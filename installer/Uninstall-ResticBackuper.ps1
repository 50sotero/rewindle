[CmdletBinding()]
param(
    [switch]$Unattended,
    [string]$ExpectedUserSid,
    # Machine-readable setup backend; see docs/setup-contract.md.
    [string]$ProgressPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
$invocationParameters = @{} + $PSBoundParameters

if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'ResticBackuper requires 64-bit Windows and a 64-bit Windows PowerShell process.'
}
if ($ProgressPath -and -not $Unattended) {
    throw '-ProgressPath requires -Unattended.'
}

$productName = 'ResticBackuper'
$productDisplayName = 'Rewindle'
$backupTaskName = 'ResticBackuper'
$dashboardTaskName = 'ResticBackuperDashboard'
$cloudVerificationTaskName = 'ResticBackuperGoogleDriveSync'
$primaryTaskEvidenceName = 'scheduled-task.xml'
$cloudTaskEvidenceName = 'google-drive-verification-task.xml'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$systemDirectory = [Environment]::SystemDirectory
$windowsPowerShell = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
$installRoot = Join-Path $programFilesRoot $productName
$stateRoot = Join-Path $programDataRoot $productName
$cloudVerificationRoot = Join-Path (
    $programDataRoot
) 'ResticBackuperCloudVerification'
$installRegistry = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResticBackuper'
$startMenuShortcut = Join-Path $programDataRoot 'Microsoft\Windows\Start Menu\Programs\ResticBackuper.lnk'
$uninstallWarnings = [Collections.Generic.List[object]]::new()
$removedTasks = [Collections.Generic.List[string]]::new()

# A finding is a stable code with one plain sentence; the console text stays the message this uninstaller has always printed.
function Stop-UninstallValidation {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$Console
    )
    $finding = [pscustomobject][ordered]@{ code = $Code; message = $Message }
    $finding.PSObject.TypeNames.Insert(0, 'Rewindle.UninstallFinding')
    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Console),
        "Rewindle.$Code",
        [Management.Automation.ErrorCategory]::InvalidData,
        $finding
    )
}

function Get-UninstallFinding {
    param([Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -ne $ErrorRecord -and
        $null -ne $ErrorRecord.TargetObject -and
        $ErrorRecord.TargetObject.PSObject.TypeNames -contains 'Rewindle.UninstallFinding') {
        return $ErrorRecord.TargetObject
    }
    return $null
}

# region progress-feed
# This region is byte-identical in Install-ResticBackuper.ps1 and Uninstall-ResticBackuper.ps1; tests/test_setup_contract.py keeps
# the two copies equal. It writes the optional -ProgressPath feed (docs/setup-contract.md, section 3) and validates output paths.
$script:FeedStream = $null
$script:FeedPath = $null
$script:FeedSequence = 0
$script:FeedResultWritten = $false
$script:FeedCurrentPhase = $null

function Initialize-FeedNative {
    if (-not ('ResticBackuperSetup.NativePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace ResticBackuperSetup {
  public static class NativePath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetLongPathNameW(string shortPath, StringBuilder longPath, uint size);
    public static string Long(string path) {
      StringBuilder buffer = new StringBuilder(1024);
      uint length = GetLongPathNameW(path, buffer, (uint)buffer.Capacity);
      if (length == 0) { return path; }
      if (length > buffer.Capacity) {
        buffer = new StringBuilder((int)length + 1);
        length = GetLongPathNameW(path, buffer, (uint)buffer.Capacity);
        if (length == 0) { return path; }
      }
      return buffer.ToString();
    }
  }
}
'@
    }
}

