#!/usr/bin/env python3
"""Fail-closed Google Drive for desktop mirror verification.

The verifier correlates a locally verified Restic inventory with DriveFS's
cloud metadata. It never prints account identifiers, cloud IDs, file paths, or
file contents. DriveFS's databases are undocumented, so every schema and
product-version dependency is allowlisted explicitly.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
from typing import Any, Iterable


ALLOWED_DRIVEFS_VERSION = "128.0.0.0"
ROOT_DATABASE_VERSIONS = (2, 4)
MIRROR_DATABASE_VERSIONS = (0, 14)
METADATA_DATABASE_VERSIONS = (138, 24)

TABLE_FINGERPRINTS: dict[str, list[tuple[str, str, int, int]]] = {
    "roots": [
        ("root_id", "INTEGER", 0, 1),
        ("metadata", "BLOB", 0, 0),
        ("media_id", "TEXT", 1, 0),
        ("title", "TEXT", 1, 0),
        ("root_path", "TEXT", 1, 0),
        ("account_token", "TEXT", 1, 0),
        ("sync_type", "INTEGER", 1, 0),
        ("destination", "INTEGER", 1, 0),
        ("medium", "INTEGER", 1, 0),
        ("state", "INTEGER", 1, 0),
        ("one_shot", "BOOL", 1, 0),
        ("is_my_drive", "BOOL", 1, 0),
        ("doc_id", "TEXT", 1, 0),
        ("last_seen_absolute_path", "TEXT", 1, 0),
    ],
    "root_config": [
        ("root_id", "INTEGER", 0, 1),
        ("root_state", "INTEGER", 1, 0),
        ("local_stable_id", "INTEGER", 0, 0),
        ("item_id", "TEXT", 0, 0),
        ("is_my_drive", "BOOLEAN", 0, 0),
    ],
    "machine_root": [
        ("stable_id", "INTEGER", 0, 1),
        ("item_id", "TEXT", 1, 0),
    ],
    "mirror_item": [
        ("local_stable_id", "INTEGER", 0, 1),
        ("stable_id", "INTEGER", 1, 0),
        ("inode", "INTEGER", 1, 0),
        ("volume", "TEXT", 1, 0),
        ("parent_local_stable_id", "INTEGER", 0, 0),
        ("local_filename", "TEXT", 0, 0),
        ("cloud_filename", "TEXT", 0, 0),
        ("local_mtime_ms", "INTEGER", 0, 0),
        ("cloud_mtime_ms", "INTEGER", 0, 0),
        ("local_md5_checksum", "TEXT", 0, 0),
        ("cloud_md5_checksum", "TEXT", 0, 0),
        ("local_size", "INTEGER", 0, 0),
        ("cloud_size", "INTEGER", 0, 0),
        ("local_type", "INTEGER", 1, 0),
        ("cloud_type", "INTEGER", 1, 0),
        ("local_version", "INTEGER", 1, 0),
        ("cloud_version", "INTEGER", 1, 0),
        ("storage_policy", "INTEGER", 1, 0),
        ("shared", "BOOLEAN", 0, 0),
        ("read_only", "BOOLEAN", 0, 0),
        ("target_version", "INTEGER", 0, 0),
        ("is_root", "BOOLEAN", 0, 0),
    ],
    "cloud_relations": [
        ("child_local_stable_id", "INTEGER", 1, 0),
        ("child_stable_id", "INTEGER", 1, 0),
        ("parent_stable_id", "INTEGER", 1, 0),
    ],
    "pending_uploads": [
        ("local_stable_id", "INTEGER", 0, 1),
        ("stable_id", "INTEGER", 1, 0),
    ],
    "queued_uploads": [
        ("stable_id", "INTEGER", 0, 1),
        ("local_stable_id", "INTEGER", 1, 0),
        ("size", "INTEGER", 1, 0),
        ("md5_checksum", "TEXT", 1, 0),
        ("mtime_ms", "INTEGER", 1, 0),
    ],
    "pending_deletes": [
        ("local_stable_id", "INTEGER", 0, 1),
        ("root_id", "INTEGER", 1, 0),
    ],
    "stable_ids": [
        ("stable_id", "INTEGER", 1, 1),
        ("cloud_id", "TEXT", 0, 0),
    ],
    "items": [
        ("stable_id", "INTEGER", 1, 1),
        ("id", "TEXT", 1, 0),
        ("proto", "BLOB", 0, 0),
        ("trashed", "BOOLEAN", 1, 0),
        ("starred", "BOOLEAN", 1, 0),
        ("is_owner", "BOOLEAN", 1, 0),
        ("mime_type", "TEXT", 1, 0),
        ("is_folder", "BOOLEAN", 1, 0),
        ("modified_date", "INTEGER", 0, 0),
        ("shared_with_me_date", "INTEGER", 0, 0),
        ("viewed_by_me_date", "INTEGER", 0, 0),
        ("file_size", "INTEGER", 0, 0),
        ("is_tombstone", "BOOLEAN", 1, 0),
        ("local_title", "TEXT", 0, 0),
        ("subscribed", "BOOLEAN", 1, 0),
        ("team_drive_stable_id", "INTEGER", 0, 0),
        ("local_title_tokenized", "TEXT", 0, 0),
        ("inaccessible_inheritance_broken", "BOOLEAN", 1, 0),
    ],
    "operations": [
        ("id", "INTEGER", 1, 1),
        ("proto", "BLOB", 0, 0),
    ],
}


class UnsupportedError(RuntimeError):
    """The installed DriveFS version/schema has not been audited."""


class PendingError(RuntimeError):
    """The provider has not yet accepted an exact expected inventory."""

    def __init__(self, category: str, mismatch_count: int = 0) -> None:
        super().__init__(category)
        self.category = category
        self.mismatch_count = mismatch_count


def normalized(path: Path) -> str:
    return os.path.normcase(os.path.abspath(str(path)))


def ensure_descendant(path: Path, parent: Path) -> None:
    try:
        path.relative_to(parent)
    except ValueError as error:
        raise UnsupportedError("path_boundary") from error


def read_versions(connection: sqlite3.Connection, schema: str = "main") -> tuple[int, int]:
    user = int(connection.execute(f"PRAGMA {schema}.user_version").fetchone()[0])
    version = int(connection.execute(f"PRAGMA {schema}.schema_version").fetchone()[0])
    return user, version


def open_read_only(path: Path) -> sqlite3.Connection:
    if not path.is_file():
        raise UnsupportedError("database_missing")
    uri = path.resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=5)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    connection.execute("PRAGMA trusted_schema=OFF")
    connection.execute("PRAGMA busy_timeout=5000")
    return connection


def table_fingerprint(
    connection: sqlite3.Connection, table: str, schema: str = "main"
) -> list[tuple[str, str, int, int]]:
    return [
        (str(row[1]), str(row[2]), int(row[3]), int(row[5]))
        for row in connection.execute(f"PRAGMA {schema}.table_info({table})")
    ]


def require_table(
    connection: sqlite3.Connection, table: str, schema: str = "main"
) -> None:
    if table_fingerprint(connection, table, schema) != TABLE_FINGERPRINTS[table]:
        raise UnsupportedError("schema_fingerprint")


def drivefs_process() -> tuple[str, str]:
    powershell = Path(os.environ.get("SystemRoot", r"C:\Windows")) / (
        r"System32\WindowsPowerShell\v1.0\powershell.exe"
    )
    command = (
        "$p=Get-Process -Name GoogleDriveFS -ErrorAction Stop | "
        "Sort-Object StartTime | Select-Object -First 1;"
        "[pscustomobject]@{"
        "path=$p.Path;"
        "version=$p.MainModule.FileVersionInfo.FileVersion"
        "}|ConvertTo-Json -Compress"
    )
    try:
        completed = subprocess.run(
            [
                str(powershell),
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                command,
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        document = json.loads(completed.stdout)
        executable = str(document["path"])
        version = str(document["version"])
    except (OSError, subprocess.SubprocessError, KeyError, ValueError, json.JSONDecodeError) as error:
        raise PendingError("drivefs_not_running") from error
    if not executable.lower().endswith(r"\googledrivefs.exe"):
        raise UnsupportedError("drivefs_executable")
    if version != ALLOWED_DRIVEFS_VERSION:
        raise UnsupportedError("drivefs_version")
    return executable, version


def file_md5(path: Path) -> tuple[int, str]:
    digest = hashlib.md5(usedforsecurity=False)
    length = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            length += len(block)
            digest.update(block)
    return length, digest.hexdigest()


def read_inventory(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise UnsupportedError("inventory_missing")
    entries: list[dict[str, Any]] = []
    seen: set[str] = set()
    with gzip.open(path, "rt", encoding="utf-8") as stream:
        for line in stream:
            value = json.loads(line)
            relative = str(value.get("relative_path", ""))
            length = value.get("length")
            sha256 = str(value.get("sha256", ""))
            md5 = str(value.get("md5", ""))
            if (
                not relative
                or Path(relative).is_absolute()
                or any(part in ("", ".", "..") for part in relative.replace("\\", "/").split("/"))
                or not isinstance(length, int)
                or length < 0
                or not re.fullmatch(r"[0-9a-f]{64}", sha256)
                or not re.fullmatch(r"[0-9a-f]{32}", md5)
            ):
                raise UnsupportedError("inventory_format")
            key = relative.replace("\\", "/").casefold()
            if key in seen:
                raise UnsupportedError("inventory_collision")
            seen.add(key)
            entries.append(
                {
                    "relative_path": relative,
                    "length": length,
                    "sha256": sha256,
                    "md5": md5,
                }
            )
    if not entries:
        raise UnsupportedError("inventory_empty")
    return entries


def provider_relative(path: Path, root: Path) -> str:
    ensure_descendant(path, root)
    return path.relative_to(root).as_posix()


def expected_files(
    destination_root: Path,
    repository: Path,
    inventory_path: Path,
    extras: Iterable[Path],
) -> tuple[dict[str, dict[str, Any]], str]:
    inventory = read_inventory(inventory_path)
    repository_prefix = provider_relative(repository, destination_root)
    expected: dict[str, dict[str, Any]] = {}
    for entry in inventory:
        absolute = repository / Path(str(entry["relative_path"]))
        relative = provider_relative(absolute, destination_root)
        key = relative.casefold()
        if key in expected:
            raise UnsupportedError("expected_collision")
        expected[key] = {
            "provider_path": relative,
            "length": int(entry["length"]),
            "md5": str(entry["md5"]),
        }
    for path in extras:
        resolved = path.resolve(strict=True)
        relative = provider_relative(resolved, destination_root)
        length, md5 = file_md5(resolved)
        key = relative.casefold()
        if key in expected:
            raise UnsupportedError("extra_collision")
        expected[key] = {
            "provider_path": relative,
            "length": length,
            "md5": md5,
        }
    return expected, repository_prefix


def load_tree(
    connection: sqlite3.Connection, root_local_id: int
) -> dict[str, sqlite3.Row]:
    rows = list(
        connection.execute(
            """
            SELECT mi.local_stable_id, mi.stable_id, mi.parent_local_stable_id,
                   mi.local_filename, mi.cloud_filename,
                   mi.local_md5_checksum, mi.cloud_md5_checksum,
                   mi.local_size, mi.cloud_size,
                   mi.local_type, mi.cloud_type, mi.cloud_version,
                   mi.is_root,
                   s.cloud_id, i.id AS item_id, i.trashed, i.is_folder,
                   i.file_size, i.is_tombstone
            FROM mirror_item AS mi
            LEFT JOIN meta.stable_ids AS s ON s.stable_id = mi.stable_id
            LEFT JOIN meta.items AS i ON i.stable_id = mi.stable_id
            """
        )
    )
    by_local_id = {int(row["local_stable_id"]): row for row in rows}
    if len(by_local_id) != len(rows) or root_local_id not in by_local_id:
        raise UnsupportedError("tree_identity")
    children: dict[int, list[sqlite3.Row]] = {}
    for row in rows:
        parent = row["parent_local_stable_id"]
        if parent is not None:
            children.setdefault(int(parent), []).append(row)

    result: dict[str, sqlite3.Row] = {}
    visited: set[int] = set()
    stack: list[tuple[int, str, int]] = [(root_local_id, "", 0)]
    while stack:
        local_id, relative, depth = stack.pop()
        if depth > 512 or local_id in visited:
            raise UnsupportedError("tree_cycle_or_depth")
        visited.add(local_id)
        for child in children.get(local_id, []):
            name = child["local_filename"]
            if not isinstance(name, str) or not name or "/" in name or "\\" in name:
                raise UnsupportedError("tree_filename")
            child_relative = name if not relative else f"{relative}/{name}"
            key = child_relative.casefold()
            if key in result:
                raise UnsupportedError("tree_collision")
            result[key] = child
            stack.append((int(child["local_stable_id"]), child_relative, depth + 1))
    return result


def valid_cloud_identity(row: sqlite3.Row) -> bool:
    cloud_id = row["cloud_id"]
    item_id = row["item_id"]
    return (
        isinstance(cloud_id, str)
        and bool(cloud_id)
        and isinstance(item_id, str)
        and cloud_id == item_id
        and isinstance(row["trashed"], int)
        and row["trashed"] == 0
        and isinstance(row["is_tombstone"], int)
        and row["is_tombstone"] == 0
    )


def integer_equals(value: Any, expected: int) -> bool:
    return isinstance(value, int) and value == expected


def verify_file(row: sqlite3.Row, expected: dict[str, Any]) -> bool:
    md5 = str(expected["md5"])
    length = int(expected["length"])
    return (
        integer_equals(row["local_type"], 1)
        and integer_equals(row["cloud_type"], 1)
        and row["local_filename"] == row["cloud_filename"]
        and integer_equals(row["local_size"], length)
        and integer_equals(row["cloud_size"], length)
        and isinstance(row["local_md5_checksum"], str)
        and row["local_md5_checksum"] == md5
        and isinstance(row["cloud_md5_checksum"], str)
        and row["cloud_md5_checksum"] == md5
        and row["cloud_version"] is not None
        and valid_cloud_identity(row)
        and integer_equals(row["is_folder"], 0)
        and integer_equals(row["file_size"], length)
    )


def verify_directory(row: sqlite3.Row) -> bool:
    return (
        integer_equals(row["local_type"], 0)
        and integer_equals(row["cloud_type"], 0)
        and row["local_filename"] == row["cloud_filename"]
        and valid_cloud_identity(row)
        and integer_equals(row["is_folder"], 1)
    )


def sample(args: argparse.Namespace) -> dict[str, Any]:
    _, provider_version = drivefs_process()
    local_app_data = Path(os.environ["LOCALAPPDATA"]).resolve()
    drivefs_root = local_app_data / "Google" / "DriveFS"
    destination_root = Path(args.destination_root).resolve(strict=True)
    repository = Path(args.repository).resolve(strict=True)
    inventory_path = Path(args.inventory).resolve(strict=True)
    ensure_descendant(repository, destination_root)
    extras = [Path(item) for item in args.extra_file]
    expected, repository_prefix = expected_files(
        destination_root, repository, inventory_path, extras
    )

    root_db = open_read_only(drivefs_root / "root_preference_sqlite.db")
    try:
        if read_versions(root_db) != ROOT_DATABASE_VERSIONS:
            raise UnsupportedError("root_schema_version")
        require_table(root_db, "roots")
        roots = list(
            root_db.execute(
                """
                SELECT root_id, account_token, sync_type, destination, medium,
                       state, one_shot, is_my_drive, last_seen_absolute_path
                FROM roots
                WHERE last_seen_absolute_path = ? COLLATE NOCASE
                """,
                (str(destination_root),),
            )
        )
        if len(roots) != 1:
            raise UnsupportedError("root_registration")
        root = roots[0]
        if normalized(Path(str(root["last_seen_absolute_path"]))) != normalized(destination_root):
            raise UnsupportedError("root_path")
        if (
            int(root["sync_type"]) != 1
            or int(root["destination"]) != 1
            or int(root["medium"]) != 1
            or int(root["state"]) != 2
            or int(root["one_shot"]) != 0
            or int(root["is_my_drive"]) != 0
        ):
            raise UnsupportedError("root_mode")
        account = str(root["account_token"])
        if not re.fullmatch(r"[A-Za-z0-9._-]+", account):
            raise UnsupportedError("account_directory")
        account_root = (drivefs_root / account).resolve()
        ensure_descendant(account_root, drivefs_root.resolve())
        root_id = int(root["root_id"])
    finally:
        root_db.close()

    mirror_db = open_read_only(account_root / "mirror_sqlite.db")
    try:
        if read_versions(mirror_db) != MIRROR_DATABASE_VERSIONS:
            raise UnsupportedError("mirror_schema_version")
        for table in (
            "root_config",
            "machine_root",
            "mirror_item",
            "cloud_relations",
            "pending_uploads",
            "queued_uploads",
            "pending_deletes",
        ):
            require_table(mirror_db, table)
        metadata_path = account_root / "mirror_metadata_sqlite.db"
        metadata_uri = metadata_path.resolve().as_uri() + "?mode=ro"
        mirror_db.execute("ATTACH DATABASE ? AS meta", (metadata_uri,))
        if read_versions(mirror_db, "meta") != METADATA_DATABASE_VERSIONS:
            raise UnsupportedError("metadata_schema_version")
        for table in ("stable_ids", "items", "operations"):
            require_table(mirror_db, table, "meta")

        configurations = list(
            mirror_db.execute(
                """
                SELECT root_state, local_stable_id, is_my_drive
                FROM root_config WHERE root_id = ?
                """,
                (root_id,),
            )
        )
        if len(configurations) != 1:
            raise UnsupportedError("root_config")
        configuration = configurations[0]
        if (
            int(configuration["root_state"]) != 1
            or configuration["local_stable_id"] is None
            or int(configuration["is_my_drive"]) != 0
        ):
            raise PendingError("root_not_connected")
        root_local_id = int(configuration["local_stable_id"])
        machine_relation = int(
            mirror_db.execute(
                """
                SELECT COUNT(*)
                FROM cloud_relations AS cr
                JOIN machine_root AS mr ON mr.stable_id = cr.parent_stable_id
                JOIN mirror_item AS mi
                  ON mi.local_stable_id = cr.child_local_stable_id
                 AND mi.stable_id = cr.child_stable_id
                WHERE mi.local_stable_id = ?
                  AND mi.is_root = 1
                  AND mr.item_id IS NOT NULL
                  AND length(mr.item_id) > 0
                """,
                (root_local_id,),
            ).fetchone()[0]
        )
        if machine_relation != 1:
            raise UnsupportedError("machine_root_relation")

        queue_counts = {
            "pending_uploads": int(
                mirror_db.execute("SELECT COUNT(*) FROM pending_uploads").fetchone()[0]
            ),
            "queued_uploads": int(
                mirror_db.execute("SELECT COUNT(*) FROM queued_uploads").fetchone()[0]
            ),
            "pending_deletes": int(
                mirror_db.execute("SELECT COUNT(*) FROM pending_deletes").fetchone()[0]
            ),
            "metadata_operations": int(
                mirror_db.execute("SELECT COUNT(*) FROM meta.operations").fetchone()[0]
            ),
        }
        tree = load_tree(mirror_db, root_local_id)
    finally:
        mirror_db.close()

    mismatches = 0
    for key, expectation in expected.items():
        row = tree.get(key)
        if row is None or not verify_file(row, expectation):
            mismatches += 1

    prefix = repository_prefix.casefold().rstrip("/") + "/"
    provider_repository_files = {
        key
        for key, row in tree.items()
        if key.startswith(prefix)
        and (
            integer_equals(row["local_type"], 1)
            or integer_equals(row["cloud_type"], 1)
        )
    }
    expected_repository_files = {key for key in expected if key.startswith(prefix)}
    if provider_repository_files != expected_repository_files:
        mismatches += len(provider_repository_files ^ expected_repository_files)

    required_directories: set[str] = set()
    for expectation in expected.values():
        parts = str(expectation["provider_path"]).split("/")[:-1]
        for index in range(1, len(parts) + 1):
            required_directories.add("/".join(parts[:index]).casefold())
    for key in required_directories:
        row = tree.get(key)
        if row is None or not verify_directory(row):
            mismatches += 1

    if mismatches:
        raise PendingError("metadata_mismatch", mismatches)
    if any(queue_counts.values()):
        raise PendingError("provider_queue", sum(queue_counts.values()))

    fingerprint = hashlib.sha256()
    total_bytes = 0
    for key in sorted(expected):
        row = tree[key]
        expectation = expected[key]
        total_bytes += int(expectation["length"])
        fingerprint.update(key.encode("utf-8"))
        fingerprint.update(b"\0")
        fingerprint.update(str(expectation["length"]).encode("ascii"))
        fingerprint.update(b"\0")
        fingerprint.update(str(expectation["md5"]).encode("ascii"))
        fingerprint.update(b"\0")
        fingerprint.update(str(row["cloud_version"]).encode("ascii"))
        fingerprint.update(b"\n")
    return {
        "schema_version": 1,
        "confirmed": True,
        "state": "confirmed",
        "confirmed_utc": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        ).isoformat(),
        "provider": "google_drive_for_desktop",
        "provider_version": provider_version,
        "expected_files": len(expected),
        "expected_bytes": total_bytes,
        "pending_uploads": queue_counts["pending_uploads"],
        "queued_uploads": queue_counts["queued_uploads"],
        "pending_deletes": queue_counts["pending_deletes"],
        "metadata_operations": queue_counts["metadata_operations"],
        "evidence_fingerprint": fingerprint.hexdigest(),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination-root", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--extra-file", action="append", default=[])
    return parser.parse_args()


def emit(document: dict[str, Any], exit_code: int) -> int:
    print(json.dumps(document, sort_keys=True, separators=(",", ":")))
    return exit_code


def main() -> int:
    try:
        return emit(sample(parse_args()), 0)
    except PendingError as error:
        return emit(
            {
                "schema_version": 1,
                "confirmed": False,
                "state": "pending",
                "category": error.category,
                "mismatch_count": error.mismatch_count,
            },
            2,
        )
    except (
        UnsupportedError,
        KeyError,
        OSError,
        sqlite3.Error,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ):
        return emit(
            {
                "schema_version": 1,
                "confirmed": False,
                "state": "unsupported",
                "category": "provider_verification_failed_closed",
            },
            1,
        )


if __name__ == "__main__":
    sys.exit(main())
