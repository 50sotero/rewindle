from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WEB = PROJECT / "src" / "dashboard" / "web"
MODULE = WEB / "src" / "runProblems.ts"

# Runs runProblems.ts as it is (Node strips its types) on each history and reports what the Activity page would show. A case is a
# list of runs, or {"runs": [...], "verified": {"at", "display"}} when the host's last verified backup is known.
RUNNER = """
const problems = await import(process.argv[1]);
const cases = JSON.parse(process.argv[2]);
const report = {};
for (const [name, value] of Object.entries(cases)) {
  const runs = Array.isArray(value) ? value : value.runs, verified = Array.isArray(value) ? undefined : value.verified;
  const resolved = problems.resolvedRuns(runs, verified);
  const unresolved = problems.unresolvedRuns(runs, resolved);
  const lastSuccess = problems.lastSuccessfulBackup(runs, verified);
  report[name] = {
    resolved: Object.fromEntries([...resolved].map(([id, by]) => [id, by.id ?? null])),
    resolvedBy: Object.fromEntries([...resolved].map(([id, by]) => [id, problems.resolvedByText(by)])),
    unresolved: unresolved.map(run => run.id),
    attention: problems.attentionText(unresolved, lastSuccess) ?? null,
    problems: runs.filter(problems.isProblem).map(run => run.id),
  };
}
const fresh = (state, verifiedAt) => problems.lastVerified({ state, verifiedAt }, 'shown', Date.parse('2026-08-10T00:00:00Z'));
const words = ['Verified', 'Unchanged', 'Clean baseline', 'Source errors', 'Incomplete', 'Failed', 'Cancelled', 'Canceled', 'Cancellation failed', 'Odd', ''];
report.helpers = {
  lastVerified: {
    healthy: fresh('Healthy', '2026-08-09T02:00:00Z') ?? null, anomaly: fresh('ClockAnomaly', '2026-08-09T02:00:00Z') ?? null,
    unavailable: fresh('Unavailable', '2026-08-09T02:00:00Z') ?? null, none: fresh('NoVerifiedBackup', '') ?? null,
    future: fresh('Healthy', '2026-08-11T02:00:00Z') ?? null,
  },
  labels: Object.fromEntries(words.map(word => [word, [problems.resultLabel(word), problems.resultHint(word) ?? null]])),
  types: ['Backup', 'Dry run', 'dry-run', '', ' Backup '].map(type => [problems.typeLabel(type), problems.runNoun(type)]),
  usual: {
    median: problems.usualSeconds([
      { success: true, result: 'Verified', durationSeconds: 600 }, { success: true, result: 'Verified', durationSeconds: 900 },
      { success: true, result: 'Verified', durationSeconds: 840 }, { success: true, result: 'Unchanged', durationSeconds: 40 },
      { success: false, result: 'Failed', durationSeconds: 5000 },
    ]),
    even: problems.usualSeconds([{ success: true, result: 'Verified', durationSeconds: 600 }, { success: true, result: 'Verified', durationSeconds: 800 }]),
    onlyUnchanged: problems.usualSeconds([{ success: true, result: 'Unchanged', durationSeconds: 40 }]),
    none: problems.usualSeconds([{ success: false, result: 'Failed', durationSeconds: 60 }]),
  },
};
console.log(JSON.stringify(report));
"""


def run(run_id: str, day: int, result: str, *, success: bool | None = None, kind: str = "Backup") -> dict:
    return {
        "id": run_id, "started": f"2026-08-{day:02d}T02:00:00Z", "startedDisplay": f"Day {day}", "type": kind,
        "result": result, "success": result in {"Verified", "Unchanged", "Clean baseline"} if success is None else success,
        "durationSeconds": 60, "durationDisplay": "1m 00s", "files": 1, "filesDisplay": "1", "processedBytes": 1,
        "processedDisplay": "1 B", "storedBytes": 0, "storedDisplay": "0 B", "snapshot": "",
    }


