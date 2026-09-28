import AppKit
import CallAudio
import SwiftUI

/// A presentation of existing audio state. Opening this surface never starts audio.
struct CallNotchView: View {
    @ObservedObject var bridge: PhoneBridgeStore
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var kit: PhoneKitStore
    @ObservedObject var routing: RoutingStore
    @ObservedObject var presentation: CallNotchPresentation
    let expand: () -> Void
    let collapse: () -> Void
    let hovered: (Bool) -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let openCodex: () -> Void
    let hide: () -> Void
    let activityChanged: (Bool) -> Void
    let preferredExpandedHeight: (CGFloat) -> Void

    private var mode: CallExperienceMode? { .init(routing: bridge.routing) }
    private var otherAudio: Bool { routing.canStop || kit.busy || kit.needsAudioCleanup }
    private var missingKey: Bool { bridge.routing.needsVoice && !bridge.keyAvailable }
    private var canConnect: Bool { !bridge.canStop && kit.ready && !otherAudio && !missingKey && (mode == .manual || hasTask) }
    private var hasTask: Bool { !bridge.codexSessionID.isEmpty }
    private var hasOrigin: Bool { UUID(uuidString: bridge.codexOriginThreadID) != nil }
    private var deliveryFailed: Bool { bridge.codexDeliveryStatus.hasPrefix("Not confirmed:") }
    private var taskTitle: String { bridge.codexTaskTitle.isEmpty ? "Task from Codex" : bridge.codexTaskTitle }
    private var status: String {
        if bridge.needsCleanup { return "Audio needs attention" }
        if !bridge.error.isEmpty { return "Audio needs attention" }
        if deliveryFailed { return "Codex needs attention" }
        if bridge.busy { return "Updating audio…" }
        if !bridge.codexQuestion.isEmpty { return "Your input is needed" }
        if bridge.active { return bridge.muted ? "Sending muted" : "Audio connected" }
        if !kit.ready { return "Audio setup required" }
        if otherAudio { return "Audio is in use" }
        if missingKey { return "API key needed" }
        return hasTask ? "Audio disconnected" : "Waiting for Codex"
    }
    private var tone: CallNotchModel.Tone {
        if bridge.needsCleanup || !bridge.error.isEmpty || deliveryFailed || !bridge.codexQuestion.isEmpty { return .attention }
        if bridge.active { return bridge.muted ? .muted : .live }
        return .idle
    }
    private var notice: CallNotchModel.Notice? {
        if bridge.needsCleanup || !bridge.error.isEmpty {
            return .error(bridge.error.isEmpty ? "Audio cleanup is incomplete." : bridge.error)
        }
        if !bridge.codexQuestion.isEmpty { return .question(bridge.codexQuestion, deliveryFailed: deliveryFailed) }
        if deliveryFailed { return .deliveryFailed }
        if otherAudio { return .otherAudio }
        return nil
    }
    private var primary: CallNotchModel.Primary {
        if bridge.canStop { return bridge.needsCleanup ? .retryCleanup(enabled: !bridge.busy) : .disconnect }
        if !kit.ready { return .setUpAudio }
        if missingKey { return .addKey }
        if !hasTask && mode != .manual { return .ready }
        return .connect(enabled: canConnect)
    }

    private func pathEnabled(_ path: CallAudioTuning.Path) -> Bool {
        bridge.active && !bridge.busy && bridge.routing.routes.contains(path.route)
            && !bridge.tuning.isMuted(path) && bridge.tuning[path] > 0
    }
    private var microphoneToCaller: Bool { pathEnabled(.microphoneToCaller) && !bridge.muted }
    private var microphoneToAgent: Bool { pathEnabled(.microphoneToAgent) }
    private var listeningToCaller: Bool {
        bridge.active && !bridge.busy && bridge.routing.listener.includesUser
            && (bridge.nativeCallerPlayback || pathEnabled(.callerToUser))
    }

