using System;
using System.IO;
using System.Reflection;
using System.Text;

namespace ResticBackuper.Dashboard
{
    internal static class RecoveryHealthCaptureHarness
    {
        private const BindingFlags Flags =
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        private static object Capture(byte[] input, int maximumBytes)
        {
            Type type = typeof(RecoveryHealthLauncher).GetNestedType(
                "BoundedUtf8Capture",
                BindingFlags.NonPublic);
            object capture = Activator.CreateInstance(
                type,
                Flags,
                null,
                new object[] { new MemoryStream(input, false), maximumBytes },
                null);
            type.GetMethod("Start", Flags).Invoke(capture, null);
            type.GetMethod("JoinUntil", Flags).Invoke(
                capture,
                new object[] { DateTime.UtcNow.AddSeconds(5) });
            return capture;
        }

        private static T Read<T>(object capture, string property)
        {
            return (T)capture.GetType().GetProperty(property, Flags).GetValue(capture, null);
        }

        private static void Require(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException(message);
        }

        public static int Main()
        {
            // Every engine path the dashboard builds points into a disposable folder; nothing real is looked at.
            EngineProfile.UseFolderRootsForTesting(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "rewindle-harness-" + System.Guid.NewGuid().ToString("N")));
            byte[] exact = Encoding.UTF8.GetBytes("A€Z");
            object accepted = Capture(exact, exact.Length);
            Require(!Read<bool>(accepted, "ExceededLimit"), "exact limit was rejected");
            Require(!Read<bool>(accepted, "Failed"), "valid UTF-8 failed");
            Require(Read<int>(accepted, "ByteCount") == exact.Length, "byte count drifted");
            Require(Read<string>(accepted, "Value") == "A€Z", "UTF-8 value drifted");

            object exceeded = Capture(exact, exact.Length - 1);
            Require(Read<bool>(exceeded, "ExceededLimit"), "limit + 1 was accepted");
            Require(Read<string>(exceeded, "Value") == string.Empty, "over-limit data was retained");

            object malformed = Capture(new byte[] { 0xC3, 0x28 }, 2);
            Require(Read<bool>(malformed, "Failed"), "malformed UTF-8 did not fail closed");
            Console.WriteLine("Recovery-health bounded capture checks passed.");
            return 0;
        }
    }
}
