"""initialize_repository.py with or without a backup password: modes, exit codes, --detect-access, and the files it writes.

Restic is never started: run_capture and the probe's subprocess runner are replaced by a fake that follows the rules in
tests/restic_access.py (which are Restic 0.19.1's measured behaviour). The real restic_base builds every command, so a
test fails when a command would reach Restic without the flag or with a password option next to it.
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import initialize_repository  # noqa: E402
import restic_common  # noqa: E402
from restic_access import (  # noqa: E402
    EMPTY_NOT_ALLOWED,
    NO_PASSWORD_FLAG,
    WRONG_PASSWORD,
    has_password_source,
    restic_access_result,
)


PASSWORD = "p" * 48
REPOSITORY_ID = "a" * 64
SANITIZED_WORDS = ("password", "dpapi", "restic_")
OLD_NOTE = "The repository password is intentionally not stored in this bundle."


class FakeRestic:
    """The backups at one location and the Restic that opens them.

    `access`: None (no backup there yet), "password", "no_password", or "both" (a backup with an empty-password key and a
    password key, which opens either way).
    """

    def __init__(self, repository: Path, access: str | None = None) -> None:
        self.repository = repository
        self.access = access
        self.saved_password_opens = True  # a password command opens a "password" backup only when this is set
        self.commands: list[list[str]] = []
        self.probes: list[str] = []
        self.probe_runs: list[list[str]] = []
        self.init_exit = 0
        self.cat_override: tuple[int, str, str] | None = None  # (exit, stdout, stderr) for every `cat config`
        self.probe_override: str | None = None
        if access is not None:
            self.write_repository_config()

    def write_repository_config(self) -> None:
        self.repository.mkdir(parents=True, exist_ok=True)
        (self.repository / "config").write_bytes(b"fixture config")
        (self.repository / "keys").mkdir(exist_ok=True)
        (self.repository / "keys" / ("b" * 64)).write_bytes(b"fixture key")

    def empty_the_keys_folder(self) -> None:
        for entry in (self.repository / "keys").iterdir():
            entry.unlink()

    def run_capture(self, command, **_kwargs):
        self.commands.append(list(command))
        flag = NO_PASSWORD_FLAG in command
        environment: dict[str, str] = {}
        if "init" in command:
            if self.init_exit != 0:
                return subprocess.CompletedProcess(
                    command, self.init_exit, "created restic repository ... knowledge of your password is required", "boom"
                )
            conflict = restic_access_result(command, environment, "no_password" if flag else "password")
            if conflict is not None:
                return subprocess.CompletedProcess(command, conflict[0], "", conflict[1])
            self.access = "no_password" if flag else "password"
            self.write_repository_config()
            return subprocess.CompletedProcess(
                command, 0, "created restic repository ... Please note that knowledge of your password is required", ""
            )
        if "cat" in command:
            if self.cat_override is not None:
                code, out, err = self.cat_override
                return subprocess.CompletedProcess(command, code, out, err)
            if self.access is None:
                return subprocess.CompletedProcess(command, 10, "", "Fatal: repository does not exist")
            if self.access == "both":
                refusal = restic_access_result(command, environment, "no_password" if flag else "password")
            elif self.access == "no_password" and not flag and has_password_source(command, environment):
                # A password was given, but the only key is the empty one.
                refusal = (12, WRONG_PASSWORD)
            elif self.access == "password" and not flag and not self.saved_password_opens:
                refusal = (12, WRONG_PASSWORD)
            else:
                refusal = restic_access_result(command, environment, self.access)
            if refusal is not None:
                return subprocess.CompletedProcess(command, refusal[0], "", refusal[1])
            return subprocess.CompletedProcess(command, 0, json.dumps({"id": REPOSITORY_ID, "version": 2}), "")
        raise AssertionError(f"unexpected Restic command: {command}")

    def probe_runner(self, command, **_kwargs):
        """The subprocess.run the real probe is given: how Restic answers `cat config --insecure-no-password`."""
        self.probe_runs.append(list(command))
        if self.access is None:
            return subprocess.CompletedProcess(command, 10, b"", b"Fatal: repository does not exist")
        access = "no_password" if self.access == "both" else self.access
        refusal = restic_access_result(command, {}, access)
        if refusal is None:
            return subprocess.CompletedProcess(command, 0, b"{}", b"")
        return subprocess.CompletedProcess(command, refusal[0], b"", refusal[1].encode())

    def probe(self, restic_executable, repository, **_kwargs) -> str:
        self.probes.append(str(repository))
        if self.probe_override is not None:
            return self.probe_override
        return restic_common.probe_repository_access(restic_executable, repository, runner=self.probe_runner)


class InitializerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="rewindle-initialize-access-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.repository = self.root / "repository"
        self.state = self.root / "state"
        self.secret = self.state / "password.test.json"
        self.key = self.root / "recovery.test.txt"
        self.recovery_tools = self.root / "recovery-tools"
        self.fake = FakeRestic(self.repository)

    def write_config(self, **extra) -> Path:
        source = self.root / "source"
        source.mkdir(exist_ok=True)
        restic = self.root / "restic.exe"
        restic.write_bytes(b"test fixture; not an executable")
        excludes = self.root / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8")
        canary = self.root / "canary.txt"
        canary.write_text("ResticBackuper test canary\n", encoding="utf-8")
        document = {
            "schema_version": 1,
            "plan_id": "11111111-1111-4111-8111-111111111111",
            "config_generation": 1,
            "repository": str(self.repository),
            "repository_volume_serial": "00000000",
            "restic_executable": str(restic),
            "recovery_tools_directory": str(self.recovery_tools),
            "python_executable": sys.executable,
            "state_directory": str(self.state),
            "secret_file": str(self.secret),
            "recovery_key_file": str(self.key),
            "exclude_file": str(excludes),
            "canary_file": str(canary),
            "hostname": "RESTICBACKUPER-TEST",
            "scheduled_tag": "scheduled-test",
            "cloud_placeholder_policy": "strict",
            "sources": [str(source)],
            "source_identities": {str(source): {"expected_volume_serial": "00000000"}},
        }
        document.update(extra)
        path = self.root / "backup-config.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def fake_secret(self, path: Path) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{"fixture": "dpapi envelope"}', encoding="utf-8")
        return PASSWORD

    def run_main(self, argv: list[str]) -> tuple[int, str, str]:
        """initialize_repository.main with the fake Restic, no ACL changes and no real DPAPI."""
        create = mock.Mock(side_effect=self.fake_secret)
        self.create_secret = create
        self.load_secret = mock.Mock(return_value=PASSWORD)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            for name, value in (
                ("validate_repository_volume", None),
                ("ensure_free_space", 1),
                ("secure_directory", lambda path: Path(path).mkdir(parents=True, exist_ok=True)),
            ):
                stack.enter_context(
                    mock.patch.object(
                        initialize_repository, name, **({"side_effect": value} if callable(value) else {"return_value": value})
                    )
                )
            stack.enter_context(mock.patch.object(initialize_repository, "create_secret", create))
            stack.enter_context(mock.patch.object(initialize_repository, "load_secret", self.load_secret))
            stack.enter_context(mock.patch.object(initialize_repository, "run_capture", side_effect=self.fake.run_capture))
            # create=True: the password-mode tests below that never reach the probe also run against an initializer without it.
            stack.enter_context(
                mock.patch.object(initialize_repository, "probe_repository_access", side_effect=self.fake.probe, create=True)
            )
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            code = initialize_repository.main(argv)
        return code, out.getvalue(), err.getvalue()

    def state_record(self) -> dict:
        return json.loads((self.state / "repository.json").read_text(encoding="utf-8"))

    def manifest(self) -> dict:
        return json.loads((self.recovery_tools / "recovery-manifest.json").read_text(encoding="utf-8"))

    def assert_nothing_written(self) -> None:
        self.assertFalse((self.state / "repository.json").exists())
        self.assertFalse(self.recovery_tools.exists())

    def assert_plain_line(self, text: str) -> None:
        self.assertEqual(1, len(text.strip().splitlines()), text)
        for word in SANITIZED_WORDS:
            self.assertNotIn(word, text.lower())
        for restic_text in (EMPTY_NOT_ALLOWED, WRONG_PASSWORD, "Fatal"):
            self.assertNotIn(restic_text, text)


class ExitCodeConstantTests(unittest.TestCase):
    def test_the_codes_the_installer_reads(self) -> None:
        self.assertEqual(
            (4, 5, 6, 7, 20, 21, 22),
            (
                initialize_repository.EXIT_NEEDS_PASSWORD,
                initialize_repository.EXIT_HAS_NO_PASSWORD,
                initialize_repository.EXIT_ACCESS_UNREADABLE,
                initialize_repository.EXIT_PASSWORD_UNAVAILABLE,
                initialize_repository.EXIT_DETECT_NO_PASSWORD,
                initialize_repository.EXIT_DETECT_PASSWORD,
                initialize_repository.EXIT_DETECT_NONE,
            ),
        )

    def test_the_plain_lines_say_nothing_the_log_filters_hide(self) -> None:
        for line in (
            initialize_repository.MISMATCH_MESSAGE,
            initialize_repository.UNREADABLE_MESSAGE,
            initialize_repository.UNAVAILABLE_MESSAGE,
        ):
            with self.subTest(line=line):
                for word in SANITIZED_WORDS:
                    self.assertNotIn(word, line.lower())
                self.assertNotIn(NO_PASSWORD_FLAG, line)
                self.assertTrue(line.isascii())

    def test_every_refusal_has_its_own_line(self) -> None:
        lines = {
            initialize_repository.MISMATCH_MESSAGE,
            initialize_repository.UNREADABLE_MESSAGE,
            initialize_repository.UNAVAILABLE_MESSAGE,
        }
        self.assertEqual(3, len(lines))
        for code, line in (
            (initialize_repository.EXIT_NEEDS_PASSWORD, initialize_repository.MISMATCH_MESSAGE),
            (initialize_repository.EXIT_HAS_NO_PASSWORD, initialize_repository.MISMATCH_MESSAGE),
            (initialize_repository.EXIT_ACCESS_UNREADABLE, initialize_repository.UNREADABLE_MESSAGE),
            (initialize_repository.EXIT_PASSWORD_UNAVAILABLE, initialize_repository.UNAVAILABLE_MESSAGE),
        ):
            with self.subTest(code=code):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    self.assertEqual(code, initialize_repository.refuse(code))
                self.assertEqual(line + "\n", err.getvalue())


class NewBackupWithoutPasswordTests(InitializerTestCase):
    def test_it_creates_the_backups_with_the_flag_and_no_secret_or_key(self) -> None:
        config = self.write_config(repository_access="no_password")

        code, out, err = self.run_main(["--config", str(config)])

        self.assertEqual((0, ""), (code, err))
        self.create_secret.assert_not_called()
        self.load_secret.assert_not_called()
        self.assertFalse(self.secret.exists())
        self.assertFalse(self.key.exists())
        init, cat = self.fake.commands
        self.assertEqual(["init", "--repository-version", "2"], init[-3:])
        self.assertEqual(["cat", "config"], cat[-2:])
        for command in self.fake.commands:
            self.assertEqual(1, command.count(NO_PASSWORD_FLAG))
            self.assertFalse(
                any(argument.startswith(("--password", "--new-password")) for argument in command), command
            )
            # The engine's own child-environment rule accepts every command it ran.
            restic_common.restic_child_environment(command)
        self.assertEqual("no_password", self.fake.access)

    def test_the_records_name_the_mode_and_report_no_secret_and_no_key(self) -> None:
        config = self.write_config(repository_access="no_password")

        _code, out, _err = self.run_main(["--config", str(config)])

        record = self.state_record()
        self.assertEqual("no_password", record["repository_access"])
        self.assertEqual("local_ntfs", record["repository_storage_mode"])
        self.assertIs(False, record["secret_created"])
        self.assertIs(False, record["recovery_key_created"])
        self.assertIs(False, record["recovery_key_names_other_repository"])
        self.assertEqual("no_password", record["recovery_tools_manifest"]["repository_access"])
        summary = json.loads(out)
        self.assertEqual("no_password", summary["repository_access"])
        self.assertIsNone(summary["secret_file"])
        self.assertIsNone(summary["recovery_key_file"])
        self.assertEqual(REPOSITORY_ID, summary["repository_id"])
        self.assertEqual(
            (False, False, False),
            (summary["secret_created"], summary["recovery_key_created"], summary["recovery_key_names_other_repository"]),
        )

    def test_the_recovery_tools_carry_the_mode_and_say_there_is_no_password(self) -> None:
        config = self.write_config(repository_access="no_password")

        self.run_main(["--config", str(config)])

        manifest = self.manifest()
        self.assertEqual("no_password", manifest["repository_access"])
        self.assertEqual(
            "These backups have no password: anyone who can read the backup folder can restore them.", manifest["note"]
        )
        self.assertNotEqual(OLD_NOTE, manifest["note"])
        self.assertEqual(
            {"restic.exe", "restore.py", "secret_store.py", "backup-config.json", "RECOVERY.md", "restic-release.json"},
            {row["name"] for row in manifest["files"]},
        )
        self.assertEqual(
            "no_password",
            json.loads((self.recovery_tools / "backup-config.json").read_text(encoding="utf-8"))["repository_access"],
        )

    def test_an_older_secret_and_key_at_the_default_paths_are_left_exactly_as_they_are(self) -> None:
        config = self.write_config(repository_access="no_password")
        self.state.mkdir()
        self.secret.write_bytes(b"an older install's DPAPI envelope")
        self.key.write_bytes(b"Repository: E:\\Somewhere else\r\nPassword: " + b"q" * 48 + b"\r\n")
        secret_before, key_before = self.secret.read_bytes(), self.key.read_bytes()

        for _round in range(2):  # the second round finds the backups it created, as a rerun would
            code, out, _err = self.run_main(["--config", str(config)])
            self.assertEqual(0, code)
            self.assertIsNone(json.loads(out)["recovery_key_file"])

        self.assertEqual(secret_before, self.secret.read_bytes())
        self.assertEqual(key_before, self.key.read_bytes())
        self.create_secret.assert_not_called()
        self.load_secret.assert_not_called()
        for command in self.fake.commands:
            self.assertNotIn("--password-command", command)

    def test_a_failed_creation_shows_none_of_restics_text(self) -> None:
        config = self.write_config(repository_access="no_password")
        self.fake.init_exit = 1

        with self.assertRaises(RuntimeError) as raised:
            self.run_main(["--config", str(config)])

        self.assertEqual("restic init failed with exit 1", str(raised.exception))
        self.assert_nothing_written()

    def test_a_failed_check_right_after_creation_shows_none_of_restics_text(self) -> None:
        # `init` worked, and the `cat config` that proves the new backups open fails: the message is exactly this, with none of
        # what Restic printed (which may name the password option), and nothing is recorded.
        config = self.write_config(repository_access="no_password")
        self.fake.cat_override = (12, "", "Fatal: wrong password or no key found")

        with self.assertRaises(RuntimeError) as raised:
            self.run_main(["--config", str(config)])

        self.assertEqual("repository authentication failed after init", str(raised.exception))
        self.assertEqual(["init", "--repository-version", "2"], self.fake.commands[0][-3:])
        self.assertEqual(["cat", "config"], self.fake.commands[1][-2:])
        self.assertEqual(2, len(self.fake.commands))
        self.assert_nothing_written()

    def test_a_folder_that_holds_other_files_is_still_refused(self) -> None:
        config = self.write_config(repository_access="no_password")
        self.repository.mkdir()
        (self.repository / "holiday.jpg").write_bytes(b"not a backup")

        with self.assertRaisesRegex(RuntimeError, "nonempty non-Restic directory"):
            self.run_main(["--config", str(config)])

        self.assertEqual([], self.fake.commands)


class ExistingBackupWithoutPasswordTests(InitializerTestCase):
    def test_backups_that_open_without_a_password_are_kept_and_reused(self) -> None:
        self.fake = FakeRestic(self.repository, "no_password")
        config = self.write_config(repository_access="no_password")

        code, out, err = self.run_main(["--config", str(config)])

        self.assertEqual((0, ""), (code, err))
        self.assertEqual(1, len(self.fake.commands))
        self.assertEqual(["cat", "config"], self.fake.commands[0][-2:])
        self.assertIn(NO_PASSWORD_FLAG, self.fake.commands[0])
        self.assertEqual([], self.fake.probes)
        self.assertEqual(REPOSITORY_ID, json.loads(out)["repository_id"])
        self.assertEqual("no_password", self.state_record()["repository_access"])
        self.create_secret.assert_not_called()
        self.assertFalse(self.secret.exists())

    def test_the_missing_password_file_refusal_belongs_to_backups_with_a_password(self) -> None:
        # No DPAPI file anywhere: with a password this refuses (5, 6 or 7, by what the backups are: none of them makes a
        # key); without one it must not, because there is no such file to have.
        self.fake = FakeRestic(self.repository, "no_password")
        config = self.write_config(repository_access="no_password")
        self.assertFalse(self.secret.exists())

        code, _out, _err = self.run_main(["--config", str(config)])

        self.assertEqual(0, code)

    def test_backups_that_need_a_password_stop_with_exit_4_and_one_plain_line(self) -> None:
        self.fake = FakeRestic(self.repository, "password")
        config = self.write_config(repository_access="no_password")

        code, out, err = self.run_main(["--config", str(config)])

        self.assertEqual(initialize_repository.EXIT_NEEDS_PASSWORD, code)
        self.assertEqual("", out)
        self.assertEqual(initialize_repository.MISMATCH_MESSAGE + "\n", err)
        self.assert_plain_line(err)
        self.assert_nothing_written()
        self.create_secret.assert_not_called()
        self.assertEqual([], self.fake.probes)
        self.assertEqual(1, len(self.fake.commands))

    def test_backups_that_could_not_be_opened_stop_with_exit_6(self) -> None:
        self.fake = FakeRestic(self.repository, "no_password")
        config = self.write_config(repository_access="no_password")
        for code_from_restic in (1, 2, 10, 130):
            with self.subTest(exit=code_from_restic):
                self.fake.commands.clear()
                self.fake.cat_override = (code_from_restic, "", "Fatal: some text from Restic")

                code, out, err = self.run_main(["--config", str(config)])

                self.assertEqual(initialize_repository.EXIT_ACCESS_UNREADABLE, code)
                self.assertEqual("", out)
                self.assertEqual(initialize_repository.UNREADABLE_MESSAGE + "\n", err)
                self.assert_plain_line(err)
                self.assert_nothing_written()

    def test_backups_that_open_both_ways_open_without_a_password_too(self) -> None:
        self.fake = FakeRestic(self.repository, "both")
        config = self.write_config(repository_access="no_password")

        code, _out, _err = self.run_main(["--config", str(config)])

        self.assertEqual(0, code)
        self.assertEqual("no_password", self.state_record()["repository_access"])


class CommitRecoveryKeyWithoutPasswordTests(InitializerTestCase):
    def test_it_succeeds_without_reading_a_secret_and_leaves_an_older_key_byte_identical(self) -> None:
        config = self.write_config(repository_access="no_password")
        self.state.mkdir()
        self.secret.write_bytes(b"an older install's DPAPI envelope")
        self.key.write_bytes(b"Repository: E:\\Somewhere else\r\nPassword: " + b"p" * 48 + b"\r\n")
        before = self.key.read_bytes()

        code, out, err = self.run_main(["--config", str(config), "--commit-recovery-key"])

        self.assertEqual((0, ""), (code, err))
        self.assertEqual({"recovery_key_file": None, "recovery_key": "none"}, json.loads(out))
        self.assertEqual(before, self.key.read_bytes())
        self.load_secret.assert_not_called()
        self.assertEqual([], self.fake.commands)
        self.assertFalse((self.state / "run.lock").exists())

    def test_it_works_when_there_is_no_secret_and_no_key_at_all(self) -> None:
        config = self.write_config(repository_access="no_password")

        code, out, _err = self.run_main(["--config", str(config), "--commit-recovery-key"])

        self.assertEqual(0, code)
        self.assertEqual({"recovery_key_file": None, "recovery_key": "none"}, json.loads(out))
        self.assertFalse(self.key.exists())
        self.assertFalse(self.state.exists())

    def test_with_a_password_it_is_still_the_commit_that_reads_the_secret(self) -> None:
        config = self.write_config(repository_access="password")
        self.state.mkdir()
        initialize_repository.write_recovery_key(self.key, self.root / "Old Drive", PASSWORD)

        code, out, _err = self.run_main(["--config", str(config), "--commit-recovery-key"])

        self.assertEqual(0, code)
        self.assertEqual({"recovery_key_file": str(self.key), "recovery_key": "rewritten"}, json.loads(out))
        self.load_secret.assert_called_once_with(self.secret)


class PasswordBackupsTests(InitializerTestCase):
    """The mode every older configuration has: today's flow, today's records."""

    def new_backup(self, **extra) -> tuple[int, dict]:
        config = self.write_config(**extra)
        code, out, err = self.run_main(["--config", str(config)])
        self.assertEqual((0, ""), (code, err))
        return code, json.loads(out)

    def test_a_configuration_without_the_key_and_one_that_says_password_behave_the_same(self) -> None:
        for extra in ({}, {"repository_access": "password"}):
            with self.subTest(extra=extra):
                shutil.rmtree(self.root, ignore_errors=True)
                self.root.mkdir()
                self.fake = FakeRestic(self.repository)
                _code, summary = self.new_backup(**extra)
                init, cat = self.fake.commands
                for command in (init, cat):
                    self.assertIn("--password-command", command)
                    self.assertNotIn(NO_PASSWORD_FLAG, command)
                self.assertEqual("password", self.fake.access)
                self.create_secret.assert_called_once_with(self.secret)
                self.assertTrue(self.secret.is_file())
                self.assertTrue(self.key.is_file())
                record = self.state_record()
                self.assertEqual("password", record["repository_access"])
                self.assertIs(True, record["secret_created"])
                self.assertIs(True, record["recovery_key_created"])
                self.assertEqual(OLD_NOTE, self.manifest()["note"])
                self.assertEqual("password", self.manifest()["repository_access"])
                self.assertEqual(str(self.secret), summary["secret_file"])
                self.assertEqual(str(self.key), summary["recovery_key_file"])
                self.assertEqual("password", summary["repository_access"])

    def test_a_kept_backup_that_the_saved_password_opens_is_reused_without_asking_anything_else(self) -> None:
        for access in ("password", "both"):
            with self.subTest(access=access):
                shutil.rmtree(self.root, ignore_errors=True)
                self.root.mkdir()
                self.fake = FakeRestic(self.repository, access)
                config = self.write_config()
                initialize_repository.write_recovery_key(self.key, self.repository, PASSWORD)
                self.fake_secret(self.secret)
                before = self.key.read_bytes()

                code, out, _err = self.run_main(["--config", str(config)])

                self.assertEqual(0, code)
                self.assertEqual([], self.fake.probes)
                self.assertEqual(1, len(self.fake.commands))
                self.assertIn("--password-command", self.fake.commands[0])
                self.assertEqual(before, self.key.read_bytes())
                self.assertIs(False, self.state_record()["secret_created"])
                self.assertEqual("password", json.loads(out)["repository_access"])

    def test_backups_that_have_no_password_stop_with_exit_5_when_there_is_no_saved_password(self) -> None:
        self.fake = FakeRestic(self.repository, "no_password")
        config = self.write_config(repository_access="password")

        code, out, err = self.run_main(["--config", str(config)])

        self.assertEqual(initialize_repository.EXIT_HAS_NO_PASSWORD, code)
        self.assertEqual("", out)
        self.assertEqual(initialize_repository.MISMATCH_MESSAGE + "\n", err)
        self.assert_plain_line(err)
        self.assertEqual([str(self.repository)], self.fake.probes)
        self.assertEqual([], self.fake.commands)  # no secret was made, so nothing was tried with one
        self.create_secret.assert_not_called()
        self.assertFalse(self.secret.exists())
        self.assert_nothing_written()
        self.assertEqual(["cat", "config"], self.fake.probe_runs[0][-2:])
        self.assertIn(NO_PASSWORD_FLAG, self.fake.probe_runs[0])

    def test_the_old_shape_of_configuration_gets_the_same_exit_5(self) -> None:
        self.fake = FakeRestic(self.repository, "no_password")
        config = self.write_config()

        code, _out, _err = self.run_main(["--config", str(config)])

        self.assertEqual(initialize_repository.EXIT_HAS_NO_PASSWORD, code)

    def test_backups_that_have_no_password_stop_with_exit_5_when_the_saved_password_does_not_open_them(self) -> None:
        for exit_code in (12, 1):
            with self.subTest(exit=exit_code):
                self.fake = FakeRestic(self.repository, "no_password")
                self.fake.cat_override = (exit_code, "", "Fatal: wrong password or no key found")
                config = self.write_config()
                self.fake_secret(self.secret)

                code, out, err = self.run_main(["--config", str(config)])

                self.assertEqual(initialize_repository.EXIT_HAS_NO_PASSWORD, code)
                self.assertEqual("", out)
                self.assert_plain_line(err)
                self.assertEqual([str(self.repository)], self.fake.probes)
                self.assert_nothing_written()

    def assert_refused(self, config: Path, code_expected: int, line: str) -> None:
        """The refusal with its own exit code and one plain line; nothing was made, tried or changed."""
        code, out, err = self.run_main(["--config", str(config)])
        self.assertEqual(code_expected, code)
        self.assertEqual("", out)
        self.assertEqual(line + "\n", err)
        self.assert_plain_line(err)
        self.assert_nothing_written()
        self.create_secret.assert_not_called()

    def test_backups_with_a_password_that_is_not_saved_on_this_pc_stop_with_exit_7(self) -> None:
        # No saved password at all, and Restic says the backups need one: a new password would not open them.
        for extra in ({}, {"repository_access": "password"}):
            with self.subTest(extra=extra):
                shutil.rmtree(self.root, ignore_errors=True)
                self.root.mkdir()
                self.fake = FakeRestic(self.repository, "password")
                config = self.write_config(**extra)
                before = sorted(str(path.relative_to(self.repository)) for path in self.repository.rglob("*"))

                self.assert_refused(config, initialize_repository.EXIT_PASSWORD_UNAVAILABLE, initialize_repository.UNAVAILABLE_MESSAGE)

                self.assertEqual([str(self.repository)], self.fake.probes)
                self.assertEqual([], self.fake.commands)  # no secret was made, so nothing was tried with one
                self.assertFalse(self.secret.exists())
                self.assertFalse(self.key.exists())
                self.assertEqual(before, sorted(str(path.relative_to(self.repository)) for path in self.repository.rglob("*")))
                self.assertEqual(["cat", "config"], self.fake.probe_runs[0][-2:])
                self.assertIn(NO_PASSWORD_FLAG, self.fake.probe_runs[0])

    def test_backups_that_could_not_be_opened_to_tell_stop_with_exit_6_when_there_is_no_saved_password(self) -> None:
        # Restic could not answer (or the answer was not one of its three): not a password this PC lacks, but backups that can't be opened.
        for answer in ("unknown", "missing", "something else"):
            with self.subTest(probe=answer):
                self.fake = FakeRestic(self.repository, "password")
                self.fake.probe_override = answer
                config = self.write_config()
                self.assertFalse(self.secret.exists())

                self.assert_refused(config, initialize_repository.EXIT_ACCESS_UNREADABLE, initialize_repository.UNREADABLE_MESSAGE)

                self.assertEqual([], self.fake.commands)
                self.assertFalse(self.secret.exists())

    def test_a_folder_of_keys_with_no_key_in_it_can_not_be_opened_at_all_so_it_is_exit_6_not_7(self) -> None:
        # Restic answers "needs a password" (12) for backups that hold no key at all, as it does for backups with a password.
        for label in ("empty", "missing", "only a folder"):
            with self.subTest(keys=label):
                shutil.rmtree(self.root, ignore_errors=True)
                self.root.mkdir()
                self.fake = FakeRestic(self.repository, "password")
                self.fake.empty_the_keys_folder()
                if label == "missing":
                    (self.repository / "keys").rmdir()
                if label == "only a folder":
                    (self.repository / "keys" / "not-a-key").mkdir()
                config = self.write_config()

                self.assert_refused(config, initialize_repository.EXIT_ACCESS_UNREADABLE, initialize_repository.UNREADABLE_MESSAGE)

                self.assertEqual([str(self.repository)], self.fake.probes)
                self.assertEqual([], self.fake.commands)

    def test_a_saved_password_that_does_not_open_backups_that_need_one_stops_with_exit_7(self) -> None:
        self.fake = FakeRestic(self.repository, "password")
        self.fake.saved_password_opens = False
        config = self.write_config()
        self.fake_secret(self.secret)
        before = self.secret.read_bytes()

        self.assert_refused(config, initialize_repository.EXIT_PASSWORD_UNAVAILABLE, initialize_repository.UNAVAILABLE_MESSAGE)

        self.assertEqual([str(self.repository)], self.fake.probes)
        self.assertEqual(1, len(self.fake.commands))  # the one `cat config` with the saved password
        self.assertIn("--password-command", self.fake.commands[0])
        self.assertEqual(before, self.secret.read_bytes())
        self.assertFalse(self.key.exists())

    def test_a_probe_that_cannot_tell_does_not_change_that(self) -> None:
        # Restic answered 12 to the saved password: the probe is only asked whether the backups have no password after all.
        for answer in ("password", "unknown", "missing"):
            with self.subTest(probe=answer):
                self.fake = FakeRestic(self.repository, "password")
                self.fake.saved_password_opens = False
                self.fake.probe_override = answer
                config = self.write_config()
                self.fake_secret(self.secret)

                self.assert_refused(config, initialize_repository.EXIT_PASSWORD_UNAVAILABLE, initialize_repository.UNAVAILABLE_MESSAGE)

    def test_a_saved_password_does_not_open_backups_whose_folder_of_keys_is_empty_exit_6(self) -> None:
        self.fake = FakeRestic(self.repository, "password")
        self.fake.saved_password_opens = False
        self.fake.empty_the_keys_folder()
        config = self.write_config()
        self.fake_secret(self.secret)

        self.assert_refused(config, initialize_repository.EXIT_ACCESS_UNREADABLE, initialize_repository.UNREADABLE_MESSAGE)

    def test_any_other_failure_with_a_saved_password_is_the_error_it_always_was(self) -> None:
        for exit_code in (1, 2, 10, 130):
            with self.subTest(exit=exit_code):
                self.fake = FakeRestic(self.repository, "password")
                self.fake.cat_override = (exit_code, "", "Fatal: some text from Restic")
                self.fake.probe_override = "password"
                config = self.write_config()
                self.fake_secret(self.secret)

                with self.assertRaisesRegex(
                    RuntimeError, f"^repository authentication failed with exit {exit_code}: Fatal: some text from Restic$"
                ):
                    self.run_main(["--config", str(config)])

                self.assert_nothing_written()
                self.create_secret.assert_not_called()

    def test_a_failed_check_right_after_creation_with_a_password_is_the_error_it_always_was(self) -> None:
        config = self.write_config()
        self.fake.cat_override = (12, "", "Fatal: wrong password or no key found")

        with self.assertRaisesRegex(RuntimeError, "^repository authentication failed after init: Fatal: wrong password"):
            self.run_main(["--config", str(config)])


class DetectAccessTests(InitializerTestCase):
    def detect(self, access: str | None, *, runner=None) -> tuple[int, str, str]:
        self.fake = FakeRestic(self.repository, access)
        restic = self.root / "restic.exe"
        restic.write_bytes(b"fixture")
        out, err = io.StringIO(), io.StringIO()
        before = sorted(path.name for path in self.root.iterdir())
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    initialize_repository,
                    "probe_repository_access",
                    side_effect=lambda exe, repo: restic_common.probe_repository_access(
                        exe, repo, runner=runner or self.fake.probe_runner
                    ),
                )
            )
            # Everything a detection must leave alone.
            for name in ("load_config", "run_capture", "create_secret", "load_secret", "secure_directory", "RunLock"):
                stack.enter_context(
                    mock.patch.object(initialize_repository, name, side_effect=AssertionError(f"{name} was used"))
                )
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            code = initialize_repository.main(["--detect-access", "--repository", str(self.repository), "--restic", str(restic)])
        after = sorted(path.name for path in self.root.iterdir())
        self.assertEqual(before, after)
        return code, out.getvalue(), err.getvalue()

    def test_backups_without_a_password_answer_20(self) -> None:
        self.assertEqual((initialize_repository.EXIT_DETECT_NO_PASSWORD, "", ""), self.detect("no_password"))

    def test_backups_with_a_password_answer_21(self) -> None:
        self.assertEqual((initialize_repository.EXIT_DETECT_PASSWORD, "", ""), self.detect("password"))

    def test_backups_that_open_both_ways_answer_20(self) -> None:
        self.assertEqual((20, "", ""), self.detect("both"))

    def test_no_backups_there_answer_22(self) -> None:
        self.assertEqual((initialize_repository.EXIT_DETECT_NONE, "", ""), self.detect(None))

    def test_an_empty_folder_answers_22(self) -> None:
        self.repository.mkdir()
        self.assertEqual((22, "", ""), self.detect(None))

    def test_anything_it_cannot_tell_answers_6_with_one_plain_line(self) -> None:
        def broken_config(command, **_kwargs):
            return subprocess.CompletedProcess(command, 10, b"", b"Fatal: unable to open config file")

        def timed_out(command, **_kwargs):
            raise subprocess.TimeoutExpired(command, 180)

        def cannot_start(command, **_kwargs):
            raise OSError("not a program")

        cases = {
            "damaged key": lambda command, **_kwargs: subprocess.CompletedProcess(command, 1, b"", b"x"),
            "panic": lambda command, **_kwargs: subprocess.CompletedProcess(command, 2, b"", b"x"),
            "time-out": timed_out,
            "no program": cannot_start,
        }
        for label, runner in cases.items():
            with self.subTest(label):
                code, out, err = self.detect("no_password", runner=runner)
                self.assertEqual((initialize_repository.EXIT_ACCESS_UNREADABLE, ""), (code, out))
                self.assertEqual(initialize_repository.UNREADABLE_MESSAGE + "\n", err)
        with self.subTest("a config file is there but Restic says there is no backup"):
            code, out, err = self.detect("no_password", runner=broken_config)
            self.assertEqual(6, code)

    def test_it_asks_restic_only_for_the_config_of_that_location_with_the_flag(self) -> None:
        self.detect("password")
        (command,) = self.fake.probe_runs
        self.assertEqual(
            [str(self.root / "restic.exe"), "--repo", str(self.repository), NO_PASSWORD_FLAG, "--no-lock", "--no-cache", "cat", "config"],
            command,
        )


class CommandLineTests(unittest.TestCase):
    def parse(self, *argv: str):
        with contextlib.redirect_stderr(io.StringIO()):
            return initialize_repository.parse_args(list(argv))

    def refused(self, *argv: str) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.parse(*argv)
        self.assertEqual(2, raised.exception.code)

    def test_without_detection_the_configuration_defaults_as_it_always_did(self) -> None:
        self.assertEqual(restic_common.DEFAULT_CONFIG, self.parse().config)
        self.assertEqual(Path("x.json"), self.parse("--config", "x.json").config)
        self.assertTrue(self.parse("--config", "x.json", "--commit-recovery-key").commit_recovery_key)
        self.assertFalse(self.parse().detect_access)

    def test_detection_takes_a_repository_and_a_restic_program(self) -> None:
        args = self.parse("--detect-access", "--repository", "E:\\Backups", "--restic", "E:\\restic.exe")
        self.assertEqual((True, Path("E:\\Backups"), Path("E:\\restic.exe"), None), (args.detect_access, args.repository, args.restic, args.config))

    def test_detection_refuses_everything_else_with_the_usage_exit_code(self) -> None:
        self.refused("--detect-access")
        self.refused("--detect-access", "--repository", "E:\\Backups")
        self.refused("--detect-access", "--restic", "E:\\restic.exe")
        self.refused("--detect-access", "--repository", "E:\\Backups", "--restic", "E:\\restic.exe", "--config", "x.json")
        self.refused(
            "--detect-access", "--repository", "E:\\Backups", "--restic", "E:\\restic.exe", "--commit-recovery-key"
        )

    def test_the_detection_options_mean_nothing_on_their_own(self) -> None:
        self.refused("--repository", "E:\\Backups")
        self.refused("--config", "x.json", "--restic", "E:\\restic.exe")


class EntryPointTests(unittest.TestCase):
    """The __main__ wrapper keeps mapping exceptions to 1 and passes the codes main() returns straight through."""

    def run_script(self, answer) -> tuple[int, str]:
        err = io.StringIO()
        argv = ["initialize_repository.py", "--detect-access", "--repository", "E:\\Backups", "--restic", "E:\\restic.exe"]
        patch = (
            mock.patch.object(restic_common, "probe_repository_access", side_effect=answer)
            if isinstance(answer, BaseException)
            else mock.patch.object(restic_common, "probe_repository_access", return_value=answer)
        )
        with mock.patch.object(sys, "argv", argv), patch, contextlib.redirect_stderr(err):
            with self.assertRaises(SystemExit) as raised:
                runpy.run_path(str(SOURCE / "initialize_repository.py"), run_name="__main__")
        return raised.exception.code, err.getvalue()

    def test_detection_codes_reach_the_process_exit_code(self) -> None:
        self.assertEqual(20, self.run_script("no_password")[0])
        self.assertEqual(21, self.run_script("password")[0])
        self.assertEqual(22, self.run_script("missing")[0])
        self.assertEqual(6, self.run_script("unknown")[0])

    def test_an_exception_is_still_exit_1(self) -> None:
        code, err = self.run_script(RuntimeError("boom"))
        self.assertEqual(1, code)
        self.assertIn("INITIALIZATION FAILED: boom", err)


if __name__ == "__main__":
    unittest.main()
