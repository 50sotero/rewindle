from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

from credential_repair import sha256_file  # noqa: E402
from refresh_recovery_tools import json_bytes  # noqa: E402
from restic_common import RunLock  # noqa: E402
from stale_lock_repair import repair  # noqa: E402


PLAN_ID = "f0714ed4-0329-4a6e-9042-a3e6f6b07f72"
REPOSITORY_ID = "d" * 64
SID = "S-1-5-21-111-222-333-1001"


def build_fixture(root: Path) -> tuple[Path, dict[str, object]]:
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
    def __init__(self, locks_before: int, locks_after: int = 0) -> None:
        self.locks = locks_before
        self.locks_after = locks_after
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.commands.append(list(command))
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


if __name__ == "__main__":
    unittest.main()
