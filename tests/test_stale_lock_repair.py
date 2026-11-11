from __future__ import annotations

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

import recovery_health  # noqa: E402
from credential_repair import sha256_file  # noqa: E402
from refresh_recovery_tools import json_bytes  # noqa: E402
from restic_access import restic_access_result  # noqa: E402
from restic_common import NO_PASSWORD_FLAG, PASSWORD_SOURCE_OPTIONS, RunLock  # noqa: E402
from stale_lock_repair import repair  # noqa: E402


PLAN_ID = "f0714ed4-0329-4a6e-9042-a3e6f6b07f72"
REPOSITORY_ID = "d" * 64
SID = "S-1-5-21-111-222-333-1001"


def build_fixture(root: Path, *, access: str | None = None) -> tuple[Path, dict[str, object]]:
    """`access` None leaves out "repository_access" (every configuration written before the choice existed; it
    means a password); "password" and "no_password" write it. The DPAPI file stays on disk in every case: backups
    without a password may sit next to one an older install left."""
    install = root / "Install"
    state = root / "State"
    repository = root / "Repository"
    recovery = root / "RecoveryTools"
    for directory in (install, state, repository, recovery):
        directory.mkdir(parents=True)
    source = r"E:\Projects"
    config: dict[str, object] = {
        "schema_version": 1,
        "plan_id": PLAN_ID,
        "config_generation": 5,
        "repository": str(repository),
        "repository_volume_serial": "AABBCCDD",
        "restic_executable": str(install / "restic.exe"),
        "recovery_tools_directory": str(recovery),
        "python_executable": str(install / "python.exe"),
        "state_directory": str(state),
        "secret_file": str(state / "secret.json"),
        "recovery_key_file": str(root / "RecoveryKey.txt"),
        "exclude_file": str(install / "excludes.txt"),
        "canary_file": str(install / "canary.txt"),
        "hostname": "FIXTURE",
        "scheduled_tag": "scheduled",
        "minimum_free_gib": 0,
        "read_concurrency": 1,
        "use_vss": False,
        "structural_check_after_backup": True,
        "cloud_placeholder_policy": "strict",
        "sources": [source],
        "source_identities": {source: {"expected_volume_serial": "11223344"}},
    }
    if access is not None:
        config["repository_access"] = access
    for path in (
        Path(config["restic_executable"]),
        Path(config["python_executable"]),
        Path(config["secret_file"]),
        Path(config["exclude_file"]),
        Path(config["canary_file"]),
        install / "secret_store.py",
        repository / "config",
        repository / "data-sentinel",
    ):
        path.write_text("fixture\n", encoding="utf-8")
    config_path = install / "backup-config.json"
    config_path.write_bytes(json_bytes(config))
    return config_path, config


