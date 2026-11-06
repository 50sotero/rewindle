"""Every script that runs elevated, or at the Highest run level, pins the PowerShell module path before any command.

Windows PowerShell 5.1 looks for the module behind an ordinary command (Get-Item, Test-Path, Join-Path, Import-Clixml,
New-Object, Get-FileHash...) in the person's Documents\\WindowsPowerShell\\Modules before Windows' own folder, and loads
it from the first folder that has one. Any program the person runs can write there. So an elevated script that runs one
of those commands before it pins the path can run that program's code with administrator rights; a module-qualified
name is no help, because a module of the same name earlier on the path wins too.

The rule: the first statement after param() is
    $trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
    $env:PSModulePath = $trustedModuleRoot
and the param block itself runs no command. The static checks read the scripts; the behaviour checks run two of them
with a stand-in module first on the path, in a temporary folder, and never touch Documents or an installed copy.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]

# Every script under src\ and installer\ that runs elevated, at the Highest run level, or as a child of such a process,
# and how it starts.
ELEVATED = {
    "installer/Install-ResticBackuper.ps1": "Setup's elevated bootstrap, or Install.cmd and its own UAC self-elevation",
    "installer/Uninstall-ResticBackuper.ps1": "Installed apps (UninstallString) or Setup, elevated, or itself (UAC)",
    "src/Manage-Backup.ps1": "the dashboard, through UAC",
    "src/Manage-Repository.ps1": "the dashboard, through UAC",
    "src/Manage-Restore.ps1": "the dashboard, through UAC",
    "src/Manage-Schedule.ps1": "the dashboard, through UAC",
    "src/Manage-Sources.ps1": "the dashboard, through UAC",
    "src/install_google_drive_sync_task.ps1": "an administrator (docs/google-drive-direct-verification.md)",
    "src/verify_my_drive_cloud_repository.ps1": "the daily 03:00 Google Drive check, a task at the Highest run level",
    "src/reveal-rclone-config-password.ps1": "rclone's password command, started by that check's elevated rclone",
}
# Every other script there, and why it never runs elevated.
NOT_ELEVATED = {
    "src/sync_repository_to_google_drive.ps1": "retired: not in the release payload, and refused as a task action",
    "src/dashboard/tests/restore-flow-regressions.ps1": "a test, run by a developer or CI",
    "src/dashboard/build.ps1": "a developer's build script",
    "src/task_launcher/build.ps1": "a developer's build script",
    "installer/setup/build.ps1": "a developer's build script",
}
# Folders the builds fill; nothing in them is a source script.
GENERATED = {"node_modules", "dist", "build-output", "obj", ".packages", "__pycache__"}

PIN = re.compile(
    r"\A\s*\$trustedModuleRoot\s*=\s*\[IO\.Path\]::Combine\(\s*\[Environment\]::SystemDirectory\s*,\s*"
    r"'WindowsPowerShell'\s*,\s*'v1\.0'\s*,\s*'Modules'\s*\)\s*[\r\n;]\s*"
    r"\$env:PSModulePath\s*=\s*\$trustedModuleRoot\s*(?:[\r\n;]|\Z)"
)
COMMAND = re.compile(r"\b[A-Za-z]+-[A-Za-z]+\b")


def scripts_under(*folders: str) -> set[str]:
    found = set()
    for folder in folders:
        for root, directories, files in os.walk(PROJECT / folder):
            directories[:] = [name for name in directories if name not in GENERATED]
            for name in files:
                if name.lower().endswith(".ps1"):
                    found.add((Path(root) / name).relative_to(PROJECT).as_posix())
    return found


def code_only(text: str, blank_strings: bool) -> str:
    """The script with comments blanked and, if asked, string contents blanked too (same length, so offsets match)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("<#", i):
            end = text.find("#>", i + 2)
            end = n if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        elif c == "#":
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif text.startswith("@'", i) or text.startswith('@"', i):
            close = "\n" + text[i + 1] + "@"
            end = text.find(close, i + 2)
            end = n if end < 0 else end + len(close)
            body = text[i + 2:end - 2]
            out.append(text[i:i + 2] + (re.sub(r"[^\n]", " ", body) if blank_strings else body) + text[end - 2:end])
            i = end
        elif c in "'\"":
            j = i + 1
            while j < n:
                if c == '"' and text[j] == "`":
                    j += 2
                    continue
                if text[j] == c:
                    if j + 1 < n and text[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            body = text[i + 1:j]
            out.append(c + (re.sub(r"[^\n]", " ", body) if blank_strings else body) + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def split_param_block(code: str) -> tuple[str, int]:
    """(the script's param block, where the code after it starts); an empty block when the script has none."""
    match = re.match(r"\s*(?:\[CmdletBinding\b[^\]]*\]\s*)?param\s*\(", code, re.IGNORECASE)
    if not match:
        return "", 0
    depth, i = 1, match.end()
    while depth:
        depth += {"(": 1, ")": -1}.get(code[i], 0)
        i += 1
    return code[match.start():i], i


def first_line(code: str) -> str:
    lines = code.strip().splitlines()
    return lines[0][:100] if lines else "(nothing)"


def csharp_literal(text: str) -> str:
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "r": "\r", "t": "\t"}.get(m.group(1), m.group(1)), text)


