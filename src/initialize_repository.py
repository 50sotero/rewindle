"""Initialize the pinned local Restic repository without exposing its password."""

from __future__ import annotations

import argparse
import hashlib
import json
import ntpath
from pathlib import Path
import re
import secrets
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from restic_common import (
    DEFAULT_CONFIG,
    RunLock,
    atomic_write_json,
    canonical_windows_path,
    ensure_free_space,
    load_config,
    repository_storage_mode,
    restic_base,
    run_capture,
    utc_now,
    validate_repository_storage_readiness,
    validate_repository_volume,
)
from secret_store import create_secret, load_secret, secure_directory, write_recovery_key


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument(
        "--commit-recovery-key",
        action="store_true",
        help="once the installation has succeeded: make a kept recovery key name this repository",
    )
    return parser.parse_args(argv)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def install_recovery_tools(config: dict, config_path: Path) -> dict:
    project = Path(__file__).resolve().parent
    destination = Path(config["recovery_tools_directory"])
    expected_names = {
        "restic.exe",
        "restore.py",
        "secret_store.py",
        "backup-config.json",
        "RECOVERY.md",
        "restic-release.json",
        "recovery-manifest.json",
    }
    if destination.exists():
        entries = {item.name for item in destination.iterdir()}
        if entries:
            manifest_path = destination / "recovery-manifest.json"
            if not manifest_path.is_file():
                raise RuntimeError(
                    f"refusing to overwrite unowned recovery-tools directory: {destination}"
                )
            old_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            if old_manifest.get("repository") != config["repository"]:
                raise RuntimeError("existing recovery-tools manifest names another repository")
            unexpected = sorted(entries - expected_names)
            if unexpected:
                raise RuntimeError(
                    "recovery-tools directory has unexpected entries: "
                    + ", ".join(unexpected)
                )
    else:
        destination.mkdir(parents=True)
    secure_directory(destination)
    sources = {
        "restic.exe": Path(config["restic_executable"]),
        "restore.py": project / "restore.py",
        "secret_store.py": project / "secret_store.py",
        "backup-config.json": config_path.resolve(strict=True),
        "RECOVERY.md": project / "RECOVERY.md",
        "restic-release.json": project / "restic-release.json",
    }
    manifest_files = []
    for name, source in sources.items():
        if not source.is_file():
            raise FileNotFoundError(f"recovery-tool source is missing: {source}")
        target = destination / name
        shutil.copy2(source, target)
        manifest_files.append(
            {"name": name, "bytes": target.stat().st_size, "sha256": sha256_file(target)}
        )
    manifest = {
        "schema_version": 1,
        "created_utc": utc_now(),
        "repository": config["repository"],
        "repository_storage_mode": repository_storage_mode(config),
        "files": manifest_files,
        "note": "The repository password is intentionally not stored in this bundle.",
    }
    if manifest["repository_storage_mode"] == "google_drivefs_stream":
        manifest["drivefs_my_drive_root"] = config["drivefs_my_drive_root"]
        manifest["drivefs_cache_directory"] = config["drivefs_cache_directory"]
    atomic_write_json(destination / "recovery-manifest.json", manifest)
    return manifest


def recovery_password(path: Path) -> str:
    text = path.read_text(encoding="utf-8-sig")
    matches = re.findall(r"^Password:\s*(\S+)\s*$", text, flags=re.MULTILINE)
    if len(matches) != 1 or len(matches[0]) < 40:
        raise ValueError(f"existing recovery key has an invalid format: {path}")
    return matches[0]


def recovery_repository(path: Path) -> str | None:
    """The repository a recovery key names, or None when it doesn't name exactly one."""
    text = path.read_text(encoding="utf-8-sig")
    matches = re.findall(r"^Repository:\s*(.+?)\s*$", text, flags=re.MULTILINE)
    return matches[0] if len(matches) == 1 else None


def same_repository(left: str | Path, right: str | Path) -> bool:
    """The comparison the recovery check makes (recovery_health.parse_recovery_key)."""
    try:
        return ntpath.normcase(canonical_windows_path(left)) == ntpath.normcase(
            canonical_windows_path(right)
        )
    except (OSError, ValueError):
        return False


def reconcile_recovery_key(
    recovery_file: Path, repository: Path, password: str, *, rewrite: bool = False
) -> str:
    """Writes the recovery key, or checks the one already there.

    Returns "created", "current", or, for a key that holds this password (checked here) but names another repository, as one
    an uninstall kept does after a reinstall chose another location: "stale", or with `rewrite` "rewritten" (it then names
    this repository; the password, which opens both, is unchanged). The recovery check and a restore from the key go by that
    line. The installer asks for the rewrite only once the installation has succeeded (--commit-recovery-key), so a reinstall
    that fails and is rolled back leaves the key naming the backups it was made for.
    """
    if not recovery_file.exists():
        if rewrite:
            raise RuntimeError("the recovery key is missing")
        write_recovery_key(recovery_file, repository, password)
        return "created"
    if not secrets.compare_digest(recovery_password(recovery_file), password):
        raise RuntimeError(
            "existing recovery key does not match the DPAPI repository password"
        )
    named = recovery_repository(recovery_file)
    if named is not None and same_repository(named, repository):
        return "current"
    if not rewrite:
        return "stale"
    write_recovery_key(recovery_file, repository, password, replace=True)
    return "rewritten"


