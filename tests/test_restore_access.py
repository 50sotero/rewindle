"""Restoring from backups that have no password.

src/restore.py also runs from the standalone recovery folder, where it cannot import restic_common, so it carries its own
copy of the engine's rule (backup-config.json "repository_access": "password", also when the key is absent, or
"no_password"). These tests check that copy against the engine's, and what restore.py does for each kind of backup:

- backups without a password are opened with --insecure-no-password and nothing else: no --password-command (not even
  when an older install left a DPAPI file behind), no recovery key, no prompt (every Restic gets stdin closed, because a
  Restic without the flag would otherwise wait for a password that nobody can type);
- the restore drill needs no key file there and says so (credential_source "none"); a key file is refused;
- a file search, a listing, a restore and the drill all work;
- a configuration without the key (every older install) behaves exactly as before.

Restic is a stand-in that follows the shared rules in tests/restic_access.py, and, where the release build's pinned
restic.exe is present, the real Restic in a throwaway backup.
"""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import warnings


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = PROJECT_ROOT / "src"
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE_ROOT))
sys.path.insert(0, str(TESTS))

import restic_common
import restore


RESTIC = PROJECT_ROOT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"
NEW_ID = "b" * 64
REPOSITORY_ID = "0123456789abcdef0123456789abcdef"
PLAN_ID = "12345678-1234-4abc-8def-1234567890ab"
NO_KEY_FILE_MESSAGE = "This backup opens without a key, so there is no key file to use."
# What a person is told when backups that Rewindle opens without a password now ask for one: never "Restic ... failed with exit
# code 12". Written out here, character for character, so that a change of it is seen.
NOW_ASKS_FOR_A_PASSWORD = (
    "These backups now ask for a password that Rewindle doesn't have, usually because they were changed outside Rewindle, "
    "so Rewindle can't open them. If you know that password, Restic can still restore your files with it, as RECOVERY.md "
    "in the recovery tools folder next to your backups explains."
)
DRILL_KEY_FILE_MESSAGE = "--recovery-drill requires a target, report, and recovery-key file"
CANARY = b"canary\n"
DRILL_FILES = {"canary.txt": CANARY, "live.txt": b"live source sentinel\n", "notes.txt": b"fixture notes\n"}
# The two sentences of Get-RepositoryAccess in every PowerShell script that reads the field (design 3, byte for byte).
GET_REPOSITORY_ACCESS = """function Get-RepositoryAccess {
    # How Restic opens these backups (backup-config.json "repository_access"): 'password' (also when the key is absent,
    # as in every configuration written before the choice existed) or 'no_password'. Anything else is refused.
    param([Parameter(Mandatory = $true)] [object]$Configuration)
    $property = $Configuration.PSObject.Properties['repository_access']
    if ($null -eq $property) { return 'password' }
    $value = $property.Value
    if ($value -isnot [string] -or $value -cnotin @('password', 'no_password')) {
        throw 'unsupported repository_access'
    }
    return [string]$value
}
"""


# A Restic for the tests: the three rules of tests/restic_access.py first (as the real Restic applies them), then just
# enough of listing, finding and restoring for restore.py. It logs every call (arguments and the names, not the values,
# of its environment) for the tests to read.
FAKE_RESTIC = r'''from __future__ import annotations
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, __TESTS__)
from restic_access import restic_access_result

script = Path(__file__)
control = json.loads(script.with_suffix(".control.json").read_text(encoding="utf-8"))
args = sys.argv[1:]
with Path(control["log"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({"args": args, "environment": sorted(os.environ)}, separators=(",", ":")) + "\n")

refusal = restic_access_result(args, os.environ, control["backups"])
if refusal is not None:
    sys.stderr.write(refusal[1] + "\n")
    raise SystemExit(refusal[0])
if control["backups"] == "password":
    # Backups with a password open only for the password command or the recovery key's password.
    if "--password-command" not in args and os.environ.get("RESTIC_PASSWORD") != control["password"]:
        raise SystemExit(12)
if control.get("answer_12_for") in args:
    # Backups that open, but this one command is answered "wrong password or no key found" (a password added in between).
    sys.stderr.write("Fatal: wrong password or no key found\n")
    raise SystemExit(12)

if "find" in args:
    ids = [args[index + 1] for index, value in enumerate(args[:-1]) if value == "--snapshot"]
    found = []
    for snapshot_id in ids:
        nodes = control.get("find_nodes", {}).get(snapshot_id, [])
        if nodes:
            found.append({"matches": nodes, "hits": len(nodes), "snapshot": snapshot_id})
    sys.stdout.write(json.dumps(found) + "\n")
    raise SystemExit(0)
if "cat" in args:
    print(json.dumps({"id": control["repository_id"], "version": 2}))
    raise SystemExit(0)
if "snapshots" in args:
    print(json.dumps(control["snapshots"], separators=(",", ":")))
    raise SystemExit(0)
if "ls" in args:
    for entry in control["tree"]:
        print(json.dumps(entry, separators=(",", ":")))
    raise SystemExit(0)
if "restore" in args:
    target = Path(args[args.index("--target") + 1])
    target.mkdir(parents=True, exist_ok=True)
    includes = [args[index + 1] for index, value in enumerate(args[:-1]) if value == "--include"]
    if includes:
        for pattern in includes:
            leaf = pattern.rsplit("/", 1)[-1]
            (target / leaf).write_bytes(control["files"][leaf].encode("latin-1"))
    else:
        (target / "restored.txt").write_text("verified fake data", encoding="utf-8")
    raise SystemExit(0)
raise SystemExit(97)
'''


def one_snapshot(source: Path) -> dict:
    return {
        "id": NEW_ID,
        "short_id": NEW_ID[:8],
        "time": "2026-07-21T01:00:00Z",
        "hostname": "TESTHOST",
        "tags": ["scheduled"],
        "paths": [str(source)],
        "summary": {"total_files_processed": 3, "total_bytes_processed": 42},
    }


