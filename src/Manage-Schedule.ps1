#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Daily', 'SelectedDays')]
    [string]$Cadence,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^(?:[01][0-9]|2[0-3]):[0-5][0-9]$')]
    [string]$Time,
    [AllowEmptyString()]
    [string]$Days = '',
    [Parameter(Mandatory = $true)]
    [ValidateSet('0', '1')]
    [string]$StartWhenAvailable,
    [Parameter(Mandatory = $true)]
    [ValidateSet('0', '1')]
    [string]$WakeToRun,
    [Parameter(Mandatory = $true)]
    [ValidateSet('0', '1')]
    [string]$AllowStartOnBatteries,
    [Parameter(Mandatory = $true)]
    [ValidateSet('0', '1')]
    [string]$StopIfGoingOnBatteries,
    [Parameter(Mandatory = $true)]
    [ValidateSet('0', '1')]
    [string]$Enabled,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedCurrentFingerprint,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedUserSid,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$RequestNonce,
    [string]$ResultPath,
    [string]$TestRoot,
    [ValidateSet('None', 'Register', 'Verify', 'RollbackRegister', 'RollbackVerify')]
    [string]$TestFailure = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productName = 'ResticBackuper'
$taskName = 'ResticBackuper'
$taskPath = '\'
$trustedModuleRoot = [IO.Path]::Combine(
    [Environment]::SystemDirectory,
    'WindowsPowerShell',
    'v1.0',
    'Modules'
)
$env:PSModulePath = $trustedModuleRoot
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$isTestMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
if ($isTestMode) {
    $testContainer = [IO.Path]::GetFullPath($TestRoot).TrimEnd('\')
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $temporaryPrefix = $temporaryRoot + '\'
    if ($testContainer -eq $temporaryRoot -or
        -not $testContainer.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable schedule-manager test root must be a child of the current user temporary directory.'
    }
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramFiles\$productName")).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramData\$productName")).TrimEnd('\')
    $taskAdapterRoot = [IO.Path]::GetFullPath((Join-Path $testContainer 'TaskAdapter')).TrimEnd('\')
    $taskAdapterXmlPath = Join-Path $taskAdapterRoot "$taskName.xml"
    $taskAdapterStatePath = Join-Path $taskAdapterRoot "$taskName.state"
}
else {
    $installRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $programDataRoot $productName)).TrimEnd('\')
}

$managerPath = Join-Path $installRoot 'Manage-Schedule.ps1'
$launcherPath = Join-Path $installRoot 'ResticBackuperTaskLauncher.exe'
$lockPath = Join-Path $stateRoot 'run.lock'
$resultRoot = Join-Path $stateRoot 'ScheduleManagerResults'
$lockStream = $null
$resultChannelReady = $false
$requestDigest = $null
$currentSid = $null
$installedFingerprint = $null
$changed = $false
$rollbackPerformed = $false
$rollbackVerified = $false
$registerAttemptCount = 0
$canonicalDayOrder = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
$dayElementNames = [ordered]@{
    Sun = 'Sunday'
    Mon = 'Monday'
    Tue = 'Tuesday'
    Wed = 'Wednesday'
    Thu = 'Thursday'
    Fri = 'Friday'
    Sat = 'Saturday'
}
$taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PathEqual {
    param([string]$Left, [string]$Right)
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
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
        if ($null -eq $parent) { break }
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

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-FlagBoolean {
    param([string]$Value)
    return $Value -eq '1'
}

function ConvertTo-FlagText {
    param([bool]$Value)
    if ($Value) { return '1' }
    return '0'
}

function ConvertTo-XmlBooleanText {
    param([bool]$Value)
    if ($Value) { return 'true' }
    return 'false'
}

function Get-CanonicalRequestedDays {
    param([string]$Value, [string]$RequestedCadence)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        foreach ($rawToken in $Value.Split(',')) {
            $token = $rawToken.Trim()
            $match = @($canonicalDayOrder | Where-Object {
                [string]::Equals($_, $token, [StringComparison]::OrdinalIgnoreCase)
            })
            if ($match.Count -ne 1) {
                throw "Unknown selected-day token: $token"
            }
            if (-not $seen.Add([string]$match[0])) {
                throw "Selected-day token is duplicated: $token"
            }
        }
    }
    $ordered = @($canonicalDayOrder | Where-Object { $seen.Contains($_) })
    if ($RequestedCadence -eq 'Daily' -and $ordered.Count -ne 0) {
        throw 'A daily schedule must not include selected days.'
    }
    if ($RequestedCadence -eq 'SelectedDays' -and $ordered.Count -lt 1) {
        throw 'A selected-days schedule requires at least one day.'
    }
    return [string[]]$ordered
}

function Get-RequestDigest {
    param(
        [string]$Sid,
        [string]$ExpectedFingerprint,
        [string]$RequestedCadence,
        [string]$RequestedTime,
        [string[]]$RequestedDays,
        [bool]$RequestedEnabled,
        [bool]$RequestedStartWhenAvailable,
        [bool]$RequestedWakeToRun,
        [bool]$RequestedAllowStartOnBatteries,
        [bool]$RequestedStopIfGoingOnBatteries,
        [string]$Nonce
    )
    $payload = @(
        'ResticBackuper.ScheduleRequest.v1',
        $Sid,
        'apply',
        $ExpectedFingerprint.ToLowerInvariant(),
        $RequestedCadence.ToLowerInvariant(),
        $RequestedTime,
        ($RequestedDays -join ','),
        (ConvertTo-FlagText -Value $RequestedEnabled),
        (ConvertTo-FlagText -Value $RequestedStartWhenAvailable),
        (ConvertTo-FlagText -Value $RequestedWakeToRun),
        (ConvertTo-FlagText -Value $RequestedAllowStartOnBatteries),
        (ConvertTo-FlagText -Value $RequestedStopIfGoingOnBatteries),
        $Nonce.ToLowerInvariant()
    ) -join "`n"
    return Get-Sha256Hex -Bytes $utf8.GetBytes($payload)
}

