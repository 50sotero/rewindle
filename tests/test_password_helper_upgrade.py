"""The rclone password helper can change without breaking PCs that already run the nightly Google Drive check.

Setting the check up copies the helper (src/reveal-rclone-config-password.ps1) into the protected assets folder and pins
its SHA-256 in assets-manifest.json. After an update, registering the check again replaces a helper that an earlier
Rewindle shipped with the packaged one (Update-ProtectedPasswordHelper in src/install_google_drive_sync_task.ps1), and
keeps the replaced files under evidence\\.

These tests run the installer's own functions, taken out of the script by PowerShell's parser, in Windows PowerShell
5.1 against a temporary assets folder. The permission checks need a folder only an elevated administrator can make, so
they are stand-ins here, except in RealPermissionTests, which runs elevated (always on CI). The helper itself is run
with a password outside ASCII, the way rclone runs it.
"""

import base64
import ctypes
import hashlib
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
INSTALLER = PROJECT / "src" / "install_google_drive_sync_task.ps1"
VERIFIER = PROJECT / "src" / "verify_my_drive_cloud_repository.ps1"
HELPER = PROJECT / "src" / "reveal-rclone-config-password.ps1"
HELPER_NAME = "reveal-rclone-config-password.ps1"
EARLIER_HELPERS = json.loads((PROJECT / "tests" / "fixtures" / "earlier-password-helpers.json").read_text("ascii"))
SYSTEM_ROOT = os.environ.get("SystemRoot", r"C:\Windows")
POWERSHELL = os.path.join(SYSTEM_ROOT, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
ON_CI = os.environ.get("GITHUB_ACTIONS") == "true"

# A password with a letter of each UTF-8 length: two bytes (a with diaeresis), three (the euro sign) and four (an emoji,
# a surrogate pair in Windows' UTF-16), and a space.
PASSWORD = "p\u00e4ss w\u20acrd-\U0001f600!"


def earlier_helper(generation: int) -> bytes:
    """The LF bytes of an earlier helper, checked against both recorded hashes."""
    for entry in EARLIER_HELPERS["helpers"]:
        if entry["generation"] == generation:
            data = base64.b64decode(entry["base64_lf"])
            if hashlib.sha256(data).hexdigest() != entry["sha256_lf"]:
                raise AssertionError(f"the fixture of helper generation {generation} does not match its LF hash")
            if hashlib.sha256(data.replace(b"\n", b"\r\n")).hexdigest() != entry["sha256_crlf"]:
                raise AssertionError(f"the fixture of helper generation {generation} does not match its CRLF hash")
            return data
    raise AssertionError(f"no earlier helper of generation {generation}")


def ps_literal(value: str) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def utf16_units(text: str) -> str:
    """The text as a PowerShell char array of UTF-16 code units, so a probe can hold it in ASCII."""
    data = text.encode("utf-16-le", "surrogatepass")
    return ",".join(str(int.from_bytes(data[i : i + 2], "little")) for i in range(0, len(data), 2))


def child_environment() -> dict:
    # A test run from PowerShell 7 hands that PowerShell's module folders down, and Windows PowerShell 5.1 cannot load
    # its own modules from them. Only Windows' own folder is allowed, under one key whatever its case.
    environment = {key: value for key, value in os.environ.items() if key.upper() != "PSMODULEPATH"}
    environment["PSModulePath"] = os.path.join(SYSTEM_ROOT, "System32", "WindowsPowerShell", "v1.0", "Modules")
    return environment


def is_elevated() -> bool:
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except (AttributeError, OSError):
        return False


PREAMBLE = r"""
$env:PSModulePath = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ScriptFunctionText {
    param([string]$Path, [string[]]$Names)

    $tokens = $null
    $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "The script does not parse: $Path"
    }
    foreach ($wanted in $Names) {
        $found = @($tree.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $wanted
        }, $true))
        if ($found.Count -ne 1) {
            throw "$wanted is defined $($found.Count) times in $Path"
        }
        $found[0].Extent.Text
    }
}

function ConvertTo-AsciiJson {
    param($Value)

    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '\u{0:x4}' -f [int][char]$m.Value }
    return [regex]::Replace($json, '[^\x20-\x7e]', $evaluator)
}

function Get-FolderSnapshot {
    # Every file under the folder, by relative path, with its SHA-256.
    param([string]$Root)

    $snapshot = [ordered]@{}
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($Root.Length + 1)
        if ($item.PSIsContainer) {
            $snapshot[$relative + '\'] = 'folder'
        }
        else {
            $snapshot[$relative] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return $snapshot
}
"""

REFRESH_FUNCTIONS = (
    "Assert-NormalFile",
    "Assert-NormalDirectory",
    "Get-Sha256Hex",
    "Read-Utf8Json",
    "Read-VerifiedAssetManifest",
    "Write-NewUtf8Json",
    "Get-KnownPasswordHelperGenerations",
    "Get-PasswordHelperRefreshPlan",
    "Assert-PasswordHelperPlanAllowed",
    "Get-Sha256HexOfBytes",
    "Write-NewFileBytes",
    "New-RefreshedAssetManifest",
    "Enter-ProtectedRunLock",
    "Exit-ProtectedRunLock",
    "Get-InstallerNativeMethods",
    "Move-FileReplacing",
    "Update-ProtectedPasswordHelper",
)
PERMISSION_FUNCTIONS = (
    "Assert-ProtectedRootAclDescriptor",
    "Assert-ProtectedRootAcl",
    "Set-ProtectedDirectoryAcl",
    "Assert-ProtectedTreeAcl",
)

# A stand-in for the installer's permission check of the whole assets folder, which needs a folder only an elevated
# administrator can make. It records what the folder held when the check ran.
TREE_CHECK_STAND_IN = r"""
$script:treeChecks = @()
function Assert-ProtectedTreeAcl {
    param([string]$Path, [string]$CurrentUserSid)

    $script:treeChecks += , ([ordered]@{
        path = $Path
        helper_sha256 = Get-Sha256Hex -Path (Join-Path $Path 'reveal-rclone-config-password.ps1')
        evidence = @(Get-ChildItem -LiteralPath (Join-Path $Path 'evidence') -Recurse -File -Force |
            ForEach-Object { $_.Name } | Sort-Object)
    })
}
"""

# Builds an assets folder the way Install-ProtectedCloudAssets does: the four files, runs\ and evidence\, and the
# manifest written by the installer's own Write-NewUtf8Json with its fields in the installer's order.
NEW_ASSETS_ROOT = r"""
function New-AssetsRoot {
    param([string]$Root, [byte[]]$HelperBytes, [switch]$WithRcloneVersion)

    [void][IO.Directory]::CreateDirectory($Root)
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'runs'))
    [void][IO.Directory]::CreateDirectory((Join-Path $Root 'evidence'))
    [IO.File]::WriteAllBytes((Join-Path $Root 'rclone.exe'), [Text.Encoding]::ASCII.GetBytes('rclone stand-in'))
    [IO.File]::WriteAllBytes((Join-Path $Root 'rclone-readonly.conf'), [Text.Encoding]::ASCII.GetBytes('configuration'))
    [IO.File]::WriteAllBytes((Join-Path $Root 'rclone-config-password.clixml'), [Text.Encoding]::ASCII.GetBytes('DPAPI'))
    [IO.File]::WriteAllBytes((Join-Path $Root 'reveal-rclone-config-password.ps1'), $HelperBytes)
    $records = @(
        foreach ($name in @('rclone.exe', 'rclone-readonly.conf', 'rclone-config-password.clixml',
                'reveal-rclone-config-password.ps1')) {
            $path = Join-Path $Root $name
            [ordered]@{ name = $name; bytes = [long](Get-Item -LiteralPath $path).Length; sha256 = Get-Sha256Hex -Path $path }
        }
    )
    $manifest = [ordered]@{
        schema_version = 1
        created_utc = '2026-11-09T21:14:03.1234560Z'
        task_user_sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        remote_name = 'ResticBackuperGoogleReadOnly'
    }
    if ($WithRcloneVersion) {
        $manifest.rclone_version = '1.74.4'
    }
    $manifest.file_count = $records.Count
    $manifest.files = $records
    Write-NewUtf8Json -Path (Join-Path $Root 'assets-manifest.json') -Value $manifest
}

function Get-RootPlan {
    param([string]$Root, [string]$PackagedPath)

    $manifest = Read-VerifiedAssetManifest -Root $Root -AllowPasswordHelperMismatch
    $record = @($manifest.files | Where-Object { [string]$_.name -ceq 'reveal-rclone-config-password.ps1' })[0]
    return Get-PasswordHelperRefreshPlan `
        -RecordedSha256 ([string]$record.sha256) `
        -PresentSha256 (Get-Sha256Hex -Path (Join-Path $Root 'reveal-rclone-config-password.ps1')) `
        -PackagedSha256 (Get-Sha256Hex -Path $PackagedPath) `
        -Generations (Get-KnownPasswordHelperGenerations)
}

function Invoke-Refresh {
    param([string]$Root, [string]$Plan, [string]$PackagedPath, [string]$LockPath)

    return Update-ProtectedPasswordHelper `
        -Root $Root `
        -Plan $Plan `
        -HelperName 'reveal-rclone-config-password.ps1' `
        -PackagedHelperPath $PackagedPath `
        -PackagedHelperSha256 (Get-Sha256Hex -Path $PackagedPath) `
        -Generations (Get-KnownPasswordHelperGenerations) `
        -RunLockPath $LockPath `
        -CurrentUserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
}
"""


def run_powershell(script: str, *arguments: str, timeout: int = 300) -> subprocess.CompletedProcess:
    """Runs the script in Windows PowerShell 5.1 with no window, and returns its raw output."""
    with tempfile.TemporaryDirectory(prefix="rewindle-helper-probe-", ignore_cleanup_errors=True) as temp:
        path = Path(temp) / "probe.ps1"
        path.write_bytes(script.encode("ascii"))
        return subprocess.run(
            [POWERSHELL, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(path),
             *arguments],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=timeout,
            check=False,
            env=child_environment(),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )


def run_probe_json(test: unittest.TestCase, body: str, functions=REFRESH_FUNCTIONS, prelude: str = "") -> dict:
    """Loads the installer's functions, runs the body, and returns the JSON document it prints last."""
    script = "\n".join(
        [
            PREAMBLE,
            "$installer = " + ps_literal(INSTALLER),
            "foreach ($definition in @(Get-ScriptFunctionText -Path $installer -Names @("
            + ", ".join(ps_literal(name) for name in functions)
            + "))) { . ([scriptblock]::Create($definition)) }",
            prelude,
            body,
        ]
    )
    completed = run_powershell(script)
    output = completed.stdout.decode("ascii", errors="replace")
    errors = completed.stderr.decode("utf-8", errors="replace")
    test.assertEqual(0, completed.returncode, f"the probe failed:\n{output}\n{errors}")
    lines = [line for line in output.splitlines() if line.strip()]
    test.assertTrue(lines, f"the probe printed nothing:\n{errors}")
    return json.loads(lines[-1])


def verifier_accepts(test: unittest.TestCase, root: Path) -> None:
    """The nightly check's own manifest reader accepts the folder (its permission check is left to RealPermissionTests)."""
    script = "\n".join(
        [
            PREAMBLE,
            "foreach ($definition in @(Get-ScriptFunctionText -Path " + ps_literal(VERIFIER) + " -Names @("
            "'Assert-NormalFile', 'Get-Sha256Hex', 'Read-Utf8Json', 'Read-VerifiedAssetManifest'))) "
            "{ . ([scriptblock]::Create($definition)) }",
            "[void](Read-VerifiedAssetManifest -Root " + ps_literal(root) + " -ExpectedUserSid "
            "([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))",
            "'accepted'",
        ]
    )
    completed = run_powershell(script)
    test.assertEqual(
        0,
        completed.returncode,
        "the nightly check refused the refreshed assets: " + completed.stderr.decode("utf-8", errors="replace"),
    )


class FolderFixture:
    """A temporary folder with an assets root, a runtime that ships the working tree's helper, and a run lock."""

    def __init__(self, temp: Path):
        self.root = temp / "ResticBackuperCloudVerification"
        self.runtime = temp / "runtime"
        self.runtime.mkdir()
        self.packaged = self.runtime / HELPER_NAME
        shutil.copyfile(HELPER, self.packaged)
        self.state = temp / "state"
        self.state.mkdir()
        self.lock = self.state / "run.lock"
        self.lock.write_bytes(b"\0")
        self.earlier = temp / "earlier-helper.ps1"
        self.earlier.write_bytes(earlier_helper(2))

    def variables(self) -> str:
        return "\n".join(
            [
                "$root = " + ps_literal(self.root),
                "$packaged = " + ps_literal(self.packaged),
                "$lockPath = " + ps_literal(self.lock),
                "$earlierBytes = [IO.File]::ReadAllBytes(" + ps_literal(self.earlier) + ")",
            ]
        )


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
class PasswordHelperOutputTests(unittest.TestCase):
    """rclone reads the password from the helper's standard output as UTF-8 and stops at the line break."""

    def run_helper(self, helper_bytes: bytes, password: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory(prefix="rewindle-helper-output-", ignore_cleanup_errors=True) as temp:
            folder = Path(temp)
            helper = folder / HELPER_NAME
            helper.write_bytes(helper_bytes)
            credential = folder / "rclone-config-password.clixml"
            # The credential is made as Setup's guide makes it: a PSCredential saved with Export-Clixml, which protects
            # the password with Windows' DPAPI for this account.
            made = run_powershell(
                "\n".join(
                    [
                        "$env:PSModulePath = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', "
                        "'v1.0', 'Modules')",
                        "$ErrorActionPreference = 'Stop'",
                        "$text = [string]::new([char[]]@(" + utf16_units(password) + "))",
                        "$secure = ConvertTo-SecureString -String $text -AsPlainText -Force",
                        "[PSCredential]::new('rclone-config', $secure) | Export-Clixml -LiteralPath $args[0]",
                    ]
                ),
                str(credential),
            )
            self.assertEqual(0, made.returncode, made.stderr.decode("utf-8", errors="replace"))
            self.assertTrue(credential.is_file() and credential.stat().st_size > 0, "the credential was not written")
            # The helper runs in a console whose code page is 437, as many are. It cannot store the euro sign or the
            # emoji, so any text written through the console's encoding comes out wrong.
            launcher = folder / "run-helper.cmd"
            launcher.write_bytes(
                (
                    "@chcp 437>nul\r\n"
                    f'@"{POWERSHELL}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass '
                    '-File "%~1" -CredentialPath "%~2"\r\n'
                ).encode("ascii")
            )
            return subprocess.run(
                [os.path.join(SYSTEM_ROOT, "System32", "cmd.exe"), "/d", "/c", str(launcher), str(helper),
                 str(credential)],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=120,
                check=False,
                env=child_environment(),
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )

    def test_a_password_outside_ascii_reaches_rclone_unchanged(self):
        completed = self.run_helper(HELPER.read_bytes(), PASSWORD)
        self.assertEqual(0, completed.returncode, completed.stderr.decode("utf-8", errors="replace"))
        # Exactly the UTF-8 bytes and a line break: no byte order mark, nothing else.
        self.assertEqual(PASSWORD.encode("utf-8") + b"\r\n", completed.stdout)
        # What rclone makes of it: strict UTF-8, with the line break trimmed.
        self.assertEqual(PASSWORD, completed.stdout.decode("utf-8", errors="strict").strip("\r\n"))

    def test_the_earlier_helper_garbled_the_same_password(self):
        # The same run with the helper of generation 2 gives other bytes, so the test above tells the two apart on
        # this machine.
        completed = self.run_helper(earlier_helper(2), PASSWORD)
        self.assertNotEqual(PASSWORD.encode("utf-8") + b"\r\n", completed.stdout)

    def test_a_password_that_is_not_valid_text_is_refused_without_output(self):
        # A lone half of a surrogate pair cannot be written as UTF-8. The helper stops, prints nothing on standard
        # output and does not repeat the password in its error.
        completed = self.run_helper(HELPER.read_bytes(), "Kx7Qw\ud800Zp9")
        self.assertNotEqual(0, completed.returncode)
        self.assertEqual(b"", completed.stdout)
        errors = completed.stderr.decode("utf-8", errors="replace")
        self.assertIn("The protected rclone configuration password is invalid.", errors)
        self.assertNotIn("Kx7Qw", errors)
        self.assertNotIn("Zp9", errors)

    def test_a_password_with_a_line_break_is_refused_without_output(self):
        completed = self.run_helper(HELPER.read_bytes(), "Kx7Qw\nZp9")
        self.assertNotEqual(0, completed.returncode)
        self.assertEqual(b"", completed.stdout)
        errors = completed.stderr.decode("utf-8", errors="replace")
        self.assertIn("The protected rclone configuration password is invalid.", errors)
        self.assertNotIn("Kx7Qw", errors)


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
class PasswordHelperPlanTests(unittest.TestCase):
    """Get-PasswordHelperRefreshPlan decides from three hashes; every case runs through the installer's own function."""

    def test_every_state_gets_its_plan(self):
        lf = {entry["generation"]: entry["sha256_lf"] for entry in EARLIER_HELPERS["helpers"]}
        crlf = {entry["generation"]: entry["sha256_crlf"] for entry in EARLIER_HELPERS["helpers"]}
        current = HELPER.read_bytes().replace(b"\r\n", b"\n")
        lf[4] = hashlib.sha256(current).hexdigest()
        crlf[4] = hashlib.sha256(current.replace(b"\n", b"\r\n")).hexdigest()
        stranger = "0" * 64
        cases = [
            # recorded, present, packaged, plan
            (lf[4], lf[4], lf[4], "current"),
            (lf[4], lf[4], crlf[4], "current"),
            (crlf[4], crlf[4], lf[4], "current"),
            (lf[1], lf[1], lf[4], "refresh"),
            (crlf[1], crlf[1], crlf[4], "refresh"),
            (lf[2], lf[2], crlf[4], "refresh"),
            (crlf[2], crlf[2], lf[4], "refresh"),
            (lf[3], lf[3], lf[4], "refresh"),
            # A refresh cut short: the helper was replaced, the manifest still names the earlier one.
            (lf[2], lf[4], lf[4], "finish"),
            (lf[2], lf[4], crlf[4], "finish"),
            (crlf[1], crlf[3], lf[4], "refresh"),
            # Assets from a newer Rewindle, with the packaged helper of generation 2.
            (lf[4], lf[4], lf[2], "newer"),
            (lf[1], lf[4], lf[2], "newer"),
            # A helper no Rewindle shipped, or a state no refresh leaves.
            (stranger, stranger, lf[4], "unknown"),
            (lf[2], stranger, lf[4], "unknown"),
            (stranger, lf[2], lf[4], "unknown"),
            (lf[2], lf[1], lf[4], "unknown"),
            (lf[2], crlf[2], lf[4], "unknown"),
            (lf[4], crlf[4], lf[4], "unknown"),
            (lf[4].upper(), lf[4].upper(), lf[4], "unknown"),
            # A packaged helper missing from the list.
            (lf[4], lf[4], stranger, "packaged_unknown"),
        ]
        body = "\n".join(
            [
                "$generations = Get-KnownPasswordHelperGenerations",
                "$plans = @(",
                *(
                    f"    (Get-PasswordHelperRefreshPlan -RecordedSha256 {ps_literal(recorded)} -PresentSha256 "
                    f"{ps_literal(present)} -PackagedSha256 {ps_literal(packaged)} -Generations $generations)"
                    for recorded, present, packaged, _ in cases
                ),
                ")",
                "ConvertTo-AsciiJson -Value ([ordered]@{ plans = $plans; type = $generations.GetType().FullName })",
            ]
        )
        report = run_probe_json(self, body)
        self.assertIn("Dictionary", report["type"], "the list of helpers was handed back one entry at a time")
        for (recorded, present, packaged, expected), plan in zip(cases, report["plans"], strict=True):
            with self.subTest(recorded=recorded[:8], present=present[:8], packaged=packaged[:8]):
                self.assertEqual(expected, plan)

    def test_each_refusal_says_what_to_do(self):
        body = r"""
$messages = [ordered]@{}
foreach ($plan in @('current', 'refresh', 'finish', 'newer', 'unknown', 'packaged_unknown', 'other')) {
    try {
        Assert-PasswordHelperPlanAllowed -Plan $plan -Root 'C:\ProgramData\ResticBackuperCloudVerification'
        $messages[$plan] = ''
    }
    catch {
        $messages[$plan] = $_.Exception.Message
    }
}
ConvertTo-AsciiJson -Value $messages
"""
        messages = run_probe_json(self, body)
        for plan in ("current", "refresh", "finish"):
            self.assertEqual("", messages[plan], plan)
        self.assertIn("newer version of Rewindle", messages["newer"])
        self.assertIn("Install that version or a later one", messages["newer"])
        self.assertIn("no version of Rewindle shipped", messages["unknown"])
        self.assertIn(r"Move C:\ProgramData\ResticBackuperCloudVerification aside", messages["unknown"])
        self.assertIn("-ProvisionAssets", messages["unknown"])
        self.assertIn("Reinstall Rewindle", messages["packaged_unknown"])
        self.assertIn("Unexpected password helper plan", messages["other"])
        self.assertIn("left as they are", messages["newer"])
        self.assertIn("left as they are", messages["unknown"])
        self.assertIn("register the check again", messages["packaged_unknown"])


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
class PasswordHelperRefreshTests(unittest.TestCase):
    """Update-ProtectedPasswordHelper on a temporary assets folder, with a stand-in for the permission check."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="rewindle-helper-refresh-", ignore_cleanup_errors=True)
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.fixture = FolderFixture(self.temp)

    def probe(self, body: str) -> dict:
        return run_probe_json(
            self,
            body,
            prelude="\n".join([TREE_CHECK_STAND_IN, NEW_ASSETS_ROOT, self.fixture.variables()]),
        )

    def evidence_folders(self) -> list[Path]:
        return sorted(path for path in (self.fixture.root / "evidence").iterdir())

    def test_an_earlier_helper_is_replaced_and_kept(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes -WithRcloneVersion
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$result = Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath
[void](Read-VerifiedAssetManifest -Root $root)
$after = Get-RootPlan -Root $root -PackagedPath $packaged
$lock = Enter-ProtectedRunLock -Path $lockPath
$lockFree = $null -ne $lock
Exit-ProtectedRunLock -Stream $lock
ConvertTo-AsciiJson -Value ([ordered]@{
    plan = $plan
    after = $after
    recorded = $result.RecordedHelperSha256
    previous_copy = $result.PreviousCopy
    tree_checks = $script:treeChecks
    lock_free = $lockFree
})
"""
        )
        self.assertEqual("refresh", report["plan"])
        self.assertEqual("current", report["after"])
        self.assertTrue(report["lock_free"], "the run lock was still held afterwards")
        earlier = earlier_helper(2)
        packaged = self.fixture.packaged.read_bytes()
        self.assertEqual(hashlib.sha256(earlier).hexdigest(), report["recorded"])
        self.assertEqual(packaged, (self.fixture.root / HELPER_NAME).read_bytes())

        # The replaced files are kept, byte for byte, and nothing staged is left over.
        folders = self.evidence_folders()
        self.assertEqual(1, len(folders))
        self.assertEqual(str(folders[0]), report["previous_copy"])
        self.assertRegex(folders[0].name, r"^password-helper-\d{8}T\d{9}Z-[0-9a-f]{8}$")
        self.assertEqual(
            sorted([HELPER_NAME + ".previous", "assets-manifest.json.previous"]),
            sorted(path.name for path in folders[0].iterdir()),
        )
        self.assertEqual(earlier, (folders[0] / (HELPER_NAME + ".previous")).read_bytes())
        before_text = (folders[0] / "assets-manifest.json.previous").read_text("utf-8")
        after_text = (self.fixture.root / "assets-manifest.json").read_text("utf-8")

        # Only the helper's size and hash changed in the manifest, written as the installer writes it.
        before = json.loads(before_text)
        after = json.loads(after_text)
        self.assertEqual(list(before), list(after))
        helper_index = [record["name"] for record in before["files"]].index(HELPER_NAME)
        expected = json.loads(before_text)
        expected["files"][helper_index]["bytes"] = len(packaged)
        expected["files"][helper_index]["sha256"] = hashlib.sha256(packaged).hexdigest()
        self.assertEqual(expected, after)
        self.assertEqual("2026-11-09T21:14:03.1234560Z", after["created_utc"])
        self.assertEqual("1.74.4", after["rclone_version"])
        changed = [
            (old, new)
            for old, new in zip(before_text.splitlines(), after_text.splitlines(), strict=True)
            if old != new
        ]
        self.assertEqual(2, len(changed), changed)
        self.assertFalse((self.fixture.root / "assets-manifest.json").read_bytes().startswith(b"\xef\xbb\xbf"))

        # The permission check ran once, on the whole folder, after the replacements were written and before the
        # helper was swapped.
        self.assertEqual(1, len(report["tree_checks"]))
        check = report["tree_checks"][0]
        self.assertEqual(str(self.fixture.root), check["path"])
        self.assertEqual(hashlib.sha256(earlier).hexdigest(), check["helper_sha256"])
        self.assertEqual(
            sorted(
                [
                    HELPER_NAME + ".new",
                    HELPER_NAME + ".previous",
                    "assets-manifest.json.new",
                    "assets-manifest.json.previous",
                ]
            ),
            check["evidence"],
        )
        verifier_accepts(self, self.fixture.root)

    def test_a_refresh_cut_short_after_the_helper_is_finished(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
# As a refresh leaves the folder when it stops between the helper and the manifest.
[IO.File]::WriteAllBytes((Join-Path $root 'reveal-rclone-config-password.ps1'), [IO.File]::ReadAllBytes($packaged))
$strict = ''
try {
    [void](Read-VerifiedAssetManifest -Root $root)
}
catch {
    $strict = $_.Exception.Message
}
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$result = Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath
[void](Read-VerifiedAssetManifest -Root $root)
ConvertTo-AsciiJson -Value ([ordered]@{
    strict = $strict
    plan = $plan
    after = Get-RootPlan -Root $root -PackagedPath $packaged
})
"""
        )
        self.assertIn("size or hash mismatch: " + HELPER_NAME, report["strict"])
        self.assertEqual("finish", report["plan"])
        self.assertEqual("current", report["after"])
        self.assertEqual(self.fixture.packaged.read_bytes(), (self.fixture.root / HELPER_NAME).read_bytes())
        folders = self.evidence_folders()
        self.assertEqual(1, len(folders))
        self.assertEqual(["assets-manifest.json.previous"], [path.name for path in folders[0].iterdir()])
        manifest = json.loads((self.fixture.root / "assets-manifest.json").read_text("utf-8"))
        self.assertNotIn("rclone_version", manifest)
        verifier_accepts(self, self.fixture.root)

    def test_nothing_changes_while_a_backup_or_the_check_holds_the_run_lock(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$before = Get-FolderSnapshot -Root $root
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$holder = [IO.File]::Open($lockPath, 'Open', 'Read', 'ReadWrite')
$holder.Lock(0, 1)
$message = ''
try {
    [void](Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
}
catch {
    $message = $_.Exception.Message
}
finally {
    $holder.Unlock(0, 1)
    $holder.Dispose()
}
ConvertTo-AsciiJson -Value ([ordered]@{
    message = $message
    unchanged = ((ConvertTo-Json $before) -ceq (ConvertTo-Json (Get-FolderSnapshot -Root $root)))
    plan_after = Get-RootPlan -Root $root -PackagedPath $packaged
})
"""
        )
        self.assertIn("A backup, the Google Drive check or another protected change is running", report["message"])
        self.assertIn("Register the check again once it has finished.", report["message"])
        self.assertTrue(report["unchanged"], "the assets folder changed although the run lock was held")
        self.assertEqual([], self.evidence_folders())
        self.assertEqual("refresh", report["plan_after"])

    def test_the_earlier_helper_goes_back_when_the_manifest_cannot_be_replaced(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$manifestBefore = Get-Sha256Hex -Path (Join-Path $root 'assets-manifest.json')
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$realMove = ${function:Move-FileReplacing}
function Move-FileReplacing {
    param([string]$Source, [string]$Target)

    if ($Target.EndsWith('assets-manifest.json')) {
        throw 'Stand-in: the manifest could not be replaced.'
    }
    & $realMove -Source $Source -Target $Target
}
$message = ''
try {
    [void](Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
}
catch {
    $message = $_.Exception.Message
}
[void](Read-VerifiedAssetManifest -Root $root)
$lock = Enter-ProtectedRunLock -Path $lockPath
$lockFree = $null -ne $lock
Exit-ProtectedRunLock -Stream $lock
ConvertTo-AsciiJson -Value ([ordered]@{
    message = $message
    manifest_unchanged = ((Get-Sha256Hex -Path (Join-Path $root 'assets-manifest.json')) -ceq $manifestBefore)
    plan_after = Get-RootPlan -Root $root -PackagedPath $packaged
    lock_free = $lockFree
})
"""
        )
        self.assertEqual("Stand-in: the manifest could not be replaced.", report["message"])
        self.assertTrue(report["manifest_unchanged"])
        self.assertEqual(earlier_helper(2), (self.fixture.root / HELPER_NAME).read_bytes())
        self.assertEqual("refresh", report["plan_after"])
        self.assertTrue(report["lock_free"])
        # The folder stays: the swap had started. It still holds the copies of the earlier files.
        folders = self.evidence_folders()
        self.assertEqual(1, len(folders))
        self.assertEqual(
            sorted([HELPER_NAME + ".previous", "assets-manifest.json.new", "assets-manifest.json.previous"]),
            sorted(path.name for path in folders[0].iterdir()),
        )

    def test_registering_again_finishes_when_even_the_way_back_fails(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$realMove = ${function:Move-FileReplacing}
function Move-FileReplacing {
    param([string]$Source, [string]$Target)

    if ($Target.EndsWith('assets-manifest.json') -or $Source.EndsWith('.rollback')) {
        throw 'Stand-in: the file could not be replaced.'
    }
    & $realMove -Source $Source -Target $Target
}
$message = ''
$warnings = @()
try {
    [void](Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath 3>&1 |
        ForEach-Object { $warnings += [string]$_ })
}
catch {
    $message = $_.Exception.Message
}
$cutShort = Get-RootPlan -Root $root -PackagedPath $packaged
Set-Item -Path function:Move-FileReplacing -Value $realMove
[void](Invoke-Refresh -Root $root -Plan $cutShort -PackagedPath $packaged -LockPath $lockPath)
[void](Read-VerifiedAssetManifest -Root $root)
ConvertTo-AsciiJson -Value ([ordered]@{
    message = $message
    warnings = $warnings
    cut_short = $cutShort
    after = Get-RootPlan -Root $root -PackagedPath $packaged
})
"""
        )
        self.assertEqual("Stand-in: the file could not be replaced.", report["message"])
        self.assertEqual(1, len(report["warnings"]), report["warnings"])
        self.assertIn("Registering the check again finishes the update.", report["warnings"][0])
        self.assertEqual("finish", report["cut_short"])
        self.assertEqual("current", report["after"])
        self.assertEqual(self.fixture.packaged.read_bytes(), (self.fixture.root / HELPER_NAME).read_bytes())
        # The earlier helper is kept by the first attempt, the manifest it recorded by both.
        kept = sorted(path.name for folder in self.evidence_folders() for path in folder.iterdir())
        self.assertIn(HELPER_NAME + ".previous", kept)
        self.assertEqual(2, kept.count("assets-manifest.json.previous"))
        verifier_accepts(self, self.fixture.root)

    def test_assets_that_change_meanwhile_are_left_alone(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
# The permission check is the last step before the run lock is taken; the helper changes while it runs.
function Assert-ProtectedTreeAcl {
    param([string]$Path, [string]$CurrentUserSid)

    [IO.File]::AppendAllText((Join-Path $Path 'reveal-rclone-config-password.ps1'), '# changed')
}
$changedBefore = ''
$wrongPlan = ''
try {
    [void](Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
}
catch {
    $changedBefore = $_.Exception.Message
}
$manifestText = [IO.File]::ReadAllText((Join-Path $root 'assets-manifest.json'))
try {
    # A plan that does not fit the folder is refused before anything is written.
    [void](Invoke-Refresh -Root $root -Plan 'finish' -PackagedPath $packaged -LockPath $lockPath)
}
catch {
    $wrongPlan = $_.Exception.Message
}
ConvertTo-AsciiJson -Value ([ordered]@{
    changed_before = $changedBefore
    wrong_plan = $wrongPlan
    manifest_unchanged = ($manifestText -ceq [IO.File]::ReadAllText((Join-Path $root 'assets-manifest.json')))
})
"""
        )
        expected = "The protected rclone assets changed while this setup ran, so they were left as they are."
        self.assertIn(expected, report["changed_before"])
        self.assertIn(expected, report["wrong_plan"])
        self.assertTrue(report["manifest_unchanged"])
        self.assertEqual([], self.evidence_folders())

    def test_a_file_is_replaced_in_one_step_or_not_at_all(self):
        report = self.probe(
            r"""
$folder = Split-Path -Parent $lockPath
$target = Join-Path $folder 'target.txt'
$source = Join-Path $folder 'source.txt'
[IO.File]::WriteAllText($target, 'old')
[IO.File]::WriteAllText($source, 'new')
Move-FileReplacing -Source $source -Target $target
$replaced = [IO.File]::ReadAllText($target)
$sourceGone = -not (Test-Path -LiteralPath $source)
[IO.File]::WriteAllText($source, 'newer')
# Another program has the target open and does not let it be deleted: the swap is tried again, then refused.
$reader = [IO.File]::Open($target, 'Open', 'Read', 'Read')
$refusal = ''
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    Move-FileReplacing -Source $source -Target $target
}
catch {
    $refusal = $_.Exception.Message
}
finally {
    $reader.Dispose()
}
$seconds = $watch.Elapsed.TotalSeconds
$held = [IO.File]::Open($lockPath, 'Open', 'Read', 'ReadWrite')
$held.Lock(0, 1)
$whileLocked = Enter-ProtectedRunLock -Path $lockPath
$held.Unlock(0, 1)
$held.Dispose()
$exclusive = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
$whileOpen = Enter-ProtectedRunLock -Path $lockPath
$exclusive.Dispose()
$free = Enter-ProtectedRunLock -Path $lockPath
$second = [IO.File]::Open($lockPath, 'Open', 'Read', 'ReadWrite')
$secondLocked = $true
try {
    $second.Lock(0, 1)
    $secondLocked = $false
    $second.Unlock(0, 1)
}
catch {
}
finally {
    $second.Dispose()
}
Exit-ProtectedRunLock -Stream $free
ConvertTo-AsciiJson -Value ([ordered]@{
    replaced = $replaced
    source_gone = $sourceGone
    refusal = $refusal
    seconds = $seconds
    target_after = [IO.File]::ReadAllText($target)
    source_kept = [IO.File]::ReadAllText($source)
    while_locked = $null -eq $whileLocked
    while_open = $null -eq $whileOpen
    free = $null -ne $free
    held_while_free = $secondLocked
})
"""
        )
        self.assertEqual("new", report["replaced"])
        self.assertTrue(report["source_gone"])
        self.assertIn("Could not replace", report["refusal"])
        self.assertGreater(report["seconds"], 0.5, "a file in use was not tried again")
        self.assertEqual("new", report["target_after"])
        self.assertEqual("newer", report["source_kept"])
        self.assertTrue(report["while_locked"], "the run lock was taken while another handle held it")
        self.assertTrue(report["while_open"], "the run lock was taken while another program had it open alone")
        self.assertTrue(report["free"], "a free run lock was not taken")
        self.assertTrue(report["held_while_free"], "the taken run lock did not keep others out")


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
class RealPermissionTests(unittest.TestCase):
    """The refresh with the installer's real permission functions, which need an elevated administrator. CI runs elevated,
    so there it must run; a local unelevated run skips it."""

    def setUp(self):
        if not is_elevated():
            if ON_CI:
                self.fail("CI must run this test elevated")
            self.skipTest("needs an elevated administrator")
        temp = tempfile.TemporaryDirectory(prefix="rewindle-helper-acl-", ignore_cleanup_errors=True)
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.fixture = FolderFixture(self.temp)

    def test_the_refreshed_folder_passes_both_permission_checks(self):
        report = run_probe_json(
            self,
            r"""
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
[void][IO.Directory]::CreateDirectory($root)
Set-ProtectedDirectoryAcl -Path $root -CurrentUserSid $sid
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
Set-ProtectedDirectoryAcl -Path $root -CurrentUserSid $sid
Assert-ProtectedTreeAcl -Path $root -CurrentUserSid $sid
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$result = Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath
Assert-ProtectedTreeAcl -Path $root -CurrentUserSid $sid
[void](Read-VerifiedAssetManifest -Root $root)
$owners = [ordered]@{}
foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
    $owners[$item.FullName.Substring($root.Length + 1)] = (Get-Acl -LiteralPath $item.FullName).GetOwner(
        [Security.Principal.SecurityIdentifier]).Value
}
ConvertTo-AsciiJson -Value ([ordered]@{ plan = $plan; after = Get-RootPlan -Root $root -PackagedPath $packaged; owners = $owners })
""",
            functions=REFRESH_FUNCTIONS + PERMISSION_FUNCTIONS,
            prelude="\n".join([NEW_ASSETS_ROOT, self.fixture.variables()]),
        )
        self.assertEqual("refresh", report["plan"])
        self.assertEqual("current", report["after"])
        self.assertEqual({"S-1-5-32-544"}, set(report["owners"].values()), report["owners"])
        # The nightly check's own permission check and manifest reader accept the folder as it now is.
        script = "\n".join(
            [
                PREAMBLE,
                "foreach ($definition in @(Get-ScriptFunctionText -Path " + ps_literal(VERIFIER) + " -Names @("
                "'Assert-NormalFile', 'Assert-NormalDirectory', 'Assert-ProtectedAcl', 'Assert-ProtectedTree', "
                "'Get-Sha256Hex', 'Read-Utf8Json', 'Read-VerifiedAssetManifest'))) "
                "{ . ([scriptblock]::Create($definition)) }",
                "$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value",
                "Assert-ProtectedTree -Root " + ps_literal(self.fixture.root) + " -CurrentUserSid $sid",
                "[void](Read-VerifiedAssetManifest -Root " + ps_literal(self.fixture.root) + " -ExpectedUserSid $sid)",
                "'accepted'",
            ]
        )
        completed = run_powershell(script)
        self.assertEqual(0, completed.returncode, completed.stderr.decode("utf-8", errors="replace"))


class InstallerOrderTests(unittest.TestCase):
    """Where the refresh sits in the installer. Single-line anchors, so a CRLF checkout reads the same."""

    TEXT = INSTALLER.read_text("utf-8")

    def position(self, anchor: str, start: int = 0) -> int:
        at = self.TEXT.find(anchor, start)
        self.assertGreaterEqual(at, 0, f"not found in the installer: {anchor}")
        return at

    def test_validate_only_reports_the_plan_and_changes_nothing(self):
        plan = self.position("$passwordHelperPlan = Get-PasswordHelperRefreshPlan `")
        allowed = self.position("Assert-PasswordHelperPlanAllowed -Plan $passwordHelperPlan", plan)
        validate_only = self.position("if ($ValidateOnly) {", allowed)
        self.position("    return", validate_only)
        refresh = self.position("$passwordHelperRefresh = Update-ProtectedPasswordHelper `")
        self.assertLess(validate_only, refresh)

    def test_the_refresh_runs_after_every_check_and_before_the_task_is_registered(self):
        elevated = self.position("\nAssert-Elevated")
        running = self.position("if ([string]$existingTask.State -eq 'Running') {", elevated)
        other_account = self.position("Refusing to replace a Google Drive task owned by another account.", running)
        refresh = self.position("$passwordHelperRefresh = Update-ProtectedPasswordHelper `", other_account)
        strict = self.position("$assetManifest = Read-VerifiedAssetManifest -Root $cloudVerificationRootFull", refresh)
        tree = self.position("Assert-ProtectedTreeAcl `", strict)
        performed = self.position("$validation.password_helper_refresh = 'performed'", tree)
        self.position("ScheduledTasks\\Register-ScheduledTask `", performed)

    def test_the_swap_happens_under_the_run_lock_after_the_permission_check(self):
        start = self.position("function Update-ProtectedPasswordHelper {")
        end = re.search(r"\r?\n}\r?\n", self.TEXT[start:])
        self.assertIsNotNone(end, "the end of Update-ProtectedPasswordHelper was not found")
        body = self.TEXT[start : start + end.start()]
        order = [
            "Assert-ProtectedTreeAcl -Path $Root -CurrentUserSid $CurrentUserSid",
            "$lock = Enter-ProtectedRunLock -Path $RunLockPath",
            "$swapStarted = $true",
            "Move-FileReplacing -Source $stagedHelper -Target $helperPath",
            "Move-FileReplacing -Source $stagedManifest -Target $manifestPath",
            "finally {",
            "Exit-ProtectedRunLock -Stream $lock",
        ]
        positions = [body.find(anchor) for anchor in order]
        self.assertNotIn(-1, positions, dict(zip(order, positions)))
        self.assertEqual(sorted(positions), positions, dict(zip(order, positions)))
        self.assertNotIn("[System.IO.File]::Replace(", body)

    def test_nothing_is_compiled_while_elevated(self):
        self.assertIsNone(re.search(r"(?im)^\s*Add-Type\b", self.TEXT))
        self.assertIn("[Reflection.Emit.AssemblyBuilderAccess]::Run", self.TEXT)


if __name__ == "__main__":
    unittest.main()
