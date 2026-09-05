import Foundation
import PlayaServerKit

struct PrimeAgentPlan: Decodable, Sendable {
    struct Task: Decodable, Sendable {
        let id: String
        let role: String
        let task: String
        let dependencies: [String]
        let readOnly: Bool
    }
    let tasks: [Task]
}

struct PrimeAgentHarness: Sendable {
    static func run(
        prompt: String,
        workspace: URL,
        complete: @escaping NativeAgentRuntime.Complete,
        approval: @escaping NativeAgentRuntime.Approval,
        onEvent: @escaping NativeAgentRuntime.Event
    ) async throws {
        await onEvent(.status("Prime is decomposing the goal"))
        let rawPlan = try await complete([
            MLXChatMessage(role: "system", content: planPrompt),
            MLXChatMessage(role: "user", content: prompt),
        ])
        let planned = decodePlan(rawPlan, fallbackGoal: prompt)
        var snapshots = planned.map { AgentTaskSnapshot(id: $0.id, role: $0.role, title: $0.task, state: .waiting, detail: "Waiting", elapsedSeconds: nil) }
        await onEvent(.tasks(snapshots))
        var reports: [String: String] = [:]
        var remaining = planned

        while !remaining.isEmpty {
            try Task.checkCancellation()
            let ready = remaining.filter { task in task.dependencies.allSatisfy { reports[$0] != nil } }
            guard !ready.isEmpty else { throw NativeAgentHarnessError.invalidPlan }
            let readOnlyBatch = Array(ready.filter(\.readOnly).prefix(2))
            let batch = readOnlyBatch.isEmpty ? [ready[0]] : readOnlyBatch

            let results = try await withThrowingTaskGroup(of: (String, String).self) { group in
                for task in batch {
                    if let index = snapshots.firstIndex(where: { $0.id == task.id }) {
                        snapshots[index].state = .running
                        snapshots[index].detail = "Running"
                    }
                    await onEvent(.tasks(snapshots))
                    group.addTask {
                        let start = Date()
                        let dependencyContext = task.dependencies.compactMap { id in reports[id].map { "\(id): \($0)" } }.joined(separator: "\n")
                        let collector = TextCollector()
                        let runtime = NativeAgentRuntime(
                            complete: complete,
                            tools: NativeAgentToolExecutor(workspace: try NativeAgentWorkspace(root: workspace)),
                            approval: approval,
                            onEvent: { event in
                                if case .status(let status) = event { await collector.set(status) }
                            },
                            maxSteps: task.readOnly ? 10 : 16
                        )
                        let report = try await runtime.run(
                            goal: "Overall goal: \(prompt)\nYour assignment: \(task.task)\nDependency reports:\n\(dependencyContext)",
                            systemPrompt: "You are the \(task.role) subagent. Stay within your assignment. \(task.readOnly ? "Use read-only inspection tools; do not modify files." : "You may edit and test the workspace.") Return a precise report for the Prime coordinator."
                        )
                        _ = await collector.value
                        return (task.id, report + "\nElapsed: \(Date().timeIntervalSince(start))s")
                    }
                }
                var values: [(String, String)] = []
                for try await result in group { values.append(result) }
                return values
            }

            for (id, report) in results {
                reports[id] = report
                if let index = snapshots.firstIndex(where: { $0.id == id }) {
                    snapshots[index].state = .completed
                    snapshots[index].detail = report
                    if let marker = report.components(separatedBy: "Elapsed: ").last?.replacingOccurrences(of: "s", with: ""), let elapsed = Double(marker) {
                        snapshots[index].elapsedSeconds = elapsed
                    }
                }
                remaining.removeAll { $0.id == id }
            }
            await onEvent(.tasks(snapshots))
        }

        await onEvent(.status("Prime is synthesizing specialist reports"))
        let reportText = planned.compactMap { task in reports[task.id].map { "## \(task.role): \(task.task)\n\($0)" } }.joined(separator: "\n\n")
        let answer = try await complete([
            MLXChatMessage(role: "system", content: "You are Prime Agent. Synthesize the specialist reports into one accurate final response. Do not mention internal orchestration unless useful."),
            MLXChatMessage(role: "user", content: "Goal: \(prompt)\n\nReports:\n\(reportText)"),
        ])
        await onEvent(.text(answer))
    }

    static func decodePlan(_ text: String, fallbackGoal: String) -> [PrimeAgentPlan.Task] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded: PrimeAgentPlan? = {
            guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") else { return nil }
            return try? JSONDecoder().decode(PrimeAgentPlan.self, from: Data(trimmed[first...last].utf8))
        }()
        var seen = Set<String>()
        let normalized = (decoded?.tasks ?? []).prefix(4).compactMap { task -> PrimeAgentPlan.Task? in
            let id = task.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seen.contains(id) else { return nil }
            seen.insert(id)
            return .init(id: id, role: task.role.isEmpty ? "Specialist" : task.role, task: task.task, dependencies: task.dependencies.filter { $0 != id }, readOnly: task.readOnly)
        }
        return normalized.isEmpty ? [.init(id: "worker", role: "Generalist", task: fallbackGoal, dependencies: [], readOnly: false)] : normalized
    }

    private static let planPrompt = """
    You are Prime Agent, a coordinator. Return JSON only: {"tasks":[{"id":"unique-id","role":"specialist role","task":"specific assignment","dependencies":["id"],"readOnly":true}]}. Create 1-4 useful specialists. Mark inspection/research/review tasks readOnly=true. Mark any file-editing task false. Dependencies must reference earlier tasks. Prefer parallel independent research and one focused implementation owner.
    """
}

private actor TextCollector {
    var value = ""
    func set(_ text: String) { value = text }
}
