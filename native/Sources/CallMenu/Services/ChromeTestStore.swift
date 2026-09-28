import AppKit
import AVFoundation
import CallAudio
import CallAutomation
import Combine

@MainActor final class RoutingStore: ObservableObject {
    @Published private(set) var sources: [ApplicationAudioSource] = []
    @Published private(set) var devices: [AudioDevice] = []
    @Published var preferences: RoutingPreferences {
        didSet {
            preferences.save(to: defaults)
            if preferences.requiresRestart(comparedTo: oldValue), active || busy { stop() }
            let p = preferences.normalized(), runtime = runtime, phoneRuntime = phoneRuntime
            queue.async {
                runtime.setGains(source: Float(p.sourceGain), microphone: Float(p.microphoneGain))
                phoneRuntime.setGains(microphone: Float(p.microphoneGain), agent: 0, caller: Float(p.sourceGain))
            }
            if reportingPhoneTest && (preferences.microphoneGain != oldValue.microphoneGain || preferences.sourceGain != oldValue.sourceGain) {
                phoneReport?.event("gain_changed", detail: "Microphone \(p.microphoneGain); caller listening \(p.sourceGain)")
                savePhoneReport(force: true)
            }
        }
    }
    @Published private(set) var muted = false
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published private(set) var needsCleanup = false
    @Published private(set) var deviceStatus = ""
    @Published private(set) var status = "Choose an application and where to send its audio."
    @Published private(set) var error = ""
    @Published private(set) var sourcePeak: Float = 0
    @Published private(set) var microphonePeak: Float = 0
    @Published private(set) var outputPeak: Float = 0
    @Published private(set) var droppedFrames: UInt64 = 0
    @Published private(set) var underrunFrames: UInt64 = 0
    @Published private(set) var outputRMS: Float = 0
    @Published private(set) var outputFrames: UInt64 = 0
    @Published private(set) var telemetryDrops: UInt64 = 0
    @Published private(set) var diagnosticSummary = ""
    @Published private(set) var diagnosticError = ""
    var onAudioObserved: (() -> Void)?
    private let microphoneOwner = UUID()
    private let defaults: UserDefaults
    private let runtime = ApplicationAudioRuntime()
    private let phoneRuntime = CallAudioRuntime()
    private let queue = DispatchQueue(label: "com.codexcall.chrome.control", qos: .userInitiated)
    private var operation = 0
    private var observedAudio = false
    private var cleanup: Task<Bool, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var refreshing = false
    private var phoneReport: PhoneTestReport?
    private var reportingPhoneTest = false
    private var lastReportWrite = Date.distantPast
    private let reportQueue = DispatchQueue(label: "com.codexcall.phone-test-report", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = RoutingPreferences.load(from: defaults)
        if let previous = try? PhoneTestReportStorage.load() {
            phoneReport = previous; diagnosticSummary = "Previous test: " + previous.summary
        }
    }
    // Discovery is only needed while the diagnostic screen is open.
    func beginDiscovery() {
        guard discoveryTask == nil else { return }
        refresh()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.refresh()
            }
        }
    }
    func endDiscovery() { discoveryTask?.cancel(); discoveryTask = nil }
    deinit { discoveryTask?.cancel() }
    var selectedApplication: ApplicationAudioSource? { sources.first { $0.id == preferences.applicationID } }
    var isPhoneTest: Bool { preferences.isPhoneTest }
    var hasPhoneDiagnostics: Bool { phoneReport != nil }
    var availability: String? {
        preferences.unavailable(applicationIDs: [RoutingPreferences.phoneSourceID] + sources.map(\.id),
            microphoneUIDs: devices.filter { $0.isPhysical && $0.input }.map(\.uid),
            outputUIDs: devices.filter { $0.isPhysical && $0.output }.map(\.uid))
    }
    var canStart: Bool {
        !active && !busy && !needsCleanup && availability == nil && (isPhoneTest || selectedApplication?.audioProcessIDs.isEmpty == false)
    }
    var canStop: Bool { active || busy || needsCleanup }
    func chooseApplication(_ id: String) {
        guard id != preferences.applicationID, !canStop else { return }
        var next = preferences
        if next.isPhoneTest { next.sourceToCaller = true; next.listenToSource = false }
        next.applicationID = id; next.applicationName = sources.first { $0.id == id }?.name ?? ""
        if next.isPhoneTest { next.applicationName = "Phone" }
        preferences = next.normalized()
        if isPhoneTest {
            error = ""; status = "Phone selected. Start or answer a call in Phone, then choose Start here."
        }
    }
    func chooseMicrophone(_ uid: String) {
        var next = preferences
        next.microphoneUID = uid; next.microphoneName = devices.first { $0.uid == uid }?.name ?? ""
        preferences = next
    }
    func chooseMonitor(_ uid: String) {
        var next = preferences
        next.monitorUID = uid; next.monitorName = devices.first { $0.uid == uid }?.name ?? ""
        preferences = next
    }
    func refresh() {
        guard !active, !busy, !refreshing else { return }
        refreshing = true
        queue.async { [weak self] in
            let result = Result { (try ApplicationAudioRuntime.discoverSources(), try Devices.list()) }
            Task { @MainActor in
                guard let self else { return }
                self.refreshing = false
                switch result {
                case .success(let value): self.sources = value.0; self.devices = value.1
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        }
    }
    func useChromePreset() {
        guard !canStop else { return }
        let matches = sources.filter { $0.bundleID == "com.google.Chrome" }
        guard matches.count == 1, let chrome = matches.first else {
            error = "Open one Google Chrome instance, refresh, then choose this preset."; return
        }
        var next = preferences
        next.applicationID = chrome.id; next.applicationName = chrome.name
        next.microphoneUID = ""; next.microphoneName = ""
        next.monitorUID = ""; next.monitorName = ""
        next.microphoneEnabled = true; next.sourceGain = 3.15; next.microphoneGain = 0.53
        next.sourceToCaller = true; next.microphoneToCaller = true
        next.listenToSource = false; next.listenToMicrophone = false
        preferences = next; error = ""; status = "Chrome + microphone preset selected. Choose Start when ready."
    }
    func start() async {
        guard canStart else { return }
        if preferences.microphoneEnabled && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            error = "Enable microphone access in Setup before including your microphone."; return
        }
        if isPhoneTest { await startPhoneTest(); return }
        guard let source = selectedApplication else { return }
        operation += 1; let version = operation
        busy = true; error = ""; status = "Connecting selected audio…"; muted = false; observedAudio = false
        preferences.applicationName = source.name
        preferences.microphoneName = devices.first { $0.uid == preferences.microphoneUID }?.name ?? preferences.microphoneName
        preferences.monitorName = devices.first { $0.uid == preferences.monitorUID }?.name ?? preferences.monitorName
        let p = preferences.normalized()
        let configuration = ApplicationAudioConfiguration(source: source, microphoneUID: p.microphoneUID,
            microphoneEnabled: p.microphoneEnabled, sourceGain: Float(p.sourceGain), microphoneGain: Float(p.microphoneGain),
            monitorUID: p.monitorUID, sourceToCaller: p.sourceToCaller, microphoneToCaller: p.microphoneToCaller,
            listenToSource: p.listenToSource, listenToMicrophone: p.listenToMicrophone)
        let revision = runtime.lifecycleRevision
        let runtime = runtime
        queue.async { [weak self] in
            runtime.onDeviceStatus = { message in
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    self.deviceStatus = message
                }
            }
            runtime.onMeters = { meters in
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    self.sourcePeak = meters.source; self.microphonePeak = meters.microphone
                    self.outputPeak = meters.estimatedOutput; self.droppedFrames = meters.droppedFrames
                    self.underrunFrames = meters.outputUnderrunFrames
                    if meters.source > 0.0001 && !self.observedAudio {
                        self.observedAudio = true; self.onAudioObserved?()
                        self.status = self.muted ? "Caller sending is muted; local listening is unchanged." : "Selected application audio is being captured."
                    }
                }
            }
            runtime.onStatus = { state in
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    switch state {
                    case .ready: self.active = true; self.busy = false; self.status = "Running. Waiting for application audio…"
                    case .failed(let message): self.error = message; self.stop()
                    default: break
                    }
                }
            }
            do { try runtime.start(configuration: configuration, expectedLifecycleRevision: revision) }
            catch { Task { @MainActor in
                guard let self, self.operation == version else { return }
                self.error = error.localizedDescription; self.stop()
            } }
        }
    }
    private func startPhoneTest() async {
        operation += 1; let version = operation
        busy = true; error = ""; status = "Checking Phone's audio…"; muted = false; observedAudio = false
        do {
            try await PhoneMicrophoneAutomation.shared.connect(owner: microphoneOwner)
            guard operation == version else { return }
        } catch {
            if operation == version { self.error = error.localizedDescription; stop() }
            return
        }
        let p = preferences.normalized(), runtime = phoneRuntime
        phoneReport = PhoneTestReport(nativePlayback: p.usesNativePhonePlayback,
            microphoneEnabled: p.microphoneEnabled && p.microphoneToCaller,
            microphoneGain: p.microphoneGain, callerGain: p.sourceGain)
        reportingPhoneTest = true; diagnosticError = ""
        savePhoneReport(force: true)
        let revision = runtime.lifecycleRevision
        queue.async { [weak self] in
            runtime.onDeviceStatus = { message in
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    self.deviceStatus = message
                    self.phoneReport?.event("devices", detail: message)
                    self.savePhoneReport(force: true)
                }
            }
            runtime.onMeters = { meters in
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    self.sourcePeak = meters.caller; self.microphonePeak = meters.microphone
                    self.outputPeak = meters.renderedPhonePeak; self.outputRMS = meters.renderedPhoneRMS
                    self.outputFrames = meters.renderedPhoneFrames
                    self.telemetryDrops = meters.renderedPhoneDroppedTelemetryBlocks
                    self.droppedFrames = meters.droppedFrames; self.underrunFrames = meters.microphoneOutputUnderrunFrames
                    self.phoneReport?.append(meters: meters, muted: self.muted, now: meters.measuredAt)
                    self.savePhoneReport()
                    if meters.caller > 0.0001 && !self.observedAudio {
                        self.observedAudio = true; self.onAudioObserved?()
                    }
                }
            }
            runtime.onStatus = { state in
                guard case .failed(let message) = state else { return }
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    self.phoneReport?.event("failed", detail: message)
                    self.error = message; self.stop()
                }
            }
            do {
                // The production Phone engine keeps caller capture out of the
                // outgoing mix. No model transport or generated audio is used.
                runtime.setCallerListeningEnabled(p.listenToSource && !p.usesNativePhonePlayback)
                runtime.setAgentMonitoringEnabled(false)
                runtime.setGains(microphone: Float(p.microphoneGain), agent: 0, caller: Float(p.sourceGain))
                try runtime.start(configuration: p.phoneTestConfiguration, epoch: UUID().uuidString,
                                  expectedLifecycleRevision: revision)
                runtime.setSendMuted(false)
                Task { @MainActor in
                    guard let self, self.operation == version else { return }
                    self.active = true; self.busy = false
                    self.status = p.usesNativePhonePlayback ? "Phone test running. Phone handles caller playback." : "Phone test running. The app handles caller playback."
                    self.phoneReport?.event("running")
                    self.savePhoneReport(force: true)
                }
            } catch { Task { @MainActor in
                guard let self, self.operation == version else { return }
                self.phoneReport?.event("failed", detail: error.localizedDescription)
                self.error = error.localizedDescription; self.stop()
            } }
        }
    }
    func setMuted(_ value: Bool) {
        muted = value; runtime.setSendMuted(value); phoneRuntime.setSendMuted(value)
        if value { outputPeak = 0 }
        if reportingPhoneTest {
            phoneReport?.event(value ? "muted" : "unmuted")
            savePhoneReport(force: true)
        }
        if active { status = value ? "Caller sending is muted; local listening is unchanged." : "Routing is running." }
    }
    func stop() {
        operation += 1; let version = operation
        runtime.stopAsync(); phoneRuntime.stopAsync()
        if reportingPhoneTest { phoneReport?.event("stopping"); savePhoneReport(force: true) }
        active = false; busy = true; status = "Stopping and restoring application playback…"
        sourcePeak = 0; microphonePeak = 0; outputPeak = 0; outputRMS = 0; outputFrames = 0; deviceStatus = ""
        let runtime = runtime, phoneRuntime = phoneRuntime
        cleanup = Task { [weak self] in
            guard let self else { return false }
            var result: Result<Void, Error> = await withCheckedContinuation { continuation in
                self.queue.async {
                    // Always attempt both cleanups, even if one fails.
                    var failures: [String] = []
                    do { try runtime.stopAndReport() } catch { failures.append(error.localizedDescription) }
                    do { try phoneRuntime.stopAndReport() } catch { failures.append(error.localizedDescription) }
                    continuation.resume(returning: failures.isEmpty ? .success(()) : .failure(CallAudioError(failures.joined(separator: " "))))
                }
            }
            if case .success = result {
                do { try await PhoneMicrophoneAutomation.shared.disconnect(owner: microphoneOwner) }
                catch { result = .failure(error) }
            }
            guard operation == version else { return false }
            busy = false
            switch result {
            case .success:
                if reportingPhoneTest { phoneReport?.event("stopped"); savePhoneReport(force: true); reportingPhoneTest = false }
                needsCleanup = false; status = "Stopped. Application playback is restored. Selections are saved."; refresh(); return true
            case .failure(let failure):
                if reportingPhoneTest { phoneReport?.event("failed", detail: failure.localizedDescription); savePhoneReport(force: true); reportingPhoneTest = false }
                needsCleanup = true; status = "Cleanup needs attention"; error = failure.localizedDescription; return false
            }
        }
    }
    func stopAndWait() async -> Bool {
        stop()
        let result = await cleanup?.value ?? false
        await withCheckedContinuation { continuation in reportQueue.async { continuation.resume() } }
        return result
    }
    private func savePhoneReport(force: Bool = false) {
        guard let report = phoneReport else { return }
        diagnosticSummary = report.summary
        let now = Date()
        guard force || now.timeIntervalSince(lastReportWrite) >= 1 else { return }
        lastReportWrite = now
        let version = operation
        reportQueue.async { [weak self] in
            do { try PhoneTestReportStorage.save(report) }
            catch { Task { @MainActor in
                guard let self, self.operation == version else { return }
                self.diagnosticError = "The local diagnostic report could not be saved. Audio is unaffected."
            } }
        }
    }
    func copyPhoneDiagnostics() {
        guard let report = phoneReport, let data = try? report.encoded(), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
