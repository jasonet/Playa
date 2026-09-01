import AppKit
import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case imageGeneration = "Image Generation"
    case videoGeneration = "Omni Video Lab"
    case dashboard = "Dashboard"
    case models = "Models"
    case integrations = "Integrations"
    case developer = "Developer"

    static var allCases: [ControlPanelTab] {
        [.chat, .videoGeneration, .dashboard, .models, .integrations, .developer]
    }

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .imageGeneration:
            "photo.on.rectangle"
        case .videoGeneration:
            "sparkles.rectangle.stack"
        case .dashboard:
            "chart.bar.xaxis"
        case .models:
            "cube.transparent"
        case .integrations:
            "puzzlepiece.extension"
        case .developer:
            "hammer"
        }
    }
}

enum ChatSessionNavigationDirection {
    case next
    case previous
}

@MainActor
final class ControlPanelNavigation: ObservableObject {
    @Published private(set) var requestedTab: ControlPanelTab?
    @Published private(set) var newChatRequest = 0
    @Published private(set) var chatSessionNavigationRequest = 0
    private var consumedNewChatRequest = 0
    private var consumedChatSessionNavigationRequest = 0
    private var requestedChatSessionNavigationDirection: ChatSessionNavigationDirection = .next

    func open(_ tab: ControlPanelTab) {
        requestedTab = tab
    }

    func createChat() {
        newChatRequest += 1
    }

    func navigateChatSession(_ direction: ChatSessionNavigationDirection) {
        requestedChatSessionNavigationDirection = direction
        chatSessionNavigationRequest += 1
    }

    func consumeNewChatRequest() -> Bool {
        guard consumedNewChatRequest < newChatRequest else {
            return false
        }
        consumedNewChatRequest = newChatRequest
        return true
    }

    func consumeChatSessionNavigationRequest() -> ChatSessionNavigationDirection? {
        guard consumedChatSessionNavigationRequest < chatSessionNavigationRequest else {
            return nil
        }
        consumedChatSessionNavigationRequest = chatSessionNavigationRequest
        return requestedChatSessionNavigationDirection
    }
}

struct ControlPanelView: View {
    let model: PlayaModel
    @ObservedObject var navigation: ControlPanelNavigation
    @ObservedObject var runtime: SystemRuntimeMonitor
    @StateObject private var chat = ChatViewModel()
    @StateObject private var imageGeneration = ImageGenerationViewModel()
    @StateObject private var dashboard = DashboardViewModel()
    @State private var sidebarSelection: ControlPanelSidebarSelection = .tab(.chat)
    @State private var selectedTab: ControlPanelTab = .chat
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var isModelConfigurationVisible = false
    @State private var isFullScreen = false
    @State private var windowTopContentInset: CGFloat = 0
    @State private var showStartConfirmation = false
    @State private var isNewChatHovering = false
    @State private var isErrorLogExpanded = false
    @State private var activeModelSearchPage: ModelSearchPage?
    private let sidebarItemInsets = EdgeInsets(top: -1, leading: 0, bottom: -1, trailing: 0)

