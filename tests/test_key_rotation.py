from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SRC = PROJECT / "src"
sys.path.insert(0, str(SRC))
RESTIC = PROJECT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"

import key_rotation  # noqa: E402
from recovery_health import authenticate, parse_recovery_key  # noqa: E402
from restic_common import RunLock, load_config, restic_base  # noqa: E402
from secret_store import create_secret, load_secret, write_recovery_key  # noqa: E402


PYTHON = Path(sys.executable)
SID = "S-1-5-21-1000-2000-3000-4000"


def volume_serial(path: Path) -> str:
    drive = Path(path).resolve().drive.upper()
    script = (
        f"$v=Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='{drive}'\";"
        "$v.VolumeSerialNumber"
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    return result.stdout.strip().upper()


class KeyRotationFixture:
    def __init__(self, root: Path):
        self.root = root
        self.repository = root / "repository"
        self.state = root / "state"
        self.source = root / "source"
        self.source.mkdir()
        self.canary = self.source / "canary.txt"
        self.canary.write_text("rotation canary\n", encoding="utf-8")
        self.excludes = root / "excludes.txt"
        self.excludes.write_text("**/__pycache__\n", encoding="utf-8")
        self.config_path = root / "backup-config.json"
        shutil.copy2(SRC / "secret_store.py", root / "secret_store.py")
        self.recovery_key = root / "RecoveryKey.txt"
        self.config = {
            "schema_version": 1,
            "plan_id": "10000000-0000-4000-8000-000000000077",
            "config_generation": 1,
            "repository": str(self.repository),
            "repository_volume_serial": volume_serial(root),
            "restic_executable": str(RESTIC),
            "recovery_tools_directory": str(root / "recovery-tools"),
            "python_executable": str(PYTHON),
            "state_directory": str(self.state),
            "secret_file": str(self.state / "repository-password.dpapi.json"),
            "recovery_key_file": str(self.recovery_key),
            "exclude_file": str(self.excludes),
            "canary_file": str(self.canary),
            "hostname": "KEY-ROTATION-TEST",
            "scheduled_tag": "rotation-test",
            "minimum_free_gib": 0,
            "read_concurrency": 2,
            "use_vss": False,
            "structural_check_after_backup": False,
            "read_data_subset_weekday": "Never",
            "read_data_subset_parts": 0,
            "cloud_placeholder_policy": "strict",
            "sources": [str(self.source)],
            "source_identities": {
                str(self.source): {"expected_volume_serial": volume_serial(self.source)}
            },
        }
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        password = create_secret(Path(self.config["secret_file"]))
        write_recovery_key(self.recovery_key, self.repository, password)
        environment = os.environ.copy()
        environment["RESTIC_PASSWORD"] = password
        initialized = subprocess.run(
            [str(RESTIC), "init", "--repo", str(self.repository)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=90,
            env=environment,
        )
        if initialized.returncode != 0:
            raise AssertionError(initialized.stderr)

    def rotate(self):
        return key_rotation.rotate(
            self.config_path,
            expected_config_sha256=key_rotation.sha256_file(self.config_path),
            expected_plan_id=self.config["plan_id"],
            expected_generation=1,
            expected_user_sid=SID,
            sid_reader=lambda: SID,
            require_manifest=False,
        )


@unittest.skipUnless(RESTIC.is_file(), "build the release artifact before key-rotation integration tests")
class KeyRotationTests(unittest.TestCase):
    def test_rotation_adds_and_proves_new_key_while_retaining_previous(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-rotation-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            old_password = load_secret(Path(fixture.config["secret_file"]))
            old_recovery_hash = key_rotation.sha256_file(fixture.recovery_key)
            data_before = sorted(
                (str(path.relative_to(fixture.repository)), path.read_bytes())
                for directory in ("data", "snapshots")
                for path in (fixture.repository / directory).rglob("*")
                if path.is_file()
            )

            result = fixture.rotate()

            self.assertEqual("rotated", result["state"])
            self.assertTrue(result["previous_repository_key_retained"])
            self.assertFalse(result["snapshots_modified"])
            self.assertFalse(result["repository_data_modified"])
            self.assertGreaterEqual(result["repository_key_count"], 2)
            previous = Path(result["previous_recovery_file"])
            self.assertTrue(previous.is_file())
            self.assertEqual(old_recovery_hash, key_rotation.sha256_file(previous))

            new_password = load_secret(Path(fixture.config["secret_file"]))
            self.assertNotEqual(old_password, new_password)
            self.assertEqual(
                new_password,
                parse_recovery_key(fixture.recovery_key, fixture.repository),
            )
            self.assertEqual(old_password, parse_recovery_key(previous, fixture.repository))

            environment = os.environ.copy()
            environment["RESTIC_PASSWORD"] = old_password
            try:
                old_id, _ = authenticate(
                    RESTIC,
                    fixture.repository,
                    [],
                    environment=environment,
                )
            finally:
                environment.pop("RESTIC_PASSWORD", None)
            self.assertEqual(result["repository_id"], old_id)
            self.assertNotEqual(result["previous_key_id"], result["new_key_id"])
            self.assertFalse((fixture.state / key_rotation.JOURNAL_NAME).exists())
            self.assertTrue((fixture.state / key_rotation.LATEST_NAME).is_file())
            history = json.loads(
                (fixture.state / key_rotation.HISTORY_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual(result["rotation_id"], history["rotations"][-1]["rotation_id"])
            data_after = sorted(
                (str(path.relative_to(fixture.repository)), path.read_bytes())
                for directory in ("data", "snapshots")
                for path in (fixture.repository / directory).rglob("*")
                if path.is_file()
            )
            self.assertEqual(data_before, data_after)

    def test_interrupted_publish_is_resumed_from_protected_journal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-resume-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            real_replace = key_rotation.replace_secret
            with mock.patch.object(
                key_rotation,
                "replace_secret",
                side_effect=RuntimeError("injected publish interruption"),
            ):
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    fixture.rotate()
            journal = fixture.state / key_rotation.JOURNAL_NAME
            self.assertTrue(journal.is_file())
            document = json.loads(journal.read_text(encoding="utf-8"))
            self.assertEqual("repository_key_added", document["phase"])
            self.assertTrue(Path(document["pending_recovery_file"]).is_file())

            with mock.patch.object(key_rotation, "replace_secret", side_effect=real_replace):
                recovered = fixture.rotate()
            self.assertEqual("rotated", recovered["state"])
            self.assertFalse(journal.exists())
            self.assertTrue(Path(recovered["previous_recovery_file"]).is_file())
            self.assertEqual(
                load_secret(Path(fixture.config["secret_file"])),
                parse_recovery_key(fixture.recovery_key, fixture.repository),
            )

    def test_binding_and_global_run_lock_fail_before_repository_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-binding-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            keys_before = sorted(path.name for path in (fixture.repository / "keys").iterdir())
            with self.assertRaisesRegex(RuntimeError, "configuration changed"):
                key_rotation.rotate(
                    fixture.config_path,
                    expected_config_sha256="0" * 64,
                    expected_plan_id=fixture.config["plan_id"],
                    expected_generation=1,
                    expected_user_sid=SID,
                    sid_reader=lambda: SID,
                    require_manifest=False,
                )
            with RunLock(fixture.state / "run.lock"):
                with self.assertRaises(Exception):
                    fixture.rotate()
            self.assertEqual(
                keys_before,
                sorted(path.name for path in (fixture.repository / "keys").iterdir()),
            )
            self.assertFalse((fixture.state / key_rotation.JOURNAL_NAME).exists())

    def test_normal_runtime_refuses_pending_rotation_journal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-journal-gate-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            journal = fixture.state / key_rotation.JOURNAL_NAME
            key_rotation._write_protected_json(journal, {"schema_version": 1})
            with self.assertRaisesRegex(RuntimeError, "credential-rotation.journal.json"):
                config, lock = key_rotation.load_config_under_lock(fixture.config_path)
                lock.__exit__(None, None, None)


if __name__ == "__main__":
    unittest.main()
