#requires -Version 5.1

# Clean-up of old backups. The dashboard starts this manager through UAC, by fixed path, for one request the person made:
#   -Action configure -Enabled 1 -KeepDaily d -KeepWeekly w -KeepMonthly m   turn clean-up on (or change the counts) and list
#                                                                             what would go; nothing is removed
#   -Action configure -Enabled 0                                              turn it off; nothing is removed
#   -Action preview                                                           list again what would go; nothing is removed
#   -Action apply -ExpectedPreviewSha256 ... -ExpectedRemoveSetSha256 ...
#                 -ExpectedRemoveCount n -ConfirmEarlierChanges 0|1           remove exactly the list the person saw
# Every request is bound to the requesting user's SID, the protected configuration, a fresh nonce and a domain-separated
# digest of all of its fields, and answers in one protected result file. The work runs under the global run lock, so no
# backup, restore step or other protected change runs meanwhile. retention.py does the Restic work; it is the only code
# that removes backups, and only here.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('configure', 'preview', 'apply')]
    [string]$Action,
    # Windows PowerShell's -File binder can drop an empty argument, so an argument that does not belong to the action is
    # left out by the dashboard and defaults to an empty string here, which the digest covers too.
    [string]$Enabled = '',
    [string]$KeepDaily = '',
    [string]$KeepWeekly = '',
    [string]$KeepMonthly = '',
    [string]$ExpectedPreviewSha256 = '',
    [string]$ExpectedRemoveSetSha256 = '',
    [string]$ExpectedRemoveCount = '',
    [string]$ConfirmEarlierChanges = '',
    [Parameter(Mandatory = $true)]
    [string]$ExpectedUserSid,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedConfigSha256,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPlanId,
    [Parameter(Mandatory = $true)]
    [long]$ExpectedConfigGeneration,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$RequestNonce,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$RequestDigest,
    [string]$TestRoot
)

# First, before any command: modules load only from Windows' own folder, never from the person's Documents folder.
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productName = 'ResticBackuper'
$requestDomain = 'ResticBackuper.RetentionRequest.v1'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$isTestMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
$testContainer = $null
if ($isTestMode) {
    $testContainer = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ($testContainer -eq $temporaryRoot -or
        -not $testContainer.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable clean-up manager test root must be below the current-user temporary directory.'
    }
    # The disposable mode needs an explicit -TestRoot AND a copy of this script outside the protected install root, and it
    # refuses an elevated token, which is how every production launch runs.
    $protectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
    $testScript = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { '' } else { [IO.Path]::GetFullPath($PSCommandPath) }
    if ([string]::IsNullOrWhiteSpace($testScript) -or
        [string]::Equals($testScript, $protectedInstallRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $testScript.StartsWith($protectedInstallRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable clean-up manager test mode cannot run from the protected install root.'
    }
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramFiles\$productName")).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramData\$productName")).TrimEnd('\')
}
else {
    $installRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $programDataRoot $productName)).TrimEnd('\')
}
$localNtfsMode = 'local_ntfs'

$managerPath = Join-Path $installRoot 'Manage-Retention.ps1'
$configPath = Join-Path $installRoot 'backup-config.json'
$runtimeManifestPath = Join-Path $installRoot 'runtime-manifest.json'
$retentionPath = Join-Path $installRoot 'retention.py'
$pythonPath = Join-Path $installRoot 'Python\python.exe'
$resticPath = Join-Path $installRoot 'restic.exe'
$lockPath = Join-Path $stateRoot 'run.lock'
$resultRoot = Join-Path $stateRoot 'RetentionManagerResults'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$currentSid = $null
$resultChannelReady = $false
$progressPath = $null
$outcome = $null
$countBounds = @{ daily = @(7, 90); weekly = @(4, 104); monthly = @(6, 120) }
$refusalCodes = @('busy', 'google_drive_not_supported', 'pending_change', 'no_verified_backup', 'last_backup_not_verified',
    'folders_changed', 'change_review_open', 'clock_problem', 'future_dated_backup', 'backup_location_unavailable',
    'policy_inactive', 'preview_mismatch', 'earlier_changes_not_confirmed')

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
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "Required directory does not exist: $Directory"
    }
    $current = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Directory -Force
    while ($null -ne $current) {
        if (-not $current.PSIsContainer -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Directory path contains a reparse point or non-directory component: $($current.FullName)"
        }
        $parent = $current.Parent
        if ($null -eq $parent) { break }
        $current = Microsoft.PowerShell.Management\Get-Item -LiteralPath $parent.FullName -Force
    }
}

function Assert-NormalFile {
    param([string]$File)
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "Required regular file is missing: $File"
    }
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $File -Force
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

function Read-BoundedJsonObject {
    param([string]$File, [long]$MaximumBytes, [string]$Description)
    $item = Assert-NormalFile -File $File
    if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) { throw "$Description has an invalid size." }
    $bytes = [IO.File]::ReadAllBytes($File)
    try { $value = $utf8.GetString($bytes) | Microsoft.PowerShell.Utility\ConvertFrom-Json }
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

