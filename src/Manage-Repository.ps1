[CmdletBinding(DefaultParameterSetName = 'Relocate')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Relocate')]
    [switch]$Relocate,
    [Parameter(Mandatory = $true, ParameterSetName = 'Relocate')]
    [string]$NewRepository,
    [Parameter(Mandatory = $true, ParameterSetName = 'Recover')]
    [switch]$Recover,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedUserSid,
    [Parameter(Mandatory = $true, ParameterSetName = 'Relocate')]
    [string]$ExpectedCurrentRepository,
    [Parameter(Mandatory = $true, ParameterSetName = 'Relocate')]
    [string]$ExpectedConfigSha256,
    [Parameter(Mandatory = $true, ParameterSetName = 'Recover')]
    [string]$ExpectedJournalSha256,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath,
    [Parameter(Mandatory = $true)]
    [string]$RequestNonce,
    [Parameter(Mandatory = $true)]
    [string]$RequestDigest,
    [string]$TestRoot,
    [ValidateRange(0, 4)]
    [int]$TestFailAfterPublish = 0,
    [ValidateRange(0, 4)]
    [int]$TestCrashAfterPublish = 0,
    [ValidateRange(0, 1000000)]
    [int]$TestCrashDuringCopyAfterFiles = 0,
    [ValidateRange(0, 2)]
    [int]$TestCrashAfterStageCreation = 0,
    [ValidateRange(0, 2)]
    [int]$TestCrashAfterEmptyDestinationRemoval = 0,
    [long]$TestAvailableBytes = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot

$productName = 'ResticBackuper'
$requestDomain = 'ResticBackuper.RepositoryRequest.v1'
$recoveryRequestDomain = 'ResticBackuper.RepositoryRecoveryRequest.v1'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$localAppDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$isTestMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
if ($isTestMode) {
    $testContainer = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ($testContainer -eq $temporaryRoot -or
        -not $testContainer.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable test root must be a child of the current user temporary directory.'
    }
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramFiles\$productName")).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramData\$productName")).TrimEnd('\')
}
else {
    $installRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $programDataRoot $productName)).TrimEnd('\')
}

$localNtfsMode = 'local_ntfs'
$driveFsMode = 'google_drivefs_stream'
$expectedDriveFsRoot = if ($isTestMode) {
    [IO.Path]::GetFullPath((Join-Path $testContainer 'DriveFs\My Drive')).TrimEnd('\')
} else { 'G:\My Drive' }
$expectedDriveFsCache = if ($isTestMode) {
    [IO.Path]::GetFullPath((Join-Path $testContainer 'LocalAppData\Google\DriveFS')).TrimEnd('\')
} else {
    [IO.Path]::GetFullPath((Join-Path $localAppDataRoot 'Google\DriveFS')).TrimEnd('\')
}
$driveFsRecoveryRoot = if ($isTestMode) {
    [IO.Path]::GetFullPath((Join-Path $testContainer 'ProgramData\ResticBackuperRecoveryTools')).TrimEnd('\')
} else {
    [IO.Path]::GetFullPath((Join-Path $programDataRoot 'ResticBackuperRecoveryTools')).TrimEnd('\')
}
$driveFsObjectLimitBytes = [long]4GB
$minimumDriveFsCacheBytes = [long]10GB

$configPath = Join-Path $installRoot 'backup-config.json'
$runtimeManifestPath = Join-Path $installRoot 'runtime-manifest.json'
$lockPath = Join-Path $stateRoot 'run.lock'
$journalPath = Join-Path $stateRoot 'repository-relocation.journal.json'
$resultRoot = Join-Path $stateRoot 'RepositoryManagerResults'
$Action = $PSCmdlet.ParameterSetName
$currentSid = $null
$canonicalCurrent = $null
$canonicalNew = $null
$canonicalConfigHash = $null
$canonicalNonce = $null
$canonicalDigest = $null
$canonicalJournalHash = $null
$resultChannelReady = $false
$progressPath = $null
$lockStream = $null
$repositoryStage = $null
$recoveryStage = $null
$newRecovery = $null
$journalReady = $false
$repositoryPromoted = $false
$recoveryPromoted = $false
$destinationInitiallyExisted = $false
$recoveryInitiallyExisted = $false
$destinationOriginalSddl = $null
$recoveryOriginalSddl = $null
$destinationOriginalAttributes = 0
$recoveryOriginalAttributes = 0
$originalConfigBytes = $null
$originalManifestBytes = $null
$filesTotal = 0L
$bytesTotal = 0L
$filesCopied = 0L
$bytesCopied = 0L
$copyStartedUtc = $null
$lastProgressUtc = [DateTime]::MinValue
$recoveredOldRepository = $null
$recoveredOldRecovery = $null
$recoveredNewRepository = $null
$recoveredNewRecovery = $null
$planId = $null
$previousConfigGeneration = $null
$newConfigGeneration = $null
$sourceStorageMode = $null
$destinationStorageMode = $null
$destinationDriveFsRoot = $null
$destinationDriveFsCache = $null
$repositoryManifestSha256 = $null

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PathEqual {
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsWithin {
    param([string]$Candidate, [string]$Parent)
    if (Test-PathEqual -Left $Candidate -Right $Parent) { return $true }
    return $Candidate.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoOverlap {
    param([string]$Candidate, [string]$Other, [string]$Message)
    if ((Test-IsWithin -Candidate $Candidate -Parent $Other) -or
        (Test-IsWithin -Candidate $Other -Parent $Candidate)) {
        throw "$Message`: $Candidate and $Other"
    }
}

function Get-CanonicalLocalPath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [IO.Path]::IsPathRooted($Value) -or
        $Value.StartsWith('\\')) {
        throw "Only an absolute local drive-letter path is supported: $Value"
    }
    $full = [IO.Path]::GetFullPath($Value)
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$' -or $full.Substring(2).Contains(':')) {
        throw "Only a normal local drive-letter path is supported: $Value"
    }
    if (-not (Test-PathEqual -Left $full -Right $root)) { $full = $full.TrimEnd('\') }
    return $full
}

function Assert-NormalDirectoryChain {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Directory does not exist or is offline: $Directory"
    }
    $current = Get-Item -LiteralPath $Directory -Force
    while ($null -ne $current) {
        if (-not $current.PSIsContainer -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Directory path contains a reparse point or non-directory component: $($current.FullName)"
        }
        $parent = $current.Parent
        if ($null -eq $parent) { break }
        $current = Get-Item -LiteralPath $parent.FullName -Force
    }
}

function Assert-NormalFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "Required regular file is missing: $File" }
    $item = Get-Item -LiteralPath $File -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Path is not a normal file: $File"
    }
    return $item
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-FileSha256Hex {
    param([string]$File)
    $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function ConvertTo-Utf8JsonBytes {
    param([object]$Value)
    return [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30) + "`n")
}

function Read-JsonObject {
    param([string]$File)
    [void](Assert-NormalFile -File $File)
    $bytes = [IO.File]::ReadAllBytes($File)
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $json = $text | ConvertFrom-Json
    if ($null -eq $json -or $json -isnot [Management.Automation.PSCustomObject]) {
        throw "Expected one JSON object: $File"
    }
    return [pscustomobject]@{ Json = $json; RawBytes = $bytes }
}

function Set-JsonProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function New-ResultDirectorySecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $security.SetOwner($administrators)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [Security.AccessControl.PropagationFlags]::None, $allow))
    }
    $readRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText), $readRights,
            $inheritance, [Security.AccessControl.PropagationFlags]::None, $allow))
    }
    return $security
}

function New-ResultFileSecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $security.SetOwner($administrators)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    }
    $readRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText), $readRights, $allow))
    }
    return $security
}

function Assert-ResultAcl {
    param([string]$Path, [string]$UserSid)
    if ($isTestMode) { return }
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -or -not $acl.AreAccessRulesProtected) {
        throw "Protected result path has an unsafe owner or inherited ACL: $Path"
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $UserSid)
    $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed) { throw "Protected result path has an unexpected ACL identity: $sid" }
        if ($sid -notin @('S-1-5-18', 'S-1-5-32-544') -and ($rule.FileSystemRights -band $dangerous) -ne 0) {
            throw "Protected result path grants write-capable rights to $sid"
        }
        [void]$seen.Add($sid)
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $UserSid)) {
        if (-not $seen.Contains($sid)) { throw "Protected result ACL is missing $sid" }
    }
}

function New-ProtectedFileSecurity {
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $security.SetOwner($administrators)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    }
    $readRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($currentSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText), $readRights, $allow))
    }
    return $security
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value, [ValidateSet('Result','Protected','Ordinary')][string]$Kind)
    $bytes = ConvertTo-Utf8JsonBytes -Value $Value
    $parent = Split-Path -Parent $Path
    # Keep this short for Windows PowerShell 5.1 callers that do not have long-path support.
    $temporary = Join-Path $parent ('.rr-{0}.tmp' -f [Guid]::NewGuid().ToString('N').Substring(0, 12))
    $stream = $null
    try {
        if (-not $isTestMode -and $Kind -in @('Result', 'Protected')) {
            $security = if ($Kind -eq 'Result') { New-ResultFileSecurity -UserSid $currentSid } else { New-ProtectedFileSecurity }
            $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None,
                4096, [IO.FileOptions]::WriteThrough, $security)
        }
        else {
            $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        if ([IO.File]::Exists($Path)) {
            $replace = [IO.File].GetMethod('Replace', [type[]]@([string], [string], [string]))
            if ($null -eq $replace) { throw 'The required atomic file replacement API is unavailable.' }
            [void]$replace.Invoke($null, [object[]]@([string]$temporary, [string]$Path, $null))
        }
        else { [IO.File]::Move($temporary, $Path) }
        $temporary = $null
        if ($Kind -eq 'Result') { Assert-ResultAcl -Path $Path -UserSid $currentSid }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-RequestDigest {
    param([string]$Sid, [string]$CurrentRepository, [string]$Destination, [string]$ConfigSha256, [string]$Nonce)
    # Protocol v1 is UTF-8 without BOM, LF-separated, and has no trailing LF.
    $payload = "$requestDomain`n$Sid`nrelocate`n$CurrentRepository`n$Destination`n$($ConfigSha256.ToLowerInvariant())`n$($Nonce.ToLowerInvariant())"
    return Get-Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($payload))
}

function Get-RecoveryRequestDigest {
    param([string]$Sid, [string]$JournalSha256, [string]$Nonce)
    $payload = "$recoveryRequestDomain`n$Sid`nrecover`n$($JournalSha256.ToLowerInvariant())`n$($Nonce.ToLowerInvariant())"
    return Get-Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($payload))
}

