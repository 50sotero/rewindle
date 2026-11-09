import csv
import json
import os
from pathlib import Path
import re
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
    from Go's only for a quote inside a field and for repeated spaces (an
    empty field), so both are refused here instead of modelled."""
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
        self.assertIn("rclone_scope = 'drive.readonly'", SCRIPT)
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
        self.assertEqual(7, len(launches))
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
        # which a backslash outside quotes separates fields. The model above
        # agrees with it here only because every path is double-quoted.
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
        self.assertIn("[Console]::Out.WriteLine($plainText)", PASSWORD_HELPER)
        self.assertNotIn("Write-Verbose", PASSWORD_HELPER)
        for relative in (
            "build/Build-Release.ps1",
            "installer/Install-ResticBackuper.ps1",
            "tests/Test-ReleaseArtifact.ps1",
        ):
            text = (PROJECT / relative).read_text(encoding="utf-8")
            self.assertIn("'reveal-rclone-config-password.ps1'", text)


if __name__ == "__main__":
    unittest.main()
