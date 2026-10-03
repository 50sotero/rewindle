using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal static class DiagnosticExporterHarness
    {
        private const string FixturePassword = "Winter!Fixture-Password-489";
        private const string FixtureHost = "fixture-host-7762";
        private const string FixtureUser = "fixture-user-8831";
        private const string FixtureEmail = "private.fixture@example.invalid";

        private static void Set(SourceConfiguration value, string property, object setting)
        {
            PropertyInfo info = typeof(SourceConfiguration).GetProperty(
                property,
                BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            info.GetSetMethod(true).Invoke(value, new[] { setting });
        }

        private static void WriteJson(string path, object value)
        {
            File.WriteAllText(
                path,
                new JavaScriptSerializer().Serialize(value),
                new UTF8Encoding(false));
        }

        public static int Main(string[] args)
        {
            // Every engine path the dashboard builds points into a disposable folder; nothing real is looked at.
            EngineProfile.UseFolderRootsForTesting(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rewindle-harness-" + System.Guid.NewGuid().ToString("N")));
            if (args.Length < 2) return 10;
            string root = Path.GetFullPath(args[0]);
            bool unsafeDestination = string.Equals(
                args[1],
                "unsafe",
                StringComparison.OrdinalIgnoreCase);
            string install = Path.Combine(root, "runtime");
            string state = Path.Combine(root, "state");
            string repository = Path.Combine(root, "repository");
            string source = Path.Combine(root, "protected-source");
            string output = Path.Combine(root, "output");
            foreach (string path in new[] { install, state, repository, source, output })
                Directory.CreateDirectory(path);
            Directory.CreateDirectory(Path.Combine(state, "logs"));

            string configPath = Path.Combine(install, "backup-config.json");
            string runId = "20260721T120000-deadbeef";
            string snapshotId = new string('a', 64);
            string longBlob = new string('Q', 140) + "==";
            Dictionary<string, object> rawConfig = new Dictionary<string, object>();
            rawConfig["schema_version"] = 1;
            rawConfig["plan_id"] = "9a7c13ef-1cf3-4d89-bfd2-8b70dbb60001";
            rawConfig["config_generation"] = 3;
            rawConfig["repository"] = repository;
            rawConfig["state_directory"] = state;
            rawConfig["sources"] = new[] { source };
            rawConfig["hostname"] = FixtureHost;
            rawConfig["owner_sid"] = "S-1-5-21-111-222-333-1001";
            rawConfig["password"] = FixturePassword;
            rawConfig["recovery_key_file"] = Path.Combine(root, "recovery-secret.txt");
            rawConfig["support_contact"] = FixtureEmail;
            WriteJson(configPath, rawConfig);

            Dictionary<string, object> status = new Dictionary<string, object>();
            status["schema_version"] = 1;
            status["state"] = "failed";
            status["run_id"] = runId;
            status["snapshot_id"] = snapshotId;
            status["plan_id"] = rawConfig["plan_id"];
            status["repository_id"] = new string('b', 64);
            status["hostname"] = FixtureHost;
            status["username"] = FixtureUser;
            status["failure"] = "Access failed for " + source + " by " +
                FixtureUser + " / " + FixtureEmail + " / " + FixturePassword;
            status["command"] = "restic backup " + source +
                " --password-file " + Path.Combine(root, "secret.txt");
            status["dpapi_blob"] = longBlob;
            status["opaque_token"] = longBlob;
            WriteJson(Path.Combine(state, "status.json"), status);

            Dictionary<string, object> cloudEvidence =
                new Dictionary<string, object>();
            cloudEvidence["schema_version"] = 2;
            cloudEvidence["proof_kind"] =
                "direct_my_drive_cloud_repository_verification";
            cloudEvidence["plan_id"] = rawConfig["plan_id"];
            cloudEvidence["repository_id"] = new string('c', 64);
            cloudEvidence["local_repository_id"] = new string('c', 64);
            cloudEvidence["cloud_repository_id"] = new string('c', 64);
            cloudEvidence["snapshot_id"] = new string('d', 64);
            cloudEvidence["inventory_fingerprint_sha256"] = new string('e', 64);
            cloudEvidence["cloud_inventory_document_sha256"] = new string('f', 64);
            cloudEvidence["backup_config_sha256"] = new string('1', 64);
            cloudEvidence["canary_sha256"] = new string('2', 64);
            cloudEvidence["immutable_proof_sha256"] = new string('3', 64);
            cloudEvidence["cloud_verification_assets_manifest_sha256"] =
                new string('4', 64);
            cloudEvidence["cloud_repository_path"] =
                "Cloud-Repository-Fixture-9032";
            cloudEvidence["canary_snapshot_path"] =
                "/C/Cloud-Canary-Fixture-9032.txt";
            cloudEvidence["remote_name"] = "Cloud-Remote-Fixture-9032";
            cloudEvidence["immutable_proof"] = Path.Combine(
                root,
                "private-cloud-proof.json");
            WriteJson(
                Path.Combine(state, "google-drive-sync-status.json"),
                cloudEvidence);

            string logPath = Path.Combine(
                state,
                "logs",
                "backup-" + runId + ".jsonl.log");
            WriteJson(
                logPath,
                new Dictionary<string, object>
                {
                    { "wrapper_event", "failure" },
                    { "error", "Unable to read " + source + " for " + FixtureUser },
                    { "command", "restic --password-file " + FixturePassword },
                    { "traceback", "trace " + FixtureEmail }
                });

            SourceConfiguration configuration = (SourceConfiguration)Activator.CreateInstance(
                typeof(SourceConfiguration),
                true);
            Set(configuration, "InstallRoot", install);
            Set(configuration, "ConfigurationPath", configPath);
            Set(configuration, "ManagerPath", Path.Combine(install, "Manage-Sources.ps1"));
            Set(configuration, "RepositoryPath", repository);
            Set(configuration, "StateDirectory", state);
            Set(configuration, "PlanId", (string)rawConfig["plan_id"]);
            Set(configuration, "ConfigGeneration", 3L);
            Set(configuration, "CloudPlaceholderPolicy", "strict");
            Set(configuration, "Sources", new List<BackupSourceView>
            {
                new BackupSourceView(source, false)
            });

            TelemetrySnapshot snapshot = new TelemetrySnapshot();
            snapshot.StateKey = "failed";
            snapshot.StatusLabel = "Backup failed";
            snapshot.StatusDetail = "Unable to read " + source + " for " + FixtureUser;
            snapshot.RunId = runId;
            snapshot.SnapshotId = snapshotId;
            snapshot.IsFailure = true;

            string destination = unsafeDestination
                ? Path.Combine(source, "diagnostics.zip")
                : Path.Combine(output, "diagnostics.zip");
            DiagnosticExportResult result = DiagnosticExporter.Export(
                configuration,
                null,
                snapshot,
                destination);
            Dictionary<string, object> outputValue = new Dictionary<string, object>();
            outputValue["succeeded"] = result.Succeeded;
            outputValue["path"] = result.ExportPath;
            outputValue["error"] = result.ErrorMessage;
            outputValue["destination"] = destination;
            Console.WriteLine(new JavaScriptSerializer().Serialize(outputValue));
            return 0;
        }
    }
}
