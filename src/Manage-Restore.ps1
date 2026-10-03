#requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'Request')]
param(
    # One protected request (RestoreRequest.v2): one elevation, one action, one bound result file.
    [Parameter(Mandatory = $true, ParameterSetName = 'Request')]
    [ValidateSet('list_snapshots', 'list_tree', 'restore', 'restore_drill')]
    [string]$Action,
    # One restore approval session (RestoreRequest.v3, see docs/engine-contract.md): one elevation serves any number of
    # snapshot and folder listings and at most one restore, over a named pipe only the requesting dashboard may use.
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [ValidateSet('session')]
    [string]$Operation,
    [Parameter(ParameterSetName = 'Request')]
    [string]$SnapshotId = '',
    [Parameter(ParameterSetName = 'Request')]
    [string]$TreePath = '',
    [Parameter(ParameterSetName = 'Request')]
    [string]$Target = '',
    [Parameter(Mandatory = $true, ParameterSetName = 'Request')]
    [string]$IncludesBase64,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedUserSid,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedConfigSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPlanId,
    [Parameter(Mandatory = $true)]
    [long]$ExpectedConfigGeneration,
    [Parameter(Mandatory = $true, ParameterSetName = 'Request')]
    [ValidateSet('0', '1')]
    [string]$AllowLegacyUnbound,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$RequestNonce,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$RequestDigest,
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [long]$DashboardProcessId,
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [string]$PipeName,
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$SessionTokenSha256,
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [int]$IdleTimeoutSeconds,
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [int]$LifetimeSeconds,
    [Parameter(Mandatory = $true, ParameterSetName = 'Session')]
    [int]$ConnectTimeoutSeconds,
    [string]$TestRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot

$productName = 'ResticBackuper'
$requestDomain = 'ResticBackuper.RestoreRequest.v2'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$localAppDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$isTestMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
if ($isTestMode) {
    $testContainer = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ($testContainer -eq $temporaryRoot -or
        -not $testContainer.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable restore-manager test root must be below the current-user temporary directory.'
    }
    # The disposable mode needs an explicit -TestRoot AND a copy of this script outside the protected install root: the
    # installed copy can never run in it (the manager-path check below also requires the copy to sit in the test root, and
    # the mode refuses an elevated token, which is how every production launch runs).
    $protectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
    $testScript = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { '' } else { [IO.Path]::GetFullPath($PSCommandPath) }
    if ([string]::IsNullOrWhiteSpace($testScript) -or
        [string]::Equals($testScript, $protectedInstallRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $testScript.StartsWith($protectedInstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable restore-manager test mode cannot run from the protected install root.'
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

$managerPath = Join-Path $installRoot 'Manage-Restore.ps1'
$configPath = Join-Path $installRoot 'backup-config.json'
$runtimeManifestPath = Join-Path $installRoot 'runtime-manifest.json'
$restorePath = Join-Path $installRoot 'restore.py'
$pythonPath = Join-Path $installRoot 'Python\python.exe'
$resticPath = Join-Path $installRoot 'restic.exe'
$lockPath = Join-Path $stateRoot 'run.lock'
$resultRoot = Join-Path $stateRoot 'RestoreManagerResults'
$restoreHistoryPath = Join-Path $stateRoot 'restore-history.json'
$lastSuccessPath = Join-Path $stateRoot 'last-success.json'
$drillRoot = if ($isTestMode) {
    [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramData\$productName-RestoreDrills")).TrimEnd('\')
} else {
    [IO.Path]::GetFullPath((Join-Path $programDataRoot "$productName-RestoreDrills")).TrimEnd('\')
}
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$currentSid = $null
# The request being served. A single request sets it once from its parameters; a session sets it for each request it
# receives. Initialize-RestoreRequest is the only writer, for both.
$requestAction = ''
$canonicalTarget = ''
$canonicalTreePath = ''
$canonicalSnapshotId = ''
$includes = @()
$includesHash = $null
$historyRecorded = $null
$historyError = $null
$resultChannelReady = $false
$progressPath = $null
$reportPath = $null
$allowLegacy = $false
$operationOutcome = $null

# Restore approval session (see Invoke-RestoreSession).
$sessionRequestDomain = 'ResticBackuper.RestoreRequest.v3'
$sessionProtocol = 'ResticBackuper.RestoreSession.v1'
$sessionPipePattern = '^ResticBackuper\.RestoreSession\.[0-9a-f]{64}$'
$sessionMaximumRequestBytes = 256KB
# The same limit as a protected result file (Write-ProtectedJson) and the dashboard's result reader.
$sessionMaximumResponseBytes = 8MB
$sessionMinimumSeconds = 5
$sessionMaximumIdleSeconds = 600
$sessionMaximumLifetimeSeconds = 3600
$sessionMaximumConnectSeconds = 300
$sessionFrameSeconds = 30
$sessionWriteSeconds = 60
$sessionPollMilliseconds = 250
$sessionConfigurationPollSeconds = 2
$sessionNormalEnds = @('client_closed', 'client_disconnected', 'client_exited', 'idle_timeout', 'lifetime_expired',
    'config_changed', 'config_unreadable', 'restore_completed', 'connect_timeout')
$sessionPipe = $null
$sessionClientProcess = $null
$sessionRequestId = $null
$sessionProgressBroken = $false
$sessionStartedUtc = [DateTime]::UtcNow
$sessionLifetimeEndUtc = [DateTime]::MaxValue
$sessionIdleEndUtc = [DateTime]::MaxValue
$sessionNextConfigurationCheckUtc = [DateTime]::MinValue
$sessionObservedClientSid = $null
$sessionPipeNative = $null
$sessionOperationCounts = [ordered]@{ list_snapshots = 0; list_tree = 0; restore = 0 }

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
        throw "Required directory does not exist: $Directory"
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

function Assert-RecoveryKeyAcl {
    param([string]$Path)
    $item = Assert-NormalFile -File $Path
    if ($item.Length -le 0 -or $item.Length -gt 64KB) {
        throw 'The recovery-key file has an invalid size.'
    }
    if ($isTestMode) { return }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) {
        throw 'The recovery-key ACL inheritance is not protected.'
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', $currentSid)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
            throw "The recovery-key ACL grants an unexpected principal or rights: $sid"
        }
        [void]$seen.Add($sid)
    }
    foreach ($sid in $allowed) {
        if (-not $seen.Contains($sid)) { throw "The recovery-key ACL is missing $sid" }
    }
}

function Assert-NoPathOverlap {
    param([string]$Candidate, [string]$Protected, [string]$Description)
    if ((Test-IsWithin -Candidate $Candidate -Parent $Protected) -or
        (Test-IsWithin -Candidate $Protected -Parent $Candidate)) {
        throw "Recovery-drill storage overlaps $Description."
    }
}

function Get-DrillTarget {
    param([string]$Nonce)
    return Get-CanonicalLocalPath -Value (Join-Path $drillRoot ("drill-" + $Nonce))
}

function Get-WindowsSnapshotPath {
    param([string]$Value)
    $full = Get-CanonicalLocalPath -Value $Value
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -notmatch '^[A-Za-z]:\\$') { throw 'The configured canary path is not on a supported drive.' }
    $drive = $root.Substring(0, 1).ToUpperInvariant()
    $tail = $full.Substring($root.Length).Replace('\', '/').Trim('/')
    return $(if ($tail) { "/$drive/$tail" } else { "/$drive" })
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

function Read-BoundedJsonObject {
    param([string]$File, [long]$MaximumBytes, [string]$Description)
    $item = Assert-NormalFile -File $File
    if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) { throw "$Description has an invalid size." }
    $bytes = [IO.File]::ReadAllBytes($File)
    try { $value = $utf8.GetString($bytes) | ConvertFrom-Json }
    catch { throw "$Description is not valid UTF-8 JSON." }
    if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
        throw "$Description must contain exactly one JSON object."
    }
    return [pscustomobject]@{ Json = $value; Bytes = $bytes }
}

function Get-RequiredProperty {
    param([object]$Object, [string]$Name, [string]$Description)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "$Description is missing required field: $Name" }
    return $property.Value
}

function Get-ConfiguredStorageBinding {
    param([object]$Configuration, [string]$Repository, [string]$RecoveryTools)
    $modeProperty = $Configuration.PSObject.Properties['repository_storage_mode']
    $mode = if ($null -eq $modeProperty) { $localNtfsMode } else { [string]$modeProperty.Value }
    if ($mode -notin @($localNtfsMode, $driveFsMode)) {
        throw 'Configured repository_storage_mode is unsupported.'
    }
    if ((Test-IsWithin -Candidate $RecoveryTools -Parent $stateRoot) -or
        (Test-IsWithin -Candidate $stateRoot -Parent $RecoveryTools)) {
        throw 'RecoveryTools must not overlap protected ProgramData state.'
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
        return [pscustomobject]@{ Mode = $mode; DriveFsRoot = $null; DriveFsCache = $null }
    }

    $rawRoot = if ($null -ne $rootProperty) {
        [string]$rootProperty.Value
    }
    elseif ($null -ne $legacyRootProperty) {
        [string]$legacyRootProperty.Value
    }
    else { '' }
    if ($null -ne $rootProperty -and $null -ne $legacyRootProperty) {
        if (-not (Test-PathEqual `
            -Left (Get-CanonicalLocalPath -Value ([string]$rootProperty.Value)) `
            -Right (Get-CanonicalLocalPath -Value ([string]$legacyRootProperty.Value)))) {
            throw 'drivefs_my_drive_root conflicts with legacy repository_drivefs_root.'
        }
    }
    $root = Get-CanonicalLocalPath -Value $rawRoot
    $cache = if ($null -ne $cacheProperty) {
        Get-CanonicalLocalPath -Value ([string]$cacheProperty.Value)
    }
    elseif ($null -ne $legacyRootProperty) { $expectedDriveFsCache }
    else { throw 'google_drivefs_stream requires drivefs_cache_directory.' }
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
    return [pscustomobject]@{ Mode = $mode; DriveFsRoot = $root; DriveFsCache = $cache }
}

function Assert-NtfsLocalPath {
    param([string]$Path, [string]$Label)
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path))
    if (-not $drive.IsReady -or
        $drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable) -or
        -not [string]::Equals($drive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must remain on a ready local NTFS volume."
    }
}

function Get-OptionalProperty {
    param([object]$Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    return $(if ($null -eq $property) { $null } else { $property.Value })
}

function New-ResultDirectorySecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $allow = [Security.AccessControl.AccessControlType]::Allow
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [Security.AccessControl.PropagationFlags]::None, $allow))
    }
    $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText), $read,
            $inheritance, [Security.AccessControl.PropagationFlags]::None, $allow))
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
            [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    }
    $read = [Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [Security.AccessControl.FileSystemRights]::Synchronize
    foreach ($sidText in @($UserSid, 'S-1-3-4')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText), $read, $allow))
    }
    return $security
}

