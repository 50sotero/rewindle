[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Add')]
    [string]$Add,
    [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
    [string]$Remove,
    [string]$ExpectedUserSid,
    [string]$ResultPath,
    [string]$RequestNonce,
    [string]$TestRoot,
    [ValidateRange(0, 4)]
    [int]$TestFailAfterPublish = 0,
    [ValidateSet('', 'JournalPrepared', 'Publish1', 'Publish2', 'Publish3', 'Publish4', 'NewVerified', 'Undo1', 'Undo2', 'Undo3', 'Undo4', 'JournalDeleted')]
    [string]$TestPauseAfter = '',
    [string]$TestPauseSentinelPath,
    [switch]$TestAllowElevatedProcess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot

$productName = 'ResticBackuper'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$localAppDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$defaultInstallRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
$isTestMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
if ($isTestMode) {
    $testContainer = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $temporaryPrefix = $temporaryRoot + '\'
    if ($testContainer -eq $temporaryRoot -or
        -not $testContainer.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable test root must be a child of the current user temporary directory.'
    }
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramFiles\$productName")).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramData\$productName")).TrimEnd('\')
}
else {
    $installRoot = $defaultInstallRoot
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
$configPath = Join-Path $installRoot 'backup-config.json'
$runtimeManifestPath = Join-Path $installRoot 'runtime-manifest.json'
$lockPath = Join-Path $stateRoot 'run.lock'
$journalPath = Join-Path $stateRoot 'source-update.journal.json'
$journalSchemaVersion = 1
$journalKind = 'resticbackuper-source-update-undo'
$journalMaximumBytes = 24MB
$journalTargetMaximumBytes = 4MB
# The dashboard's nonce-bound result channel: one protected result file per request, bound to the
# requesting SID, action, canonical path and nonce by a domain-separated SHA-256 request digest.
$resultRoot = Join-Path $stateRoot 'SourceManagerResults'
$sourceRequestDomain = 'ResticBackuper.SourceRequest.v1'
$resultChannelReady = $false
$requestDigest = $null
$lockStream = $null
$currentSid = $null
$Action = $PSCmdlet.ParameterSetName

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
    if (Test-PathEqual -Left $Candidate -Right $Parent) {
        return $true
    }
    $prefix = $Parent.TrimEnd('\') + '\'
    return $Candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CanonicalLocalPath {
    param(
        [string]$Value,
        [switch]$RequireDirectory
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'A non-empty absolute local path is required.'
    }
    if (-not [IO.Path]::IsPathRooted($Value) -or $Value.StartsWith('\\')) {
        throw "Only absolute local drive-letter paths are supported: $Value"
    }
    $full = [IO.Path]::GetFullPath($Value)
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$' -or $full.Substring(2).Contains(':')) {
        throw "Only normal local drive-letter paths are supported: $Value"
    }
    if (-not (Test-PathEqual -Left $full -Right $root)) {
        $full = $full.TrimEnd('\')
    }
    if ($RequireDirectory) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) {
            throw "Source directory does not exist: $full"
        }
    }
    return $full
}

function Assert-NormalDirectoryChain {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Directory does not exist: $Directory"
    }
    $current = Get-Item -LiteralPath $Directory -Force
    while ($null -ne $current) {
        if (-not $current.PSIsContainer -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Directory path contains a reparse point or non-directory component: $($current.FullName)"
        }
        $parent = $current.Parent
        if ($null -eq $parent) {
            break
        }
        $current = Get-Item -LiteralPath $parent.FullName -Force
    }
}

function Assert-NormalFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "Required regular file is missing: $File"
    }
    $item = Get-Item -LiteralPath $File -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Path is not a normal file: $File"
    }
}

function New-ProtectedJournalFileSecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $allow
        ))
    }
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $allow
        ))
    }
    return $security
}

function Assert-ProtectedSourceUpdateAcl {
    param([string]$Path, [string]$UserSid, [switch]$AllowInheritedRules)
    $acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -or
        (-not $AllowInheritedRules -and -not $acl.AreAccessRulesProtected)) {
        throw "Protected source-update path has an unsafe owner or inherited ACL: $Path"
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', $UserSid, 'S-1-3-4')
    $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor `
        [Security.AccessControl.FileSystemRights]::AppendData -bor `
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor `
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor `
        [Security.AccessControl.FileSystemRights]::Delete -bor `
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor `
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor `
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ((-not $AllowInheritedRules -and $rule.IsInherited) -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed) {
            throw "Protected source-update path has an unexpected ACL entry for $sid`: $Path"
        }
        if ($sid -in @('S-1-5-18', 'S-1-5-32-544')) {
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Protected source-update path lacks full control for $sid`: $Path"
            }
        }
        elseif (($rule.FileSystemRights -band $dangerous) -ne 0 -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            throw "Protected source-update path grants unsafe or insufficient rights to $sid`: $Path"
        }
        [void]$seen.Add($sid)
    }
    foreach ($requiredSid in $allowed) {
        if (-not $seen.Contains($requiredSid)) {
            throw "Protected source-update path ACL is missing $requiredSid`: $Path"
        }
    }
}

function New-ResultDirectorySecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            $allow
        ))
    }
    $readRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor `
        [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            $readRights,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            $allow
        ))
    }
    return $security
}

function New-ResultFileSecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $allow
        ))
    }
    $readRights = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor `
        [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            $readRights,
            $allow
        ))
    }
    return $security
}

function Assert-ResultAcl {
    param([string]$Path, [string]$UserSid)
    $acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -or -not $acl.AreAccessRulesProtected) {
        throw "Protected source-manager result path has an unsafe owner or inherited ACL: $Path"
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $UserSid)
    # CreateFiles/CreateDirectories alias WriteData/AppendData; both names stay so directory and
    # file write capabilities are visibly covered by the same fail-closed mask the dashboard uses.
    $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor `
        [Security.AccessControl.FileSystemRights]::CreateFiles -bor `
        [Security.AccessControl.FileSystemRights]::AppendData -bor `
        [Security.AccessControl.FileSystemRights]::CreateDirectories -bor `
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor `
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor `
        [Security.AccessControl.FileSystemRights]::Delete -bor `
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor `
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor `
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed) {
            throw "Protected source-manager result path has an unexpected ACL entry for $sid`: $Path"
        }
        if ($sid -in @('S-1-5-18', 'S-1-5-32-544')) {
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Protected source-manager result path lacks full control for $sid`: $Path"
            }
        }
        elseif (($rule.FileSystemRights -band $dangerous) -ne 0 -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            throw "Protected source-manager result path grants unsafe or insufficient rights to $sid`: $Path"
        }
        [void]$seen.Add($sid)
    }
    foreach ($requiredSid in @('S-1-5-18', 'S-1-5-32-544', $UserSid)) {
        if (-not $seen.Contains($requiredSid)) {
            throw "Protected source-manager result path ACL is missing $requiredSid`: $Path"
        }
    }
}

# The digest the dashboard computes before it asks for elevation (SourceManagerLauncher in the dashboard):
# domain, SID, lower-case action, canonical path and nonce, joined by LF and hashed as UTF-8 without a BOM.
function Get-SourceRequestDigest {
    param([string]$Sid, [string]$RequestAction, [string]$CanonicalPath, [string]$Nonce)
    $payload = $sourceRequestDomain + "`n" + $Sid + "`n" + $RequestAction.ToLowerInvariant() + "`n" +
        $CanonicalPath + "`n" + $Nonce
    return Get-Sha256Hex -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($payload))
}

function Assert-RequestNonce {
    if ($RequestNonce -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The source-manager request nonce is invalid.'
    }
}

function Initialize-ResultChannel {
    param([string]$UserSid, [string]$CanonicalPath)
    Assert-RequestNonce
    if ([string]::IsNullOrWhiteSpace($ResultPath)) {
        throw 'The dashboard must provide a protected source-manager result path.'
    }
    Assert-NormalDirectoryChain -Directory $stateRoot
    Assert-ResultAcl -Path $stateRoot -UserSid $UserSid
    if (Test-Path -LiteralPath $resultRoot) {
        Assert-NormalDirectoryChain -Directory $resultRoot
        Assert-ResultAcl -Path $resultRoot -UserSid $UserSid
    }
    else {
        [void][IO.Directory]::CreateDirectory($resultRoot, (New-ResultDirectorySecurity -UserSid $UserSid))
        Assert-NormalDirectoryChain -Directory $resultRoot
        Assert-ResultAcl -Path $resultRoot -UserSid $UserSid
    }
    $retentionCutoff = [DateTime]::UtcNow.AddDays(-7)
    foreach ($entry in Get-ChildItem -LiteralPath $resultRoot -Force) {
        if ($entry.PSIsContainer -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry.Name -cnotmatch '^[0-9a-f]{64}\.json$') {
            throw "The protected source-manager result directory contains an unexpected entry: $($entry.Name)"
        }
        Assert-ResultAcl -Path $entry.FullName -UserSid $UserSid
        if ($entry.LastWriteTimeUtc -lt $retentionCutoff) {
            [IO.File]::Delete($entry.FullName)
        }
    }
    $expectedResult = [IO.Path]::Combine($resultRoot, "$RequestNonce.json")
    $actualResult = [IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-PathEqual -Left $actualResult -Right $expectedResult)) {
        throw 'The source-manager result path does not match its request nonce.'
    }
    if ([IO.File]::Exists($actualResult) -or [IO.Directory]::Exists($actualResult)) {
        throw 'The source-manager result target already exists.'
    }
    $script:requestDigest = Get-SourceRequestDigest -Sid $UserSid -RequestAction $Action `
        -CanonicalPath $CanonicalPath -Nonce $RequestNonce
    $script:resultChannelReady = $true
}

function Get-SanitizedResultError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'The protected source change failed.'
    }
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $Message.ToCharArray()) {
        if (-not [char]::IsControl($character) -or $character -eq "`t") {
            [void]$builder.Append($character)
        }
    }
    $value = $builder.ToString().Trim()
    if ($value.Length -gt 2000) { $value = $value.Substring(0, 2000) }
    return $value
}

