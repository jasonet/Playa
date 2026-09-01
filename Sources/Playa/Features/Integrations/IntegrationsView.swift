import AppKit
import Combine
import SwiftUI

@MainActor
final class IntegrationsViewModel: ObservableObject {
    @Published var selectedTool: IntegrationTool?
    @Published var showsCLIProxyAPI = false
    @Published var showsOpenComputer = false
    @Published var selectedModelID: String?
    @Published var cliProxyBaseURL: String
    @Published var cliProxyAPIKey: String
    @Published var cliProxyDefaultModelID: String
    @Published var openComputerAPIKey: String
    @Published private(set) var cliProxyCachedModelIDs: [String] = []
    @Published private(set) var cliProxyModelsRefreshedAt: Date?
    @Published private(set) var isCheckingCLIProxyAPI = false
    @Published private(set) var cliProxyIsReachable = false
    @Published private(set) var cliProxyModelCount: Int?
    @Published private(set) var cliProxyError: String?
    @Published private(set) var statuses = Dictionary(
        uniqueKeysWithValues: IntegrationTool.allCases.map { ($0, IntegrationToolStatus.unavailable) }
    )
    @Published private(set) var isRefreshingStatuses = false
    @Published private(set) var activeOperation: IntegrationTool?
    @Published var errorMessage: String?

    let library = LocalModelLibrary()
    private let serverModel: PlayaModel
    private let profiles = IntegrationProfileManager()
    private let defaults = UserDefaults.standard
    private var libraryObservation: AnyCancellable?

    init(serverModel: PlayaModel) {
        self.serverModel = serverModel
        openComputerAPIKey = UserDefaults.standard.string(forKey: "integration.opencomputer.apiKey") ?? ""
        cliProxyAPIKey = UserDefaults.standard.string(forKey: "integration.cliProxyAPI.apiKey") ?? "123456"
        cliProxyDefaultModelID = UserDefaults.standard.string(forKey: "integration.cliProxyAPI.defaultModelID") ?? ""
        cliProxyCachedModelIDs = UserDefaults.standard.stringArray(forKey: "integration.cliProxyAPI.cachedModelIDs") ?? []
        if let time = UserDefaults.standard.object(forKey: "integration.cliProxyAPI.modelsRefreshedAt") as? Date {
            cliProxyModelsRefreshedAt = time
        } else {
            cliProxyModelsRefreshedAt = nil
        }
        let savedBaseURL = UserDefaults.standard.string(forKey: "integration.cliProxyAPI.baseURL")
        if let savedBaseURL, !savedBaseURL.isEmpty {
            cliProxyBaseURL = savedBaseURL
        } else {
            let legacyHost = UserDefaults.standard.string(forKey: "integration.cliProxyAPI.host")
            let legacyPort = UserDefaults.standard.integer(forKey: "integration.cliProxyAPI.port")
            let host = (legacyHost ?? "127.0.0.1").trimmingCharacters(in: .whitespacesAndNewlines)
            let p = (1...65535).contains(legacyPort) ? legacyPort : 8317
            let computedBaseURL = "http://\(host.isEmpty ? "127.0.0.1" : host):\(p)/v1"
            cliProxyBaseURL = computedBaseURL
            UserDefaults.standard.set(computedBaseURL, forKey: "integration.cliProxyAPI.baseURL")
        }
        libraryObservation = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var eligibleModels: [IntegrationModelDescriptor] {
        library.models
            .filter {
                ($0.capabilities.contains(.text) || $0.capabilities.contains(.vision))
                    && !$0.capabilities.contains(.imageGeneration)
                    && !$0.capabilities.contains(.embeddings)
            }
            .map(IntegrationModelDescriptor.init)
    }

    var loadedModelID: String? {
        serverModel.metrics?.server.loadedModel ?? serverModel.settings.normalized().languageModelID
    }

    var selectedModel: IntegrationModelDescriptor? {
        guard let selectedModelID else { return nil }
        return eligibleModels.first { $0.id == selectedModelID }
    }

    var isBusy: Bool { activeOperation != nil }

    func appear() {
        library.scan(path: serverModel.settings.modelSearchPath)
        refreshStatuses()
        if cliProxyCachedModelIDs.isEmpty {
            refreshCLIProxyModels()
        } else {
            cliProxyIsReachable = true
            cliProxyModelCount = cliProxyCachedModelIDs.count
        }
    }

    func modelsDidChange() {
        library.scan(path: serverModel.settings.modelSearchPath)
    }

    func select(_ tool: IntegrationTool) {
        showsCLIProxyAPI = false
        showsOpenComputer = false
        selectedTool = tool
        resolveSelectedModel()
    }

    func selectCLIProxyAPI() {
        selectedTool = nil
        showsOpenComputer = false
        showsCLIProxyAPI = true
        if cliProxyCachedModelIDs.isEmpty {
            refreshCLIProxyModels()
        } else {
            cliProxyIsReachable = true
            cliProxyModelCount = cliProxyCachedModelIDs.count
        }
    }

    func selectOpenComputer() {
        selectedTool = nil
        showsCLIProxyAPI = false
        showsOpenComputer = true
    }

    func saveOpenComputerConfiguration() {
        let key = openComputerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        openComputerAPIKey = key
        defaults.set(key, forKey: "integration.opencomputer.apiKey")
    }

    var cliProxyApplicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.cpa.gui")
    }

