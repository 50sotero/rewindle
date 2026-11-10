"""The first backup of a new generation compares its files with the latest verified backup.

A backup finds the one before it only within its own configuration generation
(--group-by host,paths,tags, and every snapshot carries its generation's tag).
A reinstall or an update that changes the backup's scope, and a move of the
backup location, start a new generation, so its first backup found no earlier
one and read every file again: on one PC, 114 GiB in about two hours, to add
0.02 GiB. backup.py now names the latest verified backup (last-success.json) as
Restic's parent when it is of the same plan, computer, folders, volumes and
repository (earlier_generation_parent). These tests check when it does and
when it doesn't, the backup command, status.json and the run log, that a lower
generation is still refused, and, where the release build's pinned restic.exe
is present, that Restic then reads only what changed, in a throwaway repository.
"""

from __future__ import annotations

import argparse
from contextlib import ExitStack
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
RESTIC = PROJECT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"
INSTALLER = PROJECT / "installer" / "Install-ResticBackuper.ps1"
# Set by CI's step after the release build: there, a missing pinned restic.exe
# fails instead of skipping.
REQUIRE_PINNED_RESTIC = os.environ.get("REWINDLE_REQUIRE_PINNED_RESTIC") == "1"

import backup  # noqa: E402
import restic_common  # noqa: E402


def pinned_restic_present() -> bool:
    if not RESTIC.is_file():
        return False
    release = json.loads((SOURCE / "restic-release.json").read_text(encoding="utf-8"))
    return restic_common.sha256_file(RESTIC) == release["executable_sha256"]


PLAN_ID = "40000000-0000-4000-8000-000000000004"
PLAN_TAG = "restic-backuper-plan:" + PLAN_ID
REPOSITORY_ID = "a" * 64
EARLIER_SNAPSHOT = "1" * 64
NEW_SNAPSHOT = "2" * 64
HOST = "GENERATION-TEST"
SERIAL = "A1B2C3D4"
# Marks a field a test removes from a record.
DELETED = object()


def generation_tag(generation: int) -> str:
    return "restic-backuper-generation:" + str(generation)


def source_record(path: str, serial: str = SERIAL) -> dict[str, object]:
    """One source's preflight record, as status.json and last-success.json keep it."""
    return {
        "configured_path": path,
        "canonical_path": path,
        "readiness": "ready",
        "expected_volume_serial": serial,
        "observed_volume_serial": serial,
        "volume_identity": "match",
        "overall_status": "ready",
    }


def listed_snapshot(
    snapshot_id: str, generation: int, sources: list[str], *, time: str = "2026-11-09T02:00:00Z"
) -> dict[str, object]:
    return {
        "id": snapshot_id,
        "hostname": HOST,
        "tags": ["scheduled", PLAN_TAG, generation_tag(generation)],
        "paths": list(sources),
        "time": time,
    }


