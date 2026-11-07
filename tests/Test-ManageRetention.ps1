param(
    # Never look at the installed configuration, even to prove it was left alone. Every check below runs in disposable
    # folders either way; this only drops the before/after comparison with the real installation.
    [switch]$SkipInstalledChecks
)

# Clean-up of old backups through the protected manager (src\Manage-Retention.ps1), in disposable folders below the
# user's temporary folder, with a stand-in restic.exe that keeps its backups in a text file and logs every call.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$managerSource = Join-Path $projectRoot 'src\Manage-Retention.ps1'
$realPython = (Get-Command python -ErrorAction Stop).Source
$powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$encoding = [Text.UTF8Encoding]::new($false)
$planId = '12345678-1234-4abc-8def-1234567890ab'
$generation = [long]7
$repositoryId = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
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

function Get-SnapshotId {
    param([int]$Index)
    return ('{0:x2}' -f $Index) * 32
}

function Get-VolumeSerial {
    param([string]$Path)
    if (-not ('RetentionManagerTests.Volume' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RetentionManagerTests {
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
    return [RetentionManagerTests.Volume]::Serial([IO.Path]::GetPathRoot($Path))
}

$compilerRoot = Join-Path ([IO.Path]::GetTempPath()) ('RSRT-C-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($compilerRoot)
$fakeRestic = Join-Path $compilerRoot 'restic.exe'
# The stand-in keeps one backup per line of its store file: ID, time, and the keep reasons Restic would give it (none:
# Restic would remove it). Every call is logged; a read-only call without --no-lock, or any other command, fails.
$fakeResticSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
public static class FakeRestic {
  static string Escape(string value) {
    return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
  }
  static string Control(string name) {
    string path = @"__FAKE_RESTIC_CONTROL__";
    if (!File.Exists(path)) return null;
    foreach (string line in File.ReadAllLines(path)) {
      int separator = line.IndexOf('=');
      if (separator > 0 && line.Substring(0, separator) == name) return line.Substring(separator + 1);
    }
    return null;
  }
  static int Code(string name) {
    string value = Control(name);
    return String.IsNullOrEmpty(value) ? 0 : Int32.Parse(value);
  }
  static string Snapshot(string[] fields, string plan, string source) {
    return "{\"id\":\"" + fields[0] + "\",\"short_id\":\"" + fields[0].Substring(0, 8) + "\",\"time\":\"" + fields[1] +
      "\",\"hostname\":\"FIXTURE\",\"tags\":[\"scheduled\",\"restic-backuper-plan:" + plan +
      "\",\"restic-backuper-generation:7\"],\"paths\":[\"" + Escape(source) + "\"],\"summary\":{\"total_files_processed\":2}}";
  }
  public static int Main(string[] args) {
    foreach (System.Collections.DictionaryEntry item in Environment.GetEnvironmentVariables()) {
      string name = ((string)item.Key).ToUpperInvariant();
      if (name.StartsWith("RCLONE_") || name == "RESTIC_PASSWORD_COMMAND" || name == "RESTIC_PASSWORD_FILE" || name == "RESTIC_REPOSITORY_FILE") {
        Console.Error.WriteLine("inherited " + name); return 92;
      }
    }
    string log = Control("FAKE_RESTIC_LOG");
    if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, String.Join("\t", args) + Environment.NewLine);
    string plan = Control("FAKE_PLAN_ID");
    string source = Control("FAKE_SOURCE");
    string storePath = Control("FAKE_STORE");
    List<string[]> store = new List<string[]>();
    foreach (string line in File.ReadAllLines(storePath)) if (line.Length > 0) store.Add(line.Split('\t'));
    bool noLock = args.Contains("--no-lock");
    if (args.Contains("cat") && args.Contains("config")) {
      if (!noLock) { Console.Error.WriteLine("a read took the lock"); return 94; }
      Console.WriteLine("{\"id\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\",\"version\":2}"); return 0;
    }
    if (args.Contains("snapshots")) {
      if (!noLock) { Console.Error.WriteLine("a read took the lock"); return 94; }
      if (Code("FAKE_SNAPSHOTS_CODE") != 0 && File.Exists(log) &&
          File.ReadAllLines(log).Any(line => line.Contains("\tforget\t") && !line.Contains("--dry-run"))) {
        return Code("FAKE_SNAPSHOTS_CODE");
      }
      Console.WriteLine("[" + String.Join(",", store.Select(fields => Snapshot(fields, plan, source)).ToArray()) + "]"); return 0;
    }
    if (args.Contains("forget") && args.Contains("--dry-run")) {
      if (!noLock) { Console.Error.WriteLine("a dry run took the lock"); return 94; }
      List<string[]> keep = store.Where(fields => fields.Length > 2 && fields[2].Length > 0).OrderByDescending(fields => fields[1]).ToList();
      List<string[]> remove = store.Where(fields => fields.Length < 3 || fields[2].Length == 0).OrderByDescending(fields => fields[1]).ToList();
      StringBuilder reasons = new StringBuilder();
      foreach (string[] fields in keep) {
        if (reasons.Length > 0) reasons.Append(",");
        reasons.Append("{\"snapshot\":" + Snapshot(fields, plan, source) + ",\"matches\":[" +
          String.Join(",", fields[2].Split('|').Select(match => "\"" + match + "\"").ToArray()) + "],\"counters\":{}}");
      }
      Console.WriteLine("[{\"tags\":null,\"host\":\"FIXTURE\",\"paths\":[\"" + Escape(source) + "\"],\"keep\":[" +
        String.Join(",", keep.Select(fields => Snapshot(fields, plan, source)).ToArray()) + "],\"remove\":" +
        (remove.Count == 0 ? "null" : "[" + String.Join(",", remove.Select(fields => Snapshot(fields, plan, source)).ToArray()) + "]") +
        ",\"reasons\":[" + reasons.ToString() + "]}]");
      return 0;
    }
    if (args.Contains("forget")) {
      if (noLock) { Console.Error.WriteLine("a removal without the lock"); return 95; }
      if (args.Any(value => value.StartsWith("--keep") || value == "--prune")) { Console.Error.WriteLine("keep rules on a removal"); return 96; }
      int batch = File.Exists(storePath + ".batches") ? Int32.Parse(File.ReadAllText(storePath + ".batches")) + 1 : 1;
      File.WriteAllText(storePath + ".batches", batch.ToString());
      if (Code("FAKE_FAIL_BATCH") == batch) return 1;
      int index = Array.IndexOf(args, "forget");
      HashSet<string> ids = new HashSet<string>(args.Skip(index + 1));
      File.WriteAllLines(storePath, store.Where(fields => !ids.Contains(fields[0])).Select(fields => String.Join("\t", fields)).ToArray());
      return 0;
    }
    if (args.Contains("prune")) {
      if (noLock) return 95;
      return Code("FAKE_PRUNE_CODE");
    }
    if (args.Contains("check")) {
      if (noLock) return 95;
      return Code("FAKE_CHECK_CODE");
    }
    Console.Error.WriteLine("forbidden fake Restic command"); return 91;
  }
}
'@
$fakeResticControl = Join-Path $compilerRoot 'fake-restic-control.txt'
$fakeResticSource = $fakeResticSource.Replace('__FAKE_RESTIC_CONTROL__', $fakeResticControl)
Add-Type -TypeDefinition $fakeResticSource -OutputAssembly $fakeRestic -OutputType ConsoleApplication

function Write-FakeResticControl {
    # retention.py gives Restic an allow-listed environment, so the fixture settings reach the stand-in through a file.
    param([pscustomobject]$Fixture, [hashtable]$Settings = @{})
    $values = [ordered]@{
        FAKE_RESTIC_LOG = $Fixture.Log; FAKE_PLAN_ID = $planId; FAKE_SOURCE = $Fixture.Source; FAKE_STORE = $Fixture.Store
    }
    foreach ($name in $Settings.Keys) { $values[$name] = [string]$Settings[$name] }
    $lines = @(foreach ($name in $values.Keys) { $name + '=' + $values[$name] })
    [IO.File]::WriteAllLines($fakeResticControl, [string[]]$lines, $encoding)
}

$pythonWrapper = Join-Path $compilerRoot 'python.exe'
$escapedPython = $realPython.Replace('\', '\\').Replace('"', '\"')
$fakePythonControl = Join-Path $compilerRoot 'fake-python-control.txt'
# Manage-Retention starts retention.py with an allow-listed environment. The stand-in refuses (exit 93) any other variable.
# Its control file can make one step hang (with a child process of its own, as Restic would be), print something that is
# not JSON, or turn the progress file into a folder after the step, so that the next progress write fails.
$pythonWrapperSource = @"
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Text;
public static class PythonWrapper {
  static string Control(string name) {
    string path = @"__FAKE_PYTHON_CONTROL__";
    if (!File.Exists(path)) return null;
    foreach (string line in File.ReadAllLines(path)) {
      int separator = line.IndexOf('=');
      if (separator > 0 && line.Substring(0, separator) == name) return line.Substring(separator + 1);
    }
    return null;
  }
  static string Argument(string[] args, string name) {
    int index = Array.IndexOf(args, name);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
  }
  static readonly string[] Allowed = {
    "SystemRoot", "windir", "SystemDrive", "ComSpec", "PATH", "PATHEXT", "OS", "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE", "TEMP", "TMP"
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
    foreach (DictionaryEntry item in Environment.GetEnvironmentVariables()) {
      string name = (string)item.Key;
      if (Array.IndexOf(Allowed, name) < 0) { Console.Error.WriteLine("inherited " + name); return 93; }
    }
    string step = Argument(args, "--step");
    if (step != null && step == Control("GARBLE_STEP")) { Console.Out.Write("this is not JSON"); return 0; }
    if (step != null && step == Control("HANG_STEP")) {
      ProcessStartInfo sleeper = new ProcessStartInfo(); sleeper.FileName = "$escapedPython";
      sleeper.Arguments = "-I -c \"import time; time.sleep(600)\""; sleeper.UseShellExecute = false;
      using (Process child = Process.Start(sleeper)) {
        File.WriteAllText(Control("PID_FILE"), Process.GetCurrentProcess().Id.ToString() + " " + child.Id.ToString());
        child.WaitForExit();
      }
      return 0;
    }
    ProcessStartInfo start = new ProcessStartInfo(); start.FileName = "$escapedPython";
    start.Arguments = String.Join(" ", Array.ConvertAll(args, Quote)); start.UseShellExecute = false;
    int exitCode;
    using (Process process = Process.Start(start)) { process.WaitForExit(); exitCode = process.ExitCode; }
    if (step != null && step == Control("BLOCK_PROGRESS_AFTER")) {
      string progress = Path.Combine(Control("RESULT_ROOT"), Argument(args, "--request-nonce") + ".json.progress.json");
      if (File.Exists(progress)) File.Delete(progress);
      Directory.CreateDirectory(progress);
    }
    return exitCode;
  }
}
"@
$pythonWrapperSource = $pythonWrapperSource.Replace('__FAKE_PYTHON_CONTROL__', $fakePythonControl)
Add-Type -TypeDefinition $pythonWrapperSource -OutputAssembly $pythonWrapper -OutputType ConsoleApplication

function Write-BackupLog {
    # A verified backup run's own log, as backup.py writes it, in the protected logs folder.
    param([pscustomobject]$Fixture, [int]$Index, [string]$Utc, [string]$Status = 'clear', [switch]$Hold)
    $runId = '20260901T{0:000000}-{1:x8}' -f $Index, $Index
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add((@{ wrapper_event = 'backup_started'; run_id = $runId } | ConvertTo-Json -Compress))
    if ($Hold) { $lines.Add((@{ wrapper_event = 'change_anomaly_hold'; run_id = $runId } | ConvertTo-Json -Compress)) }
    $lines.Add(([ordered]@{
        wrapper_event = 'backup_verified'; run_id = $runId; snapshot_id = (Get-SnapshotId -Index $Index); utc = $Utc
        plan_id = $planId; config_generation = $generation; repository_id = $repositoryId
        change_anomaly_status = $(if ($Hold) { 'hold' } else { $Status })
    } | ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $Fixture.State "logs\backup-$runId.jsonl.log"), (($lines -join "`n") + "`n"), $encoding)
    return $runId
}

function Set-LatestBackup {
    param([pscustomobject]$Fixture, [int]$Index, [string]$Utc, [string]$RunId, [bool]$Hold = $false)
    $evidence = [ordered]@{
        schema_version = 1; run_id = $RunId; state = 'success'; verification_complete = $true
        snapshot_id = (Get-SnapshotId -Index $Index); repository_id = $repositoryId; plan_id = $planId
        config_generation = $generation; finished_utc = $Utc; maintenance_hold = $Hold
    }
    Write-Json -Path (Join-Path $Fixture.State 'last-success.json') -Value $evidence
    Write-Json -Path (Join-Path $Fixture.State 'status.json') -Value $evidence
}

function Write-Store {
    param([pscustomobject]$Fixture, [string[]]$Lines)
    [IO.File]::WriteAllText($Fixture.Store, (($Lines -join "`n") + "`n"), $encoding)
    if (Test-Path -LiteralPath ($Fixture.Store + '.batches')) { Remove-Item -LiteralPath ($Fixture.Store + '.batches') }
}

function Get-StoreIds {
    param([pscustomobject]$Fixture)
    return @(Get-Content -LiteralPath $Fixture.Store | Where-Object { $_ } | ForEach-Object { $_.Split("`t")[0] })
}

function Write-Manifest {
    param([string]$Install)
    $manifestFiles = @(Get-ChildItem -LiteralPath $Install -Recurse -File -Force |
        Where-Object Name -notin @('runtime-manifest.json', 'scheduled-task.xml', 'google-drive-verification-task.xml') |
        Sort-Object FullName)
    Write-Json -Path (Join-Path $Install 'runtime-manifest.json') -Value ([ordered]@{
        schema_version = 1; version = '0.3.0'; installation_id = ('5' * 64); file_count = $manifestFiles.Count
        files = @($manifestFiles | ForEach-Object {
            [ordered]@{
                relative_path = $_.FullName.Substring($Install.Length + 1); bytes = $_.Length; sha256 = (Get-Hash -Path $_.FullName)
            }
        })
    })
}

function New-Fixture {
    # Five checked daily backups; Restic would keep the newest three. The person has not turned clean-up on.
    $root = Join-Path ([IO.Path]::GetTempPath()) ('RSRT-T-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $roots.Add($root)
    $install = Join-Path $root 'ProgramFiles\ResticBackuper'
    $state = Join-Path $root 'ProgramData\ResticBackuper'
    $repository = Join-Path $root 'Repository\Personal'
    $recovery = Join-Path $root 'Repository\RecoveryTools'
    $source = Join-Path $root 'Source'
    foreach ($directory in @($install, (Join-Path $install 'Python'), $state, (Join-Path $state 'logs'), $repository, $recovery, $source)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Copy-Item -LiteralPath $managerSource -Destination (Join-Path $install 'Manage-Retention.ps1')
    foreach ($module in @('retention.py', 'restic_common.py', 'secret_store.py')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot "src\$module") -Destination (Join-Path $install $module)
    }
    Copy-Item -LiteralPath $fakeRestic -Destination (Join-Path $install 'restic.exe')
    Copy-Item -LiteralPath $pythonWrapper -Destination (Join-Path $install 'Python\python.exe')
    [IO.File]::WriteAllText((Join-Path $install 'excludes.txt'), "node_modules`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $source 'canary.txt'), "canary`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $root 'RecoveryKey.txt'), "Password: fixture-recovery-password-material-that-is-long-enough-12345`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $repository 'config'), "repository config sentinel`n", $encoding)
    [IO.File]::WriteAllBytes((Join-Path $state 'run.lock'), [byte[]](0))
    $serial = Get-VolumeSerial -Path $repository
    $config = [ordered]@{
        schema_version = 1; plan_id = $planId; config_generation = $generation
        repository = $repository; repository_volume_serial = $serial
        restic_executable = Join-Path $install 'restic.exe'; recovery_tools_directory = $recovery
        python_executable = Join-Path $install 'Python\python.exe'; state_directory = $state
        secret_file = Join-Path $state 'missing-secret.json'; recovery_key_file = Join-Path $root 'RecoveryKey.txt'
        exclude_file = Join-Path $install 'excludes.txt'; canary_file = Join-Path $source 'canary.txt'
        hostname = 'FIXTURE'; scheduled_tag = 'scheduled'; use_vss = $false; minimum_free_gib = 0
        cloud_placeholder_policy = 'strict'; sources = @($source)
        source_identities = [ordered]@{ $source = [ordered]@{ expected_volume_serial = $serial } }
    }
    $configPath = Join-Path $install 'backup-config.json'
    Write-Json -Path $configPath -Value $config
    Write-Manifest -Install $install
    [IO.File]::WriteAllText((Join-Path $install 'scheduled-task.xml'), "<primary-task-fixture />`n", $encoding)
    $fixture = [pscustomobject]@{
        Root = $root; Install = $install; State = $state; Repository = $repository; Source = $source
        ConfigPath = $configPath; Log = (Join-Path $root 'restic.log'); Store = (Join-Path $root 'store.txt')
    }
    $storeLines = [Collections.Generic.List[string]]::new()
    $runId = $null
    foreach ($index in 1..5) {
        $day = '2026-09-2{0}' -f (4 + $index)
        $keep = if ($index -eq 5) { 'daily snapshot|weekly snapshot|monthly snapshot' } elseif ($index -ge 3) { 'daily snapshot' } else { '' }
        $storeLines.Add(((Get-SnapshotId -Index $index), "${day}T02:00:00+02:00", $keep) -join "`t")
        $runId = Write-BackupLog -Fixture $fixture -Index $index -Utc "${day}T00:30:00Z"
    }
    Set-LatestBackup -Fixture $fixture -Index 5 -Utc '2026-09-29T00:30:00Z' -RunId $runId
    Write-Store -Fixture $fixture -Lines $storeLines.ToArray()
    return $fixture
}

function Get-RequestDigest {
    param([string]$UserSid, [string]$Action, [string]$ConfigHash, [string]$Plan, [long]$ConfigGeneration, [string[]]$Fields, [string]$Nonce)
    $payload = @('ResticBackuper.RetentionRequest.v1', $UserSid, $Action, $ConfigHash, $Plan,
        $ConfigGeneration.ToString([Globalization.CultureInfo]::InvariantCulture)) + $Fields + @($Nonce)
    return Get-BytesHash -Bytes $encoding.GetBytes(($payload -join "`n"))
}

function Invoke-Manager {
    param(
        [pscustomobject]$Fixture,
        [string]$Action,
        [hashtable]$Arguments = @{},
        [hashtable]$Fake = @{},
        [string]$DigestOverride = '',
        [string]$UserSid = $sid,
        [string]$ResultPathOverride = '',
        [string]$ScriptPath = '',
        [string]$TestRootOverride = '',
        [hashtable]$Python = @{},
        [hashtable]$Limits = @{}
    )
    $nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
    $configHash = Get-Hash -Path $Fixture.ConfigPath
    $names = @('Enabled', 'KeepDaily', 'KeepWeekly', 'KeepMonthly', 'ExpectedPreviewSha256', 'ExpectedRemoveSetSha256',
        'ExpectedRemoveCount', 'ConfirmEarlierChanges')
    $fields = @(foreach ($name in $names) { if ($Arguments.ContainsKey($name)) { [string]$Arguments[$name] } else { '' } })
    $digest = if ($DigestOverride) { $DigestOverride } else {
        Get-RequestDigest -UserSid $UserSid -Action $Action -ConfigHash $configHash -Plan $planId -ConfigGeneration $generation -Fields $fields -Nonce $nonce
    }
    $resultPath = if ($ResultPathOverride) { $ResultPathOverride } else { Join-Path $Fixture.State "RetentionManagerResults\$nonce.json" }
    $script = if ($ScriptPath) { $ScriptPath } else { Join-Path $Fixture.Install 'Manage-Retention.ps1' }
    $argumentList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script,
        '-Action', $Action, '-ExpectedUserSid', $UserSid, '-ExpectedConfigSha256', $configHash,
        '-ExpectedPlanId', $planId, '-ExpectedConfigGeneration', $generation,
        '-ResultPath', $resultPath, '-RequestNonce', $nonce, '-RequestDigest', $digest,
        '-TestRoot', $(if ($TestRootOverride) { $TestRootOverride } else { $Fixture.Root })
    )
    foreach ($name in $names) {
        if ($Arguments.ContainsKey($name)) { $argumentList += @("-$name", [string]$Arguments[$name]) }
    }
    Write-FakeResticControl -Fixture $Fixture -Settings $Fake
    $pythonLines = @(foreach ($name in $Python.Keys) { $name + '=' + [string]$Python[$name] })
    [IO.File]::WriteAllLines($fakePythonControl, [string[]]$pythonLines, $encoding)
    $limitLines = @(foreach ($name in $Limits.Keys) { $name + '=' + [string]$Limits[$name] })
    [IO.File]::WriteAllLines((Join-Path $Fixture.Root 'step-time-limits.txt'), [string[]]$limitLines, $encoding)
    if (Test-Path -LiteralPath $Fixture.Log) { Remove-Item -LiteralPath $Fixture.Log }
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell @argumentList 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorPreference }
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    $progress = if (Test-Path -LiteralPath ($resultPath + '.progress.json') -PathType Leaf) {
        Get-Content -LiteralPath ($resultPath + '.progress.json') -Raw | ConvertFrom-Json
    } else { $null }
    $log = [string[]]@()
    if (Test-Path -LiteralPath $Fixture.Log) { $log = [string[]]@(Get-Content -LiteralPath $Fixture.Log) }
    return [pscustomobject]@{
        ExitCode = $exitCode; Result = $result; Progress = $progress; Output = $output; Nonce = $nonce; Digest = $digest
        Log = $log; ResultPath = $resultPath
    }
}

function Get-Preview {
    param([pscustomobject]$Fixture)
    $path = Join-Path $Fixture.State 'retention-preview.json'
    return [pscustomobject]@{ Document = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json); Sha256 = (Get-Hash -Path $path) }
}

function Invoke-Apply {
    param([pscustomobject]$Fixture, [hashtable]$Fake = @{}, [string]$Confirm = '1', [string]$PreviewSha = '', [string]$Count = '',
        [hashtable]$Python = @{}, [hashtable]$Limits = @{})
    $preview = Get-Preview -Fixture $Fixture
    return Invoke-Manager -Fixture $Fixture -Action apply -Fake $Fake -Python $Python -Limits $Limits -Arguments @{
        ExpectedPreviewSha256 = $(if ($PreviewSha) { $PreviewSha } else { $preview.Sha256 })
        ExpectedRemoveSetSha256 = $preview.Document.remove_set_sha256
        ExpectedRemoveCount = $(if ($Count) { $Count } else { [string]$preview.Document.remove_count })
        ConfirmEarlierChanges = $Confirm
    }
}

function Enable-Retention {
    param([pscustomobject]$Fixture)
    $run = Invoke-Manager -Fixture $Fixture -Action configure -Arguments @{ Enabled = '1'; KeepDaily = '7'; KeepWeekly = '4'; KeepMonthly = '6' }
    Assert-True ($run.ExitCode -eq 0 -and $run.Result.ok -and $run.Result.state -ceq 'configured') "turning clean-up on works: $($run.Output -join ' | ')"
    return $run
}

function Test-RemovalCalls {
    param([object[]]$Log)
    return @(@($Log) | Where-Object {
        $null -ne $_ -and $(
            $words = ([string]$_).Split("`t")
            (($words -contains 'forget') -and ($words -notcontains '--dry-run')) -or ($words -contains 'prune') -or ($words -contains 'check')
        )
    })
}

function Test-StoppedTree {
    # The stand-in's hung step wrote its own process id and its child's; both must be gone.
    param([string]$PidFile)
    if (-not (Test-Path -LiteralPath $PidFile -PathType Leaf)) { return $false }
    $ids = @(([IO.File]::ReadAllText($PidFile)).Trim().Split(' ') | ForEach-Object { [int]$_ })
    if ($ids.Count -ne 2) { return $false }
    foreach ($id in $ids) {
        if ($null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue)) { return $false }
    }
    return $true
}

