using System;
using System.Collections.Generic;

namespace Rewindle.Setup
{
    // The folders the installed backup leaves out entirely, so that measuring a source (its size and its online-only files)
    // agrees with what the backup's own preflight looks at. A port of _literal_directory_exclusion_rules and
    // _directory_is_definitely_excluded in src/restic_common.py: only rules whose components are all literal, apart from one
    // whole-component "**", prune a folder; anything more complex is not used, and those folders are measured as usual.
    internal sealed class ExclusionRules
    {
        public static readonly ExclusionRules None = new ExclusionRules(new List<string[]>(), new List<string[]>(), new List<KeyValuePair<string[], string[]>>());

        private readonly List<string[]> suffixes;
        private readonly List<string[]> exact;
        private readonly List<KeyValuePair<string[], string[]>> anchored;

        private ExclusionRules(List<string[]> suffixes, List<string[]> exact, List<KeyValuePair<string[], string[]>> anchored)
        {
            this.suffixes = suffixes;
            this.exact = exact;
            this.anchored = anchored;
        }

        // The lines of an excludes.txt.
        public static ExclusionRules Parse(IEnumerable<string> lines)
        {
            List<string[]> suffixes = new List<string[]>();
            List<string[]> exact = new List<string[]>();
            List<KeyValuePair<string[], string[]>> anchored = new List<KeyValuePair<string[], string[]>>();
            foreach (string raw in lines)
            {
                if (raw == null || raw.Trim().Length == 0 || raw.TrimStart().StartsWith("#", StringComparison.Ordinal))
                {
                    continue;
                }
                string pattern = raw.Trim().Replace('\\', '/').TrimEnd('/');
                if (pattern.StartsWith("!", StringComparison.Ordinal))
                {
                    continue;
                }
                string[] parts = Parts(pattern);
                if (parts.Length == 0)
                {
                    continue;
                }
                int wildcard = -1;
                bool usable = true;
                for (int index = 0; index < parts.Length; index++)
                {
                    if (parts[index] == "**")
                    {
                        if (wildcard >= 0)
                        {
                            usable = false;
                        }
                        wildcard = index;
                    }
                    else if (parts[index].IndexOfAny(new char[] { '*', '?', '[' }) >= 0)
                    {
                        usable = false;
                    }
                }
                if (!usable)
                {
                    continue;
                }
                if (wildcard >= 0)
                {
                    string[] prefix = Slice(parts, 0, wildcard);
                    string[] suffix = Slice(parts, wildcard + 1, parts.Length - wildcard - 1);
                    if (suffix.Length == 0)
                    {
                        continue;
                    }
                    if (prefix.Length > 0)
                    {
                        anchored.Add(new KeyValuePair<string[], string[]>(prefix, suffix));
                    }
                    else
                    {
                        suffixes.Add(suffix);
                    }
                    continue;
                }
                bool driveRooted = parts[0].Length == 2 && parts[0][1] == ':' && parts[0][0] >= 'a' && parts[0][0] <= 'z';
                if (driveRooted || pattern.StartsWith("//", StringComparison.Ordinal))
                {
                    exact.Add(parts);
                }
            }
            return new ExclusionRules(suffixes, exact, anchored);
        }

        // Whether the backup leaves this folder (by its full path) out entirely.
        public bool IsDefinitelyExcluded(string directoryPath)
        {
            if (suffixes.Count == 0 && exact.Count == 0 && anchored.Count == 0)
            {
                return false;
            }
            string[] parts = Parts(directoryPath.Replace('\\', '/').TrimEnd('/'));
            foreach (string[] rule in exact)
            {
                if (parts.Length == rule.Length && SameParts(parts, 0, rule))
                {
                    return true;
                }
            }
            foreach (string[] suffix in suffixes)
            {
                if (parts.Length >= suffix.Length && SameParts(parts, parts.Length - suffix.Length, suffix))
                {
                    return true;
                }
            }
            foreach (KeyValuePair<string[], string[]> rule in anchored)
            {
                if (parts.Length >= rule.Key.Length + rule.Value.Length &&
                    SameParts(parts, 0, rule.Key) &&
                    SameParts(parts, parts.Length - rule.Value.Length, rule.Value))
                {
                    return true;
                }
            }
            return false;
        }

        private static string[] Parts(string path)
        {
            List<string> parts = new List<string>();
            foreach (string component in path.Split('/'))
            {
                if (component.Length > 0)
                {
                    parts.Add(component.ToLowerInvariant());
                }
            }
            return parts.ToArray();
        }

        // parts, from start on, begins with expected.
        private static bool SameParts(string[] parts, int start, string[] expected)
        {
            if (start < 0 || start + expected.Length > parts.Length)
            {
                return false;
            }
            for (int index = 0; index < expected.Length; index++)
            {
                if (!string.Equals(parts[start + index], expected[index], StringComparison.Ordinal))
                {
                    return false;
                }
            }
            return true;
        }

        private static string[] Slice(string[] values, int start, int count)
        {
            string[] slice = new string[count];
            Array.Copy(values, start, slice, 0, count);
            return slice;
        }
    }
}
