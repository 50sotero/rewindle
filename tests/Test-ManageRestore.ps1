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
  public static int Main(string[] args) {
    string log = Environment.GetEnvironmentVariable("FAKE_RESTIC_LOG");
    if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, String.Join("\t", args) + Environment.NewLine);
    string plan = Environment.GetEnvironmentVariable("FAKE_PLAN_ID");
    string source = Environment.GetEnvironmentVariable("FAKE_SOURCE");
    bool legacy = Environment.GetEnvironmentVariable("FAKE_LEGACY_SNAPSHOT") == "1";
    string snapshot = new String(legacy ? 'f' : 'b', 64);
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
      if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("RESTIC_PASSWORD"))) {
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
      string target = After(args, "--target"); Directory.CreateDirectory(target);
      if (Environment.GetEnvironmentVariable("FAKE_RESTORE_PARTIAL") == "1") {
        File.WriteAllText(Path.Combine(target, "partial.txt"), "retained partial data"); return 23;
      }
      int includeCount = args.Count(value => value == "--include");
      if (includeCount > 0 && !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("RESTIC_PASSWORD"))) {
        for (int i = 0; i < args.Length - 1; i++) if (args[i] == "--include") {
          string include = args[i + 1]; string[] parts = include.Split(new[] {'/'}, StringSplitOptions.RemoveEmptyEntries);
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
Add-Type -TypeDefinition $fakeResticSource -OutputAssembly $fakeRestic -OutputType ConsoleApplication

$pythonWrapper = Join-Path $compilerRoot 'python.exe'
$escapedPython = $realPython.Replace('\', '\\').Replace('"', '\"')
$pythonWrapperSource = @"
using System;
using System.Diagnostics;
using System.Text;
public static class PythonWrapper {
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
    ProcessStartInfo start = new ProcessStartInfo(); start.FileName = "$escapedPython";
    start.Arguments = String.Join(" ", Array.ConvertAll(args, Quote)); start.UseShellExecute = false;
    using (Process process = Process.Start(start)) { process.WaitForExit(); return process.ExitCode; }
  }
}
"@
Add-Type -TypeDefinition $pythonWrapperSource -OutputAssembly $pythonWrapper -OutputType ConsoleApplication

function New-Fixture {
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
    [IO.File]::WriteAllText((Join-Path $root 'RecoveryKey.txt'), "Password: fixture-recovery-password-material-that-is-long-enough-12345`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $repository 'config'), "repository config sentinel`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $repository 'pack'), "encrypted repository sentinel`n", $encoding)
    [IO.File]::WriteAllBytes((Join-Path $state 'run.lock'), [byte[]](0))
    $serial = Get-VolumeSerial -Path $repository
    $config = [ordered]@{
        schema_version = 1; plan_id = $planId; config_generation = $generation
        repository = $repository; repository_volume_serial = $serial
        restic_executable = Join-Path $install 'restic.exe'; recovery_tools_directory = $recovery
        python_executable = Join-Path $install 'Python\python.exe'; state_directory = $state
        secret_file = Join-Path $state 'missing-secret.json'; recovery_key_file = Join-Path $root 'RecoveryKey.txt'
        exclude_file = Join-Path $install 'excludes.txt'; canary_file = Join-Path $source 'canary.txt'
        hostname = 'FIXTURE'; scheduled_tag = 'scheduled'; use_vss = $false
        cloud_placeholder_policy = 'strict'; sources = @($source)
        source_identities = [ordered]@{ $source = [ordered]@{ expected_volume_serial = $serial } }
    }
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
    return [pscustomobject]@{
        Root=$root; Install=$install; State=$state; Repository=$repository; Recovery=$recovery;
        Source=$source; ConfigPath=$configPath; Log=$log
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
    if ($LegacyFixture) { $env:FAKE_LEGACY_SNAPSHOT = '1' }
    else { Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue }
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
        Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue
    }
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    $progress = if (Test-Path -LiteralPath ($resultPath + '.progress.json')) {
        Get-Content -LiteralPath ($resultPath + '.progress.json') -Raw | ConvertFrom-Json
    } else { $null }
    return [pscustomobject]@{ ExitCode=$exitCode; Result=$result; Progress=$progress; Output=$output; Nonce=$nonce; Digest=$digest; ConfigHash=$configHash }
}

$productionConfig = Join-Path $env:ProgramFiles 'ResticBackuper\backup-config.json'
$productionHashBefore = $null
$taskXmlBefore = $null
if (-not $SkipInstalledChecks) {
    $productionHashBefore = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
    $taskXmlBefore = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }
}

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
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'restored.txt') -PathType Leaf) 'verified restore target created'
    $verifiedHistory = Get-Content -LiteralPath (Join-Path $fixture.State 'restore-history.json') -Raw | ConvertFrom-Json
    Assert-True ($restore.Result.history_recorded -eq $true -and @($verifiedHistory.entries).Count -eq 1 -and $verifiedHistory.entries[0].verified -eq $true) 'verified restore is recorded in bounded protected history'

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
        'Get-SessionString', 'Get-SessionInteger', 'ConvertTo-SessionHello', 'ConvertTo-SessionRequest', 'Assert-RestoreSessionClient'
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
        if ($LegacyFixture) { $env:FAKE_LEGACY_SNAPSHOT = '1' } else { Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue }
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
        $interopFixture = New-Fixture
        [RestoreManagerTests.DisposableSessionLauncher]::TestRoot = $interopFixture.Root
        [RestoreManagerTests.DisposableSessionLauncher]::Launches = 0
        $env:FAKE_RESTIC_LOG = $interopFixture.Log
        $env:FAKE_PLAN_ID = $planId
        $env:FAKE_SOURCE = $interopFixture.Source
        Remove-Item Env:FAKE_LEGACY_SNAPSHOT -ErrorAction SilentlyContinue
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
            $interopTarget = [string](Join-Path $interopFixture.Root 'Restored\Interop')
            $interopIncludes = [System.Collections.Generic.List[string]]::new()
            $interopIncludes.Add('/notes.txt')
            $interopRestore = $sessionMethods['Restore'].Invoke($null, [object[]]@($interopConfiguration, $snapshotId, $interopTarget, $interopIncludes, $false, $interopHost, $null, $null, $null))
            Assert-True ($interopRestore.Succeeded -and $interopRestore.Report.Verified) ('the dashboard could not restore through a real session: ' + $interopRestore.ErrorMessage)
            Assert-True ([RestoreManagerTests.DisposableSessionLauncher]::Launches -eq 1) 'the dashboard asked for more than one session for two listings and a restore'
            Assert-True (-not [bool]$hostType.GetProperty('HasLiveSession', $memberFlags).GetValue($interopHost)) 'the dashboard kept a session after its one restore'
            $records = @(Get-ChildItem -LiteralPath (Join-Path $interopFixture.State 'RestoreManagerResults') -Filter '*.json' |
                Where-Object { $_.Name -match '^[0-9a-f]{64}\.json$' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ($records.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
                $records = @(Get-ChildItem -LiteralPath (Join-Path $interopFixture.State 'RestoreManagerResults') -Filter '*.json' |
                    Where-Object { $_.Name -match '^[0-9a-f]{64}\.json$' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            }
            Assert-True ($records.Count -eq 1 -and [string]$records[0].close_reason -ceq 'restore_completed' -and [int]$records[0].operations.list_tree -eq 1) 'the real session did not end after the dashboard''s restore'
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
        session_single_restore = 'passed'; session_timeouts = 'passed'; session_pipe_squatting = 'passed'
        dashboard_session_interop = $interopCheck
        production_untouched = $productionCheck
    } | ConvertTo-Json -Depth 3
}
finally {
    foreach ($name in @('FAKE_RESTIC_LOG','FAKE_PLAN_ID','FAKE_SOURCE','FAKE_RESTORE_PARTIAL','FAKE_LEGACY_SNAPSHOT')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
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
