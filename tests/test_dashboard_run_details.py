from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
HARNESS = PROJECT / "tests" / "fixtures" / "RunDetailsHarness.cs"


@unittest.skipUnless(os.name == "nt", "dashboard run-details reader is Windows-only")
class DashboardRunDetailsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        framework = (
            Path(os.environ["WINDIR"])
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest(".NET Framework C# compiler is unavailable")
        cls.build_directory = tempfile.TemporaryDirectory(prefix="run-details-csharp-")
        cls.executable = Path(cls.build_directory.name) / "RunDetailsHarness.exe"
        references = [
            framework / "System.dll",
            framework / "System.Core.dll",
            framework / "System.Web.Extensions.dll",
            framework / "WPF" / "WindowsBase.dll",
            framework / "WPF" / "PresentationCore.dll",
            framework / "WPF" / "PresentationFramework.dll",
            Path(os.environ["WINDIR"])
            / "Microsoft.NET"
            / "assembly"
            / "GAC_MSIL"
            / "System.Xaml"
            / "v4.0_4.0.0.0__b77a5c561934e089"
            / "System.Xaml.dll",
        ]
        sources = [
            DASHBOARD / "EngineProfile.cs",
            DASHBOARD / "AtomicFile.cs",
            DASHBOARD / "DashboardMotion.cs",
            DASHBOARD / "SourceConfiguration.cs",
            DASHBOARD / "Telemetry.cs",
            DASHBOARD / "DashboardTheme.cs",
            DASHBOARD / "DashboardVisualStyle.cs",
            DASHBOARD / "RunDetailsWindow.cs",
            HARNESS,
        ]
        completed = subprocess.run(
            [
                str(compiler),
                "/nologo",
                "/target:exe",
                "/platform:x64",
                f"/out:{cls.executable}",
                *[f"/reference:{path}" for path in references],
                *[str(path) for path in sources],
            ],
            cwd=PROJECT,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                "run-details harness failed to compile:\n"
                + completed.stdout
                + completed.stderr
            )

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "build_directory"):
            cls.build_directory.cleanup()

    def test_reader_loads_bounded_failure_details_and_rejects_traversal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="run-details-") as root:
            completed = subprocess.run(
                [str(self.executable), root],
                cwd=PROJECT,
                text=True,
                capture_output=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(completed.stdout)
            self.assertEqual(result["phase"], "backup")
            self.assertEqual(result["failure_code"], "source_data_unreadable")
            self.assertEqual(result["exit_code"], "3")
            self.assertEqual(len(result["snapshot_id"]), 64)
            self.assertEqual(len(result["affected_paths"]), 1)
            self.assertTrue(result["has_log"])
            self.assertTrue(result["traversal_rejected"])
            event_text = "\n".join(result["events"])
            self.assertIn("failure", event_text)
            self.assertNotIn("must not be displayed", event_text)
            self.assertIn("affected paths", result["remediation"].casefold())

    def test_ui_supports_button_double_click_keyboard_copy_and_open(self) -> None:
        window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        details = (DASHBOARD / "RunDetailsWindow.cs").read_text(encoding="utf-8")
        build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")
        for evidence in (
            'viewRunDetailsButton = CreateButton("Open details")',
            "OnHistoryMouseDoubleClick",
            "OnHistoryPreviewKeyDown",
            "RunDetailsReader.Load",
            "RunDetailsWindow",
        ):
            self.assertIn(evidence, window)
        for evidence in (
            'Button("Copy summary")',
            'Button("Open log location")',
            "MaximumTailBytes",
            "MaximumEvents",
            "ConfinedPath",
            "FileAttributes.ReparsePoint",
        ):
            self.assertIn(evidence, details)
        self.assertIn("RunDetailsWindow.cs", build)


if __name__ == "__main__":
    unittest.main()
