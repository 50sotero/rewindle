"""Clean-up of old backups (src/retention.py): off by default, read-only previews, and removal of exactly a confirmed list."""

from __future__ import annotations

from contextlib import redirect_stdout
from datetime import datetime, timezone
import hashlib
import io
import json
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

import retention  # noqa: E402


PLAN = "12345678-1234-4abc-8def-1234567890ab"
OTHER_PLAN = "87654321-4321-4cba-8fed-ba0987654321"
REPO = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
NOW = datetime(2026, 9, 30, 12, 0, tzinfo=timezone.utc)
SOURCE_PATH = r"C:\Users\you\Documents"


def snapshot_id(index: int) -> str:
    return f"{index:064x}"


def snapshot(index: int, when: str, *, host: str = "FIXTURE", plan: str = PLAN, files: int = 100) -> dict:
    sid = snapshot_id(index)
    return {
        "id": sid,
        "short_id": sid[:8],
        "time": when,
        "hostname": host,
        "tags": ["scheduled", f"restic-backuper-plan:{plan}", "restic-backuper-generation:7"],
        "paths": [SOURCE_PATH],
        "summary": {"total_files_processed": files},
    }


class FakeRestic:
    """Answers the Restic calls the helper makes; real removal happens only through `stream`."""

    def __init__(self) -> None:
        self.store: list[dict] = []
        self.keep: dict[str, list[str]] = {}
        self.calls: list[list[str]] = []
        self.streamed: list[list[str]] = []
        self.fail_batch: int | None = None
        self.batches = 0
        self.prune_code = 0
        self.check_code = 0
        self.repository_id = REPO
        self.dry_run_code = 0
        self.lose_on_forget: str | None = None

    def groups(self) -> list[dict]:
        keep = [item for item in self.store if item["id"] in self.keep]
        remove = [item for item in self.store if item["id"] not in self.keep]
        keep.sort(key=lambda item: item["time"], reverse=True)
        remove.sort(key=lambda item: item["time"], reverse=True)
        return [{
            "tags": None, "host": "FIXTURE", "paths": [SOURCE_PATH],
            "keep": keep, "remove": remove or None,
            "reasons": [{"snapshot": item, "matches": self.keep[item["id"]], "counters": {}} for item in keep],
        }]

    def run(self, command: list[str], **_kwargs) -> subprocess.CompletedProcess:
        self.calls.append(list(command))
        if "cat" in command:
            return subprocess.CompletedProcess(command, 0, json.dumps({"id": self.repository_id, "version": 2}), "")
        if "forget" in command:
            if "--dry-run" not in command:
                raise AssertionError("a removal went through the read-only runner")
            if self.dry_run_code:
                return subprocess.CompletedProcess(command, self.dry_run_code, "", "boom")
            return subprocess.CompletedProcess(command, 0, json.dumps(self.groups()) + "\n", "")
        if "snapshots" in command:
            return subprocess.CompletedProcess(command, 0, json.dumps(self.store), "")
        raise AssertionError(f"unexpected read-only call: {command}")

    def stream(self, command: list[str], log_handle, *_args, **_kwargs) -> int:
        self.streamed.append(list(command))
        if "forget" in command:
            self.batches += 1
            if self.fail_batch == self.batches:
                return 1
            ids = command[command.index("forget") + 1:]
            self.store = [item for item in self.store if item["id"] not in ids]
            if self.lose_on_forget:
                self.store = [item for item in self.store if item["id"] != self.lose_on_forget]
            return 0
        if "prune" in command:
            return self.prune_code
        if "check" in command:
            return self.check_code
        raise AssertionError(f"unexpected streamed call: {command}")


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


class Harness:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.state = root / "state"
        self.install = root / "install"
        self.repository = root / "repository"
        for folder in (self.state, self.install, self.repository, self.state / "logs"):
            folder.mkdir(parents=True, exist_ok=True)
        self.config = {
            "plan_id": PLAN,
            "config_generation": 7,
            "hostname": "FIXTURE",
            "state_directory": str(self.state),
            "repository": str(self.repository),
            "repository_storage_mode": "local_ntfs",
            "restic_executable": str(self.install / "restic.exe"),
            "python_executable": str(self.install / "Python" / "python.exe"),
            "secret_file": str(self.state / "secret.json"),
            "minimum_free_gib": 10,
        }
        self.write_manifest()
        self.fake = FakeRestic()
        self.free = 500 * 1024**3
        self.acl_failures: set[str] = set()
        self.ctx = retention.Context(
            config=self.config,
            install_root=self.install,
            runner=self.fake.run,
            stream=self.fake.stream,
            acl_check=self.acl_check,
            now=lambda: NOW,
            free_bytes=lambda _path: self.free,
            validate_volume=lambda _config: None,
            validate_readiness=lambda _config, **_kwargs: {"status": "ready"},
            log_path=self.state / "logs" / "retention-test.jsonl.log",
        )
        self.log_counter = 0

    def acl_check(self, path: Path) -> None:
        if path.name in self.acl_failures:
            raise retention.RetentionError("records_unprotected", f"{path.name} is writable by the user")

    def write_manifest(self, version: str = "0.3.0", restic_hash: str = "1" * 64) -> None:
        write_json(self.install / "runtime-manifest.json", {
            "schema_version": 1, "version": version, "created_utc": "2026-09-01T00:00:00Z",
            "files": [
                {"relative_path": "backup-config.json", "bytes": 1, "sha256": "2" * 64},
                {"relative_path": "restic.exe", "bytes": 1, "sha256": restic_hash},
                {"relative_path": "retention.py", "bytes": 1, "sha256": "3" * 64},
            ],
        })

    def verified(self, index: int, when: str, *, status: str = "clear", hold: bool = False,
                 latest: bool = True, plan: str = PLAN) -> None:
        """A verified backup run: its log, and (when it is the latest) last-success.json and status.json."""
        self.log_counter += 1
        run_id = f"20260901T{self.log_counter:06d}-{self.log_counter:08x}"
        events = [{"wrapper_event": "backup_started", "run_id": run_id}]
        if hold:
            events.append({"wrapper_event": "change_anomaly_hold", "run_id": run_id, "reasons": ["deletion_ratio"]})
        verified_event = {
            "wrapper_event": "backup_verified", "run_id": run_id, "snapshot_id": snapshot_id(index), "utc": when,
            "plan_id": plan, "config_generation": 7, "repository_id": REPO,
        }
        if status is not None:
            verified_event["change_anomaly_status"] = "hold" if hold else status
        events.append(verified_event)
        log = self.state / "logs" / f"backup-{run_id}.jsonl.log"
        with log.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write("x" * 100 + "\n")
            for event in events:
                handle.write(json.dumps(event) + "\n")
        if latest:
            evidence = {
                "schema_version": 1, "run_id": run_id, "state": "success", "verification_complete": True,
                "snapshot_id": snapshot_id(index), "repository_id": REPO, "plan_id": PLAN, "config_generation": 7,
                "finished_utc": when, "maintenance_hold": hold,
            }
            write_json(self.state / "last-success.json", evidence)
            write_json(self.state / "status.json", evidence)

    def policy(self, counts=(7, 4, 6), **overrides) -> None:
        install_id = retention.install_identity(self.install)
        document = {
            "schema": retention.POLICY_SCHEMA, "schema_version": 1, "enabled": True,
            "keep_daily": counts[0], "keep_weekly": counts[1], "keep_monthly": counts[2], "group_by": "host,paths",
            "plan_id": PLAN, "repository_id": REPO, "install_id": install_id,
            "policy_sha256": retention.policy_digest(PLAN, REPO, install_id, *counts), "changed_utc": "2026-09-01T00:00:00Z",
        }
        document.update(overrides)
        write_json(self.state / retention.POLICY_NAME, document)

    def confirmed_cleanup(self) -> None:
        """A clean-up where the person ticked that their files looked right, with the backup runs logged so far."""
        retention.record_confirmation(self.ctx, REPO, "c" * 64)

    def preview_sha(self) -> str:
        return hashlib.sha256((self.state / retention.PREVIEW_NAME).read_bytes()).hexdigest()

    def preview(self) -> dict:
        return json.loads((self.state / retention.PREVIEW_NAME).read_text(encoding="utf-8"))

    def apply(self, *, confirm: bool = True, preview_sha: str | None = None, remove_sha: str | None = None,
              count: int | None = None) -> dict:
        document = self.preview()
        return retention.apply_forget(
            self.ctx,
            expected_preview_sha256=preview_sha or self.preview_sha(),
            expected_remove_set_sha256=remove_sha or document["remove_set_sha256"],
            expected_remove_count=document["remove_count"] if count is None else count,
            confirm_earlier_changes=confirm,
        )