class ElevatedScriptInventoryTests(unittest.TestCase):
    def test_every_script_is_classified(self) -> None:
        self.assertEqual(set(), set(ELEVATED) & set(NOT_ELEVATED))
        self.assertEqual(sorted(set(ELEVATED) | set(NOT_ELEVATED)), sorted(scripts_under("src", "installer")))

    def test_managers_and_installer_scripts_count_as_elevated(self) -> None:
        # By pattern, so a new manager or installer script cannot be filed as not elevated.
        for path in list(PROJECT.glob("src/Manage-*.ps1")) + list(PROJECT.glob("installer/*.ps1")):
            with self.subTest(script=path.name):
                self.assertIn(path.relative_to(PROJECT).as_posix(), ELEVATED)

    def test_every_script_the_release_ships_counts_as_elevated(self) -> None:
        # Anything in the payload lands in Program Files, where an elevated process may run it.
        builder = (PROJECT / "build" / "Build-Release.ps1").read_text(encoding="utf-8")
        payload = re.search(r"foreach \(\$name in @\((.*?)\)\) \{\s*Copy-PayloadFile", builder, re.S)
        self.assertIsNotNone(payload)
        shipped = re.findall(r"'([^'\\/]+\.ps1)'", payload.group(1))
        self.assertIn("Manage-Sources.ps1", shipped)
        for name in shipped:
            with self.subTest(script=name):
                self.assertIn("src/" + name, ELEVATED)


