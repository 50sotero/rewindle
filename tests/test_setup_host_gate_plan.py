"""The check Setup makes just before an install is made as the install will run (with the person's password choice).

When the person picks No password for a new, empty backup location, the install is started with -RepositoryAccess no_password. The plan
Setup asks for just before it must carry the same parameter: without it the installer resolves a password for the location, and refuses
over an old ResticBackuper-RecoveryKey.txt (recovery_key_stale) that an install without a password never reads, so every Install ended
"blocked". The plans the wizard asks for stay as they were: they describe the location alone and never carry the pick.

The setup host's C# (installer/setup, without the window and the program's entry point) is compiled with a console harness,
tests/fixtures/SetupGatePlanHarness.cs, and run on files in a disposable folder: no window, no elevated process, no real installer. See
tests/SetupHostTests.cs (run by tests/Test-SetupHost.ps1 in CI) for the same checks in the host's own suite.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SETUP = PROJECT / "installer" / "setup"
HARNESS = PROJECT / "tests" / "fixtures" / "SetupGatePlanHarness.cs"

# What tests/Test-SetupHost.ps1 leaves out: the program's entry point, the window, the folder chooser's COM interop and the assembly info.
EXCLUDED = ("Program.cs", "SetupWindow.cs", "FolderPicker.cs", "AssemblyInfo.cs")

SCRIPT = r"C:\t\Install-ResticBackuper.ps1"
PLAN_FILE = r"C:\t\plan.json"
CHOICES = [
    "-Repository", r"E:\Rewindle Backups", "-RepositoryStorageMode", "local_ntfs",
]
FOLDERS = ["-SourceList", r"C:\Users\you\Documents", "-Schedule", "02:00"]
SCRIPT_ARGUMENTS = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", SCRIPT]


def pick(access: str | None) -> list[str]:
    return [] if access is None else ["-RepositoryAccess", access]


def plan_arguments(access: str | None) -> list[str]:
    return SCRIPT_ARGUMENTS + ["-PlanOnly", "-PlanOutput", PLAN_FILE] + CHOICES + pick(access) + FOLDERS


@unittest.skipUnless(os.name == "nt", "Setup is Windows-only")
class SetupHostGatePlanTests(unittest.TestCase):
    """The host's pre-install plan, for an install whose person picked No password, driven through the real host code."""

    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        windows = Path(os.environ["WINDIR"])
        framework = windows / "Microsoft.NET" / "Framework64" / "v4.0.30319"
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest(".NET Framework C# compiler is unavailable")
        cls.build_directory = tempfile.TemporaryDirectory(prefix="setup-gate-plan-")
        build = Path(cls.build_directory.name)
        executable = build / "SetupGatePlanHarness.exe"
        references = [
            framework / "System.dll",
            framework / "System.Core.dll",
            framework / "System.Web.Extensions.dll",
            framework / "System.IO.Compression.dll",
            framework / "System.IO.Compression.FileSystem.dll",
            framework / "System.Drawing.dll",
            framework / "WPF" / "WindowsBase.dll",
            framework / "WPF" / "PresentationCore.dll",
            framework / "WPF" / "PresentationFramework.dll",
            windows / "Microsoft.NET" / "assembly" / "GAC_MSIL" / "System.Xaml" / "v4.0_4.0.0.0__b77a5c561934e089" / "System.Xaml.dll",
        ]
        sources = sorted((path for path in SETUP.glob("*.cs") if path.name not in EXCLUDED), key=lambda path: path.name) + [HARNESS]
        no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        compiled = subprocess.run(
            [str(compiler), "/nologo", "/target:exe", "/platform:x64", "/codepage:65001", f"/out:{executable}",
             *[f"/reference:{path}" for path in references], *[str(path) for path in sources]],
            cwd=PROJECT, text=True, capture_output=True, timeout=180, check=False, creationflags=no_window,
        )
        if compiled.returncode != 0:
            raise AssertionError("the setup gate plan harness failed to compile:\n" + compiled.stdout + compiled.stderr)
        work = build / "work"
        work.mkdir()
        # The real PlanRunner starts Windows PowerShell 5.1 (hidden) for a stub installer; a PowerShell 7 module path in this
        # environment would send 5.1 looking for modules it cannot load.
        environment = dict(os.environ)
        environment["PSModulePath"] = str(windows / "System32" / "WindowsPowerShell" / "v1.0" / "Modules")
        completed = subprocess.run(
            [str(executable), str(work)], cwd=PROJECT, text=True, capture_output=True, timeout=300, check=False,
            creationflags=no_window, env=environment,
        )
        if completed.returncode != 0:
            raise AssertionError("the setup gate plan harness failed:\n" + completed.stdout + completed.stderr)
        cls.report = json.loads(completed.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "build_directory"):
            cls.build_directory.cleanup()

    # ---- the arguments -------------------------------------------------------------------------------------------------------------

    def test_the_plan_before_an_install_carries_the_pick_exactly_where_the_install_does(self) -> None:
        lists = self.report["plan_arguments"]
        for access in ("no_password", "password", None):
            with self.subTest(access=access):
                name = access or "none"
                self.assertEqual(plan_arguments(access), lists[f"for_install:{name}"])
                install = lists[f"install:{name}"]
                # What follows -ProgressPath's value in the install is what follows -PlanOutput's in its plan: the same choices, in the same order.
                self.assertEqual(lists[f"for_install:{name}"][9:], install[11:])
                self.assertEqual(access, install[install.index("-RepositoryAccess") + 1] if "-RepositoryAccess" in install else None)

    def test_the_plans_the_wizard_asks_for_never_carry_the_pick(self) -> None:
        lists = self.report["plan_arguments"]
        for access in ("no_password", "password", None):
            with self.subTest(access=access):
                arguments = lists[f"for_wizard:{access or 'none'}"]
                self.assertEqual(plan_arguments(None), arguments)
                self.assertNotIn("-RepositoryAccess", arguments)

    # ---- an install asks for its own check -------------------------------------------------------------------------------------------

    def test_an_install_without_a_password_is_not_blocked_by_the_plan_it_makes_first(self) -> None:
        run = self.report["operation"]["no_password"]
        # The plan source says the old recovery key file is an error when asked without the pick, and says nothing when asked with it.
        self.assertEqual([True], run["asked"])
        self.assertEqual(["no_password"], run["picks"])
        self.assertEqual("succeeded", run["outcome"])
        self.assertEqual(["preparing", "elevating", "running"], run["stages"])
        self.assertEqual(1, run["starts"])
        self.assertEqual("no_password", run["access_given"])
        self.assertIsNone(run["blocked_by"])

    def test_an_install_that_leaves_the_pick_out_is_still_checked_without_it(self) -> None:
        for access in ("password", "none"):
            with self.subTest(access=access):
                run = self.report["operation"][access]
                self.assertEqual([True], run["asked"])
                self.assertEqual([""] if access == "none" else ["password"], run["picks"])
                # With a password (picked, or by default), the same old recovery key file is a real problem: nothing is started.
                self.assertEqual("blocked", run["outcome"])
                self.assertEqual("recovery_key_stale", run["blocked_by"])
                self.assertEqual(["preparing"], run["stages"])
                self.assertEqual(0, run["starts"])
                self.assertIsNone(run["access_given"])

    # ---- the page's own requests, through the bridge ------------------------------------------------------------------------------------

    def test_a_plan_the_page_asks_for_describes_the_location_alone_and_the_install_that_follows_still_goes_ahead(self) -> None:
        bridge = self.report["bridge"]
        # The page's plan request carried a valid password choice; it was asked for as no install's check, and so was made without it.
        self.assertTrue(bridge["wizard_plan_answered"])
        self.assertIs(False, bridge["wizard_plan_ok"])
        # Then the install, with the pick: its own check carries it, and the install is started with it.
        self.assertEqual([False, True], bridge["asked"])
        self.assertEqual(["", "no_password"], bridge["picks"])
        self.assertTrue(bridge["install_started_answer"])
        self.assertEqual("succeeded", bridge["install_outcome"])
        self.assertEqual(1, bridge["starts"])
        self.assertEqual("no_password", bridge["access_given"])

    # ---- the whole chain, with the real plan runner ---------------------------------------------------------------------------------------

    def runner_report(self) -> dict:
        if not self.report["runner_available"]:
            self.skipTest("Windows PowerShell is unavailable")
        return self.report["runner"]

    def test_the_real_plan_runner_gives_the_installer_the_pick_for_an_install_only(self) -> None:
        runner = self.runner_report()
        picked = runner["install_no_password"]
        self.assertEqual(["access=no_password"], picked["stub_received"])
        self.assertEqual("succeeded", picked["outcome"])
        self.assertEqual(1, picked["starts"])
        self.assertEqual("no_password", picked["access_given"])
        unpicked = runner["install_no_pick"]
        self.assertEqual(["access="], unpicked["stub_received"])
        self.assertEqual("blocked", unpicked["outcome"])
        self.assertEqual("recovery_key_stale", unpicked["blocked_by"])
        self.assertEqual(0, unpicked["starts"])

    def test_the_real_plan_runner_keeps_the_two_kinds_of_plan_apart(self) -> None:
        runner = self.runner_report()
        # The same inputs, one after the other: the wizard's plan has no pick and finds the key file; the install's check has it and does not.
        self.assertEqual(["access="], runner["wizard_plan"]["stub_received"])
        self.assertIs(False, runner["wizard_plan"]["plan_allows_install"])
        self.assertEqual(["access=no_password"], runner["install_plan"]["stub_received"])
        self.assertIs(True, runner["install_plan"]["plan_allows_install"])


if __name__ == "__main__":
    unittest.main()
