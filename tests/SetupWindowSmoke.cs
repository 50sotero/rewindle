using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

// Opens the real SetupWindow (the real web view, the real wizard bundle, the real message bridge) with a scripted stand-in for the
// installer behind it, clicks through every screen of an install and takes a screenshot of each, with the web view's own capture. It
// is built by tests\Test-SetupWindow.ps1 from installer\setup\*.cs (without Program.cs) and never starts the setup program, the
// installer, the uninstaller or Restic: plan mode is answered by a fake, the elevated launcher is a fake that only writes progress
// lines, and the places the host would look for an installed Rewindle are folders of this run's own. Windows' file and Save dialogs
// are never opened. It leaves nothing behind but the screenshots.
namespace Rewindle.Setup.Smoke
{
    internal sealed class ScriptedPlans : IPlanSource
    {
        private readonly string home;

        public ScriptedPlans(string home)
        {
            this.home = home;
        }

        public IDictionary<string, object> GetPlan(InstallerInputs inputs, CancellationToken cancel)
        {
            Thread.Sleep(350);
            cancel.ThrowIfCancellationRequested();
            if (Smoke.PlansFail)
            {
                throw new SetupFailure("plan_failed", "Setup couldn’t check this PC (the installer stopped with code 1 and gave no plan).");
            }
            string[] keys = { "Desktop", "Documents", "Pictures", "Music", "Videos", "Downloads", "Favorites" };
            List<object> folders = new List<object>();
            List<object> sources = new List<object>();
            foreach (string key in keys)
            {
                Dictionary<string, object> folder = new Dictionary<string, object>();
                string path = Path.Combine(home, key);
                folder["key"] = key;
                folder["path"] = path;
                folder["exists"] = true;
                folder["default_selected"] = true;
                folders.Add(folder);
                sources.Add(path);
            }
            const long GB = 1024L * 1024L * 1024L;
            Dictionary<string, object> windows = Volume("C:\\", "Windows", "fixed", 476 * GB, 182 * GB, true, true, true, null, false);
            Dictionary<string, object> data = Volume("D:\\", "Data", "fixed", 465 * GB, 318 * GB, false, true, true, null, false);
            Dictionary<string, object> backup = Volume("E:\\", "Backup Drive", "removable", 1863 * GB, 1652 * GB, false, false, true, null, true);
            Dictionary<string, object> stick = Volume("F:\\", "USB STICK", "removable", 29 * GB, 21 * GB, false, false, false, "This drive uses FAT32. Backups need a drive formatted as NTFS.", false);
            stick["filesystem"] = "FAT32";

            Dictionary<string, object> plan = new Dictionary<string, object>();
            plan["schema"] = "Rewindle.InstallPlan.v1";
            plan["ok"] = true;
            plan["errors"] = new object[0];
            plan["warnings"] = new object[0];
            Dictionary<string, object> resolved = new Dictionary<string, object>();
            resolved["repository"] = inputs.Repository ?? "E:\\Rewindle Backups";
            resolved["storage_mode"] = "local_ntfs";
            resolved["drivefs_my_drive_root"] = null;
            resolved["sources"] = inputs.Sources.Count > 0 ? (object)inputs.Sources.ToArray() : sources.ToArray();
            resolved["canary_source"] = "C:\\ProgramData\\ResticBackuper\\Canary";
            resolved["schedule"] = inputs.Schedule ?? "02:00";
            resolved["vss"] = inputs.Vss;
            resolved["minimum_free_bytes"] = 10 * GB;
            resolved["estimated_source_bytes"] = null;
            plan["resolved"] = resolved;
            Dictionary<string, object> defaults = new Dictionary<string, object>();
            defaults["repository"] = "E:\\Rewindle Backups";
            defaults["storage_mode"] = "local_ntfs";
            defaults["sources"] = sources.ToArray();
            defaults["schedule"] = "02:00";
            plan["defaults"] = defaults;
            Dictionary<string, object> os = new Dictionary<string, object>();
            os["caption"] = "Microsoft Windows 11 Home";
            os["build"] = "26200";
            os["x64"] = true;
            os["supported"] = true;
            Dictionary<string, object> existing = new Dictionary<string, object>();
            existing["rewindle"] = null;
            existing["legacy_personal_edition"] = false;
            Dictionary<string, object> drivefs = new Dictionary<string, object>();
            drivefs["detected"] = false;
            drivefs["my_drive_root"] = null;
            Dictionary<string, object> environment = new Dictionary<string, object>();
            environment["version"] = Smoke.ProductVersion;
            environment["os"] = os;
            environment["powershell"] = "5.1";
            environment["dotnet_framework_48"] = true;
            environment["elevated"] = false;
            environment["webview2"] = "141.0.0.0";
            environment["existing_install"] = existing;
            environment["volumes"] = new object[] { windows, data, backup, stick };
            environment["drivefs"] = drivefs;
            environment["known_folders"] = folders.ToArray();
            plan["environment"] = environment;
            return Json.AsObject(Json.Parse(Json.Serialize(plan)));
        }