    private var model: CallNotchModel {
        CallNotchModel(title: hasTask ? taskTitle : "No call in progress", hasTask: hasTask, status: status, tone: tone,
            busy: bridge.busy, active: bridge.active, muted: bridge.muted, mode: mode,
            microphoneToCaller: microphoneToCaller, microphoneToAgent: microphoneToAgent,
            listeningToCaller: listeningToCaller,
            level: bridge.active ? CGFloat(min(1, max(bridge.agentPeak, bridge.callerPeak))) : 0,
            notice: notice, hasOrigin: hasOrigin, primary: primary)
    }

    var body: some View {
        CallNotchSurface(model: model,
            chrome: CallNotchChrome(expanded: presentation.expanded, attached: presentation.isHardwareNotch,
                                    showsEars: presentation.showsEars,
                                    notchWidth: presentation.notchWidth, notchHeight: presentation.notchHeight,
                                    expandedWidth: presentation.expandedWidth, expandedHeight: presentation.expandedHeight),
            actions: CallNotchActions(expand: expand, collapse: collapse, hovered: hovered,
                openHistory: openHistory, openSettings: openSettings, openCodex: openCodex, hide: hide,
                choose: choose, toggleMute: { bridge.setMuted(!bridge.muted) }, stop: { bridge.stop() },
                connect: { Task { await bridge.start(profile: assistant.preferences) } },
                openSetup: { tab in
                    UserDefaults.standard.set(tab, forKey: "settingsSelectedTab")
                    openSettings()
                },
                preferredExpandedHeight: preferredExpandedHeight))
            .onAppear { activityChanged(model.hasActivity) }
            .onChange(of: model.hasActivity) { _, active in activityChanged(active) }
    }

    private func choose(_ choice: CallExperienceMode) {
        guard !bridge.busy else { return }
        guard !bridge.active || !choice.needsVoice || bridge.keyAvailable else {
            UserDefaults.standard.set("voice", forKey: "settingsSelectedTab")
            openSettings(); return
        }
        Task { await bridge.changeRouting(choice.routing, profile: assistant.preferences) }
    }
}

// MARK: - Value model

/// Everything the notch draws, as plain values, so the surface can be rendered
/// without live audio stores (see `CallNotchPreview`).
struct CallNotchModel {
    enum Tone { case idle, live, muted, attention }
    enum Notice { case error(String), question(String, deliveryFailed: Bool), deliveryFailed, otherAudio }
    enum Primary { case ready, connect(enabled: Bool), disconnect, retryCleanup(enabled: Bool), setUpAudio, addKey }

    var title: String
    var hasTask: Bool
    var status: String
    var tone: Tone
    var busy: Bool
    var active: Bool
    var muted: Bool
    var mode: CallExperienceMode?
    var microphoneToCaller: Bool
    var microphoneToAgent: Bool
    var listeningToCaller: Bool
    /// Recent assistant or caller peak, 0...1. Drives the compact waveform.
    var level: CGFloat
    var notice: Notice?
    var hasOrigin: Bool
    var primary: Primary

    /// Whether the collapsed notch has anything to show beside the camera.
    var hasActivity: Bool { active || busy || tone == .attention }
}

struct CallNotchChrome {
    var expanded: Bool
    var attached: Bool
    var showsEars = true
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var expandedWidth: CGFloat = CallNotchLayout.expandedWidth
    var expandedHeight: CGFloat? = nil
}

struct CallNotchActions {
    var expand: () -> Void
    var collapse: () -> Void
    var hovered: (Bool) -> Void
    var openHistory: () -> Void
    var openSettings: () -> Void
    var openCodex: () -> Void
    var hide: () -> Void
    var choose: (CallExperienceMode) -> Void
    var toggleMute: () -> Void
    var stop: () -> Void
    var connect: () -> Void
    var openSetup: (String) -> Void
    var preferredExpandedHeight: (CGFloat) -> Void
}

// MARK: - Surface

