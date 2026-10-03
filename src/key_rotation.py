"""Rotate repository access without retiring the known-good prior key.

The new Restic key is added and authenticated first.  The CurrentUser DPAPI
envelope and configured recovery-key document are then switched under the
global operation lock, while the previous recovery document and repository key
remain available for rollback.  A durable journal makes an interrupted local
publish resumable and blocks normal backups until recovery completes.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
from typing import Any, Callable

from credential_repair import sha256_file, validate_runtime_manifest
from recovery_health import authenticate, parse_recovery_key, password_command, utc_now
from restic_common import atomic_write_json, load_config_under_lock
from secret_store import (
    _current_user_sid,
    load_secret,
    replace_secret,
    restrict_acl,
    verify_restricted_acl,
    write_recovery_key,
)


SCHEMA = "ResticBackuper.KeyRotation.v1"
JOURNAL_NAME = "credential-rotation.journal.json"
LATEST_NAME = "key-rotation-latest.json"
HISTORY_NAME = "key-rotation-history.json"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_HISTORY = 32


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-config-sha256", required=True)
    parser.add_argument("--expected-plan-id", required=True)
    parser.add_argument("--expected-generation", type=int, required=True)
    parser.add_argument("--expected-user-sid", required=True)
    return parser.parse_args(argv)


def is_administrator() -> bool:
    return os.name == "nt" and bool(ctypes.windll.shell32.IsUserAnAdmin())


def _write_protected_json(path: Path, value: Any) -> None:
    atomic_write_json(path, value)
    restrict_acl(path)
    verify_restricted_acl(path)


def _normal_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and not (
        hasattr(os.path, "isjunction") and os.path.isjunction(path)
    )


def _read_json(path: Path) -> Any:
    if not _normal_file(path) or path.stat().st_size > MAX_JSON_BYTES:
        raise RuntimeError(f"Protected rotation record is missing or unsafe: {path.name}")
    verify_restricted_acl(path)
    return json.loads(path.read_text(encoding="utf-8-sig"))


def _restic_result(
    runner: Callable[..., subprocess.CompletedProcess[str]],
    command: list[str],
    *,
    environment: dict[str, str] | None = None,
    timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
    return runner(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=environment,
        timeout=timeout,
    )


def _key_list(
    restic: Path,
    repository: Path,
    authentication: list[str],
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]],
    environment: dict[str, str] | None = None,
) -> tuple[list[dict[str, Any]], str]:
    command = [
        str(restic),
        "--repo",
        str(repository),
        "--no-cache",
        "--no-lock",
        "--json",
        *authentication,
        "key",
        "list",
    ]
    result = _restic_result(runner, command, environment=environment)
    if result.returncode != 0:
        raise RuntimeError(f"Restic could not inspect repository keys (exit {result.returncode}).")
    try:
        rows = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("Restic returned invalid key-list evidence.") from error
    if not isinstance(rows, list) or len(rows) < 1 or len(rows) > 1024:
        raise RuntimeError("Restic returned an invalid repository key list.")
    current = []
    validated: list[dict[str, Any]] = []
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise RuntimeError("Restic returned an invalid repository key record.")
        key_id = row["id"].lower()
        if not re.fullmatch(r"[0-9a-f]{64}", key_id) or type(row.get("current")) is not bool:
            raise RuntimeError("Restic returned a malformed repository key identity.")
        copy = dict(row)
        copy["id"] = key_id
        validated.append(copy)
        if row["current"]:
            current.append(key_id)
    if len(current) != 1:
        raise RuntimeError("Restic did not identify exactly one current repository key.")
    return validated, current[0]


def _temporary_password_file(state: Path, rotation_id: str, password: str) -> Path:
    path = state / f".rotation-{rotation_id}.new-key.tmp"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        restrict_acl(path)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(password.encode("ascii") + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        verify_restricted_acl(path)
        return path
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
            descriptor = -1
        path.unlink(missing_ok=True)
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _remove_temporary_password(path: Path | None) -> None:
    if path is None:
        return
    try:
        if _normal_file(path):
            size = path.stat().st_size
            with path.open("r+b", buffering=0) as handle:
                handle.write(b"\0" * min(size, 4096))
                handle.flush()
                os.fsync(handle.fileno())
    finally:
        path.unlink(missing_ok=True)


def _validate_journal(
    journal: dict[str, Any], config: dict[str, Any], config_path: Path
) -> dict[str, Path]:
    if (
        journal.get("schema") != SCHEMA
        or journal.get("schema_version") != 1
        or journal.get("plan_id") != config["plan_id"]
        or journal.get("config_generation") != config["config_generation"]
        or journal.get("config_sha256") != sha256_file(config_path)
        or journal.get("repository") != config["repository"]
    ):
        raise RuntimeError("The pending credential-rotation journal does not bind the active plan.")
    recovery = Path(config["recovery_key_file"]).resolve(strict=False)
    paths = {
        "recovery": recovery,
        "pending": Path(str(journal.get("pending_recovery_file", ""))).resolve(strict=False),
        "previous": Path(str(journal.get("previous_recovery_file", ""))).resolve(strict=False),
    }
    if paths["pending"].parent != recovery.parent or paths["previous"].parent != recovery.parent:
        raise RuntimeError("The pending credential-rotation paths escape the recovery-key directory.")
    if paths["pending"] in (paths["recovery"], paths["previous"]) or paths["previous"] == paths["recovery"]:
        raise RuntimeError("The pending credential-rotation paths overlap.")
    for name in ("old_recovery_sha256", "new_recovery_sha256"):
        if not isinstance(journal.get(name), str) or not re.fullmatch(
            r"[0-9a-f]{64}", journal[name]
        ):
            raise RuntimeError("The pending credential-rotation hashes are invalid.")
    return paths


def _password_from_hashed_recovery(
    candidates: list[Path], expected_hash: str, repository: Path
) -> tuple[str, Path] | tuple[None, None]:
    for candidate in candidates:
        if not _normal_file(candidate):
            continue
        verify_restricted_acl(candidate)
        if sha256_file(candidate) == expected_hash:
            return parse_recovery_key(candidate, repository), candidate
    return None, None


def _authenticate_plaintext(
    restic: Path,
    repository: Path,
    value: str,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]],
) -> tuple[str, int, list[dict[str, Any]], str]:
    environment = os.environ.copy()
    environment["RESTIC_PASSWORD"] = value
    try:
        repository_id, repository_format = authenticate(
            restic, repository, [], environment=environment, runner=runner
        )
        keys, current_key = _key_list(
            restic,
            repository,
            [],
            runner=runner,
            environment=environment,
        )
        return repository_id, repository_format, keys, current_key
    finally:
        environment.pop("RESTIC_PASSWORD", None)


def _append_history(state: Path, record: dict[str, Any]) -> None:
    path = state / HISTORY_NAME
    rows: list[Any] = []
    if path.exists():
        document = _read_json(path)
        if not isinstance(document, dict) or document.get("schema_version") != 1:
            raise RuntimeError("Credential-rotation history is invalid.")
        existing = document.get("rotations")
        if not isinstance(existing, list):
            raise RuntimeError("Credential-rotation history rows are invalid.")
        rows = existing[-(MAX_HISTORY - 1) :]
    rows.append(record)
    _write_protected_json(
        path,
        {"schema_version": 1, "updated_utc": utc_now(), "rotations": rows},
    )


def _finish_rotation(
    config: dict[str, Any],
    config_path: Path,
    journal_path: Path,
    journal: dict[str, Any],
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]],
    acl_verifier: Callable[[Path], None],
) -> dict[str, Any]:
    paths = _validate_journal(journal, config, config_path)
    repository = Path(config["repository"])
    restic = Path(config["restic_executable"])
    state = Path(config["state_directory"])
    secret = Path(config["secret_file"])
    new_password, new_source = _password_from_hashed_recovery(
        [paths["pending"], paths["recovery"]],
        journal["new_recovery_sha256"],
        repository,
    )
    if new_password is None:
        raise RuntimeError("The pending new recovery credential is missing or changed.")
    old_password, old_source = _password_from_hashed_recovery(
        [paths["previous"], paths["recovery"]],
        journal["old_recovery_sha256"],
        repository,
    )
    if old_password is None:
        raise RuntimeError("The known-good previous recovery credential is missing or changed.")

    try:
        repository_id, repository_format, keys, new_key_id = _authenticate_plaintext(
            restic, repository, new_password, runner=runner
        )
    except Exception:
        active_password = load_secret(secret)
        if not secrets.compare_digest(active_password, old_password):
            raise RuntimeError("The interrupted rotation cannot safely restore the prior credential.")
        if old_source == paths["previous"] and not paths["recovery"].exists():
            os.replace(paths["previous"], paths["recovery"])
            acl_verifier(paths["recovery"])
        paths["pending"].unlink(missing_ok=True)
        journal_path.unlink(missing_ok=True)
        return {
            "schema": SCHEMA,
            "schema_version": 1,
            "state": "rolled_back_before_repository_key",
            "finished_utc": utc_now(),
            "plan_id": config["plan_id"],
            "config_generation": config["config_generation"],
            "repository_modified": False,
            "active_credential_modified": False,
            "previous_repository_key_retained": True,
        }

    expected_repository_id = journal.get("repository_id")
    if expected_repository_id is not None and repository_id != expected_repository_id:
        raise RuntimeError("The pending new key authenticates another repository.")
    recorded_new_key = journal.get("new_key_id")
    if recorded_new_key is not None and new_key_id != recorded_new_key:
        raise RuntimeError("The pending new key identity changed during recovery.")
    if not any(row["id"] == new_key_id for row in keys):
        raise RuntimeError("The authenticated new key is absent from Restic's key list.")

    if not secrets.compare_digest(load_secret(secret), new_password):
        replace_secret(secret, new_password)
    journal["phase"] = "active_switched"
    journal["new_key_id"] = new_key_id
    journal["repository_id"] = repository_id
    _write_protected_json(journal_path, journal)

    if paths["previous"].exists():
        acl_verifier(paths["previous"])
        if sha256_file(paths["previous"]) != journal["old_recovery_sha256"]:
            raise RuntimeError("The preserved prior recovery key changed during rotation.")
    elif paths["recovery"].exists() and sha256_file(paths["recovery"]) == journal["old_recovery_sha256"]:
        os.replace(paths["recovery"], paths["previous"])
        acl_verifier(paths["previous"])
    else:
        raise RuntimeError("The prior recovery key cannot be preserved before publication.")
    journal["phase"] = "old_recovery_preserved"
    _write_protected_json(journal_path, journal)

    if not paths["recovery"].exists() or sha256_file(paths["recovery"]) != journal["new_recovery_sha256"]:
        if not paths["pending"].exists() or sha256_file(paths["pending"]) != journal["new_recovery_sha256"]:
            raise RuntimeError("The staged new recovery key is unavailable for publication.")
        os.replace(paths["pending"], paths["recovery"])
    acl_verifier(paths["recovery"])
    if not secrets.compare_digest(parse_recovery_key(paths["recovery"], repository), new_password):
        raise RuntimeError("The published recovery key did not round-trip.")
    journal["phase"] = "published"
    _write_protected_json(journal_path, journal)

    active_id, active_format = authenticate(
        restic,
        repository,
        ["--password-command", password_command(config, config_path.parent)],
        runner=runner,
    )
    recovery_id, recovery_format, final_keys, final_current_key = _authenticate_plaintext(
        restic, repository, new_password, runner=runner
    )
    if (
        active_id != repository_id
        or recovery_id != repository_id
        or active_format != repository_format
        or recovery_format != repository_format
        or final_current_key != new_key_id
    ):
        raise RuntimeError("Post-rotation credentials did not independently bind the same repository.")
    old_key_id = str(journal["old_key_id"])
    if not any(row["id"] == old_key_id for row in final_keys):
        raise RuntimeError("The previous repository key was not retained for rollback.")

    result = {
        "schema": SCHEMA,
        "schema_version": 1,
        "rotation_id": journal["rotation_id"],
        "state": "rotated",
        "finished_utc": utc_now(),
        "plan_id": config["plan_id"],
        "config_generation": config["config_generation"],
        "repository_id": repository_id,
        "repository_format": repository_format,
        "previous_key_id": old_key_id,
        "new_key_id": new_key_id,
        "repository_key_count": len(final_keys),
        "previous_recovery_file": str(paths["previous"]),
        "active_credential_verified": True,
        "recovery_key_verified": True,
        "previous_repository_key_retained": True,
        "snapshots_modified": False,
        "repository_data_modified": False,
    }
    _append_history(state, result)
    _write_protected_json(state / LATEST_NAME, result)
    journal_path.unlink()
    new_password = ""
    old_password = ""
    return result


def rotate(
    config_path: Path,
    *,
    expected_config_sha256: str,
    expected_plan_id: str,
    expected_generation: int,
    expected_user_sid: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    acl_verifier: Callable[[Path], None] = verify_restricted_acl,
    sid_reader: Callable[[], str] = _current_user_sid,
    require_manifest: bool = True,
) -> dict[str, Any]:
    config_path = config_path.resolve(strict=True)
    if not re.fullmatch(r"[0-9a-f]{64}", expected_config_sha256):
        raise RuntimeError("The expected configuration hash is invalid.")
    if sha256_file(config_path) != expected_config_sha256:
        raise RuntimeError("The protected configuration changed before key rotation.")
    if sid_reader().casefold() != expected_user_sid.casefold():
        raise RuntimeError("Key rotation must be approved by the requesting Windows account.")
    if require_manifest:
        validate_runtime_manifest(config_path.parent)
        manifest = json.loads(
            (config_path.parent / "runtime-manifest.json").read_text(encoding="utf-8-sig")
        )
        names = {
            str(row.get("relative_path", "")).replace("/", "\\").casefold()
            for row in manifest.get("files", [])
            if isinstance(row, dict)
        }
        if "key_rotation.py" not in names:
            raise RuntimeError("The protected runtime manifest does not authorize key rotation.")

    config, run_lock = load_config_under_lock(
        config_path,
        allowed_pending_journals=frozenset({JOURNAL_NAME}),
    )
    temporary_password: Path | None = None
    new_password = ""
    old_password = ""
    try:
        if sha256_file(config_path) != expected_config_sha256:
            raise RuntimeError("The protected configuration changed while waiting for key rotation.")
        if config["plan_id"] != expected_plan_id or config["config_generation"] != expected_generation:
            raise RuntimeError("The key-rotation request names another backup plan generation.")
        state = Path(config["state_directory"])
        journal_path = state / JOURNAL_NAME
        if journal_path.exists() or journal_path.is_symlink():
            journal = _read_json(journal_path)
            if not isinstance(journal, dict):
                raise RuntimeError("The pending credential-rotation journal is invalid.")
            return _finish_rotation(
                config,
                config_path,
                journal_path,
                journal,
                runner=runner,
                acl_verifier=acl_verifier,
            )

        repository = Path(config["repository"])
        restic = Path(config["restic_executable"])
        recovery = Path(config["recovery_key_file"])
        secret = Path(config["secret_file"])
        acl_verifier(recovery)
        old_password = load_secret(secret)
        recovery_password = parse_recovery_key(recovery, repository)
        if not secrets.compare_digest(old_password, recovery_password):
            raise RuntimeError("Active and recovery credentials differ; repair them before rotating keys.")
        active_id, active_format = authenticate(
            restic,
            repository,
            ["--password-command", password_command(config, config_path.parent)],
            runner=runner,
        )
        recovery_id, recovery_format, keys_before, old_key_id = _authenticate_plaintext(
            restic, repository, recovery_password, runner=runner
        )
        recovery_password = ""
        if active_id != recovery_id or active_format != recovery_format:
            raise RuntimeError("Active and recovery credentials do not bind the same repository.")

        rotation_id = utc_now().replace("-", "").replace(":", "").replace("+00:00", "Z") + "-" + secrets.token_hex(4)
        safe_stamp = re.sub(r"[^0-9TZ]", "", rotation_id.split("-")[0])
        pending = recovery.with_name(f".{recovery.name}.{rotation_id}.pending")
        previous = recovery.with_name(
            f"{recovery.stem}.previous-{safe_stamp}-{rotation_id[-8:]}{recovery.suffix}"
        )
        if pending.exists() or previous.exists():
            raise RuntimeError("A generated recovery-key rotation path already exists.")
        new_password = secrets.token_urlsafe(48)
        write_recovery_key(pending, repository, new_password)
        acl_verifier(pending)
        if not secrets.compare_digest(parse_recovery_key(pending, repository), new_password):
            raise RuntimeError("The staged recovery key did not round-trip.")

        journal = {
            "schema": SCHEMA,
            "schema_version": 1,
            "rotation_id": rotation_id,
            "phase": "prepared",
            "started_utc": utc_now(),
            "plan_id": config["plan_id"],
            "config_generation": config["config_generation"],
            "config_sha256": expected_config_sha256,
            "repository": str(repository),
            "repository_id": active_id,
            "repository_format": active_format,
            "old_key_id": old_key_id,
            "new_key_id": None,
            "old_recovery_sha256": sha256_file(recovery),
            "new_recovery_sha256": sha256_file(pending),
            "pending_recovery_file": str(pending),
            "previous_recovery_file": str(previous),
        }
        _write_protected_json(journal_path, journal)

        temporary_password = _temporary_password_file(state, rotation_id[-8:], new_password)
        add_command = [
            str(restic),
            "--repo",
            str(repository),
            "--password-command",
            password_command(config, config_path.parent),
            "--cache-dir",
            str(state / "cache"),
            "--retry-lock",
            "5m",
            "key",
            "add",
            "--new-password-file",
            str(temporary_password),
            "--user",
            "ResticBackuper rotation",
            "--host",
            str(config["hostname"]),
        ]
        add_result = _restic_result(runner, add_command, timeout=360)
        if add_result.returncode != 0:
            raise RuntimeError(f"Restic could not add and verify the new key (exit {add_result.returncode}).")
        _remove_temporary_password(temporary_password)
        temporary_password = None

        new_repository_id, new_format, keys_after, new_key_id = _authenticate_plaintext(
            restic, repository, new_password, runner=runner
        )
        if (
            new_repository_id != active_id
            or new_format != active_format
            or new_key_id == old_key_id
            or len(keys_after) < len(keys_before) + 1
        ):
            raise RuntimeError("The newly added Restic key did not pass identity checks.")
        journal["phase"] = "repository_key_added"
        journal["new_key_id"] = new_key_id
        _write_protected_json(journal_path, journal)
        return _finish_rotation(
            config,
            config_path,
            journal_path,
            journal,
            runner=runner,
            acl_verifier=acl_verifier,
        )
    finally:
        _remove_temporary_password(temporary_password)
        new_password = ""
        old_password = ""
        run_lock.__exit__(None, None, None)


def sanitize(message: str) -> str:
    value = (message or "Key rotation failed.").strip()
    if any(token in value.casefold() for token in ("password", "dpapi", "restic_")):
        return "Key rotation stopped without exposing credential details; run it again to recover the protected journal."
    return value[:1000]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not is_administrator():
        print(json.dumps({"schema": SCHEMA, "schema_version": 1, "state": "failed", "error": "Key rotation requires Windows approval."}))
        return 2
    try:
        result = rotate(
            args.config,
            expected_config_sha256=args.expected_config_sha256,
            expected_plan_id=args.expected_plan_id,
            expected_generation=args.expected_generation,
            expected_user_sid=args.expected_user_sid,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("state") == "rotated" else 3
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
