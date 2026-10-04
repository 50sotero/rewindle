using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace Rewindle.Setup
{
    // Follows the installer's progress file (one JSON object per line, appended by an elevated process while this one reads).
    // It copes with everything a file being written by someone else does: it may not exist yet, a line may be half written when
    // it is read, a multi-byte character may be split across two reads, the file starts with a byte-order mark when PowerShell
    // wrote it, and lines end with CR LF. Only whole lines are ever returned, so the caller never sees half of one.
    internal sealed class ProgressTail
    {
        private readonly string path;
        private readonly bool requireProtectedOwner;
        private long position;
        private readonly List<byte> pending = new List<byte>();
        private bool discardingOversizedLine;

        public ProgressTail(string path)
            : this(path, false)
        {
        }

        // requireProtectedOwner: the file is written by an elevated installer, which makes Administrators its owner and lets only
        // Administrators and SYSTEM change it. Its folder belongs to the person, so another program running as them could swap
        // the file; one not owned that way is never read, and Untrusted says so.
        public ProgressTail(string path, bool requireProtectedOwner)
        {
            if (string.IsNullOrEmpty(path))
            {
                throw new ArgumentException("A progress file path is required.", "path");
            }
            this.path = path;
            this.requireProtectedOwner = requireProtectedOwner;
        }

        // True once the file was found not to be owned by Administrators or SYSTEM: nothing more is read from it.
        public bool Untrusted { get; private set; }

        // The whole lines written since the last call. An empty list when the file is not there yet or nothing new was added.
        public List<string> ReadNewLines()
        {
            List<string> lines = new List<string>();
            byte[] chunk;
            try
            {
                chunk = ReadAvailable();
            }
            catch (IOException)
            {
                // Held open exclusively for a moment, or being replaced: the next poll tries again.
                return lines;
            }
            catch (UnauthorizedAccessException)
            {
                return lines;
            }
            if (chunk == null || chunk.Length == 0)
            {
                return lines;
            }

            foreach (byte value in chunk)
            {
                if (value == (byte)'\n')
                {
                    if (!discardingOversizedLine)
                    {
                        AddLine(lines);
                    }
                    pending.Clear();
                    discardingOversizedLine = false;
                    continue;
                }
                if (discardingOversizedLine)
                {
                    continue;
                }
                if (pending.Count >= InstallerContract.MaximumProgressLineBytes)
                {
                    // A line this long is not a progress line. It is dropped up to its end, and the lines after it still count.
                    pending.Clear();
                    discardingOversizedLine = true;
                    continue;
                }
                pending.Add(value);
            }
            return lines;
        }

        // Called once the installer has exited: the lines still unread, and a last line the installer never ended with a newline.
        public List<string> Finish()
        {
            List<string> lines = ReadNewLines();
            if (!discardingOversizedLine && pending.Count > 0)
            {
                AddLine(lines);
            }
            pending.Clear();
            discardingOversizedLine = false;
            return lines;
        }

        private void AddLine(List<string> lines)
        {
            byte[] bytes = pending.ToArray();
            int start = 0;
            // The byte-order mark PowerShell's UTF-8 encoding writes at the start of a file.
            if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            {
                start = 3;
            }
            int length = bytes.Length - start;
            if (length > 0 && bytes[bytes.Length - 1] == (byte)'\r')
            {
                length--;
            }
            if (length <= 0)
            {
                return;
            }
            string text = new UTF8Encoding(false).GetString(bytes, start, length).Trim();
            if (text.Length > 0)
            {
                lines.Add(text);
            }
        }

        private byte[] ReadAvailable()
        {
            if (Untrusted || !File.Exists(path))
            {
                return null;
            }
            using (FileStream stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                if (requireProtectedOwner)
                {
                    IdentityReference owner = stream.GetAccessControl().GetOwner(typeof(SecurityIdentifier));
                    string sid = owner == null ? string.Empty : owner.Value;
                    if (sid != "S-1-5-32-544" && sid != "S-1-5-18")
                    {
                        Untrusted = true;
                        return null;
                    }
                }
                long length = stream.Length;
                if (length < position)
                {
                    // The file was replaced by a shorter one: start over with it.
                    position = 0;
                    pending.Clear();
                    discardingOversizedLine = false;
                }
                if (length == position)
                {
                    return null;
                }
                stream.Seek(position, SeekOrigin.Begin);
                long wanted = Math.Min(length - position, 4 * 1024 * 1024);
                byte[] buffer = new byte[wanted];
                int total = 0;
                while (total < buffer.Length)
                {
                    int read = stream.Read(buffer, total, buffer.Length - total);
                    if (read <= 0)
                    {
                        break;
                    }
                    total += read;
                }
                position += total;
                if (total == buffer.Length)
                {
                    return buffer;
                }
                byte[] shorter = new byte[total];
                Array.Copy(buffer, shorter, total);
                return shorter;
            }
        }
    }
}
