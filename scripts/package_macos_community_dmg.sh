#!/bin/bash

set -euo pipefail

readonly DEFAULT_NAME="Playa-0.3.4-macos-arm64-unnotarized.dmg"
readonly DEFAULT_MAX_BYTES=314572800

usage() {
    cat <<EOF
Usage: package_macos_community_dmg.sh [options] APP

Packages an ad-hoc-signed Playa.app as an unnotarized arm64 community DMG.
The default output is dist/$DEFAULT_NAME and the default maximum size is
$DEFAULT_MAX_BYTES bytes (300 MiB).

Options:
  --output PATH       DMG output path.
  --max-bytes BYTES   Fail if the DMG exceeds this exact size.
  -h, --help          Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
output="$repository_root/dist/$DEFAULT_NAME"
max_bytes="$DEFAULT_MAX_BYTES"

while (($# > 0)); do
    case "$1" in
        --output)
            (($# >= 2)) || fail "--output requires a value"
            output="$2"
            shift 2
            ;;
        --max-bytes)
            (($# >= 2)) || fail "--max-bytes requires a value"
            max_bytes="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option: $1"
            ;;
        *)
            break
            ;;
    esac
done

(($# == 1)) || { usage >&2; exit 2; }
[[ "$max_bytes" =~ ^[1-9][0-9]*$ ]] || fail "--max-bytes must be a positive integer"

app="$1"
[[ -d "$app/Contents" ]] || fail "not a macOS app bundle: $app"
app="$(cd "$(dirname "$app")" && pwd -P)/$(basename "$app")"
case "$output" in
    /*) ;;
    *) output="$repository_root/$output" ;;
esac
[[ "$output" == *.dmg ]] || fail "--output must end in .dmg"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" == "0.3.4" ]] || fail "app version is $version, expected 0.3.4"
main_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
file "$app/Contents/MacOS/$main_executable" | grep -q 'arm64' || fail "main executable is not arm64"
file "$app/Contents/MacOS/$main_executable" | grep -qv 'x86_64' || fail "main executable unexpectedly contains x86_64"

codesign --verify --deep --strict --verbose=2 "$app"
signature="$(codesign -dvv "$app" 2>&1)"
[[ "$signature" == *"Signature=adhoc"* ]] || fail "app is not ad-hoc signed"

stage="$(mktemp -d "${TMPDIR:-/tmp}/playa-community-dmg.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
cp -R "$app" "$stage/Playa.app"
ln -s /Applications "$stage/Applications"
mkdir -p "$(dirname "$output")"
rm -f "$output"

hdiutil create \
    -volname "Playa 0.3.4" \
    -srcfolder "$stage" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$output"

size="$(stat -f '%z' "$output")"
((size <= max_bytes)) || fail "DMG is $size bytes, exceeding limit $max_bytes"
sha256="$(shasum -a 256 "$output" | awk '{print $1}')"
printf '%s  %s\n' "$sha256" "$(basename "$output")" > "$output.sha256"

echo "DMG:    $output"
echo "Size:   $size bytes"
echo "SHA256: $sha256"
