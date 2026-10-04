using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Rewindle.Setup
{
    // The folders Setup works in: %TEMP%\RewindleSetup-<guid>, made by this (normal, not elevated) process and so owned by the
    // person running it. The release bundle (the installer script and the payload it copies) and the WebView2 libraries are
    // unpacked from the program's own resources into it (the wizard's pages are not: see WebContent), the installer's progress
    // files go in sibling folders of the same kind, and everything is deleted when Setup exits.
    internal sealed class SetupWorkspace : IDisposable
    {
        public const string BundleResource = "REWINDLE_BUNDLE";
        public const string WebResource = "REWINDLE_SETUP_WEB";
        public const string FolderPrefix = "RewindleSetup-";

        private static readonly Regex FolderPattern = new Regex("^RewindleSetup-[0-9a-f]{32}$", RegexOptions.CultureInvariant);
        private static readonly TimeSpan StaleAfter = TimeSpan.FromHours(6);

        // The WebView2 libraries and the names they are unpacked as. WebView2Loader.dll is also placed where the managed
        // library looks for it in the layouts the SDK's own packages use, so it is found whichever one it asks for.
        public static readonly string[][] WebViewLibraries =
        {
            new string[] { "REWINDLE_WEBVIEW2_CORE", "Microsoft.Web.WebView2.Core.dll" },
            new string[] { "REWINDLE_WEBVIEW2_WPF", "Microsoft.Web.WebView2.Wpf.dll" },
            new string[] { "REWINDLE_WEBVIEW2_LOADER", "WebView2Loader.dll" }
        };

        private readonly Func<string, Stream> openResource;
        private readonly string parent;
        private readonly object gate = new object();
        private readonly List<string> extraFolders = new List<string>();
        private Task bundleTask;
        private Dictionary<string, string> bundleHashes;
        private ExclusionRules exclusions;
        private WebContent web;
        // The unpacked WebView2 libraries, held open from just after they are written until this workspace is disposed.
        private readonly List<FileStream> heldLibraries = new List<FileStream>();
        private string resolvedLibraryFolder;

        // Set only by the test that changes a library between its unpacking and its check.
        internal Action<string> AfterLibraryWritten;

        public readonly string Root;

        public SetupWorkspace(Func<string, Stream> openResource, string parentFolder)
        {
            this.openResource = openResource;
            parent = parentFolder;
            Root = Path.Combine(parentFolder, NewFolderName());
            Directory.CreateDirectory(Root);
        }

        public static SetupWorkspace Create()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            return new SetupWorkspace(delegate(string name) { return assembly.GetManifestResourceStream(name); }, Path.GetTempPath());
        }

        private static string NewFolderName()
        {
            return FolderPrefix + Guid.NewGuid().ToString("N");
        }

        public string BundleFolder
        {
            get { return Path.Combine(Root, "bundle"); }
        }

        public string LibraryFolder
        {
            get { return Path.Combine(Root, "bin"); }
        }

        public string WebViewDataFolder
        {
            get { return Path.Combine(Root, "WebView2"); }
        }

        public string PlansFolder
        {
            get { return Path.Combine(Root, "plans"); }
        }

        public string InstallScriptPath
        {
            get { return Path.Combine(BundleFolder, InstallerContract.InstallScript); }
        }

        // The uninstaller of the release this setup carries: the fallback when no installed copy is there to run.
        public string BundledUninstallScriptPath
        {
            get { return Path.Combine(BundleFolder, "payload", InstallerContract.UninstallScript); }
        }

        // The folder the WebView2 libraries are loaded from: LibraryFolder's resolved path (see HeldFile), which the held libraries
        // keep naming the same folder. Set by ExtractLibraries.
        public string ResolvedLibraryFolder
        {
            get
            {
                lock (gate)
                {
                    if (resolvedLibraryFolder == null)
                    {
                        throw new InvalidOperationException("The WebView2 libraries have not been unpacked.");
                    }
                    return resolvedLibraryFolder;
                }
            }
        }

        // The WebView2 libraries, ready to load. Called before anything touches a WebView2 type. They are loaded later, when a
        // WebView2 type is first needed, from the person's own temporary folder, where another program running as them could swap
        // one meanwhile. So each is held open from just after it is written until Setup ends (see HeldFile), checked through that
        // handle against the copy inside this program, and loaded from ResolvedLibraryFolder.
        public void ExtractLibraries()
        {
            Directory.CreateDirectory(LibraryFolder);
            foreach (string[] library in WebViewLibraries)
            {
                HoldLibrary(library[0], library[1]);
            }
            // The layouts of the SDK's NuGet package, for a loader lookup that is relative to the managed library.
            foreach (string relative in new string[] { "x64", Path.Combine("runtimes", "win-x64", "native") })
            {
                Directory.CreateDirectory(Path.Combine(LibraryFolder, relative));
                HoldLibrary("REWINDLE_WEBVIEW2_LOADER", Path.Combine(relative, "WebView2Loader.dll"));
            }
        }

        private void HoldLibrary(string resource, string relative)
        {
            byte[] content;
            using (Stream source = OpenRequired(resource))
            using (MemoryStream copy = new MemoryStream())
            {
                source.CopyTo(copy);
                content = copy.ToArray();
            }
            string destination = Path.Combine(LibraryFolder, relative);
            // CreateNew: nothing may be waiting under that name in the folder this program has just made.
            using (FileStream target = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                target.Write(content, 0, content.Length);
            }
            if (AfterLibraryWritten != null)
            {
                AfterLibraryWritten(destination);
            }
            FileStream held = HeldFile.Open(destination);
            try
            {
                string resolved = HeldFile.ResolvedPath(held.SafeFileHandle);
                bool same;
                using (SHA256 sha = SHA256.Create())
                {
                    same = held.Length == content.Length &&
                        Convert.ToBase64String(sha.ComputeHash(held)) == Convert.ToBase64String(sha.ComputeHash(content));
                }
                string suffix = Path.DirectorySeparatorChar + relative;
                string folder = resolved != null && resolved.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
                    ? resolved.Substring(0, resolved.Length - suffix.Length)
                    : null;
                lock (gate)
                {
                    if (resolvedLibraryFolder == null && folder != null)
                    {
                        resolvedLibraryFolder = folder;
                    }
                    if (!same || folder == null || !string.Equals(folder, resolvedLibraryFolder, StringComparison.OrdinalIgnoreCase))
                    {
                        SetupLog.Write("An unpacked WebView2 library did not match this program's copy: " + destination + " (" + (resolved ?? "no resolved path") + ")");
                        throw new InvalidDataException("Another program changed Setup’s files while it was starting. Close other programs and run Setup again.");
                    }
                    heldLibraries.Add(held);
                }
            }
            catch
            {
                held.Dispose();
                throw;
            }
        }

        // The wizard's pages, read into memory from this program's own resources, to be served to the web view from there.
        public void ReadWeb()
        {
            WebContent content;
            using (Stream resource = OpenRequired(WebResource))
            {
                content = WebContent.Read(resource);
            }
            lock (gate)
            {
                web = content;
            }
        }

        public WebContent Web
        {
            get
            {
                lock (gate)
                {
                    if (web == null)
                    {
                        throw new InvalidOperationException("The wizard's pages have not been read.");
                    }
                    return web;
                }
            }
        }

        // Unpacks the release bundle in the background (it is tens of megabytes, and the first page does not need it), once.
        // A second call returns the same task, unless the first failed, in which case it starts again from an empty folder.
        public Task EnsureBundleExtracted()
        {
            lock (gate)
            {
                if (bundleTask == null || bundleTask.IsFaulted || bundleTask.IsCanceled)
                {
                    bundleTask = Task.Factory.StartNew(new Action(ExtractBundle), TaskCreationOptions.LongRunning);
                }
                return bundleTask;
            }
        }

        private void ExtractBundle()
        {
            DeleteTree(BundleFolder);
            Dictionary<string, string> hashes;
            using (Stream resource = OpenRequired(BundleResource))
            {
                hashes = SafeZip.Extract(resource, BundleFolder);
            }
            if (!File.Exists(InstallScriptPath))
            {
                throw new InvalidDataException("The embedded Rewindle installer is incomplete.");
            }
            lock (gate)
            {
                bundleHashes = hashes;
            }
        }

        // The folders the backup leaves out, from the excludes.txt in this program's own bundle (read from the embedded ZIP, so it
        // doesn't wait for the bundle to be unpacked). Read once.
        public ExclusionRules ReadExclusions()
        {
            lock (gate)
            {
                if (exclusions != null)
                {
                    return exclusions;
                }
            }
            ExclusionRules rules = ExclusionRules.None;
            using (Stream resource = OpenRequired(BundleResource))
            using (System.IO.Compression.ZipArchive archive = new System.IO.Compression.ZipArchive(resource, System.IO.Compression.ZipArchiveMode.Read, false))
            {
                System.IO.Compression.ZipArchiveEntry entry = archive.GetEntry("payload/excludes.txt");
                if (entry != null && entry.Length < 1024 * 1024)
                {
                    List<string> lines = new List<string>();
                    using (StreamReader reader = new StreamReader(entry.Open(), new System.Text.UTF8Encoding(false)))
                    {
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            lines.Add(line);
                        }
                    }
                    rules = ExclusionRules.Parse(lines);
                }
            }
            lock (gate)
            {
                exclusions = rules;
            }
            return rules;
        }

        // The SHA-256 a bundle file had when this program unpacked it from its own resources (relative path, backslashes).
        // The unpacked copy sits in the person's temp folder and can change afterwards; an elevated run checks against this.
        public string BundleSha256(string relativePath)
        {
            string hash;
            lock (gate)
            {
                if (bundleHashes == null || !bundleHashes.TryGetValue(relativePath, out hash))
                {
                    throw new InvalidOperationException("Setup has no record of " + relativePath + " from its own files.");
                }
            }
            return hash;
        }

        // A new folder for one install attempt's progress file, named like this one and owned by the same person: the installer
        // (elevated) writes to it, this program (not) reads it. Each attempt gets its own, so an old file is never read as new.
        public string CreateProgressFolder()
        {
            string folder = Path.Combine(parent, NewFolderName());
            Directory.CreateDirectory(folder);
            lock (gate)
            {
                extraFolders.Add(folder);
            }
            return folder;
        }

        private Stream OpenRequired(string name)
        {
            Stream stream = openResource(name);
            if (stream == null)
            {
                throw new InvalidDataException("The embedded " + name + " is missing from this copy of Setup.");
            }
            return stream;
        }

        public void Dispose()
        {
            List<string> folders = new List<string>();
            List<FileStream> held;
            lock (gate)
            {
                folders.AddRange(extraFolders);
                extraFolders.Clear();
                held = new List<FileStream>(heldLibraries);
                heldLibraries.Clear();
            }
            foreach (FileStream library in held)
            {
                library.Dispose();
            }
            folders.Add(Root);
            foreach (string folder in folders)
            {
                DeleteTree(folder);
            }
        }

        // Deletes a folder this program made, trying again for a moment: the web view's own processes can still be holding a
        // file in it just after the window closed. Whatever remains is picked up by SweepStale on the next run.
        public static void DeleteTree(string folder)
        {
            for (int attempt = 0; attempt < 8; attempt++)
            {
                try
                {
                    if (!Directory.Exists(folder))
                    {
                        return;
                    }
                    ClearReadOnly(folder);
                    Directory.Delete(folder, true);
                    return;
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
                Thread.Sleep(250);
            }
        }

        private static void ClearReadOnly(string folder)
        {
            foreach (string file in Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories))
            {
                try
                {
                    FileAttributes attributes = File.GetAttributes(file);
                    if ((attributes & FileAttributes.ReadOnly) != 0)
                    {
                        File.SetAttributes(file, attributes & ~FileAttributes.ReadOnly);
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

        // Removes folders an earlier run left behind (it was killed, or a file was still in use when it cleaned up). Only
        // folders named exactly like Setup's own, that are not links and have not been touched for hours. Called once Setup
        // holds the single-instance lock, so no other copy of Setup for this person is using one.
        public static void SweepStale(string parentFolder)
        {
            try
            {
                foreach (string folder in Directory.EnumerateDirectories(parentFolder, FolderPrefix + "*"))
                {
                    string name = Path.GetFileName(folder);
                    if (!FolderPattern.IsMatch(name))
                    {
                        continue;
                    }
                    DirectoryInfo info = new DirectoryInfo(folder);
                    if ((info.Attributes & FileAttributes.ReparsePoint) != 0 ||
                        DateTime.UtcNow - info.LastWriteTimeUtc < StaleAfter)
                    {
                        continue;
                    }
                    DeleteTree(folder);
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