class RunProblemsTests(unittest.TestCase):
    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        cases = {
            # Failures and incomplete runs long ago, verified backups every night since: nothing to do.
            "old_trouble": [
                run("failed-1", 1, "Failed"), run("failed-2", 2, "Failed"), run("incomplete-1", 3, "Incomplete"),
                run("verified-1", 4, "Verified"), run("incomplete-2", 5, "Incomplete"), run("verified-2", 6, "Verified"),
                run("unchanged", 7, "Unchanged"),
            ],
            "latest_failed": [run("verified", 1, "Verified"), run("failed", 2, "Failed")],
            "three_since": [
                run("verified", 1, "Verified"), run("failed-1", 2, "Failed"), run("cancelled", 3, "Canceled"),
                run("incomplete", 4, "Incomplete"), run("failed-2", 5, "Failed"),
            ],
            "never_succeeded": [run("failed-1", 1, "Failed"), run("failed-2", 2, "Failed")],
            # A cancelled run is not a problem and resolves nothing; a dry run is put right by a backup, but not the reverse.
            "kinds": [
                run("dry-failed", 1, "Source errors", kind="Dry run"), run("backup-failed", 2, "Failed"),
                run("dry-ok", 3, "Clean baseline", kind="Dry run"), run("cancelled", 4, "Cancelled"),
            ],
            "dry_then_backup": [run("dry-failed", 1, "Source errors", kind="Dry run"), run("verified", 2, "Verified")],
            # The list lacks the backup that put things right (it ran while the app was closed), but the host knows when the last
            # verified one finished: older problems are resolved by it, newer ones are not.
            "verified_beyond_the_list": {
                "runs": [run("verified", 1, "Verified"), run("failed-old", 2, "Failed"), run("failed-new", 6, "Failed")],
                "verified": {"at": "2026-08-04T02:20:00Z", "display": "Day 4, 02:20"},
            },
            "verified_beyond_several": {
                "runs": [run("verified", 1, "Verified"), run("failed-1", 5, "Failed"), run("incomplete", 6, "Incomplete")],
                "verified": {"at": "2026-08-04T02:20:00Z", "display": "Day 4, 02:20"},
            },
            # The list's own later success is the one named, even when the host's verified time is later still.
            "list_wins": {
                "runs": [run("failed", 1, "Failed"), run("verified", 2, "Verified")],
                "verified": {"at": "2026-08-09T02:20:00Z", "display": "Day 9, 02:20"},
            },
        }
        completed = subprocess.run(
            [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", RUNNER,
             MODULE.as_uri(), json.dumps(cases)],
            capture_output=True, text=True, timeout=60, check=False,
        )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            raise unittest.SkipTest("this Node.js cannot run TypeScript files")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        cls.report = json.loads(completed.stdout)

    def test_runs_a_later_backup_put_right_ask_for_nothing(self) -> None:
        old = self.report["old_trouble"]
        self.assertEqual(old["problems"], ["failed-1", "failed-2", "incomplete-1", "incomplete-2"])
        # Each is put right by the nearest later success, not the newest one.
        self.assertEqual(old["resolved"], {
            "failed-1": "verified-1", "failed-2": "verified-1", "incomplete-1": "verified-1", "incomplete-2": "verified-2",
        })
        self.assertEqual(old["unresolved"], [])
        self.assertIsNone(old["attention"])

    def test_a_latest_backup_that_failed_is_named(self) -> None:
        latest = self.report["latest_failed"]
        self.assertEqual(latest["unresolved"], ["failed"])
        self.assertEqual(latest["attention"], "The backup on Day 2 failed, and no backup has succeeded since.")

    def test_several_runs_since_the_last_success_are_counted_without_the_cancelled_one(self) -> None:
        since = self.report["three_since"]
        self.assertEqual(since["unresolved"], ["failed-2", "incomplete", "failed-1"])
        self.assertNotIn("cancelled", since["problems"])
        self.assertEqual(
            since["attention"],
            "No backup has succeeded since Day 1. 3 runs since then did not succeed; the latest, the backup on Day 5, failed.",
        )

    def test_a_history_without_any_success_says_so(self) -> None:
        never = self.report["never_succeeded"]
        self.assertEqual(never["unresolved"], ["failed-2", "failed-1"])
        self.assertTrue(never["attention"].startswith("None of the backups listed here has succeeded."))

    def test_only_a_backup_puts_a_backup_right(self) -> None:
        kinds = self.report["kinds"]
        self.assertEqual(kinds["resolved"], {"dry-failed": "dry-ok"})
        self.assertEqual(kinds["unresolved"], ["backup-failed"])
        self.assertEqual(self.report["dry_then_backup"]["resolved"], {"dry-failed": "verified"})


    def test_the_hosts_last_verified_backup_settles_what_the_list_cannot(self) -> None:
        beyond = self.report["verified_beyond_the_list"]
        # The older failure is put right by a backup that is not in the list; the newer one is not.
        self.assertEqual(beyond["resolved"], {"failed-old": None})
        self.assertEqual(beyond["resolvedBy"], {"failed-old": "Resolved by the backup that finished on Day 4, 02:20"})
        self.assertEqual(beyond["unresolved"], ["failed-new"])
        self.assertEqual(beyond["attention"], "The backup on Day 6 failed, and no backup has succeeded since.")
        several = self.report["verified_beyond_several"]
        self.assertEqual(several["resolved"], {})
        # The last success named is the host's, which is newer than the newest one listed.
        self.assertEqual(
            several["attention"],
            "No backup has succeeded since Day 4, 02:20. 2 runs since then did not succeed; the latest, the backup on Day 6, was incomplete.",
        )

    def test_a_run_in_the_list_is_named_before_the_hosts_verified_time(self) -> None:
        wins = self.report["list_wins"]
        self.assertEqual(wins["resolved"], {"failed": "verified"})
        self.assertEqual(wins["resolvedBy"], {"failed": "Resolved by the backup on Day 2"})

    def test_a_verified_time_that_cannot_be_trusted_is_not_used(self) -> None:
        fresh = self.report["helpers"]["lastVerified"]
        self.assertEqual(fresh["healthy"], {"at": "2026-08-09T02:00:00Z", "display": "shown"})
        for name in ("anomaly", "unavailable", "none", "future"):
            self.assertIsNone(fresh[name], name)

    def test_results_and_kinds_of_run_are_said_in_plain_words(self) -> None:
        labels = self.report["helpers"]["labels"]
        self.assertEqual(labels["Verified"][0], "Verified")
        self.assertEqual(labels["Unchanged"][0], "Up to date")
        self.assertEqual(labels["Clean baseline"][0], "Check passed")
        self.assertEqual(labels["Source errors"][0], "Check found problems")
        self.assertEqual(labels["Canceled"][0], "Cancelled")
        self.assertEqual(labels["Cancellation failed"][0], "Could not stop")
        self.assertEqual(labels["Failed"][0], "Failed")
        # A result nobody has a word for is shown as it came, without a made-up sentence.
        self.assertEqual(labels["Odd"], ["Odd", None])
        self.assertEqual(labels[""], ["No result", None])
        for word in ("Verified", "Unchanged", "Clean baseline", "Source errors", "Incomplete", "Failed", "Cancelled", "Cancellation failed"):
            self.assertTrue(labels[word][1].endswith("."), word)
        self.assertEqual(self.report["helpers"]["types"], [["Backup", "backup"], ["Check only", "check"], ["Check only", "check"], ["Backup", "backup"], ["Backup", "backup"]])

    def test_the_usual_backup_time_is_the_middle_one_and_ignores_runs_that_found_nothing_new(self) -> None:
        usual = self.report["helpers"]["usual"]
        self.assertEqual(usual["median"], 840)
        self.assertEqual(usual["even"], 700)
        self.assertEqual(usual["onlyUnchanged"], 40)
        self.assertEqual(usual["none"], 0)


