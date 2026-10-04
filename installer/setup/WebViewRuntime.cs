using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using Microsoft.Win32;

namespace Rewindle.Setup
{
    // The Microsoft Edge WebView2 Runtime, which draws the wizard. It is not part of this program's own libraries (those are the
    // SDK), so on a PC without it Setup offers to install it, the same way the installer does (Ensure-WebView2Runtime in
    // Install-ResticBackuper.ps1): download Microsoft's Evergreen bootstrapper from its fixed address, accept it only if it carries
    // a valid Microsoft signature, and run it silently. It touches nothing of the web view's own types, so it works without them.
    internal static class WebViewRuntime
    {
        // The fixed address of Microsoft's bootstrapper, the one the installer and the dashboard use. Nothing the page or any file
        // supplies is ever downloaded or opened.
        public const string BootstrapperAddress = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";
        private const string RuntimeClientKey = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        private const long MaximumDownloadBytes = 64L * 1024L * 1024L;
        private static readonly TimeSpan InstallTimeout = TimeSpan.FromMinutes(10);

        // The runtime's version when one is installed (machine-wide or for this user), or null: the registry keys the installer
        // reads, so Setup and the installer always agree about whether it is there.
        // Set only by the test that opens the window as if the runtime were missing.
        internal static Func<string> Probe { get; set; }

        public static string InstalledVersion()
        {
            if (Probe != null)
            {
                return Probe();
            }
            string[] locations =
            {
                @"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\" + RuntimeClientKey,
                @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\EdgeUpdate\Clients\" + RuntimeClientKey,
                @"HKEY_CURRENT_USER\SOFTWARE\Microsoft\EdgeUpdate\Clients\" + RuntimeClientKey
            };
            foreach (string location in locations)
            {
                try
                {
                    object value = Registry.GetValue(location, "pv", null);
                    string version = value as string;
                    if (version != null && System.Text.RegularExpressions.Regex.IsMatch(version, @"^\d+(\.\d+){1,3}$"))
                    {
                        return version;
                    }
                }
                catch (Exception)
                {
                    // An unreadable key counts as absent, as it does in the installer.
                }
            }
            return null;
        }

        private static int bootstrapperRunning;

        // True while Microsoft's installer may be running: Setup can't stop it once started, so the window must not close then.
        public static bool BootstrapperRunning
        {
            get { return Volatile.Read(ref bootstrapperRunning) != 0; }
        }

