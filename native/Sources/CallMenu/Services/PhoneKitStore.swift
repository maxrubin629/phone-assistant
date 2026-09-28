import AppKit
import AVFoundation
import CallAudio
import Combine

@MainActor final class PhoneKitStore: ObservableObject {
    @Published private(set) var status: PhoneKitStatus?
    @Published private(set) var busy = false
    @Published private(set) var checkingAudio = false
    @Published private(set) var needsAudioCleanup = false
    @Published private(set) var audioVerified = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var message = "Checking bundled Phone Assistant Audio Bridge…"
    @Published private(set) var audioMessage = "Allow capture of the app you choose. Your screen is never captured."
    @Published private(set) var error = ""
    private let queue = DispatchQueue(label: "com.codexcall.phonekit.setup", qos: .userInitiated)
    private var probe: AudioAccessProbe?
    private var audioTask: Task<Void, Never>?
    private var refreshing = false

    var ready: Bool { status?.bundledValid == true && status?.installedValid == true && status?.loaded == true }
    var microphoneDenied: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .denied }

    init() { refresh() }

    func refresh() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard !refreshing, !busy else { return }
        refreshing = true
        queue.async { [weak self] in
            let result = Result { try PhoneKitOperations.status() }
            Task { @MainActor in
                guard let self else { return }
                self.refreshing = false
                switch result {
                case .success(let value):
                    self.status = value; self.message = value.message
                    if value.loaded && value.installedValid { self.error = "" }
                case .failure(let failure): self.error = failure.localizedDescription; self.message = "Phone Assistant Audio Bridge needs attention"
                }
            }
        }
    }

    func install() {
        guard !busy else { return }
        busy = true; error = ""; message = "Waiting for macOS approval…"
        queue.async { [weak self] in
            let result = Result { try PhoneKitOperations.install(); return try PhoneKitOperations.status() }
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let value): self.status = value; self.message = value.loaded ? "Phone Assistant Audio Bridge is ready" : value.message
                case .failure(let failure): self.error = failure.localizedDescription; self.message = "Setup did not finish"; self.refresh()
                }
            }
        }
    }

    func requestAudio() {
        guard ready, !busy, !needsAudioCleanup else { return }
        busy = true; checkingAudio = true; error = ""
        audioMessage = "Approve System Audio Access in macOS. Checking a private test signal…"
        let probe = AudioAccessProbe(); self.probe = probe
        audioTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<Bool, Error> = await withCheckedContinuation { continuation in
                self.queue.async { continuation.resume(returning: Result { try probe.run() }) }
            }
            self.needsAudioCleanup = probe.cleanupFailed
            if !self.needsAudioCleanup { self.probe = nil }
            self.busy = false; self.checkingAudio = false
            switch result {
            case .success(true): self.audioVerified = true; self.audioMessage = "System audio access confirmed with a private test signal."
            case .success(false): self.audioVerified = false; self.audioMessage = "Audio access is not confirmed. Check the macOS permission, then try again."
            case .failure(let failure): self.audioVerified = false; self.audioMessage = failure.localizedDescription
            }
        }
    }

    func cancelAudioCheck() { probe?.cancel() }
    func stopAudioAndWait() async -> Bool {
        probe?.cancel()
        await audioTask?.value
        guard let probe, needsAudioCleanup else { return true }
        busy = true
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Result { try probe.cleanup() }) }
        }
        busy = false
        switch result {
        case .success: self.probe = nil; needsAudioCleanup = false; return true
        case .failure(let failure): audioMessage = failure.localizedDescription; return false
        }
    }
    func confirmCapturedAudio() { audioVerified = true; audioMessage = "System audio access confirmed by application audio." }

    func requestMicrophone() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            microphoneAuthorized = await AVCaptureDevice.requestAccess(for: .audio)
        } else { microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
        if !microphoneAuthorized { openMicrophoneSettings() }
    }
    func openAudioSettings() { openSettings("Privacy_ScreenCapture") }
    func openMicrophoneSettings() { openSettings("Privacy_Microphone") }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
