import AVFoundation
import CoreAudio
import CallAudioDSP
import Foundation

public struct ApplicationAudioConfiguration: Equatable, Sendable {
    public var source: ApplicationAudioSource
    public var microphoneUID: String?
    public var microphoneEnabled: Bool
    public var sourceGain: Float
    public var microphoneGain: Float
    public var monitorUID: String?
    public var sourceToCaller: Bool
    public var microphoneToCaller: Bool
    public var listenToSource: Bool
    public var listenToMicrophone: Bool
    public init(source: ApplicationAudioSource, microphoneUID: String? = nil, microphoneEnabled: Bool = false,
                sourceGain: Float = 0.5, microphoneGain: Float = 1, monitorUID: String? = nil,
                sourceToCaller: Bool = true, microphoneToCaller: Bool = true,
                listenToSource: Bool = false, listenToMicrophone: Bool = false) {
        self.source = source; self.microphoneUID = microphoneUID; self.microphoneEnabled = microphoneEnabled
        self.sourceGain = sourceGain; self.microphoneGain = microphoneGain
        self.monitorUID = monitorUID; self.sourceToCaller = sourceToCaller
        self.microphoneToCaller = microphoneToCaller; self.listenToSource = listenToSource
        self.listenToMicrophone = listenToMicrophone
    }
    var listening: Bool { listenToSource || (microphoneEnabled && listenToMicrophone) }
    var callerRoutes: CallAudioRoutes {
        var routes: CallAudioRoutes = []
        if sourceToCaller { routes.insert(.agentToCaller) }
        if microphoneEnabled && microphoneToCaller { routes.insert(.microphoneToCaller) }
        return routes
    }
    var listeningRoutes: CallAudioRoutes {
        var routes: CallAudioRoutes = []
        if listenToSource { routes.insert(.agentToUser) }
        if microphoneEnabled && listenToMicrophone { routes.insert(.callerToUser) }
        return routes
    }
}

public struct ApplicationAudioMeters: Sendable {
    public var source: Float = 0
    public var microphone: Float = 0
    /// Upper bound from input peaks and gains. This is not receiver confirmation.
    public var estimatedOutput: Float = 0
    public var droppedFrames: UInt64 = 0
    public var outputUnderrunFrames: UInt64 = 0
    public init() {}
}

enum ChromeMixPolicy {
    static func gain(_ value: Float) -> Float { value.isFinite ? min(4, max(0, value)) : 0 }
    static func routes(microphoneEnabled: Bool, muted: Bool) -> CallAudioRoutes {
        guard !muted else { return [] }
        return microphoneEnabled ? [.microphoneToCaller, .agentToCaller] : [.agentToCaller]
    }
    static func captureStalled(secondsWithoutBuffers: TimeInterval, sourcePlaying: Bool) -> Bool {
        sourcePlaying && secondsWithoutBuffers >= 0.5
    }
}

