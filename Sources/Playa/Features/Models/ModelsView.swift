import AppKit
import SwiftUI

private enum ModelsPageSection: String, CaseIterable, Identifiable {
    case installed = "Installed"
    case discover = "Discover"

    var id: String { rawValue }
}

private enum HubAccessFilter: String, CaseIterable, Identifiable {
    case all = "All access"
    case open = "Open models"
    case gated = "Gated models"

    var id: String { rawValue }
}

private enum ModelSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"
    case newest = "Newest"

    var id: String { rawValue }
}

struct ModelsView: View {
    @ObservedObject var model: PlayaModel
    @StateObject private var localLibrary = LocalModelLibrary()
    @StateObject private var hubLibrary = HuggingFaceModelLibrary()
    @StateObject private var downloadManager = HuggingFaceDownloadManager()
    @State private var section: ModelsPageSection = .installed
    @State private var localQuery = ""
    @State private var hubQuery = ""
    @State private var hubSort: HuggingFaceModelSort = .downloads
    @State private var hubCapabilityFilters = Set<LocalModelCapability>()
    @State private var hubAccessFilter: HubAccessFilter = .all
    @State private var selectedTag: String? = "MLX"
    @State private var localSortByTag: String? = nil
    @State private var modelSortOrder: ModelSortOrder = .size

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()

