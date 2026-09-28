import AppKit
import Combine
import OSLog
import QuartzCore
import SwiftUI

@MainActor final class CallNotchPresentation: ObservableObject {
    @Published fileprivate(set) var expanded = false
    @Published fileprivate(set) var notchWidth: CGFloat = 0
    @Published fileprivate(set) var notchHeight: CGFloat = 0
    @Published fileprivate(set) var isHardwareNotch = false
    @Published fileprivate(set) var showsEars = false
    @Published fileprivate(set) var expandedWidth: CGFloat = CallNotchLayout.expandedWidth
    @Published fileprivate(set) var expandedHeight: CGFloat = 140
}

/// AppKit is confined to nonactivating placement and panel lifecycle.
/// All audio actions remain in the existing bridge store.
@MainActor final class CallNotchController: NSObject {
    private let presentation = CallNotchPresentation()
    private let panel: CallNotchPanel
    private var observers: [NSObjectProtocol] = []
    private var hoverWork: DispatchWorkItem?
    private var pinned = false
    private var visible = false
    private var targetScreenNumber: NSNumber?
    private var expandedHeight: CGFloat?
    private var lastPlacementExpanded: Bool?
    private var lastPlacementEars: Bool?
    private var lastPlacementScreenNumber: NSNumber?
    private var frameAnimation = CallNotchFrameAnimation()
    private var frameTimer: Timer?
    private var needsHeightPlacement = false
    private let logger = Logger(subsystem: "com.codexcall.menu", category: "notch-placement")
    var expandsOnHover = true

