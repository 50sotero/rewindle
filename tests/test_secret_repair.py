from pathlib import Path
import secrets
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import credential_repair  # noqa: E402
import secret_store  # noqa: E402
import test_credential_repair as repair_fixture  # noqa: E402


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

    def test_a_backup_without_a_password_never_touches_an_older_install_s_secret(self) -> None:
        with tempfile.TemporaryDirectory(prefix="secret-no-password-") as root_text:
            config_path, config = repair_fixture.build_fixture(Path(root_text), access="no_password")
            state = Path(config["state_directory"])
            secret_store.secure_directory(state)
            path = Path(config["secret_file"])
            # The DPAPI file an earlier install of the same folders left behind.
            original_password = secret_store.create_secret(path)
            original_bytes = path.read_bytes()

            with self.assertRaisesRegex(RuntimeError, "^This backup opens without a key, so there is nothing to repair\\.$"):
                credential_repair.repair(
                    config_path,
                    expected_config_sha256=credential_repair.sha256_file(config_path),
                    expected_plan_id=repair_fixture.PLAN_ID,
                    expected_generation=4,
                    expected_user_sid=repair_fixture.SID,
                    runner=lambda *arguments, **keywords: self.fail("Restic was started"),
                    acl_verifier=lambda checked: self.fail("a key file was looked at"),
                    sid_reader=lambda: repair_fixture.SID,
                    require_manifest=False,
                )

            self.assertEqual(original_bytes, path.read_bytes())
            self.assertEqual(original_password, secret_store.load_secret(path))
            secret_store.verify_restricted_acl(path)
            self.assertEqual([], list(state.glob("*.tmp")))


if __name__ == "__main__":
    unittest.main()
