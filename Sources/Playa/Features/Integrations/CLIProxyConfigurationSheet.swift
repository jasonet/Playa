import AppKit
import Foundation
import SwiftUI

struct CLIProxyConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var onSaved: (() -> Void)?

    @State private var baseURL: String
    @State private var apiKey: String
    @State private var defaultModelID: String
    @State private var isShowingAPIKey = false
    @State private var isTesting = false
    @State private var testStatusMessage: String?
    @State private var testStatusIsError: Bool = false
    @State private var fetchedModels: [String] = []

    init(onSaved: (() -> Void)? = nil) {
        self.onSaved = onSaved
        let defaults = UserDefaults.standard
        let savedBaseURL = defaults.string(forKey: "integration.cliProxyAPI.baseURL")
        let initialBaseURL: String
        if let savedBaseURL, !savedBaseURL.isEmpty {
            initialBaseURL = savedBaseURL
        } else {
            let legacyHost = defaults.string(forKey: "integration.cliProxyAPI.host")
            let legacyPort = defaults.integer(forKey: "integration.cliProxyAPI.port")
            let host = (legacyHost ?? "127.0.0.1").trimmingCharacters(in: .whitespacesAndNewlines)
            let port = (1...65535).contains(legacyPort) ? legacyPort : 8317
            initialBaseURL = "http://\(host.isEmpty ? "127.0.0.1" : host):\(port)/v1"
        }
        _baseURL = State(initialValue: initialBaseURL)
        _apiKey = State(initialValue: defaults.string(forKey: "integration.cliProxyAPI.apiKey") ?? "123456")
        _defaultModelID = State(initialValue: defaults.string(forKey: "integration.cliProxyAPI.defaultModelID") ?? "")
        _fetchedModels = State(initialValue: defaults.stringArray(forKey: "integration.cliProxyAPI.cachedModelIDs") ?? [])
    }

    private var cliProxyAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cpa.gui")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    instructionSection
                    connectionForm
                    statusSection
                    modelsSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 480, height: 460)
    }

    private var header: some View {
        HStack {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("EasyCLIProxyAPI Configuration")
                    .font(.headline)
                Text("Configure your local or remote CLIProxyAPI endpoint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let appURL = cliProxyAppURL {
                Button("Open App") {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var instructionSection: some View {
        Text("Provide the OpenAI-compatible Base URL and API Key for EasyCLIProxyAPI. By default, EasyCLIProxyAPI runs at http://127.0.0.1:8317/v1 with API key 123456.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Base URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Default") {
                        baseURL = "http://127.0.0.1:8317/v1"
                    }
                    .font(.caption2)
                    .buttonStyle(.link)
                }

                TextField("http://127.0.0.1:8317/v1", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API Key")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Default") {
                        apiKey = "123456"
                    }
                    .font(.caption2)
                    .buttonStyle(.link)
                }

                HStack {
                    if isShowingAPIKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isShowingAPIKey.toggle()
                    } label: {
                        Image(systemName: isShowingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await testAndFetchModels() }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                            .padding(.trailing, 4)
                    }
                    Label("Test Connection & Fetch Models", systemImage: "bolt.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isTesting)

                Spacer()
            }

            if let message = testStatusMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: testStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(testStatusIsError ? .orange : .green)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(testStatusIsError ? .orange : .green)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (testStatusIsError ? Color.orange : Color.green).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            }
        }
    }

    private var modelsSection: some View {
        Group {
            if !fetchedModels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $defaultModelID) {
                        ForEach(fetchedModels, id: \.self) { modelID in
                            Text(modelID).tag(modelID)
                        }
                    }
                    .labelsHidden()

                    Text("\(fetchedModels.count) models available")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Save & Apply") {
                saveAndApply()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func normalizeBaseURL(_ rawURL: String) -> String? {
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
        var norm = components
        norm.path = path
        return norm.string
    }

    private func testAndFetchModels() async {
        guard let cleanURL = normalizeBaseURL(baseURL) else {
            testStatusIsError = true
            testStatusMessage = "Invalid Base URL. Expected format: http://127.0.0.1:8317/v1"
            return
        }
        guard let url = URL(string: "\(cleanURL)/models") else {
            testStatusIsError = true
            testStatusMessage = "Invalid URL."
            return
        }

        isTesting = true
        testStatusMessage = nil
        testStatusIsError = false

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                testStatusIsError = true
                if http.statusCode == 401 || http.statusCode == 403 {
                    testStatusMessage = "Authentication failed (HTTP \(http.statusCode)). Please check your API Key."
                } else {
                    testStatusMessage = "CLIProxyAPI returned HTTP \(http.statusCode)."
                }
                isTesting = false
                return
            }

            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["data"] as? [[String: Any]] else {
                testStatusIsError = true
                testStatusMessage = "Invalid response JSON format from \(cleanURL)/models"
                isTesting = false
                return
            }

            let ids = entries.compactMap { $0["id"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let uniqueIDs = Array(Set(ids)).sorted()

            if uniqueIDs.isEmpty {
                testStatusIsError = true
                testStatusMessage = "Connected successfully, but CLIProxyAPI returned 0 models."
            } else {
                fetchedModels = uniqueIDs
                if defaultModelID.isEmpty || !uniqueIDs.contains(defaultModelID) {
                    defaultModelID = uniqueIDs.first ?? ""
                }
                testStatusIsError = false
                testStatusMessage = "Successfully connected! Found \(uniqueIDs.count) models."
            }
        } catch {
            testStatusIsError = true
            if let urlError = error as? URLError {
                switch urlError.code {
                case .cannotConnectToHost:
                    testStatusMessage = "Cannot connect to \(cleanURL) (Connection refused). Make sure EasyCLIProxyAPI is running."
                case .timedOut:
                    testStatusMessage = "Connection timed out to \(cleanURL)"
                default:
                    testStatusMessage = "Network error: \(urlError.localizedDescription)"
                }
            } else {
                testStatusMessage = "Error: \(error.localizedDescription)"
            }
        }
        isTesting = false
    }

    private func saveAndApply() {
        guard let cleanURL = normalizeBaseURL(baseURL) else {
            testStatusIsError = true
            testStatusMessage = "Invalid Base URL. Expected format: http://127.0.0.1:8317/v1"
            return
        }
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        defaults.set(cleanURL, forKey: "integration.cliProxyAPI.baseURL")
        defaults.set(cleanKey, forKey: "integration.cliProxyAPI.apiKey")
        if !defaultModelID.isEmpty {
            defaults.set(defaultModelID, forKey: "integration.cliProxyAPI.defaultModelID")
        }
        if !fetchedModels.isEmpty {
            defaults.set(fetchedModels, forKey: "integration.cliProxyAPI.cachedModelIDs")
            defaults.set(Date(), forKey: "integration.cliProxyAPI.modelsRefreshedAt")
        }

        // Persist runtime config for python backend
        if let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Playa", isDirectory: true) {
            try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let config: [String: Any] = [
                "baseURL": cleanURL,
                "apiKey": cleanKey,
                "defaultModelID": defaultModelID,
                "cachedModelIDs": fetchedModels
            ]
            if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: supportDirectory.appendingPathComponent("cli-proxy-api.json"), options: .atomic)
            }
        }

        onSaved?()
        dismiss()
    }
}
