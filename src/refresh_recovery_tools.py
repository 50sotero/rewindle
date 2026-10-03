"""Transactionally refresh the standalone recovery bundle.

The protected configuration is authoritative for backup-plan identity, source
selection, topology, and policy.  Recovery-local executable and credential
paths are deliberately preserved so a portable bundle can retain its own
launch environment.  Optional recovery payload updates are hash-bound into the
manifest.  Restic is never invoked by this module.

A small adjacent rollback journal is written before any bundle file changes.
If the process is interrupted, the next invocation restores the last complete
bundle before attempting another refresh.
"""

from __future__ import annotations

import argparse
import base64
import copy
from datetime import datetime, timezone
import hashlib
import json
import ntpath
import os
from pathlib import Path
import re
import secrets
from typing import Any, Mapping
import uuid


PAYLOAD_NAMES = (
    "restic.exe",
    "restore.py",
    "secret_store.py",
    "backup-config.json",
    "RECOVERY.md",
    "restic-release.json",
)
MANIFEST_NAME = "recovery-manifest.json"
EXPECTED_ENTRIES = frozenset((*PAYLOAD_NAMES, MANIFEST_NAME))
UPDATABLE_PAYLOADS = frozenset(
    {"restore.py", "secret_store.py", "RECOVERY.md", "restic-release.json"}
)
RECOVERY_LOCAL_FIELDS = frozenset(
    {
        "restic_executable",
        "python_executable",
        "state_directory",
        "secret_file",
        "recovery_key_file",
        "exclude_file",
        "canary_file",
        "recovery_tools_directory",
    }
)
MAX_CONFIG_GENERATION = 2**63 - 1
MAX_REPLACEMENT_BYTES = 16 * 1024 * 1024
JOURNAL_SCHEMA = "ResticBackuper.RecoveryRefreshJournal.v1"
LOCAL_NTFS_MODE = "local_ntfs"
GOOGLE_DRIVEFS_MODE = "google_drivefs_stream"
STORAGE_MODES = frozenset({LOCAL_NTFS_MODE, GOOGLE_DRIVEFS_MODE})
EXPECTED_DRIVEFS_MY_DRIVE_ROOT = r"G:\My Drive"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source-config",
        type=Path,
        default=Path(r"C:\Program Files\ResticBackuper\backup-config.json"),
    )
    parser.add_argument(
        "--recovery-directory",
        type=Path,
        help="RecoveryTools directory; defaults to the path in --source-config",
    )
    parser.add_argument("--restore-source", type=Path)
    parser.add_argument("--secret-store-source", type=Path)
    parser.add_argument("--recovery-readme-source", type=Path)
    parser.add_argument("--release-source", type=Path)
    return parser.parse_args(argv)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_reparse(path: Path) -> bool:
    return path.is_symlink() or (
        hasattr(os.path, "isjunction") and os.path.isjunction(path)
    )


def require_normal_file(path: Path) -> None:
    if not path.is_file() or is_reparse(path):
        raise RuntimeError(f"expected a regular non-reparse file: {path}")


def load_json(path: Path) -> dict[str, Any]:
    require_normal_file(path)
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected a JSON object: {path}")
    return value


def json_bytes(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_staged(path: Path, data: bytes) -> Path:
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    )
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return temporary


def canonical_source(value: str) -> str:
    if value.startswith("\\\\") or not ntpath.isabs(value):
        raise RuntimeError(f"source is not an absolute local path: {value}")
    drive, _ = ntpath.splitdrive(value)
    if len(drive) != 2 or drive[1] != ":":
        raise RuntimeError(f"source is not a drive-letter path: {value}")
    return ntpath.normcase(ntpath.normpath(value))


def is_within(candidate: str, parent: str) -> bool:
    normalized_candidate = canonical_source(candidate)
    normalized_parent = canonical_source(parent)
    return normalized_candidate == normalized_parent or normalized_candidate.startswith(
        normalized_parent.rstrip("\\") + "\\"
    )