# The response, bound to its request. Disposable tests read it from standard output; an installed run
# writes it once (CreateNew) under the protected result directory with an administrator-owned ACL that
# lets the requesting user read it and nothing else, and checks that ACL before returning.
function Write-ManagerResult {
    param([Collections.IDictionary]$Response)
    $document = [ordered]@{ schema_version = 1 }
    if (-not [string]::IsNullOrWhiteSpace($RequestNonce)) {
        $document.request_nonce = $RequestNonce
        $document.request_digest = $requestDigest
        $document.request_user_sid = $currentSid
    }
    foreach ($key in $Response.Keys) {
        $document[$key] = $Response[$key]
    }
    if ($Response.Contains('error')) {
        $document.error = Get-SanitizedResultError -Message ([string]$Response.error)
    }
    if ($isTestMode) {
        $document | ConvertTo-Json -Compress -Depth 5
        return
    }
    if (-not $resultChannelReady) {
        throw 'The protected source-manager result channel is unavailable.'
    }
    [byte[]]$bytes = ConvertTo-Utf8JsonBytes -Value $document
    $target = [IO.Path]::GetFullPath($ResultPath)
    $stream = [IO.FileStream]::new(
        $target,
        [IO.FileMode]::CreateNew,
        [Security.AccessControl.FileSystemRights]::Write,
        [IO.FileShare]::None,
        4096,
        [IO.FileOptions]::WriteThrough,
        (New-ResultFileSecurity -UserSid $currentSid)
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    Assert-NormalFile -File $target
    Assert-ResultAcl -Path $target -UserSid $currentSid
}

function Assert-ExactProperties {
    param([object]$Object, [string[]]$Names, [string]$Description)
    if ($null -eq $Object -or $Object -isnot [Management.Automation.PSCustomObject]) {
        throw "$Description must be one JSON object."
    }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join "`n") -ne ($expected -join "`n")) {
        throw "$Description has an invalid schema."
    }
}

