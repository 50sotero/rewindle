using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace Rewindle.Setup
{
    // The person said no to Windows' permission prompt (or closed it).
    internal sealed class ElevationDeclinedException : Exception
    {
        public ElevationDeclinedException()
            : base("Windows permission was not given.")
        {
        }
    }

    internal interface IElevatedProcess : IDisposable
    {
        bool WaitForExit(int milliseconds);
        int ExitCode { get; }
    }

    internal interface IElevatedLauncher
    {
        // Starts Windows PowerShell with the arguments, elevated. Throws ElevationDeclinedException when the prompt is declined.
        // When the script comes from this setup's own unpacked bundle, bundle says so, and the run goes through ElevatedBootstrap.
        IElevatedProcess Start(IList<string> powershellArguments, BundleLaunch bundle);
    }

    // The real launcher: ShellExecute's "runas" verb, which is the one thing that makes Windows show the permission prompt (once).
    // The window is hidden, because the page shows the progress; the installer reports through its progress file, not the console.
    internal sealed class ShellElevatedLauncher : IElevatedLauncher
    {
        private const int ErrorCancelled = 1223;

        private sealed class Handle : IElevatedProcess
        {
            private readonly Process process;

            public Handle(Process process)
            {
                this.process = process;
            }

            public bool WaitForExit(int milliseconds)
            {
                return process.WaitForExit(milliseconds);
            }

            public int ExitCode
            {
                get { return process.ExitCode; }
            }

            public void Dispose()
            {
                process.Dispose();
            }
        }

        public IElevatedProcess Start(IList<string> powershellArguments, BundleLaunch bundle)
        {
            // A script from the person's temp folder is never run from there elevated: the bootstrap copies it into a folder only
            // administrators can change and checks it against what this program unpacked, before running it.
            IList<string> arguments = bundle == null ? powershellArguments : ElevatedBootstrap.Wrap(powershellArguments, bundle);
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = PlanRunner.WindowsPowerShellPath();
            startInfo.Arguments = CommandLine.Join(arguments);
            // Not the temp folder the program was unpacked into: nothing the elevated process starts should look there first.
            startInfo.WorkingDirectory = Environment.SystemDirectory;
            startInfo.UseShellExecute = true;
            startInfo.Verb = "runas";
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            Process process;
            try
            {
                process = Process.Start(startInfo);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == ErrorCancelled)
                {
                    throw new ElevationDeclinedException();
                }
                SetupLog.Write("The elevated start failed", error);
                throw new SetupFailure("elevation_failed", "Windows would not start the installer (" + error.Message + ").");
            }
            if (process == null)
            {
                throw new SetupFailure("elevation_failed", "Windows did not start the installer.");
            }
            return new Handle(process);
        }
    }

    // One install or uninstall, start to finish. It runs on a worker thread and reports with events (operationStage,
    // operationLine, operationFinished: the names and shapes web/src/setup/bridge.ts documents), which the bridge hands to the page.
    //
    // The order for an install is the contract's: check the choices once more in plan mode, without elevation, so a problem is
    // found before Windows is asked for anything; then ask Windows, once; then follow the installer's progress file until it ends.
    // The person can cancel only up to the moment Windows is asked. After that the installer is an elevated process this one
    // cannot stop, so the only honest controls are "wait" and, when it ends, "try again".
    internal sealed class SetupOperation
    {
        public const string Install = "install";
        public const string Uninstall = "uninstall";

        private enum Stage { Preparing, Elevating, Running, Finished }

        private readonly string kind;
        private readonly IPlanSource plans;
        private readonly IElevatedLauncher launcher;
        private readonly string userSid;
        private readonly string scriptPath;
        private readonly BundleLaunch bundle;
        private readonly Func<string> createProgressFolder;
        private readonly Action<string, Dictionary<string, object>> emit;
        private readonly Action prepare;
        private readonly CancellationTokenSource beforePermission = new CancellationTokenSource();
        private readonly object gate = new object();
        private Stage stage = Stage.Preparing;
        private ProgressLine result;

        public SetupOperation(
            string kind,
            IPlanSource plans,
            IElevatedLauncher launcher,
            string userSid,
            string scriptPath,
            BundleLaunch bundle,
            Func<string> createProgressFolder,
            Action<string, Dictionary<string, object>> emit,
            Action prepare)
        {
            this.kind = kind;
            this.plans = plans;
            this.launcher = launcher;
            this.userSid = userSid;
            this.scriptPath = scriptPath;
            this.bundle = bundle;
            this.createProgressFolder = createProgressFolder;
            this.emit = emit;
            this.prepare = prepare;
        }

        public string Kind
        {
            get { return kind; }
        }

        public bool IsRunning
        {
            get
            {
                lock (gate)
                {
                    return stage != Stage.Finished;
                }
            }
        }

        // True while closing the window would leave an elevated installer working (or about to start) behind a page that is gone.
        public bool IsPastCancel
        {
            get
            {
                lock (gate)
                {
                    return stage == Stage.Elevating || stage == Stage.Running;
                }
            }
        }

        // The installer's result line, once it has written one.
        public ProgressLine Result
        {
            get
            {
                lock (gate)
                {
                    return result;
                }
            }
        }

        // Cancels the operation if Windows has not been asked yet. Returns whether it did.
        public bool Cancel()
        {
            lock (gate)
            {
                if (stage != Stage.Preparing)
                {
                    return false;
                }
                beforePermission.Cancel();
                return true;
            }
        }

        public void Run(InstallerInputs inputs)
        {
            try
            {
                RunCore(inputs);
            }
            catch (OperationCanceledException)
            {
                Finish("cancelled", "Setup was cancelled before anything was changed.", null, null, null);
            }
            catch (SetupFailure failure)
            {
                SetupLog.Write(kind + " failed before the installer started: " + failure.Code + " " + failure.Message);
                Finish("failed", failure.Message, null, null, null);
            }
            catch (Exception error)
            {
                SetupLog.Write("Unexpected failure in the " + kind, error);
                Finish(
                    "failed",
                    "Setup ran into a problem before it could start, and nothing was changed. Try again.",
                    null,
                    null,
                    null);
            }
        }

        private void RunCore(InstallerInputs inputs)
        {
            SetStage(Stage.Preparing);
            Emit("operationStage", "stage", "preparing");
            // Whatever has to be ready first (the release bundle unpacked); it throws SetupFailure with the reason when it is not.
            if (prepare != null)
            {
                prepare();
            }
            if (kind == Install)
            {
                IDictionary<string, object> plan = plans.GetPlan(inputs, beforePermission.Token);
                if (!InstallerContract.PlanAllowsInstall(plan))
                {
                    Finish(
                        "blocked",
                        "Setup found a problem with your choices before changing anything.",
                        null,
                        null,
                        plan);
                    return;
                }
            }
            if (!File.Exists(scriptPath))
            {
                throw new SetupFailure("payload_missing", "Setup’s files are incomplete. Download Rewindle Setup again.");
            }
            beforePermission.Token.ThrowIfCancellationRequested();

            string progressPath = Path.Combine(createProgressFolder(), "progress.jsonl");
            List<string> arguments = kind == Install
                ? InstallerContract.InstallArguments(scriptPath, userSid, progressPath, inputs)
                : InstallerContract.UninstallArguments(scriptPath, userSid, progressPath);

            lock (gate)
            {
                // Past this point the person can no longer cancel, so a click that arrives now is answered "not cancelled".
                beforePermission.Token.ThrowIfCancellationRequested();
                stage = Stage.Elevating;
            }
            Emit("operationStage", "stage", "elevating");

            IElevatedProcess process;
            try
            {
                process = launcher.Start(arguments, bundle);
            }
            catch (ElevationDeclinedException)
            {
                Finish("cancelled", "Windows permission was not given, so nothing was changed.", null, null, null);
                return;
            }

            using (process)
            {
                SetStage(Stage.Running);
                Emit("operationStage", "stage", "running");
                ProgressTail tail = new ProgressTail(progressPath);
                while (!process.WaitForExit(250))
                {
                    Forward(tail.ReadNewLines());
                }
                // The installer has ended, but its last lines may still be landing on disk.
                Forward(tail.ReadNewLines());
                Thread.Sleep(200);
                Forward(tail.Finish());

                int exitCode = process.ExitCode;
                ProgressLine finalResult = Result;
                if (finalResult != null && finalResult.ResultOk)
                {
                    if (exitCode != 0)
                    {
                        SetupLog.Write("The installer reported success but exited with code " + exitCode + ".");
                    }
                    Finish("succeeded", string.Empty, finalResult.Fields, exitCode, null);
                }
                else if (finalResult != null)
                {
                    Finish(
                        "failed",
                        finalResult.ResultErrorMessage ?? "Setup couldn’t finish.",
                        finalResult.Fields,
                        exitCode,
                        null);
                }
                else
                {
                    SetupLog.Write("The installer ended with code " + exitCode + " without a result line.");
                    Finish(
                        "failed",
                        "The installer stopped without saying whether it worked (exit code " + exitCode + "). " +
                            "It may have been closed, or blocked by security software.",
                        null,
                        exitCode,
                        null);
                }
            }
        }

        private void Forward(List<string> lines)
        {
            foreach (string raw in lines)
            {
                ProgressLine line = InstallerContract.ReadProgressLine(raw);
                if (line.IsResult)
                {
                    lock (gate)
                    {
                        result = line;
                    }
                }
                Dictionary<string, object> data = new Dictionary<string, object>();
                data["operation"] = kind;
                data["raw"] = raw.Length <= 8192 ? raw : raw.Substring(0, 8192) + "…";
                data["line"] = line.Fields;
                emit("operationLine", data);
            }
        }

        private void SetStage(Stage next)
        {
            lock (gate)
            {
                stage = next;
            }
        }

        private void Emit(string name, string key, string value)
        {
            Dictionary<string, object> data = new Dictionary<string, object>();
            data["operation"] = kind;
            data[key] = value;
            emit(name, data);
        }

        private void Finish(string outcome, string message, object resultFields, int? exitCode, object plan)
        {
            SetStage(Stage.Finished);
            Dictionary<string, object> data = new Dictionary<string, object>();
            data["operation"] = kind;
            data["outcome"] = outcome;
            data["result"] = resultFields;
            data["message"] = message ?? string.Empty;
            data["exitCode"] = exitCode.HasValue ? (object)exitCode.Value : null;
            if (plan != null)
            {
                data["plan"] = plan;
            }
            emit("operationFinished", data);
        }
    }
}
