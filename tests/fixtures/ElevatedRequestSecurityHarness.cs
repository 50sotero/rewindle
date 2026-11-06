using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace ResticBackuper.Dashboard
{
    // Exercises the dashboard's one copy of the elevated-request checks. Everything is in memory except one throwaway file
    // in the temporary folder; nothing is elevated and no process is started.
    internal static class ElevatedRequestSecurityHarness
    {
        private static int failures;

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        private static void Check(bool condition, string message)
        {
            if (!condition)
            {
                failures++;
                Console.Error.WriteLine("FAIL: " + message);
            }
        }

        private static string Visible(string value)
        {
            return value == null
                ? "<null>"
                : value.Replace("\r", "\\r").Replace("\n", "\\n").Replace("\v", "\\v").Replace("\t", "\\t");
        }

        private static void Quotes(string value, string expected)
        {
            string actual = ElevatedRequestSecurity.QuoteWindowsArgument(value);
            Check(actual == expected, "quoting " + Visible(value) + " gave " + Visible(actual) + ", expected " + Visible(expected));
        }

        private static void Throws<T>(Action action, string message) where T : Exception
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                Check(error.GetType() == typeof(T), message + " threw " + error.GetType().Name + " instead of " + typeof(T).Name);
                return;
            }
            Check(false, message + " did not throw");
        }

        private static string[] Split(string commandLine)
        {
            int count;
            IntPtr argv = CommandLineToArgvW(commandLine, out count);
            if (argv == IntPtr.Zero)
            {
                throw new InvalidOperationException("CommandLineToArgvW failed.");
            }
            try
            {
                string[] values = new string[count];
                for (int index = 0; index < count; index++)
                {
                    values[index] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, index * IntPtr.Size));
                }
                return values;
            }
            finally
            {
                LocalFree(argv);
            }
        }

        private static void Quoting()
        {
            Quotes("plain", "plain");
            Quotes(@"C:\plain\folder\", @"C:\plain\folder\");
            Quotes(string.Empty, "\"\"");
            Quotes("a b", "\"a b\"");
            Quotes("a\tb", "\"a\tb\"");
            // CommandLineToArgvW splits only on space and tab, but every line break and vertical tab is quoted as well, so no
            // reader of the command line can split the value.
            Quotes("a\nb", "\"a\nb\"");
            Quotes("a\vb", "\"a\vb\"");
            Quotes("a\rb", "\"a\rb\"");
            Quotes(@"C:\dir with space\", "\"C:\\dir with space\\\\\"");
            Quotes("say \"hi\"", "\"say \\\"hi\\\"\"");
            Quotes("a\\\"b", "\"a\\\\\\\"b\"");
            Throws<ArgumentNullException>(delegate { ElevatedRequestSecurity.QuoteWindowsArgument(null); }, "a null argument");
            Throws<ArgumentException>(delegate { ElevatedRequestSecurity.QuoteWindowsArgument("a\0b"); }, "a NUL character");
            Throws<ArgumentNullException>(delegate { ElevatedRequestSecurity.BuildArgumentString(null); }, "a null argument list");
            Throws<ArgumentNullException>(
                delegate { ElevatedRequestSecurity.BuildArgumentString(new[] { "-File", null }); },
                "a null element in the argument list");

            string joined = ElevatedRequestSecurity.BuildArgumentString(
                new[] { "-File", @"C:\Program Files\Tool\run.ps1", string.Empty, "a\nb" });
            Check(
                joined == "-File \"C:\\Program Files\\Tool\\run.ps1\" \"\" \"a\nb\"",
                "joined command line was " + Visible(joined));

            string[] values = new[]
            {
                "plain", string.Empty, "a b", "a\tb", "a\nb", "a\vb", "a\rb", "a\r\nb", "trailing\\", @"C:\dir with space\",
                "say \"hi\"", "a\\\"b", @"\\server\share", "\"", "\\\"", "x\\\\\"y", "\\\\", " ", "\u00fcnicode \u20ac",
                "--expected-plan-id", "00000000-0000-0000-0000-000000000000"
            };
            string[] parsed = Split("program " + ElevatedRequestSecurity.BuildArgumentString(values));
            Check(parsed.Length == values.Length + 1, "round trip gave " + parsed.Length + " arguments");
            for (int index = 0; index < values.Length && index + 1 < parsed.Length; index++)
            {
                Check(
                    parsed[index + 1] == values[index],
                    "round trip of " + Visible(values[index]) + " gave " + Visible(parsed[index + 1]));
            }
        }

        private static FileSystemSecurity Descriptor(string sddl, bool directory)
        {
            FileSystemSecurity security = directory
                ? (FileSystemSecurity)new DirectorySecurity()
                : (FileSystemSecurity)new FileSecurity();
            security.SetSecurityDescriptorSddlForm(sddl);
            return security;
        }

        private static void Acl(string name, string sddl, string userSid, bool expected)
        {
            foreach (bool directory in new[] { false, true })
            {
                bool actual = ElevatedRequestSecurity.HasProtectedResultAcl(Descriptor(sddl, directory), userSid);
                Check(
                    actual == expected,
                    name + (directory ? " (folder)" : " (file)") + " was " + (actual ? "accepted" : "refused"));
            }
        }

        private static void Acls()
        {
            string user = WindowsIdentity.GetCurrent().User.Value;
            // 0x1200a9 is read and execute with synchronize: what the managers and Setup give the user and OWNER RIGHTS.
            string reader = "0x1200a9;;;" + user + ")";
            string system = "(A;;FA;;;SY)";
            string administrators = "(A;;FA;;;BA)";
            string ownerRights = "(A;;0x1200a9;;;OW)";

            Acl("the protected result", "O:BAD:P" + system + administrators + "(A;;" + reader + ownerRights, user, true);
            Acl("a result without OWNER RIGHTS", "O:BAD:P" + system + administrators + "(A;;" + reader, user, true);
            Acl(
                "a protected folder with inheritable entries",
                "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;" + reader + "(A;OICI;0x1200a9;;;OW)",
                user,
                true);

            Acl("SYSTEM with read only", "O:BAD:P(A;;FR;;;SY)" + administrators + "(A;;" + reader, user, false);
            Acl("Administrators with Modify", "O:BAD:P" + system + "(A;;0x1301bf;;;BA)(A;;" + reader, user, false);
            Acl("the user with read but no execute", "O:BAD:P" + system + administrators + "(A;;0x120089;;;" + user + ")", user, false);
            Acl("the user with write", "O:BAD:P" + system + administrators + "(A;;0x1200ab;;;" + user + ")", user, false);
            Acl("the user with append", "O:BAD:P" + system + administrators + "(A;;0x1200ad;;;" + user + ")", user, false);
            Acl("the user with delete", "O:BAD:P" + system + administrators + "(A;;0x1300a9;;;" + user + ")", user, false);
            Acl("the user with change permissions", "O:BAD:P" + system + administrators + "(A;;0x1600a9;;;" + user + ")", user, false);
            Acl("OWNER RIGHTS with write", "O:BAD:P" + system + administrators + "(A;;" + reader + "(A;;0x1200ab;;;OW)", user, false);
            Acl("an inherited SYSTEM entry", "O:BAD:P(A;ID;FA;;;SY)" + administrators + "(A;;" + reader, user, false);
            Acl("a deny entry", "O:BAD:P(D;;0x40000;;;" + user + ")" + system + administrators + "(A;;" + reader, user, false);
            Acl("another account", "O:BAD:P" + system + administrators + "(A;;" + reader + "(A;;0x1200a9;;;BU)", user, false);
            Acl("a missing user", "O:BAD:P" + system + administrators + ownerRights, user, false);
            Acl("a missing SYSTEM entry", "O:BAD:P" + administrators + "(A;;" + reader, user, false);
            Acl("a missing Administrators entry", "O:BAD:P" + system + "(A;;" + reader, user, false);
            Acl("SYSTEM as the owner", "O:SYD:P" + system + administrators + "(A;;" + reader, user, false);
            Acl("an unprotected list", "O:BAD:" + system + administrators + "(A;;" + reader, user, false);
            Acl("the protected result for another user", "O:BAD:P" + system + administrators + "(A;;" + reader, "S-1-5-32-545", false);
            Acl("no user", "O:BAD:P" + system + administrators + "(A;;" + reader, null, false);
            Acl("an empty user", "O:BAD:P" + system + administrators + "(A;;" + reader, string.Empty, false);
            Check(!ElevatedRequestSecurity.HasProtectedResultAcl((FileSystemSecurity)null, user), "a missing descriptor was accepted");

            string missing = Path.Combine(Path.GetTempPath(), "rewindle-acl-" + Guid.NewGuid().ToString("N"));
            Check(!ElevatedRequestSecurity.HasProtectedResultAcl(missing, user, false), "a missing file was accepted");
            Check(!ElevatedRequestSecurity.HasProtectedResultAcl(missing, user, true), "a missing folder was accepted");
            string ordinary = Path.GetTempFileName();
            try
            {
                // A file this process made inherits the temporary folder's permissions and is owned by the user.
                Check(!ElevatedRequestSecurity.HasProtectedResultAcl(ordinary, user, false), "an ordinary file was accepted");
            }
            finally
            {
                File.Delete(ordinary);
            }
        }

        private static void Nonces()
        {
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            for (int round = 0; round < 64; round++)
            {
                string nonce = ElevatedRequestSecurity.CreateNonce();
                bool hex = nonce.Length == 64;
                foreach (char character in nonce)
                {
                    hex &= (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f');
                }
                Check(hex, "a nonce was not 64 lowercase hexadecimal characters: " + nonce);
                Check(seen.Add(nonce), "a nonce repeated");
            }

            Check(ElevatedRequestSecurity.FixedEquals("abc", "abc"), "equal values did not match");
            Check(ElevatedRequestSecurity.FixedEquals(string.Empty, string.Empty), "two empty values did not match");
            Check(!ElevatedRequestSecurity.FixedEquals("abc", "abd"), "different values matched");
            Check(!ElevatedRequestSecurity.FixedEquals("ABC", "abc"), "the comparison ignored case");
            Check(!ElevatedRequestSecurity.FixedEquals("abc", "ab"), "values of different lengths matched");
            Check(!ElevatedRequestSecurity.FixedEquals(null, "abc"), "a missing value matched");
            Check(!ElevatedRequestSecurity.FixedEquals("abc", null), "a missing value matched");
            Check(!ElevatedRequestSecurity.FixedEquals(null, null), "two missing values matched");
        }

        public static int Main()
        {
            Quoting();
            Acls();
            Nonces();
            if (failures > 0)
            {
                Console.Error.WriteLine(failures + " elevated request security checks failed.");
                return 1;
            }
            Console.WriteLine("Elevated request security checks passed.");
            return 0;
        }
    }
}