        private static Dictionary<string, object> Volume(string root, string label, string type, long size, long free, bool system, bool sameDisk, bool eligible, string reason, bool recommended)
        {
            Dictionary<string, object> volume = new Dictionary<string, object>();
            volume["root"] = root;
            volume["label"] = label;
            volume["filesystem"] = "NTFS";
            volume["drive_type"] = type;
            volume["size_bytes"] = size;
            volume["free_bytes"] = free;
            volume["is_system"] = system;
            volume["same_physical_disk_as_system"] = sameDisk;
            volume["eligible"] = eligible;
            volume["ineligible_reason"] = reason;
            volume["recommended"] = recommended;
            return volume;
        }
    }

    internal sealed class ScriptedProcess : IElevatedProcess
    {
        private readonly ManualResetEvent finished = new ManualResetEvent(false);

        private readonly int exitCode;

        public ScriptedProcess(string progressPath, string keyPath, bool fail)
        {
            exitCode = fail ? 1 : 0;
            Task.Factory.StartNew(delegate
            {
                string[][] phases =
                {
                    new string[] { "preflight", "Checking this PC" },
                    new string[] { "webview2", "Getting the display component" },
                    new string[] { "payload", "Copying Rewindle" },
                    new string[] { "permissions", "Protecting Rewindle’s files" },
                    new string[] { "credential", "Creating your encryption password" },
                    new string[] { "repository", "Preparing your backup location" },
                    new string[] { "recovery_key", "Saving your recovery key" },
                    new string[] { "canary", "Adding a restore test file" },
                    new string[] { "tasks", "Scheduling daily backups" },
                    new string[] { "dashboard", "Setting up the Rewindle app" },
                    new string[] { "verification", "Checking that everything works" },
                    new string[] { "first_backup", "Starting your first backup" },
                };
                int seq = 0;
                foreach (string[] phase in phases)
                {
                    foreach (string state in new string[] { "started", "completed" })
                    {
                        if (phase[0] == "webview2" && state == "started")
                        {
                            Append(progressPath, Line(++seq, phase[0], "skipped", phase[1]));
                            break;
                        }
                        if (fail && phase[0] == "repository" && state == "completed")
                        {
                            string message = "The drive E: stopped responding while the backup location was being prepared.";
                            Dictionary<string, object> failedLine = new Dictionary<string, object>();
                            failedLine["schema"] = "Rewindle.InstallProgress.v1";
                            failedLine["seq"] = ++seq;
                            failedLine["time"] = DateTime.UtcNow.ToString("o");
                            failedLine["type"] = "phase";
                            failedLine["phase"] = "repository";
                            failedLine["state"] = "failed";
                            failedLine["title"] = phase[1];
                            failedLine["detail"] = message;
                            Append(progressPath, Json.Serialize(failedLine));
                            Dictionary<string, object> error = new Dictionary<string, object>();
                            error["code"] = "repository_prepare_failed";
                            error["message"] = message;
                            Dictionary<string, object> failure = new Dictionary<string, object>();
                            failure["schema"] = "Rewindle.InstallProgress.v1";
                            failure["type"] = "result";
                            failure["ok"] = false;
                            failure["error"] = error;
                            Append(progressPath, Json.Serialize(failure));
                            finished.Set();
                            return;
                        }
                        Append(progressPath, Line(++seq, phase[0], state, phase[1]));
                        Thread.Sleep(280);
                    }
                }
                Dictionary<string, object> result = new Dictionary<string, object>();
                result["schema"] = "Rewindle.InstallProgress.v1";
                result["type"] = "result";
                result["ok"] = true;
                result["error"] = null;
                result["install_root"] = "C:\\Program Files\\ResticBackuper";
                result["recovery_key_path"] = keyPath;
                result["recovery_key_readable_by_user"] = true;
                result["dashboard_executable"] = "C:\\Program Files\\ResticBackuper\\ResticBackuperDashboard.exe";
                result["version"] = Smoke.ProductVersion;
                Append(progressPath, Json.Serialize(result));
                finished.Set();
            }, TaskCreationOptions.LongRunning);
        }