class EarlierGenerationParentTests(unittest.TestCase):
    """Which backup, if any, earlier_generation_parent names."""

    def setUp(self) -> None:
        self.sources = ["C:\\Users\\your-user\\Documents", "D:\\Photos", "C:\\ProgramData\\ResticBackuper\\canary"]
        self.config: dict[str, object] = {
            "plan_id": PLAN_ID,
            "config_generation": 2,
            "hostname": HOST,
            "sources": list(self.sources),
        }
        self.records = [source_record(path) for path in self.sources]
        self.prior: dict[str, object] = {
            "state": "success",
            "verification_complete": True,
            "plan_id": PLAN_ID,
            "config_generation": 1,
            "hostname": HOST,
            "repository_id": REPOSITORY_ID,
            "snapshot_id": EARLIER_SNAPSHOT,
            "sources": list(self.sources),
            "source_identities": copy.deepcopy(self.records),
            # The exclusion list of the earlier backup: it may differ, see below.
            "exclude_file_sha256": "0" * 64,
        }
        self.snapshots = [listed_snapshot(EARLIER_SNAPSHOT, 1, self.sources)]

    def parent(self, **changes: object) -> dict[str, object] | None:
        return backup.earlier_generation_parent(
            changes.get("config", self.config),
            changes.get("tag", "scheduled"),
            changes.get("prior", self.prior),
            changes.get("repository_id", REPOSITORY_ID),
            changes.get("records", self.records),
            changes.get("snapshots", self.snapshots),
        )

    def changed_prior(self, **fields: object) -> dict[str, object]:
        prior = copy.deepcopy(self.prior)
        for name, value in fields.items():
            if value is DELETED:
                del prior[name]
            else:
                prior[name] = value
        return prior

    def changed_snapshot(self, **fields: object) -> list[dict[str, object]]:
        snapshot = copy.deepcopy(self.snapshots[0])
        snapshot.update(fields)
        return [snapshot]

    def test_the_latest_verified_backup_of_an_earlier_generation_is_the_parent(self) -> None:
        self.assertIs(self.snapshots[0], self.parent())
        # Unchanged, it is a parent too: success_unchanged kept the earlier snapshot.
        self.assertIs(self.snapshots[0], self.parent(prior=self.changed_prior(state="success_unchanged")))

    def test_any_earlier_generation_of_the_plan_counts(self) -> None:
        config = dict(self.config, config_generation=7)
        self.assertIs(self.snapshots[0], self.parent(config=config))

    def test_another_exclusion_list_still_has_the_parent(self) -> None:
        # An update can ship a new exclusion list: Restic reads every file the parent doesn't
        # hold, and the parent never decides what is backed up.
        self.assertIs(self.snapshots[0], self.parent(prior=self.changed_prior(exclude_file_sha256="f" * 64)))

    def test_names_compare_as_windows_compares_them(self) -> None:
        prior = self.changed_prior(
            hostname=HOST.lower(),
            sources=[path.upper() + "\\" for path in reversed(self.sources)],
            source_identities=[source_record(path.lower(), SERIAL.lower()) for path in self.sources],
        )
        self.assertIs(self.snapshots[0], self.parent(prior=prior))

    def test_the_whole_listing_is_searched_for_that_one_snapshot(self) -> None:
        others = [
            listed_snapshot("3" * 64, 1, self.sources, time="2026-11-10T02:00:00Z"),
            listed_snapshot("4" * 64, 2, self.sources[:1]),
            "not a snapshot",
        ]
        self.assertIs(self.snapshots[0], self.parent(snapshots=[*others, self.snapshots[0]]))

    def test_no_parent_without_a_verified_backup_of_this_plan_and_an_earlier_generation(self) -> None:
        cases = {
            "no verified backup on record": None,
            "a failed run": self.changed_prior(state="failed"),
            "an incomplete run": self.changed_prior(state="partial"),
            "verification not finished": self.changed_prior(verification_complete=False),
            "verification recorded as text": self.changed_prior(verification_complete="true"),
            "another plan": self.changed_prior(plan_id="50000000-0000-4000-8000-000000000005"),
            "this generation": self.changed_prior(config_generation=2),
            "a later generation": self.changed_prior(config_generation=3),
            "generation zero": self.changed_prior(config_generation=0),
            "generation as text": self.changed_prior(config_generation="1"),
            "generation as a boolean": self.changed_prior(config_generation=True),
            "no generation": self.changed_prior(config_generation=DELETED),
            "another computer": self.changed_prior(hostname="OTHER-PC"),
            "no computer": self.changed_prior(hostname=DELETED),
            "another repository": self.changed_prior(repository_id="b" * 64),
            "no repository": self.changed_prior(repository_id=None),
            "no snapshot": self.changed_prior(snapshot_id=None),
            "a short snapshot ID": self.changed_prior(snapshot_id=EARLIER_SNAPSHOT[:8]),
        }
        for label, prior in cases.items():
            with self.subTest(label):
                self.assertIsNone(self.parent(prior=prior))
        with self.subTest("a repository this run could not name"):
            self.assertIsNone(self.parent(repository_id="not-an-id"))

    def test_no_parent_when_the_folders_or_their_drives_differ(self) -> None:
        added = "E:\\Music"
        prior_cases = {
            "one more folder now": self.changed_prior(sources=self.sources[1:]),
            "one folder fewer now": self.changed_prior(sources=[*self.sources, added]),
            "another folder": self.changed_prior(sources=[added, *self.sources[1:]]),
            "folders not a list": self.changed_prior(sources=";".join(self.sources)),
            "a folder that is not text": self.changed_prior(sources=[*self.sources[1:], 7]),
            "another drive under a folder": self.changed_prior(
                source_identities=[source_record(self.sources[0], "0BADC0DE"), *self.records[1:]]
            ),
            "a drive that did not match then": self.changed_prior(
                source_identities=[dict(self.records[0], volume_identity="mismatch"), *self.records[1:]]
            ),
            "a drive without a serial": self.changed_prior(
                source_identities=[dict(self.records[0], observed_volume_serial=None), *self.records[1:]]
            ),
            "a folder without its drive": self.changed_prior(source_identities=self.records[1:]),
            "no drives recorded": self.changed_prior(source_identities=DELETED),
        }
        for label, prior in prior_cases.items():
            with self.subTest(label):
                self.assertIsNone(self.parent(prior=prior))
        record_cases = {
            "this run's drives unknown": None,
            "this run has no drives": [],
            "this run misses a drive": self.records[1:],
            "this run's drive is another": [source_record(self.sources[0], "0BADC0DE"), *self.records[1:]],
            "a record that is not one": ["ready", *self.records[1:]],
        }
        for label, records in record_cases.items():
            with self.subTest(label):
                self.assertIsNone(self.parent(records=records))

    def test_no_parent_unless_its_snapshot_is_listed_as_what_was_verified(self) -> None:
        sources = self.sources
        cases = {
            "the listing is not a list": {"id": EARLIER_SNAPSHOT},
            "it is gone": [],
            "it is listed twice": [self.snapshots[0], copy.deepcopy(self.snapshots[0])],
            "from another computer": self.changed_snapshot(hostname="OTHER-PC"),
            "of other folders": self.changed_snapshot(paths=sources[:2]),
            "without its folders": self.changed_snapshot(paths=None),
            "without the run's tag": self.changed_snapshot(tags=[PLAN_TAG, generation_tag(1)]),
            "of another plan": self.changed_snapshot(
                tags=["scheduled", "restic-backuper-plan:50000000-0000-4000-8000-000000000005", generation_tag(1)]
            ),
            "of another generation than recorded": self.changed_snapshot(tags=["scheduled", PLAN_TAG, generation_tag(2)]),
            "with two generations": self.changed_snapshot(
                tags=["scheduled", PLAN_TAG, generation_tag(1), generation_tag(2)]
            ),
            "without tags": self.changed_snapshot(tags=None),
        }
        for label, snapshots in cases.items():
            with self.subTest(label):
                self.assertIsNone(self.parent(snapshots=snapshots))
        with self.subTest("a run with another tag"):
            self.assertIsNone(self.parent(tag="manual"))



