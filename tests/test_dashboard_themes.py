from __future__ import annotations

import re
from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1]
THEME_SOURCE = PROJECT / "src" / "dashboard" / "DashboardTheme.cs"
WINDOW_SOURCE = PROJECT / "src" / "dashboard" / "DashboardWindow.cs"
CHART_SOURCE = PROJECT / "src" / "dashboard" / "RunChart.cs"
BACKUP_TASK_SOURCE = PROJECT / "src" / "dashboard" / "BackupTaskController.cs"
TASK_SCHEDULE_SOURCE = PROJECT / "src" / "dashboard" / "TaskSchedule.cs"
TELEMETRY_SOURCE = PROJECT / "src" / "dashboard" / "Telemetry.cs"


def _relative_luminance(value: str) -> float:
    channels = [int(value[index : index + 2], 16) / 255 for index in (1, 3, 5)]
    linear = [
        channel / 12.92
        if channel <= 0.04045
        else ((channel + 0.055) / 1.055) ** 2.4
        for channel in channels
    ]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def _contrast(first: str, second: str) -> float:
    high, low = sorted(
        (_relative_luminance(first), _relative_luminance(second)),
        reverse=True,
    )
    return (high + 0.05) / (low + 0.05)


def _palette(source: str, name: str) -> dict[str, str]:
    match = re.search(
        rf"Create{name}Definition\(\).*?return new PaletteDefinition\s*\{{(.*?)\n\s*\}};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"missing {name} palette")
    return dict(
        re.findall(
            r'(\w+)\s*=\s*Hex\("(#[0-9A-Fa-f]{6})"\)',
            match.group(1),
        )
    )


class DashboardThemeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.theme_source = THEME_SOURCE.read_text(encoding="utf-8")
        cls.window_source = WINDOW_SOURCE.read_text(encoding="utf-8")
        cls.chart_source = CHART_SOURCE.read_text(encoding="utf-8")
        cls.backup_task_source = BACKUP_TASK_SOURCE.read_text(encoding="utf-8")
        cls.task_schedule_source = TASK_SCHEDULE_SOURCE.read_text(encoding="utf-8")
        cls.telemetry_source = TELEMETRY_SOURCE.read_text(encoding="utf-8")
        cls.palettes = {
            name: _palette(cls.theme_source, name)
            for name in ("Midnight", "Daylight")
        }

    def test_public_theme_preferences_are_complete(self) -> None:
        enum = re.search(
            r"enum DashboardThemePreference\s*\{(.*?)\}",
            self.theme_source,
            re.DOTALL,
        )
        self.assertIsNotNone(enum)
        names = re.findall(r"\b(System|Midnight|Daylight)\b", enum.group(1))
        self.assertEqual(["System", "Midnight", "Daylight"], names)
        for name in names:
            self.assertIn(f"DashboardThemePreference.{name}", self.window_source)

    def test_normal_text_and_controls_meet_contrast_targets(self) -> None:
        normal_text_pairs = (
            ("TextPrimary", "Surface"),
            ("TextSecondary", "Surface"),
            ("TextTertiary", "BackgroundTop"),
            ("FooterText", "BackgroundTop"),
            ("FooterText", "BackgroundBottom"),
            ("ButtonText", "ButtonBackground"),
            ("AddButtonText", "AccentPrimary"),
            ("TextOnAccent", "AccentPrimary"),
            ("AccentInfoText", "Surface"),
            ("AccentInfoText", "ScheduleBackground"),
            ("AccentInfoText", "RequiredBackground"),
            ("AccentPrimary", "Surface"),
            ("Success", "Surface"),
            ("Warning", "Surface"),
            ("Danger", "Surface"),
            ("AccentPurple", "Surface"),
            ("SafetyText", "SafetyBackground"),
            ("RemoveText", "RemoveBackground"),
            ("SelectionText", "Selection"),
            ("TextPrimary", "StatusLive"),
            ("TextPrimary", "StatusWarning"),
            ("TextPrimary", "StatusDanger"),
            ("TextPrimary", "StatusSuccess"),
            ("TextPrimary", "StatusReady"),
        )
        focus_pairs = (("Focus", "BackgroundTop"), ("Focus", "Surface"))

        for palette_name, palette in self.palettes.items():
            with self.subTest(palette=palette_name):
                for foreground, background in normal_text_pairs:
                    self.assertGreaterEqual(
                        _contrast(palette[foreground], palette[background]),
                        4.5,
                        f"{palette_name} {foreground} on {background}",
                    )
                for foreground, background in focus_pairs:
                    self.assertGreaterEqual(
                        _contrast(palette[foreground], palette[background]),
                        3.0,
                        f"{palette_name} focus on {background}",
                    )

    def test_every_legacy_literal_is_semantically_mapped(self) -> None:
        used = set(
            re.findall(
                r'BrushFrom\("(#[0-9A-Fa-f]{6})"\)',
                self.window_source,
            )
        )
        mapped = set(
            re.findall(
                r'brushes\["(#[0-9A-Fa-f]{6})"\]',
                self.theme_source,
            )
        )
        self.assertTrue(used)
        self.assertEqual(set(), used - mapped)

    def test_chart_and_window_are_palette_driven(self) -> None:
        self.assertIn("new RunChart(themeResolution.Palette)", self.window_source)
        self.assertIn("RunChart(DashboardThemePalette palette)", self.chart_source)
        self.assertNotIn("ColorConverter.ConvertFromString", self.chart_source)
        self.assertIn("BuildThemeSelector()", self.window_source)
        self.assertIn("availableWidth < 1320", self.window_source)
        self.assertIn("shellLayout.ColumnDefinitions[0].Width", self.window_source)
        self.assertIn('BuildNavigationButton("\\uE83D", "Protection", "Protection")', self.window_source)
        self.assertIn('BuildNavigationButton("\\uE81C", "Activity", "Activity")', self.window_source)
        self.assertIn('BuildNavigationButton("\\uE713", "Settings", "Settings")', self.window_source)
        self.assertIn("SystemEvents.UserPreferenceChanged", self.window_source)
        self.assertIn("themeButtons.TryGetValue", self.window_source)
        self.assertIn("newThemeButton.Focus()", self.window_source)
        self.assertGreaterEqual(self.window_source.count("ApplyButtonChrome(button);"), 2)
        self.assertIn("SystemParameters.HighContrast", self.theme_source)

    def test_native_utility_layout_stays_flat_and_compact(self) -> None:
        self.assertIn("Width = Math.Min(1280, SystemParameters.WorkArea.Width - 40);", self.window_source)
        self.assertIn("options.UseNativePresentation ? 720", self.window_source)
        self.assertIn("MinWidth = options.UseNativePresentation", self.window_source)
        self.assertIn('title.Text = "Protected folders"', self.window_source)
        self.assertIn('addSourceButton = CreateButton("Add folder")', self.window_source)
        self.assertIn('tableTitle.Text = "Recent backups"', self.window_source)
        self.assertIn("row.MinHeight = 44", self.window_source)
        self.assertIn('Button remove = CreateButton("×")', self.window_source)
        self.assertIn("activeProgressPanel.Visibility", self.window_source)
        self.assertIn("sourceScroller.VerticalScrollBarVisibility", self.window_source)
        self.assertIn("Background = BackgroundTop", self.window_source)
        self.assertNotIn("new DropShadowEffect", self.window_source)
        self.assertNotIn("metricsLayout.Margin = new Thickness(-5)", self.window_source)
        self.assertIn("protectionHero.MinHeight = 168", self.window_source)
        self.assertIn("runChart.Width = 150", self.window_source)
        self.assertNotIn("Border chartStrip", self.window_source)

    def test_information_architecture_separates_primary_workflows(self) -> None:
        self.assertIn("protectionOverview = BuildProtectionPage();", self.window_source)
        self.assertIn("historyLayout = BuildActivityPage();", self.window_source)
        self.assertIn("settingsPage = (FrameworkElement)BuildSettingsPage();", self.window_source)
        self.assertIn('ShowDashboardPage("Protection")', self.window_source)
        self.assertIn('backupNowButton = CreateButton("Back up now")', self.window_source)
        self.assertIn('cancelBackupButton = CreateButton("Cancel backup")', self.window_source)
        self.assertIn('editScheduleButton = CreateButton("Edit schedule")', self.window_source)
        self.assertIn('repositoryLabel.Text = "Destination"', self.window_source)
        self.assertIn(
            'previewButton = CreateButton(previewEnabled ? "Stop preview" : "Preview animation")',
            self.window_source,
        )
        self.assertIn("PreviewKeyDown += OnDashboardPreviewKeyDown", self.window_source)

    def test_dashboard_does_not_present_configuration_or_estimates_as_fact(self) -> None:
        self.assertIn("Reading installed schedule", self.window_source)
        self.assertIn("TaskScheduleReader.ReadInstalled()", self.window_source)
        self.assertNotIn("Google Drive copy 03:00", self.window_source)
        self.assertNotIn('etaValue.Text = "02:00"', self.window_source)
        self.assertIn("hasActualFileCount", self.window_source)
        self.assertIn("hasActualByteCount", self.window_source)
        self.assertNotIn(
            "snapshot.FilesDone > 0 ? snapshot.FilesDone : snapshot.EstimatedFiles",
            self.window_source,
        )
        self.assertNotIn(
            "snapshot.BytesDone > 0 ? snapshot.BytesDone : snapshot.EstimatedBytes",
            self.window_source,
        )
        self.assertIn("restore canary missing", self.window_source)
        self.assertNotIn("restore canary covered", self.window_source)

    def test_backup_now_requests_only_the_validated_scheduled_task(self) -> None:
        self.assertIn('backupNowButton = CreateButton("Back up now")', self.window_source)
        self.assertIn('SetAutomationId(backupNowButton, "BackupNowButton")', self.window_source)
        self.assertIn('"Start a real backup now?\\n\\n"', self.window_source)
        self.assertIn("snapshot.IsActive", self.window_source)
        self.assertIn("sourceOperationInProgress", self.window_source)
        self.assertIn("previewEnabled", self.window_source)
        self.assertIn("backupRequestBaselineRunId", self.window_source)
        self.assertNotIn("backupRequestBaselineUpdatedLocal", self.window_source)
        self.assertGreaterEqual(self.window_source.count("BackupBlocksSourceChanges()"), 5)
        self.assertIn("get { return EngineProfile.Current.BackupTaskName; }", self.backup_task_source)
        self.assertIn("Environment.SpecialFolder.System", self.backup_task_source)
        self.assertIn('startInfo.Arguments = "/Query /TN', self.task_schedule_source)
        self.assertIn('startInfo.Arguments = "/Run /TN "', self.backup_task_source)
        self.assertIn('startInfo.Verb = "runas"', self.backup_task_source)
        self.assertIn("TryValidateInstalledTaskForStart", self.backup_task_source)
        self.assertIn('"HighestAvailable"', self.task_schedule_source)
        self.assertIn('"InteractiveToken"', self.task_schedule_source)
        self.assertIn('"IgnoreNew"', self.task_schedule_source)
        self.assertIn("actions.Count != 1", self.task_schedule_source)
        self.assertIn("principals.Count != 1", self.task_schedule_source)
        self.assertIn("actionsContext", self.task_schedule_source)
        self.assertIn("principalId", self.task_schedule_source)
        self.assertIn("allowDemandStart", self.task_schedule_source)
        self.assertIn("TryValidateTaskXml", self.backup_task_source)
        self.assertIn("TryResolveSid(userId", self.task_schedule_source)
        self.assertIn("SamePath(command, expectedLauncher)", self.task_schedule_source)
        self.assertIn("result.Schedule.Enabled", self.backup_task_source)
        self.assertNotIn("restic.exe", self.backup_task_source.lower())
        self.assertNotIn("python.exe", self.backup_task_source.lower())
        self.assertNotIn("Start-ScheduledTask", self.backup_task_source)

    def test_settings_are_bounded_and_per_user(self) -> None:
        self.assertIn("EngineProfile.Current.DashboardDataDirectory()", self.theme_source)
        profiles = (PROJECT / "src" / "dashboard" / "EngineProfile.cs").read_text(encoding="utf-8")
        self.assertIn("Environment.SpecialFolder.LocalApplicationData", profiles)
        self.assertIn('profile.DashboardDataDirectoryName = product + "Dashboard";', profiles)
        self.assertIn('SettingsFileName = "settings.json"', self.theme_source)
        self.assertIn("MaximumSettingsBytes = 16 * 1024", self.theme_source)
        self.assertIn("IsReparsePoint", self.theme_source)
        self.assertIn("TryParsePreference", self.theme_source)
        self.assertNotIn("SpecialFolder.CommonApplicationData", self.theme_source)

    def test_replace_existing_writes_use_real_same_directory_backups(self) -> None:
        replacement_sources = (
            self.theme_source,
            self.telemetry_source,
            self.window_source,
        )
        atomic = (PROJECT / "src" / "dashboard" / "AtomicFile.cs").read_text(encoding="utf-8")
        for source in replacement_sources:
            with self.subTest(source_length=len(source)):
                self.assertIsNone(
                    re.search(
                        r"File\.Replace\([^;]*,\s*null\s*,\s*true\)",
                        source,
                        re.DOTALL,
                    )
                )
                # Every replacement of an existing file goes through the one helper below.
                self.assertIn("AtomicFile.ReplaceExisting(", source)
        self.assertIn('Guid.NewGuid().ToString("N") + ".bak"', atomic)
        self.assertIn("File.Delete(backupPath)", atomic)
        self.assertIsNone(re.search(r"File\.Replace\([^;]*,\s*null\s*,\s*true\)", atomic, re.DOTALL))


if __name__ == "__main__":
    unittest.main()