function Initialize-ResultChannel {
    if ($canonicalNonce -notmatch '^[0-9a-f]{64}$') { throw 'The repository-manager request nonce is invalid.' }
    if ($canonicalDigest -notmatch '^[0-9a-f]{64}$') { throw 'The repository-manager request digest is invalid.' }
    $expectedDigest = if ($Action -eq 'Recover') {
        Get-RecoveryRequestDigest -Sid $currentSid -JournalSha256 $canonicalJournalHash -Nonce $canonicalNonce
    }
    else {
        Get-RequestDigest -Sid $currentSid -CurrentRepository $canonicalCurrent `
            -Destination $canonicalNew -ConfigSha256 $canonicalConfigHash -Nonce $canonicalNonce
    }
    if (-not [string]::Equals($canonicalDigest, $expectedDigest, [StringComparison]::Ordinal)) {
        throw 'The repository-manager request digest does not match the request.'
    }
    Assert-NormalDirectoryChain -Directory $stateRoot
    if (-not (Test-Path -LiteralPath $resultRoot)) {
        if ($isTestMode) { [void][IO.Directory]::CreateDirectory($resultRoot) }
        else { [void][IO.Directory]::CreateDirectory($resultRoot, (New-ResultDirectorySecurity -UserSid $currentSid)) }
    }
    Assert-NormalDirectoryChain -Directory $resultRoot
    Assert-ResultAcl -Path $resultRoot -UserSid $currentSid
    foreach ($entry in Get-ChildItem -LiteralPath $resultRoot -Force) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry.Name -notmatch '^[0-9a-f]{64}\.json(\.progress\.json)?$') {
            throw "The protected repository-result directory contains an unexpected entry: $($entry.Name)"
        }
        Assert-ResultAcl -Path $entry.FullName -UserSid $currentSid
        if ($entry.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7)) { [IO.File]::Delete($entry.FullName) }
    }
    $expectedResult = Join-Path $resultRoot "$canonicalNonce.json"
    $actualResult = [IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-PathEqual -Left $actualResult -Right $expectedResult)) {
        throw 'The repository-manager result path does not match its request nonce.'
    }
    $script:progressPath = $actualResult + '.progress.json'
    foreach ($target in @($actualResult, $progressPath)) {
        if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) {
            throw "The repository-manager result target already exists: $target"
        }
    }
    $script:resultChannelReady = $true
}

function Write-Progress {
    param(
        [ValidateSet('preflight','copying','verifying','activating','complete','failed')][string]$Stage,
        [string]$Message,
        [double]$Percent,
        [bool]$Cancellable
    )
    if (-not $resultChannelReady) { return }
    $elapsed = if ($null -eq $copyStartedUtc) { 0.0 } else { ([DateTime]::UtcNow - $copyStartedUtc).TotalSeconds }
    $throughput = if ($elapsed -gt 0.0) { [double]$bytesCopied / $elapsed } else { 0.0 }
    $remaining = if ($throughput -gt 0.0 -and $bytesTotal -gt $bytesCopied) { [double]($bytesTotal - $bytesCopied) / $throughput } else { $null }
    $document = [ordered]@{
        schema_version = 1
        request_nonce = $canonicalNonce
        request_digest = $canonicalDigest
        request_user_sid = $currentSid
        action = $Action.ToLowerInvariant()
        current_repository = $canonicalCurrent
        new_repository = $canonicalNew
        expected_config_sha256 = $canonicalConfigHash
        expected_journal_sha256 = $canonicalJournalHash
        plan_id = $planId
        previous_config_generation = $previousConfigGeneration
        config_generation = $newConfigGeneration
        stage = $Stage
        message = $Message
        percent = [Math]::Round([Math]::Max(0.0, [Math]::Min(100.0, $Percent)), 2)
        files_copied = $filesCopied
        files_total = $filesTotal
        bytes_copied = $bytesCopied
        bytes_total = $bytesTotal
        throughput_bytes_per_second = [Math]::Round($throughput, 2)
        estimated_seconds_remaining = if ($null -eq $remaining) { $null } else { [Math]::Round($remaining, 1) }
        updated_utc = [DateTime]::UtcNow.ToString('o')
        cancellable = $Cancellable
    }
    Write-AtomicJson -Path $progressPath -Value $document -Kind Result
    $script:lastProgressUtc = [DateTime]::UtcNow
}

function Write-FinalResult {
    param([bool]$Ok, [bool]$Changed, [string]$ErrorMessage)
    if (-not $resultChannelReady) { return }
    $document = [ordered]@{
        schema_version = 1
        request_nonce = $canonicalNonce
        request_digest = $canonicalDigest
        request_user_sid = $currentSid
        action = 'relocate'
        current_repository = $canonicalCurrent
        new_repository = $canonicalNew
        expected_config_sha256 = $canonicalConfigHash
        plan_id = $planId
        previous_config_generation = $previousConfigGeneration
        config_generation = $newConfigGeneration
        ok = $Ok
        changed = $Changed
        repository = if ($Ok) { $canonicalNew } else { $canonicalCurrent }
        old_repository = $canonicalCurrent
        old_repository_retained = $true
        recovery_tools_directory = if ($Ok) { $newRecovery } else { $null }
        repository_storage_mode = if ($Ok) { $destinationStorageMode } else { $sourceStorageMode }
        repository_manifest_sha256 = $repositoryManifestSha256
        files_copied = $filesCopied
        bytes_copied = $bytesCopied
        error = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage.Substring(0, [Math]::Min(2000, $ErrorMessage.Length)) }
        finished_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path ([IO.Path]::GetFullPath($ResultPath)) -Value $document -Kind Result
    if ($isTestMode) { $document | ConvertTo-Json -Compress -Depth 8 }
}

function Write-RecoveryResult {
    param([bool]$Ok, [string]$ErrorMessage)
    if (-not $resultChannelReady) { return }
    $document = [ordered]@{
        schema_version = 1
        request_nonce = $canonicalNonce
        request_digest = $canonicalDigest
        request_user_sid = $currentSid
        action = 'recover'
        expected_journal_sha256 = $canonicalJournalHash
        plan_id = $planId
        previous_config_generation = $previousConfigGeneration
        config_generation = $previousConfigGeneration
        abandoned_config_generation = $newConfigGeneration
        ok = $Ok
        changed = $Ok
        current_repository = $recoveredOldRepository
        old_repository = $recoveredOldRepository
        new_repository = $recoveredNewRepository
        repository = $recoveredOldRepository
        old_repository_retained = if ($Ok) { $true } else { $null }
        recovery_tools_directory = if ($Ok) { $recoveredOldRecovery } else { $null }
        abandoned_recovery_tools_directory = $recoveredNewRecovery
        error = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage.Substring(0, [Math]::Min(2000, $ErrorMessage.Length)) }
        finished_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path ([IO.Path]::GetFullPath($ResultPath)) -Value $document -Kind Result
    if ($isTestMode) { $document | ConvertTo-Json -Compress -Depth 8 }
}

function Enter-RunLock {
    param([string]$File)
    Assert-NormalDirectoryChain -Directory (Split-Path -Parent $File)
    if (Test-Path -LiteralPath $File) { [void](Assert-NormalFile -File $File) }
    $stream = [IO.File]::Open($File, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -eq 0) { $stream.WriteByte(0); $stream.Flush($true) }
        $stream.Lock(0, 1)
        return $stream
    }
    catch { $stream.Dispose(); throw 'A backup or another protected change already holds the run lock.' }
}

function Exit-RunLock {
    param([IO.FileStream]$Stream)
    if ($null -eq $Stream) { return }
    try { $Stream.Unlock(0, 1) } finally { $Stream.Dispose() }
}

function Get-VolumeSerial {
    param([string]$Path)
    if (-not ('RepositoryRelocation.NativeVolume' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RepositoryRelocation {
  public static class NativeVolume {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeInformation(string root, System.Text.StringBuilder volume, int volumeSize,
      out uint serial, out uint maximumComponentLength, out uint fileSystemFlags,
      System.Text.StringBuilder fileSystemName, int fileSystemNameSize);
    public static UInt32[] Details(string root) {
      uint serial, maximum, flags;
      if (!GetVolumeInformation(root, null, 0, out serial, out maximum, out flags, null, 0))
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      return new UInt32[] { serial, maximum, flags };
    }
  }
}
'@
    }
    $details = [RepositoryRelocation.NativeVolume]::Details([IO.Path]::GetPathRoot($Path))
    return ([uint32]$details[0]).ToString('X8')
}

function Get-VolumeMetadata {
    param([string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady) { throw "Volume is not ready: $root" }
    [void](Get-VolumeSerial -Path $Path)
    $details = [RepositoryRelocation.NativeVolume]::Details($root)
    return [pscustomobject]@{
        Root = $root
        Serial = ([uint32]$details[0]).ToString('X8')
        MaximumComponentLength = [long]$details[1]
        Flags = [long]$details[2]
        FileSystem = [string]$drive.DriveFormat
        DriveType = [int]$drive.DriveType
        FreeBytes = [long]$drive.AvailableFreeSpace
    }
}

function Assert-NtfsProtectedPath {
    param([string]$Path, [string]$Label)
    $metadata = Get-VolumeMetadata -Path $Path
    if (-not [string]::Equals($metadata.FileSystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must remain on NTFS: $Path"
    }
}

function Assert-ReadyNtfsDestination {
    param([string]$Destination)
    $root = [IO.Path]::GetPathRoot($Destination)
    if (Test-PathEqual -Left $Destination -Right $root) { throw 'The repository destination must not be a drive root.' }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or $drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable) -or
        -not [string]::Equals($drive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The repository destination must be on a ready local NTFS drive.'
    }
    $parent = Split-Path -Parent $Destination
    Assert-NormalDirectoryChain -Directory $parent
    if (Test-Path -LiteralPath $Destination) {
        Assert-NormalDirectoryChain -Directory $Destination
        if (@(Get-ChildItem -LiteralPath $Destination -Force).Count -ne 0) {
            throw 'The repository destination must be missing or completely empty; existing repositories are never adopted.'
        }
    }
}

function Get-StorageModeForPath {
    param([string]$Repository)
    if ((Test-IsWithin -Candidate $Repository -Parent $expectedDriveFsRoot) -and
        -not (Test-PathEqual -Left $Repository -Right $expectedDriveFsRoot)) {
        return $driveFsMode
    }
    return $localNtfsMode
}

function Assert-DriveFsProviderTransaction {
    param([string]$Directory)
    Assert-NormalDirectoryChain -Directory $Directory
    $token = [Guid]::NewGuid().ToString('N')
    $temporary = Join-Path $Directory ".resticbackuper-provider-$token.tmp"
    $committed = Join-Path $Directory ".resticbackuper-provider-$token.commit"
    $payload = [Text.Encoding]::ASCII.GetBytes("ResticBackuper DriveFS provider $token`n")
    $stream = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($payload, 0, $payload.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Move($temporary, $committed)
        if ([IO.File]::Exists($temporary) -or -not [IO.File]::Exists($committed)) {
            throw 'Google DriveFS did not expose the provider probe rename.'
        }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($committed)) -cne
            [Convert]::ToBase64String($payload)) {
            throw 'Google DriveFS provider probe readback did not match.'
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        foreach ($path in @($temporary, $committed)) {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
    }
}

function Assert-ReadyDriveFsDestination {
    param([string]$Destination)
    if (-not (Test-IsWithin -Candidate $Destination -Parent $expectedDriveFsRoot) -or
        (Test-PathEqual -Left $Destination -Right $expectedDriveFsRoot)) {
        throw "DriveFS repository destination must be strictly beneath $expectedDriveFsRoot"
    }
    foreach ($directory in @($expectedDriveFsRoot, $expectedDriveFsCache, (Split-Path -Parent $Destination))) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    if (Test-Path -LiteralPath $Destination) {
        throw 'A DriveFS repository destination must be missing so promotion cannot depend on synthetic ACL restoration.'
    }
    if (-not $isTestMode) {
        $metadata = Get-VolumeMetadata -Path $Destination
        if ($metadata.DriveType -ne [int][IO.DriveType]::Fixed -or
            -not [string]::Equals($metadata.FileSystem, 'FAT32', [StringComparison]::OrdinalIgnoreCase) -or
            ($metadata.Flags -band 0x100) -eq 0 -or
            $metadata.MaximumComponentLength -lt 64) {
            throw 'The repository destination is not the supported Google DriveFS streaming FAT32 mount.'
        }
        if (-not (Get-Process -Name GoogleDriveFS -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            throw 'Google DriveFS provider process is not running.'
        }
        Assert-NtfsProtectedPath -Path $expectedDriveFsCache -Label 'Google DriveFS cache'
    }
    $cacheFree = [long]([IO.DriveInfo]::new([IO.Path]::GetPathRoot($expectedDriveFsCache))).AvailableFreeSpace
    if ($cacheFree -lt $minimumDriveFsCacheBytes) {
        throw 'Google DriveFS cache has less than 10 GiB free.'
    }
    Assert-DriveFsProviderTransaction -Directory (Split-Path -Parent $Destination)
}

function Get-TreeInventory {
    param([string]$Root, [switch]$ExcludeRepositoryLocks)
    Assert-NormalDirectoryChain -Directory $Root
    $directories = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $records = [Collections.Generic.List[object]]::new()
    $totalBytes = 0L
    $maximumBytes = 0L
    $stack = [Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "A repository or recovery path contains a reparse point: $($item.FullName)"
            }
            $relative = $item.FullName.Substring($Root.Length + 1)
            $top = $relative.Split('\')[0]
            if ($ExcludeRepositoryLocks -and [string]::Equals($top, 'locks', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if ($item.PSIsContainer) {
                $directories.Add($relative)
                $stack.Push($item.FullName)
            }
            else {
                $files.Add($item.FullName)
                $totalBytes += $item.Length
                $maximumBytes = [Math]::Max($maximumBytes, [long]$item.Length)
                $records.Add([pscustomobject]@{
                    RelativePath = $relative
                    Bytes = [long]$item.Length
                    Sha256 = Get-FileSha256Hex -File $item.FullName
                })
            }
        }
    }
    $manifestRows = @(
        $records |
            Sort-Object RelativePath |
            ForEach-Object { "$($_.RelativePath)|$($_.Bytes)|$($_.Sha256)" }
    )
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($manifestRows -join "`n")
    return [pscustomobject]@{
        Root = $Root
        Directories = $directories
        Files = $files
        Records = $records
        Bytes = $totalBytes
        MaximumBytes = $maximumBytes
        ManifestSha256 = Get-Sha256Hex -Bytes $manifestBytes
    }
}

function Copy-Inventory {
    param([pscustomobject]$Inventory, [string]$Destination, [bool]$ReportProgress)
    Assert-NormalDirectoryChain -Directory $Destination
    foreach ($relative in $Inventory.Directories) {
        [void][IO.Directory]::CreateDirectory((Join-Path $Destination $relative))
    }
    foreach ($record in $Inventory.Records) {
        $relative = [string]$record.RelativePath
        $source = Join-Path $Inventory.Root $relative
        $target = Join-Path $Destination $relative
        [IO.File]::Copy($source, $target, $false)
        [IO.File]::SetLastWriteTimeUtc($target, [IO.File]::GetLastWriteTimeUtc($source))
        $targetItem = Get-Item -LiteralPath $target -Force
        if ([long]$record.Bytes -ne $targetItem.Length -or
            -not [string]::Equals([string]$record.Sha256, (Get-FileSha256Hex -File $target), [StringComparison]::Ordinal)) {
            throw "Copied file verification failed: $relative"
        }
        $script:filesCopied++
        $script:bytesCopied += $targetItem.Length
        if ($TestCrashDuringCopyAfterFiles -gt 0 -and $filesCopied -eq $TestCrashDuringCopyAfterFiles) {
            Stop-Process -Id $PID -Force
            throw 'Unreachable after disposable copy crash injection.'
        }
        if ($ReportProgress -and ([DateTime]::UtcNow - $lastProgressUtc).TotalSeconds -ge 0.75) {
            $fraction = if ($bytesTotal -gt 0) { [double]$bytesCopied / $bytesTotal } else { 1.0 }
            Write-Progress -Stage copying -Message 'Copying the encrypted repository and recovery tools.' `
                -Percent (5.0 + 70.0 * $fraction) -Cancellable $false
        }
    }
}

function Assert-TreeMatchesInventory {
    param(
        [string]$Root,
        [pscustomobject]$Expected,
        [switch]$ExcludeRepositoryLocks
    )
    $actual = Get-TreeInventory -Root $Root -ExcludeRepositoryLocks:$ExcludeRepositoryLocks
    if ($actual.Records.Count -ne $Expected.Records.Count -or
        $actual.Bytes -ne $Expected.Bytes -or
        -not [string]::Equals($actual.ManifestSha256, $Expected.ManifestSha256, [StringComparison]::Ordinal)) {
        throw "Repository inventory/commit manifest mismatch: $Root"
    }
    return $actual
}

function New-ProtectedStagingDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { throw "Protected staging path already exists: $Path" }
    if ($isTestMode) { [void][IO.Directory]::CreateDirectory($Path) }
    else { [void][IO.Directory]::CreateDirectory($Path, (New-ProtectedDirectorySecurity)) }
    Set-ProtectedTreeAcl -Path $Path
    Assert-ProtectedTreeAcl -Path $Path
}

function New-RepositoryStagingDirectory {
    param([string]$Path, [string]$StorageMode)
    if ($StorageMode -eq $localNtfsMode) {
        New-ProtectedStagingDirectory -Path $Path
        return
    }
    if ($StorageMode -ne $driveFsMode) {
        throw "Unsupported repository staging storage mode: $StorageMode"
    }
    if (Test-Path -LiteralPath $Path) {
        throw "DriveFS repository staging path already exists: $Path"
    }
    [void][IO.Directory]::CreateDirectory($Path)
    Assert-NormalDirectoryChain -Directory $Path
}

function Assert-RepositoryTreeSecurity {
    param([string]$Path, [string]$StorageMode)
    if ($StorageMode -eq $localNtfsMode) {
        Assert-ProtectedTreeAcl -Path $Path
        return
    }
    Assert-NormalDirectoryChain -Directory $Path
    [void](Get-TreeInventory -Root $Path -ExcludeRepositoryLocks)
}

function Restore-EmptyDirectorySecurity {
    param([string]$Path, [string]$Sddl, [int]$Attributes)
    if ([string]::IsNullOrWhiteSpace($Sddl)) { throw "Original empty-directory ACL is unavailable: $Path" }
    if (Test-Path -LiteralPath $Path) { throw "Cannot restore an empty directory over an existing path: $Path" }
    [void][IO.Directory]::CreateDirectory($Path)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetSecurityDescriptorSddlForm($Sddl, [Security.AccessControl.AccessControlSections]::All)
    Set-Acl -LiteralPath $Path -AclObject $security
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]$Attributes)
}

function Write-StageOwnershipMarker {
    param([string]$Directory)
    $marker = [ordered]@{
        schema_version = 1; domain = $requestDomain; request_nonce = $canonicalNonce;
        request_digest = $canonicalDigest; request_user_sid = $currentSid
    }
    Write-AtomicJson -Path (Join-Path $Directory '.relocation-owner.json') -Value $marker -Kind Ordinary
}

function Assert-StageOwnershipMarker {
    param([string]$Directory, [object]$Journal)
    $markerPath = Join-Path $Directory '.relocation-owner.json'
    $marker = (Read-JsonObject -File $markerPath).Json
    if ($marker.schema_version -ne 1 -or [string]$marker.domain -cne $requestDomain -or
        [string]$marker.request_nonce -cne [string]$Journal.request_nonce -or
        [string]$marker.request_digest -cne [string]$Journal.request_digest -or
        -not [string]::Equals([string]$marker.request_user_sid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Relocation staging ownership marker is invalid: $Directory"
    }
}

function Remove-OwnedTree {
    param([string]$Path, [string]$ExpectedParent)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\')
    if ((Test-PathEqual -Left $full -Right ([IO.Path]::GetPathRoot($full))) -or
        -not $full.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unowned relocation path: $full"
    }
    [IO.Directory]::Delete($full, $true)
}

function New-ProtectedDirectorySecurity {
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl, $inheritance,
            [Security.AccessControl.PropagationFlags]::None, $allow))
    }
    foreach ($sidText in @($currentSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance,
            [Security.AccessControl.PropagationFlags]::None, $allow))
    }
    return $security
}

function Assert-ProtectedAclDescriptor {
    param([Security.AccessControl.DirectorySecurity]$Acl)
    if (-not $Acl.AreAccessRulesProtected -or
        $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') {
        throw 'Protected-tree ACL policy does not disable inheritance or bind Administrators ownership.'
    }
    $rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $currentSid)
    $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.IdentityReference.Value -notin $allowed) {
            throw "Protected-tree ACL policy contains an unexpected identity: $($rule.IdentityReference.Value)"
        }
        if ($rule.IdentityReference.Value -in @($currentSid, 'S-1-3-4') -and
            ($rule.FileSystemRights -band $dangerous) -ne 0) {
            throw "Protected-tree ACL policy grants write-capable rights to $($rule.IdentityReference.Value)"
        }
    }
}

function Assert-ProtectedTreeAcl {
    param([string]$Path)
    if ($isTestMode) {
        Assert-ProtectedAclDescriptor -Acl (New-ProtectedDirectorySecurity)
        return
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $currentSid)
    $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($item in @(Get-Item -LiteralPath $Path -Force; Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Protected tree contains a reparse point: $($item.FullName)" }
        $acl = Get-Acl -LiteralPath $item.FullName
        $owner = ([Security.Principal.NTAccount]$acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne 'S-1-5-32-544') { throw "Protected item is not owned by Administrators: $($item.FullName)" }
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $rule.IdentityReference.Value -notin $allowed) {
                throw "Unexpected protected-tree ACL identity: $($rule.IdentityReference.Value)"
            }
            if ($rule.IdentityReference.Value -in @($currentSid, 'S-1-3-4') -and
                $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                ($rule.FileSystemRights -band $dangerous) -ne 0) {
                throw "Normal user or OWNER RIGHTS has write-capable rights: $($item.FullName)"
            }
        }
    }
}

function Set-ProtectedTreeAcl {
    param([string]$Path)
    Assert-NormalDirectoryChain -Directory $Path
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing ACL changes on a tree containing a reparse point: $($item.FullName)" }
    }
    $policy = New-ProtectedDirectorySecurity
    Assert-ProtectedAclDescriptor -Acl $policy
    if ($isTestMode) { return }
    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    $icaclsItem = Assert-NormalFile -File $icacls
    $signature = Get-AuthenticodeSignature -LiteralPath $icacls
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw 'System32 icacls.exe did not pass Microsoft signature verification.'
    }
    Set-Acl -LiteralPath $Path -AclObject $policy
    & $icacls (Join-Path $Path '*') /reset /T /C /L | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Resetting protected relocation child ACLs failed: $LASTEXITCODE" }
    & $icacls $Path /setowner '*S-1-5-32-544' /T /C /L | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Assigning protected relocation ownership failed: $LASTEXITCODE" }
    Assert-ProtectedTreeAcl -Path $Path
}

function Get-RequiredProperty {
    param([object]$Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Backup configuration is missing required property: $Name" }
    return $property.Value
}

function Get-ValidatedPlanSchema {
    param([object]$Configuration)
    $required = @('plan_id', 'config_generation', 'source_identities', 'cloud_placeholder_policy')
    $present = @($required | Where-Object { $null -ne $Configuration.PSObject.Properties[$_] })
    if ($present.Count -eq 0) {
        throw 'Backup configuration migration is required before repository relocation; plan identity fields are absent.'
    }
    if ($present.Count -ne $required.Count) {
        throw 'Backup configuration migration is required before repository relocation; the plan/source identity schema is incomplete.'
    }
    $parsedPlanId = [Guid]::Empty
    if ($Configuration.plan_id -isnot [string] -or
        -not [Guid]::TryParseExact([string]$Configuration.plan_id, 'D', [ref]$parsedPlanId) -or
        -not [string]::Equals([string]$Configuration.plan_id, $parsedPlanId.ToString('D'), [StringComparison]::Ordinal)) {
        throw 'Configured plan_id must be one canonical lowercase UUID.'
    }
    $generation = $Configuration.config_generation
    if ($null -eq $generation -or
        $generation.GetType().FullName -notin @('System.Int32', 'System.Int64') -or
        [long]$generation -le 0) {
        throw 'Configured config_generation must be a positive integer.'
    }
    if ($Configuration.cloud_placeholder_policy -isnot [string] -or
        [string]$Configuration.cloud_placeholder_policy -notin @('strict', 'allow')) {
        throw 'Configured cloud_placeholder_policy must be strict or allow.'
    }
    if ($Configuration.source_identities -isnot [Management.Automation.PSCustomObject]) {
        throw 'Configured source_identities must be one JSON object keyed by canonical source path.'
    }
    return [pscustomobject]@{
        PlanId = $parsedPlanId.ToString('D')
        ConfigGeneration = [long]$generation
        CloudPlaceholderPolicy = [string]$Configuration.cloud_placeholder_policy
    }
}

function Get-ValidatedSourceIdentityMap {
    param([object]$Configuration, [string[]]$Sources)
    $properties = @($Configuration.source_identities.PSObject.Properties)
    if ($properties.Count -ne $Sources.Count) {
        throw 'Configured source_identities must contain exactly one entry for every source.'
    }
    $map = [ordered]@{}
    $expectedSerials = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($source in $Sources) {
        $matches = @($properties | Where-Object {
            [string]::Equals($_.Name, $source, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1) { throw "Configured source identity is missing or duplicated: $source" }
        $property = $matches[0]
        if (-not [string]::Equals($property.Name, $source, [StringComparison]::Ordinal)) {
            throw "Configured source identity key is not the exact canonical source path: $($property.Name)"
        }
        $identity = $property.Value
        if ($identity -isnot [Management.Automation.PSCustomObject]) {
            throw "Configured source identity must be a JSON object: $source"
        }
        $serial = $identity.PSObject.Properties['expected_volume_serial']
        if ($null -eq $serial -or $serial.Value -isnot [string] -or
            [string]$serial.Value -notmatch '^[0-9A-Fa-f]{8}$') {
            throw "Configured source expected_volume_serial is invalid: $source"
        }
        $map[$source] = $identity
        $expectedSerials[$source] = ([string]$serial.Value).ToUpperInvariant()
    }
    return [pscustomobject]@{ Map = $map; ExpectedSerials = $expectedSerials }
}

function Assert-SourceListsEqual {
    param([string[]]$Expected, [object[]]$Actual, [string]$Message)
    if ($Expected.Count -ne $Actual.Count) { throw $Message }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -isnot [string] -or
            -not [string]::Equals($Expected[$index], [string]$Actual[$index], [StringComparison]::Ordinal)) {
            throw $Message
        }
    }
}

function Assert-SourceIdentityMapsEqual {
    param([Collections.IDictionary]$Expected, [Collections.IDictionary]$Actual, [string]$Message)
    if ($Expected.Count -ne $Actual.Count) { throw $Message }
    foreach ($source in $Expected.Keys) {
        if (-not $Actual.Contains($source)) { throw "$Message Missing: $source" }
        if (($Expected[$source] | ConvertTo-Json -Depth 20 -Compress) -ne
            ($Actual[$source] | ConvertTo-Json -Depth 20 -Compress)) {
            throw "$Message Field: $source"
        }
    }
}

function Assert-JsonPropertyEqual {
    param([object]$Expected, [object]$Actual, [string]$Name, [string]$Message)
    $expectedProperty = $Expected.PSObject.Properties[$Name]
    $actualProperty = $Actual.PSObject.Properties[$Name]
    if (($null -eq $expectedProperty) -ne ($null -eq $actualProperty)) { throw $Message }
    if ($null -eq $expectedProperty) { return }
    if (($expectedProperty.Value | ConvertTo-Json -Depth 20 -Compress) -ne
        ($actualProperty.Value | ConvertTo-Json -Depth 20 -Compress)) { throw $Message }
}

function Get-ValidatedTopologyPaths {
    param([object]$Configuration, [string[]]$BaseProtectedPaths)
    $protected = [Collections.Generic.List[string]]::new()
    foreach ($path in $BaseProtectedPaths) { $protected.Add($path) }
    $property = $Configuration.PSObject.Properties['topology_paths']
    if ($null -ne $property) {
        if ($property.Value -isnot [Management.Automation.PSCustomObject]) {
            throw 'Configured topology_paths must be a JSON object.'
        }
        $reserved = @('repository', 'recovery_tools_directory', 'state_directory')
        foreach ($entry in $property.Value.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($entry.Name) -or $entry.Name -in $reserved -or
                $entry.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
                throw 'Configured topology_paths contains an invalid or reserved entry.'
            }
            $protected.Add((Get-CanonicalLocalPath -Value ([string]$entry.Value)))
        }
    }
    for ($leftIndex = 0; $leftIndex -lt $protected.Count; $leftIndex++) {
        for ($rightIndex = 0; $rightIndex -lt $leftIndex; $rightIndex++) {
            Assert-NoOverlap -Candidate $protected[$leftIndex] -Other $protected[$rightIndex] `
                -Message 'Protected backup topology paths overlap'
        }
    }
    return ,@($protected)
}

function Get-ConfiguredStorageBinding {
    param(
        [object]$Configuration,
        [string]$Repository,
        [string]$RecoveryTools
    )
    $modeProperty = $Configuration.PSObject.Properties['repository_storage_mode']
    $mode = if ($null -eq $modeProperty) { $localNtfsMode } else { [string]$modeProperty.Value }
    if ($mode -notin @($localNtfsMode, $driveFsMode)) {
        throw 'Configured repository_storage_mode is unsupported.'
    }
    $rootProperty = $Configuration.PSObject.Properties['drivefs_my_drive_root']
    $legacyRootProperty = $Configuration.PSObject.Properties['repository_drivefs_root']
    $cacheProperty = $Configuration.PSObject.Properties['drivefs_cache_directory']
    if ($mode -eq $localNtfsMode) {
        if ($null -ne $rootProperty -or $null -ne $legacyRootProperty -or $null -ne $cacheProperty) {
            throw 'DriveFS path bindings are invalid with local_ntfs.'
        }
        $expectedRecovery = Get-CanonicalLocalPath -Value (
            Join-Path (Split-Path -Parent $Repository) 'RecoveryTools')
        if (-not (Test-PathEqual -Left $RecoveryTools -Right $expectedRecovery)) {
            throw 'The local_ntfs recovery-tools directory is not the repository sibling required by v1.'
        }
        return [pscustomobject]@{
            Mode = $mode
            DriveFsRoot = $null
            DriveFsCache = $null
        }
    }

    $rawRoot = if ($null -ne $rootProperty) { [string]$rootProperty.Value } elseif ($null -ne $legacyRootProperty) {
        [string]$legacyRootProperty.Value
    } else { '' }
    if ($null -ne $rootProperty -and $null -ne $legacyRootProperty) {
        $canonicalRoot = Get-CanonicalLocalPath -Value ([string]$rootProperty.Value)
        $canonicalLegacyRoot = Get-CanonicalLocalPath -Value ([string]$legacyRootProperty.Value)
        if (-not (Test-PathEqual -Left $canonicalRoot -Right $canonicalLegacyRoot)) {
            throw 'drivefs_my_drive_root conflicts with legacy repository_drivefs_root.'
        }
    }
    $root = Get-CanonicalLocalPath -Value $rawRoot
    $cache = if ($null -ne $cacheProperty) {
        Get-CanonicalLocalPath -Value ([string]$cacheProperty.Value)
    } elseif ($null -ne $legacyRootProperty) {
        $expectedDriveFsCache
    } else {
        throw 'google_drivefs_stream requires drivefs_cache_directory.'
    }
    if (-not (Test-PathEqual -Left $root -Right $expectedDriveFsRoot) -or
        -not (Test-PathEqual -Left $cache -Right $expectedDriveFsCache)) {
        throw 'Google DriveFS root/cache bindings do not match the supported current-user provider.'
    }
    if (-not (Test-IsWithin -Candidate $Repository -Parent $root) -or
        (Test-PathEqual -Left $Repository -Right $root)) {
        throw 'DriveFS repository is not strictly beneath drivefs_my_drive_root.'
    }
    if (-not (Test-PathEqual -Left $RecoveryTools -Right $driveFsRecoveryRoot)) {
        throw 'DriveFS recovery tools must remain in the protected NTFS recovery root.'
    }
    return [pscustomobject]@{
        Mode = $mode
        DriveFsRoot = $root
        DriveFsCache = $cache
    }
}

function Assert-CurrentDriveFsRepository {
    param([string]$Repository)
    foreach ($directory in @($expectedDriveFsRoot, $expectedDriveFsCache, $Repository)) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    if (-not $isTestMode) {
        $metadata = Get-VolumeMetadata -Path $Repository
        if ($metadata.DriveType -ne [int][IO.DriveType]::Fixed -or
            -not [string]::Equals($metadata.FileSystem, 'FAT32', [StringComparison]::OrdinalIgnoreCase) -or
            ($metadata.Flags -band 0x100) -eq 0 -or
            $metadata.MaximumComponentLength -lt 64) {
            throw 'The current DriveFS repository is not on the supported streaming FAT32 mount.'
        }
        if (-not (Get-Process -Name GoogleDriveFS -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            throw 'Google DriveFS provider process is not running.'
        }
        Assert-NtfsProtectedPath -Path $expectedDriveFsCache -Label 'Google DriveFS cache'
    }
    $cacheFree = [long]([IO.DriveInfo]::new([IO.Path]::GetPathRoot($expectedDriveFsCache))).AvailableFreeSpace
    if ($cacheFree -lt $minimumDriveFsCacheBytes) {
        throw 'Google DriveFS cache has less than 10 GiB free.'
    }
    Assert-DriveFsProviderTransaction -Directory (Split-Path -Parent $Repository)
}

function Get-ValidatedConfiguration {
    $loaded = Read-JsonObject -File $configPath
    if ((Get-Sha256Hex -Bytes $loaded.RawBytes) -ne $canonicalConfigHash) {
        throw 'The protected configuration changed after the relocation request was prepared.'
    }
    $configuration = $loaded.Json
    if ((Get-RequiredProperty -Object $configuration -Name 'schema_version') -ne 1) {
        throw 'Unsupported backup configuration schema.'
    }
    $plan = Get-ValidatedPlanSchema -Configuration $configuration
    foreach ($name in @(
        'repository', 'repository_volume_serial', 'restic_executable', 'recovery_tools_directory',
        'python_executable', 'state_directory', 'secret_file', 'recovery_key_file', 'exclude_file',
        'canary_file', 'hostname', 'scheduled_tag', 'sources', 'use_vss'
    )) { [void](Get-RequiredProperty -Object $configuration -Name $name) }

    $repository = Get-CanonicalLocalPath -Value ([string]$configuration.repository)
    if (-not (Test-PathEqual -Left $repository -Right $canonicalCurrent)) {
        throw 'The configured repository no longer matches the expected current repository.'
    }
    $resticExecutable = Get-CanonicalLocalPath -Value ([string]$configuration.restic_executable)
    $pythonExecutable = Get-CanonicalLocalPath -Value ([string]$configuration.python_executable)
    $secretFile = Get-CanonicalLocalPath -Value ([string]$configuration.secret_file)
    $excludeFile = Get-CanonicalLocalPath -Value ([string]$configuration.exclude_file)
    $canaryFile = Get-CanonicalLocalPath -Value ([string]$configuration.canary_file)
    [void](Get-CanonicalLocalPath -Value ([string]$configuration.recovery_key_file))
    $configuredState = Get-CanonicalLocalPath -Value ([string]$configuration.state_directory)
    $recoveryTools = Get-CanonicalLocalPath -Value ([string]$configuration.recovery_tools_directory)
    foreach ($pair in @(
        @($configuredState, $stateRoot, 'state directory'),
        @($resticExecutable, (Join-Path $installRoot 'restic.exe'), 'Restic executable'),
        @($pythonExecutable, (Join-Path $installRoot 'Python\python.exe'), 'Python executable'),
        @($secretFile, (Join-Path $stateRoot 'repository-password.dpapi.json'), 'DPAPI secret file'),
        @($excludeFile, (Join-Path $installRoot 'excludes.txt'), 'exclude file')
    )) {
        if (-not (Test-PathEqual -Left $pair[0] -Right $pair[1])) {
            throw "Configuration names an unexpected protected $($pair[2]): $($pair[0])"
        }
    }
    $storage = Get-ConfiguredStorageBinding -Configuration $configuration `
        -Repository $repository -RecoveryTools $recoveryTools
    foreach ($directory in @($installRoot, $stateRoot, $repository, $recoveryTools)) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    foreach ($file in @((Join-Path $repository 'config'), $resticExecutable, $pythonExecutable,
        (Join-Path $installRoot 'secret_store.py'), $secretFile, $excludeFile, $canaryFile)) {
        [void](Assert-NormalFile -File $file)
    }
    foreach ($binding in @(
        @($installRoot, 'Protected runtime'),
        @($stateRoot, 'ProgramData state'),
        @($secretFile, 'DPAPI secret file'),
        @($recoveryTools, 'Recovery tools'),
        @([string]$configuration.recovery_key_file, 'Recovery key')
    )) {
        Assert-NtfsProtectedPath -Path $binding[0] -Label $binding[1]
    }
    if ($storage.Mode -eq $localNtfsMode) {
        Assert-NtfsProtectedPath -Path $repository -Label 'local_ntfs repository'
    }
    else {
        Assert-CurrentDriveFsRepository -Repository $repository
    }
    $actualSerial = Get-VolumeSerial -Path $repository
    if ($configuration.repository_volume_serial -isnot [string] -or
        [string]$configuration.repository_volume_serial -notmatch '^[0-9A-Fa-f]{8}$' -or
        -not [string]::Equals([string]$configuration.repository_volume_serial, $actualSerial, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The current repository volume does not match the protected configuration.'
    }
    if ($configuration.use_vss -isnot [bool]) { throw 'Configured use_vss value must be a JSON Boolean.' }
    $protectedPaths = Get-ValidatedTopologyPaths -Configuration $configuration `
        -BaseProtectedPaths @($repository, $installRoot, $stateRoot, $recoveryTools)
    $canarySource = Get-CanonicalLocalPath -Value (Split-Path -Parent $canaryFile)
    $sources = [Collections.Generic.List[string]]::new()
    $sourceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($configuration.sources)) {
        if ($value -isnot [string]) { throw 'Every source must be a path string.' }
        $source = Get-CanonicalLocalPath -Value ([string]$value)
        if (-not [string]::Equals([string]$value, $source, [StringComparison]::Ordinal)) {
            throw "Configured source is not an exact canonical path: $value"
        }
        if (-not $sourceSet.Add($source)) { throw "Duplicate source in backup configuration: $source" }
        Assert-NormalDirectoryChain -Directory $source
        foreach ($existing in $sources) {
            Assert-NoOverlap -Candidate $source -Other $existing -Message 'Configured sources overlap'
        }
        foreach ($protected in $protectedPaths) {
            if ((Test-IsWithin -Candidate $canarySource -Parent $stateRoot) -and
                (Test-PathEqual -Left $source -Right $canarySource) -and
                (Test-PathEqual -Left $protected -Right $stateRoot)) {
                continue
            }
            Assert-NoOverlap -Candidate $source -Other $protected -Message 'Source overlaps a protected backup location'
        }
        $sources.Add($source)
    }
    if ($sources.Count -eq 0) { throw 'The protected configuration has no sources.' }
    $identities = Get-ValidatedSourceIdentityMap -Configuration $configuration -Sources @($sources)
    foreach ($source in $sources) {
        $observedSerial = Get-VolumeSerial -Path $source
        $expectedSerial = $identities.ExpectedSerials[$source]
        if (-not [string]::Equals($expectedSerial, $observedSerial, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Source volume identity mismatch: $source expected $expectedSerial, observed $observedSerial"
        }
    }
    $canarySources = @($sources | Where-Object { Test-PathEqual -Left $_ -Right $canarySource })
    if ($canarySources.Count -ne 1) {
        throw 'The exact protected canary directory must occur once in configured sources.'
    }
    return [pscustomobject]@{
        Json = $configuration; RawBytes = $loaded.RawBytes; Repository = $repository;
        RecoveryTools = $recoveryTools; ResticExecutable = $resticExecutable;
        PythonExecutable = $pythonExecutable; SecretFile = $secretFile; Sources = @($sources);
        PlanId = $plan.PlanId; ConfigGeneration = $plan.ConfigGeneration;
        CloudPlaceholderPolicy = $plan.CloudPlaceholderPolicy; IdentityMap = $identities.Map;
        ExpectedSerials = $identities.ExpectedSerials; ProtectedPaths = @($protectedPaths);
        StorageMode = $storage.Mode; DriveFsRoot = $storage.DriveFsRoot;
        DriveFsCache = $storage.DriveFsCache
    }
}

function Get-ValidatedRuntimeManifest {
    $loaded = Read-JsonObject -File $runtimeManifestPath
    $manifest = $loaded.Json
    if ($manifest.schema_version -ne 1) { throw 'Runtime manifest schema is invalid.' }
    $records = @($manifest.files)
    if ([long]$manifest.file_count -ne $records.Count) { throw 'Runtime manifest file count is invalid.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = $installRoot + '\'
    foreach ($record in $records) {
        if ($null -eq $record -or $record.relative_path -isnot [string]) { throw 'Invalid runtime manifest record.' }
        $relative = ([string]$record.relative_path).Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative.Split('\') -contains '..' -or -not $seen.Add($relative)) {
            throw "Unsafe or duplicate runtime manifest path: $relative"
        }
        $file = [IO.Path]::GetFullPath((Join-Path $installRoot $relative))
        if (-not $file.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime manifest path escapes its root.' }
        $item = Assert-NormalFile -File $file
        if ([long]$record.bytes -ne $item.Length -or
            -not [string]::Equals([string]$record.sha256, (Get-FileSha256Hex -File $file), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Runtime manifest mismatch: $relative"
        }
    }
    foreach ($required in @('backup-config.json', 'Manage-Repository.ps1', 'restic.exe', 'secret_store.py')) {
        if (-not $seen.Contains($required)) { throw "Runtime manifest is missing required file: $required" }
    }
    $actual = @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force |
        Where-Object Name -notin @(
            'runtime-manifest.json',
            'scheduled-task.xml',
            'google-drive-verification-task.xml'
        ))
    if ($actual.Count -ne $records.Count) { throw 'Runtime contains unmanifested or missing files.' }
    return [pscustomobject]@{ Json = $manifest; RawBytes = $loaded.RawBytes }
}

function Get-ValidatedRecoveryBundle {
    param(
        [string]$Directory,
        [string]$ExpectedRepository,
        [switch]$AllowOwnershipMarker,
        [pscustomobject]$ExpectedPlan
    )
    $payloadNames = @('restic.exe', 'restore.py', 'secret_store.py', 'backup-config.json', 'RECOVERY.md', 'restic-release.json')
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $payloadNames) { [void]$allowed.Add($name) }
    [void]$allowed.Add('recovery-manifest.json')
    if ($AllowOwnershipMarker) { [void]$allowed.Add('.relocation-owner.json') }
    Assert-NormalDirectoryChain -Directory $Directory
    $entries = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($entries.Count -ne $allowed.Count) { throw "Recovery bundle is incomplete or has unexpected entries: $Directory" }
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $allowed.Contains($entry.Name)) { throw "Unsafe recovery entry: $($entry.Name)" }
    }
    $manifestPath = Join-Path $Directory 'recovery-manifest.json'
    $manifestLoaded = Read-JsonObject -File $manifestPath
    $manifest = $manifestLoaded.Json
    if ($manifest.schema_version -ne 1 -or $manifest.repository -isnot [string] -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$manifest.repository)) -Right $ExpectedRepository)) {
        throw 'Recovery manifest names another repository or has an invalid schema.'
    }
    $records = @($manifest.files)
    if ($records.Count -ne $payloadNames.Count) { throw 'Recovery manifest payload count is invalid.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records) {
        $name = [string]$record.name
        if (-not $allowed.Contains($name) -or $name -eq 'recovery-manifest.json' -or -not $seen.Add($name)) {
            throw 'Recovery manifest contains an invalid or duplicate payload.'
        }
        $file = Join-Path $Directory $name
        $item = Assert-NormalFile -File $file
        if ([long]$record.bytes -ne $item.Length -or
            -not [string]::Equals([string]$record.sha256, (Get-FileSha256Hex -File $file), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Recovery manifest mismatch: $name"
        }
    }
    foreach ($name in $payloadNames) { if (-not $seen.Contains($name)) { throw "Recovery payload is missing: $name" } }
    $configPathInBundle = Join-Path $Directory 'backup-config.json'
    $configLoaded = Read-JsonObject -File $configPathInBundle
    $bundleConfig = $configLoaded.Json
    if ($bundleConfig.schema_version -ne 1 -or $bundleConfig.repository -isnot [string] -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$bundleConfig.repository)) -Right $ExpectedRepository)) {
        throw 'Recovery configuration names another repository.'
    }
    $bundlePlan = Get-ValidatedPlanSchema -Configuration $bundleConfig
    $bundleSources = [Collections.Generic.List[string]]::new()
    $sourceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in @($bundleConfig.sources)) {
        if ($value -isnot [string]) { throw 'Recovery configuration contains a non-string source path.' }
        $source = Get-CanonicalLocalPath -Value ([string]$value)
        if (-not [string]::Equals([string]$value, $source, [StringComparison]::Ordinal) -or
            -not $sourceSet.Add($source)) {
            throw 'Recovery configuration contains a non-canonical or duplicate source path.'
        }
        $bundleSources.Add($source)
    }
    if ($bundleSources.Count -eq 0) { throw 'Recovery configuration has no source folders.' }
    $bundleIdentities = Get-ValidatedSourceIdentityMap -Configuration $bundleConfig -Sources @($bundleSources)
    if ($null -ne $ExpectedPlan) {
        $bundleRecovery = Get-CanonicalLocalPath -Value ([string]$bundleConfig.recovery_tools_directory)
        $bundleStorage = Get-ConfiguredStorageBinding -Configuration $bundleConfig `
            -Repository $ExpectedRepository -RecoveryTools $bundleRecovery
        if (-not [string]::Equals($bundlePlan.PlanId, $ExpectedPlan.PlanId, [StringComparison]::Ordinal) -or
            $bundlePlan.ConfigGeneration -ne [long]$ExpectedPlan.ConfigGeneration -or
            -not [string]::Equals($bundleStorage.Mode, $ExpectedPlan.StorageMode, [StringComparison]::Ordinal) -or
            -not [string]::Equals(
                $bundlePlan.CloudPlaceholderPolicy,
                $ExpectedPlan.CloudPlaceholderPolicy,
                [StringComparison]::Ordinal
            )) {
            throw 'Recovery plan identity, generation, or cloud policy is not synchronized.'
        }
        if ($bundleStorage.Mode -eq $driveFsMode -and
            (-not (Test-PathEqual -Left $bundleStorage.DriveFsRoot -Right $ExpectedPlan.DriveFsRoot) -or
             -not (Test-PathEqual -Left $bundleStorage.DriveFsCache -Right $ExpectedPlan.DriveFsCache))) {
            throw 'Recovery DriveFS root/cache bindings are not synchronized.'
        }
        Assert-SourceListsEqual -Expected $ExpectedPlan.Sources -Actual @($bundleSources) `
            -Message 'Recovery source list is not synchronized with the protected configuration.'
        Assert-SourceIdentityMapsEqual -Expected $ExpectedPlan.IdentityMap -Actual $bundleIdentities.Map `
            -Message 'Recovery source identities are not synchronized with the protected configuration.'
        Assert-JsonPropertyEqual -Expected $ExpectedPlan.Json -Actual $bundleConfig -Name 'topology_paths' `
            -Message 'Recovery topology_paths is not synchronized with the protected configuration.'
        if ($bundleConfig.repository_volume_serial -isnot [string] -or
            -not [string]::Equals(
                [string]$bundleConfig.repository_volume_serial,
                [string]$ExpectedPlan.Json.repository_volume_serial,
                [StringComparison]::OrdinalIgnoreCase
            ) -or $bundleConfig.recovery_tools_directory -isnot [string] -or
            -not (Test-PathEqual `
                -Left (Get-CanonicalLocalPath -Value ([string]$bundleConfig.recovery_tools_directory)) `
                -Right (Get-CanonicalLocalPath -Value ([string]$ExpectedPlan.Json.recovery_tools_directory))) -or
            $bundleConfig.use_vss -isnot [bool] -or
            [bool]$bundleConfig.use_vss -ne [bool]$ExpectedPlan.Json.use_vss) {
            throw 'Recovery repository identity, location, or VSS policy is not synchronized.'
        }
    }
    return [pscustomobject]@{
        ConfigPath = $configPathInBundle; Config = $bundleConfig; ConfigBytes = $configLoaded.RawBytes;
        ManifestPath = $manifestPath; Manifest = $manifest; ManifestBytes = $manifestLoaded.RawBytes;
        Plan = $bundlePlan; Sources = @($bundleSources); IdentityMap = $bundleIdentities.Map
    }
}