/// Standalone local application-to-Phone bridge. No model, network, default-device
/// changes or caller capture are involved. Physical endpoints can follow macOS. Startup and
/// stopAndReport can block on HAL and must be called off the UI thread. Callbacks
/// execute on this runtime's serial worker and must enqueue UI work.
public final class ApplicationAudioRuntime: @unchecked Sendable {
    public static let sendDeviceUID = "com.codexcall.audio.send.device"
    public static let feedDeviceUID = "com.codexcall.audio.send.feed"
    public static func discoverSources() throws -> [ApplicationAudioSource] { try ApplicationDiscovery.sources() }
    private let worker = DispatchQueue(label: "com.codexcall.chrome-test", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let controlsOwner = AudioControls()
    private var controls: OpaquePointer { controlsOwner.pointer }
    private var statusHandler: ((CallAudioStatus) -> Void)?
    private var metersHandler: ((ApplicationAudioMeters) -> Void)?
    public var onStatus: ((CallAudioStatus) -> Void)? {
        get { sync { statusHandler } } set { sync { statusHandler = newValue } }
    }
    public var onMeters: ((ApplicationAudioMeters) -> Void)? {
        get { sync { metersHandler } } set { sync { metersHandler = newValue } }
    }
    public var lifecycleRevision: UInt64 { cab_controls_revision(controls) }
    private var configuration: ApplicationAudioConfiguration?
    private var tap: ApplicationProcessTap?
    private var sourceIO: InputIO?
    private let microphoneDevice = FollowingDevice<InputIO>()
    private var microphoneIO: InputIO? { microphoneDevice.endpoint }
    private var sendIO: OutputIO?
    private let listeningDevice = FollowingDevice<OutputIO>()
    private var monitorIO: OutputIO? { listeningDevice.endpoint }
    private var overflowAllowance: UInt64 = 0
    private var deviceStatusHandler: ((String) -> Void)?
    private var lastDeviceStatus = ""
    public var onDeviceStatus: ((String) -> Void)? {
        get { sync { deviceStatusHandler } } set { sync { deviceStatusHandler = newValue } }
    }
    // Source capture, microphone capture, microphone send, application send, microphone listening, application listening.
    private var rings: [AudioRing] = []
    private var sourceConverter: MonoConverter?
    private var microphoneConverter: MonoConverter?
    private var sourceMonitorConverter: MonoConverter?
    private var microphoneMonitorConverter: MonoConverter?
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 1
    private var sendMuted = false
    private let muteLock = NSLock()
    private var muteRevision: UInt64 = 0
    private var tickNumber: UInt64 = 0
    private var lastWorkerTick = ProcessInfo.processInfo.systemUptime
    private var lastSourceTime = ProcessInfo.processInfo.systemUptime
    private var lastMicrophoneTime = ProcessInfo.processInfo.systemUptime
    private var lastSourceFrames: UInt64 = 0
    private var lastMicrophoneFrames: UInt64 = 0
    private var sourcePeak: Float = 0
    private var microphonePeak: Float = 0

    public init() { worker.setSpecific(key: queueKey, value: true) }
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try worker.sync(execute: body)
    }
    public static func preflight(_ configuration: ApplicationAudioConfiguration) throws {
        guard !configuration.source.audioProcessIDs.isEmpty else {
            throw CallAudioError("Play audio in the selected application, refresh, then start.")
        }
        _ = try CallHardware.sendDevice(sendDeviceUID)
        if configuration.listening {
            if case .fixed = AudioDeviceSelection(uid: configuration.monitorUID) {
                _ = try CallHardware.endpoint(.init(uid: configuration.monitorUID), scope: kAudioDevicePropertyScopeOutput)
            }
        }
        try ApplicationDiscovery.validate(configuration.source)
        if configuration.microphoneEnabled {
            if case .fixed = AudioDeviceSelection(uid: configuration.microphoneUID) {
                _ = try CallHardware.endpoint(.init(uid: configuration.microphoneUID), scope: kAudioDevicePropertyScopeInput)
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw CallAudioError("Allow microphone access in Phone Assistant Audio Bridge setup before including your voice.")
            }
        }
    }
    public func start(configuration: ApplicationAudioConfiguration,
                      expectedLifecycleRevision: UInt64? = nil) throws {
        let revision = expectedLifecycleRevision ?? lifecycleRevision
        guard revision == lifecycleRevision else { throw CallAudioError("Application routing startup was cancelled before execution.") }
        try sync {
            guard revision == lifecycleRevision else { throw CallAudioError("Application routing startup was cancelled before execution.") }
            try stopOwnedResources()
            cab_controls_set_send_muted(controls, true)
            statusHandler?(.starting)
            do {
                try Self.preflight(configuration)
                self.configuration = configuration
                self.configuration?.sourceGain = ChromeMixPolicy.gain(configuration.sourceGain)
                self.configuration?.microphoneGain = ChromeMixPolicy.gain(configuration.microphoneGain)
                generation &+= 1; tickNumber = 0; sourcePeak = 0; microphonePeak = 0
                overflowAllowance = 0; lastDeviceStatus = ""
                rings = try (0..<6).map { _ in try AudioRing(capacity: 192000, generation: generation) }
                let sendDevice = try CallHardware.sendDevice(Self.sendDeviceUID)
                sendIO = try OutputIO(device: sendDevice, kind: .phone, first: rings[2], second: rings[3],
                                      controls: controlsOwner)
                let newTap = ApplicationProcessTap(processes: configuration.source.audioProcessIDs); tap = newTap
                try newTap.start()
                let input = try InputIO(device: newTap.device, ring: rings[0]); sourceIO = input
                guard input.format.mChannelsPerFrame == 1 else {
                    throw CallAudioError("Application capture must contain only the scoped mono tap.")
                }
                sourceConverter = try MonoConverter(from: input.format.mSampleRate, to: 48000)
                guard cab_controls_enable_if_revision(controls, revision) else { throw CallAudioError("Application routing startup was cancelled.") }
                try sendIO?.start(); try input.start()
                var received = false
                for _ in 0..<40 {
                    guard revision == lifecycleRevision else { throw CallAudioError("Application routing startup was cancelled.") }
                    if cab_ring_counters(rings[0].pointer).accepted_frames > 0 { received = true; break }
                    if try !ApplicationDiscovery.isPlaying(configuration.source) { break }
                    Thread.sleep(forTimeInterval: 0.025)
                }
                // Core Audio can withhold tap callbacks while all selected
                // processes are idle. The microphone may still serve the call.
                let sourcePlaying = try ApplicationDiscovery.isPlaying(configuration.source)
                guard received || !sourcePlaying else {
                    throw CallAudioError("No application capture buffers arrived. Check System Audio Access in setup and play audio in the selected app.")
                }
                try ApplicationDiscovery.validate(configuration.source)
                guard revision == lifecycleRevision else { throw CallAudioError("Application routing startup was cancelled.") }
                // Start the microphone only when the worker is ready to drain it.
                // Waiting on an idle application tap must not fill the microphone queue.
                try refreshPhysicalDevices()
                // Startup samples never emerge later after the UI reports ready.
                flushBuffers()
                sendMuted = false; updateControls()
                cab_controls_set_send_muted(controls, false)
                let now = ProcessInfo.processInfo.systemUptime
                lastWorkerTick = now; lastSourceTime = now; lastMicrophoneTime = now
                lastSourceFrames = 0; lastMicrophoneFrames = 0
                let timer = DispatchSource.makeTimerSource(queue: worker)
                timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                statusHandler?(.ready)
            } catch {
                let original = error.localizedDescription
                cab_controls_cancel(controls)
                do { try stopOwnedResources() }
                catch {
                    let failure = CallAudioError(original + " Cleanup: " + error.localizedDescription)
                    statusHandler?(.failed(failure.message)); throw failure
                }
                statusHandler?(.failed(original)); throw error
            }
        }
    }
    public func setGains(source: Float, microphone: Float) {
        worker.async { [weak self] in
            guard let self else { return }
            self.configuration?.sourceGain = ChromeMixPolicy.gain(source)
            self.configuration?.microphoneGain = ChromeMixPolicy.gain(microphone)
            self.updateControls()
        }
    }
    /// Closes the output gate immediately; the worker flushes both input and
    /// output queues before applying the most recent mute or resume intent.
    public func setSendMuted(_ muted: Bool) {
        muteLock.lock(); muteRevision &+= 1
        let intent = muteRevision
        cab_controls_set_send_muted(controls, true)
        worker.async { [weak self] in
            guard let self else { return }
            self.flushBuffers()
            self.muteLock.lock(); defer { self.muteLock.unlock() }
            guard intent == self.muteRevision else { return }
            self.sendMuted = muted; self.updateControls()
            cab_controls_set_send_muted(self.controls, muted)
        }
        muteLock.unlock()
    }
    private func updateControls() {
        guard let configuration else { cab_controls_set_routes(controls, 0); return }
        cab_controls_set_gains(controls, configuration.microphoneGain, configuration.sourceGain, configuration.microphoneGain)
        cab_controls_set_routes(controls, configuration.callerRoutes.union(configuration.listeningRoutes).rawValue)
    }
    private func flushBuffers() {
        generation &+= 1
        for ring in rings { ring.flush(generation) }
        sourceConverter?.reset(); microphoneConverter?.reset()
        sourceMonitorConverter?.reset(); microphoneMonitorConverter?.reset()
    }
    private func enqueue(_ samples: [Float], ring: AudioRing) throws {
        guard ring.write(samples, generation: generation) == samples.count else {
            throw CallAudioError("Application routing queue overflowed. Audio stopped instead of sending delayed audio.")
        }
    }
    private func tick() {
        guard let configuration, rings.count == 6, let sourceIO, let sourceConverter else { return }
        do {
            if tickNumber % 5 == 0 { try refreshPhysicalDevices() }
            let now = ProcessInfo.processInfo.systemUptime
            let rates = [sourceIO.format.mSampleRate, microphoneIO?.format.mSampleRate ?? 48000, 48000, 48000,
                         monitorIO?.format.mSampleRate ?? 48000, monitorIO?.format.mSampleRate ?? 48000]
            let backlog = rings.enumerated().map { Double(cab_ring_queued_frames($0.element.pointer)) / rates[$0.offset] }.max() ?? 0
            let overflow = rings.reduce(UInt64(0)) { $0 + cab_ring_counters($1.pointer).overflow_frames }
            try AudioBufferHealth.validate(overflowFrames: overflow - min(overflow, overflowAllowance),
                                           workerDelay: now - lastWorkerTick, captureBacklog: backlog)
            try verifyCaptureProgress(now: now)
            lastWorkerTick = now; tickNumber &+= 1
            let source = rings[0].read(8192, generation: generation)
            let microphone = rings[1].read(8192, generation: generation)
            sourcePeak = source.reduce(sourcePeak) { max($0, abs($1)) }
            microphonePeak = microphone.reduce(microphonePeak) { max($0, abs($1)) }
            if !sendMuted {
                try enqueue(sourceConverter.convert(source), ring: rings[3])
                if let microphoneConverter { try enqueue(microphoneConverter.convert(microphone), ring: rings[2]) }
            }
            if let sourceMonitorConverter { try enqueue(sourceMonitorConverter.convert(source), ring: rings[5]) }
            if let microphoneMonitorConverter { try enqueue(microphoneMonitorConverter.convert(microphone), ring: rings[4]) }
            if tickNumber % 10 == 0 {
                // Verify before reporting ready meters. Changed/vanished source
                // sets never cause a fallback to a global or other-app capture.
                try verifyRoutes(now: now)
                var meters = ApplicationAudioMeters()
                meters.source = sourcePeak; meters.microphone = microphonePeak
                meters.estimatedOutput = sendMuted ? 0 : min(1,
                    (configuration.sourceToCaller ? sourcePeak * configuration.sourceGain : 0) +
                    (configuration.microphoneEnabled && configuration.microphoneToCaller ? microphonePeak * configuration.microphoneGain : 0))
                meters.droppedFrames = rings.reduce(0) { $0 + cab_ring_counters($1.pointer).overflow_frames }
                meters.outputUnderrunFrames = cab_ring_counters(rings[3].pointer).underrun_frames
                metersHandler?(meters); sourcePeak = 0; microphonePeak = 0
            }
        } catch {
            cab_controls_cancel(controls)
            let original = error.localizedDescription
            do { try stopOwnedResources(); statusHandler?(.failed(original)) }
            catch { statusHandler?(.failed(original + " Cleanup: " + error.localizedDescription)) }
        }
    }
    /// Rebuild only physical endpoints; the app tap and virtual send stay owned.
    private func refreshPhysicalDevices() throws {
        guard let configuration, let sourceIO, rings.count == 6 else { return }
        let revision = lifecycleRevision
        let transition = DeviceTransitionGate(controlsOwner)
        var completed = false
        let prepare = { transition.begin() }
        defer {
            if transition.changed {
                // HAL device changes can block. Discard samples accumulated during
                // that gap instead of replaying them after the switch.
                flushBuffers()
                _ = rings[0].read(192000, generation: generation)
                _ = rings[1].read(192000, generation: generation)
                overflowAllowance = rings.reduce(0) { $0 + cab_ring_counters($1.pointer).overflow_frames }
                let now = ProcessInfo.processInfo.systemUptime
                lastWorkerTick = now; lastSourceTime = now; lastMicrophoneTime = now
                lastSourceFrames = cab_ring_counters(rings[0].pointer).accepted_frames
                lastMicrophoneFrames = cab_ring_counters(rings[1].pointer).accepted_frames
                sourcePeak = 0; microphonePeak = 0
                // Restores route choices, never the independent caller-mute or
                // lifecycle cancellation flags.
                transition.finish(success: completed) { updateControls() }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let micChanged = try microphoneDevice.refresh(selection: .init(uid: configuration.microphoneUID),
            enabled: configuration.microphoneEnabled, now: now,
            resolve: { try CallHardware.endpoint($0, scope: kAudioDevicePropertyScopeInput) },
            make: { try InputIO(device: $0.id, ring: self.rings[1]) }, willChange: prepare,
            didClose: { _ = self.rings[1].read(192000, generation: self.generation) },
            isCancelled: { self.lifecycleRevision != revision })
        let monitorChanged = try listeningDevice.refresh(selection: .init(uid: configuration.monitorUID),
            enabled: configuration.listening, now: now,
            resolve: { try CallHardware.endpoint($0, scope: kAudioDevicePropertyScopeOutput) },
            make: { try OutputIO(device: $0.id, kind: .monitor, first: self.rings[4], second: self.rings[5], controls: self.controlsOwner) },
            willChange: prepare, didClose: {
                _ = self.rings[4].read(192000, generation: self.generation)
                _ = self.rings[5].read(192000, generation: self.generation)
            }, isCancelled: { self.lifecycleRevision != revision })
        if micChanged {
            microphoneConverter = try microphoneIO.map { try MonoConverter(from: $0.format.mSampleRate, to: 48000) }
        }
        if monitorChanged {
            sourceMonitorConverter = try monitorIO.map { try MonoConverter(from: sourceIO.format.mSampleRate, to: $0.format.mSampleRate) }
        }
        if micChanged || monitorChanged {
            microphoneMonitorConverter = nil
            if let mic = microphoneIO, let output = monitorIO {
                microphoneMonitorConverter = try MonoConverter(from: mic.format.mSampleRate, to: output.format.mSampleRate)
            }
        }
        let message = "Microphone: " + (microphoneDevice.target?.name ?? (configuration.microphoneEnabled ? "waiting for Mac selection" : "off"))
            + " · Listening: " + (listeningDevice.target?.name ?? (configuration.listening ? "waiting for Mac selection" : "off"))
        if message != lastDeviceStatus { lastDeviceStatus = message; deviceStatusHandler?(message) }
        completed = true
    }
    private func verifyRoutes(now: TimeInterval) throws {
        guard let configuration, let sourceIO, let sendIO, tap != nil else {
            throw CallAudioError("Application routing route ownership was lost.")
        }
        guard try CallHardware.sendDevice(Self.sendDeviceUID) == sendIO.device,
              sendIO.formatIsCurrent(), sourceIO.formatIsCurrent() else {
            throw CallAudioError("Phone Assistant Audio Bridge's virtual microphone or capture format changed. Audio stopped.")
        }
        try ApplicationDiscovery.validate(configuration.source)

    }
    private func verifyCaptureProgress(now: TimeInterval) throws {
        let sourceFrames = cab_ring_counters(rings[0].pointer).accepted_frames
        if sourceFrames != lastSourceFrames { lastSourceFrames = sourceFrames; lastSourceTime = now }
        if now - lastSourceTime >= 0.5, let configuration {
            let playing = try ApplicationDiscovery.isPlaying(configuration.source)
            guard !ChromeMixPolicy.captureStalled(secondsWithoutBuffers: now - lastSourceTime, sourcePlaying: playing) else {
                throw CallAudioError("Application capture stopped delivering buffers while the selected app was playing. Audio stopped.")
            }
            // Start a fresh deadline for playback after an idle interval.
            lastSourceTime = now
        }
        if microphoneIO != nil {
            let frames = cab_ring_counters(rings[1].pointer).accepted_frames
            if frames != lastMicrophoneFrames { lastMicrophoneFrames = frames; lastMicrophoneTime = now }
            guard now - lastMicrophoneTime < 0.5 else { throw CallAudioError("Microphone capture stopped delivering buffers. Audio stopped.") }
        }
    }
    public func stopAsync(completion: (() -> Void)? = nil) {
        cab_controls_cancel(controls)
        worker.async { [weak self] in
            guard let self else { completion?(); return }
            do { try self.stopOwnedResources(); self.statusHandler?(.stopped) }
            catch { self.statusHandler?(.failed(error.localizedDescription)) }
            completion?()
        }
    }
    public func stopAndReport() throws {
        cab_controls_cancel(controls)
        try sync {
            do { try stopOwnedResources(); statusHandler?(.stopped) }
            catch { statusHandler?(.failed(error.localizedDescription)); throw error }
        }
    }
    private func stopOwnedResources() throws {
        timer?.cancel(); timer = nil
        cab_controls_set_routes(controls, 0); flushBuffers()
        var failures: [String] = []
        func attempt(_ operation: () throws -> Void) { do { try operation() } catch { failures.append(error.localizedDescription) } }
        // Independent cleanup ensures tap destruction (speaker restoration) is
        // attempted even if a device has vanished. Failed owners remain retained
        // for retry; an error never gets presented as successful cleanup.
        attempt { try sourceIO?.close() }; attempt { try microphoneDevice.reset() }
        attempt { try sendIO?.close() }; attempt { try listeningDevice.reset() }; attempt { try tap?.close() }
        if failures.isEmpty {
            sourceIO = nil; sendIO = nil; tap = nil
            sourceMonitorConverter = nil; microphoneMonitorConverter = nil
            rings.removeAll(); sourceConverter = nil; microphoneConverter = nil; configuration = nil
        } else { throw CallAudioError(failures.joined(separator: " ")) }
    }
    deinit { sync { try? stopOwnedResources() } }
}
