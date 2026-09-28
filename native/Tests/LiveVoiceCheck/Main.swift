import Foundation
import CallVoice

actor Probe {
    var bytes = 0
    var failure: String?
    func received(_ pcm: Data) { bytes += pcm.count }
    func failed(_ message: String) { failure = message }
}

@main struct LiveVoiceCheck {
    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            print("Missing OPENAI_API_KEY in process environment"); exit(2)
        }
        let probe = Probe()
        let session = LiveVoiceSession(audio: { await probe.received($0) }, failure: { await probe.failed($0) })
        do {
            try await session.connect(key: key, instructions: "This is a synthetic connection test. Say only: The audio bridge is connected.")
            try await session.instruct("Say: The audio bridge is connected.")
            let silence = Data(repeating: 0, count: 960).base64EncodedString()
            for _ in 0..<500 {
                if await probe.bytes > 0 { break }
                if let failure = await probe.failure { throw LiveVoiceError(failure) }
                try await session.sendInput(silence)
                try await Task.sleep(for: .milliseconds(20))
            }
            await session.close()
            let count = await probe.bytes
            guard count > 0 else { throw LiveVoiceError("Connected, but received no generated PCM") }
            print("PASS: native Swift client received \(count) bytes of generated PCM. No microphone, Phone capture, speaker playback, or call was used.")
        } catch {
            await session.close()
            print("FAIL: " + LiveVoiceError(error.localizedDescription).message); exit(1)
        }
    }
}
