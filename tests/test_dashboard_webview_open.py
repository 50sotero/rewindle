"""Source checks for how the dashboard starts its WebView2 page: it is drawn without the graphics card, so opening the window
after it has been hidden in the tray does not freeze the screen while a hardware-drawn page wakes up."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WEB_HOST = PROJECT / "src" / "dashboard" / "DashboardWindow.Web.cs"


class WebViewStartTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = WEB_HOST.read_text(encoding="utf-8")
        start = self.source.index("CoreWebView2EnvironmentOptions environmentOptions")
        self.creation = self.source[start:self.source.index("EnsureCoreWebView2Async(environment)", start)]

    def test_page_is_drawn_without_the_graphics_card(self) -> None:
        match = re.search(r'const string WebPresentationBrowserArguments = "([^"]*)";', self.source)
        self.assertIsNotNone(match, "the browser arguments are one named constant")
        arguments = match.group(1).split()
        self.assertIn("--disable-gpu", arguments)
        self.assertIn("--disable-gpu-compositing", arguments)

    def test_every_environment_carries_the_arguments(self) -> None:
        # Options are created whatever the language is, so a PC with no culture name still gets the arguments.
        self.assertIn("= new CoreWebView2EnvironmentOptions();", self.creation)
        self.assertNotIn("? null", self.creation)
        self.assertIn("environmentOptions.AdditionalBrowserArguments = WebPresentationBrowserArguments;", self.creation)
        self.assertRegex(self.creation, r"CoreWebView2Environment\.CreateAsync\(null, userDataFolder, environmentOptions\)")
        # The language is still passed when there is one.
        self.assertIn("environmentOptions.Language = webLanguage;", self.creation)

    def test_only_one_environment_is_created(self) -> None:
        self.assertEqual(1, self.source.count("CoreWebView2Environment.CreateAsync("))


if __name__ == "__main__":
    unittest.main()
