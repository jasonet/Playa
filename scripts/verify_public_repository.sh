#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repository_root"

required_files=(README.md LICENSE CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md project.yml)
for path in "${required_files[@]}"; do
    [[ -f "$path" ]] || { echo "error: missing $path" >&2; exit 1; }
done

for ignored in Configuration/Signing.local.xcconfig build dist DerivedData .venv .cache; do
    if git ls-files --error-unmatch "$ignored" >/dev/null 2>&1; then
        echo "error: local or generated path is tracked: $ignored" >&2
        exit 1
    fi
done

tracked_sensitive='(^|/)(Signing\.local\.xcconfig|\.env($|\.)|.*\.(p8|p12|pem|key))$'
if git ls-files | grep -E "$tracked_sensitive"; then
    echo "error: a sensitive credential file is tracked" >&2
    exit 1
fi

forbidden='ydtang@mac\.com|E7RVFY97DK|V8MWN7GKJ5|github\.com/Blaizzy/nativ|marvis-labs\.github\.io/nativ|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}'
if rg -n -i --hidden \
    --glob '!.git/**' \
    --glob '!build/**' \
    --glob '!dist/**' \
    --glob '!DerivedData/**' \
    --glob '!scripts/verify_public_repository.sh' \
    "$forbidden" .; then
    echo "error: forbidden private or legacy value found" >&2
    exit 1
fi

legacy_product='\\bNativ\\b|\\bNATIV_[A-Z0-9_]+\\b|dev\\.local\\.Nativ'
if rg -n --hidden --glob '!.git/**' --glob '!LICENSE' "$legacy_product" .; then
    echo "error: legacy product identifier found" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain --ignored | awk '$1 == "!!" {print $2}' | grep -E '(^|/)(Signing\.local\.xcconfig|\.env($|\.)|.*\.(p8|p12|pem|key))$' || true)" ]]; then
    echo "Verified ignored local credential files."
fi

echo "PASS: public repository hygiene checks succeeded."
