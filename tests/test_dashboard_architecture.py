from __future__ import annotations

from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WINDOW_SOURCE = PROJECT / "src" / "dashboard" / "DashboardWindow.cs"


class DashboardArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window = WINDOW_SOURCE.read_text(encoding="utf-8")

    def method(self, name: str, next_name: str) -> str:
        declaration = re.compile(
            rf"\n\s+private\s+[^\r\n]+?\s+{re.escape(name)}\("
        )
        next_declaration = re.compile(
            rf"\n\s+private\s+[^\r\n]+?\s+{re.escape(next_name)}\("
        )
        match = declaration.search(self.window)
        if match is None:
            self.fail(f"Could not find private method declaration for {name}")
        next_match = next_declaration.search(self.window, match.end())
        if next_match is None:
            self.fail(f"Could not find private method declaration for {next_name}")
        start = match.start()
        end = next_match.start()
        return self.window[start:end]

    def test_navigation_rail_routes_protection_activity_and_settings_pages(self) -> None:
        navigation = self.method("BuildNavigationRail", "BuildNavigationButton")
        for marker in (
            'BuildNavigationButton("\\uE83D", "Protection", "Protection")',
            'BuildNavigationButton("\\uE81C", "Activity", "Activity")',
            'BuildNavigationButton("\\uE713", "Settings", "Settings")',
        ):
            self.assertIn(marker, navigation)

        routing = self.method("ShowDashboardPage", "StyleNavigationButton")
        for page, element in (
            ("Protection", "protectionOverview"),
            ("Activity", "historyLayout"),
            ("Settings", "settingsPage"),
        ):
            self.assertRegex(
                routing,
                rf"{element}\.Visibility\s*=\s*string\.Equals\(selectedDashboardPage,\s*\"{page}\"",
            )

    def test_protection_page_owns_backup_now_and_always_visible_cancel(self) -> None:
        protection = self.method("BuildProtectionPage", "BuildActivityPage")
        self.assertIn('backupNowButton = CreateButton("Back up now")', protection)
        self.assertIn('cancelBackupButton = CreateButton("Cancel backup")', protection)
        self.assertIn("actions.Children.Add(backupNowButton);", protection)
        self.assertIn("actions.Children.Add(cancelBackupButton);", protection)
        self.assertIn("cancelBackupButton.Visibility = Visibility.Visible;", protection)

        update = self.method("UpdateCancelButton", "SetCancellationStatus")
        self.assertIn("bool enabled = false;", update)
        self.assertRegex(
            update,
            r"else\s*\{\s*label = \"Cancel backup\";\s*helpText = \"Available while an exact protected backup run is active\.\";\s*\}",
        )
        self.assertIn("cancelBackupButton.Visibility = Visibility.Visible;", update)
        self.assertIn("cancelBackupButton.IsEnabled = enabled;", update)
        self.assertNotIn("cancelBackupButton.Visibility = Visibility.Collapsed", self.window)

    def test_refresh_is_a_top_header_action_and_has_an_f5_shortcut(self) -> None:
        header = self.method("BuildHeader", "BuildIconLabel")
        self.assertIn('refresh.ToolTip = "Refresh now (F5)";', header)
        self.assertIn("refresh.Click += delegate { RefreshDashboard(); };", header)
        self.assertIn('AutomationProperties.SetName(refresh, "Refresh backup dashboard")', header)

        keyboard = self.method("OnDashboardPreviewKeyDown", "ApplyResponsiveLayout")
        self.assertIn("args.Key == Key.F5", keyboard)
        self.assertIn("RefreshDashboard();", keyboard)
        self.assertIn("args.Handled = true;", keyboard)

    def test_appearance_and_preview_live_on_settings_not_in_the_header(self) -> None:
        settings = self.method("BuildSettingsPage", "BuildHeader")
        self.assertIn('title.Text = "Settings";', settings)
        self.assertIn('appearanceTitle.Text = "Appearance";', settings)
        self.assertIn("appearance.Children.Add(BuildThemeSelector());", settings)
        self.assertIn('previewButton = CreateButton(previewEnabled ? "Stop preview" : "Preview animation")', settings)

        header = self.method("BuildHeader", "BuildIconLabel")
        self.assertNotIn("BuildThemeSelector", header)
        self.assertNotIn("previewButton", header)

    def test_repository_path_is_surfaced_from_the_protected_configuration(self) -> None:
        subtitle = self.method("UpdateHeaderSubtitle", "RefreshSources")
        self.assertIn("currentSourceConfiguration.RepositoryPath", subtitle)
        self.assertIn('headerSubtitle.Text = scope + "  \\u2022  " + repository', subtitle)
        self.assertIn("repositoryValue.Text = repository;", subtitle)
        self.assertIn(
            'AutomationProperties.SetName(repositoryValue, "Backup location " + repository);',
            subtitle,
        )

    def test_source_list_has_its_own_scroll_region_in_a_star_sized_row(self) -> None:
        sources = self.method("BuildSources", "BuildSourceRow")
        self.assertIn(
            "new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 120 }",
            sources,
        )
        self.assertIn("ScrollViewer sourceScroller = new ScrollViewer();", sources)
        self.assertIn(
            "sourceScroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;",
            sources,
        )
        self.assertIn("sourceScroller.Content = sourceList;", sources)
        self.assertIn("sourceFrame.Child = sourceScroller;", sources)
        self.assertIn("Grid.SetRow(sourceFrame, 2);", sources)

    def test_history_is_isolated_to_the_activity_page(self) -> None:
        protection = self.method("BuildProtectionPage", "BuildActivityPage")
        activity = self.method("BuildActivityPage", "BuildSettingsPage")
        settings = self.method("BuildSettingsPage", "BuildHeader")
        self.assertIn("UIElement history = BuildHistory();", activity)
        self.assertIn('AutomationProperties.SetName(page, "Backup activity page")', activity)
        self.assertNotIn("BuildHistory", protection)
        self.assertNotIn("BuildHistory", settings)

    def test_verified_badge_remains_visible_after_a_successful_snapshot(self) -> None:
        snapshot = self.method("ApplySnapshot", "ApplyPreview")
        verified_branch = re.search(
            r"else if \(snapshot\.IsSuccess\)\s*\{(?P<body>\s*SetBadge\(\"VERIFIED\"[\s\S]*?)\n\s*\}",
            snapshot,
        )
        self.assertIsNotNone(verified_branch)
        body = verified_branch.group("body")
        self.assertIn('SetBadge("VERIFIED"', body)
        self.assertIn("statusBadge.Visibility = Visibility.Visible;", body)
        self.assertNotIn("statusBadge.Visibility = Visibility.Collapsed", snapshot)

    def test_metrics_are_reserved_for_an_active_run(self) -> None:
        snapshot = self.method("ApplySnapshot", "ApplyPreview")
        self.assertIn(
            "bool showLiveProgress = snapshot.IsActive || snapshot.IsFailure;",
            snapshot,
        )
        self.assertIn(
            "activeProgressPanel.Visibility = showLiveProgress ? Visibility.Visible : Visibility.Collapsed;",
            snapshot,
        )
        self.assertIn("bool showRunMetrics = snapshot.IsActive;", snapshot)
        for element in ("metricsLayout", "metricsContext"):
            self.assertIn(
                f"{element}.Visibility = showRunMetrics ? Visibility.Visible : Visibility.Collapsed;",
                snapshot,
            )

    def test_disabled_buttons_keep_explanatory_tooltips(self) -> None:
        protection = self.method("BuildProtectionPage", "BuildActivityPage")
        self.assertIn('backupNowButton = CreateButton("Back up now")', protection)
        self.assertIn('cancelBackupButton = CreateButton("Cancel backup")', protection)

        create_button = self.method("CreateButton", "ApplyButtonChrome")
        self.assertIn("ToolTipService.SetShowOnDisabled(button, true);", create_button)
        self.assertIn(
            "backupNowButton.ToolTip = helpText;",
            self.method("UpdateBackupButton", "CancellationBlocksMutations"),
        )
        self.assertIn("cancelBackupButton.ToolTip = helpText;", self.method("UpdateCancelButton", "SetCancellationStatus"))


if __name__ == "__main__":
    unittest.main()
