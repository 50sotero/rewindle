param(
    # Never look at the installed configuration or the installed task, even to prove they were left alone. Every check below
    # runs in disposable folders either way; this only drops the two before/after comparisons with the real installation.
    [switch]$SkipInstalledChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$managerSource = Join-Path $projectRoot 'src\Manage-Repository.ps1'
$python = (Get-Command python -ErrorAction Stop).Source
$powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$encoding = [Text.UTF8Encoding]::new($false)
$fixtureRoots = [Collections.Generic.List[string]]::new()
$plantedLinks = [Collections.Generic.List[string]]::new()
$assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:assertions++
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + "`n"), $encoding)
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-VolumeSerial {
    param([string]$Path)
    if (-not ('RepositoryManagerTests.Volume' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RepositoryManagerTests {
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
    return [RepositoryManagerTests.Volume]::Serial([IO.Path]::GetPathRoot($Path))
}

function Get-TextSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RelativeFiles {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        ForEach-Object { $_.FullName.Substring($Root.Length + 1) } | Sort-Object)
}

function ConvertTo-ProcessArgument {
    # Quotes one argument the way CommandLineToArgvW reads it back.
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Add-UnrelatedFiles {
    # Things that are not Restic's own files, as a program running as the user could leave them in a backup folder it
    # can write to (a Google Drive folder keeps no permissions): other names, and Restic-like names in the wrong place.
    param([string]$Repository)
    $pack = @(Get-ChildItem -LiteralPath (Join-Path $Repository 'data') -Recurse -File -Force)[0]
    $packFolder = Split-Path -Leaf (Split-Path -Parent $pack.FullName)
    $otherPrefix = if ($packFolder -ne 'cd') { 'cd' } else { 'ef' }
    $relative = @(
        'evil.dll',
        'Thumbs.db',
        'notes\readme.txt',
        "data\$packFolder\notes.txt",
        "data\$packFolder\$otherPrefix$('0' * 62)",
        "data\zz\$('a' * 64)",
        'keys\desktop.ini',
        'snapshots\sub\x.bin',
        "index\$(Get-TextSha256 'stray index')-tmp-1"
    )
    foreach ($item in $relative) {
        $full = Join-Path $Repository $item
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
        [IO.File]::WriteAllText($full, "unrelated $item`n", $encoding)
    }
    return $relative
}

function New-FileRecord {
    param([string]$Name, [string]$Path, [string]$Property = 'name')
    $record = [ordered]@{ bytes = (Get-Item -LiteralPath $Path).Length; sha256 = Get-Hash -Path $Path }
    $record[$Property] = $Name
    return $record
}

function Get-TreeDigest {
    param([string]$Root, [switch]$ExcludeLocks)
    $rows = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            Where-Object {
                -not $ExcludeLocks -or
                -not $_.FullName.Substring($Root.Length + 1).StartsWith('locks\', [StringComparison]::OrdinalIgnoreCase)
            } |
            Sort-Object FullName |
            ForEach-Object { "$($_.FullName.Substring($Root.Length + 1))|$($_.Length)|$(Get-Hash -Path $_.FullName)" }
    )
    $bytes = $encoding.GetBytes($rows -join "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RequestDigest {
    param([string]$Current, [string]$New, [string]$ConfigHash, [string]$Nonce)
    $text = "ResticBackuper.RepositoryRequest.v1`n$sid`nrelocate`n$Current`n$New`n$ConfigHash`n$Nonce"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-RecoveryRequestDigest {
    param([string]$JournalHash, [string]$Nonce)
    $text = "ResticBackuper.RepositoryRecoveryRequest.v1`n$sid`nrecover`n$JournalHash`n$Nonce"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$compilerRoot = Join-Path ([IO.Path]::GetTempPath()) ('RRM-C-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($compilerRoot)
$fakeRestic = Join-Path $compilerRoot 'restic.exe'
# The fake reads its command line the way Restic (a Go program) does and splits the password command the way Restic
# does before starting it, so a manager that quotes the password command wrongly fails here as it fails with the real
# Restic. It also refuses any environment variable beyond the manager's allow-list. Its log and its check-failure
# switch are files in the fixture, because the manager gives Restic a clean environment.
$fakeSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
public static class FakeRestic {
  // Go's os.commandLineToArgv/readNextArg, including its "prior to 2008" double-quote rule.
  static List<string> GoArgv(string cmd) {
    List<string> args = new List<string>();
    int i = 0;
    while (i < cmd.Length) {
      if (cmd[i] == ' ' || cmd[i] == '\t') { i++; continue; }
      StringBuilder b = new StringBuilder();
      bool inQuote = false;
      int slashes = 0;
      for (; i < cmd.Length; i++) {
        char c = cmd[i];
        if ((c == ' ' || c == '\t') && !inQuote) break;
        if (c == '"') {
          b.Append('\\', slashes / 2);
          if (slashes % 2 == 0) {
            if (inQuote && i + 1 < cmd.Length && cmd[i + 1] == '"') { b.Append('"'); i++; }
            inQuote = !inQuote;
          } else {
            b.Append('"');
          }
          slashes = 0;
          continue;
        }
        if (c == '\\') { slashes++; continue; }
        b.Append('\\', slashes);
        slashes = 0;
        b.Append(c);
      }
      b.Append('\\', slashes);
      args.Add(b.ToString());
    }
    return args;
  }
  // Restic's backend.SplitShellStrings, which turns --password-command into the program and its arguments.
  static List<string> SplitShell(string data) {
    List<string> parts = new List<string>();
    char quote = '\0';
    char last = '\0';
    int start = -1;
    for (int i = 0; i < data.Length; i++) {
      char c = data[i];
      bool split;
      if (last != '\\' && quote != '\0' && c == quote) { quote = '\0'; split = true; }
      else if (last != '\\' && quote == '\0' && (c == '"' || c == '\'')) { quote = c; split = true; }
      else { last = c; split = quote == '\0' && (c == '\\' || Char.IsWhiteSpace(c)); }
      if (split) {
        if (start >= 0) { parts.Add(data.Substring(start, i - start)); start = -1; }
      } else if (start == -1) {
        start = i;
      }
    }
    if (start >= 0) parts.Add(data.Substring(start));
    if (quote != '\0') throw new InvalidOperationException("quoted string not terminated");
    return parts;
  }
  static bool SamePath(string left, string right) {
    return String.Equals(left.Replace('\\', '/'), right.Replace('\\', '/'), StringComparison.OrdinalIgnoreCase);
  }
  static bool IsWithin(string candidate, string parent) {
    string full = Path.GetFullPath(candidate).TrimEnd('\\');
    string root = Path.GetFullPath(parent).TrimEnd('\\');
    return String.Equals(full, root, StringComparison.OrdinalIgnoreCase) ||
      full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase);
  }
  static int Refuse(string message) {
    Console.Error.WriteLine("fake restic refused: " + message);
    return 92;
  }
  public static int Main(string[] ignored) {
    List<string> argv = GoArgv(Environment.CommandLine);
    if (argv.Count > 0) argv.RemoveAt(0);
    string[] args = argv.ToArray();
    string installRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    string fixtureRoot = Path.GetFullPath(Path.Combine(installRoot, "..", ".."));
    string stateRoot = Path.Combine(fixtureRoot, "ProgramData\\ResticBackuper");
    File.AppendAllText(Path.Combine(fixtureRoot, "fake-restic.log"), String.Join("\t", args) + Environment.NewLine);

    string repo = null;
    string passwordCommand = null;
    string cacheDirectory = null;
    List<string> words = new List<string>();
    for (int i = 0; i < args.Length; i++) {
      string a = args[i];
      if (a == "--repo" || a == "--password-command" || a == "--cache-dir" || a == "--retry-lock") {
        if (i + 1 >= args.Length) return Refuse("missing value for " + a);
        string value = args[++i];
        if (a == "--repo") repo = value;
        if (a == "--password-command") passwordCommand = value;
        if (a == "--cache-dir") cacheDirectory = value;
        if (a == "--retry-lock" && value != "0s") return Refuse("unexpected --retry-lock " + value);
        continue;
      }
      if (a == "--json") continue;
      if (a.StartsWith("-")) return Refuse("unknown flag " + a);
      words.Add(a);
    }
    if (String.IsNullOrEmpty(passwordCommand)) return Refuse("no --password-command");
    string[] expected = new string[] {
      Path.Combine(installRoot, "Python\\python.exe"), "-I", "-S", "-B", Path.Combine(installRoot, "secret_store.py"),
      "reveal", "--secret-file", Path.Combine(stateRoot, "repository-password.dpapi.json")
    };
    List<string> actual;
    try { actual = SplitShell(passwordCommand); }
    catch (InvalidOperationException error) { return Refuse("password command: " + error.Message); }
    bool same = actual.Count == expected.Length;
    for (int i = 0; same && i < expected.Length; i++) same = SamePath(actual[i], expected[i]);
    if (!same) return Refuse("password command does not name the expected helper: [" + String.Join("|", actual.ToArray()) + "]");

    IDictionary environment = Environment.GetEnvironmentVariables();
    foreach (DictionaryEntry entry in environment) {
      string name = ((string)entry.Key).ToUpperInvariant();
      if (name.StartsWith("RESTIC_") || name.StartsWith("RCLONE_")) return Refuse("inherited environment variable " + name);
    }
    // Exactly the Windows values, as Windows itself reports them, and TEMP/TMP in the protected temp folder next to
    // the cache. PROCESSOR_ARCHITECTURE is passed on only when it is one of Windows' own values.
    string system = Environment.SystemDirectory;
    string windows = Directory.GetParent(system).FullName;
    string temporary = Path.Combine(stateRoot, "temp");
    Dictionary<string, string> required = new Dictionary<string, string>();
    required["SYSTEMROOT"] = windows;
    required["WINDIR"] = windows;
    required["SYSTEMDRIVE"] = Path.GetPathRoot(windows).TrimEnd('\\');
    required["COMSPEC"] = Path.Combine(system, "cmd.exe");
    required["PATH"] = String.Join(";", new string[] {
      system, windows, Path.Combine(system, "Wbem"), Path.Combine(system, "WindowsPowerShell\\v1.0") });
    required["PATHEXT"] = ".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC";
    required["OS"] = "Windows_NT";
    required["NUMBER_OF_PROCESSORS"] = Environment.ProcessorCount.ToString();
    required["TEMP"] = temporary;
    required["TMP"] = temporary;
    foreach (DictionaryEntry entry in environment) {
      string name = ((string)entry.Key).ToUpperInvariant();
      string value = (string)entry.Value;
      if (name == "PROCESSOR_ARCHITECTURE") {
        if (Array.IndexOf(new string[] { "AMD64", "x86", "ARM64" }, value) < 0) return Refuse("unexpected PROCESSOR_ARCHITECTURE " + value);
        continue;
      }
      if (!required.ContainsKey(name)) return Refuse("environment variable outside the allow-list " + name);
      if (!String.Equals(value, required[name], StringComparison.OrdinalIgnoreCase)) return Refuse(name + " is not the expected value: " + value);
    }
    foreach (string name in required.Keys) {
      if (String.IsNullOrEmpty(Environment.GetEnvironmentVariable(name))) return Refuse("missing environment variable " + name);
    }
    if (!Directory.Exists(temporary)) return Refuse("the protected temp folder does not exist");

    if (String.IsNullOrEmpty(repo)) return Refuse("missing --repo");
    if (String.IsNullOrEmpty(cacheDirectory) || !IsWithin(cacheDirectory, stateRoot)) return Refuse("--cache-dir is not inside the protected state folder");

    string command = String.Join(" ", words.ToArray());
    if (command == "cat config") {
      // The fixture repository has Restic's layout: the ID is the text of config, and each snapshot is a file in snapshots.
      string id = File.ReadAllText(Path.Combine(repo, "config")).Trim();
      Console.WriteLine("{\"id\":\"" + id + "\"}");
      return 0;
    }
    if (command == "snapshots") {
      List<string> rows = new List<string>();
      foreach (string file in Directory.GetFiles(Path.Combine(repo, "snapshots"))) {
        rows.Add("{\"id\":\"" + Path.GetFileName(file) + "\"}");
      }
      Console.WriteLine("[" + String.Join(",", rows.ToArray()) + "]");
      return 0;
    }
    if (command == "check") {
      if (File.Exists(Path.Combine(fixtureRoot, "fake-restic-fail-check"))) return 17;
      if (!File.Exists(Path.Combine(repo, "config")) ||
          Directory.GetFiles(Path.Combine(repo, "data"), "*", SearchOption.AllDirectories).Length == 0) return 18;
      Console.WriteLine("repository check passed");
      return 0;
    }
    return Refuse("forbidden, unknown or stray positional arguments: [" + String.Join("|", words.ToArray()) + "]");
  }
}
'@
Add-Type -TypeDefinition $fakeSource -OutputAssembly $fakeRestic -OutputType ConsoleApplication

function New-Fixture {
    param([switch]$NoRepositoryRecord)
    # The space matters: the installed paths are under "Program Files", and a password command that is quoted wrongly
    # still splits into the right words when no path in it has a space.
    $root = Join-Path ([IO.Path]::GetTempPath()) ('RRM T-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $fixtureRoots.Add($root)
    $installRoot = Join-Path $root 'ProgramFiles\ResticBackuper'
    $stateRoot = Join-Path $root 'ProgramData\ResticBackuper'
    $oldParent = Join-Path $root 'OldStore'
    $newParent = Join-Path $root 'NewStore'
    $oldRepository = Join-Path $oldParent 'Personal'
    $oldRecovery = Join-Path $oldParent 'RecoveryTools'
    $newRepository = Join-Path $newParent 'Personal'
    $source = Join-Path $root 'Source'
    $diagnostics = Join-Path $root 'Diagnostics'
    $packId = Get-TextSha256 'fixture pack'
    foreach ($directory in @(
        $installRoot, (Join-Path $installRoot 'Python'), $stateRoot, $oldRepository,
        (Join-Path $oldRepository "data\$($packId.Substring(0, 2))"), (Join-Path $oldRepository 'data\ff'),
        (Join-Path $oldRepository 'keys'), (Join-Path $oldRepository 'index'), (Join-Path $oldRepository 'snapshots'),
        (Join-Path $oldRepository 'locks'), $oldRecovery, $newParent, $source, $diagnostics
    )) { [void][IO.Directory]::CreateDirectory($directory) }

    Copy-Item -LiteralPath $managerSource -Destination (Join-Path $installRoot 'Manage-Repository.ps1')
    Copy-Item -LiteralPath $fakeRestic -Destination (Join-Path $installRoot 'restic.exe')
    [IO.File]::WriteAllText((Join-Path $installRoot 'Python\python.exe'), "fixture python`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $installRoot 'secret_store.py'), "# fixture secret helper`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $installRoot 'excludes.txt'), "node_modules`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $source 'canary.txt'), "canary`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $stateRoot 'repository-password.dpapi.json'), "fixture dpapi envelope`n", $encoding)
    [IO.File]::WriteAllBytes((Join-Path $stateRoot 'run.lock'), [byte[]](0))
    [IO.File]::WriteAllText((Join-Path $source 'document.txt'), "source data`n", $encoding)

    # Restic's own layout. The fake Restic reads the repository ID from config and the snapshot IDs from the file names.
    # The ID has Restic's form (64 hex digits), which the repository record must carry.
    $repositoryId = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $oldRepository 'config'), "$repositoryId`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $oldRepository "keys\$(Get-TextSha256 'fixture key')"), "fixture key`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $oldRepository "index\$(Get-TextSha256 'fixture index')"), "fixture index`n", $encoding)
    foreach ($snapshot in @('fixture snapshot b', 'fixture snapshot a')) {
        [IO.File]::WriteAllText((Join-Path $oldRepository "snapshots\$(Get-TextSha256 $snapshot)"), "$snapshot`n", $encoding)
    }
    [IO.File]::WriteAllBytes((Join-Path $oldRepository "data\$($packId.Substring(0, 2))\$packId"), [byte[]](1..127))
    [IO.File]::WriteAllText((Join-Path $oldRepository "locks\$(Get-TextSha256 'fixture lock')"), "must not copy`n", $encoding)

    $serial = Get-VolumeSerial -Path $oldRepository
    $sourceSerial = Get-VolumeSerial -Path $source
    $planId = '11111111-2222-4333-8444-555555555555'
    $config = [ordered]@{
        schema_version = 1
        plan_id = $planId
        config_generation = 7
        cloud_placeholder_policy = 'strict'
        repository = $oldRepository
        repository_volume_serial = $serial
        restic_executable = Join-Path $installRoot 'restic.exe'
        recovery_tools_directory = $oldRecovery
        python_executable = Join-Path $installRoot 'Python\python.exe'
        state_directory = $stateRoot
        secret_file = Join-Path $stateRoot 'repository-password.dpapi.json'
        recovery_key_file = Join-Path $root 'RecoveryKey.txt'
        exclude_file = Join-Path $installRoot 'excludes.txt'
        canary_file = Join-Path $source 'canary.txt'
        hostname = 'FIXTURE'
        scheduled_tag = 'scheduled'
        minimum_free_gib = 0
        use_vss = $false
        sources = @($source)
        source_identities = [ordered]@{
            $source = [ordered]@{ expected_volume_serial = $sourceSerial }
        }
        topology_paths = [ordered]@{ diagnostics = $diagnostics }
        custom_marker = 'preserve-me'
    }
    $configPath = Join-Path $installRoot 'backup-config.json'
    Write-JsonFile -Path $configPath -Value $config

    foreach ($name in @('restic.exe', 'restore.py', 'secret_store.py', 'RECOVERY.md', 'restic-release.json')) {
        if ($name -eq 'restic.exe') { Copy-Item -LiteralPath $fakeRestic -Destination (Join-Path $oldRecovery $name) }
        else { [IO.File]::WriteAllText((Join-Path $oldRecovery $name), "fixture $name`n", $encoding) }
    }
    Write-JsonFile -Path (Join-Path $oldRecovery 'backup-config.json') -Value $config
    $payloads = @('restic.exe', 'restore.py', 'secret_store.py', 'backup-config.json', 'RECOVERY.md', 'restic-release.json')
    $recoveryManifest = [ordered]@{
        schema_version = 1; repository = $oldRepository; created_utc = [DateTime]::UtcNow.ToString('o')
        note = 'fixture'; files = @($payloads | ForEach-Object { New-FileRecord -Name $_ -Path (Join-Path $oldRecovery $_) })
    }
    Write-JsonFile -Path (Join-Path $oldRecovery 'recovery-manifest.json') -Value $recoveryManifest

    # The record initialize_repository.py writes, plus a field this manager does not know about.
    $recordPath = Join-Path $stateRoot 'repository.json'
    if (-not $NoRepositoryRecord) {
        Write-JsonFile -Path $recordPath -Value ([ordered]@{
            custom_marker = 'preserve-me'
            initialized_utc = '2026-01-02T03:04:05+00:00'
            recovery_key_created = $true
            recovery_key_names_other_repository = $false
            recovery_tools_directory = $oldRecovery
            recovery_tools_manifest = $recoveryManifest
            repository = $oldRepository
            repository_id = $repositoryId
            repository_storage_mode = 'local_ntfs'
            repository_version = 2
            repository_volume_serial = $serial
            schema_version = 1
            secret_created = $true
        })
    }

    $manifestFiles = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force | Sort-Object FullName)
    $runtimeManifest = [ordered]@{
        schema_version = 1; created_utc = [DateTime]::UtcNow.ToString('o'); fixture_marker = 'preserve-me'
        installation_id = ('5' * 64)
        file_count = $manifestFiles.Count
        files = @($manifestFiles | ForEach-Object {
            New-FileRecord -Name $_.FullName.Substring($installRoot.Length + 1) -Path $_.FullName -Property relative_path
        })
    }
    Write-JsonFile -Path (Join-Path $installRoot 'runtime-manifest.json') -Value $runtimeManifest
    [IO.File]::WriteAllText(
        (Join-Path $installRoot 'scheduled-task.xml'),
        "<primary-task-fixture />`n",
        $encoding
    )
    [IO.File]::WriteAllText(
        (Join-Path $installRoot 'google-drive-verification-task.xml'),
        "<verification-task-fixture />`n",
        $encoding
    )
    $log = Join-Path $root 'fake-restic.log'
    return [pscustomobject]@{
        Root=$root; InstallRoot=$installRoot; StateRoot=$stateRoot; OldRepository=$oldRepository;
        OldRecovery=$oldRecovery; NewParent=$newParent; NewRepository=$newRepository;
        ConfigPath=$configPath; ManifestPath=(Join-Path $installRoot 'runtime-manifest.json'); Log=$log;
        Source=$source; Diagnostics=$diagnostics; PlanId=$planId; SourceSerial=$sourceSerial; RepositoryId=$repositoryId;
        RecordPath=$recordPath; JournalPath=(Join-Path $stateRoot 'repository-relocation.journal.json')
    }
}

function Get-RecordHash {
    param([pscustomobject]$Fixture)
    if (-not (Test-Path -LiteralPath $Fixture.RecordPath -PathType Leaf)) { return $null }
    return Get-Hash -Path $Fixture.RecordPath
}

function Read-RecordedRepositoryId {
    param([string]$ConfigPath)
    # What the backup itself reads: restic_common.read_recorded_repository_id with the published configuration.
    $recordedIdProbe = @'
import json
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from restic_common import read_recorded_repository_id
config = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
print(read_recorded_repository_id(config) or "none")
'@
    $output = @($recordedIdProbe | & $python - (Join-Path $projectRoot 'src') $ConfigPath 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "The recorded repository ID probe failed: $($output -join ' ')" }
    return ($output -join '').Trim()
}

function Set-InstallerStyleCanary {
    param([pscustomobject]$Fixture)
    $canarySource = Join-Path $Fixture.StateRoot 'Canary'
    [void][IO.Directory]::CreateDirectory($canarySource)
    $canaryFile = Join-Path $canarySource 'backup-canary.txt'
    [IO.File]::WriteAllText($canaryFile, "protected canary`n", $encoding)
    $canarySerial = Get-VolumeSerial -Path $canarySource

    $config = Get-Content -LiteralPath $Fixture.ConfigPath -Raw | ConvertFrom-Json
    $config.canary_file = $canaryFile
    $config.sources = @($Fixture.Source, $canarySource)
    $config.source_identities | Add-Member -NotePropertyName $canarySource `
        -NotePropertyValue ([pscustomobject]@{ expected_volume_serial = $canarySerial })
    Write-JsonFile -Path $Fixture.ConfigPath -Value $config

    $recoveryConfigPath = Join-Path $Fixture.OldRecovery 'backup-config.json'
    Write-JsonFile -Path $recoveryConfigPath -Value $config
    $recoveryManifestPath = Join-Path $Fixture.OldRecovery 'recovery-manifest.json'
    $recoveryManifest = Get-Content -LiteralPath $recoveryManifestPath -Raw | ConvertFrom-Json
    $recoveryRecord = @($recoveryManifest.files | Where-Object name -eq 'backup-config.json')
    $recoveryRecord[0].bytes = (Get-Item -LiteralPath $recoveryConfigPath).Length
    $recoveryRecord[0].sha256 = Get-Hash -Path $recoveryConfigPath
    Write-JsonFile -Path $recoveryManifestPath -Value $recoveryManifest

    $runtimeManifest = Get-Content -LiteralPath $Fixture.ManifestPath -Raw | ConvertFrom-Json
    $runtimeRecord = @($runtimeManifest.files | Where-Object relative_path -eq 'backup-config.json')
    $runtimeRecord[0].bytes = (Get-Item -LiteralPath $Fixture.ConfigPath).Length
    $runtimeRecord[0].sha256 = Get-Hash -Path $Fixture.ConfigPath
    Write-JsonFile -Path $Fixture.ManifestPath -Value $runtimeManifest
}

function Invoke-Relocation {
    param(
        [pscustomobject]$Fixture,
        [string]$Destination,
        [int]$FailurePoint = 0,
        [int]$CrashPoint = 0,
        [int]$CrashDuringCopyAfterFiles = 0,
        [int]$CrashAfterStageCreation = 0,
        [int]$CrashAfterEmptyDestinationRemoval = 0,
        [long]$AvailableBytes = -1,
        [string]$DigestOverride = '',
        # The backup folder the configuration names now, when an earlier move in the same fixture changed it.
        [string]$CurrentRepository = '',
        # Pauses the copy after this many files and runs -WhilePaused (given the request nonce) before it goes on.
        [int]$PauseDuringCopyAfterFiles = 0,
        [scriptblock]$WhilePaused = $null,
        # Makes the Google Drive hold check fail, as if a folder's file ID did not survive a rename there.
        [switch]$FailFolderHoldProbe
    )
    $current = if ($CurrentRepository) { $CurrentRepository } else { $Fixture.OldRepository }
    $nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
    $configHash = Get-Hash -Path $Fixture.ConfigPath
    $digest = if ($DigestOverride) { $DigestOverride } else {
        Get-RequestDigest -Current $current -New ([IO.Path]::GetFullPath($Destination).TrimEnd('\')) `
            -ConfigHash $configHash -Nonce $nonce
    }
    $resultPath = Join-Path $Fixture.StateRoot "RepositoryManagerResults\$nonce.json"
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $Fixture.InstallRoot 'Manage-Repository.ps1'), '-Relocate',
        '-NewRepository', $Destination, '-ExpectedUserSid', $sid,
        '-ExpectedCurrentRepository', $current, '-ExpectedConfigSha256', $configHash,
        '-ResultPath', $resultPath, '-RequestNonce', $nonce, '-RequestDigest', $digest,
        '-TestRoot', $Fixture.Root, '-TestFailAfterPublish', $FailurePoint,
        '-TestCrashAfterPublish', $CrashPoint,
        '-TestCrashDuringCopyAfterFiles', $CrashDuringCopyAfterFiles,
        '-TestCrashAfterStageCreation', $CrashAfterStageCreation,
        '-TestCrashAfterEmptyDestinationRemoval', $CrashAfterEmptyDestinationRemoval,
        '-TestAvailableBytes', $AvailableBytes
    )
    if ($PauseDuringCopyAfterFiles -gt 0) { $arguments += @('-TestPauseDuringCopyAfterFiles', $PauseDuringCopyAfterFiles) }
    if ($FailFolderHoldProbe) { $arguments += '-TestFailFolderHoldProbe' }
    $paused = $false
    $whilePausedResult = $null
    if ($PauseDuringCopyAfterFiles -le 0) {
        $priorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $powershell @arguments 2>&1 | ForEach-Object { [string]$_ })
            $exitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $priorPreference }
    }
    else {
        # Started without waiting, so the test can act while the manager copies, as another program could.
        $standardOutput = Join-Path $Fixture.Root "manager-$nonce.out.txt"
        $standardError = Join-Path $Fixture.Root "manager-$nonce.err.txt"
        $commandLine = (@($arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) })) -join ' '
        $process = Start-Process -FilePath $powershell -ArgumentList $commandLine -NoNewWindow -PassThru `
            -RedirectStandardOutput $standardOutput -RedirectStandardError $standardError
        $null = $process.Handle
        $pausedSignal = Join-Path $Fixture.Root 'copy-paused.signal'
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while (-not [IO.File]::Exists($pausedSignal) -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        $paused = [IO.File]::Exists($pausedSignal)
        try {
            if ($paused -and $null -ne $WhilePaused) { $whilePausedResult = & $WhilePaused $nonce }
        }
        finally { [IO.File]::WriteAllText((Join-Path $Fixture.Root 'copy-resume.signal'), "resume`n", $encoding) }
        if (-not $process.WaitForExit(180000)) {
            $process.Kill()
            throw 'The paused repository manager did not finish.'
        }
        $exitCode = $process.ExitCode
        $output = @(@(Get-Content -LiteralPath $standardOutput) + @(Get-Content -LiteralPath $standardError) |
            ForEach-Object { [string]$_ })
        foreach ($signal in @($pausedSignal, (Join-Path $Fixture.Root 'copy-resume.signal'))) {
            if ([IO.File]::Exists($signal)) { [IO.File]::Delete($signal) }
        }
    }
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    $progressPath = $resultPath + '.progress.json'
    $progress = if (Test-Path -LiteralPath $progressPath) { Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{
        ExitCode=$exitCode; Output=$output; Result=$result; Progress=$progress; ResultPath=$resultPath;
        Nonce=$nonce; Digest=$digest; ConfigHash=$configHash; Paused=$paused; WhilePaused=$whilePausedResult
    }
}

