"""Every Restic child of the engine gets an allow-listed environment.

An elevated helper's own environment is built from the user's profile, so the
user can plant RESTIC_* and RCLONE_* settings there. These tests plant them in
this process and check that no Restic launch passes them on.
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
TESTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(TESTS))

import credential_repair  # noqa: E402
import key_rotation  # noqa: E402
import recovery_health  # noqa: E402
import stale_lock_repair  # noqa: E402
from restic_common import (  # noqa: E402
    CANCEL_ENVIRONMENT_NAMES,
    restic_child_environment,
    run_capture,
    stream_command,
    windows_directory,
)
import test_credential_repair  # noqa: E402
import test_recovery_health  # noqa: E402
import test_stale_lock_repair  # noqa: E402


PLANTED = {
    "RESTIC_PASSWORD_COMMAND": r"C:\planted\evil.cmd",
    "RESTIC_PASSWORD_FILE": r"C:\planted\password.txt",
    "RESTIC_REPOSITORY": r"C:\planted\repository",
    "RESTIC_REPOSITORY_FILE": r"C:\planted\repository.txt",
    "RESTIC_CACHE_DIR": r"C:\planted\cache",
    "RESTIC_PACK_SIZE": "bogus",
    "RESTIC_COMPRESSION": "bogus",
    "RCLONE_CONFIG_PLANTED_TYPE": "sftp",
    "RCLONE_CONFIG_PLANTED_SSH": r"C:\planted\evil.cmd",
    "RCLONE_LOG_FILE": r"C:\planted\rclone.log",
    "GODEBUG": "planted=1",
    "HTTPS_PROXY": "http://planted.invalid:8080",
    "COR_ENABLE_PROFILING": "1",
    "COR_PROFILER": "{00000000-0000-0000-0000-000000000000}",
    "PYTHONPATH": r"C:\planted",
    "LOCALAPPDATA": r"C:\planted\AppData\Local",
    "USERPROFILE": r"C:\planted",
    "PATH": r"C:\planted",
    "TEMP": r"C:\planted",
    "TMP": r"C:\planted",
    "SystemRoot": r"C:\planted",
    "windir": r"C:\planted",
    "ComSpec": r"C:\planted\cmd.exe",
    "PROCESSOR_ARCHITECTURE": "planted",
    **{name: "planted" for name in CANCEL_ENVIRONMENT_NAMES},
}
ALLOWED = {
    "SYSTEMROOT",
    "WINDIR",
    "SYSTEMDRIVE",
    "COMSPEC",
    "PATH",
    "PATHEXT",
    "OS",
    "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE",
    "TEMP",
    "TMP",
    "RESTIC_PASSWORD",
}
DUMP_ENVIRONMENT = """import json, os, sys
from pathlib import Path
print("environment captured")
Path(sys.argv[-1]).write_text(json.dumps(dict(os.environ)), encoding="utf-8")
"""


def planted_environment():
    return mock.patch.dict(os.environ, PLANTED)


class EnvironmentRecorder:
    """Wrap a fake runner and keep the environment of every call."""

    def __init__(self, inner) -> None:
        self.inner = inner
        self.calls: list[tuple[list[str], object]] = []

    def __call__(self, command: list[str], **kwargs: object):
        self.calls.append((list(command), kwargs.get("env")))
        return self.inner(command, **kwargs)


class ChildEnvironmentTests(unittest.TestCase):
    def assert_allow_listed(self, environment: object) -> dict[str, str]:
        """Check one child environment and return it with upper-case names."""
        self.assertIsInstance(environment, dict, "the child must not inherit the environment")
        values = {str(name).upper(): str(value) for name, value in dict(environment).items()}
        self.assertLessEqual(set(values), ALLOWED)
        for name, value in PLANTED.items():
            self.assertNotEqual(value, values.get(name.upper()), name)
        windows = str(windows_directory())
        self.assertEqual(windows, values["SYSTEMROOT"])
        self.assertEqual(windows, values["WINDIR"])
        self.assertNotIn("PROCESSOR_ARCHITECTURE", values)
        for folder in values["PATH"].split(";"):
            self.assertTrue(
                folder.casefold().startswith(windows.casefold()),
                f"PATH holds a folder outside Windows: {folder}",
            )
        return values

    def test_builder_keeps_only_the_allow_list(self) -> None:
        with tempfile.TemporaryDirectory(prefix="child-environment-") as root_text:
            cache = Path(root_text) / "state" / "cache"
            with planted_environment():
                plain = restic_child_environment()
                with_temp = restic_child_environment(
                    ["restic", "--cache-dir", str(cache), "snapshots"],
                    password="recovery-password",
                )
            values = self.assert_allow_listed(plain)
            self.assertNotIn("TEMP", values)
            self.assertNotIn("RESTIC_PASSWORD", values)
            values = self.assert_allow_listed(with_temp)
            temp = Path(root_text) / "state" / "temp"
            self.assertEqual(str(temp), values["TEMP"])
            self.assertEqual(str(temp), values["TMP"])
            self.assertTrue(temp.is_dir())
            self.assertEqual("recovery-password", values["RESTIC_PASSWORD"])

    def test_builder_refuses_a_linked_temp_folder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="child-environment-link-") as root_text:
            root = Path(root_text)
            elsewhere = root / "elsewhere"
            elsewhere.mkdir()
            (root / "state").mkdir()
            completed = subprocess.run(
                ["cmd.exe", "/d", "/c", "mklink", "/J", str(root / "state" / "temp"), str(elsewhere)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(0, completed.returncode, completed.stderr)
            with self.assertRaisesRegex(RuntimeError, "not a normal local folder"):
                restic_child_environment(["restic", "--cache-dir", str(root / "state" / "cache")])

    def test_run_capture_and_stream_command_children_see_only_the_allow_list(self) -> None:
        with tempfile.TemporaryDirectory(prefix="child-environment-run-") as root_text:
            root = Path(root_text)
            dump = root / "dump_environment.py"
            dump.write_text(DUMP_ENVIRONMENT, encoding="utf-8")
            cache = root / "state" / "cache"
            captured = root / "captured.json"
            streamed = root / "streamed.json"
            base = [sys.executable, "-I", "-S", str(dump), "--cache-dir", str(cache)]
            with planted_environment():
                result = run_capture([*base, str(captured)])
                log = io.StringIO()
                code = stream_command([*base, str(streamed)], log)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(0, code, log.getvalue())
            for path in (captured, streamed):
                with self.subTest(child=path.name):
                    values = self.assert_allow_listed(
                        json.loads(path.read_text(encoding="utf-8"))
                    )
                    self.assertEqual(str(root / "state" / "temp"), values["TEMP"])
                    self.assertNotIn("RESTIC_PASSWORD", values)

    def test_credential_repair_gives_restic_only_the_allow_list(self) -> None:
        with tempfile.TemporaryDirectory(prefix="child-environment-repair-") as root_text:
            config_path, _ = test_credential_repair.build_fixture(Path(root_text))
            runner = EnvironmentRecorder(test_credential_repair.FakeRunner())
            with planted_environment(), mock.patch(
                "credential_repair.load_secret",
                return_value=test_credential_repair.PASSWORD,
            ):
                result = credential_repair.repair(
                    config_path,
                    expected_config_sha256=credential_repair.sha256_file(config_path),
                    expected_plan_id=test_credential_repair.PLAN_ID,
                    expected_generation=4,
                    expected_user_sid=test_credential_repair.SID,
                    runner=runner,
                    acl_verifier=lambda path: None,
                    sid_reader=lambda: test_credential_repair.SID,
                    require_manifest=False,
                )
            self.assertEqual("already_healthy", result["state"])
            self.assertEqual(2, len(runner.calls))
            recovery = self.assert_allow_listed(runner.calls[0][1])
            self.assertEqual(test_credential_repair.PASSWORD, recovery["RESTIC_PASSWORD"])
            active = self.assert_allow_listed(runner.calls[1][1])
            self.assertIn("--password-command", runner.calls[1][0])
            self.assertNotIn("RESTIC_PASSWORD", active)

    def test_recovery_health_gives_restic_only_the_allow_list(self) -> None:
        with tempfile.TemporaryDirectory(prefix="child-environment-health-") as root_text:
            config_path = test_recovery_health.build_fixture(Path(root_text))
            runner = EnvironmentRecorder(test_recovery_health.FakeRunner())
            with planted_environment():
                report = recovery_health.inspect(
                    config_path,
                    runner=runner,
                    acl_verifier=lambda path: None,
                    history_acl_verifier=lambda path: None,
                )
            self.assertEqual("healthy", report["overall_status"])
            self.assertGreaterEqual(len(runner.calls), 3)
            recovery_calls = 0
            for command, environment in runner.calls:
                values = self.assert_allow_listed(environment)
                if "RESTIC_PASSWORD" in values:
                    recovery_calls += 1
                    self.assertNotIn("--password-command", command)
            self.assertEqual(1, recovery_calls)

    def test_stale_lock_repair_gives_restic_only_the_allow_list(self) -> None:
        with tempfile.TemporaryDirectory(prefix="child-environment-locks-") as root_text:
            config_path, _ = test_stale_lock_repair.build_fixture(Path(root_text))
            runner = EnvironmentRecorder(test_stale_lock_repair.StatefulRunner(locks_before=1))
            with planted_environment():
                result = stale_lock_repair.repair(
                    config_path,
                    expected_config_sha256=stale_lock_repair.sha256_file(config_path),
                    expected_plan_id=test_stale_lock_repair.PLAN_ID,
                    expected_generation=5,
                    expected_user_sid=test_stale_lock_repair.SID,
                    runner=runner,
                    process_reader=lambda: [],
                    sid_reader=lambda: test_stale_lock_repair.SID,
                    require_manifest=False,
                )
            self.assertEqual("repaired", result["state"])
            self.assertTrue(any(command[-1:] == ["unlock"] for command, _ in runner.calls))
            for _, environment in runner.calls:
                self.assertNotIn("RESTIC_PASSWORD", self.assert_allow_listed(environment))

    def test_stale_lock_repair_finds_tasklist_in_the_real_windows_folder(self) -> None:
        commands: list[list[str]] = []

        def runner(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            commands.append(list(command))
            return subprocess.CompletedProcess(command, 0, "INFO: No tasks are running.\n", "")

        with planted_environment():
            self.assertEqual([], stale_lock_repair.running_restic_processes(runner))
        self.assertEqual(
            str(windows_directory() / "System32" / "tasklist.exe"),
            commands[0][0],
        )

    def test_key_rotation_gives_restic_only_the_allow_list(self) -> None:
        repository_id = "e" * 64
        key_id = "f" * 64

        def fake(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            if command[-2:] == ["cat", "config"]:
                return subprocess.CompletedProcess(
                    command, 0, json.dumps({"id": repository_id, "version": 2}), ""
                )
            if command[-2:] == ["key", "list"]:
                return subprocess.CompletedProcess(
                    command, 0, json.dumps([{"id": key_id, "current": True}]), ""
                )
            return subprocess.CompletedProcess(command, 0, "", "")

        with tempfile.TemporaryDirectory(prefix="child-environment-rotation-") as root_text:
            state = Path(root_text) / "state"
            runner = EnvironmentRecorder(fake)
            with planted_environment():
                identity = key_rotation._authenticate_plaintext(
                    Path(root_text) / "restic.exe",
                    Path(root_text) / "repository",
                    "new-recovery-password",
                    runner=runner,
                )
                key_rotation._restic_result(
                    runner,
                    ["restic", "--password-command", "helper", "--cache-dir", str(state / "cache"), "key", "add"],
                )
            self.assertEqual(repository_id, identity[0])
            self.assertEqual(key_id, identity[3])
            self.assertEqual(3, len(runner.calls))
            for _, environment in runner.calls[:2]:
                values = self.assert_allow_listed(environment)
                self.assertEqual("new-recovery-password", values["RESTIC_PASSWORD"])
            values = self.assert_allow_listed(runner.calls[2][1])
            self.assertNotIn("RESTIC_PASSWORD", values)
            self.assertEqual(str(state / "temp"), values["TEMP"])


if __name__ == "__main__":
    unittest.main()
