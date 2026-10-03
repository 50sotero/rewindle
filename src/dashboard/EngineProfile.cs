using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace ResticBackuper.Dashboard
{
    // Whether an engine's protected install root holds an installed backup configuration, asked the same way
    // SourceConfiguration.Load asks it (File.GetAttributes on <install root>\backup-config.json, read-only).
    internal enum EngineInstallState
    {
        // Nothing there, or a folder where the configuration file should be: not installed.
        Absent,
        Present,
        // Windows would not say (access denied, a device error, an unusable Program Files folder). It counts as
        // installed, so that engine is chosen and its own, more specific error is what the dashboard reports; a root
        // that cannot be looked at never hands the dashboard to another engine.
        Indeterminate
    }

    // What the dashboard says about the anomaly review, which means something different to each engine: the
    // Rewindle engine records an acknowledgement that gates nothing (DriveFS upload is never paused), the legacy
    // personal edition records an approval that releases one generation for off-site promotion.
    internal sealed class AnomalyReviewWording
    {
        public string ButtonHelp;
        public string ConfirmQuestion;
        public string ConfirmEffects;
        public string RecordingLabel;
        public string RecordingName;
        public string CancelledMessage;
        public string NotRecordedMessage;
        public string NotRecordedTitle;
        public string RecordedTitle;
        public string RecordedDetail;
        public string HeroTitle;
        public string HeroCaption;
        public string HeroValue;
        public string HeroHint;
        public string HoldHeroDetail;
        public string TrayDetail;
        public string RecordedBadge;
        public string StatusLabel;
        public string StatusDetail;
        public string HoldDetailSuffix;
        public string HelperStoppedMessage;
        public string MismatchMessage;
    }

    // One engine and every identity the dashboard uses to find it, ask it for something and trust what it answers:
    // the protected install and state roots, the scheduled tasks, the task launcher, the request domains and result
    // schemas the elevated managers bind to, the manager scripts, the cloud-verification and drill folders, the
    // dashboard's own per-user folder and its single-instance names. Nothing outside this class names an engine.
    //
    // Two engines are built in. Rewindle (the default) is the public engine and installer in this repository. The
    // legacy personal edition keeps existing installs of the earlier personal engine working. A profile only
    // changes which names are used: every check made with them (UAC, nonce- and digest-bound requests, path, ACL,
    // reparse-point and runtime-manifest checks) is the same for both.
    internal sealed class EngineProfile
    {
        internal const string RewindleId = "rewindle";
        internal const string LegacyId = "legacy";
        internal const string ConfigurationFileName = "backup-config.json";

        private static readonly object gate = new object();
        private static readonly EngineProfile rewindle = CreateRewindle();
        private static readonly EngineProfile legacy = CreateLegacy();
        private static EngineProfile current = rewindle;
        private static EngineFolderRoots folderRootsOverride;

        private EngineProfile()
        {
        }

        public string Id { get; private set; }
        public string DisplayName { get; private set; }
        // The folder name under Program Files (install root) and under ProgramData (protected state).
        public string ProductDirectoryName { get; private set; }
        public string BackupTaskName { get; private set; }
        public string DashboardTaskName { get; private set; }
        public string GoogleDriveSyncTaskName { get; private set; }
        public string LauncherFileName { get; private set; }
        public string DashboardExecutableName { get; private set; }
        public string CloudVerificationDirectoryName { get; private set; }
        // The latest direct cloud proof, relative to the cloud-verification folder.
        public string CloudVerificationProofRelativePath { get; private set; }
        public string RestoreDrillsDirectoryName { get; private set; }
        // The protected recovery-tools folder under ProgramData that the engine uses for a streamed Google Drive
        // repository, or null when the engine keeps recovery tools only where the plan configures them.
        public string RecoveryToolsDirectoryName { get; private set; }
        public string LegacyGoogleDriveSyncDirectoryName { get; private set; }
        public string DashboardDataDirectoryName { get; private set; }
        public string IsolatedPresentationDirectoryName { get; private set; }
        public string IsolatedWebViewDirectoryName { get; private set; }
        public string EngineVersionFileName { get; private set; }

        public string InstanceMutexName { get; private set; }
        public string ShowEventName { get; private set; }
        public string PresentationMutexName { get; private set; }
        public string PresentationShowEventName { get; private set; }
        public string CancelEventPrefix { get; private set; }

        public string SourceRequestDomain { get; private set; }
        public string RestoreRequestDomain { get; private set; }
        public string RepositoryRequestDomain { get; private set; }
        public string RepositoryRecoveryRequestDomain { get; private set; }
        public string ScheduleRequestDomain { get; private set; }
        public string TaskXmlFingerprintDomain { get; private set; }
        public string BackupControlRequestDomain { get; private set; }
        public string SnapshotListSchema { get; private set; }
        public string SnapshotTreeSchema { get; private set; }
        public string RestoreReportSchema { get; private set; }
        public string RecoveryHealthSchema { get; private set; }
        public string AnomalyReviewSchema { get; private set; }
        public string DiagnosticsSchema { get; private set; }

        public string SourceManagerFileName { get; private set; }
        public string ScheduleManagerFileName { get; private set; }
        public string BackupManagerFileName { get; private set; }
        public string RepositoryManagerFileName { get; private set; }
        public string RestoreManagerFileName { get; private set; }
        public string PythonRelativePath { get; private set; }

        // The scopes an anomaly acknowledgement written by this engine may carry; one of them must be present.
        public IList<string> AnomalyReviewScopes { get; private set; }
        public AnomalyReviewWording AnomalyReview { get; private set; }
        // The Rewindle verifier binds every proof to its immutable evidence copy, the cloud-verification asset
        // manifest and the binary-stream capture mode, so a proof without them is incomplete. The legacy verifier
        // records only the immutable evidence hash. (Neither engine pins a repository path: a proof is bound to the
        // repository of the installed backup plan, see TelemetryReader.BuildOffsiteStatus.)
        public bool CloudProofRequiresAssetBinding { get; private set; }

        internal static EngineProfile Rewindle
        {
            get { return rewindle; }
        }

        internal static EngineProfile Legacy
        {
            get { return legacy; }
        }

        internal static IList<EngineProfile> All
        {
            get { return new[] { rewindle, legacy }; }
        }

        // The engine this process talks to. Chosen once at start-up (Program.Main); Rewindle until then.
        internal static EngineProfile Current
        {
            get
            {
                lock (gate)
                {
                    return current;
                }
            }
        }

        internal static void Activate(EngineProfile profile)
        {
            if (profile == null)
            {
                throw new ArgumentNullException("profile");
            }
            lock (gate)
            {
                current = profile;
            }
        }

        // "rewindle" or "legacy", as --engine takes it. Anything else is refused, never guessed.
        internal static EngineProfile FromId(string id)
        {
            if (string.Equals(id, RewindleId, StringComparison.OrdinalIgnoreCase))
            {
                return rewindle;
            }
            if (string.Equals(id, LegacyId, StringComparison.OrdinalIgnoreCase))
            {
                return legacy;
            }
            throw new ArgumentException(
                "--engine must be \"" + RewindleId + "\" or \"" + LegacyId + "\".");
        }

        // Picks the engine. An explicit --engine is honoured as given (if its install root holds no configuration the
        // dashboard says that engine is not installed). Otherwise the engine whose protected install root holds a
        // configuration is used, Rewindle first when both do. When neither does, Rewindle is chosen and reported as
        // not installed. Read-only: nothing is created or changed.
        internal static EngineSelection Select(string requestedId)
        {
            List<EngineProbe> probes = new List<EngineProbe>();
            foreach (EngineProfile profile in All)
            {
                probes.Add(Probe(profile));
            }
            EngineProbe chosen = null;
            bool requested = !string.IsNullOrEmpty(requestedId);
            if (requested)
            {
                EngineProfile wanted = FromId(requestedId);
                foreach (EngineProbe probe in probes)
                {
                    if (ReferenceEquals(probe.Profile, wanted))
                    {
                        chosen = probe;
                    }
                }
            }
            else
            {
                foreach (EngineProbe probe in probes)
                {
                    if (probe.State != EngineInstallState.Absent)
                    {
                        chosen = probe;
                        break;
                    }
                }
                if (chosen == null)
                {
                    chosen = probes[0];
                }
            }
            return new EngineSelection(chosen.Profile, chosen.State, requested, probes);
        }

        internal static EngineProbe Probe(EngineProfile profile)
        {
            string installRoot = string.Empty;
            try
            {
                installRoot = profile.InstallRoot();
                FileAttributes attributes = File.GetAttributes(
                    Path.Combine(installRoot, ConfigurationFileName));
                return new EngineProbe(
                    profile,
                    installRoot,
                    (attributes & FileAttributes.Directory) != 0
                        ? EngineInstallState.Absent
                        : EngineInstallState.Present);
            }
            catch (FileNotFoundException)
            {
                return new EngineProbe(profile, installRoot, EngineInstallState.Absent);
            }
            catch (DirectoryNotFoundException)
            {
                return new EngineProbe(profile, installRoot, EngineInstallState.Absent);
            }
            catch (Exception)
            {
                return new EngineProbe(profile, installRoot, EngineInstallState.Indeterminate);
            }
        }

        // Every component reads the Windows folders through here, so a test can move all of them into a disposable
        // folder at once (see UseFolderRootsForTesting) and nothing it runs looks at a real installation.
        internal static EngineFolderRoots FolderRoots
        {
            get
            {
                lock (gate)
                {
                    if (folderRootsOverride != null)
                    {
                        return folderRootsOverride;
                    }
                }
                return new EngineFolderRoots(
                    Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    Path.GetTempPath());
            }
        }

        // For the regression suites only: every Windows folder an engine path is built from is moved under one
        // disposable folder in the current user's temporary directory. A root outside it is refused, so this can
        // never point the dashboard at a real installation. Null or empty restores the real folders.
        internal static void UseFolderRootsForTesting(string disposableRoot)
        {
            if (string.IsNullOrEmpty(disposableRoot))
            {
                lock (gate)
                {
                    folderRootsOverride = null;
                }
                return;
            }
            if (!Path.IsPathRooted(disposableRoot))
            {
                throw new ArgumentException("The disposable test root must be absolute.", "disposableRoot");
            }
            string temporary = Path.GetFullPath(Path.GetTempPath())
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string root = Path.GetFullPath(disposableRoot)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(root, temporary, StringComparison.OrdinalIgnoreCase) ||
                !root.StartsWith(temporary + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "The disposable test root must be inside the current user's temporary folder.",
                    "disposableRoot");
            }
            EngineFolderRoots roots = new EngineFolderRoots(
                Path.Combine(root, "ProgramFiles"),
                Path.Combine(root, "ProgramData"),
                Path.Combine(root, "LocalAppData"),
                Path.Combine(root, "Temp"));
            lock (gate)
            {
                folderRootsOverride = roots;
            }
        }

        // The protected install root: this engine's folder under Program Files, where its installer puts it and every
        // other component looks for it. An unreadable Program Files folder fails closed: a relative path must never
        // become the root that protected paths are compared with.
        internal string InstallRoot()
        {
            string programFiles = FolderRoots.ProgramFiles;
            if (string.IsNullOrWhiteSpace(programFiles) || !Path.IsPathRooted(programFiles))
            {
                throw new InvalidOperationException("The Program Files folder could not be located.");
            }
            return Path.GetFullPath(Path.Combine(programFiles, ProductDirectoryName));
        }

        internal string ConfigurationPath()
        {
            return Path.Combine(InstallRoot(), ConfigurationFileName);
        }

        internal string ManagerPath(string managerFileName)
        {
            return Path.Combine(InstallRoot(), managerFileName);
        }

        // <ProgramData>\<product>: the protected state the engine writes and the elevated managers put results in.
        internal string StateDirectory()
        {
            return Path.Combine(FolderRoots.ProgramData, ProductDirectoryName);
        }

        internal string StateResultDirectory(string resultFolderName)
        {
            return Path.Combine(StateDirectory(), resultFolderName);
        }

        // The latest direct cloud proof, or an empty string when ProgramData cannot be located.
        internal string CloudVerificationProofPath()
        {
            string programData = FolderRoots.ProgramData;
            return string.IsNullOrWhiteSpace(programData)
                ? string.Empty
                : Path.Combine(programData, CloudVerificationDirectoryName, CloudVerificationProofRelativePath);
        }

        // The engine's fixed protected recovery-tools folder, or an empty string when it has none or ProgramData cannot
        // be located. The plan's own recovery_tools_directory is read separately.
        internal string ProtectedRecoveryToolsDirectory()
        {
            string programData = FolderRoots.ProgramData;
            return string.IsNullOrEmpty(RecoveryToolsDirectoryName) || string.IsNullOrWhiteSpace(programData)
                ? string.Empty
                : Path.Combine(programData, RecoveryToolsDirectoryName);
        }

        internal string RestoreDrillsDirectory()
        {
            return Path.Combine(FolderRoots.ProgramData, RestoreDrillsDirectoryName);
        }

        // The retired local-mirror status file under the user's own profile, or an empty string when the profile
        // folder cannot be located. It is only ever noticed, never interpreted (see TelemetryReader).
        internal string LegacyLocalSyncStatusPath()
        {
            string localApplicationData = FolderRoots.LocalAppData;
            return string.IsNullOrWhiteSpace(localApplicationData)
                ? string.Empty
                : Path.Combine(localApplicationData, LegacyGoogleDriveSyncDirectoryName, "status.json");
        }

        // The dashboard's own per-user folder (the presentation store: appearance and motion settings, run history,
        // web view profile, crash log), or an empty string when the profile folder cannot be located.
        internal string DashboardDataDirectory()
        {
            string localApplicationData = FolderRoots.LocalAppData;
            return string.IsNullOrWhiteSpace(localApplicationData)
                ? string.Empty
                : Path.Combine(localApplicationData, DashboardDataDirectoryName);
        }

        internal string IsolatedPresentationDirectory()
        {
            return Path.Combine(FolderRoots.Temp, IsolatedPresentationDirectoryName);
        }

        internal string IsolatedWebViewDirectory()
        {
            return Path.Combine(FolderRoots.Temp, IsolatedWebViewDirectoryName);
        }

        internal string CancelEventName(string cancelChannelId)
        {
            return CancelEventPrefix + cancelChannelId;
        }

        internal bool IsAnomalyReviewScope(string scope)
        {
            foreach (string accepted in AnomalyReviewScopes)
            {
                if (string.Equals(accepted, scope, StringComparison.Ordinal))
                {
                    return true;
                }
            }
            return false;
        }

        // The installed engine's version, for diagnostics and the setup notice. Read-only and bounded: the version
        // file the Rewindle installer copies next to its managers, as one semantic-version line. An engine that keeps
        // no version file (the legacy personal edition) says so. Never throws.
        internal string ReadEngineVersion()
        {
            if (string.IsNullOrEmpty(EngineVersionFileName))
            {
                return "not recorded by this edition";
            }
            try
            {
                string path = Path.Combine(InstallRoot(), EngineVersionFileName);
                FileInfo file = new FileInfo(path);
                if (!file.Exists || (file.Attributes & FileAttributes.ReparsePoint) != 0 || file.Length > 256)
                {
                    return "unknown";
                }
                string text;
                using (FileStream stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false, true), true))
                {
                    text = reader.ReadToEnd().Trim();
                }
                return Regex.IsMatch(text, @"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z")
                    ? text
                    : "unknown";
            }
            catch (Exception)
            {
                return "unknown";
            }
        }

        // ---- Restore approval session (one Windows approval per guided restore) -------------------------------------
        // Kept together, and derived from the profile's own names, so this block merges on its own. Only the Rewindle
        // engine has a session broker (Manage-Restore.ps1 -Operation session); for the legacy personal edition these are
        // null and every protected restore step stays its own elevated request. Whether the installed engine really serves
        // sessions is read from <install root>\engine-capabilities.json (RestoreSessionCapability in RestoreManager.cs).
        internal const string EngineCapabilitiesFileName = "engine-capabilities.json";

        internal string EngineCapabilitiesSchema
        {
            get { return ProductDirectoryName + ".EngineCapabilities.v1"; }
        }

        internal string RestoreSessionRequestDomain
        {
            get { return Id == RewindleId ? ProductDirectoryName + ".RestoreRequest.v3" : null; }
        }

        internal string RestoreSessionProtocol
        {
            get { return Id == RewindleId ? ProductDirectoryName + ".RestoreSession.v1" : null; }
        }

        // A session's pipe name is this prefix and 64 random lower-case hex digits.
        internal string RestoreSessionPipePrefix
        {
            get { return Id == RewindleId ? ProductDirectoryName + ".RestoreSession." : null; }
        }
        // ---- end of the restore approval session block ---------------------------------------------------------------

        private static EngineProfile CreateRewindle()
        {
            EngineProfile profile = CreateCommon("ResticBackuper");
            profile.Id = RewindleId;
            profile.DisplayName = "Rewindle engine";
            profile.LauncherFileName = "ResticBackuperTaskLauncher.exe";
            profile.DashboardExecutableName = "ResticBackuperDashboard.exe";
            profile.CloudVerificationProofRelativePath = Path.Combine("evidence", "latest-verification.json");
            profile.IsolatedWebViewDirectoryName = "ResticBackuperDashboardBeautifulUIWebView2";
            profile.EngineVersionFileName = "VERSION";
            profile.RecoveryToolsDirectoryName = "ResticBackuperRecoveryTools";
            profile.AnomalyReviewScopes = Array.AsReadOnly(new[]
            {
                "anomaly_review_acknowledgement",
                // Written by earlier Rewindle alphas; still a reviewed, exact acknowledgement.
                "offsite_promotion"
            });
            profile.CloudProofRequiresAssetBinding = true;
            profile.AnomalyReview = new AnomalyReviewWording
            {
                ButtonHelp = "Review and acknowledge only this exact generation. The deletion and retention hold remains; DriveFS upload is not paused.",
                ConfirmQuestion = "Acknowledge this exact verified change set?",
                ConfirmEffects =
                    "This acknowledgement:\n" +
                    "\u2022 records that you reviewed this exact generation\n" +
                    "\u2022 does not pause or gate Google Drive upload from the live DriveFS repository\n" +
                    "\u2022 leaves the maintenance hold in place for deletion and retention actions\n" +
                    "\u2022 does not modify snapshots or repository data",
                RecordingLabel = "Recording acknowledgement...",
                RecordingName = "Recording exact anomaly acknowledgement",
                CancelledMessage = "Windows approval was cancelled. No review acknowledgement was recorded, and no snapshot or repository data was changed. DriveFS upload was never paused.",
                NotRecordedMessage = "The exact change set was not acknowledged.",
                NotRecordedTitle = "Changes not acknowledged",
                RecordedTitle = "Changes acknowledged",
                RecordedDetail = "This exact verified generation was reviewed. The deletion and retention hold remains; DriveFS upload is not paused.",
                HeroTitle = "Backup verified - changes acknowledged",
                HeroCaption = "Review",
                HeroValue = "Acknowledged",
                HeroHint = "This exact generation was reviewed; deletion and retention remain on hold. DriveFS upload is not paused",
                TrayDetail = "This exact generation was reviewed; deletion and retention remain on hold. DriveFS upload is not paused.",
                HoldHeroDetail = "The snapshot is safe; review is required for future deletion or retention actions. DriveFS upload is not paused",
                RecordedBadge = "REVIEW ACKNOWLEDGED",
                StatusLabel = "Backup verified \u2014 changes acknowledged",
                StatusDetail = "The suspicious change set was explicitly reviewed for this exact generation. The maintenance hold remains for any future deletion or retention action; DriveFS upload is not paused.",
                HoldDetailSuffix = " triggered a review and maintenance hold. No snapshots were deleted, and this hold does not pause a live DriveFS upload.",
                HelperStoppedMessage = "Anomaly review stopped safely without recording an acknowledgement.",
                MismatchMessage = "The suspicious change set could not be acknowledged safely."
            };
            return profile;
        }

        private static EngineProfile CreateLegacy()
        {
            EngineProfile profile = CreateCommon("ResticPersonalBackup");
            profile.Id = LegacyId;
            profile.DisplayName = "Legacy personal edition";
            profile.LauncherFileName = "ResticBackupTaskLauncher.exe";
            profile.DashboardExecutableName = "ResticBackupDashboard.exe";
            profile.CloudVerificationProofRelativePath = "latest-verification.json";
            profile.IsolatedWebViewDirectoryName = "ResticPersonalBackupBeautifulUIWebView2";
            profile.EngineVersionFileName = null;
            profile.RecoveryToolsDirectoryName = null;
            profile.AnomalyReviewScopes = Array.AsReadOnly(new[] { "offsite_promotion" });
            profile.CloudProofRequiresAssetBinding = false;
            profile.AnomalyReview = new AnomalyReviewWording
            {
                ButtonHelp = "Review and explicitly approve only this exact generation for off-site promotion. The deletion and retention hold remains.",
                ConfirmQuestion = "Approve this exact verified change set for off-site promotion?",
                ConfirmEffects =
                    "This approval:\n" +
                    "\u2022 permits only this exact generation to enter the off-site copy pipeline\n" +
                    "\u2022 leaves the maintenance hold in place for deletion and retention actions\n" +
                    "\u2022 does not modify snapshots or repository data",
                RecordingLabel = "Recording approval...",
                RecordingName = "Recording exact anomaly approval",
                CancelledMessage = "Windows approval was cancelled. Off-site promotion remains paused, and no snapshot or repository data was changed.",
                NotRecordedMessage = "The exact change set was not approved. Off-site promotion remains paused.",
                NotRecordedTitle = "Changes not approved",
                RecordedTitle = "Off-site copy approved",
                RecordedDetail = "This exact verified generation may be promoted off-site. The deletion and retention hold remains.",
                HeroTitle = "Backup verified - off-site copy approved",
                HeroCaption = "Off-site approval",
                HeroValue = "Approved",
                HeroHint = "This exact generation may be copied off-site; the deletion and retention hold remains",
                TrayDetail = "This exact generation may be promoted; deletion and retention remain on hold.",
                HoldHeroDetail = "The snapshot is safe; off-site promotion is paused until the change set is reviewed",
                RecordedBadge = "OFF-SITE APPROVED",
                StatusLabel = "Backup verified \u2014 off-site copy approved",
                StatusDetail = "The suspicious change set was explicitly approved for this exact off-site generation. The maintenance hold remains for any future deletion or retention action.",
                HoldDetailSuffix = " triggered a safety hold. Off-site promotion is paused; no snapshots were deleted.",
                HelperStoppedMessage = "Anomaly review stopped safely without approving off-site promotion.",
                MismatchMessage = "The suspicious change set could not be approved safely."
            };
            return profile;
        }

        // The names both engines derive the same way from their product name, and the files they share.
        private static EngineProfile CreateCommon(string product)
        {
            EngineProfile profile = new EngineProfile();
            profile.ProductDirectoryName = product;
            profile.BackupTaskName = product;
            profile.DashboardTaskName = product + "Dashboard";
            profile.GoogleDriveSyncTaskName = product + "GoogleDriveSync";
            profile.CloudVerificationDirectoryName = product + "CloudVerification";
            profile.RestoreDrillsDirectoryName = product + "-RestoreDrills";
            profile.LegacyGoogleDriveSyncDirectoryName = product + "GoogleDriveSync";
            profile.DashboardDataDirectoryName = product + "Dashboard";
            profile.IsolatedPresentationDirectoryName = product + "BeautifulUI";

            profile.InstanceMutexName = @"Local\" + product + "Dashboard.Instance";
            profile.ShowEventName = @"Local\" + product + "Dashboard.Show";
            profile.PresentationMutexName = @"Local\" + product + "Dashboard.Presentation.Instance";
            profile.PresentationShowEventName = @"Local\" + product + "Dashboard.Presentation.Show";
            profile.CancelEventPrefix = @"Local\" + product + ".Cancel.";

            profile.SourceRequestDomain = product + ".SourceRequest.v1";
            profile.RestoreRequestDomain = product + ".RestoreRequest.v2";
            profile.RepositoryRequestDomain = product + ".RepositoryRequest.v1";
            profile.RepositoryRecoveryRequestDomain = product + ".RepositoryRecoveryRequest.v1";
            profile.ScheduleRequestDomain = product + ".ScheduleRequest.v1";
            profile.TaskXmlFingerprintDomain = product + ".TaskXml.v1";
            profile.BackupControlRequestDomain = product + ".BackupControlRequest.v1";
            profile.SnapshotListSchema = product + ".SnapshotList.v1";
            profile.SnapshotTreeSchema = product + ".SnapshotTree.v1";
            profile.RestoreReportSchema = product + ".RestoreReport.v1";
            profile.RecoveryHealthSchema = product + ".RecoveryHealth.v1";
            profile.AnomalyReviewSchema = product + ".AnomalyReview.v1";
            profile.DiagnosticsSchema = product + ".Diagnostics.v1";

            profile.SourceManagerFileName = "Manage-Sources.ps1";
            profile.ScheduleManagerFileName = "Manage-Schedule.ps1";
            profile.BackupManagerFileName = "Manage-Backup.ps1";
            profile.RepositoryManagerFileName = "Manage-Repository.ps1";
            profile.RestoreManagerFileName = "Manage-Restore.ps1";
            profile.PythonRelativePath = Path.Combine("Python", "python.exe");
            return profile;
        }
    }

    // The Windows folders engine paths are built from.
    internal sealed class EngineFolderRoots
    {
        public EngineFolderRoots(string programFiles, string programData, string localAppData, string temp)
        {
            ProgramFiles = programFiles ?? string.Empty;
            ProgramData = programData ?? string.Empty;
            LocalAppData = localAppData ?? string.Empty;
            Temp = temp ?? string.Empty;
        }

        public string ProgramFiles { get; private set; }
        public string ProgramData { get; private set; }
        public string LocalAppData { get; private set; }
        public string Temp { get; private set; }
    }

    internal sealed class EngineProbe
    {
        public EngineProbe(EngineProfile profile, string installRoot, EngineInstallState state)
        {
            Profile = profile;
            InstallRoot = installRoot ?? string.Empty;
            State = state;
        }

        public EngineProfile Profile { get; private set; }
        public string InstallRoot { get; private set; }
        public EngineInstallState State { get; private set; }
    }

    internal sealed class EngineSelection
    {
        public EngineSelection(
            EngineProfile profile,
            EngineInstallState state,
            bool requested,
            IList<EngineProbe> probes)
        {
            Profile = profile;
            State = state;
            Requested = requested;
            Probes = probes;
        }

        public EngineProfile Profile { get; private set; }
        public EngineInstallState State { get; private set; }
        // True when --engine chose it rather than the install roots.
        public bool Requested { get; private set; }
        public IList<EngineProbe> Probes { get; private set; }

        public bool Installed
        {
            get { return State != EngineInstallState.Absent; }
        }

        // Where each engine was looked for, for the "Engine not installed" notice and diagnostics.
        public IList<string> SearchedConfigurationPaths()
        {
            List<string> paths = new List<string>();
            foreach (EngineProbe probe in Probes)
            {
                if (!string.IsNullOrEmpty(probe.InstallRoot))
                {
                    paths.Add(Path.Combine(probe.InstallRoot, EngineProfile.ConfigurationFileName));
                }
            }
            return paths;
        }

        public string Describe()
        {
            return string.Format(
                CultureInfo.InvariantCulture,
                "{0} ({1}{2})",
                Profile.DisplayName,
                Installed ? "installed" : "not installed",
                Requested ? ", chosen with --engine" : string.Empty);
        }
    }
}
