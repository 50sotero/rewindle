"""Run and verify an encrypted incremental Restic snapshot."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import ntpath
import os
from pathlib import Path
import secrets
import shutil
import sys
import time
import traceback
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from restic_common import (
    BackupCancelled,
    CancellationToken,
    DEFAULT_CONFIG,
    EngineFailure,
    RepositoryAccessMismatch,
    RunLockUnavailable,
    SourcePreflightFailed,
    SourceUpdateJournalPresent,
    UNARCHIVABLE_REPARSE_TAGS,
    atomic_write_json,
    atomic_write_text,
    backup_plan_tags,
    cancellation_checkpoint,
    ensure_free_space,
    load_config_under_lock,
    measure_repository_bytes,
    preflight_sources,
    process_start_filetime,
    read_pinned_restic_version,
    read_recorded_repository_id,
    repository_access,
    restic_base,
    run_capture,
    sanitized_command,
    sha256_file,
    snapshot_plan_identity,
    stream_command,
    unarchivable_links_replaced,
    utc_now,
    validate_and_record_plan_state,
    validate_repository_storage_readiness,
    validate_repository_volume,
    windows_snapshot_path,
)


PROGRESS_PERSIST_INTERVAL_SECONDS = 0.5
# Restic's exit code for "wrong password or no key found", which is also what backups with a password answer when they are
# opened with --insecure-no-password.
RESTIC_EXIT_WRONG_PASSWORD = 12
BACKUP_APP_NAME = "ResticBackuper"
BACKUP_APP_VERSION = "0.1.0-alpha.8"
MAX_PRIOR_SUCCESS_BYTES = 4 * 1024 * 1024
DEFAULT_CHANGE_ANOMALY_POLICY = {
    "enabled": True,
    "file_change_ratio": 0.35,
    "deletion_ratio": 0.15,
    "data_added_ratio": 0.50,
    "minimum_changed_files": 1000,
}
MAX_AFFECTED_PATHS = 50
# When the deeper check last read back a sample of the stored data. It sits in
# the protected state folder next to plan-state.json and last-success.json, so
# only administrators and SYSTEM can write it.
DATA_CHECK_STATE_NAME = "data-check.json"
DATA_CHECK_INTERVAL_DAYS = 7
MAX_DATA_CHECK_STATE_BYTES = 64 * 1024
# The exclusion file each run writes for the WSL links and special files it
# leaves out (see unarchivable_exclusions), in the protected state folder. It is
# handed to Restic after the installed list and is not part of the plan: the
# change-anomaly comparison still hashes only the installed list.
UNARCHIVABLE_EXCLUDES_NAME = "unarchivable-excludes.txt"
MAX_UNARCHIVABLE_SAMPLES = 20
# The longest sample path status.json and the run log keep: its start (the
# source) and its end (the name), with an ellipsis between them.
MAX_UNARCHIVABLE_SAMPLE_CHARACTERS = 1000
# The longest exclusion line generated, in UTF-8 bytes. Restic reads exclusion
# files with Go's bufio.Scanner, which refuses a line of 64 KiB or more, and
# then fails the whole run; a longer line is not written (the entry is kept in).
MAX_UNARCHIVABLE_LINE_BYTES = 60_000
# What Go's strings.TrimSpace removes from the end of each line Restic reads
# from an exclusion file: every character unicode.IsSpace accepts.
RESTIC_TRIMMED_SPACE = frozenset(
    "\t\n\v\f\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006"
    "\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000"
)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--tag", help="snapshot tag; defaults to scheduled_tag")
    parser.add_argument("--scheduled", action="store_true")
    return parser.parse_args(argv)


def normalized_paths(paths: list[str]) -> list[str]:
    return sorted(ntpath.normcase(ntpath.normpath(path)) for path in paths)


def snapshot_matches(
    config: dict[str, Any], tag: str, snapshot: dict[str, Any]
) -> bool:
    plan_tag, generation_tag = backup_plan_tags(config)
    snapshot_tags = snapshot.get("tags") or []
    parsed_plan_identity = snapshot_plan_identity(snapshot_tags)
    return (
        snapshot.get("hostname", "").casefold() == config["hostname"].casefold()
        and tag in snapshot_tags
        and plan_tag in snapshot_tags
        and generation_tag in snapshot_tags
        and parsed_plan_identity
        == (config["plan_id"], config["config_generation"])
        and normalized_paths(snapshot.get("paths") or [])
        == normalized_paths(config["sources"])
    )


def select_snapshot(
    config: dict[str, Any], tag: str, snapshots: list[dict[str, Any]]
) -> dict[str, Any]:
    matches = [
        snapshot
        for snapshot in snapshots
        if snapshot_matches(config, tag, snapshot)
    ]
    if not matches:
        raise RuntimeError(
            "no snapshot exactly matches the configured host, tag, and source roots"
        )
    return max(matches, key=lambda item: item.get("time", ""))


def _source_volumes(records: Any) -> dict[str, str] | None:
    """Each source's volume serial, from preflight records that all matched; None otherwise."""
    if not isinstance(records, list) or not records:
        return None
    volumes: dict[str, str] = {}
    for record in records:
        if not isinstance(record, dict):
            return None
        path = record.get("canonical_path")
        serial = record.get("observed_volume_serial")
        if (
            record.get("volume_identity") != "match"
            or not isinstance(path, str)
            or not path
            or not isinstance(serial, str)
            or not serial
        ):
            return None
        volumes[ntpath.normcase(ntpath.normpath(path))] = serial.upper()
    return volumes if len(volumes) == len(records) else None


def earlier_generation_parent(
    config: dict[str, Any],
    tag: str,
    prior_success: dict[str, Any] | None,
    repository_id: str,
    source_records: Any,
    snapshots: Any,
) -> dict[str, Any] | None:
    """The backup that the first run of a new generation compares its files with.

    A backup finds the one before it only within its own generation (--group-by
    host,paths,tags, and every snapshot carries its generation's tag). A
    reinstall or an update that changes the backup's scope (a new exclusion
    list, say), or that can't show it didn't, and a move of the backup location
    start a new generation, so its first backup would find none and read every
    file again. It doesn't need to when the latest verified backup
    (last-success.json, in the protected state folder) is of this plan and an
    earlier generation, from this computer, of exactly these folders on the
    same volumes, into this same repository, and its snapshot is still there
    with those identities. Restic then reads only the files whose size,
    modification or change time differ from that snapshot, as it does between
    two backups of one generation. The exclusion list may differ: Restic reads
    every file the snapshot doesn't hold, and a parent never decides what is
    backed up.
    Returns that snapshot from the listing, or None.
    """
    if not isinstance(prior_success, dict):
        return None
    generation = prior_success.get("config_generation")
    hostname = prior_success.get("hostname")
    sources = prior_success.get("sources")
    snapshot_id = prior_success.get("snapshot_id")
    if (
        # A tuple: a corrupt state that is a list or an object never raises.
        prior_success.get("state") not in ("success", "success_unchanged")
        or prior_success.get("verification_complete") is not True
        or prior_success.get("plan_id") != config["plan_id"]
        or not _is_plain_int(generation)
        or not 1 <= generation < config["config_generation"]
        or not isinstance(hostname, str)
        or hostname.casefold() != config["hostname"].casefold()
        or not _is_repository_id(repository_id)
        or prior_success.get("repository_id") != repository_id
        or not _is_repository_id(snapshot_id)
        or not isinstance(sources, list)
        or any(not isinstance(source, str) for source in sources)
        or normalized_paths(sources) != normalized_paths(config["sources"])
    ):
        return None
    current_volumes = _source_volumes(source_records)
    if (
        current_volumes is None
        or len(current_volumes) != len(config["sources"])
        or _source_volumes(prior_success.get("source_identities")) != current_volumes
    ):
        return None
    if not isinstance(snapshots, list):
        return None
    listed = [
        snapshot
        for snapshot in snapshots
        if isinstance(snapshot, dict) and snapshot.get("id") == snapshot_id
    ]
    if len(listed) != 1:
        return None
    snapshot = listed[0]
    tags = snapshot.get("tags")
    paths = snapshot.get("paths")
    if (
        not isinstance(snapshot.get("hostname"), str)
        or snapshot["hostname"].casefold() != config["hostname"].casefold()
        or not isinstance(tags, list)
        or tag not in tags
        or snapshot_plan_identity(tags) != (config["plan_id"], generation)
        or not isinstance(paths, list)
        or any(not isinstance(path, str) for path in paths)
        or normalized_paths(paths) != normalized_paths(config["sources"])
    ):
        return None
    return snapshot


