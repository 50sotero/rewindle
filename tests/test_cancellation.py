from __future__ import annotations

import argparse
import ast
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from datetime import datetime
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402
from restic_common import (  # noqa: E402
    BackupCancelled,
    CANCEL_CHANNEL_FINGERPRINT_ENV,
    CANCEL_CHANNEL_ID_ENV,
    CANCEL_EVENT_NAME_ENV,
    CANCEL_EVENT_PREFIX,
    CANCEL_LAUNCHER_PID_ENV,
    CANCEL_LAUNCHER_START_FILETIME_ENV,
    CREATE_NO_WINDOW,
    CancellationIdentity,
    CancellationToken,
    _child_environment_without_cancellation_identity,
    _wait_for_cancellable_process,
    cancellation_checkpoint,
    process_start_filetime,
    stream_command,
)


TEST_PLAN_ID = "20000000-0000-4000-8000-000000000001"
TEST_PLAN_TAG = "restic-backuper-plan:" + TEST_PLAN_ID
TEST_GENERATION_TAG = "restic-backuper-generation:1"


def ready_preflight(source: Path) -> dict[str, object]:
    return {
        "schema_version": 1,
        "policy": "strict",
        "status": "ready",
        "sources": [
            {
                "canonical_path": str(source.resolve()),
                "readiness": "ready",
                "expected_volume_serial": "A1B2C3D4",
                "observed_volume_serial": "A1B2C3D4",
                "volume_identity": "match",
                "overall_status": "ready",
            }
        ],
        "failures": [],
    }


def create_test_event(channel_id: str):
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateEventW.argtypes = [
        ctypes.c_void_p,
        wintypes.BOOL,
        wintypes.BOOL,
        wintypes.LPCWSTR,
    ]
    kernel32.CreateEventW.restype = wintypes.HANDLE
    kernel32.SetEvent.argtypes = [wintypes.HANDLE]
    kernel32.SetEvent.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    name = CANCEL_EVENT_PREFIX + channel_id
    handle = kernel32.CreateEventW(None, True, False, name)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    return kernel32, int(handle), name


def cancellation_environment(channel_id: str, event_name: str) -> dict[str, str]:
    return {
        CANCEL_EVENT_NAME_ENV: event_name,
        CANCEL_CHANNEL_ID_ENV: channel_id,
        CANCEL_CHANNEL_FINGERPRINT_ENV: hashlib.sha256(
            event_name.encode("utf-8")
        ).hexdigest(),
        CANCEL_LAUNCHER_PID_ENV: str(os.getpid()),
        CANCEL_LAUNCHER_START_FILETIME_ENV: process_start_filetime(),
    }


class FakeProcess:
    def __init__(self, returncode: int) -> None:
        self.pid = 43210
        self.stdout = io.StringIO("line before exit\n")
        self.returncode = returncode
        self.poll_count = 0

    def poll(self):
        self.poll_count += 1
        return None if self.poll_count <= 2 else self.returncode

    def wait(self, timeout=None):
        return self.returncode

    def terminate(self):
        raise AssertionError("completed fake process must not be terminated")

    def kill(self):
        raise AssertionError("completed fake process must not be killed")


class AlreadyExitedProcess(FakeProcess):
    def poll(self):
        return self.returncode


class FakeCancellation:
    enabled = True

    def __init__(self) -> None:
        self.requested_utc = "2026-07-20T10:00:00Z"
        self.resolution = None

    def poll(self) -> bool:
        return self.resolution is None

    def disarm(self, resolution: str) -> None:
        self.resolution = resolution


class FakeConsole:
    def __init__(self, error: Exception | None = None) -> None:
        self.calls = 0
        self.error = error

    def send_ctrl_break(self, _process_id: int) -> None:
        self.calls += 1
        if self.error is not None:
            raise self.error


