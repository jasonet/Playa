import AppKit
import Foundation
import PlayaServerKit
import SwiftUI
import Textual
import UniformTypeIdentifiers

private enum CLIProxyAPIModelCatalogError: Error {
    case noModels
    case unauthorized(statusCode: Int)
    case httpError(statusCode: Int)
}

struct ChatQueuedPrompt: Identifiable, Equatable {
    let id: UUID
    let content: String
    let attachmentCount: Int
    let position: Int
}

struct NativeAgentApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let operation: String
    let reason: String
}

struct ChatView: View {
    private enum Layout {
        static let conversationMaxWidth: CGFloat = 680
        static let horizontalPadding: CGFloat = 32
    }

    private struct TranscriptScrollMetrics: Equatable {
        var visibleMinY: CGFloat = 0
        var viewportHeight: CGFloat = 0
        var contentHeight: CGFloat = 0
    }

    @ObservedObject var model: PlayaModel
    @ObservedObject var chat: ChatViewModel
    @Binding var showsConfiguration: Bool
    @State private var transcriptScrollPosition = ScrollPosition(edge: .bottom)
    @State private var transcriptScrollMetrics = TranscriptScrollMetrics()
    @State private var composerHeight: CGFloat = 0
    @State private var followsLatestMessage = true

    var body: some View {
        ModelConfigurationLayout(
            model: model,
            isConfigurationVisible: $showsConfiguration
        ) {
            VStack(spacing: 0) {
                if chat.currentSessionIsAgent, let workingDirectory = chat.currentWorkingDirectory {
                    HStack(spacing: 8) {
                        Label(chat.currentAgentHarnessKind.displayName, systemImage: chat.currentAgentHarnessKind.systemImage)
                            .font(.caption.weight(.semibold))

                        Button {
                            let url = URL(fileURLWithPath: workingDirectory)
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                Text(workingDirectory)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Reveal workspace folder in Finder")
                        .contextMenu {
                            Button("Reveal in Finder") {
                                let url = URL(fileURLWithPath: workingDirectory)
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                            }
                            Button("Copy Workspace Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(workingDirectory, forType: .string)
                            }
                        }

                        Spacer()

                        if chat.currentAgentHarnessKind == .fx {
                            Picker("Mode", selection: Binding(
                                get: { chat.currentAgentExecutionMode },
                                set: { chat.selectAgentExecutionMode($0) }
                            )) {
                                ForEach(FxAgentExecutionMode.allCases) { mode in
                                    Label(mode.displayName, systemImage: mode.systemImage)
                                        .tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.07))
                    Divider()
                }

                if let error = chat.refreshErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer()
                        if chat.currentAgentProvider == .cliProxyAPI {
                            Button("Configure…") {
                                chat.isConfiguringCLIProxy = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Button {
                            chat.refreshErrorMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                    Divider()
                }

                transcript
                    .overlay(alignment: .bottom) {
                        ChatComposer(
                            model: model,
                            viewModel: chat,
                            unavailableReason: unavailableReason,
                            canCompose: canCompose,
                            canSend: canSend,
                            onSend: {
                                chat.send(using: model)
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .frame(maxWidth: Layout.conversationMaxWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Layout.horizontalPadding)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            let isInitialMeasurement = composerHeight == 0
                            composerHeight = height
                            if isInitialMeasurement {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(50))
                                    transcriptScrollPosition.scrollTo(edge: .bottom)
                                }
                            }
                        }
                    }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            ChatTranscriptPagingMonitor { direction in
                pageTranscript(direction)
            }
            .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $chat.isConfiguringCLIProxy) {
            CLIProxyConfigurationSheet {
                chat.refreshCLIProxyAPIModels(force: true)
            }
        }
        .alert("Allow Agent operation?", isPresented: Binding(
            get: { chat.pendingNativeAgentApproval != nil },
            set: { if !$0 { chat.resolveNativeAgentApproval(allowed: false) } }
        ), presenting: chat.pendingNativeAgentApproval) { _ in
            Button("Deny", role: .cancel) { chat.resolveNativeAgentApproval(allowed: false) }
            Button("Allow") { chat.resolveNativeAgentApproval(allowed: true) }
        } message: { request in
            Text("\(request.operation)\n\n\(request.reason)")
        }
    }

    private var selectedModelID: String? {
        model.settings.normalized().languageModelID
    }

    private var isServerReady: Bool {
        model.serverState == .running
    }

    private var canSend: Bool {
        if chat.currentSessionIsAgent {
            return chat.canSend(isRunning: isServerReady, selectedModelID: selectedModelID)
        }
        return model.settings.structuredOutputValidationError == nil
            && chat.canSend(isRunning: isServerReady, selectedModelID: selectedModelID)
    }

    private var canCompose: Bool {
        if chat.currentSessionIsAgent {
            return !chat.currentAgentRequiresLocalGateway
                || (isServerReady && chat.currentAgentModelID?.isEmpty == false)
        }
        return isServerReady
            && selectedModelID?.isEmpty == false
            && model.settings.structuredOutputValidationError == nil
    }

    private var unavailableReason: String? {
        if chat.currentSessionIsAgent {
            return chat.unavailableReason(isRunning: isServerReady, selectedModelID: selectedModelID)
        }
        if case .error(let msg) = model.serverState {
            return msg
        }
        if case .starting = model.serverState {
            return "Server is starting... model loading may take 30-60s"
        }
        if case .stopped = model.serverState, model.selectedModelName != nil {
            return "Server is stopped. Click Start in the sidebar to launch."
        }
        return chat.unavailableReason(isRunning: isServerReady, selectedModelID: selectedModelID)
            ?? model.settings.structuredOutputValidationError
    }

    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if chat.visibleMessages.isEmpty {
                    if chat.messages.isEmpty {
                        ChatEmptyTranscriptView(
                            serverState: model.serverState,
                            selectedModelID: selectedModelID
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                } else {
                    ForEach(chat.visibleMessages) { message in
                        ChatMessageRow(
                            message: message,
                            bodyFontSize: model.settings.chatBodyFontSize,
                            lineHeightMultiplier: model.settings.chatLineHeightMultiplier,
                            paragraphLineHeightMultiplier: model.settings.chatParagraphLineHeightMultiplier
                        )
                            .id(message.id)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxWidth: Layout.conversationMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, max(18, composerHeight))
        }
        .scrollPosition($transcriptScrollPosition)
        .onScrollGeometryChange(for: TranscriptScrollMetrics.self) { geometry in
            TranscriptScrollMetrics(
                visibleMinY: geometry.visibleRect.minY,
                viewportHeight: geometry.visibleRect.height,
                contentHeight: geometry.contentSize.height
            )
        } action: { _, metrics in
            transcriptScrollMetrics = metrics
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 160
        } action: { _, isNearBottom in
            followsLatestMessage = isNearBottom
        }
        .onChange(of: chat.scrollToken) { _, _ in
            if followsLatestMessage {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: chat.currentSessionID) { _, _ in
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
        .onAppear {
            followsLatestMessage = true
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func pageTranscript(_ direction: ChatTranscriptPageDirection) {
        let viewportHeight = transcriptScrollMetrics.viewportHeight
        let maximumOffset = max(
            0,
            transcriptScrollMetrics.contentHeight - viewportHeight
        )
        guard viewportHeight > 0, maximumOffset > 0 else {
            return
        }

        let contextOverlap = min(80, viewportHeight * 0.12)
        let pageDistance = max(120, viewportHeight - contextOverlap)
        let signedDistance = direction == .down ? pageDistance : -pageDistance
        let targetOffset = min(
            max(transcriptScrollMetrics.visibleMinY + signedDistance, 0),
            maximumOffset
        )

        followsLatestMessage = targetOffset >= maximumOffset - 160
        withAnimation(.easeOut(duration: 0.16)) {
            transcriptScrollPosition.scrollTo(y: targetOffset)
        }
    }
}

private enum ChatTranscriptPageDirection {
    case up
    case down
}

private struct ChatTranscriptPagingMonitor: NSViewRepresentable {
    let onPage: (ChatTranscriptPageDirection) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPage: onPage)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        context.coordinator.onPage = onPage
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class MonitorView: NSView {}

    @MainActor
    final class Coordinator {
        var onPage: (ChatTranscriptPageDirection) -> Void
        private weak var view: MonitorView?
        private var eventMonitor: Any?

        init(onPage: @escaping (ChatTranscriptPageDirection) -> Void) {
            self.onPage = onPage
        }

        func attach(to view: MonitorView) {
            self.view = view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window = view?.window,
                  event.window === window,
                  relevantModifiers(for: event).isEmpty,
                  !isComposingText(in: window),
                  let direction = pageDirection(for: event)
            else {
                return event
            }

            onPage(direction)
            return nil
        }

        private func pageDirection(for event: NSEvent) -> ChatTranscriptPageDirection? {
            switch event.specialKey {
            case .pageUp:
                return .up
            case .pageDown:
                return .down
            default:
                return nil
            }
        }

        private func isComposingText(in window: NSWindow) -> Bool {
            (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        }

        private func relevantModifiers(for event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags.intersection([.command, .control, .option, .shift])
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    private static let liveDecodeRateRefreshInterval: TimeInterval = 0.25

    private struct QueuedChatRequest {
        let id: UUID
        let sessionID: UUID
        let userMessageID: UUID
        let assistantMessageID: UUID
        let settings: PlayaSettings
    }

    @Published private(set) var sessions: [ChatSessionSummary] = []
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var messages: [ChatTranscriptMessage] = []
    @Published private(set) var pendingImageAttachments: [ChatImageAttachment] = []
    @Published var draft = ""
    @Published var isConfiguringCLIProxy = false
    @Published var refreshErrorMessage: String?
    @Published private(set) var activeRequestSessionID: UUID?
    @Published private(set) var sendingStartedAt: Date?
    @Published private(set) var scrollToken = 0
    @Published private(set) var currentAgentExecutionMode: FxAgentExecutionMode = .local
    @Published private(set) var currentAgentHarnessKind: AgentHarnessKind = .fx
    @Published private(set) var currentAgentProvider: FxAgentProvider = .gateway
    @Published private(set) var pendingNativeAgentApproval: NativeAgentApprovalRequest?
    @Published private(set) var currentAgentModelID: String?
    @Published private(set) var currentAgentAvailableModelIDs: [String] = []
    @Published private(set) var cliProxyAPIModelIDs: [String] = []
    @Published private(set) var cliProxyAPIModelError: String?
    @Published private(set) var isLoadingAgentModels = false
    @Published private(set) var agentModelCatalogError: String?

    private let client = PlayaChatClient()
    private let sessionStore = ChatSessionStore()
    private var activeTask: Task<Void, Never>?
    private var agentConfigurationTask: Task<Void, Never>?
    private var activeRequestID: UUID?
    @Published private var requestQueue: [QueuedChatRequest] = []
    private var storedSessions: [ChatSession] = []
    private var currentSession: ChatSession?
    private var liveDecodeRateRefreshDates: [UUID: Date] = [:]
    private weak var appModel: PlayaModel?
    private var nativeAgentApprovalContinuation: CheckedContinuation<Bool, Never>?

    init() {
        storedSessions = sessionStore.loadSessions()
        pruneRedundantEmptySessions()
        if let latestSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(latestSession)
        } else {
            createSession()
        }
    }

    deinit {
        activeTask?.cancel()
        agentConfigurationTask?.cancel()
    }

    var currentSessionIsAgent: Bool { currentSession?.isAgent == true }

    var currentWorkingDirectory: String? { currentSession?.workingDirectory }

    var availableAgentProviders: [FxAgentProvider] {
        currentAgentHarnessKind == .fx ? FxAgentProvider.allCases : [.gateway, .cliProxyAPI]
    }

    var currentAgentRequiresLocalGateway: Bool {
        currentAgentProvider == .gateway
            || (currentAgentHarnessKind == .fx && currentAgentProvider == .cliProxyAPI)
    }

    var isCurrentSessionSending: Bool {
        guard let activeRequestSessionID else {
            return false
        }
        return activeRequestSessionID == currentSessionID
    }

    var hasPendingRequests: Bool {
        activeRequestSessionID != nil || !requestQueue.isEmpty
    }

    var visibleMessages: [ChatTranscriptMessage] {
        let queuedMessageIDs = Set(
            requestQueue.lazy
                .filter { $0.sessionID == self.currentSessionID }
                .map(\.userMessageID)
        )
        return messages.filter { !queuedMessageIDs.contains($0.id) }
    }

    var currentSessionQueuedPrompts: [ChatQueuedPrompt] {
        requestQueue.enumerated().compactMap { index, queuedRequest in
            guard queuedRequest.sessionID == currentSessionID,
                  let message = message(queuedRequest.userMessageID, in: queuedRequest.sessionID)
            else {
                return nil
            }
            return ChatQueuedPrompt(
                id: queuedRequest.id,
                content: message.content,
                attachmentCount: message.imageAttachments.count,
                position: index + 1
            )
        }
    }

    func isSessionBusy(_ sessionID: UUID) -> Bool {
        activeRequestSessionID == sessionID
            || requestQueue.contains(where: { $0.sessionID == sessionID })
    }

    func canSend(isRunning: Bool, selectedModelID: String?) -> Bool {
        if currentSessionIsAgent {
            let providerIsAvailable = !currentAgentRequiresLocalGateway || isRunning
            return providerIsAvailable
                && currentAgentModelID?.isEmpty == false
                && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return isRunning
            && selectedModelID?.isEmpty == false
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingImageAttachments.isEmpty)
    }

    func unavailableReason(isRunning: Bool, selectedModelID: String?) -> String? {
        if currentSessionIsAgent {
            if currentAgentRequiresLocalGateway, !isRunning {
                return "Local Gateway is stopped."
            }
            if isLoadingAgentModels {
                return "Loading \(currentAgentProvider.displayName) models..."
            }
            if currentAgentProvider == .cliProxyAPI && cliProxyAPIModelIDs.isEmpty {
                return cliProxyAPIModelError ?? "CLIProxyAPI is not configured. Configure Base URL and API Key."
            }
            if currentAgentModelID?.isEmpty != false {
                return agentModelCatalogError ?? "Select an Agent model."
            }
            if activeRequestSessionID == currentSessionID {
                return "Working..."
            }
            return agentModelCatalogError
        }
        if !isRunning {
            return "Server is stopped."
        }
        if selectedModelID?.isEmpty != false {
            return "Select a model in Models."
        }
        if activeRequestSessionID == currentSessionID {
            return "Working..."
        }
        return nil
    }

    func createSession() {
        if canReuseCurrentEmptySession {
            if let currentSession {
                applyCurrentSession(currentSession)
            }
            return
        }

        let createdAt = Date()
        let session = ChatSession(
            id: UUID(),
            title: ChatSession.timestampTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: []
        )

        persistCurrentSession(updateTimestamp: false)
        storedSessions.append(session)
        pruneRedundantEmptySessions()
        sessionStore.saveSession(session)
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func createAgentSession(
        workingDirectory: URL,
        initialLocalModelID: String?,
        harnessKind: AgentHarnessKind = .fx
    ) {
        persistCurrentSession(updateTimestamp: false)
        let createdAt = Date()
        let session = ChatSession(
            id: UUID(),
            title: workingDirectory.lastPathComponent,
            createdAt: createdAt,
            updatedAt: createdAt,
            messages: [],
            kind: .agent,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            agentProvider: .gateway,
            agentModelID: initialLocalModelID,
            agentHarnessKind: harnessKind
        )
        storedSessions.append(session)
        pruneRedundantEmptySessions()
        sessionStore.saveSession(session)
        draft = ""
        pendingImageAttachments.removeAll()
        applyCurrentSession(session)
    }

    func selectSession(_ sessionID: UUID) {
        guard sessionID != currentSessionID else {
            return
        }

        if let session = storedSessions.first(where: { $0.id == sessionID }) {
            persistCurrentSession(updateTimestamp: false)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
            return
        }

        if let session = sessionStore.loadSession(id: sessionID) {
            persistCurrentSession(updateTimestamp: false)
            upsertStoredSession(session)
            draft = ""
            pendingImageAttachments.removeAll()
            applyCurrentSession(session)
        }
    }

    func deleteSession(_ sessionID: UUID) {
        guard !isSessionBusy(sessionID) else {
            return
        }

        storedSessions.removeAll { $0.id == sessionID }
        sessionStore.deleteSession(id: sessionID)
        pruneRedundantEmptySessions()

        guard sessionID == currentSessionID else {
            refreshSessionList()
            return
        }

        draft = ""
        pendingImageAttachments.removeAll()

        if let nextSession = storedSessions.sorted(by: ChatSession.recencySort).first {
            applyCurrentSession(nextSession)
        } else {
            currentSession = nil
            currentSessionID = nil
            messages = []
            createSession()
        }
    }

    func send(using appModel: PlayaModel) {
        let settings = appModel.settings.normalized()
        guard let currentSession else {
            return
        }

        self.appModel = appModel
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentSession.isAgent {
            guard canSend(isRunning: appModel.isRunning, selectedModelID: settings.languageModelID),
                  let selectedAgentModelID = currentAgentModelID
            else { return }
            let modelID = currentAgentProvider == .gateway
                ? resolvedAgentLocalModelID(selectedAgentModelID, settings: settings)
                : selectedAgentModelID
            sendAgent(
                prompt: prompt,
                provider: currentAgentProvider,
                modelID: modelID,
                settings: settings,
                session: currentSession
            )
            return
        }

        guard canSend(isRunning: appModel.isRunning, selectedModelID: settings.languageModelID),
              let modelID = settings.languageModelID
        else { return }

        let imageAttachments = pendingImageAttachments
        draft = ""
        pendingImageAttachments.removeAll()

        let userMessage = ChatTranscriptMessage(
            role: .user,
            content: prompt,
            modelID: modelID,
            imageAttachments: imageAttachments
        )
        messages.append(userMessage)
        persistCurrentSession(updateTimestamp: true)
        self.appModel = appModel
        requestQueue.append(QueuedChatRequest(
            id: UUID(),
            sessionID: currentSession.id,
            userMessageID: userMessage.id,
            assistantMessageID: UUID(),
            settings: settings
        ))
        bumpScroll()
        startNextRequestIfNeeded()
    }

    private func sendAgent(
        prompt: String,
        provider: FxAgentProvider,
        modelID: String,
        settings: PlayaSettings,
        session: ChatSession
    ) {
        guard !prompt.isEmpty,
              let workingDirectory = session.workingDirectory
        else { return }

        draft = ""
        pendingImageAttachments.removeAll()
        let userMessage = ChatTranscriptMessage(role: .user, content: prompt, modelID: modelID)
        let assistantMessage = ChatTranscriptMessage(
            role: .assistant,
            content: "",
            modelID: modelID,
            isStreaming: true,
            isThinkingEnabled: true
        )
        messages.append(userMessage)
        messages.append(assistantMessage)
        persistCurrentSession(updateTimestamp: true)
        activeRequestSessionID = session.id
        sendingStartedAt = Date()
        bumpScroll()

        let executionMode = session.agentExecutionMode ?? currentAgentExecutionMode
        let harnessKind = session.resolvedAgentHarnessKind
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if harnessKind != .fx {
                    try await self.runNativeAgent(
                        kind: harnessKind,
                        prompt: prompt,
                        workspace: URL(fileURLWithPath: workingDirectory, isDirectory: true),
                        provider: provider,
                        modelID: modelID,
                        settings: settings,
                        assistantMessageID: assistantMessage.id,
                        sessionID: session.id
                    )
                    self.finishAssistantMessage(
                        assistantMessage.id,
                        in: session.id,
                        fallbackContent: "Agent completed without a text response.",
                        fallbackReasoningContent: nil,
                        responseMetrics: nil,
                        isCancelled: false
                    )
                    self.activeRequestSessionID = nil
                    self.sendingStartedAt = nil
                    self.activeTask = nil
                    self.bumpScroll()
                    return
                }
                let result = try await FxAgentHarness.run(
                    prompt: prompt,
                    workspace: URL(fileURLWithPath: workingDirectory, isDirectory: true),
                    provider: provider,
                    modelID: modelID,
                    apiKey: settings.serverAPIKey,
                    executionMode: executionMode,
                    existingSessionID: session.fxSessionID
                ) { event in
                    await self.applyAgentEvent(
                        event,
                        assistantMessageID: assistantMessage.id,
                        sessionID: session.id
                    )
                }
                let persistedModelID = provider == .gateway
                    ? (session.agentModelID ?? result.modelID)
                    : result.modelID
                self.updateAgentConfiguration(
                    sessionID: session.id,
                    fxSessionID: result.sessionID,
                    provider: provider,
                    modelID: persistedModelID,
                    availableModelIDs: result.availableModelIDs
                )
                self.finishAssistantMessage(
                    assistantMessage.id,
                    in: session.id,
                    fallbackContent: "Agent completed without a text response.",
                    fallbackReasoningContent: nil,
                    responseMetrics: nil,
                    isCancelled: false
                )
            } catch is CancellationError {
                self.finishAssistantMessage(
                    assistantMessage.id,
                    in: session.id,
                    fallbackContent: "Agent cancelled.",
                    fallbackReasoningContent: nil,
                    responseMetrics: nil,
                    isCancelled: true
                )
            } catch {
                self.failAssistantMessage(assistantMessage.id, in: session.id, error: error)
            }
            self.activeRequestSessionID = nil
            self.sendingStartedAt = nil
            self.activeTask = nil
            self.bumpScroll()
        }
    }

    private func runNativeAgent(
        kind: AgentHarnessKind,
        prompt: String,
        workspace: URL,
        provider: FxAgentProvider,
        modelID: String,
        settings: PlayaSettings,
        assistantMessageID: UUID,
        sessionID: UUID
    ) async throws {
        let complete: NativeAgentRuntime.Complete = { [weak self] messages in
            guard let self else { throw CancellationError() }
            if provider == .cliProxyAPI {
                return try await self.completeCLIProxyAPIChat(
                    messages: messages,
                    modelID: modelID,
                    settings: settings
                )
            }
            let resolvedModelID: String
            if provider == .gateway,
               let loaded = await self.appModel?.loadedServerModelID {
                resolvedModelID = loaded
            } else {
                resolvedModelID = modelID
            }
            let request = MLXChatCompletionRequest(
                model: resolvedModelID,
                messages: messages,
                maxTokens: settings.maxTokens,
                temperature: settings.temperature,
                topK: settings.topK,
                topP: settings.topP,
                minP: settings.minP,
                repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
                enableThinking: settings.thinkingEnabled,
                thinkingBudget: settings.thinkingEnabled && settings.thinkingBudgetEnabled ? settings.thinkingBudget : nil
            )
            return try await self.client.completeChat(request).content
        }
        let approval: NativeAgentRuntime.Approval = { [weak self] operation, reason in
            guard let self else { return false }
            return await self.requestNativeAgentApproval(operation: operation, reason: reason)
        }
        let events: NativeAgentRuntime.Event = { [weak self] event in
            await self?.applyNativeAgentEvent(event, assistantMessageID: assistantMessageID, sessionID: sessionID)
        }
        switch kind {
        case .deep:
            try await DeepAgentHarness.run(prompt: prompt, workspace: workspace, complete: complete, approval: approval, onEvent: events)
        case .prime:
            try await PrimeAgentHarness.run(prompt: prompt, workspace: workspace, complete: complete, approval: approval, onEvent: events)
        case .fx:
            break
        }
    }

    private func completeCLIProxyAPIChat(
        messages: [MLXChatMessage],
        modelID: String,
        settings: PlayaSettings
    ) async throws -> String {
        let baseURL = Self.resolvedCLIProxyBaseURL()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
        let endpoint = baseURL.hasSuffix("/v1")
            ? "\(baseURL)/chat/completions"
            : "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var payload: [String: Any] = [
            "model": Self.unroutedCLIProxyAPIModelID(modelID),
            "messages": messages.map { message in
                [
                    "role": message.role,
                    "content": message.textContent ?? "",
                ]
            },
            "stream": false,
        ]
        if settings.maxTokens > 0 {
            payload["max_tokens"] = settings.maxTokens
        }
        payload["temperature"] = settings.temperature
        payload["top_p"] = settings.topP

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let apiKey = Self.resolvedCLIProxyAPIKey()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PlayaChatError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlayaChatError.httpStatus(
                http.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else {
            throw PlayaChatError.invalidResponse
        }

        let content: String
        if let text = message["content"] as? String {
            content = text
        } else if let parts = message["content"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            content = ""
        }
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        if let reasoning = message["reasoning_content"] as? String,
           !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reasoning
        }
        throw PlayaChatError.missingAssistantContent
    }

    private func requestNativeAgentApproval(operation: String, reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            nativeAgentApprovalContinuation?.resume(returning: false)
            nativeAgentApprovalContinuation = continuation
            pendingNativeAgentApproval = NativeAgentApprovalRequest(id: UUID(), operation: operation, reason: reason)
        }
    }

    func resolveNativeAgentApproval(allowed: Bool) {
        pendingNativeAgentApproval = nil
        nativeAgentApprovalContinuation?.resume(returning: allowed)
        nativeAgentApprovalContinuation = nil
    }

    private func applyNativeAgentEvent(
        _ event: AgentHarnessEvent,
        assistantMessageID: UUID,
        sessionID: UUID
    ) {
        updateMessage(assistantMessageID, in: sessionID) { message in
            switch event {
            case .text(let text): message.content += text
            case .status(let status):
                if !message.reasoningContent.isEmpty { message.reasoningContent += "\n" }
                message.reasoningContent += "• \(status)"
            case .image(let attachment):
                if !message.imageAttachments.contains(where: { $0.base64Data == attachment.base64Data }) { message.imageAttachments.append(attachment) }
            case .tasks(let tasks): message.agentTasks = tasks
            }
        }
        if currentSessionID == sessionID { bumpScroll() }
    }

    private func applyAgentEvent(
        _ event: FxAgentEvent,
        assistantMessageID: UUID,
        sessionID: UUID
    ) {
        updateMessage(assistantMessageID, in: sessionID) { message in
            switch event {
            case .text(let text):
                message.content += text
            case .status(let status):
                if !message.reasoningContent.isEmpty {
                    message.reasoningContent += "\n"
                }
                message.reasoningContent += "• \(status)"
            case .image(let attachment):
                if !message.imageAttachments.contains(where: { $0.base64Data == attachment.base64Data }) {
                    message.imageAttachments.append(attachment)
                }
            }
        }
        if currentSessionID == sessionID {
            bumpScroll()
        }
    }

    func selectAgentExecutionMode(_ mode: FxAgentExecutionMode) {
        guard currentSessionIsAgent,
              mode != currentAgentExecutionMode,
              !hasPendingRequests
        else { return }
        currentAgentExecutionMode = mode
        mutateCurrentAgentSession { session in
            session.agentExecutionMode = mode
        }
    }

    func selectAgentProvider(_ provider: FxAgentProvider) {
        guard availableAgentProviders.contains(provider) else { return }
        guard currentSessionIsAgent,
              provider != currentAgentProvider,
              !hasPendingRequests
        else { return }
        currentAgentProvider = provider
        currentAgentModelID = nil
        currentAgentAvailableModelIDs = []
        isLoadingAgentModels = false
        agentModelCatalogError = nil
        mutateCurrentAgentSession { session in
            session.agentProvider = provider
            session.agentModelID = nil
        }
        refreshCurrentAgentModelCatalog()
    }

    func selectAgentModel(_ modelID: String) {
        guard currentSessionIsAgent,
              !modelID.isEmpty,
              !hasPendingRequests
        else { return }
        currentAgentModelID = modelID
        agentModelCatalogError = nil
        mutateCurrentAgentSession { session in
            session.agentProvider = currentAgentProvider
            session.agentModelID = modelID
        }
    }

    func ensureCurrentAgentLocalModel(_ fallbackModelID: String?) {
        guard currentSessionIsAgent,
              currentAgentProvider == .gateway,
              currentAgentModelID?.isEmpty != false,
              let fallbackModelID,
              !fallbackModelID.isEmpty
        else { return }
        selectAgentModel(fallbackModelID)
    }

    func refreshCurrentAgentModelCatalog(force: Bool = false) {
        guard currentSessionIsAgent,
              let session = currentSession,
              let workingDirectory = session.workingDirectory,
              !isSessionBusy(session.id),
              !isLoadingAgentModels
        else { return }

        let provider = currentAgentProvider
        if provider == .cliProxyAPI {
            refreshCLIProxyAPIModels(force: force)
            return
        }
        guard currentAgentHarnessKind == .fx else {
            agentConfigurationTask?.cancel()
            agentConfigurationTask = nil
            currentAgentAvailableModelIDs = []
            isLoadingAgentModels = false
            agentModelCatalogError = nil
            if force {
                refreshErrorMessage = nil
            }
            return
        }
        // The local gateway advertises the model that is actually loaded by the
        // running server. Do not try to reapply a stale repo ID before reading it.
        let requestedModelID = provider == .gateway ? nil : currentAgentModelID
        let sessionID = session.id
        let fxSessionID = session.fxSessionID
        let apiKey = appModel?.settings.serverAPIKey
        agentConfigurationTask?.cancel()
        isLoadingAgentModels = true
        agentModelCatalogError = nil
        if force {
            refreshErrorMessage = nil
        }

        let executionMode = session.agentExecutionMode ?? currentAgentExecutionMode
        agentConfigurationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await FxAgentHarness.configure(
                    workspace: URL(fileURLWithPath: workingDirectory, isDirectory: true),
                    provider: provider,
                    modelID: requestedModelID,
                    apiKey: apiKey,
                    executionMode: executionMode,
                    existingSessionID: fxSessionID
                )
                guard self.currentSessionID == sessionID,
                      self.currentAgentProvider == provider
                else { return }
                self.updateAgentConfiguration(
                    sessionID: sessionID,
                    fxSessionID: result.sessionID,
                    provider: provider,
                    modelID: result.modelID,
                    availableModelIDs: result.availableModelIDs
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.currentSessionID == sessionID,
                      self.currentAgentProvider == provider
                else { return }
                let errorMsg = error.localizedDescription
                self.agentModelCatalogError = errorMsg
                self.refreshErrorMessage = errorMsg
            }
            if self.currentSessionID == sessionID,
               self.currentAgentProvider == provider {
                self.isLoadingAgentModels = false
            }
            self.agentConfigurationTask = nil
        }
    }

    func refreshCLIProxyAPIModels(force: Bool = false) {
        guard let sessionID = currentSessionID else { return }
        let defaults = UserDefaults.standard
        let cachedModelIDs = defaults.stringArray(forKey: "integration.cliProxyAPI.cachedModelIDs") ?? []
        let defaultModelID = defaults.string(forKey: "integration.cliProxyAPI.defaultModelID") ?? ""

        if !force && !cachedModelIDs.isEmpty {
            self.cliProxyAPIModelIDs = cachedModelIDs
            self.cliProxyAPIModelError = nil
            self.agentModelCatalogError = nil
            self.refreshErrorMessage = nil
            self.isLoadingAgentModels = false
            self.currentAgentAvailableModelIDs = cachedModelIDs.map { "cliproxyapi::\($0)" }

            if let currentModelID = self.currentAgentModelID.map(Self.unroutedCLIProxyAPIModelID),
               cachedModelIDs.contains(currentModelID) {
                self.selectAgentModel("cliproxyapi::\(currentModelID)")
            } else if !defaultModelID.isEmpty && cachedModelIDs.contains(defaultModelID) {
                self.selectAgentModel("cliproxyapi::\(defaultModelID)")
            } else if let firstModelID = cachedModelIDs.first {
                self.selectAgentModel("cliproxyapi::\(firstModelID)")
            }
            return
        }

        let baseURL = Self.resolvedCLIProxyBaseURL()
        let cleanBaseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n\r"))
        guard let url = URL(string: "\(cleanBaseURL)/models") else {
            cliProxyAPIModelIDs = []
            let err = "Invalid CLIProxyAPI URL: \(baseURL)"
            cliProxyAPIModelError = err
            agentModelCatalogError = err
            if force {
                refreshErrorMessage = err
            }
            isLoadingAgentModels = false
            return
        }

        let apiKey = Self.resolvedCLIProxyAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)

        isLoadingAgentModels = true
        cliProxyAPIModelIDs = []
        cliProxyAPIModelError = nil
        agentModelCatalogError = nil
        if force {
            refreshErrorMessage = nil
        }
        agentConfigurationTask?.cancel()
        agentConfigurationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw CLIProxyAPIModelCatalogError.unauthorized(statusCode: http.statusCode)
                    } else {
                        throw CLIProxyAPIModelCatalogError.httpError(statusCode: http.statusCode)
                    }
                }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let entries = object?["data"] as? [[String: Any]] ?? []
                let modelIDs = entries.compactMap { $0["id"] as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let uniqueModelIDs = Array(Set(modelIDs)).sorted()
                guard !uniqueModelIDs.isEmpty else {
                    throw CLIProxyAPIModelCatalogError.noModels
                }
                guard self.currentSessionID == sessionID,
                      self.currentAgentProvider == .cliProxyAPI
                else { return }
                defaults.set(uniqueModelIDs, forKey: "integration.cliProxyAPI.cachedModelIDs")
                self.cliProxyAPIModelIDs = uniqueModelIDs
                self.cliProxyAPIModelError = nil
                self.agentModelCatalogError = nil
                self.refreshErrorMessage = nil
                self.currentAgentAvailableModelIDs = uniqueModelIDs.map { "cliproxyapi::\($0)" }

                let currentModelID = self.currentAgentModelID.map(Self.unroutedCLIProxyAPIModelID)
                if let currentModelID, uniqueModelIDs.contains(currentModelID) {
                    self.selectAgentModel("cliproxyapi::\(currentModelID)")
                } else if !defaultModelID.isEmpty && uniqueModelIDs.contains(defaultModelID) {
                    self.selectAgentModel("cliproxyapi::\(defaultModelID)")
                } else if let firstModelID = uniqueModelIDs.first {
                    self.selectAgentModel("cliproxyapi::\(firstModelID)")
                }
            } catch {
                guard self.currentSessionID == sessionID,
                      self.currentAgentProvider == .cliProxyAPI
                else { return }
                self.cliProxyAPIModelIDs = []
                self.currentAgentAvailableModelIDs = []
                let descriptiveError: String
                if let catalogError = error as? CLIProxyAPIModelCatalogError {
                    switch catalogError {
                    case .noModels:
                        descriptiveError = "CLIProxyAPI returned 0 models from \(cleanBaseURL)/models"
                    case .unauthorized(let code):
                        descriptiveError = "CLIProxyAPI authentication failed (HTTP \(code)). Check API Key."
                    case .httpError(let code):
                        descriptiveError = "CLIProxyAPI returned HTTP \(code) from \(cleanBaseURL)/models"
                    }
                } else if let urlError = error as? URLError {
                    switch urlError.code {
                    case .cannotConnectToHost:
                        descriptiveError = "Cannot connect to CLIProxyAPI at \(cleanBaseURL) (Connection refused). Is EasyCLIProxyAPI running?"
                    case .timedOut:
                        descriptiveError = "Connection to CLIProxyAPI timed out at \(cleanBaseURL)"
                    default:
                        descriptiveError = "CLIProxyAPI error: \(urlError.localizedDescription)"
                    }
                } else {
                    descriptiveError = "CLIProxyAPI error: \(error.localizedDescription)"
                }
                self.cliProxyAPIModelError = descriptiveError
                self.agentModelCatalogError = descriptiveError
                self.refreshErrorMessage = descriptiveError
            }
            self.isLoadingAgentModels = false
            self.agentConfigurationTask = nil
        }
    }

    static func resolvedCLIProxyBaseURL() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "integration.cliProxyAPI.baseURL")?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        let legacyHost = defaults.string(forKey: "integration.cliProxyAPI.host")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyPort = defaults.integer(forKey: "integration.cliProxyAPI.port")
        if let legacyHost, !legacyHost.isEmpty, (1...65535).contains(legacyPort) {
            return "http://\(legacyHost):\(legacyPort)/v1"
        }
        return "http://127.0.0.1:8317/v1"
    }

    static func resolvedCLIProxyAPIKey() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "integration.cliProxyAPI.apiKey") {
            return saved
        }
        return "123456"
    }

    private static func unroutedCLIProxyAPIModelID(_ modelID: String) -> String {
        let prefix = "cliproxyapi::"
        return modelID.hasPrefix(prefix) ? String(modelID.dropFirst(prefix.count)) : modelID
    }

    private func updateAgentConfiguration(
        sessionID: UUID,
        fxSessionID: String,
        provider: FxAgentProvider,
        modelID: String,
        availableModelIDs: [String]
    ) {
        if currentSessionID == sessionID {
            currentAgentProvider = provider
            currentAgentModelID = modelID
            currentAgentAvailableModelIDs = availableModelIDs
            isLoadingAgentModels = false
            agentModelCatalogError = nil
        }
        updateSession(id: sessionID) { session in
            session.fxSessionID = fxSessionID
            session.agentProvider = provider
            session.agentModelID = modelID
        }
    }

    private func mutateCurrentAgentSession(_ mutate: (inout ChatSession) -> Void) {
        guard var session = currentSession, session.isAgent else { return }
        mutate(&session)
        currentSession = session
        upsertStoredSession(session)
        sessionStore.saveSession(session)
        refreshSessionList()
    }

    private func updateSession(id sessionID: UUID, mutate: (inout ChatSession) -> Void) {
        if currentSessionID == sessionID, var session = currentSession {
            mutate(&session)
            currentSession = session
            upsertStoredSession(session)
            sessionStore.saveSession(session)
            refreshSessionList()
            return
        }
        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        mutate(&storedSessions[index])
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    private func resolvedServerModelID(settingsModelID: String, settings: PlayaSettings) -> String {
        if let serverID = appModel?.loadedServerModelID {
            return serverID
        }
        if PlayaSettings.looksLikeLocalPath(settingsModelID) {
            return settingsModelID
        }
        return settings.resolveLocalModelPath(for: settingsModelID) ?? settingsModelID
    }

    private func resolvedAgentLocalModelID(_ modelID: String, settings: PlayaSettings) -> String {
        if PlayaSettings.looksLikeLocalPath(modelID) {
            return modelID
        }
        if let resolved = settings.resolveLocalModelPath(for: modelID) {
            return resolved
        }
        if modelID == settings.languageModelID,
           let serverID = appModel?.loadedServerModelID {
            return serverID
        }
        return modelID
    }

    func cancel() {
        activeTask?.cancel()
    }

    func prioritizeQueuedRequest(_ requestID: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }), index > 0 else {
            return
        }
        let queuedRequest = requestQueue.remove(at: index)
        requestQueue.insert(queuedRequest, at: 0)
    }

    func steerQueuedRequest(_ requestID: UUID) {
        guard requestQueue.contains(where: { $0.id == requestID }) else {
            return
        }
        prioritizeQueuedRequest(requestID)
        activeTask?.cancel()
    }

    func removeQueuedRequest(_ requestID: UUID) {
        guard let index = requestQueue.firstIndex(where: { $0.id == requestID }) else {
            return
        }
        let queuedRequest = requestQueue.remove(at: index)
        removeMessage(queuedRequest.userMessageID, from: queuedRequest.sessionID)
        persistSession(queuedRequest.sessionID, updateTimestamp: true)
        if currentSessionID == queuedRequest.sessionID {
            bumpScroll()
        }
    }

    func chooseImageAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK else {
            return
        }

        let attachments = panel.urls.compactMap { url in
            try? ChatImageAttachment(contentsOf: url)
        }
        guard !attachments.isEmpty else {
            return
        }

        pendingImageAttachments.append(contentsOf: attachments)
    }

    func removePendingImageAttachment(_ id: UUID) {
        pendingImageAttachments.removeAll { $0.id == id }
    }

    func clear() {
        activeTask?.cancel()
        activeTask = nil
        activeRequestID = nil
        activeRequestSessionID = nil
        requestQueue.removeAll()
        sendingStartedAt = nil
        draft = ""
        pendingImageAttachments.removeAll()
        messages.removeAll()
        persistCurrentSession(updateTimestamp: true)
        bumpScroll()
    }

    private func startNextRequestIfNeeded() {
        guard activeTask == nil else {
            return
        }

        while !requestQueue.isEmpty {
            let queuedRequest = requestQueue.removeFirst()
            guard let request = makeCompletionRequest(for: queuedRequest),
                  insertAssistantMessage(for: queuedRequest)
            else {
                continue
            }

            activeRequestID = queuedRequest.id
            activeRequestSessionID = queuedRequest.sessionID
            sendingStartedAt = Date()
            if currentSessionID == queuedRequest.sessionID {
                bumpScroll()
            }

            activeTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                do {
                    let completion = try await client.streamChat(request, onEvent: { [weak self] event in
                        await MainActor.run {
                            self?.append(
                                event: event,
                                to: queuedRequest.assistantMessageID,
                                in: queuedRequest.sessionID
                            )
                        }
                    })
                    finishAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        fallbackContent: completion.content,
                        fallbackReasoningContent: completion.reasoningContent,
                        responseMetrics: ChatResponseMetrics(completion: completion),
                        isCancelled: false
                    )
                    appModel?.refreshMetricsIfRunning(force: true)
                } catch is CancellationError {
                    finishAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        fallbackContent: "Response cancelled.",
                        fallbackReasoningContent: nil,
                        responseMetrics: nil,
                        isCancelled: true
                    )
                } catch {
                    failAssistantMessage(
                        queuedRequest.assistantMessageID,
                        in: queuedRequest.sessionID,
                        error: error
                    )
                    appModel?.refreshMetricsIfRunning(force: true)
                }

                guard activeRequestID == queuedRequest.id else {
                    return
                }
                activeRequestID = nil
                activeRequestSessionID = nil
                sendingStartedAt = nil
                activeTask = nil
                if currentSessionID == queuedRequest.sessionID {
                    bumpScroll()
                }
                startNextRequestIfNeeded()
            }
            return
        }
    }

    private func makeCompletionRequest(for queuedRequest: QueuedChatRequest) -> MLXChatCompletionRequest? {
        guard let settingsModelID = queuedRequest.settings.languageModelID,
              let sessionMessages = sessionMessages(for: queuedRequest.sessionID),
              let userMessageIndex = sessionMessages.firstIndex(where: { $0.id == queuedRequest.userMessageID })
        else {
            return nil
        }

        // CRITICAL: The model field in chat requests MUST be a local filesystem
        // path, not a HuggingFace repo ID. Passing a repo ID causes the server
        // to unload the local model and attempt to re-download from HuggingFace.
        let modelID: String = {
            if let serverID = appModel?.loadedServerModelID {
                return serverID  // Already a local path from /metrics
            }
            // Fallback: resolve repo ID to local path to prevent downloads.
            if PlayaSettings.looksLikeLocalPath(settingsModelID) {
                return settingsModelID
            }
            let settings = queuedRequest.settings
            if let resolved = settings.resolveLocalModelPath(for: settingsModelID) {
                return resolved
            }
            return settingsModelID  // Last resort — let server handle it
        }()

        var requestMessages = sessionMessages[...userMessageIndex].compactMap(\.apiMessage)
        if !queuedRequest.settings.systemPrompt.isEmpty {
            requestMessages.insert(
                MLXChatMessage(role: "system", content: queuedRequest.settings.systemPrompt),
                at: 0
            )
        }

        let settings = queuedRequest.settings
        return MLXChatCompletionRequest(
            model: modelID,
            messages: requestMessages,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature,
            topK: settings.topK,
            topP: settings.topP,
            minP: settings.minP,
            repetitionPenalty: settings.repetitionPenaltyEnabled ? settings.repetitionPenalty : nil,
            enableThinking: settings.thinkingEnabled,
            thinkingBudget: settings.thinkingEnabled && settings.thinkingBudgetEnabled
                ? settings.thinkingBudget
                : nil,
            thinkingStartToken: settings.thinkingEnabled ? settings.thinkingStartToken : nil,
            thinkingEndToken: settings.thinkingEnabled ? settings.thinkingEndToken : nil,
            responseFormat: settings.chatResponseFormat,
            stream: true
        )
    }

    private func insertAssistantMessage(for queuedRequest: QueuedChatRequest) -> Bool {
        let assistantMessage = ChatTranscriptMessage(
            id: queuedRequest.assistantMessageID,
            role: .assistant,
            content: "",
            modelID: queuedRequest.settings.languageModelID,
            isStreaming: true,
            isThinkingEnabled: queuedRequest.settings.thinkingEnabled
        )

        if currentSessionID == queuedRequest.sessionID {
            guard let userMessageIndex = messages.firstIndex(where: { $0.id == queuedRequest.userMessageID }) else {
                return false
            }
            messages.insert(assistantMessage, at: userMessageIndex + 1)
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == queuedRequest.sessionID }),
              let userMessageIndex = storedSessions[sessionIndex].messages.firstIndex(
                where: { $0.id == queuedRequest.userMessageID }
              )
        else {
            return false
        }
        storedSessions[sessionIndex].messages.insert(assistantMessage, at: userMessageIndex + 1)
        return true
    }

    private func sessionMessages(for sessionID: UUID) -> [ChatTranscriptMessage]? {
        if currentSessionID == sessionID {
            return messages
        }
        return storedSessions.first(where: { $0.id == sessionID })?.messages
    }

    private func message(_ messageID: UUID, in sessionID: UUID) -> ChatTranscriptMessage? {
        sessionMessages(for: sessionID)?.first(where: { $0.id == messageID })
    }

    private func removeMessage(_ messageID: UUID, from sessionID: UUID) {
        if currentSessionID == sessionID {
            messages.removeAll { $0.id == messageID }
            return
        }
        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        storedSessions[sessionIndex].messages.removeAll { $0.id == messageID }
    }

    private func append(event: MLXChatStreamDelta, to id: UUID, in sessionID: UUID) {
        let hasTextDelta = event.content?.isEmpty == false
            || event.reasoningContent?.isEmpty == false
        let shouldRefreshMetrics = shouldRefreshLiveMetrics(
            event,
            for: id
        )
        guard hasTextDelta || shouldRefreshMetrics else {
            return
        }

        updateMessage(id, in: sessionID) { message in
            if let reasoningContent = event.reasoningContent {
                message.reasoningContent.append(reasoningContent)
            }
            if let content = event.content {
                if !content.isEmpty,
                   !message.reasoningContent.isEmpty,
                   message.thinkingDuration == nil {
                    message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
                }
                message.content.append(content)
            }
            if shouldRefreshMetrics {
                message.responseMetrics = ChatResponseMetrics(
                    totalTokens: message.responseMetrics?.totalTokens,
                    generatedTokens: event.generatedTokens
                        ?? message.responseMetrics?.generatedTokens,
                    decodeTokensPerSecond: event.decodeTokensPerSecond
                        ?? message.responseMetrics?.decodeTokensPerSecond,
                    peakMemoryGB: message.responseMetrics?.peakMemoryGB
                )
            }
        }
        if hasTextDelta, currentSessionID == sessionID {
            bumpScroll()
        }
    }

    private func shouldRefreshLiveMetrics(
        _ event: MLXChatStreamDelta,
        for messageID: UUID
    ) -> Bool {
        let hasGeneratedTokens = event.generatedTokens.map { $0 > 0 } == true
        let hasDecodeRate = event.decodeTokensPerSecond.map {
            $0 > 0 && $0.isFinite
        } == true
        guard hasGeneratedTokens || hasDecodeRate else {
            return false
        }

        let now = Date()
        if let lastRefresh = liveDecodeRateRefreshDates[messageID],
           now.timeIntervalSince(lastRefresh) < Self.liveDecodeRateRefreshInterval {
            return false
        }

        liveDecodeRateRefreshDates[messageID] = now
        return true
    }

    private func finishAssistantMessage(
        _ id: UUID,
        in sessionID: UUID,
        fallbackContent: String,
        fallbackReasoningContent: String?,
        responseMetrics: ChatResponseMetrics?,
        isCancelled: Bool
    ) {
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        updateMessage(id, in: sessionID) { message in
            message.isStreaming = false
            if message.content.isEmpty && message.imageAttachments.isEmpty {
                message.content = fallbackContent
            }
            if message.reasoningContent.isEmpty,
               let fallbackReasoningContent {
                message.reasoningContent = fallbackReasoningContent
            }
            if !message.reasoningContent.isEmpty,
               message.thinkingDuration == nil {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
            if isCancelled,
               message.content == fallbackContent,
               message.reasoningContent.isEmpty {
                message.role = .error
            }
            message.responseMetrics = responseMetrics?.hasVisibleValues == true
                ? responseMetrics
                : nil
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    private func failAssistantMessage(_ id: UUID, in sessionID: UUID, error: Error) {
        liveDecodeRateRefreshDates.removeValue(forKey: id)
        guard updateMessage(id, in: sessionID, mutate: { message in
            message.role = .error
            message.content = error.localizedDescription
            message.isStreaming = false
            if !message.reasoningContent.isEmpty,
               message.thinkingDuration == nil {
                message.thinkingDuration = Date().timeIntervalSince(message.createdAt)
            }
        }) else {
            return
        }
        persistSession(sessionID, updateTimestamp: true)
    }

    @discardableResult
    private func updateMessage(
        _ messageID: UUID,
        in sessionID: UUID,
        mutate: (inout ChatTranscriptMessage) -> Void
    ) -> Bool {
        if currentSessionID == sessionID {
            guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
                return false
            }
            mutate(&messages[messageIndex])
            return true
        }

        guard let sessionIndex = storedSessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = storedSessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID })
        else {
            return false
        }

        mutate(&storedSessions[sessionIndex].messages[messageIndex])
        return true
    }

    private func bumpScroll() {
        scrollToken += 1
    }

    private func applyCurrentSession(_ session: ChatSession) {
        agentConfigurationTask?.cancel()
        agentConfigurationTask = nil
        var appliedSession = session
        if appliedSession.agentProvider == .gateway,
           appliedSession.agentModelID?.hasPrefix("cliproxyapi::") == true {
            appliedSession.agentProvider = .cliProxyAPI
            upsertStoredSession(appliedSession)
            sessionStore.saveSession(appliedSession)
        }
        if appliedSession.resolvedAgentHarnessKind != .fx,
           appliedSession.fxSessionID != nil {
            appliedSession.fxSessionID = nil
            upsertStoredSession(appliedSession)
            sessionStore.saveSession(appliedSession)
        }
        currentSession = appliedSession
        currentSessionID = appliedSession.id
        messages = appliedSession.messages
        currentAgentExecutionMode = appliedSession.agentExecutionMode ?? .local
        currentAgentHarnessKind = appliedSession.resolvedAgentHarnessKind
        currentAgentProvider = appliedSession.agentProvider ?? .gateway
        currentAgentModelID = appliedSession.agentModelID
        currentAgentAvailableModelIDs = []
        cliProxyAPIModelIDs = []
        cliProxyAPIModelError = nil
        isLoadingAgentModels = false
        agentModelCatalogError = nil
        refreshSessionList()
        bumpScroll()
    }

    private func persistCurrentSession(updateTimestamp: Bool) {
        guard var session = currentSession else {
            return
        }

        session.messages = messages
        session.title = ChatSession.defaultTitle(
            for: messages,
            createdAt: session.createdAt,
            fallback: session.title
        )
        if updateTimestamp {
            session.updatedAt = Date()
        }

        currentSession = session
        upsertStoredSession(session)
        sessionStore.saveSession(session)
        refreshSessionList()
    }

    private func persistSession(_ sessionID: UUID, updateTimestamp: Bool) {
        if sessionID == currentSessionID {
            persistCurrentSession(updateTimestamp: updateTimestamp)
            return
        }

        guard let index = storedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        storedSessions[index].title = ChatSession.defaultTitle(
            for: storedSessions[index].messages,
            createdAt: storedSessions[index].createdAt,
            fallback: storedSessions[index].title
        )
        if updateTimestamp {
            storedSessions[index].updatedAt = Date()
        }
        sessionStore.saveSession(storedSessions[index])
        refreshSessionList()
    }

    private func upsertStoredSession(_ session: ChatSession) {
        if let index = storedSessions.firstIndex(where: { $0.id == session.id }) {
            storedSessions[index] = session
        } else {
            storedSessions.append(session)
        }
    }

    private func refreshSessionList() {
        sessions = storedSessions
            .map(\.summary)
            .sorted(by: ChatSessionSummary.recencySort)
    }

    private var canReuseCurrentEmptySession: Bool {
        guard let currentSession else {
            return false
        }

        return !currentSession.isAgent
            && currentSession.messages.isEmpty
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingImageAttachments.isEmpty
    }

    private func pruneRedundantEmptySessions() {
        let sortedSessions = storedSessions.sorted(by: ChatSession.recencySort)
        var seenIDs = Set<UUID>()
        var keptSessions: [ChatSession] = []
        var keptEmptySession = false
        var removedSessionIDs: [UUID] = []

        for session in sortedSessions {
            guard seenIDs.insert(session.id).inserted else {
                removedSessionIDs.append(session.id)
                continue
            }

            if session.messages.isEmpty && !session.isAgent {
                if keptEmptySession {
                    removedSessionIDs.append(session.id)
                    continue
                }
                keptEmptySession = true
            }

            keptSessions.append(session)
        }

        storedSessions = keptSessions
        for sessionID in removedSessionIDs {
            sessionStore.deleteSession(id: sessionID)
        }
    }
}

