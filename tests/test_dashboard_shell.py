"""Source checks for the dashboard shell: the sidebar, the toolbar, the footer and the Settings page say what they should, once."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def function_source(source: str, name: str) -> str:
    """The text of one top-level function in App.tsx, up to the next top-level declaration."""
    start = source.index(f"function {name}(")
    following = re.search(r"\n(?:function |export default function |const [A-Z_]+[:=]|// What )", source[start + 10:])
    return source[start:start + 10 + following.start()] if following else source[start:]


class ShellTests(unittest.TestCase):
    def setUp(self) -> None:
        self.app = read(WEB / "src" / "App.tsx")
        self.sidebar = read(WEB / "components" / "primitives" / "SidebarNav.tsx")
        self.css = read(WEB / "styles" / "app.css")

    def test_sidebar_has_no_recent_backups_block(self) -> None:
        # Activity is a page of its own: the sidebar is the four pages and nothing that repeats them.
        shell = self.app[self.app.index("<SidebarNav"):]
        shell = shell[:shell.index("/>")]
        for gone in ("recents", "onViewAll", "onPick", "Recent backups", "View all activity"):
            self.assertNotIn(gone, shell)
        self.assertIn("recents = []", self.sidebar)
        self.assertIn("recents.length === 0 && !onViewAll", self.sidebar)

    def test_settings_sits_in_the_sidebar_like_a_page(self) -> None:
        self.assertIn('<nav aria-label="Secondary"', self.sidebar)
        self.assertNotIn("justify-center gap-1.5", self.sidebar)
        self.assertIn("footerIcon={<Settings size={18} />}", self.app)

    def test_sidebar_starts_folded_only_in_a_small_window(self) -> None:
        self.assertIn('COMPACT_QUERY = "(max-width: 900px)"', self.sidebar)
        for label in ("Collapse sidebar", "Expand sidebar"):
            self.assertIn(f'title="{label}"', self.sidebar)

    def test_toolbar_has_no_connection_light_and_steps_the_theme(self) -> None:
        self.assertNotIn("App connected", self.app)
        self.assertNotIn("App reconnecting", self.app)
        self.assertNotIn(".connection {", self.css)
        order = [self.app.index(f"name: '{name}'") for name in ("System", "Daylight", "Midnight")]
        self.assertEqual(sorted(order), order, "the themes step System, Light, Dark")
        self.assertIn("THEME_STEPS[(themeIndex + 1) % THEME_STEPS.length]", self.app)
        self.assertIn("send('setTheme', { theme: themeNext.name })", self.app)
        self.assertRegex(self.css, r"\.topbar \{ height: 44px; min-height: 44px;")

    def test_footer_says_what_is_true_everywhere(self) -> None:
        self.assertIn("Your backups are encrypted", self.app)
        self.assertNotIn("encrypted local backup", self.app)
        self.assertNotIn("Ctrl/Cmd", self.app)

    def test_settings_sections_and_names(self) -> None:
        settings = function_source(self.app, "SettingsPage")
        headings = re.findall(r'<h2 className="section-title">([^<]+)</h2>', settings)
        self.assertEqual(["Backup plan", "Appearance", "Help and about"], headings)
        # The backup health cards are on Protection; Settings does not repeat them.
        self.assertNotIn("ProtectionHealth", settings)
        for text in ("Problem report", "Save problem report", "Text size", "Animations"):
            self.assertIn(text, settings)
        for choice in ("Follow Windows", "Always on", "Reduced"):
            self.assertIn(choice, self.app)
        # Three buttons, and the sample data is the only place that can start the animation preview.
        for zoom in ("out", "reset", "in"):
            self.assertIn(f"send('setZoom', {{ zoom: '{zoom}' }})", settings)
        self.assertIn("state.demo && <Action", settings)
        self.assertIn("Closing this window never stops a running backup.", settings)

    def test_about_lists_the_keyboard(self) -> None:
        about = function_source(self.app, "AboutSection")
        self.assertIn("Keyboard shortcuts", about)
        for key in ("Ctrl+1", "Ctrl+4", "F5", "Ctrl+0", "Esc"):
            self.assertIn(f"<kbd>{key}</kbd>", self.app)

    def test_failure_messages_are_in_plain_words(self) -> None:
        for gone in ("Connection interrupted", "Reload dashboard", "stopped drawing, so it was cleared", "Engine not installed", "Check again"):
            self.assertNotIn(gone, self.app)
        hook = read(WEB / "src" / "useDashboard.ts")
        self.assertNotIn("The dashboard has lost its connection", hook)
        self.assertIn("Rewindle has stopped updating", self.app)

    def test_host_keeps_the_text_size_and_writes_the_time_to_the_minute(self) -> None:
        host = read(DASHBOARD / "DashboardWindow.Web.cs")
        self.assertIn('FileName = "zoom.json"', host)
        self.assertIn("RestoreWebZoom();", host)
        self.assertIn("ZoomFactorChanged += OnWebPresentationZoomFactorChanged", host)
        self.assertIn("DashboardZoomStore.TrySave(next)", host)
        self.assertNotIn("It is not saved: Rewindle starts at 100%", host)
        window = read(DASHBOARD / "DashboardWindow.cs")
        self.assertIn('"Updated " + snapshot.LastUpdatedLocal.ToString("HH:mm", CultureInfo.CurrentCulture)', window)
        self.assertIn('"Backup started", "Rewindle is backing up your files."', window)
        self.assertIn('state["updatedAt"]', host)
        for raw in ('"Run details could not be opened. " + exception.Message', '"The licenses folder could not be opened. " + exception.Message'):
            self.assertNotIn(raw, host)

    def test_placeholders_are_readable(self) -> None:
        self.assertIn("::placeholder { color: var(--ink-3); opacity: 1; }", self.css)


if __name__ == "__main__":
    unittest.main()