class SpawnRecorder:
    """Records the stdin every Restic start was given (restore.py starts them through subprocess.Popen, run and call)."""

    def __init__(self) -> None:
        self.stdin: list[object] = []
        recorder = self
        real = subprocess.Popen

        class Recording(real):  # type: ignore[misc, valid-type]
            def __init__(self, *args: object, **kwargs: object) -> None:
                recorder.stdin.append(kwargs.get("stdin", "inherited"))
                super().__init__(*args, **kwargs)

        self._patch = mock.patch.object(subprocess, "Popen", Recording)

    def __enter__(self) -> "SpawnRecorder":
        self._patch.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._patch.stop()


class RuleCopyTests(unittest.TestCase):
    """restore.py's copy of the rule says what restic_common's says."""

    VALUES = ("Password", "NO_PASSWORD", "no-password", "none", "", " password", None, 0, 5, True, [], {})

    def test_the_values_the_default_and_the_flag_are_the_engines(self) -> None:
        self.assertEqual(restic_common.REPOSITORY_ACCESS_VALUES, restore.REPOSITORY_ACCESS_VALUES)
        self.assertEqual(restic_common.DEFAULT_REPOSITORY_ACCESS, restore.DEFAULT_REPOSITORY_ACCESS)
        self.assertEqual(restic_common.NO_PASSWORD_FLAG, restore.NO_PASSWORD_FLAG)
        self.assertEqual(restic_common.PASSWORD_SOURCE_OPTIONS, restore.PASSWORD_SOURCE_OPTIONS)

    def test_absent_means_password_and_the_two_values_are_exact(self) -> None:
        self.assertEqual("password", restore.repository_access({}))
        self.assertEqual("password", restore.repository_access({"repository_access": "password"}))
        self.assertEqual("no_password", restore.repository_access({"repository_access": "no_password"}))

    def test_anything_else_is_refused_with_the_engines_message(self) -> None:
        for value in self.VALUES:
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as ours:
                    restore.repository_access({"repository_access": value})
                with self.assertRaises(ValueError) as theirs:
                    restic_common.repository_access({"repository_access": value})
                self.assertEqual("unsupported repository_access", str(ours.exception))
                self.assertEqual(str(theirs.exception), str(ours.exception))

    def test_every_copy_agrees_on_every_value(self) -> None:
        for value in (*self.VALUES, "password", "no_password"):
            with self.subTest(value=value):
                config = {"repository_access": value}
                try:
                    expected = restic_common.repository_access(config)
                except ValueError as error:
                    with self.assertRaises(ValueError) as caught:
                        restore.repository_access(config)
                    self.assertEqual(str(error), str(caught.exception))
                else:
                    self.assertEqual(expected, restore.repository_access(config))

    def test_the_loader_refuses_an_unsupported_value_before_anything_runs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rwa-") as text:
            root = Path(text)
            for value in ("Password", "none", "", None):
                with self.subTest(value=value):
                    path = root / "backup-config.json"
                    path.write_text(
                        json.dumps(
                            {
                                "repository": str(root / "repository"),
                                "repository_volume_serial": "00000000",
                                "sources": [str(root / "source")],
                                "repository_access": value,
                            }
                        ),
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(ValueError, "unsupported repository_access"):
                        restore.load_restore_config(path)

    def test_no_password_backups_never_get_a_password_command(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rwa-") as text:
            root = Path(text)
            secret = root / "repository-password.dpapi.json"
            secret.write_text("an older install's DPAPI file", encoding="utf-8")
            config = {"python_executable": sys.executable, "secret_file": str(secret), "restic_executable": str(root / "restic.exe")}
            # The leftover file and a Python that exists are exactly what makes a command for backups with a password.
            command = restore.password_command(config)
            self.assertIsNotNone(command)
            self.assertIn("reveal", command)
            self.assertEqual(command, restore.password_command({**config, "repository_access": "password"}))
            self.assertIsNone(restore.password_command({**config, "repository_access": "no_password"}))


class SpawnGuardTests(unittest.TestCase):
    """The empty-password flag never meets a password source: Restic runs a password command before it refuses the pair."""

    FLAG = restore.NO_PASSWORD_FLAG

    def refused(self, command: list[str], environment: dict[str, str] | None = None) -> None:
        with self.assertRaises(ValueError) as caught:
            restore.assert_no_password_source_with_flag(command, environment)
        text = str(caught.exception).casefold()
        # restore.py's report hides a message that names the password command, the variable or DPAPI.
        for token in ("--password-command", "restic_password", "dpapi"):
            self.assertNotIn(token, text)

    def test_a_password_option_next_to_the_flag_is_refused(self) -> None:
        for option in restore.PASSWORD_SOURCE_OPTIONS:
            with self.subTest(option=option):
                self.refused(["restic", self.FLAG, option, "value"])
                self.refused(["restic", option + "=value", self.FLAG])

    def test_a_password_variable_with_a_value_next_to_the_flag_is_refused(self) -> None:
        for name in ("RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND"):
            with self.subTest(name=name):
                self.refused(["restic", self.FLAG], {name: "value"})
                self.refused(["restic", self.FLAG], {name.lower(): "value"})

    def test_empty_values_and_other_commands_are_fine(self) -> None:
        restore.assert_no_password_source_with_flag(["restic", self.FLAG], {"RESTIC_PASSWORD": ""})
        restore.assert_no_password_source_with_flag(["restic", self.FLAG], {"SystemRoot": "C:\\Windows"})
        restore.assert_no_password_source_with_flag(["restic", self.FLAG], None)
        # Backups with a password keep their password command and key, and never carry the flag.
        restore.assert_no_password_source_with_flag(["restic", "--password-command", "x"], {"RESTIC_PASSWORD": "y"})

    def test_every_way_restore_starts_restic_checks_before_starting_it(self) -> None:
        command = ["restic", self.FLAG]
        environment = {"RESTIC_PASSWORD": "value"}
        with mock.patch.object(restore.subprocess, "Popen", side_effect=AssertionError("started")), mock.patch.object(
            restore.subprocess, "run", side_effect=AssertionError("started")
        ):
            with self.assertRaises(ValueError):
                restore.run_restic_capture(command, ["snapshots"], environment, False, "snapshot query")
            with self.assertRaises(ValueError):
                restore.run_restic_json_lines_bounded(command, ["ls"], environment, False, "sample query")
            with self.assertRaises(ValueError):
                restore.run_restic_bounded(command, ["find"], environment, 10**12, 1024)
            with self.assertRaises(ValueError):
                restore.run_restic_capture(["restic", self.FLAG, "--password-command", "x"], ["snapshots"], {}, False, "snapshot query")

    def test_a_search_never_waits_for_a_password(self) -> None:
        # A search reads with its standard input closed, so a read that would need to ask for a password is refused in
        # its own words before anything starts. The search itself never asks for one (it checks first), so this is
        # the reader's own guard.
        capture = restore.bounded_restic_capture(time.monotonic() + 60)
        with mock.patch.object(restore.subprocess, "Popen", side_effect=AssertionError("started")):
            with self.assertRaises(ValueError) as caught:
                capture(["restic", "--repo", "repository"], ["snapshots", "--json"], {}, True, "snapshot query")
        self.assertEqual("File search needs Rewindle's saved key or your recovery key.", str(caught.exception))
        self.assertEqual(restore.FILE_SEARCH_KEY_MESSAGE, str(caught.exception))


class FixtureCase(unittest.TestCase):
    """A disposable backup location, configuration and stand-in Restic. Subclasses choose what the two say."""

    config_access: str | None = "no_password"  # None: a configuration without the key, as every older install has
    backups: str = "no_password"  # what the stand-in's backups are: "password" or "no_password"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="rwa-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        (self.repository / "config").write_text("immutable repository sentinel", encoding="utf-8")
        self.source = self.root / "source"
        self.source.mkdir()
        for name, content in DRILL_FILES.items():
            (self.source / name).write_bytes(content)
        self.state = self.root / "state"
        self.state.mkdir()
        self.cache = self.state / "cache"
        self.cache.mkdir()
        self.recovery_tools = self.root / "recovery-tools"
        self.recovery_tools.mkdir()
        # What an older install left behind: its saved password and its recovery key.
        self.secret_file = self.state / "repository-password.dpapi.json"
        self.secret_file.write_text("fake encrypted DPAPI blob", encoding="utf-8")
        self.password = "correct-horse-battery-staple-" + "x" * 48
        self.recovery_key = self.root / "offline-recovery-key.txt"
        self.recovery_key.write_text(f"Password: {self.password}\n", encoding="utf-8")
        self.fake = self.root / "fake_restic.py"
        self.fake.write_text(FAKE_RESTIC.replace("__TESTS__", repr(str(TESTS))), encoding="utf-8")
        self.log = self.root / "fake-restic.jsonl"
        self.config_path = self.root / "backup-config.json"
        self.config = {
            "schema_version": 1,
            "repository": str(self.repository),
            "repository_volume_serial": "00000000",
            "restic_executable": str(self.fake),
            "recovery_tools_directory": str(self.recovery_tools),
            "python_executable": sys.executable,
            "state_directory": str(self.state),
            "secret_file": str(self.secret_file),
            "recovery_key_file": str(self.recovery_key),
            "canary_file": str(self.source / "canary.txt"),
            "hostname": "TESTHOST",
            "scheduled_tag": "scheduled",
            "sources": [str(self.source)],
        }
        if self.config_access is not None:
            self.config["repository_access"] = self.config_access
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        tree: list[dict] = [{"struct_type": "snapshot", "id": NEW_ID, "time": "2026-07-21T01:00:00Z"}]
        for name, content in DRILL_FILES.items():
            path = restore.windows_snapshot_path(self.source / name)
            tree.append({"struct_type": "node", "name": name, "type": "file", "path": path, "size": len(content)})
        node = {
            "name": "notes.txt",
            "type": "file",
            "path": restore.windows_snapshot_path(self.source / "notes.txt"),
            "size": 14,
            "mtime": "2026-07-01T10:00:00.1234567+02:00",
        }
        fake_control = self.fake.with_suffix(".control.json")
        fake_control.write_text(
            json.dumps(
                {
                    "log": str(self.log),
                    "backups": self.backups,
                    "answer_12_for": None,
                    "password": self.password,
                    "repository_id": REPOSITORY_ID,
                    "snapshots": [one_snapshot(self.source)],
                    "tree": tree,
                    "find_nodes": {NEW_ID: [node]},
                    "files": {name: content.decode("latin-1") for name, content in DRILL_FILES.items()},
                }
            ),
            encoding="utf-8",
        )

    # --- helpers ---------------------------------------------------------------------------------------------------
    def answer_12_for(self, command: str, backups: str = "no_password") -> None:
        """From now on the stand-in opens the backups (they are `backups`) and answers this one Restic command with 12."""
        control_path = self.fake.with_suffix(".control.json")
        control = json.loads(control_path.read_text(encoding="utf-8"))
        control["backups"] = backups
        control["answer_12_for"] = command
        control_path.write_text(json.dumps(control), encoding="utf-8")

    def arguments(self, *extra: str) -> list[str]:
        return ["--config", str(self.config_path), "--repository", str(self.repository), "--restic", str(self.fake), *extra]

    def run_restore(self, *extra: str) -> tuple[int, str, str, SpawnRecorder]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with SpawnRecorder() as recorder, mock.patch.object(restore, "ensure_local_volume"), mock.patch.object(
            restore, "tie_children_to_this_process"
        ), redirect_stdout(stdout), redirect_stderr(stderr), warnings.catch_warnings():
            # restore.py leaves the pipe it reads a Restic's diagnostics from to the garbage collector: Python's warning
            # about that would land in the stderr these tests compare.
            warnings.simplefilter("ignore", ResourceWarning)
            result = restore.main(self.arguments(*extra))
        return result, stdout.getvalue(), stderr.getvalue(), recorder

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def leftovers(self) -> tuple[bytes, bytes]:
        return self.secret_file.read_bytes(), self.recovery_key.read_bytes()

    def drill_arguments(self, target: str = "drill-target", report: str = "drill-report.json") -> list[str]:
        return [
            "--recovery-drill",
            "--target",
            str(self.root / target),
            "--report",
            str(self.state / report),
            "--drill-canary-sha256",
            hashlib.sha256(CANARY).hexdigest(),
            "--drill-canary-bytes",
            str(len(CANARY)),
        ]

    def assert_opened_without_a_key(self, calls: list[dict], recorder: SpawnRecorder | None = None) -> None:
        self.assertTrue(calls)
        for call in calls:
            args = call["args"]
            self.assertIn("--insecure-no-password", args, args)
            for option in restore.PASSWORD_SOURCE_OPTIONS:
                self.assertFalse(any(item == option or item.startswith(option + "=") for item in args), args)
            self.assertFalse([name for name in call["environment"] if name.startswith("RESTIC_PASSWORD")], call["environment"])
        if recorder is not None:
            self.assertTrue(recorder.stdin)
            # Closed, never inherited: a Restic that asks for a password would otherwise wait for one.
            self.assertTrue(all(item == subprocess.DEVNULL for item in recorder.stdin), recorder.stdin)


class NoPasswordRestoreTests(FixtureCase):
    config_access = "no_password"
    backups = "no_password"

    def test_a_listing_opens_the_backups_with_the_flag_and_nothing_else(self) -> None:
        before = self.leftovers()
        result, stdout, stderr, recorder = self.run_restore("--list-snapshots-json")
        self.assertEqual((0, ""), (result, stderr))
        self.assertEqual([NEW_ID], [item["id"] for item in json.loads(stdout)["snapshots"]])
        self.assert_opened_without_a_key(self.calls(), recorder)
        self.assertEqual(before, self.leftovers())

    def test_a_tree_listing_and_the_human_list_carry_the_flag_too(self) -> None:
        result, stdout, stderr, recorder = self.run_restore("--list-tree-json", "--snapshot", "latest", "--tree-path", "/")
        self.assertEqual((0, ""), (result, stderr), stderr)
        self.assertEqual(NEW_ID, json.loads(stdout)["snapshot_id"])
        # The historical `restore.py --list` form starts Restic with subprocess.call.
        result, _, _, listed = self.run_restore("--list")
        self.assertEqual(0, result)
        self.assert_opened_without_a_key(self.calls(), recorder)
        self.assertTrue(all(item == subprocess.DEVNULL for item in listed.stdin), listed.stdin)
        self.assertEqual(["snapshots"], [call["args"][-1] for call in self.calls()[-1:]])

    def test_a_restore_is_verified_and_carries_the_flag(self) -> None:
        target = self.root / "restored"
        report = self.state / "restore-report.json"
        result, _, stderr, recorder = self.run_restore("--snapshot", "latest", "--target", str(target), "--report", str(report))
        self.assertEqual((0, ""), (result, stderr), stderr)
        self.assertTrue((target / "restored.txt").is_file())
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(("verified", True), (payload["result"], payload["verified"]))
        self.assertIsNone(payload["credential_source"])
        self.assert_opened_without_a_key(self.calls(), recorder)
        self.assertTrue(any("restore" in call["args"] for call in self.calls()))

    def test_a_file_search_works_without_a_saved_password_or_a_key(self) -> None:
        # A new backup without a password has no secret file at all: the search must not ask for "the protected
        # password helper or a recovery key" (restore.py used to, whenever it found neither).
        self.secret_file.unlink()
        self.recovery_key.unlink()
        result, stdout, stderr, recorder = self.run_restore(
            "--cache-dir", str(self.cache), "--no-restic-lock", "--find-json", "--find-text=notes"
        )
        self.assertEqual((0, ""), (result, stderr), stderr)
        payload = json.loads(stdout)
        self.assertEqual(("complete", ["notes.txt"]), (payload["status"], [match["name"] for match in payload["matches"]]))
        find_calls = [call for call in self.calls() if "find" in call["args"]]
        self.assertTrue(find_calls)
        self.assert_opened_without_a_key(self.calls())
        self.assertTrue(recorder.stdin and all(item == subprocess.DEVNULL for item in recorder.stdin), recorder.stdin)

    def test_a_key_file_is_refused_before_anything_runs(self) -> None:
        before = self.leftovers()
        for key in (self.recovery_key, self.root / "no-such-key.txt"):
            with self.subTest(key=key.name):
                with self.assertRaises(ValueError) as caught:
                    self.run_restore("--recovery-key-file", str(key), "--list-snapshots-json")
                self.assertEqual(NO_KEY_FILE_MESSAGE, str(caught.exception))
                self.assertEqual([], self.calls())
        self.assertEqual(before, self.leftovers())

    def test_the_drill_needs_no_key_file_and_reports_that_it_used_none(self) -> None:
        before = self.leftovers()
        result, _, stderr, recorder = self.run_restore(*self.drill_arguments())
        self.assertEqual((0, ""), (result, stderr), stderr)
        report = json.loads((self.state / "drill-report.json").read_text(encoding="utf-8"))
        self.assertEqual("recovery_key_representative", report["drill_kind"])
        self.assertEqual("none", report["credential_source"])
        self.assertEqual(("verified", True, True), (report["result"], report["verified"], report["canary_verified"]))
        self.assertEqual(2, report["sample_file_count"])
        self.assert_opened_without_a_key(self.calls(), recorder)
        # The listing the drill samples from read the backups through the flag (the stand-in lists only when it opens).
        self.assertTrue(any("ls" in call["args"] for call in self.calls()))
        self.assertTrue(any("restore" in call["args"] for call in self.calls()))
        self.assertEqual(before, self.leftovers())

    def test_a_drill_with_a_key_file_is_refused_in_the_new_words(self) -> None:
        with self.assertRaises(ValueError) as caught:
            self.run_restore(*self.drill_arguments(), "--recovery-key-file", str(self.recovery_key))
        self.assertEqual(NO_KEY_FILE_MESSAGE, str(caught.exception))
        self.assertEqual([], self.calls())

    def test_the_new_messages_pass_restores_own_filters_and_the_engines(self) -> None:
        for message in (NO_KEY_FILE_MESSAGE, "unsupported repository_access"):
            with self.subTest(message=message):
                self.assertEqual(message, restore.safe_report_error(ValueError(message)))
                # Manage-Restore.ps1's Get-SanitizedError hides a message that matches this.
                self.assertIsNone(re.search(r"(?i)(password-command|RESTIC_PASSWORD|dpapi)", message))
                # The words the engine's retention and readiness filters hide (restic_common's table, design section 8).
                for word in ("password", "dpapi", "restic_"):
                    self.assertNotIn(word, message.casefold())


class NoStartWithAPasswordSourceTests(FixtureCase):
    """main() makes one check, before any Restic starts, that the command and environment every start is given have no
    password source next to the empty-password flag. The listing, the bare list and the restore start Restic with
    subprocess.call, which has no guard of its own, so this check is theirs; nothing in restore.py puts a password
    variable into that environment, so a test has to (restic_child_environment is where one would come from)."""

    config_access = "no_password"
    backups = "no_password"

    def test_a_password_variable_in_the_environment_starts_no_restic_at_all(self) -> None:
        plain = restore.restic_child_environment
        for name in restore.PASSWORD_SOURCE_VARIABLES:
            for label, arguments in (
                ("the human list", ("--list",)),
                ("no action", ()),
                ("the list of backups", ("--list-snapshots-json",)),
                ("a folder", ("--list-tree-json", "--snapshot", "latest")),
                ("a search", ("--cache-dir", str(self.cache), "--no-restic-lock", "--find-json", "--find-text=notes")),
                ("a restore", ("--snapshot", "latest", "--target", str(self.root / "restored"))),
                ("the drill", tuple(self.drill_arguments())),
            ):
                with self.subTest(name=name, start=label):
                    self.log.unlink(missing_ok=True)
                    with mock.patch.object(restore, "restic_child_environment", lambda: {**plain(), name: "value"}):
                        with self.assertRaises(ValueError) as caught:
                            self.run_restore(*arguments)
                    self.assertEqual(restore.NO_KEY_SOURCE_MESSAGE, str(caught.exception))
                    self.assertEqual([], self.calls())

    def test_the_same_environment_without_a_password_variable_starts_restic(self) -> None:
        for arguments in (("--list",), ()):
            with self.subTest(arguments=arguments):
                result, _, _, _ = self.run_restore(*arguments)
                self.assertEqual(0, result)
        self.assertEqual(2, len(self.calls()))
        self.assert_opened_without_a_key(self.calls())


class BackupsThatNowNeedAPasswordTests(FixtureCase):
    """Someone added a password outside Rewindle: the configuration still says no_password.

    Every way restore.py reads the backups says so in NOW_ASKS_FOR_A_PASSWORD, never as "Restic ... failed with exit code 12".
    The stand-in's backups ask for a password (it answers every command with 12), or open and answer one command with 12.
    """

    config_access = "no_password"
    backups = "password"

    def refused_plainly(self, operation: str, *arguments: str) -> restore.ResticReadError:
        # Restic answers 12 and has stdin closed, so nothing waits for a password.
        with self.assertRaises(restore.ResticReadError) as caught:
            self.run_restore(*arguments)
        error = caught.exception
        self.assertEqual((operation, 12), (error.operation, error.returncode))
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, str(error))
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, restore.safe_report_error(error))
        self.assertNotIn("exit code", str(error))
        # No key was tried: the flag was the only credential on the command.
        self.assertTrue(self.calls())
        for call in self.calls():
            self.assertIn("--insecure-no-password", call["args"])
            self.assertNotIn("--password-command", call["args"])
            self.assertFalse([name for name in call["environment"] if name.startswith("RESTIC_PASSWORD")])
        return error

    def report(self, name: str) -> dict:
        return json.loads((self.state / name).read_text(encoding="utf-8"))

    def test_listing_the_backups_says_so_plainly(self) -> None:
        self.refused_plainly("repository query", "--list-snapshots-json")

    def test_the_list_of_backups_itself_says_so_plainly(self) -> None:
        self.answer_12_for("snapshots")
        self.refused_plainly("snapshot query", "--list-snapshots-json")
        # The repository query went through, so this is the list of backups itself.
        self.assertEqual(["cat", "snapshots"], [next(word for word in ("cat", "snapshots") if word in call["args"]) for call in self.calls()])

    def test_opening_a_folder_says_so_plainly(self) -> None:
        self.refused_plainly("repository query", "--list-tree-json", "--snapshot", "latest", "--tree-path", "/")
        self.answer_12_for("ls")
        self.refused_plainly("tree query", "--list-tree-json", "--snapshot", "latest", "--tree-path", "/")

    def test_finding_a_file_says_so_plainly(self) -> None:
        find = ("--cache-dir", str(self.cache), "--no-restic-lock", "--find-json", "--find-text=notes")
        # The list of backups it searches (read with the search's own time limit) ...
        self.refused_plainly("snapshot query", *find)
        # ... and the search itself.
        self.answer_12_for("find")
        self.refused_plainly("file search", *find)

    def test_restoring_says_so_plainly_in_the_report_too(self) -> None:
        target = self.root / "restored"
        arguments = ("--snapshot", "latest", "--target", str(target), "--report", str(self.state / "restore-report.json"))
        self.refused_plainly("snapshot query", *arguments)
        report = self.report("restore-report.json")
        self.assertEqual(("error", False, NOW_ASKS_FOR_A_PASSWORD), (report["result"], report["verified"], report["error"]))
        self.assertFalse(target.exists())

    def test_the_drill_says_so_plainly_in_the_report_too(self) -> None:
        self.refused_plainly("snapshot query", *self.drill_arguments())
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, self.report("drill-report.json")["error"])
        # The drill reads the backup's folders one by one, through its own bounded reader.
        self.answer_12_for("ls")
        self.refused_plainly("bounded representative sample query", *self.drill_arguments(report="drill-report-2.json"))
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, self.report("drill-report-2.json")["error"])

    def test_a_restore_that_restic_itself_refuses_says_so_plainly(self) -> None:
        # The backups opened for every query, and then Restic answered the restore itself with 12: nothing was restored.
        self.answer_12_for("restore")
        target = self.root / "restored"
        arguments = ("--snapshot", "latest", "--target", str(target), "--report", str(self.state / "restore-report.json"))
        result, _, stderr, _ = self.run_restore(*arguments)
        self.assertEqual(12, result)
        report = self.report("restore-report.json")
        self.assertEqual(("partial", 12, NOW_ASKS_FOR_A_PASSWORD), (report["result"], report["restic_exit_code"], report["error"]))
        self.assertNotIn("exit code", report["error"])
        self.assertIn("RESTORE INCOMPLETE", stderr)
        # The same for the drill's own restore.
        result, _, _, _ = self.run_restore(*self.drill_arguments())
        self.assertEqual(12, result)
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, self.report("drill-report.json")["error"])

    def test_run_as_a_program_its_last_line_is_the_sentence_alone(self) -> None:
        # The protected manager passes the sentence on only when it is the whole of this last line (Manage-Restore.ps1).
        completed = subprocess.run(
            [sys.executable, "-I", str(SOURCE_ROOT / "restore.py"), *self.arguments("--list-snapshots-json")],
            capture_output=True,
            text=True,
            timeout=120,
            stdin=subprocess.DEVNULL,
        )
        self.assertEqual(1, completed.returncode, completed.stderr)
        self.assertEqual(["RESTORE FAILED: " + NOW_ASKS_FOR_A_PASSWORD], completed.stderr.strip().splitlines())
        self.assertEqual("", completed.stdout)


