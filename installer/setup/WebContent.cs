using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;

namespace Rewindle.Setup
{
    // The wizard's pages, read from the ZIP inside this program into memory and served to the web view from there. Nothing is
    // written to disk: the page's origin is the one the message bridge trusts, and a copy in the person's temporary folder could
    // be swapped by another program running as them. Names are refused as SafeZip refuses them (rooted, drive-qualified, "..",
    // duplicates, names that differ only by case), and the archive must stay far smaller than anything Rewindle ships.
    internal sealed class WebContent
    {
        public const string StartPage = "setup.html";
        private const int MaximumEntries = 2000;
        private const long MaximumTotalBytes = 64L * 1024L * 1024L;

        private readonly Dictionary<string, byte[]> files;

        private WebContent(Dictionary<string, byte[]> files)
        {
            this.files = files;
        }

        public static WebContent Read(Stream archiveStream)
        {
            if (archiveStream == null)
            {
                throw new ArgumentNullException("archiveStream");
            }
            Dictionary<string, byte[]> files = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
            long total = 0;
            using (ZipArchive archive = new ZipArchive(archiveStream, ZipArchiveMode.Read, false))
            {
                if (archive.Entries.Count > MaximumEntries)
                {
                    throw new InvalidDataException("The embedded wizard pages have more files than expected.");
                }
                foreach (ZipArchiveEntry entry in archive.Entries)
                {
                    string name = (entry.FullName ?? string.Empty).Replace('\\', '/');
                    if (name.EndsWith("/", StringComparison.Ordinal))
                    {
                        continue;
                    }
                    if (name.Length == 0 || name.StartsWith("/", StringComparison.Ordinal) || name.IndexOf('\0') >= 0 || name.IndexOf(':') >= 0 ||
                        Array.IndexOf(name.Split('/'), "..") >= 0 || Array.IndexOf(name.Split('/'), string.Empty) >= 0 || files.ContainsKey(name))
                    {
                        throw new InvalidDataException("The embedded wizard pages contain an unsafe path.");
                    }
                    total += entry.Length;
                    if (total > MaximumTotalBytes)
                    {
                        throw new InvalidDataException("The embedded wizard pages are larger than expected.");
                    }
                    using (Stream source = entry.Open())
                    using (MemoryStream copy = new MemoryStream())
                    {
                        source.CopyTo(copy);
                        files[name] = copy.ToArray();
                    }
                }
            }
            if (!files.ContainsKey(StartPage))
            {
                throw new InvalidDataException("The embedded wizard pages are incomplete.");
            }
            return new WebContent(files);
        }

        public IEnumerable<string> Names
        {
            get { return files.Keys; }
        }

        // The file a request's path names (the URL's path, as sent: "/assets/index.js"), with its content type; false when there is
        // no such file. "/" is the start page.
        public bool TryGet(string absolutePath, out byte[] content, out string contentType)
        {
            content = null;
            contentType = null;
            string name;
            try
            {
                name = Uri.UnescapeDataString(absolutePath ?? string.Empty).TrimStart('/');
            }
            catch (UriFormatException)
            {
                return false;
            }
            if (name.Length == 0)
            {
                name = StartPage;
            }
            if (!files.TryGetValue(name, out content))
            {
                return false;
            }
            contentType = ContentTypeOf(name);
            return true;
        }

        public static string ContentTypeOf(string name)
        {
            switch (Path.GetExtension(name).ToLowerInvariant())
            {
                case ".html": return "text/html; charset=utf-8";
                case ".js":
                case ".mjs": return "text/javascript; charset=utf-8";
                case ".css": return "text/css; charset=utf-8";
                case ".json": return "application/json; charset=utf-8";
                case ".svg": return "image/svg+xml";
                case ".png": return "image/png";
                case ".ico": return "image/x-icon";
                case ".woff2": return "font/woff2";
                case ".woff": return "font/woff";
                case ".txt": return "text/plain; charset=utf-8";
                default: return "application/octet-stream";
            }
        }
    }
}
