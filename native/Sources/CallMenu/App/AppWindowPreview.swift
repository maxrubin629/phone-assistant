import AppKit
import CallHistory
import CallPreferences
import SwiftUI

/// Development renderer: `CallMenu --window-preview <directory>` draws the app
/// window (call history and onboarding) and each Settings page in light and dark
/// appearance and writes PNGs. It uses temporary history and preference storage,
/// never starts audio, and never changes saved calls or settings.
enum AppWindowPreview {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--window-preview") else { return }
        let directory = URL(fileURLWithPath: arguments.indices.contains(index + 1) ? arguments[index + 1] : ".")
        let only = arguments.firstIndex(of: "--only").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        MainActor.assumeIsolated { render(to: directory, only: only) }
    }

    private struct Page {
        let name: String
        let size: CGSize
        let view: AnyView
    }

    @MainActor private static func render(to output: URL, only: String?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("window-preview-" + UUID().uuidString)
        let files = CallHistoryFiles(directory: storage)
        for call in sampleCalls() { try? files.save(call) }
        let suite = "com.codexcall.window-preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let history = CallHistoryStore(files: files, defaults: defaults)
        let emptyHistory = CallHistoryStore(files: CallHistoryFiles(directory: storage.appendingPathComponent("empty")), defaults: defaults)
        let kit = PhoneKitStore(), bridge = PhoneBridgeStore(loadsSavedKey: false)
        let routing = RoutingStore(defaults: defaults)
        func assistant(_ step: SetupStep?) -> AssistantStore {
            let store = AssistantStore(defaults: defaults)
            store.preferences.name = "Alex"; store.preferences.ownerName = "Sam"
            if let step { store.preferences.setupStep = step }
            return store
        }
        let settled = assistant(nil)
        // Settings pages use the same content sizes as CallSettingsView, plus the title bar.
        func setting(_ name: String, _ width: CGFloat, _ height: CGFloat, _ view: some View) -> Page {
            Page(name: "settings-" + name, size: CGSize(width: width, height: height + 28), view: AnyView(view))
        }
        var pages = [
            Page(name: "history", size: CGSize(width: 1000, height: 1100), view: AnyView(CallHistoryView(history: history))),
            setting("assistant", 600, 470, AssistantSettingsView(preferences: .constant(settled.preferences))),
            setting("connections", 600, 420, ConnectionsSettingsView(bridge: bridge)),
            setting("history", 600, 330, HistorySettingsView(history: history)),
            setting("audio", 600, 520, PhoneKitSetupView(kit: kit, routingActive: false)),
            setting("troubleshooting", 640, 640, RoutingView(test: routing, kit: kit, callActive: false, showSetup: {}, openLiveControls: {})),
            Page(name: "history-empty", size: CGSize(width: 1000, height: 640), view: AnyView(CallHistoryView(history: emptyHistory))),
            Page(name: "live-controls", size: CGSize(width: 840, height: 720), view: AnyView(PhoneLiveControlsView(bridge: bridge, assistant: settled)))
        ]
        for step in [SetupStep.permissions, .assistant, .introduction] {
            pages.append(Page(name: "onboarding-" + step.rawValue, size: CGSize(width: 820, height: 700),
                view: AnyView(PhoneKitWindow(kit: kit, chrome: routing, assistant: assistant(step), bridge: bridge, history: history))))
        }
        if let only { pages = pages.filter { $0.name.hasPrefix(only) } }

        var windows: [(NSWindow, String)] = []
        for page in pages {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let controller = NSHostingController(rootView: page.view)
                controller.sceneBridgingOptions = [.toolbars, .title]
                let window = NSWindow(contentViewController: controller)
                if page.name.hasPrefix("settings") { window.title = "Settings" }
                if page.name == "live-controls" { window.title = "Live Audio Controls" }
                // navigationTitle reaches the title bar only inside a real scene.
                if page.name.hasPrefix("history") { window.title = "Calls" }
                if page.name.hasPrefix("onboarding") { window.title = "Welcome" }
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                window.appearance = NSAppearance(named: appearance)
                window.setFrame(CGRect(origin: CGPoint(x: -30000, y: -30000), size: page.size), display: true)
                window.orderFrontRegardless()
                windows.append((window, page.name + "-" + suffix))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else {
                fputs("Window capture is unavailable\n", stderr); exit(1)
            }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            for (window, name) in windows {
                guard let image = capture(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue(),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    fputs("Window capture failed\n", stderr); exit(1)
                }
                let url = output.appendingPathComponent(name + ".png")
                try? data.write(to: url)
                print(url.path)
            }
            try? FileManager.default.removeItem(at: storage)
            defaults.removePersistentDomain(forName: suite)
            exit(0)
        }
        app.run()
    }

    private static func sampleCalls() -> [CallRecord] {
        let now = Date()
        var dentist = CallRecord(id: UUID().uuidString, title: "Dentist appointment", task: "Call Bright Smile Dental and ask for a cleaning next week, mornings preferred. Return the options before booking.",
            phoneNumber: "+1 (415) 555-0132", originThreadID: UUID().uuidString, startedAt: now.addingTimeInterval(-3 * 3600))
        let t = dentist.startedAt
        dentist.append(CallEntry(kind: .event, text: "Connected · Assistant mode", at: t))
        dentist.appendSpeech("Bright Smile Dental, this is Maria.", kind: .caller, at: t.addingTimeInterval(3))
        dentist.appendSpeech("Hi Maria, I'm Alex, Sam's AI assistant. I'm calling to book a cleaning for Sam next week, ideally in the morning.", kind: .assistant, at: t.addingTimeInterval(6))
        dentist.appendSpeech("Sure. I have Tuesday at 9:30 or Thursday at 8:00.", kind: .caller, at: t.addingTimeInterval(18))
        dentist.append(CallEntry(kind: .question, text: "The office offers Tuesday 9:30 or Thursday 8:00. Which should I choose?", at: t.addingTimeInterval(24)))
        dentist.append(CallEntry(kind: .answer, text: "Tuesday at 9:30 works. Confirm under Sam Lee.", at: t.addingTimeInterval(51)))
        dentist.appendSpeech("Tuesday at 9:30 works. Could you book it under Sam Lee?", kind: .assistant, at: t.addingTimeInterval(54))
        dentist.append(CallEntry(kind: .event, text: "Switched to Join mode", at: t.addingTimeInterval(60)))
        dentist.insert(CallEntry(kind: .user, text: "Thanks! Could you text me a reminder the day before?", at: t.addingTimeInterval(62)))
        dentist.insert(CallEntry(kind: .caller, text: "Of course. You're all set for Tuesday at 9:30.", at: t.addingTimeInterval(66)))
        dentist.append(CallEntry(kind: .event, text: "Result reported", at: t.addingTimeInterval(75)))
        dentist.summary = "Booked a cleaning for Sam Lee on Tuesday at 9:30 AM. No deposit required. The office will text a reminder the day before."
        dentist.outcome = .ended; dentist.endedAt = t.addingTimeInterval(96)

        var pharmacy = CallRecord(id: UUID().uuidString, title: "Pharmacy refill status", task: "Ask whether the refill is ready.",
            phoneNumber: nil, originThreadID: UUID().uuidString, startedAt: now.addingTimeInterval(-26 * 3600))
        pharmacy.outcome = .failed; pharmacy.endedAt = pharmacy.startedAt.addingTimeInterval(12)
        pharmacy.transcriptSaved = false

        var plumber = CallRecord(id: UUID().uuidString, title: "Plumber quote", task: "Get a quote for replacing a kitchen faucet.",
            phoneNumber: "+1 (510) 555-0199", originThreadID: UUID().uuidString, startedAt: now.addingTimeInterval(-4 * 86400))
        plumber.appendSpeech("Faucet replacement is $180 plus parts.", kind: .caller, at: plumber.startedAt.addingTimeInterval(20))
        plumber.summary = "Quoted $180 plus parts; earliest visit Friday."
        plumber.outcome = .ended; plumber.endedAt = plumber.startedAt.addingTimeInterval(140)
        return [dentist, pharmacy, plumber]
    }
}