function Assert-ResultAcl {
    param([string]$Path, [string]$UserSid)
    if ($isTestMode) { return }
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or
        -not $acl.AreAccessRulesProtected) { throw "Protected restore result path has an unsafe ACL: $Path" }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $UserSid)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $dangerous = [Security.AccessControl.FileSystemRights]::WriteData -bor `
        [Security.AccessControl.FileSystemRights]::AppendData -bor `
        [Security.AccessControl.FileSystemRights]::Delete -bor `
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor `
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed) { throw "Protected restore result ACL contains unexpected identity: $sid" }
        if ($sid -notin @('S-1-5-18', 'S-1-5-32-544') -and
            ($rule.FileSystemRights -band $dangerous) -ne 0) {
            throw "Protected restore result ACL grants write rights to $sid"
        }
        [void]$seen.Add($sid)
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $UserSid)) {
        if (-not $seen.Contains($sid)) { throw "Protected restore result ACL is missing $sid" }
    }
}

function Initialize-DrillRoot {
    param([pscustomobject]$Configuration)
    Assert-NoPathOverlap -Candidate $drillRoot -Protected $Configuration.Repository -Description 'the Restic repository'
    Assert-NoPathOverlap -Candidate $drillRoot -Protected $stateRoot -Description 'protected state'
    Assert-NoPathOverlap -Candidate $drillRoot -Protected $installRoot -Description 'the protected runtime'
    foreach ($name in @('recovery_tools_directory','recovery_key_file','secret_file','canary_file')) {
        $value = [string](Get-OptionalProperty -Object $Configuration.Json -Name $name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $protectedPath = Get-CanonicalLocalPath -Value $value
            if (-not (Test-PathEqual -Left $protectedPath -Right $drillRoot) -and
                -not (Test-IsWithin -Candidate $protectedPath -Parent $drillRoot)) {
                Assert-NoPathOverlap -Candidate $drillRoot -Protected $protectedPath -Description $name
            }
        }
    }
    foreach ($source in @($Configuration.Json.sources)) {
        Assert-NoPathOverlap -Candidate $drillRoot -Protected (Get-CanonicalLocalPath -Value ([string]$source)) -Description 'a configured source'
    }
    if (-not (Test-Path -LiteralPath $drillRoot)) {
        if ($isTestMode) { [void][IO.Directory]::CreateDirectory($drillRoot) }
        else { [void][IO.Directory]::CreateDirectory($drillRoot, (New-ResultDirectorySecurity -UserSid $currentSid)) }
    }
    Assert-NormalDirectoryChain -Directory $drillRoot
    Assert-ResultAcl -Path $drillRoot -UserSid $currentSid
    if ([IO.File]::Exists($canonicalTarget) -or [IO.Directory]::Exists($canonicalTarget)) {
        throw 'The nonce-bound recovery-drill target already exists.'
    }
}

function Protect-RecoveryDrillTarget {
    param([string]$Path)
    Assert-NormalDirectoryChain -Directory $Path
    if ($isTestMode) { return }
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force) + @(Get-Item -LiteralPath $Path -Force)
    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The recovered drill target contains a reparse point: $($item.FullName)"
        }
    }
    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $item.SetAccessControl((New-ResultDirectorySecurity -UserSid $currentSid))
        }
        else {
            $item.SetAccessControl((New-ResultFileSecurity -UserSid $currentSid))
        }
    }
    foreach ($item in $items) { Assert-ResultAcl -Path $item.FullName -UserSid $currentSid }
}

function Write-ProtectedJson {
    param([string]$Path, [object]$Value, [switch]$Replace)
    $bytes = $utf8.GetBytes(($Value | ConvertTo-Json -Depth 40) + "`n")
    if ($bytes.Length -gt 8MB) { throw 'Protected restore result exceeds its size limit.' }
    $parent = Split-Path -Parent $Path
    $temporary = Join-Path $parent ('.restore-result-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $stream = $null
    try {
        if ($isTestMode) {
            $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        }
        else {
            $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None,
                4096, [IO.FileOptions]::WriteThrough, (New-ResultFileSecurity -UserSid $currentSid))
        }
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true); $stream.Dispose(); $stream = $null
        if ($Replace -and [IO.File]::Exists($Path)) {
            $replaceMethod = [IO.File].GetMethod('Replace', [type[]]@([string], [string], [string]))
            if ($null -eq $replaceMethod) { throw 'The required atomic result replacement API is unavailable.' }
            [void]$replaceMethod.Invoke($null, [object[]]@([string]$temporary, [string]$Path, $null))
            $temporary = $null
        }
        else {
            if ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path)) { throw "Protected result already exists: $Path" }
            [IO.File]::Move($temporary, $Path); $temporary = $null
        }
        Assert-ResultAcl -Path $Path -UserSid $currentSid
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Initialize-ResultChannel {
    Assert-NormalDirectoryChain -Directory $stateRoot
    if (-not (Test-Path -LiteralPath $resultRoot)) {
        if ($isTestMode) { [void][IO.Directory]::CreateDirectory($resultRoot) }
        else { [void][IO.Directory]::CreateDirectory($resultRoot, (New-ResultDirectorySecurity -UserSid $currentSid)) }
    }
    Assert-NormalDirectoryChain -Directory $resultRoot
    Assert-ResultAcl -Path $resultRoot -UserSid $currentSid
    foreach ($entry in Get-ChildItem -LiteralPath $resultRoot -Force) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry.Name -notmatch '^[0-9a-f]{64}(\.json|\.json\.progress\.json|\.restore-report\.json)$') {
            throw "Protected restore-result directory contains an unexpected entry: $($entry.Name)"
        }
        Assert-ResultAcl -Path $entry.FullName -UserSid $currentSid
        if ($entry.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7)) { [IO.File]::Delete($entry.FullName) }
    }
    $expectedResult = Join-Path $resultRoot "$RequestNonce.json"
    if (-not (Test-PathEqual -Left ([IO.Path]::GetFullPath($ResultPath)) -Right $expectedResult)) {
        throw 'The restore-manager result path does not match its request nonce.'
    }
    $script:progressPath = $expectedResult + '.progress.json'
    foreach ($candidate in @($expectedResult, $progressPath)) {
        if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
            throw "Protected restore-result target already exists: $candidate"
        }
    }
    $script:resultChannelReady = $true
}

function Remove-OrphanedRestoreReports {
    # The global run lock proves no backend can still own one of these bounded
    # temporary reports. A terminated process may otherwise block all later
    # restore requests indefinitely.
    foreach ($entry in Get-ChildItem -LiteralPath $resultRoot -File -Force) {
        if ($entry.Name -notmatch '^[0-9a-f]{64}\.restore-report\.json$') { continue }
        Assert-ResultAcl -Path $entry.FullName -UserSid $currentSid
        [IO.File]::Delete($entry.FullName)
    }
}

function Get-SanitizedError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'The protected restore operation failed.' }
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $Message.ToCharArray()) {
        if (-not [char]::IsControl($character) -or $character -eq "`t") { [void]$builder.Append($character) }
        if ($builder.Length -ge 2000) { break }
    }
    $result = $builder.ToString().Trim()
    if ($result -match '(?i)(password-command|RESTIC_PASSWORD|dpapi)') {
        return 'The protected restore operation failed without exposing credential details.'
    }
    return $(if ($result) { $result } else { 'The protected restore operation failed.' })
}

