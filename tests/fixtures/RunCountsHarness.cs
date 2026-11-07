using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    // Drives the telemetry reader on fixtures under a disposable folder and prints what it found as JSON, for
    // tests/test_dashboard_run_counts.py. Every engine path points into that folder (UseFolderRootsForTesting); nothing real
    // is read or written.
    internal static class RunCountsHarness
    {
        private const BindingFlags Private = BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;
        private const string PlanId = "4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31";
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        private static string root;
        private static int fixtureNumber;

        private static Dictionary<string, object> Document(string json)
        {
            return (Dictionary<string, object>)Json.DeserializeObject(json);
        }

        private static object Call(object target, string name, params object[] arguments)
        {
            MethodInfo method = typeof(TelemetryReader).GetMethod(name, Private);
            if (method == null)
            {
                throw new MissingMethodException("TelemetryReader", name);
            }
            return method.Invoke(method.IsStatic ? null : target, arguments);
        }

        private static string NewFolder(string name)
        {
            fixtureNumber++;
            string path = Path.Combine(root, name + "-" + fixtureNumber.ToString(CultureInfo.InvariantCulture));
            Directory.CreateDirectory(path);
            return path;
        }

        private static void WriteJson(string path, object value)
        {
            File.WriteAllText(path, Json.Serialize(value), new UTF8Encoding(false));
        }

        private static Dictionary<string, object> Summary(object filesNew, object filesChanged, object filesUnmodified)
        {
            Dictionary<string, object> summary = new Dictionary<string, object>();
            summary["message_type"] = "summary";
            summary["total_files_processed"] = 12393;
            summary["total_bytes_processed"] = 4883456789L;
            summary["data_added"] = 25690112;
            summary["total_duration"] = 3.5;
            if (filesNew != null) summary["files_new"] = filesNew;
            if (filesChanged != null) summary["files_changed"] = filesChanged;
            if (filesUnmodified != null) summary["files_unmodified"] = filesUnmodified;
            return summary;
        }

        private static Dictionary<string, object> Status(string runId, string state, Dictionary<string, object> summary)
        {
            Dictionary<string, object> status = new Dictionary<string, object>();
            status["schema_version"] = 1;
            status["run_id"] = runId;
            status["state"] = state;
            status["started_utc"] = "2026-11-05T01:00:00Z";
            status["finished_utc"] = "2026-11-05T01:05:00Z";
            status["summary"] = summary;
            return status;
        }

        // A status document as the reader parses it from disk (numbers as the serializer reads them).
        private static Dictionary<string, object> AsRead(object value)
        {
            return Document(Json.Serialize(value));
        }

        private static Dictionary<string, object> Counts(RunMetricRecord record)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["new"] = record.FilesNew;
            result["changed"] = record.FilesChanged;
            result["unmodified"] = record.FilesUnmodified;
            result["known"] = record.HasChangeCounts;
            return result;
        }

        private static Dictionary<string, object> Inventory()
        {
            Dictionary<string, object> inventory = new Dictionary<string, object>();
            inventory["schema_version"] = 1;
            inventory["count"] = 412;
            inventory["oldest_utc"] = "2025-03-03T12:00:04Z";
            inventory["newest_utc"] = "2026-11-06T01:00:03Z";
            inventory["counted_utc"] = "2026-11-06T01:02:41.512034Z";
            inventory["rule"] = "restore_browse";
            return inventory;
        }

        private static Dictionary<string, object> VerifiedRecord(string repository)
        {
            Dictionary<string, object> record = Status("verified-run", "success", Summary(3, 1, 9));
            record["verification_complete"] = true;
            record["plan_id"] = PlanId;
            record["repository"] = repository;
            record["snapshot_inventory"] = Inventory();
            return record;
        }

        private static Dictionary<string, object> Describe(BackupRangeView range)
        {
            if (range == null)
            {
                return null;
            }
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["source"] = range.Source;
            result["plan"] = range.PlanId;
            result["repository"] = range.RepositoryPath;
            result["count"] = range.Count;
            result["oldest"] = range.OldestUtc.ToString("o", CultureInfo.InvariantCulture);
            result["newest"] = range.NewestUtc.ToString("o", CultureInfo.InvariantCulture);
            result["counted"] = range.CountedUtc.ToString("o", CultureInfo.InvariantCulture);
            return result;
        }

        // The engine's count, as Load reads it from a state folder holding these files (either may be null).
        private static BackupRangeView EngineRange(object lastSuccess, object status)
        {
            string state = NewFolder("state");
            if (lastSuccess != null) WriteJson(Path.Combine(state, "last-success.json"), lastSuccess);
            if (status != null) WriteJson(Path.Combine(state, "status.json"), status);
            return new TelemetryReader(state, false).Load().EngineBackupRange;
        }

        public static int Main(string[] args)
        {
            Thread.CurrentThread.CurrentCulture = new CultureInfo("en-US");
            root = Path.GetFullPath(args[0]);
            EngineProfile.UseFolderRootsForTesting(Path.Combine(root, "roots"));
            EngineProfile.Activate(EngineProfile.Rewindle);
            Dictionary<string, object> result = new Dictionary<string, object>();
            TelemetryReader scratch = new TelemetryReader(NewFolder("state"), false);
            string repository = Path.Combine(root, "backups", "Rewindle");

            // 1-3. The counts come from Restic's summary of a backup, all three or none.
            RunMetricRecord backupRecord = (RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-1", "success", Summary(312, 41, 12040))));
            RunMetricView backupView = new RunMetricView
            {
                FilesNew = backupRecord.FilesNew,
                FilesChanged = backupRecord.FilesChanged,
                FilesUnmodified = backupRecord.FilesUnmodified
            };
            result["backup"] = Counts(backupRecord);
            result["backupDisplay"] = backupView.ChangesDisplay;
            result["zeroDisplay"] = TelemetryFormat.FormatChanges(0, 0, 12040);
            result["unknownDisplay"] = new RunMetricView().ChangesDisplay;
            result["unknownView"] = new RunMetricView().HasChangeCounts;
            result["failedAfterBackup"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-2", "failed", Summary(5, 0, 7)))));
            result["dryRun"] = Counts((RunMetricRecord)Call(scratch, "CreateDryRunMetric",
                AsRead(Status("run-3", "clean", Summary(312, 41, 12040)))));
            Dictionary<string, object> odd = new Dictionary<string, object>();
            odd["missing"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-4", "success", Summary(312, null, 12040)))));
            odd["negative"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-5", "success", Summary(-1, 41, 12040)))));
            odd["string"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-6", "success", Summary("312", 41, 12040)))));
            odd["bool"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-7", "success", Summary(312, true, 12040)))));
            odd["fraction"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-8", "success", Summary(312, 41, 12040.5)))));
            Dictionary<string, object> noSummary = Status("run-9", "cancelled", null);
            noSummary.Remove("summary");
            odd["noSummary"] = Counts((RunMetricRecord)Call(scratch, "CreateBackupMetric", AsRead(noSummary)));
            result["odd"] = odd;

            // 4-5. The history keeps them only when known, reads an older record as not known, and notices the difference.
            RunMetricRecord withoutCounts = (RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-1", "success", Summary(null, null, null))));
            RunMetricRecord olderRun = (RunMetricRecord)Call(scratch, "CreateBackupMetric",
                AsRead(Status("run-10", "success", Summary(null, null, null))));
            IDictionary<string, object> serializedWith = (IDictionary<string, object>)Call(scratch, "SerializeMetric", backupRecord);
            IDictionary<string, object> serializedWithout = (IDictionary<string, object>)Call(scratch, "SerializeMetric", olderRun);
            result["serializedWith"] = serializedWith;
            result["serializedWithoutKeys"] = new List<string>(serializedWithout.Keys);
            result["equalWithAndWithout"] = (bool)Call(null, "MetricEquals", backupRecord, withoutCounts);
            result["equalSame"] = (bool)Call(null, "MetricEquals", backupRecord,
                (RunMetricRecord)Call(scratch, "CreateBackupMetric", AsRead(Status("run-1", "success", Summary(312, 41, 12040)))));
            Dictionary<string, object> dryRecord = new Dictionary<string, object>(serializedWith);
            dryRecord["run_id"] = "dry-1";
            dryRecord["type"] = "dry_run";
            Dictionary<string, object> roundTripRoot = new Dictionary<string, object>();
            roundTripRoot["schema_version"] = 1;
            roundTripRoot["runs"] = new object[] { serializedWith, serializedWithout, dryRecord };
            List<RunMetricRecord> parsed = (List<RunMetricRecord>)Call(scratch, "ParseHistory", AsRead(roundTripRoot));
            Dictionary<string, object> parsedCounts = new Dictionary<string, object>();
            foreach (RunMetricRecord record in parsed)
            {
                parsedCounts[record.TypeKey + ":" + record.RunId + ":" + (record.HasChangeCounts ? "with" : "without")] = Counts(record);
            }
            result["parsed"] = parsedCounts;

            // Through Load, with persistence: the run in status.json reaches the history and its file.
            string historyState = NewFolder("state");
            WriteJson(Path.Combine(historyState, "status.json"), Status("run-history", "success", Summary(2, 1, 2)));
            TelemetryReader historyReader = new TelemetryReader(historyState, true);
            TelemetrySnapshot historySnapshot = historyReader.Load();
            result["loadedDisplay"] = historySnapshot.History.Count == 1 ? historySnapshot.History[0].ChangesDisplay : "(history " + historySnapshot.History.Count + ")";
            string historyFile = Path.Combine(EngineProfile.Current.DashboardDataDirectory(), "run-history.json");
            result["historyFile"] = File.Exists(historyFile) ? Document(File.ReadAllText(historyFile)) : null;

            // 6. The engine's count is read only from a verified last-success.json that names its plan and backup location.
            result["engine"] = Describe(EngineRange(VerifiedRecord(repository), null));
            Dictionary<string, object> refused = new Dictionary<string, object>();
            Dictionary<string, object> record6;
            record6 = VerifiedRecord(repository); record6["state"] = "failed";
            refused["failed"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); record6["verification_complete"] = false;
            refused["unverified"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["count"] = 0;
            refused["countZero"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["count"] = "12";
            refused["countText"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["count"] = 1.5;
            refused["countFraction"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["count"] = 1000001;
            refused["countTooLarge"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["schema_version"] = 2;
            refused["schema2"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["rule"] = "current_generation";
            refused["otherRule"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["oldest_utc"] = "2026-12-01T00:00:00Z";
            refused["oldestAfterNewest"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); ((Dictionary<string, object>)record6["snapshot_inventory"])["counted_utc"] = "not a time";
            refused["countedUnreadable"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); record6.Remove("repository");
            refused["noRepository"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); record6["plan_id"] = PlanId.ToUpperInvariant();
            refused["planNotCanonical"] = Describe(EngineRange(record6, null));
            record6 = VerifiedRecord(repository); record6["snapshot_inventory"] = null;
            refused["noInventory"] = Describe(EngineRange(record6, null));
            // A run that ended after the count (a later check failed) wrote it only into status.json: that is not read.
            refused["statusOnly"] = Describe(EngineRange(null, VerifiedRecord(repository)));
            result["engineRefused"] = refused;

            // 7. Which count is shown for the plan and backup location in use.
            DateTime counted = new DateTime(2026, 11, 6, 1, 2, 41, DateTimeKind.Utc);
            BackupRangeView engine = new BackupRangeView("backup", PlanId, repository, 412,
                new DateTime(2025, 3, 3, 12, 0, 4, DateTimeKind.Utc), new DateTime(2026, 11, 6, 1, 0, 3, DateTimeKind.Utc), counted);
            BackupRangeView listedLater = new BackupRangeView("restore", PlanId, repository, 413,
                new DateTime(2025, 3, 3, 12, 0, 4, DateTimeKind.Utc), new DateTime(2026, 11, 7, 1, 0, 3, DateTimeKind.Utc), counted.AddDays(1));
            BackupRangeView listedEarlier = new BackupRangeView("restore", PlanId, repository, 400,
                new DateTime(2025, 3, 3, 12, 0, 4, DateTimeKind.Utc), new DateTime(2026, 11, 1, 1, 0, 3, DateTimeKind.Utc), counted.AddDays(-5));
            BackupRangeView listedTie = new BackupRangeView("restore", PlanId, repository, 999,
                new DateTime(2025, 3, 3, 12, 0, 4, DateTimeKind.Utc), new DateTime(2026, 11, 6, 1, 0, 3, DateTimeKind.Utc), counted);
            BackupRangeView listedEmptyLater = new BackupRangeView("restore", PlanId, repository, 0,
                DateTime.MinValue, DateTime.MinValue, counted.AddDays(1));
            BackupRangeView listedEmptyEarlier = new BackupRangeView("restore", PlanId, repository, 0,
                DateTime.MinValue, DateTime.MinValue, counted.AddDays(-1));
            Dictionary<string, object> choose = new Dictionary<string, object>();
            choose["engineOnly"] = Describe(TelemetryReader.ChooseBackupRange(engine, null, PlanId, repository));
            choose["otherPlan"] = Describe(TelemetryReader.ChooseBackupRange(engine, null, "9a7c13ef-1cf3-4d89-bfd2-8b70dbb60001", repository));
            choose["caseAndSeparator"] = Describe(TelemetryReader.ChooseBackupRange(engine, null, PlanId, repository.ToUpperInvariant() + "\\"));
            choose["otherLocation"] = Describe(TelemetryReader.ChooseBackupRange(engine, null, PlanId, repository + "-moved"));
            choose["noLocation"] = Describe(TelemetryReader.ChooseBackupRange(engine, null, PlanId, ""));
            choose["listedLater"] = Describe(TelemetryReader.ChooseBackupRange(engine, listedLater, PlanId, repository));
            choose["listedEarlier"] = Describe(TelemetryReader.ChooseBackupRange(engine, listedEarlier, PlanId, repository));
            choose["tie"] = Describe(TelemetryReader.ChooseBackupRange(engine, listedTie, PlanId, repository));
            choose["listedEmptyLater"] = Describe(TelemetryReader.ChooseBackupRange(engine, listedEmptyLater, PlanId, repository));
            choose["listedEmptyEarlier"] = Describe(TelemetryReader.ChooseBackupRange(engine, listedEmptyEarlier, PlanId, repository));
            choose["listedOnly"] = Describe(TelemetryReader.ChooseBackupRange(null, listedEarlier, PlanId, repository));
            choose["neither"] = Describe(TelemetryReader.ChooseBackupRange(null, null, PlanId, repository));
            result["choose"] = choose;

            // 8. The Restore list's count: kept in memory when recorded. Load only reads it (the dashboard also loads on the
            // window's thread); WriteListedBackupRange, which only the background refresh calls, writes it once, and a new reader
            // reads it back.
            string listedState = NewFolder("state");
            string rangeFile = Path.Combine(EngineProfile.Current.DashboardDataDirectory(), "backup-range.json");
            TelemetryReader listedReader = new TelemetryReader(listedState, true);
            listedReader.RecordListedBackupRange(PlanId, repository, 14,
                new DateTime(2026, 10, 1, 2, 0, 0, DateTimeKind.Utc), new DateTime(2026, 11, 5, 2, 0, 0, DateTimeKind.Utc));
            result["fileBeforeLoad"] = File.Exists(rangeFile);
            result["listedInMemory"] = Describe(listedReader.Load().ListedBackupRange);
            result["fileAfterLoad"] = File.Exists(rangeFile);
            listedReader.WriteListedBackupRange();
            result["fileAfterBackgroundWrite"] = File.Exists(rangeFile) ? Document(File.ReadAllText(rangeFile)) : null;
            result["listedReadBack"] = Describe(new TelemetryReader(NewFolder("state"), false).Load().ListedBackupRange);
            File.Delete(rangeFile);
            listedReader.Load();
            listedReader.WriteListedBackupRange();
            result["rewrittenWithNothingNew"] = File.Exists(rangeFile);
            listedReader.RecordListedBackupRange(PlanId, repository, 0, DateTime.MinValue, DateTime.MinValue);
            listedReader.Load();
            listedReader.WriteListedBackupRange();
            result["emptyFile"] = File.Exists(rangeFile) ? Document(File.ReadAllText(rangeFile)) : null;
            BackupRangeView emptyBack = new TelemetryReader(NewFolder("state"), false).Load().ListedBackupRange;
            result["emptyReadBack"] = Describe(emptyBack);
            result["emptyChosen"] = Describe(TelemetryReader.ChooseBackupRange(null, emptyBack, PlanId, repository));
            File.WriteAllText(rangeFile, "{\"schema_version\":1,\"source\":\"restore\",\"count\":\"x\"}", new UTF8Encoding(false));
            result["malformedReadBack"] = Describe(new TelemetryReader(NewFolder("state"), false).Load().ListedBackupRange);
            result["malformedKept"] = File.ReadAllText(rangeFile);
            File.Delete(rangeFile);
            TelemetryReader quietReader = new TelemetryReader(NewFolder("state"), false);
            quietReader.RecordListedBackupRange(PlanId, repository, 3,
                new DateTime(2026, 10, 1, 2, 0, 0, DateTimeKind.Utc), new DateTime(2026, 11, 5, 2, 0, 0, DateTimeKind.Utc));
            result["noPersistenceInMemory"] = Describe(quietReader.Load().ListedBackupRange);
            quietReader.WriteListedBackupRange();
            result["noPersistenceFile"] = File.Exists(rangeFile);
            Dictionary<string, object> recordRefused = new Dictionary<string, object>();
            DateTime early = new DateTime(2026, 10, 1, 2, 0, 0, DateTimeKind.Utc);
            DateTime late = new DateTime(2026, 11, 5, 2, 0, 0, DateTimeKind.Utc);
            TelemetryReader refusing = new TelemetryReader(NewFolder("state"), false);
            refusing.RecordListedBackupRange("", repository, 3, early, late);
            recordRefused["noPlan"] = Describe(refusing.Load().ListedBackupRange);
            refusing.RecordListedBackupRange(PlanId, "backups", 3, early, late);
            recordRefused["relativePath"] = Describe(refusing.Load().ListedBackupRange);
            refusing.RecordListedBackupRange(PlanId, repository, -1, early, late);
            recordRefused["negative"] = Describe(refusing.Load().ListedBackupRange);
            refusing.RecordListedBackupRange(PlanId, repository, 3, late, early);
            recordRefused["oldestAfterNewest"] = Describe(refusing.Load().ListedBackupRange);
            result["recordRefused"] = recordRefused;

            // 9. The earlier personal edition: the same summary gives the counts, its last-success.json has no count of its own,
            // and the Restore list's count goes to that edition's own dashboard folder.
            EngineProfile.Activate(EngineProfile.Legacy);
            string legacyState = NewFolder("legacy-state");
            WriteJson(Path.Combine(legacyState, "status.json"), Status("legacy-run", "success", Summary(2, 1, 2)));
            Dictionary<string, object> legacySuccess = VerifiedRecord(repository);
            legacySuccess.Remove("snapshot_inventory");
            legacySuccess["prior_matching_snapshot_count"] = 7;
            WriteJson(Path.Combine(legacyState, "last-success.json"), legacySuccess);
            TelemetryReader legacyReader = new TelemetryReader(legacyState, true);
            TelemetrySnapshot legacySnapshot = legacyReader.Load();
            Dictionary<string, object> legacy = new Dictionary<string, object>();
            legacy["display"] = legacySnapshot.History.Count == 1 ? legacySnapshot.History[0].ChangesDisplay : "(history " + legacySnapshot.History.Count + ")";
            legacy["engineRange"] = Describe(legacySnapshot.EngineBackupRange);
            legacyReader.RecordListedBackupRange(PlanId, repository, 5,
                new DateTime(2024, 1, 1, 12, 0, 0, DateTimeKind.Utc), new DateTime(2026, 11, 5, 2, 0, 0, DateTimeKind.Utc));
            TelemetrySnapshot legacyAfter = legacyReader.Load();
            legacyReader.WriteListedBackupRange();
            legacy["chosen"] = Describe(TelemetryReader.ChooseBackupRange(legacyAfter.EngineBackupRange, legacyAfter.ListedBackupRange, PlanId, repository));
            string legacyFolder = EngineProfile.Legacy.DashboardDataDirectory();
            legacy["folder"] = Path.GetFileName(legacyFolder);
            legacy["fileWritten"] = File.Exists(Path.Combine(legacyFolder, "backup-range.json"));
            legacy["rewindleFileWritten"] = File.Exists(rangeFile);
            result["legacy"] = legacy;
            EngineProfile.Activate(EngineProfile.Rewindle);

            Console.WriteLine(Json.Serialize(result));
            return 0;
        }
    }
}
