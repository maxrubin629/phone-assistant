import Foundation
import SwiftUI

struct CodexConnectionSection: View {
    @State private var connecting = false
    @State private var connected = false
    @State private var error = ""
    @State private var requestID = UUID()
    @AppStorage(CodexPhoneSessionStore.autoConnectKey) private var autoConnect = true

    var body: some View {
        Section {
            LabeledContent("Phone tools") {
                if connecting {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }
                } else {
                    HStack(spacing: 10) {
                        if connected { Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        Button(connected ? "Reconnect" : "Connect to Codex", action: connect)
                            .disabled(Self.bundledMCP == nil)
                    }
                }
            }
            Toggle("Connect when the call starts", isOn: $autoConnect)
            if Self.bundledMCP == nil {
                Label("The bundled connection tool is missing. Reinstall the app.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
        } header: {
            Text("Codex")
        } footer: {
            FormFooter(connected
                ? "Start a new Codex task to load the tools."
                : "Lets Codex prepare calls. When a call is prepared, the assistant joins as soon as you start that call in Phone. Questions and results go back to the task that started it.")
        }
    }

    private func connect() {
        guard !connecting else { return }
        guard let server = Self.bundledMCP else {
            error = "The bundled connection tool is missing. Reinstall the app."; return
        }
        guard let cli = Self.codexCLI else {
            error = "Codex was not found. Install Codex, then try again."; return
        }
        let operation = UUID()
        requestID = operation; connecting = true; connected = false; error = ""
        Task { @MainActor in
            let succeeded = await Self.register(cli: cli, server: server)
            guard requestID == operation else { return }
            connecting = false; connected = succeeded
            if !succeeded { error = "Could not connect to Codex. Open Codex and try again." }
        }
    }

    private static var bundledMCP: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let server = executable.deletingLastPathComponent().appendingPathComponent("CallMCP")
        return FileManager.default.isExecutableFile(atPath: server.path) ? server : nil
    }

    private static var codexCLI: URL? {
        var candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")
        ]
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        candidates += searchPath.split(separator: ":").filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The name Codex lists the tools under. Earlier builds used `codex_phone`,
    /// which registering removes so Codex doesn't load the tools twice.
    static let serverName = "phone_assistant"
    private static let legacyServerName = "codex_phone"

    private static func register(cli: URL, server: URL) async -> Bool {
        _ = await run(cli: cli, arguments: ["mcp", "remove", legacyServerName])
        return await run(cli: cli, arguments: ["mcp", "add", serverName, "--", server.path])
    }

    private static func run(cli: URL, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = cli
                process.arguments = arguments
                // Keep credentials out of the child environment and discard CLI output.
                let inherited = ProcessInfo.processInfo.environment
                process.environment = inherited.filter { ["HOME", "PATH", "TMPDIR", "CODEX_HOME", "USER", "LOGNAME"].contains($0.key) }
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                    guard finished.wait(timeout: .now() + 20) == .success else {
                        if process.isRunning { process.terminate() }
                        continuation.resume(returning: false); return
                    }
                    continuation.resume(returning: process.terminationReason == .exit && process.terminationStatus == 0)
                } catch { continuation.resume(returning: false) }
            }
        }
    }
}
