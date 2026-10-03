from pathlib import Path
import sys
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
if str(SOURCE) not in sys.path:
    sys.path.insert(0, str(SOURCE))

import backup  # noqa: E402


class FailureDetailsTests(unittest.TestCase):
    def test_failure_classification_is_stable_by_phase(self) -> None:
        cases = (
            ("preflighting_sources", RuntimeError("fixture"), 1,
             ("source_preflight", "source_preflight_failed")),
            ("authenticating_repository", RuntimeError("fixture"), 1,
             ("repository_authentication", "repository_authentication_failed")),
            ("partial", RuntimeError("fixture"), 3,
             ("backup", "source_data_unreadable")),
            ("checking_repository", RuntimeError("fixture"), 1,
             ("repository_structure_check", "repository_structure_check_failed")),
            ("restoring_canary", RuntimeError("fixture"), 1,
             ("restore_canary", "restore_canary_failed")),
        )
        for phase, error, exit_code, expected in cases:
            with self.subTest(phase=phase):
                self.assertEqual(
                    backup.classify_failure(phase, error, exit_code), expected
                )

    def test_capacity_and_volume_failures_have_specific_codes(self) -> None:
        self.assertEqual(
            backup.classify_failure(
                "starting", RuntimeError("minimum free-space reserve"), 1
            )[1],
            "repository_low_space",
        )
        self.assertEqual(
            backup.classify_failure(
                "starting", RuntimeError("volume serial mismatch"), 1
            )[1],
            "volume_identity_mismatch",
        )

    def test_affected_paths_are_bounded_absolute_and_deduplicated(self) -> None:
        errors = [
            {"message_type": "error", "item": rf"E:\source\file-{index}.txt"}
            for index in range(70)
        ]
        errors.extend(
            [
                {"item": "E:\\source\\file-1.txt"},
                {"item": "relative.txt"},
                {"item": "E:\\source\\bad\npath.txt"},
                {"error": {"path": "F:\\other\\locked.docx"}},
            ]
        )
        status = {
            "errors": errors,
            "source_preflight": {
                "sources": [
                    {
                        "canonical_path": "G:\\missing",
                        "overall_status": "missing",
                    }
                ]
            },
        }
        paths = backup.collect_affected_paths(status)
        self.assertEqual(len(paths), backup.MAX_AFFECTED_PATHS)
        self.assertEqual(len({path.casefold() for path in paths}), len(paths))
        self.assertTrue(all(":" in path[:3] for path in paths))
        self.assertNotIn("relative.txt", paths)


if __name__ == "__main__":
    unittest.main()
