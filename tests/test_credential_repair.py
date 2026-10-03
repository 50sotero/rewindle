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

import credential_repair  # noqa: E402
from credential_repair import repair, sha256_file  # noqa: E402
from refresh_recovery_tools import json_bytes  # noqa: E402
from restic_common import RunLock  # noqa: E402


PLAN_ID = "98eaecbb-56dc-45f1-8254-5a3357105855"
REPOSITORY_ID = "c" * 64
PASSWORD = "valid-recovery-password-material-with-more-than-forty-characters"
SID = "S-1-5-21-111-222-333-1001"


def build_fixture(root: Path) -> tuple[Path, dict[str, object]]:
    install = root / "Install"
    state = root / "State"
    repository = root / "Repository"
    recovery = root / "RecoveryTools"
    source = r"E:\Projects"
    for directory in (install, state, repository, recovery):
        directory.mkdir(parents=True)
    config: dict[str, object] = {
        "schema_version": 1,
        "plan_id": PLAN_ID,
        "config_generation": 4,
        "repository": str(repository),
        "repository_volume_serial": "AABBCCDD",
        "restic_executable": str(install / "restic.exe"),
        "recovery_tools_directory": str(recovery),
        "python_executable": str(install / "python.exe"),
        "state_directory": str(state),
        "secret_file": str(state / "repository-password.dpapi.json"),
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
    ):
        path.write_text("fixture\n", encoding="utf-8")
    Path(config["recovery_key_file"]).write_text(
        "RESTIC PERSONAL BACKUP RECOVERY KEY\n"
        f"Repository: {repository}\n"
        f"Password: {PASSWORD}\n",
        encoding="utf-8",
    )
    config_path = install / "backup-config.json"
    config_path.write_bytes(json_bytes(config))
    return config_path, config


