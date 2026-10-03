"""Guarded removal of Restic locks that Restic itself classifies as stale."""

from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any, Callable

from credential_repair import (
    is_administrator,
    sanitize,
    sha256_file,
    validate_runtime_manifest,
)
from recovery_health import authenticate, command_result, lock_count, password_command, utc_now
from restic_common import load_config_under_lock
from secret_store import _current_user_sid


SCHEMA = "ResticBackuper.StaleLockRepair.v1"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-config-sha256", required=True)
    parser.add_argument("--expected-plan-id", required=True)
    parser.add_argument("--expected-generation", type=int, required=True)
    parser.add_argument("--expected-user-sid", required=True)
    return parser.parse_args(argv)


def running_restic_processes(
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> list[int]:
    tasklist = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "tasklist.exe"
    result = runner(
        [str(tasklist), "/FI", "IMAGENAME eq restic.exe", "/FO", "CSV", "/NH"],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        shell=False,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode != 0:
        raise RuntimeError("Windows process inspection failed; stale-lock repair is blocked.")
    processes: list[int] = []
    for line in result.stdout.splitlines():
        if not line.strip() or line.lstrip().startswith("INFO:"):
            continue
        try:
            row = next(csv.reader([line]))
        except (csv.Error, StopIteration) as error:
            raise RuntimeError("Windows returned invalid process metadata.") from error
        if len(row) < 2 or row[0].casefold() != "restic.exe":
            continue
        try:
            processes.append(int(row[1].replace(",", "")))
        except ValueError as error:
            raise RuntimeError("Windows returned an invalid Restic process ID.") from error
    return processes


def repair(
    config_path: Path,
    *,
    expected_config_sha256: str,
    expected_plan_id: str,
    expected_generation: int,
    expected_user_sid: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    process_reader: Callable[[], list[int]] | None = None,
    sid_reader: Callable[[], str] = _current_user_sid,
    require_manifest: bool = True,
) -> dict[str, Any]:
    config_path = config_path.resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{64}", expected_config_sha256):
        raise RuntimeError("The expected configuration hash is invalid.")
    if sha256_file(config_path) != expected_config_sha256:
        raise RuntimeError("The protected configuration changed before stale-lock repair.")
    if sid_reader().casefold() != expected_user_sid.casefold():
        raise RuntimeError("Stale-lock repair must be approved by the requesting Windows account.")
    if require_manifest:
        validate_runtime_manifest(config_path.parent)

    config, run_lock = load_config_under_lock(config_path)
    try:
        if sha256_file(config_path) != expected_config_sha256:
            raise RuntimeError("The protected configuration changed while waiting for stale-lock repair.")
        if config["plan_id"] != expected_plan_id or config["config_generation"] != expected_generation:
            raise RuntimeError("The stale-lock request names another backup plan generation.")
        active_processes = (process_reader or (lambda: running_restic_processes(runner)))()
        if active_processes:
            raise RuntimeError(
                "One or more Restic processes are still running; no repository lock was removed."
            )
        restic = Path(config["restic_executable"])
        repository = Path(config["repository"])
        authentication = [
            "--password-command",
            password_command(config, config_path.parent),
        ]
        repository_id, repository_format = authenticate(
            restic,
            repository,
            authentication,
            runner=runner,
        )
        before = lock_count(restic, repository, authentication, runner=runner)
        if before == 0:
            state = "already_unlocked"
            after = 0
        else:
            result = command_result(
                [
                    str(restic),
                    "--repo",
                    str(repository),
                    "--no-cache",
                    *authentication,
                    "unlock",
                ],
                runner=runner,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    f"Restic stale-lock repair failed with exit code {result.returncode}."
                )
            after = lock_count(restic, repository, authentication, runner=runner)
            if after > before:
                raise RuntimeError("Repository lock count increased during guarded repair.")
            state = "repaired" if after == 0 else "locks_remain"
        return {
            "schema": SCHEMA,
            "schema_version": 1,
            "state": state,
            "finished_utc": utc_now(),
            "plan_id": config["plan_id"],
            "config_generation": config["config_generation"],
            "repository_id": repository_id,
            "repository_format": repository_format,
            "locks_before": before,
            "locks_after": after,
            "removed_count": before - after,
            "snapshots_modified": False,
            "data_modified": False,
            "used_remove_all": False,
        }
    finally:
        run_lock.__exit__(None, None, None)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not is_administrator():
        print(json.dumps({"schema": SCHEMA, "schema_version": 1, "state": "failed", "error": "Stale-lock repair requires Windows approval."}))
        return 2
    try:
        result = repair(
            args.config,
            expected_config_sha256=args.expected_config_sha256,
            expected_plan_id=args.expected_plan_id,
            expected_generation=args.expected_generation,
            expected_user_sid=args.expected_user_sid,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["state"] != "locks_remain" else 3
    except Exception as error:
        print(
            json.dumps(
                {
                    "schema": SCHEMA,
                    "schema_version": 1,
                    "state": "failed",
                    "finished_utc": utc_now(),
                    "error": sanitize(str(error)),
                },
                indent=2,
                sort_keys=True,
            )
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
