import csv
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = (
    PROJECT / "src" / "verify_my_drive_cloud_repository.ps1"
).read_text(encoding="utf-8")
PASSWORD_HELPER = (
    PROJECT / "src" / "reveal-rclone-config-password.ps1"
).read_text(encoding="utf-8")


def powershell_function(text: str, name: str) -> str:
    start = text.index(f"function {name} {{")
    return text[start : text.index("\n}\n", start) + 3]


def powershell_functions(text: str, *names: str) -> str:
    return "\n".join(powershell_function(text, name) for name in names)


def powershell_block(text: str, opening: str) -> str:
    """The script-level block whose first line is `opening` (no indentation), up to its closing brace."""
    start = text.index("\n" + opening + "\n") + 1
    return text[start : text.index("\n}\n", start) + 3]


def run_probe_json(test: unittest.TestCase, probe: str) -> dict:
    completed = run_windows_powershell(probe)
    test.assertEqual(0, completed.returncode, completed.stdout + completed.stderr)
    return json.loads(completed.stdout.strip().splitlines()[-1])


def ps_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


# Stand-ins for the probes: the permission checks need folders that only an elevated administrator can make, and the
# probes run unelevated.
ACL_STAND_IN = (
    "function Assert-ProtectedAcl { param([string]$Path, [string]$CurrentUserSid, "
    "[switch]$RequireProtectedInheritance) }\n"
)
FAILURE_FUNCTIONS = (
    "Get-CheckStepLabel",
    "Set-CheckStep",
    "New-CheckFailureDetail",
    "Stop-Check",
    "Get-CheckFailureDescription",
    "Format-FileCount",
    "Get-InventoryFailureDetail",
    "Write-AtomicJson",
    "Write-CheckFailureRecord",
)
PROBE_HEADER = "\n".join(
    [
        "Set-StrictMode -Version Latest",
        "$ErrorActionPreference = 'Stop'",
        "$script:checkStep = 'checking_setup'",
        "$script:checkFailureDetail = $null",
        "$script:failureRecordTarget = $null",
        "",
    ]
)


def powershell_statement(text: str, opening: str) -> str:
    """The statement whose first line is `opening`, up to the first later line
    that holds only a closing parenthesis at the same indentation."""
    start = text.index("\n" + opening + "\n") + 1
    indent = opening[: len(opening) - len(opening.lstrip())]
    close = "\n" + indent + ")\n"
    return text[start : text.index(close, start) + len(close)]


