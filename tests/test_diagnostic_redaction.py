from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
HARNESS = PROJECT / "tests" / "fixtures" / "DiagnosticExporterHarness.cs"


@unittest.skipUnless(os.name == "nt", "dashboard diagnostic exporter is Windows-only")
class DiagnosticRedactionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        framework = (
            Path(os.environ["WINDIR"])
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        cls.compiler = framework / "csc.exe"
        if not cls.compiler.is_file():
            raise unittest.SkipTest(".NET Framework C# compiler is unavailable")
        cls.framework = framework
        cls.build_directory = tempfile.TemporaryDirectory(prefix="diagnostic-csharp-")
        cls.executable = Path(cls.build_directory.name) / "DiagnosticHarness.exe"
        sources = [
            DASHBOARD / "EngineProfile.cs",
            DASHBOARD / "AtomicFile.cs",
            DASHBOARD / "CrashLog.cs",
            DASHBOARD / "ElevatedRequestSecurity.cs",
            DASHBOARD / "SourceConfiguration.cs",
            DASHBOARD / "ProcessLiveness.cs",
            DASHBOARD / "Telemetry.cs",
            DASHBOARD / "TaskSchedule.cs",
            DASHBOARD / "DiagnosticExporter.cs",
            HARNESS,
        ]
        references = [
            framework / "System.dll",
            framework / "System.Core.dll",
            framework / "System.Xml.dll",
            framework / "System.Web.Extensions.dll",
            framework / "System.IO.Compression.dll",
            framework / "System.IO.Compression.FileSystem.dll",
        ]
        command = [
            str(cls.compiler),
            "/nologo",
            "/target:exe",
            "/platform:x64",
            "/optimize+",
            f"/out:{cls.executable}",
            *[f"/reference:{path}" for path in references],
            *[str(path) for path in sources],
        ]
        completed = subprocess.run(
            command,
            cwd=PROJECT,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                "diagnostic harness failed to compile:\n"
                + completed.stdout
                + completed.stderr
            )

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "build_directory"):
            cls.build_directory.cleanup()

    def run_harness(self, root: Path, mode: str, access: str | None = None) -> dict[str, object]:
        completed = subprocess.run(
            [str(self.executable), str(root), mode, *([access] if access is not None else [])],
            cwd=PROJECT,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout.strip())

    def test_export_removes_seeded_secrets_identities_paths_and_commands(self) -> None:
        with tempfile.TemporaryDirectory(prefix="diagnostic-export-") as root_text:
            root = Path(root_text)
            result = self.run_harness(root, "safe")
            self.assertTrue(result["succeeded"], result.get("error"))
            archive_path = Path(str(result["path"]))
            self.assertTrue(archive_path.is_file())
            with zipfile.ZipFile(archive_path) as archive:
                names = set(archive.namelist())
                self.assertIn("manifest.json", names)
                self.assertIn("configuration.json", names)
                self.assertIn("status.json", names)
                self.assertIn("latest-run-log-events.json", names)
                self.assertIn("redaction-report.json", names)
                self.assertIn("runtime-manifest.json", names)
                payload = "\n".join(
                    archive.read(name).decode("utf-8") for name in names
                )
                report = json.loads(
                    archive.read("redaction-report.json").decode("utf-8")
                )
            visible_payload = payload.replace("\\u003c", "<").replace(
                "\\u003e", ">"
            )

            for forbidden in (
                "Winter!Fixture-Password-489",
                "fixture-host-7762",
                "fixture-user-8831",
                "private.fixture@example.invalid",
                str(root),
                "Q" * 100,
                "--password-file",
                "S-1-5-21-111-222-333-1001",
                "Cloud-Repository-Fixture-9032",
                "Cloud-Canary-Fixture-9032",
                "Cloud-Remote-Fixture-9032",
                "c" * 64,
                "d" * 64,
                "e" * 64,
                "f" * 64,
                "7" * 64,
            ):
                self.assertNotIn(forbidden.casefold(), visible_payload.casefold())
            self.assertNotRegex(visible_payload, re.compile(r"[A-Za-z]:\\\\"))
            self.assertIn("<repository-path>", visible_payload)
            self.assertIn("<source-path:1>", visible_payload)
            self.assertGreater(report["paths_redacted"], 0)
            self.assertGreater(report["secrets_redacted"], 0)
            self.assertGreater(report["identities_redacted"], 0)
            self.assertFalse(report["original_values_included"])

    def test_how_the_backups_are_opened_stays_visible_in_the_export(self) -> None:
        # "repository_access" says whether the backups have a password. It is what a person reading the bundle needs to know first, and
        # nothing in it is secret: the key's name holds none of the words the redactor hides (password, secret, credential, dpapi,
        # recovery_key), so its value must come through as it is, in the configuration and in the run's status, in both modes.
        def values(node: object, key: str) -> list[object]:
            found: list[object] = []
            if isinstance(node, dict):
                for name, value in node.items():
                    if name == key:
                        found.append(value)
                    found.extend(values(value, key))
            elif isinstance(node, list):
                for item in node:
                    found.extend(values(item, key))
            return found

        for access in ("password", "no_password"):
            with self.subTest(access=access), tempfile.TemporaryDirectory(prefix="diagnostic-access-") as root_text:
                result = self.run_harness(Path(root_text), "safe", access)
                self.assertTrue(result["succeeded"], result.get("error"))
                with zipfile.ZipFile(Path(str(result["path"]))) as archive:
                    for name in ("configuration.json", "status.json"):
                        with self.subTest(document=name):
                            document = json.loads(archive.read(name).decode("utf-8"))
                            self.assertEqual(values(document, "repository_access"), [access])

    def test_a_configuration_from_before_the_choice_exports_without_inventing_one(self) -> None:
        with tempfile.TemporaryDirectory(prefix="diagnostic-owner-") as root_text:
            result = self.run_harness(Path(root_text), "safe")
            self.assertTrue(result["succeeded"], result.get("error"))
            with zipfile.ZipFile(Path(str(result["path"]))) as archive:
                for name in ("configuration.json", "status.json"):
                    with self.subTest(document=name):
                        self.assertNotIn("repository_access", archive.read(name).decode("utf-8"))

    def test_export_rejects_source_destination_and_never_overwrites(self) -> None:
        with tempfile.TemporaryDirectory(prefix="diagnostic-safety-") as root_text:
            root = Path(root_text)
            unsafe = self.run_harness(root, "unsafe")
            self.assertFalse(unsafe["succeeded"])
            self.assertIn("cannot be saved inside a protected folder", str(unsafe["error"]))
            self.assertFalse(Path(str(unsafe["destination"])).exists())

            safe = self.run_harness(root, "safe")
            self.assertTrue(safe["succeeded"], safe.get("error"))
            first_bytes = Path(str(safe["path"])).read_bytes()
            repeated = self.run_harness(root, "safe")
            self.assertFalse(repeated["succeeded"])
            self.assertIn("never overwritten", str(repeated["error"]))
            self.assertEqual(Path(str(safe["path"])).read_bytes(), first_bytes)


if __name__ == "__main__":
    unittest.main()
