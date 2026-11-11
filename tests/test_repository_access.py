"""Backups with or without a password: the engine's one rule for how Restic opens them (restic_common)."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import restic_common
from restic_access import CONFLICT, EMPTY_NOT_ALLOWED, WRONG_PASSWORD, restic_access_result


SANITIZED_WORDS = ("password", "dpapi", "restic_")


def write_config(root: Path, **extra) -> Path:
    """A minimal valid backup-config.json (as tests/test_core.py writes it), plus `extra` keys."""
    source = root / "source"
    source.mkdir(exist_ok=True)
    restic = root / "restic.exe"
    restic.write_bytes(b"test fixture; not an executable")
    excludes = root / "excludes.txt"
    excludes.write_text("**/__pycache__\n", encoding="utf-8")
    canary = root / "canary.txt"
    canary.write_text("ResticBackuper test canary\n", encoding="utf-8")
    config = {
        "schema_version": 1,
        "plan_id": "11111111-1111-4111-8111-111111111111",
        "config_generation": 1,
        "repository": str(root / "repository"),
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
        "sources": [str(source)],
        "source_identities": {str(source): {"expected_volume_serial": "00000000"}},
    }
    config.update(extra)
    path = root / "backup-config.test.json"
    path.write_text(json.dumps(config), encoding="utf-8")
    return path


class RepositoryAccessRuleTests(unittest.TestCase):
    def test_absent_means_password(self) -> None:
        self.assertEqual("password", restic_common.repository_access({}))

    def test_the_two_values_are_accepted_exactly(self) -> None:
        self.assertEqual("password", restic_common.repository_access({"repository_access": "password"}))
        self.assertEqual("no_password", restic_common.repository_access({"repository_access": "no_password"}))

    def test_anything_else_is_refused_and_never_defaulted(self) -> None:
        for value in ("Password", "NO_PASSWORD", "no-password", "none", "", " password", None, 0, 5, True, [], {}):
            with self.subTest(value=value):
                with self.assertRaises(ValueError) as caught:
                    restic_common.repository_access({"repository_access": value})
                # Rewindle's log filters hide a whole message that contains one of these words.
                for word in SANITIZED_WORDS:
                    self.assertNotIn(word, str(caught.exception).lower().replace("repository_access", ""))

    def test_load_config_records_the_access_and_defaults_an_old_configuration(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            old = restic_common.load_config(write_config(root), require_repository=False)
            self.assertEqual("password", old["repository_access"])
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            chosen = restic_common.load_config(
                write_config(root, repository_access="no_password"), require_repository=False
            )
            self.assertEqual("no_password", chosen["repository_access"])

    def test_load_config_refuses_an_unsupported_access(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            with self.assertRaises(ValueError):
                restic_common.load_config(write_config(root, repository_access="nopassword"), require_repository=False)


class ResticArgumentTests(unittest.TestCase):
    def config(self, root: Path, access: str | None) -> dict:
        config = {
            "restic_executable": str(root / "restic.exe"),
            "repository": str(root / "repository"),
            "state_directory": str(root / "state"),
            "python_executable": sys.executable,
            "secret_file": str(root / "state" / "password.test.json"),
        }
        if access is not None:
            config["repository_access"] = access
        return config

    def test_password_mode_command_is_unchanged(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            for access in (None, "password"):
                with self.subTest(access=access):
                    config = self.config(root, access)
                    command = restic_common.restic_base(config, json_output=True)
                    self.assertEqual(
                        [
                            config["restic_executable"],
                            "--repo",
                            config["repository"],
                            "--password-command",
                            restic_common.password_command(config),
                            "--cache-dir",
                            str(root / "state" / "cache"),
                            "--retry-lock",
                            "5m",
                            "--json",
                        ],
                        command,
                    )
                    self.assertNotIn(restic_common.NO_PASSWORD_FLAG, command)

    def test_no_password_mode_has_the_flag_and_no_password_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            config = self.config(root, "no_password")
            command = restic_common.restic_base(config)
            self.assertEqual(
                [
                    config["restic_executable"],
                    "--repo",
                    config["repository"],
                    "--insecure-no-password",
                    "--cache-dir",
                    str(root / "state" / "cache"),
                    "--retry-lock",
                    "5m",
                ],
                command,
            )
            self.assertEqual(["--insecure-no-password"], restic_common.restic_credential_arguments(config))
            self.assertIsNone(restic_access_result(command, restic_common.restic_child_environment(command), "no_password"))

    def test_no_reveal_command_is_ever_built_without_a_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-access-") as root_text:
            root = Path(root_text)
            with self.assertRaises(RuntimeError):
                restic_common.password_command(self.config(root, "no_password"))
            with self.assertRaises(ValueError):
                restic_common.restic_base(self.config(root, "bogus"))

    def test_the_child_environment_refuses_a_password_source_next_to_the_flag(self) -> None:
        flag = restic_common.NO_PASSWORD_FLAG
        with self.assertRaises(ValueError):
            restic_common.restic_child_environment(["restic.exe", flag, "snapshots"], password="secret")
        for source in (
            ["--password-command", "reveal"],
            ["--password-command=reveal"],
            ["--password-file", "key.txt"],
            ["--password-file=key.txt"],
            ["--new-password-file", "new.txt"],
        ):
            with self.subTest(source=source):
                with self.assertRaises(ValueError) as caught:
                    restic_common.restic_child_environment(["restic.exe", "--repo", "R", flag, *source, "snapshots"])
                for word in ("dpapi", "restic_"):
                    self.assertNotIn(word, str(caught.exception).lower())
        environment = restic_common.restic_child_environment(["restic.exe", "--repo", "R", flag, "snapshots"])
        self.assertFalse([name for name in environment if name.upper().startswith("RESTIC_")])
        # Password mode keeps working as before.
        restic_common.restic_child_environment(["restic.exe", "--password-command", "reveal", "snapshots"])
        self.assertEqual(
            "secret",
            restic_common.restic_child_environment(["restic.exe", "--repo", "R", "snapshots"], password="secret")[
                "RESTIC_PASSWORD"
            ],
        )

    def test_mismatch_failure_has_its_own_code(self) -> None:
        self.assertEqual("repository_access_mismatch", restic_common.RepositoryAccessMismatch.failure_code)
        self.assertTrue(issubclass(restic_common.RepositoryAccessMismatch, restic_common.EngineFailure))


class FakeRun:
    def __init__(self, returncode: int | None = 0, error: BaseException | None = None) -> None:
        self.returncode = returncode
        self.error = error
        self.calls: list[tuple[list[str], dict]] = []

    def __call__(self, command, **options):
        self.calls.append((list(command), options))
        if self.error is not None:
            raise self.error
        return subprocess.CompletedProcess(command, self.returncode, b'{"version":2}', b"Fatal: something restic said")


class AccessProbeTests(unittest.TestCase):
    def probe(self, repository: Path, runner: FakeRun) -> str:
        return restic_common.probe_repository_access("C:/fake/restic.exe", repository, runner=runner, timeout_seconds=7)

    def test_exit_codes_map_to_access(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text) / "repository"
            repository.mkdir()
            self.assertEqual("no_password", self.probe(repository, FakeRun(0)))
            self.assertEqual("password", self.probe(repository, FakeRun(12)))
            self.assertEqual("missing", self.probe(repository, FakeRun(10)))
            for code in (1, 2, 3, 11, 130, -1):
                with self.subTest(code=code):
                    self.assertEqual("unknown", self.probe(repository, FakeRun(code)))
            # Restic saying "no repository" next to a config file means the location can't be read properly (a Google
            # Drive folder still syncing, say), never that there are no backups.
            (repository / "config").write_bytes(b"x")
            self.assertEqual("unknown", self.probe(repository, FakeRun(10)))

    def test_time_out_and_start_failure_are_unknown(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text)
            self.assertEqual(
                "unknown", self.probe(repository, FakeRun(error=subprocess.TimeoutExpired(["restic"], 7)))
            )
            self.assertEqual("unknown", self.probe(repository, FakeRun(error=FileNotFoundError("restic.exe"))))

    def test_the_probe_reads_only_and_never_gives_a_password(self) -> None:
        with tempfile.TemporaryDirectory(prefix="resticbackuper-probe-") as root_text:
            repository = Path(root_text)
            runner = FakeRun(0)
            self.probe(repository, runner)
            command, options = runner.calls[0]
            self.assertEqual(
                [
                    "C:/fake/restic.exe",
                    "--repo",
                    str(repository),
                    "--insecure-no-password",
                    "--no-lock",
                    "--no-cache",
                    "cat",
                    "config",
                ],
                command,
            )
            self.assertIs(subprocess.DEVNULL, options["stdin"])
            self.assertEqual(7, options["timeout"])
            self.assertFalse(options["shell"])
            self.assertFalse([name for name in options["env"] if name.upper().startswith("RESTIC_")])
            self.assertIsNone(restic_access_result(command, options["env"], "no_password"))


class FakeContractTests(unittest.TestCase):
    """The shared fake rules (tests/restic_access.py) match what Restic 0.19.1 does."""

    def test_rules(self) -> None:
        flag = "--insecure-no-password"
        self.assertEqual((1, CONFLICT), restic_access_result(["restic", flag, "--password-command", "x"], {}, "no_password"))
        self.assertEqual((1, CONFLICT), restic_access_result(["restic", flag], {"RESTIC_PASSWORD": "x"}, "no_password"))
        self.assertIsNone(restic_access_result(["restic", flag], {"RESTIC_PASSWORD": ""}, "no_password"))
        self.assertEqual((1, EMPTY_NOT_ALLOWED), restic_access_result(["restic", "snapshots"], {}, "no_password"))
        self.assertEqual((12, WRONG_PASSWORD), restic_access_result(["restic", flag, "snapshots"], {}, "password"))
        self.assertIsNone(restic_access_result(["restic", "--password-command", "x"], {}, "password"))


if __name__ == "__main__":
    unittest.main()
