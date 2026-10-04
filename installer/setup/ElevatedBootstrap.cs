using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Rewindle.Setup
{
    // What an elevated run of a script from this setup's own unpacked bundle needs. The bundle sits in the person's temp
    // folder, which any program they run can change, also while Windows shows its permission prompt; so the elevated process
    // does not run it from there (see ElevatedBootstrap).
    internal sealed class BundleLaunch
    {
        // The unpacked bundle folder.
        public string SourceRoot;
        // Files or folders, relative to SourceRoot, that the elevated run copies into its protected folder.
        public string[] StagedItems;
        // Files, relative to SourceRoot, whose copies must match the SHA-256 this program took while unpacking its own resources.
        // Everything else staged must be covered by the staged script's own checks (the installer verifies the whole payload
        // against payload-manifest.json, which is one of these).
        public string[] CheckedFiles;
        // The script to run, relative to SourceRoot.
        public string ScriptRelativePath;
        // The SHA-256 a bundle file had when it was unpacked (SetupWorkspace.BundleSha256).
        public Func<string, string> ExpectedSha256;
    }

    // Wraps "powershell.exe -File <bundle script> <arguments>" into a short elevated bootstrap passed as -EncodedCommand, which
    // a program running as the person cannot change once Windows has started the process. The bootstrap:
    //   1. creates a new folder under ProgramData that only Administrators and SYSTEM can change (protected access list, set as
    //      the folder is created, so there is no moment when it is open);
    //   2. copies the staged items into it, refusing links;
    //   3. checks the copies of CheckedFiles, and of the argument file, against SHA-256 values embedded in the bootstrap;
    //   4. runs the script from the protected folder with the exact command line this program built (CommandLine.Join), and
    //      exits with its exit code; on any refusal it exits with BootstrapRefused and runs nothing;
    //   5. removes the protected folder, and, before making its own, removes ones an interrupted run left (over a day old, owned
    //      by Administrators or SYSTEM, and not links).
    internal static class ElevatedBootstrap
    {
        public const int BootstrapRefused = 70;
        public const string ArgumentFileName = "arguments.txt";
        public const string StagingPrefix = "RewindleSetup-";

        // The arguments for an elevated powershell.exe that runs the bootstrap. The script's own arguments (everything after
        // -File <script>) go into an argument file next to the progress file, as one command line; the bootstrap checks it.
        public static List<string> Wrap(IList<string> powershellArguments, BundleLaunch launch)
        {
            if (launch == null)
            {
                throw new ArgumentNullException("launch");
            }
            int file = IndexOf(powershellArguments, "-File");
            int progress = IndexOf(powershellArguments, "-ProgressPath");
            if (file < 0 || file + 1 >= powershellArguments.Count || progress < 0 || progress + 1 >= powershellArguments.Count)
            {
                throw new ArgumentException("The installer's arguments are incomplete.", "powershellArguments");
            }
            List<string> scriptArguments = new List<string>();
            for (int index = file + 2; index < powershellArguments.Count; index++)
            {
                scriptArguments.Add(powershellArguments[index]);
            }
            byte[] tail = new UTF8Encoding(false).GetBytes(CommandLine.Join(scriptArguments));
            string argumentFile = Path.Combine(Path.GetDirectoryName(powershellArguments[progress + 1]), ArgumentFileName);
            using (FileStream stream = new FileStream(argumentFile, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
            {
                stream.Write(tail, 0, tail.Length);
            }
            string script = BuildScript(launch, argumentFile, Sha256(tail));
            List<string> arguments = new List<string>();
            arguments.Add("-NoProfile");
            arguments.Add("-NonInteractive");
            arguments.Add("-ExecutionPolicy");
            arguments.Add("Bypass");
            arguments.Add("-EncodedCommand");
            arguments.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(script)));
            return arguments;
        }

        public static string BuildScript(BundleLaunch launch, string argumentFile, string argumentSha256)
        {
            StringBuilder checks = new StringBuilder();
            foreach (string relative in launch.CheckedFiles)
            {
                checks.Append("    ").Append(Literal(relative)).Append(" = ").Append(Literal(launch.ExpectedSha256(relative))).Append("\n");
            }
            List<string> items = new List<string>();
            foreach (string item in launch.StagedItems)
            {
                items.Add(Literal(item));
            }
            StringBuilder script = new StringBuilder();
            script.Append("$ErrorActionPreference = 'Stop'\n");
            script.Append("$source = ").Append(Literal(launch.SourceRoot)).Append("\n");
            script.Append("$items = @(").Append(string.Join(", ", items.ToArray())).Append(")\n");
            script.Append("$checks = @{\n").Append(checks.ToString()).Append("}\n");
            script.Append("$argumentFile = ").Append(Literal(argumentFile)).Append("\n");
            script.Append("$argumentHash = ").Append(Literal(argumentSha256)).Append("\n");
            script.Append("$scriptPath = ").Append(Literal(launch.ScriptRelativePath)).Append("\n");
            script.Append("$prefix = ").Append(Literal(StagingPrefix)).Append("\n");
            script.Append("$refused = ").Append(BootstrapRefused).Append("\n");
            script.Append(Body);
            return script.ToString();
        }

        // The part of the bootstrap that does not depend on this run. Kept small: it travels on the command line.
        private const string Body =
@"$code = $refused
$stage = $null
function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Copy-Staged([string]$From, [string]$To) {
    $item = Get-Item -LiteralPath $From -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ""Setup's files include a link: $From"" }
    $folder = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $folder)) { $null = [IO.Directory]::CreateDirectory($folder) }
    if ($item.PSIsContainer) {
        $null = [IO.Directory]::CreateDirectory($To)
        foreach ($child in @(Get-ChildItem -LiteralPath $From -Force)) { Copy-Staged $child.FullName (Join-Path $To $child.Name) }
    }
    else { [IO.File]::Copy($From, $To, $false) }
}
try {
    $administrators = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetOwner($administrators)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($administrators, $system)) {
        $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # Folders an interrupted run left (a restart or a killed process skips the finally below): only this name pattern, not a
    # link, over a day old (never a run in progress), and owned by Administrators or SYSTEM (one a user made is left alone).
    $parent = [Environment]::GetFolderPath('CommonApplicationData')
    foreach ($old in @(Get-ChildItem -LiteralPath $parent -Directory -Force -Filter ($prefix + '*') -ErrorAction SilentlyContinue)) {
        try {
            if ($old.Name -cnotmatch ('^' + [regex]::Escape($prefix) + '[0-9a-f]{32}$')) { continue }
            if ($old.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($old.CreationTimeUtc -gt [DateTime]::UtcNow.AddDays(-1)) { continue }
            $owner = (Get-Acl -LiteralPath $old.FullName).GetOwner([System.Security.Principal.SecurityIdentifier])
            if (-not ($owner.Equals($administrators) -or $owner.Equals($system))) { continue }
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop
        }
        catch { }
    }
    $candidate = Join-Path $parent ($prefix + [Guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $candidate) { throw 'The protected folder name is already in use.' }
    $null = [IO.Directory]::CreateDirectory($candidate, $security)
    $stage = $candidate
    foreach ($relative in $items) { Copy-Staged (Join-Path $source $relative) (Join-Path $stage $relative) }
    foreach ($relative in $checks.Keys) {
        if ((Get-Sha256 (Join-Path $stage $relative)) -cne $checks[$relative]) { throw ""Setup's copy of $relative changed after it was unpacked."" }
    }
    $argumentCopy = Join-Path $stage 'arguments.txt'
    [IO.File]::Copy($argumentFile, $argumentCopy, $false)
    if ((Get-Sha256 $argumentCopy) -cne $argumentHash) { throw ""Setup's choices changed after they were written."" }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""' + (Join-Path $stage $scriptPath) + '"" ' + [IO.File]::ReadAllText($argumentCopy, (New-Object System.Text.UTF8Encoding($false)))
    $start.UseShellExecute = $false
    $start.WorkingDirectory = [Environment]::SystemDirectory
    $process = [System.Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    $code = $process.ExitCode
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $code = $refused
}
finally {
    if ($stage) {
        Set-Location -LiteralPath ([Environment]::SystemDirectory)
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $code
";

        // A PowerShell single-quoted string literal. PowerShell also reads the typographic single quotes as quote characters,
        // so each of them is doubled too.
        public static string Literal(string value)
        {
            if (value == null)
            {
                throw new ArgumentNullException("value");
            }
            StringBuilder text = new StringBuilder("'");
            foreach (char character in value)
            {
                text.Append(character);
                if (character == '\'' || character == '‘' || character == '’' || character == '‚' || character == '‛')
                {
                    text.Append(character);
                }
            }
            return text.Append('\'').ToString();
        }

        public static string Sha256(byte[] data)
        {
            using (SHA256 sha = SHA256.Create())
            {
                return Hex(sha.ComputeHash(data));
            }
        }

        public static string Hex(byte[] hash)
        {
            StringBuilder text = new StringBuilder(hash.Length * 2);
            foreach (byte value in hash)
            {
                text.Append(value.ToString("x2"));
            }
            return text.ToString();
        }

        private static int IndexOf(IList<string> values, string wanted)
        {
            for (int index = 0; index < values.Count; index++)
            {
                if (string.Equals(values[index], wanted, StringComparison.Ordinal))
                {
                    return index;
                }
            }
            return -1;
        }
    }
}
