from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import ctypes
from ctypes import wintypes
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
import unittest
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = PROJECT_ROOT / "src"
sys.path.insert(0, str(SOURCE_ROOT))

import restore


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

if "cat" in args:
    print(json.dumps({"id": control["repository_id"], "version": 2}))
    raise SystemExit(0)
if "snapshots" in args:
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


def dacl_entries(path: Path) -> list[tuple[str, ...]]:
    """The access entries of a file or folder as Windows stores them, without the inherited marks."""

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
        entries.append(tuple(parts))
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
                r"C:\\Users\\you\\file.txt",
                "--report",
                str(report),
            ]
        )
        self.assertEqual(result, 0)
        self.assertEqual(stderr, "")
        self.assertTrue((target / "restored.txt").is_file())
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
        """The owner, DACL flags and entries of the folder Restic was given, as the fake Restic read them."""

        text = self.fake_log.with_suffix(".target-security.txt").read_text(encoding="utf-8")
        match = re.fullmatch(r"O:(.+?)D:([A-Z]*)((?:\([^)]*\))*)", text)
        self.assertIsNotNone(match, text)
        owner, flags, entries = match.groups()
        return owner, flags, {tuple(entry.split(";")) for entry in re.findall(r"\(([^)]*)\)", entries)}

    def assert_restore_folder_security(self, elevated: bool, *, check_owner: bool) -> None:
        owner, flags, entries = self.restore_folder_security()
        # Protected: nothing is inherited from the folder the user chose.
        self.assertIn("P", flags)
        expected = {("A", "OICI", "FA", "", "", "SY"), ("A", "OICI", "FA", "", "", "BA")}
        if not elevated:
            expected.add(("A", "OICI", "FA", "", "", restore.current_user_sid()))
        self.assertEqual(expected, entries)
        if check_owner and elevated:
            self.assertEqual("BA", owner)

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
        # Until a restored folder's own permissions are written it keeps those of the restore folder, so nothing can be
        # moved into it from outside while its contents are handed back.
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


if __name__ == "__main__":
    unittest.main()
