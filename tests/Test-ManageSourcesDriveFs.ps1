[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$sourceManager = Join-Path $projectRoot 'src\Manage-Sources.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot ('ResticBackuper-SourceManager-DriveFs-{0}' -f [Guid]::NewGuid().ToString('N'))
$encoding = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + "`n"), $encoding)
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-Record {
    param([string]$Name, [string]$Path, [string]$NameProperty)
    $result = [ordered]@{}
    $result[$NameProperty] = $Name
    $result['bytes'] = (Get-Item -LiteralPath $Path).Length
    $result['sha256'] = Get-Hash -Path $Path
    return $result
}

function Invoke-Manager {
    param([string]$Action, [string]$Path = '', [int]$FailAfterPublish = 0)
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:installedManager,
        '-ExpectedUserSid', $script:userSid,
        '-TestRoot', $fixtureRoot,
        '-TestAllowElevatedProcess'
    )
    if ($Action -in @('Add', 'Remove')) { $arguments += @("-$Action", $Path) }
    if ($FailAfterPublish -gt 0) {
        $arguments += @('-TestFailAfterPublish', [string]$FailAfterPublish)
    }
    $text = (& $powershell @arguments 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    try { $json = $text | ConvertFrom-Json }
    catch { throw "Manager did not return JSON. exit=$exitCode output=$text" }
    return [pscustomobject]@{ ExitCode = $exitCode; Json = $json; Text = $text }
}

function Set-FixtureAccess {
    # Writes repository_access (or takes it out, with $null) in the protected configuration, the recovery copy of it and
    # the recovery manifest, then rebinds the two manifests' records of the two configurations.
    param([AllowNull()] [object]$Live, [AllowNull()] [object]$RecoveryConfig, [AllowNull()] [object]$RecoveryManifest)
    foreach ($entry in @(
        [pscustomobject]@{ Path = $configPath; Value = $Live },
        [pscustomobject]@{ Path = $recoveryConfigPath; Value = $RecoveryConfig },
        [pscustomobject]@{ Path = $recoveryManifestPath; Value = $RecoveryManifest }
    )) {
        $json = Get-Content -LiteralPath $entry.Path -Raw | ConvertFrom-Json
        $property = $json.PSObject.Properties['repository_access']
        if ($null -eq $entry.Value) {
            if ($null -ne $property) { $json.PSObject.Properties.Remove('repository_access') }
        }
        elseif ($null -eq $property) { $json | Add-Member -NotePropertyName 'repository_access' -NotePropertyValue $entry.Value }
        else { $property.Value = $entry.Value }
        Write-JsonFile -Path $entry.Path -Value $json
    }
    foreach ($binding in @(
        [pscustomobject]@{ Manifest = $runtimeManifestPath; Property = 'relative_path'; File = $configPath },
        [pscustomobject]@{ Manifest = $recoveryManifestPath; Property = 'name'; File = $recoveryConfigPath }
    )) {
        $manifest = Get-Content -LiteralPath $binding.Manifest -Raw | ConvertFrom-Json
        $record = @($manifest.files | Where-Object { [string]$_.($binding.Property) -eq 'backup-config.json' })
        $record[0].bytes = (Get-Item -LiteralPath $binding.File).Length
        $record[0].sha256 = Get-Hash -Path $binding.File
        Write-JsonFile -Path $binding.Manifest -Value $manifest
    }
}