function ConvertTo-PasswordCommand {
    param([pscustomobject]$Validated)
    $helper = (Join-Path $installRoot 'secret_store.py').Replace('\', '/')
    $arguments = @(
        $Validated.PythonExecutable.Replace('\', '/'), '-I', '-S', '-B', $helper,
        'reveal', '--secret-file', $Validated.SecretFile.Replace('\', '/')
    )
    return (($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' ')
}

function Invoke-ResticCapture {
    param([pscustomobject]$Validated, [string]$Repository, [string[]]$CommandArguments)
    $cache = Join-Path $stateRoot 'cache'
    if (-not (Test-Path -LiteralPath $cache)) { [void][IO.Directory]::CreateDirectory($cache) }
    $arguments = @(
        '--repo', $Repository, '--password-command', (ConvertTo-PasswordCommand -Validated $Validated),
        '--cache-dir', $cache, '--retry-lock', '0s'
    ) + $CommandArguments
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $Validated.ResticExecutable @arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorPreference }
    if ($exitCode -ne 0) {
        $message = ($lines -join ' ').Trim()
        if ($message.Length -gt 1000) { $message = $message.Substring(0, 1000) }
        throw "Restic verification failed with exit code $exitCode`: $message"
    }
    return ($lines -join "`n")
}

function Get-ResticIdentity {
    param([pscustomobject]$Validated, [string]$Repository)
    $configurationText = Invoke-ResticCapture -Validated $Validated -Repository $Repository -CommandArguments @('cat', 'config')
    $resticConfig = $configurationText | ConvertFrom-Json
    if ($null -eq $resticConfig -or $resticConfig.id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$resticConfig.id)) {
        throw 'Restic did not return a valid repository ID.'
    }
    $snapshotText = Invoke-ResticCapture -Validated $Validated -Repository $Repository -CommandArguments @('snapshots', '--json')
    $snapshots = $snapshotText | ConvertFrom-Json
    $idList = [Collections.Generic.List[string]]::new()
    foreach ($snapshot in $snapshots) {
        $idProperty = $snapshot.PSObject.Properties['id']
        $id = if ($null -eq $idProperty) { '' } else { [string]$idProperty.Value }
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'Restic returned an invalid snapshot ID.' }
        $idList.Add($id)
    }
    $ids = @($idList | Sort-Object -Unique)
    return [pscustomobject]@{ RepositoryId = [string]$resticConfig.id; SnapshotIds = $ids }
}

function Assert-ResticIdentityEqual {
    param([pscustomobject]$Expected, [pscustomobject]$Actual)
    if (-not [string]::Equals($Expected.RepositoryId, $Actual.RepositoryId, [StringComparison]::Ordinal) -or
        ($Expected.SnapshotIds -join "`n") -cne ($Actual.SnapshotIds -join "`n")) {
        throw 'The copied destination has a different Restic repository ID or snapshot history.'
    }
}

function Assert-EmptyDestinationUnchanged {
    param([string]$Path, [bool]$InitiallyExisted, [string]$OriginalSddl)
    if ($InitiallyExisted) {
        Assert-NormalDirectoryChain -Directory $Path
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
            throw "An originally empty destination changed during relocation: $Path"
        }
        $currentSddl = (Get-Acl -LiteralPath $Path).GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::All)
        if (-not [string]::Equals($currentSddl, $OriginalSddl, [StringComparison]::Ordinal)) {
            throw "An originally empty destination ACL changed during relocation: $Path"
        }
    }
    elseif (Test-Path -LiteralPath $Path) {
        throw "A previously missing destination appeared during relocation: $Path"
    }
}

