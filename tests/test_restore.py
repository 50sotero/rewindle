from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import ctypes
from ctypes import wintypes
import fnmatch
import hashlib
import io
import json
import ntpath
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = PROJECT_ROOT / "src"
sys.path.insert(0, str(SOURCE_ROOT))

import restore


RESTIC = PROJECT_ROOT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"

OLD_ID = "a" * 64
NEW_ID = "b" * 64
WRONG_HOST_ID = "c" * 64
WRONG_TAG_ID = "d" * 64
WRONG_PATH_ID = "e" * 64
LEGACY_ID = "f" * 64
REPOSITORY_ID = "0123456789abcdef0123456789abcdef"
PLAN_ID = "12345678-1234-4abc-8def-1234567890ab"
OTHER_PLAN_ID = "87654321-4321-4abc-8def-ba0987654321"


FAKE_RESTIC = r'''from __future__ import annotations
import fnmatch
import json
import os
from pathlib import Path
import sys

script = Path(__file__)
control = json.loads(script.with_suffix(".control.json").read_text(encoding="utf-8"))
args = sys.argv[1:]
with Path(control["log"]).open("a", encoding="utf-8") as handle:
    handle.write(
        json.dumps({"args": args, "environment": sorted(os.environ)}, separators=(",", ":"))
        + "\n"
    )

expected_password = control.get("expected_password")
if expected_password is not None and os.environ.get("RESTIC_PASSWORD") != expected_password:
    raise SystemExit(91)

if "find" in args:
    # Like Restic 0.19.1's `find --json`: one array with an object for each backup that has matches.
    import time
    if control.get("pid_file"):
        Path(control["pid_file"]).write_text(str(os.getpid()), encoding="utf-8")
    ids = [args[index + 1] for index, value in enumerate(args[:-1]) if value == "--snapshot"]
    for snapshot_id in ids:
        time.sleep(float(control.get("find_sleep", {}).get(snapshot_id, 0)))
    if "find_raw" in control:
        sys.stdout.write(control["find_raw"])
        raise SystemExit(int(control.get("find_exit", 0)))
    flood = int(control.get("find_flood", 0))
    found = []
    for snapshot_id in ids:
        nodes = control.get("find_nodes", {}).get(snapshot_id, [])
        if flood:
            nodes = [
                {"name": f"budget-{index}.txt", "type": "file", "path": f"/C/Budget/budget-{index}.txt", "size": 1}
                for index in range(flood)
            ]
        if nodes:
            found.append({"matches": nodes, "hits": len(nodes), "snapshot": snapshot_id})
    sys.stdout.write(json.dumps(found) + "\n")
    raise SystemExit(int(control.get("find_exit", 0)))
if "cat" in args:
    print(json.dumps({"id": control["repository_id"], "version": 2}))
    raise SystemExit(0)
if "snapshots" in args:
    if control.get("snapshots_sleep"):
        import time
        time.sleep(float(control["snapshots_sleep"]))
    print(json.dumps(control.get("snapshots", []), separators=(",", ":")))
    raise SystemExit(int(control.get("snapshot_exit", 0)))
if "ls" in args:
    for entry in control.get("tree", []):
        print(json.dumps(entry, separators=(",", ":")))
    raise SystemExit(int(control.get("tree_exit", 0)))
if "restore" in args:
    target = Path(args[args.index("--target") + 1])
    mode = control.get("restore_mode", "success")
    if control.get("record_security"):
        # The owner and permissions of the folder Restic was given, as Windows stores them.
        import ctypes
        from ctypes import wintypes
        advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
        advapi32.GetFileSecurityW.argtypes = [
            wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)
        ]
        advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p
        ]
        needed = wintypes.DWORD()
        advapi32.GetFileSecurityW(str(target), 1 | 4, None, 0, ctypes.byref(needed))
        descriptor = ctypes.create_string_buffer(max(needed.value, 1))
        if not advapi32.GetFileSecurityW(str(target), 1 | 4, descriptor, needed, ctypes.byref(needed)):
            raise ctypes.WinError(ctypes.get_last_error())
        text = ctypes.c_void_p()
        if not advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor, 1, 1 | 4, ctypes.byref(text), None
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        Path(control["log"]).with_suffix(".target-security.txt").write_text(
            ctypes.wstring_at(text.value), encoding="utf-8"
        )
        if mode == "record_only":
            raise SystemExit(0)
    if mode == "swap":
        # Act as the requesting user while Restic loads its index: move a folder on the way to the target aside and
        # put a junction to a decoy in its place, so that Restic's writes would land in the decoy.
        import _winapi
        outcomes = {}
        for victim in control["swap_victims"]:
            victim = str(target) if victim == "--target" else victim
            try:
                os.rename(victim, victim + ".moved")
            except OSError as error:
                outcomes[victim] = getattr(error, "winerror", None) or error.errno
                continue
            _winapi.CreateJunction(control["decoy"], victim)
            outcomes[victim] = "renamed"
            break
        Path(control["swap_log"]).write_text(json.dumps(outcomes), encoding="utf-8")
    target.mkdir(parents=True, exist_ok=True)
    Path(control["log"]).with_suffix(".target.txt").write_text(str(target), encoding="utf-8")
    patterns = [args[index + 1] for index, value in enumerate(args[:-1]) if value == "--include"]
    if mode == "nothing":
        # Restic ends a restore that restored nothing with exit code 0.
        raise SystemExit(0)
    if mode == "success" and patterns:
        # Like Restic: each pattern is matched part by part with glob rules, where "[" opens a
        # character class, and a matched folder comes back with everything inside it.
        selector = args[args.index("restore") + 1]
        subfolder = selector.split(":", 1)[1].rstrip("/") if ":" in selector else ""
        wanted = [[part for part in pattern.split("/") if part] for pattern in patterns]
        for node in control.get("tree", []):
            path = str(node.get("path") or "")
            if node.get("struct_type") != "node" or not path.startswith(subfolder + "/"):
                continue
            parts = [part for part in path[len(subfolder):].split("/") if part]
            if not any(
                len(parts) >= len(pattern)
                and all(fnmatch.fnmatchcase(name, rule) for name, rule in zip(parts, pattern))
                for pattern in wanted
            ):
                continue
            destination = os.sep.join([os.path.abspath(str(target)), *parts])
            if os.name == "nt":
                destination = "\\\\?\\" + destination
            if node.get("type") == "dir":
                os.makedirs(destination, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(destination), exist_ok=True)
                with open(destination, "w", encoding="utf-8") as handle:
                    handle.write("verified fake data")
        raise SystemExit(0)
    if mode == "tree":
        (target / "nested").mkdir()
        (target / "nested" / "inner.txt").write_text("nested fake data", encoding="utf-8")
    if mode == "collide":
        # The same name appears in the chosen folder while the restore runs.
        (target.parent / "restored.txt").write_text("made by the user meanwhile", encoding="utf-8")
    if mode in ("success", "swap", "tree", "collide"):
        (target / "restored.txt").write_text("verified fake data", encoding="utf-8")
        raise SystemExit(0)
    (target / "partial.txt").write_text("retained partial fake data", encoding="utf-8")
    raise SystemExit(int(control.get("restore_exit", 23)))

raise SystemExit(97)
'''


def snapshot(
    snapshot_id: str,
    when: str,
    source: str,
    *,
    hostname: str = "TESTHOST",
    tags: list[str] | None = None,
) -> dict:
    return {
        "id": snapshot_id,
        "short_id": snapshot_id[:8],
        "time": when,
        "hostname": hostname,
        "tags": tags if tags is not None else ["scheduled"],
        "paths": [source],
        "summary": {"total_files_processed": 3, "total_bytes_processed": 42},
    }


SYSTEM_FOLDER_REFUSAL = "restore target must not be inside a Windows or program folder"


def sid_text(trustee: str) -> str:
    """The SID a trustee names, in its canonical S-1-... form.

    In SDDL Windows writes some accounts by a two-letter alias instead of their SID: SY and BA, but also LA for the
    built-in Administrator account (RID 500, the account a hosted CI runner runs as). ConvertStringSidToSidW reads both
    spellings and ConvertSidToStringSidW writes the SID back, so the tests compare the principals an entry names, not
    how Windows chose to spell them. Anything that names no principal raises.
    """

    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi32.ConvertStringSidToSidW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_void_p)]
    advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    sid = ctypes.c_void_p()
    if not advapi32.ConvertStringSidToSidW(trustee, ctypes.byref(sid)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        text = ctypes.c_void_p()
        if not advapi32.ConvertSidToStringSidW(sid, ctypes.byref(text)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            return ctypes.wstring_at(text.value)
        finally:
            kernel32.LocalFree(text)
    finally:
        kernel32.LocalFree(sid)


def by_principal(entry: tuple[str, ...]) -> tuple[str, ...]:
    """An SDDL access entry (type, flags, rights, object type, inherited object type, trustee), its trustee as a SID."""

    return entry[:5] + (sid_text(entry[5]),) + entry[6:]


def local_account_domain_sid() -> str:
    """The SID of this computer's own account domain, which its local accounts' SIDs extend, as the local security
    authority reports it."""

    class ObjectAttributes(ctypes.Structure):
        _fields_ = [
            ("Length", wintypes.ULONG),
            ("RootDirectory", wintypes.HANDLE),
            ("ObjectName", ctypes.c_void_p),
            ("Attributes", wintypes.ULONG),
            ("SecurityDescriptor", ctypes.c_void_p),
            ("SecurityQualityOfService", ctypes.c_void_p),
        ]

    class UnicodeString(ctypes.Structure):
        _fields_ = [("Length", wintypes.USHORT), ("MaximumLength", wintypes.USHORT), ("Buffer", ctypes.c_void_p)]

    class AccountDomainInfo(ctypes.Structure):
        _fields_ = [("DomainName", UnicodeString), ("DomainSid", ctypes.c_void_p)]

    policy_view_local_information = 0x1
    policy_account_domain_information = 5
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi32.LsaOpenPolicy.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ObjectAttributes), wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)
    ]
    advapi32.LsaOpenPolicy.restype = wintypes.ULONG
    advapi32.LsaQueryInformationPolicy.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    advapi32.LsaQueryInformationPolicy.restype = wintypes.ULONG
    advapi32.LsaFreeMemory.argtypes = [ctypes.c_void_p]
    advapi32.LsaFreeMemory.restype = wintypes.ULONG
    advapi32.LsaClose.argtypes = [wintypes.HANDLE]
    advapi32.LsaClose.restype = wintypes.ULONG
    advapi32.LsaNtStatusToWinError.argtypes = [wintypes.ULONG]
    advapi32.LsaNtStatusToWinError.restype = wintypes.ULONG
    advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    attributes = ObjectAttributes()
    attributes.Length = ctypes.sizeof(attributes)
    policy = wintypes.HANDLE()
    status = advapi32.LsaOpenPolicy(None, ctypes.byref(attributes), policy_view_local_information, ctypes.byref(policy))
    if status:
        raise ctypes.WinError(advapi32.LsaNtStatusToWinError(status))
    try:
        information = ctypes.c_void_p()
        status = advapi32.LsaQueryInformationPolicy(
            policy, policy_account_domain_information, ctypes.byref(information)
        )
        if status:
            raise ctypes.WinError(advapi32.LsaNtStatusToWinError(status))
        try:
            domain = AccountDomainInfo.from_address(information.value).DomainSid
            if not domain:
                raise RuntimeError("the local security authority named no account domain")
            text = ctypes.c_void_p()
            if not advapi32.ConvertSidToStringSidW(domain, ctypes.byref(text)):
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                return ctypes.wstring_at(text.value)
            finally:
                kernel32.LocalFree(text)
        finally:
            advapi32.LsaFreeMemory(information)
    finally:
        advapi32.LsaClose(policy)


def dacl_entries(path: Path) -> list[tuple[str, ...]]:
    """The access entries of a file or folder as Windows stores them, without the inherited marks and with each trustee
    as a SID."""

    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi32.GetFileSecurityW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)
    ]
    advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p
    ]
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    needed = wintypes.DWORD()
    advapi32.GetFileSecurityW(str(path), 4, None, 0, ctypes.byref(needed))
    descriptor = ctypes.create_string_buffer(needed.value)
    if not advapi32.GetFileSecurityW(str(path), 4, descriptor, needed, ctypes.byref(needed)):
        raise ctypes.WinError(ctypes.get_last_error())
    text = ctypes.c_void_p()
    if not advapi32.ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, 1, 4, ctypes.byref(text), None):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        sddl = ctypes.wstring_at(text.value)
    finally:
        kernel32.LocalFree(text)
    entries = []
    for ace in re.findall(r"\(([^)]*)\)", sddl):
        parts = ace.split(";")
        parts[1] = parts[1].replace("ID", "")
        entries.append(by_principal(tuple(parts)))
    return entries


def short_path(path: Path) -> str | None:
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    buffer = ctypes.create_unicode_buffer(32768)
    length = kernel32.GetShortPathNameW(str(path), buffer, len(buffer))
    if not 0 < length < len(buffer) or buffer.value.casefold() == str(path).casefold():
        return None
    return buffer.value


