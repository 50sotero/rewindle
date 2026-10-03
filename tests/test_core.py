from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import backup
import dry_run
import restic_common
import recovery_health
import restore
import secret_store


class CoreSafetyTests(unittest.TestCase):
    def _write_config(
        self,
        root: Path,
        *,
        exclude_text: str = "**/__pycache__\n",
        repository: Path | None = None,
        sources: list[Path] | None = None,
    ) -> Path:
        source = root / "source"
        source.mkdir(exist_ok=True)
        repository = repository or (root / "repository")
        restic = root / "restic.exe"
        restic.write_bytes(b"test fixture; not an executable")
        excludes = root / "excludes.txt"
        excludes.write_text(exclude_text, encoding="utf-8")
        canary = root / "canary.txt"
        canary.write_text("ResticBackuper test canary\n", encoding="utf-8")
        config_path = root / "backup-config.test.json"
        configured_sources = [str(item) for item in (sources or [source])]
        config_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "plan_id": "11111111-1111-4111-8111-111111111111",
                    "config_generation": 1,
                    "repository": str(repository),
                    "repository_volume_serial": "00000000",
                    "restic_executable": str(restic),
                    "recovery_tools_directory": str(root / "recovery-tools"),
                    "python_executable": sys.executable,
                    "state_directory": str(root / "state"),
                    "secret_file": str(root / "state" / "password.test.json"),
                    "recovery_key_file": str(root / "recovery.test.txt"),
                    "exclude_file": str(excludes),
                    "canary_file": str(canary),
                    "hostname": "RESTICBACKUPER-TEST",
                    "scheduled_tag": "scheduled-test",
                    "cloud_placeholder_policy": "strict",
                    "sources": configured_sources,
                    "source_identities": {
                        item: {"expected_volume_serial": "00000000"}
                        for item in configured_sources
                    },
                }
            ),
            encoding="utf-8",
        )
        return config_path

    def test_example_exclusions_pass_protected_tree_guard(self) -> None:
        patterns = [
            line.strip()
            for line in (SOURCE / "excludes.txt").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertTrue(patterns)
        for pattern in patterns:
            with self.subTest(pattern=pattern):
                self.assertFalse(
                    restic_common._exclude_can_touch_protected_tree(pattern, ".git")
                )
                self.assertFalse(
                    restic_common._exclude_can_touch_protected_tree(
                        pattern, ".codex-worktrees"
                    )
                )

    def test_exclude_guard_rejects_patterns_that_can_hide_git_state(self) -> None:
        for pattern in ("**/.g*", "**/.*", "**/.g*/objects", "**"):
            with self.subTest(pattern=pattern):
                self.assertTrue(
                    restic_common._exclude_can_touch_protected_tree(pattern, ".git")
                )
        self.assertFalse(
            restic_common._exclude_can_touch_protected_tree(
                "**/.terraform/providers", ".git"
            )
        )
        with self.assertRaises(ValueError):
            restic_common._exclude_can_touch_protected_tree("!**/.git", ".git")

    def test_load_config_accepts_safe_isolated_configuration(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-config-") as root_text:
            root = Path(root_text)
            config_path = self._write_config(root)

            config = restic_common.load_config(
                config_path, require_repository=False
            )

            self.assertEqual([str((root / "source").resolve())], config["sources"])
            self.assertEqual(
                str((root / "repository").resolve()), config["repository"]
            )

    def test_load_config_rejects_repository_source_overlap(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-overlap-") as root_text:
            root = Path(root_text)
            source = root / "source"
            source.mkdir()
            config_path = self._write_config(
                root,
                repository=source / "repository",
                sources=[source],
            )

            with self.assertRaisesRegex(ValueError, "(?:repository and source|source and repository) overlap"):
                restic_common.load_config(config_path, require_repository=False)

    @unittest.skipUnless(os.name == "nt", "requires Windows DOS path aliases")
    def test_short_path_aliases_cannot_bypass_repository_guards(self) -> None:
        import ctypes

        with tempfile.TemporaryDirectory(prefix="resticbackuper-path-alias-") as root_text:
            root = Path(root_text).resolve()
            get_short_path = ctypes.WinDLL("kernel32", use_last_error=True).GetShortPathNameW
            get_short_path.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32]
            get_short_path.restype = ctypes.c_uint32
            buffer = ctypes.create_unicode_buffer(32768)
            length = get_short_path(str(root), buffer, len(buffer))
            self.assertGreater(length, 0)
            alias = Path(buffer.value)
            if str(alias).casefold() == str(root).casefold():
                self.skipTest("temporary volume has DOS alias generation disabled")

            source = root / "source"
            source.mkdir()
            alias_source = alias / "source"
            self.assertEqual(str(source), restic_common.canonical_windows_path(alias_source))
            self.assertEqual(
                str(source / "not-created" / "report.json"),
                restic_common.canonical_windows_path(alias_source / "not-created" / "report.json"),
            )
            config_path = self._write_config(
                root, repository=source / "repository", sources=[alias_source],
            )
            with self.assertRaisesRegex(ValueError, "source and repository.*overlap"):
                restic_common.load_config(config_path, require_repository=False)
            self.assertTrue(restore.is_within(alias_source / "report.json", source))
            self.assertTrue(restore._is_within_windows_path(alias_source, source))
            self.assertEqual(
                source, restore.select_configured_source(alias_source, [str(source)]),
            )
            key = root / "separate-recovery.txt"
            password = "test-fixture-" + "x" * 40
            key.write_text(f"Repository: {alias_source}\nPassword: {password}\n", encoding="utf-8")
            self.assertEqual(password, recovery_health.parse_recovery_key(key, source))

    def test_load_config_rejects_unsafe_exclusion(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-exclude-") as root_text:
            root = Path(root_text)
            config_path = self._write_config(root, exclude_text="**/.g*\n")

            with self.assertRaisesRegex(ValueError, "protected repository state"):
                restic_common.load_config(config_path, require_repository=False)

    def test_protected_lock_paths_are_fixed_public_locations(self) -> None:
        self.assertEqual(
            Path(r"C:\Program Files\ResticBackuper\backup-config.json"),
            restic_common.PROTECTED_CONFIG,
        )
        self.assertEqual(
            Path(r"C:\ProgramData\ResticBackuper"),
            restic_common.PROTECTED_STATE_DIRECTORY,
        )

    def test_wrappers_release_lock_when_locked_body_raises(self) -> None:
        class FakeLock:
            def __init__(self) -> None:
                self.released = False

            def __exit__(self, _exc_type, _exc_value, _traceback) -> None:
                self.released = True

        for module, entrypoint, locked_name in (
            (backup, backup.run, "_run_locked"),
            (dry_run, dry_run.main, "_run_locked"),
        ):
            with self.subTest(module=module.__name__):
                held = FakeLock()
                with (
                    mock.patch.object(
                        module, "load_config_under_lock", return_value=({}, held)
                    ),
                    mock.patch.object(
                        module,
                        locked_name,
                        side_effect=PermissionError("pre-status fixture failure"),
                    ),
                ):
                    with self.assertRaisesRegex(PermissionError, "pre-status"):
                        entrypoint([])
                self.assertTrue(held.released)

    def test_paused_prelock_process_reloads_sources_after_locked_update(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-lock-race-") as root_text:
            root = Path(root_text)
            old_source = root / "old-source"
            new_source = root / "new-source"
            old_source.mkdir()
            new_source.mkdir()
            config_path = self._write_config(root, sources=[old_source])
            config = json.loads(config_path.read_text(encoding="utf-8"))
            state = Path(config["state_directory"])
            paused = threading.Event()
            continue_to_lock = threading.Event()
            outcome: dict[str, object] = {}

            def before_lock() -> None:
                paused.set()
                if not continue_to_lock.wait(timeout=10):
                    raise TimeoutError("test did not release paused pre-lock process")

            def worker() -> None:
                try:
                    loaded, held = restic_common.load_config_under_lock(
                        config_path,
                        require_repository=False,
                        before_lock=before_lock,
                    )
                    try:
                        outcome["sources"] = loaded["sources"]
                    finally:
                        held.__exit__(None, None, None)
                except BaseException as error:
                    outcome["error"] = error

            thread = threading.Thread(target=worker, daemon=True)
            thread.start()
            self.assertTrue(paused.wait(timeout=10), "worker did not reach pre-lock pause")
            with restic_common.RunLock(state / "run.lock"):
                config["sources"] = [str(old_source), str(new_source)]
                config["source_identities"] = {
                    str(old_source): {"expected_volume_serial": "00000000"},
                    str(new_source): {"expected_volume_serial": "00000000"},
                }
                config["config_generation"] += 1
                config_path.write_text(json.dumps(config), encoding="utf-8")
            continue_to_lock.set()
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive(), "worker did not finish")
            self.assertNotIn("error", outcome)
            self.assertEqual(
                [str(old_source.resolve()), str(new_source.resolve())],
                outcome["sources"],
            )

    def test_state_directory_change_is_rejected_and_lock_released(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-state-race-") as root_text:
            root = Path(root_text)
            config_path = self._write_config(root)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            original_state = Path(config["state_directory"])
            changed_state = root / "changed-state"

            def change_state_before_lock() -> None:
                config["state_directory"] = str(changed_state)
                config_path.write_text(json.dumps(config), encoding="utf-8")

            with self.assertRaisesRegex(
                RuntimeError, "state_directory changed while waiting"
            ):
                restic_common.load_config_under_lock(
                    config_path,
                    require_repository=False,
                    before_lock=change_state_before_lock,
                )

            # The post-acquire validation exception must synchronously release
            # byte zero so another protected operation can proceed immediately.
            with restic_common.RunLock(original_state / "run.lock"):
                pass

    def test_pending_source_update_journal_fails_closed_and_releases_lock(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-journal-") as root_text:
            root = Path(root_text)
            config_path = self._write_config(root)
            config = json.loads(config_path.read_text(encoding="utf-8"))
            state = Path(config["state_directory"])
            state.mkdir(parents=True)
            journal = state / restic_common.SOURCE_UPDATE_JOURNAL_NAME
            journal.write_text("pending disposable transaction\n", encoding="utf-8")

            with self.assertRaisesRegex(
                restic_common.SourceUpdateJournalPresent,
                "source-update recovery is pending",
            ):
                restic_common.load_config_under_lock(
                    config_path,
                    require_repository=False,
                )

            # Detection happens after acquiring byte zero. The exceptional path
            # must release it synchronously so the protected manager can recover.
            with restic_common.RunLock(state / "run.lock"):
                pass

    def test_run_lock_closes_handle_even_if_explicit_unlock_setup_fails(self) -> None:
        class FailingHandle:
            def __init__(self) -> None:
                self.closed = False

            def seek(self, _position: int) -> None:
                raise OSError("simulated seek failure")

            def close(self) -> None:
                self.closed = True

        run_lock = restic_common.RunLock(Path("unused"))
        handle = FailingHandle()
        run_lock.handle = handle
        with self.assertRaisesRegex(OSError, "seek failure"):
            run_lock.__exit__(None, None, None)
        self.assertTrue(handle.closed)
        self.assertIsNone(run_lock.handle)

    def test_atomic_json_write_retries_transient_replace_failure(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-atomic-") as root_text:
            target = Path(root_text) / "status.json"
            real_replace = os.replace
            calls = 0

            def flaky_replace(source: Path, destination: Path) -> None:
                nonlocal calls
                calls += 1
                if calls < 3:
                    raise PermissionError(13, "simulated sharing violation")
                real_replace(source, destination)

            with (
                mock.patch("restic_common.os.replace", side_effect=flaky_replace),
                mock.patch("restic_common.time.sleep") as sleep,
            ):
                restic_common.atomic_write_json(target, {"state": "backing_up"})

            self.assertEqual(3, calls)
            self.assertEqual(2, sleep.call_count)
            self.assertEqual(
                {"state": "backing_up"},
                json.loads(target.read_text(encoding="utf-8")),
            )
            self.assertEqual([], list(target.parent.glob(".*.tmp")))

    def test_snapshot_selection_requires_exact_identity_and_uses_latest(self) -> None:
        config = {
            "hostname": "Backup-Host",
            "sources": [r"C:\BackupSource\Documents", r"D:\Projects"],
            "plan_id": "11111111-1111-4111-8111-111111111111",
            "config_generation": 1,
        }
        older = {
            "id": "older",
            "hostname": "BACKUP-HOST",
            "tags": [
                "scheduled",
                "restic-backuper-plan:11111111-1111-4111-8111-111111111111",
                "restic-backuper-generation:1",
            ],
            "paths": [r"d:\projects", r"c:\backupsource\documents"],
            "time": "2026-01-01T01:00:00Z",
        }
        newer = {**older, "id": "newer", "time": "2026-01-02T01:00:00Z"}
        unrelated = {**newer, "id": "wrong-host", "hostname": "OTHER-HOST"}

        selected = backup.select_snapshot(
            config, "scheduled", [unrelated, older, newer]
        )

        self.assertEqual("newer", selected["id"])
        with self.assertRaisesRegex(RuntimeError, "no snapshot exactly matches"):
            backup.select_snapshot(config, "manual", [older, newer])

    def test_json_line_parser_only_accepts_objects(self) -> None:
        self.assertEqual({"message_type": "status"}, backup.parse_json_lines(
            '{"message_type":"status"}'
        ))
        for value in ("not json", "[]", '"text"', "null"):
            with self.subTest(value=value):
                self.assertIsNone(backup.parse_json_lines(value))

    def test_restore_cleanup_cannot_escape_its_dedicated_parent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-cleanup-") as root_text:
            root = Path(root_text)
            base = root / "restore-tests"
            target = base / "one-run"
            outside = root / "keep-me"
            target.mkdir(parents=True)
            outside.mkdir()

            backup.safe_remove_restore_test(target, base)
            self.assertFalse(target.exists())

            with self.assertRaisesRegex(RuntimeError, "unsafe restore-test cleanup"):
                backup.safe_remove_restore_test(outside, base)

    def test_restore_source_selector_uses_exact_configured_root(self) -> None:
        configured = [r"Q:\Profiles\Example\Documents", r"D:\Photos"]
        selected = restore.select_configured_source(
            Path(r"q:\profiles\example\documents"), configured
        )
        self.assertEqual(str(selected), configured[0])
        self.assertEqual(
            restore.windows_snapshot_path(selected),
            "/Q/Profiles/Example/Documents",
        )

    def test_restore_source_selector_rejects_unrecorded_child(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly match"):
            restore.select_configured_source(
                Path(r"Q:\Profiles\Example\Documents\Subset"),
                [r"Q:\Profiles\Example\Documents"],
            )
            self.assertTrue(outside.is_dir())

    def test_sanitized_command_redacts_password_helper(self) -> None:
        command = [
            "restic.exe",
            "--password-command",
            "python secret_store.py reveal --secret-file secret.json",
            "snapshots",
        ]
        sanitized = restic_common.sanitized_command(command)
        self.assertEqual("<DPAPI password command>", sanitized[2])
        self.assertIn("secret_store.py", command[2])
        self.assertNotIn("secret_store.py", sanitized[2])

    def test_recovery_password_parser_requires_one_strong_value(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-recovery-") as root_text:
            key_file = Path(root_text) / "recovery.test.txt"
            password = "a" * 48
            key_file.write_text(
                f"RESTICBACKUPER TEST RECOVERY KEY\nPassword: {password}\n",
                encoding="utf-8",
            )
            self.assertEqual(password, restore.recovery_password(key_file))

            key_file.write_text("Password: too-short\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                restore.recovery_password(key_file)

    @unittest.skipUnless(os.name == "nt", "DPAPI is available only on Windows")
    def test_dpapi_round_trip_stays_in_current_user_context(self) -> None:
        value = b"ephemeral-unit-test-value"
        self.assertEqual(value, secret_store.unprotect(secret_store.protect(value)))

    def test_acl_verifier_accepts_current_builtin_administrator_alias(self) -> None:
        sddl = "D:P(A;OICI;FA;;;LA)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        with mock.patch("secret_store._dacl_sddl", return_value=sddl):
            secret_store.verify_restricted_acl(
                Path("protected"), "S-1-5-21-111-222-333-500"
            )

    def test_acl_verifier_rejects_builtin_administrator_for_other_users(self) -> None:
        sddl = "D:P(A;OICI;FA;;;LA)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
        with mock.patch("secret_store._dacl_sddl", return_value=sddl):
            with self.assertRaisesRegex(RuntimeError, "unexpected principal"):
                secret_store.verify_restricted_acl(
                    Path("protected"), "S-1-5-21-111-222-333-1001"
                )

    def test_stream_command_stops_child_when_progress_callback_fails(self) -> None:
        class FakeJob:
            def __enter__(self):
                return self

            def assign(self, _process) -> None:
                return None

            def __exit__(self, _exc_type, _exc_value, _traceback) -> None:
                return None

        class FakeProcess:
            def __init__(self) -> None:
                self.stdout = io.StringIO("status line\n")
                self.terminated = False
                self.wait_calls: list[int | None] = []

            def poll(self):
                return 1 if self.terminated else None

            def terminate(self) -> None:
                self.terminated = True

            def kill(self) -> None:
                raise AssertionError("kill should not be needed")

            def wait(self, timeout=None) -> int:
                self.wait_calls.append(timeout)
                return 1

        process = FakeProcess()
        with (
            mock.patch("restic_common.subprocess.Popen", return_value=process),
            mock.patch("restic_common._WindowsKillOnCloseJob", FakeJob),
        ):
            with self.assertRaisesRegex(PermissionError, "simulated telemetry failure"):
                restic_common.stream_command(
                    ["restic"],
                    io.StringIO(),
                    lambda _line: (_ for _ in ()).throw(
                        PermissionError("simulated telemetry failure")
                    ),
                )

        self.assertTrue(process.terminated)
        self.assertEqual(
            [restic_common.PROCESS_STOP_TIMEOUT_SECONDS], process.wait_calls
        )


if __name__ == "__main__":
    unittest.main()