struct CallNotchSurface: View {
    let model: CallNotchModel
    let chrome: CallNotchChrome
    let actions: CallNotchActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shell: NotchShell {
        NotchShell(attached: chrome.attached, expanded: chrome.expanded)
    }
    /// Horizontal inset that lines content up with the inside of the shoulders.
    private var inset: CGFloat { chrome.attached ? 30 : 24 }
    private var headerHeight: CGFloat { chrome.attached ? chrome.notchHeight : 40 }
    /// Only the live waveform moves; everything else is static.
    private var animating: Bool { !reduceMotion && model.active && !model.muted && !chrome.expanded }
    private var expandedHeight: CGFloat {
        chrome.expandedHeight ?? CallNotchLayout.minimumExpandedHeight(notchHeight: chrome.notchHeight)
    }
    private var shellAnimation: Animation? {
        guard !reduceMotion else { return nil }
        let timing = CallNotchTransition.timing(expanding: chrome.expanded)
        return .timingCurve(Double(timing.x1), Double(timing.y1), Double(timing.x2), Double(timing.y2), duration: timing.duration)
    }

    var body: some View {
        NotchBackdrop(shell: shell, gradientHeight: expandedHeight)
        .overlay(alignment: .top) {
            // Keep controls mounted and measured at their final size. Resizing
            // the panel reveals them without creating glass or reflowing text.
            expanded
                .frame(width: chrome.expandedWidth, height: expandedHeight, alignment: .top)
                .opacity(chrome.expanded ? 1 : 0)
                .animation(reduceMotion ? nil : (chrome.expanded
                    ? .easeOut(duration: 0.16).delay(0.10)
                    : .easeIn(duration: 0.06)), value: chrome.expanded)
                .allowsHitTesting(chrome.expanded)
                .accessibilityHidden(!chrome.expanded)
        }
        .overlay(alignment: .top) {
            compact
                .opacity(chrome.expanded ? 0 : 1)
                .animation(reduceMotion ? nil : (chrome.expanded
                    ? .easeOut(duration: 0.06)
                    : .easeIn(duration: 0.10).delay(0.12)), value: chrome.expanded)
                .allowsHitTesting(!chrome.expanded)
                .accessibilityHidden(chrome.expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(shell)
        .preferredColorScheme(.dark)
        .environment(\.appearsActive, true)
        .onHover(perform: actions.hovered)
        .onExitCommand(perform: actions.collapse)
        .animation(shellAnimation, value: chrome.expanded)
    }

    // MARK: Compact

    private var compact: some View {
        Button(action: actions.expand) {
            if chrome.attached && !chrome.showsEars {
                // Housing-sized and empty: a hover or click target, nothing more.
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            } else {
            HStack(spacing: 0) {
                compactLeading.frame(maxWidth: .infinity)
                // No text or controls can sit behind the camera housing.
                if chrome.attached {
                    Color.clear.frame(width: chrome.notchWidth)
                } else {
                    Text(model.hasTask ? model.title : model.status)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.92)).layoutPriority(1)
                }
                compactTrailing.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, chrome.attached ? 6 : 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Phone Assistant. \(model.hasTask ? model.title + ". " : "")\(model.status). Microphone to caller \(model.microphoneToCaller ? "on" : "off"). Listening to caller \(model.listeningToCaller ? "on" : "off"). Show call controls")
        .help("\(model.status). Mic to caller: \(model.microphoneToCaller ? "On" : "Off"). Click for controls.")
    }

    /// Left ear: call state. Right ear: audio activity, only when there is some.
    @ViewBuilder private var compactLeading: some View {
        if model.tone == .attention {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        } else {
            Image(systemName: model.active ? "phone.fill" : "phone").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(model.active ? 0.95 : 0.5))
        }
    }

    @ViewBuilder private var compactTrailing: some View {
        if model.busy {
            ProgressView().controlSize(.mini).tint(.white)
        } else if model.active && model.muted {
            Image(systemName: "mic.slash.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
        } else if model.active {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
                NotchWaveform(level: model.level, time: timeline.date.timeIntervalSinceReferenceDate, bars: 5, height: 13)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.level)
            }
        }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header
                .frame(height: headerHeight)
                .background(heightReader)
            ScrollView {
                expandedBody.background(heightReader)
            }.scrollIndicators(.hidden)
            footer
                .padding(.horizontal, inset).padding(.top, 8).padding(.bottom, 14)
                .background(heightReader)
        }
        .onPreferenceChange(NotchContentHeightKey.self) { height in
            if height > 0 { actions.preferredExpandedHeight(height) }
        }
    }

