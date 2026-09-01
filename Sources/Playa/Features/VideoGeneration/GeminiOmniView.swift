import AVKit
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum GeminiOmniResolution: String, CaseIterable, Identifiable {
    case draft = "360p"
    case standard = "720p"
    case fullHD = "1080p"
    case ultraHD = "4k"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .draft: "360p · Draft"
        case .standard: "720p"
        case .fullHD: "1080p · Upscaled"
        case .ultraHD: "4K · Upscaled"
        }
    }
}

private enum GeminiOmniAspectRatio: String, CaseIterable, Identifiable {
    case landscape = "16:9"
    case portrait = "9:16"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .landscape: "Landscape · 16:9"
        case .portrait: "Portrait · 9:16"
        }
    }
}

@MainActor
final class GeminiOmniViewModel: ObservableObject {
    @Published var apiKey: String
    @Published var prompt = "Continuous, unbroken cinematic shot of Hong Kong harbour at blue hour. A traditional junk boat crosses the frame as city lights reflect on the water. Gentle ambient harbour sound, no dialogue."
    @Published fileprivate var resolution = GeminiOmniResolution.draft
    @Published fileprivate var aspectRatio = GeminiOmniAspectRatio.landscape
    @Published private(set) var isGenerating = false
    @Published private(set) var statusText: String?
    @Published private(set) var errorText: String?
    @Published private(set) var outputURL: URL?
    @Published private(set) var interactionID: String?
    @Published private(set) var player: AVPlayer?

    private var generationTask: Task<Void, Never>?

    init() {
        apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }

    deinit {
        generationTask?.cancel()
    }

    var unavailableReason: String? {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a Gemini API key."
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a video prompt."
        }
        if isGenerating {
            return "Generation in progress."
        }
        return nil
    }

    func generate() {
        guard !isGenerating else { return }

        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, !normalizedPrompt.isEmpty else { return }

        generationTask?.cancel()
        isGenerating = true
        errorText = nil
        statusText = "Submitting a request to Gemini Omni…"

        let request = GeminiOmniRequest(
            apiKey: normalizedKey,
            prompt: normalizedPrompt,
            resolution: resolution.rawValue,
            aspectRatio: aspectRatio.rawValue
        )

        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let result = try await GeminiOmniClient().generate(request) { [weak self] update in
                    Task { @MainActor in
                        self?.statusText = update
                    }
                }
                try Task.checkCancellation()

                if let previousURL = outputURL {
                    player?.pause()
                    try? FileManager.default.removeItem(at: previousURL)
                }

                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Playa-Gemini-Omni-\(UUID().uuidString)")
                    .appendingPathExtension("mp4")
                try result.videoData.write(to: temporaryURL, options: .atomic)

                outputURL = temporaryURL
                interactionID = result.interactionID
                player = AVPlayer(url: temporaryURL)
                statusText = "Video ready · \(ByteCountFormatter.string(fromByteCount: Int64(result.videoData.count), countStyle: .file))"
            } catch is CancellationError {
                statusText = "Generation cancelled."
            } catch {
                errorText = error.localizedDescription
                statusText = nil
            }

            isGenerating = false
            generationTask = nil
        }
    }

    func cancel() {
        generationTask?.cancel()
    }

    func saveVideo() {
        guard let outputURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "gemini-omni-video.mp4"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let data = try Data(contentsOf: outputURL)
            try data.write(to: destination, options: .atomic)
            statusText = "Saved \(destination.lastPathComponent)."
            errorText = nil
        } catch {
            errorText = "Could not save the video: \(error.localizedDescription)"
        }
    }
}

struct GeminiOmniView: View {
    @StateObject private var viewModel = GeminiOmniViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader
                credentialsPanel
                promptPanel
                requestPanel
                outputPanel
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            viewModel.player?.pause()
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gemini Omni Video Lab")
                    .font(.title2.weight(.semibold))
                Text("Experimental text-to-video generation through Google's Gemini Interactions API.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("gemini-omni-1.1-flash")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }
    }

