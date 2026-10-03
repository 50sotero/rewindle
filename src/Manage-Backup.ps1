#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Cancel')]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2147483647)]
    [int]$ExpectedWrapperPid,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedTaskFingerprint,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedUserSid,
    [Parameter(Mandatory = $true)]
    [string]$ResultPath,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$RequestNonce,
    [string]$TestRoot,
    [ValidateSet('None', 'FinishBeforeSignal', 'ReplaceBeforeSignal')]
    [string]$TestScenario = 'None'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productName = 'ResticBackuper'
$taskName = 'ResticBackuper'
$taskPath = '\'
$taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$taskFingerprintDomain = 'ResticBackuper.TaskXml.v1'
$requestDomain = 'ResticBackuper.BackupControlRequest.v1'
$cancelEventPrefix = 'Local\ResticBackuper.Cancel.'
$activeStates = @(
    'starting',
    # The backup wrapper's preflight phases each pass a cancellation checkpoint.
    'checking_repository_storage',
    'preflighting_sources',
    'authenticating_repository',
    'backing_up',
    'verifying_snapshot',
    'checking_repository',
    'restoring_canary',
    'checking_data_subset',
    'cancelling'
)
$terminalStates = @(
    'success',
    'success_unchanged',
    'failed',
    'partial',
    'cancelled',
    'cancel_failed'
)
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
    if ($testContainer -eq $temporaryRoot -or
        -not $testContainer.StartsWith($temporaryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The disposable backup-manager test root must be a child of the current user temporary directory.'
    }
    $installRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramFiles\$productName")).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $testContainer "ProgramData\$productName")).TrimEnd('\')
    $adapterRoot = [IO.Path]::GetFullPath((Join-Path $testContainer 'ControlAdapter')).TrimEnd('\')
    $adapterTaskXmlPath = Join-Path $adapterRoot "$taskName.xml"
    $adapterTaskStatePath = Join-Path $adapterRoot "$taskName.state"
    $adapterSecurityPath = Join-Path $adapterRoot 'security.json'
    $adapterProcessesPath = Join-Path $adapterRoot 'processes.json'
    $adapterChannelPath = Join-Path $adapterRoot 'channel.json'
    $adapterStatusAfterPath = Join-Path $adapterRoot 'status-after.json'
    $adapterSignalPath = Join-Path $adapterRoot 'signal.json'
}
else {
    $installRoot = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName)).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $programDataRoot $productName)).TrimEnd('\')
}

$managerPath = Join-Path $installRoot 'Manage-Backup.ps1'
$launcherPath = Join-Path $installRoot 'ResticBackuperTaskLauncher.exe'
$pythonPath = Join-Path $installRoot 'Python\python.exe'
$statusPath = Join-Path $stateRoot 'status.json'
$resultRoot = Join-Path $stateRoot 'BackupManagerResults'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$currentSid = $null
$requestDigest = $null
$resultChannelReady = $false
$statusReadCount = 0

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
        throw "Required directory does not exist: $Directory"
    }
    $current = Get-Item -LiteralPath $Directory -Force
    while ($null -ne $current) {
        if (-not $current.PSIsContainer -or
            ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
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
        throw "Required normal file is missing: $File"
    }
    $item = Get-Item -LiteralPath $File -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
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

function Get-RequiredProperty {
    param([object]$Object, [string]$Name, [string]$DocumentName)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$DocumentName is missing required field: $Name"
    }
    return $property.Value
}

function Read-BoundedJsonObject {
    param(
        [string]$File,
        [long]$MaximumBytes,
        [string]$Description
    )
    Assert-NormalFile -File $File
    $item = Get-Item -LiteralPath $File -Force
    if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
        throw "$Description has an invalid size."
    }
    $bytes = [IO.File]::ReadAllBytes($File)
    $text = $utf8.GetString($bytes)
    try { $value = $text | ConvertFrom-Json }
    catch { throw "$Description is not valid UTF-8 JSON: $($_.Exception.Message)" }
    if ($null -eq $value -or $value -isnot [Management.Automation.PSCustomObject]) {
        throw "$Description must contain exactly one JSON object."
    }
    return $value
}

