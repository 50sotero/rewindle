"""Clean-up of old backups: the elevated helper behind Manage-Retention.ps1.

Nothing here runs on its own or by default. Only Manage-Retention.ps1 starts this helper, after a UAC approval and with
the run lock held, for one of these steps:

``configure``
    Saves the person's choice (on with three counts, or off) in ``retention-policy.json``. Turning it on also writes the
    list of what would go (the preview); turning it off removes nothing.
``preview``
    Lists, without changing anything, which old backups the saved counts would remove and which stay. Every Restic call
    here passes ``--no-lock``, so not even a lock file is written to the backup location.
``apply-forget``
    Removes exactly the list the person saw and confirmed, by explicit backup IDs, after checking that the preview file
    is the one they saw, that the latest backup is a verified one with no open change review, that no change journal is
    pending, and that a fresh read-only listing still gives the identical list. Anything else removes nothing.
``apply-prune`` / ``apply-check`` / ``apply-record``
    Frees the space, checks the remaining backups, and records the outcome.

Restic's keep rules do not know which backups Rewindle checked. The list is therefore made safer than Restic's own: a
checked backup is never removed when it is the only checked backup of a day, week or month that is kept, the newest
backup before each unreviewed unusual change is kept, and the latest verified backup is always kept. Removing fewer
backups than Restic proposes is always safe, because removal names each backup.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from restic_common import (  # noqa: E402
    atomic_write_json,
    backup_plan_tags,
    is_administrator,
    load_config,
    repository_storage_mode,
    restic_base,
    run_capture,
    sanitized_command,
    sha256_file,
    snapshot_plan_identity,
    stream_command,
    utc_now,
    validate_repository_storage_readiness,
    validate_repository_volume,
)
from secret_store import _security_sddl, admin_only_writable_problem  # noqa: E402


POLICY_SCHEMA = "ResticBackuper.RetentionPolicy.v1"
PREVIEW_SCHEMA = "ResticBackuper.RetentionPreview.v1"
HISTORY_SCHEMA = "ResticBackuper.RetentionHistory.v1"
REMOVE_SET_DOMAIN = "ResticBackuper.RetentionRemoveSet.v1"
KEEP_SET_DOMAIN = "ResticBackuper.RetentionKeepSet.v1"
INSTALL_DOMAIN = "ResticBackuper.RetentionInstall.v1"
POLICY_NAME = "retention-policy.json"
PREVIEW_NAME = "retention-preview.json"
HISTORY_NAME = "retention-history.json"
GROUP_BY = "host,paths"
DEFAULT_COUNTS = (14, 8, 24)
COUNT_BOUNDS = {"daily": (7, 90), "weekly": (4, 104), "monthly": (6, 120)}
# 50 IDs of 64 characters keep each forget command line far below Windows' 32,767 characters.
FORGET_BATCH = 50
MAX_PLAN_BACKUPS = 10_000
MAX_POLICY_BYTES = 16 * 1024
MAX_PREVIEW_BYTES = 8 * 1024 * 1024
MAX_HISTORY_BYTES = 1024 * 1024
MAX_HISTORY = 50
MAX_EVIDENCE_BYTES = 4 * 1024 * 1024
MAX_MANIFEST_BYTES = 8 * 1024 * 1024
MAX_EARLIER_CHANGES = 20
# Each backup log ends with the backup's own verdict (backup_verified, and change_anomaly_hold before it when the run
# changed far more than usual). Only that tail is read.
LOG_TAIL_BYTES = 64 * 1024
MAX_LOGS = 20_000
CLOCK_SLACK = timedelta(days=1)
SUCCESS_STATES = frozenset({"success", "success_unchanged"})
LOCAL_NTFS = "local_ntfs"
BACKUP_LOG_NAME = re.compile(r"^backup-[0-9]{8}T[0-9]{6}-[0-9a-f]{8}\.jsonl\.log$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
FILE_ATTRIBUTE_REPARSE_POINT = 0x400

# Why a clean-up is not possible right now. The same codes are used by the preview, the manager's result and the dashboard.
GATE_CODES = (
    "google_drive_not_supported",
    "pending_change",
    "no_verified_backup",
    "last_backup_not_verified",
    "folders_changed",
    "change_review_open",
    "clock_problem",
    "future_dated_backup",
    "backup_location_unavailable",
    "policy_inactive",
)
APPLY_REFUSALS = GATE_CODES + ("preview_mismatch", "earlier_changes_not_confirmed")
OUTCOMES = frozenset({"removed", "nothing_to_remove", "partial", "space_pending", "check_failed", "failed"})

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_REFUSED = 2
EXIT_PREVIEW_CHANGED = 3
EXIT_PARTIAL = 4


class RetentionError(Exception):
    """A step that cannot go on. The code is fixed text the dashboard turns into its own sentence."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class Refusal(Exception):
    """A gate that is closed: nothing was changed, and the code says why."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def admin_only_acl(path: Path) -> None:
    """Refuse a file or folder that anyone but Administrators or SYSTEM can change.

    Never the restricted form that gives the user Full Control, as the DPAPI password file has: a program running as the
    user could then rewrite what decides which backups are removed.
    """
    problem = admin_only_writable_problem(
        _security_sddl(path, include_owner=True), owner_limited_by_owner_rights=True
    )
    if problem:
        raise RetentionError("records_unprotected", f"{path.name} is not protected: {problem}")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _free_bytes(path: Path) -> int:
    return shutil.disk_usage(Path(path).anchor).free


@dataclass
class Context:
    config: dict[str, Any]
    install_root: Path
    runner: Callable[..., Any] = run_capture
    stream: Callable[..., int] = stream_command
    acl_check: Callable[[Path], None] = admin_only_acl
    now: Callable[[], datetime] = _now
    free_bytes: Callable[[Path], int] = _free_bytes
    validate_volume: Callable[[dict[str, Any]], Any] = validate_repository_volume
    validate_readiness: Callable[..., Any] = validate_repository_storage_readiness
    log_path: Path | None = None

    @property
    def state(self) -> Path:
        return Path(self.config["state_directory"])


# ---- Small readers --------------------------------------------------------------------------------------------------


def _sha256_text(lines: list[str]) -> str:
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def _read_regular_bytes(path: Path, limit: int) -> bytes | None:
    """The bytes of a regular file (never a link or other reparse point) of at most `limit` bytes, or None if absent."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT:
        raise RetentionError("unsafe_file", f"{path.name} is not a regular file")
    if info.st_size > limit:
        raise RetentionError("unsafe_file", f"{path.name} is larger than {limit} bytes")
    with open(path, "rb") as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise RetentionError("unsafe_file", f"{path.name} is larger than {limit} bytes")
    return data


