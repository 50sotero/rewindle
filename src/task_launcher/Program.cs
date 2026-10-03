using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace ResticBackuper.TaskLauncher
{
    internal static class Program
    {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNoWindow = 0x08000000;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint Infinite = 0xFFFFFFFF;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int JobObjectExtendedLimitInformationClass = 9;
        private const uint StillActive = 259;
        private const uint WaitObject0 = 0;
        private const uint WaitFailed = 0xFFFFFFFF;
        private const uint QsAllInput = 0x04FF;
        private const uint MwmoInputAvailable = 0x0004;
        private const uint PmRemove = 0x0001;
        private const uint WmClose = 0x0010;
        private const uint ErrorAlreadyExists = 183;
        private const uint SddlRevision1 = 1;
        private const uint WsExToolWindow = 0x00000080;
        private const uint WsExNoActivate = 0x08000000;
        private const string CancelEventPrefix = "Local\\ResticBackuper.Cancel.";
        private const string CancelEventSddl =
            "O:BAG:BAD:P(A;;GA;;;SY)(A;;GA;;;BA)";

        private static IntPtr activeCancellationEvent = IntPtr.Zero;
        private static WindowProcedure windowProcedureRoot;

        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length != 0)
            {
                return 64;
            }

            string runtime = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string expectedRuntime = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "ResticBackuper");
            if (!string.Equals(runtime, expectedRuntime, StringComparison.OrdinalIgnoreCase))
            {
                return 65;
            }

            string python = Path.Combine(runtime, "Python", "python.exe");
            string backup = Path.Combine(runtime, "backup.py");
            string config = Path.Combine(runtime, "backup-config.json");
            if (!File.Exists(python) || !File.Exists(backup) || !File.Exists(config))
            {
                return 66;
            }

            IntPtr job = IntPtr.Zero;
            IntPtr window = IntPtr.Zero;
            IntPtr environment = IntPtr.Zero;
            string windowClass = null;
            ProcessInformation process = new ProcessInformation();
            CancellationChannel channel = null;
            try
            {
                channel = CancellationChannel.Create();
                activeCancellationEvent = channel.Handle;

                windowClass = "ResticBackuper.TaskLauncher." +
                    channel.ChannelId.Substring(0, 16);
                window = CreateCancellationWindow(windowClass);
                if (window == IntPtr.Zero)
                {
                    return 77;
                }

                job = CreateJobObject(IntPtr.Zero, null);
                if (job == IntPtr.Zero)
                {
                    return 67;
                }

                JobObjectExtendedLimitInformation information =
                    new JobObjectExtendedLimitInformation();
                information.BasicLimitInformation.LimitFlags =
                    JobObjectLimitKillOnJobClose;
                int informationLength = Marshal.SizeOf(information);
                IntPtr informationPointer = Marshal.AllocHGlobal(informationLength);
                try
                {
                    Marshal.StructureToPtr(information, informationPointer, false);
                    if (!SetInformationJobObject(
                        job,
                        JobObjectExtendedLimitInformationClass,
                        informationPointer,
                        (uint)informationLength))
                    {
                        return 68;
                    }
                }
                finally
                {
                    Marshal.FreeHGlobal(informationPointer);
                }

                string launcherStartFileTime = GetCurrentProcessStartFileTime();
                environment = BuildChildEnvironment(
                    channel,
                    GetCurrentProcessId(),
                    launcherStartFileTime);
                string commandLine = Quote(python)
                    + " -I -S -B -u " + Quote(backup)
                    + " --config " + Quote(config)
                    + " --scheduled";
                StartupInfo startup = new StartupInfo();
                startup.Size = (uint)Marshal.SizeOf(startup);
                StringBuilder mutableCommandLine = new StringBuilder(commandLine);
                if (!CreateProcess(
                    python,
                    mutableCommandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    false,
                    CreateNoWindow | CreateSuspended | CreateUnicodeEnvironment,
                    environment,
                    runtime,
                    ref startup,
                    out process))
                {
                    return 69;
                }

                if (!AssignProcessToJobObject(job, process.ProcessHandle))
                {
                    TerminateAndWait(process.ProcessHandle, 70);
                    return 70;
                }
                if (ResumeThread(process.ThreadHandle) == uint.MaxValue)
                {
                    TerminateAndWait(process.ProcessHandle, 71);
                    return 71;
                }

                CloseHandle(process.ThreadHandle);
                process.ThreadHandle = IntPtr.Zero;
                if (!WaitForProcessWithMessages(process.ProcessHandle))
                {
                    TerminateAndWait(process.ProcessHandle, 72);
                    return 72;
                }

                uint exitCode;
                if (!GetExitCodeProcess(process.ProcessHandle, out exitCode)
                    || exitCode == StillActive)
                {
                    TerminateAndWait(process.ProcessHandle, 73);
                    return 73;
                }
                return unchecked((int)exitCode);
            }
            catch (Win32Exception)
            {
                return 74;
            }
            catch (IOException)
            {
                return 75;
            }
            catch (UnauthorizedAccessException)
            {
                return 76;
            }
            catch (CryptographicException)
            {
                return 78;
            }
            finally
            {
                if (environment != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(environment);
                }
                if (process.ThreadHandle != IntPtr.Zero)
                {
                    CloseHandle(process.ThreadHandle);
                }
                if (process.ProcessHandle != IntPtr.Zero)
                {
                    CloseHandle(process.ProcessHandle);
                }
                if (job != IntPtr.Zero)
                {
                    // Closing this non-inherited handle kills any descendant that
                    // survived its direct Python supervisor.
                    CloseHandle(job);
                }
                if (window != IntPtr.Zero)
                {
                    DestroyWindow(window);
                }
                if (!string.IsNullOrEmpty(windowClass))
                {
                    UnregisterClass(windowClass, GetModuleHandle(null));
                }
                activeCancellationEvent = IntPtr.Zero;
                if (channel != null)
                {
                    channel.Dispose();
                }
                GC.KeepAlive(windowProcedureRoot);
            }
        }

        private static IntPtr CreateCancellationWindow(string className)
        {
            windowProcedureRoot = new WindowProcedure(CancellationWindowProcedure);
            WindowClass windowClass = new WindowClass();
            windowClass.Size = (uint)Marshal.SizeOf(windowClass);
            windowClass.Instance = GetModuleHandle(null);
            windowClass.WindowProcedure = Marshal.GetFunctionPointerForDelegate(
                windowProcedureRoot);
            windowClass.ClassName = className;
            if (RegisterClassEx(ref windowClass) == 0)
            {
                return IntPtr.Zero;
            }
            return CreateWindowEx(
                WsExToolWindow | WsExNoActivate,
                className,
                string.Empty,
                0,
                0,
                0,
                0,
                0,
                IntPtr.Zero,
                IntPtr.Zero,
                windowClass.Instance,
                IntPtr.Zero);
        }

        private static IntPtr CancellationWindowProcedure(
            IntPtr window,
            uint message,
            IntPtr wordParameter,
            IntPtr longParameter)
        {
            if (message == WmClose)
            {
                if (activeCancellationEvent != IntPtr.Zero)
                {
                    SetEvent(activeCancellationEvent);
                }
                // Task Scheduler's cooperative close becomes the same protected
                // request as the dashboard action. The supervisor remains alive.
                return IntPtr.Zero;
            }
            return DefWindowProc(window, message, wordParameter, longParameter);
        }

        private static bool WaitForProcessWithMessages(IntPtr process)
        {
            IntPtr[] handles = new IntPtr[] { process };
            while (true)
            {
                uint result = MsgWaitForMultipleObjectsEx(
                    1,
                    handles,
                    Infinite,
                    QsAllInput,
                    MwmoInputAvailable);
                if (result == WaitObject0)
                {
                    return true;
                }
                if (result == WaitObject0 + 1)
                {
                    Message message;
                    while (PeekMessage(out message, IntPtr.Zero, 0, 0, PmRemove))
                    {
                        TranslateMessage(ref message);
                        DispatchMessage(ref message);
                    }
                    continue;
                }
                if (result == WaitFailed)
                {
                    return false;
                }
                return false;
            }
        }

        private static IntPtr BuildChildEnvironment(
            CancellationChannel channel,
            uint launcherPid,
            string launcherStartFileTime)
        {
            SortedDictionary<string, string> variables =
                new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry item in Environment.GetEnvironmentVariables())
            {
                variables[Convert.ToString(item.Key)] = Convert.ToString(item.Value);
            }
            variables["RESTICBACKUPER_CANCEL_EVENT_NAME"] = channel.EventName;
            variables["RESTICBACKUPER_CANCEL_CHANNEL_ID"] = channel.ChannelId;
            variables["RESTICBACKUPER_CANCEL_CHANNEL_FINGERPRINT"] =
                channel.ChannelFingerprint;
            variables["RESTICBACKUPER_LAUNCHER_PID"] =
                launcherPid.ToString(System.Globalization.CultureInfo.InvariantCulture);
            variables["RESTICBACKUPER_LAUNCHER_START_FILETIME"] = launcherStartFileTime;

            StringBuilder block = new StringBuilder();
            foreach (KeyValuePair<string, string> item in variables)
            {
                block.Append(item.Key);
                block.Append('=');
                block.Append(item.Value);
                block.Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }

        private static string GetCurrentProcessStartFileTime()
        {
            FileTime creation;
            FileTime exitTime;
            FileTime kernelTime;
            FileTime userTime;
            if (!GetProcessTimes(
                GetCurrentProcess(),
                out creation,
                out exitTime,
                out kernelTime,
                out userTime))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ulong value = ((ulong)creation.HighDateTime << 32) |
                creation.LowDateTime;
            return value.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static void TerminateAndWait(IntPtr process, uint exitCode)
        {
            if (process == IntPtr.Zero)
            {
                return;
            }
            TerminateProcess(process, exitCode);
            WaitForSingleObject(process, 10000);
        }

        private sealed class CancellationChannel : IDisposable
        {
            private CancellationChannel(
                IntPtr handle,
                string channelId,
                string eventName,
                string channelFingerprint)
            {
                Handle = handle;
                ChannelId = channelId;
                EventName = eventName;
                ChannelFingerprint = channelFingerprint;
            }

            internal IntPtr Handle { get; private set; }
            internal string ChannelId { get; private set; }
            internal string EventName { get; private set; }
            internal string ChannelFingerprint { get; private set; }

            internal static CancellationChannel Create()
            {
                byte[] random = new byte[32];
                using (RandomNumberGenerator generator = RandomNumberGenerator.Create())
                {
                    generator.GetBytes(random);
                }
                string channelId = LowerHex(random);
                string eventName = CancelEventPrefix + channelId;
                string fingerprint;
                using (SHA256 digest = SHA256.Create())
                {
                    fingerprint = LowerHex(
                        digest.ComputeHash(new UTF8Encoding(false).GetBytes(eventName)));
                }

                IntPtr descriptor;
                uint descriptorLength;
                if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                    CancelEventSddl,
                    SddlRevision1,
                    out descriptor,
                    out descriptorLength))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                try
                {
                    SecurityAttributes attributes = new SecurityAttributes();
                    attributes.Length = Marshal.SizeOf(attributes);
                    attributes.SecurityDescriptor = descriptor;
                    attributes.InheritHandle = false;
                    IntPtr handle = CreateEvent(
                        ref attributes,
                        true,
                        false,
                        eventName);
                    int error = Marshal.GetLastWin32Error();
                    if (handle == IntPtr.Zero)
                    {
                        throw new Win32Exception(error);
                    }
                    if ((uint)error == ErrorAlreadyExists)
                    {
                        CloseHandle(handle);
                        throw new IOException("Cancellation event name unexpectedly existed.");
                    }
                    return new CancellationChannel(
                        handle,
                        channelId,
                        eventName,
                        fingerprint);
                }
                finally
                {
                    LocalFree(descriptor);
                }
            }

            public void Dispose()
            {
                if (Handle != IntPtr.Zero)
                {
                    IntPtr handle = Handle;
                    Handle = IntPtr.Zero;
                    CloseHandle(handle);
                }
            }

            private static string LowerHex(byte[] bytes)
            {
                StringBuilder value = new StringBuilder(bytes.Length * 2);
                foreach (byte item in bytes)
                {
                    value.Append(item.ToString("x2", System.Globalization.CultureInfo.InvariantCulture));
                }
                return value.ToString();
            }
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate IntPtr WindowProcedure(
            IntPtr window,
            uint message,
            IntPtr wordParameter,
            IntPtr longParameter);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WindowClass
        {
            public uint Size;
            public uint Style;
            public IntPtr WindowProcedure;
            public int ClassExtra;
            public int WindowExtra;
            public IntPtr Instance;
            public IntPtr Icon;
            public IntPtr Cursor;
            public IntPtr Background;
            public string MenuName;
            public string ClassName;
            public IntPtr SmallIcon;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Message
        {
            public IntPtr Window;
            public uint Value;
            public UIntPtr WordParameter;
            public IntPtr LongParameter;
            public uint Time;
            public Point Point;
            public uint Private;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Point
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo
        {
            public uint Size;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public uint X;
            public uint Y;
            public uint XSize;
            public uint YSize;
            public uint XCountChars;
            public uint YCountChars;
            public uint FillAttribute;
            public uint Flags;
            public ushort ShowWindow;
            public ushort Reserved2;
            public IntPtr Reserved2Pointer;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation
        {
            public IntPtr ProcessHandle;
            public IntPtr ThreadHandle;
            public uint ProcessId;
            public uint ThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool InheritHandle;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfo startupInfo,
            out ProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetCurrentProcess();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetCurrentProcessId();

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr process,
            out FileTime creation,
            out FileTime exitTime,
            out FileTime kernelTime,
            out FileTime userTime);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string moduleName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern ushort RegisterClassEx(ref WindowClass windowClass);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool UnregisterClass(string className, IntPtr instance);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowEx(
            uint extendedStyle,
            string className,
            string windowName,
            uint style,
            int x,
            int y,
            int width,
            int height,
            IntPtr parent,
            IntPtr menu,
            IntPtr instance,
            IntPtr parameter);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyWindow(IntPtr window);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr DefWindowProc(
            IntPtr window,
            uint message,
            IntPtr wordParameter,
            IntPtr longParameter);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint MsgWaitForMultipleObjectsEx(
            uint count,
            IntPtr[] handles,
            uint milliseconds,
            uint wakeMask,
            uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool PeekMessage(
            out Message message,
            IntPtr window,
            uint minimum,
            uint maximum,
            uint remove);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref Message message);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr DispatchMessage(ref Message message);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateEvent(
            ref SecurityAttributes attributes,
            bool manualReset,
            bool initialState,
            string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetEvent(IntPtr handle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
            string stringSecurityDescriptor,
            uint stringSecurityDescriptorRevision,
            out IntPtr securityDescriptor,
            out uint securityDescriptorSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);
    }
}
