import Foundation

struct ModelHistoryEntry: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let sizeLabel: String?
    let modelPath: String?
    let providerRawValue: String?
    let lastUsedAt: Date
    /// When the model server was last launched for this model.
    var lastStartedAt: Date?
    /// Human-readable summary of environment requirements (quantization, parameter count, etc.).
    var environmentNotes: String?
    /// Decode speed (tokens/second) from the last successful session.
    var lastDecodeSpeed: Double?

    var provider: LocalModelProvider? {
        providerRawValue.flatMap(LocalModelProvider.init(rawValue:))
    }
}

@MainActor
final class ModelHistoryStore: ObservableObject {
    @Published private(set) var entries: [ModelHistoryEntry] = []

    private static let maxEntries = 8
    private static var storageURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let baseURL = applicationSupport ?? FileManager.default.homeDirectoryForCurrentUser
        return baseURL
            .appendingPathComponent("Playa", isDirectory: true)
            .appendingPathComponent("ModelHistory.plist")
    }

    init() {
        load()
    }

    func record(
        modelID: String,
        displayName: String?,
        sizeLabel: String?,
        modelPath: String?,
        provider: LocalModelProvider?
    ) {
        let resolvedName = displayName
            ?? modelID.split(separator: "/").last.map(String.init)
            ?? modelID

        entries.removeAll { $0.id == modelID }
        let entry = ModelHistoryEntry(
            id: modelID,
            displayName: resolvedName,
            sizeLabel: sizeLabel,
            modelPath: modelPath,
            providerRawValue: provider?.rawValue,
            lastUsedAt: Date(),
            lastStartedAt: nil,
            environmentNotes: nil,
            lastDecodeSpeed: nil
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    /// Records a server startup event for the given model, including
    /// a human-readable summary of the environment/configuration used.
    func recordStartup(modelID: String, environmentNotes: String?) {
        guard let index = entries.firstIndex(where: { $0.id == modelID }) else {
            return
        }
        entries[index].lastStartedAt = Date()
        entries[index].environmentNotes = environmentNotes
        save()
    }

    /// Records the decode speed (tokens/second) achieved during the last session.
    func recordDecodeSpeed(modelID: String, decodeTokensPerSecond: Double) {
        guard let index = entries.firstIndex(where: { $0.id == modelID }),
              decodeTokensPerSecond > 0, decodeTokensPerSecond.isFinite
        else { return }
        entries[index].lastDecodeSpeed = decodeTokensPerSecond
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL) else { return }
        entries = (try? PropertyListDecoder().decode([ModelHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        do {
            let url = Self.storageURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            // History persistence should not crash the app.
        }
    }
}
