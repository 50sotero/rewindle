from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
NAMESPACE = "ResticBackuper.Dashboard"
TELEMETRY_SOURCE = DASHBOARD / "Telemetry.cs"
WINDOW_SOURCE = DASHBOARD / "DashboardWindow.cs"
DIAGNOSTIC_SOURCE = DASHBOARD / "DiagnosticExporter.cs"
PLAN_ID = "10000000-0000-4000-8000-000000000042"
REPOSITORY_ID = "8" * 64
SNAPSHOT_ID = "4" * 64
REPOSITORY_PATH = r"G:\My Drive\ResticBackups\Personal"


def ago(**delta) -> str:
    """A moment this long before now, as the engine writes times (UTC, ISO 8601 with Z)."""
    return (datetime.now(timezone.utc) - timedelta(**delta)).strftime("%Y-%m-%dT%H:%M:%SZ")


HARNESS_SOURCE = """
namespace {namespace}
{{
    using System;
    using System.Collections.Generic;
    using System.Web.Script.Serialization;

    internal static class OffsiteStatusHarness
    {{
        public static int Main(string[] args)
        {{
            // Every engine path the reader builds (the installed plan under Program Files, the direct cloud proof under
            // ProgramData, the retired per-user mirror status, the dashboard folder) points into the disposable engine root
            // given on the command line, which the test fills; the state folder is the second argument.
            EngineProfile.UseFolderRootsForTesting(args[0]);
            if (args.Length > 2)
            {{
                EngineProfile.Activate(EngineProfile.FromId(args[2]));
            }}
            TelemetryReader reader = new TelemetryReader(args[1], false);
            TelemetrySnapshot snapshot = reader.Load();
            OffsiteStatusView status = snapshot.OffsiteStatus;
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["kind"] = status.Kind.ToString();
            result["label"] = status.StatusLabel;
            result["detail"] = status.StatusDetail;
            result["plan_id"] = status.PlanId;
            result["config_generation"] = status.ConfigGeneration;
            result["repository_id"] = status.RepositoryId;
            result["repository_path"] = status.RepositoryPath;
            result["snapshot_id"] = status.SnapshotId;
            result["snapshot_short"] = status.SnapshotShort;
            result["inventory_fingerprint"] = status.InventoryFingerprintSha256;
            result["files"] = status.FileCount;
            result["bytes"] = status.ByteCount;
            result["provider_confirmed"] = status.ProviderUploadConfirmed;
            result["restore_verified"] = status.RestoreVerified;
            result["has_updated"] = status.LastUpdatedLocal.HasValue;
            result["provider"] = status.ProviderLabel;
            result["check_overdue"] = status.CheckOverdue;
            result["next_step"] = status.NextStep;
            // Characters outside ASCII go out as JSON escapes, so the output reads the same in any console code page (in a
            // UTF-8 console an ellipsis came back as three characters).
            string json = new JavaScriptSerializer().Serialize(result);
            System.Text.StringBuilder ascii = new System.Text.StringBuilder(json.Length);
            foreach (char character in json)
            {{
                if (character > 126)
                {{
                    ascii.Append("\\\\u").Append(((int)character).ToString("x4"));
                }}
                else
                {{
                    ascii.Append(character);
                }}
            }}
            Console.WriteLine(ascii.ToString());
            return 0;
        }}
    }}
}}
"""


class DashboardOffsiteStatusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        framework = (
            Path(os.environ.get("SystemRoot", r"C:\Windows"))
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest("The .NET Framework C# compiler is unavailable.")

        # Keep the compiled harness beneath the reviewed source tree. Some
        # Windows Application Control policies reject newly compiled binaries
        # from the per-user temporary directory even though the same compiler
        # output is allowed from the repository workspace.
        cls.temp_directory = tempfile.TemporaryDirectory(
            prefix=".offsite-status-harness-",
            dir=PROJECT,
        )
        temp = Path(cls.temp_directory.name)
        cls.executable = temp / "OffsiteStatusHarness.exe"
        harness = temp / "OffsiteStatusHarness.cs"
        harness.write_text(
            textwrap.dedent(HARNESS_SOURCE.format(namespace=NAMESPACE)),
            encoding="utf-8",
        )
        compile_result = subprocess.run(
            [
                str(compiler),
                "/nologo",
                "/target:exe",
                "/warn:4",
                f"/out:{cls.executable}",
                f"/main:{NAMESPACE}.OffsiteStatusHarness",
                f"/reference:{framework / 'System.dll'}",
                f"/reference:{framework / 'System.Core.dll'}",
                f"/reference:{framework / 'System.Web.Extensions.dll'}",
                str(DASHBOARD / "EngineProfile.cs"),
                str(DASHBOARD / "AtomicFile.cs"),
                str(DASHBOARD / "ElevatedRequestSecurity.cs"),
                str(DASHBOARD / "SourceConfiguration.cs"),
                str(DASHBOARD / "ProcessLiveness.cs"),
                str(TELEMETRY_SOURCE),
                str(harness),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if compile_result.returncode != 0:
            raise AssertionError(
                "Off-site status harness compilation failed:\n"
                + compile_result.stdout
                + compile_result.stderr
            )

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    @staticmethod
    def backup_evidence(**overrides) -> dict:
        result = {
            "schema_version": 1,
            "state": "success",
            "verification_complete": True,
            # Times are relative to now, because a proof that still covers the latest backup stops counting once it is two days
            # old. Every ordering the tests rely on is kept: the backup starts, finishes, and the proof is verified after it.
            "started_utc": ago(hours=3),
            "finished_utc": ago(hours=2, minutes=40),
            "run_id": "20260729T014500-a1b2c3d4",
            "plan_id": PLAN_ID,
            "config_generation": 2,
            "repository": REPOSITORY_PATH,
            "repository_storage_mode": "google_drivefs_stream",
            "repository_id": REPOSITORY_ID,
            "snapshot_id": SNAPSHOT_ID,
        }
        result.update(overrides)
        return result

    @staticmethod
    def direct_proof(**overrides) -> dict:
        result = {
            "schema_version": 2,
            "proof_kind": "direct_my_drive_cloud_repository_verification",
            "run_id": "20260729T001500000Z-a1b2c3d4",
            "state": "verified",
            "verified_utc": ago(hours=2, minutes=30),
            "verification_mode": "google_drive_api_readonly_rclone_backend",
            "verification_phase": "post_activation",
            "plan_id": PLAN_ID,
            "config_generation": 2,
            "repository_storage_mode": "google_drivefs_stream",
            "local_repository": REPOSITORY_PATH,
            "my_drive_root": r"G:\My Drive",
            "cloud_root_folder_id": "root",
            "cloud_repository_path": "ResticBackups/Personal",
            "repository_identity_verified": True,
            "repository_id": REPOSITORY_ID,
            "local_repository_id": REPOSITORY_ID,
            "cloud_repository_id": REPOSITORY_ID,
            "repository_version": 2,
            "exact_file_inventory_verified": True,
            "path_case_size_md5_sha256_verified": True,
            "files": 5109,
            "bytes": 89957824603,
            "missing_files": 0,
            "extra_files": 0,
            "mismatched_files": 0,
            "inventory_fingerprint_sha256": "1" * 64,
            "cloud_inventory_document_sha256": "2" * 64,
            "cloud_objects_with_ids": 5109,
            "snapshot_id": SNAPSHOT_ID,
            "canary_bytes": 126,
            "canary_sha256": "3" * 64,
            "direct_cloud_restore_verified": True,
            "provider_upload_state": "fully_synced",
            "restore_verification_state": "verified",
            "backup_config_sha256": "5" * 64,
            "immutable_proof_sha256": "6" * 64,
            "cloud_verification_assets_manifest_sha256": "7" * 64,
            "native_capture_mode": "binary_stream_copy",
        }
        result.update(overrides)
        return result

    @staticmethod
    def legacy_mirror_status() -> dict:
        return {
            "schema_version": 1,
            "state": "success",
            "snapshot_id": SNAPSHOT_ID,
            "verified_files": 5109,
            "verified_bytes": 89957824603,
            "provider_upload_state": "synced",
            "restore_verified": True,
        }

    @staticmethod
    def failure_record(**overrides) -> dict:
        """The record the nightly check leaves beside its proof when it fails (latest-failure.json)."""
        result = {
            "schema_version": 1,
            "record_kind": "direct_my_drive_cloud_check_failure",
            "state": "failed",
            "run_id": "20261110T030001123Z-1a2b3c4d",
            "started_utc": ago(hours=1, minutes=2),
            "failed_utc": ago(hours=1),
            "step": "listing_google_drive",
            "step_label": "listing your backup's files in Google Drive",
            "reason_code": "native_failed",
            "reason": "Rewindle couldn't list your backup's files in Google Drive.",
            "next_step": "Make sure this PC is online and Google Drive for desktop is signed in. Rewindle checks again tonight.",
            "plan_id": PLAN_ID,
            "config_generation": 2,
        }
        result.update(overrides)
        return result

    @staticmethod
    def legacy_proof(**overrides) -> dict:
        """A proof in the shape the earlier personal edition's verifier writes (no asset binding)."""
        proof = DashboardOffsiteStatusTests.direct_proof(**overrides)
        for field in (
            "immutable_proof_sha256",
            "cloud_verification_assets_manifest_sha256",
            "native_capture_mode",
        ):
            proof.pop(field)
        return proof

    @staticmethod
    def installed_plan(repository: str, state: Path) -> dict:
        # The installed backup-config.json the proof is bound to; SourceConfiguration.Load validates every field here.
        source = r"C:\Users\you\Documents"
        return {
            "plan_id": PLAN_ID,
            "config_generation": 2,
            "cloud_placeholder_policy": "allow",
            "repository": repository,
            "state_directory": str(state),
            "sources": [source],
            "source_identities": {source: {"expected_volume_serial": "1a2b3c4d"}},
        }

    def invoke(
        self,
        proof=None,
        proof_raw: str = None,
        protected=None,
        last_success=None,
        current=None,
        engine=None,
        configured_repository=REPOSITORY_PATH,
        failure=None,
        failure_raw: str = None,
    ) -> dict:
        """Runs the reader against a disposable engine root.

        The proof is written where the active engine reads it (ProgramData under the root) and the installed plan
        where it is installed (Program Files under the root), so nothing outside the temporary folder is looked at.
        `configured_repository=None` installs no plan. `failure` (or `failure_raw`, text written as it is) is the check's failure
        record, written beside the proof whichever engine is active, so an engine that does not read one is seen ignoring it.
        """
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine_root = root / "engine-roots"
            product = "ResticPersonalBackup" if engine == "legacy" else "ResticBackuper"
            state = root / "state"
            state.mkdir()
            proof_folder = engine_root / "ProgramData" / f"{product}CloudVerification"
            proof_path = (
                proof_folder / "latest-verification.json"
                if engine == "legacy"
                else proof_folder / "evidence" / "latest-verification.json"
            )
            proof_path.parent.mkdir(parents=True)
            if proof_raw is not None:
                proof_path.write_text(proof_raw, encoding="utf-8")
            elif proof is not None:
                proof_path.write_text(json.dumps(proof), encoding="utf-8")
            failure_path = proof_path.parent / "latest-failure.json"
            if failure_raw is not None:
                failure_path.write_text(failure_raw, encoding="utf-8")
            elif failure is not None:
                failure_path.write_text(json.dumps(failure), encoding="utf-8")
            if configured_repository is not None:
                install = engine_root / "ProgramFiles" / product
                install.mkdir(parents=True)
                (install / "backup-config.json").write_text(
                    json.dumps(self.installed_plan(configured_repository, state)),
                    encoding="utf-8",
                )
            if protected is not None:
                (state / "google-drive-sync-status.json").write_text(
                    json.dumps(protected),
                    encoding="utf-8",
                )
            if last_success is None:
                last_success = self.backup_evidence()
            if last_success is not False:
                (state / "last-success.json").write_text(
                    json.dumps(last_success),
                    encoding="utf-8",
                )
            if current is None:
                current = dict(last_success) if isinstance(last_success, dict) else None
            if current is not False and current is not None:
                (state / "status.json").write_text(
                    json.dumps(current),
                    encoding="utf-8",
                )
            arguments = [str(self.executable), str(engine_root), str(state)]
            if engine is not None:
                arguments.append(engine)
            # The dashboard accepts a test root only inside its own temporary folder, so it is given this one.
            environment = dict(os.environ, TMP=tempfile.gettempdir(), TEMP=tempfile.gettempdir())
            run = subprocess.run(
                arguments,
                capture_output=True,
                text=True,
                check=False,
                env=environment,
            )
            self.assertEqual(0, run.returncode, run.stdout + run.stderr)
            return json.loads(run.stdout)

    def test_complete_direct_cloud_proof_is_bound_and_displayed(self) -> None:
        result = self.invoke(proof=self.direct_proof())
        self.assertEqual("RestoreVerified", result["kind"])
        self.assertEqual("Google Drive copy verified", result["label"])
        self.assertTrue(result["provider_confirmed"])
        self.assertTrue(result["restore_verified"])
        self.assertEqual(PLAN_ID, result["plan_id"])
        self.assertEqual(2, result["config_generation"])
        self.assertEqual(REPOSITORY_ID, result["repository_id"])
        self.assertEqual(REPOSITORY_PATH, result["repository_path"])
        self.assertEqual(SNAPSHOT_ID, result["snapshot_id"])
        self.assertEqual(SNAPSHOT_ID[:8], result["snapshot_short"])
        self.assertEqual("1" * 64, result["inventory_fingerprint"])
        self.assertEqual(5109, result["files"])
        self.assertEqual(89957824603, result["bytes"])
        self.assertTrue(result["has_updated"])
        self.assertEqual("Google Drive", result["provider"])

    def test_legacy_mirror_evidence_is_explicitly_rejected(self) -> None:
        result = self.invoke(protected=self.legacy_mirror_status())
        self.assertEqual("StatusUnavailable", result["kind"])
        self.assertIn("retired", result["detail"])
        self.assertFalse(result["provider_confirmed"])

    def test_plan_generation_repository_snapshot_and_phase_mismatch_fail(self) -> None:
        mutations = {
            "plan": {"plan_id": "f2d73a58-895a-4bc9-b49a-92ec42eb7b2c"},
            "generation": {"config_generation": 1},
            "path": {"local_repository": r"H:\My Drive\Other\Repository"},
            "repository": {
                "repository_id": "5" * 64,
                "local_repository_id": "5" * 64,
                "cloud_repository_id": "5" * 64,
            },
            "snapshot": {"snapshot_id": "6" * 64},
            "phase": {"verification_phase": "pre_activation"},
        }
        # A proof of another plan, generation, repository or snapshot than the latest backup's is out of date, and the next check
        # covers the latest backup: it asks nothing of the person (kind Stale). A proof for another path, or from before the
        # direct-cloud phase, cannot be counted at all (StatusUnavailable).
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                result = self.invoke(proof=self.direct_proof(**mutation))
                self.assertEqual(
                    "StatusUnavailable" if label in ("path", "phase") else "Stale",
                    result["kind"],
                )
                self.assertFalse(result["provider_confirmed"])

    def test_newer_backup_attempt_invalidates_an_older_proof(self) -> None:
        current = self.backup_evidence(
            state="backing_up",
            verification_complete=False,
            started_utc=ago(hours=2, minutes=20),
            finished_utc=None,
            snapshot_id=None,
        )
        result = self.invoke(proof=self.direct_proof(), current=current)
        self.assertEqual("Stale", result["kind"])
        self.assertIn("newer than the last check", result["detail"])

    def test_inventory_restore_and_types_must_be_complete(self) -> None:
        mutations = {
            "missing": {"missing_files": 1},
            "extra": {"extra_files": 1},
            "mismatch": {"mismatched_files": 1},
            "ids": {"cloud_objects_with_ids": 5108},
            "hash": {"inventory_fingerprint_sha256": ""},
            "immutable": {"immutable_proof_sha256": ""},
            "asset_manifest": {
                "cloud_verification_assets_manifest_sha256": ""
            },
            "capture": {"native_capture_mode": "powershell_redirection"},
            "inventory_flag": {"exact_file_inventory_verified": False},
            "restore": {"direct_cloud_restore_verified": False},
            "typed_generation": {"config_generation": "2"},
            "typed_files": {"files": True},
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                result = self.invoke(proof=self.direct_proof(**mutation))
                self.assertEqual("StatusUnavailable", result["kind"])

    def test_proof_timestamp_must_follow_the_bound_backup(self) -> None:
        result = self.invoke(
            proof=self.direct_proof(verified_utc=ago(hours=4))
        )
        self.assertEqual("Stale", result["kind"])
        self.assertIn("newer than the last check", result["detail"])

    def test_direct_proof_is_preferred_and_malformed_proof_fails_closed(self) -> None:
        result = self.invoke(
            proof=self.direct_proof(),
            protected={"schema_version": 1, "state": "failed"},
        )
        self.assertEqual("RestoreVerified", result["kind"])

        invalid = self.invoke(
            proof_raw="{not-json",
            protected=self.legacy_mirror_status(),
        )
        self.assertEqual("StatusUnavailable", invalid["kind"])

    def test_credential_like_failure_is_bounded(self) -> None:
        failed = self.direct_proof(
            state="failed",
            error="RESTIC_PASSWORD_COMMAND and DPAPI details must stay private.",
        )
        result = self.invoke(proof=failed)
        self.assertEqual("Failed", result["kind"])
        self.assertNotIn("RESTIC_PASSWORD", result["detail"])
        self.assertNotIn("DPAPI", result["detail"])

    def test_rewindle_binds_any_my_drive_repository_to_its_own_cloud_path(self) -> None:
        repository = r"G:\My Drive\Backups\Laptop"
        evidence = self.backup_evidence(repository=repository)
        bound = self.invoke(
            proof=self.direct_proof(local_repository=repository, cloud_repository_path="Backups/Laptop"),
            last_success=evidence,
            configured_repository=repository,
        )
        self.assertEqual("RestoreVerified", bound["kind"])
        self.assertEqual(repository, bound["repository_path"])
        for label, mutation in {
            "other_cloud_path": {"cloud_repository_path": "Backups/Other"},
            "root_itself": {"local_repository": r"G:\My Drive", "cloud_repository_path": ""},
            "outside_my_drive": {"local_repository": r"G:\Backups\Laptop", "cloud_repository_path": "Backups/Laptop"},
        }.items():
            with self.subTest(label=label):
                proof = self.direct_proof(local_repository=repository, cloud_repository_path="Backups/Laptop")
                proof.update(mutation)
                result = self.invoke(proof=proof, last_success=evidence, configured_repository=repository)
                self.assertEqual("StatusUnavailable", result["kind"])

    def test_legacy_profile_binds_to_its_plan_and_keeps_its_proof_shape(self) -> None:
        legacy_proof = self.direct_proof()
        for field in (
            "immutable_proof_sha256",
            "cloud_verification_assets_manifest_sha256",
            "native_capture_mode",
        ):
            legacy_proof.pop(field)
        # An existing install whose plan names the same repository as before still verifies.
        accepted = self.invoke(proof=legacy_proof, engine="legacy")
        self.assertEqual("RestoreVerified", accepted["kind"])
        self.assertEqual(REPOSITORY_PATH, accepted["repository_path"])
        # The Rewindle engine requires the asset binding the legacy verifier never wrote.
        self.assertEqual("StatusUnavailable", self.invoke(proof=legacy_proof)["kind"])
        # Nothing is pinned any more: a legacy plan that names another repository is verified for that repository,
        # and only for it.
        repository = r"G:\My Drive\Backups\Laptop"
        moved_proof = dict(legacy_proof, local_repository=repository, cloud_repository_path="Backups/Laptop")
        moved_evidence = self.backup_evidence(repository=repository)
        moved = self.invoke(
            proof=moved_proof,
            last_success=moved_evidence,
            engine="legacy",
            configured_repository=repository,
        )
        self.assertEqual("RestoreVerified", moved["kind"])
        other_plan = self.invoke(
            proof=moved_proof,
            last_success=moved_evidence,
            engine="legacy",
            configured_repository=REPOSITORY_PATH,
        )
        self.assertEqual("StatusUnavailable", other_plan["kind"])

    # Fixture proofs bound to the installed plan. Each one is complete and consistent with the backup telemetry, so the
    # only thing wrong with it is the binding the test names.
    def plan_bound_case(self, plan_repository: str, proof_overrides: dict) -> dict:
        repository = proof_overrides.get("local_repository", plan_repository)
        return self.invoke(
            proof=self.direct_proof(**proof_overrides),
            last_success=self.backup_evidence(repository=repository),
            configured_repository=plan_repository,
        )

    def test_fixture_valid_proof_matches_the_installed_plan(self) -> None:
        plan = r"G:\My Drive\Backups\Desktop PC"
        result = self.plan_bound_case(
            plan,
            {"local_repository": plan, "my_drive_root": r"G:\My Drive", "cloud_repository_path": "Backups/Desktop PC"},
        )
        self.assertEqual("RestoreVerified", result["kind"])
        self.assertEqual(plan, result["repository_path"])
        self.assertEqual("Google Drive", result["provider"])
        # Google Drive for desktop on another drive letter is just as valid when the plan says so.
        other_drive = r"H:\My Drive\Backups\Desktop PC"
        moved = self.plan_bound_case(
            other_drive,
            {"local_repository": other_drive, "my_drive_root": r"H:\My Drive", "cloud_repository_path": "Backups/Desktop PC"},
        )
        self.assertEqual("RestoreVerified", moved["kind"])

    def test_fixture_wrong_drive_letter_is_refused(self) -> None:
        plan = r"G:\My Drive\Backups\Desktop PC"
        for label, overrides in {
            "proof_on_another_drive": {
                "local_repository": r"H:\My Drive\Backups\Desktop PC",
                "my_drive_root": r"H:\My Drive",
                "cloud_repository_path": "Backups/Desktop PC",
            },
            "my_drive_root_on_another_drive": {
                "local_repository": plan,
                "my_drive_root": r"H:\My Drive",
                "cloud_repository_path": "Backups/Desktop PC",
            },
        }.items():
            with self.subTest(label=label):
                result = self.plan_bound_case(plan, overrides)
                self.assertEqual("StatusUnavailable", result["kind"])
                self.assertFalse(result["provider_confirmed"])
                self.assertIn("current backup", result["detail"])

    def test_fixture_wrong_relative_path_is_refused(self) -> None:
        plan = r"G:\My Drive\Backups\Desktop PC"
        for cloud_path in (
            "Backups/Laptop",
            "Desktop PC",
            "Backups/Desktop PC/",
            "backups/desktop pc",
            "Backups\\Desktop PC",
            "",
        ):
            with self.subTest(cloud_path=cloud_path):
                result = self.plan_bound_case(
                    plan,
                    {"local_repository": plan, "my_drive_root": r"G:\My Drive", "cloud_repository_path": cloud_path},
                )
                self.assertEqual("StatusUnavailable", result["kind"])
                self.assertFalse(result["restore_verified"])

    def test_fixture_repository_outside_my_drive_is_refused(self) -> None:
        for label, plan, my_drive_root in (
            ("beside_my_drive", r"G:\Backups\Desktop PC", r"G:\My Drive"),
            ("the_root_itself", r"G:\My Drive", r"G:\My Drive"),
            ("another_drive", r"E:\Backups\Desktop PC", r"G:\My Drive"),
        ):
            with self.subTest(label=label):
                result = self.plan_bound_case(
                    plan,
                    {"local_repository": plan, "my_drive_root": my_drive_root, "cloud_repository_path": "Backups/Desktop PC"},
                )
                self.assertEqual("StatusUnavailable", result["kind"])
                self.assertFalse(result["provider_confirmed"])

    def test_fixture_stale_snapshot_is_refused(self) -> None:
        plan = r"G:\My Drive\Backups\Desktop PC"
        newer = self.backup_evidence(repository=plan, snapshot_id="9" * 64)
        # Checked an hour ago: a wait for the next check, said calmly.
        result = self.invoke(
            proof=self.direct_proof(
                local_repository=plan,
                my_drive_root=r"G:\My Drive",
                cloud_repository_path="Backups/Desktop PC",
                verified_utc=ago(hours=1),
            ),
            last_success=newer,
            configured_repository=plan,
        )
        self.assertEqual("Stale", result["kind"])
        self.assertEqual("The Google Drive copy is waiting for its next check", result["label"])
        self.assertFalse(result["check_overdue"])

    # The off-site check runs every night. A check that fails never writes a result, so a last check that worked long ago is the
    # only sign of one that keeps failing: past two days, waiting is no longer calm, and the words say so with what to do.
    def test_a_check_that_has_not_worked_for_two_days_is_overdue(self) -> None:
        cases = {
            # The latest backup is newer than the check: Stale on the timestamp comparison.
            "newer_backup": (
                {"verified_utc": ago(days=3)},
                self.backup_evidence(started_utc=ago(hours=3), finished_utc=ago(hours=2)),
                "newer than the last check",
            ),
            # The latest backup is another snapshot than the one checked: Stale on the binding.
            "other_snapshot": (
                {"verified_utc": ago(days=3)},
                self.backup_evidence(snapshot_id="9" * 64),
                "does not cover your latest backup",
            ),
        }
        for label, (proof, evidence, reason) in cases.items():
            with self.subTest(label=label):
                result = self.invoke(proof=self.direct_proof(**proof), last_success=evidence)
                self.assertEqual("Stale", result["kind"])
                self.assertTrue(result["check_overdue"])
                # The console the harness writes to may not carry the apostrophe, so the label is matched around it.
                self.assertTrue(result["label"].startswith("The Google Drive copy hasn"), result["label"])
                self.assertTrue(result["label"].endswith("t been checked lately"), result["label"])
                self.assertIn(reason, result["detail"])
                self.assertIn("No check has worked since.", result["detail"])
                self.assertIn("Leave this PC on and signed in overnight", result["detail"])
                self.assertNotIn("The next check will", result["detail"])
                self.assertFalse(result["restore_verified"])

    def test_a_check_less_than_two_days_old_is_still_a_calm_wait(self) -> None:
        result = self.invoke(
            proof=self.direct_proof(verified_utc=ago(hours=20)),
            last_success=self.backup_evidence(started_utc=ago(hours=3), finished_utc=ago(hours=2)),
        )
        self.assertEqual("Stale", result["kind"])
        self.assertFalse(result["check_overdue"])
        self.assertIn("The next check will include it.", result["detail"])

    def test_a_check_shown_as_running_for_two_days_is_overdue(self) -> None:
        stuck = self.invoke(proof=self.direct_proof(state="verifying", verified_utc=ago(days=3)))
        self.assertEqual("InProgress", stuck["kind"])
        self.assertTrue(stuck["check_overdue"])
        self.assertTrue(stuck["label"].startswith("The check of the Google Drive copy didn"), stuck["label"])
        self.assertTrue(stuck["label"].endswith("t finish"), stuck["label"])
        self.assertIn("never finished", stuck["detail"])
        self.assertIn("Leave this PC on and signed in overnight", stuck["detail"])
        running = self.invoke(proof=self.direct_proof(state="verifying", verified_utc=ago(hours=1)))
        self.assertEqual("InProgress", running["kind"])
        self.assertFalse(running["check_overdue"])
        self.assertEqual("Checking the Google Drive copy", running["label"])
        # A time ahead of the clock (a clock that was put back) is never overdue.
        ahead = self.invoke(proof=self.direct_proof(state="verifying", verified_utc=ago(hours=-30)))
        self.assertFalse(ahead["check_overdue"])

    def test_only_a_waiting_or_running_check_can_be_overdue(self) -> None:
        # A verified copy that was checked tonight is not overdue (one last checked three days ago is not verified any more: it is
        # a waiting check that is overdue, see test_a_verified_copy_that_has_not_been_checked_for_two_days_is_no_longer_verified).
        verified = self.invoke(proof=self.direct_proof(verified_utc=ago(hours=2)))
        self.assertEqual("RestoreVerified", verified["kind"])
        self.assertFalse(verified["check_overdue"])
        failed = self.invoke(proof=self.direct_proof(state="failed", verified_utc=ago(days=3)))
        self.assertEqual("Failed", failed["kind"])
        self.assertFalse(failed["check_overdue"])

    def test_the_legacy_profile_overdue_check_is_reported_the_same_way(self) -> None:
        legacy_proof = self.direct_proof(verified_utc=ago(days=3))
        for field in (
            "immutable_proof_sha256",
            "cloud_verification_assets_manifest_sha256",
            "native_capture_mode",
        ):
            legacy_proof.pop(field)
        result = self.invoke(
            proof=legacy_proof,
            last_success=self.backup_evidence(started_utc=ago(hours=3), finished_utc=ago(hours=2)),
            engine="legacy",
        )
        self.assertEqual("Stale", result["kind"])
        self.assertTrue(result["check_overdue"])

    # A copy that was verified and still covers the latest backup used to stay "verified" for ever when no newer backup came: a check
    # that stops running, or keeps failing, left the card green. It is verified for two days after the last check that worked.
    def test_a_verified_copy_that_has_not_been_checked_for_two_days_is_no_longer_verified(self) -> None:
        # The proof covers the latest backup exactly (same plan, generation, repository and snapshot, verified after it finished).
        covered = self.backup_evidence(started_utc=ago(days=4), finished_utc=ago(days=3, hours=1))
        for engine, proof in (("rewindle", self.direct_proof), ("legacy", self.legacy_proof)):
            with self.subTest(engine=engine):
                result = self.invoke(
                    proof=proof(verified_utc=ago(days=3)),
                    last_success=covered,
                    engine="legacy" if engine == "legacy" else None,
                )
                self.assertEqual("Stale", result["kind"])
                self.assertTrue(result["check_overdue"])
                self.assertTrue(result["label"].startswith("The Google Drive copy hasn"), result["label"])
                self.assertTrue(result["label"].endswith("t been checked lately"), result["label"])
                self.assertIn("The last check that worked, on ", result["detail"])
                self.assertIn(", covered your latest backup. No check has worked since.", result["detail"])
                self.assertIn("Leave this PC on and signed in overnight", result["detail"])
                self.assertNotIn("The next check will", result["detail"])
                self.assertFalse(result["restore_verified"])
                self.assertFalse(result["provider_confirmed"])
                self.assertEqual("Google Drive", result["provider"])
                self.assertTrue(result["has_updated"])

    def test_a_verified_copy_checked_within_two_days_stays_verified(self) -> None:
        for label, delta in {
            "two_hours": {"hours": 2},
            "just_inside_two_days": {"hours": 47},
        }.items():
            with self.subTest(label=label):
                result = self.invoke(
                    proof=self.direct_proof(verified_utc=ago(**delta)),
                    last_success=self.backup_evidence(started_utc=ago(days=4), finished_utc=ago(days=3)),
                )
                self.assertEqual("RestoreVerified", result["kind"])
                self.assertEqual("Google Drive copy verified", result["label"])
                self.assertFalse(result["check_overdue"])
                self.assertTrue(result["restore_verified"])
        past = self.invoke(
            proof=self.direct_proof(verified_utc=ago(hours=49)),
            last_success=self.backup_evidence(started_utc=ago(days=4), finished_utc=ago(days=3)),
        )
        self.assertEqual("Stale", past["kind"])
        self.assertTrue(past["check_overdue"])

    # What the nightly check writes when it fails, and the card shows: Failed, the reason, where it stopped, and what to do. Until a
    # first check passed the card used to say "Not set up (optional)", and after one it said nothing about a failure for two days.
    def test_a_failed_check_before_any_check_worked_is_shown_with_its_reason_and_next_step(self) -> None:
        result = self.invoke(failure=self.failure_record())
        self.assertEqual("Failed", result["kind"])
        self.assertEqual("The check of the Google Drive copy failed", result["label"])
        self.assertEqual("Google Drive", result["provider"])
        self.assertFalse(result["check_overdue"])
        self.assertTrue(result["has_updated"])
        self.assertFalse(result["restore_verified"])
        self.assertFalse(result["provider_confirmed"])
        lines = result["detail"].split("\n")
        self.assertEqual(2, len(lines), result["detail"])
        self.assertEqual("Rewindle couldn't list your backup's files in Google Drive.", lines[0])
        self.assertRegex(
            lines[1],
            r"^It stopped on .+ while listing your backup's files in Google Drive\. No check of the Google Drive copy has worked yet\.$",
        )
        self.assertEqual(
            "Make sure this PC is online and Google Drive for desktop is signed in. Rewindle checks again tonight.",
            result["next_step"],
        )

    def test_a_failed_check_newer_than_the_last_good_one_is_shown_and_names_that_one(self) -> None:
        result = self.invoke(
            proof=self.direct_proof(verified_utc=ago(hours=5)),
            last_success=self.backup_evidence(started_utc=ago(hours=7), finished_utc=ago(hours=6)),
            failure=self.failure_record(),
        )
        self.assertEqual("Failed", result["kind"])
        self.assertEqual("The check of the Google Drive copy failed", result["label"])
        self.assertEqual("Google Drive", result["provider"])
        self.assertFalse(result["check_overdue"])
        self.assertFalse(result["restore_verified"])
        self.assertFalse(result["provider_confirmed"])
        self.assertTrue(result["has_updated"])
        self.assertRegex(result["detail"], r" The last check that worked was on .+\.$")
        self.assertNotIn("has worked yet", result["detail"])
        self.assertEqual(
            "Make sure this PC is online and Google Drive for desktop is signed in. Rewindle checks again tonight.",
            result["next_step"],
        )

    def test_a_failed_check_without_a_check_that_worked_says_none_has(self) -> None:
        # Only a proof that says "verified" is a check that worked: a proof that failed or is still running is not.
        for state in ("failed", "verifying"):
            with self.subTest(state=state):
                result = self.invoke(
                    proof=self.direct_proof(state=state, verified_utc=ago(hours=5)),
                    failure=self.failure_record(),
                )
                self.assertEqual("Failed", result["kind"])
                self.assertIn("No check of the Google Drive copy has worked yet.", result["detail"])
                self.assertNotIn("The last check that worked", result["detail"])

    def test_a_failed_check_older_than_the_last_good_one_changes_nothing(self) -> None:
        stamp = ago(hours=3)
        for label, failed_utc in {
            "older": ago(hours=6),
            "same_moment": stamp,
        }.items():
            with self.subTest(label=label):
                result = self.invoke(
                    proof=self.direct_proof(verified_utc=stamp),
                    last_success=self.backup_evidence(started_utc=ago(hours=5), finished_utc=ago(hours=4)),
                    failure=self.failure_record(failed_utc=failed_utc),
                )
                self.assertEqual("RestoreVerified", result["kind"])
                self.assertEqual("Google Drive copy verified", result["label"])
                self.assertEqual("", result["next_step"])
                self.assertTrue(result["restore_verified"])

    def test_the_proofs_time_is_used_whatever_its_other_bindings_say(self) -> None:
        # A proof of another snapshot (Stale) or another path (StatusUnavailable) still says when a check last worked: a failure
        # older than that is a night that was fixed since, and one that is newer is what the card is about.
        for label, mutation, kind in (
            ("other_snapshot", {"snapshot_id": "6" * 64}, "Stale"),
            ("other_path", {"local_repository": r"H:\My Drive\Other\Repository"}, "StatusUnavailable"),
        ):
            with self.subTest(label=label, case="older failure"):
                result = self.invoke(
                    proof=self.direct_proof(verified_utc=ago(hours=3), **mutation),
                    failure=self.failure_record(failed_utc=ago(hours=5)),
                )
                self.assertEqual(kind, result["kind"])
                self.assertEqual("", result["next_step"])
            with self.subTest(label=label, case="newer failure"):
                result = self.invoke(
                    proof=self.direct_proof(verified_utc=ago(hours=5), **mutation),
                    failure=self.failure_record(failed_utc=ago(hours=3)),
                )
                self.assertEqual("Failed", result["kind"])
                self.assertIn("The last check that worked was on", result["detail"])
        # A proof that is not a direct proof at all (or has no readable time) has no time to compare, so the failure stands.
        for label, mutation in (
            ("no_time", {"verified_utc": "not a time"}),
            ("old_schema", {"schema_version": 1}),
            ("other_kind", {"proof_kind": "something_else"}),
        ):
            with self.subTest(label=label):
                result = self.invoke(
                    proof=self.direct_proof(**mutation),
                    failure=self.failure_record(failed_utc=ago(days=10)),
                )
                self.assertEqual("Failed", result["kind"])
                self.assertIn("No check of the Google Drive copy has worked yet.", result["detail"])

    def test_a_damaged_proof_does_not_hide_a_failed_check(self) -> None:
        result = self.invoke(proof_raw="{not-json", failure=self.failure_record())
        self.assertEqual("Failed", result["kind"])
        self.assertIn("No check of the Google Drive copy has worked yet.", result["detail"])
        retired = self.invoke(protected=self.legacy_mirror_status(), failure=self.failure_record())
        self.assertEqual("Failed", retired["kind"])

    def test_a_record_that_is_not_exactly_the_failure_record_is_ignored(self) -> None:
        mutations = {
            "schema_two": {"schema_version": 2},
            "schema_text": {"schema_version": "1"},
            "schema_missing": {"schema_version": None},
            "kind_other": {"record_kind": "direct_my_drive_cloud_repository_verification"},
            "kind_case": {"record_kind": "Direct_My_Drive_Cloud_Check_Failure"},
            "kind_missing": {"record_kind": None},
            "state_other": {"state": "verified"},
            "state_case": {"state": "Failed"},
            "state_missing": {"state": None},
            "time_unreadable": {"failed_utc": "yesterday evening"},
            "time_missing": {"failed_utc": None},
            "time_empty": {"failed_utc": ""},
        }
        for label, mutation in mutations.items():
            record = {key: value for key, value in self.failure_record(**mutation).items() if value is not None}
            with self.subTest(label=label, proof="none"):
                result = self.invoke(failure=record)
                self.assertEqual("NotConfigured", result["kind"])
                self.assertEqual("", result["next_step"])
            with self.subTest(label=label, proof="verified"):
                result = self.invoke(proof=self.direct_proof(), failure=record)
                self.assertEqual("RestoreVerified", result["kind"])
                self.assertEqual("", result["next_step"])
        for label, raw in {
            "not_json": "{not-json",
            "array": "[]",
            "text": '"failed"',
            "empty": "",
        }.items():
            with self.subTest(label=label, proof="none"):
                self.assertEqual("NotConfigured", self.invoke(failure_raw=raw)["kind"])
            with self.subTest(label=label, proof="verified"):
                self.assertEqual("RestoreVerified", self.invoke(proof=self.direct_proof(), failure_raw=raw)["kind"])

    def test_the_legacy_profile_does_not_look_for_a_failure_record(self) -> None:
        # The record is written beside the Rewindle proof only; the legacy profile's proof shape stays as it is.
        nothing = self.invoke(failure=self.failure_record(), engine="legacy")
        self.assertEqual("NotConfigured", nothing["kind"])
        self.assertEqual("", nothing["next_step"])
        verified = self.invoke(
            proof=self.legacy_proof(verified_utc=ago(hours=5)),
            last_success=self.backup_evidence(started_utc=ago(hours=7), finished_utc=ago(hours=6)),
            failure=self.failure_record(),
            engine="legacy",
        )
        self.assertEqual("RestoreVerified", verified["kind"])
        self.assertEqual("", verified["next_step"])

    def test_text_taken_from_a_failure_record_is_one_bounded_line(self) -> None:
        # The reason, the step and the next step are shown to the person. They cannot add lines or take unbounded room, and nothing that
        # looks like a credential detail is passed on.
        long_text = "word " * 400
        result = self.invoke(
            failure=self.failure_record(
                reason="First line.\r\nSecond line.\nThird\tline\u2028Fourth.\u0085Fifth.",
                step_label=long_text,
                next_step="Do this.\nThen that.\r\n" + long_text,
            )
        )
        self.assertEqual("Failed", result["kind"])
        lines = result["detail"].split("\n")
        self.assertEqual(2, len(lines), result["detail"])
        self.assertEqual("First line. Second line. Third line Fourth. Fifth.", lines[0])
        self.assertNotRegex(result["detail"] + result["next_step"], "[\r\t\u2028\u2029\u0085]")
        self.assertLess(len(lines[1]), 600, lines[1])
        self.assertNotIn("\n", result["next_step"])
        self.assertEqual(320, len(result["next_step"]), result["next_step"])
        self.assertTrue(result["next_step"].endswith("word\u2026"), result["next_step"])
        self.assertTrue(result["next_step"].startswith("Do this. Then that. word word"), result["next_step"])
        hidden = self.invoke(
            failure=self.failure_record(
                reason="The RESTIC_PASSWORD_COMMAND helper failed and the DPAPI blob was bad.",
                step_label="reading the recovery key",
                next_step="Open the password file.",
            )
        )
        self.assertEqual("Failed", hidden["kind"])
        for text in (hidden["detail"], hidden["next_step"]):
            self.assertNotIn("RESTIC_", text)
            self.assertNotIn("DPAPI", text)
            self.assertNotIn("password", text.lower())
            self.assertNotIn("recovery key", text)
        # The reason says its details are hidden; a step or a next step that would have to be hidden is left out, because "while
        # (details hidden)" and "next: (details hidden)" say nothing, and the person still gets a next step.
        lines = hidden["detail"].split("\n")
        self.assertEqual(2, len(lines), hidden["detail"])
        self.assertEqual("The details of this problem are hidden because they may include sign-in information.", lines[0])
        self.assertNotIn(" while ", lines[1])
        self.assertNotIn("hidden", lines[1])
        self.assertEqual(
            "Make sure Google Drive for desktop is running and this PC is online overnight. Rewindle checks again tonight.",
            hidden["next_step"],
        )

    def test_a_failure_record_with_missing_words_still_says_what_to_do(self) -> None:
        for label, record in {
            "empty": self.failure_record(reason="", step_label="", next_step=""),
            "blank": self.failure_record(reason="   ", step_label=" \n ", next_step="\t"),
            "absent": {
                key: value
                for key, value in self.failure_record().items()
                if key not in ("reason", "step_label", "next_step")
            },
            "not_text": self.failure_record(reason=7, step_label={"a": 1}, next_step=["b"]),
        }.items():
            with self.subTest(label=label):
                result = self.invoke(failure=record)
                self.assertEqual("Failed", result["kind"])
                lines = result["detail"].split("\n")
                self.assertEqual(2, len(lines), result["detail"])
                self.assertEqual("The check did not succeed.", lines[0])
                self.assertRegex(lines[1], r"^It stopped on .+\. No check of the Google Drive copy has worked yet\.$")
                self.assertNotIn(" while ", lines[1])
                self.assertEqual(
                    "Make sure Google Drive for desktop is running and this PC is online overnight. Rewindle checks again tonight.",
                    result["next_step"],
                )

    def test_fixture_proof_for_another_repository_than_the_plan_is_refused(self) -> None:
        # Consistent with itself and with the backup telemetry, but not with the installed plan: refused.
        elsewhere = r"G:\My Drive\Backups\Laptop"
        result = self.plan_bound_case(
            REPOSITORY_PATH,
            {"local_repository": elsewhere, "my_drive_root": r"G:\My Drive", "cloud_repository_path": "Backups/Laptop"},
        )
        self.assertEqual("StatusUnavailable", result["kind"])
        # Without an installed plan there is nothing to bind a proof to.
        unbound = self.invoke(proof=self.direct_proof(), configured_repository=None)
        self.assertEqual("StatusUnavailable", unbound["kind"])
        self.assertFalse(unbound["restore_verified"])

    def test_provider_is_only_named_by_direct_proof_evidence(self) -> None:
        nothing = self.invoke()
        self.assertEqual("NotConfigured", nothing["kind"])
        self.assertEqual("", nothing["provider"])
        retired = self.invoke(protected=self.legacy_mirror_status())
        self.assertEqual("", retired["provider"])

    def test_settings_and_diagnostics_use_direct_cloud_evidence(self) -> None:
        window = WINDOW_SOURCE.read_text(encoding="utf-8")
        diagnostic = DIAGNOSTIC_SOURCE.read_text(encoding="utf-8")
        telemetry = TELEMETRY_SOURCE.read_text(encoding="utf-8")
        self.assertIn("independent direct-cloud restore", window)
        self.assertNotIn(
            "Separates local mirror verification from Google Drive upload",
            window,
        )
        profiles = (DASHBOARD / "EngineProfile.cs").read_text(encoding="utf-8")
        self.assertIn("EngineProfile.Current.CloudVerificationProofPath()", telemetry)
        self.assertIn("EngineProfile.Current.CloudVerificationProofPath()", diagnostic)
        self.assertIn('profile.CloudVerificationDirectoryName = product + "CloudVerification";', profiles)
        self.assertIn('Path.Combine("evidence", "latest-verification.json")', profiles)
        self.assertIn("PostActivationVerificationPhase", telemetry)
        self.assertIn("directCloudVerification", diagnostic)
        self.assertIn("my-drive-latest-verification.json", diagnostic)

    def test_a_failed_check_reaches_the_page_and_the_settings_card_with_its_next_step(self) -> None:
        profiles = (DASHBOARD / "EngineProfile.cs").read_text(encoding="utf-8")
        telemetry = TELEMETRY_SOURCE.read_text(encoding="utf-8")
        window = WINDOW_SOURCE.read_text(encoding="utf-8")
        host = (DASHBOARD / "DashboardWindow.Web.cs").read_text(encoding="utf-8")
        types = (DASHBOARD / "web" / "src" / "native-types.ts").read_text(encoding="utf-8")
        card = (DASHBOARD / "web" / "components" / "primitives" / "ProtectionHealth.tsx").read_text(encoding="utf-8")
        # Only the Rewindle profile names a failure record (beside its proof); the legacy profile has none to look for.
        rewindle = profiles[profiles.index("private static EngineProfile CreateRewindle()"):profiles.index("private static EngineProfile CreateLegacy()")]
        legacy = profiles[profiles.index("private static EngineProfile CreateLegacy()"):profiles.index("private static EngineProfile CreateCommon(")]
        self.assertIn('profile.CloudVerificationFailureRelativePath = Path.Combine("evidence", "latest-failure.json");', rewindle)
        self.assertNotIn("CloudVerificationFailureRelativePath", legacy)
        self.assertIn("EngineProfile.Current.CloudVerificationFailurePath()", telemetry)
        self.assertIn("EngineProfile.Current.CloudVerificationFailurePathBeside(this.directCloudVerificationPath)", telemetry)
        # The record is read with the bounded reader and only counts when it is exactly the record.
        self.assertRegex(telemetry, r"ReadJsonObject\(\s*offsiteFailureRecordPath,\s*MaximumOffsiteJsonLength\)")
        self.assertIn('"direct_my_drive_cloud_check_failure"', telemetry)
        # The host sends the next step (empty when there is none), the page types it as additive and uses it for a failed check, and the
        # settings card shows it under the details.
        self.assertIn('offsite["nextStep"] = status == null ? string.Empty : status.NextStep ?? string.Empty;', host)
        self.assertRegex(types, r"/\*\* [^\n]*Additive: an older host does not send it\. \*/\n\s+nextStep\?: string;")
        self.assertIn("cloud.kind === 'Failed' ? cloud.nextStep?.trim() || `Make sure", card)
        self.assertIn("status.Kind == OffsiteStatusKind.Failed && !string.IsNullOrEmpty(status.NextStep)", window)
        self.assertIn('"Off-site copy detail: " + offsiteDetail', window)


if __name__ == "__main__":
    unittest.main()
