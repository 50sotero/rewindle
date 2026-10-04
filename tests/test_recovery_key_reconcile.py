from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest


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
        self.assertEqual((True, False), reconcile_recovery_key(self.key, self.new, PASSWORD))
        self.assertEqual(PASSWORD, parse_recovery_key(self.key, self.new))

    def test_a_kept_key_for_the_same_repository_is_left_alone(self) -> None:
        write_recovery_key(self.key, self.old, PASSWORD)
        before = self.key.read_bytes()
        self.assertEqual((False, False), reconcile_recovery_key(self.key, self.old, PASSWORD))
        self.assertEqual(before, self.key.read_bytes())

    def test_a_kept_key_for_another_repository_is_rewritten_to_name_the_new_one(self) -> None:
        # A reinstall that chose another location: the kept key has the right password but names the old repository, which
        # the recovery check rejects. It now names the new one, with the same password.
        write_recovery_key(self.key, self.old, PASSWORD)
        with self.assertRaisesRegex(RuntimeError, "different repository"):
            parse_recovery_key(self.key, self.new)
        self.assertEqual((False, True), reconcile_recovery_key(self.key, self.new, PASSWORD))
        self.assertEqual(PASSWORD, parse_recovery_key(self.key, self.new))
        self.assertEqual([], [path.name for path in self.folder.iterdir() if path.name.endswith(".tmp")])

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
