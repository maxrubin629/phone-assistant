import Foundation

struct MicrophoneChoice: Equatable {
    let title: String
    let identifier: String
}

struct MicrophoneMenuState {
    let choices: [MicrophoneChoice]
    let selected: MicrophoneChoice
}

@MainActor protocol PhoneMicrophoneMenu: AnyObject {
    func open() async throws
    func state() throws -> MicrophoneMenuState
    func select(_ choice: MicrophoneChoice) throws
    func close()
}

public struct PhoneAutomationError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// One owner holds Phone's microphone selection until audio has stopped.
/// A failed selection retains its recovery record because AXPress can succeed
/// even when subsequent verification fails.
@MainActor public final class PhoneMicrophoneAutomation {
    public static let shared = PhoneMicrophoneAutomation(menu: AccessibilityPhoneMicrophoneMenu())
    private let menu: PhoneMicrophoneMenu
    private var owner: UUID?
    private var previous: MicrophoneChoice?
    private var destination: MicrophoneChoice?
    private var pending: Task<Void, Error>?
    private var restoring: Task<Void, Error>?

    init(menu: PhoneMicrophoneMenu) { self.menu = menu }

    public func connect(owner requestedOwner: UUID) async throws {
        guard owner == nil else {
            throw PhoneAutomationError("Another audio connection is using Phone's microphone. Disconnect it first.")
        }
        owner = requestedOwner
        let task = Task { @MainActor in
            defer { menu.close() }
            try await menu.open()
            try Task.checkCancellation()
            let state = try menu.state()
            let matches = state.choices.filter { $0.title == "Phone Assistant" }
            guard matches.count == 1, let target = matches.first else {
                throw PhoneAutomationError("Phone Assistant is not available in Phone's microphone menu. Enable Phone Assistant Audio Bridge in Audio setup and retry.")
            }
            guard state.selected != target else { return }
            previous = state.selected; destination = target
            try menu.select(target)
            try await verify(target)
        }
        pending = task
        // Stop cancels and drains this task before attempting restoration.
        try await task.value
    }

    public func disconnect(owner requestedOwner: UUID) async throws {
        guard owner == requestedOwner else { return }
        if let restoring { try await restoring.value; return }
        let task = Task { @MainActor in
            pending?.cancel()
            _ = await pending?.result
            pending = nil
            defer { menu.close() }
            if let previous, let destination {
                try await menu.open()
                let state = try menu.state()
                // Preserve a microphone change made by the user during the call.
                if state.selected == destination {
                    guard state.choices.contains(previous) else {
                        throw PhoneAutomationError("Phone's previous microphone is unavailable. Reconnect it and retry audio cleanup.")
                    }
                    try menu.select(previous)
                    try await verify(previous)
                }
            }
            previous = nil; destination = nil; owner = nil
        }
        restoring = task
        defer { restoring = nil }
        try await task.value
    }

    #if DEBUG
    /// Runs the real menu adapter without opening any audio or placing a call.
    public func checkSelectionAndRestoration() async throws -> [String: String] {
        guard owner == nil else { throw PhoneAutomationError("Disconnect audio before checking Phone selection.") }
        let checkOwner = UUID()
        func selected() async throws -> MicrophoneChoice {
            defer { menu.close() }
            try await menu.open()
            return try menu.state().selected
        }
        let before = try await selected()
        do {
            try await connect(owner: checkOwner)
            let during = try await selected()
            try await disconnect(owner: checkOwner)
            let after = try await selected()
            guard during.title == "Phone Assistant", after == before else {
                throw PhoneAutomationError("Microphone round-trip verification failed.")
            }
            return ["before": before.title, "connected": during.title, "restored": after.title]
        } catch {
            let failure = error
            do { try await disconnect(owner: checkOwner) }
            catch { throw PhoneAutomationError(failure.localizedDescription + " Cleanup: " + error.localizedDescription) }
            throw failure
        }
    }
    #endif

    private func verify(_ choice: MicrophoneChoice) async throws {
        for _ in 0..<12 {
            menu.close()
            try await Task.sleep(for: .milliseconds(100))
            try await menu.open()
            try Task.checkCancellation()
            if try menu.state().selected == choice { return }
        }
        throw PhoneAutomationError("Phone did not confirm the microphone change. Retry the connection.")
    }
}
