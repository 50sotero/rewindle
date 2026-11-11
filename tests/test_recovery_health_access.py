"""Recovery-readiness checks for backups made with or without a password.

A backup without a password ("repository_access": "no_password") is opened with Restic's --insecure-no-password flag
alone: no DPAPI file, no recovery key, no password command. These tests run the real inspection against fake Restic
programs that follow Restic 0.19.1's rules (tests/restic_access.py).
"""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import credential_repair  # noqa: E402
import key_rotation  # noqa: E402
import recovery_health  # noqa: E402
from recovery_health import credential_arguments, inspect, password_command  # noqa: E402
from refresh_recovery_tools import MANIFEST_NAME, json_bytes, sha256_file  # noqa: E402
from restic_common import NO_PASSWORD_FLAG, PASSWORD_SOURCE_OPTIONS, assert_no_password_source_with_flag  # noqa: E402
import test_recovery_health as base  # noqa: E402


# The words Rewindle's log filters hide a whole message for (RecoveryHealthManager.Sanitize and the Python
# sanitizers of the repair tools), plus the flag itself.
HIDDEN_WORDS = ("password", "dpapi", "restic_")

NOW_ASKS_FOR_PASSWORD = (
    "These backups now ask for a password, usually because one was added outside Rewindle. "
    "See Switching an existing backup in Rewindle's guide."
)
NOW_OPEN_WITHOUT_PASSWORD = (
    "These backups now open without a password, usually because it was removed outside Rewindle. "
    "See Switching an existing backup in Rewindle's guide."
)


def run_inspection(
    config_path: Path, runner: object, acl_calls: list[Path] | None = None
) -> dict[str, object]:
    def verify(path: Path) -> None:
        if acl_calls is not None:
            acl_calls.append(path)

    return inspect(
        config_path,
        runner=runner,
        acl_verifier=verify,
        history_acl_verifier=lambda path: None,
    )


def checks_of(report: dict[str, object]) -> dict[str, dict[str, str]]:
    return {item["id"]: item for item in report["checks"]}


def read_config(config_path: Path) -> dict[str, object]:
    return json.loads(config_path.read_text(encoding="utf-8"))


def set_drill_source(config_path: Path, source: str) -> None:
    path = Path(read_config(config_path)["state_directory"]) / "restore-history.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    for entry in document["entries"]:
        entry["credential_source"] = source
    path.write_bytes(json_bytes(document))


def set_bundle_access(config_path: Path, access: str | None) -> None:
    """Make the recovery copy (its configuration and its manifest) name `access`; None leaves the key out."""
    config = read_config(config_path)
    recovery = Path(config["recovery_tools_directory"])
    bundle_config = dict(config)
    bundle_config.pop("repository_access", None)
    if access is not None:
        bundle_config["repository_access"] = access
    target = recovery / "backup-config.json"
    target.write_bytes(json_bytes(bundle_config))
    manifest = json.loads((recovery / MANIFEST_NAME).read_text(encoding="utf-8"))
    for row in manifest["files"]:
        if row["name"] == "backup-config.json":
            row["bytes"] = target.stat().st_size
            row["sha256"] = sha256_file(target)
    manifest.pop("repository_access", None)
    if access is not None:
        manifest["repository_access"] = access
    (recovery / MANIFEST_NAME).write_bytes(json_bytes(manifest))


def set_live_access(config_path: Path, access: str | None) -> None:
    config = read_config(config_path)
    config.pop("repository_access", None)
    if access is not None:
        config["repository_access"] = access
    config_path.write_bytes(json_bytes(config))


class ExitRunner:
    """Every Restic command answers with one exit code."""

    def __init__(self, exit_code: int) -> None:
        self.exit_code = exit_code
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.commands.append(list(command))
        return subprocess.CompletedProcess(command, self.exit_code, "", "fatal")


