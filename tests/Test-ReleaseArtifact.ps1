[CmdletBinding()]
param(
    [string]$Artifact,
    [switch]$KeepWorkspace
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).TrimEnd('\')
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
if (-not $Artifact) {
    $Artifact = Join-Path $projectRoot "artifacts\Rewindle-v$version-windows-x64.zip"
}
$artifactPath = [IO.Path]::GetFullPath($Artifact)
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
    throw "Release artifact is missing: $artifactPath"
}

$workspaceName = 'ResticBackuper-integration-' + [Guid]::NewGuid().ToString('N')
$workspace = Join-Path ([IO.Path]::GetTempPath()) $workspaceName
$bundle = Join-Path $workspace 'bundle'
$runtime = Join-Path $workspace 'runtime'
$source = Join-Path $workspace 'source'
$repository = Join-Path $workspace 'repository'
$state = Join-Path $workspace 'state'
$recoveryTools = Join-Path $workspace 'RecoveryTools'
$recoveryKey = Join-Path $workspace 'RecoveryKey.txt'
$restoreTarget = Join-Path $workspace 'restored'
$drillTarget = Join-Path $workspace 'recovery-drill'
$drillReport = Join-Path $state 'artifact-recovery-drill.json'

function Invoke-EmbeddedPython {
    param([string[]]$Arguments)
    & (Join-Path $runtime 'Python\python.exe') -I -S -B @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Embedded Python command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

function Assert-PayloadManifest {
    $payload = Join-Path $bundle 'payload'
    $manifestPath = Join-Path $bundle 'payload-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.file_count -ne @($manifest.files).Count) {
        throw 'Payload manifest header/count is invalid.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = [IO.Path]::GetFullPath($payload).TrimEnd('\') + '\'
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.relative_path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..' -or -not $seen.Add($relative)) {
            throw "Unsafe manifest path: $relative"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $payload $relative))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Manifest path escapes payload: $relative"
        }
        $item = Get-Item -LiteralPath $path -Force
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($item.PSIsContainer -or $item.Length -ne [long]$entry.bytes -or $hash -ne [string]$entry.sha256) {
            throw "Payload verification failed: $relative"
        }
    }
    $actual = @(Get-ChildItem -LiteralPath $payload -Recurse -File -Force)
    if ($actual.Count -ne $manifest.file_count) {
        throw 'Payload file count differs from its manifest.'
    }
}

