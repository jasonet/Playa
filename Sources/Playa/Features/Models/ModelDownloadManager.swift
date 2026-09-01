import Foundation

// MARK: - Model Source Registry

/// Supported model registries for discovery and download.
enum ModelRegistry: String, CaseIterable, Identifiable, Codable, Sendable {
    case huggingFace = "huggingface"
    case modelScope = "modelscope"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .huggingFace: "Hugging Face"
        case .modelScope: "ModelScope"
        }
    }

    var searchURL: URL {
        switch self {
        case .huggingFace:
            URL(string: "https://huggingface.co/models?sort=trending")!
        case .modelScope:
            URL(string: "https://modelscope.cn/models?sort=Default")!
        }
    }

    /// Construct a download URL for a given repo ID on this registry.
    func repoURL(for repoID: String) -> URL? {
        switch self {
        case .huggingFace:
            URL(string: "https://huggingface.co/\(repoID)")
        case .modelScope:
            URL(string: "https://modelscope.cn/models/\(repoID)")
        }
    }
}

// MARK: - Download Task Model

/// Represents a single model download in the queue.
struct ModelDownloadTask: Identifiable, Equatable, Sendable {
    let id: UUID
    let repoID: String
    let registry: ModelRegistry
    let displayName: String
    let sizeLabel: String?
    let cachePath: String
    let createdAt: Date

    enum State: Equatable, Sendable {
        case queued
        case downloading(progress: Double)
        case paused(progress: Double)
        case completed
        case failed(String)
    }

    var state: State = .queued

    var isTerminal: Bool {
        switch state {
        case .completed, .failed: true
        default: false
        }
    }

    var progress: Double {
        switch state {
        case .downloading(let p), .paused(let p): p
        case .completed: 1.0
        case .queued: 0.0
        case .failed: 0.0
        }
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }
}

// MARK: - Download Manager

