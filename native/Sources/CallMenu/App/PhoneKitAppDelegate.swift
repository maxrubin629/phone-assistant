import AppKit
import CallAutomation

/// AppKit supplies orderly quit handling; SwiftUI owns all visible state.
@MainActor final class PhoneKitAppDelegate: NSObject, NSApplicationDelegate {
    var requestStop: (() async -> Bool)?
    private var terminating = false
    var notch: CallNotchController?
    var didPrepareControls = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--check-phone-selection"),
           CommandLine.arguments.count > index + 1 {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                var report: [String: String]
                do {
                    report = try await PhoneMicrophoneAutomation.shared.checkSelectionAndRestoration()
                    report["result"] = "passed"
                } catch { report = ["result": "failed", "error": error.localizedDescription] }
                do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic) }
                catch { fputs("Could not write Phone selection check: \(error.localizedDescription)\n", stderr) }
                exit(report["result"] == "passed" ? 0 : 1)
            }
        }
        #endif
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let requestStop else { return .terminateNow }
        terminating = true
        Task {
            let success = await requestStop()
            terminating = false
            NSApp.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }
}
