import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageGenerationView: View {
    @ObservedObject var model: PlayaModel
    @ObservedObject var viewModel: ImageGenerationViewModel
    @StateObject private var modelLibrary = LocalModelLibrary()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ImageGenerationPromptSection(
                    prompt: $viewModel.prompt,
                    isDisabled: viewModel.isGenerating
                )

                HStack(alignment: .top, spacing: 16) {
                    ImageGenerationSection(title: "Request") {
                        ImageGenerationModelRow(
                            modelID: $viewModel.modelID,
                            configuredModelID: model.settings.normalized().imageGenerationModelID,
                            library: modelLibrary,
                            onRefresh: {
                                modelLibrary.scan(path: model.settings.modelSearchPath)
                            }
                        )

                        Divider()

                        ImageGenerationControls(viewModel: viewModel)
                    }
                    .frame(minWidth: 380)

                    ImageGenerationReferencePanel(viewModel: viewModel)
                        .frame(minWidth: 260)
                }

                ImageGenerationActionBar(
                    viewModel: viewModel,
                    unavailableReason: viewModel.unavailableReason(isRunning: model.isRunning),
                    onRun: {
                        viewModel.run(using: model)
                    }
                )

                ImageGenerationResultsSection(viewModel: viewModel)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: modelSearchScanPath) {
            modelLibrary.scan(path: model.settings.modelSearchPath)
        }
        .onAppear {
            viewModel.applyDefaultModel(model.settings.normalized().imageGenerationModelID)
        }
        .onDisappear {
            modelLibrary.cancel()
        }
    }

    private var modelSearchScanPath: String {
        model.settings.normalized().expandedModelSearchPath
    }
}

private struct ImageGenerationPromptSection: View {
    @Binding var prompt: String
    let isDisabled: Bool
    private let textInset = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)

    var body: some View {
        ImageGenerationSection(title: "Prompt") {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )

                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(textInset)
                    .disabled(isDisabled)

                if prompt.isEmpty {
                    Text("Describe the image to generate or how to edit the reference image.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(textInset)
                        .offset(x: 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 112)
            .padding(12)
        }
    }
}

private struct ImageGenerationModelRow: View {
    @Binding var modelID: String
    let configuredModelID: String?
    @ObservedObject var library: LocalModelLibrary
    let onRefresh: () -> Void

    var body: some View {
        ImageGenerationRow(label: "Model") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Image model or local path", text: $modelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Menu {
                        if let configuredModelID {
                            Button("Use configured image model") {
                                modelID = configuredModelID
                            }
                            Divider()
                        }

                        Button("Refresh local models") {
                            onRefresh()
                        }

                        Divider()

                        if library.models.isEmpty {
                            Text(library.isScanning ? "Scanning..." : "No local models found")
                        } else {
                            ForEach(library.models) { model in
                                Button(model.repoID) {
                                    modelID = model.repoID
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .help("Choose local model")

                    if library.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text(modelStatus)
                    .font(.caption)
                    .foregroundStyle(library.error == nil ? Color(nsColor: .secondaryLabelColor) : Color.orange)
                    .lineLimit(2)
            }
        }
    }

    private var modelStatus: String {
        if let error = library.error {
            return error
        }
        if library.isScanning {
            return "Scanning local Hugging Face cache..."
        }
        if library.models.isEmpty {
            return "Enter an image generation/edit model ID or local path."
        }
        return "\(library.models.count) local \(library.models.count == 1 ? "model" : "models") available."
    }
}

private struct ImageGenerationControls: View {
    @ObservedObject var viewModel: ImageGenerationViewModel

