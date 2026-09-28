import AppKit
import AVFoundation
import CallAudio
import CallAutomation
import CallPreferences
import CallTranscription
import CallVoice
import Combine

@MainActor final class PhoneBridgeStore: ObservableObject {
    @Published private(set) var routing = PhoneRouting()
    @Published private(set) var active = false
    @Published private(set) var busy = false
    @Published private(set) var needsCleanup = false
    @Published private(set) var status = "Start or answer a call in Phone, then connect here."
    @Published private(set) var voiceStatus = "Not connected"
    @Published private(set) var devices = ""
    @Published private(set) var error = ""
    @Published private(set) var muted = false
    @Published private(set) var callerPeak: Float = 0
    @Published private(set) var microphonePeak: Float = 0
    @Published var tuning = CallAudioTuning()
    var microphoneGain: Double { tuning[.microphoneToCaller] }
    @Published var selectedMicrophoneUID = ""
    @Published var selectedMonitorUID = ""
    @Published var nativeCallerPlayback = false
    @Published var liveMeters = CallAudioMeters()
    @Published var availableDevices: [AudioDevice] = []
    @Published var hardwareLevels: [LiveHardwareLevel] = []
    @Published var controlMessage = ""
    var refreshingControls = false
    @Published private(set) var agentPeak: Float = 0
    @Published var task = "Help the user with this telephone conversation."
    // Codex supplies the task. These fields are display metadata, never authority
    // from the remote caller and never audio configuration.
    @Published var codexTaskTitle = ""
    @Published var codexOriginThreadID = ""
    @Published var codexSessionID = ""
    @Published var codexQuestion = ""
    @Published var codexDeliveryStatus = ""
    var onDelegateTool: (@Sendable (String, String, String) async throws -> String)?
    /// Receives each transcript delta: text, whether the assistant said it, and
    /// whether the user's microphone was mixed into what the assistant heard.
    var onTranscript: ((String, Bool, Bool) -> Void)?
    /// Finalized on-device lines for the caller and the user. When set, each
    /// call also tries to transcribe the two sources separately (macOS 26+).
    var onTranscribedLine: ((TranscribedLine) -> Void)?
    private var transcription: CallTranscription?
    /// True while on-device transcription labels the caller and the user; the
    /// assistant's own words still come from the voice session.
    var speakerLabeled: Bool { transcription != nil }
    // Kept in the Keychain (see APIKeyStore). Never included in preferences, logs, or the bundle.
    @Published private(set) var apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    /// False when the key could not be written to the Keychain and lasts only until quit.
    @Published private(set) var keySaved = true
    var keyAvailable: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canStop: Bool { active || busy || needsCleanup }
    let runtime = CallAudioRuntime()
    private let microphoneOwner = UUID()
    private let sender = BoundedAudioSender()
    private let queue = DispatchQueue(label: "com.codexcall.phone-bridge", qos: .userInitiated)
    private var voice: LiveVoiceSession?
    private var cleanup: Task<Bool, Never>?
    private var operation: UInt64 = 0
    private var epoch = ""
    private var sequence: UInt64 = 0
    private var transcript = ""
    private var lastTranscriptWasAssistant: Bool?
    private var runID: UUID?
    var diagnosticReport: PhoneTestReport?
    private var lastReportWrite = Date.distantPast
    private let reportQueue = DispatchQueue(label: "com.codexcall.phone-bridge-report", qos: .utility)
    private let microphoneGainKey = "phoneBridgeMicrophoneGain"

