"""Safe recovery entrypoint that also works from the standalone D: bundle.

The historical command line remains supported::

    restore.py --list
    restore.py --snapshot latest --target D:\\Recovered

The dashboard-facing commands deliberately emit only JSON on stdout::

    restore.py --list-snapshots-json
    restore.py --list-tree-json --snapshot latest --tree-path C:\\Users

All restore selectors are resolved to one immutable snapshot ID before Restic is
allowed to write the alternate target.  This is especially important for
``latest``: it is bound to the configured host, scheduled tag, and complete set
of source roots rather than to whichever unrelated snapshot happens to be new.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import ntpath
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import threading
import time
import uuid
from typing import Any

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONFIG = SCRIPT_DIRECTORY / "backup-config.json"
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
REPORT_SCHEMA = "ResticBackuper.RestoreReport.v1"
LIST_SCHEMA = "ResticBackuper.SnapshotList.v1"
TREE_SCHEMA = "ResticBackuper.SnapshotTree.v1"
MAX_REPORT_BYTES = 64 * 1024
MAX_REPORT_INCLUDES = 64
MAX_REPORT_STRING = 1024
DRILL_MAX_FILES = 8
DRILL_MAX_FILE_BYTES = 8 * 1024 * 1024
DRILL_MAX_TOTAL_BYTES = 32 * 1024 * 1024
DRILL_MAX_LISTING_BYTES = 8 * 1024 * 1024
DRILL_MAX_LISTING_ENTRIES = 100_000
DRILL_MAX_DIAGNOSTIC_BYTES = 256 * 1024
DRILL_MAX_LISTING_CALLS = 128
DRILL_MAX_DIRECTORIES_PER_SOURCE = 24
DRIVE_FIXED = 3
DRIVE_REMOVABLE = 2
LOCAL_NTFS_MODE = "local_ntfs"
GOOGLE_DRIVEFS_MODE = "google_drivefs_stream"
REPOSITORY_STORAGE_MODES = frozenset({LOCAL_NTFS_MODE, GOOGLE_DRIVEFS_MODE})
# How Restic opens these backups (backup-config.json "repository_access"): the same values, default and message as
# restic_common, which this recovery entrypoint cannot import because it also runs from the standalone recovery folder.
# "password": the saved DPAPI password or the recovery key (a configuration written before the choice existed has no such
# key and means this). "no_password": --insecure-no-password and nothing else, so no password command, no recovery key and
# no prompt: Restic refuses the flag next to any password source, but only after it has run a password command.
REPOSITORY_ACCESS_VALUES = ("password", "no_password")
DEFAULT_REPOSITORY_ACCESS = "password"
NO_PASSWORD_FLAG = "--insecure-no-password"
PASSWORD_SOURCE_OPTIONS = ("--password-command", "--password-file", "--new-password-file")
PASSWORD_SOURCE_VARIABLES = ("RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND")
# These reach the person through the manager's own filter, which hides a message that names the password command, the
# variable or DPAPI: they name none of them.
NO_KEY_FILE_MESSAGE = "This backup opens without a key, so there is no key file to use."
NO_KEY_SOURCE_MESSAGE = "a restore command for backups without a key also names a key source"
DRILL_ARGUMENTS_MESSAGE = "--recovery-drill requires a target, report, and recovery-key file"
FILE_SEARCH_KEY_MESSAGE = "File search needs Rewindle's saved key or your recovery key."
# What a recovery drill's report says it was opened with: the recovery key (backups with a password) or nothing.
DRILL_CREDENTIAL_SOURCE_KEY = "recovery_key"
DRILL_CREDENTIAL_SOURCE_NONE = "none"
EXPECTED_DRIVEFS_MY_DRIVE_ROOT = r"G:\My Drive"
PLAN_TAG_PREFIX = "restic-backuper-plan:"
GENERATION_TAG_PREFIX = "restic-backuper-generation:"
SNAPSHOT_BINDING_PLAN = "plan"
SNAPSHOT_BINDING_LEGACY = "legacy_unbound"
SNAPSHOT_BINDING_CONFIGURATION = "configuration"
SYSTEM_FOLDER_REFUSAL = "restore target must not be inside a Windows or program folder"
# FOLDERID_Windows (first: its drive is the system drive below), FOLDERID_ProgramFiles, FOLDERID_ProgramFilesX86
# and FOLDERID_ProgramFilesX64. The x86 and x64 folders are optional: a 32-bit process or an older Windows may
# not report them. ProgramData is not asked for here: the known-folder API expands its record with the caller's
# %SystemDrive% (see program_data_folder).
SYSTEM_KNOWN_FOLDERS = (
    ("F38BF404-1D43-42F2-9305-67DE0B28FC23", True),
    ("905E63B6-C1BF-494E-B29C-65B732D3D21A", True),
    ("7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E", False),
    ("6D809377-6AF0-444B-8957-A3773F02200E", False),
)
KF_FLAG_DONT_VERIFY = 0x00004000
PROFILE_LIST_KEY = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
RESTORE_FOLDER_PREFIX = ".rewindle-restore-"


class ResticReadError(RuntimeError):
    """A read-only Restic metadata operation failed without exposing argv."""

    def __init__(self, operation: str, returncode: int):
        self.operation = operation
        self.returncode = int(returncode)
        super().__init__(f"Restic {operation} failed with exit code {returncode}")


def _normalized_windows_path(path: Path | str) -> str:
    return canonical_path(path)


def _is_within_windows_path(candidate: Path | str, parent: Path | str) -> bool:
    normalized_candidate = _normalized_windows_path(candidate)
    normalized_parent = _normalized_windows_path(parent)
    return normalized_candidate == normalized_parent or normalized_candidate.startswith(
        normalized_parent.rstrip("\\") + "\\"
    )


def validate_repository_storage_config(config: dict[str, Any]) -> str:
    """Validate the self-contained repository/backend topology.

    The recovery entrypoint cannot depend on the installed runtime package, so
    it carries the same narrow DriveFS path contract locally. This validation
    is lexical; repository availability and volume identity are checked later.
    """

    mode = config.get("repository_storage_mode", LOCAL_NTFS_MODE)
    if not isinstance(mode, str) or mode not in REPOSITORY_STORAGE_MODES:
        raise ValueError(
            "restore configuration repository_storage_mode is unsupported"
        )
    repository = config.get("repository")
    if not isinstance(repository, str) or not repository.strip():
        raise ValueError("restore configuration repository must be a non-empty path")
    repository_drive, _ = ntpath.splitdrive(ntpath.abspath(repository))
    if repository_drive.casefold() == "g:" and mode != GOOGLE_DRIVEFS_MODE:
        raise ValueError(
            "a repository on G: requires explicit google_drivefs_stream mode"
        )
    role_paths = {"repository": repository}
    for name in ("state_directory", "recovery_tools_directory"):
        value = config.get(name)
        if isinstance(value, str) and value.strip():
            role_paths[name] = value
    role_items = list(role_paths.items())
    for index, (name, path) in enumerate(role_items):
        for other_name, other_path in role_items[:index]:
            if _is_within_windows_path(
                path, other_path
            ) or _is_within_windows_path(other_path, path):
                raise ValueError(
                    "restore configuration protected roles overlap: "
                    f"{other_name} and {name}"
                )

    root = config.get("drivefs_my_drive_root")
    legacy_root = config.get("repository_drivefs_root")
    cache = config.get("drivefs_cache_directory")
    if mode == LOCAL_NTFS_MODE:
        if root is not None or legacy_root is not None or cache is not None:
            raise ValueError(
                "DriveFS path bindings are only valid with google_drivefs_stream"
            )
        return mode

    if root is None:
        root = legacy_root
    elif (
        legacy_root is not None
        and isinstance(root, str)
        and isinstance(legacy_root, str)
        and _normalized_windows_path(root) != _normalized_windows_path(legacy_root)
    ):
        raise ValueError(
            "drivefs_my_drive_root conflicts with legacy repository_drivefs_root"
        )
    if not isinstance(root, str) or not root.strip() or not ntpath.isabs(root):
        raise ValueError(
            "google_drivefs_stream requires an absolute drivefs_my_drive_root"
        )
    if cache is None and legacy_root is not None:
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            cache = str(Path(local_app_data) / "Google" / "DriveFS")
    if not isinstance(cache, str) or not cache.strip() or not ntpath.isabs(cache):
        raise ValueError(
            "google_drivefs_stream requires an absolute drivefs_cache_directory"
        )
    if _normalized_windows_path(root) != _normalized_windows_path(
        EXPECTED_DRIVEFS_MY_DRIVE_ROOT
    ):
        raise ValueError(
            f"Google DriveFS binding must be exactly {EXPECTED_DRIVEFS_MY_DRIVE_ROOT}"
        )
    if (
        not _is_within_windows_path(repository, root)
        or _normalized_windows_path(repository) == _normalized_windows_path(root)
    ):
        raise ValueError(
            "DriveFS repository must be strictly beneath drivefs_my_drive_root"
        )
    if _is_within_windows_path(cache, root):
        raise ValueError("drivefs_cache_directory must remain outside Google DriveFS")
    for name in ("state_directory", "recovery_tools_directory"):
        value = config.get(name)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(
                f"google_drivefs_stream restore configuration requires {name}"
            )
        if _is_within_windows_path(value, root):
            raise ValueError(f"{name} must remain outside Google DriveFS")
    for name in (
        "secret_file",
        "recovery_key_file",
        "restic_executable",
        "python_executable",
        "exclude_file",
    ):
        value = config.get(name)
        if isinstance(value, str) and value.strip() and _is_within_windows_path(
            value, root
        ):
            raise ValueError(f"{name} must remain outside Google DriveFS")
    return mode


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--repository", type=Path, help="override repository path")
    parser.add_argument("--restic", type=Path, help="override Restic executable")
    parser.add_argument(
        "--recovery-key-file",
        type=Path,
        help="restricted recovery text file containing a 'Password:' line",
    )
    parser.add_argument("--list", action="store_true", help="list snapshots")
    parser.add_argument(
        "--list-snapshots-json",
        "--list-json",
        action="store_true",
        dest="list_snapshots_json",
        help="emit configuration-bound snapshots as one machine-readable JSON object",
    )
    parser.add_argument(
        "--list-tree-json",
        "--tree-json",
        action="store_true",
        dest="list_tree_json",
        help="emit a snapshot tree as one machine-readable JSON object",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="with --list, use the machine-readable snapshot-list form",
    )
    parser.add_argument("--snapshot", default="latest")
    parser.add_argument(
        "--allow-legacy-unbound",
        action="store_true",
        help=(
            "allow one exact legacy snapshot ID after it matches the configured "
            "repository, host, scheduled tag, and complete source set"
        ),
    )
    parser.add_argument(
        "--tree-path",
        default=None,
        help="optional in-snapshot directory passed to Restic ls",
    )
    parser.add_argument("--target", type=Path)
    parser.add_argument(
        "--source",
        type=Path,
        help="restore one exact configured source without recreating absolute-path ancestors",
    )
    parser.add_argument(
        "--include",
        action="append",
        default=[],
        help=(
            "one item to restore, taken literally: its path as Restic lists it (for example "
            "/C/Users/you/Documents/report.docx), or with --source its path inside that source "
            "(for example /report.docx); repeatable"
        ),
    )
    parser.add_argument(
        "--report",
        type=Path,
        help="atomically write a bounded JSON report for this restore",
    )
    parser.add_argument(
        "--recovery-drill",
        action="store_true",
        help="restore and independently verify one bounded recovery sample",
    )
    parser.add_argument(
        "--drill-canary-sha256",
        help="protected historical SHA-256 for the snapshot canary",
    )
    parser.add_argument(
        "--drill-canary-bytes",
        type=int,
        help="protected historical byte count for the snapshot canary",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        help="existing Restic cache directory to read through (the protected backup's own cache)",
    )
    parser.add_argument(
        "--no-restic-lock",
        action="store_true",
        help="list without Restic's repository lock; only for a caller that holds the protected run lock",
    )
    parser.add_argument(
        "--find-json",
        action="store_true",
        help="look for files and folders by name in every backup, newest first, and emit one JSON object",
    )
    parser.add_argument(
        "--find-text",
        help="with --find-json: part of the name to look for (pass it as --find-text=TEXT)",
    )
    parser.add_argument(
        "--find-from-snapshot",
        help="with --find-json: the exact ID of the newest backup to look through",
    )
    parser.add_argument(
        "--find-seconds",
        type=int,
        help="with --find-json: the time the search may take, in seconds",
    )
    return parser.parse_args(argv)


def load_restore_config(path: Path) -> dict[str, Any]:
    value = json.loads(path.resolve(strict=True).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("restore configuration must be a JSON object")
    required = {"repository", "repository_volume_serial", "sources"}
    missing = sorted(required - value.keys())
    if missing:
        raise ValueError(f"restore configuration is missing: {', '.join(missing)}")
    if not isinstance(value.get("repository"), str) or not value["repository"].strip():
        raise ValueError("restore configuration repository must be a non-empty path")
    sources = value.get("sources")
    if (
        not isinstance(sources, list)
        or not sources
        or any(not isinstance(item, str) or not item.strip() for item in sources)
    ):
        raise ValueError("restore configuration sources must be non-empty paths")
    if "hostname" in value and (
        not isinstance(value["hostname"], str) or not value["hostname"].strip()
    ):
        raise ValueError("restore configuration hostname must be a non-empty string")
    if "scheduled_tag" in value:
        scheduled_tag = value["scheduled_tag"]
        if isinstance(scheduled_tag, str):
            valid_scheduled_tag = bool(scheduled_tag.strip())
        else:
            valid_scheduled_tag = (
                isinstance(scheduled_tag, list)
                and bool(scheduled_tag)
                and all(
                    isinstance(item, str) and bool(item.strip())
                    for item in scheduled_tag
                )
            )
        if not valid_scheduled_tag:
            raise ValueError("restore configuration scheduled_tag must contain valid tags")
    has_plan = "plan_id" in value
    has_generation = "config_generation" in value
    if has_plan != has_generation:
        raise ValueError("restore configuration plan_id and config_generation must occur together")
    if has_plan:
        plan_id = value["plan_id"]
        if not isinstance(plan_id, str):
            raise ValueError("restore configuration plan_id must be a canonical UUID")
        try:
            parsed_plan = uuid.UUID(plan_id)
        except (ValueError, AttributeError) as error:
            raise ValueError("restore configuration plan_id must be a canonical UUID") from error
        if str(parsed_plan) != plan_id:
            raise ValueError("restore configuration plan_id must be a canonical lowercase UUID")
        generation = value["config_generation"]
        if (
            isinstance(generation, bool)
            or not isinstance(generation, int)
            or generation <= 0
            or generation > 2**63 - 1
        ):
            raise ValueError("restore configuration config_generation must be a positive integer")
    if "topology_paths" in value:
        topology_paths = value["topology_paths"]
        if not isinstance(topology_paths, dict) or any(
            not isinstance(item, str) or not item.strip()
            for item in topology_paths.values()
        ):
            raise ValueError("restore configuration topology_paths must contain paths")
    repository_access(value)
    validate_repository_storage_config(value)
    return value


def choose_existing_path(candidates: list[Path | None], label: str) -> Path:
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate.resolve(strict=True)
    shown = ", ".join(str(item) for item in candidates if item is not None)
    raise FileNotFoundError(f"no usable {label} found; checked: {shown}")


def volume_serial(path: Path) -> str:
    root = ntpath.splitdrive(ntpath.abspath(str(path)))[0] + "\\"
    serial = wintypes.DWORD()
    maximum_component = wintypes.DWORD()
    flags = wintypes.DWORD()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    if not kernel32.GetVolumeInformationW(
        root,
        None,
        0,
        ctypes.byref(serial),
        ctypes.byref(maximum_component),
        ctypes.byref(flags),
        None,
        0,
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return f"{serial.value:08X}"


def canonical_path(path: Path | str) -> str:
    # This recovery entrypoint is copied into a standalone bundle; keep its
    # DOS-alias comparison independent of the installed restic_common module.
    absolute = ntpath.normpath(ntpath.abspath(str(path)))
    if os.name != "nt":
        return ntpath.normcase(absolute)
    get_long_path = ctypes.WinDLL("kernel32", use_last_error=True).GetLongPathNameW
    get_long_path.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
    get_long_path.restype = ctypes.c_uint32
    candidate = absolute
    suffix: list[str] = []
    while True:
        buffer = ctypes.create_unicode_buffer(32768)
        length = get_long_path(candidate, buffer, len(buffer))
        if 0 < length < len(buffer):
            return ntpath.normcase(ntpath.normpath(ntpath.join(buffer.value, *reversed(suffix))))
        if length >= len(buffer):
            raise ValueError("Windows path exceeds the supported length")
        error = ctypes.get_last_error()
        if error not in (2, 3, 15, 21, 53, 67, 123, 161):
            raise ctypes.WinError(error)
        parent, leaf = ntpath.split(candidate)
        if not leaf or parent == candidate:
            return ntpath.normcase(absolute)
        suffix.append(leaf)
        candidate = parent


def windows_snapshot_path(path: Path) -> str:
    absolute = ntpath.abspath(str(path))
    drive, tail = ntpath.splitdrive(absolute)
    if not drive or drive.startswith("\\"):
        raise ValueError("unsupported Windows source path form")
    components = [part for part in tail.replace("\\", "/").split("/") if part]
    return "/" + "/".join([drive.rstrip(":"), *components])


def select_configured_source(requested: Path, configured: list[str]) -> Path:
    requested_text = canonical_path(requested)
    matches = [
        Path(source)
        for source in configured
        if canonical_path(source) == requested_text
    ]
    if len(matches) != 1:
        raise ValueError("--source must exactly match one source recorded in backup-config.json")
    return matches[0]


def is_within(candidate: Path | str, parent: Path | str) -> bool:
    child = canonical_path(candidate)
    root = canonical_path(parent)
    try:
        return ntpath.commonpath([child, root]) == root
    except ValueError:
        return False


def paths_overlap(first: Path | str, second: Path | str) -> bool:
    return is_within(first, second) or is_within(second, first)


def recovery_password(path: Path) -> str:
    text = path.resolve(strict=True).read_text(encoding="utf-8-sig")
    matches = re.findall(r"^Password:\s*(\S+)\s*$", text, flags=re.MULTILINE)
    if len(matches) != 1 or len(matches[0]) < 40:
        raise ValueError("recovery key file must contain exactly one valid Password line")
    return matches[0]


def repository_access(config: dict[str, Any]) -> str:
    """How Restic opens these backups: "password" (also when the key is absent) or "no_password".

    Any other value is refused, never read as a default: these backups would then be opened the wrong way. The message
    names only the key, because the manager's report filter hides a whole message that names a password source.
    """
    value = config.get("repository_access", DEFAULT_REPOSITORY_ACCESS)
    if not isinstance(value, str) or value not in REPOSITORY_ACCESS_VALUES:
        raise ValueError("unsupported repository_access")
    return value


def assert_no_password_source_with_flag(
    command: list[str], environment: dict[str, str] | None = None
) -> None:
    """Refuse a Restic command that opens backups without a password (NO_PASSWORD_FLAG) and also has a password source.

    Restic refuses that pair, but only after it has run a password command, so nothing is started for it: not a
    password option on the command line, and not a non-empty password variable (an empty one is tolerated) in the
    environment it would be given.
    """
    if NO_PASSWORD_FLAG not in command:
        return
    for argument in command:
        for option in PASSWORD_SOURCE_OPTIONS:
            if argument == option or argument.startswith(option + "="):
                raise ValueError(NO_KEY_SOURCE_MESSAGE)
    for name, value in (environment or {}).items():
        if name.upper() in PASSWORD_SOURCE_VARIABLES and value:
            raise ValueError(NO_KEY_SOURCE_MESSAGE)


def password_command(config: dict[str, Any]) -> str | None:
    if repository_access(config) == "no_password":
        # These backups open without a key. An older install's DPAPI file at secret_file is left alone and never used:
        # Restic would run its password command before refusing it next to the flag.
        return None
    python = Path(config.get("python_executable", ""))
    secret = Path(config.get("secret_file", ""))
    helper = (
        choose_existing_path(
            [
                SCRIPT_DIRECTORY / "secret_store.py",
                Path(config.get("restic_executable", "")).parent.parent
                / "secret_store.py",
            ],
            "DPAPI helper",
        )
        if secret.is_file() and python.is_file()
        else None
    )
    if helper is None:
        return None
    arguments = [
        str(python).replace("\\", "/"),
        "-I",
        "-S",
        "-B",
        str(helper).replace("\\", "/"),
        "reveal",
        "--secret-file",
        str(secret).replace("\\", "/"),
    ]
    return subprocess.list2cmdline(arguments)


def windows_directory() -> Path:
    """Return the shared Windows folder as Windows reports it, not SystemRoot."""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetSystemWindowsDirectoryW.argtypes = [wintypes.LPWSTR, wintypes.UINT]
    kernel32.GetSystemWindowsDirectoryW.restype = wintypes.UINT
    buffer = ctypes.create_unicode_buffer(32768)
    length = kernel32.GetSystemWindowsDirectoryW(buffer, len(buffer))
    if length == 0 or length >= len(buffer):
        raise ctypes.WinError(ctypes.get_last_error())
    return Path(buffer.value)


def restic_child_environment() -> dict[str, str]:
    """Build Restic's complete environment from an allow-list.

    This bundle cannot import restic_common, so it carries its own copy of the
    engine's list. Nothing else is inherited: an inherited
    RESTIC_PASSWORD_COMMAND, RESTIC_PASSWORD_FILE, RESTIC_REPOSITORY_FILE or
    RCLONE_* value would run a command with the restore's rights or point
    Restic somewhere else. LOCALAPPDATA stays because Restic's default cache
    lives there when no --cache-dir is given. A recovery key's RESTIC_PASSWORD
    is added by the caller.
    """
    windows = windows_directory()
    system = windows / "System32"
    environment = {
        "SystemRoot": str(windows),
        "windir": str(windows),
        "SystemDrive": windows.drive,
        "ComSpec": str(system / "cmd.exe"),
        "PATH": ";".join(
            str(path)
            for path in (
                system,
                windows,
                system / "Wbem",
                system / "WindowsPowerShell" / "v1.0",
            )
        ),
        "PATHEXT": ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC",
        "OS": "Windows_NT",
        "NUMBER_OF_PROCESSORS": str(os.cpu_count() or 1),
    }
    architecture = os.environ.get("PROCESSOR_ARCHITECTURE")
    if architecture in {"AMD64", "x86", "ARM64"}:
        environment["PROCESSOR_ARCHITECTURE"] = architecture
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    if re.match(r"^[A-Za-z]:\\", local_app_data):
        environment["LOCALAPPDATA"] = local_app_data
    return environment


def restic_executable_prefix(restic: Path) -> list[str]:
    # A Python fake is useful for the fully disposable test suite.  Production
    # recovery bundles continue to use the unchanged restic.exe form.
    if restic.suffix.casefold() == ".py":
        return [sys.executable, str(restic)]
    return [str(restic)]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def normalize_paths(paths: list[Any]) -> list[str]:
    return sorted(
        ntpath.normcase(ntpath.normpath(str(path)))
        for path in paths
        if isinstance(path, str) and path.strip()
    )


def configured_tags(config: dict[str, Any]) -> list[str]:
    value = config.get("scheduled_tag")
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    if isinstance(value, list):
        return [item.strip() for item in value if isinstance(item, str) and item.strip()]
    return []


def configured_plan(config: dict[str, Any]) -> tuple[str, int] | None:
    plan_id = config.get("plan_id")
    generation = config.get("config_generation")
    if isinstance(plan_id, str) and isinstance(generation, int) and not isinstance(
        generation, bool
    ):
        return plan_id, generation
    return None


def plan_tag(plan_id: str) -> str:
    return PLAN_TAG_PREFIX + plan_id


def generation_tag(generation: int) -> str:
    return GENERATION_TAG_PREFIX + str(generation)


def snapshot_plan_metadata(
    snapshot: dict[str, Any], config: dict[str, Any]
) -> tuple[str, int] | None:
    expected = configured_plan(config)
    if expected is None:
        return None
    tags = snapshot.get("tags")
    if not isinstance(tags, list) or any(not isinstance(item, str) for item in tags):
        raise ValueError("snapshot tags are invalid")
    plan_tags = [item for item in tags if item.startswith(PLAN_TAG_PREFIX)]
    generation_tags = [item for item in tags if item.startswith(GENERATION_TAG_PREFIX)]
    if len(plan_tags) != 1 or plan_tags[0] != plan_tag(expected[0]):
        raise ValueError("snapshot does not have exactly one matching backup-plan tag")
    if len(generation_tags) != 1:
        raise ValueError("snapshot does not have exactly one generation tag")
    generation_text = generation_tags[0][len(GENERATION_TAG_PREFIX) :]
    if not re.fullmatch(r"[1-9][0-9]*", generation_text):
        raise ValueError("snapshot generation tag is malformed")
    generation = int(generation_text)
    if generation > 2**63 - 1:
        raise ValueError("snapshot generation tag is outside the supported range")
    return expected[0], generation


def snapshot_matches_plan(snapshot: dict[str, Any], config: dict[str, Any]) -> bool:
    try:
        return snapshot_plan_metadata(snapshot, config) is not None
    except ValueError:
        return False


def snapshot_has_plan_binding_tags(snapshot: dict[str, Any]) -> bool:
    tags = snapshot.get("tags")
    if not isinstance(tags, list) or any(not isinstance(item, str) for item in tags):
        return True
    prefixes = (PLAN_TAG_PREFIX.casefold(), GENERATION_TAG_PREFIX.casefold())
    return any(item.casefold().startswith(prefixes) for item in tags)


def snapshot_matches_legacy_configuration(
    snapshot: dict[str, Any], config: dict[str, Any]
) -> bool:
    """Match only pre-plan snapshots that are unambiguously from this configuration."""
    if configured_plan(config) is None or snapshot_has_plan_binding_tags(snapshot):
        return False
    hostname = config.get("hostname")
    actual_hostname = snapshot.get("hostname")
    if (
        not isinstance(hostname, str)
        or not hostname.strip()
        or not isinstance(actual_hostname, str)
        or actual_hostname.casefold() != hostname.strip().casefold()
    ):
        return False
    required_tags = configured_tags(config)
    actual_tags = snapshot.get("tags")
    if (
        not required_tags
        or not isinstance(actual_tags, list)
        or any(not isinstance(tag, str) for tag in actual_tags)
        or any(tag not in actual_tags for tag in required_tags)
    ):
        return False
    configured_sources = config.get("sources")
    actual_paths = snapshot.get("paths")
    if (
        not isinstance(configured_sources, list)
        or not configured_sources
        or not isinstance(actual_paths, list)
        or normalize_paths(actual_paths) != normalize_paths(configured_sources)
    ):
        return False
    return True


def snapshot_binding_state(
    snapshot: dict[str, Any], config: dict[str, Any]
) -> str | None:
    if configured_plan(config) is None and snapshot_matches_configuration(snapshot, config):
        return SNAPSHOT_BINDING_CONFIGURATION
    if snapshot_matches_plan(snapshot, config):
        return SNAPSHOT_BINDING_PLAN
    if snapshot_matches_legacy_configuration(snapshot, config):
        return SNAPSHOT_BINDING_LEGACY
    return None


def snapshot_matches_configuration(
    snapshot: dict[str, Any], config: dict[str, Any]
) -> bool:
    plan = configured_plan(config)
    if plan is not None:
        try:
            metadata = snapshot_plan_metadata(snapshot, config)
        except ValueError:
            return False
        if metadata is None or metadata[1] != plan[1]:
            return False
    hostname = config.get("hostname")
    if isinstance(hostname, str) and hostname.strip():
        actual = snapshot.get("hostname")
        if not isinstance(actual, str) or actual.casefold() != hostname.strip().casefold():
            return False
    required_tags = configured_tags(config)
    if required_tags:
        actual_tags = snapshot.get("tags") or []
        if not isinstance(actual_tags, list) or any(tag not in actual_tags for tag in required_tags):
            return False
    configured_sources = config.get("sources") or []
    if configured_sources:
        actual_paths = snapshot.get("paths") or []
        if not isinstance(actual_paths, list) or normalize_paths(actual_paths) != normalize_paths(
            configured_sources
        ):
            return False
    return True


def validate_snapshot(snapshot: Any) -> dict[str, Any]:
    if not isinstance(snapshot, dict):
        raise ValueError("Restic snapshot JSON contained a non-object entry")
    snapshot_id = snapshot.get("id")
    if not isinstance(snapshot_id, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", snapshot_id):
        raise ValueError("Restic snapshot JSON contained an invalid snapshot ID")
    return snapshot


def parse_json_array(text: str, operation: str) -> list[dict[str, Any]]:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError(f"Restic returned invalid JSON for {operation}") from error
    if value is None:
        return []
    if not isinstance(value, list):
        raise ValueError(f"Restic returned a non-array JSON value for {operation}")
    return [validate_snapshot(item) for item in value]


def parse_json_stream(text: str) -> list[dict[str, Any]]:
    stripped = text.strip()
    if not stripped:
        return []
    if stripped.startswith("["):
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError as error:
            raise ValueError("Restic returned invalid JSON for tree listing") from error
        if not isinstance(value, list) or not all(isinstance(item, dict) for item in value):
            raise ValueError("Restic returned an invalid tree JSON collection")
        return value
    entries: list[dict[str, Any]] = []
    for line in stripped.splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError("Restic returned invalid JSON for tree listing") from error
        if not isinstance(item, dict):
            raise ValueError("Restic returned a non-object tree entry")
        entries.append(item)
    return entries


def normalize_snapshot_file_path(value: Any) -> str:
    if not isinstance(value, str) or not value.startswith("/") or "\\" in value:
        raise ValueError("Restic returned an invalid snapshot file path")
    components = [component for component in value.split("/") if component]
    if not components or any(component in {".", ".."} for component in components):
        raise ValueError("Restic returned an unsafe snapshot file path")
    normalized = "/" + "/".join(components)
    if len(normalized) > MAX_REPORT_STRING:
        raise ValueError("Restic returned an overlong snapshot file path")
    return normalized


def choose_recovery_drill_sample(
    entries: list[dict[str, Any]],
    *,
    canary_snapshot_path: str,
    source_snapshot_paths: list[str],
) -> list[dict[str, Any]]:
    canary = normalize_snapshot_file_path(canary_snapshot_path)
    sources = [normalize_snapshot_file_path(item) for item in source_snapshot_paths]
    candidates: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in entries:
        if entry.get("type") != "file":
            continue
        path = normalize_snapshot_file_path(entry.get("path"))
        raw_size = entry.get("size")
        if isinstance(raw_size, bool) or not isinstance(raw_size, int) or raw_size < 0:
            raise ValueError("Restic returned an invalid snapshot file size")
        if path.casefold() == canary.casefold():
            continue
        if raw_size == 0 or raw_size > DRILL_MAX_FILE_BYTES:
            continue
        leaf = path.rsplit("/", 1)[-1]
        if (
            not leaf
            or leaf.endswith((" ", "."))
            or any(ord(character) < 32 for character in leaf)
            or any(character in leaf for character in '*?[]<>:"|')
        ):
            continue
        folded = path.casefold()
        if folded in seen:
            raise ValueError("Restic returned a duplicate snapshot file path")
        seen.add(folded)
        matching_sources = [
            source
            for source in sources
            if path.casefold() == source.casefold()
            or path.casefold().startswith(source.casefold().rstrip("/") + "/")
        ]
        if not matching_sources:
            raise ValueError("Restic returned a file outside the configured source roots")
        source = max(matching_sources, key=len)
        candidates.append({"path": path, "bytes": raw_size, "source": source})
    source_order = {source.casefold(): index for index, source in enumerate(sources)}
    candidates.sort(
        key=lambda item: (
            source_order[str(item["source"]).casefold()],
            str(item["path"]).casefold(),
            int(item["bytes"]),
        )
    )

    chosen: list[dict[str, Any]] = []
    chosen_paths: set[str] = set()
    total = 0
    for pass_index in (0, 1):
        for source in sources:
            eligible = [
                item
                for item in candidates
                if str(item["source"]) == source
                and str(item["path"]).casefold() not in chosen_paths
            ]
            if not eligible:
                continue
            candidate = eligible[0]
            size = int(candidate["bytes"])
            if total + size > DRILL_MAX_TOTAL_BYTES:
                continue
            chosen.append(candidate)
            chosen_paths.add(str(candidate["path"]).casefold())
            total += size
            if len(chosen) >= DRILL_MAX_FILES:
                break
        if len(chosen) >= DRILL_MAX_FILES:
            break
    if len(chosen) < 2:
        raise RuntimeError(
            "the snapshot has fewer than two bounded ordinary-data files for a representative drill"
        )
    return chosen


def snapshot_path_to_target(target: Path, snapshot_path: str) -> Path:
    normalized = normalize_snapshot_file_path(snapshot_path)
    return target.joinpath(*[component for component in normalized.split("/") if component])


def recovery_drill_restore_groups(
    canary_snapshot_path: str,
    canary_bytes: int,
    sample: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    selected = [
        {"path": normalize_snapshot_file_path(canary_snapshot_path), "bytes": canary_bytes, "canary": True},
        *[
            {"path": normalize_snapshot_file_path(item["path"]), "bytes": int(item["bytes"]), "canary": False}
            for item in sample
        ],
    ]
    groups: list[dict[str, Any]] = []
    by_parent: dict[str, dict[str, Any]] = {}
    for item in selected:
        parent, leaf = str(item["path"]).rsplit("/", 1)
        if (
            not parent
            or not leaf
            or leaf.endswith((" ", "."))
            or any(ord(character) < 32 for character in leaf)
            or any(character in leaf for character in '*?[]<>:"|')
        ):
            raise ValueError("a recovery-drill file name cannot be selected literally")
        key = parent.casefold()
        group = by_parent.get(key)
        if group is None:
            group = {"parent": parent, "items": []}
            by_parent[key] = group
            groups.append(group)
        group["items"].append({**item, "leaf": leaf})
    return groups


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run_restic_json_lines_bounded(
    base_command: list[str],
    arguments: list[str],
    environment: dict[str, str],
    interactive_password: bool,
    operation: str,
) -> list[dict[str, Any]]:
    assert_no_password_source_with_flag([*base_command, *arguments], environment)
    process = subprocess.Popen(
        [*base_command, *arguments],
        cwd=SCRIPT_DIRECTORY,
        stdin=None if interactive_password else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        shell=False,
        creationflags=CREATE_NO_WINDOW,
    )
    if process.stdout is None or process.stderr is None:
        process.kill()
        raise RuntimeError("Restic output channels could not be opened")
    diagnostic = bytearray()
    diagnostic_overflow = False

    def drain_diagnostic() -> None:
        nonlocal diagnostic_overflow
        for block in iter(lambda: process.stderr.read(64 * 1024), b""):
            remaining = DRILL_MAX_DIAGNOSTIC_BYTES - len(diagnostic)
            if remaining > 0:
                diagnostic.extend(block[:remaining])
            if len(block) > remaining:
                diagnostic_overflow = True

    diagnostic_thread = threading.Thread(target=drain_diagnostic, daemon=True)
    diagnostic_thread.start()
    entries: list[dict[str, Any]] = []
    total_bytes = 0
    overflow = False
    try:
        for raw_line in iter(process.stdout.readline, b""):
            total_bytes += len(raw_line)
            if total_bytes > DRILL_MAX_LISTING_BYTES or len(raw_line) > MAX_REPORT_BYTES:
                overflow = True
                break
            try:
                item = json.loads(raw_line.decode("utf-8", errors="strict"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise ValueError("Restic returned invalid UTF-8 JSON for the drill listing") from error
            if not isinstance(item, dict):
                raise ValueError("Restic returned a non-object drill listing entry")
            entries.append(item)
            if len(entries) > DRILL_MAX_LISTING_ENTRIES:
                overflow = True
                break
        if overflow:
            process.kill()
        returncode = process.wait()
        diagnostic_thread.join(timeout=5)
        if diagnostic_thread.is_alive():
            process.kill()
            raise RuntimeError("Restic diagnostics did not close after the drill listing")
        if overflow:
            raise RuntimeError("Restic drill listing exceeded its bounded safety limit")
        if diagnostic_overflow:
            raise RuntimeError("Restic drill diagnostics exceeded their bounded safety limit")
        if returncode != 0:
            raise ResticReadError(operation, returncode)
        return entries
    finally:
        try:
            process.stdout.close()
        except Exception:
            pass


def query_recovery_drill_listing(
    base_command: list[str],
    environment: dict[str, str],
    interactive_password: bool,
    exact_selector: str,
    *,
    canary_snapshot_path: str,
    source_snapshot_paths: list[str],
) -> list[dict[str, Any]]:
    canary = normalize_snapshot_file_path(canary_snapshot_path).casefold()
    collected: list[dict[str, Any]] = []
    total_entries = 0
    total_bytes = 0
    total_calls = 0
    for raw_source in source_snapshot_paths:
        source = normalize_snapshot_file_path(raw_source)
        source_folded = source.casefold()
        queue = [source]
        seen_directories = {source_folded}
        eligible_paths: set[str] = set()
        source_calls = 0
        while (
            queue
            and len(eligible_paths) < 2
            and source_calls < DRILL_MAX_DIRECTORIES_PER_SOURCE
            and total_calls < DRILL_MAX_LISTING_CALLS
        ):
            directory = queue.pop(0)
            entries = run_restic_json_lines_bounded(
                base_command,
                ["ls", "--json", "--", exact_selector, directory],
                environment,
                interactive_password,
                "bounded representative sample query",
            )
            source_calls += 1
            total_calls += 1
            total_entries += len(entries)
            total_bytes += sum(
                len(json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
                for entry in entries
            )
            if total_entries > DRILL_MAX_LISTING_ENTRIES or total_bytes > DRILL_MAX_LISTING_BYTES:
                raise RuntimeError("Restic drill traversal exceeded its aggregate safety limit")
            collected.extend(entries)
            discovered_directories: list[str] = []
            for entry in entries:
                entry_type = entry.get("type")
                if entry_type not in {"file", "dir"}:
                    continue
                path = normalize_snapshot_file_path(entry.get("path"))
                folded = path.casefold()
                if folded != source_folded and not folded.startswith(source_folded.rstrip("/") + "/"):
                    raise ValueError("Restic returned a drill entry outside its configured source root")
                if entry_type == "dir":
                    if folded not in seen_directories:
                        seen_directories.add(folded)
                        discovered_directories.append(path)
                    continue
                raw_size = entry.get("size")
                if isinstance(raw_size, bool) or not isinstance(raw_size, int) or raw_size < 0:
                    raise ValueError("Restic returned an invalid snapshot file size")
                leaf = path.rsplit("/", 1)[-1]
                if (
                    folded != canary
                    and 0 < raw_size <= DRILL_MAX_FILE_BYTES
                    and leaf
                    and not leaf.endswith((" ", "."))
                    and not any(ord(character) < 32 for character in leaf)
                    and not any(character in leaf for character in '*?[]<>:"|')
                ):
                    eligible_paths.add(folded)
            queue.extend(discovered_directories)
            queue.sort(key=str.casefold)
    return collected


def run_restic_capture(
    base_command: list[str],
    arguments: list[str],
    environment: dict[str, str],
    interactive_password: bool,
    operation: str,
) -> str:
    assert_no_password_source_with_flag([*base_command, *arguments], environment)
    completed = subprocess.run(
        [*base_command, *arguments],
        cwd=SCRIPT_DIRECTORY,
        stdin=None if interactive_password else subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=environment,
        shell=False,
        creationflags=CREATE_NO_WINDOW,
        check=False,
    )
    if completed.returncode != 0:
        raise ResticReadError(operation, completed.returncode)
    return completed.stdout


def query_repository_id(
    base_command: list[str], environment: dict[str, str], interactive_password: bool
) -> str:
    text = run_restic_capture(
        base_command, ["cat", "config"], environment, interactive_password, "repository query"
    )
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError("Restic returned invalid repository configuration JSON") from error
    repository_id = value.get("id") if isinstance(value, dict) else None
    if not isinstance(repository_id, str) or not re.fullmatch(
        r"[0-9a-fA-F]{16,128}", repository_id
    ):
        raise ValueError("Restic returned an invalid repository ID")
    return repository_id.lower()


def query_snapshots(
    base_command: list[str],
    environment: dict[str, str],
    interactive_password: bool,
    config: dict[str, Any],
    *,
    binding: str,
    selector: str | None = None,
    allow_legacy_unbound: bool = False,
    capture: Any = None,
) -> list[dict[str, Any]]:
    # `capture` runs Restic and returns its output; a file search passes one that stops at its deadline.
    capture = capture or run_restic_capture
    if binding not in {"current", "browse", "explicit"}:
        raise ValueError("invalid internal snapshot binding mode")
    arguments = ["snapshots", "--json"]
    plan = configured_plan(config)
    if plan is not None and not (
        binding == "browse" or (binding == "explicit" and allow_legacy_unbound)
    ):
        arguments.extend(["--tag", plan_tag(plan[0])])
        if binding == "current":
            arguments.extend(["--tag", generation_tag(plan[1])])
    if binding == "current" or (binding == "browse" and plan is None):
        hostname = config.get("hostname")
        if isinstance(hostname, str) and hostname.strip():
            arguments.extend(["--host", hostname.strip()])
        for tag in configured_tags(config):
            arguments.extend(["--tag", tag])
        for source in config.get("sources") or []:
            if isinstance(source, str) and source.strip():
                arguments.extend(["--path", source])
    if selector:
        arguments.extend(["--", selector])
    snapshots = parse_json_array(
        capture(
            base_command,
            arguments,
            environment,
            interactive_password,
            "snapshot query",
        ),
        "snapshot listing",
    )
    if binding == "current" or (binding == "browse" and plan is None):
        snapshots = [
            item for item in snapshots if snapshot_matches_configuration(item, config)
        ]
    elif plan is not None and binding == "browse":
        snapshots = [
            item for item in snapshots if snapshot_binding_state(item, config) is not None
        ]
    elif plan is not None and binding == "explicit" and allow_legacy_unbound:
        snapshots = [
            item for item in snapshots if snapshot_binding_state(item, config) is not None
        ]
    elif plan is not None:
        snapshots = [item for item in snapshots if snapshot_matches_plan(item, config)]
    return snapshots


def split_snapshot_selector(selector: str) -> tuple[str, str | None]:
    # Preserve Restic's snapshotID:subfolder selector while resolving only the
    # snapshot portion.  Snapshot IDs and aliases themselves cannot contain ':'.
    if ":" not in selector:
        return selector, None
    snapshot_part, subfolder = selector.split(":", 1)
    if not snapshot_part:
        raise ValueError("snapshot selector is empty")
    return snapshot_part, subfolder


def snapshot_sort_key(snapshot: dict[str, Any]) -> tuple[datetime, str]:
    raw_time = snapshot.get("time")
    if isinstance(raw_time, str):
        try:
            parsed = datetime.fromisoformat(raw_time.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            parsed = parsed.astimezone(timezone.utc)
        except ValueError:
            parsed = datetime.min.replace(tzinfo=timezone.utc)
    else:
        parsed = datetime.min.replace(tzinfo=timezone.utc)
    return parsed, str(snapshot.get("id", ""))


def resolve_snapshot(
    selector: str,
    base_command: list[str],
    environment: dict[str, str],
    interactive_password: bool,
    config: dict[str, Any],
    *,
    allow_legacy_unbound: bool = False,
) -> tuple[dict[str, Any], str]:
    snapshot_part, subfolder = split_snapshot_selector(selector.strip())
    if not snapshot_part:
        raise ValueError("snapshot selector is empty")
    if (
        snapshot_part.startswith("-")
        or "\x00" in snapshot_part
        or len(snapshot_part) > MAX_REPORT_STRING
    ):
        raise ValueError("snapshot selector is invalid or too long")
    if snapshot_part.casefold() == "latest":
        if allow_legacy_unbound:
            raise ValueError("legacy snapshot access requires one exact 64-character snapshot ID")
        candidates = query_snapshots(
            base_command,
            environment,
            interactive_password,
            config,
            binding="current",
        )
        if not candidates:
            raise RuntimeError(
                "no snapshot exactly matches the configured host, tag, and source roots"
            )
        selected = max(candidates, key=snapshot_sort_key)
    else:
        if allow_legacy_unbound and not re.fullmatch(r"[0-9a-fA-F]{64}", snapshot_part):
            raise ValueError("legacy snapshot access requires one exact 64-character snapshot ID")
        candidates = query_snapshots(
            base_command,
            environment,
            interactive_password,
            config,
            binding="explicit",
            selector=snapshot_part,
            allow_legacy_unbound=allow_legacy_unbound,
        )
        if not candidates:
            raise RuntimeError("the requested snapshot selector did not match a snapshot")
        exact = [
            item
            for item in candidates
            if item["id"].casefold() == snapshot_part.casefold()
            or str(item.get("short_id", "")).casefold() == snapshot_part.casefold()
            or item["id"].casefold().startswith(snapshot_part.casefold())
        ]
        if re.fullmatch(r"[0-9a-fA-F]{4,64}", snapshot_part) and not exact:
            raise RuntimeError("the requested snapshot ID is not part of this backup plan")
        selected_pool = exact or candidates
        if len(selected_pool) != 1:
            raise RuntimeError("the requested snapshot selector is ambiguous")
        selected = selected_pool[0]
    exact_selector = selected["id"]
    if subfolder is not None:
        exact_selector += ":" + subfolder
    return selected, exact_selector


def public_snapshot(snapshot: dict[str, Any], config: dict[str, Any]) -> dict[str, Any]:
    binding_state = snapshot_binding_state(snapshot, config)
    if binding_state is None:
        raise ValueError("snapshot is not bound to this backup configuration")
    result: dict[str, Any] = {
        "id": snapshot["id"].lower(),
        "short_id": snapshot.get("short_id"),
        "time": snapshot.get("time"),
        "hostname": snapshot.get("hostname"),
        "tags": snapshot.get("tags") or [],
        "paths": snapshot.get("paths") or [],
        "binding_state": binding_state,
    }
    summary = snapshot.get("summary")
    if isinstance(summary, dict):
        result["summary"] = summary
    metadata = (
        snapshot_plan_metadata(snapshot, config)
        if binding_state == SNAPSHOT_BINDING_PLAN
        else None
    )
    if metadata is not None:
        result["plan_id"] = metadata[0]
        result["config_generation"] = metadata[1]
    return result


def path_is_reparse(path: Path) -> bool:
    try:
        information = os.lstat(path)
    except FileNotFoundError:
        return False
    attributes = getattr(information, "st_file_attributes", 0)
    return bool(attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)) or path.is_symlink()


def ensure_no_reparse_ancestor(path: Path) -> None:
    parts = path.parts
    if not parts:
        raise RuntimeError("restore target is invalid")
    current = Path(parts[0])
    if current.exists() and path_is_reparse(current):
        raise RuntimeError("restore target must not traverse a reparse point")
    for part in parts[1:]:
        current = current / part
        if not os.path.lexists(current):
            break
        if path_is_reparse(current):
            raise RuntimeError("restore target must not traverse a reparse point")
        if current != path and not current.is_dir():
            raise RuntimeError("restore target parent must be a normal directory")


def ensure_local_volume(path: Path) -> None:
    absolute = ntpath.abspath(str(path))
    drive, _ = ntpath.splitdrive(absolute)
    if not drive or drive.startswith("\\\\"):
        raise RuntimeError("restore target must be on a local drive")
    root = drive + "\\"
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    drive_type = int(kernel32.GetDriveTypeW(root))
    if drive_type not in {DRIVE_FIXED, DRIVE_REMOVABLE}:
        raise RuntimeError("restore target must be on a writable local drive")


class _Guid(ctypes.Structure):
    _fields_ = [
        ("Data1", ctypes.c_uint32),
        ("Data2", ctypes.c_uint16),
        ("Data3", ctypes.c_uint16),
        ("Data4", ctypes.c_ubyte * 8),
    ]


def program_data_folder(windows_root: str) -> str:
    """ProgramData from the machine's own record, with %SystemDrive% taken from the Windows folder's drive.

    The record (ProfileList\\ProgramData, normally "%SystemDrive%\\ProgramData") is what the known-folder API
    reads too, but the API expands it with the calling process's environment, which the requesting user can set
    for an elevated process. Any other variable in the record is refused rather than expanded.
    """

    import winreg

    drive = ntpath.splitdrive(windows_root)[0]
    if not re.fullmatch(r"[A-Za-z]:", drive):
        raise RuntimeError("Windows and program folders could not be identified")
    try:
        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            PROFILE_LIST_KEY,
            0,
            winreg.KEY_QUERY_VALUE | winreg.KEY_WOW64_64KEY,
        ) as key:
            value, kind = winreg.QueryValueEx(key, "ProgramData")
    except OSError as error:
        raise RuntimeError("Windows and program folders could not be identified") from error
    if kind not in (winreg.REG_SZ, winreg.REG_EXPAND_SZ) or not isinstance(value, str):
        raise RuntimeError("Windows and program folders could not be identified")
    expanded = re.sub("%systemdrive%", lambda _match: drive, value, flags=re.IGNORECASE)
    if "%" in expanded or not re.fullmatch(r"[A-Za-z]:\\[^%]*", expanded):
        raise RuntimeError("Windows and program folders could not be identified")
    return ntpath.normpath(expanded)


def system_folder_roots() -> list[str]:
    """Windows, Program Files (both) and ProgramData, never taken from environment variables.

    The requesting user can set environment variables for an elevated process, so none is consulted. Windows and
    the Program Files folders come from the shell's known-folder API, which does not expand them from the
    environment; it reads its own records (KF_FLAG_DONT_VERIFY), so asking does not touch the folders themselves.
    ProgramData comes from program_data_folder, because the API would expand it with %SystemDrive%.
    """

    if os.name != "nt":
        return []
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    ole32 = ctypes.WinDLL("ole32")
    get_path = shell32.SHGetKnownFolderPath
    get_path.argtypes = [
        ctypes.POINTER(_Guid),
        wintypes.DWORD,
        wintypes.HANDLE,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    get_path.restype = ctypes.c_long
    ole32.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    ole32.CoTaskMemFree.restype = None
    roots: list[str] = []
    for folder_id, required in SYSTEM_KNOWN_FOLDERS:
        guid = _Guid.from_buffer_copy(uuid.UUID(folder_id).bytes_le)
        pointer = ctypes.c_void_p()
        result = get_path(ctypes.byref(guid), KF_FLAG_DONT_VERIFY, None, ctypes.byref(pointer))
        try:
            value = ctypes.wstring_at(pointer.value) if result >= 0 and pointer.value else ""
        finally:
            if pointer.value:
                ole32.CoTaskMemFree(pointer)
        if value:
            roots.append(value)
        elif required:
            raise RuntimeError("Windows and program folders could not be identified")
    roots.append(program_data_folder(roots[0]))
    return roots


def _system_root_key(root: str) -> str:
    absolute = ntpath.normpath(ntpath.abspath(root))
    # Known folders are recorded with long names. Expand a short-name alias only when one appears, so the check
    # never has to look inside a Windows or program folder.
    if "~" in absolute:
        return canonical_path(absolute)
    return ntpath.normcase(absolute)


def ensure_outside_system_folders(path: Path | str) -> None:
    candidate = canonical_path(path)
    for root in system_folder_roots():
        key = _system_root_key(root)
        try:
            inside = ntpath.commonpath([candidate, key]) == key
        except ValueError:
            inside = False
        if inside:
            raise RuntimeError(SYSTEM_FOLDER_REFUSAL)


def forbidden_restore_paths(
    config: dict[str, Any],
    config_path: Path,
    repository: Path,
    snapshot_paths: list[str] | None = None,
) -> list[Path]:
    paths: list[Path] = [repository, Path(config.get("repository", repository)), SCRIPT_DIRECTORY]
    for source in config.get("sources") or []:
        if isinstance(source, str) and source.strip():
            paths.append(Path(source))
    for name in (
        "state_directory",
        "runtime_directory",
        "recovery_tools_directory",
        "secret_file",
        "recovery_key_file",
        "restic_executable",
        "python_executable",
        "exclude_file",
        "canary_file",
    ):
        value = config.get(name)
        if isinstance(value, str) and value.strip():
            paths.append(Path(value))
    topology_paths = config.get("topology_paths")
    if isinstance(topology_paths, dict):
        for value in topology_paths.values():
            if isinstance(value, str) and value.strip():
                paths.append(Path(value))
    paths.append(config_path)
    for snapshot_path in snapshot_paths or []:
        if isinstance(snapshot_path, str) and snapshot_path.strip():
            paths.append(Path(snapshot_path))
    return paths


def validate_restore_target(
    requested: Path,
    config: dict[str, Any],
    config_path: Path,
    repository: Path,
    snapshot_paths: list[str] | None = None,
    *,
    allow_system_folders: bool = False,
) -> tuple[Path, bool]:
    target = Path(os.path.abspath(str(requested)))
    drive, tail = ntpath.splitdrive(canonical_path(target))
    if not drive or tail in ("", "\\", "/"):
        raise RuntimeError("restore target must not be a drive root")
    ensure_local_volume(target)
    # Only the recovery drill writes below ProgramData, into the protected manager's own drill folder.
    if not allow_system_folders:
        ensure_outside_system_folders(target)
    ensure_no_reparse_ancestor(target)
    for forbidden in forbidden_restore_paths(
        config, config_path, repository, snapshot_paths
    ):
        if paths_overlap(target, forbidden):
            raise RuntimeError(
                "restore target must not overlap the repository, a source, or protected backup state"
            )
    existed = target.exists()
    if existed:
        if not target.is_dir() or path_is_reparse(target):
            raise RuntimeError("restore target must be a normal directory")
        try:
            next(target.iterdir())
        except StopIteration:
            pass
        else:
            raise RuntimeError("restore target must be absent or an empty directory")
    return target, existed


# ----------------------------------------------------------------------------------------------------------
# The restore folder: no gap between the target check and Restic's writes.
#
# An elevated restore must never write through a junction that the requesting user puts in place after the
# target was checked. So the target is opened one folder at a time from the drive root, each relative to the
# handle of the folder above it and without following any link, and it stays open without delete sharing until
# the restore is handed over: Windows then refuses to rename it or any folder above it. Restic writes into a
# new hidden folder inside the target that only Administrators and SYSTEM can change (when the restore runs
# elevated), so nothing can be planted below it while Restic writes; Restic applies a restored folder's own
# permissions only after everything below that folder is written. Afterwards every restored item gets, through
# its own handle, the permissions it would have inherited inside the target, and moves into the target by
# handle, never replacing anything. Nothing is followed, and no path is walked again once a part of the tree
# may be writable by the user.

_FILE_LIST_DIRECTORY = 0x0001
_FILE_READ_ATTRIBUTES = 0x0080
_FILE_WRITE_ATTRIBUTES = 0x0100
_DELETE = 0x00010000
_READ_CONTROL = 0x00020000
_WRITE_DAC = 0x00040000
_SYNCHRONIZE = 0x00100000
_SHARE_READ_WRITE = 0x1 | 0x2
_SHARE_ALL = 0x1 | 0x2 | 0x4
_OPEN_EXISTING = 3
_FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
_FILE_OPEN = 1
_FILE_CREATE = 2
_FILE_OPEN_IF = 3
_FILE_DIRECTORY_FILE = 0x00000001
_FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020
_FILE_NON_DIRECTORY_FILE = 0x00000040
_FILE_OPEN_REPARSE_POINT = 0x00200000
_OBJ_CASE_INSENSITIVE = 0x00000040
_FILE_ATTRIBUTE_HIDDEN = 0x0002
_FILE_ATTRIBUTE_DIRECTORY = 0x0010
_FILE_ATTRIBUTE_NORMAL = 0x0080
_FILE_ATTRIBUTE_REPARSE_POINT = 0x0400
_FILE_PERSISTENT_ACLS = 0x0008
_FILE_SUPPORTS_REPARSE_POINTS = 0x0080
_FILE_ID_BOTH_DIRECTORY_INFO = 10
_FILE_ID_BOTH_DIRECTORY_RESTART_INFO = 11
_FILE_BASIC_INFORMATION = 4
_FILE_RENAME_INFORMATION = 10
_FILE_DISPOSITION_INFORMATION = 13
_ERROR_NO_MORE_FILES = 18
_OWNER_GROUP_DACL_INFORMATION = 0x1 | 0x2 | 0x4
_DACL_SECURITY_INFORMATION = 0x4
_SE_DACL_AUTO_INHERIT_REQ = 0x0100
_SE_DACL_AUTO_INHERITED = 0x0400
_SE_DACL_PROTECTED = 0x1000
_SEF_DACL_AUTO_INHERIT = 0x01
_SEF_AVOID_PRIVILEGE_CHECK = 0x08
_SEF_AVOID_OWNER_CHECK = 0x10
_TOKEN_QUERY = 0x0008
_TOKEN_USER = 1
_TOKEN_ELEVATION = 20
# The target and the restore folder are held with list access and without delete sharing: Windows then
# refuses to rename or delete them, or any folder above them. They never hold delete access themselves,
# which would make Restic's own opens of the folder fail.
_TARGET_ACCESS = _FILE_LIST_DIRECTORY | _FILE_READ_ATTRIBUTES | _READ_CONTROL
_RESTORE_FOLDER_ACCESS = _TARGET_ACCESS | _FILE_WRITE_ATTRIBUTES | _WRITE_DAC
_FILE_GENERIC_MAPPING = (0x00120089, 0x00120116, 0x001200A0, 0x001F01FF)
_ERROR_ACCESS_DENIED = 5
_ERROR_SHARING_VIOLATION = 32
_ERROR_ALREADY_EXISTS = 183
# Moving a restored item into the target is tried again for a short while when another program (an antivirus
# scan, for example) has a file in it open; the waits of one hand-over add up to a few seconds at most.
_MOVE_RETRY_DELAYS = (0.1, 0.25, 0.5, 1.0)
_MOVE_RETRY_BUDGET = 5.0
_LEFT_IN_RESTORE_FOLDER = (
    "Some restored files could not be moved into the folder you chose, because files with the same names "
    "appeared there while the restore ran. They are in the folder named {name} inside it."
)
_LEFT_IN_RESTORE_FOLDER_IN_USE = (
    "Some restored files could not be moved into the folder you chose; another program may have been using them, "
    "or a file with the same name was already there. They are in the folder named {name} inside it, and you can "
    "move them yourself."
)


class _UnicodeString(ctypes.Structure):
    _fields_ = [
        ("Length", ctypes.c_ushort),
        ("MaximumLength", ctypes.c_ushort),
        ("Buffer", ctypes.c_wchar_p),
    ]


class _ObjectAttributes(ctypes.Structure):
    _fields_ = [
        ("Length", ctypes.c_ulong),
        ("RootDirectory", wintypes.HANDLE),
        ("ObjectName", ctypes.POINTER(_UnicodeString)),
        ("Attributes", ctypes.c_ulong),
        ("SecurityDescriptor", ctypes.c_void_p),
        ("SecurityQualityOfService", ctypes.c_void_p),
    ]


class _IoStatusBlock(ctypes.Structure):
    _fields_ = [("Status", ctypes.c_void_p), ("Information", ctypes.c_size_t)]


class _FileInformation(ctypes.Structure):
    _fields_ = [
        ("dwFileAttributes", wintypes.DWORD),
        ("ftCreationTime", wintypes.FILETIME),
        ("ftLastAccessTime", wintypes.FILETIME),
        ("ftLastWriteTime", wintypes.FILETIME),
        ("dwVolumeSerialNumber", wintypes.DWORD),
        ("nFileSizeHigh", wintypes.DWORD),
        ("nFileSizeLow", wintypes.DWORD),
        ("nNumberOfLinks", wintypes.DWORD),
        ("nFileIndexHigh", wintypes.DWORD),
        ("nFileIndexLow", wintypes.DWORD),
    ]


class _DirectoryEntry(ctypes.Structure):
    # FILE_ID_BOTH_DIR_INFO without its trailing name, which starts right after this header.
    _fields_ = [
        ("NextEntryOffset", wintypes.DWORD),
        ("FileIndex", wintypes.DWORD),
        ("CreationTime", ctypes.c_longlong),
        ("LastAccessTime", ctypes.c_longlong),
        ("LastWriteTime", ctypes.c_longlong),
        ("ChangeTime", ctypes.c_longlong),
        ("EndOfFile", ctypes.c_longlong),
        ("AllocationSize", ctypes.c_longlong),
        ("FileAttributes", wintypes.DWORD),
        ("FileNameLength", wintypes.DWORD),
        ("EaSize", wintypes.DWORD),
        ("ShortNameLength", ctypes.c_byte),
        ("ShortName", ctypes.c_wchar * 12),
        ("FileId", ctypes.c_longlong),
    ]


class _RenameInformation(ctypes.Structure):
    # FILE_RENAME_INFORMATION without its trailing name, which starts right after FileNameLength.
    _fields_ = [
        ("ReplaceIfExists", ctypes.c_ulong),
        ("RootDirectory", wintypes.HANDLE),
        ("FileNameLength", ctypes.c_ulong),
    ]


class _BasicInformation(ctypes.Structure):
    _fields_ = [
        ("CreationTime", ctypes.c_longlong),
        ("LastAccessTime", ctypes.c_longlong),
        ("LastWriteTime", ctypes.c_longlong),
        ("ChangeTime", ctypes.c_longlong),
        ("FileAttributes", ctypes.c_ulong),
    ]


class _GenericMapping(ctypes.Structure):
    _fields_ = [
        ("GenericRead", wintypes.DWORD),
        ("GenericWrite", wintypes.DWORD),
        ("GenericExecute", wintypes.DWORD),
        ("GenericAll", wintypes.DWORD),
    ]


class _Win32:
    """The Windows calls the restore folder needs, loaded once and only when a restore runs."""

    def __init__(self) -> None:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
        ntdll = ctypes.WinDLL("ntdll")
        handle = wintypes.HANDLE
        dword = wintypes.DWORD
        self.create_file = kernel32.CreateFileW
        self.create_file.argtypes = [wintypes.LPCWSTR, dword, dword, ctypes.c_void_p, dword, dword, handle]
        self.create_file.restype = handle
        self.close_handle = kernel32.CloseHandle
        self.close_handle.argtypes = [handle]
        self.file_information = kernel32.GetFileInformationByHandle
        self.file_information.argtypes = [handle, ctypes.POINTER(_FileInformation)]
        self.file_information_ex = kernel32.GetFileInformationByHandleEx
        self.file_information_ex.argtypes = [handle, ctypes.c_int, ctypes.c_void_p, dword]
        self.final_path = kernel32.GetFinalPathNameByHandleW
        self.final_path.argtypes = [handle, wintypes.LPWSTR, dword, dword]
        self.final_path.restype = dword
        self.volume_information = kernel32.GetVolumeInformationByHandleW
        self.volume_information.argtypes = [
            handle,
            wintypes.LPWSTR,
            dword,
            ctypes.POINTER(dword),
            ctypes.POINTER(dword),
            ctypes.POINTER(dword),
            wintypes.LPWSTR,
            dword,
        ]
        self.local_free = kernel32.LocalFree
        self.local_free.argtypes = [ctypes.c_void_p]
        self.local_free.restype = ctypes.c_void_p
        self.current_process = kernel32.GetCurrentProcess
        self.current_process.restype = handle
        self.nt_create_file = ntdll.NtCreateFile
        self.nt_create_file.argtypes = [
            ctypes.POINTER(handle),
            ctypes.c_ulong,
            ctypes.POINTER(_ObjectAttributes),
            ctypes.POINTER(_IoStatusBlock),
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_void_p,
            ctypes.c_ulong,
        ]
        self.nt_create_file.restype = ctypes.c_long
        self.nt_set_information = ntdll.NtSetInformationFile
        self.nt_set_information.argtypes = [
            handle,
            ctypes.POINTER(_IoStatusBlock),
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_int,
        ]
        self.nt_set_information.restype = ctypes.c_long
        self.status_to_error = ntdll.RtlNtStatusToDosError
        self.status_to_error.argtypes = [ctypes.c_long]
        self.status_to_error.restype = ctypes.c_ulong
        self.get_security = advapi32.GetKernelObjectSecurity
        self.get_security.argtypes = [handle, dword, ctypes.c_void_p, dword, ctypes.POINTER(dword)]
        self.set_security = advapi32.SetKernelObjectSecurity
        self.set_security.argtypes = [handle, dword, ctypes.c_void_p]
        self.descriptor_control = advapi32.GetSecurityDescriptorControl
        self.descriptor_control.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(wintypes.WORD),
            ctypes.POINTER(dword),
        ]
        self.set_descriptor_control = advapi32.SetSecurityDescriptorControl
        self.set_descriptor_control.argtypes = [ctypes.c_void_p, wintypes.WORD, wintypes.WORD]
        self.descriptor_length = advapi32.GetSecurityDescriptorLength
        self.descriptor_length.argtypes = [ctypes.c_void_p]
        self.descriptor_length.restype = dword
        self.from_sddl = advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW
        self.from_sddl.argtypes = [wintypes.LPCWSTR, dword, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
        self.create_private = advapi32.CreatePrivateObjectSecurityEx
        self.create_private.argtypes = [
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_void_p,
            wintypes.BOOL,
            wintypes.ULONG,
            handle,
            ctypes.POINTER(_GenericMapping),
        ]
        self.destroy_private = advapi32.DestroyPrivateObjectSecurity
        self.destroy_private.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        self.open_process_token = advapi32.OpenProcessToken
        self.open_process_token.argtypes = [handle, dword, ctypes.POINTER(handle)]
        self.token_information = advapi32.GetTokenInformation
        self.token_information.argtypes = [handle, ctypes.c_int, ctypes.c_void_p, dword, ctypes.POINTER(dword)]
        self.sid_to_string = advapi32.ConvertSidToStringSidW
        self.sid_to_string.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]


_WIN32_CALLS: _Win32 | None = None


def _win32() -> _Win32:
    global _WIN32_CALLS
    if _WIN32_CALLS is None:
        _WIN32_CALLS = _Win32()
    return _WIN32_CALLS


def _last_error() -> OSError:
    return ctypes.WinError(ctypes.get_last_error())


def _close(handle: int | None) -> None:
    if handle:
        _win32().close_handle(handle)


def _open_relative(
    directory: int,
    name: str,
    access: int,
    disposition: int = _FILE_OPEN,
    options: int = 0,
    *,
    share: int = _SHARE_READ_WRITE,
    attributes: int = 0,
    security: int | None = None,
) -> int:
    """Open or create one name inside an open folder, never following a link (NtCreateFile, root handle)."""

    if not name or name in (".", "..") or any(character in name for character in "\\/:\x00"):
        raise RuntimeError("restore target contains an invalid folder name")
    native = _win32()
    length = len(name.encode("utf-16-le"))
    object_name = _UnicodeString(length, length, name)
    object_attributes = _ObjectAttributes(
        ctypes.sizeof(_ObjectAttributes),
        directory,
        ctypes.pointer(object_name),
        _OBJ_CASE_INSENSITIVE,
        security,
        None,
    )
    handle = wintypes.HANDLE()
    status_block = _IoStatusBlock()
    status = native.nt_create_file(
        ctypes.byref(handle),
        access | _SYNCHRONIZE,
        ctypes.byref(object_attributes),
        ctypes.byref(status_block),
        None,
        attributes,
        share,
        disposition,
        options | _FILE_SYNCHRONOUS_IO_NONALERT | _FILE_OPEN_REPARSE_POINT,
        None,
        0,
    )
    if status < 0:
        raise ctypes.WinError(native.status_to_error(status))
    return int(handle.value)


def _set_information(handle: int, information: Any, information_class: int) -> None:
    native = _win32()
    status_block = _IoStatusBlock()
    status = native.nt_set_information(
        handle,
        ctypes.byref(status_block),
        ctypes.byref(information),
        ctypes.sizeof(information),
        information_class,
    )
    if status < 0:
        raise ctypes.WinError(native.status_to_error(status))


def _information(handle: int) -> _FileInformation:
    information = _FileInformation()
    if not _win32().file_information(handle, ctypes.byref(information)):
        raise _last_error()
    return information


def _identity(information: _FileInformation) -> tuple[int, int]:
    return (
        int(information.dwVolumeSerialNumber),
        (int(information.nFileIndexHigh) << 32) | int(information.nFileIndexLow),
    )


def _final_path(handle: int) -> str:
    buffer = ctypes.create_unicode_buffer(32768)
    length = _win32().final_path(handle, buffer, len(buffer), 0)
    if length == 0:
        raise _last_error()
    if length >= len(buffer):
        raise RuntimeError("restore target path is too long")
    text = buffer.value
    if text.startswith("\\\\?\\UNC\\") or not text.startswith("\\\\?\\"):
        raise RuntimeError("restore target must be on a local drive")
    return text[4:]


def _directory_entries(handle: int, limit: int | None = None) -> list[tuple[str, int, int]]:
    """The names in an open folder, with their attributes and file IDs, read through the folder's own handle."""

    native = _win32()
    buffer = ctypes.create_string_buffer(64 * 1024)
    header_size = ctypes.sizeof(_DirectoryEntry)
    entries: list[tuple[str, int, int]] = []
    information_class = _FILE_ID_BOTH_DIRECTORY_RESTART_INFO
    while True:
        if not native.file_information_ex(handle, information_class, buffer, len(buffer)):
            error = ctypes.get_last_error()
            if error == _ERROR_NO_MORE_FILES:
                return entries
            raise ctypes.WinError(error)
        information_class = _FILE_ID_BOTH_DIRECTORY_INFO
        offset = 0
        while True:
            entry = _DirectoryEntry.from_buffer(buffer, offset)
            name = ctypes.wstring_at(ctypes.addressof(buffer) + offset + header_size, entry.FileNameLength // 2)
            if name not in (".", ".."):
                entries.append((name, int(entry.FileAttributes), int(entry.FileId) & 0xFFFFFFFFFFFFFFFF))
                if limit is not None and len(entries) >= limit:
                    return entries
            if entry.NextEntryOffset == 0:
                break
            offset += entry.NextEntryOffset


def _read_security(handle: int) -> ctypes.Array:
    native = _win32()
    needed = wintypes.DWORD()
    native.get_security(handle, _OWNER_GROUP_DACL_INFORMATION, None, 0, ctypes.byref(needed))
    if needed.value == 0:
        raise _last_error()
    buffer = ctypes.create_string_buffer(needed.value)
    if not native.get_security(handle, _OWNER_GROUP_DACL_INFORMATION, buffer, needed, ctypes.byref(needed)):
        raise _last_error()
    return buffer


def _dacl_protected(descriptor: Any) -> bool:
    control = wintypes.WORD()
    revision = wintypes.DWORD()
    if not _win32().descriptor_control(descriptor, ctypes.byref(control), ctypes.byref(revision)):
        raise _last_error()
    return bool(control.value & _SE_DACL_PROTECTED)


def _mark_auto_inherited(descriptor: Any) -> None:
    # In auto-inherit form the folder's inherited entries stay marked as inherited, and so do its children's.
    flags = _SE_DACL_AUTO_INHERIT_REQ | _SE_DACL_AUTO_INHERITED
    if not _win32().set_descriptor_control(descriptor, flags, flags):
        raise _last_error()


def _write_dacl(handle: int, descriptor: Any) -> None:
    _mark_auto_inherited(descriptor)
    if not _win32().set_security(handle, _DACL_SECURITY_INFORMATION, descriptor):
        raise _last_error()


def _inherited_security(parent: Any, current: Any, directory: bool) -> ctypes.Array:
    """The descriptor `current` would have under `parent`: own entries kept, inherited ones from `parent`."""

    native = _win32()
    created = ctypes.c_void_p()
    mapping = _GenericMapping(*_FILE_GENERIC_MAPPING)
    if not native.create_private(
        parent,
        current,
        ctypes.byref(created),
        None,
        bool(directory),
        _SEF_DACL_AUTO_INHERIT | _SEF_AVOID_PRIVILEGE_CHECK | _SEF_AVOID_OWNER_CHECK,
        None,
        ctypes.byref(mapping),
    ):
        raise _last_error()
    try:
        length = native.descriptor_length(created)
        copy = ctypes.create_string_buffer(length)
        ctypes.memmove(copy, created, length)
        return copy
    finally:
        native.destroy_private(ctypes.byref(created))


def _security_from_sddl(text: str) -> ctypes.c_void_p:
    pointer = ctypes.c_void_p()
    if not _win32().from_sddl(text, 1, ctypes.byref(pointer), None):
        raise _last_error()
    return pointer


def _process_token_information(information_class: int) -> ctypes.Array:
    native = _win32()
    token = wintypes.HANDLE()
    if not native.open_process_token(native.current_process(), _TOKEN_QUERY, ctypes.byref(token)):
        raise _last_error()
    try:
        needed = wintypes.DWORD()
        native.token_information(token, information_class, None, 0, ctypes.byref(needed))
        buffer = ctypes.create_string_buffer(max(needed.value, 4))
        if not native.token_information(token, information_class, buffer, len(buffer), ctypes.byref(needed)):
            raise _last_error()
        return buffer
    finally:
        _close(token.value)


def process_is_elevated() -> bool:
    return bool(wintypes.DWORD.from_buffer(_process_token_information(_TOKEN_ELEVATION)).value)


def current_user_sid() -> str:
    native = _win32()
    # The record's SID pointer leads into the record itself, so the record is kept until the SID is turned into text.
    record = _process_token_information(_TOKEN_USER)
    sid = ctypes.c_void_p.from_buffer(record).value
    text = ctypes.c_void_p()
    if not native.sid_to_string(sid, ctypes.byref(text)):
        raise _last_error()
    try:
        return ctypes.wstring_at(text.value)
    finally:
        native.local_free(text)


def restore_folder_sddl(elevated: bool, user_sid: str | None = None) -> str:
    """Protected permissions for the folder Restic writes into: Administrators and SYSTEM only when elevated.

    Without elevation Restic runs with the user's own rights, so there is no boundary to keep: the user is
    added.
    """

    administrators_and_system = "(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
    if elevated:
        return "O:BAD:PAI" + administrators_and_system
    if not isinstance(user_sid, str) or not re.fullmatch(r"S-1-\d+(-\d+)+", user_sid):
        raise RuntimeError("the current Windows account could not be identified")
    return "D:PAI" + administrators_and_system + f"(A;OICI;FA;;;{user_sid})"


def _open_target(target: Path) -> int:
    """Open (creating where missing) each folder of `target` from the drive root, relative to the one above."""

    native = _win32()
    absolute = ntpath.normpath(ntpath.abspath(str(target)))
    drive, tail = ntpath.splitdrive(absolute)
    components = [part for part in tail.split("\\") if part]
    if not re.fullmatch(r"[A-Za-z]:", drive) or not components:
        raise RuntimeError("restore target must not be a drive root")
    handle = native.create_file(
        "\\\\?\\" + drive + "\\",
        _FILE_READ_ATTRIBUTES | _SYNCHRONIZE,
        _SHARE_ALL,
        None,
        _OPEN_EXISTING,
        _FILE_FLAG_BACKUP_SEMANTICS,
        None,
    )
    if not handle or handle == ctypes.c_void_p(-1).value:
        raise _last_error()
    try:
        for index, component in enumerate(components):
            last = index == len(components) - 1
            try:
                child = _open_relative(
                    handle,
                    component,
                    _TARGET_ACCESS if last else _FILE_READ_ATTRIBUTES,
                    _FILE_OPEN_IF,
                    _FILE_DIRECTORY_FILE,
                    share=_SHARE_READ_WRITE if last else _SHARE_ALL,
                )
            except NotADirectoryError as error:
                raise RuntimeError("restore target parent must be a normal directory") from error
            _close(handle)
            handle = child
            attributes = _information(handle).dwFileAttributes
            if attributes & _FILE_ATTRIBUTE_REPARSE_POINT:
                raise RuntimeError("restore target must not traverse a reparse point")
            if not attributes & _FILE_ATTRIBUTE_DIRECTORY:
                raise RuntimeError("restore target parent must be a normal directory")
        return int(handle)
    except BaseException:
        _close(handle)
        raise


def _hand_back_entry(
    directory: int, parent: Any, name: str, attributes: int, file_id: int
) -> tuple[int, ctypes.Array] | None:
    """Give one restored file the permissions it inherits in the target, or work them out for a folder.

    A folder is returned open, with its new permissions worked out, for the caller to enter. They are written only
    after everything below it is handed back (deepest first), so the hand-back itself never opens a folder up while
    its contents are still being handed back. That does not close a restored folder to the user: Restic restores each
    folder's owner from the backup, and an owner can always change a folder's permissions, so once Restic has finished
    a folder the user owns, a program running as the user can move into it anything on the drive that it may delete.
    Such an item is handed back like a restored one; links, protected permissions and files with a second name are
    still left alone.
    """

    if attributes & _FILE_ATTRIBUTE_REPARSE_POINT:
        # A link restored from the backup is left exactly as restored, and never followed.
        return None
    is_directory = bool(attributes & _FILE_ATTRIBUTE_DIRECTORY)
    try:
        handle = _open_relative(
            directory,
            name,
            _READ_CONTROL | _WRITE_DAC | _FILE_READ_ATTRIBUTES | (_FILE_LIST_DIRECTORY if is_directory else 0),
            _FILE_OPEN,
            _FILE_DIRECTORY_FILE if is_directory else _FILE_NON_DIRECTORY_FILE,
        )
    except OSError as error:
        # Gone, replaced by another kind of item, or restored with its own permissions that leave Administrators
        # out: Restic set those itself, so nothing below it inherits from the restore folder.
        if getattr(error, "winerror", None) in (2, 3, 5, 32, 267):
            return None
        raise
    keep = False
    try:
        information = _information(handle)
        if information.dwFileAttributes & _FILE_ATTRIBUTE_REPARSE_POINT:
            return None
        if bool(information.dwFileAttributes & _FILE_ATTRIBUTE_DIRECTORY) != is_directory:
            return None
        if file_id and _identity(information)[1] != file_id:
            return None
        # A file with a second name might be reached from outside the restore; its permissions stay as they are.
        if not is_directory and information.nNumberOfLinks != 1:
            return None
        current = _read_security(handle)
        # Restored with its own protected permissions: nothing changes here, and nothing below inherits from
        # above.
        if _dacl_protected(current):
            return None
        updated = _inherited_security(parent, current, is_directory)
        if is_directory:
            # The form it will be written in, so the items below inherit from exactly that.
            _mark_auto_inherited(updated)
            keep = True
            return handle, updated
        _write_dacl(handle, updated)
        return None
    finally:
        if not keep:
            _close(handle)


def _hand_back_tree(directory: int, parent: Any) -> None:
    """Hand back everything below an open folder, one open folder per level, without following any link.

    Each folder below gets its own permissions last, once everything inside it has been handed back.
    """

    stack: list[tuple[int, Any, Any, bool]] = [(directory, parent, iter(_directory_entries(directory)), False)]
    try:
        while stack:
            handle, descriptor, entries, owned = stack[-1]
            entry = next(entries, None)
            if entry is None:
                stack.pop()
                if owned:
                    try:
                        _write_dacl(handle, descriptor)
                    finally:
                        _close(handle)
                continue
            opened = _hand_back_entry(handle, descriptor, *entry)
            if opened is None:
                continue
            child, child_descriptor = opened
            try:
                listing = iter(_directory_entries(child))
            except BaseException:
                _close(child)
                raise
            stack.append((child, child_descriptor, listing, True))
    finally:
        for handle, _descriptor, _entries, owned in stack:
            if owned:
                _close(handle)


def _rename_into(handle: int, directory: int, name: str) -> None:
    encoded = name.encode("utf-16-le")
    name_offset = _RenameInformation.FileNameLength.offset + ctypes.sizeof(ctypes.c_ulong)
    buffer = ctypes.create_string_buffer(max(ctypes.sizeof(_RenameInformation), name_offset + len(encoded)) + 2)
    header = _RenameInformation.from_buffer(buffer)
    header.ReplaceIfExists = 0
    header.RootDirectory = directory
    header.FileNameLength = len(encoded)
    ctypes.memmove(ctypes.addressof(buffer) + name_offset, encoded, len(encoded))
    native = _win32()
    status_block = _IoStatusBlock()
    status = native.nt_set_information(
        handle, ctypes.byref(status_block), buffer, len(buffer), _FILE_RENAME_INFORMATION
    )
    if status < 0:
        raise ctypes.WinError(native.status_to_error(status))


class RestoreFolder:
    """The checked target, held open for the whole restore, and the protected folder Restic writes into."""

    def __init__(self, target: Path) -> None:
        self.target = target
        self.name = RESTORE_FOLDER_PREFIX + uuid.uuid4().hex[:16]
        self.path = ""
        self.target_handle: int | None = None
        self.handle: int | None = None
        self.identity: tuple[int, int] | None = None
        self.permissions = True
        # True once an item stayed behind for a reason other than a name that appeared in the target meanwhile.
        self.left_in_use = False

    @classmethod
    def open(cls, target: Path) -> "RestoreFolder":
        folder = cls(target)
        try:
            folder._prepare()
        except BaseException:
            folder._abandon()
            raise
        return folder

    def _prepare(self) -> None:
        self.target_handle = _open_target(self.target)
        final = _final_path(self.target_handle)
        # A folder above the target swapped for another before it was held open shows up here.
        if ntpath.normcase(ntpath.normpath(final)) != canonical_path(self.target):
            raise RuntimeError("restore target changed while it was being prepared")
        ensure_outside_system_folders(final)
        if _directory_entries(self.target_handle, limit=1):
            raise RuntimeError("restore target became non-empty before restore started")
        flags = wintypes.DWORD()
        native = _win32()
        if not native.volume_information(self.target_handle, None, 0, None, None, ctypes.byref(flags), None, 0):
            raise _last_error()
        self.permissions = bool(flags.value & _FILE_PERSISTENT_ACLS)
        if not self.permissions and flags.value & _FILE_SUPPORTS_REPARSE_POINTS:
            raise RuntimeError("restore target must be on a drive that keeps folder permissions")
        security = None
        if self.permissions:
            elevated = process_is_elevated()
            user_sid = None if elevated else current_user_sid()
            security = _security_from_sddl(restore_folder_sddl(elevated, user_sid))
        try:
            # Created with its protected permissions in the same call, so nobody else ever holds it open.
            self.handle = _open_relative(
                self.target_handle,
                self.name,
                _RESTORE_FOLDER_ACCESS,
                _FILE_CREATE,
                _FILE_DIRECTORY_FILE,
                attributes=_FILE_ATTRIBUTE_HIDDEN,
                security=security.value if security is not None else None,
            )
            if security is not None:
                # The same permissions again, now in auto-inherit form, which a create does not keep.
                _write_dacl(self.handle, security)
        finally:
            if security is not None:
                _win32().local_free(security)
        self.identity = _identity(_information(self.handle))
        self.path = _final_path(self.handle)
        if ntpath.normcase(self.path) != ntpath.normcase(ntpath.join(final, self.name)):
            raise RuntimeError("restore target changed while it was being prepared")
        if _directory_entries(self.handle, limit=1):
            raise RuntimeError("restore target changed while it was being prepared")

    def hand_over(self) -> list[str]:
        """Move what Restic restored into the target with the target's inherited permissions.

        Returns the names left in the restore folder, because the same name appeared in the target meanwhile or
        another program kept using the item (see left_message); the folder is then left visible and open to the
        user.
        """

        try:
            if ntpath.normcase(_final_path(self.handle)) != ntpath.normcase(self.path):
                raise RuntimeError("the restore folder changed during the restore")
            if self.permissions:
                _hand_back_tree(self.handle, _read_security(self.target_handle))
            left: list[str] = []
            deadline = time.monotonic() + _MOVE_RETRY_BUDGET
            for name, _attributes, _file_id in _directory_entries(self.handle):
                error = self._move_in(name, deadline)
                if error is not None:
                    left.append(name)
                    if error != _ERROR_ALREADY_EXISTS:
                        self.left_in_use = True
            if left:
                self._release()
            else:
                self._remove()
            return left
        except BaseException:
            try:
                self._release()
            except Exception:
                pass
            raise
        finally:
            self.close()

    def _move_in(self, name: str, deadline: float) -> int | None:
        """Rename one top-level item into the target by handle, never replacing anything; None once it moved.

        Otherwise returns the Windows error. Access denied and sharing violations, which a program holding a file
        below the item open causes, are tried again until the hand-over's short retry budget runs out.
        """

        delays = list(_MOVE_RETRY_DELAYS)
        while True:
            try:
                entry = _open_relative(self.handle, name, _DELETE | _FILE_READ_ATTRIBUTES)
                try:
                    _rename_into(entry, self.target_handle, name)
                finally:
                    _close(entry)
                return None
            except OSError as error:
                code = getattr(error, "winerror", None) or -1
                if code not in (_ERROR_ACCESS_DENIED, _ERROR_SHARING_VIOLATION) or not delays:
                    return code
                delay = delays.pop(0)
                if time.monotonic() + delay > deadline:
                    return code
                time.sleep(delay)

    def left_message(self) -> str:
        """Why items stayed in the restore folder, and where to find them; a name collision only when it was one."""

        template = _LEFT_IN_RESTORE_FOLDER_IN_USE if self.left_in_use else _LEFT_IN_RESTORE_FOLDER
        return template.format(name=self.name)

    def _release(self) -> None:
        """Leave the restore folder visible, with the permissions it would inherit in the target."""

        if self.handle is None:
            return
        if self.permissions:
            creator = _security_from_sddl("O:SYG:SYD:AI")
            try:
                updated = _inherited_security(_read_security(self.target_handle), creator, True)
            finally:
                _win32().local_free(creator)
            _write_dacl(self.handle, updated)
        visible = _BasicInformation(0, 0, 0, 0, _FILE_ATTRIBUTE_NORMAL)
        _set_information(self.handle, visible, _FILE_BASIC_INFORMATION)

    def _remove(self) -> None:
        """Delete the now empty restore folder, after checking that the name still leads to it."""

        _close(self.handle)
        self.handle = None
        try:
            handle = _open_relative(
                self.target_handle, self.name, _DELETE | _FILE_READ_ATTRIBUTES, _FILE_OPEN, _FILE_DIRECTORY_FILE
            )
        except OSError:
            return
        try:
            if _identity(_information(handle)) == self.identity:
                _set_information(handle, ctypes.c_ubyte(1), _FILE_DISPOSITION_INFORMATION)
        except OSError:
            # An empty folder left behind holds nothing; the user can delete it.
            pass
        finally:
            _close(handle)

    def _abandon(self) -> None:
        if self.handle is not None:
            try:
                self._remove()
            except Exception:
                pass
        self.close()

    def close(self) -> None:
        _close(self.handle)
        self.handle = None
        _close(self.target_handle)
        self.target_handle = None


def validate_includes(includes: list[str], inside_source: bool = False) -> list[str]:
    """The chosen items: each one item's path, as Restic lists it, taken literally.

    That is "/" and then each name, with "/" between names. Without --source it is the path in the
    snapshot (/C/Users/you/... for a whole snapshot, or the path inside the folder that --snapshot
    names, so no drive letter is required); with --source the snapshot folder is the source, so it
    is the item's path inside that source. A path names one item, so the restore can check
    afterwards that every chosen item came back. "*" and "?" cannot occur in a Windows name, so they
    could only be wildcards and are refused.
    """
    if len(includes) > MAX_REPORT_INCLUDES:
        raise ValueError(f"at most {MAX_REPORT_INCLUDES} include patterns are allowed")
    result: list[str] = []
    for pattern in includes:
        if not isinstance(pattern, str) or not pattern:
            raise ValueError("include patterns must not be empty")
        if "\x00" in pattern or len(pattern) > MAX_REPORT_STRING:
            raise ValueError("an include pattern is invalid or too long")
        if (
            not pattern.startswith("/")
            or "\\" in pattern
            or "*" in pattern
            or "?" in pattern
            or any(part in {"", ".", ".."} for part in pattern.split("/")[1:])
        ):
            # The dashboard looks for "an include must be one item's path" to put this in plain words.
            raise ValueError(
                "an include must be one item's path inside the --source folder, starting with / and "
                "with / between names, for example /Taxes/return.pdf for Taxes\\return.pdf in that folder"
                if inside_source
                else "an include must be one item's path as Restic lists it, starting with / and "
                "with / between names, for example /C/Users/you/Documents/report.docx"
            )
        result.append(pattern)
    return result


def restic_literal_pattern(snapshot_path: str) -> str:
    """The Restic include pattern that matches this one snapshot path, and nothing else.

    Restic matches include patterns with Go's filepath.Match rules, where "[" opens a character
    class: "Photos [2020]" would match a folder named "Photos 2" and never itself. "[[]" is a class
    that holds only "[". A "]" outside a class is already literal, validate_includes refuses "*"
    and "?", and on Windows a backslash is a path separator rather than an escape.
    """
    return snapshot_path.replace("[", "[[]")


def _extended_length_path(path: str) -> str:
    # Restic writes restored paths of any length; look for them the same way. Each chosen item's
    # parts are already free of "." and "..", so nothing needs the normalization the prefix skips.
    if os.name != "nt" or path.startswith("\\\\"):
        return path
    return "\\\\?\\" + path


def missing_chosen_items(
    target: Path, chosen: list[str], restore_folder: str = "", left: list[str] | None = None
) -> list[str]:
    """The chosen snapshot paths that Restic did not restore, looked for once it finished.

    Restic restores a chosen item at the target plus its snapshot path (relative to the snapshot
    folder when the selector names one), and leaves the name as it was in the backup. An item below
    a top-level name the hand-over left in the restore folder (`left`, in `restore_folder`) came
    back but was not moved into place, so it is looked for there and not in the target, where the
    same name may now be someone else's. A link counts as restored even when what it points to is
    not there. This only reads.
    """
    base = os.path.abspath(str(target)).rstrip("\\/")
    left_names = {name.casefold() for name in left or ()}
    missing: list[str] = []
    for item in chosen:
        parts = [part for part in item.split("/") if part]
        folder = base
        if restore_folder and parts and parts[0].casefold() in left_names:
            folder = os.path.abspath(restore_folder).rstrip("\\/")
        restored = _extended_length_path(os.sep.join([folder, *parts]))
        if not os.path.lexists(restored):
            missing.append(item)
    return missing


def missing_chosen_items_message(missing: int, chosen: int) -> str:
    # The dashboard looks for "without restoring every chosen item" to put this in plain words, and
    # reads the counts to tell a restore that brought back none of them from one that left some out.
    return (
        f"Restic finished without restoring every chosen item ({missing} of {chosen} missing); "
        "the alternate target was retained for inspection"
    )


def also_not_restored_message(missing: int, chosen: int) -> str:
    """Added to the hand-over's message, which is already in plain words and reaches the person as it is."""
    if chosen == 1:
        counted = "the item you chose was not restored at all"
    elif missing == chosen:
        counted = f"none of the {chosen} items you chose was restored at all"
    else:
        counted = f"{missing} of the {chosen} items you chose {'was' if missing == 1 else 'were'} not restored at all"
    return (
        f"Besides those, {counted}. To try again, choose the folder that holds "
        f"{'it' if missing == 1 else 'them'} and a new empty folder to restore into."
    )


def validate_report_path(
    path: Path,
    repository: Path,
    config: dict[str, Any],
    config_path: Path,
) -> Path:
    report = Path(os.path.abspath(str(path)))
    if paths_overlap(report, repository):
        raise RuntimeError("restore report must be outside the Restic repository")
    protected_files = [config_path]
    for name in ("secret_file", "recovery_key_file"):
        value = config.get(name)
        if isinstance(value, str) and value.strip():
            protected_files.append(Path(value))
    if any(canonical_path(report) == canonical_path(item) for item in protected_files):
        raise RuntimeError("restore report must not replace protected backup configuration")
    if report.exists() and (report.is_dir() or path_is_reparse(report)):
        raise RuntimeError("restore report path must be a normal file path")
    ensure_no_reparse_ancestor(report.parent)
    report.parent.mkdir(parents=True, exist_ok=True)
    ensure_no_reparse_ancestor(report.parent)
    return report


def safe_report_error(error: BaseException) -> str:
    if isinstance(error, ResticReadError):
        return str(error)[:MAX_REPORT_STRING]
    if isinstance(error, (ValueError, RuntimeError, FileNotFoundError)):
        text = str(error)
        lowered = text.casefold()
        if any(token in lowered for token in ("--password-command", "restic_password", "dpapi")):
            return "restore preparation failed; see the protected console log"
        return text[:MAX_REPORT_STRING]
    return "restore failed unexpectedly; see the protected console log"


def atomic_write_report(path: Path, report: dict[str, Any]) -> None:
    payload = json.dumps(
        report, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if len(payload) > MAX_REPORT_BYTES:
        raise ValueError("restore report exceeds its size limit")
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def base_report(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema": REPORT_SCHEMA,
        "schema_version": 1,
        "operation": "restore",
        "drill_kind": "recovery_key_representative" if args.recovery_drill else None,
        # The drill with a recovery key (backups with a password); main() says "none" once the configuration shows that
        # these backups have no password and so no key.
        "credential_source": DRILL_CREDENTIAL_SOURCE_KEY if args.recovery_drill else None,
        "repository": None,
        "repository_id": None,
        "plan_id": None,
        "snapshot_id": None,
        "snapshot_generation": None,
        "snapshot_binding": None,
        "snapshot_subfolder": None,
        "includes": [
            str(item)[:MAX_REPORT_STRING] for item in args.include[:MAX_REPORT_INCLUDES]
        ],
        "target": str(Path(os.path.abspath(str(args.target)))) if args.target else None,
        "started_utc": utc_now(),
        "finished_utc": None,
        "restic_exit_code": None,
        "result": "error",
        "verified": False,
        "partial_target_retained": False,
        "target_preexisted_empty": None,
        "canary_verified": None,
        "canary_sha256": None,
        "canary_bytes": None,
        "sample_policy": None,
        "sample_file_count": None,
        "sample_bytes": None,
        "sample_paths_sha256": None,
        "error": None,
    }


# ---- Find a file in every backup (--find-json) ------------------------------------------------------------------------
# Restore's "Find a file" asks the protected restore manager, inside the restore session that was already approved, to look
# for a name in the backups it lists. It only reads: `restic find` through the backup's cache and, because the manager holds
# the protected run lock, without Restic's own lock. The search has a time budget, looks through the newest backups first,
# in batches that grow, and says how far back it got, so the next request can go on from there.

FIND_SCHEMA = "ResticBackuper.FileSearch.v1"
FIND_TEXT_MIN = 2
FIND_TEXT_MAX = 200
FIND_FORBIDDEN = '\\/:*?"<>|'
FIND_SECONDS_DEFAULT = 20
FIND_SECONDS_MIN = 5
FIND_SECONDS_MAX = 60
FIND_MAX_BATCH = 32
FIND_MAX_PATHS = 100
FIND_MAX_VERSIONS = 10
# Restic matches the pattern against every part of a path, so a name that is part of a folder's name ("doc" in Documents)
# brings back everything inside that folder. Past either limit in one batch the search stops and asks for more of the name.
FIND_MAX_BATCH_BYTES = 32 * 1024 * 1024
FIND_MAX_BATCH_NODES = 100_000
FIND_MAX_LIST_BYTES = 64 * 1024 * 1024
FIND_EXIT_START_MISSING = 4
FIND_INVALID_OUTPUT = "Restic returned unexpected file-search output"
_RESTIC_TIME = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})")
# The job that ends every process this one starts when this one ends (see tie_children_to_this_process). Never closed:
# Windows closes it when this process ends.
_FIND_JOB: Any = None


