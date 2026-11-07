"""A verified backup records how much space the backups take, for the dashboard."""

from __future__ import annotations

import argparse
import contextlib
import functools
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402
import restic_common  # noqa: E402
from restic_common import measure_repository_bytes  # noqa: E402


TEST_PLAN_ID = "20000000-0000-4000-8000-000000000005"
TEST_PLAN_TAG = "restic-backuper-plan:" + TEST_PLAN_ID
TEST_GENERATION_TAG = "restic-backuper-generation:1"
REPOSITORY_ID = "c" * 64
FILE_ATTRIBUTE_DIRECTORY = 0x10
FILE_ATTRIBUTE_REPARSE_POINT = 0x400


def write_bytes(path: Path, size: int) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"r" * size)
    return size


def fill_repository(repository: Path) -> int:
    """A small folder shaped like a Restic repository; returns its exact size."""
    total = write_bytes(repository / "config", 155)
    total += write_bytes(repository / "keys" / ("1" * 64), 460)
    total += write_bytes(repository / "data" / "ab" / ("ab" + "2" * 62), 4096)
    total += write_bytes(repository / "data" / "cd" / ("cd" + "3" * 62), 70001)
    total += write_bytes(repository / "index" / ("4" * 64), 812)
    total += write_bytes(repository / "snapshots" / ("5" * 64), 301)
    (repository / "locks").mkdir()
    return total


@contextlib.contextmanager
def hung_listing(repository: Path, *, longest: float = 8.0):
    """Listing any folder of the backup location blocks, as on a Google Drive for desktop that hangs; other folders list as usual.

    The listing gives up by itself after `longest` seconds, so a measurement that waits for it (no hard limit) is slow rather
    than stuck forever. On the way out the listing is let go and the walk left behind is waited for, so the temporary folder
    can be removed.
    """
    real_scandir = os.scandir
    root = os.path.normcase(os.path.abspath(repository))
    listing = SimpleNamespace(entered=threading.Event(), release=threading.Event())

    def scandir(path=None):
        target = os.path.normcase(os.path.abspath(os.fspath(path if path is not None else ".")))
        if target == root or target.startswith(root + os.sep):
            listing.entered.set()
            listing.release.wait(longest)
            raise OSError("the folder listing did not come back")
        return real_scandir(path) if path is not None else real_scandir()

    try:
        with mock.patch.object(restic_common.os, "scandir", side_effect=scandir):
            yield listing
    finally:
        listing.release.set()
        for thread in threading.enumerate():
            if thread.name == "repository-size-walk":
                thread.join(10)


