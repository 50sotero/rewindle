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

from recovery_health import inspect  # noqa: E402
from refresh_recovery_tools import MANIFEST_NAME, PAYLOAD_NAMES, json_bytes, sha256_file  # noqa: E402


PLAN_ID = "19d5e13c-bef2-410f-b45a-1bb9b30cd301"
REPOSITORY_ID = "b" * 64
SNAPSHOT_ID = "c" * 64
PASSWORD = "correct-recovery-password-material-that-is-long-enough-12345"


def config_for(root: Path, generation: int = 3) -> dict[str, object]:
    source = r"E:\Projects"
    install = root / "Install"
    state = root / "State"
    repository = root / "Repository" / "Personal"
    recovery = root / "Repository" / "RecoveryTools"
    return {
        "schema_version": 1,
        "plan_id": PLAN_ID,
        "config_generation": generation,
        "repository": str(repository),
        "repository_volume_serial": "A1B2C3D4",
        "restic_executable": str(install / "restic.exe"),
        "recovery_tools_directory": str(recovery),
        "python_executable": str(install / "python.exe"),
        "state_directory": str(state),
        "secret_file": str(state / "repository-password.dpapi.json"),
        "recovery_key_file": str(root / "RecoveryKey.txt"),
        "exclude_file": str(install / "excludes.txt"),
        "canary_file": str(install / "backup-canary.txt"),
        "hostname": "FIXTURE",
        "scheduled_tag": "scheduled",
        "minimum_free_gib": 0,
        "use_vss": False,
        "cloud_placeholder_policy": "strict",
        "sources": [source],
        "source_identities": {source: {"expected_volume_serial": "11223344"}},
    }


def create_bundle(directory: Path, config: dict[str, object]) -> None:
    directory.mkdir(parents=True)
    for name in PAYLOAD_NAMES:
        data = json_bytes(config) if name == "backup-config.json" else (name + "\n").encode()
        (directory / name).write_bytes(data)
    manifest = {
        "schema_version": 1,
        "created_utc": "2026-01-01T00:00:00Z",
        "repository": config["repository"],
        "files": [
            {
                "name": name,
                "bytes": (directory / name).stat().st_size,
                "sha256": sha256_file(directory / name),
            }
            for name in PAYLOAD_NAMES
        ],
    }
    (directory / MANIFEST_NAME).write_bytes(json_bytes(manifest))


def build_fixture(root: Path, *, history: bool = True) -> Path:
    config = config_for(root)
    install = Path(config["restic_executable"]).parent
    state = Path(config["state_directory"])
    repository = Path(config["repository"])
    install.mkdir()
    state.mkdir()
    repository.mkdir(parents=True)
    for path in (
        Path(config["restic_executable"]),
        Path(config["python_executable"]),
        Path(config["secret_file"]),
        install / "secret_store.py",
        Path(config["exclude_file"]),
        Path(config["canary_file"]),
        repository / "config",
    ):
        path.write_text("fixture\n", encoding="utf-8")
    recovery_key = Path(config["recovery_key_file"])
    recovery_key.write_text(
        "RESTIC PERSONAL BACKUP RECOVERY KEY\n"
        f"Repository: {repository}\n"
        f"Password: {PASSWORD}\n",
        encoding="utf-8",
    )
    config_path = install / "backup-config.json"
    config_path.write_bytes(json_bytes(config))
    create_bundle(Path(config["recovery_tools_directory"]), config)
    (state / "last-success.json").write_bytes(
        json_bytes(
            {
                "schema_version": 1,
                "plan_id": PLAN_ID,
                "config_generation": 3,
                "state": "success",
                "verification_complete": True,
                "verification": {
                    "repository_structure": True,
                    "canary": {"verified": True},
                },
            }
        )
    )
    if history:
        (state / "restore-history.json").write_bytes(
            json_bytes(
                {
                    "schema_version": 2,
                    "entries": [
                        {
                            "kind": "recovery_key_representative_drill",
                            "credential_source": "recovery_key",
                            "plan_id": PLAN_ID,
                            "config_generation": 3,
                            "snapshot_generation": 3,
                            "repository_id": REPOSITORY_ID,
                            "snapshot_id": SNAPSHOT_ID,
                            "snapshot_binding": "plan",
                            "result": "verified",
                            "verified": True,
                            "canary_verified": True,
                            "sample_policy": "one-or-two-bounded-files-per-source-v1",
                            "sample_file_count": 2,
                            "sample_bytes": 42,
                            "backend_exit_code": 0,
                            "partial_target_retained": False,
                            "finished_utc": "2026-07-21T12:00:00Z",
                        }
                    ],
                }
            )
        )
    return config_path