class ResticReadErrorWordsTests(unittest.TestCase):
    """Only a start without a password that Restic answered with 12 gets the sentence; every other failure keeps its words."""

    FLAG = restore.NO_PASSWORD_FLAG

    def test_the_sentence_is_for_exit_code_12_of_a_command_without_a_password(self) -> None:
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, restore.NOW_ASKS_FOR_A_PASSWORD_MESSAGE)
        self.assertEqual(12, restore.RESTIC_WRONG_PASSWORD_EXIT)
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, str(restore.ResticReadError("snapshot query", 12, ["restic", self.FLAG])))

    def test_everything_else_keeps_the_exit_code_in_its_words(self) -> None:
        for returncode, command in (
            (12, ["restic", "--password-command", "x"]),  # backups with a password
            (12, ["restic"]),
            (12, None),
            (12, []),
            (1, ["restic", self.FLAG]),
            (130, ["restic", self.FLAG]),
        ):
            with self.subTest(returncode=returncode, command=command):
                error = restore.ResticReadError("tree query", returncode, command)
                self.assertEqual(f"Restic tree query failed with exit code {returncode}", str(error))
                self.assertEqual(("tree query", returncode), (error.operation, error.returncode))


class PasswordBackupsAreUnchangedTests(FixtureCase):
    """A configuration without the key (every older install, the owner's included) behaves exactly as before."""

    config_access = None
    backups = "password"

    def test_a_listing_with_the_saved_password_uses_the_command_and_never_the_flag(self) -> None:
        result, _, stderr, recorder = self.run_restore("--list-snapshots-json")
        self.assertEqual((0, ""), (result, stderr))
        self.assertTrue(self.calls())
        for call in self.calls():
            self.assertIn("--password-command", call["args"])
            self.assertNotIn("--insecure-no-password", call["args"])
            self.assertNotIn("RESTIC_PASSWORD", call["environment"])
        self.assertTrue(all(item == subprocess.DEVNULL for item in recorder.stdin), recorder.stdin)

    def test_the_recovery_key_is_still_the_password_and_a_drill_still_says_recovery_key(self) -> None:
        result, _, stderr, recorder = self.run_restore("--recovery-key-file", str(self.recovery_key), *self.drill_arguments())
        self.assertEqual((0, ""), (result, stderr), stderr)
        report = json.loads((self.state / "drill-report.json").read_text(encoding="utf-8"))
        self.assertEqual(("recovery_key_representative", "recovery_key"), (report["drill_kind"], report["credential_source"]))
        self.assertTrue(report["verified"])
        for call in self.calls():
            self.assertNotIn("--insecure-no-password", call["args"])
            self.assertNotIn("--password-command", call["args"])
            self.assertIn("RESTIC_PASSWORD", call["environment"])
        self.assertTrue(all(item == subprocess.DEVNULL for item in recorder.stdin), recorder.stdin)

    def test_a_drill_without_a_key_file_is_still_refused_in_the_same_words_and_exit(self) -> None:
        with self.assertRaises(ValueError) as caught:
            self.run_restore(*self.drill_arguments())
        self.assertEqual(DRILL_KEY_FILE_MESSAGE, str(caught.exception))
        self.assertEqual([], self.calls())
        # Run as a program, as the protected manager does: one line on stderr and exit code 1, no report.
        completed = subprocess.run(
            [sys.executable, "-I", str(SOURCE_ROOT / "restore.py"), *self.arguments(*self.drill_arguments())],
            capture_output=True,
            text=True,
            timeout=120,
            stdin=subprocess.DEVNULL,
        )
        self.assertEqual(1, completed.returncode)
        self.assertEqual(f"RESTORE FAILED: {DRILL_KEY_FILE_MESSAGE}", completed.stderr.strip())
        self.assertFalse((self.state / "drill-report.json").exists())

    def test_a_wrong_key_or_a_refused_command_still_says_the_exit_code(self) -> None:
        # Only backups opened without a password say that they now ask for one; these keep the words they always had.
        wrong = self.root / "wrong-key.txt"
        wrong.write_text(f"Password: {'w' * 48}\n", encoding="utf-8")
        with self.assertRaises(restore.ResticReadError) as caught:
            self.run_restore("--recovery-key-file", str(wrong), "--list-snapshots-json")
        self.assertEqual("Restic repository query failed with exit code 12", str(caught.exception))
        self.assertEqual("Restic repository query failed with exit code 12", restore.safe_report_error(caught.exception))
        self.answer_12_for("snapshots", backups="password")
        with self.assertRaises(restore.ResticReadError) as caught:
            self.run_restore("--list-snapshots-json")
        self.assertEqual("Restic snapshot query failed with exit code 12", str(caught.exception))
        self.answer_12_for("find", backups="password")
        with self.assertRaises(restore.ResticReadError) as caught:
            self.run_restore("--cache-dir", str(self.cache), "--no-restic-lock", "--find-json", "--find-text=notes")
        self.assertEqual("Restic file search failed with exit code 12", str(caught.exception))
        self.answer_12_for("restore", backups="password")
        report_path = self.state / "restore-report.json"
        result, _, _, _ = self.run_restore("--snapshot", "latest", "--target", str(self.root / "restored"), "--report", str(report_path))
        self.assertEqual(12, result)
        self.assertEqual(
            "Restic restore failed with exit code 12; the alternate target was retained for inspection",
            json.loads(report_path.read_text(encoding="utf-8"))["error"],
        )

    def test_a_password_configuration_that_names_its_mode_behaves_the_same(self) -> None:
        explicit = dict(self.config, repository_access="password")
        self.config_path.write_text(json.dumps(explicit), encoding="utf-8")
        result, _, stderr, _ = self.run_restore("--list-snapshots-json")
        self.assertEqual((0, ""), (result, stderr))
        for call in self.calls():
            self.assertIn("--password-command", call["args"])
            self.assertNotIn("--insecure-no-password", call["args"])

    def test_a_key_file_without_a_drill_still_works_for_a_listing(self) -> None:
        result, _, stderr, _ = self.run_restore("--recovery-key-file", str(self.recovery_key), "--list-snapshots-json")
        self.assertEqual((0, ""), (result, stderr))
        self.assertTrue(all("RESTIC_PASSWORD" in call["environment"] for call in self.calls()))


