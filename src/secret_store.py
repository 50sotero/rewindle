"""Current-user DPAPI storage for the Restic repository password.

The only command that emits the password is ``reveal``. It exists solely for
Restic's --password-command integration and must never be logged.
"""

from __future__ import annotations

import argparse
import base64
import csv
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
from typing import Final


SCHEMA_VERSION: Final = 1
CRYPTPROTECT_UI_FORBIDDEN: Final = 0x1


class DATA_BLOB(ctypes.Structure):
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_ubyte)),
    ]


def _windows_libraries():
    if os.name != "nt":
        raise RuntimeError("DPAPI secret storage is available only on Windows")

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(DATA_BLOB),
        wintypes.LPCWSTR,
        ctypes.POINTER(DATA_BLOB),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(DATA_BLOB),
    ]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(DATA_BLOB),
        ctypes.c_void_p,
        ctypes.POINTER(DATA_BLOB),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(DATA_BLOB),
    ]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    return crypt32, kernel32


def _input_blob(data: bytes) -> tuple[DATA_BLOB, ctypes.Array]:
    buffer = ctypes.create_string_buffer(data)
    blob = DATA_BLOB(
        len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte))
    )
    return blob, buffer


def protect(secret: bytes) -> bytes:
    crypt32, kernel32 = _windows_libraries()
    input_blob, input_buffer = _input_blob(secret)
    output_blob = DATA_BLOB()
    if not crypt32.CryptProtectData(
        ctypes.byref(input_blob),
        "Rewindle backup repository password",
        None,
        None,
        None,
        CRYPTPROTECT_UI_FORBIDDEN,
        ctypes.byref(output_blob),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        kernel32.LocalFree(output_blob.pbData)


def unprotect(ciphertext: bytes) -> bytes:
    crypt32, kernel32 = _windows_libraries()
    input_blob, input_buffer = _input_blob(ciphertext)
    output_blob = DATA_BLOB()
    if not crypt32.CryptUnprotectData(
        ctypes.byref(input_blob),
        None,
        None,
        None,
        None,
        CRYPTPROTECT_UI_FORBIDDEN,
        ctypes.byref(output_blob),
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        kernel32.LocalFree(output_blob.pbData)


def _atomic_create(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    descriptor: int | None = None
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        # Apply and verify the final private DACL while the file is still empty.
        # This prevents plaintext recovery material from ever occupying an
        # inherited group-readable temporary file.
        restrict_acl(temporary)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if path.exists():
            raise FileExistsError(f"refusing to replace existing secret material: {path}")
        os.rename(temporary, path)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary.exists():
            temporary.unlink()


def _current_user_sid() -> str:
    result = subprocess.run(
        ["whoami.exe", "/user", "/fo", "csv", "/nh"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    row = next(csv.reader([result.stdout.strip()]))
    if len(row) < 2 or not row[1].startswith("S-1-"):
        raise RuntimeError("could not determine the current Windows user SID")
    return row[1]


def restrict_acl(path: Path, *, directory: bool = False) -> None:
    user_sid = _current_user_sid()
    suffix = "(OI)(CI)F" if directory else "F"
    grants = [
        f"*{user_sid}:{suffix}",
        f"*S-1-5-18:{suffix}",
        f"*S-1-5-32-544:{suffix}",
    ]
    result = subprocess.run(
        ["icacls.exe", str(path), "/inheritance:r", "/grant:r", *grants],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode != 0:
        raise RuntimeError(f"could not restrict ACL on {path}: {result.stderr.strip()}")
    # Some user-profile folders contribute an explicit OWNER RIGHTS entry even
    # after inherited ACEs are removed. The current SID already has an exact
    # full-control grant, so keeping that generic owner grant would only make
    # later ownership changes broaden access.
    owner_rights = subprocess.run(
        ["icacls.exe", str(path), "/remove:g", "*S-1-3-4"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if owner_rights.returncode != 0:
        raise RuntimeError(
            f"could not remove generic owner rights on {path}: "
            f"{owner_rights.stderr.strip()}"
        )
    verify_restricted_acl(path, user_sid)


def _security_sddl(path: Path, *, include_owner: bool = False) -> str:
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    security_descriptor = ctypes.c_void_p()
    owner = ctypes.c_void_p()
    dacl = ctypes.c_void_p()
    get_named = advapi32.GetNamedSecurityInfoW
    get_named.argtypes = [
        wintypes.LPWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p),
    ]
    get_named.restype = wintypes.DWORD
    information = 0x4 | (0x1 if include_owner else 0)
    error = get_named(
        str(path),
        1,  # SE_FILE_OBJECT
        information,
        ctypes.byref(owner) if include_owner else None,
        None,
        ctypes.byref(dacl),
        None,
        ctypes.byref(security_descriptor),
    )
    if error:
        raise ctypes.WinError(error)
    text_pointer = wintypes.LPWSTR()
    text_length = wintypes.ULONG()
    convert = advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW
    convert.argtypes = [
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.LPWSTR),
        ctypes.POINTER(wintypes.ULONG),
    ]
    convert.restype = wintypes.BOOL
    try:
        if not convert(
            security_descriptor,
            1,
            information,
            ctypes.byref(text_pointer),
            ctypes.byref(text_length),
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            return text_pointer.value
        finally:
            kernel32.LocalFree(text_pointer)
    finally:
        kernel32.LocalFree(security_descriptor)


def _dacl_sddl(path: Path) -> str:
    return _security_sddl(path)


def verify_restricted_acl(path: Path, user_sid: str | None = None) -> None:
    current_sid = user_sid or _current_user_sid()
    sddl = _dacl_sddl(path)
    prefix = sddl.split("(", 1)[0]
    if not prefix.startswith("D:") or "P" not in prefix[2:]:
        raise RuntimeError(f"ACL inheritance is not protected on {path}: {sddl}")
    allowed_sids = {current_sid, "SY", "BA", "S-1-5-18", "S-1-5-32-544"}
    # Windows renders the built-in Administrator account (RID 500) as ``LA``.
    # Accept it only when that account is the current DPAPI owner.
    if current_sid.rsplit("-", 1)[-1] == "500":
        allowed_sids.add("LA")
    entries = re.findall(r"\(([^)]*)\)", sddl)
    if not entries:
        raise RuntimeError(f"ACL has no access entries on {path}: {sddl}")
    for entry in entries:
        fields = entry.split(";")
        if len(fields) < 6 or fields[0] != "A" or fields[2] != "FA":
            raise RuntimeError(f"ACL has a non-full-control allow entry on {path}: {entry}")
        if fields[5] not in allowed_sids:
            raise RuntimeError(f"ACL grants an unexpected principal on {path}: {entry}")


def verify_protected_readonly_acl(path: Path, user_sid: str | None = None) -> None:
    """Verify an Administrator-owned proof file readable but not writable by its user."""

    current_sid = user_sid or _current_user_sid()
    sddl = _security_sddl(path, include_owner=True)
    owner_match = re.search(r"O:(.*?)(?=[GDS]:)", sddl)
    if owner_match is None or owner_match.group(1) not in {"BA", "S-1-5-32-544"}:
        raise RuntimeError(f"ACL owner is not Administrators on {path}: {sddl}")
    dacl_index = sddl.find("D:")
    if dacl_index < 0:
        raise RuntimeError(f"ACL has no DACL on {path}: {sddl}")
    dacl = sddl[dacl_index:]
    prefix = dacl.split("(", 1)[0]
    if "P" not in prefix[2:]:
        raise RuntimeError(f"ACL inheritance is not protected on {path}: {sddl}")
    allowed_sids = {
        current_sid,
        "SY",
        "BA",
        "OW",
        "S-1-5-18",
        "S-1-5-32-544",
        "S-1-3-4",
    }
    required = {"SY", "BA", current_sid}
    seen: set[str] = set()
    write_mask = 0x00000116 | 0x00040000 | 0x00080000 | 0x00010000
    for entry in re.findall(r"\(([^)]*)\)", dacl):
        fields = entry.split(";")
        if len(fields) < 6 or fields[0] != "A" or fields[1]:
            raise RuntimeError(f"ACL contains an inherited or non-allow entry on {path}: {entry}")
        sid = fields[5]
        if sid not in allowed_sids:
            raise RuntimeError(f"ACL grants an unexpected principal on {path}: {entry}")
        rights = fields[2]
        if sid in {current_sid, "OW", "S-1-3-4"}:
            if rights in {"FA", "FW", "GA", "GW"}:
                raise RuntimeError(f"ACL grants write access to the normal user on {path}: {entry}")
            if rights.startswith("0x") and int(rights, 16) & write_mask:
                raise RuntimeError(f"ACL grants write access to the normal user on {path}: {entry}")
        if sid in {"SY", "S-1-5-18"}:
            seen.add("SY")
            if rights not in {"FA", "GA"}:
                raise RuntimeError(f"SYSTEM lacks full control on {path}: {entry}")
        elif sid in {"BA", "S-1-5-32-544"}:
            seen.add("BA")
            if rights not in {"FA", "GA"}:
                raise RuntimeError(f"Administrators lack full control on {path}: {entry}")
        elif sid == current_sid:
            seen.add(current_sid)
    if not required.issubset(seen):
        raise RuntimeError(f"ACL is missing a required principal on {path}: {sddl}")


def secure_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    restrict_acl(path, directory=True)


def create_secret(path: Path) -> str:
    if path.exists():
        raise FileExistsError(f"secret already exists: {path}")
    password = secrets.token_urlsafe(48)
    envelope = {
        "schema_version": SCHEMA_VERSION,
        "protection": "Windows DPAPI CurrentUser",
        "ciphertext_base64": base64.b64encode(
            protect(password.encode("ascii"))
        ).decode("ascii"),
    }
    _atomic_create(
        path,
        (json.dumps(envelope, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )
    return password


def _secret_envelope_bytes(password: str) -> bytes:
    try:
        encoded = password.encode("ascii")
    except UnicodeEncodeError as error:
        raise ValueError("repository password must be ASCII") from error
    if len(password) < 40 or any(character.isspace() for character in password):
        raise ValueError("repository password is invalid or unexpectedly short")
    envelope = {
        "schema_version": SCHEMA_VERSION,
        "protection": "Windows DPAPI CurrentUser",
        "ciphertext_base64": base64.b64encode(protect(encoded)).decode("ascii"),
    }
    return (json.dumps(envelope, indent=2, sort_keys=True) + "\n").encode("utf-8")


def replace_secret(path: Path, password: str) -> None:
    """Atomically replace/create one CurrentUser envelope after a round trip.

    The original bytes are restored if any post-publication verification fails.
    Plaintext is never written to disk.
    """

    path = path.resolve(strict=False)
    if path.exists() and (not path.is_file() or path.is_symlink()):
        raise RuntimeError(f"secret target is not a normal file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    original = path.read_bytes() if path.exists() else None
    data = _secret_envelope_bytes(password)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.repair.tmp")
    rollback: Path | None = None
    published = False
    descriptor: int | None = None
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        restrict_acl(temporary)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if load_secret(temporary) != password:
            raise RuntimeError("staged DPAPI secret did not round-trip")
        os.replace(temporary, path)
        published = True
        verify_restricted_acl(path)
        if load_secret(path) != password:
            raise RuntimeError("published DPAPI secret did not round-trip")
    except BaseException as error:
        rollback_errors: list[str] = []
        if published:
            try:
                if original is None:
                    path.unlink(missing_ok=True)
                else:
                    rollback = path.with_name(
                        f".{path.name}.{secrets.token_hex(8)}.rollback.tmp"
                    )
                    rollback_descriptor = os.open(
                        rollback, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
                    )
                    try:
                        restrict_acl(rollback)
                        with os.fdopen(rollback_descriptor, "wb") as handle:
                            rollback_descriptor = -1
                            handle.write(original)
                            handle.flush()
                            os.fsync(handle.fileno())
                    finally:
                        if rollback_descriptor >= 0:
                            os.close(rollback_descriptor)
                    os.replace(rollback, path)
                    rollback = None
            except BaseException as rollback_error:
                rollback_errors.append(f"secret rollback failed: {rollback_error}")
        if rollback_errors:
            raise RuntimeError(f"{error}; {'; '.join(rollback_errors)}") from error
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)
        if rollback is not None:
            rollback.unlink(missing_ok=True)


def load_secret(path: Path) -> str:
    envelope = json.loads(path.read_text(encoding="utf-8"))
    if envelope.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"unsupported secret envelope schema: {path}")
    if envelope.get("protection") != "Windows DPAPI CurrentUser":
        raise ValueError(f"unexpected secret protection scope: {path}")
    ciphertext = base64.b64decode(envelope["ciphertext_base64"], validate=True)
    password = unprotect(ciphertext).decode("ascii")
    if len(password) < 40:
        raise ValueError("decrypted repository password is unexpectedly short")
    return password


def write_recovery_key(path: Path, repository: Path, password: str) -> None:
    content = (
        "RESTIC PERSONAL BACKUP RECOVERY KEY\r\n"
        "===================================\r\n\r\n"
        f"Repository: {repository}\r\n"
        f"Password: {password}\r\n\r\n"
        "Store a printed or password-manager copy away from this computer.\r\n"
        "Anyone with this password and the repository can read the backup.\r\n"
    ).encode("utf-8")
    _atomic_create(path, content)


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    reveal = subparsers.add_parser("reveal")
    reveal.add_argument("--secret-file", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.command == "reveal":
        password = load_secret(args.secret_file)
        sys.stdout.buffer.write(password.encode("ascii") + b"\n")
        sys.stdout.buffer.flush()
        return 0
    raise AssertionError("unreachable")


if __name__ == "__main__":
    raise SystemExit(main())