function Get-OptionalProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    return $(if ($null -eq $property) { $null } else { $property.Value })
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
    $acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544' -or
        -not $acl.AreAccessRulesProtected) { throw "Protected clean-up result path has an unsafe ACL: $Path" }
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
            $sid -notin $allowed) { throw "Protected clean-up result ACL contains unexpected identity: $sid" }
        if ($sid -notin @('S-1-5-18', 'S-1-5-32-544') -and
            ($rule.FileSystemRights -band $dangerous) -ne 0) {
            throw "Protected clean-up result ACL grants write rights to $sid"
        }
        [void]$seen.Add($sid)
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $UserSid)) {
        if (-not $seen.Contains($sid)) { throw "Protected clean-up result ACL is missing $sid" }
    }
}

function Write-ProtectedJson {
    param([string]$Path, [object]$Value, [switch]$Replace)
    $bytes = $utf8.GetBytes(($Value | Microsoft.PowerShell.Utility\ConvertTo-Json -Depth 10) + "`n")
    if ($bytes.Length -gt 64KB) { throw 'Protected clean-up result exceeds its size limit.' }
    $parent = Split-Path -Parent $Path
    $temporary = Join-Path $parent ('.retention-result-' + [Guid]::NewGuid().ToString('N') + '.tmp')
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
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $resultRoot)) {
        if ($isTestMode) { [void][IO.Directory]::CreateDirectory($resultRoot) }
        else { [void][IO.Directory]::CreateDirectory($resultRoot, (New-ResultDirectorySecurity -UserSid $currentSid)) }
    }
    Assert-NormalDirectoryChain -Directory $resultRoot
    Assert-ResultAcl -Path $resultRoot -UserSid $currentSid
    foreach ($entry in Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $resultRoot -Force) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry.Name -notmatch '^[0-9a-f]{64}(\.json|\.json\.progress\.json)$') {
            throw "Protected clean-up result directory contains an unexpected entry: $($entry.Name)"
        }
        Assert-ResultAcl -Path $entry.FullName -UserSid $currentSid
        if ($entry.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7)) { [IO.File]::Delete($entry.FullName) }
    }
    $expectedResult = Join-Path $resultRoot "$RequestNonce.json"
    if (-not (Test-PathEqual -Left ([IO.Path]::GetFullPath($ResultPath)) -Right $expectedResult)) {
        throw 'The clean-up manager result path does not match its request nonce.'
    }
    $script:progressPath = $expectedResult + '.progress.json'
    foreach ($candidate in @($expectedResult, $progressPath)) {
        if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
            throw "Protected clean-up result target already exists: $candidate"
        }
    }
    $script:resultChannelReady = $true
}

function Get-SanitizedError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return 'The protected clean-up step failed.' }
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $Message.ToCharArray()) {
        if (-not [char]::IsControl($character) -or $character -eq "`t") { [void]$builder.Append($character) }
        if ($builder.Length -ge 1000) { break }
    }
    $result = $builder.ToString().Trim()
    if ($result -match '(?i)(password|RESTIC_|dpapi)') {
        return 'The protected clean-up step failed without exposing credential details.'
    }
    return $(if ($result) { $result } else { 'The protected clean-up step failed.' })
}