private struct AgentTaskPanel: View {
    let tasks: [AgentTaskSnapshot]
    @State private var isExpanded: Bool = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            taskIcon(for: task.state)
                            Text(task.role)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            Text(task.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            if let elapsed = task.elapsedSeconds {
                                Text("\(elapsed, specifier: "%.1f")s")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !task.detail.isEmpty {
                            Text(task.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(task.state == .completed ? 6 : 3)
                        }
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    )
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.3.sequence.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Prime Subagents (\(completedCount)/\(tasks.count))")
                    .font(.caption.weight(.semibold))
                if hasRunningTasks {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.15), lineWidth: 1)
        )
    }

    private var completedCount: Int {
        tasks.filter { $0.state == .completed }.count
    }

    private var hasRunningTasks: Bool {
        tasks.contains { $0.state == .running }
    }

    @ViewBuilder
    private func taskIcon(for state: AgentTaskState) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

private struct ChatMessageRow: View {
    private static let maximumUserBubbleWidth: CGFloat = 560

    let message: ChatTranscriptMessage
    let bodyFontSize: Double
    let lineHeightMultiplier: Double
    let paragraphLineHeightMultiplier: Double
    @State private var didCopyResponse = false
    @State private var isHoveringMessage = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .contextMenu {
                        if let modelID = message.modelID {
                            Button("Copy Model Name") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(modelID, forType: .string)
                            }
                        }
                    }
            }

            VStack(alignment: contentStackAlignment, spacing: 6) {
                if !message.imageAttachments.isEmpty {
                    ChatImageAttachmentStack(
                        attachments: message.imageAttachments,
                        isUserMessage: message.role == .user
                    )
                }

                if showsThinkingBubble {
                    ChatThinkingBubble(
                        content: message.reasoningContent,
                        isThinking: message.isStreaming && message.content.isEmpty,
                        thinkingDuration: message.thinkingDuration
                    )
                }

                if !message.agentTasks.isEmpty {
                    AgentTaskPanel(tasks: message.agentTasks)
                }

                if showsTextContent {
                    textBubble
                }
            }
            .frame(maxWidth: .infinity, alignment: rowAlignment)

            if let liveResponseMetrics {
                ChatLiveDecodeMetricsBadge(metrics: liveResponseMetrics)
                    .equatable()
            } else if let responseMetrics {
                ChatResponseMetricsRow(metrics: responseMetrics)
            }

            if showsCopyAction {
                HStack(spacing: 8) {
                    ChatCopyResponseButton(
                        didCopy: didCopyResponse,
                        onCopy: copyResponse
                    )

                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .opacity(isHoveringMessage || didCopyResponse ? 1 : 0)
                .accessibilityHidden(!isHoveringMessage && !didCopyResponse)
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
        .contentShape(.rect)
        .onHover { isHoveringMessage = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHoveringMessage)
    }

    @ViewBuilder
    private var textBubble: some View {
        Group {
            if usesCompactBubble {
                ChatMessageText(
                    content: displayContent,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming,
                    paragraphLineHeightMultiplier: paragraphLineHeightMultiplier,
                    bodyFontSize: bodyFontSize
                )
                .lineSpacing(bodyLineSpacing)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                ChatMessageText(
                    content: displayContent,
                    rendersMarkdown: rendersMarkdown,
                    isStreaming: message.isStreaming,
                    paragraphLineHeightMultiplier: paragraphLineHeightMultiplier,
                    bodyFontSize: bodyFontSize
                )
                .lineSpacing(bodyLineSpacing)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: CGFloat(bodyFontSize)))
        .padding(.horizontal, message.role == .assistant ? 0 : 12)
        .padding(.vertical, message.role == .assistant ? 3 : 9)
        .frame(maxWidth: bubbleMaximumWidth, alignment: alignment)
        .foregroundStyle(foregroundStyle)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: message.role == .error ? 1 : 0.5)
        )
    }

    private var title: String {
        switch message.role {
        case .user:
            return ""
        case .assistant:
            return message.modelID ?? "Assistant"
        case .error:
            return "Error"
        }
    }

    private var bodyLineSpacing: CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(bodyFontSize))
        let nativeLineHeight = font.ascender - font.descender + font.leading
        return max(0, nativeLineHeight * CGFloat(lineHeightMultiplier - 1))
    }

    private var rowAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var bubbleMaximumWidth: CGFloat? {
        message.role == .user && !usesCompactBubble ? Self.maximumUserBubbleWidth : nil
    }

    private var alignment: Alignment {
        .leading
    }

    private var textAlignment: TextAlignment {
        .leading
    }

    private var contentStackAlignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var displayContent: String {
        message.content.isEmpty ? " " : message.content
    }

    private var usesCompactBubble: Bool {
        !displayContent.contains(where: \.isNewline)
            && displayContent.count <= 72
    }

    private var showsTextContent: Bool {
        !message.content.isEmpty
            || (!showsThinkingBubble && (message.imageAttachments.isEmpty || message.isStreaming))
    }

    private var showsThinkingBubble: Bool {
        guard message.role == .assistant else {
            return false
        }
        return !message.reasoningContent.isEmpty
            || (message.isThinkingEnabled && message.isStreaming && message.content.isEmpty)
    }

    private var rendersMarkdown: Bool {
        message.role == .assistant
    }

    private var foregroundStyle: Color {
        message.role == .user ? .white : Color(nsColor: .labelColor)
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user:
            return .accentColor
        case .assistant:
            return .clear
        case .error:
            return Color(nsColor: .systemRed).opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            return .clear
        case .assistant:
            return .clear
        case .error:
            return Color(nsColor: .systemRed).opacity(0.45)
        }
    }

    private var responseMetrics: ChatResponseMetrics? {
        guard message.role == .assistant,
              !message.isStreaming,
              let responseMetrics = message.responseMetrics,
              responseMetrics.hasVisibleValues
        else {
            return nil
        }

        return responseMetrics
    }

    private var liveResponseMetrics: ChatResponseMetrics? {
        guard message.role == .assistant,
              message.isStreaming,
              let responseMetrics = message.responseMetrics,
              responseMetrics.generatedTokens.map({ $0 > 0 }) == true
                || responseMetrics.decodeTokensPerSecond.map({
                    $0 > 0 && $0.isFinite
                }) == true
        else {
            return nil
        }

        return responseMetrics
    }

    private var showsCopyAction: Bool {
        message.role == .assistant
            && !message.isStreaming
            && !message.content.isEmpty
    }

    private func copyResponse() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyResponse = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyResponse = false
            }
        }
    }
}

