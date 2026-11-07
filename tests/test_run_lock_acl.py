"""run.lock stays a file only Administrators and SYSTEM can open, wherever it is created or opened.

Every backup and protected change takes byte zero of run.lock, and Windows lets any handle that can read a file lock
its bytes. The state folder is readable by the user, so a file that simply inherits its permissions lets any program
running with standard rights hold the lock and keep backups and the managers from ever starting. The engine
(restic_common.RunLock, tested in test_core), the four managers that take the lock and the installer, which resets
the state folder's permissions, all give run.lock the same Administrators and SYSTEM only permissions. These checks
read the scripts and run their permission functions in Windows PowerShell; nothing is elevated or installed.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "src"))

import restic_common  # noqa: E402


MANAGERS = tuple(
    PROJECT / "src" / name
    for name in ("Manage-Sources.ps1", "Manage-Repository.ps1", "Manage-Schedule.ps1", "Manage-Restore.ps1")
)
INSTALLER = PROJECT / "installer" / "Install-ResticBackuper.ps1"
POLICY_FUNCTIONS = ("New-RunLockSecurity", "Test-RunLockSecurity", "Protect-RunLock")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def function_text(script: str, name: str) -> str:
    matches = re.findall(rf"(?ms)^function {re.escape(name)} \{{\n.*?^\}}\n", script)
    if len(matches) != 1:
        raise AssertionError(f"expected exactly one function {name}, found {len(matches)}")
    return matches[0]


class RunLockSourceTests(unittest.TestCase):
    def test_every_manager_opens_run_lock_through_the_protected_opener(self) -> None:
        for manager in MANAGERS:
            with self.subTest(manager=manager.name):
                script = read(manager)
                enter = function_text(script, "Enter-RunLock")
                self.assertIn("Open-RunLockFile -File", enter)
                self.assertNotIn("[IO.File]::Open(", enter)
                opener = function_text(script, "Open-RunLockFile")
                # Only the disposable test mode opens the file without the policy.
                test_branch, protected_branch = opener.split("if ($isTestMode) {", 1)[1].split("}", 1)
                self.assertIn("[IO.File]::Open(", test_branch)
                self.assertNotIn("[IO.File]::Open(", protected_branch)
                # A new file is born with the policy, and an existing one is repaired before the lock is taken.
                self.assertRegex(protected_branch, r"\[IO\.FileStream\]::new\(\$File,[^;]*\$security\)")
                self.assertIn("Protect-RunLock -File $File -Policy $security", protected_branch)
                self.assertLess(enter.index("Open-RunLockFile"), enter.index(".Lock(0, 1)"))
                # A program holding the file open without sharing makes the open fail, but must not stop the repair.
                after_open = protected_branch.split("[IO.FileStream]::new($File,", 1)[1]
                refused = after_open.split("catch {", 1)[1].split("\n    }\n", 1)[0]
                self.assertIn("Protect-RunLock -File $File -Policy (New-RunLockSecurity)", refused)
                self.assertLess(refused.index("Protect-RunLock"), refused.index("throw $openFailure"))

    def test_the_installer_protects_run_lock_after_resetting_the_state_folder(self) -> None:
        script = read(INSTALLER)
        calls = [match.start() for match in re.finditer(r"(?m)^ *Protect-RunLockFile -StateRoot \$stateRoot *$", script)]
        self.assertEqual(1, len(calls), "the installer must protect run.lock once, in its permissions step")
        resets = [match.start() for match in re.finditer(r"(?m)^ *Set-ProtectedDirectory -Path \$stateRoot\b", script)]
        self.assertTrue(resets)
        self.assertLess(
            max(resets), calls[0], "the installer must protect run.lock after it last resets the state folder"
        )
        phase = script.index("Start-InstallPhase 'permissions'")
        self.assertLess(phase, calls[0])
        self.assertLess(calls[0], script.index("Complete-InstallPhase 'permissions'", phase))
        protect = function_text(script, "Protect-RunLockFile")
        self.assertIn("New-RunLockSecurity", protect)
        self.assertIn("Protect-RunLock -File $file -Policy $security", protect)
        self.assertNotIn("[IO.File]::Open(", protect)
        # An existing file is repaired by its path and never opened, so a program that holds it open, even without
        # sharing, can stop neither the repair nor the upgrade.
        existing, _created = protect.split("    $security = New-RunLockSecurity\n", 1)
        self.assertIn("Protect-RunLock -File $file -Policy (New-RunLockSecurity)\n        return\n", existing)
        self.assertNotIn("FileStream", existing)

    def test_a_failed_repair_says_what_to_do(self) -> None:
        protect = function_text(read(MANAGERS[0]), "Protect-RunLock")
        self.assertRegex(protect, r"could not be limited to Administrators and SYSTEM\. An administrator can delete it")

    def test_every_copy_of_the_run_lock_policy_is_the_same(self) -> None:
        # The managers and the installer run alone, each with its own copy; they must not drift apart.
        reference = read(MANAGERS[0])
        for path in (*MANAGERS[1:], INSTALLER):
            script = read(path)
            for name in POLICY_FUNCTIONS:
                with self.subTest(script=path.name, function=name):
                    self.assertEqual(function_text(reference, name), function_text(script, name))

    def test_the_engine_and_the_scripts_ask_for_the_same_permissions(self) -> None:
        self.assertEqual("O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)", restic_common.RUN_LOCK_SDDL)
        policy = function_text(read(MANAGERS[0]), "New-RunLockSecurity")
        self.assertIn("SetAccessRuleProtection($true, $false)", policy)
        self.assertIn("SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))", policy)
        self.assertIn("@('S-1-5-18', 'S-1-5-32-544')", policy)
        self.assertIn("FileSystemRights]::FullControl", policy)

    def test_the_dashboard_never_opens_run_lock(self) -> None:
        # The dashboard runs with standard rights and cannot open run.lock. It must never need to, and must never
        # read a refused open as "nothing is running".
        dashboard = PROJECT / "src" / "dashboard"
        sources = [
            *dashboard.glob("*.cs"),
            *(dashboard / "web" / "src").rglob("*.ts"),
            *(dashboard / "web" / "src").rglob("*.tsx"),
        ]
        self.assertTrue(sources)
        for path in sources:
            with self.subTest(path=path.relative_to(PROJECT).as_posix()):
                self.assertNotRegex(read(path), r"(?i)run[._]lock")


POLICY_PROBE = r"""
param([string]$Script, [string]$Work)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errors)
if ($errors.Count -ne 0) { throw "$Script does not parse." }
$wanted = @('New-RunLockSecurity', 'Test-RunLockSecurity', 'Open-RunLockFile')
$found = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $true))
. ([scriptblock]::Create((($found | ForEach-Object { $_.Extent.Text }) -join "`n")))

