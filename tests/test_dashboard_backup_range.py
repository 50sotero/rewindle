"""What each backup did, and how far back the backups go, on the dashboard's pages.

backupRange.ts runs with Node as it is (Node strips its types), with when.ts writing the dates the way the page does. The
rest are source checks that tie the pages, the table and the run details to it and to the host's state.
"""

from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"
RANGE_MODULE = WEB / "src" / "backupRange.ts"
WHEN_MODULE = WEB / "src" / "when.ts"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def function_body(source: str, name: str) -> str:
    """The text of a top-level `function name(` up to the closing brace at the start of a line."""
    start = source.index(f"function {name}(")
    return source[start:source.index("\n}\n", start)]


# Each case is [range, locale, verifiedAt]; the runner prints the line backupRangeText gives, with dates written as App writes them.
RUNNER = """
const range = await import(process.argv[1]);
const when = await import(process.argv[2]);
const cases = JSON.parse(process.argv[3]);
const report = {};
for (const [name, [value, locale, verifiedAt]] of Object.entries(cases)) {
  const formatDate = iso => when.formatWhen(iso, locale, '', { weekday: false, time: false });
  report[name] = range.backupRangeText(value, locale, formatDate, verifiedAt ?? undefined);
}
console.log(JSON.stringify(report));
"""

# Midday UTC, so the date is the same in every time zone; years before this one, so the year is always written.
OLDEST = "2025-03-03T12:00:00Z"
COUNTED = "2025-11-02T12:00:00Z"
VERIFIED = "2025-11-05T12:00:00Z"


def backup_range(count: object, *, source: str = "backup", oldest: str = OLDEST, counted: str = COUNTED) -> dict:
    return {"count": count, "oldestAt": oldest, "countedAt": counted, "source": source}


class BackupRangeTextTests(unittest.TestCase):
    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        cases = {
            "none": [None, "en-GB", None],
            "zero": [backup_range(0), "en-GB", None],
            "fraction": [backup_range(1.5), "en-GB", None],
            "negative": [backup_range(-3), "en-GB", None],
            "text": [backup_range("412"), "en-GB", None],
            "unreadableOldest": [backup_range(412, oldest="not a date"), "en-GB", None],
            "one": [backup_range(1), "en-GB", None],
            "many": [backup_range(412), "en-GB", None],
            "manyUs": [backup_range(412), "en-US", None],
            "thousandsUs": [backup_range(12040), "en-US", None],
            # The Restore list counted before the last verified backup: the line says when it was counted.
            "listedBeforeVerified": [backup_range(412, source="restore"), "en-GB", VERIFIED],
            "listedBeforeVerifiedUs": [backup_range(412, source="restore"), "en-US", VERIFIED],
            # The backup service counts during the verified backup itself, so its count is never dated.
            "engineBeforeVerified": [backup_range(412, source="backup"), "en-GB", VERIFIED],
            "listedNoVerified": [backup_range(412, source="restore"), "en-GB", None],
            "listedAfterVerified": [backup_range(412, source="restore", counted="2025-11-06T12:00:00Z"), "en-GB", VERIFIED],
            "listedUnreadableCounted": [backup_range(412, source="restore", counted="later"), "en-GB", VERIFIED],
        }
        completed = subprocess.run(
            [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", RUNNER,
             RANGE_MODULE.as_uri(), WHEN_MODULE.as_uri(), json.dumps(cases)],
            capture_output=True, encoding="utf-8", timeout=60, check=False,
        )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            raise unittest.SkipTest("this Node.js cannot run TypeScript files")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        cls.report = json.loads(completed.stdout)

    def test_nothing_is_said_when_anything_is_unknown(self) -> None:
        for name in ("none", "zero", "fraction", "negative", "text", "unreadableOldest"):
            with self.subTest(name=name):
                self.assertEqual(self.report[name], "")

    def test_the_line_counts_the_backups_and_names_the_oldest(self) -> None:
        self.assertEqual(self.report["one"], "1 backup, from 3 Mar 2025")
        self.assertEqual(self.report["many"], "412 backups, oldest 3 Mar 2025")
        self.assertEqual(self.report["manyUs"], "412 backups, oldest Mar 3, 2025")
        self.assertEqual(self.report["thousandsUs"], "12,040 backups, oldest Mar 3, 2025")

    def test_only_a_restore_list_count_older_than_the_last_backup_is_dated(self) -> None:
        self.assertEqual(self.report["listedBeforeVerified"], "412 backups, oldest 3 Mar 2025 · as of 2 Nov 2025")
        self.assertEqual(self.report["listedBeforeVerifiedUs"], "412 backups, oldest Mar 3, 2025 · as of Nov 2, 2025")
        for name in ("engineBeforeVerified", "listedNoVerified", "listedAfterVerified", "listedUnreadableCounted"):
            with self.subTest(name=name):
                self.assertEqual(self.report[name], "412 backups, oldest 3 Mar 2025")


