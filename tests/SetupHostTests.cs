using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

// Hermetic checks of the logic in installer\setup\*.cs, compiled together with those sources by tests\Test-SetupHost.ps1 (it
// leaves out Program.cs and SetupWindow.cs, the only files that need the WebView2 libraries and a screen). Nothing here starts
// the setup program, the installer, the uninstaller or Restic: the installer is replaced by a stub script in a temporary
// folder, the elevated launcher by a fake, and every file is made and removed below a folder of this run's own.
namespace Rewindle.Setup.Tests
{
    internal static class Harness
    {
        private static int passed;
        private static readonly List<string> failures = new List<string>();
        private static string root;

        [STAThread]
        private static int Main(string[] args)
        {
            root = Path.Combine(Path.GetTempPath(), "rewindle-setup-host-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                string renderTo = null;
                string iconPath = null;
                string builtProgram = null;
                string projectRoot = null;
                for (int index = 0; index < args.Length - 1; index++)
                {
                    if (args[index] == "--render") { renderTo = args[index + 1]; }
                    if (args[index] == "--icon") { iconPath = args[index + 1]; }
                    if (args[index] == "--built") { builtProgram = args[index + 1]; }
                    if (args[index] == "--project") { projectRoot = args[index + 1]; }
                }
                if (renderTo != null)
                {
                    RenderPanels(renderTo, iconPath);
                    return 0;
                }

                Run("CommandLine round trip", CommandLineRoundTrip);
                Run("Paths and inputs", PathsAndInputs);
                Run("Installer arguments", InstallerArguments);
                Run("Plan files and progress lines", PlanAndProgressLines);
                Run("Progress tail", ProgressTailBehaviour);
                Run("Safe ZIP extraction", SafeZipBehaviour);
                Run("Workspace", WorkspaceBehaviour);
                Run("Folder measurement", FolderMeasurement);
                Run("Exclusion rules", ExclusionRuleBehaviour);
                Run("Plan runner (stub installer)", PlanRunnerBehaviour);
                Run("Install and uninstall flow", OperationFlow);
                Run("Bridge protocol", ProtocolBehaviour);
                Run("Bridge commands", BridgeCommands);
                Run("Uninstaller compatibility", UninstallerCompatibility);
                Run("Elevated bootstrap", ElevatedBootstrapBehaviour);
                Run("Web policy", WebPolicyBehaviour);
                Run("Microsoft signature check", SignatureCheck);
                Run("Native screen palette", PaletteBehaviour);
                if (builtProgram != null)
                {
                    string program = builtProgram;
                    string project = projectRoot;
                    Run("The built setup program's resources", delegate { BuiltProgramResources(program, project); });
                    Run("Exclusion rules agree with the engine", delegate { ExclusionRuleParity(project); });
                }
            }
            finally
            {
                Cleanup();
            }
            Console.WriteLine();
            Console.WriteLine("{0} checks passed, {1} failed.", passed, failures.Count);
            foreach (string failure in failures)
            {
                Console.WriteLine("  FAILED: " + failure);
            }
            return failures.Count == 0 ? 0 : 1;
        }

        // The folders the backup leaves out, as the engine's preflight prunes them (a port of its literal-rule compiler).
        private static void ExclusionRuleBehaviour()
        {
            ExclusionRules rules = ExclusionRules.Parse(new string[]
            {
                "# a comment", "", "**/node_modules", "**/.gradle/caches", "C:/Windows/Temp", "E:\\code\\**\\target",
                "**/*.pyc", "!**/keep", "**/a/*/b", "**", "**/x/**/y",
            });
            Check(rules.IsDefinitelyExcluded(@"C:\Users\you\Projects\app\node_modules"), "a **/name rule prunes that folder anywhere");
            Check(rules.IsDefinitelyExcluded(@"C:\Users\you\Projects\App\NODE_MODULES"), "case does not matter");
            Check(!rules.IsDefinitelyExcluded(@"C:\Users\you\node_modules_backup"), "a different name is not pruned");
            Check(rules.IsDefinitelyExcluded(@"D:\work\.gradle\caches"), "a multi-part **/a/b rule prunes a/b");
            Check(!rules.IsDefinitelyExcluded(@"D:\work\.gradle"), "but not a alone");
            Check(rules.IsDefinitelyExcluded(@"C:\Windows\Temp"), "an absolute rule prunes exactly that folder");
            Check(!rules.IsDefinitelyExcluded(@"C:\Windows\Temp\sub"), "and not a folder below it");
            Check(rules.IsDefinitelyExcluded(@"E:\code\rust\target"), "a prefix/**/suffix rule prunes the suffix below the prefix");
            Check(!rules.IsDefinitelyExcluded(@"D:\code\rust\target"), "and not below another prefix");
            Check(!rules.IsDefinitelyExcluded(@"C:\Users\you\file.pyc"), "a rule with a wildcard in a component is not used for pruning");
            Check(!rules.IsDefinitelyExcluded(@"C:\Users\you\keep"), "a ! rule is not used for pruning");
            Check(!rules.IsDefinitelyExcluded(@"C:\a\x\b"), "a * component makes the rule unusable");
            Check(!rules.IsDefinitelyExcluded(@"C:\x\m\y"), "two ** wildcards make the rule unusable");
            Check(!ExclusionRules.None.IsDefinitelyExcluded(@"C:\Users\you\Projects\app\node_modules"), "no rules prune nothing");

            // Measuring leaves an excluded folder out entirely: its size and its online-only files.
            string folder = NewFolder("excluded");
            File.WriteAllBytes(Path.Combine(folder, "kept.txt"), new byte[10]);
            string modules = Path.Combine(folder, "node_modules");
            Directory.CreateDirectory(modules);
            string cached = Path.Combine(modules, "cached.bin");
            File.WriteAllBytes(cached, new byte[500]);
            File.SetAttributes(cached, FileAttributes.Offline);
            FolderTotals last = null;
            FolderMeasurer.Measure(folder, ExclusionRules.Parse(new string[] { "**/node_modules" }), CancellationToken.None,
                delegate(FolderTotals totals, bool done, string error) { if (done) { last = totals; } });
            Check(last != null && last.Files == 1 && last.Bytes == 10 && last.PlaceholderFiles == 0,
                "an excluded folder's size and online-only files are not counted");
            FolderMeasurer.Measure(folder, ExclusionRules.None, CancellationToken.None,
                delegate(FolderTotals totals, bool done, string error) { if (done) { last = totals; } });
            Check(last != null && last.Files == 2 && last.PlaceholderFiles == 1, "without the rule the same folder is counted");
            File.SetAttributes(cached, FileAttributes.Normal);
        }