/// Manages a queue of model downloads with support for pause, resume, and cancellation.
/// Designed to support both HuggingFace and ModelScope registries.
///
/// Architecture:
/// - Downloads execute sequentially (one active at a time) to avoid bandwidth contention.
/// - Each download is backed by a `HuggingFaceDownloadOperation` (Python subprocess) for HF models.
/// - ModelScope downloads can be added via a similar Python-based or native URLSession approach.
/// - Completed/failed tasks are retained briefly for UI display, then pruned.
///
/// Usage:
/// ```swift
/// let manager = ModelDownloadManager()
/// manager.enqueue(repoID: "org/model", registry: .huggingFace, cachePath: "~/.cache/huggingface/hub")
/// manager.pause(taskID: someID)
/// manager.resume(taskID: someID)
/// manager.cancel(taskID: someID)
/// ```
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var tasks: [ModelDownloadTask] = []
    @Published private(set) var activeTaskID: UUID?

    /// Maximum completed/failed tasks retained in the list before pruning.
    private let maxRetainedTerminalTasks = 10

    private var activeOperation: HuggingFaceDownloadOperation?
    private var activeDownloadTask: Task<Void, Never>?
    private var onCompletionCallback: ((UUID) -> Void)?

    deinit {
        activeDownloadTask?.cancel()
    }

    // MARK: - Public API

    /// Enqueue a new model download. Returns the task ID, or nil if a download
    /// for the same repoID is already queued or active.
    @discardableResult
    func enqueue(
        repoID: String,
        registry: ModelRegistry,
        displayName: String,
        sizeLabel: String?,
        cachePath: String,
        onCompletion: ((UUID) -> Void)? = nil
    ) -> UUID? {
        // Prevent duplicate downloads for the same repo
        guard !tasks.contains(where: {
            $0.repoID == repoID && !$0.isTerminal
        }) else {
            return nil
        }

        let task = ModelDownloadTask(
            id: UUID(),
            repoID: repoID,
            registry: registry,
            displayName: displayName,
            sizeLabel: sizeLabel,
            cachePath: cachePath,
            createdAt: Date()
        )
        tasks.append(task)
        pruneTerminalTasks()

        // If nothing is currently downloading, start this one immediately
        if activeTaskID == nil {
            startNextTask(onCompletion: onCompletion)
        }
        return task.id
    }

    func pause(taskID: UUID) {
        guard let task = task(for: taskID), !task.isPaused,
              taskID == activeTaskID
        else { return }
        activeOperation?.pause()
        updateTask(taskID) { $0.state = .paused(progress: $0.progress) }
    }

    func resume(taskID: UUID) {
        guard let task = task(for: taskID), task.isPaused,
              taskID == activeTaskID
        else { return }
        activeOperation?.resume()
        updateTask(taskID) { $0.state = .downloading(progress: $0.progress) }
    }

    func cancel(taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }

        if taskID == activeTaskID {
            activeDownloadTask?.cancel()
            activeDownloadTask = nil
            activeOperation = nil
            activeTaskID = nil
        }

        tasks.remove(at: index)

        // Start the next queued task
        if activeTaskID == nil {
            startNextTask()
        }
    }

    func cancelAll() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeOperation = nil
        activeTaskID = nil
        tasks.removeAll { !$0.isTerminal }
    }

    // MARK: - Queries

    var activeTask: ModelDownloadTask? {
        tasks.first { $0.id == activeTaskID }
    }

    var queuedTasks: [ModelDownloadTask] {
        tasks.filter { $0.state == .queued }
    }

    var hasActiveDownload: Bool {
        activeTaskID != nil
    }

    // MARK: - Private

    private func task(for id: UUID) -> ModelDownloadTask? {
        tasks.first { $0.id == id }
    }

    private func updateTask(_ id: UUID, mutate: (inout ModelDownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
    }

    private func startNextTask(onCompletion: ((UUID) -> Void)? = nil) {
        guard let nextIndex = tasks.firstIndex(where: { $0.state == .queued }) else { return }
        let nextTask = tasks[nextIndex]
        activeTaskID = nextTask.id
        onCompletionCallback = onCompletion

        updateTask(nextTask.id) { $0.state = .downloading(progress: 0) }

        executeDownload(for: nextTask)
    }

    private func executeDownload(for task: ModelDownloadTask) {
        let cachePath = LocalModelDiscovery.expandedPath(task.cachePath)

        switch task.registry {
        case .huggingFace:
            executeHuggingFaceDownload(taskID: task.id, repoID: task.repoID, cachePath: cachePath)
        case .modelScope:
            // ModelScope download not yet implemented — mark as failed with a TODO
            updateTask(task.id) {
                $0.state = .failed("ModelScope downloads are not yet supported.")
            }
            activeTaskID = nil
            startNextTask()
        }
    }

    private func executeHuggingFaceDownload(taskID: UUID, repoID: String, cachePath: String) {
        let operation: HuggingFaceDownloadOperation
        do {
            operation = try HuggingFaceDownloadOperation(
                repoID: repoID,
                cachePath: cachePath
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateTask(taskID) {
                        $0.state = .downloading(progress: progress)
                    }
                }
            }
            activeOperation = operation
        } catch {
            updateTask(taskID) {
                $0.state = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            activeTaskID = nil
            activeOperation = nil
            startNextTask()
            return
        }

        activeDownloadTask = Task { [weak self] in
            do {
                try await HuggingFaceSnapshotDownloaderBridge.download(operation: operation)
                guard !Task.isCancelled else { return }
                await self?.handleDownloadComplete(taskID: taskID, success: true)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.handleDownloadComplete(
                    taskID: taskID,
                    success: false,
                    errorMessage: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
    }

    private func handleDownloadComplete(taskID: UUID, success: Bool, errorMessage: String? = nil) {
        if success {
            updateTask(taskID) { $0.state = .completed }
            onCompletionCallback?(taskID)
        } else {
            updateTask(taskID) { $0.state = .failed(errorMessage ?? "Unknown error") }
        }

        activeTaskID = nil
        activeOperation = nil
        activeDownloadTask = nil
        pruneTerminalTasks()
        startNextTask()
    }

    private func pruneTerminalTasks() {
        let terminalTasks = tasks.filter(\.isTerminal)
        guard terminalTasks.count > maxRetainedTerminalTasks else { return }
        let toRemove = terminalTasks
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(terminalTasks.count - maxRetainedTerminalTasks)
        let removeIDs = Set(toRemove.map(\.id))
        tasks.removeAll { removeIDs.contains($0.id) }
    }
}

// MARK: - Bridge to existing HuggingFaceSnapshotDownloader

/// Bridges to the private `HuggingFaceSnapshotDownloader` in HuggingFaceHub.swift.
/// This avoids duplicating the download/cleanup logic.
private enum HuggingFaceSnapshotDownloaderBridge {
    static func download(operation: HuggingFaceDownloadOperation) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try operation.run()
            }.value
        } onCancel: {
            operation.cancel()
        }
    }
}
