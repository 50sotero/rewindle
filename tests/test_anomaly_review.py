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

import anomaly_review  # noqa: E402
from restic_common import RunLock, atomic_write_json  # noqa: E402
from secret_store import restrict_acl, secure_directory  # noqa: E402


PLAN_ID = "10000000-0000-4000-8000-000000000088"
REPOSITORY_ID = "a" * 64
SNAPSHOT_ID = "b" * 64
RUN_ID = "20260721T120000-deadbeef"
SID = "S-1-5-21-1000-2000-3000-4000"


def volume_serial(path: Path) -> str:
    drive = path.resolve().drive.upper()
    result = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            f"(Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='{drive}'\").VolumeSerialNumber",
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    return result.stdout.strip().upper()


class ReviewFixture:
    def __init__(self, root: Path):
        self.root = root
        self.state = root / "state"
        self.repository = root / "repository"
        self.repository.mkdir()
        (self.repository / "config").write_text("repository config unchanged", encoding="utf-8")
        self.source = root / "source"
        self.source.mkdir()
        self.canary = self.source / "canary.txt"
        self.canary.write_text("canary", encoding="utf-8")
        self.excludes = root / "excludes.txt"
        self.excludes.write_text("**/__pycache__\n", encoding="utf-8")
        self.restic = root / "restic.exe"
        self.restic.write_bytes(b"fixture")
        secure_directory(self.state)
        self.config_path = root / "config.json"
        self.config = {
            "schema_version": 1,
            "plan_id": PLAN_ID,
            "config_generation": 3,
            "repository": str(self.repository),
            "repository_volume_serial": volume_serial(root),
            "restic_executable": str(self.restic),
            "recovery_tools_directory": str(root / "recovery"),
            "python_executable": sys.executable,
            "state_directory": str(self.state),
            "secret_file": str(self.state / "secret.json"),
            "recovery_key_file": str(root / "recovery-key.txt"),
            "exclude_file": str(self.excludes),
            "canary_file": str(self.canary),
            "hostname": "ANOMALY-REVIEW-TEST",
            "scheduled_tag": "scheduled",
            "cloud_placeholder_policy": "strict",
            "sources": [str(self.source)],
            "source_identities": {
                str(self.source): {"expected_volume_serial": volume_serial(self.source)}
            },
        }
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.evidence = {
            "schema_version": 1,
            "state": "success",
            "verification_complete": True,
            "maintenance_hold": True,
            "plan_id": PLAN_ID,
            "config_generation": 3,
            "repository_id": REPOSITORY_ID,
            "run_id": RUN_ID,
            "snapshot_id": SNAPSHOT_ID,
            "change_anomaly": {
                "schema_version": 1,
                "evaluated": True,
                "status": "hold",
                "hold": True,
                "reasons": ["deletion_ratio"],
                "measurements": {"deletion_ratio": 0.42},
            },
        }
        self.evidence_path = self.state / "last-success.json"
        atomic_write_json(self.evidence_path, self.evidence)
        restrict_acl(self.evidence_path)

    def approve(self, **overrides):
        arguments = {
            "expected_config_sha256": anomaly_review.sha256_file(self.config_path),
            "expected_plan_id": PLAN_ID,
            "expected_generation": 3,
            "expected_user_sid": SID,
            "expected_run_id": RUN_ID,
            "expected_snapshot_id": SNAPSHOT_ID,
            "expected_evidence_sha256": anomaly_review.sha256_file(self.evidence_path),
            "sid_reader": lambda: SID,
            "require_manifest": False,
        }
        arguments.update(overrides)
        return anomaly_review.approve(self.config_path, **arguments)


class AnomalyReviewTests(unittest.TestCase):
    def test_exact_review_acknowledges_only_evidence_and_preserves_backup(self) -> None:
        with tempfile.TemporaryDirectory(prefix="anomaly-review-") as root_text:
            fixture = ReviewFixture(Path(root_text))
            evidence_before = fixture.evidence_path.read_bytes()
            repository_before = (fixture.repository / "config").read_bytes()
            result = fixture.approve()
            self.assertEqual("approved", result["state"])
            self.assertEqual(
                ["anomaly_review_acknowledgement"],
                result["scope"],
            )
            self.assertTrue(result["maintenance_hold_remains"])
            self.assertFalse(result["snapshots_modified"])
            self.assertFalse(result["repository_modified"])
            self.assertEqual(evidence_before, fixture.evidence_path.read_bytes())
            self.assertEqual(repository_before, (fixture.repository / "config").read_bytes())
            acknowledgement = json.loads(
                (fixture.state / anomaly_review.ACKNOWLEDGEMENT_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual(
                anomaly_review.sha256_file(fixture.evidence_path),
                acknowledgement["backup_evidence_sha256"],
            )
            self.assertEqual(SNAPSHOT_ID, acknowledgement["snapshot_id"])
            history = json.loads(
                (fixture.state / anomaly_review.HISTORY_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual(1, len(history["reviews"]))

            second = fixture.approve()
            self.assertEqual("already_approved", second["state"])
            history_after = json.loads(
                (fixture.state / anomaly_review.HISTORY_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual(1, len(history_after["reviews"]))

    def test_evidence_plan_run_and_snapshot_binding_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="anomaly-review-binding-") as root_text:
            fixture = ReviewFixture(Path(root_text))
            invalid = (
                ({"expected_plan_id": "20000000-0000-4000-8000-000000000088"}, "plan generation"),
                ({"expected_run_id": "another-run"}, "current verified anomaly"),
                ({"expected_snapshot_id": "c" * 64}, "current verified anomaly"),
                ({"expected_evidence_sha256": "d" * 64}, "changed after"),
            )
            for overrides, message in invalid:
                with self.subTest(overrides=overrides):
                    with self.assertRaisesRegex(RuntimeError, message):
                        fixture.approve(**overrides)
            self.assertFalse((fixture.state / anomaly_review.ACKNOWLEDGEMENT_NAME).exists())

    def test_global_run_lock_blocks_review_without_writing_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory(prefix="anomaly-review-lock-") as root_text:
            fixture = ReviewFixture(Path(root_text))
            with RunLock(fixture.state / "run.lock"):
                with self.assertRaises(Exception):
                    fixture.approve()
            self.assertFalse((fixture.state / anomaly_review.ACKNOWLEDGEMENT_NAME).exists())


if __name__ == "__main__":
    unittest.main()
