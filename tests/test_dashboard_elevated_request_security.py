from __future__ import annotations

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
SHARED = DASHBOARD / "ElevatedRequestSecurity.cs"
HARNESS = PROJECT / "tests" / "fixtures" / "ElevatedRequestSecurityHarness.cs"

# The helpers that bind or launch an elevated request. Each exists once, in ElevatedRequestSecurity.cs.
HELPER_DEFINITION = re.compile(
    r"\bstatic\s+[\w<>\[\],. ]+?\s+"
    r"(QuoteWindowsArgument|QuoteArgument|Quote|BuildArgumentString|JoinArguments|CreateNonce|FixedEquals|"
    r"HasProtectedResultAcl|HasProtectedAcl)\s*\("
)
# Opening a log in File Explorer runs with standard rights and uses Explorer's own "/select," syntax, not a manager's.
ALLOWED_DEFINITIONS = {("RunDetailsWindow.cs", "Quote")}
QUOTING_CHARACTER_SET = re.compile(r"IndexOfAny\(\s*new\s*(?:char)?\s*\[\]\s*\{\s*' '\s*,\s*'\\t'")
CONSUMERS = (
    "BackupCancellationController.cs",
    "BackupTaskController.cs",
    "RecoveryHealthManager.cs",
    "RepositoryManager.cs",
    "RestoreManager.cs",
    "ScheduleManagerLauncher.cs",
    "SourceConfiguration.cs",
)


def dashboard_sources() -> dict[str, str]:
    return {path.name: path.read_text(encoding="utf-8") for path in sorted(DASHBOARD.glob("*.cs"))}


def shared_users() -> set[str]:
    return {
        name
        for name, text in dashboard_sources().items()
        if name != SHARED.name and "ElevatedRequestSecurity." in text
    }


def stored_blob(path: Path) -> bytes:
    """The file as git stores it (its staged copy, the same as HEAD on a clean checkout).

    A checkout may rewrite line endings (core.autocrlf=true writes CR LF), so the line endings a
    file is published with can only be read from the stored copy, not from the working tree.
    """
    relative = path.relative_to(PROJECT).as_posix()
    result = subprocess.run(
        ["git", "cat-file", "blob", f":{relative}"],
        cwd=PROJECT,
        capture_output=True,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"git has no stored copy of {relative}: " + result.stderr.decode("utf-8", "replace").strip()
        )
    return result.stdout


class ElevatedRequestSecurityBehaviorTests(unittest.TestCase):
    def test_shared_checks_quote_strictly_and_require_full_control(self) -> None:
        if os.name != "nt":
            self.skipTest("the dashboard is Windows-only")
        framework = (
            Path(os.environ.get("SystemRoot", r"C:\Windows"))
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            self.skipTest(".NET Framework C# compiler is unavailable")
        with tempfile.TemporaryDirectory(prefix="elevated-request-security-") as root_text:
            executable = Path(root_text) / "ElevatedRequestSecurityHarness.exe"
            compiled = subprocess.run(
                [
                    str(compiler),
                    "/nologo",
                    "/target:exe",
                    "/platform:x64",
                    "/warn:4",
                    "/warnaserror+",
                    f"/out:{executable}",
                    f"/reference:{framework / 'System.dll'}",
                    f"/reference:{framework / 'System.Core.dll'}",
                    str(SHARED),
                    str(HARNESS),
                ],
                cwd=PROJECT,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            self.assertEqual(0, compiled.returncode, compiled.stdout + compiled.stderr)
            run = subprocess.run(
                [str(executable)],
                cwd=PROJECT,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(0, run.returncode, run.stdout + run.stderr)
            self.assertIn("Elevated request security checks passed.", run.stdout)


class ElevatedRequestSecuritySourceTests(unittest.TestCase):
    def test_no_class_keeps_its_own_copy_of_a_shared_check(self) -> None:
        copies = []
        for name, text in dashboard_sources().items():
            if name == SHARED.name:
                continue
            for match in HELPER_DEFINITION.finditer(text):
                if (name, match.group(1)) not in ALLOWED_DEFINITIONS:
                    line = text.count("\n", 0, match.start()) + 1
                    copies.append(f"{name}:{line} {match.group(1)}")
            if QUOTING_CHARACTER_SET.search(text):
                copies.append(f"{name}: its own command-line quoting")
        self.assertEqual([], copies)

    def test_every_launcher_uses_the_shared_class(self) -> None:
        self.assertTrue(SHARED.is_file())
        users = shared_users()
        for name in CONSUMERS:
            self.assertIn(name, users)
        text = SHARED.read_text(encoding="utf-8")
        for member in (
            "internal static string QuoteWindowsArgument(string value)",
            "internal static string BuildArgumentString(IEnumerable<string> arguments)",
            "internal static string CreateNonce()",
            "internal static bool FixedEquals(string left, string right)",
            "internal static bool HasProtectedResultAcl(string path, string userSid, bool directory)",
            "internal static bool HasProtectedResultAcl(FileSystemSecurity security, string userSid)",
        ):
            self.assertIn(member, text)

    def test_every_elevated_command_line_comes_from_the_shared_builder(self) -> None:
        elevated = 0
        for name, text in dashboard_sources().items():
            if not re.search(r'\.Verb\s*=\s*"runas"', text):
                continue
            elevated += 1
            for match in re.finditer(r"\.Arguments\s*=\s*([^;]+);", text):
                self.assertIn(
                    "ElevatedRequestSecurity.",
                    match.group(1),
                    f"{name} builds an elevated command line by hand: {match.group(0)}",
                )
        self.assertGreaterEqual(elevated, len(CONSUMERS))

    def test_the_shared_file_is_compiled_wherever_its_users_are(self) -> None:
        build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")
        missing = []
        if "(Join-Path $project 'ElevatedRequestSecurity.cs')" not in build:
            missing.append("src/dashboard/build.ps1")
        users = shared_users()
        for path in sorted((PROJECT / "tests").glob("test_*.py")):
            text = path.read_text(encoding="utf-8")
            if "csc" not in text:
                continue
            if any(f'"{name}"' in text for name in users) and '"ElevatedRequestSecurity.cs"' not in text:
                missing.append(path.name)
        scripts = sorted((PROJECT / "tests").glob("*.ps1")) + sorted((DASHBOARD / "tests").glob("*.ps1"))
        for path in scripts:
            text = path.read_text(encoding="utf-8-sig")
            if "Add-Type" not in text:
                continue
            if any(f"src\\dashboard\\{name}'" in text for name in users) and (
                "src\\dashboard\\ElevatedRequestSecurity.cs'" not in text
            ):
                missing.append(path.name)
        self.assertEqual([], missing)

    def test_shared_file_is_ascii_without_a_byte_order_mark(self) -> None:
        for path in (SHARED, HARNESS):
            data = path.read_bytes()
            self.assertFalse(data.startswith(b"\xef\xbb\xbf"), path.name)
            data.decode("ascii")
            # LF only, in the copy git publishes; the working copy's line endings follow the checkout's settings.
            self.assertEqual(0, stored_blob(path).count(b"\r"), f"{path.name} is stored with a carriage return")


if __name__ == "__main__":
    unittest.main()