        private static string Line(int seq, string phase, string state, string title)
        {
            Dictionary<string, object> line = new Dictionary<string, object>();
            line["schema"] = "Rewindle.InstallProgress.v1";
            line["seq"] = seq;
            line["time"] = DateTime.UtcNow.ToString("o");
            line["type"] = "phase";
            line["phase"] = phase;
            line["state"] = state;
            line["title"] = title;
            line["detail"] = null;
            return Json.Serialize(line);
        }

        private static void Append(string path, string line)
        {
            File.AppendAllText(path, line + "\r\n", new UTF8Encoding(false));
        }

        public bool WaitForExit(int milliseconds)
        {
            return finished.WaitOne(milliseconds);
        }

        public int ExitCode
        {
            get { return exitCode; }
        }

        public void Dispose()
        {
        }
    }

    internal sealed class ScriptedLauncher : IElevatedLauncher
    {
        private readonly string keyPath;
        private readonly string mode;
        private int starts;

        public ScriptedLauncher(string keyPath, string mode)
        {
            this.keyPath = keyPath;
            this.mode = mode;
        }

        public bool FeedOwnedByAdministrators
        {
            get { return false; }
        }

        public IElevatedProcess Start(IList<string> powershellArguments, BundleLaunch bundle)
        {
            Thread.Sleep(900);
            starts++;
            // The first Windows prompt is declined in the "declined" case; trying again goes through.
            if (mode == "declined" && starts == 1)
            {
                throw new ElevationDeclinedException();
            }
            return new ScriptedProcess(powershellArguments[powershellArguments.IndexOf("-ProgressPath") + 1], keyPath, mode == "install-failure");
        }
    }

    internal static class Smoke
    {
        private static string outputFolder;
        private static string theme = "light";
        // happy, plan-failure (the first check of the PC fails), install-failure, declined (the first Windows prompt is declined) or
        // runtime-missing (the window opens as on a PC without the WebView2 Runtime).
        private static string scenario = "happy";
        // Draws the page as Windows' High Contrast makes it (the web view's forced-colors mode), for a look at it.
        private static bool forcedColors;
        // While true, every check of the PC fails; the plan-failure case turns it off before choosing "Try again".
        internal static volatile bool PlansFail;
        // The version the window shows (Test-SetupWindow passes the one in VERSION).
        internal static string ProductVersion = "0.0.0";
        private static readonly List<string> log = new List<string>();
        private static int shot;

