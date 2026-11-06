from __future__ import annotations

import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
HARNESS = PROJECT / "tests" / "fixtures" / "SessionEndHarness.cs"

WM_CLOSE = 0x0010
WM_QUERYENDSESSION = 0x0011
WM_ENDSESSION = 0x0016
ENDSESSION_LOGOFF = 0x80000000
SMTO_ABORTIFHUNG = 0x0002


def _user32():
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumThreadWindows.argtypes = [wintypes.DWORD, callback, wintypes.LPARAM]
    user32.EnumThreadWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.SendMessageTimeoutW.argtypes = [
        wintypes.HWND,
        wintypes.UINT,
        wintypes.WPARAM,
        wintypes.LPARAM,
        wintypes.UINT,
        wintypes.UINT,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    user32.SendMessageTimeoutW.restype = ctypes.c_ssize_t
    return user32, callback


class SessionEndTests(unittest.TestCase):
    """A sign-out or shutdown that is cancelled must leave Rewindle running, and one that goes ahead must close it.

    The harness is a WPF application wired as the dashboard is (tests/fixtures/SessionEndHarness.cs). The messages
    Windows sends at a sign-out are sent only to the windows of that harness process, never to anything else.
    """

    @classmethod
    def setUpClass(cls) -> None:
        if os.name != "nt":
            raise unittest.SkipTest("The session-end guard is Windows-only.")
        framework = (
            Path(os.environ.get("SystemRoot", r"C:\Windows"))
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest("The .NET Framework C# compiler is unavailable.")
        cls.temp_directory = tempfile.TemporaryDirectory(prefix="session-end-")
        cls.executable = Path(cls.temp_directory.name) / "SessionEndHarness.exe"
        references = [
            framework / "System.dll",
            framework / "WPF" / "WindowsBase.dll",
            framework / "WPF" / "PresentationCore.dll",
            framework / "WPF" / "PresentationFramework.dll",
            Path(os.environ.get("WINDIR", r"C:\Windows"))
            / "Microsoft.NET"
            / "assembly"
            / "GAC_MSIL"
            / "System.Xaml"
            / "v4.0_4.0.0.0__b77a5c561934e089"
            / "System.Xaml.dll",
        ]
        completed = subprocess.run(
            [
                str(compiler),
                "/nologo",
                "/target:winexe",
                "/platform:x64",
                "/warn:4",
                f"/out:{cls.executable}",
                *[f"/reference:{path}" for path in references],
                str(DASHBOARD / "SessionEndGuard.cs"),
                str(HARNESS),
            ],
            cwd=PROJECT,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                "session-end harness failed to compile:\n" + completed.stdout + completed.stderr
            )

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    def setUp(self) -> None:
        self.user32, self.callback = _user32()
        self.log_path = Path(self.temp_directory.name) / f"session-{self._testMethodName}.log"
        self.process = subprocess.Popen([str(self.executable), str(self.log_path)])
        self.addCleanup(self._stop)
        deadline = time.monotonic() + 30
        ready = None
        while time.monotonic() < deadline and ready is None:
            ready = re.search(r"^ready thread=(\d+) window=(\d+) guard=(\w+)$", self.log(), re.MULTILINE)
            if ready is None:
                if self.process.poll() is not None:
                    self.fail("the harness ended before its window was ready:\n" + self.log())
                time.sleep(0.05)
        if ready is None:
            self.fail("the harness window did not open:\n" + self.log())
        self.thread_id = int(ready.group(1))
        self.main_window = int(ready.group(2))
        self.guard_installed = ready.group(3) == "yes"

    def _stop(self) -> None:
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=10)

    def log(self) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return ""

    def harness_windows(self) -> list[int]:
        # The top-level windows of the harness's UI thread, as Windows reaches them at a sign-out. Each is checked to belong
        # to the harness process before anything is sent to it.
        found: list[int] = []

        def collect(window: int, _: int) -> bool:
            owner = wintypes.DWORD()
            self.user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
            if owner.value == self.process.pid:
                found.append(window)
            return True

        self.user32.EnumThreadWindows(self.thread_id, self.callback(collect), 0)
        self.assertIn(self.main_window, found)
        return found

    def send(self, window: int, message: int, wparam: int, lparam: int) -> int | None:
        # None when the window is gone (the harness may be closing); nothing is ever sent to another process's window.
        owner = wintypes.DWORD()
        self.user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
        if owner.value != self.process.pid:
            return None
        answer = ctypes.c_size_t(0)
        sent = self.user32.SendMessageTimeoutW(
            window, message, wparam, lparam, SMTO_ABORTIFHUNG, 5000, ctypes.byref(answer)
        )
        if sent == 0:
            if self.process.poll() is not None:
                return None
            self.fail(f"message {message:#x} was not delivered (error {ctypes.get_last_error()})")
        return answer.value

    def broadcast(self, message: int, wparam: int, lparam: int) -> list[int]:
        answers = [self.send(window, message, wparam, lparam) for window in self.harness_windows()]
        return [answer for answer in answers if answer is not None]

    def still_running_after(self, seconds: float) -> bool:
        try:
            self.process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            return True
        return False

    def test_a_cancelled_sign_out_leaves_the_app_running_and_hiding_to_the_tray(self) -> None:
        answers = self.broadcast(WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF)
        # Every window says the session may end: Rewindle never holds a sign-out up.
        self.assertTrue(answers and all(answer != 0 for answer in answers), answers)
        self.assertTrue(
            self.still_running_after(1.5),
            "the app quit as soon as Windows asked whether the session may end:\n" + self.log(),
        )
        self.assertTrue(self.guard_installed, "the session-end guard could not be installed:\n" + self.log())
        self.assertNotIn("wpf-session-ending", self.log())
        self.assertNotIn("closing", self.log())

        self.broadcast(WM_ENDSESSION, 0, ENDSESSION_LOGOFF)
        self.assertTrue(self.still_running_after(0.5), "the app quit after the sign-out was cancelled:\n" + self.log())
        self.assertIn("session-end-cancelled", self.log())

        # The window's X still hides it to the tray afterwards.
        self.assertIsNotNone(self.send(self.main_window, WM_CLOSE, 0, 0))
        self.assertTrue(self.still_running_after(0.5), "closing the window quit the app:\n" + self.log())
        self.assertIn("hidden", self.log())
        self.assertNotIn("closed", self.log())

    def test_a_sign_out_that_goes_ahead_closes_the_app_before_windows_moves_on(self) -> None:
        self.assertTrue(self.guard_installed, "the session-end guard could not be installed:\n" + self.log())
        self.broadcast(WM_QUERYENDSESSION, 0, ENDSESSION_LOGOFF)
        self.broadcast(WM_ENDSESSION, 1, ENDSESSION_LOGOFF)
        # Windows may end the process as soon as WM_ENDSESSION returns, so the window has already closed by then.
        lines = self.log().splitlines()
        self.assertIn("session-ended", lines)
        self.assertIn("closed", lines)
        self.assertLess(lines.index("session-ended"), lines.index("closed"))
        self.assertFalse(self.still_running_after(10), "the app did not end with the session:\n" + self.log())
        self.assertEqual(self.process.returncode, 0)
        self.assertIn("run-returned", self.log())


class SessionEndWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.guard = (DASHBOARD / "SessionEndGuard.cs").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")

    def test_the_dashboard_installs_the_guard_and_never_holds_a_sign_out_up(self) -> None:
        self.assertIn("(Join-Path $project 'SessionEndGuard.cs')", self.build)
        self.assertIn("SourceInitialized += delegate { InstallSessionEndGuard(); };", self.window)
        self.assertIn("SessionEndGuard.TryInstall(", self.window)
        ended = self.window.index("private void OnSessionEnded()")
        self.assertIn("allowClose = true;", self.window[ended : ended + 400])
        self.assertIn("Close();", self.window[ended : ended + 400])
        cancelled = self.window.index("private void OnSessionEndCancelled()")
        self.assertIn("allowClose = false;", self.window[cancelled : cancelled + 200])
        # Neither the guard nor the window ever refuses a sign-out.
        self.assertIn("return new IntPtr(1);", self.guard)
        self.assertNotIn("Cancel = true", self.guard)
        self.assertNotIn("SessionEndingCancelEventArgs", self.window)
        self.assertNotIn("leaves allowClose set (see the SessionEnding handler)", self.window)


if __name__ == "__main__":
    unittest.main()
