import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "src" / "dashboard"


class DashboardScheduleUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.editor = (DASHBOARD / "ScheduleEditorWindow.cs").read_text(encoding="utf-8")
        cls.launcher = (DASHBOARD / "ScheduleManagerLauncher.cs").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")
        cls.sources = (DASHBOARD / "SourceConfiguration.cs").read_text(encoding="utf-8")
        cls.schedule = (DASHBOARD / "TaskSchedule.cs").read_text(encoding="utf-8")

    def test_schedule_is_visible_and_not_hard_coded(self):
        self.assertIn('SetAutomationId(editScheduleButton, "EditScheduleButton")', self.window)
        self.assertIn("currentTaskSchedule.Summary", self.window)
        self.assertIn("currentTaskSchedule.NextRunDisplay", self.window)
        self.assertNotIn("Google Drive copy 03:00", self.window)
        self.assertNotRegex(self.window, r'etaValue\.Text\s*=\s*"02:00"')

    def test_plan_facts_show_the_validated_repository(self):
        self.assertIn("public string RepositoryPath { get; private set; }", self.sources)
        self.assertIn('document.TryGetValue("repository", out repositoryValue)', self.sources)
        self.assertIn("Path.IsPathRooted(repositoryPath)", self.sources)
        self.assertIn("RepositoryPath = repositoryPath", self.sources)
        self.assertIn("currentSourceConfiguration.RepositoryPath", self.window)
        self.assertIn('repositoryLabel.Text = "Destination"', self.window)

    def test_editor_covers_supported_task_scheduler_policy(self):
        for marker in (
            "Every day",
            "Selected days",
            "ScheduleOptionText.RunMissed",
            "ScheduleOptionText.Wake",
            "ScheduleOptionText.FinishIfUnplugged",
            "Automatic backups",
        ):
            self.assertIn(marker, self.editor)
        for marker in (
            'RunMissed = "Run when the PC is next available"',
            'Wake = "Wake this PC from sleep"',
            'StartOnBattery = "May start on battery"',
            'FinishIfUnplugged = "Let a running backup finish if the PC is unplugged"',
        ):
            self.assertIn(marker, self.schedule)
        self.assertIn("AutomationLiveSetting.Assertive", self.editor)
        self.assertIn('CreateButton("Review schedule", true)', self.editor)

    def test_apply_requires_manager_and_independent_reread(self):
        manager_call = self.window.index("ScheduleManagerLauncher.Run(")
        verification = self.window.index(
            "TaskScheduleReadResult independentRead = await ReadScheduleOffUiThreadAsync()",
            manager_call,
        )
        success = self.window.index(
            'SetScheduleStatus("Schedule updated and independently verified."',
            verification,
        )
        self.assertLess(manager_call, verification)
        self.assertLess(verification, success)
        self.assertIn("independentRead.Schedule.Matches(requested)", self.window)

    def test_schedule_changes_block_other_mutations(self):
        self.assertRegex(
            self.window,
            r"private bool BackupBlocksSourceChanges\(\)[\s\S]{0,220}scheduleOperationInProgress",
        )
        self.assertRegex(
            self.window,
            r"private async void OnBackupNowClick[\s\S]{0,350}scheduleOperationInProgress",
        )
        self.assertIn("Wait for the current backup to finish before changing its schedule.", self.window)

    def test_ui_does_not_start_a_backup_as_part_of_schedule_change(self):
        forbidden = ("Start-ScheduledTask", "schtasks /Run", "schtasks.exe /Run")
        for text in forbidden:
            self.assertNotIn(text, self.editor)
            self.assertNotIn(text, self.launcher)
        self.assertIn("ScheduleEditorWindow.cs", self.build)
        self.assertIn("TaskSchedule.cs", self.build)
        self.assertIn("ScheduleManagerLauncher.cs", self.build)


if __name__ == "__main__":
    unittest.main()
