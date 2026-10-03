from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"


class DashboardFreshnessSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.telemetry = (DASHBOARD / "Telemetry.cs").read_text(encoding="utf-8")
        cls.freshness = (DASHBOARD / "BackupFreshness.cs").read_text(encoding="utf-8")
        cls.window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")

    def method(self, name: str, next_name: str) -> str:
        start = self.window.index(f"private void {name}")
        end = self.window.index(f"private void {next_name}", start)
        return self.window[start:end]

    def test_last_success_is_an_independent_read_only_input(self) -> None:
        self.assertIn('Path.Combine(this.stateDirectory, "last-success.json")', self.telemetry)
        self.assertIn("snapshot.LastVerifiedFinishedUtc", self.telemetry)
        self.assertIn("TryReadLastVerifiedFinishedUtc", self.telemetry)
        self.assertIn('result["last_success"]', self.telemetry)
        self.assertRegex(
            self.telemetry,
            r'"status\.json",\s*"dry-run-latest\.json",\s*"last-success\.json"',
        )

    def test_evaluator_is_calendar_based_and_side_effect_free(self) -> None:
        self.assertIn("FindLatestDueOccurrence", self.freshness)
        self.assertIn("date.Add(schedule.TimeOfDay)", self.freshness)
        self.assertIn("IsInvalidTime", self.freshness)
        self.assertIn("GetAmbiguousTimeOffsets", self.freshness)
        self.assertNotIn("TimeSpan.FromHours(24)", self.freshness)
        for mutating_api in (
            "Process.Start",
            "File.Write",
            "File.Delete",
            "Directory.CreateDirectory",
            "TaskScheduleReader",
        ):
            self.assertNotIn(mutating_api, self.freshness)

    def test_protection_and_settings_have_named_non_color_statuses(self) -> None:
        self.assertIn('"ProtectionBackupFreshnessStatus"', self.window)
        self.assertIn('"SettingsBackupFreshnessStatus"', self.window)
        self.assertIn('shortStatus = "Backup freshness: " + freshness.StatusLabel', self.window)
        self.assertIn("AutomationProperties.SetHelpText(protectionFreshnessStatus", self.window)
        self.assertIn("AutomationProperties.SetHelpText(settingsFreshnessStatus", self.window)
        for label in (
            'SetBadge("NEEDS ATTENTION"',
            'SetBadge("PAUSED"',
            'SetBadge("FIRST BACKUP NEEDED"',
        ):
            self.assertIn(label, self.window)

    def test_active_and_cancelling_run_status_has_precedence(self) -> None:
        freshness = self.method("ApplyFreshnessStatus", "ApplyPreview")
        gate = freshness.index("if (activeRunOwnsPrimaryStatus)")
        early_return = freshness.index("return;", gate)
        attention_override = freshness.index('SetBadge("NEEDS ATTENTION"')
        self.assertLess(gate, early_return)
        self.assertLess(early_return, attention_override)
        self.assertRegex(
            freshness,
            re.compile(
                r"snapshot\.IsActive\s*\|\|\s*string\.Equals\(\s*"
                r"snapshot\.StateKey,\s*\"cancelling\"",
                re.MULTILINE,
            ),
        )

    def test_build_includes_the_freshness_evaluator(self) -> None:
        self.assertIn("(Join-Path $project 'BackupFreshness.cs')", self.build)


if __name__ == "__main__":
    unittest.main()