        // Downloads, verifies and installs the runtime. `report` gets a plain sentence and, while the size is known, a fraction
        // from 0 to 1 (negative when there is nothing to measure). Blocks; run it off the UI thread. Throws SetupFailure with a
        // sentence for the person, and ElevationDeclinedException when Windows asked for permission and was refused.
        public static void Install(string workFolder, CancellationToken cancel, Action<string, double> report)
        {
            string bootstrapper = Path.Combine(workFolder, "MicrosoftEdgeWebview2Setup-" + Guid.NewGuid().ToString("N") + ".exe");
            try
            {
                report("Downloading the runtime from Microsoft…", -1);
                Download(bootstrapper, cancel, report);

                report("Checking Microsoft’s signature…", -1);
                string signerProblem;
                if (!IsSignedByMicrosoft(bootstrapper, out signerProblem))
                {
                    SetupLog.Write("The WebView2 bootstrapper was rejected: " + signerProblem);
                    throw new SetupFailure(
                        "signature_rejected",
                        "The download didn’t pass Microsoft’s signature check, so Setup did not run it. " + signerProblem);
                }

                // Raised before the last cancellation check, so a window that cancels and then looks at BootstrapperRunning
                // either stops this before Microsoft's installer starts or sees that it has started.
                Interlocked.Exchange(ref bootstrapperRunning, 1);
                try
                {
                    cancel.ThrowIfCancellationRequested();
                    report("Installing the runtime… this can take a minute.", -1);
                    Run(bootstrapper);
                }
                finally
                {
                    Interlocked.Exchange(ref bootstrapperRunning, 0);
                }

                if (InstalledVersion() == null)
                {
                    throw new SetupFailure(
                        "runtime_not_registered",
                        "The installer finished, but Windows doesn’t list the runtime yet. Try again, or install it from Microsoft’s site.");
                }
            }
            finally
            {
                try
                {
                    if (File.Exists(bootstrapper))
                    {
                        File.Delete(bootstrapper);
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

        private static void Download(string destination, CancellationToken cancel, Action<string, double> report)
        {
            try
            {
                // Windows 7 era defaults are not enough for Microsoft's servers; TLS 1.2 is asked for by number.
                ServicePointManager.SecurityProtocol |= (SecurityProtocolType)3072;
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(BootstrapperAddress);
                request.Method = "GET";
                request.AllowAutoRedirect = true;
                request.MaximumAutomaticRedirections = 5;
                request.Timeout = 30000;
                request.ReadWriteTimeout = 30000;
                request.UserAgent = "RewindleSetup";
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    if (!string.Equals(response.ResponseUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new SetupFailure("download_insecure", "Microsoft’s download was not offered over a secure connection.");
                    }
                    long length = response.ContentLength;
                    if (length > MaximumDownloadBytes)
                    {
                        throw new SetupFailure("download_too_large", "The download was larger than expected, so Setup stopped it.");
                    }
                    using (Stream source = response.GetResponseStream())
                    using (FileStream target = new FileStream(destination, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        byte[] buffer = new byte[64 * 1024];
                        long total = 0;
                        int read;
                        while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            cancel.ThrowIfCancellationRequested();
                            total += read;
                            if (total > MaximumDownloadBytes)
                            {
                                throw new SetupFailure("download_too_large", "The download was larger than expected, so Setup stopped it.");
                            }
                            target.Write(buffer, 0, read);
                            if (length > 0)
                            {
                                report("Downloading the runtime from Microsoft…", Math.Min(1.0, (double)total / length));
                            }
                        }
                        if (total == 0)
                        {
                            throw new SetupFailure("download_empty", "Microsoft’s server sent an empty file.");
                        }
                    }
                }
            }
            catch (WebException error)
            {
                SetupLog.Write("WebView2 bootstrapper download failed", error);
                throw new SetupFailure(
                    "download_failed",
                    "Setup couldn’t download the runtime. Check your internet connection and try again.");
            }
        }

        private static void Run(string bootstrapper)
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = bootstrapper;
            startInfo.Arguments = "/silent /install";
            // ShellExecute, so that Windows can ask for permission itself if the bootstrapper needs it.
            startInfo.UseShellExecute = true;
            startInfo.WindowStyle = ProcessWindowStyle.Hidden;
            Process process;
            try
            {
                process = Process.Start(startInfo);
            }
            catch (Win32Exception error)
            {
                if (error.NativeErrorCode == 1223)
                {
                    throw new ElevationDeclinedException();
                }
                SetupLog.Write("The WebView2 bootstrapper did not start", error);
                throw new SetupFailure("runtime_start_failed", "Windows would not start Microsoft’s installer.");
            }
            if (process == null)
            {
                throw new SetupFailure("runtime_start_failed", "Windows would not start Microsoft’s installer.");
            }
            using (process)
            {
                if (!process.WaitForExit((int)InstallTimeout.TotalMilliseconds))
                {
                    // A retry, or closing Setup (which deletes the bootstrapper), must not race an installer that is still
                    // running. Stop it before reporting; when Windows does not let Setup stop it (it may run elevated), wait for
                    // it to finish and let the caller judge the result from the registry as usual.
                    if (StopTimedOut(process))
                    {
                        throw new SetupFailure("runtime_timeout", "Microsoft’s installer is taking too long. Try again in a few minutes.");
                    }
                    SetupLog.Write("The WebView2 bootstrapper ran past the time limit and could not be stopped; waiting for it to finish.");
                    process.WaitForExit();
                }
                // A nonzero exit with the runtime present afterwards (a newer one was already there) is still a success;
                // the caller checks the registry.
                SetupLog.Write("The WebView2 bootstrapper exited with code " + process.ExitCode + ".");
            }
        }

        // True when Setup stopped the timed-out bootstrapper; false when it had already exited or Windows refused (access denied).
        private static bool StopTimedOut(Process process)
        {
            try
            {
                process.Kill();
            }
            catch (InvalidOperationException)
            {
                return false;
            }
            catch (Win32Exception error)
            {
                SetupLog.Write("The timed-out WebView2 bootstrapper could not be stopped", error);
                return false;
            }
            process.WaitForExit();
            return true;
        }

        // True when the file has a valid Authenticode signature whose signer is Microsoft: the check Install-ResticBackuper.ps1
        // makes with Get-AuthenticodeSignature (status Valid, signer subject naming Microsoft).
        public static bool IsSignedByMicrosoft(string path, out string problem)
        {
            problem = null;
            int trust = VerifyTrust(path);
            if (trust != 0)
            {
                problem = trust == unchecked((int)0x800B0100)
                    ? "The file is not signed."
                    : "The file’s signature is not valid (code 0x" + trust.ToString("X8") + ").";
                return false;
            }
            try
            {
                X509Certificate signer = X509Certificate.CreateFromSignedFile(path);
                string subject = signer.Subject ?? string.Empty;
                if (subject.IndexOf("Microsoft Corporation", StringComparison.OrdinalIgnoreCase) < 0)
                {
                    problem = "It was not signed by Microsoft.";
                    return false;
                }
            }
            catch (Exception)
            {
                problem = "Its signer could not be read.";
                return false;
            }
            return true;
        }

        // WinVerifyTrust with the generic Authenticode policy and no user interface. Zero means the signature is valid and trusted.
        private static int VerifyTrust(string path)
        {
            Guid action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
            WintrustFileInfo fileInfo = new WintrustFileInfo();
            fileInfo.cbStruct = (uint)Marshal.SizeOf(typeof(WintrustFileInfo));
            fileInfo.pcwszFilePath = path;
            IntPtr fileInfoPointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WintrustFileInfo)));
            try
            {
                Marshal.StructureToPtr(fileInfo, fileInfoPointer, false);
                WintrustData data = new WintrustData();
                data.cbStruct = (uint)Marshal.SizeOf(typeof(WintrustData));
                data.dwUIChoice = 2;           // WTD_UI_NONE
                data.fdwRevocationChecks = 0;  // WTD_REVOKE_NONE
                data.dwUnionChoice = 1;        // WTD_CHOICE_FILE
                data.pFile = fileInfoPointer;
                data.dwStateAction = 1;        // WTD_STATEACTION_VERIFY
                data.dwProvFlags = 0x00000010; // WTD_REVOCATION_CHECK_NONE
                int result = WinVerifyTrust(IntPtr.Zero, ref action, ref data);
                data.dwStateAction = 2;        // WTD_STATEACTION_CLOSE: releases what the verify call kept
                WinVerifyTrust(IntPtr.Zero, ref action, ref data);
                return result;
            }
            finally
            {
                // Frees the path string the structure copy holds, then the structure's own memory.
                Marshal.DestroyStructure(fileInfoPointer, typeof(WintrustFileInfo));
                Marshal.FreeHGlobal(fileInfoPointer);
            }
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WintrustFileInfo
        {
            public uint cbStruct;
            [MarshalAs(UnmanagedType.LPWStr)]
            public string pcwszFilePath;
            public IntPtr hFile;
            public IntPtr pgKnownSubject;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WintrustData
        {
            public uint cbStruct;
            public IntPtr pPolicyCallbackData;
            public IntPtr pSIPClientData;
            public uint dwUIChoice;
            public uint fdwRevocationChecks;
            public uint dwUnionChoice;
            public IntPtr pFile;
            public uint dwStateAction;
            public IntPtr hWVTStateData;
            public IntPtr pwszURLReference;
            public uint dwProvFlags;
            public uint dwUIContext;
            public IntPtr pSignatureSettings;
        }

        [DllImport("wintrust.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
        private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref WintrustData data);
    }
}
