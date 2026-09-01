# Contributing to Playa

Thank you for helping improve Playa.

## Development requirements

- Apple Silicon Mac running macOS 26 or newer
- Xcode with the macOS 26 SDK
- XcodeGen
- Python 3
- Zig
- A checkout of `vercel-labs/fx` at `../fx`, or `PLAYA_FX_SOURCE_ROOT` set to its location

## Setup

```sh
brew install xcodegen zig
git clone https://github.com/jasonet/Playa.git
cd Playa
git clone https://github.com/vercel-labs/fx.git ../fx
make xcode-build
```

Do not commit machine-specific signing configuration. Put local values in `Configuration/Signing.local.xcconfig`.

## Before submitting a pull request

Run the relevant focused tests, then run:

```sh
xcodegen generate
xcodebuild \
  -project Playa.xcodeproj \
  -scheme Playa \
  -configuration Debug \
  -derivedDataPath build/XcodeDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

swift scripts/test_cli_proxy_config.swift
python3 scripts/test_fx_gateway_bridge.py
python3 scripts/test_fx_image_stream_bridge.py
```

For model-layout changes, also run:

```sh
swift scripts/test_models_layout.swift \
  build/XcodeDerivedData/Build/Products/Debug/Playa.app
```

## Pull requests

- Keep changes focused.
- Add or update tests for behavior changes.
- Explain user-visible changes and verification steps.
- Never include API keys, OAuth tokens, certificates, private signing keys, personal paths, or generated build products.
- Preserve third-party license and attribution notices.

## Reporting bugs

Open a GitHub issue with the Playa version, macOS version, Mac model, reproduction steps, expected behavior, actual behavior, and relevant logs with secrets removed.
