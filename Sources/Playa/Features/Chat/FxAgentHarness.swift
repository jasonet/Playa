import Foundation

enum FxAgentEvent: Sendable {
    case text(String)
    case status(String)
    case image(ChatImageAttachment)
}

private struct FxAgentImageMarkerDecoder {
    private static let markerPrefix = "[[PLAYA_IMAGE_V1:"
    private static let markerSuffix = "]]"

    private struct Metadata: Decodable {
        let filename: String
        let mimeType: String
    }

    private var buffer = ""

    mutating func consume(_ text: String) -> [FxAgentEvent] {
        buffer += text
        var events: [FxAgentEvent] = []

        while let markerStart = buffer.range(of: Self.markerPrefix) {
            let leadingText = String(buffer[..<markerStart.lowerBound])
            if !leadingText.isEmpty {
                events.append(.text(leadingText))
            }
            let tokenStart = markerStart.upperBound
            guard let markerEnd = buffer.range(
                of: Self.markerSuffix,
                range: tokenStart..<buffer.endIndex
            ) else {
                buffer = String(buffer[markerStart.lowerBound...])
                return events
            }

            let token = String(buffer[tokenStart..<markerEnd.lowerBound])
            if let attachment = Self.attachment(from: token) {
                events.append(.image(attachment))
            }
            buffer = String(buffer[markerEnd.upperBound...])
        }

        let retainedCount = min(buffer.count, Self.markerPrefix.count - 1)
        let emitEnd = buffer.index(buffer.endIndex, offsetBy: -retainedCount)
        let readyText = String(buffer[..<emitEnd])
        if !readyText.isEmpty {
            events.append(.text(readyText))
        }
        buffer = String(buffer[emitEnd...])
        return events
    }

    mutating func finish() -> [FxAgentEvent] {
        defer { buffer = "" }
        return buffer.isEmpty ? [] : [.text(buffer)]
    }

    private static func attachment(from token: String) -> ChatImageAttachment? {
        var base64 = token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padding)
        guard let metadataData = Data(base64Encoded: base64),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
              metadata.filename == URL(fileURLWithPath: metadata.filename).lastPathComponent,
              !metadata.filename.isEmpty,
              metadata.mimeType.hasPrefix("image/"),
              let cachesDirectory = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
              ).first
        else {
            return nil
        }

        let imageURL = cachesDirectory
            .appendingPathComponent("Playa", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
            .appendingPathComponent(metadata.filename, isDirectory: false)
        guard let imageData = try? Data(contentsOf: imageURL), !imageData.isEmpty else {
            return nil
        }
        return ChatImageAttachment(
            filename: metadata.filename,
            mimeType: metadata.mimeType,
            base64Data: imageData.base64EncodedString()
        )
    }
}

enum FxAgentExecutionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case local = "local"
    case opencomputer = "opencomputer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:
            "Local"
        case .opencomputer:
            "OpenComputer"
        }
    }

    var systemImage: String {
        switch self {
        case .local:
            "laptopcomputer"
        case .opencomputer:
            "cloud"
        }
    }
}

struct FxAgentRunResult: Sendable {
    let sessionID: String
    let modelID: String
    let availableModelIDs: [String]
}

struct FxAgentSessionConfiguration: Sendable {
    let sessionID: String
    let modelID: String
    let availableModelIDs: [String]
}

enum FxAgentHarnessError: LocalizedError {
    case binaryNotFound
    case processFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "fx agent binary was not found. Build /Users/tfwl/Sites/Github/fx first."
        case .processFailed(let message):
            "fx agent failed: \(message)"
        case .invalidResponse(let message):
            "fx agent returned an invalid ACP response: \(message)"
        }
    }
}

struct FxAgentHarness {
    static func runImageMarkerSmokeTest() throws -> String {
        let imageData = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let fileManager = FileManager.default
        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw FxAgentHarnessError.invalidResponse("missing caches directory")
        }
        let directory = cachesDirectory
            .appendingPathComponent("Playa", isDirectory: true)
            .appendingPathComponent("Chat", isDirectory: true)
            .appendingPathComponent("GeneratedImages", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "marker-smoke-\(UUID().uuidString).png"
        let imageURL = directory.appendingPathComponent(filename)
        try imageData.write(to: imageURL, options: .atomic)
        defer { try? fileManager.removeItem(at: imageURL) }

        let metadata = try JSONSerialization.data(withJSONObject: [
            "filename": filename,
            "mimeType": "image/png",
        ])
        let token = metadata.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let marker = "[[PLAYA_IMAGE_V1:\(token)]]"

        var decoder = FxAgentImageMarkerDecoder()
        let splitIndex = marker.index(marker.startIndex, offsetBy: 12)
        var events = decoder.consume("caption " + String(marker[..<splitIndex]))
        events += decoder.consume(String(marker[splitIndex...]) + " tail")
        events += decoder.finish()

        let text = events.compactMap { event -> String? in
            if case .text(let value) = event { return value }
            return nil
        }.joined()
        let images = events.compactMap { event -> ChatImageAttachment? in
            if case .image(let value) = event { return value }
            return nil
        }
        guard text == "caption  tail",
              images.count == 1,
              images[0].mimeType == "image/png",
              images[0].imageData == imageData
        else {
            throw FxAgentHarnessError.invalidResponse("generated image marker decoding failed")
        }
        return "PASS: fx generated image marker decoding succeeded."
    }

