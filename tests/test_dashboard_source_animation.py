from __future__ import annotations

from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WINDOW_SOURCE = PROJECT / "src" / "dashboard" / "DashboardWindow.cs"
SOURCE_CONFIG_SOURCE = PROJECT / "src" / "dashboard" / "SourceConfiguration.cs"


class DashboardSourceAnimationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window = WINDOW_SOURCE.read_text(encoding="utf-8")
        cls.source_config = SOURCE_CONFIG_SOURCE.read_text(encoding="utf-8")

    def test_add_folder_has_durable_lifecycle_states(self) -> None:
        for stage in (
            "Idle",
            "AwaitingApproval",
            "Applying",
            "Verifying",
            "Succeeded",
            "Cancelled",
            "Failed",
        ):
            self.assertIn(stage, self.window)
        self.assertIn("sourceOperationGeneration", self.window)
        self.assertIn("sourceOperationExpiresUtc", self.window)
        self.assertIn("animateNextResolvedSourceRow", self.window)

    def test_add_flow_uses_elevated_launch_callback_before_wait(self) -> None:
        callback = self.source_config.index("onElevatedProcessStarted();")
        wait = self.source_config.index("process.WaitForExit();")
        self.assertLess(callback, wait)
        self.assertIn("SourceManagerLauncher.Run(", self.window)
        self.assertIn("SourceOperationStage.Applying", self.window)

    def test_pending_copy_is_honest_about_backup_state(self) -> None:
        for marker in (
            "No backup has started.",
            "The folder is not shown as protected until this check passes.",
            "Protected list unchanged.",
            "Included in the next backup",
        ):
            self.assertIn(marker, self.window)
        self.assertNotIn("Estimated time remaining for folder add", self.window)

    def test_activity_respects_motion_and_accessibility_preferences(self) -> None:
        motion = (PROJECT / "src" / "dashboard" / "DashboardMotion.cs").read_text(encoding="utf-8")
        self.assertIn("SystemParameters.ClientAreaAnimation", motion)
        self.assertIn("!themeResolution.IsHighContrast", self.window)
        self.assertIn("StopSourceOperationAnimation()", self.window)
        self.assertIn("AutomationEvents.LiveRegionChanged", self.window)
        self.assertIn("AutomationLiveSetting.Assertive", self.window)

    def test_retry_and_dismiss_are_inline_not_dialog_driven_for_add_failures(self) -> None:
        self.assertIn('"RetryAddFolderButton"', self.window)
        self.assertIn('"DismissAddFolderStatusButton"', self.window)
        failed = self.window.index("SourceOperationStage.Failed")
        self.assertGreater(self.window.index("sourceOperationRetryButton.Visibility", failed), failed)
        add_flow = self.window[self.window.index("private async Task ApplySourceChange") :]
        self.assertNotIn('"Folder change failed",\n                    MessageBoxButton.OK', add_flow.split("else\n                {", 1)[0])


if __name__ == "__main__":
    unittest.main()
