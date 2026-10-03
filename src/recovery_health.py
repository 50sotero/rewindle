"""Read-only repository and recovery-readiness inspection.

The report intentionally contains no password material.  It independently
authenticates with the active CurrentUser DPAPI envelope and, when available,
the offline recovery key.  Restic is invoked only with read-only commands and
``--no-lock``/``--no-cache``.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import ntpath
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Callable

from refresh_recovery_tools import (
    GOOGLE_DRIVEFS_MODE,
    validate_bundle,
    validate_config_pair,
    validate_storage_config,
)
from restic_common import (
    DRIVE_FIXED,
    canonical_windows_path,
    validate_repository_volume,
    windows_volume_metadata,
)
from secret_store import verify_protected_readonly_acl, verify_restricted_acl


SCHEMA = "ResticBackuper.RecoveryHealth.v1"
MAX_JSON_BYTES = 4 * 1024 * 1024
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
DRIVE_REMOVABLE = 2


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        type=Path,
        default=Path(r"C:\Program Files\ResticBackuper\backup-config.json"),
    )
    return parser.parse_args(argv)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def valid_utc_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not value.endswith("Z"):
        return False
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed <= datetime.now(timezone.utc)


def load_object(path: Path, maximum_bytes: int = MAX_JSON_BYTES) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"required normal JSON file is missing: {path}")
    size = path.stat().st_size
    if size <= 0 or size > maximum_bytes:
        raise RuntimeError(f"JSON file size is invalid: {path}")
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise RuntimeError(f"JSON file does not contain one object: {path}")
    return value


def parse_recovery_key(path: Path, repository: Path) -> str:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("The configured recovery key is missing or not a normal file.")
    if path.stat().st_size <= 0 or path.stat().st_size > 64 * 1024:
        raise RuntimeError("The recovery key file size is invalid.")
    text = path.read_text(encoding="utf-8-sig")
    repositories = re.findall(r"^Repository:\s*(.+?)\s*$", text, flags=re.MULTILINE)
    passwords = re.findall(r"^Password:\s*(\S+)\s*$", text, flags=re.MULTILINE)
    if len(repositories) != 1 or len(passwords) != 1 or len(passwords[0]) < 40:
        raise RuntimeError("The recovery key does not contain one valid repository/password pair.")
    expected = ntpath.normcase(canonical_windows_path(repository))
    recorded = ntpath.normcase(canonical_windows_path(repositories[0]))
    if recorded != expected:
        raise RuntimeError("The recovery key names a different repository.")
    return passwords[0]


def command_result(
    command: list[str],
    *,
    environment: dict[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> subprocess.CompletedProcess[str]:
    result = runner(
        command,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=environment,
        shell=False,
        creationflags=CREATE_NO_WINDOW,
    )
    if len(result.stdout.encode("utf-8", errors="replace")) > MAX_JSON_BYTES:
        raise RuntimeError("Restic returned more health data than expected.")
    return result


def password_command(config: dict[str, Any], script_directory: Path) -> str:
    python = Path(str(config.get("python_executable", "")))
    secret = Path(str(config.get("secret_file", "")))
    helper = script_directory / "secret_store.py"
    for path, label in ((python, "Python"), (secret, "DPAPI secret"), (helper, "DPAPI helper")):
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"The configured {label} is missing or unsafe.")
    return subprocess.list2cmdline(
        [
            str(python).replace("\\", "/"),
            "-I",
            "-S",
            "-B",
            str(helper).replace("\\", "/"),
            "reveal",
            "--secret-file",
            str(secret).replace("\\", "/"),
        ]
    )


def parse_repository_config(stdout: str) -> tuple[str, int]:
    try:
        value = json.loads(stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("Restic returned invalid repository metadata.") from error
    if not isinstance(value, dict):
        raise RuntimeError("Restic returned invalid repository metadata.")
    repository_id = value.get("id")
    version = value.get("version")
    if not isinstance(repository_id, str) or not re.fullmatch(r"[0-9a-f]{64}", repository_id):
        raise RuntimeError("Restic returned an invalid repository ID.")
    if isinstance(version, bool) or not isinstance(version, int) or version <= 0:
        raise RuntimeError("Restic returned an invalid repository format version.")
    return repository_id, version


def authenticate(
    restic: Path,
    repository: Path,
    authentication: list[str],
    *,
    environment: dict[str, str] | None = None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> tuple[str, int]:
    result = command_result(
        [
            str(restic),
            "--repo",
            str(repository),
            "--no-cache",
            "--no-lock",
            "--json",
            *authentication,
            "cat",
            "config",
        ],
        environment=environment,
        runner=runner,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Repository authentication failed with Restic exit code {result.returncode}.")
    return parse_repository_config(result.stdout)


def lock_count(
    restic: Path,
    repository: Path,
    authentication: list[str],
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> int:
    result = command_result(
        [
            str(restic),
            "--repo",
            str(repository),
            "--no-cache",
            "--no-lock",
            "--json",
            *authentication,
            "list",
            "locks",
        ],
        runner=runner,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Repository lock inspection failed with Restic exit code {result.returncode}.")
    try:
        value = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as error:
        raise RuntimeError("Restic returned invalid lock metadata.") from error
    if isinstance(value, list):
        return len(value)
    if isinstance(value, dict):
        locks = value.get("locks")
        if isinstance(locks, list):
            return len(locks)
    raise RuntimeError("Restic returned an unsupported lock response.")


def add_check(
    checks: list[dict[str, Any]],
    check_id: str,
    status: str,
    summary: str,
    detail: str = "",
) -> None:
    checks.append(
        {
            "id": check_id,
            "status": status,
            "summary": summary[:300],
            "detail": detail[:1000],
        }
    )


def inspect(
    config_path: Path,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    acl_verifier: Callable[[Path], None] = verify_restricted_acl,
    history_acl_verifier: Callable[[Path], None] = verify_protected_readonly_acl,
) -> dict[str, Any]:
    config_path = config_path.resolve(strict=True)
    config = load_object(config_path)
    storage = validate_storage_config(config, "protected")
    script_directory = config_path.parent
    repository = Path(str(config.get("repository", ""))).resolve(strict=True)
    restic = Path(str(config.get("restic_executable", ""))).resolve(strict=True)
    recovery_directory = Path(str(config.get("recovery_tools_directory", ""))).resolve(strict=True)
    state_directory = Path(str(config.get("state_directory", ""))).resolve(strict=True)
    recovery_key = Path(str(config.get("recovery_key_file", "")))
    minimum_free = config.get("minimum_free_gib", 0)
    if isinstance(minimum_free, bool) or not isinstance(minimum_free, (int, float)) or minimum_free < 0:
        raise RuntimeError("The configured free-space reserve is invalid.")
    if not (repository / "config").is_file() or restic.is_symlink():
        raise RuntimeError("The configured repository or Restic executable is unavailable.")

    checks: list[dict[str, Any]] = []
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "schema_version": 1,
        "generated_utc": utc_now(),
        "plan_id": config.get("plan_id"),
        "config_generation": config.get("config_generation"),
        "repository": str(repository),
        "repository_storage_mode": storage["mode"],
        "repository_id": None,
        "repository_format": None,
        "free_bytes": None,
        "reserve_bytes": int(float(minimum_free) * 1024**3),
        "active_lock_count": None,
        "checks": checks,
    }

    if storage["mode"] == GOOGLE_DRIVEFS_MODE:
        try:
            validate_repository_volume(config)
            for path, label in (
                (state_directory, "ProgramData state"),
                (recovery_directory, "Recovery tools"),
                (Path(str(storage["cache"])), "Google DriveFS cache"),
            ):
                metadata = windows_volume_metadata(path)
                if (
                    metadata.filesystem != "NTFS"
                    or metadata.drive_type not in {DRIVE_FIXED, DRIVE_REMOVABLE}
                ):
                    raise RuntimeError(
                        f"{label} is not on a supported local NTFS volume."
                    )
            add_check(
                checks,
                "repository_storage",
                "pass",
                "DriveFS repository and protected local NTFS paths match their bindings.",
            )
        except Exception as error:
            add_check(
                checks,
                "repository_storage",
                "fail",
                "DriveFS repository or protected local storage binding is unavailable.",
                str(error),
            )
    else:
        add_check(
            checks,
            "repository_storage",
            "pass",
            "The local NTFS repository storage mode is configured.",
        )

    pending_transaction_names = (
        "repository-relocation.journal.json",
        "plan-migration.journal.json",
        "credential-rotation.journal.json",
    )
    pending_transactions = [
        name
        for name in pending_transaction_names
        if (state_directory / name).exists() or (state_directory / name).is_symlink()
    ]
    if pending_transactions:
        add_check(
            checks,
            "pending_transaction",
            "fail",
            "A protected transaction must be recovered before backups resume.",
            ", ".join(pending_transactions),
        )
    else:
        add_check(
            checks,
            "pending_transaction",
            "pass",
            "No interrupted protected transaction is pending.",
        )

    try:
        recovery = validate_bundle(recovery_directory)
        validate_config_pair(config, recovery["config"])
        if recovery["config"] != config:
            # Recovery-local launch paths may deliberately differ. The shared
            # plan and policy have already been validated by validate_config_pair.
            shared_fields = set(config) - {
                "restic_executable",
                "python_executable",
                "state_directory",
                "secret_file",
                "recovery_key_file",
                "exclude_file",
                "canary_file",
            }
            drift = sorted(
                name for name in shared_fields if recovery["config"].get(name) != config.get(name)
            )
            if drift:
                raise RuntimeError("Recovery configuration drift: " + ", ".join(drift))
        add_check(checks, "recovery_bundle", "pass", "Recovery bundle manifest and plan binding are valid.")
    except Exception as error:
        add_check(checks, "recovery_bundle", "fail", "Recovery bundle needs repair.", str(error))

    dpapi_auth: list[str] | None = None
    try:
        dpapi_auth = ["--password-command", password_command(config, script_directory)]
        repository_id, repository_format = authenticate(
            restic, repository, dpapi_auth, runner=runner
        )
        report["repository_id"] = repository_id
        report["repository_format"] = repository_format
        add_check(checks, "active_credential", "pass", "The active DPAPI credential unlocks the repository.")
    except Exception as error:
        add_check(checks, "active_credential", "fail", "The active DPAPI credential cannot unlock the repository.", str(error))

    try:
        acl_verifier(recovery_key)
        password = parse_recovery_key(recovery_key, repository)
        environment = os.environ.copy()
        environment["RESTIC_PASSWORD"] = password
        try:
            recovery_id, recovery_format = authenticate(
                restic,
                repository,
                [],
                environment=environment,
                runner=runner,
            )
        finally:
            environment.pop("RESTIC_PASSWORD", None)
            password = ""
        if report["repository_id"] is not None and recovery_id != report["repository_id"]:
            raise RuntimeError("The recovery key authenticated to an unexpected repository ID.")
        report["repository_id"] = recovery_id
        report["repository_format"] = recovery_format
        add_check(checks, "recovery_key", "pass", "The restricted recovery key independently unlocks the repository.")
    except Exception as error:
        add_check(checks, "recovery_key", "fail", "The recovery key is missing, unsafe, or cannot unlock the repository.", str(error))

    try:
        usage = shutil.disk_usage(repository)
        report["free_bytes"] = usage.free
        reserve = report["reserve_bytes"]
        if usage.free < reserve:
            add_check(checks, "capacity", "fail", "Repository free space is below the configured reserve.")
        elif usage.free < reserve * 1.5:
            add_check(checks, "capacity", "warn", "Repository free space is approaching the configured reserve.")
        else:
            add_check(checks, "capacity", "pass", "Repository free space is above the configured reserve.")
    except Exception as error:
        add_check(checks, "capacity", "fail", "Repository capacity could not be inspected.", str(error))

    if dpapi_auth is not None:
        try:
            report["active_lock_count"] = lock_count(
                restic, repository, dpapi_auth, runner=runner
            )
            count = report["active_lock_count"]
            add_check(
                checks,
                "locks",
                "pass" if count == 0 else "warn",
                "No repository locks are present."
                if count == 0
                else f"{count} repository lock(s) require activity/staleness review.",
            )
        except Exception as error:
            add_check(checks, "locks", "fail", "Repository locks could not be inspected.", str(error))
    else:
        add_check(checks, "locks", "fail", "Repository locks cannot be inspected without the active credential.")

    status_path = state_directory / "last-success.json"
    status: dict[str, Any] | None = None
    try:
        status = load_object(status_path)
        verification = status.get("verification")
        current_plan = status.get("plan_id") == config.get("plan_id")
        current_generation = status.get("config_generation") == config.get("config_generation")
        verified = (
            status.get("state") in {"success", "success_unchanged"}
            and status.get("verification_complete") is True
            and isinstance(verification, dict)
            and verification.get("repository_structure") is True
            and isinstance(verification.get("canary"), dict)
            and verification["canary"].get("verified") is True
        )
        if verified and current_plan and current_generation:
            add_check(checks, "last_verification", "pass", "The current plan's latest backup passed structure and canary verification.")
        elif verified:
            add_check(checks, "last_verification", "warn", "The last verified backup predates the current plan generation.")
        else:
            add_check(checks, "last_verification", "fail", "No complete structure-and-canary verification is recorded.")
    except Exception as error:
        add_check(checks, "last_verification", "fail", "The latest verified backup record is unavailable.", str(error))

    if isinstance(status, dict) and status.get("maintenance_hold") is True:
        anomaly = status.get("change_anomaly")
        reasons = anomaly.get("reasons") if isinstance(anomaly, dict) else None
        detail = ", ".join(str(item) for item in reasons[:10]) if isinstance(reasons, list) else ""
        add_check(
            checks,
            "change_anomaly",
            "warn",
            "The latest verified snapshot is under a change-anomaly review hold.",
            detail,
        )
    else:
        add_check(
            checks,
            "change_anomaly",
            "pass",
            "No change-anomaly review hold is active.",
        )

    rotation_path = state_directory / "key-rotation-latest.json"
    if rotation_path.exists() or rotation_path.is_symlink():
        try:
            acl_verifier(rotation_path)
            rotation = load_object(rotation_path)
            if (
                rotation.get("schema") != "ResticBackuper.KeyRotation.v1"
                or rotation.get("state") != "rotated"
                or rotation.get("plan_id") != config.get("plan_id")
                or rotation.get("config_generation") != config.get("config_generation")
                or rotation.get("repository_id") != report.get("repository_id")
                or rotation.get("previous_repository_key_retained") is not True
            ):
                raise RuntimeError("The latest key-rotation evidence does not bind this plan.")
            previous = Path(str(rotation.get("previous_recovery_file", ""))).resolve(strict=True)
            configured_recovery = recovery_key.resolve(strict=True)
            if previous.parent != configured_recovery.parent or ".previous-" not in previous.name:
                raise RuntimeError("The previous recovery-key path is outside the configured key directory.")
            acl_verifier(previous)
            previous_password = parse_recovery_key(previous, repository)
            environment = os.environ.copy()
            environment["RESTIC_PASSWORD"] = previous_password
            try:
                previous_id, previous_format = authenticate(
                    restic, repository, [], environment=environment, runner=runner
                )
            finally:
                environment.pop("RESTIC_PASSWORD", None)
                previous_password = ""
            if previous_id != report.get("repository_id") or previous_format != report.get("repository_format"):
                raise RuntimeError("The retained previous key authenticates another repository.")
            add_check(
                checks,
                "rotation_rollback_key",
                "pass",
                "The retained pre-rotation recovery key still independently unlocks the repository.",
            )
        except Exception as error:
            add_check(
                checks,
                "rotation_rollback_key",
                "fail",
                "The retained pre-rotation recovery path failed verification.",
                str(error),
            )
    else:
        add_check(
            checks,
            "rotation_rollback_key",
            "pass",
            "No completed key rotation is recorded; the original recovery credential remains active.",
        )

    history_path = state_directory / "restore-history.json"
    try:
        if not history_path.exists():
            add_check(
                checks,
                "restore_drill",
                "warn",
                "No representative restore drill has been recorded yet.",
                "Use Run restore drill to recover and verify a bounded sample with the restricted recovery key.",
            )
            history = None
        else:
            history_acl_verifier(history_path)
            history = load_object(history_path)
        if history is not None:
            entries = history.get("entries")
            if history.get("schema_version") != 2 or not isinstance(entries, list) or len(entries) > 50:
                raise RuntimeError("Restore history schema is invalid.")
            verified_entries = [
                item
                for item in entries
                if isinstance(item, dict)
                and item.get("kind") == "recovery_key_representative_drill"
                and item.get("credential_source") == "recovery_key"
                and item.get("plan_id") == config.get("plan_id")
                and item.get("config_generation") == config.get("config_generation")
                and item.get("snapshot_generation") == config.get("config_generation")
                and item.get("repository_id") == report.get("repository_id")
                and isinstance(item.get("snapshot_id"), str)
                and re.fullmatch(r"[0-9a-f]{64}", item["snapshot_id"])
                and item.get("snapshot_binding") == "plan"
                and item.get("result") == "verified"
                and item.get("verified") is True
                and item.get("canary_verified") is True
                and item.get("sample_policy") == "one-or-two-bounded-files-per-source-v1"
                and isinstance(item.get("sample_file_count"), int)
                and 2 <= item["sample_file_count"] <= 8
                and isinstance(item.get("sample_bytes"), int)
                and 0 < item["sample_bytes"] <= 32 * 1024 * 1024
                and item.get("backend_exit_code") == 0
                and item.get("partial_target_retained") is False
                and valid_utc_timestamp(item.get("finished_utc"))
            ]
            if verified_entries:
                report["last_restore_drill_utc"] = verified_entries[-1].get("finished_utc")
                add_check(
                    checks,
                    "restore_drill",
                    "pass",
                    "A recovery-key restore of the canary and a bounded representative sample is recorded.",
                )
            else:
                add_check(
                    checks,
                    "restore_drill",
                    "warn",
                    "Run and verify the guided recovery-key restore drill.",
                )
    except Exception as error:
        add_check(checks, "restore_drill", "warn", "Restore-drill history could not be validated.", str(error))

    statuses = {item["status"] for item in checks}
    report["overall_status"] = "blocked" if "fail" in statuses else "warning" if "warn" in statuses else "healthy"
    report["failed_check_count"] = sum(item["status"] == "fail" for item in checks)
    report["warning_check_count"] = sum(item["status"] == "warn" for item in checks)
    return report


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = inspect(args.config)
    except Exception as error:
        report = {
            "schema": SCHEMA,
            "schema_version": 1,
            "generated_utc": utc_now(),
            "overall_status": "blocked",
            "failed_check_count": 1,
            "warning_check_count": 0,
            "checks": [
                {
                    "id": "health_runtime",
                    "status": "fail",
                    "summary": "Recovery readiness could not be inspected.",
                    "detail": str(error)[:1000],
                }
            ],
        }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report.get("overall_status") != "blocked" else 2


if __name__ == "__main__":
    raise SystemExit(main())