    var body: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .alert("Start \(model.selectedModelName ?? "model")?", isPresented: $showStartConfirmation) {
            Button("Start", action: { model.startSelectedModel() })
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will launch the model server. Existing chats will reconnect once the server is ready.")
        }
        .frame(minWidth: 1040, minHeight: 600)
        .background {
            ControlPanelWindowStateReader(
                isFullScreen: $isFullScreen,
                topContentInset: $windowTopContentInset
            )
                .frame(width: 0, height: 0)
        }
        .onAppear {
            applySidebarSelection(navigation.requestedTab.map(ControlPanelSidebarSelection.tab) ?? sidebarSelection)
            handleNewChatRequest()
            handleChatSessionNavigationRequest()
        }
        .onReceive(navigation.$requestedTab) { tab in
            guard let tab else { return }
            applySidebarSelection(.tab(tab))
        }
        .onChange(of: navigation.newChatRequest) { _, _ in
            handleNewChatRequest()
        }
        .onChange(of: navigation.chatSessionNavigationRequest) { _, _ in
            handleChatSessionNavigationRequest()
        }
        .onChange(of: model.serverState) { _, newState in
            if case .error = newState {
                // Keep expansion state for new errors
            } else {
                isErrorLogExpanded = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach(ControlPanelTab.allCases) { tab in
                    let selection = ControlPanelSidebarSelection.tab(tab)
                    Button {
                        applySidebarSelection(selection)
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .sidebarRowSelectionStyle(isSelected: sidebarSelection == selection)
                    .buttonStyle(.plain)
                    .listRowInsets(sidebarItemInsets)
                }
            }

            Section {
                serverStatusRow
            } header: {
                HStack(spacing: 8) {
                    Text("Server")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(serverStatusDotColor)
                        .frame(width: 8, height: 8)
                }
                .textCase(nil)
                .padding(.horizontal, 7)
            }

            Section {
                if !model.modelHistory.entries.isEmpty {
                    ForEach(model.modelHistory.entries) { entry in
                        ControlPanelModelHistoryRow(
                            entry: entry,
                            isCurrentModel: model.settings.normalized().languageModelID == entry.id,
                            isServerRunning: model.serverState == .running,
                            onStart: {
                                model.selectModel(
                                    to: entry.id,
                                    displayName: entry.displayName,
                                    sizeLabel: entry.sizeLabel,
                                    modelPath: entry.modelPath
                                )
                                model.startSelectedModel()
                            },
                            onStop: {
                                model.stopServer()
                            },
                            onDelete: {
                                model.modelHistory.remove(entry.id)
                            }
                        )
                        .listRowInsets(sidebarItemInsets)
                    }
                }

                // Model registry search links (always visible)
                Button {
                    activeModelSearchPage = .huggingface
                } label: {
                    Label("HuggingFace", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .sidebarRowSelectionStyle(isSelected: activeModelSearchPage == .huggingface)
                .buttonStyle(.plain)
                .listRowInsets(sidebarItemInsets)

                Button {
                    activeModelSearchPage = .modelScope
                } label: {
                    Label("ModelScope", systemImage: "cube.box")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .sidebarRowSelectionStyle(isSelected: activeModelSearchPage == .modelScope)
                .buttonStyle(.plain)
                .listRowInsets(sidebarItemInsets)
            } header: {
                HStack(spacing: 8) {
                    Text("Models")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))
                    if !model.modelHistory.entries.isEmpty {
                        Text("\(model.modelHistory.entries.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(.secondary.opacity(0.08))
                            )
                    }
                    Spacer(minLength: 0)
                }
                .textCase(nil)
                .padding(.horizontal, 7)
            }

            Section {
                ForEach(recentSessions) { recent in
                    ControlPanelRecentSessionRow(
                        recent: recent,
                        isSelected: sidebarSelection == recent.selection,
                        isCurrent: isCurrentRecent(recent),
                        isSelectionDisabled: isRecentSelectionDisabled(recent),
                        isDeleteDisabled: isRecentDeleteDisabled(recent),
                        onSelect: {
                            applySidebarSelection(recent.selection)
                        },
                        onDelete: {
                            deleteRecentSession(recent)
                        }
                    )
                    .listRowInsets(sidebarItemInsets)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Recents")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary.opacity(0.7))

                    Spacer(minLength: 0)

                    Menu {
                        Button("New Chat", systemImage: "bubble.left") {
                            withAnimation(.snappy(duration: 0.2)) {
                                createRecentSession()
                            }
                        }
                        Button("New Agent Session…", systemImage: "folder") {
                            chooseAgentDirectory()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(isNewChatHovering ? Color.primary : Color.secondary.opacity(0.7))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Create a chat or directory-backed fx agent session")
                    .padding(.trailing, 4)
                    .onHover { isNewChatHovering = $0 }
                }
                .textCase(nil)
                .padding(.horizontal, 7)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: effectiveWindowTopInset)
        }
        .navigationTitle("Playa")
        .background(ControlPanelSidebarSurfaceReader())
    }

    /// Decode speed to display in the server section.
    /// Prefers live metrics from the current session; falls back to the
    /// persisted speed from the last session in model history.
    private var serverDecodeSpeed: Double? {
        if let live = model.metrics?.summary.averageDecodeTokensPerSecond,
           live > 0, live.isFinite {
            return live
        }
        guard let modelID = model.settings.languageModelID,
              let entry = model.modelHistory.entries.first(where: { $0.id == modelID })
        else { return nil }
        return entry.lastDecodeSpeed
    }

    private var serverStatusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch model.serverState {
            case .running:
                HStack(spacing: 7) {
                    serverModelIcon

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedModelName ?? model.loadedModelDisplay)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 3) {
                            if let sizeLabel = model.selectedModelSizeLabel {
                                Text(sizeLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            if let speed = serverDecodeSpeed {
                                if model.selectedModelSizeLabel != nil {
                                    Text("·")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Text("\(Int(speed.rounded()))t/s")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Button {
                        model.stopServer()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop server")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.08))
                )
                .contentShape(.rect)
            case .starting:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedModelName ?? "Starting...")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 3) {
                            if let sizeLabel = model.selectedModelSizeLabel {
                                Text(sizeLabel)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        model.stopServer()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop server")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.06))
                )
                .contentShape(.rect)
            case .error(let msg):
                let analysis = ServerErrorAnalyzer.analyze(logText: model.logText, errorMessage: msg)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: analysis.category.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        serverModelIcon
                        Text(model.selectedModelName ?? "Server error")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.forceKillServer()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Force kill server")
                    }

                    Text(analysis.summary)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(analysis.suggestions.enumerated()), id: \.offset) { _, suggestion in
                            HStack(alignment: .top, spacing: 4) {
                                Text("•")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 8)
                                Text(suggestion)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isErrorLogExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.system(size: 9))
                            Text(isErrorLogExpanded ? "Hide log" : "Show log")
                                .font(.system(size: 9, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(isErrorLogExpanded ? 90 : 0))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    if isErrorLogExpanded {
                        let recentLines = ServerErrorAnalyzer.recentLogLines(from: model.logText, maxLines: 10)
                        if !recentLines.isEmpty {
                            ScrollView {
                                Text(recentLines)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        } else {
                            Text("No log output captured.")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        Button {
                            navigation.open(.developer)
                        } label: {
                            Label("View Log", systemImage: "arrow.up.right")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)

                        Button {
                            model.forceKillServer()
                            showStartConfirmation = true
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            case .stopped:
                if let selectedName = model.selectedModelName {
                    HStack(spacing: 7) {
                        serverModelIcon

                        VStack(alignment: .leading, spacing: 1) {
                            Text(selectedName)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            HStack(spacing: 3) {
                                if let sizeLabel = model.selectedModelSizeLabel {
                                    Text(sizeLabel)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                if let speed = serverDecodeSpeed {
                                    if model.selectedModelSizeLabel != nil {
                                        Text("·")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text("\(Int(speed.rounded()))t/s")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                        }

                        Spacer(minLength: 0)

                        Button {
                            showStartConfirmation = true
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                        .help("Start \(selectedName)")
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.clear)
                    )
                    .contentShape(.rect)
                } else {
                    Text("No model selected")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if model.isGGUFRunning {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("GGUF server active")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Spacer()
                    Button {
                        model.stopGGUFServer()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowInsets(sidebarItemInsets)
    }

    @ViewBuilder
    private var serverModelIcon: some View {
        if let provider = currentServerModelProvider,
           let icon = LocalModelProviderIcon.image(for: provider) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "cube.transparent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var currentServerModelProvider: LocalModelProvider? {
        guard let modelID = model.settings.normalized().languageModelID else { return nil }
        return LocalModelProviderResolver.resolve(repoID: modelID, modelType: nil, architectures: [])
    }

    @ViewBuilder
    private var serverRunningMetrics: some View {
        if let metrics = model.metrics {
            HStack(spacing: 8) {
                let decodeRate = metrics.summary.averageDecodeTokensPerSecond
                let generatedTokens = metrics.summary.generatedTokensTotal
                let peakMemory = metrics.latest?.peakMemoryGB

                if decodeRate > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                        Text(PlayaFormatting.rate(decodeRate))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }

                if generatedTokens > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "text.cursor")
                            .font(.system(size: 8))
                        Text(PlayaFormatting.integer(generatedTokens))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }

                if let peakMemory, peakMemory > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "memorychip")
                            .font(.system(size: 8))
                        Text(PlayaFormatting.gigabytes(peakMemory))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10))
        }
    }

    private var serverStatusDotColor: Color {
        switch model.serverState {
        case .running:
            return .green
        case .starting:
            return .yellow
        case .error:
            return .orange
        case .stopped:
            return .secondary.opacity(0.3)
        }
    }

    private var recentSessions: [ControlPanelRecentSession] {
        chat.sessions
            .map(ControlPanelRecentSession.init(chat:))
            .sorted(by: ControlPanelRecentSession.recencySort)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                if let searchPage = activeModelSearchPage {
                    ModelSearchPageView(page: searchPage, activePage: $activeModelSearchPage)
                } else {
                    switch selectedTab {
                    case .chat:
                        ChatView(
                            model: model,
                            chat: chat,
                            showsConfiguration: $isModelConfigurationVisible
                        )
                    case .imageGeneration:
                        ImageGenerationView(model: model, viewModel: imageGeneration)
                    case .videoGeneration:
                        GeminiOmniView()
                    case .dashboard:
                        StatsView(model: model, dashboard: dashboard)
                    case .models:
                        ModelsView(model: model)
                    case .integrations:
                        IntegrationsView(model: model)
                    case .developer:
                        DeveloperView(
                            model: model,
                            runtime: runtime,
                            showsConfiguration: $isModelConfigurationVisible
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(
            ControlPanelDetailSafeArea(
                isFullScreen: isFullScreen,
                windowTopInset: effectiveWindowTopInset,
                respectsTopSafeArea: activeModelSearchPage != nil
            )
        )
    }

    private var effectiveWindowTopInset: CGFloat {
        // Hidden-title-bar windows place SwiftUI content beneath the window
        // controls. Use AppKit's measured content-layout inset when available,
        // with conservative fallbacks for the first layout pass.
        max(windowTopContentInset, isFullScreen ? 28 : 52)
    }

    private func applySidebarSelection(_ selection: ControlPanelSidebarSelection) {
        activeModelSearchPage = nil
        switch selection {
        case .tab(let tab):
            sidebarSelection = selection
            selectedTab = tab
        case .chat(let sessionID):
            if chat.sessions.contains(where: { $0.id == sessionID }) {
                chat.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.chat)
            }
            selectedTab = .chat
        case .imageGeneration(let sessionID):
            if imageGeneration.sessions.contains(where: { $0.id == sessionID }) {
                imageGeneration.selectSession(sessionID)
                sidebarSelection = selection
            } else {
                sidebarSelection = .tab(.imageGeneration)
            }
            selectedTab = .imageGeneration
        }
    }

    private func createRecentSession() {
        chat.createSession()
        applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
    }

    private func chooseAgentDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Agent Workspace"
        panel.prompt = "Create Agent Session"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        chat.createAgentSession(
            workingDirectory: directory,
            initialLocalModelID: model.settings.normalized().languageModelID
        )
        applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
    }

    private func handleNewChatRequest() {
        guard navigation.consumeNewChatRequest() else {
            return
        }
        createRecentSession()
    }

    private func handleChatSessionNavigationRequest() {
        guard let direction = navigation.consumeChatSessionNavigationRequest() else {
            return
        }

        let orderedSessions = chat.sessions.sorted(by: ChatSessionSummary.recencySort)
        guard !orderedSessions.isEmpty else {
            return
        }

        let targetIndex: Int
        if let currentSessionID = chat.currentSessionID,
           let currentIndex = orderedSessions.firstIndex(where: { $0.id == currentSessionID })
        {
            let offset = direction == .next ? 1 : -1
            targetIndex = (currentIndex + offset + orderedSessions.count) % orderedSessions.count
        } else {
            targetIndex = direction == .next ? 0 : orderedSessions.count - 1
        }

        applySidebarSelection(.chat(orderedSessions[targetIndex].id))
    }

    private func deleteRecentSession(_ recent: ControlPanelRecentSession) {
        let deletingSelection = sidebarSelection == recent.selection

        switch recent.selection {
        case .chat(let sessionID):
            chat.deleteSession(sessionID)
            if deletingSelection {
                applySidebarSelection(chat.currentSessionID.map(ControlPanelSidebarSelection.chat) ?? .tab(.chat))
            }
        case .imageGeneration(let sessionID):
            imageGeneration.deleteSession(sessionID)
            if deletingSelection {
                applySidebarSelection(
                    imageGeneration.currentSessionID.map(ControlPanelSidebarSelection.imageGeneration)
                        ?? .tab(.imageGeneration)
                )
            }
        case .tab:
            break
        }
    }

    private func isCurrentRecent(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return sessionID == chat.currentSessionID
        case .imageGeneration(let sessionID):
            return sessionID == imageGeneration.currentSessionID
        case .tab:
            return false
        }
    }

    private func isRecentDeleteDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat(let sessionID):
            return chat.isSessionBusy(sessionID)
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private func isRecentSelectionDisabled(_ recent: ControlPanelRecentSession) -> Bool {
        switch recent.selection {
        case .chat:
            return false
        case .imageGeneration:
            return imageGeneration.isGenerating
        case .tab:
            return false
        }
    }

    private var newRecentHelp: String {
        "Create a new chat"
    }

}

private struct ControlPanelSidebarSurfaceReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        expandSidebarSurface(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        expandSidebarSurface(from: view)
    }

    private func expandSidebarSurface(from view: NSView) {
        guard #available(macOS 26.0, *) else { return }
        expandGlassSidebarSurface(from: view)
    }

    @available(macOS 26.0, *)
    private func expandGlassSidebarSurface(from view: NSView) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            var glassSurface: NSGlassEffectView?

            while let current = ancestor {
                if let glass = current as? NSGlassEffectView {
                    glassSurface = glass
                    break
                }
                ancestor = current.superview
            }

            guard let glassSurface, let container = glassSurface.superview else { return }

            for constraint in container.constraints {
                let firstView = constraint.firstItem as? NSView
                let secondView = constraint.secondItem as? NSView
                let directlyPositionsSurface =
                    (firstView === glassSurface && secondView === container)
                    || (firstView === container && secondView === glassSurface)

                guard directlyPositionsSurface else { continue }
                constraint.constant = 0
            }

            container.needsUpdateConstraints = true
            container.needsLayout = true
        }
    }
}

private struct ControlPanelWindowStateReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool
    @Binding var topContentInset: CGFloat

    func makeNSView(context: Context) -> ControlPanelWindowStateReaderView {
        let view = ControlPanelWindowStateReaderView()
        view.onWindowChange = context.coordinator.update(window:)
        return view
    }

    func updateNSView(_ view: ControlPanelWindowStateReaderView, context: Context) {
        context.coordinator.isFullScreen = $isFullScreen
        context.coordinator.topContentInset = $topContentInset
        view.onWindowChange = context.coordinator.update(window:)
        view.reportWindowState()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen, topContentInset: $topContentInset)
    }

    @MainActor
    final class Coordinator {
        var isFullScreen: Binding<Bool>
        var topContentInset: Binding<CGFloat>

        init(isFullScreen: Binding<Bool>, topContentInset: Binding<CGFloat>) {
            self.isFullScreen = isFullScreen
            self.topContentInset = topContentInset
        }

        func update(window: NSWindow?) {
            let newValue = window?.styleMask.contains(.fullScreen) == true
            if isFullScreen.wrappedValue != newValue {
                isFullScreen.wrappedValue = newValue
            }

            let measuredInset: CGFloat
            if let window, let contentView = window.contentView {
                measuredInset = max(0, contentView.bounds.height - window.contentLayoutRect.height)
            } else {
                measuredInset = 0
            }
            if abs(topContentInset.wrappedValue - measuredInset) > 0.5 {
                topContentInset.wrappedValue = measuredInset
            }
        }
    }
}

@MainActor
private final class ControlPanelWindowStateReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowState()

        DispatchQueue.main.async { [weak self] in
            self?.reportWindowState()
        }
    }

    func reportWindowState() {
        onWindowChange?(window)
    }
}

private struct ControlPanelDetailSafeArea: ViewModifier {
    let isFullScreen: Bool
    let windowTopInset: CGFloat
    let respectsTopSafeArea: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if respectsTopSafeArea {
            content
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: windowTopInset)
            }
        }
    }
}

private enum ControlPanelSidebarSelection: Hashable {
    case tab(ControlPanelTab)
    case chat(UUID)
    case imageGeneration(UUID)
}

private struct ControlPanelRecentSession: Identifiable, Equatable {
    enum ID: Hashable {
        case chat(UUID)
        case imageGeneration(UUID)
    }

