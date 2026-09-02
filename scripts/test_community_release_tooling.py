#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SIGN_SCRIPT = ROOT / "scripts" / "sign_macos_release.sh"
PACKAGE_SCRIPT = ROOT / "scripts" / "package_macos_community_dmg.sh"


class CommunityReleaseToolingTests(unittest.TestCase):
    def test_signer_documents_adhoc_community_signing(self) -> None:
        result = subprocess.run(
            [str(SIGN_SCRIPT), "--help"], check=True, capture_output=True, text=True
        )
        self.assertIn("--adhoc", result.stdout)
        self.assertIn("unnotarized community", result.stdout.lower())

    def test_adhoc_signer_allows_embedded_python_to_load_native_extensions(self) -> None:
        script = SIGN_SCRIPT.read_text()
        self.assertIn("com.apple.security.cs.disable-library-validation", script)
        self.assertIn("*/python/bin/python3.*", script)

    def test_adhoc_signer_allows_app_to_load_adhoc_frameworks(self) -> None:
        script = SIGN_SCRIPT.read_text()
        self.assertIn('if [[ "$adhoc" == true && "$target" == "$app_path" ]]', script)
        self.assertIn('entitlements="$adhoc_app_entitlements"', script)
        self.assertIn('--entitlements "$entitlements"', script)

    def test_signer_is_compatible_with_macos_bash_empty_entitlement_arguments(self) -> None:
        script = SIGN_SCRIPT.read_text()
        self.assertNotIn('"${entitlement_arguments[@]}"', script)
        self.assertIn('local entitlements=""', script)
        self.assertIn('if [[ -n "$entitlements" ]]; then', script)

    def test_packager_exposes_fixed_034_artifact_name_and_size_limit(self) -> None:
        result = subprocess.run(
            [str(PACKAGE_SCRIPT), "--help"], check=True, capture_output=True, text=True
        )
        self.assertIn("Playa-0.3.4-macos-arm64-unnotarized.dmg", result.stdout)
        self.assertIn("314572800", result.stdout)


if __name__ == "__main__":
    unittest.main()