    var normalizedCLIProxyBaseURL: String? {
        let trimmed = cliProxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme, (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        var norm = components
        norm.path = path
        return norm.string
    }

    func saveCLIProxyConfiguration() {
        guard let baseURL = normalizedCLIProxyBaseURL else {
            cliProxyError = "Enter a valid HTTP/HTTPS base URL (e.g. http://127.0.0.1:8317/v1)."
            return
        }
        cliProxyBaseURL = baseURL
        defaults.set(baseURL, forKey: "integration.cliProxyAPI.baseURL")
        defaults.set(cliProxyAPIKey, forKey: "integration.cliProxyAPI.apiKey")
        defaults.set(cliProxyDefaultModelID, forKey: "integration.cliProxyAPI.defaultModelID")
        persistCLIProxyRuntimeConfiguration(baseURL: baseURL)
        refreshCLIProxyModels()
    }

    func refreshCLIProxyModels() {
        guard !isCheckingCLIProxyAPI else { return }
        guard let baseURL = normalizedCLIProxyBaseURL, let url = URL(string: "\(baseURL)/models") else {
            cliProxyIsReachable = false
            cliProxyError = "Enter a valid HTTP/HTTPS base URL."
            return
        }

        isCheckingCLIProxyAPI = true
        cliProxyError = nil
        persistCLIProxyRuntimeConfiguration(baseURL: baseURL)

        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let key = cliProxyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(http.statusCode) else {
                    cliProxyIsReachable = false
                    cliProxyError = http.statusCode == 401
                        ? "Authentication failed. Check the API key."
                        : "CLIProxyAPI returned HTTP \(http.statusCode)."
                    isCheckingCLIProxyAPI = false
                    return
                }

                let fetchedModelIDs = parseCLIProxyModelIDs(from: data)
                if fetchedModelIDs.isEmpty {
                    cliProxyIsReachable = false
                    cliProxyError = "CLIProxyAPI returned no models."
                    isCheckingCLIProxyAPI = false
                    return
                }

                cliProxyCachedModelIDs = fetchedModelIDs
                cliProxyModelCount = fetchedModelIDs.count
                cliProxyIsReachable = true
                cliProxyError = nil
                let now = Date()
                cliProxyModelsRefreshedAt = now

                defaults.set(fetchedModelIDs, forKey: "integration.cliProxyAPI.cachedModelIDs")
                defaults.set(now, forKey: "integration.cliProxyAPI.modelsRefreshedAt")

                if !fetchedModelIDs.contains(cliProxyDefaultModelID) {
                    cliProxyDefaultModelID = fetchedModelIDs.first ?? ""
                    defaults.set(cliProxyDefaultModelID, forKey: "integration.cliProxyAPI.defaultModelID")
                }
            } catch {
                cliProxyIsReachable = false
                cliProxyError = "CLIProxyAPI is not reachable at \(baseURL)."
            }
            isCheckingCLIProxyAPI = false
        }
    }

    private func parseCLIProxyModelIDs(from jsonData: Data) -> [String] {
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

    func openCLIProxyAPI() {
        guard let url = cliProxyApplicationURL else {
            cliProxyError = "EasyCLIProxyAPI is not installed."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func copyCLIProxyValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func persistCLIProxyRuntimeConfiguration(baseURL: String) {
        guard let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Playa", isDirectory: true) else { return }
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "baseURL": baseURL,
                    "apiKey": cliProxyAPIKey,
                    "defaultModelID": cliProxyDefaultModelID,
                    "cachedModelIDs": cliProxyCachedModelIDs
                ],
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(
                to: supportDirectory.appendingPathComponent("cli-proxy-api.json"),
                options: .atomic
            )
        } catch {
            cliProxyError = "Couldn’t save CLIProxyAPI runtime configuration: \(error.localizedDescription)"
        }
    }

    func resolveSelectedModel() {
        guard !eligibleModels.isEmpty else {
            selectedModelID = nil
            return
        }
        if let selectedModelID, eligibleModels.contains(where: { $0.id == selectedModelID }) {
            return
        }
        if let loadedModelID, eligibleModels.contains(where: { $0.id == loadedModelID }) {
            selectedModelID = loadedModelID
        } else {
            selectedModelID = eligibleModels.first?.id
        }
    }

    func refreshStatuses() {
        guard !isRefreshingStatuses else { return }
        isRefreshingStatuses = true
        Task {
            var refreshed: [IntegrationTool: IntegrationToolStatus] = [:]
            for tool in IntegrationTool.allCases {
                refreshed[tool] = await profiles.status(for: tool)
            }
            statuses = refreshed
            isRefreshingStatuses = false
        }
    }

    func configure(_ tool: IntegrationTool) {
        guard let selectedModelID else {
            errorMessage = IntegrationServiceError.noModel.localizedDescription
            return
        }
        activeOperation = tool
        do {
            try configureProfile(tool: tool, selectedModelID: selectedModelID)
            if tool == .codex {
                try profiles.configureCodexDesktop(selectedModelID: selectedModelID)
            }
            var status = statuses[tool] ?? .unavailable
            status.isConfigured = true
            statuses[tool] = status
        } catch {
            errorMessage = error.localizedDescription
        }
        activeOperation = nil
    }

    func configureAndOpen(_ tool: IntegrationTool, workingDirectory: URL) {
        guard let selectedModelID else {
            errorMessage = IntegrationServiceError.noModel.localizedDescription
            return
        }
        guard let executableURL = statuses[tool]?.executableURL else {
            errorMessage = IntegrationServiceError.missingExecutable(tool).localizedDescription
            return
        }

        rememberWorkingDirectory(workingDirectory, for: tool)
        activeOperation = tool
        Task {
            do {
                try configureProfile(tool: tool, selectedModelID: selectedModelID)
                var status = statuses[tool] ?? .unavailable
                status.isConfigured = true
                statuses[tool] = status

                try await prepareServer(modelID: selectedModelID)
                try profiles.launch(
                    tool: tool,
                    executableURL: executableURL,
                    selectedModelID: selectedModelID,
                    workingDirectory: workingDirectory
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            activeOperation = nil
        }
    }

    func configureAndOpenCodexDesktop(workingDirectory: URL) {
        let tool = IntegrationTool.codex
        guard let selectedModelID else {
            errorMessage = IntegrationServiceError.noModel.localizedDescription
            return
        }
        guard let executableURL = statuses[tool]?.executableURL else {
            errorMessage = IntegrationServiceError.missingExecutable(tool).localizedDescription
            return
        }

        rememberWorkingDirectory(workingDirectory, for: tool)
        activeOperation = tool
        Task {
            do {
                try configureProfile(tool: tool, selectedModelID: selectedModelID)
                try profiles.configureCodexDesktop(selectedModelID: selectedModelID)
                var status = statuses[tool] ?? .unavailable
                status.isConfigured = true
                statuses[tool] = status

                try await prepareServer(modelID: selectedModelID)
                try profiles.launchCodexDesktop(
                    executableURL: executableURL,
                    selectedModelID: selectedModelID,
                    workingDirectory: workingDirectory
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            activeOperation = nil
        }
    }

    func workingDirectory(for tool: IntegrationTool) -> URL? {
        guard let path = defaults.string(forKey: workingDirectoryKey(for: tool)) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func rememberWorkingDirectory(_ url: URL, for tool: IntegrationTool) {
        defaults.set(url.path, forKey: workingDirectoryKey(for: tool))
        objectWillChange.send()
    }

    func revealConfiguration(for tool: IntegrationTool) {
        let url = profiles.configurationURL(for: tool)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    func launchCommand(for tool: IntegrationTool, workingDirectory: URL) -> String? {
        guard let selectedModelID, let executableURL = statuses[tool]?.executableURL else {
            return nil
        }
        return profiles.launchCommand(
            tool: tool,
            executableURL: executableURL,
            selectedModelID: selectedModelID,
            workingDirectory: workingDirectory
        )
    }

    func copyLaunchCommand(for tool: IntegrationTool, workingDirectory: URL) {
        guard let command = launchCommand(for: tool, workingDirectory: workingDirectory) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func configureProfile(tool: IntegrationTool, selectedModelID: String) throws {
        try profiles.configure(
            tool: tool,
            selectedModelID: selectedModelID,
            models: eligibleModels,
            maxOutputTokens: serverModel.settings.normalized().maxTokens
        )
    }

    func codexDesktopLaunchCommand(workingDirectory: URL) -> String? {
        guard
            let selectedModelID,
            let executableURL = statuses[.codex]?.executableURL
        else { return nil }
        return profiles.codexDesktopLaunchCommand(
            executableURL: executableURL,
            selectedModelID: selectedModelID,
            workingDirectory: workingDirectory
        )
    }

    func copyCodexDesktopLaunchCommand(workingDirectory: URL) {
        guard let command = codexDesktopLaunchCommand(workingDirectory: workingDirectory) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    private func prepareServer(modelID: String) async throws {
        // Keep the process alive and hot-swap its text-generation cache through
        // the management endpoint. The harness also sends this model on every
        // inference request, so subsequent responses stay on the selection.
        // Check the listener before starting a process because an earlier app
        // session may still own the bundled server on port 8080.
        if await inferenceEndpointIsReady() {
            try await loadModelThroughEndpoint(modelID)
            return
        }

        if !serverModel.isRunning {
            serverModel.startServer()
        }

        let deadline = Date().addingTimeInterval(300)
        var stoppedPolls = 0
        while Date() < deadline {
            if await inferenceEndpointIsReady() {
                try await loadModelThroughEndpoint(modelID)
                return
            }

            if serverModel.isRunning {
                stoppedPolls = 0
            } else {
                stoppedPolls += 1
                if stoppedPolls >= 10 {
                    throw IntegrationServiceError.serverUnavailable
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw IntegrationServiceError.serverUnavailable
    }

    private func inferenceEndpointIsReady() async -> Bool {
        do {
            // /v1/models is part of the public inference API and does not
            // require a management API key. It also proves the listener that
            // the harness will use is ready.
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/models")!)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    private func loadModelThroughEndpoint(_ modelID: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/v1/models/load")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelID])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IntegrationServiceError.modelLoadFailed(modelID, "The server returned an invalid response.")
            }
            if (200..<300).contains(http.statusCode) {
                return
            }

            // Older bundled servers do not expose the management endpoint.
            // Every harness request still includes the selected model, so the
            // inference server will load it on demand and stream the response.
            if http.statusCode == 404 {
                return
            }

            throw IntegrationServiceError.modelLoadFailed(
                modelID,
                serverErrorMessage(from: data) ?? "The server returned HTTP \(http.statusCode)."
            )
        } catch let error as IntegrationServiceError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw IntegrationServiceError.modelLoadTimedOut(modelID)
        } catch {
            throw IntegrationServiceError.modelLoadFailed(modelID, error.localizedDescription)
        }
    }

    private func serverErrorMessage(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = object["detail"] as? String,
           !detail.isEmpty {
            return detail
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    private func workingDirectoryKey(for tool: IntegrationTool) -> String {
        "integration.\(tool.rawValue).workingDirectory"
    }
}

struct IntegrationsView: View {
    @StateObject private var viewModel: IntegrationsViewModel

    init(model: PlayaModel) {
        _viewModel = StateObject(wrappedValue: IntegrationsViewModel(serverModel: model))
    }

    var body: some View {
        Group {
            if viewModel.showsOpenComputer {
                OpenComputerIntegrationDetailView(viewModel: viewModel)
            } else if viewModel.showsCLIProxyAPI {
                CLIProxyAPIIntegrationDetailView(viewModel: viewModel)
            } else if let selectedTool = viewModel.selectedTool {
                IntegrationDetailView(tool: selectedTool, viewModel: viewModel)
            } else {
                IntegrationCatalogView(viewModel: viewModel)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: viewModel.appear)
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            viewModel.modelsDidChange()
        }
        .onChange(of: viewModel.library.models) { _, _ in
            viewModel.resolveSelectedModel()
        }
        .alert("Integration Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }
}

private struct IntegrationCatalogView: View {
    @ObservedObject var viewModel: IntegrationsViewModel
    private let columns = [
        GridItem(.adaptive(minimum: 245, maximum: 330), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Integrations")
                        .font(.largeTitle.bold())
                    Text("Run your coding tools with models served from this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.refreshStatuses()
                } label: {
                    if viewModel.isRefreshingStatuses {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRefreshingStatuses)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    OpenComputerIntegrationCard(viewModel: viewModel) {
                        viewModel.selectOpenComputer()
                    }

                    CLIProxyAPIIntegrationCard(viewModel: viewModel) {
                        viewModel.selectCLIProxyAPI()
                    }

                    ForEach(IntegrationTool.allCases) { tool in
                        IntegrationCard(
                            tool: tool,
                            status: viewModel.statuses[tool] ?? .unavailable,
                            isLoading: viewModel.isRefreshingStatuses
                        ) {
                            viewModel.select(tool)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct OpenComputerIntegrationCard: View {
    @ObservedObject var viewModel: IntegrationsViewModel
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 13))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("OpenComputer")
                        .font(.title3.bold())
                    Text("Cloud microVM sandboxes & agent scaling")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    if !viewModel.openComputerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Configured · Cloud sandboxes active")
                    } else {
                        Image(systemName: "circle.dashed")
                        Text("Free $10 credit · Optional API key")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 175, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? Color.orange.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isHovering ? Color.orange.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Configure OpenComputer")
    }
}

private struct OpenComputerIntegrationDetailView: View {
    @ObservedObject var viewModel: IntegrationsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    viewModel.showsOpenComputer = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("All integrations")

                Image(systemName: "cloud.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenComputer")
                        .font(.title2.bold())
                    Text("Cloud microVM runtime for agent sandboxing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    connectionPanel
                    featuresPanel
                }
                .padding(24)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            let hasKey = !viewModel.openComputerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Circle()
                .fill(hasKey ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(hasKey ? "Key Configured" : "Local-Only by Default")
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    private var connectionPanel: some View {
        IntegrationPanel(title: "Authentication & API Key", systemImage: "key.fill") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("API Key").foregroundStyle(.secondary)
                    SecureField("OpenComputer API Key (optional)", text: $viewModel.openComputerAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Save Key") {
                    viewModel.saveOpenComputerConfiguration()
                }
                .buttonStyle(.borderedProminent)

                Button("Get Free $10 Credit Key →") {
                    if let url = URL(string: "https://opencomputer.dev") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }

            Text("Local-Only mode works completely free without any API key. Configure your OpenComputer Key when you need isolated cloud MicroVM sandboxes, headless browsers, or remote background execution.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var featuresPanel: some View {
        IntegrationPanel(title: "Execution Modes in Playa", systemImage: "slider.horizontal.2.square") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local-Only Mode")
                            .font(.callout.weight(.medium))
                        Text("Zero setup, 100% free, runs entirely on your Mac with native tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cloud")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenComputer Enhanced Mode")
                            .font(.callout.weight(.medium))
                        Text("Elastic cloud Linux microVMs with pre-installed browsers, ffmpeg, full network egress, and checkpoint/fork.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CLIProxyAPIIntegrationCard: View {
    @ObservedObject var viewModel: IntegrationsViewModel
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Image(systemName: "arrow.trianglehead.branch")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 13))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("CLIProxyAPI")
                        .font(.title3.bold())
                    Text("Unified OpenAI, Claude, and Gemini proxy")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    if viewModel.isCheckingCLIProxyAPI {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else if viewModel.cliProxyIsReachable {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(viewModel.cliProxyModelCount.map { "Online · \($0) models" } ?? "Online")
                    } else if viewModel.cliProxyApplicationURL != nil {
                        Image(systemName: "power").foregroundStyle(.orange)
                        Text("Installed · offline")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text("Not installed")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 175, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? Color.indigo.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isHovering ? Color.indigo.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Configure CLIProxyAPI")
    }
}

private struct CLIProxyAPIIntegrationDetailView: View {
    @ObservedObject var viewModel: IntegrationsViewModel
    @State private var showAPIKey = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    viewModel.showsCLIProxyAPI = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("All integrations")

                Image(systemName: "arrow.trianglehead.branch")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text("EasyCLIProxyAPI").font(.title2.bold())
                    Text("Local multi-provider compatibility gateway")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    connectionPanel
                    actionsPanel
                }
                .frame(maxWidth: 760)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            if viewModel.isCheckingCLIProxyAPI {
                ProgressView().controlSize(.small)
                Text("Checking")
            } else {
                Circle()
                    .fill(viewModel.cliProxyIsReachable ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(viewModel.cliProxyIsReachable ? "Online" : "Offline")
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.09), in: Capsule())
    }

    private var connectionPanel: some View {
        IntegrationPanel(title: "Connection Configuration", systemImage: "network") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Base URL").foregroundStyle(.secondary)
                    TextField("http://127.0.0.1:8317/v1", text: $viewModel.cliProxyBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("API Key").foregroundStyle(.secondary)
                    HStack {
                        if showAPIKey {
                            TextField("Optional API Key", text: $viewModel.cliProxyAPIKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Optional API Key", text: $viewModel.cliProxyAPIKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Default Model").foregroundStyle(.secondary)
                    if viewModel.cliProxyCachedModelIDs.isEmpty {
                        Text("No models fetched yet")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        Picker("", selection: $viewModel.cliProxyDefaultModelID) {
                            ForEach(viewModel.cliProxyCachedModelIDs, id: \.self) { modelID in
                                Text(modelID).tag(modelID)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: viewModel.cliProxyDefaultModelID) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "integration.cliProxyAPI.defaultModelID")
                        }
                    }
                }
            }

            if let error = viewModel.cliProxyError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if viewModel.cliProxyIsReachable {
                HStack(spacing: 8) {
                    Label(
                        viewModel.cliProxyModelCount.map { "Connected · \($0) models cached" } ?? "Connected",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)

                    if let lastRefreshed = viewModel.cliProxyModelsRefreshedAt {
                        Text("· Updated \(lastRefreshed.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Save & Test") { viewModel.saveCLIProxyConfiguration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isCheckingCLIProxyAPI)
                Button("Refresh Models") { viewModel.refreshCLIProxyModels() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isCheckingCLIProxyAPI)
            }

            Text("Enter your complete OpenAI-compatible API URL (e.g. http://127.0.0.1:8317/v1). Fetching models updates the cached model picker.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsPanel: some View {
        IntegrationPanel(title: "EasyCLIProxyAPI", systemImage: "app") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.cliProxyApplicationURL == nil ? "Application not installed" : "Application installed")
                        .font(.callout.weight(.medium))
                    Text("Manage OAuth accounts, upstream providers, API keys, aliases, and the proxy core in EasyCLIProxyAPI.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open EasyCLIProxyAPI") { viewModel.openCLIProxyAPI() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.cliProxyApplicationURL == nil)
            }
        }
    }
}

private struct IntegrationCard: View {
    let tool: IntegrationTool
    let status: IntegrationToolStatus
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    IntegrationLogo(tool: tool, size: 52)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(tool.displayName)
                        .font(.title3.bold())
                    Text(tool.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                    } else if status.executableURL == nil {
                        Image(systemName: "arrow.down.circle")
                        Text("Not installed")
                    } else if status.isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Configured")
                    } else {
                        Image(systemName: "gearshape")
                        Text("Ready to configure")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 175, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHovering ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isHovering ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Configure \(tool.displayName)")
    }
}

private struct IntegrationDetailView: View {
    let tool: IntegrationTool
    @ObservedObject var viewModel: IntegrationsViewModel
    @State private var workingDirectory: URL?

    private var status: IntegrationToolStatus {
        viewModel.statuses[tool] ?? .unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    viewModel.selectedTool = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .help("All integrations")

                IntegrationLogo(tool: tool, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.displayName).font(.title2.bold())
                    Text(tool.summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                IntegrationAvailabilityBadge(status: status)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if status.executableURL == nil, !viewModel.isRefreshingStatuses {
                        missingToolPanel
                    } else {
                        modelPanel
                        projectPanel
                        launchCommandPanel
                        configurationPanel
                        actionBar
                    }
                }
                .frame(maxWidth: 760)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            workingDirectory = viewModel.workingDirectory(for: tool)
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private var missingToolPanel: some View {
        IntegrationPanel(title: "Installation required", systemImage: "arrow.down.app") {
            Text("Install \(tool.displayName), then return here and refresh its status.")
                .foregroundStyle(.secondary)
            HStack {
                Button("View installation guide") {
                    NSWorkspace.shared.open(tool.installURL)
                }
                .buttonStyle(.borderedProminent)
                Button("Check again") {
                    viewModel.refreshStatuses()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var modelPanel: some View {
        IntegrationPanel(title: "Model", systemImage: "cube.transparent") {
            if viewModel.library.isScanning && viewModel.eligibleModels.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Scanning installed models…").foregroundStyle(.secondary)
                }
            } else if viewModel.eligibleModels.isEmpty {
                Text("No installed chat models were found. Download one from the Models page first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $viewModel.selectedModelID) {
                    ForEach(viewModel.eligibleModels) { model in
                        Text(model.id).tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if let selected = viewModel.selectedModel {
                    HStack(spacing: 8) {
                        if selected.id == viewModel.loadedModelID {
                            IntegrationPill(title: "Loaded", systemImage: "bolt.fill", color: .green)
                        }
                        if let context = selected.contextWindow {
                            IntegrationPill(title: formatContext(context), systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        if selected.supportsVision {
                            IntegrationPill(title: "Vision", systemImage: "eye")
                        }
                        if selected.supportsReasoning {
                            IntegrationPill(title: "Reasoning", systemImage: "brain")
                        }
                    }
                    if !selected.supportsTools {
                        Label(
                            "Tool calling was not detected for this model. The integration can open, but coding actions may fail.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var projectPanel: some View {
        IntegrationPanel(title: "Project folder", systemImage: "folder") {
            HStack(spacing: 10) {
                Text(workingDirectory?.path ?? "Choose a folder")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFolder)
                    .buttonStyle(.bordered)
            }
            Text("\(tool.displayName) opens in this folder. The last folder is remembered for this tool.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configurationPanel: some View {
        IntegrationPanel(title: "Managed configuration", systemImage: "gearshape.2") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                IntegrationConfigurationRow(label: "Endpoint", value: IntegrationProfileManager.openAIBaseURL)
                IntegrationConfigurationRow(label: "Profile", value: IntegrationProfileManager.providerID)
                IntegrationConfigurationRow(label: "Model loading", value: "On demand · no restart")
                IntegrationConfigurationRow(label: "Responses", value: "Streaming")
                if let version = status.version {
                    IntegrationConfigurationRow(label: "Version", value: version)
                }
            }
            if tool == .codex {
                Text("Codex Desktop reads ~/.codex/config.toml. Configuring this integration makes the selected local model its default while preserving unrelated Codex settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Show configuration in Finder") {
                viewModel.revealConfiguration(for: tool)
            }
            .buttonStyle(.link)
        }
    }

    private var launchCommandPanel: some View {
        IntegrationPanel(title: "Launch command", systemImage: "terminal") {
            if let workingDirectory,
               let command = viewModel.launchCommand(for: tool, workingDirectory: workingDirectory) {
                if tool == .codex {
                    Text("CLI")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                if tool == .codex,
                   let desktopCommand = viewModel.codexDesktopLaunchCommand(workingDirectory: workingDirectory) {
                    Text("Desktop app")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        Text(desktopCommand)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Text(tool == .codex
                         ? "Choose Terminal or the Codex desktop app after the server is ready."
                         : "This is the command opened in Terminal after the server is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if tool == .codex {
                        Button {
                            viewModel.copyCodexDesktopLaunchCommand(workingDirectory: workingDirectory)
                        } label: {
                            Label("Copy Desktop", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }
                    Button {
                        viewModel.copyLaunchCommand(for: tool, workingDirectory: workingDirectory)
                    } label: {
                        Label(tool == .codex ? "Copy CLI" : "Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Choose a model and project folder to generate the command.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Configure") {
                viewModel.configure(tool)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy || viewModel.selectedModelID == nil)

            Spacer()

            if tool == .codex {
                Button {
                    guard let workingDirectory else { return }
                    viewModel.configureAndOpen(tool, workingDirectory: workingDirectory)
                } label: {
                    if viewModel.activeOperation == tool {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…")
                        }
                    } else {
                        Label("Open CLI", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.selectedModelID == nil || workingDirectory == nil)
            } else {
                Button {
                    guard let workingDirectory else { return }
                    viewModel.configureAndOpen(tool, workingDirectory: workingDirectory)
                } label: {
                    if viewModel.activeOperation == tool {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…")
                        }
                    } else {
                        Label(status.isConfigured ? "Open \(tool.displayName)" : "Configure & Open", systemImage: "terminal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy || viewModel.selectedModelID == nil || workingDirectory == nil)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project for \(tool.displayName)"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workingDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectory = url
        viewModel.rememberWorkingDirectory(url, for: tool)
    }

    private func formatContext(_ count: Int) -> String {
        count >= 1_000 ? "\(count / 1_000)K context" : "\(count) context"
    }
}

private struct IntegrationLogo: View {
    let tool: IntegrationTool
    let size: CGFloat

    var body: some View {
        Image(tool.logoAssetName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            .accessibilityHidden(true)
    }
}

private struct IntegrationAvailabilityBadge: View {
    let status: IntegrationToolStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.executableURL == nil ? Color.secondary : (status.isConfigured ? .green : .orange))
                .frame(width: 7, height: 7)
            Text(status.executableURL == nil ? "Not installed" : (status.isConfigured ? "Configured" : "Not configured"))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }
}

private struct IntegrationPanel<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct IntegrationConfigurationRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private struct IntegrationPill: View {
    let title: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }
}
