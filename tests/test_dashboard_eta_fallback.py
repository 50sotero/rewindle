from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]
TELEMETRY_SOURCE = PROJECT / "src" / "dashboard" / "Telemetry.cs"


HARNESS_SOURCE = r"""
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Web.Script.Serialization;

namespace ResticBackuper.Dashboard
{
    internal static class EtaFallbackHarness
    {
        private static string Fingerprint(params string[] sources)
        {
            Dictionary<string, object> document = new Dictionary<string, object>();
            document["sources"] = sources;
            MethodInfo method = typeof(TelemetryReader).GetMethod(
                "BuildSourceFingerprint",
                BindingFlags.NonPublic | BindingFlags.Static);
            return (string)method.Invoke(null, new object[] { document });
        }

        private static RunMetricRecord Metric(
            string runId,
            string sourceFingerprint,
            double durationSeconds,
            double resticDurationSeconds,
            long files,
            long bytes,
            DateTime startedUtc)
        {
            return new RunMetricRecord
            {
                RunId = runId,
                TypeKey = "backup",
                StateKey = "success",
                Success = true,
                StartedUtc = startedUtc,
                FinishedUtc = startedUtc.AddSeconds(durationSeconds),
                DurationSeconds = durationSeconds,
                ResticDurationSeconds = resticDurationSeconds,
                Files = files,
                ProcessedBytes = bytes,
                StoredBytes = 1,
                SnapshotId = runId,
                SourceFingerprint = sourceFingerprint
            };
        }

        private static TelemetrySnapshot Snapshot(
            IList<RunMetricRecord> history,
            params string[] currentSources)
        {
            TelemetryReader reader = new TelemetryReader(@"C:\EtaFallbackState", false);
            FieldInfo historyField = typeof(TelemetryReader).GetField(
                "historyRecords",
                BindingFlags.NonPublic | BindingFlags.Instance);
            historyField.SetValue(reader, new List<RunMetricRecord>(history));

            Dictionary<string, object> progress = new Dictionary<string, object>();
            progress["message_type"] = "status";
            progress["seconds_elapsed"] = 120.0;
            progress["files_done"] = 100L;
            progress["bytes_done"] = 1000L;
            progress["percent_done"] = 0.0;

            Dictionary<string, object> document = new Dictionary<string, object>();
            document["run_id"] = "current-run";
            document["state"] = "backing_up";
            document["started_utc"] = DateTime.UtcNow.AddSeconds(-120).ToString("o");
            document["wrapper_pid"] = Process.GetCurrentProcess().Id;
            document["sources"] = currentSources;
            document["progress"] = progress;
            document["errors"] = new object[0];

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
            string currentFingerprint = Fingerprint(@"C:\Protected\Current");
            string otherFingerprint = Fingerprint(@"C:\Protected\Other");
            DateTime now = DateTime.UtcNow;

            RunMetricRecord comparable = Metric(
                "comparable",
                otherFingerprint,
                300,
                200,
                200,
                2000,
                now.AddMinutes(-1));
            RunMetricRecord matching = Metric(
                "matching",
                currentFingerprint,
                1200,
                1100,
                1000,
                10000,
                now.AddDays(-1));

            TelemetrySnapshot mismatchSnapshot = Snapshot(
                new List<RunMetricRecord> { comparable },
                @"C:\Protected\Current");
            TelemetrySnapshot matchingSnapshot = Snapshot(
                new List<RunMetricRecord> { comparable, matching },
                @"C:\Protected\Current");

            Dictionary<string, object> result = new Dictionary<string, object>();
            result["mismatch_eta_seconds"] = mismatchSnapshot.Eta.HasValue
                ? mismatchSnapshot.Eta.Value.TotalSeconds
                : -1;
            result["mismatch_confidence"] = mismatchSnapshot.ConfidenceLabel;
            result["mismatch_estimated"] = mismatchSnapshot.ProgressIsEstimated;
            result["matching_eta_seconds"] = matchingSnapshot.Eta.HasValue
                ? matchingSnapshot.Eta.Value.TotalSeconds
                : -1;
            result["matching_confidence"] = matchingSnapshot.ConfidenceLabel;
            result["matching_estimated"] = matchingSnapshot.ProgressIsEstimated;
            Console.WriteLine(new JavaScriptSerializer().Serialize(result));
            return 0;
        }
    }
}
"""


class DashboardEtaFallbackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
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
        harness = temp / "EtaFallbackHarness.cs"
        executable = temp / "EtaFallbackHarness.exe"
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
                str(TELEMETRY_SOURCE.parent / "EngineProfile.cs"),
                str(TELEMETRY_SOURCE.parent / "AtomicFile.cs"),
                str(TELEMETRY_SOURCE.parent / "SourceConfiguration.cs"),
                str(TELEMETRY_SOURCE),
                str(harness),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if compile_result.returncode != 0:
            raise AssertionError(
                "ETA harness compilation failed:\n"
                + compile_result.stdout
                + compile_result.stderr
            )

        run_result = subprocess.run(
            [str(executable)],
            capture_output=True,
            text=True,
            check=False,
        )
        if run_result.returncode != 0:
            raise AssertionError(
                "ETA harness execution failed:\n"
                + run_result.stdout
                + run_result.stderr
            )
        cls.result = json.loads(run_result.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "temp_directory"):
            cls.temp_directory.cleanup()

    def test_mismatched_source_set_gets_immediate_low_confidence_eta(self) -> None:
        self.assertGreater(self.result["mismatch_eta_seconds"], 0)
        self.assertTrue(self.result["mismatch_estimated"])
        self.assertEqual(
            self.result["mismatch_confidence"],
            "Low-confidence estimate from comparable recent runs",
        )

    def test_matching_source_history_remains_preferred(self) -> None:
        self.assertGreater(
            self.result["matching_eta_seconds"],
            self.result["mismatch_eta_seconds"],
        )
        self.assertTrue(self.result["matching_estimated"])
        self.assertEqual(
            self.result["matching_confidence"],
            "Estimated from matching folder-set history",
        )


if __name__ == "__main__":
    unittest.main()
