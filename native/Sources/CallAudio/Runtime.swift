import AVFoundation
import CoreAudio
import CallAudioDSP
import Foundation

/// One worker owns device lifecycle, conversion, epoch sequencing and transport
/// delivery. Public methods serialize onto it. Model/status callbacks run on
/// this worker and must enqueue work rather than block it. Hardware I/O only
/// touches bounded preallocated rings and lock-free controls.
public final class CallAudioRuntime: @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.codexcall.audio", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let controlsOwner = AudioControls()
    private var controls: OpaquePointer { controlsOwner.pointer }
    private var modelHandler: ((CallAudioPacket) -> Void)?
    private var statusHandler: ((CallAudioStatus) -> Void)?
    private var metersHandler: ((CallAudioMeters) -> Void)?
    private var transcriptionHandler: (([Float]?, [Float]?) -> Void)?
    public var onModelPCM: ((CallAudioPacket) -> Void)? {
        get { sync { modelHandler } } set { sync { modelHandler = newValue } }
    }
    public var onStatus: ((CallAudioStatus) -> Void)? {
        get { sync { statusHandler } } set { sync { statusHandler = newValue } }
    }
    public var onMeters: ((CallAudioMeters) -> Void)? {
        get { sync { metersHandler } } set { sync { metersHandler = newValue } }
    }
    /// Separate 24 kHz caller and microphone frames for on-device transcription,
    /// before they are mixed for the assistant. Each is nil unless the assistant
    /// is authorized to hear that source, so nothing is transcribed that the
    /// assistant could not hear. Called on the audio worker; must not block.
    public var onTranscriptionAudio: (([Float]?, [Float]?) -> Void)? {
        get { sync { transcriptionHandler } } set { sync { transcriptionHandler = newValue } }
    }
    private var configuration: CallAudioConfiguration?
    private var timer: DispatchSourceTimer?
    private var tap: CallerTap?
    private var callerIO: InputIO?
    private let microphoneDevice = FollowingDevice<InputIO>()
    private var microphoneIO: InputIO? { microphoneDevice.endpoint }
    private var phoneIO: OutputIO?
    private let listeningDevice = FollowingDevice<OutputIO>()
    private var monitorIO: OutputIO? { listeningDevice.endpoint }
    private var overflowAllowance: UInt64 = 0
    private var lastDeviceStatus = ""
    private var deviceStatusHandler: ((String) -> Void)?
    public var onDeviceStatus: ((String) -> Void)? {
        get { sync { deviceStatusHandler } } set { sync { deviceStatusHandler = newValue } }
    }
    private var epoch = ""
    private var generation: UInt64 = 1
    private var streamGate = StreamGate()
    private var samplePosition: UInt64 = 0
    private var tickNumber: UInt64 = 0
    private var sendMuted = true
    private let muteIntentLock = NSLock()
    private var muteIntent: UInt64 = 0
    private var agentMonitoring = true
    private var callerListening = true
    private var microphoneGain: Float = 1
    private var agentGain: Float = 1
    private var callerGain: Float = 1
    private var liveTuning: CallAudioTuning?
    private var latestAgentPeak: Float = 0
    private var callerMeterWindow = CaptureMeterWindow()
    private var microphoneMeterWindow = CaptureMeterWindow()
    private var lastCaptureFrames: UInt64 = 0
    private var lastCaptureTime = ProcessInfo.processInfo.systemUptime
    private var lastWorkerTick = ProcessInfo.processInfo.systemUptime
    private var rings: [AudioRing] = []
    // Indices: caller capture, microphone capture, mic->phone, agent->phone,
    // caller->monitor, agent->monitor, owner->monitor, caller->model, mic->model.
    private var callerToModel: MonoConverter?
    private var callerToMonitor: MonoConverter?
    private var microphoneToModel: MonoConverter?
    private var microphoneToPhone: MonoConverter?
    private var agentToPhone: MonoConverter?
    private var agentToMonitor: MonoConverter?
    private var ownerToMonitor: MonoConverter?

    public init() {
        worker.setSpecific(key: queueKey, value: true)
    }
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try worker.sync(execute: body)
    }
    public static func preflight(_ configuration: CallAudioConfiguration) throws {
        _ = try CallHardware.sendDevice(configuration.virtualOutputUID)
        if configuration.needsListeningDevice, case .fixed = AudioDeviceSelection(uid: configuration.monitorOutputUID) {
            _ = try CallHardware.endpoint(.init(uid: configuration.monitorOutputUID), scope: kAudioDevicePropertyScopeOutput)
        }
        if configuration.usesMicrophone {
            // Do not claim a speaking connection when Automatic currently
            // points back at our virtual microphone or has no physical input.
            let selection = AudioDeviceSelection(uid: configuration.microphoneUID)
            do { _ = try CallHardware.endpoint(selection, scope: kAudioDevicePropertyScopeInput) }
            catch {
                guard selection == .automatic else { throw error }
                throw CallAudioError("Choose a physical microphone in System Settings → Sound → Input. Phone Assistant belongs in Phone's Microphone menu, not the Mac's system input.")
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw CallAudioError("Microphone access must be granted before enabling the microphone.")
            }
        }
    }
    public var lifecycleRevision: UInt64 { cab_controls_revision(controls) }
    public func start(configuration: CallAudioConfiguration, epoch: String,
                      expectedLifecycleRevision: UInt64? = nil) throws {
        let revision = expectedLifecycleRevision ?? cab_controls_revision(controls)
        guard revision == cab_controls_revision(controls) else { throw CallAudioError("Audio startup was cancelled before execution.") }
        try sync {
            guard revision == cab_controls_revision(controls) else { throw CallAudioError("Audio startup was cancelled before execution.") }
            try stopOwnedResources()
            sendMuted = true; cab_controls_set_send_muted(controls, true)
            guard !epoch.isEmpty else { throw CallAudioError("An audio epoch is required.") }
            try Self.preflight(configuration)
            let process = try CallHardware.phoneProcess()
            if configuration.requirePhoneInput {
                // Phone's checked menu item can update before its audio helper.
                // Wait briefly for HAL without opening any send/capture I/O.
                for attempt in 0..<20 {
                    guard revision == cab_controls_revision(controls) else { throw CallAudioError("Audio startup was cancelled.") }
                    do {
                        try CallHardware.verifyPhoneInput(process: process, uid: configuration.virtualOutputUID)
                        break
                    } catch {
                        if attempt == 19 { throw error }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            statusHandler?(.starting)
            self.configuration = configuration; self.epoch = epoch
            generation &+= 1; streamGate.transition(to: epoch); samplePosition = 0; tickNumber = 0
            overflowAllowance = 0; lastDeviceStatus = ""
            do {
                rings = try (0..<9).map { index in
                    // Every queue holds at most one second. 192k source capture
                    // remains bounded to 1/4 second; worker drains every 20 ms.
                    try AudioRing(capacity: index >= 7 ? 24000 : 48000, generation: generation)
                }
                let phone = try CallHardware.sendDevice(configuration.virtualOutputUID)
                // OutputIO's Phone renderer always limits the combined send
                // mix; both microphone and generated voice share protection.
                phoneIO = try OutputIO(device: phone, kind: .phone, first: rings[2], second: rings[3], controls: controlsOwner)
                agentToPhone = try MonoConverter(from: 24000, to: 48000)
                let callerTap = CallerTap(process: process); tap = callerTap
                try callerTap.start(manageListening: configuration.manageCallerListening)
                let capture = try InputIO(device: callerTap.device, ring: rings[0])
                guard capture.format.mChannelsPerFrame == 1 else { throw CallAudioError("Caller capture must contain exactly the scoped mono tap, with no extra input channels.") }
                callerIO = capture
                callerToModel = try MonoConverter(from: capture.format.mSampleRate, to: 24000)
                try refreshPhysicalDevices()
                updateControls()
                guard cab_controls_enable_if_revision(controls, revision) else {
                    throw CallAudioError("Audio startup was cancelled.")
                }
                // The monitor must run before a mutedWhenTapped source starts.
                try phoneIO?.start(); try capture.start()
                var captureStarted = false
                for _ in 0..<40 {
                    if cab_ring_counters(rings[0].pointer).accepted_frames > 0 { captureStarted = true; break }
                    Thread.sleep(forTimeInterval: 0.025)
                }
                guard captureStarted else { throw CallAudioError("Phone capture produced no buffers. Check system audio capture permission.") }
                guard cab_controls_revision(controls) == revision else { throw CallAudioError("Audio startup was cancelled.") }
                lastCaptureFrames = 0; lastCaptureTime = ProcessInfo.processInfo.systemUptime
                lastWorkerTick = lastCaptureTime
                let timer = DispatchSource.makeTimerSource(queue: worker)
                timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                statusHandler?(.ready)
            } catch {
                let original = error.localizedDescription
                do { try stopOwnedResources() }
                catch { statusHandler?(.failed(original + " Cleanup: " + error.localizedDescription)); throw error }
                statusHandler?(.failed(original)); throw error
            }
        }
    }
    public func setMode(_ mode: CallAudioMode) {
        sync {
            guard configuration?.mode != mode else { return }
            configuration?.mode = mode
            // A mode transition requires a fresh transport epoch. Already-issued
            // model speech must never become audible to a different audience.
            epoch = ""; streamGate.transition(to: ""); flushBuffers(); updateControls()
        }
    }
    /// Close every route before a UI change, even if a worker/HAL call is blocked.
    public func suspendRouting() -> UInt64 {
        cab_controls_cancel(controls)
        return lifecycleRevision
    }
    public func applyPhoneRouting(_ routing: PhoneRouting, epoch: String, expectedRevision: UInt64) throws {
        try sync {
            guard var configuration, !epoch.isEmpty, expectedRevision == lifecycleRevision else {
                throw CallAudioError("The route change was cancelled.")
            }
            configuration.phoneRouting = routing
            configuration.microphoneEnabled = routing.speaker.includesUser
            if !routing.listener.includesUser && !configuration.manageCallerListening {
                try tap?.setManagedListening(true)
                configuration.manageCallerListening = true
            }
            try Self.preflight(configuration)
            self.configuration = configuration
            self.epoch = epoch; streamGate.transition(to: epoch); samplePosition = 0
            flushBuffers(); try refreshPhysicalDevices(); updateControls()
            guard cab_controls_enable_if_revision(controls, expectedRevision) else {
                throw CallAudioError("The route change was cancelled.")
            }
        }
    }
    public func setMicrophoneEnabled(_ enabled: Bool) throws {
        try sync {
            guard var configuration else { throw CallAudioError("Audio is disconnected.") }
            configuration.microphoneEnabled = enabled
            try Self.preflight(configuration)
            self.configuration = configuration
            try refreshPhysicalDevices()
            flushBuffers(); updateControls()
        }
    }
    public func setSendMuted(_ muted: Bool) {
        // This is the one UI-safe immediate control. Close the atomic send gate
        // before queueing anything. A blocked Core Audio lifecycle call cannot
        // delay muting. Only the most recent intent may reopen after its flush.
        muteIntentLock.lock()
        muteIntent &+= 1
        let intent = muteIntent
        cab_controls_set_send_muted(controls, true)
        worker.async { [weak self] in
            guard let self else { return }
            self.flushBuffers()
            self.muteIntentLock.lock()
            defer { self.muteIntentLock.unlock() }
            guard intent == self.muteIntent else { return }
            self.sendMuted = muted
            self.updateControls()
            cab_controls_set_send_muted(self.controls, muted)
        }
        muteIntentLock.unlock()
    }
    public func setAgentMonitoringEnabled(_ enabled: Bool) {
        sync { agentMonitoring = enabled; updateControls() }
    }
    public func setCallerListeningEnabled(_ enabled: Bool) {
        sync { callerListening = enabled; updateControls() }
    }
    public func setGains(microphone: Float, agent: Float, caller: Float = 1) {
        sync {
            microphoneGain = boundedGain(microphone); agentGain = boundedGain(agent); callerGain = boundedGain(caller)
            updateControls()
        }
    }
    public func setLiveTuning(_ value: CallAudioTuning) {
        sync { liveTuning = value.normalized(); updateControls() }
    }
    /// Reuses the endpoint-following machinery; never changes macOS defaults,
    /// the Phone-facing device identity, provider session, or transport epoch.
    public func setPhysicalSelections(microphoneUID: String?, monitorUID: String?) throws {
        try sync {
            guard var next = configuration else { throw CallAudioError("Audio is disconnected.") }
            next.microphoneUID = microphoneUID; next.monitorOutputUID = monitorUID
            try Self.preflight(next)
            configuration = next
            try refreshPhysicalDevices()
        }
    }
    public func setNativeCallerPlayback(_ enabled: Bool) throws {
        try sync {
            guard var next = configuration, let tap else { throw CallAudioError("Audio is disconnected.") }
            guard !enabled || next.phoneRouting?.listener.includesUser == true else {
                throw CallAudioError("Choose Me or Both for listening before enabling Phone playback.")
            }
            guard next.manageCallerListening == enabled else { return }
            cab_controls_set_routes(controls, 0)
            do {
                try tap.setManagedListening(!enabled)
                next.manageCallerListening = !enabled
                configuration = next
                flushBuffers(); try refreshPhysicalDevices(); updateControls()
            } catch {
                // Leave delivery closed until the owner handles the failure.
                throw error
            }
        }
    }
    private func boundedGain(_ value: Float) -> Float { value.isFinite ? min(4, max(0, value)) : 0 }
    private func updateControls() {
        var routes = configuration?.effectiveRoutes ?? []
        if configuration?.microphoneEnabled != true { routes.subtract([.microphoneToCaller, .microphoneToAgent]) }
        if sendMuted || epoch.isEmpty { routes.subtract([.microphoneToCaller, .agentToCaller]) }
        if !agentMonitoring && configuration?.mode != .privateAside { routes.remove(.agentToUser) }
        if !callerListening || configuration?.manageCallerListening != true { routes.remove(.callerToUser) }
        if let liveTuning {
            routes = liveTuning.effectiveRoutes(routes)
            liveTuning.apply(to: controls)
        } else { cab_controls_set_gains(controls, microphoneGain, agentGain, callerGain) }
        cab_controls_set_routes(controls, routes.rawValue)
    }
    public func setEpoch(_ epoch: String) {
        sync {
            guard epoch != self.epoch else { return }
            self.epoch = epoch; streamGate.transition(to: epoch); samplePosition = 0
            flushBuffers(); updateControls()
        }
    }
    private func flushBuffers() {
        callerMeterWindow.reset(); microphoneMeterWindow.reset(); latestAgentPeak = 0
        generation &+= 1
        for ring in rings { ring.flush(generation) }
        for converter in [callerToModel, callerToMonitor, microphoneToModel, microphoneToPhone,
                          agentToPhone, agentToMonitor, ownerToMonitor] { converter?.reset() }
    }
    public func submitAgentPCM(_ data: Data, epoch: String, sequence: UInt64,
                               audience: CallAudioAudience = .caller) throws {
        try sync {
            guard configuration != nil, !epoch.isEmpty, epoch == self.epoch else {
                throw CallAudioError("Discarded audio from a stale or disconnected epoch.")
            }
            let samples = try PCM24.decode(data)
            try streamGate.accept(epoch: epoch, sequence: sequence)
            latestAgentPeak = max(latestAgentPeak, samples.reduce(0) { max($0, abs($1)) })
            // Only enqueue authorized destinations. Caller mute must not also
            // mute the user's listening path. A suspended lifecycle masks all.
            let authorized = CallAudioRoutes(rawValue: cab_controls_routes(controls))
            guard !authorized.isEmpty else { return }
            if audience == .owner || configuration?.mode == .privateAside {
                guard authorized.contains(.agentToUser) else { return }
                // A disappearing Automatic output pauses private playback. Never
                // retain private speech to replay when another output appears.
                if monitorIO == nil && AudioDeviceSelection(uid: configuration?.monitorOutputUID) == .automatic { return }
                guard monitorIO != nil, let ownerToMonitor else { throw CallAudioError("Private agent audio requires a physical monitor.") }
                try writeRequired(ownerToMonitor.convert(samples), to: rings[6])
            } else {
                if authorized.contains(.agentToCaller), let agentToPhone {
                    try writeRequired(agentToPhone.convert(samples), to: rings[3])
                }
                if authorized.contains(.agentToUser), let agentToMonitor { try writeRequired(agentToMonitor.convert(samples), to: rings[5]) }
            }
        }
    }
    private func writeRequired(_ samples: [Float], to ring: AudioRing) throws {
        guard ring.write(samples, generation: generation) == samples.count else {
            cab_controls_cancel(controls)
            let message = "Audio queue overflowed. Audio stopped to avoid delayed or incomplete speech."
            do { try stopOwnedResources(); statusHandler?(.failed(message)) }
            catch { statusHandler?(.failed(message + " Cleanup: " + error.localizedDescription)); throw error }
            throw CallAudioError(message)
        }
    }
    private func tick() {
        guard let configuration, rings.count == 9 else { return }
        do {
            if tickNumber % 5 == 0 { try refreshPhysicalDevices() }
            let now = ProcessInfo.processInfo.systemUptime
            let liveQueues: [(Int, Double)] = [
                (0, callerIO?.format.mSampleRate ?? 48000),
                (1, microphoneIO?.format.mSampleRate ?? 48000),
                (2, 48000), (4, monitorIO?.format.mSampleRate ?? 48000), (7, 24000), (8, 24000)
            ]
            let backlog = liveQueues.map { Double(cab_ring_queued_frames(rings[$0.0].pointer)) / $0.1 }.max() ?? 0
            let overflow = rings.reduce(UInt64(0)) { $0 + cab_ring_counters($1.pointer).overflow_frames }
            try AudioBufferHealth.validate(overflowFrames: overflow - min(overflow, overflowAllowance),
                                           workerDelay: now - lastWorkerTick, captureBacklog: backlog)
            lastWorkerTick = now
            tickNumber &+= 1
            let caller = rings[0].read(8192, generation: generation)
            let microphone = rings[1].read(8192, generation: generation)
            callerMeterWindow.observe(caller); microphoneMeterWindow.observe(microphone)
            if let callerToModel { try writeRequired(callerToModel.convert(caller), to: rings[7]) }
            if let callerToMonitor, configuration.manageCallerListening {
                try writeRequired(callerToMonitor.convert(caller), to: rings[4])
            }
            if let microphoneToModel { try writeRequired(microphoneToModel.convert(microphone), to: rings[8]) }
            if let microphoneToPhone { try writeRequired(microphoneToPhone.convert(microphone), to: rings[2]) }
            let remote = rings[7].read(480, generation: generation)
            let local = rings[8].read(480, generation: generation)
            let routes = CallAudioRoutes(rawValue: cab_controls_routes(controls))
            if let transcriptionHandler, !epoch.isEmpty {
                transcriptionHandler(routes.contains(.callerToAgent) ? remote : nil,
                                     routes.contains(.microphoneToAgent) ? local : nil)
            }
            if !epoch.isEmpty, configuration.phoneRouting?.needsVoice == true || !routes.intersection([.callerToAgent, .microphoneToAgent]).isEmpty {
                // The voice protocol needs a clock even in output-only mode.
                // With no authorized inputs, the mixer emits only zero PCM.
                ModelFrameMixer.render(caller: remote, microphone: local, frames: 480, routes: routes,
                    callerGain: Float(liveTuning?[.callerToAgent] ?? Double(callerGain)),
                    microphoneGain: Float(liveTuning?[.microphoneToAgent] ?? Double(microphoneGain))) { pcm in
                    modelHandler?(CallAudioPacket(pcm16: pcm, epoch: epoch, startSample: samplePosition))
                }
            }
            samplePosition &+= 480
            if tickNumber % 10 == 0 {
                let counters = rings.map { cab_ring_counters($0.pointer) }
                let phone = phoneIO?.takePhoneOutputMetrics() ?? CABPhoneOutputSnapshot()
                metersHandler?(CallAudioMeters(caller: callerMeterWindow.peak,
                    microphone: microphoneMeterWindow.peak, agent: latestAgentPeak,
                    droppedFrames: counters.reduce(0) { $0 + $1.overflow_frames },
                    outputUnderrunFrames: phone.microphone_underrun_frames + phone.agent_underrun_frames,
                    microphoneOutputUnderrunFrames: phone.microphone_underrun_frames,
                    agentOutputUnderrunFrames: phone.agent_underrun_frames,
                    microphoneCaptureFrames: microphoneMeterWindow.frames, callerCaptureFrames: callerMeterWindow.frames,
                    renderedPhonePeak: phone.peak, renderedPhoneRMS: phone.rms,
                    renderedPhoneFrames: phone.rendered_frames, renderedPhoneDroppedTelemetryBlocks: phone.dropped_blocks,
                    phoneReadbackPeak: phone.readback_peak, phoneReadbackRMS: phone.readback_rms,
                    phoneReadbackFrames: phone.readback_frames, phoneReadbackZeroFrames: phone.readback_zero_frames,
                    phoneReadbackUnavailableBlocks: phone.readback_unavailable_blocks))
                callerMeterWindow.reset(); microphoneMeterWindow.reset(); latestAgentPeak = 0
                try verifyRoutes()
            }
        } catch {
            let original = error.localizedDescription
            do { try stopOwnedResources(); statusHandler?(.failed(original)) }
            catch { statusHandler?(.failed(original + " Cleanup: " + error.localizedDescription)) }
        }
    }
    private func refreshPhysicalDevices() throws {
        guard let configuration, let callerIO, rings.count == 9 else { return }
        let revision = lifecycleRevision
        let transition = DeviceTransitionGate(controlsOwner)
        var completed = false
        let prepare = { transition.begin() }
        defer {
            if transition.changed {
                flushBuffers()
                for index in [0, 1, 7, 8] { _ = rings[index].read(48000, generation: generation) }
                overflowAllowance = rings.reduce(0) { $0 + cab_ring_counters($1.pointer).overflow_frames }
                lastWorkerTick = ProcessInfo.processInfo.systemUptime
                lastCaptureTime = lastWorkerTick
                lastCaptureFrames = cab_ring_counters(rings[0].pointer).accepted_frames
                transition.finish(success: completed) { updateControls() }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        let micChanged = try microphoneDevice.refresh(selection: .init(uid: configuration.microphoneUID),
            enabled: configuration.usesMicrophone, now: now,
            resolve: { try CallHardware.endpoint($0, scope: kAudioDevicePropertyScopeInput) },
            make: { try InputIO(device: $0.id, ring: self.rings[1]) }, willChange: prepare,
            didClose: { _ = self.rings[1].read(48000, generation: self.generation) },
            isCancelled: { self.lifecycleRevision != revision })
        let monitorChanged = try listeningDevice.refresh(selection: .init(uid: configuration.monitorOutputUID),
            enabled: configuration.needsListeningDevice, now: now,
            resolve: { try CallHardware.endpoint($0, scope: kAudioDevicePropertyScopeOutput) },
            make: { try OutputIO(device: $0.id, kind: .monitor, first: self.rings[4], second: self.rings[5], third: self.rings[6], controls: self.controlsOwner) },
            willChange: prepare, didClose: {
                for index in [4, 5, 6] { _ = self.rings[index].read(48000, generation: self.generation) }
            }, isCancelled: { self.lifecycleRevision != revision })
        if micChanged {
            microphoneToModel = try microphoneIO.map { try MonoConverter(from: $0.format.mSampleRate, to: 24000) }
            microphoneToPhone = try microphoneIO.map { try MonoConverter(from: $0.format.mSampleRate, to: 48000) }
        }
        if monitorChanged {
            callerToMonitor = try monitorIO.map { try MonoConverter(from: callerIO.format.mSampleRate, to: $0.format.mSampleRate) }
            agentToMonitor = try monitorIO.map { try MonoConverter(from: 24000, to: $0.format.mSampleRate) }
            ownerToMonitor = try monitorIO.map { try MonoConverter(from: 24000, to: $0.format.mSampleRate) }
        }
        let message = "Microphone: " + (microphoneDevice.target?.name ?? (configuration.usesMicrophone ? "waiting for Mac selection" : "off"))
            + " · Listening: " + (listeningDevice.target?.name ?? (configuration.needsListeningDevice ? "waiting for Mac selection" : "off"))
        if message != lastDeviceStatus { lastDeviceStatus = message; deviceStatusHandler?(message) }
        completed = true
    }
    private func verifyRoutes() throws {
        guard let configuration, let phoneIO, let callerIO, let tap else { throw CallAudioError("Audio route ownership was lost.") }
        guard try CallHardware.sendDevice(configuration.virtualOutputUID) == phoneIO.device else {
            throw CallAudioError("The Phone Assistant device reconnected. Connect Phone audio again.")
        }
        guard phoneIO.formatIsCurrent() else {
            throw CallAudioError("The Phone Assistant output format changed. Connect Phone audio again.")
        }
        guard callerIO.formatIsCurrent() else {
            throw CallAudioError("The incoming call audio format changed. Connect Phone audio again.")
        }
        guard try CallHardware.phoneProcess() == tap.process else {
            throw CallAudioError("Phone restarted its call audio. Connect Phone audio again.")
        }
        if configuration.requirePhoneInput { try CallHardware.verifyPhoneInput(process: tap.process, uid: configuration.virtualOutputUID) }
        let frames = cab_ring_counters(rings[0].pointer).accepted_frames
        if frames != lastCaptureFrames { lastCaptureFrames = frames; lastCaptureTime = ProcessInfo.processInfo.systemUptime }
        guard ProcessInfo.processInfo.systemUptime - lastCaptureTime < 2 else { throw CallAudioError("Caller capture buffers stopped arriving.") }
    }
    public func stop() {
        try? stopAndReport()
    }
    public func stopAndReport() throws {
        cab_controls_cancel(controls)
        try sync {
            do { try stopOwnedResources(); statusHandler?(.stopped) }
            catch { statusHandler?(.failed(error.localizedDescription)); throw error }
        }
    }
    /// Immediate fail-closed gate for UI deadlines. Resource teardown follows on
    /// the worker without blocking the caller. A cancelled start cannot enable
    /// routes after returning from a slow Core Audio call.
    public func stopAsync(completion: (() -> Void)? = nil) {
        cab_controls_cancel(controls)
        worker.async { [weak self] in
            guard let self else { completion?(); return }
            do { try self.stopOwnedResources(); self.statusHandler?(.stopped) }
            catch { self.statusHandler?(.failed(error.localizedDescription)) }
            completion?()
        }
    }
    private func stopOwnedResources() throws {
        timer?.cancel(); timer = nil
        cab_controls_set_routes(controls, 0)
        flushBuffers(); epoch = ""; streamGate.transition(to: "")
        var failures: [String] = []
        func attempt(_ operation: () throws -> Void) { do { try operation() } catch { failures.append(error.localizedDescription) } }
        // Stop capture before its owned tap is destroyed, and stop every endpoint
        // even if a different device has disappeared. Destroying the tap restores
        // Phone's normal output when managed caller listening was active.
        attempt { try callerIO?.close() }; attempt { try microphoneDevice.reset() }
        attempt { try phoneIO?.close() }; attempt { try listeningDevice.reset() }
        attempt { try tap?.close() }
        if failures.isEmpty {
            callerIO = nil; phoneIO = nil; tap = nil
            rings.removeAll(); configuration = nil
            callerToModel = nil; callerToMonitor = nil; microphoneToModel = nil; microphoneToPhone = nil
            agentToPhone = nil; agentToMonitor = nil; ownerToMonitor = nil
        }
        if !failures.isEmpty { throw CallAudioError(failures.joined(separator: " ")) }
    }
    // A callback that HAL fails to destroy retains its endpoint, rings and
    // controls owner. Those allocations remain valid until HAL releases it.
    deinit { sync { try? stopOwnedResources() } }
}