function Invoke-Recovery {
    param([pscustomobject]$Fixture)
    $journalPath = Join-Path $Fixture.StateRoot 'repository-relocation.journal.json'
    $journalHash = Get-Hash -Path $journalPath
    $nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
    $digest = Get-RecoveryRequestDigest -JournalHash $journalHash -Nonce $nonce
    $resultPath = Join-Path $Fixture.StateRoot "RepositoryManagerResults\$nonce.json"
    $arguments = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',
        (Join-Path $Fixture.InstallRoot 'Manage-Repository.ps1'), '-Recover',
        '-ExpectedUserSid',$sid,'-ExpectedJournalSha256',$journalHash,
        '-ResultPath',$resultPath,'-RequestNonce',$nonce,'-RequestDigest',$digest,
        '-TestRoot',$Fixture.Root
    )
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorPreference }
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ ExitCode=$exitCode; Output=$output; Result=$result; JournalHash=$journalHash; Nonce=$nonce; Digest=$digest }
}

$productionConfig = Join-Path $env:ProgramFiles 'ResticBackuper\backup-config.json'
$productionHashBefore = $null
$taskXmlBefore = $null
if (-not $SkipInstalledChecks) {
    $productionHashBefore = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
    $taskXmlBefore = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }
}

# Settings a user can leave in their own environment. The manager must not hand any of them to Restic or to the
# password helper it starts; the fake refuses to run when one arrives.
$leakedVariables = [ordered]@{
    RESTIC_PASSWORD_FILE = 'Z:\elsewhere\not-the-backup-password.txt'
    RESTIC_REPOSITORY = 'Z:\elsewhere\not-the-backup'
    RCLONE_CONFIG = 'Z:\elsewhere\not-an-rclone-config.conf'
}
$priorVariables = @{}
foreach ($name in $leakedVariables.Keys) {
    $priorVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $leakedVariables[$name], 'Process')
}

