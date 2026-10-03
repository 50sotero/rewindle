$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$managerSource = Join-Path $projectRoot 'src\Manage-Repository.ps1'
$python = (Get-Command python -ErrorAction Stop).Source
$powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$encoding = [Text.UTF8Encoding]::new($false)
$fixtureRoots = [Collections.Generic.List[string]]::new()
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
$fakeSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
public static class FakeRestic {
  static string ValueAfter(string[] args, string name) {
    int i = Array.IndexOf(args, name);
    if (i < 0 || i + 1 >= args.Length) throw new Exception("missing " + name);
    return args[i + 1];
  }
  public static int Main(string[] args) {
    string log = Environment.GetEnvironmentVariable("FAKE_RESTIC_LOG");
    if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, String.Join("\t", args) + Environment.NewLine);
    string repo = ValueAfter(args, "--repo");
    if (args.Contains("cat") && args.Contains("config")) {
      string id = File.ReadAllText(Path.Combine(repo, "repo-id.txt")).Trim();
      Console.WriteLine("{\"id\":\"" + id + "\"}");
      return 0;
    }
    if (args.Contains("snapshots")) {
      Console.WriteLine(File.ReadAllText(Path.Combine(repo, "snapshot-ids.json")));
      return 0;
    }
    if (args.Contains("check")) {
      if (Environment.GetEnvironmentVariable("FAKE_RESTIC_FAIL_CHECK") == "1") return 17;
      if (!File.Exists(Path.Combine(repo, "config")) || !File.Exists(Path.Combine(repo, "data", "pack-01"))) return 18;
      Console.WriteLine("repository check passed");
      return 0;
    }
    Console.Error.WriteLine("forbidden or unknown fake Restic command");
    return 91;
  }
}
'@
Add-Type -TypeDefinition $fakeSource -OutputAssembly $fakeRestic -OutputType ConsoleApplication