    private var heightReader: some View {
        GeometryReader { Color.clear.preference(key: NotchContentHeightKey.self, value: $0.size.height) }
    }

    /// On a notch the header lives in the two ears beside the camera, like the
    /// menu bar it replaces; the housing itself stays empty.
    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(maxWidth: .infinity)
            if chrome.attached { Color.clear.frame(width: chrome.notchWidth) }
            HStack(spacing: 4) {
                NotchOverflowMenu(hasOrigin: model.hasOrigin, busy: model.busy, actions: actions)
                    .frame(width: 26, height: 22)
                Button(action: actions.collapse) {
                    Image(systemName: "chevron.compact.up").font(.system(size: 14, weight: .semibold))
                        .frame(width: 26, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Collapse").accessibilityLabel("Collapse call controls")
            }
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, inset - 4)
        .padding(.leading, 4)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    callSummary.frame(minWidth: 160, idealWidth: 170, maxWidth: .infinity, alignment: .leading)
                    modeControls.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    callSummary
                    modeControls
                }
            }
            if let notice = model.notice { noticeView(notice) }
        }
        .padding(.horizontal, inset).padding(.top, chrome.attached ? 6 : 4)
    }

    private var callSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.title)
                .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                .foregroundStyle(.white)
                .accessibilityLabel(model.hasTask ? "Task from Codex: \(model.title)" : model.title)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(model.status).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
        }
    }

    private var routeStatus: some View {
        HStack(spacing: 6) {
            RouteChip(on: model.microphoneToCaller, onTitle: "Mic on", offTitle: "Mic off",
                      onSymbol: "mic.fill", offSymbol: "mic.slash")
                .accessibilityLabel("Microphone to caller \(model.microphoneToCaller ? "on" : "off")")
            RouteChip(on: model.listeningToCaller, onTitle: "Listening", offTitle: "Sound off",
                      onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash")
                .accessibilityLabel("Listening to caller \(model.listeningToCaller ? "on" : "off")")
        }
        .font(.system(size: 10, weight: .medium))
        .help("Mic to assistant: \(model.microphoneToAgent ? "On" : "Off")")
    }

    @ViewBuilder private func noticeView(_ notice: CallNotchModel.Notice) -> some View {
        switch notice {
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .question(let question, let failed):
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(question).font(.system(size: 12)).foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    if failed { Text("Could not reach Codex").font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength: 0)
                Button("Open Codex", action: actions.openCodex).controlSize(.small)
                    .modifier(NotchButtonGlass(prominent: false)).disabled(!model.hasOrigin)
            }
            .padding(12)
            .modifier(NotchTileGlass(selected: true, cornerRadius: 16))
        case .deliveryFailed:
            HStack {
                Text("Could not send the update to Codex").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open Codex", action: actions.openCodex).controlSize(.small)
                    .modifier(NotchButtonGlass(prominent: false)).disabled(!model.hasOrigin)
            }
        case .otherAudio:
            Text("Stop the other audio session first.").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder private var modeControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) { modeRow }
        } else { modeRow }
    }

    private var modeRow: some View {
        HStack(spacing: 6) {
            modeButton(.listen)
            modeButton(.join)
            modeButton(.takeOver)
        }
    }

    private func modeButton(_ choice: CallExperienceMode) -> some View {
        let selected = model.mode == choice
        return Button { actions.choose(choice) } label: {
            HStack(spacing: 6) {
                Image(systemName: choice.symbolName).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.88))
                Text(choice.title).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.78))
            }
            .frame(width: 80, height: 34)
            .modifier(NotchModeButtonGlass(selected: selected))
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(model.busy)
        .accessibilityLabel(choice.title)
        .accessibilityValue(selected ? "Selected" : "")
        .help(choice.detail)
    }

    @ViewBuilder private var footer: some View {
        if model.active || model.mode != .assistant {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    routeStatus.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    historyButton
                    footerActions
                }
            }
            .controlSize(.regular)
        } else {
            HStack(spacing: 10) {
                routeStatus.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                historyButton
                footerActions
            }
            .controlSize(.regular)
        }
    }

    private var historyButton: some View {
        Button(action: actions.openHistory) {
            Image(systemName: "macwindow")
                .font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.65))
            .accessibilityLabel("Open call history").help(model.active ? "Open the live transcript" : "Open call history")
    }

    @ViewBuilder private var footerActions: some View {
        if model.mode != .assistant {
            Button("Assistant only") { actions.choose(.assistant) }
                .modifier(NotchButtonGlass(prominent: false)).disabled(model.busy)
        }
        if model.busy { ProgressView().controlSize(.small).tint(.white) }
        if model.active {
            Button(action: actions.toggleMute) {
                Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(model.muted ? Color.orange : .white)
                    .frame(width: 18)
            }
            .modifier(NotchButtonGlass(prominent: false)).disabled(model.busy)
            .accessibilityLabel(model.muted ? "Unmute to caller" : "Mute to caller")
        }
        primaryButton
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.primary {
        case .disconnect:
            Button("Disconnect audio", action: actions.stop)
                .modifier(NotchButtonGlass(prominent: false))
                .help("Disconnects audio routing. The Phone call stays open.")
        case .retryCleanup(let enabled):
            Button("Retry cleanup", action: actions.stop)
                .modifier(NotchButtonGlass(prominent: false)).disabled(!enabled)
        case .setUpAudio:
            Button("Set up audio") { actions.openSetup("permissions") }
                .modifier(NotchButtonGlass(prominent: true))
        case .addKey:
            Button("Add API key") { actions.openSetup("voice") }
                .modifier(NotchButtonGlass(prominent: true))
        case .ready:
            Text("Ready for Codex").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
        case .connect(let enabled):
            Button("Connect audio", action: actions.connect)
                .modifier(NotchButtonGlass(prominent: true)).disabled(!enabled)
                .help("Start or answer the call in Phone first")
        }
    }

    private var statusColor: Color {
        switch model.tone {
        case .attention, .muted: return .orange
        case .live: return SiriPalette.blue
        case .idle: return .white.opacity(0.45)
        }
    }
}