private struct ChatLiveDecodeMetricsBadge: View, Equatable {
    let metrics: ChatResponseMetrics

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)

            Text("Decode")
                .foregroundStyle(.secondary)

            if let generatedTokens = metrics.generatedTokens {
                Text("\(PlayaFormatting.integer(generatedTokens)) tokens")
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            if metrics.generatedTokens != nil,
               metrics.decodeTokensPerSecond != nil {
                Text("·")
                    .foregroundStyle(.tertiary)
            }

            if let decodeTokensPerSecond = metrics.decodeTokensPerSecond {
                Text(PlayaFormatting.rate(decodeTokensPerSecond))
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Decode metrics")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        [
            metrics.generatedTokens.map { "\($0) generated tokens" },
            metrics.decodeTokensPerSecond.map(PlayaFormatting.rate)
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private struct ChatCopyResponseButton: View {
    let didCopy: Bool
    let onCopy: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onCopy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    didCopy
                        ? Color.green
                        : (isHovering ? Color.primary : Color.secondary)
                )
                .frame(width: 30, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(didCopy ? "Copied" : "Copy response")
        .accessibilityLabel(didCopy ? "Response copied" : "Copy response")
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: didCopy)
    }
}

private struct ChatThinkingBubble: View {
    let content: String
    let isThinking: Bool
    let thinkingDuration: TimeInterval?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if isThinking {
                        ChatThinkingShimmerText("Working")
                    } else {
                        Text(completedTitle)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less reasoning" : "Show full reasoning")

            if isExpanded || isThinking {
                Divider()

                Group {
                    if isExpanded {
                        ChatMessageText(
                            content: content,
                            rendersMarkdown: !isThinking,
                            isStreaming: isThinking
                        )
                        .font(.callout)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                    } else {
                        Text(content)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: 58, alignment: .bottomLeading)
                            .clipped()
                            .padding(12)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 0.75)
        }
        .animation(.easeInOut(duration: 0.2), value: isThinking)
        .accessibilityElement(children: .contain)
    }