function Write-ProgressResult {
    param([string]$Stage, [string]$Message, [int]$Percent)
    if (-not $resultChannelReady) { return }
    if ($null -ne $sessionPipe) {
        # A session reports progress on its channel, for the request it is serving; never between requests.
        if ($null -ne $sessionRequestId) { Send-SessionProgress -Stage $Stage -Message $Message -Percent $Percent }
        return
    }
    $document = [ordered]@{
        schema_version = 1; request_nonce = $RequestNonce; request_digest = $RequestDigest;
        request_user_sid = $currentSid; action = $requestAction; plan_id = $ExpectedPlanId;
        config_generation = $ExpectedConfigGeneration; snapshot_id = if ($canonicalSnapshotId) { $canonicalSnapshotId } else { $null };
        allow_legacy_unbound = $allowLegacy;
        target = if ($canonicalTarget) { $canonicalTarget } else { $null };
        stage = $Stage; message = $Message; percent = $Percent; cancellable = $false;
        updated_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-ProtectedJson -Path $progressPath -Value $document -Replace:([IO.File]::Exists($progressPath))
}

function New-FinalResultDocument {
    # The bound result of one request. A single request writes it to its protected result file; a session sends it on its
    # channel. Both carry exactly these fields.
    param([bool]$Ok, [object]$Payload, [string]$ErrorMessage, [int]$BackendExitCode)
    return [ordered]@{
        schema_version = 1; request_nonce = $RequestNonce; request_digest = $RequestDigest;
        request_user_sid = $currentSid; action = $requestAction; expected_config_sha256 = $ExpectedConfigSha256;
        plan_id = $ExpectedPlanId; config_generation = $ExpectedConfigGeneration;
        allow_legacy_unbound = $allowLegacy;
        snapshot_id = if ($canonicalSnapshotId) { $canonicalSnapshotId } else { $null };
        tree_path = if ($canonicalTreePath) { $canonicalTreePath } else { $null };
        target = if ($canonicalTarget) { $canonicalTarget } else { $null };
        includes_sha256 = $includesHash; ok = $Ok; backend_exit_code = $BackendExitCode;
        history_recorded = $historyRecorded; history_error = $historyError;
        payload = $Payload; error = if ($Ok) { $null } else { Get-SanitizedError -Message $ErrorMessage };
        finished_utc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-FinalResult {
    param([bool]$Ok, [object]$Payload, [string]$ErrorMessage, [int]$BackendExitCode)
    if (-not $resultChannelReady) { return }
    $document = New-FinalResultDocument -Ok $Ok -Payload $Payload -ErrorMessage $ErrorMessage -BackendExitCode $BackendExitCode
    Write-ProtectedJson -Path ([IO.Path]::GetFullPath($ResultPath)) -Value $document
    if ($isTestMode) { $document | ConvertTo-Json -Compress -Depth 20 }
}

function Write-RestoreHistory {
    param([object]$Payload, [int]$BackendExitCode)
    $entries = @()
    if ([IO.File]::Exists($restoreHistoryPath)) {
        $history = (Read-BoundedJsonObject -File $restoreHistoryPath -MaximumBytes 1MB -Description 'Protected restore history').Json
        if ($history.schema_version -notin @(1,2) -or $null -eq $history.PSObject.Properties['entries']) {
            throw 'Protected restore history schema is invalid.'
        }
        if ($history.schema_version -eq 2) { $entries = @($history.entries) }
        if ($entries.Count -gt 200) { throw 'Protected restore history exceeds its bounded entry limit.' }
    }
    $entry = [ordered]@{
        finished_utc = [DateTime]::UtcNow.ToString('o')
        kind = if ($requestAction -eq 'restore_drill') { 'recovery_key_representative_drill' } else { 'manual_restore' }
        credential_source = if ($requestAction -eq 'restore_drill') { 'recovery_key' } else { 'active_credential' }
        plan_id = $ExpectedPlanId
        config_generation = $ExpectedConfigGeneration
        snapshot_generation = Get-OptionalProperty -Object $Payload -Name 'snapshot_generation'
        repository_id = [string](Get-OptionalProperty -Object $Payload -Name 'repository_id')
        snapshot_id = $canonicalSnapshotId
        snapshot_binding = [string]$Payload.snapshot_binding
        result = [string]$Payload.result
        verified = $Payload.verified -is [bool] -and [bool]$Payload.verified
        partial_target_retained = $Payload.partial_target_retained -is [bool] -and [bool]$Payload.partial_target_retained
        backend_exit_code = $BackendExitCode
        target = $canonicalTarget
        includes_sha256 = $includesHash
        canary_verified = if ($requestAction -eq 'restore_drill') { [bool]$Payload.canary_verified } else { $false }
        canary_sha256 = if ($requestAction -eq 'restore_drill') { [string]$Payload.canary_sha256 } else { $null }
        canary_bytes = if ($requestAction -eq 'restore_drill') { [long]$Payload.canary_bytes } else { $null }
        sample_policy = if ($requestAction -eq 'restore_drill') { [string]$Payload.sample_policy } else { $null }
        sample_file_count = if ($requestAction -eq 'restore_drill') { [long]$Payload.sample_file_count } else { $null }
        sample_bytes = if ($requestAction -eq 'restore_drill') { [long]$Payload.sample_bytes } else { $null }
        sample_paths_sha256 = if ($requestAction -eq 'restore_drill') { [string]$Payload.sample_paths_sha256 } else { $null }
    }
    $newEntries = @($entries | Select-Object -Last 49) + @($entry)
    $document = [ordered]@{
        schema_version = 2
        plan_id = $ExpectedPlanId
        updated_utc = [DateTime]::UtcNow.ToString('o')
        entries = $newEntries
    }
    Write-ProtectedJson -Path $restoreHistoryPath -Value $document -Replace:([IO.File]::Exists($restoreHistoryPath))
}

function Enter-RunLock {
    $stream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -eq 0) { $stream.WriteByte(0); $stream.Flush($true) }
        $stream.Lock(0, 1)
        return $stream
    }
    catch { $stream.Dispose(); throw 'A backup or another protected operation already holds the run lock.' }
}

function Exit-RunLock {
    param([IO.FileStream]$Stream)
    if ($null -eq $Stream) { return }
    try { $Stream.Unlock(0, 1) } finally { $Stream.Dispose() }
}

function Assert-NoPendingJournal {
    foreach ($name in @('repository-relocation.journal.json', 'plan-migration.journal.json', 'credential-rotation.journal.json')) {
        $path = Join-Path $stateRoot $name
        if ([IO.File]::Exists($path) -or [IO.Directory]::Exists($path)) {
            throw "A pending protected-operation journal ($name) must be repaired before restore operations."
        }
    }
}

function Get-ValidatedConfiguration {
    $loaded = Read-BoundedJsonObject -File $configPath -MaximumBytes 1MB -Description 'Protected backup configuration'
    if ((Get-Sha256Hex -Bytes $loaded.Bytes) -ne $ExpectedConfigSha256) {
        throw 'The protected configuration changed after the restore request was prepared.'
    }
    $config = $loaded.Json
    if ($config.schema_version -ne 1) { throw 'Unsupported protected configuration schema.' }
    $parsedPlan = [Guid]::Empty
    if ($config.plan_id -isnot [string] -or
        -not [Guid]::TryParseExact([string]$config.plan_id, 'D', [ref]$parsedPlan) -or
        $parsedPlan.ToString('D') -cne $ExpectedPlanId -or
        [string]$config.plan_id -cne $ExpectedPlanId) {
        throw 'The protected restore request names another backup plan.'
    }
    if ($config.config_generation.GetType().FullName -notin @('System.Int32', 'System.Int64') -or
        [long]$config.config_generation -ne $ExpectedConfigGeneration -or $ExpectedConfigGeneration -le 0) {
        throw 'The protected restore request names another configuration generation.'
    }
    foreach ($name in @(
        'repository','repository_volume_serial','restic_executable','recovery_tools_directory',
        'python_executable','state_directory','secret_file','recovery_key_file','canary_file','sources','source_identities'
    )) { [void](Get-RequiredProperty -Object $config -Name $name -Description 'Protected backup configuration') }
    $repository = Get-CanonicalLocalPath -Value ([string]$config.repository)
    $recoveryTools = Get-CanonicalLocalPath -Value ([string]$config.recovery_tools_directory)
    $configuredState = Get-CanonicalLocalPath -Value ([string]$config.state_directory)
    $configuredRestic = Get-CanonicalLocalPath -Value ([string]$config.restic_executable)
    $configuredPython = Get-CanonicalLocalPath -Value ([string]$config.python_executable)
    if (-not (Test-PathEqual -Left $configuredState -Right $stateRoot) -or
        -not (Test-PathEqual -Left $configuredRestic -Right $resticPath) -or
        -not (Test-PathEqual -Left $configuredPython -Right $pythonPath)) {
        throw 'The protected configuration names an unexpected runtime or state path.'
    }
    $storage = Get-ConfiguredStorageBinding -Configuration $config `
        -Repository $repository -RecoveryTools $recoveryTools
    foreach ($directory in @($installRoot, $stateRoot, $repository, $recoveryTools)) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    Assert-NtfsLocalPath -Path $stateRoot -Label 'ProgramData state'
    Assert-NtfsLocalPath -Path $recoveryTools -Label 'Recovery tools'
    if ($storage.Mode -eq $localNtfsMode) {
        Assert-NtfsLocalPath -Path $repository -Label 'local_ntfs repository'
    }
    else {
        foreach ($directory in @($storage.DriveFsRoot, $storage.DriveFsCache)) {
            Assert-NormalDirectoryChain -Directory $directory
        }
        Assert-NtfsLocalPath -Path $storage.DriveFsCache -Label 'Google DriveFS cache'
        if (-not $isTestMode) {
            $repositoryDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($repository))
            if ($repositoryDrive.DriveType -ne [IO.DriveType]::Fixed -or
                -not [string]::Equals($repositoryDrive.DriveFormat, 'FAT32', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'The DriveFS repository is not on the supported fixed FAT32 streaming mount.'
            }
        }
    }
    foreach ($file in @($managerPath, $restorePath, $pythonPath, $resticPath, $configPath, (Join-Path $repository 'config'))) {
        [void](Assert-NormalFile -File $file)
    }
    Assert-RecoveryKeyAcl -Path (Get-CanonicalLocalPath -Value ([string]$config.recovery_key_file))
    [void](Assert-NormalFile -File $lastSuccessPath)
    return [pscustomobject]@{
        Json = $config
        Repository = $repository
        RecoveryTools = $recoveryTools
        RepositoryStorageMode = $storage.Mode
        Bytes = $loaded.Bytes
    }
}

function Assert-RuntimeManifest {
    $loaded = Read-BoundedJsonObject -File $runtimeManifestPath -MaximumBytes 4MB -Description 'Protected runtime manifest'
    $manifest = $loaded.Json
    $records = @($manifest.files)
    if ($manifest.schema_version -ne 1 -or [long]$manifest.file_count -ne $records.Count) {
        throw 'Protected runtime manifest header is invalid.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = $installRoot + '\'
    foreach ($record in $records) {
        if ($record.relative_path -isnot [string]) { throw 'Protected runtime manifest contains an invalid record.' }
        $relative = ([string]$record.relative_path).Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative.Split('\') -contains '..' -or -not $seen.Add($relative)) {
            throw "Protected runtime manifest contains an unsafe path: $relative"
        }
        $file = [IO.Path]::GetFullPath((Join-Path $installRoot $relative))
        if (-not $file.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime manifest path escapes its root.' }
        Assert-NormalDirectoryChain -Directory ([IO.Path]::GetDirectoryName($file))
        $item = Assert-NormalFile -File $file
        if ([long]$record.bytes -ne $item.Length -or
            -not [string]::Equals([string]$record.sha256, (Get-FileSha256Hex -File $file), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Protected runtime manifest mismatch: $relative"
        }
    }
    foreach ($required in @('backup-config.json','Manage-Restore.ps1','restore.py','restic.exe','Python\python.exe')) {
        if (-not $seen.Contains($required)) { throw "Protected runtime manifest is missing: $required" }
    }
    $actualFiles = @(
        Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force |
            Where-Object Name -notin @(
                'runtime-manifest.json',
                'scheduled-task.xml',
                'google-drive-verification-task.xml'
            )
    )
    if ($actualFiles.Count -ne $records.Count) {
        throw 'Protected runtime contains unmanifested or missing files.'
    }
    foreach ($file in $actualFiles) {
        Assert-NormalDirectoryChain -Directory $file.DirectoryName
        $relative = $file.FullName.Substring($installRoot.Length + 1)
        if (-not $seen.Contains($relative)) {
            throw "Protected runtime contains an unmanifested file: $relative"
        }
    }
}

function ConvertTo-WindowsArgument {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = [Text.StringBuilder]::new(); [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1))); [void]$builder.Append('"'); $slashes = 0; continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-RestoreBackend {
    param([string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pythonPath
    $start.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument -Value ([string]$_) }) -join ' ')
    $start.WorkingDirectory = $installRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Windows did not start the protected restore backend.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($utf8.GetByteCount($stdout) -gt 7MB -or $utf8.GetByteCount($stderr) -gt 1MB) {
            throw 'The protected restore backend returned more output than the manager accepts.'
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
    }
    finally { $process.Dispose() }
}

function ConvertFrom-BackendObject {
    param([string]$Text, [string]$Description)
    try { $value = $Text | ConvertFrom-Json }
    catch { throw "$Description returned invalid JSON." }
    if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
        throw "$Description did not return one JSON object."
    }
    return $value
}

function Test-CanonicalPathArraysEqual {
    param([object[]]$Left, [object[]]$Right)
    $leftPaths = @($Left | ForEach-Object { Get-CanonicalLocalPath -Value ([string]$_) } | Sort-Object)
    $rightPaths = @($Right | ForEach-Object { Get-CanonicalLocalPath -Value ([string]$_) } | Sort-Object)
    if ($leftPaths.Count -ne $rightPaths.Count) { return $false }
    for ($index = 0; $index -lt $leftPaths.Count; $index++) {
        if (-not (Test-PathEqual -Left $leftPaths[$index] -Right $rightPaths[$index])) { return $false }
    }
    return $true
}

function Assert-LegacySnapshotBinding {
    param([object]$Snapshot, [pscustomobject]$Configuration)
    if ([string](Get-OptionalProperty -Object $Snapshot -Name 'binding_state') -cne 'legacy_unbound' -or
        $null -ne (Get-OptionalProperty -Object $Snapshot -Name 'plan_id') -or
        $null -ne (Get-OptionalProperty -Object $Snapshot -Name 'config_generation')) {
        throw 'Legacy snapshot response contains plan-binding metadata.'
    }
    $configuredHostname = [string](Get-OptionalProperty -Object $Configuration.Json -Name 'hostname')
    if ([string]::IsNullOrWhiteSpace($configuredHostname) -or
        -not [string]::Equals([string]$Snapshot.hostname, $configuredHostname, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Legacy snapshot response belongs to another computer.'
    }
    $requiredTags = @((Get-OptionalProperty -Object $Configuration.Json -Name 'scheduled_tag'))
    $actualTags = @($Snapshot.tags)
    if ($requiredTags.Count -eq 0) { throw 'Legacy snapshot matching requires a scheduled tag.' }
    foreach ($tag in $actualTags) {
        if ($tag -isnot [string] -or
            ([string]$tag).StartsWith('restic-backuper-plan:', [StringComparison]::OrdinalIgnoreCase) -or
            ([string]$tag).StartsWith('restic-backuper-generation:', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Legacy snapshot response contains invalid or conflicting tags.'
        }
    }
    foreach ($tag in $requiredTags) {
        if ($tag -isnot [string] -or -not ($actualTags -ccontains [string]$tag)) {
            throw 'Legacy snapshot response does not have the configured scheduled tag.'
        }
    }
    if (-not (Test-CanonicalPathArraysEqual -Left @($Snapshot.paths) -Right @($Configuration.Json.sources))) {
        throw 'Legacy snapshot response does not have the configured complete source set.'
    }
}

function Assert-SnapshotListPayload {
    param([object]$Payload, [pscustomobject]$Configuration)
    if ([string]$Payload.schema -cne 'ResticBackuper.SnapshotList.v1' -or $Payload.schema_version -ne 1 -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$Payload.repository)) -Right $Configuration.Repository) -or
        [string]$Payload.binding.plan_id -cne $ExpectedPlanId -or
        [string]$Payload.binding.legacy_match_policy -cne 'exact-host-scheduled-tags-and-sources') {
        throw 'Snapshot-list response is not bound to the requested repository and plan.'
    }
    $snapshots = @($Payload.snapshots)
    if ($snapshots.Count -gt 10000) { throw 'Snapshot-list response exceeds the protected item limit.' }
    foreach ($snapshot in $snapshots) {
        if ([string]$snapshot.id -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Snapshot-list response contains an invalid immutable snapshot ID.'
        }
        $bindingState = [string](Get-OptionalProperty -Object $snapshot -Name 'binding_state')
        if ($bindingState -ceq 'plan') {
            $snapshotGeneration = Get-OptionalProperty -Object $snapshot -Name 'config_generation'
            if ([string](Get-OptionalProperty -Object $snapshot -Name 'plan_id') -cne $ExpectedPlanId -or
                $null -eq $snapshotGeneration -or
                $snapshotGeneration.GetType().FullName -notin @('System.Int32','System.Int64') -or
                [long]$snapshotGeneration -le 0) {
                throw 'Snapshot-list response contains an invalid plan-bound snapshot.'
            }
        }
        elseif ($bindingState -ceq 'legacy_unbound') {
            Assert-LegacySnapshotBinding -Snapshot $snapshot -Configuration $Configuration
        }
        else {
            throw 'Snapshot-list response contains an unknown snapshot binding.'
        }
    }
}

function Assert-TreePayload {
    param([object]$Payload, [pscustomobject]$Configuration)
    if ([string]$Payload.schema -cne 'ResticBackuper.SnapshotTree.v1' -or $Payload.schema_version -ne 1 -or
        [string]$Payload.snapshot_id -cne $canonicalSnapshotId -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$Payload.repository)) -Right $Configuration.Repository)) {
        throw 'Snapshot-tree response is not bound to the requested snapshot and plan.'
    }
    if ($allowLegacy) {
        if ([string]$Payload.snapshot_binding -cne 'legacy_unbound') {
            throw 'Snapshot-tree response did not return the explicitly requested legacy snapshot.'
        }
        Assert-LegacySnapshotBinding -Snapshot $Payload.snapshot -Configuration $Configuration
    }
    elseif ([string]$Payload.snapshot_binding -cne 'plan' -or
        [string]$Payload.snapshot.binding_state -cne 'plan' -or
        [string]$Payload.snapshot.plan_id -cne $ExpectedPlanId) {
        throw 'Snapshot-tree response is not bound to the requested backup plan.'
    }
    if (@($Payload.entries).Count -gt 100000) { throw 'Snapshot-tree response exceeds the protected item limit.' }
}

function Assert-RestoreReport {
    param([object]$Payload)
    if ([string]$Payload.schema -cne 'ResticBackuper.RestoreReport.v1' -or $Payload.schema_version -ne 1 -or
        [string]$Payload.snapshot_id -cne $canonicalSnapshotId -or
        -not (Test-PathEqual -Left (Get-CanonicalLocalPath -Value ([string]$Payload.target)) -Right $canonicalTarget) -or
        [string]$Payload.result -notin @('verified','partial','error')) {
        throw 'Restore report is not bound to the requested snapshot, plan, and target.'
    }
    if ($allowLegacy) {
        if ([string]$Payload.snapshot_binding -cne 'legacy_unbound' -or
            $null -ne (Get-OptionalProperty -Object $Payload -Name 'plan_id') -or
            $null -ne (Get-OptionalProperty -Object $Payload -Name 'snapshot_generation')) {
            throw 'Restore report did not return the explicitly requested legacy snapshot.'
        }
    }
    elseif ([string]$Payload.snapshot_binding -cne 'plan' -or [string]$Payload.plan_id -cne $ExpectedPlanId) {
        throw 'Restore report is not bound to the requested backup plan.'
    }
    if ([string]$Payload.result -eq 'verified' -and ($Payload.verified -isnot [bool] -or -not [bool]$Payload.verified)) {
        throw 'Restore report claims success without verification.'
    }
}

function Get-RecoveryDrillEvidence {
    param([pscustomobject]$Configuration)
    $evidence = (Read-BoundedJsonObject -File $lastSuccessPath -MaximumBytes 1MB -Description 'Protected latest-success evidence').Json
    if ($evidence.schema_version -ne 1 -or [string]$evidence.state -notin @('success','success_unchanged') -or
        [string]$evidence.plan_id -cne $ExpectedPlanId -or
        $evidence.config_generation.GetType().FullName -notin @('System.Int32','System.Int64') -or
        [long]$evidence.config_generation -ne $ExpectedConfigGeneration -or
        [string]$evidence.repository_id -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$evidence.snapshot_id -cnotmatch '^[0-9a-f]{64}$' -or
        $evidence.verification_complete -isnot [bool] -or -not [bool]$evidence.verification_complete -or
        $evidence.verification.repository_structure -isnot [bool] -or -not [bool]$evidence.verification.repository_structure -or
        $evidence.verification.canary.verified -isnot [bool] -or -not [bool]$evidence.verification.canary.verified -or
        [string]$evidence.verification.canary.snapshot_path -cne (Get-WindowsSnapshotPath -Value ([string]$Configuration.Json.canary_file)) -or
        [string]$evidence.verification.canary.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $evidence.verification.canary.bytes.GetType().FullName -notin @('System.Int32','System.Int64') -or
        [long]$evidence.verification.canary.bytes -lt 0 -or [long]$evidence.verification.canary.bytes -gt 8MB) {
        throw 'The latest successful backup does not contain a complete bounded recovery-drill proof.'
    }
    return [pscustomobject]@{
        SnapshotId = [string]$evidence.snapshot_id
        RepositoryId = [string]$evidence.repository_id
        CanarySha256 = [string]$evidence.verification.canary.sha256
        CanaryBytes = [long]$evidence.verification.canary.bytes
    }
}

function Assert-RecoveryDrillReport {
    param([object]$Payload, [pscustomobject]$Evidence)
    if ([string]$Payload.drill_kind -cne 'recovery_key_representative' -or
        [string]$Payload.credential_source -cne 'recovery_key' -or
        [string]$Payload.repository_id -cne $Evidence.RepositoryId -or
        [string]$Payload.result -cne 'verified' -or
        $Payload.verified -isnot [bool] -or -not [bool]$Payload.verified -or
        $Payload.partial_target_retained -isnot [bool] -or [bool]$Payload.partial_target_retained -or
        $Payload.canary_verified -isnot [bool] -or -not [bool]$Payload.canary_verified -or
        [string]$Payload.canary_sha256 -cne $Evidence.CanarySha256 -or
        [long]$Payload.canary_bytes -ne $Evidence.CanaryBytes -or
        [string]$Payload.sample_policy -cne 'one-or-two-bounded-files-per-source-v1' -or
        [long]$Payload.sample_file_count -lt 2 -or [long]$Payload.sample_file_count -gt 8 -or
        [long]$Payload.sample_bytes -le 0 -or [long]$Payload.sample_bytes -gt 32MB -or
        [string]$Payload.sample_paths_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The recovery-drill report does not contain complete verified sample evidence.'
    }
}

function Assert-ProtectedManagerHost {
    # Who may run this manager, and from where: the same checks for a single request and for a session.
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'Protected restore operations require 64-bit Windows PowerShell.'
    }
    if ($isTestMode) {
        if (Test-Administrator) { throw 'Disposable restore-manager tests must run without an elevated token.' }
    }
    elseif (-not (Test-Administrator)) { throw 'Protected restore operations must run elevated.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:currentSid = $identity.User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or
        -not [string]::Equals($ExpectedUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approve restore access with the same Windows account that made the request.'
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
        -not (Test-PathEqual -Left ([IO.Path]::GetFullPath($PSCommandPath)) -Right $managerPath)) {
        throw 'Protected restore operations must run from the installed manager script.'
    }
    $parsedPlan = [Guid]::Empty
    if (-not [Guid]::TryParseExact($ExpectedPlanId, 'D', [ref]$parsedPlan) -or
        $parsedPlan.ToString('D') -cne $ExpectedPlanId -or $ExpectedConfigGeneration -le 0) {
        throw 'The restore request has an invalid plan identity or generation.'
    }
}

function Initialize-RestoreRequest {
    # Validates one request's action and selectors and sets the request state every later step reads. A single request
    # passes its parameters; a session passes each request it receives. This is the only place either is validated.
    param(
        [string]$RequestAction,
        [string]$RequestSnapshotId,
        [string]$RequestTreePath,
        [string]$RequestTarget,
        [string]$RequestIncludesBase64,
        [string]$RequestAllowLegacyUnbound
    )
    $script:requestAction = ''
    $script:canonicalSnapshotId = ''
    $script:canonicalTreePath = ''
    $script:canonicalTarget = ''
    $script:includes = @()
    $script:includesHash = $null
    $script:historyRecorded = $null
    $script:historyError = $null
    $script:reportPath = $null
    if ($RequestAction -cnotin @('list_snapshots', 'list_tree', 'restore', 'restore_drill')) {
        throw 'The protected restore action is invalid.'
    }
    if ($RequestAllowLegacyUnbound -cnotin @('0', '1')) { throw 'The legacy snapshot option is invalid.' }
    $script:requestAction = $RequestAction
    $script:allowLegacy = $RequestAllowLegacyUnbound -ceq '1'
    if (($requestAction -eq 'list_snapshots' -or $requestAction -eq 'restore_drill') -and $allowLegacy) {
        throw 'Legacy snapshot access is not a snapshot-list request option.'
    }
    if ($requestAction -in @('list_tree','restore')) {
        if ($RequestSnapshotId -cnotmatch '^[0-9a-f]{64}$') { throw 'Restore operations require one exact lowercase snapshot ID.' }
        $script:canonicalSnapshotId = $RequestSnapshotId
    }
    elseif ($RequestSnapshotId) { throw 'Snapshot ID is not valid for this request.' }
    if ($RequestTreePath) {
        if ($requestAction -ne 'list_tree' -or $RequestTreePath.Length -gt 1024 -or -not $RequestTreePath.StartsWith('/') -or
            $RequestTreePath.Contains('\') -or $RequestTreePath.Split('/') -contains '..') {
            throw 'Snapshot tree path must be one bounded absolute in-snapshot path using forward slashes.'
        }
        $script:canonicalTreePath = $RequestTreePath
    }
    if ($requestAction -eq 'restore') { $script:canonicalTarget = Get-CanonicalLocalPath -Value $RequestTarget }
    elseif ($requestAction -eq 'restore_drill') {
        if ($RequestTarget) { throw 'A recovery-drill target is derived by the protected manager.' }
        $script:canonicalTarget = Get-DrillTarget -Nonce $RequestNonce
    }
    elseif ($RequestTarget) { throw 'Restore target is only valid for restore requests.' }
    try { $includesBytes = [Convert]::FromBase64String($RequestIncludesBase64) }
    catch { throw 'Restore include selection is not valid Base64.' }
    if ($includesBytes.Length -gt 64KB) { throw 'Restore include selection is too large.' }
    $script:includesHash = Get-Sha256Hex -Bytes $includesBytes
    try { $parsedIncludes = $utf8.GetString($includesBytes) | ConvertFrom-Json }
    catch { throw 'Restore include selection is not valid UTF-8 JSON.' }
    $script:includes = @($parsedIncludes)
    if ($includes.Count -gt 64 -or ($requestAction -ne 'restore' -and $includes.Count -ne 0)) {
        throw 'Restore include selection is invalid for this action.'
    }
    foreach ($include in $includes) {
        if ($include -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$include) -or
            ([string]$include).Length -gt 1024 -or ([string]$include).Contains([char]0)) {
            throw 'Restore include selection contains an invalid pattern.'
        }
    }
}

function Set-OperationOutcome {
    param([bool]$Ok, [object]$Payload, [string]$ErrorMessage, [int]$BackendExitCode, [int]$ExitCode)
    $script:operationOutcome = [pscustomobject]@{
        Ok = $Ok; Payload = $Payload; ErrorMessage = $ErrorMessage; BackendExitCode = $BackendExitCode; ExitCode = $ExitCode
    }
}

function Invoke-RestoreOperation {
    # The protected step of one validated request, under the global run lock: plan, journal, configuration and runtime
    # checks, the backend, and the checks of what it returned. The outcome (and the exit code a single request ends with)
    # is left in $operationOutcome for the caller to report. The run lock is released before this returns.
    $script:operationOutcome = $null
    $lockStream = $null
    try {
        Write-ProgressResult -Stage preflight -Message 'Validating the protected backup plan and repository.' -Percent 5
        $lockStream = Enter-RunLock
        Remove-OrphanedRestoreReports
        Assert-NoPendingJournal
        $configuration = Get-ValidatedConfiguration
        Assert-RuntimeManifest
        $drillEvidence = $null
        if ($requestAction -eq 'restore_drill') {
            Initialize-DrillRoot -Configuration $configuration
            $drillEvidence = Get-RecoveryDrillEvidence -Configuration $configuration
            $script:canonicalSnapshotId = $drillEvidence.SnapshotId
        }

        $arguments = @('-I','-S','-B',$restorePath,'--config',$configPath,'--restic',$resticPath)
        if ($requestAction -eq 'list_snapshots') {
            $arguments += '--list-snapshots-json'
            Write-ProgressResult -Stage reading -Message 'Reading plan-bound and safely matched legacy snapshot history.' -Percent 35
        }
        elseif ($requestAction -eq 'list_tree') {
            $arguments += @('--list-tree-json','--snapshot',$canonicalSnapshotId)
            if ($allowLegacy) { $arguments += '--allow-legacy-unbound' }
            if ($canonicalTreePath) { $arguments += @('--tree-path',$canonicalTreePath) }
            Write-ProgressResult -Stage reading -Message 'Reading the selected snapshot folder.' -Percent 35
        }
        else {
            $script:reportPath = Join-Path $resultRoot "$RequestNonce.restore-report.json"
            if (Test-Path -LiteralPath $reportPath) { throw 'Protected restore report target already exists.' }
            $arguments += @('--snapshot',$canonicalSnapshotId,'--target',$canonicalTarget,'--report',$reportPath)
            if ($allowLegacy) { $arguments += '--allow-legacy-unbound' }
            if ($requestAction -eq 'restore_drill') {
                $arguments += @(
                    '--recovery-key-file',[string]$configuration.Json.recovery_key_file,
                    '--recovery-drill','--drill-canary-sha256',$drillEvidence.CanarySha256,
                    '--drill-canary-bytes',$drillEvidence.CanaryBytes.ToString([Globalization.CultureInfo]::InvariantCulture)
                )
                Write-ProgressResult -Stage restoring -Message 'Restoring the canary and a bounded representative sample with the recovery key.' -Percent 25
            }
            else {
                foreach ($include in $includes) { $arguments += @('--include',[string]$include) }
                Write-ProgressResult -Stage restoring -Message 'Restoring to the new location and verifying every restored file.' -Percent 25
            }
        }
        $backend = Invoke-RestoreBackend -Arguments $arguments
        $payload = $null
        if ($requestAction -eq 'list_snapshots') {
            if ($backend.ExitCode -ne 0) { throw "Snapshot history query failed with exit code $($backend.ExitCode)." }
            $payload = ConvertFrom-BackendObject -Text $backend.Stdout -Description 'Snapshot history query'
            Assert-SnapshotListPayload -Payload $payload -Configuration $configuration
        }
        elseif ($requestAction -eq 'list_tree') {
            if ($backend.ExitCode -ne 0) { throw "Snapshot tree query failed with exit code $($backend.ExitCode)." }
            $payload = ConvertFrom-BackendObject -Text $backend.Stdout -Description 'Snapshot tree query'
            Assert-TreePayload -Payload $payload -Configuration $configuration
        }
        else {
            if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
                throw "Restore backend returned exit code $($backend.ExitCode) without a protected report."
            }
            $payload = (Read-BoundedJsonObject -File $reportPath -MaximumBytes 64KB -Description 'Protected restore report').Json
            Assert-RestoreReport -Payload $payload
            [IO.File]::Delete($reportPath); $script:reportPath = $null
            if ($backend.ExitCode -ne 0 -or [string]$payload.result -ne 'verified') {
                if ($requestAction -eq 'restore') {
                    try { Write-RestoreHistory -Payload $payload -BackendExitCode $backend.ExitCode; $script:historyRecorded = $true }
                    catch { $script:historyRecorded = $false; $script:historyError = Get-SanitizedError -Message $_.Exception.Message }
                }
                $failureMessage = [string]$payload.error
                if ($requestAction -eq 'restore_drill' -and [IO.Directory]::Exists($canonicalTarget)) {
                    try { Protect-RecoveryDrillTarget -Path $canonicalTarget }
                    catch { $failureMessage += ' The retained drill target could not be normalized to its protected review ACL.' }
                }
                Write-ProgressResult -Stage failed -Message 'Restore stopped; any partial alternate target was retained for inspection.' -Percent 0
                Set-OperationOutcome -Ok $false -Payload $payload -ErrorMessage $failureMessage -BackendExitCode $backend.ExitCode `
                    -ExitCode $(if ($backend.ExitCode -ne 0) { $backend.ExitCode } else { 1 })
                return
            }
            if ($requestAction -eq 'restore_drill') {
                Assert-RecoveryDrillReport -Payload $payload -Evidence $drillEvidence
                try { Protect-RecoveryDrillTarget -Path $canonicalTarget }
                catch {
                    Write-ProgressResult -Stage failed -Message 'The sample was verified, but its retained review ACL could not be protected.' -Percent 0
                    Set-OperationOutcome -Ok $false -Payload $payload -ErrorMessage 'The recovery drill was verified, but its retained sample could not be normalized to the protected read-only ACL; readiness evidence was not recorded.' -BackendExitCode 0 -ExitCode 1
                    return
                }
            }
            try { Write-RestoreHistory -Payload $payload -BackendExitCode $backend.ExitCode; $script:historyRecorded = $true }
            catch { $script:historyRecorded = $false; $script:historyError = Get-SanitizedError -Message $_.Exception.Message }
            if ($requestAction -eq 'restore_drill' -and -not $historyRecorded) {
                Write-ProgressResult -Stage failed -Message 'The sample was restored and verified, but readiness evidence was not recorded.' -Percent 0
                Set-OperationOutcome -Ok $false -Payload $payload -ErrorMessage 'The recovery drill was verified, but its protected readiness evidence could not be recorded.' -BackendExitCode 0 -ExitCode 1
                return
            }
        }
        Write-ProgressResult -Stage complete -Message $(if ($requestAction -eq 'restore_drill') {
            'Recovery-key restore drill completed, verified, and was recorded.'
        } elseif ($requestAction -eq 'restore') {
            'Restore completed and was verified.'
        } else { 'Protected snapshot data loaded.' }) -Percent 100
        Set-OperationOutcome -Ok $true -Payload $payload -ErrorMessage $null -BackendExitCode $backend.ExitCode -ExitCode 0
    }
    catch {
        $failure = $_.Exception.Message
        try { Write-ProgressResult -Stage failed -Message (Get-SanitizedError -Message $failure) -Percent 0 } catch { }
        if ($isTestMode) { [Console]::Error.WriteLine($failure); [Console]::Error.WriteLine($_.ScriptStackTrace) }
        Set-OperationOutcome -Ok $false -Payload $null -ErrorMessage $failure -BackendExitCode -1 -ExitCode 1
    }
    finally {
        if ($null -ne $reportPath -and [IO.File]::Exists($reportPath)) { try { [IO.File]::Delete($reportPath) } catch { } }
        $script:reportPath = $null
        if ($null -ne $lockStream) { Exit-RunLock -Stream $lockStream }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Restore approval session (-Operation session). One elevation serves one guided restore: any number of snapshot and
# folder listings and at most one restore. Each request goes through Initialize-RestoreRequest and
# Invoke-RestoreOperation exactly as a single request does. The channel is a named pipe that only the requesting account
# can open, that is served once (one instance, created first or not at all), and that is used only after Windows names
# the client as the dashboard process that asked and the client proves the session token. Messages are a 4-byte
# little-endian length and one UTF-8 JSON object. Any protocol violation ends the session; the reason is recorded in the
# session's protected result file as a fixed code and sentence, never with what the client sent.
# ---------------------------------------------------------------------------------------------------------------------

function New-SessionException {
    param([string]$Reason, [string]$Message)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['restore_session_reason'] = $Reason
    return $exception
}

function Test-FixedTextEqual {
    param([string]$Left, [string]$Right)
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $Left.Length; $index++) { $difference = $difference -bor ([int]$Left[$index] -bxor [int]$Right[$index]) }
    return $difference -eq 0
}

