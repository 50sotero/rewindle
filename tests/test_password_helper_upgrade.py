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
    "Get-MoveFileNativeMethods",
    "Move-FileReplacing",
    "Update-ProtectedPasswordHelper",
    "Get-AssetPasswordHelperPlan",
    "Invoke-PasswordHelperRefresh",
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

# The plan as the installer makes it when the check is registered: the manifest read as it reads it, then its own
# Get-AssetPasswordHelperPlan.
function Get-RootPlan {
    param([string]$Root, [string]$PackagedPath)

    $manifest = Read-VerifiedAssetManifest -Root $Root -AllowPasswordHelperMismatch
    return (Get-AssetPasswordHelperPlan `
        -Manifest $manifest `
        -Root $Root `
        -HelperName 'reveal-rclone-config-password.ps1' `
        -PackagedHelperSha256 (Get-Sha256Hex -Path $PackagedPath)).Plan
}

# Update-ProtectedPasswordHelper alone.
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

# The whole step that registering the check runs (Invoke-PasswordHelperRefresh).
function Invoke-RefreshStep {
    param([string]$Root, [string]$Plan, [string]$PackagedPath, [string]$LockPath)

    return Invoke-PasswordHelperRefresh `
        -Root $Root `
        -Plan $Plan `
        -HelperName 'reveal-rclone-config-password.ps1' `
        -PackagedHelperPath $PackagedPath `
        -PackagedHelperSha256 (Get-Sha256Hex -Path $PackagedPath) `
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
                        # One code unit at a time, so that an empty password can be saved too.
                        "$secure = [Security.SecureString]::new()",
                        "foreach ($unit in [char[]]@(" + utf16_units(password) + ")) { $secure.AppendChar($unit) }",
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

    def test_a_password_rclone_could_not_take_is_refused_without_output(self):
        # A lone half of a surrogate pair cannot be written as UTF-8, rclone would cut the password at a line break of
        # either kind, and an empty one is no password. The helper stops, prints nothing on standard output and does
        # not repeat the password in its error.
        for label, password in (
            ("not valid text", "Kx7Qw\ud800Zp9"),
            ("line feed", "Kx7Qw\nZp9"),
            ("carriage return", "Kx7Qw\rZp9"),
            ("both", "Kx7Qw\r\nZp9"),
            ("empty", ""),
        ):
            with self.subTest(label):
                completed = self.run_helper(HELPER.read_bytes(), password)
                self.assertNotEqual(0, completed.returncode)
                self.assertEqual(b"", completed.stdout)
                errors = completed.stderr.decode("utf-8", errors="replace")
                self.assertIn("The protected rclone configuration password is invalid.", errors)
                self.assertNotIn("Kx7Qw", errors)
                self.assertNotIn("Zp9", errors)


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
        self.assertIn("Dictionary", report["type"], "Get-KnownPasswordHelperGenerations did not return a dictionary")
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
        # The whole step that registering the check runs.
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes -WithRcloneVersion
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$fields = Invoke-RefreshStep -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath
[void](Read-VerifiedAssetManifest -Root $root)
$after = Get-RootPlan -Root $root -PackagedPath $packaged
$lock = Enter-ProtectedRunLock -Path $lockPath
$lockFree = $null -ne $lock
Exit-ProtectedRunLock -Stream $lock
ConvertTo-AsciiJson -Value ([ordered]@{
    plan = $plan
    after = $after
    fields = $fields
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
        self.assertEqual(packaged, (self.fixture.root / HELPER_NAME).read_bytes())

        # The replaced files are kept, byte for byte, and nothing staged is left over.
        folders = self.evidence_folders()
        self.assertEqual(1, len(folders))
        # What the installer reports: the manifest as it now is, and what was replaced and where it is kept.
        self.assertEqual(
            {
                "asset_manifest_sha256": hashlib.sha256((self.fixture.root / "assets-manifest.json").read_bytes()).hexdigest(),
                "password_helper_refresh": "performed",
                "password_helper_previous_sha256": hashlib.sha256(earlier).hexdigest(),
                "password_helper_previous_copy": str(folders[0]),
            },
            report["fields"],
        )
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

        # The permission check ran on the whole folder after the replacements were written and before the helper was
        # swapped, and again once the swap was done.
        self.assertEqual(2, len(report["tree_checks"]))
        before_swap, after_swap = report["tree_checks"]
        self.assertEqual(str(self.fixture.root), before_swap["path"])
        self.assertEqual(hashlib.sha256(earlier).hexdigest(), before_swap["helper_sha256"])
        self.assertEqual(
            sorted(
                [
                    HELPER_NAME + ".new",
                    HELPER_NAME + ".previous",
                    "assets-manifest.json.new",
                    "assets-manifest.json.previous",
                ]
            ),
            before_swap["evidence"],
        )
        self.assertEqual(str(self.fixture.root), after_swap["path"])
        self.assertEqual(hashlib.sha256(packaged).hexdigest(), after_swap["helper_sha256"])
        self.assertEqual(sorted([HELPER_NAME + ".previous", "assets-manifest.json.previous"]), after_swap["evidence"])
        verifier_accepts(self, self.fixture.root)

    def test_registering_refuses_assets_the_refresh_left_disagreeing(self):
        # A refresh that reports success but swapped only the helper: the strict read afterwards refuses the folder.
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
function Update-ProtectedPasswordHelper {
    param($Root, $Plan, $HelperName, $PackagedHelperPath, $PackagedHelperSha256, $Generations, $RunLockPath, $CurrentUserSid)

    [IO.File]::WriteAllBytes((Join-Path $Root $HelperName), [IO.File]::ReadAllBytes($PackagedHelperPath))
    return [pscustomobject]@{ RecordedHelperSha256 = 'stand-in'; PreviousCopy = 'stand-in' }
}
$message = ''
try {
    [void](Invoke-RefreshStep -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
}
catch {
    $message = $_.Exception.Message
}
ConvertTo-AsciiJson -Value ([ordered]@{ plan = $plan; message = $message })
"""
        )
        self.assertEqual("refresh", report["plan"])
        self.assertEqual("Cloud-verification asset size or hash mismatch: " + HELPER_NAME, report["message"])

    def test_registering_refuses_assets_the_refresh_left_with_an_earlier_helper(self):
        # A refresh that reports success but changed nothing: the folder reads well, and still holds generation 2.
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
function Update-ProtectedPasswordHelper {
    param($Root, $Plan, $HelperName, $PackagedHelperPath, $PackagedHelperSha256, $Generations, $RunLockPath, $CurrentUserSid)

    return [pscustomobject]@{ RecordedHelperSha256 = 'stand-in'; PreviousCopy = 'stand-in' }
}
$message = ''
try {
    [void](Invoke-RefreshStep -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
}
catch {
    $message = $_.Exception.Message
}
ConvertTo-AsciiJson -Value ([ordered]@{ plan = $plan; message = $message })
"""
        )
        self.assertEqual("refresh", report["plan"])
        self.assertEqual(
            "The refreshed rclone password helper could not be confirmed. Register the check again.", report["message"]
        )

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

    def test_a_refresh_cut_short_by_a_build_with_the_other_line_endings_is_finished(self):
        # The helper in the assets is the packaged one's generation with the other line endings: a refresh cut short by
        # a local build, finished by a release build. Finishing records the file that is there and leaves it as it is.
        packaged = self.fixture.packaged.read_bytes()
        lf = packaged.replace(b"\r\n", b"\n")
        other = lf.replace(b"\n", b"\r\n") if packaged == lf else lf
        other_path = self.temp / "other-line-endings.ps1"
        other_path.write_bytes(other)
        report = self.probe(
            "$otherPath = "
            + ps_literal(other_path)
            + r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
[IO.File]::WriteAllBytes((Join-Path $root 'reveal-rclone-config-password.ps1'), [IO.File]::ReadAllBytes($otherPath))
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
[void](Invoke-Refresh -Root $root -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
[void](Read-VerifiedAssetManifest -Root $root)
ConvertTo-AsciiJson -Value ([ordered]@{
    plan = $plan
    after = Get-RootPlan -Root $root -PackagedPath $packaged
})
"""
        )
        self.assertEqual("finish", report["plan"])
        self.assertEqual("current", report["after"])
        self.assertEqual(other, (self.fixture.root / HELPER_NAME).read_bytes())
        manifest = json.loads((self.fixture.root / "assets-manifest.json").read_text("utf-8"))
        record = next(record for record in manifest["files"] if record["name"] == HELPER_NAME)
        self.assertEqual({"name": HELPER_NAME, "bytes": len(other), "sha256": hashlib.sha256(other).hexdigest()}, record)
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

    def test_a_swap_that_silently_does_nothing_is_caught_and_undone(self):
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$manifestBefore = Get-Sha256Hex -Path (Join-Path $root 'assets-manifest.json')
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$realMove = ${function:Move-FileReplacing}
function Move-FileReplacing {
    param([string]$Source, [string]$Target)

    # Reports success for the manifest and moves nothing.
    if ($Target.EndsWith('assets-manifest.json')) {
        return
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
ConvertTo-AsciiJson -Value ([ordered]@{
    message = $message
    manifest_unchanged = ((Get-Sha256Hex -Path (Join-Path $root 'assets-manifest.json')) -ceq $manifestBefore)
    plan_after = Get-RootPlan -Root $root -PackagedPath $packaged
})
"""
        )
        self.assertEqual(
            "The refreshed rclone password helper could not be confirmed. Register the check again.", report["message"]
        )
        self.assertTrue(report["manifest_unchanged"])
        # The helper was swapped, and put back once the manifest turned out not to be.
        self.assertEqual(earlier_helper(2), (self.fixture.root / HELPER_NAME).read_bytes())
        self.assertEqual("refresh", report["plan_after"])

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
        # What happened and what to do first, then the reason, which may carry its own next step.
        self.assertEqual(
            [
                "The earlier rclone password helper could not be put back. Registering the check again finishes the "
                "update. Stand-in: the file could not be replaced."
            ],
            report["warnings"],
        )
        self.assertEqual("finish", report["cut_short"])
        self.assertEqual("current", report["after"])
        self.assertEqual(self.fixture.packaged.read_bytes(), (self.fixture.root / HELPER_NAME).read_bytes())
        # The earlier helper is kept by the first attempt, the manifest it recorded by both.
        kept = sorted(path.name for folder in self.evidence_folders() for path in folder.iterdir())
        self.assertIn(HELPER_NAME + ".previous", kept)
        self.assertEqual(2, kept.count("assets-manifest.json.previous"))
        verifier_accepts(self, self.fixture.root)

    def test_a_helper_that_was_never_replaced_is_not_reported_as_not_put_back(self):
        # Another program opens the helper, shares it with no one, and keeps it open: its rename is refused, so the
        # earlier helper is still in place and nothing needs putting back.
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$realMove = ${function:Move-FileReplacing}
$script:holder = $null
function Move-FileReplacing {
    param([string]$Source, [string]$Target)

    if ($Target.EndsWith('reveal-rclone-config-password.ps1') -and $null -eq $script:holder) {
        $script:holder = [IO.File]::Open($Target, 'Open', 'Read', 'None')
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
finally {
    if ($null -ne $script:holder) {
        $script:holder.Dispose()
    }
}
ConvertTo-AsciiJson -Value ([ordered]@{
    held = $null -ne $script:holder
    message = $message
    warnings = $warnings
    plan_after = Get-RootPlan -Root $root -PackagedPath $packaged
})
"""
        )
        self.assertTrue(report["held"], "the helper was never held open")
        self.assertRegex(
            report["message"],
            "^Could not replace " + re.escape(str(self.fixture.root / HELPER_NAME)) + " with .+ If another program",
        )
        self.assertEqual([], report["warnings"], "a helper that was never replaced was reported as not put back")
        self.assertEqual(earlier_helper(2), (self.fixture.root / HELPER_NAME).read_bytes())
        self.assertEqual("refresh", report["plan_after"])

    def test_assets_that_change_before_the_swap_are_left_alone(self):
        # Just after the run lock is taken, one file changes: the helper or the manifest in the assets root, or one of
        # the replacements written into the evidence folder. The refresh stops before it swaps anything.
        report = self.probe(
            r"""
$realEnter = ${function:Enter-ProtectedRunLock}
function Enter-ProtectedRunLock {
    param([string]$Path)

    $taken = & $realEnter -Path $Path
    if ($script:changeName.EndsWith('.new')) {
        $file = @(Get-ChildItem -LiteralPath (Join-Path $script:changeRoot 'evidence') -Recurse -File -Force |
            Where-Object { $_.Name -ceq $script:changeName })[0].FullName
    }
    else {
        $file = Join-Path $script:changeRoot $script:changeName
    }
    [IO.File]::AppendAllText($file, ' ')
    return $taken
}
$results = [ordered]@{}
foreach ($name in @('assets-manifest.json', 'reveal-rclone-config-password.ps1', 'assets-manifest.json.new',
        'reveal-rclone-config-password.ps1.new')) {
    $script:changeName = $name
    $script:changeRoot = Join-Path (Split-Path -Parent $root) ('assets-' + $name)
    New-AssetsRoot -Root $script:changeRoot -HelperBytes $earlierBytes
    $manifestBefore = [IO.File]::ReadAllText((Join-Path $script:changeRoot 'assets-manifest.json'))
    $plan = Get-RootPlan -Root $script:changeRoot -PackagedPath $packaged
    $message = ''
    try {
        [void](Invoke-Refresh -Root $script:changeRoot -Plan $plan -PackagedPath $packaged -LockPath $lockPath)
    }
    catch {
        $message = $_.Exception.Message
    }
    $lock = & $realEnter -Path $lockPath
    $lockFree = $null -ne $lock
    Exit-ProtectedRunLock -Stream $lock
    $results[$name] = [ordered]@{
        plan = $plan
        message = $message
        manifest_before = $manifestBefore
        manifest = [IO.File]::ReadAllText((Join-Path $script:changeRoot 'assets-manifest.json'))
        evidence = @(Get-ChildItem -LiteralPath (Join-Path $script:changeRoot 'evidence') -Force | ForEach-Object { $_.Name })
        lock_free = $lockFree
    }
}
ConvertTo-AsciiJson -Value $results
"""
        )
        changed = "The protected rclone assets changed while this setup ran, so they were left as they are. Run it again."
        earlier = earlier_helper(2)
        for name, result in report.items():
            with self.subTest(name):
                self.assertEqual("refresh", result["plan"])
                self.assertEqual(changed, result["message"])
                # Nothing was swapped: the two files are as they were, but for the change made under the lock.
                helper = (self.temp / ("assets-" + name) / HELPER_NAME).read_bytes()
                self.assertEqual(earlier + b" " if name == HELPER_NAME else earlier, helper)
                expected_manifest = result["manifest_before"] + " " if name == "assets-manifest.json" else result["manifest_before"]
                self.assertEqual(expected_manifest, result["manifest"])
                self.assertEqual([], result["evidence"], "the replacements were left behind")
                self.assertTrue(result["lock_free"], "the run lock was still held afterwards")
        self.assertEqual(4, len(report))

    def test_a_plan_that_does_not_fit_the_folder_is_refused_before_anything_is_written(self):
        # The refresh makes its own plan from the files it reads and refuses one handed to it that differs. Otherwise
        # 'finish' would record a helper no Rewindle shipped, and 'refresh' would replace a current helper.
        report = self.probe(
            r"""
$results = [ordered]@{}
foreach ($case in @('stranger', 'current')) {
    $caseRoot = Join-Path (Split-Path -Parent $root) ('assets-' + $case)
    if ($case -ceq 'stranger') {
        # Generation 2 with a line added, while the manifest still records generation 2.
        New-AssetsRoot -Root $caseRoot -HelperBytes $earlierBytes
        [IO.File]::AppendAllText((Join-Path $caseRoot 'reveal-rclone-config-password.ps1'), "# added`n")
        $wrong = 'finish'
    }
    else {
        New-AssetsRoot -Root $caseRoot -HelperBytes ([IO.File]::ReadAllBytes($packaged))
        $wrong = 'refresh'
    }
    $before = Get-FolderSnapshot -Root $caseRoot
    $script:treeChecks = @()
    $message = ''
    try {
        [void](Invoke-Refresh -Root $caseRoot -Plan $wrong -PackagedPath $packaged -LockPath $lockPath)
    }
    catch {
        $message = $_.Exception.Message
    }
    $results[$case] = [ordered]@{
        message = $message
        unchanged = ((ConvertTo-Json $before) -ceq (ConvertTo-Json (Get-FolderSnapshot -Root $caseRoot)))
        tree_checks = @($script:treeChecks).Count
    }
}
ConvertTo-AsciiJson -Value $results
"""
        )
        for case in ("stranger", "current"):
            with self.subTest(case):
                self.assertIn("The protected rclone assets changed while this setup ran", report[case]["message"])
                self.assertTrue(report[case]["unchanged"], "the assets folder changed")
                self.assertEqual(0, report[case]["tree_checks"], "the refresh wrote its copies before refusing")

    def test_a_packaged_helper_that_changes_meanwhile_is_not_put_in(self):
        # The installer hashes the packaged helper when it starts and reads it again for the refresh. Bytes that differ
        # from that hash are refused, so only the helper the runtime's manifest vouched for can go in.
        report = self.probe(
            r"""
New-AssetsRoot -Root $root -HelperBytes $earlierBytes
$before = Get-FolderSnapshot -Root $root
$plan = Get-RootPlan -Root $root -PackagedPath $packaged
$packagedSha256 = Get-Sha256Hex -Path $packaged
[IO.File]::AppendAllText($packaged, "# changed`n")
$message = ''
try {
    [void](Update-ProtectedPasswordHelper `
        -Root $root `
        -Plan $plan `
        -HelperName 'reveal-rclone-config-password.ps1' `
        -PackagedHelperPath $packaged `
        -PackagedHelperSha256 $packagedSha256 `
        -Generations (Get-KnownPasswordHelperGenerations) `
        -RunLockPath $lockPath `
        -CurrentUserSid ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
}
catch {
    $message = $_.Exception.Message
}
ConvertTo-AsciiJson -Value ([ordered]@{
    plan = $plan
    message = $message
    unchanged = ((ConvertTo-Json $before) -ceq (ConvertTo-Json (Get-FolderSnapshot -Root $root)))
})
"""
        )
        self.assertEqual("refresh", report["plan"])
        self.assertEqual("The packaged rclone password helper changed while this setup ran. Run it again.", report["message"])
        self.assertTrue(report["unchanged"], "the assets folder changed")

    def test_only_the_password_helper_may_differ_from_its_record(self):
        # Reading the assets for the plan lets the helper's file differ from its record, which a refresh cut short
        # leaves. Every other asset must still match it.
        report = self.probe(
            r"""
$results = [ordered]@{}
foreach ($name in @('rclone.exe', 'rclone-readonly.conf', 'rclone-config-password.clixml',
        'reveal-rclone-config-password.ps1')) {
    $caseRoot = Join-Path (Split-Path -Parent $root) ('assets-' + $name)
    New-AssetsRoot -Root $caseRoot -HelperBytes $earlierBytes
    # One byte changes; the size stays.
    $path = Join-Path $caseRoot $name
    $bytes = [IO.File]::ReadAllBytes($path)
    $bytes[0] = $bytes[0] -bxor 1
    [IO.File]::WriteAllBytes($path, $bytes)
    try {
        [void](Read-VerifiedAssetManifest -Root $caseRoot -AllowPasswordHelperMismatch)
        $results[$name] = ''
    }
    catch {
        $results[$name] = $_.Exception.Message
    }
}
ConvertTo-AsciiJson -Value $results
"""
        )
        for name in ("rclone.exe", "rclone-readonly.conf", "rclone-config-password.clixml"):
            with self.subTest(name):
                self.assertEqual("Cloud-verification asset size or hash mismatch: " + name, report[name])
        self.assertEqual("", report[HELPER_NAME])

    def test_the_plan_refuses_assets_it_cannot_bring_up_to_date(self):
        # The plan the installer makes from the assets refuses, with what to do: a helper no Rewindle shipped, assets
        # set up by a newer Rewindle, and a packaged helper this Rewindle does not know.
        stranger = self.temp / "stranger-helper.ps1"
        stranger.write_bytes(earlier_helper(2) + b"# added\n")
        report = self.probe(
            "\n".join(["$stranger = " + ps_literal(stranger), "$earlierPath = " + ps_literal(self.fixture.earlier)])
            + r"""
$results = [ordered]@{}
# The case, the helper in the assets, the packaged helper.
foreach ($case in @(
        @('unknown', $stranger, $packaged),
        @('newer', $packaged, $earlierPath),
        @('packaged_unknown', $earlierPath, $stranger))) {
    $caseRoot = Join-Path (Split-Path -Parent $root) ('assets-' + $case[0])
    New-AssetsRoot -Root $caseRoot -HelperBytes ([IO.File]::ReadAllBytes($case[1]))
    try {
        $results[$case[0]] = 'allowed: ' + (Get-RootPlan -Root $caseRoot -PackagedPath $case[2])
    }
    catch {
        $results[$case[0]] = $_.Exception.Message
    }
}
ConvertTo-AsciiJson -Value $results
"""
        )
        self.assertIn("no version of Rewindle shipped", report["unknown"])
        self.assertIn("Move " + str(self.temp / "assets-unknown") + " aside", report["unknown"])
        self.assertIn("set up by a newer version of Rewindle", report["newer"])
        self.assertIn("does not recognise its own rclone password helper", report["packaged_unknown"])

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
# Another program has the source open and does not let it be deleted (Windows says it is in use, not that access is
# denied): also tried again, then refused.
$sourceReader = [IO.File]::Open($source, 'Open', 'Read', 'Read')
$sourceRefusal = ''
$sourceWatch = [Diagnostics.Stopwatch]::StartNew()
try {
    Move-FileReplacing -Source $source -Target $target
}
catch {
    $sourceRefusal = $_.Exception.Message
}
finally {
    $sourceReader.Dispose()
}
$sourceSeconds = $sourceWatch.Elapsed.TotalSeconds
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
    source_refusal = $sourceRefusal
    source_seconds = $sourceSeconds
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
        # Both files, Windows' reason in its own language, then what to do.
        refused = re.compile(
            "^Could not replace "
            + re.escape(str(self.fixture.state / "target.txt"))
            + " with "
            + re.escape(str(self.fixture.state / "source.txt"))
            + r" \(.+\)\. If another program has either file open, close it, then register the check again\.$"
        )
        self.assertRegex(report["refusal"], refused)
        self.assertGreater(report["seconds"], 0.5, "a target in use was not tried again")
        self.assertRegex(report["source_refusal"], refused)
        self.assertGreater(report["source_seconds"], 0.5, "a source in use was not tried again")
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
    """Where the refresh sits in the installer's main flow, which only an elevated registration runs. Python reads the
    script with universal newlines, so a CRLF checkout reads the same."""

    TEXT = INSTALLER.read_text("utf-8")

    def position(self, anchor: str, start: int = 0) -> int:
        at = self.TEXT.find(anchor, start)
        self.assertGreaterEqual(at, 0, f"not found in the installer: {anchor}")
        return at

    def function_span(self, name: str) -> tuple[int, int]:
        start = self.position(f"\nfunction {name} {{") + 1
        end = self.TEXT.find("\n}\n", start)
        self.assertGreater(end, start, f"the end of {name} was not found")
        return start, end + 2

    def calls(self, name: str) -> list[int]:
        """Where each line that uses the name starts, leaving out comments and the function's own definition."""
        found = []
        offset = 0
        for line in self.TEXT.splitlines(keepends=True):
            code = line.lstrip()
            if (
                not code.startswith("#")
                and not code.startswith(f"function {name} ")
                and re.search(rf"(?<![\w-]){re.escape(name)}(?![\w-])", line)
            ):
                found.append(offset)
            offset += len(line)
        return found

    def test_validate_only_reports_the_plan_and_changes_nothing(self):
        plan = self.position("\n    $passwordHelperState = Get-AssetPasswordHelperPlan `\n") + 1
        validate_only = self.position("\nif ($ValidateOnly) {\n", plan)
        returned = self.position("\n    return\n}\n", validate_only)
        self.assertEqual([plan], self.calls("Get-AssetPasswordHelperPlan"))
        # The refresh step runs once, from the main flow, after -ValidateOnly has returned; the refresh itself runs only
        # from that step.
        step = self.calls("Invoke-PasswordHelperRefresh")
        self.assertEqual(1, len(step), "Invoke-PasswordHelperRefresh is called more than once")
        self.assertGreater(step[0], returned)
        step_start, step_end = self.function_span("Invoke-PasswordHelperRefresh")
        update = self.calls("Update-ProtectedPasswordHelper")
        self.assertEqual(1, len(update), "Update-ProtectedPasswordHelper is called more than once")
        self.assertTrue(step_start < update[0] < step_end, "Update-ProtectedPasswordHelper runs outside the refresh step")

    def test_the_refresh_runs_after_every_check_and_before_the_task_is_registered(self):
        elevated = self.position("\nAssert-Elevated\n")
        running = self.position("if ([string]$existingTask.State -eq 'Running') {", elevated)
        other_account = self.position("Refusing to replace a Google Drive task owned by another account.", running)
        refresh = self.position("    $passwordHelperRefresh = Invoke-PasswordHelperRefresh `", other_account)
        merged = self.position("        $validation[$field] = $passwordHelperRefresh[$field]", refresh)
        # The first registration after the checks is the real one; the one in the catch block puts the earlier task
        # back.
        registered = self.position("ScheduledTasks\\Register-ScheduledTask `", other_account)
        self.assertLess(merged, registered, "the refresh runs after the task is registered")

    def test_the_refresh_is_wired_to_the_assets_the_runtime_and_the_account(self):
        # The main flow's two calls as they must read: the plan from the manifest just read, the assets root and the
        # runtime's helper; the refresh only when the plan is not 'current', with the run lock and this account, and
        # its fields put into the report.
        for block in (
            [
                "if ($null -ne $assetManifest) {",
                "    $passwordHelperState = Get-AssetPasswordHelperPlan `",
                "        -Manifest $assetManifest `",
                "        -Root $cloudVerificationRootFull `",
                "        -HelperName $passwordHelperName `",
                "        -PackagedHelperSha256 $packagedPasswordHelperSha256",
                "    $passwordHelperPlan = $passwordHelperState.Plan",
                "    $recordedPasswordHelperSha256 = $passwordHelperState.RecordedSha256",
                "}",
            ],
            [
                "if ($null -ne $passwordHelperPlan -and $passwordHelperPlan -cne 'current') {",
                "    $passwordHelperRefresh = Invoke-PasswordHelperRefresh `",
                "        -Root $cloudVerificationRootFull `",
                "        -Plan $passwordHelperPlan `",
                "        -HelperName $passwordHelperName `",
                "        -PackagedHelperPath $passwordHelperPath `",
                "        -PackagedHelperSha256 $packagedPasswordHelperSha256 `",
                "        -RunLockPath $runLockPath `",
                "        -CurrentUserSid $userSid",
                "    foreach ($field in @($passwordHelperRefresh.Keys)) {",
                "        $validation[$field] = $passwordHelperRefresh[$field]",
                "    }",
                "}",
            ],
        ):
            with self.subTest(block[1].strip()):
                self.assertIn("\n" + "\n".join(block) + "\n", self.TEXT)
        # What those names hold: the runtime's helper and its hash, the run lock, and this account.
        for definition in (
            "$passwordHelperName = 'reveal-rclone-config-password.ps1'",
            "$passwordHelperPath = Join-Path $protectedRootFull $passwordHelperName",
            "$packagedPasswordHelperSha256 = Get-Sha256Hex -Path $passwordHelperPath",
            "$runLockPath = Join-Path $stateDirectoryFull 'run.lock'",
            "$userSid = $identity.User.Value",
        ):
            with self.subTest(definition):
                self.assertIn("\n" + definition + "\n", self.TEXT)

    def test_the_swap_happens_under_the_run_lock_after_the_permission_check(self):
        start, end = self.function_span("Update-ProtectedPasswordHelper")
        body = self.TEXT[start:end]
        order = [
            "Assert-ProtectedTreeAcl -Path $Root -CurrentUserSid $CurrentUserSid",
            "$lock = Enter-ProtectedRunLock -Path $RunLockPath",
            "(Get-Sha256Hex -Path $stagedHelper) -cne $newHelperSha256",
            "$swapStarted = $true",
            "Move-FileReplacing -Source $stagedHelper -Target $helperPath",
            "Move-FileReplacing -Source $stagedManifest -Target $manifestPath",
            "finally {",
            # The way back runs while the lock is still held.
            "Move-FileReplacing -Source $rollback -Target $helperPath",
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
