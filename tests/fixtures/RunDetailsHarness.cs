using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal static class RunDetailsHarness
    {
        private static void Set(SourceConfiguration value, string property, object setting)
        {
            PropertyInfo info = typeof(SourceConfiguration).GetProperty(
                property,
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            info.GetSetMethod(true).Invoke(value, new[] { setting });
        }

        public static int Main(string[] args)
        {
            // Every engine path the dashboard builds points into a disposable folder; nothing real is looked at.
            EngineProfile.UseFolderRootsForTesting(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rewindle-harness-" + System.Guid.NewGuid().ToString("N")));
            string root = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(root);
            string state = Path.Combine(root, "state");
            string logs = Path.Combine(state, "logs");
            string source = Path.Combine(root, "source");
            Directory.CreateDirectory(state);
            Directory.CreateDirectory(logs);
            Directory.CreateDirectory(source);
            string runId = "20260721T130000-cafef00d";
            string snapshotId = new string('a', 64);
            Dictionary<string, object> status = new Dictionary<string, object>();
            status["schema_version"] = 1;
            status["run_id"] = runId;
            status["state"] = "partial";
            status["failure_phase"] = "backup";
            status["failure_code"] = "source_data_unreadable";
            status["exit_code"] = 3;
            status["snapshot_id"] = snapshotId;
            status["failure"] = "Some source data was unreadable.";
            status["affected_paths"] = new[] { Path.Combine(source, "locked.txt") };
            File.WriteAllText(
                Path.Combine(state, "status.json"),
                new JavaScriptSerializer().Serialize(status),
                new UTF8Encoding(false));
            File.WriteAllText(
                Path.Combine(logs, "backup-" + runId + ".jsonl.log"),
                new JavaScriptSerializer().Serialize(
                    new Dictionary<string, object>
                    {
                        { "wrapper_event", "failure" },
                        { "utc", "2026-07-21T13:05:00Z" },
                        { "failure_phase", "backup" },
                        { "failure_code", "source_data_unreadable" },
                        { "affected_paths", new[] { Path.Combine(source, "locked.txt") } },
                        { "error", "Some source data was unreadable." },
                        { "traceback", "must not be displayed" },
                        { "command", "must not be displayed" }
                    }) + Environment.NewLine,
                new UTF8Encoding(false));

            SourceConfiguration configuration = (SourceConfiguration)Activator.CreateInstance(
                typeof(SourceConfiguration),
                true);
            Set(configuration, "InstallRoot", Path.Combine(root, "runtime"));
            Set(configuration, "ConfigurationPath", Path.Combine(root, "runtime", "backup-config.json"));
            Set(configuration, "ManagerPath", Path.Combine(root, "runtime", "Manage-Sources.ps1"));
            Set(configuration, "RepositoryPath", Path.Combine(root, "repository"));
            Set(configuration, "StateDirectory", state);
            Set(configuration, "PlanId", "9a7c13ef-1cf3-4d89-bfd2-8b70dbb60001");
            Set(configuration, "ConfigGeneration", 1L);
            Set(configuration, "CloudPlaceholderPolicy", "strict");
            Set(configuration, "Sources", new List<BackupSourceView>
            {
                new BackupSourceView(source, false)
            });
            RunMetricView run = new RunMetricView
            {
                RunId = runId,
                TypeLabel = "Backup",
                StateLabel = "Incomplete",
                StartedLocal = new DateTime(2026, 7, 21, 13, 0, 0),
                DurationSeconds = 300,
                SnapshotShort = snapshotId.Substring(0, 12)
            };
            RunDetails details = RunDetailsReader.Load(configuration, run);
            bool traversalRejected = false;
            try
            {
                RunDetailsReader.Load(
                    configuration,
                    new RunMetricView
                    {
                        RunId = "..\\outside",
                        TypeLabel = "Backup",
                        StateLabel = "Failed",
                        StartedLocal = DateTime.Now
                    });
            }
            catch (InvalidDataException)
            {
                traversalRejected = true;
            }
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["phase"] = details.Phase;
            result["failure_code"] = details.FailureCode;
            result["exit_code"] = details.ExitCode;
            result["snapshot_id"] = details.SnapshotId;
            result["affected_paths"] = details.AffectedPaths;
            result["events"] = details.Events;
            result["has_log"] = details.HasLog;
            result["remediation"] = details.Remediation;
            result["traversal_rejected"] = traversalRejected;
            Console.WriteLine(new JavaScriptSerializer().Serialize(result));
            return 0;
        }
    }
}