function Assert-ActivationTrees {
    param(
        [pscustomobject]$Validated,
        [pscustomobject]$ExpectedIdentity,
        [pscustomobject]$ExpectedPlan,
        [string]$Repository,
        [string]$Recovery,
        [string]$StorageMode,
        [pscustomobject]$RepositoryInventory
    )
    Assert-NormalDirectoryChain -Directory $Repository
    Assert-NormalDirectoryChain -Directory $Recovery
    [void](Assert-TreeMatchesInventory -Root $Repository -Expected $RepositoryInventory -ExcludeRepositoryLocks)
    [void](Get-TreeInventory -Root $Recovery)
    Assert-RepositoryTreeSecurity -Path $Repository -StorageMode $StorageMode
    Assert-ProtectedTreeAcl -Path $Recovery
    Assert-ResticIdentityEqual -Expected $ExpectedIdentity -Actual (
        Get-ResticIdentity -Validated $Validated -Repository $Repository)
    [void](Get-ValidatedRecoveryBundle -Directory $Recovery -ExpectedRepository $Repository -ExpectedPlan $ExpectedPlan)
}

function New-RuntimeManifestBytes {
    param([object]$Manifest, [byte[]]$NewConfigBytes)
    $found = 0
    foreach ($record in @($Manifest.files)) {
        if ([string]::Equals([string]$record.relative_path, 'backup-config.json', [StringComparison]::OrdinalIgnoreCase)) {
            $record.bytes = $NewConfigBytes.Length
            $record.sha256 = Get-Sha256Hex -Bytes $NewConfigBytes
            $found++
        }
    }
    if ($found -ne 1) { throw 'Runtime manifest does not bind exactly one backup configuration.' }
    Set-JsonProperty -Object $Manifest -Name 'created_utc' -Value ([DateTime]::UtcNow.ToString('o'))
    Set-JsonProperty -Object $Manifest -Name 'last_update_reason' -Value 'Protected repository relocated'
    return ConvertTo-Utf8JsonBytes -Value $Manifest
}