def validate_storage_config(config: dict[str, Any], label: str) -> dict[str, str | None]:
    repository = config.get("repository")
    if not isinstance(repository, str) or not repository.strip():
        raise RuntimeError(f"{label} repository path is invalid")
    canonical_repository = canonical_source(repository)
    serial = config.get("repository_volume_serial")
    if not isinstance(serial, str) or not re.fullmatch(r"[0-9A-Fa-f]{8}", serial):
        raise RuntimeError(f"{label} repository_volume_serial is invalid")
    role_paths = {"repository": canonical_repository}
    for name in ("state_directory", "recovery_tools_directory"):
        value = config.get(name)
        if not isinstance(value, str) or not value.strip():
            raise RuntimeError(f"{label} configuration is missing {name}")
        role_paths[name] = canonical_source(value)
    role_items = list(role_paths.items())
    for index, (name, path) in enumerate(role_items):
        for other_name, other_path in role_items[:index]:
            if is_within(path, other_path) or is_within(other_path, path):
                raise RuntimeError(
                    f"{label} protected roles overlap: {other_name} and {name}"
                )

    mode = config.get("repository_storage_mode", LOCAL_NTFS_MODE)
    if not isinstance(mode, str) or mode not in STORAGE_MODES:
        raise RuntimeError(f"{label} repository_storage_mode is invalid")
    repository_drive, _ = ntpath.splitdrive(canonical_repository)
    if repository_drive.casefold() == "g:" and mode != GOOGLE_DRIVEFS_MODE:
        raise RuntimeError(
            f"{label} repository on G: requires google_drivefs_stream"
        )

    root = config.get("drivefs_my_drive_root")
    legacy_root = config.get("repository_drivefs_root")
    cache = config.get("drivefs_cache_directory")
    if mode == LOCAL_NTFS_MODE:
        if root is not None or legacy_root is not None or cache is not None:
            raise RuntimeError(
                f"{label} local_ntfs configuration contains DriveFS bindings"
            )
        return {"mode": mode, "root": None, "cache": None}

    if root is None:
        root = legacy_root
    elif (
        legacy_root is not None
        and isinstance(root, str)
        and isinstance(legacy_root, str)
        and canonical_source(root) != canonical_source(legacy_root)
    ):
        raise RuntimeError(
            f"{label} drivefs_my_drive_root conflicts with its legacy alias"
        )
    if not isinstance(root, str) or not root.strip():
        raise RuntimeError(f"{label} drivefs_my_drive_root is invalid")
    if cache is None and legacy_root is not None:
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            cache = str(Path(local_app_data) / "Google" / "DriveFS")
    if not isinstance(cache, str) or not cache.strip():
        raise RuntimeError(f"{label} drivefs_cache_directory is invalid")
    canonical_root = canonical_source(root)
    canonical_cache = canonical_source(cache)
    if canonical_root != canonical_source(EXPECTED_DRIVEFS_MY_DRIVE_ROOT):
        raise RuntimeError(
            f"{label} DriveFS root must be {EXPECTED_DRIVEFS_MY_DRIVE_ROOT}"
        )
    if canonical_repository == canonical_root or not is_within(
        canonical_repository, canonical_root
    ):
        raise RuntimeError(
            f"{label} DriveFS repository must be strictly beneath My Drive"
        )
    if is_within(canonical_cache, canonical_root):
        raise RuntimeError(
            f"{label} drivefs_cache_directory must remain outside Google DriveFS"
        )
    for name in (
        "state_directory",
        "secret_file",
        "recovery_key_file",
        "recovery_tools_directory",
        "restic_executable",
        "python_executable",
        "exclude_file",
    ):
        value = config.get(name)
        if not isinstance(value, str) or not value.strip():
            raise RuntimeError(f"{label} configuration is missing {name}")
        if is_within(value, canonical_root):
            raise RuntimeError(f"{label} {name} must remain outside Google DriveFS")
    return {"mode": mode, "root": canonical_root, "cache": canonical_cache}