function New-ResultDirectorySecurity {
    param([string]$UserSid)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $security.SetOwner($administrators)
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
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $security.SetOwner($administrators)
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

function Assert-ResultSecurityDescriptor {
    param(
        [Security.AccessControl.FileSystemSecurity]$Acl,
        [string]$Path,
        [string]$UserSid
    )
    $owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -or -not $Acl.AreAccessRulesProtected) {
        throw "Protected result path has an unsafe owner or inherited ACL: $Path"
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $UserSid)
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
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed) {
            throw "Protected result path has an unexpected ACL identity: $sid"
        }
        if ($sid -in @('S-1-5-18', 'S-1-5-32-544')) {
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Protected result path lacks full-control rights for $sid"
            }
        }
        elseif (($rule.FileSystemRights -band $dangerous) -ne 0 -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            throw "Protected result path grants unsafe or insufficient rights to $sid"
        }
        [void]$seen.Add($sid)
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $UserSid)) {
        if (-not $seen.Contains($sid)) {
            throw "Protected result path ACL is missing $sid"
        }
    }
}

function Assert-ResultAcl {
    param([string]$Path, [string]$UserSid)
    Assert-ResultSecurityDescriptor -Acl (Get-Acl -LiteralPath $Path) -Path $Path -UserSid $UserSid
}

function Initialize-ResultChannel {
    param([string]$UserSid)
    Assert-NormalDirectoryChain -Directory $stateRoot
    Assert-ResultAcl -Path $stateRoot -UserSid $UserSid
    if (Test-Path -LiteralPath $resultRoot) {
        Assert-NormalDirectoryChain -Directory $resultRoot
        Assert-ResultAcl -Path $resultRoot -UserSid $UserSid
    }
    else {
        [void][IO.Directory]::CreateDirectory(
            $resultRoot,
            (New-ResultDirectorySecurity -UserSid $UserSid)
        )
        Assert-NormalDirectoryChain -Directory $resultRoot
        Assert-ResultAcl -Path $resultRoot -UserSid $UserSid
    }
    $retentionCutoff = [DateTime]::UtcNow.AddDays(-7)
    foreach ($entry in Get-ChildItem -LiteralPath $resultRoot -Force) {
        if ($entry.PSIsContainer -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry.Name -notmatch '^[0-9a-f]{64}\.json$') {
            throw "The protected schedule-result directory contains an unexpected entry: $($entry.Name)"
        }
        Assert-ResultAcl -Path $entry.FullName -UserSid $UserSid
        if ($entry.LastWriteTimeUtc -lt $retentionCutoff) {
            [IO.File]::Delete($entry.FullName)
        }
    }
    $expectedResult = [IO.Path]::Combine($resultRoot, "$RequestNonce.json")
    $actualResult = [IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-PathEqual -Left $actualResult -Right $expectedResult)) {
        throw 'The schedule-manager result path does not match its request nonce.'
    }
    if ([IO.File]::Exists($actualResult) -or [IO.Directory]::Exists($actualResult)) {
        throw 'The schedule-manager result target already exists.'
    }
    $script:resultChannelReady = $true
}

function Get-SanitizedResultError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'The protected schedule change failed.'
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

function New-ResultDocument {
    param([Collections.IDictionary]$Response)
    return [ordered]@{
        schema_version = 1
        request_nonce = $RequestNonce
        request_digest = $requestDigest
        request_user_sid = $currentSid
        action = 'apply'
        expected_current_fingerprint = $ExpectedCurrentFingerprint
        ok = [bool]$Response.ok
        changed = if ($Response.Contains('changed')) { [bool]$Response.changed } else { $false }
        rollback_performed = if ($Response.Contains('rollback_performed')) { [bool]$Response.rollback_performed } else { $false }
        rollback_verified = if ($Response.Contains('rollback_verified')) { [bool]$Response.rollback_verified } else { $false }
        backup_started = $false
        installed_fingerprint = if ($Response.Contains('installed_fingerprint')) { $Response.installed_fingerprint } else { $null }
        schedule = if ($Response.Contains('schedule')) { $Response.schedule } else { $null }
        error = if ($Response.Contains('error')) { Get-SanitizedResultError -Message ([string]$Response.error) } else { $null }
    }
}

function Write-ManagerResult {
    param([Collections.IDictionary]$Response)
    $document = New-ResultDocument -Response $Response
    if ($isTestMode) {
        $document | ConvertTo-Json -Compress -Depth 6
        return
    }
    if (-not $resultChannelReady) {
        throw 'The protected schedule-result channel is unavailable.'
    }
    [byte[]]$bytes = $utf8.GetBytes(($document | ConvertTo-Json -Depth 6) + "`n")
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

function Enter-RunLock {
    param([string]$File)
    $parent = Split-Path -Parent $File
    Assert-NormalDirectoryChain -Directory $parent
    if (Test-Path -LiteralPath $File) { Assert-NormalFile -File $File }
    $stream = [IO.File]::Open(
        $File,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::ReadWrite
    )
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
        throw 'A backup or another protected configuration change is already running. Try again after it finishes.'
    }
}

function Exit-RunLock {
    param([IO.FileStream]$Stream)
    if ($null -eq $Stream) { return }
    try { $Stream.Unlock(0, 1) }
    finally { $Stream.Dispose() }
}

