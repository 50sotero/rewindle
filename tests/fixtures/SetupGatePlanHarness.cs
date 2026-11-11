using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// The check Setup makes just before an install, as the setup host really does it (tests\test_setup_host_gate_plan.py compiles this file
// with installer\setup\*.cs, without Program.cs, SetupWindow.cs, FolderPicker.cs and AssemblyInfo.cs, as tests\Test-SetupHost.ps1 does,
// and runs the result). The person picked No password for a new, empty location. A plan made without that pick resolves a password for
// the location, and finds an old recovery key file in the profile an error (recovery_key_stale), though the install, which is told the
// pick, never reads that file. The install must not stop for it, and the plans the wizard asks for must stay free of the pick.
//
// It creates no window and uses no WPF type, starts no elevated process and touches nothing outside the folder it is given: the elevated
// launcher is a fake that only writes a progress line. Plan mode is answered by a fake that decides from the very arguments
// InstallerContract.PlanArguments builds, and by the real PlanRunner against a stub installer script in that folder (a normal, hidden
// Windows PowerShell run, as PlanRunner always makes it). The report is JSON on standard output.
namespace Rewindle.Setup.GateHarness
{
    // Answers as the installer does for a new, empty location with an old recovery key file in the profile: that is an error (field
    // environment) unless the request carries -RepositoryAccess no_password. Whether it does is read from the arguments the host builds
    // for the request, not from the flag, so the answer follows what the installer would really have been given.
    internal sealed class KeyFileSensitivePlans : IPlanSource
    {
        public readonly List<bool> Asked = new List<bool>();
        // The value each request would carry after -RepositoryAccess, or an empty string when it would not carry the parameter.
        public readonly List<string> Picks = new List<string>();

        public IDictionary<string, object> GetPlan(InstallerInputs inputs, bool forInstall, CancellationToken cancel)
        {
            List<string> arguments = InstallerContract.PlanArguments("Install-ResticBackuper.ps1", "plan.json", inputs, forInstall);
            int at = arguments.IndexOf("-RepositoryAccess");
            string pick = at < 0 ? string.Empty : arguments[at + 1];
            lock (this)
            {
                Asked.Add(forInstall);
                Picks.Add(pick);
            }
            return SetupGatePlanHarness.ParsePlan(pick == InstallerContract.AccessNone ? SetupGatePlanHarness.CleanPlan : SetupGatePlanHarness.StaleKeyPlan);
        }
    }

    internal sealed class FinishedProcess : IElevatedProcess
    {
        public bool WaitForExit(int milliseconds)
        {
            return true;
        }

        public int ExitCode
        {
            get { return 0; }
        }

        public void Dispose()
        {
        }
    }

    // Stands in for the elevated start: records the arguments, and writes the installer's success line into the progress file it was given.
    internal sealed class RecordingLauncher : IElevatedLauncher
    {
        public int Starts;
        public List<string> Arguments;

        public bool FeedOwnedByAdministrators
        {
            get { return false; }
        }

        public IElevatedProcess Start(IList<string> powershellArguments, BundleLaunch bundle)
        {
            Starts++;
            Arguments = new List<string>(powershellArguments);
            string progress = powershellArguments[powershellArguments.IndexOf("-ProgressPath") + 1];
            File.AppendAllText(
                progress,
                "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null}\r\n",
                new UTF8Encoding(false));
            return new FinishedProcess();
        }

        // The value after -RepositoryAccess in the install's command line, or null when the install did not get the parameter.
        public string AccessGiven()
        {
            if (Arguments == null)
            {
                return null;
            }
            int at = Arguments.IndexOf("-RepositoryAccess");
            return at < 0 ? null : Arguments[at + 1];
        }
    }

    // The window the bridge serves, without a window: it keeps what the bridge sends to the page.
    internal sealed class RecordingServices : IBridgeServices
    {
        public readonly List<string> Sent = new List<string>();
        private readonly ThemeState theme = new ThemeState();

        public void Post(Action work) { work(); }
        public void Send(string json) { lock (Sent) { Sent.Add(json); } }
        public ThemeState Theme { get { return theme; } }
        public string Locale { get { return "en-US"; } }
        public string PickFolder(string title, string okButtonLabel, string legacyDescription) { return string.Empty; }
        public string PickSaveFile(string initialFolder, string suggestedName) { return string.Empty; }
        public void CopyToClipboard(string text) { }
        public void OpenAddress(string address) { }
        public void RevealFile(string path) { }
        public void StartProgram(string path, string arguments) { }
        public string Zoom(string direction) { return "Zoom " + direction; }
        public void RequestClose() { }

