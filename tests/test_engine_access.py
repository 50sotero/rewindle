"""Backups with or without a password: what a backup run and a dry run record and report (src/backup.py, src/dry_run.py).

Restic is never started. The fakes follow the rules in tests/restic_access.py, so a run only succeeds when every Restic
command it built carries --insecure-no-password exactly when the backups have no password, and never next to a password
option. The real restic_base builds the commands.
"""

from __future__ import annotations

import argparse
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup  # noqa: E402
import dry_run  # noqa: E402
import initialize_repository  # noqa: E402
import restic_common  # noqa: E402
import retention  # noqa: E402
import test_generation_parent as generation  # noqa: E402
from restic_access import NO_PASSWORD_FLAG, WRONG_PASSWORD, restic_access_result  # noqa: E402


SANITIZED_WORDS = ("password", "dpapi", "restic_")
MISMATCH_TEXT = "these backups now ask for a key that Rewindle doesn't have"
PASSWORD_OPTIONS = ("--password-command", "--password-file", "--new-password-file")


def assert_credential_arguments(test: unittest.TestCase, command: list[str], access: str) -> None:
    if access == "no_password":
        test.assertEqual(1, command.count(NO_PASSWORD_FLAG), command)
        test.assertFalse(
            any(argument.startswith(PASSWORD_OPTIONS) for argument in command), f"a password option next to the flag: {command}"
        )
    else:
        test.assertNotIn(NO_PASSWORD_FLAG, command)
        test.assertEqual(1, command.count("--password-command"), command)


class AccessRun(generation.GenerationRun):
    """backup._run_locked with the real restic_base and a fake Restic that opens its backups only the right way."""

    def __init__(self, root: Path, *, access: str | None = None, opens_as: str = "password") -> None:
        super().__init__(root, generation=1)
        self.config["python_executable"] = sys.executable
        self.config["secret_file"] = str(root / "state" / "secret.json")
        if access is not None:
            self.config["repository_access"] = access
        self.opens_as = opens_as
        self.commands: list[list[str]] = []
        self.cat_answer: tuple[int, str] | None = None  # (exit code, stderr) for `cat config`, whatever the rules say

    def run(self, *, real_preflight: bool = False) -> int:
        listings = 0

        def refusal(command: list[str]):
            return restic_access_result(command, {}, self.opens_as)

        def fake_capture(command, **_kwargs):
            nonlocal listings
            self.commands.append(list(command))
            if "cat" in command and self.cat_answer is not None:
                return subprocess.CompletedProcess(command, self.cat_answer[0], "", self.cat_answer[1])
            refused = refusal(command)
            if refused is not None:
                return subprocess.CompletedProcess(command, refused[0], "", refused[1])
            if "cat" in command:
                return subprocess.CompletedProcess(
                    command, 0, json.dumps({"id": generation.REPOSITORY_ID, "version": 2}), ""
                )
            listings += 1
            payload = list(self.listed)
            if listings > 1:
                payload.append(
                    generation.listed_snapshot(
                        generation.NEW_SNAPSHOT, 1, self.sources, time="2026-11-10T02:00:00Z"
                    )
                )
            return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

        def fake_stream(command, _log, on_line=None, **_kwargs):
            self.commands.append(list(command))
            refused = refusal(command)
            if refused is not None:
                return refused[0]
            if "backup" not in command:
                raise AssertionError(f"unexpected streamed Restic command: {command}")
            on_line(
                json.dumps(
                    {
                        "message_type": "summary",
                        "snapshot_id": generation.NEW_SNAPSHOT,
                        "total_files_processed": 1,
                        "total_bytes_processed": 7,
                        "files_new": 0,
                        "files_changed": 0,
                        "files_unmodified": 1,
                        "data_added": 0,
                    }
                )
            )
            return 0

        ready = {
            "schema_version": 1,
            "policy": "strict",
            "status": "ready",
            "sources": [generation.source_record(path) for path in self.sources],
            "failures": [],
        }
        with ExitStack() as patches:
            for name, value in (
                ("validate_repository_volume", None),
                ("ensure_free_space", 1),
                ("preflight_sources", ready),
                ("verify_canary", {"verified": True}),
                ("process_start_filetime", "133733333333333333"),
            ):
                patches.enter_context(mock.patch.object(backup, name, return_value=value))
            patches.enter_context(mock.patch.object(backup, "run_capture", side_effect=fake_capture))
            patches.enter_context(mock.patch.object(backup, "stream_command", side_effect=fake_stream))
            patches.enter_context(redirect_stderr(io.StringIO()))
            return backup._run_locked(argparse.Namespace(tag=None, scheduled=True), self.config)


