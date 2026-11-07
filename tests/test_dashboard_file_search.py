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
FILE_SEARCH = WEB / "src" / "fileSearch.ts"
ONE_SHOT = WEB / "src" / "oneShot.ts"
NATIVE_TYPES = WEB / "src" / "native-types.ts"
MODAL = WEB / "components" / "primitives" / "RestoreFlowModal.tsx"
HOST_SEARCH = DASHBOARD / "DashboardWindow.RestoreSearch.cs"
CASES = PROJECT / "tests" / "fixtures" / "file-search-text-cases.json"

# Words a person should not need to know to use Find a file. "snapshot" also covers "snapshots".
FORBIDDEN_WORDS = ("snapshot", "repository", "engine", "canary", "restic", "session", "protected task")

# fileSearch.ts as it is (Node strips its types): the shared text cases, the lines of a result, the footer and the words.
RUNNER = """
const search = await import(process.argv[1]);
const once = await import(process.argv[2]);
const cases = JSON.parse(process.argv[3]);
const when = (iso, fallback) => iso ? `at ${iso.slice(0, 10)}` : fallback;
const version = (extra) => ({ snapshotId: 'ab'.repeat(32), when: '2026-11-06T02:00:00Z', whenDisplay: '', firstWhen: '2026-11-03T02:00:00Z',
  firstWhenDisplay: '', modified: '2026-11-05T18:22:00Z', modifiedDisplay: '', size: 49357, sizeDisplay: '48.2 KB', backups: 4,
  isLegacyUnbound: false, ...extra });
const result = (extra) => ({ key: 'file|/C/Docs/Budget.xlsx', path: '/C/Docs/Budget.xlsx', name: 'Budget.xlsx', type: 'file',
  folderDisplay: 'C:\\\\Docs', lastSeen: '2026-11-03T02:00:00Z', lastSeenDisplay: '', missingFromNewer: false, hasMoreVersions: false,
  versions: [], ...extra });
const state = (extra) => ({ text: 'Budget', status: 'idle', outcome: '', message: '', error: '', listChanged: false, searched: 0, total: 3,
  searchedOldest: '', searchedOldestDisplay: '', canContinue: false, overflow: false, blocked: '', results: [], resultsTotal: 0, ...extra });
const strings = [];
const walk = (value) => { if (typeof value === 'string') strings.push(value); else if (value && typeof value === 'object') Object.values(value).forEach(walk); };
walk(search.FIND_TEXT);
console.log(JSON.stringify({
  cases: cases.map(item => search.checkSearchText(item.text)),
  problems: search.FIND_TEXT.problems,
  strings,
  status: ['idle', 'searching', 'done', 'failed', 'stopping', '', null, 7].map(search.statusFrom),
  outcome: ['', 'complete', 'more', 'tooMany', 'tooBroad', 'tooSlow', 'stopped', undefined].map(search.outcomeFrom),
  lines: {
    several: search.versionLines(version({}), result({}), when),
    one: search.versionLines(version({ backups: 1, firstWhen: '2026-11-06T02:00:00Z' }), result({}), when),
    undated: search.versionLines(version({ when: '', firstWhen: '', modified: '', backups: 3 }), result({}), when),
    folder: search.versionLines(version({ sizeDisplay: '', modified: '' }), result({ type: 'dir' }), when),
    folderCut: search.versionLines(version({ sizeDisplay: '', modified: '' }), result({ type: 'dir', hasMoreVersions: true }), when),
  },
  label: search.versionLabel(version({}), result({}), when),
  folderLabel: search.versionLabel(version({ modified: '' }), result({ type: 'dir', name: 'Taxes' }), when),
  where: [search.folderLine(result({})), search.folderLine(result({ folderDisplay: '' }))],
  missing: [search.missingLine(result({ missingFromNewer: true }), when), search.missingLine(result({}), when)],
  footer: {
    idle: search.footerHint(state({})),
    blocked: search.footerHint(state({ blocked: 'A backup is about to start.' })),
    searching: search.footerHint(state({ status: 'searching' })),
    found: search.footerHint(state({ status: 'done', resultsTotal: 2 })),
    none: search.footerHint(state({ status: 'done' })),
    slow: search.footerHint(state({ status: 'done', outcome: 'tooSlow', nothingSearched: true })),
    slowAfterFinds: search.footerHint(state({ status: 'done', outcome: 'tooSlow', nothingSearched: true, resultsTotal: 2 })),
    notSearched: search.footerHint(state({ status: 'done', outcome: 'more', nothingSearched: true })),
    broad: search.footerHint(state({ status: 'done', outcome: 'tooBroad' })),
    failed: search.footerHint(state({ status: 'failed' })),
  },
  goOn: [search.continueLabel(state({})), search.continueLabel(state({ nothingSearched: true })),
    search.continueLabel(state({ outcome: 'tooSlow' }))],
  filled: search.fill(search.FIND_TEXT.suggest, { query: 'Budget' }),
  oneShot: ['restoreFlowFindFiles', 'restoreFlowFindMore', 'restoreFlowPickFound', 'restoreFlowFindClear'].map(command => once.ONE_SHOT_COMMANDS.has(command)),
}));
"""


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class FileSearchPageTests(unittest.TestCase):
    report: dict
    cases: list

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        cls.cases = json.loads(read(CASES))
        # Each text is handed over as JSON: a lone surrogate written as \\ud800 stays one, where an argument would be re-encoded.
        completed = subprocess.run(
            [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", RUNNER,
             FILE_SEARCH.as_uri(), ONE_SHOT.as_uri(), json.dumps(cls.cases)],
            capture_output=True, encoding="utf-8", timeout=60, check=False,
        )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            raise unittest.SkipTest("this Node.js cannot run TypeScript files")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        cls.report = json.loads(completed.stdout)

    def test_the_page_reads_every_shared_text_case_as_the_other_parts_do(self) -> None:
        self.assertGreater(len(self.cases), 30)
        for index, (case, checked) in enumerate(zip(self.cases, self.report["cases"])):
            with self.subTest(index=index):
                self.assertEqual(checked["error"], "" if case["valid"] else case["error"])
                if case["valid"]:
                    self.assertEqual(checked["normalized"], case["normalized"])
                else:
                    self.assertEqual(checked["message"], self.report["problems"][case["error"]])

    def test_the_page_refuses_a_text_in_the_hosts_words(self) -> None:
        host = read(HOST_SEARCH)
        body = host[host.index("internal static string RestoreFlowSearchTextMessage"):]
        body = body[:body.index("default:")]
        host_messages = {
            code: message.replace('\\"', '"').replace("\\\\", "\\")
            for code, message in re.findall(r'case "([A-Z]+)": return "((?:[^"\\]|\\.)*)";', body)
        }
        self.assertEqual(set(host_messages), {"EMPTY", "SHORT", "LONG", "FORBIDDEN", "CONTROL"})
        self.assertEqual(host_messages, self.report["problems"])

    def test_an_unknown_status_or_outcome_from_another_host_is_read_safely(self) -> None:
        self.assertEqual(self.report["status"], ["idle", "searching", "done", "failed", "idle", "idle", "idle", "idle"])
        self.assertEqual(self.report["outcome"], ["", "complete", "more", "tooMany", "tooBroad", "tooSlow", "", ""])

    def test_each_version_says_what_it_is_and_which_backups_hold_it(self) -> None:
        lines = self.report["lines"]
        self.assertEqual(lines["several"], ["Changed at 2026-11-05 · 48.2 KB", "In 4 backups, at 2026-11-03 to at 2026-11-06"])
        self.assertEqual(lines["one"], ["Changed at 2026-11-05 · 48.2 KB", "In the backup from at 2026-11-06"])
        self.assertEqual(lines["undated"], ["Change date unknown · 48.2 KB", "In 3 backups"])
        # A folder's change time says little (it moves only when something in it is added, removed or renamed): one row, no date.
        self.assertEqual(lines["folder"], ["Folder", "In 4 backups, at 2026-11-03 to at 2026-11-06"])
        self.assertEqual(lines["folderCut"], ["Folder", "In 4 or more backups, up to at 2026-11-06"])
        self.assertEqual(self.report["label"], "Restore Budget.xlsx as changed at 2026-11-05, from the backup of at 2026-11-06")
        self.assertEqual(self.report["folderLabel"], "Restore Taxes from the backup of at 2026-11-06")
        self.assertEqual(self.report["where"], ["In C:\\Docs", "At the top level of your backup"])
        self.assertEqual(self.report["missing"][0], "Not in your backups after at 2026-11-03. It may have been moved, renamed or deleted.")
        self.assertEqual(self.report["missing"][1], "")

    def test_the_footer_says_what_to_do_next_on_the_find_tab(self) -> None:
        footer = self.report["footer"]
        self.assertEqual(footer["idle"], "Type a name, then choose Find. Or choose a backup by date.")
        self.assertEqual(footer["blocked"], "A backup is about to start.")
        self.assertIn("Nothing is changed", footer["searching"])
        self.assertEqual(footer["found"], "Choose Restore this next to the version you want.")
        self.assertIn("Check the spelling", footer["none"])
        # A page that looked through no backup found nothing because it could not look: Try again or choose by date, never
        # "check the spelling"; a name too common to finish asks for more of it, as the summary above it does.
        for key in ("slow", "notSearched"):
            with self.subTest(footer=key):
                self.assertEqual(footer[key], "No backup could be looked through in the time allowed. Try again, or choose a backup by date.")
        self.assertEqual(footer["slowAfterFinds"], footer["found"])
        self.assertEqual(footer["broad"], "Type more of the name, or choose a backup by date.")
        self.assertIn("Nothing was changed", footer["failed"])
        # Going on after a page that looked through nothing (always so for tooSlow) repeats that page: Try again.
        self.assertEqual(self.report["goOn"], ["Look further back", "Try again", "Try again"])
        self.assertEqual(self.report["filled"], "Find a file named \u201cBudget\u201d")

    def test_find_look_further_back_and_restore_this_ask_once_per_press(self) -> None:
        self.assertEqual(self.report["oneShot"], [True, True, True, False])
        types = read(NATIVE_TYPES)
        protected = types[types.index("export const PROTECTED_COMMANDS"):]
        protected = protected[:protected.index("]);")]
        for command in ("restoreFlowFindFiles", "restoreFlowFindMore", "restoreFlowPickFound"):
            self.assertIn(f"'{command}'", protected)
        self.assertNotIn("'restoreFlowFindClear'", protected)

    def test_no_word_a_person_would_need_explained(self) -> None:
        # The host's sentences: the marked wording region and the sentence for an engine without the search. The rest of the file
        # is code (its literals name state keys such as snapshotId, which no one reads).
        host = read(HOST_SEARCH)
        region = host[host.index("// ---- File search wording"):host.index("// ---- End of file search wording")]
        unavailable = host[host.index("RestoreFlowSearchUnavailableMessage ="):]
        region += unavailable[:unavailable.index(";")]
        host_strings = re.findall(r'"((?:[^"\\]|\\.)*)"', region)
        self.assertTrue(any("Look further back" in text for text in host_strings))
        for text in [*self.report["strings"], *host_strings]:
            lowered = text.lower()
            for word in FORBIDDEN_WORDS:
                with self.subTest(text=text, word=word):
                    self.assertIsNone(re.search(rf"\b{re.escape(word)}", lowered))

    def test_the_tabs_appear_only_when_the_host_offers_the_search(self) -> None:
        modal = read(MODAL)
        self.assertIn("{search && <div className=\"restore-find-tabs\" role=\"tablist\"", modal)
        self.assertIn("const findShown = !!search && findMode;", modal)
        self.assertIn("activeStep === 'backup' && !findShown && <Button", modal)


if __name__ == "__main__":
    unittest.main()