class ElevatedModulePathTests(unittest.TestCase):
    def test_elevated_scripts_pin_the_module_path_first(self) -> None:
        for relative in sorted(ELEVATED):
            with self.subTest(script=relative):
                text = (PROJECT / relative).read_text(encoding="utf-8-sig")
                self.assertNotRegex(text, r"(?im)^\s*#requires\b.*-Modules\b", "#requires -Modules loads modules")
                self.assertNotRegex(text, r"(?im)^\s*using\s+module\b", "using module loads a module first")
                param, after = split_param_block(code_only(text, blank_strings=True))
                self.assertNotIn("ValidateScript", param, "a ValidateScript runs before the pin")
                self.assertEqual([], COMMAND.findall(param), "the param block runs a command before the pin")
                self.assertNotIn("&", param, "the param block runs a command before the pin")
                rest = code_only(text, blank_strings=False)[after:]
                self.assertTrue(PIN.match(rest), "the first statement after param() is: " + first_line(rest))

    def test_the_setup_bootstrap_pins_the_module_path_first(self) -> None:
        source = (PROJECT / "installer" / "setup" / "ElevatedBootstrap.cs").read_text(encoding="utf-8")
        build = source[source.index("public static string BuildScript("):]
        build = build[build.index("StringBuilder script = new StringBuilder();"):].split("\n")[1:]
        self.assertNotIn("script.Insert(", source)
        # The script starts with the text of the plain script.Append("...") lines that open it.
        opening = []
        for line in build:
            line = line.strip()
            if line.startswith("//"):
                continue
            literal = re.fullmatch(r'script\.Append\("((?:[^"\\]|\\.)*)"\);', line)
            if not literal:
                break
            opening.append(csharp_literal(literal.group(1)))
        script = "".join(opening)
        self.assertTrue(PIN.match(script), "the bootstrap does not start with the pin: " + first_line(script))


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
class ModulePathBehaviourTests(unittest.TestCase):
    """Two scripts run with a stand-in module first on the module path; none of its commands may answer them."""

    SHADOWED = {
        "Get-Item": "Microsoft.PowerShell.Management",
        "Test-Path": "Microsoft.PowerShell.Management",
        "Join-Path": "Microsoft.PowerShell.Management",
        "Split-Path": "Microsoft.PowerShell.Management",
        "Get-ChildItem": "Microsoft.PowerShell.Management",
        "Import-Clixml": "Microsoft.PowerShell.Utility",
        "Get-Acl": "Microsoft.PowerShell.Security",
    }

    def setUp(self) -> None:
        system = os.environ.get("SystemRoot", r"C:\Windows")
        self.powershell = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        self.system_modules = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "Modules")
        self.temp = Path(tempfile.mkdtemp(prefix="rewindle-module-path-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.marker = self.temp / "shadowed.txt"
        module = self.temp / "modules" / "Shadow"
        module.mkdir(parents=True)
        functions = "".join(
            f"function {name} {{ [IO.File]::AppendAllText($env:SHADOW_MARKER, '{name} '); {owner}\\{name} @args }}\n"
            for name, owner in self.SHADOWED.items()
        )
        (module / "Shadow.psm1").write_text(functions, encoding="ascii", newline="\n")
        exported = ", ".join(f"'{name}'" for name in self.SHADOWED)
        (module / "Shadow.psd1").write_text(
            "@{\n    RootModule = 'Shadow.psm1'\n    ModuleVersion = '1.0'\n"
            "    GUID = '00000000-0000-4000-8000-000000000001'\n"
            f"    FunctionsToExport = @({exported})\n    CmdletsToExport = @()\n    AliasesToExport = @()\n}}\n",
            encoding="ascii",
            newline="\n",
        )
        self.shadowed_path = str(module.parent) + ";" + self.system_modules

    def run_powershell(self, arguments: list[str], module_path: str) -> subprocess.CompletedProcess[str]:
        replaced = {"PSMODULEPATH", "PSMODULEANALYSISCACHEPATH", "SHADOW_MARKER"}
        environment = {key: value for key, value in os.environ.items() if key.upper() not in replaced}
        environment["PSModulePath"] = module_path
        # Keeps the stand-in module out of the person's own module analysis cache.
        environment["PSModuleAnalysisCachePath"] = str(self.temp / "analysis-cache.bin")
        environment["SHADOW_MARKER"] = str(self.marker)
        return subprocess.run(
            [self.powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", *arguments],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
            env=environment,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def shadowed(self) -> list[str]:
        if not self.marker.exists():
            return []
        return sorted(set(self.marker.read_text(encoding="ascii").split()))

    def test_the_stand_in_module_answers_an_unpinned_command(self) -> None:
        # Without this, the checks below could pass because the stand-in never loads.
        result = self.run_powershell(["-Command", "$null = Join-Path 'a' 'b'"], self.shadowed_path)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["Join-Path"], self.shadowed())

    def test_the_password_helper_runs_only_windows_modules(self) -> None:
        helper_folder = self.temp / "helper"
        helper_folder.mkdir()
        helper = helper_folder / "reveal-rclone-config-password.ps1"
        shutil.copyfile(PROJECT / "src" / "reveal-rclone-config-password.ps1", helper)
        credential = helper_folder / "rclone-config-password.clixml"
        made = self.run_powershell(
            [
                "-Command",
                "$secret = ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force; "
                "[pscredential]::new('rclone-config', $secret) | Export-Clixml -LiteralPath '"
                + str(credential).replace("'", "''") + "'",
            ],
            self.system_modules,
        )
        self.assertEqual(0, made.returncode, made.stderr)

        result = self.run_powershell(["-File", str(helper), "-CredentialPath", str(credential)], self.shadowed_path)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("not-a-real-password", result.stdout.strip())
        self.assertEqual([], self.shadowed())

    def test_the_google_drive_check_runs_only_windows_modules(self) -> None:
        config = self.temp / "backup-config.json"
        config.write_text(json.dumps({"repository_storage_mode": "google_drivefs_stream"}), encoding="utf-8")
        result = self.run_powershell(
            [
                "-File",
                str(PROJECT / "src" / "verify_my_drive_cloud_repository.ps1"),
                "-ConfigPath",
                str(config),
                "-CloudVerificationRoot",
                str(self.temp / "cloud-verification"),
                "-ValidateOnly",
            ],
            self.shadowed_path,
        )
        # It stops at the incomplete configuration, after reading it with Test-Path, Get-Item and ConvertFrom-Json.
        self.assertNotEqual(0, result.returncode)
        self.assertIn("missing repository", result.stderr)
        self.assertEqual([], self.shadowed())


if __name__ == "__main__":
    unittest.main()