function Update-StagedRecoveryBundle {
    param(
        [string]$Directory,
        [string]$Repository,
        [string]$VolumeSerial,
        [string]$RecoveryDirectory,
        [pscustomobject]$ExpectedBefore,
        [pscustomobject]$ExpectedAfter
    )
    $bundle = Get-ValidatedRecoveryBundle -Directory $Directory -ExpectedRepository $canonicalCurrent `
        -AllowOwnershipMarker -ExpectedPlan $ExpectedBefore
    $bundle.Config.repository = $Repository
    $bundle.Config.repository_volume_serial = $VolumeSerial
    $bundle.Config.recovery_tools_directory = $RecoveryDirectory
    $bundle.Config.config_generation = [long]$ExpectedAfter.ConfigGeneration
    Set-JsonProperty -Object $bundle.Config -Name 'repository_storage_mode' -Value $ExpectedAfter.StorageMode
    if ($null -ne $bundle.Config.PSObject.Properties['repository_drivefs_root']) {
        $bundle.Config.PSObject.Properties.Remove('repository_drivefs_root')
    }
    if ($ExpectedAfter.StorageMode -eq $driveFsMode) {
        Set-JsonProperty -Object $bundle.Config -Name 'drivefs_my_drive_root' -Value $ExpectedAfter.DriveFsRoot
        Set-JsonProperty -Object $bundle.Config -Name 'drivefs_cache_directory' -Value $ExpectedAfter.DriveFsCache
    }
    else {
        foreach ($name in @('drivefs_my_drive_root', 'drivefs_cache_directory')) {
            if ($null -ne $bundle.Config.PSObject.Properties[$name]) {
                $bundle.Config.PSObject.Properties.Remove($name)
            }
        }
    }
    $configBytes = ConvertTo-Utf8JsonBytes -Value $bundle.Config
    [IO.File]::WriteAllBytes($bundle.ConfigPath, $configBytes)
    $found = 0
    foreach ($record in @($bundle.Manifest.files)) {
        if ([string]::Equals([string]$record.name, 'backup-config.json', [StringComparison]::OrdinalIgnoreCase)) {
            $record.bytes = $configBytes.Length
            $record.sha256 = Get-Sha256Hex -Bytes $configBytes
            $found++
        }
    }
    if ($found -ne 1) { throw 'Recovery manifest does not bind exactly one backup configuration.' }
    $bundle.Manifest.repository = $Repository
    Set-JsonProperty -Object $bundle.Manifest -Name 'created_utc' -Value ([DateTime]::UtcNow.ToString('o'))
    Set-JsonProperty -Object $bundle.Manifest -Name 'last_update_reason' -Value 'Protected repository relocated'
    [IO.File]::WriteAllBytes($bundle.ManifestPath, (ConvertTo-Utf8JsonBytes -Value $bundle.Manifest))
    [void](Get-ValidatedRecoveryBundle -Directory $Directory -ExpectedRepository $Repository `
        -AllowOwnershipMarker -ExpectedPlan $ExpectedAfter)
}

function Set-AtomicFileBytes {
    param([string]$Target, [byte[]]$Bytes)
    [void](Assert-NormalFile -File $Target)
    $parent = Split-Path -Parent $Target
    Assert-NormalDirectoryChain -Directory $parent
    $temporary = Join-Path $parent ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Target)), [Guid]::NewGuid().ToString('N'))
    $stream = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream = $null
        $replace = [IO.File].GetMethod('Replace', [type[]]@([string], [string], [string]))
        if ($null -eq $replace) { throw 'The required atomic file replacement API is unavailable.' }
        [void]$replace.Invoke($null, [object[]]@([string]$temporary, [string]$Target, $null))
        $temporary = $null
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Write-Journal {
    param([string]$State)
    if ($null -eq $script:journalDocument) { throw 'Relocation journal is not initialized.' }
    $script:journalDocument.state = $State
    $script:journalDocument.updated_utc = [DateTime]::UtcNow.ToString('o')
    Write-AtomicJson -Path $journalPath -Value $script:journalDocument -Kind Protected
    $script:journalReady = $true
}

function Assert-InjectionAllowed {
    param([int]$Point)
    if ($TestCrashAfterPublish -eq $Point) {
        # Disposable tests use process termination to model power loss. The OS
        # releases run.lock, while the write-through journal remains durable.
        Stop-Process -Id $PID -Force
        throw 'Unreachable after disposable crash injection.'
    }
    if ($TestFailAfterPublish -eq $Point) { throw "Injected disposable relocation failure at activation point $Point." }
}

function Get-JournalProperty {
    param([object]$Journal, [string]$Name)
    $property = $Journal.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "Pending relocation journal is missing: $Name" }
    return $property.Value
}