        public IDictionary<string, object> Message(Func<IDictionary<string, object>, bool> match, int milliseconds)
        {
            DateTime deadline = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (true)
            {
                lock (Sent)
                {
                    foreach (string json in Sent)
                    {
                        IDictionary<string, object> message = Json.AsObject(Json.Parse(json));
                        if (message != null && match(message))
                        {
                            return message;
                        }
                    }
                }
                if (DateTime.UtcNow > deadline)
                {
                    return null;
                }
                Thread.Sleep(20);
            }
        }

        public IDictionary<string, object> Response(string id)
        {
            return Message(delegate(IDictionary<string, object> message)
            {
                return Json.String(message, "type", 16) == "response" && Json.String(message, "id", 64) == id;
            }, 30000);
        }

        public IDictionary<string, object> Event(string name)
        {
            return Message(delegate(IDictionary<string, object> message)
            {
                return Json.String(message, "type", 16) == "event" && Json.String(message, "event", 64) == name;
            }, 30000);
        }
    }

    internal static class SetupGatePlanHarness
    {
        public const string CleanPlan = "{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":true,\"errors\":[],\"warnings\":[]}";
        public const string StaleKeyPlan = "{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":false,\"errors\":[{\"code\":\"recovery_key_stale\"," +
            "\"field\":\"environment\",\"message\":\"An older recovery key file is in the way.\"}],\"warnings\":[]}";
        private const string User = "S-1-5-21-1-2-3-1001";

        public static IDictionary<string, object> ParsePlan(string text)
        {
            IDictionary<string, object> plan;
            string problem;
            if (!InstallerContract.TryReadPlan(text, out plan, out problem))
            {
                throw new InvalidOperationException(problem);
            }
            return plan;
        }

