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
    probe_repository_access,
    repository_access,
    repository_storage_mode,
    restic_base,
    run_capture,
    utc_now,
    validate_repository_storage_readiness,
    validate_repository_volume,
)
from secret_store import create_secret, load_secret, secure_directory, write_recovery_key


# Exit codes. 0 is success and 1 any other failure (the __main__ wrapper maps every exception to it). The others tell the
# installer why it must stop without touching the backups, so it can say so in plain words.
EXIT_NEEDS_PASSWORD = 4  # no password was chosen, but the backups in this location need one
EXIT_HAS_NO_PASSWORD = 5  # a password was chosen, but the backups in this location have none
# Either choice: the backups in this location could not be opened to tell how they open, or, when a password was chosen and
# none saved on this PC opens them, they could not be opened at all (Restic can't tell, or the folder of keys holds no key).
EXIT_ACCESS_UNREADABLE = 6
# A password was chosen and the backups need one, but this PC has no saved password that opens them (made on another PC, or
# the saved password is gone). The password is never made again: it would not open these backups.
EXIT_PASSWORD_UNAVAILABLE = 7
# --detect-access answers with these (and EXIT_ACCESS_UNREADABLE for "can't tell"); it writes nothing.
EXIT_DETECT_NO_PASSWORD = 20
EXIT_DETECT_PASSWORD = 21
EXIT_DETECT_NONE = 22
DETECT_EXIT_CODES = {
    "no_password": EXIT_DETECT_NO_PASSWORD,
    "password": EXIT_DETECT_PASSWORD,
    "missing": EXIT_DETECT_NONE,
}
# Restic's exit code for "wrong password or no key found" (also what a password backup answers to --insecure-no-password).
RESTIC_EXIT_WRONG_PASSWORD = 12
# One plain line each on stderr, with none of Restic's text.
MISMATCH_MESSAGE = "The backups in this location don't match the choice made in Setup."
UNREADABLE_MESSAGE = "Setup couldn't open the backups in this location."
UNAVAILABLE_MESSAGE = "This PC has nothing saved that opens the backups in this location."
REFUSAL_MESSAGES = {EXIT_ACCESS_UNREADABLE: UNREADABLE_MESSAGE, EXIT_PASSWORD_UNAVAILABLE: UNAVAILABLE_MESSAGE}
NO_PASSWORD_NOTE = (
    "These backups have no password: anyone who can read the backup folder can restore them."
)
PASSWORD_NOTE = "The repository password is intentionally not stored in this bundle."


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    # None means "not given": --detect-access refuses an explicit --config, and everything else falls back to the default.
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument(
        "--commit-recovery-key",
        action="store_true",
        help="once the installation has succeeded: make a kept recovery key name this repository",
    )
    parser.add_argument(
        "--detect-access",
        action="store_true",
        help="tell whether the backups in --repository open without a password (exit 20), need one (21) or are not there (22)",
    )
    parser.add_argument("--repository", type=Path, help="with --detect-access: the backup location to look at")
    parser.add_argument("--restic", type=Path, help="with --detect-access: the Restic program to look with")
    args = parser.parse_args(argv)
    if args.detect_access:
        if args.config is not None or args.commit_recovery_key:
            parser.error("--detect-access cannot be combined with --config or --commit-recovery-key")
        if args.repository is None or args.restic is None:
            parser.error("--detect-access needs --repository and --restic")
    else:
        if args.repository is not None or args.restic is not None:
            parser.error("--repository and --restic are only for --detect-access")
        if args.config is None:
            args.config = DEFAULT_CONFIG
    return args


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
    access = repository_access(config)
    manifest = {
        "schema_version": 1,
        "created_utc": utc_now(),
        "repository": config["repository"],
        "repository_storage_mode": repository_storage_mode(config),
        "repository_access": access,
        "files": manifest_files,
        "note": NO_PASSWORD_NOTE if access == "no_password" else PASSWORD_NOTE,
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


def detect_access(restic_executable: Path, repository: Path) -> int:
    """--detect-access: how the backups at `repository` open, as an exit code. Reads only Restic's answer, writes nothing."""
    answer = probe_repository_access(restic_executable, repository)
    code = DETECT_EXIT_CODES.get(answer, EXIT_ACCESS_UNREADABLE)
    if code == EXIT_ACCESS_UNREADABLE:
        print(UNREADABLE_MESSAGE, file=sys.stderr)
    return code


def refuse(code: int) -> int:
    """Stop with one of the exit codes that mean "these backups are not what was chosen"; the message is one plain line."""
    print(REFUSAL_MESSAGES.get(code, MISMATCH_MESSAGE), file=sys.stderr)
    return code


def keys_folder_has_files(repository: Path) -> bool:
    """Whether the backups' folder of keys holds at least one key file. A missing, empty or unreadable folder does not.

    Restic answers "wrong password or no key found" (exit 12) for backups that hold no key at all, the same as for backups
    with a password that was not given, so the answer alone does not tell a password from a folder that was damaged or has
    not finished downloading from Google Drive.
    """
    try:
        return any(entry.is_file() for entry in (repository / "keys").iterdir())
    except OSError:
        return False


def refuse_unopened_password_backups(repository: Path) -> int:
    """A password was chosen and the backups were not opened with the saved password (or there is none): 7 when they hold
    keys, so a password exists that this PC does not have, and 6 when they hold none and so can't be opened at all."""
    return refuse(EXIT_PASSWORD_UNAVAILABLE if keys_folder_has_files(repository) else EXIT_ACCESS_UNREADABLE)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.detect_access:
        return detect_access(args.restic, args.repository)
    config = load_config(args.config, require_repository=False)
    repository = Path(config["repository"])
    state = Path(config["state_directory"])
    secret_file = Path(config["secret_file"])
    recovery_file = Path(config["recovery_key_file"])
    storage_mode = repository_storage_mode(config)
    access = repository_access(config)
    with_password = access == "password"

    if args.commit_recovery_key:
        if not with_password:
            # No key was ever made for these backups: an older install's key file (if any) is left exactly as it is.
            print(json.dumps({"recovery_key_file": None, "recovery_key": "none"}))
            return 0
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
        if with_password and config_file.is_file() and not secret_file.is_file():
            # No saved password, and a new one would not open these backups, so none is made. Only Restic can say which kind
            # of backups these are: without a password (5), with one this PC doesn't have (7), or not to be opened at all (6).
            answer = probe_repository_access(config["restic_executable"], repository)
            if answer == "no_password":
                return refuse(EXIT_HAS_NO_PASSWORD)
            if answer == "password":
                return refuse_unopened_password_backups(repository)
            return refuse(EXIT_ACCESS_UNREADABLE)

        password: str | None = None
        secret_created = False
        if with_password and not secret_file.is_file():
            password = create_secret(secret_file)
            secret_created = True

        if config_file.is_file():
            cat_result = run_capture(restic_base(config) + ["cat", "config"])
            if cat_result.returncode != 0:
                if not with_password:
                    # Exit 12: the backups ask for a password. Anything else: they could not be opened to tell.
                    return refuse(
                        EXIT_NEEDS_PASSWORD
                        if cat_result.returncode == RESTIC_EXIT_WRONG_PASSWORD
                        else EXIT_ACCESS_UNREADABLE
                    )
                if probe_repository_access(config["restic_executable"], repository) == "no_password":
                    return refuse(EXIT_HAS_NO_PASSWORD)
                if cat_result.returncode == RESTIC_EXIT_WRONG_PASSWORD:
                    # The saved password does not open them, and neither does an empty one: a password this PC doesn't have.
                    return refuse_unopened_password_backups(repository)
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
                # Restic's init text (it always warns about "knowledge of your password") is never shown for backups without one.
                detail = f": {result.stderr.strip() or result.stdout.strip()}" if with_password else ""
                raise RuntimeError(f"restic init failed with exit {result.returncode}{detail}")
            cat_result = run_capture(restic_base(config) + ["cat", "config"])
            if cat_result.returncode != 0:
                detail = f": {cat_result.stderr.strip()}" if with_password else ""
                raise RuntimeError(f"repository authentication failed after init{detail}")
            repository_config = json.loads(cat_result.stdout)
        if storage_mode == "google_drivefs_stream":
            validate_repository_storage_readiness(
                config,
                volume_validated=True,
            )

        # Backups without a password have no DPAPI secret and no recovery key: neither is read, written or reported, and a
        # file an older install left at either path is not looked at.
        recovery_state: str | None = None
        if with_password:
            if password is None:
                password = load_secret(secret_file)
            recovery_state = reconcile_recovery_key(recovery_file, repository, password)
            del password
        recovery_created = recovery_state == "created"

        recovery_tools = install_recovery_tools(config, args.config)

        state_record = {
            "schema_version": 1,
            "initialized_utc": utc_now(),
            "repository": str(repository),
            "repository_id": repository_config.get("id"),
            "repository_version": repository_config.get("version"),
            "repository_volume_serial": config["repository_volume_serial"],
            "repository_storage_mode": storage_mode,
            "repository_access": access,
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
                "repository_access": access,
                "secret_file": str(secret_file) if with_password else None,
                "recovery_key_file": str(recovery_file) if with_password else None,
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