function Get-FeedLongPath {
    param([string]$Path)
    Initialize-FeedNative
    $long = [ResticBackuperSetup.NativePath]::Long([IO.Path]::GetFullPath($Path))
    $root = [IO.Path]::GetPathRoot($long)
    if ($long.Length -gt $root.Length) {
        $long = $long.TrimEnd('\')
    }
    return $long
}

function Test-FeedWithin {
    param(
        [string]$Candidate,
        [string]$Parent,
        [switch]$Strict
    )
    $candidatePath = (Get-FeedLongPath $Candidate).TrimEnd('\') + '\'
    $parentPath = (Get-FeedLongPath $Parent).TrimEnd('\') + '\'
    if ($Strict -and $candidatePath.Length -le $parentPath.Length) {
        return $false
    }
    return $candidatePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-FeedNoReparse {
    param(
        [string]$Path,
        [string]$Label
    )
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Label must not pass through a reparse point (link or junction): $current"
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Get-FeedProfilePath {
    param([string]$Sid)
    try {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
        $value = [string](Get-ItemProperty -LiteralPath $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($value))
    }
    catch {
        return $null
    }
}

function Get-FeedOwnerSid {
    param([string]$Path)
    $security = [IO.Directory]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Owner)
    $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
    if ($null -eq $owner) { return $null }
    return $owner.Value
}

# Validates a file the caller asked this script to create: absolute local path, expected extension, an existing folder inside
# one of the allowed roots, no reparse point anywhere in the path, nothing at the path yet and (optionally) every folder below
# the root owned by one SID. It returns the full path and never creates anything.
function Resolve-SafeOutputPath {
    param(
        [string]$Path,
        [string]$Label,
        [string]$Extension,
        [string[]]$AllowedRoots,
        [switch]$RequireStrictlyBelow,
        [string]$RequiredOwnerSid
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is required."
    }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "$Label must be an absolute path on a local drive: $Path"
    }
    try {
        $full = [IO.Path]::GetFullPath($Path)
    }
    catch {
        throw "$Label is not a valid path: $Path"
    }
    $leaf = Split-Path -Leaf $full
    if (-not [string]::Equals([IO.Path]::GetExtension($leaf), $Extension, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "$Label must be a file name ending in $Extension : $full"
    }
    $parent = Split-Path -Parent $full
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "The folder for $Label does not exist: $parent"
    }
    # The deepest allowed root that contains the folder wins, so a per-session temporary folder (...\Temp\1, say) is the root and
    # only the folders below it have to belong to the expected user.
    $containedIn = $null
    foreach ($root in @($AllowedRoots | Where-Object { $_ })) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        if (Test-FeedWithin -Candidate $parent -Parent $root -Strict:$RequireStrictlyBelow) {
            if ($null -eq $containedIn -or (Get-FeedLongPath $root).Length -gt (Get-FeedLongPath $containedIn).Length) {
                $containedIn = $root
            }
        }
    }
    if ($null -eq $containedIn) {
        throw "$Label must be inside the temporary folder of the account that runs setup: $full"
    }
    Assert-FeedNoReparse -Path $full -Label $Label
    if ($RequiredOwnerSid) {
        $directory = [IO.DirectoryInfo]::new((Get-FeedLongPath $parent))
        $rootPath = (Get-FeedLongPath $containedIn).TrimEnd('\')
        while ($null -ne $directory -and (Test-FeedWithin -Candidate $directory.FullName -Parent $rootPath -Strict)) {
            if ((Get-FeedOwnerSid -Path $directory.FullName) -ne $RequiredOwnerSid) {
                throw "$Label must be in a folder owned by the account that started setup: $($directory.FullName)"
            }
            $directory = $directory.Parent
        }
    }
    if (Test-Path -LiteralPath $full) {
        throw "$Label already exists; setup only creates new files: $full"
    }
    return $full
}

function Open-ProgressFeed {
    param(
        [string]$Path,
        [string]$ExpectedSid
    )
    if ($null -ne $script:FeedStream) {
        throw 'The progress feed is already open.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedSid)) {
        throw '-ProgressPath requires -ExpectedUserSid.'
    }
    try {
        $expected = [Security.Principal.SecurityIdentifier]::new($ExpectedSid)
    }
    catch {
        throw '-ExpectedUserSid is not a valid Windows security identifier.'
    }
    $roots = @()
    $profilePath = Get-FeedProfilePath -Sid $expected.Value
    if ($profilePath) {
        $roots += (Join-Path $profilePath 'AppData\Local\Temp')
    }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $expected.Value) {
        $processTemp = [IO.Path]::GetTempPath()
        if (-not $profilePath -or (Test-FeedWithin -Candidate $processTemp -Parent $profilePath)) {
            $roots += $processTemp
        }
    }
    if ($roots.Count -eq 0) {
        throw 'Could not determine the temporary folder of the expected user.'
    }
    $full = Resolve-SafeOutputPath -Path $Path -Label '-ProgressPath' -Extension '.jsonl' `
        -AllowedRoots $roots -RequireStrictlyBelow -RequiredOwnerSid $expected.Value
    # The file takes the access rules of its folder, which lies in the expected user's own temporary folder, so that user can read
    # it and delete it afterwards whichever account (an administrator, for example) creates it.
    $rights = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::ReadAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Synchronize
    $stream = [IO.FileStream]::new($full, [IO.FileMode]::CreateNew, $rights, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
    try {
        Assert-FeedNoReparse -Path $full -Label '-ProgressPath'
    }
    catch {
        $stream.Dispose()
        throw
    }
    $script:FeedStream = $stream
    $script:FeedPath = $full
    $script:FeedSequence = 0
    $script:FeedResultWritten = $false
    $script:FeedCurrentPhase = $null
}

function Write-FeedLine {
    param([Parameter(Mandatory)][Collections.IDictionary]$Body)
    if ($null -eq $script:FeedStream) { return }
    try {
        $script:FeedSequence++
        $line = [ordered]@{
            schema = 'Rewindle.InstallProgress.v1'
            seq = $script:FeedSequence
            time = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        }
        foreach ($key in $Body.Keys) {
            $line[$key] = $Body[$key]
        }
        $text = (ConvertTo-Json -InputObject $line -Compress -Depth 6) + "`n"
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
        $script:FeedStream.Write($bytes, 0, $bytes.Length)
        $script:FeedStream.Flush($true)
    }
    catch {
        # A progress file that stops accepting lines must never stop an installation that is otherwise healthy.
        try { $script:FeedStream.Dispose() } catch { }
        $script:FeedStream = $null
    }
}

function Write-FeedPhase {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('started', 'completed', 'skipped', 'failed')][string]$State,
        [Parameter(Mandatory)][string]$Title,
        [string]$Detail
    )
    if ($State -eq 'started') {
        $script:FeedCurrentPhase = $Phase
    }
    elseif ($script:FeedCurrentPhase -eq $Phase) {
        $script:FeedCurrentPhase = $null
    }
    Write-FeedLine ([ordered]@{
        type = 'phase'
        phase = $Phase
        state = $State
        title = $Title
        detail = if ([string]::IsNullOrEmpty($Detail)) { $null } else { $Detail }
    })
}

