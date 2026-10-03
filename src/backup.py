"""Run and verify an encrypted incremental Restic snapshot."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import ntpath
import os
from pathlib import Path
import secrets
import shutil
import sys
import time
import traceback
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from restic_common import (
    BackupCancelled,
    CancellationToken,
    DEFAULT_CONFIG,
    RunLockUnavailable,
    SourceUpdateJournalPresent,
    atomic_write_json,
    backup_plan_tags,
    cancellation_checkpoint,
    ensure_free_space,
    load_config_under_lock,
    preflight_sources,
    process_start_filetime,
    read_pinned_restic_version,
    read_recorded_repository_id,
    restic_base,
    run_capture,
    sanitized_command,
    sha256_file,
    snapshot_plan_identity,
    stream_command,
    utc_now,
    validate_and_record_plan_state,
    validate_repository_storage_readiness,
    validate_repository_volume,
    windows_snapshot_path,
)


PROGRESS_PERSIST_INTERVAL_SECONDS = 0.5
BACKUP_APP_NAME = "ResticBackuper"
BACKUP_APP_VERSION = "0.1.0-alpha.8"
MAX_PRIOR_SUCCESS_BYTES = 4 * 1024 * 1024
DEFAULT_CHANGE_ANOMALY_POLICY = {
    "enabled": True,
    "file_change_ratio": 0.35,
    "deletion_ratio": 0.15,
    "data_added_ratio": 0.50,
    "minimum_changed_files": 1000,
}
MAX_AFFECTED_PATHS = 50


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--tag", help="snapshot tag; defaults to scheduled_tag")
    parser.add_argument("--scheduled", action="store_true")
    return parser.parse_args(argv)


def normalized_paths(paths: list[str]) -> list[str]:
    return sorted(ntpath.normcase(ntpath.normpath(path)) for path in paths)


def snapshot_matches(
    config: dict[str, Any], tag: str, snapshot: dict[str, Any]
) -> bool:
    plan_tag, generation_tag = backup_plan_tags(config)
    snapshot_tags = snapshot.get("tags") or []
    parsed_plan_identity = snapshot_plan_identity(snapshot_tags)
    return (
        snapshot.get("hostname", "").casefold() == config["hostname"].casefold()
        and tag in snapshot_tags
        and plan_tag in snapshot_tags
        and generation_tag in snapshot_tags
        and parsed_plan_identity
        == (config["plan_id"], config["config_generation"])
        and normalized_paths(snapshot.get("paths") or [])
        == normalized_paths(config["sources"])
    )


def select_snapshot(
    config: dict[str, Any], tag: str, snapshots: list[dict[str, Any]]
) -> dict[str, Any]:
    matches = [
        snapshot
        for snapshot in snapshots
        if snapshot_matches(config, tag, snapshot)
    ]
    if not matches:
        raise RuntimeError(
            "no snapshot exactly matches the configured host, tag, and source roots"
        )
    return max(matches, key=lambda item: item.get("time", ""))


def parse_json_lines(line: str) -> dict[str, Any] | None:
    try:
        value = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        return None
    return value if isinstance(value, dict) else None


def load_prior_success_for_anomaly(path: Path) -> dict[str, Any] | None:
    """Load bounded prior telemetry; malformed telemetry is never trusted."""
    try:
        if not path.is_file() or path.stat().st_size > MAX_PRIOR_SUCCESS_BYTES:
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _change_anomaly_policy(config: dict[str, Any]) -> dict[str, Any]:
    configured = config.get("change_anomaly")
    policy = dict(DEFAULT_CHANGE_ANOMALY_POLICY)
    if isinstance(configured, dict):
        policy.update(configured)
    return policy


def evaluate_change_anomaly(
    summary: dict[str, Any],
    prior_status: dict[str, Any] | None,
    config: dict[str, Any],
) -> dict[str, Any]:
    """Compare like-for-like verified runs and request a non-destructive hold.

    The hold never fails or removes the newly verified snapshot.  It is durable
    telemetry for exact operator acknowledgement and future destructive
    maintenance gates. It does not pause a live DriveFS upload.
    """
    policy = _change_anomaly_policy(config)
    result: dict[str, Any] = {
        "schema_version": 1,
        "evaluated": False,
        "status": "not_comparable",
        "hold": False,
        "reasons": [],
        "thresholds": {
            "file_change_ratio": policy["file_change_ratio"],
            "deletion_ratio": policy["deletion_ratio"],
            "data_added_ratio": policy["data_added_ratio"],
            "minimum_changed_files": policy["minimum_changed_files"],
        },
    }
    if not policy["enabled"]:
        result["status"] = "disabled"
        return result
    if not isinstance(prior_status, dict):
        result["reason_not_evaluated"] = "no bounded verified prior run"
        return result

    current_exclude_hash = sha256_file(Path(config["exclude_file"]))
    comparable = (
        prior_status.get("verification_complete") is True
        and prior_status.get("state") in {"success", "success_unchanged"}
        and prior_status.get("plan_id") == config["plan_id"]
        and prior_status.get("config_generation") == config["config_generation"]
        and normalized_paths(prior_status.get("sources") or [])
        == normalized_paths(config["sources"])
        and prior_status.get("exclude_file_sha256") == current_exclude_hash
        and prior_status.get("repository_id") == read_recorded_repository_id(config)
    )
    prior_summary = prior_status.get("summary")
    if not comparable or not isinstance(prior_summary, dict):
        result["reason_not_evaluated"] = "backup plan or prior evidence changed"
        return result

    numeric_fields = (
        "total_files_processed",
        "total_bytes_processed",
        "files_new",
        "files_changed",
        "data_added",
    )
    if any(
        isinstance(document.get(field), bool)
        or not isinstance(document.get(field), (int, float))
        or document[field] < 0
        for document in (summary, prior_summary)
        for field in numeric_fields
        if field in ("total_files_processed", "total_bytes_processed")
        or document is summary
    ):
        result["reason_not_evaluated"] = "backup summary counters are invalid"
        return result

    prior_files = int(prior_summary["total_files_processed"])
    prior_bytes = int(prior_summary["total_bytes_processed"])
    if prior_files <= 0 or prior_bytes <= 0:
        result["reason_not_evaluated"] = "prior backup has no comparison baseline"
        return result

    current_files = int(summary["total_files_processed"])
    new_files = int(summary["files_new"])
    changed_files = int(summary["files_changed"])
    data_added = int(summary["data_added"])
    estimated_deleted = max(0, prior_files + new_files - current_files)
    affected_files = new_files + changed_files + estimated_deleted
    measurements = {
        "prior_files": prior_files,
        "current_files": current_files,
        "new_files": new_files,
        "changed_files": changed_files,
        "estimated_deleted_files": estimated_deleted,
        "affected_files": affected_files,
        "prior_logical_bytes": prior_bytes,
        "current_logical_bytes": int(summary["total_bytes_processed"]),
        "repository_bytes_added": data_added,
        "file_change_ratio": (new_files + changed_files) / prior_files,
        "deletion_ratio": estimated_deleted / prior_files,
        "data_added_ratio": data_added / prior_bytes,
    }
    result["measurements"] = measurements
    result["evaluated"] = True

    if affected_files >= int(policy["minimum_changed_files"]):
        if measurements["file_change_ratio"] >= float(policy["file_change_ratio"]):
            result["reasons"].append("file_change_ratio")
        if measurements["deletion_ratio"] >= float(policy["deletion_ratio"]):
            result["reasons"].append("deletion_ratio")
        if measurements["data_added_ratio"] >= float(policy["data_added_ratio"]):
            result["reasons"].append("data_added_ratio")

    result["hold"] = bool(result["reasons"])
    result["status"] = "hold" if result["hold"] else "clear"
    return result


def collect_affected_paths(status: dict[str, Any]) -> list[str]:
    """Return a bounded, deduplicated set of source paths implicated by a run."""
    candidates: list[Any] = []
    for event in status.get("errors") or []:
        if not isinstance(event, dict):
            continue
        for key in ("item", "path", "name"):
            candidates.append(event.get(key))
        nested = event.get("error")
        if isinstance(nested, dict):
            for key in ("item", "path", "name"):
                candidates.append(nested.get(key))
    source_preflight = status.get("source_preflight")
    if isinstance(source_preflight, dict):
        for source in source_preflight.get("sources") or []:
            if (
                not isinstance(source, dict)
                or source.get("overall_status") == "ready"
            ):
                continue
            candidates.append(
                source.get("canonical_path") or source.get("configured_path")
            )

    paths: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if not isinstance(candidate, str):
            continue
        value = candidate.strip()
        if (
            not value
            or len(value) > 1024
            or "\x00" in value
            or "\r" in value
            or "\n" in value
            or not ntpath.isabs(value)
        ):
            continue
        normalized = ntpath.normcase(ntpath.normpath(value))
        if normalized in seen:
            continue
        seen.add(normalized)
        paths.append(value)
        if len(paths) >= MAX_AFFECTED_PATHS:
            break
    return paths


def classify_failure(
    phase_state: str,
    error: BaseException,
    exit_code: int | None,
) -> tuple[str, str]:
    """Publish stable support semantics without depending on exception wording."""
    phase = {
        "starting": "initialization",
        "checking_repository_storage": "repository_storage",
        "preflighting_sources": "source_preflight",
        "authenticating_repository": "repository_authentication",
        "backing_up": "backup",
        "partial": "backup",
        "verifying_snapshot": "snapshot_verification",
        "checking_repository": "repository_structure_check",
        "restoring_canary": "restore_canary",
        "checking_data_subset": "repository_data_check",
    }.get(phase_state, "wrapper")
    message = str(error).casefold()
    if phase_state == "partial" or exit_code == 3:
        code = "source_data_unreadable"
    elif "free space" in message or "free-space" in message:
        code = "repository_low_space"
    elif "volume serial" in message or "volume identity" in message:
        code = "volume_identity_mismatch"
    elif phase == "repository_storage":
        code = "repository_storage_unavailable"
    elif phase == "source_preflight":
        code = "source_preflight_failed"
    elif phase == "repository_authentication":
        code = "repository_authentication_failed"
    elif phase == "backup":
        code = "restic_backup_failed"
    elif phase == "snapshot_verification":
        code = "snapshot_verification_failed"
    elif phase == "repository_structure_check":
        code = "repository_structure_check_failed"
    elif phase == "restore_canary":
        code = "restore_canary_failed"
    elif phase == "repository_data_check":
        code = "repository_data_check_failed"
    elif isinstance(error, KeyboardInterrupt):
        code = "wrapper_interrupted"
    else:
        code = "wrapper_failed"
    return phase, code


def authenticate_repository_id(
    config: dict[str, Any],
    recorded_repository_id: str | None,
    *,
    cancellation: CancellationToken | None = None,
    on_cancellation=None,
) -> str:
    """Authenticate the repository and bind its actual non-secret 64-hex ID."""
    result = run_capture(
        restic_base(config, json_output=True) + ["cat", "config"],
        cancellation=cancellation,
        on_cancellation=on_cancellation,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "could not authenticate repository identity: "
            + (result.stderr.strip() or f"Restic exited {result.returncode}")
        )
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("repository identity response is not valid JSON") from error
    repository_id = document.get("id") if isinstance(document, dict) else None
    if (
        not isinstance(repository_id, str)
        or len(repository_id) != 64
        or any(character not in "0123456789abcdef" for character in repository_id)
    ):
        raise RuntimeError("repository identity response has no canonical 64-hex ID")
    if recorded_repository_id is not None and repository_id != recorded_repository_id:
        raise RuntimeError(
            "authenticated repository ID does not match the recorded repository identity"
        )
    return repository_id


def safe_remove_restore_test(target: Path, base: Path) -> None:
    target_resolved = target.resolve(strict=True)
    base_resolved = base.resolve(strict=True)
    if target_resolved.parent != base_resolved:
        raise RuntimeError(f"unsafe restore-test cleanup target: {target_resolved}")
    shutil.rmtree(target_resolved)


def verify_canary(
    config: dict[str, Any],
    snapshot_id: str,
    run_id: str,
    log_handle,
    *,
    cancellation: CancellationToken | None = None,
    on_cancellation=None,
) -> dict[str, Any]:
    canary = Path(config["canary_file"])
    expected_hash = sha256_file(canary)
    restore_base = Path(config["state_directory"]) / "restore-tests"
    restore_base.mkdir(parents=True, exist_ok=True)
    target = restore_base / run_id
    if target.exists():
        raise FileExistsError(f"restore-test target already exists: {target}")
    target.mkdir()

    snapshot_path = windows_snapshot_path(canary)
    # Restic's snapshotID:subfolder selector accepts directories, not files.
    # Restoring the canary's small project directory avoids recreating the
    # source volume's parent ACL hierarchy in the temporary verification tree.
    snapshot_selector = f"{snapshot_id}:{windows_snapshot_path(canary.parent)}"
    command = restic_base(config) + [
        "restore",
        snapshot_selector,
        "--target",
        str(target),
        "--overwrite",
        "never",
        "--verify",
    ]
    log_handle.write(
        json.dumps(
            {"wrapper_event": "canary_restore", "command": sanitized_command(command)}
        )
        + "\n"
    )
    log_handle.flush()
    return_code = stream_command(
        command,
        log_handle,
        cancellation=cancellation,
        on_cancellation=on_cancellation,
    )
    if return_code != 0:
        raise RuntimeError(f"canary restore failed with exit {return_code}")
    cancellation_checkpoint(cancellation, on_cancellation)

    candidates = list(target.rglob(canary.name))
    if len(candidates) != 1:
        raise RuntimeError(
            f"canary restore produced {len(candidates)} matching files, expected one"
        )
    restored = candidates[0]
    actual_hash = sha256_file(restored)
    if actual_hash != expected_hash or restored.stat().st_size != canary.stat().st_size:
        raise RuntimeError("restored canary content does not match its source")

    result = {
        "snapshot_path": snapshot_path,
        "bytes": restored.stat().st_size,
        "sha256": actual_hash,
        "verified": True,
    }
    safe_remove_restore_test(target, restore_base)
    return result


def _run_locked(
    args: argparse.Namespace,
    config: dict[str, Any],
    cancellation: CancellationToken | None = None,
) -> int:
    tag = args.tag or config["scheduled_tag"]
    plan_tag, generation_tag = backup_plan_tags(config)
    state_directory = Path(config["state_directory"])
    logs_directory = state_directory / "logs"
    logs_directory.mkdir(parents=True, exist_ok=True)
    validate_and_record_plan_state(config, state_directory)
    status_path = state_directory / "status.json"
    last_success_path = state_directory / "last-success.json"
    prior_success_exists = last_success_path.is_file()
    prior_success = load_prior_success_for_anomaly(last_success_path)

    run_id = datetime.now().strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(4)
    log_path = logs_directory / f"backup-{run_id}.jsonl.log"
    cancellation_identity = cancellation.identity if cancellation is not None else None
    status: dict[str, Any] = {
        "schema_version": 1,
        "run_id": run_id,
        "state": "starting",
        "started_utc": utc_now(),
        "finished_utc": None,
        "wrapper_pid": os.getpid(),
        "wrapper_start_filetime": process_start_filetime(),
        "launcher_pid": (
            cancellation_identity.launcher_pid if cancellation_identity else None
        ),
        "launcher_start_filetime": (
            cancellation_identity.launcher_start_filetime
            if cancellation_identity
            else None
        ),
        "cancel_channel_id": (
            cancellation_identity.channel_id if cancellation_identity else None
        ),
        "cancel_channel_fingerprint": (
            cancellation_identity.channel_fingerprint
            if cancellation_identity
            else None
        ),
        "cancel_requested_utc": None,
        "cancel_signal_sent_utc": None,
        "cancel_outcome": None,
        "scheduled": bool(args.scheduled),
        "app_name": BACKUP_APP_NAME,
        "app_version": BACKUP_APP_VERSION,
        "plan_id": config["plan_id"],
        "config_generation": config["config_generation"],
        "repository": config["repository"],
        "repository_storage_mode": config.get(
            "repository_storage_mode", "local_ntfs"
        ),
        "repository_readiness": None,
        "repository_volume_serial": config["repository_volume_serial"],
        "repository_id": read_recorded_repository_id(config),
        "hostname": config["hostname"],
        "tag": tag,
        "snapshot_tags": [tag, plan_tag, generation_tag],
        "plan_tag": plan_tag,
        "generation_tag": generation_tag,
        "sources": config["sources"],
        "source_identities": [],
        "source_preflight": None,
        "exclude_file": config["exclude_file"],
        "exclude_file_sha256": sha256_file(Path(config["exclude_file"])),
        "restic_executable": config["restic_executable"],
        "restic_executable_sha256": sha256_file(Path(config["restic_executable"])),
        "restic_version": read_pinned_restic_version(config),
        "canary_source_sha256": sha256_file(Path(config["canary_file"])),
        "log_file": str(log_path),
        "exit_code": None,
        "snapshot_id": None,
        "restic_reported_snapshot_id": None,
        "snapshot_created": False,
        "verification_complete": False,
        "progress": None,
        "summary": None,
        "change_anomaly": None,
        "maintenance_hold": False,
        "errors": [],
        "affected_paths": [],
        "failure_phase": None,
        "failure_code": None,
        "verification": {},
    }
    try:
        atomic_write_json(status_path, status)
        with log_path.open(
            "a", encoding="utf-8", newline="\n", buffering=1
        ) as log_handle:
            def on_cancellation(stage: str, timestamp: str) -> None:
                if stage == "requested":
                    if status["cancel_requested_utc"] is None:
                        status["phase_at_cancel_request"] = status["state"]
                        status["cancel_requested_utc"] = timestamp
                    status["state"] = "cancelling"
                elif stage == "signal_sent":
                    if status["cancel_signal_sent_utc"] is None:
                        status["cancel_signal_sent_utc"] = timestamp
                elif stage in (
                    "finished_before_cancellation_took_effect",
                    "ctrl_break_signal_failed",
                    "non_130_exit_after_cancellation_signal",
                    "child_exit_won_cancellation_race",
                ):
                    status["cancel_outcome"] = stage
                    status["cancel_resolved_utc"] = timestamp
                    status["state"] = status.get(
                        "phase_at_cancel_request", status["state"]
                    )
                else:
                    raise ValueError(f"unknown cancellation stage: {stage}")
                atomic_write_json(status_path, status)
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": f"cancellation_{stage}",
                            "run_id": run_id,
                            "utc": timestamp,
                        }
                    )
                    + "\n"
                )
                log_handle.flush()

            cancellation_checkpoint(cancellation, on_cancellation)
            status["state"] = "checking_repository_storage"
            atomic_write_json(status_path, status)
            validate_repository_volume(config)
            status["repository_readiness"] = (
                validate_repository_storage_readiness(
                    config,
                    volume_validated=True,
                )
            )
            atomic_write_json(status_path, status)
            status["free_bytes_before"] = ensure_free_space(config)
            cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "preflighting_sources"
            atomic_write_json(status_path, status)
            source_preflight = preflight_sources(config)
            status["source_preflight"] = source_preflight
            status["source_identities"] = source_preflight["sources"]
            status["affected_paths"] = collect_affected_paths(status)
            atomic_write_json(status_path, status)
            if source_preflight["status"] != "ready":
                raise RuntimeError(
                    "source preflight failed: "
                    + "; ".join(source_preflight["failures"])
                )
            cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "authenticating_repository"
            atomic_write_json(status_path, status)
            status["repository_id"] = authenticate_repository_id(
                config,
                status["repository_id"],
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            atomic_write_json(status_path, status)
            cancellation_checkpoint(cancellation, on_cancellation)

            prior_snapshots_result = run_capture(
                restic_base(config, json_output=True) + ["snapshots"],
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            if prior_snapshots_result.returncode != 0:
                raise RuntimeError(
                    "could not query snapshots before backup: "
                    + prior_snapshots_result.stderr.strip()
                )
            prior_snapshots = json.loads(prior_snapshots_result.stdout)
            prior_matching_snapshot_ids = {
                snapshot["id"]
                for snapshot in prior_snapshots
                if snapshot_matches(config, tag, snapshot)
            }
            status["prior_matching_snapshot_count"] = len(
                prior_matching_snapshot_ids
            )
            cancellation_checkpoint(cancellation, on_cancellation)

            canary = Path(config["canary_file"])
            if not any(
                ntpath.commonpath(
                    [
                        ntpath.normcase(ntpath.abspath(str(canary))),
                        ntpath.normcase(ntpath.abspath(source)),
                    ]
                )
                == ntpath.normcase(ntpath.abspath(source))
                for source in config["sources"]
                if ntpath.splitdrive(str(canary))[0].casefold()
                == ntpath.splitdrive(source)[0].casefold()
            ):
                raise RuntimeError("the restore canary is not inside a configured source")

            command = restic_base(config, json_output=True) + [
                "backup",
                *config["sources"],
                "--iexclude-file",
                config["exclude_file"],
                "--exclude-caches",
                "--skip-if-unchanged",
                "--no-scan",
                "--read-concurrency",
                str(int(config.get("read_concurrency", 2))),
                "--group-by",
                "host,paths,tags",
                "--host",
                config["hostname"],
                "--tag",
                tag,
                "--tag",
                plan_tag,
                "--tag",
                generation_tag,
            ]
            if config.get("use_vss"):
                command.append("--use-fs-snapshot")

            status["state"] = "backing_up"
            status["command"] = sanitized_command(command)
            atomic_write_json(status_path, status)
            log_handle.write(
                json.dumps(
                    {
                        "wrapper_event": "backup_started",
                        "run_id": run_id,
                        "utc": utc_now(),
                        "command": sanitized_command(command),
                    }
                )
                + "\n"
            )

            last_progress_persisted = float("-inf")

            def on_backup_line(line: str) -> None:
                nonlocal last_progress_persisted
                event = parse_json_lines(line)
                if event is None:
                    return
                message_type = event.get("message_type")
                if message_type == "status":
                    status["progress"] = event
                    now = time.monotonic()
                    if (
                        now - last_progress_persisted
                        >= PROGRESS_PERSIST_INTERVAL_SECONDS
                    ):
                        atomic_write_json(status_path, status)
                        last_progress_persisted = now
                elif message_type == "summary":
                    status["summary"] = event
                    reported_snapshot_id = event.get("snapshot_id")
                    if isinstance(reported_snapshot_id, str):
                        status["restic_reported_snapshot_id"] = reported_snapshot_id
                elif message_type == "error":
                    if len(status["errors"]) < 100:
                        status["errors"].append(event)
                        status["affected_paths"] = collect_affected_paths(status)

            backup_return_code = stream_command(
                command,
                log_handle,
                on_backup_line,
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            status["backup_exit_code"] = backup_return_code
            if backup_return_code == 3:
                if (
                    status.get("cancel_outcome")
                    == "non_130_exit_after_cancellation_signal"
                    and isinstance(status.get("summary"), dict)
                    and status["summary"].get("snapshot_id")
                ):
                    status["cancel_outcome"] = (
                        "finished_before_cancellation_took_effect"
                    )
                status["state"] = "partial"
                status["exit_code"] = 3
                raise RuntimeError(
                    "Restic created an incomplete snapshot because some source data was unreadable"
                )
            if backup_return_code != 0:
                status["exit_code"] = backup_return_code
                raise RuntimeError(f"Restic backup failed with exit {backup_return_code}")
            cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "verifying_snapshot"
            atomic_write_json(status_path, status)
            snapshots_result = run_capture(
                restic_base(config, json_output=True) + ["snapshots"],
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            log_handle.write(snapshots_result.stderr)
            if snapshots_result.returncode != 0:
                raise RuntimeError(
                    f"could not query snapshots: {snapshots_result.stderr.strip()}"
                )
            snapshots = json.loads(snapshots_result.stdout)
            summary = status.get("summary")
            if not isinstance(summary, dict) or summary.get("message_type") != "summary":
                raise RuntimeError(
                    "Restic exited successfully but emitted no parseable JSON summary"
                )
            summary_snapshot_id = summary.get("snapshot_id")
            if summary_snapshot_id:
                bound = [
                    item
                    for item in snapshots
                    if item.get("id") == summary_snapshot_id
                    and snapshot_matches(config, tag, item)
                ]
                if len(bound) != 1:
                    raise RuntimeError(
                        "backup summary snapshot is missing or does not match host/tag/paths"
                    )
                snapshot = bound[0]
            else:
                if not prior_matching_snapshot_ids:
                    raise RuntimeError(
                        "Restic reported no new snapshot and no matching parent exists"
                    )
                prior_snapshot = select_snapshot(config, tag, prior_snapshots)
                bound = [
                    item
                    for item in snapshots
                    if item.get("id") == prior_snapshot.get("id")
                    and snapshot_matches(config, tag, item)
                ]
                if len(bound) != 1:
                    raise RuntimeError(
                        "unchanged backup parent is no longer present after the run"
                    )
                snapshot = bound[0]
            snapshot_id = snapshot["id"]
            status["snapshot_id"] = snapshot_id
            status["snapshot"] = snapshot
            status["snapshot_created"] = bool(
                summary_snapshot_id
                and snapshot_id not in prior_matching_snapshot_ids
            )
            cancellation_checkpoint(cancellation, on_cancellation)

            if config.get("structural_check_after_backup", True):
                status["state"] = "checking_repository"
                atomic_write_json(status_path, status)
                check_command = restic_base(config) + ["check"]
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "structural_check",
                            "command": sanitized_command(check_command),
                        }
                    )
                    + "\n"
                )
                if stream_command(
                    check_command,
                    log_handle,
                    cancellation=cancellation,
                    on_cancellation=on_cancellation,
                ) != 0:
                    raise RuntimeError("repository structural check failed")
                status["verification"]["repository_structure"] = True
                cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "restoring_canary"
            atomic_write_json(status_path, status)
            status["verification"]["canary"] = verify_canary(
                config,
                snapshot_id,
                run_id,
                log_handle,
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            cancellation_checkpoint(cancellation, on_cancellation)

            weekday = datetime.now().strftime("%A")
            subset_parts = int(config.get("read_data_subset_parts", 0))
            if (
                args.scheduled
                and prior_success_exists
                and subset_parts > 0
                and weekday.casefold()
                == str(config.get("read_data_subset_weekday", "")).casefold()
            ):
                subset = datetime.now().timetuple().tm_yday % subset_parts + 1
                subset_command = restic_base(config) + [
                    "check",
                    f"--read-data-subset={subset}/{subset_parts}",
                ]
                status["state"] = "checking_data_subset"
                status["verification"]["data_subset"] = f"{subset}/{subset_parts}"
                atomic_write_json(status_path, status)
                if stream_command(
                    subset_command,
                    log_handle,
                    cancellation=cancellation,
                    on_cancellation=on_cancellation,
                ) != 0:
                    raise RuntimeError("repository data-subset check failed")
                cancellation_checkpoint(cancellation, on_cancellation)

            cancellation_checkpoint(cancellation, on_cancellation)
            status["change_anomaly"] = evaluate_change_anomaly(
                summary, prior_success, config
            )
            status["maintenance_hold"] = bool(status["change_anomaly"]["hold"])
            if status["maintenance_hold"]:
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "change_anomaly_hold",
                            "run_id": run_id,
                            "utc": utc_now(),
                            "reasons": status["change_anomaly"]["reasons"],
                            "measurements": status["change_anomaly"].get(
                                "measurements"
                            ),
                        }
                    )
                    + "\n"
                )
            status["state"] = (
                "success_unchanged"
                if not summary_snapshot_id
                or snapshot_id in prior_matching_snapshot_ids
                else "success"
            )
            status["exit_code"] = 0
            status["verification_complete"] = True
            status["finished_utc"] = utc_now()
            status["free_bytes_after"] = shutil.disk_usage(
                Path(config["repository"]).anchor
            ).free
            atomic_write_json(status_path, status)
            atomic_write_json(last_success_path, status)
            log_handle.write(
                json.dumps(
                    {
                        "wrapper_event": "backup_verified",
                        "run_id": run_id,
                        "snapshot_id": snapshot_id,
                        "utc": status["finished_utc"],
                        "plan_id": status["plan_id"],
                        "config_generation": status["config_generation"],
                        "repository_id": status["repository_id"],
                        "source_identities": status["source_identities"],
                        "exclude_file_sha256": status["exclude_file_sha256"],
                        "hostname": status["hostname"],
                        "snapshot_tags": status["snapshot_tags"],
                        "app_name": status["app_name"],
                        "app_version": status["app_version"],
                        "restic_version": status["restic_version"],
                    }
                )
                + "\n"
            )
            return 0
    except BackupCancelled as error:
        cancelled_phase = str(
            status.get("phase_at_cancel_request") or status.get("state") or "wrapper"
        )
        status["state"] = "cancelled" if error.cooperative else "cancel_failed"
        status["exit_code"] = (
            130
            if error.cooperative
            else (
                error.process_returncode
                if error.process_returncode not in (None, 0)
                else 1
            )
        )
        status["finished_utc"] = utc_now()
        status["cancel_requested_utc"] = (
            status.get("cancel_requested_utc") or error.requested_utc
        )
        status["cancel_signal_sent_utc"] = (
            status.get("cancel_signal_sent_utc") or error.signal_sent_utc
        )
        status["cancel_outcome"] = error.outcome
        if error.process_returncode is not None:
            status["restic_exit_code"] = error.process_returncode
        if not error.cooperative:
            status["failure"] = str(error)
        status["failure_phase"] = cancelled_phase
        status["failure_code"] = (
            "cooperative_cancellation"
            if error.cooperative
            else "cooperative_cancellation_failed"
        )
        status["affected_paths"] = collect_affected_paths(status)
        status_write_error = None
        try:
            atomic_write_json(status_path, status)
        except Exception as telemetry_error:
            status_write_error = str(telemetry_error)
        try:
            with log_path.open("a", encoding="utf-8", newline="\n") as log_handle:
                cancellation_event = {
                    "wrapper_event": (
                        "cancelled" if error.cooperative else "cancellation_failed"
                    ),
                    "run_id": run_id,
                    "utc": status["finished_utc"],
                    "outcome": error.outcome,
                    "restic_exit_code": error.process_returncode,
                }
                if error.signal_error is not None:
                    cancellation_event["signal_error"] = error.signal_error
                if status_write_error is not None:
                    cancellation_event["status_write_error"] = status_write_error
                log_handle.write(json.dumps(cancellation_event) + "\n")
                log_handle.flush()
                os.fsync(log_handle.fileno())
        except OSError:
            pass
        try:
            label = "BACKUP CANCELLED" if error.cooperative else "CANCELLATION FAILED"
            print(f"{label}: {error}", file=sys.stderr)
        except (AttributeError, OSError):
            pass
        return int(status["exit_code"])
    except BaseException as error:
        failed_phase_state = str(status.get("state") or "wrapper")
        if status.get("state") != "partial":
            status["state"] = "failed"
        if status.get("exit_code") is None:
            status["exit_code"] = 130 if isinstance(error, KeyboardInterrupt) else 1
        status["finished_utc"] = utc_now()
        status["failure"] = str(error)
        status["failure_phase"], status["failure_code"] = classify_failure(
            failed_phase_state,
            error,
            int(status["exit_code"]) if status.get("exit_code") is not None else None,
        )
        status["affected_paths"] = collect_affected_paths(status)
        status_write_error = None
        try:
            atomic_write_json(status_path, status)
        except Exception as telemetry_error:
            status_write_error = str(telemetry_error)
        try:
            with log_path.open("a", encoding="utf-8", newline="\n") as log_handle:
                failure_event = {
                    "wrapper_event": "failure",
                    "utc": status["finished_utc"],
                    "error": str(error),
                    "failure_phase": status["failure_phase"],
                    "failure_code": status["failure_code"],
                    "affected_paths": status["affected_paths"],
                    "traceback": traceback.format_exc(),
                }
                if status_write_error is not None:
                    failure_event["status_write_error"] = status_write_error
                log_handle.write(json.dumps(failure_event) + "\n")
                log_handle.flush()
                os.fsync(log_handle.fileno())
        except OSError:
            pass
        try:
            print(f"BACKUP FAILED: {error}", file=sys.stderr)
        except (AttributeError, OSError):
            pass
        return int(status["exit_code"] or 1)


def run(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    with CancellationToken.from_environment() as cancellation:
        try:
            config, run_lock = load_config_under_lock(
                args.config, require_repository=True
            )
        except (RunLockUnavailable, SourceUpdateJournalPresent) as error:
            print(f"BACKUP NOT STARTED: {error}", file=sys.stderr)
            return 75
        try:
            return _run_locked(args, config, cancellation)
        finally:
            run_lock.__exit__(None, None, None)


if __name__ == "__main__":
    raise SystemExit(run())