function Get-AdapterSecurityDocument {
    if (-not $isTestMode) { throw 'The security adapter is available only in disposable tests.' }
    return Read-BoundedJsonObject -File $adapterSecurityPath -MaximumBytes 1MB `
        -Description 'The disposable security adapter'
}

function Assert-AdapterPathSecurity {
    param(
        [string]$Path,
        [string]$Key,
        [ValidateSet('directory', 'file')]
        [string]$Kind,
        [switch]$RequireProtectedRoot,
        [switch]$AllowUserOwner
    )
    $document = Get-AdapterSecurityDocument
    if ($document.schema_version -ne 1) {
        throw 'The disposable security adapter schema is invalid.'
    }
    $records = Get-RequiredProperty -Object $document -Name 'paths' -DocumentName 'The disposable security adapter'
    $record = Get-RequiredProperty -Object $records -Name $Key -DocumentName 'The disposable security adapter path table'
    if ($record.path -isnot [string] -or
        -not (Test-PathEqual -Left ([IO.Path]::GetFullPath([string]$record.path)) -Right ([IO.Path]::GetFullPath($Path))) -or
        $record.kind -ne $Kind -or
        $record.normal -isnot [bool] -or -not [bool]$record.normal -or
        $record.reparse -isnot [bool] -or [bool]$record.reparse) {
        throw "Protected path adapter identity is unsafe: $Key"
    }
    $owner = [string]$record.owner_sid
    if ($owner -ne 'S-1-5-32-544' -and
        (-not $AllowUserOwner -or
            -not [string]::Equals($owner, $currentSid, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Protected path adapter owner is unsafe: $Key"
    }
    foreach ($booleanName in @(
        'system_full',
        'administrators_full',
        'user_read_execute',
        'owner_rights_read_execute'
    )) {
        $value = Get-RequiredProperty -Object $record -Name $booleanName -DocumentName "The $Key security record"
        if ($value -isnot [bool] -or -not [bool]$value) {
            throw "Protected path adapter lacks required ACL rights: $Key/$booleanName"
        }
    }
    foreach ($booleanName in @('unexpected_identity', 'user_write', 'owner_rights_write')) {
        $value = Get-RequiredProperty -Object $record -Name $booleanName -DocumentName "The $Key security record"
        if ($value -isnot [bool] -or [bool]$value) {
            throw "Protected path adapter grants an unsafe ACL capability: $Key/$booleanName"
        }
    }
    if ($RequireProtectedRoot) {
        if ($record.inheritance_protected -isnot [bool] -or -not [bool]$record.inheritance_protected) {
            throw "Protected root adapter inherits an unsafe ACL: $Key"
        }
    }
}

function Assert-RealPathSecurity {
    param(
        [string]$Path,
        [string]$Kind,
        [switch]$RequireProtectedRoot,
        [switch]$AllowUserOwner
    )
    if ($Kind -eq 'directory') { Assert-NormalDirectoryChain -Directory $Path }
    else { Assert-NormalFile -File $Path }
    $acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -and
        (-not $AllowUserOwner -or
            -not [string]::Equals($owner, $currentSid, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Protected path has an unsafe owner: $Path"
    }
    if ($RequireProtectedRoot -and -not $acl.AreAccessRulesProtected) {
        throw "Protected root still inherits ACL entries: $Path"
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $currentSid)
    $required = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed -or ($RequireProtectedRoot -and $rule.IsInherited)) {
            throw "Protected path contains an unexpected ACL entry for $sid`: $Path"
        }
        if ($sid -in @('S-1-5-18', 'S-1-5-32-544')) {
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Protected path does not grant full control to $sid`: $Path"
            }
        }
        elseif (($rule.FileSystemRights -band $dangerous) -ne 0 -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            throw "Protected path grants unsafe requester/owner rights to $sid`: $Path"
        }
        [void]$required.Add($sid)
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $currentSid)) {
        if (-not $required.Contains($sid)) {
            throw "Protected path ACL is missing $sid`: $Path"
        }
    }
}

function Assert-ProtectedPath {
    param(
        [string]$Path,
        [string]$AdapterKey,
        [ValidateSet('directory', 'file')]
        [string]$Kind,
        [switch]$RequireProtectedRoot,
        [switch]$AllowUserOwner
    )
    if ($Kind -eq 'directory') { Assert-NormalDirectoryChain -Directory $Path }
    else { Assert-NormalFile -File $Path }
    if ($isTestMode) {
        Assert-AdapterPathSecurity -Path $Path -Key $AdapterKey -Kind $Kind `
            -RequireProtectedRoot:$RequireProtectedRoot -AllowUserOwner:$AllowUserOwner
    }
    else {
        Assert-RealPathSecurity -Path $Path -Kind $Kind `
            -RequireProtectedRoot:$RequireProtectedRoot -AllowUserOwner:$AllowUserOwner
    }
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

function Assert-ResultAcl {
    param([string]$Path, [string]$UserSid)
    $acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -or -not $acl.AreAccessRulesProtected) {
        throw "Protected result path has an unsafe owner or inherited ACL: $Path"
    }
    $allowed = @('S-1-5-18', 'S-1-5-32-544', 'S-1-3-4', $UserSid)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
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
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowed) {
            throw "Protected result path has an unexpected ACL identity: $sid"
        }
        if ($sid -in @('S-1-5-18', 'S-1-5-32-544')) {
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
                throw "Protected result path lacks full control for $sid"
            }
        }
        elseif (($rule.FileSystemRights -band $dangerous) -ne 0 -or
            ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            throw "Protected result path grants unsafe requester/owner rights to $sid"
        }
        [void]$seen.Add($sid)
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $UserSid)) {
        if (-not $seen.Contains($sid)) { throw "Protected result path ACL is missing $sid" }
    }
}

function Initialize-ResultChannel {
    param([string]$UserSid)
    if (Test-Path -LiteralPath $resultRoot) {
        Assert-NormalDirectoryChain -Directory $resultRoot
        Assert-ResultAcl -Path $resultRoot -UserSid $UserSid
    }
    else {
        [void][IO.Directory]::CreateDirectory(
            $resultRoot,
            (New-ResultDirectorySecurity -UserSid $UserSid)
        )
        Assert-ResultAcl -Path $resultRoot -UserSid $UserSid
    }
    foreach ($entry in Get-ChildItem -LiteralPath $resultRoot -Force) {
        if ($entry.PSIsContainer -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $entry.Name -notmatch '^[0-9a-f]{64}\.json$') {
            throw "The protected backup-result directory contains an unexpected entry: $($entry.Name)"
        }
        Assert-ResultAcl -Path $entry.FullName -UserSid $UserSid
        if ($entry.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-7)) {
            [IO.File]::Delete($entry.FullName)
        }
    }
    $expectedPath = [IO.Path]::Combine($resultRoot, "$RequestNonce.json")
    $actualPath = [IO.Path]::GetFullPath($ResultPath)
    if (-not (Test-PathEqual -Left $expectedPath -Right $actualPath)) {
        throw 'The backup-manager result path does not match its request nonce.'
    }
    if ([IO.File]::Exists($actualPath) -or [IO.Directory]::Exists($actualPath)) {
        throw 'The backup-manager result target already exists.'
    }
    $script:resultChannelReady = $true
}

