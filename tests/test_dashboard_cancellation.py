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


HARNESS_SOURCE = r"""
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal static class CancellationTelemetryHarness
    {
        private static Dictionary<string, object> Document(string state, bool terminal)
        {
            Dictionary<string, object> progress = new Dictionary<string, object>();
            progress["message_type"] = "status";
            progress["seconds_elapsed"] = 30.0;
            progress["files_done"] = 12L;
            progress["bytes_done"] = 4096L;

            Dictionary<string, object> document = new Dictionary<string, object>();
            document["run_id"] = "20260720T120000-deadbeef";
            document["state"] = state;
            document["started_utc"] = DateTime.UtcNow.AddSeconds(-30).ToString("o");
            document["wrapper_pid"] = Process.GetCurrentProcess().Id;
            document["sources"] = new object[] { @"C:\Protected" };
            document["progress"] = progress;
            document["errors"] = new object[0];
            document["phase_at_cancel_request"] = "backing_up";
            document["cancel_outcome"] = state == "cancelled" ? "restic_exit_130" : null;
            if (terminal)
            {
                document["finished_utc"] = DateTime.UtcNow.ToString("o");
                document["exit_code"] = 130;
            }
            return document;
        }

        private static TelemetrySnapshot Snapshot(
            TelemetryReader reader,
            Dictionary<string, object> document)
        {
            MethodInfo build = typeof(TelemetryReader).GetMethod(
                "BuildBackupSnapshot",
                BindingFlags.NonPublic | BindingFlags.Instance);
            return (TelemetrySnapshot)build.Invoke(
                reader,
                new object[] { document, DateTime.UtcNow });
        }

        public static int Main()
        {
            // Every engine path the reader builds points into a disposable folder; nothing real is looked at.
            EngineProfile.UseFolderRootsForTesting(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rewindle-harness-" + System.Guid.NewGuid().ToString("N")));
            TelemetryReader reader = new TelemetryReader(@"C:\CancellationState", false);
            Dictionary<string, object> cancellingDocument = Document("cancelling", false);
            Dictionary<string, object> cancelledDocument = Document("cancelled", true);
            TelemetrySnapshot cancelling = Snapshot(reader, cancellingDocument);
            TelemetrySnapshot cancelled = Snapshot(reader, cancelledDocument);

            MethodInfo createMetric = typeof(TelemetryReader).GetMethod(
                "CreateBackupMetric",
                BindingFlags.NonPublic | BindingFlags.Instance);
            object cancelledMetric = createMetric.Invoke(
                reader,
                new object[] { cancelledDocument });

            Dictionary<string, object> result = new Dictionary<string, object>();
            result["cancelling_active"] = cancelling.IsActive;
            result["cancelling_label"] = cancelling.StatusLabel;
            result["cancelled_active"] = cancelled.IsActive;
            result["cancelled_flag"] = cancelled.IsCancelled;
            result["cancelled_failure"] = cancelled.IsFailure;
            result["cancelled_success"] = cancelled.IsSuccess;
            result["cancelled_detail"] = cancelled.StatusDetail;
            result["cancelled_outcome"] = cancelled.CancelOutcome;
            result["cancelled_metric"] = cancelledMetric != null;
            Console.WriteLine(new JavaScriptSerializer().Serialize(result));
            return 0;
        }
    }
}
"""


class DashboardCancellationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.window_source = (DASHBOARD / "DashboardWindow.cs").read_text(encoding="utf-8")
        cls.controller_source = (DASHBOARD / "BackupCancellationController.cs").read_text(
            encoding="utf-8"
        )

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
        harness = temp / "CancellationTelemetryHarness.cs"
        executable = temp / "CancellationTelemetryHarness.exe"
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
                str(DASHBOARD / "SourceConfiguration.cs"),
                str(DASHBOARD / "Telemetry.cs"),
                str(harness),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if compile_result.returncode != 0:
            raise AssertionError(
                "Cancellation telemetry harness compilation failed:\n"
                + compile_result.stdout
                + compile_result.stderr
            )
        run_result = subprocess.run(
            [str(executable)], capture_output=True, text=True, check=False
        )
        if run_result.returncode != 0:
            raise AssertionError(
                "Cancellation telemetry harness failed:\n"
                + run_result.stdout
                + run_result.stderr
            )
        cls.result = json.loads(run_result.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    def test_cancel_button_uses_only_the_protected_cooperative_path(self) -> None:
        self.assertIn('SetAutomationId(cancelBackupButton, "CancelBackupButton")', self.window_source)
        self.assertIn(
            "cancelBackupButton.Visibility = Visibility.Visible;",
            self.window_source,
        )
        self.assertNotIn(
            "cancelBackupButton.Visibility = Visibility.Collapsed;",
            self.window_source,
        )
        self.assertIn(
            "Available while an exact protected backup run is active.",
            self.window_source,
        )
        self.assertIn("BackupCancellationController.RequestCancel(", self.window_source)
        self.assertIn("Previously verified snapshots are not changed", self.window_source)
        self.assertIn("currentTaskSchedule.State == BackupTaskState.Running", self.window_source)
        for forbidden in ("Stop-ScheduledTask", "schtasks /End", "TerminateProcess"):
            self.assertNotIn(forbidden, self.window_source)
            self.assertNotIn(forbidden, self.controller_source)

    def test_cancelling_is_active_and_cancelled_is_terminal_neutral(self) -> None:
        self.assertTrue(self.result["cancelling_active"])
        self.assertEqual(self.result["cancelling_label"], "Cancelling backup safely")
        self.assertFalse(self.result["cancelled_active"])
        self.assertTrue(self.result["cancelled_flag"])
        self.assertFalse(self.result["cancelled_failure"])
        self.assertFalse(self.result["cancelled_success"])
        self.assertIn("Previously verified snapshots remain available", self.result["cancelled_detail"])
        self.assertEqual(self.result["cancelled_outcome"], "restic_exit_130")
        self.assertTrue(self.result["cancelled_metric"])

    def test_success_is_not_claimed_when_helper_only_accepts_request(self) -> None:
        requested = self.window_source.index("else if (result.Requested)")
        observe = self.window_source.index("private void ObserveCancellationState")
        self.assertNotIn("canceled safely", self.window_source[requested : requested + 500].lower())
        self.assertIn("snapshot.IsCancelled", self.window_source[observe : observe + 3500])
        self.assertIn("BackupTaskState.Running", self.window_source[observe : observe + 3500])


if __name__ == "__main__":
    unittest.main()