def restic_literal_exclude(path_text: str) -> str:
    """The exclusion-file line that matches exactly this path, and nothing else.

    Restic replaces $NAME in an exclusion file with that environment variable,
    and reads "$$" as one "$". It matches each line with Go's filepath.Match
    rules, which on Windows have no escape character: "[" opens a character
    class and "*" and "?" are wildcards, so each becomes a class that holds only
    itself (as restic_literal_pattern in restore.py does for "["). A "]" outside
    a class is already literal. Restic also trims white space from both ends of
    a line, so white space at the end of the path becomes a class too (that
    matters for a name ending in, say, a no-break space: a name ending in a
    plain space or a dot never gets here, see unarchivable_exclusions). The
    line starts with a drive or a share, never with white space or "#".
    """
    kept = len(path_text)
    while kept and path_text[kept - 1] in RESTIC_TRIMMED_SPACE:
        kept -= 1
    escaped: list[str] = []
    for character in path_text[:kept]:
        if character == "$":
            escaped.append("$$")
        elif character in "[*?":
            escaped.append("[" + character + "]")
        else:
            escaped.append(character)
    escaped.extend("[" + character + "]" for character in path_text[kept:])
    return "".join(escaped)


def _comparable_path(path: str) -> str:
    # Lexical only: ntpath.abspath would ask Windows, which drops trailing spaces and dots.
    return ntpath.normcase(ntpath.normpath(path))


def _display_text(text: str) -> str:
    # A name that is not valid Unicode cannot be written to status.json as UTF-8;
    # Restic, too, shows U+FFFD in its place. A path can be over 32,000
    # characters long, so a sample keeps its start and its end.
    text = text.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "replace")
    if len(text) > MAX_UNARCHIVABLE_SAMPLE_CHARACTERS:
        head = MAX_UNARCHIVABLE_SAMPLE_CHARACTERS // 4
        tail = MAX_UNARCHIVABLE_SAMPLE_CHARACTERS - head - 1
        text = text[:head] + "\u2026" + text[-tail:]
    return text


def unarchivable_exclusions(
    config: dict[str, Any], found: Any
) -> tuple[list[str], dict[str, Any], list[str]]:
    """The exclusion lines for the WSL links and special files a run leaves out, its record, and their paths.

    ``found`` is preflight_sources' "unarchivable_links". Each line is the source
    exactly as configured and handed to Restic, then the path below it with "/"
    between names, so a short (8.3) name or the letter case in the source is the
    one Restic walks. Every line names one path strictly inside its source that
    is not the restore test file; anything else is a fault and stops the run.
    So is a last name ending in a space or a dot: Restic matches each item by its
    full Windows path, which drops them, so no line could name it exactly (the
    source walk keeps such names in, as "trailing_dot_or_space").
    A line longer than MAX_UNARCHIVABLE_LINE_BYTES is not written: that entry is
    kept in, as "too_long". The record goes to status.json as
    "unarchivable_links"; the paths (in Windows form, one for each line) are
    for unarchivable_links_replaced after Restic has run.
    """
    record: dict[str, Any] = {
        "count": 0,
        "samples": [],
        "tags": {name: 0 for name in UNARCHIVABLE_REPARSE_TAGS.values()},
        "not_left_out": {"count": 0, "reasons": {}, "samples": []},
    }
    lines: list[str] = []
    left_out: list[str] = []
    kept_in = record["not_left_out"]

    def keep_in(path: str, tag: str, reason: str) -> None:
        kept_in["count"] += 1
        kept_in["reasons"][reason] = kept_in["reasons"].get(reason, 0) + 1
        if len(kept_in["samples"]) < MAX_UNARCHIVABLE_SAMPLES:
            kept_in["samples"].append(
                {"path": _display_text(path), "tag": tag, "reason": reason}
            )

    sources = [str(source) for source in config["sources"]]
    canary = _comparable_path(str(config["canary_file"]))
    for item in found or ():
        configured = item["configured_path"]
        if configured not in sources:
            raise RuntimeError(
                "a WSL link to leave out was found outside the configured sources"
            )
        root = _comparable_path(configured)
        base = configured.rstrip("\\/")
        for entry in item["entries"]:
            relative = entry["relative_path"]
            parts = relative.split("\\") if isinstance(relative, str) else []
            if (
                not parts
                or any(
                    part in ("", ".", "..")
                    or any(character in part for character in "/:")
                    or any(ord(character) < 0x20 for character in part)
                    for part in parts
                )
                # Windows drops these before Restic matches (see restic_common).
                or parts[-1].endswith((" ", "."))
            ):
                raise RuntimeError(
                    f"a WSL link to leave out has an unusable relative path: {relative!r}"
                )
            tag = entry.get("tag")
            if tag not in record["tags"]:
                raise RuntimeError(
                    f"a WSL link to leave out has an unknown reparse tag: {tag!r}"
                )
            display = base + "\\" + "\\".join(parts)
            comparable = _comparable_path(display)
            try:
                inside = ntpath.commonpath([comparable, root]) == root
            except ValueError:
                inside = False
            if not inside or comparable in (root, canary):
                raise RuntimeError(
                    "a WSL link to leave out is not strictly inside its source, "
                    f"or is the restore test file: {display!r}"
                )
            line = restic_literal_exclude(
                base.replace("\\", "/") + "/" + "/".join(parts)
            )
            if len(line.encode("utf-8", "surrogatepass")) > MAX_UNARCHIVABLE_LINE_BYTES:
                keep_in(display, tag, "too_long")
                continue
            lines.append(line)
            left_out.append(display)
            record["count"] += 1
            record["tags"][tag] += 1
            if len(record["samples"]) < MAX_UNARCHIVABLE_SAMPLES:
                record["samples"].append(_display_text(display))
        not_left_out = item["not_left_out"]
        kept_in["count"] += int(not_left_out["count"])
        for reason, count in not_left_out["reasons"].items():
            kept_in["reasons"][reason] = kept_in["reasons"].get(reason, 0) + int(count)
        for sample in not_left_out["samples"]:
            if len(kept_in["samples"]) >= MAX_UNARCHIVABLE_SAMPLES:
                break
            kept_in["samples"].append(
                {
                    "path": _display_text(base + "\\" + sample["relative_path"]),
                    "tag": sample["tag"],
                    "reason": sample["reason"],
                }
            )
    return lines, record, left_out


