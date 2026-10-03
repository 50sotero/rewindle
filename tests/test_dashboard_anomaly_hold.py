from pathlib import Path
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"


class DashboardAnomalyHoldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.telemetry = (DASHBOARD / "Telemetry.cs").read_text(encoding="utf-8")
        cls.window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        profiles = (DASHBOARD / "EngineProfile.cs").read_text(encoding="utf-8")
        cls.rewindle_profile = profiles[
            profiles.index("private static EngineProfile CreateRewindle()") :
            profiles.index("private static EngineProfile CreateLegacy()")
        ]
        cls.backup = (PROJECT / "src" / "backup.py").read_text(encoding="utf-8")

    def test_backup_records_non_destructive_hold_after_verification(self) -> None:
        self.assertIn('status["change_anomaly"] = evaluate_change_anomaly(', self.backup)
        self.assertIn('status["maintenance_hold"] = bool(', self.backup)
        self.assertLess(
            self.backup.index('status["verification"]["canary"] = verify_canary('),
            self.backup.index('status["change_anomaly"] = evaluate_change_anomaly('),
        )
        self.assertNotIn('restic_base(config) + ["forget"', self.backup)
        self.assertNotIn('restic_base(config) + ["prune"', self.backup)

    def test_dashboard_describes_review_hold_without_claiming_upload_pause(self) -> None:
        self.assertIn("public bool HasMaintenanceHold", self.telemetry)
        self.assertIn('GetBool(document, "maintenance_hold", false)', self.telemetry)
        self.assertIn('"Backup verified — review changes"', self.window)
        self.assertIn('SetBadge("REVIEW CHANGES"', self.window)
        # The hold detail is the engine's own sentence; the Rewindle engine never pauses a live DriveFS upload.
        self.assertIn("EngineProfile.Current.AnomalyReview.HoldDetailSuffix", self.telemetry)
        self.assertIn(
            "this hold does not pause a live DriveFS upload",
            self.rewindle_profile,
        )
        self.assertNotIn("Off-site promotion is paused", self.telemetry)
        self.assertNotIn("off-site promotion is paused", self.window.lower())
        self.assertNotIn("off-site promotion is paused", self.rewindle_profile.lower())

    def test_public_core_never_uses_the_hold_to_delete_or_prune(self) -> None:
        self.assertNotIn('restic_base(config) + ["forget"', self.backup)
        self.assertNotIn('restic_base(config) + ["prune"', self.backup)


if __name__ == "__main__":
    unittest.main()