function Test-RunLockFree {
    param([pscustomobject]$Fixture)
    $stream = [IO.File]::Open((Join-Path $Fixture.State 'run.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        try { $stream.Lock(0, 1) } catch { return $false }
        $stream.Unlock(0, 1)
        return $true
    }
    finally { $stream.Dispose() }
}

function Get-LastHistoryEntry {
    param([pscustomobject]$Fixture)
    $history = Get-Content -LiteralPath (Join-Path $Fixture.State 'retention-history.json') -Raw | ConvertFrom-Json
    return @($history.entries)[-1]
}

$productionConfig = Join-Path $env:ProgramFiles 'ResticBackuper\backup-config.json'
$productionHashBefore = $null
if (-not $SkipInstalledChecks) {
    $productionHashBefore = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
}

# Settings a user could plant in their own environment. Manage-Retention must not pass them to retention.py (the Python
# stand-in exits 93 on any variable outside its allow-list), and retention.py must not pass them to Restic (exit 92).
$plantedEnvironment = @{
    RESTIC_PASSWORD_COMMAND = 'C:\planted\evil.cmd'
    RESTIC_PASSWORD_FILE = 'C:\planted\password.txt'
    RCLONE_CONFIG_PLANTED_TYPE = 'sftp'
}
foreach ($name in $plantedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $plantedEnvironment[$name], 'Process') }

