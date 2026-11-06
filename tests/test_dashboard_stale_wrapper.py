from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"


# A backup status that says "running" is believed only while the process that wrote it is still the same process: its ID
# and its exact creation time, which the engine records as wrapper_start_filetime. The harness builds snapshots from
# synthetic status documents (nothing is read from disk) and asks ProcessLiveness directly. It must run unelevated, as the
# dashboard does: an elevated runner may be allowed to open the System process.
HARNESS_SOURCE = r"""
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal static class StaleWrapperHarness
    {
        // Windows' System process. It exists on every PC, and an unelevated process may not open it.
        private const int SystemProcessId = 4;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr process,
            out long creation,
            out long exit,
            out long kernel,
            out long user);

        private static long CreationFileTime(Process process)
        {
            long creation;
            long exit;
            long kernel;
            long user;
            if (!GetProcessTimes(process.Handle, out creation, out exit, out kernel, out user))
            {
                throw new InvalidOperationException("GetProcessTimes failed: " + Marshal.GetLastWin32Error());
            }
            return creation;
        }

        private static Dictionary<string, object> Document(int processId, object fileTime, DateTime startedUtc)
        {
            Dictionary<string, object> progress = new Dictionary<string, object>();
            progress["message_type"] = "status";
            progress["seconds_elapsed"] = 30.0;
            progress["files_done"] = 12L;
            progress["bytes_done"] = 4096L;

            Dictionary<string, object> document = new Dictionary<string, object>();
            document["schema_version"] = 1;
            document["run_id"] = "20260720T120000-deadbeef";
            document["state"] = "backing_up";
            document["started_utc"] = startedUtc.ToString("o", CultureInfo.InvariantCulture);
            document["finished_utc"] = null;
            document["wrapper_pid"] = processId;
            if (fileTime != null)
            {
                document["wrapper_start_filetime"] = fileTime;
            }
            document["sources"] = new object[] { @"C:\Protected" };
            document["progress"] = progress;
            document["errors"] = new object[0];
            return document;
        }

        private static Dictionary<string, object> Describe(
            TelemetryReader reader,
            Dictionary<string, object> document,
            DateTime lastWriteUtc)
        {
            MethodInfo build = typeof(TelemetryReader).GetMethod(
                "BuildBackupSnapshot",
                BindingFlags.NonPublic | BindingFlags.Instance);
            TelemetrySnapshot snapshot = (TelemetrySnapshot)build.Invoke(
                reader,
                new object[] { document, lastWriteUtc });
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["active"] = snapshot.IsActive;
            result["state"] = snapshot.StateKey;
            result["label"] = snapshot.StatusLabel;
            return result;
        }

        public static int Main()
        {
            // Every engine path the reader builds points into a disposable folder; nothing real is looked at.
            EngineProfile.UseFolderRootsForTesting(Path.Combine(Path.GetTempPath(), "rewindle-harness-" + Guid.NewGuid().ToString("N")));
            TelemetryReader reader = new TelemetryReader(@"C:\StaleWrapperState", false);

            Process self = Process.GetCurrentProcess();
            long selfCreation = CreationFileTime(self);
            DateTime selfStartedUtc = DateTime.FromFileTimeUtc(selfCreation);
            // Past the two-minute grace a status gets before a missing writer counts, and well inside a day.
            DateTime writtenUtc = DateTime.UtcNow.AddMinutes(-3);
            DateTime startedUtc = DateTime.UtcNow.AddMinutes(-5);
            string unrelatedTime = "133000000000000000";

            // A process that has exited while this harness still holds its handle: its ID cannot be handed out again
            // meanwhile, and it keeps its creation time.
            ProcessStartInfo start = new ProcessStartInfo(
                Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                "/d /c exit 0");
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            Process child = Process.Start(start);
            child.WaitForExit();
            long childCreation = CreationFileTime(child);

            Dictionary<string, object> cases = new Dictionary<string, object>();
            cases["system_process"] = Describe(
                reader, Document(SystemProcessId, unrelatedTime, startedUtc), writtenUtc);
            cases["system_process_fresh"] = Describe(
                reader, Document(SystemProcessId, unrelatedTime, startedUtc), DateTime.UtcNow);
            cases["same_process"] = Describe(
                reader,
                Document(self.Id, selfCreation.ToString(CultureInfo.InvariantCulture), selfStartedUtc),
                writtenUtc);
            cases["same_process_number"] = Describe(
                reader, Document(self.Id, selfCreation, selfStartedUtc), writtenUtc);
            cases["reused_id"] = Describe(
                reader,
                Document(self.Id, (selfCreation + 1).ToString(CultureInfo.InvariantCulture), selfStartedUtc),
                writtenUtc);
            cases["exited_child"] = Describe(
                reader,
                Document(child.Id, childCreation.ToString(CultureInfo.InvariantCulture), DateTime.FromFileTimeUtc(childCreation)),
                writtenUtc);
            cases["no_start_time"] = Describe(
                reader, Document(self.Id, null, selfStartedUtc), writtenUtc);
            cases["malformed_start_time"] = Describe(
                reader, Document(self.Id, "0" + selfCreation.ToString(CultureInfo.InvariantCulture), selfStartedUtc), writtenUtc);

            Dictionary<string, object> liveness = new Dictionary<string, object>();
            liveness["self"] = ProcessLiveness.IsSameProcessAlive(self.Id, selfCreation);
            liveness["self_other_time"] = ProcessLiveness.IsSameProcessAlive(self.Id, selfCreation + 1);
            liveness["system_process"] = ProcessLiveness.IsSameProcessAlive(SystemProcessId, long.Parse(unrelatedTime, CultureInfo.InvariantCulture));
            liveness["exited_child"] = ProcessLiveness.IsSameProcessAlive(child.Id, childCreation);
            liveness["zero_id"] = ProcessLiveness.IsSameProcessAlive(0, selfCreation);
            liveness["zero_time"] = ProcessLiveness.IsSameProcessAlive(self.Id, 0);
            child.Dispose();

            Dictionary<string, object> result = new Dictionary<string, object>();
            result["cases"] = cases;
            result["liveness"] = liveness;
            Console.WriteLine(new JavaScriptSerializer().Serialize(result));
            return 0;
        }
    }
}
"""


class DashboardStaleWrapperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.telemetry = (DASHBOARD / "Telemetry.cs").read_text(encoding="utf-8")
        cls.liveness = (DASHBOARD / "ProcessLiveness.cs").read_text(encoding="utf-8")
        cls.build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")

        framework = (
            Path(os.environ.get("SystemRoot", r"C:\Windows"))
            / "Microsoft.NET"
            / "Framework64"
            / "v4.0.30319"
        )
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest("The .NET Framework C# compiler is unavailable.")

        cls.temp_directory = tempfile.TemporaryDirectory()
        temp = Path(cls.temp_directory.name)
        harness = temp / "StaleWrapperHarness.cs"
        executable = temp / "StaleWrapperHarness.exe"
        harness.write_text(textwrap.dedent(HARNESS_SOURCE), encoding="utf-8")
        compile_result = subprocess.run(
            [
                str(compiler),
                "/nologo",
                "/target:exe",
                "/warn:4",
                f"/out:{executable}",
                f"/reference:{framework / 'System.dll'}",
                f"/reference:{framework / 'System.Core.dll'}",
                f"/reference:{framework / 'System.Web.Extensions.dll'}",
                str(DASHBOARD / "EngineProfile.cs"),
                str(DASHBOARD / "AtomicFile.cs"),
                str(DASHBOARD / "ElevatedRequestSecurity.cs"),
                str(DASHBOARD / "SourceConfiguration.cs"),
                str(DASHBOARD / "ProcessLiveness.cs"),
                str(DASHBOARD / "Telemetry.cs"),
                str(harness),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if compile_result.returncode != 0:
            raise AssertionError(
                "Stale wrapper harness compilation failed:\n"
                + compile_result.stdout
                + compile_result.stderr
            )
        run_result = subprocess.run(
            [str(executable)], capture_output=True, text=True, check=False
        )
        if run_result.returncode != 0:
            raise AssertionError(
                "Stale wrapper harness failed:\n" + run_result.stdout + run_result.stderr
            )
        result = json.loads(run_result.stdout)
        cls.cases = result["cases"]
        cls.liveness_result = result["liveness"]

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    def assert_interrupted(self, name: str) -> None:
        case = self.cases[name]
        self.assertFalse(case["active"], f"{name} still shows a backup running: {case}")
        self.assertEqual(case["state"], "interrupted", name)

    def assert_running(self, name: str) -> None:
        case = self.cases[name]
        self.assertTrue(case["active"], f"{name} no longer shows the backup running: {case}")
        self.assertEqual(case["state"], "backing_up", name)

    def test_an_id_taken_over_by_a_process_that_cannot_be_opened_is_not_a_running_backup(self) -> None:
        # After a sign-out mid-backup the wrapper's ID can go to a SYSTEM or elevated process. Windows refuses to open it, and
        # that refusal must not read as "still running".
        self.assert_interrupted("system_process")

    def test_an_id_now_used_by_another_process_is_not_a_running_backup(self) -> None:
        # The ID is alive and openable, and the start time is close, but the exact creation time is another process's.
        self.assert_interrupted("reused_id")

    def test_a_process_that_has_exited_is_not_a_running_backup(self) -> None:
        self.assert_interrupted("exited_child")

    def test_the_recorded_process_still_running_is_a_running_backup(self) -> None:
        self.assert_running("same_process")
        self.assert_running("same_process_number")

    def test_a_fresh_status_keeps_its_grace_period(self) -> None:
        # A status written moments ago is believed for two minutes, as before, whatever the process check says.
        self.assert_running("system_process_fresh")

    def test_a_status_without_the_start_time_keeps_the_older_check(self) -> None:
        # Status files from engine builds that do not record the creation time keep the check by ID and start time.
        self.assert_running("no_start_time")
        self.assert_running("malformed_start_time")

    def test_process_liveness_needs_the_same_process_and_a_running_one(self) -> None:
        self.assertTrue(self.liveness_result["self"])
        for name in ("self_other_time", "system_process", "exited_child", "zero_id", "zero_time"):
            self.assertFalse(self.liveness_result[name], name)

    def test_liveness_asks_only_for_the_limited_query_right(self) -> None:
        self.assertIn(
            "internal static class ProcessLiveness",
            self.liveness,
        )
        self.assertIn(
            "public static bool IsSameProcessAlive(int processId, long creationFileTimeUtc)",
            self.liveness,
        )
        self.assertIn("0x1000", self.liveness)
        self.assertIn("GetProcessTimes(", self.liveness)
        # A process that has ended keeps its ID and creation time while a handle to it is open, so it must also still be
        # running (STILL_ACTIVE).
        self.assertIn("StillActive = 259;", self.liveness)
        self.assertIn("GetExitCodeProcess(handle, out exitCode) && exitCode == StillActive", self.liveness)
        self.assertNotIn("0x0400", self.liveness)
        self.assertIn("ProcessLiveness.IsSameProcessAlive(", self.telemetry)
        self.assertIn('"wrapper_start_filetime"', self.telemetry)
        self.assertIn("(Join-Path $project 'ProcessLiveness.cs')", self.build)


if __name__ == "__main__":
    unittest.main()