class GenerationRun:
    """backup._run_locked against fake Restic, with a verified backup of generation 1 on record."""

    def __init__(self, root: Path, *, generation: int = 2) -> None:
        self.source = root / "source"
        self.source.mkdir()
        (root / "repository").mkdir()
        self.state = root / "state"
        self.state.mkdir()
        self.excludes = root / "excludes.txt"
        self.excludes.write_text("**/__pycache__\n", encoding="utf-8", newline="\n")
        restic = root / "restic.exe"
        restic.write_bytes(b"fixture")
        canary = self.source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8", newline="\n")
        self.sources = [str(self.source)]
        self.config: dict[str, object] = {
            "plan_id": PLAN_ID,
            "config_generation": generation,
            "scheduled_tag": "scheduled",
            "state_directory": str(self.state),
            "repository": str(root / "repository"),
            "repository_volume_serial": SERIAL,
            "hostname": HOST,
            "sources": list(self.sources),
            "exclude_file": str(self.excludes),
            "restic_executable": str(restic),
            "canary_file": str(canary),
            "use_vss": False,
            "read_concurrency": 2,
            "structural_check_after_backup": False,
            "read_data_subset_parts": 0,
            "source_identities": {str(self.source): {"expected_volume_serial": SERIAL}},
            "cloud_placeholder_policy": "strict",
        }
        self.listed = [listed_snapshot(EARLIER_SNAPSHOT, 1, self.sources)]
        self.backup_commands: list[list[str]] = []

    def record_verified_backup(self, **changes: object) -> None:
        """last-success.json and status.json as generation 1's last verified backup left them."""
        record: dict[str, object] = {
            "schema_version": 1,
            "state": "success",
            "verification_complete": True,
            "plan_id": PLAN_ID,
            "config_generation": 1,
            "hostname": HOST,
            "tag": "scheduled",
            "repository_id": REPOSITORY_ID,
            "snapshot_id": EARLIER_SNAPSHOT,
            "sources": list(self.sources),
            "source_identities": [source_record(path) for path in self.sources],
        }
        record.update(changes)
        for name in ("last-success.json", "status.json"):
            restic_common.atomic_write_json(self.state / name, record)

    def document(self, name: str) -> dict[str, object]:
        return json.loads((self.state / name).read_text(encoding="utf-8"))

    def log_events(self) -> list[dict[str, object]]:
        (log,) = (self.state / "logs").glob("backup-*.jsonl.log")
        return [
            json.loads(line)
            for line in log.read_text(encoding="utf-8").splitlines()
            if line.startswith("{")
        ]

    def run(self, *, real_preflight: bool = False) -> int:
        generation = int(self.config["config_generation"])
        listings = 0

        def fake_capture(command, **_kwargs):
            nonlocal listings
            if command[1] == "cat":
                return subprocess.CompletedProcess(
                    ["restic"], 0, json.dumps({"id": REPOSITORY_ID, "version": 2}), ""
                )
            listings += 1
            payload = list(self.listed)
            if listings > 1:
                payload.append(
                    listed_snapshot(NEW_SNAPSHOT, generation, self.sources, time="2026-11-10T02:00:00Z")
                )
            return subprocess.CompletedProcess(["restic"], 0, json.dumps(payload), "")

        def fake_stream(command, _log, on_line=None, **_kwargs):
            if command[1] != "backup":
                raise AssertionError(f"unexpected fake Restic verb: {command[1]}")
            self.backup_commands.append(list(command))
            on_line(
                json.dumps(
                    {
                        "message_type": "summary",
                        "snapshot_id": NEW_SNAPSHOT,
                        "total_files_processed": 1,
                        "total_bytes_processed": 7,
                        "files_new": 0,
                        "files_changed": 0,
                        "files_unmodified": 1,
                        "data_added": 0,
                    }
                )
            )
            return 0

        ready = {
            "schema_version": 1,
            "policy": "strict",
            "status": "ready",
            "sources": [source_record(path) for path in self.sources],
            "failures": [],
        }
        with ExitStack() as patches:
            for name, value in (
                ("validate_repository_volume", None),
                ("ensure_free_space", 1),
                # The real preflight reads the folders and their drives as a backup does.
                ("preflight_sources", None if real_preflight else ready),
                ("restic_base", ["restic"]),
                ("verify_canary", {"verified": True}),
                ("process_start_filetime", "133733333333333333"),
            ):
                if name == "preflight_sources" and real_preflight:
                    continue
                patches.enter_context(mock.patch.object(backup, name, return_value=value))
            patches.enter_context(mock.patch.object(backup, "run_capture", side_effect=fake_capture))
            patches.enter_context(mock.patch.object(backup, "stream_command", side_effect=fake_stream))
            return backup._run_locked(
                argparse.Namespace(tag=None, scheduled=True), self.config
            )

    def command_without_parent(self, generation: int) -> list[str]:
        """The command every backup ran before: Restic looks for a parent in this generation only."""
        return [
            "restic",
            "backup",
            *self.sources,
            "--iexclude-file",
            str(self.excludes),
            "--exclude-caches",
            "--skip-if-unchanged",
            "--no-scan",
            "--read-concurrency",
            "2",
            "--group-by",
            "host,paths,tags",
            "--host",
            HOST,
            "--tag",
            "scheduled",
            "--tag",
            PLAN_TAG,
            "--tag",
            generation_tag(generation),
        ]