class BackupRecordsTests(unittest.TestCase):
    def run_backup(self, **arguments) -> AccessRun:
        folder = tempfile.TemporaryDirectory(prefix="engine-access-")
        self.addCleanup(folder.cleanup)
        run = AccessRun(Path(folder.name), **arguments)
        self.assertEqual(0, run.run())
        return run

    def test_status_and_last_success_say_how_the_backups_open(self) -> None:
        # An older configuration has no such key: it is a backup with a password, and says so.
        cases = (
            ("an older configuration", None, "password", "password"),
            ("a backup with a password", "password", "password", "password"),
            ("a backup without a password", "no_password", "no_password", "no_password"),
        )
        for label, configured, opens_as, expected in cases:
            with self.subTest(label):
                run = self.run_backup(access=configured, opens_as=opens_as)
                for name in ("status.json", "last-success.json"):
                    self.assertEqual(expected, run.document(name)["repository_access"], name)
                self.assertEqual("local_ntfs", run.document("status.json")["repository_storage_mode"])
                self.assertEqual("success", run.document("status.json")["state"])

    def test_every_restic_command_of_a_backup_without_a_password_carries_the_flag_and_no_password_option(self) -> None:
        run = self.run_backup(access="no_password", opens_as="no_password")
        verbs = {word for command in run.commands for word in command if word in ("cat", "snapshots", "backup")}
        self.assertEqual({"cat", "snapshots", "backup"}, verbs)
        for command in run.commands:
            assert_credential_arguments(self, command, "no_password")
            # The engine's own rule for what its Restic children may be given accepts every one.
            restic_common.restic_child_environment(command)

    def test_every_restic_command_of_a_backup_with_a_password_is_what_it_always_was(self) -> None:
        for configured in (None, "password"):
            with self.subTest(configured=configured):
                run = self.run_backup(access=configured, opens_as="password")
                self.assertTrue(run.commands)
                for command in run.commands:
                    assert_credential_arguments(self, command, "password")


class AuthenticationRefusalTests(unittest.TestCase):
    def run_refused(self, *, access: str | None, opens_as: str = "password", answer=None) -> tuple[AccessRun, dict]:
        folder = tempfile.TemporaryDirectory(prefix="engine-access-refused-")
        self.addCleanup(folder.cleanup)
        run = AccessRun(Path(folder.name), access=access, opens_as=opens_as)
        run.cat_answer = answer
        self.assertEqual(1, run.run())
        return run, run.document("status.json")

    def test_backups_without_a_password_that_now_ask_for_one_are_a_mismatch_not_a_drive_problem(self) -> None:
        # They were replaced, or given a password outside Rewindle: Restic answers exit 12 (rule 3 of the shared fake).
        run, status = self.run_refused(access="no_password", opens_as="password")

        self.assertEqual("failed", status["state"])
        self.assertEqual("repository_authentication", status["failure_phase"])
        self.assertEqual("repository_access_mismatch", status["failure_code"])
        self.assertEqual(MISMATCH_TEXT, status["failure"])
        self.assertNotIn(WRONG_PASSWORD, json.dumps(status))
        self.assertEqual(1, len(run.commands))
        self.assertFalse(any("backup" in command for command in run.commands))
        failure_events = [event for event in run.log_events() if event.get("wrapper_event") == "failure"]
        self.assertEqual(["repository_access_mismatch"], [event["failure_code"] for event in failure_events])
        self.assertEqual([MISMATCH_TEXT], [event["error"] for event in failure_events])

    def test_the_mismatch_says_nothing_the_log_filters_hide(self) -> None:
        for word in SANITIZED_WORDS:
            self.assertNotIn(word, MISMATCH_TEXT.lower())
        self.assertEqual(MISMATCH_TEXT, retention.sanitize(MISMATCH_TEXT))
        for line in (initialize_repository.MISMATCH_MESSAGE, initialize_repository.UNREADABLE_MESSAGE):
            self.assertEqual(line, retention.sanitize(line))
        self.assertEqual("restic init failed with exit 1", retention.sanitize("restic init failed with exit 1"))

    def test_another_failure_to_open_backups_without_a_password_keeps_its_code_and_text(self) -> None:
        for exit_code in (1, 2, 10, 130):
            with self.subTest(exit=exit_code):
                _run, status = self.run_refused(access="no_password", opens_as="no_password", answer=(exit_code, "Fatal: something"))
                self.assertEqual("repository_authentication_failed", status["failure_code"])
                self.assertEqual("could not authenticate repository identity: Fatal: something", status["failure"])

    def test_backups_with_a_password_that_answer_exit_12_are_what_they_always_were(self) -> None:
        for configured in (None, "password"):
            with self.subTest(configured=configured):
                _run, status = self.run_refused(access=configured, opens_as="password", answer=(12, WRONG_PASSWORD))
                self.assertEqual("repository_authentication_failed", status["failure_code"])
                self.assertEqual(f"could not authenticate repository identity: {WRONG_PASSWORD}", status["failure"])

    def test_authenticate_repository_id_raises_the_mismatch_only_for_exit_12_without_a_password(self) -> None:
        def authenticate(config: dict, exit_code: int):
            completed = subprocess.CompletedProcess(["restic"], exit_code, "", WRONG_PASSWORD)
            with mock.patch.object(backup, "restic_base", return_value=["restic"]), mock.patch.object(
                backup, "run_capture", return_value=completed
            ):
                return backup.authenticate_repository_id(config, None)

        with self.assertRaises(restic_common.RepositoryAccessMismatch) as raised:
            authenticate({"repository": r"D:\Repository", "repository_access": "no_password"}, 12)
        self.assertEqual(MISMATCH_TEXT, str(raised.exception))
        self.assertIsInstance(raised.exception, restic_common.EngineFailure)
        self.assertEqual("repository_access_mismatch", raised.exception.failure_code)
        for config in ({"repository": r"D:\Repository"}, {"repository": r"D:\Repository", "repository_access": "password"}):
            with self.subTest(config=config):
                with self.assertRaises(RuntimeError) as plain:
                    authenticate(config, 12)
                self.assertNotIsInstance(plain.exception, restic_common.RepositoryAccessMismatch)
                self.assertIn(WRONG_PASSWORD, str(plain.exception))
        with self.assertRaises(RuntimeError) as other:
            authenticate({"repository": r"D:\Repository", "repository_access": "no_password"}, 1)
        self.assertNotIsInstance(other.exception, restic_common.RepositoryAccessMismatch)