    private var completedTitle: String {
        guard let thinkingDuration else {
            return "Worked"
        }
        return "Worked for \(PlayaFormatting.elapsedDuration(thinkingDuration))"
    }
}

private struct ChatThinkingShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Group {
            if reduceMotion {
                label
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.animation) { context in
                    let duration = 1.65
                    let progress = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: duration) / duration

                    label
                        .foregroundStyle(Color.primary.opacity(0.38))
                        .overlay {
                            GeometryReader { proxy in
                                let beamWidth = max(34, proxy.size.width * 0.55)

                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color.secondary.opacity(0.25),
                                        Color.primary.opacity(0.75),
                                        .white,
                                        Color.primary.opacity(0.75),
                                        Color.secondary.opacity(0.25),
                                        .clear
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: beamWidth)
                                .offset(
                                    x: -beamWidth
                                        + (proxy.size.width + beamWidth) * progress
                                )
                                .blur(radius: 1.1)
                            }
                            .mask(label)
                            .allowsHitTesting(false)
                        }
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text)
            .font(.callout.weight(.medium))
    }
}

private struct ChatResponseMetricsRow: View {
    let metrics: ChatResponseMetrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                metricPills
            }

            VStack(alignment: .leading, spacing: 6) {
                metricPills
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var metricPills: some View {
        ChatResponseMetricPill(
            label: "Total tokens",
            value: PlayaFormatting.integer(metrics.totalTokens)
        )
        ChatResponseMetricPill(
            label: "Decode tok/s",
            value: PlayaFormatting.rate(metrics.decodeTokensPerSecond)
        )
        ChatResponseMetricPill(
            label: "Peak memory",
            value: metrics.peakMemoryGB.map(PlayaFormatting.gigabytes) ?? "--"
        )
    }
}

