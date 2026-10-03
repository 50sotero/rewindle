import contextlib
import importlib.util
import io
import json
import sqlite3
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "src" / "verify_google_drive_upload.py"
SPEC = importlib.util.spec_from_file_location("google_drive_verifier", MODULE_PATH)
VERIFIER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VERIFIER)


class GoogleDriveVerifierTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.connection.row_factory = sqlite3.Row
        self.connection.execute(
            """
            CREATE TABLE item (
                local_type INTEGER,
                cloud_type INTEGER,
                local_filename TEXT,
                cloud_filename TEXT,
                local_size INTEGER,
                cloud_size INTEGER,
                local_md5_checksum TEXT,
                cloud_md5_checksum TEXT,
                cloud_version INTEGER,
                cloud_id TEXT,
                item_id TEXT,
                trashed INTEGER,
                is_tombstone INTEGER,
                is_folder INTEGER,
                file_size INTEGER
            )
            """
        )
        self.values = {
            "local_type": 1,
            "cloud_type": 1,
            "local_filename": "config",
            "cloud_filename": "config",
            "local_size": 155,
            "cloud_size": 155,
            "local_md5_checksum": "a" * 32,
            "cloud_md5_checksum": "a" * 32,
            "cloud_version": 7,
            "cloud_id": "cloud-item",
            "item_id": "cloud-item",
            "trashed": 0,
            "is_tombstone": 0,
            "is_folder": 0,
            "file_size": 155,
        }

    def tearDown(self):
        self.connection.close()

    def row(self, **updates):
        values = dict(self.values)
        values.update(updates)
        columns = list(values)
        self.connection.execute("DELETE FROM item")
        self.connection.execute(
            f"INSERT INTO item ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})",
            [values[column] for column in columns],
        )
        return self.connection.execute("SELECT * FROM item").fetchone()

    def test_complete_file_metadata_is_confirmed(self):
        expected = {"length": 155, "md5": "a" * 32}
        self.assertTrue(VERIFIER.verify_file(self.row(), expected))

    def test_nullable_inflight_file_metadata_is_pending_not_an_exception(self):
        expected = {"length": 155, "md5": "a" * 32}
        nullable_fields = (
            "local_type",
            "cloud_type",
            "local_size",
            "cloud_size",
            "local_md5_checksum",
            "cloud_md5_checksum",
            "cloud_version",
            "cloud_id",
            "item_id",
            "trashed",
            "is_tombstone",
            "is_folder",
            "file_size",
        )
        for field in nullable_fields:
            with self.subTest(field=field):
                self.assertFalse(VERIFIER.verify_file(self.row(**{field: None}), expected))

    def test_type_error_is_emitted_as_bounded_fail_closed_json(self):
        output = io.StringIO()
        with mock.patch.object(VERIFIER, "parse_args", return_value=object()):
            with mock.patch.object(VERIFIER, "sample", side_effect=TypeError("incomplete row")):
                with contextlib.redirect_stdout(output):
                    self.assertEqual(VERIFIER.main(), 1)
        document = json.loads(output.getvalue())
        self.assertEqual(document["state"], "unsupported")
        self.assertEqual(document["category"], "provider_verification_failed_closed")
        self.assertNotIn("incomplete row", output.getvalue())


if __name__ == "__main__":
    unittest.main()
