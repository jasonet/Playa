#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("build_mlx_vlm_server.py")
SPEC = importlib.util.spec_from_file_location("build_mlx_vlm_server", SCRIPT)
assert SPEC and SPEC.loader
builder = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = builder
SPEC.loader.exec_module(builder)


class ReleasePruningTests(unittest.TestCase):
    def test_prune_distribution_removes_only_distribution_development_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "mlx-vlm-server"
            python = output / "python"
            site_packages = python / "lib" / "python3.12" / "site-packages"

            removable_directories = [
                python / "include",
                python / "lib" / "python3.12" / "ensurepip",
                python / "lib" / "python3.12" / "idlelib",
                python / "lib" / "python3.12" / "tkinter",
                python / "lib" / "python3.12" / "turtledemo",
                site_packages / "pip",
                site_packages / "numpy" / "tests",
                site_packages / "pandas" / "tests",
                site_packages / "example_package" / "test",
                site_packages / "example_package" / "__pycache__",
            ]
            removable_files = [
                python / "lib" / "python3.12" / "module.pyc",
                site_packages / "example_package" / "cached.pyo",
            ]
            retained_files = [
                python / "bin" / "python3",
                site_packages / "mlx" / "lib" / "mlx.metallib",
                site_packages / "mlx_vlm" / "server" / "openai.py",
                site_packages / "cv2" / "__init__.py",
                site_packages / "example_package" / "testing.py",
                site_packages / "example_package" / "contest.py",
            ]

            for directory in removable_directories:
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "placeholder.txt").write_text("remove me")
            for file_path in removable_files + retained_files:
                file_path.parent.mkdir(parents=True, exist_ok=True)
                file_path.write_text("retain me" if file_path in retained_files else "remove me")

            summary = builder.prune_distribution(output)

            for path in removable_directories + removable_files:
                self.assertFalse(path.exists(), f"expected pruning to remove {path}")
            for path in retained_files:
                self.assertTrue(path.exists(), f"expected pruning to retain {path}")
            self.assertGreaterEqual(summary.removed_directories, len(removable_directories))
            self.assertEqual(summary.removed_bytecode_files, len(removable_files))
            self.assertGreater(summary.removed_bytes, 0)

    def test_build_signature_records_release_pruning_mode(self) -> None:
        parameters = builder.build_signature.__annotations__
        self.assertIn("prune_release", parameters)

    def test_shell_launcher_never_writes_bytecode_into_signed_bundle(self) -> None:
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", builder.launcher_contents())


if __name__ == "__main__":
    unittest.main()
