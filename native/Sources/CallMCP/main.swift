import CallControl
import Foundation

do {
    try MCPServer().run()
} catch {
    // stdout belongs exclusively to the MCP protocol.
    try? FileHandle.standardError.write(contentsOf: Data(("Phone Assistant MCP: " + error.localizedDescription + "\n").utf8))
    exit(1)
}