def standard_history(h: Harness) -> None:
    """Five daily backups, all checked; Restic keeps the last three."""
    for index, day in enumerate(("2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29"), start=1):
        when = f"{day}T02:00:00+02:00"
        h.fake.store.append(snapshot(index, when))
        h.verified(index, f"{day}T00:30:00Z", latest=index == 5)
    for index in (3, 4, 5):
        h.fake.keep[snapshot_id(index)] = ["daily snapshot"]
    h.fake.keep[snapshot_id(5)] = ["daily snapshot", "weekly snapshot", "monthly snapshot"]


class RetentionTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.h = Harness(Path(self.temporary.name))

    def tearDown(self) -> None:
        self.temporary.cleanup()


class OffByDefaultTests(RetentionTestCase):
    def test_no_policy_means_no_restic_call_and_no_policy_file(self) -> None:
        standard_history(self.h)
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual(document["state"], "blocked")
        self.assertEqual(document["blocked_reason"], "policy_inactive")
        self.assertEqual(self.h.fake.calls, [])
        self.assertFalse((self.h.state / retention.POLICY_NAME).exists())
        self.assertEqual(self.h.fake.streamed, [])

    def test_a_turned_off_policy_means_no_restic_call(self) -> None:
        standard_history(self.h)
        self.h.policy(enabled=False)
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual(document["blocked_reason"], "policy_inactive")
        self.assertEqual(self.h.fake.calls, [])

    def test_a_policy_from_another_install_plan_or_location_is_inactive(self) -> None:
        standard_history(self.h)
        install_id = retention.install_identity(self.h.install)
        self.h.policy()
        policy = json.loads((self.h.state / retention.POLICY_NAME).read_text(encoding="utf-8"))
        self.assertIsNone(retention.policy_problem(policy, self.h.config, REPO, install_id))
        self.assertEqual(retention.policy_problem(policy, self.h.config, "f" * 64, install_id), "repository")
        self.assertEqual(retention.policy_problem(policy, {**self.h.config, "plan_id": OTHER_PLAN}, REPO, install_id), "plan")
        self.h.write_manifest(version="0.3.1")
        self.assertEqual(retention.policy_problem(policy, self.h.config, REPO, retention.install_identity(self.h.install)), "install")
        self.assertEqual(retention.policy_problem({**policy, "keep_daily": 3}, self.h.config, REPO, install_id), "counts")
        self.assertEqual(retention.policy_problem({**policy, "keep_daily": 8}, self.h.config, REPO, install_id), "digest")
        self.assertEqual(retention.policy_problem({**policy, "enabled": "yes"}, self.h.config, REPO, install_id), "off")

    def test_an_update_turns_it_off_but_a_folder_or_location_change_does_not(self) -> None:
        before = retention.install_identity(self.h.install)
        manifest = json.loads((self.h.install / "runtime-manifest.json").read_text(encoding="utf-8"))
        manifest["files"][0]["sha256"] = "9" * 64
        manifest["created_utc"] = "2026-09-20T00:00:00Z"
        manifest["last_update_reason"] = "Protected repository relocated"
        write_json(self.h.install / "runtime-manifest.json", manifest)
        self.assertEqual(retention.install_identity(self.h.install), before)
        self.h.write_manifest(restic_hash="4" * 64)
        self.assertNotEqual(retention.install_identity(self.h.install), before)

    def test_a_policy_anyone_but_administrators_can_change_does_not_count(self) -> None:
        standard_history(self.h)
        self.h.policy()
        self.h.acl_failures.add(retention.POLICY_NAME)
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual(document["blocked_reason"], "policy_inactive")
        self.assertEqual(self.h.fake.calls, [])

    def test_counts_bounds_and_the_policy_digest_vector(self) -> None:
        self.assertEqual(retention.validate_counts(7, 4, 6), (7, 4, 6))
        self.assertEqual(retention.validate_counts(90, 104, 120), (90, 104, 120))
        for counts in ((6, 4, 6), (91, 4, 6), (7, 3, 6), (7, 105, 6), (7, 4, 5), (7, 4, 121), (True, 4, 6), ("7", 4, 6)):
            with self.subTest(counts=counts), self.assertRaises(ValueError):
                retention.validate_counts(*counts)
        # The same vector is checked by the dashboard (tests/test_dashboard_retention.py) and the manager suite.
        self.assertEqual(
            retention.policy_digest(PLAN, REPO, "a" * 64, 14, 8, 24),
            "84a15a61186356399ad62e0fd1c3c688841a2724a8082ca7ea5879b1da72f7ab",
        )
        self.assertEqual(
            retention.set_digest(retention.REMOVE_SET_DOMAIN, [snapshot_id(2), snapshot_id(1)]),
            hashlib.sha256(("ResticBackuper.RetentionRemoveSet.v1\n" + snapshot_id(1) + "\n" + snapshot_id(2)).encode()).hexdigest(),
        )
        self.assertEqual(
            retention.set_digest(retention.REMOVE_SET_DOMAIN, []),
            hashlib.sha256(b"ResticBackuper.RetentionRemoveSet.v1").hexdigest(),
        )

    def test_turning_it_on_writes_the_policy_and_a_preview(self) -> None:
        standard_history(self.h)
        result = retention.configure(self.h.ctx, enabled=True, counts=(7, 4, 6))
        self.assertEqual(result["state"], "configured")
        self.assertEqual(result["preview_state"], "ready")
        self.assertEqual(result["remove_count"], 2)
        policy = json.loads((self.h.state / retention.POLICY_NAME).read_text(encoding="utf-8"))
        self.assertTrue(policy["enabled"])
        self.assertEqual(policy["install_id"], retention.install_identity(self.h.install))
        self.assertEqual(self.h.fake.streamed, [], "turning it on removed something")

    def test_it_is_not_turned_on_in_a_state_folder_others_can_change_but_can_still_be_turned_off(self) -> None:
        standard_history(self.h)
        self.h.acl_failures.add(self.h.state.name)
        with self.assertRaises(retention.RetentionError) as failed:
            retention.configure(self.h.ctx, enabled=True, counts=(7, 4, 6))
        self.assertEqual(failed.exception.code, "records_unprotected")
        self.assertFalse((self.h.state / retention.POLICY_NAME).exists())
        self.assertEqual(retention.configure(self.h.ctx, enabled=False, counts=None)["state"], "disabled")
        self.assertEqual(self.h.fake.streamed, [])

    def test_turning_it_off_keeps_the_counts_removes_nothing_and_works_with_a_pending_journal(self) -> None:
        standard_history(self.h)
        self.h.policy(counts=(30, 10, 36))
        (self.h.state / "source-update.journal.json").write_text("{}", encoding="utf-8")
        args = retention.parse_args([
            "--config", "x", "--expected-config-sha256", "0" * 64, "--request-nonce", "1" * 64,
            "--step", "configure", "--enabled", "0",
        ])
        result = retention.run_step(args, self.h.ctx)
        self.assertEqual(result["state"], "disabled")
        policy = json.loads((self.h.state / retention.POLICY_NAME).read_text(encoding="utf-8"))
        self.assertFalse(policy["enabled"])
        self.assertEqual((policy["keep_daily"], policy["keep_weekly"], policy["keep_monthly"]), (30, 10, 36))
        self.assertEqual(self.h.preview()["state"], "disabled")
        self.assertEqual(self.h.fake.calls + self.h.fake.streamed, [])
        on = retention.parse_args([
            "--config", "x", "--expected-config-sha256", "0" * 64, "--request-nonce", "1" * 64,
            "--step", "configure", "--enabled", "1", "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6",
        ])
        with self.assertRaises(retention.Refusal) as refused:
            retention.run_step(on, self.h.ctx)
        self.assertEqual(refused.exception.code, "pending_change")


