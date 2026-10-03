from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"


class DashboardRecoveryHealthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.backend = (PROJECT / "src" / "recovery_health.py").read_text(encoding="utf-8")
        cls.repair = (PROJECT / "src" / "credential_repair.py").read_text(encoding="utf-8")
        cls.lock_repair = (PROJECT / "src" / "stale_lock_repair.py").read_text(encoding="utf-8")
        cls.key_rotation = (PROJECT / "src" / "key_rotation.py").read_text(encoding="utf-8")
        cls.manager = (DASHBOARD / "RecoveryHealthManager.cs").read_text(encoding="utf-8")
        cls.restore_manager = (DASHBOARD / "RestoreManager.cs").read_text(encoding="utf-8")
        cls.window = (DASHBOARD / "RecoveryReadinessWindow.cs").read_text(encoding="utf-8")
        cls.dashboard = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")

    def test_bounded_capture_accepts_exact_bytes_and_rejects_overflow_and_bad_utf8(self) -> None:
        if os.name != "nt":
            self.skipTest("dashboard capture is Windows-only")
        framework = (
            Path(os.environ.get("SystemRoot", r"C:\Windows"))
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            self.skipTest(".NET Framework C# compiler is unavailable")
        with tempfile.TemporaryDirectory(prefix="readiness-capture-") as root_text:
            executable = Path(root_text) / "RecoveryHealthCaptureHarness.exe"
            compile_result = subprocess.run(
                [
                    str(compiler),
                    "/nologo",
                    "/target:exe",
                    "/platform:x64",
                    f"/out:{executable}",
                    f"/reference:{framework / 'System.dll'}",
                    f"/reference:{framework / 'System.Core.dll'}",
                    f"/reference:{framework / 'System.Web.Extensions.dll'}",
                    str(DASHBOARD / "EngineProfile.cs"),
                    str(DASHBOARD / "AtomicFile.cs"),
                    str(DASHBOARD / "SourceConfiguration.cs"),
                    str(DASHBOARD / "Telemetry.cs"),
                    str(DASHBOARD / "TaskSchedule.cs"),
                    str(DASHBOARD / "RecoveryHealthManager.cs"),
                    str(PROJECT / "tests" / "fixtures" / "RecoveryHealthCaptureHarness.cs"),
                ],
                cwd=PROJECT,
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
            self.assertEqual(
                0,
                compile_result.returncode,
                compile_result.stdout + compile_result.stderr,
            )
            run_result = subprocess.run(
                [str(executable)],
                cwd=PROJECT,
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
            self.assertEqual(0, run_result.returncode, run_result.stderr)
            self.assertIn("bounded capture checks passed", run_result.stdout)

    def test_readiness_authenticates_active_and_recovery_credentials_independently(self) -> None:
        self.assertIn('"active_credential"', self.backend)
        self.assertIn('"recovery_key"', self.backend)
        self.assertIn('environment["RESTIC_PASSWORD"] = password', self.backend)
        self.assertIn('["--password-command", password_command(', self.backend)
        self.assertIn('environment.pop("RESTIC_PASSWORD", None)', self.backend)
        self.assertNotRegex(self.backend, r'print\([^\n]*(password|recovery_password)')

    def test_health_commands_are_read_only_and_do_not_lock_or_cache(self) -> None:
        self.assertIn('"--no-lock"', self.backend)
        self.assertIn('"--no-cache"', self.backend)
        self.assertIn('"cat",\n            "config"', self.backend)
        self.assertIn('"list",\n            "locks"', self.backend)
        self.assertNotRegex(
            self.backend,
            r'(?i)["\'](?:backup|forget|prune|unlock|key remove|delete)["\']',
        )

    def test_report_binds_to_plan_generation_repository_and_bounded_schema(self) -> None:
        for evidence in (
            "get { return EngineProfile.Current.RecoveryHealthSchema; }",
            'ReadString(document, "plan_id") != configuration.PlanId',
            'ReadLong(document, "config_generation") != configuration.ConfigGeneration',
            'PathEquals(ReadString(document, "repository"), configuration.RepositoryPath)',
            'MaximumOutputBytes = 4 * 1024 * 1024',
            'MaximumErrorBytes = 256 * 1024',
            'process.StandardOutput.BaseStream',
            'process.StandardError.BaseStream',
            'private sealed class BoundedUtf8Capture',
            'checks.Count >= 64',
        ):
            self.assertIn(evidence, self.manager)

    def test_launchers_preserve_trusted_sibling_imports_without_environment_injection(self) -> None:
        self.assertEqual(5, self.manager.count('"-E", "-S", "-B"'))
        self.assertNotIn('"-I", "-S", "-B"', self.manager)
        self.assertIn('Recovery-readiness output exceeded its safety limit.', self.manager)
        self.assertIn('Recovery-readiness diagnostics exceeded their safety limit.', self.manager)

    def test_repair_is_uac_protected_shared_lock_bound_and_never_changes_repository_keys(self) -> None:
        self.assertIn('start.Verb = "runas"', self.manager)
        self.assertIn("load_config_under_lock", self.repair)
        self.assertIn("validate_runtime_manifest", self.repair)
        self.assertIn("replace_secret(secret, recovery_password)", self.repair)
        self.assertIn('"repository_modified": False', self.repair)
        self.assertIn('"recovery_key_modified": False', self.repair)
        self.assertNotRegex(self.repair, r'(?i)["\'](?:key add|key remove|forget|prune|unlock)["\']')

    def test_repair_requires_recovery_pass_and_active_failure_then_rechecks_both(self) -> None:
        self.assertIn('CheckPassed(report, "recovery_key")', self.window)
        self.assertIn('!CheckPassed(report, "active_credential")', self.window)
        self.assertIn("CredentialRepairLauncher.Repair", self.window)
        self.assertIn("The recovery key and the replacement CurrentUser credential both unlock the same repository.", self.window)
        self.assertIn("The repository, repository keys, snapshots and the recovery-key file are not changed.", self.window)

    def test_stale_lock_repair_is_explicit_conservative_and_post_checked(self) -> None:
        self.assertIn("load_config_under_lock", self.lock_repair)
        self.assertIn("running_restic_processes", self.lock_repair)
        self.assertIn('"unlock"', self.lock_repair)
        self.assertNotIn('"--remove-all"', self.lock_repair)
        self.assertIn('"snapshots_modified": False', self.lock_repair)
        self.assertIn('"data_modified": False', self.lock_repair)
        self.assertIn('LockRepairLabel = "Repair stale locks"', self.window)
        self.assertIn("Button(LockRepairLabel, false)", self.window)
        self.assertIn("StaleLockRepairLauncher.Repair", self.window)
        self.assertIn("It never uses --remove-all", self.window)

    def test_guided_restore_drill_uses_protected_manager_and_refreshes_health(self) -> None:
        self.assertIn('DrillLabel = "Run restore drill"', self.window)
        self.assertIn("Button(DrillLabel, false)", self.window)
        self.assertIn('RestoreManagerLauncher.RunRecoveryDrill(', self.window)
        self.assertIn('RecoveryHealthLauncher.Inspect(configuration)', self.window)
        self.assertIn('CheckNeedsReview(report, "restore_drill")', self.window)
        self.assertIn('CheckPassed(report, "recovery_key")', self.window)
        self.assertIn('CheckPassed(report, "recovery_bundle")', self.window)
        self.assertIn('BuildRecoveryDrillTarget(nonce)', self.restore_manager)
        self.assertIn('target.Length > 0 && action != "restore_drill"', self.restore_manager)
        self.assertIn('"restore_drill"', self.restore_manager)
        self.assertIn('historyRecorded != true', self.restore_manager)
        self.assertNotIn('restic.exe', self.window.lower())
        self.assertNotIn('RESTIC_PASSWORD', self.window)

    def test_dashboard_exposes_readiness_and_build_includes_every_component(self) -> None:
        self.assertIn('CreateButton("Check recovery readiness")', self.dashboard)
        self.assertIn("OnCheckRecoveryReadinessClick", self.dashboard)
        self.assertIn("RecoveryReadinessWindow", self.dashboard)
        for component in (
            "RecoveryHealthManager.cs",
            "RecoveryReadinessWindow.cs",
        ):
            self.assertIn(component, self.build)

    def test_key_rotation_adds_and_proves_before_switch_and_retains_rollback_key(self) -> None:
        self.assertIn('"key",\n            "add"', self.key_rotation)
        self.assertIn("_authenticate_plaintext(", self.key_rotation)
        completion = self.key_rotation[
            self.key_rotation.index("def _finish_rotation(") : self.key_rotation.index("def rotate(")
        ]
        self.assertLess(
            completion.index("_authenticate_plaintext("),
            completion.index("replace_secret(secret, new_password)"),
        )
        self.assertIn('"previous_repository_key_retained": True', self.key_rotation)
        self.assertIn('"snapshots_modified": False', self.key_rotation)
        self.assertIn('"repository_data_modified": False', self.key_rotation)
        self.assertNotIn('"key", "remove"', self.key_rotation)
        self.assertIn("credential-rotation.journal.json", self.key_rotation)
        self.assertIn('RotateLabel = "Rotate keys"', self.window)
        self.assertIn("Button(RotateLabel, false)", self.window)
        self.assertIn("KeyRotationLauncher.Rotate", self.window)
        self.assertIn("The previous repository key and a restricted copy of the previous recovery-key file are kept for rollback", self.window)
        self.assertIn("rotation_rollback_key", self.manager)


if __name__ == "__main__":
    unittest.main()