    private var credentialsPanel: some View {
        panel(title: "API access", systemImage: "key.horizontal") {
            SecureField("Gemini API key", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isGenerating)

            HStack {
                Text("The key is sent only to generativelanguage.googleapis.com and is not saved by Playa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Get API key") {
                    NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/app/apikey")!)
                }
                .buttonStyle(.link)
            }
        }
    }

    private var promptPanel: some View {
        panel(title: "Prompt", systemImage: "text.alignleft") {
            TextEditor(text: $viewModel.prompt)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 130)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .disabled(viewModel.isGenerating)

            Text("English prompts are fully supported. Describe the scene, camera movement, lighting, timing, and audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var requestPanel: some View {
        panel(title: "Request", systemImage: "slider.horizontal.3") {
            HStack(spacing: 14) {
                Picker("Resolution", selection: $viewModel.resolution) {
                    ForEach(GeminiOmniResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .frame(width: 190)
                .disabled(viewModel.isGenerating)

                Picker("Aspect ratio", selection: $viewModel.aspectRatio) {
                    ForEach(GeminiOmniAspectRatio.allCases) { aspectRatio in
                        Text(aspectRatio.title).tag(aspectRatio)
                    }
                }
                .frame(width: 200)
                .disabled(viewModel.isGenerating)

                Spacer()

                if viewModel.isGenerating {
                    Button("Cancel", role: .cancel) {
                        viewModel.cancel()
                    }
                }

                Button {
                    viewModel.generate()
                } label: {
                    if viewModel.isGenerating {
                        Label("Generating…", systemImage: "hourglass")
                    } else {
                        Label("Generate video", systemImage: "sparkles.rectangle.stack")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.unavailableReason != nil)
                .help(viewModel.unavailableReason ?? "Generate a video with Gemini Omni")
            }

            if viewModel.isGenerating || viewModel.statusText != nil {
                HStack(spacing: 8) {
                    if viewModel.isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let statusText = viewModel.statusText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorText = viewModel.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text("Video generation is a billable Google API request. Start with 360p while testing.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var outputPanel: some View {
        if let player = viewModel.player {
            panel(title: "Output", systemImage: "play.rectangle") {
                VideoPlayer(player: player)
                    .aspectRatio(
                        viewModel.aspectRatio == .portrait
                            ? CGFloat(9) / CGFloat(16)
                            : CGFloat(16) / CGFloat(9),
                        contentMode: .fit
                    )
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    if let interactionID = viewModel.interactionID {
                        Text("Interaction \(interactionID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button("Save video…", systemImage: "square.and.arrow.down") {
                        viewModel.saveVideo()
                    }
                }
            }
        }
    }

    private func panel<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

private struct GeminiOmniRequest: Sendable {
    let apiKey: String
    let prompt: String
    let resolution: String
    let aspectRatio: String
}

private struct GeminiOmniResult: Sendable {
    let videoData: Data
    let interactionID: String?
}

private struct GeminiOmniClient: Sendable {
    private static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    func generate(
        _ generation: GeminiOmniRequest,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> GeminiOmniResult {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(generation.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gemini-omni-1.1-flash",
            "input": generation.prompt,
            "response_format": [
                "type": "video",
                "delivery": "uri",
                "resolution": generation.resolution,
                "aspect_ratio": generation.aspectRatio,
            ],
        ])

        let (responseData, response) = try await Self.session.data(for: request)
        try Self.validate(response: response, data: responseData)
        let responseJSON = try Self.jsonObject(from: responseData)
        let interactionID = responseJSON["id"] as? String

        if let inlineData = try Self.inlineVideoData(in: responseJSON) {
            return GeminiOmniResult(videoData: inlineData, interactionID: interactionID)
        }

        guard let videoURI = Self.videoURI(in: responseJSON),
              let fileName = Self.fileName(in: videoURI)
        else {
            throw GeminiOmniError.invalidResponse("The API response did not contain video data or a video URI.")
        }

        onProgress("Video created. Waiting for Google to finish processing…")
        try await waitUntilActive(fileName: fileName, apiKey: generation.apiKey, onProgress: onProgress)
        try Task.checkCancellation()

        onProgress("Downloading generated video…")
        let downloadURL = try Self.downloadURL(from: videoURI, fileName: fileName)
        var downloadRequest = URLRequest(url: downloadURL)
        downloadRequest.timeoutInterval = 900
        downloadRequest.setValue(generation.apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (videoData, downloadResponse) = try await Self.session.data(for: downloadRequest)
        try Self.validate(response: downloadResponse, data: videoData)

        guard !videoData.isEmpty else {
            throw GeminiOmniError.invalidResponse("Google returned an empty video file.")
        }

        return GeminiOmniResult(videoData: videoData, interactionID: interactionID)
    }

    private func waitUntilActive(
        fileName: String,
        apiKey: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        let deadline = Date().addingTimeInterval(900)

        while Date() < deadline {
            try Task.checkCancellation()

            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName)")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await Self.session.data(for: request)
            try Self.validate(response: response, data: data)
            let json = try Self.jsonObject(from: data)
            let state = Self.fileState(in: json)

            switch state {
            case "ACTIVE":
                return
            case "FAILED":
                throw GeminiOmniError.generationFailed(Self.failureMessage(in: json))
            default:
                onProgress("Google is processing the video\(state.map { " (\($0.lowercased()))" } ?? "")…")
                try await Task.sleep(for: .seconds(5))
            }
        }

        throw GeminiOmniError.timedOut
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 1_200
        return URLSession(configuration: configuration)
    }()

    private static func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiOmniError.invalidResponse("Google returned a non-HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = apiErrorMessage(in: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw GeminiOmniError.http(status: httpResponse.statusCode, message: message)
        }
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiOmniError.invalidResponse("Google returned malformed JSON.")
        }
        return json
    }

    private static func inlineVideoData(in json: [String: Any]) throws -> Data? {
        guard let content = videoContent(in: json), let encoded = content["data"] as? String else {
            return nil
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw GeminiOmniError.invalidResponse("The generated video's Base64 data is invalid.")
        }
        return data
    }

    private static func videoURI(in json: [String: Any]) -> String? {
        videoContent(in: json)?["uri"] as? String
    }

    private static func videoContent(in json: [String: Any]) -> [String: Any]? {
        if let output = json["output_video"] as? [String: Any] {
            return output
        }

        guard let steps = json["steps"] as? [[String: Any]] else { return nil }
        for step in steps.reversed() {
            guard step["type"] as? String == "model_output",
                  let contents = step["content"] as? [[String: Any]]
            else { continue }

            if let video = contents.first(where: { $0["type"] as? String == "video" }) {
                return video
            }
        }
        return nil
    }

    private static func fileName(in uri: String) -> String? {
        guard let range = uri.range(of: #"files/[^/:?]+"#, options: .regularExpression) else {
            return nil
        }
        return String(uri[range])
    }

    private static func fileState(in json: [String: Any]) -> String? {
        if let state = json["state"] as? String {
            return state.uppercased()
        }
        if let state = json["state"] as? [String: Any], let name = state["name"] as? String {
            return name.uppercased()
        }
        return nil
    }

    private static func failureMessage(in json: [String: Any]) -> String {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return "Google reported that video processing failed."
    }

    private static func downloadURL(from uri: String, fileName: String) throws -> URL {
        let candidate: URL
        if let absolute = URL(string: uri), absolute.scheme != nil {
            candidate = absolute
        } else {
            guard let constructed = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(fileName):download?alt=media") else {
                throw GeminiOmniError.invalidResponse("Google returned an invalid video URI.")
            }
            candidate = constructed
        }

        if candidate.absoluteString.contains(":download") {
            return candidate
        }
        guard let download = URL(string: candidate.absoluteString + ":download?alt=media") else {
            throw GeminiOmniError.invalidResponse("Google returned an invalid video download URI.")
        }
        return download
    }

    private static func apiErrorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }
}

private enum GeminiOmniError: LocalizedError {
    case http(status: Int, message: String)
    case invalidResponse(String)
    case generationFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            "Gemini API error (HTTP \(status)): \(message)"
        case .invalidResponse(let message):
            message
        case .generationFailed(let message):
            "Video generation failed: \(message)"
        case .timedOut:
            "Video processing did not finish within 15 minutes."
        }
    }
}