    let id: ID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let isAgent: Bool

    init(chat session: ChatSessionSummary) {
        id = .chat(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        isAgent = session.isAgent
    }

    init(imageGeneration session: ImageGenerationSessionSummary) {
        id = .imageGeneration(session.id)
        title = session.title
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        isAgent = false
    }

    var selection: ControlPanelSidebarSelection {
        switch id {
        case .chat(let sessionID):
            return .chat(sessionID)
        case .imageGeneration(let sessionID):
            return .imageGeneration(sessionID)
        }
    }

    static func recencySort(_ lhs: ControlPanelRecentSession, _ rhs: ControlPanelRecentSession) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private struct ControlPanelModelHistoryRow: View {
    let entry: ModelHistoryEntry
    let isCurrentModel: Bool
    let isServerRunning: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    private var isActive: Bool {
        isCurrentModel && isServerRunning
    }

    var body: some View {
        HStack(spacing: 7) {
            providerIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)

                HStack(spacing: 3) {
                    if let sizeLabel = entry.sizeLabel {
                        Text(sizeLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if let speed = entry.lastDecodeSpeed, speed > 0 {
                        if entry.sizeLabel != nil {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(Int(speed.rounded()))t/s")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer(minLength: 0)

            if isActive {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop \(entry.displayName)")
            } else if isHovering {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Start \(entry.displayName)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.green.opacity(0.08) : (isHovering ? Color.accentColor.opacity(0.06) : Color.clear))
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .contextMenu {
            Button {
                onStart()
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(isActive)

            if isActive {
                Button {
                    onStop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
            .disabled(isActive)
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let provider = entry.provider,
           let icon = LocalModelProviderIcon.image(for: provider) {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "cube.transparent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

private struct ControlPanelRecentSessionRow: View {
    let recent: ControlPanelRecentSession
    let isSelected: Bool
    let isCurrent: Bool
    let isSelectionDisabled: Bool
    let isDeleteDisabled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var isDeleteHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.clear)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)

                    if recent.isAgent {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(recent.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isSelectionDisabled)
            .help(recent.title)

            if isHovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .frame(width: 26, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isDeleteHovering ? Color.red.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDeleteHovering ? Color.red : Color.secondary)
                .disabled(isDeleteDisabled)
                .help("Delete \(recent.title)")
                .opacity(isHovering && !isDeleteDisabled ? 1 : 0)
                .allowsHitTesting(isHovering && !isDeleteDisabled)
                .onHover { isDeleteHovering = $0 }
            }
        }
        .sidebarRowSelectionStyle(isSelected: isSelected)
        .opacity(isSelectionDisabled && !isCurrent ? 0.55 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeInOut, value: isHovering)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .disabled(isSelectionDisabled)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(isDeleteDisabled)
        }
    }
}

private struct SidebarRowSelectionStyle: ViewModifier {
    let isSelected: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15, weight: .regular))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .foregroundStyle(Color.primary)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .animation(.easeInOut, value: isHovering)
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
    }
}

private extension View {
    func sidebarRowSelectionStyle(isSelected: Bool) -> some View {
        modifier(SidebarRowSelectionStyle(isSelected: isSelected))
    }
}

#Preview {
    ControlPanelView(model: .init(), navigation: .init(), runtime: .init())
}