def find_text_problem(value: Any) -> str:
    """The rule of the shared file-search text rules that `value` breaks first, or "".

    The same rules, in the same order, are in Manage-Restore.ps1, the dashboard and its page, and all four are tested
    against tests/fixtures/file-search-text-cases.json. Only spaces are trimmed. An unpaired surrogate is refused before
    the length is measured, since it has no UTF-16 length of its own.
    """
    if not isinstance(value, str):
        return "EMPTY"
    text = value.strip(" ")
    if not text:
        return "EMPTY"
    for character in text:
        code = ord(character)
        if code < 0x20 or code == 0x7F or 0xD800 <= code <= 0xDFFF:
            return "CONTROL"
    if any(character in FIND_FORBIDDEN for character in text):
        return "FORBIDDEN"
    units = len(text.encode("utf-16-le")) // 2
    if units < FIND_TEXT_MIN:
        return "SHORT"
    if units > FIND_TEXT_MAX:
        return "LONG"
    return ""


def normalize_find_text(value: Any) -> str:
    problem = find_text_problem(value)
    if problem:
        raise ValueError(f"the file search text is invalid ({problem})")
    return str(value).strip(" ")


def find_restic_pattern(text: str) -> str:
    """The Restic pattern for names that hold `text`: always "*" first, so it can never be read as an option.

    Restic matches with Go's filepath.Match, where "[" starts a character class and Windows has no escape character, so
    both brackets match any one character here; find_keep then keeps only names that hold the text itself.
    """
    pattern = "*" + text.replace("[", "?").replace("]", "?") + "*"
    if pattern.startswith("-"):
        raise ValueError("the file search pattern must not look like an option")
    return pattern