try {
    New-Item -ItemType Directory -Path $bundle, $runtime, $source | Out-Null
    Expand-Archive -LiteralPath $artifactPath -DestinationPath $bundle
    Assert-PayloadManifest
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $bundle 'payload') -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $runtime -Recurse
    }
    foreach ($offsitePayload in @(
        'verify_my_drive_cloud_repository.ps1',
        'verify_cloud_repository_inventory.py',
        'reveal-rclone-config-password.ps1',
        'install_google_drive_sync_task.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtime $offsitePayload) -PathType Leaf)) {
            throw "Optional direct Google Drive verification payload is missing: $offsitePayload"
        }
    }
    foreach ($recoveryPayload in @(
        'recovery_health.py',
        'restore.py',
        'Manage-Restore.ps1',
        'ResticBackuperDashboard.exe'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $runtime $recoveryPayload) -PathType Leaf)) {
            throw "Guided recovery payload is missing: $recoveryPayload"
        }
    }

    [IO.File]::WriteAllText((Join-Path $source 'document.txt'), 'integration backup version 1', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'notes.txt'), 'bounded representative restore sample', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'backup-canary.txt'), 'ResticBackuper integration restore canary', [Text.UTF8Encoding]::new($false))

    $driveRoot = [IO.Path]::GetPathRoot($workspace)
    $device = $driveRoot.TrimEnd('\').Replace("'", "''")
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$device'"
    if (-not $disk -or -not $disk.VolumeSerialNumber) {
        throw "Could not determine volume serial for $driveRoot"
    }
    $configPath = Join-Path $runtime 'backup-config.json'
    $fixtureVolumeSerial = ([string]$disk.VolumeSerialNumber).ToUpperInvariant()
    $configuration = [ordered]@{
        schema_version = 1
        plan_id = '87654321-4321-4abc-8def-1234567890ab'
        config_generation = 1
        repository = $repository
        repository_volume_serial = $fixtureVolumeSerial
        restic_executable = Join-Path $runtime 'restic.exe'
        recovery_tools_directory = $recoveryTools
        python_executable = Join-Path $runtime 'Python\python.exe'
        state_directory = $state
        secret_file = Join-Path $state 'repository-password.dpapi.json'
        recovery_key_file = $recoveryKey
        exclude_file = Join-Path $runtime 'excludes.txt'
        canary_file = Join-Path $source 'backup-canary.txt'
        hostname = 'ResticBackuperIntegration'
        scheduled_tag = 'integration'
        minimum_free_gib = 0
        read_concurrency = 2
        use_vss = $false
        structural_check_after_backup = $true
        read_data_subset_weekday = [DateTime]::Today.DayOfWeek.ToString()
        read_data_subset_parts = 30
        cloud_placeholder_policy = 'strict'
        change_anomaly = [ordered]@{
            enabled = $true
            file_change_ratio = 0.35
            deletion_ratio = 0.15
            data_added_ratio = 0.50
            minimum_changed_files = 1000
        }
        sources = @($source)
        source_identities = [ordered]@{}
    }
    $configuration.source_identities[$source] = [ordered]@{
        expected_volume_serial = $fixtureVolumeSerial
    }
    [IO.File]::WriteAllText($configPath, ($configuration | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

    Invoke-EmbeddedPython -Arguments @((Join-Path $runtime 'initialize_repository.py'), '--config', $configPath)
    Invoke-EmbeddedPython -Arguments @((Join-Path $runtime 'backup.py'), '--config', $configPath)
    if (-not (Test-Path -LiteralPath (Join-Path $state 'last-success.json') -PathType Leaf)) {
        throw 'First integration backup did not record a verified success.'
    }

    [IO.File]::WriteAllText((Join-Path $source 'document.txt'), 'integration backup version 2 with changed length', [Text.UTF8Encoding]::new($false))
    Invoke-EmbeddedPython -Arguments @((Join-Path $runtime 'backup.py'), '--config', $configPath)

    $lastSuccess = Get-Content -LiteralPath (Join-Path $state 'last-success.json') -Raw | ConvertFrom-Json
    $canaryProof = $lastSuccess.verification.canary
    $repositoryConfigHashBeforeDrill = (Get-FileHash -LiteralPath (Join-Path $repository 'config') -Algorithm SHA256).Hash
    $sourceHashesBeforeDrill = @{}
    foreach ($sourceFile in Get-ChildItem -LiteralPath $source -File) {
        $sourceHashesBeforeDrill[$sourceFile.Name] = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
    }
    Invoke-EmbeddedPython -Arguments @(
        (Join-Path $runtime 'restore.py'),
        '--config', $configPath,
        '--snapshot', [string]$lastSuccess.snapshot_id,
        '--target', $drillTarget,
        '--report', $drillReport,
        '--recovery-key-file', $recoveryKey,
        '--recovery-drill',
        '--drill-canary-sha256', [string]$canaryProof.sha256,
        '--drill-canary-bytes', [string]$canaryProof.bytes
    )
    $drill = Get-Content -LiteralPath $drillReport -Raw | ConvertFrom-Json
    $drillFiles = @(Get-ChildItem -LiteralPath $drillTarget -Recurse -File)
    if (-not $drill.verified -or [string]$drill.result -cne 'verified' -or
        [string]$drill.drill_kind -cne 'recovery_key_representative' -or
        [string]$drill.credential_source -cne 'recovery_key' -or
        -not $drill.canary_verified -or [int]$drill.sample_file_count -lt 2 -or
        $drillFiles.Count -ne ([int]$drill.sample_file_count + 1)) {
        throw 'Packaged recovery-key representative drill did not produce complete bounded evidence.'
    }
    if ((Get-FileHash -LiteralPath (Join-Path $repository 'config') -Algorithm SHA256).Hash -cne $repositoryConfigHashBeforeDrill) {
        throw 'Packaged recovery drill changed the repository configuration.'
    }
    foreach ($sourceFile in Get-ChildItem -LiteralPath $source -File) {
        if ($sourceHashesBeforeDrill[$sourceFile.Name] -cne (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash) {
            throw "Packaged recovery drill changed source data: $($sourceFile.Name)"
        }
    }

    Invoke-EmbeddedPython -Arguments @(
        (Join-Path $runtime 'restore.py'),
        '--config', $configPath,
        '--snapshot', 'latest',
        '--source', $source,
        '--target', $restoreTarget
    )
    $restoredDocuments = @(Get-ChildItem -LiteralPath $restoreTarget -Recurse -Filter 'document.txt' -File)
    if ($restoredDocuments.Count -ne 1 -or (Get-Content -LiteralPath $restoredDocuments[0].FullName -Raw) -ne 'integration backup version 2 with changed length') {
        throw 'Independent integration restore did not reproduce the latest source content.'
    }

    $snapshotsJson = & (Join-Path $runtime 'restic.exe') --repo $repository --password-command ((Join-Path $runtime 'Python\python.exe').Replace('\','/') + ' -I -S -B ' + (Join-Path $runtime 'secret_store.py').Replace('\','/') + ' reveal --secret-file ' + (Join-Path $state 'repository-password.dpapi.json').Replace('\','/')) snapshots --json
    if ($LASTEXITCODE -ne 0) { throw 'Could not query integration snapshots.' }
    # Windows PowerShell 5.1 can preserve a JSON array as one nested pipeline
    # object when ConvertFrom-Json is wrapped directly in @(...).
    $parsedSnapshots = $snapshotsJson | ConvertFrom-Json
    $snapshots = @($parsedSnapshots)
    if ($snapshots.Count -lt 2) {
        throw "Expected at least two integration snapshots; found $($snapshots.Count)."
    }

    [pscustomobject]@{
        artifact = $artifactPath
        artifact_sha256 = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        snapshots = $snapshots.Count
        verified_backups = 2
        independent_restore = $true
        recovery_key_drill = $true
        recovery_drill_files = $drillFiles.Count
        payload_manifest = $true
        workspace = if ($KeepWorkspace) { $workspace } else { $null }
    } | ConvertTo-Json -Depth 4
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $workspace)) {
        $resolved = [IO.Path]::GetFullPath($workspace)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\ResticBackuper-integration-'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne $workspaceName) {
            throw "Refusing to remove unexpected integration workspace: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
