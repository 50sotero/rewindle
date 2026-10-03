from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = (
    PROJECT / "src" / "verify_my_drive_cloud_repository.ps1"
).read_text(encoding="utf-8")
PASSWORD_HELPER = (
    PROJECT / "src" / "reveal-rclone-config-password.ps1"
).read_text(encoding="utf-8")


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
        self.assertIn("'RCLONE_DRIVE_SCOPE'", SCRIPT)
        self.assertIn("'drive.readonly'", SCRIPT)
        self.assertIn("'lsjson'", SCRIPT)
        self.assertIn("'--hash-type', 'MD5'", SCRIPT)
        self.assertIn("'--hash-type', 'SHA-256'", SCRIPT)
        self.assertIn("$remoteRepository = 'rclone:'", SCRIPT)
        self.assertIn("'--no-lock'", SCRIPT)
        self.assertIn("'--no-cache'", SCRIPT)
        self.assertIn("@('snapshots', '--json')", SCRIPT)
        self.assertIn("Get-ResticSnapshotListingFromJson", SCRIPT)
        self.assertIn("direct_cloud_latest_snapshot_verified = $true", SCRIPT)
        self.assertIn("'restore', $SnapshotId", SCRIPT)
        self.assertIn("'--verify'", SCRIPT)

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