def validate_plan_config(config: dict[str, Any], label: str) -> list[str]:
    if config.get("schema_version") != 1:
        raise RuntimeError(f"{label} configuration schema is invalid")
    plan_id = config.get("plan_id")
    try:
        canonical_plan_id = str(uuid.UUID(plan_id)) if isinstance(plan_id, str) else ""
    except ValueError as error:
        raise RuntimeError(f"{label} plan_id is invalid") from error
    if plan_id != canonical_plan_id:
        raise RuntimeError(f"{label} plan_id is not a canonical lowercase UUID")
    generation = config.get("config_generation")
    if (
        isinstance(generation, bool)
        or not isinstance(generation, int)
        or generation <= 0
        or generation > MAX_CONFIG_GENERATION
    ):
        raise RuntimeError(f"{label} config_generation is invalid")
    if config.get("cloud_placeholder_policy") not in {"strict", "allow"}:
        raise RuntimeError(f"{label} cloud_placeholder_policy is invalid")
    validate_storage_config(config, label)

    sources = config.get("sources")
    if not isinstance(sources, list) or not sources or not all(
        isinstance(item, str) and bool(item.strip()) for item in sources
    ):
        raise RuntimeError(f"{label} configuration has an invalid sources list")
    normalized: list[str] = []
    for item in sources:
        canonical = canonical_source(item)
        if canonical in normalized:
            raise RuntimeError(f"{label} configuration contains a duplicate root: {item}")
        for existing in normalized:
            if canonical.startswith(existing.rstrip("\\") + "\\") or existing.startswith(
                canonical.rstrip("\\") + "\\"
            ):
                raise RuntimeError(f"{label} configuration contains nested roots")
        normalized.append(canonical)

    identities = config.get("source_identities")
    if not isinstance(identities, dict):
        raise RuntimeError(f"{label} source_identities is invalid")
    normalized_identities: dict[str, str] = {}
    for source, identity in identities.items():
        if not isinstance(source, str) or not isinstance(identity, dict):
            raise RuntimeError(f"{label} source_identities contains an invalid entry")
        canonical = canonical_source(source)
        serial = identity.get("expected_volume_serial")
        if canonical in normalized_identities or not isinstance(serial, str) or not re.fullmatch(
            r"[0-9A-Fa-f]{8}", serial
        ):
            raise RuntimeError(f"{label} source_identities contains an invalid entry")
        normalized_identities[canonical] = serial.upper()
    if set(normalized_identities) != set(normalized):
        raise RuntimeError(f"{label} source_identities does not exactly match sources")

    use_vss = config.get("use_vss")
    if not isinstance(use_vss, bool):
        raise RuntimeError(f"{label} configuration use_vss must be a Boolean")
    topology = config.get("topology_paths", {})
    if not isinstance(topology, dict) or any(
        not isinstance(key, str)
        or not key.strip()
        or not isinstance(value, str)
        or not value.strip()
        for key, value in topology.items()
    ):
        raise RuntimeError(f"{label} topology_paths is invalid")
    return list(sources)


def validate_config_pair(
    source: dict[str, Any], recovery: dict[str, Any]
) -> tuple[list[str], bool]:
    sources = validate_plan_config(source, "source")
    validate_plan_config(recovery, "recovery")
    source_storage = validate_storage_config(source, "source")
    recovery_storage = validate_storage_config(recovery, "recovery")
    if source.get("repository") != recovery.get("repository"):
        raise RuntimeError("source and recovery configurations name different repositories")
    if source.get("repository_volume_serial") != recovery.get(
        "repository_volume_serial"
    ):
        raise RuntimeError("source and recovery configurations name different volumes")
    if source["plan_id"] != recovery["plan_id"]:
        raise RuntimeError("source and recovery configurations name different backup plans")
    if source_storage != recovery_storage:
        raise RuntimeError(
            "source and recovery configurations have different repository storage bindings"
        )
    if source["config_generation"] < recovery["config_generation"]:
        raise RuntimeError("source configuration would roll back the recovery generation")
    return sources, bool(source["use_vss"])