function Write-FeedResult {
    param(
        [Parameter(Mandatory)][bool]$Ok,
        $ErrorInfo,
        [Collections.IDictionary]$Fields
    )
    if ($script:FeedResultWritten) { return }
    $script:FeedResultWritten = $true
    $line = [ordered]@{
        type = 'result'
        ok = $Ok
        error = $ErrorInfo
    }
    if ($null -ne $Fields) {
        foreach ($key in $Fields.Keys) {
            $line[$key] = $Fields[$key]
        }
    }
    Write-FeedLine $line
}

function Close-ProgressFeed {
    if ($null -ne $script:FeedStream) {
        try { $script:FeedStream.Dispose() } catch { }
        $script:FeedStream = $null
    }
}
# endregion progress-feed

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($Value.IndexOf([char]0) -ge 0 -or $Value.Contains('"')) {
        throw 'Uninstaller arguments cannot contain a quote or NUL character.'
    }
    $trailingBackslashes = [regex]::Match($Value, '\\+$').Value
    return '"' + $Value + $trailingBackslashes + '"'
}

function Invoke-SelfElevation {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $PSCommandPath),
        '-ExpectedUserSid', (Quote-ProcessArgument $sid)
    )
    if ($invocationParameters.ContainsKey('ProgressPath')) {
        $arguments += @('-ProgressPath', (Quote-ProcessArgument $ProgressPath))
    }
    if ($Unattended) {
        $arguments += '-Unattended'
    }
    $process = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $arguments `
        -Verb RunAs `
        -WindowStyle Normal `
        -Wait `
        -PassThru
    exit $process.ExitCode
}

function Get-NormalizedPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Read-Utf8Json {
    param([string]$Path)

    $text = [IO.File]::ReadAllText(
        [IO.Path]::GetFullPath($Path),
        [Text.UTF8Encoding]::new($false, $true)
    )
    return $text | ConvertFrom-Json
}

function Assert-NormalDirectory {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a normal, non-reparse directory: $Path"
    }
}

function Assert-MicrosoftSignedExecutable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Windows executable is missing: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw "Required Windows executable did not pass Microsoft signature validation: $Path"
    }
}

