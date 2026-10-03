"""Shared safety and process helpers for the Rewindle backup engine."""

from __future__ import annotations

from contextlib import AbstractContextManager
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import fnmatch
import hashlib
import json
import math
import msvcrt
import ntpath
import os
from pathlib import Path
import queue
import re
import secrets
import shutil
import stat
import subprocess
import sys
import threading
import time
from typing import Any, Callable
import uuid


PROJECT_DIRECTORY = Path(__file__).resolve().parent
DEFAULT_CONFIG = PROJECT_DIRECTORY / "backup-config.json"
PROTECTED_CONFIG = Path(r"C:\Program Files\ResticBackuper\backup-config.json")
PROTECTED_STATE_DIRECTORY = Path(r"C:\ProgramData\ResticBackuper")
SOURCE_UPDATE_JOURNAL_NAME = "source-update.journal.json"
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
CREATE_NEW_PROCESS_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
ATOMIC_WRITE_ATTEMPTS = 20
ATOMIC_WRITE_MAX_DELAY_SECONDS = 0.5
PROCESS_STOP_TIMEOUT_SECONDS = 10
PROCESS_POLL_INTERVAL_SECONDS = 0.1
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
CANCEL_EVENT_PREFIX = r"Local\ResticBackuper.Cancel."
CANCEL_CHANNEL_ID_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CANCEL_EVENT_NAME_ENV = "RESTICBACKUPER_CANCEL_EVENT_NAME"
CANCEL_CHANNEL_ID_ENV = "RESTICBACKUPER_CANCEL_CHANNEL_ID"
CANCEL_CHANNEL_FINGERPRINT_ENV = "RESTICBACKUPER_CANCEL_CHANNEL_FINGERPRINT"
CANCEL_LAUNCHER_PID_ENV = "RESTICBACKUPER_LAUNCHER_PID"
CANCEL_LAUNCHER_START_FILETIME_ENV = "RESTICBACKUPER_LAUNCHER_START_FILETIME"
CANCEL_ENVIRONMENT_NAMES = (
    CANCEL_EVENT_NAME_ENV,
    CANCEL_CHANNEL_ID_ENV,
    CANCEL_CHANNEL_FINGERPRINT_ENV,
    CANCEL_LAUNCHER_PID_ENV,
    CANCEL_LAUNCHER_START_FILETIME_ENV,
)
SYNCHRONIZE = 0x00100000
WAIT_OBJECT_0 = 0x00000000
WAIT_TIMEOUT = 0x00000102
CTRL_BREAK_EVENT = 1
SW_HIDE = 0
PLAN_TAG_PREFIX = "restic-backuper-plan:"
GENERATION_TAG_PREFIX = "restic-backuper-generation:"
CLOUD_PLACEHOLDER_POLICIES = frozenset({"strict", "allow"})
REPOSITORY_STORAGE_MODES = frozenset({"local_ntfs", "google_drivefs_stream"})
DEFAULT_REPOSITORY_STORAGE_MODE = "local_ntfs"
GOOGLE_DRIVEFS_FILESYSTEMS = frozenset({"FAT32"})
EXPECTED_DRIVEFS_MY_DRIVE_ROOT = r"G:\My Drive"
EXPECTED_DRIVEFS_PROCESS = "GoogleDriveFS.exe"
MAX_DRIVEFS_OBJECT_BYTES = 4 * 1024**3
MINIMUM_DRIVEFS_CACHE_FREE_BYTES = 10 * 1024**3
DRIVE_FIXED = 3
DRIVE_REMOVABLE = 2
FILE_SUPPORTS_REMOTE_STORAGE = 0x00000100
FILE_ATTRIBUTE_DIRECTORY = 0x00000010
FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400
FILE_ATTRIBUTE_OFFLINE = 0x00001000
FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x00040000
FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000
CLOUD_ONLY_ATTRIBUTE_MASK = (
    FILE_ATTRIBUTE_OFFLINE
    | FILE_ATTRIBUTE_RECALL_ON_OPEN
    | FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS
)
SOURCE_PREFLIGHT_SAMPLE_LIMIT = 20
MAX_CONFIG_GENERATION = 2**63 - 1


@dataclass(frozen=True)
class WindowsVolumeMetadata:
    root: str
    serial: str
    filesystem: str
    label: str
    drive_type: int
    flags: int
    maximum_component_length: int


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _is_retryable_atomic_write_error(error: OSError) -> bool:
    """Return whether a Windows file-sharing race may clear on retry."""
    return (
        isinstance(error, PermissionError)
        or getattr(error, "winerror", None) in {5, 32, 33, 1224}
        or error.errno in {errno.EACCES, errno.EBUSY, errno.EPERM}
    )


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(ATOMIC_WRITE_ATTEMPTS):
        temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as handle:
                json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            return
        except OSError as error:
            if (
                attempt + 1 >= ATOMIC_WRITE_ATTEMPTS
                or not _is_retryable_atomic_write_error(error)
            ):
                raise
            delay = min(
                0.05 * (2**attempt),
                ATOMIC_WRITE_MAX_DELAY_SECONDS,
            )
            time.sleep(delay)
        finally:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                # A stale telemetry temp is preferable to masking the original
                # write result. Every attempt uses a collision-resistant name.
                pass


def _is_within(candidate: Path, parent: Path) -> bool:
    child_text = _normalized_windows_path(candidate)
    parent_text = _normalized_windows_path(parent)
    try:
        return ntpath.commonpath([child_text, parent_text]) == parent_text
    except ValueError:
        return False


def canonical_windows_path(path: str | Path) -> str:
    """Expand existing DOS aliases without following junctions or requiring a leaf."""
    import ctypes

    absolute = ntpath.normpath(ntpath.abspath(str(path)))
    if os.name != "nt":
        return absolute
    get_long_path = ctypes.WinDLL("kernel32", use_last_error=True).GetLongPathNameW
    get_long_path.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
    get_long_path.restype = ctypes.c_uint32
    candidate = absolute
    suffix: list[str] = []
    while True:
        buffer = ctypes.create_unicode_buffer(32768)
        length = get_long_path(candidate, buffer, len(buffer))
        if 0 < length < len(buffer):
            return ntpath.normpath(ntpath.join(buffer.value, *reversed(suffix)))
        if length >= len(buffer):
            raise ValueError("Windows path exceeds the supported length")
        error = ctypes.get_last_error()
        # Missing/offline paths retain lexical names for preflight to diagnose.
        # Access failures must not silently bypass an alias comparison.
        if error not in (2, 3, 15, 21, 53, 67, 123, 161):
            raise ctypes.WinError(error)
        parent, leaf = ntpath.split(candidate)
        if not leaf or parent == candidate:
            return absolute
        suffix.append(leaf)
        candidate = parent


def _normalized_windows_path(path: str | Path) -> str:
    return ntpath.normcase(canonical_windows_path(path))


def _paths_overlap(left: str | Path, right: str | Path) -> bool:
    return _is_within(Path(left), Path(right)) or _is_within(Path(right), Path(left))


def validate_backup_topology(
    sources: list[str | Path],
    protected_paths: dict[str, str | Path],
) -> None:
    """Reject duplicate, nested, or mutually overlapping backup path roles.

    ``protected_paths`` is intentionally caller supplied so repository, recovery,
    install/state, restore, off-site, diagnostic, and maintenance destinations can
    all use the same conservative validator without hard-coded product paths.
    """
    canonical_sources = [canonical_windows_path(item) for item in sources]
    for index, source in enumerate(canonical_sources):
        for other_index in range(index):
            other = canonical_sources[other_index]
            if _paths_overlap(source, other):
                raise ValueError(
                    f"source roots overlap: {other} and {source}"
                )

    canonical_protected: list[tuple[str, str]] = []
    for raw_label, raw_path in protected_paths.items():
        label = str(raw_label).strip()
        if not label:
            raise ValueError("topology path labels must not be empty")
        if raw_path is None or not str(raw_path).strip():
            raise ValueError(f"topology path is empty: {label}")
        canonical_protected.append((label, canonical_windows_path(raw_path)))

    for source in canonical_sources:
        for label, protected in canonical_protected:
            if _paths_overlap(source, protected):
                raise ValueError(
                    f"source and {label} overlap: {source} and {protected}"
                )

    for index, (label, protected) in enumerate(canonical_protected):
        for other_label, other in canonical_protected[:index]:
            if _paths_overlap(protected, other):
                raise ValueError(
                    f"{other_label} and {label} overlap: {other} and {protected}"
                )


def _exclude_can_touch_protected_tree(pattern: str, protected: str) -> bool:
    normalized = pattern.replace("\\", "/").lower()
    if normalized.startswith("!"):
        raise ValueError(f"negated exclude patterns are not allowed: {pattern}")
    components = [part for part in normalized.split("/") if part]
    if components == ["**"]:
        return True
    return any(
        component != "**" and fnmatch.fnmatchcase(protected, component)
        for component in components
    ) or (components and components[-1] == "**")


def repository_storage_mode(config: dict[str, Any]) -> str:
    """Return the explicit repository backend mode with legacy compatibility."""
    mode = config.get(
        "repository_storage_mode",
        DEFAULT_REPOSITORY_STORAGE_MODE,
    )
    if not isinstance(mode, str) or mode not in REPOSITORY_STORAGE_MODES:
        raise ValueError(
            "repository_storage_mode must be one of: "
            + ", ".join(sorted(REPOSITORY_STORAGE_MODES))
        )
    repository_drive, _tail = ntpath.splitdrive(
        ntpath.abspath(str(config.get("repository", "")))
    )
    if (
        repository_drive.casefold() == "g:"
        and mode != "google_drivefs_stream"
    ):
        raise ValueError(
            "a repository on G: requires explicit google_drivefs_stream mode"
        )
    return str(mode)


