using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

// The version attributes come from the repository's VERSION file: build\Build-Release.ps1 compiles this file together with
// the version source it generates, so the setup program carries the version of the bundle it installs.
[assembly: AssemblyTitle("Rewindle Setup")]
[assembly: AssemblyDescription("Install Rewindle encrypted backup and verified recovery")]
[assembly: AssemblyProduct("Rewindle")]
[assembly: AssemblyCompany("Victor Sotero")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Victor Sotero")]

namespace Rewindle.Setup
{
    internal static class Program
    {
        private const string BundleResourceName = "REWINDLE_BUNDLE";

        private static int Main()
        {
            string extractionRoot = Path.Combine(
                Path.GetTempPath(),
                "Rewindle-Setup-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(extractionRoot);
                ExtractBundle(extractionRoot);
                string installer = Path.Combine(extractionRoot, "Install.cmd");
                if (!File.Exists(installer))
                {
                    throw new InvalidDataException("The embedded Rewindle installer is incomplete.");
                }

                ProcessStartInfo startInfo = new ProcessStartInfo
                {
                    FileName = installer,
                    WorkingDirectory = extractionRoot,
                    UseShellExecute = true
                };
                using (Process process = Process.Start(startInfo))
                {
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    "Rewindle setup could not start.\n\n" + error.Message,
                    "Rewindle setup",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                try
                {
                    if (Directory.Exists(extractionRoot))
                    {
                        Directory.Delete(extractionRoot, true);
                    }
                }
                catch
                {
                    // The installer may still have a file open after a failed launch.
                }
            }
        }

        private static void ExtractBundle(string destinationRoot)
        {
            using (Stream resource = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(BundleResourceName))
            {
                if (resource == null)
                {
                    throw new InvalidDataException("The embedded Rewindle payload is missing.");
                }
                using (ZipArchive archive = new ZipArchive(resource, ZipArchiveMode.Read, false))
                {
                    HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    string root = Path.GetFullPath(destinationRoot).TrimEnd(Path.DirectorySeparatorChar) +
                        Path.DirectorySeparatorChar;
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string relative = (entry.FullName ?? string.Empty).Replace('/', Path.DirectorySeparatorChar);
                        if (string.IsNullOrWhiteSpace(relative) ||
                            Path.IsPathRooted(relative) ||
                            relative.IndexOf('\0') >= 0 ||
                            relative.Split(Path.DirectorySeparatorChar).Length == 0 ||
                            Array.IndexOf(relative.Split(Path.DirectorySeparatorChar), "..") >= 0 ||
                            relative.IndexOf(':') >= 0 ||
                            !seen.Add(relative))
                        {
                            throw new InvalidDataException(
                                "The embedded Rewindle payload contains an unsafe path.");
                        }

                        string path = Path.GetFullPath(Path.Combine(destinationRoot, relative));
                        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                        {
                            throw new InvalidDataException(
                                "The embedded Rewindle payload escapes its temporary directory.");
                        }
                        if (entry.FullName.EndsWith("/", StringComparison.Ordinal))
                        {
                            Directory.CreateDirectory(path);
                            continue;
                        }

                        string parent = Path.GetDirectoryName(path);
                        if (!string.IsNullOrEmpty(parent))
                        {
                            Directory.CreateDirectory(parent);
                        }
                        using (Stream source = entry.Open())
                        using (FileStream target = new FileStream(
                            path,
                            FileMode.CreateNew,
                            FileAccess.Write,
                            FileShare.None))
                        {
                            source.CopyTo(target);
                        }
                    }
                }
            }
        }
    }
}