class DryRunTests(unittest.TestCase):
    def load_config(self, root: Path, **extra) -> dict:
        source = root / "source"
        source.mkdir(exist_ok=True)
        restic = root / "restic.exe"
        restic.write_bytes(b"test fixture; not an executable")
        excludes = root / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8")
        canary = root / "canary.txt"
        canary.write_text("ResticBackuper test canary\n", encoding="utf-8")
        document = {
            "schema_version": 1,
            "plan_id": "11111111-1111-4111-8111-111111111111",
            "config_generation": 1,
            "repository": str(root / "repository"),
            "repository_volume_serial": "00000000",
            "restic_executable": str(restic),
            "recovery_tools_directory": str(root / "recovery-tools"),
            "python_executable": sys.executable,
            "state_directory": str(root / "state"),
            "secret_file": str(root / "state" / "password.test.json"),
            "recovery_key_file": str(root / "recovery.test.txt"),
            "exclude_file": str(excludes),
            "canary_file": str(canary),
            "hostname": "RESTICBACKUPER-TEST",
            "scheduled_tag": "scheduled-test",
            "cloud_placeholder_policy": "strict",
            "sources": [str(source)],
            "source_identities": {str(source): {"expected_volume_serial": "00000000"}},
        }
        document.update(extra)
        path = root / "backup-config.test.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return restic_common.load_config(path, require_repository=False)

    def dry_run(self, access: str | None, opens_as: str) -> tuple[dict, list[list[str]]]:
        folder = tempfile.TemporaryDirectory(prefix="engine-access-dry-run-")
        self.addCleanup(folder.cleanup)
        root = Path(folder.name).resolve()
        config = self.load_config(root, **({} if access is None else {"repository_access": access}))
        commands: list[list[str]] = []

        def fake_stream(command, _log, on_line=None, **_kwargs):
            commands.append(list(command))
            refused = restic_access_result(command, {}, opens_as)
            if refused is not None:
                return refused[0]
            on_line(json.dumps({"message_type": "summary", "total_files_processed": 1, "total_bytes_processed": 7}))
            return 0

        with ExitStack() as patches:
            for name, value in (
                ("validate_repository_volume", None),
                ("validate_repository_storage_readiness", {"status": "ready"}),
                ("ensure_free_space", 1),
            ):
                patches.enter_context(mock.patch.object(dry_run, name, return_value=value))
            patches.enter_context(mock.patch.object(dry_run, "stream_command", side_effect=fake_stream))
            patches.enter_context(redirect_stdout(io.StringIO()))
            patches.enter_context(redirect_stderr(io.StringIO()))
            self.assertEqual(0, dry_run._run_locked(config))
        report = json.loads((Path(config["state_directory"]) / "dry-run-latest.json").read_text(encoding="utf-8"))
        return report, commands

    def test_the_report_says_how_the_backups_open(self) -> None:
        for label, configured, opens_as, expected in (
            ("an older configuration", None, "password", "password"),
            ("a backup with a password", "password", "password", "password"),
            ("a backup without a password", "no_password", "no_password", "no_password"),
        ):
            with self.subTest(label):
                report, _commands = self.dry_run(configured, opens_as)
                self.assertEqual("clean", report["state"])
                self.assertEqual(expected, report["repository_access"])

    def test_the_scan_of_a_backup_without_a_password_carries_the_flag_and_no_password_option(self) -> None:
        report, commands = self.dry_run("no_password", "no_password")
        (command,) = commands
        assert_credential_arguments(self, command, "no_password")
        self.assertIn("--dry-run", command)
        self.assertEqual(1, report["command"].count(NO_PASSWORD_FLAG))
        self.assertNotIn("--password-command", report["command"])

    def test_the_scan_of_a_backup_with_a_password_is_what_it_always_was(self) -> None:
        report, commands = self.dry_run(None, "password")
        (command,) = commands
        assert_credential_arguments(self, command, "password")
        self.assertIn("<DPAPI password command>", report["command"])
        self.assertNotIn(NO_PASSWORD_FLAG, report["command"])


if __name__ == "__main__":
    unittest.main()
