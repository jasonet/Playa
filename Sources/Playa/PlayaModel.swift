import Combine
import Foundation
import PlayaServerKit

struct SessionTokenActivitySample: Equatable, Sendable {
    let recordedAt: Date
    let promptTokens: Int
    let generatedTokens: Int

    var totalTokens: Int {
        promptTokens + generatedTokens
    }
}

enum PlayaServerState: Equatable {
    case stopped
    case starting
    case running
    case error(String)
}

@MainActor
final class PlayaModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var serverState: PlayaServerState = .stopped
    @Published private(set) var logText = ""
    @Published private(set) var metrics: PlayaMetrics?
    @Published private(set) var lastMetricsError: String?
    @Published private(set) var lastMetricsFetchAt: Date?
    @Published private(set) var allTimeStats = PlayaAllTimeStats()
    @Published private(set) var sessionTokenActivity: [SessionTokenActivitySample] = []
    @Published private(set) var modelSwitchInProgress = false
    @Published private(set) var metricsLoading = false
    @Published private(set) var loadedServerModelID: String?
    @Published var settings = PlayaSettings.load() {
        didSet {
            settings.save()
        }
    }

    var menuIsOpen = false
    var onMenuStateChanged: (() -> Void)?

    private let server = PlayaProcessController()
    private let ggufController = PlayaGGUFController()
    private let metricsClient = PlayaMetricsClient()
    private let modelsClient = PlayaModelsClient()
    private var metricsFetchTask: Task<Void, Never>?
    private var metricsTimer: Timer?
    private var metricsStartupGraceUntil: Date?
    private var settingsAppliedAtServerStart: PlayaSettings?
    private var previousSessionPromptTokenCount: Int?
    private var previousSessionGeneratedTokenCount: Int?
    private var preservedSessionMetrics: PlayaMetrics?
    private var preservedSessionTokenActivity: [SessionTokenActivitySample] = []
    private var isStoppingForModelSwitch = false
    @Published private(set) var selectedModelName: String?
    @Published private(set) var selectedModelSizeLabel: String?
    private var selectedModelPath: String?
    @Published private(set) var isGGUFRunning = false
    let modelHistory = ModelHistoryStore()
    @Published private(set) var ggufLoadingModelID: String?
    private var ggufLogText = ""
    private var ggufMetricsTask: Task<Void, Never>?
    private var ggufMetricsTimer: Timer?
    private let healthClient = PlayaServerHealthClient(timeout: 5)
    private var serverStartupTask: Task<Void, Never>?
    private let serverStartupTimeout: TimeInterval = 120

    private let maxLogCharacters = 250_000
    private let maxSessionActivitySamples = 120

    init() {
        PlayaAllTimeStats.removeLegacyStorage()
        allTimeStats = PlayaAllTimeStats.load(from: currentAnalyticsDatabaseURL())
        configureServerCallbacks()
        isRunning = server.isRunning
        if server.isRunning {
            serverState = .running
        }
    }

    var metricsAreStale: Bool {
        guard let lastMetricsFetchAt else {
            return true
        }
        return Date().timeIntervalSince(lastMetricsFetchAt) >= 5
    }

    var loadedModelDisplay: String {
        guard let loaded = metrics?.server.loadedModel else { return "None" }
        // Strip the local filesystem path, showing only org/model or model name.
        let components = loaded.split(separator: "/").map(String.init)
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return loaded
    }

    var sessionStatsDisplayMetrics: PlayaMetrics? {
        metrics ?? preservedSessionMetrics
    }

    var sessionStatsDisplayTokenActivity: [SessionTokenActivitySample] {
        metrics == nil ? preservedSessionTokenActivity : sessionTokenActivity
    }

    var sessionStatsArePreserved: Bool {
        metrics == nil && preservedSessionMetrics != nil
    }

    var selectedModelDisplay: String {
        settings.normalized().languageModelID ?? "On demand"
    }

    var analyticsDatabaseURL: URL {
        currentAnalyticsDatabaseURL(runtimePath: metrics?.server.analyticsDatabasePath)
    }

    var unavailableMetricsText: String {
        lastMetricsError == nil ? "Waiting for server..." : "Metrics unavailable"
    }

    var settingsRequireRestart: Bool {
        guard isRunning, let settingsAppliedAtServerStart else {
            return false
        }
        return !settings.hasSameLaunchConfiguration(as: settingsAppliedAtServerStart)
    }

    func startServer() {
        serverState = .starting
        isRunning = true

        do {
            var launchEnvironment = settings.launchEnvironment
            launchEnvironment["MLX_PLATFORM_ANALYTICS_DB_PATH"] = currentAnalyticsDatabaseURL().path
            let args = settings.launchArguments(withModelPath: selectedModelPath)
            appendLog("\n--- Server Launch Diagnostics ---\n")
            appendLog("selectedModelPath: \(selectedModelPath ?? "nil")\n")
            appendLog("languageModelID: \(settings.languageModelID ?? "nil")\n")
            appendLog("Launch arguments: \(args.joined(separator: " "))\n")
            try server.start(
                arguments: args,
                environment: launchEnvironment
            )
            settingsAppliedAtServerStart = settings.normalized()
            appendLog("\nStarted mlx-vlm-server. Waiting for server to become ready...\n")
            recordModelStartup(args: args)
        } catch PlayaError.alreadyRunning {
            settingsAppliedAtServerStart = settings.normalized()
            appendLog("\nmlx-vlm-server is already running. Checking health...\n")
        } catch {
            appendLog("\nFailed to start mlx-vlm-server: \(error)\n")
            serverState = .error("\(error)")
            isRunning = false
            notifyMenuStateChanged()
            return
        }

        startMetricsPolling()
        startServerHealthPolling()
        notifyMenuStateChanged()
    }

    private func startServerHealthPolling() {
        serverStartupTask?.cancel()
        serverStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.serverStartupTimeout)

            while !Task.isCancelled {
                let health = await self.healthClient.checkHealth()

                switch health {
                case .ready:
                    // Health endpoint is up; verify model is actually loaded via metrics.
                    let serverAPIKey = self.settingsAppliedAtServerStart?.serverAPIKey
                    if let fetchedMetrics = try? await self.metricsClient.fetchMetrics(apiKey: serverAPIKey),
                       let loadedModel = fetchedMetrics.server.loadedModel {
                        // IMPORTANT: Use the full local path as the model ID for chat requests.
                        // The server identifies loaded models by their local filesystem path.
                        // Passing a HuggingFace repo ID instead would cause the server to
                        // unload the local model and attempt to re-download from HuggingFace.
                        self.loadedServerModelID = loadedModel
                        self.appendLog("\nmlx-vlm-server is ready. Model loaded: \(fetchedMetrics.server.displayLoadedModel)\n")
                        self.serverState = .running
                        return
                    }
                    // Server is up but model still loading — keep polling.
                    if Date() > deadline {
                        self.serverState = .error("Server did not become ready within \(Int(self.serverStartupTimeout))s. It may be stuck loading the model. Check the Developer log for details.")
                        self.appendLog("\nServer startup timed out after \(Int(self.serverStartupTimeout))s.\n")
                        return
                    }
                    self.appendLog("Server is up, waiting for model to finish loading...\n")
                case .loading(let msg):
                    if Date() > deadline {
                        self.serverState = .error("Server did not become ready within \(Int(self.serverStartupTimeout))s. It may be stuck loading the model. Check the Developer log for details.")
                        self.appendLog("\nServer startup timed out after \(Int(self.serverStartupTimeout))s.\n")
                        return
                    }
                    if let msg {
                        self.appendLog("Server loading: \(msg)\n")
                    }
                case .error(let msg):
                    self.serverState = .error(msg)
                    self.appendLog("\nServer health check failed: \(msg)\n")
                    return
                case .unknown:
                    break
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)  // poll every 2s
            }
        }
    }

    func stopServer(preserveSessionStats: Bool = false) {
        serverStartupTask?.cancel()
        serverStartupTask = nil
        persistDecodeSpeedToHistory()
        serverState = .stopped
        loadedServerModelID = nil
        if preserveSessionStats {
            preserveCurrentSessionStats()
        } else {
            modelSwitchInProgress = false
            clearPreservedSessionStats()
        }

        do {
            appendLog("\nStopping mlx-vlm-server...\n")
            try server.stop()
        } catch PlayaError.notRunning {
            appendLog("\nmlx-vlm-server is not running.\n")
        } catch {
            appendLog("\nFailed to stop mlx-vlm-server: \(error)\n")
        }

        isRunning = server.isRunning
        if server.isRunning {
            serverState = .running
        }
        if !isRunning {
            settingsAppliedAtServerStart = nil
        }
        stopMetricsPolling(clearSession: true)
        notifyMenuStateChanged()
    }

    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    func selectModel(to modelID: String?, displayName: String? = nil, sizeLabel: String? = nil, modelPath: String? = nil) {
        var nextSettings = settings
        nextSettings.languageModelID = modelID
        settings.languageModelID = nextSettings.normalized().languageModelID
        selectedModelName = displayName ?? (modelID?.split(separator: "/").last.map(String.init) ?? modelID)
        selectedModelSizeLabel = sizeLabel
        selectedModelPath = modelPath
        if let modelID {
            let provider = LocalModelProviderResolver.resolve(repoID: modelID, modelType: nil, architectures: [])
            modelHistory.record(
                modelID: modelID,
                displayName: displayName,
                sizeLabel: sizeLabel,
                modelPath: modelPath,
                provider: provider
            )
        }
        notifyMenuStateChanged()
    }

    func startSelectedModel() {
        let modelID = settings.normalized().languageModelID
        guard modelID != nil, !modelSwitchInProgress else { return }

        modelSwitchInProgress = true
        notifyMenuStateChanged()

        Task { @MainActor [weak self] in
            guard let self else { return }

            if self.server.isRunning {
                self.isStoppingForModelSwitch = true
                self.stopServer(preserveSessionStats: true)
                await Task.yield()
                self.isStoppingForModelSwitch = false
            }

            guard !self.server.isRunning else {
                self.appendLog("\nCould not stop the current server.\n")
                self.modelSwitchInProgress = false
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
                return
            }
            self.startServer()
            if !self.server.isRunning {
                self.modelSwitchInProgress = false
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
            }
        }
    }

    func switchLanguageModel(to modelID: String?) {
        guard !modelSwitchInProgress else {
            return
        }

        var nextSettings = settings
        nextSettings.languageModelID = modelID
        let normalizedModelID = nextSettings.normalized().languageModelID
        let selectionIsAlreadyApplied = settings.normalized().languageModelID == normalizedModelID
            && server.isRunning
            && !settingsRequireRestart
        guard !selectionIsAlreadyApplied else {
            return
        }

        settings.languageModelID = normalizedModelID
        if let modelID {
            let provider = LocalModelProviderResolver.resolve(repoID: modelID, modelType: nil, architectures: [])
            modelHistory.record(
                modelID: modelID,
                displayName: nil,
                sizeLabel: nil,
                modelPath: nil,
                provider: provider
            )
        }
        modelSwitchInProgress = true
        notifyMenuStateChanged()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            if self.server.isRunning {
                self.isStoppingForModelSwitch = true
                self.stopServer(preserveSessionStats: true)
                await Task.yield()
                self.isStoppingForModelSwitch = false
            }

            guard !self.server.isRunning else {
                self.appendLog("\nCould not stop the current server to switch models.\n")
                self.modelSwitchInProgress = false
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
                return
            }
            self.startServer()
            if !self.server.isRunning {
                self.modelSwitchInProgress = false
                self.clearPreservedSessionStats()
                self.notifyMenuStateChanged()
            }
        }
    }

    func applicationWillTerminate() {
        stopMetricsPolling(clearSession: true)
        if server.isRunning {
            try? server.stop(timeout: 2)
        }
        isRunning = false
        settingsAppliedAtServerStart = nil
    }

    func resetSettings() {
        settings = PlayaSettings()
    }

    func clearLogs() {
        logText = ""
    }

    func refreshMetricsIfRunning(force: Bool = false) {
        isRunning = server.isRunning
        if server.isRunning {
            serverState = .running
        }
        guard isRunning else {
            stopMetricsPolling(clearSession: true)
            notifyMenuStateChanged()
            return
        }
        guard metricsFetchTask == nil else {
            return
        }
        guard force || metricsAreStale else {
            return
        }

        let client = metricsClient
        let serverAPIKey = settingsAppliedAtServerStart?.serverAPIKey
        metricsFetchTask = Task { [weak self] in
            do {
                let fetchedMetrics = try await client.fetchMetrics(apiKey: serverAPIKey)
                await MainActor.run {
                    self?.handleMetricsFetchSuccess(fetchedMetrics)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.metricsFetchTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.handleMetricsFetchFailure(error)
                }
            }
        }
    }

    func startGGUFServer(for model: LocalModel) {
        guard !isGGUFRunning, let snapshotURL = model.snapshotURL else { return }

        let ggufFile: URL?
        if model.format == .gguf {
            ggufFile = findGGUFFile(in: snapshotURL)
        } else {
            appendLog("\nGGUF server only supports GGUF models.\n")
            return
        }

        guard let ggufFile else {
            appendLog("\nCould not find .gguf file in \(snapshotURL.path)\n")
            return
        }

        let port = settings.ggufServerPort

        ggufController.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.appendGGUFLog(text)
            }
        }

        ggufController.onTermination = { [weak self] status in
            Task { @MainActor in
                self?.isGGUFRunning = false
                self?.ggufLoadingModelID = nil
                if status != 0 {
                    self?.appendGGUFLog("\nllama-server exited with status \(status)\n")
                }
            }
        }

        do {
            ggufLoadingModelID = model.repoID
            appendGGUFLog("\nStarting llama-server with \(model.displayName)...\n")
            try ggufController.start(modelPath: ggufFile.path, port: port)
            isGGUFRunning = true
            startGGUFHealthPolling()
        } catch PlayaError.alreadyRunning {
            isGGUFRunning = true
            appendGGUFLog("\nllama-server is already running.\n")
        } catch {
            ggufLoadingModelID = nil
            appendGGUFLog("\nFailed to start llama-server: \(error)\n")
        }
    }

    func stopGGUFServer() {
        ggufLoadingModelID = nil
        stopGGUFHealthPolling()

        do {
            appendGGUFLog("\nStopping llama-server...\n")
            try ggufController.stop()
        } catch PlayaError.notRunning {
            appendGGUFLog("\nllama-server is not running.\n")
        } catch {
            appendGGUFLog("\nFailed to stop llama-server: \(error)\n")
        }

        if !ggufController.isRunning {
            isGGUFRunning = false
        }
    }

    func forceKillServer() {
        serverStartupTask?.cancel()
        serverStartupTask = nil
        server.forceKill()
        isRunning = false
        serverState = .stopped
        loadedServerModelID = nil
        settingsAppliedAtServerStart = nil
        stopMetricsPolling(clearSession: true)
        metricsLoading = false
        appendLog("\nForce killed mlx-vlm-server.\n")
        notifyMenuStateChanged()
    }

    func forceKillGGUFServer() {
        appendGGUFLog("\nForce-killing llama-server...\n")
        ggufController.forceKill()
        isGGUFRunning = false
        ggufLoadingModelID = nil
    }

    private func findGGUFFile(in url: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.first { $0.pathExtension.lowercased() == "gguf" }
    }

    private func startGGUFHealthPolling() {
        stopGGUFHealthPolling()
        ggufMetricsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if !self.ggufController.isRunning {
                    await MainActor.run { self.isGGUFRunning = false; self.ggufLoadingModelID = nil }
                    break
                }
                let url = self.ggufController.healthCheckURL()
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        await MainActor.run { self.ggufLoadingModelID = nil }
                    }
                } catch {
                    // Server still starting
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopGGUFHealthPolling() {
        ggufMetricsTask?.cancel()
        ggufMetricsTask = nil
        ggufMetricsTimer?.invalidate()
        ggufMetricsTimer = nil
    }

    private func appendGGUFLog(_ text: String) {
        ggufLogText.append(text)
        if ggufLogText.count > 100_000 {
            ggufLogText.removeFirst(ggufLogText.count - 100_000)
        }
    }

    /// Persists the current session's average decode speed to the model history
    /// store so it can be displayed next to each model in the sidebar.
    private func persistDecodeSpeedToHistory() {
        guard let modelID = settings.languageModelID,
              let speed = metrics?.summary.averageDecodeTokensPerSecond,
              speed > 0, speed.isFinite
        else { return }
        modelHistory.recordDecodeSpeed(modelID: modelID, decodeTokensPerSecond: speed)
    }

    private func configureServerCallbacks() {
        server.onOutput = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.appendLog(text)
            }
        }
        server.onTermination = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.persistDecodeSpeedToHistory()
                self?.appendLog("\nmlx-vlm-server stopped with status \(status)\n")
                self?.isRunning = false
                self?.serverState = .stopped
                self?.loadedServerModelID = nil
                self?.settingsAppliedAtServerStart = nil
                self?.stopMetricsPolling(clearSession: true)
                self?.metricsLoading = false
                if self?.isStoppingForModelSwitch != true {
                    self?.modelSwitchInProgress = false
                    self?.clearPreservedSessionStats()
                }
                self?.notifyMenuStateChanged()
            }
        }
    }

    private func startMetricsPolling() {
        lastMetricsError = nil
        metrics = nil
        metricsLoading = true
        sessionTokenActivity = []
        previousSessionPromptTokenCount = nil
        previousSessionGeneratedTokenCount = nil
        metricsStartupGraceUntil = Date().addingTimeInterval(20)

        if metricsTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.refreshMetricsIfRunning(force: self.metricsLoading)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            metricsTimer = timer
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.refreshMetricsIfRunning(force: true)
        }
    }

    private func stopMetricsPolling(clearSession: Bool) {
        metricsFetchTask?.cancel()
        metricsFetchTask = nil
        metricsTimer?.invalidate()
        metricsTimer = nil
        lastMetricsError = nil
        lastMetricsFetchAt = nil
        metricsStartupGraceUntil = nil
        metricsLoading = false

        if clearSession {
            metrics = nil
            sessionTokenActivity = []
            previousSessionPromptTokenCount = nil
            previousSessionGeneratedTokenCount = nil
        }
    }

    private func handleMetricsFetchSuccess(_ fetchedMetrics: PlayaMetrics) {
        metricsFetchTask = nil
        lastMetricsFetchAt = Date()
        guard server.isRunning else {
            isRunning = false
            metrics = nil
            notifyMenuStateChanged()
            return
        }

        isRunning = true
        lastMetricsError = nil
        metricsStartupGraceUntil = nil
        metricsLoading = false
        recordSessionActivity(
            promptTokenCount: fetchedMetrics.summary.promptTokensTotal,
            generatedTokenCount: fetchedMetrics.summary.generatedTokensTotal
        )
        metrics = fetchedMetrics
        modelSwitchInProgress = false
        clearPreservedSessionStats()
        refreshAllTimeStats(runtimePath: fetchedMetrics.server.analyticsDatabasePath)

        if menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func handleMetricsFetchFailure(_ error: Error) {
        metricsFetchTask = nil
        lastMetricsError = isTransientStartupMetricsError(error) ? nil : error.localizedDescription

        if !menuIsOpen {
            notifyMenuStateChanged()
        }
    }

    private func isTransientStartupMetricsError(_ error: Error) -> Bool {
        guard let metricsStartupGraceUntil, Date() < metricsStartupGraceUntil else {
            return false
        }
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }

    private func recordModelStartup(args: [String]) {
        guard let modelID = settings.normalized().languageModelID else { return }

        let s = settings.normalized()
        var notes: [String] = []
        notes.append("maxTokens: \(s.maxTokens)")
        notes.append("temp: \(String(format: "%.2f", s.temperature))")
        if s.maxKVSize > 0 { notes.append("maxKV: \(s.maxKVSize)") }
        if s.kvQuantizationEnabled { notes.append("kvBits: \(s.kvBits)") }
        if s.thinkingEnabled { notes.append("thinking: on") }
        if let modelPathArg = args.first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") || $0.contains(".lmstudio") || $0.contains("huggingface") }) {
            notes.append("path: \(modelPathArg)")
        }

        modelHistory.recordStartup(
            modelID: modelID,
            environmentNotes: notes.joined(separator: ", ")
        )
    }

    private func appendLog(_ text: String) {
        logText.append(text)
        if logText.count > maxLogCharacters {
            logText.removeFirst(logText.count - maxLogCharacters)
        }
    }

    private func recordSessionActivity(promptTokenCount: Int, generatedTokenCount: Int) {
        let promptDelta = tokenDelta(
            current: promptTokenCount,
            previous: previousSessionPromptTokenCount
        )
        let generatedDelta = tokenDelta(
            current: generatedTokenCount,
            previous: previousSessionGeneratedTokenCount
        )

        sessionTokenActivity.append(SessionTokenActivitySample(
            recordedAt: Date(),
            promptTokens: promptDelta,
            generatedTokens: generatedDelta
        ))
        if sessionTokenActivity.count > maxSessionActivitySamples {
            sessionTokenActivity.removeFirst(sessionTokenActivity.count - maxSessionActivitySamples)
        }
        previousSessionPromptTokenCount = promptTokenCount
        previousSessionGeneratedTokenCount = generatedTokenCount
    }

    private func tokenDelta(current: Int, previous: Int?) -> Int {
        guard let previous, current >= previous else {
            return 0
        }
        return current - previous
    }

    private func preserveCurrentSessionStats() {
        if let metrics {
            preservedSessionMetrics = metrics
            preservedSessionTokenActivity = sessionTokenActivity
        }
    }

    private func clearPreservedSessionStats() {
        preservedSessionMetrics = nil
        preservedSessionTokenActivity = []
    }

    private func refreshAllTimeStats(runtimePath: String? = nil) {
        allTimeStats = PlayaAllTimeStats.load(
            from: currentAnalyticsDatabaseURL(runtimePath: runtimePath)
        )
    }

    private func currentAnalyticsDatabaseURL(runtimePath: String? = nil) -> URL {
        if let runtimePath = runtimePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimePath.isEmpty {
            return URL(fileURLWithPath: runtimePath).standardizedFileURL
        }
        return PlayaAnalyticsStore.defaultDatabaseURL()
    }

    private func notifyMenuStateChanged() {
        onMenuStateChanged?()
    }
}
