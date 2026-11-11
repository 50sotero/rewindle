param(
    # Never look at the installed configuration or the installed task, even to prove they were left alone. Every check below
    # runs in disposable folders either way; this only drops the two before/after comparisons with the real installation.
    [switch]$SkipInstalledChecks,
    # The built dashboard, whose own session client is run against the session broker when it is there.
    [string]$DashboardPath = (Join-Path $PSScriptRoot '..\src\dashboard\dist\ResticBackuperDashboard.exe')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$managerSource = Join-Path $projectRoot 'src\Manage-Restore.ps1'
$restoreSource = Join-Path $projectRoot 'src\restore.py'
$realPython = (Get-Command python -ErrorAction Stop).Source
$powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$encoding = [Text.UTF8Encoding]::new($false)
$planId = '12345678-1234-4abc-8def-1234567890ab'
$generation = [long]7
$snapshotId = 'b' * 64
$legacySnapshotId = 'f' * 64
$repositoryId = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
# What a person is told when backups that Rewindle opens without a password now ask for one (restore.py and the manager have the
# same sentence). Written out here, character for character, so that a change of it is seen.
$backupsNowAskForAPasswordMessage = 'These backups now ask for a password that Rewindle doesn''t have, usually because they were changed outside Rewindle, so Rewindle can''t open them. If you know that password, Restic can still restore your files with it, as RECOVERY.md in the recovery tools folder next to your backups explains.'
$assertions = 0
$roots = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertions++
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesHash {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Write-Json {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 30) + "`n"), $encoding)
}

function Get-VolumeSerial {
    param([string]$Path)
    if (-not ('RestoreManagerTests.Volume' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RestoreManagerTests {
  public static class Volume {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeInformation(string root, System.Text.StringBuilder volume, int volumeSize,
      out uint serial, out uint maximumComponentLength, out uint fileSystemFlags,
      System.Text.StringBuilder fileSystemName, int fileSystemNameSize);
    public static string Serial(string root) {
      uint serial, maximum, flags;
      if (!GetVolumeInformation(root, null, 0, out serial, out maximum, out flags, null, 0))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      return serial.ToString("X8");
    }
  }
}
'@
    }
    return [RestoreManagerTests.Volume]::Serial([IO.Path]::GetPathRoot($Path))
}

function New-FileRecord {
    param([string]$Root, [string]$Path)
    return [ordered]@{
        relative_path = $Path.Substring($Root.Length + 1)
        bytes = (Get-Item -LiteralPath $Path).Length
        sha256 = Get-Hash -Path $Path
    }
}

$compilerRoot = Join-Path ([IO.Path]::GetTempPath()) ('RSTR-C-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($compilerRoot)
$fakeRestic = Join-Path $compilerRoot 'restic.exe'
$fakeResticSource = @'
using System;
using System.IO;
using System.Linq;
using System.Text;
public static class FakeRestic {
  static string After(string[] args, string name) {
    int index = Array.IndexOf(args, name);
    if (index < 0 || index + 1 >= args.Length) throw new Exception("missing " + name);
    return args[index + 1];
  }
  static string Escape(string value) {
    return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
  }
  // restore.py gives Restic an allow-listed environment, so the fixture settings come from a control file.
  static string Control(string name) {
    string path = @"__FAKE_RESTIC_CONTROL__";
    if (!File.Exists(path)) return null;
    foreach (string line in File.ReadAllLines(path)) {
      int separator = line.IndexOf('=');
      if (separator > 0 && line.Substring(0, separator) == name) return line.Substring(separator + 1);
    }
    return null;
  }
  // ---- Restic 0.19.1's rules for --insecure-no-password (the same text in Test-ManageRestore.ps1 and Test-ManageRetention.ps1) ----
  // FAKE_REPOSITORY_ACCESS (control file) says what backups this stand-in is: password (the default) or no_password. The
  // first rule that applies refuses the command, as Restic does: 1. the flag next to a password source (an option, or a
  // variable with a value): exit 1; 2. backups without a password opened without the flag: exit 1 (with stdin closed, as
  // every caller has it; with an open stdin the real Restic waits for a password instead); 3. backups with a password
  // opened with the flag: exit 12. -1 means the command may go on.
  static int Access(string[] args) {
    bool flag = Array.IndexOf(args, "--insecure-no-password") >= 0;
    bool source = false;
    foreach (string argument in args) {
      foreach (string option in new[] { "--password-command", "--password-file", "--new-password-file" }) {
        if (argument == option || argument.StartsWith(option + "=", StringComparison.Ordinal)) source = true;
      }
    }
    foreach (string variable in new[] { "RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND" }) {
      if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable(variable))) source = true;
    }
    string access = Control("FAKE_REPOSITORY_ACCESS");
    if (String.IsNullOrEmpty(access)) access = "password";
    if (flag && source) {
      Console.Error.WriteLine("Fatal: --insecure-no-password must not be specified together with providing a password via a cli option or environment variable");
      return 1;
    }
    if (access == "no_password" && !flag) {
      Console.Error.WriteLine("Fatal: an empty password is not allowed by default. Pass the flag `--insecure-no-password` to restic to disable this check");
      return 1;
    }
    if (access == "password" && flag) {
      Console.Error.WriteLine("Fatal: wrong password or no key found");
      return 12;
    }
    return -1;
  }
  // ---- end of the access rules ----
  public static int Main(string[] args) {
    foreach (System.Collections.DictionaryEntry item in Environment.GetEnvironmentVariables()) {
      string name = ((string)item.Key).ToUpperInvariant();
      if (name.StartsWith("RCLONE_") || name == "RESTIC_PASSWORD_COMMAND" || name == "RESTIC_PASSWORD_FILE" || name == "RESTIC_REPOSITORY_FILE") {
        Console.Error.WriteLine("inherited " + name); return 92;
      }
    }
    string log = Control("FAKE_RESTIC_LOG");
    if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, String.Join("\t", args) + Environment.NewLine);
    int refused = Access(args);
    if (refused >= 0) return refused;
    string plan = Control("FAKE_PLAN_ID");
    string source = Control("FAKE_SOURCE");
    bool legacy = Control("FAKE_LEGACY_SNAPSHOT") == "1";
    string snapshot = new String(legacy ? 'f' : 'b', 64);
    if (args.Contains("find")) {
      // Like Restic 0.19.1's find --json: one array, with an object for each backup that has matches. The pattern must
      // be the last argument, after "--", and start and end with "*"; a "?" matches any one character.
      string sleep = Control("FAKE_FIND_SLEEP_MS");
      if (!String.IsNullOrEmpty(sleep)) System.Threading.Thread.Sleep(Int32.Parse(sleep));
      string pattern = args[args.Length - 1];
      if (Array.IndexOf(args, "--") != args.Length - 2 || pattern.Length < 2 || pattern[0] != '*' || pattern[pattern.Length - 1] != '*') {
        Console.Error.WriteLine("unexpected find pattern"); return 94;
      }
      System.Text.RegularExpressions.Regex rule = new System.Text.RegularExpressions.Regex(
        "^" + System.Text.RegularExpressions.Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase);
      string root = Path.GetFullPath(source); string drive = root.Substring(0, 1).ToUpperInvariant();
      string prefix = "/" + drive + "/" + root.Substring(2).Replace('\\', '/').Trim('/');
      StringBuilder nodes = new StringBuilder(); int hits = 0;
      foreach (string name in new[] { "notes.txt", "-notes draft.txt", "documents" }) {
        if (!rule.IsMatch(name)) continue;
        if (hits++ > 0) nodes.Append(",");
        nodes.Append("{\"name\":\"" + Escape(name) + "\",\"type\":\"" + (name == "documents" ? "dir" : "file") + "\",\"path\":\"" +
          Escape(prefix + "/" + name) + "\"" + (name == "documents" ? "" : ",\"size\":14") + ",\"mtime\":\"2026-07-19T10:00:00.1234567+02:00\"}");
      }
      StringBuilder output = new StringBuilder("[");
      for (int i = 0; i < args.Length - 1; i++) if (args[i] == "--snapshot" && args[i + 1] == snapshot && hits > 0) {
        output.Append("{\"matches\":[" + nodes + "],\"hits\":" + hits + ",\"snapshot\":\"" + snapshot + "\"}");
      }
      Console.WriteLine(output.Append("]").ToString()); return 0;
    }
    if (args.Contains("cat") && args.Contains("config")) {
      Console.WriteLine("{\"id\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"version\":2}"); return 0;
    }
    if (args.Contains("snapshots")) {
      string tags = legacy
        ? "\"scheduled\""
        : "\"scheduled\",\"restic-backuper-plan:" + plan + "\",\"restic-backuper-generation:7\"";
      Console.WriteLine("[{\"id\":\"" + snapshot + "\",\"short_id\":\"" + snapshot.Substring(0, 8) + "\",\"time\":\"2026-07-20T02:00:00Z\",\"hostname\":\"FIXTURE\",\"tags\":[" + tags + "],\"paths\":[\"" + Escape(source) + "\"],\"summary\":{\"total_files_processed\":2,\"total_bytes_processed\":42}}]"); return 0;
    }
    if (args.Contains("ls")) {
      if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("RESTIC_PASSWORD")) || args.Contains("--insecure-no-password")) {
        string root = Path.GetFullPath(source); string drive = root.Substring(0, 1).ToUpperInvariant();
        string tail = root.Substring(2).Replace('\\', '/').Trim('/'); string prefix = "/" + drive + "/" + tail;
        Console.WriteLine("{\"name\":\"canary.txt\",\"type\":\"file\",\"path\":\"" + Escape(prefix + "/canary.txt") + "\",\"size\":7}");
        Console.WriteLine("{\"name\":\"live.txt\",\"type\":\"file\",\"path\":\"" + Escape(prefix + "/live.txt") + "\",\"size\":21}");
        Console.WriteLine("{\"name\":\"notes.txt\",\"type\":\"file\",\"path\":\"" + Escape(prefix + "/notes.txt") + "\",\"size\":14}");
        return 0;
      }
      Console.WriteLine("{\"name\":\"documents\",\"type\":\"dir\",\"path\":\"/documents\"}");
      Console.WriteLine("{\"name\":\"notes.txt\",\"type\":\"file\",\"path\":\"/notes.txt\",\"size\":42}");
      return 0;
    }
    if (args.Contains("restore")) {
      // The manager's progress as it is while Restic restores (the file the dashboard reads), kept for the test to read.
      string progressFile = Control("FAKE_PROGRESS_FILE"); string progressCopy = Control("FAKE_PROGRESS_COPY");
      if (!String.IsNullOrEmpty(progressFile) && !String.IsNullOrEmpty(progressCopy) && File.Exists(progressFile)) File.Copy(progressFile, progressCopy, true);
      string target = After(args, "--target"); Directory.CreateDirectory(target);
      if (Control("FAKE_RESTORE_PARTIAL") == "1") {
        File.WriteAllText(Path.Combine(target, "partial.txt"), "retained partial data"); return 23;
      }
      // Restic finishing with exit code 0 although it restored nothing, as it does when no pattern matches.
      if (Control("FAKE_RESTORE_NOTHING") == "1") return 0;
      int includeCount = args.Count(value => value == "--include");
      if (includeCount > 0) {
        for (int i = 0; i < args.Length - 1; i++) if (args[i] == "--include") {
          // Like Restic, "[" opens a character class: a pattern with one matches no name that is written
          // literally, so only "[[]" (a class that holds "[") brings such a name back.
          string marked = args[i + 1].Replace("[[]", "\u0001");
          if (marked.Contains("[")) continue;
          string include = marked.Replace("\u0001", "[");
          string[] parts = include.Split(new[] {'/'}, StringSplitOptions.RemoveEmptyEntries);
          string restored = target; foreach (string part in parts) restored = Path.Combine(restored, part);
          Directory.CreateDirectory(Path.GetDirectoryName(restored));
          string content = include.EndsWith("/canary.txt") ? "canary\n" : include.EndsWith("/live.txt") ? "live source sentinel\n" : "fixture notes\n";
          File.WriteAllText(restored, content, new UTF8Encoding(false));
        }
      } else File.WriteAllText(Path.Combine(target, "restored.txt"), "verified restored data");
      return 0;
    }
    Console.Error.WriteLine("forbidden fake Restic command"); return 91;
  }
}
'@
$fakeResticControl = Join-Path $compilerRoot 'fake-restic-control.txt'
$fakeResticSource = $fakeResticSource.Replace('__FAKE_RESTIC_CONTROL__', $fakeResticControl)
Add-Type -TypeDefinition $fakeResticSource -OutputAssembly $fakeRestic -OutputType ConsoleApplication

function Write-FakeResticControl {
    # Restic gets an allow-listed environment, so this process's FAKE_* settings reach the fake through a file.
    $lines = @(foreach ($name in @('FAKE_RESTIC_LOG','FAKE_PLAN_ID','FAKE_SOURCE','FAKE_RESTORE_PARTIAL','FAKE_RESTORE_NOTHING','FAKE_LEGACY_SNAPSHOT','FAKE_FIND_SLEEP_MS','FAKE_REPOSITORY_ACCESS','FAKE_PROGRESS_FILE','FAKE_PROGRESS_COPY')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $name + '=' + $value }
    })
    [IO.File]::WriteAllLines($fakeResticControl, [string[]]$lines, $encoding)
}

