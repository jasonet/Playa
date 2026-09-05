import Foundation
import PlayaServerKit

actor DeepTestCollector {
    var callCount = 0
    var events: [String] = []
    var finalAnswer: String = ""

    func nextResponse() -> String {
        callCount += 1
        if callCount == 1 {
            return "I will check files: invalid json here"
        } else if callCount == 2 {
            return """
            {"type":"tool","tool":"write_file","arguments":{"path":"hello.txt","content":"world"},"status":"Writing initial file"}
            """
        } else if callCount == 3 {
            return """
            {"type":"tool","tool":"read_file","arguments":{"path":"hello.txt"},"status":"Reading file back"}
            """
        } else {
            return """
            {"type":"finish","answer":"Successfully created and verified hello.txt containing world."}
            """
        }
    }

    func appendEvent(_ event: AgentHarnessEvent) {
        switch event {
        case .text(let t): finalAnswer += t
        case .status(let s): events.append(s)
        case .image: break
        case .tasks: break
        }
    }
}

@main
enum DeepAgentHarnessTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deep-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let collector = DeepTestCollector()
        let scriptedComplete: NativeAgentRuntime.Complete = { _ in
            await collector.nextResponse()
        }

        try await DeepAgentHarness.run(
            prompt: "Create hello.txt with world and verify",
            workspace: root,
            complete: scriptedComplete,
            approval: { _, _ in true },
            onEvent: { event in
                await collector.appendEvent(event)
            }
        )

        let written = try String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8)
        precondition(written == "world", "hello.txt must be written")
        let finalAnswer = await collector.finalAnswer
        precondition(finalAnswer.contains("Successfully created and verified"), "final answer must be received")
        let events = await collector.events
        precondition(events.contains(where: { $0.contains("Writing initial file") }), "tool status event must be emitted")
        print("PASS: Deep Agent plan-act-observe-reflect loop works and recovers from invalid output.")
    }
}