def merge_config(source: dict[str, Any], recovery: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(source)
    for name in RECOVERY_LOCAL_FIELDS:
        if name in recovery:
            merged[name] = copy.deepcopy(recovery[name])
    return merged


def validate_bundle(directory: Path) -> dict[str, Any]:
    if not directory.is_dir() or is_reparse(directory):
        raise RuntimeError(f"recovery directory is not a normal directory: {directory}")
    entries = {item.name for item in directory.iterdir()}
    if entries != EXPECTED_ENTRIES:
        missing = sorted(EXPECTED_ENTRIES - entries)
        unexpected = sorted(entries - EXPECTED_ENTRIES)
        raise RuntimeError(
            f"recovery entry mismatch; missing={missing}, unexpected={unexpected}"
        )
    for name in EXPECTED_ENTRIES:
        require_normal_file(directory / name)

    manifest = load_json(directory / MANIFEST_NAME)
    if manifest.get("schema_version") != 1:
        raise RuntimeError("recovery manifest schema is invalid")
    rows = manifest.get("files")
    if not isinstance(rows, list):
        raise RuntimeError("recovery manifest files list is invalid")
    names = [row.get("name") for row in rows if isinstance(row, dict)]
    if len(rows) != len(PAYLOAD_NAMES) or set(names) != set(PAYLOAD_NAMES):
        raise RuntimeError("recovery manifest payload set is invalid")
    if len(names) != len(set(names)):
        raise RuntimeError("recovery manifest contains duplicate payload names")
    for row in rows:
        name = row.get("name")
        digest = row.get("sha256")
        path = directory / name
        if (
            not isinstance(row.get("bytes"), int)
            or isinstance(row.get("bytes"), bool)
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or row["bytes"] != path.stat().st_size
            or digest != sha256_file(path)
        ):
            raise RuntimeError(f"recovery manifest mismatch: {name}")
    config = load_json(directory / "backup-config.json")
    if manifest.get("repository") != config.get("repository"):
        raise RuntimeError("recovery manifest and configuration repository mismatch")
    storage = validate_storage_config(config, "recovery")
    manifest_mode = manifest.get("repository_storage_mode")
    if manifest_mode is not None and manifest_mode != storage["mode"]:
        raise RuntimeError(
            "recovery manifest and configuration storage modes mismatch"
        )
    if storage["mode"] == GOOGLE_DRIVEFS_MODE:
        for name, expected in (
            ("drivefs_my_drive_root", config.get("drivefs_my_drive_root")),
            ("drivefs_cache_directory", config.get("drivefs_cache_directory")),
        ):
            actual = manifest.get(name)
            if actual is not None and (
                not isinstance(actual, str)
                or not isinstance(expected, str)
                or canonical_source(actual) != canonical_source(expected)
            ):
                raise RuntimeError(
                    f"recovery manifest and configuration {name} mismatch"
                )
    return {"manifest": manifest, "config": config}


def journal_path_for(directory: Path) -> Path:
    return directory.parent / f".{directory.name}.refresh-journal.json"


def write_journal(directory: Path, originals: Mapping[str, bytes]) -> Path:
    journal_path = journal_path_for(directory)
    if journal_path.exists():
        raise RuntimeError(f"recovery refresh journal already exists: {journal_path}")
    journal = {
        "schema": JOURNAL_SCHEMA,
        "schema_version": 1,
        "created_utc": utc_now(),
        "recovery_directory": str(directory.resolve()),
        "originals": [
            {
                "name": name,
                "bytes": len(data),
                "sha256": sha256_bytes(data),
                "base64": base64.b64encode(data).decode("ascii"),
            }
            for name, data in originals.items()
        ],
    }
    stage = write_staged(journal_path, json_bytes(journal))
    os.replace(stage, journal_path)
    return journal_path


def load_journal(directory: Path) -> dict[str, bytes]:
    journal_path = journal_path_for(directory)
    journal = load_json(journal_path)
    if (
        journal.get("schema") != JOURNAL_SCHEMA
        or journal.get("schema_version") != 1
        or journal.get("recovery_directory") != str(directory.resolve())
        or not isinstance(journal.get("originals"), list)
    ):
        raise RuntimeError("recovery refresh journal header is invalid")
    originals: dict[str, bytes] = {}
    allowed = {*UPDATABLE_PAYLOADS, "backup-config.json", MANIFEST_NAME}
    for row in journal["originals"]:
        if not isinstance(row, dict) or row.get("name") not in allowed:
            raise RuntimeError("recovery refresh journal contains an invalid target")
        name = row["name"]
        if name in originals:
            raise RuntimeError("recovery refresh journal contains duplicate targets")
        try:
            data = base64.b64decode(row.get("base64", ""), validate=True)
        except (ValueError, TypeError) as error:
            raise RuntimeError("recovery refresh journal contains invalid Base64") from error
        if (
            row.get("bytes") != len(data)
            or row.get("sha256") != sha256_bytes(data)
        ):
            raise RuntimeError("recovery refresh journal payload is not hash-bound")
        originals[name] = data
    if MANIFEST_NAME not in originals:
        raise RuntimeError("recovery refresh journal is missing the original manifest")
    return originals


def restore_originals(directory: Path, originals: Mapping[str, bytes]) -> None:
    for name, data in originals.items():
        target = directory / name
        stage = write_staged(target, data)
        os.replace(stage, target)


def recover_interrupted_refresh(directory: Path) -> bool:
    journal_path = journal_path_for(directory)
    if not journal_path.exists():
        return False
    originals = load_journal(directory)
    restore_originals(directory, originals)
    validate_bundle(directory)
    journal_path.unlink()
    return True


def read_payload_sources(payload_sources: Mapping[str, Path] | None) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    for name, source in (payload_sources or {}).items():
        if name not in UPDATABLE_PAYLOADS:
            raise RuntimeError(f"recovery payload is not independently updatable: {name}")
        path = Path(source)
        require_normal_file(path)
        size = path.stat().st_size
        if size <= 0 or size > MAX_REPLACEMENT_BYTES:
            raise RuntimeError(f"recovery payload size is outside the allowed range: {name}")
        result[name] = path.read_bytes()
    return result


def refresh(
    source_config: Path,
    recovery_directory: Path,
    payload_sources: Mapping[str, Path] | None = None,
) -> dict[str, Any]:
    recovery_directory = recovery_directory.resolve()
    recovered_interruption = recover_interrupted_refresh(recovery_directory)
    source = load_json(source_config)
    validated = validate_bundle(recovery_directory)
    existing = validated["config"]
    sources, use_vss = validate_config_pair(source, existing)
    merged = merge_config(source, existing)
    validate_plan_config(merged, "merged recovery")

    changed_fields = sorted(
        key
        for key in set(existing) | set(merged)
        if existing.get(key) != merged.get(key) or (key in existing) != (key in merged)
    )
    replacement_data = read_payload_sources(payload_sources)
    changed_payloads = sorted(
        name
        for name, data in replacement_data.items()
        if sha256_bytes(data) != sha256_file(recovery_directory / name)
    )
    if not changed_fields and not changed_payloads:
        return {
            "schema_version": 1,
            "state": "already_current",
            "recovered_interruption": recovered_interruption,
            "changed_fields": [],
            "changed_payloads": [],
            "source_count": len(sources),
            "use_vss": use_vss,
            "plan_id": merged["plan_id"],
            "config_generation": merged["config_generation"],
        }

    planned: dict[str, bytes] = {
        name: replacement_data[name] for name in changed_payloads
    }
    if changed_fields:
        planned["backup-config.json"] = json_bytes(merged)

    rows: list[dict[str, Any]] = []
    for name in PAYLOAD_NAMES:
        if name in planned:
            data = planned[name]
            size = len(data)
            digest = sha256_bytes(data)
        else:
            path = recovery_directory / name
            size = path.stat().st_size
            digest = sha256_file(path)
        rows.append({"name": name, "bytes": size, "sha256": digest})
    new_manifest = copy.deepcopy(validated["manifest"])
    new_manifest["created_utc"] = utc_now()
    new_manifest["repository"] = merged["repository"]
    storage = validate_storage_config(merged, "merged recovery")
    new_manifest["repository_storage_mode"] = storage["mode"]
    if storage["mode"] == GOOGLE_DRIVEFS_MODE:
        new_manifest["drivefs_my_drive_root"] = merged["drivefs_my_drive_root"]
        new_manifest["drivefs_cache_directory"] = merged[
            "drivefs_cache_directory"
        ]
    else:
        new_manifest.pop("drivefs_my_drive_root", None)
        new_manifest.pop("drivefs_cache_directory", None)
    new_manifest["files"] = rows
    new_manifest["last_update_reason"] = (
        "Protected plan configuration or recovery payload changed"
    )
    planned[MANIFEST_NAME] = json_bytes(new_manifest)

    originals = {
        name: (recovery_directory / name).read_bytes() for name in planned
    }
    journal_path = write_journal(recovery_directory, originals)
    staged: dict[str, Path] = {}
    try:
        for name, data in planned.items():
            staged[name] = write_staged(recovery_directory / name, data)
        for name in [item for item in planned if item != MANIFEST_NAME]:
            os.replace(staged[name], recovery_directory / name)
            del staged[name]
        os.replace(staged[MANIFEST_NAME], recovery_directory / MANIFEST_NAME)
        del staged[MANIFEST_NAME]

        final = validate_bundle(recovery_directory)
        validate_config_pair(source, final["config"])
        if final["config"] != merged:
            raise RuntimeError("published recovery configuration differs from staged data")
        for name in changed_payloads:
            if sha256_file(recovery_directory / name) != sha256_bytes(replacement_data[name]):
                raise RuntimeError(f"published recovery payload differs from staged data: {name}")
        journal_path.unlink()
        return {
            "schema_version": 1,
            "state": "refreshed",
            "recovered_interruption": recovered_interruption,
            "changed_fields": changed_fields,
            "changed_payloads": changed_payloads,
            "source_count": len(sources),
            "use_vss": use_vss,
            "plan_id": merged["plan_id"],
            "config_generation": merged["config_generation"],
            "config_bytes": (recovery_directory / "backup-config.json").stat().st_size,
            "config_sha256": sha256_file(recovery_directory / "backup-config.json"),
            "manifest_sha256": sha256_file(recovery_directory / MANIFEST_NAME),
        }
    except BaseException as error:
        rollback_errors: list[str] = []
        try:
            for stage in staged.values():
                stage.unlink(missing_ok=True)
            staged.clear()
            restore_originals(recovery_directory, originals)
            validate_bundle(recovery_directory)
            journal_path.unlink(missing_ok=True)
        except BaseException as rollback_error:
            rollback_errors.append(f"recovery rollback failed: {rollback_error}")
        if rollback_errors:
            raise RuntimeError(f"{error}; {'; '.join(rollback_errors)}") from error
        raise
    finally:
        for stage in staged.values():
            stage.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    recovery_directory = args.recovery_directory
    if recovery_directory is None:
        source_configuration = load_json(args.source_config)
        configured_directory = source_configuration.get("recovery_tools_directory")
        if not isinstance(configured_directory, str) or not configured_directory:
            raise RuntimeError(
                "source configuration does not name a recovery-tools directory"
            )
        recovery_directory = Path(configured_directory)
    payload_sources = {
        name: path
        for name, path in {
            "restore.py": args.restore_source,
            "secret_store.py": args.secret_store_source,
            "RECOVERY.md": args.recovery_readme_source,
            "restic-release.json": args.release_source,
        }.items()
        if path is not None
    }
    result = refresh(args.source_config, recovery_directory, payload_sources)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
