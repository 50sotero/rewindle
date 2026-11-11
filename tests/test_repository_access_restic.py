"""Backups without a password with the pinned Restic 0.19.1, in throwaway repositories.

CI runs this module after the release build with REWINDLE_REQUIRE_PINNED_RESTIC=1, so a missing restic.exe fails there
instead of skipping. Locally it runs when build\\build-output\\ResticBackuper\\payload\\restic.exe is the pinned release.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
RESTIC = PROJECT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"
INITIALIZER = SOURCE / "initialize_repository.py"
# Set by CI's step after the release build: there, a missing pinned restic.exe fails instead of skipping.
REQUIRE_PINNED_RESTIC = os.environ.get("REWINDLE_REQUIRE_PINNED_RESTIC") == "1"
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

import initialize_repository  # noqa: E402
import restic_common  # noqa: E402
import secret_store  # noqa: E402
from restic_access import CONFLICT, EMPTY_NOT_ALLOWED, WRONG_PASSWORD  # noqa: E402


def pinned_restic_present() -> bool:
    if not RESTIC.is_file():
        return False
    release = json.loads((SOURCE / "restic-release.json").read_text(encoding="utf-8"))
    return restic_common.sha256_file(RESTIC) == release["executable_sha256"]


def tree_fingerprint(root: Path) -> dict[str, str]:
    """Every file below root with its SHA-256, so a test can prove nothing was added, changed or removed."""
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


@unittest.skipUnless(
    os.name == "nt" and (pinned_restic_present() or REQUIRE_PINNED_RESTIC),
    "needs the release build's pinned restic.exe (run build\\Build-Release.ps1)",
)
class PinnedResticNoPasswordTests(unittest.TestCase):
    """What Rewindle's code does with real backups made with and without a password."""

    @classmethod
    def setUpClass(cls) -> None:
        if not pinned_restic_present():
            raise AssertionError(
                f"REWINDLE_REQUIRE_PINNED_RESTIC is set, but {RESTIC} is missing or is not the pinned release"
            )
        cls._temporary = tempfile.TemporaryDirectory(prefix="no-password-restic-")
        # The long form of the folder: CI's TEMP is an 8.3 short path, and Restic records the path it is given.
        cls.root = Path(cls._temporary.name).resolve()
        # Only what Restic needs: no inherited RESTIC_* setting can point it at any other backup.
        cls.environment = {name: os.environ[name] for name in ("SYSTEMROOT", "TEMP", "TMP") if name in os.environ}
        cls.password_file = cls.root / "password.txt"
        cls.password_file.write_text("no-password-restic-test-only\n", encoding="utf-8")
        fixtures = cls.root / "fixtures"
        fixtures.mkdir()
        cls.no_password = fixtures / "no-password"
        cls.restic_ok("init", "--repo", str(cls.no_password), "--insecure-no-password", "--repository-version", "2")
        cls.password = fixtures / "password"
        cls.restic_ok("init", "--repo", str(cls.password), "--password-file", str(cls.password_file),
                      "--repository-version", "2")
        cls.dual = fixtures / "dual"
        cls.restic_ok("init", "--repo", str(cls.dual), "--password-file", str(cls.password_file),
                      "--repository-version", "2")
        cls.restic_ok("--repo", str(cls.dual), "--password-file", str(cls.password_file), "key", "add",
                      "--new-insecure-no-password")
        cls.empty_keys = fixtures / "empty-keys"
        shutil.copytree(cls.no_password, cls.empty_keys)
        for key in (cls.empty_keys / "keys").iterdir():
            key.unlink()
        cls.damaged_key = fixtures / "damaged-key"
        shutil.copytree(cls.no_password, cls.damaged_key)
        (key,) = list((cls.damaged_key / "keys").iterdir())
        key.write_bytes(b'{"created": "not a key"}')
        cls.truncated_config = fixtures / "truncated-config"
        shutil.copytree(cls.no_password, cls.truncated_config)
        config = cls.truncated_config / "config"
        config.write_bytes(config.read_bytes()[:10])
        cls.empty_folder = fixtures / "empty-folder"
        cls.empty_folder.mkdir()
        cls.missing = fixtures / "missing"

    @classmethod
    def tearDownClass(cls) -> None:
        cls._temporary.cleanup()

    @classmethod
    def restic(cls, *arguments: str, extra_environment: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        environment = dict(cls.environment)
        environment.update(extra_environment or {})
        # --no-cache: the trimmed environment has no LocalAppData for Restic's default cache, and these fixtures need none.
        return subprocess.run(
            [str(RESTIC), "--no-cache", *arguments],
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=180,
            creationflags=CREATE_NO_WINDOW,
        )

    @classmethod
    def restic_ok(cls, *arguments: str) -> subprocess.CompletedProcess:
        result = cls.restic(*arguments)
        if result.returncode != 0:
            raise AssertionError(f"restic {' '.join(arguments[:3])} failed with {result.returncode}: {result.stderr}")
        return result

    def copy_of(self, fixture: Path) -> Path:
        temporary = tempfile.mkdtemp(prefix="copy-", dir=self.root)
        target = Path(temporary) / fixture.name
        shutil.copytree(fixture, target)
        return target

    def test_restic_refuses_as_the_shared_fakes_say(self) -> None:
        # Opened without the flag (stdin closed): refused at once, not a prompt.
        result = self.restic("--repo", str(self.no_password), "cat", "config")
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn(EMPTY_NOT_ALLOWED.removeprefix("Fatal: "), result.stderr)
        # The flag next to a password source: refused.
        for source in (["--password-file", str(self.password_file)],):
            with self.subTest(source=source):
                result = self.restic("--repo", str(self.no_password), "--insecure-no-password", *source, "cat", "config")
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertIn(CONFLICT.removeprefix("Fatal: "), result.stderr)
        result = self.restic("--repo", str(self.no_password), "--insecure-no-password", "cat", "config",
                             extra_environment={"RESTIC_PASSWORD": "anything"})
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn(CONFLICT.removeprefix("Fatal: "), result.stderr)
        # The flag on backups with a password: no key opens.
        result = self.restic("--repo", str(self.password), "--insecure-no-password", "cat", "config")
        self.assertEqual(12, result.returncode, result.stderr)
        self.assertIn(WRONG_PASSWORD.removeprefix("Fatal: "), result.stderr)

    def test_the_probe_tells_each_kind_of_location_apart(self) -> None:
        expected = {
            self.no_password: "no_password",
            self.password: "password",
            self.dual: "no_password",
            self.empty_keys: "password",
            self.damaged_key: "unknown",
            self.truncated_config: "unknown",
            self.empty_folder: "missing",
            self.missing: "missing",
        }
        for location, access in expected.items():
            with self.subTest(location=location.name):
                self.assertEqual(access, restic_common.probe_repository_access(RESTIC, location, timeout_seconds=120))

    def test_the_probe_changes_nothing(self) -> None:
        for fixture in (self.no_password, self.password, self.damaged_key):
            with self.subTest(fixture=fixture.name):
                location = self.copy_of(fixture)
                before = tree_fingerprint(location)
                restic_common.probe_repository_access(RESTIC, location, timeout_seconds=120)
                self.assertEqual(before, tree_fingerprint(location))

    def test_detect_access_answers_with_its_exit_codes(self) -> None:
        expected = {
            self.no_password: 20,
            self.password: 21,
            self.dual: 20,
            self.empty_keys: 21,
            self.damaged_key: 6,
            self.truncated_config: 6,
            self.empty_folder: 22,
            self.missing: 22,
        }
        for location, code in expected.items():
            with self.subTest(location=location.name):
                result = subprocess.run(
                    [sys.executable, "-I", "-S", "-B", str(INITIALIZER), "--detect-access",
                     "--repository", str(location), "--restic", str(RESTIC)],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=240,
                    creationflags=CREATE_NO_WINDOW,
                )
                self.assertEqual(code, result.returncode, result.stderr)
                # Restic's own words never reach Setup's console.
                self.assertNotIn("Fatal", result.stdout + result.stderr)

    def test_every_engine_command_opens_backups_without_a_password(self) -> None:
        repository = self.copy_of(self.no_password)
        state = self.root / f"state-{repository.parent.name}"
        source = self.root / f"source-{repository.parent.name}"
        (source / "folder").mkdir(parents=True)
        (source / "folder" / "note.txt").write_text("no-password backup\n", encoding="utf-8", newline="\n")
        restored = self.root / f"restored-{repository.parent.name}"
        config = {
            "restic_executable": str(RESTIC),
            "repository": str(repository),
            "state_directory": str(state),
            "repository_access": "no_password",
            "python_executable": sys.executable,
            "secret_file": str(state / "never-created.json"),
        }

        def run(*arguments: str, json_output: bool = False) -> subprocess.CompletedProcess:
            command = restic_common.restic_base(config, json_output=json_output) + list(arguments)
            self.assertIn("--insecure-no-password", command)
            self.assertNotIn("--password-command", command)
            result = restic_common.run_capture(command)
            self.assertEqual(0, result.returncode, f"{arguments[:2]}: {result.stderr}")
            return result

        run("backup", str(source), "--host", "no-password-test", "--tag", "no-password-test")
        snapshots = json.loads(run("snapshots", json_output=True).stdout)
        self.assertEqual(1, len(snapshots))
        run("ls", "latest")
        run("find", "note.txt")
        # As restore.py does, restore one folder of the snapshot ("<snapshot>:<folder>"): a whole-snapshot restore would
        # recreate the absolute path's parents with their real permissions (C:\Users), which the test could not remove.
        nodes = [json.loads(line) for line in run("ls", "latest", json_output=True).stdout.splitlines() if line.strip()]
        (note_node,) = [node for node in nodes if node.get("name") == "note.txt"]
        folder_in_snapshot = note_node["path"].rsplit("/", 1)[0]
        run("restore", f"latest:{folder_in_snapshot}", "--target", str(restored))
        self.assertEqual("no-password backup\n", (restored / "note.txt").read_text(encoding="utf-8"))
        run("check")
        run("check", "--read-data-subset", "1/1")
        run("stats")
        run("cat", "config")
        run("key", "list")
        run("list", "locks")
        run("unlock")
        run("backup", str(source), "--host", "no-password-test", "--tag", "no-password-test")
        run("forget", "--keep-last", "1", "--prune")
        self.assertEqual(1, len(json.loads(run("snapshots", json_output=True).stdout)))
        self.assertFalse((state / "never-created.json").exists())

    def write_initializer_config(self, repository: Path, access: str | None) -> tuple[Path, dict]:
        """A complete configuration for the real initializer, in its own folders (as tests/Test-ReleaseArtifact.ps1)."""
        case = Path(tempfile.mkdtemp(prefix="init-", dir=self.root))
        source = case / "source"
        source.mkdir()
        canary = source / "backup-canary.txt"
        canary.write_text("no-password initializer canary\n", encoding="utf-8")
        excludes = case / "excludes.txt"
        excludes.write_text("**/__pycache__\n", encoding="utf-8")
        serial = restic_common.volume_serial(case)
        config = {
            "schema_version": 1,
            "plan_id": "22222222-2222-4222-8222-222222222222",
            "config_generation": 1,
            "repository": str(repository),
            "repository_volume_serial": serial,
            "restic_executable": str(RESTIC),
            "recovery_tools_directory": str(case / "RecoveryTools"),
            "python_executable": sys.executable,
            "state_directory": str(case / "state"),
            "secret_file": str(case / "state" / "repository-password.dpapi.json"),
            "recovery_key_file": str(case / "RecoveryKey.txt"),
            "exclude_file": str(excludes),
            "canary_file": str(canary),
            "hostname": "RESTICBACKUPER-NO-PASSWORD-TEST",
            "scheduled_tag": "no-password-test",
            "minimum_free_gib": 0,
            "cloud_placeholder_policy": "strict",
            "sources": [str(source)],
            "source_identities": {str(source): {"expected_volume_serial": serial}},
        }
        if access is not None:
            config["repository_access"] = access
        path = case / "backup-config.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        return path, config

    def initialize(self, config_path: Path, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-B", str(INITIALIZER), "--config", str(config_path), *extra],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=600,
            creationflags=CREATE_NO_WINDOW,
        )

    def test_the_initializer_makes_new_backups_without_a_password(self) -> None:
        repository = Path(tempfile.mkdtemp(prefix="new-", dir=self.root)) / "Backups"
        config_path, config = self.write_initializer_config(repository, "no_password")
        result = self.initialize(config_path)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("no_password", restic_common.probe_repository_access(RESTIC, repository, timeout_seconds=120))
        self.assertFalse(Path(config["secret_file"]).exists())
        self.assertFalse(Path(config["recovery_key_file"]).exists())
        record = json.loads((Path(config["state_directory"]) / "repository.json").read_text(encoding="utf-8"))
        self.assertEqual("no_password", record["repository_access"])
        manifest = json.loads(
            (Path(config["recovery_tools_directory"]) / "recovery-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual("no_password", manifest["repository_access"])
        self.assertNotIn("knowledge of your password", result.stdout + result.stderr)
        # Committing a recovery key, as every install does at its end, changes nothing for these backups.
        commit = self.initialize(config_path, "--commit-recovery-key")
        self.assertEqual(0, commit.returncode, commit.stderr)
        self.assertFalse(Path(config["recovery_key_file"]).exists())
        # A second run over the same backups keeps them as they are.
        before = tree_fingerprint(repository)
        again = self.initialize(config_path)
        self.assertEqual(0, again.returncode, again.stderr)
        self.assertEqual(before, tree_fingerprint(repository))

    def test_the_initializer_never_switches_existing_backups(self) -> None:
        cases = (
            # (fixture, configured access, expected exit)
            (self.password, "no_password", 4),
            (self.no_password, "password", 5),
            (self.no_password, None, 5),
            (self.damaged_key, "no_password", 6),
        )
        for fixture, access, code in cases:
            with self.subTest(fixture=fixture.name, access=access):
                repository = self.copy_of(fixture)
                before = tree_fingerprint(repository)
                config_path, config = self.write_initializer_config(repository, access)
                result = self.initialize(config_path)
                self.assertEqual(code, result.returncode, result.stderr)
                self.assertEqual(before, tree_fingerprint(repository))
                # No password file and no recovery key were made for backups that were not continued.
                self.assertFalse(Path(config["secret_file"]).exists())
                self.assertFalse(Path(config["recovery_key_file"]).exists())
                self.assertNotIn("Fatal", result.stdout + result.stderr)

    def test_backups_with_a_password_this_pc_does_not_have_are_refused_with_exit_7_and_changed_in_no_way(self) -> None:
        unavailable = initialize_repository.UNAVAILABLE_MESSAGE
        unreadable = initialize_repository.UNREADABLE_MESSAGE
        mismatch = initialize_repository.MISMATCH_MESSAGE
        cases = (
            # (fixture, configured access, expected exit, the one plain line)
            (self.password, "password", 7, unavailable),
            (self.password, None, 7, unavailable),  # a configuration from before the choice existed means a password
            (self.dual, "password", 5, mismatch),  # opens without a password too, so it is "no password" and the choice is wrong
            (self.empty_keys, "password", 6, unreadable),  # holds no key at all: not a password this PC lacks
            (self.damaged_key, "password", 6, unreadable),
            (self.truncated_config, "password", 6, unreadable),
        )
        for fixture, access, code, line in cases:
            with self.subTest(fixture=fixture.name, access=access):
                repository = self.copy_of(fixture)
                before = tree_fingerprint(repository)
                config_path, config = self.write_initializer_config(repository, access)
                result = self.initialize(config_path)
                self.assertEqual(code, result.returncode, result.stderr)
                self.assertEqual(line + "\n", result.stderr)
                self.assertEqual("", result.stdout)
                self.assertEqual(before, tree_fingerprint(repository))
                # Nothing was created for them: no password, no recovery key, no recovery tools, no record.
                self.assertFalse(Path(config["secret_file"]).exists())
                self.assertFalse(Path(config["recovery_key_file"]).exists())
                self.assertFalse(Path(config["recovery_tools_directory"]).exists())
                self.assertFalse((Path(config["state_directory"]) / "repository.json").exists())

    def test_a_saved_password_that_does_not_open_the_backups_is_exit_7_and_is_left_exactly_as_it_is(self) -> None:
        for label, fixture, code, line in (
            ("another password", self.password, 7, initialize_repository.UNAVAILABLE_MESSAGE),
            ("a folder of keys with no key", self.empty_keys, 6, initialize_repository.UNREADABLE_MESSAGE),
            ("backups without a password", self.no_password, 5, initialize_repository.MISMATCH_MESSAGE),
        ):
            with self.subTest(label):
                repository = self.copy_of(fixture)
                before = tree_fingerprint(repository)
                config_path, config = self.write_initializer_config(repository, "password")
                # A real stored password, made for some other backups.
                secret_file = Path(config["secret_file"])
                secret_store.create_secret(secret_file)
                secret_before = secret_file.read_bytes()
                result = self.initialize(config_path)
                self.assertEqual(code, result.returncode, result.stderr)
                self.assertEqual(line + "\n", result.stderr)
                self.assertEqual(before, tree_fingerprint(repository))
                self.assertEqual(secret_before, secret_file.read_bytes())
                self.assertFalse(Path(config["recovery_key_file"]).exists())
                self.assertFalse(Path(config["recovery_tools_directory"]).exists())
                self.assertNotIn("Fatal", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
