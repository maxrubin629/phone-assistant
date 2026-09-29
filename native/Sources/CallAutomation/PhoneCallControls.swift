import AppKit
import ApplicationServices

/// Hangs up the active Continuity call. On macOS 27 its controls are a
/// Notification Center banner holding a "Mute" and an "End" button; Phone's own
/// window has no call controls. Only an End button that sits beside Mute in
/// the same banner is pressed, and only when exactly one such banner exists.
@MainActor public enum PhoneCallControls {
    /// How many call banners' End buttons are visible; exactly one can be pressed.
    public static func endButtonCount() -> Int {
        guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return 0 }
        var found: [AXUIElement] = [], visited = 0
        collect(AXUIElementCreateApplication(center.processIdentifier), depth: 0, visited: &visited, into: &found)
        return found.count
    }

    public static func endCall() throws {
        guard PhoneAutomationPermission.authorized else {
            throw PhoneAutomationError("Allow Phone Assistant in System Settings → Privacy & Security → \(PhoneAutomationPermission.settingsPaneName) so it can hang up calls.")
        }
        guard let center = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            throw PhoneAutomationError("The call's controls are unavailable, so the call wasn't hung up.")
        }
        var endButtons: [AXUIElement] = []
        var visited = 0
        collect(AXUIElementCreateApplication(center.processIdentifier), depth: 0, visited: &visited, into: &endButtons)
        guard endButtons.count == 1, let end = endButtons.first else {
            throw PhoneAutomationError(endButtons.isEmpty
                ? "No active call banner was found, so the call wasn't hung up."
                : "More than one call banner is showing, so the call wasn't hung up.")
        }
        guard AXUIElementPerformAction(end, kAXPressAction as CFString) == .success else {
            throw PhoneAutomationError("Pressing the call's End button failed.")
        }
    }

    /// Finds End buttons whose siblings include a Mute button.
    private static func collect(_ element: AXUIElement, depth: Int, visited: inout Int, into found: inout [AXUIElement]) {
        visited += 1
        guard depth < 20, visited < 4000 else { return }
        let children = self.children(element)
        let buttons = children.filter { string($0, kAXRoleAttribute) == kAXButtonRole as String }
        let labels = buttons.map { string($0, kAXDescriptionAttribute) }
        if labels.contains("Mute"), let index = labels.firstIndex(of: "End") { found.append(buttons[index]) }
        for child in children { collect(child, depth: depth + 1, visited: &visited, into: &found) }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
}