function Get-SanitizedError {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'The protected cancellation request failed.'
    }
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $Message.ToCharArray()) {
        if (-not [char]::IsControl($character) -or $character -eq "`t") {
            [void]$builder.Append($character)
        }
    }
    $value = $builder.ToString().Trim()
    if ($value.Length -gt 2000) { $value = $value.Substring(0, 2000) }
    if ([string]::IsNullOrWhiteSpace($value)) { return 'The protected cancellation request failed.' }
    return $value
}

function New-ResultDocument {
    param(
        [bool]$Ok,
        [bool]$Requested,
        [bool]$AlreadyFinished,
        [AllowNull()][string]$ErrorMessage
    )
    return [ordered]@{
        schema_version = 1
        request_nonce = $RequestNonce
        request_digest = $requestDigest
        request_user_sid = $currentSid
        action = 'cancel'
        run_id = $RunId
        ok = $Ok
        requested = $Requested
        already_finished = $AlreadyFinished
        error = if ($Ok) { $null } else { Get-SanitizedError -Message $ErrorMessage }
    }
}

function Write-ManagerResult {
    param(
        [bool]$Ok,
        [bool]$Requested,
        [bool]$AlreadyFinished,
        [AllowNull()][string]$ErrorMessage
    )
    $document = New-ResultDocument -Ok $Ok -Requested $Requested `
        -AlreadyFinished $AlreadyFinished -ErrorMessage $ErrorMessage
    if ($isTestMode) {
        $document | ConvertTo-Json -Compress -Depth 4
        return
    }
    if (-not $resultChannelReady) {
        throw 'The protected backup-result channel is unavailable.'
    }
    $bytes = $utf8.GetBytes(($document | ConvertTo-Json -Depth 4) + "`n")
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
    finally { $stream.Dispose() }
    Assert-ResultAcl -Path $target -UserSid $currentSid
}

function Get-RequestDigest {
    $payload = @(
        $requestDomain,
        $currentSid,
        'cancel',
        $RunId,
        $ExpectedWrapperPid.ToString([Globalization.CultureInfo]::InvariantCulture),
        $ExpectedTaskFingerprint,
        $RequestNonce
    ) -join "`n"
    return Get-Sha256Hex -Bytes $utf8.GetBytes($payload)
}