    static func configure(
        workspace: URL,
        provider: FxAgentProvider,
        modelID: String?,
        apiKey: String?,
        executionMode: FxAgentExecutionMode = .local,
        existingSessionID: String?
    ) async throws -> FxAgentSessionConfiguration {
        try await Task.detached(priority: .userInitiated) {
            let connection = try startConnection(
                workspace: workspace,
                apiKey: apiKey,
                executionMode: executionMode
            )
            defer { connection.close() }

            let configuration = try openAndConfigureSession(
                connection: connection,
                workspace: workspace,
                provider: provider,
                modelID: modelID,
                existingSessionID: existingSessionID
            )
            return FxAgentSessionConfiguration(
                sessionID: configuration.sessionID,
                modelID: configuration.modelID,
                availableModelIDs: configuration.availableModelIDs
            )
        }.value
    }

    static func run(
        prompt: String,
        workspace: URL,
        provider: FxAgentProvider,
        modelID: String?,
        apiKey: String?,
        executionMode: FxAgentExecutionMode = .local,
        existingSessionID: String?,
        onEvent: @escaping @Sendable (FxAgentEvent) async -> Void
    ) async throws -> FxAgentRunResult {
        try await Task.detached(priority: .userInitiated) {
            let connection = try startConnection(
                workspace: workspace,
                apiKey: apiKey,
                executionMode: executionMode
            )
            defer { connection.close() }

            let configuration = try openAndConfigureSession(
                connection: connection,
                workspace: workspace,
                provider: provider,
                modelID: modelID,
                existingSessionID: existingSessionID
            )

            try writeRequest(
                [
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "session/prompt",
                    "params": [
                        "sessionId": configuration.sessionID,
                        "prompt": [["type": "text", "text": prompt]]
                    ]
                ],
                to: connection.input
            )

            var imageMarkerDecoder = FxAgentImageMarkerDecoder()
            while let message = try connection.reader.readObject() {
                if let id = message["id"] as? Int, id == 5 {
                    if let error = message["error"] as? [String: Any] {
                        throw FxAgentHarnessError.processFailed(error["message"] as? String ?? "prompt failed")
                    }
                    for event in imageMarkerDecoder.finish() {
                        await onEvent(event)
                    }
                    return FxAgentRunResult(
                        sessionID: configuration.sessionID,
                        modelID: configuration.modelID,
                        availableModelIDs: configuration.availableModelIDs
                    )
                }
                guard message["method"] as? String == "session/update",
                      let params = message["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      let updateKind = update["sessionUpdate"] as? String
                else {
                    continue
                }
                switch updateKind {
                case "agent_message_chunk":
                    if let content = update["content"] as? [String: Any],
                       let text = content["text"] as? String,
                       !text.isEmpty {
                        for event in imageMarkerDecoder.consume(text) {
                            await onEvent(event)
                        }
                    }
                case "tool_call":
                    if let title = update["title"] as? String, !title.isEmpty {
                        await onEvent(.status(title))
                    }
                default:
                    break
                }
            }

            let stderr = connection.error.fileHandleForReading.readDataToEndOfFile()
            throw FxAgentHarnessError.processFailed(String(decoding: stderr, as: UTF8.self))
        }.value
    }

    private struct SessionConfiguration {
        let sessionID: String
        let modelID: String
        let availableModelIDs: [String]
    }

    private final class Connection {
        let process: Process
        let inputPipe: Pipe
        let error: Pipe
        let reader: JSONLineReader

        var input: FileHandle { inputPipe.fileHandleForWriting }

        init(process: Process, inputPipe: Pipe, outputPipe: Pipe, errorPipe: Pipe) {
            self.process = process
            self.inputPipe = inputPipe
            self.error = errorPipe
            reader = JSONLineReader(fileHandle: outputPipe.fileHandleForReading)
        }

        func close() {
            try? input.close()
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func startConnection(
        workspace: URL,
        apiKey: String?,
        executionMode: FxAgentExecutionMode = .local
    ) throws -> Connection {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = try resolveBinaryURL()
        process.arguments = [
            "--context-limit", "skill_description_bytes=4096",
            "acp"
        ]
        process.currentDirectoryURL = workspace
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["AI_GATEWAY_API_KEY"] = apiKey?.isEmpty == false ? apiKey : "playa-local"
        environment["VERCEL_OIDC_TOKEN"] = ""
        environment["FX_GATEWAY_CHAT_URL"] = "http://127.0.0.1:8080/v3/ai/language-model"
        environment["FX_GATEWAY_BASE_URL"] = "http://127.0.0.1:8080"
        environment["FX_PERMISSION_MODE"] = "auto"
        environment["FX_AUTO_UPGRADE"] = "0"
        environment["NO_COLOR"] = "1"

        if executionMode == .opencomputer {
            let openComputerAPIKey = UserDefaults.standard.string(forKey: "integration.opencomputer.apiKey")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !openComputerAPIKey.isEmpty {
                environment["OPENCOMPUTER_API_KEY"] = openComputerAPIKey
            }
            environment["FX_EXECUTION_MODE"] = "opencomputer"
        } else {
            environment["FX_EXECUTION_MODE"] = "local"
        }
        process.environment = environment

        try process.run()
        let connection = Connection(
            process: process,
            inputPipe: inputPipe,
            outputPipe: outputPipe,
            errorPipe: errorPipe
        )
        do {
            try writeRequest(
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": 1]],
                to: connection.input
            )
            _ = try readResponse(id: 1, reader: connection.reader)
            return connection
        } catch {
            connection.close()
            throw error
        }
    }

    private static func openAndConfigureSession(
        connection: Connection,
        workspace: URL,
        provider: FxAgentProvider,
        modelID: String?,
        existingSessionID: String?
    ) throws -> SessionConfiguration {
        let sessionMethod = existingSessionID == nil ? "session/new" : "session/resume"
        var sessionParams: [String: Any] = [
            "cwd": workspace.path,
            "mcpServers": []
        ]
        if let existingSessionID {
            sessionParams["sessionId"] = existingSessionID
        }
        try writeRequest(
            ["jsonrpc": "2.0", "id": 2, "method": sessionMethod, "params": sessionParams],
            to: connection.input
        )
        let sessionResponse = try readResponse(id: 2, reader: connection.reader)
        let returnedSessionID = (sessionResponse["result"] as? [String: Any])?["sessionId"] as? String
        guard let sessionID = returnedSessionID ?? existingSessionID,
              !sessionID.isEmpty else {
            throw FxAgentHarnessError.invalidResponse("missing sessionId")
        }

        try writeRequest(
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "session/set_config_option",
                "params": ["configId": "provider", "value": provider.fxProviderValue]
            ],
            to: connection.input
        )
        var configurationResponse = try readResponse(id: 3, reader: connection.reader)
        var selection = try modelSelection(from: configurationResponse)

        if let modelID, modelID != selection.current {
            try writeRequest(
                [
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "session/set_config_option",
                    "params": ["configId": "model", "value": modelID]
                ],
                to: connection.input
            )
            configurationResponse = try readResponse(id: 4, reader: connection.reader)
            selection = try modelSelection(from: configurationResponse)
        }

        let availableModelIDs = provider.requiresLocalGateway
            ? [selection.current]
            : selection.options
        return SessionConfiguration(
            sessionID: sessionID,
            modelID: selection.current,
            availableModelIDs: availableModelIDs
        )
    }

    private static func modelSelection(
        from response: [String: Any]
    ) throws -> (current: String, options: [String]) {
        guard let result = response["result"] as? [String: Any],
              let configOptions = result["configOptions"] as? [[String: Any]],
              let model = configOptions.first(where: { $0["id"] as? String == "model" }),
              let current = model["currentValue"] as? String,
              !current.isEmpty
        else {
            throw FxAgentHarnessError.invalidResponse("missing model configuration")
        }
        let options = (model["options"] as? [[String: Any]] ?? [])
            .compactMap { $0["value"] as? String }
        return (current, options)
    }

    private static func resolveBinaryURL() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["PLAYA_FX_BINARY"],
           FileManager.default.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        if let bundled = Bundle.main.url(forResource: "fx", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
#if DEBUG
        let sourceURL = URL(fileURLWithPath: #filePath)
        let githubRoot = (0..<6).reduce(sourceURL) { url, _ in url.deletingLastPathComponent() }
        let developmentBinary = githubRoot.appendingPathComponent("fx/zig-out/bin/fx")
        if FileManager.default.isExecutableFile(atPath: developmentBinary.path) {
            return developmentBinary
        }
#endif
        throw FxAgentHarnessError.binaryNotFound
    }

    private static func writeRequest(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func readResponse(id: Int, reader: JSONLineReader) throws -> [String: Any] {
        while let object = try reader.readObject() {
            guard object["id"] as? Int == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw FxAgentHarnessError.processFailed(error["message"] as? String ?? "ACP request failed")
            }
            return object
        }
        throw FxAgentHarnessError.invalidResponse("connection closed")
    }
}

private final class JSONLineReader {
    private let fileHandle: FileHandle
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func readObject() throws -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let value = try JSONSerialization.jsonObject(with: Data(line))
                return value as? [String: Any]
            }
            let chunk = fileHandle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