function Assert-SessionTimeouts {
    param([int]$Idle, [int]$Lifetime, [int]$Connect)
    if ($Idle -lt $sessionMinimumSeconds -or $Idle -gt $sessionMaximumIdleSeconds -or
        $Lifetime -lt $sessionMinimumSeconds -or $Lifetime -gt $sessionMaximumLifetimeSeconds -or
        $Connect -lt $sessionMinimumSeconds -or $Connect -gt $sessionMaximumConnectSeconds) {
        throw 'The restore-session timeouts are outside the protected limits.'
    }
}

function Get-SessionRequestDigest {
    # RestoreRequest.v3: the session request binds the account, plan, the one dashboard process, the pipe, the hash of the
    # session token (the token itself never leaves the dashboard except on the pipe), the timeouts and the nonce.
    param([string]$UserSid)
    $payload = @(
        $sessionRequestDomain, $UserSid, 'session', $ExpectedConfigSha256, $ExpectedPlanId,
        $ExpectedConfigGeneration.ToString([Globalization.CultureInfo]::InvariantCulture),
        $DashboardProcessId.ToString([Globalization.CultureInfo]::InvariantCulture),
        $PipeName, $SessionTokenSha256,
        $IdleTimeoutSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        $LifetimeSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        $ConnectTimeoutSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        $RequestNonce
    ) -join "`n"
    return Get-Sha256Hex -Bytes $utf8.GetBytes($payload)
}