def find_fold(text: str) -> str:
    # Restic lowers names with Go's strings.ToLower, one character at a time ("İ" becomes "i", and a sigma at the end
    # of a word stays a sigma); str.lower() handles both differently.
    return "".join(character.lower()[0] for character in text)


def normalize_restic_time(value: Any) -> str | None:
    """A time Restic prints (RFC 3339, up to nine fraction digits, a local offset), in UTC with the 100 ns NTFS keeps.

    The same text is the version key here and in the dashboard, which compares and orders these strings as they are.
    """
    if not isinstance(value, str) or len(value) > 64:
        return None
    match = _RESTIC_TIME.fullmatch(value)
    if match is None:
        return None
    offset = "+00:00" if match.group(3) == "Z" else match.group(3)
    try:
        moment = datetime.fromisoformat(match.group(1) + offset).astimezone(timezone.utc)
    except (ValueError, OverflowError):
        return None
    fraction = (match.group(2) or "").ljust(9, "0")[:7]
    return moment.strftime("%Y-%m-%dT%H:%M:%S") + "." + fraction + "Z"


def tie_children_to_this_process() -> None:
    """Put this process in a job that ends every process in it when this one ends.

    Every Restic a search starts (and the password helper Restic starts) is then in the job from the moment it exists, so
    none can go on reading the backup after the manager has stopped this process. This uses Windows' own job objects, as
    restic_common does for backups; it is a copy because this file must stay standalone.
    """
    global _FIND_JOB
    if os.name != "nt" or _FIND_JOB is not None:
        return

    class BasicLimits(ctypes.Structure):
        _fields_ = [
            ("PerProcessUserTimeLimit", ctypes.c_int64),
            ("PerJobUserTimeLimit", ctypes.c_int64),
            ("LimitFlags", wintypes.DWORD),
            ("MinimumWorkingSetSize", ctypes.c_size_t),
            ("MaximumWorkingSetSize", ctypes.c_size_t),
            ("ActiveProcessLimit", wintypes.DWORD),
            ("Affinity", ctypes.c_size_t),
            ("PriorityClass", wintypes.DWORD),
            ("SchedulingClass", wintypes.DWORD),
        ]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint64) for name in ("Reads", "Writes", "Others", "ReadBytes", "WriteBytes", "OtherBytes")]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("BasicLimitInformation", BasicLimits),
            ("IoInfo", IoCounters),
            ("ProcessMemoryLimit", ctypes.c_size_t),
            ("JobMemoryLimit", ctypes.c_size_t),
            ("PeakProcessMemoryUsed", ctypes.c_size_t),
            ("PeakJobMemoryUsed", ctypes.c_size_t),
        ]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel32.CreateJobObjectW.restype = wintypes.HANDLE
    kernel32.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel32.SetInformationJobObject.restype = wintypes.BOOL
    kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
    kernel32.GetCurrentProcess.argtypes = []
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.CreateJobObjectW(None, None)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    limits = ExtendedLimits()
    limits.BasicLimitInformation.LimitFlags = 0x00002000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not kernel32.SetInformationJobObject(handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)) or not (
        kernel32.AssignProcessToJobObject(handle, kernel32.GetCurrentProcess())
    ):
        error = ctypes.get_last_error()
        kernel32.CloseHandle(handle)
        raise RuntimeError(f"the file search could not be tied to this process (Windows error {error})")
    _FIND_JOB = handle