class PreviewTests(RetentionTestCase):
    def test_the_listing_is_read_only_and_filtered_to_this_computer_and_plan(self) -> None:
        command = retention.dry_run_command(self.h.config, (14, 8, 24))
        tail = command[command.index("--no-lock"):]
        self.assertEqual(tail, [
            "--no-lock", "forget", "--dry-run", "--host", "FIXTURE", "--tag", f"restic-backuper-plan:{PLAN}",
            "--group-by", "host,paths", "--keep-daily", "14", "--keep-weekly", "8", "--keep-monthly", "24",
        ])
        self.assertNotIn("--prune", command)
        self.assertIn("--json", command)

    def test_every_call_of_a_preview_passes_no_lock_and_nothing_is_removed(self) -> None:
        standard_history(self.h)
        self.h.policy()
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual(document["state"], "ready")
        self.assertTrue(self.h.fake.calls)
        for command in self.h.fake.calls:
            self.assertIn("--no-lock", command)
        self.assertEqual(self.h.fake.streamed, [])
        self.assertEqual([item["id"] for item in document["remove"]], [snapshot_id(1), snapshot_id(2)])
        self.assertEqual([item["id"] for item in document["keep"]], [snapshot_id(5), snapshot_id(4), snapshot_id(3)])
        self.assertEqual(document["keep"][0]["reasons"], ["day", "week", "month"])
        self.assertEqual(document["remove"][0]["files"], 100)
        self.assertNotIn("bytes", document["remove"][0])

    def test_parse_rejects_bad_ids_other_computers_other_plans_duplicates_and_empty_groups(self) -> None:
        good = snapshot(1, "2026-09-01T02:00:00Z")
        cases = {
            "short id": [{"keep": [{**good, "id": "abc"}], "remove": None, "reasons": []}],
            "other computer": [{"keep": [snapshot(1, "2026-09-01T02:00:00Z", host="OTHER")], "remove": None, "reasons": []}],
            "other plan": [{"keep": [snapshot(1, "2026-09-01T02:00:00Z", plan=OTHER_PLAN)], "remove": None, "reasons": []}],
            "untagged": [{"keep": [{**good, "tags": ["scheduled"]}], "remove": None, "reasons": []}],
            "twice": [{"keep": [good], "remove": [good], "reasons": []}],
            "keeps nothing": [{"keep": [], "remove": [good], "reasons": []}],
            "no time": [{"keep": [{**good, "time": "yesterday"}], "remove": None, "reasons": []}],
            "not a list": {"keep": [good]},
        }
        for name, document in cases.items():
            with self.subTest(case=name), self.assertRaises(ValueError):
                retention.parse_forget_groups(json.dumps(document), self.h.config)
        self.assertEqual(retention.parse_forget_groups("", self.h.config).keep, [])

    def test_parse_maps_restics_reasons(self) -> None:
        plan = retention.parse_forget_groups(json.dumps([{
            "keep": [snapshot(1, "2026-09-01T02:00:00.123456789+02:00")], "remove": None,
            "reasons": [{"snapshot": snapshot(1, "x"), "matches": ["oldest daily snapshot", "weekly snapshot", "last snapshot"]}],
        }]), self.h.config)
        self.assertEqual(plan.keep[0].reasons, {"day", "week"})
        self.assertEqual(plan.keep[0].time.utcoffset().total_seconds(), 7200)

    def test_the_listing_limit(self) -> None:
        with mock.patch.object(retention, "MAX_PLAN_BACKUPS", 2):
            document = [{"keep": [snapshot(1, "2026-09-01T02:00:00Z")],
                         "remove": [snapshot(2, "2026-08-01T02:00:00Z"), snapshot(3, "2026-07-01T02:00:00Z")], "reasons": []}]
            with self.assertRaises(ValueError):
                retention.parse_forget_groups(json.dumps(document), self.h.config)

    def test_a_failed_listing_is_an_error_preview_with_a_fixed_code(self) -> None:
        standard_history(self.h)
        self.h.policy()
        self.h.fake.dry_run_code = 1
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual((document["state"], document["error_code"]), ("error", "listing_failed"))
        self.assertEqual(document["remove"], [])


