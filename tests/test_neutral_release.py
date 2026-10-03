"""Source checks for the public release: one version source, nothing written for one person's setup."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class SingleVersionSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.version = read(PROJECT / "VERSION").strip()

    def test_web_package_carries_the_version_file(self) -> None:
        package = json.loads(read(WEB / "package.json"))
        lock = json.loads(read(WEB / "package-lock.json"))
        self.assertEqual("rewindle-dashboard", package["name"])
        self.assertEqual(self.version, package["version"])
        self.assertEqual(("rewindle-dashboard", self.version), (lock["name"], lock["version"]))
        self.assertEqual(("rewindle-dashboard", self.version), (lock["packages"][""]["name"], lock["packages"][""]["version"]))

    def test_binaries_take_their_version_from_the_build(self) -> None:
        for path in (
            DASHBOARD / "AssemblyInfo.cs",
            PROJECT / "src" / "task_launcher" / "AssemblyInfo.cs",
            PROJECT / "installer" / "RewindleSetup.cs",
        ):
            with self.subTest(path=path.name):
                text = read(path)
                self.assertNotRegex(text, r"\[assembly:\s*Assembly(File|Informational)?Version\(")
                self.assertIn('AssemblyCompany("Victor Sotero")', text)
                self.assertIn('AssemblyCopyright("Copyright (c) 2026 Victor Sotero")', text)
                self.assertNotIn("-personal", text.lower())
        self.assertIn('assemblyIdentity version="0.0.0.0"', read(DASHBOARD / "app.manifest"))
        helper = read(PROJECT / "build" / "RewindleVersion.ps1")
        self.assertIn("AssemblyInformationalVersion", helper)
        for script in (
            DASHBOARD / "build.ps1",
            PROJECT / "src" / "task_launcher" / "build.ps1",
            PROJECT / "build" / "Build-Release.ps1",
        ):
            with self.subTest(script=script.name):
                self.assertIn("RewindleVersion.ps1", read(script))
        self.assertIn("Assert-ReleaseBinaryVersion $setupArtifactPath", read(PROJECT / "build" / "Build-Release.ps1"))

    def test_dashboard_answers_version_and_help(self) -> None:
        program = read(DASHBOARD / "Program.cs")
        for marker in ('"--version"', '"--help"', "AssemblyInformationalVersionAttribute", "MessageBox.Show(text"):
            self.assertIn(marker, program)
        self.assertIn('setup["appVersion"] = Program.DisplayVersion();', read(DASHBOARD / "DashboardWindow.Web.cs"))


class NeutralDashboardTests(unittest.TestCase):
    def test_no_literal_drive_or_repository_binding(self) -> None:
        for name in ("EngineProfile.cs", "Telemetry.cs"):
            with self.subTest(name=name):
                text = read(DASHBOARD / name)
                self.assertIsNone(re.search(r'@?"[A-Za-z]:\\', text), "a literal drive path is back")
                self.assertNotIn("FixedCloud", text)
                self.assertNotIn("ResticBackups", text)
        self.assertIn("SourceConfiguration.Load().RepositoryPath", read(DASHBOARD / "Telemetry.cs"))

    def test_protected_folders_keep_their_own_names(self) -> None:
        text = read(DASHBOARD / "SourceConfiguration.cs")
        for nickname in ("Software projects", "Codex configuration", "Google Drive - My Drive", '".codex"', '"code"'):
            self.assertNotIn(nickname, text)
        for known in ('"Desktop"', '"Documents"', '"Pictures"', '"Music"', '"Videos"', '"Favorites"'):
            self.assertIn(known, text)

    def test_off_site_card_names_a_provider_only_when_told(self) -> None:
        health = read(WEB / "components" / "primitives" / "ProtectionHealth.tsx")
        self.assertIn("label: 'Off-site copy'", health)
        self.assertIn("NotConfigured: 'Not set up (optional)'", health)
        self.assertIn("cloud.provider", health)
        # No provider is written into the page's own words; comments may name one as an example.
        code = re.sub(r"/\*.*?\*/", "", health, flags=re.S)
        code = re.sub(r"(?m)^\s*//.*$", "", code)
        self.assertNotIn("Google Drive", code, "the off-site card names a provider itself")
        self.assertNotIn("Cloud copy", health)
        self.assertIn('offsite["provider"]', read(DASHBOARD / "DashboardWindow.Web.cs"))

    def test_sidebar_is_a_static_lockup(self) -> None:
        sidebar = read(WEB / "components" / "primitives" / "SidebarNav.tsx")
        app = read(WEB / "src" / "App.tsx")
        for gone in ("WorkspaceMenu", "createPortal", "data-workspace-menu", "onWorkspaceSettings"):
            self.assertNotIn(gone, sidebar)
        self.assertIn("./rewindle-icon.svg", sidebar)
        self.assertNotIn('className="breadcrumb"', app)
        self.assertNotIn("Personal", app + sidebar)

    def test_about_section_and_licenses_command(self) -> None:
        app = read(WEB / "src" / "App.tsx")
        for marker in ("About Rewindle", "MIT License", "Powered by Restic", "PROJECT_URL", "openLicensesFolder",
                       "Closing this window never stops a running backup."):
            self.assertIn(marker, app)
        web_sources = [path for path in (WEB / "src").rglob("*.ts*")] + [path for path in (WEB / "components").rglob("*.tsx")]
        defined = [path.name for path in web_sources if "https://github.com/50sotero/rewindle" in read(path)]
        self.assertEqual(["project.ts"], defined, "the project address must be written in one place")
        host = read(DASHBOARD / "DashboardWindow.Web.cs")
        handler = host[host.index("private static bool OpenLicensesFolder"):]
        handler = handler[: handler.index("\n        }\n") + 10]
        self.assertIn('Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "licenses")', handler)
        self.assertNotIn("payload", handler)

    def test_installer_offers_no_personal_default_folders(self) -> None:
        installer = read(PROJECT / "installer" / "Install-ResticBackuper.ps1")
        defaults = installer[installer.index("function Get-DefaultSources"):]
        defaults = defaults[: defaults.index("\n}\n")]
        self.assertNotIn(".codex", defaults)
        self.assertNotIn("'code'", defaults)


if __name__ == "__main__":
    unittest.main()
