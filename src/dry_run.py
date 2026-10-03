"""Run the production source/exclusion scan without creating a snapshot."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import secrets
import sys
import time
import traceback
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from restic_common import (
    DEFAULT_CONFIG,
    RunLockUnavailable,
    SourceUpdateJournalPresent,
    atomic_write_json,
    ensure_free_space,
    load_config_under_lock,
    restic_base,
    sanitized_command,
    sha256_file,
    stream_command,
    utc_now,
    validate_repository_storage_readiness,
    validate_repository_volume,
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    return parser.parse_args(argv)


def _run_locked(config: dict[str, Any]) -> int:
    state_directory = Path(config["state_directory"])
    logs_directory = state_directory / "logs"
    logs_directory.mkdir(parents=True, exist_ok=True)
    run_id = datetime.now().strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(4)
    log_path = logs_directory / f"dry-run-{run_id}.jsonl.log"
    status_path = state_directory / "dry-run-status.json"
    report_path = state_directory / f"dry-run-report-{run_id}.json"
    latest_report_path = state_directory / "dry-run-latest.json"
    report: dict[str, Any] = {
        "schema_version": 1,
        "run_id": run_id,
        "state": "starting",
        "started_utc": utc_now(),
        "finished_utc": None,
        "wrapper_pid": os.getpid(),
        "repository": config["repository"],
        "repository_storage_mode": config.get(
            "repository_storage_mode", "local_ntfs"
        ),
        "repository_readiness": None,
        "repository_volume_serial": config["repository_volume_serial"],
        "sources": config["sources"],
        "exclude_file": config["exclude_file"],
        "exclude_file_sha256": sha256_file(Path(config["exclude_file"])),
        "restic_executable_sha256": sha256_file(
            Path(config["restic_executable"])
        ),
        "log_file": str(log_path),
        "report_file": str(report_path),
        "error_count": 0,
        "error_samples": [],
        "error_kinds": {},
        "progress": None,
        "summary": None,
        "restic_exit_code": None,
    }
    try:
        validate_repository_volume(config)
        report["repository_readiness"] = validate_repository_storage_readiness(
            config,
            volume_validated=True,
        )
        report["free_bytes_before"] = ensure_free_space(config)
        command = restic_base(config, json_output=True) + [
            "backup",
            *config["sources"],
            "--dry-run",
            "--iexclude-file",
            config["exclude_file"],
            "--exclude-caches",
            "--no-scan",
            "--read-concurrency",
            str(int(config.get("read_concurrency", 2))),
            "--group-by",
            "host,paths,tags",
            "--host",
            config["hostname"],
            "--tag",
            "dry-run",
        ]
        report["command"] = sanitized_command(command)
        report["state"] = "scanning"
        atomic_write_json(status_path, report)
        error_kinds: Counter[str] = Counter()
        last_status_write = 0.0

        with log_path.open(
            "a", encoding="utf-8", newline="\n", buffering=1
        ) as log_handle:
            log_handle.write(
                json.dumps(
                    {
                        "wrapper_event": "dry_run_started",
                        "utc": utc_now(),
                        "command": sanitized_command(command),
                    }
                )
                + "\n"
            )

            def on_line(line: str) -> None:
                nonlocal last_status_write
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    return
                if not isinstance(event, dict):
                    return
                message_type = event.get("message_type")
                if message_type == "status":
                    report["progress"] = event
                elif message_type == "summary":
                    report["summary"] = event
                elif message_type == "error":
                    report["error_count"] += 1
                    during = str(event.get("during") or "unknown")
                    message = str((event.get("error") or {}).get("message") or "")
                    kind = "access_denied" if "access is denied" in message.lower() else during
                    error_kinds[kind] += 1
                    if len(report["error_samples"]) < 50:
                        report["error_samples"].append(event)
                now = time.monotonic()
                if now - last_status_write >= 5 or (
                    message_type == "error" and report["error_count"] % 100 == 0
                ):
                    report["error_kinds"] = dict(error_kinds)
                    atomic_write_json(status_path, report)
                    last_status_write = now

            return_code = stream_command(command, log_handle, on_line)

        report["restic_exit_code"] = return_code
        report["error_kinds"] = dict(error_kinds)
        report["finished_utc"] = utc_now()
        if return_code == 0 and report["error_count"] == 0:
            report["state"] = "clean"
        elif return_code == 3:
            report["state"] = "source_errors"
        else:
            report["state"] = "failed"
        atomic_write_json(status_path, report)
        atomic_write_json(report_path, report)
        atomic_write_json(latest_report_path, report)
        print(
            json.dumps(
                {
                    "state": report["state"],
                    "restic_exit_code": return_code,
                    "error_count": report["error_count"],
                    "error_kinds": report["error_kinds"],
                    "summary": report["summary"],
                    "report_file": str(report_path),
                    "log_file": str(log_path),
                },
                indent=2,
            )
        )
        return return_code
    except Exception as error:
        report["state"] = "failed"
        report["finished_utc"] = utc_now()
        report["failure"] = str(error)
        report["traceback"] = traceback.format_exc()
        atomic_write_json(status_path, report)
        atomic_write_json(report_path, report)
        print(f"DRY RUN FAILED: {error}", file=sys.stderr)
        return 1


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        config, run_lock = load_config_under_lock(
            args.config, require_repository=True
        )
    except (RunLockUnavailable, SourceUpdateJournalPresent) as error:
        print(f"DRY RUN NOT STARTED: {error}", file=sys.stderr)
        return 75
    try:
        return _run_locked(config)
    finally:
        run_lock.__exit__(None, None, None)


if __name__ == "__main__":
    raise SystemExit(main())