        [STAThread]
        private static int Main(string[] args)
        {
            string web = null;
            string libs = null;
            string icon = null;
            double width = 960;
            double height = 680;
            for (int index = 0; index < args.Length - 1; index++)
            {
                switch (args[index])
                {
                    case "--web": web = args[index + 1]; break;
                    case "--libs": libs = args[index + 1]; break;
                    case "--icon": icon = args[index + 1]; break;
                    case "--out": outputFolder = args[index + 1]; break;
                    case "--theme": theme = args[index + 1]; break;
                    case "--case": scenario = args[index + 1]; break;
                    case "--forced-colors": forcedColors = args[index + 1] == "yes"; break;
                    case "--width": width = double.Parse(args[index + 1]); break;
                    case "--height": height = double.Parse(args[index + 1]); break;
                    case "--version": ProductVersion = args[index + 1]; break;
                    case "--culture":
                        // The number and date formats the pages use (the host reports this culture), e.g. en-US for screenshots.
                        CultureInfo culture = CultureInfo.GetCultureInfo(args[index + 1]);
                        CultureInfo.DefaultThreadCurrentCulture = culture;
                        Thread.CurrentThread.CurrentCulture = culture;
                        break;
                }
            }
            Directory.CreateDirectory(outputFolder);
            string root = Path.Combine(Path.GetTempPath(), "rewindle-setup-smoke-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            SetupWorkspace workspace = null;
            try
            {
                string webZip = Path.Combine(root, "web.zip");
                ZipFile.CreateFromDirectory(web, webZip);
                Func<string, Stream> open = delegate(string name)
                {
                    if (name == SetupWorkspace.WebResource) { return File.OpenRead(webZip); }
                    foreach (string[] library in SetupWorkspace.WebViewLibraries)
                    {
                        if (library[0] == name) { return File.OpenRead(Path.Combine(libs, library[1])); }
                    }
                    return null;
                };
                workspace = new SetupWorkspace(open, root);
                workspace.ExtractLibraries();
                WebViewLibraries.Install(workspace.ResolvedLibraryFolder);
                workspace.ReadWeb();
                ThemeState chosen = new ThemeState();
                chosen.Dark = theme == "dark";
                SystemTheme.Override = chosen;
                return Run(workspace, root, icon, width, height);
            }
            finally
            {
                File.WriteAllLines(Path.Combine(outputFolder, "smoke-" + scenario + "-" + theme + ".log"), log.ToArray());
                if (workspace != null) { workspace.Dispose(); }
                try { Directory.Delete(root, true); } catch (Exception) { }
            }
        }

        // Not inlined into Main: the first code that needs the WebView2 assemblies, found only after WebViewLibraries.Install.
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int Run(SetupWorkspace workspace, string root, string iconPath, double width, double height)
        {
            string home = Path.Combine(root, "home");
            foreach (string key in new string[] { "Desktop", "Documents", "Pictures", "Music", "Videos", "Downloads", "Favorites" })
            {
                string folder = Path.Combine(home, key);
                Directory.CreateDirectory(folder);
                for (int index = 0; index < 20; index++)
                {
                    File.WriteAllBytes(Path.Combine(folder, "file" + index + ".bin"), new byte[(index + 1) * 40000]);
                }
            }
            string keyFile = Path.Combine(root, "ResticBackuper-RecoveryKey.txt");
            File.WriteAllText(keyFile, "not a real recovery key");

            BridgeEnvironment environment = new BridgeEnvironment();
            environment.ProductVersion = ProductVersion;
            environment.UserSid = "S-1-5-21-1-2-3-1001";
            environment.ProgramFilesFolder = Path.Combine(root, "Program Files");
            environment.CommonDataFolder = Path.Combine(root, "ProgramData");
            environment.Plans = new ScriptedPlans(home);
            environment.Launcher = new ScriptedLauncher(keyFile, scenario);
            environment.EnsureBundle = delegate { return Task.Factory.StartNew(delegate { }); };
            environment.InstallScriptPath = Path.Combine(root, "Install-ResticBackuper.ps1");
            File.WriteAllText(environment.InstallScriptPath, "# stand-in");
            environment.BundledUninstallScriptPath = Path.Combine(root, "Uninstall-ResticBackuper.ps1");
            environment.CreateProgressFolder = workspace.CreateProgressFolder;

            ImageSource icon = null;
            if (iconPath != null && File.Exists(iconPath))
            {
                BitmapDecoder decoder = BitmapDecoder.Create(new Uri(iconPath), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                icon = decoder.Frames[0];
            }
            if (scenario == "runtime-missing")
            {
                WebViewRuntime.Probe = delegate { return null; };
            }
            Application application = new Application();
            application.ShutdownMode = ShutdownMode.OnMainWindowClose;
            SetupWindow window = new SetupWindow(workspace, environment, icon);
            window.Width = width;
            window.Height = height;
            int exitCode = 1;
            window.ContentRendered += async delegate
            {
                try
                {
                    await Drive(window);
                    exitCode = 0;
                }
                catch (Exception error)
                {
                    log.Add("FAILED: " + error);
                    Console.WriteLine("FAILED: " + error.Message);
                }
                window.Close();
            };
            application.Run(window);
            return exitCode;
        }

        private static WebView2 ViewOf(SetupWindow window)
        {
            FieldInfo field = typeof(SetupWindow).GetField("webView", BindingFlags.Instance | BindingFlags.NonPublic);
            return (WebView2)field.GetValue(window);
        }

        private static async Task<string> Eval(WebView2 view, string script)
        {
            return await view.CoreWebView2.ExecuteScriptAsync(script);
        }

        private static async Task WaitUntil(WebView2 view, string condition, string what, int milliseconds)
        {
            DateTime until = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (DateTime.UtcNow < until)
            {
                string answer = await Eval(view, "(function(){try{return !!(" + condition + ")}catch(e){return false}})()");
                if (answer == "true")
                {
                    log.Add("ok: " + what);
                    return;
                }
                await Task.Delay(120);
            }
            string where = await Eval(view, "JSON.stringify({text: document.body.innerText.slice(0, 400), errors: window.__errors || null, href: location.href})");
            throw new TimeoutException("Timed out waiting for " + what + ". The page says: " + where);
        }

        private static async Task Click(WebView2 view, string text)
        {
            string script = "(function(){var b=[].slice.call(document.querySelectorAll('button')).filter(function(x){return x.textContent.trim()==='" +
                text.Replace("'", "\\'") + "' && !x.disabled})[0]; if(b){b.click();return true} return false})()";
            await WaitUntil(view, script, "the button '" + text + "'", 15000);
        }

        private static async Task Shot(WebView2 view, string name)
        {
            await Task.Delay(450);
            using (MemoryStream stream = new MemoryStream())
            {
                await view.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream);
                string file = Path.Combine(outputFolder, "smoke-" + scenario + "-" + theme + "-" + (++shot).ToString("00") + "-" + name + ".png");
                File.WriteAllBytes(file, stream.ToArray());
                log.Add("shot: " + file);
                Console.WriteLine("Wrote " + file);
            }
        }

        // The window as it opens on a PC without the WebView2 Runtime: the plain native screen, and no web view.
        private static async Task DriveMissingRuntime(SetupWindow window)
        {
            await Task.Delay(1500);
            if (ViewOf(window) != null) { throw new InvalidOperationException("A web view was created although the runtime was reported missing."); }
            log.Add("ok: no web view was created");
            UIElement content = (UIElement)window.Content;
            int width = (int)window.ActualWidth;
            int height = (int)window.ActualHeight;
            RenderTargetBitmap bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(content);
            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            string file = Path.Combine(outputFolder, "smoke-" + scenario + "-" + theme + "-01-native-runtime-missing.png");
            using (FileStream stream = File.Create(file)) { encoder.Save(stream); }
            log.Add("shot: " + file);
            Console.WriteLine("Wrote " + file);
        }

        private static async Task Drive(SetupWindow window)
        {
            if (scenario == "runtime-missing")
            {
                await DriveMissingRuntime(window);
                return;
            }
            PlansFail = scenario == "plan-failure";
            DateTime until = DateTime.UtcNow.AddSeconds(60);
            WebView2 view = null;
            while (DateTime.UtcNow < until)
            {
                view = ViewOf(window);
                if (view != null && view.CoreWebView2 != null) { break; }
                await Task.Delay(100);
            }
            if (view == null || view.CoreWebView2 == null) { throw new TimeoutException("The web view did not start."); }
            log.Add("ok: the web view started");
            // The window navigates to the wizard right after the control starts; reloading before that would cancel it.
            until = DateTime.UtcNow.AddSeconds(30);
            while (DateTime.UtcNow < until && !WebPolicy.IsAllowedUri(view.CoreWebView2.Source))
            {
                await Task.Delay(100);
            }
            if (!WebPolicy.IsAllowedUri(view.CoreWebView2.Source)) { throw new TimeoutException("The window did not navigate to the wizard: " + view.CoreWebView2.Source); }
            log.Add("ok: the window navigated to the wizard");

            // Collect script errors from the start of the page.
            await view.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                "window.__errors=[];window.addEventListener('error',function(e){window.__errors.push(String(e.message))});" +
                "window.addEventListener('unhandledrejection',function(e){window.__errors.push('rejection: '+e.reason)});");
            view.CoreWebView2.Reload();
            await Task.Delay(500);

            await WaitUntil(view, "document.getElementById('screen-title') && document.getElementById('screen-title').textContent.length > 0", "the first screen", 45000);
            if (forcedColors)
            {
                await view.CoreWebView2.CallDevToolsProtocolMethodAsync(
                    "Emulation.setEmulatedMedia",
                    "{\"features\":[{\"name\":\"forced-colors\",\"value\":\"active\"}]}");
                log.Add("ok: forced colors on");
                await Task.Delay(500);
            }
            string title = await Eval(view, "document.getElementById('screen-title').textContent");
            log.Add("first screen: " + title);
            if (scenario == "plan-failure")
            {
                // The installer could not describe the PC: the wizard says so, and trying again goes through.
                await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('couldn') >= 0", "the screen that says the PC could not be checked", 15000);
                await Shot(view, "plan-failed");
                PlansFail = false;
                await Click(view, "Try again");
                await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('verify') >= 0", "the welcome screen after trying again", 15000);
                await Shot(view, "welcome-after-retry");
                await CheckErrors(view);
                return;
            }
            await Shot(view, "welcome");

            // Ctrl+= and Ctrl+0 reach the host as setZoom commands, and the host changes the page's size.
            await Eval(view, "window.dispatchEvent(new KeyboardEvent('keydown',{key:'=',ctrlKey:true,bubbles:true,cancelable:true}))");
            await Task.Delay(700);
            if (Math.Abs(view.ZoomFactor - 1.1) > 0.001) { throw new InvalidOperationException("Ctrl+= did not zoom to 110% (it is " + view.ZoomFactor + ")."); }
            log.Add("ok: Ctrl+= zoomed the page to 110%");
            await Shot(view, "welcome-zoomed");
            await Eval(view, "window.dispatchEvent(new KeyboardEvent('keydown',{key:'0',ctrlKey:true,bubbles:true,cancelable:true}))");
            await Task.Delay(700);
            if (Math.Abs(view.ZoomFactor - 1.0) > 0.001) { throw new InvalidOperationException("Ctrl+0 did not return to 100% (it is " + view.ZoomFactor + ")."); }
            log.Add("ok: Ctrl+0 returned the page to 100%");

            await Click(view, "Next");
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('protect') >= 0", "What to protect", 10000);
            await Task.Delay(2500);
            await Shot(view, "folders");

            await Click(view, "Next");
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('backups be kept') >= 0", "Where to keep backups", 10000);
            await Task.Delay(1000);
            await Shot(view, "location");

            await Click(view, "Next");
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('When should') >= 0", "When to back up", 10000);
            await Shot(view, "schedule");

            await Click(view, "Next");
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('Ready to install') >= 0", "Review", 10000);
            await Shot(view, "review");

            await Click(view, "Install");
            if (scenario == "declined")
            {
                await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('wasn') >= 0", "the screen that says Windows permission was not given", 20000);
                await Shot(view, "declined");
                await Click(view, "Try again");
                await WaitUntil(view, "document.querySelector('.phase-list')", "the install after trying again", 20000);
                await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('is installed') >= 0", "the install finishing", 60000);
                await Shot(view, "installed-after-retry");
                await CheckErrors(view);
                return;
            }
            await WaitUntil(view, "document.querySelector('.phase-list')", "the install steps", 15000);
            await Task.Delay(1500);
            await Shot(view, "installing");
            if (scenario == "install-failure")
            {
                await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('finish') >= 0", "the screen that says setup could not finish", 60000);
                await Shot(view, "failed");
                await CheckErrors(view);
                return;
            }
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('is installed') >= 0", "the install finishing", 60000);
            await Shot(view, "installed");

            await Click(view, "Continue");
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('recovery key') >= 0", "the recovery key", 10000);
            await Shot(view, "recovery");

            await Eval(view, "document.querySelector('.ack input').click()");
            await Click(view, "Finish");
            await WaitUntil(view, "document.getElementById('screen-title').textContent.indexOf('all set') >= 0", "Done", 10000);
            await Shot(view, "done");

            await Click(view, "Open Rewindle");
            await WaitUntil(view, "document.querySelector('.callout.is-error')", "the answer when Rewindle is not installed where the host looks", 10000);
            await Shot(view, "done-not-found");

            await CheckErrors(view);
        }

        private static async Task CheckErrors(WebView2 view)
        {
            string errors = await Eval(view, "JSON.stringify(window.__errors||[])");
            log.Add("script errors: " + errors);
            if (errors != "\"[]\"") { throw new InvalidOperationException("The page reported script errors: " + errors); }
        }
    }
}
