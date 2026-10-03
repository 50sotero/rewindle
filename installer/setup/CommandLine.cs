using System;
using System.Collections.Generic;
using System.Text;

namespace Rewindle.Setup
{
    // Builds a Windows command line from an array of arguments, with the quoting rules CommandLineToArgvW (and so
    // powershell.exe) reads back. Nothing a person chose is ever pasted into a command line any other way: every value is one
    // element of an argument array, and this is the only place those elements become text.
    internal static class CommandLine
    {
        public static string Quote(string argument)
        {
            if (argument == null)
            {
                throw new ArgumentNullException("argument");
            }
            if (argument.IndexOf('\0') >= 0)
            {
                throw new ArgumentException("A command-line argument cannot contain a NUL character.");
            }
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\r', '\n', '\v', '"' }) < 0)
            {
                return argument;
            }

            StringBuilder builder = new StringBuilder(argument.Length + 2);
            builder.Append('"');
            int backslashes = 0;
            foreach (char character in argument)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    // Backslashes before a quote are doubled, and the quote itself is escaped.
                    builder.Append('\\', backslashes * 2 + 1);
                    builder.Append('"');
                }
                else
                {
                    builder.Append('\\', backslashes);
                    builder.Append(character);
                }
                backslashes = 0;
            }
            // Backslashes before the closing quote would escape it, so they are doubled too.
            builder.Append('\\', backslashes * 2);
            builder.Append('"');
            return builder.ToString();
        }

        public static string Join(IEnumerable<string> arguments)
        {
            if (arguments == null)
            {
                throw new ArgumentNullException("arguments");
            }
            StringBuilder builder = new StringBuilder();
            foreach (string argument in arguments)
            {
                if (builder.Length > 0)
                {
                    builder.Append(' ');
                }
                builder.Append(Quote(argument));
            }
            return builder.ToString();
        }
    }
}
