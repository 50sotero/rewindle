from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SRC = PROJECT / "src"
sys.path.insert(0, str(SRC))

from initialize_repository import reconcile_recovery_key  # noqa: E402
from recovery_health import parse_recovery_key  # noqa: E402
from secret_store import write_recovery_key  # noqa: E402


PASSWORD = "p" * 48


class RecoveryKeyReconcileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = Path(tempfile.mkdtemp(prefix="rewindle-recovery-key-"))
        self.key = self.folder / "ResticBackuper-RecoveryKey.txt"
        self.old = self.folder / "Old Drive" / "Backups"
        self.new = self.folder / "New Drive" / "Backups"

    def tearDown(self) -> None:
        import shutil

        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_new_key_is_written_for_the_repository(self) -> None:
        self.assertEqual("created", reconcile_recovery_key(self.key, self.new, PASSWORD))
        self.assertEqual(PASSWORD, parse_recovery_key(self.key, self.new))

    def test_a_kept_key_for_the_same_repository_is_left_alone(self) -> None:
        write_recovery_key(self.key, self.old, PASSWORD)
        before = self.key.read_bytes()
        self.assertEqual("current", reconcile_recovery_key(self.key, self.old, PASSWORD))
        self.assertEqual("current", reconcile_recovery_key(self.key, self.old, PASSWORD, rewrite=True))
        self.assertEqual(before, self.key.read_bytes())

    def test_a_kept_key_for_another_repository_is_rewritten_only_when_the_install_commits(self) -> None:
        # A reinstall that chose another location: the kept key has the right password but names the old repository, which
        # the recovery check rejects for the new one. Initializing leaves it alone (a failed install must not change it); the
        # commit makes it name the new one, with the same password.
        write_recovery_key(self.key, self.old, PASSWORD)
        before = self.key.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "different repository"):
            parse_recovery_key(self.key, self.new)
        self.assertEqual("stale", reconcile_recovery_key(self.key, self.new, PASSWORD))
        self.assertEqual(before, self.key.read_bytes())
        self.assertEqual("rewritten", reconcile_recovery_key(self.key, self.new, PASSWORD, rewrite=True))
        self.assertEqual(PASSWORD, parse_recovery_key(self.key, self.new))
        self.assertEqual([], [path.name for path in self.folder.iterdir() if path.name.endswith(".tmp")])

    def test_the_commit_never_writes_a_missing_key(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "missing"):
            reconcile_recovery_key(self.key, self.new, PASSWORD, rewrite=True)
        self.assertFalse(self.key.exists())

    def test_the_commit_runs_only_from_its_own_switch(self) -> None:
        import initialize_repository

        config = {"repository": str(self.new), "state_directory": str(self.folder / "state"), "secret_file": str(self.folder / "secret.json"), "recovery_key_file": str(self.key)}
        with mock.patch.object(initialize_repository, "load_config", return_value=config), \
                mock.patch.object(initialize_repository, "load_secret", return_value=PASSWORD), \
                mock.patch.object(initialize_repository, "repository_storage_mode", return_value="local_ntfs"), \
                mock.patch.object(initialize_repository, "validate_repository_volume", side_effect=AssertionError("initialized")):
            write_recovery_key(self.key, self.old, PASSWORD)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, initialize_repository.main(["--config", "x.json", "--commit-recovery-key"]))
        self.assertEqual(PASSWORD, parse_recovery_key(self.key, self.new))

    def mocked_main(self, config: dict, argv: list[str]):
        """main() with a configuration a test built by hand (so it need not carry repository_access) and nothing real."""
        import initialize_repository

        load_secret = mock.Mock(return_value=PASSWORD)
        out = io.StringIO()
        with mock.patch.object(initialize_repository, "load_config", return_value=config), \
                mock.patch.object(initialize_repository, "load_secret", load_secret), \
                mock.patch.object(initialize_repository, "repository_storage_mode", return_value="local_ntfs"), \
                mock.patch.object(initialize_repository, "validate_repository_volume", side_effect=AssertionError("initialized")), \
                contextlib.redirect_stdout(out):
            code = initialize_repository.main(argv)
        return code, out.getvalue(), load_secret

    def hand_built_config(self, **extra) -> dict:
        return {
            "repository": str(self.new),
            "state_directory": str(self.folder / "state"),
            "secret_file": str(self.folder / "secret.json"),
            "recovery_key_file": str(self.key),
            **extra,
        }

    def test_a_configuration_without_repository_access_commits_the_key_as_a_backup_with_a_password(self) -> None:
        # Every configuration written before the choice existed, and a test's hand-built one: no such key.
        config = self.hand_built_config()
        self.assertNotIn("repository_access", config)
        write_recovery_key(self.key, self.old, PASSWORD)

        code, out, load_secret = self.mocked_main(config, ["--config", "x.json", "--commit-recovery-key"])

        self.assertEqual(0, code)
        load_secret.assert_called_once_with(self.folder / "secret.json")
        self.assertEqual({"recovery_key_file": str(self.key), "recovery_key": "rewritten"}, json.loads(out))
        self.assertEqual(PASSWORD, parse_recovery_key(self.key, self.new))

    def test_the_commit_for_backups_without_a_password_reads_no_secret_and_leaves_an_older_key_alone(self) -> None:
        write_recovery_key(self.key, self.old, PASSWORD)
        before = self.key.read_bytes()

        code, out, load_secret = self.mocked_main(
            self.hand_built_config(repository_access="no_password"), ["--config", "x.json", "--commit-recovery-key"]
        )

        self.assertEqual(0, code)
        load_secret.assert_not_called()
        self.assertEqual({"recovery_key_file": None, "recovery_key": "none"}, json.loads(out))
        self.assertEqual(before, self.key.read_bytes())
        self.assertFalse((self.folder / "state").exists())

    def test_an_unsupported_repository_access_stops_the_commit_before_any_key_is_read(self) -> None:
        write_recovery_key(self.key, self.old, PASSWORD)
        before = self.key.read_bytes()
        for value in ("No_Password", "", None, 5, ["no_password"]):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "^unsupported repository_access$"):
                    self.mocked_main(
                        self.hand_built_config(repository_access=value), ["--config", "x.json", "--commit-recovery-key"]
                    )
                self.assertEqual(before, self.key.read_bytes())

    def test_the_installer_commits_the_key_after_verification_and_before_the_first_backup(self) -> None:
        installer = (PROJECT / "installer" / "Install-ResticBackuper.ps1").read_text(encoding="utf-8-sig")
        verified = installer.index("    Assert-InstallationVerified\n")
        commit = installer.index("--commit-recovery-key", verified)
        self.assertLess(commit, installer.index("Start-InstallPhase 'first_backup'", verified))
        self.assertEqual(1, installer.count("--commit-recovery-key"))

    def test_a_kept_key_with_another_password_is_refused_and_kept(self) -> None:
        write_recovery_key(self.key, self.old, "q" * 48)
        before = self.key.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            reconcile_recovery_key(self.key, self.new, PASSWORD)
        self.assertEqual(before, self.key.read_bytes())

    def test_a_new_key_never_replaces_one_that_appears_meanwhile(self) -> None:
        write_recovery_key(self.key, self.old, PASSWORD)
        with self.assertRaises(FileExistsError):
            write_recovery_key(self.key, self.new, PASSWORD)


if __name__ == "__main__":
    unittest.main()