        // The port gives the engine's answer for the shipped excludes.txt (run with the engine's own Python code).
        private static void ExclusionRuleParity(string project)
        {
            string excludes = Path.Combine(project, "src", "excludes.txt");
            string[] samples = new string[]
            {
                @"C:\Users\you\Projects\web\node_modules", @"C:\Users\you\Projects\py\.venv", @"C:\Users\you\Projects\py\venv",
                @"C:\Users\you\Projects\py\__pycache__", @"D:\work\.gradle\caches", @"D:\work\.gradle", @"C:\Users\you\.cache",
                @"C:\Users\you\Documents", @"C:\Users\you\Projects\app\target", @"C:\Users\you\Projects\site\.next\cache",
                @"C:\Users\you\Projects\site\.next", @"C:\Users\you\coverage", @"C:\Users\you\Pictures\node_modules_photos",
            };
            ExclusionRules rules = ExclusionRules.Parse(File.ReadAllLines(excludes));
            string sampleFile = Path.Combine(NewFolder("parity"), "samples.txt");
            File.WriteAllLines(sampleFile, samples);
            string code = "import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); " +
                "import restic_common as c; r = c._literal_directory_exclusion_rules(Path(sys.argv[2])); " +
                "print(''.join('1' if c._directory_is_definitely_excluded(p, r) else '0' for p in Path(sys.argv[3]).read_text(encoding='utf-8').splitlines()))";
            System.Diagnostics.ProcessStartInfo start = new System.Diagnostics.ProcessStartInfo("python",
                CommandLine.Join(new string[] { "-c", code, Path.Combine(project, "src"), excludes, sampleFile }));
            start.UseShellExecute = false;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            string expected;
            try
            {
                using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(start))
                {
                    expected = process.StandardOutput.ReadToEnd().Trim();
                    string problems = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        Check(false, "the engine's exclusion functions ran: " + problems.Trim());
                        return;
                    }
                }
            }
            catch (System.ComponentModel.Win32Exception)
            {
                Console.WriteLine("    (python is not on PATH: the comparison with the engine runs where it is, as in CI)");
                return;
            }
            StringBuilder actual = new StringBuilder();
            foreach (string sample in samples)
            {
                actual.Append(rules.IsDefinitelyExcluded(sample) ? '1' : '0');
            }
            Equal(expected, actual.ToString(), "the port prunes exactly the folders the engine prunes for the shipped excludes.txt");
        }

        // An elevated run of a script from the unpacked bundle goes through ElevatedBootstrap. Its pieces are checked everywhere;
        // the bootstrap itself runs only when these checks run elevated (CI), against a stub bundle, never a real installer.
        private static void ElevatedBootstrapBehaviour()
        {
            Equal("'it''s'", ElevatedBootstrap.Literal("it's"), "a single quote is doubled");
            Equal("'a\u2019\u2019b'", ElevatedBootstrap.Literal("a\u2019b"), "a typographic single quote is doubled too");

            string folder = Path.Combine(Path.GetTempPath(), "rewindle-bootstrap-" + Guid.NewGuid().ToString("N"));
            string bundle = Path.Combine(folder, "bundle");
            Directory.CreateDirectory(Path.Combine(bundle, "payload"));
            try
            {
                string stub = Path.Combine(bundle, "stub.ps1");
                string result = Path.Combine(folder, "result.txt");
                File.WriteAllText(stub, "param([string]$ProgressPath, [string]$Name)\r\n[IO.File]::WriteAllText('" + result.Replace("'", "''") + "', $Name + '|' + $PSScriptRoot)\r\nexit 7\r\n");
                File.WriteAllText(Path.Combine(bundle, "payload", "data.txt"), "payload");
                Dictionary<string, string> hashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                hashes["stub.ps1"] = ElevatedBootstrap.Sha256(File.ReadAllBytes(stub));
                Func<BundleLaunch> launchFor = delegate
                {
                    BundleLaunch launch = new BundleLaunch();
                    launch.SourceRoot = bundle;
                    launch.StagedItems = new string[] { "stub.ps1", "payload" };
                    launch.CheckedFiles = new string[] { "stub.ps1" };
                    launch.ScriptRelativePath = "stub.ps1";
                    launch.ExpectedSha256 = delegate(string relative) { return hashes[relative]; };
                    return launch;
                };
                Func<string, List<string>> wrap = delegate(string attempt)
                {
                    string progressFolder = Path.Combine(folder, attempt);
                    Directory.CreateDirectory(progressFolder);
                    List<string> plain = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", stub,
                        "-ProgressPath", Path.Combine(progressFolder, "progress.jsonl"), "-Name", "a b;E:\\" };
                    return ElevatedBootstrap.Wrap(plain, launchFor());
                };

                List<string> wrapped = wrap("one");
                Check(wrapped.Count == 6 && wrapped[4] == "-EncodedCommand" && !wrapped.Contains("-File"), "the elevated arguments carry only the encoded bootstrap");
                string script = Encoding.Unicode.GetString(Convert.FromBase64String(wrapped[5]));
                string argumentFile = Path.Combine(folder, "one", ElevatedBootstrap.ArgumentFileName);
                byte[] argumentBytes = File.ReadAllBytes(argumentFile);
                Equal(CommandLine.Join(new string[] { "-ProgressPath", Path.Combine(folder, "one", "progress.jsonl"), "-Name", "a b;E:\\" }),
                    Encoding.UTF8.GetString(argumentBytes), "the argument file holds the script's own arguments as one command line");
                Check(script.Contains(ElevatedBootstrap.Literal(hashes["stub.ps1"])) && script.Contains(ElevatedBootstrap.Literal(ElevatedBootstrap.Sha256(argumentBytes))),
                    "the bootstrap carries the unpacked hash of the script and the hash of the argument file");
                Check(script.Length < 12000, "the bootstrap stays small enough for a command line");

                string scriptFile = Path.Combine(folder, "bootstrap.ps1");
                File.WriteAllText(scriptFile, script);
                Equal("0", RunPowerShell("$e = $null; [void][Management.Automation.Language.Parser]::ParseFile('" + scriptFile.Replace("'", "''") + "', [ref]$null, [ref]$e); $e.Count").Trim(),
                    "the bootstrap is valid PowerShell");

                if (!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))
                {
                    Console.WriteLine("    (not elevated: the bootstrap itself runs only where these checks run as an administrator, as in CI)");
                    return;
                }
                string programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                Func<int> stages = delegate { return Directory.GetDirectories(programData, ElevatedBootstrap.StagingPrefix + "*").Length; };
                int before = stages();

                Equal(7, RunPowerShellExit(wrapped), "the bootstrap runs the staged script and returns its exit code");
                string[] written = File.ReadAllText(result).Split('|');
                Equal("a b;E:\\", written[0], "an argument with a space and a trailing backslash arrives unchanged");
                Check(written[1].StartsWith(Path.Combine(programData, ElevatedBootstrap.StagingPrefix), StringComparison.OrdinalIgnoreCase),
                    "the script ran from the protected folder, not from the bundle");
                Equal(before, stages(), "the protected folder is removed afterwards");

                File.Delete(result);
                List<string> tamperedRun = wrap("two");
                File.AppendAllText(stub, "\r\n# changed after unpacking\r\n");
                Equal(ElevatedBootstrap.BootstrapRefused, RunPowerShellExit(tamperedRun), "a script changed after unpacking is refused");
                Check(!File.Exists(result), "and nothing of it ran");
                Equal(before, stages(), "and the protected folder is removed");

                // Folders an interrupted run left behind: one over a day old is removed by the next run, a recent one is not.
                string stale = Path.Combine(programData, ElevatedBootstrap.StagingPrefix + Guid.NewGuid().ToString("N"));
                string recent = Path.Combine(programData, ElevatedBootstrap.StagingPrefix + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(Path.Combine(stale, "payload"));
                Directory.CreateDirectory(recent);
                Directory.SetCreationTimeUtc(stale, DateTime.UtcNow.AddDays(-2));
                File.Delete(stub);
                File.WriteAllText(stub, "param([string]$ProgressPath, [string]$Name)\r\n[IO.File]::WriteAllText('" + result.Replace("'", "''") + "', $Name + '|' + $PSScriptRoot)\r\nexit 7\r\n");
                hashes["stub.ps1"] = ElevatedBootstrap.Sha256(File.ReadAllBytes(stub));
                try
                {
                    Equal(7, RunPowerShellExit(wrap("three")), "a later run still works");
                    Check(!Directory.Exists(stale), "and removes a protected folder an interrupted run left over a day ago");
                    Check(Directory.Exists(recent), "but not a recent one, which may belong to a run in progress");
                }
                finally
                {
                    try { Directory.Delete(stale, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                    try { Directory.Delete(recent, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
                }
            }
            finally
            {
                try { Directory.Delete(folder, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }

        private static string RunPowerShell(string command)
        {
            System.Diagnostics.ProcessStartInfo start = new System.Diagnostics.ProcessStartInfo(PlanRunner.WindowsPowerShellPath(),
                CommandLine.Join(new string[] { "-NoProfile", "-NonInteractive", "-Command", command }));
            start.UseShellExecute = false;
            start.RedirectStandardOutput = true;
            using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(start))
            {
                string output = process.StandardOutput.ReadToEnd();
                process.WaitForExit();
                return output;
            }
        }

        private static int RunPowerShellExit(IList<string> arguments)
        {
            System.Diagnostics.ProcessStartInfo start = new System.Diagnostics.ProcessStartInfo(PlanRunner.WindowsPowerShellPath(), CommandLine.Join(arguments));
            start.UseShellExecute = false;
            using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(start))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }

        // An uninstaller from an earlier release has no -ProgressPath; setup then uses its own bundled copy.
        private static void UninstallerCompatibility()
        {
            string folder = Path.Combine(Path.GetTempPath(), "rewindle-setup-uninstaller-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            try
            {
                string current = Path.Combine(folder, "current.ps1");
                File.WriteAllText(current, "[CmdletBinding()]\r\nparam(\r\n    [switch]$Unattended,\r\n    [string]$ExpectedUserSid,\r\n\r\n    [string]$ProgressPath\r\n)\r\n$schema = 'Rewindle.InstallProgress.v1'\r\n");
                string otherFeed = Path.Combine(folder, "other-feed.ps1");
                File.WriteAllText(otherFeed, "param([string]$ProgressPath)\r\n$schema = 'Rewindle.InstallProgress.v2'\r\n");
                string released = Path.Combine(folder, "released.ps1");
                File.WriteAllText(released, "[CmdletBinding()]\r\nparam(\r\n    [switch]$Unattended,\r\n    [string]$ExpectedUserSid\r\n)\r\n# mentions $ProgressPath only in a comment\r\n");
                Check(SetupBridge.SupportsProgressFeed(current), "an uninstaller that declares -ProgressPath speaks the progress contract");
                Check(!SetupBridge.SupportsProgressFeed(released), "the 0.2.0-alpha.1 uninstaller (no -ProgressPath parameter) does not");
                Check(!SetupBridge.SupportsProgressFeed(otherFeed), "an uninstaller with -ProgressPath that writes another progress schema does not");
                Check(!SetupBridge.SupportsProgressFeed(Path.Combine(folder, "missing.ps1")), "a missing uninstaller does not");
            }
            finally
            {
                Directory.Delete(folder, true);
            }
        }

        private static void Run(string name, Action body)
        {
            Console.WriteLine(name);
            try
            {
                body();
            }
            catch (Exception error)
            {
                failures.Add(name + ": threw " + error.GetType().Name + ": " + error.Message);
                Console.WriteLine("  threw " + error);
            }
        }

        private static void Cleanup()
        {
            try
            {
                foreach (string file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
                {
                    try { File.SetAttributes(file, FileAttributes.Normal); } catch (Exception) { }
                }
                Directory.Delete(root, true);
            }
            catch (Exception error)
            {
                Console.WriteLine("  (could not remove " + root + ": " + error.Message + ")");
            }
        }

        // ---- assertions ----------------------------------------------------------------------------------------------------

        internal static void Check(bool condition, string what)
        {
            if (condition)
            {
                passed++;
                return;
            }
            failures.Add(what);
            Console.WriteLine("  FAILED: " + what);
        }

        internal static void Equal<T>(T expected, T actual, string what)
        {
            bool same = EqualityComparer<T>.Default.Equals(expected, actual);
            Check(same, what + (same ? string.Empty : " (expected <" + expected + ">, got <" + actual + ">)"));
        }

        internal static void SequenceEqual(IEnumerable<string> expected, IEnumerable<string> actual, string what)
        {
            string[] a = expected.ToArray();
            string[] b = actual.ToArray();
            bool same = a.Length == b.Length && a.Zip(b, (x, y) => x == y).All(item => item);
            Check(same, what + (same ? string.Empty : " (expected [" + string.Join(" | ", a) + "], got [" + string.Join(" | ", b) + "])"));
        }

        internal static void Throws<T>(Action body, string what) where T : Exception
        {
            try
            {
                body();
            }
            catch (T)
            {
                Check(true, what);
                return;
            }
            catch (Exception other)
            {
                Check(false, what + " (threw " + other.GetType().Name + " instead of " + typeof(T).Name + ")");
                return;
            }
            Check(false, what + " (did not throw)");
        }

        internal static bool WaitFor(Func<bool> condition, int milliseconds)
        {
            DateTime until = DateTime.UtcNow.AddMilliseconds(milliseconds);
            while (DateTime.UtcNow < until)
            {
                if (condition())
                {
                    return true;
                }
                Thread.Sleep(20);
            }
            return condition();
        }

        internal static string NewFolder(string name)
        {
            string path = Path.Combine(root, name + "-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(path);
            return path;
        }

        // ---- command lines -------------------------------------------------------------------------------------------------

        [DllImport("shell32.dll", SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int count);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        private static string[] ParseCommandLine(string commandLine)
        {
            int count;
            IntPtr pointer = CommandLineToArgvW(commandLine, out count);
            try
            {
                string[] result = new string[count];
                for (int index = 0; index < count; index++)
                {
                    result[index] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, index * IntPtr.Size));
                }
                return result;
            }
            finally
            {
                LocalFree(pointer);
            }
        }

        private static void CommandLineRoundTrip()
        {
            string[] samples =
            {
                @"C:\Users\you\Documents",
                @"D:\Rewindle Backups",
                @"E:\",
                @"E:\folder with space\",
                @"C:\a\\b c\",
                "C:\\say \"hello\"",
                @"C:\ends with two\\",
                string.Empty,
                "x;y;z",
                @"C:\Tom & Jerry's $env:PATH %TEMP% ^caret",
                "C:\\\u65E5\u672C\u8A9E folder",
                "tab\there",
            };
            string[] parsed = ParseCommandLine("program.exe " + CommandLine.Join(samples));
            SequenceEqual(new string[] { "program.exe" }.Concat(samples), parsed, "quoting round-trips through CommandLineToArgvW");
            Throws<ArgumentException>(() => CommandLine.Quote("a\0b"), "a NUL character is refused");
        }

        // ---- the contract ----------------------------------------------------------------------------------------------------

        private static IDictionary<string, object> Obj(string json)
        {
            return Json.AsObject(Json.Parse(json));
        }

        private static void PathsAndInputs()
        {
            foreach (string good in new string[] { @"C:\Users\you", @"E:\Rewindle Backups", @"D:\", @"G:\My Drive\Rewindle Backups", @"c:\lower\case" })
            {
                Check(InstallerContract.IsAcceptablePath(good), "acceptable: " + good);
            }
            string[] bad =
            {
                string.Empty, @"\\server\share\folder", "C:", "C:folder", @"C:\a\..\b", @"C:\a\.\b", "C:\\a\"b", @"C:\a|b", @"C:\a?b",
                @"C:\a*b", @"C:\a<b", @"C:\a:stream", "C:\\line\nbreak", "relative\\path", @"\\?\C:\x", "C:\\" + new string('x', 1100),
            };
            foreach (string path in bad)
            {
                Check(!InstallerContract.IsAcceptablePath(path), "refused: " + (path.Length > 40 ? path.Substring(0, 40) + "…" : path));
            }
            Check(!InstallerContract.IsAcceptablePath(null), "refused: null");

            Check(InstallerContract.IsAcceptableSchedule("02:00") && InstallerContract.IsAcceptableSchedule("23:59") && InstallerContract.IsAcceptableSchedule("00:00"), "valid times");
            Check(!InstallerContract.IsAcceptableSchedule("24:00") && !InstallerContract.IsAcceptableSchedule("2:00") && !InstallerContract.IsAcceptableSchedule("12:60") &&
                  !InstallerContract.IsAcceptableSchedule("12:00 AM") && !InstallerContract.IsAcceptableSchedule(null), "invalid times");

            InstallerInputs inputs;
            string error;
            Check(InstallerContract.TryReadInputs(null, false, out inputs, out error), "no inputs is fine for a plan");
            Check(!InstallerContract.TryReadInputs(null, true, out inputs, out error), "no inputs is not fine for an install");

            IDictionary<string, object> full = Obj(@"{""repository"":""E:\\Rewindle Backups"",""storageMode"":""local_ntfs"",""sources"":[""C:\\Users\\you\\Desktop"",""C:\\Users\\you\\Documents""],""schedule"":""03:30"",""vss"":false,""startBackup"":true}");
            Check(InstallerContract.TryReadInputs(full, true, out inputs, out error), "full choices are read: " + error);
            Equal(@"E:\Rewindle Backups", inputs.Repository, "repository");
            Equal(2, inputs.Sources.Count, "two sources");
            Equal("03:30", inputs.Schedule, "schedule");
            Check(!inputs.Vss && inputs.StartBackup, "vss off, first backup on");

            Check(InstallerContract.TryReadInputs(Obj(@"{""repository"":"""",""sources"":[]}"), false, out inputs, out error) && inputs.Repository == null && inputs.Sources.Count == 0,
                "an empty repository and no sources are left out of a plan request");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""repository"":""D:\\ok"",""sources"":[""C:\\a;b""]}"), false, out inputs, out error), "a semicolon in a folder name is refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""storageMode"":""nfs""}"), false, out inputs, out error), "unknown storage mode refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""schedule"":""25:00""}"), false, out inputs, out error), "invalid schedule refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""repository"":""\\\\host\\share""}"), false, out inputs, out error), "a network repository is refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""repository"":5}"), false, out inputs, out error), "a repository that is not text is refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""vss"":""yes""}"), false, out inputs, out error), "vss that is not a boolean is refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""storageMode"":""local_ntfs"",""driveFsMyDriveRoot"":""G:\\My Drive""}"), false, out inputs, out error),
                "a Google Drive root with a local drive is refused");
            Check(InstallerContract.TryReadInputs(Obj(@"{""storageMode"":""google_drivefs_stream"",""driveFsMyDriveRoot"":""G:\\My Drive"",""repository"":""G:\\My Drive\\Backups""}"), false, out inputs, out error),
                "a Google Drive choice is read");
            string manySources = "[" + string.Join(",", Enumerable.Range(0, 65).Select(n => "\"C:\\\\f" + n + "\"")) + "]";
            Check(!InstallerContract.TryReadInputs(Obj("{\"sources\":" + manySources + "}"), false, out inputs, out error), "more than 64 folders refused");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""repository"":""E:\\b"",""sources"":[],""schedule"":""02:00""}"), true, out inputs, out error), "an install needs a folder");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""sources"":[""C:\\a""],""schedule"":""02:00""}"), true, out inputs, out error), "an install needs a repository");
            Check(!InstallerContract.TryReadInputs(Obj(@"{""repository"":""E:\\b"",""sources"":[""C:\\a""]}"), true, out inputs, out error), "an install needs a schedule");
        }

        private static void InstallerArguments()
        {
            // Folders whose paths are too long together are refused: one -SourceList over Windows' command-line limit can't start.
            List<string> longPaths = new List<string>();
            for (int index = 0; index < 20; index++)
            {
                longPaths.Add("\"C:\\\\" + new string('a', 900) + index + "\"");
            }
            InstallerInputs tooLong;
            string tooLongError;
            Check(!InstallerContract.TryReadInputs(Obj("{\"sources\":[" + string.Join(",", longPaths.ToArray()) + "]}"), false, out tooLong, out tooLongError) &&
                tooLongError.Contains("too long"), "folders whose paths are too long together are refused");

            InstallerInputs inputs = new InstallerInputs();
            inputs.Repository = @"E:\Rewindle Backups";
            inputs.Sources.Add(@"C:\Users\you\Desktop");
            inputs.Sources.Add(@"C:\Users\you\Documents");
            inputs.Schedule = "02:00";
            inputs.Vss = true;

            SequenceEqual(
                new string[]
                {
                    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", @"C:\t\Install-ResticBackuper.ps1", "-PlanOnly", "-PlanOutput",
                    @"C:\t\plan.json", "-Repository", @"E:\Rewindle Backups", "-RepositoryStorageMode", "local_ntfs", "-SourceList",
                    @"C:\Users\you\Desktop;C:\Users\you\Documents", "-Schedule", "02:00"
                },
                InstallerContract.PlanArguments(@"C:\t\Install-ResticBackuper.ps1", @"C:\t\plan.json", inputs),
                "plan arguments");

            inputs.Vss = false;
            inputs.StartBackup = true;
            List<string> install = InstallerContract.InstallArguments(@"C:\t\Install-ResticBackuper.ps1", "S-1-5-21-1-2-3-1001", @"C:\t\progress.jsonl", inputs);
            SequenceEqual(
                new string[]
                {
                    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", @"C:\t\Install-ResticBackuper.ps1", "-Unattended", "-ExpectedUserSid",
                    "S-1-5-21-1-2-3-1001", "-ProgressPath", @"C:\t\progress.jsonl", "-Repository", @"E:\Rewindle Backups", "-RepositoryStorageMode", "local_ntfs",
                    "-SourceList", @"C:\Users\you\Desktop;C:\Users\you\Documents", "-Schedule", "02:00", "-DisableVss", "-StartBackup"
                },
                install,
                "install arguments, open files off and a first backup");
            Check(!install.Contains("-PlanOnly"), "an install never carries -PlanOnly");

            inputs.StorageMode = InstallerContract.StorageDriveFs;
            inputs.DriveFsMyDriveRoot = @"G:\My Drive";
            Check(InstallerContract.PlanArguments("s.ps1", "p.json", inputs).Contains("-DriveFsMyDriveRoot"), "the Google Drive root is passed");

            SequenceEqual(
                new string[]
                {
                    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", @"C:\t\Uninstall-ResticBackuper.ps1", "-Unattended", "-ExpectedUserSid",
                    "S-1-5-21-1-2-3-1001", "-ProgressPath", @"C:\t\progress.jsonl"
                },
                InstallerContract.UninstallArguments(@"C:\t\Uninstall-ResticBackuper.ps1", "S-1-5-21-1-2-3-1001", @"C:\t\progress.jsonl"),
                "uninstall arguments");
        }

        private static void PlanAndProgressLines()
        {
            IDictionary<string, object> plan;
            string error;
            Check(InstallerContract.TryReadPlan("\uFEFF{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":true,\"errors\":[]}", out plan, out error) && InstallerContract.PlanAllowsInstall(plan),
                "a plan with a byte-order mark is read, and allows the install");
            Check(InstallerContract.TryReadPlan("{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":true,\"errors\":[{\"code\":\"x\"}]}", out plan, out error) && !InstallerContract.PlanAllowsInstall(plan),
                "a plan with an error does not allow it, whatever its flag says");
            Check(InstallerContract.TryReadPlan("{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":false,\"errors\":[]}", out plan, out error) && !InstallerContract.PlanAllowsInstall(plan),
                "ok:false does not allow it");
            Check(!InstallerContract.TryReadPlan("{\"schema\":\"Other.v9\"}", out plan, out error), "another schema is refused");
            Check(!InstallerContract.TryReadPlan("not json", out plan, out error), "text that is not JSON is refused");
            Check(!InstallerContract.TryReadPlan("[1,2]", out plan, out error), "an array is refused");
            Check(!InstallerContract.TryReadPlan("   ", out plan, out error), "an empty plan is refused");

            ProgressLine phase = InstallerContract.ReadProgressLine("{\"schema\":\"Rewindle.InstallProgress.v1\",\"seq\":1,\"type\":\"phase\",\"phase\":\"payload\",\"state\":\"started\"}");
            Check(phase.Fields != null && !phase.IsResult, "a phase line is an object, not a result");
            ProgressLine ok = InstallerContract.ReadProgressLine("{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null,\"recovery_key_path\":\"C:\\\\Users\\\\you\\\\key.txt\",\"recovery_key_readable_by_user\":true,\"dashboard_executable\":\"C:\\\\Program Files\\\\ResticBackuper\\\\ResticBackuperDashboard.exe\",\"install_root\":\"C:\\\\Program Files\\\\ResticBackuper\"}");
            Check(ok.IsResult && ok.ResultOk && ok.RecoveryKeyReadableByUser == true && ok.RecoveryKeyPath == @"C:\Users\you\key.txt", "a successful result line");
            ProgressLine failed = InstallerContract.ReadProgressLine("{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":false,\"error\":{\"code\":\"x\",\"message\":\"It broke.\"}}");
            Check(failed.IsResult && !failed.ResultOk && failed.ResultErrorMessage == "It broke.", "a failed result line");
            ProgressLine unknown = InstallerContract.ReadProgressLine("{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null,\"recovery_key_path\":\"C:\\\\k.txt\",\"recovery_key_readable_by_user\":null}");
            Check(unknown.ResultOk && unknown.RecoveryKeyReadableByUser == null, "a readable-by-user answer of null stays unknown, not false");
            Check(!InstallerContract.ReadProgressLine("{\"type\":\"result\",\"ok\":true,\"error\":null}").IsResult, "a result line without the progress schema decides nothing");
            Check(!InstallerContract.ReadProgressLine("{\"schema\":\"Rewindle.InstallProgress.v2\",\"type\":\"result\",\"ok\":true,\"error\":null}").IsResult, "a result line in an unknown schema decides nothing");
            ProgressLine contradictory = InstallerContract.ReadProgressLine("{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":{\"code\":\"x\",\"message\":\"no\"}}");
            Check(!contradictory.ResultOk, "ok:true with an error object is a failure");
            ProgressLine junk = InstallerContract.ReadProgressLine("WARNING: something printed text into the file");
            Check(junk.Fields == null && !junk.IsResult && junk.Raw.StartsWith("WARNING"), "a line that is not JSON is kept as text");
        }

        // ---- the progress file ---------------------------------------------------------------------------------------------

        private static void ProgressTailBehaviour()
        {
            string folder = NewFolder("tail");
            string path = Path.Combine(folder, "progress.jsonl");
            ProgressTail tail = new ProgressTail(path);
            Equal(0, tail.ReadNewLines().Count, "no file yet: nothing, and no error");

            File.WriteAllBytes(path, new byte[0]);
            Equal(0, tail.ReadNewLines().Count, "an empty file");

            // The byte-order mark, a CR LF line end and a line still being written.
            using (FileStream stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            {
                byte[] first = Encoding.UTF8.GetPreamble().Concat(Encoding.UTF8.GetBytes("{\"a\":1}\r\n{\"b\":")).ToArray();
                stream.Write(first, 0, first.Length);
                stream.Flush();
                SequenceEqual(new string[] { "{\"a\":1}" }, tail.ReadNewLines(), "only the whole line is returned (BOM and CR LF removed)");
                byte[] second = Encoding.UTF8.GetBytes("2}\n\n   \n{\"c\":3}\n");
                stream.Write(second, 0, second.Length);
                stream.Flush();
                SequenceEqual(new string[] { "{\"b\":2}", "{\"c\":3}" }, tail.ReadNewLines(), "the rest of the line arrives; blank lines are skipped");
                Equal(0, tail.ReadNewLines().Count, "nothing new");

                // A multi-byte character split across two reads.
                byte[] euro = Encoding.UTF8.GetBytes("{\"d\":\"\u20AC\"}\n");
                stream.Write(euro, 0, 8);
                stream.Flush();
                Equal(0, tail.ReadNewLines().Count, "half a line, in the middle of a character");
                stream.Write(euro, 8, euro.Length - 8);
                stream.Flush();
                SequenceEqual(new string[] { "{\"d\":\"\u20AC\"}" }, tail.ReadNewLines(), "the character is whole once the line is");

                // The last line has no newline: it is returned by Finish, not before.
                byte[] last = Encoding.UTF8.GetBytes("{\"e\":5}");
                stream.Write(last, 0, last.Length);
                stream.Flush();
                Equal(0, tail.ReadNewLines().Count, "an unterminated last line waits");
                SequenceEqual(new string[] { "{\"e\":5}" }, tail.Finish(), "and Finish returns it");
            }

            // A line far longer than any progress line is dropped, and the lines after it still count.
            string longPath = Path.Combine(folder, "long.jsonl");
            File.WriteAllText(longPath, new string('x', InstallerContract.MaximumProgressLineBytes + 10) + "\n{\"ok\":1}\n");
            SequenceEqual(new string[] { "{\"ok\":1}" }, new ProgressTail(longPath).ReadNewLines(), "an oversized line is dropped");

            // The file is replaced by a shorter one.
            string shrinkPath = Path.Combine(folder, "shrink.jsonl");
            File.WriteAllText(shrinkPath, "{\"one\":1}\n{\"two\":2}\n");
            ProgressTail shrinking = new ProgressTail(shrinkPath);
            Equal(2, shrinking.ReadNewLines().Count, "two lines first");
            File.WriteAllText(shrinkPath, "{\"x\":9}\n");
            SequenceEqual(new string[] { "{\"x\":9}" }, shrinking.ReadNewLines(), "a replaced, shorter file is read from its start");

            // Read while another process holds the file open for writing.
            string heldPath = Path.Combine(folder, "held.jsonl");
            using (FileStream writer = new FileStream(heldPath, FileMode.Create, FileAccess.Write, FileShare.Read))
            {
                byte[] bytes = Encoding.UTF8.GetBytes("{\"held\":true}\n");
                writer.Write(bytes, 0, bytes.Length);
                writer.Flush();
                SequenceEqual(new string[] { "{\"held\":true}" }, new ProgressTail(heldPath).ReadNewLines(), "a file the writer still has open is readable");
            }
        }

        // ---- ZIP and workspace ---------------------------------------------------------------------------------------------

        private static MemoryStream Zip(params string[] names)
        {
            MemoryStream stream = new MemoryStream();
            using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Create, true))
            {
                foreach (string name in names)
                {
                    ZipArchiveEntry entry = archive.CreateEntry(name);
                    if (!name.EndsWith("/"))
                    {
                        using (StreamWriter writer = new StreamWriter(entry.Open()))
                        {
                            writer.Write("content of " + name);
                        }
                    }
                }
            }
            stream.Position = 0;
            return stream;
        }

        private static void SafeZipBehaviour()
        {
            string target = NewFolder("zip");
            SafeZip.Extract(Zip("setup.html", "assets/app.js", "assets/deep/er/file.txt", "empty/"), target);
            Check(File.Exists(Path.Combine(target, "setup.html")) && File.Exists(Path.Combine(target, "assets", "deep", "er", "file.txt")) &&
                  Directory.Exists(Path.Combine(target, "empty")), "a normal archive is unpacked");

            foreach (string unsafeName in new string[] { "../evil.txt", "a/../../evil.txt", "/rooted.txt", "C:/drive.txt", "a/b:stream.txt", "..\\evil.txt" })
            {
                string place = NewFolder("zipbad");
                Throws<InvalidDataException>(() => SafeZip.Extract(Zip("fine.txt", unsafeName), place), "refused: " + unsafeName);
                Check(!File.Exists(Path.Combine(Path.GetDirectoryName(place), "evil.txt")), "nothing was written outside for " + unsafeName);
            }
            Throws<InvalidDataException>(() => SafeZip.Extract(Zip("a.txt", "A.TXT"), NewFolder("zipdup")), "names that differ only by case are refused");
        }

        private static void WorkspaceBehaviour()
        {
            string parent = NewFolder("workspace");
            Dictionary<string, byte[]> resources = new Dictionary<string, byte[]>();
            resources[SetupWorkspace.BundleResource] = Zip("Install-ResticBackuper.ps1", "payload/Uninstall-ResticBackuper.ps1", "payload/restic.exe").ToArray();
            resources[SetupWorkspace.WebResource] = Zip("setup.html", "assets/a.js").ToArray();
            foreach (string[] library in SetupWorkspace.WebViewLibraries)
            {
                resources[library[0]] = Encoding.ASCII.GetBytes("library " + library[1]);
            }
            Func<string, Stream> open = delegate(string name)
            {
                byte[] bytes;
                return resources.TryGetValue(name, out bytes) ? new MemoryStream(bytes) : null;
            };

            string rootPath;
            string progress;
            using (SetupWorkspace workspace = new SetupWorkspace(open, parent))
            {
                rootPath = workspace.Root;
                Check(Path.GetFileName(rootPath).StartsWith("RewindleSetup-") && Path.GetFileName(rootPath).Length == "RewindleSetup-".Length + 32, "the folder is named RewindleSetup-<guid>");
                workspace.ExtractLibraries();
                workspace.ExtractWeb();
                workspace.EnsureBundleExtracted().Wait();
                Check(File.Exists(Path.Combine(workspace.LibraryFolder, "WebView2Loader.dll")) && File.Exists(Path.Combine(workspace.LibraryFolder, "x64", "WebView2Loader.dll")) &&
                      File.Exists(Path.Combine(workspace.LibraryFolder, "runtimes", "win-x64", "native", "WebView2Loader.dll")) &&
                      File.Exists(Path.Combine(workspace.LibraryFolder, "Microsoft.Web.WebView2.Wpf.dll")), "the WebView2 libraries are unpacked, the loader in each layout");
                Check(File.Exists(workspace.InstallScriptPath) && File.Exists(workspace.BundledUninstallScriptPath) && File.Exists(Path.Combine(workspace.WebFolder, "setup.html")), "the bundle and the web files are unpacked");
                Check(object.ReferenceEquals(workspace.EnsureBundleExtracted(), workspace.EnsureBundleExtracted()), "the bundle is unpacked once");
                progress = workspace.CreateProgressFolder();
                Check(Directory.Exists(progress) && Path.GetFileName(progress).StartsWith("RewindleSetup-") && progress != rootPath, "a progress folder of its own, named the same way");
            }
            Check(!Directory.Exists(rootPath) && !Directory.Exists(progress), "everything is removed when the workspace is disposed");

            // A broken bundle: the failure is reported and a second try starts again.
            resources[SetupWorkspace.BundleResource] = Zip("something-else.txt").ToArray();
            using (SetupWorkspace broken = new SetupWorkspace(open, parent))
            {
                bool failed = false;
                try { broken.EnsureBundleExtracted().Wait(); } catch (AggregateException) { failed = true; }
                Check(failed, "a bundle without the installer script fails");
                resources[SetupWorkspace.BundleResource] = Zip("Install-ResticBackuper.ps1").ToArray();
                broken.EnsureBundleExtracted().Wait();
                Check(File.Exists(broken.InstallScriptPath), "and unpacking is retried from scratch");
            }

            // Stale folders: only exactly-named, old ones go.
            string stale = Path.Combine(parent, "RewindleSetup-" + new string('a', 32));
            string recent = Path.Combine(parent, "RewindleSetup-" + new string('b', 32));
            string lookalike = Path.Combine(parent, "RewindleSetup-notaguid");
            foreach (string folder in new string[] { stale, recent, lookalike })
            {
                Directory.CreateDirectory(folder);
                File.WriteAllText(Path.Combine(folder, "x.txt"), "x");
            }
            Directory.SetLastWriteTimeUtc(stale, DateTime.UtcNow.AddDays(-2));
            Directory.SetLastWriteTimeUtc(lookalike, DateTime.UtcNow.AddDays(-2));
            SetupWorkspace.SweepStale(parent);
            Check(!Directory.Exists(stale) && Directory.Exists(recent) && Directory.Exists(lookalike), "the sweep removes an old, exactly-named folder and nothing else");
        }

        // ---- folder sizes --------------------------------------------------------------------------------------------------

        private static void FolderMeasurement()
        {
            string folder = NewFolder("measure");
            string outer = NewFolder("outside");
            File.WriteAllBytes(Path.Combine(folder, "a.txt"), new byte[10]);
            Directory.CreateDirectory(Path.Combine(folder, "sub", "deeper"));
            File.WriteAllBytes(Path.Combine(folder, "sub", "b.txt"), new byte[20]);
            File.WriteAllBytes(Path.Combine(folder, "sub", "deeper", "c.txt"), new byte[30]);
            File.WriteAllBytes(Path.Combine(outer, "huge.bin"), new byte[5000]);

            FolderTotals last = null;
            bool done = false;
            string error = "unset";
            Action<FolderTotals, bool, string> collect = delegate(FolderTotals totals, bool finished, string problem)
            {
                last = totals;
                done = finished;
                error = problem;
            };

            FolderMeasurer.Measure(folder, CancellationToken.None, collect);
            Check(done && error == null && last.Files == 3 && last.Bytes == 60 && last.SkippedFolders == 0 && last.PlaceholderFiles == 0,
                "a plain tree: 3 files, 60 bytes (got " + (last == null ? "nothing" : last.Files + " files, " + last.Bytes + " bytes") + ")");

            // A junction to a folder with a big file is not followed.
            string junction = Path.Combine(folder, "link");
            System.Diagnostics.ProcessStartInfo link = new System.Diagnostics.ProcessStartInfo("cmd.exe", "/c mklink /J " + CommandLine.Quote(junction) + " " + CommandLine.Quote(outer));
            link.CreateNoWindow = true;
            link.UseShellExecute = false;
            link.RedirectStandardOutput = true;
            using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(link))
            {
                process.StandardOutput.ReadToEnd();
                process.WaitForExit();
            }
            if (Directory.Exists(junction))
            {
                FolderMeasurer.Measure(folder, CancellationToken.None, collect);
                Check(done && last.Files == 3 && last.Bytes == 60, "a junction is not followed (the big file behind it is not counted)");
                Directory.Delete(junction);
            }
            else
            {
                Check(false, "the test could not make a junction");
            }

            // A file that is only in the cloud (the offline attribute stands in for the recall flags).
            string cloud = Path.Combine(folder, "cloud-only.docx");
            File.WriteAllBytes(cloud, new byte[100]);
            File.SetAttributes(cloud, FileAttributes.Offline);
            FolderMeasurer.Measure(folder, CancellationToken.None, collect);
            Check(last.Files == 4 && last.PlaceholderFiles == 1 && last.PlaceholderBytes == 100 && last.Bytes == 160, "cloud-only files are counted and told apart");
            File.SetAttributes(cloud, FileAttributes.Normal);
            File.Delete(cloud);

            // A folder that is only in the cloud counts as online-only too, as in the engine's preflight, which classifies every
            // entry before it decides not to walk a folder.
            string cloudFolder = Path.Combine(folder, "cloud-folder");
            Directory.CreateDirectory(cloudFolder);
            DirectoryInfo cloudFolderInfo = new DirectoryInfo(cloudFolder);
            cloudFolderInfo.Attributes = FileAttributes.Directory | FileAttributes.Offline;
            FolderMeasurer.Measure(folder, CancellationToken.None, collect);
            Check(last.Files == 3 && last.PlaceholderFiles == 1, "an online-only folder is counted as online-only");
            cloudFolderInfo.Attributes = FileAttributes.Directory;
            Directory.Delete(cloudFolder);

            // A folder that cannot be opened is skipped and counted, and the rest is still measured.
            string denied = Path.Combine(folder, "denied");
            Directory.CreateDirectory(denied);
            File.WriteAllBytes(Path.Combine(denied, "secret.txt"), new byte[7]);
            DirectoryInfo deniedInfo = new DirectoryInfo(denied);
            SecurityIdentifier me = WindowsIdentity.GetCurrent().User;
            FileSystemAccessRule rule = new FileSystemAccessRule(me, FileSystemRights.ListDirectory | FileSystemRights.ReadData, AccessControlType.Deny);
            DirectorySecurity security = deniedInfo.GetAccessControl();
            security.AddAccessRule(rule);
            deniedInfo.SetAccessControl(security);
            try
            {
                FolderMeasurer.Measure(folder, CancellationToken.None, collect);
                Check(done && last.SkippedFolders == 1 && last.Files == 3 && last.Bytes == 60, "an unreadable folder is skipped and counted (skipped " + last.SkippedFolders + ", files " + last.Files + ")");
            }
            finally
            {
                security = deniedInfo.GetAccessControl();
                security.RemoveAccessRule(rule);
                deniedInfo.SetAccessControl(security);
            }

            // A missing folder, and a cancelled walk.
            FolderMeasurer.Measure(Path.Combine(folder, "nope"), CancellationToken.None, collect);
            Check(done && error != null && last.Files == 0, "a missing folder says so");
            done = false;
            CancellationTokenSource cancelled = new CancellationTokenSource();
            cancelled.Cancel();
            FolderMeasurer.Measure(folder, cancelled.Token, collect);
            Check(!done, "a cancelled walk does not report as finished");

            // Partial totals stream while a bigger tree is walked.
            string big = NewFolder("big");
            for (int index = 0; index < 40; index++)
            {
                string sub = Path.Combine(big, "d" + index);
                Directory.CreateDirectory(sub);
                for (int file = 0; file < 25; file++)
                {
                    File.WriteAllBytes(Path.Combine(sub, "f" + file), new byte[1]);
                }
            }
            int reports = 0;
            FolderMeasurer.Measure(big, CancellationToken.None, delegate(FolderTotals totals, bool finished, string problem)
            {
                reports++;
                last = totals;
                done = finished;
            });
            Check(done && last.Files == 1000 && reports >= 1, "a thousand files are counted");
        }

        // ---- plan mode, with a stub in place of the installer ------------------------------------------------------------

        private static string WriteStub(string folder)
        {
            string script = Path.Combine(folder, "Install-ResticBackuper.ps1");
            File.WriteAllText(script, @"
param([switch]$PlanOnly, [string]$PlanOutput, [string]$Repository, [string]$RepositoryStorageMode, [string]$DriveFsMyDriveRoot,
      [string]$SourceList, [string]$Schedule, [switch]$DisableVss)
$mode = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mode.txt') -Raw).Trim()
$received = [ordered]@{ plan_only = [bool]$PlanOnly; repository = $Repository; mode = $RepositoryStorageMode; drivefs = $DriveFsMyDriveRoot;
    sources = $SourceList; schedule = $Schedule; disable_vss = [bool]$DisableVss }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'received.json'), ($received | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
switch ($mode) {
    'ok' { [IO.File]::WriteAllText($PlanOutput, '{""schema"":""Rewindle.InstallPlan.v1"",""ok"":true,""errors"":[],""warnings"":[]}', [Text.UTF8Encoding]::new($true)); exit 0 }
    'nofile' { exit 3 }
    'badjson' { [IO.File]::WriteAllText($PlanOutput, 'this is not json'); exit 0 }
    'otherschema' { [IO.File]::WriteAllText($PlanOutput, '{""schema"":""Something.Else.v1""}'); exit 0 }
    'sleep' { Start-Sleep -Seconds 60; exit 0 }
    'nap' { Start-Sleep -Seconds 5; [IO.File]::WriteAllText($PlanOutput, '{""schema"":""Rewindle.InstallPlan.v1"",""ok"":true,""errors"":[],""warnings"":[]}', [Text.UTF8Encoding]::new($true)); exit 0 }
}
", new UTF8Encoding(true));
            return script;
        }

        private static void PlanRunnerBehaviour()
        {
            string folder = NewFolder("stub");
            string script = WriteStub(folder);
            string modeFile = Path.Combine(folder, "mode.txt");
            PlanRunner runner = new PlanRunner(script, Path.Combine(folder, "plans"), TimeSpan.FromSeconds(60));
            InstallerInputs inputs = new InstallerInputs();
            inputs.Repository = @"E:\";
            inputs.Sources.Add(@"C:\Users\you\Tom & Jerry's $env:PATH %TEMP%");
            inputs.Sources.Add(@"D:\Photo Archive\");
            inputs.Schedule = "04:15";
            inputs.Vss = false;

            File.WriteAllText(modeFile, "ok");
            IDictionary<string, object> plan = runner.GetPlan(inputs, CancellationToken.None);
            Check(plan != null && Json.Bool(plan, "ok") == true, "the stub's plan is returned");
            IDictionary<string, object> received = Obj(File.ReadAllText(Path.Combine(folder, "received.json")));
            Check(Json.Bool(received, "plan_only") == true, "the script got -PlanOnly");
            Equal(@"E:\", Json.String(received, "repository", 4096), "a repository that is a drive root arrives whole");
            Equal(@"C:\Users\you\Tom & Jerry's $env:PATH %TEMP%;D:\Photo Archive\", Json.String(received, "sources", 4096), "folders with spaces, & ' $ % and a trailing backslash arrive exactly");
            Equal("04:15", Json.String(received, "schedule", 64), "the schedule");
            Check(Json.Bool(received, "disable_vss") == true, "-DisableVss");
            Equal("local_ntfs", Json.String(received, "mode", 64), "the storage mode");
            Check(Directory.GetFiles(Path.Combine(folder, "plans")).Length == 0, "the plan file is removed once read");

            File.WriteAllText(modeFile, "nofile");
            try { runner.GetPlan(inputs, CancellationToken.None); Check(false, "no plan file is a failure"); }
            catch (SetupFailure failure) { Check(failure.Code == "plan_failed" && failure.Message.Contains("3"), "no plan file: plan_failed with the exit code (" + failure.Message + ")"); }

            File.WriteAllText(modeFile, "badjson");
            try { runner.GetPlan(inputs, CancellationToken.None); Check(false, "bad JSON is a failure"); }
            catch (SetupFailure failure) { Equal("plan_invalid", failure.Code, "bad JSON: plan_invalid"); }

            File.WriteAllText(modeFile, "otherschema");
            try { runner.GetPlan(inputs, CancellationToken.None); Check(false, "another schema is a failure"); }
            catch (SetupFailure failure) { Equal("plan_invalid", failure.Code, "another schema: plan_invalid"); }

            File.WriteAllText(modeFile, "sleep");
            PlanRunner impatient = new PlanRunner(script, Path.Combine(folder, "plans"), TimeSpan.FromSeconds(3));
            System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew();
            try { impatient.GetPlan(inputs, CancellationToken.None); Check(false, "a slow installer times out"); }
            catch (SetupFailure failure) { Check(failure.Code == "plan_timeout" && clock.Elapsed < TimeSpan.FromSeconds(30), "a slow installer is stopped: plan_timeout after " + clock.Elapsed.TotalSeconds.ToString("0.0") + " s"); }

            // Google Drive mode gets its own, longer limit: plan mode checks every file of an existing repository there.
            File.WriteAllText(modeFile, "nap");
            PlanRunner patientForDrive = new PlanRunner(script, Path.Combine(folder, "plans"), TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(60));
            try { patientForDrive.GetPlan(inputs, CancellationToken.None); Check(false, "a local check over the local limit times out"); }
            catch (SetupFailure failure) { Equal("plan_timeout", failure.Code, "a local check is held to the local limit"); }
            InstallerInputs driveInputs = new InstallerInputs();
            driveInputs.Repository = @"G:\My Drive\Rewindle\Backups";
            driveInputs.StorageMode = InstallerContract.StorageDriveFs;
            driveInputs.DriveFsMyDriveRoot = @"G:\My Drive";
            driveInputs.Sources.Add(@"C:\Users\you\Documents");
            Check(patientForDrive.GetPlan(driveInputs, CancellationToken.None) != null, "a Google Drive check may take longer than the local limit");
            File.WriteAllText(modeFile, "sleep");

            CancellationTokenSource cancel = new CancellationTokenSource();
            cancel.CancelAfter(1500);
            clock.Restart();
            Throws<OperationCanceledException>(() => runner.GetPlan(inputs, cancel.Token), "a cancelled request stops the installer");
            Check(clock.Elapsed < TimeSpan.FromSeconds(30), "and does not wait for it");

            PlanRunner missing = new PlanRunner(Path.Combine(folder, "missing.ps1"), Path.Combine(folder, "plans"), TimeSpan.FromSeconds(5));
            try { missing.GetPlan(inputs, CancellationToken.None); Check(false, "a missing script is a failure"); }
            catch (SetupFailure failure) { Equal("payload_missing", failure.Code, "a missing script: payload_missing"); }
        }

        // ---- install and uninstall -----------------------------------------------------------------------------------------

        internal sealed class Events
        {
            public readonly List<KeyValuePair<string, Dictionary<string, object>>> All = new List<KeyValuePair<string, Dictionary<string, object>>>();

            public void Add(string name, Dictionary<string, object> data)
            {
                lock (All) { All.Add(new KeyValuePair<string, Dictionary<string, object>>(name, data)); }
            }

            public List<string> Names()
            {
                lock (All)
                {
                    return All.Select(item => item.Key == "operationStage" ? "stage:" + item.Value["stage"] : item.Key == "operationFinished" ? "finished:" + item.Value["outcome"] : item.Key).ToList();
                }
            }

            public Dictionary<string, object> Finished()
            {
                lock (All) { return All.Where(item => item.Key == "operationFinished").Select(item => item.Value).FirstOrDefault(); }
            }
        }

        internal sealed class FakePlans : IPlanSource
        {
            public bool Ok = true;
            public ManualResetEvent Block;
            public InstallerInputs Seen;

            public IDictionary<string, object> GetPlan(InstallerInputs inputs, CancellationToken cancel)
            {
                Seen = inputs;
                if (Block != null)
                {
                    while (!Block.WaitOne(20)) { cancel.ThrowIfCancellationRequested(); }
                }
                cancel.ThrowIfCancellationRequested();
                return Obj(Ok
                    ? "{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":true,\"errors\":[],\"warnings\":[]}"
                    : "{\"schema\":\"Rewindle.InstallPlan.v1\",\"ok\":false,\"errors\":[{\"code\":\"repository_not_empty\",\"field\":\"repository\",\"message\":\"The folder is not empty.\"}],\"warnings\":[]}");
            }
        }

        internal sealed class FakeProcess : IElevatedProcess
        {
            public int Exit;
            public ManualResetEvent Release = new ManualResetEvent(true);

            public bool WaitForExit(int milliseconds)
            {
                return Release.WaitOne(milliseconds);
            }

            public int ExitCode
            {
                get { return Exit; }
            }

            public void Dispose()
            {
            }
        }

        internal sealed class FakeLauncher : IElevatedLauncher
        {
            public bool Decline;
            public int Exit;
            public string[] Lines = new string[0];
            public ManualResetEvent Hold;
            public List<string> Arguments;
            public BundleLaunch Bundle;
            public int Starts;

            public IElevatedProcess Start(IList<string> powershellArguments, BundleLaunch bundle)
            {
                Starts++;
                Arguments = new List<string>(powershellArguments);
                Bundle = bundle;
                if (Decline)
                {
                    throw new ElevationDeclinedException();
                }
                string progress = powershellArguments[powershellArguments.IndexOf("-ProgressPath") + 1];
                FakeProcess process = new FakeProcess();
                process.Exit = Exit;
                if (Hold != null)
                {
                    process.Release = new ManualResetEvent(false);
                }
                ManualResetEvent hold = Hold;
                ManualResetEvent release = process.Release;
                string[] lines = Lines;
                Task.Factory.StartNew(delegate
                {
                    // Written like the real installer writes: after the process has started, one line at a time, the file created on the first.
                    Thread.Sleep(60);
                    foreach (string line in lines)
                    {
                        File.AppendAllText(progress, line + "\r\n", new UTF8Encoding(false));
                        Thread.Sleep(30);
                    }
                    if (hold != null)
                    {
                        hold.WaitOne(10000);
                        release.Set();
                    }
                });
                return process;
            }
        }

        private const string PhaseLine = "{\"schema\":\"Rewindle.InstallProgress.v1\",\"seq\":1,\"time\":\"t\",\"type\":\"phase\",\"phase\":\"payload\",\"state\":\"started\",\"title\":\"Copying\",\"detail\":null}";
        private const string OkResult = "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null,\"install_root\":\"C:\\\\Program Files\\\\ResticBackuper\",\"recovery_key_path\":\"C:\\\\Users\\\\you\\\\key.txt\",\"recovery_key_readable_by_user\":true,\"dashboard_executable\":\"C:\\\\Program Files\\\\ResticBackuper\\\\ResticBackuperDashboard.exe\",\"version\":\"0.2.0\"}";

        private static InstallerInputs SampleInputs()
        {
            InstallerInputs inputs = new InstallerInputs();
            inputs.Repository = @"E:\Rewindle Backups";
            inputs.Sources.Add(@"C:\Users\you\Documents");
            inputs.Schedule = "02:00";
            inputs.StartBackup = true;
            return inputs;
        }

        private static void OperationFlow()
        {
            string folder = NewFolder("operation");
            // The script path is only checked for existence before the elevated start.
            string script = Path.Combine(folder, "script.ps1");
            File.WriteAllText(script, "# stub");

            Func<string, FakePlans, FakeLauncher, Events, Action, SetupOperation> make = delegate(string kind, FakePlans plans, FakeLauncher launcher, Events events, Action prepare)
            {
                return new SetupOperation(kind, plans, launcher, "S-1-5-21-1-2-3-1001", script, null, delegate
                {
                    string progress = Path.Combine(folder, "attempt-" + Guid.NewGuid().ToString("N").Substring(0, 6));
                    Directory.CreateDirectory(progress);
                    return progress;
                }, events.Add, prepare);
            };

            // 1. A good install.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Lines = new string[] { PhaseLine, "this line is not JSON", OkResult };
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, null);
                operation.Run(SampleInputs());
                SequenceEqual(new string[] { "stage:preparing", "stage:elevating", "stage:running", "operationLine", "operationLine", "operationLine", "finished:succeeded" }, events.Names(), "a good install: stages, three lines, success");
                Check(operation.Result != null && operation.Result.ResultOk && operation.Result.RecoveryKeyPath == @"C:\Users\you\key.txt", "the result line is kept");
                Dictionary<string, object> finished = events.Finished();
                Check(finished["result"] != null && (int)finished["exitCode"] == 0, "the finished event carries the result and the exit code");
                Check(launcher.Starts == 1, "Windows is asked once");
                Check(launcher.Arguments.Contains("-Unattended") && launcher.Arguments.Contains("-StartBackup") && launcher.Arguments.Contains("S-1-5-21-1-2-3-1001") &&
                      launcher.Arguments[launcher.Arguments.IndexOf("-ProgressPath") + 1].EndsWith("progress.jsonl"), "the installer is started unattended with the SID and a progress path");
                lock (events.All)
                {
                    Check(events.All.Where(e => e.Key == "operationLine").Select(e => (string)e.Value["raw"]).Contains("this line is not JSON") &&
                          events.All.Where(e => e.Key == "operationLine").Any(e => e.Value["line"] == null), "a line that is not JSON is still forwarded as text");
                }
            }

            // 2. The choices fail the last check: nothing is started.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                FakePlans plans = new FakePlans();
                plans.Ok = false;
                SetupOperation operation = make(SetupOperation.Install, plans, launcher, events, null);
                operation.Run(SampleInputs());
                SequenceEqual(new string[] { "stage:preparing", "finished:blocked" }, events.Names(), "a plan with errors blocks the install before Windows is asked");
                Check(launcher.Starts == 0 && events.Finished()["plan"] != null, "no elevated start, and the plan comes back");
            }

            // 3. The permission prompt is declined.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Decline = true;
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, null);
                operation.Run(SampleInputs());
                SequenceEqual(new string[] { "stage:preparing", "stage:elevating", "finished:cancelled" }, events.Names(), "a declined prompt is a cancellation, not an error");
                Check(!operation.IsRunning, "and the operation is over");
            }

            // 4. The installer reports a failure.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Exit = 1;
                launcher.Lines = new string[] { PhaseLine, "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":false,\"error\":{\"code\":\"repository_not_empty\",\"message\":\"The folder is not empty.\"}}" };
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, null);
                operation.Run(SampleInputs());
                Check(events.Names().Last() == "finished:failed" && (string)events.Finished()["message"] == "The folder is not empty.", "a failed result line is a failure with the installer's own message");
                Equal(1, (int)events.Finished()["exitCode"], "and its exit code");
            }

            // 5. The installer ends without a result line.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Exit = 5;
                launcher.Lines = new string[] { PhaseLine };
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, null);
                operation.Run(SampleInputs());
                Check(events.Names().Last() == "finished:failed" && ((string)events.Finished()["message"]).Contains("exit code 5"), "no result line is a failure that says the exit code");
            }

            // 6. Not a single line is ever written.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Exit = -1;
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, null);
                operation.Run(SampleInputs());
                Check(events.Names().Last() == "finished:failed" && !events.Names().Contains("operationLine"), "an installer that writes nothing is a failure, not a hang");
            }

            // 7. Cancelling before Windows is asked, and not after.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                FakePlans plans = new FakePlans();
                plans.Block = new ManualResetEvent(false);
                SetupOperation operation = make(SetupOperation.Install, plans, launcher, events, null);
                Task run = Task.Factory.StartNew(delegate { operation.Run(SampleInputs()); });
                Check(WaitFor(() => events.Names().Contains("stage:preparing"), 5000), "preparing");
                Check(!operation.IsPastCancel, "not past the point of no return yet");
                Check(operation.Cancel(), "Cancel is accepted while preparing");
                run.Wait(10000);
                SequenceEqual(new string[] { "stage:preparing", "finished:cancelled" }, events.Names(), "cancelled before anything was asked");
                Check(launcher.Starts == 0, "and nothing was started");
            }
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Hold = new ManualResetEvent(false);
                launcher.Lines = new string[] { PhaseLine, OkResult };
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, null);
                Task run = Task.Factory.StartNew(delegate { operation.Run(SampleInputs()); });
                Check(WaitFor(() => events.Names().Contains("stage:running"), 5000), "running");
                Check(operation.IsPastCancel && operation.IsRunning, "past the point of no return while the installer works");
                Check(!operation.Cancel(), "Cancel is refused once Windows has been asked");
                launcher.Hold.Set();
                run.Wait(10000);
                Check(events.Names().Last() == "finished:succeeded" && !operation.IsRunning && !operation.IsPastCancel, "and the install still finishes");
            }

            // 8. The first step fails (the bundle could not be unpacked).
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                SetupOperation operation = make(SetupOperation.Install, new FakePlans(), launcher, events, delegate { throw new SetupFailure("payload_unpack_failed", "Setup couldn’t unpack its files."); });
                operation.Run(SampleInputs());
                Check(events.Names().Last() == "finished:failed" && (string)events.Finished()["message"] == "Setup couldn’t unpack its files." && launcher.Starts == 0, "a failed first step is reported and starts nothing");
            }

            // 9. Uninstall: no plan, the uninstaller's own arguments.
            {
                Events events = new Events();
                FakeLauncher launcher = new FakeLauncher();
                launcher.Lines = new string[] { "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null}" };
                FakePlans plans = new FakePlans();
                SetupOperation operation = make(SetupOperation.Uninstall, plans, launcher, events, null);
                operation.Run(null);
                Check(plans.Seen == null && events.Names().Last() == "finished:succeeded", "an uninstall asks for no plan and succeeds");
                Check(launcher.Arguments.Contains("-Unattended") && !launcher.Arguments.Contains("-Repository") && !launcher.Arguments.Contains("-StartBackup"), "an uninstall carries no install choices");
            }
        }

        // ---- the bridge ----------------------------------------------------------------------------------------------------

        internal sealed class FakeUi : IBridgeServices
        {
            public readonly List<string> Sent = new List<string>();
            public readonly List<string> Opened = new List<string>();
            public readonly List<string> Revealed = new List<string>();
            public readonly List<string> Copied = new List<string>();
            public readonly List<string> Started = new List<string>();
            public string FolderToReturn = string.Empty;
            public string SaveToReturn = string.Empty;
            public string SaveInitialFolder;
            public bool CloseRequested;
            public ThemeState Theme_ = new ThemeState();

            public void Post(Action work)
            {
                work();
            }

            public void Send(string json)
            {
                lock (Sent) { Sent.Add(json); }
            }

            public ThemeState Theme { get { return Theme_; } }
            public string Locale { get { return "en-US"; } }
            public string PickFolder(string title, string okButtonLabel, string legacyDescription) { return FolderToReturn; }
            public string PickSaveFile(string initialFolder, string suggestedName) { SaveInitialFolder = initialFolder; return SaveToReturn; }
            public void CopyToClipboard(string text) { Copied.Add(text); }
            public void OpenAddress(string address) { Opened.Add(address); }
            public void RevealFile(string path) { Revealed.Add(path); }
            public void StartProgram(string path, string arguments) { Started.Add(path + "|" + arguments); }
            public string Zoom(string direction) { return "Zoom " + direction; }
            public void RequestClose() { CloseRequested = true; }

            public IDictionary<string, object> Response(string id)
            {
                lock (Sent)
                {
                    foreach (string json in Sent)
                    {
                        IDictionary<string, object> message = Obj(json);
                        if (Json.String(message, "type", 16) == "response" && Json.String(message, "id", 64) == id)
                        {
                            return message;
                        }
                    }
                }
                return null;
            }

            public bool WaitResponse(string id)
            {
                return WaitFor(() => Response(id) != null, 10000);
            }

            public List<IDictionary<string, object>> Events(string name)
            {
                lock (Sent)
                {
                    return Sent.Select(json => Obj(json)).Where(m => Json.String(m, "type", 16) == "event" && Json.String(m, "event", 64) == name).ToList();
                }
            }
        }

        private static string Request(string id, string command, string payloadJson)
        {
            return "{\"type\":\"request\",\"id\":\"" + id + "\",\"command\":\"" + command + "\"" + (payloadJson == null ? string.Empty : ",\"payload\":" + payloadJson) + "}";
        }

        private static bool Ok(IDictionary<string, object> response)
        {
            return response != null && Json.Bool(response, "ok") == true;
        }

        private static string ErrorCode(IDictionary<string, object> response)
        {
            return response == null ? null : Json.String(Json.AsObject(Json.Get(response, "error")), "code", 64);
        }

        private static IDictionary<string, object> ResultOf(IDictionary<string, object> response)
        {
            return Json.AsObject(Json.Get(response, "result"));
        }

        private static void ProtocolBehaviour()
        {
            BridgeRequest request;
            Check(!BridgeProtocol.TryParseRequest("garbage", out request), "garbage is dropped");
            Check(!BridgeProtocol.TryParseRequest("[]", out request), "an array is dropped");
            Check(!BridgeProtocol.TryParseRequest("{\"type\":\"event\",\"id\":\"1\",\"command\":\"hello\"}", out request), "a message of another type is dropped");
            Check(!BridgeProtocol.TryParseRequest("{\"type\":\"request\",\"id\":\"bad id!\",\"command\":\"hello\"}", out request), "an id with odd characters is dropped");
            Check(!BridgeProtocol.TryParseRequest("{\"type\":\"request\",\"command\":\"hello\"}", out request), "no id is dropped");
            Check(!BridgeProtocol.TryParseRequest(new string(' ', BridgeProtocol.MaximumMessageLength + 1), out request), "a message over the limit is dropped");
            Check(BridgeProtocol.TryParseRequest("{\"type\":\"request\",\"id\":\"7\",\"command\":\"formatDisk\"}", out request) && request.Command == null, "a well-formed request for a command that is not listed is recognised as such");
            Check(BridgeProtocol.TryParseRequest("{\"type\":\"request\",\"id\":\"7\",\"command\":\"hello\"}", out request) && request.Command == "hello" && request.Payload == null, "hello is accepted");
            Check(BridgeProtocol.TryParseRequest("\"{\\\"type\\\":\\\"request\\\",\\\"id\\\":\\\"8\\\",\\\"command\\\":\\\"close\\\"}\"", out request) && request.Command == "close", "JSON inside a string is read once");
            Equal(16, BridgeProtocol.Commands.Length, "sixteen commands");
            Check(BridgeProtocol.Commands.Distinct().Count() == BridgeProtocol.Commands.Length, "none twice");
            Check(!BridgeProtocol.IsCommand("__proto__") && !BridgeProtocol.IsCommand("Hello") && !BridgeProtocol.IsCommand(null), "command names are exact");
        }

        private static BridgeEnvironment NewEnvironment(string folder, FakePlans plans, FakeLauncher launcher)
        {
            string script = Path.Combine(folder, "Install-ResticBackuper.ps1");
            File.WriteAllText(script, "# stub");
            BridgeEnvironment environment = new BridgeEnvironment();
            environment.ProductVersion = "9.9.9-test";
            environment.UserSid = "S-1-5-21-1-2-3-1001";
            environment.ProgramFilesFolder = Path.Combine(folder, "Program Files");
            environment.CommonDataFolder = Path.Combine(folder, "ProgramData");
            environment.Plans = plans;
            environment.Launcher = launcher;
            environment.EnsureBundle = delegate { return Task.Factory.StartNew(delegate { }); };
            environment.InstallScriptPath = script;
            environment.BundledUninstallScriptPath = Path.Combine(folder, "Uninstall-ResticBackuper.ps1");
            environment.CreateProgressFolder = delegate
            {
                string progress = Path.Combine(folder, "p-" + Guid.NewGuid().ToString("N").Substring(0, 6));
                Directory.CreateDirectory(progress);
                return progress;
            };
            return environment;
        }

        private static void BridgeCommands()
        {
            string folder = NewFolder("bridge");
            FakePlans plans = new FakePlans();
            FakeLauncher launcher = new FakeLauncher();
            FakeUi ui = new FakeUi();
            BridgeEnvironment environment = NewEnvironment(folder, plans, launcher);
            SetupBridge bridge = new SetupBridge(ui, environment);

            // Answers to things that are not requests: none. Unknown commands: an error, because the page is waiting.
            bridge.Receive("garbage");
            bridge.Receive(Request("u1", "formatDisk", "{}"));
            Equal("unknown_command", ErrorCode(ui.Response("u1")), "an unknown command is answered with an error");
            Equal(1, ui.Sent.Count, "garbage got no answer at all");

            bridge.Receive(Request("h1", "hello", null));
            IDictionary<string, object> hello = ResultOf(ui.Response("h1"));
            Check(Json.Long(hello, "protocol") == 1 && Json.String(hello, "host", 16) == "desktop" && Json.String(hello, "version", 64) == "9.9.9-test" && Json.Get(hello, "dark") is bool && Json.String(hello, "locale", 16) == "en-US",
                "hello describes the host");

            // getPlan.
            bridge.Receive(Request("g1", "getPlan", "{\"inputs\":{\"schedule\":\"99:99\"}}"));
            Equal("invalid_inputs", ErrorCode(ui.Response("g1")), "getPlan checks its inputs");
            bridge.Receive(Request("g2", "getPlan", "{\"inputs\":{\"repository\":\"E:\\\\Backups\",\"sources\":[\"C:\\\\Users\\\\you\\\\Desktop\"],\"schedule\":\"02:00\",\"vss\":true}}"));
            Check(ui.WaitResponse("g2") && Ok(ui.Response("g2")) && Json.String(ResultOf(ui.Response("g2")), "schema", 64) == "Rewindle.InstallPlan.v1", "getPlan answers with the plan");
            Check(plans.Seen != null && plans.Seen.Repository == @"E:\Backups" && plans.Seen.Sources.Count == 1, "from the validated inputs");
            // A newer plan replaces one that is still running.
            plans.Block = new ManualResetEvent(false);
            bridge.Receive(Request("g3", "getPlan", "{\"inputs\":{}}"));
            Thread.Sleep(150);
            bridge.Receive(Request("g4", "getPlan", "{\"inputs\":{}}"));
            Check(ui.WaitResponse("g3") && ErrorCode(ui.Response("g3")) == "superseded", "an older plan request is superseded by a newer one");
            plans.Block.Set();
            Check(ui.WaitResponse("g4") && Ok(ui.Response("g4")), "and the newer one is answered");
            plans.Block = null;

            // Links, text, zoom, close.
            bridge.Receive(Request("o1", "openUrl", "{\"target\":\"readme\"}"));
            bridge.Receive(Request("o2", "openUrl", "{\"target\":\"https://evil.example/\"}"));
            bridge.Receive(Request("o3", "openUrl", "{\"target\":\"javascript:alert(1)\"}"));
            bridge.Receive(Request("o4", "openUrl", null));
            Check(Ok(ui.Response("o1")) && ui.Opened.SequenceEqual(new string[] { "https://github.com/50sotero/rewindle#readme" }), "openUrl opens the project's README by name");
            Check(ErrorCode(ui.Response("o2")) == "invalid_request" && ErrorCode(ui.Response("o3")) == "invalid_request" && ErrorCode(ui.Response("o4")) == "invalid_request" && ui.Opened.Count == 1, "and refuses any address the page names");
            foreach (string name in new string[] { "readme", "issues", "license", "requirements" })
            {
                string address;
                Check(ProjectLinks.TryResolve(name, out address) && address.StartsWith("https://github.com/50sotero/rewindle"), "link " + name + " is the project's own");
            }
            bridge.Receive(Request("c1", "copyText", "{\"text\":\"details\"}"));
            bridge.Receive(Request("c2", "copyText", "{\"text\":\"" + new string('a', 70000) + "\"}"));
            bridge.Receive(Request("c3", "copyText", "{\"text\":\"\"}"));
            Check(Ok(ui.Response("c1")) && ui.Copied.Count == 1 && ErrorCode(ui.Response("c2")) == "invalid_request" && ErrorCode(ui.Response("c3")) == "invalid_request", "copyText copies a reasonable amount of text");
            bridge.Receive(Request("z1", "setZoom", "{\"zoom\":\"in\"}"));
            bridge.Receive(Request("z2", "setZoom", "{\"zoom\":\"sideways\"}"));
            Check(Ok(ui.Response("z1")) && ErrorCode(ui.Response("z2")) == "invalid_request", "setZoom takes in, out or reset");
            bridge.Receive(Request("x1", "close", null));
            Check(Ok(ui.Response("x1")) && ui.CloseRequested, "close closes the window");

            // Folders.
            string chosen = NewFolder("chosen");
            ui.FolderToReturn = chosen;
            bridge.Receive(Request("b1", "browseFolder", null));
            Equal(chosen, Json.String(ResultOf(ui.Response("b1")), "path", 1024), "browseFolder returns the chosen folder");
            ui.FolderToReturn = string.Empty;
            bridge.Receive(Request("b2", "browseRepositoryFolder", null));
            Check(Ok(ui.Response("b2")) && Json.Get(ResultOf(ui.Response("b2")), "path") == null, "a cancelled chooser answers with no path");
            ui.FolderToReturn = Path.Combine(chosen, "does-not-exist");
            bridge.Receive(Request("b3", "browseFolder", null));
            Equal("not_a_folder", ErrorCode(ui.Response("b3")), "a path that is not a folder is refused");

            // measureFolders: validation, then events.
            bridge.Receive(Request("m1", "measureFolders", "{\"request\":\"r1\",\"paths\":[]}"));
            bridge.Receive(Request("m2", "measureFolders", "{\"request\":\"r1\",\"paths\":[\"\\\\\\\\server\\\\share\"]}"));
            bridge.Receive(Request("m3", "measureFolders", "{\"request\":\"bad id\",\"paths\":[\"C:\\\\x\"]}"));
            Check(ErrorCode(ui.Response("m1")) == "invalid_request" && ErrorCode(ui.Response("m2")) == "invalid_request" && ErrorCode(ui.Response("m3")) == "invalid_request", "measureFolders checks its payload");
            File.WriteAllBytes(Path.Combine(chosen, "one.bin"), new byte[1234]);
            bridge.Receive(Request("m4", "measureFolders", "{\"request\":\"r2\",\"paths\":[" + Json.Serialize(chosen) + "]}"));
            Check(Ok(ui.Response("m4")), "measureFolders accepts valid paths at once");
            Check(WaitFor(() => ui.Events("measure").Any(e => Json.Bool(Json.AsObject(Json.Get(e, "data")), "done") == true), 10000), "and streams until done");
            IDictionary<string, object> measured = Json.AsObject(Json.Get(ui.Events("measure").Last(), "data"));
            Check(Json.Long(measured, "bytes") == 1234 && Json.Long(measured, "files") == 1 && Json.String(measured, "request", 64) == "r2" && Json.String(measured, "path", 1024) == chosen, "with the totals, the request and the path as it was asked");
            bridge.Receive(Request("m5", "cancelMeasure", "{\"request\":\"unknown\"}"));
            Check(Ok(ui.Response("m5")) && Json.Bool(ResultOf(ui.Response("m5")), "cancelled") == false, "cancelling a measurement that is not running is harmless");

            // The dashboard is only ever the installed one.
            bridge.Receive(Request("d1", "openDashboard", null));
            Equal("dashboard_missing", ErrorCode(ui.Response("d1")), "no dashboard installed: an error that says so");
            string installRoot = Path.Combine(environment.ProgramFilesFolder, "ResticBackuper");
            Directory.CreateDirectory(installRoot);
            File.WriteAllText(Path.Combine(installRoot, "ResticBackuperDashboard.exe"), "stub");
            Directory.CreateDirectory(Path.Combine(environment.CommonDataFolder, "ResticBackuper"));
            bridge.Receive(Request("d2", "openDashboard", null));
            Check(Ok(ui.Response("d2")) && ui.Started.Count == 1 && ui.Started[0].StartsWith(Path.Combine(installRoot, "ResticBackuperDashboard.exe") + "|--state-dir "), "the installed dashboard is started with its state folder");
            Check(SetupBridge.IsInstalledDashboard(Path.Combine(installRoot, "ResticBackuperDashboard.exe"), installRoot) &&
                  !SetupBridge.IsInstalledDashboard(Path.Combine(folder, "ResticBackuperDashboard.exe"), installRoot) &&
                  !SetupBridge.IsInstalledDashboard(Path.Combine(installRoot, "other.exe"), installRoot) &&
                  !SetupBridge.IsInstalledDashboard(Path.Combine(installRoot, "..", "ResticBackuperDashboard.exe"), installRoot) &&
                  !SetupBridge.IsInstalledDashboard(@"\\server\share\ResticBackuper\ResticBackuperDashboard.exe", installRoot), "only that file in that folder counts as the dashboard");

            // Recovery key commands before and after an install.
            bridge.Receive(Request("k1", "saveRecoveryKeyCopy", null));
            Equal("no_recovery_key", ErrorCode(ui.Response("k1")), "no key to copy before an install");
            bridge.Receive(Request("k2", "showRecoveryKey", null));
            Equal("no_recovery_key", ErrorCode(ui.Response("k2")), "and none to show");

            // Install: validation, busy, events, cancel.
            bridge.Receive(Request("i1", "install", "{\"choices\":{\"repository\":\"E:\\\\b\"}}"));
            Equal("invalid_choices", ErrorCode(ui.Response("i1")), "install checks its choices");
            string keyFile = Path.Combine(folder, "RecoveryKey.txt");
            File.WriteAllText(keyFile, "recovery key contents");
            launcher.Hold = new ManualResetEvent(false);
            launcher.Lines = new string[]
            {
                PhaseLine,
                "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null,\"install_root\":" + Json.Serialize(installRoot) + ",\"recovery_key_path\":" + Json.Serialize(keyFile) +
                    ",\"recovery_key_readable_by_user\":true,\"dashboard_executable\":\"C:\\\\Windows\\\\notepad.exe\"}"
            };
            string choices = "{\"choices\":{\"repository\":\"E:\\\\Rewindle Backups\",\"storageMode\":\"local_ntfs\",\"sources\":[\"C:\\\\Users\\\\you\\\\Documents\"],\"schedule\":\"02:00\",\"vss\":true,\"startBackup\":false}}";
            bridge.Receive(Request("i2", "install", choices));
            Check(Ok(ui.Response("i2")), "install starts");
            bridge.Receive(Request("i3", "install", choices));
            Equal("busy", ErrorCode(ui.Response("i3")), "a second install while one is running is refused");
            bridge.Receive(Request("i4", "uninstall", null));
            Equal("busy", ErrorCode(ui.Response("i4")), "and so is an uninstall");
            Check(WaitFor(() => ui.Events("operationStage").Any(e => Json.String(Json.AsObject(Json.Get(e, "data")), "stage", 16) == "running"), 10000), "the install reaches running");
            Check(bridge.IsBusyPastCancel, "the window must not close now");
            bridge.Receive(Request("i5", "cancelInstall", null));
            Check(Json.Bool(ResultOf(ui.Response("i5")), "cancelled") == false, "cancelInstall is refused once Windows was asked");
            launcher.Hold.Set();
            Check(WaitFor(() => ui.Events("operationFinished").Count == 1, 10000), "the install finishes");
            Check(Json.String(Json.AsObject(Json.Get(ui.Events("operationFinished")[0], "data")), "outcome", 32) == "succeeded", "successfully");
            Check(WaitFor(() => !bridge.IsBusyPastCancel, 5000), "and the window may close again");

            // The key: copy it, show it. The dashboard path the installer reported (notepad) is not trusted.
            string destination = Path.Combine(NewFolder("usb"), "My key.txt");
            ui.SaveToReturn = destination;
            bridge.Receive(Request("k3", "saveRecoveryKeyCopy", null));
            Check(ui.WaitResponse("k3") && Ok(ui.Response("k3")) && Json.Bool(ResultOf(ui.Response("k3")), "saved") == true && File.ReadAllText(destination) == "recovery key contents", "the recovery key is copied, byte for byte");
            ui.SaveToReturn = string.Empty;
            bridge.Receive(Request("k4", "saveRecoveryKeyCopy", null));
            Check(Ok(ui.Response("k4")) && Json.Bool(ResultOf(ui.Response("k4")), "saved") == false, "cancelling the Save dialog saves nothing");
            ui.SaveToReturn = Path.Combine(NewFolder("usb2"), "no", "such", "folder", "key.txt");
            bridge.Receive(Request("k5", "saveRecoveryKeyCopy", null));
            Equal("recovery_key_save_failed", ErrorCode(ui.Response("k5")), "a place that cannot be written is an error");
            bridge.Receive(Request("k6", "showRecoveryKey", null));
            Check(Ok(ui.Response("k6")) && ui.Revealed.SequenceEqual(new string[] { keyFile }), "show in folder reveals the file the installer reported");
            ui.Started.Clear();
            bridge.Receive(Request("d3", "openDashboard", null));
            Check(Ok(ui.Response("d3")) && ui.Started[0].StartsWith(Path.Combine(installRoot, "ResticBackuperDashboard.exe")), "a dashboard path outside the install folder is ignored");

            // Uninstall; and a second operation is allowed once the first is over.
            launcher.Hold = null;
            launcher.Lines = new string[] { "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null}" };
            bridge.Receive(Request("n1", "uninstall", null));
            Check(Ok(ui.Response("n1")) && WaitFor(() => ui.Events("operationFinished").Count == 2, 10000), "an uninstall can follow");

            // An unreadable key (the installer says only administrators can read it).
            FakeLauncher locked = new FakeLauncher();
            FakeUi lockedUi = new FakeUi();
            SetupBridge lockedBridge = new SetupBridge(lockedUi, NewEnvironment(NewFolder("locked"), new FakePlans(), locked));
            locked.Lines = new string[] { "{\"schema\":\"Rewindle.InstallProgress.v1\",\"type\":\"result\",\"ok\":true,\"error\":null,\"recovery_key_path\":\"C:\\\\ProgramData\\\\Rewindle\\\\key.txt\",\"recovery_key_readable_by_user\":false}" };
            lockedBridge.Receive(Request("l1", "install", choices));
            Check(lockedUi.WaitResponse("l1") && WaitFor(() => lockedUi.Events("operationFinished").Count == 1, 10000), "an install whose key only administrators can read finishes");
            lockedBridge.Receive(Request("l2", "saveRecoveryKeyCopy", null));
            Check(ErrorCode(lockedUi.Response("l2")) == "recovery_key_unreadable" && ((string)Json.String(Json.AsObject(Json.Get(lockedUi.Response("l2"), "error")), "message", 2000)).Contains("Show in folder"), "an unreadable key is an error that tells what to do instead");

            // After Shutdown nothing more is answered.
            int before = ui.Sent.Count;
            bridge.Shutdown();
            bridge.Receive(Request("s1", "hello", null));
            Equal(before, ui.Sent.Count, "a closing window answers nothing");

            // An install that is cancelled before it asks Windows for anything.
            FakeLauncher never = new FakeLauncher();
            FakePlans slow = new FakePlans();
            slow.Block = new ManualResetEvent(false);
            FakeUi slowUi = new FakeUi();
            SetupBridge slowBridge = new SetupBridge(slowUi, NewEnvironment(NewFolder("slow"), slow, never));
            slowBridge.Receive(Request("q1", "install", choices));
            Thread.Sleep(200);
            slowBridge.Receive(Request("q2", "cancelInstall", null));
            Check(Json.Bool(ResultOf(slowUi.Response("q2")), "cancelled") == true, "cancelInstall is accepted before Windows is asked");
            Check(WaitFor(() => slowUi.Events("operationFinished").Count == 1, 10000) &&
                  Json.String(Json.AsObject(Json.Get(slowUi.Events("operationFinished")[0], "data")), "outcome", 32) == "cancelled" && never.Starts == 0, "and ends as cancelled with nothing started");
            slowBridge.Shutdown();

            // The page crashes while an install is still preparing: it is cancelled, so the reload can't leave it running unseen.
            FakeLauncher neverAfterCrash = new FakeLauncher();
            FakePlans slowAfterCrash = new FakePlans();
            slowAfterCrash.Block = new ManualResetEvent(false);
            FakeUi crashUi = new FakeUi();
            SetupBridge crashBridge = new SetupBridge(crashUi, NewEnvironment(NewFolder("crash"), slowAfterCrash, neverAfterCrash));
            Check(!crashBridge.StopForLostPage(), "with nothing running, a lost page may simply be reloaded");
            crashBridge.Receive(Request("c1", "install", choices));
            Thread.Sleep(200);
            Check(!crashBridge.StopForLostPage(), "an install still preparing is cancelled when the page is lost, so the page may be reloaded");
            Check(WaitFor(() => crashUi.Events("operationFinished").Count == 1, 10000) &&
                  Json.String(Json.AsObject(Json.Get(crashUi.Events("operationFinished")[0], "data")), "outcome", 32) == "cancelled" && neverAfterCrash.Starts == 0,
                  "and it ends as cancelled with nothing started");
            crashBridge.Shutdown();
        }

        private static void WebPolicyBehaviour()
        {
            foreach (string allowed in new string[] { "https://rewindle-setup.local/setup.html", "https://rewindle-setup.local/assets/a.js?x=1", "https://REWINDLE-SETUP.LOCAL:443/", "https://rewindle-setup.local" })
            {
                Check(WebPolicy.IsAllowedUri(allowed), "allowed: " + allowed);
            }
            foreach (string refused in new string[]
            {
                "http://rewindle-setup.local/setup.html", "https://rewindle-setup.local.evil.example/", "https://evil.example/", "https://user@rewindle-setup.local/",
                "https://rewindle-setup.local:8443/", "file:///C:/Windows/win.ini", "about:blank", "data:text/html,hi", "javascript:alert(1)", "ftp://rewindle-setup.local/",
                string.Empty, null, "rewindle-setup.local/setup.html"
            })
            {
                Check(!WebPolicy.IsAllowedUri(refused), "refused: " + (refused ?? "null"));
            }
        }

        private static void SignatureCheck()
        {
            string problem;
            string compiler = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe");
            if (File.Exists(compiler))
            {
                Check(WebViewRuntime.IsSignedByMicrosoft(compiler, out problem), "a Microsoft-signed program passes (" + problem + ")");
            }
            string unsigned = Path.Combine(root, "unsigned.exe");
            File.WriteAllBytes(unsigned, new byte[] { 0x4D, 0x5A, 0x90, 0x00 });
            Check(!WebViewRuntime.IsSignedByMicrosoft(unsigned, out problem) && !string.IsNullOrEmpty(problem), "an unsigned file is refused: " + problem);
            Check(!WebViewRuntime.IsSignedByMicrosoft(Path.Combine(root, "missing.exe"), out problem), "a missing file is refused");
            Check(WebViewRuntime.BootstrapperAddress.StartsWith("https://go.microsoft.com/"), "the bootstrapper's address is Microsoft's, over https");
            string version = WebViewRuntime.InstalledVersion();
            Check(version == null || version.Contains("."), "the installed runtime version is null or a version number (" + (version ?? "none") + ")");
        }

        // ---- the program the build made ---------------------------------------------------------------------------------

        // Reads the embedded resources of the real setup program (its metadata only: nothing in it is started or run) and unpacks them the
        // way Setup does, so a bundle the program's own unpacker would refuse, or a missing or wrong library, is found by the build's CI.
        private static void BuiltProgramResources(string program, string project)
        {
            System.Reflection.Assembly built = System.Reflection.Assembly.LoadFrom(program);
            string[] names = built.GetManifestResourceNames();
            foreach (string expected in new string[] { SetupWorkspace.BundleResource, SetupWorkspace.WebResource, "REWINDLE_ICON", "REWINDLE_WEBVIEW2_CORE", "REWINDLE_WEBVIEW2_WPF", "REWINDLE_WEBVIEW2_LOADER" })
            {
                Check(names.Contains(expected), "the program embeds " + expected);
            }
            Equal(6, names.Length, "and nothing else");

            string version = File.ReadAllText(Path.Combine(project, "VERSION")).Trim();
            object[] informational = built.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false);
            Equal(version, ((System.Reflection.AssemblyInformationalVersionAttribute)informational[0]).InformationalVersion, "the program carries the version in VERSION");

            string parent = NewFolder("built");
            using (SetupWorkspace workspace = new SetupWorkspace(delegate(string name) { return built.GetManifestResourceStream(name); }, parent))
            {
                workspace.ExtractLibraries();
                workspace.ExtractWeb();
                workspace.EnsureBundleExtracted().Wait();
                foreach (string relative in new string[]
                {
                    "Install.cmd", "Install-ResticBackuper.ps1", "payload-manifest.json", "BUILD-INFO.json", @"payload\Uninstall-ResticBackuper.ps1",
                    @"payload\ResticBackuperDashboard.exe", @"payload\restic.exe", @"payload\web\index.html", @"payload\dashboard-assets.json",
                })
                {
                    Check(File.Exists(Path.Combine(workspace.BundleFolder, relative)), "the bundle holds " + relative);
                }
                Check(!Directory.EnumerateFiles(Path.Combine(workspace.BundleFolder, "payload", "web"), "setup*", SearchOption.AllDirectories).Any(), "and none of the wizard's files are in the dashboard's");
                Check(File.Exists(Path.Combine(workspace.WebFolder, "setup.html")) && Directory.EnumerateFiles(workspace.WebFolder, "*.js", SearchOption.AllDirectories).Any(), "the wizard's pages are there");
                string page = File.ReadAllText(Path.Combine(workspace.WebFolder, "setup.html"));
                Check(page.Contains("Content-Security-Policy"), "with their content security policy");

                // The three libraries are the pinned package's own files.
                string package = Path.Combine(project, "src", "dashboard", ".packages", "webview2.1.0.4191.47");
                if (Directory.Exists(package))
                {
                    Equal(Sha(Path.Combine(package, "lib", "net462", "Microsoft.Web.WebView2.Core.dll")), Sha(Path.Combine(workspace.LibraryFolder, "Microsoft.Web.WebView2.Core.dll")), "the managed core library is the pinned SDK's");
                    Equal(Sha(Path.Combine(package, "lib", "net462", "Microsoft.Web.WebView2.Wpf.dll")), Sha(Path.Combine(workspace.LibraryFolder, "Microsoft.Web.WebView2.Wpf.dll")), "the WPF library is the pinned SDK's");
                    Equal(Sha(Path.Combine(package, "runtimes", "win-x64", "native", "WebView2Loader.dll")), Sha(Path.Combine(workspace.LibraryFolder, "WebView2Loader.dll")), "the loader is the pinned SDK's");
                }
                // The installer script in the bundle is the repository's.
                Equal(Sha(Path.Combine(project, "installer", "Install-ResticBackuper.ps1")), Sha(workspace.InstallScriptPath), "the bundled installer script is the repository's");
            }
            // The program's embedded application manifest: it runs as the person who started it (the installer it starts is the only elevated
            // process), is DPI aware per monitor, and carries the release version.
            string manifest = ReadManifest(program);
            Check(manifest.Contains("level=\"asInvoker\"") && !manifest.Contains("requireAdministrator") && !manifest.Contains("highestAvailable"), "the program asks for no elevation");
            Check(manifest.Contains("PerMonitorV2") && manifest.Contains("longPathAware"), "and is per-monitor DPI aware and long-path aware");
            Check(manifest.Contains("Rewindle.Setup") && System.Text.RegularExpressions.Regex.IsMatch(manifest, "assemblyIdentity version=\"" + System.Text.RegularExpressions.Regex.Escape(version.Split('-')[0]) + @"\.[0-9]+"""), "and its manifest carries the version");
            using (System.IO.Stream icon = built.GetManifestResourceStream("REWINDLE_ICON"))
            {
                System.Windows.Media.Imaging.BitmapDecoder decoder = System.Windows.Media.Imaging.BitmapDecoder.Create(icon, System.Windows.Media.Imaging.BitmapCreateOptions.None, System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
                Check(decoder.Frames.Count >= 3, "the icon has several sizes (" + decoder.Frames.Count + ")");
            }
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibraryEx(string file, IntPtr handle, uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LockResource(IntPtr resource);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SizeofResource(IntPtr module, IntPtr resource);

        [DllImport("kernel32.dll")]
        private static extern bool FreeLibrary(IntPtr module);

        // Reads the manifest resource out of a program's file without running anything in it (it is loaded as data).
        private static string ReadManifest(string program)
        {
            IntPtr module = LoadLibraryEx(program, IntPtr.Zero, 0x22);
            if (module == IntPtr.Zero) { return string.Empty; }
            try
            {
                IntPtr resource = FindResource(module, (IntPtr)1, (IntPtr)24);
                if (resource == IntPtr.Zero) { return string.Empty; }
                uint size = SizeofResource(module, resource);
                IntPtr pointer = LockResource(LoadResource(module, resource));
                byte[] bytes = new byte[size];
                Marshal.Copy(pointer, bytes, 0, (int)size);
                return Encoding.UTF8.GetString(bytes);
            }
            finally
            {
                FreeLibrary(module);
            }
        }

        private static string Sha(string path)
        {
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
            {
                return BitConverter.ToString(sha.ComputeHash(stream));
            }
        }

        // ---- the native screens --------------------------------------------------------------------------------------------

        private static void PaletteBehaviour()
        {
            ThemeState light = new ThemeState();
            ThemeState dark = new ThemeState();
            dark.Dark = true;
            Check(StatusPalette.For(light).PageColor == (Color)ColorConverter.ConvertFromString("#F6F4EE"), "light page color is the web page's");
            Check(StatusPalette.For(dark).PageColor == (Color)ColorConverter.ConvertFromString("#101927"), "dark page color is the web page's");
            Check(!light.SameAs(dark) && light.SameAs(new ThemeState()), "theme states compare");
        }

        // `Test-SetupHost.ps1 -RenderScreens <folder>` draws the native screens to PNG files, for a look at them.
        private static void RenderPanels(string folder, string iconPath)
        {
            Directory.CreateDirectory(folder);
            ImageSource icon = null;
            if (iconPath != null && File.Exists(iconPath))
            {
                BitmapDecoder decoder = BitmapDecoder.Create(new Uri(iconPath), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                BitmapFrame best = null;
                foreach (BitmapFrame frame in decoder.Frames)
                {
                    if (best == null || frame.PixelWidth > best.PixelWidth) { best = frame; }
                }
                icon = best;
            }
            foreach (bool dark in new bool[] { false, true })
            {
                ThemeState theme = new ThemeState();
                theme.Dark = dark;
                foreach (string state in new string[] { "missing", "progress", "failed" })
                {
                    StatusPanel panel = new StatusPanel();
                    panel.Icon = icon;
                    panel.ApplyTheme(theme);
                    StatusContent content = new StatusContent();
                    if (state == "missing")
                    {
                        content.Title = "Setup needs one more thing";
                        content.Body = "Rewindle Setup shows its pages with Microsoft’s free WebView2 Runtime, which isn’t on this PC yet. Setup can download it from Microsoft, check Microsoft’s signature on it and install it. It takes about a minute and doesn’t change any of your files.";
                        content.Detail = "About 2 MB from Microsoft. Windows may ask for permission.";
                        content.Buttons.Add(new StatusButton("Install it now", true, null));
                        content.Buttons.Add(new StatusButton("Close", false, null));
                        content.Link = new StatusButton("Download it from Microsoft’s website instead", false, null);
                    }
                    else if (state == "progress")
                    {
                        content.Title = "Getting the display component";
                        content.Body = "Downloading the runtime from Microsoft…";
                        content.Detail = "You can keep this window open while it works.";
                        content.Progress = 0.42;
                    }
                    else
                    {
                        content.Title = "The runtime wasn’t installed";
                        content.Body = "Windows permission wasn’t given, so the runtime wasn’t installed.";
                        content.Detail = "Nothing else on this PC was changed.";
                        content.Buttons.Add(new StatusButton("Try again", true, null));
                        content.Buttons.Add(new StatusButton("Close", false, null));
                    }
                    panel.Show(content);
                    Size size = new Size(960, 640);
                    panel.Measure(size);
                    panel.Arrange(new Rect(size));
                    panel.UpdateLayout();
                    RenderTargetBitmap bitmap = new RenderTargetBitmap(960, 640, 96, 96, PixelFormats.Pbgra32);
                    bitmap.Render(panel);
                    PngBitmapEncoder encoder = new PngBitmapEncoder();
                    encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    string file = Path.Combine(folder, "native-" + state + "-" + (dark ? "dark" : "light") + ".png");
                    using (FileStream stream = File.Create(file))
                    {
                        encoder.Save(stream);
                    }
                    Console.WriteLine("Wrote " + file);
                }
            }
        }
    }
}