# The most backups the inventory record counts; a listing larger than this is
# not described rather than described wrongly.
MAX_INVENTORY_COUNT = 1_000_000


def summarize_restorable_snapshots(
    config: dict[str, Any], snapshots: Any, counted_utc: str
) -> dict[str, Any] | None:
    """How many backups the dashboard's Restore list would offer, and the oldest and newest.

    Display-only evidence: nothing is allowed or refused because of it, and it never fails a
    backup. It counts with restore.py's own browse rule (snapshot_binding_state: this plan, any
    generation, plus earlier backups that match this configuration exactly), and, like that
    list, describes nothing when any entry of the listing is not a snapshot with an exact ID.
    """
    try:
        # Imported here, not at the top: a problem in restore.py costs this record, never a
        # backup. backup.py puts its own folder first on sys.path, which the launcher's -I
        # would otherwise leave out. restore.py imports nothing of Rewindle's (the recovery
        # kit copies it alone), so this adds no new dependency to it.
        from restore import snapshot_binding_state, validate_snapshot

        if not isinstance(snapshots, list) or len(snapshots) > MAX_INVENTORY_COUNT:
            return None
        count = 0
        times: list[datetime] = []
        for snapshot in snapshots:
            # The Restore list refuses a listing with an entry that is not a snapshot.
            validate_snapshot(snapshot)
            if snapshot_binding_state(snapshot, config) is None:
                continue
            count += 1
            moment = _snapshot_time_utc(snapshot.get("time"))
            if moment is not None:
                times.append(moment)
        if count < 1 or not times:
            return None
        return {
            "schema_version": 1,
            "count": count,
            "oldest_utc": _utc_text(min(times).replace(microsecond=0)),
            "newest_utc": _utc_text(max(times).replace(microsecond=0)),
            "counted_utc": counted_utc,
            "rule": "restore_browse",
        }
    except Exception:
        return None


def _snapshot_time_utc(value: Any) -> datetime | None:
    if not isinstance(value, str) or len(value) > 64:
        return None
    try:
        # Python 3.11 and later read Restic's nine fraction digits and a "Z".
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(timezone.utc)


def parse_json_lines(line: str) -> dict[str, Any] | None:
    try:
        value = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        return None
    return value if isinstance(value, dict) else None


