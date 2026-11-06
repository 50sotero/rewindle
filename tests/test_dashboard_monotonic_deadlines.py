from __future__ import annotations

from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WINDOW_SOURCES = ("DashboardWindow.cs", "DashboardWindow.Web.cs")

# The window's timers: when the schedule is read again, when the backup drive and the protected folders are checked
# again, when each notice lapses, the wait after Back up now, the web page's heartbeat and its not-responding and reload
# allowances. Each is a Stopwatch value, so setting the clock back cannot hold any of them in the future.
MONOTONIC_FIELDS = (
    "nextScheduleRefreshAt",
    "repositoryVolumeNextProbeAt",
    "webSourceExistenceNextProbeAt",
    "backupRequestPendingUntil",
    "sourceOperationExpiresAt",
    "sourceNoticeExpiresAt",
    "scheduleNoticeExpiresAt",
    "cancellationNoticeExpiresAt",
    "webPresentationNextHeartbeatAt",
    "webPresentationUnresponsiveSince",
    "webPresentationUnresponsiveLast",
    "webPresentationUnresponsiveNoticeAt",
)
WALL_CLOCK_NAMES = (
    "nextScheduleRefreshUtc",
    "repositoryVolumeCheckedUtc",
    "webSourceExistenceCheckedUtc",
    "backupRequestPendingUntilUtc",
    "sourceOperationExpiresUtc",
    "sourceNoticeExpiresUtc",
    "scheduleNoticeExpiresUtc",
    "cancellationNoticeExpiresUtc",
    "webPresentationLastPostUtc",
    "webPresentationUnresponsiveSinceUtc",
    "webPresentationUnresponsiveLastUtc",
    "webPresentationUnresponsiveNoticeUtc",
    "webPresentationRecoveryUtc",
)


class DashboardMonotonicDeadlineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sources = {
            name: (DASHBOARD / name).read_text(encoding="utf-8") for name in WINDOW_SOURCES
        }
        cls.window = cls.sources["DashboardWindow.cs"]
        cls.combined = "\n".join(cls.sources.values())

    def test_timers_are_stopwatch_values(self) -> None:
        for field in MONOTONIC_FIELDS:
            self.assertRegex(self.combined, rf"\n        private long {field};\n", field)
        self.assertIn("private readonly List<long> webPresentationRecoveryStarts", self.combined)
        for name in WALL_CLOCK_NAMES:
            self.assertNotIn(name, self.combined)

    def test_the_clock_is_the_stopwatch(self) -> None:
        now = self.window.index("private static long MonotonicNow()")
        self.assertIn("return Stopwatch.GetTimestamp();", self.window[now : now + 120])
        self.assertIn("private const long MonotonicNever = long.MaxValue;", self.window)
        reached = self.window.index("private static bool MonotonicReached(long deadline)")
        self.assertIn("return MonotonicNow() >= deadline;", self.window[reached : reached + 120])
        # Environment.TickCount wraps after 24.9 days, so it is no substitute.
        for path in DASHBOARD.glob("*.cs"):
            self.assertNotIn("Environment.TickCount", path.read_text(encoding="utf-8"), path.name)

    def test_no_wall_clock_deadline_is_compared(self) -> None:
        for name, source in self.sources.items():
            self.assertIsNone(
                re.search(r"DateTime\.UtcNow\s*(<|<=|>|>=)|(<|<=|>|>=)\s*DateTime\.UtcNow", source),
                name,
            )
            self.assertIsNone(re.search(r"DateTime\.UtcNow\.Add(Seconds|Milliseconds|Minutes)\(", source), name)
            for subtracted in re.findall(r"DateTime\.UtcNow\s*-\s*([A-Za-z_.]+)", source):
                # Only a backup time may be subtracted from the wall clock: that is an age shown to the person.
                self.assertEqual(subtracted, "snapshot.LastVerifiedFinishedUtc.Value", name)

    def test_every_protected_action_asks_the_same_pending_check(self) -> None:
        pending = self.window.index("private bool BackupRequestPending()")
        self.assertIn(
            "return backupRequestPendingUntil != 0 && !MonotonicReached(backupRequestPendingUntil);",
            self.window[pending : pending + 200],
        )
        self.assertGreaterEqual(self.window.count("BackupRequestPending()"), 12)
        self.assertIn(
            "backupRequestPendingUntil = MonotonicAfter(TimeSpan.FromSeconds(45));", self.window
        )
        due = self.window.index("private bool ScheduleRefreshDue(bool force)")
        self.assertIn(
            "return force || MonotonicReached(nextScheduleRefreshAt);", self.window[due : due + 200]
        )
        self.assertIn("if (!ScheduleRefreshDue(force))", self.window)


if __name__ == "__main__":
    unittest.main()