    init(bridge: PhoneBridgeStore, assistant: AssistantStore, kit: PhoneKitStore,
         routing: RoutingStore,
         openHistory: @escaping () -> Void, openSettings: @escaping () -> Void,
         openCodex: (() -> Void)? = nil) {
        panel = CallNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Phone Assistant controls"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.collapse() }
        panel.contentView = CallNotchHostingView(rootView: CallNotchView(
            bridge: bridge, assistant: assistant, kit: kit, routing: routing,
            presentation: presentation,
            expand: { [weak self] in self?.expandForKeyboard() },
            collapse: { [weak self] in self?.collapse() },
            hovered: { [weak self] in self?.hovered($0) },
            openHistory: { [weak self] in self?.collapse(); openHistory() },
            openSettings: { [weak self] in self?.collapse(); openSettings() },
            openCodex: {
                if let openCodex { openCodex(); return }
                guard UUID(uuidString: bridge.codexOriginThreadID) != nil,
                      let url = URL(string: "codex://threads/" + bridge.codexOriginThreadID) else { return }
                NSWorkspace.shared.open(url)
            },
            hide: { [weak self] in self?.hide() },
            activityChanged: { [weak self] active in
                DispatchQueue.main.async { self?.setShowsEars(active) }
            },
            preferredExpandedHeight: { [weak self] height in
                DispatchQueue.main.async { self?.updateExpandedHeight(height) }
            }))

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        })
    }

    func show(expanded: Bool = false) {
        visible = true
        pinned = expanded
        presentation.expanded = expanded
        place()
        panel.orderFrontRegardless()
    }

    func hide() {
        hoverWork?.cancel(); hoverWork = nil
        frameAnimation.cancel()
        frameTimer?.invalidate(); frameTimer = nil
        visible = false; pinned = false
        panel.orderOut(nil)
        presentation.expanded = false
    }

    func setVisible(_ isVisible: Bool) { isVisible ? show() : hide() }

    func toggleExpanded() {
        if visible && presentation.expanded { collapse() }
        else { expandForKeyboard() }
    }

    /// Only explicit user interaction takes keyboard focus. Hover never does.
    func expandForKeyboard() {
        hoverWork?.cancel(); hoverWork = nil
        pinned = true
        visible = true
        presentation.expanded = true
        place(animateExpansion: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func collapse() {
        hoverWork?.cancel(); hoverWork = nil
        pinned = false
        presentation.expanded = false
        panel.resignKey()
        place(animateExpansion: true)
    }

    private func hovered(_ inside: Bool) {
        hoverWork?.cancel(); hoverWork = nil
        guard visible, expandsOnHover, !pinned else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.visible, !self.pinned else { return }
            self.presentation.expanded = inside
            self.place(animateExpansion: true)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.25 : 0.45), execute: work)
    }

    private func setShowsEars(_ value: Bool) {
        guard presentation.showsEars != value else { return }
        presentation.showsEars = value
        place(animateExpansion: true)
    }

    private func place(animateExpansion: Bool = false) {
        guard visible, let screen = targetScreen() else { return }
        let layout = CallNotchLayout.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top, auxiliaryLeft: screen.auxiliaryTopLeftArea,
            auxiliaryRight: screen.auxiliaryTopRightArea, expanded: presentation.expanded,
            showsEars: presentation.showsEars, preferredExpandedHeight: expandedHeight)
        let expandedLayout = CallNotchLayout.make(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            safeTop: screen.safeAreaInsets.top, auxiliaryLeft: screen.auxiliaryTopLeftArea,
            auxiliaryRight: screen.auxiliaryTopRightArea, expanded: true,
            showsEars: presentation.showsEars, preferredExpandedHeight: expandedHeight)
        if presentation.notchWidth != layout.notchWidth { presentation.notchWidth = layout.notchWidth }
        if presentation.notchHeight != layout.notchHeight { presentation.notchHeight = layout.notchHeight }
        if presentation.isHardwareNotch != layout.isHardwareNotch { presentation.isHardwareNotch = layout.isHardwareNotch }
        if presentation.expandedWidth != expandedLayout.frame.width { presentation.expandedWidth = expandedLayout.frame.width }
        if presentation.expandedHeight != expandedLayout.frame.height { presentation.expandedHeight = expandedLayout.frame.height }
        panel.level = layout.isHardwareNotch ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .floating
        if panel.frame != layout.frame {
            logger.info("screen=\(String(describing: screen.frame), privacy: .public) panel=\(String(describing: layout.frame), privacy: .public) notch=\(layout.notchWidth, privacy: .public)x\(layout.notchHeight, privacy: .public) hardware=\(layout.isHardwareNotch, privacy: .public)")
        }
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let shouldAnimate = animateExpansion && panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && lastPlacementExpanded != nil
            && (lastPlacementExpanded != presentation.expanded
                || (!presentation.expanded && lastPlacementEars != presentation.showsEars))
            && lastPlacementScreenNumber == screenNumber
            && abs(panel.frame.maxY - layout.frame.maxY) < 0.5
        lastPlacementExpanded = presentation.expanded
        lastPlacementEars = presentation.showsEars
        lastPlacementScreenNumber = screenNumber
        guard let serial = frameAnimation.begin(target: layout.frame, animated: shouldAnimate) else { return }
        frameTimer?.invalidate(); frameTimer = nil
        needsHeightPlacement = false
        if shouldAnimate {
            let expanding = layout.frame.width > panel.frame.width || layout.frame.height > panel.frame.height
            let timing = CallNotchTransition.timing(expanding: expanding)
            let start = panel.frame
            let startedAt = CACurrentMediaTime()
            // NSWindow's animator scales the rendered content during resizing.
            // Resize and lay out each frame so the top-anchored fade stays put.
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.frameAnimation.generation == serial else {
                        timer.invalidate(); return
                    }
                    let fraction = min(1, (CACurrentMediaTime() - startedAt) / timing.duration)
                    self.panel.setFrame(timing.frame(from: start, to: layout.frame, at: fraction), display: false)
                    self.panel.contentView?.layoutSubtreeIfNeeded()
                    self.panel.displayIfNeeded()
                    if fraction >= 1 {
                        timer.invalidate(); self.frameTimer = nil
                        guard self.frameAnimation.complete(serial) else { return }
                        if self.needsHeightPlacement {
                            self.needsHeightPlacement = false
                            self.place()
                        }
                    }
                }
            }
            frameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            panel.setFrame(layout.frame, display: true)
        }
    }

    private func updateExpandedHeight(_ height: CGFloat) {
        guard height.isFinite else { return }
        let bounded = min(CallNotchLayout.maximumHeight,
                          max(CallNotchLayout.minimumExpandedHeight(notchHeight: presentation.notchHeight), ceil(height)))
        guard abs((expandedHeight ?? 0) - bounded) > 1 else { return }
        expandedHeight = bounded
        if presentation.expanded {
            if frameAnimation.isAnimating { needsHeightPlacement = true }
            else { place() }
        }
    }

    private func targetScreen() -> NSScreen? {
        if let targetScreenNumber, let existing = NSScreen.screens.first(where: { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == targetScreenNumber }) {
            return existing
        }
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
        targetScreenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return screen
    }

    deinit {
        hoverWork?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}

extension CallNotchController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        if pinned { collapse() }
    }
}

private final class CallNotchPanel: NSPanel {
    var onCancel: (() -> Void)?
    // AppKit's Liquid Glass uses these appearance queries even when SwiftUI's
    // appearsActive/materialActiveAppearance are set. This nonactivating panel
    // must retain its glass while the user works in another application.
    // These selectors are undocumented: keep them isolated and recheck on new
    // macOS releases. They do not override isKeyWindow or activate the app.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func hasKeyAppearance() -> Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}

private final class CallNotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