    var body: some View {
        VStack(spacing: 0) {
            ImageGenerationRow(label: "Size") {
                HStack(spacing: 8) {
                    TextField("", value: $viewModel.width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 78)

                    Text("x")
                        .foregroundStyle(.secondary)

                    TextField("", value: $viewModel.height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 78)

                    Menu {
                        ForEach(ImageGenerationSizeOptions.longestSides, id: \.self) { longestSide in
                            Button {
                                viewModel.applyLongestSide(longestSide)
                            } label: {
                                if viewModel.currentLongestSide == longestSide {
                                    Label("\(longestSide) px", systemImage: "checkmark")
                                } else {
                                    Text("\(longestSide) px")
                                }
                            }
                        }
                    } label: {
                        Label("\(viewModel.currentLongestSide) px", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .help("Set longest side")

                    Spacer(minLength: 0)
                }
            }

            Divider()

            ImageGenerationRow(label: "Images") {
                Spacer(minLength: 0)

                TextField("", value: $viewModel.count, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64)

                Stepper("", value: $viewModel.count, in: 1...10)
                    .labelsHidden()
            }

            Divider()

            ImageGenerationRow(label: "Steps") {
                Spacer(minLength: 0)

                TextField("", value: $viewModel.steps, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 78)

                Stepper("", value: $viewModel.steps, in: 1...1_000)
                    .labelsHidden()
            }

            Divider()

            ImageGenerationRow(label: "Guidance") {
                Slider(value: $viewModel.guidance, in: 0...20, step: 0.1)
                    .frame(minWidth: 140)

                TextField("", value: $viewModel.guidance, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 72)
            }

            Divider()

            ImageGenerationRow(label: "Seed") {
                TextField("Random", text: $viewModel.seedText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 140)

                Spacer(minLength: 0)
            }
        }
    }
}

private struct ImageGenerationReferencePanel: View {
    @ObservedObject var viewModel: ImageGenerationViewModel
    @State private var isDropTargeted = false

    var body: some View {
        ImageGenerationSection(title: "Reference Image") {
            VStack(alignment: .leading, spacing: 12) {
                if let referenceImage = viewModel.referenceImage {
                    if let nsImage = referenceImage.nsImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 260)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    Text(referenceImage.filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Button {
                            viewModel.chooseReferenceImage()
                        } label: {
                            Label("Replace", systemImage: "photo")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isGenerating)

                        Button {
                            viewModel.removeReferenceImage()
                        } label: {
                            Label("Remove", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isGenerating)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)

                        Text("Drop or choose a reference image")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button {
                            viewModel.chooseReferenceImage()
                        } label: {
                            Label("Choose Image", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isGenerating)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                    )
                }
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .onDrop(
                of: ImageGenerationDrag.supportedDropTypeIdentifiers,
                isTargeted: $isDropTargeted
            ) { providers in
                viewModel.loadReferenceImage(from: providers)
            }
            .help("Drop an image here to use it as the reference")
        }
    }
}

private struct ImageGenerationActionBar: View {
    @ObservedObject var viewModel: ImageGenerationViewModel
    let unavailableReason: String?
    let onRun: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let statusText = viewModel.statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                viewModel.cancel()
            } label: {
                Image(systemName: "stop.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.isGenerating)
            .help("Stop")

            Button {
                viewModel.clearResults()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isGenerating || viewModel.results.isEmpty)
            .help("Clear results")

            Button(action: onRun) {
                Label(viewModel.referenceImage == nil ? "Generate" : "Edit", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(unavailableReason != nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

private struct ImageGenerationResultsSection: View {
    @ObservedObject var viewModel: ImageGenerationViewModel
    @State private var selectedResultID: GeneratedImage.ID?
    @FocusState private var resultsAreFocused: Bool

    var body: some View {
        ImageGenerationSection(title: "Results") {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.statusText ?? "Working...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText = viewModel.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if viewModel.results.isEmpty && !viewModel.isGenerating && viewModel.errorText == nil {
                    ContentUnavailableView(
                        "No Images",
                        systemImage: "photo.on.rectangle",
                        description: Text("Generated images will appear here.")
                    )
                    .frame(minHeight: 220)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(viewModel.results) { result in
                            GeneratedImageCard(
                                result: result,
                                isSelected: selectedResultID == result.id,
                                onSelect: {
                                    selectedResultID = result.id
                                    resultsAreFocused = true
                                },
                                onSave: {
                                    viewModel.save(result)
                                }
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .focusable()
            .focused($resultsAreFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard let selectedResult else { return .ignored }
                GeneratedImagePreview.open(selectedResult)
                return .handled
            }
            .onChange(of: viewModel.results) { _, results in
                if let selectedResultID,
                   !results.contains(where: { $0.id == selectedResultID }) {
                    self.selectedResultID = nil
                }
            }
        }
    }

    private var selectedResult: GeneratedImage? {
        guard let selectedResultID else { return nil }
        return viewModel.results.first(where: { $0.id == selectedResultID })
    }
}

private struct GeneratedImageCard: View {
    let result: GeneratedImage
    let isSelected: Bool
    let onSelect: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let nsImage = result.nsImage {
                Button {
                    onSelect()
                    GeneratedImagePreview.open(result)
                } label: {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(nsImage.size, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .onDrag {
                    ImageGenerationDrag.itemProvider(for: result)
                }
                .help("Click to preview at actual size, or drag to use as a reference")
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(result.width)x\(result.height)")
                        .font(.caption.weight(.semibold))
                    Text("Seed \(result.seed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onSave) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.bordered)
                .help("Save image")
            }

            if let revisedPrompt = result.revisedPrompt,
               !revisedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(revisedPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
    }
}

@MainActor
private enum GeneratedImagePreview {
    private static var windows: [UUID: GeneratedImagePreviewWindowController] = [:]

    static func open(_ result: GeneratedImage) {
        if let existing = windows[result.id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let image = result.nsImage else { return }
        let controller = GeneratedImagePreviewWindowController(
            result: result,
            image: image
        ) {
            windows[result.id] = nil
        }
        windows[result.id] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
private final class GeneratedImagePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(result: GeneratedImage, image: NSImage, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let imageSize = NSSize(
            width: max(CGFloat(result.width), 1),
            height: max(CGFloat(result.height), 1)
        )
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: imageSize))
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: imageSize))
        scrollView.documentView = imageView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor

        let visibleFrame = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1_200, height: 800)
        let contentSize = NSSize(
            width: min(imageSize.width, max(visibleFrame.width - 80, 320)),
            height: min(imageSize.height, max(visibleFrame.height - 100, 240))
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(result.filename) — \(result.width)×\(result.height)"
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
}

private enum ImageGenerationDrag {
    static let supportedDropTypeIdentifiers = [
        UTType.fileURL,
        .png,
        .jpeg,
        .tiff,
        .gif,
        .image
    ].map(\.identifier)

    static func itemProvider(for result: GeneratedImage) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = result.filename
        provider.registerDataRepresentation(
            forTypeIdentifier: result.imageType.identifier,
            visibility: .all
        ) { completion in
            completion(result.imageData, nil)
            return nil
        }
        return provider
    }
}

private struct ImageGenerationSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
    }
}

private struct ImageGenerationRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)

            content
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

#Preview {
    ImageGenerationView(model: .init(), viewModel: ImageGenerationViewModel())
}