class FirstBackupOfNewGenerationTests(unittest.TestCase):
    def test_it_names_the_latest_verified_backup_as_its_parent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="generation-parent-") as root_text:
            run = GenerationRun(Path(root_text))
            run.record_verified_backup()

            self.assertEqual(0, run.run())

            expected = run.command_without_parent(2)
            skip = expected.index("--skip-if-unchanged")
            # The earlier backup replaces the one --group-by would look for, and the run makes a
            # snapshot of generation 2 even if nothing changed.
            expected[skip : skip + 1] = ["--parent", EARLIER_SNAPSHOT]
            self.assertEqual([expected], run.backup_commands)

            status = run.document("status.json")
            self.assertEqual("success", status["state"])
            self.assertEqual(NEW_SNAPSHOT, status["snapshot_id"])
            self.assertTrue(status["snapshot_created"])
            self.assertEqual(
                {"snapshot_id": EARLIER_SNAPSHOT, "config_generation": 1},
                status["earlier_generation_parent"],
            )
            success = run.document("last-success.json")
            self.assertEqual((2, NEW_SNAPSHOT), (success["config_generation"], success["snapshot_id"]))
            (event,) = [
                event
                for event in run.log_events()
                if event.get("wrapper_event") == "parent_from_earlier_generation"
            ]
            self.assertEqual(
                (EARLIER_SNAPSHOT, 1), (event["snapshot_id"], event["config_generation"])
            )
            self.assertEqual(2, run.document("plan-state.json")["config_generation"])

    def test_a_generation_with_a_backup_of_its_own_finds_that_one(self) -> None:
        with tempfile.TemporaryDirectory(prefix="generation-parent-own-") as root_text:
            run = GenerationRun(Path(root_text))
            run.record_verified_backup()
            run.listed.append(listed_snapshot("5" * 64, 2, run.sources, time="2026-11-09T12:00:00Z"))

            self.assertEqual(0, run.run())

            self.assertEqual([run.command_without_parent(2)], run.backup_commands)
            self.assertIsNone(run.document("status.json")["earlier_generation_parent"])
            self.assertFalse(
                any(
                    event.get("wrapper_event") == "parent_from_earlier_generation"
                    for event in run.log_events()
                )
            )

    def test_without_a_matching_verified_backup_it_reads_everything_as_before(self) -> None:
        cases = {
            "none on record": None,
            "of other folders": {"sources": ["C:\\Elsewhere"]},
            "in another repository": {"repository_id": "b" * 64},
            "not verified": {"verification_complete": False},
        }
        for label, changes in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory(prefix="generation-parent-none-") as root_text:
                run = GenerationRun(Path(root_text))
                if changes is not None:
                    run.record_verified_backup(**changes)

                self.assertEqual(0, run.run())

                self.assertEqual([run.command_without_parent(2)], run.backup_commands)
                self.assertIsNone(run.document("status.json")["earlier_generation_parent"])

    def test_a_lower_generation_is_still_refused(self) -> None:
        # validate_and_record_plan_state is unchanged: a configuration older than the backups
        # on record never runs, so it never looks for a parent either.
        with tempfile.TemporaryDirectory(prefix="generation-parent-lower-") as root_text:
            run = GenerationRun(Path(root_text), generation=1)
            run.record_verified_backup(config_generation=2)

            with self.assertRaisesRegex(RuntimeError, "config_generation rollback detected"):
                run.run()

            self.assertEqual([], run.backup_commands)
            self.assertEqual(2, run.document("status.json")["config_generation"])