private struct ChatResponseMetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)

            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .help("\(label): \(value)")
    }
}

private struct ChatImageAttachmentStack: View {
    let attachments: [ChatImageAttachment]
    let isUserMessage: Bool

    var body: some View {
        VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                ChatImageAttachmentView(attachment: attachment)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUserMessage ? .trailing : .leading)
    }
}

private struct ChatImageAttachmentView: View {
    let attachment: ChatImageAttachment

    @State private var isHovering = false
    @State private var saveError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text(attachment.filename)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(width: 180, height: 120)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 2 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            if image != nil {
                Button(action: saveImage) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .opacity(isHovering ? 1 : 0.72)
                .help("Save Image As…")
                .accessibilityLabel("Save \(attachment.filename)")
            }
        }
        .contentShape(Rectangle())
        .focusable(image != nil)
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(count: 2) {
            openPreview()
        }
        .onTapGesture {
            isFocused = true
            openPreview()
        }
        .onKeyPress(.space) {
            guard image != nil else { return .ignored }
            openPreview()
            return .handled
        }
        .help("Click, double-click, or press Space to preview (attachment.filename) at full size")
        .accessibilityLabel(attachment.filename)
        .accessibilityHint("Click or press Space to preview at full size")
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Preview at Full Size", action: openPreview)
            Button("Save Image As…", action: saveImage)
        }
        .alert(
            "Unable to Save Image",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private var image: NSImage? {
        guard let data = attachment.imageData else {
            return nil
        }
        return NSImage(data: data)
    }

    private func openPreview() {
        guard image != nil else { return }
        ChatImagePreview.open(attachment)
    }

    private func saveImage() {
        guard let data = attachment.imageData else {
            saveError = "The image data is unavailable."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = attachment.filename
        if let contentType = UTType(mimeType: attachment.mimeType) {
            panel.allowedContentTypes = [contentType]
        }
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            saveError = error.localizedDescription
        }
    }
}