function Edit-Policy {
    param([scriptblock]$Change)
    $security = New-RunLockSecurity
    & $Change $security
    return $security
}
$system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
$administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
$allow = [Security.AccessControl.AccessControlType]::Allow
$results = [ordered]@{}
$results['policy'] = Test-RunLockSecurity -Acl (New-RunLockSecurity)
$results['readable by users'] = Test-RunLockSecurity -Acl (Edit-Policy { param($s) $s.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', $allow)) })
$results['inherits'] = Test-RunLockSecurity -Acl (Edit-Policy { param($s) $s.SetAccessRuleProtection($false, $true) })
$results['owned by SYSTEM'] = Test-RunLockSecurity -Acl (Edit-Policy { param($s) $s.SetOwner($system) })
$results['no SYSTEM'] = Test-RunLockSecurity -Acl (Edit-Policy { param($s) [void]$s.RemoveAccessRuleAll([Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', $allow)) })
$results['Administrators may only modify'] = Test-RunLockSecurity -Acl (Edit-Policy { param($s) $s.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, 'Modify', $allow)) })
$results['denies'] = Test-RunLockSecurity -Acl (Edit-Policy { param($s) $s.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'Write', [Security.AccessControl.AccessControlType]::Deny)) })
$inherited = Join-Path $Work 'inherited.lock'
[IO.File]::WriteAllBytes($inherited, [byte[]](0))
$results['a file with inherited permissions'] = Test-RunLockSecurity -Acl ([IO.File]::GetAccessControl($inherited, 'Owner, Access'))
$isTestMode = $true
$created = Join-Path $Work 'created.lock'
$stream = Open-RunLockFile -File $created
try { $results['test mode opens a plain file'] = ($stream -is [IO.FileStream]) -and $stream.CanWrite -and [IO.File]::Exists($created) }
finally { $stream.Dispose() }
$results | ConvertTo-Json -Compress
"""


class RunLockPolicyBehaviourTests(unittest.TestCase):
    def test_the_policy_accepts_only_an_administrators_and_system_file(self) -> None:
        expected = {
            "policy": True,
            "readable by users": False,
            "inherits": False,
            "owned by SYSTEM": False,
            "no SYSTEM": False,
            "Administrators may only modify": False,
            "denies": False,
            "a file with inherited permissions": False,
            "test mode opens a plain file": True,
        }
        with tempfile.TemporaryDirectory(prefix="resticbackuper-run-lock-policy-") as root_text:
            probe = Path(root_text) / "probe.ps1"
            probe.write_text(POLICY_PROBE, encoding="ascii", newline="\n")
            for manager in MANAGERS:
                with self.subTest(manager=manager.name):
                    work = Path(root_text) / manager.stem
                    work.mkdir()
                    result = subprocess.run(
                        [
                            "powershell.exe",
                            "-NoProfile",
                            "-NonInteractive",
                            "-ExecutionPolicy",
                            "Bypass",
                            "-File",
                            str(probe),
                            "-Script",
                            str(manager),
                            "-Work",
                            str(work),
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        encoding="utf-8",
                        errors="replace",
                        timeout=120,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual(expected, json.loads(result.stdout.strip().splitlines()[-1]))


OPENER_PROBE = r"""
param([string]$Script, [string]$Work)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$errors)
if ($errors.Count -ne 0) { throw "$Script does not parse." }
$wanted = @('Protect-RunLock', 'Open-RunLockFile', 'Protect-RunLockFile')
$found = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted }, $true))
. ([scriptblock]::Create((($found | ForEach-Object { $_.Extent.Text }) -join "`n")))