function Invoke-TestPauseBoundary {
    param([string]$Boundary)
    if ([string]::IsNullOrWhiteSpace($TestPauseAfter) -or
        -not [string]::Equals($TestPauseAfter, $Boundary, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    if (-not $isTestMode) {
        throw 'Abrupt-boundary pause injection is available only for disposable tests.'
    }
    $sentinel = [IO.Path]::GetFullPath($TestPauseSentinelPath)
    if (-not (Test-IsWithin -Candidate $sentinel -Parent $testContainer) -or
        (Test-PathEqual -Left $sentinel -Right $testContainer)) {
        throw 'The disposable pause sentinel must be a file below the test root.'
    }
    $parent = Split-Path -Parent $sentinel
    Assert-NormalDirectoryChain -Directory $parent
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes("$Boundary`n")
    $stream = [IO.File]::Open($sentinel, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    while ($true) {
        [Threading.Thread]::Sleep(1000)
    }
}

function Get-RequiredProperty {
    param(
        [object]$Object,
        [string]$Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "Backup configuration is missing required property: $Name"
    }
    return $property.Value
}

function Set-JsonProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
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
        $repositoryParent = Split-Path -Parent $Repository
        if ([string]::IsNullOrWhiteSpace($repositoryParent)) {
            throw 'The local_ntfs repository must not be a drive root.'
        }
        $expectedRecovery = Get-CanonicalLocalPath -Value (
            Join-Path $repositoryParent 'RecoveryTools')
        if (-not (Test-PathEqual -Left $RecoveryTools -Right $expectedRecovery)) {
            throw 'The local_ntfs recovery-tools directory is not the repository sibling required by v1.'
        }
        return [pscustomobject]@{
            Mode = $mode
            DriveFsRoot = $null
            DriveFsCache = $null
        }
    }

    $rawRoot = if ($null -ne $rootProperty) {
        [string]$rootProperty.Value
    }
    elseif ($null -ne $legacyRootProperty) {
        [string]$legacyRootProperty.Value
    }
    else { '' }
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
    }
    elseif ($null -ne $legacyRootProperty) {
        $expectedDriveFsCache
    }
    else {
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

function Assert-NtfsLocalPath {
    param([string]$Path, [string]$Label)
    $root = [IO.Path]::GetPathRoot($Path)
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or
        $drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable) -or
        -not [string]::Equals($drive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must remain on a ready local NTFS volume: $Path"
    }
}

function Assert-ConfiguredStorageLocations {
    param(
        [object]$Configuration,
        [string]$Repository,
        [string]$RecoveryTools,
        [pscustomobject]$Storage
    )
    foreach ($directory in @($Repository, $RecoveryTools)) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    Assert-NormalFile -File (Join-Path $Repository 'config')
    Assert-NtfsLocalPath -Path $stateRoot -Label 'ProgramData state'
    Assert-NtfsLocalPath -Path $RecoveryTools -Label 'Recovery tools'
    Assert-NoOverlap -Candidate $stateRoot -Other $RecoveryTools `
        -Message 'ProgramData state overlaps RecoveryTools'

    $repositoryDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Repository))
    if (-not $repositoryDrive.IsReady -or
        $repositoryDrive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) {
        throw 'The configured repository is not on a ready supported drive.'
    }
    if ($Storage.Mode -eq $localNtfsMode) {
        if (-not [string]::Equals($repositoryDrive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The configured local_ntfs repository is not on NTFS.'
        }
        $recoveryDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($RecoveryTools))
        if (-not (Test-PathEqual -Left $repositoryDrive.RootDirectory.FullName `
            -Right $recoveryDrive.RootDirectory.FullName)) {
            throw 'The local_ntfs RecoveryTools directory is not on the repository volume.'
        }
    }
    else {
        foreach ($directory in @($Storage.DriveFsRoot, $Storage.DriveFsCache)) {
            Assert-NormalDirectoryChain -Directory $directory
        }
        Assert-NtfsLocalPath -Path $Storage.DriveFsCache -Label 'Google DriveFS cache'
        if (-not $isTestMode -and
            ($repositoryDrive.DriveType -ne [IO.DriveType]::Fixed -or
             -not [string]::Equals($repositoryDrive.DriveFormat, 'FAT32', [StringComparison]::OrdinalIgnoreCase))) {
            throw 'The configured DriveFS repository is not on the supported fixed FAT32 streaming mount.'
        }
    }
    if (-not $isTestMode) {
        $actualSerial = Get-LocalVolumeSerialHex -Directory $Repository
        if (-not [string]::Equals(
            $actualSerial,
            [string]$Configuration.repository_volume_serial,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw 'The configured repository volume serial does not match the currently mounted volume.'
        }
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-FileSha256Hex {
    param([string]$File)
    $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-Utf8JsonBytes {
    param([object]$Value)
    $text = ($Value | ConvertTo-Json -Depth 20) + "`n"
    return [Text.UTF8Encoding]::new($false).GetBytes($text)
}

function Read-JsonObject {
    param([string]$File)
    Assert-NormalFile -File $File
    $rawBytes = [IO.File]::ReadAllBytes($File)
    $rawText = [Text.UTF8Encoding]::new($false, $true).GetString($rawBytes)
    $value = $rawText | ConvertFrom-Json
    if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
        throw "Expected one JSON object: $File"
    }
    return [pscustomobject]@{ Json = $value; RawBytes = $rawBytes }
}

function New-StagedFileBytes {
    param([string]$Target, [byte[]]$Bytes, [string]$StagedPath, [string]$UserSid)
    Assert-NormalFile -File $Target
    $parent = Split-Path -Parent $Target
    Assert-NormalDirectoryChain -Directory $parent
    $temporary = [IO.Path]::GetFullPath($StagedPath)
    if (-not (Test-PathEqual -Left (Split-Path -Parent $temporary) -Right $parent) -or
        [IO.File]::Exists($temporary) -or [IO.Directory]::Exists($temporary)) {
        throw "The derived source-update staging path is unsafe or already exists: $temporary"
    }
    $stream = $null
    try {
        if ($isTestMode) {
            $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        }
        else {
            # Give the staged file its final protected owner/DACL before its
            # name can atomically replace a protected target. This avoids even
            # a transient requester-owned target after ReplaceFile.
            $stream = [IO.FileStream]::new(
                $temporary,
                [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write,
                [IO.FileShare]::None,
                4096,
                [IO.FileOptions]::WriteThrough,
                (New-ProtectedJournalFileSecurity -UserSid $UserSid)
            )
        }
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        if (-not $isTestMode) {
            Assert-ProtectedSourceUpdateAcl -Path $temporary -UserSid $UserSid
        }
        return $temporary
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Publish-StagedFile {
    param([string]$Staged, [string]$Target)
    $replaceMethod = [IO.File].GetMethod('Replace', [type[]]@([string], [string], [string]))
    if ($null -eq $replaceMethod) {
        throw 'The required atomic file replacement API is unavailable.'
    }
    [void]$replaceMethod.Invoke($null, [object[]]@($Staged, $Target, $null))
}

function Sync-ReplacedFileToDisk {
    param([string]$Target)
    # File.Replace has no supported write-through flag. Flush the resulting
    # target handle before a later journal deletion may commit the transaction,
    # including when RecoveryTools is on a different volume.
    $stream = [IO.File]::Open(
        $Target,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::Read
    )
    try {
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Set-AtomicFileBytes {
    param([string]$Target, [byte[]]$Bytes, [string]$StagedPath, [string]$UserSid)
    $staged = New-StagedFileBytes -Target $Target -Bytes $Bytes -StagedPath $StagedPath -UserSid $UserSid
    try {
        Publish-StagedFile -Staged $staged -Target $Target
        Sync-ReplacedFileToDisk -Target $Target
        if (-not $isTestMode) {
            Assert-ProtectedSourceUpdateAcl -Path $Target -UserSid $UserSid
        }
        $staged = $null
    }
    finally {
        if ($null -ne $staged -and (Test-Path -LiteralPath $staged)) {
            Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SourceUpdateStagePath {
    param([string]$Target, [string]$TransactionId, [string]$TargetId, [string]$Phase)
    return Join-Path (Split-Path -Parent $Target) `
        ('.{0}.source-update.{1}.{2}.{3}.tmp' -f ([IO.Path]::GetFileName($Target)), $TransactionId, $TargetId, $Phase)
}

function New-JournalByteRecord {
    param([byte[]]$Bytes)
    if ($Bytes.Length -le 0 -or $Bytes.Length -gt $journalTargetMaximumBytes) {
        throw "A source-update target is outside the supported size range: $($Bytes.Length) bytes."
    }
    return [ordered]@{
        length = [long]$Bytes.Length
        sha256 = Get-Sha256Hex -Bytes $Bytes
        bytes_base64 = [Convert]::ToBase64String($Bytes)
    }
}

function ConvertFrom-JournalByteRecord {
    param([object]$Record, [string]$Description)
    Assert-ExactProperties -Object $Record -Names @('length', 'sha256', 'bytes_base64') -Description $Description
    if (($Record.length -isnot [int] -and $Record.length -isnot [long]) -or
        [long]$Record.length -le 0 -or
        [long]$Record.length -gt $journalTargetMaximumBytes) {
        throw "$Description has an invalid byte length."
    }
    if ($Record.sha256 -isnot [string] -or [string]$Record.sha256 -notmatch '^[0-9a-f]{64}$' -or
        $Record.bytes_base64 -isnot [string] -or
        ([string]$Record.bytes_base64).Length % 4 -ne 0 -or
        [string]$Record.bytes_base64 -notmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$') {
        throw "$Description has invalid hash or Base64 data."
    }
    try {
        [byte[]]$bytes = [Convert]::FromBase64String([string]$Record.bytes_base64)
    }
    catch {
        throw "$Description contains invalid Base64 data."
    }
    if ([Convert]::ToBase64String($bytes) -ne [string]$Record.bytes_base64 -or
        $bytes.Length -ne [long]$Record.length -or
        -not [string]::Equals((Get-Sha256Hex -Bytes $bytes), [string]$Record.sha256, [StringComparison]::Ordinal)) {
        throw "$Description bytes do not match their declared length and SHA-256."
    }
    return $bytes
}

function ConvertFrom-StrictJsonBytes {
    param([byte[]]$Bytes, [string]$Description)
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        $value = $text | ConvertFrom-Json
    }
    catch {
        throw "$Description is not valid UTF-8 JSON."
    }
    if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
        throw "$Description must be one JSON object."
    }
    return $value
}

function Get-SourceUpdateTargetPaths {
    param([byte[]]$OldProtectedConfigBytes, [byte[]]$NewProtectedConfigBytes)
    $oldConfig = ConvertFrom-StrictJsonBytes -Bytes $OldProtectedConfigBytes `
        -Description 'Old protected configuration in the source-update journal'
    $newConfig = ConvertFrom-StrictJsonBytes -Bytes $NewProtectedConfigBytes `
        -Description 'New protected configuration in the source-update journal'
    foreach ($configuration in @($oldConfig, $newConfig)) {
        foreach ($name in @('repository', 'repository_volume_serial', 'recovery_tools_directory', 'state_directory')) {
            [void](Get-RequiredProperty -Object $configuration -Name $name)
        }
    }
    Assert-SourceConfigurationTransition -Before $oldConfig -After $newConfig `
        -Message 'The source-update journal contains an invalid configuration transition.'
    $repository = Get-CanonicalLocalPath -Value ([string]$oldConfig.repository)
    $configuredState = Get-CanonicalLocalPath -Value ([string]$oldConfig.state_directory)
    if (-not (Test-PathEqual -Left $configuredState -Right $stateRoot)) {
        throw 'The source-update journal names an unexpected protected state directory.'
    }
    if ($oldConfig.repository_volume_serial -isnot [string] -or
        [string]$oldConfig.repository_volume_serial -notmatch '^[0-9A-Fa-f]{8}$') {
        throw 'The source-update journal contains an invalid repository volume serial.'
    }
    $recoveryTools = Get-CanonicalLocalPath -Value ([string]$oldConfig.recovery_tools_directory)
    $storage = Get-ConfiguredStorageBinding -Configuration $oldConfig `
        -Repository $repository -RecoveryTools $recoveryTools
    Assert-ConfiguredStorageLocations -Configuration $oldConfig -Repository $repository `
        -RecoveryTools $recoveryTools -Storage $storage
    return [ordered]@{
        protected_config = $configPath
        runtime_manifest = $runtimeManifestPath
        recovery_config = Join-Path $recoveryTools 'backup-config.json'
        recovery_manifest = Join-Path $recoveryTools 'recovery-manifest.json'
    }
}

function Assert-FileMatchesBytes {
    param([string]$File, [byte[]]$Bytes, [string]$Description)
    Assert-NormalFile -File $File
    $item = Get-Item -LiteralPath $File -Force
    if ($item.Length -ne $Bytes.Length -or
        -not [string]::Equals((Get-FileSha256Hex -File $File), (Get-Sha256Hex -Bytes $Bytes), [StringComparison]::Ordinal)) {
        throw "$Description does not match its journaled bytes: $File"
    }
}

function Write-SourceUpdateJournal {
    param([byte[]]$Bytes, [string]$UserSid)
    if ($Bytes.Length -le 0 -or $Bytes.Length -gt $journalMaximumBytes) {
        throw "The source-update journal is outside its supported size range: $($Bytes.Length) bytes."
    }
    if ([IO.File]::Exists($journalPath) -or [IO.Directory]::Exists($journalPath)) {
        throw 'A source-update recovery journal already exists.'
    }
    $stream = $null
    try {
        if ($isTestMode) {
            $stream = [IO.File]::Open($journalPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        }
        else {
            $stream = [IO.FileStream]::new(
                $journalPath,
                [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write,
                [IO.FileShare]::Read,
                4096,
                [IO.FileOptions]::WriteThrough,
                (New-ProtectedJournalFileSecurity -UserSid $UserSid)
            )
        }
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    Assert-NormalFile -File $journalPath
    if (-not $isTestMode) {
        Assert-ProtectedSourceUpdateAcl -Path $journalPath -UserSid $UserSid
    }
}

function Get-ValidatedSourceUpdateJournal {
    param([string]$UserSid)
    Assert-NormalFile -File $journalPath
    if (-not $isTestMode) {
        Assert-ProtectedSourceUpdateAcl -Path $stateRoot -UserSid $UserSid
        Assert-ProtectedSourceUpdateAcl -Path $journalPath -UserSid $UserSid
    }
    $journalItem = Get-Item -LiteralPath $journalPath -Force
    if ($journalItem.Length -le 0 -or $journalItem.Length -gt $journalMaximumBytes) {
        throw 'The source-update recovery journal has an invalid size.'
    }
    [byte[]]$rawBytes = [IO.File]::ReadAllBytes($journalPath)
    $journal = ConvertFrom-StrictJsonBytes -Bytes $rawBytes -Description 'Source-update recovery journal'
    Assert-ExactProperties -Object $journal `
        -Names @('schema_version', 'transaction_kind', 'transaction_id', 'requester_sid', 'targets') `
        -Description 'Source-update recovery journal'
    if (($journal.schema_version -isnot [int] -and $journal.schema_version -isnot [long]) -or
        [long]$journal.schema_version -ne $journalSchemaVersion -or
        $journal.transaction_kind -isnot [string] -or
        -not [string]::Equals([string]$journal.transaction_kind, $journalKind, [StringComparison]::Ordinal) -or
        $journal.transaction_id -isnot [string] -or
        [string]$journal.transaction_id -notmatch '^[0-9a-f]{32}$' -or
        $journal.requester_sid -isnot [string] -or
        -not [string]::Equals([string]$journal.requester_sid, $UserSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The source-update recovery journal header is invalid.'
    }
    $targetIds = @('protected_config', 'runtime_manifest', 'recovery_config', 'recovery_manifest')
    $records = @($journal.targets)
    if ($records.Count -ne $targetIds.Count) {
        throw 'The source-update recovery journal must contain exactly four fixed targets.'
    }
    $entries = [ordered]@{}
    for ($index = 0; $index -lt $targetIds.Count; $index++) {
        $record = $records[$index]
        Assert-ExactProperties -Object $record -Names @('id', 'old', 'new') `
            -Description "Source-update target record $($index + 1)"
        $expectedId = $targetIds[$index]
        if ($record.id -isnot [string] -or
            -not [string]::Equals([string]$record.id, $expectedId, [StringComparison]::Ordinal)) {
            throw "The source-update recovery journal target order or ID is invalid at position $($index + 1)."
        }
        [byte[]]$oldBytes = ConvertFrom-JournalByteRecord -Record $record.old -Description "$expectedId old record"
        [byte[]]$newBytes = ConvertFrom-JournalByteRecord -Record $record.new -Description "$expectedId new record"
        $entries[$expectedId] = [pscustomobject]@{ OldBytes = $oldBytes; NewBytes = $newBytes }
    }
    $paths = Get-SourceUpdateTargetPaths `
        -OldProtectedConfigBytes ([byte[]]$entries['protected_config'].OldBytes) `
        -NewProtectedConfigBytes ([byte[]]$entries['protected_config'].NewBytes)
    foreach ($targetId in $targetIds) {
        $target = [string]$paths[$targetId]
        Assert-NormalDirectoryChain -Directory (Split-Path -Parent $target)
        Assert-NormalFile -File $target
        if (-not $isTestMode) {
            Assert-ProtectedSourceUpdateAcl -Path $target -UserSid $UserSid -AllowInheritedRules
        }
        $currentLength = (Get-Item -LiteralPath $target -Force).Length
        $currentHash = Get-FileSha256Hex -File $target
        $oldBytes = [byte[]]$entries[$targetId].OldBytes
        $newBytes = [byte[]]$entries[$targetId].NewBytes
        $matchesOld = $currentLength -eq $oldBytes.Length -and
            [string]::Equals($currentHash, (Get-Sha256Hex -Bytes $oldBytes), [StringComparison]::Ordinal)
        $matchesNew = $currentLength -eq $newBytes.Length -and
            [string]::Equals($currentHash, (Get-Sha256Hex -Bytes $newBytes), [StringComparison]::Ordinal)
        if (-not $matchesOld -and -not $matchesNew) {
            throw "Source-update target is neither its exact OLD nor NEW version: $targetId"
        }
        $entries[$targetId] | Add-Member -NotePropertyName Path -NotePropertyValue $target
    }
    return [pscustomobject]@{
        TransactionId = [string]$journal.transaction_id
        Entries = $entries
        TargetIds = $targetIds
    }
}

function Remove-DerivedTransactionStagingFiles {
    param([pscustomobject]$Journal)
    foreach ($targetId in $Journal.TargetIds) {
        $target = [string]$Journal.Entries[$targetId].Path
        foreach ($phase in @('forward', 'undo')) {
            $staged = Get-SourceUpdateStagePath -Target $target -TransactionId $Journal.TransactionId `
                -TargetId $targetId -Phase $phase
            if ([IO.Directory]::Exists($staged)) {
                throw "A derived source-update staging path is unexpectedly a directory: $staged"
            }
            if ([IO.File]::Exists($staged)) {
                Assert-NormalFile -File $staged
                [IO.File]::Delete($staged)
            }
        }
    }
}

function Invoke-SourceUpdateRecovery {
    param([string]$UserSid)
    if (-not [IO.File]::Exists($journalPath)) {
        if ([IO.Directory]::Exists($journalPath)) {
            throw 'The fixed source-update journal path is unexpectedly a directory.'
        }
        return $false
    }
    $journal = Get-ValidatedSourceUpdateJournal -UserSid $UserSid
    $undoCount = 0
    foreach ($targetId in $journal.TargetIds) {
        $entry = $journal.Entries[$targetId]
        $staged = Get-SourceUpdateStagePath -Target $entry.Path -TransactionId $journal.TransactionId `
            -TargetId $targetId -Phase 'undo'
        if ([IO.File]::Exists($staged)) {
            Assert-NormalFile -File $staged
            [IO.File]::Delete($staged)
        }
        elseif ([IO.Directory]::Exists($staged)) {
            throw "A derived undo staging path is unexpectedly a directory: $staged"
        }
        Set-AtomicFileBytes -Target $entry.Path -Bytes ([byte[]]$entry.OldBytes) -StagedPath $staged -UserSid $UserSid
        Assert-FileMatchesBytes -File $entry.Path -Bytes ([byte[]]$entry.OldBytes) `
            -Description "Restored OLD $targetId"
        $undoCount++
        Invoke-TestPauseBoundary -Boundary "Undo$undoCount"
    }
    Remove-DerivedTransactionStagingFiles -Journal $journal
    foreach ($targetId in $journal.TargetIds) {
        $entry = $journal.Entries[$targetId]
        Assert-FileMatchesBytes -File $entry.Path -Bytes ([byte[]]$entry.OldBytes) `
            -Description "Fully restored OLD $targetId"
    }
    $restored = Get-ValidatedConfiguration -File $configPath -AllowOfflineNonCanary
    [void](Get-ValidatedRuntimeManifest -Validated $restored)
    [void](Get-ValidatedRecoveryBundle -Validated $restored)
    if (-not $isTestMode) {
        Assert-ProtectedSourceUpdateAcl -Path $journalPath -UserSid $UserSid
    }
    [IO.File]::Delete($journalPath)
    if ([IO.File]::Exists($journalPath) -or [IO.Directory]::Exists($journalPath)) {
        throw 'The source-update recovery journal could not be deleted after full OLD-state verification.'
    }
    return $true
}

function Invoke-AtomicFileSet {
    param(
        [Collections.IDictionary]$Updates,
        [scriptblock]$Verify,
        [int]$FailAfterPublish = 0,
        [string]$UserSid
    )
    $targetIds = @('protected_config', 'runtime_manifest', 'recovery_config', 'recovery_manifest')
    if ($Updates.Count -ne $targetIds.Count -or
        (($Updates.Keys | ForEach-Object { [string]$_ }) -join "`n") -ne ($targetIds -join "`n")) {
        throw 'A source update must provide exactly the four fixed targets in canonical order.'
    }
    [byte[]]$oldProtectedConfig = [IO.File]::ReadAllBytes($configPath)
    $paths = Get-SourceUpdateTargetPaths -OldProtectedConfigBytes $oldProtectedConfig `
        -NewProtectedConfigBytes ([byte[]]$Updates['protected_config'])
    $transactionId = [Guid]::NewGuid().ToString('N')
    $records = [Collections.Generic.List[object]]::new()
    foreach ($targetId in $targetIds) {
        $target = [string]$paths[$targetId]
        Assert-NormalFile -File $target
        if (-not $isTestMode) {
            Assert-ProtectedSourceUpdateAcl -Path $target -UserSid $UserSid -AllowInheritedRules
        }
        [byte[]]$oldBytes = [IO.File]::ReadAllBytes($target)
        [byte[]]$newBytes = [byte[]]$Updates[$targetId]
        $records.Add([ordered]@{
            id = $targetId
            old = New-JournalByteRecord -Bytes $oldBytes
            new = New-JournalByteRecord -Bytes $newBytes
        })
    }
    $journalDocument = [ordered]@{
        schema_version = $journalSchemaVersion
        transaction_kind = $journalKind
        transaction_id = $transactionId
        requester_sid = $UserSid
        targets = @($records)
    }
    [byte[]]$journalBytes = ConvertTo-Utf8JsonBytes -Value $journalDocument
    Write-SourceUpdateJournal -Bytes $journalBytes -UserSid $UserSid
    [void](Get-ValidatedSourceUpdateJournal -UserSid $UserSid)
    Invoke-TestPauseBoundary -Boundary 'JournalPrepared'
    try {
        $publishCount = 0
        foreach ($targetId in $targetIds) {
            $target = [string]$paths[$targetId]
            $staged = Get-SourceUpdateStagePath -Target $target -TransactionId $transactionId `
                -TargetId $targetId -Phase 'forward'
            Set-AtomicFileBytes -Target $target -Bytes ([byte[]]$Updates[$targetId]) -StagedPath $staged -UserSid $UserSid
            Assert-FileMatchesBytes -File $target -Bytes ([byte[]]$Updates[$targetId]) `
                -Description "Published NEW $targetId"
            $publishCount++
            Invoke-TestPauseBoundary -Boundary "Publish$publishCount"
            if ($FailAfterPublish -gt 0 -and $publishCount -eq $FailAfterPublish) {
                throw "Injected disposable-test failure after publishing $publishCount files."
            }
        }
        & $Verify
        Invoke-TestPauseBoundary -Boundary 'NewVerified'
        [IO.File]::Delete($journalPath)
        if ([IO.File]::Exists($journalPath) -or [IO.Directory]::Exists($journalPath)) {
            throw 'The source-update journal could not be deleted to commit the verified NEW state.'
        }
        Invoke-TestPauseBoundary -Boundary 'JournalDeleted'
    }
    finally {
        foreach ($targetId in $targetIds) {
            $target = [string]$paths[$targetId]
            foreach ($phase in @('forward', 'undo')) {
                $staged = Get-SourceUpdateStagePath -Target $target -TransactionId $transactionId `
                    -TargetId $targetId -Phase $phase
                if ([IO.File]::Exists($staged)) {
                    [IO.File]::Delete($staged)
                }
            }
        }
    }
}

function Enter-RunLock {
    param([string]$File)
    $parent = Split-Path -Parent $File
    Assert-NormalDirectoryChain -Directory $parent
    if (Test-Path -LiteralPath $File) {
        Assert-NormalFile -File $File
    }
    $stream = [IO.File]::Open($File, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -eq 0) {
            $stream.WriteByte(0)
            $stream.Flush($true)
        }
        $stream.Lock(0, 1)
        return $stream
    }
    catch {
        $stream.Dispose()
        throw 'A backup or another source change is already running. Try again after it finishes.'
    }
}

function Exit-RunLock {
    param([IO.FileStream]$Stream)
    if ($null -eq $Stream) {
        return
    }
    try {
        $Stream.Unlock(0, 1)
    }
    finally {
        $Stream.Dispose()
    }
}

function Assert-NoOverlap {
    param(
        [string]$Candidate,
        [string]$Other,
        [string]$Message
    )
    if ((Test-IsWithin -Candidate $Candidate -Parent $Other) -or (Test-IsWithin -Candidate $Other -Parent $Candidate)) {
        throw "$Message`: $Candidate and $Other"
    }
}

function Assert-SourceDrive {
    param([string]$Directory, [bool]$UseVss)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Directory))
    if (-not $drive.IsReady -or $drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) {
        throw "A source must be on a ready local fixed or removable drive: $Directory"
    }
    if ($UseVss -and ($drive.DriveType -ne [IO.DriveType]::Fixed -or
        -not [string]::Equals($drive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase))) {
        throw "VSS is enabled, so every source must be on a local fixed NTFS volume: $Directory"
    }
}

function Get-LocalVolumeSerialHex {
    param([string]$Directory)
    $root = [IO.Path]::GetPathRoot($Directory)
    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw "Cannot read a volume serial for a non-drive-letter path: $Directory"
    }
    $deviceId = $root.Substring(0, 2).ToUpperInvariant()
    $disk = [Management.ManagementObject]::new("Win32_LogicalDisk.DeviceID='$deviceId'")
    try {
        $disk.Get()
        $serial = [string]$disk['VolumeSerialNumber']
    }
    finally {
        $disk.Dispose()
    }
    if ($serial -notmatch '^[0-9A-Fa-f]{8}$') {
        throw "Windows returned an invalid volume serial for $root"
    }
    return $serial.ToUpperInvariant()
}

function Assert-SourceListsEqual {
    param([string[]]$Expected, [object[]]$Actual, [string]$Message)
    if ($Expected.Count -ne $Actual.Count) { throw $Message }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -isnot [string] -or
            -not (Test-PathEqual -Left $Expected[$index] -Right ([string]$Actual[$index]))) {
            throw $Message
        }
    }
}

function Assert-RecoveryStorageBinding {
    param([object]$Configuration, [pscustomobject]$Validated)
    $modeProperty = $Configuration.PSObject.Properties['repository_storage_mode']
    $mode = if ($null -eq $modeProperty) { $localNtfsMode } else { [string]$modeProperty.Value }
    if (-not [string]::Equals($mode, $Validated.StorageMode, [StringComparison]::Ordinal)) {
        throw 'Recovery repository_storage_mode is not synchronized with the protected configuration.'
    }
    $rootProperty = $Configuration.PSObject.Properties['drivefs_my_drive_root']
    $legacyRootProperty = $Configuration.PSObject.Properties['repository_drivefs_root']
    $cacheProperty = $Configuration.PSObject.Properties['drivefs_cache_directory']
    if ($mode -eq $localNtfsMode) {
        if ($null -ne $rootProperty -or $null -ne $legacyRootProperty -or $null -ne $cacheProperty) {
            throw 'Recovery configuration contains DriveFS bindings for local_ntfs.'
        }
        return
    }
    if ($mode -ne $driveFsMode) {
        throw 'Recovery repository_storage_mode is unsupported.'
    }
    $rawRoot = if ($null -ne $rootProperty) {
        [string]$rootProperty.Value
    }
    elseif ($null -ne $legacyRootProperty) {
        [string]$legacyRootProperty.Value
    }
    else { '' }
    $root = Get-CanonicalLocalPath -Value $rawRoot
    $cache = if ($null -ne $cacheProperty) {
        Get-CanonicalLocalPath -Value ([string]$cacheProperty.Value)
    }
    elseif ($null -ne $legacyRootProperty) {
        $expectedDriveFsCache
    }
    else { throw 'Recovery google_drivefs_stream configuration lacks its cache binding.' }
    if (-not (Test-PathEqual -Left $root -Right $Validated.DriveFsRoot) -or
        -not (Test-PathEqual -Left $cache -Right $Validated.DriveFsCache)) {
        throw 'Recovery Google DriveFS bindings are not synchronized with the protected configuration.'
    }
    foreach ($name in @(
        'state_directory', 'secret_file', 'recovery_key_file', 'recovery_tools_directory',
        'restic_executable', 'python_executable', 'exclude_file'
    )) {
        $property = $Configuration.PSObject.Properties[$name]
        if ($null -ne $property -and $property.Value -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $path = Get-CanonicalLocalPath -Value ([string]$property.Value)
            if (Test-IsWithin -Candidate $path -Parent $root) {
                throw "Recovery $name must remain outside Google DriveFS."
            }
        }
    }
}

function Get-ValidatedConfiguration {
    param(
        [string]$File,
        [string]$RemovalCandidate,
        [switch]$AllowOfflineNonCanary
    )
    $loaded = Read-JsonObject -File $File
    $configuration = $loaded.Json
    if ((Get-RequiredProperty -Object $configuration -Name 'schema_version') -ne 1) {
        throw 'Unsupported backup configuration schema.'
    }
    foreach ($name in @(
        'plan_id', 'config_generation', 'cloud_placeholder_policy', 'source_identities',
        'repository', 'repository_volume_serial', 'restic_executable', 'recovery_tools_directory',
        'python_executable', 'state_directory', 'secret_file', 'recovery_key_file', 'exclude_file',
        'canary_file', 'hostname', 'scheduled_tag', 'sources', 'use_vss'
    )) { [void](Get-RequiredProperty -Object $configuration -Name $name) }

    $parsedPlanId = [Guid]::Empty
    if ($configuration.plan_id -isnot [string] -or
        -not [Guid]::TryParseExact([string]$configuration.plan_id, 'D', [ref]$parsedPlanId) -or
        -not [string]::Equals([string]$configuration.plan_id, $parsedPlanId.ToString('D'), [StringComparison]::Ordinal)) {
        throw 'Backup plan_id must be a canonical UUID.'
    }
    if (($configuration.config_generation -isnot [int] -and
        $configuration.config_generation -isnot [long]) -or
        [long]$configuration.config_generation -le 0 -or
        [long]$configuration.config_generation -eq [long]::MaxValue) {
        throw 'Backup config_generation must be a positive incrementable integer.'
    }
    if ($configuration.cloud_placeholder_policy -isnot [string] -or
        [string]$configuration.cloud_placeholder_policy -notin @('strict', 'allow')) {
        throw 'Backup cloud_placeholder_policy must be strict or allow.'
    }

    $repository = Get-CanonicalLocalPath -Value ([string]$configuration.repository)
    $configuredState = Get-CanonicalLocalPath -Value ([string]$configuration.state_directory)
    $resticExecutable = Get-CanonicalLocalPath -Value ([string]$configuration.restic_executable)
    $pythonExecutable = Get-CanonicalLocalPath -Value ([string]$configuration.python_executable)
    $excludeFile = Get-CanonicalLocalPath -Value ([string]$configuration.exclude_file)
    $secretFile = Get-CanonicalLocalPath -Value ([string]$configuration.secret_file)
    $canaryFile = Get-CanonicalLocalPath -Value ([string]$configuration.canary_file)
    $recoveryTools = Get-CanonicalLocalPath -Value ([string]$configuration.recovery_tools_directory)
    [void](Get-CanonicalLocalPath -Value ([string]$configuration.recovery_key_file))

    $expectedCanary = Join-Path $stateRoot 'Canary\backup-canary.txt'
    foreach ($pair in @(
        @($configuredState, $stateRoot, 'state directory'),
        @($resticExecutable, (Join-Path $installRoot 'restic.exe'), 'Restic executable'),
        @($pythonExecutable, (Join-Path $installRoot 'Python\python.exe'), 'Python executable'),
        @($excludeFile, (Join-Path $installRoot 'excludes.txt'), 'exclude file'),
        @($secretFile, (Join-Path $stateRoot 'repository-password.dpapi.json'), 'DPAPI secret file'),
        @($canaryFile, $expectedCanary, 'canary file')
    )) {
        if (-not (Test-PathEqual -Left $pair[0] -Right $pair[1])) {
            throw "Configuration names an unexpected protected $($pair[2]): $($pair[0])"
        }
    }
    if ($configuration.repository_volume_serial -isnot [string] -or
        $configuration.repository_volume_serial -notmatch '^[0-9A-Fa-f]{8}$') {
        throw 'Repository volume serial is invalid.'
    }
    if ($configuration.hostname -isnot [string] -or [string]::IsNullOrWhiteSpace($configuration.hostname) -or
        $configuration.scheduled_tag -isnot [string] -or [string]::IsNullOrWhiteSpace($configuration.scheduled_tag)) {
        throw 'Configured hostname or scheduled tag is invalid.'
    }
    if ($configuration.use_vss -isnot [bool]) {
        throw 'Configured use_vss value must be a JSON Boolean.'
    }

    $storage = Get-ConfiguredStorageBinding -Configuration $configuration `
        -Repository $repository -RecoveryTools $recoveryTools
    Assert-ConfiguredStorageLocations -Configuration $configuration -Repository $repository `
        -RecoveryTools $recoveryTools -Storage $storage
    foreach ($directory in @($installRoot, $stateRoot, $repository, $recoveryTools)) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    foreach ($normalFile in @(
        (Join-Path $repository 'config'), $resticExecutable, $pythonExecutable, $excludeFile, $canaryFile
    )) { Assert-NormalFile -File $normalFile }
    Assert-NormalDirectoryChain -Directory (Split-Path -Parent $canaryFile)

    Assert-NoOverlap -Candidate $repository -Other $installRoot -Message 'Repository overlaps the app runtime'
    Assert-NoOverlap -Candidate $repository -Other $stateRoot -Message 'Repository overlaps the app state'
    Assert-NoOverlap -Candidate $repository -Other $recoveryTools -Message 'Repository overlaps recovery tools'

    $sourceValues = @($configuration.sources)
    if ($sourceValues.Count -lt 2) {
        throw 'Configuration must contain a user source and the protected canary source.'
    }
    $sourceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sources = [Collections.Generic.List[string]]::new()
    foreach ($value in $sourceValues) {
        if ($value -isnot [string]) { throw 'Every configured source must be a path string.' }
        $source = Get-CanonicalLocalPath -Value ([string]$value)
        if (-not $sourceSet.Add($source)) { throw "Duplicate source in backup configuration: $source" }
        $sources.Add($source)
    }

    if ($configuration.source_identities -isnot [Management.Automation.PSCustomObject]) {
        throw 'Backup source_identities must be one JSON object.'
    }
    $identityProperties = @($configuration.source_identities.PSObject.Properties)
    if ($identityProperties.Count -ne $sources.Count) {
        throw 'Backup source_identities must contain exactly one entry per source.'
    }
    foreach ($source in $sources) {
        $matches = @($identityProperties | Where-Object {
            [string]::Equals($_.Name, $source, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -ne 1 -or
            -not [string]::Equals($matches[0].Name, $source, [StringComparison]::Ordinal)) {
            throw "A source volume identity is missing, duplicated, or non-canonical: $source"
        }
        $identity = $matches[0].Value
        if ($identity -isnot [Management.Automation.PSCustomObject] -or
            $identity.expected_volume_serial -isnot [string] -or
            [string]$identity.expected_volume_serial -notmatch '^[0-9A-F]{8}$') {
            throw "A source volume identity is invalid: $source"
        }
    }

    $canarySource = Get-CanonicalLocalPath -Value (Split-Path -Parent $canaryFile)
    $canaryMatches = @($sources | Where-Object { Test-PathEqual -Left $_ -Right $canarySource })
    if ($canaryMatches.Count -ne 1) {
        throw 'The exact protected canary directory must occur once in configured sources.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RemovalCandidate)) {
        $removalMatches = @($sources | Where-Object { Test-PathEqual -Left $_ -Right $RemovalCandidate })
        if ($removalMatches.Count -ne 1) {
            throw "Removal path is not an exact configured source: $RemovalCandidate"
        }
    }

    $remaining = @(
        $sources | Where-Object {
            [string]::IsNullOrWhiteSpace($RemovalCandidate) -or
            -not (Test-PathEqual -Left $_ -Right $RemovalCandidate)
        }
    )
    $validatedRemaining = [Collections.Generic.List[string]]::new()
    foreach ($source in $remaining) {
        $isCanarySource = Test-PathEqual -Left $source -Right $canarySource
        $sourceIsOnline = Test-Path -LiteralPath $source -PathType Container
        if (-not $sourceIsOnline -and ($isCanarySource -or -not $AllowOfflineNonCanary)) {
            throw "Configured source directory does not exist or is offline: $source"
        }
        if ($sourceIsOnline) {
            Assert-NormalDirectoryChain -Directory $source
            Assert-SourceDrive -Directory $source -UseVss ([bool]$configuration.use_vss)
        }
        foreach ($existing in $validatedRemaining) {
            Assert-NoOverlap -Candidate $source -Other $existing -Message 'Configured sources contain one another'
        }
        Assert-NoOverlap -Candidate $source -Other $repository -Message 'Source overlaps the repository'
        if (-not $isCanarySource) {
            foreach ($protected in @($installRoot, $stateRoot, $recoveryTools)) {
                Assert-NoOverlap -Candidate $source -Other $protected -Message 'User source overlaps a protected backup location'
            }
        }
        $validatedRemaining.Add($source)
    }
    return [pscustomobject]@{
        Json = $configuration
        RawBytes = $loaded.RawBytes
        Repository = $repository
        RecoveryTools = $recoveryTools
        CanarySource = $canarySource
        Sources = @($sources)
        SourceIdentities = $configuration.source_identities
        PlanId = [string]$configuration.plan_id
        ConfigGeneration = [long]$configuration.config_generation
        UseVss = [bool]$configuration.use_vss
        StorageMode = $storage.Mode
        DriveFsRoot = $storage.DriveFsRoot
        DriveFsCache = $storage.DriveFsCache
    }
}

function Get-ValidatedRuntimeManifest {
    param([pscustomobject]$Validated)
    $loaded = Read-JsonObject -File $runtimeManifestPath
    $manifest = $loaded.Json
    if ($manifest.schema_version -ne 1) { throw 'Runtime manifest schema is invalid.' }
    $records = @($manifest.files)
    if ([long]$manifest.file_count -ne $records.Count) { throw 'Runtime manifest file count is invalid.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = $installRoot + '\'
    foreach ($record in $records) {
        if ($null -eq $record -or $record.relative_path -isnot [string]) {
            throw 'Runtime manifest contains an invalid file record.'
        }
        $relative = ([string]$record.relative_path).Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative.Split('\') -contains '..' -or -not $seen.Add($relative)) {
            throw "Runtime manifest contains an unsafe or duplicate path: $relative"
        }
        $file = [IO.Path]::GetFullPath((Join-Path $installRoot $relative))
        if (-not $file.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Runtime manifest path escapes the install root: $relative"
        }
        Assert-NormalFile -File $file
        $item = Get-Item -LiteralPath $file -Force
        $hash = Get-FileSha256Hex -File $file
        if ([long]$record.bytes -ne $item.Length -or
            -not [string]::Equals([string]$record.sha256, $hash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Runtime manifest mismatch: $relative"
        }
    }
    foreach ($required in @('backup-config.json', 'Manage-Sources.ps1')) {
        if (-not $seen.Contains($required)) { throw "Runtime manifest is missing required file: $required" }
    }
    $actualFiles = @(
        Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force |
            Where-Object Name -notin @(
                'runtime-manifest.json',
                'scheduled-task.xml',
                'google-drive-verification-task.xml'
            )
    )
    if ($actualFiles.Count -ne $records.Count) { throw 'Runtime contains unmanifested or missing files.' }
    foreach ($file in $actualFiles) {
        $relative = $file.FullName.Substring($prefix.Length)
        if (-not $seen.Contains($relative)) { throw "Runtime contains an unmanifested file: $relative" }
    }
    return [pscustomobject]@{ Json = $manifest; RawBytes = $loaded.RawBytes; Path = $runtimeManifestPath }
}

function Get-ValidatedRecoveryBundle {
    param([pscustomobject]$Validated)
    $payloadNames = @('restic.exe', 'restore.py', 'secret_store.py', 'backup-config.json', 'RECOVERY.md', 'restic-release.json')
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $payloadNames) { [void]$allowed.Add($name) }
    [void]$allowed.Add('recovery-manifest.json')
    $entries = @(Get-ChildItem -LiteralPath $Validated.RecoveryTools -Force)
    if ($entries.Count -ne $allowed.Count) { throw 'Recovery-tools directory is incomplete or contains unexpected entries.' }
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not $allowed.Contains($entry.Name)) {
            throw "Recovery-tools directory contains an unsafe or unexpected entry: $($entry.Name)"
        }
    }
    foreach ($name in $allowed) { Assert-NormalFile -File (Join-Path $Validated.RecoveryTools $name) }

    $manifestPath = Join-Path $Validated.RecoveryTools 'recovery-manifest.json'
    $manifestLoaded = Read-JsonObject -File $manifestPath
    $manifest = $manifestLoaded.Json
    if ($manifest.schema_version -ne 1 -or $manifest.repository -isnot [string] -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$manifest.repository)) -Right $Validated.Repository)) {
        throw 'Recovery manifest header is invalid or names another repository.'
    }
    $records = @($manifest.files)
    if ($records.Count -ne $payloadNames.Count) { throw 'Recovery manifest payload count is invalid.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records) {
        if ($null -eq $record -or $record.name -isnot [string] -or
            -not $allowed.Contains([string]$record.name) -or [string]$record.name -eq 'recovery-manifest.json' -or
            -not $seen.Add([string]$record.name)) {
            throw 'Recovery manifest contains an invalid or duplicate payload record.'
        }
        $file = Join-Path $Validated.RecoveryTools ([string]$record.name)
        $item = Get-Item -LiteralPath $file -Force
        $hash = Get-FileSha256Hex -File $file
        if ([long]$record.bytes -ne $item.Length -or
            -not [string]::Equals([string]$record.sha256, $hash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Recovery manifest mismatch: $($record.name)"
        }
    }
    foreach ($name in $payloadNames) {
        if (-not $seen.Contains($name)) { throw "Recovery manifest is missing payload: $name" }
    }

    $recoveryConfigPath = Join-Path $Validated.RecoveryTools 'backup-config.json'
    $configLoaded = Read-JsonObject -File $recoveryConfigPath
    $recoveryConfig = $configLoaded.Json
    if ($recoveryConfig.schema_version -ne 1 -or $recoveryConfig.repository -isnot [string] -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$recoveryConfig.repository)) -Right $Validated.Repository) -or
        $recoveryConfig.repository_volume_serial -isnot [string] -or
        -not [string]::Equals([string]$recoveryConfig.repository_volume_serial, [string]$Validated.Json.repository_volume_serial, [StringComparison]::OrdinalIgnoreCase) -or
        $recoveryConfig.use_vss -isnot [bool]) {
        throw 'Recovery configuration does not match the protected repository.'
    }
    Assert-RecoveryStorageBinding -Configuration $recoveryConfig -Validated $Validated
    Assert-SourceListsEqual -Expected $Validated.Sources -Actual @($recoveryConfig.sources) -Message 'Recovery source list is not synchronized with the protected configuration.'
    if ($recoveryConfig.plan_id -isnot [string] -or
        -not [string]::Equals([string]$recoveryConfig.plan_id, $Validated.PlanId, [StringComparison]::Ordinal) -or
        ($recoveryConfig.config_generation -isnot [int] -and $recoveryConfig.config_generation -isnot [long]) -or
        [long]$recoveryConfig.config_generation -ne $Validated.ConfigGeneration) {
        throw 'Recovery backup-plan identity is not synchronized with the protected configuration.'
    }
    $protectedIdentityJson = $Validated.Json.source_identities | ConvertTo-Json -Depth 10 -Compress
    $recoveryIdentityJson = $recoveryConfig.source_identities | ConvertTo-Json -Depth 10 -Compress
    if ($protectedIdentityJson -cne $recoveryIdentityJson) {
        throw 'Recovery source volume identities are not synchronized with the protected configuration.'
    }
    if ([bool]$recoveryConfig.use_vss -ne $Validated.UseVss) {
        throw 'Recovery VSS setting is not synchronized with the protected configuration.'
    }
    return [pscustomobject]@{
        ConfigPath = $recoveryConfigPath
        Config = $recoveryConfig
        RawConfigBytes = $configLoaded.RawBytes
        ManifestPath = $manifestPath
        Manifest = $manifest
        RawManifestBytes = $manifestLoaded.RawBytes
    }
}

function New-ManifestBytesForReplacement {
    param(
        [object]$Manifest,
        [string]$PathProperty,
        [string]$ReplacementName,
        [byte[]]$ReplacementBytes,
        [string]$Reason
    )
    $found = 0
    foreach ($record in @($Manifest.files)) {
        if ([string]::Equals([string]$record.$PathProperty, $ReplacementName, [StringComparison]::OrdinalIgnoreCase)) {
            $record.bytes = $ReplacementBytes.Length
            $record.sha256 = Get-Sha256Hex -Bytes $ReplacementBytes
            $found++
        }
    }
    if ($found -ne 1) { throw "Manifest does not contain exactly one $ReplacementName record." }
    Set-JsonProperty -Object $Manifest -Name 'created_utc' -Value ([DateTime]::UtcNow.ToString('o'))
    Set-JsonProperty -Object $Manifest -Name 'last_update_reason' -Value $Reason
    return ConvertTo-Utf8JsonBytes -Value $Manifest
}

function Assert-SourceConfigurationTransition {
    param([object]$Before, [object]$After, [string]$Message)
    $mutable = @('sources', 'source_identities', 'config_generation')
    $beforeNames = @($Before.PSObject.Properties.Name | Where-Object { $_ -notin $mutable } | Sort-Object)
    $afterNames = @($After.PSObject.Properties.Name | Where-Object { $_ -notin $mutable } | Sort-Object)
    if (($beforeNames -join "`n") -ne ($afterNames -join "`n")) { throw $Message }
    foreach ($name in $beforeNames) {
        $beforeText = $Before.$name | ConvertTo-Json -Depth 20 -Compress
        $afterText = $After.$name | ConvertTo-Json -Depth 20 -Compress
        if ($beforeText -ne $afterText) { throw "$Message Field: $name" }
    }
    if (($Before.config_generation -isnot [int] -and $Before.config_generation -isnot [long]) -or
        ($After.config_generation -isnot [int] -and $After.config_generation -isnot [long]) -or
        [long]$Before.config_generation -le 0 -or
        [long]$Before.config_generation -eq [long]::MaxValue -or
        [long]$After.config_generation -ne ([long]$Before.config_generation + 1)) {
        throw "$Message Configuration generation did not increase exactly once."
    }
}

function Set-ConfigurationAndRecovery {
    param(
        [pscustomobject]$Validated,
        [pscustomobject]$Runtime,
        [pscustomobject]$Recovery,
        [string[]]$NewSources,
        [byte[]]$NewConfigBytes,
        [int]$FailAfterPublish
    )
    $beforeLive = ([Text.UTF8Encoding]::new($false, $true).GetString($Validated.RawBytes) | ConvertFrom-Json)
    $beforeRecovery = ([Text.UTF8Encoding]::new($false, $true).GetString($Recovery.RawConfigBytes) | ConvertFrom-Json)
    $Recovery.Config.sources = @($NewSources)
    Set-JsonProperty -Object $Recovery.Config -Name 'source_identities' -Value $Validated.Json.source_identities
    Set-JsonProperty -Object $Recovery.Config -Name 'config_generation' -Value ([long]$Validated.Json.config_generation)
    $newRecoveryConfigBytes = ConvertTo-Utf8JsonBytes -Value $Recovery.Config
    $newRuntimeManifestBytes = New-ManifestBytesForReplacement `
        -Manifest $Runtime.Json -PathProperty 'relative_path' -ReplacementName 'backup-config.json' `
        -ReplacementBytes $NewConfigBytes -Reason 'Protected source configuration changed'
    $newRecoveryManifestBytes = New-ManifestBytesForReplacement `
        -Manifest $Recovery.Manifest -PathProperty 'name' -ReplacementName 'backup-config.json' `
        -ReplacementBytes $newRecoveryConfigBytes -Reason 'Protected source configuration changed'

    $updates = [ordered]@{
        protected_config = $NewConfigBytes
        runtime_manifest = $newRuntimeManifestBytes
        recovery_config = $newRecoveryConfigBytes
        recovery_manifest = $newRecoveryManifestBytes
    }

    $verify = {
        $finalLive = Get-ValidatedConfiguration -File $configPath -AllowOfflineNonCanary
        Assert-SourceListsEqual -Expected $NewSources -Actual $finalLive.Sources -Message 'Published protected source list differs from staged data.'
        Assert-SourceConfigurationTransition -Before $beforeLive -After $finalLive.Json -Message 'The protected configuration transition is invalid.'
        [void](Get-ValidatedRuntimeManifest -Validated $finalLive)
        $finalRecovery = Get-ValidatedRecoveryBundle -Validated $finalLive
        Assert-SourceConfigurationTransition -Before $beforeRecovery -After $finalRecovery.Config -Message 'The recovery configuration transition is invalid.'
    }
    Invoke-AtomicFileSet -Updates $updates -Verify $verify -FailAfterPublish $FailAfterPublish -UserSid $currentSid
}

try {
    $Path = if ($Action -eq 'Add') { $Add } elseif ($Action -eq 'Remove') { $Remove } else { $null }
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'ResticBackuper source management requires 64-bit Windows PowerShell.'
    }
    if ($isTestMode) {
        if ((Test-Administrator) -and -not $TestAllowElevatedProcess) {
            throw 'Elevated disposable tests require the explicit TestAllowElevatedProcess acknowledgement.'
        }
    }
    elseif (-not (Test-Administrator)) {
        throw 'Source changes must be run elevated.'
    }
    if (-not $isTestMode -and
        ($TestFailAfterPublish -ne 0 -or -not [string]::IsNullOrWhiteSpace($TestPauseAfter) -or
            -not [string]::IsNullOrWhiteSpace($TestPauseSentinelPath) -or $TestAllowElevatedProcess)) {
        throw 'Failure and abrupt-boundary injection are available only for disposable tests.'
    }
    if ([string]::IsNullOrWhiteSpace($TestPauseAfter) -ne
        [string]::IsNullOrWhiteSpace($TestPauseSentinelPath)) {
        throw 'Disposable abrupt-boundary tests require both a pause boundary and sentinel path.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or
        -not [string]::Equals($ExpectedUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approve elevation with the same Windows account that requested this source change.'
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Source management must be executed as an installed script, not dot-sourced.'
    }
    $actualScript = [IO.Path]::GetFullPath($PSCommandPath)
    $expectedScript = Join-Path $installRoot 'Manage-Sources.ps1'
    if (-not (Test-PathEqual -Left $actualScript -Right $expectedScript)) {
        throw "Refusing to manage sources outside the protected installation: $actualScript"
    }
    foreach ($directory in @($installRoot, $stateRoot)) { Assert-NormalDirectoryChain -Directory $directory }
    Assert-NormalFile -File $actualScript
    if (-not $isTestMode) {
        Assert-ProtectedSourceUpdateAcl -Path $stateRoot -UserSid $currentSid
    }

    if ($Action -ne 'List' -and [string]::IsNullOrWhiteSpace($Path)) {
        throw 'The add or remove path must not be empty.'
    }
    # Bind the result to the exact request before any protected state is touched. An installed run
    # always needs the dashboard's nonce-bound result channel; a disposable test may pass a nonce to
    # receive the same bound document on standard output.
    $requestPath = if ($Action -eq 'List') { '' } else { Get-CanonicalLocalPath -Value $Path }
    if (-not $isTestMode) {
        Initialize-ResultChannel -UserSid $currentSid -CanonicalPath $requestPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($RequestNonce) -or -not [string]::IsNullOrWhiteSpace($ResultPath)) {
        Assert-RequestNonce
        $requestDigest = Get-SourceRequestDigest -Sid $currentSid -RequestAction $Action `
            -CanonicalPath $requestPath -Nonce $RequestNonce
    }

    $lockStream = Enter-RunLock -File $lockPath
    [void](Invoke-SourceUpdateRecovery -UserSid $currentSid)
    $removalCandidate = if ($Action -eq 'Remove') { Get-CanonicalLocalPath -Value $Path } else { $null }
    $validated = Get-ValidatedConfiguration -File $configPath -RemovalCandidate $removalCandidate `
        -AllowOfflineNonCanary:($Action -in @('Add', 'Remove'))
    $runtime = Get-ValidatedRuntimeManifest -Validated $validated
    $recovery = Get-ValidatedRecoveryBundle -Validated $validated
    $sources = [Collections.Generic.List[string]]::new()
    foreach ($source in $validated.Sources) { $sources.Add($source) }
    $changedPath = $null
    $changed = $false

    if ($Action -eq 'Add') {
        $candidate = Get-CanonicalLocalPath -Value $Path -RequireDirectory
        Assert-NormalDirectoryChain -Directory $candidate
        Assert-SourceDrive -Directory $candidate -UseVss $validated.UseVss
        Assert-NoOverlap -Candidate $candidate -Other $validated.Repository -Message 'Source overlaps the repository'
        Assert-NoOverlap -Candidate $candidate -Other $installRoot -Message 'Source overlaps the app runtime'
        Assert-NoOverlap -Candidate $candidate -Other $stateRoot -Message 'Source overlaps the app state'
        Assert-NoOverlap -Candidate $candidate -Other $validated.RecoveryTools -Message 'Source overlaps recovery tools'
        foreach ($existing in $sources) {
            Assert-NoOverlap -Candidate $candidate -Other $existing -Message 'Source duplicates, contains, or is contained by a configured source'
        }
        $canaryIndex = -1
        for ($index = 0; $index -lt $sources.Count; $index++) {
            if (Test-PathEqual -Left $sources[$index] -Right $validated.CanarySource) {
                $canaryIndex = $index
                break
            }
        }
        if ($canaryIndex -lt 0) { throw 'The protected canary source disappeared during validation.' }
        $sources.Insert($canaryIndex, $candidate)
        $changedPath = $candidate
        $changed = $true
    }
    elseif ($Action -eq 'Remove') {
        $candidate = $removalCandidate
        $matchIndex = -1
        for ($index = 0; $index -lt $sources.Count; $index++) {
            if (Test-PathEqual -Left $candidate -Right $sources[$index]) {
                $matchIndex = $index
                break
            }
        }
        if ($matchIndex -lt 0) {
            throw "Removal path is not an exact configured source: $candidate"
        }
        if (Test-PathEqual -Left $sources[$matchIndex] -Right $validated.CanarySource) {
            throw 'The protected restore-canary source cannot be removed.'
        }
        $userSourceCount = @($sources | Where-Object { -not (Test-PathEqual -Left $_ -Right $validated.CanarySource) }).Count
        if ($userSourceCount -le 1) {
            throw 'The last user backup source cannot be removed.'
        }
        $changedPath = $sources[$matchIndex]
        $sources.RemoveAt($matchIndex)
        $changed = $true
    }

    if ($changed) {
        $validated.Json.sources = @($sources)
        $newIdentities = [ordered]@{}
        foreach ($source in $sources) {
            $existingIdentity = @($validated.SourceIdentities.PSObject.Properties | Where-Object {
                [string]::Equals($_.Name, $source, [StringComparison]::OrdinalIgnoreCase)
            })
            $serial = if ($existingIdentity.Count -eq 1) {
                [string]$existingIdentity[0].Value.expected_volume_serial
            }
            else {
                Get-LocalVolumeSerialHex -Directory $source
            }
            $newIdentities[$source] = [ordered]@{ expected_volume_serial = $serial.ToUpperInvariant() }
        }
        Set-JsonProperty -Object $validated.Json -Name 'source_identities' -Value ([pscustomobject]$newIdentities)
        Set-JsonProperty -Object $validated.Json -Name 'config_generation' -Value ($validated.ConfigGeneration + 1)
        $newConfigBytes = ConvertTo-Utf8JsonBytes -Value $validated.Json
        Set-ConfigurationAndRecovery -Validated $validated -Runtime $runtime -Recovery $recovery `
            -NewSources @($sources) -NewConfigBytes $newConfigBytes -FailAfterPublish $TestFailAfterPublish
    }

    $userSources = @($sources | Where-Object { -not (Test-PathEqual -Left $_ -Right $validated.CanarySource) })
    Write-ManagerResult -Response ([ordered]@{
        ok = $true
        action = $Action.ToLowerInvariant()
        changed = $changed
        path = $changedPath
        plan_id = $validated.PlanId
        previous_config_generation = $validated.ConfigGeneration
        config_generation = $(if ($changed) { $validated.ConfigGeneration + 1 } else { $validated.ConfigGeneration })
        user_source_count = $userSources.Count
        source_count = $sources.Count
        canary_source = $validated.CanarySource
        required_sources = @($validated.CanarySource)
        sources = @($sources)
    })
}
catch {
    $failureMessage = $_.Exception.Message
    if ($null -ne $lockStream -and -not [string]::IsNullOrWhiteSpace($currentSid)) {
        try {
            if (Invoke-SourceUpdateRecovery -UserSid $currentSid) {
                $failureMessage = "$failureMessage The interrupted source update was rolled back and reconciled to its exact OLD state."
            }
        }
        catch {
            $failureMessage = "$failureMessage Source-update recovery also failed and the protected journal was retained: $($_.Exception.Message)"
        }
    }
    $resultAction = if ($null -ne $Action) { $Action.ToLowerInvariant() } else { $PSCmdlet.ParameterSetName.ToLowerInvariant() }
    $failure = [ordered]@{
        ok = $false
        action = $resultAction
        error = $failureMessage
    }
    if ($isTestMode) {
        Write-ManagerResult -Response $failure
    }
    elseif ($resultChannelReady) {
        # The success result may already exist when only its post-write ACL check failed; CreateNew
        # then refuses to replace it, and the dashboard rejects an ok result paired with a failing exit.
        try { Write-ManagerResult -Response $failure }
        catch { }
    }
    exit 1
}
finally {
    if ($null -ne $lockStream) {
        Exit-RunLock -Stream $lockStream
    }
}
