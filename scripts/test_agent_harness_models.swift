import Foundation

@main
enum AgentHarnessModelsTests {
    static func main() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Legacy","createdAt":0,"updatedAt":0,"messages":[],"kind":"agent","workingDirectory":"/tmp/work"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ChatSession.self, from: legacy)
        precondition(decoded.resolvedAgentHarnessKind == .fx)

        var session = decoded
        session.agentHarnessKind = .prime
        session.messages = [ChatTranscriptMessage(
            role: .assistant,
            content: "done",
            agentTasks: [AgentTaskSnapshot(id: "research", role: "Researcher", title: "Inspect", state: .completed, detail: "Found it", elapsedSeconds: 1.5)]
        )]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let roundTrip = try decoder.decode(ChatSession.self, from: encoder.encode(session))
        precondition(roundTrip.agentHarnessKind == .prime)
        precondition(roundTrip.messages.first?.agentTasks.first?.state == .completed)
        precondition(AgentHarnessKind.deep.displayName == "Deep Agent")
        precondition(AgentHarnessKind.prime.systemImage == "person.3.sequence")
        print("PASS: agent harness models persist and legacy agents default to Fx.")
    }
}
