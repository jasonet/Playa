import Foundation
import PlayaServerKit

struct DeepAgentHarness: Sendable {
    static func run(
        prompt: String,
        workspace: URL,
        complete: @escaping NativeAgentRuntime.Complete,
        approval: @escaping NativeAgentRuntime.Approval,
        onEvent: @escaping NativeAgentRuntime.Event
    ) async throws {
        let runtime = NativeAgentRuntime(
            complete: complete,
            tools: NativeAgentToolExecutor(workspace: try NativeAgentWorkspace(root: workspace)),
            approval: approval,
            onEvent: onEvent
        )
        let answer = try await runtime.run(
            goal: prompt,
            systemPrompt: """
            You are Deep Agent, a capable single autonomous software agent. Work through Plan, Act, Observe, and Reflect cycles. Inspect the real workspace, make focused changes when needed, run relevant tests, recover from errors, and finish only when the goal is addressed.
            """
        )
        await onEvent(.text(answer))
    }
}
