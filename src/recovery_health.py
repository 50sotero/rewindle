"""Read-only repository and recovery-readiness inspection.

The report intentionally contains no password material.  It independently
authenticates with the active CurrentUser DPAPI envelope and, when available,
the offline recovery key.  Restic is invoked only with read-only commands and
``--no-lock``/``--no-cache``.

Backups set up without a password (``repository_access`` ``no_password``) have
no DPAPI envelope and no recovery key: they are opened with Restic's
``--insecure-no-password`` flag alone, and the two key checks are left out.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import ntpath
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
    NO_PASSWORD_FLAG,
    canonical_windows_path,
    probe_repository_access,
    repository_access,
    restic_child_environment,
    validate_repository_volume,
    windows_volume_metadata,
)
from secret_store import verify_protected_readonly_acl, verify_restricted_acl


SCHEMA = "ResticBackuper.RecoveryHealth.v1"
MAX_JSON_BYTES = 4 * 1024 * 1024
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
DRIVE_REMOVABLE = 2
# Written by backup.py after a passed check of a sample of the stored data.
DATA_CHECK_STATE_NAME = "data-check.json"
MAX_DATA_CHECK_BYTES = 64 * 1024
# The check runs about once a week, so two weeks allows one missed week.
DATA_CHECK_FRESH_DAYS = 14
# Restic's exit code for "wrong password or no key found" (also what a backup with a password answers when it is
# opened with --insecure-no-password, and what one without answers once a password key was added).
RESTIC_NO_MATCHING_KEY_EXIT = 12
# The whole readiness inspection has one minute, so the follow-up look at how the backups open gets a short limit.
ACCESS_FOLLOW_UP_TIMEOUT_SECONDS = 20

# What the checks say when backups are opened without a password, or no longer open the way they were made. A check's
# summary and detail reach the dashboard's window as written: the filter that hides a whole message holding the word
# "password" (RecoveryHealthManager.Sanitize) applies to error text only. The summaries avoid the word anyway; the two
# details below say it on purpose, because it is the news, and tests/test_dashboard_repository_access.py carries them
# through the dashboard's own code to prove that nothing hides or changes them.
NO_PASSWORD_OPENS_SUMMARY = "Rewindle can open your backups."
NO_PASSWORD_FAILS_SUMMARY = (
    "Rewindle couldn't open your backups. Check that the backup drive or Google Drive folder is connected, "
    "then run the checks again."
)
NO_PASSWORD_NOW_ASKS_DETAIL = (
    "These backups now ask for a password, usually because one was added outside Rewindle. "
    "To keep backing up, start new backups in another place."
)
PASSWORD_NOW_OPENS_FREELY_DETAIL = (
    "These backups now open without a password, usually because it was removed outside Rewindle. "
    "To keep using them, see Switching an existing backup in SECURITY.md on Rewindle's GitHub page, "
    "or start new backups in another place."
)


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


def parse_utc_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def valid_utc_timestamp(value: Any) -> bool:
    parsed = parse_utc_timestamp(value)
    return parsed is not None and parsed <= datetime.now(timezone.utc)


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
    # Restic gets the allow-listed environment plus, for a recovery-key check,
    # the one password the caller set. Nothing else in ``environment`` or in
    # this process's own environment reaches it.
    password = None if environment is None else environment.get("RESTIC_PASSWORD")
    result = runner(
        command,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=restic_child_environment(command, password=password),
        shell=False,
        creationflags=CREATE_NO_WINDOW,
    )
    if len(result.stdout.encode("utf-8", errors="replace")) > MAX_JSON_BYTES:
        raise RuntimeError("Restic returned more health data than expected.")
    return result


def password_command(config: dict[str, Any], script_directory: Path) -> str:
    if repository_access(config) == "no_password":
        # Restic runs a password command before it refuses one next to --insecure-no-password, so for these backups none
        # is built: an older install's DPAPI file at secret_file is never looked at.
        raise RuntimeError("This backup opens without a key, so no key reveal is built for it.")
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


def credential_arguments(config: dict[str, Any], script_directory: Path) -> list[str]:
    """What lets Restic open these backups as Rewindle itself does: the flag, or the DPAPI password command."""
    if repository_access(config) == "no_password":
        return [NO_PASSWORD_FLAG]
    return ["--password-command", password_command(config, script_directory)]


def refuse_when_backups_have_no_key(config_path: Path, message: str) -> None:
    """Raise RuntimeError(message) when the configuration at config_path says the backups open without a key.

    For the tools that repair or rotate keys: it reads the configuration file only, so a backup without a key is
    refused before any key, secret or journal is read.
    """
    if repository_access(load_object(config_path)) == "no_password":
        raise RuntimeError(message)


class RepositoryAuthenticationFailed(RuntimeError):
    """Restic could not open the backups; exit_code is what Restic answered."""

    def __init__(self, exit_code: int) -> None:
        super().__init__(f"Repository authentication failed with Restic exit code {exit_code}.")
        self.exit_code = exit_code


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
        raise RepositoryAuthenticationFailed(result.returncode)
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


def backups_now_open_without_password(
    restic: Path,
    repository: Path,
    runner: Callable[..., subprocess.CompletedProcess[str]],
) -> bool:
    """True when backups set up with a password open with no password at all (a read-only look, run only after Restic
    refused the saved password with exit 12). Any other answer, or no answer in time, is False."""
    try:
        return (
            probe_repository_access(
                restic,
                repository,
                timeout_seconds=ACCESS_FOLLOW_UP_TIMEOUT_SECONDS,
                runner=runner,
            )
            == "no_password"
        )
    except Exception:
        return False


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
    # How Restic opens these backups. Read first, so an unsupported value is named here and nowhere else.
    access = repository_access(config)
    no_password = access == "no_password"
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
        "repository_access": access,
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
                "Your backup location on Google Drive and Rewindle's local data folder are set up as expected.",
            )
        except Exception as error:
            add_check(
                checks,
                "repository_storage",
                "fail",
                "Rewindle can't confirm that your backup location on Google Drive and its local data folder are set up correctly.",
                str(error),
            )
    else:
        add_check(
            checks,
            "repository_storage",
            "pass",
            "Your backup location is on a local Windows (NTFS) drive, as set up.",
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
            "An unfinished change must be completed before backups can resume.",
            ", ".join(pending_transactions),
        )
    else:
        add_check(
            checks,
            "pending_transaction",
            "pass",
            "No unfinished changes are waiting.",
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
                # Compared as the mode each one names (a missing key means a password), below.
                "repository_access",
            }
            drift = sorted(
                name for name in shared_fields if recovery["config"].get(name) != config.get(name)
            )
            if repository_access(recovery["config"]) != access:
                drift = sorted([*drift, "repository_access"])
            if drift:
                raise RuntimeError("Recovery configuration drift: " + ", ".join(drift))
        add_check(checks, "recovery_bundle", "pass", "Your recovery information is complete and matches your backup settings.")
    except Exception as error:
        add_check(checks, "recovery_bundle", "fail", "Your recovery information needs repair.", str(error))

    active_auth: list[str] | None = None
    try:
        active_auth = credential_arguments(config, script_directory)
        repository_id, repository_format = authenticate(
            restic, repository, active_auth, runner=runner
        )
        report["repository_id"] = repository_id
        report["repository_format"] = repository_format
        add_check(
            checks,
            "active_credential",
            "pass",
            NO_PASSWORD_OPENS_SUMMARY
            if no_password
            else "Rewindle's saved password for this Windows account opens your backups.",
        )
    except Exception as error:
        detail = str(error)
        if getattr(error, "exit_code", None) == RESTIC_NO_MATCHING_KEY_EXIT:
            if no_password:
                detail = NO_PASSWORD_NOW_ASKS_DETAIL
            elif backups_now_open_without_password(restic, repository, runner):
                detail = PASSWORD_NOW_OPENS_FREELY_DETAIL
        add_check(
            checks,
            "active_credential",
            "fail",
            NO_PASSWORD_FAILS_SUMMARY
            if no_password
            else "Rewindle's saved password for this Windows account can't open your backups, so scheduled backups would fail.",
            detail,
        )

    if not no_password:
        # Backups without a password have no recovery key to check.
        try:
            acl_verifier(recovery_key)
            password = parse_recovery_key(recovery_key, repository)
            environment = restic_child_environment()
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
            add_check(checks, "recovery_key", "pass", "Your recovery key opens your backups on its own.")
        except Exception as error:
            add_check(checks, "recovery_key", "fail", "Your recovery key is missing, unsafe to use, or doesn't open your backups.", str(error))

    try:
        usage = shutil.disk_usage(repository)
        report["free_bytes"] = usage.free
        reserve = report["reserve_bytes"]
        if usage.free < reserve:
            add_check(checks, "capacity", "fail", "The drive holding your backups is almost full: it has less free space than Rewindle keeps in reserve.")
        elif usage.free < reserve * 1.5:
            add_check(checks, "capacity", "warn", "The drive holding your backups is getting full.")
        else:
            add_check(checks, "capacity", "pass", "The drive holding your backups has plenty of free space.")
    except Exception as error:
        add_check(checks, "capacity", "fail", "Rewindle couldn't check the free space on the drive holding your backups.", str(error))

    if active_auth is not None:
        try:
            report["active_lock_count"] = lock_count(
                restic, repository, active_auth, runner=runner
            )
            count = report["active_lock_count"]
            add_check(
                checks,
                "locks",
                "pass" if count == 0 else "warn",
                "No leftover locks from interrupted backups."
                if count == 0
                else f"{count} lock(s) are present. If no backup is running, they are leftovers; choose Repair stale locks.",
            )
        except Exception as error:
            add_check(checks, "locks", "fail", "Rewindle couldn't check for leftover locks.", str(error))
    else:
        add_check(checks, "locks", "fail", "Rewindle can't check for leftover locks until its saved password works again.")

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
            add_check(checks, "last_verification", "pass", "Your latest backup was checked, and its restore test file came back correctly.")
        elif verified:
            add_check(checks, "last_verification", "warn", "The last checked backup was made before your latest settings change. A new backup will refresh it.")
        else:
            add_check(checks, "last_verification", "fail", "No fully checked backup is on record yet.")
    except Exception as error:
        add_check(checks, "last_verification", "fail", "The record of your latest checked backup isn't available.", str(error))

    subset_parts = config.get("read_data_subset_parts", 0)
    if isinstance(subset_parts, int) and not isinstance(subset_parts, bool) and subset_parts > 0:
        data_check_path = state_directory / DATA_CHECK_STATE_NAME
        data_check_next = (
            "Rewindle does this about once a week during a backup; choose Back up now to do it sooner."
        )
        try:
            record = None
            if data_check_path.exists() or data_check_path.is_symlink():
                record = load_object(data_check_path, MAX_DATA_CHECK_BYTES)
                checked = parse_utc_timestamp(record.get("last_data_subset_check_utc"))
                if record.get("schema_version") != 1 or checked is None:
                    raise RuntimeError("The record of the last data check is invalid.")
                if report["repository_id"] is not None and record.get("repository_id") != report["repository_id"]:
                    # A record left by an earlier backup location says nothing about this one.
                    record = None
            if record is None:
                add_check(
                    checks,
                    "data_check",
                    "warn",
                    "A sample of your saved backup data hasn't been read back and checked yet. " + data_check_next,
                )
            else:
                report["last_data_subset_check_utc"] = record["last_data_subset_check_utc"]
                now = datetime.now(timezone.utc)
                if checked <= now and (now - checked).total_seconds() <= DATA_CHECK_FRESH_DAYS * 86400:
                    add_check(
                        checks,
                        "data_check",
                        "pass",
                        "A sample of your saved backup data was read back and checked in the last two weeks.",
                    )
                else:
                    add_check(
                        checks,
                        "data_check",
                        "warn",
                        "A sample of your saved backup data hasn't been read back and checked in the last two weeks. " + data_check_next,
                        "The recorded time of the last check is later than this PC's clock."
                        if checked > now
                        else "Last checked " + record["last_data_subset_check_utc"] + ".",
                    )
        except Exception as error:
            add_check(
                checks,
                "data_check",
                "warn",
                "Rewindle couldn't tell when a sample of your saved backup data was last read back and checked. " + data_check_next,
                str(error),
            )

    if isinstance(status, dict) and status.get("maintenance_hold") is True:
        anomaly = status.get("change_anomaly")
        reasons = anomaly.get("reasons") if isinstance(anomaly, dict) else None
        detail = ", ".join(str(item) for item in reasons[:10]) if isinstance(reasons, list) else ""
        add_check(
            checks,
            "change_anomaly",
            "warn",
            "Your latest backup changed far more than usual and is waiting for you to confirm these changes.",
            detail,
        )
    else:
        add_check(
            checks,
            "change_anomaly",
            "pass",
            "No unusual changes are waiting for your confirmation.",
        )

    # Backups without a password have no keys to rotate: nothing to check here.
    if not no_password:
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
                environment = restic_child_environment()
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
                    "The recovery key kept from before your last key change still opens your backups.",
                )
            except Exception as error:
                add_check(
                    checks,
                    "rotation_rollback_key",
                    "fail",
                    "The recovery key kept from before your last key change didn't pass its check.",
                    str(error),
                )
        else:
            add_check(
                checks,
                "rotation_rollback_key",
                "pass",
                "You haven't changed your keys, so your original recovery key is still the one in use.",
            )

    history_path = state_directory / "restore-history.json"
    # The restore drill's evidence names where its credential came from: the recovery key, or "none" for backups
    # that open without one.
    drill_credential_source = "none" if no_password else "recovery_key"
    try:
        if not history_path.exists():
            add_check(
                checks,
                "restore_drill",
                "warn",
                "You haven't run a restore drill yet.",
                "Choose Run restore drill to restore a small sample of your files and check it."
                if no_password
                else "Choose Run restore drill to restore a small sample of your files with your recovery key and check it.",
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
                and item.get("credential_source") == drill_credential_source
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
                    "A restore drill (the restore test file plus a small sample of your files) passed."
                    if no_password
                    else "A restore drill with your recovery key (the restore test file plus a small sample of your files) passed.",
                )
            else:
                add_check(
                    checks,
                    "restore_drill",
                    "warn",
                    "Run the restore drill to prove Rewindle can restore your files."
                    if no_password
                    else "Run the restore drill to prove your recovery key can restore your files.",
                )
    except Exception as error:
        add_check(checks, "restore_drill", "warn", "Rewindle couldn't read the record of past restore drills.", str(error))

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
                    "summary": "Rewindle couldn't run its recovery check.",
                    "detail": str(error)[:1000],
                }
            ],
        }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report.get("overall_status") != "blocked" else 2


if __name__ == "__main__":
    raise SystemExit(main())
