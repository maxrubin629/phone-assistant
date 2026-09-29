import SwiftUI

/// Native Settings: one grouped form per pane, following the system accent color.
struct CallSettingsView: View {
    @ObservedObject var kit: PhoneKitStore
    @ObservedObject var routing: RoutingStore
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var bridge: PhoneBridgeStore
    @ObservedObject var history: CallHistoryStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settingsSelectedTab") private var selection = "assistant"

    var body: some View {
        TabView(selection: $selection) {
            AssistantSettingsView(preferences: $assistant.preferences)
                .tabItem { Label("Assistant", systemImage: "person.crop.circle") }.tag("assistant")
            ConnectionsSettingsView(bridge: bridge)
                .tabItem { Label("Connections", systemImage: "link") }.tag("voice")
            HistorySettingsView(history: history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag("history")
            PhoneKitSetupView(kit: kit, routingActive: routing.canStop || bridge.canStop)
                .tabItem { Label("Audio", systemImage: "checkmark.shield") }.tag("permissions")
            RoutingView(test: routing, kit: kit, callActive: bridge.canStop,
                        showSetup: { selection = "permissions" },
                        openLiveControls: { AppWindows.present { openWindow(id: "live-audio-controls") } })
                .tabItem { Label("Troubleshooting", systemImage: "stethoscope") }.tag("advanced")
        }
        // One size for every pane, so switching tabs doesn't resize the window.
        .frame(width: 640, height: 560)
        .plainToolbar()
        .onAppear {
            if !["assistant", "voice", "history", "permissions", "advanced"].contains(selection) { selection = "assistant" }
            kit.refresh()
        }
        .onChange(of: phase) { _, value in if value == .active { kit.refresh() } }
        .onDisappear {
            if routing.canStop { routing.stop() }
            kit.cancelAudioCheck()
        }
    }
}

private extension View {
    /// Keeps the tab bar flush with the window: no gray background or divider
    /// appears when a pane's content scrolls under it.
    @ViewBuilder func plainToolbar() -> some View {
        if #available(macOS 26.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar).scrollEdgeEffectHidden(true, for: .top)
        } else if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
