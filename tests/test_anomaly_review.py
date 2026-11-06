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

    def test_evidence_with_the_state_folders_inherited_admin_only_acl_is_accepted(self) -> None:
        # backup.py writes last-success.json with the permissions it inherits from the state folder, which only
        # Administrators and SYSTEM can change. A non-elevated test cannot make a file Administrator-owned, so the
        # descriptors are those of a real install.
        with tempfile.TemporaryDirectory(prefix="anomaly-review-inherited-") as root_text:
            fixture = ReviewFixture(Path(root_text))
            fixture.evidence_path.unlink()
            atomic_write_json(fixture.evidence_path, fixture.evidence)
            descriptors = {
                fixture.evidence_path: INSTALLED_EVIDENCE_SDDL,
                fixture.state: INSTALLED_STATE_FOLDER_SDDL,
            }
            seen: list[Path] = []

            def installed_descriptor(path: Path, *, include_owner: bool = False) -> str:
                self.assertTrue(include_owner)
                seen.append(Path(path))
                return descriptors[Path(path)]

            with mock.patch.object(anomaly_review, "_security_sddl", installed_descriptor):
                result = fixture.approve()
            self.assertEqual("approved", result["state"])
            self.assertEqual([fixture.evidence_path, fixture.state], seen)

    def test_evidence_a_user_could_change_is_refused(self) -> None:
        with tempfile.TemporaryDirectory(prefix="anomaly-review-unprotected-") as root_text:
            fixture = ReviewFixture(Path(root_text))
            fixture.evidence_path.unlink()
            atomic_write_json(fixture.evidence_path, fixture.evidence)
            # The real descriptor of a file in a user's temporary folder: owned by the user.
            with self.assertRaisesRegex(RuntimeError, "not protected"):
                fixture.approve()
            user_writable_folder = INSTALLED_STATE_FOLDER_SDDL.replace(f"0x1200a9;;;{SID}", f"0x1301bf;;;{SID}")
            descriptors = {
                fixture.evidence_path: INSTALLED_EVIDENCE_SDDL,
                fixture.state: user_writable_folder,
            }
            with mock.patch.object(
                anomaly_review,
                "_security_sddl",
                lambda path, include_owner=False: descriptors[Path(path)],
            ):
                with self.assertRaisesRegex(RuntimeError, "evidence folder is not protected"):
                    fixture.approve()
            self.assertFalse((fixture.state / anomaly_review.ACKNOWLEDGEMENT_NAME).exists())


class AdminOnlyWritableTests(unittest.TestCase):
    def test_installed_state_folder_and_evidence_pass(self) -> None:
        self.assertIsNone(anomaly_review.admin_only_writable_problem(INSTALLED_EVIDENCE_SDDL))
        self.assertIsNone(anomaly_review.admin_only_writable_problem(INSTALLED_STATE_FOLDER_SDDL))
        # SYSTEM may own it, and entries that only pass to children or deny access change nothing here.
        self.assertIsNone(
            anomaly_review.admin_only_writable_problem(
                f"O:SYG:SYD:PAI(A;;FA;;;SY)(A;OICIIO;FA;;;CO)(D;;FW;;;{SID})(A;;FR;;;{SID})(A;;GRGX;;;BU)"
            )
        )

    def test_anything_another_account_could_change_fails(self) -> None:
        refused = {
            "owned by the user": INSTALLED_EVIDENCE_SDDL.replace("O:BA", f"O:{SID}"),
            "user full control": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;FA;;;{SID})",
            "user write": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;FW;;;{SID})",
            "user delete": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;0x1300a9;;;{SID})",
            "user re-permission": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;0x1600a9;;;{SID})",
            "user generic all": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;GA;;;{SID})",
            "users add a file": "O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;CI;0x100006;;;BU)",
            "everyone write": "O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;0x120116;;;WD)",
            "flags in another order": f"O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;CIOI;FA;;;{SID})",
            "unknown rights": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(A;ID;ZZ;;;{SID})",
            "callback entry": f"O:BAG:SYD:AI(A;ID;FA;;;BA)(XA;;FR;;;{SID};(x))",
            "no access list": "O:BAG:SYD:NO_ACCESS_CONTROL",
            "empty access list": "O:BAG:SYD:P",
            "no owner": "D:P(A;;FA;;;BA)",
        }
        for label, sddl in refused.items():
            with self.subTest(label):
                self.assertIsNotNone(anomaly_review.admin_only_writable_problem(sddl))


INSTALLED_STATE_FOLDER_SDDL = (
    f"O:BAG:{SID}D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;{SID})"
)
INSTALLED_EVIDENCE_SDDL = f"O:BAG:{SID}D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;{SID})"


if __name__ == "__main__":
    unittest.main()
