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

    enum CodingKeys: String, CodingKey {
        case type
        case tool
        case arguments
        case status
        case answer
        case result
        case message
        case finalAnswer = "final_answer"
    }

    init(type: String, tool: String? = nil, arguments: [String: String]? = nil, status: String? = nil, answer: String? = nil) {
        self.type = type
        self.tool = tool
        self.arguments = arguments
        self.status = status
        self.answer = answer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tool = try container.decodeIfPresent(String.self, forKey: .tool)
        let rawAnswer = try container.decodeIfPresent(String.self, forKey: .answer)
            ?? container.decodeIfPresent(String.self, forKey: .finalAnswer)
            ?? container.decodeIfPresent(String.self, forKey: .result)
            ?? container.decodeIfPresent(String.self, forKey: .message)
        let status = try container.decodeIfPresent(String.self, forKey: .status)

        let rawType = try container.decodeIfPresent(String.self, forKey: .type)
        let resolvedType: String
        if let rawType {
            resolvedType = rawType
        } else if tool != nil {
            resolvedType = "tool"
        } else if rawAnswer != nil {
            resolvedType = "finish"
        } else {
            resolvedType = "unknown"
        }

        self.type = resolvedType
        self.tool = tool
        self.status = status
        self.answer = rawAnswer

        if let rawArgs = try? container.decode([String: FlexibleStringValue].self, forKey: .arguments) {
            self.arguments = rawArgs.mapValues(\.stringValue)
        } else {
            self.arguments = nil
        }
    }
}

private struct FlexibleStringValue: Decodable, Sendable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            stringValue = s
        } else if let i = try? container.decode(Int.self) {
            stringValue = String(i)
        } else if let d = try? container.decode(Double.self) {
            stringValue = String(d)
        } else if let b = try? container.decode(Bool.self) {
            stringValue = String(b)
        } else {
            stringValue = ""
        }
    }
}

struct NativeAgentRuntime: Sendable {
    typealias Complete = @Sendable (_ messages: [MLXChatMessage]) async throws -> String
    typealias Approval = NativeAgentToolExecutor.Approval
    typealias Event = @Sendable (AgentHarnessEvent) async -> Void

    let complete: Complete
    let tools: NativeAgentToolExecutor
    let approval: Approval
    let onEvent: Event
    var maxSteps = 25

    func run(goal: String, systemPrompt: String) async throws -> String {
        var messages = [
            MLXChatMessage(role: "system", content: systemPrompt + Self.protocolPrompt),
            MLXChatMessage(role: "user", content: goal),
        ]
        var lastStatus = "Planning next action"
        var recentActionSignatures: [String] = []

        for step in 1...maxSteps {
            try Task.checkCancellation()

            // If we've reached the final step of the budget, synthesize a best-effort response
            if step == maxSteps {
                messages.append(MLXChatMessage(
                    role: "user",
                    content: "Observation: Step budget limit reached (\(maxSteps) steps). Please provide your final response now, summarizing all findings, actions completed, and remaining tasks."
                ))
                await onEvent(.status("Step \(step)/\(maxSteps): synthesizing final summary"))
                let raw = try await complete(messages)
                if let action = Self.decodeAction(raw), let answer = action.answer, !answer.isEmpty {
                    return answer
                }
                let clean = Self.cleanModelOutput(raw)
                return clean.isEmpty ? "Completed \(maxSteps) steps. Last status: \(lastStatus)" : clean
            }

            await onEvent(.status("Step \(step)/\(maxSteps): planning next action"))
            let raw = try await complete(messages)
            guard let action = Self.decodeAction(raw) else {
                messages.append(MLXChatMessage(role: "assistant", content: raw))
                messages.append(MLXChatMessage(role: "user", content: "Observation: Return exactly one valid JSON action conforming to the protocol."))
                continue
            }
            if action.type == "finish", let answer = action.answer, !answer.isEmpty {
                return answer
            }
            guard action.type == "tool", let name = action.tool else {
                messages.append(MLXChatMessage(role: "user", content: "Observation: Invalid action type. Use {\"type\":\"tool\",...} or {\"type\":\"finish\",...}."))
                continue
            }

            let currentStatus = action.status ?? "Using \(name)"
            lastStatus = currentStatus
            let request = NativeAgentToolRequest(name: name, arguments: action.arguments ?? [:], status: action.status)
            await onEvent(.status(currentStatus))

            let signature = "\(name):\(action.arguments?.sorted(by: { $0.key < $1.key }).description ?? "")"
            recentActionSignatures.append(signature)
            let isRepeating = recentActionSignatures.suffix(3).count == 3 && Set(recentActionSignatures.suffix(3)).count == 1

            let result = await tools.execute(request, approval: approval)
            messages.append(MLXChatMessage(role: "assistant", content: raw))

            var observation = "Observation (\(result.isError ? "error" : "success")):\n\(result.output)"
            if isRepeating {
                observation += "\nNote: You have executed this exact tool call repeatedly. Please adjust your approach or conclude with a final answer."
            }
            messages.append(MLXChatMessage(role: "user", content: observation))
        }

        return "Completed \(maxSteps) steps. Last status: \(lastStatus)"
    }

    static func cleanModelOutput(_ text: String) -> String {
        var output = text
        while let start = output.range(of: "<think>", options: .caseInsensitive),
              let end = output.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<output.endIndex) {
            output.removeSubrange(start.lowerBound..<end.upperBound)
        }
        if let start = output.range(of: "<think>", options: .caseInsensitive), !output.contains("</think>") {
            output = String(output[..<start.lowerBound])
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeAction(_ text: String) -> NativeAgentAction? {
        let cleaned = cleanModelOutput(text)

        // 1. Check for markdown code fences
        if let blockRange = cleaned.range(of: "```json") ?? cleaned.range(of: "```") {
            let afterFence = cleaned[blockRange.upperBound...]
            if let closingFence = afterFence.range(of: "```") {
                let insideBlock = String(afterFence[..<closingFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let action = tryDecodeJSON(insideBlock) {
                    return action
                }
            }
        }

        // 2. Try whole string
        if let action = tryDecodeJSON(cleaned) {
            return action
        }

        // 3. Try outermost balanced/scanned JSON braces
        if let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}"), first < last {
            let candidate = String(cleaned[first...last])
            if let action = tryDecodeJSON(candidate) {
                return action
            }
        }

        return nil
    }

    private static func tryDecodeJSON(_ candidate: String) -> NativeAgentAction? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else { return nil }
        return try? JSONDecoder().decode(NativeAgentAction.self, from: Data(trimmed.utf8))
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