$pythonWrapper = Join-Path $compilerRoot 'python.exe'
$escapedPython = $realPython.Replace('\', '\\').Replace('"', '\"')
# Manage-Restore starts restore.py with an allow-listed environment. The stand-in refuses (exit 93) any other variable
# and records what it got, for the exact check after the first listing.
$pythonEnvironmentLog = Join-Path $compilerRoot 'python-environment.txt'
$escapedPythonEnvironmentLog = $pythonEnvironmentLog.Replace('\', '\\').Replace('"', '\"')
$pythonWrapperSource = @"
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
public static class PythonWrapper {
  static readonly string[] Allowed = {
    "SystemRoot", "windir", "SystemDrive", "ComSpec", "PATH", "PATHEXT", "OS", "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE", "LOCALAPPDATA"
  };
  static string Quote(string value) {
    if (value.Length > 0 && value.IndexOfAny(new[] {' ', '\t', '"'}) < 0) return value;
    StringBuilder result = new StringBuilder("\""); int slashes = 0;
    foreach (char item in value) {
      if (item == '\\') { slashes++; continue; }
      if (item == '"') { result.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
      if (slashes > 0) { result.Append('\\', slashes); slashes = 0; }
      result.Append(item);
    }
    if (slashes > 0) result.Append('\\', slashes * 2);
    return result.Append('"').ToString();
  }
  public static int Main(string[] args) {
    List<string> received = new List<string>();
    foreach (DictionaryEntry item in Environment.GetEnvironmentVariables()) {
      string name = (string)item.Key;
      if (Array.IndexOf(Allowed, name) < 0) { Console.Error.WriteLine("inherited " + name); return 93; }
      received.Add(name + "=" + (string)item.Value);
    }
    received.Sort(StringComparer.Ordinal);
    File.WriteAllLines("$escapedPythonEnvironmentLog", received.ToArray(), new UTF8Encoding(false));
    ProcessStartInfo start = new ProcessStartInfo(); start.FileName = "$escapedPython";
    start.Arguments = String.Join(" ", Array.ConvertAll(args, Quote)); start.UseShellExecute = false;
    using (Process process = Process.Start(start)) { process.WaitForExit(); return process.ExitCode; }
  }
}
"@
Add-Type -TypeDefinition $pythonWrapperSource -OutputAssembly $pythonWrapper -OutputType ConsoleApplication

function New-Fixture {
    # -WithPasswordHelper: the configuration names a stored password, as every installed one does, so restore.py gives Restic
    # its password helper (which this fake never runs). A file search needs it; the other requests also run without it.
    # -Access: the "repository_access" the configuration names; '' leaves the key out, as every older install's configuration
    # does. -NoRecoveryKey: no file at the recovery key's path, as for a new backup without a password. -BrokenRecoveryKey: an
    # empty file there, an older install's key that no longer checks out. -BackupsAre: what the stand-in Restic's backups are
    # (password or no_password); by default what the configuration says.
    param([switch]$WithPasswordHelper, [string]$Access = '', [switch]$NoRecoveryKey, [switch]$BrokenRecoveryKey, [string]$BackupsAre = '')
    $root = Join-Path ([IO.Path]::GetTempPath()) ('RSTR-T-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $roots.Add($root)
    $install = Join-Path $root 'ProgramFiles\ResticBackuper'
    $state = Join-Path $root 'ProgramData\ResticBackuper'
    $repository = Join-Path $root 'Repository\Personal'
    $recovery = Join-Path $root 'Repository\RecoveryTools'
    $source = Join-Path $root 'Source'
    foreach ($directory in @($install, (Join-Path $install 'Python'), $state, $repository, $recovery, $source)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Copy-Item -LiteralPath $managerSource -Destination (Join-Path $install 'Manage-Restore.ps1')
    Copy-Item -LiteralPath $restoreSource -Destination (Join-Path $install 'restore.py')
    Copy-Item -LiteralPath $fakeRestic -Destination (Join-Path $install 'restic.exe')
    Copy-Item -LiteralPath $pythonWrapper -Destination (Join-Path $install 'Python\python.exe')
    [IO.File]::WriteAllText((Join-Path $install 'secret_store.py'), "# intentionally unused fixture helper`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $install 'excludes.txt'), "node_modules`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $source 'canary.txt'), "canary`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $source 'live.txt'), "live source sentinel`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $source 'notes.txt'), "fixture notes`n", $encoding)
    $recoveryKeyPath = Join-Path $root 'RecoveryKey.txt'
    if ($BrokenRecoveryKey) { [IO.File]::WriteAllBytes($recoveryKeyPath, [byte[]]@()) }
    elseif (-not $NoRecoveryKey) {
        [IO.File]::WriteAllText($recoveryKeyPath, "Password: fixture-recovery-password-material-that-is-long-enough-12345`n", $encoding)
    }
    [IO.File]::WriteAllText((Join-Path $repository 'config'), "repository config sentinel`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $repository 'pack'), "encrypted repository sentinel`n", $encoding)
    [IO.File]::WriteAllBytes((Join-Path $state 'run.lock'), [byte[]](0))
    # The backup's own Restic cache, which restore requests read through.
    [void][IO.Directory]::CreateDirectory((Join-Path $state 'cache'))
    $serial = Get-VolumeSerial -Path $repository
    $secretFile = Join-Path $state 'missing-secret.json'
    if ($WithPasswordHelper) {
        $secretFile = Join-Path $state 'repository-password.dpapi.json'
        [IO.File]::WriteAllText($secretFile, "{}`n", $encoding)
    }
    $config = [ordered]@{
        schema_version = 1; plan_id = $planId; config_generation = $generation
        repository = $repository; repository_volume_serial = $serial
        restic_executable = Join-Path $install 'restic.exe'; recovery_tools_directory = $recovery
        python_executable = Join-Path $install 'Python\python.exe'; state_directory = $state
        secret_file = $secretFile; recovery_key_file = $recoveryKeyPath
        exclude_file = Join-Path $install 'excludes.txt'; canary_file = Join-Path $source 'canary.txt'
        hostname = 'FIXTURE'; scheduled_tag = 'scheduled'; use_vss = $false
        cloud_placeholder_policy = 'strict'; sources = @($source)
        source_identities = [ordered]@{ $source = [ordered]@{ expected_volume_serial = $serial } }
    }
    if ($Access -ne '') { $config['repository_access'] = $Access }
    $configPath = Join-Path $install 'backup-config.json'
    Write-Json -Path $configPath -Value $config
    Write-Json -Path (Join-Path $state 'last-success.json') -Value ([ordered]@{
        schema_version = 1; plan_id = $planId; config_generation = $generation
        state = 'success'; repository_id = $repositoryId; snapshot_id = $snapshotId
        verification_complete = $true
        verification = [ordered]@{
            repository_structure = $true
            canary = [ordered]@{
                verified = $true; snapshot_path = ('/' + $source.Substring(0,1).ToUpperInvariant() + '/' + $source.Substring(3).Replace('\','/') + '/canary.txt')
                bytes = 7; sha256 = (Get-Hash -Path (Join-Path $source 'canary.txt'))
            }
        }
    })
    $manifestFiles = @(Get-ChildItem -LiteralPath $install -Recurse -File -Force | Sort-Object FullName)
    Write-Json -Path (Join-Path $install 'runtime-manifest.json') -Value ([ordered]@{
        schema_version = 1; file_count = $manifestFiles.Count
        files = @($manifestFiles | ForEach-Object { New-FileRecord -Root $install -Path $_.FullName })
    })
    [IO.File]::WriteAllText(
        (Join-Path $install 'scheduled-task.xml'),
        "<primary-task-fixture />`n",
        $encoding
    )
    [IO.File]::WriteAllText(
        (Join-Path $install 'google-drive-verification-task.xml'),
        "<verification-task-fixture />`n",
        $encoding
    )
    $log = Join-Path $root 'restic.log'
    $fakeAccess = if ($BackupsAre) { $BackupsAre } elseif ($Access -ceq 'no_password') { 'no_password' } else { 'password' }
    return [pscustomobject]@{
        Root=$root; Install=$install; State=$state; Repository=$repository; Recovery=$recovery;
        Source=$source; ConfigPath=$configPath; Log=$log; RecoveryKey=$recoveryKeyPath; Secret=$secretFile; FakeAccess=$fakeAccess
    }
}

function Invoke-Manager {
    param(
        [pscustomobject]$Fixture,
        [string]$Action,
        [string]$Snapshot = '',
        [string]$TreePath = '',
        [string]$Target = '',
        [string[]]$Includes = @(),
        [bool]$AllowLegacy = $false,
        [switch]$LegacyFixture,
        [string]$Plan = $planId,
        [long]$ConfigGeneration = $generation,
        [string]$DigestOverride = ''
    )
    $nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
    $configHash = Get-Hash -Path $Fixture.ConfigPath
    $includesJson = ConvertTo-Json -InputObject @($Includes) -Compress
    [byte[]]$includeBytes = $encoding.GetBytes($includesJson)
    $includeHash = Get-BytesHash -Bytes $includeBytes
    $canonicalTarget = if ($Target) {
        [IO.Path]::GetFullPath($Target).TrimEnd('\')
    } elseif ($Action -eq 'restore_drill') {
        [IO.Path]::GetFullPath((Join-Path $Fixture.Root "ProgramData\ResticBackuper-RestoreDrills\drill-$nonce")).TrimEnd('\')
    } else { '' }
    $payload = @(
        'ResticBackuper.RestoreRequest.v2', $sid, $Action, $configHash, $Plan,
        $ConfigGeneration.ToString([Globalization.CultureInfo]::InvariantCulture),
        $(if ($AllowLegacy) { '1' } else { '0' }),
        $Snapshot, $TreePath, $canonicalTarget, $includeHash, $nonce
    ) -join "`n"
    $digest = if ($DigestOverride) { $DigestOverride } else { Get-BytesHash -Bytes $encoding.GetBytes($payload) }
    $resultPath = Join-Path $Fixture.State "RestoreManagerResults\$nonce.json"
    $arguments = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',
        (Join-Path $Fixture.Install 'Manage-Restore.ps1'),
        '-Action',$Action,
        '-IncludesBase64',[Convert]::ToBase64String($includeBytes),
        '-ExpectedUserSid',$sid,'-ExpectedConfigSha256',$configHash,
        '-ExpectedPlanId',$Plan,'-ExpectedConfigGeneration',$ConfigGeneration,
        '-AllowLegacyUnbound',$(if ($AllowLegacy) { '1' } else { '0' }),
        '-ResultPath',$resultPath,'-RequestNonce',$nonce,'-RequestDigest',$digest,
        '-TestRoot',$Fixture.Root
    )
    if ($Snapshot) { $arguments += @('-SnapshotId',$Snapshot) }
    if ($TreePath) { $arguments += @('-TreePath',$TreePath) }
    if ($Target) { $arguments += @('-Target',$Target) }
    $env:FAKE_RESTIC_LOG = $Fixture.Log
    $env:FAKE_PLAN_ID = $planId
    $env:FAKE_SOURCE = $Fixture.Source
    $env:FAKE_REPOSITORY_ACCESS = $Fixture.FakeAccess
    # The fake Restic copies the manager's progress as it is when a restore starts: what the dashboard shows meanwhile.
    $restoringCopy = Join-Path $Fixture.Root ('restoring-progress-' + $nonce + '.json')
    $env:FAKE_PROGRESS_FILE = $resultPath + '.progress.json'
    $env:FAKE_PROGRESS_COPY = $restoringCopy
    if ($LegacyFixture) { $env:FAKE_LEGACY_SNAPSHOT = '1' }
    else { Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue }
    Write-FakeResticControl
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
        Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_PROGRESS_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_PROGRESS_COPY -ErrorAction SilentlyContinue
    }
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    $progress = if (Test-Path -LiteralPath ($resultPath + '.progress.json')) {
        Get-Content -LiteralPath ($resultPath + '.progress.json') -Raw | ConvertFrom-Json
    } else { $null }
    $restoring = if (Test-Path -LiteralPath $restoringCopy) { Get-Content -LiteralPath $restoringCopy -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ ExitCode=$exitCode; Result=$result; Progress=$progress; Restoring=$restoring; Output=$output; Nonce=$nonce; Digest=$digest; ConfigHash=$configHash }
}

$productionConfig = Join-Path $env:ProgramFiles 'ResticBackuper\backup-config.json'
$productionHashBefore = $null
$taskXmlBefore = $null
if (-not $SkipInstalledChecks) {
    $productionHashBefore = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
    $taskXmlBefore = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }
}

# Settings a user could plant in their own environment. Manage-Restore must not pass them to restore.py (the Python
# stand-in exits 93 on any variable outside its allow-list), and restore.py must not pass them to Restic (the fake exits 92).
$plantedEnvironment = @{
    RESTIC_PASSWORD_COMMAND = 'C:\planted\evil.cmd'
    RESTIC_PASSWORD_FILE = 'C:\planted\password.txt'
    RESTIC_REPOSITORY_FILE = 'C:\planted\repository.txt'
    RCLONE_CONFIG_PLANTED_TYPE = 'sftp'
}
foreach ($name in $plantedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $plantedEnvironment[$name], 'Process') }

try {
    $fixture = New-Fixture
    $repositoryBefore = Get-Hash -Path (Join-Path $fixture.Repository 'pack')
    $sourceBefore = Get-Hash -Path (Join-Path $fixture.Source 'live.txt')

    $list = Invoke-Manager -Fixture $fixture -Action list_snapshots
    if ($list.ExitCode -ne 0) {
        Write-Output ("snapshot-list output: " + ($list.Output -join ' | '))
        if ($null -ne $list.Result) { Write-Output ("snapshot-list result: " + ($list.Result | ConvertTo-Json -Compress -Depth 20)) }
    }
    Assert-True ($list.ExitCode -eq 0 -and $list.Result.ok -eq $true) 'snapshot listing succeeds'
    # restore.py got the Windows values from the Windows API and the user's local application-data folder, nothing else.
    $systemFolder = [Environment]::SystemDirectory
    $windowsFolder = [IO.Directory]::GetParent($systemFolder).FullName
    $expectedPythonEnvironment = [ordered]@{
        ComSpec = (Join-Path $systemFolder 'cmd.exe')
        LOCALAPPDATA = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        NUMBER_OF_PROCESSORS = [string][Environment]::ProcessorCount
        OS = 'Windows_NT'
        PATH = (@($systemFolder, $windowsFolder, (Join-Path $systemFolder 'Wbem'), (Join-Path $systemFolder 'WindowsPowerShell\v1.0')) -join ';')
        PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
        SystemDrive = [IO.Path]::GetPathRoot($windowsFolder).TrimEnd('\')
        SystemRoot = $windowsFolder
        windir = $windowsFolder
    }
    if ($env:PROCESSOR_ARCHITECTURE -cin @('AMD64', 'x86', 'ARM64')) {
        $expectedPythonEnvironment['PROCESSOR_ARCHITECTURE'] = $env:PROCESSOR_ARCHITECTURE
    }
    $expectedPythonLines = [string[]]@($expectedPythonEnvironment.Keys | ForEach-Object { $_ + '=' + $expectedPythonEnvironment[$_] })
    [Array]::Sort($expectedPythonLines, [StringComparer]::Ordinal)
    $receivedPythonLines = [IO.File]::ReadAllLines($pythonEnvironmentLog, $encoding)
    Assert-True (($receivedPythonLines -join "`n") -ceq ($expectedPythonLines -join "`n")) (
        'restore.py gets only the allow-listed environment: ' + ($receivedPythonLines -join '; '))
    Assert-True ([string]$list.Result.request_digest -ceq $list.Digest -and [string]$list.Result.expected_config_sha256 -ceq $list.ConfigHash) 'snapshot result request/config binding'
    Assert-True ([string]$list.Result.plan_id -ceq $planId -and [long]$list.Result.config_generation -eq $generation) 'snapshot result plan binding'
    Assert-True ($list.Result.allow_legacy_unbound -eq $false) 'snapshot result binds legacy opt-in off'
    Assert-True ([string]$list.Result.payload.schema -ceq 'ResticBackuper.SnapshotList.v1') 'snapshot payload schema'
    Assert-True (@($list.Result.payload.snapshots).Count -eq 1 -and [string]$list.Result.payload.snapshots[0].id -ceq $snapshotId) 'snapshot payload exact item'
    Assert-True ([string]$list.Progress.stage -ceq 'complete' -and [int]$list.Progress.percent -eq 100) 'snapshot progress completes'

    $tree = Invoke-Manager -Fixture $fixture -Action list_tree -Snapshot $snapshotId -TreePath '/'
    Assert-True ($tree.ExitCode -eq 0 -and $tree.Result.ok -eq $true) 'tree listing succeeds'
    Assert-True ([string]$tree.Result.payload.snapshot_id -ceq $snapshotId -and @($tree.Result.payload.entries).Count -eq 2) 'tree result exact snapshot and entries'

    $legacyFixture = New-Fixture
    $legacyList = Invoke-Manager -Fixture $legacyFixture -Action list_snapshots -LegacyFixture
    Assert-True ($legacyList.ExitCode -eq 0 -and $legacyList.Result.ok -eq $true) 'matching legacy snapshot listing succeeds'
    Assert-True (@($legacyList.Result.payload.snapshots).Count -eq 1 -and
        [string]$legacyList.Result.payload.snapshots[0].id -ceq $legacySnapshotId -and
        [string]$legacyList.Result.payload.snapshots[0].binding_state -ceq 'legacy_unbound') 'matching legacy snapshot is clearly classified'
    $legacyWithoutOptIn = Invoke-Manager -Fixture $legacyFixture -Action list_tree -Snapshot $legacySnapshotId -LegacyFixture
    Assert-True ($legacyWithoutOptIn.ExitCode -ne 0 -and $legacyWithoutOptIn.Result.ok -eq $false) 'legacy tree access fails without explicit opt-in'
    $legacyTree = Invoke-Manager -Fixture $legacyFixture -Action list_tree -Snapshot $legacySnapshotId -AllowLegacy $true -LegacyFixture
    Assert-True ($legacyTree.ExitCode -eq 0 -and $legacyTree.Result.ok -eq $true -and
        $legacyTree.Result.allow_legacy_unbound -eq $true -and
        [string]$legacyTree.Result.payload.snapshot_binding -ceq 'legacy_unbound') 'exact legacy tree access succeeds with bound opt-in'
    $legacyTarget = Join-Path $legacyFixture.Root 'Restored\Legacy'
    $legacyRestore = Invoke-Manager -Fixture $legacyFixture -Action restore -Snapshot $legacySnapshotId -Target $legacyTarget -AllowLegacy $true -LegacyFixture
    Assert-True ($legacyRestore.ExitCode -eq 0 -and $legacyRestore.Result.ok -eq $true -and
        [string]$legacyRestore.Result.payload.snapshot_binding -ceq 'legacy_unbound') 'exact legacy restore succeeds with bound opt-in'
    $legacyHistory = Get-Content -LiteralPath (Join-Path $legacyFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True ([string]$legacyHistory.entries[0].snapshot_binding -ceq 'legacy_unbound') 'legacy restore classification is recorded in protected history'

    $target = Join-Path $fixture.Root 'Restored\Verified'
    $restore = Invoke-Manager -Fixture $fixture -Action restore -Snapshot $snapshotId -Target $target -Includes @('/notes.txt')
    Assert-True ($restore.ExitCode -eq 0 -and $restore.Result.ok -eq $true) 'verified restore succeeds'
    Assert-True ([string]$restore.Result.payload.result -ceq 'verified' -and $restore.Result.payload.verified -eq $true) 'verified restore report accepted'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'notes.txt') -PathType Leaf) 'verified restore target created'
    $verifiedHistory = Get-Content -LiteralPath (Join-Path $fixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True ($restore.Result.history_recorded -eq $true -and @($verifiedHistory.entries).Count -eq 1 -and $verifiedHistory.entries[0].verified -eq $true) 'verified restore is recorded in bounded protected history'

    # Names with square brackets come back as themselves: the fake, like Restic, reads "[" as the start of a character class.
    $bracketFixture = New-Fixture
    $bracketTarget = Join-Path $bracketFixture.Root 'Restored\Brackets'
    # Its history is full of recovery drills' entries, so this restore's entry takes the place of the oldest of them.
    $drillEntries = [Collections.Generic.List[object]]::new()
    foreach ($number in 1..50) {
        $drillEntries.Add([ordered]@{ finished_utc = '2026-03-01T00:00:00.0000000Z'; kind = 'recovery_key_representative_drill'; result = 'verified'; verified = $true; target = ('drill-' + $number) })
    }
    Write-Json -Path (Join-Path $bracketFixture.State 'restore-history.json') -Value ([ordered]@{
        schema_version = 2; plan_id = $planId; updated_utc = '2026-03-01T00:00:00.0000000Z'; entries = $drillEntries.ToArray()
    })
    $bracketRestore = Invoke-Manager -Fixture $bracketFixture -Action restore -Snapshot $snapshotId -Target $bracketTarget -Includes @('/Photos [2020]/a.txt', '/Notes[1].txt')
    Assert-True ($bracketRestore.ExitCode -eq 0 -and $bracketRestore.Result.ok -eq $true -and [string]$bracketRestore.Result.payload.result -ceq 'verified') 'a restore of names with square brackets was not verified'
    Assert-True ((Test-Path -LiteralPath (Join-Path $bracketTarget 'Photos [2020]\a.txt') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $bracketTarget 'Notes[1].txt') -PathType Leaf)) 'names with square brackets were not restored'
    Assert-True ((Get-Content -LiteralPath $bracketFixture.Log -Raw).Contains("--include`t/Photos [[]2020]/a.txt")) 'a chosen name with "[" reached Restic as a pattern instead of literally'
    $bracketEntries = @((Get-Content -LiteralPath (Join-Path $bracketFixture.State 'restore-history.json') -Raw | ConvertFrom-Json).entries)
    Assert-True ($bracketEntries.Count -eq 50 -and [string]$bracketEntries[0].target -ceq 'drill-2' -and
        [string]$bracketEntries[49].kind -ceq 'manual_restore' -and $bracketEntries[49].verified -eq $true) 'a history of only drill entries did not make room by its oldest one'

    # Restic can finish with exit code 0 having restored nothing; a chosen item that is not there ends as an incomplete restore.
    $nothingFixture = New-Fixture
    $nothingTarget = Join-Path $nothingFixture.Root 'Restored\Nothing'
    $env:FAKE_RESTORE_NOTHING = '1'
    try { $nothing = Invoke-Manager -Fixture $nothingFixture -Action restore -Snapshot $snapshotId -Target $nothingTarget -Includes @('/notes.txt') }
    finally { Remove-Item Env:FAKE_RESTORE_NOTHING -ErrorAction SilentlyContinue }
    Assert-True ($nothing.ExitCode -ne 0 -and $nothing.Result.ok -eq $false -and [int]$nothing.Result.backend_exit_code -eq 1) 'a restore that brought back no chosen item was reported as done'
    Assert-True ([string]$nothing.Result.payload.result -ceq 'partial' -and $nothing.Result.payload.verified -eq $false -and
        [int]$nothing.Result.payload.restic_exit_code -eq 0 -and
        [string]$nothing.Result.error -match 'without restoring every chosen item') 'a missing chosen item was not reported in its own words'
    $nothingHistory = Get-Content -LiteralPath (Join-Path $nothingFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True (@($nothingHistory.entries).Count -eq 1 -and $nothingHistory.entries[0].verified -eq $false) 'a restore missing a chosen item was recorded as verified'

    # An item that is not one path as the backup lists it is refused before anything is restored, once the report is bound to the
    # snapshot, so the manager accepts the report and the refusal reaches the dashboard in restore.py's words, which it puts plainly.
    $refusedFixture = New-Fixture
    $refusedTarget = Join-Path $refusedFixture.Root 'Restored\Refused'
    # The history is already full (50 entries, all that recovery_health.py reads), and its oldest entry is a recovery drill's.
    $seededEntries = [Collections.Generic.List[object]]::new()
    $seededEntries.Add([ordered]@{ finished_utc = '2026-01-01T00:00:00.0000000Z'; kind = 'recovery_key_representative_drill'; result = 'verified'; verified = $true })
    foreach ($number in 1..49) {
        $seededEntries.Add([ordered]@{ finished_utc = ('2026-02-{0:D2}T00:00:00.0000000Z' -f [Math]::Min($number, 28)); kind = 'manual_restore'; result = 'verified'; verified = $true; target = ('seeded-' + $number) })
    }
    Write-Json -Path (Join-Path $refusedFixture.State 'restore-history.json') -Value ([ordered]@{
        schema_version = 2; plan_id = $planId; updated_utc = '2026-02-28T00:00:00.0000000Z'; entries = $seededEntries.ToArray()
    })
    $refused = Invoke-Manager -Fixture $refusedFixture -Action restore -Snapshot $snapshotId -Target $refusedTarget -Includes @('C:\notes.txt')
    Assert-True ($refused.ExitCode -ne 0 -and $refused.Result.ok -eq $false -and
        [string]$refused.Result.error -match "^an include must be one item's path as Restic lists it") ('a refused item did not reach the dashboard in restore.py''s words: ' + [string]$refused.Result.error)
    Assert-True ([string]$refused.Result.payload.result -ceq 'error' -and $refused.Result.payload.verified -eq $false) 'a refused item was not reported as a restore that did not run'
    Assert-True (-not (Test-Path -LiteralPath $refusedTarget) -or @(Get-ChildItem -LiteralPath $refusedTarget -Force).Count -eq 0) 'a refused item still restored something'
    Assert-True (-not (@(Get-Content -LiteralPath $refusedFixture.Log) | Where-Object { ($_ -split "`t") -contains 'restore' })) 'Restic was asked to restore a refused item'
    # The refused restore is recorded, in the place of the oldest manual restore's entry, never the drill's.
    $refusedEntries = @((Get-Content -LiteralPath (Join-Path $refusedFixture.State 'restore-history.json') -Raw | ConvertFrom-Json).entries)
    Assert-True ($refusedEntries.Count -eq 50 -and [string]$refusedEntries[49].kind -ceq 'manual_restore' -and [string]$refusedEntries[49].result -ceq 'error') 'a refused restore was not recorded at the end of a history of 50 entries'
    Assert-True ([string]$refusedEntries[0].kind -ceq 'recovery_key_representative_drill' -and [string]$refusedEntries[1].target -ceq 'seeded-2' -and
        @($refusedEntries | Where-Object { [string]$_.kind -ceq 'recovery_key_representative_drill' }).Count -eq 1) 'a refused restore pushed the recovery drill out of the history that readiness reads'

    $drillFixture = New-Fixture
    $drill = Invoke-Manager -Fixture $drillFixture -Action restore_drill
    if ($drill.ExitCode -ne 0) {
        Write-Output ("drill output: " + ($drill.Output -join ' | '))
        if ($null -ne $drill.Result) { Write-Output ("drill result: " + ($drill.Result | ConvertTo-Json -Compress -Depth 20)) }
    }
    Assert-True ($drill.ExitCode -eq 0 -and $drill.Result.ok -eq $true -and $drill.Result.history_recorded -eq $true) 'recovery-key representative drill succeeds'
    Assert-True ([string]$drill.Result.payload.drill_kind -ceq 'recovery_key_representative' -and
        [string]$drill.Result.payload.credential_source -ceq 'recovery_key' -and
        [bool]$drill.Result.payload.canary_verified -and [long]$drill.Result.payload.sample_file_count -eq 2) 'drill report contains verified canary and bounded sample evidence'
    $expectedDrillTarget = [IO.Path]::GetFullPath((Join-Path $drillFixture.Root "ProgramData\ResticBackuper-RestoreDrills\drill-$($drill.Nonce)")).TrimEnd('\')
    Assert-True ([string]$drill.Result.target -ceq $expectedDrillTarget) 'drill target is nonce-bound and manager-derived'
    $drillHistory = Get-Content -LiteralPath (Join-Path $drillFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True ([int]$drillHistory.schema_version -eq 2 -and @($drillHistory.entries).Count -eq 1 -and
        [string]$drillHistory.entries[0].kind -ceq 'recovery_key_representative_drill' -and
        [string]$drillHistory.entries[0].repository_id -ceq $repositoryId -and
        [long]$drillHistory.entries[0].snapshot_generation -eq $generation) 'only complete drill evidence is durably recorded'
    # A configuration without repository_access (the fixtures so far, and every older install, the owner's included) is a
    # backup with a password: its drill used the recovery key, says so in its report and history, and its Restic never got
    # the empty-password flag.
    $ownerShapedConfiguration = Get-Content -LiteralPath $drillFixture.ConfigPath -Raw | ConvertFrom-Json
    Assert-True ($null -eq $ownerShapedConfiguration.PSObject.Properties['repository_access']) 'the fixtures so far are shaped like an older configuration, without repository_access'
    Assert-True ([string]$drillHistory.entries[0].credential_source -ceq 'recovery_key') 'a drill of backups with a password is recorded as made with the recovery key'
    Assert-True ([string]$drill.Progress.message -ceq 'Recovery-key restore drill completed, verified, and was recorded.') 'the drill of backups with a password keeps its completion text'
    # What the dashboard shows while Restic restores the sample (the fake Restic copied the progress file as it was then).
    Assert-True ($null -ne $drill.Restoring -and [string]$drill.Restoring.stage -ceq 'restoring' -and [int]$drill.Restoring.percent -eq 25 -and
        [string]$drill.Restoring.message -ceq 'Restoring the canary and a bounded representative sample with the recovery key.') ('the drill of backups with a password says that it restores with the recovery key: ' + [string]$drill.Restoring.message)
    Assert-True (-not ((Get-Content -LiteralPath $drillFixture.Log -Raw) -match 'insecure-no-password')) 'backups with a password never get the empty-password flag'

    # ------------------------------------------------------------------------------------------------------------------
    # Backups without a password ("repository_access": "no_password"). They have no recovery key and no saved password:
    # nothing is looked for at those paths, and Restic opens them with --insecure-no-password and nothing else (the stand-in
    # follows Restic 0.19.1: it refuses the flag next to a password source and backups without a password opened without it).
    # ------------------------------------------------------------------------------------------------------------------
    $accessTokens = $null
    $accessParseErrors = $null
    $accessAst = [Management.Automation.Language.Parser]::ParseFile($managerSource, [ref]$accessTokens, [ref]$accessParseErrors)
    Assert-True ($accessParseErrors.Count -eq 0) 'the restore manager parses'
    foreach ($accessFunctionName in @('Get-RepositoryAccess', 'Assert-RecoveryDrillReport', 'Test-BackendAskedForAPassword')) {
        $accessDefinitions = @($accessAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $accessFunctionName
        }, $false))
        Assert-True ($accessDefinitions.Count -eq 1) ($accessFunctionName + ' is defined once in the manager')
        . ([scriptblock]::Create($accessDefinitions[0].Extent.Text))
    }
    function ConvertTo-AccessConfiguration([string]$Json) { return (ConvertFrom-Json -InputObject $Json) }
    # The reader (a byte-identical copy lives in every script that reads the field) under StrictMode, which throws on a
    # dotted read of a key that older configurations do not have.
    Assert-True ((Get-RepositoryAccess -Configuration (ConvertTo-AccessConfiguration '{"schema_version":1}')) -ceq 'password') 'a configuration without repository_access means a password'
    Assert-True ((Get-RepositoryAccess -Configuration (ConvertTo-AccessConfiguration '{"repository_access":"password"}')) -ceq 'password') 'repository_access password means a password'
    Assert-True ((Get-RepositoryAccess -Configuration (ConvertTo-AccessConfiguration '{"repository_access":"no_password"}')) -ceq 'no_password') 'repository_access no_password means no password'
    foreach ($unsupported in @('"Password"', '"NO_PASSWORD"', '"No_Password"', '"no-password"', '"none"', '""', '" password"', 'null', '5', 'true', '["password"]', '{}')) {
        $refusedValue = $false
        try { [void](Get-RepositoryAccess -Configuration (ConvertTo-AccessConfiguration ('{"repository_access":' + $unsupported + '}'))) }
        catch { $refusedValue = ([string]$_.Exception.Message -ceq 'unsupported repository_access') }
        Assert-True $refusedValue ('repository_access ' + $unsupported + ' is refused, never read as a default')
    }
    # What a recovery drill's report must name: the recovery key for backups with a password, none for backups without one.
    $drillEvidenceSample = [pscustomobject]@{ RepositoryId = $repositoryId; CanarySha256 = ('c' * 64); CanaryBytes = [long]7 }
    function Test-DrillReportAccepted([string]$CredentialSource, [string]$Access) {
        $report = [pscustomobject]@{
            drill_kind = 'recovery_key_representative'; credential_source = $CredentialSource; repository_id = $repositoryId
            result = 'verified'; verified = $true; partial_target_retained = $false; canary_verified = $true
            canary_sha256 = ('c' * 64); canary_bytes = [long]7; sample_policy = 'one-or-two-bounded-files-per-source-v1'
            sample_file_count = [long]2; sample_bytes = [long]35; sample_paths_sha256 = ('d' * 64)
        }
        try { Assert-RecoveryDrillReport -Payload $report -Evidence $drillEvidenceSample -RepositoryAccess $Access; return $true }
        catch { return $false }
    }
    Assert-True (Test-DrillReportAccepted 'recovery_key' 'password') 'a drill of backups with a password is accepted when it names the recovery key'
    Assert-True (Test-DrillReportAccepted 'none' 'no_password') 'a drill of backups without a password is accepted when it names no credential'
    Assert-True (-not (Test-DrillReportAccepted 'none' 'password')) 'a drill of backups with a password that used no key is refused'
    Assert-True (-not (Test-DrillReportAccepted 'recovery_key' 'no_password')) 'a drill of backups without a password that claims a recovery key is refused'
    Assert-True (-not (Test-DrillReportAccepted 'None' 'no_password')) 'the credential a drill names is compared exactly'
    Assert-True (-not (Test-DrillReportAccepted 'active_credential' 'no_password')) 'no other credential is accepted for a drill'

    # No recovery key file at all, as for a new backup without a password: every request used to look for one first.
    $noKeyFixture = New-Fixture -Access no_password -NoRecoveryKey
    Assert-True (-not (Test-Path -LiteralPath $noKeyFixture.RecoveryKey)) 'the backup without a password starts with no recovery key file'
    $noKeyList = Invoke-Manager -Fixture $noKeyFixture -Action list_snapshots
    Assert-True ($noKeyList.ExitCode -eq 0 -and $noKeyList.Result.ok -eq $true) ('backups without a password list without any recovery key file: ' + [string]$noKeyList.Result.error)
    $noKeyCalls = @(Get-Content -LiteralPath $noKeyFixture.Log)
    Assert-True ($noKeyCalls.Count -ge 2 -and @($noKeyCalls | Where-Object { $_ -notmatch '(^|\t)--insecure-no-password(\t|$)' }).Count -eq 0) 'every Restic for backups without a password was given the empty-password flag'
    $noKeyTree = Invoke-Manager -Fixture $noKeyFixture -Action list_tree -Snapshot $snapshotId -TreePath '/'
    Assert-True ($noKeyTree.ExitCode -eq 0 -and $noKeyTree.Result.ok -eq $true) 'a folder of backups without a password lists too'

    # An older install's recovery key that no longer checks out, and its saved password, are left exactly as they are: not
    # looked at, not used (Restic would run a password command before it refused one next to the flag), and not needed.
    $leftoverFixture = New-Fixture -Access no_password -BrokenRecoveryKey -WithPasswordHelper
    $leftoverKeyHash = Get-Hash -Path $leftoverFixture.RecoveryKey
    $leftoverSecretHash = Get-Hash -Path $leftoverFixture.Secret
    $leftoverTarget = Join-Path $leftoverFixture.Root 'Restored\NoPassword'
    $leftoverRestore = Invoke-Manager -Fixture $leftoverFixture -Action restore -Snapshot $snapshotId -Target $leftoverTarget -Includes @('/notes.txt')
    Assert-True ($leftoverRestore.ExitCode -eq 0 -and $leftoverRestore.Result.ok -eq $true -and [string]$leftoverRestore.Result.payload.result -ceq 'verified') ('a restore of backups without a password ignores an older key: ' + [string]$leftoverRestore.Result.error)
    Assert-True (Test-Path -LiteralPath (Join-Path $leftoverTarget 'notes.txt') -PathType Leaf) 'the restore of backups without a password brought the chosen item back'
    $leftoverCalls = @(Get-Content -LiteralPath $leftoverFixture.Log)
    Assert-True ($leftoverCalls.Count -ge 3 -and @($leftoverCalls | Where-Object { $_ -notmatch '(^|\t)--insecure-no-password(\t|$)' -or $_ -match 'password-command' -or $_ -match 'secret_store' }).Count -eq 0) 'a saved password left by an older install is never turned into a password command for backups without a password'
    Assert-True ((Get-Hash -Path $leftoverFixture.RecoveryKey) -ceq $leftoverKeyHash -and (Get-Hash -Path $leftoverFixture.Secret) -ceq $leftoverSecretHash) 'an older recovery key and saved password were left byte for byte as they were'
    $leftoverHistory = Get-Content -LiteralPath (Join-Path $leftoverFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True (@($leftoverHistory.entries).Count -eq 1 -and [string]$leftoverHistory.entries[0].kind -ceq 'manual_restore' -and
        [string]$leftoverHistory.entries[0].credential_source -ceq 'active_credential' -and $leftoverHistory.entries[0].verified -eq $true) 'a restore of backups without a password is recorded like any restore'

    # The restore drill without a key: no key file is given, Restic opens the backups with the flag, and the report and the
    # history say that no credential was used. The progress says so in plain words.
    $noPasswordDrillFixture = New-Fixture -Access no_password -NoRecoveryKey
    $noPasswordDrill = Invoke-Manager -Fixture $noPasswordDrillFixture -Action restore_drill
    if ($noPasswordDrill.ExitCode -ne 0) {
        Write-Output ("no-password drill output: " + ($noPasswordDrill.Output -join ' | '))
        if ($null -ne $noPasswordDrill.Result) { Write-Output ("no-password drill result: " + ($noPasswordDrill.Result | ConvertTo-Json -Compress -Depth 20)) }
    }
    Assert-True ($noPasswordDrill.ExitCode -eq 0 -and $noPasswordDrill.Result.ok -eq $true -and $noPasswordDrill.Result.history_recorded -eq $true) 'a restore drill of backups without a password succeeds with no recovery key'
    Assert-True ([string]$noPasswordDrill.Result.payload.drill_kind -ceq 'recovery_key_representative' -and
        [string]$noPasswordDrill.Result.payload.credential_source -ceq 'none' -and
        [bool]$noPasswordDrill.Result.payload.canary_verified -and [long]$noPasswordDrill.Result.payload.sample_file_count -eq 2) 'its report names no credential and holds verified canary and sample evidence'
    $noPasswordDrillHistory = Get-Content -LiteralPath (Join-Path $noPasswordDrillFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True (@($noPasswordDrillHistory.entries).Count -eq 1 -and
        [string]$noPasswordDrillHistory.entries[0].kind -ceq 'recovery_key_representative_drill' -and
        [string]$noPasswordDrillHistory.entries[0].credential_source -ceq 'none' -and
        [string]$noPasswordDrillHistory.entries[0].repository_id -ceq $repositoryId -and
        $noPasswordDrillHistory.entries[0].verified -eq $true) 'its history entry keeps the drill kind and records that no credential was used'
    Assert-True ([string]$noPasswordDrill.Progress.stage -ceq 'complete' -and
        [string]$noPasswordDrill.Progress.message -ceq 'Restore drill completed, verified, and was recorded.') 'the drill of backups without a password finishes in plain words'
    # ... and restores in plain words too: they have no recovery key, so the progress never says the sample is restored with one.
    Assert-True ($null -ne $noPasswordDrill.Restoring -and [string]$noPasswordDrill.Restoring.stage -ceq 'restoring' -and [int]$noPasswordDrill.Restoring.percent -eq 25 -and
        [string]$noPasswordDrill.Restoring.message -ceq 'Restoring the restore test file and a small sample of your files.') ('the drill of backups without a password restores in plain words: ' + [string]$noPasswordDrill.Restoring.message)
    $noPasswordDrillCalls = @(Get-Content -LiteralPath $noPasswordDrillFixture.Log)
    Assert-True ($noPasswordDrillCalls.Count -ge 3 -and
        @($noPasswordDrillCalls | Where-Object { $_ -notmatch '(^|\t)--insecure-no-password(\t|$)' -or $_ -notmatch '(^|\t)--no-cache(\t|$)' }).Count -eq 0 -and
        @($noPasswordDrillCalls | Where-Object { ($_ -split "`t") -contains 'ls' }).Count -ge 1) 'the drill listed and restored through the flag, reading only the backup location'
    # The same drill with an older key at the usual path that no longer checks out: it is not looked at either.
    $brokenKeyDrillFixture = New-Fixture -Access no_password -BrokenRecoveryKey
    $brokenKeyDrill = Invoke-Manager -Fixture $brokenKeyDrillFixture -Action restore_drill
    Assert-True ($brokenKeyDrill.ExitCode -eq 0 -and $brokenKeyDrill.Result.ok -eq $true -and [string]$brokenKeyDrill.Result.payload.credential_source -ceq 'none') 'an older, unusable recovery key does not stop the drill of backups without a password'

    # A configuration that says "password" in so many words is the same as one without the key.
    $explicitPasswordFixture = New-Fixture -Access password
    $explicitPasswordList = Invoke-Manager -Fixture $explicitPasswordFixture -Action list_snapshots
    Assert-True ($explicitPasswordList.ExitCode -eq 0 -and $explicitPasswordList.Result.ok -eq $true -and
        -not ((Get-Content -LiteralPath $explicitPasswordFixture.Log -Raw) -match 'insecure-no-password')) 'repository_access password is a backup with a password'
    # ... and for a backup with a password the recovery key is still required (and checked) for every request.
    $missingKeyFixture = New-Fixture -NoRecoveryKey
    $missingKey = Invoke-Manager -Fixture $missingKeyFixture -Action list_snapshots
    Assert-True ($missingKey.ExitCode -ne 0 -and $missingKey.Result.ok -eq $false -and [string]$missingKey.Result.error -match 'Required regular file is missing') 'backups with a password still need their recovery key file'
    Assert-True (-not (Test-Path -LiteralPath $missingKeyFixture.Log)) 'nothing reached Restic when the recovery key was missing'

    # Anything but the two values is refused, before Restic is reached.
    $unsupportedFixture = New-Fixture -Access 'No_Password'
    $unsupportedList = Invoke-Manager -Fixture $unsupportedFixture -Action list_snapshots
    Assert-True ($unsupportedList.ExitCode -ne 0 -and $unsupportedList.Result.ok -eq $false -and [string]$unsupportedList.Result.error -ceq 'unsupported repository_access') 'an unsupported repository_access is refused in plain words'
    Assert-True (-not (Test-Path -LiteralPath $unsupportedFixture.Log)) 'nothing reached Restic for an unsupported repository_access'

    # Backups that now ask for a password (one was added outside Rewindle) fail at once, with nothing waiting for a password.
    $nowPasswordFixture = New-Fixture -Access no_password -NoRecoveryKey -BackupsAre password
    $nowPassword = Invoke-Manager -Fixture $nowPasswordFixture -Action list_snapshots
    Assert-True ($nowPassword.ExitCode -ne 0 -and $nowPassword.Result.ok -eq $false -and [string]$nowPassword.Result.error -notmatch '(?i)(password-command|RESTIC_PASSWORD|dpapi)') 'backups that now ask for a password fail at once'
    # Every request that reads them says so in the same plain words (never "... failed with exit code 1"), whether or not
    # restore.py wrote a report, and the progress the dashboard shows ends in them too.
    Assert-True ([string]$nowPassword.Result.error -ceq $backupsNowAskForAPasswordMessage -and [string]$nowPassword.Progress.stage -ceq 'failed' -and
        [string]$nowPassword.Progress.message -ceq $backupsNowAskForAPasswordMessage) ('listing backups that now ask for a password says so in plain words: ' + [string]$nowPassword.Result.error)
    $nowPasswordTree = Invoke-Manager -Fixture $nowPasswordFixture -Action list_tree -Snapshot $snapshotId -TreePath '/'
    Assert-True ($nowPasswordTree.ExitCode -ne 0 -and $nowPasswordTree.Result.ok -eq $false -and [string]$nowPasswordTree.Result.error -ceq $backupsNowAskForAPasswordMessage) ('opening a folder of backups that now ask for a password says so in plain words: ' + [string]$nowPasswordTree.Result.error)
    $nowPasswordTarget = Join-Path $nowPasswordFixture.Root 'Restored\NowAsks'
    $nowPasswordRestore = Invoke-Manager -Fixture $nowPasswordFixture -Action restore -Snapshot $snapshotId -Target $nowPasswordTarget -Includes @('/notes.txt')
    Assert-True ($nowPasswordRestore.ExitCode -ne 0 -and $nowPasswordRestore.Result.ok -eq $false -and [string]$nowPasswordRestore.Result.error -ceq $backupsNowAskForAPasswordMessage) ('restoring from backups that now ask for a password says so in plain words: ' + [string]$nowPasswordRestore.Result.error)
    $nowPasswordDrill = Invoke-Manager -Fixture $nowPasswordFixture -Action restore_drill
    Assert-True ($nowPasswordDrill.ExitCode -ne 0 -and $nowPasswordDrill.Result.ok -eq $false -and [string]$nowPasswordDrill.Result.error -ceq $backupsNowAskForAPasswordMessage) ('the drill of backups that now ask for a password says so in plain words: ' + [string]$nowPasswordDrill.Result.error)
    Assert-True ([string]$nowPasswordDrill.Progress.stage -ceq 'failed' -and [string]$nowPasswordDrill.Progress.message -ceq $backupsNowAskForAPasswordMessage) 'the drill progress ends in the same words'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $nowPasswordFixture.State 'RestoreManagerResults') -Filter '*.restore-report.json' -Force -ErrorAction SilentlyContinue).Count -eq 0) 'no report of the refused restore or drill is left behind'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nowPasswordFixture.State 'restore-history.json'))) 'a drill or restore that could not open the backups records nothing'
    Assert-True (-not (@(Get-Content -LiteralPath $nowPasswordFixture.Log) | Where-Object { ($_ -split "`t") -contains 'restore' })) 'Restic was never asked to restore backups that now ask for a password'
    # The manager lets restore.py's words through only when they are the whole of its last line, and only for backups without a password.
    $backendSentence = 'RESTORE FAILED: ' + $backupsNowAskForAPasswordMessage
    function Test-AskedForAPassword([string]$Access, [string]$Stderr, [int]$ExitCode = 1, [bool]$TimedOut = $false) {
        return [bool](Test-BackendAskedForAPassword -Backend ([pscustomobject]@{ ExitCode = $ExitCode; Stdout = ''; Stderr = $Stderr; TimedOut = $TimedOut }) -RepositoryAccess $Access)
    }
    Assert-True (Test-AskedForAPassword 'no_password' ($backendSentence + "`r`n")) 'the sentence as the last line is passed on'
    Assert-True (Test-AskedForAPassword 'no_password' ("RESTORE INCOMPLETE: something`r`n`r`n" + $backendSentence + "`r`n`r`n")) 'the sentence after other lines, with blank lines around it, is passed on'
    Assert-True (-not (Test-AskedForAPassword 'password' ($backendSentence + "`r`n"))) 'backups with a password never get the sentence'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backendSentence + "`r`n") 0)) 'a backend that ended well is not read for it'
    Assert-True (-not (Test-AskedForAPassword 'no_password' '' (-1) $true)) 'a backend that ran out of time is not read for it'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backendSentence + "`r`nRESTORE INCOMPLETE: Restic exited with 12"))) 'a line after the sentence means it was not the last word'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backendSentence + ' More words.'))) 'the sentence with more words after it is not passed on'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backendSentence.ToLowerInvariant()))) 'the sentence is compared exactly'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ('RESTORE FAILED: Restic repository query failed with exit code 12'))) 'another failure is not turned into the sentence'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backupsNowAskForAPasswordMessage))) 'the sentence alone, without the failure line it is printed on, is not passed on'
    Assert-True (-not (Test-AskedForAPassword 'No_Password' ($backendSentence))) 'the access is compared exactly'
    # A backend that was stopped for running out of time may still have printed the sentence as its last line before it was stopped:
    # what a stopped backend leaves behind is never read as its answer (the manager gives it exit code -1 and no output, but the
    # check does not rely on that).
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backendSentence + "`r`n") 1 $true)) 'a backend that ran out of time is not read for the sentence, whatever its last line says'
    Assert-True (-not (Test-AskedForAPassword 'no_password' ($backendSentence + "`r`n") (-1) $true)) 'a backend stopped with exit code -1 is not read for the sentence either'
    Assert-True (Test-AskedForAPassword 'no_password' ($backendSentence + "`r`n") 1 $false) 'the same last line from a backend that was not stopped is the sentence'
    # A backend that failed without a word has no last line to read: the answer is no, and nothing is thrown. The manager runs under
    # $ErrorActionPreference = 'Stop' (and StrictMode), where reading the last line of nothing ("Index was outside the bounds of the
    # array.", or "You cannot call a method on a null-valued expression." without StrictMode) would end the request with that error
    # instead of the backend's own failure.
    $preferenceBeforeSilentBackends = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        foreach ($silentStderr in @('', "`r`n", "  `r`n`t`r`n")) {
            $silentAnswer = $null
            $silentFailure = ''
            try { $silentAnswer = Test-AskedForAPassword 'no_password' $silentStderr 1 $false }
            catch { $silentFailure = [string]$_.Exception.Message }
            Assert-True ($silentFailure -ceq '' -and $silentAnswer -is [bool] -and -not $silentAnswer) ('a backend that failed without a word is not read for the sentence and throws nothing: ' + $silentFailure)
        }
    }
    finally { $ErrorActionPreference = $preferenceBeforeSilentBackends }

    $partialDrillFixture = New-Fixture
    $env:FAKE_RESTORE_PARTIAL = '1'
    try { $partialDrill = Invoke-Manager -Fixture $partialDrillFixture -Action restore_drill }
    finally { Remove-Item Env:FAKE_RESTORE_PARTIAL -ErrorAction SilentlyContinue }
    $expectedPartialDrillTarget = [IO.Path]::GetFullPath((Join-Path $partialDrillFixture.Root "ProgramData\ResticBackuper-RestoreDrills\drill-$($partialDrill.Nonce)")).TrimEnd('\')
    Assert-True ($partialDrill.ExitCode -eq 23 -and $partialDrill.Result.ok -eq $false -and
        [string]$partialDrill.Result.payload.result -ceq 'partial' -and
        $partialDrill.Result.payload.partial_target_retained -eq $true -and
        [string]$partialDrill.Result.payload.target -ceq $expectedPartialDrillTarget) 'failed drill retains and reports its manager-derived target'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $partialDrillFixture.State 'restore-history.json'))) 'failed drill never records passing readiness history'

    $partialFixture = New-Fixture
    $partialTarget = Join-Path $partialFixture.Root 'Restored\Partial'
    $env:FAKE_RESTORE_PARTIAL = '1'
    try { $partial = Invoke-Manager -Fixture $partialFixture -Action restore -Snapshot $snapshotId -Target $partialTarget }
    finally { Remove-Item Env:FAKE_RESTORE_PARTIAL -ErrorAction SilentlyContinue }
    Assert-True ($partial.ExitCode -eq 23 -and $partial.Result.ok -eq $false) 'partial restore reports backend failure'
    Assert-True ([string]$partial.Result.payload.result -ceq 'partial' -and $partial.Result.payload.partial_target_retained -eq $true) 'partial target retention reported'
    Assert-True (Test-Path -LiteralPath (Join-Path $partialTarget 'partial.txt') -PathType Leaf) 'partial target retained'
    $partialHistory = Get-Content -LiteralPath (Join-Path $partialFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True ($partial.Result.history_recorded -eq $true -and @($partialHistory.entries).Count -eq 1 -and $partialHistory.entries[0].partial_target_retained -eq $true) 'partial restore is retained in protected history'

    $unsafeFixture = New-Fixture
    $unsafe = Invoke-Manager -Fixture $unsafeFixture -Action restore -Snapshot $snapshotId -Target $unsafeFixture.Source
    Assert-True ($unsafe.ExitCode -ne 0 -and $unsafe.Result.ok -eq $false -and $unsafe.Result.error -match 'must not overlap') 'live source restore target rejected'
    Assert-True (-not ((Get-Content -LiteralPath $unsafeFixture.Log -Raw) -match '(?m)(^|\t)restore(\t|$)')) 'unsafe target rejected before Restic restore'

    $digestFixture = New-Fixture
    $badDigest = Invoke-Manager -Fixture $digestFixture -Action list_snapshots -DigestOverride ('0' * 64)
    Assert-True ($badDigest.ExitCode -ne 0 -and $null -eq $badDigest.Result) 'forged digest rejected before result channel'

    $planFixture = New-Fixture
    $wrongPlan = Invoke-Manager -Fixture $planFixture -Action list_snapshots -Plan 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    Assert-True ($wrongPlan.ExitCode -ne 0 -and $wrongPlan.Result.ok -eq $false -and $wrongPlan.Result.error -match 'another backup plan') 'wrong requested plan rejected'

    $journalFixture = New-Fixture
    [IO.File]::WriteAllText((Join-Path $journalFixture.State 'plan-migration.journal.json'), "{}`n", $encoding)
    $journal = Invoke-Manager -Fixture $journalFixture -Action list_snapshots
    Assert-True ($journal.ExitCode -ne 0 -and $journal.Result.error -match 'pending protected-operation journal') 'pending migration journal gates restore'

    $lockFixture = New-Fixture
    $held = [IO.File]::Open((Join-Path $lockFixture.State 'run.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { $held.Lock(0,1); $locked = Invoke-Manager -Fixture $lockFixture -Action list_snapshots }
    finally { try { $held.Unlock(0,1) } finally { $held.Dispose() } }
    Assert-True ($locked.ExitCode -ne 0 -and $locked.Result.error -match 'run lock') 'shared backup lock gates restore'

    $orphanFixture = New-Fixture
    $orphanDirectory = Join-Path $orphanFixture.State 'RestoreManagerResults'
    [void][IO.Directory]::CreateDirectory($orphanDirectory)
    $orphanPath = Join-Path $orphanDirectory (('a' * 64) + '.restore-report.json')
    [IO.File]::WriteAllText($orphanPath, "{}`n", $encoding)
    $orphanRecovery = Invoke-Manager -Fixture $orphanFixture -Action list_snapshots
    Assert-True ($orphanRecovery.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $orphanPath)) 'orphaned backend report is recovered under the run lock'

    $unmanifestedFixture = New-Fixture
    [IO.File]::WriteAllText((Join-Path $unmanifestedFixture.Install 'injected.txt'), "unexpected`n", $encoding)
    $unmanifested = Invoke-Manager -Fixture $unmanifestedFixture -Action list_snapshots
    Assert-True ($unmanifested.ExitCode -ne 0 -and $unmanifested.Result.error -match 'unmanifested or missing files') 'unmanifested protected runtime file is rejected'

    # A folder link inside the runtime is still refused now that each folder's chain is walked once per check.
    $junctionFixture = New-Fixture
    $outside = Join-Path $junctionFixture.Root 'Outside'
    [void][IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $outside 'module.py'), "# outside the runtime`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $outside 'second.py'), "# outside the runtime`n", $encoding)
    $junction = Join-Path $junctionFixture.Install 'Python\Lib'
    & cmd.exe /d /c mklink /J "$junction" "$outside" | Out-Null
    Assert-True (([IO.File]::GetAttributes($junction) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'junction fixture created'
    $junctionManifestPath = Join-Path $junctionFixture.Install 'runtime-manifest.json'
    $junctionManifest = Get-Content -LiteralPath $junctionManifestPath -Raw | ConvertFrom-Json
    $junctionRecords = @($junctionManifest.files) + @(
        (New-FileRecord -Root $junctionFixture.Install -Path (Join-Path $junction 'module.py')),
        (New-FileRecord -Root $junctionFixture.Install -Path (Join-Path $junction 'second.py'))
    )
    Write-Json -Path $junctionManifestPath -Value ([ordered]@{ schema_version = 1; file_count = $junctionRecords.Count; files = $junctionRecords })
    $junctioned = Invoke-Manager -Fixture $junctionFixture -Action list_snapshots
    [IO.Directory]::Delete($junction)
    Assert-True ($junctioned.ExitCode -ne 0 -and $junctioned.Result.error -match 'reparse point') 'runtime folder link is rejected'

    # Listings read through the backup's cache and take no Restic lock; a restore keeps the lock; a recovery drill
    # reads only the backup location; and before the first backup has made a cache, Restic keeps its own.
    $cacheToken = "`t--cache-dir`t" + (Join-Path $fixture.State 'cache') + "`t"
    $listingFixture = New-Fixture
    $listingCache = "`t--cache-dir`t" + (Join-Path $listingFixture.State 'cache') + "`t"
    [void](Invoke-Manager -Fixture $listingFixture -Action list_snapshots)
    [void](Invoke-Manager -Fixture $listingFixture -Action list_tree -Snapshot $snapshotId -TreePath '/')
    $listingCalls = @(Get-Content -LiteralPath $listingFixture.Log)
    Assert-True ($listingCalls.Count -ge 3 -and
        @($listingCalls | Where-Object { -not $_.Contains($listingCache) -or $_ -notmatch '(^|\t)--no-lock(\t|$)' }).Count -eq 0) 'listings read through the backup cache without a Restic lock'
    $restoreCalls = @(Get-Content -LiteralPath $fixture.Log | Where-Object { $_ -match '(^|\t)restore(\t|$)' })
    Assert-True ($restoreCalls.Count -ge 1 -and
        @($restoreCalls | Where-Object { -not $_.Contains($cacheToken) -or $_ -match '(^|\t)--no-lock(\t|$)' }).Count -eq 0) 'a restore reads through the backup cache and keeps the Restic lock'
    $drillCalls = @(Get-Content -LiteralPath $drillFixture.Log)
    Assert-True ($drillCalls.Count -ge 1 -and
        @($drillCalls | Where-Object { $_ -match '(^|\t)--cache-dir(\t|$)' -or $_ -notmatch '(^|\t)--no-cache(\t|$)' }).Count -eq 0) 'a recovery drill reads only the backup location'
    $uncachedFixture = New-Fixture
    [IO.Directory]::Delete((Join-Path $uncachedFixture.State 'cache'))
    $uncached = Invoke-Manager -Fixture $uncachedFixture -Action list_snapshots
    Assert-True ($uncached.ExitCode -eq 0 -and $uncached.Result.ok -eq $true -and
        (Get-Content -LiteralPath $uncachedFixture.Log -Raw) -notmatch '(^|\t)--cache-dir(\t|$)') 'without a backup cache yet, Restic keeps its own'

    $logText = Get-Content -LiteralPath $fixture.Log -Raw
    Assert-True ($logText -match '\tcat\tconfig' -and $logText -match '\tsnapshots\t--json' -and $logText -match '\tls\t--json') 'read-only Restic metadata commands used'
    Assert-True ($logText -match '\trestore\t' -and $logText -match '\t--overwrite\tnever\t' -and $logText -match '\t--verify') 'restore uses non-overwrite verification contract'
    Assert-True ($logText -notmatch '(?im)(^|\t)(backup|init|forget|prune|delete)(\t|$)') 'manager never invokes destructive/history-changing Restic commands'
    Assert-True ((Get-Hash -Path (Join-Path $fixture.Repository 'pack')) -eq $repositoryBefore) 'repository content unchanged'
    Assert-True ((Get-Hash -Path (Join-Path $fixture.Source 'live.txt')) -eq $sourceBefore) 'live source unchanged'

    # ------------------------------------------------------------------------------------------------------------------
    # Restore approval session (-Operation session). The protocol's own rules are unit-tested on the functions the manager
    # defines (loaded from its source with the PowerShell parser, never by running it); the session itself is run in the
    # disposable mode, non-elevated, with this process as the dashboard. Nothing here touches a real installation.
    # ------------------------------------------------------------------------------------------------------------------
    $sessionFunctionNames = @(
        'Get-Sha256Hex', 'New-SessionException', 'Test-FixedTextEqual', 'Assert-SessionTimeouts', 'ConvertTo-SessionFrame',
        'Get-SessionFrameLength', 'ConvertFrom-SessionFrameBody', 'Assert-SessionMessageFields', 'Get-SessionMessageType',
        'Get-SessionString', 'Get-SessionInteger', 'ConvertTo-SessionHello', 'ConvertTo-SessionRequest', 'Assert-RestoreSessionClient',
        'Test-PathEqual', 'Get-CanonicalLocalPath', 'Get-OptionalProperty', 'Get-FindTextProblem', 'Test-FindPayloadInteger',
        'Test-FindPayloadTime', 'Test-FindPayloadPath', 'Get-FindPayloadArray', 'Assert-FindPayload'
    )
    $parseTokens = $null
    $parseErrors = $null
    $managerAst = [Management.Automation.Language.Parser]::ParseFile($managerSource, [ref]$parseTokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'the restore manager parses'
    $sessionFunctions = @($managerAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $sessionFunctionNames
    }, $false))
    Assert-True ($sessionFunctions.Count -eq $sessionFunctionNames.Count) 'every session protocol function was found in the manager'
    foreach ($definition in $sessionFunctions) { . ([scriptblock]::Create($definition.Extent.Text)) }
    # The script-level values those functions read, exactly as the manager sets them.
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $sessionProtocol = 'ResticBackuper.RestoreSession.v1'
    $sessionMinimumSeconds = 5
    $sessionMaximumIdleSeconds = 600
    $sessionMaximumLifetimeSeconds = 3600
    $sessionMaximumConnectSeconds = 300
    $sessionSettingsText = [regex]::Matches((Get-Content -LiteralPath $managerSource -Raw),
        '(?m)^\$session(Protocol|MinimumSeconds|MaximumIdleSeconds|MaximumLifetimeSeconds|MaximumConnectSeconds|MaximumRequestBytes|MaximumResponseBytes) = (.+)$')
    $sessionSettings = @{}
    foreach ($match in $sessionSettingsText) { $sessionSettings[$match.Groups[1].Value] = $match.Groups[2].Value.Trim() }
    Assert-True ($sessionSettings['Protocol'] -ceq "'ResticBackuper.RestoreSession.v1'" -and $sessionSettings['MinimumSeconds'] -ceq '5' -and
        $sessionSettings['MaximumIdleSeconds'] -ceq '600' -and $sessionSettings['MaximumLifetimeSeconds'] -ceq '3600' -and
        $sessionSettings['MaximumConnectSeconds'] -ceq '300' -and $sessionSettings['MaximumRequestBytes'] -ceq '256KB' -and
        $sessionSettings['MaximumResponseBytes'] -ceq '8MB') 'the session limits the unit checks use are the manager''s own'

    function Get-SessionFailureReason([scriptblock]$Action) {
        try { & $Action; return $null }
        catch { return [string]$_.Exception.Data['restore_session_reason'] }
    }
    function ConvertTo-TestJsonObject([string]$Text) { return (ConvertFrom-Json -InputObject $Text) }

    # Framing: a little-endian length before one UTF-8 object, inside the limit on both sides.
    $sampleFrame = ConvertTo-SessionFrame -Message ([ordered]@{ type = 'close' }) -MaximumBytes 64
    Assert-True ($sampleFrame.Length -eq 4 + 16 -and $sampleFrame[0] -eq 16 -and $sampleFrame[1] -eq 0 -and $sampleFrame[3] -eq 0) 'a frame carries its little-endian length'
    Assert-True ((Get-SessionFrameLength -Header ([byte[]]@(16, 0, 0, 0)) -MaximumBytes 64) -eq 16) 'a frame length is read back'
    Assert-True ((Get-SessionFrameLength -Header ([byte[]]@(0, 0, 4, 0)) -MaximumBytes 262144) -eq 262144) 'a frame at the request limit is accepted'
    Assert-True ((Get-SessionFailureReason { Get-SessionFrameLength -Header ([byte[]]@(1, 0, 4, 0)) -MaximumBytes 262144 }) -ceq 'frame_too_large') 'a frame one byte over the request limit is refused'
    Assert-True ((Get-SessionFailureReason { Get-SessionFrameLength -Header ([byte[]]@(0, 0, 0, 0)) -MaximumBytes 262144 }) -ceq 'frame_too_large') 'an empty frame is refused'
    Assert-True ((Get-SessionFailureReason { Get-SessionFrameLength -Header ([byte[]]@(255, 255, 255, 255)) -MaximumBytes 8388608 }) -ceq 'frame_too_large') 'a frame claiming 4 GiB is refused'
    Assert-True ((Get-SessionFailureReason { Get-SessionFrameLength -Header ([byte[]]@(1, 0)) -MaximumBytes 64 }) -ceq 'malformed_frame') 'a short header is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionFrame -Message ([ordered]@{ type = ('x' * 100) }) -MaximumBytes 64 }) -ceq 'frame_too_large') 'an outgoing message over its limit is never sent'
    Assert-True ((Get-SessionFailureReason { ConvertFrom-SessionFrameBody -Body ([byte[]]@(0x7B, 0xC3, 0x28, 0x7D)) }) -ceq 'malformed_frame') 'a frame that is not UTF-8 is refused'
    Assert-True ((Get-SessionFailureReason { ConvertFrom-SessionFrameBody -Body $encoding.GetBytes('[1,2]') }) -ceq 'malformed_frame') 'a frame that is not one object is refused'
    Assert-True ((Get-SessionFailureReason { ConvertFrom-SessionFrameBody -Body $encoding.GetBytes('{"type":') }) -ceq 'malformed_frame') 'a frame that is not JSON is refused'
    Assert-True ((Get-SessionFailureReason { ConvertFrom-SessionFrameBody -Body ([byte[]](@(0xEF, 0xBB, 0xBF) + $encoding.GetBytes('{"type":"close"}'))) }) -ceq 'malformed_frame') 'a frame with a byte-order mark is refused'
    Assert-True ((Get-SessionMessageType -Message (ConvertFrom-SessionFrameBody -Body $encoding.GetBytes('{"type":"close"}'))) -ceq 'close') 'a well-formed frame is read'

    # Schema: exactly the fields of each message, with their types; an unknown or missing field, a wrong type or a request out
    # of sequence ends the session; a session never serves a recovery drill.
    $goodToken = 'c' * 64
    $hello = ConvertTo-SessionHello -Message (ConvertTo-TestJsonObject ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken + '","dashboard_process_id":1234}'))
    Assert-True ($hello.Token -ceq $goodToken -and $hello.ProcessId -eq 1234) 'a valid hello is accepted'
    foreach ($badHello in @(
        ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken + '"}'),
        ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken + '","dashboard_process_id":1234,"extra":1}'),
        ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v2","session_token":"' + $goodToken + '","dashboard_process_id":1234}'),
        ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken + '","dashboard_process_id":"1234"}'),
        ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken + '","Dashboard_process_id":1234}'),
        ('{"type":"request","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken + '","dashboard_process_id":1234}')
    )) {
        Assert-True ((Get-SessionFailureReason { ConvertTo-SessionHello -Message (ConvertTo-TestJsonObject $badHello) }) -ceq 'schema_violation') ('a malformed hello was accepted: ' + $badHello)
    }
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionHello -Message (ConvertTo-TestJsonObject ('{"type":"hello","protocol":"ResticBackuper.RestoreSession.v1","session_token":"' + $goodToken.ToUpperInvariant() + '","dashboard_process_id":1234}')) }) -ceq 'token_mismatch') 'a token that is not lower-case hex is refused'
    $emptyIncludes = [Convert]::ToBase64String($encoding.GetBytes('[]'))
    function New-TestRequestText([long]$Id, [string]$RequestAction = 'list_snapshots', [string]$Extra = '') {
        return '{"type":"request","request_id":' + $Id + ',"action":"' + $RequestAction + '","snapshot_id":"","tree_path":"","target":"","includes_base64":"' + $emptyIncludes + '","allow_legacy_unbound":"0"' + $Extra + '}'
    }
    $parsedRequest = ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1)) -ExpectedRequestId 1
    Assert-True ($parsedRequest.Action -ceq 'list_snapshots' -and $parsedRequest.RequestId -eq 1 -and $parsedRequest.IncludesBase64 -ceq $emptyIncludes) 'a valid request is accepted'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 2)) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a request out of sequence is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'list_snapshots' ',"x":1')) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a request with an extra field is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'restore_drill')) -ExpectedRequestId 1 }) -ceq 'action_not_allowed') 'a session refuses a recovery drill'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'delete')) -ExpectedRequestId 1 }) -ceq 'action_not_allowed') 'a session refuses an unknown action'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject ((New-TestRequestText 1).Replace('"allow_legacy_unbound":"0"', '"allow_legacy_unbound":false'))) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a request field of the wrong type is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject ((New-TestRequestText 1).Replace('"target":""', ('"target":"' + ('x' * 4097) + '"')))) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'an over-long request field is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject ((New-TestRequestText 1).Replace('"request_id":1', '"request_id":1.5'))) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a fractional request id is refused'

    # A file search: two more fields, only on a find_files request, and the shared text rules.
    $findFields = ',"find_text":"Budget","find_from_snapshot_id":"' + $snapshotId + '"'
    $parsedFind = ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'find_files' $findFields)) -ExpectedRequestId 1
    Assert-True ($parsedFind.Action -ceq 'find_files' -and $parsedFind.FindText -ceq 'Budget' -and $parsedFind.FindFromSnapshotId -ceq $snapshotId) 'a file search request is accepted'
    Assert-True ($parsedRequest.FindText -ceq '' -and $parsedRequest.FindFromSnapshotId -ceq '') 'a listing carries no search fields'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'find_files')) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a file search without its two fields is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'list_snapshots' $findFields)) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a listing with search fields is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'find_files' (',"find_text":"' + ('x' * 257) + '","find_from_snapshot_id":"' + $snapshotId + '"'))) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'an over-long search text is refused'
    Assert-True ((Get-SessionFailureReason { ConvertTo-SessionRequest -Message (ConvertTo-TestJsonObject (New-TestRequestText 1 'find_files' (',"find_text":5,"find_from_snapshot_id":"' + $snapshotId + '"'))) -ExpectedRequestId 1 }) -ceq 'schema_violation') 'a search text that is not a string is refused'
    # Windows PowerShell's ConvertFrom-Json writes an array as one object (the parentheses and ForEach-Object take it apart)
    # and reads an unpaired surrogate (\ud800 in the file) as U+FFFD, so each text is also read from the file as written.
    $findCasesJson = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\file-search-text-cases.json') -Raw -Encoding UTF8
    $findCases = @(($findCasesJson | ConvertFrom-Json) | ForEach-Object { $_ })
    $findCaseTexts = @([regex]::Matches($findCasesJson, '"text": "((?:[^"\\]|\\.)*)"') | ForEach-Object { [regex]::Unescape($_.Groups[1].Value) })
    Assert-True ($findCases.Count -gt 30 -and $findCaseTexts.Count -eq $findCases.Count) 'the shared file-search text cases were read'
    for ($caseIndex = 0; $caseIndex -lt $findCases.Count; $caseIndex++) {
        $case = $findCases[$caseIndex]
        $caseText = [string]$findCaseTexts[$caseIndex]
        $expectedProblem = if ($case.valid) { '' } else { [string]$case.error }
        Assert-True ((Get-FindTextProblem -Value $caseText) -ceq $expectedProblem) ('shared file-search text case ' + $caseIndex + ' gives ' + $expectedProblem)
        if ($case.valid) { Assert-True ($caseText.Trim([char]0x20) -ceq [string]$case.normalized) ('shared file-search text case ' + $caseIndex + ' trims to its normal form') }
    }

    # What restore.py --find-json returns must answer this search, for this backup location and plan.
    $fileSearchSchema = 'ResticBackuper.FileSearch.v1'
    Assert-True ((Get-Content -LiteralPath $managerSource -Raw) -match "(?m)^\`$fileSearchSchema = 'ResticBackuper\.FileSearch\.v1'\r?$") 'the file-search schema the unit checks use is the manager''s own'
    $ExpectedPlanId = $planId
    $findText = 'Budget'
    $findFromSnapshotId = $snapshotId
    $findConfiguration = [pscustomobject]@{ Repository = 'C:\Backups\Personal' }
    function New-TestFindPayload {
        return (ConvertFrom-Json -InputObject ('{"schema":"ResticBackuper.FileSearch.v1","schema_version":1,"repository":"C:\\Backups\\Personal",' +
            '"binding":{"plan_id":"' + $planId + '","legacy_match_policy":"exact-host-scheduled-tags-and-sources"},' +
            '"query":{"text":"Budget","from_snapshot_id":"' + $snapshotId + '"},"status":"more","snapshots_total":3,"snapshots_searched":1,' +
            '"searched_newest_time":"2026-07-20T02:00:00.0000000Z","searched_oldest_time":"2026-07-20T02:00:00.0000000Z",' +
            '"next_from_snapshot_id":"' + $legacySnapshotId + '","matches_total":1,"skipped":0,"elapsed_ms":120,' +
            '"matches":[{"path":"/C/Docs/Budget.xlsx","name":"Budget.xlsx","type":"file","versions_total":1,"versions":[' +
            '{"size":10,"mtime":"2026-07-19T08:00:00.1234567Z","snapshot_id":"' + $snapshotId + '","snapshot_time":"2026-07-20T02:00:00.0000000Z",' +
            '"first_snapshot_id":"' + $snapshotId + '","first_snapshot_time":null,"backups":1,"binding_state":"plan"}]}]}'))
    }
    function Test-FindPayloadAccepted([scriptblock]$Change) {
        $payload = New-TestFindPayload
        & $Change $payload
        try { Assert-FindPayload -Payload $payload -Configuration $findConfiguration; return $true }
        catch { return $false }
    }
    Assert-True (Test-FindPayloadAccepted { param($p) }) 'a file-search payload bound to the search is accepted'
    Assert-True (Test-FindPayloadAccepted { param($p) $p.status = 'complete'; $p.next_from_snapshot_id = $null }) 'a finished search without a next start is accepted'
    Assert-True (Test-FindPayloadAccepted { param($p) $p.matches = @(); $p.status = 'too_broad' }) 'a search that found nothing is accepted'
    Assert-True (Test-FindPayloadAccepted { param($p) $p.status = 'too_many'; $p.next_from_snapshot_id = $null }) 'too many matches up to the oldest backup is accepted without a next start'
    Assert-True (Test-FindPayloadAccepted { param($p) $p.matches[0].versions[0].binding_state = 'legacy_unbound' }) 'a version in an older-setup backup is accepted'
    $findDefects = @(
        @{ Name = 'another schema'; Change = { param($p) $p.schema = 'ResticBackuper.FileSearch.v2' } },
        @{ Name = 'another backup location'; Change = { param($p) $p.repository = 'C:\Backups\Other' } },
        @{ Name = 'another plan'; Change = { param($p) $p.binding.plan_id = '87654321-4321-4abc-8def-ba0987654321' } },
        @{ Name = 'another text'; Change = { param($p) $p.query.text = 'budget' } },
        @{ Name = 'another start'; Change = { param($p) $p.query.from_snapshot_id = $legacySnapshotId } },
        @{ Name = 'an unknown status'; Change = { param($p) $p.status = 'stopped' } },
        @{ Name = 'more searched than listed'; Change = { param($p) $p.snapshots_searched = 4 } },
        @{ Name = 'a count that is text'; Change = { param($p) $p.snapshots_total = '3' } },
        @{ Name = 'too many backups'; Change = { param($p) $p.snapshots_total = 10001 } },
        @{ Name = 'an unfinished search without a next start'; Change = { param($p) $p.next_from_snapshot_id = $null } },
        @{ Name = 'a search cut short without a next start'; Change = { param($p) $p.status = 'too_slow'; $p.next_from_snapshot_id = $null } },
        @{ Name = 'a finished search with a next start'; Change = { param($p) $p.status = 'complete' } },
        @{ Name = 'a next start that is not exact'; Change = { param($p) $p.next_from_snapshot_id = $legacySnapshotId.ToUpperInvariant() } },
        @{ Name = 'no list of matches'; Change = { param($p) $p.matches = $null } },
        @{ Name = 'more than 100 matches'; Change = { param($p) $first = $p.matches[0]; $p.matches = @(for ($i = 0; $i -lt 101; $i++) { $first }) } },
        @{ Name = 'a path with a .. part'; Change = { param($p) $p.matches[0].path = '/C/Docs/../Budget.xlsx' } },
        @{ Name = 'a Windows path'; Change = { param($p) $p.matches[0].path = 'C:\Docs\Budget.xlsx' } },
        @{ Name = 'the top of the backup'; Change = { param($p) $p.matches[0].path = '/'; $p.matches[0].name = '' } },
        @{ Name = 'a name that is not the last part'; Change = { param($p) $p.matches[0].name = 'Other.xlsx' } },
        @{ Name = 'a link'; Change = { param($p) $p.matches[0].type = 'symlink' } },
        @{ Name = 'no versions'; Change = { param($p) $p.matches[0].versions = @() } },
        @{ Name = 'eleven versions'; Change = { param($p) $one = $p.matches[0].versions[0]; $p.matches[0].versions = @(for ($i = 0; $i -lt 11; $i++) { $one }); $p.matches[0].versions_total = 11 } },
        @{ Name = 'fewer versions in total than listed'; Change = { param($p) $p.matches[0].versions_total = 0 } },
        @{ Name = 'a version in an unknown backup form'; Change = { param($p) $p.matches[0].versions[0].snapshot_id = 'abc' } },
        @{ Name = 'a version bound to the configuration only'; Change = { param($p) $p.matches[0].versions[0].binding_state = 'configuration' } },
        @{ Name = 'a negative size'; Change = { param($p) $p.matches[0].versions[0].size = -1 } },
        @{ Name = 'a size that is text'; Change = { param($p) $p.matches[0].versions[0].size = '10' } },
        @{ Name = 'a version in no backup'; Change = { param($p) $p.matches[0].versions[0].backups = 0 } },
        @{ Name = 'a time that is a number'; Change = { param($p) $p.matches[0].versions[0].mtime = 5 } }
    )
    foreach ($defect in $findDefects) {
        Assert-True (-not (Test-FindPayloadAccepted $defect.Change)) ('a file-search payload with ' + $defect.Name + ' was accepted')
    }

    # The client: Windows' word on its process and account, and the token.
    $tokenHash = Get-Sha256Hex -Bytes $encoding.GetBytes($goodToken)
    Assert-RestoreSessionClient -ObservedProcessId 42 -ObservedUserSid $sid -ClaimedProcessId 42 -PresentedToken $goodToken -ExpectedProcessId 42 -ExpectedSid $sid -ExpectedTokenSha256 $tokenHash
    Assert-True ((Get-SessionFailureReason { Assert-RestoreSessionClient -ObservedProcessId 43 -ObservedUserSid $sid -ClaimedProcessId 42 -PresentedToken $goodToken -ExpectedProcessId 42 -ExpectedSid $sid -ExpectedTokenSha256 $tokenHash }) -ceq 'client_process_mismatch') 'another client process is refused'
    Assert-True ((Get-SessionFailureReason { Assert-RestoreSessionClient -ObservedProcessId 42 -ObservedUserSid $sid -ClaimedProcessId 43 -PresentedToken $goodToken -ExpectedProcessId 42 -ExpectedSid $sid -ExpectedTokenSha256 $tokenHash }) -ceq 'client_process_mismatch') 'a client claiming another process is refused'
    Assert-True ((Get-SessionFailureReason { Assert-RestoreSessionClient -ObservedProcessId 42 -ObservedUserSid 'S-1-5-21-1-2-3-1001' -ClaimedProcessId 42 -PresentedToken $goodToken -ExpectedProcessId 42 -ExpectedSid $sid -ExpectedTokenSha256 $tokenHash }) -ceq 'client_account_mismatch') 'a client running as another account is refused'
    Assert-True ((Get-SessionFailureReason { Assert-RestoreSessionClient -ObservedProcessId 42 -ObservedUserSid '' -ClaimedProcessId 42 -PresentedToken $goodToken -ExpectedProcessId 42 -ExpectedSid $sid -ExpectedTokenSha256 $tokenHash }) -ceq 'client_account_mismatch') 'a client Windows could not name is refused'
    Assert-True ((Get-SessionFailureReason { Assert-RestoreSessionClient -ObservedProcessId 42 -ObservedUserSid $sid -ClaimedProcessId 42 -PresentedToken ('d' * 64) -ExpectedProcessId 42 -ExpectedSid $sid -ExpectedTokenSha256 $tokenHash }) -ceq 'token_mismatch') 'a client with another token is refused'
    $timeoutRefused = $false
    try { Assert-SessionTimeouts -Idle 601 -Lifetime 3600 -Connect 120 } catch { $timeoutRefused = $true }
    Assert-True $timeoutRefused 'an idle timeout over ten minutes is refused'
    $timeoutRefused = $false
    try { Assert-SessionTimeouts -Idle 600 -Lifetime 3601 -Connect 120 } catch { $timeoutRefused = $true }
    Assert-True $timeoutRefused 'a session lifetime over an hour is refused'
    $timeoutRefused = $false
    try { Assert-SessionTimeouts -Idle 4 -Lifetime 3600 -Connect 120 } catch { $timeoutRefused = $true }
    Assert-True $timeoutRefused 'a timeout under the minimum is refused'
    Assert-SessionTimeouts -Idle 600 -Lifetime 3600 -Connect 120

    # The running session.
    $powershellPath = $powershell
    function ConvertTo-CommandLineArgument([string]$Value) {
        if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
        return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    function New-SessionSecret { return ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant() }
    function Start-SessionBroker {
        param(
            [pscustomobject]$Fixture,
            [long]$DashboardPid = $PID,
            [int]$Idle = 60,
            [int]$Lifetime = 600,
            [int]$Connect = 30,
            [string]$UserSid = $sid,
            [string]$PipeOverride = '',
            [string]$DigestOverride = '',
            [switch]$LegacyFixture
        )
        $nonce = New-SessionSecret
        $token = New-SessionSecret
        $pipeName = if ($PipeOverride) { $PipeOverride } else { 'ResticBackuper.RestoreSession.' + (New-SessionSecret) }
        $tokenSha256 = Get-BytesHash -Bytes $encoding.GetBytes($token)
        $configHash = Get-Hash -Path $Fixture.ConfigPath
        $digestPayload = @(
            'ResticBackuper.RestoreRequest.v3', $UserSid, 'session', $configHash, $planId,
            $generation.ToString([Globalization.CultureInfo]::InvariantCulture),
            $DashboardPid.ToString([Globalization.CultureInfo]::InvariantCulture), $pipeName, $tokenSha256,
            [string]$Idle, [string]$Lifetime, [string]$Connect, $nonce
        ) -join "`n"
        $digest = if ($DigestOverride) { $DigestOverride } else { Get-BytesHash -Bytes $encoding.GetBytes($digestPayload) }
        $resultPath = Join-Path $Fixture.State "RestoreManagerResults\$nonce.json"
        $arguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Fixture.Install 'Manage-Restore.ps1'),
            '-Operation', 'session', '-ExpectedUserSid', $UserSid, '-ExpectedConfigSha256', $configHash,
            '-ExpectedPlanId', $planId, '-ExpectedConfigGeneration', [string]$generation, '-ResultPath', $resultPath,
            '-RequestNonce', $nonce, '-RequestDigest', $digest, '-DashboardProcessId', [string]$DashboardPid,
            '-PipeName', $pipeName, '-SessionTokenSha256', $tokenSha256, '-IdleTimeoutSeconds', [string]$Idle,
            '-LifetimeSeconds', [string]$Lifetime, '-ConnectTimeoutSeconds', [string]$Connect, '-TestRoot', $Fixture.Root
        )
        $env:FAKE_RESTIC_LOG = $Fixture.Log
        $env:FAKE_PLAN_ID = $planId
        $env:FAKE_SOURCE = $Fixture.Source
        $env:FAKE_REPOSITORY_ACCESS = $Fixture.FakeAccess
        if ($LegacyFixture) { $env:FAKE_LEGACY_SNAPSHOT = '1' } else { Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue }
        Write-FakeResticControl
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $powershellPath
        $start.Arguments = (($arguments | ForEach-Object { ConvertTo-CommandLineArgument ([string]$_) }) -join ' ')
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardError = $true
        $start.RedirectStandardOutput = $true
        $process = [Diagnostics.Process]::Start($start)
        $stderr = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        return [pscustomobject]@{
            Process = $process; Stderr = $stderr; Stdout = $stdout; Nonce = $nonce; Digest = $digest; Token = $token
            PipeName = $pipeName; ResultPath = $resultPath; Fixture = $Fixture; Pipe = $null
        }
    }
    function Connect-SessionBroker([pscustomobject]$Broker, [int]$TimeoutMilliseconds = 30000) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        while ([DateTime]::UtcNow -lt $deadline -and -not $Broker.Process.HasExited) {
            $client = [IO.Pipes.NamedPipeClientStream]::new('.', $Broker.PipeName, [IO.Pipes.PipeDirection]::InOut,
                [IO.Pipes.PipeOptions]::Asynchronous, [Security.Principal.TokenImpersonationLevel]::Identification)
            try { $client.Connect(250); $Broker.Pipe = $client; return $client }
            catch { $client.Dispose() }
        }
        throw ('the session broker did not open its pipe: ' + (Stop-SessionBroker $Broker).Stderr)
    }
    function Send-RawSessionBytes([pscustomobject]$Broker, [byte[]]$Bytes) {
        $Broker.Pipe.Write($Bytes, 0, $Bytes.Length)
    }
    function Send-SessionTestMessage([pscustomobject]$Broker, [object]$Message) {
        $body = $encoding.GetBytes((ConvertTo-Json -InputObject $Message -Depth 10 -Compress))
        $header = [BitConverter]::GetBytes([int]$body.Length)
        Send-RawSessionBytes $Broker ([byte[]]($header + $body))
    }
    function Read-SessionTestBytes([IO.Pipes.PipeStream]$Pipe, [int]$Count, [int]$TimeoutMilliseconds) {
        $buffer = New-Object byte[] $Count
        $offset = 0
        while ($offset -lt $Count) {
            try {
                $task = $Pipe.ReadAsync($buffer, $offset, $Count - $offset)
                if (-not $task.Wait($TimeoutMilliseconds)) { throw 'timed out waiting for the session broker' }
                $read = $task.Result
            }
            catch { if ($_.Exception.Message -match 'timed out') { throw }; return $null }
            if ($read -le 0) { return $null }
            $offset += $read
        }
        return ,$buffer
    }
    function Read-SessionTestMessage([pscustomobject]$Broker, [int]$TimeoutMilliseconds = 60000) {
        $header = Read-SessionTestBytes $Broker.Pipe 4 $TimeoutMilliseconds
        if ($null -eq $header) { return $null }
        $length = [BitConverter]::ToInt32($header, 0)
        Assert-True ($length -gt 0 -and $length -le 8MB) 'the broker sent a frame outside its limit'
        $body = Read-SessionTestBytes $Broker.Pipe $length $TimeoutMilliseconds
        Assert-True ($null -ne $body) 'the broker closed the channel inside a frame'
        return (ConvertFrom-Json -InputObject $encoding.GetString($body))
    }
    function Send-SessionHello([pscustomobject]$Broker, [string]$Token = $Broker.Token, [long]$ClaimedPid = $PID) {
        Send-SessionTestMessage $Broker ([ordered]@{ type = 'hello'; protocol = 'ResticBackuper.RestoreSession.v1'; session_token = $Token; dashboard_process_id = $ClaimedPid })
    }
    function Open-SessionBroker([pscustomobject]$Broker) {
        [void](Connect-SessionBroker $Broker)
        Send-SessionHello $Broker
        $ready = Read-SessionTestMessage $Broker
        # The reason is only gathered on failure: stopping the broker closes the channel.
        if ($null -eq $ready -or [string]$ready.type -cne 'ready') { Assert-True $false ('the session did not become ready: ' + (Stop-SessionBroker $Broker).Stderr) }
        $script:assertions++
        return $ready
    }
    function Send-SessionTestRequest([pscustomobject]$Broker, [long]$Id, [string]$RequestAction, [string]$Snapshot = '', [string]$Tree = '', [string]$RestoreTarget = '', [string[]]$Include = @(), [string]$Legacy = '0') {
        $includeJson = if ($Include.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($Include) -Compress }
        Send-SessionTestMessage $Broker ([ordered]@{
            type = 'request'; request_id = $Id; action = $RequestAction; snapshot_id = $Snapshot; tree_path = $Tree; target = $RestoreTarget
            includes_base64 = [Convert]::ToBase64String($encoding.GetBytes($includeJson)); allow_legacy_unbound = $Legacy
        })
    }
    function Send-SessionTestFind([pscustomobject]$Broker, [long]$Id, [string]$Text, [string]$From = $snapshotId, [string]$Snapshot = '', [string]$RestoreTarget = '', [string]$IncludeJson = '[]', [string]$Legacy = '0') {
        Send-SessionTestMessage $Broker ([ordered]@{
            type = 'request'; request_id = $Id; action = 'find_files'; snapshot_id = $Snapshot; tree_path = ''; target = $RestoreTarget
            includes_base64 = [Convert]::ToBase64String($encoding.GetBytes($IncludeJson)); allow_legacy_unbound = $Legacy
            find_text = $Text; find_from_snapshot_id = $From
        })
    }
    function Receive-SessionTestResult([pscustomobject]$Broker, [long]$Id) {
        $progress = @()
        while ($true) {
            $message = Read-SessionTestMessage $Broker
            if ($null -eq $message) { Assert-True $false ('the session ended before answering request ' + $Id + ': ' + (Stop-SessionBroker $Broker).Stderr) }
            if ([string]$message.type -ceq 'progress') {
                Assert-True ([long]$message.request_id -eq $Id) 'progress named another request'
                $progress += $message
                continue
            }
            Assert-True ([string]$message.type -ceq 'result' -and [long]$message.request_id -eq $Id) ('request ' + $Id + ' was not answered with its result')
            return [pscustomobject]@{ Message = $message; Result = $message.result; ExitCode = [int]$message.exit_code; Progress = $progress }
        }
    }
    function Stop-SessionBroker([pscustomobject]$Broker, [int]$WaitMilliseconds = 60000) {
        if ($null -ne $Broker.Pipe) { try { $Broker.Pipe.Dispose() } catch { } }
        $exited = $Broker.Process.WaitForExit($WaitMilliseconds)
        if (-not $exited) { try { $Broker.Process.Kill() } catch { }; [void]$Broker.Process.WaitForExit(10000) }
        $record = if (Test-Path -LiteralPath $Broker.ResultPath) { Get-Content -LiteralPath $Broker.ResultPath -Raw | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Exited = $exited; ExitCode = $Broker.Process.ExitCode; Record = $record; Stderr = $Broker.Stderr.Result }
    }
    function Wait-SessionBrokerEnd([pscustomobject]$Broker, [int]$WaitMilliseconds = 60000) {
        # Waits for the broker to end on its own, without closing the channel first.
        $exited = $Broker.Process.WaitForExit($WaitMilliseconds)
        return (Stop-SessionBroker $Broker 10000) | Add-Member -NotePropertyName EndedOnItsOwn -NotePropertyValue $exited -PassThru
    }

    # One session serves any number of listings and exactly one restore, then ends.
    $sessionFixture = New-Fixture
    $broker = Start-SessionBroker -Fixture $sessionFixture
    $ready = Open-SessionBroker $broker
    Assert-True ([string]$ready.protocol -ceq 'ResticBackuper.RestoreSession.v1' -and [string]$ready.request_nonce -ceq $broker.Nonce -and
        [string]$ready.request_digest -ceq $broker.Digest -and [long]$ready.broker_process_id -eq $broker.Process.Id -and
        [int]$ready.idle_timeout_seconds -eq 60 -and [int]$ready.lifetime_seconds -eq 600) 'the session ready message is bound to its request and its broker process'
    $secondClient = [IO.Pipes.NamedPipeClientStream]::new('.', $broker.PipeName, [IO.Pipes.PipeDirection]::InOut)
    $secondAccepted = $true
    try { $secondClient.Connect(1000) } catch { $secondAccepted = $false } finally { $secondClient.Dispose() }
    Assert-True (-not $secondAccepted) 'the session broker accepted a second client'
    Send-SessionTestRequest $broker 1 'list_snapshots'
    $sessionList = Receive-SessionTestResult $broker 1
    Assert-True ($sessionList.ExitCode -eq 0 -and $sessionList.Result.ok -eq $true -and [string]$sessionList.Result.action -ceq 'list_snapshots' -and
        [string]$sessionList.Result.request_nonce -ceq $broker.Nonce -and [string]$sessionList.Result.request_digest -ceq $broker.Digest -and
        [string]$sessionList.Result.request_user_sid -ceq $sid -and [string]$sessionList.Result.plan_id -ceq $planId -and
        [string]$sessionList.Result.payload.schema -ceq 'ResticBackuper.SnapshotList.v1') 'a session lists snapshots with the bound result a single request writes'
    Assert-True (@($sessionList.Progress).Count -ge 2 -and [string]$sessionList.Progress[-1].stage -ceq 'complete') 'a session reports progress for the request it serves'
    Send-SessionTestRequest $broker 2 'list_tree' $snapshotId '/'
    $sessionTree = Receive-SessionTestResult $broker 2
    Assert-True ($sessionTree.ExitCode -eq 0 -and $sessionTree.Result.ok -eq $true -and [string]$sessionTree.Result.tree_path -ceq '/' -and
        @($sessionTree.Result.payload.entries).Count -eq 2) 'a session lists a folder'
    Send-SessionTestRequest $broker 3 'list_tree' $snapshotId '/documents'
    $sessionTree2 = Receive-SessionTestResult $broker 3
    Assert-True ($sessionTree2.ExitCode -eq 0 -and $sessionTree2.Result.ok -eq $true -and [string]$sessionTree2.Result.tree_path -ceq '/documents') 'a session lists another folder without another approval'
    $sessionTarget = Join-Path $sessionFixture.Root 'Restored\Session'
    Send-SessionTestRequest $broker 4 'restore' $snapshotId '' $sessionTarget @('/notes.txt')
    $sessionRestore = Receive-SessionTestResult $broker 4
    Assert-True ($sessionRestore.ExitCode -eq 0 -and $sessionRestore.Result.ok -eq $true -and [string]$sessionRestore.Result.payload.result -ceq 'verified' -and
        [string]$sessionRestore.Result.target -ceq ([IO.Path]::GetFullPath($sessionTarget))) 'a session restores once, verified'
    $afterRestore = Read-SessionTestMessage $broker 30000
    Assert-True ($null -eq $afterRestore) 'the session kept its channel open after its one restore'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and $ended.ExitCode -eq 0 -and [string]$ended.Record.close_reason -ceq 'restore_completed' -and $ended.Record.ok -eq $true -and
        [int]$ended.Record.operations.list_snapshots -eq 1 -and [int]$ended.Record.operations.list_tree -eq 2 -and [int]$ended.Record.operations.restore -eq 1) 'the session ended after its one restore and recorded what it served'
    Assert-True ([string]$ended.Record.request_nonce -ceq $broker.Nonce -and [string]$ended.Record.action -ceq 'session') 'the session record is bound to its request'
    $sessionHistory = Get-Content -LiteralPath (Join-Path $sessionFixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True (@($sessionHistory.entries).Count -eq 1 -and [string]$sessionHistory.entries[0].kind -ceq 'manual_restore') 'a session restore is recorded in the protected history like any restore'
    Assert-True (-not (Test-Path -LiteralPath ($broker.ResultPath + '.progress.json'))) 'a session wrote a progress file instead of using its channel'

    # A restore that fails still ends the session; the destination guards are the single request's.
    $guardFixture = New-Fixture
    $broker = Start-SessionBroker -Fixture $guardFixture
    [void](Open-SessionBroker $broker)
    Send-SessionTestRequest $broker 1 'restore' $snapshotId '' $guardFixture.Source
    $guarded = Receive-SessionTestResult $broker 1
    Assert-True ($guarded.ExitCode -ne 0 -and $guarded.Result.ok -eq $false -and [string]$guarded.Result.error -match 'must not overlap') 'a session restore into a protected folder is refused by the same guard'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and [string]$ended.Record.close_reason -ceq 'restore_completed') 'a failed restore still ends the session'
    Assert-True (-not ((Get-Content -LiteralPath $guardFixture.Log -Raw -ErrorAction SilentlyContinue) -match '(?m)(^|\t)restore(\t|$)')) 'the refused session restore never reached Restic'

    # A listing that fails (the backup holds the run lock) is a result, not the end of the session.
    $lockSessionFixture = New-Fixture
    $broker = Start-SessionBroker -Fixture $lockSessionFixture
    [void](Open-SessionBroker $broker)
    $held = [IO.File]::Open((Join-Path $lockSessionFixture.State 'run.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { $held.Lock(0, 1); Send-SessionTestRequest $broker 1 'list_snapshots'; $lockedList = Receive-SessionTestResult $broker 1 }
    finally { try { $held.Unlock(0, 1) } finally { $held.Dispose() } }
    Assert-True ($lockedList.Result.ok -eq $false -and [string]$lockedList.Result.error -match 'run lock') 'a session listing honours the backup run lock'
    Send-SessionTestRequest $broker 2 'list_snapshots'
    Assert-True ((Receive-SessionTestResult $broker 2).Result.ok -eq $true) 'a session goes on after a listing that failed'
    Send-SessionTestMessage $broker ([ordered]@{ type = 'close' })
    $closed = Read-SessionTestMessage $broker 30000
    Assert-True ($null -ne $closed -and [string]$closed.type -ceq 'closed' -and [string]$closed.reason -ceq 'client_closed') 'a session confirms a close'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and $ended.ExitCode -eq 0 -and [string]$ended.Record.close_reason -ceq 'client_closed') 'a session ends when the dashboard closes it'

    # A file search: served by the session, bound to its text and its start, and read through the backup cache without a
    # Restic lock, like a listing. The text reaches Restic as one pattern after "--", even when it starts with "-".
    $findFixture = New-Fixture -WithPasswordHelper
    $broker = Start-SessionBroker -Fixture $findFixture
    [void](Open-SessionBroker $broker)
    Send-SessionTestRequest $broker 1 'list_snapshots'
    Assert-True ((Receive-SessionTestResult $broker 1).Result.ok -eq $true) 'a session lists its backups before a search'
    Send-SessionTestFind $broker 2 'notes'
    $searched = Receive-SessionTestResult $broker 2
    $searchedNames = @($searched.Result.payload.matches | ForEach-Object { [string]$_.name })
    Assert-True ($searched.ExitCode -eq 0 -and $searched.Result.ok -eq $true -and [string]$searched.Result.action -ceq 'find_files' -and
        [string]$searched.Result.request_nonce -ceq $broker.Nonce -and [string]$searched.Result.plan_id -ceq $planId -and
        [string]$searched.Result.find_text_sha256 -ceq (Get-BytesHash -Bytes $encoding.GetBytes('notes')) -and
        [string]$searched.Result.find_from_snapshot_id -ceq $snapshotId -and $null -eq $searched.Result.snapshot_id -and
        $null -eq $searched.Result.target -and [string]$searched.Result.payload.schema -ceq 'ResticBackuper.FileSearch.v1' -and
        [string]$searched.Result.payload.status -ceq 'complete' -and [int]$searched.Result.payload.snapshots_searched -eq 1 -and
        ($searchedNames -join '|') -ceq '-notes draft.txt|notes.txt') ('a session finds files by name with a bound result: ' + ($searched.Result | ConvertTo-Json -Compress -Depth 20))
    Assert-True (@($searched.Progress | Where-Object { [string]$_.stage -ceq 'searching' }).Count -eq 1) 'a search reports that it is searching'
    Assert-True ($null -eq $sessionList.Result.PSObject.Properties['find_text_sha256'] -and $null -eq $sessionTree.Result.PSObject.Properties['find_from_snapshot_id']) 'a listing result carries no search fields'
    Send-SessionTestFind $broker 3 '-notes'
    $dashSearch = Receive-SessionTestResult $broker 3
    Assert-True ($dashSearch.Result.ok -eq $true -and [string]$dashSearch.Result.payload.query.text -ceq '-notes' -and
        (@($dashSearch.Result.payload.matches | ForEach-Object { [string]$_.name }) -join '|') -ceq '-notes draft.txt') ('a text that starts with "-" is searched for as it is: ' + [string]$dashSearch.Result.error)
    $findCalls = @(Get-Content -LiteralPath $findFixture.Log | Where-Object { $_ -match '(^|\t)find(\t|$)' })
    Assert-True ($findCalls.Count -eq 2 -and $findCalls[0].EndsWith("`tfind`t--json`t--ignore-case`t--snapshot`t$snapshotId`t--`t*notes*") -and
        $findCalls[1].EndsWith("`t--`t*-notes*") -and
        @($findCalls | Where-Object { -not $_.Contains((Join-Path $findFixture.State 'cache')) -or $_ -notmatch '(^|\t)--no-lock(\t|$)' }).Count -eq 0) ('a search runs a read-only Restic find through the backup cache: ' + ($findCalls -join ' / '))
    Send-SessionTestFind $broker 4 'notes' ('9' * 64)
    $goneStart = Receive-SessionTestResult $broker 4
    Assert-True ($goneStart.Result.ok -eq $false -and [string]$goneStart.Result.error -match 'no longer in the list' -and
        [string]$goneStart.Result.find_from_snapshot_id -ceq ('9' * 64)) 'a search from a backup that is no longer listed fails and says so'
    # The manager chooses how long a search may take: restore.py stops at its own deadline and says how far it got.
    $env:FAKE_FIND_SLEEP_MS = '120000'
    Write-FakeResticControl
    $slowWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Send-SessionTestFind $broker 5 'notes'
        $slowSearch = Receive-SessionTestResult $broker 5
    }
    finally {
        Remove-Item Env:FAKE_FIND_SLEEP_MS -ErrorAction SilentlyContinue
        Write-FakeResticControl
    }
    Assert-True ($slowSearch.Result.ok -eq $true -and [string]$slowSearch.Result.payload.status -ceq 'too_slow' -and
        [int]$slowSearch.Result.payload.snapshots_searched -eq 0 -and $slowWatch.Elapsed.TotalSeconds -ge 19 -and
        $slowWatch.Elapsed.TotalSeconds -lt 34) ('a search ends at the manager''s time limit: ' + [string]$slowWatch.Elapsed.TotalSeconds + ' s, ' + [string]$slowSearch.Result.error)
    Send-SessionTestRequest $broker 6 'list_tree' $snapshotId '/'
    Assert-True ((Receive-SessionTestResult $broker 6).Result.ok -eq $true) 'a session goes on after a search'
    Send-SessionTestMessage $broker ([ordered]@{ type = 'close' })
    [void](Read-SessionTestMessage $broker 30000)
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and [string]$ended.Record.close_reason -ceq 'client_closed' -and
        [int]$ended.Record.operations.find_files -eq 4 -and [int]$ended.Record.operations.list_snapshots -eq 1) 'the session record counts the searches'
    Assert-True ((Get-Content -LiteralPath $broker.ResultPath -Raw) -notmatch 'notes') 'the session record holds no search text'
    # The same search for backups without a password: no saved password and no recovery key exist and none is needed (the search
    # used to refuse to start without the protected password helper or a recovery key).
    $noPasswordFindFixture = New-Fixture -Access no_password -NoRecoveryKey
    $broker = Start-SessionBroker -Fixture $noPasswordFindFixture
    [void](Open-SessionBroker $broker)
    Send-SessionTestRequest $broker 1 'list_snapshots'
    Assert-True ((Receive-SessionTestResult $broker 1).Result.ok -eq $true) 'a session lists backups without a password'
    Send-SessionTestFind $broker 2 'notes'
    $noPasswordSearch = Receive-SessionTestResult $broker 2
    Assert-True ($noPasswordSearch.Result.ok -eq $true -and [string]$noPasswordSearch.Result.payload.status -ceq 'complete' -and
        (@($noPasswordSearch.Result.payload.matches | ForEach-Object { [string]$_.name }) -join '|') -ceq '-notes draft.txt|notes.txt') ('a session finds files in backups without a password: ' + [string]$noPasswordSearch.Result.error)
    $noPasswordFindCalls = @(Get-Content -LiteralPath $noPasswordFindFixture.Log | Where-Object { $_ -match '(^|\t)find(\t|$)' })
    Assert-True ($noPasswordFindCalls.Count -eq 1 -and $noPasswordFindCalls[0] -match '(^|\t)--insecure-no-password(\t|$)' -and
        $noPasswordFindCalls[0] -notmatch 'password-command') 'the search of backups without a password runs Restic find with the flag only'
    Send-SessionTestMessage $broker ([ordered]@{ type = 'close' })
    [void](Read-SessionTestMessage $broker 30000)
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and [string]$ended.Record.close_reason -ceq 'client_closed') 'the session for backups without a password ends when the dashboard closes it'
    # Backups that now ask for a password: the list, a folder and a search each answer in the same plain words, and the session
    # goes on (the person can still close the dialog or choose another backup location).
    $nowAsksFixture = New-Fixture -Access no_password -NoRecoveryKey -BackupsAre password
    $broker = Start-SessionBroker -Fixture $nowAsksFixture
    [void](Open-SessionBroker $broker)
    Send-SessionTestRequest $broker 1 'list_snapshots'
    $nowAsksList = Receive-SessionTestResult $broker 1
    Send-SessionTestRequest $broker 2 'list_tree' $snapshotId '/'
    $nowAsksTree = Receive-SessionTestResult $broker 2
    Send-SessionTestFind $broker 3 'notes'
    $nowAsksSearch = Receive-SessionTestResult $broker 3
    foreach ($answer in @(@('listing', $nowAsksList), @('opening a folder', $nowAsksTree), @('searching', $nowAsksSearch))) {
        Assert-True ($answer[1].ExitCode -ne 0 -and $answer[1].Result.ok -eq $false -and [string]$answer[1].Result.error -ceq $backupsNowAskForAPasswordMessage) ('a session says so in plain words when ' + $answer[0] + ' backups that now ask for a password: ' + [string]$answer[1].Result.error)
        Assert-True ([string]$answer[1].Progress[-1].stage -ceq 'failed' -and [string]$answer[1].Progress[-1].message -ceq $backupsNowAskForAPasswordMessage) ('the progress of a session ends in the same words when ' + $answer[0])
    }
    Send-SessionTestMessage $broker ([ordered]@{ type = 'close' })
    $nowAsksClosed = Read-SessionTestMessage $broker 30000
    Assert-True ($null -ne $nowAsksClosed -and [string]$nowAsksClosed.type -ceq 'closed') 'a session whose backups now ask for a password goes on until it is closed'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and $ended.ExitCode -eq 0 -and [string]$ended.Record.close_reason -ceq 'client_closed') 'that session ends when the dashboard closes it'
    # A single request can never ask for a search.
    $singleFind = Invoke-Manager -Fixture $findFixture -Action find_files
    Assert-True ($singleFind.ExitCode -ne 0 -and $null -eq $singleFind.Result) 'a single request asking for a search is refused'

    # Each protocol violation ends the session at once, with a fixed reason that quotes nothing the client sent.
    $violationFixture = New-Fixture
    $marker = 'never-echo-' + [Guid]::NewGuid().ToString('N')
    $violations = @(
        @{ Name = 'an oversized frame'; Reason = 'frame_too_large'; Send = { param($b) Send-RawSessionBytes $b ([byte[]]@(1, 0, 4, 0)) } },
        @{ Name = 'an empty frame'; Reason = 'frame_too_large'; Send = { param($b) Send-RawSessionBytes $b ([byte[]]@(0, 0, 0, 0)) } },
        @{ Name = 'a frame that is not JSON'; Reason = 'malformed_frame'; Send = { param($b) $body = $encoding.GetBytes('{"type":"' + $marker); Send-RawSessionBytes $b ([byte[]]([BitConverter]::GetBytes([int]$body.Length) + $body)) } },
        @{ Name = 'an unknown message type'; Reason = 'schema_violation'; Send = { param($b) Send-SessionTestMessage $b ([ordered]@{ type = $marker }) } },
        @{ Name = 'a request with an extra field'; Reason = 'schema_violation'; Send = { param($b) Send-SessionTestMessage $b ([ordered]@{ type = 'request'; request_id = 1; action = 'list_snapshots'; snapshot_id = ''; tree_path = ''; target = ''; includes_base64 = $emptyIncludes; allow_legacy_unbound = '0'; extra = $marker }) } },
        @{ Name = 'a request out of sequence'; Reason = 'schema_violation'; Send = { param($b) Send-SessionTestRequest $b 7 'list_snapshots' } },
        @{ Name = 'a recovery drill'; Reason = 'action_not_allowed'; Send = { param($b) Send-SessionTestRequest $b 1 'restore_drill' } },
        @{ Name = 'a request the single-request validation refuses'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestRequest $b 1 'list_tree' ('B' * 64) } },
        @{ Name = 'a listing with a target'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestRequest $b 1 'list_snapshots' '' '' 'C:\Elsewhere' } },
        @{ Name = 'a search of older-setup backups only'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestFind $b 1 'notes' -Legacy '1' } },
        @{ Name = 'a search in one backup'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestFind $b 1 'notes' -Snapshot $snapshotId } },
        @{ Name = 'a search with a target and chosen items'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestFind $b 1 'notes' -RestoreTarget 'C:\Elsewhere' -IncludeJson '["/notes.txt"]' } },
        @{ Name = 'a search text that is not in its normal form'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestFind $b 1 ' notes' } },
        @{ Name = 'a search for a path'; Reason = 'request_rejected'; Send = { param($b) Send-SessionTestFind $b 1 'docs\notes' } },
        @{ Name = 'a frame that stops half-way'; Reason = 'frame_timeout'; Send = { param($b) Send-RawSessionBytes $b ([byte[]]@(64, 0)) } }
    )
    foreach ($violation in $violations) {
        $broker = Start-SessionBroker -Fixture $violationFixture
        [void](Open-SessionBroker $broker)
        & $violation.Send $broker
        $ended = Wait-SessionBrokerEnd $broker 90000
        Assert-True ($ended.EndedOnItsOwn -and $ended.ExitCode -eq 1 -and [string]$ended.Record.close_reason -ceq $violation.Reason -and $ended.Record.ok -eq $false) ('the session did not end on ' + $violation.Name + ': ' + [string]$ended.Record.close_reason + ' ' + $ended.Stderr)
        Assert-True (-not ((Get-Content -LiteralPath $broker.ResultPath -Raw) -match [regex]::Escape($marker))) ('the session record quoted the client after ' + $violation.Name)
    }

    # The hello: the wrong token, or a client that is not the dashboard that asked, never gets a session.
    $broker = Start-SessionBroker -Fixture $violationFixture
    [void](Connect-SessionBroker $broker)
    Send-SessionHello $broker ('e' * 64)
    Assert-True ($null -eq (Read-SessionTestMessage $broker 30000)) 'a client with the wrong token was answered'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ([string]$ended.Record.close_reason -ceq 'token_mismatch' -and $ended.ExitCode -eq 1) 'a wrong session token ends the session'
    $broker = Start-SessionBroker -Fixture $violationFixture
    [void](Connect-SessionBroker $broker)
    Send-SessionHello $broker $broker.Token ($PID + 1)
    Assert-True ($null -eq (Read-SessionTestMessage $broker 30000)) 'a client claiming another process was answered'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ([string]$ended.Record.close_reason -ceq 'client_process_mismatch') 'a hello that names another process ends the session'
    $bystander = Start-Process -FilePath $powershell -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden
    try {
        $broker = Start-SessionBroker -Fixture $violationFixture -DashboardPid $bystander.Id
        [void](Connect-SessionBroker $broker)
        # The broker may already have dropped the channel: it checks who connected before it reads anything.
        try { Send-SessionHello $broker $broker.Token $bystander.Id } catch { }
        Assert-True ($null -eq (Read-SessionTestMessage $broker 30000)) 'a client that is not the requesting process was answered'
        $ended = Wait-SessionBrokerEnd $broker
        Assert-True ([string]$ended.Record.close_reason -ceq 'client_process_mismatch' -and $ended.ExitCode -eq 1) 'Windows'' client process ID decides who the client is'
    }
    finally { try { $bystander.Kill() } catch { } }
    $foreignSid = 'S-1-5-21-1000000000-1000000000-1000000000-1001'
    $broker = Start-SessionBroker -Fixture $violationFixture -UserSid $foreignSid
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.EndedOnItsOwn -and $ended.ExitCode -eq 1 -and $null -eq $ended.Record -and $ended.Stderr -match 'same Windows account') 'a session for another account is refused before any channel exists'
    $broker = Start-SessionBroker -Fixture $violationFixture -DigestOverride ('0' * 64)
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.ExitCode -eq 1 -and $null -eq $ended.Record -and $ended.Stderr -match 'digest') 'a forged session digest is refused before any channel exists'
    $broker = Start-SessionBroker -Fixture $violationFixture -PipeOverride ('Other.' + (New-SessionSecret))
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.ExitCode -eq 1 -and $null -eq $ended.Record) 'a pipe name outside the session namespace is refused'
    $broker = Start-SessionBroker -Fixture $violationFixture -Idle 601
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.ExitCode -eq 1 -and $null -eq $ended.Record -and $ended.Stderr -match 'timeouts') 'a session asking for more than the protected idle limit is refused'

    # A pipe name someone else already holds is never shared: the session is refused (no squatting).
    $squatName = 'ResticBackuper.RestoreSession.' + (New-SessionSecret)
    $squatter = [IO.Pipes.NamedPipeServerStream]::new($squatName, [IO.Pipes.PipeDirection]::InOut, 10)
    try {
        $broker = Start-SessionBroker -Fixture $violationFixture -PipeOverride $squatName
        $ended = Wait-SessionBrokerEnd $broker
        Assert-True ($ended.EndedOnItsOwn -and $ended.ExitCode -eq 1 -and [string]$ended.Record.close_reason -ceq 'pipe_unavailable') 'a squatted pipe name was used instead of refused'
        Assert-True (-not $squatter.IsConnected) 'the squatter received a connection'
    }
    finally { $squatter.Dispose() }

    # Lifetime: idle, absolute, the dashboard going away, and a configuration change.
    $timeoutFixture = New-Fixture
    $broker = Start-SessionBroker -Fixture $timeoutFixture -Idle 5
    [void](Open-SessionBroker $broker)
    Send-SessionTestRequest $broker 1 'list_snapshots'
    [void](Receive-SessionTestResult $broker 1)
    $idleWatch = [Diagnostics.Stopwatch]::StartNew()
    $idleClosed = Read-SessionTestMessage $broker 30000
    Assert-True ($null -ne $idleClosed -and [string]$idleClosed.type -ceq 'closed' -and [string]$idleClosed.reason -ceq 'idle_timeout' -and $idleWatch.Elapsed.TotalSeconds -ge 4) 'an idle session tells its client it ended'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ($ended.ExitCode -eq 0 -and [string]$ended.Record.close_reason -ceq 'idle_timeout') 'an idle session ends'
    $broker = Start-SessionBroker -Fixture $timeoutFixture -Idle 60 -Lifetime 5
    [void](Open-SessionBroker $broker)
    $ended = Wait-SessionBrokerEnd $broker 30000
    Assert-True ($ended.EndedOnItsOwn -and [string]$ended.Record.close_reason -ceq 'lifetime_expired') 'a session ends at its absolute lifetime'
    $broker = Start-SessionBroker -Fixture $timeoutFixture -Connect 5
    $ended = Wait-SessionBrokerEnd $broker 30000
    Assert-True ($ended.EndedOnItsOwn -and [string]$ended.Record.close_reason -ceq 'connect_timeout') 'a session nobody connects to ends'
    $broker = Start-SessionBroker -Fixture $timeoutFixture
    [void](Open-SessionBroker $broker)
    $broker.Pipe.Dispose()
    $ended = Wait-SessionBrokerEnd $broker 30000
    Assert-True ($ended.EndedOnItsOwn -and [string]$ended.Record.close_reason -ceq 'client_disconnected') 'a session ends when its client goes away'
    $configFixture = New-Fixture
    $broker = Start-SessionBroker -Fixture $configFixture
    [void](Open-SessionBroker $broker)
    [IO.File]::AppendAllText($configFixture.ConfigPath, "`n", $encoding)
    $configClosed = Read-SessionTestMessage $broker 30000
    Assert-True ($null -ne $configClosed -and [string]$configClosed.reason -ceq 'config_changed') 'a session tells its client the plan changed'
    $ended = Wait-SessionBrokerEnd $broker
    Assert-True ([string]$ended.Record.close_reason -ceq 'config_changed') 'a session ends when the protected configuration changes'

    # The disposable mode needs a copy of the manager in its test root: the repository copy (like the installed one) with
    # -TestRoot is refused, and so is a session from it.
    $priorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sourceAttempt = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $managerSource -Operation session `
        -ExpectedUserSid $sid -ExpectedConfigSha256 ('a' * 64) -ExpectedPlanId $planId -ExpectedConfigGeneration 7 `
        -ResultPath (Join-Path $sessionFixture.State "RestoreManagerResults\$('f' * 64).json") -RequestNonce ('f' * 64) -RequestDigest ('0' * 64) `
        -DashboardProcessId $PID -PipeName ('ResticBackuper.RestoreSession.' + ('1' * 64)) -SessionTokenSha256 ('2' * 64) `
        -IdleTimeoutSeconds 60 -LifetimeSeconds 600 -ConnectTimeoutSeconds 30 -TestRoot $sessionFixture.Root 2>&1 | ForEach-Object { [string]$_ }
    $sourceExit = $LASTEXITCODE
    $ErrorActionPreference = $priorPreference
    Assert-True ($sourceExit -ne 0 -and (($sourceAttempt -join ' ') -match 'installed manager script')) 'the disposable mode ran from outside its test root'


    # The dashboard's own session client against this broker: the dashboard assembly (when it has been built) opens, verifies and
    # uses a real session, started in the disposable mode instead of with runas, with this process as the dashboard.
    $interopCheck = 'skipped (the dashboard has not been built)'
    $dashboardExecutable = [IO.Path]::GetFullPath($DashboardPath)
    if (Test-Path -LiteralPath $dashboardExecutable -PathType Leaf) {
        $dashboardAssembly = [Reflection.Assembly]::LoadFrom($dashboardExecutable)
        $memberFlags = [Reflection.BindingFlags]'Instance, Static, Public, NonPublic'
        $profileType = $dashboardAssembly.GetType('ResticBackuper.Dashboard.EngineProfile', $true)
        $configurationType = $dashboardAssembly.GetType('ResticBackuper.Dashboard.SourceConfiguration', $true)
        $hostType = $dashboardAssembly.GetType('ResticBackuper.Dashboard.RestoreSessionHost', $true)
        $launcherType = $dashboardAssembly.GetType('ResticBackuper.Dashboard.RestoreSessionLauncher', $true)
        $managerLauncherType = $dashboardAssembly.GetType('ResticBackuper.Dashboard.RestoreManagerLauncher', $true)
        if (-not ('RestoreManagerTests.DisposableSessionLauncher' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
namespace RestoreManagerTests {
  // Starts the broker the dashboard asked for in the disposable mode: the same command line, without runas, plus -TestRoot.
  public static class DisposableSessionLauncher {
    public static string TestRoot;
    public static int Launches;
    public static Process Launch(ProcessStartInfo start, object request) {
      Launches++;
      if (start.Verb != "runas" || !start.UseShellExecute) throw new InvalidOperationException("The session was not asked for with runas.");
      ProcessStartInfo disposable = new ProcessStartInfo(start.FileName, start.Arguments + " -TestRoot \"" + TestRoot + "\"");
      disposable.WorkingDirectory = start.WorkingDirectory;
      disposable.UseShellExecute = false;
      disposable.CreateNoWindow = true;
      return Process.Start(disposable);
    }
  }
}
'@
        }
        # With a stored password, as every installed plan has: a file search never asks for one.
        $interopFixture = New-Fixture -WithPasswordHelper
        [RestoreManagerTests.DisposableSessionLauncher]::TestRoot = $interopFixture.Root
        [RestoreManagerTests.DisposableSessionLauncher]::Launches = 0
        $env:FAKE_RESTIC_LOG = $interopFixture.Log
        $env:FAKE_PLAN_ID = $planId
        $env:FAKE_SOURCE = $interopFixture.Source
        $env:FAKE_REPOSITORY_ACCESS = $interopFixture.FakeAccess
        Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue
        Write-FakeResticControl
        $profileType.GetMethod('UseFolderRootsForTesting', $memberFlags).Invoke($null, [object[]]@([string]$interopFixture.Root)) | Out-Null
        $profileType.GetMethod('Activate', $memberFlags).Invoke($null, [object[]]@($profileType.GetProperty('Rewindle', $memberFlags).GetValue($null))) | Out-Null
        try {
            $interopConfiguration = $configurationType.GetMethod('Load', $memberFlags).Invoke($null, @())
            $interopLaunch = [Delegate]::CreateDelegate($launcherType, [RestoreManagerTests.DisposableSessionLauncher].GetMethod('Launch'))
            $interopHost = [Activator]::CreateInstance($hostType, $memberFlags, $null, [object[]]@($interopLaunch), $null)
            $sessionMethods = @{}
            foreach ($method in $managerLauncherType.GetMethods($memberFlags)) {
                if (@($method.GetParameters() | Where-Object { $_.ParameterType -eq $hostType }).Count -gt 0) { $sessionMethods[$method.Name] = $method }
            }
            $interopList = $sessionMethods['ListSnapshots'].Invoke($null, [object[]]@($interopConfiguration, $interopHost, $null, $null, $null))
            Assert-True ($interopList.Succeeded -and $interopList.Snapshots.Count -eq 1 -and $interopList.Snapshots[0].Id -ceq $snapshotId) ('the dashboard could not list snapshots through a real session: ' + $interopList.ErrorMessage)
            $interopTree = $sessionMethods['ListTree'].Invoke($null, [object[]]@($interopConfiguration, $snapshotId, '/', $false, $interopHost, $null, $null, $null))
            Assert-True ($interopTree.Succeeded -and $interopTree.Entries.Count -eq 2) ('the dashboard could not list a folder through a real session: ' + $interopTree.ErrorMessage)
            # Find a file through the same session: the dashboard's request, this broker's checks, restore.py's page and the dashboard's own.
            $interopFind = $sessionMethods['FindFiles'].Invoke($null, [object[]]@($interopConfiguration, $interopHost, 'notes', $snapshotId, $null, $null, $null))
            $interopFound = @(if ($interopFind.Succeeded) { $interopFind.FileSearch.Matches | ForEach-Object { [string]$_.Name } })
            Assert-True ($interopFind.Succeeded -and [string]$interopFind.FileSearch.Status -ceq 'complete' -and ($interopFound -join '|') -ceq '-notes draft.txt|notes.txt' -and
                [string]$interopFind.FileSearch.Matches[1].Versions[0].SnapshotId -ceq $snapshotId) ('the dashboard could not find a file through a real session: ' + $interopFind.ErrorMessage)
            $interopTarget = [string](Join-Path $interopFixture.Root 'Restored\Interop')
            $interopIncludes = [System.Collections.Generic.List[string]]::new()
            $interopIncludes.Add('/notes.txt')
            $interopRestore = $sessionMethods['Restore'].Invoke($null, [object[]]@($interopConfiguration, $snapshotId, $interopTarget, $interopIncludes, $false, $interopHost, $null, $null, $null))
            Assert-True ($interopRestore.Succeeded -and $interopRestore.Report.Verified) ('the dashboard could not restore through a real session: ' + $interopRestore.ErrorMessage)
            Assert-True ([RestoreManagerTests.DisposableSessionLauncher]::Launches -eq 1) 'the dashboard asked for more than one session for two listings, a search and a restore'
            Assert-True (-not [bool]$hostType.GetProperty('HasLiveSession', $memberFlags).GetValue($interopHost)) 'the dashboard kept a session after its one restore'
            $records = @(Get-ChildItem -LiteralPath (Join-Path $interopFixture.State 'RestoreManagerResults') -Filter '*.json' |
                Where-Object { $_.Name -match '^[0-9a-f]{64}\.json$' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ($records.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
                $records = @(Get-ChildItem -LiteralPath (Join-Path $interopFixture.State 'RestoreManagerResults') -Filter '*.json' |
                    Where-Object { $_.Name -match '^[0-9a-f]{64}\.json$' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            }
            Assert-True ($records.Count -eq 1 -and [string]$records[0].close_reason -ceq 'restore_completed' -and [int]$records[0].operations.list_tree -eq 1 -and
                [int]$records[0].operations.find_files -eq 1) 'the real session did not end after the dashboard''s restore'
            # A session the dashboard closes ends at once.
            $closingHost = [Activator]::CreateInstance($hostType, $memberFlags, $null, [object[]]@($interopLaunch), $null)
            $closingList = $sessionMethods['ListSnapshots'].Invoke($null, [object[]]@($interopConfiguration, $closingHost, $null, $null, $null))
            Assert-True ($closingList.Succeeded) ('the second real session could not list snapshots: ' + $closingList.ErrorMessage)
            $hostType.GetMethod('Close', $memberFlags).Invoke($closingHost, @()) | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                Start-Sleep -Milliseconds 200
                $closedRecords = @(Get-ChildItem -LiteralPath (Join-Path $interopFixture.State 'RestoreManagerResults') -Filter '*.json' |
                    Where-Object { $_.Name -match '^[0-9a-f]{64}\.json$' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
                    Where-Object { [string]$_.close_reason -ceq 'client_closed' })
            } while ($closedRecords.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline)
            Assert-True ($closedRecords.Count -eq 1) 'a real session did not end when the dashboard closed it'
            $interopCheck = 'passed'
        }
        finally {
            $profileType.GetMethod('UseFolderRootsForTesting', $memberFlags).Invoke($null, [object[]]@([string]$null)) | Out-Null
        }
    }

    $productionCheck = 'skipped'
    if (-not $SkipInstalledChecks) {
        $productionHashAfter = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
        $taskXmlAfter = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }
        Assert-True ($productionHashAfter -eq $productionHashBefore) 'production protected config untouched'
        Assert-True ($taskXmlAfter -ceq $taskXmlBefore) 'production task untouched'
        $productionCheck = 'passed'
    }

    [ordered]@{
        ok = $true; assertions = $assertions; disposable_roots = $roots.Count
        snapshot_list = 'passed'; tree_list = 'passed'; verified_restore = 'passed'
        partial_restore_retained = 'passed'; unsafe_target = 'passed'; plan_and_digest_binding = 'passed'; legacy_unbound_opt_in = 'passed'
        journal_and_lock_gates = 'passed'; orphan_recovery_and_manifest_parity = 'passed'; no_repository_or_source_mutation = 'passed'
        restore_session = 'passed'; session_framing_and_schema = 'passed'; session_client_identity = 'passed'
        session_single_restore = 'passed'; session_timeouts = 'passed'; session_pipe_squatting = 'passed'; session_file_search = 'passed'
        backups_without_a_password = 'passed'; backups_with_a_password_unchanged = 'passed'
        dashboard_session_interop = $interopCheck
        production_untouched = $productionCheck
    } | ConvertTo-Json -Depth 3
}
finally {
    foreach ($name in @('FAKE_RESTIC_LOG','FAKE_PLAN_ID','FAKE_SOURCE','FAKE_RESTORE_PARTIAL','FAKE_RESTORE_NOTHING','FAKE_LEGACY_SNAPSHOT','FAKE_FIND_SLEEP_MS','FAKE_REPOSITORY_ACCESS','FAKE_PROGRESS_FILE','FAKE_PROGRESS_COPY')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    foreach ($name in $plantedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    foreach ($root in $roots) {
        $full = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ($full.StartsWith($temp + '\RSTR-T-', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
            # A broker on its way out can hold its working folder for a moment, and a cleanup failure must not hide a test failure.
            for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $full); $attempt++) {
                try { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 500 }
            }
            if (Test-Path -LiteralPath $full) { Write-Warning "Could not remove the disposable test folder $full" }
        }
    }
    if ((Test-Path -LiteralPath $compilerRoot) -and
        $compilerRoot.StartsWith(([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\RSTR-C-'), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $compilerRoot -Recurse -Force
    }
}
