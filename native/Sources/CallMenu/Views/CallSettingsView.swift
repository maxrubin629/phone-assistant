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
                .frame(width: 600, height: 470)
                .tabItem { Label("Assistant", systemImage: "person.crop.circle") }.tag("assistant")
            ConnectionsSettingsView(bridge: bridge)
                .frame(width: 600, height: 420)
                .tabItem { Label("Connections", systemImage: "link") }.tag("voice")
            HistorySettingsView(history: history)
                .frame(width: 600, height: 330)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag("history")
            PhoneKitSetupView(kit: kit, routingActive: routing.canStop || bridge.canStop)
                .frame(width: 600, height: 520)
                .tabItem { Label("Audio", systemImage: "checkmark.shield") }.tag("permissions")
            RoutingView(test: routing, kit: kit, callActive: bridge.canStop,
                        showSetup: { selection = "permissions" },
                        openLiveControls: { openWindow(id: "live-audio-controls"); NSApp.activate(ignoringOtherApps: true) })
                .frame(width: 640, height: 640)
                .tabItem { Label("Troubleshooting", systemImage: "stethoscope") }.tag("advanced")
        }
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
