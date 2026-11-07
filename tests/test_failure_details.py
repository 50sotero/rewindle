from __future__ import annotations

import argparse
import contextlib
import ctypes
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
if str(SOURCE) not in sys.path:
    sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402
import restic_common  # noqa: E402


def other_serial(serial: str) -> str:
    """A serial that differs from the real one, worked out at run time."""
    return f"{int(serial, 16) ^ 1:08X}"


def unused_drive_letter() -> str:
    mask = ctypes.WinDLL("kernel32").GetLogicalDrives()
    # D: and G: are left alone even when nothing is mounted there.
    for letter in "ZYXWVUTSRQPONMLKJIHFE":
        if not mask & (1 << (ord(letter) - ord("A"))):
            return letter
    raise unittest.SkipTest("every drive letter is in use")


class FailureDetailsTests(unittest.TestCase):
    def test_failure_classification_is_stable_by_phase(self) -> None:
        cases = (
            ("checking_repository_storage", RuntimeError("fixture"), 1,
             ("repository_storage", "repository_storage_unavailable")),
            ("preflighting_sources", RuntimeError("fixture"), 1,
             ("source_preflight", "source_preflight_failed")),
            ("authenticating_repository", RuntimeError("fixture"), 1,
             ("repository_authentication", "repository_authentication_failed")),
            ("partial", RuntimeError("fixture"), 3,
             ("backup", "source_data_unreadable")),
            ("checking_repository", RuntimeError("fixture"), 1,
             ("repository_structure_check", "repository_structure_check_failed")),
            ("restoring_canary", RuntimeError("fixture"), 1,
             ("restore_canary", "restore_canary_failed")),
            ("checking_data_subset", RuntimeError("fixture"), 1,
             ("repository_data_check", "repository_data_check_failed")),
        )
        for phase, error, exit_code, expected in cases:
            with self.subTest(phase=phase):
                self.assertEqual(
                    backup.classify_failure(phase, error, exit_code), expected
                )

    def test_the_wording_of_a_message_never_picks_the_code(self) -> None:
        # Restic's or Windows's own text can mention anything; only the place
        # the engine recognised the problem decides the code.
        self.assertEqual(
            ("backup", "restic_backup_failed"),
            backup.classify_failure(
                "backing_up",
                RuntimeError("not enough free space; volume serial changed"),
                1,
            ),
        )
        self.assertEqual(
            ("repository_storage", "repository_storage_unavailable"),
            backup.classify_failure(
                "checking_repository_storage",
                RuntimeError("volume identity is unavailable"),
                1,
            ),
        )

    def test_engine_failures_carry_their_own_code(self) -> None:
        cases = (
            (restic_common.RepositoryLowSpace("x"), "repository_low_space"),
            (restic_common.RepositoryVolumeMismatch("x"), "volume_identity_mismatch"),
            (restic_common.SourcePreflightFailed("x"), "source_preflight_failed"),
        )
        for error, code in cases:
            with self.subTest(code=code):
                self.assertIsInstance(error, RuntimeError)
                self.assertEqual(
                    code,
                    backup.classify_failure("checking_repository_storage", error, 1)[1],
                )
        # Unreadable files keep their own code whatever stopped the run.
        self.assertEqual(
            "source_data_unreadable",
            backup.classify_failure(
                "partial", restic_common.RepositoryLowSpace("x"), 3
            )[1],
        )

    def test_affected_paths_are_bounded_absolute_and_deduplicated(self) -> None:
        errors = [
            {"message_type": "error", "item": rf"E:\source\file-{index}.txt"}
            for index in range(70)
        ]
        errors.extend(
            [
                {"item": "E:\\source\\file-1.txt"},
                {"item": "relative.txt"},
                {"item": "E:\\source\\bad\npath.txt"},
                {"error": {"path": "F:\\other\\locked.docx"}},
            ]
        )
        status = {
            "errors": errors,
            "source_preflight": {
                "sources": [
                    {
                        "canonical_path": "G:\\missing",
                        "overall_status": "missing",
                    }
                ]
            },
        }
        paths = backup.collect_affected_paths(status)
        self.assertEqual(len(paths), backup.MAX_AFFECTED_PATHS)
        self.assertEqual(len({path.casefold() for path in paths}), len(paths))
        self.assertTrue(all(":" in path[:3] for path in paths))
        self.assertNotIn("relative.txt", paths)