try {
    $installRoot = Join-Path $fixtureRoot 'ProgramFiles\ResticBackuper'
    $stateRoot = Join-Path $fixtureRoot 'ProgramData\ResticBackuper'
    $driveFsRoot = Join-Path $fixtureRoot 'DriveFs\My Drive'
    $driveFsCache = Join-Path $fixtureRoot 'LocalAppData\Google\DriveFS'
    $repository = Join-Path $driveFsRoot 'ResticBackups\Personal'
    $recoveryRoot = Join-Path $fixtureRoot 'ProgramData\ResticBackuperRecoveryTools'
    $sourceRoot = Join-Path $fixtureRoot 'Sources'
    $firstSource = Join-Path $sourceRoot 'Documents'
    $addSource = Join-Path $sourceRoot 'Pictures'
    $canarySource = Join-Path $stateRoot 'Canary'
    foreach ($directory in @(
        $installRoot, (Join-Path $installRoot 'Python'), $stateRoot, $repository,
        $driveFsCache, $recoveryRoot, $firstSource, $addSource, $canarySource
    )) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $script:installedManager = Join-Path $installRoot 'Manage-Sources.ps1'
    Copy-Item -LiteralPath $sourceManager -Destination $script:installedManager
    foreach ($file in @(
        (Join-Path $installRoot 'restic.exe'),
        (Join-Path $installRoot 'Python\python.exe'),
        (Join-Path $installRoot 'excludes.txt'),
        (Join-Path $repository 'config')
    )) {
        [IO.File]::WriteAllText($file, "fixture`n", $encoding)
    }
    $canary = Join-Path $canarySource 'backup-canary.txt'
    [IO.File]::WriteAllText($canary, "fixture canary`n", $encoding)

    $configPath = Join-Path $installRoot 'backup-config.json'
    $config = [ordered]@{
        schema_version = 1
        plan_id = '22222222-2222-4222-8222-222222222222'
        config_generation = 1
        repository = $repository
        repository_storage_mode = 'google_drivefs_stream'
        drivefs_my_drive_root = $driveFsRoot
        drivefs_cache_directory = $driveFsCache
        repository_volume_serial = 'A1B2C3D4'
        restic_executable = Join-Path $installRoot 'restic.exe'
        recovery_tools_directory = $recoveryRoot
        python_executable = Join-Path $installRoot 'Python\python.exe'
        state_directory = $stateRoot
        secret_file = Join-Path $stateRoot 'repository-password.dpapi.json'
        recovery_key_file = Join-Path $fixtureRoot 'RecoveryKey.txt'
        exclude_file = Join-Path $installRoot 'excludes.txt'
        canary_file = $canary
        hostname = 'DRIVEFS-FIXTURE'
        scheduled_tag = 'scheduled'
        cloud_placeholder_policy = 'strict'
        use_vss = $true
        sources = @($firstSource, $canarySource)
        source_identities = [ordered]@{
            $firstSource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
            $canarySource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
        }
    }
    Write-JsonFile -Path $configPath -Value $config

    $runtimeManifestPath = Join-Path $installRoot 'runtime-manifest.json'
    $runtimeFiles = @(
        Get-ChildItem -LiteralPath $installRoot -Recurse -File |
            Where-Object Name -ne 'runtime-manifest.json' |
            Sort-Object FullName
    )
    Write-JsonFile -Path $runtimeManifestPath -Value ([ordered]@{
        schema_version = 1
        product = 'ResticBackuper'
        version = 'test'
        created_utc = '2026-01-01T00:00:00Z'
        file_count = $runtimeFiles.Count
        files = @(
            foreach ($file in $runtimeFiles) {
                New-Record -Name $file.FullName.Substring($installRoot.Length + 1) `
                    -Path $file.FullName -NameProperty 'relative_path'
            }
        )
    })

    $recoveryConfig = [ordered]@{}
    foreach ($entry in $config.GetEnumerator()) {
        $recoveryConfig[$entry.Key] = $entry.Value
    }
    $recoveryConfig['restic_executable'] = 'X:\Standalone\restic.exe'
    $recoveryConfig['recovery_tools_directory'] = 'X:\Standalone\RecoveryTools'
    $recoveryConfig['python_executable'] = 'X:\Standalone\python.exe'
    $recoveryConfig['state_directory'] = 'X:\Standalone\state'
    $recoveryConfig['secret_file'] = 'X:\Standalone\secret.json'
    $recoveryConfig['recovery_key_file'] = 'X:\Standalone\recovery.txt'
    $recoveryConfig['exclude_file'] = 'X:\Standalone\excludes.txt'
    $recoveryConfig['standalone_marker'] = 'preserve-me'
    $recoveryConfigPath = Join-Path $recoveryRoot 'backup-config.json'
    foreach ($name in @('restic.exe', 'restore.py', 'secret_store.py', 'RECOVERY.md', 'restic-release.json')) {
        [IO.File]::WriteAllText((Join-Path $recoveryRoot $name), "fixture $name`n", $encoding)
    }
    Write-JsonFile -Path $recoveryConfigPath -Value $recoveryConfig
    $payloadNames = @('restic.exe', 'restore.py', 'secret_store.py', 'backup-config.json', 'RECOVERY.md', 'restic-release.json')
    $recoveryManifestPath = Join-Path $recoveryRoot 'recovery-manifest.json'
    Write-JsonFile -Path $recoveryManifestPath -Value ([ordered]@{
        schema_version = 1
        created_utc = '2026-01-01T00:00:00Z'
        repository = $repository
        standalone_manifest_marker = 'preserve-me'
        files = @(
            foreach ($name in $payloadNames) {
                New-Record -Name $name -Path (Join-Path $recoveryRoot $name) -NameProperty 'name'
            }
        )
    })

    $script:userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $list = Invoke-Manager -Action 'List'
    Assert-True ($list.ExitCode -eq 0 -and [bool]$list.Json.ok) "DriveFS list failed: $($list.Text)"

    $beforeRollback = @{}
    foreach ($path in @($configPath, $runtimeManifestPath, $recoveryConfigPath, $recoveryManifestPath)) {
        $beforeRollback[$path] = Get-Hash -Path $path
    }
    $rollback = Invoke-Manager -Action 'Add' -Path $addSource -FailAfterPublish 2
    Assert-True ($rollback.ExitCode -eq 1 -and [string]$rollback.Json.error -match 'rolled back') `
        "DriveFS source-update rollback failed: $($rollback.Text)"
    foreach ($path in $beforeRollback.Keys) {
        Assert-True ((Get-Hash -Path $path) -eq $beforeRollback[$path]) `
            "DriveFS rollback changed protected target: $path"
    }

    $add = Invoke-Manager -Action 'Add' -Path $addSource
    Assert-True ($add.ExitCode -eq 0 -and [bool]$add.Json.ok) "DriveFS add failed: $($add.Text)"
    $published = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $publishedRecovery = Get-Content -Raw -LiteralPath $recoveryConfigPath | ConvertFrom-Json
    Assert-True ([string]$published.repository_storage_mode -ceq 'google_drivefs_stream') `
        'DriveFS storage mode changed during source update'
    Assert-True ([string]$published.recovery_tools_directory -eq $recoveryRoot) `
        'live DriveFS recovery-tools root changed'
    Assert-True ([string]$publishedRecovery.recovery_tools_directory -eq 'X:\Standalone\RecoveryTools') `
        'standalone recovery-local tools path was overwritten'
    Assert-True (@($published.sources) -contains $addSource) 'DriveFS source was not added'
    Assert-True (@($publishedRecovery.sources) -contains $addSource) 'DriveFS recovery source was not added'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $repository) 'RecoveryTools'))) `
        'source manager created a forbidden RecoveryTools sibling on DriveFS'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $driveFsRoot 'RecoveryTools'))) `
        'source manager wrote recovery material into DriveFS'

    # Backups without a password in Google Drive (backup-config.json "repository_access"): the mode rides along with a
    # source change in the protected configuration and the recovery copy, and a recovery bundle that names the other mode
    # is refused. Everything above ran on a configuration without the key.
    Set-FixtureAccess -Live 'no_password' -RecoveryConfig 'no_password' -RecoveryManifest 'no_password'
    $noPasswordRemove = Invoke-Manager -Action 'Remove' -Path $addSource
    Assert-True ($noPasswordRemove.ExitCode -eq 0 -and [bool]$noPasswordRemove.Json.ok) `
        "DriveFS source change on backups without a password failed: $($noPasswordRemove.Text)"
    $publishedNoPassword = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $publishedNoPasswordRecovery = Get-Content -Raw -LiteralPath $recoveryConfigPath | ConvertFrom-Json
    Assert-True ([string]$publishedNoPassword.repository_access -ceq 'no_password' -and
        [string]$publishedNoPasswordRecovery.repository_access -ceq 'no_password' -and
        [string]$publishedNoPassword.repository_storage_mode -ceq 'google_drivefs_stream') `
        'a DriveFS source change keeps repository_access in the live configuration and the recovery copy'
    Assert-True (-not (@($publishedNoPassword.sources) -contains $addSource) -and
        -not (@($publishedNoPasswordRecovery.sources) -contains $addSource)) 'the DriveFS source was removed from both'
    Set-FixtureAccess -Live 'no_password' -RecoveryConfig $null -RecoveryManifest 'no_password'
    $beforeMismatch = @{}
    foreach ($path in @($configPath, $runtimeManifestPath, $recoveryConfigPath, $recoveryManifestPath)) {
        $beforeMismatch[$path] = Get-Hash -Path $path
    }
    $mismatch = Invoke-Manager -Action 'Add' -Path $addSource
    Assert-True ($mismatch.ExitCode -eq 1 -and [string]$mismatch.Json.error -match 'repository_access is not synchronized') `
        "a DriveFS recovery copy without the key beside no_password was not refused: $($mismatch.Text)"
    foreach ($path in $beforeMismatch.Keys) {
        Assert-True ((Get-Hash -Path $path) -eq $beforeMismatch[$path]) "a refused DriveFS source change changed $path"
    }

    $global:LASTEXITCODE = 0
    [pscustomobject]@{
        ok = $true
        tests = 6
        drivefs_separate_recovery_tools = 'passed'
        drivefs_journal_rollback = 'passed'
        drivefs_source_update = 'passed'
        standalone_recovery_paths_preserved = 'passed'
        drivefs_repository_access_kept = 'passed'
        drivefs_repository_access_mismatch_refused = 'passed'
    } | ConvertTo-Json -Depth 3
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $safePrefix = $temporaryRoot + '\ResticBackuper-SourceManager-DriveFs-'
    if ($resolvedFixture.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
