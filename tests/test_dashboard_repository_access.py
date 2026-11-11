"""How the dashboard reads and words a backup made with or without a password (backup-config.json "repository_access").

A backup made without a password has no saved password and no recovery key, and anyone who can open its folder can restore it. The
dashboard follows what the configuration says: the footer and the Save the backup step, the failure texts, the readiness checks and the
window that shows them, the repair and rotation launchers, and the evidence a restore drill must carry. A backup made before the choice
existed (a configuration without the key, the owner's included) is a backup with a password and reads and behaves as it always did.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "src"))

import recovery_health  # noqa: E402
import restore  # noqa: E402

DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"
ACCESS_TS = WEB / "src" / "repositoryAccess.ts"
HARNESS = PROJECT / "tests" / "fixtures" / "RepositoryAccessHarness.cs"
RESTORE_SEARCH = DASHBOARD / "DashboardWindow.RestoreSearch.cs"

# The owner's sentence, word for word, and the words the page and the windows use for a backup without a password.
NO_PASSWORD_NOTE = "You chose to back up without a password, so anyone who can open the backup folder can restore these files."

# Today's words for a backup with a password: they must not change. The run's details window (RunDetailsWindow.cs) writes straight
# apostrophes and the status line under the backup (Telemetry.cs) typographic ones (U+2019), so each sentence is pinned as it shows.
PASSWORD_AUTHENTICATION_DETAILS = (
    "Rewindle couldn't unlock your backups with its saved password. Open the Restore page and choose Check recovery readiness."
)
PASSWORD_AUTHENTICATION_STATUS = (
    "Rewindle couldn\u2019t unlock the backup location, so the backup stopped before it began. Your earlier backups are not affected."
)
NO_PASSWORD_AUTHENTICATION_DETAILS = (
    "Rewindle couldn't open your backups. Check that the backup drive or Google Drive folder is connected, then choose Back up now. "
    "If it still fails, open the Restore page and choose Check recovery readiness."
)
NO_PASSWORD_AUTHENTICATION_STATUS = (
    "Rewindle couldn\u2019t open your backups, so the backup stopped before it began. Check that the backup drive or Google Drive folder is "
    "connected, then try again. Your earlier backups are not affected."
)
MISMATCH = (
    "These backups now ask for a password that Rewindle doesn't have, usually because they were changed outside Rewindle. Rewindle can't "
    "carry on with them. To keep backing up, start new backups in another place."
)
MISMATCH_STATUS = MISMATCH.replace("'", "\u2019")
NOW_ASKS_FOR_PASSWORD = (
    "These backups now ask for a password, usually because one was added outside Rewindle. "
    "To keep backing up, start new backups in another place."
)
NOW_OPEN_WITHOUT_PASSWORD = (
    "These backups now open without a password, usually because it was removed outside Rewindle. "
    "To keep using them, see Switching an existing backup in SECURITY.md on Rewindle's GitHub page, "
    "or start new backups in another place."
)
# What restore.py says, character for character, when backups that Rewindle opens without a password now ask for one (the exit code 12 of
# a restore, a listing, a folder, a search or the drill), and what follows it when items stayed in the restore folder.
RESTORE_NOW_ASKS = (
    "These backups now ask for a password that Rewindle doesn't have, usually because they were changed outside Rewindle, so Rewindle "
    "can't open them. If you know that password, Restic can still restore your files with it, as RECOVERY.md in the recovery tools folder "
    "next to your backups explains."
)
RESTORE_FOLDER_NAME = ".rewindle-restore-0123456789abcdef"
SOURCE_UNREADABLE_DETAILS = "Open the affected paths listed below and check that you can read them. This run isn't counted as a finished backup."
SOURCE_UNREADABLE_STATUS = (
    "Some files couldn\u2019t be read (a program may have had them open), so this backup is incomplete. The next backup tries again."
)

PASSWORD_DESCRIPTION = (
    "These checks only look; they change nothing. They test that Rewindle's saved password and your recovery key each open your backups, "
    "that there is free space, that nothing is left locked, and that a restore works."
)
NO_PASSWORD_DESCRIPTION = (
    "These checks only look; they change nothing. They test that Rewindle can open your backups, that there is free space, that nothing "
    "is left locked, and that a restore works."
)
PASSWORD_LOCK_HELP = "Available only when leftover locks are present and Rewindle's saved password works."
NO_PASSWORD_LOCK_HELP = "Available only when leftover locks are present and Rewindle can open your backups."
PASSWORD_DRILL_HELP = (
    "Available only when a restore drill is due, your recovery key and recovery information check out, the latest backup was checked, "
    "and no locks or unfinished changes remain."
)
NO_PASSWORD_DRILL_HELP = (
    "Available only when a restore drill is due, Rewindle can open your backups, your recovery information checks out, the latest "
    "backup was checked, and no locks or unfinished changes remain."
)
PASSWORD_REPAIR_HELP = "Available only when your recovery key works but Rewindle's saved password for this Windows account doesn't."

# Words a person should not meet in the dashboard's own sentences.
TECHNICAL = re.compile(r"\b(repositor(?:y|ies)|snapshots?|restic|engine|dpapi|canary)\b", re.IGNORECASE)

RUNNER = """
const access = await import(process.argv[1]);
const odd = [undefined, null, '', 'Password', 'NO_PASSWORD', 'none', 'no-password', ' no_password', 'encrypted', 0, 1, true, false, {}, []];
console.log(JSON.stringify({
  password: access.repositoryAccessOf('password'),
  noPassword: access.repositoryAccessOf('no_password'),
  odd: odd.map(value => access.repositoryAccessOf(value)),
  note: access.NO_PASSWORD_NOTE,
  save: { password: access.saveStepExplanation('password'), noPassword: access.saveStepExplanation('no_password'), unknown: access.saveStepExplanation(null) },
}));
"""


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def restore_search_failure_copy() -> str:
    """DescribeRestoreFlowSearchFailure, word for word from the window's source, in a class the console harness can compile."""
    source = read(RESTORE_SEARCH)
    start = source.index("private static string DescribeRestoreFlowSearchFailure(")
    closing = "\n        }\n"
    end = source.index(closing, start) + len(closing)
    messages = (
        ("RestoreFlowSearchRunLockMessage", "(run lock)"),
        ("RestoreFlowSearchListChangedMessage", "(list changed)"),
        ("RestoreFlowSearchTooLongMessage", "(too long)"),
        ("RestoreFlowSearchGenericFailureMessage", "(generic failure)"),
    )
    lines = ["namespace ResticBackuper.Dashboard", "{", "    internal static class RestoreSearchFailureCopy", "    {"]
    lines += [f'        private const string {name} = "{text}";' for name, text in messages]
    lines += ["", "        " + source[start:end].replace("private static", "internal static", 1) + "    }", "}", ""]
    return "\n".join(lines)