@MainActor
private enum ChatImagePreview {
    private static var windows: [UUID: ChatImagePreviewWindowController] = [:]

    static func open(_ attachment: ChatImageAttachment) {
        if let existing = windows[attachment.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let data = attachment.imageData,
              let image = NSImage(data: data) else { return }
        let controller = ChatImagePreviewWindowController(
            attachment: attachment,
            image: image
        ) {
            windows[attachment.id] = nil
        }
        windows[attachment.id] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class ChatImagePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(
        attachment: ChatImageAttachment,
        image: NSImage,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose

        let pixelSize = Self.pixelSize(for: image)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: pixelSize))
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: pixelSize))
        scrollView.documentView = imageView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor

        let visibleFrame = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1_200, height: 800)
        let contentSize = NSSize(
            width: min(pixelSize.width, max(visibleFrame.width - 80, 320)),
            height: min(pixelSize.height, max(visibleFrame.height - 100, 240))
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(attachment.filename) — \(Int(pixelSize.width))×\(Int(pixelSize.height))"
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.setContentSize(contentSize)
        window.contentMinSize = NSSize(width: 320, height: 240)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private static func pixelSize(for image: NSImage) -> NSSize {
        let representation = image.representations.max {
            ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
        }
        guard let representation,
              representation.pixelsWide > 0,
              representation.pixelsHigh > 0 else {
            return NSSize(
                width: max(image.size.width, 1),
                height: max(image.size.height, 1)
            )
        }
        return NSSize(
            width: representation.pixelsWide,
            height: representation.pixelsHigh
        )
    }
}