class FakeRunner:
    def __init__(self, recovery_ok: bool = True, active_ok: bool = True) -> None:
        self.recovery_ok = recovery_ok
        self.active_ok = active_ok
        self.calls: list[tuple[list[str], bool]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        environment = kwargs.get("env")
        recovery = isinstance(environment, dict) and "RESTIC_PASSWORD" in environment
        self.calls.append((list(command), recovery))
        if recovery and (not self.recovery_ok or environment["RESTIC_PASSWORD"] != PASSWORD):
            return subprocess.CompletedProcess(command, 12, "", "wrong key")
        if not recovery and not self.active_ok:
            return subprocess.CompletedProcess(command, 12, "", "bad active key")
        return subprocess.CompletedProcess(
            command,
            0,
            json.dumps({"id": REPOSITORY_ID, "version": 2}),
            "",
        )


class CredentialRepairTests(unittest.TestCase):
    def invoke(
        self,
        config_path: Path,
        runner: FakeRunner,
    ) -> dict[str, object]:
        return repair(
            config_path,
            expected_config_sha256=sha256_file(config_path),
            expected_plan_id=PLAN_ID,
            expected_generation=4,
            expected_user_sid=SID,
            runner=runner,
            acl_verifier=lambda path: None,
            sid_reader=lambda: SID,
            require_manifest=False,
        )

    def test_missing_or_broken_active_secret_is_repaired_only_after_recovery_authentication(self) -> None:
        with tempfile.TemporaryDirectory(prefix="credential-repair-") as root_text:
            root = Path(root_text)
            config_path, config = build_fixture(root)
            repository_config = Path(config["repository"]) / "config"
            key_path = Path(config["recovery_key_file"])
            before_repository = repository_config.read_bytes()
            before_key = key_path.read_bytes()
            runner = FakeRunner()

            def fake_replace(path: Path, password: str) -> None:
                self.assertEqual(PASSWORD, password)
                path.write_text("new protected envelope", encoding="utf-8")

            with mock.patch("credential_repair.load_secret", side_effect=RuntimeError("broken")), mock.patch(
                "credential_repair.replace_secret", side_effect=fake_replace
            ) as replace:
                result = self.invoke(config_path, runner)

            self.assertEqual("repaired", result["state"])
            self.assertTrue(result["secret_replaced"])
            self.assertFalse(result["repository_modified"])
            self.assertFalse(result["recovery_key_modified"])
            replace.assert_called_once()
            self.assertTrue(runner.calls[0][1], "recovery credential is authenticated first")
            self.assertFalse(runner.calls[-1][1], "repaired active credential is authenticated last")
            self.assertEqual(before_repository, repository_config.read_bytes())
            self.assertEqual(before_key, key_path.read_bytes())
            self.assertNotIn(PASSWORD, json.dumps(result))

    def test_already_healthy_secret_is_not_rewritten(self) -> None:
        with tempfile.TemporaryDirectory(prefix="credential-healthy-") as root_text:
            config_path, _ = build_fixture(Path(root_text))
            with mock.patch("credential_repair.load_secret", return_value=PASSWORD), mock.patch(
                "credential_repair.replace_secret"
            ) as replace:
                result = self.invoke(config_path, FakeRunner())
            self.assertEqual("already_healthy", result["state"])
            self.assertFalse(result["secret_replaced"])
            replace.assert_not_called()

    def test_invalid_recovery_key_never_mutates_active_secret(self) -> None:
        with tempfile.TemporaryDirectory(prefix="credential-bad-key-") as root_text:
            config_path, _ = build_fixture(Path(root_text))
            with mock.patch("credential_repair.replace_secret") as replace:
                with self.assertRaisesRegex(RuntimeError, "exit code 12"):
                    self.invoke(config_path, FakeRunner(recovery_ok=False))
            replace.assert_not_called()

    def test_config_generation_sid_and_shared_run_lock_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="credential-binding-") as root_text:
            root = Path(root_text)
            config_path, config = build_fixture(root)
            digest = sha256_file(config_path)
            with self.assertRaisesRegex(RuntimeError, "Windows account"):
                repair(
                    config_path,
                    expected_config_sha256=digest,
                    expected_plan_id=PLAN_ID,
                    expected_generation=4,
                    expected_user_sid=SID,
                    sid_reader=lambda: SID + "9",
                    require_manifest=False,
                )
            with self.assertRaisesRegex(RuntimeError, "another backup process"):
                with RunLock(Path(config["state_directory"]) / "run.lock"):
                    self.invoke(config_path, FakeRunner())

    def test_runtime_manifest_allows_only_distinct_task_evidence_files(self) -> None:
        with tempfile.TemporaryDirectory(prefix="credential-manifest-") as root_text:
            install = Path(root_text) / "Install"
            required = (
                "backup-config.json",
                "credential_repair.py",
                "key_rotation.py",
                "anomaly_review.py",
                "recovery_health.py",
                "restic_common.py",
                "secret_store.py",
                "restic.exe",
                r"Python\python.exe",
            )
            for relative in required:
                path = install / Path(relative)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"fixture {relative}\n", encoding="utf-8")
            for evidence in (
                "scheduled-task.xml",
                "google-drive-verification-task.xml",
            ):
                (install / evidence).write_text(
                    f"<fixture name={evidence!r} />\n",
                    encoding="utf-8",
                )
            rows = [
                {
                    "relative_path": relative,
                    "bytes": (install / Path(relative)).stat().st_size,
                    "sha256": sha256_file(install / Path(relative)),
                }
                for relative in required
            ]
            (install / "runtime-manifest.json").write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "file_count": len(rows),
                        "files": rows,
                    }
                ),
                encoding="utf-8",
            )

            credential_repair.validate_runtime_manifest(install)
            (install / "unexpected-task.xml").write_text(
                "<unexpected />\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                RuntimeError,
                "unmanifested or missing",
            ):
                credential_repair.validate_runtime_manifest(install)


if __name__ == "__main__":
    unittest.main()
