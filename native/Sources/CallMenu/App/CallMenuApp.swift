import SwiftUI
import CallAudio
@main struct CallMenuApp: App {
    init() {
        CallNotchPreview.runIfRequested()
        AppWindowPreview.runIfRequested()
        if CommandLine.arguments.contains("--phone-test-report") || CommandLine.arguments.contains("--phone-bridge-report") {
            do {
                let url = CommandLine.arguments.contains("--phone-bridge-report")
                    ? PhoneTestReportStorage.bridgeURL : PhoneTestReportStorage.defaultURL
                guard let report = try PhoneTestReportStorage.load(from: url) else {
                    print("{\"available\":false}"); exit(0)
                }
                print(String(decoding: try report.encoded(), as: UTF8.self)); exit(0)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--observe-phone-input") {
            do { print(try PhoneOutputProbe.observeInput()); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--check-phone-readback") || CommandLine.arguments.contains("--check-sustained-phone-readback") {
            do { print(try PhoneOutputProbe.checkAutomaticReadback(sustained: CommandLine.arguments.contains("--check-sustained-phone-readback"))); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--check-phone-output") || CommandLine.arguments.contains("--check-call-capture") {
            do { print(try PhoneOutputProbe.run(captureFormat: CommandLine.arguments.contains("--check-call-capture"))); exit(0) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
    }
    @NSApplicationDelegateAdaptor(PhoneKitAppDelegate.self) private var delegate
    @StateObject private var kit = PhoneKitStore()
    @StateObject private var chrome = RoutingStore()
    @StateObject private var assistant = AssistantStore()
    @StateObject private var bridge = PhoneBridgeStore()
    @StateObject private var phoneSessions = CodexPhoneSessionStore()
    @StateObject private var history = CallHistoryStore()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some Scene {
        // One main window: reopening brings it back instead of stacking copies.
        Window("Phone Assistant", id: "phone-kit") {
            PhoneKitWindow(kit: kit, chrome: chrome, assistant: assistant, bridge: bridge, history: history)
                .onAppear {
                    #if DEBUG
                    guard !CommandLine.arguments.contains("--check-phone-selection") else { return }
                    #endif
                    guard !delegate.didPrepareControls else { return }
                    delegate.didPrepareControls = true
                    chrome.onAudioObserved = { kit.confirmCapturedAudio() }
                    phoneSessions.start(bridge: bridge, kit: kit, assistant: assistant, test: chrome, history: history)
                    delegate.notch = CallNotchController(bridge: bridge, assistant: assistant, kit: kit,
                        routing: chrome,
                        openHistory: {
                            history.requestedSelection = history.liveID ?? history.mostRecent?.id
                            AppWindows.present { openWindow(id: "phone-kit") }
                        },
                        openSettings: { AppWindows.present { openSettings() } })
                    delegate.reopen = { AppWindows.present { openWindow(id: "phone-kit") } }
                    AppWindows.observe()
                    delegate.notch?.show()
                    if assistant.preferences.setupCompleted {
                        DispatchQueue.main.async {
                            NSApp.windows.filter { ["Phone Assistant", "Calls"].contains($0.title) }.forEach { $0.orderOut(nil) }
                            AppWindows.refresh()
                        }
                    }
                    delegate.requestStop = {
                        if kit.busy && !kit.checkingAudio { return false }
                        phoneSessions.beginShutdown()
                        let bridgeStopped = await bridge.stopAndWait()
                        let setupStopped = await kit.stopAudioAndWait()
                        let chromeStopped = await chrome.stopAndWait()
                        if setupStopped && chromeStopped && bridgeStopped {
                            delegate.notch?.hide()
                            await phoneSessions.shutdown()
                        } else {
                            phoneSessions.resumeAfterCancelledQuit()
                        }
                        return setupStopped && chromeStopped && bridgeStopped
                    }
                }
        }.defaultSize(width: 940, height: 740).windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
        Settings {
            CallSettingsView(kit: kit, routing: chrome, assistant: assistant, bridge: bridge, history: history)
        }
        Window("Live Audio Controls", id: "live-audio-controls") {
            PhoneLiveControlsView(bridge: bridge, assistant: assistant)
        }.defaultSize(width: 840, height: 720)
        MenuBarExtra("Phone Assistant", systemImage: "phone.connection") {
            CallMenuContents(chrome: chrome, assistant: assistant, bridge: bridge,
                showCallWidget: { delegate.notch?.expandForKeyboard() })
        }.menuBarExtraStyle(.menu)
    }
}