class GateTests(RetentionTestCase):
    def setUp(self) -> None:
        super().setUp()
        standard_history(self.h)
        self.h.policy()

    def blocked(self) -> str | None:
        document, _sha = retention.compute_preview(self.h.ctx)
        return document["blocked_reason"]

    def test_any_pending_journal_blocks_even_one_with_a_new_name(self) -> None:
        (self.h.state / "something-new.journal.json").mkdir()
        self.assertEqual(self.blocked(), "pending_change")
        self.assertEqual(self.h.fake.calls, [])

    def test_a_later_attempt_that_did_not_finish_blocks(self) -> None:
        status = json.loads((self.h.state / "status.json").read_text(encoding="utf-8"))
        status.update({"run_id": "later", "state": "partial"})
        write_json(self.h.state / "status.json", status)
        self.assertEqual(self.blocked(), "last_backup_not_verified")

    def test_no_verified_backup_blocks(self) -> None:
        (self.h.state / "last-success.json").unlink()
        self.assertEqual(self.blocked(), "no_verified_backup")

    def test_evidence_anyone_can_change_is_not_trusted(self) -> None:
        self.h.acl_failures.add("last-success.json")
        self.assertEqual(self.blocked(), "no_verified_backup")

    def test_changed_folders_block(self) -> None:
        self.h.config["config_generation"] = 8
        self.assertEqual(self.blocked(), "folders_changed")

    def test_a_change_review_blocks_whether_or_not_it_was_acknowledged(self) -> None:
        for name in ("last-success.json", "status.json"):
            document = json.loads((self.h.state / name).read_text(encoding="utf-8"))
            document["maintenance_hold"] = True
            write_json(self.h.state / name, document)
        self.assertEqual(self.blocked(), "change_review_open")
        write_json(self.h.state / "anomaly-acknowledgement.json", {"acknowledged": True})
        self.assertEqual(self.blocked(), "change_review_open")

    def test_a_clock_problem_and_a_future_dated_backup_block(self) -> None:
        self.h.ctx.now = lambda: datetime(2026, 9, 1, tzinfo=timezone.utc)
        self.assertEqual(self.blocked(), "clock_problem")
        self.h.ctx.now = lambda: NOW
        self.h.fake.store.append(snapshot(9, "2027-01-01T02:00:00Z"))
        self.h.fake.keep[snapshot_id(9)] = ["daily snapshot"]
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual(document["blocked_reason"], "future_dated_backup")
        self.assertEqual(document["future_dated_utc"], "2027-01-01T02:00:00Z")

    def test_an_unavailable_backup_location_blocks(self) -> None:
        def unplugged(_config):
            raise RuntimeError("the drive is gone")
        self.h.ctx.validate_volume = unplugged
        self.assertEqual(self.blocked(), "backup_location_unavailable")
        self.h.ctx.validate_volume = lambda _config: None
        self.h.fake.repository_id = "f" * 64
        self.assertEqual(self.blocked(), "backup_location_unavailable")

    def test_google_drive_backup_locations_are_not_supported_yet(self) -> None:
        self.h.config["repository_storage_mode"] = "google_drivefs_stream"
        with mock.patch.object(retention, "repository_storage_mode", lambda config: config["repository_storage_mode"]):
            self.assertEqual(self.blocked(), "google_drive_not_supported")
        self.assertEqual(self.h.fake.calls, [])


