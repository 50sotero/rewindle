from __future__ import annotations

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SRC = PROJECT / "src"
sys.path.insert(0, str(SRC))
sys.path.insert(0, str(Path(__file__).resolve().parent))
RESTIC = PROJECT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"

import key_rotation  # noqa: E402
import test_credential_repair as repair_fixture  # noqa: E402
from recovery_health import authenticate, parse_recovery_key  # noqa: E402
from restic_common import RunLock, load_config, restic_base  # noqa: E402
from secret_store import create_secret, load_secret, write_recovery_key  # noqa: E402


PYTHON = Path(sys.executable)
SID = "S-1-5-21-1000-2000-3000-4000"


def volume_serial(path: Path) -> str:
    drive = Path(path).resolve().drive.upper()
    script = (
        f"$v=Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='{drive}'\";"
        "$v.VolumeSerialNumber"
    )
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    return result.stdout.strip().upper()


class KeyRotationFixture:
    def __init__(self, root: Path):
        self.root = root
        self.repository = root / "repository"
        self.state = root / "state"
        self.source = root / "source"
        self.source.mkdir()
        self.canary = self.source / "canary.txt"
        self.canary.write_text("rotation canary\n", encoding="utf-8")
        self.excludes = root / "excludes.txt"
        self.excludes.write_text("**/__pycache__\n", encoding="utf-8")
        self.config_path = root / "backup-config.json"
        shutil.copy2(SRC / "secret_store.py", root / "secret_store.py")
        self.recovery_key = root / "RecoveryKey.txt"
        self.config = {
            "schema_version": 1,
            "plan_id": "10000000-0000-4000-8000-000000000077",
            "config_generation": 1,
            "repository": str(self.repository),
            "repository_volume_serial": volume_serial(root),
            "restic_executable": str(RESTIC),
            "recovery_tools_directory": str(root / "recovery-tools"),
            "python_executable": str(PYTHON),
            "state_directory": str(self.state),
            "secret_file": str(self.state / "repository-password.dpapi.json"),
            "recovery_key_file": str(self.recovery_key),
            "exclude_file": str(self.excludes),
            "canary_file": str(self.canary),
            "hostname": "KEY-ROTATION-TEST",
            "scheduled_tag": "rotation-test",
            "minimum_free_gib": 0,
            "read_concurrency": 2,
            "use_vss": False,
            "structural_check_after_backup": False,
            "read_data_subset_weekday": "Never",
            "read_data_subset_parts": 0,
            "cloud_placeholder_policy": "strict",
            "sources": [str(self.source)],
            "source_identities": {
                str(self.source): {"expected_volume_serial": volume_serial(self.source)}
            },
        }
        self.config_path.write_text(json.dumps(self.config), encoding="utf-8")
        password = create_secret(Path(self.config["secret_file"]))
        write_recovery_key(self.recovery_key, self.repository, password)
        environment = os.environ.copy()
        environment["RESTIC_PASSWORD"] = password
        initialized = subprocess.run(
            [str(RESTIC), "init", "--repo", str(self.repository)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=90,
            env=environment,
        )
        if initialized.returncode != 0:
            raise AssertionError(initialized.stderr)

    def rotate(self):
        return key_rotation.rotate(
            self.config_path,
            expected_config_sha256=key_rotation.sha256_file(self.config_path),
            expected_plan_id=self.config["plan_id"],
            expected_generation=1,
            expected_user_sid=SID,
            sid_reader=lambda: SID,
            require_manifest=False,
        )


@unittest.skipUnless(RESTIC.is_file(), "build the release artifact before key-rotation integration tests")
class KeyRotationTests(unittest.TestCase):
    def test_rotation_adds_and_proves_new_key_while_retaining_previous(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-rotation-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            old_password = load_secret(Path(fixture.config["secret_file"]))
            old_recovery_hash = key_rotation.sha256_file(fixture.recovery_key)
            data_before = sorted(
                (str(path.relative_to(fixture.repository)), path.read_bytes())
                for directory in ("data", "snapshots")
                for path in (fixture.repository / directory).rglob("*")
                if path.is_file()
            )

            result = fixture.rotate()

            self.assertEqual("rotated", result["state"])
            self.assertTrue(result["previous_repository_key_retained"])
            self.assertFalse(result["snapshots_modified"])
            self.assertFalse(result["repository_data_modified"])
            self.assertGreaterEqual(result["repository_key_count"], 2)
            previous = Path(result["previous_recovery_file"])
            self.assertTrue(previous.is_file())
            self.assertEqual(old_recovery_hash, key_rotation.sha256_file(previous))

            new_password = load_secret(Path(fixture.config["secret_file"]))
            self.assertNotEqual(old_password, new_password)
            self.assertEqual(
                new_password,
                parse_recovery_key(fixture.recovery_key, fixture.repository),
            )
            self.assertEqual(old_password, parse_recovery_key(previous, fixture.repository))

            environment = os.environ.copy()
            environment["RESTIC_PASSWORD"] = old_password
            try:
                old_id, _ = authenticate(
                    RESTIC,
                    fixture.repository,
                    [],
                    environment=environment,
                )
            finally:
                environment.pop("RESTIC_PASSWORD", None)
            self.assertEqual(result["repository_id"], old_id)
            self.assertNotEqual(result["previous_key_id"], result["new_key_id"])
            self.assertFalse((fixture.state / key_rotation.JOURNAL_NAME).exists())
            self.assertTrue((fixture.state / key_rotation.LATEST_NAME).is_file())
            history = json.loads(
                (fixture.state / key_rotation.HISTORY_NAME).read_text(encoding="utf-8")
            )
            self.assertEqual(result["rotation_id"], history["rotations"][-1]["rotation_id"])
            data_after = sorted(
                (str(path.relative_to(fixture.repository)), path.read_bytes())
                for directory in ("data", "snapshots")
                for path in (fixture.repository / directory).rglob("*")
                if path.is_file()
            )
            self.assertEqual(data_before, data_after)

    def test_interrupted_publish_is_resumed_from_protected_journal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-resume-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            real_replace = key_rotation.replace_secret
            with mock.patch.object(
                key_rotation,
                "replace_secret",
                side_effect=RuntimeError("injected publish interruption"),
            ):
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    fixture.rotate()
            journal = fixture.state / key_rotation.JOURNAL_NAME
            self.assertTrue(journal.is_file())
            document = json.loads(journal.read_text(encoding="utf-8"))
            self.assertEqual("repository_key_added", document["phase"])
            self.assertTrue(Path(document["pending_recovery_file"]).is_file())

            with mock.patch.object(key_rotation, "replace_secret", side_effect=real_replace):
                recovered = fixture.rotate()
            self.assertEqual("rotated", recovered["state"])
            self.assertFalse(journal.exists())
            self.assertTrue(Path(recovered["previous_recovery_file"]).is_file())
            self.assertEqual(
                load_secret(Path(fixture.config["secret_file"])),
                parse_recovery_key(fixture.recovery_key, fixture.repository),
            )

    def test_binding_and_global_run_lock_fail_before_repository_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-binding-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            keys_before = sorted(path.name for path in (fixture.repository / "keys").iterdir())
            with self.assertRaisesRegex(RuntimeError, "configuration changed"):
                key_rotation.rotate(
                    fixture.config_path,
                    expected_config_sha256="0" * 64,
                    expected_plan_id=fixture.config["plan_id"],
                    expected_generation=1,
                    expected_user_sid=SID,
                    sid_reader=lambda: SID,
                    require_manifest=False,
                )
            with RunLock(fixture.state / "run.lock"):
                with self.assertRaises(Exception):
                    fixture.rotate()
            self.assertEqual(
                keys_before,
                sorted(path.name for path in (fixture.repository / "keys").iterdir()),
            )
            self.assertFalse((fixture.state / key_rotation.JOURNAL_NAME).exists())

    def test_normal_runtime_refuses_pending_rotation_journal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-key-journal-gate-") as root_text:
            fixture = KeyRotationFixture(Path(root_text))
            journal = fixture.state / key_rotation.JOURNAL_NAME
            key_rotation._write_protected_json(journal, {"schema_version": 1})
            with self.assertRaisesRegex(RuntimeError, "credential-rotation.journal.json"):
                config, lock = key_rotation.load_config_under_lock(fixture.config_path)
                lock.__exit__(None, None, None)


NO_KEYS_TO_ROTATE = "This backup opens without a key, so there are no keys to rotate."


def forbid_reads() -> contextlib.ExitStack:
    """Every way key_rotation reads or changes a key, a secret or a journal, or touches Restic, fails the test."""
    stack = contextlib.ExitStack()
    for name in (
        "_read_json",
        "_finish_rotation",
        "_write_protected_json",
        "_restic_result",
        "_authenticate_plaintext",
        "load_secret",
        "replace_secret",
        "write_recovery_key",
        "parse_recovery_key",
        "load_config_under_lock",
        "authenticate",
        "validate_runtime_manifest",
    ):
        stack.enter_context(
            mock.patch.object(key_rotation, name, side_effect=AssertionError(f"{name} was called"))
        )
    return stack


def snapshot(root: Path) -> dict[str, bytes]:
    return {str(path.relative_to(root)): path.read_bytes() for path in sorted(root.rglob("*")) if path.is_file()}


class KeyRotationWithoutKeyTests(unittest.TestCase):
    """Backups made without a password have no keys to rotate: refused at once, nothing read or changed."""

    def rotate_config(self, config_path: Path, **overrides: object):
        parameters = {
            "expected_config_sha256": key_rotation.sha256_file(config_path),
            "expected_plan_id": repair_fixture.PLAN_ID,
            "expected_generation": 4,
            "expected_user_sid": repair_fixture.SID,
            "sid_reader": lambda: repair_fixture.SID,
            "acl_verifier": lambda path: self.fail("a key file was looked at"),
            "runner": lambda *arguments, **keywords: self.fail("Restic was started"),
        }
        parameters.update(overrides)
        return key_rotation.rotate(config_path, **parameters)

    def test_a_backup_without_a_password_is_refused_before_the_journal_is_read(self) -> None:
        for journal in (None, "an unfinished rotation of an older backup"):
            with self.subTest(journal=journal), tempfile.TemporaryDirectory(prefix="rotation-no-password-") as root_text:
                root = Path(root_text)
                config_path, config = repair_fixture.build_fixture(
                    root, access="no_password", leftover_key_files=True
                )
                if journal is not None:
                    (Path(config["state_directory"]) / key_rotation.JOURNAL_NAME).write_text(
                        journal, encoding="utf-8"
                    )
                before = snapshot(root)

                with forbid_reads(), self.assertRaises(RuntimeError) as caught:
                    # require_manifest left on: the refusal comes before even the runtime manifest is read.
                    self.rotate_config(config_path)

                self.assertEqual(NO_KEYS_TO_ROTATE, str(caught.exception))
                self.assertEqual(before, snapshot(root), "nothing was created, changed or removed")
                # The message reaches the owner: no log filter turns it into "without exposing credential details".
                self.assertEqual(NO_KEYS_TO_ROTATE, key_rotation.sanitize(NO_KEYS_TO_ROTATE))

    def test_the_tool_reports_the_refusal_as_a_failed_run(self) -> None:
        if sys.platform != "win32":
            self.skipTest("the approving Windows account is a Windows notion")
        from secret_store import _current_user_sid

        with tempfile.TemporaryDirectory(prefix="rotation-no-password-main-") as root_text:
            config_path, _ = repair_fixture.build_fixture(Path(root_text), access="no_password")
            output = io.StringIO()
            arguments = [
                "--config",
                str(config_path),
                "--expected-config-sha256",
                key_rotation.sha256_file(config_path),
                "--expected-plan-id",
                repair_fixture.PLAN_ID,
                "--expected-generation",
                "4",
                "--expected-user-sid",
                _current_user_sid(),
            ]
            with mock.patch.object(key_rotation, "is_administrator", return_value=True):
                with forbid_reads(), contextlib.redirect_stdout(output):
                    exit_code = key_rotation.main(arguments)
            self.assertEqual(2, exit_code)
            result = json.loads(output.getvalue())
            self.assertEqual("failed", result["state"])
            self.assertEqual(NO_KEYS_TO_ROTATE, result["error"])

    def test_an_unsupported_value_is_refused_before_the_run_lock_is_taken(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rotation-bad-mode-") as root_text:
            config_path, config = repair_fixture.build_fixture(Path(root_text))
            config["repository_access"] = "No_Password"
            config_path.write_text(json.dumps(config), encoding="utf-8")
            with forbid_reads(), self.assertRaisesRegex(ValueError, "^unsupported repository_access$"):
                self.rotate_config(config_path)

    def test_a_backup_with_a_password_still_resumes_its_pending_rotation(self) -> None:
        for access in (None, "password"):
            with self.subTest(access=access), tempfile.TemporaryDirectory(prefix="rotation-password-") as root_text:
                config_path, config = repair_fixture.build_fixture(Path(root_text), access=access)
                (Path(config["state_directory"]) / key_rotation.JOURNAL_NAME).write_text("{}", encoding="utf-8")
                finished = {"state": "rotated"}
                with mock.patch.object(key_rotation, "_read_json", return_value={"phase": "prepared"}), mock.patch.object(
                    key_rotation, "_finish_rotation", return_value=finished
                ) as finish:
                    result = self.rotate_config(config_path, require_manifest=False)
                self.assertIs(finished, result)
                finish.assert_called_once()


@unittest.skipUnless(RESTIC.is_file(), "build the release artifact before key-rotation integration tests")
class KeyRotationWithoutKeyRealResticTests(unittest.TestCase):
    def test_the_keys_of_a_backup_without_a_password_are_left_as_they_are(self) -> None:
        with tempfile.TemporaryDirectory(prefix="restic-rotation-no-password-") as root_text:
            root = Path(root_text)
            config_path, config = repair_fixture.build_fixture(root, access="no_password")
            repository = Path(config["repository"])
            # The fixture's stand-in repository file is replaced by a real backup location made without a password.
            (repository / "config").unlink()
            environment = {name: value for name, value in os.environ.items() if not name.startswith("RESTIC_")}
            initialized = subprocess.run(
                [str(RESTIC), "init", "--repo", str(repository), "--insecure-no-password"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=90,
                env=environment,
            )
            self.assertEqual(0, initialized.returncode, initialized.stderr)
            before = snapshot(repository)
            self.assertEqual(1, len([name for name in before if name.startswith("keys")]))

            with self.assertRaises(RuntimeError) as caught:
                key_rotation.rotate(
                    config_path,
                    expected_config_sha256=key_rotation.sha256_file(config_path),
                    expected_plan_id=repair_fixture.PLAN_ID,
                    expected_generation=4,
                    expected_user_sid=repair_fixture.SID,
                    sid_reader=lambda: repair_fixture.SID,
                    require_manifest=False,
                )

            self.assertEqual(NO_KEYS_TO_ROTATE, str(caught.exception))
            self.assertEqual(before, snapshot(repository))


if __name__ == "__main__":
    unittest.main()