def tree_fingerprint(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not path.exists():
        return result
    for item in sorted((entry for entry in path.rglob("*") if entry.is_file())):
        result[str(item.relative_to(path))] = hashlib.sha256(item.read_bytes()).hexdigest()
    return result


class TrusteeSpellingTests(unittest.TestCase):
    def test_an_alias_and_its_sid_name_the_same_principal(self) -> None:
        # The built-in Administrator account is this computer's account domain with RID 500, built here at run time from
        # what the local security authority reports; Windows writes it in SDDL as LA.
        domain = local_account_domain_sid()
        self.assertRegex(domain, r"^S-1-5-21(-\d+){3}$")
        administrator = domain + "-500"
        for alias, sid in (("LA", administrator), ("BA", "S-1-5-32-544"), ("SY", "S-1-5-18")):
            with self.subTest(alias=alias):
                self.assertEqual(sid, sid_text(alias))
                self.assertEqual(sid_text(alias), sid_text(sid))
                self.assertEqual(("A", "OICI", "FA", "", "", sid), by_principal(("A", "OICI", "FA", "", "", alias)))
        # Different principals stay apart, and a SID is kept as it is.
        self.assertEqual(3, len({sid_text("LA"), sid_text("BA"), sid_text("SY")}))
        self.assertEqual(restore.current_user_sid(), sid_text(restore.current_user_sid()))
        # Something that names no principal is never taken for one.
        for garbled in ("", "XX", "S-1-", "BA)(A;OICI;FA;;;WD"):
            with self.subTest(garbled=garbled), self.assertRaises(OSError):
                sid_text(garbled)


class RestoreBackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="restic-restore-test-")
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        (self.repository / "config").write_text("immutable repository sentinel", encoding="utf-8")
        (self.repository / "data-pack").write_bytes(b"do not mutate repository")
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "live.txt").write_text("live source sentinel", encoding="utf-8")
        self.state = self.root / "state"
        self.state.mkdir()
        self.recovery_tools = self.root / "recovery-tools"
        self.recovery_tools.mkdir()
        self.task_sentinel = self.root / "scheduled-task.xml"
        self.task_sentinel.write_text("unchanged fake scheduled task", encoding="utf-8")
        self.fake_restic = self.root / "fake_restic.py"
        self.fake_restic.write_text(FAKE_RESTIC, encoding="utf-8")
        self.fake_log = self.root / "fake-restic.jsonl"
        self.control_path = self.fake_restic.with_suffix(".control.json")
        self.recovery_key = self.root / "offline-recovery-key.txt"
        self.password = "correct-horse-battery-staple-" + "x" * 48
        self.recovery_key.write_text(f"Password: {self.password}\n", encoding="utf-8")
        self.secret_file = self.state / "repository-password.dpapi.json"
        self.config_path = self.root / "backup-config.json"
        self.config = {
            "schema_version": 1,
            "repository": str(self.repository),
            "repository_volume_serial": "00000000",
            "restic_executable": str(self.fake_restic),
            "recovery_tools_directory": str(self.recovery_tools),
            "python_executable": sys.executable,
            "state_directory": str(self.state),
            "secret_file": str(self.secret_file),
            "recovery_key_file": str(self.recovery_key),
            "hostname": "TESTHOST",
            "scheduled_tag": "scheduled",
            "sources": [str(self.source)],
        }
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        self.write_control()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_control(self, **changes: object) -> None:
        snapshots = [
            snapshot(OLD_ID, "2026-07-20T01:00:00Z", str(self.source)),
            snapshot(NEW_ID, "2026-07-21T01:00:00Z", str(self.source)),
            snapshot(
                WRONG_HOST_ID,
                "2026-07-22T01:00:00Z",
                str(self.source),
                hostname="OTHER-HOST",
            ),
            snapshot(
                WRONG_TAG_ID,
                "2026-07-23T01:00:00Z",
                str(self.source),
                tags=["manual"],
            ),
            snapshot(
                WRONG_PATH_ID,
                "2026-07-24T01:00:00Z",
                str(self.root / "other-source"),
            ),
        ]
        control: dict[str, object] = {
            "log": str(self.fake_log),
            "repository_id": REPOSITORY_ID,
            "snapshots": snapshots,
            "tree": [
                {
                    "struct_type": "snapshot",
                    "id": NEW_ID,
                    "time": "2026-07-21T01:00:00Z",
                },
                {
                    "struct_type": "node",
                    "name": "Users",
                    "type": "dir",
                    "path": "/C/Users",
                },
                {
                    "struct_type": "node",
                    "name": "file.txt",
                    "type": "file",
                    "path": "/C/Users/file.txt",
                    "size": 42,
                },
            ],
            "expected_password": self.password,
            "restore_mode": "success",
        }
        control.update(changes)
        self.control_path.write_text(json.dumps(control), encoding="utf-8")

    def base_arguments(self, *, recovery_key: bool = True) -> list[str]:
        arguments = [
            "--config",
            str(self.config_path),
            "--repository",
            str(self.repository),
            "--restic",
            str(self.fake_restic),
        ]
        if recovery_key:
            arguments.extend(["--recovery-key-file", str(self.recovery_key)])
        return arguments

    def enable_plan(self, generation: int = 2) -> None:
        self.config["plan_id"] = PLAN_ID
        self.config["config_generation"] = generation
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")

    def invoke(self, arguments: list[str]) -> tuple[int, str, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(restore, "ensure_local_volume"), redirect_stdout(
            stdout
        ), redirect_stderr(stderr):
            result = restore.main([*self.base_arguments(), *arguments])
        return result, stdout.getvalue(), stderr.getvalue()

    def read_log(self) -> list[list[str]]:
        if not self.fake_log.exists():
            return []
        return [
            json.loads(line)["args"]
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]

    def immutable_state(self) -> tuple[dict[str, str], dict[str, str], str]:
        return (
            tree_fingerprint(self.repository),
            tree_fingerprint(self.source),
            self.task_sentinel.read_text(encoding="utf-8"),
        )

    def test_machine_snapshot_listing_is_filtered_and_uses_restic_json(self) -> None:
        before = self.immutable_state()
        result, stdout, stderr = self.invoke(["--list-snapshots-json"])
        self.assertEqual(result, 0)
        self.assertEqual(stderr, "")
        payload = json.loads(stdout)
        self.assertEqual(payload["schema"], restore.LIST_SCHEMA)
        self.assertEqual(payload["repository_id"], REPOSITORY_ID)
        self.assertTrue(
            all(
                item["binding_state"] == restore.SNAPSHOT_BINDING_CONFIGURATION
                for item in payload["snapshots"]
            )
        )
        self.assertEqual([item["id"] for item in payload["snapshots"]], [NEW_ID, OLD_ID])
        snapshot_commands = [args for args in self.read_log() if "snapshots" in args]
        self.assertEqual(len(snapshot_commands), 1)
        command = snapshot_commands[0]
        self.assertIn("--json", command)
        self.assertEqual(command[command.index("--host") + 1], "TESTHOST")
        self.assertEqual(command[command.index("--tag") + 1], "scheduled")
        self.assertEqual(command[command.index("--path") + 1], str(self.source))
        self.assertEqual(self.immutable_state(), before)

    def test_dpapi_password_helper_cannot_create_runtime_bytecode_cache(self) -> None:
        self.secret_file.write_text("fake encrypted DPAPI blob", encoding="utf-8")
        command = restore.password_command(self.config)
        self.assertIsNotNone(command)
        self.assertIn("-I -S -B", command)

    def test_drivefs_restore_config_keeps_recovery_and_state_outside_my_drive(
        self,
    ) -> None:
        drivefs_repository = r"G:\My Drive\ResticBackups\Personal"
        drivefs = {
            **self.config,
            "repository": drivefs_repository,
            "repository_storage_mode": "google_drivefs_stream",
            "drivefs_my_drive_root": r"G:\My Drive",
            "drivefs_cache_directory": str(self.root / "Google" / "DriveFS"),
        }
        self.config_path.write_text(json.dumps(drivefs), encoding="utf-8")
        loaded = restore.load_restore_config(self.config_path)
        self.assertEqual(
            "google_drivefs_stream",
            restore.validate_repository_storage_config(loaded),
        )
        self.assertEqual(str(self.recovery_tools), loaded["recovery_tools_directory"])

        drivefs["recovery_tools_directory"] = (
            r"G:\My Drive\ResticBackups\RecoveryTools"
        )
        self.config_path.write_text(json.dumps(drivefs), encoding="utf-8")
        with self.assertRaisesRegex(
            ValueError,
            "recovery_tools_directory must remain outside",
        ):
            restore.load_restore_config(self.config_path)

    def test_g_restore_repository_requires_explicit_drivefs_mode(self) -> None:
        self.config["repository"] = r"G:\My Drive\ResticBackups\Personal"
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        with self.assertRaisesRegex(
            ValueError,
            "requires explicit google_drivefs_stream",
        ):
            restore.load_restore_config(self.config_path)

    def test_restore_config_rejects_nested_state_and_recovery_roles(self) -> None:
        self.config["state_directory"] = r"C:\ProgramData\ResticBackuper"
        self.config["recovery_tools_directory"] = (
            r"C:\ProgramData\ResticBackuper\RecoveryTools"
        )
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "protected roles overlap"):
            restore.load_restore_config(self.config_path)

    def test_machine_tree_listing_resolves_latest_to_exact_bound_snapshot(self) -> None:
        result, stdout, _ = self.invoke(
            ["--list-tree-json", "--snapshot", "latest", "--tree-path", "C:\\Users"]
        )
        self.assertEqual(result, 0)
        payload = json.loads(stdout)
        self.assertEqual(payload["schema"], restore.TREE_SCHEMA)
        self.assertEqual(payload["snapshot_id"], NEW_ID)
        self.assertEqual(payload["repository_id"], REPOSITORY_ID)
        self.assertEqual(payload["tree_path"], "C:\\Users")
        self.assertEqual(payload["entries"][1]["name"], "Users")
        tree_commands = [args for args in self.read_log() if "ls" in args]
        self.assertEqual(len(tree_commands), 1)
        self.assertIn(NEW_ID, tree_commands[0])
        self.assertNotIn("latest", tree_commands[0])
        self.assertIn("--json", tree_commands[0])

    def test_only_a_caller_holding_the_run_lock_lists_without_the_restic_lock(self) -> None:
        # Run on its own (as RECOVERY.md documents) nothing holds the run lock, so Restic's lock stays.
        self.assertEqual(self.invoke(["--list-snapshots-json"])[0], 0)
        self.assertEqual(self.invoke(["--list", "--json"])[0], 0)
        standalone = self.read_log()
        self.assertTrue(standalone)
        self.assertTrue(all("--no-lock" not in args for args in standalone))
        self.fake_log.unlink()
        self.assertEqual(self.invoke(["--no-restic-lock", "--list-snapshots-json"])[0], 0)
        self.assertEqual(
            self.invoke(
                ["--no-restic-lock", "--list-tree-json", "--snapshot", "latest", "--tree-path", "C:\\Users"]
            )[0],
            0,
        )
        listings = self.read_log()
        self.assertTrue(listings)
        self.assertTrue(all("--no-lock" in args for args in listings))
        with self.assertRaisesRegex(ValueError, "only valid for listings"):
            self.invoke(["--no-restic-lock", "--snapshot", "latest", "--target", str(self.root / "locked-restore")])

    def test_cache_dir_reaches_every_restic_call_but_never_a_drill(self) -> None:
        cache = self.state / "cache"
        cache.mkdir()
        self.assertEqual(self.invoke(["--cache-dir", str(cache), "--list-snapshots-json"])[0], 0)
        self.assertEqual(
            self.invoke(["--cache-dir", str(cache), "--snapshot", "latest", "--target", str(self.root / "cached")])[0],
            0,
        )
        calls = self.read_log()
        self.assertTrue(calls)
        for args in calls:
            self.assertEqual(args[args.index("--cache-dir") + 1], str(cache))
            self.assertNotIn("--no-cache", args)
        with self.assertRaisesRegex(ValueError, "existing local directory"):
            self.invoke(["--cache-dir", str(self.state / "missing"), "--list-snapshots-json"])
        with self.assertRaisesRegex(ValueError, "without a cache"):
            self.invoke(
                [
                    "--cache-dir",
                    str(cache),
                    "--recovery-drill",
                    "--target",
                    str(self.root / "drill-target"),
                    "--report",
                    str(self.state / "drill-report.json"),
                    "--drill-canary-sha256",
                    "0" * 64,
                    "--drill-canary-bytes",
                    "1",
                ]
            )

    def test_plan_listing_browses_old_generations_but_latest_is_current(self) -> None:
        self.enable_plan(generation=2)
        old_source = str(self.root / "retired-source")
        valid_old = snapshot(
            OLD_ID,
            "2026-07-30T01:00:00Z",
            old_source,
            tags=[
                "scheduled",
                restore.plan_tag(PLAN_ID),
                restore.generation_tag(1),
            ],
        )
        valid_current = snapshot(
            NEW_ID,
            "2026-07-21T01:00:00Z",
            str(self.source),
            tags=[
                "scheduled",
                restore.plan_tag(PLAN_ID),
                restore.generation_tag(2),
            ],
        )
        mismatched_plan = snapshot(
            WRONG_HOST_ID,
            "2026-08-01T01:00:00Z",
            str(self.source),
            tags=[
                "scheduled",
                restore.plan_tag(OTHER_PLAN_ID),
                restore.generation_tag(2),
            ],
        )
        malformed_generation = snapshot(
            WRONG_TAG_ID,
            "2026-08-02T01:00:00Z",
            str(self.source),
            tags=[
                "scheduled",
                restore.plan_tag(PLAN_ID),
                restore.GENERATION_TAG_PREFIX + "02",
            ],
        )
        multiple_generations = snapshot(
            WRONG_PATH_ID,
            "2026-08-03T01:00:00Z",
            str(self.source),
            tags=[
                "scheduled",
                restore.plan_tag(PLAN_ID),
                restore.generation_tag(2),
                restore.generation_tag(3),
            ],
        )
        self.write_control(
            snapshots=[
                valid_old,
                valid_current,
                mismatched_plan,
                malformed_generation,
                multiple_generations,
            ]
        )

        result, stdout, _ = self.invoke(["--list-snapshots-json"])
        self.assertEqual(result, 0)
        listing = json.loads(stdout)
        self.assertEqual(listing["binding"]["plan_id"], PLAN_ID)
        self.assertEqual(listing["binding"]["current_config_generation"], 2)
        self.assertEqual(
            {item["id"] for item in listing["snapshots"]}, {OLD_ID, NEW_ID}
        )
        generations = {
            item["id"]: item["config_generation"] for item in listing["snapshots"]
        }
        self.assertEqual(generations, {OLD_ID: 1, NEW_ID: 2})
        browse_command = [args for args in self.read_log() if "snapshots" in args][0]
        self.assertNotIn(restore.plan_tag(PLAN_ID), browse_command)
        self.assertNotIn(restore.generation_tag(2), browse_command)
        self.assertNotIn("--host", browse_command)
        self.assertNotIn("--path", browse_command)

        result, stdout, _ = self.invoke(
            ["--list-tree-json", "--snapshot", "latest"]
        )
        self.assertEqual(result, 0)
        latest_tree = json.loads(stdout)
        self.assertEqual(latest_tree["snapshot_id"], NEW_ID)
        self.assertEqual(latest_tree["snapshot_generation"], 2)
        self.assertEqual(latest_tree["snapshot_binding"], restore.SNAPSHOT_BINDING_PLAN)
        current_commands = [args for args in self.read_log() if "snapshots" in args]
        latest_command = current_commands[-1]
        self.assertIn(restore.plan_tag(PLAN_ID), latest_command)
        self.assertIn(restore.generation_tag(2), latest_command)
        self.assertIn("--host", latest_command)
        self.assertIn("--path", latest_command)

        result, stdout, _ = self.invoke(
            ["--list-tree-json", "--snapshot", OLD_ID]
        )
        self.assertEqual(result, 0)
        old_tree = json.loads(stdout)
        self.assertEqual(old_tree["snapshot_id"], OLD_ID)
        self.assertEqual(old_tree["snapshot_generation"], 1)
        with self.assertRaisesRegex(RuntimeError, "overlap"):
            self.invoke(
                [
                    "--snapshot",
                    OLD_ID,
                    "--target",
                    old_source,
                ]
            )
        self.assertFalse(Path(old_source).exists())

    def test_plan_listing_and_exact_opt_in_restore_include_only_matching_legacy(self) -> None:
        self.enable_plan(generation=2)
        current = snapshot(
            NEW_ID,
            "2026-07-21T01:00:00Z",
            str(self.source),
            tags=[
                "scheduled",
                restore.plan_tag(PLAN_ID),
                restore.generation_tag(2),
            ],
        )
        legacy = snapshot(LEGACY_ID, "2026-07-20T01:00:00Z", str(self.source))
        wrong_host = snapshot(
            WRONG_HOST_ID,
            "2026-07-19T01:00:00Z",
            str(self.source),
            hostname="OTHER-HOST",
        )
        wrong_tag = snapshot(
            WRONG_TAG_ID,
            "2026-07-18T01:00:00Z",
            str(self.source),
            tags=["manual"],
        )
        wrong_path = snapshot(
            WRONG_PATH_ID,
            "2026-07-17T01:00:00Z",
            str(self.root / "other-source"),
        )
        conflicting_binding = snapshot(
            OLD_ID,
            "2026-07-16T01:00:00Z",
            str(self.source),
            tags=["scheduled", restore.plan_tag(OTHER_PLAN_ID)],
        )
        self.write_control(
            snapshots=[
                current,
                legacy,
                wrong_host,
                wrong_tag,
                wrong_path,
                conflicting_binding,
            ]
        )

        result, stdout, _ = self.invoke(["--list-snapshots-json"])
        self.assertEqual(result, 0)
        listing = json.loads(stdout)
        self.assertEqual(
            {item["id"] for item in listing["snapshots"]}, {NEW_ID, LEGACY_ID}
        )
        by_id = {item["id"]: item for item in listing["snapshots"]}
        self.assertEqual(by_id[NEW_ID]["binding_state"], restore.SNAPSHOT_BINDING_PLAN)
        self.assertEqual(
            by_id[LEGACY_ID]["binding_state"], restore.SNAPSHOT_BINDING_LEGACY
        )
        self.assertNotIn("plan_id", by_id[LEGACY_ID])
        self.assertNotIn("config_generation", by_id[LEGACY_ID])

        with self.assertRaisesRegex(RuntimeError, "did not match|not part"):
            self.invoke(["--list-tree-json", "--snapshot", LEGACY_ID])
        with self.assertRaisesRegex(ValueError, "exact 64-character"):
            self.invoke(
                [
                    "--list-tree-json",
                    "--snapshot",
                    "latest",
                    "--allow-legacy-unbound",
                ]
            )
        with self.assertRaisesRegex(ValueError, "exact 64-character"):
            self.invoke(
                [
                    "--list-tree-json",
                    "--snapshot",
                    LEGACY_ID[:12],
                    "--allow-legacy-unbound",
                ]
            )

        result, stdout, _ = self.invoke(
            [
                "--list-tree-json",
                "--snapshot",
                LEGACY_ID,
                "--allow-legacy-unbound",
            ]
        )
        self.assertEqual(result, 0)
        tree = json.loads(stdout)
        self.assertEqual(tree["snapshot_id"], LEGACY_ID)
        self.assertEqual(tree["snapshot_binding"], restore.SNAPSHOT_BINDING_LEGACY)
        self.assertIsNone(tree["snapshot_generation"])

        target = self.root / "legacy-restore"
        report = self.state / "legacy-restore.json"
        result, _, _ = self.invoke(
            [
                "--snapshot",
                LEGACY_ID,
                "--allow-legacy-unbound",
                "--target",
                str(target),
                "--report",
                str(report),
            ]
        )
        self.assertEqual(result, 0)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["snapshot_binding"], restore.SNAPSHOT_BINDING_LEGACY)
        self.assertIsNone(payload["plan_id"])
        self.assertIsNone(payload["snapshot_generation"])

    def test_plan_selection_rejects_mismatch_malformed_and_multiple_generation_tags(self) -> None:
        self.enable_plan(generation=2)
        cases = {
            "mismatched-plan": snapshot(
                WRONG_HOST_ID,
                "2026-07-21T01:00:00Z",
                str(self.source),
                tags=[
                    "scheduled",
                    restore.plan_tag(OTHER_PLAN_ID),
                    restore.generation_tag(2),
                ],
            ),
            "malformed-generation": snapshot(
                WRONG_TAG_ID,
                "2026-07-21T01:00:00Z",
                str(self.source),
                tags=[
                    "scheduled",
                    restore.plan_tag(PLAN_ID),
                    restore.GENERATION_TAG_PREFIX + "not-a-number",
                ],
            ),
            "multiple-generations": snapshot(
                WRONG_PATH_ID,
                "2026-07-21T01:00:00Z",
                str(self.source),
                tags=[
                    "scheduled",
                    restore.plan_tag(PLAN_ID),
                    restore.generation_tag(2),
                    restore.generation_tag(3),
                ],
            ),
        }
        for label, invalid in cases.items():
            with self.subTest(label=label):
                self.write_control(snapshots=[invalid])
                with self.assertRaisesRegex(RuntimeError, "did not match|not part"):
                    self.invoke(["--list-tree-json", "--snapshot", invalid["id"]])

    def test_restore_report_includes_plan_and_historical_generation(self) -> None:
        self.enable_plan(generation=2)
        historical = snapshot(
            OLD_ID,
            "2026-07-20T01:00:00Z",
            str(self.root / "retired-source"),
            tags=[
                "scheduled",
                restore.plan_tag(PLAN_ID),
                restore.generation_tag(1),
            ],
        )
        self.write_control(snapshots=[historical])
        target = self.root / "historical-restore"
        report = self.state / "historical-restore.json"
        result, _, _ = self.invoke(
            [
                "--snapshot",
                OLD_ID,
                "--target",
                str(target),
                "--report",
                str(report),
            ]
        )
        self.assertEqual(result, 0)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["plan_id"], PLAN_ID)
        self.assertEqual(payload["snapshot_generation"], 1)
        restore_command = [args for args in self.read_log() if "restore" in args][0]
        self.assertIn(OLD_ID, restore_command)
        self.assertNotIn("latest", restore_command)

    def test_historical_human_list_cli_is_preserved(self) -> None:
        with mock.patch.object(restore.subprocess, "call", return_value=0) as call:
            result, stdout, _ = self.invoke(["--list"])
        self.assertEqual(result, 0)
        self.assertEqual(stdout, "")
        command = call.call_args.args[0]
        self.assertEqual(command[-1], "snapshots")
        self.assertNotIn("--json", command)

    def test_target_rejects_protected_topologies_nonempty_and_reparse(self) -> None:
        with mock.patch.object(restore, "ensure_local_volume"):
            with self.assertRaisesRegex(RuntimeError, "overlap"):
                restore.validate_restore_target(
                    self.source / "inside",
                    self.config,
                    self.config_path,
                    self.repository,
                )
            with self.assertRaisesRegex(RuntimeError, "overlap"):
                restore.validate_restore_target(
                    self.root,
                    self.config,
                    self.config_path,
                    self.repository,
                )
            with self.assertRaisesRegex(RuntimeError, "protected backup state"):
                restore.validate_restore_target(
                    self.state / "restore",
                    self.config,
                    self.config_path,
                    self.repository,
                )
            nonempty = self.root / "nonempty"
            nonempty.mkdir()
            (nonempty / "existing.txt").write_text("do not merge", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "absent or an empty"):
                restore.validate_restore_target(
                    nonempty,
                    self.config,
                    self.config_path,
                    self.repository,
                )
            reparse_parent = self.root / "reparse-parent"
            reparse_parent.mkdir()
            with mock.patch.object(
                restore,
                "path_is_reparse",
                side_effect=lambda path: Path(path) == reparse_parent,
            ):
                with self.assertRaisesRegex(RuntimeError, "reparse"):
                    restore.validate_restore_target(
                        reparse_parent / "restore",
                        self.config,
                        self.config_path,
                        self.repository,
                    )
        with self.assertRaisesRegex(RuntimeError, "local drive"):
            restore.ensure_local_volume(Path(r"\\server\share\restore"))

    def test_verified_restore_report_and_non_destructive_restic_arguments(self) -> None:
        target = self.root / "verified-restore"
        report = self.state / "restore-report.json"
        before = self.immutable_state()
        result, _, stderr = self.invoke(
            [
                "--snapshot",
                "latest",
                "--target",
                str(target),
                "--include",
                "/C/Users/file.txt",
                "--report",
                str(report),
            ]
        )
        self.assertEqual(result, 0)
        self.assertEqual(stderr, "")
        self.assertTrue((target / "C" / "Users" / "file.txt").is_file())
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["schema"], restore.REPORT_SCHEMA)
        self.assertEqual(payload["repository"], str(self.repository.resolve()))
        self.assertEqual(payload["repository_id"], REPOSITORY_ID)
        self.assertEqual(payload["snapshot_id"], NEW_ID)
        self.assertEqual(payload["result"], "verified")
        self.assertTrue(payload["verified"])
        self.assertFalse(payload["partial_target_retained"])
        self.assertEqual(payload["restic_exit_code"], 0)
        self.assertTrue(payload["started_utc"].endswith("Z"))
        self.assertTrue(payload["finished_utc"].endswith("Z"))
        restore_commands = [args for args in self.read_log() if "restore" in args]
        self.assertEqual(len(restore_commands), 1)
        command = restore_commands[0]
        self.assertIn(NEW_ID, command)
        self.assertNotIn("latest", command)
        self.assertNotIn("--delete", command)
        self.assertEqual(command[command.index("--overwrite") + 1], "never")
        self.assertIn("--verify", command)
        self.assertEqual(self.immutable_state(), before)

    def test_restic_sees_only_an_allow_listed_environment(self) -> None:
        planted = {
            "RESTIC_PASSWORD_COMMAND": r"C:\planted\evil.cmd",
            "RESTIC_PASSWORD_FILE": r"C:\planted\password.txt",
            "RESTIC_REPOSITORY_FILE": r"C:\planted\repository.txt",
            "RESTIC_CACHE_DIR": r"C:\planted\cache",
            "RCLONE_CONFIG_PLANTED_TYPE": "sftp",
            "RCLONE_LOG_FILE": r"C:\planted\rclone.log",
            "PYTHONPATH": r"C:\planted",
            "COR_PROFILER": "{00000000-0000-0000-0000-000000000000}",
            "PATH": r"C:\planted",
            "SystemRoot": r"C:\planted",
        }
        allowed = {
            "SYSTEMROOT",
            "WINDIR",
            "SYSTEMDRIVE",
            "COMSPEC",
            "PATH",
            "PATHEXT",
            "OS",
            "NUMBER_OF_PROCESSORS",
            "PROCESSOR_ARCHITECTURE",
            "LOCALAPPDATA",
            "RESTIC_PASSWORD",
        }
        target = self.root / "clean-environment-restore"
        with mock.patch.dict(os.environ, planted):
            listing, _, listing_errors = self.invoke(["--list-snapshots-json"])
            restored, _, restore_errors = self.invoke(
                ["--snapshot", "latest", "--target", str(target)]
            )
        self.assertEqual(0, listing, listing_errors)
        self.assertEqual(0, restored, restore_errors)
        self.assertTrue((target / "restored.txt").is_file())
        calls = [
            json.loads(line)
            for line in self.fake_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertTrue(any("restore" in call["args"] for call in calls))
        for call in calls:
            names = set(call["environment"])
            self.assertLessEqual(names, allowed, call["args"])
            self.assertIn("RESTIC_PASSWORD", names)

    def test_exact_configured_source_uses_immutable_subfolder_selector(self) -> None:
        target = self.root / "source-restore"
        report = self.state / "source-restore-report.json"
        result, _, stderr = self.invoke(
            [
                "--snapshot",
                "latest",
                "--source",
                str(self.source),
                "--target",
                str(target),
                "--report",
                str(report),
            ]
        )
        self.assertEqual(result, 0)
        self.assertEqual(stderr, "")
        expected_subfolder = restore.windows_snapshot_path(self.source)
        command = [args for args in self.read_log() if "restore" in args][0]
        selector = command[command.index("restore") + 1]
        self.assertEqual(selector, NEW_ID + ":" + expected_subfolder)
        self.assertNotIn("--include", command)
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["snapshot_id"], NEW_ID)
        self.assertEqual(payload["snapshot_subfolder"], expected_subfolder)

    def test_source_rejects_an_already_subfoldered_snapshot_selector(self) -> None:
        with self.assertRaisesRegex(ValueError, "cannot be combined"):
            self.invoke(
                [
                    "--snapshot",
                    "latest:/already-selected",
                    "--source",
                    str(self.source),
                    "--target",
                    str(self.root / "invalid-source-restore"),
                ]
            )

    def test_existing_empty_normal_target_is_accepted_without_merge(self) -> None:
        target = self.root / "empty-restore"
        target.mkdir()
        report = self.state / "empty-target-report.json"
        result, _, _ = self.invoke(
            ["--target", str(target), "--report", str(report)]
        )
        self.assertEqual(result, 0)
        self.assertTrue((target / "restored.txt").is_file())
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertTrue(payload["target_preexisted_empty"])

    def test_recovery_drill_finds_nested_samples_with_bounded_shallow_queries(self) -> None:
        source = "/E/source"
        nested = source + "/nested"
        responses = [
            [{"type": "dir", "path": source}, {"type": "dir", "path": nested}],
            [
                {"type": "file", "path": nested + "/one.txt", "size": 11},
                {"type": "file", "path": nested + "/two.txt", "size": 12},
            ],
        ]
        with mock.patch.object(
            restore, "run_restic_json_lines_bounded", side_effect=responses
        ) as runner:
            entries = restore.query_recovery_drill_listing(
                ["restic"], {}, False, NEW_ID,
                canary_snapshot_path=source + "/canary.txt",
                source_snapshot_paths=[source],
            )
        sample = restore.choose_recovery_drill_sample(
            entries,
            canary_snapshot_path=source + "/canary.txt",
            source_snapshot_paths=[source],
        )
        self.assertEqual([nested + "/one.txt", nested + "/two.txt"], [item["path"] for item in sample])
        self.assertEqual(2, runner.call_count)
        self.assertEqual(source, runner.call_args_list[0].args[1][-1])
        self.assertEqual(nested, runner.call_args_list[1].args[1][-1])
        self.assertNotIn("--recursive", runner.call_args_list[0].args[1])

    def test_failed_restore_retains_partial_target_and_report_leaks_no_secret(self) -> None:
        # Exercise the existing password-command path as well as the report's
        # strict separation from subprocess argv and DPAPI metadata.
        self.secret_file.write_text("fake encrypted DPAPI blob", encoding="utf-8")
        self.write_control(expected_password=None, restore_mode="failure", restore_exit=23)
        target = self.root / "partial-restore"
        report = self.state / "failed-restore-report.json"
        before = self.immutable_state()
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(restore, "ensure_local_volume"), redirect_stdout(
            stdout
        ), redirect_stderr(stderr):
            result = restore.main(
                [
                    *self.base_arguments(recovery_key=False),
                    "--snapshot",
                    "latest",
                    "--target",
                    str(target),
                    "--report",
                    str(report),
                ]
            )
        self.assertEqual(result, 23)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("partial alternate target was retained", stderr.getvalue())
        self.assertTrue((target / "partial.txt").is_file())
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["result"], "partial")
        self.assertFalse(payload["verified"])
        self.assertTrue(payload["partial_target_retained"])
        self.assertEqual(payload["restic_exit_code"], 23)
        serialized = report.read_text(encoding="utf-8").casefold()
        for forbidden in (
            self.password.casefold(),
            str(self.secret_file).casefold(),
            "--password-command",
            "secret_store.py",
            "restic_password",
            "dpapi",
        ):
            self.assertNotIn(forbidden, serialized)
        protected_commands = self.read_log()
        self.assertTrue(
            any("--password-command" in command for command in protected_commands)
        )
        self.assertLessEqual(len(report.read_bytes()), restore.MAX_REPORT_BYTES)
        self.assertEqual(self.immutable_state(), before)

    def test_preflight_failure_writes_error_report_without_touching_target(self) -> None:
        target = self.root / "already-populated"
        target.mkdir()
        sentinel = target / "keep.txt"
        sentinel.write_text("keep me", encoding="utf-8")
        report = self.state / "preflight-error.json"
        with mock.patch.object(restore, "ensure_local_volume"):
            with self.assertRaisesRegex(RuntimeError, "absent or an empty"):
                restore.main(
                    [
                        *self.base_arguments(),
                        "--target",
                        str(target),
                        "--report",
                        str(report),
                    ]
                )
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep me")
        payload = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(payload["result"], "error")
        self.assertFalse(payload["partial_target_retained"])
        self.assertIsNone(payload["restic_exit_code"])
        self.assertFalse(any("restore" in args for args in self.read_log()))

    def test_report_cannot_replace_repository_config_or_backup_config(self) -> None:
        target = self.root / "restore"
        with mock.patch.object(restore, "ensure_local_volume"):
            with self.assertRaisesRegex(RuntimeError, "outside the Restic repository"):
                restore.main(
                    [
                        *self.base_arguments(),
                        "--target",
                        str(target),
                        "--report",
                        str(self.repository / "report.json"),
                    ]
                )
            with self.assertRaisesRegex(RuntimeError, "protected backup configuration"):
                restore.main(
                    [
                        *self.base_arguments(),
                        "--target",
                        str(target),
                        "--report",
                        str(self.config_path),
                    ]
                )

    def restore_into(self, target: Path, report_name: str) -> tuple[int, dict]:
        report = self.state / report_name
        result, _, _ = self.invoke(
            ["--snapshot", "latest", "--target", str(target), "--report", str(report)]
        )
        return result, json.loads(report.read_text(encoding="utf-8"))

    def assert_swap_refused(self, target: Path, victims: list[str]) -> None:
        decoy = self.root / "decoy"
        decoy.mkdir()
        swap_log = self.root / "swap.json"
        self.write_control(
            restore_mode="swap",
            swap_victims=victims,
            decoy=str(decoy),
            swap_log=str(swap_log),
        )
        result, payload = self.restore_into(target, "swap-report.json")
        outcomes = json.loads(swap_log.read_text(encoding="utf-8"))
        self.assertEqual([], list(decoy.iterdir()), "a restore wrote through a swapped-in junction")
        self.assertTrue(outcomes)
        for victim, outcome in outcomes.items():
            with self.subTest(victim=victim):
                # 32: held open without delete sharing; 5: a folder below it is held open.
                self.assertIn(outcome, (5, 32))
        self.assertEqual(0, result)
        self.assertEqual("verified", payload["result"])
        self.assertTrue((target / "restored.txt").is_file())
        self.assertEqual(["restored.txt"], sorted(item.name for item in target.iterdir()))

    def test_target_swapped_for_a_link_during_restore_is_never_written_through(self) -> None:
        target = self.root / "swap-target"
        self.assert_swap_refused(target, ["--target", str(target)])

    def test_folder_above_the_target_cannot_be_swapped_during_restore(self) -> None:
        parent = self.root / "swap-parent"
        self.assert_swap_refused(parent / "target", [str(parent)])

    def test_windows_and_program_folders_are_refused(self) -> None:
        fake_windows = self.root / "Fake Windows"
        fake_program_files = self.root / "Fake Program Files With A Long Name"
        fake_program_data = self.root / "Fake ProgramData"
        for folder in (fake_windows, fake_program_files, fake_program_data):
            folder.mkdir()
        (fake_program_files / "Vendor").mkdir()
        cases = {
            "new folder": (fake_windows / "Setup" / "Scripts", fake_windows / "Setup"),
            "existing empty folder": (fake_program_files / "Vendor", None),
            "the folder itself": (fake_program_data, None),
            "other letter case": (Path(str(fake_program_data).upper()) / "New", fake_program_data / "New"),
        }
        alias = short_path(fake_program_files)
        if alias is not None:
            cases["short name"] = (Path(alias) / "Alias", fake_program_files / "Alias")
        roots = [str(fake_windows), str(fake_program_files), str(fake_program_data)]
        with mock.patch.object(restore, "system_folder_roots", create=True, return_value=roots):
            for label, (target, created) in cases.items():
                with self.subTest(label=label):
                    report = self.state / "system-folder-report.json"
                    with self.assertRaisesRegex(RuntimeError, SYSTEM_FOLDER_REFUSAL):
                        self.invoke(["--target", str(target), "--report", str(report)])
                    payload = json.loads(report.read_text(encoding="utf-8"))
                    self.assertEqual(SYSTEM_FOLDER_REFUSAL, payload["error"])
                    if created is not None:
                        self.assertFalse(created.exists())
                    self.assertEqual([], list((fake_program_files / "Vendor").iterdir()))
            # The recovery drill keeps its own folder below ProgramData.
            drill_target, _ = restore.validate_restore_target(
                fake_program_data / "drill-1",
                self.config,
                self.config_path,
                self.repository,
                allow_system_folders=True,
            )
            self.assertEqual(fake_program_data / "drill-1", drill_target)
        self.assertFalse(any("restore" in args for args in self.read_log()))
        if alias is None:
            self.skipTest("this volume does not make short names; the other cases ran")

    def test_system_folders_do_not_follow_the_environment(self) -> None:
        expected = restore.system_folder_roots()
        self.assertGreaterEqual(len(expected), 4)
        windows_drive = ntpath.splitdrive(expected[0])[0].upper()
        # A fresh process whose environment the requesting user has steered: the system drive and every folder variable
        # point elsewhere. The known-folder API caches what it found, so this cannot be done in this process.
        other_drive = "Q:" if windows_drive != "Q:" else "R:"
        fake = str(self.root / "environment")
        environment = dict(os.environ)
        for name in (
            "ProgramFiles",
            "ProgramFiles(x86)",
            "ProgramW6432",
            "CommonProgramFiles",
            "SystemRoot",
            "windir",
            "ProgramData",
            "ALLUSERSPROFILE",
            "PUBLIC",
        ):
            environment[name] = fake + "\\" + name
        environment["SystemDrive"] = other_drive
        code = (
            "import json, sys; sys.path.insert(0, sys.argv[1]); import restore; "
            "print(json.dumps(restore.system_folder_roots()))"
        )
        completed = subprocess.run(
            [sys.executable, "-I", "-c", code, str(SOURCE_ROOT)],
            env=environment,
            capture_output=True,
            text=True,
            timeout=120,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        steered = json.loads(completed.stdout)
        self.assertEqual(expected, steered)
        for root in steered:
            self.assertFalse(root.casefold().startswith(fake.casefold()))
            self.assertFalse(root.upper().startswith(other_drive))
            self.assertRegex(root, r"^[A-Za-z]:\\")

    def test_program_data_comes_from_the_machine_record_with_the_windows_drive(self) -> None:
        import winreg

        def record(value: str, kind: int = winreg.REG_EXPAND_SZ) -> object:
            return mock.patch("winreg.QueryValueEx", return_value=(value, kind))

        with record(r"%SystemDrive%\ProgramData"):
            self.assertEqual(r"D:\ProgramData", restore.program_data_folder(r"D:\Windows"))
        with record(r"%SYSTEMDRIVE%\Shared Data"):
            self.assertEqual(r"E:\Shared Data", restore.program_data_folder(r"E:\WINDOWS"))
        with record(r"F:\ProgramData", winreg.REG_SZ):
            self.assertEqual(r"F:\ProgramData", restore.program_data_folder(r"C:\Windows"))
        for value in ("%ALLUSERSPROFILE%", r"%SystemDrive%\%PUBLIC%", "ProgramData", r"\\server\share\ProgramData"):
            with self.subTest(value=value), record(value):
                with self.assertRaisesRegex(RuntimeError, "could not be identified"):
                    restore.program_data_folder(r"C:\Windows")
        with record(r"%SystemDrive%\ProgramData", winreg.REG_DWORD):
            with self.assertRaisesRegex(RuntimeError, "could not be identified"):
                restore.program_data_folder(r"C:\Windows")

    def restore_folder_security(self) -> tuple[str, str, set[tuple[str, ...]]]:
        """The owner, DACL flags and entries of the folder Restic was given, as the fake Restic read them, with the
        owner and each trustee as a SID."""

        text = self.fake_log.with_suffix(".target-security.txt").read_text(encoding="utf-8")
        match = re.fullmatch(r"O:(.+?)D:([A-Z]*)((?:\([^)]*\))*)", text)
        self.assertIsNotNone(match, text)
        owner, flags, entries = match.groups()
        return (
            sid_text(owner),
            flags,
            {by_principal(tuple(entry.split(";"))) for entry in re.findall(r"\(([^)]*)\)", entries)},
        )

    def assert_restore_folder_security(self, elevated: bool, *, check_owner: bool) -> None:
        owner, flags, entries = self.restore_folder_security()
        # Protected: nothing is inherited from the folder the user chose.
        self.assertIn("P", flags)
        expected = {("A", "OICI", "FA", "", "", "SY"), ("A", "OICI", "FA", "", "", "BA")}
        if not elevated:
            expected.add(("A", "OICI", "FA", "", "", restore.current_user_sid()))
        # Compared by the principals they name: Windows writes the built-in Administrator account, the one a hosted CI
        # runner runs as, as LA rather than by its SID.
        self.assertEqual({by_principal(entry) for entry in expected}, entries)
        if check_owner and elevated:
            self.assertEqual(sid_text("BA"), owner)

    def test_the_account_is_read_before_its_token_record_is_released(self) -> None:
        # The SID in a TOKEN_USER record lies inside that same record, so the record must still be held when the SID is
        # turned into text. Here the record is wiped the moment it is released, as reused memory would be.
        listed = subprocess.run(["whoami", "/user", "/fo", "csv", "/nh"], capture_output=True, text=True, check=True)
        expected = listed.stdout.strip().rsplit(",", 1)[-1].strip('"')
        self.assertRegex(expected, r"^S-1-\d+(-\d+)+$")
        read = restore._process_token_information

        def wiped_when_released(information_class: int) -> ctypes.Array:
            original = read(information_class)
            size = ctypes.sizeof(original)

            class Wiped(ctypes.c_char * size):  # type: ignore[misc, valid-type]
                def __del__(self) -> None:
                    ctypes.memset(ctypes.addressof(self), 0, ctypes.sizeof(self))

            record = Wiped()
            ctypes.memmove(record, original, size)
            start = ctypes.addressof(original)
            pointer = ctypes.c_void_p.from_buffer(original).value or 0
            if start <= pointer < start + size:
                # The record's own SID pointer, moved along with it.
                ctypes.c_void_p.from_buffer(record).value = ctypes.addressof(record) + (pointer - start)
            return record

        with mock.patch.object(restore, "_process_token_information", wiped_when_released):
            self.assertEqual(expected, restore.current_user_sid())

    def test_restore_folder_is_admin_only_when_elevated(self) -> None:
        administrators_and_system = "(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        self.assertEqual("O:BAD:PAI" + administrators_and_system, restore.restore_folder_sddl(True))
        self.assertEqual(
            "D:PAI" + administrators_and_system + "(A;OICI;FA;;;S-1-9-1234-5678)",
            restore.restore_folder_sddl(False, "S-1-9-1234-5678"),
        )
        with self.assertRaisesRegex(RuntimeError, "could not be identified"):
            restore.restore_folder_sddl(False, "BA)(A;OICI;FA;;;WD")
        # What really lands on disk, read by the fake Restic from the folder it was given, as this run is (an
        # administrator in CI, a standard user locally). The restore really goes through that folder: a new hidden
        # folder inside the target, gone afterwards.
        elevated = restore.process_is_elevated()
        target = self.root / "folder-check"
        self.write_control(record_security=True)
        result, payload = self.restore_into(target, "folder-report.json")
        self.assertEqual(0, result)
        self.assertEqual("verified", payload["result"])
        self.assert_restore_folder_security(elevated, check_owner=True)
        written = Path(self.fake_log.with_suffix(".target.txt").read_text(encoding="utf-8"))
        # Restic is given the folder's final path, with long names, while a runner's temporary folder may be named by
        # its short 8.3 alias (GitHub's is), so both are compared in their long form.
        self.assertEqual(restore.canonical_path(target), restore.canonical_path(written.parent))
        self.assertTrue(written.name.startswith(restore.RESTORE_FOLDER_PREFIX))
        self.assertFalse(written.exists())
        self.assertEqual(["restored.txt"], sorted(item.name for item in target.iterdir()))
        # And the other kind of run. Only an elevated process may make Administrators the owner, so an unelevated run
        # leaves the owner out; the fake Restic, running as this user, then only reads the folder.
        other = not elevated
        build = restore.restore_folder_sddl

        def without_owner_unless_elevated(is_elevated: bool, user_sid: str | None = None) -> str:
            text = build(is_elevated, user_sid)
            return text if elevated else text.replace("O:BA", "", 1)

        self.write_control(record_security=True, restore_mode="record_only")
        other_target = self.root / "folder-check-other"
        try:
            with mock.patch.object(restore, "process_is_elevated", return_value=other), mock.patch.object(
                restore, "restore_folder_sddl", side_effect=without_owner_unless_elevated
            ):
                result, payload = self.restore_into(other_target, "folder-other.json")
            self.assertEqual(0, result)
            self.assert_restore_folder_security(other, check_owner=False)
        finally:
            # Unelevated, the administrator-only folder cannot be opened again to be deleted; this run owns it, so it
            # can give it back its inherited permissions for the clean-up.
            for leftover in other_target.glob(restore.RESTORE_FOLDER_PREFIX + "*"):
                subprocess.run(["icacls", str(leftover), "/reset"], capture_output=True, check=False)

    def test_restored_items_get_the_permissions_of_the_chosen_folder(self) -> None:
        target = self.root / "permissions"
        self.write_control(restore_mode="tree")
        result, payload = self.restore_into(target, "permissions-report.json")
        self.assertEqual(0, result)
        self.assertEqual("verified", payload["result"])
        (target / "control").mkdir()
        (target / "control.txt").write_text("made in place", encoding="utf-8")
        self.assertEqual(["control", "control.txt", "nested", "restored.txt"], sorted(i.name for i in target.iterdir()))
        self.assertEqual(dacl_entries(target / "control.txt"), dacl_entries(target / "restored.txt"))
        self.assertEqual(dacl_entries(target / "control"), dacl_entries(target / "nested"))
        self.assertEqual(dacl_entries(target / "control.txt"), dacl_entries(target / "nested" / "inner.txt"))

    def test_partial_restore_is_handed_over_and_leaves_no_restore_folder(self) -> None:
        self.write_control(restore_mode="failure", restore_exit=23)
        target = self.root / "partial-handover"
        result, payload = self.restore_into(target, "partial-handover.json")
        self.assertEqual(23, result)
        self.assertEqual("partial", payload["result"])
        self.assertTrue(payload["partial_target_retained"])
        self.assertEqual(["partial.txt"], sorted(item.name for item in target.iterdir()))

    def test_a_name_taken_meanwhile_is_left_in_a_visible_restore_folder(self) -> None:
        self.write_control(restore_mode="collide")
        target = self.root / "collide"
        result, payload = self.restore_into(target, "collide.json")
        self.assertEqual(1, result)
        self.assertEqual("partial", payload["result"])
        self.assertTrue(payload["partial_target_retained"])
        self.assertEqual("made by the user meanwhile", (target / "restored.txt").read_text(encoding="utf-8"))
        folders = [item for item in target.iterdir() if item.is_dir()]
        self.assertEqual(1, len(folders))
        self.assertIn(folders[0].name, payload["error"])
        self.assertIn("same names appeared there", payload["error"])
        self.assertEqual("verified fake data", (folders[0] / "restored.txt").read_text(encoding="utf-8"))
        self.assertFalse(os.stat(folders[0]).st_file_attributes & stat.FILE_ATTRIBUTE_HIDDEN)

    def test_folders_get_their_permissions_after_everything_inside_them(self) -> None:
        # A restored folder's own permissions are written after everything inside it, so the hand-back itself never
        # opens a folder up while its contents are still being handed back. (A folder Restic restored with the user as
        # its owner is the user's to change before that anyway; see _hand_back_entry.)
        target = self.root / "deepest-first"
        self.write_control(restore_mode="tree")
        written: list[str] = []
        write = restore._write_dacl

        def recording(handle: int, descriptor: object) -> None:
            written.append(restore._final_path(handle).casefold())
            write(handle, descriptor)

        with mock.patch.object(restore, "_write_dacl", side_effect=recording):
            result, payload = self.restore_into(target, "deepest-first.json")
        self.assertEqual(0, result)
        self.assertEqual("verified", payload["result"])
        inner = [index for index, path in enumerate(written) if path.endswith(r"\nested\inner.txt")]
        folder = [index for index, path in enumerate(written) if path.endswith(r"\nested")]
        self.assertEqual(1, len(inner), written)
        self.assertEqual(1, len(folder), written)
        self.assertLess(inner[0], folder[0], written)
        self.assertEqual("nested fake data", (target / "nested" / "inner.txt").read_text(encoding="utf-8"))

    def busy_rename(self, failures: int, error: int) -> tuple[object, list[str]]:
        """_rename_into failing `failures` times with a Windows error before it works (-1: always)."""

        calls: list[str] = []
        rename = restore._rename_into

        def busy(handle: int, directory: int, name: str) -> None:
            calls.append(name)
            if failures < 0 or len(calls) <= failures:
                raise OSError(0, "in use", None, error)
            rename(handle, directory, name)

        return busy, calls

    def test_an_item_in_use_for_a_moment_still_moves_in(self) -> None:
        target = self.root / "busy-briefly"
        busy, calls = self.busy_rename(2, 32)
        with mock.patch.object(restore, "_rename_into", side_effect=busy), mock.patch.object(
            restore, "_MOVE_RETRY_DELAYS", (0.0, 0.0, 0.0)
        ):
            result, payload = self.restore_into(target, "busy-briefly.json")
        self.assertEqual(0, result)
        self.assertEqual("verified", payload["result"])
        self.assertEqual(["restored.txt"] * 3, calls)
        self.assertEqual(["restored.txt"], sorted(item.name for item in target.iterdir()))

    def test_an_item_kept_in_use_is_not_called_a_name_clash(self) -> None:
        for error in (5, 32):
            with self.subTest(error=error):
                target = self.root / f"busy-{error}"
                busy, calls = self.busy_rename(-1, error)
                with mock.patch.object(restore, "_rename_into", side_effect=busy), mock.patch.object(
                    restore, "_MOVE_RETRY_DELAYS", (0.0, 0.0)
                ):
                    result, payload = self.restore_into(target, f"busy-{error}.json")
                self.assertEqual(1, result)
                self.assertEqual("partial", payload["result"])
                self.assertEqual(3, len(calls))
                folders = [item for item in target.iterdir() if item.is_dir()]
                self.assertEqual(1, len(folders))
                self.assertIn(folders[0].name, payload["error"])
                self.assertNotIn("same names appeared there", payload["error"])
                self.assertIn("another program may have been using them", payload["error"])
                self.assertEqual("verified fake data", (folders[0] / "restored.txt").read_text(encoding="utf-8"))

    def bracket_tree(self) -> list[dict[str, object]]:
        def node(path: str, kind: str = "file") -> dict[str, object]:
            return {
                "struct_type": "node",
                "name": path.rsplit("/", 1)[-1],
                "type": kind,
                "path": path,
                "size": 7,
            }

        return [
            node("/C/Users", "dir"),
            node("/C/Users/Photos [2020]", "dir"),
            node("/C/Users/Photos [2020]/a.txt"),
            # What "Photos [2020]" and "Notes[1].txt" match when Restic reads them as patterns.
            node("/C/Users/Photos 2", "dir"),
            node("/C/Users/Photos 2/decoy.txt"),
            node("/C/Users/Notes[1].txt"),
            node("/C/Users/Notes1.txt"),
            node("/C/Users/plain.txt"),
        ]

    def restore_selection(
        self, label: str, chosen: list[str], *extra: str, **control: object
    ) -> tuple[int, str, dict, Path]:
        self.write_control(**{"tree": self.bracket_tree(), **control})
        target = self.root / label
        report = self.state / f"{label}-report.json"
        arguments = ["--snapshot", "latest", *extra, "--target", str(target), "--report", str(report)]
        for item in chosen:
            arguments.extend(["--include", item])
        result, _, stderr = self.invoke(arguments)
        return result, stderr, json.loads(report.read_text(encoding="utf-8")), target

    @staticmethod
    def restored_files(target: Path) -> list[str]:
        return sorted(item.relative_to(target).as_posix() for item in target.rglob("*") if item.is_file())

    def test_names_with_square_brackets_restore_as_themselves(self) -> None:
        result, stderr, payload, target = self.restore_selection(
            "brackets", ["/C/Users/Photos [2020]", "/C/Users/Notes[1].txt"]
        )
        self.assertEqual((0, ""), (result, stderr))
        self.assertEqual("verified", payload["result"])
        self.assertTrue(payload["verified"])
        self.assertEqual(
            ["C/Users/Notes[1].txt", "C/Users/Photos [2020]/a.txt"], self.restored_files(target)
        )
        command = [args for args in self.read_log() if "restore" in args][0]
        self.assertEqual(
            ["/C/Users/Photos [[]2020]", "/C/Users/Notes[[]1].txt"],
            [command[index + 1] for index, value in enumerate(command) if value == "--include"],
        )
        # The report names the items as they were chosen.
        self.assertEqual(["/C/Users/Photos [2020]", "/C/Users/Notes[1].txt"], payload["includes"])

    def test_restic_restoring_no_chosen_item_ends_the_restore_incomplete(self) -> None:
        result, stderr, payload, target = self.restore_selection(
            "nothing", ["/C/Users/plain.txt", "/C/Users/Photos [2020]"], restore_mode="nothing"
        )
        self.assertEqual(1, result)
        self.assertEqual("partial", payload["result"])
        self.assertFalse(payload["verified"])
        self.assertTrue(payload["partial_target_retained"])
        self.assertEqual(0, payload["restic_exit_code"])
        self.assertEqual(
            "Restic finished without restoring every chosen item (2 of 2 missing); "
            "the alternate target was retained for inspection",
            payload["error"],
        )
        self.assertIn("RESTORE INCOMPLETE", stderr)
        self.assertIn("  /C/Users/Photos [2020]\n", stderr)
        self.assertTrue(target.is_dir())

    def test_only_the_chosen_items_that_did_not_come_back_are_missing(self) -> None:
        # The dashboard only offers what the backup lists; a name the backup does not hold stands in for
        # any item Restic leaves out while it restores the rest.
        result, stderr, payload, target = self.restore_selection(
            "one-missing", ["/C/Users/plain.txt", "/C/Users/gone [old].txt"]
        )
        self.assertEqual(1, result)
        self.assertEqual("partial", payload["result"])
        self.assertIn("(1 of 2 missing)", payload["error"])
        self.assertIn("  /C/Users/gone [old].txt\n", stderr)
        self.assertNotIn("  /C/Users/plain.txt", stderr)
        self.assertEqual(["C/Users/plain.txt"], self.restored_files(target))

    def test_items_left_in_the_restore_folder_are_not_also_called_missing(self) -> None:
        # The chosen items are looked for in the chosen folder after the hand-over. When the hand-over left them in the
        # restore folder, the restore already ends as incomplete with a message that says where they are, and that
        # message is the one the report keeps.
        busy, calls = self.busy_rename(-1, 32)
        with mock.patch.object(restore, "_rename_into", side_effect=busy), mock.patch.object(
            restore, "_MOVE_RETRY_DELAYS", (0.0, 0.0)
        ):
            result, stderr, payload, target = self.restore_selection("left-behind", ["/C/Users/plain.txt"])
        self.assertEqual(1, result)
        self.assertEqual(3, len(calls))
        self.assertEqual(("partial", False, 0), (payload["result"], payload["verified"], payload["restic_exit_code"]))
        self.assertIn("another program may have been using them", payload["error"])
        self.assertNotIn("without restoring every chosen item", payload["error"])
        self.assertIn("could not be moved into", stderr)
        self.assertNotIn("Not restored", stderr)
        folders = [item for item in target.iterdir() if item.is_dir()]
        self.assertEqual(1, len(folders))
        self.assertIn(folders[0].name, payload["error"])
        self.assertEqual(["C/Users/plain.txt"], self.restored_files(folders[0]))

    def test_a_skipped_item_is_still_named_when_the_hand_over_left_others_behind(self) -> None:
        # The items the hand-over left are looked for in the restore folder, where they are; a chosen item that Restic
        # skipped is in neither place, and the hand-over's message, which says where the others are, also names it.
        busy, _ = self.busy_rename(-1, 32)
        with mock.patch.object(restore, "_rename_into", side_effect=busy), mock.patch.object(
            restore, "_MOVE_RETRY_DELAYS", (0.0, 0.0)
        ):
            result, stderr, payload, target = self.restore_selection(
                "left-and-skipped", ["/C/Users/plain.txt", "/C/Users/gone [old].txt"]
            )
        self.assertEqual(1, result)
        self.assertEqual(("partial", False, 0), (payload["result"], payload["verified"], payload["restic_exit_code"]))
        folders = [item for item in target.iterdir() if item.is_dir()]
        self.assertEqual(1, len(folders))
        self.assertTrue(payload["error"].startswith("Some restored files could not be moved into the folder you chose"))
        self.assertIn(folders[0].name, payload["error"])
        self.assertTrue(
            payload["error"].endswith(
                " Besides those, 1 of the 2 items you chose was not restored at all. To try again, choose the folder "
                "that holds it and a new empty folder to restore into."
            ),
            payload["error"],
        )
        self.assertNotIn("Restic", payload["error"])
        self.assertIn("could not be moved into", stderr)
        self.assertIn("Not restored at all:\n  /C/Users/gone [old].txt\n", stderr)
        self.assertNotIn("  /C/Users/plain.txt", stderr)
        self.assertEqual(["C/Users/plain.txt"], self.restored_files(folders[0]))

    def test_items_the_hand_over_left_are_looked_for_in_the_restore_folder_only(self) -> None:
        target = self.root / "looked-for"
        restore_folder = target / ".rewindle-restore-0123456789abcdef"
        (restore_folder / "C" / "Users").mkdir(parents=True)
        (restore_folder / "C" / "Users" / "kept.txt").write_text("restored", encoding="utf-8")
        # A "C" that appeared in the target while the restore ran is someone else's, so what is in it does not count.
        (target / "C" / "Users").mkdir(parents=True)
        (target / "C" / "Users" / "theirs.txt").write_text("not restored", encoding="utf-8")
        (target / "D").mkdir()
        (target / "D" / "moved.txt").write_text("restored", encoding="utf-8")
        chosen = ["/C/Users/kept.txt", "/C/Users/theirs.txt", "/D/moved.txt", "/D/skipped.txt"]
        self.assertEqual(
            ["/C/Users/theirs.txt", "/D/skipped.txt"],
            restore.missing_chosen_items(target, chosen, str(restore_folder), ["c"]),
        )
        # Without anything left behind, everything is looked for in the target.
        self.assertEqual(["/C/Users/kept.txt", "/D/skipped.txt"], restore.missing_chosen_items(target, chosen))

    def test_what_is_added_to_the_hand_over_message_counts_the_skipped_items(self) -> None:
        cases = (
            (1, 1, "the item you chose was not restored at all", "holds it"),
            (2, 2, "none of the 2 items you chose was restored at all", "holds them"),
            (1, 3, "1 of the 3 items you chose was not restored at all", "holds it"),
            (2, 3, "2 of the 3 items you chose were not restored at all", "holds them"),
        )
        for missing, chosen, counted, holds in cases:
            with self.subTest(missing=missing, chosen=chosen):
                message = restore.also_not_restored_message(missing, chosen)
                self.assertTrue(message.startswith(f"Besides those, {counted}. To try again, "), message)
                self.assertIn(f"choose the folder that {holds} and a new empty folder", message)

    def test_a_restored_item_beyond_the_windows_path_limit_counts_as_restored(self) -> None:
        deep = "/C/Users/" + "/".join(f"a-rather-long-folder-name-{index:02d}" for index in range(9))
        chosen = deep + "/report [final].txt"
        self.assertGreater(len(str(self.root)) + len(chosen), 300)
        tree = [{"struct_type": "node", "name": "report [final].txt", "type": "file", "path": chosen, "size": 7}]
        result, stderr, payload, _ = self.restore_selection("long", [chosen], tree=tree)
        self.assertEqual((0, ""), (result, stderr))
        self.assertEqual("verified", payload["result"])

    def test_items_chosen_inside_a_source_are_looked_for_where_restic_puts_them(self) -> None:
        source = restore.windows_snapshot_path(self.source)
        tree = [
            {"struct_type": "node", "name": "Photos [2020]", "type": "dir", "path": source + "/Photos [2020]"},
            {
                "struct_type": "node",
                "name": "a.txt",
                "type": "file",
                "path": source + "/Photos [2020]/a.txt",
                "size": 7,
            },
        ]
        result, stderr, payload, target = self.restore_selection(
            "inside-source", ["/Photos [2020]"], "--source", str(self.source), tree=tree
        )
        self.assertEqual((0, ""), (result, stderr))
        self.assertEqual("verified", payload["result"])
        self.assertEqual(["Photos [2020]/a.txt"], self.restored_files(target))

    def test_an_include_must_be_one_snapshot_path(self) -> None:
        self.assertEqual(
            ["/C/Users/Photos [2020]", "/C"],
            restore.validate_includes(["/C/Users/Photos [2020]", "/C"]),
        )
        for value in (
            "C:\\Users\\you\\file.txt",
            "Users/you/file.txt",
            "/C/Users/*.docx",
            "/C/Users/file?.txt",
            "/",
            "/C//Users",
            "/C/Users/",
            "/C/./Users",
            "/C/../Users",
        ):
            with self.subTest(value=value):
                with self.assertRaisesRegex(
                    ValueError, "one item's path as Restic lists it, starting with / and with / between names,"
                ):
                    restore.validate_includes([value])
                # With --source the same rules hold, and the refusal says what the path is then relative to.
                with self.assertRaisesRegex(
                    ValueError, "one item's path inside the --source folder, starting with / and with / between names,"
                ):
                    restore.validate_includes([value], inside_source=True)
        # The refusal says only what is checked: a path inside the folder that --snapshot names has no
        # drive letter, so none is asked for.
        self.assertEqual(["/Users/you/file.txt"], restore.validate_includes(["/Users/you/file.txt"]))
        for inside_source in (False, True):
            with self.subTest(inside_source=inside_source):
                with self.assertRaises(ValueError) as refused:
                    restore.validate_includes(["Users/you/file.txt"], inside_source=inside_source)
                self.assertNotIn("drive letter", str(refused.exception))
                # The words the dashboard looks for to put the refusal plainly.
                self.assertTrue(str(refused.exception).startswith("an include must be one item's path"))
        dashboard = (SOURCE_ROOT / "dashboard" / "RestoreManager.cs").read_text(encoding="utf-8")
        self.assertIn('text.Contains("an include must be one item\'s path")', dashboard)
        with self.assertRaisesRegex(ValueError, r"as Restic lists it, .*for example /C/Users/you/Documents/report\.docx"):
            self.invoke(["--target", str(self.root / "refused"), "--include", "/C/Users/*.docx"])
        with self.assertRaisesRegex(ValueError, r"inside the --source folder, .*for example /Taxes/return\.pdf"):
            self.invoke(
                ["--target", str(self.root / "refused"), "--source", str(self.source), "--include", "C:\\x.txt"]
            )
        self.assertFalse(any("restore" in args for args in self.read_log()))

    def test_the_include_help_gives_the_path_with_and_without_a_source(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaises(SystemExit):
            restore.parse_args(["--help"])
        # argparse wraps the help where it likes, so the words are compared without their spacing.
        squeezed = "".join(output.getvalue().split())
        for expected in (
            "one item to restore, taken literally: its path as Restic lists it",
            "(for example /C/Users/you/Documents/report.docx)",
            "or with --source its path inside that source (for example /report.docx)",
        ):
            self.assertIn("".join(expected.split()), squeezed)

    def test_an_item_inside_the_folder_the_snapshot_selector_names_needs_no_drive_letter(self) -> None:
        result, stderr, payload, target = self.restore_selection(
            "selector-folder", ["/Photos [2020]"], "--snapshot", "latest:/C/Users"
        )
        self.assertEqual((0, ""), (result, stderr))
        self.assertEqual("verified", payload["result"])
        self.assertEqual(["Photos [2020]/a.txt"], self.restored_files(target))

    def test_without_a_report_an_item_is_refused_before_restic_is_started(self) -> None:
        # Run on its own, with no stored credential, Restic asks for the repository password; a wrong
        # item is refused before that, and before the configuration is read.
        target = self.root / "refused-early"
        with mock.patch.object(
            restore.subprocess, "Popen", side_effect=AssertionError("Restic was started")
        ), mock.patch.object(
            restore, "load_restore_config", side_effect=AssertionError("the configuration was read")
        ):
            for extra in ([], ["--source", str(self.source)]):
                with self.subTest(extra=extra), self.assertRaisesRegex(
                    ValueError, "^an include must be one item's path"
                ):
                    restore.main(
                        [
                            *self.base_arguments(recovery_key=False),
                            *extra,
                            "--target",
                            str(target),
                            "--include",
                            "C:\\Users\\you\\file.txt",
                        ]
                    )
        self.assertEqual([], self.read_log())
        self.assertFalse(target.exists())

    def test_with_a_report_an_item_is_refused_once_the_report_is_bound(self) -> None:
        # The protected manager accepts only a report bound to the snapshot, so the refusal waits for
        # that, and still comes before anything is restored.
        target = self.root / "refused-bound"
        report_path = self.state / "refused-bound-report.json"
        with self.assertRaisesRegex(ValueError, "^an include must be one item's path as Restic lists it"):
            self.invoke(
                [
                    "--snapshot",
                    "latest",
                    "--target",
                    str(target),
                    "--report",
                    str(report_path),
                    "--include",
                    "C:\\Users\\you\\file.txt",
                ]
            )
        payload = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(("error", False), (payload["result"], payload["verified"]))
        self.assertEqual((NEW_ID, REPOSITORY_ID), (payload["snapshot_id"], payload["repository_id"]))
        self.assertTrue(payload["error"].startswith("an include must be one item's path as Restic lists it"))
        self.assertFalse(any("restore" in args for args in self.read_log()))
        self.assertFalse(target.exists())


class ExtendedLengthPathTests(unittest.TestCase):
    """Chosen items are looked for through the \\\\?\\ prefix, which lifts the Windows path length limit.

    A restore test cannot pin this on a computer where long paths are switched on, so the helper is tested itself.
    """

    @unittest.skipUnless(os.name == "nt", "Windows paths")
    def test_a_drive_path_gets_the_prefix_and_a_prefixed_path_keeps_its_own(self) -> None:
        self.assertEqual("\\\\?\\C:\\Restored\\a [1].txt", restore._extended_length_path("C:\\Restored\\a [1].txt"))
        self.assertEqual("\\\\?\\C:\\Restored", restore._extended_length_path("\\\\?\\C:\\Restored"))

    @unittest.skipUnless(os.name == "nt", "Windows paths")
    def test_each_chosen_item_is_looked_for_through_the_prefix(self) -> None:
        looked_for: list[str] = []

        def lexists(path: str) -> bool:
            looked_for.append(path)
            return True

        with mock.patch.object(restore.os.path, "lexists", side_effect=lexists):
            missing = restore.missing_chosen_items(
                Path("C:\\Restored"),
                ["/C/Users/a [1].txt", "/kept/b.txt"],
                "C:\\Restored\\.rewindle-restore-0123456789abcdef",
                ["kept"],
            )
        self.assertEqual([], missing)
        self.assertEqual(
            [
                "\\\\?\\C:\\Restored\\C\\Users\\a [1].txt",
                "\\\\?\\C:\\Restored\\.rewindle-restore-0123456789abcdef\\kept\\b.txt",
            ],
            looked_for,
        )


FIND_TEXT_CASES = json.loads(
    (PROJECT_ROOT / "tests" / "fixtures" / "file-search-text-cases.json").read_text(encoding="utf-8")
)


def backup_id(index: int) -> str:
    return hashlib.sha256(f"backup-{index}".encode("ascii")).hexdigest()


def found(path: str, kind: str = "file", size: int = 7, mtime: str = "2026-07-01T10:00:00.1234567+02:00") -> dict:
    """One item as `restic find --json` prints it."""
    node: dict[str, object] = {"name": path.rsplit("/", 1)[-1], "type": kind, "path": path, "mtime": mtime}
    if kind == "file":
        node["size"] = size
    return node


class FileSearchTextTests(unittest.TestCase):
    def test_the_shared_text_cases(self) -> None:
        self.assertGreater(len(FIND_TEXT_CASES), 30)
        for case in FIND_TEXT_CASES:
            with self.subTest(text=case["text"]):
                if case["valid"]:
                    self.assertEqual("", restore.find_text_problem(case["text"]))
                    self.assertEqual(case["normalized"], restore.normalize_find_text(case["text"]))
                else:
                    self.assertEqual(case["error"], restore.find_text_problem(case["text"]))
                    with self.assertRaisesRegex(ValueError, "file search text is invalid"):
                        restore.normalize_find_text(case["text"])

    def test_the_pattern_starts_with_a_star_and_lets_brackets_match_themselves(self) -> None:
        for text, pattern in (
            ("Budget", "*Budget*"),
            ("-notes", "*-notes*"),
            ("--x", "*--x*"),
            ("[old]", "*?old?*"),
            ("Photos [2020]", "*Photos ?2020?*"),
            ("a]b[c", "*a?b?c*"),
        ):
            with self.subTest(text=text):
                self.assertEqual(pattern, restore.find_restic_pattern(text))
                # fnmatch reads "[" as Restic does: the name itself is matched only once the brackets are widened.
                self.assertTrue(fnmatch.fnmatchcase(f"x {text} y", pattern))

    def test_names_are_folded_one_character_at_a_time_as_restic_does(self) -> None:
        self.assertEqual("budget.xlsx", restore.find_fold("BUDGET.XLSX"))
        self.assertEqual("istanbul", restore.find_fold("\u0130stanbul"))
        self.assertEqual("\u03c3\u03c3", restore.find_fold("\u03a3\u03a3"))

    def test_times_are_kept_in_utc_to_a_ten_millionth_of_a_second(self) -> None:
        for value, expected in (
            ("2026-07-01T10:00:00.1234567+02:00", "2026-07-01T08:00:00.1234567Z"),
            ("2026-07-01T08:00:00.123456789Z", "2026-07-01T08:00:00.1234567Z"),
            ("2026-07-01T08:00:00Z", "2026-07-01T08:00:00.0000000Z"),
            ("2026-07-01T03:30:00.5-04:30", "2026-07-01T08:00:00.5000000Z"),
        ):
            with self.subTest(value=value):
                self.assertEqual(expected, restore.normalize_restic_time(value))
        for value in ("", "yesterday", "2026-07-01 08:00:00Z", "2026-07-01T08:00:00", "2026-13-01T08:00:00Z", None, 5):
            with self.subTest(value=value):
                self.assertIsNone(restore.normalize_restic_time(value))


class FileSearchTests(unittest.TestCase):
    """--find-json through restore.py and the fake Restic, in the same disposable folders as the restore tests."""

    tearDown = RestoreBackendTests.tearDown
    write_control = RestoreBackendTests.write_control
    base_arguments = RestoreBackendTests.base_arguments
    enable_plan = RestoreBackendTests.enable_plan
    invoke = RestoreBackendTests.invoke
    read_log = RestoreBackendTests.read_log
    bracket_tree = RestoreBackendTests.bracket_tree
    restore_selection = RestoreBackendTests.restore_selection
    restored_files = staticmethod(RestoreBackendTests.restored_files)

    def setUp(self) -> None:
        RestoreBackendTests.setUp(self)
        self.cache = self.state / "cache"
        self.cache.mkdir()
        self.snapshots: list[dict] = []

    def backups(self, count: int) -> list[str]:
        """Make `count` backups of the configured folder and return their IDs, newest first."""
        self.snapshots = [
            snapshot(backup_id(index), f"2026-07-{1 + index // 24:02d}T{index % 24:02d}:00:00Z", str(self.source))
            for index in range(count)
        ]
        self.write_control(snapshots=self.snapshots)
        return [backup_id(index) for index in reversed(range(count))]

    def time_of(self, snapshot_id: str) -> str:
        for item in self.snapshots:
            if item["id"] == snapshot_id:
                return restore.normalize_restic_time(item["time"])
        raise KeyError(snapshot_id)

    def write_found(self, **control: object) -> None:
        self.write_control(snapshots=self.snapshots, **control)

    def search(self, text: str = "Budget", *extra: str) -> tuple[int, dict | None, str]:
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(restore, "tie_children_to_this_process") as tie, redirect_stdout(
            stdout
        ), redirect_stderr(stderr):
            result = restore.main(
                [
                    *self.base_arguments(),
                    "--cache-dir",
                    str(self.cache),
                    "--no-restic-lock",
                    "--find-json",
                    f"--find-text={text}",
                    *extra,
                ]
            )
        self.assertTrue(tie.called)
        return result, json.loads(stdout.getvalue()) if result == 0 else None, stderr.getvalue()

    def find_calls(self) -> list[list[str]]:
        return [args for args in self.read_log() if "find" in args]

    @staticmethod
    def batch(args: list[str]) -> list[str]:
        return [args[index + 1] for index, value in enumerate(args) if value == "--snapshot"]

    def test_backups_are_searched_newest_first_in_batches_that_grow(self) -> None:
        ids = self.backups(14)
        self.write_found(find_nodes={ids[5]: [found("/C/Docs/Budget.xlsx")]})
        result, payload, stderr = self.search()
        self.assertEqual((0, ""), (result, stderr))
        calls = self.find_calls()
        self.assertEqual([ids[0:1], ids[1:3], ids[3:7], ids[7:14]], [self.batch(call) for call in calls])
        for call in calls:
            start = call.index("find")
            self.assertEqual(["find", "--json", "--ignore-case", "--snapshot"], call[start : start + 4])
            self.assertEqual(["--", "*Budget*"], call[-2:])
        for call in self.read_log():
            # Only reads, through the backup's cache, without Restic's lock: the manager holds the run lock.
            self.assertIn("--no-lock", call)
            self.assertEqual(str(self.cache), call[call.index("--cache-dir") + 1])
        self.assertEqual(1, sum("snapshots" in call for call in self.read_log()))
        self.assertEqual(restore.FIND_SCHEMA, payload["schema"])
        self.assertEqual(1, payload["schema_version"])
        self.assertEqual(str(self.repository.resolve()), payload["repository"])
        self.assertNotIn("repository_id", payload)
        self.assertEqual({"text": "Budget", "from_snapshot_id": None}, payload["query"])
        self.assertEqual(
            {"plan_id": None, "legacy_match_policy": "exact-host-scheduled-tags-and-sources"}, payload["binding"]
        )
        self.assertEqual(
            ("complete", 14, 14, None, 1, 0),
            (
                payload["status"],
                payload["snapshots_total"],
                payload["snapshots_searched"],
                payload["next_from_snapshot_id"],
                payload["matches_total"],
                payload["skipped"],
            ),
        )
        self.assertEqual(self.time_of(ids[0]), payload["searched_newest_time"])
        self.assertEqual(self.time_of(ids[13]), payload["searched_oldest_time"])
        self.assertIsInstance(payload["elapsed_ms"], int)
        self.assertEqual(ids[5], payload["matches"][0]["versions"][0]["snapshot_id"])

    def test_only_names_that_hold_the_text_are_kept_and_each_version_once(self) -> None:
        ids = self.backups(4)
        self.write_found(
            find_nodes={
                ids[0]: [
                    found("/C/Docs/Budget.xlsx", size=10, mtime="2026-07-03T10:00:00.1234567+02:00"),
                    found("/C/Docs/Budgets", "dir"),
                    # Inside a folder whose name holds the text; Restic prints these too.
                    found("/C/Docs/Budgets/notes.txt"),
                    {"name": "budget.lnk", "type": "symlink", "path": "/C/Docs/budget.lnk"},
                    found("C:\\Docs\\budget.txt"),
                    found("/C/Docs/../budget.txt"),
                    found("/C/Docs//budget.txt"),
                ],
                # The same file at the same moment, written with another offset: the same version.
                ids[1]: [
                    found("/C/Docs/Budget.xlsx", size=10, mtime="2026-07-03T08:00:00.1234567Z"),
                    found("/C/Docs/Budgets", "dir"),
                ],
                ids[2]: [found("/C/Docs/Budget.xlsx", size=9, mtime="2026-07-02T08:00:00Z")],
            }
        )
        result, payload, _ = self.search("budget")
        self.assertEqual(0, result)
        self.assertEqual(("complete", 2, 5), (payload["status"], payload["matches_total"], payload["skipped"]))
        file_match, folder_match = payload["matches"]
        self.assertEqual(
            ("/C/Docs/Budget.xlsx", "Budget.xlsx", "file", 2),
            (file_match["path"], file_match["name"], file_match["type"], file_match["versions_total"]),
        )
        newer, older = file_match["versions"]
        self.assertEqual(
            {
                "size": 10,
                "mtime": "2026-07-03T08:00:00.1234567Z",
                "snapshot_id": ids[0],
                "snapshot_time": self.time_of(ids[0]),
                "first_snapshot_id": ids[1],
                "first_snapshot_time": self.time_of(ids[1]),
                "backups": 2,
                "binding_state": "configuration",
            },
            newer,
        )
        self.assertEqual((9, ids[2], ids[2], 1), (older["size"], older["snapshot_id"], older["first_snapshot_id"], older["backups"]))
        self.assertEqual(("/C/Docs/Budgets", "dir", 1), (folder_match["path"], folder_match["type"], folder_match["versions_total"]))
        self.assertEqual(
            (0, None, ids[0], ids[1], 2),
            tuple(folder_match["versions"][0][key] for key in ("size", "mtime", "snapshot_id", "first_snapshot_id", "backups")),
        )

    def test_a_path_keeps_its_ten_newest_versions_and_says_how_many_there_are(self) -> None:
        ids = self.backups(12)
        self.write_found(
            find_nodes={snapshot_id: [found("/C/Docs/Budget.xlsx", size=index)] for index, snapshot_id in enumerate(ids)}
        )
        result, payload, _ = self.search()
        self.assertEqual(0, result)
        match = payload["matches"][0]
        self.assertEqual(12, match["versions_total"])
        self.assertEqual(ids[:10], [version["snapshot_id"] for version in match["versions"]])

    def test_text_that_starts_with_a_dash_reaches_restic_as_a_pattern(self) -> None:
        ids = self.backups(1)
        for text in ("-notes", "--x", "-rf"):
            with self.subTest(text=text):
                self.fake_log.unlink(missing_ok=True)
                result, payload, _ = self.search(text)
                self.assertEqual((0, text), (result, payload["query"]["text"]))
                call = self.find_calls()[0]
                self.assertEqual(["--snapshot", ids[0], "--", f"*{text}*"], call[-4:])

    def test_the_time_running_out_stops_a_batch_and_says_where_to_go_on(self) -> None:
        ids = self.backups(6)
        self.write_found(
            find_nodes={ids[0]: [found("/C/Docs/Budget.xlsx")], ids[4]: [found("/C/Old/Budget.xlsx")]},
            find_sleep={ids[1]: 30},
        )
        started = time.monotonic()
        with mock.patch.object(restore, "FIND_SECONDS_MIN", 1):
            result, payload, _ = self.search("Budget", "--find-seconds=3")
        self.assertLess(time.monotonic() - started, 6)
        self.assertEqual(0, result)
        # The batch the deadline cut is not counted: Restic prints nothing for a backup without matches.
        self.assertEqual(
            ("more", 6, 1, ids[1], ["/C/Docs/Budget.xlsx"]),
            (
                payload["status"],
                payload["snapshots_total"],
                payload["snapshots_searched"],
                payload["next_from_snapshot_id"],
                [match["path"] for match in payload["matches"]],
            ),
        )
        self.assertEqual(self.time_of(ids[0]), payload["searched_oldest_time"])
        self.fake_log.unlink()
        self.write_found(find_nodes={ids[4]: [found("/C/Old/Budget.xlsx")]})
        result, payload, _ = self.search("Budget", f"--find-from-snapshot={ids[1]}")
        self.assertEqual(0, result)
        self.assertEqual({"text": "Budget", "from_snapshot_id": ids[1]}, payload["query"])
        self.assertEqual([ids[1:2], ids[2:4], ids[4:6]], [self.batch(call) for call in self.find_calls()])
        self.assertEqual(
            ("complete", 5, None, self.time_of(ids[1]), self.time_of(ids[5])),
            (
                payload["status"],
                payload["snapshots_searched"],
                payload["next_from_snapshot_id"],
                payload["searched_newest_time"],
                payload["searched_oldest_time"],
            ),
        )
        self.assertEqual(["/C/Old/Budget.xlsx"], [match["path"] for match in payload["matches"]])

    def test_one_backup_that_cannot_be_searched_in_time_is_too_slow(self) -> None:
        ids = self.backups(3)
        self.write_found(find_sleep={ids[0]: 30})
        with mock.patch.object(restore, "FIND_SECONDS_MIN", 1):
            result, payload, _ = self.search("Budget", "--find-seconds=2")
        self.assertEqual(0, result)
        self.assertEqual(
            ("too_slow", 0, ids[0]),
            (payload["status"], payload["snapshots_searched"], payload["next_from_snapshot_id"]),
        )

    def test_a_slow_list_of_backups_still_leaves_the_newest_backup_searched(self) -> None:
        # The list took more than half of the time. The newest backup is still searched with what is left, so a location
        # that is always slow to list still gets further with each page instead of repeating the same empty one.
        ids = self.backups(3)
        self.write_found(snapshots_sleep=3.5, find_nodes={ids[0]: [found("/C/Docs/Budget.xlsx")]})
        with mock.patch.object(restore, "FIND_SECONDS_MIN", 1):
            result, payload, _ = self.search("Budget", "--find-seconds=6")
        self.assertEqual(0, result)
        calls = self.find_calls()
        self.assertTrue(calls, "the newest backup was not searched after a slow list")
        self.assertEqual(ids[0:1], self.batch(calls[0]))
        self.assertIn(payload["status"], ("more", "complete"))
        self.assertGreaterEqual(payload["snapshots_searched"], 1)
        self.assertEqual(["/C/Docs/Budget.xlsx"], [match["path"] for match in payload["matches"]])
        if payload["status"] == "more":
            self.assertEqual(ids[payload["snapshots_searched"]], payload["next_from_snapshot_id"])

    def test_a_slow_list_and_a_backup_that_does_not_fit_after_it_are_too_slow(self) -> None:
        # Nothing could be searched in this page's time: too_slow (Try again, or choose by date), never "more" with nothing
        # searched, which would offer to go on and then repeat the same work.
        ids = self.backups(3)
        self.write_found(snapshots_sleep=2, find_sleep={ids[0]: 30})
        with mock.patch.object(restore, "FIND_SECONDS_MIN", 1):
            result, payload, _ = self.search("Budget", "--find-seconds=3")
        self.assertEqual(0, result)
        self.assertEqual(
            ("too_slow", 3, 0, ids[0]),
            (
                payload["status"],
                payload["snapshots_total"],
                payload["snapshots_searched"],
                payload["next_from_snapshot_id"],
            ),
        )
        self.assertEqual([ids[0:1]], [self.batch(call) for call in self.find_calls()])

    def test_a_list_of_backups_cut_by_the_time_is_too_slow(self) -> None:
        ids = self.backups(3)
        self.write_found(snapshots_sleep=30)
        with mock.patch.object(restore, "FIND_SECONDS_MIN", 1):
            result, payload, _ = self.search("Budget", "--find-seconds=1", f"--find-from-snapshot={ids[1]}")
            self.assertEqual(0, result)
            # The same start again: Try again repeats this page, and the list on screen still offers choosing by date.
            self.assertEqual(
                ("too_slow", 0, 0, ids[1], []),
                (
                    payload["status"],
                    payload["snapshots_total"],
                    payload["snapshots_searched"],
                    payload["next_from_snapshot_id"],
                    payload["matches"],
                ),
            )
            with self.assertRaisesRegex(RuntimeError, "list of backups could not be read in the time"):
                self.search("Budget", "--find-seconds=1")
        self.assertEqual([], self.find_calls())

    def test_a_name_that_matches_too_much_asks_for_more_of_it(self) -> None:
        ids = self.backups(3)
        self.write_found(find_flood=60)
        with mock.patch.object(restore, "FIND_MAX_BATCH_NODES", 50):
            result, payload, _ = self.search()
        self.assertEqual(
            (0, "too_broad", 0, ids[0], []),
            (result, payload["status"], payload["snapshots_searched"], payload["next_from_snapshot_id"], payload["matches"]),
        )
        with mock.patch.object(restore, "FIND_MAX_BATCH_BYTES", 4096):
            result, payload, _ = self.search()
        self.assertEqual((0, "too_broad", 0), (result, payload["status"], payload["snapshots_searched"]))

    def test_more_than_a_hundred_paths_stops_with_the_first_hundred(self) -> None:
        ids = self.backups(3)
        self.write_found(find_flood=101)
        result, payload, _ = self.search()
        self.assertEqual(0, result)
        self.assertEqual(
            ("too_many", 1, ids[1], 101, 100),
            (
                payload["status"],
                payload["snapshots_searched"],
                payload["next_from_snapshot_id"],
                payload["matches_total"],
                len(payload["matches"]),
            ),
        )

    def test_a_start_that_is_no_longer_listed_exits_with_its_own_code(self) -> None:
        self.backups(3)
        result, payload, stderr = self.search("Budget", f"--find-from-snapshot={backup_id(99)}")
        self.assertEqual((restore.FIND_EXIT_START_MISSING, None), (result, payload))
        self.assertIn("the backup to search from is no longer in the list", stderr)
        self.assertEqual([], self.find_calls())

    def test_restic_failing_or_printing_anything_unexpected_is_not_used(self) -> None:
        ids = self.backups(2)
        self.write_found(find_exit=1)
        with self.assertRaisesRegex(restore.ResticReadError, "file search failed with exit code 1"):
            self.search()
        one = {"matches": [found("/C/Docs/Budget.xlsx")], "hits": 1, "snapshot": ids[0]}
        for raw in (
            "not json",
            json.dumps(one),
            json.dumps([{**one, "hits": 2}]),
            json.dumps([{**one, "hits": True}]),
            json.dumps([{**one, "extra": 1}]),
            json.dumps([{**one, "snapshot": backup_id(99)}]),
            json.dumps([{**one, "snapshot": ids[0].upper()}]),
            json.dumps([one, one]),
            json.dumps([{"matches": "x", "hits": 1, "snapshot": ids[0]}]),
            "null",
        ):
            with self.subTest(raw=raw):
                self.write_found(find_raw=raw)
                with self.assertRaisesRegex(ValueError, restore.FIND_INVALID_OUTPUT):
                    self.search()

    def test_the_options_of_a_search_are_checked_before_restic_runs(self) -> None:
        self.backups(2)
        refused = (
            (["--find-json"], "needs --find-text"),
            (["--find-text=Budget"], "require --find-json"),
            (["--find-seconds=20"], "require --find-json"),
            (["--find-json", "--find-text= Budget"], "needs --find-text"),
            (["--find-json", "--find-text=a"], "file search text is invalid"),
            (["--find-json", "--find-text=Docs/Budget"], "file search text is invalid"),
            (["--find-json", "--find-text=Budget", "--find-from-snapshot=" + "A" * 64], "full backup ID"),
            (["--find-json", "--find-text=Budget", "--find-from-snapshot=abc"], "full backup ID"),
            (["--find-json", "--find-text=Budget", "--find-seconds=4"], "from 5 to 60"),
            (["--find-json", "--find-text=Budget", "--find-seconds=61"], "from 5 to 60"),
            (["--find-json", "--find-text=Budget", "--list-snapshots-json"], "choose only one"),
            (["--find-json", "--find-text=Budget", "--list-tree-json"], "choose only one"),
            (["--find-json", "--find-text=Budget", "--target", str(self.root / "t")], "choose only one"),
            (["--find-json", "--find-text=Budget", "--include", "/C/Docs"], "takes only its text"),
            (["--find-json", "--find-text=Budget", "--tree-path", "/C"], "takes only its text"),
            (["--find-json", "--find-text=Budget", "--snapshot", backup_id(0)], "takes only its text"),
            (["--find-json", "--find-text=Budget", "--allow-legacy-unbound"], "takes only its text"),
        )
        for arguments, message in refused:
            with self.subTest(arguments=arguments), self.assertRaisesRegex(ValueError, message):
                self.invoke(arguments)
        with self.assertRaisesRegex(ValueError, "needs the protected password helper or a recovery key"):
            restore.main([*self.base_arguments(recovery_key=False), "--find-json", "--find-text=Budget"])
        self.assertEqual([], self.read_log())

    def test_versions_say_which_backups_belong_to_the_plan(self) -> None:
        self.enable_plan(generation=2)
        current = snapshot(
            NEW_ID,
            "2026-07-21T01:00:00Z",
            str(self.source),
            tags=["scheduled", restore.plan_tag(PLAN_ID), restore.generation_tag(2)],
        )
        legacy = snapshot(LEGACY_ID, "2026-07-20T01:00:00Z", str(self.source))
        other_host = snapshot(WRONG_HOST_ID, "2026-07-22T01:00:00Z", str(self.source), hostname="OTHER-HOST")
        self.snapshots = [legacy, current, other_host]
        self.write_found(
            find_nodes={
                NEW_ID: [found("/C/Docs/Budget.xlsx")],
                LEGACY_ID: [found("/C/Docs/Budget.xlsx"), found("/C/Docs/Budget-old.xlsx")],
                WRONG_HOST_ID: [found("/C/Docs/Budget-other.xlsx")],
            }
        )
        result, payload, _ = self.search()
        self.assertEqual(0, result)
        self.assertEqual(PLAN_ID, payload["binding"]["plan_id"])
        self.assertEqual(2, payload["snapshots_total"])
        self.assertEqual([[NEW_ID], [LEGACY_ID]], [self.batch(call) for call in self.find_calls()])
        versions = {match["path"]: match["versions"] for match in payload["matches"]}
        self.assertEqual({"/C/Docs/Budget.xlsx", "/C/Docs/Budget-old.xlsx"}, set(versions))
        self.assertEqual(
            [("plan", NEW_ID, LEGACY_ID, 2)],
            [(v["binding_state"], v["snapshot_id"], v["first_snapshot_id"], v["backups"]) for v in versions["/C/Docs/Budget.xlsx"]],
        )
        self.assertEqual("legacy_unbound", versions["/C/Docs/Budget-old.xlsx"][0]["binding_state"])

    def test_restic_sees_only_an_allow_listed_environment_while_searching(self) -> None:
        self.backups(2)
        planted = {
            "RESTIC_PASSWORD_COMMAND": r"C:\planted\evil.cmd",
            "RESTIC_REPOSITORY_FILE": r"C:\planted\repository.txt",
            "RCLONE_CONFIG_PLANTED_TYPE": "sftp",
            "PYTHONPATH": r"C:\planted",
        }
        with mock.patch.dict(os.environ, planted):
            result, _, stderr = self.search()
        self.assertEqual(0, result, stderr)
        calls = [json.loads(line) for line in self.fake_log.read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any("find" in call["args"] for call in calls))
        for call in calls:
            names = set(call["environment"])
            self.assertFalse(names & set(planted), call["args"])
            self.assertIn("RESTIC_PASSWORD", names)

    def test_a_found_name_with_square_brackets_restores_as_itself(self) -> None:
        self.write_control(
            tree=self.bracket_tree(),
            find_nodes={
                NEW_ID: [
                    found("/C/Users/Photos [2020]", "dir"),
                    found("/C/Users/Photos [2020]/a.txt"),
                    # What the widened pattern also matches.
                    found("/C/Users/Photos x2020y", "dir"),
                ]
            },
        )
        result, payload, _ = self.search("[2020]")
        self.assertEqual(0, result)
        self.assertEqual(["--", "*?2020?*"], self.find_calls()[0][-2:])
        self.assertEqual(["/C/Users/Photos [2020]"], [match["path"] for match in payload["matches"]])
        result, stderr, report, target = self.restore_selection("found", [payload["matches"][0]["path"]])
        self.assertEqual((0, ""), (result, stderr))
        self.assertEqual("verified", report["result"])
        self.assertEqual(["C/Users/Photos [2020]/a.txt"], self.restored_files(target))

    def run_search_process(self, *extra: str) -> subprocess.Popen:
        return subprocess.Popen(
            [
                sys.executable,
                "-I",
                str(SOURCE_ROOT / "restore.py"),
                *self.base_arguments(),
                "--find-json",
                "--find-text=Budget",
                *extra,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )

    def test_the_time_budget_holds_for_the_whole_process(self) -> None:
        ids = self.backups(6)
        self.write_found(find_sleep={ids[1]: 60})
        started = time.monotonic()
        process = self.run_search_process("--find-seconds=5")
        stdout, stderr = process.communicate(timeout=30)
        self.assertLess(time.monotonic() - started, 7.5)
        self.assertEqual(0, process.returncode, stderr)
        payload = json.loads(stdout)
        self.assertEqual(("more", 1, ids[1]), (payload["status"], payload["snapshots_searched"], payload["next_from_snapshot_id"]))
        self.assertLess(payload["elapsed_ms"], 6000)

    @unittest.skipUnless(os.name == "nt", "Windows job objects")
    def test_stopping_the_search_also_stops_restic(self) -> None:
        ids = self.backups(2)
        pid_file = self.root / "find.pid"
        self.write_found(find_sleep={ids[0]: 120}, pid_file=str(pid_file))
        process = self.run_search_process("--find-seconds=60")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        try:
            deadline = time.monotonic() + 20
            while not (pid_file.is_file() and pid_file.read_text(encoding="utf-8")):
                self.assertIsNone(process.poll(), process.stderr.read() if process.poll() is not None else "")
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            handle = kernel32.OpenProcess(0x00100000, False, int(pid_file.read_text(encoding="utf-8")))  # SYNCHRONIZE
            self.assertTrue(handle)
            try:
                # As the manager does when a search outlasts its own limit.
                process.kill()
                process.wait(timeout=10)
                self.assertEqual(0, kernel32.WaitForSingleObject(handle, 10_000))
            finally:
                kernel32.CloseHandle(handle)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=10)


class ResticLiteralPatternTests(unittest.TestCase):
    """The include pattern for a chosen path, checked with fnmatch, which reads "[" as Restic does."""

    def test_each_opening_bracket_becomes_a_class_that_holds_only_itself(self) -> None:
        cases = (
            ("/C/Users/Photos [2020]", "/C/Users/Photos [[]2020]"),
            ("/C/[draft] notes.txt", "/C/[[]draft] notes.txt"),
            ("/C/a]b.txt", "/C/a]b.txt"),
            ("/C/x[1][2]/[[y]].txt", "/C/x[[]1][[]2]/[[][[]y]].txt"),
            ("/C/Users/plain report (2).txt", "/C/Users/plain report (2).txt"),
        )
        for chosen, expected in cases:
            with self.subTest(chosen=chosen):
                self.assertEqual(expected, restore.restic_literal_pattern(chosen))

    def test_the_pattern_matches_the_chosen_name_and_no_other(self) -> None:
        for name, other in (
            ("Photos [2020]", "Photos 2"),
            ("[draft] notes.txt", "d notes.txt"),
            ("Notes[1].txt", "Notes1.txt"),
            ("a]b.txt", "ab.txt"),
            ("x[1][2]", "x12"),
        ):
            with self.subTest(name=name):
                pattern = restore.restic_literal_pattern(name)
                self.assertTrue(fnmatch.fnmatchcase(name, pattern))
                self.assertFalse(fnmatch.fnmatchcase(other, pattern))
                if "[" in name:
                    # Unescaped, the name is a pattern for another name and never for itself.
                    self.assertFalse(fnmatch.fnmatchcase(name, name))
                    self.assertTrue(fnmatch.fnmatchcase(other, name))


def pinned_restic_present() -> bool:
    if not RESTIC.is_file():
        return False
    release = json.loads((SOURCE_ROOT / "restic-release.json").read_text(encoding="utf-8"))
    return hashlib.sha256(RESTIC.read_bytes()).hexdigest() == release["executable_sha256"]


@unittest.skipUnless(
    os.name == "nt" and pinned_restic_present(),
    "needs the release build's pinned restic.exe (run build\\Build-Release.ps1)",
)
class PinnedResticRestoreTests(unittest.TestCase):
    """Chosen items through restore.py and the pinned Restic, in a throwaway backup."""

    def test_names_with_square_brackets_come_back_and_nothing_else(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rewindle-brackets-") as root_text:
            root = Path(root_text)
            source = root / "source"
            for relative in ("Photos [2020]/a.txt", "Photos 2/decoy.txt", "Notes[1].txt", "Notes1.txt", "plain.txt"):
                path = source / Path(relative)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n", encoding="ascii")
            password = "pinned-restic-restore-test-only-" + "x" * 40
            key = root / "recovery-key.txt"
            key.write_text(f"Password: {password}\n", encoding="ascii")
            repository = root / "repository"
            # Only what Restic needs: no inherited RESTIC_* settings can point it at any other backup.
            environment = {
                name: os.environ[name] for name in ("SYSTEMROOT", "TEMP", "TMP") if name in os.environ
            }
            environment["RESTIC_PASSWORD"] = password
            common = [str(RESTIC), "--repo", str(repository), "--no-cache"]
            for arguments in (["init"], ["backup", str(source), "--host", "TESTHOST", "--tag", "scheduled"]):
                finished = subprocess.run(
                    [*common, *arguments],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=120,
                    env=environment,
                )
                self.assertEqual(0, finished.returncode, finished.stderr)
            state = root / "state"
            state.mkdir()
            cache = root / "cache"
            cache.mkdir()
            config_path = root / "backup-config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "repository": str(repository),
                        "repository_volume_serial": "00000000",
                        "restic_executable": str(RESTIC),
                        "state_directory": str(state),
                        "recovery_key_file": str(key),
                        "hostname": "TESTHOST",
                        "scheduled_tag": "scheduled",
                        "sources": [str(source)],
                    }
                ),
                encoding="utf-8",
            )
            quiet_call = subprocess.call

            def restore_selection(label: str, chosen: list[str]) -> tuple[int, dict, list[str]]:
                target = root / label
                report = state / f"{label}.json"
                # Restored relative to the source, as --source does, so no folder above it (with the
                # permissions of the profile folders) is recreated in the target.
                arguments = [
                    "--config", str(config_path),
                    "--repository", str(repository),
                    "--restic", str(RESTIC),
                    "--recovery-key-file", str(key),
                    "--cache-dir", str(cache),
                    "--snapshot", "latest",
                    "--source", str(source),
                    "--target", str(target),
                    "--report", str(report),
                ]
                for item in chosen:
                    arguments.extend(["--include", item])
                inherited = {
                    name: value for name, value in os.environ.items() if not name.upper().startswith("RESTIC_")
                }
                with mock.patch.dict(os.environ, inherited, clear=True), mock.patch.object(
                    restore, "ensure_local_volume"
                ), mock.patch.object(
                    restore.subprocess,
                    "call",
                    side_effect=lambda command, **options: quiet_call(
                        command, **{**options, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
                    ),
                ), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    result = restore.main(arguments)
                files = sorted(item.relative_to(target).as_posix() for item in target.rglob("*") if item.is_file())
                return result, json.loads(report.read_text(encoding="utf-8")), files

            result, payload, files = restore_selection("escaped", ["/Photos [2020]", "/Notes[1].txt"])
            self.assertEqual(0, result, payload)
            self.assertEqual(("verified", True), (payload["result"], payload["verified"]))
            self.assertEqual(["Notes[1].txt", "Photos [2020]/a.txt"], files)

            # Without the escaping, Restic reads "[2020]" as one of "2" or "0": it brings back "Photos 2"
            # instead and exits 0, and only the check for the chosen item stops this counting as done.
            with mock.patch.object(restore, "restic_literal_pattern", side_effect=lambda path: path):
                result, payload, files = restore_selection("unescaped", ["/Photos [2020]"])
            self.assertEqual(["Photos 2/decoy.txt"], files)
            self.assertEqual((1, 0), (result, payload["restic_exit_code"]))
            self.assertEqual(("partial", False), (payload["result"], payload["verified"]))
            self.assertIn("without restoring every chosen item (1 of 1 missing)", payload["error"])

    def test_find_looks_through_every_backup_by_name(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rewindle-find-") as root_text:
            root = Path(root_text)
            source = root / "source"
            for relative in ("Budget 2026.xlsx", "Budgets/notes.txt", "Photos [2020]/a.txt", "Photos x2020y/b.txt"):
                path = source / Path(relative)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture\n")
            password = "pinned-restic-find-test-only-" + "x" * 40
            key = root / "recovery-key.txt"
            key.write_text(f"Password: {password}\n", encoding="ascii")
            repository = root / "repository"
            environment = {
                name: os.environ[name] for name in ("SYSTEMROOT", "TEMP", "TMP") if name in os.environ
            }
            environment["RESTIC_PASSWORD"] = password
            common = [str(RESTIC), "--repo", str(repository), "--no-cache"]
            backup = ["backup", str(source), "--host", "TESTHOST", "--tag", "scheduled"]
            for arguments in (["init"], backup, None, backup):
                if arguments is None:
                    # A new version of the file between the two backups.
                    (source / "Budget 2026.xlsx").write_bytes(b"fixture, changed\n")
                    continue
                finished = subprocess.run(
                    [*common, *arguments],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=120,
                    env=environment,
                )
                self.assertEqual(0, finished.returncode, finished.stderr)
            cache = root / "cache"
            cache.mkdir()
            config_path = root / "backup-config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "repository": str(repository),
                        "repository_volume_serial": "00000000",
                        "restic_executable": str(RESTIC),
                        "state_directory": str(root / "state"),
                        "recovery_key_file": str(key),
                        "hostname": "TESTHOST",
                        "scheduled_tag": "scheduled",
                        "sources": [str(source)],
                    }
                ),
                encoding="utf-8",
            )

            def search(text: str) -> dict:
                stdout = io.StringIO()
                inherited = {
                    name: value for name, value in os.environ.items() if not name.upper().startswith("RESTIC_")
                }
                with mock.patch.dict(os.environ, inherited, clear=True), mock.patch.object(
                    restore, "tie_children_to_this_process"
                ), redirect_stdout(stdout), redirect_stderr(io.StringIO()):
                    result = restore.main(
                        [
                            "--config", str(config_path),
                            "--repository", str(repository),
                            "--restic", str(RESTIC),
                            "--recovery-key-file", str(key),
                            "--cache-dir", str(cache),
                            "--no-restic-lock",
                            "--find-json",
                            f"--find-text={text}",
                            "--find-seconds=60",
                        ]
                    )
                self.assertEqual(0, result)
                return json.loads(stdout.getvalue())

            payload = search("budget")
            self.assertEqual(("complete", 2, 2), (payload["status"], payload["snapshots_total"], payload["snapshots_searched"]))
            matches = {match["name"]: match for match in payload["matches"]}
            self.assertEqual({"Budget 2026.xlsx", "Budgets"}, set(matches))
            self.assertEqual("dir", matches["Budgets"]["type"])
            self.assertEqual(2, matches["Budgets"]["versions"][0]["backups"])
            versions = matches["Budget 2026.xlsx"]["versions"]
            self.assertEqual([17, 8], [version["size"] for version in versions])
            for version in versions:
                self.assertRegex(version["mtime"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$")
            # "notes.txt" in the matching folder, in each backup.
            self.assertEqual(2, payload["skipped"])

            payload = search("[2020]")
            self.assertEqual(["Photos [2020]"], [match["name"] for match in payload["matches"]])
            self.assertTrue(payload["matches"][0]["path"].endswith("/source/Photos [2020]"))

            # The recovery guide's own command (src/RECOVERY.md, "Finding a file") prints what the guide says: a line for each
            # backup with a match, then one line for each match that ends with its size in bytes, the date and time it last
            # changed, and its path inside the backup.
            guide = (SOURCE_ROOT / "RECOVERY.md").read_text(encoding="utf-8")
            section = guide[guide.index("## Finding a file") :]
            documented = re.search(r"^\.\\restic\.exe --repo '[^']+' (find .+)$", section, re.MULTILINE)
            self.assertIsNotNone(documented)
            arguments = [part.strip("'") for part in documented.group(1).split()]
            finished = subprocess.run(
                [*common, *arguments],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=120,
                env=environment,
            )
            self.assertEqual(0, finished.returncode, finished.stderr)
            lines = [line for line in finished.stdout.splitlines() if line.strip()]
            headers = [line for line in lines if line.startswith("Found matching entries in snapshot ")]
            self.assertEqual(2, len(headers), finished.stdout)
            sizes = []
            for line in lines:
                if line in headers:
                    continue
                listed = re.fullmatch(r"\S+\s+\d+\s+\d+\s+(\d+) \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} (/\S.*)", line)
                self.assertIsNotNone(listed, f"the guide's find command did not print a size and a date: {line!r}")
                if listed.group(2).endswith("/source/Budget 2026.xlsx"):
                    sizes.append(int(listed.group(1)))
            self.assertEqual([8, 17], sorted(sizes))


if __name__ == "__main__":
    unittest.main()
