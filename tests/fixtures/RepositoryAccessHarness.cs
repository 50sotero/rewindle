using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace ResticBackuper.Dashboard
{
    // The two things RestoreManager.cs takes from the dashboard window (two fixed messages); the window itself is not compiled here.
    internal static class DashboardWindow
    {
        internal const string RestoreFlowSearchUnavailableMessage = "stub";
        internal const string RestoreFlowSystemFolderMessage = "stub";
    }

    // How the dashboard reads and words "repository_access" (a backup with or without a password): the configuration reader, the
    // failure texts, the readiness report and window, the recovery launchers and the restore drill's evidence. Everything runs on files
    // in a disposable folder; no window is ever shown and no process is started.
    internal static class RepositoryAccessHarness
    {
        private const BindingFlags Flags =
            BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
        private const string RunId = "20260721T130000-cafef00d";
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        private static string root;
        private static int counter;

        private static string NewFolder(string name)
        {
            counter++;
            string path = Path.Combine(root, name + "-" + counter.ToString());
            Directory.CreateDirectory(path);
            return path;
        }

        private static void Write(string path, object value)
        {
            File.WriteAllText(path, Json.Serialize(value), new UTF8Encoding(false));
        }

        private static void Set(object target, string property, object setting)
        {
            PropertyInfo info = target.GetType().GetProperty(property, Flags);
            info.GetSetMethod(true).Invoke(target, new[] { setting });
        }

        private static T Get<T>(object target, string field)
        {
            return (T)target.GetType().GetField(field, Flags).GetValue(target);
        }

        private static SourceConfiguration Configuration(string access, string installRoot)
        {
            string state = NewFolder("state");
            string source = NewFolder("source");
            SourceConfiguration value = (SourceConfiguration)Activator.CreateInstance(typeof(SourceConfiguration), true);
            Set(value, "InstallRoot", installRoot);
            Set(value, "ConfigurationPath", Path.Combine(installRoot, "backup-config.json"));
            Set(value, "ManagerPath", Path.Combine(installRoot, "Manage-Sources.ps1"));
            Set(value, "RepositoryPath", NewFolder("repository"));
            Set(value, "StateDirectory", state);
            Set(value, "PlanId", "9a7c13ef-1cf3-4d89-bfd2-8b70dbb60001");
            Set(value, "ConfigGeneration", 1L);
            Set(value, "CloudPlaceholderPolicy", "strict");
            Set(value, "Sources", new List<BackupSourceView> { new BackupSourceView(source, false) });
            Set(value, "RepositoryAccess", access);
            return value;
        }

        // ---- SourceConfiguration.ReadRepositoryAccess and Load ---------------------------------------------------------------------

        private static Dictionary<string, object> ReadAccess()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            Dictionary<string, object> empty = new Dictionary<string, object>();
            result["absent"] = SourceConfiguration.ReadRepositoryAccess(empty);
            result["document_missing"] = SourceConfiguration.ReadRepositoryAccess(null);
            string[] words = { "password", "no_password", "Password", "NO_PASSWORD", "none", "", " no_password", "no-password", "encrypted" };
            foreach (string word in words)
            {
                Dictionary<string, object> document = new Dictionary<string, object>();
                document["repository_access"] = word;
                result["text:" + word] = SourceConfiguration.ReadRepositoryAccess(document);
            }
            Dictionary<string, object> nothing = new Dictionary<string, object>();
            nothing["repository_access"] = null;
            result["json_null"] = SourceConfiguration.ReadRepositoryAccess(nothing);
            Dictionary<string, object> number = new Dictionary<string, object>();
            number["repository_access"] = 1;
            result["number"] = SourceConfiguration.ReadRepositoryAccess(number);
            Dictionary<string, object> flag = new Dictionary<string, object>();
            flag["repository_access"] = true;
            result["boolean"] = SourceConfiguration.ReadRepositoryAccess(flag);
            return result;
        }

        // The real Load, on a configuration written where the dashboard looks for it (under the disposable folder).
        private static Dictionary<string, object> LoadCases()
        {
            string configuration = EngineProfile.Current.ConfigurationPath();
            Directory.CreateDirectory(Path.GetDirectoryName(configuration));
            string source = Path.GetFullPath(NewFolder("loaded-source"));
            Dictionary<string, object> result = new Dictionary<string, object>();
            string[] cases = { "absent", "password", "no_password", "unsupported", "number" };
            foreach (string name in cases)
            {
                Dictionary<string, object> document = new Dictionary<string, object>();
                document["schema_version"] = 1;
                document["plan_id"] = "9a7c13ef-1cf3-4d89-bfd2-8b70dbb60001";
                document["config_generation"] = 4;
                document["cloud_placeholder_policy"] = "strict";
                document["repository"] = Path.GetFullPath(NewFolder("loaded-repository"));
                document["state_directory"] = Path.GetFullPath(NewFolder("loaded-state"));
                document["sources"] = new[] { source };
                Dictionary<string, object> identity = new Dictionary<string, object>();
                identity["expected_volume_serial"] = "0A1B2C3D";
                Dictionary<string, object> identities = new Dictionary<string, object>();
                identities[source] = identity;
                document["source_identities"] = identities;
                // What the installer writes next to it for every new install, and what an older configuration does not have.
                document["repository_storage_mode"] = "local_ntfs";
                if (name == "password" || name == "no_password") document["repository_access"] = name;
                if (name == "unsupported") document["repository_access"] = "encrypted";
                if (name == "number") document["repository_access"] = 7;
                Write(configuration, document);
                SourceConfiguration loaded = SourceConfiguration.Load();
                result[name] = loaded.RepositoryAccess;
            }
            return result;
        }

        // ---- failure words: the run details' next step and the status line --------------------------------------------------------

        private static string RunDetailsRemediation(string code, string access)
        {
            SourceConfiguration configuration = Configuration(access, Path.Combine(root, "runtime"));
            Dictionary<string, object> status = new Dictionary<string, object>();
            status["schema_version"] = 1;
            status["run_id"] = RunId;
            status["state"] = "failed";
            status["failure_phase"] = "authentication";
            status["failure_code"] = code;
            Write(Path.Combine(configuration.StateDirectory, "status.json"), status);
            RunMetricView run = new RunMetricView
            {
                RunId = RunId,
                TypeLabel = "Backup",
                StateLabel = "Failed",
                StartedLocal = new DateTime(2026, 7, 21, 13, 0, 0),
                DurationSeconds = 5
            };
            return RunDetailsReader.Load(configuration, run).Remediation;
        }

        private static string StatusLine(string code, string recordedAccess, bool recordAccess)
        {
            string state = NewFolder("telemetry-state");
            Dictionary<string, object> status = new Dictionary<string, object>();
            status["schema_version"] = 1;
            status["run_id"] = RunId;
            status["state"] = "failed";
            status["started_utc"] = "2026-11-05T01:00:00Z";
            status["finished_utc"] = "2026-11-05T01:00:05Z";
            status["failure_phase"] = "authentication";
            status["failure_code"] = code;
            if (recordAccess) status["repository_access"] = recordedAccess;
            Write(Path.Combine(state, "status.json"), status);
            TelemetrySnapshot snapshot = new TelemetryReader(state, false).Load();
            return snapshot.IsFailure ? snapshot.StatusDetail : "(not a failure: " + snapshot.StateKey + ")";
        }

        private static Dictionary<string, object> FailureWords()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            string[] codes = { "repository_authentication_failed", "repository_access_mismatch", "source_data_unreadable" };
            string[] accesses = { "password", "no_password", null };
            foreach (string code in codes)
            {
                foreach (string access in accesses)
                {
                    string label = code + "|" + (access ?? "unknown");
                    result["details:" + label] = RunDetailsRemediation(code, access);
                    // The status line takes the mode from the run's own record: a record without it is a backup with a password.
                    result["status:" + label] = StatusLine(code, access, true);
                }
                result["status:" + code + "|absent"] = StatusLine(code, null, false);
            }
            return result;
        }

        // ---- the readiness report and its launchers -------------------------------------------------------------------------------

        private static Dictionary<string, object> ReportDocument(IDictionary<string, object> configuration, string access, bool include)
        {
            Dictionary<string, object> document = new Dictionary<string, object>();
            document["schema_version"] = 1;
            document["schema"] = EngineProfile.Current.RecoveryHealthSchema;
            document["plan_id"] = "9a7c13ef-1cf3-4d89-bfd2-8b70dbb60001";
            document["config_generation"] = 1;
            document["repository"] = configuration["repository"];
            document["overall_status"] = "healthy";
            document["failed_check_count"] = 0;
            document["warning_check_count"] = 0;
            document["reserve_bytes"] = 1000;
            List<object> checks = new List<object>();
            Dictionary<string, object> check = new Dictionary<string, object>();
            check["id"] = "active_credential";
            check["status"] = "pass";
            check["summary"] = "Rewindle can open your backups.";
            checks.Add(check);
            document["checks"] = checks;
            if (include) document["repository_access"] = access;
            return document;
        }

        private static Dictionary<string, object> ParseCases()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            MethodInfo parse = typeof(RecoveryHealthLauncher).GetMethod("ParseBoundReport", Flags);
            string[] configurations = { "password", "no_password", null };
            // A report's access: absent, or one of the words (a number and another text are not accepted).
            object[] reports = { "(absent)", "password", "no_password", "encrypted", 1 };
            foreach (string access in configurations)
            {
                SourceConfiguration configuration = Configuration(access, Path.Combine(root, "runtime"));
                Dictionary<string, object> bound = new Dictionary<string, object>();
                bound["repository"] = configuration.RepositoryPath;
                foreach (object reported in reports)
                {
                    Dictionary<string, object> document = ReportDocument(bound, reported as string, !"(absent)".Equals(reported));
                    if (reported is int) document["repository_access"] = reported;
                    // As the launcher reads it: through the serializer, so numbers have the types the parser meets.
                    IDictionary<string, object> read = (IDictionary<string, object>)Json.DeserializeObject(Json.Serialize(document));
                    RecoveryHealthReport report = (RecoveryHealthReport)parse.Invoke(null, new object[] { read, configuration });
                    Dictionary<string, object> outcome = new Dictionary<string, object>();
                    outcome["loaded"] = report.Loaded;
                    outcome["access"] = report.RepositoryAccess;
                    outcome["error"] = report.ErrorMessage;
                    result[(access ?? "unknown") + "|" + Convert.ToString(reported)] = outcome;
                }
            }
            return result;
        }

        private static Dictionary<string, object> Launchers()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            string missing = Path.Combine(root, "no-runtime-here");
            string[] accesses = { "password", "no_password" };
            foreach (string access in accesses)
            {
                SourceConfiguration configuration = Configuration(access, missing);
                int started = 0;
                Action onStarted = delegate { started++; };
                CredentialRepairResult repair = CredentialRepairLauncher.Repair(configuration, onStarted);
                KeyRotationResult rotation = KeyRotationLauncher.Rotate(configuration, onStarted);
                result["repair:" + access] = repair.ErrorMessage;
                result["rotate:" + access] = rotation.ErrorMessage;
                result["started:" + access] = started;
            }
            return result;
        }

        // ---- the readiness window ---------------------------------------------------------------------------------------------------

        private static RecoveryHealthCheck Check(string id, string status)
        {
            return new RecoveryHealthCheck(id, status, id, status == "pass" ? "ok" : string.Empty);
        }

        private static RecoveryHealthReport Report(string access, long? locks, params string[] checks)
        {
            List<RecoveryHealthCheck> list = new List<RecoveryHealthCheck>();
            foreach (string item in checks)
            {
                string[] parts = item.Split(':');
                list.Add(Check(parts[0], parts[1]));
            }
            RecoveryHealthReport report = RecoveryHealthReport.Success(
                "healthy", "abcdef0123456789", 2L, 500000000000L, 1000000000L, locks, 0, 0, list);
            report.RepositoryAccess = access;
            return report;
        }

        private static Dictionary<string, object> Describe(RecoveryReadinessWindow window)
        {
            Dictionary<string, object> state = new Dictionary<string, object>();
            string[] names = { "drillButton", "repairButton", "lockRepairButton", "keyRotationButton" };
            foreach (string name in names)
            {
                Button button = Get<Button>(window, name);
                Dictionary<string, object> item = new Dictionary<string, object>();
                item["visible"] = button.Visibility == Visibility.Visible;
                item["enabled"] = button.IsEnabled;
                item["help"] = AutomationProperties.GetHelpText(button);
                item["label"] = Convert.ToString(button.Content);
                state[name] = item;
            }
            state["detail"] = Get<TextBlock>(window, "detail").Text;
            state["hint"] = Get<TextBlock>(window, "actionHint").Text;
            DataGrid grid = Get<DataGrid>(window, "checksGrid");
            List<object> rows = new List<object>();
            if (grid.ItemsSource != null)
            {
                foreach (object row in grid.ItemsSource) rows.Add(((RecoveryHealthCheck)row).Id);
            }
            state["rows"] = rows;
            return state;
        }

        private static Dictionary<string, object> Readiness()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            DashboardThemePalette palette = DashboardThemeManager.Resolve(DashboardThemePreference.Midnight).Palette;
            MethodInfo apply = typeof(RecoveryReadinessWindow).GetMethod("ApplyReport", Flags);
            string runtime = Path.Combine(root, "runtime");
            string[] full = { "active_credential:pass", "recovery_key:pass", "recovery_bundle:pass", "last_verification:pass", "pending_transaction:pass", "restore_drill:warn" };
            string[] noKey = { "active_credential:pass", "recovery_bundle:pass", "last_verification:pass", "pending_transaction:pass", "restore_drill:warn" };

            // Before any report: the description follows the configuration.
            foreach (string access in new[] { "password", "no_password", null })
            {
                RecoveryReadinessWindow fresh = new RecoveryReadinessWindow(Configuration(access, runtime), palette);
                result["fresh:" + (access ?? "unknown")] = Describe(fresh);
            }

            // A backup with a password, as ever: the recovery key gates the drill and the key actions are there.
            RecoveryReadinessWindow password = new RecoveryReadinessWindow(Configuration("password", runtime), palette);
            apply.Invoke(password, new object[] { Report("password", 0L, full) });
            result["password_all_pass"] = Describe(password);
            apply.Invoke(password, new object[] { Report("password", 0L, "active_credential:pass", "recovery_key:fail", "recovery_bundle:pass", "last_verification:pass", "pending_transaction:pass", "restore_drill:warn") });
            result["password_key_fails"] = Describe(password);
            apply.Invoke(password, new object[] { Report("password", 0L, noKey) });
            result["password_report_without_a_key_check"] = Describe(password);
            apply.Invoke(password, new object[] { Report("password", 0L, "active_credential:fail", "recovery_key:pass", "recovery_bundle:pass", "last_verification:pass", "pending_transaction:pass") });
            result["password_repair_offered"] = Describe(password);

            // A backup without one: no key row, no key actions, the drill gated on Rewindle opening the backups.
            RecoveryReadinessWindow open = new RecoveryReadinessWindow(Configuration("no_password", runtime), palette);
            apply.Invoke(open, new object[] { Report("no_password", 0L, noKey) });
            result["no_password_all_pass"] = Describe(open);
            apply.Invoke(open, new object[] { Report("no_password", 0L, "active_credential:fail", "recovery_bundle:pass", "last_verification:pass", "pending_transaction:pass", "restore_drill:warn") });
            result["no_password_cannot_open"] = Describe(open);
            apply.Invoke(open, new object[] { Report("no_password", 2L, noKey) });
            result["no_password_locks"] = Describe(open);
            apply.Invoke(open, new object[] { Report("no_password", 0L, "active_credential:pass", "recovery_bundle:fail", "last_verification:pass", "pending_transaction:pass", "restore_drill:warn") });
            result["no_password_bundle_fails"] = Describe(open);
            // Even a report that lists a key check does not turn the key actions on for a backup without a password.
            apply.Invoke(open, new object[] { Report("no_password", 0L, full) });
            result["no_password_key_check_listed"] = Describe(open);
            // The case a repair is made for with a password (the key works, the saved password does not): there is nothing to repair here.
            apply.Invoke(open, new object[] { Report("no_password", 0L, "active_credential:fail", "recovery_key:pass", "recovery_bundle:pass", "last_verification:pass", "pending_transaction:pass") });
            result["no_password_key_check_listed_and_cannot_open"] = Describe(open);
            // The report decides, not the window's configuration: a password report on a window that began as another kind shows the key actions.
            RecoveryReadinessWindow other = new RecoveryReadinessWindow(Configuration(null, runtime), palette);
            apply.Invoke(other, new object[] { Report("no_password", 0L, noKey) });
            result["report_decides"] = Describe(other);
            return result;
        }

        // What the readiness check says when backups no longer open the way they were made. The test writes the sentences it takes from the
        // engine (recovery_health.py) to readiness-details.json, keyed by the configuration's mode, and this takes each one through the steps
        // a real report goes through: read from the engine's JSON by the launcher, then listed in the window. Neither may hide or change it.
        private static Dictionary<string, object> ReadinessDetails()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            string path = Path.Combine(root, "readiness-details.json");
            if (!File.Exists(path)) return result;
            IDictionary<string, object> given = (IDictionary<string, object>)Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
            MethodInfo parse = typeof(RecoveryHealthLauncher).GetMethod("ParseBoundReport", Flags);
            MethodInfo apply = typeof(RecoveryReadinessWindow).GetMethod("ApplyReport", Flags);
            DashboardThemePalette palette = DashboardThemeManager.Resolve(DashboardThemePreference.Midnight).Palette;
            foreach (KeyValuePair<string, object> item in given)
            {
                SourceConfiguration configuration = Configuration(item.Key, Path.Combine(root, "runtime"));
                Dictionary<string, object> bound = new Dictionary<string, object>();
                bound["repository"] = configuration.RepositoryPath;
                Dictionary<string, object> document = ReportDocument(bound, item.Key, true);
                document["overall_status"] = "blocked";
                document["failed_check_count"] = 1;
                List<object> checks = new List<object>();
                Dictionary<string, object> check = new Dictionary<string, object>();
                check["id"] = "active_credential";
                check["status"] = "fail";
                check["summary"] = "Rewindle couldn't open your backups.";
                check["detail"] = (string)item.Value;
                checks.Add(check);
                document["checks"] = checks;
                IDictionary<string, object> read = (IDictionary<string, object>)Json.DeserializeObject(Json.Serialize(document));
                RecoveryHealthReport report = (RecoveryHealthReport)parse.Invoke(null, new object[] { read, configuration });
                Dictionary<string, object> outcome = new Dictionary<string, object>();
                outcome["loaded"] = report.Loaded;
                outcome["parsed"] = report.Loaded ? report.Checks[0].Detail : report.ErrorMessage;
                RecoveryReadinessWindow window = new RecoveryReadinessWindow(configuration, palette);
                apply.Invoke(window, new object[] { report });
                DataGrid grid = Get<DataGrid>(window, "checksGrid");
                string listed = null;
                if (grid.ItemsSource != null)
                {
                    foreach (object row in grid.ItemsSource) listed = ((RecoveryHealthCheck)row).Detail;
                }
                outcome["listed"] = listed;
                result[item.Key] = outcome;
            }
            return result;
        }

        // ---- what restore.py says when backups now ask for a password, on its way to the screen ----------------------------------------
        // The test writes restore-words.json: "asks" is the engine's sentence for backups without a password that Restic now refuses (exit
        // code 12) and "asks_and_left" the same sentence followed by where items stayed in the restore folder. Every answer the dashboard
        // reads from the restore step passes SanitizeAnswer (a listing, a folder, a search, a restore, the drill, or no request at all), and
        // a file search's failure then passes DescribeRestoreFlowSearchFailure (copied out of the window's source by the test, which cannot
        // compile the window itself). Neither may drop, shorten or reword the sentence.

        private static Dictionary<string, object> RestoreWords()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            string path = Path.Combine(root, "restore-words.json");
            if (!File.Exists(path)) return result;
            IDictionary<string, object> given = (IDictionary<string, object>)Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
            string[] actions = { null, "list_snapshots", "list_tree", "find_files", "restore", "restore_drill" };
            foreach (string key in new[] { "asks", "asks_and_left", "asks_and_left_in_use" })
            {
                string sentence = (string)given[key];
                foreach (string action in actions)
                {
                    result["sanitize:" + key + "|" + (action ?? "none")] = RestoreManagerLauncher.SanitizeAnswer(sentence, action);
                }
                result["sanitize:" + key + "|plain"] = RestoreManagerLauncher.Sanitize(sentence);
            }
            // A controlled difference: a message that is one of the dashboard's own refusals is still worded for the person, so the
            // sanitizer is really in the way here and not a pass-through.
            result["sanitize:control"] = RestoreManagerLauncher.SanitizeAnswer("restore target must not overlap anything", "restore");
            Type copy = Type.GetType("ResticBackuper.Dashboard.RestoreSearchFailureCopy");
            if (copy != null)
            {
                MethodInfo describe = copy.GetMethod("DescribeRestoreFlowSearchFailure", Flags);
                string[] inputs = {
                    (string)given["asks"], (string)given["asks_and_left"], "The backup service already holds the run lock.",
                    "That file is no longer in the list.", "The search took too long.", "", "The file search failed."
                };
                foreach (string input in inputs)
                {
                    object[] arguments = new object[] { input, false };
                    Dictionary<string, object> outcome = new Dictionary<string, object>();
                    outcome["text"] = (string)describe.Invoke(null, arguments);
                    outcome["list_changed"] = (bool)arguments[1];
                    result["search:" + input] = outcome;
                }
            }
            return result;
        }

        // ---- the restore drill's evidence ------------------------------------------------------------------------------------------

        private static string DrillVerdict(string access, string credentialSource)
        {
            Dictionary<string, object> payload = new Dictionary<string, object>();
            payload["drill_kind"] = "recovery_key_representative";
            payload["credential_source"] = credentialSource;
            payload["snapshot_generation"] = 3;
            payload["canary_verified"] = true;
            payload["canary_bytes"] = 12;
            payload["canary_sha256"] = new string('a', 64);
            payload["sample_policy"] = "one-or-two-bounded-files-per-source-v1";
            payload["sample_file_count"] = 3;
            payload["sample_bytes"] = 1024;
            payload["sample_paths_sha256"] = new string('b', 64);
            IDictionary<string, object> read = (IDictionary<string, object>)Json.DeserializeObject(Json.Serialize(payload));
            ProtectedRestoreReport report = new ProtectedRestoreReport(
                "verified", new string('c', 64), Path.Combine(root, "target"), true, false, 0, null, "binding");
            MethodInfo validate = typeof(RestoreManagerLauncher).GetMethod("ValidateRecoveryDrillReport", Flags);
            try
            {
                validate.Invoke(null, new object[] { read, report, 3L, access });
                return "accepted";
            }
            catch (TargetInvocationException error)
            {
                return error.InnerException.GetType().Name;
            }
        }

        private static Dictionary<string, object> DrillCases()
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            string[] accesses = { "password", "no_password", null };
            string[] sources = { "recovery_key", "none", "dpapi" };
            foreach (string access in accesses)
            {
                foreach (string source in sources)
                {
                    result[(access ?? "unknown") + "|" + source] = DrillVerdict(access, source);
                }
                result["expected:" + (access ?? "unknown")] = RestoreManagerLauncher.ExpectedDrillCredentialSource(access);
            }
            return result;
        }

        private static int Run(string folder)
        {
            // Every engine path the dashboard builds points into a disposable folder; nothing real is looked at.
            EngineProfile.UseFolderRootsForTesting(Path.Combine(Path.GetTempPath(), "rewindle-harness-" + Guid.NewGuid().ToString("N")));
            root = Path.GetFullPath(folder);
            Directory.CreateDirectory(root);
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["read"] = ReadAccess();
            result["load"] = LoadCases();
            result["failure_words"] = FailureWords();
            result["parse"] = ParseCases();
            result["launchers"] = Launchers();
            result["readiness"] = Readiness();
            result["readiness_details"] = ReadinessDetails();
            result["restore_words"] = RestoreWords();
            result["drill"] = DrillCases();
            Console.WriteLine(AsciiJson(result));
            return 0;
        }

        // The report with every character outside ASCII written as a JSON escape, so it reads back the same whatever the console's
        // code page: an OEM code page turns a typographic apostrophe (U+2019) into a straight one, and CI's keeps it as it is.
        private static string AsciiJson(object value)
        {
            string json = Json.Serialize(value);
            StringBuilder ascii = new StringBuilder(json.Length);
            foreach (char character in json)
            {
                if (character > 126)
                {
                    ascii.Append("\\u").Append(((int)character).ToString("x4"));
                }
                else
                {
                    ascii.Append(character);
                }
            }
            return ascii.ToString();
        }

        [STAThread]
        public static int Main(string[] args)
        {
            // A window is built to be read and never shown, which needs a thread of its own kind; nothing is displayed.
            int exitCode = 1;
            Exception failure = null;
            Thread thread = new Thread(delegate ()
            {
                try { exitCode = Run(args[0]); }
                catch (Exception error) { failure = error; }
            });
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            thread.Join();
            if (failure != null)
            {
                Console.Error.WriteLine(failure.ToString());
                return 2;
            }
            return exitCode;
        }
    }
}
