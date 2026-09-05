import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let store = try String(contentsOfFile: "Sources/Playa/Features/Chat/ChatSessionStore.swift", encoding: .utf8)
let tools = try String(contentsOfFile: "Sources/Playa/Features/Chat/NativeAgentTools.swift", encoding: .utf8)
let runtime = try String(contentsOfFile: "Sources/Playa/Features/Chat/NativeAgentRuntime.swift", encoding: .utf8)
let deep = try String(contentsOfFile: "Sources/Playa/Features/Chat/DeepAgentHarness.swift", encoding: .utf8)
let prime = try String(contentsOfFile: "Sources/Playa/Features/Chat/PrimeAgentHarness.swift", encoding: .utf8)
let chat = try String(contentsOfFile: "Sources/Playa/Features/Chat/ChatView.swift", encoding: .utf8)
let panel = try String(contentsOfFile: "Sources/Playa/ControlPanelView.swift", encoding: .utf8)

require(store.contains("enum AgentHarnessKind"), "missing harness kind")
require(store.contains("var resolvedAgentHarnessKind: AgentHarnessKind { agentHarnessKind ?? .fx }"), "legacy sessions must default to Fx")
require(store.contains("var agentTasks: [AgentTaskSnapshot]"), "task snapshots must persist")
require(tools.contains("resolvingSymlinksInPath"), "workspace must resolve symlinks")
require(tools.contains("outsideWorkspace"), "workspace escape must be rejected")
require(tools.contains("git reset --hard") && tools.contains("git push --force"), "destructive Git must be denied")
require(tools.contains("sudo ") && tools.contains(".ssh/") && tools.contains(".env"), "privileged and credential access must be denied")
require(tools.contains("npm install") && tools.contains("curl ") && tools.contains("rm "), "install/network/delete must require confirmation")
require(runtime.contains("for step in 1...maxSteps"), "native loop must be bounded")
require(runtime.contains("Observation ("), "tool results must feed the observe loop")
require(deep.contains("Plan, Act, Observe, and Reflect"), "Deep strategy prompt missing")
require(prime.contains("prefix(4)"), "Prime must cap dynamic agents at four")
require(prime.contains("prefix(2)"), "Prime must cap read-only concurrency at two")
require(prime.contains("readOnlyBatch.isEmpty ? [ready[0]]"), "Prime writes must be serialized")
require(chat.contains("case .deep:") && chat.contains("case .prime:"), "chat routing must include native harnesses")
require(chat.contains("guard currentAgentHarnessKind == .fx else"), "native Agent model refresh must not invoke the Fx configurator")
require(chat.contains("completeCLIProxyAPIChat"), "native Agents must call CLIProxyAPI through its OpenAI-compatible endpoint")
require(chat.contains("Self.unroutedCLIProxyAPIModelID(modelID)"), "native CLIProxyAPI requests must remove the internal routing prefix")
require(chat.contains("currentAgentRequiresLocalGateway"), "native CLIProxyAPI must not require the local MLX gateway")
let composer = try String(contentsOfFile: "Sources/Playa/Features/Chat/ChatComposer.swift", encoding: .utf8)
require(composer.contains("private func selectAgentModel(_ modelID: String)"), "shared Agent model selection handler missing")
require(composer.contains("model.switchLanguageModel(to: modelID)"), "native local Agent selection must switch the Local Gateway model")
require(chat.contains("Allow Agent operation?"), "risk confirmation alert missing")
require(chat.contains("DisclosureGroup"), "expandable task panel missing")
require((panel.contains("Choose an Agent Harness") || panel.contains("Select Agent Harness")) && panel.contains("AgentHarnessKind.allCases"), "new Agent type chooser missing")
print("PASS: native Agent harness architecture, safety policy, routing, and UI are present.")