class MeasureRepositoryBytesTests(unittest.TestCase):
    def test_adds_up_every_regular_file_in_nested_folders(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            repository = Path(root_text) / "repository"
            expected = fill_repository(repository)
            self.assertEqual(expected, measure_repository_bytes(repository))

    def test_an_empty_folder_takes_no_space(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            self.assertEqual(0, measure_repository_bytes(Path(root_text)))

    def test_gives_up_on_a_junction_inside_and_never_follows_it(self) -> None:
        if os.name != "nt":
            self.skipTest("junctions are a Windows feature")
        import _winapi

        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            root = Path(root_text)
            repository = root / "repository"
            fill_repository(repository)
            outside = root / "outside"
            write_bytes(outside / "large.bin", 1_000_000)
            _winapi.CreateJunction(str(outside), str(repository / "data" / "planted"))
            listed: list[str] = []
            real_scandir = os.scandir

            def watching_scandir(path):
                listed.append(os.fspath(path))
                return real_scandir(path)

            with mock.patch.object(restic_common.os, "scandir", side_effect=watching_scandir):
                self.assertIsNone(measure_repository_bytes(repository))
            self.assertFalse(any("planted" in path for path in listed), listed)

    def test_gives_up_on_a_location_that_is_itself_a_junction(self) -> None:
        if os.name != "nt":
            self.skipTest("junctions are a Windows feature")
        import _winapi

        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            root = Path(root_text)
            real = root / "real"
            fill_repository(real)
            _winapi.CreateJunction(str(real), str(root / "linked"))
            self.assertIsNone(measure_repository_bytes(root / "linked"))

    def test_gives_up_on_a_symbolic_link_to_a_folder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            root = Path(root_text)
            repository = root / "repository"
            fill_repository(repository)
            outside = root / "outside"
            write_bytes(outside / "large.bin", 1_000_000)
            try:
                os.symlink(outside, repository / "index" / "planted", target_is_directory=True)
            except OSError:
                self.skipTest("this account may not create symbolic links")
            self.assertIsNone(measure_repository_bytes(repository))

    def test_an_unreadable_folder_gives_no_size(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            repository = Path(root_text) / "repository"
            fill_repository(repository)
            with mock.patch.object(
                restic_common.os, "scandir", side_effect=PermissionError(5, "Access is denied")
            ):
                self.assertIsNone(measure_repository_bytes(repository))

    def test_a_walk_past_the_time_limit_gives_no_size(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            repository = Path(root_text) / "repository"
            expected = fill_repository(repository)
            ticks = iter(range(0, 10_000, 61))
            self.assertIsNone(
                measure_repository_bytes(repository, clock=lambda: float(next(ticks)))
            )
            # Within the limit the same folder is measured, with the default limit of about 15 seconds.
            slow = iter(range(0, 10_000, 1))
            self.assertEqual(
                expected, measure_repository_bytes(repository, clock=lambda: float(next(slow)))
            )
            self.assertLessEqual(restic_common.REPOSITORY_SIZE_TIME_LIMIT_SECONDS, 15.0)

    def test_a_folder_listing_that_never_returns_gives_no_size_at_the_limit(self) -> None:
        # A Google Drive for desktop that hangs: one listing does not come back. The limit still holds, so the end of a
        # verified backup is never held up by it.
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            repository = Path(root_text) / "repository"
            fill_repository(repository)
            with hung_listing(repository) as listing:
                started = time.monotonic()
                measured = measure_repository_bytes(repository, time_limit_seconds=0.5)
                waited = time.monotonic() - started
            self.assertTrue(listing.entered.is_set())
            self.assertIsNone(measured)
            self.assertLess(waited, 4.0)

    def test_a_missing_location_or_a_file_gives_no_size(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-") as root_text:
            root = Path(root_text)
            self.assertIsNone(measure_repository_bytes(root / "missing"))
            write_bytes(root / "a-file", 10)
            self.assertIsNone(measure_repository_bytes(root / "a-file"))


class RepositoryEntryKindTests(unittest.TestCase):
    """Decided from each entry's own metadata. A regular file that carries the reparse attribute cannot be made portably, so these
    use stand-ins for the metadata a folder listing gives."""

    @staticmethod
    def entry(mode: int, attributes: int = 0) -> SimpleNamespace:
        return SimpleNamespace(st_mode=mode, st_file_attributes=attributes, st_size=10)

    def test_a_regular_file_counts_even_with_the_reparse_attribute(self) -> None:
        kind = restic_common._repository_entry_kind
        self.assertEqual("file", kind(self.entry(stat.S_IFREG | 0o666)))
        # Cloud placeholders and deduplicated files: the listed size is read, nothing is followed.
        self.assertEqual("file", kind(self.entry(stat.S_IFREG | 0o666, FILE_ATTRIBUTE_REPARSE_POINT)))

    def test_only_plain_folders_are_entered(self) -> None:
        kind = restic_common._repository_entry_kind
        self.assertEqual("folder", kind(self.entry(stat.S_IFDIR | 0o777, FILE_ATTRIBUTE_DIRECTORY)))
        # A junction, as Python lists it on Windows.
        self.assertEqual(
            "linked_folder",
            kind(self.entry(stat.S_IFDIR | 0o777, FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)),
        )
        # A symbolic link to a folder.
        self.assertEqual(
            "linked_folder",
            kind(self.entry(stat.S_IFLNK | 0o777, FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)),
        )

    def test_a_link_to_a_file_is_skipped(self) -> None:
        kind = restic_common._repository_entry_kind
        self.assertEqual("other", kind(self.entry(stat.S_IFLNK | 0o777, FILE_ATTRIBUTE_REPARSE_POINT)))


class RunFixture:
    def __init__(self, root: Path) -> None:
        self.source = root / "source"
        self.source.mkdir()
        self.repository = root / "repository"
        self.expected_bytes = fill_repository(self.repository)
        self.state = root / "state"
        self.state.mkdir()
        excludes = root / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8", newline="\n")
        restic = root / "restic.exe"
        restic.write_bytes(b"fixture")
        canary = self.source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8", newline="\n")
        self.config: dict[str, object] = {
            "plan_id": TEST_PLAN_ID,
            "config_generation": 1,
            "scheduled_tag": "scheduled",
            "state_directory": str(self.state),
            "repository": str(self.repository),
            "repository_volume_serial": "A1B2C3D4",
            "hostname": "SIZE-TEST",
            "sources": [str(self.source)],
            "exclude_file": str(excludes),
            "restic_executable": str(restic),
            "canary_file": str(canary),
            "use_vss": False,
            "read_concurrency": 2,
            "structural_check_after_backup": True,
            "read_data_subset_parts": 0,
            "source_identities": {str(self.source): {"expected_volume_serial": "A1B2C3D4"}},
            "cloud_placeholder_policy": "strict",
        }

    def document(self, name: str) -> dict[str, object]:
        return json.loads((self.state / name).read_text(encoding="utf-8"))

    def run(self, *extra_patches) -> int:
        snapshot_calls = 0
        source = self.source

        def fake_capture(command, **_kwargs):
            nonlocal snapshot_calls
            if command[1] == "cat":
                return subprocess.CompletedProcess(
                    ["restic"], 0, json.dumps({"id": REPOSITORY_ID, "version": 2}), ""
                )
            snapshot_calls += 1
            payload = []
            if snapshot_calls > 1:
                payload = [
                    {
                        "id": "size-snapshot",
                        "hostname": "SIZE-TEST",
                        "tags": ["scheduled", TEST_PLAN_TAG, TEST_GENERATION_TAG],
                        "paths": [str(source)],
                        "time": "2026-11-09T02:00:00Z",
                    }
                ]
            return subprocess.CompletedProcess(["restic"], 0, json.dumps(payload), "")

        def fake_stream(command, _log, on_line=None, **_kwargs):
            if command[1] == "backup":
                on_line(
                    json.dumps(
                        {
                            "message_type": "summary",
                            "snapshot_id": "size-snapshot",
                            "total_files_processed": 1,
                            "total_bytes_processed": 1,
                            "files_new": 1,
                            "files_changed": 0,
                            "data_added": 1,
                        }
                    )
                )
                return 0
            if command[1] == "check":
                return 0
            raise AssertionError(f"unexpected fake Restic verb: {command[1]}")

        ready = {
            "schema_version": 1,
            "policy": "strict",
            "status": "ready",
            "sources": [
                {
                    "canonical_path": str(source),
                    "readiness": "ready",
                    "volume_identity": "match",
                    "overall_status": "ready",
                }
            ],
            "failures": [],
        }
        patches = [
            mock.patch.object(backup, "validate_repository_volume"),
            mock.patch.object(backup, "ensure_free_space", return_value=1),
            mock.patch.object(backup, "preflight_sources", return_value=ready),
            mock.patch.object(backup, "restic_base", return_value=["restic"]),
            mock.patch.object(backup, "run_capture", side_effect=fake_capture),
            mock.patch.object(backup, "stream_command", side_effect=fake_stream),
            mock.patch.object(backup, "verify_canary", return_value={"verified": True}),
            mock.patch.object(backup, "process_start_filetime", return_value="133733333333333333"),
            *extra_patches,
        ]
        for patch in patches:
            patch.start()
        try:
            return backup._run_locked(argparse.Namespace(tag=None, scheduled=True), self.config)
        finally:
            for patch in reversed(patches):
                patch.stop()


class VerifiedBackupRecordsSizeTests(unittest.TestCase):
    def test_a_verified_backup_records_the_size_of_the_backup_folder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-run-") as root_text:
            fixture = RunFixture(Path(root_text))
            self.assertEqual(0, fixture.run())
            status = fixture.document("status.json")
            last_success = fixture.document("last-success.json")
            self.assertEqual("success", status["state"])
            self.assertEqual(fixture.expected_bytes, status["repository_bytes_after"])
            self.assertEqual(fixture.expected_bytes, last_success["repository_bytes_after"])

    def test_the_size_is_measured_before_the_finish_time_is_taken(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-run-") as root_text:
            fixture = RunFixture(Path(root_text))
            events: list[tuple[str, str]] = []
            real_now = backup.utc_now
            real_measure = backup.measure_repository_bytes

            def noting_now() -> str:
                value = real_now()
                events.append(("now", value))
                return value

            def noting_measure(*args, **kwargs):
                events.append(("measure", ""))
                return real_measure(*args, **kwargs)

            self.assertEqual(
                0,
                fixture.run(
                    mock.patch.object(backup, "utc_now", side_effect=noting_now),
                    mock.patch.object(backup, "measure_repository_bytes", side_effect=noting_measure),
                ),
            )
            measured = events.index(("measure", ""))
            later = [value for kind, value in events[measured + 1:] if kind == "now"]
            self.assertIn(fixture.document("status.json")["finished_utc"], later)

    def test_a_size_that_cannot_be_measured_is_left_empty_and_the_backup_still_counts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-run-") as root_text:
            fixture = RunFixture(Path(root_text))
            self.assertEqual(
                0, fixture.run(mock.patch.object(backup, "measure_repository_bytes", return_value=None))
            )
            status = fixture.document("status.json")
            self.assertEqual("success", status["state"])
            self.assertIn("repository_bytes_after", status)
            self.assertIsNone(status["repository_bytes_after"])
            self.assertIsNone(fixture.document("last-success.json")["repository_bytes_after"])

    def test_a_backup_folder_that_hangs_does_not_hold_up_the_end_of_a_verified_backup(self) -> None:
        # The scheduled task ignores a new start while a run is still going, so a run held up here would cost the next backups.
        with tempfile.TemporaryDirectory(prefix="repository-size-run-") as root_text:
            fixture = RunFixture(Path(root_text))
            quick = functools.partial(measure_repository_bytes, time_limit_seconds=0.5)
            with hung_listing(fixture.repository) as listing:
                started = time.monotonic()
                code = fixture.run(mock.patch.object(backup, "measure_repository_bytes", side_effect=quick))
                waited = time.monotonic() - started
            self.assertEqual(0, code)
            self.assertTrue(listing.entered.is_set())
            self.assertLess(waited, 6.0)
            status = fixture.document("status.json")
            self.assertEqual("success", status["state"])
            self.assertIsNone(status["repository_bytes_after"])
            self.assertIsNone(fixture.document("last-success.json")["repository_bytes_after"])

    def test_a_measurement_that_breaks_never_fails_a_verified_backup(self) -> None:
        with tempfile.TemporaryDirectory(prefix="repository-size-run-") as root_text:
            fixture = RunFixture(Path(root_text))
            self.assertEqual(
                0,
                fixture.run(
                    mock.patch.object(
                        backup, "measure_repository_bytes", side_effect=RuntimeError("unexpected")
                    )
                ),
            )
            status = fixture.document("status.json")
            self.assertEqual("success", status["state"])
            self.assertTrue(status["verification_complete"])
            last_success = fixture.document("last-success.json")
            self.assertEqual("success", last_success["state"])
            self.assertIsNone(last_success["repository_bytes_after"])


if __name__ == "__main__":
    unittest.main()