class _BoundedRun:
    __slots__ = ("returncode", "output", "stopped")

    def __init__(self, returncode: int | None, output: bytes, stopped: str) -> None:
        self.returncode = returncode
        self.output = output
        # "" when Restic ended on its own, "deadline" when the time ran out first, "overflow" past the byte limit.
        self.stopped = stopped


def run_restic_bounded(
    base_command: list[str],
    arguments: list[str],
    environment: dict[str, str],
    deadline: float,
    maximum_bytes: int,
) -> _BoundedRun:
    """One Restic read, stopped at `deadline` (time.monotonic) or once it has printed more than `maximum_bytes`."""
    assert_no_password_source_with_flag([*base_command, *arguments], environment)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return _BoundedRun(None, b"", "deadline")
    process = subprocess.Popen(
        [*base_command, *arguments],
        cwd=SCRIPT_DIRECTORY,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        shell=False,
        creationflags=CREATE_NO_WINDOW,
    )
    if process.stdout is None or process.stderr is None:
        process.kill()
        raise RuntimeError("Restic output channels could not be opened")
    stopped: list[str] = []
    guard = threading.Lock()

    def stop(reason: str) -> None:
        with guard:
            if not stopped:
                stopped.append(reason)
        try:
            process.kill()
        except OSError:
            pass

    def drain_diagnostics() -> None:
        # Read only so that Restic never waits on a full pipe; a search reports none of it.
        for _ in iter(lambda: process.stderr.read(64 * 1024), b""):
            pass

    drainer = threading.Thread(target=drain_diagnostics, daemon=True)
    drainer.start()
    timer = threading.Timer(remaining, stop, args=("deadline",))
    timer.daemon = True
    timer.start()
    chunks: list[bytes] = []
    total = 0
    try:
        while True:
            block = process.stdout.read1(64 * 1024)
            if not block:
                break
            total += len(block)
            if total > maximum_bytes:
                stop("overflow")
                break
            chunks.append(block)
    finally:
        timer.cancel()
        try:
            process.stdout.close()
        except OSError:
            pass
    returncode = process.wait()
    drainer.join(timeout=5)
    reason = stopped[0] if stopped else ""
    if reason == "deadline" and returncode == 0:
        # It had finished before the time ran out; only the kill came late.
        reason = ""
    return _BoundedRun(returncode, b"".join(chunks), reason)