class SaferThanResticTests(RetentionTestCase):
    def test_a_checked_backup_stays_when_restic_keeps_an_unchecked_one_of_its_day(self) -> None:
        h = self.h
        # 28th: a checked 02:00 backup and a 13:00 Back up now that was made but never checked. 29th: the latest.
        h.fake.store += [snapshot(1, "2026-09-28T02:00:00+02:00"), snapshot(2, "2026-09-28T13:00:00+02:00"),
                         snapshot(3, "2026-09-29T02:00:00+02:00")]
        h.verified(1, "2026-09-28T00:30:00Z", latest=False)
        h.verified(3, "2026-09-29T00:30:00Z")
        h.fake.keep = {snapshot_id(2): ["daily snapshot"], snapshot_id(3): ["daily snapshot"]}
        h.policy()
        document, _sha = retention.compute_preview(h.ctx)
        self.assertEqual(document["remove"], [])
        kept = {item["id"]: item["reasons"] for item in document["keep"]}
        self.assertEqual(kept[snapshot_id(1)], ["checked"])

    def test_the_latest_verified_backup_is_never_on_the_list(self) -> None:
        h = self.h
        standard_history(h)
        h.fake.keep = {snapshot_id(4): ["daily snapshot"]}
        h.policy()
        document, _sha = retention.compute_preview(h.ctx)
        self.assertNotIn(snapshot_id(5), [item["id"] for item in document["remove"]])
        self.assertIn("latest", {item["id"]: item["reasons"] for item in document["keep"]}[snapshot_id(5)])

    def test_the_last_backup_before_an_unreviewed_unusual_change_stays(self) -> None:
        h = self.h
        standard_history(h)
        # Backup 3 changed far more files than usual; nobody has confirmed a clean-up since.
        h.verified(3, "2026-09-27T00:30:00Z", hold=True, latest=False)
        h.fake.keep = {snapshot_id(3): ["daily snapshot"], snapshot_id(4): ["daily snapshot"], snapshot_id(5): ["daily snapshot"]}
        h.policy()
        document, _sha = retention.compute_preview(h.ctx)
        kept = {item["id"]: item["reasons"] for item in document["keep"]}
        self.assertEqual(kept[snapshot_id(2)], ["before_change"])
        self.assertEqual([item["id"] for item in document["remove"]], [snapshot_id(1)])
        self.assertTrue(document["needs_files_confirmed"])
        self.assertIn("hold", [change["kind"] for change in document["earlier_changes"]])


class EarlierChangesTests(RetentionTestCase):
    def test_the_first_clean_up_always_asks_to_check_files(self) -> None:
        standard_history(self.h)
        self.h.policy()
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertTrue(document["first_cleanup"])
        self.assertTrue(document["needs_files_confirmed"])

    def test_a_confirmed_clean_up_clears_the_changes_that_were_there_then(self) -> None:
        h = self.h
        standard_history(h)
        # Backup 3 changed far more files than usual, and backup 4 could not be compared with the one before it.
        h.verified(3, "2026-09-27T00:30:00Z", hold=True, latest=False)
        h.verified(4, "2026-09-28T00:30:00Z", status="not_comparable", latest=False)
        h.policy()
        document, _sha = retention.compute_preview(h.ctx)
        self.assertEqual(sorted(change["kind"] for change in document["earlier_changes"]), ["hold", "not_compared"])
        # Backup 2, the last one before the change nobody has looked at, stays.
        self.assertEqual([item["id"] for item in document["remove"]], [snapshot_id(1)])
        h.confirmed_cleanup()
        document, _sha = retention.compute_preview(h.ctx)
        self.assertEqual(
            (document["earlier_changes"], document["needs_files_confirmed"], document["first_cleanup"]), ([], False, False)
        )
        self.assertEqual([item["id"] for item in document["remove"]], [snapshot_id(1), snapshot_id(2)])

    def test_a_change_after_the_confirmation_counts_even_when_the_clock_was_set_back(self) -> None:
        h = self.h
        standard_history(h)
        h.policy()
        h.confirmed_cleanup()
        # The PC's clock was set back after the confirmed clean-up. The next backup changed far more files than usual and is
        # recorded with a time before every backup the person looked over. Nobody looked at it, so it still counts.
        h.verified(3, "2026-09-20T00:30:00Z", hold=True, latest=False)
        document, _sha = retention.compute_preview(h.ctx)
        self.assertTrue(document["needs_files_confirmed"])
        self.assertEqual(
            [(change["kind"], change["finished_utc"]) for change in document["earlier_changes"]],
            [("hold", "2026-09-20T00:30:00Z")],
        )
        kept = {item["id"]: item["reasons"] for item in document["keep"]}
        self.assertEqual(kept[snapshot_id(2)], ["before_change"])
        self.assertEqual([item["id"] for item in document["remove"]], [snapshot_id(1)])

    def test_only_a_confirmed_removal_records_the_backups_looked_over(self) -> None:
        h = self.h
        standard_history(h)
        h.verified(3, "2026-09-27T00:30:00Z", hold=True, latest=False)
        h.policy()
        record = {
            "outcome": "removed", "request_nonce": "1" * 64, "started_utc": "2026-09-30T10:00:00Z", "confirmed_count": 1,
            "removed_count": 1, "removed_set_sha256": "2" * 64, "prune_completed": True, "check_completed": True,
            "prune_mode": "standard", "free_bytes_before": 1,
        }
        retention.apply_record(h.ctx, **record, files_confirmed=False)
        self.assertFalse((h.state / retention.CONFIRMED_NAME).exists())
        self.assertTrue(h.preview()["needs_files_confirmed"])
        retention.apply_record(h.ctx, **record, files_confirmed=True)
        confirmed = json.loads((h.state / retention.CONFIRMED_NAME).read_text(encoding="utf-8"))
        self.assertEqual((confirmed["schema"], confirmed["plan_id"], confirmed["repository_id"]),
                         (retention.CONFIRMED_SCHEMA, PLAN, REPO))
        self.assertEqual(len(confirmed["runs"]), 1)
        self.assertRegex(confirmed["runs"][0], r"^[0-9]{8}T[0-9]{6}-[0-9a-f]{8}$")
        self.assertEqual((h.preview()["needs_files_confirmed"], h.preview()["earlier_changes"]), (False, []))

    def test_a_confirmation_that_cannot_be_trusted_or_names_another_location_asks_again(self) -> None:
        h = self.h
        standard_history(h)
        h.policy()
        h.confirmed_cleanup()
        path = h.state / retention.CONFIRMED_NAME
        document = json.loads(path.read_text(encoding="utf-8"))
        self.assertFalse(retention.compute_preview(h.ctx)[0]["needs_files_confirmed"])
        write_json(path, {**document, "repository_id": "f" * 64})
        preview, _sha = retention.compute_preview(h.ctx)
        self.assertEqual((preview["first_cleanup"], preview["needs_files_confirmed"], preview["earlier_changes_unknown"]),
                         (True, True, False))
        write_json(path, {**document, "runs": ["yesterday"]})
        preview, _sha = retention.compute_preview(h.ctx)
        self.assertEqual((preview["needs_files_confirmed"], preview["earlier_changes_unknown"]), (True, True))
        write_json(path, document)
        h.acl_failures.add(retention.CONFIRMED_NAME)
        preview, _sha = retention.compute_preview(h.ctx)
        self.assertEqual((preview["needs_files_confirmed"], preview["earlier_changes_unknown"]), (True, True))

    def test_a_hold_stays_recorded_through_blocked_and_error_previews_and_off_then_on(self) -> None:
        h = self.h
        standard_history(h)
        h.confirmed_cleanup()
        h.policy()
        h.verified(4, "2026-09-28T00:30:00Z", hold=True)
        document, _sha = retention.compute_preview(h.ctx)
        self.assertEqual(document["blocked_reason"], "change_review_open")
        h.fake.dry_run_code = 1
        h.verified(5, "2026-09-29T00:30:00Z")
        document, _sha = retention.compute_preview(h.ctx)
        self.assertEqual(document["state"], "error")
        retention.configure(h.ctx, enabled=False, counts=None)
        h.fake.dry_run_code = 0
        retention.configure(h.ctx, enabled=True, counts=(7, 4, 6))
        document = h.preview()
        self.assertEqual(document["state"], "ready")
        self.assertTrue(document["needs_files_confirmed"])
        self.assertEqual([change["kind"] for change in document["earlier_changes"]], ["hold"])

    def test_a_backup_that_could_not_be_compared_needs_a_look(self) -> None:
        standard_history(self.h)
        self.h.confirmed_cleanup()
        self.h.verified(5, "2026-09-29T00:30:00Z", status="not_comparable")
        self.h.policy()
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertTrue(document["needs_files_confirmed"])
        self.assertEqual(document["earlier_changes"][0]["kind"], "not_compared")

    def test_an_older_log_that_does_not_say_counts_as_unknown(self) -> None:
        standard_history(self.h)
        self.h.confirmed_cleanup()
        self.h.verified(5, "2026-09-29T00:30:00Z", status=None)
        self.h.policy()
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertTrue(document["earlier_changes_unknown"])
        self.assertTrue(document["needs_files_confirmed"])

    def test_an_approval_in_the_users_review_history_does_not_clear_a_change(self) -> None:
        standard_history(self.h)
        self.h.confirmed_cleanup()
        self.h.verified(4, "2026-09-28T00:30:00Z", hold=True, latest=False)
        write_json(self.h.state / "anomaly-review-history.json", {"schema_version": 1, "reviews": [
            {"plan_id": PLAN, "snapshot_id": snapshot_id(4), "approved": True}]})
        self.h.policy()
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertTrue(document["needs_files_confirmed"])

    def test_unprotected_logs_are_an_error_not_a_clean_record(self) -> None:
        standard_history(self.h)
        self.h.confirmed_cleanup()
        self.h.policy()
        self.h.acl_failures.add("logs")
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual((document["state"], document["error_code"]), ("error", "records_unprotected"))


