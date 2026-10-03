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
EXPECTED_DRIVEFS_MY_DRIVE_ROOT = r"G:\My Drive"
PLAN_TAG_PREFIX = "restic-backuper-plan:"
GENERATION_TAG_PREFIX = "restic-backuper-generation:"
SNAPSHOT_BINDING_PLAN = "plan"
SNAPSHOT_BINDING_LEGACY = "legacy_unbound"
SNAPSHOT_BINDING_CONFIGURATION = "configuration"


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
        help="snapshot path/pattern to restore; repeatable",
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


def password_command(config: dict[str, Any]) -> str | None:
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
) -> list[dict[str, Any]]:
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
        run_restic_capture(
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
) -> tuple[Path, bool]:
    target = Path(os.path.abspath(str(requested)))
    drive, tail = ntpath.splitdrive(canonical_path(target))
    if not drive or tail in ("", "\\", "/"):
        raise RuntimeError("restore target must not be a drive root")
    ensure_local_volume(target)
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


def validate_includes(includes: list[str]) -> list[str]:
    if len(includes) > MAX_REPORT_INCLUDES:
        raise ValueError(f"at most {MAX_REPORT_INCLUDES} include patterns are allowed")
    result: list[str] = []
    for pattern in includes:
        if not isinstance(pattern, str) or not pattern:
            raise ValueError("include patterns must not be empty")
        if "\x00" in pattern or len(pattern) > MAX_REPORT_STRING:
            raise ValueError("an include pattern is invalid or too long")
        result.append(pattern)
    return result


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
        "credential_source": "recovery_key" if args.recovery_drill else None,
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


def emit_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.json and not args.list:
        raise ValueError("--json is only valid with --list")
    if args.list and args.json:
        args.list_snapshots_json = True
    selected_actions = sum(
        bool(value)
        for value in (args.list, args.list_snapshots_json, args.list_tree_json, args.target)
    )
    # `--list --json` is one action despite setting the normalized flag above.
    if args.list and args.list_snapshots_json:
        selected_actions -= 1
    if selected_actions > 1:
        raise ValueError("choose only one of snapshot listing, tree listing, or restore")
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
        if args.target is None or args.report is None or args.recovery_key_file is None:
            raise ValueError("--recovery-drill requires a target, report, and recovery-key file")
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
    report = base_report(args) if args.report is not None else None
    report_path: Path | None = None
    restore_started = False
    restore_succeeded = False
    environment = os.environ.copy()
    try:
        config_path = args.config.resolve(strict=True)
        config = load_restore_config(config_path)
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
        interactive_password = True
        if args.recovery_key_file:
            environment["RESTIC_PASSWORD"] = recovery_password(args.recovery_key_file)
            interactive_password = False
        else:
            dpapi_command = password_command(config)
            if dpapi_command:
                command.extend(["--password-command", dpapi_command])
                interactive_password = False

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

        includes = validate_includes(args.include)
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
        )
        if report is not None:
            report["target"] = str(target)
            report["target_preexisted_empty"] = target_existed

        target.mkdir(parents=True, exist_ok=True)
        # Recheck immediately before Restic runs.  A race cannot turn the
        # alternate location into an implicit merge target unnoticed.
        ensure_no_reparse_ancestor(target)
        if any(target.iterdir()):
            raise RuntimeError("restore target became non-empty before restore started")
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
            restore_command = [
                *command,
                "restore",
                exact_selector,
                "--target",
                str(target),
                "--overwrite",
                "never",
                "--verify",
            ]
            for pattern in includes:
                restore_command.extend(["--include", pattern])
            restore_started = True
            returncode = subprocess.call(
                restore_command,
                cwd=SCRIPT_DIRECTORY,
                stdin=None if interactive_password else subprocess.DEVNULL,
                env=environment,
                shell=False,
                creationflags=CREATE_NO_WINDOW,
            )
        restore_succeeded = returncode == 0
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
            elif returncode == 0:
                report["result"] = "verified"
                report["verified"] = True
            else:
                report["result"] = "partial"
                report["partial_target_retained"] = True
                report["error"] = (
                    f"Restic restore failed with exit code {returncode}; "
                    "the alternate target was retained for inspection"
                )
        if returncode != 0:
            print(
                f"RESTORE INCOMPLETE: Restic exited with {returncode}; "
                f"the partial alternate target was retained at {target}",
                file=sys.stderr,
            )
        if report is not None:
            atomic_write_report(report_path, report)
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
