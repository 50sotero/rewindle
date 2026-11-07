"""Backup drive space: the host's evaluator, the page's words for it, and how the two are wired together."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"
TONE = WEB / "src" / "protectionTone.ts"
GIB = 1024**3
LONG_MAX = 2**63 - 1

# Words a home user should never have to read on these lines (rule 8 of the dashboard's wording).
TECHNICAL = re.compile(r"repositor|snapshot|engine|canary|restic|volume", re.IGNORECASE)
# A sentence that asks the person to make room: free up or free some space, make room or space, clear space, or delete or remove
# files or data.
FREES_SPACE = re.compile(
    r"\bfree (up|some)\b"
    r"|\bmake (some |more )?(room|space)\b"
    r"|\bclear(ing)? (up |out )?(some |more )?(disk |drive )?space\b"
    r"|\b(delete|deleting|remove|removing|erase|erasing) (some |other |old |unneeded |unused |large |big |a few )?(files|data)\b",
    re.IGNORECASE,
)
# What such a sentence must also say: never anything inside the backup folder (the page's NEVER_INSIDE).
NEVER_INSIDE = re.compile(r"never[^.]*inside the (backup|repository) folder|NEVER_INSIDE", re.IGNORECASE)


def surface_blocks(text: str, *, markdown: bool) -> list[tuple[int, str]]:
    """What the scan reads as one unit, with its first line number: each line of a source file, and each paragraph, list item,
    heading or table row of a Markdown file, whose sentences wrap over several lines."""
    lines = text.splitlines()
    if not markdown:
        return list(enumerate(lines, 1))
    blocks: list[tuple[int, str]] = []
    current: list[str] = []
    first = 0
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        standalone = stripped.startswith(("#", "|"))
        if current and (not stripped or standalone or re.match(r"(?:[-*+]|\d+\.)\s", stripped)):
            blocks.append((first, " ".join(current)))
            current = []
        if not stripped:
            continue
        if standalone:
            blocks.append((number, stripped))
            continue
        if not current:
            first = number
        current.append(stripped)
    if current:
        blocks.append((first, " ".join(current)))
    return blocks


def asks_to_free_space_without_the_clause(blocks: list[tuple[int, str]]) -> list[tuple[int, str]]:
    return [(number, text) for number, text in blocks if FREES_SPACE.search(text) and not NEVER_INSIDE.search(text)]


HARNESS_SOURCE = r"""
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal static class BackupSpaceHarness
    {
        private static readonly DateTime Origin = new DateTime(2026, 1, 1, 2, 0, 0, DateTimeKind.Utc);

        private static long Long(IDictionary<string, object> source, string key, long fallback)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) && value != null
                ? Convert.ToInt64(value, CultureInfo.InvariantCulture)
                : fallback;
        }

        private static bool Flag(IDictionary<string, object> source, string key, bool fallback)
        {
            object value;
            return source != null && source.TryGetValue(key, out value) && value is bool ? (bool)value : fallback;
        }

        private static int Main(string[] args)
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;
            object[] cases = (object[])serializer.DeserializeObject(File.ReadAllText(args[0]));
            Dictionary<string, object> report = new Dictionary<string, object>();
            foreach (object item in cases)
            {
                IDictionary<string, object> spec = (IDictionary<string, object>)item;
                object factsValue;
                IDictionary<string, object> given = spec.TryGetValue("facts", out factsValue)
                    ? (IDictionary<string, object>)factsValue
                    : new Dictionary<string, object>();
                BackupSpaceFacts facts = new BackupSpaceFacts();
                facts.FreeBytes = Long(given, "free", -1);
                facts.TotalBytes = Long(given, "total", -1);
                facts.ReserveBytes = Long(given, "reserve", -1);
                facts.WarnWeeks = (int)Long(given, "warn", 8);
                facts.HistoryReadable = Flag(given, "historyReadable", true);
                facts.ForecastAvailable = Flag(given, "forecastAvailable", true);
                List<BackupSpaceSample> samples = new List<BackupSpaceSample>();
                object samplesValue;
                if (spec.TryGetValue("samples", out samplesValue))
                {
                    foreach (object raw in (object[])samplesValue)
                    {
                        object[] pair = (object[])raw;
                        samples.Add(new BackupSpaceSample(
                            Origin.AddDays(Convert.ToDouble(pair[0], CultureInfo.InvariantCulture)),
                            Convert.ToInt64(pair[1], CultureInfo.InvariantCulture)));
                    }
                }
                facts.Samples = samples;
                BackupSpaceResult result;
                object judgeValue;
                if (spec.TryGetValue("judge", out judgeValue))
                {
                    IDictionary<string, object> judge = (IDictionary<string, object>)judgeValue;
                    result = BackupSpaceEvaluator.Judge(
                        facts,
                        (BackupSpaceForecastState)Enum.Parse(typeof(BackupSpaceForecastState), (string)judge["state"]),
                        Long(judge, "weekly", -1));
                }
                else
                {
                    result = BackupSpaceEvaluator.Evaluate(facts);
                }
                if (Flag(spec, "hold", false))
                {
                    result = BackupSpaceEvaluator.HoldDuringRun(result, facts);
                }
                if (Flag(spec, "holdNothing", false))
                {
                    result = BackupSpaceEvaluator.HoldDuringRun(null, facts);
                }
                Dictionary<string, object> outcome = new Dictionary<string, object>();
                outcome["level"] = result.Level.ToString();
                outcome["reason"] = result.Reason.ToString();
                outcome["state"] = result.ForecastState.ToString();
                outcome["weeksLeft"] = result.WeeksLeft.HasValue ? (object)result.WeeksLeft.Value : null;
                outcome["weeksRounded"] = result.WeeksRounded.HasValue ? (object)result.WeeksRounded.Value : null;
                outcome["weekly"] = result.WeeklyBytes.ToString(CultureInfo.InvariantCulture);
                report[(string)spec["name"]] = outcome;
            }
            Dictionary<string, object> allowed = new Dictionary<string, object>();
            foreach (int weeks in new[] { 4, 8, 12, 0, 5 })
            {
                allowed[weeks.ToString(CultureInfo.InvariantCulture)] = BackupSpaceEvaluator.IsAllowedWarnWeeks(weeks);
            }
            report["allowed"] = allowed;
            Console.WriteLine(serializer.Serialize(report));
            return 0;
        }
    }
}
"""


def daily(count: int, added, *, first: float = 0.0) -> list[list[float]]:
    """`count` backups a day apart; `added` is a number or a function of the index."""
    return [[first + index, added(index) if callable(added) else added] for index in range(count)]


def away_from_zero(value: float) -> int:
    return int(math.floor(value + 0.5))


EVALUATOR_CASES = [
    {"name": "learning_none"},
    {"name": "learning_one", "samples": daily(1, GIB)},
    {"name": "learning_two", "samples": daily(2, GIB)},
    {"name": "learning_short", "samples": [[0, GIB], [2.5, GIB], [5, GIB]]},
    # One backup 70 days before a week of daily backups: it is outside the 8 weeks, and 6 days are too short.
    {"name": "window", "samples": [[0, GIB]] + daily(7, GIB, first=64)},
    {"name": "flat_zero", "samples": daily(10, 0)},
    # The one backup that added anything is the one left out.
    {"name": "flat_one_off", "samples": daily(10, lambda i: 50 * GIB if i == 5 else 0)},
    # The oldest is the first backup (200 GiB), one adds a 50 GiB folder once, the rest add 1 GiB each.
    {
        "name": "growing",
        "samples": daily(15, lambda i: 200 * GIB if i == 0 else 50 * GIB if i == 7 else GIB),
        "facts": {"free": 500 * GIB, "total": 1000 * GIB, "reserve": 10 * GIB},
    },
    # Photos imported once a week and nothing else changing: a median per backup would be 0 and never warn.
    {"name": "weekly_imports", "samples": daily(56, lambda i: 2 * GIB if (i + 1) % 7 == 0 else 0, first=1)},
    # A newest backup recorded while the PC's clock was months ahead is set aside.
    {"name": "wrong_clock", "samples": daily(10, GIB) + [[200, GIB]]},
    {"name": "full_reserve", "facts": {"free": 5 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}},
    {"name": "full_empty", "facts": {"free": 0, "total": 100 * GIB, "reserve": 0}},
    {"name": "invalid_free", "facts": {"free": -1, "total": 931 * GIB, "reserve": 10 * GIB}, "samples": daily(15, GIB)},
    {"name": "invalid_total", "facts": {"free": 5 * GIB, "total": 0, "reserve": 10 * GIB}},
    {"name": "invalid_more_free", "facts": {"free": 932 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}},
    # Rounding: the host rounds once, to 2 decimals, and judges and sends that value; the words use the same whole number.
    {"name": "round_8_4", "facts": {"free": 84000, "total": 10**12, "reserve": 0}, "judge": {"state": "Growing", "weekly": 10000}},
    {"name": "round_8_5", "facts": {"free": 85000, "total": 10**12, "reserve": 0}, "judge": {"state": "Growing", "weekly": 10000}},
    {"name": "round_8_495", "facts": {"free": 84950, "total": 10**12, "reserve": 0}, "judge": {"state": "Growing", "weekly": 10000}},
    {"name": "round_8_4999", "facts": {"free": 84999, "total": 10**12, "reserve": 0}, "judge": {"state": "Growing", "weekly": 10000}},
    {"name": "percent_learning", "facts": {"free": 60 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}},
    {
        "name": "percent_unreadable",
        "facts": {"free": 60 * GIB, "total": 931 * GIB, "reserve": 10 * GIB, "historyReadable": False},
        "samples": daily(15, GIB),
    },
    {
        "name": "percent_but_growing_slowly",
        "facts": {"free": 60 * GIB, "total": 931 * GIB, "reserve": 10 * GIB},
        "judge": {"state": "Growing", "weekly": 50 * GIB // 40},
    },
    {"name": "percent_but_flat", "facts": {"free": 60 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}, "samples": daily(10, 0)},
    # Check recovery readiness warns below 1.5 times the reserve; the card is never calmer than that.
    {"name": "under_one_and_a_half_reserves", "facts": {"free": 14 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}, "samples": daily(10, 0)},
    {"name": "one_and_a_half_reserves", "facts": {"free": 15 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}, "samples": daily(10, 0)},
    {"name": "plenty", "facts": {"free": 412 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}},
    {
        "name": "unavailable",
        "facts": {"free": 500 * GIB, "total": 1000 * GIB, "reserve": 10 * GIB, "forecastAvailable": False},
        "samples": daily(15, GIB),
    },
    {
        "name": "unavailable_little_room",
        "facts": {"free": 60 * GIB, "total": 931 * GIB, "reserve": 10 * GIB, "forecastAvailable": False},
        "samples": daily(15, GIB),
    },
    {
        "name": "unavailable_under_one_and_a_half_reserves",
        "facts": {"free": 14 * GIB, "total": 931 * GIB, "reserve": 10 * GIB, "forecastAvailable": False},
    },
    {
        "name": "unavailable_too_full",
        "facts": {"free": 5 * GIB, "total": 931 * GIB, "reserve": 10 * GIB, "forecastAvailable": False},
    },
    {"name": "warn_5_is_8", "facts": {"free": 80000, "total": 10**12, "reserve": 0, "warn": 5}, "judge": {"state": "Growing", "weekly": 10000}},
    {"name": "warn_4", "facts": {"free": 80000, "total": 10**12, "reserve": 0, "warn": 4}, "judge": {"state": "Growing", "weekly": 10000}},
    {"name": "warn_12", "facts": {"free": 120000, "total": 10**12, "reserve": 0, "warn": 12}, "judge": {"state": "Growing", "weekly": 10000}},
    {
        "name": "history_unreadable",
        "facts": {"free": 5 * GIB, "total": 931 * GIB, "reserve": 10 * GIB, "historyReadable": False},
        "samples": daily(15, GIB),
    },
    {"name": "cap", "facts": {"free": 10**15, "total": 10**16, "reserve": 0}, "judge": {"state": "Growing", "weekly": 1}},
    {"name": "no_overflow", "facts": {"free": 10**15, "total": 10**16, "reserve": 0}, "samples": daily(10, LONG_MAX // 4)},
    # While a backup runs its own writes can take the free space below the reserve: the card holds what it said before the run,
    # and never repeats a "too full" from before it (a run the service accepted had room).
    {"name": "hold_full", "facts": {"free": 5 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}, "samples": daily(15, GIB), "hold": True},
    {"name": "hold_low", "facts": {"free": 20 * GIB, "total": 931 * GIB, "reserve": 10 * GIB}, "samples": daily(15, GIB), "hold": True},
    {"name": "hold_nothing", "holdNothing": True},
    # The dashboard started during a run with the earlier personal edition: still no forecast, so no warning choice to offer.
    {"name": "hold_nothing_unavailable", "facts": {"forecastAvailable": False}, "holdNothing": True},
    {
        "name": "hold_unavailable_low",
        "facts": {"free": 14 * GIB, "total": 931 * GIB, "reserve": 10 * GIB, "forecastAvailable": False},
        "hold": True,
    },
]


class BackupSpaceEvaluatorTests(unittest.TestCase):
    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        framework = (
            Path(os.environ.get("SystemRoot", r"C:\Windows")) / "Microsoft.NET" / "Framework64" / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest("The .NET Framework C# compiler is unavailable.")
        cls.temp_directory = tempfile.TemporaryDirectory(prefix="backup-space-")
        temp = Path(cls.temp_directory.name)
        harness = temp / "BackupSpaceHarness.cs"
        executable = temp / "BackupSpaceHarness.exe"
        cases = temp / "cases.json"
        harness.write_text(textwrap.dedent(HARNESS_SOURCE), encoding="utf-8", newline="\n")
        cases.write_text(json.dumps(EVALUATOR_CASES), encoding="utf-8", newline="\n")
        compiled = subprocess.run(
            [
                str(compiler), "/nologo", "/target:exe", "/warn:4", "/warnaserror+", f"/out:{executable}",
                f"/reference:{framework / 'System.dll'}",
                f"/reference:{framework / 'System.Core.dll'}",
                f"/reference:{framework / 'System.Web.Extensions.dll'}",
                str(DASHBOARD / "BackupSpace.cs"),
                str(harness),
            ],
            capture_output=True, text=True, check=False, timeout=120,
        )
        if compiled.returncode != 0:
            raise AssertionError("backup space harness compilation failed:\n" + compiled.stdout + compiled.stderr)
        ran = subprocess.run([str(executable), str(cases)], capture_output=True, text=True, check=False, timeout=60)
        if ran.returncode != 0:
            raise AssertionError("backup space harness failed:\n" + ran.stdout + ran.stderr)
        cls.report = json.loads(ran.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    def case(self, name: str) -> dict:
        return self.report[name]

    def test_too_few_backups_or_too_short_a_time_is_still_learning(self) -> None:
        for name in ("learning_none", "learning_one", "learning_two", "learning_short", "window"):
            with self.subTest(name=name):
                self.assertEqual("Learning", self.case(name)["state"])
                self.assertEqual("-1", self.case(name)["weekly"])
                self.assertIsNone(self.case(name)["weeksLeft"])

    def test_backups_that_add_nothing_are_flat(self) -> None:
        for name in ("flat_zero", "flat_one_off"):
            with self.subTest(name=name):
                self.assertEqual("Flat", self.case(name)["state"])
                self.assertEqual("0", self.case(name)["weekly"])

    def test_the_biggest_backup_is_left_out_of_the_weekly_growth(self) -> None:
        growing = self.case("growing")
        self.assertEqual("Growing", growing["state"])
        self.assertEqual(str(7 * GIB), growing["weekly"])
        self.assertEqual(70.0, growing["weeksLeft"])
        self.assertEqual("Ok", growing["level"])

    def test_weekly_imports_still_count(self) -> None:
        imports = self.case("weekly_imports")
        self.assertEqual("Growing", imports["state"])
        self.assertEqual(str(away_from_zero(14 * GIB / 54 * (55 / 55 * 7))), imports["weekly"])

    def test_one_backup_with_a_wrong_clock_does_not_blind_the_forecast(self) -> None:
        clock = self.case("wrong_clock")
        self.assertEqual("Growing", clock["state"])
        self.assertEqual(str(7 * GIB), clock["weekly"])

    def test_too_little_space_for_the_next_backup_is_full(self) -> None:
        for name in ("full_reserve", "full_empty", "unavailable_too_full", "history_unreadable"):
            with self.subTest(name=name):
                self.assertEqual(("Full", "Reserve"), (self.case(name)["level"], self.case(name)["reason"]))

    def test_a_reading_that_makes_no_sense_is_unknown(self) -> None:
        for name in ("invalid_free", "invalid_total", "invalid_more_free"):
            with self.subTest(name=name):
                self.assertEqual(("Unknown", "None"), (self.case(name)["level"], self.case(name)["reason"]))
                self.assertIsNone(self.case(name)["weeksLeft"])
        # The forecast itself does not need the free space.
        self.assertEqual("Growing", self.case("invalid_free")["state"])

    def test_the_level_is_judged_on_the_whole_weeks_the_words_use(self) -> None:
        self.assertEqual(("Low", "Forecast", 8.4, 8), self.summary("round_8_4"))
        self.assertEqual(("Ok", "None", 8.5, 9), self.summary("round_8_5"))
        # Rounded once to 2 decimals (8.5), then to whole weeks (9): not amber at 8, and the page says "about 9 weeks".
        self.assertEqual(("Ok", "None", 8.5, 9), self.summary("round_8_4999"))
        borderline = self.case("round_8_495")
        self.assertEqual(away_from_zero(borderline["weeksLeft"]), borderline["weeksRounded"])
        self.assertEqual("Low" if borderline["weeksRounded"] <= 8 else "Ok", borderline["level"])

    def summary(self, name: str) -> tuple:
        case = self.case(name)
        return case["level"], case["reason"], case["weeksLeft"], case["weeksRounded"]

    def test_little_room_with_no_forecast_is_low(self) -> None:
        self.assertEqual(("Low", "Percent"), self.level("percent_learning"))
        self.assertEqual(("Low", "Percent"), self.level("percent_unreadable"))
        # A forecast that is far off wins; backups that do not grow are no reason either.
        self.assertEqual(("Ok", "None"), self.level("percent_but_growing_slowly"))
        self.assertEqual(40.0, self.case("percent_but_growing_slowly")["weeksLeft"])
        self.assertEqual(("Ok", "None"), self.level("percent_but_flat"))
        self.assertEqual(("Ok", "None"), self.level("plenty"))

    def test_the_card_is_never_calmer_than_check_recovery_readiness(self) -> None:
        self.assertEqual(("Low", "Percent"), self.level("under_one_and_a_half_reserves"))
        self.assertEqual(("Ok", "None"), self.level("one_and_a_half_reserves"))

    def level(self, name: str) -> tuple:
        return self.case(name)["level"], self.case(name)["reason"]

    def test_without_a_forecast_from_the_backup_service_the_live_figures_still_count(self) -> None:
        self.assertEqual("Unavailable", self.case("unavailable")["state"])
        self.assertEqual("-1", self.case("unavailable")["weekly"])
        self.assertEqual(("Ok", "None"), self.level("unavailable"))
        # Only the reserve rules: less than a tenth of the drive free would be amber for good there, with no warning choice to tune
        # it, so it is not a reason. Below 1.5 times the reserve (Check recovery readiness warns too) and too full still are.
        self.assertEqual(("Ok", "None"), self.level("unavailable_little_room"))
        self.assertEqual(("Low", "Percent"), self.level("unavailable_under_one_and_a_half_reserves"))
        self.assertEqual(("Full", "Reserve"), self.level("unavailable_too_full"))

    def test_the_warning_is_4_8_or_12_weeks(self) -> None:
        self.assertEqual(("Low", "Forecast"), self.level("warn_5_is_8"))
        self.assertEqual(("Ok", "None"), self.level("warn_4"))
        self.assertEqual(("Low", "Forecast"), self.level("warn_12"))
        self.assertEqual({"4": True, "8": True, "12": True, "0": False, "5": False}, self.report["allowed"])

    def test_an_unreadable_history_has_no_forecast(self) -> None:
        self.assertEqual("Unknown", self.case("history_unreadable")["state"])

    def test_weeks_left_is_capped_and_large_numbers_do_not_overflow(self) -> None:
        self.assertEqual(10000.0, self.case("cap")["weeksLeft"])
        big = self.case("no_overflow")
        self.assertEqual("Growing", big["state"])
        self.assertGreater(int(big["weekly"]), 0)

    def test_a_running_backup_keeps_what_the_card_said_before_it(self) -> None:
        self.assertEqual(("Unknown", "None"), self.level("hold_full"))
        self.assertEqual("Growing", self.case("hold_full")["state"])
        self.assertEqual(("Low", "Forecast"), self.level("hold_low"))
        self.assertEqual(("Unknown", "None", "Unknown"), (*self.level("hold_nothing"), self.case("hold_nothing")["state"]))
        # With the earlier personal edition there is still no forecast, so Settings offers no Low space warning during the run.
        self.assertEqual(
            ("Unknown", "None", "Unavailable"), (*self.level("hold_nothing_unavailable"), self.case("hold_nothing_unavailable")["state"])
        )
        self.assertEqual(("Low", "Percent", "Unavailable"), (*self.level("hold_unavailable_low"), self.case("hold_unavailable_low")["state"]))


def space(
    *,
    level: str = "ok",
    reason: str = "",
    kind: str = "drive",
    drive: str = "D:",
    reading: str = "ready",
    state: str = "growing",
    weeks: float | None = 57.33,
    rounded: int | None = 57,
    backups: int = 212 * GIB,
    backups_display: str = "212 GiB",
    estimated: bool = False,
    reserve: int = 10 * GIB,
    reserve_display: str = "10.0 GiB",
    free_display: str = "96.0 GiB",
    stopped: bool = False,
) -> dict:
    return {
        "kind": kind, "reading": reading, "drive": drive,
        "freeBytes": 96 * GIB if reading == "ready" else -1, "freeDisplay": free_display if reading == "ready" else "",
        "totalBytes": 931 * GIB if reading == "ready" else -1, "totalDisplay": "931 GiB" if reading == "ready" else "",
        "backupsBytes": backups, "backupsDisplay": backups_display if backups >= 0 else "", "backupsEstimated": estimated,
        "reserveBytes": reserve, "reserveDisplay": reserve_display if reserve > 0 else "",
        "forecast": {
            "state": state, "weeksLeft": weeks if state == "growing" else None, "weeksRounded": rounded if state == "growing" else None,
            "weeklyBytes": GIB + GIB // 2 if state == "growing" else 0 if state == "flat" else -1,
            "weeklyDisplay": "1.50 GiB" if state == "growing" else "0 B" if state == "flat" else "",
        },
        "level": level, "reason": reason, "warnWeeks": 8, "runStoppedForSpace": stopped,
    }


def repository(space_state: dict | None, *, ready: bool | None = True, path: str = "D:\\Backups\\Rewindle") -> dict:
    result = {"path": path, "volume": "D:\\  •  Local disk  •  96.0 GiB free"}
    if ready is not None:
        result["volumeReady"] = ready
    if space_state is not None:
        result["space"] = space_state
    return result


CARDS = {
    "local_growing": repository(space()),
    "local_far": repository(space(weeks=130.0, rounded=130)),
    "local_flat": repository(space(state="flat")),
    "local_learning": repository(space(state="learning")),
    "local_unknown_forecast": repository(space(state="unknown")),
    "local_low_forecast": repository(space(level="low", reason="forecast", weeks=6.0, rounded=6, free_display="22.0 GiB")),
    "local_low_percent": repository(space(level="low", reason="percent", state="learning", free_display="60.0 GiB")),
    "local_full": repository(space(level="full", reason="reserve", weeks=0.0, rounded=0, free_display="6.20 GiB")),
    "local_full_no_reserve": repository(space(level="full", reason="reserve", reserve=-1, free_display="0 B")),
    "local_no_backups_size": repository(space(backups=-1)),
    "local_estimated": repository(space(estimated=True)),
    "local_checking": repository(space(reading="checking", level="unknown", state="unknown", backups=-1)),
    "local_unreadable": repository(space(reading="unknown", level="unknown")),
    "local_unplugged": repository(space(reading="unknown", level="unknown"), ready=False),
    "local_no_letter": repository(space(level="low", reason="percent", state="learning", drive=""), path="\\\\nas\\backups"),
    "local_held_during_run": repository(space(level="unknown", state="growing")),
    "legacy_local": repository(space(state="unavailable", backups=-1)),
    "legacy_local_low": repository(space(state="unavailable", backups=-1, level="low", reason="percent", free_display="14.0 GiB")),
    "legacy_google": repository(space(kind="googleDrive", drive="G:", state="unavailable", estimated=True), path="G:\\My Drive\\Rewindle"),
    "google_growing": repository(space(kind="googleDrive", drive="G:", weeks=20.0, rounded=20), path="G:\\My Drive\\Rewindle"),
    "google_far": repository(space(kind="googleDrive", drive="G:", weeks=1099.0, rounded=1099), path="G:\\My Drive\\Rewindle"),
    "google_flat": repository(space(kind="googleDrive", drive="G:", state="flat"), path="G:\\My Drive\\Rewindle"),
    "google_learning": repository(space(kind="googleDrive", drive="G:", state="learning"), path="G:\\My Drive\\Rewindle"),
    "google_low_forecast": repository(space(kind="googleDrive", drive="G:", level="low", reason="forecast", weeks=3.0, rounded=3), path="G:\\My Drive\\Rewindle"),
    "google_low_percent": repository(space(kind="googleDrive", drive="G:", level="low", reason="percent", state="learning"), path="G:\\My Drive\\Rewindle"),
    "google_full": repository(space(kind="googleDrive", drive="G:", level="full", reason="reserve", free_display="2.00 GiB"), path="G:\\My Drive\\Rewindle"),
    "google_full_no_reserve": repository(space(kind="googleDrive", drive="G:", level="full", reason="reserve", reserve=-1), path="G:\\My Drive\\Rewindle"),
    "google_checking": repository(space(kind="googleDrive", drive="G:", reading="checking", level="unknown"), path="G:\\My Drive\\Rewindle"),
    "google_unreadable": repository(space(kind="googleDrive", drive="G:", reading="unknown", level="unknown"), path="G:\\My Drive\\Rewindle"),
    "google_not_running": repository(space(kind="googleDrive", drive="G:", reading="unknown", level="unknown"), ready=False, path="G:\\My Drive\\Rewindle"),
    "google_estimated": repository(space(kind="googleDrive", drive="G:", estimated=True), path="G:\\My Drive\\Rewindle"),
    "full_already_stopped": repository(space(level="full", reason="reserve", stopped=True)),
    "older_host": repository(None),
}

WEEKS = [[0.05, None], [0.5, None], [1, None], [4.4, 4], [25.4, 25], [26, None], [57.33, None], [77, None], [78, None], [103, None], [104, None], [8.49, 9]]

PAGE_RUNNER = """
const tone = await import(process.argv[1]);
const { cards, weeks } = JSON.parse(process.argv[2]);
const report = { cards: {}, concerns: {}, words: [] };
for (const [name, repository] of Object.entries(cards)) {
  report.cards[name] = tone.describeSpace(repository);
  report.concerns[name] = tone.spaceConcern(repository);
}
for (const [value, rounded] of weeks) report.words.push(tone.forecastWords(value, rounded));
console.log(JSON.stringify(report));
"""


def run_page(runner: str, *arguments: str) -> dict:
    node = shutil.which("node")
    if not node:
        raise unittest.SkipTest("Node.js is unavailable")
    completed = subprocess.run(
        [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", runner, *arguments],
        capture_output=True, encoding="utf-8", timeout=60, check=False,
    )
    if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
        raise unittest.SkipTest("this Node.js cannot run TypeScript files")
    if completed.returncode != 0:
        raise AssertionError(completed.stderr)
    return json.loads(completed.stdout)


class BackupSpaceWordingTests(unittest.TestCase):
    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        cls.report = run_page(PAGE_RUNNER, TONE.as_uri(), json.dumps({"cards": CARDS, "weeks": WEEKS}))

    def card(self, name: str) -> dict:
        return self.report["cards"][name]

    def test_forecast_words(self) -> None:
        self.assertEqual(
            [
                "about 1 day", "about 4 days", "about 1 week", "about 4 weeks", "about 25 weeks", "about 6 months",
                "about 13 months", "about 18 months", "about 2 years", "about 2 years", "more than 2 years",
                # The host's whole number of weeks is the one the words use.
                "about 9 weeks",
            ],
            self.report["words"],
        )

    def test_a_local_drive(self) -> None:
        growing = self.card("local_growing")
        self.assertEqual("Backups use 212 GiB • 96.0 GiB free of 931 GiB", growing["usage"])
        self.assertEqual(("Full in about 13 months at this rate.", "muted", ""), (growing["status"], growing["tone"], growing["nextStep"]))
        self.assertEqual("Enough space for more than 2 years at this rate.", self.card("local_far")["status"])
        self.assertEqual("Your backups haven’t grown lately, so they aren’t filling the drive.", self.card("local_flat")["status"])
        self.assertEqual("After a few more backups, Rewindle can tell when the drive will be full.", self.card("local_learning")["status"])
        self.assertEqual("", self.card("local_unknown_forecast")["status"])
        self.assertEqual("96.0 GiB free of 931 GiB", self.card("local_no_backups_size")["usage"])
        self.assertEqual("Backups use about 212 GiB • 96.0 GiB free of 931 GiB", self.card("local_estimated")["usage"])

    def test_a_local_drive_running_low_or_too_full_says_what_to_do(self) -> None:
        free_up = (
            "Free up space on D: by removing other files (never anything inside the backup folder), "
            "or choose Change location to move your backups to a bigger drive."
        )
        low = self.card("local_low_forecast")
        self.assertEqual(
            ("Space is running low: the backup drive will be full in about 6 weeks at this rate.", "warning", free_up),
            (low["status"], low["tone"], low["nextStep"]),
        )
        percent = self.card("local_low_percent")
        self.assertEqual(
            ("Space is running low: only 60.0 GiB is free on D:, and backups stop below 10.0 GiB.", "warning", free_up),
            (percent["status"], percent["tone"], percent["nextStep"]),
        )
        full = self.card("local_full")
        self.assertEqual(
            "The backup drive is too full to back up. Rewindle needs at least 10.0 GiB free on D:, and 6.20 GiB is free.", full["status"]
        )
        self.assertEqual("danger", full["tone"])
        self.assertEqual(free_up + " Once there’s room, the next scheduled backup runs, or choose Back up now.", full["nextStep"])
        self.assertEqual("The backup drive is full, so backups can’t run.", self.card("local_full_no_reserve")["status"])
        self.assertIn("Free up space on the backup drive by removing other files", self.card("local_no_letter")["nextStep"])
        self.assertIn("is free on the backup drive, and backups stop below", self.card("local_no_letter")["status"])

    def test_a_drive_that_cannot_be_read_yet_does_not_alarm(self) -> None:
        self.assertEqual(("", "Checking the backup drive…", "muted"), self.lines("local_checking"))
        self.assertEqual(
            ("", "Rewindle can’t read the free space on the backup drive right now. It tries again in a minute.", "muted"),
            self.lines("local_unreadable"),
        )
        self.assertEqual(("The backup drive (D:) isn’t connected.", "danger", "Plug it back in."), self.problem("local_unplugged"))
        held = self.card("local_held_during_run")
        self.assertEqual(("", "muted"), (held["status"], held["tone"]))
        self.assertTrue(held["usage"])

    def lines(self, name: str) -> tuple:
        card = self.card(name)
        return card["usage"], card["status"], card["tone"]

    def problem(self, name: str) -> tuple:
        card = self.card(name)
        return card["status"], card["tone"], card["nextStep"]

    def test_google_storage(self) -> None:
        self.assertEqual("Backups use 212 GiB • Google storage: 96.0 GiB free of 931 GiB", self.card("google_growing")["usage"])
        self.assertEqual("Backups use about 212 GiB • Google storage: 96.0 GiB free of 931 GiB", self.card("google_estimated")["usage"])
        self.assertEqual("Your Google storage will be full in about 20 weeks at this rate.", self.card("google_growing")["status"])
        self.assertEqual("Enough Google storage for more than 2 years at this rate.", self.card("google_far")["status"])
        self.assertEqual("Your backups haven’t grown lately, so they aren’t filling your Google storage.", self.card("google_flat")["status"])
        self.assertEqual("After a few more backups, Rewindle can tell when your Google storage will be full.", self.card("google_learning")["status"])
        free_up = (
            "Free up Google storage by removing other files (never anything inside the backup folder), "
            "get more storage from Google, or choose Change location to move your backups to a drive."
        )
        self.assertEqual(
            ("Space is running low: your Google storage will be full in about 3 weeks at this rate.", "warning", free_up),
            self.problem("google_low_forecast"),
        )
        self.assertEqual(
            ("Space is running low: only 96.0 GiB is free in your Google storage, and backups stop below 10.0 GiB.", "warning", free_up),
            self.problem("google_low_percent"),
        )
        self.assertEqual(
            (
                "Your Google storage is too full to back up. Rewindle needs at least 10.0 GiB of it free, and 2.00 GiB is free.",
                "danger",
                free_up + " Once there’s room, the next scheduled backup runs, or choose Back up now.",
            ),
            self.problem("google_full"),
        )
        self.assertEqual("Your Google storage is full, so backups can’t run.", self.card("google_full_no_reserve")["status"])
        self.assertEqual("Checking your Google storage…", self.card("google_checking")["status"])
        self.assertEqual(
            "Rewindle can’t read your Google storage right now. It tries again in a minute.", self.card("google_unreadable")["status"]
        )
        self.assertEqual(
            ("Google Drive for desktop isn’t running.", "danger", "Start Google Drive for desktop and sign in."),
            self.problem("google_not_running"),
        )

    def test_the_earlier_personal_edition_says_plainly_what_it_cannot_show(self) -> None:
        legacy = self.card("legacy_local")
        # It records no size: the line shows what the dashboard reads itself, and the forecast is said to be unavailable, calmly.
        self.assertEqual("96.0 GiB free of 931 GiB", legacy["usage"])
        self.assertEqual(("With this backup program, Rewindle can’t forecast when the drive will be full.", "muted"), (legacy["status"], legacy["tone"]))
        self.assertEqual("", legacy["how"])
        self.assertEqual(
            "With this backup program, Rewindle can’t forecast when your Google storage will be full.", self.card("legacy_google")["status"]
        )
        # What the dashboard can read itself still counts, with what to do.
        self.assertEqual("warning", self.card("legacy_local_low")["tone"])
        self.assertEqual(
            "Space is running low: only 14.0 GiB is free on D:, and backups stop below 10.0 GiB.", self.card("legacy_local_low")["status"]
        )
        self.assertIn("never anything inside the backup folder", self.card("legacy_local_low")["nextStep"])
        self.assertIsNone(self.report["concerns"]["legacy_local_low"])

    def test_how_it_is_worked_out_is_only_shown_for_a_forecast(self) -> None:
        for name, card in self.report["cards"].items():
            with self.subTest(card=name):
                forecast = CARDS[name].get("space", {}).get("forecast", {}).get("state")
                if card["how"]:
                    self.assertIn(forecast, ("growing", "flat"))
        growing = self.card("local_growing")["how"]
        self.assertIn("leaves out the single biggest one (such as a folder added once)", growing)
        self.assertIn("Lately that is about 1.50 GiB a week.", growing)
        self.assertIn("other files on the drive can fill it sooner", growing)
        self.assertIn("“Full” means less than 10.0 GiB free", growing)
        self.assertIn("Lately they have added almost nothing.", self.card("local_flat")["how"])
        self.assertIn("shared with Gmail and Google Photos", self.card("google_growing")["how"])
        self.assertEqual("", self.card("local_learning")["how"])

    def test_an_older_host_keeps_the_volume_line(self) -> None:
        self.assertEqual(("D:\\  •  Local disk  •  96.0 GiB free", "", "muted"), self.lines("older_host"))
        self.assertIsNone(self.report["concerns"]["older_host"])

    def test_the_hero_says_too_full_and_running_low_but_not_little_room(self) -> None:
        concerns = self.report["concerns"]
        self.assertEqual("danger", concerns["local_full"]["tone"])
        self.assertEqual(
            "The backup drive is too full for the next backup. Free up space on D: by removing other files "
            "(never anything inside the backup folder), or move your backups to a bigger drive (see Backup location below).",
            concerns["local_full"]["text"],
        )
        self.assertEqual(
            "Your Google storage is too full for the next backup. Free some up by removing other files "
            "(never anything inside the backup folder), or get more storage from Google (see Backup location below).",
            concerns["google_full"]["text"],
        )
        self.assertEqual(
            {"tone": "warning", "text": "The backup drive will be full in about 6 weeks at this rate. See Backup location below for what to do."},
            concerns["local_low_forecast"],
        )
        self.assertEqual("Your Google storage will be full in about 3 weeks at this rate. See Backup location below for what to do.", concerns["google_low_forecast"]["text"])
        for name in ("local_low_percent", "google_low_percent", "local_growing", "local_checking", "local_unplugged", "full_already_stopped"):
            with self.subTest(name=name):
                self.assertIsNone(concerns[name])

    def test_every_sentence_that_asks_to_free_space_says_never_to_touch_the_backup_folder(self) -> None:
        texts = [text for card in self.report["cards"].values() for text in card.values()]
        texts += [concern["text"] for concern in self.report["concerns"].values() if concern]
        asked = [text for text in texts if FREES_SPACE.search(text)]
        self.assertGreater(len(asked), 10)
        for text in asked:
            with self.subTest(text=text):
                self.assertIn("never anything inside the backup folder", text)

    def test_no_technical_words(self) -> None:
        for name, card in self.report["cards"].items():
            if name == "older_host":
                continue  # the host's own volume text, shown as before
            for text in card.values():
                with self.subTest(card=name, text=text):
                    self.assertIsNone(TECHNICAL.search(text))
        for concern in self.report["concerns"].values():
            if concern:
                self.assertIsNone(TECHNICAL.search(concern["text"]))


class FreeSpaceAdviceSurfaceTests(unittest.TestCase):
    """Every place that asks a person to free space on the backup drive also says never to delete anything inside the backup folder."""

    def test_the_low_space_failure_text_and_next_step_carry_the_clause(self) -> None:
        telemetry = (DASHBOARD / "Telemetry.cs").read_text(encoding="utf-8")
        start = telemetry.index('case "repository_low_space":', telemetry.index("private static string DescribeFailureCode("))
        self.assertIn("(never anything inside the backup folder)", telemetry[start:telemetry.index("case", start + 30)])
        details = (DASHBOARD / "RunDetailsWindow.cs").read_text(encoding="utf-8")
        start = details.index('case "repository_low_space":', details.index("private static string Remediation("))
        self.assertIn("(never anything inside the backup folder)", details[start:details.index("case", start + 30)])

    def test_no_surface_asks_to_free_space_without_the_clause(self) -> None:
        sources = [
            *DASHBOARD.glob("*.cs"),
            *(WEB / "src").rglob("*.ts"),
            *(WEB / "src").rglob("*.tsx"),
            *(WEB / "components").rglob("*.tsx"),
            *(PROJECT / "src").glob("*.py"),
            *(PROJECT / "src").glob("*.ps1"),
            *(PROJECT / "installer").glob("*.ps1"),
            PROJECT / "README.md",
            PROJECT / "src" / "RECOVERY.md",
            *(PROJECT / "docs").glob("*.md"),
        ]
        found = 0
        for path in sources:
            if "node_modules" in path.parts:
                continue
            blocks = surface_blocks(path.read_text(encoding="utf-8"), markdown=path.suffix.lower() == ".md")
            found += sum(1 for _number, text in blocks if FREES_SPACE.search(text))
            for number, text in asks_to_free_space_without_the_clause(blocks):
                with self.subTest(file=path.name, line=number):
                    self.fail("asks to free space without saying never anything inside the backup folder: " + text)
        # The card's and hero's next steps, the low-space failure sentence and next step, RECOVERY.md and the architecture notes.
        self.assertGreater(found, 7)

    def test_the_scan_knows_every_way_of_asking_to_free_space(self) -> None:
        asks = [
            "Free up space on D:.",
            "Free some up.",
            "Make room on the backup drive.",
            "Make some space on D: first.",
            "Clear space on the drive.",
            "Clear up some disk space, then try again.",
            "Delete files you no longer need.",
            "Remove old files from the drive.",
            "Try deleting other files.",
            "Removing unneeded data helps.",
        ]
        for text in asks:
            with self.subTest(text=text):
                self.assertTrue(FREES_SPACE.search(text))
                self.assertEqual([(1, text)], asks_to_free_space_without_the_clause([(1, text)]))
                guarded = text[:-1] + " (never anything inside the backup folder)."
                self.assertEqual([], asks_to_free_space_without_the_clause([(1, guarded)]))
        # Words that only describe space, or remove something else, are not asks.
        for text in ("96.0 GiB free of 931 GiB", "Open to review or remove items.", "The backup drive doesn’t have enough free space."):
            with self.subTest(text=text):
                self.assertIsNone(FREES_SPACE.search(text))
        # "Never" alone, or a clause about some other folder, is not the clause.
        self.assertTrue(asks_to_free_space_without_the_clause([(1, "Make room by deleting old files. Never wait.")]))
        self.assertTrue(asks_to_free_space_without_the_clause([(1, "Make room, but never anything inside the Windows folder.")]))

    def test_in_markdown_a_wrapped_paragraph_is_read_whole(self) -> None:
        guarded = "Backups stop below the reserve. Make room by removing other\nfiles from that drive. Never delete anything inside the\nrepository folder.\n"
        self.assertEqual([], asks_to_free_space_without_the_clause(surface_blocks(guarded, markdown=True)))
        bare = "Intro.\n\nBackups stop below the reserve. Make room by removing other\nfiles from that drive.\n"
        self.assertEqual([3], [number for number, _ in asks_to_free_space_without_the_clause(surface_blocks(bare, markdown=True))])
        # A list item is its own unit: the clause in the next item does not cover it.
        items = "- Make room by deleting old files\n  from that drive.\n- Never delete anything inside the backup folder.\n"
        self.assertEqual([1], [number for number, _ in asks_to_free_space_without_the_clause(surface_blocks(items, markdown=True))])


class BackupSpaceWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        read = lambda path: path.read_text(encoding="utf-8")  # noqa: E731
        cls.space = read(DASHBOARD / "BackupSpace.cs")
        cls.window_space = read(DASHBOARD / "DashboardWindow.BackupSpace.cs")
        cls.window = read(DASHBOARD / "DashboardWindow.cs")
        cls.web = read(DASHBOARD / "DashboardWindow.Web.cs")
        cls.store = read(DASHBOARD / "SpaceWarningStore.cs")
        cls.telemetry = read(DASHBOARD / "Telemetry.cs")
        cls.build = read(DASHBOARD / "build.ps1")
        cls.types = read(WEB / "src" / "native-types.ts")
        cls.app = read(WEB / "src" / "App.tsx")
        cls.demo = read(WEB / "src" / "demo" / "demoState.ts")
        cls.bridge = read(WEB / "src" / "demo" / "mockBridge.ts")
        cls.profile = read(DASHBOARD / "EngineProfile.cs")

    def test_the_evaluator_is_pure(self) -> None:
        for forbidden in ("DateTime.Now", "DateTime.UtcNow", "DriveInfo", "File.", "Directory.", "Stopwatch"):
            self.assertNotIn(forbidden, self.space)

    def test_harnesses_with_fixed_source_lists_keep_compiling(self) -> None:
        # Several tests compile these files without BackupSpace.cs, so they never name its types. (Only read
        # here, never compiled, so the names are stems.)
        for stem in ("Telemetry", "SourceConfiguration", "DiagnosticExporter", "EngineProfile"):
            with self.subTest(file=stem):
                text = (DASHBOARD / f"{stem}.cs").read_text(encoding="utf-8")
                self.assertIsNone(re.search(r"(?<![A-Za-z])BackupSpace[A-Z]", text))

    def test_the_build_compiles_the_new_sources(self) -> None:
        for name in ("BackupSpace.cs", "SpaceWarningStore.cs", "DashboardWindow.BackupSpace.cs"):
            self.assertIn(f"(Join-Path $project '{name}')", self.build)

    def test_the_host_reads_the_drive_root_as_the_engine_does(self) -> None:
        method = self.window_space[self.window_space.index("internal static bool TryReadDriveSpace("):]
        method = method[:method.index("\n        }\n")]
        self.assertIn("drive.TotalFreeSpace", method)
        self.assertIn("Path.GetPathRoot", method)
        self.assertNotIn("AvailableFreeSpace", method)
        self.assertNotIn("EnumerateFiles", self.window_space)
        # The probe still describes the volume as before, and also reads the figures, off the window's thread.
        self.assertIn("DescribeRepositoryVolume(repositoryPath, out driveReady)", self.window)
        self.assertIn("TryReadDriveSpace(repositoryPath, out driveFree, out driveTotal)", self.window)
        self.assertIn("repositoryVolumeRead = true;", self.window)

    def test_the_drive_is_read_again_sooner_after_refresh_and_after_a_run(self) -> None:
        self.assertIn("repositoryVolumeNextProbeAt = 0;", self.window_space)
        refresh = self.web[self.web.index('if (string.Equals(command, "refresh", StringComparison.Ordinal))'):]
        self.assertIn("ProbeRepositorySpaceSooner();", refresh[:200])
        transition = self.window[self.window.index("private void HandleStateTransition("):]
        self.assertIn("if (wasActive && !snapshot.IsActive)", transition[:3000])
        self.assertIn("ProbeRepositorySpaceSooner();", transition[:3000])

    def test_the_card_holds_its_level_while_a_backup_runs(self) -> None:
        self.assertIn("bool runActive = previewEnabled || (readable && snapshot.IsActive);", self.window_space)
        self.assertIn("BackupSpaceEvaluator.HoldDuringRun(", self.window_space)

    def test_the_low_space_warning_is_a_presentation_command(self) -> None:
        self.assertIn('if (string.Equals(command, "setSpaceWarning", StringComparison.Ordinal))', self.web)
        self.assertIn("return ExecuteSpaceWarningCommand(payload, out error);", self.web)
        self.assertIn("TryParseSpaceWarningWeeks(payload, out weeks)", self.window_space)
        self.assertIn('private const string FileName = "space-warning.json";', self.store)
        self.assertIn("DashboardThemeManager.SettingsPath", self.store)
        self.assertIn("AtomicFile.ReplaceExisting", self.store)
        self.assertIn("LoadSpaceWarningPreference();", self.window)
        self.assertIn("| 'setSpaceWarning';", self.types)
        protected = self.types[self.types.index("export const PROTECTED_COMMANDS"):]
        self.assertNotIn("setSpaceWarning", protected[:protected.index("]);")])

    def test_the_page_state_carries_space(self) -> None:
        self.assertIn('repository["space"] = BuildWebSpaceState();', self.web)
        self.assertIn("space?: BackupSpaceState | null", self.types)
        self.assertIn('"repository_bytes_after"', self.telemetry)
        self.assertIn("public bool ForecastsBackupSpace { get; private set; }", self.profile)
        self.assertEqual(2, self.profile.count("profile.ForecastsBackupSpace = "))
        self.assertIn("profile.ForecastsBackupSpace = true;", self.profile)
        self.assertIn("profile.ForecastsBackupSpace = false;", self.profile)
        # Only the drive letter of a path is published.
        self.assertIn('space["drive"] = known.Drive ?? string.Empty;', self.window_space)

    def test_both_backup_location_cards_show_the_space(self) -> None:
        self.assertIn("<SpaceLine repository={state.repository} />", self.app)
        self.assertIn("<SpaceLine repository={state.repository} live /><SpaceWarningSetting state={state} send={send} />", self.app)
        self.assertEqual(1, self.app.count("<VolumeLine "), "VolumeLine is only the fallback for an older host")
        self.assertIn("const SPACE_WARNING_WEEKS = ['4', '8', '12'] as const;", self.app)
        self.assertIn("send('setSpaceWarning', { weeks })", self.app)
        self.assertIn("space.forecast.state === 'unavailable'", self.app)

    def test_the_sample_data_has_space(self) -> None:
        self.assertIn("space: sampleSpace()", self.demo)
        self.assertIn("applySpaceScenario(state, new URLSearchParams(window.location.search).get('space'));", self.bridge)
        self.assertIn("case 'setSpaceWarning':", self.bridge)


if __name__ == "__main__":
    unittest.main()
