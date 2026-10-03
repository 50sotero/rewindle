[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\Program Files\ResticBackuper\backup-config.json',
    [string]$DestinationRoot = (Join-Path $env:USERPROFILE 'GoogleDriveZipBackup'),
    [string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'ResticBackuperGoogleDriveSync'),
    [int]$WaitMinutes = 360,
    [int]$PollSeconds = 30,
    [int]$ProviderWaitMinutes = 1440,
    [int]$ProviderPollSeconds = 15,
    [switch]$SkipProviderVerification,
    [switch]$SkipRestoreVerification,
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backupTaskName = 'ResticBackuper'
$Source = $null
$Destination = $null
$repositoryId = $null
$destinationMode = $null
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$startedUtc = [DateTime]::UtcNow
$statusPath = Join-Path $StateRoot 'status.json'
$logDirectory = Join-Path $StateRoot 'logs'
$logPath = Join-Path $logDirectory ("sync-$runId.log")
$reportPath = Join-Path $StateRoot ("report-$runId.json")
$lockPath = Join-Path $StateRoot 'sync.lock'
$lockStream = $null
$runLockPath = $null
$runLockStream = $null
$lastRobocopyExitCode = $null
$planId = $null
$configGeneration = $null
$protectedConfigSha256 = $null
$backupRunId = $null
$snapshotId = $null
$commitManifestPath = $null
$commitInventoryPath = $null
$providerProofPath = $null
$stagingDirectory = $null
$stagingManifestPath = $null
$restoreProofPath = $null
$restoreTargetPath = $null
$providerUploadState = $null
$restoreVerificationState = $null
$restoreVerificationSource = $null
$anomalyReviewApproved = $false
$anomalyAcknowledgementPath = $null
$providerDeadlineUtc = $null

function Get-CanonicalLocalDirectoryPath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Label,
        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is missing."
    }
    if (-not [System.IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) {
        throw "$Label must be an absolute local drive path."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw "$Label must be on a local Windows drive."
    }
    if ($fullPath.Length -gt $root.Length) {
        $fullPath = $fullPath.TrimEnd('\')
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "$Label was not found: $fullPath"
    }
    return $fullPath
}

function Get-LocalVolumeSerial {
    param([Parameter(Mandatory)] [string]$Path)

    $drive = [System.IO.Path]::GetPathRoot($Path).Substring(0, 2).ToUpperInvariant()
    $escapedDrive = $drive.Replace("'", "''")
    $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$escapedDrive'" -ErrorAction Stop
    if ($null -eq $volume -or [string]::IsNullOrWhiteSpace([string]$volume.VolumeSerialNumber)) {
        throw "Could not read the volume serial for $drive"
    }
    if ([int]$volume.DriveType -ne 3) {
        throw "The repository must be on a fixed local drive; $drive has drive type $($volume.DriveType)."
    }
    return ([string]$volume.VolumeSerialNumber).ToUpperInvariant()
}

function Test-ResticRepositoryLayout {
    param([Parameter(Mandatory)] [string]$Repository)

    if (-not (Test-Path -LiteralPath (Join-Path $Repository 'config') -PathType Leaf)) {
        return $false
    }
    foreach ($directoryName in @('data', 'index', 'keys', 'snapshots')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Repository $directoryName) -PathType Container)) {
            return $false
        }
    }
    return $true
}

function Assert-RepositoryMetadata {
    param(
        [Parameter(Mandatory)] [object]$Metadata,
        [Parameter(Mandatory)] [string]$Label
    )

    $id = ([string]$Metadata.id).ToLowerInvariant()
    if ($id -notmatch '^[0-9a-f]{64}$') {
        throw "$Label returned an invalid repository ID."
    }
    $version = [int]$Metadata.version
    if ($version -notin @(1, 2)) {
        throw "$Label uses unsupported Restic repository version $version."
    }
    [pscustomobject]@{ id = $id; version = $version }
}