def commit_recovery_key(recovery_file: Path, repository: Path, secret_file: Path) -> int:
    password = load_secret(secret_file)
    state = reconcile_recovery_key(recovery_file, repository, password, rewrite=True)
    del password
    print(json.dumps({"recovery_key_file": str(recovery_file), "recovery_key": state}))
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    config = load_config(args.config, require_repository=False)
    repository = Path(config["repository"])
    state = Path(config["state_directory"])
    secret_file = Path(config["secret_file"])
    recovery_file = Path(config["recovery_key_file"])
    storage_mode = repository_storage_mode(config)

    if args.commit_recovery_key:
        with RunLock(state / "run.lock"):
            return commit_recovery_key(recovery_file, repository, secret_file)

    secure_directory(state)
    with RunLock(state / "run.lock"):
        validate_repository_volume(config)
        ensure_free_space(config)

        repository.mkdir(parents=True, exist_ok=True)
        config_file = repository / "config"
        existing_entries = list(repository.iterdir())
        if existing_entries and not config_file.is_file():
            raise RuntimeError(
                f"refusing to initialize nonempty non-Restic directory: {repository}"
            )
        if config_file.is_file() and not secret_file.is_file():
            raise RuntimeError(
                "repository exists but its DPAPI password file is missing; "
                "refusing to create an unrelated key"
            )

        password: str | None = None
        secret_created = False
        if not secret_file.is_file():
            password = create_secret(secret_file)
            secret_created = True

        if config_file.is_file():
            cat_result = run_capture(restic_base(config) + ["cat", "config"])
            if cat_result.returncode != 0:
                raise RuntimeError(
                    f"repository authentication failed with exit {cat_result.returncode}: "
                    f"{cat_result.stderr.strip() or cat_result.stdout.strip()}"
                )
            repository_config = json.loads(cat_result.stdout)
            if storage_mode == "local_ntfs":
                secure_directory(repository)
        else:
            if storage_mode == "local_ntfs":
                secure_directory(repository)
            result = run_capture(
                restic_base(config) + ["init", "--repository-version", "2"]
            )
            if result.returncode != 0:
                raise RuntimeError(
                    f"restic init failed with exit {result.returncode}: "
                    f"{result.stderr.strip() or result.stdout.strip()}"
                )
            cat_result = run_capture(restic_base(config) + ["cat", "config"])
            if cat_result.returncode != 0:
                raise RuntimeError(
                    f"repository authentication failed after init: {cat_result.stderr.strip()}"
                )
            repository_config = json.loads(cat_result.stdout)
        if storage_mode == "google_drivefs_stream":
            validate_repository_storage_readiness(
                config,
                volume_validated=True,
            )

        if password is None:
            password = load_secret(secret_file)
        recovery_state = reconcile_recovery_key(recovery_file, repository, password)
        recovery_created = recovery_state == "created"
        del password

        recovery_tools = install_recovery_tools(config, args.config)

        state_record = {
            "schema_version": 1,
            "initialized_utc": utc_now(),
            "repository": str(repository),
            "repository_id": repository_config.get("id"),
            "repository_version": repository_config.get("version"),
            "repository_volume_serial": config["repository_volume_serial"],
            "repository_storage_mode": storage_mode,
            "secret_created": secret_created,
            "recovery_key_created": recovery_created,
            "recovery_key_names_other_repository": recovery_state == "stale",
            "recovery_tools_directory": config["recovery_tools_directory"],
            "recovery_tools_manifest": recovery_tools,
        }
        if storage_mode == "google_drivefs_stream":
            state_record["drivefs_my_drive_root"] = config["drivefs_my_drive_root"]
            state_record["drivefs_cache_directory"] = config[
                "drivefs_cache_directory"
            ]
        atomic_write_json(state / "repository.json", state_record)

    print(
        json.dumps(
            {
                "repository": str(repository),
                "repository_id": repository_config.get("id"),
                "repository_version": repository_config.get("version"),
                "repository_storage_mode": storage_mode,
                "secret_file": str(secret_file),
                "recovery_key_file": str(recovery_file),
                "secret_created": secret_created,
                "recovery_key_created": recovery_created,
                "recovery_key_names_other_repository": recovery_state == "stale",
                "recovery_tools_directory": config["recovery_tools_directory"],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"INITIALIZATION FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