class _FindOutOfTime(Exception):
    pass


def bounded_restic_capture(deadline: float) -> Any:
    """run_restic_capture, for a search: stopped at the deadline, and bounded."""

    def capture(
        base_command: list[str],
        arguments: list[str],
        environment: dict[str, str],
        interactive_password: bool,
        operation: str,
    ) -> str:
        if interactive_password:
            # Only backups with a password get here: for backups without one nothing is ever interactive.
            raise ValueError(FILE_SEARCH_KEY_MESSAGE)
        run = run_restic_bounded(base_command, arguments, environment, deadline, FIND_MAX_LIST_BYTES)
        if run.stopped == "deadline":
            raise _FindOutOfTime()
        if run.stopped == "overflow":
            raise RuntimeError(f"Restic returned more output than a file search accepts for the {operation}")
        if run.returncode != 0:
            raise ResticReadError(operation, int(run.returncode or 1))
        return run.output.decode("utf-8", errors="replace")

    return capture


def parse_find_output(output: bytes, batch: set[str]) -> dict[str, list[Any]]:
    """What `restic find --json` printed for one batch: each backup that had matches, with them.

    Restic 0.19.1 prints one array of {"matches": [...], "hits": N, "snapshot": "<id>"}, one object for each backup that
    has a match. Anything else, a count that does not add up or a backup that was not asked for is not used.
    """
    try:
        value = json.loads(output.decode("utf-8", errors="strict"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(FIND_INVALID_OUTPUT) from error
    if not isinstance(value, list):
        raise ValueError(FIND_INVALID_OUTPUT)
    found: dict[str, list[Any]] = {}
    for item in value:
        if not isinstance(item, dict) or set(item) != {"matches", "hits", "snapshot"}:
            raise ValueError(FIND_INVALID_OUTPUT)
        matches, hits, snapshot_id = item["matches"], item["hits"], item["snapshot"]
        if (
            not isinstance(matches, list)
            or isinstance(hits, bool)
            or not isinstance(hits, int)
            or hits != len(matches)
            or not isinstance(snapshot_id, str)
            or snapshot_id not in batch
            or snapshot_id in found
        ):
            raise ValueError(FIND_INVALID_OUTPUT)
        found[snapshot_id] = matches
    return found


def find_keep(node: Any, needle: str) -> tuple[str, str, int, str | None] | None:
    """A file or folder whose own name holds the text, as (type, path, size, modified), or None.

    Restic also prints everything inside a folder whose name matches, links and other kinds of items, and a path is
    used only in the form a folder listing gives it (the same rules as the dashboard's TryNormalizeRestoreFlowTreePath).
    """
    if not isinstance(node, dict):
        return None
    kind, path = node.get("type"), node.get("path")
    if kind not in ("file", "dir") or not isinstance(path, str) or len(path) > MAX_REPORT_STRING:
        return None
    parts = path.split("/")
    if (
        not path.startswith("/")
        or "\\" in path
        or "\x00" in path
        or any(part in ("", ".", "..") for part in parts[1:])
    ):
        return None
    if needle not in find_fold(parts[-1]):
        return None
    size = node.get("size", 0) if kind == "file" else 0
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        return None
    return kind, path, size, normalize_restic_time(node.get("mtime")) if kind == "file" else None


class FindResults:
    """Every file and folder found, by type and path, and each of its versions (a size and a change time; a folder has one)."""

    def __init__(self) -> None:
        self.entries: dict[tuple[str, str], dict[tuple[Any, ...], dict[str, Any]]] = {}
        self.skipped = 0

    def add(self, snapshot_id: str, snapshot_time: str, binding_state: str, nodes: list[Any], needle: str) -> None:
        seen: set[tuple[str, str]] = set()
        for node in nodes:
            kept = find_keep(node, needle)
            if kept is None:
                self.skipped += 1
                continue
            kind, path, size, modified = kept
            if (kind, path) in seen:
                continue
            seen.add((kind, path))
            versions = self.entries.setdefault((kind, path), {})
            key: tuple[Any, ...] = ("dir",) if kind == "dir" else (size, modified or "")
            sighting = (snapshot_time, snapshot_id)
            version = versions.get(key)
            if version is None:
                versions[key] = {
                    "size": size,
                    "mtime": modified,
                    "snapshot_id": snapshot_id,
                    "snapshot_time": snapshot_time,
                    "first_snapshot_id": snapshot_id,
                    "first_snapshot_time": snapshot_time,
                    "backups": 1,
                    "binding_state": binding_state,
                }
                continue
            version["backups"] += 1
            if sighting > (version["snapshot_time"], version["snapshot_id"]):
                version["snapshot_id"], version["snapshot_time"] = snapshot_id, snapshot_time
                version["binding_state"] = binding_state
            if sighting < (version["first_snapshot_time"], version["first_snapshot_id"]):
                version["first_snapshot_id"], version["first_snapshot_time"] = snapshot_id, snapshot_time

    def matches(self) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for (kind, path), versions in self.entries.items():
            ordered = sorted(
                versions.values(), key=lambda item: (item["snapshot_time"], item["snapshot_id"]), reverse=True
            )
            rows.append(
                {
                    "path": path,
                    "name": path.rsplit("/", 1)[-1],
                    "type": kind,
                    "versions_total": len(ordered),
                    "versions": [
                        {
                            **version,
                            "snapshot_time": version["snapshot_time"] or None,
                            "first_snapshot_time": version["first_snapshot_time"] or None,
                        }
                        for version in ordered[:FIND_MAX_VERSIONS]
                    ],
                }
            )
        # The most recently seen first, then by path.
        rows.sort(key=lambda row: row["path"].casefold())
        rows.sort(key=lambda row: row["versions"][0]["snapshot_time"] or "", reverse=True)
        return rows[:FIND_MAX_PATHS]


def run_file_search(
    args: argparse.Namespace,
    command: list[str],
    environment: dict[str, str],
    config: dict[str, Any],
    repository: Path,
    started: float,
) -> int:
    """Look for args.find_text in the backups --list-snapshots-json lists, from the newest (or from
    --find-from-snapshot) towards the oldest, until the time is up, and emit what was found as one JSON object.

    The time goes first to the list of backups and then to batches of 1, 2, 4 ... 32 backups, each made only as large
    as the time left allows at the rate of the one before it. A batch that the deadline cuts is not counted: Restic
    prints nothing for a backup without matches, so what a cut batch looked through cannot be told.

    The first batch (one backup) runs with whatever time the list left. When the list or that backup takes the rest of
    the time, nothing was searched and the page ends as too_slow; "more" always means at least one backup was searched,
    so going on from it gets further. Otherwise a location that is always slow to list would repeat the same empty page.
    """
    tie_children_to_this_process()
    budget = float(FIND_SECONDS_DEFAULT if args.find_seconds is None else args.find_seconds)
    deadline = started + budget
    text = args.find_text
    from_id = args.find_from_snapshot
    pattern = find_restic_pattern(text)
    needle = find_fold(text)
    plan = configured_plan(config)
    payload: dict[str, Any] = {
        "schema": FIND_SCHEMA,
        "schema_version": 1,
        "repository": str(repository),
        "binding": {
            "plan_id": plan[0] if plan is not None else None,
            "legacy_match_policy": "exact-host-scheduled-tags-and-sources",
        },
        "query": {"text": text, "from_snapshot_id": from_id},
        "status": "more",
        "snapshots_total": 0,
        "snapshots_searched": 0,
        "searched_newest_time": None,
        "searched_oldest_time": None,
        "next_from_snapshot_id": from_id,
        "matches_total": 0,
        "skipped": 0,
        "elapsed_ms": 0,
        "matches": [],
    }

    def finish(status: str, results: FindResults | None = None) -> int:
        payload["status"] = status
        if status == "complete":
            payload["next_from_snapshot_id"] = None
        if results is not None:
            payload["matches_total"] = len(results.entries)
            payload["skipped"] = results.skipped
            payload["matches"] = results.matches()
        payload["elapsed_ms"] = int((time.monotonic() - started) * 1000)
        emit_json(payload)
        return 0

    try:
        snapshots = query_snapshots(
            command, environment, False, config, binding="browse", capture=bounded_restic_capture(deadline)
        )
    except _FindOutOfTime:
        if from_id is None:
            raise RuntimeError("the list of backups could not be read in the time the search has") from None
        # Nothing was searched. The same request can be made again (the next start stays this one), and the dashboard's
        # own list still offers a backup by date.
        return finish("too_slow")
    snapshots.sort(key=snapshot_sort_key, reverse=True)
    ids = [str(item["id"]).lower() for item in snapshots]
    payload["snapshots_total"] = len(snapshots)
    if from_id is None:
        start = 0
    elif from_id in ids:
        start = ids.index(from_id)
    else:
        print("RESTORE FAILED: the backup to search from is no longer in the list", file=sys.stderr)
        return FIND_EXIT_START_MISSING
    if start >= len(snapshots):
        return finish("complete", FindResults())
    payload["next_from_snapshot_id"] = ids[start]
    results = FindResults()
    index = start
    next_size = 1
    rate: float | None = None
    first_batch = True
    while index < len(snapshots):
        size = min(next_size, len(snapshots) - index)
        # The first batch of a request has one backup and runs with whatever time is left, however little (see above).
        if rate is not None:
            remaining = deadline - time.monotonic()
            size = min(size, int(remaining / (rate * 1.25)) if rate > 0 else size)
            if size < 1:
                return finish("more", results)
        batch = snapshots[index : index + size]
        batch_ids = [str(item["id"]).lower() for item in batch]
        arguments = ["find", "--json", "--ignore-case"]
        for snapshot_id in batch_ids:
            arguments.extend(["--snapshot", snapshot_id])
        arguments.extend(["--", pattern])
        batch_started = time.monotonic()
        run = run_restic_bounded(command, arguments, environment, deadline, FIND_MAX_BATCH_BYTES)
        if run.stopped == "deadline":
            return finish("too_slow" if first_batch else "more", results)
        if run.stopped == "overflow":
            return finish("too_broad", results)
        if run.returncode != 0:
            raise ResticReadError("file search", int(run.returncode or 1))
        found = parse_find_output(run.output, set(batch_ids))
        if sum(len(nodes) for nodes in found.values()) > FIND_MAX_BATCH_NODES:
            return finish("too_broad", results)
        for snapshot in batch:
            snapshot_id = str(snapshot["id"]).lower()
            nodes = found.get(snapshot_id)
            if nodes:
                results.add(
                    snapshot_id,
                    normalize_restic_time(snapshot.get("time")) or "",
                    snapshot_binding_state(snapshot, config) or SNAPSHOT_BINDING_CONFIGURATION,
                    nodes,
                    needle,
                )
        if payload["searched_newest_time"] is None:
            payload["searched_newest_time"] = normalize_restic_time(batch[0].get("time"))
        payload["searched_oldest_time"] = normalize_restic_time(batch[-1].get("time"))
        payload["snapshots_searched"] += len(batch)
        index += len(batch)
        payload["next_from_snapshot_id"] = ids[index] if index < len(ids) else None
        if len(results.entries) > FIND_MAX_PATHS:
            return finish("too_many", results)
        rate = (time.monotonic() - batch_started) / len(batch)
        next_size = min(next_size * 2, FIND_MAX_BATCH)
        first_batch = False
    return finish("complete", results)


def emit_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def check_find_arguments(args: argparse.Namespace) -> None:
    find_options = (args.find_text, args.find_from_snapshot, args.find_seconds)
    if not args.find_json:
        if any(value is not None for value in find_options):
            raise ValueError("--find-text, --find-from-snapshot and --find-seconds require --find-json")
        return
    if (
        args.target is not None
        or args.report is not None
        or args.include
        or args.source is not None
        or args.allow_legacy_unbound
        or args.recovery_drill
        or args.tree_path is not None
        or args.snapshot != "latest"
    ):
        raise ValueError("a file search takes only its text, where to start and how long it may take")
    if args.find_text is None or normalize_find_text(args.find_text) != args.find_text:
        raise ValueError("--find-json needs --find-text with the search text as the dashboard checked it")
    if args.find_from_snapshot is not None and not re.fullmatch(r"[0-9a-f]{64}", args.find_from_snapshot):
        raise ValueError("--find-from-snapshot must be a full backup ID")
    if args.find_seconds is not None and not FIND_SECONDS_MIN <= args.find_seconds <= FIND_SECONDS_MAX:
        raise ValueError(f"--find-seconds must be from {FIND_SECONDS_MIN} to {FIND_SECONDS_MAX}")


def main(argv: list[str] | None = None) -> int:
    # A file search's time budget counts from here, so that starting Python and reading settings are in it.
    started = time.monotonic()
    args = parse_args(argv)
    if args.json and not args.list:
        raise ValueError("--json is only valid with --list")
    if args.list and args.json:
        args.list_snapshots_json = True
    selected_actions = sum(
        bool(value)
        for value in (args.list, args.list_snapshots_json, args.list_tree_json, args.target, args.find_json)
    )
    # `--list --json` is one action despite setting the normalized flag above.
    if args.list and args.list_snapshots_json:
        selected_actions -= 1
    if selected_actions > 1:
        raise ValueError("choose only one of snapshot listing, tree listing, file search, or restore")
    check_find_arguments(args)
    if args.report is not None and args.target is None:
        raise ValueError("--report is only valid with --target")
    if args.allow_legacy_unbound and not (args.list_tree_json or args.target is not None):
        raise ValueError("--allow-legacy-unbound is only valid for tree listing or restore")
    if args.source is not None and args.target is None:
        raise ValueError("--source is only valid with --target")
    if args.source is not None and args.recovery_drill:
        raise ValueError("--source cannot be combined with --recovery-drill")
    drill_proof_fields = (args.drill_canary_sha256, args.drill_canary_bytes)
    if args.recovery_drill:
        # Whether a recovery-key file is needed depends on the backups (none for a backup without a password), which the
        # configuration says: that check is made below, once it is loaded.
        if args.target is None or args.report is None:
            raise ValueError(DRILL_ARGUMENTS_MESSAGE)
        if args.allow_legacy_unbound or args.include:
            raise ValueError("a recovery drill does not accept legacy snapshots or caller include patterns")
        if (
            not isinstance(args.drill_canary_sha256, str)
            or not re.fullmatch(r"[0-9a-f]{64}", args.drill_canary_sha256)
            or isinstance(args.drill_canary_bytes, bool)
            or not isinstance(args.drill_canary_bytes, int)
            or args.drill_canary_bytes < 0
            or args.drill_canary_bytes > DRILL_MAX_FILE_BYTES
        ):
            raise ValueError("the recovery-drill canary proof is invalid")
    elif any(value is not None for value in drill_proof_fields):
        raise ValueError("drill canary proof fields require --recovery-drill")
    if args.no_restic_lock and args.target is not None:
        raise ValueError("--no-restic-lock is only valid for listings")
    if args.cache_dir is not None:
        if args.recovery_drill:
            raise ValueError("a recovery drill reads the repository without a cache")
        if (
            not args.cache_dir.is_absolute()
            or not args.cache_dir.is_dir()
            or path_is_reparse(args.cache_dir)
        ):
            raise ValueError("--cache-dir must name an existing local directory")
    # The chosen items are checked before anything else. Run on its own (RECOVERY.md), with no report
    # to bind, restore.py refuses one here, before the configuration is read or Restic is started, so
    # nobody types the repository password only to be told an item is written wrong. A report
    # (--report, which the protected manager passes) is accepted only once it is bound to the
    # snapshot, so a refusal then waits until it is, below, and still comes before anything is
    # restored; the manager gives Restic the stored password, so nobody is asked for it meanwhile.
    includes: list[str] = []
    include_refusal: ValueError | None = None
    if args.target is not None:
        try:
            includes = validate_includes(args.include, inside_source=args.source is not None)
        except ValueError as error:
            if args.report is None:
                raise
            include_refusal = error
    report = base_report(args) if args.report is not None else None
    report_path: Path | None = None
    restore_started = False
    restore_succeeded = False
    environment = restic_child_environment()
    try:
        config_path = args.config.resolve(strict=True)
        config = load_restore_config(config_path)
        access = repository_access(config)
        if access == "no_password":
            # No key exists for these backups, so none is read: a key file given for them is a mistake, and is refused.
            if args.recovery_key_file is not None:
                raise ValueError(NO_KEY_FILE_MESSAGE)
            if report is not None and args.recovery_drill:
                report["credential_source"] = DRILL_CREDENTIAL_SOURCE_NONE
        elif args.recovery_drill and args.recovery_key_file is None:
            raise ValueError(DRILL_ARGUMENTS_MESSAGE)
        configured_repository = Path(config["repository"])
        repository = (args.repository or configured_repository).resolve(strict=True)
        if not (repository / "config").is_file():
            raise FileNotFoundError(f"not an initialized Restic repository: {repository}")
        if args.repository is None:
            actual_serial = volume_serial(repository)
            expected_serial = str(config["repository_volume_serial"]).upper()
            if actual_serial != expected_serial:
                raise RuntimeError(
                    f"repository volume mismatch: expected {expected_serial}, got {actual_serial}; "
                    "use --repository only after verifying a deliberately moved copy"
                )

        if report is not None:
            report["repository"] = str(repository)
            report_path = validate_report_path(args.report, repository, config, config_path)

        restic = choose_existing_path(
            [
                args.restic,
                Path(config.get("restic_executable", "")),
                SCRIPT_DIRECTORY / "restic.exe",
                Path(config.get("recovery_tools_directory", "")) / "restic.exe",
            ],
            "Restic executable",
        )
        command = [
            *restic_executable_prefix(restic),
            "--repo",
            str(repository),
            "--retry-lock",
            "5m",
        ]
        if args.recovery_drill:
            command.extend(["--no-cache", "--no-lock"])
        else:
            if args.cache_dir is not None:
                command.extend(["--cache-dir", str(args.cache_dir)])
            if args.no_restic_lock:
                # Only the protected manager asks for this, for a listing, while it holds the run lock that keeps
                # backups and maintenance from changing the repository. A Restic lock would only add a write and a
                # delete in the backup location (a cloud folder for some plans) around every listing. Run on its own,
                # restore.py holds no run lock and keeps Restic's lock.
                command.append("--no-lock")
        interactive_password = True
        if access == "no_password":
            # The flag is the whole credential: never a password command (not even when an older install's DPAPI file is
            # still there), never a key, and never a prompt, so every Restic below gets stdin closed.
            command.append(NO_PASSWORD_FLAG)
            interactive_password = False
        elif args.recovery_key_file:
            environment["RESTIC_PASSWORD"] = recovery_password(args.recovery_key_file)
            interactive_password = False
        else:
            dpapi_command = password_command(config)
            if dpapi_command:
                command.extend(["--password-command", dpapi_command])
                interactive_password = False
        assert_no_password_source_with_flag(command, environment)

        if args.find_json:
            # Backups without a password are never interactive, so only backups with one can lack both a key and the helper.
            if access == "password" and interactive_password:
                raise ValueError(FILE_SEARCH_KEY_MESSAGE)
            return run_file_search(args, command, environment, config, repository, started)

        if args.list and not args.list_snapshots_json:
            return subprocess.call(
                [*command, "snapshots"],
                cwd=SCRIPT_DIRECTORY,
                stdin=None if interactive_password else subprocess.DEVNULL,
                env=environment,
                shell=False,
                creationflags=CREATE_NO_WINDOW,
            )

        if args.list_snapshots_json:
            repository_id = query_repository_id(command, environment, interactive_password)
            plan = configured_plan(config)
            snapshots = query_snapshots(
                command,
                environment,
                interactive_password,
                config,
                binding="browse",
            )
            snapshots.sort(key=snapshot_sort_key, reverse=True)
            emit_json(
                {
                    "schema": LIST_SCHEMA,
                    "schema_version": 1,
                    "repository": str(repository),
                    "repository_id": repository_id,
                    "binding": {
                        "plan_id": plan[0] if plan is not None else None,
                        "current_config_generation": plan[1] if plan is not None else None,
                        "hostname": config.get("hostname"),
                        "scheduled_tags": configured_tags(config),
                        "sources": config.get("sources") or [],
                        "legacy_match_policy": "exact-host-scheduled-tags-and-sources",
                    },
                    "snapshots": [public_snapshot(item, config) for item in snapshots],
                }
            )
            return 0

        if args.list_tree_json:
            repository_id = query_repository_id(command, environment, interactive_password)
            snapshot, exact_selector = resolve_snapshot(
                args.snapshot,
                command,
                environment,
                interactive_password,
                config,
                allow_legacy_unbound=args.allow_legacy_unbound,
            )
            binding_state = snapshot_binding_state(snapshot, config)
            metadata = (
                snapshot_plan_metadata(snapshot, config)
                if binding_state == SNAPSHOT_BINDING_PLAN
                else None
            )
            tree_arguments = ["ls", "--json", "--", exact_selector]
            if args.tree_path is not None:
                if "\x00" in args.tree_path or len(args.tree_path) > MAX_REPORT_STRING:
                    raise ValueError("tree path is invalid or too long")
                tree_arguments.append(args.tree_path)
            entries = parse_json_stream(
                run_restic_capture(
                    command,
                    tree_arguments,
                    environment,
                    interactive_password,
                    "tree query",
                )
            )
            emit_json(
                {
                    "schema": TREE_SCHEMA,
                    "schema_version": 1,
                    "repository": str(repository),
                    "repository_id": repository_id,
                    "snapshot_id": snapshot["id"].lower(),
                    "snapshot": public_snapshot(snapshot, config),
                    "snapshot_generation": metadata[1] if metadata is not None else None,
                    "snapshot_binding": binding_state,
                    "tree_path": args.tree_path,
                    "entries": entries,
                }
            )
            return 0

        if args.target is None:
            # Preserve the historical no-target behavior as a human snapshot list.
            return subprocess.call(
                [*command, "snapshots"],
                cwd=SCRIPT_DIRECTORY,
                stdin=None if interactive_password else subprocess.DEVNULL,
                env=environment,
                shell=False,
                creationflags=CREATE_NO_WINDOW,
            )

        requested_snapshot = args.snapshot
        if args.source is not None:
            snapshot_part, snapshot_subfolder = split_snapshot_selector(requested_snapshot)
            if snapshot_subfolder is not None:
                raise ValueError("--source cannot be combined with an already subfoldered snapshot selector")
            selected_source = select_configured_source(
                args.source, list(config.get("sources", []))
            )
            requested_snapshot = snapshot_part + ":" + windows_snapshot_path(selected_source)
        snapshot, exact_selector = resolve_snapshot(
            requested_snapshot,
            command,
            environment,
            interactive_password,
            config,
            allow_legacy_unbound=args.allow_legacy_unbound,
        )
        repository_id = query_repository_id(command, environment, interactive_password)
        if report is not None:
            report["repository_id"] = repository_id
            report["snapshot_id"] = snapshot["id"].lower()
            binding_state = snapshot_binding_state(snapshot, config)
            report["snapshot_binding"] = binding_state
            metadata = (
                snapshot_plan_metadata(snapshot, config)
                if binding_state == SNAPSHOT_BINDING_PLAN
                else None
            )
            if metadata is not None:
                report["plan_id"] = metadata[0]
                report["snapshot_generation"] = metadata[1]
            _, report["snapshot_subfolder"] = split_snapshot_selector(requested_snapshot)
        # A refused item, held until the report is bound to the snapshot (see above), so the protected
        # manager accepts the report and passes the refusal on in these words, which the dashboard puts
        # plainly. Nothing has been restored yet.
        if include_refusal is not None:
            raise include_refusal
        if args.recovery_drill:
            canary_file = Path(str(config.get("canary_file", "")))
            canary_snapshot_path = windows_snapshot_path(canary_file)
            source_snapshot_paths = [
                windows_snapshot_path(Path(item)) for item in config.get("sources", [])
            ]
            listing = query_recovery_drill_listing(
                command,
                environment,
                interactive_password,
                exact_selector,
                canary_snapshot_path=canary_snapshot_path,
                source_snapshot_paths=source_snapshot_paths,
            )
            sample = choose_recovery_drill_sample(
                listing,
                canary_snapshot_path=canary_snapshot_path,
                source_snapshot_paths=source_snapshot_paths,
            )
            drill_groups = recovery_drill_restore_groups(
                canary_snapshot_path, int(args.drill_canary_bytes), sample
            )

        target, target_existed = validate_restore_target(
            args.target,
            config,
            config_path,
            repository,
            snapshot.get("paths") if isinstance(snapshot.get("paths"), list) else None,
            allow_system_folders=bool(args.recovery_drill),
        )
        if report is not None:
            report["target"] = str(target)
            report["target_preexisted_empty"] = target_existed

        restore_folder: RestoreFolder | None = None
        left_in_restore_folder: list[str] = []
        if args.recovery_drill:
            # The drill writes only below the protected manager's own drill folder, which the user cannot
            # change.
            target.mkdir(parents=True, exist_ok=True)
            ensure_no_reparse_ancestor(target)
            if any(target.iterdir()):
                raise RuntimeError("restore target became non-empty before restore started")
        else:
            # Held open, with Restic's own protected folder inside it, until the restored files are handed over.
            restore_folder = RestoreFolder.open(target)
        drill_outputs: dict[str, Path] = {}
        if args.recovery_drill:
            returncode = 0
            for group_index, group in enumerate(drill_groups, start=1):
                slot = target / f"sample-{group_index:02d}"
                slot.mkdir()
                ensure_no_reparse_ancestor(slot)
                restore_command = [
                    *command,
                    "restore",
                    snapshot["id"].lower() + ":" + str(group["parent"]),
                    "--target",
                    str(slot),
                    "--overwrite",
                    "never",
                    "--verify",
                    "--exclude-xattr",
                    "*",
                ]
                for item in group["items"]:
                    restore_command.extend(["--include", "/" + str(item["leaf"])])
                restore_started = True
                returncode = subprocess.call(
                    restore_command,
                    cwd=SCRIPT_DIRECTORY,
                    stdin=None if interactive_password else subprocess.DEVNULL,
                    env=environment,
                    shell=False,
                    creationflags=CREATE_NO_WINDOW,
                )
                if returncode != 0:
                    break
                for item in group["items"]:
                    drill_outputs[str(item["path"]).casefold()] = slot / str(item["leaf"])
        else:
            assert restore_folder is not None
            restore_command = [
                *command,
                "restore",
                exact_selector,
                "--target",
                restore_folder.path,
                "--overwrite",
                "never",
                "--verify",
            ]
            for chosen in includes:
                restore_command.extend(["--include", restic_literal_pattern(chosen)])
            restore_started = True
            try:
                returncode = subprocess.call(
                    restore_command,
                    cwd=SCRIPT_DIRECTORY,
                    stdin=None if interactive_password else subprocess.DEVNULL,
                    env=environment,
                    shell=False,
                    creationflags=CREATE_NO_WINDOW,
                )
            finally:
                # Also after a failed restore, so a partial restore is still found in the chosen folder.
                left_in_restore_folder = restore_folder.hand_over()
        # Restic ends a restore that matched nothing with exit code 0 and verifies the nothing it
        # restored, so every chosen item is looked for in the chosen folder, once the restored items
        # have been handed over to it, before the restore counts as done. A hand-over that left items
        # in the restore folder already ends the restore as incomplete and says where they are; the
        # items it left are looked for there, so a chosen item that Restic skipped is still named.
        missing_items: list[str] = []
        if returncode == 0 and includes and restore_folder is not None:
            missing_items = missing_chosen_items(
                target,
                includes,
                restore_folder.path if left_in_restore_folder else "",
                left_in_restore_folder,
            )
        restore_succeeded = returncode == 0 and not left_in_restore_folder and not missing_items
        if report is not None:
            report["restic_exit_code"] = int(returncode)
            report["finished_utc"] = utc_now()
            if returncode == 0 and args.recovery_drill:
                canary_target = drill_outputs[canary_snapshot_path.casefold()]
                ensure_no_reparse_ancestor(canary_target)
                if not canary_target.is_file() or path_is_reparse(canary_target):
                    raise RuntimeError("the protected canary was not restored as one normal file")
                actual_canary_bytes = canary_target.stat().st_size
                actual_canary_sha256 = sha256_file(canary_target)
                if (
                    actual_canary_bytes != args.drill_canary_bytes
                    or actual_canary_sha256 != args.drill_canary_sha256
                ):
                    raise RuntimeError("the restored canary did not match its protected snapshot proof")
                actual_sample_bytes = 0
                expected_files = {canonical_path(canary_target)}
                for item in sample:
                    restored = drill_outputs[str(item["path"]).casefold()]
                    ensure_no_reparse_ancestor(restored)
                    if (
                        not restored.is_file()
                        or path_is_reparse(restored)
                        or restored.stat().st_size != int(item["bytes"])
                    ):
                        raise RuntimeError("a representative drill file did not match its snapshot metadata")
                    actual_sample_bytes += restored.stat().st_size
                    expected_files.add(canonical_path(restored))
                actual_files: set[str] = set()
                for restored_item in target.rglob("*"):
                    if path_is_reparse(restored_item):
                        raise RuntimeError("the recovery-drill target contains a reparse point")
                    if restored_item.is_file():
                        actual_files.add(canonical_path(restored_item))
                if actual_files != expected_files:
                    raise RuntimeError("the recovery-drill file inventory did not match the bounded selection")
                path_manifest = "\n".join(str(item["path"]) for item in sample).encode("utf-8")
                report["canary_verified"] = True
                report["canary_sha256"] = actual_canary_sha256
                report["canary_bytes"] = actual_canary_bytes
                report["sample_policy"] = "one-or-two-bounded-files-per-source-v1"
                report["sample_file_count"] = len(sample)
                report["sample_bytes"] = actual_sample_bytes
                report["sample_paths_sha256"] = hashlib.sha256(path_manifest).hexdigest()
                report["result"] = "verified"
                report["verified"] = True
            elif returncode == 0 and not left_in_restore_folder and not missing_items:
                report["result"] = "verified"
                report["verified"] = True
            elif returncode == 0:
                report["result"] = "partial"
                report["partial_target_retained"] = True
                if left_in_restore_folder:
                    report["error"] = restore_folder.left_message()
                    if missing_items:
                        report["error"] += " " + also_not_restored_message(len(missing_items), len(includes))
                else:
                    report["error"] = missing_chosen_items_message(len(missing_items), len(includes))
            else:
                report["result"] = "partial"
                report["partial_target_retained"] = True
                report["error"] = (
                    f"Restic restore failed with exit code {returncode}; "
                    "the alternate target was retained for inspection"
                )
                if left_in_restore_folder:
                    report["error"] += "; " + restore_folder.left_message()
        if returncode != 0:
            print(
                f"RESTORE INCOMPLETE: Restic exited with {returncode}; "
                f"the partial alternate target was retained at {target}",
                file=sys.stderr,
            )
        elif left_in_restore_folder:
            print(
                "RESTORE INCOMPLETE: some restored items could not be moved into "
                f"{target}; they are in {restore_folder.path}",
                file=sys.stderr,
            )
        elif missing_items:
            print(
                "RESTORE INCOMPLETE: Restic finished without restoring every chosen item; "
                f"the alternate target was retained at {target}. Not restored:",
                file=sys.stderr,
            )
        if left_in_restore_folder and missing_items:
            print("Not restored at all:", file=sys.stderr)
        for item in missing_items:
            print(f"  {item}", file=sys.stderr)
        if report is not None:
            atomic_write_report(report_path, report)
        if returncode == 0 and (left_in_restore_folder or missing_items):
            return 1
        return int(returncode)
    except Exception as error:
        if report is not None:
            report["finished_utc"] = utc_now()
            if restore_started:
                report["result"] = "partial"
                report["partial_target_retained"] = True
                report["error"] = (
                    "restore or its independent validation failed; "
                    "the alternate target was retained for inspection"
                )
            else:
                report["error"] = safe_report_error(error)
        if restore_started:
            print(
                "RESTORE INCOMPLETE: the partial alternate target was retained for inspection",
                file=sys.stderr,
            )
        if report is not None and report_path is not None:
            atomic_write_report(report_path, report)
        raise
    finally:
        environment.pop("RESTIC_PASSWORD", None)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"RESTORE FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