function New-Fixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('RRM-T-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
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
    foreach ($directory in @(
        $installRoot, (Join-Path $installRoot 'Python'), $stateRoot, $oldRepository,
        (Join-Path $oldRepository 'data'), (Join-Path $oldRepository 'locks'),
        $oldRecovery, $newParent, $source, $diagnostics
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

    [IO.File]::WriteAllText((Join-Path $oldRepository 'config'), "encrypted repository config`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $oldRepository 'repo-id.txt'), "fixture-repository-id`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $oldRepository 'snapshot-ids.json'), '[{"id":"snap-b"},{"id":"snap-a"}]', $encoding)
    [IO.File]::WriteAllBytes((Join-Path $oldRepository 'data\pack-01'), [byte[]](1..127))
    [IO.File]::WriteAllText((Join-Path $oldRepository 'locks\ephemeral'), "must not copy`n", $encoding)

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

    $manifestFiles = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force | Sort-Object FullName)
    $runtimeManifest = [ordered]@{
        schema_version = 1; created_utc = [DateTime]::UtcNow.ToString('o'); fixture_marker = 'preserve-me'
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
        Source=$source; Diagnostics=$diagnostics; PlanId=$planId; SourceSerial=$sourceSerial
    }
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
        [string]$DigestOverride = ''
    )
    $nonce = ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')).ToLowerInvariant()
    $configHash = Get-Hash -Path $Fixture.ConfigPath
    $digest = if ($DigestOverride) { $DigestOverride } else {
        Get-RequestDigest -Current $Fixture.OldRepository -New ([IO.Path]::GetFullPath($Destination).TrimEnd('\')) `
            -ConfigHash $configHash -Nonce $nonce
    }
    $resultPath = Join-Path $Fixture.StateRoot "RepositoryManagerResults\$nonce.json"
    $env:FAKE_RESTIC_LOG = $Fixture.Log
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $Fixture.InstallRoot 'Manage-Repository.ps1'), '-Relocate',
        '-NewRepository', $Destination, '-ExpectedUserSid', $sid,
        '-ExpectedCurrentRepository', $Fixture.OldRepository, '-ExpectedConfigSha256', $configHash,
        '-ResultPath', $resultPath, '-RequestNonce', $nonce, '-RequestDigest', $digest,
        '-TestRoot', $Fixture.Root, '-TestFailAfterPublish', $FailurePoint,
        '-TestCrashAfterPublish', $CrashPoint,
        '-TestCrashDuringCopyAfterFiles', $CrashDuringCopyAfterFiles,
        '-TestCrashAfterStageCreation', $CrashAfterStageCreation,
        '-TestCrashAfterEmptyDestinationRemoval', $CrashAfterEmptyDestinationRemoval,
        '-TestAvailableBytes', $AvailableBytes
    )
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $powershell @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorPreference }
    $result = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json } else { $null }
    $progressPath = $resultPath + '.progress.json'
    $progress = if (Test-Path -LiteralPath $progressPath) { Get-Content -LiteralPath $progressPath -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{
        ExitCode=$exitCode; Output=$output; Result=$result; Progress=$progress; ResultPath=$resultPath;
        Nonce=$nonce; Digest=$digest; ConfigHash=$configHash
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
$productionHashBefore = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
$taskXmlBefore = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }

try {
    # Successful copy-only relocation with full identity/history/check verification.
    $fixture = New-Fixture
    $oldRepositoryDigest = Get-TreeDigest -Root $fixture.OldRepository -ExcludeLocks
    $oldRecoveryDigest = Get-TreeDigest -Root $fixture.OldRecovery
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
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.NewRepository 'locks\ephemeral'))) 'repository locks excluded'
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
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.StateRoot 'repository-relocation.journal.json'))) 'success journal removed'
    $logText = Get-Content -LiteralPath $fixture.Log -Raw
    Assert-True ($logText -match '\tcat\tconfig' -and $logText -match '\tsnapshots\t--json' -and $logText -match '\tcheck') 'fake Restic verification commands used'
    Assert-True ($logText -notmatch '(?im)(^|\t)(backup|init|forget|prune|delete)(\t|$)') 'no history-creating or destructive Restic command'

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

    $driveFsCrashFixture = New-Fixture
    $driveFsCrashRoot = Join-Path $driveFsCrashFixture.Root 'DriveFs\My Drive'
    $driveFsCrashParent = Join-Path $driveFsCrashRoot 'ResticBackups'
    $driveFsCrashCache = Join-Path $driveFsCrashFixture.Root 'LocalAppData\Google\DriveFS'
    foreach ($directory in @($driveFsCrashRoot, $driveFsCrashParent, $driveFsCrashCache)) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    $driveFsCrashRepository = Join-Path $driveFsCrashParent 'Personal'
    $driveFsCrash = Invoke-Relocation -Fixture $driveFsCrashFixture `
        -Destination $driveFsCrashRepository -CrashPoint 1
    Assert-True ($driveFsCrash.ExitCode -ne 0) 'DriveFS post-promotion crash terminates'
    $driveFsRecoveryRun = Invoke-Recovery -Fixture $driveFsCrashFixture
    Assert-True ($driveFsRecoveryRun.ExitCode -eq 0 -and $driveFsRecoveryRun.Result.ok -eq $true) 'DriveFS post-promotion crash rolls back from protected journal'
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

    # All four activation failure points roll back protected files and owned copies.
    foreach ($point in 1..4) {
        $rollbackFixture = New-Fixture
        $configBefore = Get-Hash -Path $rollbackFixture.ConfigPath
        $manifestBefore = Get-Hash -Path $rollbackFixture.ManifestPath
        $repoBefore = Get-TreeDigest -Root $rollbackFixture.OldRepository -ExcludeLocks
        $recoveryBefore = Get-TreeDigest -Root $rollbackFixture.OldRecovery
        $rollbackRun = Invoke-Relocation -Fixture $rollbackFixture -Destination $rollbackFixture.NewRepository -FailurePoint $point
        Assert-True ($rollbackRun.ExitCode -ne 0 -and $rollbackRun.Result.ok -eq $false) "failure point $point reports failure"
        Assert-True ((Get-Hash -Path $rollbackFixture.ConfigPath) -eq $configBefore) "failure point $point restores config"
        Assert-True ((Get-Hash -Path $rollbackFixture.ManifestPath) -eq $manifestBefore) "failure point $point restores manifest"
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
        [pscustomobject]@{ Name='manifest_published'; Publish=4; Copy=0; Stage=0 }
    )
    foreach ($case in $crashCases) {
        $crashFixture = New-Fixture
        $crashConfigBefore = Get-Hash -Path $crashFixture.ConfigPath
        $crashManifestBefore = Get-Hash -Path $crashFixture.ManifestPath
        $crashRepoBefore = Get-TreeDigest -Root $crashFixture.OldRepository -ExcludeLocks
        $crashRecoveryBefore = Get-TreeDigest -Root $crashFixture.OldRecovery
        $crashRun = Invoke-Relocation -Fixture $crashFixture -Destination $crashFixture.NewRepository `
            -CrashPoint $case.Publish -CrashDuringCopyAfterFiles $case.Copy -CrashAfterStageCreation $case.Stage
        Assert-True ($crashRun.ExitCode -ne 0) "crash state $($case.Name) terminates process"
        Assert-True (Test-Path -LiteralPath (Join-Path $crashFixture.StateRoot 'repository-relocation.journal.json') -PathType Leaf) "crash state $($case.Name) leaves durable journal"
        $recoveryRun = Invoke-Recovery -Fixture $crashFixture
        Assert-True ($recoveryRun.ExitCode -eq 0 -and $recoveryRun.Result.ok -eq $true) "crash state $($case.Name) reconciles on dedicated recovery"
        Assert-True ([string]$recoveryRun.Result.action -eq 'recover') "crash state $($case.Name) recovery result action"
        Assert-True ([string]$recoveryRun.Result.expected_journal_sha256 -eq $recoveryRun.JournalHash) "crash state $($case.Name) recovery journal binding"
        Assert-True ([string]$recoveryRun.Result.old_repository -eq $crashFixture.OldRepository) "crash state $($case.Name) recovery old path"
        Assert-True ([string]$recoveryRun.Result.new_repository -eq $crashFixture.NewRepository) "crash state $($case.Name) recovery requested path"
        Assert-True ($recoveryRun.Result.old_repository_retained -eq $true) "crash state $($case.Name) recovery retention boolean"
        Assert-True ((Get-Hash -Path $crashFixture.ConfigPath) -eq $crashConfigBefore) "crash state $($case.Name) restores config"
        Assert-True ((Get-Hash -Path $crashFixture.ManifestPath) -eq $crashManifestBefore) "crash state $($case.Name) restores manifest"
        Assert-True ((Get-TreeDigest -Root $crashFixture.OldRepository -ExcludeLocks) -eq $crashRepoBefore) "crash state $($case.Name) retains old repository"
        Assert-True ((Get-TreeDigest -Root $crashFixture.OldRecovery) -eq $crashRecoveryBefore) "crash state $($case.Name) retains old recovery"
        Assert-True (-not (Test-Path -LiteralPath $crashFixture.NewRepository)) "crash state $($case.Name) removes proven owned destination"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $crashFixture.NewParent 'RecoveryTools'))) "crash state $($case.Name) removes proven owned recovery"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $crashFixture.StateRoot 'repository-relocation.journal.json'))) "crash state $($case.Name) clears journal"
    }

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
    $builderText = Get-Content -LiteralPath (Join-Path $projectRoot 'build\Build-Release.ps1') -Raw
    $installerText = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Install-ResticBackuper.ps1') -Raw
    $commonText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\restic_common.py') -Raw
    Assert-True ($builderText -match "'Manage-Repository\.ps1'") 'release builder packages repository manager'
    Assert-True ($installerText -match "'Manage-Repository\.ps1'") 'installer requires repository manager payload'
    Assert-True ($commonText -match 'repository-relocation\.journal\.json' -and $commonText -match 'pending protected-operation journal') 'Python backup loader blocks pending relocation journal'

    # Failed Restic check never activates the copy.
    $checkFixture = New-Fixture
    $env:FAKE_RESTIC_FAIL_CHECK = '1'
    try { $checkRun = Invoke-Relocation -Fixture $checkFixture -Destination $checkFixture.NewRepository }
    finally { Remove-Item Env:FAKE_RESTIC_FAIL_CHECK -ErrorAction SilentlyContinue }
    Assert-True ($checkRun.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $checkFixture.NewRepository)) 'failed check prevents activation'
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

    $productionHashAfter = if (Test-Path -LiteralPath $productionConfig) { Get-Hash -Path $productionConfig } else { $null }
    $taskXmlAfter = try { (Export-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction Stop).Replace("`r`n", "`n") } catch { $null }
    Assert-True ($productionHashAfter -eq $productionHashBefore) 'production protected config untouched'
    Assert-True ($taskXmlAfter -ceq $taskXmlBefore) 'production scheduled task untouched'

    [ordered]@{
        test = 'Manage-Repository'
        assertions = $assertions
        disposable_roots = $fixtureRoots.Count
        success_copy_and_verify = 'passed'
        empty_destination = 'passed'
        unsafe_destinations_and_capacity = 'passed'
        activation_rollback_points = 4
        abrupt_termination_recovery_states = $crashCases.Count
        empty_destination_removal_crash_states = 2
        existing_empty_acl_and_attributes_restored = 'passed'
        protected_staging_and_activation_acl_contract = 'passed'
        drivefs_staging_manifest_and_ntfs_recovery = 'passed'
        drivefs_crash_recovery = 'passed'
        installer_style_canary_state_exception = 'passed'
        pending_journal_backup_gate = 'passed'
        fake_restic_no_backup_or_init = 'passed'
        old_repository_retention = 'passed'
        production_config_untouched = 'passed'
        production_task_untouched = 'passed'
    } | ConvertTo-Json -Compress
}
finally {
    Remove-Item Env:FAKE_RESTIC_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_RESTIC_FAIL_CHECK -ErrorAction SilentlyContinue
    foreach ($root in $fixtureRoots) {
        if (Test-Path -LiteralPath $root) {
            $full = [IO.Path]::GetFullPath($root)
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
                [IO.Path]::GetFileName($full).StartsWith('RRM-T-', [StringComparison]::Ordinal)) {
                Remove-Item -LiteralPath $full -Recurse -Force
            }
        }
    }
    if (Test-Path -LiteralPath $compilerRoot) { Remove-Item -LiteralPath $compilerRoot -Recurse -Force }
}