function Initialize-TrustedScheduledTasksModule {
    if ($isTestMode) { return }
    $manifest = Join-Path $trustedModuleRoot 'ScheduledTasks\ScheduledTasks.psd1'
    Assert-NormalFile -File $manifest
    Import-Module -Name $manifest -Force -ErrorAction Stop
    $loaded = @(Get-Module -Name ScheduledTasks)
    if ($loaded.Count -ne 1) {
        throw 'The trusted Windows ScheduledTasks module did not load exactly once.'
    }
    $loadedPath = [IO.Path]::GetFullPath([string]$loaded[0].Path)
    $trustedPrefix = [IO.Path]::GetFullPath($trustedModuleRoot).TrimEnd('\') + '\'
    if (-not $loadedPath.StartsWith($trustedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "ScheduledTasks loaded from an untrusted path: $loadedPath"
    }
}

function Get-ProtectedTaskSnapshot {
    if ($isTestMode) {
        Assert-NormalFile -File $adapterTaskXmlPath
        $text = [IO.File]::ReadAllText($adapterTaskXmlPath, $utf8)
        $state = [IO.File]::ReadAllText($adapterTaskStatePath, $utf8).Trim()
        return [pscustomobject]@{ Xml = $text; State = $state }
    }
    $task = ScheduledTasks\Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    if ($task.TaskName -ne $taskName -or $task.TaskPath -ne $taskPath) {
        throw 'Task Scheduler returned an unexpected task identity.'
    }
    $xml = [string](ScheduledTasks\Export-ScheduledTask `
        -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop)
    return [pscustomobject]@{ Xml = $xml; State = [string]$task.State }
}

function Read-TaskXmlDocument {
    param([string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml) -or $Xml.Length -gt 4MB) {
        throw 'The protected task XML is empty or oversized.'
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
        throw 'The protected task XML root is invalid.'
    }
    return $document
}

function Get-TaskNamespaceManager {
    param([Xml.XmlDocument]$Document)
    $manager = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $manager.AddNamespace('t', $taskNamespace)
    return ,$manager
}

function Get-RequiredTaskNode {
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

function Get-TaskBoolean {
    param(
        [Xml.XmlNode]$Context,
        [string]$XPath,
        [Xml.XmlNamespaceManager]$NamespaceManager,
        [string]$Description
    )
    $node = Get-RequiredTaskNode -Context $Context -XPath $XPath `
        -NamespaceManager $NamespaceManager -Description $Description
    $text = $node.InnerText.Trim().ToLowerInvariant()
    if ($text -notin @('true', 'false')) {
        throw "The protected task Boolean is invalid: $Description"
    }
    return $text -eq 'true'
}

function Resolve-TaskSid {
    param([string]$Identity)
    try { return ([Security.Principal.SecurityIdentifier]::new($Identity)).Value }
    catch {
        try {
            return ([Security.Principal.NTAccount]::new($Identity)).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
        }
        catch { throw "The protected task principal cannot be resolved: $Identity" }
    }
}

function Assert-StrictProtectedTask {
    param([Xml.XmlDocument]$Document)
    $namespaceManager = Get-TaskNamespaceManager -Document $Document
    $root = $Document.DocumentElement
    $uri = Get-RequiredTaskNode -Context $root -XPath 't:RegistrationInfo/t:URI' `
        -NamespaceManager $namespaceManager -Description 'RegistrationInfo/URI element'
    if ($uri.InnerText.Trim() -ne "\$taskName") {
        throw 'The registered task URI does not identify ResticBackuper.'
    }
    $principals = @($root.SelectNodes('t:Principals/t:Principal', $namespaceManager))
    if ($principals.Count -ne 1) { throw 'The protected task must contain exactly one principal.' }
    $principal = [Xml.XmlNode]$principals[0]
    $principalId = $principal.Attributes['id']
    if ($null -eq $principalId -or [string]::IsNullOrWhiteSpace($principalId.Value)) {
        throw 'The protected task principal is missing its identity label.'
    }
    $userId = Get-RequiredTaskNode -Context $principal -XPath 't:UserId' `
        -NamespaceManager $namespaceManager -Description 'principal UserId element'
    $registeredSid = Resolve-TaskSid -Identity $userId.InnerText.Trim()
    if (-not [string]::Equals($registeredSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The protected task principal differs from the approving Windows account.'
    }
    $logon = Get-RequiredTaskNode -Context $principal -XPath 't:LogonType' `
        -NamespaceManager $namespaceManager -Description 'principal LogonType element'
    $runLevel = Get-RequiredTaskNode -Context $principal -XPath 't:RunLevel' `
        -NamespaceManager $namespaceManager -Description 'principal RunLevel element'
    if ($logon.InnerText.Trim() -ne 'InteractiveToken' -or
        $runLevel.InnerText.Trim() -ne 'HighestAvailable') {
        throw 'The protected task principal is not InteractiveToken/HighestAvailable.'
    }
    $principalChildren = @($principal.SelectNodes('*'))
    if ($principalChildren.Count -ne 3) {
        throw 'The protected task principal contains unexpected fields.'
    }

    $actionsNode = Get-RequiredTaskNode -Context $root -XPath 't:Actions' `
        -NamespaceManager $namespaceManager -Description 'Actions element'
    $context = $actionsNode.Attributes['Context']
    if ($null -eq $context -or $context.Value -ne $principalId.Value) {
        throw 'The protected task action context differs from its principal.'
    }
    $actions = @($actionsNode.SelectNodes('*'))
    if ($actions.Count -ne 1 -or $actions[0].LocalName -ne 'Exec') {
        throw 'The protected task must contain exactly one executable action.'
    }
    $exec = [Xml.XmlNode]$actions[0]
    $command = Get-RequiredTaskNode -Context $exec -XPath 't:Command' `
        -NamespaceManager $namespaceManager -Description 'action Command element'
    $working = Get-RequiredTaskNode -Context $exec -XPath 't:WorkingDirectory' `
        -NamespaceManager $namespaceManager -Description 'action WorkingDirectory element'
    $arguments = @($exec.SelectNodes('t:Arguments', $namespaceManager))
    if ($arguments.Count -gt 1 -or
        ($arguments.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($arguments[0].InnerText)) -or
        -not (Test-PathEqual -Left ([IO.Path]::GetFullPath($command.InnerText.Trim())) -Right $launcherPath) -or
        -not (Test-PathEqual -Left ([IO.Path]::GetFullPath($working.InnerText.Trim()).TrimEnd('\')) -Right $installRoot)) {
        throw 'The protected task action does not match the supervised launcher.'
    }
    foreach ($child in @($exec.SelectNodes('*'))) {
        if ($child.NamespaceURI -ne $taskNamespace -or
            $child.LocalName -notin @('Command', 'Arguments', 'WorkingDirectory')) {
            throw "The protected task action contains an unexpected field: $($child.LocalName)"
        }
    }

    $settings = Get-RequiredTaskNode -Context $root -XPath 't:Settings' `
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
        $node = Get-RequiredTaskNode -Context $settings -XPath ("t:{0}" -f $entry.Key) `
            -NamespaceManager $namespaceManager -Description ("Settings/{0}" -f $entry.Key)
        if ($node.InnerText.Trim() -ne [string]$entry.Value) {
            throw "The protected task has an unsafe Settings/$($entry.Key) value."
        }
    }
    foreach ($name in @(
        'Enabled',
        'StartWhenAvailable',
        'WakeToRun',
        'DisallowStartIfOnBatteries',
        'StopIfGoingOnBatteries'
    )) {
        [void](Get-TaskBoolean -Context $settings -XPath "t:$name" `
            -NamespaceManager $namespaceManager -Description "Settings/$name")
    }

    $triggers = @($root.SelectNodes('t:Triggers/*', $namespaceManager))
    if ($triggers.Count -ne 1 -or $triggers[0].LocalName -ne 'CalendarTrigger') {
        throw 'The protected task must contain exactly one calendar trigger.'
    }
    $trigger = [Xml.XmlNode]$triggers[0]
    $start = Get-RequiredTaskNode -Context $trigger -XPath 't:StartBoundary' `
        -NamespaceManager $namespaceManager -Description 'calendar StartBoundary'
    if (-not (Get-TaskBoolean -Context $trigger -XPath 't:Enabled' `
        -NamespaceManager $namespaceManager -Description 'calendar Enabled')) {
        throw 'The protected calendar trigger is disabled unexpectedly.'
    }
    $parsedStart = [DateTime]::MinValue
    if (-not [DateTime]::TryParse(
        $start.InnerText.Trim(),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsedStart
    ) -or ($parsedStart.TimeOfDay.Ticks % [TimeSpan]::TicksPerMinute) -ne 0) {
        throw 'The protected calendar trigger start time is invalid.'
    }
    $scheduleNodes = @($trigger.SelectNodes('t:ScheduleByDay | t:ScheduleByWeek', $namespaceManager))
    if ($scheduleNodes.Count -ne 1 -or @($trigger.SelectNodes('*')).Count -ne 3) {
        throw 'The protected calendar trigger shape is invalid.'
    }
    $schedule = [Xml.XmlNode]$scheduleNodes[0]
    if ($schedule.LocalName -eq 'ScheduleByDay') {
        $interval = Get-RequiredTaskNode -Context $schedule -XPath 't:DaysInterval' `
            -NamespaceManager $namespaceManager -Description 'daily DaysInterval'
        if ($interval.InnerText.Trim() -ne '1' -or @($schedule.SelectNodes('*')).Count -ne 1) {
            throw 'The protected daily trigger interval is invalid.'
        }
    }
    else {
        $weeks = Get-RequiredTaskNode -Context $schedule -XPath 't:WeeksInterval' `
            -NamespaceManager $namespaceManager -Description 'weekly WeeksInterval'
        $days = Get-RequiredTaskNode -Context $schedule -XPath 't:DaysOfWeek' `
            -NamespaceManager $namespaceManager -Description 'weekly DaysOfWeek'
        if ($weeks.InnerText.Trim() -ne '1' -or @($schedule.SelectNodes('*')).Count -ne 2 -or
            @($days.SelectNodes('*')).Count -lt 1) {
            throw 'The protected weekly trigger is invalid.'
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($day in @($days.SelectNodes('*'))) {
            if ($day.NamespaceURI -ne $taskNamespace -or
                $day.LocalName -notin @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') -or
                -not $seen.Add($day.LocalName)) {
                throw 'The protected weekly trigger contains an invalid selected day.'
            }
        }
    }
}

function Get-TaskFingerprint {
    param([Xml.XmlDocument]$Document)
    return Get-Sha256Hex -Bytes $utf8.GetBytes(
        $taskFingerprintDomain + "`n" + $Document.DocumentElement.OuterXml
    )
}

