import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "src"
    / "verify_cloud_repository_inventory.py"
)
SPEC = importlib.util.spec_from_file_location("cloud_repository_inventory", MODULE_PATH)
VERIFIER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(VERIFIER)


def cloud_item(relative_path: str, content: bytes, cloud_id: str) -> dict:
    return {
        "Path": relative_path,
        "Name": relative_path.rsplit("/", 1)[-1],
        "Size": len(content),
        "IsDir": False,
        "ID": cloud_id,
        "Hashes": {
            "md5": hashlib.md5(content, usedforsecurity=False).hexdigest(),
            "sha256": hashlib.sha256(content).hexdigest(),
        },
    }


class CloudRepositoryInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        (self.repository / "data" / "ab").mkdir(parents=True)
        self.contents = {
            "config": b'{"id":"repository-id","version":2}\n',
            "data/ab/pack": b"encrypted-restic-pack",
        }
        for relative, content in self.contents.items():
            path = self.repository / Path(relative)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)

    def tearDown(self):
        self.temporary.cleanup()

    def cloud_document(self) -> list[dict]:
        return [
            cloud_item(relative, content, f"cloud-{index}")
            for index, (relative, content) in enumerate(self.contents.items(), 1)
        ]

    def test_exact_path_size_and_both_hashes_are_verified(self):
        proof = VERIFIER.compare_inventories(
            VERIFIER.local_inventory(self.repository),
            VERIFIER.cloud_inventory(self.cloud_document()),
        )
        self.assertTrue(proof["exact_file_inventory_verified"])
        self.assertTrue(proof["path_case_size_md5_sha256_verified"])
        self.assertEqual(proof["files"], 2)
        self.assertEqual(proof["cloud_objects_with_ids"], 2)
        self.assertRegex(proof["inventory_fingerprint_sha256"], r"^[0-9a-f]{64}$")

    def test_case_difference_and_extra_object_fail_exact_comparison(self):
        case_changed = self.cloud_document()
        case_changed[0]["Path"] = "Config"
        case_changed[0]["Name"] = "Config"
        with self.assertRaises(VERIFIER.InventoryError) as context:
            VERIFIER.compare_inventories(
                VERIFIER.local_inventory(self.repository),
                VERIFIER.cloud_inventory(case_changed),
            )
        self.assertEqual("cloud_files_missing", context.exception.category)

        extra = self.cloud_document()
        extra.append(cloud_item("keys/extra", b"extra", "cloud-extra"))
        with self.assertRaises(VERIFIER.InventoryError) as context:
            VERIFIER.compare_inventories(
                VERIFIER.local_inventory(self.repository),
                VERIFIER.cloud_inventory(extra),
            )
        self.assertEqual("cloud_files_extra", context.exception.category)

    def test_missing_hash_and_content_mismatch_fail_closed_without_paths(self):
        missing_hash = self.cloud_document()
        del missing_hash[0]["Hashes"]["sha256"]
        with self.assertRaises(VERIFIER.InventoryError) as context:
            VERIFIER.cloud_inventory(missing_hash)
        self.assertEqual("cloud_hash_missing", context.exception.category)

        mismatch = self.cloud_document()
        mismatch[1]["Hashes"]["sha256"] = "f" * 64
        cloud_path = self.root / "cloud.json"
        proof_path = self.root / "proof.json"
        cloud_path.write_text(json.dumps(mismatch), encoding="utf-8")
        output = io.StringIO()
        with redirect_stdout(output):
            result = VERIFIER.main(
                (
                    "--local-repository",
                    str(self.repository),
                    "--cloud-inventory",
                    str(cloud_path),
                    "--proof",
                    str(proof_path),
                )
            )
        self.assertEqual(2, result)
        self.assertFalse(proof_path.exists())
        self.assertNotIn("data/ab/pack", output.getvalue())

    def test_hash_name_casing_is_normalized_and_cloud_ids_are_unique(self):
        alternate_names = self.cloud_document()
        for item in alternate_names:
            hashes = item["Hashes"]
            item["Hashes"] = {
                "MD5": hashes["md5"],
                "SHA-256": hashes["sha256"],
            }
        inventory = VERIFIER.cloud_inventory(alternate_names)
        self.assertEqual(set(self.contents), set(inventory))

        duplicate_id = self.cloud_document()
        duplicate_id[1]["ID"] = duplicate_id[0]["ID"]
        with self.assertRaises(VERIFIER.InventoryError) as context:
            VERIFIER.cloud_inventory(duplicate_id)
        self.assertEqual("cloud_identity_duplicate", context.exception.category)


if __name__ == "__main__":
    unittest.main()
