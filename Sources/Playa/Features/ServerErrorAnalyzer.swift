import Foundation

struct ServerErrorAnalysis {
    let category: Category
    let summary: String
    let suggestions: [String]

    enum Category: String {
        case modelNotFound
        case outOfMemory
        case portInUse
        case permissionDenied
        case missingDependency
        case modelFormatError
        case networkError
        case pythonRuntime
        case genericCrash
        case timeout

        var icon: String {
            switch self {
            case .modelNotFound: "questionmark.folder"
            case .outOfMemory: "memorychip"
            case .portInUse: "network"
            case .permissionDenied: "lock.shield"
            case .missingDependency: "puzzlepiece.extension"
            case .modelFormatError: "doc.badge.gearshape"
            case .networkError: "wifi.slash"
            case .pythonRuntime: "terminal"
            case .genericCrash: "exclamationmark.triangle"
            case .timeout: "clock.badge.exclamationmark"
            }
        }
    }
}

enum ServerErrorAnalyzer {
    static func analyze(logText: String, errorMessage: String) -> ServerErrorAnalysis {
        let combined = (logText + "\n" + errorMessage).lowercased()

        if let result = matchModelNotFound(combined) { return result }
        if let result = matchOutOfMemory(combined) { return result }
        if let result = matchPortInUse(combined) { return result }
        if let result = matchPermissionDenied(combined) { return result }
        if let result = matchMissingDependency(combined) { return result }
        if let result = matchModelFormatError(combined) { return result }
        if let result = matchNetworkError(combined) { return result }
        if let result = matchPythonRuntime(combined) { return result }
        if let result = matchTimeout(combined) { return result }

        return ServerErrorAnalysis(
            category: .genericCrash,
            summary: "Server failed to start.",
            suggestions: [
                "Check the Developer log for the full error output.",
                "Try force-killing the server and restarting.",
                "Verify the model files are complete and not corrupted.",
                "Try a different model to isolate the issue."
            ]
        )
    }

    static func recentLogLines(from logText: String, maxLines: Int = 8) -> String {
        let lines = logText
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let relevantLines = lines.suffix(maxLines)
        return relevantLines.joined(separator: "\n")
    }

    // MARK: - Pattern Matchers

    private static func matchModelNotFound(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "no model found",
            "model not found",
            "could not find model",
            "does not exist",
            "no such file or directory",
            "repository not found",
            "huggingface_hub.errors.repositorynotfounderror",
            "file not found",
            "cannot find",
            "model path"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .modelNotFound,
            summary: "Model files could not be found.",
            suggestions: [
                "Check that the model is downloaded in the Models page.",
                "Verify the model search path in settings (~/.cache/huggingface/hub).",
                "If using a local path, ensure the directory exists and contains model files.",
                "Try re-downloading the model from the Discover tab."
            ]
        )
    }

    private static func matchOutOfMemory(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "out of memory",
            "oom",
            "not enough memory",
            "memory allocation failed",
            "insufficient memory",
            "cannot allocate",
            "killed",
            "signal 9",
            "exceeded memory"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .outOfMemory,
            summary: "The model requires more memory than available.",
            suggestions: [
                "Try a smaller model or a more quantized variant (e.g., 4-bit instead of 16-bit).",
                "Reduce the max context tokens in settings.",
                "Close other applications to free up memory.",
                "Enable KV cache quantization in settings to reduce memory usage."
            ]
        )
    }

    private static func matchPortInUse(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "address already in use",
            "port.*already",
            "bind.*failed",
            "errno.*98",
            "errno.*48",
            "[errno 48]",
            "[errno 98]"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .portInUse,
            summary: "Port 8080 is already in use by another process.",
            suggestions: [
                "Kill the other process using port 8080 (check Activity Monitor or run `lsof -i :8080`).",
                "Another Playa server instance may still be running — force kill it first.",
                "Wait a few seconds and try again (the port may be released shortly)."
            ]
        )
    }

    private static func matchPermissionDenied(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "permission denied",
            "access denied",
            "operation not permitted",
            "errno 13",
            "[errno 13]"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .permissionDenied,
            summary: "Permission denied when accessing model files.",
            suggestions: [
                "Check file permissions on the model directory.",
                "Ensure Playa has Full Disk Access in System Settings → Privacy & Security.",
                "Try running `chmod -R u+rw` on the model cache directory."
            ]
        )
    }

    private static func matchMissingDependency(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "modulenotfounderror",
            "importerror",
            "no module named",
            "pip install",
            "package not found",
            "dependency",
            "missing.*library",
            "could not import"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .missingDependency,
            summary: "A required Python dependency is missing.",
            suggestions: [
                "Rebuild the Python distribution: run `make build` in the project directory.",
                "Check that mlx-vlm-server is correctly bundled in the app resources.",
                "Verify the model's architecture is supported by the current mlx-vlm version."
            ]
        )
    }

    private static func matchModelFormatError(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "safetensors",
            "config.json",
            "tokenizer",
            "unsupported.*architecture",
            "invalid.*format",
            "corrupted",
            "json.*decode",
            "unrecognized.*model",
            "keyerror.*model_type"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .modelFormatError,
            summary: "Model files appear to be corrupted or in an unsupported format.",
            suggestions: [
                "Delete and re-download the model from the Discover tab.",
                "Verify the model is an MLX-compatible format (check for config.json and model weights).",
                "Try a different model to confirm the issue is model-specific."
            ]
        )
    }

    private static func matchNetworkError(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "connection refused",
            "connection reset",
            "timeout",
            "network",
            "urlopen error",
            "ssl",
            "certificate",
            "huggingface.*error",
            "hf_hub.*error"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .networkError,
            summary: "Network error while accessing model files.",
            suggestions: [
                "Check your internet connection.",
                "If behind a proxy, ensure proxy settings are correct (Playa strips system proxies for local server).",
                "Hugging Face may be temporarily unavailable — try again in a few minutes.",
                "Try using a VPN if Hugging Face is blocked in your region."
            ]
        )
    }

    private static func matchPythonRuntime(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "python",
            "dyld",
            "symbol not found",
            "image not found",
            "library not loaded",
            "framework.*not found",
            "traceback",
            "segfault",
            "segmentation fault"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .pythonRuntime,
            summary: "Python runtime error in the server process.",
            suggestions: [
                "Rebuild the Python distribution: run `make build` in the project directory.",
                "Check that Xcode Command Line Tools are installed (`xcode-select --install`).",
                "If you recently updated macOS, the bundled Python may need to be rebuilt.",
                "Check the Developer log for the full Python traceback."
            ]
        )
    }

    private static func matchTimeout(_ text: String) -> ServerErrorAnalysis? {
        let patterns = [
            "did not become ready",
            "timed out",
            "timeout",
            "stuck loading"
        ]
        guard patterns.contains(where: { text.contains($0) }) else { return nil }
        return ServerErrorAnalysis(
            category: .timeout,
            summary: "Server startup timed out.",
            suggestions: [
                "Large models can take 1-2 minutes to load — try increasing the timeout.",
                "The model may be downloading from Hugging Face (check network activity).",
                "Try a smaller model to verify the server can start.",
                "Force-kill the server and restart."
            ]
        )
    }
}