function ConvertTo-SessionFrame {
    param([object]$Message, [int]$MaximumBytes)
    $body = $utf8.GetBytes((ConvertTo-Json -InputObject $Message -Depth 40 -Compress))
    if ($body.Length -le 0 -or $body.Length -gt $MaximumBytes) {
        throw (New-SessionException -Reason 'frame_too_large' -Message 'A restore-session message exceeds its size limit.')
    }
    $frame = New-Object byte[] (4 + $body.Length)
    $frame[0] = [byte]($body.Length -band 0xFF)
    $frame[1] = [byte](($body.Length -shr 8) -band 0xFF)
    $frame[2] = [byte](($body.Length -shr 16) -band 0xFF)
    $frame[3] = [byte](($body.Length -shr 24) -band 0xFF)
    [Array]::Copy($body, 0, $frame, 4, $body.Length)
    return ,$frame
}

function Get-SessionFrameLength {
    param([byte[]]$Header, [int]$MaximumBytes)
    if ($null -eq $Header -or $Header.Length -ne 4) {
        throw (New-SessionException -Reason 'malformed_frame' -Message 'A restore-session frame header is incomplete.')
    }
    $length = [long]$Header[0] + ([long]$Header[1] * 256) + ([long]$Header[2] * 65536) + ([long]$Header[3] * 16777216)
    if ($length -le 0 -or $length -gt $MaximumBytes) {
        throw (New-SessionException -Reason 'frame_too_large' -Message 'A restore-session frame is empty or exceeds its size limit.')
    }
    return [int]$length
}