function Import-TrustedScheduledTasksModule {
    $manifest = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\Modules\ScheduledTasks\ScheduledTasks.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "The protected Windows ScheduledTasks module is missing: $manifest"
    }
    $previousVariable = Get-Variable -Name PSModuleAutoLoadingPreference -ErrorAction SilentlyContinue
    $previousAutoLoading = if ($null -eq $previousVariable) { 'All' } else { [string]$previousVariable.Value }
    try {
        $script:PSModuleAutoLoadingPreference = 'None'
        Import-Module -Name $manifest -Force -ErrorAction Stop
    }
    finally {
        $script:PSModuleAutoLoadingPreference = $previousAutoLoading
    }
}

function Assert-OwnedRuntime {
    $expected = Get-NormalizedPath (Join-Path $programFilesRoot $productName)
    $actual = Get-NormalizedPath $installRoot
    if ($actual -ne $expected) {
        throw "Refusing unexpected install path: $actual"
    }
    if (-not (Test-Path -LiteralPath $actual)) {
        Stop-UninstallValidation -Code 'not_installed' `
            -Message "Rewindle's program files were not found on this PC, so there is nothing to remove." `
            -Console "Rewindle is not installed: $actual does not exist."
    }
    Assert-NormalDirectory -Path $actual

    $notOwned = 'Rewindle could not confirm that the program folder is its own, so nothing was removed.'
    $manifestPath = Join-Path $actual 'runtime-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Stop-UninstallValidation -Code 'install_not_owned' -Message $notOwned `
            -Console 'The runtime manifest is missing; refusing recursive removal.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.product -ne $productName -or $manifest.file_count -ne @($manifest.files).Count) {
        Stop-UninstallValidation -Code 'install_not_owned' -Message $notOwned `
            -Console 'The runtime manifest is not a valid ResticBackuper manifest.'
    }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$allowed.Add('runtime-manifest.json')
    [void]$allowed.Add($primaryTaskEvidenceName)
    [void]$allowed.Add($cloudTaskEvidenceName)
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.relative_path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..' -or -not $allowed.Add($relative)) {
            Stop-UninstallValidation -Code 'install_not_owned' -Message $notOwned `
                -Console "The runtime manifest contains an unsafe or duplicate path: $relative"
        }
    }

    foreach ($item in Get-ChildItem -LiteralPath $actual -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Stop-UninstallValidation -Code 'install_not_owned' -Message $notOwned `
                -Console "The runtime contains a reparse point; refusing recursive removal: $($item.FullName)"
        }
        if (-not $item.PSIsContainer) {
            $relative = $item.FullName.Substring($actual.Length + 1)
            if (-not $allowed.Contains($relative)) {
                Stop-UninstallValidation -Code 'install_not_owned' -Message $notOwned `
                    -Console "The runtime contains an unowned file; refusing recursive removal: $relative"
            }
        }
    }
    return $manifest
}