def load_prior_success_for_anomaly(path: Path) -> dict[str, Any] | None:
    """Load bounded prior telemetry; malformed telemetry is never trusted."""
    try:
        if not path.is_file() or path.stat().st_size > MAX_PRIOR_SUCCESS_BYTES:
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _utc_text(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_utc_text(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.endswith("Z") or len(value) > 40:
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    if parsed.tzinfo is None or not 2000 <= parsed.year <= 9000:
        return None
    return parsed


def _is_plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_repository_id(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def load_data_check_state(path: Path) -> dict[str, Any] | None:
    """Return the record of the last passed data-sample check, if it is usable.

    A missing, oversized or malformed record counts as "never checked", so the
    next eligible run checks again instead of trusting it.
    """
    try:
        if path.is_symlink() or not path.is_file():
            return None
        if path.stat().st_size > MAX_DATA_CHECK_STATE_BYTES:
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(value, dict):
        return None
    subset = value.get("subset")
    subset_parts = value.get("subset_parts")
    if (
        not _is_plain_int(value.get("schema_version"))
        or value["schema_version"] != 1
        or _parse_utc_text(value.get("last_data_subset_check_utc")) is None
        or not _is_repository_id(value.get("repository_id"))
        or not _is_plain_int(subset)
        or not _is_plain_int(subset_parts)
        or not 1 <= subset <= subset_parts
    ):
        return None
    return value


def data_subset_check_due(
    record: dict[str, Any] | None,
    now_utc: datetime,
    repository_id: str,
    subset_parts: int,
) -> bool:
    """Decide whether this run also reads back a sample of the stored data.

    It is due on the first run on or after the seventh day (by this PC's
    calendar) since the last passed check, whatever the weekday, so a PC that
    is off on one day of the week, or a schedule that skips that day, still
    gets it. Counting calendar days keeps a daily backup on the same weekday
    even when one run takes a few minutes longer than the last. No record, a
    record for another backup or another number of parts, and a recorded time
    later than now (the clock was moved back) all count as due.
    """
    if (
        record is None
        or record.get("repository_id") != repository_id
        or record.get("subset_parts") != subset_parts
    ):
        return True
    checked = _parse_utc_text(record.get("last_data_subset_check_utc"))
    if checked is None or checked > now_utc:
        return True
    try:
        elapsed_days = (now_utc.astimezone().date() - checked.astimezone().date()).days
    except (OverflowError, OSError, ValueError):
        return True
    return elapsed_days >= DATA_CHECK_INTERVAL_DAYS


def next_data_subset(
    record: dict[str, Any] | None,
    now_utc: datetime,
    repository_id: str,
    subset_parts: int,
) -> int:
    """Take the next part in turn, so each part is read once per round."""
    if (
        record is not None
        and record.get("repository_id") == repository_id
        and record.get("subset_parts") == subset_parts
    ):
        return int(record["subset"]) % subset_parts + 1
    return now_utc.timetuple().tm_yday % subset_parts + 1


def _change_anomaly_policy(config: dict[str, Any]) -> dict[str, Any]:
    configured = config.get("change_anomaly")
    policy = dict(DEFAULT_CHANGE_ANOMALY_POLICY)
    if isinstance(configured, dict):
        policy.update(configured)
    return policy


def evaluate_change_anomaly(
    summary: dict[str, Any],
    prior_status: dict[str, Any] | None,
    config: dict[str, Any],
) -> dict[str, Any]:
    """Compare like-for-like verified runs and request a non-destructive hold.

    The hold never fails or removes the newly verified snapshot.  It is durable
    telemetry for exact operator acknowledgement and future destructive
    maintenance gates. It does not pause a live DriveFS upload.
    """
    policy = _change_anomaly_policy(config)
    result: dict[str, Any] = {
        "schema_version": 1,
        "evaluated": False,
        "status": "not_comparable",
        "hold": False,
        "reasons": [],
        "thresholds": {
            "file_change_ratio": policy["file_change_ratio"],
            "deletion_ratio": policy["deletion_ratio"],
            "data_added_ratio": policy["data_added_ratio"],
            "minimum_changed_files": policy["minimum_changed_files"],
        },
    }
    if not policy["enabled"]:
        result["status"] = "disabled"
        return result
    if not isinstance(prior_status, dict):
        result["reason_not_evaluated"] = "no bounded verified prior run"
        return result

    current_exclude_hash = sha256_file(Path(config["exclude_file"]))
    comparable = (
        prior_status.get("verification_complete") is True
        and prior_status.get("state") in {"success", "success_unchanged"}
        and prior_status.get("plan_id") == config["plan_id"]
        and prior_status.get("config_generation") == config["config_generation"]
        and normalized_paths(prior_status.get("sources") or [])
        == normalized_paths(config["sources"])
        and prior_status.get("exclude_file_sha256") == current_exclude_hash
        and prior_status.get("repository_id") == read_recorded_repository_id(config)
    )
    prior_summary = prior_status.get("summary")
    if not comparable or not isinstance(prior_summary, dict):
        result["reason_not_evaluated"] = "backup plan or prior evidence changed"
        return result

    numeric_fields = (
        "total_files_processed",
        "total_bytes_processed",
        "files_new",
        "files_changed",
        "data_added",
    )
    if any(
        isinstance(document.get(field), bool)
        or not isinstance(document.get(field), (int, float))
        or document[field] < 0
        for document in (summary, prior_summary)
        for field in numeric_fields
        if field in ("total_files_processed", "total_bytes_processed")
        or document is summary
    ):
        result["reason_not_evaluated"] = "backup summary counters are invalid"
        return result

    prior_files = int(prior_summary["total_files_processed"])
    prior_bytes = int(prior_summary["total_bytes_processed"])
    if prior_files <= 0 or prior_bytes <= 0:
        result["reason_not_evaluated"] = "prior backup has no comparison baseline"
        return result

    current_files = int(summary["total_files_processed"])
    new_files = int(summary["files_new"])
    changed_files = int(summary["files_changed"])
    data_added = int(summary["data_added"])
    estimated_deleted = max(0, prior_files + new_files - current_files)
    affected_files = new_files + changed_files + estimated_deleted
    measurements = {
        "prior_files": prior_files,
        "current_files": current_files,
        "new_files": new_files,
        "changed_files": changed_files,
        "estimated_deleted_files": estimated_deleted,
        "affected_files": affected_files,
        "prior_logical_bytes": prior_bytes,
        "current_logical_bytes": int(summary["total_bytes_processed"]),
        "repository_bytes_added": data_added,
        "file_change_ratio": (new_files + changed_files) / prior_files,
        "deletion_ratio": estimated_deleted / prior_files,
        "data_added_ratio": data_added / prior_bytes,
    }
    result["measurements"] = measurements
    result["evaluated"] = True

    if affected_files >= int(policy["minimum_changed_files"]):
        if measurements["file_change_ratio"] >= float(policy["file_change_ratio"]):
            result["reasons"].append("file_change_ratio")
        if measurements["deletion_ratio"] >= float(policy["deletion_ratio"]):
            result["reasons"].append("deletion_ratio")
        if measurements["data_added_ratio"] >= float(policy["data_added_ratio"]):
            result["reasons"].append("data_added_ratio")

    result["hold"] = bool(result["reasons"])
    result["status"] = "hold" if result["hold"] else "clear"
    return result


def collect_affected_paths(status: dict[str, Any]) -> list[str]:
    """Return a bounded, deduplicated set of source paths implicated by a run."""
    candidates: list[Any] = []
    for event in status.get("errors") or []:
        if not isinstance(event, dict):
            continue
        for key in ("item", "path", "name"):
            candidates.append(event.get(key))
        nested = event.get("error")
        if isinstance(nested, dict):
            for key in ("item", "path", "name"):
                candidates.append(nested.get(key))
    source_preflight = status.get("source_preflight")
    if isinstance(source_preflight, dict):
        for source in source_preflight.get("sources") or []:
            if (
                not isinstance(source, dict)
                or source.get("overall_status") == "ready"
            ):
                continue
            candidates.append(
                source.get("canonical_path") or source.get("configured_path")
            )

    paths: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if not isinstance(candidate, str):
            continue
        value = candidate.strip()
        if (
            not value
            or len(value) > 1024
            or "\x00" in value
            or "\r" in value
            or "\n" in value
            or not ntpath.isabs(value)
        ):
            continue
        normalized = ntpath.normcase(ntpath.normpath(value))
        if normalized in seen:
            continue
        seen.add(normalized)
        paths.append(value)
        if len(paths) >= MAX_AFFECTED_PATHS:
            break
    return paths


def classify_failure(
    phase_state: str,
    error: BaseException,
    exit_code: int | None,
) -> tuple[str, str]:
    """Publish stable support semantics without depending on exception wording.

    A problem the engine recognises where it happens (a full backup drive, a
    different drive at the backup location's letter, a protected folder that
    is missing or on another drive) raises an ``EngineFailure`` that carries
    its own code. Everything else is classified by the phase it stopped in.
    """
    phase = {
        "starting": "initialization",
        "checking_repository_storage": "repository_storage",
        "preflighting_sources": "source_preflight",
        "authenticating_repository": "repository_authentication",
        "backing_up": "backup",
        "partial": "backup",
        "verifying_snapshot": "snapshot_verification",
        "checking_repository": "repository_structure_check",
        "restoring_canary": "restore_canary",
        "checking_data_subset": "repository_data_check",
    }.get(phase_state, "wrapper")
    if phase_state == "partial" or exit_code == 3:
        code = "source_data_unreadable"
    elif isinstance(error, EngineFailure):
        code = error.failure_code
    elif phase == "repository_storage":
        code = "repository_storage_unavailable"
    elif phase == "source_preflight":
        code = "source_preflight_failed"
    elif phase == "repository_authentication":
        code = "repository_authentication_failed"
    elif phase == "backup":
        code = "restic_backup_failed"
    elif phase == "snapshot_verification":
        code = "snapshot_verification_failed"
    elif phase == "repository_structure_check":
        code = "repository_structure_check_failed"
    elif phase == "restore_canary":
        code = "restore_canary_failed"
    elif phase == "repository_data_check":
        code = "repository_data_check_failed"
    elif isinstance(error, KeyboardInterrupt):
        code = "wrapper_interrupted"
    else:
        code = "wrapper_failed"
    return phase, code


def authenticate_repository_id(
    config: dict[str, Any],
    recorded_repository_id: str | None,
    *,
    cancellation: CancellationToken | None = None,
    on_cancellation=None,
) -> str:
    """Authenticate the repository and bind its actual non-secret 64-hex ID."""
    result = run_capture(
        restic_base(config, json_output=True) + ["cat", "config"],
        cancellation=cancellation,
        on_cancellation=on_cancellation,
    )
    if result.returncode != 0:
        if result.returncode == RESTIC_EXIT_WRONG_PASSWORD and repository_access(config) == "no_password":
            # The backups were set up without a password and now ask for a key Rewindle does not have (changed outside
            # Rewindle, or replaced by other backups). The run records its own failure code, so the reader is not told to
            # check the drive; Restic's text stays out of the message.
            raise RepositoryAccessMismatch(
                "these backups now ask for a key that Rewindle doesn't have"
            )
        raise RuntimeError(
            "could not authenticate repository identity: "
            + (result.stderr.strip() or f"Restic exited {result.returncode}")
        )
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError("repository identity response is not valid JSON") from error
    repository_id = document.get("id") if isinstance(document, dict) else None
    if (
        not isinstance(repository_id, str)
        or len(repository_id) != 64
        or any(character not in "0123456789abcdef" for character in repository_id)
    ):
        raise RuntimeError("repository identity response has no canonical 64-hex ID")
    if recorded_repository_id is not None and repository_id != recorded_repository_id:
        raise RuntimeError(
            "authenticated repository ID does not match the recorded repository identity"
        )
    return repository_id


def safe_remove_restore_test(target: Path, base: Path) -> None:
    target_resolved = target.resolve(strict=True)
    base_resolved = base.resolve(strict=True)
    if target_resolved.parent != base_resolved:
        raise RuntimeError(f"unsafe restore-test cleanup target: {target_resolved}")
    shutil.rmtree(target_resolved)


def verify_canary(
    config: dict[str, Any],
    snapshot_id: str,
    run_id: str,
    log_handle,
    *,
    cancellation: CancellationToken | None = None,
    on_cancellation=None,
) -> dict[str, Any]:
    canary = Path(config["canary_file"])
    expected_hash = sha256_file(canary)
    restore_base = Path(config["state_directory"]) / "restore-tests"
    restore_base.mkdir(parents=True, exist_ok=True)
    target = restore_base / run_id
    if target.exists():
        raise FileExistsError(f"restore-test target already exists: {target}")
    target.mkdir()

    snapshot_path = windows_snapshot_path(canary)
    # Restic's snapshotID:subfolder selector accepts directories, not files.
    # Restoring the canary's small project directory avoids recreating the
    # source volume's parent ACL hierarchy in the temporary verification tree.
    snapshot_selector = f"{snapshot_id}:{windows_snapshot_path(canary.parent)}"
    command = restic_base(config) + [
        "restore",
        snapshot_selector,
        "--target",
        str(target),
        "--overwrite",
        "never",
        "--verify",
    ]
    log_handle.write(
        json.dumps(
            {"wrapper_event": "canary_restore", "command": sanitized_command(command)}
        )
        + "\n"
    )
    log_handle.flush()
    return_code = stream_command(
        command,
        log_handle,
        cancellation=cancellation,
        on_cancellation=on_cancellation,
    )
    if return_code != 0:
        raise RuntimeError(f"canary restore failed with exit {return_code}")
    cancellation_checkpoint(cancellation, on_cancellation)

    candidates = list(target.rglob(canary.name))
    if len(candidates) != 1:
        raise RuntimeError(
            f"canary restore produced {len(candidates)} matching files, expected one"
        )
    restored = candidates[0]
    actual_hash = sha256_file(restored)
    if actual_hash != expected_hash or restored.stat().st_size != canary.stat().st_size:
        raise RuntimeError("restored canary content does not match its source")

    result = {
        "snapshot_path": snapshot_path,
        "bytes": restored.stat().st_size,
        "sha256": actual_hash,
        "verified": True,
    }
    safe_remove_restore_test(target, restore_base)
    return result


def _run_locked(
    args: argparse.Namespace,
    config: dict[str, Any],
    cancellation: CancellationToken | None = None,
) -> int:
    tag = args.tag or config["scheduled_tag"]
    plan_tag, generation_tag = backup_plan_tags(config)
    state_directory = Path(config["state_directory"])
    logs_directory = state_directory / "logs"
    logs_directory.mkdir(parents=True, exist_ok=True)
    validate_and_record_plan_state(config, state_directory)
    status_path = state_directory / "status.json"
    last_success_path = state_directory / "last-success.json"
    prior_success_exists = last_success_path.is_file()
    prior_success = load_prior_success_for_anomaly(last_success_path)

    run_id = datetime.now().strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(4)
    log_path = logs_directory / f"backup-{run_id}.jsonl.log"
    cancellation_identity = cancellation.identity if cancellation is not None else None
    status: dict[str, Any] = {
        "schema_version": 1,
        "run_id": run_id,
        "state": "starting",
        "started_utc": utc_now(),
        "finished_utc": None,
        "wrapper_pid": os.getpid(),
        "wrapper_start_filetime": process_start_filetime(),
        "launcher_pid": (
            cancellation_identity.launcher_pid if cancellation_identity else None
        ),
        "launcher_start_filetime": (
            cancellation_identity.launcher_start_filetime
            if cancellation_identity
            else None
        ),
        "cancel_channel_id": (
            cancellation_identity.channel_id if cancellation_identity else None
        ),
        "cancel_channel_fingerprint": (
            cancellation_identity.channel_fingerprint
            if cancellation_identity
            else None
        ),
        "cancel_requested_utc": None,
        "cancel_signal_sent_utc": None,
        "cancel_outcome": None,
        "scheduled": bool(args.scheduled),
        "app_name": BACKUP_APP_NAME,
        "app_version": BACKUP_APP_VERSION,
        "plan_id": config["plan_id"],
        "config_generation": config["config_generation"],
        "repository": config["repository"],
        "repository_storage_mode": config.get(
            "repository_storage_mode", "local_ntfs"
        ),
        "repository_access": repository_access(config),
        "repository_readiness": None,
        "repository_volume_serial": config["repository_volume_serial"],
        "repository_id": read_recorded_repository_id(config),
        "hostname": config["hostname"],
        "tag": tag,
        "snapshot_tags": [tag, plan_tag, generation_tag],
        "plan_tag": plan_tag,
        "generation_tag": generation_tag,
        "sources": config["sources"],
        "source_identities": [],
        "source_preflight": None,
        "exclude_file": config["exclude_file"],
        "exclude_file_sha256": sha256_file(Path(config["exclude_file"])),
        "restic_executable": config["restic_executable"],
        "restic_executable_sha256": sha256_file(Path(config["restic_executable"])),
        "restic_version": read_pinned_restic_version(config),
        "canary_source_sha256": sha256_file(Path(config["canary_file"])),
        "log_file": str(log_path),
        "exit_code": None,
        "snapshot_id": None,
        "restic_reported_snapshot_id": None,
        "snapshot_created": False,
        "verification_complete": False,
        "progress": None,
        "summary": None,
        # How many backups the Restore list offers after this run, and how far back
        # they go (summarize_restorable_snapshots). Display only.
        "snapshot_inventory": None,
        # The first backup of a new generation names the earlier backup Restic
        # compares its files with (earlier_generation_parent): its snapshot ID
        # and generation. None for every other run.
        "earlier_generation_parent": None,
        # The WSL links and special files this run leaves out because Restic
        # cannot store them, and those it could not (unarchivable_exclusions).
        "unarchivable_links": None,
        "change_anomaly": None,
        "maintenance_hold": False,
        "errors": [],
        "affected_paths": [],
        "failure_phase": None,
        "failure_code": None,
        "verification": {},
    }
    try:
        atomic_write_json(status_path, status)
        with log_path.open(
            "a", encoding="utf-8", newline="\n", buffering=1
        ) as log_handle:
            def on_cancellation(stage: str, timestamp: str) -> None:
                if stage == "requested":
                    if status["cancel_requested_utc"] is None:
                        status["phase_at_cancel_request"] = status["state"]
                        status["cancel_requested_utc"] = timestamp
                    status["state"] = "cancelling"
                elif stage == "signal_sent":
                    if status["cancel_signal_sent_utc"] is None:
                        status["cancel_signal_sent_utc"] = timestamp
                elif stage in (
                    "finished_before_cancellation_took_effect",
                    "ctrl_break_signal_failed",
                    "non_130_exit_after_cancellation_signal",
                    "child_exit_won_cancellation_race",
                ):
                    status["cancel_outcome"] = stage
                    status["cancel_resolved_utc"] = timestamp
                    status["state"] = status.get(
                        "phase_at_cancel_request", status["state"]
                    )
                else:
                    raise ValueError(f"unknown cancellation stage: {stage}")
                atomic_write_json(status_path, status)
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": f"cancellation_{stage}",
                            "run_id": run_id,
                            "utc": timestamp,
                        }
                    )
                    + "\n"
                )
                log_handle.flush()

            cancellation_checkpoint(cancellation, on_cancellation)
            status["state"] = "checking_repository_storage"
            atomic_write_json(status_path, status)
            validate_repository_volume(config)
            status["repository_readiness"] = (
                validate_repository_storage_readiness(
                    config,
                    volume_validated=True,
                )
            )
            atomic_write_json(status_path, status)
            status["free_bytes_before"] = ensure_free_space(config)
            cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "preflighting_sources"
            atomic_write_json(status_path, status)
            source_preflight = preflight_sources(config)
            # Up to a thousand paths: kept out of status.json, which records
            # their count and a sample instead.
            found_links = source_preflight.pop("unarchivable_links", None)
            status["source_preflight"] = source_preflight
            status["source_identities"] = source_preflight["sources"]
            status["affected_paths"] = collect_affected_paths(status)
            atomic_write_json(status_path, status)
            if source_preflight["status"] != "ready":
                raise SourcePreflightFailed(
                    "source preflight failed: "
                    + "; ".join(source_preflight["failures"])
                )
            # WSL links and special files Restic cannot store are left out of
            # this run by exact path; without them nothing changes. A stale file
            # from an earlier run is removed, never passed on.
            unarchivable_excludes = state_directory / UNARCHIVABLE_EXCLUDES_NAME
            (
                unarchivable_lines,
                status["unarchivable_links"],
                unarchivable_paths,
            ) = unarchivable_exclusions(config, found_links)
            if unarchivable_lines:
                atomic_write_text(
                    unarchivable_excludes, "\n".join(unarchivable_lines) + "\n"
                )
            else:
                try:
                    unarchivable_excludes.unlink(missing_ok=True)
                except OSError as error:
                    # It is not passed to Restic, so a file that something
                    # holds open changes nothing; the next run tries again.
                    log_handle.write(
                        json.dumps(
                            {
                                "wrapper_event": "unarchivable_excludes_not_removed",
                                "run_id": run_id,
                                "utc": utc_now(),
                                "error": str(error),
                            }
                        )
                        + "\n"
                    )
            atomic_write_json(status_path, status)
            if status["unarchivable_links"]["count"]:
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "unarchivable_links_left_out",
                            "run_id": run_id,
                            "utc": utc_now(),
                            "count": status["unarchivable_links"]["count"],
                            "tags": status["unarchivable_links"]["tags"],
                            "samples": status["unarchivable_links"]["samples"],
                            "not_left_out": status["unarchivable_links"][
                                "not_left_out"
                            ]["count"],
                            "exclude_file": str(unarchivable_excludes),
                        }
                    )
                    + "\n"
                )
            cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "authenticating_repository"
            atomic_write_json(status_path, status)
            status["repository_id"] = authenticate_repository_id(
                config,
                status["repository_id"],
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            atomic_write_json(status_path, status)
            cancellation_checkpoint(cancellation, on_cancellation)

            prior_snapshots_result = run_capture(
                restic_base(config, json_output=True) + ["snapshots"],
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            if prior_snapshots_result.returncode != 0:
                raise RuntimeError(
                    "could not query snapshots before backup: "
                    + prior_snapshots_result.stderr.strip()
                )
            prior_snapshots = json.loads(prior_snapshots_result.stdout)
            prior_matching_snapshot_ids = {
                snapshot["id"]
                for snapshot in prior_snapshots
                if snapshot_matches(config, tag, snapshot)
            }
            status["prior_matching_snapshot_count"] = len(
                prior_matching_snapshot_ids
            )
            # A generation with no backup yet starts from the latest verified
            # backup of an earlier one, when nothing it reads has moved.
            earlier_parent = (
                None
                if prior_matching_snapshot_ids
                else earlier_generation_parent(
                    config,
                    tag,
                    prior_success,
                    status["repository_id"],
                    status["source_identities"],
                    prior_snapshots,
                )
            )
            if earlier_parent is not None:
                status["earlier_generation_parent"] = {
                    "snapshot_id": earlier_parent["id"],
                    "config_generation": prior_success["config_generation"],
                }
                atomic_write_json(status_path, status)
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "parent_from_earlier_generation",
                            "run_id": run_id,
                            "utc": utc_now(),
                            **status["earlier_generation_parent"],
                        }
                    )
                    + "\n"
                )
            cancellation_checkpoint(cancellation, on_cancellation)

            canary = Path(config["canary_file"])
            if not any(
                ntpath.commonpath(
                    [
                        ntpath.normcase(ntpath.abspath(str(canary))),
                        ntpath.normcase(ntpath.abspath(source)),
                    ]
                )
                == ntpath.normcase(ntpath.abspath(source))
                for source in config["sources"]
                if ntpath.splitdrive(str(canary))[0].casefold()
                == ntpath.splitdrive(source)[0].casefold()
            ):
                raise RuntimeError("the restore canary is not inside a configured source")

            command = restic_base(config, json_output=True) + [
                "backup",
                *config["sources"],
                "--iexclude-file",
                config["exclude_file"],
                *(
                    ["--iexclude-file", str(unarchivable_excludes)]
                    if unarchivable_lines
                    else []
                ),
                "--exclude-caches",
                # Named, the earlier backup replaces the parent --group-by would
                # find. The first backup of a generation is always kept, even
                # with nothing changed: the generation needs a backup of its own.
                *(
                    ["--parent", earlier_parent["id"]]
                    if earlier_parent is not None
                    else ["--skip-if-unchanged"]
                ),
                "--no-scan",
                "--read-concurrency",
                str(int(config.get("read_concurrency", 2))),
                "--group-by",
                "host,paths,tags",
                "--host",
                config["hostname"],
                "--tag",
                tag,
                "--tag",
                plan_tag,
                "--tag",
                generation_tag,
            ]
            if config.get("use_vss"):
                command.append("--use-fs-snapshot")

            status["state"] = "backing_up"
            status["command"] = sanitized_command(command)
            atomic_write_json(status_path, status)
            log_handle.write(
                json.dumps(
                    {
                        "wrapper_event": "backup_started",
                        "run_id": run_id,
                        "utc": utc_now(),
                        "command": sanitized_command(command),
                    }
                )
                + "\n"
            )

            last_progress_persisted = float("-inf")

            def on_backup_line(line: str) -> None:
                nonlocal last_progress_persisted
                event = parse_json_lines(line)
                if event is None:
                    return
                message_type = event.get("message_type")
                if message_type == "status":
                    status["progress"] = event
                    now = time.monotonic()
                    if (
                        now - last_progress_persisted
                        >= PROGRESS_PERSIST_INTERVAL_SECONDS
                    ):
                        atomic_write_json(status_path, status)
                        last_progress_persisted = now
                elif message_type == "summary":
                    status["summary"] = event
                    reported_snapshot_id = event.get("snapshot_id")
                    if isinstance(reported_snapshot_id, str):
                        status["restic_reported_snapshot_id"] = reported_snapshot_id
                elif message_type == "error":
                    if len(status["errors"]) < 100:
                        status["errors"].append(event)
                        status["affected_paths"] = collect_affected_paths(status)

            backup_return_code = stream_command(
                command,
                log_handle,
                on_backup_line,
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            status["backup_exit_code"] = backup_return_code
            if backup_return_code == 3:
                if (
                    status.get("cancel_outcome")
                    == "non_130_exit_after_cancellation_signal"
                    and isinstance(status.get("summary"), dict)
                    and status["summary"].get("snapshot_id")
                ):
                    status["cancel_outcome"] = (
                        "finished_before_cancellation_took_effect"
                    )
                status["state"] = "partial"
                status["exit_code"] = 3
                raise RuntimeError(
                    "Restic created an incomplete snapshot because some source data was unreadable"
                )
            if backup_return_code != 0:
                status["exit_code"] = backup_return_code
                raise RuntimeError(f"Restic backup failed with exit {backup_return_code}")
            # If WSL put a real file or folder where a left-out link was before
            # Restic got there, this backup left it out: it is not complete.
            replaced = unarchivable_links_replaced(unarchivable_paths)
            if replaced:
                status["unarchivable_links"]["replaced"] = {
                    "count": len(replaced),
                    "samples": [
                        _display_text(path)
                        for path in replaced[:MAX_UNARCHIVABLE_SAMPLES]
                    ],
                }
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "unarchivable_links_replaced",
                            "run_id": run_id,
                            "utc": utc_now(),
                            **status["unarchivable_links"]["replaced"],
                        }
                    )
                    + "\n"
                )
                status["state"] = "partial"
                status["exit_code"] = 3
                raise RuntimeError(
                    "a WSL link left out of this backup was replaced by a file or "
                    "folder while it ran, so the backup may be missing it"
                )
            cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "verifying_snapshot"
            atomic_write_json(status_path, status)
            snapshots_result = run_capture(
                restic_base(config, json_output=True) + ["snapshots"],
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            log_handle.write(snapshots_result.stderr)
            if snapshots_result.returncode != 0:
                raise RuntimeError(
                    f"could not query snapshots: {snapshots_result.stderr.strip()}"
                )
            snapshots = json.loads(snapshots_result.stdout)
            summary = status.get("summary")
            if not isinstance(summary, dict) or summary.get("message_type") != "summary":
                raise RuntimeError(
                    "Restic exited successfully but emitted no parseable JSON summary"
                )
            summary_snapshot_id = summary.get("snapshot_id")
            if summary_snapshot_id:
                bound = [
                    item
                    for item in snapshots
                    if item.get("id") == summary_snapshot_id
                    and snapshot_matches(config, tag, item)
                ]
                if len(bound) != 1:
                    raise RuntimeError(
                        "backup summary snapshot is missing or does not match host/tag/paths"
                    )
                snapshot = bound[0]
            else:
                if not prior_matching_snapshot_ids:
                    raise RuntimeError(
                        "Restic reported no new snapshot and no matching parent exists"
                    )
                prior_snapshot = select_snapshot(config, tag, prior_snapshots)
                bound = [
                    item
                    for item in snapshots
                    if item.get("id") == prior_snapshot.get("id")
                    and snapshot_matches(config, tag, item)
                ]
                if len(bound) != 1:
                    raise RuntimeError(
                        "unchanged backup parent is no longer present after the run"
                    )
                snapshot = bound[0]
            snapshot_id = snapshot["id"]
            status["snapshot_id"] = snapshot_id
            status["snapshot"] = snapshot
            status["snapshot_created"] = bool(
                summary_snapshot_id
                and snapshot_id not in prior_matching_snapshot_ids
            )
            # From the listing just read, which already holds this run's backup
            # (or the unchanged one it kept): no extra Restic call.
            status["snapshot_inventory"] = summarize_restorable_snapshots(
                config, snapshots, utc_now()
            )
            cancellation_checkpoint(cancellation, on_cancellation)

            if config.get("structural_check_after_backup", True):
                status["state"] = "checking_repository"
                atomic_write_json(status_path, status)
                check_command = restic_base(config) + ["check"]
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "structural_check",
                            "command": sanitized_command(check_command),
                        }
                    )
                    + "\n"
                )
                if stream_command(
                    check_command,
                    log_handle,
                    cancellation=cancellation,
                    on_cancellation=on_cancellation,
                ) != 0:
                    raise RuntimeError("repository structural check failed")
                status["verification"]["repository_structure"] = True
                cancellation_checkpoint(cancellation, on_cancellation)

            status["state"] = "restoring_canary"
            atomic_write_json(status_path, status)
            status["verification"]["canary"] = verify_canary(
                config,
                snapshot_id,
                run_id,
                log_handle,
                cancellation=cancellation,
                on_cancellation=on_cancellation,
            )
            cancellation_checkpoint(cancellation, on_cancellation)

            # About once a week (see data_subset_check_due), not on one fixed
            # weekday: read_data_subset_weekday is still accepted but unused.
            subset_parts = int(config.get("read_data_subset_parts", 0))
            data_check_path = state_directory / DATA_CHECK_STATE_NAME
            data_check_record = load_data_check_state(data_check_path)
            if (
                data_check_record is not None
                and data_check_record["repository_id"] != status["repository_id"]
            ):
                data_check_record = None
            status["last_data_subset_check_utc"] = (
                data_check_record["last_data_subset_check_utc"]
                if data_check_record is not None
                else None
            )
            data_check_started = _now_utc()
            if (
                args.scheduled
                and prior_success_exists
                and subset_parts > 0
                and data_subset_check_due(
                    data_check_record,
                    data_check_started,
                    status["repository_id"],
                    subset_parts,
                )
            ):
                subset = next_data_subset(
                    data_check_record,
                    data_check_started,
                    status["repository_id"],
                    subset_parts,
                )
                subset_command = restic_base(config) + [
                    "check",
                    f"--read-data-subset={subset}/{subset_parts}",
                ]
                status["state"] = "checking_data_subset"
                status["verification"]["data_subset"] = f"{subset}/{subset_parts}"
                atomic_write_json(status_path, status)
                if stream_command(
                    subset_command,
                    log_handle,
                    cancellation=cancellation,
                    on_cancellation=on_cancellation,
                ) != 0:
                    raise RuntimeError("repository data-subset check failed")
                cancellation_checkpoint(cancellation, on_cancellation)
                # Recorded only once the check has passed: a failed or
                # cancelled check is retried by the next run.
                checked_utc = _utc_text(data_check_started)
                atomic_write_json(
                    data_check_path,
                    {
                        "schema_version": 1,
                        "last_data_subset_check_utc": checked_utc,
                        "subset": subset,
                        "subset_parts": subset_parts,
                        "repository_id": status["repository_id"],
                        "run_id": run_id,
                    },
                )
                status["verification"]["data_subset_checked_utc"] = checked_utc
                status["last_data_subset_check_utc"] = checked_utc

            cancellation_checkpoint(cancellation, on_cancellation)
            status["change_anomaly"] = evaluate_change_anomaly(
                summary, prior_success, config
            )
            status["maintenance_hold"] = bool(status["change_anomaly"]["hold"])
            if status["maintenance_hold"]:
                log_handle.write(
                    json.dumps(
                        {
                            "wrapper_event": "change_anomaly_hold",
                            "run_id": run_id,
                            "utc": utc_now(),
                            "reasons": status["change_anomaly"]["reasons"],
                            "measurements": status["change_anomaly"].get(
                                "measurements"
                            ),
                        }
                    )
                    + "\n"
                )
            # How much space the backups now take, for the dashboard's Backup
            # location card. Measured before the finish time is taken, so the
            # recorded run includes it. The walk is read-only and time-boxed (also
            # when a folder listing hangs), and whatever happens in it, a verified
            # backup stays verified.
            try:
                repository_bytes_after = measure_repository_bytes(
                    Path(config["repository"])
                )
            except Exception:
                repository_bytes_after = None
            status["state"] = (
                "success_unchanged"
                if not summary_snapshot_id
                or snapshot_id in prior_matching_snapshot_ids
                else "success"
            )
            status["exit_code"] = 0
            status["verification_complete"] = True
            status["finished_utc"] = utc_now()
            status["free_bytes_after"] = shutil.disk_usage(
                Path(config["repository"]).anchor
            ).free
            status["repository_bytes_after"] = repository_bytes_after
            atomic_write_json(status_path, status)
            atomic_write_json(last_success_path, status)
            log_handle.write(
                json.dumps(
                    {
                        "wrapper_event": "backup_verified",
                        "run_id": run_id,
                        "snapshot_id": snapshot_id,
                        "utc": status["finished_utc"],
                        "plan_id": status["plan_id"],
                        "config_generation": status["config_generation"],
                        "repository_id": status["repository_id"],
                        "source_identities": status["source_identities"],
                        "exclude_file_sha256": status["exclude_file_sha256"],
                        "hostname": status["hostname"],
                        "snapshot_tags": status["snapshot_tags"],
                        "app_name": status["app_name"],
                        "app_version": status["app_version"],
                        "restic_version": status["restic_version"],
                        # Whether this run was compared with the one before it ("clear" or "hold"), or could not be
                        # ("not_comparable", "disabled"). Clean-up of old backups reads it, read-only, to know which
                        # runs the person should look over before old backups are removed.
                        "change_anomaly_status": status["change_anomaly"]["status"],
                    }
                )
                + "\n"
            )
            return 0
    except BackupCancelled as error:
        cancelled_phase = str(
            status.get("phase_at_cancel_request") or status.get("state") or "wrapper"
        )
        status["state"] = "cancelled" if error.cooperative else "cancel_failed"
        status["exit_code"] = (
            130
            if error.cooperative
            else (
                error.process_returncode
                if error.process_returncode not in (None, 0)
                else 1
            )
        )
        status["finished_utc"] = utc_now()
        status["cancel_requested_utc"] = (
            status.get("cancel_requested_utc") or error.requested_utc
        )
        status["cancel_signal_sent_utc"] = (
            status.get("cancel_signal_sent_utc") or error.signal_sent_utc
        )
        status["cancel_outcome"] = error.outcome
        if error.process_returncode is not None:
            status["restic_exit_code"] = error.process_returncode
        if not error.cooperative:
            status["failure"] = str(error)
        status["failure_phase"] = cancelled_phase
        status["failure_code"] = (
            "cooperative_cancellation"
            if error.cooperative
            else "cooperative_cancellation_failed"
        )
        status["affected_paths"] = collect_affected_paths(status)
        status_write_error = None
        try:
            atomic_write_json(status_path, status)
        except Exception as telemetry_error:
            status_write_error = str(telemetry_error)
        try:
            with log_path.open("a", encoding="utf-8", newline="\n") as log_handle:
                cancellation_event = {
                    "wrapper_event": (
                        "cancelled" if error.cooperative else "cancellation_failed"
                    ),
                    "run_id": run_id,
                    "utc": status["finished_utc"],
                    "outcome": error.outcome,
                    "restic_exit_code": error.process_returncode,
                }
                if error.signal_error is not None:
                    cancellation_event["signal_error"] = error.signal_error
                if status_write_error is not None:
                    cancellation_event["status_write_error"] = status_write_error
                log_handle.write(json.dumps(cancellation_event) + "\n")
                log_handle.flush()
                os.fsync(log_handle.fileno())
        except OSError:
            pass
        try:
            label = "BACKUP CANCELLED" if error.cooperative else "CANCELLATION FAILED"
            print(f"{label}: {error}", file=sys.stderr)
        except (AttributeError, OSError):
            pass
        return int(status["exit_code"])
    except BaseException as error:
        failed_phase_state = str(status.get("state") or "wrapper")
        if status.get("state") != "partial":
            status["state"] = "failed"
        if status.get("exit_code") is None:
            status["exit_code"] = 130 if isinstance(error, KeyboardInterrupt) else 1
        status["finished_utc"] = utc_now()
        status["failure"] = str(error)
        status["failure_phase"], status["failure_code"] = classify_failure(
            failed_phase_state,
            error,
            int(status["exit_code"]) if status.get("exit_code") is not None else None,
        )
        status["affected_paths"] = collect_affected_paths(status)
        status_write_error = None
        try:
            atomic_write_json(status_path, status)
        except Exception as telemetry_error:
            status_write_error = str(telemetry_error)
        try:
            with log_path.open("a", encoding="utf-8", newline="\n") as log_handle:
                failure_event = {
                    "wrapper_event": "failure",
                    "utc": status["finished_utc"],
                    "error": str(error),
                    "failure_phase": status["failure_phase"],
                    "failure_code": status["failure_code"],
                    "affected_paths": status["affected_paths"],
                    "traceback": traceback.format_exc(),
                }
                if status_write_error is not None:
                    failure_event["status_write_error"] = status_write_error
                log_handle.write(json.dumps(failure_event) + "\n")
                log_handle.flush()
                os.fsync(log_handle.fileno())
        except OSError:
            pass
        try:
            print(f"BACKUP FAILED: {error}", file=sys.stderr)
        except (AttributeError, OSError):
            pass
        return int(status["exit_code"] or 1)


def run(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    with CancellationToken.from_environment() as cancellation:
        try:
            config, run_lock = load_config_under_lock(
                args.config, require_repository=True
            )
        except (RunLockUnavailable, SourceUpdateJournalPresent) as error:
            print(f"BACKUP NOT STARTED: {error}", file=sys.stderr)
            return 75
        try:
            return _run_locked(args, config, cancellation)
        finally:
            run_lock.__exit__(None, None, None)


if __name__ == "__main__":
    raise SystemExit(run())