function Repair-PendingRelocation {
    if (-not [IO.File]::Exists($journalPath)) {
        if ([IO.Directory]::Exists($journalPath)) { throw 'The pending relocation journal path is a directory.' }
        return $false
    }
    [void](Assert-NormalFile -File $journalPath)
    Assert-ResultAcl -Path $journalPath -UserSid $currentSid
    $loaded = Read-JsonObject -File $journalPath
    $journal = $loaded.Json
    foreach ($name in @(
        'schema_version','action','request_nonce','request_digest','request_user_sid','expected_config_sha256',
        'plan_id','previous_config_generation','config_generation','destination_volume_serial',
        'source_storage_mode','destination_storage_mode','drivefs_my_drive_root','drivefs_cache_directory',
        'repository_manifest_sha256','repository_file_count','repository_bytes',
        'old_repository','new_repository','old_recovery_tools','new_recovery_tools','repository_stage','recovery_stage',
        'destination_initially_existed','recovery_initially_existed','original_config_base64',
        'destination_original_sddl','recovery_original_sddl',
        'destination_original_attributes','recovery_original_attributes',
        'original_runtime_manifest_base64','intended_config_sha256','intended_runtime_manifest_sha256','state'
    )) { [void](Get-JournalProperty -Journal $journal -Name $name) }
    if ($journal.schema_version -ne 1 -or [string]$journal.action -cne 'relocate' -or
        [string]$journal.request_nonce -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$journal.request_digest -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$journal.expected_config_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$journal.intended_config_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$journal.intended_runtime_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$journal.repository_manifest_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$journal.source_storage_mode -notin @($localNtfsMode, $driveFsMode) -or
        [string]$journal.destination_storage_mode -notin @($localNtfsMode, $driveFsMode) -or
        [long]$journal.repository_file_count -le 0 -or [long]$journal.repository_bytes -lt 0 -or
        [string]$journal.destination_volume_serial -cnotmatch '^[0-9A-Fa-f]{8}$' -or
        [string]$journal.state -notin @('copying','verifying','prepared','repository_promoted','recovery_promoted','config_published','manifest_published','committed')) {
        throw 'Pending relocation journal has an invalid protocol header.'
    }
    if (-not [string]::Equals([string]$journal.request_user_sid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Pending relocation journal belongs to another Windows user.'
    }
    $oldRepository = Get-CanonicalLocalPath -Value ([string]$journal.old_repository)
    $pendingNew = Get-CanonicalLocalPath -Value ([string]$journal.new_repository)
    $oldRecovery = Get-CanonicalLocalPath -Value ([string]$journal.old_recovery_tools)
    $pendingRecovery = Get-CanonicalLocalPath -Value ([string]$journal.new_recovery_tools)
    $pendingParent = Get-CanonicalLocalPath -Value (Split-Path -Parent $pendingNew)
    $script:recoveredOldRepository = $oldRepository
    $script:recoveredOldRecovery = $oldRecovery
    $script:recoveredNewRepository = $pendingNew
    $script:recoveredNewRecovery = $pendingRecovery
    $pendingStorageMode = [string]$journal.destination_storage_mode
    $oldStorageMode = [string]$journal.source_storage_mode
    $expectedOldRecovery = if ($oldStorageMode -eq $driveFsMode) {
        $driveFsRecoveryRoot
    } else {
        Get-CanonicalLocalPath -Value (Join-Path (Split-Path -Parent $oldRepository) 'RecoveryTools')
    }
    $expectedPendingRecovery = if ($pendingStorageMode -eq $driveFsMode) {
        $driveFsRecoveryRoot
    } else {
        Get-CanonicalLocalPath -Value (Join-Path $pendingParent 'RecoveryTools')
    }
    $expectedRepositoryStage = Get-CanonicalLocalPath -Value (Join-Path $pendingParent ".restic-repository-$($journal.request_nonce).staging")
    $expectedRecoveryParent = Get-CanonicalLocalPath -Value (Split-Path -Parent $expectedPendingRecovery)
    $expectedRecoveryStage = Get-CanonicalLocalPath -Value (Join-Path $expectedRecoveryParent ".restic-recovery-$($journal.request_nonce).staging")
    if (-not (Test-PathEqual -Left $oldRecovery -Right $expectedOldRecovery) -or
        -not (Test-PathEqual -Left $pendingRecovery -Right $expectedPendingRecovery) -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$journal.repository_stage)) -Right $expectedRepositoryStage) -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$journal.recovery_stage)) -Right $expectedRecoveryStage) -or
        (Test-PathEqual -Left (Split-Path -Parent $oldRepository) -Right $pendingParent) -or
        (Test-PathEqual -Left $oldRecovery -Right $pendingRecovery)) {
        throw 'Pending relocation journal paths are not the exact v1 repository/recovery/staging layout.'
    }
    if ($pendingStorageMode -eq $driveFsMode) {
        if (-not (Test-PathEqual -Left ([string]$journal.drivefs_my_drive_root) -Right $expectedDriveFsRoot) -or
            -not (Test-PathEqual -Left ([string]$journal.drivefs_cache_directory) -Right $expectedDriveFsCache) -or
            -not (Test-IsWithin -Candidate $pendingNew -Parent $expectedDriveFsRoot) -or
            [bool]$journal.destination_initially_existed) {
            throw 'Pending relocation journal has invalid DriveFS bindings.'
        }
    }
    elseif ($null -ne $journal.drivefs_my_drive_root -or $null -ne $journal.drivefs_cache_directory) {
        throw 'Pending local relocation journal unexpectedly contains DriveFS bindings.'
    }
    $expectedPendingDigest = Get-RequestDigest -Sid $currentSid -CurrentRepository $oldRepository `
        -Destination $pendingNew -ConfigSha256 ([string]$journal.expected_config_sha256) -Nonce ([string]$journal.request_nonce)
    if (-not [string]::Equals($expectedPendingDigest, [string]$journal.request_digest, [StringComparison]::Ordinal)) {
        throw 'Pending relocation journal request binding is invalid.'
    }
    try {
        [byte[]]$savedConfig = [Convert]::FromBase64String([string]$journal.original_config_base64)
        [byte[]]$savedManifest = [Convert]::FromBase64String([string]$journal.original_runtime_manifest_base64)
    }
    catch { throw 'Pending relocation journal contains invalid original metadata.' }
    $savedConfigHash = Get-Sha256Hex -Bytes $savedConfig
    $savedManifestHash = Get-Sha256Hex -Bytes $savedManifest
    if ($savedConfigHash -ne [string]$journal.expected_config_sha256) {
        throw 'Pending relocation journal original configuration hash is invalid.'
    }
    $savedConfigJson = [Text.UTF8Encoding]::new($false, $true).GetString($savedConfig) | ConvertFrom-Json
    if (-not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$savedConfigJson.repository)) -Right $oldRepository) -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$savedConfigJson.recovery_tools_directory)) -Right $oldRecovery)) {
        throw 'Pending relocation journal original configuration does not bind the retained repository.'
    }
    $savedStorage = Get-ConfiguredStorageBinding -Configuration $savedConfigJson `
        -Repository $oldRepository -RecoveryTools $oldRecovery
    if (-not [string]::Equals($savedStorage.Mode, $oldStorageMode, [StringComparison]::Ordinal)) {
        throw 'Pending relocation journal source storage mode does not match its original configuration.'
    }
    $savedPlan = Get-ValidatedPlanSchema -Configuration $savedConfigJson
    if (-not [string]::Equals($savedPlan.PlanId, [string]$journal.plan_id, [StringComparison]::Ordinal) -or
        $savedPlan.ConfigGeneration -eq [long]::MaxValue -or
        $savedPlan.ConfigGeneration -ne [long]$journal.previous_config_generation -or
        [long]$journal.config_generation -ne ($savedPlan.ConfigGeneration + 1)) {
        throw 'Pending relocation journal plan identity or generation transition is invalid.'
    }
    $script:planId = $savedPlan.PlanId
    $script:previousConfigGeneration = $savedPlan.ConfigGeneration
    $script:newConfigGeneration = [long]$journal.config_generation
    $savedManifestJson = [Text.UTF8Encoding]::new($false, $true).GetString($savedManifest) | ConvertFrom-Json
    $configRecords = @($savedManifestJson.files | Where-Object {
        [string]::Equals([string]$_.relative_path, 'backup-config.json', [StringComparison]::OrdinalIgnoreCase)
    })
    if ($configRecords.Count -ne 1 -or [string]$configRecords[0].sha256 -ne $savedConfigHash -or
        [long]$configRecords[0].bytes -ne $savedConfig.Length) {
        throw 'Pending relocation journal original runtime manifest does not bind its configuration.'
    }
    $currentConfigHash = Get-FileSha256Hex -File $configPath
    $currentManifestHash = Get-FileSha256Hex -File $runtimeManifestPath
    if ($currentConfigHash -notin @($savedConfigHash, [string]$journal.intended_config_sha256) -or
        $currentManifestHash -notin @($savedManifestHash, [string]$journal.intended_runtime_manifest_sha256)) {
        throw 'Protected metadata changed outside the pending relocation transaction; automatic recovery is unsafe.'
    }

    # Restore known originals first while run.lock is held. Until the journal is
    # deleted, the Python loader still refuses to start any backup.
    if ($currentConfigHash -ne $savedConfigHash) { Set-AtomicFileBytes -Target $configPath -Bytes $savedConfig }
    if ($currentManifestHash -ne $savedManifestHash) { Set-AtomicFileBytes -Target $runtimeManifestPath -Bytes $savedManifest }

    $savedCanonicalCurrent = $canonicalCurrent
    $savedCanonicalHash = $canonicalConfigHash
    try {
        $script:canonicalCurrent = $oldRepository
        $script:canonicalConfigHash = $savedConfigHash
        $validatedOld = Get-ValidatedConfiguration
        [void](Get-ValidatedRuntimeManifest)
    }
    finally {
        $script:canonicalCurrent = $savedCanonicalCurrent
        $script:canonicalConfigHash = $savedCanonicalHash
    }
    [void](Get-ValidatedRecoveryBundle -Directory $oldRecovery -ExpectedRepository $oldRepository -ExpectedPlan $validatedOld)
    $oldIdentity = Get-ResticIdentity -Validated $validatedOld -Repository $oldRepository
    $pendingJson = ($savedConfigJson | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $pendingJson.repository = $pendingNew
    $pendingJson.repository_volume_serial = ([string]$journal.destination_volume_serial).ToUpperInvariant()
    $pendingJson.recovery_tools_directory = $pendingRecovery
    $pendingJson.config_generation = [long]$journal.config_generation
    Set-JsonProperty -Object $pendingJson -Name 'repository_storage_mode' -Value $pendingStorageMode
    if ($null -ne $pendingJson.PSObject.Properties['repository_drivefs_root']) {
        $pendingJson.PSObject.Properties.Remove('repository_drivefs_root')
    }
    if ($pendingStorageMode -eq $driveFsMode) {
        Set-JsonProperty -Object $pendingJson -Name 'drivefs_my_drive_root' -Value $expectedDriveFsRoot
        Set-JsonProperty -Object $pendingJson -Name 'drivefs_cache_directory' -Value $expectedDriveFsCache
    }
    else {
        foreach ($name in @('drivefs_my_drive_root','drivefs_cache_directory')) {
            if ($null -ne $pendingJson.PSObject.Properties[$name]) {
                $pendingJson.PSObject.Properties.Remove($name)
            }
        }
    }
    $expectedPendingPlan = [pscustomobject]@{
        Json = $pendingJson
        PlanId = $validatedOld.PlanId
        ConfigGeneration = [long]$journal.config_generation
        CloudPlaceholderPolicy = $validatedOld.CloudPlaceholderPolicy
        Sources = $validatedOld.Sources
        IdentityMap = $validatedOld.IdentityMap
        StorageMode = $pendingStorageMode
        DriveFsRoot = if ($pendingStorageMode -eq $driveFsMode) { $expectedDriveFsRoot } else { $null }
        DriveFsCache = if ($pendingStorageMode -eq $driveFsMode) { $expectedDriveFsCache } else { $null }
    }

    $repoStageExists = Test-Path -LiteralPath $expectedRepositoryStage -PathType Container
    $recoveryStageExists = Test-Path -LiteralPath $expectedRecoveryStage -PathType Container
    $repoPromotedByState = [string]$journal.state -in @(
        'repository_promoted','recovery_promoted','config_published','manifest_published','committed'
    )
    $recoveryPromotedByState = [string]$journal.state -in @(
        'recovery_promoted','config_published','manifest_published','committed'
    )
    $repoOwned = $repoPromotedByState -or (
        [string]$journal.state -eq 'prepared' -and -not $repoStageExists -and
        (Test-Path -LiteralPath $pendingNew -PathType Container)
    )
    $recoveryOwned = $recoveryPromotedByState -or (
        [string]$journal.state -eq 'repository_promoted' -and -not $recoveryStageExists -and
        (Test-Path -LiteralPath $pendingRecovery -PathType Container)
    )
    $candidates = [Collections.Generic.List[object]]::new()
    if ($repoStageExists) { $candidates.Add([pscustomobject]@{ Path = $expectedRepositoryStage; Kind = 'repository' }) }
    if ($repoOwned -and (Test-Path -LiteralPath $pendingNew -PathType Container)) {
        $candidates.Add([pscustomobject]@{ Path = $pendingNew; Kind = 'repository' })
    }
    if ($recoveryStageExists) { $candidates.Add([pscustomobject]@{ Path = $expectedRecoveryStage; Kind = 'recovery' }) }
    if ($recoveryOwned -and (Test-Path -LiteralPath $pendingRecovery -PathType Container)) {
        $candidates.Add([pscustomobject]@{ Path = $pendingRecovery; Kind = 'recovery' })
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path)) { continue }
        $isDriveFsRepositoryCandidate = $candidate.Kind -eq 'repository' -and
            $pendingStorageMode -eq $driveFsMode
        if ($isDriveFsRepositoryCandidate) {
            Assert-NormalDirectoryChain -Directory $candidate.Path
        }
        else {
            Assert-ProtectedTreeAcl -Path $candidate.Path
        }
        $ownershipMarker = Join-Path $candidate.Path '.relocation-owner.json'
        if ([string]$journal.state -eq 'copying' -and
            ((Test-PathEqual -Left $candidate.Path -Right $expectedRepositoryStage) -or
             (Test-PathEqual -Left $candidate.Path -Right $expectedRecoveryStage))) {
            # In copying state, an exact protected nonce stage may be empty or
            # partial if power failed between directory creation and its marker.
            # Exact journal path + protected ACL is the ownership proof for
            # NTFS. DriveFS cannot enforce that ACL and therefore requires its
            # nonce-bound marker even in the copying state.
            if ($isDriveFsRepositoryCandidate -and
                -not (Test-Path -LiteralPath $ownershipMarker -PathType Leaf)) {
                throw 'Unmarked DriveFS staging cannot be removed automatically.'
            }
            if (Test-Path -LiteralPath $ownershipMarker -PathType Leaf) {
                Assert-StageOwnershipMarker -Directory $candidate.Path -Journal $journal
            }
        }
        elseif (Test-Path -LiteralPath $ownershipMarker -PathType Leaf) {
            Assert-StageOwnershipMarker -Directory $candidate.Path -Journal $journal
        }
        elseif ($candidate.Kind -eq 'repository') {
            $candidateIdentity = Get-ResticIdentity -Validated $validatedOld -Repository $candidate.Path
            Assert-ResticIdentityEqual -Expected $oldIdentity -Actual $candidateIdentity
            $candidateInventory = Get-TreeInventory -Root $candidate.Path -ExcludeRepositoryLocks
            if ($candidateInventory.Records.Count -ne [long]$journal.repository_file_count -or
                $candidateInventory.Bytes -ne [long]$journal.repository_bytes -or
                -not [string]::Equals(
                    $candidateInventory.ManifestSha256,
                    [string]$journal.repository_manifest_sha256,
                    [StringComparison]::Ordinal
                )) {
                throw 'Pending relocation repository does not match its commit manifest.'
            }
        }
        else {
            [void](Get-ValidatedRecoveryBundle -Directory $candidate.Path -ExpectedRepository $pendingNew `
                -ExpectedPlan $expectedPendingPlan)
        }
    }
    if (Test-Path -LiteralPath $expectedRepositoryStage) {
        Remove-OwnedTree -Path $expectedRepositoryStage -ExpectedParent $pendingParent
    }
    if (Test-Path -LiteralPath $expectedRecoveryStage) {
        Remove-OwnedTree -Path $expectedRecoveryStage -ExpectedParent $expectedRecoveryParent
    }
    if ($repoOwned -and (Test-Path -LiteralPath $pendingNew)) {
        Remove-OwnedTree -Path $pendingNew -ExpectedParent $pendingParent
    }
    if ([bool]$journal.destination_initially_existed -and -not (Test-Path -LiteralPath $pendingNew)) {
        Restore-EmptyDirectorySecurity -Path $pendingNew -Sddl ([string]$journal.destination_original_sddl) `
            -Attributes ([int]$journal.destination_original_attributes)
    }
    if ($recoveryOwned -and (Test-Path -LiteralPath $pendingRecovery)) {
        Remove-OwnedTree -Path $pendingRecovery -ExpectedParent $expectedRecoveryParent
    }
    if ([bool]$journal.recovery_initially_existed -and -not (Test-Path -LiteralPath $pendingRecovery)) {
        Restore-EmptyDirectorySecurity -Path $pendingRecovery -Sddl ([string]$journal.recovery_original_sddl) `
            -Attributes ([int]$journal.recovery_original_attributes)
    }
    [IO.File]::Delete($journalPath)
    return $true
}

function Assert-PublishedConfiguration {
    param(
        [string]$ExpectedRepository,
        [string]$ExpectedRecovery,
        [string]$ExpectedVolume,
        [pscustomobject]$ExpectedPlan
    )
    $published = (Read-JsonObject -File $configPath).Json
    if (-not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$published.repository)) -Right $ExpectedRepository) -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$published.recovery_tools_directory)) -Right $ExpectedRecovery) -or
        -not [string]::Equals([string]$published.repository_volume_serial, $ExpectedVolume, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Published protected repository configuration differs from the staged transaction.'
    }
    $publishedStorage = Get-ConfiguredStorageBinding -Configuration $published `
        -Repository $ExpectedRepository -RecoveryTools $ExpectedRecovery
    if (-not [string]::Equals($publishedStorage.Mode, $ExpectedPlan.StorageMode, [StringComparison]::Ordinal) -or
        ($publishedStorage.Mode -eq $driveFsMode -and
         (-not (Test-PathEqual -Left $publishedStorage.DriveFsRoot -Right $ExpectedPlan.DriveFsRoot) -or
          -not (Test-PathEqual -Left $publishedStorage.DriveFsCache -Right $ExpectedPlan.DriveFsCache)))) {
        throw 'Published repository storage binding differs from the staged transaction.'
    }
    $publishedPlan = Get-ValidatedPlanSchema -Configuration $published
    if (-not [string]::Equals($publishedPlan.PlanId, $ExpectedPlan.PlanId, [StringComparison]::Ordinal) -or
        $publishedPlan.ConfigGeneration -ne [long]$ExpectedPlan.ConfigGeneration -or
        -not [string]::Equals(
            $publishedPlan.CloudPlaceholderPolicy,
            $ExpectedPlan.CloudPlaceholderPolicy,
            [StringComparison]::Ordinal
        )) {
        throw 'Published protected plan identity or generation differs from the staged transaction.'
    }
    Assert-SourceListsEqual -Expected $ExpectedPlan.Sources -Actual @($published.sources) `
        -Message 'Published protected sources differ from the staged transaction.'
    $publishedIdentities = Get-ValidatedSourceIdentityMap -Configuration $published -Sources $ExpectedPlan.Sources
    Assert-SourceIdentityMapsEqual -Expected $ExpectedPlan.IdentityMap -Actual $publishedIdentities.Map `
        -Message 'Published protected source identities differ from the staged transaction.'
    Assert-JsonPropertyEqual -Expected $ExpectedPlan.Json -Actual $published -Name 'topology_paths' `
        -Message 'Published protected topology paths differ from the staged transaction.'
}

try {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'Repository relocation requires 64-bit Windows PowerShell.'
    }
    if ($isTestMode) {
        if (Test-Administrator) { throw 'Disposable repository-manager tests must run without an elevated token.' }
    }
    elseif (-not (Test-Administrator)) {
        throw 'Repository relocation must be run elevated.'
    }
    if (-not $isTestMode -and ($TestFailAfterPublish -ne 0 -or $TestCrashAfterPublish -ne 0 -or
        $TestCrashDuringCopyAfterFiles -ne 0 -or $TestCrashAfterStageCreation -ne 0 -or
        $TestCrashAfterEmptyDestinationRemoval -ne 0 -or
        $TestAvailableBytes -ne -1)) {
        throw 'Failure and capacity injection are available only for disposable tests.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or
        -not [string]::Equals($ExpectedUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approve elevation with the same Windows account that requested repository relocation.'
    }
    if ($RequestNonce -cnotmatch '^[0-9a-f]{64}$' -or $RequestDigest -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Nonce and request digest must be lowercase hexadecimal.'
    }
    $canonicalNonce = $RequestNonce
    $canonicalDigest = $RequestDigest
    if ($Action -eq 'Recover') {
        if ($ExpectedJournalSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Expected journal SHA-256 must be lowercase hexadecimal.'
        }
        $canonicalJournalHash = $ExpectedJournalSha256
    }
    else {
        if ($ExpectedConfigSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Expected configuration SHA-256 must be lowercase hexadecimal.'
        }
        $canonicalConfigHash = $ExpectedConfigSha256
        $canonicalCurrent = Get-CanonicalLocalPath -Value $ExpectedCurrentRepository
        $canonicalNew = Get-CanonicalLocalPath -Value $NewRepository
        if (Test-PathEqual -Left $canonicalCurrent -Right $canonicalNew) {
            throw 'The new repository must differ from the current repository.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Repository relocation must run as an installed script, not dot-sourced.'
    }
    $actualScript = [IO.Path]::GetFullPath($PSCommandPath)
    $expectedScript = Join-Path $installRoot 'Manage-Repository.ps1'
    if (-not (Test-PathEqual -Left $actualScript -Right $expectedScript)) {
        throw "Refusing to relocate a repository outside the protected installation: $actualScript"
    }
    foreach ($directory in @($installRoot, $stateRoot)) { Assert-NormalDirectoryChain -Directory $directory }
    [void](Assert-NormalFile -File $actualScript)
    Initialize-ResultChannel
    Write-Progress -Stage preflight -Message $(if ($Action -eq 'Recover') {
        'Validating the pending protected relocation journal.'
    } else { 'Validating the protected repository and destination.' }) -Percent 1 -Cancellable $false

    $lockStream = Enter-RunLock -File $lockPath
    $credentialRotationJournal = Join-Path $stateRoot 'credential-rotation.journal.json'
    if ([IO.File]::Exists($credentialRotationJournal) -or [IO.Directory]::Exists($credentialRotationJournal)) {
        throw 'A pending credential rotation must be recovered before repository relocation.'
    }
    if ($Action -eq 'Recover') {
        if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
            throw 'No pending repository relocation journal exists.'
        }
        if ((Get-FileSha256Hex -File $journalPath) -ne $canonicalJournalHash) {
            throw 'The pending relocation journal changed after recovery was requested.'
        }
        if (-not (Repair-PendingRelocation)) { throw 'No pending repository relocation was recovered.' }
        $canonicalCurrent = $recoveredOldRepository
        $canonicalNew = $recoveredNewRepository
        Write-Progress -Stage complete -Message 'Pending relocation safely rolled back to the retained old repository.' -Percent 100 -Cancellable $false
        Write-RecoveryResult -Ok $true -ErrorMessage $null
        exit 0
    }
    if ([IO.File]::Exists($journalPath) -or [IO.Directory]::Exists($journalPath)) {
        if (Repair-PendingRelocation) {
            Write-Progress -Stage preflight -Message 'Recovered a pending relocation safely; refresh and retry the request.' -Percent 0 -Cancellable $false
            throw 'A pending repository relocation was safely rolled back to the retained old repository. Refresh and retry.'
        }
    }
    $validated = Get-ValidatedConfiguration
    $planId = $validated.PlanId
    $previousConfigGeneration = [long]$validated.ConfigGeneration
    if ($previousConfigGeneration -eq [long]::MaxValue) {
        throw 'Configured config_generation cannot be incremented because it reached the supported maximum.'
    }
    $newConfigGeneration = $previousConfigGeneration + 1
    $runtime = Get-ValidatedRuntimeManifest
    [void](Get-ValidatedRecoveryBundle -Directory $validated.RecoveryTools `
        -ExpectedRepository $validated.Repository -ExpectedPlan $validated)

    $sourceStorageMode = $validated.StorageMode
    $destinationStorageMode = Get-StorageModeForPath -Repository $canonicalNew
    if ($destinationStorageMode -eq $driveFsMode) {
        Assert-ReadyDriveFsDestination -Destination $canonicalNew
        $destinationDriveFsRoot = $expectedDriveFsRoot
        $destinationDriveFsCache = $expectedDriveFsCache
    }
    else {
        Assert-ReadyNtfsDestination -Destination $canonicalNew
        $destinationDriveFsRoot = $null
        $destinationDriveFsCache = $null
    }
    $currentParent = Get-CanonicalLocalPath -Value (Split-Path -Parent $validated.Repository)
    $newParent = Get-CanonicalLocalPath -Value (Split-Path -Parent $canonicalNew)
    if (Test-PathEqual -Left $currentParent -Right $newParent) {
        throw 'Relocation requires a different parent for the destination repository.'
    }
    $newRecovery = if ($destinationStorageMode -eq $driveFsMode) {
        $driveFsRecoveryRoot
    } else {
        Get-CanonicalLocalPath -Value (Join-Path $newParent 'RecoveryTools')
    }
    if (Test-PathEqual -Left $newRecovery -Right $validated.RecoveryTools) {
        throw 'Relocation requires a distinct NTFS recovery-tools destination.'
    }
    Assert-ReadyNtfsDestination -Destination $newRecovery
    Assert-NoOverlap -Candidate $canonicalNew -Other $newRecovery -Message 'New repository overlaps its recovery tools'
    foreach ($protected in $validated.ProtectedPaths) {
        Assert-NoOverlap -Candidate $canonicalNew -Other $protected -Message 'New repository overlaps protected backup state'
        Assert-NoOverlap -Candidate $newRecovery -Other $protected -Message 'New recovery tools overlap protected backup state'
    }
    foreach ($source in $validated.Sources) {
        Assert-NoOverlap -Candidate $canonicalNew -Other $source -Message 'New repository overlaps a configured source'
        Assert-NoOverlap -Candidate $newRecovery -Other $source -Message 'New recovery tools overlap a configured source'
    }

    $destinationInitiallyExisted = Test-Path -LiteralPath $canonicalNew -PathType Container
    $recoveryInitiallyExisted = Test-Path -LiteralPath $newRecovery -PathType Container
    if ($destinationInitiallyExisted) {
        $destinationOriginalSddl = (Get-Acl -LiteralPath $canonicalNew).GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::All)
        $destinationOriginalAttributes = [int](Get-Item -LiteralPath $canonicalNew -Force).Attributes
    }
    if ($recoveryInitiallyExisted) {
        $recoveryOriginalSddl = (Get-Acl -LiteralPath $newRecovery).GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::All)
        $recoveryOriginalAttributes = [int](Get-Item -LiteralPath $newRecovery -Force).Attributes
    }
    $repositoryStage = Join-Path $newParent ".restic-repository-$canonicalNonce.staging"
    $recoveryParent = Get-CanonicalLocalPath -Value (Split-Path -Parent $newRecovery)
    $recoveryStage = Join-Path $recoveryParent ".restic-recovery-$canonicalNonce.staging"
    foreach ($stage in @($repositoryStage, $recoveryStage)) {
        if (Test-Path -LiteralPath $stage) { throw "Nonce staging path already exists: $stage" }
        Assert-NoOverlap -Candidate $stage -Other $canonicalNew -Message 'Staging overlaps destination'
        Assert-NoOverlap -Candidate $stage -Other $newRecovery -Message 'Staging overlaps recovery destination'
    }

    $repositoryInventory = Get-TreeInventory -Root $validated.Repository -ExcludeRepositoryLocks
    $recoveryInventory = Get-TreeInventory -Root $validated.RecoveryTools
    $repositoryManifestSha256 = $repositoryInventory.ManifestSha256
    $filesTotal = [long]$repositoryInventory.Files.Count + [long]$recoveryInventory.Files.Count
    $bytesTotal = [long]$repositoryInventory.Bytes + [long]$recoveryInventory.Bytes
    if ($filesTotal -le 0 -or $repositoryInventory.Files.Count -le 0) {
        throw 'The current repository inventory is unexpectedly empty.'
    }
    if ($destinationStorageMode -eq $driveFsMode -and
        $repositoryInventory.MaximumBytes -ge $driveFsObjectLimitBytes) {
        throw 'DriveFS cannot host a repository containing an object of 4 GiB or larger.'
    }
    $minimumFree = 0L
    if ($validated.Json.PSObject.Properties['minimum_free_gib']) {
        $minimumFree = [long]([double]$validated.Json.minimum_free_gib * 1GB)
        if ($minimumFree -lt 0) { throw 'Configured minimum_free_gib is invalid.' }
    }
    $available = if ($TestAvailableBytes -ge 0) { $TestAvailableBytes } else {
        ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($canonicalNew))).AvailableFreeSpace
    }
    $required = $bytesTotal + $minimumFree
    if ($available -lt $required) {
        throw "The destination has insufficient space: $available bytes available, $required bytes required for the copy and configured reserve."
    }

    $destinationSerial = Get-VolumeSerial -Path $canonicalNew
    $liveJson = ([Text.UTF8Encoding]::new($false, $true).GetString($validated.RawBytes) | ConvertFrom-Json)
    $liveJson.repository = $canonicalNew
    $liveJson.repository_volume_serial = $destinationSerial
    $liveJson.recovery_tools_directory = $newRecovery
    $liveJson.config_generation = $newConfigGeneration
    Set-JsonProperty -Object $liveJson -Name 'repository_storage_mode' -Value $destinationStorageMode
    $legacyRoot = $liveJson.PSObject.Properties['repository_drivefs_root']
    if ($null -ne $legacyRoot) { $liveJson.PSObject.Properties.Remove('repository_drivefs_root') }
    if ($destinationStorageMode -eq $driveFsMode) {
        Set-JsonProperty -Object $liveJson -Name 'drivefs_my_drive_root' -Value $destinationDriveFsRoot
        Set-JsonProperty -Object $liveJson -Name 'drivefs_cache_directory' -Value $destinationDriveFsCache
    }
    else {
        foreach ($name in @('drivefs_my_drive_root', 'drivefs_cache_directory')) {
            if ($null -ne $liveJson.PSObject.Properties[$name]) { $liveJson.PSObject.Properties.Remove($name) }
        }
    }
    $stagedPlan = [pscustomobject]@{
        Json = $liveJson
        PlanId = $validated.PlanId
        ConfigGeneration = $newConfigGeneration
        CloudPlaceholderPolicy = $validated.CloudPlaceholderPolicy
        Sources = $validated.Sources
        IdentityMap = $validated.IdentityMap
        StorageMode = $destinationStorageMode
        DriveFsRoot = $destinationDriveFsRoot
        DriveFsCache = $destinationDriveFsCache
    }
    [byte[]]$newConfigBytes = ConvertTo-Utf8JsonBytes -Value $liveJson
    [byte[]]$newManifestBytes = New-RuntimeManifestBytes -Manifest $runtime.Json -NewConfigBytes $newConfigBytes
    $originalConfigBytes = $validated.RawBytes
    $originalManifestBytes = $runtime.RawBytes
    $script:journalDocument = [ordered]@{
        schema_version = 1
        action = 'relocate'
        request_nonce = $canonicalNonce
        request_digest = $canonicalDigest
        request_user_sid = $currentSid
        expected_config_sha256 = $canonicalConfigHash
        plan_id = $validated.PlanId
        previous_config_generation = $previousConfigGeneration
        config_generation = $newConfigGeneration
        destination_volume_serial = $destinationSerial
        source_storage_mode = $sourceStorageMode
        destination_storage_mode = $destinationStorageMode
        drivefs_my_drive_root = $destinationDriveFsRoot
        drivefs_cache_directory = $destinationDriveFsCache
        repository_manifest_sha256 = $repositoryInventory.ManifestSha256
        repository_file_count = [long]$repositoryInventory.Records.Count
        repository_bytes = [long]$repositoryInventory.Bytes
        old_repository = $validated.Repository
        new_repository = $canonicalNew
        old_recovery_tools = $validated.RecoveryTools
        new_recovery_tools = $newRecovery
        repository_stage = $repositoryStage
        recovery_stage = $recoveryStage
        destination_initially_existed = $destinationInitiallyExisted
        recovery_initially_existed = $recoveryInitiallyExisted
        destination_original_sddl = $destinationOriginalSddl
        recovery_original_sddl = $recoveryOriginalSddl
        destination_original_attributes = $destinationOriginalAttributes
        recovery_original_attributes = $recoveryOriginalAttributes
        original_config_base64 = [Convert]::ToBase64String($originalConfigBytes)
        original_runtime_manifest_base64 = [Convert]::ToBase64String($originalManifestBytes)
        intended_config_sha256 = Get-Sha256Hex -Bytes $newConfigBytes
        intended_runtime_manifest_sha256 = Get-Sha256Hex -Bytes $newManifestBytes
        state = 'copying'
        created_utc = [DateTime]::UtcNow.ToString('o')
        updated_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-Journal -State copying
    $sourceIdentity = Get-ResticIdentity -Validated $validated -Repository $validated.Repository
    $copyStartedUtc = [DateTime]::UtcNow
    Write-Progress -Stage copying -Message 'Copying the encrypted repository and recovery tools.' -Percent 5 -Cancellable $false
    New-RepositoryStagingDirectory -Path $repositoryStage -StorageMode $destinationStorageMode
    Write-StageOwnershipMarker -Directory $repositoryStage
    if ($TestCrashAfterStageCreation -eq 1) { Stop-Process -Id $PID -Force }
    New-ProtectedStagingDirectory -Path $recoveryStage
    Write-StageOwnershipMarker -Directory $recoveryStage
    if ($TestCrashAfterStageCreation -eq 2) { Stop-Process -Id $PID -Force }
    Copy-Inventory -Inventory $repositoryInventory -Destination $repositoryStage -ReportProgress $true
    Copy-Inventory -Inventory $recoveryInventory -Destination $recoveryStage -ReportProgress $true
    Update-StagedRecoveryBundle -Directory $recoveryStage -Repository $canonicalNew `
        -VolumeSerial $destinationSerial -RecoveryDirectory $newRecovery `
        -ExpectedBefore $validated -ExpectedAfter $stagedPlan

    Write-Journal -State verifying
    Assert-StageOwnershipMarker -Directory $repositoryStage -Journal $script:journalDocument
    Assert-StageOwnershipMarker -Directory $recoveryStage -Journal $script:journalDocument
    [IO.File]::Delete((Join-Path $repositoryStage '.relocation-owner.json'))
    [IO.File]::Delete((Join-Path $recoveryStage '.relocation-owner.json'))
    Write-Progress -Stage verifying -Message 'Verifying repository identity, snapshot history, and Restic structure.' -Percent 78 -Cancellable $false
    $copiedIdentity = Get-ResticIdentity -Validated $validated -Repository $repositoryStage
    Assert-ResticIdentityEqual -Expected $sourceIdentity -Actual $copiedIdentity
    [void](Invoke-ResticCapture -Validated $validated -Repository $repositoryStage -CommandArguments @('check'))
    [void](Assert-TreeMatchesInventory -Root $repositoryStage -Expected $repositoryInventory -ExcludeRepositoryLocks)
    [void](Assert-TreeMatchesInventory -Root $validated.Repository -Expected $repositoryInventory -ExcludeRepositoryLocks)
    $sourceIdentityAfterCopy = Get-ResticIdentity -Validated $validated -Repository $validated.Repository
    Assert-ResticIdentityEqual -Expected $sourceIdentity -Actual $sourceIdentityAfterCopy
    if ($destinationStorageMode -eq $localNtfsMode) {
        Set-ProtectedTreeAcl -Path $repositoryStage
    }
    Set-ProtectedTreeAcl -Path $recoveryStage
    Assert-RepositoryTreeSecurity -Path $repositoryStage -StorageMode $destinationStorageMode
    Assert-ProtectedTreeAcl -Path $recoveryStage

    Write-Journal -State prepared
    Write-Progress -Stage activating -Message 'Activating the verified copy with a rollback journal.' -Percent 92 -Cancellable $false

    Assert-EmptyDestinationUnchanged -Path $canonicalNew -InitiallyExisted $destinationInitiallyExisted -OriginalSddl $destinationOriginalSddl
    Assert-NormalDirectoryChain -Directory $repositoryStage
    [void](Assert-TreeMatchesInventory -Root $repositoryStage -Expected $repositoryInventory -ExcludeRepositoryLocks)
    Assert-RepositoryTreeSecurity -Path $repositoryStage -StorageMode $destinationStorageMode
    Assert-ResticIdentityEqual -Expected $sourceIdentity -Actual (Get-ResticIdentity -Validated $validated -Repository $repositoryStage)
    if ($destinationInitiallyExisted) { [IO.Directory]::Delete($canonicalNew, $false) }
    if ($TestCrashAfterEmptyDestinationRemoval -eq 1) { Stop-Process -Id $PID -Force }
    Move-Item -LiteralPath $repositoryStage -Destination $canonicalNew
    $repositoryStage = $null
    $repositoryPromoted = $true
    Assert-RepositoryTreeSecurity -Path $canonicalNew -StorageMode $destinationStorageMode
    Write-Journal -State repository_promoted
    Assert-InjectionAllowed -Point 1

    Assert-EmptyDestinationUnchanged -Path $newRecovery -InitiallyExisted $recoveryInitiallyExisted -OriginalSddl $recoveryOriginalSddl
    Assert-NormalDirectoryChain -Directory $recoveryStage
    [void](Get-TreeInventory -Root $recoveryStage)
    Assert-ProtectedTreeAcl -Path $recoveryStage
    [void](Get-ValidatedRecoveryBundle -Directory $recoveryStage -ExpectedRepository $canonicalNew `
        -ExpectedPlan $stagedPlan)
    if ($recoveryInitiallyExisted) { [IO.Directory]::Delete($newRecovery, $false) }
    if ($TestCrashAfterEmptyDestinationRemoval -eq 2) { Stop-Process -Id $PID -Force }
    Move-Item -LiteralPath $recoveryStage -Destination $newRecovery
    $recoveryStage = $null
    $recoveryPromoted = $true
    Assert-ProtectedTreeAcl -Path $newRecovery
    Write-Journal -State recovery_promoted
    Assert-InjectionAllowed -Point 2

    Assert-ActivationTrees -Validated $validated -ExpectedIdentity $sourceIdentity -ExpectedPlan $stagedPlan `
        -Repository $canonicalNew -Recovery $newRecovery -StorageMode $destinationStorageMode `
        -RepositoryInventory $repositoryInventory
    if ((Get-FileSha256Hex -File $configPath) -ne (Get-Sha256Hex -Bytes $originalConfigBytes) -or
        (Get-FileSha256Hex -File $runtimeManifestPath) -ne (Get-Sha256Hex -Bytes $originalManifestBytes)) {
        throw 'Protected metadata changed before the repository configuration switch.'
    }
    Set-AtomicFileBytes -Target $configPath -Bytes $newConfigBytes
    Write-Journal -State config_published
    Assert-InjectionAllowed -Point 3
    Assert-ActivationTrees -Validated $validated -ExpectedIdentity $sourceIdentity -ExpectedPlan $stagedPlan `
        -Repository $canonicalNew -Recovery $newRecovery -StorageMode $destinationStorageMode `
        -RepositoryInventory $repositoryInventory
    if ((Get-FileSha256Hex -File $configPath) -ne (Get-Sha256Hex -Bytes $newConfigBytes) -or
        (Get-FileSha256Hex -File $runtimeManifestPath) -ne (Get-Sha256Hex -Bytes $originalManifestBytes)) {
        throw 'Protected metadata changed before the runtime-manifest switch.'
    }
    Set-AtomicFileBytes -Target $runtimeManifestPath -Bytes $newManifestBytes
    Write-Journal -State manifest_published
    Assert-InjectionAllowed -Point 4

    Assert-PublishedConfiguration -ExpectedRepository $canonicalNew -ExpectedRecovery $newRecovery `
        -ExpectedVolume $destinationSerial -ExpectedPlan $stagedPlan
    [void](Get-ValidatedRuntimeManifest)
    [void](Get-ValidatedRecoveryBundle -Directory $newRecovery -ExpectedRepository $canonicalNew `
        -ExpectedPlan $stagedPlan)
    $finalIdentity = Get-ResticIdentity -Validated $validated -Repository $canonicalNew
    Assert-ResticIdentityEqual -Expected $sourceIdentity -Actual $finalIdentity
    [void](Assert-TreeMatchesInventory -Root $canonicalNew -Expected $repositoryInventory -ExcludeRepositoryLocks)
    if ($destinationStorageMode -eq $driveFsMode) {
        Assert-DriveFsProviderTransaction -Directory (Split-Path -Parent $canonicalNew)
    }
    [void](Assert-NormalFile -File (Join-Path $validated.Repository 'config'))
    [void](Get-ValidatedRecoveryBundle -Directory $validated.RecoveryTools `
        -ExpectedRepository $validated.Repository -ExpectedPlan $validated)
    Write-Journal -State committed
    [IO.File]::Delete($journalPath)
    $journalReady = $false
    Write-Progress -Stage complete -Message 'Repository relocation completed; the old repository was retained.' -Percent 100 -Cancellable $false
    Write-FinalResult -Ok $true -Changed $true -ErrorMessage $null
    exit 0
}
catch {
    $failure = $_.Exception.Message
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    if ($journalReady) {
        try {
            if ($null -ne $originalConfigBytes -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
                Set-AtomicFileBytes -Target $configPath -Bytes $originalConfigBytes
            }
        }
        catch { $rollbackErrors.Add("protected config: $($_.Exception.Message)") }
        try {
            if ($null -ne $originalManifestBytes -and (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
                Set-AtomicFileBytes -Target $runtimeManifestPath -Bytes $originalManifestBytes
            }
        }
        catch { $rollbackErrors.Add("runtime manifest: $($_.Exception.Message)") }
        try {
            if ($repositoryPromoted) {
                Remove-OwnedTree -Path $canonicalNew -ExpectedParent (Split-Path -Parent $canonicalNew)
            }
            if ($destinationInitiallyExisted -and -not (Test-Path -LiteralPath $canonicalNew)) {
                Restore-EmptyDirectorySecurity -Path $canonicalNew -Sddl $destinationOriginalSddl `
                    -Attributes $destinationOriginalAttributes
            }
        }
        catch { $rollbackErrors.Add("new repository: $($_.Exception.Message)") }
        try {
            if ($recoveryPromoted) {
                Remove-OwnedTree -Path $newRecovery -ExpectedParent (Split-Path -Parent $newRecovery)
            }
            if ($recoveryInitiallyExisted -and -not (Test-Path -LiteralPath $newRecovery)) {
                Restore-EmptyDirectorySecurity -Path $newRecovery -Sddl $recoveryOriginalSddl `
                    -Attributes $recoveryOriginalAttributes
            }
        }
        catch { $rollbackErrors.Add("new recovery tools: $($_.Exception.Message)") }
        if ($rollbackErrors.Count -eq 0) {
            try { [IO.File]::Delete($journalPath); $journalReady = $false }
            catch { $rollbackErrors.Add("journal cleanup: $($_.Exception.Message)") }
        }
    }
    foreach ($stage in @($repositoryStage, $recoveryStage)) {
        if (-not [string]::IsNullOrWhiteSpace($stage) -and (Test-Path -LiteralPath $stage)) {
            try { Remove-OwnedTree -Path $stage -ExpectedParent (Split-Path -Parent $stage) }
            catch { $rollbackErrors.Add("staging cleanup: $($_.Exception.Message)") }
        }
    }
    if ($rollbackErrors.Count -gt 0) {
        $failure = "$failure Rollback needs attention and the pending journal will keep backups blocked: $($rollbackErrors -join '; ')"
    }
    try { Write-Progress -Stage failed -Message $failure -Percent 0 -Cancellable $false } catch { }
    try {
        if ($Action -eq 'Recover') { Write-RecoveryResult -Ok $false -ErrorMessage $failure }
        else { Write-FinalResult -Ok $false -Changed $false -ErrorMessage $failure }
    }
    catch { }
    if ($isTestMode) {
        [Console]::Error.WriteLine($failure)
        [Console]::Error.WriteLine($_.ScriptStackTrace)
    }
    elseif (-not $resultChannelReady) {
        [Console]::Error.WriteLine($failure)
    }
    exit 1
}
finally {
    if ($null -ne $lockStream) { Exit-RunLock -Stream $lockStream }
}
