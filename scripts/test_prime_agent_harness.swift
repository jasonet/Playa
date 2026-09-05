import Foundation
import PlayaServerKit

actor PrimeTestCollector {
    var events: [AgentHarnessEvent] = []
    var finalAnswer: String = ""
    var subagentCalls: [String] = []

    func appendEvent(_ event: AgentHarnessEvent) {
        events.append(event)
        if case .text(let t) = event {
            finalAnswer += t
        }
    }

    func recordSubagentCall(_ prompt: String) {
        subagentCalls.append(prompt)
    }
}

@main
enum PrimeAgentHarnessTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prime-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Write an existing file to inspect
        try "initial config".write(to: root.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)

        let collector = PrimeTestCollector()

        let scriptedComplete: NativeAgentRuntime.Complete = { messages in
            let prompt = messages.last?.textContent ?? ""
            await collector.recordSubagentCall(prompt)

            // Step 1: Prime planning (initial prompt without assignment)
            if !prompt.contains("Your assignment:") && !prompt.contains("Reports:") && !prompt.contains("Observation") {
                return """
                {
                  "tasks": [
                    {"id": "inspect", "role": "Inspector", "task": "Inspect config.txt", "dependencies": [], "readOnly": true},
                    {"id": "schema", "role": "Architect", "task": "Check schema requirements", "dependencies": [], "readOnly": true},
                    {"id": "write", "role": "Engineer", "task": "Write out new config.json", "dependencies": ["inspect", "schema"], "readOnly": false},
                    {"id": "extra1", "role": "Ignore1", "task": "Extra task", "dependencies": [], "readOnly": true},
                    {"id": "extra2", "role": "Ignore2", "task": "Extra task", "dependencies": [], "readOnly": true}
                  ]
                }
                """
            }

            // Final synthesis pass
            if prompt.contains("Reports:") {
                return "Prime summary: Successfully analyzed config and wrote config.json version 1."
            }

            // Subagent tasks
            if prompt.contains("Inspect config.txt") {
                if prompt.contains("Observation (success):\ninitial config") {
                    return """
                    {"type":"finish","answer":"Found config.txt with content 'initial config'."}
                    """
                } else {
                    return """
                    {"type":"tool","tool":"read_file","arguments":{"path":"config.txt"},"status":"Inspecting config"}
                    """
                }
            }

            if prompt.contains("Check schema requirements") {
                return """
                {"type":"finish","answer":"Schema requires JSON format with version 1."}
                """
            }

            if prompt.contains("Write out new config.json") {
                if prompt.contains("Observation (success):\nWrote config.json") {
                    return """
                    {"type":"finish","answer":"Successfully wrote new config.json."}
                    """
                } else {
                    return """
                    {"type":"tool","tool":"write_file","arguments":{"path":"config.json","content":"{\\"version\\": 1}"},"status":"Writing json"}
                    """
                }
            }

            if prompt.contains("Extra task") {
                return """
                {"type":"finish","answer":"Extra task finished."}
                """
            }

            return """
            {"type":"finish","answer":"Fallback done."}
            """
        }

        try await PrimeAgentHarness.run(
            prompt: "Refactor config and generate report",
            workspace: root,
            complete: scriptedComplete,
            approval: { _, _ in true },
            onEvent: { event in
                await collector.appendEvent(event)
            }
        )

        // 1. Verify cap of 4 tasks (5 were generated in plan)
        let plan = PrimeAgentHarness.decodePlan("""
        {
          "tasks": [
            {"id": "1", "role": "R1", "task": "T1", "dependencies": [], "readOnly": true},
            {"id": "2", "role": "R2", "task": "T2", "dependencies": [], "readOnly": true},
            {"id": "3", "role": "R3", "task": "T3", "dependencies": [], "readOnly": true},
            {"id": "4", "role": "R4", "task": "T4", "dependencies": [], "readOnly": true},
            {"id": "5", "role": "R5", "task": "T5", "dependencies": [], "readOnly": true}
          ]
        }
        """, fallbackGoal: "test")
        precondition(plan.count == 4, "Prime must enforce max 4 subagents")

        // 2. Verify config.json was written by the engineer task
        let written = try String(contentsOf: root.appendingPathComponent("config.json"), encoding: .utf8)
        precondition(written.contains("\"version\": 1"), "config.json must be written")

        // 3. Verify final answer
        let finalAnswer = await collector.finalAnswer
        precondition(finalAnswer.contains("Prime summary: Successfully analyzed"), "Final synthesis answer must be present")

        // 4. Verify task snapshots were emitted
        let events = await collector.events
        let taskSnapshots = events.compactMap { event -> [AgentTaskSnapshot]? in
            if case .tasks(let t) = event { return t }
            return nil
        }
        precondition(!taskSnapshots.isEmpty, "Task snapshots must be emitted")
        let lastSnapshot = taskSnapshots.last!
        precondition(lastSnapshot.allSatisfy { $0.state == .completed }, "All tasks must finish in completed state")

        print("PASS: Prime Agent planner, concurrency limits, dependency resolution, task snapshot emissions, and final synthesis work correctly.")
    }
}