class ApplyTests(RetentionTestCase):
    def setUp(self) -> None:
        super().setUp()
        standard_history(self.h)
        self.h.policy()
        retention.compute_preview(self.h.ctx)

    def forgotten(self) -> list[list[str]]:
        return [command for command in self.h.fake.streamed if "forget" in command]

    def test_exactly_the_confirmed_ids_are_removed(self) -> None:
        result = self.h.apply()
        self.assertEqual(result["state"], "removed")
        self.assertEqual(result["removed_count"], 2)
        forgets = self.forgotten()
        self.assertEqual(len(forgets), 1)
        self.assertEqual(forgets[0][forgets[0].index("forget") + 1:], [snapshot_id(1), snapshot_id(2)])
        for command in forgets:
            self.assertFalse(any(word.startswith("--keep") or word in ("--prune", "--dry-run") for word in command))
        self.assertEqual({item["id"] for item in self.h.fake.store}, {snapshot_id(3), snapshot_id(4), snapshot_id(5)})

    def test_large_lists_are_removed_in_batches_of_fifty(self) -> None:
        h = self.h
        for index in range(10, 130):
            h.fake.store.append(snapshot(index, f"2026-0{1 + index % 7}-{1 + index % 27:02d}T0{index % 9}:{index % 60:02d}:00Z"))
        retention.compute_preview(h.ctx)
        self.assertEqual(h.preview()["remove_count"], 122)
        result = h.apply()
        self.assertEqual(result["state"], "removed")
        self.assertEqual([len(command) - command.index("forget") - 1 for command in self.forgotten()], [50, 50, 22])

    def test_a_preview_that_is_not_the_one_seen_removes_nothing(self) -> None:
        with self.assertRaises(retention.Refusal) as refused:
            self.h.apply(preview_sha="e" * 64)
        self.assertEqual(refused.exception.code, "preview_mismatch")
        with self.assertRaises(retention.Refusal):
            self.h.apply(count=1)
        with self.assertRaises(retention.Refusal):
            self.h.apply(remove_sha="d" * 64)
        self.assertEqual(self.forgotten(), [])

    def test_a_new_backup_since_the_preview_removes_nothing(self) -> None:
        sha = self.h.preview_sha()
        self.h.fake.store.append(snapshot(6, "2026-09-30T02:00:00+02:00"))
        self.h.verified(6, "2026-09-30T00:30:00Z")
        with self.assertRaises(retention.Refusal) as refused:
            self.h.apply(preview_sha=sha)
        self.assertEqual(refused.exception.code, "preview_mismatch")
        self.assertEqual(self.forgotten(), [])

    def test_unconfirmed_earlier_changes_remove_nothing(self) -> None:
        with self.assertRaises(retention.Refusal) as refused:
            self.h.apply(confirm=False)
        self.assertEqual(refused.exception.code, "earlier_changes_not_confirmed")
        self.assertEqual(self.forgotten(), [])

    def test_a_different_fresh_listing_shows_the_new_list_and_removes_nothing(self) -> None:
        sha = self.h.preview_sha()
        self.h.fake.keep[snapshot_id(2)] = ["monthly snapshot"]
        result = self.h.apply(preview_sha=sha)
        self.assertEqual(result["state"], "preview_changed")
        self.assertEqual(self.forgotten(), [])
        self.assertEqual(self.h.preview()["remove_count"], 1)
        self.assertNotEqual(self.h.preview_sha(), sha)

    def test_a_journal_that_appears_after_the_managers_check_removes_nothing(self) -> None:
        (self.h.state / "repository-relocation.journal.json").write_text("{}", encoding="utf-8")
        with self.assertRaises(retention.Refusal) as refused:
            self.h.apply()
        self.assertEqual(refused.exception.code, "pending_change")
        self.assertEqual(self.forgotten(), [])

    def test_a_setting_turned_off_since_removes_nothing(self) -> None:
        self.h.policy(enabled=False)
        with self.assertRaises(retention.Refusal) as refused:
            self.h.apply()
        self.assertEqual(refused.exception.code, "policy_inactive")

    def test_a_failed_batch_stops_and_reports_what_is_really_gone(self) -> None:
        h = self.h
        for index in range(10, 70):
            h.fake.store.append(snapshot(index, f"2026-0{1 + index % 7}-{1 + index % 27:02d}T0{index % 9}:00:00Z"))
        retention.compute_preview(h.ctx)
        h.fake.fail_batch = 2
        result = h.apply()
        self.assertEqual(result["state"], "partial")
        self.assertEqual(result["removed_count"], 50)
        self.assertEqual(len(self.forgotten()), 2)

    def test_a_list_that_cannot_be_read_back_is_partial_and_reports_the_finished_batches(self) -> None:
        h = self.h
        original_run = h.fake.run

        def no_relist(command, **kwargs):
            if "snapshots" in command and self.forgotten():
                return subprocess.CompletedProcess(command, 1, "", "the location went away")
            return original_run(command, **kwargs)

        h.ctx.runner = no_relist
        result = h.apply()
        self.assertEqual(result["state"], "partial")
        self.assertTrue(result["removal_unverified"])
        self.assertEqual(result["removed_count"], 2)
        self.assertEqual(
            result["removed_set_sha256"],
            retention.set_digest(retention.REMOVE_SET_DOMAIN, [snapshot_id(1), snapshot_id(2)]),
        )

    def test_an_error_after_the_first_batch_still_lists_again_and_reports_what_is_gone(self) -> None:
        # For example the request's log could not be written any more because the disk filled up: the batch counts as failed,
        # and what earlier batches removed is read back and reported, so it can be recorded.
        h = self.h
        for index in range(10, 70):
            h.fake.store.append(snapshot(index, f"2026-0{1 + index % 7}-{1 + index % 27:02d}T0{index % 9}:00:00Z"))
        retention.compute_preview(h.ctx)
        original_stream = h.fake.stream

        def full_disk(command, log_handle, *args, **kwargs):
            if "forget" in command and h.fake.batches >= 1:
                h.fake.batches += 1
                raise OSError(28, "No space left on device")
            return original_stream(command, log_handle, *args, **kwargs)

        h.ctx.stream = full_disk
        result = h.apply()
        self.assertEqual(result["state"], "partial")
        self.assertFalse(result["removal_unverified"])
        self.assertEqual(result["removed_count"], 50)
        self.assertEqual(h.fake.batches, 2)

    def test_an_error_on_the_first_batch_reports_nothing_removed(self) -> None:
        def broken(command, log_handle, *args, **kwargs):
            raise OSError(28, "No space left on device")

        self.h.ctx.stream = broken
        result = self.h.apply()
        self.assertEqual((result["state"], result["removed_count"]), ("partial", 0))
        self.assertEqual(len(self.h.fake.store), 5)

    def test_a_listing_that_cannot_start_after_removing_is_partial_and_unverified(self) -> None:
        h = self.h
        original_run = h.fake.run

        def cannot_start(command, **kwargs):
            if "snapshots" in command and self.forgotten():
                raise OSError(2, "The system cannot find the file specified")
            return original_run(command, **kwargs)

        h.ctx.runner = cannot_start
        result = h.apply()
        self.assertEqual((result["state"], result["removal_unverified"], result["removed_count"]), ("partial", True, 2))

    def test_a_state_folder_others_can_change_removes_nothing(self) -> None:
        self.h.acl_failures.add(self.h.state.name)
        with self.assertRaises(retention.RetentionError) as failed:
            self.h.apply()
        self.assertEqual(failed.exception.code, "records_unprotected")
        self.assertEqual(self.forgotten(), [])
        document, _sha = retention.compute_preview(self.h.ctx)
        self.assertEqual((document["state"], document["error_code"]), ("error", "records_unprotected"))

    def test_a_kept_backup_that_disappears_stops_everything(self) -> None:
        self.h.fake.lose_on_forget = snapshot_id(4)
        result = self.h.apply()
        self.assertEqual(result["state"], "kept_backup_missing")

    def test_nothing_to_remove_removes_nothing(self) -> None:
        h = self.h
        h.fake.keep.update({snapshot_id(1): ["monthly snapshot"], snapshot_id(2): ["weekly snapshot"]})
        retention.compute_preview(h.ctx)
        result = h.apply()
        self.assertEqual((result["state"], result["removed_count"]), ("nothing_to_remove", 0))
        self.assertEqual(self.forgotten(), [])