function Write-ProgressResult {
    # Where an apply has got to, for the dashboard: replaced in place, with the result's protected permissions.
    param([string]$Stage, [string]$Message, [object]$Percent, [object]$Count)
    if (-not $resultChannelReady) { return }
    $document = [ordered]@{
        schema_version = 1; request_nonce = $RequestNonce; request_digest = $RequestDigest
        request_user_sid = $currentSid; action = $Action; stage = $Stage; message = $Message
        percent = $Percent; count = $Count; updated_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-ProtectedJson -Path $progressPath -Value $document -Replace:([IO.File]::Exists($progressPath))
}

function Set-Outcome {
    param(
        [string]$State,
        [int]$ExitCode,
        [string]$RefusalCode = $null,
        [object]$Values = $null,
        [string]$ErrorMessage = $null,
        [int]$BackendExitCode = 0
    )
    $script:outcome = [pscustomobject]@{
        State = $State; ExitCode = $ExitCode; RefusalCode = $RefusalCode; Values = $Values
        ErrorMessage = $ErrorMessage; BackendExitCode = $BackendExitCode
    }
}

function Get-OutcomeValue {
    param([string]$Name)
    if ($null -eq $outcome -or $null -eq $outcome.Values) { return $null }
    if ($outcome.Values -is [Collections.IDictionary]) {
        return $(if ($outcome.Values.Contains($Name)) { $outcome.Values[$Name] } else { $null })
    }
    return Get-OptionalProperty -Object $outcome.Values -Name $Name
}

function New-FinalResultDocument {
    $ok = $null -ne $outcome -and $outcome.ExitCode -eq 0
    $state = if ($null -eq $outcome) { 'failed' } else { $outcome.State }
    return [ordered]@{
        schema_version = 1; request_nonce = $RequestNonce; request_digest = $RequestDigest
        request_user_sid = $currentSid; action = $Action; expected_config_sha256 = $ExpectedConfigSha256
        plan_id = $ExpectedPlanId; config_generation = $ExpectedConfigGeneration
        enabled = $Enabled; keep_daily = $KeepDaily; keep_weekly = $KeepWeekly; keep_monthly = $KeepMonthly
        expected_preview_sha256 = $ExpectedPreviewSha256; expected_remove_set_sha256 = $ExpectedRemoveSetSha256
        expected_remove_count = $ExpectedRemoveCount; confirm_earlier_changes = $ConfirmEarlierChanges
        ok = $ok; state = $state
        refusal_code = if ($null -ne $outcome -and $outcome.RefusalCode) { $outcome.RefusalCode } else { $null }
        policy_sha256 = Get-OutcomeValue -Name 'policy_sha256'
        preview_sha256 = Get-OutcomeValue -Name 'preview_sha256'
        preview_state = Get-OutcomeValue -Name 'preview_state'
        remove_count = Get-OutcomeValue -Name 'remove_count'
        removed_count = Get-OutcomeValue -Name 'removed_count'
        removed_set_sha256 = Get-OutcomeValue -Name 'removed_set_sha256'
        removal_unverified = Get-OutcomeValue -Name 'removal_unverified'
        kept_count = Get-OutcomeValue -Name 'kept_count'
        prune_completed = Get-OutcomeValue -Name 'prune_completed'
        check_completed = Get-OutcomeValue -Name 'check_completed'
        prune_mode = Get-OutcomeValue -Name 'prune_mode'
        history_recorded = Get-OutcomeValue -Name 'history_recorded'
        backend_exit_code = if ($null -eq $outcome) { -1 } else { $outcome.BackendExitCode }
        error = if ($ok) { $null } elseif ($null -ne $outcome -and $outcome.ErrorMessage) {
            Get-SanitizedError -Message $outcome.ErrorMessage
        } elseif ($state -eq 'failed') { 'The protected clean-up step failed.' } else { $null }
        finished_utc = [DateTime]::UtcNow.ToString('o')
    }
}

function Write-FinalResult {
    if (-not $resultChannelReady) { return }
    $document = New-FinalResultDocument
    Write-ProtectedJson -Path ([IO.Path]::GetFullPath($ResultPath)) -Value $document
    if ($isTestMode) { $document | Microsoft.PowerShell.Utility\ConvertTo-Json -Compress -Depth 10 }
}

function New-RunLockSecurity {
    # run.lock is the lock every backup and protected change takes, and any handle that can read a file can lock its
    # bytes. Only Administrators and SYSTEM may open it, so a program running with standard rights cannot hold it.
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sidText),
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
    }
    return $security
}

function Test-RunLockSecurity {
    param([Security.AccessControl.FileSystemSecurity]$Acl)
    $owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier])
    if (-not $Acl.AreAccessRulesProtected -or $null -eq $owner -or $owner.Value -ne 'S-1-5-32-544') { return $false }
    $seen = [Collections.Generic.HashSet[string]]::new()
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
            -not $seen.Add($rule.IdentityReference.Value)) {
            return $false
        }
    }
    return $seen.SetEquals([string[]]@('S-1-5-18', 'S-1-5-32-544'))
}

