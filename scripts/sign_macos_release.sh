#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sign_macos_release.sh [options] TARGET

Signs every Mach-O file inside a macOS app from the inside out, then signs
nested code bundles and the app itself. TARGET may also be a .dmg disk image;
in that case, only the disk image container is signed.

Options:
  --identity ID    Codesigning identity name or SHA-1 hash.
  --team-id ID     Resolve a certificate whose subject OU matches this Team ID.
                   If neither option is provided, DEVELOPMENT_TEAM is read from
                   the Release build settings.
  --no-timestamp   Disable the secure timestamp for local development testing.
                   This selects Apple Development for Team ID resolution and is
                   rejected for Developer ID Application identities.
  --adhoc          Ad-hoc sign an unnotarized community build. This provides
                   code integrity but does not establish a trusted developer.
  -h, --help       Show this help.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"
identity="${CODE_SIGN_IDENTITY:-}"
team_id="${PLAYA_TEAM_ID:-}"
use_timestamp=true
adhoc=false

while (($# > 0)); do
    case "$1" in
        --identity)
            (($# >= 2)) || fail "--identity requires a value"
            identity="$2"
            shift 2
            ;;
        --team-id)
            (($# >= 2)) || fail "--team-id requires a value"
            team_id="$2"
            shift 2
            ;;
        --no-timestamp)
            use_timestamp=false
            shift
            ;;
        --adhoc)
            adhoc=true
            identity="-"
            use_timestamp=false
            shift
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

(($# == 1)) || {
    usage >&2
    exit 2
}

target_path="$1"
is_disk_image=false
if [[ -f "$target_path" && "$target_path" == *.dmg ]]; then
    is_disk_image=true
elif [[ ! -d "$target_path" || ! -d "$target_path/Contents" ]]; then
    fail "target must be a macOS app bundle or .dmg disk image: $target_path"
fi

target_directory="$(cd "$(dirname "$target_path")" && pwd -P)"
target_path="$target_directory/$(basename "$target_path")"
app_path="$target_path"

[[ -z "$identity" || -z "$team_id" ]] || fail "use either --identity or --team-id, not both"
if [[ "$adhoc" == true && -n "$team_id" ]]; then
    fail "--adhoc cannot be combined with --team-id"
fi

if [[ -z "$identity" && -z "$team_id" ]]; then
    team_id="$(
        xcodebuild \
            -project "$repository_root/Playa.xcodeproj" \
            -scheme Playa \
            -configuration Release \
            -showBuildSettings 2>/dev/null |
            sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' |
            sort -u |
            head -n 1
    )"
    [[ -n "$team_id" ]] || fail "could not infer DEVELOPMENT_TEAM; pass --team-id or --identity"
    echo "Using DEVELOPMENT_TEAM from Release build settings: $team_id"
fi

if [[ -n "$team_id" ]]; then
    [[ "$team_id" =~ ^[[:alnum:]]{10}$ ]] || fail "invalid Team ID: $team_id"
    command -v openssl >/dev/null 2>&1 || fail "openssl is required to resolve a Team ID"

    certificate_kind="Developer ID Application"
    if [[ "$use_timestamp" == false ]]; then
        certificate_kind="Apple Development"
    fi

    matching_hashes=()
    matching_names=()
    while IFS= read -r identity_candidate; do
        certificate_hash="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) ".*"$/\1/p' <<< "$identity_candidate")"
        certificate_name="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' <<< "$identity_candidate")"
        [[ -n "$certificate_hash" && "$certificate_name" == "$certificate_kind:"* ]] || continue

        certificate_subject="$(
            security find-certificate -c "$certificate_name" -p 2>/dev/null |
                openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true
        )"
        [[ "$certificate_subject" == *"OU=$team_id"* ]] || continue
        matching_hashes+=("$certificate_hash")
        matching_names+=("$certificate_name")
    done < <(security find-identity -v -p codesigning 2>/dev/null)

    if ((${#matching_hashes[@]} == 0)); then
        fail "no $certificate_kind certificate found for Team ID $team_id"
    fi
    if ((${#matching_hashes[@]} > 1)); then
        echo "error: multiple $certificate_kind certificates found for Team ID $team_id:" >&2
        for certificate_name in "${matching_names[@]}"; do
            echo "  $certificate_name" >&2
        done
        fail "pass --identity to choose one explicitly"
    fi

    identity="${matching_hashes[0]}"
    identity_display_name="${matching_names[0]}"
    echo "Resolved signing identity: $identity_display_name"
fi

identity_line=""
if [[ "$adhoc" == false ]]; then
    identity_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$identity" | head -n 1 || true)"
    [[ -n "$identity_line" ]] || fail "codesigning identity not found: $identity"
fi

if [[ "$use_timestamp" == false && "$identity_line" == *"Developer ID Application"* ]]; then
    fail "Developer ID Application signatures require a secure timestamp"
fi

timestamp_arguments=(--timestamp)
if [[ "$use_timestamp" == false ]]; then
    timestamp_arguments=(--timestamp=none)
fi

adhoc_python_entitlements=""
adhoc_app_entitlements=""
cleanup() {
    [[ -z "$adhoc_python_entitlements" ]] || rm -f "$adhoc_python_entitlements"
    [[ -z "$adhoc_app_entitlements" ]] || rm -f "$adhoc_app_entitlements"
}
trap cleanup EXIT

if [[ "$adhoc" == true ]]; then
    adhoc_python_entitlements="$(mktemp "${TMPDIR:-/tmp}/playa-python-entitlements.XXXXXX")"
    adhoc_app_entitlements="$(mktemp "${TMPDIR:-/tmp}/playa-app-entitlements.XXXXXX")"
    cat > "$adhoc_python_entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
    cp "$adhoc_python_entitlements" "$adhoc_app_entitlements"
fi

sign_target() {
    local target="$1"
    local entitlements=""
    if [[ "$adhoc" == true && "$target" == */python/bin/python3.* ]]; then
        entitlements="$adhoc_python_entitlements"
    fi
    if [[ "$adhoc" == true && "$target" == "$app_path" ]]; then
        entitlements="$adhoc_app_entitlements"
    fi
    if [[ -n "$entitlements" ]]; then
        codesign \
            --force \
            --sign "$identity" \
            --options runtime \
            "${timestamp_arguments[@]}" \
            --entitlements "$entitlements" \
            "$target"
    else
        codesign \
            --force \
            --sign "$identity" \
            --options runtime \
            "${timestamp_arguments[@]}" \
            "$target"
    fi
}

if [[ "$is_disk_image" == true ]]; then
    [[ "$adhoc" == false ]] || fail "ad-hoc signing a DMG container is not supported; sign the app before packaging"
    echo "Signing disk image with: $identity"
    codesign \
        --force \
        --sign "$identity" \
        "${timestamp_arguments[@]}" \
        "$target_path"
    codesign --verify --strict --verbose=2 "$target_path"

    disk_image_signature="$(codesign -dvvv "$target_path" 2>&1)"
    if [[ "$use_timestamp" == true ]]; then
        [[ "$disk_image_signature" == *"Authority=Developer ID Application:"* ]] || \
            fail "disk image is not signed with a Developer ID Application certificate"
        [[ "$disk_image_signature" == *"Timestamp="* ]] || \
            fail "disk image signature does not contain a secure timestamp"
    fi

    echo "Signed and verified: $target_path"
    exit 0
fi

native_files=()
while IFS= read -r -d '' candidate; do
    file_type="$(file -b "$candidate" 2>/dev/null || true)"
    if [[ "$file_type" == Mach-O* ]]; then
        native_files+=("$candidate")
    fi
done < <(find "$app_path" -type f -print0)

echo "Signing ${#native_files[@]} Mach-O files with: $identity"
for native_file in "${native_files[@]}"; do
    sign_target "$native_file"
done

# Re-seal nested code bundles after their contents have been modified. `find
# -depth` guarantees that nested bundles are handled before their containers.
while IFS= read -r -d '' code_bundle; do
    sign_target "$code_bundle"
done < <(
    find "$app_path" -depth -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' -o -name '*.app' \) \
        ! -path "$app_path" \
        -print0
)

# Signing without an entitlements file intentionally removes development-only
# entitlements such as com.apple.security.get-task-allow.
sign_target "$app_path"

for native_file in "${native_files[@]}"; do
    codesign --verify --strict "$native_file"
done
codesign --verify --deep --strict --verbose=2 "$app_path"

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
if [[ "$app_entitlements" == *"com.apple.security.get-task-allow"* ]]; then
    fail "the signed app still contains the development-only get-task-allow entitlement"
fi

echo "Signed and verified: $app_path"
