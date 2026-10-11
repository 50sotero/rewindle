from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WEB = PROJECT / "src" / "dashboard" / "web"
MODULE = WEB / "src" / "runProblems.ts"

# Runs runProblems.ts as it is (Node strips its types) on each history and reports what the Activity page would show.
RUNNER = """
const problems = await import(process.argv[1]);
const cases = JSON.parse(process.argv[2]);
const report = {};
for (const [name, runs] of Object.entries(cases)) {
  const resolved = problems.resolvedRuns(runs);
  const unresolved = problems.unresolvedRuns(runs, resolved);
  const lastSuccess = runs.filter(run => run.type === 'Backup' && run.success).sort((a, b) => Date.parse(b.started) - Date.parse(a.started))[0];
  report[name] = {
    resolved: Object.fromEntries([...resolved].map(([id, by]) => [id, by.id])),
    unresolved: unresolved.map(run => run.id),
    attention: problems.attentionText(unresolved, lastSuccess) ?? null,
    problems: runs.filter(problems.isProblem).map(run => run.id),
  };
}
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


class ActivityWordingTests(unittest.TestCase):
    def test_the_history_no_longer_calls_every_failed_run_something_to_act_on(self) -> None:
        app = (WEB / "src" / "App.tsx").read_text(encoding="utf-8")
        modal = (WEB / "components" / "primitives" / "RunDetailsModal.tsx").read_text(encoding="utf-8")
        self.assertNotIn("todo: 'Needs attention'", app)
        self.assertIn("todo: 'Problems'", app)
        self.assertIn("statusNote: 'Resolved'", app)
        self.assertIn("Nothing needs doing.", app)
        self.assertIn("resolvedBy={detailsResolvedBy}", app)
        self.assertIn("'If it happens again'", modal)


if __name__ == "__main__":
    unittest.main()