class ActivityWordingTests(unittest.TestCase):
    def test_the_history_no_longer_calls_every_failed_run_something_to_act_on(self) -> None:
        app = (WEB / "src" / "App.tsx").read_text(encoding="utf-8")
        modal = (WEB / "components" / "primitives" / "RunDetailsModal.tsx").read_text(encoding="utf-8")
        self.assertNotIn("todo: 'Needs attention'", app)
        # The chip says "Problems" while anything is open and "Resolved" once every one was put right.
        self.assertIn("todo: unresolved.length ? 'Problems' : 'Resolved'", app)
        self.assertIn("done: 'Successful'", app)
        self.assertIn("statusNote: 'Resolved'", app)
        self.assertIn("Nothing needs doing.", app)
        self.assertIn("resolvedBy={detailsResolvedBy}", app)
        self.assertIn("'If it happens again'", modal)

    def test_the_page_tells_a_cancelled_or_resolved_run_apart_from_one_to_act_on(self) -> None:
        modal = (WEB / "components" / "primitives" / "RunDetailsModal.tsx").read_text(encoding="utf-8")
        self.assertIn("Stopped before it finished", modal)
        self.assertIn("Nothing is wrong, and your earlier backups are not affected.", modal)
        self.assertNotIn(r"dry\s*run", modal)


if __name__ == "__main__":
    unittest.main()