private struct NotchContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private struct RouteChip: View {
    let on: Bool
    let onTitle: String, offTitle: String, onSymbol: String, offSymbol: String
    var body: some View {
        Label(on ? onTitle : offTitle, systemImage: on ? onSymbol : offSymbol)
            .foregroundStyle(on ? Color.white : .white.opacity(0.55))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(on ? 0.14 : 0.06)))
            .overlay(Capsule().strokeBorder(on ? AnyShapeStyle(SiriPalette.rim.opacity(0.7)) : AnyShapeStyle(.white.opacity(0.06)), lineWidth: 0.75))
    }
}

/// AppKit owns menu presentation so the native menu can extend beyond the panel.
private struct NotchOverflowMenu: NSViewRepresentable {
    var hasOrigin: Bool
    var busy: Bool
    var actions: CallNotchActions

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton()
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More call controls")
        button.imagePosition = .imageOnly
        button.contentTintColor = .white.withAlphaComponent(0.7)
        button.setAccessibilityLabel("More call controls")
        button.target = button
        button.action = #selector(MenuButton.showMenu)
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        button.entries = [
            ("Call history", true, actions.openHistory),
            ("Settings", true, actions.openSettings)
        ]
        if hasOrigin { button.entries.append(("Open Codex", true, actions.openCodex)) }
        button.entries.append(("", false, {}))
        button.entries.append(("Just me", !busy, { actions.choose(.manual) }))
        button.entries.append(("Hide widget", true, actions.hide))
    }

    final class MenuButton: NSButton, NSMenuDelegate {
        var entries: [(String, Bool, () -> Void)] = []
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        @objc func showMenu() {
            guard let window, let screen = window.screen else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            for (index, entry) in entries.enumerated() {
                if entry.0.isEmpty { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: entry.0, action: #selector(selectItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.isEnabled = entry.1
                menu.addItem(item)
            }
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            // Starting inside the menu-bar strip can confine a native menu to
            // that strip. Anchor below it, using screen rather than panel bounds.
            let location = NSPoint(x: anchor.maxX - menu.size.width,
                                   y: min(anchor.minY - 4, screen.visibleFrame.maxY - 4))
            // Present independently of the short hosting window.
            menu.popUp(positioning: nil, at: location, in: nil)
        }

        func confinementRect(for menu: NSMenu, on screen: NSScreen?) -> NSRect {
            (screen ?? window?.screen)?.visibleFrame ?? .zero
        }

        @objc private func selectItem(_ item: NSMenuItem) {
            guard entries.indices.contains(item.tag) else { return }
            let action = entries[item.tag].2
            DispatchQueue.main.async(execute: action)
        }
    }
}

