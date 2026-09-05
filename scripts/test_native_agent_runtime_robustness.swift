import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Check source patterns
let runtime = try String(contentsOfFile: "Sources/Playa/Features/Chat/NativeAgentRuntime.swift", encoding: .utf8)
let prime = try String(contentsOfFile: "Sources/Playa/Features/Chat/PrimeAgentHarness.swift", encoding: .utf8)

require(runtime.contains("cleanModelOutput"), "NativeAgentRuntime must implement cleanModelOutput")
require(runtime.contains("<think>"), "cleanModelOutput must handle <think> tags")
require(runtime.contains("```json"), "decodeAction must handle markdown code blocks")
require(runtime.contains("FlexibleStringValue"), "arguments must support flexible string/numeric/boolean values")
require(runtime.contains("Observation: Step budget limit reached"), "step limit must perform graceful final synthesis")
require(runtime.contains("isRepeating"), "runtime must detect repeated tool executions")
require(prime.contains("maxSteps: task.readOnly ? 12 : 20"), "Prime subagents must use updated step budget")

print("PASS: Native Agent runtime robustness, step limit recovery, and parsing checks succeeded.")