class BackupRangeSourceTests(unittest.TestCase):
    def test_protection_and_restore_show_the_line(self) -> None:
        app = read(WEB / "src" / "App.tsx")
        self.assertIn("import { backupRangeText } from './backupRange';", app)
        self.assertIn("const backupRangeLine = (state: DashboardState) =>", app)
        self.assertIn("verifiedBackup(state)?.at", app)
        self.assertIn("{ weekday: false, time: false }", app)
        protection = function_body(app, "Protection")
        self.assertIn("const range = backupRangeLine(state);", protection)
        # Under the backup location, in one row of the card with the drive's line, so the button beside them stays put.
        self.assertRegex(
            protection,
            r'<div className="location-facts"><VolumeLine repository=\{state\.repository\} />\{range && <div className="muted-copy backup-range-line">\{range\}</div>\}</div>',
        )
        restore = function_body(app, "RestorePage")
        self.assertIn("const range = backupRangeLine(state);", restore)
        self.assertIn('{range && <p className="muted-copy restore-range"><History size={13} aria-hidden="true" />{range}</p>}', restore)
        # Not drawn in place of the explanation when the backup service is missing.
        self.assertLess(restore.index("if (serviceMissing(state))"), restore.index("backupRangeLine(state)"))
        # Settings and Activity do not repeat it.
        self.assertNotIn("backupRangeLine", function_body(app, "SettingsPage"))
        self.assertNotIn("backupRangeLine", function_body(app, "ActivityHistory"))

    def test_activity_rows_carry_what_each_backup_found(self) -> None:
        app = read(WEB / "src" / "App.tsx")
        self.assertIn("ownerNote: run.changesDisplay || undefined,", function_body(app, "ActivityHistory"))
        table = read(WEB / "components" / "primitives" / "FilterTable.tsx")
        self.assertIn("ownerNote?: string;", table)
        self.assertIn('{row.ownerNote && <>', table)
        self.assertIn('<span className="sr-only">; </span>', table)
        self.assertIn('title={row.ownerNote}>{row.ownerNote}</span>', table)

    def test_run_details_show_what_the_backup_found(self) -> None:
        modal = read(WEB / "components" / "primitives" / "RunDetailsModal.tsx")
        self.assertIn("const changes = result?.isBackup ? activeDetails?.changesDisplay?.trim() || undefined : undefined;", modal)
        self.assertIn('<DetailStat label="Files" value={counted(activeDetails.filesDisplay)} icon={<FileText size={13} />} sub={changes} hint={changes ? CHANGES_HINT : undefined} />', modal)
        self.assertIn('{sub && <span className="run-detail-stat-sub">{sub}</span>}', modal)
        # Why a backup after a change to the plan counts everything as new: adding or removing a folder, and moving the backups.
        hint = re.search(r"const CHANGES_HINT = '([^']*)';", modal)
        self.assertIsNotNone(hint)
        self.assertIn("add or remove a folder, or move your backups", hint.group(1))
        css = read(WEB / "styles" / "app.css")
        for rule in (".run-detail-stat-sub", ".backup-destinations .location-facts", ".backup-range-line", ".restore-range"):
            self.assertIn(rule, css)

    def test_the_page_reads_what_the_host_sends(self) -> None:
        types = read(WEB / "src" / "native-types.ts")
        self.assertIn("export interface BackupRangeState { count: number; oldestAt: string; countedAt: string; source: 'backup' | 'restore' }", types)
        self.assertIn("backupRange?: BackupRangeState | null;", types)
        self.assertEqual(types.count("changesDisplay?: string;"), 2)
        web = read(DASHBOARD / "DashboardWindow.Web.cs")
        self.assertIn('state["backupRange"] = BuildWebBackupRangeState(snapshot);', web)
        for key in ("count", "oldestAt", "countedAt", "source"):
            self.assertIn(f'result["{key}"] = ', web)
        # Only the sentence goes to the page: the raw numbers stay in the host and its history file.
        self.assertIn('item["changesDisplay"] = run.ChangesDisplay;', web)
        self.assertNotIn('item["filesNew"]', web)
        self.assertNotIn('result["newestAt"]', web)
        self.assertIn('{ "changesDisplay", details.ChangesDisplay ?? string.Empty },', web)

    def test_the_restore_lists_count_never_changes_what_restore_does(self) -> None:
        flow = read(DASHBOARD / "DashboardWindow.RestoreFlow.cs")
        self.assertIn("ShowRestoreFlowSnapshotList(result.Snapshots, freshAfterRead);", flow)
        start = flow.index("private void ShowRestoreFlowSnapshotList(")
        body = flow[start:flow.index("\n        }\n", start)]
        # Last, after the list is shown and published, and nothing it throws reaches Restore.
        publish = body.rindex("PublishWebPresentationState();")
        self.assertLess(publish, body.index("RecordRestoreFlowBackupRange(freshAfterRead, listedSnapshots);"))
        self.assertRegex(
            body[publish:],
            r"try\s*\{\s*RecordRestoreFlowBackupRange\(freshAfterRead, listedSnapshots\);\s*\}\s*catch \(Exception\)\s*\{",
        )
        # On the window's thread it only keeps the count in memory: the file is written by the next refresh.
        telemetry = read(DASHBOARD / "Telemetry.cs")
        start = telemetry.index("internal void RecordListedBackupRange(")
        record = telemetry[start:telemetry.index("\n        }\n", start)]
        for io in ("TryAtomicWriteJson", "File.", "Directory.", "lock (syncRoot)"):
            self.assertNotIn(io, record)
        self.assertIn("lock (listedBackupRangeGate)", record)

    def test_the_words_are_a_home_users(self) -> None:
        # The literal text these additions show: the range line, the run-details tooltip and the host's count sentence.
        texts = re.findall(r"`([^`]*)`", read(RANGE_MODULE))
        modal = read(WEB / "components" / "primitives" / "RunDetailsModal.tsx")
        texts += re.findall(r"const CHANGES_HINT = '([^']*)';", modal)
        telemetry = read(DASHBOARD / "Telemetry.cs")
        format_changes = telemetry[telemetry.index("public static string FormatChanges("):]
        texts += re.findall(r'"([^"]*)"', format_changes[:format_changes.index("\n        }\n")])
        self.assertGreaterEqual(len(texts), 6)
        for text in texts:
            with self.subTest(text=text):
                self.assertIsNone(re.search(r"snapshot|repositor|restic|engine", text, re.IGNORECASE))

    def test_the_sample_data_shows_both_looks(self) -> None:
        demo = read(WEB / "src" / "demo" / "demoState.ts")
        # Counts without another random() call, so every other sample value stays as it was.
        self.assertIn("20 + (age * 37) % 300", demo)
        self.assertIn("changesDisplay: run.changesDisplay ?? ''", demo)
        bridge = read(WEB / "src" / "demo" / "mockBridge.ts")
        self.assertIn("state.backupRange = range === 'none' ? null : sampleBackupRange(Date.now(), range === 'stale' ? 3 : 0);", bridge)


if __name__ == "__main__":
    unittest.main()