function Assert-OwnedTask {
    param(
        [string]$TaskName,
        [string]$ExpectedExecutable,
        [string]$ExpectedArguments = ''
    )
    $notOwned = "A Windows scheduled task named $TaskName exists but was not created by Rewindle, so nothing was removed."
    $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) {
        return $null
    }
    if ($tasks.Count -ne 1) {
        Stop-UninstallValidation -Code 'task_not_owned' -Message $notOwned `
            -Console "More than one scheduled task uses the protected name: $TaskName"
    }
    $task = $tasks[0]
    $expected = Get-NormalizedPath $ExpectedExecutable
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) {
        Stop-UninstallValidation -Code 'task_not_owned' -Message $notOwned `
            -Console "Scheduled task '$TaskName' is not owned by this installation."
    }
    $workingDirectory = Get-NormalizedPath ([Environment]::ExpandEnvironmentVariables([string]$actions[0].WorkingDirectory))
    if (
        $task.TaskPath -ne '\' -or
        (Get-NormalizedPath ([Environment]::ExpandEnvironmentVariables([string]$actions[0].Execute))) -ne $expected -or
        $workingDirectory -ne (Get-NormalizedPath $installRoot) -or
        ([string]$actions[0].Arguments) -ne $ExpectedArguments
    ) {
        Stop-UninstallValidation -Code 'task_not_owned' -Message $notOwned `
            -Console "Scheduled task '$TaskName' is not owned by this installation."
    }
    return $task
}

function Convert-TaskPrincipalToSid {
    param([string]$UserId)

    try {
        return ([Security.Principal.SecurityIdentifier]$UserId).Value
    }
    catch {
        return ([Security.Principal.NTAccount]$UserId).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
}

function Stop-OwnedProcesses {
    param(
        [string]$ProcessName,
        [string]$ExpectedExecutable
    )
    $expected = Get-NormalizedPath $ExpectedExecutable
    $stopped = @()
    foreach ($process in Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        try {
            $actual = Get-NormalizedPath $process.MainModule.FileName
            if ($actual -eq $expected) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $stopped += $process
            }
        }
        catch [System.ComponentModel.Win32Exception] {
            throw "Could not verify process $($process.Id); refusing runtime removal."
        }
        catch [InvalidOperationException] {
            continue
        }
    }
    foreach ($process in $stopped) {
        if (-not $process.WaitForExit(10000)) {
            throw "Owned process did not exit; runtime is preserved: $ProcessName ($($process.Id))"
        }
    }
}

$uninstallPhaseTitles = @{
    preflight = 'Checking what is installed'
    stop = 'Stopping Rewindle'
    tasks = 'Removing the scheduled tasks'
    program_files = 'Removing the Rewindle program files'
    shortcut = 'Removing the Start menu shortcut'
    registration = 'Removing Rewindle from Installed apps'
    verification = 'Checking that Rewindle was removed'
}
# What a failure in each phase is called when no more specific code applies, and what is said about it.
$uninstallPhaseFailures = @{
    preflight = @('preflight_failed', 'Setup could not finish checking what is installed. Nothing was removed.')
    stop = @('stop_failed', 'Setup could not stop Rewindle, so the program files were kept.')
    tasks = @('task_removal_failed', 'Setup could not remove the scheduled tasks.')
    program_files = @('program_files_removal_failed', 'Setup could not remove the Rewindle program files.')
    shortcut = @('shortcut_removal_failed', 'Setup could not remove the Start menu shortcut.')
    registration = @('registration_removal_failed', 'Setup could not remove Rewindle from Installed apps.')
    verification = @('verification_failed', 'Setup could not confirm that Rewindle was removed.')
}

function Start-UninstallPhase {
    param([Parameter(Mandatory)][string]$Phase)
    Write-FeedPhase -Phase $Phase -State 'started' -Title $uninstallPhaseTitles[$Phase]
}

function Complete-UninstallPhase {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail
    )
    Write-FeedPhase -Phase $Phase -State 'completed' -Title $uninstallPhaseTitles[$Phase] -Detail $Detail
}

function Skip-UninstallPhase {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail
    )
    Write-FeedPhase -Phase $Phase -State 'skipped' -Title $uninstallPhaseTitles[$Phase] -Detail $Detail
}

function Add-UninstallWarning {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )
    $script:uninstallWarnings.Add([ordered]@{ code = $Code; message = $Message })
}

# What an uninstall keeps, so a setup program can tell the user. A path is null when it is not known.
function Get-KeptData {
    $kept = [ordered]@{
        state_root = $stateRoot
        repository = $null
        recovery_key = $null
        recovery_tools = $null
        cloud_verification_root = $null
    }
    if ($null -ne $script:configuration) {
        $kept['repository'] = [string]$script:configuration.repository
        $kept['recovery_key'] = [string]$script:configuration.recovery_key_file
        $kept['recovery_tools'] = [string]$script:configuration.recovery_tools_directory
    }
    if (Test-Path -LiteralPath $cloudVerificationRoot -PathType Container) {
        $kept['cloud_verification_root'] = $cloudVerificationRoot
    }
    return $kept
}

function Write-UninstallFailure {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -eq $script:FeedStream) { return }
    $phase = $script:FeedCurrentPhase
    $finding = Get-UninstallFinding -ErrorRecord $ErrorRecord
    if ($null -ne $finding) {
        $code = [string]$finding.code
        $message = [string]$finding.message
    }
    elseif ($null -ne $phase -and $uninstallPhaseFailures.ContainsKey($phase)) {
        $code = $uninstallPhaseFailures[$phase][0]
        $message = $uninstallPhaseFailures[$phase][1]
    }
    else {
        $code = 'uninstall_failed'
        $message = 'Setup could not finish removing Rewindle.'
    }
    if ($phase) {
        Write-FeedPhase -Phase $phase -State 'failed' -Title $uninstallPhaseTitles[$phase] -Detail $message
    }
    Write-FeedResult -Ok $false -ErrorInfo ([ordered]@{
        code = $code
        message = $message
        detail = $ErrorRecord.Exception.Message
    }) -Fields ([ordered]@{
        operation = 'uninstall'
        install_root = $installRoot
        removed = $null
        kept = Get-KeptData
        warnings = @($script:uninstallWarnings)
    })
}

function Complete-UninstallFeed {
    if (-not $script:FeedResultWritten) {
        Write-FeedResult -Ok $false -ErrorInfo ([ordered]@{
            code = 'uninstall_interrupted'
            message = 'Setup was stopped before it finished removing Rewindle.'
            detail = $null
        }) -Fields ([ordered]@{
            operation = 'uninstall'
            install_root = $installRoot
            removed = $null
            kept = Get-KeptData
            warnings = @($script:uninstallWarnings)
        })
    }
    Close-ProgressFeed
}

$configuration = $null
$progressOpened = $false
try {
    if ($ProgressPath -and (Test-Administrator)) {
        Open-ProgressFeed -Path $ProgressPath -ExpectedSid $ExpectedUserSid
        $progressOpened = $true
    }
    Start-UninstallPhase 'preflight'
    Assert-MicrosoftSignedExecutable -Path $windowsPowerShell

    if (-not (Test-Administrator)) {
        Invoke-SelfElevation
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentSid = $identity.User.Value
    if ($ExpectedUserSid -and $ExpectedUserSid -ne $currentSid) {
        Stop-UninstallValidation -Code 'expected_user_mismatch' `
            -Message 'Setup was approved with a different Windows account than the one that started it. Run setup again and approve it with your own account.' `
            -Console 'Approve elevation with the same Windows account that started uninstall.'
    }
    Import-TrustedScheduledTasksModule

    $null = Assert-OwnedRuntime
    $configurationPath = Join-Path $installRoot 'backup-config.json'
    if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
        try {
            $configuration = Read-Utf8Json -Path $configurationPath
        }
        catch {
            Write-Warning "Could not read display-only uninstall metadata; continuing with protected runtime ownership checks: $($_.Exception.Message)"
            Add-UninstallWarning -Code 'uninstall_metadata_unreadable' `
                -Message "Rewindle's settings file could not be read, so setup cannot list which backup data it keeps. Nothing in your backups is removed."
        }
    }
    $backupTask = Assert-OwnedTask `
        -TaskName $backupTaskName `
        -ExpectedExecutable (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe')
    $dashboardExecutable = Join-Path $installRoot 'ResticBackuperDashboard.exe'
    $dashboardArguments = '--minimized --state-dir "{0}"' -f $stateRoot
    $dashboardTask = Assert-OwnedTask `
        -TaskName $dashboardTaskName `
        -ExpectedExecutable $dashboardExecutable `
        -ExpectedArguments $dashboardArguments

    $cloudTask = $null
    $cloudTaskCandidate = Get-ScheduledTask `
        -TaskName $cloudVerificationTaskName `
        -ErrorAction SilentlyContinue
    if ($null -ne $cloudTaskCandidate) {
        $cloudNotOwned = 'The Google Drive verification task does not belong to this Rewindle installation, so nothing was removed.'
        if ($null -eq $configuration -or
            [string]$configuration.repository_storage_mode -cne
                'google_drivefs_stream') {
            Stop-UninstallValidation -Code 'cloud_task_not_owned' -Message $cloudNotOwned `
                -Console 'The Google Drive verification task lacks matching protected configuration.'
        }
        $repositoryStatePath = Join-Path $stateRoot 'repository.json'
        if (-not (Test-Path -LiteralPath $repositoryStatePath -PathType Leaf)) {
            Stop-UninstallValidation -Code 'cloud_task_not_owned' -Message $cloudNotOwned `
                -Console 'The Google Drive verification task lacks protected repository identity.'
        }
        $repositoryState = Read-Utf8Json -Path $repositoryStatePath
        $repositoryId = [string]$repositoryState.repository_id
        if ($repositoryState.schema_version -ne 1 -or
            $repositoryId -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-NormalizedPath ([string]$repositoryState.repository)) -ne
                (Get-NormalizedPath ([string]$configuration.repository))) {
            Stop-UninstallValidation -Code 'cloud_task_not_owned' -Message $cloudNotOwned `
                -Console 'The Google Drive verification task repository identity is invalid.'
        }
        $cloudArguments = (
            '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
            '-WindowStyle Hidden -File "' +
            (Join-Path $installRoot 'verify_my_drive_cloud_repository.ps1') +
            '" -ConfigPath "' + $configurationPath +
            '" -CloudVerificationRoot "' + $cloudVerificationRoot +
            '" -ExpectedRepositoryId "' + $repositoryId + '"'
        )
        $cloudTask = Assert-OwnedTask `
            -TaskName $cloudVerificationTaskName `
            -ExpectedExecutable $windowsPowerShell `
            -ExpectedArguments $cloudArguments
        if ($null -eq $cloudTask -or
            (Convert-TaskPrincipalToSid `
                -UserId ([string]$cloudTask.Principal.UserId)) -cne
            $currentSid) {
            Stop-UninstallValidation -Code 'cloud_task_not_owned' `
                -Message 'The Google Drive verification task belongs to a different Windows account, so nothing was removed.' `
                -Console 'The Google Drive verification task belongs to another account.'
        }
    }

    if (-not $Unattended) {
        Write-Host ''
        Write-Host "$productDisplayName uninstall" -ForegroundColor Cyan
        Write-Host "  App runtime : $installRoot"
        Write-Host "  Preserved   : $stateRoot"
        if ($configuration) {
            Write-Host "  Repository  : $($configuration.repository) (preserved)"
            Write-Host "  Recovery key: $($configuration.recovery_key_file) (preserved)"
        }
        $confirmation = Read-Host 'Remove the app runtime and scheduled tasks? Backup data is kept. [y/N]'
        if ($confirmation -notmatch '^(?i)y(?:es)?$') {
            throw 'Uninstall cancelled before any changes were made.'
        }
    }
    Complete-UninstallPhase 'preflight'

    Start-UninstallPhase 'stop'
    foreach ($task in @($cloudTask, $dashboardTask, $backupTask)) {
        if ($task -and $task.State -eq 'Running') {
            Stop-ScheduledTask -InputObject $task -ErrorAction Stop
        }
    }
    $stopDeadline = [DateTime]::UtcNow.AddSeconds(20)
    foreach ($taskName in @(
        $cloudVerificationTaskName,
        $dashboardTaskName,
        $backupTaskName
    )) {
        while ([DateTime]::UtcNow -lt $stopDeadline) {
            $currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $currentTask -or $currentTask.State -ne 'Running') {
                break
            }
            Start-Sleep -Milliseconds 250
        }
        $currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($currentTask -and $currentTask.State -eq 'Running') {
            Stop-UninstallValidation -Code 'process_not_stopped' `
                -Message 'Rewindle is still running a task and would not stop, so its program files were kept. Try again in a few minutes.' `
                -Console "Scheduled task did not stop; runtime is preserved: $taskName"
        }
    }
    Stop-OwnedProcesses -ProcessName 'ResticBackuperDashboard' -ExpectedExecutable $dashboardExecutable
    Stop-OwnedProcesses -ProcessName 'ResticBackuperTaskLauncher' -ExpectedExecutable (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe')
    Complete-UninstallPhase 'stop'

    Start-UninstallPhase 'tasks'
    foreach ($task in @($cloudTask, $dashboardTask, $backupTask)) {
        if ($task) {
            Unregister-ScheduledTask -InputObject $task -Confirm:$false
            $removedTasks.Add([string]$task.TaskName)
        }
    }
    Complete-UninstallPhase 'tasks'

    Start-UninstallPhase 'program_files'
    $resolved = Get-NormalizedPath $installRoot
    $expected = Get-NormalizedPath (Join-Path $programFilesRoot $productName)
    if ($resolved -ne $expected) {
        throw "Install path changed during uninstall: $resolved"
    }
    Set-Location -LiteralPath $systemDirectory
    Remove-Item -LiteralPath $resolved -Recurse -Force
    Complete-UninstallPhase 'program_files'

    $shortcutRemoved = $false
    $shortcutKept = $false
    if (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf) {
        Start-UninstallPhase 'shortcut'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startMenuShortcut)
        if ((Get-NormalizedPath $shortcut.TargetPath) -eq (Get-NormalizedPath $dashboardExecutable)) {
            Remove-Item -LiteralPath $startMenuShortcut -Force
            $shortcutRemoved = $true
            Complete-UninstallPhase 'shortcut'
        }
        else {
            Write-Warning "Preserved a Start Menu shortcut with an unexpected target: $startMenuShortcut"
            $shortcutKept = $true
            $shortcutDetail = 'A Start menu item named ResticBackuper points somewhere else, so it was left alone.'
            Add-UninstallWarning -Code 'shortcut_kept_unexpected_target' -Message $shortcutDetail
            Complete-UninstallPhase 'shortcut' $shortcutDetail
        }
    }
    else {
        Skip-UninstallPhase 'shortcut' 'There was no Start menu shortcut.'
    }

    $registrationRemoved = $false
    $registrationKept = $false
    if (Test-Path -LiteralPath $installRegistry) {
        Start-UninstallPhase 'registration'
        $registration = Get-ItemProperty -LiteralPath $installRegistry
        if (($registration.DisplayName -eq $productName -or $registration.DisplayName -eq $productDisplayName) -and
            (Get-NormalizedPath ([string]$registration.InstallLocation)) -eq (Get-NormalizedPath $installRoot)) {
            Remove-Item -LiteralPath $installRegistry -Recurse -Force
            $registrationRemoved = $true
            Complete-UninstallPhase 'registration'
        }
        else {
            Write-Warning 'Preserved an uninstall registry entry with unexpected ownership metadata.'
            $registrationKept = $true
            $registrationDetail = 'An entry in Installed apps does not belong to this Rewindle installation, so it was left alone.'
            Add-UninstallWarning -Code 'registration_kept_unexpected_owner' -Message $registrationDetail
            Complete-UninstallPhase 'registration' $registrationDetail
        }
    }
    else {
        Skip-UninstallPhase 'registration' 'Rewindle was not listed in Installed apps.'
    }

    Start-UninstallPhase 'verification'
    if (Test-Path -LiteralPath $installRoot) {
        Stop-UninstallValidation -Code 'verification_failed' `
            -Message 'Setup finished, but could not confirm that the Rewindle program files are gone.' `
            -Console "Uninstall verification failed: $installRoot still exists."
    }
    foreach ($taskName in @($backupTaskName, $dashboardTaskName, $cloudVerificationTaskName)) {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Stop-UninstallValidation -Code 'verification_failed' `
                -Message "Setup finished, but could not confirm that the scheduled task $taskName is gone." `
                -Console "Uninstall verification failed: scheduled task $taskName still exists."
        }
    }
    if (-not $registrationKept -and (Test-Path -LiteralPath $installRegistry)) {
        Stop-UninstallValidation -Code 'verification_failed' `
            -Message 'Setup finished, but could not confirm that Rewindle is gone from Installed apps.' `
            -Console 'Uninstall verification failed: the uninstall registry entry still exists.'
    }
    Complete-UninstallPhase 'verification'

    Write-Host ''
    Write-Host "$productDisplayName app components were removed." -ForegroundColor Green
    Write-Host "Preserved backup state: $stateRoot"
    if (Test-Path -LiteralPath $cloudVerificationRoot -PathType Container) {
        Write-Host "Preserved cloud verification assets/evidence: $cloudVerificationRoot"
    }
    if ($configuration) {
        Write-Host "Preserved repository: $($configuration.repository)"
        Write-Host "Preserved recovery key: $($configuration.recovery_key_file)"
        Write-Host "Preserved recovery tools: $($configuration.recovery_tools_directory)"
    }
    Write-FeedResult -Ok $true -ErrorInfo $null -Fields ([ordered]@{
        operation = 'uninstall'
        install_root = $installRoot
        removed = [ordered]@{
            install_root = $true
            scheduled_tasks = @($removedTasks)
            start_menu_shortcut = $shortcutRemoved
            installed_apps_entry = $registrationRemoved
        }
        kept = Get-KeptData
        warnings = @($uninstallWarnings)
    })
    exit 0
}
catch {
    Write-UninstallFailure -ErrorRecord $_
    throw
}
finally {
    Complete-UninstallFeed
}