class FilesThatSpeakForThemselvesTests(unittest.TestCase):
    """Static checks of the files this change touches (the behaviour is in the tests above and in Test-ManageRestore.ps1)."""

    MANAGER = (SOURCE_ROOT / "Manage-Restore.ps1").read_text(encoding="utf-8")
    RESTORE = (SOURCE_ROOT / "restore.py").read_text(encoding="utf-8")
    RESTORE_SUITE = (TESTS / "Test-ManageRestore.ps1").read_text(encoding="utf-8")
    RETENTION_SUITE = (TESTS / "Test-ManageRetention.ps1").read_text(encoding="utf-8")
    RULES = re.compile(
        r"  // ---- Restic 0\.19\.1's rules for --insecure-no-password.*?  // ---- end of the access rules ----\n",
        re.DOTALL,
    )

    def function_text(self, text: str, name: str) -> str:
        start = text.index(f"function {name} {{")
        return text[start : text.index("\n}\n", start) + 3]

    def test_the_manager_reads_the_field_with_the_shared_function_and_never_by_dotted_access(self) -> None:
        self.assertEqual(GET_REPOSITORY_ACCESS, self.function_text(self.MANAGER, "Get-RepositoryAccess"))
        # `$config.repository_access` throws under StrictMode on every older configuration.
        self.assertEqual([], re.findall(r"[$\w)\]]\.repository_access\b", self.MANAGER))

    def test_restore_py_reads_the_field_only_through_its_rule(self) -> None:
        self.assertEqual(1, len(re.findall(r"""config(?:\[|\.get\()["']repository_access["']""", self.RESTORE)))

    def test_the_manager_looks_at_the_recovery_key_only_for_backups_with_a_password(self) -> None:
        calls = re.findall(r"^( *)(.*Assert-RecoveryKeyAcl -Path.*)$", self.MANAGER, re.MULTILINE)
        self.assertEqual(1, len(calls))
        text = self.MANAGER
        call = text.index("Assert-RecoveryKeyAcl -Path (")
        guard = text.rfind("if (", 0, call)
        self.assertIn("$repositoryAccess -ceq 'password'", text[guard:call])

    def test_the_plain_progress_texts_are_there(self) -> None:
        self.assertIn("'Restoring the restore test file and a small sample of your files.'", self.MANAGER)
        self.assertIn("'Restore drill completed, verified, and was recorded.'", self.MANAGER)
        # Password backups keep their texts.
        self.assertIn("'Restoring the canary and a bounded representative sample with the recovery key.'", self.MANAGER)
        self.assertIn("'Recovery-key restore drill completed, verified, and was recorded.'", self.MANAGER)

    def test_the_manager_has_the_same_sentence(self) -> None:
        match = re.search(r"^\$backupsNowAskForAPasswordMessage = '(.*)'$", self.MANAGER, re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, match.group(1).replace("''", "'"))

    def test_no_filter_between_restore_and_the_dashboard_hides_or_rewrites_the_sentence(self) -> None:
        # restore.py's report: the sentence as it is, short enough, nothing but printable characters.
        error = restore.ResticReadError("snapshot query", 12, [restore.NO_PASSWORD_FLAG])
        self.assertEqual(NOW_ASKS_FOR_A_PASSWORD, restore.safe_report_error(error))
        self.assertLess(len(NOW_ASKS_FOR_A_PASSWORD), restore.MAX_REPORT_STRING)
        self.assertTrue(all(character.isprintable() for character in NOW_ASKS_FOR_A_PASSWORD))
        # The manager's Get-SanitizedError hides a message that names the password command, the variable or DPAPI.
        sanitizer = re.search(r"\$result -match '([^']+)'", self.function_text(self.MANAGER, "Get-SanitizedError"))
        self.assertIsNotNone(sanitizer)
        self.assertIsNone(re.search(sanitizer.group(1), NOW_ASKS_FOR_A_PASSWORD))
        # The dashboard's two places that choose its own words for a backend message (the rest is shown as it came): every phrase
        # they look for is absent from the sentence, so neither one rewrites it.
        lowered = NOW_ASKS_FOR_A_PASSWORD.casefold()
        for path, method in (
            (SOURCE_ROOT / "dashboard" / "RestoreManager.cs", "private static string PlainBackendMessage("),
            (SOURCE_ROOT / "dashboard" / "DashboardWindow.RestoreSearch.cs", "private static string DescribeRestoreFlowSearchFailure("),
        ):
            text = path.read_text(encoding="utf-8")
            start = text.index(method)
            phrases = re.findall(r'Contains\("([^"]+)"\)', text[start : text.index("\n        }\n", start)])
            self.assertGreater(len(phrases), 3, method)
            for phrase in phrases:
                self.assertNotIn(phrase.casefold(), lowered, f"{method} would rewrite the sentence at {phrase!r}")

    def test_both_suites_stand_in_for_restic_with_the_same_three_rules(self) -> None:
        restore_rules = self.RULES.findall(self.RESTORE_SUITE)
        retention_rules = self.RULES.findall(self.RETENTION_SUITE)
        self.assertEqual(1, len(restore_rules))
        self.assertEqual(restore_rules, retention_rules)
        rules = restore_rules[0]
        for text in (
            "FAKE_REPOSITORY_ACCESS",
            "--insecure-no-password",
            "--password-command",
            "--password-file",
            "--new-password-file",
            "RESTIC_PASSWORD_FILE",
            "RESTIC_PASSWORD_COMMAND",
            "Fatal: --insecure-no-password must not be specified together with providing a password via a cli option or "
            "environment variable",
            "Fatal: an empty password is not allowed by default. Pass the flag `--insecure-no-password` to restic to disable "
            "this check",
            "Fatal: wrong password or no key found",
        ):
            self.assertIn(text, rules)
        for source in (self.RESTORE_SUITE, self.RETENTION_SUITE):
            self.assertIn("int refused = Access(args);", source)
            self.assertLess(source.index("File.AppendAllText(log"), source.index("int refused = Access(args);"))

    def test_the_restore_suite_lists_a_drill_when_the_key_is_the_flag_or_a_password(self) -> None:
        self.assertIn(
            'if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("RESTIC_PASSWORD")) || args.Contains("--insecure-no-password")) {',
            self.RESTORE_SUITE,
        )

    def test_the_files_stay_ascii_with_lf_endings(self) -> None:
        for path in (
            SOURCE_ROOT / "Manage-Restore.ps1",
            TESTS / "Test-ManageRestore.ps1",
            TESTS / "Test-ManageRetention.ps1",
            SOURCE_ROOT / "restore.py",
        ):
            data = path.read_bytes()
            self.assertNotIn(b"\r", data, path.name)
            if path.suffix == ".ps1":
                self.assertEqual(b"", bytes(byte for byte in data if byte > 127), path.name)