# The script's own policy makes Administrators the owner, which only an elevated process may do. As test_core does for
# the engine, this probe applies the same DACL without the owner part.
function New-RunLockSecurity {
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    return $security
}
function Test-RunLockSecurity {
    param([Security.AccessControl.FileSystemSecurity]$Acl)
    if (-not $Acl.AreAccessRulesProtected) { return $false }
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            -not $seen.Add($rule.IdentityReference.Value)) {
            return $false
        }
    }
    return $seen.SetEquals([string[]]@('S-1-5-18', 'S-1-5-32-544'))
}

$isTestMode = $false
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-Outcome {
    param([string]$File)
    $state = if (Test-RunLockSecurity -Acl ([IO.File]::GetAccessControl($File, 'Access'))) { 'protected' } else { 'open to others' }
    # Unelevated, this process stands for a program with standard rights, which must no longer be able to open it.
    if ($elevated) { return "$state/not checked" }
    try { ([IO.File]::Open($File, 'Open', 'Read', 'ReadWrite')).Dispose(); return "$state/opened" }
    catch {
        if ($_.Exception.GetBaseException() -is [UnauthorizedAccessException]) { return "$state/denied" }
        throw
    }
}

function New-InheritedFile {
    param([string]$Folder)
    [void][IO.Directory]::CreateDirectory($Folder)
    $file = Join-Path $Folder 'run.lock'
    [IO.File]::WriteAllBytes($file, [byte[]](0))
    return $file
}

function Invoke-Step {
    param([string]$File)
    if (Get-Command Protect-RunLockFile -ErrorAction SilentlyContinue) {
        Protect-RunLockFile -StateRoot (Split-Path -Parent $File)
    }
    else {
        (Open-RunLockFile -File $File).Dispose()
    }
}

$results = [ordered]@{ elevated = $elevated }
$created = Join-Path (Join-Path $Work 'new') 'run.lock'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $created))
Invoke-Step -File $created
$results['create'] = Get-Outcome -File $created

$inherited = New-InheritedFile -Folder (Join-Path $Work 'inherited')
Invoke-Step -File $inherited
$results['repair'] = Get-Outcome -File $inherited

# A program that opened the older, user-readable file without sharing, and keeps it open.
$held = New-InheritedFile -Folder (Join-Path $Work 'held')
$holder = [IO.File]::Open($held, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    try { Invoke-Step -File $held; $results['held step'] = 'went ahead' }
    catch { $results['held step'] = 'refused' }
    $results['held repaired while open'] = Test-RunLockSecurity -Acl ([IO.File]::GetAccessControl($held, 'Access'))
}
finally { $holder.Dispose() }
$results['held'] = Get-Outcome -File $held
$results | ConvertTo-Json -Compress
"""


class RunLockOpenerBehaviourTests(unittest.TestCase):
    """Run each script's protected opener (not its test mode) on real files, as the managers and the installer do."""

    def run_probe(self, script: Path, work: Path) -> dict:
        probe = work.parent / "opener-probe.ps1"
        if not probe.exists():
            probe.write_text(OPENER_PROBE, encoding="ascii", newline="\n")
        work.mkdir()
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(probe),
                "-Script",
                str(script),
                "-Work",
                str(work),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    @staticmethod
    def protected(elevated: bool) -> str:
        return "protected/not checked" if elevated else "protected/denied"

    def test_the_managers_repair_run_lock_even_while_a_program_holds_it_without_sharing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-run-lock-opener-") as root_text:
            for manager in MANAGERS:
                with self.subTest(manager=manager.name):
                    result = self.run_probe(manager, Path(root_text) / manager.stem)
                    protected = self.protected(result["elevated"])
                    self.assertEqual(protected, result["create"])
                    self.assertEqual(protected, result["repair"])
                    # The manager cannot take the lock, and says so, but the file is repaired all the same.
                    self.assertEqual("refused", result["held step"])
                    self.assertTrue(result["held repaired while open"])
                    self.assertEqual(protected, result["held"])

    def test_the_installer_repairs_run_lock_even_while_a_program_holds_it_without_sharing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-run-lock-opener-") as root_text:
            result = self.run_probe(INSTALLER, Path(root_text) / "installer")
            protected = self.protected(result["elevated"])
            self.assertEqual(protected, result["create"])
            self.assertEqual(protected, result["repair"])
            # The upgrade goes on: it never needs the file's contents.
            self.assertEqual("went ahead", result["held step"])
            self.assertTrue(result["held repaired while open"])
            self.assertEqual(protected, result["held"])


if __name__ == "__main__":
    unittest.main()
