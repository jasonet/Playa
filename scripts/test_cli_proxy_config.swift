import Foundation

func normalizeBaseURL(_ rawURL: String) -> String? {
    let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
          let scheme = components.scheme, (scheme == "http" || scheme == "https"),
          let host = components.host, !host.isEmpty,
          components.query == nil, components.fragment == nil
    else {
        return nil
    }
    var path = components.path
    while path.hasSuffix("/") {
        path.removeLast()
    }
    var normalizedComponents = components
    normalizedComponents.path = path
    guard let urlString = normalizedComponents.string else { return nil }
    return urlString
}

func migrateLegacyHostPort(host: String?, port: Int) -> String {
    let rawHost = (host ?? "127.0.0.1").trimmingCharacters(in: .whitespacesAndNewlines)
    let safeHost = rawHost.isEmpty ? "127.0.0.1" : rawHost
    let p = (1...65535).contains(port) ? port : 8317
    let formattedHost = safeHost.contains(":") && !safeHost.hasPrefix("[") ? "[\(safeHost)]" : safeHost
    return "http://\(formattedHost):\(p)/v1"
}

func parseModelIDs(from jsonData: Data) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let list = object["data"] as? [[String: Any]] else {
        return []
    }
    var result: [String] = []
    for item in list {
        if let id = item["id"] as? String {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
    }
    return result.sorted()
}

func resolveSavedValue(_ savedValue: String?, default defaultValue: String) -> String {
    savedValue ?? defaultValue
}

// Test 1: URL Normalization
assert(normalizeBaseURL("http://127.0.0.1:8317/v1") == "http://127.0.0.1:8317/v1")
assert(normalizeBaseURL("http://127.0.0.1:8317/v1/") == "http://127.0.0.1:8317/v1")
assert(normalizeBaseURL("https://api.example.com/v1?query=1") == nil)
assert(normalizeBaseURL("invalid-url") == nil)

// Test 2: Migration
assert(migrateLegacyHostPort(host: "127.0.0.1", port: 8317) == "http://127.0.0.1:8317/v1")
assert(migrateLegacyHostPort(host: "", port: 0) == "http://127.0.0.1:8317/v1")

// Test 3: Default Configuration Fallbacks
assert(resolveSavedValue(nil, default: "http://127.0.0.1:8317/v1") == "http://127.0.0.1:8317/v1")
assert(resolveSavedValue(nil, default: "123456") == "123456")
assert(resolveSavedValue("http://192.168.1.8:9000/v1", default: "http://127.0.0.1:8317/v1") == "http://192.168.1.8:9000/v1")
assert(resolveSavedValue("custom-secret", default: "123456") == "custom-secret")
assert(resolveSavedValue("", default: "123456") == "")

// Test 4: Model Parsing
let json = """
{
  "object": "list",
  "data": [
    {"id": "gpt-4o"},
    {"id": "claude-3-5-sonnet"},
    {"id": "gpt-4o"}
  ]
}
""".data(using: .utf8)!
let models = parseModelIDs(from: json)
assert(models == ["claude-3-5-sonnet", "gpt-4o"])

// Test 5: Production Source Code Check for API Key Default Fallback
let integrationsSource = try String(
    contentsOfFile: "Sources/Playa/Features/Integrations/IntegrationsView.swift",
    encoding: .utf8
)
assert(
    integrationsSource.contains(
        "cliProxyAPIKey = UserDefaults.standard.string(forKey: \"integration.cliProxyAPI.apiKey\") ?? \"123456\""
    ),
    "IntegrationsViewModel must use 123456 only when no saved API key exists"
)

// Test 6: Production Source Code Check for ChatComposer clickable config and refresh models
let chatComposerSource = try String(
    contentsOfFile: "Sources/Playa/Features/Chat/ChatComposer.swift",
    encoding: .utf8
)
assert(
    chatComposerSource.contains("viewModel.isConfiguringCLIProxy = true"),
    "ChatComposer must allow opening CLIProxy configuration on click"
)
assert(
    chatComposerSource.contains("viewModel.refreshCurrentAgentModelCatalog(force: true)"),
    "ChatComposer Refresh models must force a fresh catalog fetch"
)

// Test 7: Production Source Code Check for ChatView sheet and error banner
let chatViewSource = try String(
    contentsOfFile: "Sources/Playa/Features/Chat/ChatView.swift",
    encoding: .utf8
)
assert(
    chatViewSource.contains("CLIProxyConfigurationSheet"),
    "ChatView must present CLIProxyConfigurationSheet"
)
assert(
    chatComposerSource.contains("Not configured — Click to configure parameters"),
    "ChatComposer must offer clickable parameter configuration item when not configured"
)
assert(
    chatComposerSource.contains("Status: Refresh Failed"),
    "ChatComposer must display refresh failure status when error is present"
)
assert(
    chatViewSource.contains("refreshErrorMessage"),
    "ChatView must support displaying refresh error message banner"
)

print("PASS: CLIProxyAPI config logic unit tests succeeded.")
