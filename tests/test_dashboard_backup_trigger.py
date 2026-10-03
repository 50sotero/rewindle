from __future__ import annotations

from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WINDOW_SOURCE = PROJECT / "src" / "dashboard" / "DashboardWindow.cs"
CONTROLLER_SOURCE = PROJECT / "src" / "dashboard" / "BackupTaskController.cs"
SCHEDULE_SOURCE = PROJECT / "src" / "dashboard" / "TaskSchedule.cs"
BUILD_SOURCE = PROJECT / "src" / "dashboard" / "build.ps1"


class DashboardBackupTriggerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.profiles = (PROJECT / "src" / "dashboard" / "EngineProfile.cs").read_text(encoding="utf-8")
        cls.window = WINDOW_SOURCE.read_text(encoding="utf-8")
        cls.controller = CONTROLLER_SOURCE.read_text(encoding="utf-8")
        cls.schedule = SCHEDULE_SOURCE.read_text(encoding="utf-8")
        cls.build = BUILD_SOURCE.read_text(encoding="utf-8")

    def test_button_is_accessible_and_confirmation_protected(self) -> None:
        self.assertIn('backupNowButton = CreateButton("Back up now")', self.window)
        self.assertIn('SetAutomationId(backupNowButton, "BackupNowButton")', self.window)
        self.assertIn('"Start a real backup now?\\n\\n"', self.window)
        self.assertIn("MessageBoxResult.No", self.window)

    def test_button_is_disabled_for_conflicting_states(self) -> None:
        for marker in (
            "backupStartInProgress",
            "previewEnabled",
            "sourceOperationInProgress",
            "snapshot.IsActive",
            "backupRequestPendingUntilUtc",
            "backupRequestBaselineRunId",
        ):
            self.assertIn(marker, self.window)
        self.assertNotIn("backupRequestBaselineUpdatedLocal", self.window)
        self.assertGreaterEqual(self.window.count("BackupBlocksSourceChanges()"), 5)

    def test_controller_is_fixed_to_the_engine_profile_task(self) -> None:
        # The task and launcher are the active engine profile's: ResticBackuper for the public Rewindle engine.
        self.assertIn("get { return EngineProfile.Current.BackupTaskName; }", self.controller)
        self.assertIn("get { return EngineProfile.Current.LauncherFileName; }", self.schedule)
        self.assertIn('CreateCommon("ResticBackuper")', self.profiles)
        self.assertIn("profile.BackupTaskName = product;", self.profiles)
        self.assertIn('profile.LauncherFileName = "ResticBackuperTaskLauncher.exe";', self.profiles)
        self.assertIn("Environment.SpecialFolder.System", self.controller)
        self.assertIn('startInfo.Arguments = "/Query /TN', self.schedule)
        self.assertIn('startInfo.Arguments = "/Run /TN "', self.controller)
        self.assertIn('startInfo.Verb = "runas"', self.controller)

    def test_task_identity_and_duplicate_policy_are_validated_before_request(self) -> None:
        validation = self.controller.index("TryValidateInstalledTaskForStart")
        request = self.controller.index('startInfo.Arguments = "/Run /TN "')
        self.assertLess(validation, request)
        for marker in (
            "SamePath(command, expectedLauncher)",
            "SamePath(workingDirectory, installRoot)",
            "TryResolveSid(userId",
            '"InteractiveToken"',
            '"HighestAvailable"',
            '"IgnoreNew"',
            "actions.Count != 1",
            "principals.Count != 1",
            "actionsContext",
            "principalId",
            "allowDemandStart",
        ):
            self.assertIn(marker, self.schedule)
        self.assertIn("result.Schedule.Enabled", self.controller)
        self.assertIn("result.Schedule.AllowDemandStart", self.controller)

    def test_dashboard_never_launches_backup_components_directly(self) -> None:
        lower = self.controller.lower()
        self.assertNotIn("restic.exe", lower)
        self.assertNotIn("python.exe", lower)
        self.assertNotIn("backup.py", lower)
        self.assertNotIn("start-scheduledtask", lower)
        self.assertIn("BackupTaskController.cs", self.build)
        self.assertIn("TryValidateTaskXml", self.controller)


if __name__ == "__main__":
    unittest.main()
