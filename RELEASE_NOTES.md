# Playa 0.3.5

Playa 0.3.5 introduces native Agent Harness engines alongside Fx Agent, adds risk-tiered execution safety, and improves ACP server reliability.

## Highlights

- **Deep Agent Harness**: Native in-process autonomous single-agent engine operating through iterative `Plan → Act → Observe → Reflect` loops directly in your project workspace.
- **Prime Agent Harness**: Dynamic multi-agent coordinator that decomposes complex goals into specialist tasks, executes independent read-only tasks concurrently, serializes edits, and synthesizes results.
- **Unified Agent Picker**: Interactive card-based harness selector when creating new agent sessions, with distinct indicators for autonomous and multi-agent workflows.
- **Sandboxed Tool Runtime**: Bounded tool execution with symlink resolution, workspace boundary enforcement, and risk-tiered user confirmations for sensitive operations.
- **Fx Agent & ACP Server Fixes**: Resolved ACP `initialize` startup error handling and credential fallback when offline or in restricted network environments.
- **EasyCLIProxyAPI Integration**: Seamless configuration, discovery, caching, and model management for external OpenAI-compatible gateways.
- **Complete Offline Runtime**: Retains the complete embedded MLX and MLX-VLM Python stack on Apple Silicon with deterministic Release pruning.

## Community build security notice

`Playa-0.3.5-macos-arm64-unnotarized.dmg` is ad-hoc signed and **not notarized by Apple**. The ad-hoc signature protects code integrity but does not verify the publisher's identity. macOS Gatekeeper may block the first launch.

Only download the DMG from the official GitHub release and verify its SHA-256 checksum. After copying Playa to `/Applications`, Control-click the app and choose **Open**. If macOS still blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway** for Playa.

## Requirements

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 14.0 or newer
- Sufficient disk space and unified memory for selected models
