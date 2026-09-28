import AppKit
import ApplicationServices

@MainActor public enum PhoneAutomationPermission {
    public static var authorized: Bool { AXIsProcessTrusted() }
    public static var settingsPaneName: String {
        if #available(macOS 27.0, *) { return "Device Control and Data Access" }
        return "Accessibility"
    }

    public static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The Phone Audio menu is flat: a disabled Microphone heading, microphone
/// choices, a disabled Output heading, then output choices. Restrict all
/// selection and checkmark reads to the microphone section.
@MainActor final class AccessibilityPhoneMicrophoneMenu: PhoneMicrophoneMenu {
    private var audioMenu: AXUIElement?
    private var menuBarItem: AXUIElement?
    private var phone: NSRunningApplication?
    private var previousApplication: NSRunningApplication?

    func open() async throws {
        guard PhoneAutomationPermission.authorized else {
            PhoneAutomationPermission.request()
            throw PhoneAutomationError("Allow Phone Assistant in System Settings → Privacy & Security → \(PhoneAutomationPermission.settingsPaneName), then connect again. This lets Phone Assistant select Phone's microphone automatically.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mobilephone").first else {
            throw PhoneAutomationError("Open Phone and start or answer a call, then connect again.")
        }
        phone = app
        if previousApplication == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        app.activate(options: [])
        try await Task.sleep(for: .milliseconds(100))
        try Task.checkCancellation()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let rawBar = value(root, kAXMenuBarAttribute), CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { throw unavailable() }
        let bar = rawBar as! AXUIElement
        let matches = children(bar).filter {
            string($0, kAXIdentifierAttribute) == "com.apple.facetime.menu.video"
        }
        guard matches.count == 1, let item = matches.first else { throw unavailable() }
        menuBarItem = item
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw unavailable() }
        for _ in 0..<10 {
            try Task.checkCancellation()
            if let menu = children(item).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }),
               !children(menu).isEmpty {
                audioMenu = menu
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw unavailable()
    }

    func state() throws -> MicrophoneMenuState {
        let items = try microphoneItems()
        let marked = items.filter { !string($0, kAXMenuItemMarkCharAttribute).isEmpty }
        guard marked.count == 1, let current = marked.first else {
            throw PhoneAutomationError("Phone's selected microphone could not be read. Reopen Phone and retry.")
        }
        return MicrophoneMenuState(choices: items.map(choice), selected: choice(current))
    }

    func select(_ requested: MicrophoneChoice) throws {
        let matches = try microphoneItems().filter { choice($0) == requested }
        guard matches.count == 1, let item = matches.first,
              (value(item, kAXEnabledAttribute) as? Bool) == true else { throw unavailable() }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            throw PhoneAutomationError("Phone's microphone menu did not accept the selection. Retry the connection.")
        }
    }

    func close() {
        if let menu = audioMenu ?? menuBarItem { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
        audioMenu = nil; menuBarItem = nil
        if let previousApplication, NSWorkspace.shared.frontmostApplication?.processIdentifier == phone?.processIdentifier {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }

    private func microphoneItems() throws -> [AXUIElement] {
        guard let audioMenu else { throw unavailable() }
        let items = children(audioMenu)
        guard let start = items.firstIndex(where: { string($0, kAXTitleAttribute) == "Microphone" }),
              let end = items.indices.first(where: { $0 > start && string(items[$0], kAXTitleAttribute) == "Output" }),
              end > start + 1 else { throw unavailable() }
        return items[(start + 1)..<end].filter { !string($0, kAXTitleAttribute).isEmpty }
    }

    private func choice(_ item: AXUIElement) -> MicrophoneChoice {
        .init(title: string(item, kAXTitleAttribute), identifier: string(item, kAXIdentifierAttribute))
    }
    private func value(_ item: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func string(_ item: AXUIElement, _ attribute: String) -> String { value(item, attribute) as? String ?? "" }
    private func children(_ item: AXUIElement) -> [AXUIElement] { value(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func unavailable() -> PhoneAutomationError {
        PhoneAutomationError("Phone's microphone menu is unavailable or has changed. Automatic selection currently requires Phone's English Audio menu. Reopen Phone and retry.")
    }
}
