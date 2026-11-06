"""Record an explicit, plan-bound acknowledgement of one suspicious backup run.

Acknowledgement records that the operator reviewed the exact verified evidence.
It does not pause or gate DriveFS upload. The anomaly record and maintenance
hold remain intact for future destructive maintenance policy; no snapshot,
repository file, or backup telemetry is rewritten by this workflow.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
from typing import Any

from credential_repair import sha256_file, validate_runtime_manifest
from recovery_health import utc_now
from restic_common import atomic_write_json, load_config_under_lock
from secret_store import _current_user_sid, _security_sddl, restrict_acl, verify_restricted_acl


SCHEMA = "ResticBackuper.AnomalyReview.v1"
ACKNOWLEDGEMENT_NAME = "anomaly-acknowledgement.json"
HISTORY_NAME = "anomaly-review-history.json"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_HISTORY = 100


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--expected-config-sha256", required=True)
    parser.add_argument("--expected-plan-id", required=True)
    parser.add_argument("--expected-generation", type=int, required=True)
    parser.add_argument("--expected-user-sid", required=True)
    parser.add_argument("--expected-run-id", required=True)
    parser.add_argument("--expected-snapshot-id", required=True)
    parser.add_argument("--expected-evidence-sha256", required=True)
    return parser.parse_args(argv)


def is_administrator() -> bool:
    return os.name == "nt" and bool(ctypes.windll.shell32.IsUserAnAdmin())


def _normal_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink() and not (
        hasattr(os.path, "isjunction") and os.path.isjunction(path)
    )


ADMIN_SIDS = frozenset({"SY", "BA", "S-1-5-18", "S-1-5-32-544"})
# Any right that changes an object or its access: write or append data (add a file or folder), write extended attributes,
# delete a child, write attributes, delete, change the access list or the owner, and the generic and maximum-allowed forms.
WRITE_RIGHTS = (
    0x00000002 | 0x00000004 | 0x00000010 | 0x00000040 | 0x00000100
    | 0x00010000 | 0x00040000 | 0x00080000
    | 0x02000000 | 0x10000000 | 0x40000000
)
RIGHT_TOKENS = {
    "GA": 0x10000000, "GR": 0x80000000, "GW": 0x40000000, "GX": 0x20000000,
    "RC": 0x00020000, "SD": 0x00010000, "WD": 0x00040000, "WO": 0x00080000,
    "FA": 0x001F01FF, "FR": 0x00120089, "FW": 0x00120116, "FX": 0x001200A0,
    "CC": 0x00000001, "DC": 0x00000002, "LC": 0x00000004, "SW": 0x00000008,
    "RP": 0x00000010, "WP": 0x00000020, "DT": 0x00000040, "LO": 0x00000080,
    "CR": 0x00000100,
}


def _rights_mask(rights: str) -> int | None:
    if rights[:2].casefold() == "0x":
        try:
            return int(rights, 16)
        except ValueError:
            return None
    if not rights or len(rights) % 2:
        return None
    mask = 0
    for index in range(0, len(rights), 2):
        bit = RIGHT_TOKENS.get(rights[index : index + 2])
        if bit is None:
            return None
        mask |= bit
    return mask


def admin_only_writable_problem(sddl: str) -> str | None:
    """Why a security descriptor (owner and access list) lets anyone but Administrators or SYSTEM change the object, or None.

    Inherited entries count like any other, and deny entries and entries that apply only to children are skipped.
    """
    owner = re.search(r"O:(.*?)(?=[GDS]:)", sddl)
    if owner is None or owner.group(1) not in ADMIN_SIDS:
        return "it is not owned by Administrators or SYSTEM"
    start = sddl.find("D:")
    if start < 0:
        return "it has no access list"
    dacl = sddl[start:]
    if "NO_ACCESS_CONTROL" in dacl.split("(", 1)[0]:
        return "it has no access list"
    entries = re.findall(r"\(([^)]*)\)", dacl)
    if not entries:
        return "its access list is empty"
    for entry in entries:
        fields = entry.split(";")
        if len(fields) < 6:
            return f"it has an access entry that cannot be read: {entry}"
        flags = {fields[1][index : index + 2] for index in range(0, len(fields[1]), 2)}
        if fields[0] == "D" or "IO" in flags:
            continue
        if fields[0] != "A":
            return f"it has an unexpected access entry: {entry}"
        if fields[5] in ADMIN_SIDS:
            continue
        mask = _rights_mask(fields[2])
        if mask is None or mask & WRITE_RIGHTS:
            return f"someone other than Administrators can change it: {entry}"
    return None


def _verify_backup_evidence_acl(path: Path) -> None:
    """Accept the evidence file the backup wrote, with its folder's admin-only permissions, as well as a restricted one.

    backup.py writes last-success.json with the permissions it inherits from the state folder (Administrators and SYSTEM
    change it, the user reads it), not the restricted form verify_restricted_acl wants, so that check alone refused every
    review. Either form is fine as long as only Administrators or SYSTEM can change the file or the folder that holds it.
    """
    try:
        verify_restricted_acl(path)
        return
    except RuntimeError:
        pass
    for target, label in ((path, "file"), (path.parent, "folder")):
        problem = admin_only_writable_problem(_security_sddl(target, include_owner=True))
        if problem:
            raise RuntimeError(f"The backup's evidence {label} is not protected ({problem}): {target}")


def _read_protected_object(path: Path, *, backup_evidence: bool = False) -> dict[str, Any]:
    if not _normal_file(path) or path.stat().st_size <= 0 or path.stat().st_size > MAX_JSON_BYTES:
        raise RuntimeError(f"Protected review evidence is missing or unsafe: {path.name}")
    if backup_evidence:
        _verify_backup_evidence_acl(path)
    else:
        verify_restricted_acl(path)
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise RuntimeError(f"Protected review evidence is not one JSON object: {path.name}")
    return value


def _write_protected(path: Path, value: Any) -> None:
    atomic_write_json(path, value)
    restrict_acl(path)
    verify_restricted_acl(path)


def _anomaly_sha256(anomaly: dict[str, Any]) -> str:
    canonical = json.dumps(
        anomaly,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _append_history(state: Path, acknowledgement: dict[str, Any]) -> None:
    path = state / HISTORY_NAME
    entries: list[Any] = []
    if path.exists() or path.is_symlink():
        document = _read_protected_object(path)
        if document.get("schema_version") != 1 or not isinstance(document.get("reviews"), list):
            raise RuntimeError("Anomaly-review history is invalid.")
        entries = document["reviews"][-(MAX_HISTORY - 1) :]
    entries.append(acknowledgement)
    _write_protected(
        path,
        {"schema_version": 1, "updated_utc": utc_now(), "reviews": entries},
    )


def approve(
    config_path: Path,
    *,
    expected_config_sha256: str,
    expected_plan_id: str,
    expected_generation: int,
    expected_user_sid: str,
    expected_run_id: str,
    expected_snapshot_id: str,
    expected_evidence_sha256: str,
    sid_reader=_current_user_sid,
    require_manifest: bool = True,
) -> dict[str, Any]:
    config_path = config_path.resolve(strict=True)
    for value, label in (
        (expected_config_sha256, "configuration hash"),
        (expected_evidence_sha256, "backup evidence hash"),
    ):
        if not re.fullmatch(r"[0-9a-f]{64}", value):
            raise RuntimeError(f"The expected {label} is invalid.")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_snapshot_id):
        raise RuntimeError("The expected snapshot identity is invalid.")
    if not re.fullmatch(r"[0-9A-Za-z._+-]{1,160}", expected_run_id):
        raise RuntimeError("The expected run identity is invalid.")
    if sha256_file(config_path) != expected_config_sha256:
        raise RuntimeError("The protected configuration changed before anomaly review.")
    if sid_reader().casefold() != expected_user_sid.casefold():
        raise RuntimeError("Anomaly approval must be confirmed by the requesting Windows account.")
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
        if "anomaly_review.py" not in names:
            raise RuntimeError("The protected runtime manifest does not authorize anomaly review.")

    config, run_lock = load_config_under_lock(config_path)
    try:
        if sha256_file(config_path) != expected_config_sha256:
            raise RuntimeError("The protected configuration changed while waiting for anomaly review.")
        if config["plan_id"] != expected_plan_id or config["config_generation"] != expected_generation:
            raise RuntimeError("The anomaly-review request names another backup plan generation.")
        state = Path(config["state_directory"])
        evidence_path = state / "last-success.json"
        evidence = _read_protected_object(evidence_path, backup_evidence=True)
        if sha256_file(evidence_path) != expected_evidence_sha256:
            raise RuntimeError("The latest verified backup changed after the anomaly was reviewed.")
        if (
            evidence.get("state") not in {"success", "success_unchanged"}
            or evidence.get("verification_complete") is not True
            or evidence.get("maintenance_hold") is not True
            or evidence.get("run_id") != expected_run_id
            or evidence.get("snapshot_id") != expected_snapshot_id
            or evidence.get("plan_id") != config["plan_id"]
            or evidence.get("config_generation") != config["config_generation"]
        ):
            raise RuntimeError("The selected backup is not the current verified anomaly hold.")
        anomaly = evidence.get("change_anomaly")
        if (
            not isinstance(anomaly, dict)
            or anomaly.get("hold") is not True
            or anomaly.get("status") != "hold"
            or not isinstance(anomaly.get("reasons"), list)
            or len(anomaly["reasons"]) < 1
        ):
            raise RuntimeError("The selected backup has no valid change-anomaly evidence.")
        repository_id = evidence.get("repository_id")
        if not isinstance(repository_id, str) or not re.fullmatch(r"[0-9a-f]{64}", repository_id):
            raise RuntimeError("The selected backup has no canonical repository identity.")

        acknowledgement = {
            "schema": SCHEMA,
            "schema_version": 1,
            "decision": "approved",
            "approved_utc": utc_now(),
            "reviewer_sid": expected_user_sid,
            "scope": ["anomaly_review_acknowledgement"],
            "maintenance_hold_remains": True,
            "plan_id": config["plan_id"],
            "config_generation": config["config_generation"],
            "repository_id": repository_id,
            "run_id": expected_run_id,
            "snapshot_id": expected_snapshot_id,
            "backup_evidence_sha256": expected_evidence_sha256,
            "anomaly_sha256": _anomaly_sha256(anomaly),
            "reasons": [str(item)[:100] for item in anomaly["reasons"][:20]],
            "snapshots_modified": False,
            "repository_modified": False,
        }
        acknowledgement_path = state / ACKNOWLEDGEMENT_NAME
        if acknowledgement_path.exists() or acknowledgement_path.is_symlink():
            existing = _read_protected_object(acknowledgement_path)
            identity_fields = (
                "decision",
                "plan_id",
                "config_generation",
                "repository_id",
                "run_id",
                "snapshot_id",
                "backup_evidence_sha256",
                "anomaly_sha256",
            )
            if all(existing.get(name) == acknowledgement.get(name) for name in identity_fields):
                result = dict(existing)
                result["state"] = "already_approved"
                return result
        _write_protected(acknowledgement_path, acknowledgement)
        _append_history(state, acknowledgement)
        result = dict(acknowledgement)
        result["state"] = "approved"
        result["acknowledgement_file"] = str(acknowledgement_path)
        return result
    finally:
        run_lock.__exit__(None, None, None)


def sanitize(message: str) -> str:
    value = (message or "Anomaly review failed.").strip()
    if any(token in value.casefold() for token in ("password", "dpapi", "restic_")):
        return "Anomaly review failed without exposing credential details."
    return value[:1000]


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not is_administrator():
        print(json.dumps({"schema": SCHEMA, "schema_version": 1, "state": "failed", "error": "Anomaly approval requires Windows approval."}))
        return 2
    try:
        result = approve(
            args.config,
            expected_config_sha256=args.expected_config_sha256,
            expected_plan_id=args.expected_plan_id,
            expected_generation=args.expected_generation,
            expected_user_sid=args.expected_user_sid,
            expected_run_id=args.expected_run_id,
            expected_snapshot_id=args.expected_snapshot_id,
            expected_evidence_sha256=args.expected_evidence_sha256,
        )
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except Exception as error:
        print(json.dumps({"schema": SCHEMA, "schema_version": 1, "state": "failed", "finished_utc": utc_now(), "error": sanitize(str(error))}, indent=2, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
