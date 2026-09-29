#if DEBUG
import AppKit
import ApplicationServices
import CallAutomation

/// Development probe: `open -n CallMenu.app --args --inspect-call-controls <file>`
/// lists call-related buttons in the apps that can show an active call's
/// controls, so hang-up automation can target the real control. Read-only:
/// it never presses anything. Runs as the app so it uses the app's
/// Accessibility permission.
@MainActor enum CallControlsInspector {
    private static let bundles = ["com.apple.mobilephone", "com.apple.notificationcenterui",
                                  "com.apple.controlcenter", "com.apple.FaceTime"]
    private static let keywords = ["end", "hang", "decline", "call", "mute", "leave"]

    static func write(to destination: URL) {
        var found: [[String: String]] = []
        for app in NSWorkspace.shared.runningApplications where bundles.contains(app.bundleIdentifier ?? "") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var visited = 0
            walk(root, path: app.bundleIdentifier ?? "?", depth: 0, visited: &visited, found: &found)
        }
        let report: [String: Any] = ["trusted": AXIsProcessTrusted(), "controls": found,
                                     "hangUpTargets": PhoneCallControls.endButtonCount()]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private static func walk(_ element: AXUIElement, path: String, depth: Int, visited: inout Int, found: inout [[String: String]]) {
        visited += 1
        guard depth < 18, visited < 6000 else { return }
        let role = string(element, kAXRoleAttribute)
        let fields = ["title": string(element, kAXTitleAttribute), "description": string(element, kAXDescriptionAttribute),
                      "identifier": string(element, kAXIdentifierAttribute), "help": string(element, kAXHelpAttribute)]
        let text = fields.values.joined(separator: " ").lowercased()
        if role == kAXButtonRole as String || role == "AXMenuItem", keywords.contains(where: text.contains) {
            var entry = fields.filter { !$0.value.isEmpty }
            entry["role"] = role; entry["path"] = path
            found.append(entry)
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            walk(child, path: path + "/" + role, depth: depth + 1, visited: &visited, found: &found)
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }
}
#endif
