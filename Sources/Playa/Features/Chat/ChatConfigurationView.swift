import AppKit
import Darwin
import Foundation
import PlayaServerKit
import SwiftUI

struct ModelConfigurationLayout<Content: View>: View {
    @ObservedObject var model: PlayaModel
    @Binding var isConfigurationVisible: Bool
    private let content: Content

    init(
        model: PlayaModel,
        isConfigurationVisible: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        _isConfigurationVisible = isConfigurationVisible
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

            if isConfigurationVisible {
                Divider()

                ModelConfigurationView(
                    model: model,
                    settings: $model.settings,
                    settingsRequireRestart: model.settingsRequireRestart,
                    onReset: model.resetSettings
                )
                .frame(width: 320)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isConfigurationVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(configurationVisibilityHelp)
                .accessibilityLabel(configurationVisibilityHelp)
            }
        }
    }

    private var configurationVisibilityHelp: String {
        isConfigurationVisible ? "Hide model configuration" : "Show model configuration"
    }
}

struct ModelConfigurationView: View {
    @ObservedObject var model: PlayaModel
    @Binding var settings: PlayaSettings
    let settingsRequireRestart: Bool
    let onReset: () -> Void
    @State private var modelConfiguration: LocalModelConfigurationMetadata?
    @State private var isLoadingModelConfiguration = false
    @State private var modelConfigurationRevision = 0
    @State private var copiedConnectionValue: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    connectionSection
                    modelContextSection
                    textDisplaySection
                    kvQuantizationSection
                    thinkingSection
                    samplingSection
                    speculativeDecodingSection
                    structuredOutputSection
                    prefixCachingSection
                    serverLogSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        .task(id: modelConfigurationLookupID) {
            await loadModelConfiguration(for: modelConfigurationLookupID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localModelLibraryDidChange)) { _ in
            modelConfigurationRevision += 1
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label("Model Configuration", systemImage: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 0)

                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset model configuration")
            }

            if settingsRequireRestart {
                Label("Server restart required", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text("Request settings apply to the next message.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modelContextSection: some View {
        ChatConfigurationSection(title: "Model Context") {
            ConfigurationIntegerField(
                title: "Max output",
                value: $settings.maxTokens,
                range: 1...262_144
            )

            ConfigurationIntegerField(
                title: "Context window",
                value: modelContextBinding,
                range: 0...1_048_576
            )
            .disabled(isLoadingModelConfiguration)

            VStack(alignment: .leading, spacing: 5) {
                Text("System prompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if settings.systemPrompt.isEmpty {
                        Text(systemPromptPlaceholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $settings.systemPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                }
                .frame(minHeight: 72)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }

                Text(systemPromptHint)
                    .configurationHintStyle()
            }
        }
    }

    private var connectionSection: some View {
        ChatConfigurationSection(title: "Connections") {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.serverState == .running ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)

                Text("OpenAI-compatible API")
                    .font(.subheadline.weight(.medium))

                Spacer(minLength: 8)

                Text(model.serverState == .running ? "Ready" : "Offline")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.serverState == .running ? Color.green : Color.secondary)
            }

            ConnectionValueRow(
                title: "Local",
                displayValue: openAIBaseURL,
                copied: copiedConnectionValue == openAIBaseURL,
                onCopy: { copyConnectionValue(openAIBaseURL) }
            )

            if let tailscaleBaseURL {
                ConnectionValueRow(
                    title: "Tailscale",
                    displayValue: tailscaleBaseURL,
                    copied: copiedConnectionValue == tailscaleBaseURL,
                    onCopy: { copyConnectionValue(tailscaleBaseURL) }
                )
            }

            if let machineBaseURL {
                ConnectionValueRow(
                    title: "Machine name",
                    displayValue: machineBaseURL,
                    copied: copiedConnectionValue == machineBaseURL,
                    onCopy: { copyConnectionValue(machineBaseURL) }
                )
            }

            if let loadedModelID {
                ConnectionValueRow(
                    title: "Model ID",
                    displayValue: loadedModelID,
                    copied: copiedConnectionValue == loadedModelID,
                    onCopy: { copyConnectionValue(loadedModelID) }
                )
            }

            if let apiKey = normalizedServerAPIKey {
                ConnectionValueRow(
                    title: "API Key",
                    displayValue: String(repeating: "•", count: 12),
                    copied: copiedConnectionValue == apiKey,
                    onCopy: { copyConnectionValue(apiKey) }
                )
            } else {
                ConnectionValueRow(
                    title: "API Key",
                    displayValue: "Not required",
                    copied: false,
                    onCopy: nil
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Label("Open WebUI", systemImage: "network")
                    .font(.footnote.weight(.semibold))

                Text("The server listens on all network interfaces. Use Local on this Mac, or Tailscale / Machine name from another permitted device.")
                    .configurationHintStyle()
            }
        }
    }