class RealEngineFailureTests(unittest.TestCase):
    """Each run stops in a real engine check, with that check's own message."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="failure-details-")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.source = root / "source"
        self.source.mkdir()
        self.repository = root / "repository"
        self.repository.mkdir()
        self.state = root / "state"
        self.state.mkdir()
        excludes = root / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8")
        restic = root / "restic.exe"
        restic.write_bytes(b"fixture")
        canary = self.source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8")
        self.real_serial = restic_common.volume_serial(root)
        self.config: dict[str, object] = {
            "plan_id": "20000000-0000-4000-8000-000000000003",
            "config_generation": 1,
            "scheduled_tag": "scheduled",
            "state_directory": str(self.state),
            "repository": str(self.repository),
            "repository_volume_serial": self.real_serial,
            "minimum_free_gib": 0,
            "hostname": "FAILURE-TEST",
            "sources": [str(self.source)],
            "exclude_file": str(excludes),
            "restic_executable": str(restic),
            "canary_file": str(canary),
            "source_identities": {
                str(self.source): {"expected_volume_serial": self.real_serial}
            },
            "cloud_placeholder_policy": "strict",
        }

    def run_backup(self, *patches) -> dict[str, object]:
        args = argparse.Namespace(tag=None, scheduled=True)
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(backup, "process_start_filetime", return_value="1")
            )
            restic_capture = stack.enter_context(mock.patch.object(backup, "run_capture"))
            restic_stream = stack.enter_context(mock.patch.object(backup, "stream_command"))
            for patch in patches:
                stack.enter_context(patch)
            result = backup._run_locked(args, self.config)
        self.assertEqual(1, result)
        restic_capture.assert_not_called()
        restic_stream.assert_not_called()
        status = json.loads((self.state / "status.json").read_text(encoding="utf-8"))
        self.assertEqual("failed", status["state"])
        return status

    def test_full_backup_drive_is_low_space(self) -> None:
        self.config["minimum_free_gib"] = 10**9

        status = self.run_backup()

        self.assertIn("GiB free", status["failure"])
        self.assertEqual("repository_storage", status["failure_phase"])
        self.assertEqual("repository_low_space", status["failure_code"])

    def test_different_drive_at_the_backup_letter_is_a_volume_mismatch(self) -> None:
        self.config["repository_volume_serial"] = other_serial(self.real_serial)

        status = self.run_backup()

        self.assertIn("repository volume mismatch", status["failure"])
        self.assertEqual("repository_storage", status["failure_phase"])
        self.assertEqual("volume_identity_mismatch", status["failure_code"])

    def test_missing_backup_drive_is_storage_unavailable(self) -> None:
        letter = unused_drive_letter()
        self.config["repository"] = f"{letter}:\\Backups\\Rewindle"

        status = self.run_backup()

        self.assertEqual("repository_storage", status["failure_phase"])
        self.assertEqual("repository_storage_unavailable", status["failure_code"])

    def test_unavailable_source_drive_is_a_source_problem(self) -> None:
        status = self.run_backup(
            # The backup location is fine; only the protected folder's drive
            # stops answering when Windows is asked for its identity.
            mock.patch.object(backup, "validate_repository_volume"),
            mock.patch.object(
                restic_common,
                "volume_serial",
                side_effect=OSError(21, "The device is not ready"),
            ),
        )

        self.assertIn("source volume identity is unavailable", status["failure"])
        self.assertEqual(
            "unavailable", status["source_preflight"]["sources"][0]["volume_identity"]
        )
        self.assertEqual("source_preflight", status["failure_phase"])
        self.assertEqual("source_preflight_failed", status["failure_code"])

    def test_different_drive_at_a_source_letter_is_a_source_problem(self) -> None:
        self.config["source_identities"] = {
            str(self.source): {"expected_volume_serial": other_serial(self.real_serial)}
        }

        status = self.run_backup()

        self.assertIn("source volume mismatch", status["failure"])
        self.assertEqual("source_preflight", status["failure_phase"])
        self.assertEqual("source_preflight_failed", status["failure_code"])


if __name__ == "__main__":
    unittest.main()
