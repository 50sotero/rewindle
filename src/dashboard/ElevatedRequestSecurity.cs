using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace ResticBackuper.Dashboard
{
    // The checks every elevated request from the dashboard relies on, kept in one place so the copies cannot drift apart:
    // the command line a manager or helper is started with, the request nonce, the constant-time comparison of the
    // bindings that come back, and the permissions a protected result, progress file or state folder must have before
    // the dashboard reads it. Each rule is the strictest one any earlier copy had.
    internal static class ElevatedRequestSecurity
    {
        private const string SystemSid = "S-1-5-18";
        private const string AdministratorsSid = "S-1-5-32-544";
        private const string OwnerRightsSid = "S-1-3-4";

        // Characters that end or change an unquoted argument. CommandLineToArgvW (and so powershell.exe and python.exe)
        // splits only on space and tab, but every whitespace character is quoted so no reader can split the value.
        private static readonly char[] CharactersThatNeedQuotes = new[] { ' ', '\t', '\r', '\n', '\v', '"' };

        // What the user and OWNER RIGHTS must never hold on a protected result: any way to write, delete, take or
        // re-permission it. CreateFiles and CreateDirectories alias WriteData and AppendData; both names are kept so the
        // file and the folder meaning are visibly covered.
        private const FileSystemRights ForbiddenReaderRights = FileSystemRights.WriteData |
            FileSystemRights.CreateFiles |
            FileSystemRights.AppendData |
            FileSystemRights.CreateDirectories |
            FileSystemRights.WriteAttributes |
            FileSystemRights.WriteExtendedAttributes |
            FileSystemRights.Delete |
            FileSystemRights.DeleteSubdirectoriesAndFiles |
            FileSystemRights.ChangePermissions |
            FileSystemRights.TakeOwnership;

        // Quotes one argument so CommandLineToArgvW reads it back unchanged. A NUL would cut the command line short, so it
        // is refused, as is null: no caller has a reason to send either to an elevated process.
        internal static string QuoteWindowsArgument(string value)
        {
            if (value == null)
            {
                throw new ArgumentNullException("value");
            }
            if (value.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("A command-line argument cannot contain a NUL character.", "value");
            }
            if (value.Length > 0 && value.IndexOfAny(CharactersThatNeedQuotes) < 0)
            {
                return value;
            }
            StringBuilder result = new StringBuilder(value.Length + 2);
            result.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    // Backslashes before a quote are doubled, and the quote itself is escaped.
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                }
                else
                {
                    result.Append('\\', backslashes);
                    result.Append(character);
                }
                backslashes = 0;
            }
            // Backslashes before the closing quote would escape it, so they are doubled too.
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        // The only place an elevated command line is built: one quoted element per argument, separated by single spaces.
        internal static string BuildArgumentString(IEnumerable<string> arguments)
        {
            if (arguments == null)
            {
                throw new ArgumentNullException("arguments");
            }
            StringBuilder result = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (result.Length > 0)
                {
                    result.Append(' ');
                }
                result.Append(QuoteWindowsArgument(argument));
            }
            return result.ToString();
        }

        // 32 random bytes as 64 lowercase hexadecimal characters.
        internal static string CreateNonce()
        {
            byte[] bytes = new byte[32];
            using (RandomNumberGenerator generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(bytes);
            }
            StringBuilder value = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes)
            {
                value.Append(item.ToString("x2", CultureInfo.InvariantCulture));
            }
            return value.ToString();
        }

        // Compares in a time that depends only on the length, so a binding is never guessed one character at a time.
        // A missing value never matches, not even another missing value.
        internal static bool FixedEquals(string left, string right)
        {
            if (left == null || right == null || left.Length != right.Length)
            {
                return false;
            }
            int difference = 0;
            for (int index = 0; index < left.Length; index++)
            {
                difference |= left[index] ^ right[index];
            }
            return difference == 0;
        }

        internal static bool HasProtectedResultAcl(string path, string userSid, bool directory)
        {
            try
            {
                FileSystemSecurity security = directory
                    ? (FileSystemSecurity)new DirectoryInfo(path).GetAccessControl(
                        AccessControlSections.Owner | AccessControlSections.Access)
                    : (FileSystemSecurity)new FileInfo(path).GetAccessControl(
                        AccessControlSections.Owner | AccessControlSections.Access);
                return HasProtectedResultAcl(security, userSid);
            }
            catch
            {
                return false;
            }
        }

        // What a protected result, progress file or state folder must look like before the dashboard trusts it: owned by
        // Administrators, with a protected DACL of explicit allow entries only; Full Control for SYSTEM and
        // Administrators; read and execute, and no way to change it, for the requesting user and, optionally, OWNER
        // RIGHTS; and nobody else.
        internal static bool HasProtectedResultAcl(FileSystemSecurity security, string userSid)
        {
            try
            {
                if (security == null || string.IsNullOrEmpty(userSid))
                {
                    return false;
                }
                SecurityIdentifier owner = security.GetOwner(
                    typeof(SecurityIdentifier)) as SecurityIdentifier;
                if (owner == null || owner.Value != AdministratorsSid ||
                    !security.AreAccessRulesProtected)
                {
                    return false;
                }
                HashSet<string> required = new HashSet<string>(
                    new[] { SystemSid, AdministratorsSid, userSid },
                    StringComparer.OrdinalIgnoreCase);
                HashSet<string> allowed = new HashSet<string>(
                    required,
                    StringComparer.OrdinalIgnoreCase);
                allowed.Add(OwnerRightsSid);
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                AuthorizationRuleCollection rules = security.GetAccessRules(
                    true,
                    true,
                    typeof(SecurityIdentifier));
                foreach (FileSystemAccessRule rule in rules)
                {
                    SecurityIdentifier sid = rule.IdentityReference as SecurityIdentifier;
                    string value = sid == null ? null : sid.Value;
                    if (value == null || rule.IsInherited ||
                        rule.AccessControlType != AccessControlType.Allow ||
                        !allowed.Contains(value))
                    {
                        return false;
                    }
                    if (value == SystemSid || value == AdministratorsSid)
                    {
                        if ((rule.FileSystemRights & FileSystemRights.FullControl) !=
                            FileSystemRights.FullControl)
                        {
                            return false;
                        }
                    }
                    else if ((rule.FileSystemRights & ForbiddenReaderRights) != 0 ||
                        (rule.FileSystemRights & FileSystemRights.ReadAndExecute) !=
                            FileSystemRights.ReadAndExecute)
                    {
                        return false;
                    }
                    seen.Add(value);
                }
                return required.IsSubsetOf(seen);
            }
            catch
            {
                return false;
            }
        }
    }
}