class StatefulRunner:
    """Restic as the backups open: `access` says whether they were made with a password or without."""

    def __init__(self, locks_before: int, locks_after: int = 0, access: str = "password") -> None:
        self.locks = locks_before
        self.locks_after = locks_after
        self.access = access
        self.commands: list[list[str]] = []
        self.environments: list[dict[str, str]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.commands.append(list(command))
        environment = kwargs.get("env")
        self.environments.append(dict(environment) if isinstance(environment, dict) else {})
        refusal = restic_access_result(command, environment, self.access)
        if refusal is not None:
            return subprocess.CompletedProcess(command, refusal[0], "", refusal[1])
        if command[-2:] == ["cat", "config"]:
            return subprocess.CompletedProcess(command, 0, json.dumps({"id": REPOSITORY_ID, "version": 2}), "")
        if command[-2:] == ["list", "locks"]:
            return subprocess.CompletedProcess(command, 0, json.dumps(["e" * 64] * self.locks), "")
        if command[-1:] == ["unlock"]:
            self.locks = self.locks_after
            return subprocess.CompletedProcess(command, 0, "successfully removed locks\n", "")
        return subprocess.CompletedProcess(command, 1, "", "unexpected")


class StaleLockRepairTests(unittest.TestCase):
    def invoke(
        self,
        config_path: Path,
        runner: StatefulRunner,
        processes: list[int] | None = None,
    ) -> dict[str, object]:
        return repair(
            config_path,
            expected_config_sha256=sha256_file(config_path),
            expected_plan_id=PLAN_ID,
            expected_generation=5,
            expected_user_sid=SID,
            runner=runner,
            process_reader=lambda: list(processes or []),
            sid_reader=lambda: SID,
            require_manifest=False,
        )

    def test_default_unlock_removes_only_restic_classified_stale_locks(self) -> None:
        with tempfile.TemporaryDirectory(prefix="stale-lock-") as root_text:
            config_path, config = build_fixture(Path(root_text))
            sentinel = Path(config["repository"]) / "data-sentinel"
            before = sentinel.read_bytes()
            runner = StatefulRunner(locks_before=3, locks_after=0)

            result = self.invoke(config_path, runner)

            self.assertEqual("repaired", result["state"])
            self.assertEqual(3, result["removed_count"])
            self.assertFalse(result["snapshots_modified"])
            self.assertFalse(result["data_modified"])
            self.assertFalse(result["used_remove_all"])
            unlock = next(command for command in runner.commands if command[-1:] == ["unlock"])
            self.assertNotIn("--remove-all", unlock)
            self.assertEqual(before, sentinel.read_bytes())

    def test_running_restic_process_blocks_before_repository_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="stale-lock-running-") as root_text:
            config_path, _ = build_fixture(Path(root_text))
            runner = StatefulRunner(locks_before=2)
            with self.assertRaisesRegex(RuntimeError, "still running"):
                self.invoke(config_path, runner, processes=[1234])
            self.assertEqual([], runner.commands)

    def test_nonstale_locks_can_remain_without_remove_all(self) -> None:
        with tempfile.TemporaryDirectory(prefix="stale-lock-remain-") as root_text:
            config_path, _ = build_fixture(Path(root_text))
            runner = StatefulRunner(locks_before=2, locks_after=1)
            result = self.invoke(config_path, runner)
            self.assertEqual("locks_remain", result["state"])
            self.assertEqual(1, result["removed_count"])
            self.assertEqual(1, result["locks_after"])

    def test_zero_locks_is_idempotent_and_shared_run_lock_gates_repair(self) -> None:
        with tempfile.TemporaryDirectory(prefix="stale-lock-idempotent-") as root_text:
            config_path, config = build_fixture(Path(root_text))
            runner = StatefulRunner(locks_before=0)
            result = self.invoke(config_path, runner)
            self.assertEqual("already_unlocked", result["state"])
            self.assertFalse(any(command[-1:] == ["unlock"] for command in runner.commands))
            with RunLock(Path(config["state_directory"]) / "run.lock"):
                with self.assertRaisesRegex(RuntimeError, "another backup process"):
                    self.invoke(config_path, StatefulRunner(1))

    def test_a_backup_without_a_password_is_unlocked_with_the_flag_and_never_a_password_command(self) -> None:
        with tempfile.TemporaryDirectory(prefix="stale-lock-no-password-") as root_text:
            config_path, config = build_fixture(Path(root_text), access="no_password")
            secret = Path(config["secret_file"])
            secret_before = secret.read_bytes()
            runner = StatefulRunner(locks_before=2, locks_after=0, access="no_password")

            with mock.patch.object(
                recovery_health, "password_command", side_effect=AssertionError("a key command was built")
            ):
                result = self.invoke(config_path, runner)

            self.assertEqual("repaired", result["state"])
            self.assertEqual(2, result["removed_count"])
            # Opening the backups, counting the locks, unlocking, counting again: every command opens them the
            # same way, through the flag alone.
            self.assertEqual(
                [["cat", "config"], ["list", "locks"], ["unlock"], ["list", "locks"]],
                [command[-2:] if command[-1] != "unlock" else ["unlock"] for command in runner.commands],
            )
            for command, environment in zip(runner.commands, runner.environments):
                self.assertIn(NO_PASSWORD_FLAG, command)
                for option in PASSWORD_SOURCE_OPTIONS:
                    self.assertNotIn(option, command)
                self.assertEqual([], [name for name in environment if name.startswith("RESTIC_PASSWORD")])
            unlock = next(command for command in runner.commands if command[-1:] == ["unlock"])
            self.assertNotIn("--remove-all", unlock)
            self.assertEqual(secret_before, secret.read_bytes())

    def test_backups_that_now_ask_for_a_password_are_not_unlocked(self) -> None:
        with tempfile.TemporaryDirectory(prefix="stale-lock-asks-") as root_text:
            config_path, _ = build_fixture(Path(root_text), access="no_password")
            # A key with a password was added outside Rewindle: Restic refuses the flag with exit 12.
            runner = StatefulRunner(locks_before=2, access="password")

            with self.assertRaisesRegex(RuntimeError, "exit code 12"):
                self.invoke(config_path, runner)

            self.assertEqual([["cat", "config"]], [command[-2:] for command in runner.commands])

    def test_a_backup_with_a_password_is_opened_with_the_password_command_as_before(self) -> None:
        for access in (None, "password"):
            with self.subTest(access=access), tempfile.TemporaryDirectory(prefix="stale-lock-password-") as root_text:
                config_path, _ = build_fixture(Path(root_text), access=access)
                runner = StatefulRunner(locks_before=1)

                result = self.invoke(config_path, runner)

                self.assertEqual("repaired", result["state"])
                self.assertEqual(4, len(runner.commands))
                for command in runner.commands:
                    self.assertIn("--password-command", command)
                    self.assertNotIn(NO_PASSWORD_FLAG, command)


if __name__ == "__main__":
    unittest.main()