class SpaceAndRecordTests(RetentionTestCase):
    def test_prune_frees_space_even_when_the_drive_is_nearly_full(self) -> None:
        h = self.h
        h.free = 2 * 1024**3
        result = retention.apply_prune(h.ctx)
        self.assertEqual((result["prune_completed"], result["prune_mode"]), (True, "unused_only"))
        command = h.fake.streamed[-1]
        self.assertEqual(command[command.index("prune"):], ["prune", "--max-unused", "unlimited"])
        h.free = 500 * 1024**3
        retention.apply_prune(h.ctx)
        command = h.fake.streamed[-1]
        self.assertEqual(command[command.index("prune"):], ["prune", "--max-unused", "5%"])

    def test_a_failed_prune_is_recorded_and_offered_again(self) -> None:
        h = self.h
        standard_history(h)
        h.policy()
        h.fake.prune_code = 1
        self.assertFalse(retention.apply_prune(h.ctx)["prune_completed"])
        retention.apply_record(
            h.ctx, outcome="space_pending", request_nonce="1" * 64, started_utc="2026-09-30T10:00:00Z",
            confirmed_count=2, removed_count=2, removed_set_sha256="2" * 64, prune_completed=False,
            check_completed=False, prune_mode="standard", free_bytes_before=1, files_confirmed=True,
        )
        entries, readable = retention.read_history(h.ctx)
        self.assertTrue(readable)
        self.assertEqual(entries[-1]["outcome"], "space_pending")
        self.assertTrue(retention.prune_pending(entries))
        self.assertTrue(h.preview()["prune_pending"])

    def test_history_keeps_the_newest_fifty(self) -> None:
        h = self.h
        standard_history(h)
        h.policy()
        for number in range(55):
            retention.apply_record(
                h.ctx, outcome="nothing_to_remove", request_nonce=f"{number:064x}", started_utc="2026-09-30T10:00:00Z",
                confirmed_count=0, removed_count=0, removed_set_sha256="2" * 64, prune_completed=False,
                check_completed=False, prune_mode="none", free_bytes_before=None, files_confirmed=False,
            )
        entries, _readable = retention.read_history(h.ctx)
        self.assertEqual(len(entries), 50)
        self.assertEqual(entries[-1]["request_nonce"], f"{54:064x}")


