from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "src" / "dashboard"


class DashboardRepositoryUiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.manager = (DASHBOARD / "RepositoryManager.cs").read_text(encoding="utf-8")
        cls.dialog = (DASHBOARD / "RepositoryLocationWindow.cs").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")

    def method(self, source: str, name: str, next_name: str = "") -> str:
        # The whole body of one method, found by its declaration and matched braces. `next_name` is kept for
        # readability of the call sites; the dashboard no longer keeps these methods in a fixed order.
        start = re.search(rf"\n\s+(?:private|internal)\s+[^\r\n]+\s+{re.escape(name)}\(", source)
        self.assertIsNotNone(start, name)
        brace = source.index("{", start.end())
        depth = 0
        for index in range(brace, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    return source[start.start() : index + 1]
        self.fail(f"unbalanced method body: {name}")

    def test_build_includes_separated_repository_components(self) -> None:
        self.assertIn("RepositoryManager.cs", self.build)
        self.assertIn("RepositoryLocationWindow.cs", self.build)

    def test_protection_and_settings_surface_the_destination_action(self) -> None:
        self.assertIn(
            'SetAutomationId(changeRepositoryButton, "ChangeRepositoryButton")',
            self.window,
        )
        self.assertIn(
            'SetAutomationId(\n                settingsChangeRepositoryButton,\n                "SettingsChangeRepositoryButton")',
            self.window,
        )
        self.assertIn('title.Text = "Backup storage";', self.window)
        self.assertIn("settingsRepositoryValue.Text = repository;", self.window)
        self.assertIn("GetRepositoryVolumeText(currentSourceConfiguration.RepositoryPath)", self.window)
        self.assertIn("DescribeRepositoryVolume(repositoryPath, out driveReady)", self.window)

    def test_wizard_has_review_language_and_every_required_stage(self) -> None:
        for stage in (
            "Selecting",
            "Reviewing",
            "WaitingForApproval",
            "Copying",
            "Verifying",
            "Activating",
            "Complete",
            "Failed",
        ):
            self.assertIn(f"RepositoryLocationStage.{stage}", self.dialog)
        for copy in (
            "The repository is copied, verified, and only then activated.",
            "The old repository is kept untouched for recovery.",
            "This does not start a backup.",
            "Repository size:",
            "Free at destination:",
        ):
            self.assertIn(copy, self.dialog)
        # The Windows folder picker the rest of the app uses, owned by this window; the result is only a suggestion
        # that is canonicalized and checked here and again by the protected manager.
        self.assertIn("DashboardWindow.PickFolder(", self.dialog)
        self.assertIn("new WindowInteropHelper(this).Handle", self.dialog)

    def test_launcher_uses_exact_nonce_bound_contract(self) -> None:
        self.assertIn("get { return EngineProfile.Current.RepositoryRequestDomain; }", self.manager)
        profiles = (DASHBOARD / "EngineProfile.cs").read_text(encoding="utf-8")
        self.assertIn('profile.RepositoryRequestDomain = product + ".RepositoryRequest.v1";', profiles)
        digest = self.method(self.manager, "ComputeRequestDigest", "CanonicalizeRepository")
        self.assertIn('RequestDomain + "\\n" + userSid + "\\nrelocate\\n"', digest)
        self.assertIn('currentRepository + "\\n" + newRepository + "\\n"', digest)
        self.assertIn('configSha256.ToLowerInvariant() + "\\n" + nonce.ToLowerInvariant()', digest)
        for argument in (
            '"-Relocate"',
            '"-NewRepository"',
            '"-ExpectedUserSid"',
            '"-ExpectedCurrentRepository"',
            '"-ExpectedConfigSha256"',
            '"-ResultPath"',
            '"-RequestNonce"',
            '"-RequestDigest"',
        ):
            self.assertIn(argument, self.manager)
        self.assertIn('startInfo.Verb = "runas";', self.manager)

    def test_interrupted_move_has_a_dedicated_bound_recovery_contract(self) -> None:
        self.assertIn("get { return EngineProfile.Current.RepositoryRecoveryRequestDomain; }", self.manager)
        profiles = (DASHBOARD / "EngineProfile.cs").read_text(encoding="utf-8")
        self.assertIn(
            'profile.RepositoryRecoveryRequestDomain = product + ".RepositoryRecoveryRequest.v1";',
            profiles,
        )
        digest = self.method(
            self.manager,
            "ComputeRecoveryRequestDigest",
            "CanonicalizeRepository",
        )
        self.assertIn('RecoveryRequestDomain + "\\n" + userSid + "\\nrecover\\n"', digest)
        self.assertIn(
            'journalSha256.ToLowerInvariant() + "\\n" + nonce.ToLowerInvariant()',
            digest,
        )
        for argument in (
            '"-Recover"',
            '"-ExpectedJournalSha256"',
            '"-ExpectedUserSid"',
            '"-ResultPath"',
            '"-RequestNonce"',
            '"-RequestDigest"',
        ):
            self.assertIn(argument, self.manager)
        self.assertIn('GetRecoveryStatus()', self.manager)
        self.assertIn('!ElevatedRequestSecurity.HasProtectedResultAcl(journalPath, userSid, false)', self.manager)
        self.assertIn(
            '!ElevatedRequestSecurity.FixedEquals(ReadString(document, "action"), "recover")',
            self.manager,
        )
        self.assertIn(
            '!ElevatedRequestSecurity.FixedEquals(ReadString(document, "expected_journal_sha256"), journalSha256)',
            self.manager,
        )

    def test_interrupted_move_is_prominent_on_protection_and_settings(self) -> None:
        for automation_id in (
            "ProtectionRepositoryRecoveryCard",
            "SettingsRepositoryRecoveryCard",
            "ProtectionRepairRepositoryButton",
            "SettingsRepairRepositoryButton",
            "ProtectionRepositoryRecoveryProgress",
            "SettingsRepositoryRecoveryProgress",
        ):
            self.assertIn(f'"{automation_id}"', self.window)
        for copy in (
            "ACTION REQUIRED  \\u2022  BACKUPS PAUSED",
            "Interrupted repository move",
            "Repair interrupted move",
            "There is no dismiss or journal deletion action.",
            "BACKUPS PAUSED",
        ):
            self.assertIn(copy, self.window)
        self.assertIn("repairButton.Click += OnRepairRepositoryClick;", self.window)
        self.assertIn("progress.IsIndeterminate", self.window)
        self.assertIn("AutomationLiveSetting.Assertive", self.window)

    def test_recovery_journal_is_a_hard_gate_for_protected_mutations(self) -> None:
        gate = self.method(
            self.window,
            "RepositoryRecoveryBlocksMutations",
            "RepositoryRecoveryHasConflictingOperation",
        )
        self.assertIn("repositoryRecoveryInProgress", gate)
        self.assertIn("repositoryRecoveryStatus.Exists", gate)

        refresh = self.method(self.window, "RefreshDashboard", "RefreshSchedule")
        self.assertLess(
            refresh.index("RefreshRepositoryRecoveryStatus();"),
            refresh.index("RefreshSchedule("),
        )
        for start, end in (
            ("UpdateSourceButtons", "UpdateBackupButton"),
            ("UpdateBackupButton", "CancellationBlocksMutations"),
            ("UpdateScheduleButton", "SetScheduleStatus"),
            ("UpdateRepositoryButtons", "ApplyRepositoryButtonState"),
            ("OnChangeRepositoryClick", "OnEditScheduleClick"),
            ("OnEditScheduleClick", "HasNewerBackupTelemetry"),
            ("BackupBlocksSourceChanges", "OnBackupNowClick"),
            ("OnBackupNowClick", "OnAddSourceClick"),
        ):
            self.assertIn(
                "RepositoryRecoveryBlocksMutations()",
                self.method(self.window, start, end),
                start,
            )
        self.assertIn(
            "!RepositoryRecoveryBlocksMutations()",
            self.method(self.window, "RenderSourceOperationItem", "StartSourceOperationActivity"),
        )

    def test_repair_uses_background_bound_recovery_and_waits_for_journal_removal(self) -> None:
        repair = self.method(
            self.window,
            "OnRepairRepositoryClick",
            "OnChangeRepositoryClick",
        )
        for evidence in (
            "await Task.Run",
            "RepositoryManagerLauncher.Recover(",
            "ApplyRepositoryRecoveryProgress(progress)",
            "repositoryRecoveryInProgress = true",
            "repositoryOperationInProgress = true",
            "repositoryRecoveryInProgress = false",
            "repositoryOperationInProgress = false",
            "RefreshRepositoryRecoveryStatus();",
            "!repositoryRecoveryStatus.Exists",
            "RefreshDashboard();",
        ):
            self.assertIn(evidence, repair)
        self.assertIn("else if (!journalCleared)", repair)
        self.assertIn("Backups remain paused", repair)
        self.assertNotIn("File.Delete", repair)
        self.assertNotIn("Directory.Delete", repair)

    def test_untrusted_or_unrecoverable_journal_has_no_bypass(self) -> None:
        surface = self.method(
            self.window,
            "UpdateRepositoryRecoverySurface",
            "ApplyRepositoryRecoverySurface",
        )
        self.assertIn("status.IsRecoverable", surface)
        self.assertIn("!status.IsRecoverable", surface)
        self.assertIn('"Repair unavailable"', surface)
        self.assertIn('"Automatic and manual backups remain blocked.', surface)
        self.assertNotIn("dismiss", surface.lower())
        self.assertNotIn("File.Delete", surface)
        self.assertNotIn("Directory.Delete", surface)

    def test_a_running_move_is_not_called_interrupted(self) -> None:
        # The record of a move exists for the whole move. While the move runs (this dashboard's own, or one whose recorded
        # process is still that same running process) it keeps every change blocked but asks for no repair. Once that
        # process has ended, it is an interrupted move again. tests/Test-RepositoryRecoveryStatus.ps1 runs the decision.
        status = self.method(self.manager, "GetRecoveryStatus")
        self.assertLess(status.index("if (OwnMoveInFlight)"), status.index("ReadRecordedRecoveryStatus()"))
        self.assertIn("RememberedMoveOwnerIsRunning()", status)
        self.assertIn(
            "return ClassifyRecovery(TryReadSharedText(journalPath));",
            self.method(self.manager, "ReadRecordedRecoveryStatus"),
        )
        classify = self.method(self.manager, "ClassifyRecovery")
        self.assertIn("ProcessLiveness.IsSameProcessAlive(ownerProcessId, ownerCreationFileTimeUtc)", classify)
        self.assertIn("return RepositoryRecoveryStatus.Recoverable();", classify)
        owner = self.method(self.manager, "TryReadMoveOwner")
        self.assertIn('"owner_process_id"', owner)
        self.assertIn('"owner_process_creation_filetime_utc"', owner)
        # The manager replaces the record during the move; a reader that did not share deletion would make that fail.
        self.assertIn("FileShare.ReadWrite | FileShare.Delete", self.method(self.manager, "TryReadSharedText"))
        run = self.method(self.manager, "Run")
        began = run.index("BeginOwnMove();")
        self.assertLess(run.index("Process.Start(startInfo)"), began)
        self.assertLess(began, run.index("process.WaitForExit(500)"))
        self.assertIn("EndOwnMove();", run[run.index("finally", began):])
        recover = self.method(self.manager, "Recover")
        self.assertNotIn("BeginOwnMove", recover)
        self.assertLess(recover.index("status.IsMoveRunning"), recover.index("!status.IsRecoverable"))
        self.assertIn("'ProcessLiveness.cs'", self.build)
        liveness = (DASHBOARD / "ProcessLiveness.cs").read_text(encoding="utf-8")
        self.assertIn("internal static class ProcessLiveness", liveness)
        self.assertIn("public static bool IsSameProcessAlive(int processId, long creationFileTimeUtc)", liveness)
        engine = (ROOT / "src" / "Manage-Repository.ps1").read_text(encoding="utf-8")
        self.assertIn("owner_process_id = $PID", engine)
        self.assertIn("owner_process_creation_filetime_utc = Get-CurrentProcessCreationFileTime", engine)

    def test_a_running_move_blocks_changes_but_offers_no_repair(self) -> None:
        # The hard gate is the record's presence, running or not.
        gate = self.method(self.window, "RepositoryRecoveryBlocksMutations")
        self.assertIn("repositoryRecoveryStatus.Exists", gate)
        self.assertNotIn("IsMoveRunning", gate)
        surface = self.method(self.window, "UpdateRepositoryRecoverySurface")
        visible = surface[surface.index("bool visible"):]
        visible = visible[: visible.index(";")]
        self.assertIn("!status.IsMoveRunning", visible)
        can_repair = surface[surface.index("bool canRepair"):]
        can_repair = can_repair[: can_repair.index(";")]
        self.assertIn("!status.IsMoveRunning", can_repair)
        self.assertIn("status.IsRecoverable", can_repair)
        apply = self.method(self.window, "ApplyRepositoryRecoverySurface")
        self.assertLess(apply.index("repairButton.IsEnabled = canRepair;"), apply.index("if (!visible)"))
        click = self.method(self.window, "OnRepairRepositoryClick")
        self.assertIn("!repositoryRecoveryStatus.IsRecoverable", click)
        web = (DASHBOARD / "DashboardWindow.Web.cs").read_text(encoding="utf-8")
        recovery = self.method(web, "BuildWebRecoveryState")
        self.assertIn('recovery["repairNeeded"] = status.Exists && !moveRunning;', recovery)
        self.assertIn('recovery["moveRunning"] = moveRunning;', recovery)
        hero = self.method(self.window, "ApplyRepositoryRecoveryPrimaryStatus")
        self.assertLess(
            hero.index("else if (RepositoryMoveRunning())"),
            hero.index('"Backups paused: backup-location move unfinished"'),
        )
        self.assertIn('heroTitle.Text = "Moving your backup location";', hero)
        readiness = self.method(self.window, "UpdateRestoreReadiness")
        self.assertLess(
            readiness.index("else if (RepositoryMoveRunning())"),
            readiness.index("else if (repositoryRecoveryStatus.Exists)"),
        )
        for name in ("UpdateBackupButton", "UpdateScheduleButton", "UpdateRepositoryButtons"):
            self.assertIn("RepositoryMoveRunning()", self.method(self.window, name), name)
        app = (DASHBOARD / "web" / "src" / "App.tsx").read_text(encoding="utf-8")
        self.assertIn("if (state.recovery.moveRunning) return", app)
        types = (DASHBOARD / "web" / "src" / "native-types.ts").read_text(encoding="utf-8")
        self.assertIn("moveRunning?: boolean", types)

    def test_a_running_move_is_told_in_plain_calm_words(self) -> None:
        texts = re.findall(r'(?:OwnMoveRunningMessage|MoveRunningMessage) =\s+"([^"]+)"', self.manager)
        self.assertEqual(2, len(texts))
        hero = self.method(self.window, "ApplyRepositoryRecoveryPrimaryStatus")
        branch = hero[hero.index("else if (RepositoryMoveRunning())"):]
        texts += re.findall(r'"([^"]+)"', branch[: branch.index("}")])
        readiness = self.method(self.window, "UpdateRestoreReadiness")
        branch = readiness[readiness.index("else if (RepositoryMoveRunning())"):]
        texts += re.findall(r'"([^"]+)"', branch[: branch.index("}")])
        self.assertGreater(len(texts), 8)
        for text in texts:
            self.assertNotRegex(text.lower(), r"repositor|journal|snapshot|restic|interrupt|paused|action required", text)

    def test_only_bound_progress_and_final_result_are_accepted(self) -> None:
        for field in (
            "request_nonce",
            "request_digest",
            "request_user_sid",
            "action",
            "current_repository",
            "expected_config_sha256",
            "old_repository",
            "new_repository",
            "old_repository_retained",
        ):
            self.assertIn(f'"{field}"', self.manager)
        self.assertIn('string progressPath = resultPath + ".progress.json";', self.manager)
        self.assertIn('!ElevatedRequestSecurity.HasProtectedResultAcl(progressPath, userSid, false)', self.manager)
        for field in (
            "schema_version",
            "stage",
            "percent",
            "files_copied",
            "files_total",
            "bytes_copied",
            "bytes_total",
            "throughput_bytes_per_second",
            "estimated_seconds_remaining",
            "cancellable",
        ):
            self.assertIn(f'"{field}"', self.manager)
        self.assertIn('stage == "activating" && cancellable', self.manager)

    def test_repository_change_blocks_all_other_mutations(self) -> None:
        for start, end in (
            ("UpdateSourceButtons", "UpdateBackupButton"),
            ("UpdateScheduleButton", "SetScheduleStatus"),
            ("OnEditScheduleClick", "HasNewerBackupTelemetry"),
            ("BackupBlocksSourceChanges", "OnBackupNowClick"),
            ("OnBackupNowClick", "OnAddSourceClick"),
        ):
            self.assertIn(
                "repositoryOperationInProgress",
                self.method(self.window, start, end),
                start,
            )
        self.assertIn("CancellationBlocksMutations(lastSnapshot)", self.window)

    def test_dashboard_does_not_mutate_configuration_or_start_backup(self) -> None:
        combined = self.manager + self.dialog
        for forbidden in (
            "Start-ScheduledTask",
            "schtasks /Run",
            "WriteAllText(configuration.ConfigurationPath",
            "File.Delete(configuration.ConfigurationPath",
            "File.Move(configuration.ConfigurationPath",
        ):
            self.assertNotIn(forbidden, combined)
        self.assertIn("SourceConfiguration.Load()", self.dialog)
        self.assertIn("bool independentlyVerified = result.Succeeded", self.dialog)
        self.assertIn("Directory.Exists(result.OldRepository)", self.dialog)


if __name__ == "__main__":
    unittest.main()