def pinned_restic_present() -> bool:
    if not RESTIC.is_file():
        return False
    release = json.loads((SOURCE_ROOT / "restic-release.json").read_text(encoding="utf-8"))
    return hashlib.sha256(RESTIC.read_bytes()).hexdigest() == release["executable_sha256"]


@unittest.skipUnless(
    os.name == "nt" and pinned_restic_present(),
    "needs the release build's pinned restic.exe (run build\\Build-Release.ps1)",
)
class PinnedResticNoPasswordRestoreTests(unittest.TestCase):
    """restore.py and the real Restic 0.19.1, in a throwaway backup made without a password."""

    def test_every_way_restore_opens_the_backups_without_a_key(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rwa-real-") as text:
            root = Path(text)
            source = root / "source"
            source.mkdir()
            for name, content in {
                "canary.txt": b"canary\n",
                "Budget 2026.xlsx": b"fixture, budget\n",
                "notes.txt": b"fixture notes\n",
                "plain.txt": b"plain\n",
            }.items():
                (source / name).write_bytes(content)
            repository = root / "repository"
            state = root / "state"
            state.mkdir()
            cache = state / "cache"
            cache.mkdir()
            environment = {name: os.environ[name] for name in ("SYSTEMROOT", "TEMP", "TMP") if name in os.environ}
            common = [str(RESTIC), "--repo", str(repository), "--no-cache", "--insecure-no-password"]
            for arguments in (["init"], ["backup", str(source), "--host", "TESTHOST", "--tag", "scheduled"]):
                finished = subprocess.run(
                    [*common, *arguments],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=180,
                    env=environment,
                    stdin=subprocess.DEVNULL,
                )
                self.assertEqual(0, finished.returncode, finished.stderr)
            # An older install's files, which a backup without a password must leave alone and never use.
            secret = state / "repository-password.dpapi.json"
            secret.write_text("fake encrypted DPAPI blob", encoding="utf-8")
            config_path = root / "backup-config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "repository": str(repository),
                        "repository_volume_serial": "00000000",
                        "restic_executable": str(RESTIC),
                        "python_executable": sys.executable,
                        "state_directory": str(state),
                        "secret_file": str(secret),
                        "recovery_key_file": str(root / "RecoveryKey.txt"),
                        "canary_file": str(source / "canary.txt"),
                        "hostname": "TESTHOST",
                        "scheduled_tag": "scheduled",
                        "sources": [str(source)],
                        "repository_access": "no_password",
                    }
                ),
                encoding="utf-8",
            )
            base = ["--config", str(config_path), "--repository", str(repository), "--restic", str(RESTIC)]
            inherited = {name: value for name, value in os.environ.items() if not name.upper().startswith("RESTIC_")}

            def run(*extra: str) -> tuple[int, str, str]:
                stdout, stderr = io.StringIO(), io.StringIO()
                with mock.patch.dict(os.environ, inherited, clear=True), mock.patch.object(
                    restore, "ensure_local_volume"
                ), mock.patch.object(restore, "tie_children_to_this_process"), redirect_stdout(stdout), redirect_stderr(stderr):
                    result = restore.main([*base, *extra])
                return result, stdout.getvalue(), stderr.getvalue()

            result, stdout, stderr = run("--list-snapshots-json")
            self.assertEqual(0, result, stderr)
            self.assertEqual(1, len(json.loads(stdout)["snapshots"]))

            result, stdout, stderr = run("--cache-dir", str(cache), "--no-restic-lock", "--find-json", "--find-text=budget")
            self.assertEqual(0, result, stderr)
            self.assertEqual(["Budget 2026.xlsx"], [match["name"] for match in json.loads(stdout)["matches"]])

            report = state / "restore-report.json"
            result, _, stderr = run("--snapshot", "latest", "--source", str(source), "--target", str(root / "restored"), "--report", str(report))
            self.assertEqual(0, result, stderr)
            self.assertEqual("verified", json.loads(report.read_text(encoding="utf-8"))["result"])
            self.assertEqual(b"fixture notes\n", (root / "restored" / "notes.txt").read_bytes())

            drill_report = state / "drill-report.json"
            result, _, stderr = run(
                "--recovery-drill",
                "--target",
                str(root / "drill"),
                "--report",
                str(drill_report),
                "--drill-canary-sha256",
                hashlib.sha256(b"canary\n").hexdigest(),
                "--drill-canary-bytes",
                "7",
            )
            self.assertEqual(0, result, stderr)
            evidence = json.loads(drill_report.read_text(encoding="utf-8"))
            self.assertEqual(("recovery_key_representative", "none"), (evidence["drill_kind"], evidence["credential_source"]))
            self.assertEqual(("verified", True, True), (evidence["result"], evidence["verified"], evidence["canary_verified"]))
            self.assertGreaterEqual(evidence["sample_file_count"], 2)
            self.assertEqual(b"fake encrypted DPAPI blob", secret.read_bytes())
            self.assertFalse((root / "RecoveryKey.txt").exists())


if __name__ == "__main__":
    unittest.main()