function ConvertFrom-SessionFrameBody {
    param([byte[]]$Body)
    try { $text = $utf8.GetString($Body) }
    catch { throw (New-SessionException -Reason 'malformed_frame' -Message 'A restore-session message is not valid UTF-8.') }
    if ($text.Length -eq 0 -or $text[0] -ne '{') {
        throw (New-SessionException -Reason 'malformed_frame' -Message 'A restore-session message is not one JSON object.')
    }
    try { $value = ConvertFrom-Json -InputObject $text }
    catch { throw (New-SessionException -Reason 'malformed_frame' -Message 'A restore-session message is not valid JSON.') }
    if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
        throw (New-SessionException -Reason 'malformed_frame' -Message 'A restore-session message is not one JSON object.')
    }
    return $value
}

function Assert-SessionMessageFields {
    # Exactly these fields, with exactly these names: nothing missing, nothing extra.
    param([object]$Message, [string[]]$Names, [string]$Description)
    $actual = @($Message.PSObject.Properties | ForEach-Object { $_.Name })
    $valid = $actual.Count -eq $Names.Count
    if ($valid) {
        foreach ($name in $Names) { if ($actual -cnotcontains $name) { $valid = $false; break } }
    }
    if (-not $valid) {
        throw (New-SessionException -Reason 'schema_violation' -Message "$Description does not have exactly the expected fields.")
    }
}

function Get-SessionMessageType {
    param([object]$Message)
    $property = $Message.PSObject.Properties['type']
    if ($null -eq $property -or $property.Name -cne 'type' -or $property.Value -isnot [string]) {
        throw (New-SessionException -Reason 'schema_violation' -Message 'A restore-session message has no valid type.')
    }
    return [string]$property.Value
}

function Get-SessionString {
    param([object]$Message, [string]$Name, [int]$MaximumLength, [string]$Description)
    $value = $Message.PSObject.Properties[$Name].Value
    if ($value -isnot [string] -or $value.Length -gt $MaximumLength) {
        throw (New-SessionException -Reason 'schema_violation' -Message "$Description has an invalid $Name.")
    }
    return [string]$value
}

function Get-SessionInteger {
    param([object]$Message, [string]$Name, [string]$Description)
    $value = $Message.PSObject.Properties[$Name].Value
    if (($value -isnot [int] -and $value -isnot [long]) -or [long]$value -le 0) {
        throw (New-SessionException -Reason 'schema_violation' -Message "$Description has an invalid $Name.")
    }
    return [long]$value
}

