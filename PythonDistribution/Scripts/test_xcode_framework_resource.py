#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("build_xcode_framework_resource.py")
SPEC = importlib.util.spec_from_file_location("build_xcode_framework_resource", SCRIPT)
assert SPEC and SPEC.loader
resource_builder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = resource_builder
SPEC.loader.exec_module(resource_builder)


class XcodeFrameworkResourceTests(unittest.TestCase):
    def test_release_build_enables_distribution_pruning(self) -> None:
        with patch.dict(os.environ, {"CONFIGURATION": "Release"}, clear=False):
            command = resource_builder.distribution_build_command(Path("/tmp/output"))
        self.assertIn("--prune-release", command)

    def test_debug_build_keeps_development_content(self) -> None:
        with patch.dict(os.environ, {"CONFIGURATION": "Debug"}, clear=False):
            command = resource_builder.distribution_build_command(Path("/tmp/output"))
        self.assertNotIn("--prune-release", command)


if __name__ == "__main__":
    unittest.main()