// MARK: - Palette

/// The Apple Intelligence spectrum: violet, pink, periwinkle, coral and amber.
enum SiriPalette {
    static let violet = Color(red: 0.74, green: 0.51, blue: 0.95)
    static let pink = Color(red: 0.96, green: 0.73, blue: 0.92)
    static let blue = Color(red: 0.55, green: 0.62, blue: 1.0)
    static let coral = Color(red: 1.0, green: 0.40, blue: 0.47)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.44)
    static let text = Color(red: 0.80, green: 0.76, blue: 1.0)
    static let iconGradient = LinearGradient(colors: [blue, violet, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let rim = LinearGradient(colors: [blue, violet, pink, amber], startPoint: .leading, endPoint: .trailing)
}

// MARK: - Shell and glass

/// Concave shoulders meet the screen edge like the housing's own fillets; the
/// lower corners use continuous curvature. Radii animate between states.
struct NotchShell: Shape {
    var shoulder: CGFloat
    var bottom: CGFloat
    var attached: Bool

    init(attached: Bool, expanded: Bool) {
        self.attached = attached
        shoulder = attached ? (expanded ? 16 : 6) : 0
        bottom = attached ? (expanded ? 34 : 11) : (expanded ? 30 : 19)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottom) }
        set { shoulder = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard attached else {
            return RoundedRectangle(cornerRadius: min(bottom, rect.height / 2), style: .continuous).path(in: rect)
        }
        let w = rect.width, h = rect.height
        let s = min(shoulder, w / 4, h / 2)
        let r = min(bottom, (w - 2 * s) / 2, h - s)
        let k: CGFloat = 0.62  // cubic handle length; slightly past a circle for continuous curvature
        var path = Path()
        path.move(to: .zero)
        // The screen's housing covers the center; the panel itself has no cutout.
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addCurve(to: CGPoint(x: w - s, y: s),
                      control1: CGPoint(x: w - s * k, y: 0), control2: CGPoint(x: w - s, y: s * (1 - k)))
        path.addLine(to: CGPoint(x: w - s, y: h - r))
        path.addCurve(to: CGPoint(x: w - s - r, y: h),
                      control1: CGPoint(x: w - s, y: h - r * (1 - k)), control2: CGPoint(x: w - s - r * (1 - k), y: h))
        path.addLine(to: CGPoint(x: s + r, y: h))
        path.addCurve(to: CGPoint(x: s, y: h - r),
                      control1: CGPoint(x: s + r * (1 - k), y: h), control2: CGPoint(x: s, y: h - r * (1 - k)))
        path.addLine(to: CGPoint(x: s, y: s))
        path.addCurve(to: .zero,
                      control1: CGPoint(x: s, y: s * (1 - k)), control2: CGPoint(x: s * k, y: 0))
        path.closeSubpath()
        return path
    }
}