try {
    # --- Static rules for an elevated script ---
    $managerText = [IO.File]::ReadAllText($managerSource)
    Assert-True (-not ($managerText -match '(?m)^\s*Add-Type\b')) 'the manager never compiles code'
    Assert-True ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($managerSource)) -ceq $managerText) 'the manager is plain ASCII'
    # Its LF line endings are checked by tests\test_retention.py in the copy git stores: a checkout with core.autocrlf=true
    # (the CI runner's) writes CR LF here, and this suite runs in CI as a temporary standard user, so it does not call git.
    foreach ($command in @('Get-Acl', 'ConvertFrom-Json', 'ConvertTo-Json')) {
        $bare = [regex]::Matches($managerText, '(?<![\\\w-])' + [regex]::Escape($command) + '\b').Count
        Assert-True ($bare -eq 0) "$command is always module-qualified in the manager"
    }
    Assert-True ($managerText -match "'apply-forget'") 'the manager removes only through the helper''s confirmed-list step'
    Assert-True (-not ($managerText -match "'(forget|prune|check)'")) 'the manager never starts Restic itself'
    Assert-True (-not ($managerText -match '--keep-(last|within|hourly|yearly|tag)')) 'the manager passes no other keep rule'

    # --- The request digest test vector, shared with the dashboard ---
    $vector = Get-RequestDigest -UserSid 'S-1-5-21-1-2-3-1001' -Action 'apply' -ConfigHash ('a' * 64) -Plan $planId -ConfigGeneration 7 `
        -Fields @('', '', '', '', ('b' * 64), ('c' * 64), '2', '1') -Nonce ('d' * 64)
    Assert-True ($vector -ceq 'dc98255ecec19bc0c56d1edcc522694560baeaadbb7355673b2755e4e4b49995') 'the request digest test vector'

    # --- Off by default: listing needs the person to turn it on ---
    $fixture = New-Fixture
    $preview = Invoke-Manager -Fixture $fixture -Action preview
    Assert-True ($preview.ExitCode -eq 0 -and $preview.Result.ok) "listing works while clean-up is off: $($preview.Output -join ' | ')"
    Assert-True ($preview.Result.preview_state -ceq 'disabled' -or $preview.Result.preview_state -ceq 'blocked') 'a preview while off removes nothing and lists nothing'
    Assert-True (@(Test-RemovalCalls -Log $preview.Log).Count -eq 0) 'a preview while off runs nothing that removes'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'retention-policy.json'))) 'a preview never turns clean-up on'

    # --- Request shape and binding refusals ---
    $bad = Invoke-Manager -Fixture $fixture -Action configure -Arguments @{ Enabled = '1'; KeepDaily = '3'; KeepWeekly = '4'; KeepMonthly = '6' }
    Assert-True ($bad.ExitCode -eq 1 -and $null -eq $bad.Result) 'too few daily backups is refused before anything runs'
    $bad = Invoke-Manager -Fixture $fixture -Action configure -Arguments @{ Enabled = '1'; KeepDaily = '14'; KeepWeekly = '8'; KeepMonthly = '121' }
    Assert-True ($bad.ExitCode -eq 1) 'too many monthly backups is refused'
    $bad = Invoke-Manager -Fixture $fixture -Action configure -Arguments @{ Enabled = '0'; KeepDaily = '14' }
    Assert-True ($bad.ExitCode -eq 1) 'turning clean-up off takes no counts'
    $bad = Invoke-Manager -Fixture $fixture -Action preview -Arguments @{ Enabled = '1' }
    Assert-True ($bad.ExitCode -eq 1) 'listing takes no setting'
    $bad = Invoke-Manager -Fixture $fixture -Action apply -Arguments @{ ExpectedPreviewSha256 = ('a' * 64); ExpectedRemoveSetSha256 = ('b' * 64); ExpectedRemoveCount = '1' }
    Assert-True ($bad.ExitCode -eq 1) 'removing needs an answer about checking files'
    $bad = Invoke-Manager -Fixture $fixture -Action apply -Arguments @{ ExpectedPreviewSha256 = ('A' * 64); ExpectedRemoveSetSha256 = ('b' * 64); ExpectedRemoveCount = '1'; ConfirmEarlierChanges = '1' }
    Assert-True ($bad.ExitCode -eq 1) 'the confirmed list must be named exactly'
    $bad = Invoke-Manager -Fixture $fixture -Action preview -DigestOverride ('e' * 64)
    Assert-True ($bad.ExitCode -eq 1 -and $null -eq $bad.Result) 'a digest that does not match writes no result'
    $bad = Invoke-Manager -Fixture $fixture -Action preview -UserSid 'S-1-5-21-1-2-3-4'
    Assert-True ($bad.ExitCode -eq 1 -and $null -eq $bad.Result) 'another account''s request is refused'
    $elsewhere = Join-Path $fixture.State ('RetentionManagerResults\' + ('f' * 64) + '.json')
    $bad = Invoke-Manager -Fixture $fixture -Action preview -ResultPathOverride $elsewhere
    Assert-True ($bad.ExitCode -eq 1 -and -not (Test-Path -LiteralPath $elsewhere)) 'a result path that is not the nonce''s is refused'
    $outside = Join-Path $projectRoot 'tests'
    $bad = Invoke-Manager -Fixture $fixture -Action preview -TestRootOverride $outside
    Assert-True ($bad.ExitCode -eq 1) 'a test root outside the temporary folder is refused'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $fixture.State 'RetentionManagerResults') -Force | Where-Object Name -like '*.json').Count -ge 1) 'earlier results stay'

    # --- Turning it on lists what would go; nothing is removed ---
    $on = Enable-Retention -Fixture $fixture
    $policy = Get-Content -LiteralPath (Join-Path $fixture.State 'retention-policy.json') -Raw | ConvertFrom-Json
    Assert-True ($policy.enabled -eq $true -and $policy.keep_daily -eq 7 -and $policy.repository_id -ceq $repositoryId) 'the policy names the setting and the backup location'
    $current = Get-Preview -Fixture $fixture
    Assert-True ($current.Document.state -ceq 'ready' -and $current.Document.remove_count -eq 2) "the preview lists the two oldest backups: $($current.Document | ConvertTo-Json -Depth 4 -Compress)"
    Assert-True ($on.Result.preview_sha256 -ceq $current.Sha256) 'the result names the preview it wrote'
    Assert-True (@(Test-RemovalCalls -Log $on.Log).Count -eq 0) 'turning it on removes nothing'
    Assert-True (@($on.Log | Where-Object { $_ -match "`tforget`t" -and $_ -notmatch '--no-lock' }).Count -eq 0) 'every listing passes --no-lock'
    Assert-True ((Get-StoreIds -Fixture $fixture).Count -eq 5) 'all five backups are still there'

    # --- A held change review blocks the preview before Restic lists anything ---
    $holdFixture = New-Fixture
    [void](Enable-Retention -Fixture $holdFixture)
    $runId = Write-BackupLog -Fixture $holdFixture -Index 6 -Utc '2026-09-30T00:30:00Z' -Hold
    Write-Store -Fixture $holdFixture -Lines (@(Get-Content -LiteralPath $holdFixture.Store) +
        @(((Get-SnapshotId -Index 6), '2026-09-30T02:00:00+02:00', 'daily snapshot') -join "`t"))
    Set-LatestBackup -Fixture $holdFixture -Index 6 -Utc '2026-09-30T00:30:00Z' -RunId $runId -Hold $true
    $held = Invoke-Manager -Fixture $holdFixture -Action preview
    Assert-True ($held.ExitCode -eq 0 -and $held.Result.preview_state -ceq 'blocked') 'a preview with an open change review is blocked'
    Assert-True ((Get-Preview -Fixture $holdFixture).Document.blocked_reason -ceq 'change_review_open') 'the preview says a change review is open'
    Assert-True (@($held.Log | Where-Object { $_ -match "`tforget`t" }).Count -eq 0) 'no listing runs while a change review is open'

    # --- A journal blocks everything but turning clean-up off ---
    $journal = Join-Path $fixture.State 'source-change.journal.json'
    [IO.File]::WriteAllText($journal, "{}`n", $encoding)
    $blocked = Invoke-Apply -Fixture $fixture
    Assert-True ($blocked.ExitCode -eq 2 -and $blocked.Result.refusal_code -ceq 'pending_change') 'a pending change refuses removal'
    Assert-True ($blocked.Log.Count -eq 0) 'a pending change refuses before any Restic call'
    $blocked = Invoke-Manager -Fixture $fixture -Action preview
    Assert-True ($blocked.ExitCode -eq 2 -and $blocked.Result.refusal_code -ceq 'pending_change') 'a pending change refuses a listing'
    $offFixture = New-Fixture
    [void](Enable-Retention -Fixture $offFixture)
    [IO.File]::WriteAllText((Join-Path $offFixture.State 'repository-relocation.journal.json'), "{}`n", $encoding)
    Remove-Item -LiteralPath (Join-Path $offFixture.Repository 'config')
    $off = Invoke-Manager -Fixture $offFixture -Action configure -Arguments @{ Enabled = '0' }
    Assert-True ($off.ExitCode -eq 0 -and $off.Result.state -ceq 'disabled') "turning it off works with a pending change and an unplugged backup location: $($off.Output -join ' | ')"
    Assert-True ($off.Log.Count -eq 0) 'turning it off never calls Restic'
    $offPolicy = Get-Content -LiteralPath (Join-Path $offFixture.State 'retention-policy.json') -Raw | ConvertFrom-Json
    Assert-True ($offPolicy.enabled -eq $false -and $offPolicy.keep_daily -eq 7) 'turning it off keeps the counts for next time'
    Assert-True ((Get-StoreIds -Fixture $offFixture).Count -eq 5) 'turning it off removes nothing'

    # --- An unplugged backup drive is a reason to wait, refused with that reason before anything runs ---
    $unpluggedFixture = New-Fixture
    [void](Enable-Retention -Fixture $unpluggedFixture)
    $unpluggedSeen = Get-Preview -Fixture $unpluggedFixture
    Rename-Item -LiteralPath $unpluggedFixture.Repository -NewName 'Personal-unplugged'
    $unplugged = Invoke-Manager -Fixture $unpluggedFixture -Action preview
    Assert-True ($unplugged.ExitCode -eq 2 -and $unplugged.Result.state -ceq 'refused' -and $unplugged.Result.refusal_code -ceq 'backup_location_unavailable') "Check now with the backup drive unplugged is refused with that reason: $($unplugged.Output -join ' | ')"
    Assert-True ($unplugged.Log.Count -eq 0) 'nothing runs while the backup drive is unplugged'
    $unplugged = Invoke-Apply -Fixture $unpluggedFixture
    Assert-True ($unplugged.ExitCode -eq 2 -and $unplugged.Result.refusal_code -ceq 'backup_location_unavailable' -and $unplugged.Log.Count -eq 0) "a removal with the backup drive unplugged is refused with that reason: $($unplugged.Output -join ' | ')"
    $unplugged = Invoke-Manager -Fixture $unpluggedFixture -Action configure -Arguments @{ Enabled = '1'; KeepDaily = '14'; KeepWeekly = '8'; KeepMonthly = '24' }
    Assert-True ($unplugged.ExitCode -eq 2 -and $unplugged.Result.refusal_code -ceq 'backup_location_unavailable') 'changing the setting with the backup drive unplugged is refused with that reason'
    Assert-True ((Get-Preview -Fixture $unpluggedFixture).Sha256 -ceq $unpluggedSeen.Sha256) 'a refused request leaves the list as it was'
    Rename-Item -LiteralPath (Join-Path (Split-Path -Parent $unpluggedFixture.Repository) 'Personal-unplugged') -NewName 'Personal'
    Remove-Item -LiteralPath (Join-Path $unpluggedFixture.Repository 'config')
    $unplugged = Invoke-Manager -Fixture $unpluggedFixture -Action preview
    Assert-True ($unplugged.ExitCode -eq 2 -and $unplugged.Result.refusal_code -ceq 'backup_location_unavailable') 'a drive without the backup location on it is refused with the same reason'
    Remove-Item -LiteralPath $journal

    # --- The run lock held elsewhere: busy, and nothing runs ---
    $lock = [IO.File]::Open((Join-Path $fixture.State 'run.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        $lock.Lock(0, 1)
        $busy = Invoke-Apply -Fixture $fixture
        Assert-True ($busy.ExitCode -eq 2 -and $busy.Result.refusal_code -ceq 'busy') 'a held run lock is refused as busy'
        Assert-True ($busy.Log.Count -eq 0) 'busy runs no Restic call'
    }
    finally { $lock.Dispose() }

    # --- A preview file that is not the one the person saw ---
    $mismatch = Invoke-Apply -Fixture $fixture -PreviewSha ('9' * 64)
    Assert-True ($mismatch.ExitCode -eq 2 -and $mismatch.Result.refusal_code -ceq 'preview_mismatch') 'a different preview is refused'
    Assert-True (@(Test-RemovalCalls -Log $mismatch.Log).Count -eq 0) 'a different preview removes nothing'
    $mismatch = Invoke-Apply -Fixture $fixture -Count '1'
    Assert-True ($mismatch.ExitCode -eq 2 -and $mismatch.Result.refusal_code -ceq 'preview_mismatch') 'a different count is refused'

    # --- The first clean-up needs the person to say they checked their files ---
    $unconfirmed = Invoke-Apply -Fixture $fixture -Confirm '0'
    Assert-True ($unconfirmed.ExitCode -eq 2 -and $unconfirmed.Result.refusal_code -ceq 'earlier_changes_not_confirmed') 'the first clean-up needs the files confirmed'
    Assert-True (@(Test-RemovalCalls -Log $unconfirmed.Log).Count -eq 0) 'unconfirmed changes remove nothing'

    # --- Restic's answer changed since the preview: the new list is shown and nothing is removed ---
    $changedFixture = New-Fixture
    [void](Enable-Retention -Fixture $changedFixture)
    $seen = Get-Preview -Fixture $changedFixture
    $lines = @(Get-Content -LiteralPath $changedFixture.Store)
    # Restic now keeps the second-oldest backup as a monthly one.
    $parts = $lines[1].Split("`t")
    $lines[1] = ($parts[0], $parts[1], 'monthly snapshot') -join "`t"
    Write-Store -Fixture $changedFixture -Lines $lines
    $changed = Invoke-Manager -Fixture $changedFixture -Action apply -Arguments @{
        ExpectedPreviewSha256 = $seen.Sha256; ExpectedRemoveSetSha256 = $seen.Document.remove_set_sha256
        ExpectedRemoveCount = [string]$seen.Document.remove_count; ConfirmEarlierChanges = '1'
    }
    Assert-True ($changed.ExitCode -eq 3 -and $changed.Result.state -ceq 'preview_changed') "a changed list is reported: $($changed.Output -join ' | ')"
    Assert-True (@(Test-RemovalCalls -Log $changed.Log).Count -eq 0) 'a changed list removes nothing'
    Assert-True ((Get-Preview -Fixture $changedFixture).Document.remove_count -eq 1) 'the new list is written for the person to see'

    # --- The happy path: exactly the confirmed backups go, then space is freed and the rest is checked ---
    $removed = Invoke-Apply -Fixture $fixture
    Assert-True ($removed.ExitCode -eq 0 -and $removed.Result.ok -and $removed.Result.state -ceq 'removed') "the confirmed list is removed: $($removed.Output -join ' | ')"
    Assert-True ($removed.Result.removed_count -eq 2 -and $removed.Result.prune_completed -and $removed.Result.check_completed) 'space was freed and the rest checked'
    Assert-True ($removed.Result.request_nonce -ceq $removed.Nonce -and $removed.Result.request_digest -ceq $removed.Digest -and $removed.Result.request_user_sid -ceq $sid) 'the result is bound to its request'
    $order = @($removed.Log | ForEach-Object {
        $words = $_.Split("`t")
        if ($words -contains '--dry-run') { 'list' } elseif ($words -contains 'forget') { 'forget' } elseif ($words -contains 'prune') { 'prune' }
        elseif ($words -contains 'check') { 'check' } elseif ($words -contains 'snapshots') { 'relist' } else { $null }
    } | Where-Object { $_ })
    Assert-True (($order -join ',') -ceq 'list,forget,relist,prune,check,list') "the steps run in order: $($order -join ',')"
    $forgetLine = @($removed.Log | Where-Object { $_.Split("`t") -contains 'forget' -and $_.Split("`t") -notcontains '--dry-run' })[0].Split("`t")
    $forgotten = @($forgetLine[([Array]::IndexOf($forgetLine, 'forget') + 1)..($forgetLine.Count - 1)])
    Assert-True (($forgotten -join ',') -ceq ((Get-SnapshotId -Index 1), (Get-SnapshotId -Index 2) -join ',')) 'exactly the two confirmed backups were named'
    Assert-True ((Get-StoreIds -Fixture $fixture).Count -eq 3) 'three backups are left'
    $history = Get-Content -LiteralPath (Join-Path $fixture.State 'retention-history.json') -Raw | ConvertFrom-Json
    Assert-True (@($history.entries).Count -eq 1 -and $history.entries[0].outcome -ceq 'removed' -and $history.entries[0].files_confirmed) 'the clean-up is recorded'
    $confirmedRecord = Get-Content -LiteralPath (Join-Path $fixture.State 'retention-confirmed.json') -Raw | ConvertFrom-Json
    Assert-True ($confirmedRecord.schema -ceq 'ResticBackuper.RetentionConfirmed.v1' -and $confirmedRecord.request_nonce -ceq $removed.Nonce) 'the files the person checked are recorded with the clean-up'
    $fresh = (Get-Preview -Fixture $fixture).Document
    Assert-True ($fresh.remove_count -eq 0) 'the fresh list has nothing more to remove'
    Assert-True (-not $fresh.first_cleanup -and -not $fresh.needs_files_confirmed) 'after a confirmed clean-up the next list does not ask again for the same backups'
    Assert-True ($removed.Progress.stage -ceq 'complete') 'the progress file says it finished'

    # --- An unmanifested file in the program folder ---
    $planted = Join-Path $fixture.Install 'planted.py'
    [IO.File]::WriteAllText($planted, "print('x')`n", $encoding)
    $unsafe = Invoke-Manager -Fixture $fixture -Action preview
    Assert-True ($unsafe.ExitCode -eq 1 -and $unsafe.Result.state -ceq 'failed' -and $unsafe.Log.Count -eq 0) 'an unmanifested program file stops everything'
    Remove-Item -LiteralPath $planted

    # --- A failed batch: partial, and the space is still freed for what went ---
    $partialFixture = New-Fixture
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $partialFixture.Store)) { $lines.Add($line) }
    foreach ($index in 10..69) {
        $lines.Add(((Get-SnapshotId -Index $index), ('2026-0{0}-{1:00}T0{2}:00:00Z' -f (1 + $index % 7), (1 + $index % 27), ($index % 9)), '') -join "`t")
    }
    Write-Store -Fixture $partialFixture -Lines $lines.ToArray()
    [void](Enable-Retention -Fixture $partialFixture)
    Assert-True ((Get-Preview -Fixture $partialFixture).Document.remove_count -eq 62) 'the large list is complete'
    $partial = Invoke-Apply -Fixture $partialFixture -Fake @{ FAKE_FAIL_BATCH = 2 }
    Assert-True ($partial.ExitCode -eq 4 -and $partial.Result.state -ceq 'partial' -and $partial.Result.removed_count -eq 50) "a failed batch is partial: $($partial.Output -join ' | ')"
    Assert-True ($partial.Result.prune_completed) 'the space of what went is freed'

    # --- A failed prune: space pending, and offered again ---
    $pruneFixture = New-Fixture
    [void](Enable-Retention -Fixture $pruneFixture)
    $pruned = Invoke-Apply -Fixture $pruneFixture -Fake @{ FAKE_PRUNE_CODE = 1 }
    Assert-True ($pruned.ExitCode -eq 5 -and $pruned.Result.state -ceq 'space_pending' -and -not $pruned.Result.check_completed) 'a failed prune is space pending'
    Assert-True ((Get-Preview -Fixture $pruneFixture).Document.prune_pending -eq $true) 'freeing the space is offered again'
    $again = Invoke-Apply -Fixture $pruneFixture
    Assert-True ($again.ExitCode -eq 0 -and $again.Result.state -ceq 'nothing_to_remove' -and $again.Result.prune_completed) "the space is freed the next time: $($again.Output -join ' | ')"

    # --- A failed check after freeing space ---
    $checkFixture = New-Fixture
    [void](Enable-Retention -Fixture $checkFixture)
    $checked = Invoke-Apply -Fixture $checkFixture -Fake @{ FAKE_CHECK_CODE = 1 }
    Assert-True ($checked.ExitCode -eq 6 -and $checked.Result.state -ceq 'check_failed') 'a failed check is reported'

    # --- The list could not be read back after removing: partial, nothing more runs ---
    $relistFixture = New-Fixture
    [void](Enable-Retention -Fixture $relistFixture)
    $relist = Invoke-Apply -Fixture $relistFixture -Fake @{ FAKE_SNAPSHOTS_CODE = 1 }
    Assert-True ($relist.ExitCode -eq 4 -and $relist.Result.state -ceq 'partial' -and $relist.Result.removal_unverified) "an unverified removal is partial: $($relist.Output -join ' | ')"
    Assert-True (@($relist.Log | Where-Object { $_.Split("`t") -contains 'prune' }).Count -eq 0) 'nothing more runs after an unverified removal'

    # --- A step that runs past its time limit is stopped with every process it started, and the run lock is let go ---
    $hangFixture = New-Fixture
    [void](Enable-Retention -Fixture $hangFixture)
    $pidFile = Join-Path $hangFixture.Root 'hang.pid'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $hung = Invoke-Manager -Fixture $hangFixture -Action preview -Python @{ HANG_STEP = 'preview'; PID_FILE = $pidFile } -Limits @{ preview = 3 }
    $clock.Stop()
    Assert-True ($hung.ExitCode -eq 1 -and $hung.Result.state -ceq 'failed') "a listing past its time limit fails: $($hung.Output -join ' | ')"
    Assert-True ([string]$hung.Result.error -match 'time limit') 'the result says the listing ran past its time limit'
    Assert-True ($clock.Elapsed.TotalSeconds -lt 120) "the stalled listing is stopped at its limit, not after it ends: $($clock.Elapsed.TotalSeconds) s"
    Assert-True (Test-StoppedTree -PidFile $pidFile) 'the stalled helper and the process it started are both stopped'
    Assert-True (Test-RunLockFree -Fixture $hangFixture) 'the run lock is free after a stalled listing'

    # --- Freeing the space stalls after the backups were removed: it says so, and freeing the space is offered again ---
    $pruneHangFixture = New-Fixture
    [void](Enable-Retention -Fixture $pruneHangFixture)
    $pidFile = Join-Path $pruneHangFixture.Root 'hang.pid'
    $stalled = Invoke-Apply -Fixture $pruneHangFixture -Python @{ HANG_STEP = 'apply-prune'; PID_FILE = $pidFile } -Limits @{ 'apply-prune' = 3 }
    Assert-True ($stalled.ExitCode -eq 5 -and $stalled.Result.state -ceq 'space_pending' -and $stalled.Result.removed_count -eq 2) "a stalled freeing of space says the backups were removed and the space is not free yet: $($stalled.Output -join ' | ')"
    Assert-True (-not $stalled.Result.prune_completed -and $stalled.Result.history_recorded -eq $true) 'the removal is recorded even though freeing the space stalled'
    Assert-True ([string]$stalled.Result.error -match 'time limit') 'the result says freeing the space ran past its time limit'
    Assert-True (Test-StoppedTree -PidFile $pidFile) 'the stalled freeing of space is stopped with everything it started'
    Assert-True (Test-RunLockFree -Fixture $pruneHangFixture) 'the run lock is free after a stalled freeing of space'
    Assert-True ((Get-StoreIds -Fixture $pruneHangFixture).Count -eq 3) 'the two confirmed backups were removed'
    Assert-True ((Get-Preview -Fixture $pruneHangFixture).Document.prune_pending -eq $true) 'freeing the space is offered again after it stalled'
    Assert-True ((Get-LastHistoryEntry -Fixture $pruneHangFixture).outcome -ceq 'space_pending') 'the history says the space is still to be freed'
    Assert-True ($stalled.Progress.stage -ceq 'failed') 'the progress file does not say it finished'

    # --- The removal itself stalls: some backups may have gone, and nobody claims a count ---
    $forgetHangFixture = New-Fixture
    [void](Enable-Retention -Fixture $forgetHangFixture)
    $pidFile = Join-Path $forgetHangFixture.Root 'hang.pid'
    $unknown = Invoke-Apply -Fixture $forgetHangFixture -Python @{ HANG_STEP = 'apply-forget'; PID_FILE = $pidFile } -Limits @{ 'apply-forget' = 3 }
    Assert-True ($unknown.ExitCode -eq 4 -and $unknown.Result.state -ceq 'partial' -and $unknown.Result.removal_unverified -eq $true) "a stalled removal is partial and unverified: $($unknown.Output -join ' | ')"
    Assert-True ($unknown.Result.removed_count -eq 0 -and $unknown.Result.history_recorded -eq $true) 'a stalled removal claims no count and is recorded'
    Assert-True (Test-StoppedTree -PidFile $pidFile) 'the stalled removal is stopped with everything it started'
    Assert-True (Test-RunLockFree -Fixture $forgetHangFixture) 'the run lock is free after a stalled removal'
    $entry = Get-LastHistoryEntry -Fixture $forgetHangFixture
    Assert-True ($entry.outcome -ceq 'partial' -and $entry.removal_unverified -eq $true) 'the history says the removal could not be confirmed'
    Assert-True ((Get-Preview -Fixture $forgetHangFixture).Document.prune_pending -eq $true) 'freeing the space is offered after a removal nobody could confirm'

    # --- Answers that cannot be read, from each step after the removal started ---
    $garbledFixture = New-Fixture
    [void](Enable-Retention -Fixture $garbledFixture)
    $garbled = Invoke-Apply -Fixture $garbledFixture -Python @{ GARBLE_STEP = 'apply-forget' }
    Assert-True ($garbled.ExitCode -eq 4 -and $garbled.Result.state -ceq 'partial' -and $garbled.Result.removal_unverified -eq $true -and $garbled.Result.removed_count -eq 0) "an unreadable answer from the removal is partial and unverified: $($garbled.Output -join ' | ')"
    $garbledFixture = New-Fixture
    [void](Enable-Retention -Fixture $garbledFixture)
    $garbled = Invoke-Apply -Fixture $garbledFixture -Python @{ GARBLE_STEP = 'apply-prune' }
    Assert-True ($garbled.ExitCode -eq 5 -and $garbled.Result.state -ceq 'space_pending' -and $garbled.Result.removed_count -eq 2) "an unreadable answer from freeing the space is space pending: $($garbled.Output -join ' | ')"
    Assert-True ($garbled.Result.history_recorded -eq $true -and (Get-LastHistoryEntry -Fixture $garbledFixture).outcome -ceq 'space_pending') 'it is recorded as space pending'
    $garbledFixture = New-Fixture
    [void](Enable-Retention -Fixture $garbledFixture)
    $garbled = Invoke-Apply -Fixture $garbledFixture -Python @{ GARBLE_STEP = 'apply-check' }
    Assert-True ($garbled.ExitCode -eq 6 -and $garbled.Result.state -ceq 'check_failed' -and $garbled.Result.check_unfinished -eq $true) "an unreadable answer from the check says the check did not finish: $($garbled.Output -join ' | ')"
    Assert-True ($garbled.Result.prune_completed -eq $true -and $garbled.Result.removed_count -eq 2) 'the space was freed before the check'
    Assert-True ((Get-LastHistoryEntry -Fixture $garbledFixture).check_unfinished -eq $true) 'the history says the check did not finish'

    # --- The progress note cannot be written after the removal: the rest is still reported as what it is ---
    $blockedFixture = New-Fixture
    [void](Enable-Retention -Fixture $blockedFixture)
    $blockedProgress = Invoke-Apply -Fixture $blockedFixture -Python @{
        BLOCK_PROGRESS_AFTER = 'apply-forget'; RESULT_ROOT = (Join-Path $blockedFixture.State 'RetentionManagerResults')
    }
    Assert-True ($blockedProgress.ExitCode -eq 5 -and $blockedProgress.Result.state -ceq 'space_pending' -and $blockedProgress.Result.removed_count -eq 2) "a progress note that cannot be written after the removal ends as space pending: $($blockedProgress.Output -join ' | ')"
    Assert-True ($blockedProgress.Result.history_recorded -eq $true) 'the removal is recorded'
    Assert-True ((Get-StoreIds -Fixture $blockedFixture).Count -eq 3) 'the two confirmed backups were removed'

    # --- The manager refuses to run from a copy outside the fixture's program folder ---
    $copy = Join-Path $fixture.Root 'Manage-Retention.ps1'
    Copy-Item -LiteralPath $managerSource -Destination $copy
    $wrongPlace = Invoke-Manager -Fixture $fixture -Action preview -ScriptPath $copy
    Assert-True ($wrongPlace.ExitCode -eq 1 -and $null -eq $wrongPlace.Result) 'the manager runs only from the installed path'

    if (-not $SkipInstalledChecks) {
        $productionHashAfter = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
        Assert-True ($productionHashBefore -eq $productionHashAfter) 'the installed configuration was not touched'
    }
    Write-Output "Manage-Retention tests passed: $assertions assertions."
}
finally {
    foreach ($name in $plantedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $compilerRoot) { Remove-Item -LiteralPath $compilerRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
