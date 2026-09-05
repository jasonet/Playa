import Foundation
import PlayaServerKit

enum AgentHarnessEvent: Sendable {
    case text(String)
    case status(String)
    case image(ChatImageAttachment)
    case tasks([AgentTaskSnapshot])
}

struct NativeAgentAction: Decodable, Sendable {
    let type: String
    let tool: String?
    let arguments: [String: String]?
    let status: String?
    let answer: String?
}

struct NativeAgentRuntime: Sendable {
    typealias Complete = @Sendable (_ messages: [MLXChatMessage]) async throws -> String
    typealias Approval = NativeAgentToolExecutor.Approval
    typealias Event = @Sendable (AgentHarnessEvent) async -> Void

    let complete: Complete
    let tools: NativeAgentToolExecutor
    let approval: Approval
    let onEvent: Event
    var maxSteps = 20

    func run(goal: String, systemPrompt: String) async throws -> String {
        var messages = [
            MLXChatMessage(role: "system", content: systemPrompt + Self.protocolPrompt),
            MLXChatMessage(role: "user", content: goal),
        ]
        for step in 1...maxSteps {
            try Task.checkCancellation()
            await onEvent(.status("Step \(step): planning next action"))
            let raw = try await complete(messages)
            guard let action = Self.decodeAction(raw) else {
                messages.append(MLXChatMessage(role: "assistant", content: raw))
                messages.append(MLXChatMessage(role: "user", content: "Observation: Return exactly one valid JSON action."))
                continue
            }
            if action.type == "finish", let answer = action.answer, !answer.isEmpty {
                return answer
            }
            guard action.type == "tool", let name = action.tool else {
                messages.append(MLXChatMessage(role: "user", content: "Observation: Invalid action type."))
                continue
            }
            let request = NativeAgentToolRequest(name: name, arguments: action.arguments ?? [:], status: action.status)
            await onEvent(.status(action.status ?? "Using \(name)"))
            let result = await tools.execute(request, approval: approval)
            messages.append(MLXChatMessage(role: "assistant", content: raw))
            messages.append(MLXChatMessage(role: "user", content: "Observation (\(result.isError ? "error" : "success")):\n\(result.output)"))
        }
        throw NativeAgentHarnessError.stepLimit
    }

    static func decodeAction(_ text: String) -> NativeAgentAction? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") {
            candidate = String(trimmed[first...last])
        } else { return nil }
        return try? JSONDecoder().decode(NativeAgentAction.self, from: Data(candidate.utf8))
    }

    private static let protocolPrompt = """

You control workspace tools. Return exactly one JSON object per turn, with no markdown.
Tool action: {"type":"tool","tool":"list_files|read_file|search|write_file|shell","arguments":{"path":"...","query":"...","content":"...","command":"..."},"status":"short visible status"}
Final action: {"type":"finish","answer":"concise final response"}
Never claim a tool result before observing it. Prefer tests after edits.
"""
}

enum NativeAgentHarnessError: LocalizedError {
    case stepLimit
    case invalidPlan
    var errorDescription: String? {
        switch self {
        case .stepLimit: "Native Agent stopped after reaching its safety step limit."
        case .invalidPlan: "Prime Agent could not produce a valid task plan."
        }
    }
}