class CancellationTests(unittest.TestCase):
    def test_restic_children_do_not_inherit_the_control_channel(self) -> None:
        control = {
            CANCEL_EVENT_NAME_ENV: "event",
            CANCEL_CHANNEL_ID_ENV: "id",
            CANCEL_CHANNEL_FINGERPRINT_ENV: "fingerprint",
            CANCEL_LAUNCHER_PID_ENV: "123",
            CANCEL_LAUNCHER_START_FILETIME_ENV: "456",
        }
        with mock.patch.dict(os.environ, control, clear=False):
            child = _child_environment_without_cancellation_identity()
        for name in control:
            self.assertNotIn(name, child)

    def test_token_validates_identity_and_opens_synchronize_only(self) -> None:
        channel_id = "ab" * 32
        kernel32, creator, event_name = create_test_event(channel_id)
        token = None
        try:
            token = CancellationToken.from_environment(
                cancellation_environment(channel_id, event_name)
            )
            self.assertTrue(token.enabled)
            self.assertFalse(token.poll())

            ctypes.set_last_error(0)
            self.assertFalse(kernel32.SetEvent(token.handle))
            self.assertEqual(ctypes.get_last_error(), 5)

            self.assertTrue(kernel32.SetEvent(creator))
            self.assertTrue(token.poll())
            first_observed = token.requested_utc
            self.assertTrue(token.poll())
            self.assertEqual(token.requested_utc, first_observed)
        finally:
            if token is not None:
                token.close()
            kernel32.CloseHandle(creator)

    def test_token_rejects_partial_or_forged_launcher_contract(self) -> None:
        channel_id = "cd" * 32
        event_name = CANCEL_EVENT_PREFIX + channel_id
        complete = cancellation_environment(channel_id, event_name)
        for name in complete:
            with self.subTest(missing=name):
                malformed = dict(complete)
                del malformed[name]
                with self.assertRaisesRegex(ValueError, "incomplete"):
                    CancellationToken.from_environment(malformed)

        malformed = dict(complete)
        malformed[CANCEL_EVENT_NAME_ENV] += "-forged"
        with self.assertRaisesRegex(ValueError, "not derived"):
            CancellationToken.from_environment(malformed)
        malformed = dict(complete)
        malformed[CANCEL_CHANNEL_FINGERPRINT_ENV] = "0" * 64
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            CancellationToken.from_environment(malformed)

    def test_checkpoint_cancels_without_starting_a_child(self) -> None:
        cancellation = FakeCancellation()
        updates = []
        with self.assertRaises(BackupCancelled) as raised:
            cancellation_checkpoint(
                cancellation,
                lambda stage, timestamp: updates.append((stage, timestamp)),
            )
        self.assertTrue(raised.exception.cooperative)
        self.assertEqual(raised.exception.outcome, "cancelled_at_checkpoint")
        self.assertEqual(updates, [("requested", cancellation.requested_utc)])

    def test_supervisor_sends_ctrl_break_exactly_once_and_maps_130(self) -> None:
        process = FakeProcess(130)
        cancellation = FakeCancellation()
        console = FakeConsole()
        updates = []
        with self.assertRaises(BackupCancelled) as raised:
            _wait_for_cancellable_process(
                process,
                {"stdout": process.stdout},
                console,
                cancellation,
                lambda stage, timestamp: updates.append((stage, timestamp)),
                lambda _stream, _line: None,
            )
        self.assertEqual(console.calls, 1)
        self.assertEqual(raised.exception.process_returncode, 130)
        self.assertEqual(raised.exception.outcome, "restic_exit_130")
        self.assertEqual([item[0] for item in updates], ["requested", "signal_sent"])

    def test_exit_zero_after_signal_continues_normal_verification_path(self) -> None:
        process = FakeProcess(0)
        cancellation = FakeCancellation()
        console = FakeConsole()
        updates = []
        return_code = _wait_for_cancellable_process(
            process,
            {"stdout": process.stdout},
            console,
            cancellation,
            lambda stage, timestamp: updates.append((stage, timestamp)),
            lambda _stream, _line: None,
        )
        self.assertEqual(return_code, 0)
        self.assertEqual(console.calls, 1)
        self.assertEqual(
            cancellation.resolution, "finished_before_cancellation_took_effect"
        )
        self.assertEqual(
            [item[0] for item in updates],
            [
                "requested",
                "signal_sent",
                "finished_before_cancellation_took_effect",
            ],
        )
        self.assertFalse(cancellation.poll())

    def test_child_exit_wins_a_request_first_observed_after_exit(self) -> None:
        for return_code, expected_resolution in (
            (0, "finished_before_cancellation_took_effect"),
            (3, "child_exit_won_cancellation_race"),
            (130, "child_exit_won_cancellation_race"),
        ):
            with self.subTest(return_code=return_code):
                process = AlreadyExitedProcess(return_code)
                cancellation = FakeCancellation()
                console = FakeConsole()
                updates = []
                observed = _wait_for_cancellable_process(
                    process,
                    {"stdout": process.stdout},
                    console,
                    cancellation,
                    lambda stage, timestamp: updates.append((stage, timestamp)),
                    lambda _stream, _line: None,
                )
                self.assertEqual(observed, return_code)
                self.assertEqual(console.calls, 0)
                self.assertEqual(cancellation.resolution, expected_resolution)
                self.assertEqual(
                    [item[0] for item in updates],
                    ["requested", expected_resolution],
                )
                self.assertFalse(cancellation.poll())

    def test_signal_failure_then_exit_zero_continues_normal_path(self) -> None:
        process = FakeProcess(0)
        cancellation = FakeCancellation()
        console = FakeConsole(OSError("simulated GenerateConsoleCtrlEvent failure"))
        updates = []
        return_code = _wait_for_cancellable_process(
            process,
            {"stdout": process.stdout},
            console,
            cancellation,
            lambda stage, timestamp: updates.append((stage, timestamp)),
            lambda _stream, _line: None,
        )
        self.assertEqual(return_code, 0)
        self.assertEqual(console.calls, 1)
        self.assertEqual(cancellation.resolution, "ctrl_break_signal_failed")
        self.assertEqual(
            [item[0] for item in updates],
            ["requested", "ctrl_break_signal_failed"],
        )

    def test_signal_failure_never_relabels_an_independent_exit_130(self) -> None:
        process = FakeProcess(130)
        cancellation = FakeCancellation()
        console = FakeConsole(OSError("simulated GenerateConsoleCtrlEvent failure"))
        updates = []
        return_code = _wait_for_cancellable_process(
            process,
            {"stdout": process.stdout},
            console,
            cancellation,
            lambda stage, timestamp: updates.append((stage, timestamp)),
            lambda _stream, _line: None,
        )
        self.assertEqual(return_code, 130)
        self.assertEqual(console.calls, 1)
        self.assertEqual(cancellation.resolution, "ctrl_break_signal_failed")
        self.assertEqual(
            [item[0] for item in updates],
            ["requested", "ctrl_break_signal_failed"],
        )

    def test_cancelled_run_is_terminal_130_and_preserves_last_success(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-cancel-status-") as root_text:
            root = Path(root_text)
            state = root / "state"
            state.mkdir()
            previous_success = {"state": "success", "snapshot_id": "previous"}
            last_success = state / "last-success.json"
            last_success.write_text(json.dumps(previous_success), encoding="utf-8")
            source = root / "source"
            source.mkdir()
            excludes = root / "excludes.txt"
            excludes.write_text("**/__pycache__\n", encoding="utf-8")
            restic = root / "restic.exe"
            restic.write_bytes(b"fixture")
            canary = source / "canary.txt"
            canary.write_text("canary\n", encoding="utf-8")
            identity = CancellationIdentity(
                channel_id="ef" * 32,
                channel_fingerprint="01" * 32,
                event_name=CANCEL_EVENT_PREFIX + "ef" * 32,
                launcher_pid=2468,
                launcher_start_filetime="133700000000000000",
            )

            class RequestedToken:
                def __init__(self) -> None:
                    self.identity = identity
                    self.requested_utc = "2026-07-20T11:00:00Z"

                def poll(self) -> bool:
                    return True

            config = {
                "plan_id": TEST_PLAN_ID,
                "config_generation": 1,
                "scheduled_tag": "scheduled",
                "state_directory": str(state),
                "repository": str(root / "repository"),
                "repository_volume_serial": "A1B2C3D4",
                "hostname": "CANCEL-TEST",
                "sources": [str(source)],
                "exclude_file": str(excludes),
                "restic_executable": str(restic),
                "canary_file": str(canary),
                "source_identities": {
                    str(source): {"expected_volume_serial": "A1B2C3D4"}
                },
                "cloud_placeholder_policy": "strict",
            }
            args = argparse.Namespace(tag=None, scheduled=True)
            with mock.patch.object(
                backup, "process_start_filetime", return_value="133711111111111111"
            ):
                result = backup._run_locked(args, config, RequestedToken())

            self.assertEqual(result, 130)
            status = json.loads((state / "status.json").read_text(encoding="utf-8"))
            self.assertEqual(status["state"], "cancelled")
            self.assertEqual(status["exit_code"], 130)
            self.assertEqual(status["cancel_outcome"], "cancelled_at_checkpoint")
            self.assertEqual(status["launcher_pid"], 2468)
            self.assertEqual(
                status["launcher_start_filetime"], "133700000000000000"
            )
            self.assertEqual(
                status["wrapper_start_filetime"], "133711111111111111"
            )
            self.assertFalse(status["verification_complete"])
            self.assertFalse(status["snapshot_created"])
            self.assertNotIn("failure", status)
            self.assertEqual(
                json.loads(last_success.read_text(encoding="utf-8")), previous_success
            )

    def test_every_restic_phase_accepts_the_cancellation_contract(self) -> None:
        source = (SOURCE / "backup.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        restic_calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id in {"run_capture", "stream_command"}
        ]
        self.assertEqual(
            sum(node.func.id == "run_capture" for node in restic_calls), 3
        )
        self.assertGreaterEqual(
            sum(node.func.id == "stream_command" for node in restic_calls), 4
        )
        for call in restic_calls:
            with self.subTest(function=call.func.id, line=call.lineno):
                keywords = {item.arg for item in call.keywords}
                self.assertIn("cancellation", keywords)
                self.assertIn("on_cancellation", keywords)
        canary_source = source[
            source.index("def verify_canary(") : source.index("def _run_locked(")
        ]
        self.assertIn("cancellation=cancellation", canary_source)
        self.assertIn("cancellation_checkpoint(cancellation", canary_source)

    def test_backup_exit_result_wins_the_final_checkpoint_race(self) -> None:
        source = (SOURCE / "backup.py").read_text(encoding="utf-8")
        result_block = source[
            source.index('status["backup_exit_code"] = backup_return_code') :
            source.index('status["state"] = "verifying_snapshot"')
        ]
        checkpoint = result_block.index(
            "cancellation_checkpoint(cancellation, on_cancellation)"
        )
        self.assertLess(result_block.index("if backup_return_code == 3:"), checkpoint)
        self.assertLess(result_block.index("if backup_return_code != 0:"), checkpoint)

    def test_cancellation_is_terminal_at_each_restic_phase_and_between_phases(self) -> None:
        phases = (
            "repository_identity",
            "prior_snapshots",
            "backup",
            "post_snapshots",
            "repository_check",
            "canary",
            "subset_check",
            "checkpoint_after_canary",
        )
        for target_phase in phases:
            with self.subTest(phase=target_phase):
                with tempfile.TemporaryDirectory(
                    prefix="restic-cancel-phase-"
                ) as root_text:
                    root = Path(root_text)
                    source = root / "source"
                    source.mkdir()
                    repository = root / "repository"
                    repository.mkdir()
                    state = root / "state"
                    state.mkdir()
                    excludes = root / "excludes.txt"
                    excludes.write_text("**/__pycache__\n", encoding="utf-8")
                    restic = root / "restic.exe"
                    restic.write_bytes(b"fixture")
                    canary = source / "canary.txt"
                    canary.write_text("canary\n", encoding="utf-8")
                    previous_success = {"state": "success", "snapshot_id": "old"}
                    last_success = state / "last-success.json"
                    if target_phase == "subset_check":
                        last_success.write_text(
                            json.dumps(previous_success), encoding="utf-8"
                        )

                    class PhaseToken:
                        identity = None
                        requested_utc = "2026-07-20T12:00:00Z"

                        def __init__(self) -> None:
                            self.requested = False

                        def poll(self) -> bool:
                            return self.requested

                    token = PhaseToken()
                    snapshot_calls = 0
                    check_calls = 0

                    def cancel_from_process(on_cancellation) -> None:
                        on_cancellation("requested", token.requested_utc)
                        on_cancellation("signal_sent", "2026-07-20T12:00:01Z")
                        raise BackupCancelled(
                            token.requested_utc,
                            signal_sent_utc="2026-07-20T12:00:01Z",
                            process_returncode=130,
                        )

                    def fake_capture(command, **kwargs):
                        nonlocal snapshot_calls
                        if command[1] == "cat":
                            if target_phase == "repository_identity":
                                cancel_from_process(kwargs["on_cancellation"])
                            return subprocess.CompletedProcess(
                                ["restic"],
                                0,
                                json.dumps({"id": "f" * 64, "version": 2}),
                                "",
                            )
                        phase = (
                            "prior_snapshots"
                            if snapshot_calls == 0
                            else "post_snapshots"
                        )
                        snapshot_calls += 1
                        if target_phase == phase:
                            cancel_from_process(kwargs["on_cancellation"])
                        payload = []
                        if phase == "post_snapshots":
                            payload = [
                                {
                                    "id": "new-snapshot",
                                    "hostname": "PHASE-TEST",
                                    "tags": [
                                        "scheduled",
                                        TEST_PLAN_TAG,
                                        TEST_GENERATION_TAG,
                                    ],
                                    "paths": [str(source)],
                                    "time": "2026-07-20T12:00:00Z",
                                }
                            ]
                        return subprocess.CompletedProcess(
                            ["restic"], 0, json.dumps(payload), ""
                        )

                    def fake_stream(command, _log, on_line=None, **kwargs):
                        nonlocal check_calls
                        verb = command[1]
                        if verb == "backup":
                            if target_phase == "backup":
                                cancel_from_process(kwargs["on_cancellation"])
                            on_line(
                                json.dumps(
                                    {
                                        "message_type": "summary",
                                        "snapshot_id": "new-snapshot",
                                    }
                                )
                            )
                            return 0
                        if verb == "check":
                            check_calls += 1
                            phase = (
                                "repository_check"
                                if check_calls == 1
                                else "subset_check"
                            )
                            if target_phase == phase:
                                cancel_from_process(kwargs["on_cancellation"])
                            return 0
                        raise AssertionError(f"unexpected fake Restic verb: {verb}")

                    def fake_canary(_config, _snapshot, _run, _log, **kwargs):
                        if target_phase == "canary":
                            cancel_from_process(kwargs["on_cancellation"])
                        if target_phase == "checkpoint_after_canary":
                            token.requested = True
                        return {"verified": True}

                    config = {
                        "plan_id": TEST_PLAN_ID,
                        "config_generation": 1,
                        "scheduled_tag": "scheduled",
                        "state_directory": str(state),
                        "repository": str(repository),
                        "repository_volume_serial": "A1B2C3D4",
                        "hostname": "PHASE-TEST",
                        "sources": [str(source)],
                        "exclude_file": str(excludes),
                        "restic_executable": str(restic),
                        "canary_file": str(canary),
                        "use_vss": False,
                        "read_concurrency": 2,
                        "structural_check_after_backup": True,
                        "read_data_subset_parts": 1,
                        "read_data_subset_weekday": datetime.now().strftime("%A"),
                        "source_identities": {
                            str(source): {"expected_volume_serial": "A1B2C3D4"}
                        },
                        "cloud_placeholder_policy": "strict",
                    }
                    args = argparse.Namespace(tag=None, scheduled=True)
                    with (
                        mock.patch.object(backup, "validate_repository_volume"),
                        mock.patch.object(backup, "ensure_free_space", return_value=1),
                        mock.patch.object(
                            backup,
                            "preflight_sources",
                            return_value=ready_preflight(source),
                        ),
                        mock.patch.object(backup, "restic_base", return_value=["restic"]),
                        mock.patch.object(backup, "run_capture", side_effect=fake_capture),
                        mock.patch.object(backup, "stream_command", side_effect=fake_stream),
                        mock.patch.object(backup, "verify_canary", side_effect=fake_canary),
                        mock.patch.object(
                            backup,
                            "process_start_filetime",
                            return_value="133722222222222222",
                        ),
                    ):
                        result = backup._run_locked(args, config, token)

                    self.assertEqual(result, 130)
                    status = json.loads(
                        (state / "status.json").read_text(encoding="utf-8")
                    )
                    self.assertEqual(status["state"], "cancelled")
                    self.assertEqual(status["exit_code"], 130)
                    self.assertFalse(status["verification_complete"])
                    if target_phase == "subset_check":
                        self.assertEqual(
                            json.loads(last_success.read_text(encoding="utf-8")),
                            previous_success,
                        )
                    else:
                        self.assertFalse(last_success.exists())

    def test_exit_zero_cancellation_races_finish_verification_and_publish_success(self) -> None:
        for outcome in (
            "finished_before_cancellation_took_effect",
            "ctrl_break_signal_failed",
        ):
            with self.subTest(outcome=outcome):
                with tempfile.TemporaryDirectory(
                    prefix="restic-cancel-race-success-"
                ) as root_text:
                    root = Path(root_text)
                    source = root / "source"
                    source.mkdir()
                    repository = root / "repository"
                    repository.mkdir()
                    state = root / "state"
                    excludes = root / "excludes.txt"
                    excludes.write_text("**/__pycache__\n", encoding="utf-8")
                    restic = root / "restic.exe"
                    restic.write_bytes(b"fixture")
                    canary = source / "canary.txt"
                    canary.write_text("canary\n", encoding="utf-8")

                    class ResolvedToken:
                        identity = None
                        requested_utc = "2026-07-20T13:00:00Z"

                        def poll(self) -> bool:
                            return False

                    token = ResolvedToken()
                    snapshot_calls = 0

                    def fake_capture(command, **_kwargs):
                        nonlocal snapshot_calls
                        if command[1] == "cat":
                            return subprocess.CompletedProcess(
                                ["restic"],
                                0,
                                json.dumps({"id": "f" * 64, "version": 2}),
                                "",
                            )
                        snapshot_calls += 1
                        payload = [] if snapshot_calls == 1 else [
                            {
                                "id": "race-snapshot",
                                "hostname": "RACE-TEST",
                                "tags": [
                                    "scheduled",
                                    TEST_PLAN_TAG,
                                    TEST_GENERATION_TAG,
                                ],
                                "paths": [str(source)],
                                "time": "2026-07-20T13:00:00Z",
                            }
                        ]
                        return subprocess.CompletedProcess(
                            ["restic"], 0, json.dumps(payload), ""
                        )

                    def fake_stream(command, _log, on_line=None, **kwargs):
                        if command[1] == "backup":
                            callback = kwargs["on_cancellation"]
                            callback("requested", token.requested_utc)
                            if outcome == "finished_before_cancellation_took_effect":
                                callback("signal_sent", "2026-07-20T13:00:01Z")
                            callback(outcome, "2026-07-20T13:00:02Z")
                            on_line(
                                json.dumps(
                                    {
                                        "message_type": "summary",
                                        "snapshot_id": "race-snapshot",
                                    }
                                )
                            )
                        return 0

                    config = {
                        "plan_id": TEST_PLAN_ID,
                        "config_generation": 1,
                        "scheduled_tag": "scheduled",
                        "state_directory": str(state),
                        "repository": str(repository),
                        "repository_volume_serial": "A1B2C3D4",
                        "hostname": "RACE-TEST",
                        "sources": [str(source)],
                        "exclude_file": str(excludes),
                        "restic_executable": str(restic),
                        "canary_file": str(canary),
                        "use_vss": False,
                        "read_concurrency": 2,
                        "structural_check_after_backup": True,
                        "read_data_subset_parts": 0,
                        "source_identities": {
                            str(source): {"expected_volume_serial": "A1B2C3D4"}
                        },
                        "cloud_placeholder_policy": "strict",
                    }
                    args = argparse.Namespace(tag=None, scheduled=False)
                    with (
                        mock.patch.object(backup, "validate_repository_volume"),
                        mock.patch.object(backup, "ensure_free_space", return_value=1),
                        mock.patch.object(
                            backup,
                            "preflight_sources",
                            return_value=ready_preflight(source),
                        ),
                        mock.patch.object(backup, "restic_base", return_value=["restic"]),
                        mock.patch.object(backup, "run_capture", side_effect=fake_capture),
                        mock.patch.object(backup, "stream_command", side_effect=fake_stream),
                        mock.patch.object(
                            backup,
                            "verify_canary",
                            return_value={"verified": True},
                        ),
                        mock.patch.object(
                            backup,
                            "process_start_filetime",
                            return_value="133733333333333333",
                        ),
                    ):
                        result = backup._run_locked(args, config, token)

                    self.assertEqual(result, 0)
                    success = json.loads(
                        (state / "last-success.json").read_text(encoding="utf-8")
                    )
                    self.assertEqual(success["state"], "success")
                    self.assertEqual(success["cancel_outcome"], outcome)
                    self.assertEqual(
                        success["cancel_requested_utc"], token.requested_utc
                    )
                    self.assertTrue(success["verification_complete"])
                    self.assertTrue(success["snapshot_created"])
                    if outcome == "finished_before_cancellation_took_effect":
                        self.assertEqual(
                            success["cancel_signal_sent_utc"],
                            "2026-07-20T13:00:01Z",
                        )
                    else:
                        self.assertIsNone(success["cancel_signal_sent_utc"])

    def test_private_console_is_not_visible_in_a_consoleless_driver(self) -> None:
        script = (
            "import ctypes,sys; "
            "sys.path.insert(0, r'" + str(SOURCE) + "'); "
            "from restic_common import _WindowsCtrlBreakConsole; "
            "u=ctypes.WinDLL('user32'); k=ctypes.WinDLL('kernel32'); "
            "k.GetConsoleWindow.restype=ctypes.c_void_p; "
            "u.IsWindowVisible.argtypes=[ctypes.c_void_p]; "
            "u.IsWindowVisible.restype=ctypes.c_int; "
            "c=_WindowsCtrlBreakConsole(True); c.__enter__(); "
            "w=k.GetConsoleWindow(); visible=(u.IsWindowVisible(w) if w else 0); "
            "c.close(); raise SystemExit(1 if visible else 0)"
        )
        result = subprocess.run(
            [sys.executable, "-I", "-c", script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            creationflags=CREATE_NO_WINDOW,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))

    def test_real_ctrl_break_is_drained_and_exits_130(self) -> None:
        channel_id = "12" * 32
        kernel32, creator, event_name = create_test_event(channel_id)
        token = None
        log = io.StringIO()
        updates = []
        try:
            token = CancellationToken.from_environment(
                cancellation_environment(channel_id, event_name)
            )

            def on_line(line: str) -> None:
                if line == "ready":
                    if not kernel32.SetEvent(creator):
                        raise ctypes.WinError(ctypes.get_last_error())

            with self.assertRaises(BackupCancelled) as raised:
                stream_command(
                    [sys.executable, "-I", str(PROJECT / "tests" / "fixtures" / "cancel_signal_helper.py")],
                    log,
                    on_line,
                    cancellation=token,
                    on_cancellation=lambda stage, timestamp: updates.append(
                        (stage, timestamp)
                    ),
                )
            self.assertEqual(raised.exception.process_returncode, 130)
            self.assertEqual(raised.exception.outcome, "restic_exit_130")
            self.assertEqual([item[0] for item in updates].count("signal_sent"), 1)
            self.assertIn("ctrl_break_received", log.getvalue())
            self.assertIn("cleanup_complete", log.getvalue())
        finally:
            if token is not None:
                token.close()
            kernel32.CloseHandle(creator)


if __name__ == "__main__":
    unittest.main()