/// The dark top runs behind the camera housing; frosted glass stays visible below it.
private struct NotchBackdrop: View {
    let shell: NotchShell
    let gradientHeight: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        glass.clipShape(shell)
    }

    @ViewBuilder private var glass: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Color.clear.glassEffect(.regular, in: shell)
                // Apply the fade above the glass so its adaptive material does
                // not wash out the black top. Content is a separate layer above.
                .overlay(alignment: .top) {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                            Gradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.90), location: 0.20),
                                .init(color: .black.opacity(0.35), location: 0.60),
                                .init(color: .black.opacity(0.10), location: 1)
                            ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: gradientHeight)))
                    }
                    // Gradient coordinates are fixed, independent of the
                    // current canvas height and inherited shell animations.
                    .transaction { $0.animation = nil }
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
        } else {
            shell.fill(Color(white: 0.04))
        }
    }
}

private struct NotchWaveform: View {
    let level: CGFloat
    let time: TimeInterval
    let bars: Int
    let height: CGFloat

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<bars, id: \.self) { index in
                let wobble = CGFloat(sin(time * 7.3 + Double(index) * 1.7) * 0.5 + 0.5)
                let center = 1 - abs(CGFloat(index) - CGFloat(bars - 1) / 2) / CGFloat(bars)
                let fraction = max(0.2, min(1, 0.22 + level * center * (0.55 + 0.45 * wobble) * 1.4))
                Capsule().frame(width: 2.5, height: height * fraction)
            }
        }
        .frame(height: height)
        .foregroundStyle(.white.opacity(0.9))
        .accessibilityHidden(true)
    }
}

// MARK: - Control glass

private struct NotchModeButtonGlass: ViewModifier {
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = Capsule()
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                content.glassEffect(.regular.tint(selected ? SiriPalette.violet.opacity(0.3) : nil).interactive(), in: shape)
                    .environment(\.materialActiveAppearance, .active)
            } else {
                content.background(selected ? SiriPalette.violet.opacity(0.22) : Color.white.opacity(0.08), in: shape)
            }
        }
        .overlay(shape.strokeBorder(selected ? SiriPalette.violet.opacity(0.55) : Color.white.opacity(contrast == .increased ? 0.5 : 0.14), lineWidth: 0.75))
    }
}

private struct NotchTileGlass: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                content.glassEffect(.regular.tint(selected ? SiriPalette.violet.opacity(0.22) : .white.opacity(0.03)).interactive(), in: shape)
                    .environment(\.materialActiveAppearance, .active)
            } else {
                content.background(selected ? SiriPalette.violet.opacity(0.2) : Color.white.opacity(0.08), in: shape)
            }
        }
        .overlay(shape.strokeBorder(selected ? AnyShapeStyle(SiriPalette.rim) : AnyShapeStyle(Color.white.opacity(contrast == .increased ? 0.5 : 0.07)),
                                    lineWidth: selected ? 1.1 : 0.75))
    }
}

private struct NotchButtonGlass: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        content.buttonStyle(NotchActionButtonStyle(prominent: prominent))
    }
}

/// Actions and mode controls share interactive glass in the nonactivating panel.
private struct NotchActionButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.4))
            .padding(.horizontal, 12).frame(height: 30)
            .modifier(NotchModeButtonGlass(selected: prominent))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