class SavedPasswordRejected(base.FakeRunner):
    """Backups made with a password whose saved password Restic now refuses.

    `probe_exit` is what opening them with --insecure-no-password answers: 0 when a key without a password was added
    outside Rewindle, 12 when none was.
    """

    def __init__(self, probe_exit: int, active_exit: int = 12, probe_raises: bool = False) -> None:
        super().__init__()
        self.probe_exit = probe_exit
        self.active_exit = active_exit
        self.probe_raises = probe_raises

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if "--password-command" in command:
            self.commands.append(list(command))
            return subprocess.CompletedProcess(command, self.active_exit, "", "fatal")
        if NO_PASSWORD_FLAG in command:
            self.commands.append(list(command))
            if self.probe_raises:
                raise OSError("could not start")
            if self.probe_exit == 0:
                payload = json.dumps({"id": base.REPOSITORY_ID, "version": 2})
                return subprocess.CompletedProcess(command, 0, payload, "")
            return subprocess.CompletedProcess(command, self.probe_exit, "", "fatal")
        return super().__call__(command, **kwargs)


class BackupWithoutPasswordTests(unittest.TestCase):
    def test_every_restic_command_carries_the_flag_and_no_key_is_touched(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-no-password-") as root_text:
            root = Path(root_text)
            config_path = base.build_fixture(root, access="no_password")
            before = {path: path.read_bytes() for path in root.rglob("*") if path.is_file()}
            runner = base.FakeRunner(access="no_password")
            acl_calls: list[Path] = []

            report = run_inspection(config_path, runner, acl_calls)

            self.assertEqual("healthy", report["overall_status"], report["checks"])
            self.assertEqual("no_password", report["repository_access"])
            self.assertEqual(base.REPOSITORY_ID, report["repository_id"])
            self.assertEqual(0, report["active_lock_count"])
            checks = checks_of(report)
            # Without a password there is no recovery key and no rotation to check.
            self.assertNotIn("recovery_key", checks)
            self.assertNotIn("rotation_rollback_key", checks)
            self.assertEqual("pass", checks["active_credential"]["status"])
            self.assertEqual("Rewindle can open your backups.", checks["active_credential"]["summary"])
            self.assertEqual("pass", checks["locks"]["status"])
            self.assertEqual("pass", checks["restore_drill"]["status"])
            self.assertEqual(
                "A restore drill (the restore test file plus a small sample of your files) passed.",
                checks["restore_drill"]["summary"],
            )
            # Just the two reads, both through the flag; nothing carries a password option or variable.
            self.assertEqual([["cat", "config"], ["list", "locks"]], [c[-2:] for c in runner.commands])
            for command, environment in zip(runner.commands, runner.environments):
                self.assertIn(NO_PASSWORD_FLAG, command)
                for option in PASSWORD_SOURCE_OPTIONS:
                    self.assertNotIn(option, command)
                self.assertEqual([], [name for name in environment if name.startswith("RESTIC_PASSWORD")])
                assert_no_password_source_with_flag(command)
            self.assertEqual([], acl_calls, "no key or key record is looked at")
            self.assertEqual(before, {path: path.read_bytes() for path in root.rglob("*") if path.is_file()})
            serialized = json.dumps(report)
            for text in ("RESTIC_PASSWORD", "dpapi", "recovery key", "saved password", "--insecure"):
                self.assertNotIn(text, serialized)

    def test_files_an_older_install_left_are_never_read_or_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-no-password-leftover-") as root_text:
            root = Path(root_text)
            config_path = base.build_fixture(root, access="no_password", leftover_key_files=True)
            config = read_config(config_path)
            # A rotation record left by the older password backup.
            (Path(config["state_directory"]) / "key-rotation-latest.json").write_text("{not json", encoding="utf-8")
            secret = Path(config["secret_file"])
            key = Path(config["recovery_key_file"])
            secret_before, key_before = secret.read_bytes(), key.read_bytes()
            runner = base.FakeRunner(access="no_password")
            acl_calls: list[Path] = []

            with mock.patch.object(
                recovery_health, "parse_recovery_key", side_effect=AssertionError("a key was read")
            ), mock.patch.object(
                recovery_health, "password_command", side_effect=AssertionError("a key command was built")
            ):
                report = run_inspection(config_path, runner, acl_calls)

            self.assertEqual("healthy", report["overall_status"], report["checks"])
            self.assertEqual([], acl_calls)
            self.assertNotIn("rotation_rollback_key", checks_of(report))
            self.assertEqual(secret_before, secret.read_bytes())
            self.assertEqual(key_before, key.read_bytes())

    def test_password_command_refuses_before_building_anything(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-no-password-command-") as root_text:
            root = Path(root_text)
            config_path = base.build_fixture(root, access="no_password", leftover_key_files=True)
            config = read_config(config_path)
            secret = Path(config["secret_file"])
            secret_before = secret.read_bytes()
            # With every file in place, which is what an older install leaves behind ...
            with self.assertRaisesRegex(RuntimeError, "opens without a key"):
                password_command(config, config_path.parent)
            # ... and with none of them: the refusal does not depend on what is on disk.
            with self.assertRaisesRegex(RuntimeError, "opens without a key") as caught:
                password_command({"repository_access": "no_password"}, root / "nowhere")
            self.assertEqual(secret_before, secret.read_bytes())
            # Said in words no log filter hides (it would be shown as "without exposing credential details").
            for word in HIDDEN_WORDS:
                self.assertNotIn(word, str(caught.exception).casefold())

    def test_credential_arguments_follow_the_mode(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-credential-arguments-") as root_text:
            root = Path(root_text)
            config_path = base.build_fixture(root)
            config = read_config(config_path)
            command = password_command(config, config_path.parent)
            for access in (None, "password"):
                with self.subTest(access=access):
                    shaped = dict(config)
                    shaped.pop("repository_access", None)
                    if access is not None:
                        shaped["repository_access"] = access
                    self.assertEqual(
                        ["--password-command", command], credential_arguments(shaped, config_path.parent)
                    )
            self.assertEqual(
                [NO_PASSWORD_FLAG],
                credential_arguments({**config, "repository_access": "no_password"}, config_path.parent),
            )
            self.assertEqual([NO_PASSWORD_FLAG], credential_arguments({"repository_access": "no_password"}, root))

    def test_backups_that_now_ask_for_a_password_say_so_with_a_next_step(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-no-password-asks-") as root_text:
            config_path = base.build_fixture(Path(root_text), access="no_password")
            # A key with a password was added outside Rewindle: Restic refuses the flag with exit 12.
            runner = base.FakeRunner(access="password")

            report = run_inspection(config_path, runner)

            checks = checks_of(report)
            self.assertEqual("blocked", report["overall_status"])
            self.assertEqual("fail", checks["active_credential"]["status"])
            self.assertEqual(
                "Rewindle couldn't open your backups. Check that the backup drive or Google Drive folder is "
                "connected, then run the checks again.",
                checks["active_credential"]["summary"],
            )
            self.assertEqual(NOW_ASKS_FOR_PASSWORD, checks["active_credential"]["detail"])
            self.assertEqual("fail", checks["locks"]["status"])
            self.assertNotIn("saved password", checks["locks"]["summary"] + checks["locks"]["detail"])
            # The check only looks: no follow-up probe for backups that already use the flag.
            self.assertEqual([["cat", "config"], ["list", "locks"]], [c[-2:] for c in runner.commands])
            self.assertTrue(all(NO_PASSWORD_FLAG in command for command in runner.commands))
            for item in report["checks"]:
                for text in (item["summary"], item["detail"]):
                    for word in ("dpapi", "restic_", "--insecure"):
                        self.assertNotIn(word, text.casefold())

    def test_any_other_failure_keeps_restic_s_exit_code_as_the_detail(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-no-password-gone-") as root_text:
            config_path = base.build_fixture(Path(root_text), access="no_password")
            report = run_inspection(config_path, ExitRunner(10))
            check = checks_of(report)["active_credential"]
            self.assertEqual("fail", check["status"])
            self.assertEqual("Repository authentication failed with Restic exit code 10.", check["detail"])

    def test_restore_drill_counts_only_a_drill_without_a_key(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-no-password-drill-") as root_text:
            root = Path(root_text)
            config_path = base.build_fixture(root, access="no_password", history=False)
            report = run_inspection(config_path, base.FakeRunner(access="no_password"))
            check = checks_of(report)["restore_drill"]
            self.assertEqual("warn", check["status"])
            self.assertEqual("You haven't run a restore drill yet.", check["summary"])
            self.assertEqual(
                "Choose Run restore drill to restore a small sample of your files and check it.", check["detail"]
            )
            self.assertEqual("warning", report["overall_status"])

        with tempfile.TemporaryDirectory(prefix="health-no-password-drill-old-") as root_text:
            config_path = base.build_fixture(Path(root_text), access="no_password")
            # A drill that used a recovery key says nothing about a backup that has none.
            set_drill_source(config_path, "recovery_key")
            report = run_inspection(config_path, base.FakeRunner(access="no_password"))
            check = checks_of(report)["restore_drill"]
            self.assertEqual("warn", check["status"])
            self.assertEqual("Run the restore drill to prove Rewindle can restore your files.", check["summary"])


class BackupWithPasswordTests(unittest.TestCase):
    def test_a_configuration_without_the_key_is_a_backup_with_a_password(self) -> None:
        for access in (None, "password"):
            with self.subTest(access=access), tempfile.TemporaryDirectory(prefix="health-password-") as root_text:
                config_path = base.build_fixture(Path(root_text), access=access)
                runner = base.FakeRunner()

                report = run_inspection(config_path, runner)

                self.assertEqual("healthy", report["overall_status"], report["checks"])
                self.assertEqual("password", report["repository_access"])
                checks = checks_of(report)
                self.assertEqual(
                    "Rewindle's saved password for this Windows account opens your backups.",
                    checks["active_credential"]["summary"],
                )
                self.assertEqual("pass", checks["recovery_key"]["status"])
                self.assertEqual("pass", checks["rotation_rollback_key"]["status"])
                self.assertIn("--password-command", runner.commands[0])
                self.assertTrue(all(NO_PASSWORD_FLAG not in command for command in runner.commands))
                self.assertEqual(3, len(runner.commands), "the active key, the recovery key and the locks")

    def test_a_drill_without_a_key_does_not_count_for_a_backup_with_a_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-password-drill-") as root_text:
            config_path = base.build_fixture(Path(root_text))
            set_drill_source(config_path, "none")
            report = run_inspection(config_path, base.FakeRunner())
            check = checks_of(report)["restore_drill"]
            self.assertEqual("warn", check["status"])
            self.assertEqual("Run the restore drill to prove your recovery key can restore your files.", check["summary"])

        with tempfile.TemporaryDirectory(prefix="health-password-drill-key-") as root_text:
            config_path = base.build_fixture(Path(root_text))
            report = run_inspection(config_path, base.FakeRunner())
            self.assertEqual(
                "A restore drill with your recovery key (the restore test file plus a small sample of your files) "
                "passed.",
                checks_of(report)["restore_drill"]["summary"],
            )

        with tempfile.TemporaryDirectory(prefix="health-password-drill-none-") as root_text:
            config_path = base.build_fixture(Path(root_text), history=False)
            check = checks_of(run_inspection(config_path, base.FakeRunner()))["restore_drill"]
            self.assertEqual(
                "Choose Run restore drill to restore a small sample of your files with your recovery key and check it.",
                check["detail"],
            )

    def test_a_backup_that_now_opens_without_a_password_is_named_after_a_read_only_look(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-password-removed-") as root_text:
            config_path = base.build_fixture(Path(root_text))
            runner = SavedPasswordRejected(probe_exit=0)

            report = run_inspection(config_path, runner)

            check = checks_of(report)["active_credential"]
            self.assertEqual("fail", check["status"])
            self.assertEqual(
                "Rewindle's saved password for this Windows account can't open your backups, so scheduled backups "
                "would fail.",
                check["summary"],
            )
            self.assertEqual(NOW_OPEN_WITHOUT_PASSWORD, check["detail"])
            probes = [command for command in runner.commands if NO_PASSWORD_FLAG in command]
            self.assertEqual(1, len(probes))
            probe = probes[0]
            self.assertEqual(["cat", "config"], probe[-2:])
            self.assertIn("--no-lock", probe)
            self.assertIn("--no-cache", probe)
            for option in PASSWORD_SOURCE_OPTIONS:
                self.assertNotIn(option, probe)

    def test_the_look_changes_nothing_unless_it_finds_the_backups_open(self) -> None:
        cases = {
            "still needs a password": SavedPasswordRejected(probe_exit=12),
            "cannot tell": SavedPasswordRejected(probe_exit=1),
            "cannot start": SavedPasswordRejected(probe_exit=0, probe_raises=True),
        }
        for name, runner in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory(prefix="health-password-look-") as root_text:
                config_path = base.build_fixture(Path(root_text))
                check = checks_of(run_inspection(config_path, runner))["active_credential"]
                self.assertEqual("fail", check["status"])
                self.assertEqual("Repository authentication failed with Restic exit code 12.", check["detail"])
                self.assertEqual(1, sum(NO_PASSWORD_FLAG in command for command in runner.commands))

    def test_the_look_is_only_for_restic_s_no_matching_key_answer_and_never_for_a_working_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="health-password-exit-1-") as root_text:
            config_path = base.build_fixture(Path(root_text))
            runner = SavedPasswordRejected(probe_exit=0, active_exit=1)
            check = checks_of(run_inspection(config_path, runner))["active_credential"]
            self.assertEqual("Repository authentication failed with Restic exit code 1.", check["detail"])
            self.assertTrue(all(NO_PASSWORD_FLAG not in command for command in runner.commands))

        # A backup that opens both ways (a key without a password was added) keeps working with its saved password,
        # and the check does not look any further.
        with tempfile.TemporaryDirectory(prefix="health-password-both-ways-") as root_text:
            config_path = base.build_fixture(Path(root_text))
            runner = base.FakeRunner()
            report = run_inspection(config_path, runner)
            self.assertEqual("pass", checks_of(report)["active_credential"]["status"])
            self.assertTrue(all(NO_PASSWORD_FLAG not in command for command in runner.commands))


class ModeValueTests(unittest.TestCase):
    def test_an_unsupported_value_is_refused_by_name_before_anything_runs(self) -> None:
        for value in ("No_Password", "", "none", 5, None):
            with self.subTest(value=value), tempfile.TemporaryDirectory(prefix="health-bad-mode-") as root_text:
                config_path = base.build_fixture(Path(root_text))
                config = read_config(config_path)
                config["repository_access"] = value
                config_path.write_bytes(json_bytes(config))
                runner = base.FakeRunner()

                with self.assertRaisesRegex(ValueError, "^unsupported repository_access$"):
                    run_inspection(config_path, runner)
                self.assertEqual([], runner.commands)

                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    exit_code = recovery_health.main(["--config", str(config_path)])
                self.assertEqual(2, exit_code)
                failure = json.loads(output.getvalue())["checks"][0]
                self.assertEqual("health_runtime", failure["id"])
                self.assertEqual("unsupported repository_access", failure["detail"])
                for word in HIDDEN_WORDS:
                    self.assertNotIn(word, failure["detail"].casefold())


class SanitizerTests(unittest.TestCase):
    """Text that can reach a log filter must survive it: the dashboard hides a whole message that holds one of three
    words, and the repair tools' own sanitizer does the same."""

    def dashboard_words(self) -> set[str]:
        source = (PROJECT / "src" / "dashboard" / "RecoveryHealthManager.cs").read_text(encoding="utf-8")
        return {
            word.casefold()
            for word in re.findall(r'IndexOf\("([^"]+)", StringComparison\.OrdinalIgnoreCase\)', source)
        }

    def test_the_messages_that_reach_a_filter_hold_none_of_the_words_it_hides(self) -> None:
        words = self.dashboard_words()
        # If the filter changes, this list is the thing to look at again.
        self.assertEqual({"password", "dpapi", "restic_"}, words)
        with self.assertRaises(RuntimeError) as refused:
            password_command({"repository_access": "no_password"}, Path("nowhere"))
        messages = {
            "credential repair refusal": credential_repair.NO_KEY_TO_REPAIR,
            "key rotation refusal": key_rotation.NO_KEYS_TO_ROTATE,
            "unsupported value": "unsupported repository_access",
            "key command refusal": str(refused.exception),
            "no key to open": str(recovery_health.RepositoryAuthenticationFailed(12)),
        }
        for name, message in messages.items():
            with self.subTest(name):
                self.assertEqual([], [word for word in words if word in message.casefold()])
        # ... which is what the repair tools' own sanitizers say too.
        self.assertEqual(credential_repair.NO_KEY_TO_REPAIR, credential_repair.sanitize(credential_repair.NO_KEY_TO_REPAIR))
        self.assertEqual(key_rotation.NO_KEYS_TO_ROTATE, key_rotation.sanitize(key_rotation.NO_KEYS_TO_ROTATE))

    def test_what_restic_says_never_reaches_a_message(self) -> None:
        # The fake answers as Restic 0.19.1 does: its own words are about a password and the flag.
        with tempfile.TemporaryDirectory(prefix="health-restic-words-") as root_text:
            config_path = base.build_fixture(Path(root_text), access="no_password")
            report = run_inspection(config_path, base.FakeRunner(access="password"))
            serialized = json.dumps(report).casefold()
            for restic_words in ("wrong password or no key found", "--insecure-no-password", "empty password"):
                self.assertNotIn(restic_words, serialized)


class RecoveryCopyDriftTests(unittest.TestCase):
    """The recovery copy must name the same mode as the live configuration; a missing key means a password."""

    def drift_detail(self, live: str | None, bundle: str | None) -> tuple[str, str]:
        with tempfile.TemporaryDirectory(prefix="health-drift-") as root_text:
            config_path = base.build_fixture(Path(root_text), access=live)
            set_bundle_access(config_path, bundle)
            # Defence in depth: the pair check of the bundle code is out of the way, so this is the drift check alone.
            with mock.patch.object(recovery_health, "validate_config_pair", return_value=([], False)):
                report = run_inspection(config_path, base.FakeRunner(access=live or "password"))
            check = checks_of(report)["recovery_bundle"]
            return check["status"], check["detail"]

    def test_a_missing_key_and_password_are_the_same_mode(self) -> None:
        self.assertEqual(("pass", ""), self.drift_detail("password", None))
        self.assertEqual(("pass", ""), self.drift_detail(None, "password"))
        self.assertEqual(("pass", ""), self.drift_detail(None, None))
        self.assertEqual(("pass", ""), self.drift_detail("no_password", "no_password"))

    def test_different_modes_are_drift_whichever_side_names_it(self) -> None:
        expected = ("fail", "Recovery configuration drift: repository_access")
        self.assertEqual(expected, self.drift_detail(None, "no_password"))
        self.assertEqual(expected, self.drift_detail("password", "no_password"))
        self.assertEqual(expected, self.drift_detail("no_password", None))
        self.assertEqual(expected, self.drift_detail("no_password", "password"))


if __name__ == "__main__":
    unittest.main()