class FakeRunner:
    def __init__(self, locks: int = 0, recovery_password_valid: bool = True) -> None:
        self.locks = locks
        self.recovery_password_valid = recovery_password_valid
        self.commands: list[list[str]] = []

    def __call__(self, command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        self.commands.append(list(command))
        environment = kwargs.get("env")
        is_recovery = isinstance(environment, dict) and "RESTIC_PASSWORD" in environment
        if is_recovery and (
            not self.recovery_password_valid or environment["RESTIC_PASSWORD"] != PASSWORD
        ):
            return subprocess.CompletedProcess(command, 12, "", "wrong password")
        if command[-2:] == ["cat", "config"]:
            return subprocess.CompletedProcess(
                command,
                0,
                json.dumps({"id": REPOSITORY_ID, "version": 2}),
                "",
            )
        if command[-2:] == ["list", "locks"]:
            return subprocess.CompletedProcess(command, 0, json.dumps(["a" * 64] * self.locks), "")
        return subprocess.CompletedProcess(command, 1, "", "unexpected")


class RecoveryHealthTests(unittest.TestCase):
    def test_dashboard_cli_isolation_allows_protected_sibling_imports(self) -> None:
        missing_config = PROJECT / "definitely-missing-readiness-test-config.json"
        result = subprocess.run(
            [
                sys.executable,
                "-E",
                "-S",
                "-B",
                str(SOURCE / "recovery_health.py"),
                "--config",
                str(missing_config),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="strict",
            check=False,
        )

        self.assertEqual(2, result.returncode)
        self.assertEqual("", result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual("ResticBackuper.RecoveryHealth.v1", report["schema"])
        self.assertEqual("health_runtime", report["checks"][0]["id"])

        for name in (
            "credential_repair.py",
            "stale_lock_repair.py",
            "anomaly_review.py",
            "key_rotation.py",
        ):
            with self.subTest(script=name):
                helper = subprocess.run(
                    [sys.executable, "-E", "-S", "-B", str(SOURCE / name), "--help"],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    errors="strict",
                    check=False,
                )
                self.assertEqual(0, helper.returncode, helper.stderr)
                self.assertNotIn("ModuleNotFoundError", helper.stderr)

    def test_all_independent_checks_can_be_healthy_without_mutation_or_secret_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-health-") as root_text:
            root = Path(root_text)
            config_path = build_fixture(root)
            before = {
                path.relative_to(root): path.read_bytes()
                for path in root.rglob("*")
                if path.is_file()
            }
            runner = FakeRunner()

            report = inspect(
                config_path,
                runner=runner,
                acl_verifier=lambda path: None,
                history_acl_verifier=lambda path: None,
            )

            self.assertEqual("healthy", report["overall_status"])
            self.assertEqual(REPOSITORY_ID, report["repository_id"])
            self.assertEqual(2, report["repository_format"])
            self.assertEqual(0, report["active_lock_count"])
            self.assertTrue(all(item["status"] == "pass" for item in report["checks"]))
            serialized = json.dumps(report)
            self.assertNotIn(PASSWORD, serialized)
            self.assertNotIn("RESTIC_PASSWORD", serialized)
            after = {
                path.relative_to(root): path.read_bytes()
                for path in root.rglob("*")
                if path.is_file()
            }
            self.assertEqual(before, after)
            self.assertTrue(all("--no-lock" in command and "--no-cache" in command for command in runner.commands))

    def test_bad_recovery_key_and_existing_lock_are_distinct_actionable_states(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-health-bad-key-") as root_text:
            config_path = build_fixture(Path(root_text), history=False)
            report = inspect(
                config_path,
                runner=FakeRunner(locks=2, recovery_password_valid=False),
                acl_verifier=lambda path: None,
                history_acl_verifier=lambda path: None,
            )

            checks = {item["id"]: item for item in report["checks"]}
            self.assertEqual("blocked", report["overall_status"])
            self.assertEqual("fail", checks["recovery_key"]["status"])
            self.assertEqual("warn", checks["locks"]["status"])
            self.assertEqual("warn", checks["restore_drill"]["status"])
            self.assertEqual("pass", checks["active_credential"]["status"])

    def test_recovery_bundle_generation_drift_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="recovery-health-drift-") as root_text:
            root = Path(root_text)
            config_path = build_fixture(root)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            recovery = Path(config["recovery_tools_directory"])
            drift = config_for(root, generation=2)
            create_target = recovery / "backup-config.json"
            create_target.write_bytes(json_bytes(drift))
            manifest = json.loads((recovery / MANIFEST_NAME).read_text(encoding="utf-8"))
            for row in manifest["files"]:
                if row["name"] == "backup-config.json":
                    row["bytes"] = create_target.stat().st_size
                    row["sha256"] = sha256_file(create_target)
            (recovery / MANIFEST_NAME).write_bytes(json_bytes(manifest))

            report = inspect(
                config_path,
                runner=FakeRunner(),
                acl_verifier=lambda path: None,
                history_acl_verifier=lambda path: None,
            )

            bundle_check = next(item for item in report["checks"] if item["id"] == "recovery_bundle")
            self.assertEqual("fail", bundle_check["status"])
            self.assertEqual("blocked", report["overall_status"])


if __name__ == "__main__":
    unittest.main()