function ConvertTo-SessionHello {
    param([object]$Message)
    Assert-SessionMessageFields -Message $Message -Names @('type', 'protocol', 'session_token', 'dashboard_process_id') `
        -Description 'The session hello'
    if ((Get-SessionMessageType -Message $Message) -cne 'hello' -or
        (Get-SessionString -Message $Message -Name 'protocol' -MaximumLength 128 -Description 'The session hello') -cne $sessionProtocol) {
        throw (New-SessionException -Reason 'schema_violation' -Message 'The session hello names another protocol.')
    }
    $token = Get-SessionString -Message $Message -Name 'session_token' -MaximumLength 64 -Description 'The session hello'
    if ($token -cnotmatch '^[0-9a-f]{64}$') {
        throw (New-SessionException -Reason 'token_mismatch' -Message 'The restore-session client did not present this session''s token.')
    }
    return [pscustomobject]@{
        Token = $token
        ProcessId = Get-SessionInteger -Message $Message -Name 'dashboard_process_id' -Description 'The session hello'
    }
}

function ConvertTo-SessionRequest {
    # The envelope of one request. Its action and selectors are validated afterwards by Initialize-RestoreRequest, exactly
    # as a single request's parameters are. A recovery drill is never served by a session.
    param([object]$Message, [long]$ExpectedRequestId)
    $description = 'A restore-session request'
    Assert-SessionMessageFields -Message $Message -Description $description -Names @(
        'type', 'request_id', 'action', 'snapshot_id', 'tree_path', 'target', 'includes_base64', 'allow_legacy_unbound')
    if ((Get-SessionMessageType -Message $Message) -cne 'request') {
        throw (New-SessionException -Reason 'schema_violation' -Message "$description has another type.")
    }
    $requestId = Get-SessionInteger -Message $Message -Name 'request_id' -Description $description
    if ($requestId -ne $ExpectedRequestId) {
        throw (New-SessionException -Reason 'schema_violation' -Message "$description is out of sequence.")
    }
    $requestedAction = Get-SessionString -Message $Message -Name 'action' -MaximumLength 32 -Description $description
    if ($requestedAction -cnotin @('list_snapshots', 'list_tree', 'restore')) {
        throw (New-SessionException -Reason 'action_not_allowed' -Message "$description asks for an action a session does not serve.")
    }
    $legacy = Get-SessionString -Message $Message -Name 'allow_legacy_unbound' -MaximumLength 1 -Description $description
    if ($legacy -cnotin @('0', '1')) {
        throw (New-SessionException -Reason 'schema_violation' -Message "$description has an invalid allow_legacy_unbound.")
    }
    return [pscustomobject]@{
        RequestId = $requestId
        Action = $requestedAction
        SnapshotId = Get-SessionString -Message $Message -Name 'snapshot_id' -MaximumLength 128 -Description $description
        TreePath = Get-SessionString -Message $Message -Name 'tree_path' -MaximumLength 2048 -Description $description
        Target = Get-SessionString -Message $Message -Name 'target' -MaximumLength 4096 -Description $description
        IncludesBase64 = Get-SessionString -Message $Message -Name 'includes_base64' -MaximumLength 131072 -Description $description
        AllowLegacyUnbound = $legacy
    }
}

function Assert-RestoreSessionClient {
    # Windows' own word on the client (its process and its account) must match the request, and the client must know the
    # session token whose hash the elevated command line carries.
    param(
        [long]$ObservedProcessId,
        [string]$ObservedUserSid,
        [long]$ClaimedProcessId,
        [string]$PresentedToken,
        [long]$ExpectedProcessId,
        [string]$ExpectedSid,
        [string]$ExpectedTokenSha256
    )
    if ($ExpectedProcessId -le 0 -or $ObservedProcessId -ne $ExpectedProcessId -or $ClaimedProcessId -ne $ExpectedProcessId) {
        throw (New-SessionException -Reason 'client_process_mismatch' -Message 'The restore-session client is not the dashboard process that asked for the session.')
    }
    if ([string]::IsNullOrWhiteSpace($ObservedUserSid) -or [string]::IsNullOrWhiteSpace($ExpectedSid) -or
        -not [string]::Equals($ObservedUserSid, $ExpectedSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-SessionException -Reason 'client_account_mismatch' -Message 'The restore-session client runs as another Windows account.')
    }
    if ($PresentedToken -cnotmatch '^[0-9a-f]{64}$' -or $ExpectedTokenSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not (Test-FixedTextEqual -Left (Get-Sha256Hex -Bytes $utf8.GetBytes($PresentedToken)) -Right $ExpectedTokenSha256)) {
        throw (New-SessionException -Reason 'token_mismatch' -Message 'The restore-session client did not present this session''s token.')
    }
}

function Get-PipeNativeMethods {
    # GetNamedPipeClientProcessId has no managed equivalent. The P/Invoke stub is emitted in memory (Reflection.Emit, run
    # only), so nothing is compiled or loaded from a folder the requesting account can write.
    if ($null -ne $script:sessionPipeNative) { return $script:sessionPipeNative }
    $assemblyName = [Reflection.AssemblyName]::new('ResticBackuper.RestoreSession.Native.' + [Guid]::NewGuid().ToString('N'))
    $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly($assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule($assemblyName.Name)
    $type = $module.DefineType('ResticBackuper.RestoreSession.NativeMethods', [Reflection.TypeAttributes]'Public, Class, Sealed, Abstract')
    $method = $type.DefinePInvokeMethod('GetNamedPipeClientProcessId', 'kernel32.dll',
        [Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
        [Reflection.CallingConventions]::Standard, [bool],
        [Type[]]@([Microsoft.Win32.SafeHandles.SafePipeHandle], [UInt32].MakeByRefType()),
        [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Unicode)
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    $script:sessionPipeNative = $type.CreateType()
    return $script:sessionPipeNative
}

function Get-NamedPipeClientProcessId {
    param([IO.Pipes.NamedPipeServerStream]$Pipe)
    $native = Get-PipeNativeMethods
    [uint32]$clientProcessId = 0
    if (-not $native::GetNamedPipeClientProcessId($Pipe.SafePipeHandle, [ref]$clientProcessId) -or $clientProcessId -eq 0) {
        throw (New-SessionException -Reason 'client_process_mismatch' -Message 'Windows did not identify the restore-session client process.')
    }
    return [long]$clientProcessId
}

function Get-NamedPipeClientUserSid {
    # The account of the token the client opened the pipe with. The client connects at identification level, which is
    # enough to read it and not enough to act as the client.
    param([IO.Pipes.NamedPipeServerStream]$Pipe)
    $script:sessionObservedClientSid = $null
    try {
        $Pipe.RunAsClient([IO.Pipes.PipeStreamImpersonationWorker]{
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent($true)
            if ($null -ne $identity -and $null -ne $identity.User) { $script:sessionObservedClientSid = $identity.User.Value }
        })
    }
    catch {
        throw (New-SessionException -Reason 'client_account_mismatch' -Message 'Windows did not identify the restore-session client account.')
    }
    return $script:sessionObservedClientSid
}

function New-RestoreSessionPipe {
    # Only the requesting account may open the pipe, never over the network, and there is one instance: the pipe is
    # created first (FILE_FLAG_FIRST_PIPE_INSTANCE, which one instance implies) or not at all, so a name someone else
    # already holds ends the session instead of being shared.
    $security = [IO.Pipes.PipeSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.AddAccessRule([IO.Pipes.PipeAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-2'),
        [IO.Pipes.PipeAccessRights]::FullControl, [Security.AccessControl.AccessControlType]::Deny))
    $security.AddAccessRule([IO.Pipes.PipeAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($currentSid),
        [IO.Pipes.PipeAccessRights]::ReadWrite, [Security.AccessControl.AccessControlType]::Allow))
    try {
        return [IO.Pipes.NamedPipeServerStream]::new($PipeName, [IO.Pipes.PipeDirection]::InOut, 1,
            [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 65536, 65536, $security)
    }
    catch {
        throw (New-SessionException -Reason 'pipe_unavailable' -Message 'The restore-session pipe name was already in use, so the session was refused.')
    }
}

function Test-SessionConfiguration {
    # $null while the protected configuration is the one the session was approved for. Read with full sharing so that a
    # protected change replacing the file is never held up by this check.
    try {
        $stream = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if ($stream.Length -le 0 -or $stream.Length -gt 1MB) { return 'config_changed' }
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try { $hash = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $algorithm.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { return 'config_unreadable' }
    if (-not [string]::Equals($hash, $ExpectedConfigSha256, [StringComparison]::Ordinal)) { return 'config_changed' }
    return $null
}

function Test-SessionClientExited {
    # The dashboard process the session serves has ended. A process Windows will not report on is left to the channel,
    # which closes with it.
    if ($null -eq $sessionClientProcess) { return $false }
    try { return [bool]$sessionClientProcess.HasExited } catch { return $false }
}

function Get-SessionEndReason {
    # Why an idle session must end now, or $null.
    $now = [DateTime]::UtcNow
    if ($now -ge $sessionLifetimeEndUtc) { return 'lifetime_expired' }
    if ($now -ge $sessionIdleEndUtc) { return 'idle_timeout' }
    if (Test-SessionClientExited) { return 'client_exited' }
    if ($now -ge $sessionNextConfigurationCheckUtc) {
        $script:sessionNextConfigurationCheckUtc = $now.AddSeconds($sessionConfigurationPollSeconds)
        $configurationEnd = Test-SessionConfiguration
        if ($null -ne $configurationEnd) { return $configurationEnd }
    }
    return $null
}

function Wait-SessionRead {
    # One read into $Buffer. While -Idle (waiting for a message to begin) the session's own ends apply; otherwise the read
    # must complete by $DeadlineUtc. Returns the number of bytes read; the client closing the channel ends the session.
    param([byte[]]$Buffer, [int]$Offset, [int]$Count, [DateTime]$DeadlineUtc, [switch]$Idle)
    try { $task = $sessionPipe.ReadAsync($Buffer, $Offset, $Count) }
    catch {
        if ($isTestMode) { [Console]::Error.WriteLine('session read failed: ' + $_.Exception.ToString()) }
        throw (New-SessionException -Reason 'client_disconnected' -Message 'The restore-session client disconnected.')
    }
    while ($true) {
        try { $done = $task.Wait($sessionPollMilliseconds) }
        catch {
            if ($isTestMode) { [Console]::Error.WriteLine('session read failed: ' + $_.Exception.ToString()) }
            throw (New-SessionException -Reason 'client_disconnected' -Message 'The restore-session client disconnected.')
        }
        if ($done) { break }
        if ($Idle) {
            $end = Get-SessionEndReason
            if ($null -ne $end) { throw (New-SessionException -Reason $end -Message 'The restore session ended.') }
        }
        elseif ([DateTime]::UtcNow -ge $DeadlineUtc) {
            throw (New-SessionException -Reason 'frame_timeout' -Message 'A restore-session message did not arrive in time.')
        }
    }
    $read = $task.Result
    if ($read -le 0) { throw (New-SessionException -Reason 'client_disconnected' -Message 'The restore-session client closed the channel.') }
    return $read
}

function Read-SessionMessage {
    # The next message. Once its first byte has arrived, the rest of the frame must follow within the frame deadline.
    param([switch]$Idle, [DateTime]$StartDeadlineUtc = [DateTime]::MaxValue)
    $header = New-Object byte[] 4
    $offset = Wait-SessionRead -Buffer $header -Offset 0 -Count 4 -DeadlineUtc $StartDeadlineUtc -Idle:$Idle
    $frameDeadline = [DateTime]::UtcNow.AddSeconds($sessionFrameSeconds)
    while ($offset -lt 4) {
        $offset += Wait-SessionRead -Buffer $header -Offset $offset -Count (4 - $offset) -DeadlineUtc $frameDeadline
    }
    $length = Get-SessionFrameLength -Header $header -MaximumBytes $sessionMaximumRequestBytes
    $body = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $offset += Wait-SessionRead -Buffer $body -Offset $offset -Count ($length - $offset) -DeadlineUtc $frameDeadline
    }
    return (ConvertFrom-SessionFrameBody -Body $body)
}

function Write-SessionFrame {
    param([byte[]]$Frame, [int]$TimeoutSeconds = $sessionWriteSeconds)
    $completed = $false
    try {
        $task = $sessionPipe.WriteAsync($Frame, 0, $Frame.Length)
        $completed = $task.Wait($TimeoutSeconds * 1000)
    }
    catch { throw (New-SessionException -Reason 'client_disconnected' -Message 'The restore-session client disconnected.') }
    if (-not $completed) {
        throw (New-SessionException -Reason 'write_timeout' -Message 'The restore-session client stopped reading.')
    }
}

function Write-SessionMessage {
    param([object]$Message, [int]$TimeoutSeconds = $sessionWriteSeconds)
    Write-SessionFrame -Frame (ConvertTo-SessionFrame -Message $Message -MaximumBytes $sessionMaximumResponseBytes) `
        -TimeoutSeconds $TimeoutSeconds
}

function Send-SessionProgress {
    # Advisory, like a single request's progress file: a client that stopped listening does not stop the operation, which
    # runs to its end like a single request whose dashboard went away.
    param([string]$Stage, [string]$Message, [int]$Percent)
    if ($sessionProgressBroken) { return }
    try {
        Write-SessionMessage -TimeoutSeconds 5 -Message ([ordered]@{
            type = 'progress'; request_id = $sessionRequestId; stage = $Stage; message = $Message; percent = $Percent
        })
    }
    catch { $script:sessionProgressBroken = $true }
}

function Invoke-SessionRequest {
    param([pscustomobject]$Request)
    $script:sessionRequestId = $Request.RequestId
    try {
        try {
            Initialize-RestoreRequest -RequestAction $Request.Action -RequestSnapshotId $Request.SnapshotId `
                -RequestTreePath $Request.TreePath -RequestTarget $Request.Target `
                -RequestIncludesBase64 $Request.IncludesBase64 -RequestAllowLegacyUnbound $Request.AllowLegacyUnbound
        }
        catch {
            throw (New-SessionException -Reason 'request_rejected' -Message 'A restore-session request failed the protected request validation.')
        }
        $null = Invoke-RestoreOperation
        $outcome = $operationOutcome
        $exitCode = $outcome.ExitCode
        $sessionOperationCounts[$Request.Action] = [int]$sessionOperationCounts[$Request.Action] + 1
        $document = New-FinalResultDocument -Ok $outcome.Ok -Payload $outcome.Payload -ErrorMessage $outcome.ErrorMessage `
            -BackendExitCode $outcome.BackendExitCode
        try {
            $frame = ConvertTo-SessionFrame -MaximumBytes $sessionMaximumResponseBytes -Message ([ordered]@{
                type = 'result'; request_id = $Request.RequestId; exit_code = $exitCode; result = $document
            })
        }
        catch {
            # As a single request whose result file would exceed its limit: the result is a failure that says so.
            $document = New-FinalResultDocument -Ok $false -Payload $null -BackendExitCode -1 `
                -ErrorMessage 'Protected restore result exceeds its size limit.'
            $frame = ConvertTo-SessionFrame -MaximumBytes $sessionMaximumResponseBytes -Message ([ordered]@{
                type = 'result'; request_id = $Request.RequestId; exit_code = 1; result = $document
            })
        }
        Write-SessionFrame -Frame $frame
    }
    finally { $script:sessionRequestId = $null }
}