    init(loadsSavedKey: Bool = true) {
        // An OPENAI_API_KEY from the environment is used as-is and never saved.
        if !apiKey.isEmpty { keySaved = false }
        else if loadsSavedKey, let saved = APIKeyStore.load() { apiKey = saved }
        if let saved = UserDefaults.standard.object(forKey: microphoneGainKey) as? Double, saved.isFinite {
            tuning = .init(microphoneGain: min(4, max(0, saved)))
        }
        sender.onFailure = { [weak self] epoch, message in
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                self.fail(message)
            }
        }
    }
    func start(profile: AssistantPreferences) async {
        guard !canStop else { return }
        guard !routing.needsVoice || keyAvailable else { error = "Add an API key in Settings → Connections to use the assistant."; return }
        operation &+= 1; let version = operation
        let run = UUID(); runID = run
        busy = true; error = ""; muted = false; liveMeters = .init()
        epoch = UUID().uuidString; sequence = 0; transcript = ""; lastTranscriptWasAssistant = nil
        status = "Checking Phone's microphone and connecting audio…"
        diagnosticReport = PhoneTestReport(nativePlayback: nativeCallerPlayback && routing.listener.includesUser,
            microphoneEnabled: routing.speaker.includesUser, microphoneGain: microphoneGain, callerGain: 1,
            origin: .phoneBridge)
        recordRouting()
        diagnosticReport?.setLiveTuning(tuning)
        do {
            try await requireMicrophone(for: routing)
            guard operation == version else { return }
            status = "Selecting Phone’s microphone…"
            try await PhoneMicrophoneAutomation.shared.connect(owner: microphoneOwner)
            guard operation == version else { return }
            // Everyday calls follow macOS. Advanced application-test choices
            // belong to that test and must not silently pin the phone's mic.
            let configuration = CallAudioConfiguration(virtualOutputUID: ApplicationAudioRuntime.sendDeviceUID,
                microphoneUID: selectedMicrophoneUID.isEmpty ? nil : selectedMicrophoneUID,
                monitorOutputUID: selectedMonitorUID.isEmpty ? nil : selectedMonitorUID,
                microphoneEnabled: routing.speaker.includesUser,
                manageCallerListening: !(nativeCallerPlayback && routing.listener.includesUser),
                phoneRouting: routing, requirePhoneInput: true)
            let nextEpoch = epoch, revision = runtime.lifecycleRevision, selectedTuning = tuning
            let sender = self.sender
            try await control { [weak self] engine in
                engine.onStatus = { state in
                    if case .failed(let message) = state {
                        Task { @MainActor in guard let self, self.runID == run else { return }; self.fail(message) }
                    }
                }
                engine.onDeviceStatus = { message in
                    Task { @MainActor in
                        guard let self, self.runID == run else { return }
                        self.devices = message
                        self.diagnosticReport?.event("devices", detail: message)
                        self.saveDiagnosticReport(force: true)
                    }
                }
                engine.onMeters = { meters in
                    Task { @MainActor in
                        guard let self, self.runID == run else { return }
                        self.callerPeak = meters.caller; self.microphonePeak = meters.microphone; self.agentPeak = meters.agent
                        self.liveMeters = meters
                        self.diagnosticReport?.append(meters: meters, muted: self.muted, now: meters.measuredAt)
                        self.saveDiagnosticReport()
                    }
                }
                engine.onModelPCM = { packet in sender.enqueue(packet.pcm16, epoch: packet.epoch) }
                engine.setCallerListeningEnabled(true); engine.setAgentMonitoringEnabled(true)
                engine.setLiveTuning(selectedTuning)
                try engine.start(configuration: configuration, epoch: nextEpoch, expectedLifecycleRevision: revision)
            }
            guard operation == version else { return }
            active = true
            try await connectVoice(profile: profile, version: version)
            guard operation == version else { return }
            runtime.setSendMuted(muted)
            busy = false; status = "Connected. Phone is using Phone Assistant."
            diagnosticReport?.event("running")
            saveDiagnosticReport(force: true)
            await startTranscription(run: run)
        } catch { if operation == version { fail(error.localizedDescription) } }
    }

    func changeRouting(_ next: PhoneRouting, profile: AssistantPreferences) async {
        guard !busy, next != routing else { return }
        guard !active else { await changeActiveRouting(next, profile: profile); return }
        routing = next; error = ""
        if !next.listener.includesUser { nativeCallerPlayback = false }
    }
    private func changeActiveRouting(_ next: PhoneRouting, profile: AssistantPreferences) async {
        guard !next.needsVoice || keyAvailable else { error = "Add an API key in Settings → Connections to use the assistant."; return }
        busy = true
        // Close all destinations before awaiting permission, network, or HAL.
        let revision = runtime.suspendRouting()
        // Adding/removing local listening does not replace the model or expose
        // new input to it. Keep the current voice conversation and its context.
        if next.speaker == routing.speaker && next.listener.includesAgent == routing.listener.includesAgent {
            let version = operation, nextEpoch = epoch
            do {
                try await control { try $0.applyPhoneRouting(next, epoch: nextEpoch, expectedRevision: revision) }
                guard operation == version else { return }
                routing = next; busy = false; status = "Connected. Listening updated."
                if !next.listener.includesUser { nativeCallerPlayback = false }
                recordRouting()
                // Same session, new situation: tell the assistant who is listening now.
                // Best effort; the call continues if this instruction can't be sent.
                try? await voice?.instruct(next.instructions(ownerName: profile.normalized().ownerName))
            } catch { if operation == version { fail(error.localizedDescription) } }
            return
        }
        sender.close(); operation &+= 1; let version = operation
        let oldVoice = voice; voice = nil; await oldVoice?.close()
        do {
            try await requireMicrophone(for: next)
            guard operation == version else { return }
            routing = next; epoch = UUID().uuidString; sequence = 0
            let nextEpoch = epoch
            runtime.setSendMuted(true)
            try await control { try $0.applyPhoneRouting(next, epoch: nextEpoch, expectedRevision: revision) }
            guard operation == version else { return }
            try await connectVoice(profile: profile, version: version)
            guard operation == version else { return }
            runtime.setSendMuted(muted)
            if !next.listener.includesUser { nativeCallerPlayback = false }
            busy = false; status = "Connected. Audio choices updated."
            recordRouting()
        } catch { if operation == version { fail(error.localizedDescription) } }
    }

    private func connectVoice(profile: AssistantPreferences, version: UInt64) async throws {
        guard routing.needsVoice else { voiceStatus = "Off. This conversation stays between you and the caller."; return }
        voiceStatus = "Connecting the assistant…"
        let packetEpoch = epoch
        let session = LiveVoiceSession(audio: { [weak self] pcm in
            guard let self else { return }
            try await self.generated(pcm, version: version, epoch: packetEpoch)
        }, transcript: { [weak self] text, isAssistant in
            await self?.remember(text, isAssistant: isAssistant, version: version)
        }, failure: { [weak self] message in
            await self?.voiceFailed(message, version: version)
        }, delegation: onDelegateTool)
        voice = session
        let modeInstructions = routing.instructions(ownerName: profile.normalized().ownerName)
        let instructions = profile.sessionInstructions + "\n" + modeInstructions
            + "\nYou are on an actual telephone call. Follow this task: " + String(task.prefix(16000))
            + "\nNever claim to control audio routes or to have completed an external action without confirmation."
            + (onDelegateTool == nil ? "" : "\nWhen facts or decisions are missing, use your text delegate's ask_codex tool to consult the originating Codex task. Wait for its scoped answer. Use report_call_result to return a factual summary when the task is complete. Neither tool dials or hangs up Phone.")
            + (routing.listener.includesAgent ? " Wait for caller speech before beginning." : " You cannot hear the call in this mode. Use the task to decide what to say; do not invent replies from the caller.")
        try await session.connect(key: apiKey, instructions: instructions, context: transcript)
        guard operation == version, voice === session else { await session.close(); return }
        sender.open(epoch: packetEpoch) { message in
            guard case .string(let text) = message,
                  let event = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let encoded = event["audio"] as? String else { throw LiveVoiceError("Invalid native audio frame") }
            try await session.sendInput(encoded)
        }
        voiceStatus = routing.speaker.includesAgent ? "Assistant connected" : "Assistant listening silently"
        try await session.instruct(modeInstructions)
    }
    private func generated(_ pcm: Data, version: UInt64, epoch packetEpoch: String) async throws {
        guard operation == version, active, epoch == packetEpoch else { return }
        // Agent speech is discarded in user-only sending, never queued to resume.
        guard routing.speaker.includesAgent else { return }
        let next = sequence; sequence &+= 1
        try await control { try $0.submitAgentPCM(pcm, epoch: packetEpoch, sequence: next) }
    }
    private func remember(_ text: String, isAssistant: Bool, version: UInt64) {
        guard operation == version, active else { return }
        if isAssistant && !routing.speaker.includesAgent { return }
        if lastTranscriptWasAssistant != isAssistant {
            transcript += isAssistant ? "\nAssistant: " : "\nHeard on the call: "
            lastTranscriptWasAssistant = isAssistant
        }
        transcript = String((transcript + text).suffix(12000))
        onTranscript?(text, isAssistant, routing.routes.contains(.microphoneToAgent))
    }
    private func voiceFailed(_ message: String, version: UInt64) {
        guard operation == version else { return }; fail(message)
    }
    private func requireMicrophone(for routing: PhoneRouting) async throws {
        guard routing.speaker.includesUser else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw LiveVoiceError("Enable microphone access in Permissions to speak on the call.") }
    }
    func setAPIKey(_ key: String) {
        guard !canStop else { return }
        apiKey = key
        keySaved = APIKeyStore.save(key)
    }
    func removeAPIKey() {
        guard !canStop else { return }
        apiKey = ""; keySaved = true
        APIKeyStore.delete()
    }
    func setMuted(_ value: Bool) {
        muted = value; runtime.setSendMuted(value)
        guard canStop else { return }
        diagnosticReport?.event(value ? "muted" : "unmuted")
        saveDiagnosticReport(force: true)
    }
    func deliverCodexAnswer(_ text: String) async throws {
        guard active, !busy, let voice else { throw LiveVoiceError("The voice session is not ready. The answer has not been delivered.") }
        try await voice.instruct("The originating Codex task answered your question. Treat this as scoped context for the existing task: " + text)
    }
    func setMicrophoneGain(_ value: Double) {
        setLevel(value, path: .microphoneToCaller)
    }
    private func startTranscription(run: UUID) async {
        // Lines stay with the session that started them, even if they finalize
        // after the next call has bound a new handler.
        guard let deliver = onTranscribedLine, !codexSessionID.isEmpty, transcription == nil else { return }
        let session = await CallTranscription.start { line in
            Task { @MainActor in deliver(line) }
        }
        guard let session else { return }
        // The call may have ended while the speech model loaded.
        guard runID == run, active else { await session.finish(timeout: 0); return }
        transcription = session
        runtime.onTranscriptionAudio = { caller, microphone in session.append(caller: caller, microphone: microphone) }
    }
    private func stopTranscription() {
        runtime.onTranscriptionAudio = nil
        guard let session = transcription else { return }
        transcription = nil
        Task { await session.finish() }
    }
    func stop() {
        stopTranscription()
        runtime.stopAsync(); sender.close(); operation &+= 1; epoch = ""
        runID = nil
        diagnosticReport?.event("stopping")
        saveDiagnosticReport(force: true)
        let version = operation, oldVoice = voice; voice = nil
        active = false; busy = true; status = "Disconnecting audio…"
        voiceStatus = "Not connected"; devices = ""
        callerPeak = 0; microphonePeak = 0; agentPeak = 0
        cleanup = Task {
            await oldVoice?.close()
            let result: Result<Void, Error>
            do {
                try await self.control { try $0.stopAndReport() }
                try await PhoneMicrophoneAutomation.shared.disconnect(owner: self.microphoneOwner)
                result = .success(())
            }
            catch { result = .failure(error) }
            guard self.operation == version else { return false }
            self.busy = false
            switch result {
            case .success:
                self.diagnosticReport?.event("stopped"); self.saveDiagnosticReport(force: true)
                self.needsCleanup = false; self.status = "Disconnected. Phone's audio is restored."; return true
            case .failure(let failure):
                self.diagnosticReport?.event("failed", detail: "Audio cleanup did not complete.")
                self.saveDiagnosticReport(force: true)
                self.needsCleanup = true; self.error = failure.localizedDescription; return false
            }
        }
    }
    func stopAndWait() async -> Bool {
        stop()
        let result = await cleanup?.value ?? false
        await withCheckedContinuation { continuation in reportQueue.async { continuation.resume() } }
        return result
    }
    private func fail(_ message: String) {
        // Provider errors may contain arbitrary remote text. Persist a fixed
        // lifecycle label, never model text, prompts, transcripts, or credentials.
        diagnosticReport?.event("failed", detail: "The Phone bridge reported a connection error.")
        stop(); error = LiveVoiceError(message).message
    }
    private func recordRouting() {
        diagnosticReport?.setNativePlayback(nativeCallerPlayback && routing.listener.includesUser)
        diagnosticReport?.event("routing", detail: "Speaker: \(routing.speaker.rawValue); listener: \(routing.listener.rawValue)")
        saveDiagnosticReport(force: true)
    }
    func saveDiagnosticReport(force: Bool = false) {
        guard let report = diagnosticReport else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastReportWrite) >= 1 else { return }
        lastReportWrite = now
        // Bounded scalar snapshots only; disk work never runs on the audio
        // worker, and a diagnostic write failure cannot interrupt the call.
        reportQueue.async { try? PhoneTestReportStorage.save(report, to: PhoneTestReportStorage.bridgeURL) }
    }
    func applyLiveRouteChange(_ action: @escaping (CallAudioRuntime) throws -> Void) async -> Bool {
        guard active, !busy else { return !canStop }
        busy = true
        let version = operation, revision = runtime.lifecycleRevision
        do {
            try await control { engine in
                guard engine.lifecycleRevision == revision else { throw CallAudioError("Audio change was cancelled.") }
                try action(engine)
                guard engine.lifecycleRevision == revision else { throw CallAudioError("Audio change was cancelled.") }
            }
            guard operation == version else { return false }
            busy = false; return true
        } catch {
            if operation == version { fail(error.localizedDescription) }
            return false
        }
    }
    func control<T>(_ operation: @escaping (CallAudioRuntime) throws -> T) async throws -> T {
        let runtime = runtime
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation(runtime) }) }
        }
    }
}