private struct ChatMessageText: View {
    let content: String
    let rendersMarkdown: Bool
    let isStreaming: Bool
    let paragraphLineHeightMultiplier: Double
    let bodyFontSize: Double

    init(
        content: String,
        rendersMarkdown: Bool,
        isStreaming: Bool,
        paragraphLineHeightMultiplier: Double = PlayaSettings.defaultChatParagraphLineHeightMultiplier,
        bodyFontSize: Double = PlayaSettings.defaultChatBodyFontSize
    ) {
        self.content = content
        self.rendersMarkdown = rendersMarkdown
        self.isStreaming = isStreaming
        self.paragraphLineHeightMultiplier = paragraphLineHeightMultiplier
        self.bodyFontSize = bodyFontSize
    }

    @ViewBuilder
    var body: some View {
        if rendersMarkdown && !isStreaming {
            StructuredText(
                markdown: PlayaMarkdownFormatting.normalizedMathDelimiters(in: content),
                syntaxExtensions: [.math]
            )
            .textual.paragraphStyle(
                ChatParagraphStyle(lineHeightMultiplier: paragraphLineHeightMultiplier)
            )
            .textual.thematicBreakStyle(ChatNoteThematicBreakStyle())
            .textual.headingStyle(ChatHeadingStyle(bodyFontSize: bodyFontSize))
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
        } else {
            renderedText
                .textSelection(.enabled)
        }
    }