function Write-SessionRecord {
    # The session's protected result file: how it ended, as a fixed code and sentence, and what it served.
    param([string]$Reason, [bool]$Ok, [string]$Detail)
    if (-not $resultChannelReady) { return }
    Write-ProtectedJson -Path ([IO.Path]::GetFullPath($ResultPath)) -Value ([ordered]@{
        schema_version = 1; request_nonce = $RequestNonce; request_digest = $RequestDigest;
        request_user_sid = $currentSid; action = 'session'; protocol = $sessionProtocol;
        expected_config_sha256 = $ExpectedConfigSha256; plan_id = $ExpectedPlanId; config_generation = $ExpectedConfigGeneration;
        dashboard_process_id = $DashboardProcessId; ok = $Ok; close_reason = $Reason;
        error = if ($Ok) { $null } else { Get-SanitizedError -Message $Detail };
        operations = $sessionOperationCounts;
        started_utc = $sessionStartedUtc.ToString('o'); finished_utc = [DateTime]::UtcNow.ToString('o')
    })
}

function Invoke-RestoreSession {
    $script:sessionStartedUtc = [DateTime]::UtcNow
    try {
        Assert-ProtectedManagerHost
        if ($PipeName -cnotmatch $sessionPipePattern) { throw 'The restore-session pipe name is invalid.' }
        if ($DashboardProcessId -le 0 -or $DashboardProcessId -gt [uint32]::MaxValue -or $DashboardProcessId -eq $PID) {
            throw 'The restore-session dashboard process is invalid.'
        }
        Assert-SessionTimeouts -Idle $IdleTimeoutSeconds -Lifetime $LifetimeSeconds -Connect $ConnectTimeoutSeconds
        if ((Get-SessionRequestDigest -UserSid $currentSid) -cne $RequestDigest) {
            throw 'The restore-session request digest does not match the requested session.'
        }
        Assert-NormalDirectoryChain -Directory $installRoot
        Assert-NormalDirectoryChain -Directory $stateRoot
        Initialize-ResultChannel
    }
    catch {
        # Nothing was opened. As with a single request that fails before its result channel exists, only a sanitized line.
        if ($isTestMode) { [Console]::Error.WriteLine($_.Exception.Message) }
        else { [Console]::Error.WriteLine((Get-SanitizedError -Message $_.Exception.Message)) }
        $script:sessionExitCode = 1
        return
    }

    $reason = 'internal_error'
    $detail = 'The restore session stopped after an unexpected error.'
    try {
        $script:sessionLifetimeEndUtc = $sessionStartedUtc.AddSeconds($LifetimeSeconds)
        $startEnd = Test-SessionConfiguration
        if ($null -ne $startEnd) { throw (New-SessionException -Reason $startEnd -Message 'The protected configuration changed before the session started.') }
        try { $script:sessionClientProcess = [Diagnostics.Process]::GetProcessById([int]$DashboardProcessId) }
        catch { throw (New-SessionException -Reason 'client_exited' -Message 'The dashboard that asked for the session is no longer running.') }
        $script:sessionPipe = New-RestoreSessionPipe
        $connect = $sessionPipe.WaitForConnectionAsync()
        $connectEnd = [DateTime]::UtcNow.AddSeconds($ConnectTimeoutSeconds)
        while ($true) {
            try { if ($connect.Wait($sessionPollMilliseconds)) { break } }
            catch { throw (New-SessionException -Reason 'client_disconnected' -Message 'The restore-session client did not connect.') }
            if ([DateTime]::UtcNow -ge $connectEnd) { throw (New-SessionException -Reason 'connect_timeout' -Message 'The dashboard did not connect in time.') }
            if ([DateTime]::UtcNow -ge $sessionLifetimeEndUtc) { throw (New-SessionException -Reason 'lifetime_expired' -Message 'The restore session reached its lifetime.') }
            if (Test-SessionClientExited) { throw (New-SessionException -Reason 'client_exited' -Message 'The dashboard that asked for the session is no longer running.') }
        }
        # Who connected is checked before anything it sent is read.
        $clientProcessId = Get-NamedPipeClientProcessId -Pipe $sessionPipe
        if ($clientProcessId -ne $DashboardProcessId) {
            throw (New-SessionException -Reason 'client_process_mismatch' -Message 'The restore-session client is not the dashboard process that asked for the session.')
        }
        $hello = ConvertTo-SessionHello -Message (Read-SessionMessage -StartDeadlineUtc ([DateTime]::UtcNow.AddSeconds($sessionFrameSeconds)))
        $clientSid = Get-NamedPipeClientUserSid -Pipe $sessionPipe
        Assert-RestoreSessionClient -ObservedProcessId $clientProcessId -ObservedUserSid $clientSid `
            -ClaimedProcessId $hello.ProcessId -PresentedToken $hello.Token -ExpectedProcessId $DashboardProcessId `
            -ExpectedSid $ExpectedUserSid -ExpectedTokenSha256 $SessionTokenSha256
        Write-SessionMessage -Message ([ordered]@{
            type = 'ready'; protocol = $sessionProtocol; request_nonce = $RequestNonce; request_digest = $RequestDigest;
            broker_process_id = $PID; idle_timeout_seconds = $IdleTimeoutSeconds; lifetime_seconds = $LifetimeSeconds
        })
        $script:sessionIdleEndUtc = [DateTime]::UtcNow.AddSeconds($IdleTimeoutSeconds)
        $nextRequestId = 1
        while ($true) {
            $message = Read-SessionMessage -Idle
            $type = Get-SessionMessageType -Message $message
            if ($type -ceq 'close') {
                Assert-SessionMessageFields -Message $message -Names @('type') -Description 'The session close'
                try { Write-SessionMessage -TimeoutSeconds 5 -Message ([ordered]@{ type = 'closed'; reason = 'client_closed' }) } catch { }
                throw (New-SessionException -Reason 'client_closed' -Message 'The dashboard closed the restore session.')
            }
            if ($type -cne 'request') {
                throw (New-SessionException -Reason 'schema_violation' -Message 'A restore-session message has an unknown type.')
            }
            $request = ConvertTo-SessionRequest -Message $message -ExpectedRequestId $nextRequestId
            $nextRequestId++
            Invoke-SessionRequest -Request $request
            if ($request.Action -ceq 'restore') {
                # At most one restore: the session ends after it, whatever its outcome.
                throw (New-SessionException -Reason 'restore_completed' -Message 'The restore session served its one restore.')
            }
            $script:sessionIdleEndUtc = [DateTime]::UtcNow.AddSeconds($IdleTimeoutSeconds)
        }
    }
    catch {
        $coded = $_.Exception.Data['restore_session_reason']
        if ($coded -is [string] -and $coded) {
            $reason = $coded
            $detail = $_.Exception.Message
        }
        elseif ($isTestMode) {
            [Console]::Error.WriteLine($_.Exception.Message)
            [Console]::Error.WriteLine($_.ScriptStackTrace)
        }
    }
    $normal = $reason -cin $sessionNormalEnds
    if ($null -ne $sessionPipe) {
        if ($reason -cin @('idle_timeout', 'lifetime_expired', 'config_changed', 'config_unreadable', 'client_exited')) {
            # A client that is not reading finds this on its next request and asks for a new session.
            try { Write-SessionMessage -TimeoutSeconds 2 -Message ([ordered]@{ type = 'closed'; reason = $reason }) } catch { }
        }
        try { $sessionPipe.Dispose() } catch { }
        $script:sessionPipe = $null
    }
    try { Write-SessionRecord -Reason $reason -Ok $normal -Detail $detail } catch { }
    if ($isTestMode) { [Console]::Error.WriteLine('restore session ended: ' + $reason) }
    $script:sessionExitCode = $(if ($normal) { 0 } else { 1 })
}

if ($PSCmdlet.ParameterSetName -ceq 'Session') {
    $sessionExitCode = 1
    $null = Invoke-RestoreSession
    exit $sessionExitCode
}

try {
    Assert-ProtectedManagerHost
    Initialize-RestoreRequest -RequestAction $Action -RequestSnapshotId $SnapshotId -RequestTreePath $TreePath `
        -RequestTarget $Target -RequestIncludesBase64 $IncludesBase64 -RequestAllowLegacyUnbound $AllowLegacyUnbound
    $expectedDigestPayload = @(
        $requestDomain, $currentSid, $requestAction, $ExpectedConfigSha256, $ExpectedPlanId,
        $ExpectedConfigGeneration.ToString([Globalization.CultureInfo]::InvariantCulture),
        $AllowLegacyUnbound, $canonicalSnapshotId, $canonicalTreePath, $canonicalTarget, $includesHash, $RequestNonce
    ) -join "`n"
    if ((Get-Sha256Hex -Bytes $utf8.GetBytes($expectedDigestPayload)) -cne $RequestDigest) {
        throw 'The restore-manager request digest does not match the requested operation.'
    }

    Assert-NormalDirectoryChain -Directory $installRoot
    Assert-NormalDirectoryChain -Directory $stateRoot
    Initialize-ResultChannel
    $null = Invoke-RestoreOperation
    $outcome = $operationOutcome
    Write-FinalResult -Ok $outcome.Ok -Payload $outcome.Payload -ErrorMessage $outcome.ErrorMessage -BackendExitCode $outcome.BackendExitCode
    exit $outcome.ExitCode
}
catch {
    $failure = $_.Exception.Message
    try { Write-ProgressResult -Stage failed -Message (Get-SanitizedError -Message $failure) -Percent 0 } catch { }
    try { Write-FinalResult -Ok $false -Payload $null -ErrorMessage $failure -BackendExitCode -1 } catch { }
    if ($isTestMode) { [Console]::Error.WriteLine($failure); [Console]::Error.WriteLine($_.ScriptStackTrace) }
    elseif (-not $resultChannelReady) {
        $safeFailure = Get-SanitizedError -Message $failure
        [Console]::Error.WriteLine($safeFailure)
    }
    exit 1
}