function Get-AuthenticatedRepositoryMetadata {
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [string]$ResticExecutable,
        [Parameter(Mandatory)] [string]$PasswordCommand,
        [switch]$AllowPlainConfig
    )

    if ($AllowPlainConfig) {
        try {
            $plainConfig = Get-Content -LiteralPath (Join-Path $Repository 'config') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            return Assert-RepositoryMetadata -Metadata $plainConfig -Label 'The plaintext staged repository configuration'
        }
        catch {
            # Restic v2 normally encrypts this file. Authenticate it below.
        }
    }

    $priorPasswordCommand = [Environment]::GetEnvironmentVariable('RESTIC_PASSWORD_COMMAND', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('RESTIC_PASSWORD_COMMAND', $PasswordCommand, 'Process')
        $repositoryConfigText = (& $ResticExecutable --repo $Repository --no-lock cat config 2>&1 | Out-String).Trim()
        $resticExitCode = $LASTEXITCODE
    }
    finally {
        [Environment]::SetEnvironmentVariable('RESTIC_PASSWORD_COMMAND', $priorPasswordCommand, 'Process')
    }
    if ($resticExitCode -ne 0) {
        throw "Restic could not authenticate and read $Repository (exit $resticExitCode): $repositoryConfigText"
    }
    try {
        $repositoryConfig = $repositoryConfigText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Restic returned an invalid repository configuration for $Repository`: $($_.Exception.Message)"
    }
    return Assert-RepositoryMetadata -Metadata $repositoryConfig -Label "Restic repository $Repository"
}

function Resolve-ProtectedRepository {
    param(
        [Parameter(Mandatory)] [string]$ProtectedConfigPath,
        [Parameter(Mandatory)] [string]$StagingRoot
    )

    $configFullPath = [System.IO.Path]::GetFullPath($ProtectedConfigPath)
    if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) {
        throw "Protected backup configuration not found: $configFullPath"
    }
    try {
        $config = Get-Content -LiteralPath $configFullPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Protected backup configuration is not valid JSON: $($_.Exception.Message)"
    }
    if ($config.schema_version -ne 1) {
        throw "Unsupported protected backup configuration schema: $($config.schema_version)"
    }
    foreach ($property in @(
        'repository', 'repository_volume_serial', 'restic_executable',
        'python_executable', 'secret_file', 'state_directory', 'plan_id',
        'config_generation'
    )) {
        if ($config.PSObject.Properties.Name -notcontains $property -or [string]::IsNullOrWhiteSpace([string]$config.$property)) {
            throw "Protected backup configuration is missing $property."
        }
    }

    $parsedPlanId = [Guid]::Empty
    if (-not [Guid]::TryParseExact([string]$config.plan_id, 'D', [ref]$parsedPlanId) -or
        [string]$config.plan_id -cne $parsedPlanId.ToString('D')) {
        throw 'Protected backup configuration has a non-canonical plan_id.'
    }
    if ($config.config_generation -isnot [int] -or
        [int]$config.config_generation -lt 1 -or
        [int]$config.config_generation -gt 2147483647) {
        throw 'Protected backup configuration has an invalid config_generation.'
    }

    $repository = Get-CanonicalLocalDirectoryPath -Path ([string]$config.repository) -Label 'Restic repository' -MustExist
    if (-not (Test-ResticRepositoryLayout -Repository $repository)) {
        throw "Restic repository layout is incomplete: $repository"
    }
    $expectedSerial = ([string]$config.repository_volume_serial).ToUpperInvariant()
    if ($expectedSerial -notmatch '^[0-9A-F]{8}$') {
        throw 'Protected backup configuration has an invalid repository_volume_serial.'
    }
    $actualSerial = Get-LocalVolumeSerial -Path $repository
    if (-not [string]::Equals($expectedSerial, $actualSerial, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Repository volume mismatch: expected $expectedSerial, observed $actualSerial."
    }

    $resticExecutable = [System.IO.Path]::GetFullPath([string]$config.restic_executable)
    $pythonExecutable = [System.IO.Path]::GetFullPath([string]$config.python_executable)
    $secretFile = [System.IO.Path]::GetFullPath([string]$config.secret_file)
    $stateDirectory = Get-CanonicalLocalDirectoryPath -Path ([string]$config.state_directory) -Label 'Protected state directory' -MustExist
    $secretStore = Join-Path (Split-Path -Parent $configFullPath) 'secret_store.py'
    foreach ($requiredFile in @($resticExecutable, $pythonExecutable, $secretFile, $secretStore)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Protected repository dependency not found: $requiredFile"
        }
    }

    $passwordCommand = '"' + $pythonExecutable + '" "' + $secretStore + '" reveal --secret-file "' + $secretFile + '"'
    $repositoryConfig = Get-AuthenticatedRepositoryMetadata -Repository $repository -ResticExecutable $resticExecutable -PasswordCommand $passwordCommand
    $resolvedRepositoryId = [string]$repositoryConfig.id

    $stagingBase = Get-CanonicalLocalDirectoryPath -Path $StagingRoot -Label 'Google Drive staging root' -MustExist
    if (Test-ResticRepositoryLayout -Repository $stagingBase) {
        throw 'Google Drive staging root must be the parent of repositories, not an existing Restic repository root.'
    }
    $repositoriesRoot = Join-Path $stagingBase 'Repositories'
    if (Test-ResticRepositoryLayout -Repository $repositoriesRoot) {
        throw 'Google Drive Repositories container must not itself be a Restic repository.'
    }

    $destination = Join-Path $repositoriesRoot $resolvedRepositoryId
    $destinationMode = 'repository_id'
    if (Test-ResticRepositoryLayout -Repository $destination) {
        $scopedConfig = Get-AuthenticatedRepositoryMetadata -Repository $destination -ResticExecutable $resticExecutable -PasswordCommand $passwordCommand -AllowPlainConfig
        if (-not [string]::Equals([string]$scopedConfig.id, $resolvedRepositoryId, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Repository-ID staging destination contains another repository: $destination"
        }
    }
    $defaultProtectedConfig = [System.IO.Path]::GetFullPath('C:\Program Files\ResticBackuper\backup-config.json')
    $runLockState = $stateDirectory
    if ([string]::Equals($configFullPath, $defaultProtectedConfig, [System.StringComparison]::OrdinalIgnoreCase)) {
        $runLockState = [System.IO.Path]::GetFullPath('C:\ProgramData\ResticBackuper')
        if (-not [string]::Equals($stateDirectory, $runLockState, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'The protected plan must be migrated to the canonical ProgramData state directory before off-site sync.'
        }
    }
    [pscustomobject]@{
        config_path = $configFullPath
        repository = $repository
        repository_id = $resolvedRepositoryId
        repository_version = [int]$repositoryConfig.version
        repository_volume_serial = $actualSerial
        destination_root = $stagingBase
        destination = $destination
        destination_mode = $destinationMode
        restic_executable = $resticExecutable
        python_executable = $pythonExecutable
        password_command = $passwordCommand
        state_directory = $stateDirectory
        run_lock_path = Join-Path $runLockState 'run.lock'
        plan_id = $parsedPlanId.ToString('D')
        config_generation = [int]$config.config_generation
        config_sha256 = (Get-FileHash -LiteralPath $configFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Value
    )

    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('j-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    $backupPath = Join-Path $directory (([System.IO.Path]::GetFileName($Path)) + '.' + [Guid]::NewGuid().ToString('N') + '.bak')
    $json = $Value | ConvertTo-Json -Depth 8
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-NewJson {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Value
    )

    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace immutable commit evidence: $Path"
    }
    $temporaryPath = Join-Path $directory ('j-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporaryPath, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Enter-SharedRunLock {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The protected run-lock handshake does not exist: $Path"
    }
    $lockItem = Get-Item -LiteralPath $Path -Force
    if (($lockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The protected run-lock handshake must not be a reparse point.'
    }
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        if ($stream.Length -lt 1) {
            throw 'The protected run-lock handshake is empty.'
        }
        $stream.Lock(0, 1)
        return $stream
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Exit-SharedRunLock {
    param([System.IO.FileStream]$Stream)
    if ($null -eq $Stream) { return }
    try { $Stream.Unlock(0, 1) } finally { $Stream.Dispose() }
}

function Read-VerifiedBackupEvidence {
    param([Parameter(Mandatory)] [object]$Resolved)

    $evidencePath = Join-Path ([string]$Resolved.state_directory) 'last-success.json'
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw 'No verified backup evidence exists for off-site promotion.'
    }
    $item = Get-Item -LiteralPath $evidencePath -Force
    if ([long]$item.Length -gt 8MB) {
        throw 'Verified backup evidence exceeds the protected size limit.'
    }
    try {
        $evidence = Get-Content -LiteralPath $evidencePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Verified backup evidence is invalid: $($_.Exception.Message)"
    }
    if ([string]$evidence.state -notin @('success', 'success_unchanged') -or
        $evidence.verification_complete -ne $true) {
        throw 'The latest backup is not a completed, verified snapshot.'
    }
    if ($evidence.PSObject.Properties.Name -notcontains 'verification' -or
        $null -eq $evidence.verification -or
        $evidence.verification.PSObject.Properties.Name -notcontains 'canary' -or
        $null -eq $evidence.verification.canary -or
        $evidence.verification.canary.verified -ne $true) {
        throw 'The latest backup has no successful restore-canary proof.'
    }
    if ([string]$evidence.repository_id -cne [string]$Resolved.repository_id -or
        [string]$evidence.plan_id -cne [string]$Resolved.plan_id -or
        [int]$evidence.config_generation -ne [int]$Resolved.config_generation) {
        throw 'The latest verified backup evidence does not bind the active repository plan.'
    }
    if ([string]$evidence.snapshot_id -notmatch '^[0-9a-f]{64}$') {
        throw 'The latest verified backup evidence has no canonical snapshot ID.'
    }
    $evidenceSha256 = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($evidence.PSObject.Properties.Name -contains 'maintenance_hold' -and
        $evidence.maintenance_hold -eq $true) {
        $reasons = @()
        if ($evidence.PSObject.Properties.Name -contains 'change_anomaly' -and
            $null -ne $evidence.change_anomaly -and
            $evidence.change_anomaly.PSObject.Properties.Name -contains 'reasons') {
            $reasons = @($evidence.change_anomaly.reasons)
        }
        $ackPath = Join-Path ([string]$Resolved.state_directory) 'anomaly-acknowledgement.json'
        $approved = $false
        if (Test-Path -LiteralPath $ackPath -PathType Leaf) {
            try {
                $ackItem = Get-Item -LiteralPath $ackPath -Force
                if ([long]$ackItem.Length -le 4MB) {
                    $ack = Get-Content -LiteralPath $ackPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $scopes = @($ack.scope)
                    $approved = [string]$ack.schema -ceq 'ResticBackuper.AnomalyReview.v1' -and
                        [int]$ack.schema_version -eq 1 -and
                        [string]$ack.decision -ceq 'approved' -and
                        $ack.maintenance_hold_remains -eq $true -and
                        $scopes -ccontains 'offsite_promotion' -and
                        [string]$ack.plan_id -ceq [string]$Resolved.plan_id -and
                        [int]$ack.config_generation -eq [int]$Resolved.config_generation -and
                        [string]$ack.repository_id -ceq [string]$Resolved.repository_id -and
                        [string]$ack.run_id -ceq [string]$evidence.run_id -and
                        [string]$ack.snapshot_id -ceq [string]$evidence.snapshot_id -and
                        [string]$ack.backup_evidence_sha256 -ceq $evidenceSha256
                }
            }
            catch { $approved = $false }
        }
        if (-not $approved) {
            $reasonText = if ($reasons.Count -gt 0) { ': ' + ($reasons -join ', ') } else { '' }
            throw "Off-site promotion is paused by the latest backup's anomaly hold$reasonText. Review the run before approving this exact generation."
        }
        $script:anomalyReviewApproved = $true
        $script:anomalyAcknowledgementPath = $ackPath
    }
    [pscustomobject]@{
        path = $evidencePath
        sha256 = $evidenceSha256
        document = $evidence
    }
}

function Initialize-CommitCandidate {
    param(
        [Parameter(Mandatory)] [System.Collections.IEnumerable]$Inventory,
        [Parameter(Mandatory)] [object]$Resolved
    )

    $repositoryPathKey = ([string]$Resolved.repository_id).Substring(0, 16)
    $commitDirectory = Join-Path (Join-Path ([string]$Resolved.destination_root) 'CommittedGenerations') $repositoryPathKey
    [System.IO.Directory]::CreateDirectory($commitDirectory) | Out-Null
    $identityPath = Join-Path $commitDirectory 'repository.json'
    if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
        try { $commitIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'The off-site commit identity record is invalid.' }
        if ([string]$commitIdentity.repository_id -cne [string]$Resolved.repository_id) {
            throw 'The shortened off-site commit path belongs to another repository.'
        }
    }
    else {
        Write-NewJson -Path $identityPath -Value ([ordered]@{
            schema_version = 1
            repository_id = [string]$Resolved.repository_id
            created_utc = [DateTime]::UtcNow.ToString('o')
        })
    }
    $inventoryFinal = Join-Path $commitDirectory ($runId + '.inventory.jsonl.gz')
    $inventoryTemporary = Join-Path $commitDirectory ('i-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
    if (Test-Path -LiteralPath $inventoryFinal) {
        throw 'The generated off-site commit identity already exists.'
    }

    $fileStream = $null
    $gzipStream = $null
    $writer = $null
    try {
        $fileStream = [System.IO.File]::Open($inventoryTemporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Compress, $true)
        $writer = [System.IO.StreamWriter]::new($gzipStream, [System.Text.UTF8Encoding]::new($false), 65536, $true)
        foreach ($entry in $Inventory) {
            $line = [ordered]@{
                relative_path = [string]$entry.relative_path
                length = [long]$entry.length
                sha256 = [string]$entry.sha256
                md5 = [string]$entry.md5
            } | ConvertTo-Json -Compress
            $writer.WriteLine($line)
        }
        $writer.Flush()
        $writer.Dispose(); $writer = $null
        $gzipStream.Dispose(); $gzipStream = $null
        $fileStream.Flush($true)
        $fileStream.Dispose(); $fileStream = $null
        [System.IO.File]::Move($inventoryTemporary, $inventoryFinal)
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $gzipStream) { $gzipStream.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        if (Test-Path -LiteralPath $inventoryTemporary -PathType Leaf) {
            Remove-Item -LiteralPath $inventoryTemporary -Force -ErrorAction SilentlyContinue
        }
    }
    $script:commitInventoryPath = $inventoryFinal
    [pscustomobject]@{
        commit_directory = $commitDirectory
        identity_path = $identityPath
        inventory_path = $inventoryFinal
        inventory_sha256 = (Get-FileHash -LiteralPath $inventoryFinal -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Publish-CommittedGeneration {
    param(
        [Parameter(Mandatory)] [object]$Candidate,
        [Parameter(Mandatory)] [object]$Resolved,
        [Parameter(Mandatory)] [object]$BackupEvidence,
        [Parameter(Mandatory)] [object]$ProviderProof,
        [Parameter(Mandatory)] [object]$RestoreProof,
        [Parameter(Mandatory)] [long]$SourceFiles,
        [Parameter(Mandatory)] [long]$SourceBytes,
        [Parameter(Mandatory)] [long]$ExtraFiles,
        [Parameter(Mandatory)] [string]$StagingManifestSha256
    )

    $committedUtc = [DateTime]::UtcNow.ToString('o')
    $providerFinal = Join-Path ([string]$Candidate.commit_directory) ($runId + '.provider.json')
    $manifestFinal = Join-Path ([string]$Candidate.commit_directory) ($runId + '.commit.json')
    if ((Test-Path -LiteralPath $providerFinal) -or (Test-Path -LiteralPath $manifestFinal)) {
        throw 'The generated off-site provider or commit proof already exists.'
    }
    $providerRecord = [ordered]@{
        schema_version = 1
        commit_id = $runId
        state = 'confirmed'
        confirmed_utc = [string]$ProviderProof.confirmed_utc
        provider = 'google_drive_for_desktop'
        provider_version = [string]$ProviderProof.provider_version
        expected_files = [long]$ProviderProof.expected_files
        expected_bytes = [long]$ProviderProof.expected_bytes
        pending_uploads = [long]$ProviderProof.pending_uploads
        queued_uploads = [long]$ProviderProof.queued_uploads
        pending_deletes = [long]$ProviderProof.pending_deletes
        metadata_operations = [long]$ProviderProof.metadata_operations
        evidence_fingerprint = [string]$ProviderProof.evidence_fingerprint
        stable_samples = 2
        stable_seconds = 30
    }
    Write-NewJson -Path $providerFinal -Value $providerRecord
    $script:providerProofPath = $providerFinal
    $manifest = [ordered]@{
        schema_version = 1
        commit_id = $runId
        state = 'committed'
        committed_utc = $committedUtc
        plan_id = [string]$Resolved.plan_id
        config_generation = [int]$Resolved.config_generation
        protected_config_sha256 = [string]$Resolved.config_sha256
        repository_id = [string]$Resolved.repository_id
        repository_version = [int]$Resolved.repository_version
        repository_volume_serial = [string]$Resolved.repository_volume_serial
        destination = [string]$Resolved.destination
        destination_mode = [string]$Resolved.destination_mode
        backup_run_id = [string]$BackupEvidence.document.run_id
        snapshot_id = [string]$BackupEvidence.document.snapshot_id
        backup_finished_utc = [string]$BackupEvidence.document.finished_utc
        backup_evidence_sha256 = [string]$BackupEvidence.sha256
        source_files = $SourceFiles
        source_bytes = $SourceBytes
        extra_files_preserved = $ExtraFiles
        inventory_format = 'json-lines+gzip'
        inventory_file = [System.IO.Path]::GetFileName([string]$Candidate.inventory_path)
        inventory_sha256 = [string]$Candidate.inventory_sha256
        staging_manifest_sha256 = $StagingManifestSha256
        run_lock_held_during_inventory_and_promotion = $true
        staged_outside_provider_root = $true
        atomic_file_promotion = $true
        staged_repository_authenticated = $true
        restic_check_complete = $true
        no_delete_copy = $true
        provider_upload_state = 'confirmed'
        provider_proof_file = [System.IO.Path]::GetFileName($providerFinal)
        provider_proof_sha256 = (Get-FileHash -LiteralPath $providerFinal -Algorithm SHA256).Hash.ToLowerInvariant()
        restore_verification_state = if ($RestoreProof.verified -eq $true) { 'verified' } else { 'skipped' }
        restore_verified = $RestoreProof.verified -eq $true
        restore_verification_source = if ($RestoreProof.verified -eq $true) { 'resident_google_drive_mirror' } else { $null }
        cloud_api_restore_verified = $false
        restore_canary_bytes = if ($RestoreProof.verified -eq $true) { [long]$RestoreProof.bytes } else { $null }
        restore_canary_sha256 = if ($RestoreProof.verified -eq $true) { [string]$RestoreProof.sha256 } else { $null }
        anomaly_review_approved = $anomalyReviewApproved
        anomaly_acknowledgement_sha256 = if ($anomalyReviewApproved) {
            (Get-FileHash -LiteralPath $anomalyAcknowledgementPath -Algorithm SHA256).Hash.ToLowerInvariant()
        } else { $null }
    }
    Write-NewJson -Path $manifestFinal -Value $manifest
    $script:commitManifestPath = $manifestFinal
    return [pscustomobject]@{
        manifest = $manifest
        manifest_path = $manifestFinal
        inventory_path = [string]$Candidate.inventory_path
        provider_path = $providerFinal
        latest_path = Join-Path ([string]$Candidate.commit_directory) 'latest.json'
    }
}

function Publish-LatestPointer {
    param(
        [Parameter(Mandatory)] [object]$Commit,
        [Parameter(Mandatory)] [object]$Resolved
    )

    Write-AtomicJson -Path ([string]$Commit.latest_path) -Value ([ordered]@{
        schema_version = 1
        repository_id = [string]$Resolved.repository_id
        commit_id = $runId
        manifest_file = [System.IO.Path]::GetFileName([string]$Commit.manifest_path)
        inventory_file = [System.IO.Path]::GetFileName([string]$Commit.inventory_path)
        provider_proof_file = [System.IO.Path]::GetFileName([string]$Commit.provider_path)
        committed_utc = [string]$Commit.manifest.committed_utc
        provider_upload_state = 'confirmed'
        restore_verification_state = [string]$Commit.manifest.restore_verification_state
    })
}

function New-SyncStatus {
    param(
        [Parameter(Mandatory)] [string]$State,
        [string]$Message,
        [Nullable[int]]$RobocopyExitCode,
        [Nullable[long]]$SourceFiles,
        [Nullable[long]]$SourceBytes,
        [Nullable[long]]$VerifiedFiles,
        [Nullable[long]]$VerifiedBytes,
        [Nullable[int]]$MissingFiles,
        [Nullable[int]]$SizeMismatches,
        [Nullable[int]]$ExtraFiles,
        [string]$ErrorMessage
    )

    [ordered]@{
        schema_version = 1
        run_id = $runId
        state = $State
        message = $Message
        source = $Source
        destination = $Destination
        config_path = [System.IO.Path]::GetFullPath($ConfigPath)
        repository_id = $repositoryId
        destination_mode = $destinationMode
        plan_id = $planId
        config_generation = $configGeneration
        protected_config_sha256 = $protectedConfigSha256
        backup_run_id = $backupRunId
        snapshot_id = $snapshotId
        staging_directory = $stagingDirectory
        staging_manifest = $stagingManifestPath
        commit_manifest = $commitManifestPath
        commit_inventory = $commitInventoryPath
        provider_proof = $providerProofPath
        provider_upload_state = $providerUploadState
        restore_verification_state = $restoreVerificationState
        restore_verified = $restoreVerificationState -eq 'verified'
        restore_verification_source = $restoreVerificationSource
        restore_proof = $restoreProofPath
        restore_target = $restoreTargetPath
        anomaly_review_approved = $anomalyReviewApproved
        anomaly_acknowledgement = $anomalyAcknowledgementPath
        started_utc = $startedUtc.ToString('o')
        updated_utc = [DateTime]::UtcNow.ToString('o')
        finished_utc = if ($State -in @('success', 'failed')) { [DateTime]::UtcNow.ToString('o') } else { $null }
        backup_task = $backupTaskName
        robocopy_exit_code = $RobocopyExitCode
        source_files = $SourceFiles
        source_bytes = $SourceBytes
        verified_files = $VerifiedFiles
        verified_bytes = $VerifiedBytes
        missing_files = $MissingFiles
        size_mismatches = $SizeMismatches
        extra_files = $ExtraFiles
        log_file = $logPath
        error = $ErrorMessage
    }
}

function Test-RepositoryBusy {
    try {
        $task = Get-ScheduledTask -TaskName $backupTaskName -ErrorAction Stop
        if ([string]$task.State -eq 'Running') {
            return $true
        }
    }
    catch [Microsoft.Management.Infrastructure.CimException] {
        # The repository lock check below remains authoritative if Task Scheduler
        # is temporarily unavailable.
    }
    catch [Microsoft.PowerShell.Cmdletization.Cim.CimJobException] {
        # The public off-site tool is optional and its disposable validation can
        # run before the main ResticBackuper scheduled task is installed.
    }

    $repositoryLocks = Join-Path $Source 'locks'
    if (Test-Path -LiteralPath $repositoryLocks) {
        return @(Get-ChildItem -LiteralPath $repositoryLocks -File -Force -ErrorAction SilentlyContinue).Count -gt 0
    }
    return $false
}

function Wait-ForIdleRepository {
    $deadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    while (Test-RepositoryBusy) {
        Write-AtomicJson -Path $statusPath -Value (New-SyncStatus -State 'waiting' -Message 'Waiting for the Restic repository to become idle.')
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "The Restic repository remained busy for $WaitMinutes minutes."
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-FileContentDigests {
    param([Parameter(Mandatory)] [string]$Path)

    $sha256 = [System.Security.Cryptography.IncrementalHash]::CreateHash(
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $md5 = [System.Security.Cryptography.IncrementalHash]::CreateHash(
        [System.Security.Cryptography.HashAlgorithmName]::MD5
    )
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $buffer = New-Object byte[] (1024 * 1024)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $sha256.AppendData($buffer, 0, $read)
            $md5.AppendData($buffer, 0, $read)
        }
        [pscustomobject]@{
            sha256 = ([System.BitConverter]::ToString($sha256.GetHashAndReset())).Replace('-', '').ToLowerInvariant()
            md5 = ([System.BitConverter]::ToString($md5.GetHashAndReset())).Replace('-', '').ToLowerInvariant()
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha256.Dispose()
        $md5.Dispose()
    }
}

function Get-RepositoryInventory {
    param(
        [Parameter(Mandatory)] [string]$Repository,
        [switch]$IncludeDigests
    )

    $repositoryFull = [System.IO.Path]::GetFullPath($Repository).TrimEnd('\')
    $locksPrefix = ([System.IO.Path]::GetFullPath((Join-Path $repositoryFull 'locks')).TrimEnd('\')) + '\'
    $items = Get-ChildItem -LiteralPath $repositoryFull -File -Recurse -Force -ErrorAction Stop |
        Where-Object { -not $_.FullName.StartsWith($locksPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object -Property FullName

    $inventory = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $items) {
        $relativePath = $item.FullName.Substring($repositoryFull.Length).TrimStart('\')
        $sha256 = $null
        $md5 = $null
        if ($IncludeDigests) {
            $digests = Get-FileContentDigests -Path $item.FullName
            $sha256 = [string]$digests.sha256
            $md5 = [string]$digests.md5
        }
        $inventory.Add([pscustomobject]@{
            relative_path = $relativePath
            length = [long]$item.Length
            sha256 = $sha256
            md5 = $md5
        })
    }
    return $inventory
}

function Compare-RepositoryInventories {
    param(
        [Parameter(Mandatory)] [System.Collections.IEnumerable]$Expected,
        [Parameter(Mandatory)] [System.Collections.IEnumerable]$Observed
    )

    $expectedByPath = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $observedByPath = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $Expected) {
        if ($expectedByPath.ContainsKey([string]$entry.relative_path)) {
            throw "The expected inventory contains a duplicate path: $($entry.relative_path)"
        }
        $expectedByPath.Add([string]$entry.relative_path, $entry)
    }
    foreach ($entry in $Observed) {
        if ($observedByPath.ContainsKey([string]$entry.relative_path)) {
            throw "The observed inventory contains a duplicate path: $($entry.relative_path)"
        }
        $observedByPath.Add([string]$entry.relative_path, $entry)
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    $mismatched = [System.Collections.Generic.List[string]]::new()
    $extra = [System.Collections.Generic.List[string]]::new()
    $verifiedFiles = 0L
    $verifiedBytes = 0L
    foreach ($path in $expectedByPath.Keys) {
        if (-not $observedByPath.ContainsKey($path)) {
            $missing.Add($path)
            continue
        }
        $expectedEntry = $expectedByPath[$path]
        $observedEntry = $observedByPath[$path]
        if ([long]$expectedEntry.length -ne [long]$observedEntry.length -or
            [string]$expectedEntry.sha256 -cne [string]$observedEntry.sha256 -or
            [string]$expectedEntry.md5 -cne [string]$observedEntry.md5) {
            $mismatched.Add($path)
            continue
        }
        $verifiedFiles++
        $verifiedBytes += [long]$expectedEntry.length
    }
    foreach ($path in $observedByPath.Keys) {
        if (-not $expectedByPath.ContainsKey($path)) {
            $extra.Add($path)
        }
    }

    [pscustomobject]@{
        missing = $missing
        mismatched = $mismatched
        extra = $extra
        verified_files = $verifiedFiles
        verified_bytes = $verifiedBytes
    }
}

function Get-PromotionRank {
    param([Parameter(Mandatory)] [string]$RelativePath)

    if ($RelativePath -ceq 'config') { return 0 }
    if ($RelativePath.StartsWith('keys\', [System.StringComparison]::OrdinalIgnoreCase)) { return 1 }
    if ($RelativePath.StartsWith('data\', [System.StringComparison]::OrdinalIgnoreCase)) { return 2 }
    if ($RelativePath.StartsWith('index\', [System.StringComparison]::OrdinalIgnoreCase)) { return 3 }
    if ($RelativePath.StartsWith('snapshots\', [System.StringComparison]::OrdinalIgnoreCase)) { return 4 }
    throw "The source repository contains an unsupported promotion path: $RelativePath"
}

function Stage-MissingRepositoryFiles {
    param(
        [Parameter(Mandatory)] [System.Collections.IEnumerable]$MissingEntries,
        [Parameter(Mandatory)] [string]$PayloadRoot
    )

    $stagedFiles = 0L
    $stagedBytes = 0L
    foreach ($entry in $MissingEntries) {
        [void](Get-PromotionRank -RelativePath ([string]$entry.relative_path))
        $sourcePath = Join-Path $Source ([string]$entry.relative_path)
        $stagedPath = Join-Path $PayloadRoot ([string]$entry.relative_path)
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $stagedPath)) | Out-Null
        if (Test-Path -LiteralPath $stagedPath -PathType Leaf) {
            $existingItem = Get-Item -LiteralPath $stagedPath -Force
            $existingDigests = Get-FileContentDigests -Path $stagedPath
            if ([long]$existingItem.Length -ne [long]$entry.length -or
                [string]$existingDigests.sha256 -cne [string]$entry.sha256 -or
                [string]$existingDigests.md5 -cne [string]$entry.md5) {
                throw "A retained staging file does not match its immutable source: $($entry.relative_path)"
            }
        }
        else {
            [System.IO.File]::Copy($sourcePath, $stagedPath, $false)
            $stagedItem = Get-Item -LiteralPath $stagedPath -Force
            $stagedDigests = Get-FileContentDigests -Path $stagedPath
            if ([long]$stagedItem.Length -ne [long]$entry.length -or
                [string]$stagedDigests.sha256 -cne [string]$entry.sha256 -or
                [string]$stagedDigests.md5 -cne [string]$entry.md5) {
                throw "The staged copy failed content verification: $($entry.relative_path)"
            }
        }
        $stagedFiles++
        $stagedBytes += [long]$entry.length
    }
    [pscustomobject]@{ files = $stagedFiles; bytes = $stagedBytes }
}

function Promote-StagedRepositoryFiles {
    param(
        [Parameter(Mandatory)] [System.Collections.IEnumerable]$Entries,
        [Parameter(Mandatory)] [string]$PayloadRoot
    )

    $payloadVolume = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($PayloadRoot))
    $destinationVolume = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Destination))
    if (-not [string]::Equals($payloadVolume, $destinationVolume, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The verified staging payload must share a volume with the destination for atomic promotion.'
    }

    $ordered = @($Entries | Sort-Object `
        @{ Expression = { Get-PromotionRank -RelativePath ([string]$_.relative_path) } }, `
        @{ Expression = { [string]$_.relative_path } })
    foreach ($entry in $ordered) {
        $stagedPath = Join-Path $PayloadRoot ([string]$entry.relative_path)
        $destinationPath = Join-Path $Destination ([string]$entry.relative_path)
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            $destinationItem = Get-Item -LiteralPath $destinationPath -Force
            $destinationDigests = Get-FileContentDigests -Path $destinationPath
            if ([long]$destinationItem.Length -ne [long]$entry.length -or
                [string]$destinationDigests.sha256 -cne [string]$entry.sha256 -or
                [string]$destinationDigests.md5 -cne [string]$entry.md5) {
                throw "Refusing to overwrite a non-identical off-site repository file: $($entry.relative_path)"
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
            throw "The verified staging payload is missing: $($entry.relative_path)"
        }
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
        [System.IO.File]::Move($stagedPath, $destinationPath)
    }
}

function Invoke-AuthenticatedResticCommand {
    param(
        [Parameter(Mandatory)] [object]$Resolved,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $priorPasswordCommand = [Environment]::GetEnvironmentVariable('RESTIC_PASSWORD_COMMAND', 'Process')
    try {
        [Environment]::SetEnvironmentVariable(
            'RESTIC_PASSWORD_COMMAND',
            [string]$Resolved.password_command,
            'Process'
        )
        $text = (& ([string]$Resolved.restic_executable) @Arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Environment]::SetEnvironmentVariable('RESTIC_PASSWORD_COMMAND', $priorPasswordCommand, 'Process')
    }
    [pscustomobject]@{ exit_code = [int]$exitCode; output = $text }
}

function Invoke-OffsiteRepositoryCheck {
    param([Parameter(Mandatory)] [object]$Resolved)

    $result = Invoke-AuthenticatedResticCommand -Resolved $Resolved -Arguments @(
        '--repo', $Destination,
        '--no-lock',
        '--no-cache',
        'check'
    )
    if ([int]$result.exit_code -ne 0) {
        throw "The staged off-site repository failed Restic check (exit $($result.exit_code))."
    }
    return $true
}

function Invoke-OffsiteRestoreVerification {
    param(
        [Parameter(Mandatory)] [object]$Resolved,
        [Parameter(Mandatory)] [object]$BackupEvidence
    )

    if ($SkipRestoreVerification) {
        $script:restoreVerificationState = 'skipped'
        return [pscustomobject]@{
            schema_version = 1
            verified = $false
            skipped = $true
            snapshot_id = [string]$BackupEvidence.document.snapshot_id
        }
    }

    $canary = $BackupEvidence.document.verification.canary
    $snapshotPath = [string]$canary.snapshot_path
    $expectedSha256 = [string]$canary.sha256
    $expectedBytes = [long]$canary.bytes
    if ([string]::IsNullOrWhiteSpace($snapshotPath) -or
        -not $snapshotPath.StartsWith('/', [System.StringComparison]::Ordinal) -or
        $snapshotPath.Contains('\') -or
        $expectedSha256 -notmatch '^[0-9a-f]{64}$' -or
        $expectedBytes -lt 0) {
        throw 'The latest verified backup evidence has invalid restore-canary metadata.'
    }
    $segments = @($snapshotPath.TrimStart('/').Split('/'))
    if ($segments.Count -lt 2 -or
        @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw 'The restore-canary path is not safe to materialize.'
    }

    $restoreRoot = Join-Path (Join-Path $StateRoot 'restore-tests') $runId
    if (Test-Path -LiteralPath $restoreRoot) {
        throw "The unique off-site restore target already exists: $restoreRoot"
    }
    [System.IO.Directory]::CreateDirectory($restoreRoot) | Out-Null
    $script:restoreTargetPath = $restoreRoot
    $script:restoreVerificationState = 'running'
    $script:restoreVerificationSource = 'resident_google_drive_mirror'
    $result = Invoke-AuthenticatedResticCommand -Resolved $Resolved -Arguments @(
        '--repo', $Destination,
        '--no-lock',
        '--no-cache',
        'restore', ([string]$BackupEvidence.document.snapshot_id),
        '--target', $restoreRoot,
        '--include', $snapshotPath,
        '--verify'
    )
    if ([int]$result.exit_code -ne 0) {
        throw "The independent off-site canary restore failed (exit $($result.exit_code))."
    }

    $relativeCanary = [string]::Join(
        [System.IO.Path]::DirectorySeparatorChar,
        $segments
    )
    $restoredCanary = Join-Path $restoreRoot $relativeCanary
    if (-not (Test-Path -LiteralPath $restoredCanary -PathType Leaf)) {
        throw 'The independent off-site restore did not materialize the expected canary.'
    }
    $restoredItem = Get-Item -LiteralPath $restoredCanary -Force
    $restoredDigests = Get-FileContentDigests -Path $restoredCanary
    if ([long]$restoredItem.Length -ne $expectedBytes -or
        [string]$restoredDigests.sha256 -cne $expectedSha256) {
        throw 'The independent off-site restore canary failed byte-for-byte verification.'
    }
    $script:restoreVerificationState = 'verified'
    [pscustomobject]@{
        schema_version = 1
        verified = $true
        skipped = $false
        verified_utc = [DateTime]::UtcNow.ToString('o')
        snapshot_id = [string]$BackupEvidence.document.snapshot_id
        source_kind = 'resident_google_drive_mirror'
        bytes = $expectedBytes
        sha256 = $expectedSha256
    }
}

function Invoke-GoogleDriveProviderProbe {
    param(
        [Parameter(Mandatory)] [object]$Resolved,
        [Parameter(Mandatory)] [string]$InventoryPath,
        [string[]]$ExtraFiles = @()
    )

    if ($SkipProviderVerification) {
        return [pscustomobject]@{
            confirmed = $false
            skipped = $true
            state = 'unconfirmed'
            evidence_fingerprint = $null
        }
    }
    $helper = Join-Path $PSScriptRoot 'verify_google_drive_upload.py'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "Google Drive provider verifier not found: $helper"
    }
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        $helper,
        '--destination-root', ([string]$Resolved.destination_root),
        '--repository', $Destination,
        '--inventory', $InventoryPath
    )) {
        $arguments.Add([string]$argument)
    }
    foreach ($extraFile in $ExtraFiles) {
        $arguments.Add('--extra-file')
        $arguments.Add([string]$extraFile)
    }
    $output = (& ([string]$Resolved.python_executable) @arguments 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    try {
        $document = if ([string]::IsNullOrWhiteSpace($output)) {
            $null
        } else {
            $output | ConvertFrom-Json -ErrorAction Stop
        }
    }
    catch {
        throw 'The Google Drive provider verifier returned invalid JSON.'
    }
    if ($exitCode -eq 0 -and $null -ne $document -and $document.confirmed -eq $true) {
        return $document
    }
    if ($exitCode -eq 2 -and $null -ne $document) {
        return $document
    }
    throw "Google Drive provider verification failed closed (exit $exitCode)."
}

function Wait-ForGoogleDriveProvider {
    param(
        [Parameter(Mandatory)] [object]$Resolved,
        [Parameter(Mandatory)] [string]$InventoryPath,
        [string[]]$ExtraFiles = @()
    )

    if ($SkipProviderVerification) {
        $script:providerUploadState = 'unconfirmed'
        return Invoke-GoogleDriveProviderProbe -Resolved $Resolved -InventoryPath $InventoryPath -ExtraFiles $ExtraFiles
    }
    if ($null -eq $script:providerDeadlineUtc) {
        $script:providerDeadlineUtc = [DateTime]::UtcNow.AddMinutes($ProviderWaitMinutes)
    }
    $deadline = [DateTime]$script:providerDeadlineUtc
    $firstFingerprint = $null
    $firstConfirmedUtc = $null
    while ($true) {
        $probe = Invoke-GoogleDriveProviderProbe -Resolved $Resolved -InventoryPath $InventoryPath -ExtraFiles $ExtraFiles
        if ($probe.confirmed -eq $true) {
            $fingerprint = [string]$probe.evidence_fingerprint
            if ($fingerprint -notmatch '^[0-9a-f]{64}$') {
                throw 'The Google Drive provider proof has an invalid evidence fingerprint.'
            }
            if ([string]::Equals($fingerprint, $firstFingerprint, [System.StringComparison]::Ordinal)) {
                if ($null -ne $firstConfirmedUtc -and
                    ([DateTime]::UtcNow - $firstConfirmedUtc).TotalSeconds -ge 30) {
                    $script:providerUploadState = 'confirmed'
                    return $probe
                }
            }
            else {
                $firstFingerprint = $fingerprint
                $firstConfirmedUtc = [DateTime]::UtcNow
            }
        }
        else {
            $firstFingerprint = $null
            $firstConfirmedUtc = $null
        }
        $script:providerUploadState = 'pending'
        Write-AtomicJson -Path $statusPath -Value (New-SyncStatus `
            -State 'awaiting_provider' `
            -Message 'The repository is locally verified; waiting for Google Drive to confirm every committed byte.')
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Google Drive did not confirm the committed inventory within $ProviderWaitMinutes minutes."
        }
        Start-Sleep -Seconds $ProviderPollSeconds
    }
}

try {
    if ($WaitMinutes -lt 0) { throw 'WaitMinutes must be zero or greater.' }
    if ($PollSeconds -lt 1) { throw 'PollSeconds must be at least one second.' }
    if ($ProviderWaitMinutes -lt 0) { throw 'ProviderWaitMinutes must be zero or greater.' }
    if ($ProviderPollSeconds -lt 1) { throw 'ProviderPollSeconds must be at least one second.' }

    $resolved = Resolve-ProtectedRepository -ProtectedConfigPath $ConfigPath -StagingRoot $DestinationRoot
    $Source = [string]$resolved.repository
    $Destination = [string]$resolved.destination
    $repositoryId = [string]$resolved.repository_id
    $destinationMode = [string]$resolved.destination_mode
    $runLockPath = [string]$resolved.run_lock_path
    $planId = [string]$resolved.plan_id
    $configGeneration = [int]$resolved.config_generation
    $protectedConfigSha256 = [string]$resolved.config_sha256
    if ($ValidateOnly) {
        $resolved | ConvertTo-Json -Depth 5
        exit 0
    }

    $sourceFullPath = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationFullPath = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $destinationRootFullPath = [System.IO.Path]::GetFullPath([string]$resolved.destination_root).TrimEnd('\')
    $stateRootFullPath = [System.IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
    $sourcePrefix = $sourceFullPath + '\'
    $destinationPrefix = $destinationFullPath + '\'
    $destinationRootPrefix = $destinationRootFullPath + '\'
    $stateRootPrefix = $stateRootFullPath + '\'
    if ($destinationFullPath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $sourceFullPath.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $sourceFullPath.Equals($destinationFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Source and destination must not overlap.'
    }
    if ($stateRootFullPath.StartsWith($destinationRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $destinationRootFullPath.StartsWith($stateRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $stateRootFullPath.Equals($destinationRootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The private staging state must remain outside the registered Google Drive root.'
    }
    $destinationRootItem = Get-Item -LiteralPath $destinationRootFullPath -Force
    if (($destinationRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The registered Google Drive Computers root must be an ordinary local directory.'
    }

    [System.IO.Directory]::CreateDirectory($StateRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        exit 0
    }

    Write-AtomicJson -Path $statusPath -Value (New-SyncStatus -State 'starting' -Message 'Preparing the Google Drive staging copy.')
    Wait-ForIdleRepository

    $lockDeadline = [DateTime]::UtcNow.AddMinutes($WaitMinutes)
    while ($null -eq $runLockStream) {
        try {
            $runLockStream = Enter-SharedRunLock -Path $runLockPath
        }
        catch [System.IO.IOException] {
            Write-AtomicJson -Path $statusPath -Value (New-SyncStatus -State 'waiting' -Message 'Waiting for another protected backup operation to release the shared run lock.')
            if ([DateTime]::UtcNow -ge $lockDeadline) {
                throw "The protected run lock remained busy for $WaitMinutes minutes."
            }
            Start-Sleep -Seconds $PollSeconds
        }
    }

    # Re-read all authoritative paths and identities after taking the same lock
    # used by backup and configuration managers. This closes the pre-lock race.
    $lockedResolved = Resolve-ProtectedRepository -ProtectedConfigPath $ConfigPath -StagingRoot $DestinationRoot
    if (-not [string]::Equals([string]$lockedResolved.run_lock_path, $runLockPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Protected state_directory changed while off-site sync waited for the run lock.'
    }
    $resolved = $lockedResolved
    $Source = [string]$resolved.repository
    $Destination = [string]$resolved.destination
    $repositoryId = [string]$resolved.repository_id
    $destinationMode = [string]$resolved.destination_mode
    $planId = [string]$resolved.plan_id
    $configGeneration = [int]$resolved.config_generation
    $protectedConfigSha256 = [string]$resolved.config_sha256

    foreach ($journalName in @('repository-relocation.journal.json', 'plan-migration.journal.json', 'credential-rotation.journal.json')) {
        $pendingJournal = Join-Path ([string]$resolved.state_directory) $journalName
        if ([System.IO.File]::Exists($pendingJournal) -or [System.IO.Directory]::Exists($pendingJournal)) {
            throw "A pending protected-operation journal ($journalName) blocks off-site promotion until recovery completes."
        }
    }
    $backupEvidence = Read-VerifiedBackupEvidence -Resolved $resolved
    $backupRunId = [string]$backupEvidence.document.run_id
    $snapshotId = [string]$backupEvidence.document.snapshot_id

    Write-AtomicJson -Path $statusPath -Value (New-SyncStatus `
        -State 'inventory' `
        -Message 'Hashing the locked primary repository and the existing off-site mirror.')
    $sourceInventory = @(Get-RepositoryInventory -Repository $Source -IncludeDigests)
    foreach ($entry in $sourceInventory) {
        [void](Get-PromotionRank -RelativePath ([string]$entry.relative_path))
    }
    $sourceFiles = [long]$sourceInventory.Count
    $sourceBytes = [long](($sourceInventory | Measure-Object -Property length -Sum).Sum)
    if (-not ($sourceInventory | Where-Object {
        [string]$_.relative_path -ceq ('snapshots\' + $snapshotId)
    })) {
        throw 'The locked primary repository inventory does not contain the verified snapshot object.'
    }

    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destinationItem = Get-Item -LiteralPath $Destination -Force
    if (($destinationItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The off-site repository destination must not be a reparse point.'
    }
    $existingDestinationInventory = @(Get-RepositoryInventory -Repository $Destination -IncludeDigests)
    foreach ($entry in $existingDestinationInventory) {
        [void](Get-PromotionRank -RelativePath ([string]$entry.relative_path))
    }
    $initialComparison = Compare-RepositoryInventories `
        -Expected $sourceInventory `
        -Observed $existingDestinationInventory
    if ($initialComparison.mismatched.Count -gt 0) {
        throw "The existing off-site repository contains $($initialComparison.mismatched.Count) same-path content mismatches; no file was overwritten."
    }
    $sourceByPath = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $sourceInventory) {
        $sourceByPath.Add([string]$entry.relative_path, $entry)
    }
    $missingEntries = @($initialComparison.missing | ForEach-Object { $sourceByPath[[string]$_] })
    $requiredNewBytes = 0L
    foreach ($entry in $missingEntries) {
        $requiredNewBytes += [long]$entry.length
    }

    $stagingDirectory = Join-Path (Join-Path $StateRoot 'staging') $runId
    $stagingPayload = Join-Path $stagingDirectory 'payload'
    [System.IO.Directory]::CreateDirectory($stagingPayload) | Out-Null
    $stagingManifestPath = Join-Path $stagingDirectory 'staging.json'
    $stagingDocument = [ordered]@{
        schema_version = 1
        run_id = $runId
        state = 'inventory_complete'
        created_utc = [DateTime]::UtcNow.ToString('o')
        repository_id = $repositoryId
        snapshot_id = $snapshotId
        source_files = $sourceFiles
        source_bytes = $sourceBytes
        required_new_files = [long]$missingEntries.Count
        required_new_bytes = $requiredNewBytes
        existing_verified_files = [long]$initialComparison.verified_files
        existing_verified_bytes = [long]$initialComparison.verified_bytes
        extra_files_preserved = [long]$initialComparison.extra.Count
        no_delete = $true
        no_overwrite = $true
    }
    Write-NewJson -Path $stagingManifestPath -Value $stagingDocument

    Write-AtomicJson -Path $statusPath -Value (New-SyncStatus `
        -State 'staging' `
        -Message 'Copying only missing immutable repository files into private staging.' `
        -SourceFiles $sourceFiles `
        -SourceBytes $sourceBytes `
        -VerifiedFiles ([long]$initialComparison.verified_files) `
        -VerifiedBytes ([long]$initialComparison.verified_bytes) `
        -MissingFiles ([int]$missingEntries.Count) `
        -SizeMismatches 0 `
        -ExtraFiles ([int]$initialComparison.extra.Count))
    $stageResult = Stage-MissingRepositoryFiles `
        -MissingEntries $missingEntries `
        -PayloadRoot $stagingPayload
    $stagingDocument.state = 'staged_verified'
    $stagingDocument.staged_files = [long]$stageResult.files
    $stagingDocument.staged_bytes = [long]$stageResult.bytes
    $stagingDocument.staged_utc = [DateTime]::UtcNow.ToString('o')
    Write-AtomicJson -Path $stagingManifestPath -Value $stagingDocument

    Write-AtomicJson -Path $statusPath -Value (New-SyncStatus `
        -State 'promoting' `
        -Message 'Promoting complete staged files atomically; snapshots are promoted last.' `
        -SourceFiles $sourceFiles `
        -SourceBytes $sourceBytes)
    Promote-StagedRepositoryFiles `
        -Entries $missingEntries `
        -PayloadRoot $stagingPayload
    $stagingDocument.state = 'promoted'
    $stagingDocument.promoted_utc = [DateTime]::UtcNow.ToString('o')
    Write-AtomicJson -Path $stagingManifestPath -Value $stagingDocument

    Write-AtomicJson -Path $statusPath -Value (New-SyncStatus `
        -State 'verifying' `
        -Message 'Rehashing the primary and off-site repositories after atomic promotion.')
    $finalSourceInventory = @(Get-RepositoryInventory -Repository $Source -IncludeDigests)
    $sourceStability = Compare-RepositoryInventories `
        -Expected $sourceInventory `
        -Observed $finalSourceInventory
    if ($sourceStability.missing.Count -gt 0 -or
        $sourceStability.mismatched.Count -gt 0 -or
        $sourceStability.extra.Count -gt 0) {
        throw 'The locked primary repository changed between inventory and final verification.'
    }
    $finalDestinationInventory = @(Get-RepositoryInventory -Repository $Destination -IncludeDigests)
    $verification = Compare-RepositoryInventories `
        -Expected $finalSourceInventory `
        -Observed $finalDestinationInventory
    if ($verification.missing.Count -gt 0 -or $verification.mismatched.Count -gt 0) {
        throw "Final off-site verification failed: $($verification.missing.Count) missing and $($verification.mismatched.Count) content-mismatched files."
    }
    $destinationFiles = [long]$finalDestinationInventory.Count
    $destinationBytes = [long](($finalDestinationInventory | Measure-Object -Property length -Sum).Sum)

    $stagedMetadata = Get-AuthenticatedRepositoryMetadata -Repository $Destination -ResticExecutable ([string]$resolved.restic_executable) -PasswordCommand ([string]$resolved.password_command) -AllowPlainConfig
    if (-not [string]::Equals([string]$stagedMetadata.id, $repositoryId, [System.StringComparison]::OrdinalIgnoreCase) -or
        [int]$stagedMetadata.version -ne [int]$resolved.repository_version) {
        throw 'The staged repository failed authenticated repository identity verification.'
    }
    [void](Invoke-OffsiteRepositoryCheck -Resolved $resolved)
    $restoreProof = Invoke-OffsiteRestoreVerification -Resolved $resolved -BackupEvidence $backupEvidence
    $restoreProofPath = Join-Path $stagingDirectory 'restore-proof.json'
    Write-NewJson -Path $restoreProofPath -Value $restoreProof

    $stagingDocument.state = 'locally_verified'
    $stagingDocument.locally_verified_utc = [DateTime]::UtcNow.ToString('o')
    $stagingDocument.destination_files = $destinationFiles
    $stagingDocument.destination_bytes = $destinationBytes
    $stagingDocument.missing_files = 0
    $stagingDocument.content_mismatches = 0
    $stagingDocument.extra_files_preserved = [long]$verification.extra.Count
    $stagingDocument.repository_authenticated = $true
    $stagingDocument.restic_check_complete = $true
    $stagingDocument.restore_verified = $restoreProof.verified -eq $true
    $stagingDocument.restore_proof_sha256 = (Get-FileHash -LiteralPath $restoreProofPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-AtomicJson -Path $stagingManifestPath -Value $stagingDocument
    $stagingManifestSha256 = (Get-FileHash -LiteralPath $stagingManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $candidate = Initialize-CommitCandidate `
        -Inventory $finalDestinationInventory `
        -Resolved $resolved

    # The primary repository is no longer needed after the exact local mirror,
    # Restic check, and independent restore have all succeeded.
    Exit-SharedRunLock -Stream $runLockStream
    $runLockStream = $null

    if ($SkipProviderVerification) {
        $providerUploadState = 'unconfirmed'
        $localOnly = New-SyncStatus `
            -State 'local_verified' `
            -Message 'The repository mirror is locally verified; provider confirmation was explicitly skipped.' `
            -SourceFiles $sourceFiles `
            -SourceBytes $sourceBytes `
            -VerifiedFiles ([long]$verification.verified_files) `
            -VerifiedBytes ([long]$verification.verified_bytes) `
            -MissingFiles 0 `
            -SizeMismatches 0 `
            -ExtraFiles ([int]$verification.extra.Count)
        Write-AtomicJson -Path $statusPath -Value $localOnly
        Write-AtomicJson -Path $reportPath -Value $localOnly
        exit 0
    }

    $providerProof = Wait-ForGoogleDriveProvider `
        -Resolved $resolved `
        -InventoryPath ([string]$candidate.inventory_path) `
        -ExtraFiles @([string]$candidate.identity_path, [string]$candidate.inventory_path)

    $commit = Publish-CommittedGeneration `
        -Candidate $candidate `
        -Resolved $resolved `
        -BackupEvidence $backupEvidence `
        -ProviderProof $providerProof `
        -RestoreProof $restoreProof `
        -SourceFiles $sourceFiles `
        -SourceBytes $sourceBytes `
        -ExtraFiles ([long]$verification.extra.Count) `
        -StagingManifestSha256 $stagingManifestSha256

    [void](Wait-ForGoogleDriveProvider `
        -Resolved $resolved `
        -InventoryPath ([string]$candidate.inventory_path) `
        -ExtraFiles @(
            [string]$candidate.identity_path,
            [string]$candidate.inventory_path,
            [string]$commit.provider_path,
            [string]$commit.manifest_path
        ))
    Publish-LatestPointer -Commit $commit -Resolved $resolved
    [void](Wait-ForGoogleDriveProvider `
        -Resolved $resolved `
        -InventoryPath ([string]$candidate.inventory_path) `
        -ExtraFiles @(
            [string]$candidate.identity_path,
            [string]$candidate.inventory_path,
            [string]$commit.provider_path,
            [string]$commit.manifest_path,
            [string]$commit.latest_path
        ))

    $providerUploadState = 'confirmed'
    $success = New-SyncStatus `
        -State 'success' `
        -Message 'The complete repository upload is confirmed, and a restore from the fully resident Google Drive mirror is verified.' `
        -SourceFiles $sourceFiles `
        -SourceBytes $sourceBytes `
        -VerifiedFiles ([long]$verification.verified_files) `
        -VerifiedBytes ([long]$verification.verified_bytes) `
        -MissingFiles 0 `
        -SizeMismatches 0 `
        -ExtraFiles ([int]$verification.extra.Count)
    Write-AtomicJson -Path $statusPath -Value $success
    Write-AtomicJson -Path $reportPath -Value $success
    exit 0
}
catch {
    if ($ValidateOnly) {
        Write-Error $_
        exit 1
    }
    $failure = New-SyncStatus `
        -State 'failed' `
        -Message 'The verified Google Drive mirror transaction failed.' `
        -RobocopyExitCode $lastRobocopyExitCode `
        -ErrorMessage $_.Exception.Message
    try { Write-AtomicJson -Path $statusPath -Value $failure } catch { }
    try { Write-AtomicJson -Path $reportPath -Value $failure } catch { }
    Write-Error $_
    exit 1
}
finally {
    if ($null -ne $runLockStream) {
        try { Exit-SharedRunLock -Stream $runLockStream } catch { }
        $runLockStream = $null
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}