def run_windows_powershell(probe: str) -> subprocess.CompletedProcess:
    """Runs the probe script in Windows PowerShell 5.1, with no window."""
    system = os.environ.get("SystemRoot", r"C:\Windows")
    powershell = os.path.join(
        system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"
    )
    with tempfile.TemporaryDirectory(
        prefix="rewindle-verifier-probe-", ignore_cleanup_errors=True
    ) as temp:
        script = Path(temp) / "probe.ps1"
        script.write_text(probe, encoding="ascii", newline="\n")
        return subprocess.run(
            [
                powershell,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )


def split_password_command(command: str) -> list[str]:
    """Splits a password command roughly the way rclone reads
    RCLONE_PASSWORD_COMMAND: Go's encoding/csv with a space as the separator,
    so double quotes group a field that holds spaces. Python's csv differs
    from Go's for a quote inside an unquoted field (Go refuses it), so that is
    refused here. An empty field (a leading, trailing or doubled space) is
    refused too: Restic's splitter would drop it, and it is always a typo."""
    rows = list(
        csv.reader([command], delimiter=" ", quotechar='"', strict=True)
    )
    if len(rows) != 1:
        raise ValueError(f"not one command line: {command!r}")
    fields = rows[0]
    if any(not field or '"' in field for field in fields):
        raise ValueError(f"an empty field or a stray quote: {command!r}")
    return fields


def native_launches(text: str) -> list[str]:
    """Return each Invoke-RequiredNative / Invoke-NativeToFiles call."""
    lines = text.splitlines()
    launches = []
    for index, line in enumerate(lines):
        if not re.match(
            r"^\s*(?:\$\w+ = )?Invoke-(?:RequiredNative|NativeToFiles) `$", line
        ):
            continue
        depth = 0
        block = []
        for current in lines[index:]:
            block.append(current)
            depth += current.count("(") - current.count(")")
            if depth <= 0 and not current.rstrip().endswith("`"):
                break
        launches.append("\n".join(block))
    return launches


class MyDriveCloudVerifierScriptTests(unittest.TestCase):
    def test_paths_are_configuration_derived_and_user_neutral(self):
        self.assertIn("$configuredRepository", SCRIPT)
        self.assertIn("$configuredMyDriveRoot", SCRIPT)
        self.assertIn("$derivedCloudPath", SCRIPT)
        self.assertIn("Convert-ToResticSnapshotPath", SCRIPT)
        self.assertNotRegex(SCRIPT, r"(?i)\b[A-Z]:\\Users\\[^\\\s\"']+")
        self.assertNotIn("LOCALAPPDATA", SCRIPT.upper())

    def test_rclone_and_evidence_are_fixed_to_protected_programdata(self):
        self.assertIn("ResticBackuperCloudVerification", SCRIPT)
        self.assertIn("assets-manifest.json", SCRIPT)
        self.assertIn("task_user_sid", SCRIPT)
        self.assertIn("-ExpectedUserSid $currentUserSid", SCRIPT)
        self.assertIn("Assert-ProtectedTree", SCRIPT)
        self.assertIn("Assert-ProtectedAcl", SCRIPT)
        self.assertIn("$rcloneExecutable = Join-Path", SCRIPT)
        self.assertNotIn("Get-Command rclone", SCRIPT)
        self.assertIn("$rcloneRunConfig", SCRIPT)
        self.assertIn(
            "[System.IO.File]::Copy($rcloneConfigMaster, $rcloneRunConfig, $false)",
            SCRIPT,
        )

    def test_native_capture_is_binary_safe_under_windows_powershell_51(self):
        self.assertIn("[System.Diagnostics.ProcessStartInfo]::new()", SCRIPT)
        self.assertIn("$process.StandardOutput.BaseStream.CopyToAsync($stdout)", SCRIPT)
        self.assertIn("$process.StandardError.BaseStream.CopyToAsync($stderr)", SCRIPT)
        self.assertIn("[System.Threading.Tasks.Task]::WaitAll", SCRIPT)
        self.assertIn(
            "[System.Text.UTF8Encoding]::new($false, $true)",
            SCRIPT,
        )
        self.assertNotIn("1> $StdoutPath", SCRIPT)
        self.assertNotIn("2> $StderrPath", SCRIPT)
        self.assertNotIn("Get-Content", SCRIPT)

    def test_latest_proof_replace_uses_a_real_backup_path(self):
        self.assertIn("'.bak'", SCRIPT)
        self.assertIn("[System.IO.File]::Delete($backup)", SCRIPT)
        self.assertNotIn(
            "[System.IO.File]::Replace($temporary, $fullPath, $null, $true)",
            SCRIPT,
        )

    def test_api_calls_are_read_only_and_restore_bypasses_drivefs(self):
        # The scope and the My Drive root travel in rclone's connection string,
        # which outranks the configuration file and every RCLONE_* variable.
        self.assertIn("',scope=drive.readonly,root_folder_id='", SCRIPT)
        self.assertNotIn("RCLONE_DRIVE_", SCRIPT)
        self.assertIn("'lsjson'", SCRIPT)
        self.assertIn("($readOnlyRemote + ':' + $CloudRepositoryPath)", SCRIPT)
        self.assertIn("'--hash-type', 'MD5'", SCRIPT)
        self.assertIn("'--hash-type', 'SHA-256'", SCRIPT)
        self.assertIn(
            "$remoteRepository = 'rclone:' + $readOnlyRemote + ':'", SCRIPT
        )
        self.assertIn("'--no-lock'", SCRIPT)
        self.assertIn("'--no-cache'", SCRIPT)
        self.assertIn("@('snapshots', '--json')", SCRIPT)
        self.assertIn("Get-ResticSnapshotListingFromJson", SCRIPT)
        self.assertIn("direct_cloud_latest_snapshot_verified = $true", SCRIPT)
        self.assertIn("'restore', ($SnapshotId + ':'", SCRIPT)
        self.assertIn("'--verify'", SCRIPT)

    def test_canary_restore_does_not_recreate_parent_folders(self):
        # Restoring the canary file with --include also recreated each parent
        # folder with the source's owner and ACL (C:\ProgramData is
        # SYSTEM-owned and lets Users write). Assert-ProtectedTree then failed
        # after the restore, and the folder left behind failed every later run
        # at its start. The canary's own folder is restored instead, as
        # backup.py does, so only the canary lands in the run folder.
        restores = [
            launch for launch in native_launches(SCRIPT) if "'restore'" in launch
        ]
        self.assertEqual(1, len(restores))
        self.assertIn(
            "'restore', ($SnapshotId + ':' + $canaryFolderSnapshotPath)",
            restores[0],
        )
        self.assertNotIn("'--include'", SCRIPT)
        self.assertNotIn("$relativeCanary", SCRIPT)
        # The folder is worked out before any cloud work, so -ValidateOnly and
        # the start of a run already refuse a canary at the root of a drive.
        derived_at = SCRIPT.index(
            "$canaryFolderSnapshotPath = Get-CanaryFolderSnapshotPath `\n"
            "    -CanaryPath $canaryReferenceFull"
        )
        self.assertLess(derived_at, SCRIPT.index("if ($ValidateOnly) {"))
        self.assertIn("$canaryLeaf = Split-Path -Leaf $canaryReferenceFull", SCRIPT)
        # Only the canary may come back, and it lands directly in the target.
        restore_at = SCRIPT.index(restores[0])
        after_restore = SCRIPT[restore_at:]
        self.assertIn(
            "$restoredEntries = @(Get-ChildItem -LiteralPath $restoreTarget -Force)",
            after_restore,
        )
        # Count first: under StrictMode, [0] on an empty array would throw.
        self.assertIn(
            "if ($restoredEntries.Count -ne 1 -or\n"
            "        -not [string]::Equals(\n"
            "            $restoredEntries[0].Name,\n"
            "            $canaryLeaf,\n"
            "            [System.StringComparison]::OrdinalIgnoreCase\n"
            "        )) {",
            after_restore,
        )
        self.assertIn(
            "$restoredCanary = Join-Path $restoreTarget $canaryLeaf", after_restore
        )
        # The proof's restore evidence and the post-restore tree check stay.
        self.assertIn("restored_canary = $restoredCanary", SCRIPT)
        self.assertIn("Assert-ProtectedTree", after_restore)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_canary_folder_selector_refuses_a_drive_root(self):
        # Runs the verifier's own functions in Windows PowerShell 5.1. A canary
        # at the root of a drive would make the snapshotID:subfolder selector
        # restore everything backed up from that drive, so it is refused.
        probe = "\n".join(
            [
                "Set-StrictMode -Version Latest",
                "$ErrorActionPreference = 'Stop'",
                powershell_function(SCRIPT, "Convert-ToResticSnapshotPath"),
                powershell_function(SCRIPT, "Get-CanaryFolderSnapshotPath"),
                "$result = [ordered]@{}",
                "foreach ($path in @(",
                "    'C:\\ProgramData\\ResticBackuper\\Canary\\backup-canary.txt',",
                "    'D:\\Data\\backup-canary.txt',",
                "    'C:\\backup-canary.txt',",
                "    '\\\\server\\share\\Canary\\backup-canary.txt'",
                ")) {",
                "    try { $result[$path] = Get-CanaryFolderSnapshotPath -CanaryPath $path }",
                "    catch { $result[$path] = 'refused: ' + $_.Exception.Message }",
                "}",
                "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                "",
            ]
        )
        completed = run_windows_powershell(probe)
        self.assertEqual(0, completed.returncode, completed.stderr)
        result = json.loads(completed.stdout.strip().splitlines()[-1])
        self.assertEqual(
            "/C/ProgramData/ResticBackuper/Canary",
            result["C:\\ProgramData\\ResticBackuper\\Canary\\backup-canary.txt"],
        )
        self.assertEqual("/D/Data", result["D:\\Data\\backup-canary.txt"])
        self.assertEqual(
            "refused: The canary must be inside a folder, not at the root of a drive.",
            result["C:\\backup-canary.txt"],
        )
        self.assertEqual(
            "refused: The canary must use a local drive-letter path.",
            result["\\\\server\\share\\Canary\\backup-canary.txt"],
        )

    def test_every_child_gets_an_allow_listed_environment(self):
        # The task runs elevated with an environment built from the user's
        # profile. No child may inherit it, and the verifier no longer sets
        # rclone or Restic settings in its own process.
        self.assertIn("$start.EnvironmentVariables.Clear()", SCRIPT)
        self.assertNotIn("SetEnvironmentVariable", SCRIPT)
        self.assertNotIn("$env:", SCRIPT.replace("$env:PSModulePath", ""))
        launches = native_launches(SCRIPT)
        self.assertEqual(8, len(launches))
        for launch in launches:
            self.assertRegex(launch, r"-Environment \$\w+")
        self.assertIn("-Environment $helperEnvironment", SCRIPT)
        for setting in (
            "RCLONE_CONFIG",
            "RCLONE_PASSWORD_COMMAND",
            "RCLONE_ASK_PASSWORD",
            "RCLONE_CACHE_DIR",
            "RESTIC_PASSWORD_COMMAND",
        ):
            self.assertIn(f"            {setting} = ", SCRIPT)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_password_commands_start_the_intended_programs(self):
        # Runs the verifier's own lines in Windows PowerShell 5.1. -f binds
        # tighter than +, so a format string split with + was formatted only
        # after the +: rclone was asked to start a program named {0}, could not
        # unlock its configuration, and every check failed in seconds. The
        # paths hold spaces, as a -CloudVerificationRoot may, so the quotes
        # around every path are exercised too.
        values = {
            "powershellExecutable": r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
            "rclonePasswordHelperPath": r"C:\ProgramData\Cloud Check\reveal-rclone-config-password.ps1",
            "rcloneCredentialPath": r"C:\ProgramData\Cloud Check\rclone-config-password.clixml",
            "pythonExecutable": r"C:\Program Files\ResticBackuper\Python\python.exe",
            "secretStore": r"C:\Program Files\ResticBackuper\secret_store.py",
            "secretFile": r"C:\ProgramData\ResticBackuper\repository-password.dpapi.json",
        }
        probe = "\n".join(
            ["Set-StrictMode -Version Latest", "$ErrorActionPreference = 'Stop'"]
            + [f"${name} = '{value}'" for name, value in values.items()]
            + [
                powershell_statement(SCRIPT, "    $rclonePasswordCommand = ("),
                powershell_statement(SCRIPT, "    $resticPasswordCommand = ("),
                "[Console]::Out.Write((@{ rclone = $rclonePasswordCommand; "
                "restic = $resticPasswordCommand } | ConvertTo-Json -Compress))",
                "",
            ]
        )
        completed = run_windows_powershell(probe)
        self.assertEqual(0, completed.returncode, completed.stderr)
        result = json.loads(completed.stdout.strip().splitlines()[-1])
        self.assertEqual(
            [
                values["powershellExecutable"],
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                values["rclonePasswordHelperPath"],
                "-CredentialPath",
                values["rcloneCredentialPath"],
            ],
            split_password_command(result["rclone"]),
        )
        # Restic splits RESTIC_PASSWORD_COMMAND with its own splitter, in
        # which a backslash outside quotes separates fields and a quote right
        # after a backslash does not close. The model above agrees with it
        # here only because every path is double-quoted and none ends in a
        # backslash (they are all files).
        for name in ("pythonExecutable", "secretStore", "secretFile"):
            self.assertIn(f'"{values[name]}"', result["restic"])
        self.assertEqual(
            [
                values["pythonExecutable"],
                "-I",
                "-S",
                "-B",
                values["secretStore"],
                "reveal",
                "--secret-file",
                values["secretFile"],
            ],
            split_password_command(result["restic"]),
        )

    def test_no_format_string_is_split_with_plus_before_f(self):
        # 'a {0} ' + 'b {1}' -f $x, $y formats only 'b {1}': -f binds tighter
        # than +. A format string split over two literals must be joined in
        # parentheses first, as the rclone password command now is. This
        # catches that shape (a literal, +, then a literal followed by -f);
        # generated folders such as node_modules are not the project's code.
        trap = re.compile(
            r"(?i)['\"]\s*\+\s*(?:'[^'\n]*'|\"[^\"\n]*\")\s*-f\b"
        )
        generated = {"node_modules", "dist", "bin", "obj", ".packages"}
        for folder in ("src", "installer", "build", "tests"):
            for path in sorted((PROJECT / folder).rglob("*.ps*1")):
                if generated.intersection(path.relative_to(PROJECT).parts):
                    continue
                with self.subTest(path=path.relative_to(PROJECT).as_posix()):
                    text = path.read_text(encoding="utf-8")
                    match = trap.search(text)
                    self.assertIsNone(
                        match,
                        f"line {text.count(chr(10), 0, match.start()) + 1}"
                        if match
                        else "",
                    )

    def test_schema_two_proof_binds_assets_backup_inventory_and_restore(self):
        self.assertIn("schema_version = 2", SCRIPT)
        self.assertIn(
            "proof_kind = 'direct_my_drive_cloud_repository_verification'",
            SCRIPT,
        )
        for field in (
            "verification_phase",
            "plan_id",
            "config_generation",
            "repository_storage_mode",
            "local_repository",
            "repository_id",
            "local_repository_id",
            "cloud_repository_id",
            "snapshot_id",
            "snapshot_time",
            "direct_cloud_snapshot_count",
            "direct_cloud_latest_snapshot_verified",
            "inventory_fingerprint_sha256",
            "cloud_inventory_document_sha256",
            "direct_cloud_restore_verified",
            "backup_config_sha256",
            "cloud_verification_assets_manifest_sha256",
            "native_capture_mode",
        ):
            self.assertIn(f"{field} =", SCRIPT)

    def test_packaged_password_helper_is_path_bound_and_zeroes_native_memory(self):
        self.assertIn("'rclone-config-password.clixml'", PASSWORD_HELPER)
        self.assertIn("Test-SamePath", PASSWORD_HELPER)
        self.assertIn("Import-Clixml -LiteralPath", PASSWORD_HELPER)
        self.assertIn("SecureStringToBSTR", PASSWORD_HELPER)
        self.assertIn("ZeroFreeBSTR", PASSWORD_HELPER)
        # The password leaves as UTF-8 bytes, which are cleared afterwards (see the UTF-8 test below).
        self.assertIn("[Console]::OpenStandardOutput()", PASSWORD_HELPER)
        self.assertIn("[Array]::Clear($passwordBytes, 0, $passwordBytes.Length)", PASSWORD_HELPER)
        self.assertNotIn("[Console]::Out.WriteLine($plainText)", PASSWORD_HELPER)
        self.assertNotIn("Write-Verbose", PASSWORD_HELPER)
        for relative in (
            "build/Build-Release.ps1",
            "installer/Install-ResticBackuper.ps1",
            "tests/Test-ReleaseArtifact.ps1",
        ):
            text = (PROJECT / relative).read_text(encoding="utf-8")
            self.assertIn("'reveal-rclone-config-password.ps1'", text)

    def test_the_proof_does_not_claim_the_token_scope(self):
        # The scope travels with every call, but a sign-in made with a broader scope keeps it, and the check does not
        # look that up. The proof says what was asked for, not that it was enforced.
        self.assertNotIn("rclone_scope = 'drive.readonly'", SCRIPT)
        self.assertIn("rclone_scope_requested = 'drive.readonly'", SCRIPT)
        self.assertIn("rclone_token_scope_verified = $false", SCRIPT)
        self.assertIn("rclone_version = $rcloneVersion.ToString()", SCRIPT)


class MyDriveCloudVerifierFailureRecordTests(unittest.TestCase):
    """A check that stops leaves a record of where and why."""

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_linked_evidence_folder_is_refused_before_any_record(self):
        # The record is never written through a link the task's user could make: such a folder stops the check before
        # the record is armed.
        with tempfile.TemporaryDirectory(prefix="rewindle-evidence-link-") as temp:
            root = Path(temp) / "CloudVerification"
            elsewhere = Path(temp) / "elsewhere"
            root.mkdir()
            elsewhere.mkdir()
            check = (
                "Assert-RecordableEvidenceFolder -Root $root -EvidenceRoot $evidence -CurrentUserSid 'S-1-5-18'"
            )
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    ACL_STAND_IN,
                    powershell_functions(SCRIPT, "Assert-NormalDirectory", "Assert-RecordableEvidenceFolder"),
                    "$root = " + ps_literal(str(root)),
                    "$evidence = Join-Path $root 'evidence'",
                    "$result = [ordered]@{}",
                    "[void][IO.Directory]::CreateDirectory($evidence)",
                    "try { " + check + "; $result.normal = 'accepted' } catch { $result.normal = $_.Exception.Message }",
                    "[IO.Directory]::Delete($evidence)",
                    "$null = New-Item -ItemType Junction -Path $evidence -Target " + ps_literal(str(elsewhere)),
                    "try { " + check + "; $result.linked = 'accepted' } catch { $result.linked = $_.Exception.Message }",
                    "[IO.Directory]::Delete($evidence)",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
            self.assertTrue(elsewhere.is_dir())
        self.assertEqual("accepted", result["normal"])
        self.assertIn("reparse point", result["linked"])

    def test_the_record_is_armed_before_the_configuration_is_read(self):
        # Every failure counts, also one in the configuration or with Google Drive for desktop not running, so the record
        # is armed first, as soon as its own folder is found safe, and never by -ValidateOnly.
        armed = SCRIPT.index("    $script:failureRecordTarget = @{")
        guard = SCRIPT.rindex("if (-not $ValidateOnly) {", 0, armed)
        safe = SCRIPT.index("    Assert-RecordableEvidenceFolder `", guard)
        self.assertLess(guard, safe)
        self.assertLess(safe, armed)
        self.assertLess(armed, SCRIPT.index("$config = Read-Utf8Json -Path $configPathFull"))
        self.assertIn("$failureRecordPath = Join-Path $evidenceRoot 'latest-failure.json'", SCRIPT)
        # Only the root and the evidence folder are checked there, each with the protected-ACL check.
        check = powershell_function(SCRIPT, "Assert-RecordableEvidenceFolder")
        self.assertIn("-RequireProtectedInheritance", check)
        self.assertEqual(2, check.count("Assert-ProtectedAcl `"))
        self.assertEqual(2, check.count("Assert-NormalDirectory -Path"))

    def test_a_check_that_passes_removes_the_record_and_disarms_it(self):
        latest = SCRIPT.index("    Write-AtomicJson -Path $latestProofPath -Value $latestProof")
        removed = SCRIPT.index("    try { Remove-CheckFailureRecord -Path $failureRecordPath } catch { }")
        disarmed = SCRIPT.index("    $script:failureRecordTarget = $null", removed)
        self.assertLess(latest, removed)
        self.assertLess(removed, disarmed)
        self.assertLess(disarmed, SCRIPT.index("    Write-Output $latestProofPath"))

    def test_every_native_step_is_named_before_it_runs(self):
        expected = {
            "@('version')": "checking_rclone",
            "'cat',\n            'config'": "opening_local_backup",
            "@('cat', 'config')": "connecting_to_google_drive",
            "'lsjson'": "listing_google_drive",
            "$inventoryHelper,": "comparing_files",
            "@('snapshots', '--json')": "listing_cloud_backups",
            "'restore', ($SnapshotId": "test_restore",
        }
        for marker, step in expected.items():
            with self.subTest(step=step):
                at = SCRIPT.index(marker, SCRIPT.index("$runLock = $null"))
                named = SCRIPT.rindex("Set-CheckStep '", 0, at)
                self.assertEqual(step, SCRIPT[named + len("Set-CheckStep '") :].split("'", 1)[0])
        labels = powershell_function(SCRIPT, "Get-CheckStepLabel")
        steps = set(re.findall(r"Set-CheckStep '([a-z_]+)'", SCRIPT))
        for step in steps:
            self.assertIn(f"'{step}' {{ return", labels)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_record_says_when_where_and_why_in_plain_words(self):
        with tempfile.TemporaryDirectory(prefix="rewindle-failure-record-") as temp:
            record = Path(temp) / "latest-failure.json"
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    ACL_STAND_IN,
                    powershell_functions(SCRIPT, *FAILURE_FUNCTIONS),
                    "$target = @{ Path = " + ps_literal(str(record)) + "; CurrentUserSid = 'S-1-5-18'; "
                    "RunId = '20261110T030001123Z-1a2b3c4d'; StartedUtc = [DateTime]::UtcNow.AddMinutes(-2); "
                    "PlanId = '10000000-0000-4000-8000-000000000042'; ConfigGeneration = [long]3 }",
                    "$result = [ordered]@{}",
                    "Write-CheckFailureRecord -Target $target -Step 'listing_google_drive' -Detail $null "
                    "-Message ('rclone failed' + [char]10 + 'second line')",
                    "$result.generic = [IO.File]::ReadAllText(" + ps_literal(str(record)) + ")",
                    "$detail = Get-InventoryFailureDetail -Category 'cloud_files_missing' -Count 3",
                    "Write-CheckFailureRecord -Target $target -Step 'comparing_files' -Detail $detail -Message 'x'",
                    "$result.specific = [IO.File]::ReadAllText(" + ps_literal(str(record)) + ")",
                    "$result.files = @(Get-ChildItem -LiteralPath " + ps_literal(temp) + ").Count",
                    "$result.one = @(foreach ($category in @('cloud_files_missing', 'cloud_size_mismatch', "
                    "'cloud_content_mismatch')) { (Get-InventoryFailureDetail -Category $category -Count 1).reason })",
                    "$result.many = (Get-InventoryFailureDetail -Category 'cloud_content_mismatch' -Count 1234).reason",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
        generic = json.loads(result["generic"])
        self.assertEqual(1, generic["schema_version"])
        self.assertEqual("direct_my_drive_cloud_check_failure", generic["record_kind"])
        self.assertEqual("failed", generic["state"])
        self.assertEqual("20261110T030001123Z-1a2b3c4d", generic["run_id"])
        self.assertRegex(generic["started_utc"], r"Z$")
        self.assertRegex(generic["failed_utc"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z$")
        self.assertEqual("listing_google_drive", generic["step"])
        self.assertEqual("listing your backup's files in Google Drive", generic["step_label"])
        self.assertEqual("google_drive_list_failed", generic["reason_code"])
        self.assertEqual("Rewindle couldn't list your backup's files in Google Drive.", generic["reason"])
        self.assertIn("Rewindle checks again tonight.", generic["next_step"])
        self.assertEqual("rclone failed second line", generic["technical_detail"])
        self.assertEqual("10000000-0000-4000-8000-000000000042", generic["plan_id"])
        self.assertEqual(3, generic["config_generation"])
        specific = json.loads(result["specific"])
        self.assertEqual("comparing_files", specific["step"])
        self.assertEqual("cloud_files_missing", specific["reason_code"])
        self.assertEqual("3 files of your backup aren't in Google Drive yet.", specific["reason"])
        self.assertIn("until it has uploaded everything", specific["next_step"])
        # Replaced in place: no temporary or backup file is left beside it.
        self.assertEqual(1, result["files"])
        # One file reads as one file.
        self.assertEqual(
            [
                "1 file of your backup isn't in Google Drive yet.",
                "1 file in Google Drive isn't the same size as on this PC. Google Drive for desktop may still be "
                "uploading it.",
                "1 file in Google Drive doesn't match the one on this PC.",
            ],
            result["one"],
        )
        self.assertEqual("1,234 files in Google Drive don't match the ones on this PC.", result["many"])

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_stopped_check_records_why_and_still_fails(self):
        # The script's own trap: any error once the record is armed (here one raised inside a function, inside a
        # try/finally like the run's) writes the record with the step and reason, and the task still fails.
        trap = powershell_block(SCRIPT, "trap {")
        for armed in (True, False):
            with self.subTest(armed=armed), tempfile.TemporaryDirectory(prefix="rewindle-failure-trap-") as temp:
                record = Path(temp) / "latest-failure.json"
                finally_marker = Path(temp) / "finally.txt"
                arm = (
                    "$script:failureRecordTarget = @{ Path = " + ps_literal(str(record)) + "; "
                    "CurrentUserSid = 'S-1-5-18'; RunId = '20261110T030001123Z-1a2b3c4d'; "
                    "StartedUtc = [DateTime]::UtcNow; PlanId = $null; ConfigGeneration = $null }"
                    if armed
                    else ""
                )
                probe = "\n".join(
                    [
                        PROBE_HEADER,
                        ACL_STAND_IN,
                        powershell_functions(SCRIPT, *FAILURE_FUNCTIONS),
                        trap,
                        arm,
                        "Set-CheckStep 'waiting_for_backup'",
                        "function Stop-Inside { Stop-Check -Message 'held too long' -ReasonCode 'backup_still_running' "
                        "-Reason 'A backup was still running.' -NextStep 'Open Activity.' }",
                        "try { Stop-Inside } finally { [IO.File]::WriteAllText("
                        + ps_literal(str(finally_marker))
                        + ", 'ran') }",
                        "[Console]::Out.Write('not reached')",
                        "",
                    ]
                )
                completed = run_windows_powershell(probe)
                self.assertNotEqual(0, completed.returncode)
                self.assertNotIn("not reached", completed.stdout)
                self.assertIn("held too long", completed.stderr)
                self.assertTrue(finally_marker.exists())
                if not armed:
                    self.assertFalse(record.exists())
                    continue
                written = json.loads(record.read_text(encoding="utf-8"))
                self.assertEqual("waiting_for_backup", written["step"])
                self.assertEqual("waiting for a backup to finish", written["step_label"])
                self.assertEqual("backup_still_running", written["reason_code"])
                self.assertEqual("A backup was still running.", written["reason"])
                self.assertEqual("Open Activity.", written["next_step"])
                self.assertEqual("held too long", written["technical_detail"])
                self.assertIsNone(written["plan_id"])

    def test_every_step_has_plain_words(self):
        description = powershell_function(SCRIPT, "Get-CheckFailureDescription")
        labels = powershell_function(SCRIPT, "Get-CheckStepLabel")
        for step in re.findall(r"'([a-z_]+)' \{ return", labels):
            with self.subTest(step=step):
                self.assertIn(f"        '{step}' {{\n", description)


class MyDriveCloudVerifierWaitTests(unittest.TestCase):
    """A check that Windows starts late waits for Google Drive, the network and the backup instead of failing."""

    def test_waits_come_before_the_work_they_protect(self):
        # Google Drive for desktop's folder is waited for before the setup checks look at it (not by -ValidateOnly).
        wait = SCRIPT.index("    Wait-ForMyDriveRepository `")
        self.assertLess(SCRIPT.rindex("if (-not $ValidateOnly) {", 0, wait), wait)
        self.assertLess(wait, SCRIPT.index("Assert-NormalDirectory -Path $myDriveRootFull | Out-Null"))
        # The network, then the backup's head start, then the run lock, all before the first native step that reads.
        body = SCRIPT[SCRIPT.index("$runLock = $null") :]
        order = [
            "    Wait-ForNetwork -DeadlineUtc",
            "    [void](Wait-ForBackupHeadStart `",
            "    $runLock = Enter-ProtectedRunLockWhenFree `",
            "        -Operation 'Local Restic repository authentication'",
        ]
        positions = [body.index(item) for item in order]
        self.assertEqual(sorted(positions), positions)
        self.assertNotIn("Enter-ProtectedRunLock -Path $runLockPath", SCRIPT)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_the_run_lock_is_waited_for_and_then_taken(self):
        with tempfile.TemporaryDirectory(prefix="rewindle-run-lock-") as temp:
            lock = Path(temp) / "run.lock"
            lock.write_bytes(b"\0")
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(
                        SCRIPT,
                        "Assert-NormalFile",
                        "Get-RemainingMilliseconds",
                        "Format-PlainDuration",
                        "New-CheckFailureDetail",
                        "Stop-Check",
                        "Enter-ProtectedRunLock",
                        "Enter-ProtectedRunLockWhenFree",
                    ),
                    "$path = " + ps_literal(str(lock)),
                    "$result = [ordered]@{}",
                    # Another holder (a backup) keeps byte zero locked through its own handle.
                    "$holder = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite'); $holder.Lock(0, 1)",
                    "$watch = [Diagnostics.Stopwatch]::StartNew()",
                    "$result.held = (Enter-ProtectedRunLock -Path $path) -eq $null",
                    "try { $null = Enter-ProtectedRunLockWhenFree -Path $path "
                    "-DeadlineUtc ([DateTime]::UtcNow.AddSeconds(1.5)) -PollSeconds 0.2; $result.gave_up = $false }",
                    "catch { $result.gave_up = $true; $result.reason_code = $script:checkFailureDetail.reason_code; "
                    "$result.reason = $script:checkFailureDetail.reason }",
                    "$result.waited = $watch.Elapsed.TotalSeconds",
                    "$holder.Unlock(0, 1); $holder.Dispose()",
                    "$taken = Enter-ProtectedRunLockWhenFree -Path $path -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(5)) "
                    "-PollSeconds 0.2",
                    "$result.taken = $taken -is [IO.FileStream]",
                    "$taken.Unlock(0, 1); $taken.Dispose()",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
        self.assertTrue(result["held"])
        self.assertTrue(result["gave_up"])
        self.assertEqual("backup_still_running", result["reason_code"])
        self.assertEqual("A backup was still running after 1 minute, so the check couldn't start.", result["reason"])
        self.assertGreaterEqual(result["waited"], 1.3)
        self.assertLess(result["waited"], 10)
        self.assertTrue(result["taken"])
        # Only a lock violation (Windows error 33) means a backup holds the lock; any other error is a real one, and its
        # own words don't blame a backup.
        lock = powershell_function(SCRIPT, "Enter-ProtectedRunLock")
        self.assertIn("if (($_.Exception.HResult -band 0xFFFF) -eq 33) {\n            return $null", lock)
        self.assertIn("        throw\n", lock[lock.index("-eq 33") :])
        descriptions = powershell_function(SCRIPT, "Get-CheckFailureDescription")
        waiting = descriptions[descriptions.index("        'waiting_for_backup' {") :]
        waiting = waiting[: waiting.index("\n        }\n")]
        self.assertIn("'run_lock_unusable'", waiting)
        self.assertNotIn("Open Activity", waiting)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_due_or_missed_backup_gets_a_head_start(self):
        # Whatever the time: Windows may replay a missed 03:00 run a minute later or hours later.
        self.assertNotIn("Test-CheckStartedLate", SCRIPT)
        with tempfile.TemporaryDirectory(prefix="rewindle-head-start-") as temp:
            status = Path(temp) / "status.json"
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(
                        SCRIPT,
                        "Read-Utf8Json",
                        "Get-RemainingMilliseconds",
                        "Wait-Until",
                        "Get-LatestBackupStartUtc",
                        "Wait-ForBackupHeadStart",
                    ),
                    "$status = " + ps_literal(str(status)),
                    "$result = [ordered]@{}",
                    "$started = [DateTime]::new(2026, 11, 10, 3, 1, 0, [DateTimeKind]::Utc)",
                    "function Write-Status([DateTime]$Utc) { [IO.File]::WriteAllText($status, "
                    "('{\"state\":\"running\",\"started_utc\":\"' + $Utc.ToString('yyyy-MM-ddTHH:mm:ssZ') + '\"}')) }",
                    "$watch = [Diagnostics.Stopwatch]::StartNew()",
                    "$result.unknown_backup_waits = Wait-ForBackupHeadStart -StatusPath $status "
                    "-CheckStartedUtc $started -HeadStart ([TimeSpan]::FromSeconds(1)) -PollSeconds 0.2",
                    "$result.unknown_seconds = $watch.Elapsed.TotalSeconds",
                    "Write-Status $started.AddHours(-2)",
                    "$watch.Restart()",
                    "$result.recent_backup_waits = Wait-ForBackupHeadStart -StatusPath $status "
                    "-CheckStartedUtc $started -HeadStart ([TimeSpan]::FromSeconds(30)) -PollSeconds 0.2",
                    "$result.recent_seconds = $watch.Elapsed.TotalSeconds",
                    "Write-Status $started.AddHours(-30)",
                    "$watch.Restart()",
                    "$result.old_backup_waits = Wait-ForBackupHeadStart -StatusPath $status "
                    "-CheckStartedUtc $started -HeadStart ([TimeSpan]::FromSeconds(1)) -PollSeconds 0.2",
                    "$result.old_seconds = $watch.Elapsed.TotalSeconds",
                    "$result.parsed = (Get-LatestBackupStartUtc -StatusPath $status).ToString('o')",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
        self.assertTrue(result["unknown_backup_waits"])
        self.assertGreaterEqual(result["unknown_seconds"], 0.9)
        self.assertFalse(result["recent_backup_waits"])
        self.assertLess(result["recent_seconds"], 5)
        self.assertTrue(result["old_backup_waits"])
        self.assertGreaterEqual(result["old_seconds"], 0.9)
        self.assertRegex(result["parsed"], r"Z$")

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_google_drive_that_never_appears_is_named_as_the_reason(self):
        with tempfile.TemporaryDirectory(prefix="rewindle-drive-wait-") as temp:
            root = Path(temp) / "My Drive"
            repository = root / "Rewindle" / "Backups"
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(
                        SCRIPT,
                        "Get-RemainingMilliseconds",
                        "Wait-Until",
                        "New-CheckFailureDetail",
                        "Stop-Check",
                        "Wait-ForMyDriveRepository",
                    ),
                    "$result = [ordered]@{}",
                    "foreach ($case in @('no_root', 'no_repository', 'ready')) {",
                    "    if ($case -eq 'no_repository') { [void][IO.Directory]::CreateDirectory("
                    + ps_literal(str(root))
                    + ") }",
                    "    if ($case -eq 'ready') { [void][IO.Directory]::CreateDirectory("
                    + ps_literal(str(repository))
                    + "); [IO.File]::WriteAllText("
                    + ps_literal(str(repository / "config"))
                    + ", 'x') }",
                    "    $script:checkFailureDetail = $null",
                    "    try { Wait-ForMyDriveRepository -MyDriveRoot "
                    + ps_literal(str(root))
                    + " -Repository "
                    + ps_literal(str(repository))
                    + " -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(0.5)) -PollSeconds 0.1; $result[$case] = 'ready' }",
                    "    catch { $result[$case] = $script:checkFailureDetail.reason_code }",
                    "}",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
        self.assertEqual("google_drive_folder_missing", result["no_root"])
        self.assertEqual("backup_folder_missing", result["no_repository"])
        self.assertEqual("ready", result["ready"])


class MyDriveCloudVerifierDeadlineTests(unittest.TestCase):
    """Every native step has a deadline sized from the repository, and one past it is stopped by exact process ID."""

    def test_every_native_step_has_a_sized_deadline(self):
        launches = native_launches(SCRIPT)
        self.assertEqual(8, len(launches))
        for launch in launches:
            with self.subTest(launch=launch.splitlines()[0]):
                if "-Executable $Executable" in launch:
                    # Invoke-RequiredNative hands its caller's deadline on.
                    self.assertIn("-TimeoutSeconds $TimeoutSeconds", launch)
                else:
                    self.assertIn("-TimeoutSeconds (Get-NativeTimeoutSeconds", launch)
        # The steps that read the repository are sized from its bytes, the listing from its file count.
        helper = next(launch for launch in launches if "$inventoryHelper," in launch)
        self.assertIn("-Bytes $localRepositorySize.bytes", helper)
        listing = next(launch for launch in launches if "'lsjson'" in launch)
        self.assertIn("-Files $localRepositorySize.files", listing)
        restore = next(launch for launch in launches if "'restore'" in launch)
        self.assertIn("-Bytes $localRepositorySize.bytes", restore)
        native = powershell_function(SCRIPT, "Invoke-NativeToFiles")
        self.assertIn("$process.WaitForExit(", native)
        self.assertIn("Stop-NativeProcessTree -Process $process", native)
        self.assertNotIn("Stop-Process", SCRIPT)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_deadlines_follow_the_repository_size_and_the_check_budget(self):
        with tempfile.TemporaryDirectory(prefix="rewindle-measure-") as temp:
            repository = Path(temp) / "repository"
            (repository / "data" / "00").mkdir(parents=True)
            (repository / "config").write_bytes(b"c" * 10)
            (repository / "data" / "00" / "pack").write_bytes(b"p" * 1000)
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(
                        SCRIPT,
                        "Get-CheckStepLabel",
                        "New-CheckFailureDetail",
                        "Stop-Check",
                        "Get-NativeTimeoutSeconds",
                        "Measure-LocalRepository",
                    ),
                    "$result = [ordered]@{}",
                    "$far = [DateTime]::UtcNow.AddHours(11)",
                    "$result.sized = Get-NativeTimeoutSeconds -BaseSeconds 1800 -Bytes 60GB -BytesPerSecond 2MB "
                    "-CheckDeadlineUtc $far",
                    "$result.listing = Get-NativeTimeoutSeconds -BaseSeconds 1800 -Files 3600 -SecondsPerFile 1 "
                    "-CheckDeadlineUtc $far",
                    "$result.capped = Get-NativeTimeoutSeconds -BaseSeconds 1800 -Bytes 60GB -BytesPerSecond 2MB "
                    "-CheckDeadlineUtc ([DateTime]::UtcNow.AddSeconds(100))",
                    "$script:checkStep = 'test_restore'",
                    "try { $null = Get-NativeTimeoutSeconds -BaseSeconds 60 -CheckDeadlineUtc ([DateTime]::UtcNow); "
                    "$result.out_of_time = 'no' }",
                    "catch { $result.out_of_time = $script:checkFailureDetail.reason }",
                    "$size = Measure-LocalRepository -Path " + ps_literal(str(repository)),
                    "$result.files = $size.files; $result.bytes = $size.bytes",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
        self.assertEqual(1800 + 30720, result["sized"])
        self.assertEqual(1800 + 3600, result["listing"])
        self.assertLessEqual(result["capped"], 100)
        self.assertGreater(result["capped"], 90)
        self.assertEqual(
            "The check ran out of time before restoring a test file from Google Drive.", result["out_of_time"]
        )
        self.assertEqual(2, result["files"])
        self.assertEqual(1010, result["bytes"])

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_step_past_its_deadline_is_stopped_with_what_it_started(self):
        # cmd.exe starts ping.exe, as Restic starts rclone. Both must be gone once the deadline passes, by exact ID.
        marker = str(4000 + os.getpid() % 900)
        with tempfile.TemporaryDirectory(prefix="rewindle-deadline-") as temp:
            system = os.environ.get("SystemRoot", r"C:\Windows")
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(
                        SCRIPT,
                        "ConvertTo-NativeArgument",
                        "Get-RemainingMilliseconds",
                        "Get-NativeProcessTree",
                        "Stop-ExactProcess",
                        "Stop-NativeProcessTree",
                        "Format-PlainDuration",
                        "Get-CheckStepLabel",
                        "New-CheckFailureDetail",
                        "Stop-Check",
                        "Invoke-NativeToFiles",
                    ),
                    "$script:checkStep = 'listing_google_drive'",
                    "$system = " + ps_literal(os.path.join(system, "System32")),
                    "$environment = @{ SystemRoot = " + ps_literal(system) + "; PATH = $system }",
                    "$result = [ordered]@{}",
                    "$watch = [Diagnostics.Stopwatch]::StartNew()",
                    "try {",
                    "    $null = Invoke-NativeToFiles -Executable (Join-Path $system 'cmd.exe') "
                    "-Arguments @('/d', '/c', 'ping.exe -n 60 -w " + marker + " 127.0.0.1') "
                    "-StdoutPath " + ps_literal(str(Path(temp) / "out.log")) + " "
                    "-StderrPath " + ps_literal(str(Path(temp) / "err.log")) + " "
                    "-Environment $environment -TimeoutSeconds 3",
                    "    $result.outcome = 'finished'",
                    "}",
                    "catch {",
                    "    $result.outcome = 'stopped'",
                    "    $result.reason_code = $script:checkFailureDetail.reason_code",
                    "    $result.reason = $script:checkFailureDetail.reason",
                    "}",
                    "$result.seconds = $watch.Elapsed.TotalSeconds",
                    "$checkDeadlineUtc = [DateTime]::UtcNow.AddSeconds(2)",
                    "try {",
                    "    $null = Invoke-NativeToFiles -Executable (Join-Path $system 'cmd.exe') "
                    "-Arguments @('/d', '/c', 'ping.exe -n 60 -w " + marker + " 127.0.0.1') "
                    "-StdoutPath " + ps_literal(str(Path(temp) / "out2.log")) + " "
                    "-StderrPath " + ps_literal(str(Path(temp) / "err2.log")) + " "
                    "-Environment $environment -TimeoutSeconds 2",
                    "    $result.capped = 'finished'",
                    "}",
                    "catch {",
                    "    $result.capped = $script:checkFailureDetail.reason_code",
                    "    $result.capped_reason = $script:checkFailureDetail.reason",
                    "}",
                    "[Threading.Thread]::Sleep(1000)",
                    "$left = @(CimCmdlets\\Get-CimInstance -ClassName Win32_Process | Where-Object { "
                    "[string]$_.CommandLine -like '*-w " + marker + " 127.0.0.1*' })",
                    "$result.left = $left.Count",
                    "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                    "",
                ]
            )
            result = run_probe_json(self, probe)
        self.assertEqual("stopped", result["outcome"])
        self.assertEqual("timed_out", result["reason_code"])
        self.assertEqual(
            "The check stopped because listing your backup's files in Google Drive took longer than 1 minute.",
            result["reason"],
        )
        self.assertLess(result["seconds"], 30)
        self.assertEqual("out_of_time", result["capped"])
        self.assertEqual(
            "The check ran out of time while listing your backup's files in Google Drive.", result["capped_reason"]
        )
        self.assertEqual(0, result["left"])

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_process_id_that_names_another_process_is_left_alone(self):
        # Windows reuses process IDs: a process with the same ID but another start time is not the one to stop.
        system = os.environ.get("SystemRoot", r"C:\Windows")
        probe = "\n".join(
            [
                PROBE_HEADER,
                powershell_function(SCRIPT, "Stop-ExactProcess"),
                "$info = [Diagnostics.ProcessStartInfo]::new("
                + ps_literal(os.path.join(system, "System32", "ping.exe"))
                + ", '-n 30 127.0.0.1')",
                "$info.UseShellExecute = $false; $info.CreateNoWindow = $true",
                "$process = [Diagnostics.Process]::Start($info)",
                "$result = [ordered]@{}",
                "try {",
                "    Stop-ExactProcess -Id $process.Id -Started $process.StartTime.AddMinutes(-5)",
                "    $result.other_start_spared = -not $process.WaitForExit(1000)",
                "    Stop-ExactProcess -Id $process.Id -Started $process.StartTime",
                "    $result.exact_stopped = $process.WaitForExit(10000)",
                "}",
                "finally { if (-not $process.HasExited) { $process.Kill() }; $process.Dispose() }",
                "[Console]::Out.Write(($result | ConvertTo-Json -Compress))",
                "",
            ]
        )
        result = run_probe_json(self, probe)
        self.assertTrue(result["other_start_spared"])
        self.assertTrue(result["exact_stopped"])


class MyDriveCloudVerifierRcloneVersionTests(unittest.TestCase):
    def test_the_version_is_checked_before_anything_long(self):
        self.assertIn("$minimumRcloneVersion = [Version]'1.65.0'", SCRIPT)
        body = SCRIPT[SCRIPT.index("$runLock = $null") :]
        version = body.index("Set-CheckStep 'checking_rclone'")
        self.assertLess(version, body.index("Wait-ForNetwork"))
        self.assertLess(version, body.index("'lsjson'"))
        self.assertIn("if ($rcloneVersion -lt $minimumRcloneVersion) {", body)
        self.assertIn("-ReasonCode 'rclone_too_old'", body)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_rclone_version_text_is_read_strictly(self):
        samples = {
            "rclone v1.74.4\r\n- os/version: Microsoft Windows 11\r\n": "1.74.4",
            "rclone v1.65.0\n": "1.65.0",
            "rclone v1.64.2\n": "1.64.2",
            "rclone v1.66.0-beta.7731.6a8ddbcc4\n": "1.66.0",
            "": "refused",
            "rclone 1.70.0\n": "refused",
            "v1.70.0 rclone\n": "refused",
        }
        lines = [PROBE_HEADER, powershell_function(SCRIPT, "ConvertFrom-RcloneVersionText"), "$result = @()"]
        for text in samples:
            literal = ps_literal(text).replace("\r", "' + [char]13 + '").replace("\n", "' + [char]10 + '")
            lines.append(
                "try { $v = ConvertFrom-RcloneVersionText -Text (" + literal + "); "
                "$result += $v.ToString() + '|' + ($v -lt [Version]'1.65.0') } catch { $result += 'refused' }"
            )
        lines += ["[Console]::Out.Write((ConvertTo-Json -InputObject @($result) -Compress))", ""]
        completed = run_windows_powershell("\n".join(lines))
        self.assertEqual(0, completed.returncode, completed.stderr)
        result = json.loads(completed.stdout.strip().splitlines()[-1])
        expected = [
            value if value == "refused" else f"{value}|{value == '1.64.2'}" for value in samples.values()
        ]
        self.assertEqual([item.replace("True", "true").replace("False", "false") for item in expected],
                         [item.replace("True", "true").replace("False", "false") for item in result])


class MyDriveCloudVerifierRunFolderTests(unittest.TestCase):
    def test_the_configuration_copy_is_removed_when_the_run_ends(self):
        cleanup = SCRIPT[SCRIPT.rindex("\nfinally {\n") :]
        self.assertIn("try { Remove-RunFile -Path $rcloneRunConfig } catch { }", cleanup)

    def test_old_runs_are_removed_after_the_tree_check_and_before_the_new_run(self):
        prune = SCRIPT.index("    Remove-OldCheckRuns `\n        -RunsRoot $runsRoot")
        # Housekeeping never stops a check.
        self.assertEqual("try {\n", SCRIPT[SCRIPT.rindex("\n", 0, prune - 1) + 1 : prune])
        self.assertIn("catch { }", SCRIPT[prune : prune + 200])
        self.assertLess(SCRIPT.index("Assert-ProtectedTree `\n    -Root $cloudVerificationRootFull"), prune)
        self.assertLess(prune, SCRIPT.index("$runDirectory = Join-Path $runsRoot $runId"))
        self.assertIn("$previousRunsKept = 4", SCRIPT)

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_only_the_newest_runs_and_the_latest_proof_are_kept(self):
        with tempfile.TemporaryDirectory(prefix="rewindle-runs-", ignore_cleanup_errors=True) as temp:
            runs = Path(temp) / "runs"
            names = [f"202611{day:02d}T030000000Z-0000000{day % 10}" for day in range(1, 9)]
            for name in names:
                (runs / name / "restore").mkdir(parents=True)
                (runs / name / "verification-proof.json").write_text("{}", encoding="ascii")
                (runs / name / "rclone-readonly.conf").write_text("secret", encoding="ascii")
            (runs / "notes").mkdir()
            (runs / "stray.txt").write_text("x", encoding="ascii")
            # A read-only restored file in an old run, and a read-only configuration copy in a kept one.
            read_only = runs / names[1] / "restore" / "canary.txt"
            read_only.write_text("canary", encoding="ascii")
            os.chmod(read_only, stat.S_IREAD)
            os.chmod(runs / names[5] / "rclone-readonly.conf", stat.S_IREAD)
            # A file still in use in another old run.
            in_use = runs / names[2] / "rclone.stderr.log"
            in_use.write_text("log", encoding="ascii")
            proof = str(runs / names[0] / "verification-proof.json")
            probe = "\n".join(
                [
                    PROBE_HEADER,
                    powershell_functions(
                        SCRIPT, "Get-RunIdFromProofPath", "Remove-RunFile", "Remove-RunFolder", "Remove-OldCheckRuns"
                    ),
                    "$keep = Get-RunIdFromProofPath -ProofPath " + ps_literal(proof),
                    "$inUse = [IO.File]::Open(" + ps_literal(str(in_use)) + ", 'Open', 'Read', 'None')",
                    "try { Remove-OldCheckRuns -RunsRoot " + ps_literal(str(runs)) + " -Keep 4 -KeepRunId $keep }",
                    "finally { $inUse.Dispose() }",
                    "[Console]::Out.Write((ConvertTo-Json -InputObject @($keep) -Compress))",
                    "",
                ]
            )
            completed = run_windows_powershell(probe)
            self.assertEqual(0, completed.returncode, completed.stderr)
            self.assertEqual([names[0]], json.loads(completed.stdout.strip().splitlines()[-1]))
            left = sorted(path.name for path in runs.iterdir())
            # The run with a file in use stays until a later run; nothing stopped.
            self.assertEqual(sorted([names[0], names[2], *names[-4:], "notes", "stray.txt"]), left)
            self.assertTrue(in_use.exists())
            for name in [names[0], *names[-4:]]:
                self.assertTrue((runs / name / "verification-proof.json").exists())
                self.assertFalse((runs / name / "rclone-readonly.conf").exists())


class RclonePasswordHelperEncodingTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
    def test_a_password_outside_ascii_reaches_rclone_as_utf8(self):
        # rclone reads the password command's output as UTF-8. Through [Console]::Out it came in the console's code
        # page (437 or 850 on most PCs), so a letter outside ASCII changed and the configuration could not be opened.
        password = "p\u00e4ss-\u00c5\u20ac"
        system = os.environ.get("SystemRoot", r"C:\Windows")
        powershell = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        with tempfile.TemporaryDirectory(prefix="rewindle-password-helper-") as temp:
            helper = Path(temp) / "reveal-rclone-config-password.ps1"
            helper.write_bytes((PROJECT / "src" / "reveal-rclone-config-password.ps1").read_bytes())
            credential = Path(temp) / "rclone-config-password.clixml"
            characters = ", ".join(f"0x{ord(character):04x}" for character in password)
            made = run_windows_powershell(
                "$secret = ConvertTo-SecureString ([string]::new([char[]]@("
                + characters
                + "))) -AsPlainText -Force\n"
                "[pscredential]::new('rclone-config', $secret) | Export-Clixml -LiteralPath "
                + ps_literal(str(credential))
                + "\n"
            )
            self.assertEqual(0, made.returncode, made.stderr)
            completed = subprocess.run(
                [
                    powershell,
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(helper),
                    "-CredentialPath",
                    str(credential),
                ],
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=120,
                check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual(password.encode("utf-8") + b"\r\n", completed.stdout)


if __name__ == "__main__":
    unittest.main()