def load_config(path: Path = DEFAULT_CONFIG, *, require_repository: bool = True) -> dict[str, Any]:
    path = path.resolve(strict=True)
    config = json.loads(path.read_text(encoding="utf-8"))
    required = {
        "repository",
        "repository_volume_serial",
        "restic_executable",
        "recovery_tools_directory",
        "python_executable",
        "state_directory",
        "secret_file",
        "recovery_key_file",
        "exclude_file",
        "canary_file",
        "hostname",
        "scheduled_tag",
        "sources",
        "plan_id",
        "config_generation",
        "source_identities",
        "cloud_placeholder_policy",
    }
    missing = sorted(required - config.keys())
    if missing:
        raise ValueError(f"configuration is missing keys: {', '.join(missing)}")
    if config.get("schema_version") != 1:
        raise ValueError("unsupported backup configuration schema")

    raw_repository_serial = config.get("repository_volume_serial")
    if not isinstance(raw_repository_serial, str) or not re.fullmatch(
        r"[0-9A-Fa-f]{8}", raw_repository_serial
    ):
        raise ValueError(
            "repository_volume_serial must be eight hexadecimal characters"
        )
    config["repository_volume_serial"] = raw_repository_serial.upper()

    storage_mode = repository_storage_mode(config)
    config["repository_storage_mode"] = storage_mode
    raw_drivefs_root = config.get("drivefs_my_drive_root")
    legacy_drivefs_root = config.get("repository_drivefs_root")
    if raw_drivefs_root is None and legacy_drivefs_root is not None:
        raw_drivefs_root = legacy_drivefs_root
    elif (
        raw_drivefs_root is not None
        and legacy_drivefs_root is not None
        and isinstance(raw_drivefs_root, str)
        and isinstance(legacy_drivefs_root, str)
        and _normalized_windows_path(raw_drivefs_root)
        != _normalized_windows_path(legacy_drivefs_root)
    ):
        raise ValueError(
            "drivefs_my_drive_root conflicts with legacy repository_drivefs_root"
        )
    raw_drivefs_cache = config.get("drivefs_cache_directory")
    if (
        storage_mode == "google_drivefs_stream"
        and raw_drivefs_cache is None
        and legacy_drivefs_root is not None
    ):
        local_app_data = os.environ.get("LOCALAPPDATA")
        if local_app_data:
            raw_drivefs_cache = str(Path(local_app_data) / "Google" / "DriveFS")
    if storage_mode == "google_drivefs_stream":
        if (
            not isinstance(raw_drivefs_root, str)
            or not raw_drivefs_root.strip()
            or not ntpath.isabs(raw_drivefs_root)
            or not ntpath.splitdrive(raw_drivefs_root)[0]
        ):
            raise ValueError(
                "drivefs_my_drive_root must be an absolute drive path "
                "for google_drivefs_stream"
            )
        if (
            not isinstance(raw_drivefs_cache, str)
            or not raw_drivefs_cache.strip()
            or not ntpath.isabs(raw_drivefs_cache)
            or not ntpath.splitdrive(raw_drivefs_cache)[0]
        ):
            raise ValueError(
                "drivefs_cache_directory must be an absolute drive path "
                "for google_drivefs_stream"
            )
    elif (
        raw_drivefs_root is not None
        or legacy_drivefs_root is not None
        or raw_drivefs_cache is not None
    ):
        raise ValueError(
            "DriveFS path bindings are only valid with google_drivefs_stream"
        )

    raw_plan_id = config.get("plan_id")
    if not isinstance(raw_plan_id, str):
        raise ValueError("plan_id must be a canonical UUID string")
    try:
        parsed_plan_id = uuid.UUID(raw_plan_id)
    except (ValueError, AttributeError) as error:
        raise ValueError("plan_id must be a canonical UUID string") from error
    canonical_plan_id = str(parsed_plan_id)
    if raw_plan_id != canonical_plan_id:
        raise ValueError("plan_id must be a lowercase canonical UUID string")
    config["plan_id"] = canonical_plan_id

    generation = config.get("config_generation")
    if (
        type(generation) is not int
        or generation <= 0
        or generation > MAX_CONFIG_GENERATION
    ):
        raise ValueError(
            f"config_generation must be an integer from 1 through {MAX_CONFIG_GENERATION}"
        )

    cloud_policy = config.get("cloud_placeholder_policy")
    if cloud_policy not in CLOUD_PLACEHOLDER_POLICIES:
        raise ValueError(
            "cloud_placeholder_policy must be one of: "
            + ", ".join(sorted(CLOUD_PLACEHOLDER_POLICIES))
        )

    anomaly_policy = config.get("change_anomaly")
    if anomaly_policy is not None:
        if not isinstance(anomaly_policy, dict):
            raise ValueError("change_anomaly must be an object when provided")
        allowed_anomaly_keys = {
            "enabled",
            "file_change_ratio",
            "deletion_ratio",
            "data_added_ratio",
            "minimum_changed_files",
        }
        unknown_anomaly_keys = sorted(set(anomaly_policy) - allowed_anomaly_keys)
        if unknown_anomaly_keys:
            raise ValueError(
                "change_anomaly contains unknown keys: "
                + ", ".join(unknown_anomaly_keys)
            )
        if "enabled" in anomaly_policy and type(anomaly_policy["enabled"]) is not bool:
            raise ValueError("change_anomaly.enabled must be true or false")
        for key in ("file_change_ratio", "deletion_ratio", "data_added_ratio"):
            if key not in anomaly_policy:
                continue
            value = anomaly_policy[key]
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or value < 0
                or value > 10
            ):
                raise ValueError(
                    f"change_anomaly.{key} must be a finite number from 0 through 10"
                )
        if "minimum_changed_files" in anomaly_policy:
            minimum = anomaly_policy["minimum_changed_files"]
            if type(minimum) is not int or minimum < 1 or minimum > 1_000_000_000:
                raise ValueError(
                    "change_anomaly.minimum_changed_files must be an integer from 1 through 1000000000"
                )

    for key in (
        "repository",
        "restic_executable",
        "recovery_tools_directory",
        "python_executable",
        "state_directory",
        "secret_file",
        "recovery_key_file",
        "exclude_file",
        "canary_file",
    ):
        config[key] = str(Path(config[key]).resolve(strict=False))
    if storage_mode == "google_drivefs_stream":
        config["drivefs_my_drive_root"] = str(
            Path(raw_drivefs_root).resolve(strict=False)
        )
        config["drivefs_cache_directory"] = str(
            Path(raw_drivefs_cache).resolve(strict=False)
        )
        config.pop("repository_drivefs_root", None)

    restic = Path(config["restic_executable"])
    python = Path(config["python_executable"])
    excludes = Path(config["exclude_file"])
    canary = Path(config["canary_file"])
    if not restic.is_file():
        raise FileNotFoundError(f"Restic executable is missing: {restic}")
    if not python.is_file():
        raise FileNotFoundError(f"Python executable is missing: {python}")
    if not excludes.is_file():
        raise FileNotFoundError(f"exclude file is missing: {excludes}")
    if not canary.is_file():
        raise FileNotFoundError(f"restore canary is missing: {canary}")

    patterns = [
        line.strip()
        for line in excludes.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if not patterns:
        raise ValueError("exclude file has no active patterns")
    for pattern in patterns:
        protected_matches = [
            protected
            for protected in (".git", ".codex-worktrees")
            if _exclude_can_touch_protected_tree(pattern, protected)
        ]
        if protected_matches:
            raise ValueError(
                "exclude pattern could omit protected repository state "
                f"({', '.join(protected_matches)}): {pattern}"
            )

    if not isinstance(config["sources"], list):
        raise ValueError("sources must be a nonempty array")
    sources = [Path(canonical_windows_path(item)) for item in config["sources"]]
    if not sources:
        raise ValueError("sources must be a nonempty array")
    normalized_sources = [_normalized_windows_path(item) for item in sources]
    if len(normalized_sources) != len(set(normalized_sources)):
        raise ValueError("duplicate source path in configuration")
    config["sources"] = [str(item) for item in sources]

    raw_identities = config["source_identities"]
    if not isinstance(raw_identities, dict):
        raise ValueError("source_identities must be an object keyed by source path")
    identities_by_normalized_path: dict[str, dict[str, str]] = {}
    for raw_source, raw_identity in raw_identities.items():
        if not isinstance(raw_source, str) or not raw_source.strip():
            raise ValueError("source_identities contains an invalid source path")
        normalized_source = _normalized_windows_path(raw_source)
        if normalized_source in identities_by_normalized_path:
            raise ValueError("source_identities contains duplicate canonical paths")
        if not isinstance(raw_identity, dict):
            raise ValueError(
                f"source identity must be an object: {canonical_windows_path(raw_source)}"
            )
        expected_serial = raw_identity.get("expected_volume_serial")
        if not isinstance(expected_serial, str) or not re.fullmatch(
            r"[0-9A-Fa-f]{8}", expected_serial
        ):
            raise ValueError(
                "source expected_volume_serial must be eight hexadecimal characters: "
                + canonical_windows_path(raw_source)
            )
        identities_by_normalized_path[normalized_source] = {
            "expected_volume_serial": expected_serial.upper()
        }
    if set(identities_by_normalized_path) != set(normalized_sources):
        missing_identities = sorted(
            canonical_windows_path(source)
            for source, normalized in zip(sources, normalized_sources)
            if normalized not in identities_by_normalized_path
        )
        extra_identities = sorted(
            canonical_windows_path(source)
            for source in raw_identities
            if _normalized_windows_path(source) not in set(normalized_sources)
        )
        details = []
        if missing_identities:
            details.append("missing: " + ", ".join(missing_identities))
        if extra_identities:
            details.append("unknown: " + ", ".join(extra_identities))
        raise ValueError("source_identities does not exactly match sources (" + "; ".join(details) + ")")
    config["source_identities"] = {
        str(source): identities_by_normalized_path[normalized]
        for source, normalized in zip(sources, normalized_sources)
    }

    repository = Path(config["repository"])
    if storage_mode == "google_drivefs_stream":
        drivefs_root = Path(config["drivefs_my_drive_root"])
        if (
            not _is_within(repository, drivefs_root)
            or _normalized_windows_path(repository)
            == _normalized_windows_path(drivefs_root)
        ):
            raise ValueError(
                "repository must be strictly beneath drivefs_my_drive_root"
            )
        for protected_key in (
            "state_directory",
            "secret_file",
            "recovery_key_file",
            "recovery_tools_directory",
            "restic_executable",
            "python_executable",
            "exclude_file",
        ):
            if _is_within(Path(config[protected_key]), drivefs_root):
                raise ValueError(
                    f"{protected_key} must remain outside Google DriveFS"
                )
        cache_directory = Path(config["drivefs_cache_directory"])
        if _is_within(cache_directory, drivefs_root):
            raise ValueError(
                "drivefs_cache_directory must remain outside Google DriveFS"
            )

    topology_paths: dict[str, str | Path] = {
        "repository": repository,
        "recovery_tools_directory": config["recovery_tools_directory"],
        "state_directory": config["state_directory"],
    }
    optional_topology = config.get("topology_paths", {})
    if not isinstance(optional_topology, dict):
        raise ValueError("topology_paths must be an object when provided")
    for label, value in optional_topology.items():
        if label in topology_paths:
            raise ValueError(f"topology_paths repeats reserved role: {label}")
        topology_paths[str(label)] = value
    topology_sources = list(config["sources"])
    state_directory = Path(config["state_directory"])
    canary_source = canary.parent
    if _is_within(canary_source, state_directory):
        exact_canary_sources = [
            source
            for source in topology_sources
            if _normalized_windows_path(source)
            == _normalized_windows_path(canary_source)
        ]
        if len(exact_canary_sources) != 1:
            raise ValueError(
                "the exact protected canary directory must occur once in sources"
            )
        topology_sources = [
            source
            for source in topology_sources
            if _normalized_windows_path(source)
            != _normalized_windows_path(canary_source)
        ]
    validate_backup_topology(topology_sources, topology_paths)
    if require_repository and not (repository / "config").is_file():
        raise FileNotFoundError(f"initialized Restic repository is missing: {repository}")
    return config


def backup_plan_tags(config: dict[str, Any]) -> tuple[str, str]:
    """Return the exact stable plan and generation tags for a snapshot."""
    generation = config["config_generation"]
    if (
        type(generation) is not int
        or generation <= 0
        or generation > MAX_CONFIG_GENERATION
    ):
        raise ValueError("config_generation is outside the supported range")
    return (
        PLAN_TAG_PREFIX + str(config["plan_id"]).lower(),
        GENERATION_TAG_PREFIX + str(generation),
    )


def snapshot_plan_identity(tags: Any) -> tuple[str, int] | None:
    """Parse one canonical plan tag and one canonical positive generation tag."""
    if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
        return None
    plan_tags = [tag for tag in tags if tag.startswith(PLAN_TAG_PREFIX)]
    generation_tags = [
        tag for tag in tags if tag.startswith(GENERATION_TAG_PREFIX)
    ]
    if len(plan_tags) != 1 or len(generation_tags) != 1:
        return None
    raw_plan_id = plan_tags[0][len(PLAN_TAG_PREFIX) :]
    raw_generation = generation_tags[0][len(GENERATION_TAG_PREFIX) :]
    try:
        canonical_plan_id = str(uuid.UUID(raw_plan_id))
    except ValueError:
        return None
    if canonical_plan_id != raw_plan_id:
        return None
    if not re.fullmatch(r"[1-9][0-9]*", raw_generation):
        return None
    generation = int(raw_generation)
    if generation > MAX_CONFIG_GENERATION:
        return None
    return canonical_plan_id, generation


def windows_volume_metadata(path: Path) -> WindowsVolumeMetadata:
    """Read the Windows volume identity and capabilities for a repository path."""
    import ctypes
    from ctypes import wintypes

    root = ntpath.splitdrive(ntpath.abspath(str(path)))[0] + "\\"
    if root == "\\":
        raise ValueError(f"path has no Windows volume: {path}")
    label = ctypes.create_unicode_buffer(261)
    filesystem = ctypes.create_unicode_buffer(261)
    serial = wintypes.DWORD()
    maximum_component = wintypes.DWORD()
    flags = wintypes.DWORD()
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetVolumeInformationW.argtypes = [
        wintypes.LPCWSTR,
        wintypes.LPWSTR,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(wintypes.DWORD),
        ctypes.POINTER(wintypes.DWORD),
        wintypes.LPWSTR,
        wintypes.DWORD,
    ]
    kernel32.GetVolumeInformationW.restype = wintypes.BOOL
    if not kernel32.GetVolumeInformationW(
        root,
        label,
        len(label),
        ctypes.byref(serial),
        ctypes.byref(maximum_component),
        ctypes.byref(flags),
        filesystem,
        len(filesystem),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    kernel32.GetDriveTypeW.argtypes = [wintypes.LPCWSTR]
    kernel32.GetDriveTypeW.restype = wintypes.UINT
    return WindowsVolumeMetadata(
        root=root,
        serial=f"{serial.value:08X}",
        filesystem=filesystem.value.upper(),
        label=label.value,
        drive_type=int(kernel32.GetDriveTypeW(root)),
        flags=int(flags.value),
        maximum_component_length=int(maximum_component.value),
    )


def volume_serial(path: Path) -> str:
    return windows_volume_metadata(path).serial


def _cloud_attribute_classification(attributes: int | None) -> str:
    if type(attributes) is not int or attributes < 0:
        return "unknown"
    if attributes & CLOUD_ONLY_ATTRIBUTE_MASK:
        return "cloud_only"
    return "local"


def _display_windows_path(path: str | Path) -> str:
    """Return a canonical path without a Win32 extended-length prefix."""
    text = str(path)
    if text.startswith("\\\\?\\UNC\\"):
        text = "\\\\" + text[8:]
    elif text.startswith("\\\\?\\"):
        text = text[4:]
    return canonical_windows_path(text)


def _extended_windows_path(path: str | Path) -> Path:
    """Return a Win32 I/O path that remains valid beyond MAX_PATH."""
    canonical = _display_windows_path(path)
    if os.name != "nt":
        return Path(canonical)
    if canonical.startswith("\\\\"):
        return Path("\\\\?\\UNC\\" + canonical[2:])
    return Path("\\\\?\\" + canonical)


def _literal_directory_exclusion_rules(
    exclude_file: Path | None,
) -> tuple[
    tuple[tuple[str, ...], ...],
    tuple[tuple[str, ...], ...],
    tuple[tuple[tuple[str, ...], tuple[str, ...]], ...],
]:
    """Compile only exclusion forms that can safely prune whole directories.

    Restic's full glob language is deliberately not reimplemented here. A rule
    is used for preflight pruning only when every path component is literal,
    except for one whole-component ``**`` wildcard. More complex patterns stay
    fail-closed and their trees are scanned normally.
    """
    if exclude_file is None:
        return (), (), ()
    patterns = [
        line.strip().replace("\\", "/").rstrip("/")
        for line in Path(exclude_file).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    suffixes: set[tuple[str, ...]] = set()
    exact: set[tuple[str, ...]] = set()
    anchored: set[tuple[tuple[str, ...], tuple[str, ...]]] = set()
    for pattern in patterns:
        if pattern.startswith("!"):
            continue
        parts = tuple(
            component.casefold()
            for component in pattern.split("/")
            if component
        )
        if not parts or any(
            any(character in component for character in "*?[")
            and component != "**"
            for component in parts
        ):
            continue
        wildcard_indexes = [
            index for index, component in enumerate(parts) if component == "**"
        ]
        if len(wildcard_indexes) > 1:
            continue
        if wildcard_indexes:
            wildcard = wildcard_indexes[0]
            prefix = parts[:wildcard]
            suffix = parts[wildcard + 1 :]
            if not suffix:
                continue
            if prefix:
                anchored.add((prefix, suffix))
            else:
                suffixes.add(suffix)
            continue
        if re.match(r"^[a-z]:$", parts[0]) or pattern.startswith("//"):
            exact.add(parts)
    return (
        tuple(sorted(suffixes)),
        tuple(sorted(exact)),
        tuple(sorted(anchored)),
    )


def _directory_is_definitely_excluded(
    path: str | Path,
    rules: tuple[
        tuple[tuple[str, ...], ...],
        tuple[tuple[str, ...], ...],
        tuple[tuple[tuple[str, ...], tuple[str, ...]], ...],
    ],
) -> bool:
    normalized = _display_windows_path(path).replace("\\", "/").rstrip("/")
    parts = tuple(
        component.casefold()
        for component in normalized.split("/")
        if component
    )
    suffixes, exact, anchored = rules
    if parts in exact:
        return True
    if any(
        len(parts) >= len(suffix) and parts[-len(suffix) :] == suffix
        for suffix in suffixes
    ):
        return True
    return any(
        len(parts) >= len(prefix) + len(suffix)
        and parts[: len(prefix)] == prefix
        and parts[-len(suffix) :] == suffix
        for prefix, suffix in anchored
    )


def _path_disappeared_during_scan(error: OSError) -> bool:
    return (
        isinstance(error, FileNotFoundError)
        or getattr(error, "winerror", None) in {2, 3}
        or error.errno == errno.ENOENT
    )


def scan_cloud_placeholders(
    source: Path,
    *,
    sample_limit: int = SOURCE_PREFLIGHT_SAMPLE_LIMIT,
    exclude_file: Path | None = None,
) -> dict[str, Any]:
    """Classify a source tree from Windows attributes without opening file data."""
    source_display = Path(_display_windows_path(source))
    source_io = _extended_windows_path(source_display)
    exclusion_rules = _literal_directory_exclusion_rules(exclude_file)
    result: dict[str, Any] = {
        "status": "clear",
        "entries_scanned": 0,
        "cloud_only_count": 0,
        "inaccessible_count": 0,
        "unknown_count": 0,
        "reparse_points_skipped": 0,
        "excluded_directories_skipped": 0,
        "vanished_entries_skipped": 0,
        "samples": [],
    }

    def record_sample(path: str | Path, classification: str, **details: Any) -> None:
        if len(result["samples"]) >= sample_limit:
            return
        sample: dict[str, Any] = {
            "path": _display_windows_path(path),
            "classification": classification,
        }
        sample.update(details)
        result["samples"].append(sample)

    def classify(path: str | Path, stat_result: os.stat_result) -> tuple[str, int | None]:
        attributes = getattr(stat_result, "st_file_attributes", None)
        classification = _cloud_attribute_classification(attributes)
        result["entries_scanned"] += 1
        if classification == "cloud_only":
            result["cloud_only_count"] += 1
            record_sample(
                path,
                classification,
                attributes_hex=f"0x{attributes:08X}",
            )
        elif classification == "unknown":
            result["unknown_count"] += 1
            record_sample(path, classification)
        return classification, attributes

    try:
        root_stat = os.stat(source_io, follow_symlinks=False)
        classify(source_display, root_stat)
    except OSError as error:
        result["inaccessible_count"] += 1
        record_sample(
            source_display,
            "inaccessible",
            winerror=getattr(error, "winerror", None),
            errno=getattr(error, "errno", None),
        )
        result["status"] = "inaccessible"
        return result

    pending = [source_io]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        if (
                            entry.is_dir(follow_symlinks=False)
                            and _directory_is_definitely_excluded(
                                entry.path, exclusion_rules
                            )
                        ):
                            result["excluded_directories_skipped"] += 1
                            continue
                    except OSError as error:
                        if _path_disappeared_during_scan(error):
                            result["vanished_entries_skipped"] += 1
                        else:
                            result["inaccessible_count"] += 1
                            record_sample(
                                entry.path,
                                "inaccessible",
                                winerror=getattr(error, "winerror", None),
                                errno=getattr(error, "errno", None),
                            )
                        continue
                    try:
                        entry_stat = entry.stat(follow_symlinks=False)
                    except OSError as error:
                        if _path_disappeared_during_scan(error):
                            result["vanished_entries_skipped"] += 1
                        else:
                            result["inaccessible_count"] += 1
                            record_sample(
                                entry.path,
                                "inaccessible",
                                winerror=getattr(error, "winerror", None),
                                errno=getattr(error, "errno", None),
                            )
                        continue
                    _classification, attributes = classify(entry.path, entry_stat)
                    if (
                        type(attributes) is int
                        and attributes & FILE_ATTRIBUTE_DIRECTORY
                    ):
                        if attributes & FILE_ATTRIBUTE_REPARSE_POINT:
                            result["reparse_points_skipped"] += 1
                        else:
                            pending.append(Path(entry.path))
        except OSError as error:
            if directory != source_io and _path_disappeared_during_scan(error):
                result["vanished_entries_skipped"] += 1
            else:
                result["inaccessible_count"] += 1
                record_sample(
                    directory,
                    "inaccessible",
                    winerror=getattr(error, "winerror", None),
                    errno=getattr(error, "errno", None),
                )

    if result["inaccessible_count"]:
        result["status"] = "inaccessible"
    elif result["unknown_count"]:
        result["status"] = "unknown"
    elif result["cloud_only_count"]:
        result["status"] = "cloud_only"
    return result


def preflight_sources(
    config: dict[str, Any],
    *,
    volume_serial_reader: Callable[[Path], str] | None = None,
    placeholder_scanner: Callable[[Path], dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Return complete per-source readiness records without invoking Restic."""
    read_serial = volume_serial_reader or volume_serial
    policy = str(config.get("cloud_placeholder_policy", "strict"))
    records: list[dict[str, Any]] = []
    failures: list[str] = []

    for configured_source in config["sources"]:
        canonical = canonical_windows_path(configured_source)
        identity = config["source_identities"].get(configured_source)
        if identity is None:
            identity = next(
                (
                    value
                    for key, value in config["source_identities"].items()
                    if _normalized_windows_path(key) == _normalized_windows_path(canonical)
                ),
                None,
            )
        expected = (
            str(identity.get("expected_volume_serial", "")).upper()
            if isinstance(identity, dict)
            else ""
        )
        record: dict[str, Any] = {
            "configured_path": str(configured_source),
            "canonical_path": canonical,
            "readiness": "pending",
            "expected_volume_serial": expected or None,
            "observed_volume_serial": None,
            "volume_identity": "not_checked",
            "cloud_placeholder_policy": policy,
            "cloud_scan": None,
            "overall_status": "pending",
        }
        source_path = Path(canonical)
        try:
            source_stat = os.stat(source_path, follow_symlinks=False)
        except FileNotFoundError:
            record["readiness"] = "missing"
            record["overall_status"] = "missing"
            failures.append(f"source is missing: {canonical}")
            records.append(record)
            continue
        except OSError as error:
            record["readiness"] = "inaccessible"
            record["overall_status"] = "inaccessible"
            record["access_error"] = {
                "winerror": getattr(error, "winerror", None),
                "errno": getattr(error, "errno", None),
            }
            failures.append(f"source is inaccessible: {canonical}")
            records.append(record)
            continue
        if not stat.S_ISDIR(source_stat.st_mode):
            record["readiness"] = "missing"
            record["overall_status"] = "not_a_directory"
            failures.append(f"source is not a directory: {canonical}")
            records.append(record)
            continue

        record["readiness"] = "ready"
        try:
            observed = read_serial(source_path).upper()
        except OSError as error:
            record["readiness"] = "inaccessible"
            record["volume_identity"] = "unavailable"
            record["overall_status"] = "inaccessible"
            record["volume_error"] = {
                "winerror": getattr(error, "winerror", None),
                "errno": getattr(error, "errno", None),
            }
            failures.append(f"source volume identity is unavailable: {canonical}")
            records.append(record)
            continue
        record["observed_volume_serial"] = observed
        if not expected or observed != expected:
            record["volume_identity"] = "mismatch"
            record["overall_status"] = "volume_mismatch"
            failures.append(
                f"source volume mismatch: {canonical} expected {expected or '<missing>'}, "
                f"observed {observed}"
            )
            records.append(record)
            continue
        record["volume_identity"] = "match"

        try:
            if placeholder_scanner is None:
                configured_excludes = config.get("exclude_file")
                cloud_scan = scan_cloud_placeholders(
                    source_path,
                    exclude_file=(
                        Path(str(configured_excludes))
                        if configured_excludes
                        else None
                    ),
                )
            else:
                cloud_scan = placeholder_scanner(source_path)
        except Exception as error:
            cloud_scan = {
                "status": "unknown",
                "entries_scanned": 0,
                "cloud_only_count": 0,
                "inaccessible_count": 0,
                "unknown_count": 1,
                "reparse_points_skipped": 0,
                "samples": [
                    {
                        "path": canonical,
                        "classification": "unknown",
                        "error_type": type(error).__name__,
                    }
                ],
            }
        record["cloud_scan"] = cloud_scan
        cloud_status = cloud_scan.get("status")
        if cloud_status in {"inaccessible", "unknown"}:
            record["readiness"] = "inaccessible"
            record["overall_status"] = "cloud_classification_" + str(cloud_status)
            failures.append(
                f"source cloud-placeholder classification is {cloud_status}: {canonical}"
            )
        elif cloud_status == "cloud_only" and policy == "strict":
            record["overall_status"] = "cloud_only"
            failures.append(f"source contains cloud-only placeholders: {canonical}")
        elif cloud_status in {"clear", "cloud_only"}:
            record["overall_status"] = "ready"
        else:
            record["readiness"] = "inaccessible"
            record["overall_status"] = "cloud_classification_unknown"
            failures.append(
                f"source cloud-placeholder classification is unknown: {canonical}"
            )
        records.append(record)

    return {
        "schema_version": 1,
        "policy": policy,
        "status": "ready" if not failures else "failed",
        "sources": records,
        "failures": failures,
    }


def validate_repository_volume(config: dict[str, Any]) -> None:
    repository = Path(config["repository"])
    mode = repository_storage_mode(config)
    metadata: WindowsVolumeMetadata | None = None
    if mode == "google_drivefs_stream":
        raw_root = config.get("drivefs_my_drive_root")
        if not isinstance(raw_root, str) or not raw_root.strip():
            raise RuntimeError(
                "google_drivefs_stream requires drivefs_my_drive_root"
            )
        drivefs_root = Path(raw_root)
        if (
            not _is_within(repository, drivefs_root)
            or _normalized_windows_path(repository)
            == _normalized_windows_path(drivefs_root)
        ):
            raise RuntimeError(
                "repository is not strictly beneath the configured Google DriveFS root"
            )
        if not drivefs_root.is_dir():
            raise RuntimeError(
                f"configured Google DriveFS root is unavailable: {drivefs_root}"
            )
        metadata = windows_volume_metadata(repository)
        actual = metadata.serial
    else:
        actual = volume_serial(repository)

    expected = str(config["repository_volume_serial"]).upper()
    if actual != expected:
        raise RuntimeError(
            f"repository volume mismatch: expected {expected}, observed {actual}"
        )
    if metadata is None:
        return
    if metadata.drive_type != DRIVE_FIXED:
        raise RuntimeError(
            "Google DriveFS repository is not on a fixed virtual drive"
        )
    if metadata.filesystem not in GOOGLE_DRIVEFS_FILESYSTEMS:
        raise RuntimeError(
            "Google DriveFS repository filesystem is unsupported: "
            + (metadata.filesystem or "<unknown>")
        )
    if not metadata.flags & FILE_SUPPORTS_REMOTE_STORAGE:
        raise RuntimeError(
            "Google DriveFS repository volume lacks remote-storage capability"
        )
    if metadata.maximum_component_length < 64:
        raise RuntimeError(
            "Google DriveFS repository volume cannot represent Restic object names"
        )


def _probe_repository_atomic_write(repository: Path) -> None:
    """Prove create, durable write, same-directory rename, read, and cleanup."""
    token = secrets.token_hex(16)
    original = repository / f".resticbackuper-readiness-{token}.tmp"
    renamed = repository / f".resticbackuper-readiness-{token}.committed"
    payload = ("ResticBackuper DriveFS readiness " + token + "\n").encode("ascii")
    try:
        with original.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(original, renamed)
        if original.exists() or not renamed.is_file():
            raise RuntimeError(
                "Google DriveFS did not expose the atomic readiness rename"
            )
        with renamed.open("rb") as handle:
            observed = handle.read(len(payload) + 1)
        if observed != payload:
            raise RuntimeError(
                "Google DriveFS readiness probe content did not round-trip"
            )
    finally:
        original.unlink(missing_ok=True)
        renamed.unlink(missing_ok=True)


def _running_drivefs_process_names() -> frozenset[str]:
    """Read exact process image names without optional process libraries."""
    try:
        result = subprocess.run(
            [
                "tasklist.exe",
                "/FO",
                "CSV",
                "/NH",
                "/FI",
                f"IMAGENAME eq {EXPECTED_DRIVEFS_PROCESS}",
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=False,
            creationflags=CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError(
            "could not inspect Google DriveFS process state"
        ) from error
    if result.returncode != 0:
        raise RuntimeError("could not inspect Google DriveFS process state")
    names: set[str] = set()
    for row in csv.reader(result.stdout.splitlines()):
        if row and row[0].casefold().endswith(".exe"):
            names.add(row[0].casefold())
    return frozenset(names)


def _minimum_drivefs_cache_free_bytes(config: dict[str, Any]) -> int:
    raw = config.get("minimum_free_gib", 0)
    if (
        isinstance(raw, bool)
        or not isinstance(raw, (int, float))
        or not math.isfinite(float(raw))
        or float(raw) < 0
    ):
        raise RuntimeError("minimum_free_gib is invalid for DriveFS cache checks")
    return max(
        int(float(raw) * 1024**3),
        MINIMUM_DRIVEFS_CACHE_FREE_BYTES,
    )


def _scan_drivefs_repository_objects(repository: Path) -> dict[str, int]:
    """Inventory every object and enforce DriveFS's strict FAT32 size ceiling."""
    file_count = 0
    total_bytes = 0
    maximum_bytes = 0

    def fail_on_walk_error(error: OSError) -> None:
        raise RuntimeError(
            "could not enumerate every DriveFS repository object"
        ) from error

    for directory, directory_names, file_names in os.walk(
        repository,
        topdown=True,
        onerror=fail_on_walk_error,
        followlinks=False,
    ):
        directory_path = Path(directory)
        for name in directory_names:
            child = directory_path / name
            if child.is_symlink():
                raise RuntimeError(
                    "DriveFS repository contains a symbolic-link directory"
                )
        for name in file_names:
            child = directory_path / name
            if child.is_symlink():
                raise RuntimeError(
                    "DriveFS repository contains a symbolic-link object"
                )
            metadata = child.stat()
            if not stat.S_ISREG(metadata.st_mode):
                raise RuntimeError(
                    "DriveFS repository contains a non-file object"
                )
            size = metadata.st_size
            if size >= MAX_DRIVEFS_OBJECT_BYTES:
                raise RuntimeError(
                    "DriveFS repository object is not strictly smaller than 4 GiB: "
                    + canonical_windows_path(child)
                )
            file_count += 1
            total_bytes += size
            maximum_bytes = max(maximum_bytes, size)
    return {
        "file_count": file_count,
        "total_bytes": total_bytes,
        "maximum_object_bytes": maximum_bytes,
        "object_size_limit_bytes_exclusive": MAX_DRIVEFS_OBJECT_BYTES,
    }


def _validate_drivefs_provider(
    config: dict[str, Any],
    *,
    volume_validated: bool,
) -> dict[str, Any]:
    raw_root = config.get("drivefs_my_drive_root")
    if not isinstance(raw_root, str) or not raw_root.strip():
        raise RuntimeError(
            "google_drivefs_stream requires drivefs_my_drive_root"
        )
    drivefs_root = Path(raw_root)
    repository = Path(config["repository"])
    if (
        _normalized_windows_path(drivefs_root)
        != _normalized_windows_path(EXPECTED_DRIVEFS_MY_DRIVE_ROOT)
    ):
        raise RuntimeError(
            rf"Google DriveFS binding must be exactly {EXPECTED_DRIVEFS_MY_DRIVE_ROOT}"
        )
    if (
        not _is_within(repository, drivefs_root)
        or _normalized_windows_path(repository)
        == _normalized_windows_path(drivefs_root)
    ):
        raise RuntimeError(
            "DriveFS repository must be a strict descendant of "
            + EXPECTED_DRIVEFS_MY_DRIVE_ROOT
        )
    if not drivefs_root.is_dir():
        raise RuntimeError("bound Google DriveFS My Drive root is unavailable")
    if not volume_validated:
        validate_repository_volume(config)

    process_names = _running_drivefs_process_names()
    if EXPECTED_DRIVEFS_PROCESS.casefold() not in process_names:
        raise RuntimeError("Google DriveFS provider process is not running")

    raw_cache = config.get("drivefs_cache_directory")
    if not isinstance(raw_cache, str) or not raw_cache.strip():
        raise RuntimeError(
            "google_drivefs_stream requires drivefs_cache_directory"
        )
    cache_directory = Path(raw_cache)
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("LOCALAPPDATA is unavailable for DriveFS cache binding")
    expected_cache = Path(local_app_data) / "Google" / "DriveFS"
    if (
        _normalized_windows_path(cache_directory)
        != _normalized_windows_path(expected_cache)
    ):
        raise RuntimeError(
            "configured DriveFS cache is not the current user's "
            "Google DriveFS cache"
        )
    if not cache_directory.is_dir():
        raise RuntimeError(
            "configured Google DriveFS cache directory is unavailable"
        )
    protected_local_paths: dict[str, str] = {}
    for name, raw_path, allowed_drive_types in (
        (
            "drivefs_cache_directory",
            str(cache_directory),
            {DRIVE_FIXED},
        ),
        (
            "state_directory",
            config.get("state_directory"),
            {DRIVE_FIXED, DRIVE_REMOVABLE},
        ),
        (
            "recovery_tools_directory",
            config.get("recovery_tools_directory"),
            {DRIVE_FIXED, DRIVE_REMOVABLE},
        ),
    ):
        if not isinstance(raw_path, str) or not raw_path.strip():
            raise RuntimeError(f"google_drivefs_stream requires {name}")
        path = Path(raw_path)
        if (
            not path.is_dir()
            or path.is_symlink()
            or (hasattr(path, "is_junction") and path.is_junction())
        ):
            raise RuntimeError(
                f"{name} is unavailable or is not a normal local directory"
            )
        metadata = windows_volume_metadata(path)
        if (
            metadata.filesystem != "NTFS"
            or metadata.drive_type not in allowed_drive_types
        ):
            raise RuntimeError(f"{name} must remain on a local NTFS volume")
        protected_local_paths[name] = str(path)
    cache_free = shutil.disk_usage(cache_directory).free
    minimum_cache_free = _minimum_drivefs_cache_free_bytes(config)
    if cache_free < minimum_cache_free:
        raise RuntimeError(
            "Google DriveFS cache free space is inadequate: "
            f"{cache_free / 1024**3:.1f} GiB available; "
            f"{minimum_cache_free / 1024**3:.1f} GiB required"
        )
    return {
        "drivefs_root": str(drivefs_root),
        "provider_process": EXPECTED_DRIVEFS_PROCESS,
        "cache_directory": str(cache_directory),
        "cache_free_bytes": cache_free,
        "minimum_cache_free_bytes": minimum_cache_free,
        "protected_local_paths": protected_local_paths,
    }


def validate_repository_storage_readiness(
    config: dict[str, Any],
    *,
    volume_validated: bool = False,
) -> dict[str, Any]:
    """Fail closed when an explicitly configured repository backend is not ready."""
    mode = repository_storage_mode(config)
    if not volume_validated:
        validate_repository_volume(config)
        volume_validated = True
    if mode == "local_ntfs":
        return {"mode": mode, "status": "ready"}

    repository = Path(config["repository"])
    provider = _validate_drivefs_provider(
        config,
        volume_validated=True,
    )
    config_file = repository / "config"
    if not repository.is_dir() or not config_file.is_file():
        raise RuntimeError(
            f"initialized Google DriveFS Restic repository is unavailable: {repository}"
        )
    try:
        with config_file.open("rb") as handle:
            prefix = handle.read(1)
    except OSError as error:
        raise RuntimeError(
            "Google DriveFS Restic repository config is not locally readable"
        ) from error
    if not prefix:
        raise RuntimeError("Google DriveFS Restic repository config is empty")
    inventory = _scan_drivefs_repository_objects(repository)
    try:
        _probe_repository_atomic_write(repository)
    except OSError as error:
        raise RuntimeError(
            "Google DriveFS repository failed its atomic write/readiness probe"
        ) from error
    return {
        "mode": mode,
        "status": "ready",
        "atomic_write_probe": "passed",
        **provider,
        **inventory,
    }


def read_recorded_repository_id(config: dict[str, Any]) -> str | None:
    """Read a non-secret repository ID only from its bound local state record."""
    record_path = Path(config["state_directory"]) / "repository.json"
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None
    if not isinstance(record, dict):
        return None
    if not isinstance(record.get("repository"), str) or (
        _normalized_windows_path(record["repository"])
        != _normalized_windows_path(config["repository"])
    ):
        return None
    repository_id = record.get("repository_id")
    if not isinstance(repository_id, str) or not re.fullmatch(
        r"[0-9A-Fa-f]{64}", repository_id
    ):
        return None
    return repository_id.lower()


def read_pinned_restic_version(config: dict[str, Any]) -> str | None:
    """Return the signed-release version only when it binds the configured EXE."""
    metadata_path = PROJECT_DIRECTORY / "restic-release.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        expected_hash = metadata.get("executable_sha256")
        version = metadata.get("version")
        if (
            not isinstance(expected_hash, str)
            or not re.fullmatch(r"[0-9A-Fa-f]{64}", expected_hash)
            or not isinstance(version, str)
            or not re.fullmatch(r"[0-9A-Za-z.+_-]{1,40}", version)
            or not metadata.get("checksums_signature_verified") is True
        ):
            return None
        if sha256_file(Path(config["restic_executable"])) != expected_hash.lower():
            return None
        return version
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None


def validate_and_record_plan_state(
    config: dict[str, Any],
    state_directory: Path,
) -> dict[str, Any]:
    """Persist the highest observed generation and reject plan/config rollback."""
    state_directory.mkdir(parents=True, exist_ok=True)
    plan_state_path = state_directory / "plan-state.json"
    observed_plan_ids: set[str] = set()
    highest_generation = 0

    def consume(document: Any, label: str, *, required: bool = False) -> None:
        nonlocal highest_generation
        if not isinstance(document, dict):
            if required:
                raise RuntimeError(f"{label} is not a JSON object")
            return
        plan_id = document.get("plan_id")
        generation = document.get("config_generation")
        if plan_id is None and generation is None and not required:
            return
        if (
            not isinstance(plan_id, str)
            or not isinstance(generation, int)
            or isinstance(generation, bool)
            or generation <= 0
            or generation > MAX_CONFIG_GENERATION
        ):
            raise RuntimeError(f"{label} contains an invalid backup-plan identity")
        try:
            canonical_plan_id = str(uuid.UUID(plan_id))
        except ValueError as error:
            raise RuntimeError(
                f"{label} contains an invalid backup-plan identity"
            ) from error
        if canonical_plan_id != plan_id:
            raise RuntimeError(f"{label} contains a noncanonical backup-plan identity")
        observed_plan_ids.add(plan_id)
        highest_generation = max(highest_generation, generation)

    if plan_state_path.exists():
        try:
            plan_state = json.loads(plan_state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError) as error:
            raise RuntimeError("backup plan state is unreadable or corrupt") from error
        if not isinstance(plan_state, dict) or plan_state.get("schema_version") != 1:
            raise RuntimeError("backup plan state has an unsupported schema")
        consume(plan_state, "backup plan state", required=True)

    for name in ("last-success.json", "status.json"):
        history_path = state_directory / name
        if not history_path.is_file():
            continue
        try:
            history = json.loads(history_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError):
            continue
        consume(history, name)

    configured_plan = config["plan_id"]
    configured_generation = config["config_generation"]
    if (
        type(configured_generation) is not int
        or configured_generation <= 0
        or configured_generation > MAX_CONFIG_GENERATION
    ):
        raise RuntimeError("configured config_generation is outside the supported range")
    if observed_plan_ids and observed_plan_ids != {configured_plan}:
        raise RuntimeError(
            "configured plan_id does not match the durable backup plan state"
        )
    if configured_generation < highest_generation:
        raise RuntimeError(
            "config_generation rollback detected: "
            f"configured {configured_generation}, previously observed {highest_generation}"
        )

    record = {
        "schema_version": 1,
        "plan_id": configured_plan,
        "config_generation": max(configured_generation, highest_generation),
        "updated_utc": utc_now(),
    }
    atomic_write_json(plan_state_path, record)
    return record


def ensure_free_space(config: dict[str, Any]) -> int:
    free = shutil.disk_usage(Path(config["repository"]).anchor).free
    minimum = int(float(config.get("minimum_free_gib", 0)) * 1024**3)
    if free < minimum:
        raise RuntimeError(
            f"repository volume has {free / 1024**3:.1f} GiB free; "
            f"at least {minimum / 1024**3:.1f} GiB is required"
        )
    return free


def password_command(config: dict[str, Any]) -> str:
    helper = PROJECT_DIRECTORY / "secret_store.py"
    # Restic parses --password-command with POSIX shellword rules even on
    # Windows. Forward slashes prevent drive paths such as C:\\Users from being
    # split at backslash escapes before CreateProcess receives them.
    arguments = [
        config["python_executable"].replace("\\", "/"),
        "-I",
        "-S",
        "-B",
        str(helper).replace("\\", "/"),
        "reveal",
        "--secret-file",
        config["secret_file"].replace("\\", "/"),
    ]
    return subprocess.list2cmdline(arguments)


def restic_base(config: dict[str, Any], *, json_output: bool = False) -> list[str]:
    cache = Path(config["state_directory"]) / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    command = [
        config["restic_executable"],
        "--repo",
        config["repository"],
        "--password-command",
        password_command(config),
        "--cache-dir",
        str(cache),
        "--retry-lock",
        "5m",
    ]
    if json_output:
        command.append("--json")
    return command


def sanitized_command(command: list[str]) -> list[str]:
    result = list(command)
    try:
        index = result.index("--password-command")
        result[index + 1] = "<DPAPI password command>"
    except (ValueError, IndexError):
        pass
    return result


def process_start_filetime(process_handle: int | None = None) -> str:
    """Return a Windows process creation FILETIME as an exact decimal string."""
    import ctypes
    from ctypes import wintypes

    if os.name != "nt":
        raise OSError("Windows process identity is required")

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetCurrentProcess.argtypes = []
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.GetProcessTimes.argtypes = [
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.FILETIME),
        ctypes.POINTER(wintypes.FILETIME),
        ctypes.POINTER(wintypes.FILETIME),
        ctypes.POINTER(wintypes.FILETIME),
    ]
    kernel32.GetProcessTimes.restype = wintypes.BOOL

    handle = (
        kernel32.GetCurrentProcess()
        if process_handle is None
        else wintypes.HANDLE(process_handle)
    )
    creation = wintypes.FILETIME()
    exit_time = wintypes.FILETIME()
    kernel_time = wintypes.FILETIME()
    user_time = wintypes.FILETIME()
    if not kernel32.GetProcessTimes(
        handle,
        ctypes.byref(creation),
        ctypes.byref(exit_time),
        ctypes.byref(kernel_time),
        ctypes.byref(user_time),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    value = (int(creation.dwHighDateTime) << 32) | int(creation.dwLowDateTime)
    return str(value)


@dataclass(frozen=True)
class CancellationIdentity:
    channel_id: str
    channel_fingerprint: str
    event_name: str
    launcher_pid: int
    launcher_start_filetime: str


class CancellationToken(AbstractContextManager["CancellationToken"]):
    """Read-only view of the launcher's protected per-run cancellation event."""

    def __init__(
        self,
        identity: CancellationIdentity | None = None,
        handle: int | None = None,
    ) -> None:
        self.identity = identity
        self.handle = handle
        self.kernel32 = None
        self.requested_utc: str | None = None
        self.resolution: str | None = None

    @property
    def enabled(self) -> bool:
        return self.identity is not None and self.handle is not None

    @classmethod
    def from_environment(cls, environ: Any = None) -> "CancellationToken":
        values = os.environ if environ is None else environ
        names = CANCEL_ENVIRONMENT_NAMES
        present = [name in values for name in names]
        if not any(present):
            return cls()
        if not all(present):
            missing = [name for name, exists in zip(names, present) if not exists]
            raise ValueError(
                "incomplete launcher cancellation identity: " + ", ".join(missing)
            )

        channel_id = str(values[CANCEL_CHANNEL_ID_ENV])
        event_name = str(values[CANCEL_EVENT_NAME_ENV])
        fingerprint = str(values[CANCEL_CHANNEL_FINGERPRINT_ENV])
        if CANCEL_CHANNEL_ID_PATTERN.fullmatch(channel_id) is None:
            raise ValueError("launcher cancellation channel identifier is invalid")
        expected_name = CANCEL_EVENT_PREFIX + channel_id
        if event_name != expected_name:
            raise ValueError("launcher cancellation event name is not derived from its channel")
        expected_fingerprint = hashlib.sha256(event_name.encode("utf-8")).hexdigest()
        if not secrets.compare_digest(fingerprint, expected_fingerprint):
            raise ValueError("launcher cancellation channel fingerprint is invalid")

        launcher_pid_text = str(values[CANCEL_LAUNCHER_PID_ENV])
        launcher_filetime = str(values[CANCEL_LAUNCHER_START_FILETIME_ENV])
        if (
            not launcher_pid_text.isascii()
            or not launcher_pid_text.isdecimal()
            or not launcher_filetime.isascii()
            or not launcher_filetime.isdecimal()
        ):
            raise ValueError("launcher process identity is invalid")
        launcher_pid = int(launcher_pid_text)
        launcher_start = int(launcher_filetime)
        if not (1 <= launcher_pid <= 0xFFFFFFFF) or not (
            1 <= launcher_start <= 0xFFFFFFFFFFFFFFFF
        ):
            raise ValueError("launcher process identity is out of range")
        if os.name != "nt":
            raise OSError("launcher cancellation events are supported only on Windows")

        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenEventW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.OpenEventW.restype = wintypes.HANDLE
        kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel32.WaitForSingleObject.restype = wintypes.DWORD
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL
        handle = kernel32.OpenEventW(SYNCHRONIZE, False, event_name)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())

        token = cls(
            CancellationIdentity(
                channel_id=channel_id,
                channel_fingerprint=fingerprint,
                event_name=event_name,
                launcher_pid=launcher_pid,
                launcher_start_filetime=launcher_filetime,
            ),
            int(handle),
        )
        token.kernel32 = kernel32
        return token

    def poll(self) -> bool:
        if not self.enabled or self.resolution is not None:
            return False
        if self.kernel32 is None or self.handle is None:
            raise RuntimeError("cancellation event handle is unavailable")
        result = int(self.kernel32.WaitForSingleObject(self.handle, 0))
        if result == WAIT_TIMEOUT:
            return False
        if result != WAIT_OBJECT_0:
            import ctypes

            raise ctypes.WinError(ctypes.get_last_error())
        if self.requested_utc is None:
            self.requested_utc = utc_now()
        return True

    def disarm(self, resolution: str) -> None:
        """Resolve the one-shot request after the child wins the exit race."""
        if not resolution:
            raise ValueError("cancellation resolution must not be empty")
        self.resolution = resolution

    def close(self) -> None:
        if self.handle is not None and self.kernel32 is not None:
            handle = self.handle
            self.handle = None
            self.kernel32.CloseHandle(handle)

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


class BackupCancelled(RuntimeError):
    """Raised only after a cancellation checkpoint or supervised child exit."""

    def __init__(
        self,
        requested_utc: str,
        *,
        signal_sent_utc: str | None = None,
        process_returncode: int | None = None,
        signal_error: str | None = None,
    ) -> None:
        self.requested_utc = requested_utc
        self.signal_sent_utc = signal_sent_utc
        self.process_returncode = process_returncode
        self.signal_error = signal_error
        if signal_error is not None:
            message = f"cancellation signal failed: {signal_error}"
        elif process_returncode is None:
            message = "backup cancelled at a phase checkpoint"
        else:
            message = f"Restic exited {process_returncode} after cancellation"
        super().__init__(message)

    @property
    def cooperative(self) -> bool:
        return self.process_returncode in (None, 130)

    @property
    def outcome(self) -> str:
        if self.process_returncode is None:
            return "cancelled_at_checkpoint"
        if self.process_returncode == 130:
            return "restic_exit_130"
        if self.signal_error is not None:
            return "ctrl_break_signal_failed"
        return f"restic_exit_{self.process_returncode}_after_signal"


CancellationCallback = Callable[[str, str], None]
_CONSOLE_LOCK = threading.Lock()


class _WindowsCtrlBreakConsole(AbstractContextManager["_WindowsCtrlBreakConsole"]):
    """Provide an invisible console shared with a dedicated child process group."""

    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled
        self.allocated = False
        self.locked = False
        self.kernel32 = None

    @property
    def creationflags(self) -> int:
        return CREATE_NEW_PROCESS_GROUP if self.enabled else CREATE_NO_WINDOW

    def __enter__(self) -> "_WindowsCtrlBreakConsole":
        if not self.enabled:
            return self
        if os.name != "nt":
            raise OSError("Ctrl-Break cancellation is supported only on Windows")

        import ctypes
        from ctypes import wintypes

        _CONSOLE_LOCK.acquire()
        self.locked = True
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32.GetConsoleCP.argtypes = []
        kernel32.GetConsoleCP.restype = wintypes.UINT
        kernel32.AllocConsole.argtypes = []
        kernel32.AllocConsole.restype = wintypes.BOOL
        kernel32.FreeConsole.argtypes = []
        kernel32.FreeConsole.restype = wintypes.BOOL
        kernel32.GetConsoleWindow.argtypes = []
        kernel32.GetConsoleWindow.restype = wintypes.HWND
        kernel32.GenerateConsoleCtrlEvent.argtypes = [wintypes.DWORD, wintypes.DWORD]
        kernel32.GenerateConsoleCtrlEvent.restype = wintypes.BOOL
        user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
        user32.ShowWindow.restype = wintypes.BOOL
        user32.IsWindowVisible.argtypes = [wintypes.HWND]
        user32.IsWindowVisible.restype = wintypes.BOOL

        try:
            if kernel32.GetConsoleCP() == 0:
                if not kernel32.AllocConsole():
                    raise ctypes.WinError(ctypes.get_last_error())
                self.allocated = True
                window = kernel32.GetConsoleWindow()
                if window:
                    user32.ShowWindow(window, SW_HIDE)
                    if user32.IsWindowVisible(window):
                        raise RuntimeError(
                            "the private cancellation console could not be hidden safely"
                        )
            self.kernel32 = kernel32
            return self
        except BaseException:
            self.close()
            raise

    def send_ctrl_break(self, process_id: int) -> None:
        if not self.enabled or self.kernel32 is None:
            raise RuntimeError("private cancellation console is not active")
        if not self.kernel32.GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, process_id):
            import ctypes

            raise ctypes.WinError(ctypes.get_last_error())

    def close(self) -> None:
        try:
            if self.allocated and self.kernel32 is not None:
                self.kernel32.FreeConsole()
        finally:
            self.allocated = False
            self.kernel32 = None
            if self.locked:
                self.locked = False
                _CONSOLE_LOCK.release()

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


class _WindowsKillOnCloseJob(AbstractContextManager["_WindowsKillOnCloseJob"]):
    """Keep a process tree tied to the lifetime of its Python supervisor."""

    def __init__(self) -> None:
        self.handle = None
        self.kernel32 = None

    def __enter__(self) -> "_WindowsKillOnCloseJob":
        import ctypes
        from ctypes import wintypes

        class JobObjectBasicLimitInformation(ctypes.Structure):
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
            _fields_ = [
                ("ReadOperationCount", ctypes.c_uint64),
                ("WriteOperationCount", ctypes.c_uint64),
                ("OtherOperationCount", ctypes.c_uint64),
                ("ReadTransferCount", ctypes.c_uint64),
                ("WriteTransferCount", ctypes.c_uint64),
                ("OtherTransferCount", ctypes.c_uint64),
            ]

        class JobObjectExtendedLimitInformation(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", JobObjectBasicLimitInformation),
                ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        kernel32.SetInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        kernel32.SetInformationJobObject.restype = wintypes.BOOL
        kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.CloseHandle.restype = wintypes.BOOL

        handle = kernel32.CreateJobObjectW(None, None)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())

        information = JobObjectExtendedLimitInformation()
        information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel32.SetInformationJobObject(
            handle,
            JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
            ctypes.byref(information),
            ctypes.sizeof(information),
        ):
            error = ctypes.get_last_error()
            kernel32.CloseHandle(handle)
            raise ctypes.WinError(error)

        self.handle = handle
        self.kernel32 = kernel32
        return self

    def assign(self, process: subprocess.Popen[str]) -> None:
        import ctypes
        from ctypes import wintypes

        if self.handle is None or self.kernel32 is None:
            raise RuntimeError("process job is not active")
        process_handle = getattr(process, "_handle", None)
        if process_handle is None:
            raise RuntimeError("Python did not expose the child process handle")
        if not self.kernel32.AssignProcessToJobObject(
            self.handle,
            wintypes.HANDLE(int(process_handle)),
        ):
            error = ctypes.get_last_error()
            if process.poll() is None:
                raise ctypes.WinError(error)

    def close(self) -> None:
        if self.handle is not None and self.kernel32 is not None:
            handle = self.handle
            self.handle = None
            self.kernel32.CloseHandle(handle)

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self.close()


def _stop_process(process: subprocess.Popen[str]) -> None:
    """Best-effort child cleanup that never masks the triggering exception."""
    try:
        if process.poll() is not None:
            return
    except OSError:
        pass
    try:
        process.terminate()
    except OSError:
        pass
    try:
        process.wait(timeout=PROCESS_STOP_TIMEOUT_SECONDS)
        return
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        process.kill()
    except OSError:
        pass
    try:
        process.wait(timeout=PROCESS_STOP_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        pass


def cancellation_checkpoint(
    cancellation: CancellationToken | None,
    on_cancellation: CancellationCallback | None = None,
) -> None:
    """Raise before starting more work when the per-run event is set."""
    if cancellation is None or not cancellation.poll():
        return
    requested_utc = cancellation.requested_utc or utc_now()
    if on_cancellation is not None:
        on_cancellation("requested", requested_utc)
    raise BackupCancelled(requested_utc)


def _child_environment_without_cancellation_identity() -> dict[str, str]:
    """Do not disclose the launcher's privileged control channel to Restic."""
    environment = dict(os.environ)
    for name in CANCEL_ENVIRONMENT_NAMES:
        environment.pop(name, None)
    return environment


def _wait_for_cancellable_process(
    process: subprocess.Popen[str],
    streams: dict[str, Any],
    console: _WindowsCtrlBreakConsole,
    cancellation: CancellationToken | None,
    on_cancellation: CancellationCallback | None,
    on_output: Callable[[str, str], None],
) -> int:
    output_queue: queue.Queue[tuple[str, str | None, BaseException | None]] = (
        queue.Queue()
    )
    readers: list[threading.Thread] = []

    def read_stream(name: str, stream: Any) -> None:
        try:
            for line in stream:
                output_queue.put((name, line, None))
        except BaseException as error:
            output_queue.put((name, None, error))
        finally:
            output_queue.put((name, None, None))

    for name, stream in streams.items():
        reader = threading.Thread(
            target=read_stream,
            args=(name, stream),
            name=f"restic-{name}-reader",
            daemon=True,
        )
        reader.start()
        readers.append(reader)

    finished_streams: set[str] = set()
    cancellation_seen = False
    signal_sent_utc: str | None = None
    signal_error: str | None = None
    try:
        while process.poll() is None or len(finished_streams) != len(streams):
            if (
                not cancellation_seen
                and cancellation is not None
                and cancellation.poll()
                and process.poll() is None
            ):
                cancellation_seen = True
                requested_utc = cancellation.requested_utc or utc_now()
                if on_cancellation is not None:
                    on_cancellation("requested", requested_utc)
                try:
                    console.send_ctrl_break(int(process.pid))
                except BaseException as error:
                    signal_error = str(error)
                    cancellation.disarm("ctrl_break_signal_failed")
                    if on_cancellation is not None:
                        on_cancellation("ctrl_break_signal_failed", utc_now())
                    # The request is resolved and must not be retried or used
                    # to reinterpret a later independent child exit.
                    cancellation_seen = False
                else:
                    signal_sent_utc = utc_now()
                    if on_cancellation is not None:
                        on_cancellation("signal_sent", signal_sent_utc)

            try:
                stream_name, line, reader_error = output_queue.get(
                    timeout=PROCESS_POLL_INTERVAL_SECONDS
                )
            except queue.Empty:
                continue
            if reader_error is not None:
                raise reader_error
            if line is None:
                finished_streams.add(stream_name)
            else:
                on_output(stream_name, line)

        return_code = process.wait()
        for reader in readers:
            reader.join(timeout=PROCESS_STOP_TIMEOUT_SECONDS)
            if reader.is_alive():
                raise RuntimeError("child output reader did not finish")
        if (
            not cancellation_seen
            and cancellation is not None
            and cancellation.poll()
        ):
            # The child result is already final, so a request first observed
            # here must not be reinterpreted by the next phase checkpoint.
            # Preserve success for normal verification and preserve every
            # nonzero result for the caller's ordinary failure handling.
            requested_utc = cancellation.requested_utc or utc_now()
            if on_cancellation is not None:
                on_cancellation("requested", requested_utc)
            resolution = (
                "finished_before_cancellation_took_effect"
                if return_code == 0
                else "child_exit_won_cancellation_race"
            )
            cancellation.disarm(resolution)
            if on_cancellation is not None:
                on_cancellation(resolution, utc_now())
        if cancellation_seen and return_code == 130:
            raise BackupCancelled(
                cancellation.requested_utc or utc_now(),
                signal_sent_utc=signal_sent_utc,
                process_returncode=return_code,
                signal_error=signal_error,
            )
        if cancellation_seen:
            resolution = (
                "ctrl_break_signal_failed"
                if signal_error is not None
                else (
                    "finished_before_cancellation_took_effect"
                    if return_code == 0
                    else "non_130_exit_after_cancellation_signal"
                )
            )
            cancellation.disarm(resolution)
            if on_cancellation is not None:
                on_cancellation(resolution, utc_now())
        return return_code
    except BaseException:
        # Callback, pipe, and supervisor failures still require immediate child
        # containment. Cancellation itself is raised only after the child exits.
        _stop_process(process)
        raise
    finally:
        for stream in streams.values():
            try:
                stream.close()
            except OSError:
                pass


def run_capture(
    command: list[str],
    *,
    cwd: Path = PROJECT_DIRECTORY,
    cancellation: CancellationToken | None = None,
    on_cancellation: CancellationCallback | None = None,
) -> subprocess.CompletedProcess[str]:
    cancellation_checkpoint(cancellation, on_cancellation)
    with _WindowsCtrlBreakConsole(bool(cancellation and cancellation.enabled)) as console:
        with _WindowsKillOnCloseJob() as job:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                shell=False,
                creationflags=console.creationflags,
                env=_child_environment_without_cancellation_identity(),
            )
            assigned = False
            try:
                job.assign(process)
                assigned = True
                assert process.stdout is not None
                assert process.stderr is not None
                output: dict[str, list[str]] = {"stdout": [], "stderr": []}

                def capture(stream_name: str, line: str) -> None:
                    output[stream_name].append(line)

                return_code = _wait_for_cancellable_process(
                    process,
                    {"stdout": process.stdout, "stderr": process.stderr},
                    console,
                    cancellation,
                    on_cancellation,
                    capture,
                )
                return subprocess.CompletedProcess(
                    command,
                    return_code,
                    "".join(output["stdout"]),
                    "".join(output["stderr"]),
                )
            except BaseException:
                if not assigned:
                    _stop_process(process)
                raise


def stream_command(
    command: list[str],
    log_handle,
    on_line: Callable[[str], None] | None = None,
    *,
    cwd: Path = PROJECT_DIRECTORY,
    cancellation: CancellationToken | None = None,
    on_cancellation: CancellationCallback | None = None,
) -> int:
    cancellation_checkpoint(cancellation, on_cancellation)
    with _WindowsCtrlBreakConsole(bool(cancellation and cancellation.enabled)) as console:
        with _WindowsKillOnCloseJob() as job:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                shell=False,
                creationflags=console.creationflags,
                env=_child_environment_without_cancellation_identity(),
            )
            assigned = False
            try:
                job.assign(process)
                assigned = True
                assert process.stdout is not None

                def consume(_stream_name: str, line: str) -> None:
                    log_handle.write(line)
                    log_handle.flush()
                    if on_line is not None:
                        on_line(line.rstrip("\r\n"))

                return _wait_for_cancellable_process(
                    process,
                    {"stdout": process.stdout},
                    console,
                    cancellation,
                    on_cancellation,
                    consume,
                )
            except BaseException:
                if not assigned:
                    _stop_process(process)
                raise


class RunLockUnavailable(RuntimeError):
    """Raised when another protected operation owns byte zero of run.lock."""


class SourceUpdateJournalPresent(RuntimeError):
    """Raised until the protected source manager reconciles an interrupted update."""


class RunLock(AbstractContextManager["RunLock"]):
    def __init__(self, path: Path):
        self.path = path
        self.handle = None

    def __enter__(self) -> "RunLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = self.path.open("a+b", buffering=0)
        self.handle.seek(0, os.SEEK_END)
        if self.handle.tell() == 0:
            self.handle.write(b"\0")
        self.handle.seek(0)
        try:
            msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            self.handle.close()
            self.handle = None
            raise RunLockUnavailable(
                "another backup process already holds the run lock"
            ) from error
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        if self.handle is not None:
            handle = self.handle
            self.handle = None
            try:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            finally:
                # Closing releases Windows byte locks even if seek/unlock fails.
                handle.close()


def _same_windows_path(left: Path, right: Path) -> bool:
    return ntpath.normcase(ntpath.abspath(str(left))) == ntpath.normcase(
        ntpath.abspath(str(right))
    )


def _preliminary_state_directory(config_path: Path) -> Path:
    """Choose only the lock location; authoritative config is loaded later."""
    if _same_windows_path(config_path, PROTECTED_CONFIG):
        return PROTECTED_STATE_DIRECTORY
    preliminary = json.loads(config_path.read_text(encoding="utf-8"))
    if not isinstance(preliminary, dict):
        raise ValueError("backup configuration must be one JSON object")
    state_value = preliminary.get("state_directory")
    if not isinstance(state_value, str) or not state_value:
        raise ValueError("configuration has no valid state_directory for its run lock")
    return Path(state_value).resolve(strict=False)


def load_config_under_lock(
    path: Path = DEFAULT_CONFIG,
    *,
    require_repository: bool = True,
    before_lock: Callable[[], None] | None = None,
    allowed_pending_journals: frozenset[str] = frozenset(),
) -> tuple[dict[str, Any], RunLock]:
    """Acquire the shared byte lock, then load and validate current config.

    Protected scheduled runs choose the fixed ProgramData lock without reading
    configuration first. Disposable/manual configurations read only their lock
    directory before locking, then reload the full configuration and reject a
    state-directory change. Thus a process paused before Lock cannot later run
    source paths that a completed source-manager transaction replaced.
    """
    config_path = path.resolve(strict=True)
    lock_state = _preliminary_state_directory(config_path)
    if before_lock is not None:
        before_lock()
    run_lock = RunLock(lock_state / "run.lock")
    run_lock.__enter__()
    try:
        pending_journals = (
            lock_state / SOURCE_UPDATE_JOURNAL_NAME,
            lock_state / "repository-relocation.journal.json",
            lock_state / "plan-migration.journal.json",
            lock_state / "credential-rotation.journal.json",
        )
        pending_journal = next(
            (
                journal
                for journal in pending_journals
                if journal.name not in allowed_pending_journals
                and (journal.exists() or journal.is_symlink())
            ),
            None,
        )
        if pending_journal is not None:
            message = (
                f"a pending protected-operation journal ({pending_journal.name}) "
                "blocks backups until the transaction is recovered"
            )
            if pending_journal.name == SOURCE_UPDATE_JOURNAL_NAME:
                raise SourceUpdateJournalPresent(
                    "source-update recovery is pending; " + message
                )
            raise RuntimeError(message)
        config = load_config(config_path, require_repository=require_repository)
        authoritative_state = Path(config["state_directory"]).resolve(strict=False)
        if not _same_windows_path(authoritative_state, lock_state):
            raise RuntimeError(
                "configuration state_directory changed while waiting for the run lock"
            )
        return config, run_lock
    except BaseException:
        run_lock.__exit__(None, None, None)
        raise


def windows_snapshot_path(path: Path) -> str:
    absolute = ntpath.abspath(str(path))
    drive, tail = ntpath.splitdrive(absolute)
    if not drive or drive.startswith("\\"):
        raise ValueError(f"unsupported canary path form: {absolute}")
    components = [part for part in tail.replace("\\", "/").split("/") if part]
    return "/" + "/".join([drive.rstrip(":"), *components])
