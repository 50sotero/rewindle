from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"


class DashboardRestoreUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.restore_window = (DASHBOARD / "RestoreWindow.cs").read_text(encoding="utf-8")
        cls.manager = (DASHBOARD / "RestoreManager.cs").read_text(encoding="utf-8")
        cls.protected_manager = (PROJECT / "src" / "Manage-Restore.ps1").read_text(encoding="utf-8")
        cls.restore_backend = (PROJECT / "src" / "restore.py").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")
        cls.installer = (PROJECT / "installer" / "Install-ResticBackuper.ps1").read_text(encoding="utf-8")
        cls.builder = (PROJECT / "build" / "Build-Release.ps1").read_text(encoding="utf-8")

    def test_restore_is_a_first_class_navigation_page_and_build_component(self) -> None:
        self.assertIn('BuildNavigationButton("\\uE8F3", "Restore", "Restore")', self.window)
        self.assertIn("BuildRestorePage()", self.window)
        self.assertIn('string.Equals(selectedDashboardPage, "Restore"', self.window)
        self.assertIn("RestoreManager.cs", self.build)
        self.assertIn("RestoreWindow.cs", self.build)

    def test_launcher_binds_every_result_to_nonce_sid_config_plan_and_generation(self) -> None:
        self.assertIn("get { return EngineProfile.Current.RestoreRequestDomain; }", self.manager)
        profiles = (DASHBOARD / "EngineProfile.cs").read_text(encoding="utf-8")
        self.assertIn('profile.RestoreRequestDomain = product + ".RestoreRequest.v2";', profiles)
        self.assertIn('CreateCommon("ResticBackuper")', profiles)
        for field in (
            'ReadString(document, "request_nonce")',
            'ReadString(document, "request_digest")',
            'ReadString(document, "request_user_sid")',
            'ReadString(document, "expected_config_sha256")',
            'ReadString(document, "plan_id")',
            'ReadLong(document, "config_generation")',
            'ReadBoolean(document, "allow_legacy_unbound")',
            'ReadString(document, "includes_sha256")',
        ):
            self.assertIn(field, self.manager)
        self.assertIn("FixedEquals", self.manager)
        self.assertIn('Verb = "runas"', self.manager)

    def test_legacy_snapshots_are_narrowly_classified_and_require_explicit_consent(self) -> None:
        for evidence in (
            '"legacy_unbound"',
            '"Legacy / unbound"',
            '"-AllowLegacyUnbound"',
            '"exact-host-scheduled-tags-and-sources"',
        ):
            self.assertIn(evidence, self.manager)
        for evidence in (
            "repository, computer, scheduled tag, and exact source-path set",
            "Confirm legacy / unbound snapshot",
            "MessageBoxButton.YesNo",
            "snapshot.IsLegacyUnbound",
            "explicit confirmation required",
        ):
            self.assertIn(evidence, self.restore_window)

    def test_ui_uses_only_protected_manager_and_never_invokes_restic_directly(self) -> None:
        self.assertIn("RestoreManagerLauncher.ListSnapshots", self.restore_window)
        self.assertIn("RestoreManagerLauncher.ListTree", self.restore_window)
        self.assertIn("RestoreManagerLauncher.Restore", self.restore_window)
        self.assertNotRegex(self.restore_window, r"restic\.exe|restore\.py")
        self.assertEqual(1, self.restore_window.count("Process.Start("))
        self.assertIn('FileName = "explorer.exe"', self.restore_window)

    def test_alternate_location_is_empty_reviewed_non_overwrite_and_verified(self) -> None:
        for evidence in (
            "New or empty destination folder",
            "The restore destination must be empty.",
            "Restore and verify",
            "never overwrite",
            "verify after restore",
            "partial files retained",
        ):
            self.assertIn(evidence, self.restore_window)
        self.assertIn("MessageBoxButton.OKCancel", self.restore_window)
        self.assertNotIn("overwrite always", self.restore_window.lower())

    def test_progress_and_terminal_states_are_accessible_and_truthful(self) -> None:
        self.assertIn("AutomationLiveSetting.Assertive", self.restore_window)
        self.assertIn("AutomationLiveSetting.Polite", self.restore_window)
        self.assertIn('AutomationProperties.SetName(targetBox, "Restore destination folder")', self.restore_window)
        self.assertIn("Restore complete and verified", self.restore_window)
        self.assertIn("Restore incomplete — partial files retained", self.restore_window)
        self.assertIn("operationInProgress", self.restore_window)
        self.assertIn("args.Cancel = true", self.restore_window)

    def test_restore_blocks_during_backup_or_protected_recovery(self) -> None:
        readiness = re.search(
            r"private void UpdateRestoreReadiness\(\)(.*?)(?=\n\s*private )",
            self.window,
            flags=re.S,
        )
        self.assertIsNotNone(readiness)
        text = readiness.group(1)
        self.assertIn("repositoryOperationInProgress", text)
        self.assertIn("repositoryRecoveryInProgress", text)
        self.assertIn("repositoryRecoveryStatus.Exists", text)
        self.assertIn("BackupBlocksSourceChanges()", text)

    def test_restore_backend_and_manager_ship_in_every_runtime_path(self) -> None:
        for source in (self.installer, self.builder):
            self.assertIn("restore.py", source)
            self.assertIn("Manage-Restore.ps1", source)
            self.assertIn("refresh_recovery_tools.py", source)
            self.assertIn("'engine-capabilities.json'", source)

    def test_engine_capabilities_advertise_the_session_the_manager_serves(self) -> None:
        import json

        capabilities = json.loads((PROJECT / "src" / "engine-capabilities.json").read_text(encoding="utf-8"))
        self.assertEqual("ResticBackuper.EngineCapabilities.v1", capabilities["schema"])
        self.assertEqual(1, capabilities["schema_version"])
        session = capabilities["restore_session"]
        self.assertIn(f"$sessionProtocol = '{session['protocol']}'", self.protected_manager)
        self.assertIn(f"$sessionRequestDomain = '{session['request_domain']}'", self.protected_manager)
        self.assertEqual("Manage-Restore.ps1", session["manager"])
        # Every request a session serves goes through the single request's validation and protected step.
        self.assertIn("Initialize-RestoreRequest -RequestAction $Request.Action", self.protected_manager)
        self.assertIn("Initialize-RestoreRequest -RequestAction $Action", self.protected_manager)
        self.assertEqual(2, self.protected_manager.count("$null = Invoke-RestoreOperation"))
        # A session never compiles code into a folder the requesting account can write.
        self.assertNotIn("Add-Type", self.protected_manager)

    def test_guided_drill_omits_snapshot_acls_and_protects_retained_output(self) -> None:
        self.assertRegex(self.restore_backend, r'"--exclude-xattr",\s*"\*"')
        self.assertIn("Protect-RecoveryDrillTarget", self.protected_manager)
        self.assertLess(
            self.protected_manager.index("Protect-RecoveryDrillTarget -Path $canonicalTarget"),
            self.protected_manager.index("Write-RestoreHistory -Payload $payload", self.protected_manager.index("Protect-RecoveryDrillTarget -Path $canonicalTarget")),
        )


if __name__ == "__main__":
    unittest.main()
