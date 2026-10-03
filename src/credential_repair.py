"""Repair the active CurrentUser DPAPI envelope from the recovery key.

The recovery key is authenticated against the configured repository before any
protected state is changed.  The only mutation is one atomic DPAPI-envelope
replacement; the repository, its keys, snapshots, and recovery key are never
modified by this workflow.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any, Callable

from recovery_health import authenticate, parse_recovery_key, password_command, utc_now
from restic_common import load_config_under_lock
from secret_store import (
    _current_user_sid,
    load_secret,
    replace_secret,
    verify_restricted_acl,
)


SCHEMA = "ResticBackuper.CredentialRepair.v1"
MAX_MANIFEST_BYTES = 4 * 1024 * 1024


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-config-sha256", required=True)
    parser.add_argument("--expected-plan-id", required=True)
    parser.add_argument("--expected-generation", type=int, required=True)
    parser.add_argument("--expected-user-sid", required=True)
    return parser.parse_args(argv)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normal_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and not (
        hasattr(os.path, "isjunction") and os.path.isjunction(path)
    )


def validate_runtime_manifest(install_root: Path) -> None:
    manifest_path = install_root / "runtime-manifest.json"
    if not normal_file(manifest_path) or manifest_path.stat().st_size > MAX_MANIFEST_BYTES:
        raise RuntimeError("The protected runtime manifest is missing or unsafe.")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise RuntimeError("The protected runtime manifest header is invalid.")
    rows = manifest.get("files")
    if not isinstance(rows, list) or manifest.get("file_count") != len(rows):
        raise RuntimeError("The protected runtime manifest count is invalid.")
    seen: set[str] = set()
    root = install_root.resolve(strict=True)
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("relative_path"), str):
            raise RuntimeError("The protected runtime manifest contains an invalid record.")
        relative = row["relative_path"].replace("/", "\\")
        normalized = relative.casefold()
        if (
            not relative
            or nt_is_absolute(relative)
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or normalized in seen
        ):
            raise RuntimeError("The protected runtime manifest contains an unsafe path.")
        seen.add(normalized)
        candidate = (root / Path(relative)).resolve(strict=True)
        try:
            candidate.relative_to(root)
        except ValueError as error:
            raise RuntimeError("The protected runtime manifest path escapes its root.") from error
        if not normal_file(candidate):
            raise RuntimeError("A protected runtime manifest file is missing or unsafe.")
        digest = row.get("sha256")
        size = row.get("bytes")
        if (
            isinstance(size, bool)
            or not isinstance(size, int)
            or size != candidate.stat().st_size
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or digest != sha256_file(candidate)
        ):
            raise RuntimeError("A protected runtime file does not match its manifest.")
    required = {
        "backup-config.json",
        "credential_repair.py",
        "key_rotation.py",
        "anomaly_review.py",
        "recovery_health.py",
        "restic_common.py",
        "secret_store.py",
        "restic.exe",
        "python\\python.exe",
    }
    if not {item.casefold() for item in required}.issubset(seen):
        raise RuntimeError("The protected runtime manifest is missing credential-repair files.")
    actual = {
        str(path.relative_to(root)).replace("/", "\\").casefold()
        for path in root.rglob("*")
        if path.is_file()
        and path.name
        not in {
            "runtime-manifest.json",
            "scheduled-task.xml",
            "google-drive-verification-task.xml",
        }
    }
    if actual != seen:
        raise RuntimeError("The protected runtime contains unmanifested or missing files.")


def nt_is_absolute(value: str) -> bool:
    return bool(re.match(r"^(?:[A-Za-z]:[\\/]|[\\/]{2})", value))


def is_administrator() -> bool:
    return os.name == "nt" and bool(ctypes.windll.shell32.IsUserAnAdmin())


def repair(
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
        raise RuntimeError("The protected configuration changed before credential repair.")
    if sid_reader().casefold() != expected_user_sid.casefold():
        raise RuntimeError("Credential repair must be approved by the requesting Windows account.")
    if require_manifest:
        validate_runtime_manifest(config_path.parent)

    config, run_lock = load_config_under_lock(config_path)
    try:
        if sha256_file(config_path) != expected_config_sha256:
            raise RuntimeError("The protected configuration changed while waiting for credential repair.")
        if config["plan_id"] != expected_plan_id or config["config_generation"] != expected_generation:
            raise RuntimeError("The credential-repair request names another backup plan generation.")
        repository = Path(config["repository"])
        restic = Path(config["restic_executable"])
        recovery_key = Path(config["recovery_key_file"])
        secret = Path(config["secret_file"])
        acl_verifier(recovery_key)
        recovery_password = parse_recovery_key(recovery_key, repository)
        environment = os.environ.copy()
        environment["RESTIC_PASSWORD"] = recovery_password
        try:
            repository_id, repository_format = authenticate(
                restic,
                repository,
                [],
                environment=environment,
                runner=runner,
            )
        finally:
            environment.pop("RESTIC_PASSWORD", None)

        active_matches = False
        try:
            active_matches = load_secret(secret) == recovery_password
            if active_matches:
                active_id, active_format = authenticate(
                    restic,
                    repository,
                    ["--password-command", password_command(config, config_path.parent)],
                    runner=runner,
                )
                active_matches = (
                    active_id == repository_id and active_format == repository_format
                )
        except Exception:
            active_matches = False

        if active_matches:
            state = "already_healthy"
            replaced = False
        else:
            replace_secret(secret, recovery_password)
            active_id, active_format = authenticate(
                restic,
                repository,
                ["--password-command", password_command(config, config_path.parent)],
                runner=runner,
            )
            if active_id != repository_id or active_format != repository_format:
                raise RuntimeError("The repaired active credential did not bind to the recovery repository.")
            state = "repaired"
            replaced = True
        recovery_password = ""
        return {
            "schema": SCHEMA,
            "schema_version": 1,
            "state": state,
            "finished_utc": utc_now(),
            "plan_id": config["plan_id"],
            "config_generation": config["config_generation"],
            "repository_id": repository_id,
            "repository_format": repository_format,
            "secret_replaced": replaced,
            "repository_modified": False,
            "recovery_key_modified": False,
        }
    finally:
        run_lock.__exit__(None, None, None)


def sanitize(message: str) -> str:
    value = (message or "Credential repair failed.").strip()
    if any(token in value.casefold() for token in ("password", "dpapi", "restic_")):
        return "Credential repair failed without exposing credential details."
    return value[:1000]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not is_administrator():
        print(json.dumps({"schema": SCHEMA, "schema_version": 1, "state": "failed", "error": "Credential repair requires Windows approval."}))
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
        return 0
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