class CommandLineTests(RetentionTestCase):
    def test_the_test_root_is_refused_for_an_administrator_and_outside_the_temporary_folder(self) -> None:
        config = self.h.root / "config.json"
        config.write_text("{}", encoding="utf-8")
        with mock.patch.object(retention, "is_administrator", lambda: True):
            with self.assertRaises(retention.RetentionError):
                retention._validate_test_root(self.h.root, config)
        with mock.patch.object(retention, "is_administrator", lambda: False):
            retention._validate_test_root(self.h.root, config)
            with self.assertRaises(retention.RetentionError):
                retention._validate_test_root(PROJECT, config)

    def test_turning_it_off_does_not_need_the_backup_location(self) -> None:
        seen: list[bool] = []

        def load(_path, *, require_repository=True):
            seen.append(require_repository)
            raise retention.RetentionError("stopped", "stopped after loading")

        config = self.h.root / "config.json"
        config.write_text("{}", encoding="utf-8")
        digest = hashlib.sha256(config.read_bytes()).hexdigest()
        outputs = []
        with mock.patch.object(retention, "load_config", load), mock.patch.object(retention, "is_administrator", lambda: False):
            for enabled in ("0", "1"):
                buffer = io.StringIO()
                with redirect_stdout(buffer):
                    code = retention.main([
                        "--config", str(config), "--expected-config-sha256", digest, "--request-nonce", "a" * 64,
                        "--step", "configure", "--enabled", enabled, "--keep-daily", "14", "--keep-weekly", "8",
                        "--keep-monthly", "24", "--test-root", str(self.h.root),
                    ])
                outputs.append((code, json.loads(buffer.getvalue())["state"]))
        self.assertEqual(seen, [False, True])
        self.assertEqual(outputs, [(1, "failed"), (1, "failed")])

    def test_errors_never_carry_credential_details(self) -> None:
        self.assertNotIn("secret", retention.sanitize("RESTIC_PASSWORD=secret was refused"))
        self.assertEqual(len(retention.sanitize("x" * 5000)), 1000)


class StaticSafetyTests(unittest.TestCase):
    def test_only_the_retention_helper_removes_or_prunes(self) -> None:
        for path in sorted(list(SOURCE.glob("*.py")) + list(SOURCE.glob("*.ps1"))):
            text = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                if path.name == "retention.py":
                    continue
                self.assertNotRegex(text, r'["\']prune["\']')
                for match in re.finditer(r'["\']forget["\']', text):
                    self.fail(f"{path.name} names Restic's forget")
        text = (SOURCE / "retention.py").read_text(encoding="utf-8")
        removal = re.findall(r'\["forget", \*batch\]', text)
        self.assertEqual(len(removal), 1)
        self.assertEqual(len(re.findall(r'"prune", "--max-unused"', text)), 1)

    def test_the_helper_never_gives_its_records_the_users_full_control(self) -> None:
        text = (SOURCE / "retention.py").read_text(encoding="utf-8")
        for name in ("restrict_acl", "_write_protected", "verify_restricted_acl", "_verify_backup_evidence_acl"):
            self.assertNotRegex(text, r"\b" + name + r"\b")
        self.assertNotIn("import anomaly_review", text)
        self.assertNotIn("from anomaly_review", text)

    def test_the_backup_records_whether_each_run_was_compared(self) -> None:
        text = (SOURCE / "backup.py").read_text(encoding="utf-8")
        verified = text[text.index('"wrapper_event": "backup_verified"'):]
        self.assertIn('"change_anomaly_status": status["change_anomaly"]["status"]', verified[:2500])
        self.assertNotIn("retention", text.replace("retention_", ""))


class AdminOnlyAclTests(unittest.TestCase):
    SID = "S-1-5-21-1000-1000-1000-1001"

    def test_the_installed_state_folder_shapes(self) -> None:
        from secret_store import admin_only_writable_problem
        administrators_owned = f"O:BAG:{self.SID}D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;{self.SID})(A;ID;0x1200a9;;;OW)"
        user_owned = administrators_owned.replace("O:BA", f"O:{self.SID}")
        self.assertIsNone(admin_only_writable_problem(administrators_owned, owner_limited_by_owner_rights=True))
        self.assertIsNone(admin_only_writable_problem(user_owned, owner_limited_by_owner_rights=True))
        self.assertIsNotNone(admin_only_writable_problem(user_owned))
        without_owner_rights = user_owned.replace("(A;ID;0x1200a9;;;OW)", "")
        self.assertIsNotNone(admin_only_writable_problem(without_owner_rights, owner_limited_by_owner_rights=True))
        writable = administrators_owned.replace(f"(A;ID;0x1200a9;;;{self.SID})", f"(A;ID;FA;;;{self.SID})")
        self.assertIsNotNone(admin_only_writable_problem(writable, owner_limited_by_owner_rights=True))
        owner_rights_write = user_owned.replace("(A;ID;0x1200a9;;;OW)", "(A;ID;FA;;;OW)")
        self.assertIsNotNone(admin_only_writable_problem(owner_rights_write, owner_limited_by_owner_rights=True))


if __name__ == "__main__":
    unittest.main()