function Protect-RunLock {
    param([string]$File, [Security.AccessControl.FileSecurity]$Policy)
    $sections = [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Access
    if (Test-RunLockSecurity -Acl ([IO.File]::GetAccessControl($File, $sections))) { return }
    [IO.File]::SetAccessControl($File, $Policy)
    if (-not (Test-RunLockSecurity -Acl ([IO.File]::GetAccessControl($File, $sections)))) {
        throw "The run lock $File could not be limited to Administrators and SYSTEM. An administrator can delete it so " +
            'the next backup creates it again.'
    }
}

function Open-RunLockFile {
    param([string]$File)
    $security = New-RunLockSecurity
    if (-not (Test-RunLockSecurity -Acl $security)) { throw 'The run lock permission policy is invalid.' }
    if ($isTestMode) {
        return [IO.File]::Open($File, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    }
    try {
        $stream = [IO.FileStream]::new($File, [IO.FileMode]::OpenOrCreate,
            ([Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Write),
            [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::None, $security)
    }
    catch {
        $openFailure = $_
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $File -PathType Leaf) {
            Protect-RunLock -File $File -Policy (New-RunLockSecurity)
        }
        throw $openFailure
    }
    try { Protect-RunLock -File $File -Policy $security }
    catch { $stream.Dispose(); throw }
    return $stream
}

function Enter-RunLock {
    # Null when another backup or protected operation holds it: the request is then refused as busy, and nothing runs.
    $stream = Open-RunLockFile -File $lockPath
    try {
        if ($stream.Length -eq 0) { $stream.WriteByte(0); $stream.Flush($true) }
        $stream.Lock(0, 1)
        return $stream
    }
    catch { $stream.Dispose(); return $null }
}

function Exit-RunLock {
    param([IO.FileStream]$Stream)
    if ($null -eq $Stream) { return }
    try { $Stream.Unlock(0, 1) } finally { $Stream.Dispose() }
}

function Test-PendingJournal {
    # Any *.journal.json (a file, a folder or a link) is an unfinished protected change: a folder change, a move of the
    # backup location, a plan migration, a key rotation, or one a later version adds. Nothing is cleaned up meanwhile.
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($stateRoot)) {
        if ([IO.Path]::GetFileName($entry).EndsWith('.journal.json', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-ValidatedConfiguration {
    # The protected configuration the request was made for. -Light (turning clean-up off) checks only what binds the
    # request, so that a backup drive that is unplugged cannot keep clean-up on.
    param([switch]$Light)
    $loaded = Read-BoundedJsonObject -File $configPath -MaximumBytes 1MB -Description 'Protected backup configuration'
    if ((Get-Sha256Hex -Bytes $loaded.Bytes) -cne $ExpectedConfigSha256) {
        throw 'The protected configuration changed after the clean-up request was prepared.'
    }
    $config = $loaded.Json
    if ($config.schema_version -ne 1) { throw 'Unsupported protected configuration schema.' }
    $parsedPlan = [Guid]::Empty
    if ($config.plan_id -isnot [string] -or
        -not [Guid]::TryParseExact([string]$config.plan_id, 'D', [ref]$parsedPlan) -or
        $parsedPlan.ToString('D') -cne $ExpectedPlanId -or
        [string]$config.plan_id -cne $ExpectedPlanId) {
        throw 'The protected clean-up request names another backup plan.'
    }
    if ($config.config_generation.GetType().FullName -notin @('System.Int32', 'System.Int64') -or
        [long]$config.config_generation -ne $ExpectedConfigGeneration -or $ExpectedConfigGeneration -le 0) {
        throw 'The protected clean-up request names another configuration generation.'
    }
    foreach ($name in @('repository', 'repository_volume_serial', 'restic_executable', 'python_executable', 'state_directory')) {
        [void](Get-RequiredProperty -Object $config -Name $name -Description 'Protected backup configuration')
    }
    $configuredState = Get-CanonicalLocalPath -Value ([string]$config.state_directory)
    $configuredRestic = Get-CanonicalLocalPath -Value ([string]$config.restic_executable)
    $configuredPython = Get-CanonicalLocalPath -Value ([string]$config.python_executable)
    if (-not (Test-PathEqual -Left $configuredState -Right $stateRoot) -or
        -not (Test-PathEqual -Left $configuredRestic -Right $resticPath) -or
        -not (Test-PathEqual -Left $configuredPython -Right $pythonPath)) {
        throw 'The protected configuration names an unexpected runtime or state path.'
    }
    $modeProperty = $config.PSObject.Properties['repository_storage_mode']
    $mode = if ($null -eq $modeProperty) { $localNtfsMode } else { [string]$modeProperty.Value }
    foreach ($directory in @($installRoot, $stateRoot)) { Assert-NormalDirectoryChain -Directory $directory }
    foreach ($file in @($managerPath, $retentionPath, $pythonPath, $resticPath, $configPath)) {
        [void](Assert-NormalFile -File $file)
    }
    $repository = Get-CanonicalLocalPath -Value ([string]$config.repository)
    $locationAvailable = $true
    if (-not $Light -and $mode -eq $localNtfsMode) {
        if ((Test-IsWithin -Candidate $repository -Parent $stateRoot) -or (Test-IsWithin -Candidate $stateRoot -Parent $repository) -or
            (Test-IsWithin -Candidate $repository -Parent $installRoot) -or (Test-IsWithin -Candidate $installRoot -Parent $repository)) {
            throw 'The backup location overlaps the protected runtime or state.'
        }
        # An unplugged or missing backup drive is a reason to wait, not a failure: the request is refused before anything runs.
        # A location that is there is checked in full, and anything unusual about it still stops the request.
        $locationAvailable = (Test-BackupLocationPresent -Repository $repository)
        if ($locationAvailable) {
            Assert-NormalDirectoryChain -Directory $repository
            Assert-NtfsLocalPath -Path $repository -Label 'The backup location'
            [void](Assert-NormalFile -File (Join-Path $repository 'config'))
        }
    }
    return [pscustomobject]@{
        Json = $config; Repository = $repository; RepositoryStorageMode = $mode; LocationAvailable = $locationAvailable
    }
}

function Test-BackupLocationPresent {
    # The backup location's folder and its config file exist. Never throws: a drive that is not there answers false.
    param([string]$Repository)
    try {
        return ([IO.Directory]::Exists($Repository) -and [IO.File]::Exists((Join-Path $Repository 'config')))
    }
    catch {
        return $false
    }
}

function Assert-RuntimeManifest {
    $loaded = Read-BoundedJsonObject -File $runtimeManifestPath -MaximumBytes 8MB -Description 'Protected runtime manifest'
    $manifest = $loaded.Json
    $records = @($manifest.files)
    if ($manifest.schema_version -ne 1 -or [long]$manifest.file_count -ne $records.Count) {
        throw 'Protected runtime manifest header is invalid.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $checkedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
        $directory = [IO.Path]::GetDirectoryName($file)
        if ($checkedDirectories.Add($directory)) { Assert-NormalDirectoryChain -Directory $directory }
        $item = Assert-NormalFile -File $file
        if ([long]$record.bytes -ne $item.Length -or
            -not [string]::Equals([string]$record.sha256, (Get-FileSha256Hex -File $file), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Protected runtime manifest mismatch: $relative"
        }
    }
    foreach ($required in @('backup-config.json', 'Manage-Retention.ps1', 'retention.py', 'restic_common.py', 'secret_store.py',
        'restic.exe', 'Python\python.exe')) {
        if (-not $seen.Contains($required)) { throw "Protected runtime manifest is missing: $required" }
    }
    # The installer's two task evidence files are the only files beside the manifest that it does not list.
    $actualFiles = @(
        Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force |
            Microsoft.PowerShell.Core\Where-Object Name -notin @(
                'runtime-manifest.json',
                'scheduled-task.xml',
                'google-drive-verification-task.xml'
            )
    )
    if ($actualFiles.Count -ne $records.Count) {
        throw 'Protected runtime contains unmanifested or missing files.'
    }
    foreach ($file in $actualFiles) {
        if ($checkedDirectories.Add($file.DirectoryName)) { Assert-NormalDirectoryChain -Directory $file.DirectoryName }
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

function New-RetentionBackendEnvironment {
    # The complete environment of retention.py. This manager runs elevated, but Windows builds its environment from the
    # user's profile (HKCU\Environment included), which the user can change without approval, and Python and the Restic
    # it starts read settings from it. So nothing is inherited: the Windows values come from the Windows API. Restic's own
    # children get a further allow-listed environment from restic_common.restic_child_environment.
    $system = [Environment]::SystemDirectory
    $windows = [IO.Directory]::GetParent($system).FullName
    $environment = [ordered]@{
        SystemRoot = $windows; windir = $windows; SystemDrive = [IO.Path]::GetPathRoot($windows).TrimEnd('\')
        ComSpec = (Join-Path $system 'cmd.exe')
        PATH = (@($system, $windows, (Join-Path $system 'Wbem'), (Join-Path $system 'WindowsPowerShell\v1.0')) -join ';')
        PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'; OS = 'Windows_NT'
        NUMBER_OF_PROCESSORS = [string][Environment]::ProcessorCount
    }
    $architecture = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Process')
    if ($architecture -cin @('AMD64', 'x86', 'ARM64')) { $environment['PROCESSOR_ARCHITECTURE'] = $architecture }
    if ($isTestMode) {
        # Only the disposable test mode: retention.py checks that its test folder is below the user's temporary folder.
        $temporary = [IO.Path]::GetTempPath().TrimEnd('\')
        $environment['TEMP'] = $temporary; $environment['TMP'] = $temporary
    }
    return $environment
}

function Invoke-RetentionStep {
    # One step of retention.py, which prints one JSON object. Its exit code must agree with the state it reports.
    param([string]$Step, [string[]]$Extra = @())
    foreach ($value in $Extra) {
        if ([string]::IsNullOrEmpty($value)) { throw 'The clean-up step was prepared with an empty argument.' }
    }
    $arguments = @('-I', '-S', '-B', $retentionPath, '--config', $configPath, '--expected-config-sha256', $ExpectedConfigSha256,
        '--request-nonce', $RequestNonce, '--step', $Step) + $Extra
    if ($isTestMode) { $arguments += @('--test-root', $testContainer) }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $pythonPath
    $start.Arguments = (($arguments | Microsoft.PowerShell.Core\ForEach-Object { ConvertTo-WindowsArgument -Value ([string]$_) }) -join ' ')
    $start.WorkingDirectory = $installRoot
    $start.EnvironmentVariables.Clear()
    $environment = New-RetentionBackendEnvironment
    foreach ($name in @($environment.Keys)) { $start.EnvironmentVariables[[string]$name] = [string]$environment[$name] }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Windows did not start the protected clean-up helper.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($isTestMode -and $stderr) { [Console]::Error.WriteLine($stderr) }
        if ($utf8.GetByteCount($stdout) -gt 1MB -or $utf8.GetByteCount($stderr) -gt 1MB) {
            throw 'The protected clean-up helper returned more output than the manager accepts.'
        }
        try { $value = $stdout | Microsoft.PowerShell.Utility\ConvertFrom-Json }
        catch { throw "The clean-up step $Step returned invalid JSON." }
        if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
            throw "The clean-up step $Step did not return one JSON object."
        }
        $state = [string](Get-OptionalProperty -Object $value -Name 'state')
        $expectedExit = switch ($state) {
            'refused' { 2 } 'preview_changed' { 3 } 'partial' { 4 } 'failed' { 1 } 'prune_failed' { 1 } 'check_failed' { 1 }
            'kept_backup_missing' { 1 } default { 0 }
        }
        if ([string]::IsNullOrEmpty($state) -or $process.ExitCode -ne $expectedExit) {
            throw "The clean-up step $Step answered $state with exit code $($process.ExitCode)."
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; State = $state; Value = $value }
    }
    finally { $process.Dispose() }
}

function Assert-ProtectedManagerHost {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'Clean-up of old backups requires 64-bit Windows PowerShell.'
    }
    if ($isTestMode) {
        if (Test-Administrator) { throw 'Disposable clean-up manager tests must run without an elevated token.' }
    }
    elseif (-not (Test-Administrator)) { throw 'Clean-up of old backups must run elevated.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:currentSid = $identity.User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or
        -not [string]::Equals($ExpectedUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approve clean-up with the same Windows account that asked for it.'
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
        -not (Test-PathEqual -Left ([IO.Path]::GetFullPath($PSCommandPath)) -Right $managerPath)) {
        throw 'Clean-up of old backups must run from the installed manager script.'
    }
    $parsedPlan = [Guid]::Empty
    if (-not [Guid]::TryParseExact($ExpectedPlanId, 'D', [ref]$parsedPlan) -or
        $parsedPlan.ToString('D') -cne $ExpectedPlanId -or $ExpectedConfigGeneration -le 0) {
        throw 'The clean-up request has an invalid plan identity or generation.'
    }
}

function Assert-Count {
    param([string]$Value, [string]$Kind)
    $bounds = $countBounds[$Kind]
    if ($Value -cnotmatch '^[1-9][0-9]{0,2}$' -or [int]$Value -lt $bounds[0] -or [int]$Value -gt $bounds[1]) {
        throw "The number of $Kind backups to keep must be a whole number from $($bounds[0]) to $($bounds[1])."
    }
}

function Assert-RetentionRequestShape {
    # Which arguments belong to which action. One that does not belong is a refusal, never ignored.
    foreach ($value in @($RequestNonce, $RequestDigest, $ExpectedConfigSha256)) {
        if ($value -cnotmatch '^[0-9a-f]{64}$') { throw 'The clean-up request has an invalid binding.' }
    }
    $countsGiven = @($KeepDaily, $KeepWeekly, $KeepMonthly) -ne ''
    $applyGiven = @($ExpectedPreviewSha256, $ExpectedRemoveSetSha256, $ExpectedRemoveCount, $ConfirmEarlierChanges) -ne ''
    switch ($Action) {
        'configure' {
            if ($Enabled -cnotin @('0', '1')) { throw 'Say whether clean-up is turned on or off.' }
            if ($applyGiven.Count -ne 0) { throw 'Turning clean-up on or off takes no list to remove.' }
            if ($Enabled -ceq '1') {
                Assert-Count -Value $KeepDaily -Kind 'daily'
                Assert-Count -Value $KeepWeekly -Kind 'weekly'
                Assert-Count -Value $KeepMonthly -Kind 'monthly'
            }
            elseif ($countsGiven.Count -ne 0) { throw 'Turning clean-up off takes no counts.' }
        }
        'preview' {
            if ($Enabled -ne '' -or $countsGiven.Count -ne 0 -or $applyGiven.Count -ne 0) {
                throw 'Listing old backups takes no other arguments.'
            }
        }
        'apply' {
            if ($Enabled -ne '' -or $countsGiven.Count -ne 0) { throw 'Removing old backups does not change the setting.' }
            if ($ExpectedPreviewSha256 -cnotmatch '^[0-9a-f]{64}$' -or $ExpectedRemoveSetSha256 -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Removing old backups needs the exact list that was confirmed.'
            }
            if ($ExpectedRemoveCount -cnotmatch '^(0|[1-9][0-9]{0,4})$' -or [int]$ExpectedRemoveCount -gt 10000) {
                throw 'The number of backups to remove is invalid.'
            }
            if ($ConfirmEarlierChanges -cnotin @('0', '1')) { throw 'Say whether the files were checked.' }
        }
    }
}

function Get-RetentionRequestDigest {
    $payload = @(
        $requestDomain, $currentSid, $Action, $ExpectedConfigSha256, $ExpectedPlanId,
        $ExpectedConfigGeneration.ToString([Globalization.CultureInfo]::InvariantCulture),
        $Enabled, $KeepDaily, $KeepWeekly, $KeepMonthly,
        $ExpectedPreviewSha256, $ExpectedRemoveSetSha256, $ExpectedRemoveCount, $ConfirmEarlierChanges, $RequestNonce
    ) -join "`n"
    return Get-Sha256Hex -Bytes $utf8.GetBytes($payload)
}

function Get-StepValue {
    param([object]$Step, [string]$Name)
    return Get-OptionalProperty -Object $Step.Value -Name $Name
}

function Invoke-RetentionApply {
    $startedUtc = [DateTime]::UtcNow.ToString('o')
    $count = [int]$ExpectedRemoveCount
    Write-ProgressResult -Stage 'checking' -Message 'Checking the list against the backups that are there now.' -Percent 15 -Count $count
    $forget = Invoke-RetentionStep -Step 'apply-forget' -Extra @(
        '--expected-preview-sha256', $ExpectedPreviewSha256, '--expected-remove-set-sha256', $ExpectedRemoveSetSha256,
        '--expected-remove-count', $ExpectedRemoveCount, '--confirm-earlier-changes', $ConfirmEarlierChanges)
    switch ($forget.State) {
        'refused' {
            $code = [string](Get-StepValue -Step $forget -Name 'refusal_code')
            if ($code -cnotin $refusalCodes) { throw 'The clean-up helper refused for an unknown reason.' }
            Write-ProgressResult -Stage 'failed' -Message 'Nothing was removed.' -Percent 0 -Count $count
            Set-Outcome -State 'refused' -ExitCode 2 -RefusalCode $code -BackendExitCode $forget.ExitCode
            return
        }
        'preview_changed' {
            Write-ProgressResult -Stage 'failed' -Message 'The list changed. Nothing was removed.' -Percent 0 -Count $count
            Set-Outcome -State 'preview_changed' -ExitCode 3 -Values $forget.Value -BackendExitCode $forget.ExitCode
            return
        }
        'failed' {
            throw ('The clean-up helper stopped before removing anything: ' + [string](Get-StepValue -Step $forget -Name 'error'))
        }
    }
    if ($forget.State -cnotin @('removed', 'partial', 'nothing_to_remove', 'kept_backup_missing')) {
        throw "The clean-up helper answered an unknown state: $($forget.State)"
    }
    $removedCount = [int](Get-StepValue -Step $forget -Name 'removed_count')
    $removedSet = [string](Get-StepValue -Step $forget -Name 'removed_set_sha256')
    if ($removedSet -cnotmatch '^[0-9a-f]{64}$' -or $removedCount -lt 0 -or $removedCount -gt $count) {
        throw 'The clean-up helper reported an invalid removed list.'
    }
    $freeBefore = Get-StepValue -Step $forget -Name 'free_bytes_before'
    $values = [ordered]@{
        removed_count = $removedCount; removed_set_sha256 = $removedSet; remove_count = $count
        kept_count = Get-StepValue -Step $forget -Name 'kept_count'
        prune_completed = $false; check_completed = $false; prune_mode = 'none'; history_recorded = $false
        preview_sha256 = $null; preview_state = $null; policy_sha256 = $null
    }
    $unverified = [bool](Get-StepValue -Step $forget -Name 'removal_unverified')
    $values.removal_unverified = $unverified
    $needsPrune = -not $unverified -and ($removedCount -gt 0 -or ($forget.State -ceq 'nothing_to_remove' -and
        [bool](Get-StepValue -Step $forget -Name 'prune_pending')))
    $finalState = $forget.State
    if ($unverified) {
        # The backups could not be listed again after removing: nothing more runs; the next clean-up frees the space.
        $finalState = 'partial'
    }
    elseif ($forget.State -ceq 'kept_backup_missing') {
        # A backup that should have stayed is gone: nothing more is done, and the person is sent to the recovery check.
        $finalState = 'check_failed'
    }
    elseif ($needsPrune) {
        Write-ProgressResult -Stage 'freeing' -Message 'Freeing space on the backup location.' -Percent $null -Count $removedCount
        $prune = Invoke-RetentionStep -Step 'apply-prune'
        $values.prune_completed = [bool](Get-StepValue -Step $prune -Name 'prune_completed')
        $values.prune_mode = [string](Get-StepValue -Step $prune -Name 'prune_mode')
        if ($values.prune_completed) {
            Write-ProgressResult -Stage 'verifying' -Message 'Checking the remaining backups.' -Percent 90 -Count $removedCount
            $check = Invoke-RetentionStep -Step 'apply-check'
            $values.check_completed = [bool](Get-StepValue -Step $check -Name 'check_completed')
        }
        if ($forget.State -ceq 'partial') { $finalState = 'partial' }
        elseif (-not $values.prune_completed) { $finalState = 'space_pending' }
        elseif (-not $values.check_completed) { $finalState = 'check_failed' }
        elseif ($forget.State -ceq 'nothing_to_remove') { $finalState = 'nothing_to_remove' }
        else { $finalState = 'removed' }
    }
    $filesConfirmed = if ($ConfirmEarlierChanges -ceq '1') { '1' } else { '0' }
    $recordArguments = @('--outcome', $finalState, '--started-utc', $startedUtc,
        '--confirmed-count', $ExpectedRemoveCount, '--removed-count', [string]$removedCount,
        '--removed-set-sha256', $removedSet,
        '--prune-completed', $(if ($values.prune_completed) { '1' } else { '0' }),
        '--check-completed', $(if ($values.check_completed) { '1' } else { '0' }),
        '--prune-mode', $(if ($values.prune_mode -cin @('standard', 'unused_only')) { $values.prune_mode } else { 'none' }),
        '--files-confirmed', $filesConfirmed)
    if ($null -ne $freeBefore) { $recordArguments += @('--free-bytes-before', [string][long]$freeBefore) }
    try {
        $record = Invoke-RetentionStep -Step 'apply-record' -Extra $recordArguments
        $values.history_recorded = $record.State -ceq 'recorded'
        $values.preview_sha256 = Get-StepValue -Step $record -Name 'preview_sha256'
        $values.preview_state = Get-StepValue -Step $record -Name 'preview_state'
    }
    catch { $values.history_recorded = $false }
    $exitCode = switch ($finalState) {
        'removed' { 0 } 'nothing_to_remove' { 0 } 'partial' { 4 } 'space_pending' { 5 } 'check_failed' { 6 } default { 1 }
    }
    Write-ProgressResult -Stage $(if ($exitCode -eq 0) { 'complete' } else { 'failed' }) -Message 'Clean-up finished.' `
        -Percent $(if ($exitCode -eq 0) { 100 } else { 0 }) -Count $removedCount
    Set-Outcome -State $finalState -ExitCode $exitCode -Values $values -BackendExitCode $forget.ExitCode
}

function Invoke-RetentionOperation {
    # The protected work of one validated request, under the global run lock. The outcome is left in $outcome; the run lock
    # is released before this returns.
    $lockStream = $null
    try {
        Write-ProgressResult -Stage 'preflight' -Message 'Checking the backup plan.' -Percent 5 -Count $null
        $lockStream = Enter-RunLock
        if ($null -eq $lockStream) {
            Set-Outcome -State 'refused' -ExitCode 2 -RefusalCode 'busy'
            return
        }
        $disabling = $Action -ceq 'configure' -and $Enabled -ceq '0'
        $configuration = Get-ValidatedConfiguration -Light:$disabling
        if (-not $disabling) {
            # Turning clean-up off is the safe direction: neither a Google Drive backup location nor a pending journal stops it.
            if ($configuration.RepositoryStorageMode -cne $localNtfsMode) {
                Set-Outcome -State 'refused' -ExitCode 2 -RefusalCode 'google_drive_not_supported'
                return
            }
            if (Test-PendingJournal) {
                Set-Outcome -State 'refused' -ExitCode 2 -RefusalCode 'pending_change'
                return
            }
            if (-not $configuration.LocationAvailable) {
                Set-Outcome -State 'refused' -ExitCode 2 -RefusalCode 'backup_location_unavailable'
                return
            }
        }
        Assert-RuntimeManifest
        if ($Action -ceq 'apply') {
            Invoke-RetentionApply
            return
        }
        $extra = [string[]]@()
        if ($disabling) { $extra = [string[]]@('--enabled', '0') }
        elseif ($Action -ceq 'configure') {
            $extra = [string[]]@('--enabled', '1', '--keep-daily', $KeepDaily, '--keep-weekly', $KeepWeekly,
                '--keep-monthly', $KeepMonthly)
        }
        $step = Invoke-RetentionStep -Step $(if ($Action -ceq 'preview') { 'preview' } else { 'configure' }) -Extra $extra
        $expected = if ($Action -ceq 'preview') { 'previewed' } elseif ($disabling) { 'disabled' } else { 'configured' }
        if ($step.State -ceq 'refused') {
            $code = [string](Get-StepValue -Step $step -Name 'refusal_code')
            if ($code -cnotin $refusalCodes) { throw 'The clean-up helper refused for an unknown reason.' }
            Set-Outcome -State 'refused' -ExitCode 2 -RefusalCode $code -BackendExitCode $step.ExitCode
            return
        }
        if ($step.State -cne $expected) {
            throw ('The clean-up helper did not finish: ' + [string](Get-StepValue -Step $step -Name 'error'))
        }
        Write-ProgressResult -Stage 'complete' -Message 'Done.' -Percent 100 -Count $null
        Set-Outcome -State $expected -ExitCode 0 -Values $step.Value -BackendExitCode $step.ExitCode
    }
    catch {
        $failure = $_.Exception.Message
        try { Write-ProgressResult -Stage 'failed' -Message (Get-SanitizedError -Message $failure) -Percent 0 -Count $null } catch { }
        if ($isTestMode) { [Console]::Error.WriteLine($failure); [Console]::Error.WriteLine($_.ScriptStackTrace) }
        Set-Outcome -State 'failed' -ExitCode 1 -ErrorMessage $failure -BackendExitCode -1
    }
    finally {
        if ($null -ne $lockStream) { Exit-RunLock -Stream $lockStream }
    }
}

try {
    Assert-ProtectedManagerHost
    Assert-RetentionRequestShape
    if ((Get-RetentionRequestDigest) -cne $RequestDigest) {
        throw 'The clean-up request digest does not match the requested operation.'
    }
    Assert-NormalDirectoryChain -Directory $installRoot
    Assert-NormalDirectoryChain -Directory $stateRoot
    Initialize-ResultChannel
    Invoke-RetentionOperation
    Write-FinalResult
    exit $outcome.ExitCode
}
catch {
    $failure = $_.Exception.Message
    if ($null -eq $outcome) { Set-Outcome -State 'failed' -ExitCode 1 -ErrorMessage $failure -BackendExitCode -1 }
    try { Write-ProgressResult -Stage 'failed' -Message (Get-SanitizedError -Message $failure) -Percent 0 -Count $null } catch { }
    try { Write-FinalResult } catch { }
    if ($isTestMode) { [Console]::Error.WriteLine($failure); [Console]::Error.WriteLine($_.ScriptStackTrace) }
    elseif (-not $resultChannelReady) { [Console]::Error.WriteLine((Get-SanitizedError -Message $failure)) }
    exit 1
}