    private var openAIBaseURL: String {
        IntegrationProfileManager.openAIBaseURL
    }

    private var tailscaleBaseURL: String? {
        PlayaNetworkEndpoints.tailscaleIPv4.map { "http://\($0):8080/v1" }
    }

    private var machineBaseURL: String? {
        PlayaNetworkEndpoints.machineName.map { "http://\($0):8080/v1" }
    }

    private var loadedModelID: String? {
        model.loadedServerModelID ?? model.metrics?.server.loadedModel
    }

    private var normalizedServerAPIKey: String? {
        let key = settings.serverAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    private func copyConnectionValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) {
            copiedConnectionValue = value
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard copiedConnectionValue == value else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                copiedConnectionValue = nil
            }
        }
    }

    private var textDisplaySection: some View {
        ChatConfigurationSection(title: "Text Display") {
            ConfigurationSlider(
                title: "Text size",
                value: $settings.chatBodyFontSize,
                range: 11...24,
                step: 1,
                formattedValue: "\(Int(settings.chatBodyFontSize.rounded())) pt"
            )

            ConfigurationSlider(
                title: "Line height",
                value: $settings.chatLineHeightMultiplier,
                range: 1...2,
                step: 0.05,
                formattedValue: String(format: "%.2f×", settings.chatLineHeightMultiplier)
            )

            ConfigurationSlider(
                title: "Paragraph line height",
                value: $settings.chatParagraphLineHeightMultiplier,
                range: 1.2...2,
                step: 0.05,
                formattedValue: String(format: "%.2f×", settings.chatParagraphLineHeightMultiplier)
            )

            Text("Changes apply instantly to conversation text.")
                .configurationHintStyle()
        }
    }

    private var modelConfigurationLookupID: String {
        let normalizedSettings = settings.normalized()
        return [
            normalizedSettings.modelSearchPath,
            normalizedSettings.languageModelID ?? "",
            String(modelConfigurationRevision)
        ].joined(separator: "\u{0}")
    }

    private func loadModelConfiguration(for lookupID: String) async {
        modelConfiguration = nil
        guard let modelID = settings.normalized().languageModelID else {
            isLoadingModelConfiguration = false
            return
        }

        isLoadingModelConfiguration = true
        let metadata = await LocalModelDiscovery.configurationMetadata(
            repoID: modelID,
            path: settings.modelSearchPath
        )
        guard lookupID == modelConfigurationLookupID else {
            return
        }
        modelConfiguration = metadata
        isLoadingModelConfiguration = false
    }

    private var modelContextBinding: Binding<Int> {
        Binding(
            get: {
                settings.maxKVSize > 0
                    ? settings.maxKVSize
                    : (modelConfiguration?.contextSize ?? 0)
            },
            set: { value in
                if value == modelConfiguration?.contextSize {
                    settings.maxKVSize = 0
                } else {
                    settings.maxKVSize = value
                }
            }
        )
    }

    private var systemPromptPlaceholder: String {
        if isLoadingModelConfiguration {
            return "Reading chat template…"
        }
        return modelConfiguration?.defaultSystemPrompt ?? "Optional custom system prompt"
    }

    private var systemPromptHint: String {
        if isLoadingModelConfiguration {
            return "Looking for a default system prompt in the chat template."
        }
        if modelConfiguration?.defaultSystemPrompt != nil {
            return settings.systemPrompt.isEmpty
                ? "Template default shown above. Enter text to override it."
                : "Custom prompt overrides the model's chat-template default."
        }
        return "No default system prompt was found in the chat template."
    }

    private var kvQuantizationSection: some View {
        ChatConfigurationSection(title: "KV Quantization") {
            Toggle("Quantize KV cache", isOn: $settings.kvQuantizationEnabled)
                .configurationToggleStyle()

            if settings.kvQuantizationEnabled {
                Toggle("TurboQuant", isOn: turboQuantBinding)
                    .configurationToggleStyle()

                ConfigurationDoubleField(
                    title: "KV bits",
                    value: $settings.kvBits,
                    range: 2...16
                )

                if !settings.turboQuantEnabled {
                    ConfigurationIntegerField(
                        title: "Group size",
                        value: $settings.kvGroupSize,
                        range: 1...1024
                    )
                }

                ConfigurationIntegerField(
                    title: "Quantize after",
                    value: $settings.quantizedKVStart,
                    range: 0...1_048_576
                )

                Text("Changes to the KV cache require a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var thinkingSection: some View {
        ChatConfigurationSection(title: "Thinking") {
            Toggle("Enable Thinking", isOn: $settings.thinkingEnabled)
                .configurationToggleStyle()

            if settings.thinkingEnabled {
                Toggle("Limit thinking", isOn: $settings.thinkingBudgetEnabled)
                    .configurationToggleStyle()

                if settings.thinkingBudgetEnabled {
                    ConfigurationIntegerField(
                        title: "Budget",
                        value: $settings.thinkingBudget,
                        range: 1...262_144
                    )
                }
                ConfigurationTextField(title: "Start token", text: $settings.thinkingStartToken)
                ConfigurationTextField(title: "EOS token", text: $settings.thinkingEndToken)
            }
        }
    }

    private var samplingSection: some View {
        ChatConfigurationSection(title: "Sampling") {
            ConfigurationDoubleField(
                title: "Temperature",
                value: $settings.temperature,
                range: 0...2
            )
            ConfigurationIntegerField(
                title: "Top K",
                value: $settings.topK,
                range: 0...10_000
            )
            ConfigurationDoubleField(
                title: "Top P",
                value: $settings.topP,
                range: 0...1
            )
            ConfigurationDoubleField(
                title: "Min P",
                value: $settings.minP,
                range: 0...1
            )

            Toggle("Repetition penalty", isOn: $settings.repetitionPenaltyEnabled)
                .configurationToggleStyle()

            if settings.repetitionPenaltyEnabled {
                ConfigurationDoubleField(
                    title: "Penalty",
                    value: $settings.repetitionPenalty,
                    range: 0...4
                )
            }
        }
    }

    private var speculativeDecodingSection: some View {
        ChatConfigurationSection(title: "Speculative Decoding") {
            Toggle("Enable drafter", isOn: speculativeDecodingBinding)
                .configurationToggleStyle()

            if settings.speculativeDecodingEnabled {
                ConfigurationTextField(title: "Draft model", text: $settings.draftModelID)

                HStack(spacing: 8) {
                    Text("Family")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.draftKind) {
                        Text("Auto").tag("auto")
                        Text("DFlash").tag("dflash")
                        Text("EAGLE3").tag("eagle3")
                        Text("MTP").tag("mtp")
                    }
                    .labelsHidden()
                    .frame(width: 112)
                }
                .font(.body)

                ConfigurationIntegerField(
                    title: "Block size",
                    value: $settings.draftBlockSize,
                    range: 0...1024
                )

                Text(settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Enter a drafter model to activate speculative decoding."
                    : "The drafter is loaded after the next server restart.")
                    .configurationHintStyle(
                        isError: settings.draftModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
    }

    private var structuredOutputSection: some View {
        ChatConfigurationSection(title: "Structured Output") {
            Toggle("Enforce JSON schema", isOn: structuredOutputBinding)
                .configurationToggleStyle()

            if settings.structuredOutputEnabled {
                ConfigurationTextField(title: "Schema name", text: $settings.structuredOutputName)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("JSON schema")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 0)

                        Button("Reset") {
                            settings.structuredOutputSchema = PlayaSettings.defaultStructuredOutputSchema
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                    }

                    TextEditor(text: $settings.structuredOutputSchema)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 128)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    settings.structuredOutputValidationError == nil
                                        ? Color(nsColor: .separatorColor)
                                        : Color.red.opacity(0.7),
                                    lineWidth: 0.5
                                )
                        }
                }

                if let error = settings.structuredOutputValidationError {
                    Text(error)
                        .configurationHintStyle(isError: true)
                }
            }
        }
    }

    private var prefixCachingSection: some View {
        ChatConfigurationSection(title: "Prefix Caching") {
            Toggle("Enable automatic caching", isOn: $settings.prefixCachingEnabled)
                .configurationToggleStyle()

            if settings.prefixCachingEnabled {
                ConfigurationIntegerField(
                    title: "Cache blocks",
                    value: $settings.prefixCacheBlocks,
                    range: 1...1_048_576
                )
                ConfigurationIntegerField(
                    title: "Tokens per block",
                    value: $settings.prefixCacheBlockSize,
                    range: 1...4096
                )
                Text("Shared prompt prefixes are reused after a server restart.")
                    .configurationHintStyle()
            }
        }
    }

    private var serverLogSection: some View {
        ChatConfigurationSection(title: "Server Log") {
            HStack(spacing: 6) {
                Circle()
                    .fill(serverLogDotColor)
                    .frame(width: 7, height: 7)
                Text(serverLogStatusText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(serverLogDotColor)
                Spacer()
                if model.isRunning || model.serverState == .starting {
                    Button {
                        model.stopServer()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Stop server")
                } else if case .error = model.serverState {
                    Button {
                        model.forceKillServer()
                        model.startSelectedModel()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .help("Force kill and restart")
                }
            }

            if case .error(let msg) = model.serverState {
                let analysis = ServerErrorAnalyzer.analyze(logText: model.logText, errorMessage: msg)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: analysis.category.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(analysis.summary)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(analysis.suggestions.prefix(3).enumerated()), id: \.offset) { _, suggestion in
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
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
                )
            }

            let recentLines = ServerErrorAnalyzer.recentLogLines(from: model.logText, maxLines: 20)
            if !recentLines.isEmpty {
                ScrollView {
                    ScrollViewReader { proxy in
                        Text(recentLines)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("logBottom")
                            .onChange(of: model.logText) { _, _ in
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                    }
                }
                .frame(height: 120)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            } else {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundStyle(.tertiary)
                    Text("No server output yet.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }
    }

    private var serverLogDotColor: Color {
        switch model.serverState {
        case .running: return .green
        case .starting: return .yellow
        case .error: return .orange
        case .stopped: return .secondary.opacity(0.4)
        }
    }

    private var serverLogStatusText: String {
        switch model.serverState {
        case .running: return "Running"
        case .starting: return "Starting..."
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    private var turboQuantBinding: Binding<Bool> {
        Binding(
            get: { settings.turboQuantEnabled },
            set: { enabled in
                settings.turboQuantEnabled = enabled
                if enabled, settings.kvBits == 8 {
                    settings.kvBits = 3.5
                } else if !enabled, settings.kvBits == 3.5 {
                    settings.kvBits = 8
                }
            }
        )
    }

    private var speculativeDecodingBinding: Binding<Bool> {
        Binding(
            get: { settings.speculativeDecodingEnabled },
            set: { enabled in
                settings.speculativeDecodingEnabled = enabled
                if enabled {
                    settings.structuredOutputEnabled = false
                }
            }
        )
    }

    private var structuredOutputBinding: Binding<Bool> {
        Binding(
            get: { settings.structuredOutputEnabled },
            set: { enabled in
                settings.structuredOutputEnabled = enabled
                if enabled {
                    settings.speculativeDecodingEnabled = false
                }
            }
        )
    }
}

private struct ChatConfigurationSection<Content: View>: View {
    let title: String
    private let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct ConfigurationIntegerField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField("", value: $value, format: .number)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .onChange(of: value) { _, newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }
        }
    }
}

private struct ConnectionValueRow: View {
    let title: String
    let displayValue: String
    let copied: Bool
    let onCopy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 8) {
                Text(displayValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let onCopy {
                    Button(action: onCopy) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(copied ? "Copied" : "Copy \(title)")
                    .accessibilityLabel(copied ? "Copied \(title)" : "Copy \(title)")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

private struct ConfigurationDoubleField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            TextField(
                "",
                value: $value,
                format: .number.precision(.fractionLength(0...3))
            )
            .font(.subheadline)
            .multilineTextAlignment(.trailing)
            .frame(width: 88)
            .onChange(of: value) { _, newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        }
    }
}

private struct ConfigurationSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(formattedValue)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(formattedValue)
        }
        .font(.subheadline)
        .controlSize(.small)
    }
}

private struct ConfigurationTextField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.subheadline)
        }
    }
}

private enum PlayaNetworkEndpoints {
    static var machineName: String? {
        let hostname = ProcessInfo.processInfo.hostName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let shortName = hostname.split(separator: ".").first,
              !shortName.isEmpty
        else {
            return nil
        }
        return String(shortName)
    }

    static var tailscaleIPv4: String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = interface {
            defer { interface = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ipAddress = String(cString: buffer)
            let octets = ipAddress.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4,
               octets[0] == 100,
               (64...127).contains(octets[1])
            {
                return ipAddress
            }
        }
        return nil
    }
}

private extension View {
    func configurationToggleStyle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .font(.subheadline)
    }

    func configurationHintStyle(isError: Bool = false) -> some View {
        font(.footnote)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
