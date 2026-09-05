import Foundation

enum NativeAgentRisk: Equatable, Sendable {
    case automatic
    case confirmation(String)
    case denied(String)
}

struct NativeAgentToolRequest: Codable, Equatable, Sendable {
    let name: String
    let arguments: [String: String]
    let status: String?
}

struct NativeAgentToolResult: Equatable, Sendable {
    let output: String
    let isError: Bool
}

struct NativeAgentWorkspace: Sendable {
    let root: URL

    init(root: URL) throws {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NativeAgentToolError.invalidWorkspace
        }
        self.root = resolved
    }

    func resolve(_ path: String) throws -> URL {
        let candidate = path.isEmpty || path == "."
            ? root
            : root.appendingPathComponent(path)
        let standardized = candidate.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw NativeAgentToolError.outsideWorkspace(path)
        }
        if FileManager.default.fileExists(atPath: resolved.path) {
            let linked = resolved.resolvingSymlinksInPath()
            guard linked.path == root.path || linked.path.hasPrefix(root.path + "/") else {
                throw NativeAgentToolError.outsideWorkspace(path)
            }
            return linked
        }
        return resolved
    }
}

enum NativeAgentToolError: LocalizedError {
    case invalidWorkspace
    case outsideWorkspace(String)
    case unsupportedTool(String)
    case denied(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace: "The Agent workspace is unavailable."
        case .outsideWorkspace(let path): "Access outside the workspace is blocked: \(path)"
        case .unsupportedTool(let tool): "Unsupported native Agent tool: \(tool)"
        case .denied(let reason): reason
        case .failed(let detail): detail
        }
    }
}

struct NativeAgentToolExecutor: Sendable {
    typealias Approval = @Sendable (String, String) async -> Bool

    let workspace: NativeAgentWorkspace

    func risk(for request: NativeAgentToolRequest) -> NativeAgentRisk {
        let joined = ([request.name] + request.arguments.values).joined(separator: " ").lowercased()
        let deniedPatterns = ["sudo ", "git push --force", "git reset --hard", "git clean -f", "/etc/", "/system/", "/library/keychains", ".ssh/", ".aws/", ".env", "security find-"]
        if let pattern = deniedPatterns.first(where: joined.contains) {
            return .denied("Blocked high-risk operation containing ‘\(pattern.trimmingCharacters(in: .whitespaces))’.")
        }
        let confirmPatterns = ["rm ", "rm -", "curl ", "wget ", "npm install", "pnpm install", "yarn add", "pip install", "brew install", "git push", "network"]
        if let pattern = confirmPatterns.first(where: joined.contains) {
            return .confirmation("This operation may delete data, install dependencies, or access the network (‘\(pattern.trimmingCharacters(in: .whitespaces))’).")
        }
        return .automatic
    }

    func execute(_ request: NativeAgentToolRequest, approval: Approval) async -> NativeAgentToolResult {
        do {
            var approvedElevatedOperation = false
            switch risk(for: request) {
            case .automatic:
                break
            case .confirmation(let reason):
                guard await approval(request.status ?? request.name, reason) else {
                    return NativeAgentToolResult(output: "User denied the requested operation: \(reason)", isError: true)
                }
                approvedElevatedOperation = true
            case .denied(let reason):
                return NativeAgentToolResult(output: reason, isError: true)
            }

            switch request.name {
            case "list_files":
                let url = try workspace.resolve(request.arguments["path"] ?? ".")
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                return .init(output: entries.joined(separator: "\n"), isError: false)
            case "read_file":
                let url = try workspace.resolve(request.arguments["path"] ?? "")
                let data = try Data(contentsOf: url)
                guard data.count <= 1_000_000 else { throw NativeAgentToolError.failed("File exceeds the 1 MB read limit.") }
                return .init(output: String(decoding: data, as: UTF8.self), isError: false)
            case "search":
                let query = request.arguments["query"] ?? ""
                guard !query.isEmpty else { throw NativeAgentToolError.failed("search requires query") }
                let searchRoot = try workspace.resolve(request.arguments["path"] ?? ".")
                return try await run("/usr/bin/grep", arguments: ["-R", "-n", "-I", "--", query, searchRoot.path])
            case "write_file":
                let url = try workspace.resolve(request.arguments["path"] ?? "")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (request.arguments["content"] ?? "").write(to: url, atomically: true, encoding: .utf8)
                return .init(output: "Wrote \(url.path.replacingOccurrences(of: workspace.root.path + "/", with: ""))", isError: false)
            case "shell":
                let command = request.arguments["command"] ?? ""
                guard !command.isEmpty else { throw NativeAgentToolError.failed("shell requires command") }
                return try await runShell(command, allowsNetwork: approvedElevatedOperation)
            default:
                throw NativeAgentToolError.unsupportedTool(request.name)
            }
        } catch {
            return NativeAgentToolResult(output: error.localizedDescription, isError: true)
        }
    }

    private func runShell(_ command: String, allowsNetwork: Bool) async throws -> NativeAgentToolResult {
        let escapedRoot = workspace.root.path.replacingOccurrences(of: "\"", with: "\\\"")
        let networkRule = allowsNetwork ? "(allow network*)" : "(deny network*)"
        let profile = """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process*)
        (allow sysctl-read)
        (allow file-read*)
        (allow file-write* (subpath "\(escapedRoot)"))
        (allow file-write* (subpath "/private/tmp"))
        (allow file-write* (subpath "/private/var/folders"))
        \(networkRule)
        """
        return try await run("/usr/bin/sandbox-exec", arguments: ["-p", profile, "/bin/zsh", "-lc", command])
    }

    private func run(_ executable: String, arguments: [String]) async throws -> NativeAgentToolResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let lock = NSLock()
                var captured = Data()
                output.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    lock.lock()
                    if captured.count < 200_000 { captured.append(data.prefix(200_000 - captured.count)) }
                    lock.unlock()
                }
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = workspace.root
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    process.waitUntilExit()
                    output.fileHandleForReading.readabilityHandler = nil
                    let tail = output.fileHandleForReading.readDataToEndOfFile()
                    lock.lock()
                    if captured.count < 200_000 { captured.append(tail.prefix(200_000 - captured.count)) }
                    let data = captured
                    lock.unlock()
                    continuation.resume(returning: NativeAgentToolResult(
                        output: String(decoding: data, as: UTF8.self),
                        isError: process.terminationStatus != 0
                    ))
                } catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
