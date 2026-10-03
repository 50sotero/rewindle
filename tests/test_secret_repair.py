from pathlib import Path
import secrets
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))

import secret_store  # noqa: E402


@unittest.skipUnless(sys.platform == "win32", "DPAPI is Windows-only")
class SecretRepairTests(unittest.TestCase):
    def test_atomic_replacement_round_trips_under_current_user_dpapi(self) -> None:
        with tempfile.TemporaryDirectory(prefix="secret-repair-") as root_text:
            root = Path(root_text)
            secret_store.secure_directory(root)
            path = root / "secret.json"
            secret_store.create_secret(path)
            replacement = secrets.token_urlsafe(48)

            secret_store.replace_secret(path, replacement)

            self.assertEqual(replacement, secret_store.load_secret(path))
            secret_store.verify_restricted_acl(path)
            self.assertEqual([], list(root.glob("*.tmp")))

    def test_post_publish_failure_restores_original_envelope(self) -> None:
        with tempfile.TemporaryDirectory(prefix="secret-rollback-") as root_text:
            root = Path(root_text)
            secret_store.secure_directory(root)
            path = root / "secret.json"
            original_password = secret_store.create_secret(path)
            original_bytes = path.read_bytes()
            replacement = secrets.token_urlsafe(48)

            with mock.patch(
                "secret_store.load_secret",
                side_effect=[replacement, RuntimeError("injected post-publish failure")],
            ):
                with self.assertRaisesRegex(RuntimeError, "post-publish failure"):
                    secret_store.replace_secret(path, replacement)

            self.assertEqual(original_bytes, path.read_bytes())
            self.assertEqual(original_password, secret_store.load_secret(path))
            secret_store.verify_restricted_acl(path)


if __name__ == "__main__":
    unittest.main()
