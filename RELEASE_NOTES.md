# Playa 0.3.4 Community Preview

Playa 0.3.4 adds a downloadable Apple Silicon community build while preserving the complete bundled MLX and MLX-VLM Python runtime for offline inference after dependencies and model files have been downloaded.

## Highlights

- Complete embedded MLX, MLX-VLM, Transformers, scientific Python, image, video, and audio runtime
- Deterministic Release pruning of Python bytecode caches, third-party test suites, pip/ensurepip, IDLE, Tk demos, and development headers
- Compressed arm64 DMG targeting no more than 300 MiB
- One-click local MLX and MLX-VLM model serving on Apple Silicon
- TB-scale local model discovery, filtering, downloads, history, launch, and removal
- EasyCLIProxyAPI provider configuration and model discovery
- Classic streaming chat, Fx Agent, OpenComputer execution, and conversational image workflows

## Community build security notice

`Playa-0.3.4-macos-arm64-unnotarized.dmg` is ad-hoc signed and **not notarized by Apple**. The ad-hoc signature protects code integrity but does not verify the publisher's identity. macOS Gatekeeper may block the first launch.

Only download the DMG from the official GitHub release and verify its SHA-256 checksum. After copying Playa to `/Applications`, Control-click the app and choose **Open**. If macOS still blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway** for Playa.

A future build signed with a Developer ID Application certificate and accepted by Apple notarization will support the standard macOS launch flow.

## Requirements

- Apple Silicon Mac
- macOS 26 or newer
- Sufficient disk space and unified memory for the selected models

Provider credentials, Apple signing identities, certificates, notarization credentials, and private update keys are intentionally excluded from the repository and release assets.
