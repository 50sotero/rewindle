using System;
using System.Runtime.InteropServices;

namespace ResticBackuper.Dashboard
{
    // Whether a process that a protected record names, by its process id and its creation time (a UTC FILETIME), is still
    // that same process and still running. The creation time tells a reused process id apart; the exit code tells a
    // process that has ended, but whose process object is kept by an open handle (this dashboard's own, for instance),
    // apart from one that runs. The dashboard asks only for limited query access, which Windows grants on a same-user
    // elevated process; when Windows refuses, or anything else fails, the answer is false ("not known to be running").
    internal static class ProcessLiveness
    {
        private const uint ProcessQueryLimitedInformation = 0x1000;
        private const uint StillActive = 259;

        public static bool IsSameProcessAlive(int processId, long creationFileTimeUtc)
        {
            if (processId <= 0 || creationFileTimeUtc <= 0)
            {
                return false;
            }
            IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)processId);
            if (handle == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                long creation;
                long exit;
                long kernel;
                long user;
                if (!GetProcessTimes(handle, out creation, out exit, out kernel, out user) ||
                    creation != creationFileTimeUtc)
                {
                    return false;
                }
                uint exitCode;
                return GetExitCodeProcess(handle, out exitCode) && exitCode == StillActive;
            }
            catch
            {
                return false;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(
            IntPtr process,
            out long creationTime,
            out long exitTime,
            out long kernelTime,
            out long userTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
