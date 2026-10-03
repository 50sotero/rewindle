from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402


PLAN_ID = "10000000-0000-4000-8000-000000000099"
REPOSITORY_ID = "a" * 64


def summary(
    *, total_files: int, total_bytes: int, new: int, changed: int, added: int
) -> dict:
    return {
        "message_type": "summary",
        "total_files_processed": total_files,
        "total_bytes_processed": total_bytes,
        "files_new": new,
        "files_changed": changed,
        "data_added": added,
    }


def config() -> dict:
    return {
        "plan_id": PLAN_ID,
        "config_generation": 4,
        "sources": [r"C:\Data"],
        "exclude_file": r"C:\Protected\excludes.txt",
    }


def prior(prior_summary: dict) -> dict:
    return {
        "state": "success",
        "verification_complete": True,
        "plan_id": PLAN_ID,
        "config_generation": 4,
        "sources": [r"C:\Data"],
        "exclude_file_sha256": "b" * 64,
        "repository_id": REPOSITORY_ID,
        "summary": prior_summary,
    }


class ChangeAnomalyTests(unittest.TestCase):
    def evaluate(self, current: dict, previous: dict | None, configuration=None):
        with (
            mock.patch.object(backup, "sha256_file", return_value="b" * 64),
            mock.patch.object(
                backup, "read_recorded_repository_id", return_value=REPOSITORY_ID
            ),
        ):
            return backup.evaluate_change_anomaly(
                current, previous, configuration or config()
            )

    def test_first_run_is_not_comparable_and_never_held(self) -> None:
        result = self.evaluate(
            summary(
                total_files=250_000,
                total_bytes=20_000_000,
                new=250_000,
                changed=0,
                added=10_000_000,
            ),
            None,
        )
        self.assertFalse(result["evaluated"])
        self.assertFalse(result["hold"])
        self.assertEqual("not_comparable", result["status"])

    def test_normal_incremental_change_is_clear(self) -> None:
        result = self.evaluate(
            summary(
                total_files=100_050,
                total_bytes=1_001_000_000,
                new=100,
                changed=250,
                added=2_000_000,
            ),
            prior(
                summary(
                    total_files=100_000,
                    total_bytes=1_000_000_000,
                    new=0,
                    changed=0,
                    added=0,
                )
            ),
        )
        self.assertTrue(result["evaluated"])
        self.assertEqual("clear", result["status"])
        self.assertEqual(50, result["measurements"]["estimated_deleted_files"])
        self.assertFalse(result["hold"])

    def test_mass_rewrite_sets_non_destructive_hold(self) -> None:
        result = self.evaluate(
            summary(
                total_files=100_000,
                total_bytes=1_000_000_000,
                new=1_000,
                changed=40_000,
                added=600_000_000,
            ),
            prior(
                summary(
                    total_files=100_000,
                    total_bytes=1_000_000_000,
                    new=0,
                    changed=0,
                    added=0,
                )
            ),
        )
        self.assertTrue(result["hold"])
        self.assertEqual("hold", result["status"])
        self.assertIn("file_change_ratio", result["reasons"])
        self.assertIn("data_added_ratio", result["reasons"])

    def test_deletion_estimate_accounts_for_new_files(self) -> None:
        result = self.evaluate(
            summary(
                total_files=85_500,
                total_bytes=850_000_000,
                new=500,
                changed=0,
                added=2_000_000,
            ),
            prior(
                summary(
                    total_files=100_000,
                    total_bytes=1_000_000_000,
                    new=0,
                    changed=0,
                    added=0,
                )
            ),
        )
        self.assertEqual(15_000, result["measurements"]["estimated_deleted_files"])
        self.assertTrue(result["hold"])
        self.assertEqual(["deletion_ratio"], result["reasons"])

    def test_generation_change_is_not_compared(self) -> None:
        previous = prior(
            summary(
                total_files=100_000,
                total_bytes=1_000_000_000,
                new=0,
                changed=0,
                added=0,
            )
        )
        previous["config_generation"] = 3
        result = self.evaluate(
            summary(
                total_files=1,
                total_bytes=1,
                new=1,
                changed=0,
                added=1,
            ),
            previous,
        )
        self.assertFalse(result["evaluated"])
        self.assertFalse(result["hold"])

    def test_minimum_file_gate_avoids_noise_and_policy_can_disable(self) -> None:
        configuration = config()
        configuration["change_anomaly"] = {
            "enabled": True,
            "file_change_ratio": 0.01,
            "deletion_ratio": 0.01,
            "data_added_ratio": 0.01,
            "minimum_changed_files": 1000,
        }
        previous = prior(
            summary(
                total_files=500,
                total_bytes=1000,
                new=0,
                changed=0,
                added=0,
            )
        )
        result = self.evaluate(
            summary(
                total_files=400,
                total_bytes=400,
                new=0,
                changed=400,
                added=900,
            ),
            previous,
            configuration,
        )
        self.assertFalse(result["hold"])

        configuration["change_anomaly"]["enabled"] = False
        disabled = self.evaluate(
            summary(
                total_files=0,
                total_bytes=0,
                new=0,
                changed=0,
                added=0,
            ),
            previous,
            configuration,
        )
        self.assertEqual("disabled", disabled["status"])

    def test_prior_telemetry_loader_is_bounded_and_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory(prefix="anomaly-prior-") as root_text:
            path = Path(root_text) / "last-success.json"
            path.write_text(json.dumps({"state": "success"}), encoding="utf-8")
            self.assertEqual(
                "success", backup.load_prior_success_for_anomaly(path)["state"]
            )
            path.write_text("not json", encoding="utf-8")
            self.assertIsNone(backup.load_prior_success_for_anomaly(path))
            with path.open("wb") as handle:
                handle.truncate(backup.MAX_PRIOR_SUCCESS_BYTES + 1)
            self.assertIsNone(backup.load_prior_success_for_anomaly(path))


if __name__ == "__main__":
    unittest.main()