            switch section {
            case .installed:
                installedPage
            case .discover:
                discoverPage
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: modelScanPath) {
            localLibrary.scan(
                path: model.settings.modelSearchPath,
                lmStudioPath: model.settings.expandedLmStudioModelPath
            )
        }
        .task(id: hubSearchTaskID) {
            guard section == .discover else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            hubLibrary.search(query: hubQuery, sort: hubSort)
        }
        .onDisappear {
            localLibrary.cancel()
            hubLibrary.cancel()
            downloadManager.cancelDownload()
        }
    }

    private var pageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                pageTitle
                Spacer(minLength: 12)
                sectionPicker
            }

            VStack(alignment: .leading, spacing: 12) {
                pageTitle
                HStack {
                    Spacer()
                    sectionPicker
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var installedPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ModelsSearchField(prompt: "Filter installed models", text: $localQuery)

                Button {
                    localLibrary.scan(
                        path: model.settings.modelSearchPath,
                        lmStudioPath: model.settings.expandedLmStudioModelPath
                    )
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(localLibrary.isScanning)

            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollView {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

                VStack(alignment: .leading, spacing: 0) {
                    if !allTags.isEmpty {
                        tagFilterBar
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 10)
                    }

                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        if let error = localLibrary.error {
                            ModelsNotice(
                                title: "Couldn’t read the model cache",
                                message: error,
                                systemImage: "exclamationmark.triangle.fill",
                                color: .orange
                            )
                            .gridCellColumns(5)
                        }

                        if localLibrary.isScanning && localLibrary.models.isEmpty {
                            ModelsLoadingState(title: "Scanning your Hugging Face cache…")
                                .gridCellColumns(5)
                        } else if filteredLocalModels.isEmpty {
                            ModelsEmptyState(
                                systemImage: localQuery.isEmpty ? "shippingbox" : "magnifyingglass",
                                title: localQuery.isEmpty ? "No MLX models installed" : "No models match your filter",
                                message: localQuery.isEmpty
                                    ? "Discover an MLX model on Hugging Face and download it to this cache."
                                    : "Try a different model name or provider.",
                                actionTitle: localQuery.isEmpty ? "Discover models" : nil,
                                action: { section = .discover }
                            )
                            .gridCellColumns(5)
                        } else {
                            Section {
                                HStack {
                                    Text("\(filteredLocalModels.count) \(filteredLocalModels.count == 1 ? "model" : "models")")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Picker("Sort", selection: $modelSortOrder) {
                                        ForEach(ModelSortOrder.allCases) { order in
                                            Text(order.rawValue).tag(order)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                    if localLibrary.isScanning {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .gridCellColumns(5)

                            ForEach(sortedModels) { localModel in
                                let isSelected = model.settings.normalized().languageModelID == localModel.repoID
                                let isLoading = isSelected && model.modelSwitchInProgress
                                InstalledModelCard(
                                    localModel: localModel,
                                    isSelected: isSelected,
                                    isLoading: isLoading,
                                    isServerRunning: model.isRunning,
                                    isDeleting: localLibrary.deletingModelIDs.contains(localModel.repoID),
                                    canDelete: !model.modelSwitchInProgress && !isModelInUse(localModel.repoID),
                                    onSelect: {
    let sizeLabel = localModel.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    let modelPath = localModel.snapshotURL?.path
    model.selectModel(to: localModel.repoID, displayName: localModel.displayName, sizeLabel: sizeLabel, modelPath: modelPath)
},
                                    onStartModel: { model.startSelectedModel() },
                                    onStopModel: { model.stopServer() },
                                    onDelete: { deleteInstalledModel(localModel) },
                                    isGGUFRunning: model.isGGUFRunning,
                                    ggufLoadingModelID: model.ggufLoadingModelID,
                                    onStartGGUF: { model.startGGUFServer(for: localModel) },
                                    onStopGGUF: { model.stopGGUFServer() },
                                    onForceKillGGUF: { model.forceKillGGUFServer() }
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var discoverPage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ModelsSearchField(prompt: "Search models on Hugging Face", text: $hubQuery)

                    if hubLibrary.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28)
                    }
                }

                discoverFilterBar
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let error = hubLibrary.error {
                        ModelsNotice(
                            title: "Hugging Face is unavailable",
                            message: error,
                            systemImage: "wifi.exclamationmark",
                            color: .orange
                        )
                    } else if hubLibrary.isSearching && hubLibrary.models.isEmpty {
                        ModelsLoadingState(title: hubQuery.isEmpty ? "Finding popular Safetensors models…" : "Searching Hugging Face…")
                    } else if hubLibrary.models.isEmpty {
                        ModelsEmptyState(
                            systemImage: "magnifyingglass",
                            title: "No Safetensors models found",
                            message: "Try a model family, provider, or repository name.",
                            actionTitle: nil,
                            action: {}
                        )
                    } else {
                        discoverResultsHeader

                        if filteredHubModels.isEmpty {
                            ModelsEmptyState(
                                systemImage: "line.3.horizontal.decrease.circle",
                                title: "No models match these filters",
                                message: "Try another capability or access filter, or continue to the next page.",
                                actionTitle: nil,
                                action: {}
                            )
                        } else {
                            ForEach(filteredHubModels) { hubModel in
                                HubModelRow(
                                    model: hubModel,
                                    isInstalled: installedModelIDs.contains(hubModel.id),
                                    isDownloading: downloadManager.downloadingModelID == hubModel.id,
                                    downloadProgress: downloadManager.downloadingModelID == hubModel.id
                                        ? downloadManager.downloadProgress
                                        : 0,
                                    isDownloadPaused: downloadManager.downloadingModelID == hubModel.id
                                        && downloadManager.isDownloadPaused,
                                    anotherDownloadIsActive: downloadManager.downloadingModelID != nil,
                                    downloadError: downloadManager.errorByModelID[hubModel.id],
                                    onDownload: {
                                        downloadManager.download(
                                            repoID: hubModel.id,
                                            cachePath: model.settings.modelSearchPath
                                        ) {
                                            localLibrary.scan(path: model.settings.modelSearchPath)
                                            NotificationCenter.default.post(
                                                name: .localModelLibraryDidChange,
                                                object: nil
                                            )
                                        }
                                    },
                                    onPauseResume: {
                                        if downloadManager.isDownloadPaused {
                                            downloadManager.resumeDownload()
                                        } else {
                                            downloadManager.pauseDownload()
                                        }
                                    },
                                    onRemoveDownload: {
                                        downloadManager.removeDownload()
                                    }
                                )
                            }
                        }

                        HStack(spacing: 12) {
                            Spacer()

                            Button {
                                hubLibrary.goToPreviousPage()
                            } label: {
                                Label("Previous", systemImage: "chevron.left")
                            }
                            .disabled(!hubLibrary.canGoToPreviousPage)

                            Text("Page \(hubLibrary.pageNumber) of up to 5")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 122)

                            Button {
                                hubLibrary.goToNextPage()
                            } label: {
                                Label("Next", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .disabled(!hubLibrary.canGoToNextPage)

                            Spacer()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private func isModelInUse(_ repoID: String) -> Bool {
        guard model.isRunning else { return false }
        let settings = model.settings.normalized()
        let configuredModelIDs = [
            settings.languageModelID,
            settings.imageGenerationModelID,
            settings.textToSpeechModelID,
            settings.speechToTextModelID,
            model.metrics?.server.loadedModel
        ]
        return configuredModelIDs.contains(repoID)
    }

    private func deleteInstalledModel(_ localModel: LocalModel) {
        localLibrary.delete(
            model: localModel,
            path: model.settings.modelSearchPath
        ) {
            var settings = model.settings
            if settings.languageModelID == localModel.repoID {
                settings.languageModelID = nil
            }
            if settings.imageGenerationModelID == localModel.repoID {
                settings.imageGenerationModelID = nil
            }
            if settings.textToSpeechModelID == localModel.repoID {
                settings.textToSpeechModelID = nil
            }
            if settings.speechToTextModelID == localModel.repoID {
                settings.speechToTextModelID = nil
            }
            model.settings = settings
            NotificationCenter.default.post(name: .localModelLibraryDidChange, object: nil)
        }
    }

    private var filteredLocalModels: [LocalModel] {
        let query = localQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var models = query.isEmpty
            ? localLibrary.models
            : localLibrary.models.filter {
                $0.repoID.localizedCaseInsensitiveContains(query)
                    || $0.provider?.displayName.localizedCaseInsensitiveContains(query) == true
            }

        if let tag = selectedTag {
            models = models.filter { $0.tags.contains(tag) }
        }

        if let tag = localSortByTag {
            let matching = models.filter { $0.tags.contains(tag) }
            let nonMatching = models.filter { !$0.tags.contains(tag) }
            models = matching + nonMatching
        }

        let selectedModelID = model.settings.normalized().languageModelID
        if let selectedIndex = models.firstIndex(where: { $0.repoID == selectedModelID }) {
            let selectedModel = models.remove(at: selectedIndex)
            models.insert(selectedModel, at: 0)
        }
        return models
    }

    private var sortedModels: [LocalModel] {
        let sorted: [LocalModel]
        switch modelSortOrder {
        case .name:
            sorted = filteredLocalModels.sorted { $0.repoID.localizedCaseInsensitiveCompare($1.repoID) == .orderedAscending }
        case .size:
            sorted = filteredLocalModels.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        case .newest:
            sorted = filteredLocalModels.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        }

        // Pin running models to the top
        let runningID = model.settings.normalized().languageModelID
        if model.serverState != .stopped, let runningID {
            var result = sorted
            if let idx = result.firstIndex(where: { $0.repoID == runningID }) {
                let running = result.remove(at: idx)
                result.insert(running, at: 0)
            }
            return result
        }
        return sorted
    }

    private var allTags: [String] {
        var tagCounts: [String: Int] = [:]
        for model in localLibrary.models {
            for tag in model.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        return tagCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map(\.key)
    }

    private var tagFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TagFlowLayout(spacing: 6) {
                TagPill(
                    title: "All",
                    count: localLibrary.models.count,
                    isSelected: selectedTag == nil && localSortByTag == nil,
                    action: {
                        selectedTag = nil
                        localSortByTag = nil
                    }
                )
                ForEach(allTags, id: \.self) { tag in
                    TagPill(
                        title: tag,
                        count: localLibrary.models.filter { $0.tags.contains(tag) }.count,
                        isSelected: selectedTag == tag || localSortByTag == tag,
                        action: {
                            if selectedTag == tag {
                                selectedTag = nil
                            } else {
                                selectedTag = tag
                                localSortByTag = nil
                            }
                        },
                        onGroup: {
                            if localSortByTag == tag {
                                localSortByTag = nil
                            } else {
                                localSortByTag = tag
                                selectedTag = nil
                            }
                        }
                    )
                }
            }
        }
    }

    private var installedModelIDs: Set<String> {
        Set(localLibrary.models.map(\.repoID))
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Models")
                .font(.title2.weight(.semibold))
            Text("Manage local MLX models or find new ones on Hugging Face.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(ModelsPageSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 230)
    }

    private var discoverFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                hubSortPicker
                hubCapabilityPicker
                hubAccessPicker
                Spacer(minLength: 8)
                shownModelCount
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    hubSortPicker
                    Spacer(minLength: 8)
                    shownModelCount
                }
                HStack(spacing: 12) {
                    hubCapabilityPicker
                    hubAccessPicker
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                hubSortPicker
                hubCapabilityPicker
                hubAccessPicker
                shownModelCount
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hubSortPicker: some View {
        Picker("Sort by", selection: $hubSort) {
            ForEach(HuggingFaceModelSort.allCases) { sort in
                Label(sort.displayName, systemImage: sort.systemImage)
                    .tag(sort)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var hubCapabilityPicker: some View {
        HStack(spacing: 8) {
            Text("Capability")

            Menu {
                Button {
                    hubCapabilityFilters.removeAll()
                } label: {
                    if hubCapabilityFilters.isEmpty {
                        Label("All capabilities", systemImage: "checkmark")
                    } else {
                        Text("All capabilities")
                    }
                }

                Divider()

                ForEach(
                    LocalModelCapability.visibleModelTags.filter { $0 != .embeddings },
                    id: \.self
                ) { capability in
                    Toggle(
                        capability.displayName,
                        isOn: capabilitySelectionBinding(for: capability)
                    )
                }
            } label: {
                Text(capabilityFilterTitle)
                    .frame(minWidth: 130, alignment: .leading)
            }
            .menuStyle(.button)
        }
        .fixedSize()
    }

    private var capabilityFilterTitle: String {
        switch hubCapabilityFilters.count {
        case 0:
            "All capabilities"
        case 1:
            hubCapabilityFilters.first?.displayName ?? "All capabilities"
        default:
            "\(hubCapabilityFilters.count) selected"
        }
    }

    private func capabilitySelectionBinding(
        for capability: LocalModelCapability
    ) -> Binding<Bool> {
        Binding(
            get: { hubCapabilityFilters.contains(capability) },
            set: { isSelected in
                if isSelected {
                    hubCapabilityFilters.insert(capability)
                } else {
                    hubCapabilityFilters.remove(capability)
                }
            }
        )
    }

    private var hubAccessPicker: some View {
        Picker("Access", selection: $hubAccessFilter) {
            ForEach(HubAccessFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var shownModelCount: some View {
        Text("\(filteredHubModels.count) shown")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var discoverResultsHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                discoverResultsTitle
                Spacer(minLength: 8)
                discoverSortStatus
                openHubLink
            }

            VStack(alignment: .leading, spacing: 6) {
                discoverResultsTitle
                HStack(spacing: 12) {
                    discoverSortStatus
                    Spacer(minLength: 8)
                    openHubLink
                }
            }
        }
    }

    private var discoverResultsTitle: some View {
        Text(hubQuery.isEmpty ? "Safetensors models on Hugging Face" : "Search results")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var discoverSortStatus: some View {
        Label("Sorted by \(hubSort.displayName.lowercased())", systemImage: hubSort.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var openHubLink: some View {
        Link(destination: hubModelsURL) {
            Label("Open Hub", systemImage: "arrow.up.right")
                .font(.caption)
        }
        .fixedSize()
    }

    private var filteredHubModels: [HuggingFaceModel] {
        hubLibrary.models.filter { hubModel in
            let matchesCapability = hubCapabilityFilters.allSatisfy {
                hubModel.capabilities.contains($0)
            }
            let matchesAccess: Bool
            switch hubAccessFilter {
            case .all:
                matchesAccess = true
            case .open:
                matchesAccess = !hubModel.isGated && !hubModel.isPrivate
            case .gated:
                matchesAccess = hubModel.isGated
            }
            return matchesCapability && matchesAccess
        }
    }

    private var modelScanPath: String {
        model.settings.normalized().expandedModelSearchPath
    }

    private var hubSearchTaskID: String {
        "\(section.rawValue):\(hubQuery):\(hubSort.rawValue)"
    }

    private var hubModelsURL: URL {
        var components = URLComponents(string: "https://huggingface.co/models")!
        var queryItems = [
            URLQueryItem(name: "library", value: "safetensors"),
            URLQueryItem(name: "sort", value: hubSort.hubWebValue),
            URLQueryItem(name: "p", value: String(hubLibrary.pageNumber - 1))
        ]

        let query = hubQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        queryItems.append(contentsOf: hubCapabilityFilters
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.hubQueryItem))

        switch hubAccessFilter {
        case .all:
            break
        case .open:
            queryItems.append(URLQueryItem(name: "gated", value: "false"))
        case .gated:
            queryItems.append(URLQueryItem(name: "gated", value: "true"))
        }

        components.queryItems = queryItems
        return components.url!
    }

}

private struct ModelsSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private struct InstalledModelCard: View {
    let localModel: LocalModel
    let isSelected: Bool
    let isLoading: Bool
    let isServerRunning: Bool
    let isDeleting: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onStartModel: () -> Void
    let onStopModel: () -> Void
    let onDelete: () -> Void
    var isGGUFRunning: Bool = false
    var ggufLoadingModelID: String? = nil
    var onStartGGUF: (() -> Void)?
    var onStopGGUF: (() -> Void)?
    var onForceKillGGUF: (() -> Void)?

    @State private var showStartConfirmation = false

    @State private var isHovered = false
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ModelProviderBadge(provider: localModel.provider, isHighlighted: isSelected)

                ModelPill(
                    title: localModel.formatTag,
                    systemImage: localModel.format == .mlx ? "cpu" : "cube",
                    color: localModel.format == .mlx ? .blue : .green
                )

                Spacer()

                if let sizeBytes = localModel.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.08))
                        )
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                Menu {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([localModel.snapshotURL].compactMap { $0 })
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.up.forward.square")
                    }

                    if canDelete {
                        Divider()
                        Button(role: .destructive) {
                            showsDeleteConfirmation = true
                        } label: {
                            Label("Delete Model", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Text(localModel.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)


            if let parameterSizeLabel = localModel.parameterSizeLabel {
                HStack(spacing: 4) {
                    ModelPill(title: parameterSizeLabel, systemImage: "brain")
                    if let quantLabel = localModel.quantizationLabel {
                        ModelPill(title: quantLabel, systemImage: "memorychip")
                    }
                    if let contextSize = localModel.contextSize {
                        ModelPill(title: "\(compactContextSize(contextSize))", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                }
            }



            if !localModel.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(localModel.tags.sorted().prefix(5)), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.secondary.opacity(0.08))
                            )
                    }
                    if localModel.tags.count > 5 {
                        Text("+\(localModel.tags.count - 5)")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .modelRowBackground(isHighlighted: isSelected, isHovered: isHovered, isRunning: isSelected && isServerRunning)
        .onTapGesture {
            guard !isLoading else { return }
            if isSelected && isServerRunning {
                showStartConfirmation = true  // re-use to confirm stop
            } else {
                onSelect()
            }
        }
        .overlay(alignment: .bottom) {
            if localModel.format == .mlx && isSelected {
                mlxControlBar
            } else if localModel.format == .gguf {
                ggufControlBar
            }
        }
        .alert(isSelected && isServerRunning ? "Stop \(localModel.displayName)?" : "Start \(localModel.displayName)?", isPresented: $showStartConfirmation) {
            if isSelected && isServerRunning {
                Button("Stop", role: .destructive, action: onStopModel)
                Button("Cancel", role: .cancel) {}
            } else {
                Button("Start", action: onStartModel)
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if isSelected && isServerRunning {
                Text("This will stop the currently running server and free memory.")
            } else {
                Text("This will stop any currently running model and load \(localModel.displayName).")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if localModel.format == .gguf {
                ggufControlBar
            }
        }
        .alert("Delete \(localModel.displayName)?", isPresented: $showsDeleteConfirmation) {
            Button("Delete Model", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(localModel.repoID) from the local Hugging Face cache.")
        }
    }

    @ViewBuilder
    private var mlxControlBar: some View {
        let isThisModelRunning = isServerRunning && isSelected

        HStack(spacing: 0) {
            if isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                    Text("Loading...")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else if isThisModelRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Running")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Spacer()

                Button {
                    onStopModel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop server")
                .padding(.trailing, 4)
            } else {
                Button {
                    showStartConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text("Start MLX")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10
            )
            .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var ggufControlBar: some View {
        let isThisModelLoading = ggufLoadingModelID == localModel.repoID
        let isThisModelRunning = isGGUFRunning && ggufLoadingModelID == nil

        HStack(spacing: 0) {
            if isThisModelLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                    Text("Starting...")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Spacer()

                Button {
                    onForceKillGGUF?()
                } label: {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Force kill")
                .padding(.trailing, 4)
            } else if isThisModelRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Running")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Spacer()

                Button {
                    onStopGGUF?()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop GGUF server")
                .padding(.trailing, 4)
            } else {
                Button {
                    onStartGGUF?()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text("Start GGUF")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: 10,
                bottomTrailingRadius: 10
            )
            .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct HubModelRow: View {
    let model: HuggingFaceModel
    let isInstalled: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let isDownloadPaused: Bool
    let anotherDownloadIsActive: Bool
    let downloadError: String?
    let onDownload: () -> Void
    let onPauseResume: () -> Void
    let onRemoveDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ModelProviderBadge(provider: model.provider)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(modelName(model.id))
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                        if model.isGated {
                            ModelPill(title: "Gated", systemImage: "lock")
                        }
                        if let memoryEstimate = model.memoryEstimate, !memoryEstimate.isUsable {
                            ModelPill(
                                title: "May not fit in memory",
                                systemImage: "exclamationmark.triangle.fill",
                                color: .orange
                            )
                            .help("Pre-download estimate. \(memoryEstimate.explanation)")
                        }
                    }

                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        ModelPill(title: compactCount(model.downloads), systemImage: "arrow.down.circle")
                        ModelPill(title: compactCount(model.likes), systemImage: "heart")
                        if let sizeBytes = model.sizeBytes {
                            ModelPill(
                                title: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file),
                                systemImage: "internaldrive"
                            )
                        }
                    }

                    if !model.capabilities.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(LocalModelCapability.visibleModelTags, id: \.self) { capability in
                                if model.capabilities.contains(capability) {
                                    CapabilityPill(capability: capability)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                if isInstalled {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                        .fixedSize()
                } else if isDownloading {
                    ModelDownloadProgressControl(
                        progress: downloadProgress,
                        isPaused: isDownloadPaused,
                        onPauseResume: onPauseResume,
                        onRemove: onRemoveDownload
                    )
                } else {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(anotherDownloadIsActive || model.isPrivate)
                        .help(model.isGated ? "Gated models require Hugging Face authentication." : "Download to the configured cache")
                        .fixedSize()
                }
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .modelRowBackground(isHighlighted: false)
    }
}

private struct ModelDownloadProgressControl: View {
    let progress: Double
    let isPaused: Bool
    let onPauseResume: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            if isHovering {
                HStack(spacing: 6) {
                    ModelDownloadActionButton(
                        title: isPaused ? "Resume download" : "Pause download",
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        tint: isPaused ? .green : .orange,
                        action: onPauseResume
                    )

                    ModelDownloadActionButton(
                        title: "Remove download",
                        systemImage: "trash",
                        tint: .red,
                        action: onRemove
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 3)

                    Circle()
                        .trim(from: 0, to: displayedProgress)
                        .stroke(
                            isPaused ? Color.orange : Color.accentColor,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    if progress > 0 {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    } else {
                        Image(systemName: isPaused ? "pause.fill" : "arrow.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .frame(width: 34, height: 34)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: 74, height: 36)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.16), value: isHovering)
        .animation(.easeOut(duration: 0.18), value: displayedProgress)
        .help(isPaused ? "Download paused" : "Downloading \(Int((progress * 100).rounded())) percent")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isPaused ? "Download paused" : "Download progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    private var displayedProgress: Double {
        min(max(progress, 0.025), 1)
    }
}

private struct ModelDownloadActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isDisabled = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDisabled ? Color.secondary.opacity(0.45) : (isHovering ? tint : Color.secondary))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering && !isDisabled ? tint.opacity(0.13) : Color.secondary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 && !isDisabled }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct ModelProviderBadge: View {
    let provider: LocalModelProvider?
    var isHighlighted = false
    @Environment(\.colorScheme) private var colorScheme

    private var color: Color {
        provider?.modelBadgeColor ?? .secondary
    }

    private var backgroundColor: Color {
        if provider?.needsLightIconBackgroundInDarkMode == true, colorScheme == .dark {
            return Color.white.opacity(0.92)
        }
        if isHighlighted {
            return Color(nsColor: .controlBackgroundColor)
        }
        if provider?.preservesIconColors == true {
            return Color.secondary.opacity(0.10)
        }
        return color.opacity(0.14)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundColor)

            if let provider, let image = LocalModelProviderIcon.image(for: provider) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: 25, height: 25)
                    .accessibilityLabel(provider.displayName)
            } else if let provider {
                Text(provider.monogram)
                    .font(.system(size: provider.monogram.count > 2 ? 9 : 12, weight: .bold))
                    .foregroundStyle(color)
            } else {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 46)
        .help(provider?.displayName ?? "Unknown provider")
    }
}

private struct ModelPill: View {
    let title: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.10)))
            .fixedSize()
    }
}

private struct CapabilityPill: View {
    let capability: LocalModelCapability

    var body: some View {
        ModelPill(title: capability.displayName, systemImage: capability.systemImage)
    }
}

private struct ModelsNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }
}

private struct ModelsLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct ModelsEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct ModelRowBackground: ViewModifier {
    let isHighlighted: Bool
    let isHovered: Bool
    let isRunning: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
    }

    private var backgroundColor: Color {
        if isRunning {
            return Color.green.opacity(0.06)
        }
        if isHighlighted {
            return Color.accentColor.opacity(0.38)
        }
        if isHovered {
            return Color.accentColor.opacity(0.08)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var borderColor: Color {
        if isRunning {
            return Color.green.opacity(0.8)
        }
        if isHighlighted {
            return Color.accentColor.opacity(0.90)
        }
        if isHovered {
            return Color.accentColor.opacity(0.40)
        }
        return Color(nsColor: .separatorColor)
    }

    private var borderWidth: CGFloat {
        isRunning ? 2 : (isHighlighted ? 1.5 : (isHovered ? 1 : 0.5))
    }
}

private extension View {
    func modelRowBackground(isHighlighted: Bool, isHovered: Bool = false, isRunning: Bool = false) -> some View {
        modifier(ModelRowBackground(isHighlighted: isHighlighted, isHovered: isHovered, isRunning: isRunning))
    }
}

private extension LocalModelCapability {
    static let visibleModelTags = allCases.filter { $0 != .text }

    var hubQueryItem: URLQueryItem {
        switch self {
        case .text:
            URLQueryItem(name: "pipeline_tag", value: "text-generation")
        case .vision:
            URLQueryItem(name: "pipeline_tag", value: "image-text-to-text")
        case .audio:
            URLQueryItem(name: "other", value: "audio")
        case .video:
            URLQueryItem(name: "other", value: "video")
        case .imageGeneration:
            URLQueryItem(name: "pipeline_tag", value: "text-to-image")
        case .speechToText:
            URLQueryItem(name: "pipeline_tag", value: "automatic-speech-recognition")
        case .textToSpeech:
            URLQueryItem(name: "pipeline_tag", value: "text-to-speech")
        case .embeddings:
            URLQueryItem(name: "pipeline_tag", value: "feature-extraction")
        case .reasoning:
            URLQueryItem(name: "other", value: "reasoning")
        case .tools:
            URLQueryItem(name: "other", value: "tool-calling")
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .vision: "eye"
        case .audio: "waveform"
        case .video: "film"
        case .imageGeneration: "photo.badge.plus"
        case .speechToText: "captions.bubble"
        case .textToSpeech: "speaker.wave.2"
        case .embeddings: "circle.grid.3x3"
        case .reasoning: "brain.fill"
        case .tools: "hammer"
        }
    }
}

private extension LocalModelProvider {
    var modelBadgeColor: Color {
        switch self {
        case .google:
            .primary
        case .openAI:
            .primary
        case .meta:
            Color(red: 0 / 255, green: 129 / 255, blue: 251 / 255)
        case .mistral:
            .primary
        case .qwen:
            Color(red: 0 / 255, green: 46 / 255, blue: 254 / 255)
        case .microsoft:
            .primary
        case .cohere:
            .primary
        case .deepSeek:
            Color(red: 79 / 255, green: 112 / 255, blue: 255 / 255)
        case .ai2:
            Color(red: 255 / 255, green: 103 / 255, blue: 170 / 255)
        case .openBMB:
            Color(red: 68 / 255, green: 119 / 255, blue: 255 / 255)
        case .openMOSS:
            .primary
        case .poolside:
            .primary
        case .prismML:
            .primary
        case .nvidia:
            Color(red: 118 / 255, green: 185 / 255, blue: 0 / 255)
        case .apple:
            .primary
        case .ibm:
            Color(red: 15 / 255, green: 98 / 255, blue: 254 / 255)
        case .liquidAI:
            .primary
        case .zAI:
            .primary
        }
    }
}

private func modelName(_ repoID: String) -> String {
    repoID.split(separator: "/").last.map(String.init) ?? repoID
}

private func compactContextSize(_ value: Int) -> String {
    let million = 1024 * 1024
    if value >= million, value.isMultiple(of: million) { return "\(value / million)M" }
    if value >= 1024, value.isMultiple(of: 1024) { return "\(value / 1024)K" }
    return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
}

private func compactCount(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
    }
    if value >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0K", with: "K")
    }
    return "\(value)"
}

private struct TagPill: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    var onGroup: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption2.weight(isSelected ? .bold : .medium))
                    Text("\(count)")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(isSelected ? .white : .primary)
            }
            .buttonStyle(.plain)

            if let onGroup {
                Button(action: onGroup) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Group by \(title)")
            }
        }
    }
}

private struct TagFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        guard !rows.isEmpty else { return .zero }
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for (idx, row) in rows.enumerated() {
            let rowHeight = row.map(\.height).max() ?? 0
            totalHeight += rowHeight
            if idx < rows.count - 1 { totalHeight += spacing }
            var rowWidth: CGFloat = 0
            for (j, item) in row.enumerated() {
                rowWidth += item.width
                if j < row.count - 1 { rowWidth += spacing }
            }
            if rowWidth > maxRowWidth { maxRowWidth = rowWidth }
        }
        return CGSize(width: proposal.width ?? maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.height).max() ?? 0
            var x = bounds.minX
            for item in row {
                item.subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += item.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[(subview: LayoutSubview, width: CGFloat, height: CGFloat)]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[(subview: LayoutSubview, width: CGFloat, height: CGFloat)]] = []
        var currentRow: [(subview: LayoutSubview, width: CGFloat, height: CGFloat)] = []
        var currentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = size.width + (currentRow.isEmpty ? 0 : spacing)
            if !currentRow.isEmpty, currentWidth + itemWidth > maxWidth {
                rows.append(currentRow)
                currentRow = []
                currentWidth = 0
            }
            currentRow.append((subview, size.width, size.height))
            currentWidth += itemWidth
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}

#Preview {
    ModelsView(model: .init())
        .frame(width: 850, height: 680)
}