function Initialize-TrustedScheduledTasksModule {
    if ($isTestMode) { return }
    $moduleManifest = Join-Path $trustedModuleRoot 'ScheduledTasks\ScheduledTasks.psd1'
    Assert-NormalFile -File $moduleManifest
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $loaded = @(Get-Module -Name ScheduledTasks)
    if ($loaded.Count -ne 1) {
        throw 'The trusted Windows ScheduledTasks module did not load exactly once.'
    }
    $loadedPath = [IO.Path]::GetFullPath([string]$loaded[0].Path)
    $trustedPrefix = [IO.Path]::GetFullPath($trustedModuleRoot).TrimEnd('\') + '\'
    if (-not $loadedPath.StartsWith($trustedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ScheduledTasks was loaded from an untrusted path: $loadedPath"
    }
}

function Get-ProtectedTaskState {
    if ($isTestMode) {
        Assert-NormalFile -File $taskAdapterStatePath
        $state = [IO.File]::ReadAllText($taskAdapterStatePath, $utf8).Trim()
        if ($state -notin @('Ready', 'Disabled', 'Running', 'Queued')) {
            throw "The disposable task adapter contains an invalid state: $state"
        }
        return $state
    }
    $task = ScheduledTasks\Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    if ($task.TaskName -ne $taskName -or $task.TaskPath -ne $taskPath) {
        throw 'Task Scheduler returned an unexpected task identity.'
    }
    return [string]$task.State
}

function Get-ProtectedTaskXmlSnapshot {
    if ($isTestMode) {
        Assert-NormalFile -File $taskAdapterXmlPath
        $bytes = [IO.File]::ReadAllBytes($taskAdapterXmlPath)
        $text = $utf8.GetString($bytes)
        return [pscustomobject]@{ Text = $text; Bytes = $bytes }
    }
    $text = [string](ScheduledTasks\Export-ScheduledTask `
        -TaskName $taskName `
        -TaskPath $taskPath `
        -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Task Scheduler exported an empty task definition.'
    }
    return [pscustomobject]@{ Text = $text; Bytes = $utf8.GetBytes($text) }
}

function Register-ProtectedTaskXml {
    param([string]$Xml)
    $script:registerAttemptCount++
    if ($isTestMode) {
        Assert-NormalDirectoryChain -Directory $taskAdapterRoot
        if ($TestFailure -eq 'RollbackRegister' -and $registerAttemptCount -ge 2) {
            throw 'Injected disposable-test rollback registration failure.'
        }
        [IO.File]::WriteAllText($taskAdapterXmlPath, $Xml, $utf8)
        if ($TestFailure -eq 'Register' -and $registerAttemptCount -eq 1) {
            throw 'Injected disposable-test registration failure after the adapter write.'
        }
        return
    }
    ScheduledTasks\Register-ScheduledTask `
        -TaskName $taskName `
        -TaskPath $taskPath `
        -Xml $Xml `
        -Force `
        -ErrorAction Stop | Out-Null
}

function Read-TaskXmlDocument {
    param([string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml) -or $Xml.Length -gt 4MB) {
        throw 'The scheduled-task XML is empty or exceeds the protected size limit.'
    }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = 4MB
    $reader = $null
    $stringReader = [IO.StringReader]::new($Xml)
    try {
        $reader = [Xml.XmlReader]::Create($stringReader, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $false
        $document.XmlResolver = $null
        $document.Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stringReader.Dispose()
    }
    if ($null -eq $document.DocumentElement -or
        $document.DocumentElement.LocalName -ne 'Task' -or
        $document.DocumentElement.NamespaceURI -ne $taskNamespace) {
        throw 'The exported task XML has an unexpected root element or namespace.'
    }
    return $document
}

function Get-NamespaceManager {
    param([Xml.XmlDocument]$Document)
    $manager = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $manager.AddNamespace('t', $taskNamespace)
    # XmlNamespaceManager implements IEnumerable; suppress pipeline enumeration.
    return ,$manager
}

function Get-RequiredSingleNode {
    param(
        [Xml.XmlNode]$Context,
        [string]$XPath,
        [Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$Description
    )
    $nodes = @($Context.SelectNodes($XPath, $NamespaceManager))
    if ($nodes.Count -ne 1) {
        throw "The protected task must contain exactly one $Description."
    }
    return [Xml.XmlNode]$nodes[0]
}

function Get-OptionalSingleNode {
    param(
        [Xml.XmlNode]$Context,
        [string]$XPath,
        [Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$Description
    )
    $nodes = @($Context.SelectNodes($XPath, $NamespaceManager))
    if ($nodes.Count -gt 1) {
        throw "The protected task contains more than one $Description."
    }
    if ($nodes.Count -eq 0) { return $null }
    return [Xml.XmlNode]$nodes[0]
}

function Get-RequiredXmlBoolean {
    param(
        [Xml.XmlNode]$Context,
        [string]$XPath,
        [Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$Description
    )
    $node = Get-RequiredSingleNode -Context $Context -XPath $XPath `
        -NamespaceManager $NamespaceManager -Description $Description
    $value = $node.InnerText.Trim().ToLowerInvariant()
    if ($value -notin @('true', 'false')) {
        throw "The protected task contains an invalid Boolean for $Description."
    }
    return $value -eq 'true'
}

function Resolve-TaskPrincipalSid {
    param([string]$Identity)
    try {
        return ([Security.Principal.SecurityIdentifier]::new($Identity)).Value
    }
    catch {
        try {
            return ([Security.Principal.NTAccount]::new($Identity)).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
        }
        catch {
            throw "The protected task principal cannot be resolved to a Windows SID: $Identity"
        }
    }
}

function Convert-DayElementToToken {
    param([string]$Name)
    foreach ($entry in $dayElementNames.GetEnumerator()) {
        if ([string]::Equals([string]$entry.Value, $Name, [StringComparison]::Ordinal)) {
            return [string]$entry.Key
        }
    }
    throw "The protected weekly schedule contains an unknown day element: $Name"
}

function Get-ValidatedTaskDefinition {
    param([Xml.XmlDocument]$Document, [string]$ExpectedSid)
    $namespaceManager = Get-NamespaceManager -Document $Document
    $root = $Document.DocumentElement

    $uriNode = Get-RequiredSingleNode -Context $root -XPath 't:RegistrationInfo/t:URI' `
        -NamespaceManager $namespaceManager -Description 'RegistrationInfo/URI element'
    if ($uriNode.InnerText.Trim() -ne "\$taskName") {
        throw 'The exported task XML names another registered task.'
    }

    $principalNodes = @($root.SelectNodes('t:Principals/t:Principal', $namespaceManager))
    if ($principalNodes.Count -ne 1) {
        throw 'The protected task must contain exactly one principal.'
    }
    $principal = [Xml.XmlNode]$principalNodes[0]
    $principalId = $principal.Attributes['id']
    if ($null -eq $principalId -or [string]::IsNullOrWhiteSpace($principalId.Value)) {
        throw 'The protected task principal is missing its id.'
    }
    $userIdNode = Get-RequiredSingleNode -Context $principal -XPath 't:UserId' `
        -NamespaceManager $namespaceManager -Description 'principal UserId element'
    $registeredSid = Resolve-TaskPrincipalSid -Identity $userIdNode.InnerText.Trim()
    if (-not [string]::Equals($registeredSid, $ExpectedSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The protected task principal does not match the approving Windows account.'
    }
    $logonType = Get-RequiredSingleNode -Context $principal -XPath 't:LogonType' `
        -NamespaceManager $namespaceManager -Description 'principal LogonType element'
    $runLevel = Get-RequiredSingleNode -Context $principal -XPath 't:RunLevel' `
        -NamespaceManager $namespaceManager -Description 'principal RunLevel element'
    if ($logonType.InnerText.Trim() -ne 'InteractiveToken' -or
        $runLevel.InnerText.Trim() -ne 'HighestAvailable') {
        throw 'The protected task principal is not InteractiveToken/HighestAvailable.'
    }

    $actions = @($root.SelectNodes('t:Actions/*', $namespaceManager))
    if ($actions.Count -ne 1 -or $actions[0].LocalName -ne 'Exec') {
        throw 'The protected task must contain exactly one executable action.'
    }
    $actionsNode = Get-RequiredSingleNode -Context $root -XPath 't:Actions' `
        -NamespaceManager $namespaceManager -Description 'Actions element'
    $contextAttribute = $actionsNode.Attributes['Context']
    if ($null -eq $contextAttribute -or $contextAttribute.Value -ne $principalId.Value) {
        throw 'The protected task action context does not match its principal.'
    }
    $exec = [Xml.XmlNode]$actions[0]
    $command = Get-RequiredSingleNode -Context $exec -XPath 't:Command' `
        -NamespaceManager $namespaceManager -Description 'action Command element'
    $workingDirectory = Get-RequiredSingleNode -Context $exec -XPath 't:WorkingDirectory' `
        -NamespaceManager $namespaceManager -Description 'action WorkingDirectory element'
    $arguments = Get-OptionalSingleNode -Context $exec -XPath 't:Arguments' `
        -NamespaceManager $namespaceManager -Description 'action Arguments element'
    if (-not (Test-PathEqual -Left ([IO.Path]::GetFullPath($command.InnerText.Trim())) -Right $launcherPath) -or
        -not (Test-PathEqual -Left ([IO.Path]::GetFullPath($workingDirectory.InnerText.Trim()).TrimEnd('\')) -Right $installRoot) -or
        ($null -ne $arguments -and -not [string]::IsNullOrWhiteSpace($arguments.InnerText))) {
        throw 'The protected task action does not match the supervised backup launcher.'
    }
    $execChildren = @($exec.SelectNodes('*'))
    foreach ($child in $execChildren) {
        if ($child.NamespaceURI -ne $taskNamespace -or $child.LocalName -notin @('Command', 'Arguments', 'WorkingDirectory')) {
            throw "The protected task executable action contains an unexpected element: $($child.LocalName)"
        }
    }

    $settings = Get-RequiredSingleNode -Context $root -XPath 't:Settings' `
        -NamespaceManager $namespaceManager -Description 'Settings element'
    $fixedSettings = [ordered]@{
        MultipleInstancesPolicy = 'IgnoreNew'
        AllowHardTerminate = 'true'
        RunOnlyIfNetworkAvailable = 'false'
        AllowStartOnDemand = 'true'
        Hidden = 'false'
        RunOnlyIfIdle = 'false'
        ExecutionTimeLimit = 'PT0S'
        Priority = '7'
    }
    foreach ($entry in $fixedSettings.GetEnumerator()) {
        $node = Get-RequiredSingleNode -Context $settings -XPath ("t:{0}" -f $entry.Key) `
            -NamespaceManager $namespaceManager -Description ("Settings/{0} element" -f $entry.Key)
        if ($node.InnerText.Trim() -ne [string]$entry.Value) {
            throw "The protected task has an unexpected Settings/$($entry.Key) value."
        }
    }
    $taskEnabled = Get-RequiredXmlBoolean -Context $settings -XPath 't:Enabled' `
        -NamespaceManager $namespaceManager -Description 'Settings/Enabled'
    $taskStartWhenAvailable = Get-RequiredXmlBoolean -Context $settings -XPath 't:StartWhenAvailable' `
        -NamespaceManager $namespaceManager -Description 'Settings/StartWhenAvailable'
    $taskWakeToRun = Get-RequiredXmlBoolean -Context $settings -XPath 't:WakeToRun' `
        -NamespaceManager $namespaceManager -Description 'Settings/WakeToRun'
    $disallowStartOnBatteries = Get-RequiredXmlBoolean -Context $settings `
        -XPath 't:DisallowStartIfOnBatteries' -NamespaceManager $namespaceManager `
        -Description 'Settings/DisallowStartIfOnBatteries'
    $taskStopIfGoingOnBatteries = Get-RequiredXmlBoolean -Context $settings `
        -XPath 't:StopIfGoingOnBatteries' -NamespaceManager $namespaceManager `
        -Description 'Settings/StopIfGoingOnBatteries'

    $triggers = @($root.SelectNodes('t:Triggers/*', $namespaceManager))
    if ($triggers.Count -ne 1 -or $triggers[0].LocalName -ne 'CalendarTrigger') {
        throw 'The protected task must contain exactly one calendar trigger.'
    }
    $trigger = [Xml.XmlNode]$triggers[0]
    $startBoundary = Get-RequiredSingleNode -Context $trigger -XPath 't:StartBoundary' `
        -NamespaceManager $namespaceManager -Description 'calendar StartBoundary element'
    $triggerEnabled = Get-RequiredXmlBoolean -Context $trigger -XPath 't:Enabled' `
        -NamespaceManager $namespaceManager -Description 'calendar Enabled element'
    if (-not $triggerEnabled) {
        throw 'The protected calendar trigger must remain enabled; task enablement belongs in Settings/Enabled.'
    }
    $boundaryPattern = '^(?<date>\d{4}-\d{2}-\d{2})T(?<hour>\d{2}):(?<minute>\d{2})(?::(?<second>\d{2})(?:\.\d{1,7})?)?(?<zone>Z|[+-]\d{2}:\d{2})?$'
    $boundaryMatch = [Text.RegularExpressions.Regex]::Match($startBoundary.InnerText.Trim(), $boundaryPattern)
    if (-not $boundaryMatch.Success) {
        throw 'The protected task has an invalid calendar StartBoundary.'
    }
    $parsedBoundary = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
        $startBoundary.InnerText.Trim(),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsedBoundary
    )) {
        throw 'The protected task calendar StartBoundary cannot be parsed.'
    }
    if (($parsedBoundary.TimeOfDay.Ticks % [TimeSpan]::TicksPerMinute) -ne 0) {
        throw 'The protected task calendar StartBoundary must be aligned to an exact minute.'
    }

    $scheduleNodes = @($trigger.SelectNodes('t:ScheduleByDay | t:ScheduleByWeek', $namespaceManager))
    if ($scheduleNodes.Count -ne 1) {
        throw 'The protected calendar trigger must contain exactly one daily or weekly schedule.'
    }
    $triggerChildren = @($trigger.SelectNodes('*'))
    if ($triggerChildren.Count -ne 3) {
        throw 'The protected calendar trigger contains unexpected scheduling fields.'
    }
    foreach ($child in $triggerChildren) {
        if ($child.NamespaceURI -ne $taskNamespace -or
            $child.LocalName -notin @('StartBoundary', 'Enabled', 'ScheduleByDay', 'ScheduleByWeek')) {
            throw "The protected calendar trigger contains an unexpected element: $($child.LocalName)"
        }
    }

    $scheduleNode = [Xml.XmlNode]$scheduleNodes[0]
    $scheduleCadence = $null
    $scheduleDays = @()
    if ($scheduleNode.LocalName -eq 'ScheduleByDay') {
        $daysInterval = Get-RequiredSingleNode -Context $scheduleNode -XPath 't:DaysInterval' `
            -NamespaceManager $namespaceManager -Description 'daily DaysInterval element'
        if ($daysInterval.InnerText.Trim() -ne '1' -or @($scheduleNode.SelectNodes('*')).Count -ne 1) {
            throw 'The protected daily schedule must have exactly a one-day interval.'
        }
        $scheduleCadence = 'Daily'
    }
    else {
        $weeksInterval = Get-RequiredSingleNode -Context $scheduleNode -XPath 't:WeeksInterval' `
            -NamespaceManager $namespaceManager -Description 'weekly WeeksInterval element'
        $daysOfWeek = Get-RequiredSingleNode -Context $scheduleNode -XPath 't:DaysOfWeek' `
            -NamespaceManager $namespaceManager -Description 'weekly DaysOfWeek element'
        if ($weeksInterval.InnerText.Trim() -ne '1' -or @($scheduleNode.SelectNodes('*')).Count -ne 2) {
            throw 'The protected weekly schedule must have exactly a one-week interval and selected days.'
        }
        $seenDays = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($dayNode in @($daysOfWeek.SelectNodes('*'))) {
            if ($dayNode.NamespaceURI -ne $taskNamespace -or $dayNode.HasChildNodes -or
                -not [string]::IsNullOrWhiteSpace($dayNode.InnerText)) {
                throw 'The protected weekly schedule contains an invalid selected-day element.'
            }
            $token = Convert-DayElementToToken -Name $dayNode.LocalName
            if (-not $seenDays.Add($token)) {
                throw "The protected weekly schedule repeats a selected day: $token"
            }
        }
        if ($seenDays.Count -lt 1) {
            throw 'The protected weekly schedule must select at least one day.'
        }
        $scheduleDays = @($canonicalDayOrder | Where-Object { $seenDays.Contains($_) })
        $scheduleCadence = 'SelectedDays'
    }

    return [pscustomobject]@{
        NamespaceManager = $namespaceManager
        StartBoundary = $startBoundary
        BoundaryDate = $boundaryMatch.Groups['date'].Value
        BoundaryZone = $boundaryMatch.Groups['zone'].Value
        ScheduleNode = $scheduleNode
        SettingsNode = $settings
        Cadence = $scheduleCadence
        Time = $parsedBoundary.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        Days = [string[]]$scheduleDays
        Enabled = $taskEnabled
        StartWhenAvailable = $taskStartWhenAvailable
        WakeToRun = $taskWakeToRun
        AllowStartOnBatteries = -not $disallowStartOnBatteries
        StopIfGoingOnBatteries = $taskStopIfGoingOnBatteries
    }
}

function Get-TaskFingerprint {
    param([Xml.XmlDocument]$Document)
    $payload = 'ResticBackuper.TaskXml.v1' + "`n" + $Document.DocumentElement.OuterXml
    return Get-Sha256Hex -Bytes $utf8.GetBytes($payload)
}

function Set-RequiredNodeText {
    param(
        [Xml.XmlNode]$Context,
        [string]$XPath,
        [Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$Description,
        [string]$Value
    )
    $node = Get-RequiredSingleNode -Context $Context -XPath $XPath `
        -NamespaceManager $NamespaceManager -Description $Description
    $node.InnerText = $Value
}

function New-DesiredTaskDocument {
    param(
        [Xml.XmlDocument]$Baseline,
        [string]$RequestedCadence,
        [string]$RequestedTime,
        [string[]]$RequestedDays,
        [bool]$RequestedEnabled,
        [bool]$RequestedStartWhenAvailable,
        [bool]$RequestedWakeToRun,
        [bool]$RequestedAllowStartOnBatteries,
        [bool]$RequestedStopIfGoingOnBatteries,
        [string]$ExpectedSid
    )
    $document = [Xml.XmlDocument]$Baseline.CloneNode($true)
    $validated = Get-ValidatedTaskDefinition -Document $document -ExpectedSid $ExpectedSid
    $validated.StartBoundary.InnerText = $validated.BoundaryDate + 'T' + $RequestedTime + ':00' + $validated.BoundaryZone

    Set-RequiredNodeText -Context $validated.SettingsNode -XPath 't:Enabled' `
        -NamespaceManager $validated.NamespaceManager -Description 'Settings/Enabled' `
        -Value (ConvertTo-XmlBooleanText -Value $RequestedEnabled)
    Set-RequiredNodeText -Context $validated.SettingsNode -XPath 't:StartWhenAvailable' `
        -NamespaceManager $validated.NamespaceManager -Description 'Settings/StartWhenAvailable' `
        -Value (ConvertTo-XmlBooleanText -Value $RequestedStartWhenAvailable)
    Set-RequiredNodeText -Context $validated.SettingsNode -XPath 't:WakeToRun' `
        -NamespaceManager $validated.NamespaceManager -Description 'Settings/WakeToRun' `
        -Value (ConvertTo-XmlBooleanText -Value $RequestedWakeToRun)
    Set-RequiredNodeText -Context $validated.SettingsNode -XPath 't:DisallowStartIfOnBatteries' `
        -NamespaceManager $validated.NamespaceManager -Description 'Settings/DisallowStartIfOnBatteries' `
        -Value (ConvertTo-XmlBooleanText -Value (-not $RequestedAllowStartOnBatteries))
    Set-RequiredNodeText -Context $validated.SettingsNode -XPath 't:StopIfGoingOnBatteries' `
        -NamespaceManager $validated.NamespaceManager -Description 'Settings/StopIfGoingOnBatteries' `
        -Value (ConvertTo-XmlBooleanText -Value $RequestedStopIfGoingOnBatteries)

    if ($RequestedCadence -eq 'Daily') {
        $replacement = $document.CreateElement('ScheduleByDay', $taskNamespace)
        $interval = $document.CreateElement('DaysInterval', $taskNamespace)
        $interval.InnerText = '1'
        [void]$replacement.AppendChild($interval)
    }
    else {
        $replacement = $document.CreateElement('ScheduleByWeek', $taskNamespace)
        $daysNode = $document.CreateElement('DaysOfWeek', $taskNamespace)
        foreach ($token in $RequestedDays) {
            [void]$daysNode.AppendChild($document.CreateElement([string]$dayElementNames[$token], $taskNamespace))
        }
        $weeksInterval = $document.CreateElement('WeeksInterval', $taskNamespace)
        $weeksInterval.InnerText = '1'
        [void]$replacement.AppendChild($daysNode)
        [void]$replacement.AppendChild($weeksInterval)
    }
    [void]$validated.ScheduleNode.ParentNode.ReplaceChild($replacement, $validated.ScheduleNode)
    return $document
}

function Get-PreservedTaskFingerprint {
    param([Xml.XmlDocument]$Document, [string]$ExpectedSid)
    $copy = [Xml.XmlDocument]$Document.CloneNode($true)
    $validated = Get-ValidatedTaskDefinition -Document $copy -ExpectedSid $ExpectedSid
    $validated.StartBoundary.InnerText = '2000-01-01T00:00:00'
    foreach ($path in @(
        't:Enabled',
        't:StartWhenAvailable',
        't:WakeToRun',
        't:DisallowStartIfOnBatteries',
        't:StopIfGoingOnBatteries'
    )) {
        Set-RequiredNodeText -Context $validated.SettingsNode -XPath $path `
            -NamespaceManager $validated.NamespaceManager -Description "preserved comparison $path" -Value 'false'
    }
    $placeholder = $copy.CreateElement('ScheduleByDay', $taskNamespace)
    $interval = $copy.CreateElement('DaysInterval', $taskNamespace)
    $interval.InnerText = '1'
    [void]$placeholder.AppendChild($interval)
    [void]$validated.ScheduleNode.ParentNode.ReplaceChild($placeholder, $validated.ScheduleNode)
    $payload = 'ResticBackuper.TaskPreserved.v1' + "`n" + $copy.DocumentElement.OuterXml
    return Get-Sha256Hex -Bytes $utf8.GetBytes($payload)
}

function Assert-DefinitionMatchesRequest {
    param(
        [pscustomobject]$Definition,
        [string]$RequestedCadence,
        [string]$RequestedTime,
        [string[]]$RequestedDays,
        [bool]$RequestedEnabled,
        [bool]$RequestedStartWhenAvailable,
        [bool]$RequestedWakeToRun,
        [bool]$RequestedAllowStartOnBatteries,
        [bool]$RequestedStopIfGoingOnBatteries
    )
    if ($Definition.Cadence -ne $RequestedCadence -or
        $Definition.Time -ne $RequestedTime -or
        (@($Definition.Days) -join ',') -ne ($RequestedDays -join ',') -or
        $Definition.Enabled -ne $RequestedEnabled -or
        $Definition.StartWhenAvailable -ne $RequestedStartWhenAvailable -or
        $Definition.WakeToRun -ne $RequestedWakeToRun -or
        $Definition.AllowStartOnBatteries -ne $RequestedAllowStartOnBatteries -or
        $Definition.StopIfGoingOnBatteries -ne $RequestedStopIfGoingOnBatteries) {
        throw 'The installed task schedule differs from the approved request.'
    }
}

function New-ScheduleResultObject {
    param([pscustomobject]$Definition)
    return [ordered]@{
        cadence = [string]$Definition.Cadence
        time = [string]$Definition.Time
        days = [string[]]@($Definition.Days)
        enabled = [bool]$Definition.Enabled
        start_when_available = [bool]$Definition.StartWhenAvailable
        wake_to_run = [bool]$Definition.WakeToRun
        allow_start_on_batteries = [bool]$Definition.AllowStartOnBatteries
        stop_if_going_on_batteries = [bool]$Definition.StopIfGoingOnBatteries
    }
}

try {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'ResticBackuper schedule management requires 64-bit Windows PowerShell 5.1.'
    }
    if ($PSVersionTable.PSVersion.Major -ne 5) {
        throw 'ResticBackuper schedule management must run in Windows PowerShell 5.1.'
    }
    if ($isTestMode) {
        if ($TestFailure -notin @('None', 'Register', 'Verify', 'RollbackRegister', 'RollbackVerify')) {
            throw 'The disposable test failure point is invalid.'
        }
    }
    else {
        if (-not (Test-Administrator)) {
            throw 'Schedule changes must be run elevated.'
        }
        if ($TestFailure -ne 'None') {
            throw 'Failure injection is available only for disposable tests.'
        }
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or
        -not [string]::Equals($ExpectedUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approve elevation with the same Windows account that requested this schedule change.'
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Schedule management must be executed as an installed script, not dot-sourced.'
    }
    $actualScript = [IO.Path]::GetFullPath($PSCommandPath)
    if (-not (Test-PathEqual -Left $actualScript -Right $managerPath)) {
        throw "Refusing to manage the schedule outside the protected installation: $actualScript"
    }
    foreach ($directory in @($installRoot, $stateRoot)) {
        Assert-NormalDirectoryChain -Directory $directory
    }
    Assert-NormalFile -File $actualScript
    if ($isTestMode) {
        Assert-NormalDirectoryChain -Directory $taskAdapterRoot
    }
    else {
        Assert-NormalFile -File $launcherPath
    }

    $requestedDays = Get-CanonicalRequestedDays -Value $Days -RequestedCadence $Cadence
    $requestedEnabled = ConvertTo-FlagBoolean -Value $Enabled
    $requestedStartWhenAvailable = ConvertTo-FlagBoolean -Value $StartWhenAvailable
    $requestedWakeToRun = ConvertTo-FlagBoolean -Value $WakeToRun
    $requestedAllowStartOnBatteries = ConvertTo-FlagBoolean -Value $AllowStartOnBatteries
    $requestedStopIfGoingOnBatteries = ConvertTo-FlagBoolean -Value $StopIfGoingOnBatteries
    $requestDigest = Get-RequestDigest `
        -Sid $currentSid `
        -ExpectedFingerprint $ExpectedCurrentFingerprint `
        -RequestedCadence $Cadence `
        -RequestedTime $Time `
        -RequestedDays $requestedDays `
        -RequestedEnabled $requestedEnabled `
        -RequestedStartWhenAvailable $requestedStartWhenAvailable `
        -RequestedWakeToRun $requestedWakeToRun `
        -RequestedAllowStartOnBatteries $requestedAllowStartOnBatteries `
        -RequestedStopIfGoingOnBatteries $requestedStopIfGoingOnBatteries `
        -Nonce $RequestNonce

    if (-not $isTestMode) {
        if ([string]::IsNullOrWhiteSpace($ResultPath)) {
            throw 'The dashboard must provide a protected schedule-result path.'
        }
        Initialize-ResultChannel -UserSid $currentSid
    }
    Initialize-TrustedScheduledTasksModule

    # The shared byte-range lock is deliberately acquired before the first task
    # adapter or ScheduledTasks call. It interoperates with the protected runtime.
    $lockStream = Enter-RunLock -File $lockPath
    foreach ($journalName in @('repository-relocation.journal.json', 'plan-migration.journal.json', 'credential-rotation.journal.json')) {
        $pendingJournal = Join-Path $stateRoot $journalName
        if ([IO.File]::Exists($pendingJournal) -or [IO.Directory]::Exists($pendingJournal)) {
            throw "A pending protected-operation journal ($journalName) must be recovered before schedule changes."
        }
    }
    $initialState = Get-ProtectedTaskState
    if ($initialState -notin @('Ready', 'Disabled')) {
        throw "The protected backup task is $initialState; schedule changes require it to be stopped."
    }

    $baselineSnapshot = Get-ProtectedTaskXmlSnapshot
    $baselineDocument = Read-TaskXmlDocument -Xml $baselineSnapshot.Text
    $baselineFingerprint = Get-TaskFingerprint -Document $baselineDocument
    if (-not [string]::Equals(
        $baselineFingerprint,
        $ExpectedCurrentFingerprint,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The protected schedule changed after it was reviewed. Refresh and approve the current schedule.'
    }
    $baselineDefinition = Get-ValidatedTaskDefinition -Document $baselineDocument -ExpectedSid $currentSid
    $baselinePreservedFingerprint = Get-PreservedTaskFingerprint `
        -Document $baselineDocument -ExpectedSid $currentSid

    $desiredDocument = New-DesiredTaskDocument `
        -Baseline $baselineDocument `
        -RequestedCadence $Cadence `
        -RequestedTime $Time `
        -RequestedDays $requestedDays `
        -RequestedEnabled $requestedEnabled `
        -RequestedStartWhenAvailable $requestedStartWhenAvailable `
        -RequestedWakeToRun $requestedWakeToRun `
        -RequestedAllowStartOnBatteries $requestedAllowStartOnBatteries `
        -RequestedStopIfGoingOnBatteries $requestedStopIfGoingOnBatteries `
        -ExpectedSid $currentSid
    $desiredDefinition = Get-ValidatedTaskDefinition -Document $desiredDocument -ExpectedSid $currentSid
    Assert-DefinitionMatchesRequest `
        -Definition $desiredDefinition `
        -RequestedCadence $Cadence `
        -RequestedTime $Time `
        -RequestedDays $requestedDays `
        -RequestedEnabled $requestedEnabled `
        -RequestedStartWhenAvailable $requestedStartWhenAvailable `
        -RequestedWakeToRun $requestedWakeToRun `
        -RequestedAllowStartOnBatteries $requestedAllowStartOnBatteries `
        -RequestedStopIfGoingOnBatteries $requestedStopIfGoingOnBatteries
    $desiredPreservedFingerprint = Get-PreservedTaskFingerprint `
        -Document $desiredDocument -ExpectedSid $currentSid
    if ($desiredPreservedFingerprint -ne $baselinePreservedFingerprint) {
        throw 'Staging the schedule changed a protected task field outside the approved schedule settings.'
    }

    $desiredFingerprint = Get-TaskFingerprint -Document $desiredDocument
    if ($desiredFingerprint -eq $baselineFingerprint) {
        $installedFingerprint = $baselineFingerprint
        $finalDefinition = $baselineDefinition
    }
    else {
        $changed = $true
        $preRegistrationState = Get-ProtectedTaskState
        if ($preRegistrationState -notin @('Ready', 'Disabled')) {
            throw "The protected backup task became $preRegistrationState before registration; no change was made."
        }
        $registrationAttempted = $true
        try {
            Register-ProtectedTaskXml -Xml $desiredDocument.OuterXml
            if ($isTestMode -and $TestFailure -in @('Verify', 'RollbackRegister', 'RollbackVerify')) {
                throw 'Injected disposable-test verification failure.'
            }
            $installedSnapshot = Get-ProtectedTaskXmlSnapshot
            $installedDocument = Read-TaskXmlDocument -Xml $installedSnapshot.Text
            $finalDefinition = Get-ValidatedTaskDefinition -Document $installedDocument -ExpectedSid $currentSid
            Assert-DefinitionMatchesRequest `
                -Definition $finalDefinition `
                -RequestedCadence $Cadence `
                -RequestedTime $Time `
                -RequestedDays $requestedDays `
                -RequestedEnabled $requestedEnabled `
                -RequestedStartWhenAvailable $requestedStartWhenAvailable `
                -RequestedWakeToRun $requestedWakeToRun `
                -RequestedAllowStartOnBatteries $requestedAllowStartOnBatteries `
                -RequestedStopIfGoingOnBatteries $requestedStopIfGoingOnBatteries
            $installedPreservedFingerprint = Get-PreservedTaskFingerprint `
                -Document $installedDocument -ExpectedSid $currentSid
            if ($installedPreservedFingerprint -ne $baselinePreservedFingerprint) {
                throw 'Task Scheduler changed a protected task field outside the approved schedule settings.'
            }
            $installedFingerprint = Get-TaskFingerprint -Document $installedDocument
        }
        catch {
            $changeError = $_.Exception.Message
            $rollbackPerformed = $true
            try {
                Register-ProtectedTaskXml -Xml $baselineSnapshot.Text
                $rollbackSnapshot = Get-ProtectedTaskXmlSnapshot
                $rollbackDocument = Read-TaskXmlDocument -Xml $rollbackSnapshot.Text
                $rollbackDefinition = Get-ValidatedTaskDefinition `
                    -Document $rollbackDocument -ExpectedSid $currentSid
                $rollbackFingerprint = Get-TaskFingerprint -Document $rollbackDocument
                $rollbackPreservedFingerprint = Get-PreservedTaskFingerprint `
                    -Document $rollbackDocument -ExpectedSid $currentSid
                if ($rollbackFingerprint -ne $baselineFingerprint -or
                    $rollbackPreservedFingerprint -ne $baselinePreservedFingerprint) {
                    throw 'The exported task after rollback does not match the approved baseline.'
                }
                if ($isTestMode -and $TestFailure -eq 'RollbackVerify') {
                    throw 'Injected disposable-test rollback verification failure.'
                }
                $rollbackVerified = $true
                $installedFingerprint = $rollbackFingerprint
                $finalDefinition = $rollbackDefinition
            }
            catch {
                $rollbackError = $_.Exception.Message
                throw "Schedule update failed ($changeError), and rollback needs attention: $rollbackError"
            }
            throw "Schedule update failed and was rolled back: $changeError"
        }
    }

    $response = [ordered]@{
        ok = $true
        changed = $changed
        rollback_performed = $rollbackPerformed
        rollback_verified = $rollbackVerified
        installed_fingerprint = $installedFingerprint
        schedule = New-ScheduleResultObject -Definition $finalDefinition
    }
    Write-ManagerResult -Response $response
}
catch {
    $response = [ordered]@{
        ok = $false
        changed = $false
        rollback_performed = $rollbackPerformed
        rollback_verified = $rollbackVerified
        installed_fingerprint = $installedFingerprint
        error = $_.Exception.Message
    }
    if ($isTestMode) {
        if ([string]::IsNullOrWhiteSpace($requestDigest) -and -not [string]::IsNullOrWhiteSpace($currentSid)) {
            try {
                $digestDays = Get-CanonicalRequestedDays -Value $Days -RequestedCadence $Cadence
                $requestDigest = Get-RequestDigest `
                    -Sid $currentSid `
                    -ExpectedFingerprint $ExpectedCurrentFingerprint `
                    -RequestedCadence $Cadence `
                    -RequestedTime $Time `
                    -RequestedDays $digestDays `
                    -RequestedEnabled (ConvertTo-FlagBoolean -Value $Enabled) `
                    -RequestedStartWhenAvailable (ConvertTo-FlagBoolean -Value $StartWhenAvailable) `
                    -RequestedWakeToRun (ConvertTo-FlagBoolean -Value $WakeToRun) `
                    -RequestedAllowStartOnBatteries (ConvertTo-FlagBoolean -Value $AllowStartOnBatteries) `
                    -RequestedStopIfGoingOnBatteries (ConvertTo-FlagBoolean -Value $StopIfGoingOnBatteries) `
                    -Nonce $RequestNonce
            }
            catch { }
        }
        Write-ManagerResult -Response $response
    }
    elseif ($resultChannelReady) {
        try { Write-ManagerResult -Response $response }
        catch { }
    }
    exit 1
}
finally {
    if ($null -ne $lockStream) { Exit-RunLock -Stream $lockStream }
}