    private var renderedText: Text {
        guard rendersMarkdown,
              let attributed = try? AttributedString(
                markdown: content,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              )
        else {
            return Text(content)
        }

        return Text(attributed)
    }
}

private struct ChatNoteThematicBreakStyle: StructuredText.ThematicBreakStyle {
    func makeBody(configuration _: Configuration) -> some View {
        ChatNoteWaveShape()
            .stroke(Color(nsColor: .systemYellow).opacity(0.14), lineWidth: 5)
            .overlay {
                ChatNoteWaveShape()
                    .stroke(
                        Color(nsColor: .separatorColor).opacity(0.55),
                        style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round)
                    )
            }
            .frame(height: 7)
            .textual.blockSpacing(.init(top: 12, bottom: 12))
            .accessibilityHidden(true)
    }
}

private struct ChatNoteWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let amplitude = min(1.5, rect.height * 0.3)
        let wavelength: CGFloat = 14

        path.move(to: CGPoint(x: rect.minX, y: midY))
        for x in stride(from: rect.minX + 1, through: rect.maxX, by: 1) {
            let phase = (x - rect.minX) / wavelength * 2 * .pi
            path.addLine(to: CGPoint(x: x, y: midY + sin(phase) * amplitude))
        }
        return path
    }
}

private struct ChatHeadingStyle: StructuredText.HeadingStyle {
    private static let gitHubFontScales: [CGFloat] = [2, 1.5, 1.25, 1, 0.875, 0.85]

    let bodyFontSize: Double

    func makeBody(configuration: Configuration) -> some View {
        let headingLevel = min(max(configuration.headingLevel, 1), 6)
        let baseScale = Self.gitHubFontScales[headingLevel - 1]
        let onePointScale = 1 / CGFloat(max(bodyFontSize, 1))

        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .textual.fontScale(max(0.8, baseScale - onePointScale))
                .textual.lineSpacing(.fontScaled(0.125))
                .textual.blockSpacing(.init(top: 24, bottom: 16))
                .fontWeight(.semibold)

            if headingLevel <= 2 {
                Divider()
                    .overlay(Color(nsColor: .separatorColor).opacity(0.55))
            }
        }
    }
}

private struct ChatParagraphStyle: StructuredText.ParagraphStyle {
    let lineHeightMultiplier: Double

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(
                .fontScaled(CGFloat(max(0, lineHeightMultiplier - 1)))
            )
            .textual.blockSpacing(.fontScaled(bottom: 1))
    }
}

private struct ChatEmptyTranscriptView: View {
    let serverState: PlayaServerState
    let selectedModelID: String?

    var body: some View {
        VStack(spacing: 7) {
            if case .starting = serverState {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch serverState {
        case .stopped:
            return "Server is stopped"
        case .starting:
            return "Server is starting..."
        case .error:
            return "Server error"
        case .running where selectedModelID == nil:
            return "No model selected"
        case .running:
            return "No messages"
        }
    }

    private var detail: String? {
        switch serverState {
        case .stopped:
            return "Select a model and start the server to chat."
        case .starting:
            return selectedModelID ?? "Waiting for model to load..."
        case .error(let msg):
            return msg
        case .running where selectedModelID == nil:
            return "Choose a model in Models."
        case .running:
            return selectedModelID
        }
    }
}

#Preview {
    ChatView(model: .init(), chat: ChatViewModel(), showsConfiguration: .constant(true))
}
