import AppKit

/// Phone Assistant lives in the menu bar and the notch, so it has no Dock icon
/// while idle. Whenever one of its windows is open it becomes an ordinary app:
/// a Dock icon, Command-Tab, and windows that come forward when reopened.
@MainActor enum AppWindows {
    private static var observers: [NSObjectProtocol] = []

    /// Opens a window and brings the app forward.
    static func present(_ open: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        open()
        NSApp.activate()
    }

    static func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // A closing window is still visible until this notification returns.
                DispatchQueue.main.async { refresh() }
            })
        }
    }

    static func refresh() {
        let open = NSApp.windows.contains { window in
            !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
                && (window.isVisible || window.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = open ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