function Test-ValidRunId {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and
        $Value.Length -le 128 -and
        $Value -match '^[A-Za-z0-9_.:-]+$'
}

function ConvertTo-RequiredFileTime {
    param([object]$Value, [string]$Description)
    if ($Value -isnot [string] -or $Value -notmatch '^[1-9][0-9]{0,18}$') {
        throw "$Description must be a bounded unsigned decimal string."
    }
    $parsed = [UInt64]0
    if (-not [UInt64]::TryParse(
        $Value,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    ) -or $parsed -gt [UInt64][Int64]::MaxValue) {
        throw "$Description is outside the supported FILETIME range."
    }
    return $parsed.ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Test-UtcTimestamp {
    param([object]$Value)
    if ($Value -isnot [string] -or $Value.Length -gt 64 -or $Value -notmatch 'Z$') { return $false }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact(
        [string]$Value,
        [string[]]@("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'"),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal,
        [ref]$parsed
    )
}

function Read-ProtectedStatus {
    $script:statusReadCount++
    $sourcePath = $statusPath
    if ($isTestMode -and $statusReadCount -ge 2 -and
        $TestScenario -in @('FinishBeforeSignal', 'ReplaceBeforeSignal')) {
        $sourcePath = $adapterStatusAfterPath
    }
    if ($sourcePath -eq $statusPath) {
        Assert-ProtectedPath -Path $statusPath -AdapterKey 'status' -Kind file -AllowUserOwner
    }
    else {
        Assert-NormalFile -File $sourcePath
    }
    $document = Read-BoundedJsonObject -File $sourcePath -MaximumBytes 4MB `
        -Description 'The protected current backup status'
    if ($document.schema_version -isnot [int] -or $document.schema_version -ne 1) {
        throw 'The protected current backup status schema is invalid.'
    }
    $statusRunId = Get-RequiredProperty -Object $document -Name 'run_id' -DocumentName 'The protected current backup status'
    $state = Get-RequiredProperty -Object $document -Name 'state' -DocumentName 'The protected current backup status'
    if ($statusRunId -isnot [string] -or -not (Test-ValidRunId -Value $statusRunId) -or
        $state -isnot [string] -or $state.Length -gt 64) {
        throw 'The protected current backup status identity is invalid.'
    }
    if (-not [string]::Equals($statusRunId, $RunId, [StringComparison]::Ordinal)) {
        throw 'The protected current backup status belongs to another run.'
    }
    $isActive = $state -in $activeStates
    $isTerminal = $state -in $terminalStates
    if (-not $isActive -and -not $isTerminal) {
        throw "The protected current backup state is invalid: $state"
    }

    $wrapperPid = Get-RequiredProperty -Object $document -Name 'wrapper_pid' -DocumentName 'The protected current backup status'
    $launcherPid = Get-RequiredProperty -Object $document -Name 'launcher_pid' -DocumentName 'The protected current backup status'
    if ($wrapperPid -isnot [int] -or $wrapperPid -le 0 -or
        $launcherPid -isnot [int] -or $launcherPid -le 0) {
        throw 'The protected current backup process IDs are invalid.'
    }
    $wrapperStart = ConvertTo-RequiredFileTime `
        -Value (Get-RequiredProperty -Object $document -Name 'wrapper_start_filetime' -DocumentName 'The protected current backup status') `
        -Description 'The protected wrapper start identity'
    $launcherStart = ConvertTo-RequiredFileTime `
        -Value (Get-RequiredProperty -Object $document -Name 'launcher_start_filetime' -DocumentName 'The protected current backup status') `
        -Description 'The protected launcher start identity'

    $channelId = Get-RequiredProperty -Object $document -Name 'cancel_channel_id' -DocumentName 'The protected current backup status'
    $channelFingerprint = Get-RequiredProperty -Object $document -Name 'cancel_channel_fingerprint' -DocumentName 'The protected current backup status'
    if ($channelId -isnot [string] -or $channelId -notmatch '^[0-9a-f]{64}$' -or
        $channelFingerprint -isnot [string] -or $channelFingerprint -notmatch '^[0-9a-f]{64}$') {
        throw 'The protected cancellation channel identity is invalid.'
    }
    $eventName = $cancelEventPrefix + $channelId
    $computedFingerprint = Get-Sha256Hex -Bytes $utf8.GetBytes($eventName)
    if (-not [string]::Equals(
        $computedFingerprint,
        $channelFingerprint,
        [StringComparison]::Ordinal
    )) {
        throw 'The protected cancellation channel fingerprint is invalid.'
    }

    $finishedUtc = Get-RequiredProperty -Object $document -Name 'finished_utc' -DocumentName 'The protected current backup status'
    $exitCode = Get-RequiredProperty -Object $document -Name 'exit_code' -DocumentName 'The protected current backup status'
    $cancelRequestedUtc = Get-RequiredProperty -Object $document -Name 'cancel_requested_utc' -DocumentName 'The protected current backup status'
    $cancelSignalSentUtc = Get-RequiredProperty -Object $document -Name 'cancel_signal_sent_utc' -DocumentName 'The protected current backup status'
    $cancelOutcome = Get-RequiredProperty -Object $document -Name 'cancel_outcome' -DocumentName 'The protected current backup status'
    foreach ($value in @($cancelRequestedUtc, $cancelSignalSentUtc)) {
        if ($null -ne $value -and -not (Test-UtcTimestamp -Value $value)) {
            throw 'The protected cancellation acknowledgement timestamp is invalid.'
        }
    }
    if ($null -ne $cancelSignalSentUtc -and $null -eq $cancelRequestedUtc) {
        throw 'The protected status reports a cancellation signal without acknowledgement.'
    }
    if ($null -ne $cancelOutcome -and
        ($cancelOutcome -isnot [string] -or [string]::IsNullOrWhiteSpace($cancelOutcome) -or $cancelOutcome.Length -gt 128)) {
        throw 'The protected cancellation outcome is invalid.'
    }
    if ($isActive) {
        if ($null -ne $finishedUtc -or $null -ne $exitCode) {
            throw 'The protected active status contains terminal fields.'
        }
        if ($null -ne $cancelOutcome) {
            throw 'The protected cancellation channel was already resolved and cannot be reused.'
        }
        if ($state -eq 'cancelling' -and $null -eq $cancelRequestedUtc) {
            throw 'The protected cancelling state lacks wrapper acknowledgement.'
        }
    }
    else {
        if (-not (Test-UtcTimestamp -Value $finishedUtc) -or $exitCode -isnot [int]) {
            throw 'The protected terminal status lacks a valid finish result.'
        }
        if ($state -in @('cancelled','cancel_failed') -and $cancelOutcome -isnot [string]) {
            throw 'The protected cancellation terminal state lacks an outcome.'
        }
    }
    return [pscustomobject]@{
        RunId = [string]$statusRunId
        State = [string]$state
        IsActive = [bool]$isActive
        IsTerminal = [bool]$isTerminal
        WrapperPid = [int]$wrapperPid
        WrapperStartFileTime = [string]$wrapperStart
        LauncherPid = [int]$launcherPid
        LauncherStartFileTime = [string]$launcherStart
        ChannelId = [string]$channelId
        ChannelFingerprint = [string]$channelFingerprint
        EventName = [string]$eventName
    }
}

function Get-ProcessIdentity {
    param([int]$ProcessId)
    if ($isTestMode) {
        $document = Read-BoundedJsonObject -File $adapterProcessesPath -MaximumBytes 1MB `
            -Description 'The disposable process adapter'
        if ($document.schema_version -ne 1) { throw 'The disposable process adapter schema is invalid.' }
        $matches = @(@($document.processes) | Where-Object { $_.pid -is [int] -and $_.pid -eq $ProcessId })
        if ($matches.Count -ne 1 -or $matches[0].running -isnot [bool] -or -not [bool]$matches[0].running) {
            throw "Protected process is missing or no longer running: $ProcessId"
        }
        return [pscustomobject]@{
            ProcessId = $ProcessId
            Executable = [string]$matches[0].executable
            StartFileTime = ConvertTo-RequiredFileTime -Value $matches[0].start_filetime `
                -Description "Disposable process $ProcessId start identity"
        }
    }
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($ProcessId)
        if ($process.HasExited) { throw "Protected process already exited: $ProcessId" }
        $executable = [IO.Path]::GetFullPath($process.MainModule.FileName)
        $startFileTime = $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(
            [Globalization.CultureInfo]::InvariantCulture
        )
        if ($process.HasExited) { throw "Protected process exited during identity validation: $ProcessId" }
        return [pscustomobject]@{
            ProcessId = $ProcessId
            Executable = $executable
            StartFileTime = $startFileTime
        }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Assert-ProcessIdentity {
    param(
        [int]$ProcessId,
        [string]$ExpectedExecutable,
        [string]$ExpectedStartFileTime,
        [string]$Description
    )
    $identity = Get-ProcessIdentity -ProcessId $ProcessId
    if (-not (Test-PathEqual -Left ([IO.Path]::GetFullPath($identity.Executable)) -Right $ExpectedExecutable) -or
        -not [string]::Equals($identity.StartFileTime, $ExpectedStartFileTime, [StringComparison]::Ordinal)) {
        throw "$Description process identity does not match the protected status."
    }
}

function Assert-EventSecurity {
    param([Security.AccessControl.EventWaitHandleSecurity]$Security)
    $owner = $Security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    $group = $Security.GetGroup([Security.Principal.SecurityIdentifier]).Value
    if ($owner -ne 'S-1-5-32-544' -or $group -ne 'S-1-5-32-544' -or
        -not $Security.AreAccessRulesProtected) {
        throw 'The cancellation event has an unsafe owner, group, or inherited DACL.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $Security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin @('S-1-5-18','S-1-5-32-544') -or
            ($rule.EventWaitHandleRights -band [Security.AccessControl.EventWaitHandleRights]::FullControl) -ne
                [Security.AccessControl.EventWaitHandleRights]::FullControl) {
            throw "The cancellation event has an unsafe ACL rule for $sid."
        }
        [void]$seen.Add($sid)
    }
    if ($seen.Count -ne 2 -or -not $seen.Contains('S-1-5-18') -or
        -not $seen.Contains('S-1-5-32-544')) {
        throw 'The cancellation event ACL is missing its exact SYSTEM/Administrators rules.'
    }
}

function Open-ProtectedCancellationEvent {
    param([pscustomobject]$Status)
    $rights = [Security.AccessControl.EventWaitHandleRights]::ReadPermissions -bor `
        [Security.AccessControl.EventWaitHandleRights]::Modify -bor `
        [Security.AccessControl.EventWaitHandleRights]::Synchronize
    if ($isTestMode) {
        $document = Read-BoundedJsonObject -File $adapterChannelPath -MaximumBytes 1MB `
            -Description 'The disposable cancellation-channel adapter'
        if ($document.schema_version -ne 1 -or $document.exists -isnot [bool] -or
            -not [bool]$document.exists) {
            throw 'The protected cancellation event does not exist.'
        }
        if ($document.event_name -isnot [string] -or
            -not [string]::Equals([string]$document.event_name, $Status.EventName, [StringComparison]::Ordinal) -or
            $document.required_rights -isnot [int] -or $document.required_rights -ne [int]$rights) {
            throw 'The cancellation-event adapter identity or access mask is invalid.'
        }
        if ($document.open_denied -isnot [bool] -or [bool]$document.open_denied) {
            throw 'Opening the protected cancellation event was denied.'
        }
        if ($document.owner_sid -ne 'S-1-5-32-544' -or
            $document.group_sid -ne 'S-1-5-32-544' -or
            $document.dacl_protected -isnot [bool] -or -not [bool]$document.dacl_protected -or
            $document.system_full -isnot [bool] -or -not [bool]$document.system_full -or
            $document.administrators_full -isnot [bool] -or -not [bool]$document.administrators_full -or
            $document.unexpected_ace -isnot [bool] -or [bool]$document.unexpected_ace) {
            throw 'The cancellation-event adapter security descriptor is unsafe.'
        }
        return [pscustomobject]@{ Adapter = $true; Document = $document; Rights = [int]$rights; Status = $Status }
    }
    $event = [Threading.EventWaitHandle]::OpenExisting($Status.EventName, $rights)
    try {
        Assert-EventSecurity -Security $event.GetAccessControl()
    }
    catch {
        $event.Dispose()
        throw
    }
    return [pscustomobject]@{ Adapter = $false; Event = $event; Rights = [int]$rights; Status = $Status }
}

function Set-ProtectedCancellationEvent {
    param([pscustomobject]$Opened)
    if ($Opened.Adapter) {
        if ($Opened.Document.signal_failure -isnot [bool] -or [bool]$Opened.Document.signal_failure) {
            throw 'The protected cancellation event could not be signaled.'
        }
        if (Test-Path -LiteralPath $adapterSignalPath) {
            throw 'The disposable cancellation adapter was already signaled.'
        }
        $signal = [ordered]@{
            schema_version = 1
            event_name = $Opened.Status.EventName
            cancel_channel_id = $Opened.Status.ChannelId
            requested_rights = [int]$Opened.Rights
            set = $true
        }
        [IO.File]::WriteAllText(
            $adapterSignalPath,
            ($signal | ConvertTo-Json -Compress),
            $utf8
        )
        return
    }
    if (-not $Opened.Event.Set()) {
        throw 'The protected cancellation event returned an unsuccessful signal result.'
    }
}

function Close-ProtectedCancellationEvent {
    param([pscustomobject]$Opened)
    if ($null -ne $Opened -and -not $Opened.Adapter -and $null -ne $Opened.Event) {
        $Opened.Event.Dispose()
    }
}

function Assert-StatusBinding {
    param([pscustomobject]$Status)
    if ($Status.WrapperPid -ne $ExpectedWrapperPid) {
        throw 'The protected current backup wrapper PID differs from the reviewed run.'
    }
    Assert-ProcessIdentity -ProcessId $Status.WrapperPid -ExpectedExecutable $pythonPath `
        -ExpectedStartFileTime $Status.WrapperStartFileTime -Description 'Backup wrapper'
    Assert-ProcessIdentity -ProcessId $Status.LauncherPid -ExpectedExecutable $launcherPath `
        -ExpectedStartFileTime $Status.LauncherStartFileTime -Description 'Task launcher'
}

function Test-RaceFinished {
    try {
        $latest = Read-ProtectedStatus
        return $latest.IsTerminal
    }
    catch { return $false }
}

try {
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'ResticBackuper cancellation requires 64-bit Windows PowerShell 5.1.'
    }
    if ($PSVersionTable.PSVersion.Major -ne 5) {
        throw 'ResticBackuper cancellation must run in Windows PowerShell 5.1.'
    }
    if (-not $isTestMode -and -not (Test-Administrator)) {
        throw 'Backup cancellation requests must run elevated.'
    }
    if (-not $isTestMode -and $TestScenario -ne 'None') {
        throw 'Cancellation race injection is available only for disposable tests.'
    }
    if (-not (Test-ValidRunId -Value $RunId)) {
        throw 'The requested backup run identifier is invalid.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    if ([string]::IsNullOrWhiteSpace($ExpectedUserSid) -or
        -not [string]::Equals($ExpectedUserSid, $currentSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approve elevation with the same Windows account that requested cancellation.'
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Backup cancellation must execute as an installed script, not dot-sourced.'
    }
    $actualScript = [IO.Path]::GetFullPath($PSCommandPath)
    if (-not (Test-PathEqual -Left $actualScript -Right $managerPath)) {
        throw "Refusing to control a backup outside the protected installation: $actualScript"
    }

    Assert-ProtectedPath -Path $installRoot -AdapterKey 'install_root' -Kind directory -RequireProtectedRoot
    Assert-ProtectedPath -Path $managerPath -AdapterKey 'manager' -Kind file
    Assert-ProtectedPath -Path $launcherPath -AdapterKey 'launcher' -Kind file
    Assert-ProtectedPath -Path $pythonPath -AdapterKey 'python' -Kind file
    Assert-ProtectedPath -Path $stateRoot -AdapterKey 'state_root' -Kind directory -RequireProtectedRoot

    $requestDigest = Get-RequestDigest
    if (-not $isTestMode) {
        Initialize-ResultChannel -UserSid $currentSid
    }
    Initialize-TrustedScheduledTasksModule

    $taskSnapshot = Get-ProtectedTaskSnapshot
    $taskDocument = Read-TaskXmlDocument -Xml $taskSnapshot.Xml
    Assert-StrictProtectedTask -Document $taskDocument
    $taskFingerprint = Get-TaskFingerprint -Document $taskDocument
    if (-not [string]::Equals(
        $taskFingerprint,
        $ExpectedTaskFingerprint,
        [StringComparison]::Ordinal
    )) {
        throw 'The protected backup task changed after the cancellation request was reviewed.'
    }

    $status = Read-ProtectedStatus
    if ($status.IsTerminal) {
        Write-ManagerResult -Ok $true -Requested $false -AlreadyFinished $true -ErrorMessage $null
        exit 0
    }
    if ($taskSnapshot.State -ne 'Running') {
        $latest = Read-ProtectedStatus
        if ($latest.IsTerminal) {
            Write-ManagerResult -Ok $true -Requested $false -AlreadyFinished $true -ErrorMessage $null
            exit 0
        }
        throw "The protected task is $($taskSnapshot.State), but the reviewed run is still marked active."
    }
    Assert-StatusBinding -Status $status

    $openedEvent = $null
    try {
        try { $openedEvent = Open-ProtectedCancellationEvent -Status $status }
        catch {
            $openError = $_.Exception.Message
            if (Test-RaceFinished) {
                Write-ManagerResult -Ok $true -Requested $false -AlreadyFinished $true -ErrorMessage $null
                exit 0
            }
            throw $openError
        }

        $latestStatus = Read-ProtectedStatus
        if ($latestStatus.IsTerminal) {
            Write-ManagerResult -Ok $true -Requested $false -AlreadyFinished $true -ErrorMessage $null
            exit 0
        }
        if ($latestStatus.WrapperPid -ne $status.WrapperPid -or
            $latestStatus.WrapperStartFileTime -ne $status.WrapperStartFileTime -or
            $latestStatus.LauncherPid -ne $status.LauncherPid -or
            $latestStatus.LauncherStartFileTime -ne $status.LauncherStartFileTime -or
            $latestStatus.ChannelId -ne $status.ChannelId -or
            $latestStatus.ChannelFingerprint -ne $status.ChannelFingerprint) {
            throw 'The protected cancellation identity changed before signaling.'
        }
        $latestTask = Get-ProtectedTaskSnapshot
        $latestTaskDocument = Read-TaskXmlDocument -Xml $latestTask.Xml
        Assert-StrictProtectedTask -Document $latestTaskDocument
        if ($latestTask.State -ne 'Running' -or
            (Get-TaskFingerprint -Document $latestTaskDocument) -ne $ExpectedTaskFingerprint) {
            if (Test-RaceFinished) {
                Write-ManagerResult -Ok $true -Requested $false -AlreadyFinished $true -ErrorMessage $null
                exit 0
            }
            throw 'The protected task stopped or changed before cancellation was signaled.'
        }
        Assert-StatusBinding -Status $latestStatus
        try { Set-ProtectedCancellationEvent -Opened $openedEvent }
        catch {
            $signalError = $_.Exception.Message
            if (Test-RaceFinished) {
                Write-ManagerResult -Ok $true -Requested $false -AlreadyFinished $true -ErrorMessage $null
                exit 0
            }
            throw $signalError
        }
    }
    finally {
        Close-ProtectedCancellationEvent -Opened $openedEvent
    }

    Write-ManagerResult -Ok $true -Requested $true -AlreadyFinished $false -ErrorMessage $null
}
catch {
    if ($isTestMode) {
        if ([string]::IsNullOrWhiteSpace($requestDigest) -and $null -ne $currentSid) {
            try { $requestDigest = Get-RequestDigest }
            catch { }
        }
        Write-ManagerResult -Ok $false -Requested $false -AlreadyFinished $false `
            -ErrorMessage $_.Exception.Message
    }
    elseif ($resultChannelReady) {
        try {
            Write-ManagerResult -Ok $false -Requested $false -AlreadyFinished $false `
                -ErrorMessage $_.Exception.Message
        }
        catch { }
    }
    exit 1
}