def _parse_object(data: bytes, name: str) -> dict[str, Any]:
    try:
        value = json.loads(data.decode("utf-8-sig"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise RetentionError("unreadable_file", f"{name} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise RetentionError("unreadable_file", f"{name} is not one JSON object")
    return value


def _read_protected_object(ctx: Context, name: str, limit: int) -> tuple[dict[str, Any], bytes] | None:
    path = ctx.state / name
    data = _read_regular_bytes(path, limit)
    if data is None:
        return None
    ctx.acl_check(path)
    return _parse_object(data, name), data


def parse_time(value: Any) -> datetime | None:
    """An ISO 8601 time with its offset (Restic writes up to nine fraction digits), or None."""
    if not isinstance(value, str) or not value or len(value) > 64:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{2}:\d{2})", text)
    if match is None:
        return None
    fraction = (match.group(2) or "")[:7]
    try:
        return datetime.fromisoformat(match.group(1) + fraction + match.group(3))
    except ValueError:
        return None


def _is_hex64(value: Any) -> bool:
    return isinstance(value, str) and HEX64.fullmatch(value) is not None


def _plain_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def sanitize(message: str) -> str:
    """Keep an error short and free of anything that names how the password is reached."""
    text = " ".join(str(message).split())[:1000]
    if re.search(r"(?i)password|dpapi|restic_", text):
        return "The clean-up step failed without exposing credential details."
    return text or "The clean-up step failed."


def _log(ctx: Context, event: dict[str, Any]) -> None:
    if ctx.log_path is None:
        return
    try:
        ctx.log_path.parent.mkdir(parents=True, exist_ok=True)
        with ctx.log_path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(json.dumps({"retention_event": event.pop("event"), "utc": utc_now(), **event}) + "\n")
    except OSError:
        pass


# ---- Policy ---------------------------------------------------------------------------------------------------------


def validate_counts(daily: Any, weekly: Any, monthly: Any) -> tuple[int, int, int]:
    counts = (daily, weekly, monthly)
    for value, (name, (low, high)) in zip(counts, COUNT_BOUNDS.items()):
        if not _plain_int(value) or not low <= value <= high:
            raise ValueError(f"keep-{name} must be a whole number from {low} to {high}")
    return counts  # type: ignore[return-value]


def install_identity(install_root: Path) -> str:
    """This installation of the program files, as the installer's runtime manifest records them.

    Every file the installer placed, by name and SHA-256, and the version, except the backup configuration, which folder
    and location changes rewrite. An update or a reinstall with other program files gives another identity, and a saved
    clean-up setting then no longer counts (it is "off" until the person turns it on again).
    """
    data = _read_regular_bytes(install_root / "runtime-manifest.json", MAX_MANIFEST_BYTES)
    if data is None:
        raise RetentionError("install_unreadable", "the runtime manifest is missing")
    manifest = _parse_object(data, "runtime-manifest.json")
    files = manifest.get("files")
    if not isinstance(files, list):
        raise RetentionError("install_unreadable", "the runtime manifest lists no files")
    version = manifest.get("version")
    entries: list[tuple[str, str]] = []
    for record in files:
        if not isinstance(record, dict):
            raise RetentionError("install_unreadable", "the runtime manifest has an invalid record")
        relative = record.get("relative_path")
        digest = record.get("sha256")
        if not isinstance(relative, str) or not isinstance(digest, str) or not re.fullmatch(r"[0-9A-Fa-f]{64}", digest):
            raise RetentionError("install_unreadable", "the runtime manifest has an invalid record")
        relative = relative.replace("/", "\\").lower()
        if relative == "backup-config.json":
            continue
        entries.append((relative, digest.lower()))
    entries.sort()
    return _sha256_text(
        [INSTALL_DOMAIN, version if isinstance(version, str) else ""]
        + [f"{relative}\t{digest}" for relative, digest in entries]
    )


def policy_digest(plan_id: str, repository_id: str, install_id: str, daily: int, weekly: int, monthly: int) -> str:
    return _sha256_text(
        [POLICY_SCHEMA, plan_id, repository_id, install_id, str(daily), str(weekly), str(monthly), GROUP_BY]
    )


def read_policy(ctx: Context) -> dict[str, Any] | None:
    try:
        loaded = _read_protected_object(ctx, POLICY_NAME, MAX_POLICY_BYTES)
    except RetentionError as error:
        raise RetentionError("policy_unreadable", str(error)) from error
    return None if loaded is None else loaded[0]


def policy_problem(
    policy: dict[str, Any] | None,
    config: dict[str, Any],
    repository_id: str | None,
    install_id: str | None,
) -> str | None:
    """Why the saved setting does not allow a clean-up here, or None when it is on and belongs to this install."""
    if policy is None:
        return "missing"
    if policy.get("schema") != POLICY_SCHEMA or policy.get("schema_version") != 1:
        return "schema"
    if policy.get("enabled") is not True:
        return "off"
    try:
        daily, weekly, monthly = validate_counts(
            policy.get("keep_daily"), policy.get("keep_weekly"), policy.get("keep_monthly")
        )
    except ValueError:
        return "counts"
    if policy.get("group_by") != GROUP_BY:
        return "grouping"
    if policy.get("plan_id") != config["plan_id"]:
        return "plan"
    if repository_id is None or policy.get("repository_id") != repository_id:
        return "repository"
    if install_id is None or policy.get("install_id") != install_id:
        return "install"
    expected = policy_digest(config["plan_id"], repository_id, install_id, daily, weekly, monthly)
    if policy.get("policy_sha256") != expected:
        return "digest"
    return None


def _policy_counts(policy: dict[str, Any] | None) -> tuple[int, int, int]:
    if policy is not None:
        try:
            return validate_counts(policy.get("keep_daily"), policy.get("keep_weekly"), policy.get("keep_monthly"))
        except ValueError:
            pass
    return DEFAULT_COUNTS


# ---- Evidence and gates ---------------------------------------------------------------------------------------------


@dataclass
class Evidence:
    document: dict[str, Any]
    sha256: str


def read_evidence(ctx: Context) -> Evidence | None:
    """last-success.json, the record of the latest verified backup, or None when there is none."""
    try:
        loaded = _read_protected_object(ctx, "last-success.json", MAX_EVIDENCE_BYTES)
    except RetentionError:
        return None
    if loaded is None:
        return None
    document, data = loaded
    return Evidence(document, hashlib.sha256(data).hexdigest())


def pending_journals(state: Path) -> list[str]:
    """Every *.journal.json in the state folder (a file, a folder or a link): an unfinished protected change."""
    try:
        with os.scandir(state) as entries:
            return sorted(entry.name for entry in entries if entry.name.casefold().endswith(".journal.json"))
    except FileNotFoundError:
        return []


def _evidence_is_verified(document: dict[str, Any]) -> bool:
    return (
        document.get("state") in SUCCESS_STATES
        and document.get("verification_complete") is True
        and isinstance(document.get("run_id"), str)
        and bool(document.get("run_id"))
        and _is_hex64(document.get("snapshot_id"))
        and _is_hex64(document.get("repository_id"))
    )


def evaluate_gates(ctx: Context, evidence: Evidence | None) -> str | None:
    """The first closed gate, or None when a clean-up may be considered."""
    config = ctx.config
    if repository_storage_mode(config) != LOCAL_NTFS:
        return "google_drive_not_supported"
    if pending_journals(ctx.state):
        return "pending_change"
    if evidence is None or not _evidence_is_verified(evidence.document):
        return "no_verified_backup"
    document = evidence.document
    try:
        status = _read_protected_object(ctx, "status.json", MAX_EVIDENCE_BYTES)
    except RetentionError:
        status = None
    if (
        status is None
        or status[0].get("run_id") != document.get("run_id")
        or status[0].get("state") not in SUCCESS_STATES
    ):
        return "last_backup_not_verified"
    if document.get("plan_id") != config["plan_id"] or document.get("config_generation") != config["config_generation"]:
        return "folders_changed"
    if document.get("maintenance_hold") is True:
        return "change_review_open"
    finished = parse_time(document.get("finished_utc"))
    if finished is None or finished > ctx.now() + CLOCK_SLACK:
        return "clock_problem"
    return None


def authenticate_location(ctx: Context, repository_id: str) -> None:
    """The backup location is the one the latest verified backup used, and it answers. Read-only (--no-lock)."""
    try:
        ctx.validate_volume(ctx.config)
        ctx.validate_readiness(ctx.config, volume_validated=True)
    except Exception as error:
        raise Refusal("backup_location_unavailable") from error
    result = ctx.runner(restic_base(ctx.config, json_output=True) + ["--no-lock", "cat", "config"])
    if result.returncode != 0:
        raise Refusal("backup_location_unavailable")
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise Refusal("backup_location_unavailable") from error
    if not isinstance(document, dict) or document.get("id") != repository_id:
        raise Refusal("backup_location_unavailable")


# ---- Restic's proposal ----------------------------------------------------------------------------------------------


@dataclass
class Item:
    id: str
    time: datetime
    time_text: str
    files: int | None
    generation: int | None
    group: int
    reasons: set[str] = field(default_factory=set)


@dataclass
class Plan:
    remove: list[Item]
    keep: list[Item]
    group_count: int


def dry_run_command(config: dict[str, Any], counts: tuple[int, int, int]) -> list[str]:
    """Restic's own proposal for this computer's backups of this plan. Read-only: --dry-run, and --no-lock."""
    plan_tag, _generation_tag = backup_plan_tags(config)
    daily, weekly, monthly = counts
    return restic_base(config, json_output=True) + [
        "--no-lock",
        "forget",
        "--dry-run",
        "--host",
        config["hostname"],
        "--tag",
        plan_tag,
        "--group-by",
        GROUP_BY,
        "--keep-daily",
        str(daily),
        "--keep-weekly",
        str(weekly),
        "--keep-monthly",
        str(monthly),
    ]


def _restic_reason(match: str) -> str | None:
    text = match.casefold()
    if "daily" in text:
        return "day"
    if "weekly" in text:
        return "week"
    if "monthly" in text:
        return "month"
    return None


def _snapshot_item(value: Any, config: dict[str, Any], plan_tag: str, group: int) -> Item:
    if not isinstance(value, dict):
        raise ValueError("a backup in the listing is not an object")
    snapshot_id = value.get("id")
    if not _is_hex64(snapshot_id):
        raise ValueError("a backup in the listing has no full ID")
    hostname = value.get("hostname")
    if not isinstance(hostname, str) or hostname.casefold() != str(config["hostname"]).casefold():
        raise ValueError("the listing names a backup of another computer")
    tags = value.get("tags")
    if not isinstance(tags, list) or plan_tag not in tags:
        raise ValueError("the listing names a backup of another plan")
    moment = parse_time(value.get("time"))
    if moment is None:
        raise ValueError("a backup in the listing has no readable time")
    identity = snapshot_plan_identity(tags)
    summary = value.get("summary")
    files = summary.get("total_files_processed") if isinstance(summary, dict) else None
    return Item(
        id=snapshot_id,
        time=moment,
        time_text=str(value.get("time")),
        files=files if _plain_int(files) and files >= 0 else None,
        generation=identity[1] if identity is not None else None,
        group=group,
    )


def parse_forget_groups(stdout: str, config: dict[str, Any]) -> Plan:
    """Restic's JSON proposal, read strictly. Anything unexpected raises ValueError, and nothing is removed."""
    text = stdout.strip()
    if not text:
        # Restic prints nothing when no backup matches.
        return Plan([], [], 0)
    document = json.loads(text)
    if not isinstance(document, list):
        raise ValueError("the listing is not a list of groups")
    plan_tag, _generation_tag = backup_plan_tags(config)
    remove: list[Item] = []
    keep: list[Item] = []
    seen: set[str] = set()
    for index, group in enumerate(document):
        if not isinstance(group, dict):
            raise ValueError("a group in the listing is not an object")
        kept_raw = group.get("keep") or []
        removed_raw = group.get("remove") or []
        reasons_raw = group.get("reasons") or []
        if not isinstance(kept_raw, list) or not isinstance(removed_raw, list) or not isinstance(reasons_raw, list):
            raise ValueError("a group in the listing has no keep or remove list")
        kept = [_snapshot_item(value, config, plan_tag, index) for value in kept_raw]
        removed = [_snapshot_item(value, config, plan_tag, index) for value in removed_raw]
        if removed and not kept:
            raise ValueError("a group would keep no backup at all")
        reasons: dict[str, set[str]] = {}
        for reason in reasons_raw:
            if not isinstance(reason, dict) or not isinstance(reason.get("snapshot"), dict):
                raise ValueError("a keep reason in the listing is not an object")
            matches = reason.get("matches")
            if not isinstance(matches, list) or any(not isinstance(match, str) for match in matches):
                raise ValueError("a keep reason in the listing has no matches")
            reason_id = reason["snapshot"].get("id")
            mapped = {_restic_reason(match) for match in matches} - {None}
            reasons.setdefault(str(reason_id), set()).update(mapped)  # type: ignore[arg-type]
        for item in kept + removed:
            if item.id in seen:
                raise ValueError("the listing names a backup twice")
            seen.add(item.id)
        for item in kept:
            item.reasons = set(reasons.get(item.id, set()))
        keep.extend(kept)
        remove.extend(removed)
    if len(seen) > MAX_PLAN_BACKUPS:
        raise ValueError("the listing names more backups than clean-up handles")
    return Plan(remove, keep, len(document))


def _period(item: Item, kind: str) -> tuple[int, ...]:
    # Restic groups each backup by the day, ISO week and month of its own recorded time, in its own offset.
    if kind == "day":
        return (item.time.year, item.time.month, item.time.day)
    if kind == "week":
        iso = item.time.isocalendar()
        return (iso[0], iso[1])
    return (item.time.year, item.time.month)


def _move_to_keep(plan: Plan, item: Item, reason: str) -> None:
    plan.remove.remove(item)
    item.reasons = {reason}
    plan.keep.append(item)


def make_safer(plan: Plan, *, checked: set[str], latest_id: str, holds: list[dict[str, Any]]) -> Plan:
    """Take out of Restic's proposal what Rewindle must keep. Only ever moves backups from remove to keep."""
    latest = next((item for item in plan.remove if item.id == latest_id), None)
    if latest is not None:
        _move_to_keep(plan, latest, "latest")
    if latest is None and not any(item.id == latest_id for item in plan.keep):
        raise RetentionError("latest_backup_missing", "the latest verified backup is not in the listing")

    # A day, week or month that Restic keeps must keep a checked backup when it had one. Restic keeps the newest backup
    # of each period, which can be one that was made but not checked (an incomplete run, or a check that failed after it).
    for kind in ("day", "week", "month"):
        for keeper in [item for item in plan.keep if kind in item.reasons]:
            if keeper.id in checked:
                continue
            key = _period(keeper, kind)
            if any(
                item.group == keeper.group and item.id in checked and _period(item, kind) == key
                for item in plan.keep
            ):
                continue
            candidates = [
                item
                for item in plan.remove
                if item.group == keeper.group and item.id in checked and _period(item, kind) == key
            ]
            if candidates:
                _move_to_keep(plan, max(candidates, key=lambda item: item.time), "checked")

    # The last backup from before each unusual change that nobody has confirmed yet may hold the only good copies.
    for change in holds:
        changed = next(
            (item for item in plan.keep + plan.remove if item.id == change.get("snapshot_id")), None
        )
        if changed is None:
            continue
        before = sorted(
            (item for item in plan.keep + plan.remove if item.group == changed.group and item.time < changed.time),
            key=lambda item: item.time,
            reverse=True,
        )
        if not before:
            continue
        chosen = next((item for item in before if item.id in checked), before[0])
        if chosen in plan.remove:
            _move_to_keep(plan, chosen, "before_change")

    groups_with_removals = {item.group for item in plan.remove}
    if any(not any(kept.group == group for kept in plan.keep) for group in groups_with_removals):
        raise RetentionError("group_without_backup", "a group would keep no backup")
    plan.remove.sort(key=lambda item: item.time)
    plan.keep.sort(key=lambda item: item.time, reverse=True)
    return plan


def set_digest(domain: str, ids: list[str] | set[str]) -> str:
    return _sha256_text([domain, *sorted(ids)])


# ---- Records the backup kept ----------------------------------------------------------------------------------------


@dataclass
class BackupRecords:
    checked: set[str]
    changes: list[dict[str, Any]]
    complete: bool


def _tail_events(path: Path) -> list[dict[str, Any]]:
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT:
            return []
        with open(path, "rb") as handle:
            start = max(0, info.st_size - LOG_TAIL_BYTES)
            handle.seek(start)
            data = handle.read(LOG_TAIL_BYTES)
    except OSError:
        return []
    lines = data.split(b"\n")
    if start > 0 and lines:
        lines = lines[1:]
    events = []
    for line in lines:
        if b"wrapper_event" not in line:
            continue
        try:
            value = json.loads(line.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict):
            events.append(value)
    return events


def read_backup_records(
    ctx: Context, repository_id: str, since: datetime | None
) -> BackupRecords:
    """Which backups of this plan were verified, and which verified runs since `since` need the person to check their files.

    Read from the tail of each backup's own log in the protected logs folder, which the backup writes and nothing else
    changes: a run that ended with backup_verified made a checked backup. A run whose unusual changes held clean-up back
    (change_anomaly_hold), or that could not be compared with the run before it, is a change to confirm; so is one whose
    log does not say (an older engine). Nothing here is ever cleared except by a clean-up the person confirmed.
    """
    logs = ctx.state / "logs"
    try:
        info = os.lstat(logs)
    except FileNotFoundError:
        return BackupRecords(set(), [], False)
    if not stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT:
        raise RetentionError("records_unprotected", "the logs folder is not a normal folder")
    ctx.acl_check(logs)
    with os.scandir(logs) as entries:
        names = sorted(entry.name for entry in entries if BACKUP_LOG_NAME.fullmatch(entry.name))
    complete = len(names) <= MAX_LOGS
    names = names[-MAX_LOGS:]
    checked: set[str] = set()
    changes: list[dict[str, Any]] = []
    plan_id = ctx.config["plan_id"]
    for name in names:
        events = _tail_events(logs / name)
        verified = [event for event in events if event.get("wrapper_event") == "backup_verified"]
        if not verified:
            continue
        event = verified[-1]
        snapshot_id = event.get("snapshot_id")
        if (
            event.get("plan_id") != plan_id
            or event.get("repository_id") != repository_id
            or not _is_hex64(snapshot_id)
        ):
            continue
        checked.add(snapshot_id)
        finished = parse_time(event.get("utc"))
        run_id = event.get("run_id")
        hold = any(
            other.get("wrapper_event") == "change_anomaly_hold" and other.get("run_id") == run_id
            for other in events
        )
        status = event.get("change_anomaly_status")
        if hold or status == "hold":
            kind = "hold"
        elif status == "clear":
            continue
        elif status in ("not_comparable", "disabled"):
            kind = "not_compared"
        else:
            kind = "unknown"
        if since is not None and finished is not None and finished <= since:
            continue
        changes.append(
            {
                "run_id": run_id if isinstance(run_id, str) else None,
                "snapshot_id": snapshot_id,
                "finished_utc": event.get("utc") if finished is not None else None,
                "kind": kind,
            }
        )
    changes.sort(key=lambda change: change.get("finished_utc") or "", reverse=True)
    return BackupRecords(checked, changes, complete)


# ---- History --------------------------------------------------------------------------------------------------------


def read_history(ctx: Context) -> tuple[list[dict[str, Any]], bool]:
    """The recorded clean-ups, oldest first, and whether the record could be read."""
    try:
        loaded = _read_protected_object(ctx, HISTORY_NAME, MAX_HISTORY_BYTES)
    except RetentionError:
        return [], False
    if loaded is None:
        return [], True
    document = loaded[0]
    entries = document.get("entries")
    if (
        document.get("schema") != HISTORY_SCHEMA
        or document.get("schema_version") != 1
        or document.get("plan_id") != ctx.config["plan_id"]
        or not isinstance(entries, list)
        or any(not isinstance(entry, dict) for entry in entries)
    ):
        return [], False
    return entries, True


def last_confirmed_cleanup(entries: list[dict[str, Any]], readable: bool) -> datetime | None:
    """When the person last confirmed that their files looked right before a clean-up, or None."""
    if not readable:
        return None
    for entry in reversed(entries):
        if entry.get("files_confirmed") is True:
            started = parse_time(entry.get("started_utc"))
            if started is not None:
                return started
    return None


def prune_pending(entries: list[dict[str, Any]]) -> bool:
    for entry in reversed(entries):
        if entry.get("prune_completed") is True:
            return False
        removed = entry.get("removed_count")
        if _plain_int(removed) and removed > 0:
            return True
    return False


# ---- Preview --------------------------------------------------------------------------------------------------------


def _item_document(item: Item, *, with_reasons: bool) -> dict[str, Any]:
    document: dict[str, Any] = {
        "id": item.id,
        "time": item.time_text,
        "files": item.files,
        "generation": item.generation,
    }
    if with_reasons:
        order = ("latest", "day", "week", "month", "checked", "before_change")
        document["reasons"] = [reason for reason in order if reason in item.reasons]
    return document


def _base_preview(ctx: Context, evidence: Evidence | None, policy: dict[str, Any] | None) -> dict[str, Any]:
    daily, weekly, monthly = _policy_counts(policy)
    document = evidence.document if evidence is not None else {}
    return {
        "schema": PREVIEW_SCHEMA,
        "schema_version": 1,
        "state": "error",
        "blocked_reason": None,
        "error_code": None,
        "created_utc": utc_now(),
        "plan_id": ctx.config["plan_id"],
        "config_generation": ctx.config["config_generation"],
        "repository_id": document.get("repository_id") if _is_hex64(document.get("repository_id")) else None,
        "policy": {
            "keep_daily": daily,
            "keep_weekly": weekly,
            "keep_monthly": monthly,
            "group_by": GROUP_BY,
            "policy_sha256": policy.get("policy_sha256") if isinstance(policy, dict) else None,
        },
        "evidence": {
            "run_id": document.get("run_id"),
            "snapshot_id": document.get("snapshot_id"),
            "finished_utc": document.get("finished_utc"),
            "last_success_sha256": evidence.sha256 if evidence is not None else None,
        },
        "group_count": 0,
        "remove_count": 0,
        "keep_count": 0,
        "remove_set_sha256": set_digest(REMOVE_SET_DOMAIN, []),
        "keep_set_sha256": set_digest(KEEP_SET_DOMAIN, []),
        "remove": [],
        "keep": [],
        "future_dated_utc": None,
        "earlier_changes": [],
        "earlier_changes_unknown": False,
        "first_cleanup": False,
        "needs_files_confirmed": False,
        "prune_pending": False,
    }


def write_preview(ctx: Context, document: dict[str, Any]) -> str:
    """Write the preview with the state folder's protected permissions; the SHA-256 of what is on disk."""
    path = ctx.state / PREVIEW_NAME
    atomic_write_json(path, document)
    ctx.acl_check(path)
    data = _read_regular_bytes(path, MAX_PREVIEW_BYTES)
    if data is None:
        raise RetentionError("preview_unwritten", "the preview was not written")
    return hashlib.sha256(data).hexdigest()


@dataclass
class Computed:
    document: dict[str, Any]
    plan: Plan | None


def check_state_folder(ctx: Context) -> None:
    """The state folder itself must be one only Administrators and SYSTEM can change.

    The per-file check accepts a file the user owns when OWNER RIGHTS limits the owner to reading, which is only safe while
    nobody else can create files in the folder. Turning clean-up off does not need it: that is the safe direction.
    """
    try:
        info = os.lstat(ctx.state)
    except FileNotFoundError as error:
        raise RetentionError("records_unprotected", "the state folder is missing") from error
    if not stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT:
        raise RetentionError("records_unprotected", "the state folder is not a normal folder")
    ctx.acl_check(ctx.state)


def compute(ctx: Context, *, require_policy: bool = True) -> Computed:
    """Everything a preview says, without writing it. Gates first; Restic only when they are all open."""
    check_state_folder(ctx)
    evidence = read_evidence(ctx)
    try:
        policy = read_policy(ctx)
    except RetentionError:
        policy = None
        policy_unreadable = True
    else:
        policy_unreadable = False
    document = _base_preview(ctx, evidence, policy)

    def blocked(code: str) -> Computed:
        document["state"] = "blocked"
        document["blocked_reason"] = code
        return Computed(document, None)

    gate = evaluate_gates(ctx, evidence)
    if gate is not None:
        return blocked(gate)
    assert evidence is not None
    repository_id = evidence.document["repository_id"]
    install_id = install_identity(ctx.install_root)
    if require_policy and (policy_unreadable or policy_problem(policy, ctx.config, repository_id, install_id)):
        return blocked("policy_inactive")
    authenticate_location(ctx, repository_id)

    counts = _policy_counts(policy)
    result = ctx.runner(dry_run_command(ctx.config, counts))
    if result.returncode != 0:
        raise RetentionError("listing_failed", f"Restic could not list the backups (exit {result.returncode})")
    try:
        plan = parse_forget_groups(result.stdout, ctx.config)
    except (ValueError, json.JSONDecodeError) as error:
        raise RetentionError("listing_unexpected", str(error)) from error

    limit = ctx.now() + CLOCK_SLACK
    future = [item for item in plan.keep + plan.remove if item.time > limit]
    if future:
        document["future_dated_utc"] = max(future, key=lambda item: item.time).time_text
        return blocked("future_dated_backup")

    entries, history_readable = read_history(ctx)
    since = last_confirmed_cleanup(entries, history_readable)
    records = read_backup_records(ctx, repository_id, since)
    holds = [change for change in records.changes if change["kind"] == "hold"]
    plan = make_safer(plan, checked=records.checked, latest_id=evidence.document["snapshot_id"], holds=holds)

    remove_ids = [item.id for item in plan.remove]
    keep_ids = [item.id for item in plan.keep]
    unknown = (not records.complete) or (not history_readable) or any(
        change["kind"] == "unknown" for change in records.changes
    )
    document.update(
        {
            "state": "ready",
            "group_count": plan.group_count,
            "remove_count": len(remove_ids),
            "keep_count": len(keep_ids),
            "remove_set_sha256": set_digest(REMOVE_SET_DOMAIN, remove_ids),
            "keep_set_sha256": set_digest(KEEP_SET_DOMAIN, keep_ids),
            "remove": [_item_document(item, with_reasons=False) for item in plan.remove],
            "keep": [_item_document(item, with_reasons=True) for item in plan.keep],
            "earlier_changes": [
                {"finished_utc": change["finished_utc"], "kind": change["kind"]}
                for change in records.changes[:MAX_EARLIER_CHANGES]
            ],
            "earlier_changes_unknown": unknown,
            "first_cleanup": since is None,
            "needs_files_confirmed": since is None or unknown or bool(records.changes),
            "prune_pending": prune_pending(entries) if history_readable else False,
        }
    )
    return Computed(document, plan)


def compute_preview(ctx: Context) -> tuple[dict[str, Any], str]:
    """Compute and write the preview. A failure is written as an error preview with a fixed code."""
    try:
        computed = compute(ctx)
        document = computed.document
    except Refusal as refusal:
        document = _base_preview(ctx, read_evidence(ctx), _safe_policy(ctx))
        document["state"] = "blocked"
        document["blocked_reason"] = refusal.code
    except RetentionError as error:
        document = _base_preview(ctx, read_evidence(ctx), _safe_policy(ctx))
        document["error_code"] = error.code
        _log(ctx, {"event": "preview_failed", "error_code": error.code, "error": sanitize(str(error))})
    except Exception as error:  # noqa: BLE001 - the preview says it failed; nothing was removed
        document = _base_preview(ctx, read_evidence(ctx), _safe_policy(ctx))
        document["error_code"] = "failed"
        _log(ctx, {"event": "preview_failed", "error_code": "failed", "error": sanitize(str(error))})
    return document, write_preview(ctx, document)


def _safe_policy(ctx: Context) -> dict[str, Any] | None:
    try:
        return read_policy(ctx)
    except RetentionError:
        return None


# ---- Steps ----------------------------------------------------------------------------------------------------------


def configure(
    ctx: Context, *, enabled: bool, counts: tuple[int, int, int] | None
) -> dict[str, Any]:
    """Save the person's setting. On: the counts, bound to this plan, backup location and installation, and a preview.
    Off: the same document with enabled false (the counts are kept for next time), and nothing is removed."""
    config = ctx.config
    try:
        existing = read_policy(ctx)
    except RetentionError:
        existing = None
    if not enabled:
        daily, weekly, monthly = _policy_counts(existing)
        document = dict(existing) if isinstance(existing, dict) else {}
        document.update(
            {
                "schema": POLICY_SCHEMA,
                "schema_version": 1,
                "enabled": False,
                "keep_daily": daily,
                "keep_weekly": weekly,
                "keep_monthly": monthly,
                "group_by": GROUP_BY,
                "plan_id": config["plan_id"],
                "changed_utc": utc_now(),
            }
        )
        path = ctx.state / POLICY_NAME
        atomic_write_json(path, document)
        ctx.acl_check(path)
        preview = _base_preview(ctx, None, document)
        preview["state"] = "disabled"
        preview_sha = write_preview(ctx, preview)
        return {"state": "disabled", "policy_sha256": document.get("policy_sha256"), "preview_sha256": preview_sha}

    if counts is None:
        raise RetentionError("invalid_request", "turning clean-up on needs the three counts")
    daily, weekly, monthly = validate_counts(*counts)
    check_state_folder(ctx)
    evidence = read_evidence(ctx)
    if evidence is not None and _evidence_is_verified(evidence.document):
        repository_id = evidence.document["repository_id"]
    else:
        # There is no verified backup yet: the location is authenticated read-only, and clean-up waits for the first one.
        result = ctx.runner(restic_base(config, json_output=True) + ["--no-lock", "cat", "config"])
        try:
            repository_id = json.loads(result.stdout).get("id") if result.returncode == 0 else None
        except (json.JSONDecodeError, AttributeError):
            repository_id = None
        if not _is_hex64(repository_id):
            raise RetentionError("backup_location_unavailable", "the backup location did not answer")
    install_id = install_identity(ctx.install_root)
    digest = policy_digest(config["plan_id"], repository_id, install_id, daily, weekly, monthly)
    document = {
        "schema": POLICY_SCHEMA,
        "schema_version": 1,
        "enabled": True,
        "keep_daily": daily,
        "keep_weekly": weekly,
        "keep_monthly": monthly,
        "group_by": GROUP_BY,
        "plan_id": config["plan_id"],
        "repository_id": repository_id,
        "install_id": install_id,
        "policy_sha256": digest,
        "changed_utc": utc_now(),
    }
    path = ctx.state / POLICY_NAME
    atomic_write_json(path, document)
    ctx.acl_check(path)
    preview, preview_sha = compute_preview(ctx)
    return {
        "state": "configured",
        "policy_sha256": digest,
        "preview_sha256": preview_sha,
        "preview_state": preview["state"],
        "remove_count": preview["remove_count"],
        "keep_count": preview["keep_count"],
        "blocked_reason": preview["blocked_reason"],
    }


def preview_step(ctx: Context) -> dict[str, Any]:
    preview, preview_sha = compute_preview(ctx)
    return {
        "state": "previewed",
        "preview_sha256": preview_sha,
        "preview_state": preview["state"],
        "remove_count": preview["remove_count"],
        "keep_count": preview["keep_count"],
        "blocked_reason": preview["blocked_reason"],
        "error_code": preview["error_code"],
    }


def _relist(ctx: Context) -> set[str]:
    plan_tag, _generation_tag = backup_plan_tags(ctx.config)
    command = restic_base(ctx.config, json_output=True) + [
        "--no-lock", "snapshots", "--host", ctx.config["hostname"], "--tag", plan_tag,
    ]
    for _attempt in range(2):
        result = ctx.runner(command)
        if result.returncode != 0:
            continue
        try:
            listed = json.loads(result.stdout or "[]")
        except json.JSONDecodeError:
            continue
        if isinstance(listed, list) and all(isinstance(item, dict) and _is_hex64(item.get("id")) for item in listed):
            return {item["id"] for item in listed}
    raise RetentionError("relist_failed", "the backups could not be listed again after removing")


def apply_forget(
    ctx: Context,
    *,
    expected_preview_sha256: str,
    expected_remove_set_sha256: str,
    expected_remove_count: int,
    confirm_earlier_changes: bool,
) -> dict[str, Any]:
    """Remove exactly the confirmed list, or nothing."""
    config = ctx.config
    check_state_folder(ctx)
    if pending_journals(ctx.state):
        raise Refusal("pending_change")
    evidence = read_evidence(ctx)
    gate = evaluate_gates(ctx, evidence)
    if gate is not None:
        raise Refusal(gate)
    assert evidence is not None
    repository_id = evidence.document["repository_id"]
    install_id = install_identity(ctx.install_root)
    try:
        policy = read_policy(ctx)
    except RetentionError as error:
        raise Refusal("policy_inactive") from error
    if policy_problem(policy, config, repository_id, install_id) is not None:
        raise Refusal("policy_inactive")
    assert policy is not None

    # The preview must be exactly the file the person saw, made from the current setting and the current latest backup.
    preview_bytes = _read_regular_bytes(ctx.state / PREVIEW_NAME, MAX_PREVIEW_BYTES)
    if preview_bytes is None or hashlib.sha256(preview_bytes).hexdigest() != expected_preview_sha256:
        raise Refusal("preview_mismatch")
    ctx.acl_check(ctx.state / PREVIEW_NAME)
    preview = _parse_object(preview_bytes, PREVIEW_NAME)
    preview_policy = preview.get("policy") if isinstance(preview.get("policy"), dict) else {}
    preview_evidence = preview.get("evidence") if isinstance(preview.get("evidence"), dict) else {}
    if (
        preview.get("schema") != PREVIEW_SCHEMA
        or preview.get("state") != "ready"
        or preview.get("plan_id") != config["plan_id"]
        or preview.get("config_generation") != config["config_generation"]
        or preview.get("repository_id") != repository_id
        or preview_policy.get("policy_sha256") != policy["policy_sha256"]
        or preview.get("remove_set_sha256") != expected_remove_set_sha256
        or preview.get("remove_count") != expected_remove_count
        or preview_evidence.get("last_success_sha256") != evidence.sha256
    ):
        raise Refusal("preview_mismatch")

    # A fresh read-only listing must give the identical list; otherwise the new list is shown and nothing is removed.
    computed = compute(ctx)
    fresh = computed.document
    if (
        computed.plan is None
        or fresh["remove_set_sha256"] != preview.get("remove_set_sha256")
        or fresh["keep_set_sha256"] != preview.get("keep_set_sha256")
    ):
        if fresh["state"] == "blocked":
            raise Refusal(str(fresh["blocked_reason"]))
        preview_sha = write_preview(ctx, fresh)
        _log(ctx, {"event": "preview_changed", "remove_count": fresh["remove_count"]})
        return {"state": "preview_changed", "preview_sha256": preview_sha, "exit_code": EXIT_PREVIEW_CHANGED}
    if fresh["needs_files_confirmed"] and not confirm_earlier_changes:
        raise Refusal("earlier_changes_not_confirmed")

    plan = computed.plan
    confirmed = [item.id for item in plan.remove]
    if (
        len(confirmed) != expected_remove_count
        or set_digest(REMOVE_SET_DOMAIN, confirmed) != expected_remove_set_sha256
        or evidence.document["snapshot_id"] in confirmed
        or any(not _is_hex64(snapshot_id) for snapshot_id in confirmed)
    ):
        raise RetentionError("invariant_failed", "the confirmed list does not match what may be removed")
    keep_ids = {item.id for item in plan.keep}
    result: dict[str, Any] = {
        "confirmed_count": len(confirmed),
        "kept_count": len(keep_ids),
        "files_confirmed": bool(confirm_earlier_changes),
        "free_bytes_before": None,
        "prune_pending": bool(fresh.get("prune_pending")),
    }
    if not confirmed:
        result.update(
            {"state": "nothing_to_remove", "removed_count": 0,
             "removed_set_sha256": set_digest(REMOVE_SET_DOMAIN, []), "exit_code": EXIT_OK}
        )
        return result

    result["free_bytes_before"] = ctx.free_bytes(Path(config["repository"]))
    failed = False
    succeeded: list[str] = []
    for start in range(0, len(confirmed), FORGET_BATCH):
        batch = sorted(confirmed)[start : start + FORGET_BATCH]
        # Explicit backup IDs only: no keep rules, no --prune. This and apply_prune are the only places that remove.
        command = restic_base(config) + ["forget", *batch]
        _log(ctx, {"event": "forget_batch", "count": len(batch), "command": sanitized_command(command)[:-len(batch)]})
        exit_code: int | None
        try:
            with _open_log(ctx) as log_handle:
                exit_code = ctx.stream(command, log_handle)
        except Exception as error:  # noqa: BLE001 - earlier batches may have removed backups: list again below
            # The batch may or may not have run (its log could not be opened or written, for example on a full disk).
            # It counts as a failed batch, so the fresh listing below says what was removed and it is recorded.
            exit_code = None
            _log(ctx, {"event": "forget_batch_error", "error": sanitize(str(error))})
        if exit_code != 0:
            failed = True
            _log(ctx, {"event": "forget_batch_failed", "exit_code": exit_code})
            break
        succeeded.extend(batch)

    try:
        listed = _relist(ctx)
    except Exception:  # noqa: BLE001 - a listing that cannot start is a listing that failed
        # Some backups were removed but the list could not be read back. What the finished batches removed is reported,
        # nothing more runs, and the next clean-up lists again and frees the space.
        _log(ctx, {"event": "removal_unverified", "count": len(succeeded)})
        result.update(
            {
                "state": "partial",
                "removal_unverified": True,
                "removed_count": len(succeeded),
                "removed_set_sha256": set_digest(REMOVE_SET_DOMAIN, succeeded),
                "exit_code": EXIT_PARTIAL,
            }
        )
        return result
    result["removal_unverified"] = False
    removed = sorted(set(confirmed) - listed)
    missing_kept = sorted(keep_ids - listed)
    result.update(
        {
            "removed_count": len(removed),
            "removed_set_sha256": set_digest(REMOVE_SET_DOMAIN, removed),
        }
    )
    if missing_kept:
        _log(ctx, {"event": "kept_backup_missing", "count": len(missing_kept)})
        result.update({"state": "kept_backup_missing", "exit_code": EXIT_FAILED})
        return result
    if failed or len(removed) != len(confirmed):
        result.update({"state": "partial", "exit_code": EXIT_PARTIAL})
        return result
    result.update({"state": "removed", "exit_code": EXIT_OK})
    return result


class _open_log:
    """The request's log, or a sink when there is none."""

    def __init__(self, ctx: Context) -> None:
        self.ctx = ctx
        self.handle: Any = None

    def __enter__(self) -> Any:
        if self.ctx.log_path is None:
            self.handle = open(os.devnull, "w", encoding="utf-8")
        else:
            self.ctx.log_path.parent.mkdir(parents=True, exist_ok=True)
            self.handle = self.ctx.log_path.open("a", encoding="utf-8", newline="\n")
        return self.handle

    def __exit__(self, *_exc: Any) -> None:
        self.handle.close()


def apply_prune(ctx: Context) -> dict[str, Any]:
    """Free the space of removed backups. With little room left, only wholly unused data is deleted, which needs
    almost no extra space; otherwise partly used data is also tidied, up to 5% left unused."""
    config = ctx.config
    free = ctx.free_bytes(Path(config["repository"]))
    minimum = int(float(config.get("minimum_free_gib", 0)) * 1024**3)
    low_space = free < minimum
    command = restic_base(config) + ["prune", "--max-unused", "unlimited" if low_space else "5%"]
    _log(ctx, {"event": "prune", "low_space": low_space, "command": sanitized_command(command)})
    with _open_log(ctx) as log_handle:
        exit_code = ctx.stream(command, log_handle)
    return {
        "state": "pruned" if exit_code == 0 else "prune_failed",
        "prune_completed": exit_code == 0,
        "prune_mode": "unused_only" if low_space else "standard",
        "restic_exit_code": exit_code,
        "exit_code": EXIT_OK if exit_code == 0 else EXIT_FAILED,
    }


def apply_check(ctx: Context) -> dict[str, Any]:
    command = restic_base(ctx.config) + ["check"]
    _log(ctx, {"event": "check", "command": sanitized_command(command)})
    with _open_log(ctx) as log_handle:
        exit_code = ctx.stream(command, log_handle)
    return {
        "state": "checked" if exit_code == 0 else "check_failed",
        "check_completed": exit_code == 0,
        "restic_exit_code": exit_code,
        "exit_code": EXIT_OK if exit_code == 0 else EXIT_FAILED,
    }


def apply_record(
    ctx: Context,
    *,
    outcome: str,
    request_nonce: str,
    started_utc: str,
    confirmed_count: int,
    removed_count: int,
    removed_set_sha256: str,
    prune_completed: bool,
    check_completed: bool,
    prune_mode: str,
    free_bytes_before: int | None,
    files_confirmed: bool,
) -> dict[str, Any]:
    """Record how the clean-up went, then list again what is there now."""
    if outcome not in OUTCOMES:
        raise RetentionError("invalid_request", "unknown clean-up outcome")
    entries, readable = read_history(ctx)
    if not readable:
        entries = []
    policy = _safe_policy(ctx)
    daily, weekly, monthly = _policy_counts(policy)
    free_after = ctx.free_bytes(Path(ctx.config["repository"]))
    entry = {
        "request_nonce": request_nonce,
        "started_utc": started_utc,
        "finished_utc": utc_now(),
        "outcome": outcome,
        "confirmed_count": confirmed_count,
        "removed_count": removed_count,
        "removed_set_sha256": removed_set_sha256,
        "prune_completed": prune_completed,
        "check_completed": check_completed,
        "prune_mode": prune_mode,
        "files_confirmed": files_confirmed,
        "keep_daily": daily,
        "keep_weekly": weekly,
        "keep_monthly": monthly,
        "free_bytes_before": free_bytes_before,
        "free_bytes_after": free_after,
    }
    entries = (entries + [entry])[-MAX_HISTORY:]
    path = ctx.state / HISTORY_NAME
    atomic_write_json(
        path,
        {
            "schema": HISTORY_SCHEMA,
            "schema_version": 1,
            "plan_id": ctx.config["plan_id"],
            "updated_utc": utc_now(),
            "entries": entries,
        },
    )
    ctx.acl_check(path)
    preview, preview_sha = compute_preview(ctx)
    return {
        "state": "recorded",
        "free_bytes_after": free_after,
        "preview_sha256": preview_sha,
        "preview_state": preview["state"],
        "exit_code": EXIT_OK,
    }


# ---- Command line ---------------------------------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Clean-up of old backups (run only by Manage-Retention.ps1).")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-config-sha256", required=True)
    parser.add_argument("--request-nonce", required=True)
    parser.add_argument(
        "--step",
        required=True,
        choices=("configure", "preview", "apply-forget", "apply-prune", "apply-check", "apply-record"),
    )
    parser.add_argument("--enabled", choices=("0", "1"))
    parser.add_argument("--keep-daily", type=int)
    parser.add_argument("--keep-weekly", type=int)
    parser.add_argument("--keep-monthly", type=int)
    parser.add_argument("--expected-preview-sha256")
    parser.add_argument("--expected-remove-set-sha256")
    parser.add_argument("--expected-remove-count", type=int)
    parser.add_argument("--confirm-earlier-changes", choices=("0", "1"))
    parser.add_argument("--outcome", choices=sorted(OUTCOMES))
    parser.add_argument("--started-utc")
    parser.add_argument("--confirmed-count", type=int, default=0)
    parser.add_argument("--removed-count", type=int, default=0)
    parser.add_argument("--removed-set-sha256")
    parser.add_argument("--prune-completed", choices=("0", "1"), default="0")
    parser.add_argument("--check-completed", choices=("0", "1"), default="0")
    parser.add_argument("--prune-mode", choices=("standard", "unused_only", "none"), default="none")
    parser.add_argument("--free-bytes-before", type=int)
    parser.add_argument("--files-confirmed", choices=("0", "1"), default="0")
    parser.add_argument("--test-root", type=Path)
    return parser.parse_args(argv)


def _strictly_within(child: Path, parent: Path) -> bool:
    child_text = os.path.normcase(str(child))
    parent_text = os.path.normcase(str(parent)).rstrip("\\/")
    return child_text.startswith(parent_text + os.sep)


def _test_mode_acl_check(_path: Path) -> None:
    """A disposable test folder in the user's temporary folder has the user's permissions, not the protected ones."""


def _validate_test_root(test_root: Path, config_path: Path) -> None:
    if is_administrator():
        raise RetentionError("invalid_request", "--test-root is refused for an administrator")
    temporary = Path(tempfile.gettempdir()).resolve()
    root = test_root.resolve(strict=True)
    if not _strictly_within(root, temporary) or not _strictly_within(config_path, root):
        raise RetentionError("invalid_request", "--test-root must be a disposable folder in the temporary folder")


def _required(value: Any, name: str) -> Any:
    if value is None:
        raise RetentionError("invalid_request", f"{name} is required for this step")
    return value


def run_step(args: argparse.Namespace, ctx: Context) -> dict[str, Any]:
    step = args.step
    if step != "configure" or args.enabled != "0":
        # Turning clean-up off is the safe direction: it stays possible while a change journal is pending.
        if pending_journals(ctx.state):
            raise Refusal("pending_change")
    if step == "configure":
        enabled = _required(args.enabled, "--enabled") == "1"
        counts = (args.keep_daily, args.keep_weekly, args.keep_monthly) if enabled else None
        if enabled and None in counts:  # type: ignore[operator]
            raise RetentionError("invalid_request", "turning clean-up on needs the three counts")
        result = configure(ctx, enabled=enabled, counts=counts)  # type: ignore[arg-type]
        result["exit_code"] = EXIT_OK
        return result
    if step == "preview":
        result = preview_step(ctx)
        result["exit_code"] = EXIT_OK
        return result
    if step == "apply-forget":
        preview_sha = _required(args.expected_preview_sha256, "--expected-preview-sha256")
        remove_sha = _required(args.expected_remove_set_sha256, "--expected-remove-set-sha256")
        count = _required(args.expected_remove_count, "--expected-remove-count")
        if not _is_hex64(preview_sha) or not _is_hex64(remove_sha) or not 0 <= count <= MAX_PLAN_BACKUPS:
            raise RetentionError("invalid_request", "the confirmed list is not described correctly")
        return apply_forget(
            ctx,
            expected_preview_sha256=preview_sha,
            expected_remove_set_sha256=remove_sha,
            expected_remove_count=count,
            confirm_earlier_changes=_required(args.confirm_earlier_changes, "--confirm-earlier-changes") == "1",
        )
    if step == "apply-prune":
        return apply_prune(ctx)
    if step == "apply-check":
        return apply_check(ctx)
    removed_set = args.removed_set_sha256 or set_digest(REMOVE_SET_DOMAIN, [])
    if not _is_hex64(removed_set):
        raise RetentionError("invalid_request", "the removed set is not described correctly")
    return apply_record(
        ctx,
        outcome=_required(args.outcome, "--outcome"),
        request_nonce=args.request_nonce,
        started_utc=_required(args.started_utc, "--started-utc"),
        confirmed_count=args.confirmed_count,
        removed_count=args.removed_count,
        removed_set_sha256=removed_set,
        prune_completed=args.prune_completed == "1",
        check_completed=args.check_completed == "1",
        prune_mode=args.prune_mode,
        free_bytes_before=args.free_bytes_before,
        files_confirmed=args.files_confirmed == "1",
    )


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        if not _is_hex64(args.request_nonce) or not _is_hex64(args.expected_config_sha256):
            raise RetentionError("invalid_request", "the request nonce or configuration hash is invalid")
        config_path = args.config.resolve(strict=True)
        acl_check: Callable[[Path], None] = admin_only_acl
        if args.test_root is not None:
            _validate_test_root(args.test_root, config_path)
            acl_check = _test_mode_acl_check
        if sha256_file(config_path) != args.expected_config_sha256:
            raise RetentionError("configuration_changed", "the backup configuration changed after the request")
        # Turning clean-up off never reads the backup location, so an unplugged drive cannot keep it on.
        disabling = args.step == "configure" and args.enabled == "0"
        config = load_config(config_path, require_repository=not disabling)
        state = Path(config["state_directory"])
        ctx = Context(
            config=config,
            install_root=config_path.parent,
            acl_check=acl_check,
            log_path=state / "logs" / f"retention-{args.request_nonce}.jsonl.log",
        )
        result = run_step(args, ctx)
    except Refusal as refusal:
        result = {"state": "refused", "refusal_code": refusal.code, "exit_code": EXIT_REFUSED}
    except RetentionError as error:
        result = {"state": "failed", "error_code": error.code, "error": sanitize(str(error)), "exit_code": EXIT_FAILED}
    except Exception as error:  # noqa: BLE001 - reported as one fixed-shape answer
        result = {"state": "failed", "error_code": "failed", "error": sanitize(str(error)), "exit_code": EXIT_FAILED}
    exit_code = int(result.pop("exit_code"))
    print(json.dumps(result, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