def installer_reads() -> tuple[set[str], set[str]]:
    """The fields of last-success.json, and of each of its source records, that Get-ContinuedConfigGeneration reads."""
    text = INSTALLER.read_text(encoding="utf-8")
    body = text.split("\nfunction Get-ContinuedConfigGeneration {\n", 1)[1].split("\n}\n", 1)[0]
    required = re.search(r"foreach \(\$name in @\((.*?)\)\) \{", body, re.S)
    if required is None:
        raise AssertionError("Get-ContinuedConfigGeneration no longer lists the fields it requires")
    top = set(re.findall(r"'([a-z0-9_]+)'", required.group(1)))
    top |= set(re.findall(r"\$evidence\.([a-z0-9_]+)", body))
    per_source = set(re.findall(r"\$fields\['([a-z0-9_]+)'\]", body))
    per_source |= set(re.findall(r"\$record\.([a-z0-9_]+)", body))
    return top, per_source


class InstallerReadsWhatTheBackupWritesTests(unittest.TestCase):
    """A reinstall keeps the generation only from what last-success.json says (Get-ContinuedConfigGeneration in the
    installer). If backup.py stopped writing a field it reads, or wrote it under another name or in another form, every
    reinstall would quietly start a new generation again, so this reads a record that a backup run itself wrote."""

    def test_a_verified_backup_records_every_field_the_installer_compares(self) -> None:
        top, per_source = installer_reads()
        self.assertTrue({"exclude_file_sha256", "sources", "source_identities", "hostname"} <= top)
        self.assertEqual({"configured_path", "volume_identity", "observed_volume_serial"}, per_source)
        with tempfile.TemporaryDirectory(prefix="generation-parent-installer-") as root_text:
            run = GenerationRun(Path(root_text), generation=1)
            # The drive the folder is really on, as the installer records it for each folder.
            serial = restic_common.volume_serial(run.source)
            run.config["source_identities"] = {str(run.source): {"expected_volume_serial": serial}}
            run.config["repository_storage_mode"] = "local_ntfs"

            self.assertEqual(0, run.run(real_preflight=True))

            record = run.document("last-success.json")
            exclusions = hashlib.sha256(run.excludes.read_bytes()).hexdigest()
        self.assertEqual(set(), top - set(record), "fields the installer reads that the backup doesn't write")
        # In the form the installer requires to keep the generation.
        self.assertEqual("success", record["state"])
        self.assertIs(True, record["verification_complete"])
        self.assertEqual(1, record["config_generation"])
        self.assertRegex(record["snapshot_id"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            (HOST, run.config["repository"], "local_ntfs", SERIAL, exclusions, run.sources),
            (
                record["hostname"],
                record["repository"],
                record["repository_storage_mode"],
                record["repository_volume_serial"],
                record["exclude_file_sha256"],
                record["sources"],
            ),
        )
        (source,) = record["source_identities"]
        self.assertEqual(set(), per_source - set(source), "source fields the installer reads that the backup doesn't write")
        self.assertEqual(
            (str(run.source), "match", serial),
            (source["configured_path"], source["volume_identity"], source["observed_volume_serial"]),
        )


@unittest.skipUnless(
    os.name == "nt" and (pinned_restic_present() or REQUIRE_PINNED_RESTIC),
    "needs the release build's pinned restic.exe (run build\\Build-Release.ps1)",
)
class PinnedResticGenerationParentTests(unittest.TestCase):
    """What the pinned Restic reads in the first backup of a new generation, in a throwaway repository."""

    FILES = 120
    FILE_BYTES = 64 * 1024

    @classmethod
    def setUpClass(cls) -> None:
        if not pinned_restic_present():
            raise AssertionError(
                f"REWINDLE_REQUIRE_PINNED_RESTIC is set, but {RESTIC} is missing "
                "or is not the pinned release"
            )

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="generation-parent-restic-")
        self.addCleanup(temporary.cleanup)
        # The long form of the folder: CI's TEMP is an 8.3 short path, and Restic records
        # the path it is given.
        self.root = Path(temporary.name).resolve()
        self.source = self.root / "source"
        (self.source / "folder").mkdir(parents=True)
        for index in range(self.FILES):
            (self.source / "folder" / f"file-{index:03}.bin").write_bytes(os.urandom(self.FILE_BYTES))
        canary = self.source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8", newline="\n")
        self.state = self.root / "state"
        self.state.mkdir()
        self.password = self.root / "password.txt"
        self.password.write_text("generation-parent-test-only\n", encoding="utf-8")
        repository = self.root / "repository"
        # Only what Restic needs: no inherited RESTIC_* setting can point it at any other backup.
        self.environment = {
            name: os.environ[name] for name in ("SYSTEMROOT", "TEMP", "TMP") if name in os.environ
        }
        initialized = self.restic("init")
        self.assertEqual(0, initialized.returncode, initialized.stderr)
        self.config: dict[str, object] = {
            "plan_id": PLAN_ID,
            "config_generation": 1,
            "scheduled_tag": "scheduled",
            "state_directory": str(self.state),
            "repository": str(repository),
            "repository_volume_serial": SERIAL,
            "hostname": HOST,
            "sources": [str(self.source)],
            "exclude_file": str(SOURCE / "excludes.txt"),
            "restic_executable": str(RESTIC),
            "canary_file": str(canary),
            "use_vss": False,
            "read_concurrency": 2,
            "structural_check_after_backup": False,
            "read_data_subset_parts": 0,
            "source_identities": {str(self.source): {"expected_volume_serial": SERIAL}},
            "cloud_placeholder_policy": "strict",
        }

    def base(self, *, json_output: bool = False) -> list[str]:
        command = [
            str(RESTIC),
            "--repo",
            str(self.root / "repository"),
            "--password-file",
            str(self.password),
            "--cache-dir",
            str(self.state / "cache"),
        ]
        return [*command, "--json"] if json_output else command

    def restic(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*self.base(), *arguments],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=300,
            env=self.environment,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def backup_run(self, generation: int) -> dict[str, object]:
        """One backup._run_locked run with the real Restic; returns status.json."""
        self.config["config_generation"] = generation
        ready = {
            "schema_version": 1,
            "policy": "strict",
            "status": "ready",
            "sources": [source_record(str(self.source))],
            "failures": [],
        }
        with (
            mock.patch.object(backup, "validate_repository_volume"),
            mock.patch.object(backup, "ensure_free_space", return_value=1),
            mock.patch.object(backup, "preflight_sources", return_value=ready),
            mock.patch.object(
                backup,
                "restic_base",
                side_effect=lambda _config, json_output=False: self.base(json_output=json_output),
            ),
            mock.patch.object(backup, "verify_canary", return_value={"verified": True}),
        ):
            result = backup._run_locked(argparse.Namespace(tag=None, scheduled=True), self.config)
        status = json.loads((self.state / "status.json").read_text(encoding="utf-8"))
        self.assertEqual(0, result, status.get("failure"))
        return status

    def summary_counts(self, status: dict[str, object]) -> tuple[int, int, int]:
        summary = status["summary"]
        return summary["files_new"], summary["files_changed"], summary["files_unmodified"]

    def test_a_new_generation_reads_only_what_changed(self) -> None:
        everything = self.FILES + 1
        first = self.backup_run(1)
        self.assertEqual("success", first["state"])
        self.assertEqual((everything, 0, 0), self.summary_counts(first))

        # What the first backup of generation 2 did before: Restic, looking for a parent in
        # generation 2 only, found none and read every file again.
        before = self.restic(
            "--json",
            "backup",
            str(self.source),
            "--dry-run",
            "--iexclude-file",
            str(SOURCE / "excludes.txt"),
            "--exclude-caches",
            "--group-by",
            "host,paths,tags",
            "--host",
            HOST,
            "--tag",
            "scheduled",
            "--tag",
            PLAN_TAG,
            "--tag",
            generation_tag(2),
        )
        self.assertEqual(0, before.returncode, before.stderr)
        (summary,) = [
            message
            for message in map(backup.parse_json_lines, before.stdout.splitlines())
            if message is not None and message.get("message_type") == "summary"
        ]
        self.assertEqual(
            (everything, 0), (summary["files_new"], summary["files_unmodified"])
        )

        # Now it compares each file with generation 1's verified backup, and reads none.
        second = self.backup_run(2)
        self.assertEqual("success", second["state"])
        self.assertTrue(second["snapshot_created"])
        self.assertEqual((0, 0, everything), self.summary_counts(second))
        self.assertEqual(
            {"snapshot_id": first["snapshot_id"], "config_generation": 1},
            second["earlier_generation_parent"],
        )
        self.assertIn("--parent", second["command"])
        self.assertNotIn("--skip-if-unchanged", second["command"])
        self.assertIn(generation_tag(2), second["snapshot"]["tags"])

        # From then on generation 2 finds its own backups.
        (self.source / "folder" / "file-000.bin").write_bytes(os.urandom(self.FILE_BYTES))
        (self.source / "folder" / "added.bin").write_bytes(os.urandom(self.FILE_BYTES))
        third = self.backup_run(2)
        self.assertEqual((1, 1, everything - 1), self.summary_counts(third))
        self.assertIsNone(third["earlier_generation_parent"])
        self.assertIn("--skip-if-unchanged", third["command"])
        self.assertNotIn("--parent", third["command"])


if __name__ == "__main__":
    unittest.main()
