using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace Rewindle.Setup
{
    // Something the wizard asked for that did not work, with a code the page can tell apart and a sentence for the person.
    internal sealed class SetupFailure : Exception
    {
        public readonly string Code;

        public SetupFailure(string code, string message)
            : base(message)
        {
            Code = code;
        }
    }

    internal interface IPlanSource
    {
        // Asks the installer to describe this PC and check `inputs`. Blocks until the plan is read; throws SetupFailure when
        // the installer cannot produce one and OperationCanceledException when `cancel` fires.
        IDictionary<string, object> GetPlan(InstallerInputs inputs, CancellationToken cancel);
    }

    // Plan mode: runs Install-ResticBackuper.ps1 -PlanOnly in a normal (not elevated) Windows PowerShell with an argument array,
    // waits for it for a limited time, and reads the plan file it wrote. Nothing is changed by it. The plan file is removed
    // once it has been read.
    internal sealed class PlanRunner : IPlanSource
    {
        private readonly string scriptPath;
        private readonly string plansFolder;
        private readonly TimeSpan timeout;

        public PlanRunner(string scriptPath, string plansFolder, TimeSpan timeout)
        {
            this.scriptPath = scriptPath;
            this.plansFolder = plansFolder;
            this.timeout = timeout;
        }

        // The 64-bit Windows PowerShell the installer requires. This program is 64-bit, so SystemDirectory is System32.
        public static string WindowsPowerShellPath()
        {
            return Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        }

        public IDictionary<string, object> GetPlan(InstallerInputs inputs, CancellationToken cancel)
        {
            if (!File.Exists(scriptPath))
            {
                throw new SetupFailure("payload_missing", "Setup’s files are incomplete. Download Rewindle Setup again.");
            }
            string powershell = WindowsPowerShellPath();
            if (!File.Exists(powershell))
            {
                throw new SetupFailure("powershell_missing", "Windows PowerShell wasn’t found on this PC, and Rewindle needs it.");
            }
            Directory.CreateDirectory(plansFolder);
            string planPath = Path.Combine(plansFolder, "plan-" + Guid.NewGuid().ToString("N") + ".json");
            List<string> arguments = InstallerContract.PlanArguments(scriptPath, planPath, inputs);

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powershell;
            startInfo.Arguments = CommandLine.Join(arguments);
            startInfo.WorkingDirectory = Environment.SystemDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            startInfo.RedirectStandardOutput = true;
            startInfo.RedirectStandardError = true;
            startInfo.RedirectStandardInput = true;

            StringBuilder diagnostics = new StringBuilder();
            Process process;
            try
            {
                process = Process.Start(startInfo);
            }
            catch (Win32Exception error)
            {
                SetupLog.Write("Plan mode did not start: " + error.Message);
                throw new SetupFailure("plan_start_failed", "Setup couldn’t start Windows PowerShell to check this PC.");
            }
            if (process == null)
            {
                throw new SetupFailure("plan_start_failed", "Setup couldn’t start Windows PowerShell to check this PC.");
            }

            using (process)
            {
                // Nothing is ever typed to it, and an installer that prompts must not wait for an answer.
                try { process.StandardInput.Close(); } catch (IOException) { }
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs received)
                {
                    Append(diagnostics, received.Data);
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs received)
                {
                    Append(diagnostics, received.Data);
                };
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();

                Stopwatch clock = Stopwatch.StartNew();
                while (!process.WaitForExit(100))
                {
                    if (cancel.IsCancellationRequested)
                    {
                        Stop(process);
                        TryDelete(planPath);
                        throw new OperationCanceledException(cancel);
                    }
                    if (clock.Elapsed > timeout)
                    {
                        Stop(process);
                        TryDelete(planPath);
                        SetupLog.Write("Plan mode timed out. Output: " + Tail(diagnostics));
                        throw new SetupFailure(
                            "plan_timeout",
                            "Checking this PC took too long, so Setup stopped it. Close other programs and try again.");
                    }
                }
                // Lets the asynchronous readers finish with the last lines.
                process.WaitForExit();

                string text = ReadPlanFile(planPath);
                if (text == null)
                {
                    int exitCode = process.ExitCode;
                    SetupLog.Write("Plan mode exited with code " + exitCode + " and wrote no plan. Output: " + Tail(diagnostics));
                    throw new SetupFailure(
                        "plan_failed",
                        "Setup couldn’t check this PC (the installer stopped with code " + exitCode + " and gave no plan).");
                }
                IDictionary<string, object> plan;
                string problem;
                if (!InstallerContract.TryReadPlan(text, out plan, out problem))
                {
                    SetupLog.Write("Plan could not be used: " + problem);
                    throw new SetupFailure("plan_invalid", problem);
                }
                return plan;
            }
        }

        // The plan's text, or null when the installer wrote no readable file. The file is deleted either way.
        private static string ReadPlanFile(string planPath)
        {
            try
            {
                FileInfo info = new FileInfo(planPath);
                if (!info.Exists)
                {
                    return null;
                }
                if (info.Length > InstallerContract.MaximumPlanBytes)
                {
                    throw new SetupFailure("plan_invalid", "The installer’s plan is larger than expected.");
                }
                return File.ReadAllText(planPath, new UTF8Encoding(false));
            }
            catch (IOException)
            {
                return null;
            }
            catch (UnauthorizedAccessException)
            {
                return null;
            }
            finally
            {
                TryDelete(planPath);
            }
        }

        private static void Append(StringBuilder builder, string line)
        {
            if (line == null)
            {
                return;
            }
            lock (builder)
            {
                if (builder.Length < 8192)
                {
                    builder.AppendLine(line);
                }
            }
        }

        private static string Tail(StringBuilder builder)
        {
            lock (builder)
            {
                string text = builder.ToString().Trim();
                return text.Length <= 1200 ? text : text.Substring(0, 1200) + "…";
            }
        }

        private static void Stop(Process process)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill();
                    process.WaitForExit(3000);
                }
            }
            catch (InvalidOperationException)
            {
            }
            catch (Win32Exception)
            {
            }
        }

        private static void TryDelete(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
