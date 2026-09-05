import Foundation

@main
enum NativeAgentToolTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-agent-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = NativeAgentToolExecutor(workspace: try NativeAgentWorkspace(root: root))

        let write = await executor.execute(.init(name: "write_file", arguments: ["path": "Sources/value.txt", "content": "hello"], status: nil)) { _, _ in false }
        precondition(!write.isError)
        let read = await executor.execute(.init(name: "read_file", arguments: ["path": "Sources/value.txt"], status: nil)) { _, _ in false }
        precondition(read.output == "hello")

        let escape = await executor.execute(.init(name: "read_file", arguments: ["path": "../outside_secret.txt"], status: nil)) { _, _ in false }
        precondition(escape.isError && escape.output.contains("outside the workspace"))

        let deniedPath = await executor.execute(.init(name: "read_file", arguments: ["path": "/etc/passwd"], status: nil)) { _, _ in false }
        precondition(deniedPath.isError && deniedPath.output.contains("Blocked high-risk"))

        let denied = await executor.execute(.init(name: "shell", arguments: ["command": "sudo id"], status: nil)) { _, _ in true }
        precondition(denied.isError && denied.output.contains("Blocked high-risk"))

        let needsApproval = await executor.execute(.init(name: "shell", arguments: ["command": "rm Sources/value.txt"], status: nil)) { _, _ in false }
        precondition(needsApproval.isError && FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/value.txt").path))

        let shellWrite = await executor.execute(.init(name: "shell", arguments: ["command": "printf safe > result.txt"], status: nil)) { _, _ in false }
        precondition(!shellWrite.isError)
        let shellWrittenContent = try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8)
        precondition(shellWrittenContent == "safe")

        let outsideTarget = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("native-agent-escape-test-\(UUID().uuidString)")
        let outsideWrite = await executor.execute(.init(name: "shell", arguments: ["command": "printf bad > \(outsideTarget.path)"], status: nil)) { _, _ in false }
        precondition(outsideWrite.isError)
        precondition(!FileManager.default.fileExists(atPath: outsideTarget.path))
        print("PASS: native Agent tools enforce workspace and risk boundaries.")
    }
}
