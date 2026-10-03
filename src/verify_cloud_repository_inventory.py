#!/usr/bin/env python3
"""Compare a local Restic repository with a read-only Drive API inventory.

The PowerShell orchestrator produces the rclone inventory so credentials remain
in process-scoped environment variables and never cross this helper's command
line. Successful evidence contains only aggregate counts and cryptographic
fingerprints; object IDs and repository paths remain in the private run folder.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import Any, Iterable


MD5_PATTERN = re.compile(r"[0-9a-f]{32}")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class InventoryError(RuntimeError):
    """Fail-closed inventory verification error with a non-sensitive category."""

    def __init__(self, category: str, count: int = 0) -> None:
        super().__init__(category)
        self.category = category
        self.count = count


def _is_safe_relative_path(value: str) -> bool:
    if (
        not value
        or value.startswith("/")
        or value.endswith("/")
        or "\\" in value
        or any(ord(character) < 32 for character in value)
    ):
        return False
    return all(part not in ("", ".", "..") for part in value.split("/"))


def _hash_file(path: Path) -> tuple[int, str, str]:
    before = path.stat()
    md5 = hashlib.md5(usedforsecurity=False)
    sha256 = hashlib.sha256()
    length = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            length += len(block)
            md5.update(block)
            sha256.update(block)
    after = path.stat()
    stable_fields = ("st_size", "st_mtime_ns", "st_ino", "st_dev")
    if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
        raise InventoryError("local_repository_changed")
    if length != before.st_size:
        raise InventoryError("local_repository_changed")
    return length, md5.hexdigest(), sha256.hexdigest()


def local_inventory(repository: Path) -> dict[str, dict[str, Any]]:
    repository = repository.resolve(strict=True)
    if not repository.is_dir() or not (repository / "config").is_file():
        raise InventoryError("local_repository_invalid")

    entries: dict[str, dict[str, Any]] = {}
    casefolded: set[str] = set()
    for root, directory_names, file_names in os.walk(repository, followlinks=False):
        root_path = Path(root)
        for directory_name in directory_names:
            if (root_path / directory_name).is_symlink():
                raise InventoryError("local_reparse_or_symlink")
        for file_name in file_names:
            path = root_path / file_name
            if path.is_symlink():
                raise InventoryError("local_reparse_or_symlink")
            relative = path.relative_to(repository).as_posix()
            if not _is_safe_relative_path(relative):
                raise InventoryError("local_path_invalid")
            folded = relative.casefold()
            if folded in casefolded:
                raise InventoryError("local_path_collision")
            casefolded.add(folded)
            length, md5, sha256 = _hash_file(path)
            entries[relative] = {
                "size": length,
                "md5": md5,
                "sha256": sha256,
            }
    if not entries:
        raise InventoryError("local_repository_empty")
    return entries


def _lower_hash(value: Any, pattern: re.Pattern[str], category: str) -> str:
    normalized = str(value or "").lower()
    if not pattern.fullmatch(normalized):
        raise InventoryError(category)
    return normalized


def cloud_inventory(document: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(document, list):
        raise InventoryError("cloud_inventory_format")

    entries: dict[str, dict[str, Any]] = {}
    casefolded: set[str] = set()
    cloud_ids: set[str] = set()
    for item in document:
        if not isinstance(item, dict) or item.get("IsDir") is not False:
            raise InventoryError("cloud_inventory_format")
        relative = item.get("Path")
        if not isinstance(relative, str) or not _is_safe_relative_path(relative):
            raise InventoryError("cloud_path_invalid")
        if item.get("Name") != relative.rsplit("/", 1)[-1]:
            raise InventoryError("cloud_path_invalid")
        folded = relative.casefold()
        if folded in casefolded:
            raise InventoryError("cloud_path_collision")
        casefolded.add(folded)

        size = item.get("Size")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise InventoryError("cloud_size_invalid")
        hashes = item.get("Hashes")
        if not isinstance(hashes, dict):
            raise InventoryError("cloud_hash_missing")
        normalized_hashes: dict[str, Any] = {}
        for name, value in hashes.items():
            normalized_name = str(name).lower().replace("-", "")
            if normalized_name in normalized_hashes:
                raise InventoryError("cloud_hash_ambiguous")
            normalized_hashes[normalized_name] = value
        md5 = _lower_hash(
            normalized_hashes.get("md5"),
            MD5_PATTERN,
            "cloud_hash_missing",
        )
        sha256 = _lower_hash(
            normalized_hashes.get("sha256"),
            SHA256_PATTERN,
            "cloud_hash_missing",
        )
        cloud_id = item.get("ID")
        if (
            not isinstance(cloud_id, str)
            or not cloud_id
            or len(cloud_id) > 512
            or any(ord(character) < 32 for character in cloud_id)
        ):
            raise InventoryError("cloud_identity_missing")
        if cloud_id in cloud_ids:
            raise InventoryError("cloud_identity_duplicate")
        cloud_ids.add(cloud_id)
        entries[relative] = {
            "size": size,
            "md5": md5,
            "sha256": sha256,
        }
    if not entries:
        raise InventoryError("cloud_repository_empty")
    return entries


def _fingerprint(entries: dict[str, dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for relative in sorted(entries):
        entry = entries[relative]
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(entry["size"]).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(entry["md5"]).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(entry["sha256"]).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def compare_inventories(
    expected: dict[str, dict[str, Any]],
    observed: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    expected_paths = set(expected)
    observed_paths = set(observed)
    missing = expected_paths - observed_paths
    extra = observed_paths - expected_paths
    mismatched = {
        relative
        for relative in expected_paths & observed_paths
        if expected[relative] != observed[relative]
    }
    if missing:
        raise InventoryError("cloud_files_missing", len(missing))
    if extra:
        raise InventoryError("cloud_files_extra", len(extra))
    if mismatched:
        raise InventoryError("cloud_content_mismatch", len(mismatched))

    expected_fingerprint = _fingerprint(expected)
    observed_fingerprint = _fingerprint(observed)
    if expected_fingerprint != observed_fingerprint:
        raise InventoryError("inventory_fingerprint_mismatch")
    return {
        "schema_version": 1,
        "state": "verified",
        "exact_file_inventory_verified": True,
        "path_case_size_md5_sha256_verified": True,
        "files": len(expected),
        "bytes": sum(int(entry["size"]) for entry in expected.values()),
        "inventory_fingerprint_sha256": expected_fingerprint,
        "cloud_objects_with_ids": len(observed),
        "missing_files": 0,
        "extra_files": 0,
        "mismatched_files": 0,
    }


def verify(local_repository: Path, cloud_inventory_path: Path) -> dict[str, Any]:
    try:
        raw_cloud_inventory = cloud_inventory_path.read_bytes()
        cloud_document = json.loads(raw_cloud_inventory.decode("utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InventoryError("cloud_inventory_format") from error
    proof = compare_inventories(
        local_inventory(local_repository),
        cloud_inventory(cloud_document),
    )
    proof["cloud_inventory_document_sha256"] = hashlib.sha256(
        raw_cloud_inventory
    ).hexdigest()
    return proof


def _write_new_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(document, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")


def parse_args(arguments: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-repository", required=True, type=Path)
    parser.add_argument("--cloud-inventory", required=True, type=Path)
    parser.add_argument("--proof", required=True, type=Path)
    return parser.parse_args(arguments)


def main(arguments: Iterable[str] | None = None) -> int:
    try:
        args = parse_args(arguments)
        proof = verify(args.local_repository, args.cloud_inventory)
        _write_new_json(args.proof, proof)
        print(
            json.dumps(
                {
                    "state": "verified",
                    "proof": str(args.proof.resolve()),
                    "files": proof["files"],
                    "bytes": proof["bytes"],
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 0
    except InventoryError as error:
        print(
            json.dumps(
                {
                    "state": "failed",
                    "category": error.category,
                    "count": error.count,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 2
    except (KeyError, OSError, TypeError, ValueError):
        print(
            json.dumps(
                {
                    "state": "failed",
                    "category": "inventory_verification_failed_closed",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