        private static int Main(string[] args)
        {
            try
            {
                string root = Path.GetFullPath(args[0]);
                Directory.CreateDirectory(root);
                Dictionary<string, object> report = new Dictionary<string, object>();
                report["plan_arguments"] = ArgumentLists();
                report["operation"] = OperationWithFakePlans(Directory.CreateDirectory(Path.Combine(root, "operation")).FullName);
                report["bridge"] = Bridge(Directory.CreateDirectory(Path.Combine(root, "bridge")).FullName);
                bool runnerAvailable = File.Exists(PlanRunner.WindowsPowerShellPath());
                report["runner_available"] = runnerAvailable;
                if (runnerAvailable)
                {
                    report["runner"] = WithTheRealPlanRunner(Directory.CreateDirectory(Path.Combine(root, "runner")).FullName);
                }
                Console.Out.Write(new JavaScriptSerializer().Serialize(report));
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
        }

        private static InstallerInputs Inputs(string access)
        {
            InstallerInputs inputs = new InstallerInputs();
            inputs.Repository = @"E:\Rewindle Backups";
            inputs.Sources.Add(@"C:\Users\you\Documents");
            inputs.Schedule = "02:00";
            inputs.RepositoryAccess = access;
            return inputs;
        }

        // ---- PlanArguments ---------------------------------------------------------------------------------------------------------

        private static Dictionary<string, object> ArgumentLists()
        {
            Dictionary<string, object> lists = new Dictionary<string, object>();
            foreach (string access in new string[] { InstallerContract.AccessNone, InstallerContract.AccessPassword, null })
            {
                string name = access ?? "none";
                InstallerInputs inputs = Inputs(access);
                lists["for_install:" + name] = InstallerContract.PlanArguments(@"C:\t\Install-ResticBackuper.ps1", @"C:\t\plan.json", inputs, true).ToArray();
                lists["for_wizard:" + name] = InstallerContract.PlanArguments(@"C:\t\Install-ResticBackuper.ps1", @"C:\t\plan.json", inputs, false).ToArray();
                lists["install:" + name] = InstallerContract.InstallArguments(@"C:\t\Install-ResticBackuper.ps1", User, @"C:\t\progress.jsonl", inputs).ToArray();
            }
            return lists;
        }

        // ---- an install, asking a fake for its check -----------------------------------------------------------------------------

        // Runs one install to its end, with the given source of plans and the stand-in for the elevated start.
        private static Dictionary<string, object> RunInstall(IPlanSource plans, string folder, string script, string access)
        {
            RecordingLauncher launcher = new RecordingLauncher();
            List<object> stages = new List<object>();
            string[] outcome = new string[1];
            string[] firstPlanError = new string[1];
            SetupOperation operation = new SetupOperation(
                SetupOperation.Install,
                plans,
                launcher,
                User,
                script,
                null,
                delegate
                {
                    string progress = Path.Combine(folder, "attempt-" + Guid.NewGuid().ToString("N").Substring(0, 6));
                    Directory.CreateDirectory(progress);
                    return progress;
                },
                delegate(string name, Dictionary<string, object> data)
                {
                    lock (stages)
                    {
                        if (name == "operationStage")
                        {
                            stages.Add(data["stage"]);
                        }
                        if (name == "operationFinished")
                        {
                            outcome[0] = (string)data["outcome"];
                            IDictionary<string, object> plan = data.ContainsKey("plan") ? data["plan"] as IDictionary<string, object> : null;
                            IList<object> errors = plan == null ? null : Json.AsList(Json.Get(plan, "errors"));
                            if (errors != null && errors.Count > 0)
                            {
                                firstPlanError[0] = Json.String(Json.AsObject(errors[0]), "code", 64);
                            }
                        }
                    }
                },
                null);
            operation.Run(Inputs(access));
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["outcome"] = outcome[0];
            result["stages"] = stages.ToArray();
            result["starts"] = launcher.Starts;
            result["access_given"] = launcher.AccessGiven();
            result["blocked_by"] = firstPlanError[0];
            return result;
        }

        private static Dictionary<string, object> OperationWithFakePlans(string folder)
        {
            string script = Path.Combine(folder, "Install-ResticBackuper.ps1");
            File.WriteAllText(script, "# stub");
            Dictionary<string, object> cases = new Dictionary<string, object>();
            foreach (string access in new string[] { InstallerContract.AccessNone, InstallerContract.AccessPassword, null })
            {
                KeyFileSensitivePlans plans = new KeyFileSensitivePlans();
                Dictionary<string, object> run = RunInstall(plans, folder, script, access);
                run["asked"] = plans.Asked.ToArray();
                run["picks"] = plans.Picks.ToArray();
                cases[access ?? "none"] = run;
            }
            return cases;
        }

        // ---- the page's plan request and install, through the bridge --------------------------------------------------------------

        private static string Request(string id, string command, string payloadJson)
        {
            return "{\"type\":\"request\",\"id\":\"" + id + "\",\"command\":\"" + command + "\"" +
                (payloadJson == null ? string.Empty : ",\"payload\":" + payloadJson) + "}";
        }

        private static Dictionary<string, object> Bridge(string folder)
        {
            string script = Path.Combine(folder, "Install-ResticBackuper.ps1");
            File.WriteAllText(script, "# stub");
            KeyFileSensitivePlans plans = new KeyFileSensitivePlans();
            RecordingLauncher launcher = new RecordingLauncher();
            RecordingServices services = new RecordingServices();
            BridgeEnvironment environment = new BridgeEnvironment();
            environment.ProductVersion = "9.9.9-test";
            environment.UserSid = User;
            environment.ProgramFilesFolder = Path.Combine(folder, "Program Files");
            environment.CommonDataFolder = Path.Combine(folder, "ProgramData");
            environment.Plans = plans;
            environment.Launcher = launcher;
            environment.EnsureBundle = delegate { return System.Threading.Tasks.Task.Factory.StartNew(delegate { }); };
            environment.InstallScriptPath = script;
            environment.BundledUninstallScriptPath = Path.Combine(folder, "Uninstall-ResticBackuper.ps1");
            environment.CreateProgressFolder = delegate
            {
                string progress = Path.Combine(folder, "p-" + Guid.NewGuid().ToString("N").Substring(0, 6));
                Directory.CreateDirectory(progress);
                return progress;
            };
            SetupBridge bridge = new SetupBridge(services, environment);
            Dictionary<string, object> result = new Dictionary<string, object>();
            try
            {
                // The page asks for a plan with an inputs payload that carries a (valid) password choice.
                bridge.Receive(Request("g1", "getPlan",
                    "{\"inputs\":{\"repository\":\"E:\\\\Rewindle Backups\",\"sources\":[\"C:\\\\Users\\\\you\\\\Documents\"],\"schedule\":\"02:00\",\"repositoryAccess\":\"no_password\"}}"));
                IDictionary<string, object> answer = services.Response("g1");
                result["wizard_plan_answered"] = answer != null && Json.Bool(answer, "ok") == true;
                IDictionary<string, object> wizardPlan = answer == null ? null : Json.AsObject(Json.Get(answer, "result"));
                result["wizard_plan_ok"] = wizardPlan == null ? null : Json.Bool(wizardPlan, "ok");

                // The install, with the pick.
                bridge.Receive(Request("i1", "install",
                    "{\"choices\":{\"repository\":\"E:\\\\Rewindle Backups\",\"storageMode\":\"local_ntfs\",\"sources\":[\"C:\\\\Users\\\\you\\\\Documents\"]," +
                    "\"schedule\":\"02:00\",\"vss\":true,\"startBackup\":false,\"repositoryAccess\":\"no_password\"}}"));
                IDictionary<string, object> started = services.Response("i1");
                result["install_started_answer"] = started != null && Json.Bool(started, "ok") == true;
                IDictionary<string, object> finished = services.Event("operationFinished");
                result["install_outcome"] = finished == null ? null : Json.String(Json.AsObject(Json.Get(finished, "data")), "outcome", 32);
                result["starts"] = launcher.Starts;
                result["access_given"] = launcher.AccessGiven();
                lock (plans)
                {
                    result["asked"] = plans.Asked.ToArray();
                    result["picks"] = plans.Picks.ToArray();
                }
            }
            finally
            {
                bridge.Shutdown();
            }
            return result;
        }

        // ---- the real PlanRunner, against a stub installer ------------------------------------------------------------------------

        // A stand-in for Install-ResticBackuper.ps1 in plan mode that behaves as the installer does for the location above: it notes the
        // password choice it was given (one line per run), and answers with the old recovery key file as an error unless it was given
        // -RepositoryAccess no_password.
        private const string StubInstaller = @"
param([switch]$PlanOnly, [string]$PlanOutput, [string]$Repository, [string]$RepositoryStorageMode, [string]$DriveFsMyDriveRoot,
      [string]$RepositoryAccess, [string]$SourceList, [string]$Schedule, [switch]$DisableVss)
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'received.txt'), ('access=' + $RepositoryAccess + ""`n""))
if ($RepositoryAccess -ceq 'no_password') {
    $plan = '{""schema"":""Rewindle.InstallPlan.v1"",""ok"":true,""errors"":[],""warnings"":[]}'
} else {
    $plan = '{""schema"":""Rewindle.InstallPlan.v1"",""ok"":false,""errors"":[{""code"":""recovery_key_stale"",""field"":""environment"",""message"":""An older recovery key file is in the way.""}],""warnings"":[]}'
}
[IO.File]::WriteAllText($PlanOutput, $plan, (New-Object System.Text.UTF8Encoding($false)))
exit 0
";

        private static string[] Received(string folder)
        {
            string path = Path.Combine(folder, "received.txt");
            string[] lines = File.Exists(path) ? File.ReadAllLines(path) : new string[0];
            if (File.Exists(path))
            {
                File.Delete(path);
            }
            return lines;
        }

        private static Dictionary<string, object> WithTheRealPlanRunner(string folder)
        {
            string script = Path.Combine(folder, "Install-ResticBackuper.ps1");
            File.WriteAllText(script, StubInstaller, new UTF8Encoding(true));
            PlanRunner runner = new PlanRunner(script, Path.Combine(folder, "plans"), TimeSpan.FromSeconds(90));
            Dictionary<string, object> report = new Dictionary<string, object>();

            Dictionary<string, object> picked = RunInstall(runner, folder, script, InstallerContract.AccessNone);
            picked["stub_received"] = Received(folder);
            report["install_no_password"] = picked;

            Dictionary<string, object> unpicked = RunInstall(runner, folder, script, null);
            unpicked["stub_received"] = Received(folder);
            report["install_no_pick"] = unpicked;

            // The same inputs asked for as the wizard does and as the check before an install does.
            InstallerInputs inputs = Inputs(InstallerContract.AccessNone);
            Dictionary<string, object> wizard = new Dictionary<string, object>();
            wizard["plan_allows_install"] = InstallerContract.PlanAllowsInstall(runner.GetPlan(inputs, false, CancellationToken.None));
            wizard["stub_received"] = Received(folder);
            report["wizard_plan"] = wizard;
            Dictionary<string, object> gate = new Dictionary<string, object>();
            gate["plan_allows_install"] = InstallerContract.PlanAllowsInstall(runner.GetPlan(inputs, true, CancellationToken.None));
            gate["stub_received"] = Received(folder);
            report["install_plan"] = gate;
            return report;
        }
    }
}