try {
    # Successful copy-only relocation with full identity/history/check verification.
    $fixture = New-Fixture
    $oldRepositoryDigest = Get-TreeDigest -Root $fixture.OldRepository -ExcludeLocks
    $oldRecoveryDigest = Get-TreeDigest -Root $fixture.OldRecovery
    # A distinctive protected DACL on the record: the rewrite must keep the record's permissions, not take the
    # temporary file's. (Outside test mode the manager also resets them to the installer's, which needs elevation.)
    $recordAcl = Get-Acl -LiteralPath $fixture.RecordPath
    $recordAcl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($recordAcl.Access)) { [void]$recordAcl.RemoveAccessRule($rule) }
    $recordAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
    $recordAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), 'ReadAndExecute', 'Allow'))
    Set-Acl -LiteralPath $fixture.RecordPath -AclObject $recordAcl
    $recordDaclBefore = (Get-Acl -LiteralPath $fixture.RecordPath).GetSecurityDescriptorSddlForm('Access')
    $recordBefore = Get-Content -LiteralPath $fixture.RecordPath -Raw | ConvertFrom-Json
    $run = Invoke-Relocation -Fixture $fixture -Destination $fixture.NewRepository
    if ($run.ExitCode -ne 0) {
        Write-Output ("success-case output: " + ($run.Output -join ' | '))
        if ($null -ne $run.Result) { Write-Output ("success-case result: " + ($run.Result | ConvertTo-Json -Compress -Depth 8)) }
    }
    Assert-True ($run.ExitCode -eq 0) 'successful relocation exit code'
    Assert-True ($run.Result.ok -eq $true -and $run.Result.changed -eq $true) 'successful result contract'
    Assert-True ([string]$run.Result.request_nonce -ceq $run.Nonce) 'result nonce binding'
    Assert-True ([string]$run.Result.request_digest -ceq $run.Digest) 'result digest binding'
    Assert-True ([string]$run.Result.request_user_sid -eq $sid) 'result SID binding'
    Assert-True ([string]$run.Result.current_repository -eq $fixture.OldRepository) 'result current binding'
    Assert-True ([string]$run.Result.new_repository -eq $fixture.NewRepository) 'result new binding'
    Assert-True ([string]$run.Result.old_repository -eq $fixture.OldRepository) 'result old repository field'
    Assert-True ($run.Result.old_repository_retained -eq $true) 'result old repository retention boolean'
    Assert-True ([string]$run.Result.expected_config_sha256 -ceq $run.ConfigHash) 'result config hash binding'
    Assert-True ([string]$run.Result.plan_id -ceq $fixture.PlanId) 'result stable plan identity binding'
    Assert-True ([long]$run.Result.previous_config_generation -eq 7) 'result previous generation binding'
    Assert-True ([long]$run.Result.config_generation -eq 8) 'result generation increments exactly once'
    Assert-True ([string]$run.Progress.stage -eq 'complete' -and [double]$run.Progress.percent -eq 100) 'complete progress contract'
    Assert-True ([string]$run.Progress.plan_id -ceq $fixture.PlanId -and
        [long]$run.Progress.previous_config_generation -eq 7 -and
        [long]$run.Progress.config_generation -eq 8) 'progress plan-generation binding'
    foreach ($name in @('files_copied','files_total','bytes_copied','bytes_total','throughput_bytes_per_second','estimated_seconds_remaining','cancellable')) {
        Assert-True ($null -ne $run.Progress.PSObject.Properties[$name]) "progress field $name"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $fixture.NewRepository 'config') -PathType Leaf) 'destination repository exists'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.NewRepository 'locks'))) 'repository locks excluded'
    $expectedResticFiles = @(Get-RelativeFiles -Root $fixture.OldRepository | Where-Object { -not $_.StartsWith('locks\') })
    Assert-True (((Get-RelativeFiles -Root $fixture.NewRepository) -join '|') -ceq ($expectedResticFiles -join '|')) 'destination holds exactly the backup files'
    Assert-True ((Get-TreeDigest -Root $fixture.OldRepository -ExcludeLocks) -eq $oldRepositoryDigest) 'old repository retained byte-for-byte excluding locks'
    Assert-True ((Get-TreeDigest -Root $fixture.OldRecovery) -eq $oldRecoveryDigest) 'old RecoveryTools untouched'
    $publishedConfig = Get-Content -LiteralPath $fixture.ConfigPath -Raw | ConvertFrom-Json
    Assert-True ([string]$publishedConfig.repository -eq $fixture.NewRepository) 'protected config repository updated'
    Assert-True ([string]$publishedConfig.custom_marker -eq 'preserve-me') 'protected custom fields preserved'
    Assert-True ([string]$publishedConfig.plan_id -ceq $fixture.PlanId -and
        [long]$publishedConfig.config_generation -eq 8) 'protected plan preserved and generation advanced'
    Assert-True ([string]$publishedConfig.cloud_placeholder_policy -ceq 'strict') 'protected cloud policy preserved'
    Assert-True ([string]$publishedConfig.source_identities.($fixture.Source).expected_volume_serial -ceq $fixture.SourceSerial) 'protected source identity preserved'
    Assert-True ([string]$publishedConfig.topology_paths.diagnostics -eq $fixture.Diagnostics) 'protected topology paths preserved'
    $newRecovery = Join-Path $fixture.NewParent 'RecoveryTools'
    Assert-True ([string]$publishedConfig.recovery_tools_directory -eq $newRecovery) 'protected recovery sibling updated'
    $recoveryConfig = Get-Content -LiteralPath (Join-Path $newRecovery 'backup-config.json') -Raw | ConvertFrom-Json
    $recoveryManifest = Get-Content -LiteralPath (Join-Path $newRecovery 'recovery-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ([string]$recoveryConfig.repository -eq $fixture.NewRepository) 'recovery config repository updated'
    Assert-True ([string]$recoveryConfig.plan_id -ceq $fixture.PlanId -and
        [long]$recoveryConfig.config_generation -eq 8) 'recovery plan preserved and generation synchronized'
    Assert-True ([string]$recoveryConfig.source_identities.($fixture.Source).expected_volume_serial -ceq $fixture.SourceSerial) 'recovery source identity preserved'
    Assert-True ([string]$recoveryConfig.topology_paths.diagnostics -eq $fixture.Diagnostics) 'recovery topology paths preserved'
    Assert-True ([string]$recoveryManifest.repository -eq $fixture.NewRepository) 'recovery manifest repository updated'
    $runtimeManifest = Get-Content -LiteralPath $fixture.ManifestPath -Raw | ConvertFrom-Json
    $configRecord = @($runtimeManifest.files | Where-Object relative_path -eq 'backup-config.json')
    Assert-True ($configRecord.Count -eq 1 -and [string]$configRecord[0].sha256 -eq (Get-Hash -Path $fixture.ConfigPath)) 'runtime manifest rebound'
    # Clean-up of old backups is bound to the installer's installation_id: a move keeps it, so a saved setting stays on.
    Assert-True ([string]$runtimeManifest.installation_id -ceq ('5' * 64) -and [string]$runtimeManifest.fixture_marker -ceq 'preserve-me') 'runtime manifest keeps the installer''s installation_id'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.StateRoot 'repository-relocation.journal.json'))) 'success journal removed'
    $logText = Get-Content -LiteralPath $fixture.Log -Raw
    Assert-True ($logText -match '\tcat\tconfig' -and $logText -match '\tsnapshots\t--json' -and $logText -match '\tcheck') 'fake Restic verification commands used'
    Assert-True ($logText -notmatch '(?im)(^|\t)(backup|init|forget|prune|delete)(\t|$)') 'no history-creating or destructive Restic command'

    # The repository record follows the move, so the backup still reads the repository ID from it.
    $recordBytes = [IO.File]::ReadAllBytes($fixture.RecordPath)
    Assert-True (-not ($recordBytes.Length -ge 3 -and $recordBytes[0] -eq 0xEF -and $recordBytes[1] -eq 0xBB -and $recordBytes[2] -eq 0xBF)) 'repository record is UTF-8 without BOM'
    $record = [Text.UTF8Encoding]::new($false, $true).GetString($recordBytes) | ConvertFrom-Json
    Assert-True ([string]$record.repository -eq $fixture.NewRepository) 'repository record names the new location'
    Assert-True ([string]$record.repository_id -ceq $fixture.RepositoryId) 'repository record keeps the repository ID'
    Assert-True ([string]$record.repository_volume_serial -ceq (Get-VolumeSerial -Path $fixture.NewRepository)) 'repository record names the new volume'
    Assert-True ([string]$record.repository_storage_mode -ceq 'local_ntfs') 'repository record keeps the local storage mode'
    Assert-True ([string]$record.recovery_tools_directory -eq $newRecovery) 'repository record names the new recovery tools'
    Assert-True ([string]$record.recovery_tools_manifest.repository -eq $fixture.NewRepository) 'repository record carries the moved recovery manifest'
    Assert-True ([string]$record.custom_marker -ceq 'preserve-me' -and
        [string]$record.initialized_utc -ceq [string]$recordBefore.initialized_utc -and
        [long]$record.repository_version -eq 2 -and $record.secret_created -eq $true -and
        $record.recovery_key_created -eq $true -and $record.recovery_key_names_other_repository -eq $false -and
        [long]$record.schema_version -eq 1) 'repository record keeps every other field'
    Assert-True ($null -eq $record.PSObject.Properties['drivefs_my_drive_root'] -and
        $null -eq $record.PSObject.Properties['drivefs_cache_directory']) 'local repository record has no DriveFS fields'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.relocated_utc)) 'repository record says when it moved'
    Assert-True ((Get-Acl -LiteralPath $fixture.RecordPath).GetSecurityDescriptorSddlForm('Access') -ceq $recordDaclBefore) 'repository record keeps its permissions'
    Assert-True ((Read-RecordedRepositoryId -ConfigPath $fixture.ConfigPath) -ceq $fixture.RepositoryId) 'backup reads the repository ID after the move'

    # DriveFS is an explicit backend: only the encrypted repository moves onto
    # its synthetic filesystem, while recovery material stays on protected NTFS.
    $driveFsFixture = New-Fixture
    Set-InstallerStyleCanary -Fixture $driveFsFixture
    $driveFsRoot = Join-Path $driveFsFixture.Root 'DriveFs\My Drive'
    $driveFsParent = Join-Path $driveFsRoot 'ResticBackups'
    $driveFsCache = Join-Path $driveFsFixture.Root 'LocalAppData\Google\DriveFS'
    foreach ($directory in @($driveFsRoot, $driveFsParent, $driveFsCache)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $driveFsRepository = Join-Path $driveFsParent 'Personal'
    $driveFsRun = Invoke-Relocation -Fixture $driveFsFixture -Destination $driveFsRepository
    if ($driveFsRun.ExitCode -ne 0) {
        Write-Output ("DriveFS-case output: " + ($driveFsRun.Output -join ' | '))
    }
    Assert-True ($driveFsRun.ExitCode -eq 0) 'DriveFS relocation succeeds through disposable provider semantics'
    $driveFsConfig = Get-Content -LiteralPath $driveFsFixture.ConfigPath -Raw | ConvertFrom-Json
    $driveFsRecovery = Join-Path $driveFsFixture.Root 'ProgramData\ResticBackuperRecoveryTools'
    Assert-True ([string]$driveFsConfig.repository_storage_mode -ceq 'google_drivefs_stream') 'DriveFS mode emitted explicitly'
    Assert-True ([string]$driveFsConfig.drivefs_my_drive_root -eq $driveFsRoot) 'DriveFS My Drive root emitted canonically'
    Assert-True ([string]$driveFsConfig.drivefs_cache_directory -eq $driveFsCache) 'DriveFS cache emitted canonically'
    Assert-True ($null -eq $driveFsConfig.PSObject.Properties['repository_drivefs_root']) 'legacy DriveFS root alias not emitted'
    Assert-True ([string]$driveFsConfig.recovery_tools_directory -eq $driveFsRecovery) 'DriveFS recovery tools remain in protected NTFS root'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $driveFsParent 'RecoveryTools'))) 'no recovery material copied beside DriveFS repository'
    Assert-True (Test-Path -LiteralPath (Join-Path $driveFsRecovery 'recovery-manifest.json') -PathType Leaf) 'protected DriveFS recovery bundle committed'
    Assert-True ([string]$driveFsRun.Result.repository_manifest_sha256 -ceq
        (Get-TreeDigest -Root $driveFsFixture.OldRepository -ExcludeLocks)) 'DriveFS result binds exact repository commit manifest'
    Assert-True (@(Get-ChildItem -LiteralPath $driveFsParent -Force |
        Where-Object Name -like '.restic-repository-*.staging').Count -eq 0) 'DriveFS staging removed after verified promotion'
    Assert-True (@(Get-ChildItem -LiteralPath $driveFsParent -Force |
        Where-Object Name -like '.resticbackuper-provider-*').Count -eq 0) 'DriveFS provider probes cleaned'
    $driveFsRecord = Get-Content -LiteralPath $driveFsFixture.RecordPath -Raw | ConvertFrom-Json
    Assert-True ([string]$driveFsRecord.repository -eq $driveFsRepository -and
        [string]$driveFsRecord.repository_id -ceq $driveFsFixture.RepositoryId) 'DriveFS repository record names the new location and keeps the ID'
    Assert-True ([string]$driveFsRecord.repository_storage_mode -ceq 'google_drivefs_stream' -and
        [string]$driveFsRecord.drivefs_my_drive_root -eq $driveFsRoot -and
        [string]$driveFsRecord.drivefs_cache_directory -eq $driveFsCache) 'DriveFS repository record carries the DriveFS bindings'
    Assert-True ([string]$driveFsRecord.recovery_tools_directory -eq $driveFsRecovery) 'DriveFS repository record names the protected recovery tools'
    Assert-True ((Read-RecordedRepositoryId -ConfigPath $driveFsFixture.ConfigPath) -ceq $driveFsFixture.RepositoryId) 'backup reads the repository ID after a DriveFS move'
    Assert-True (@(Get-ChildItem -LiteralPath $driveFsParent -Force |
        Where-Object Name -like '.resticbackuper-hold-*').Count -eq 0) 'Google Drive hold checks cleaned'

    # Held folders, file IDs and renames through a handle have not been tried on Google Drive's own file system, and
    # rollback and recovery need them as much as the move does. When they fail on a throwaway folder there, the move is
    # refused in plain words before the journal is written: no copy starts, so nothing needs rolling back.
    $holdFixture = New-Fixture
    $holdRoot = Join-Path $holdFixture.Root 'DriveFs\My Drive'
    $holdParent = Join-Path $holdRoot 'ResticBackups'
    foreach ($directory in @($holdRoot, $holdParent, (Join-Path $holdFixture.Root 'LocalAppData\Google\DriveFS'))) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $holdConfigBefore = Get-Hash -Path $holdFixture.ConfigPath
    $holdRun = Invoke-Relocation -Fixture $holdFixture -Destination (Join-Path $holdParent 'Personal') -FailFolderHoldProbe
    Assert-True ($holdRun.ExitCode -ne 0 -and $null -ne $holdRun.Result -and
        [string]$holdRun.Result.error -match 'Google Drive could not keep a folder in place') ('a failed Google Drive hold check refuses the move in plain words: ' + ($holdRun.Output -join ' | '))
    Assert-True (-not (Test-Path -LiteralPath $holdFixture.Log)) 'a failed Google Drive hold check stops the move before its first Restic step'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $holdFixture.StateRoot 'repository-relocation.journal.json'))) 'a failed Google Drive hold check leaves no journal'
    Assert-True ((Get-Hash -Path $holdFixture.ConfigPath) -eq $holdConfigBefore) 'a failed Google Drive hold check keeps the configuration'
    Assert-True (@(Get-ChildItem -LiteralPath $holdParent -Force).Count -eq 0) 'a failed Google Drive hold check leaves nothing in Google Drive'

    # Only Restic's own files are copied, and anything else beside them stays where it is, from a local folder ...
    $extrasFixture = New-Fixture
    $extrasExpected = @(Get-RelativeFiles -Root $extrasFixture.OldRepository | Where-Object { -not $_.StartsWith('locks\') })
    $extras = @(Add-UnrelatedFiles -Repository $extrasFixture.OldRepository)
    $extrasRun = Invoke-Relocation -Fixture $extrasFixture -Destination $extrasFixture.NewRepository
    if ($extrasRun.ExitCode -ne 0) { Write-Output ("unrelated-files output: " + ($extrasRun.Output -join ' | ')) }
    Assert-True ($extrasRun.ExitCode -eq 0 -and $extrasRun.Result.ok -eq $true) 'move succeeds with unrelated files beside the backup'
    foreach ($extra in $extras) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $extrasFixture.NewRepository $extra))) "unrelated file not copied: $extra"
        Assert-True (Test-Path -LiteralPath (Join-Path $extrasFixture.OldRepository $extra) -PathType Leaf) "unrelated file left in place: $extra"
    }
    Assert-True (((Get-RelativeFiles -Root $extrasFixture.NewRepository) -join '|') -ceq ($extrasExpected -join '|')) 'only the backup files were copied'

    # ... and from a Google Drive folder, which keeps no permissions, back to a local folder.
    $driveFsExtras = @(Add-UnrelatedFiles -Repository $driveFsRepository)
    $backParent = Join-Path $driveFsFixture.Root 'BackStore'
    [void][IO.Directory]::CreateDirectory($backParent)
    $backRepository = Join-Path $backParent 'Personal'
    $backRun = Invoke-Relocation -Fixture $driveFsFixture -Destination $backRepository -CurrentRepository $driveFsRepository
    if ($backRun.ExitCode -ne 0) { Write-Output ("DriveFS-source output: " + ($backRun.Output -join ' | ')) }
    Assert-True ($backRun.ExitCode -eq 0 -and $backRun.Result.ok -eq $true) 'move from Google Drive succeeds with unrelated files there'
    foreach ($extra in $driveFsExtras) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $backRepository $extra))) "unrelated Google Drive file not copied: $extra"
        Assert-True (Test-Path -LiteralPath (Join-Path $driveFsRepository $extra) -PathType Leaf) "unrelated Google Drive file left in place: $extra"
    }
    Assert-True (((Get-RelativeFiles -Root $backRepository) -join '|') -ceq ($expectedResticFiles -join '|')) 'only the backup files came back from Google Drive'

    # A local stage is administrator-only, so something else turning up in it is refused rather than copied along.
    $strayFixture = New-Fixture
    $strayRun = Invoke-Relocation -Fixture $strayFixture -Destination $strayFixture.NewRepository `
        -PauseDuringCopyAfterFiles 1 -WhilePaused {
            param([string]$Nonce)
            $stage = Join-Path $strayFixture.NewParent ".restic-repository-$Nonce.staging"
            [IO.File]::WriteAllText((Join-Path $stage 'evil.dll'), "planted`n", $encoding)
            return 'planted'
        }
    Assert-True ($strayRun.Paused -and $strayRun.WhilePaused -eq 'planted') 'stray-file case paused during the copy'
    Assert-True ($strayRun.ExitCode -ne 0 -and [string]$strayRun.Result.error -match 'not part of the backup: evil\.dll') 'a file planted in the stage is refused by name'
    Assert-True (-not (Test-Path -LiteralPath $strayFixture.NewRepository)) 'a refused copy never becomes the backup location'
    Assert-True (@(Get-ChildItem -LiteralPath $strayFixture.NewParent -Force |
        Where-Object Name -like '.restic-*.staging').Count -eq 0) 'a refused copy leaves no stage behind'

    # While the copy runs, a program running as the user tries to rename the stages, or the folder holding them, to
    # swap in a junction to a folder of its choosing. Each stage is held open without delete sharing, so every rename
    # is refused and nothing is ever written through a junction.
    $raceFixture = New-Fixture
    $raceDigest = Get-TreeDigest -Root $raceFixture.OldRepository -ExcludeLocks
    $decoy = Join-Path $raceFixture.Root 'Decoy'
    $race = Invoke-Relocation -Fixture $raceFixture -Destination $raceFixture.NewRepository `
        -PauseDuringCopyAfterFiles 1 -WhilePaused {
            param([string]$Nonce)
            $outcome = [ordered]@{}
            foreach ($target in @(
                [pscustomobject]@{ Name = 'parent'; Path = $raceFixture.NewParent },
                [pscustomobject]@{ Name = 'recovery stage'; Path = (Join-Path $raceFixture.NewParent ".restic-recovery-$Nonce.staging") },
                [pscustomobject]@{ Name = 'repository stage'; Path = (Join-Path $raceFixture.NewParent ".restic-repository-$Nonce.staging") }
            )) {
                $moved = $target.Path + '.moved'
                try { [IO.Directory]::Move($target.Path, $moved) }
                catch { $outcome[$target.Name] = 'refused'; continue }
                $outcome[$target.Name] = 'renamed'
                if ($target.Name -ne 'repository stage') { [IO.Directory]::Move($moved, $target.Path); continue }
                # What an attacker would do next: the same folders somewhere of its choosing, and a junction to them.
                [void][IO.Directory]::CreateDirectory($decoy)
                foreach ($folder in @(Get-ChildItem -LiteralPath $moved -Recurse -Directory -Force)) {
                    [void][IO.Directory]::CreateDirectory((Join-Path $decoy $folder.FullName.Substring($moved.Length + 1)))
                }
                & cmd.exe /d /c mklink /J "$($target.Path)" "$decoy" | Out-Null
                $plantedLinks.Add($target.Path)
            }
            return $outcome
        }
    if ($race.ExitCode -ne 0) { Write-Output ("swap-case output: " + ($race.Output -join ' | ')) }
    Assert-True ($race.Paused -and $null -ne $race.WhilePaused) 'swap case paused during the copy'
    Assert-True ($race.WhilePaused['parent'] -eq 'refused') 'the folder holding the stages cannot be renamed during the copy'
    Assert-True ($race.WhilePaused['recovery stage'] -eq 'refused') 'the recovery-tools stage cannot be renamed during the copy'
    Assert-True ($race.WhilePaused['repository stage'] -eq 'refused') 'the backup stage cannot be renamed during the copy'
    Assert-True (@(Get-RelativeFiles -Root $decoy).Count -eq 0) 'nothing is written through a swapped stage'
    Assert-True ($race.ExitCode -eq 0 -and $race.Result.ok -eq $true) 'the move completes after the swap attempts'
    Assert-True ((Get-TreeDigest -Root $raceFixture.NewRepository -ExcludeLocks) -eq $raceDigest) 'the new location holds exactly the backup'

    $driveFsCrashFixture = New-Fixture
    $driveFsCrashRoot = Join-Path $driveFsCrashFixture.Root 'DriveFs\My Drive'
    $driveFsCrashParent = Join-Path $driveFsCrashRoot 'ResticBackups'
    $driveFsCrashCache = Join-Path $driveFsCrashFixture.Root 'LocalAppData\Google\DriveFS'
    foreach ($directory in @($driveFsCrashRoot, $driveFsCrashParent, $driveFsCrashCache)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $driveFsCrashRepository = Join-Path $driveFsCrashParent 'Personal'
    $driveFsCrashRecordBefore = Get-RecordHash -Fixture $driveFsCrashFixture
    $driveFsCrash = Invoke-Relocation -Fixture $driveFsCrashFixture `
        -Destination $driveFsCrashRepository -CrashPoint 1
    Assert-True ($driveFsCrash.ExitCode -ne 0) 'DriveFS post-promotion crash terminates'
    $driveFsRecoveryRun = Invoke-Recovery -Fixture $driveFsCrashFixture
    Assert-True ($driveFsRecoveryRun.ExitCode -eq 0 -and $driveFsRecoveryRun.Result.ok -eq $true) 'DriveFS post-promotion crash rolls back from protected journal'
    Assert-True ((Get-RecordHash -Fixture $driveFsCrashFixture) -ceq $driveFsCrashRecordBefore) 'DriveFS crash recovery restores the repository record'
    Assert-True (-not (Test-Path -LiteralPath $driveFsCrashRepository)) 'DriveFS crash recovery removes only manifest-proven promoted repository'
    Assert-True (Test-Path -LiteralPath $driveFsCrashFixture.OldRepository -PathType Container) 'DriveFS crash recovery retains old repository'

    # Existing empty destinations are accepted, but another repository is never adopted.
    $emptyFixture = New-Fixture
    [void][IO.Directory]::CreateDirectory($emptyFixture.NewRepository)
    $emptyRun = Invoke-Relocation -Fixture $emptyFixture -Destination $emptyFixture.NewRepository
    Assert-True ($emptyRun.ExitCode -eq 0) 'empty destination accepted'
    $nonemptyFixture = New-Fixture
    [void][IO.Directory]::CreateDirectory($nonemptyFixture.NewRepository)
    [IO.File]::WriteAllText((Join-Path $nonemptyFixture.NewRepository 'config'), "foreign repository`n", $encoding)
    $nonemptyRun = Invoke-Relocation -Fixture $nonemptyFixture -Destination $nonemptyFixture.NewRepository
    Assert-True ($nonemptyRun.ExitCode -ne 0 -and $nonemptyRun.Result.error -match 'missing or completely empty') 'nonempty destination rejected'

    # Without a repository record there is nothing to keep in step, and the move does not invent one.
    $noRecordFixture = New-Fixture -NoRepositoryRecord
    $noRecordRun = Invoke-Relocation -Fixture $noRecordFixture -Destination $noRecordFixture.NewRepository
    Assert-True ($noRecordRun.ExitCode -eq 0 -and $noRecordRun.Result.ok -eq $true) 'move without a repository record succeeds'
    Assert-True (-not (Test-Path -LiteralPath $noRecordFixture.RecordPath)) 'move without a repository record creates none'

    # A record left naming an earlier folder of the same backup is brought up to date.
    $staleRecordFixture = New-Fixture
    $staleRecord = Get-Content -LiteralPath $staleRecordFixture.RecordPath -Raw | ConvertFrom-Json
    $staleRecord.repository = Join-Path $staleRecordFixture.Root 'EarlierStore\Personal'
    Write-JsonFile -Path $staleRecordFixture.RecordPath -Value $staleRecord
    $staleRecordRun = Invoke-Relocation -Fixture $staleRecordFixture -Destination $staleRecordFixture.NewRepository
    Assert-True ($staleRecordRun.ExitCode -eq 0) 'record naming an earlier folder of the same backup is accepted'
    Assert-True ([string](Get-Content -LiteralPath $staleRecordFixture.RecordPath -Raw | ConvertFrom-Json).repository -eq
        $staleRecordFixture.NewRepository) 'record naming an earlier folder is brought up to date'

    # A record of another backup, or one that is damaged, stops the move before anything is copied.
    $recordRefusals = @(
        [pscustomobject]@{ Name = 'another backup'; Id = ('ab' * 32); Pattern = 'belongs to a different backup' },
        [pscustomobject]@{ Name = 'damaged'; Id = 'not-a-repository-id'; Pattern = 'is damaged' }
    )
    foreach ($refusal in $recordRefusals) {
        $foreignFixture = New-Fixture
        $foreignRecord = Get-Content -LiteralPath $foreignFixture.RecordPath -Raw | ConvertFrom-Json
        $foreignRecord.repository_id = $refusal.Id
        Write-JsonFile -Path $foreignFixture.RecordPath -Value $foreignRecord
        $foreignRecordHash = Get-RecordHash -Fixture $foreignFixture
        $foreignConfigHash = Get-Hash -Path $foreignFixture.ConfigPath
        $foreignRun = Invoke-Relocation -Fixture $foreignFixture -Destination $foreignFixture.NewRepository
        Assert-True ($foreignRun.ExitCode -ne 0 -and [string]$foreignRun.Result.error -match $refusal.Pattern) "record of $($refusal.Name) refused"
        Assert-True (-not (Test-Path -LiteralPath $foreignFixture.NewRepository) -and
            @(Get-ChildItem -LiteralPath $foreignFixture.NewParent -Force).Count -eq 0) "record of $($refusal.Name) refused before any copy"
        Assert-True ((Get-RecordHash -Fixture $foreignFixture) -ceq $foreignRecordHash -and
            (Get-Hash -Path $foreignFixture.ConfigPath) -ceq $foreignConfigHash) "record of $($refusal.Name) leaves the record and configuration alone"
        Assert-True (-not (Test-Path -LiteralPath $foreignFixture.JournalPath)) "record of $($refusal.Name) leaves no journal"
    }

    # Request binding and v1 path policy rejections occur before any copy.
    $digestFixture = New-Fixture
    $badDigest = Invoke-Relocation -Fixture $digestFixture -Destination $digestFixture.NewRepository -DigestOverride ('0' * 64)
    Assert-True ($badDigest.ExitCode -ne 0 -and $null -eq $badDigest.Result) 'bad digest rejected before result channel'
    $sameFixture = New-Fixture
    $sameRun = Invoke-Relocation -Fixture $sameFixture -Destination $sameFixture.OldRepository
    Assert-True ($sameRun.ExitCode -ne 0) 'current repository rejected as destination'
    $sameParentFixture = New-Fixture
    $sameParentRun = Invoke-Relocation -Fixture $sameParentFixture -Destination (Join-Path (Split-Path -Parent $sameParentFixture.OldRepository) 'Other')
    Assert-True ($sameParentRun.ExitCode -ne 0 -and $sameParentRun.Result.error -match 'different parent') 'same-parent destination rejected'
    $spaceFixture = New-Fixture
    $spaceRun = Invoke-Relocation -Fixture $spaceFixture -Destination $spaceFixture.NewRepository -AvailableBytes 1
    Assert-True ($spaceRun.ExitCode -ne 0 -and $spaceRun.Result.error -match 'insufficient space') 'insufficient capacity rejected'
    $topologyFixture = New-Fixture
    $topologyRun = Invoke-Relocation -Fixture $topologyFixture `
        -Destination (Join-Path $topologyFixture.Diagnostics 'Personal')
    Assert-True ($topologyRun.ExitCode -ne 0 -and $topologyRun.Result.error -match 'overlaps protected backup state') 'optional topology destination overlap rejected'

    # Plan migration, generation bounds, canonical identity keys, and source-volume identity fail closed.
    $legacyFixture = New-Fixture
    $legacyConfig = Get-Content -LiteralPath $legacyFixture.ConfigPath -Raw | ConvertFrom-Json
    foreach ($name in @('plan_id','config_generation','source_identities','cloud_placeholder_policy')) {
        $legacyConfig.PSObject.Properties.Remove($name)
    }
    Write-JsonFile -Path $legacyFixture.ConfigPath -Value $legacyConfig
    $legacyRun = Invoke-Relocation -Fixture $legacyFixture -Destination $legacyFixture.NewRepository
    Assert-True ($legacyRun.ExitCode -ne 0 -and $legacyRun.Result.error -match 'migration is required') 'legacy configuration requires explicit migration'

    $identityFixture = New-Fixture
    $identityConfig = Get-Content -LiteralPath $identityFixture.ConfigPath -Raw | ConvertFrom-Json
    $wrongSerial = if ($identityFixture.SourceSerial -cne '00000000') { '00000000' } else { 'FFFFFFFF' }
    $identityConfig.source_identities.($identityFixture.Source).expected_volume_serial = $wrongSerial
    Write-JsonFile -Path $identityFixture.ConfigPath -Value $identityConfig
    $identityRun = Invoke-Relocation -Fixture $identityFixture -Destination $identityFixture.NewRepository
    Assert-True ($identityRun.ExitCode -ne 0 -and $identityRun.Result.error -match 'Source volume identity mismatch') 'substituted source volume rejected'

    $canonicalFixture = New-Fixture
    $canonicalConfig = Get-Content -LiteralPath $canonicalFixture.ConfigPath -Raw | ConvertFrom-Json
    $canonicalIdentity = $canonicalConfig.source_identities.($canonicalFixture.Source)
    $canonicalConfig.source_identities.PSObject.Properties.Remove($canonicalFixture.Source)
    $canonicalConfig.source_identities | Add-Member -NotePropertyName $canonicalFixture.Source.ToLowerInvariant() -NotePropertyValue $canonicalIdentity
    Write-JsonFile -Path $canonicalFixture.ConfigPath -Value $canonicalConfig
    $canonicalRun = Invoke-Relocation -Fixture $canonicalFixture -Destination $canonicalFixture.NewRepository
    Assert-True ($canonicalRun.ExitCode -ne 0 -and $canonicalRun.Result.error -match 'exact canonical source path') 'non-canonical source identity key rejected'

    $overflowFixture = New-Fixture
    $overflowConfig = Get-Content -LiteralPath $overflowFixture.ConfigPath -Raw | ConvertFrom-Json
    $overflowConfig.config_generation = [long]::MaxValue
    Write-JsonFile -Path $overflowFixture.ConfigPath -Value $overflowConfig
    $overflowRun = Invoke-Relocation -Fixture $overflowFixture -Destination $overflowFixture.NewRepository
    Assert-True ($overflowRun.ExitCode -ne 0 -and $overflowRun.Result.error -match 'supported maximum') 'generation overflow rejected'

    # All five activation failure points roll back protected files and owned copies. Point 5 follows the rewrite of the
    # repository record.
    foreach ($point in 1..5) {
        $rollbackFixture = New-Fixture
        $configBefore = Get-Hash -Path $rollbackFixture.ConfigPath
        $manifestBefore = Get-Hash -Path $rollbackFixture.ManifestPath
        $recordHashBefore = Get-RecordHash -Fixture $rollbackFixture
        $repoBefore = Get-TreeDigest -Root $rollbackFixture.OldRepository -ExcludeLocks
        $recoveryBefore = Get-TreeDigest -Root $rollbackFixture.OldRecovery
        $rollbackRun = Invoke-Relocation -Fixture $rollbackFixture -Destination $rollbackFixture.NewRepository -FailurePoint $point
        Assert-True ($rollbackRun.ExitCode -ne 0 -and $rollbackRun.Result.ok -eq $false) "failure point $point reports failure"
        Assert-True ((Get-Hash -Path $rollbackFixture.ConfigPath) -eq $configBefore) "failure point $point restores config"
        Assert-True ((Get-Hash -Path $rollbackFixture.ManifestPath) -eq $manifestBefore) "failure point $point restores manifest"
        Assert-True ((Get-RecordHash -Fixture $rollbackFixture) -ceq $recordHashBefore) "failure point $point restores the repository record"
        Assert-True ((Get-TreeDigest -Root $rollbackFixture.OldRepository -ExcludeLocks) -eq $repoBefore) "failure point $point retains old repo"
        Assert-True ((Get-TreeDigest -Root $rollbackFixture.OldRecovery) -eq $recoveryBefore) "failure point $point retains old recovery"
        Assert-True (-not (Test-Path -LiteralPath $rollbackFixture.NewRepository)) "failure point $point removes owned destination"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackFixture.NewParent 'RecoveryTools'))) "failure point $point removes owned recovery"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $rollbackFixture.StateRoot 'repository-relocation.journal.json'))) "failure point $point clears journal after rollback"
    }

    # Existing-empty rollback restores the exact directory ACL and attributes.
    $emptyRollbackFixture = New-Fixture
    [void][IO.Directory]::CreateDirectory($emptyRollbackFixture.NewRepository)
    [IO.File]::SetAttributes($emptyRollbackFixture.NewRepository, [IO.FileAttributes]::Hidden)
    $emptySddl = (Get-Acl -LiteralPath $emptyRollbackFixture.NewRepository).GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::All)
    $emptyAttributes = [int](Get-Item -LiteralPath $emptyRollbackFixture.NewRepository -Force).Attributes
    $emptyRollbackRun = Invoke-Relocation -Fixture $emptyRollbackFixture -Destination $emptyRollbackFixture.NewRepository -FailurePoint 1
    Assert-True ($emptyRollbackRun.ExitCode -ne 0) 'existing-empty injected failure reports failure'
    Assert-True (Test-Path -LiteralPath $emptyRollbackFixture.NewRepository -PathType Container) 'existing-empty destination restored'
    Assert-True (@(Get-ChildItem -LiteralPath $emptyRollbackFixture.NewRepository -Force).Count -eq 0) 'restored existing destination remains empty'
    Assert-True ((Get-Acl -LiteralPath $emptyRollbackFixture.NewRepository).GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::All) -ceq $emptySddl) 'existing-empty ACL restored exactly'
    Assert-True ([int](Get-Item -LiteralPath $emptyRollbackFixture.NewRepository -Force).Attributes -eq $emptyAttributes) 'existing-empty attributes restored exactly'

    foreach ($emptyCrashPoint in 1..2) {
        $emptyCrashFixture = New-Fixture
        $emptyCrashRecovery = Join-Path $emptyCrashFixture.NewParent 'RecoveryTools'
        [void][IO.Directory]::CreateDirectory($emptyCrashFixture.NewRepository)
        [void][IO.Directory]::CreateDirectory($emptyCrashRecovery)
        [IO.File]::SetAttributes($emptyCrashFixture.NewRepository, [IO.FileAttributes]::Hidden)
        [IO.File]::SetAttributes($emptyCrashRecovery, [IO.FileAttributes]::Hidden)
        $repoEmptySddl = (Get-Acl -LiteralPath $emptyCrashFixture.NewRepository).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $recoveryEmptySddl = (Get-Acl -LiteralPath $emptyCrashRecovery).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        $repoEmptyAttributes = [int](Get-Item -LiteralPath $emptyCrashFixture.NewRepository -Force).Attributes
        $recoveryEmptyAttributes = [int](Get-Item -LiteralPath $emptyCrashRecovery -Force).Attributes
        $emptyCrashRun = Invoke-Relocation -Fixture $emptyCrashFixture -Destination $emptyCrashFixture.NewRepository `
            -CrashAfterEmptyDestinationRemoval $emptyCrashPoint
        Assert-True ($emptyCrashRun.ExitCode -ne 0) "empty-destination removal crash $emptyCrashPoint terminates"
        $emptyCrashRecoveryRun = Invoke-Recovery -Fixture $emptyCrashFixture
        Assert-True ($emptyCrashRecoveryRun.ExitCode -eq 0) "empty-destination removal crash $emptyCrashPoint recovers"
        Assert-True ((Get-Acl -LiteralPath $emptyCrashFixture.NewRepository).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All) -ceq $repoEmptySddl) "empty-destination removal crash $emptyCrashPoint restores repo ACL"
        Assert-True ((Get-Acl -LiteralPath $emptyCrashRecovery).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All) -ceq $recoveryEmptySddl) "empty-destination removal crash $emptyCrashPoint restores recovery ACL"
        Assert-True ([int](Get-Item -LiteralPath $emptyCrashFixture.NewRepository -Force).Attributes -eq $repoEmptyAttributes) "empty-destination removal crash $emptyCrashPoint restores repo attributes"
        Assert-True ([int](Get-Item -LiteralPath $emptyCrashRecovery -Force).Attributes -eq $recoveryEmptyAttributes) "empty-destination removal crash $emptyCrashPoint restores recovery attributes"
    }

    # Terminate the manager process across copy and all four publication states,
    # then prove the next protected invocation reconciles to OLD and unblocks retry.
    $crashCases = @(
        [pscustomobject]@{ Name='stage_repository_unmarked'; Publish=0; Copy=0; Stage=1 },
        [pscustomobject]@{ Name='stage_recovery_unmarked'; Publish=0; Copy=0; Stage=2 },
        [pscustomobject]@{ Name='copying'; Publish=0; Copy=1; Stage=0 },
        [pscustomobject]@{ Name='repository_promoted'; Publish=1; Copy=0; Stage=0 },
        [pscustomobject]@{ Name='recovery_promoted'; Publish=2; Copy=0; Stage=0 },
        [pscustomobject]@{ Name='config_published'; Publish=3; Copy=0; Stage=0 },
        [pscustomobject]@{ Name='manifest_published'; Publish=4; Copy=0; Stage=0 },
        [pscustomobject]@{ Name='repository_record_rewritten'; Publish=5; Copy=0; Stage=0 }
    )
    foreach ($case in $crashCases) {
        $crashFixture = New-Fixture
        $crashConfigBefore = Get-Hash -Path $crashFixture.ConfigPath
        $crashManifestBefore = Get-Hash -Path $crashFixture.ManifestPath
        $crashRecordBefore = Get-RecordHash -Fixture $crashFixture
        $crashRepoBefore = Get-TreeDigest -Root $crashFixture.OldRepository -ExcludeLocks
        $crashRecoveryBefore = Get-TreeDigest -Root $crashFixture.OldRecovery
        $crashStartedUtc = [DateTime]::UtcNow
        $crashRun = Invoke-Relocation -Fixture $crashFixture -Destination $crashFixture.NewRepository `
            -CrashPoint $case.Publish -CrashDuringCopyAfterFiles $case.Copy -CrashAfterStageCreation $case.Stage
        $crashEndedUtc = [DateTime]::UtcNow
        Assert-True ($crashRun.ExitCode -ne 0) "crash state $($case.Name) terminates process"
        Assert-True (Test-Path -LiteralPath (Join-Path $crashFixture.StateRoot 'repository-relocation.journal.json') -PathType Leaf) "crash state $($case.Name) leaves durable journal"
        # The journal names the process that ran the move, so a dashboard opened during a move can tell whether that
        # process is still running.
        $crashJournal = Get-Content -LiteralPath $crashFixture.JournalPath -Raw | ConvertFrom-Json
        $ownerProcessId = $crashJournal.PSObject.Properties['owner_process_id']
        $ownerCreation = $crashJournal.PSObject.Properties['owner_process_creation_filetime_utc']
        $ownerFileTime = 0L
        Assert-True ($null -ne $ownerProcessId -and $ownerProcessId.Value -is [int] -and
            [int]$ownerProcessId.Value -gt 0) "crash state $($case.Name) journal names the moving process"
        Assert-True ($null -ne $ownerCreation -and $ownerCreation.Value -is [string] -and
            [string]$ownerCreation.Value -cmatch '^[1-9][0-9]*$' -and
            [long]::TryParse([string]$ownerCreation.Value, [ref]$ownerFileTime) -and
            [DateTime]::FromFileTimeUtc($ownerFileTime) -ge $crashStartedUtc.AddSeconds(-1) -and
            [DateTime]::FromFileTimeUtc($ownerFileTime) -le $crashEndedUtc.AddSeconds(1)) "crash state $($case.Name) journal has the moving process's creation time"
        if ($case.Publish -eq 5) {
            $intendedRecord = $crashJournal.PSObject.Properties['intended_repository_record_sha256']
            Assert-True ((Get-RecordHash -Fixture $crashFixture) -cne $crashRecordBefore -and $null -ne $intendedRecord -and
                [string]$intendedRecord.Value -ceq (Get-RecordHash -Fixture $crashFixture)) "crash state $($case.Name) stopped after the journaled record rewrite"
        }
        $recoveryRun = Invoke-Recovery -Fixture $crashFixture
        Assert-True ($recoveryRun.ExitCode -eq 0 -and $recoveryRun.Result.ok -eq $true) "crash state $($case.Name) reconciles on dedicated recovery"
        Assert-True ([string]$recoveryRun.Result.action -eq 'recover') "crash state $($case.Name) recovery result action"
        Assert-True ([string]$recoveryRun.Result.expected_journal_sha256 -eq $recoveryRun.JournalHash) "crash state $($case.Name) recovery journal binding"
        Assert-True ([string]$recoveryRun.Result.old_repository -eq $crashFixture.OldRepository) "crash state $($case.Name) recovery old path"
        Assert-True ([string]$recoveryRun.Result.new_repository -eq $crashFixture.NewRepository) "crash state $($case.Name) recovery requested path"
        Assert-True ($recoveryRun.Result.old_repository_retained -eq $true) "crash state $($case.Name) recovery retention boolean"
        Assert-True ((Get-Hash -Path $crashFixture.ConfigPath) -eq $crashConfigBefore) "crash state $($case.Name) restores config"
        Assert-True ((Get-Hash -Path $crashFixture.ManifestPath) -eq $crashManifestBefore) "crash state $($case.Name) restores manifest"
        Assert-True ((Get-RecordHash -Fixture $crashFixture) -ceq $crashRecordBefore) "crash state $($case.Name) restores the repository record"
        Assert-True ((Get-TreeDigest -Root $crashFixture.OldRepository -ExcludeLocks) -eq $crashRepoBefore) "crash state $($case.Name) retains old repository"
        Assert-True ((Get-TreeDigest -Root $crashFixture.OldRecovery) -eq $crashRecoveryBefore) "crash state $($case.Name) retains old recovery"
        Assert-True (-not (Test-Path -LiteralPath $crashFixture.NewRepository)) "crash state $($case.Name) removes proven owned destination"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $crashFixture.NewParent 'RecoveryTools'))) "crash state $($case.Name) removes proven owned recovery"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $crashFixture.StateRoot 'repository-relocation.journal.json'))) "crash state $($case.Name) clears journal"
    }

    # Repair stops before it changes anything when the record of the backup location, or the record of the move, is not
    # what the move left behind. Trying again gives the same answer, so what the person reads must say, in plain words,
    # what is safe and where to get help.
    $refusedFixture = New-Fixture
    $refusedRecordBefore = Get-RecordHash -Fixture $refusedFixture
    $refusedCrash = Invoke-Relocation -Fixture $refusedFixture -Destination $refusedFixture.NewRepository -CrashPoint 5
    Assert-True ($refusedCrash.ExitCode -ne 0 -and (Test-Path -LiteralPath $refusedFixture.JournalPath -PathType Leaf)) 'refused repair fixture stops mid-move'
    [byte[]]$refusedJournalBytes = [IO.File]::ReadAllBytes($refusedFixture.JournalPath)
    $refusedJournalText = $encoding.GetString($refusedJournalBytes)
    [byte[]]$refusedRecordBytes = [IO.File]::ReadAllBytes($refusedFixture.RecordPath)
    $refusedConfigHash = Get-Hash -Path $refusedFixture.ConfigPath
    $refusedManifestHash = Get-Hash -Path $refusedFixture.ManifestPath
    $schemaTwoRecord = [Convert]::ToBase64String($encoding.GetBytes('{"schema_version":2}'))
    $refusedCases = @(
        [pscustomobject]@{ Name='record changed'; Reason="Rewindle's record of your backup location changed while the move was stopped"; Record='changed'; Field=$null; Value=$null },
        [pscustomobject]@{ Name='record missing'; Reason="Rewindle's record of your backup location is missing"; Record='missing'; Field=$null; Value=$null },
        [pscustomobject]@{ Name='saved record not readable'; Reason="Rewindle's record of the unfinished move is damaged"; Record=$null; Field='original_repository_record_base64'; Value='not base64!' },
        [pscustomobject]@{ Name='saved record of another kind'; Reason="Rewindle's record of the unfinished move is damaged"; Record=$null; Field='original_repository_record_base64'; Value=$schemaTwoRecord },
        [pscustomobject]@{ Name='rewrite fingerprint damaged'; Reason="Rewindle's record of the unfinished move is damaged"; Record=$null; Field='intended_repository_record_sha256'; Value='not-a-fingerprint' }
    )
    foreach ($case in $refusedCases) {
        $journalText = $refusedJournalText
        if ($null -ne $case.Field) {
            $journalText = [regex]::Replace($refusedJournalText, '("' + $case.Field + '"\s*:\s*)"[^"]*"', ('${1}"' + $case.Value + '"'))
            Assert-True ($journalText -cne $refusedJournalText) "refused repair ($($case.Name)) fixture changes the saved field"
            [IO.File]::WriteAllText($refusedFixture.JournalPath, $journalText, $encoding)
        }
        if ($case.Record -eq 'changed') { [IO.File]::WriteAllText($refusedFixture.RecordPath, "{`"schema_version`": 1}`n", $encoding) }
        if ($case.Record -eq 'missing') { [IO.File]::Delete($refusedFixture.RecordPath) }
        $recordBeforeAttempt = Get-RecordHash -Fixture $refusedFixture
        $refusedRun = Invoke-Recovery -Fixture $refusedFixture
        $refusedText = if ($null -eq $refusedRun.Result) { '' } else { [string]$refusedRun.Result.error }
        Assert-True ($refusedRun.ExitCode -ne 0 -and $null -ne $refusedRun.Result -and $refusedRun.Result.ok -eq $false) "refused repair ($($case.Name)) stops"
        Assert-True ($refusedText.StartsWith($case.Reason, [StringComparison]::Ordinal)) "refused repair ($($case.Name)) says why: $refusedText"
        Assert-True ($refusedText -notmatch '(?i)repositor|journal|relocat|metadata|snapshot|restic|engine|canary') "refused repair ($($case.Name)) uses plain words: $refusedText"
        Assert-True ($refusedText.EndsWith("It stopped before changing anything, and your backups were not touched. Choose Save problem report in Settings and ask for help; don't delete anything in the backup location.", [StringComparison]::Ordinal)) "refused repair ($($case.Name)) names a next step that can help: $refusedText"
        Assert-True ((Get-Hash -Path $refusedFixture.ConfigPath) -eq $refusedConfigHash -and
            (Get-Hash -Path $refusedFixture.ManifestPath) -eq $refusedManifestHash -and
            (Get-RecordHash -Fixture $refusedFixture) -ceq $recordBeforeAttempt -and
            $encoding.GetString([IO.File]::ReadAllBytes($refusedFixture.JournalPath)) -ceq $journalText) "refused repair ($($case.Name)) changes nothing"
        [IO.File]::WriteAllBytes($refusedFixture.JournalPath, $refusedJournalBytes)
        [IO.File]::WriteAllBytes($refusedFixture.RecordPath, $refusedRecordBytes)
    }
    $acceptedRepair = Invoke-Recovery -Fixture $refusedFixture
    Assert-True ($acceptedRepair.ExitCode -eq 0 -and $acceptedRepair.Result.ok -eq $true -and
        (Get-RecordHash -Fixture $refusedFixture) -ceq $refusedRecordBefore) 'refused repairs leave the move repairable'

    $managerText = Get-Content -LiteralPath $managerSource -Raw
    Assert-True ($managerText -match 'New-RepositoryStagingDirectory -Path \$repositoryStage -StorageMode \$destinationStorageMode') 'repository staging uses storage-mode-specific protection contract'
    Assert-True ($managerText -match 'New-ProtectedStagingDirectory -Path \$recoveryStage') 'recovery staging protected before copy contract'
    Assert-True ($managerText -match '(?s)Assert-ActivationTrees.+?-Repository \$canonicalNew') 'final trees revalidated before metadata switch contract'
    Assert-True ($managerText -match "'S-1-5-32-544'") 'Administrators ACL policy present'
    Assert-True ($managerText -match "'S-1-5-18'") 'SYSTEM ACL policy present'
    Assert-True ($managerText -match 'ReadAndExecute') 'normal-user read-only ACL policy present'
    Assert-True ($managerText -match 'GoogleDriveFS' -and $managerText -match 'drivefs_cache_directory') 'DriveFS provider and cache gates present'
    Assert-True ($managerText -match 'MaximumBytes -ge \$driveFsObjectLimitBytes') 'DriveFS 4 GiB object gate present'
    Assert-True ($managerText -match 'repository_manifest_sha256' -and $managerText -match 'Assert-TreeMatchesInventory') 'repository commit manifest verification present'
    Assert-True ($managerText -notmatch 'Move-Item[^\n]*\$(repositoryStage|recoveryStage)') 'stages are never renamed by path'
    Assert-True ($managerText -match 'Move-PinnedDirectory -Pin \$repositoryStagePin -Destination \$canonicalNew' -and
        $managerText -match 'Move-PinnedDirectory -Pin \$recoveryStagePin -Destination \$newRecovery') 'stages renamed through their held handle'
    $pinAccess = [regex]::Match($managerText, '(?m)^\$stagePinAccess = 0x([0-9A-Fa-f]+)')
    $pinShare = [regex]::Match($managerText, '(?m)^\$stagePinShare = 0x([0-9A-Fa-f]+)')
    Assert-True ($pinAccess.Success -and ([Convert]::ToInt64($pinAccess.Groups[1].Value, 16) -band 0x10000) -eq 0 -and
        ([Convert]::ToInt64($pinAccess.Groups[1].Value, 16) -band 0x1) -ne 0) 'the hold lists the folder and never asks for delete access'
    Assert-True ($pinShare.Success -and ([Convert]::ToInt64($pinShare.Groups[1].Value, 16) -band 0x4) -eq 0) 'the hold never shares delete'
    Assert-True ($managerText -match 'Get-TreeInventory -Root \$validated\.Repository -ResticLayout Skip') 'only Restic files are read from the current backup folder'
    # Once a stage has its final name nothing that can fail runs before the caller marks it promoted, so a failure there
    # can never leave a promoted copy that rollback does not know about.
    $moveBody = [regex]::Match($managerText, '(?s)\nfunction Move-PinnedDirectory \{(.+?)\n\}').Groups[1].Value
    $renameAt = $moveBody.IndexOf('SetFileInformationByHandle(')
    $afterRename = if ($renameAt -lt 0) { '' } else {
        @($moveBody.Substring($renameAt).Split("`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    }
    Assert-True ($renameAt -ge 0 -and $afterRename -notmatch 'Get-DirectoryHandleIdentity|Assert-|Open-' -and
        $afterRename -match 'return \$identity') 'a renamed stage is returned without another check that could fail'
    Assert-True ($managerText -match '(?s)\nfunction Assert-ReadyDriveFsDestination \{(?:(?!\nfunction ).)+?\n    Assert-DriveFsFolderHold -Directory') 'Google Drive moves check held folders before they start'
    # Outside test mode the rewritten record gets the installer's owner and inherited permissions; that needs elevation,
    # so only the source can be checked here.
    Assert-True ($managerText -match '(?s)function Set-RepositoryRecordBytes \{.+?Set-AtomicFileBytes -Target \$repositoryRecordPath.+?if \(\$isTestMode\) \{ return \}.+?/reset /C /L.+?/setowner ''\*S-1-5-32-544'' /C /L.+?AreAccessRulesProtected.+?GetAccessRules\(\$true, \$false') 'repository record gets the installer owner and inherited permissions'
    # The same goes for what the person reads when that step fails (on a move, its undo or a repair): plain words and a
    # next step. An undo that fails names the record in plain words too.
    $recordWriter = [regex]::Match($managerText, '(?s)\nfunction Set-RepositoryRecordBytes \{.+?\n\}\n').Value
    $recordWriterTexts = @([regex]::Matches($recordWriter, 'throw "([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($recordWriter.Contains("`$tryAgain = 'Try again. If it keeps failing, choose Save problem report in Settings and ask for help.'")) 'record permission failures name a next step'
    Assert-True ($recordWriterTexts.Count -eq 3 -and @($recordWriterTexts | Where-Object {
        -not $_.EndsWith(' $tryAgain', [StringComparison]::Ordinal) -or $_ -match '(?i)repositor|journal|relocat|metadata|icacls'
    }).Count -eq 0) "record permission failures use plain words and end with the next step: $($recordWriterTexts -join ' | ')"
    Assert-True ($managerText.Contains('$rollbackErrors.Add("backup location record: ') -and
        -not $managerText.Contains('$rollbackErrors.Add("repository record: ')) 'a failed undo names the backup location record in plain words'
    # Those permissions, and the held copy folders' own, are set by running System32's icacls.exe as administrator, and only
    # once Microsoft itself has signed it: the installer's rule (Get-MicrosoftSignerProblem), not a signer name that merely
    # contains "Microsoft". The rule gets made-up facts here, and Get-TrustedIcacls gets Windows' answer about the file
    # replaced by a certificate made in memory and never stored. Nothing runs icacls.
    & {
        $signerAst = [Management.Automation.Language.Parser]::ParseFile($managerSource, [ref]$null, [ref]$null)
        $signerFunctions = @($signerAst.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $_.Name -in @('Assert-NormalFile', 'Get-MicrosoftSignerProblem', 'Get-AuthenticodeSignerFacts', 'Get-TrustedIcacls')
            })
        Assert-True ($signerFunctions.Count -eq 4) "the manager defines the installer's signer rule and Get-TrustedIcacls once each (got: $(@($signerFunctions | ForEach-Object { $_.Name }) -join ', '))"
        foreach ($definition in $signerFunctions) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $leaf = '1111111111111111111111111111111111111111'
        $intermediate = '2222222222222222222222222222222222222222'
        $windowsSubject = "C=US`r`nS=Washington`r`nL=Redmond`r`nO=Microsoft Corporation`r`nCN=Microsoft Windows"
        foreach ($case in @(
                @{ Label = 'Microsoft Corporation through Microsoft Root Certificate Authority 2010'; Pass = $true; Root = '3B1EFD3A66EA28B16697394703A72CA340A05BD5' },
                @{ Label = 'Microsoft Corporation through Microsoft Root Certificate Authority 2011'; Pass = $true; Root = '8F43288AD272F3103B6FB1428485EA3014C0BCFE' },
                @{ Label = 'a file Windows reports as its own, without its chain'; Pass = $true; OSBinary = $true; Chain = @(); ChainValid = $false },
                @{ Label = 'an organization that merely contains Microsoft'; Pass = $false; OSBinary = $true; Subject = "C=US`r`nO=Contoso Microsoftware Ltd`r`nCN=Microsoft Corporation" },
                @{ Label = 'Microsoft Corporation in the common name only'; Pass = $false; OSBinary = $true; Subject = "C=US`r`nO=Contoso Ltd`r`nCN=Microsoft Corporation" },
                @{ Label = 'Microsoft Corporation and a second organization'; Pass = $false; Subject = "O=Microsoft Corporation`r`nCN=x + O=Contoso Ltd" },
                @{ Label = "Microsoft's root for other publishers"; Pass = $false; Root = 'F40042E2E5F7E8EF8189FED15519AECE42C3BFA2' },
                @{ Label = 'a chain that did not validate'; Pass = $false; ChainValid = $false },
                @{ Label = 'a signature that is not valid'; Pass = $false; OSBinary = $true; Status = 'NotTrusted' }
            )) {
            $root = if ($case.ContainsKey('Root')) { $case.Root } else { '8F43288AD272F3103B6FB1428485EA3014C0BCFE' }
            $problem = Get-MicrosoftSignerProblem `
                -Status $(if ($case.ContainsKey('Status')) { $case.Status } else { 'Valid' }) `
                -Subject $(if ($case.ContainsKey('Subject')) { $case.Subject } else { $windowsSubject }) `
                -ChainThumbprints $(if ($case.ContainsKey('Chain')) { $case.Chain } else { @($leaf, $intermediate, $root) }) `
                -ChainValid $(if ($case.ContainsKey('ChainValid')) { $case.ChainValid } else { $true }) `
                -IsOSBinary $($case.ContainsKey('OSBinary') -and $case.OSBinary)
            if ($case.Pass) { Assert-True ($null -eq $problem) "the icacls signer rule passes $($case.Label) (got: $problem)" }
            else { Assert-True (-not [string]::IsNullOrEmpty($problem)) "the icacls signer rule refuses $($case.Label)" }
        }
        $systemIcacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
        foreach ($case in @(
                @{ Label = 'a valid signature by a publisher with Microsoft in its name, even one Windows calls its own'; Subject = 'CN=Microsoft Corporation, O=Contoso Microsoft Fans Ltd, C=US'; OSBinary = $true; Pass = $false },
                @{ Label = "a valid signature named Microsoft Corporation that doesn't lead to Microsoft's root"; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'; OSBinary = $false; Pass = $false },
                @{ Label = 'a file Windows reports as its own, signed by Microsoft Corporation'; Subject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'; OSBinary = $true; Pass = $true }
            )) {
            $key = [Security.Cryptography.RSA]::Create(2048)
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($case.Subject, $key,
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $fixtureSignature = [pscustomobject]@{
                Status = 'Valid'
                SignatureType = 'Authenticode'
                SignerCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
                IsOSBinary = $case.OSBinary
            }
            $answer = & {
                function Get-AuthenticodeSignature { param([string]$LiteralPath) return $fixtureSignature }
                try { 'returned ' + (Get-TrustedIcacls) } catch { 'refused: ' + $_.Exception.Message }
            }
            if ($case.Pass) {
                Assert-True ($answer -ceq "returned $systemIcacls") "Get-TrustedIcacls accepts $($case.Label) (got: $answer)"
            }
            else {
                Assert-True ($answer.StartsWith("refused: Windows' permissions tool didn't pass Microsoft's signature check (", [StringComparison]::Ordinal) -and
                    $answer.EndsWith(' Choose Save problem report in Settings and ask for help.', [StringComparison]::Ordinal)) "Get-TrustedIcacls refuses $($case.Label) in plain words with a next step (got: $answer)"
            }
        }
        Assert-True ((Get-TrustedIcacls) -ceq $systemIcacls) "System32's own icacls.exe passes with Windows' real answer"
    }
    $builderText = Get-Content -LiteralPath (Join-Path $projectRoot 'build\Build-Release.ps1') -Raw
    $installerText = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Install-ResticBackuper.ps1') -Raw
    $commonText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\restic_common.py') -Raw
    Assert-True ($builderText -match "'Manage-Repository\.ps1'") 'release builder packages repository manager'
    Assert-True ($installerText -match "'Manage-Repository\.ps1'") 'installer requires repository manager payload'
    Assert-True ($commonText -match 'repository-relocation\.journal\.json' -and $commonText -match 'pending protected-operation journal') 'Python backup loader blocks pending relocation journal'

    # Failed Restic check never activates the copy.
    $checkFixture = New-Fixture
    [IO.File]::WriteAllText((Join-Path $checkFixture.Root 'fake-restic-fail-check'), "fail`n", $encoding)
    $checkRun = Invoke-Relocation -Fixture $checkFixture -Destination $checkFixture.NewRepository
    Assert-True ($checkRun.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $checkFixture.NewRepository)) 'failed check prevents activation'
    Assert-True ([string]$checkRun.Result.error -match 'exit code 17') 'failed check is the reason the move stopped'
    Assert-True ((Get-Content -LiteralPath $checkFixture.ConfigPath -Raw | ConvertFrom-Json).repository -eq $checkFixture.OldRepository) 'failed check preserves config'

    # Shared lock excludes relocation, and pending journals independently block the Python backup loader.
    $lockFixture = New-Fixture
    $lockStream = [IO.File]::Open((Join-Path $lockFixture.StateRoot 'run.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $lockStream.Lock(0, 1)
        $lockRun = Invoke-Relocation -Fixture $lockFixture -Destination $lockFixture.NewRepository
    }
    finally { try { $lockStream.Unlock(0, 1) } finally { $lockStream.Dispose() } }
    Assert-True ($lockRun.ExitCode -ne 0 -and $lockRun.Result.error -match 'run lock') 'shared run lock enforced'

    $journalFixture = New-Fixture
    [IO.File]::WriteAllText((Join-Path $journalFixture.StateRoot 'repository-relocation.journal.json'), "{}`n", $encoding)
    $probe = @'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from restic_common import load_config_under_lock
try:
    load_config_under_lock(Path(sys.argv[2]))
except RuntimeError as error:
    if "pending protected-operation journal" in str(error):
        raise SystemExit(0)
    print(error)
    raise SystemExit(3)
raise SystemExit(4)
'@
    $probeOutput = $probe | & $python - (Join-Path $projectRoot 'src') $journalFixture.ConfigPath 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'pending journal blocks backup config loading'

    # The manager runs elevated with the requesting account's own %TEMP%, which its unelevated programs can change, so its
    # native call is emitted in memory, never compiled through files there. A child process with TEMP and TMP pointed at an
    # empty, watched folder defines every manager function, reads a volume's details, and reports what appeared there.
    $nativeRoot = Join-Path ([IO.Path]::GetTempPath()) ('RRM-T-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $fixtureRoots.Add($nativeRoot)
    $watchedTemp = Join-Path $nativeRoot 'watched-temp'
    [void][IO.Directory]::CreateDirectory($watchedTemp)
    $usedLetters = @([Environment]::GetLogicalDrives() | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() })
    $unusedLetter = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') | Where-Object { $usedLetters -notcontains $_ } | Select-Object -First 1
    Assert-True ($null -ne $unusedLetter) 'a drive letter nobody uses is found for the error check'
    $nativeProbe = Join-Path $nativeRoot 'native-probe.ps1'
    [IO.File]::WriteAllText($nativeProbe, @'
param([string]$Manager, [string]$Watched, [string]$Folder, [string]$UnusedRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$created = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$watcher = [IO.FileSystemWatcher]::new($Watched)
$watcher.IncludeSubdirectories = $true
$null = Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $created -Action { $Event.MessageData.Enqueue($EventArgs.Name) }
$watcher.EnableRaisingEvents = $true
$ast = [Management.Automation.Language.Parser]::ParseFile($Manager, [ref]$null, [ref]$null)
foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$script:repositoryNative = $null
function Get-ProbeValue {
    param([scriptblock]$Probe)
    try { & $Probe } catch { 'error: ' + $_.Exception.Message }
}
$result = [ordered]@{}
$result.serial = Get-ProbeValue { Get-VolumeSerial -Path $Folder }
$result.metadata = Get-ProbeValue {
    $metadata = Get-VolumeMetadata -Path $Folder
    [ordered]@{ serial = $metadata.Serial; file_system = $metadata.FileSystem; maximum = $metadata.MaximumComponentLength; flags = $metadata.Flags }
}
$result.unused_drive_error = Get-ProbeValue {
    try { [void](Get-VolumeDetails -Root $UnusedRoot); 'succeeded' }
    catch [ComponentModel.Win32Exception] { $_.Exception.NativeErrorCode }
}
$result.set_last_error = Get-ProbeValue {
    $import = @((Get-RepositoryNativeMethods).GetMethod('GetVolumeInformationW').GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false))[0]
    $import.Value -eq 'kernel32.dll' -and $import.SetLastError -and $import.EntryPoint -ceq 'GetVolumeInformationW'
}
Start-Sleep -Milliseconds 500
$watcher.EnableRaisingEvents = $false
$names = [Collections.Generic.List[string]]::new()
$item = $null
while ($created.TryDequeue([ref]$item)) { $names.Add($item) }
$result.created_in_temp = @($names)
ConvertTo-Json -InputObject $result -Depth 4 -Compress
'@, $encoding)
    $probeStart = [Diagnostics.ProcessStartInfo]::new($powershell)
    $probeArguments = @($nativeProbe, $managerSource, $watchedTemp, $nativeRoot, $unusedLetter)
    $probeStart.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Manager "{1}" -Watched "{2}" -Folder "{3}" -UnusedRoot {4}:\' -f $probeArguments
    $probeStart.UseShellExecute = $false
    $probeStart.RedirectStandardOutput = $true
    $probeStart.RedirectStandardError = $true
    $probeStart.CreateNoWindow = $true
    $probeStart.EnvironmentVariables['TEMP'] = $watchedTemp
    $probeStart.EnvironmentVariables['TMP'] = $watchedTemp
    $probeProcess = [Diagnostics.Process]::Start($probeStart)
    $probeError = $probeProcess.StandardError.ReadToEndAsync()
    $probeText = $probeProcess.StandardOutput.ReadToEnd()
    $probeProcess.WaitForExit()
    Assert-True ($probeProcess.ExitCode -eq 0) "the native-call probe ran (stderr: $($probeError.Result))"
    $nativeResult = $probeText | ConvertFrom-Json
    Assert-True (@($nativeResult.created_in_temp).Count -eq 0) "reading volume details created nothing in %TEMP% (a compiler would leave its .cs, .cmdline and .dll files there; got: $(@($nativeResult.created_in_temp) -join ', '))"
    $referenceSerial = Get-VolumeSerial -Path $nativeRoot
    Assert-True ([string]$nativeResult.serial -ceq $referenceSerial) 'the manager reads the volume serial'
    Assert-True ($nativeResult.metadata -isnot [string]) 'the manager reads the volume metadata'
    Assert-True ([string]$nativeResult.metadata.serial -ceq $referenceSerial) 'the volume metadata carries the same serial'
    Assert-True ([string]$nativeResult.metadata.file_system -eq ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($nativeRoot))).DriveFormat) 'the volume metadata names the file system'
    Assert-True ([long]$nativeResult.metadata.maximum -gt 0 -and [long]$nativeResult.metadata.flags -ne 0) 'the volume metadata carries the longest name and the file-system flags'
    Assert-True (@(3, 15) -contains $nativeResult.unused_drive_error) "an unused drive letter fails with Windows' own error, so SetLastError is set (got: $($nativeResult.unused_drive_error))"
    Assert-True ($nativeResult.set_last_error -eq $true) 'the emitted call imports kernel32 by its exact name with SetLastError'

    $productionCheck = 'skipped'
    if (-not $SkipInstalledChecks) {
        $productionHashAfter = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
        $taskXmlAfter = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }
        Assert-True ($productionHashAfter -eq $productionHashBefore) 'production protected config untouched'
        Assert-True ($taskXmlAfter -ceq $taskXmlBefore) 'production scheduled task untouched'
        $productionCheck = 'passed'
    }

    [ordered]@{
        test = 'Manage-Repository'
        assertions = $assertions
        disposable_roots = $fixtureRoots.Count
        success_copy_and_verify = 'passed'
        empty_destination = 'passed'
        password_command_and_allow_listed_environment = 'passed'
        repository_record_follows_the_move = 'passed'
        unsafe_destinations_and_capacity = 'passed'
        activation_rollback_points = 5
        abrupt_termination_recovery_states = $crashCases.Count
        refused_repairs_in_plain_words = $refusedCases.Count
        empty_destination_removal_crash_states = 2
        existing_empty_acl_and_attributes_restored = 'passed'
        protected_staging_and_activation_acl_contract = 'passed'
        drivefs_staging_manifest_and_ntfs_recovery = 'passed'
        drivefs_crash_recovery = 'passed'
        installer_style_canary_state_exception = 'passed'
        pending_journal_backup_gate = 'passed'
        native_call_compiles_nothing = 'passed'
        fake_restic_no_backup_or_init = 'passed'
        old_repository_retention = 'passed'
        only_restic_files_copied = 'passed'
        stages_held_during_copy = 'passed'
        icacls_signed_by_microsoft_itself = 'passed'
        production_config_untouched = $productionCheck
        production_task_untouched = $productionCheck
    } | ConvertTo-Json -Compress
}
finally {
    foreach ($name in $leakedVariables.Keys) {
        [Environment]::SetEnvironmentVariable($name, $priorVariables[$name], 'Process')
    }
    # A junction the swap test planted goes first, on its own, so removing the fixture never reaches through it.
    foreach ($link in $plantedLinks) {
        if ([IO.Directory]::Exists($link) -and ([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint)) {
            [IO.Directory]::Delete($link, $false)
        }
    }
    foreach ($root in $fixtureRoots) {
        if (Test-Path -LiteralPath $root) {
            $full = [IO.Path]::GetFullPath($root)
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            # Only roots this run made are listed. Both prefixes are this suite's: 'RRM T-' for fixtures (with the
            # space) and 'RRM-T-' for any root made without one.
            $rootName = [IO.Path]::GetFileName($full)
            if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
                ($rootName.StartsWith('RRM T-', [StringComparison]::Ordinal) -or
                    $rootName.StartsWith('RRM-T-', [StringComparison]::Ordinal))) {
                Remove-Item -LiteralPath $full -Recurse -Force
            }
        }
    }
    if (Test-Path -LiteralPath $compilerRoot) { Remove-Item -LiteralPath $compilerRoot -Recurse -Force }
}
