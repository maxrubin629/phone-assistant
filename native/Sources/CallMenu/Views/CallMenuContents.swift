import SwiftUI

struct CallMenuContents: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var chrome: RoutingStore
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var bridge: PhoneBridgeStore
    var showCallWidget: () -> Void

    private var status: String {
        if bridge.canStop { return bridge.status }
        if chrome.canStop { return chrome.status }
        return assistant.preferences.setupCompleted
            ? "Ready to connect"
            : "Setup required"
    }

    var body: some View {
        Text("Phone Assistant")
        Text(status)
        Divider()

        Button(action: showCallWidget) {
            Label("Show Widget", systemImage: "rectangle.topthird.inset.filled")
        }
        .keyboardShortcut("0", modifiers: [.command, .shift])

        Button {
            AppWindows.present { openWindow(id: "phone-kit") }
        } label: {
            Label(assistant.preferences.setupCompleted ? "Call History" : "Finish Setup…",
                  systemImage: assistant.preferences.setupCompleted ? "clock.arrow.circlepath" : "checklist")
        }
        Button {
            AppWindows.present { openSettings() }
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        if chrome.canStop {
            Button { chrome.stop() } label: {
                Label("Stop Audio Test", systemImage: "stop.circle")
            }
        }
        if bridge.canStop {
            Button { bridge.stop() } label: {
                Label("Disconnect Audio", systemImage: "phone.down")
            }
        }

        Divider()
        // The app delegate waits for every audio owner to stop before quitting.
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