class RepositoryAccessPageTests(unittest.TestCase):
    """repositoryAccess.ts as it is (Node strips its types), and the places in the page and the host that carry the value."""

    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        completed = subprocess.run(
            [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", RUNNER, ACCESS_TS.as_uri()],
            capture_output=True, encoding="utf-8", timeout=60, check=False,
        )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            raise unittest.SkipTest("this Node.js cannot run TypeScript files")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        cls.report = json.loads(completed.stdout)
        cls.app = read(WEB / "src" / "App.tsx")
        cls.types = read(WEB / "src" / "native-types.ts")
        cls.demo = read(WEB / "src" / "demo" / "demoState.ts")
        cls.bridge = read(WEB / "src" / "demo" / "mockBridge.ts")
        cls.host = read(DASHBOARD / "DashboardWindow.Web.cs")
        cls.window = read(DASHBOARD / "DashboardWindow.cs")

    def test_only_the_two_exact_words_are_read_and_anything_else_is_not_known(self) -> None:
        self.assertEqual(self.report["password"], "password")
        self.assertEqual(self.report["noPassword"], "no_password")
        # A missing field, null, another case or text, a number and a flag all say nothing: the page then claims nothing.
        self.assertEqual(self.report["odd"], [None] * 15)

    def test_the_footer_note_is_the_owners_sentence(self) -> None:
        self.assertEqual(self.report["note"], NO_PASSWORD_NOTE)

    def test_the_save_step_claims_encryption_only_for_a_backup_with_a_password(self) -> None:
        save = self.report["save"]
        self.assertEqual(save["password"], "Saves an encrypted copy of your files as one backup.")
        self.assertEqual(save["noPassword"], "Saves a copy of your files as one backup.")
        # Not knowing how the backups are opened claims nothing either way.
        self.assertEqual(save["unknown"], save["noPassword"])
        for text in save.values():
            self.assertIsNone(TECHNICAL.search(text))

    def test_the_protection_step_takes_its_words_from_how_the_backups_are_opened(self) -> None:
        self.assertIn("saveStepExplanation(repositoryAccessOf(state.repository.repositoryAccess))", self.app)
        self.assertNotIn("'Saves an encrypted copy of your files as one backup.'", self.app)
        self.assertIn("import { NO_PASSWORD_NOTE, repositoryAccessOf, saveStepExplanation, type RepositoryAccess } from './repositoryAccess';", self.app)

    def test_the_footer_follows_how_the_backups_are_opened(self) -> None:
        start = self.app.index("function ProtectionNote(")
        note = self.app[start:self.app.index("export default function App()", start)]
        # With a password: today's footer, word for word and with the closed lock.
        self.assertIn("<span><LockKeyhole size={10} />{preview ? 'Animation preview · no backup is running' : 'Your backups are encrypted'}</span>", note)
        # Without one: the open lock, the plain words, and the consequence as the accessible name and the tooltip.
        self.assertIn("access === 'no_password'", note)
        self.assertIn("<LockKeyholeOpen size={10} aria-hidden=\"true\" />", note)
        self.assertIn("'Your backups have no password'", note)
        self.assertIn("aria-label={preview ? undefined : NO_PASSWORD_NOTE}", note)
        self.assertIn("title={preview ? undefined : NO_PASSWORD_NOTE}", note)
        # Not known: no word of protection.
        unknown = note[note.index("access === null"):]
        unknown = unknown[:unknown.index("\n")]
        self.assertNotIn("encrypted", unknown)
        self.assertNotIn("no password", unknown.casefold())
        self.assertIn("<ProtectionNote access={repositoryAccessOf(state.repository.repositoryAccess)} preview={!!state.preview} />", self.app)
        self.assertIn("LockKeyholeOpen", self.app[:self.app.index("} from 'lucide-react';")])
        # The password footer's sentence still appears once, where the shell test finds it.
        self.assertEqual(self.app.count("Your backups are encrypted"), 1)

    def test_the_host_sends_how_the_backups_are_opened_and_the_page_types_it(self) -> None:
        start = self.host.index("private Dictionary<string, object> BuildWebRepositoryState()")
        build = self.host[start:self.host.index("private Dictionary<string, object> BuildWebBackupRangeState", start)]
        self.assertIn('repository["repositoryAccess"] = currentSourceConfiguration == null', build)
        self.assertIn(": currentSourceConfiguration.RepositoryAccess;", build)
        self.assertIn("repositoryAccess?: 'password' | 'no_password' | null", self.types)
        # The sample has a password unless the address asks for another case.
        self.assertIn("repositoryAccess: 'password'", self.demo)
        self.assertIn("'no_password'", self.bridge[self.bridge.index("get('access')"):])
        self.assertIn("state.repository.repositoryAccess = null", self.bridge)

    def test_the_older_window_says_nothing_about_encryption(self) -> None:
        self.assertNotIn("Encrypted locally", self.window)
        self.assertNotIn("encrypted Restic repository", self.window)
        self.assertIn('footerDetails.Text = "Stored on this PC  •  Protected changes require Windows approval";', self.window)
        self.assertIn('hint.Text = "Where your backups are stored.";', self.window)


@unittest.skipUnless(os.name == "nt", "the dashboard is Windows-only")
class RepositoryAccessHostTests(unittest.TestCase):
    """The dashboard's C# for both kinds of backup, compiled with the console harness and run on files in a disposable folder."""

    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        framework = Path(os.environ["WINDIR"]) / "Microsoft.NET" / "Framework64" / "v4.0.30319"
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest(".NET Framework C# compiler is unavailable")
        cls.build_directory = tempfile.TemporaryDirectory(prefix="repository-access-csharp-")
        executable = Path(cls.build_directory.name) / "RepositoryAccessHarness.exe"
        references = [
            framework / "System.dll",
            framework / "System.Core.dll",
            framework / "System.Web.Extensions.dll",
            framework / "WPF" / "WindowsBase.dll",
            framework / "WPF" / "PresentationCore.dll",
            framework / "WPF" / "PresentationFramework.dll",
            Path(os.environ["WINDIR"]) / "Microsoft.NET" / "assembly" / "GAC_MSIL" / "System.Xaml" / "v4.0_4.0.0.0__b77a5c561934e089" / "System.Xaml.dll",
        ]
        # The window that words a file search's failure cannot be compiled here (it is the whole dashboard window), so the method that does
        # is cut out of its source, as it is, into a class of its own beside the four messages it chooses between.
        search_copy = Path(cls.build_directory.name) / "RestoreSearchFailureCopy.cs"
        search_copy.write_text(restore_search_failure_copy(), encoding="utf-8")
        sources = [
            DASHBOARD / name
            for name in (
                "EngineProfile.cs", "AtomicFile.cs", "DashboardMotion.cs", "ElevatedRequestSecurity.cs", "SourceConfiguration.cs",
                "ProcessLiveness.cs", "Telemetry.cs", "TaskSchedule.cs", "DashboardTheme.cs", "DashboardVisualStyle.cs",
                "RecoveryHealthManager.cs", "RecoveryReadinessWindow.cs", "RestoreManager.cs", "RestoreFileSearch.cs", "RunDetailsWindow.cs",
            )
        ] + [HARNESS, search_copy]
        compiled = subprocess.run(
            [str(compiler), "/nologo", "/target:exe", "/platform:x64", f"/out:{executable}", "/codepage:65001",
             *[f"/reference:{path}" for path in references], *[str(path) for path in sources]],
            cwd=PROJECT, text=True, capture_output=True, timeout=120, check=False,
        )
        if compiled.returncode != 0:
            raise AssertionError("repository access harness failed to compile:\n" + compiled.stdout + compiled.stderr)
        work = Path(cls.build_directory.name) / "work"
        work.mkdir()
        # The sentences the readiness check gives when backups no longer open the way they were made, as the engine words them, keyed by
        # the mode of the configuration whose report carries each (see ReadinessDetails in the harness).
        (work / "readiness-details.json").write_text(
            json.dumps({"no_password": recovery_health.NO_PASSWORD_NOW_ASKS_DETAIL, "password": recovery_health.PASSWORD_NOW_OPENS_FREELY_DETAIL}),
            encoding="utf-8",
        )
        # The engine's sentence for backups that now ask for a password, alone and followed by where items stayed in the restore folder.
        (work / "restore-words.json").write_text(
            json.dumps(
                {
                    "asks": restore.NOW_ASKS_FOR_A_PASSWORD_MESSAGE,
                    "asks_and_left": restore.NOW_ASKS_FOR_A_PASSWORD_MESSAGE + " " + restore._LEFT_IN_RESTORE_FOLDER.format(name=RESTORE_FOLDER_NAME),
                    "asks_and_left_in_use": restore.NOW_ASKS_FOR_A_PASSWORD_MESSAGE
                    + " "
                    + restore._LEFT_IN_RESTORE_FOLDER_IN_USE.format(name=RESTORE_FOLDER_NAME),
                }
            ),
            encoding="utf-8",
        )
        # A window is built and read, never shown, and no process is started: the harness works on files in this folder only.
        completed = subprocess.run([str(executable), str(work)], cwd=PROJECT, text=True, capture_output=True, timeout=120, check=False)
        if completed.returncode != 0:
            raise AssertionError("repository access harness failed:\n" + completed.stdout + completed.stderr)
        cls.report = json.loads(completed.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "build_directory"):
            cls.build_directory.cleanup()

    # ---- the configuration ----------------------------------------------------------------------------------------------------

    def test_a_configuration_names_how_its_backups_are_opened(self) -> None:
        read_access = self.report["read"]
        # No key is a backup with a password: every configuration written before the choice existed, the owner's included.
        self.assertEqual(read_access["absent"], "password")
        self.assertEqual(read_access["text:password"], "password")
        self.assertEqual(read_access["text:no_password"], "no_password")
        # Anything else says nothing (the engine refuses such a configuration), and so does no document at all.
        for key, value in read_access.items():
            if key not in ("absent", "text:password", "text:no_password"):
                with self.subTest(case=key):
                    self.assertIsNone(value)

    def test_loading_a_configuration_reads_it_and_never_refuses_it_for_the_value(self) -> None:
        loaded = self.report["load"]
        self.assertEqual(loaded["absent"], "password")
        self.assertEqual(loaded["password"], "password")
        self.assertEqual(loaded["no_password"], "no_password")
        self.assertIsNone(loaded["unsupported"])
        self.assertIsNone(loaded["number"])

    # ---- the words of a failed backup -----------------------------------------------------------------------------------------

    def test_a_backup_with_a_password_keeps_its_failure_words(self) -> None:
        words = self.report["failure_words"]
        self.assertEqual(words["details:repository_authentication_failed|password"], PASSWORD_AUTHENTICATION_DETAILS)
        self.assertEqual(words["status:repository_authentication_failed|password"], PASSWORD_AUTHENTICATION_STATUS)
        # A run's record from before the choice has no repository_access, and reads as a backup with a password.
        self.assertEqual(words["status:repository_authentication_failed|absent"], PASSWORD_AUTHENTICATION_STATUS)
        for mode in ("password", "no_password", "unknown"):
            self.assertEqual(words[f"details:source_data_unreadable|{mode}"], SOURCE_UNREADABLE_DETAILS)
            self.assertEqual(words[f"status:source_data_unreadable|{mode}"], SOURCE_UNREADABLE_STATUS)
        self.assertEqual(words["status:source_data_unreadable|absent"], SOURCE_UNREADABLE_STATUS)

    def test_a_backup_without_a_password_is_not_blamed_on_a_saved_password(self) -> None:
        words = self.report["failure_words"]
        for mode in ("no_password", "unknown"):
            with self.subTest(mode=mode):
                self.assertEqual(words[f"details:repository_authentication_failed|{mode}"], NO_PASSWORD_AUTHENTICATION_DETAILS)
                self.assertEqual(words[f"status:repository_authentication_failed|{mode}"], NO_PASSWORD_AUTHENTICATION_STATUS)
        for key in ("details:repository_authentication_failed|no_password", "status:repository_authentication_failed|no_password"):
            self.assertNotIn("password", words[key].casefold())
            self.assertIn("backup drive or Google Drive folder is connected", words[key])

    def test_backups_that_now_ask_for_a_password_say_what_to_do_in_every_mode(self) -> None:
        words = self.report["failure_words"]
        for mode in ("password", "no_password", "unknown"):
            with self.subTest(mode=mode):
                self.assertEqual(words[f"details:repository_access_mismatch|{mode}"], MISMATCH)
                self.assertEqual(words[f"status:repository_access_mismatch|{mode}"], MISMATCH_STATUS)
        self.assertEqual(words["status:repository_access_mismatch|absent"], MISMATCH_STATUS)

    def test_no_failure_sentence_uses_a_word_a_person_should_not_need(self) -> None:
        for key, text in self.report["failure_words"].items():
            with self.subTest(key=key):
                self.assertIsNone(TECHNICAL.search(text))

    # ---- backups that now ask for a password, on their way from restore.py to the screen -------------------------------------------

    def test_the_sentence_for_backups_that_now_ask_for_a_password_is_shown_whole_for_every_kind_of_request(self) -> None:
        # The engine's constant is the sentence the owner approved, and the dashboard never rewrites, shortens or drops it.
        self.assertEqual(RESTORE_NOW_ASKS, restore.NOW_ASKS_FOR_A_PASSWORD_MESSAGE)
        words = self.report["restore_words"]
        followed_by = {
            "asks": RESTORE_NOW_ASKS,
            "asks_and_left": RESTORE_NOW_ASKS + " " + restore._LEFT_IN_RESTORE_FOLDER.format(name=RESTORE_FOLDER_NAME),
            "asks_and_left_in_use": RESTORE_NOW_ASKS + " " + restore._LEFT_IN_RESTORE_FOLDER_IN_USE.format(name=RESTORE_FOLDER_NAME),
        }
        for key, sentence in followed_by.items():
            for action in ("none", "list_snapshots", "list_tree", "find_files", "restore", "restore_drill", "plain"):
                with self.subTest(sentence=key, action=action):
                    self.assertEqual(sentence, words[f"sanitize:{key}|{action}"])

    def test_the_sanitizer_the_sentence_passes_through_still_rewords_the_dashboards_own_refusals(self) -> None:
        # Without this, "unchanged" could only mean that nothing is checked at all.
        self.assertEqual(
            "That folder is part of what Rewindle backs up or where its backups are kept. Choose a different folder, for example a new folder on another drive.",
            self.report["restore_words"]["sanitize:control"],
        )

    def test_a_file_search_that_fails_with_the_sentence_shows_it_whole_and_keeps_the_list(self) -> None:
        words = self.report["restore_words"]
        for key, sentence in (
            ("asks", RESTORE_NOW_ASKS),
            ("asks_and_left", RESTORE_NOW_ASKS + " " + restore._LEFT_IN_RESTORE_FOLDER.format(name=RESTORE_FOLDER_NAME)),
        ):
            with self.subTest(sentence=key):
                self.assertEqual({"text": sentence, "list_changed": False}, words["search:" + sentence])
        # The copy of the window's method is the real one: it still chooses its own words for what it knows.
        for text, outcome in (
            ("The backup service already holds the run lock.", {"text": "(run lock)", "list_changed": False}),
            ("That file is no longer in the list.", {"text": "(list changed)", "list_changed": True}),
            ("The search took too long.", {"text": "(too long)", "list_changed": False}),
            ("", {"text": "(generic failure)", "list_changed": False}),
            ("The file search failed.", {"text": "(generic failure)", "list_changed": False}),
        ):
            with self.subTest(text=text):
                self.assertEqual(outcome, words["search:" + text])

    # ---- the readiness report -------------------------------------------------------------------------------------------------

    def test_a_readiness_report_must_describe_the_way_the_configuration_opens_its_backups(self) -> None:
        parsed = self.report["parse"]
        # No repository_access in a report means a backup with a password.
        self.assertEqual(parsed["password|(absent)"], {"loaded": True, "access": "password", "error": None})
        self.assertEqual(parsed["password|password"], {"loaded": True, "access": "password", "error": None})
        self.assertEqual(parsed["no_password|no_password"], {"loaded": True, "access": "no_password", "error": None})
        # A report that says the other, or something unknown, is not used (and neither is any report for a configuration that is unknown).
        for key in ("password|no_password", "password|encrypted", "password|1", "no_password|(absent)", "no_password|password",
                    "no_password|encrypted", "no_password|1", "unknown|(absent)", "unknown|password", "unknown|no_password",
                    "unknown|encrypted", "unknown|1"):
            with self.subTest(case=key):
                self.assertFalse(parsed[key]["loaded"])
                self.assertIsNone(parsed[key]["access"])
                self.assertEqual(parsed[key]["error"], "Recovery-readiness data did not match how these backups are opened, so it was not used.")
                self.assertIsNone(TECHNICAL.search(parsed[key]["error"]))

    def test_what_the_checks_say_when_backups_no_longer_open_the_way_they_were_made_is_shown_whole(self) -> None:
        shown = self.report["readiness_details"]
        self.assertEqual({"no_password", "password"}, set(shown))
        # No word filter on the way (the launcher's, the window's) may hide a sentence that says "password" or names SECURITY.md, and none
        # may change it: the sentences are the engine's own and reach the grid as written.
        for mode, expected, engine in (
            ("no_password", NOW_ASKS_FOR_PASSWORD, recovery_health.NO_PASSWORD_NOW_ASKS_DETAIL),
            ("password", NOW_OPEN_WITHOUT_PASSWORD, recovery_health.PASSWORD_NOW_OPENS_FREELY_DETAIL),
        ):
            with self.subTest(mode=mode):
                self.assertEqual(expected, engine)
                self.assertEqual({"loaded": True, "parsed": expected, "listed": expected}, shown[mode])
                self.assertIsNone(TECHNICAL.search(expected))
        # Where to read about switching is named, so a person can find it from the app; "guide" alone is a place nobody can open.
        self.assertIn("SECURITY.md on Rewindle's GitHub page", shown["password"]["listed"])

    def test_a_backup_without_a_password_has_no_key_to_repair_or_rotate(self) -> None:
        launched = self.report["launchers"]
        self.assertEqual(launched["repair:no_password"], "This backup opens without a key, so there is nothing to repair.")
        self.assertEqual(launched["rotate:no_password"], "This backup opens without a key, so there are no keys to rotate.")
        # Refused before anything is looked for or started; a backup with a password goes on to look for its helper, as before.
        self.assertEqual(launched["started:no_password"], 0)
        self.assertEqual(launched["repair:password"], "The protected credential-repair runtime is missing.")
        self.assertEqual(launched["rotate:password"], "The protected key-rotation helper is missing.")

    # ---- the readiness window -------------------------------------------------------------------------------------------------

    def button(self, scenario: str, name: str) -> dict:
        return self.report["readiness"][scenario][name]

    def test_a_backup_with_a_password_is_drilled_with_its_recovery_key_as_always(self) -> None:
        self.assertTrue(self.button("password_all_pass", "drillButton")["enabled"])
        for scenario in ("password_key_fails", "password_report_without_a_key_check"):
            with self.subTest(scenario=scenario):
                self.assertFalse(self.button(scenario, "drillButton")["enabled"])
                self.assertEqual(self.button(scenario, "drillButton")["help"], PASSWORD_DRILL_HELP)
        # The key actions are there, and the repair is offered when the key works and the saved password does not.
        for scenario in ("password_all_pass", "password_key_fails", "password_repair_offered", "fresh:password"):
            self.assertTrue(self.button(scenario, "repairButton")["visible"])
            self.assertTrue(self.button(scenario, "keyRotationButton")["visible"])
        self.assertTrue(self.button("password_repair_offered", "repairButton")["enabled"])
        self.assertTrue(self.button("password_all_pass", "keyRotationButton")["enabled"])
        self.assertEqual(self.button("password_key_fails", "repairButton")["help"], PASSWORD_REPAIR_HELP)
        self.assertEqual(self.button("password_all_pass", "lockRepairButton")["help"], PASSWORD_LOCK_HELP)
        self.assertEqual(self.report["readiness"]["fresh:password"]["detail"], PASSWORD_DESCRIPTION)
        self.assertEqual(self.report["readiness"]["password_all_pass"]["rows"][1], "recovery_key")

    def test_a_backup_without_a_password_shows_no_key_actions_and_drills_without_a_key(self) -> None:
        for scenario in ("fresh:no_password", "no_password_all_pass", "no_password_cannot_open", "no_password_locks",
                         "no_password_bundle_fails", "no_password_key_check_listed", "no_password_key_check_listed_and_cannot_open",
                         "report_decides"):
            with self.subTest(scenario=scenario):
                for name in ("repairButton", "keyRotationButton"):
                    self.assertFalse(self.button(scenario, name)["visible"])
                    self.assertFalse(self.button(scenario, name)["enabled"])
                self.assertTrue(self.button(scenario, "drillButton")["visible"])
                self.assertTrue(self.button(scenario, "lockRepairButton")["visible"])
        # The drill needs Rewindle to open the backups and the recovery information to check out, and no recovery key.
        self.assertTrue(self.button("no_password_all_pass", "drillButton")["enabled"])
        self.assertFalse(self.button("no_password_cannot_open", "drillButton")["enabled"])
        self.assertFalse(self.button("no_password_bundle_fails", "drillButton")["enabled"])
        for scenario in ("no_password_cannot_open", "no_password_bundle_fails", "no_password_locks"):
            self.assertEqual(self.button(scenario, "drillButton")["help"], NO_PASSWORD_DRILL_HELP)
        # No report of a backup without a password lists a recovery key row, and the window does not add one.
        self.assertNotIn("recovery_key", self.report["readiness"]["no_password_all_pass"]["rows"])
        self.assertNotIn("rotation_rollback_key", self.report["readiness"]["no_password_all_pass"]["rows"])
        self.assertIn("Available now: Run restore drill.", self.report["readiness"]["no_password_all_pass"]["hint"])

    def test_leftover_locks_can_be_repaired_in_a_backup_without_a_password(self) -> None:
        self.assertTrue(self.button("no_password_locks", "lockRepairButton")["enabled"])
        self.assertIn("Available now: Repair stale locks.", self.report["readiness"]["no_password_locks"]["hint"])
        self.assertFalse(self.button("no_password_all_pass", "lockRepairButton")["enabled"])
        self.assertEqual(self.button("no_password_all_pass", "lockRepairButton")["help"], NO_PASSWORD_LOCK_HELP)

    def test_the_window_says_what_the_checks_test_for_the_kind_of_backup_it_describes(self) -> None:
        readiness = self.report["readiness"]
        self.assertEqual(readiness["fresh:no_password"]["detail"], NO_PASSWORD_DESCRIPTION)
        # Not knowing keeps today's words, as a window never given a mode always did.
        self.assertEqual(readiness["fresh:unknown"]["detail"], PASSWORD_DESCRIPTION)
        self.assertEqual(readiness["fresh:no_password"]["lockRepairButton"]["help"], NO_PASSWORD_LOCK_HELP)

    def test_the_report_decides_the_actions_not_the_window_it_was_opened_with(self) -> None:
        # A window that began without a known mode, given a report of a backup without a password, hides the key actions.
        self.assertFalse(self.button("report_decides", "repairButton")["visible"])
        self.assertTrue(self.button("report_decides", "drillButton")["enabled"])
        # And a report that lists a key check, for a backup that has none, does not switch the key actions on.
        self.assertFalse(self.button("no_password_key_check_listed", "keyRotationButton")["enabled"])
        self.assertFalse(self.button("no_password_key_check_listed", "repairButton")["enabled"])
        # Nor does a report that shows the key working and Rewindle unable to open the backups turn on the key repair (made for a password).
        self.assertFalse(self.button("no_password_key_check_listed_and_cannot_open", "repairButton")["enabled"])
        self.assertNotIn("Repair active credential", self.report["readiness"]["no_password_key_check_listed_and_cannot_open"]["hint"])

    def test_nothing_the_window_says_for_a_backup_without_a_password_names_a_key_or_a_saved_password(self) -> None:
        for scenario in ("fresh:no_password", "no_password_all_pass", "no_password_cannot_open", "no_password_locks", "no_password_bundle_fails"):
            state = self.report["readiness"][scenario]
            texts = [state["detail"], state["hint"]] + [state[name]["help"] for name in ("drillButton", "lockRepairButton")]
            for text in texts:
                with self.subTest(scenario=scenario, text=text):
                    for word in ("recovery key", "saved password", "keys", "credential", "dpapi"):
                        self.assertNotIn(word, text.casefold())
                    self.assertIsNone(TECHNICAL.search(text))

    def test_the_window_confirms_and_reports_a_drill_without_a_key_in_its_own_words(self) -> None:
        window = read(DASHBOARD / "RecoveryReadinessWindow.cs")
        self.assertIn('"Your original files and backups are not touched."', window)
        self.assertIn('"Your original files, backups and keys are not touched."', window)
        self.assertIn('? "Choose Yes in the Windows permission prompt to continue."', window)
        self.assertIn(": \"Choose Yes in the Windows permission prompt to continue. Your recovery key stays inside Rewindle's restore tool.\";", window)
        self.assertIn('"Checking that Rewindle can open your backups and validating protected artifacts."', window)
        self.assertIn('"Authenticating both recovery paths and validating protected artifacts."', window)

    # ---- the restore drill's evidence -----------------------------------------------------------------------------------------

    def test_a_drill_report_must_name_the_source_that_matches_how_the_backups_are_opened(self) -> None:
        drill = self.report["drill"]
        self.assertEqual(drill["password|recovery_key"], "accepted")
        self.assertEqual(drill["no_password|none"], "accepted")
        for key in ("password|none", "password|dpapi", "no_password|recovery_key", "no_password|dpapi",
                    "unknown|recovery_key", "unknown|none", "unknown|dpapi"):
            with self.subTest(case=key):
                self.assertEqual(drill[key], "InvalidDataException")
        self.assertEqual(drill["expected:password"], "recovery_key")
        self.assertEqual(drill["expected:no_password"], "none")
        self.assertIsNone(drill["expected:unknown"])

    def test_the_drill_takes_the_mode_from_the_configuration_the_request_was_bound_to(self) -> None:
        manager = read(DASHBOARD / "RestoreManager.cs")
        # The same bound configuration as the generation, in the request that runs by itself and in the one served by a session.
        self.assertEqual(manager.count("configuration.RepositoryAccess"), 2)
        self.assertIn("ValidateRecoveryDrillReport(payload, report, generation, repositoryAccess);", manager)
        self.assertNotIn('ReadString(payload, "credential_source") != "recovery_key"', manager)


if __name__ == "__main__":
    unittest.main()
