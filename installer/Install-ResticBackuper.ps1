[CmdletBinding()]
param(
    [string]$Repository,
    [ValidateSet('local_ntfs', 'google_drivefs_stream')]
    [string]$RepositoryStorageMode = 'local_ntfs',
    [string]$DriveFsMyDriveRoot,
    [string]$DriveFsCacheDirectory,
    [string]$SourceList,
    # The pattern is checked in the script body (Assert-ScheduleValue) so that -PlanOnly can report a bad time in its plan
    # instead of failing parameter binding before any plan exists. A real install checks it before anything else.
    [string]$Schedule = '02:00',
    [ValidateRange(1, 1048576)]
    [int]$MinimumFreeGiB = 10,
    [switch]$DisableVss,
    [switch]$SkipDashboard,
    [switch]$StartBackup,
    [switch]$Unattended,
    [string]$ExpectedUserSid,
    # Machine-readable setup backend; see docs/setup-contract.md.
    [switch]$PlanOnly,
    [string]$PlanOutput,
    [string]$ProgressPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
$invocationParameters = @{} + $PSBoundParameters

if (-not $PlanOnly -and (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess)) {
    throw 'ResticBackuper requires 64-bit Windows and a 64-bit Windows PowerShell process.'
}
if ($PlanOnly -and $ProgressPath) {
    throw '-PlanOnly cannot be combined with -ProgressPath.'
}
if (-not $PlanOnly -and $PlanOutput) {
    throw '-PlanOutput requires -PlanOnly.'
}
if ($ProgressPath -and -not $Unattended) {
    throw '-ProgressPath requires -Unattended.'
}

function Get-InstallerRoots {
    $roots = [ordered]@{
        program_files = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        program_data = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        user_profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        local_app_data = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        drivefs_my_drive_root = 'G:\My Drive'
        known_folders = $null
        default_repository = $null
        default_repository_set = $false
    }
    # Test hook: the hermetic plan tests point every machine-wide root at a disposable fixture so that no real Program Files,
    # ProgramData or profile folder is read. Only -PlanOnly (which changes nothing) honors it; a real install refuses it.
    $override = [Environment]::GetEnvironmentVariable('REWINDLE_SETUP_TEST_ROOTS')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if (-not $PlanOnly) {
            throw 'REWINDLE_SETUP_TEST_ROOTS is a test hook that only -PlanOnly honors. Remove it from the environment before installing.'
        }
        $document = $override | ConvertFrom-Json
        foreach ($key in @('program_files', 'program_data', 'user_profile', 'local_app_data', 'drivefs_my_drive_root')) {
            if ($document.PSObject.Properties.Name -contains $key) {
                $value = [string]$document.$key
                if (-not [IO.Path]::IsPathRooted($value)) {
                    throw "REWINDLE_SETUP_TEST_ROOTS.$key must be an absolute path."
                }
                $roots[$key] = [IO.Path]::GetFullPath($value)
            }
        }
        if ($document.PSObject.Properties.Name -contains 'default_repository') {
            # An empty value means "no default drive", so a test can exercise that case on any machine.
            $roots['default_repository_set'] = $true
            $roots['default_repository'] = if ([string]::IsNullOrWhiteSpace([string]$document.default_repository)) { $null } else { [string]$document.default_repository }
        }
        if ($document.PSObject.Properties.Name -contains 'known_folders') {
            $folders = [ordered]@{}
            foreach ($property in $document.known_folders.PSObject.Properties) {
                $folders[$property.Name] = [string]$property.Value
            }
            $roots['known_folders'] = $folders
        }
    }
    return $roots
}

$productName = 'ResticBackuper'
$backupTaskName = 'ResticBackuper'
$dashboardTaskName = 'ResticBackuperDashboard'
$primaryTaskEvidenceName = 'scheduled-task.xml'
$cloudTaskEvidenceName = 'google-drive-verification-task.xml'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadRoot = Join-Path $scriptRoot 'payload'
$payloadManifestPath = Join-Path $scriptRoot 'payload-manifest.json'
$installerRoots = Get-InstallerRoots
$programFilesRoot = $installerRoots.program_files
$programDataRoot = $installerRoots.program_data
$userProfileRoot = $installerRoots.user_profile
$systemDirectory = [Environment]::SystemDirectory
$installRoot = Join-Path $programFilesRoot $productName
$stateRoot = Join-Path $programDataRoot $productName
$installRegistry = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResticBackuper'
$startMenuShortcut = Join-Path $programDataRoot 'Microsoft\Windows\Start Menu\Programs\ResticBackuper.lnk'
$icacls = Join-Path $systemDirectory 'icacls.exe'
$windowsPowerShell = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
$expectedDriveFsRoot = $installerRoots.drivefs_my_drive_root
$expectedDriveFsCache = Join-Path $installerRoots.local_app_data 'Google\DriveFS'
$defaultRepositorySuffix = 'ResticBackups\Personal'
$runtimeCreated = $false
$backupTaskCreated = $false
$dashboardTaskCreated = $false
$shortcutCreated = $false
$registryCreated = $false
$firstBackupStarted = $false
$dashboardAssetsManifest = $null
$webView2RuntimeVersion = $null
$webView2RuntimeGuid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$webView2BootstrapperUri = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'

# Results of the validation stages. Both -PlanOnly and a real install fill them through the same functions.
$identity = $null
$currentSid = $null
$payloadManifest = $null
$version = $null
$repositoryPath = $null
$repositoryParent = $null
$recoveryTools = $null
$repositoryPreviouslyInitialized = $false
$sources = @()
$useVss = -not $DisableVss
$canarySource = Join-Path $stateRoot 'Canary'
$canaryFile = Join-Path $canarySource 'backup-canary.txt'
$canaryAlreadyCovered = $false
$configuredSources = @()
$sourceIdentities = $null
$recoveryKey = Join-Path $userProfileRoot 'ResticBackuper-RecoveryKey.txt'
$secretFile = Join-Path $stateRoot 'repository-password.dpapi.json'
$volume = $null
$volumeCache = @{}
$planDefaultRepository = $null
$planErrors = $null
$planWarnings = $null
$installWarnings = [Collections.Generic.List[object]]::new()
$recoveryKeyReadable = $null

# Findings are the stable, machine-readable form of every validation message. Each carries a code, the field of the wizard it
# belongs to, one plain sentence for the user, and the console text this installer has always printed.
function New-InstallFinding {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Message,
        [string]$Console,
        [string]$Path
    )
    $finding = [pscustomobject][ordered]@{
        code = $Code
        field = $Field
        message = $Message
        path = if ([string]::IsNullOrEmpty($Path)) { $null } else { $Path }
        detail = $null
        console = if ([string]::IsNullOrEmpty($Console)) { $Message } else { $Console }
    }
    $finding.PSObject.TypeNames.Insert(0, 'Rewindle.InstallFinding')
    return $finding
}

function Stop-InstallFinding {
    param([Parameter(Mandatory)][object]$Finding)
    $record = [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new([string]$Finding.console),
        ('Rewindle.' + [string]$Finding.code),
        [Management.Automation.ErrorCategory]::InvalidData,
        $Finding
    )
    throw $record
}

function Stop-InstallValidation {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Message,
        [string]$Console,
        [string]$Path
    )
    Stop-InstallFinding -Finding (New-InstallFinding -Code $Code -Field $Field -Message $Message -Console $Console -Path $Path)
}

function Get-InstallFinding {
    param([Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -ne $ErrorRecord -and
        $null -ne $ErrorRecord.TargetObject -and
        $ErrorRecord.TargetObject.PSObject.TypeNames -contains 'Rewindle.InstallFinding') {
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

function Get-DotNetFrameworkRelease {
    $frameworkKey = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    try {
        return [long](Get-ItemProperty -LiteralPath $frameworkKey -Name Release -ErrorAction Stop).Release
    }
    catch {
        return $null
    }
}

function Assert-DotNetFramework48 {
    $friendly = 'Rewindle needs Microsoft .NET Framework 4.8. Install it from Windows Update or from Microsoft, then run setup again.'
    $release = Get-DotNetFrameworkRelease
    if ($null -eq $release) {
        Stop-InstallValidation -Code 'dotnet_framework_missing' -Field 'environment' -Message $friendly `
            -Console 'ResticBackuper requires the Microsoft .NET Framework 4.8 desktop runtime.'
    }
    if ($release -lt 528040) {
        Stop-InstallValidation -Code 'dotnet_framework_missing' -Field 'environment' -Message $friendly `
            -Console "ResticBackuper requires the Microsoft .NET Framework 4.8 desktop runtime (release 528040 or newer); found release $release."
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($Value.IndexOf([char]0) -ge 0 -or $Value.Contains('"')) {
        throw 'Installer arguments cannot contain a quote or NUL character.'
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
        '-Schedule', (Quote-ProcessArgument $Schedule),
        '-MinimumFreeGiB', [string]$MinimumFreeGiB,
        '-RepositoryStorageMode', (Quote-ProcessArgument $RepositoryStorageMode),
        '-ExpectedUserSid', (Quote-ProcessArgument $sid)
    )
    if ($invocationParameters.ContainsKey('Repository')) {
        $arguments += @('-Repository', (Quote-ProcessArgument $Repository))
    }
    if ($invocationParameters.ContainsKey('SourceList')) {
        $arguments += @('-SourceList', (Quote-ProcessArgument $SourceList))
    }
    if ($invocationParameters.ContainsKey('DriveFsMyDriveRoot')) {
        $arguments += @('-DriveFsMyDriveRoot', (Quote-ProcessArgument $DriveFsMyDriveRoot))
    }
    if ($invocationParameters.ContainsKey('DriveFsCacheDirectory')) {
        $arguments += @('-DriveFsCacheDirectory', (Quote-ProcessArgument $DriveFsCacheDirectory))
    }
    if ($invocationParameters.ContainsKey('ProgressPath')) {
        $arguments += @('-ProgressPath', (Quote-ProcessArgument $ProgressPath))
    }
    foreach ($switchName in @('DisableVss', 'SkipDashboard', 'StartBackup', 'Unattended')) {
        if ($invocationParameters.ContainsKey($switchName) -and [bool]$invocationParameters[$switchName]) {
            $arguments += '-' + $switchName
        }
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

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-NormalizedPath {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        throw "Path must be absolute: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full -eq $root) {
        return $root
    }
    return $full.TrimEnd('\')
}

# Get-NormalizedPath for a path the user typed: the same normalization, with a finding instead of a bare exception.
function Resolve-InputPath {
    param(
        [string]$Path,
        [string]$Field,
        [string]$NotAbsoluteCode,
        [string]$NotAbsoluteMessage,
        [string]$InvalidCode,
        [string]$InvalidMessage
    )
    $rooted = $false
    try { $rooted = [IO.Path]::IsPathRooted($Path) } catch { $rooted = $false }
    if (-not $rooted) {
        Stop-InstallValidation -Code $NotAbsoluteCode -Field $Field -Message $NotAbsoluteMessage `
            -Console "Path must be absolute: $Path" -Path $Path
    }
    try {
        return Get-NormalizedPath -Path $Path
    }
    catch {
        Stop-InstallValidation -Code $InvalidCode -Field $Field -Message $InvalidMessage `
            -Console $_.Exception.Message -Path $Path
    }
}

function Test-IsWithin {
    param(
        [string]$Candidate,
        [string]$Parent
    )
    $candidatePath = (Get-NormalizedPath $Candidate).TrimEnd('\') + '\'
    $parentPath = (Get-NormalizedPath $Parent).TrimEnd('\') + '\'
    return $candidatePath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NormalDirectory {
    param(
        [string]$Path,
        [string]$Code,
        [string]$Field,
        [string]$Message
    )
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $console = "Expected a normal, non-reparse directory: $Path"
        if ($Code) {
            Stop-InstallValidation -Code $Code -Field $Field -Message $Message -Console $console -Path $Path
        }
        throw $console
    }
}

function Assert-NoReparsePath {
    param(
        [string]$Path,
        [switch]$Recurse,
        [string]$Code,
        [string]$Field,
        [string]$Message
    )
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $console = "Reparse points are not accepted in protected paths: $current"
                if ($Code) {
                    Stop-InstallValidation -Code $Code -Field $Field -Message $Message -Console $console -Path $current
                }
                throw $console
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $reparse = Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
        if ($reparse) {
            $console = "Reparse point found in a protected tree: $($reparse.FullName)"
            if ($Code) {
                Stop-InstallValidation -Code $Code -Field $Field -Message $Message -Console $console -Path $reparse.FullName
            }
            throw $console
        }
    }
}

function Assert-MicrosoftSignedExecutable {
    param(
        [string]$Path,
        [string]$Code = 'system_tool_untrusted'
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-InstallValidation -Code 'system_tool_missing' -Field 'environment' `
            -Message 'A Windows component that setup needs is missing, so this copy of Windows cannot be used for setup.' `
            -Console "Required Windows executable is missing: $Path" -Path $Path
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') {
        $message = if ($Code -eq 'webview2_installer_untrusted') {
            "The Microsoft Edge WebView2 installer that was downloaded did not pass Microsoft's signature check, so setup stopped."
        } else {
            "A Windows component that setup needs did not pass Microsoft's signature check, so setup stopped."
        }
        Stop-InstallValidation -Code $Code -Field 'environment' -Message $message `
            -Console "Required Windows executable did not pass Microsoft signature validation: $Path" -Path $Path
    }
}

function Stop-PayloadFinding {
    param(
        [Parameter(Mandatory)][string]$Console,
        [string]$Code = 'payload_corrupt'
    )
    $message = switch ($Code) {
        'payload_missing' { 'The Rewindle setup files are missing. Download Rewindle again and run setup from the new copy.' }
        'payload_incomplete' { 'The Rewindle setup files are incomplete. Download Rewindle again and run setup from the new copy.' }
        'payload_copy_failed' { "Setup could not copy Rewindle's program files correctly." }
        default { 'The Rewindle setup files are damaged. Download Rewindle again and run setup from the new copy.' }
    }
    Stop-InstallValidation -Code $Code -Field 'environment' -Message $message -Console $Console
}

function Assert-TreeMatchesManifest {
    param(
        [string]$Root,
        [object]$Manifest,
        [string]$Label,
        [string]$Code = 'payload_corrupt'
    )
    Assert-NormalDirectory -Path $Root
    Assert-NoReparsePath -Path $Root -Recurse
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($entry in $Manifest.files) {
        $relative = [string]$entry.relative_path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..' -or -not $seen.Add($relative)) {
            Stop-PayloadFinding -Code $Code -Console "Unsafe or duplicate $Label path: $relative"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $Root $relative))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-PayloadFinding -Code $Code -Console "$Label path escapes its root: $relative"
        }
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-PayloadFinding -Code $Code -Console "$Label is missing a file: $relative"
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-PayloadFinding -Code $Code -Console "$Label entry is not a regular file: $relative"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($item.Length -ne [long]$entry.bytes -or $hash -ne [string]$entry.sha256) {
            Stop-PayloadFinding -Code $Code -Console "$Label integrity check failed: $relative"
        }
    }
    $actual = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)
    if ($actual.Count -ne $Manifest.file_count) {
        Stop-PayloadFinding -Code $Code -Console "$Label has unmanifested or missing files."
    }
    foreach ($file in $actual) {
        $relative = $file.FullName.Substring($Root.Length + 1)
        if (-not $seen.Contains($relative)) {
            Stop-PayloadFinding -Code $Code -Console "$Label contains an unmanifested file: $relative"
        }
    }
}

function Assert-DashboardAssetsManifest {
    param(
        [string]$Root,
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        Stop-PayloadFinding -Code 'payload_incomplete' -Console "Dashboard assets manifest is missing: $ManifestPath"
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or -not ($manifest.PSObject.Properties.Name -contains 'files')) {
        Stop-PayloadFinding -Console 'Dashboard assets manifest schema is invalid.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $relative = ([string]$entry.relative_path).Replace('/', '\')
        if (
            [string]::IsNullOrWhiteSpace($relative) -or
            [IO.Path]::IsPathRooted($relative) -or
            $relative.Split('\') -contains '..' -or
            $relative -match '[<>:"|?*]' -or
            -not $seen.Add($relative)
        ) {
            Stop-PayloadFinding -Console "Dashboard assets manifest contains an unsafe or duplicate path: $relative"
        }
        if (
            -not $relative.StartsWith('web\', [StringComparison]::OrdinalIgnoreCase) -and
            -not $relative.StartsWith('licenses\', [StringComparison]::OrdinalIgnoreCase) -and
            $relative -notin @(
                'Microsoft.Web.WebView2.Core.dll',
                'Microsoft.Web.WebView2.Wpf.dll',
                'WebView2Loader.dll'
            )
        ) {
            Stop-PayloadFinding -Console "Dashboard assets manifest contains an unexpected path: $relative"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $Root $relative))
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-PayloadFinding -Console "Dashboard assets manifest path escapes its root: $relative"
        }
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-PayloadFinding -Code 'payload_incomplete' -Console "Dashboard assets manifest member is missing: $relative"
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-PayloadFinding -Console "Dashboard assets manifest member is not a regular file: $relative"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [long]$bytes = 0
        if (
            -not [long]::TryParse([string]$entry.bytes, [ref]$bytes) -or
            $bytes -lt 0 -or
            $item.Length -ne $bytes -or
            $hash -ne [string]$entry.sha256
        ) {
            Stop-PayloadFinding -Console "Dashboard assets manifest integrity check failed: $relative"
        }
    }
    foreach ($required in @(
        'web\index.html',
        'Microsoft.Web.WebView2.Core.dll',
        'Microsoft.Web.WebView2.Wpf.dll',
        'WebView2Loader.dll'
    )) {
        if (-not $seen.Contains($required)) {
            Stop-PayloadFinding -Code 'payload_incomplete' -Console "Dashboard assets manifest is missing required member: $required"
        }
    }
    return $manifest
}

function Get-WebView2RuntimeVersion {
    $keyPaths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$webView2RuntimeGuid",
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$webView2RuntimeGuid",
        "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$webView2RuntimeGuid"
    )
    foreach ($keyPath in $keyPaths) {
        if (-not (Test-Path -LiteralPath $keyPath)) {
            continue
        }
        try {
            $properties = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
            $version = [string]$properties.pv
            if ($version -match '^\d+(?:\.\d+){1,3}$') {
                return $version
            }
        }
        catch {
        }
    }
    return $null
}

function Ensure-WebView2Runtime {
    $existing = Get-WebView2RuntimeVersion
    if ($existing) {
        return $existing
    }

    $bootstrapper = Join-Path ([IO.Path]::GetTempPath()) (
        'Rewindle-WebView2-' + [Guid]::NewGuid().ToString('N') + '.exe'
    )
    try {
        Write-Host 'Microsoft Edge WebView2 Runtime is missing; downloading the Microsoft bootstrapper.' -ForegroundColor Yellow
        Invoke-WebRequest -UseBasicParsing -Uri $webView2BootstrapperUri -OutFile $bootstrapper
        Assert-MicrosoftSignedExecutable -Path $bootstrapper -Code 'webview2_installer_untrusted'
        $process = Start-Process -FilePath $bootstrapper -ArgumentList @('/silent', '/install') -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "WebView2 Runtime bootstrapper failed with exit code $($process.ExitCode)."
        }
        $installed = Get-WebView2RuntimeVersion
        if (-not $installed) {
            throw 'WebView2 Runtime bootstrapper completed without registering a runtime.'
        }
        return $installed
    }
    finally {
        if (Test-Path -LiteralPath $bootstrapper) {
            Remove-Item -LiteralPath $bootstrapper -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-Payload {
    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        Stop-PayloadFinding -Code 'payload_missing' -Console "Installer payload is missing: $payloadRoot"
    }
    if (-not (Test-Path -LiteralPath $payloadManifestPath -PathType Leaf)) {
        Stop-PayloadFinding -Code 'payload_missing' -Console "Installer payload manifest is missing: $payloadManifestPath"
    }
    $manifest = Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.file_count -ne @($manifest.files).Count) {
        Stop-PayloadFinding -Console 'Installer payload manifest header/count is invalid.'
    }
    Assert-TreeMatchesManifest -Root $payloadRoot -Manifest $manifest -Label 'Installer payload'
    $required = @(
        'VERSION',
        'Python\python.exe',
        'restic.exe',
        'initialize_repository.py',
        'refresh_recovery_tools.py',
        'recovery_health.py',
        'credential_repair.py',
        'stale_lock_repair.py',
        'key_rotation.py',
        'anomaly_review.py',
        'backup.py',
        'dry_run.py',
        'restore.py',
        'restic_common.py',
        'secret_store.py',
        'verify_my_drive_cloud_repository.ps1',
        'verify_cloud_repository_inventory.py',
        'reveal-rclone-config-password.ps1',
        'install_google_drive_sync_task.ps1',
        'excludes.txt',
        'backup-canary.txt',
        'RECOVERY.md',
        'restic-release.json',
        'Manage-Sources.ps1',
        'Manage-Schedule.ps1',
        'Manage-Backup.ps1',
        'Manage-Repository.ps1',
        'Manage-Restore.ps1',
        # The dashboard's only evidence that this engine serves restore approval sessions. It is copied with the rest of the
        # payload, protected by the install-root ACL, listed in runtime-manifest.json and removed by the uninstaller.
        'engine-capabilities.json',
        'ResticBackuperTaskLauncher.exe',
        'Uninstall-ResticBackuper.ps1',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'dependencies.json',
        'licenses\RESTIC.txt',
        'licenses\PYTHON.txt'
    )
    if (-not $SkipDashboard) {
        $required += 'ResticBackuperDashboard.exe'
        $required += 'dashboard-assets.json'
        $required += 'web\index.html'
        $required += 'Microsoft.Web.WebView2.Core.dll'
        $required += 'Microsoft.Web.WebView2.Wpf.dll'
        $required += 'WebView2Loader.dll'
    }
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot $relative) -PathType Leaf)) {
            Stop-PayloadFinding -Code 'payload_incomplete' -Console "Installer payload lacks a required component: $relative"
        }
    }
    if (-not $SkipDashboard) {
        $script:dashboardAssetsManifest = Assert-DashboardAssetsManifest `
            -Root $payloadRoot `
            -ManifestPath (Join-Path $payloadRoot 'dashboard-assets.json')
    }
    return $manifest
}

function Assert-RecoveryToolsCompatible {
    param(
        [string]$Path,
        [string]$RepositoryPath
    )
    $friendly = 'The folder Rewindle keeps its recovery tools in (next to the backup folder) already holds files from something else. Choose a different backup folder.'
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return
    }
    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($entries.Count -eq 0) {
        return
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('restic.exe', 'restore.py', 'secret_store.py', 'backup-config.json', 'RECOVERY.md', 'restic-release.json', 'recovery-manifest.json')) {
        [void]$expected.Add($name)
    }
    foreach ($entry in $entries) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $expected.Remove($entry.Name)) {
            Stop-InstallValidation -Code 'recovery_tools_conflict' -Field 'repository' -Message $friendly `
                -Console "RecoveryTools contains an unexpected entry: $($entry.FullName)" -Path $Path
        }
    }
    if ($expected.Count -ne 0) {
        $missing = @($expected | Sort-Object) -join ', '
        Stop-InstallValidation -Code 'recovery_tools_conflict' -Field 'repository' -Message $friendly `
            -Console "RecoveryTools is incomplete; missing: $missing" -Path $Path
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Path 'recovery-manifest.json') -Raw | ConvertFrom-Json
    $recoveryConfig = Get-Content -LiteralPath (Join-Path $Path 'backup-config.json') -Raw | ConvertFrom-Json
    if (
        $manifest.schema_version -ne 1 -or
        (Get-NormalizedPath ([string]$manifest.repository)) -ne (Get-NormalizedPath $RepositoryPath) -or
        (Get-NormalizedPath ([string]$recoveryConfig.repository)) -ne (Get-NormalizedPath $RepositoryPath)
    ) {
        Stop-InstallValidation -Code 'recovery_tools_conflict' -Field 'repository' -Message $friendly `
            -Console 'RecoveryTools belongs to another repository or has invalid metadata.' -Path $Path
    }
}

function Set-ProtectedDirectory {
    param(
        [string]$Path,
        [string]$UserSid
    )
    Assert-NormalDirectory -Path $Path
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $ownerRights = [Security.Principal.SecurityIdentifier]::new('S-1-3-4')
    $user = [Security.Principal.SecurityIdentifier]::new($UserSid)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administrators)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance, $propagation, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($ownerRights, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance, $propagation, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
        & $icacls (Join-Path $Path '*') /reset /T /C /L | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Resetting child ACLs failed for $Path"
        }
    }
    & $icacls $Path /setowner '*S-1-5-32-544' /T /C /L | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Assigning protected ownership failed for $Path"
    }
}

function Get-DefaultRepository {
    $systemRoot = [IO.Path]::GetPathRoot($systemDirectory)
    $candidates = @(
        [IO.DriveInfo]::GetDrives() |
            Where-Object {
                $_.IsReady -and
                $_.RootDirectory.FullName -ne $systemRoot -and
                $_.DriveFormat -eq 'NTFS' -and
                $_.DriveType -in @([IO.DriveType]::Removable, [IO.DriveType]::Fixed)
            } |
            Sort-Object AvailableFreeSpace -Descending
    )
    if ($candidates.Count -gt 0) {
        return (Join-Path $candidates[0].RootDirectory.FullName $defaultRepositorySuffix)
    }
    return $null
}

function Get-DownloadsFolderPath {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
        $value = [string](Get-ItemProperty -LiteralPath $key -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    catch {
    }
    return (Join-Path $userProfileRoot 'Downloads')
}

function Get-KnownFolderPaths {
    $folders = [ordered]@{}
    if ($null -ne $installerRoots.known_folders) {
        foreach ($name in $installerRoots.known_folders.Keys) {
            $folders[$name] = $installerRoots.known_folders[$name]
        }
        return $folders
    }
    $folders['Desktop'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $folders['Documents'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $folders['Pictures'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures)
    $folders['Music'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyMusic)
    $folders['Videos'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyVideos)
    $folders['Downloads'] = Get-DownloadsFolderPath
    $folders['Favorites'] = [Environment]::GetFolderPath([Environment+SpecialFolder]::Favorites)
    $folders['SavedGames'] = Join-Path $userProfileRoot 'Saved Games'
    return $folders
}

function Get-DefaultSources {
    $folders = Get-KnownFolderPaths
    $candidates = @(
        $folders['Desktop'],
        $folders['Documents'],
        $folders['Pictures'],
        $folders['Videos'],
        $folders['Music'],
        $folders['Favorites'],
        $folders['Downloads'],
        $folders['SavedGames']
    )
    return @(
        $candidates |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
            ForEach-Object { [IO.Path]::GetFullPath($_) } |
            Select-Object -Unique
    )
}

# The part of Assert-SourceDrive that depends only on what Windows reports about the drive, so tests can feed it synthetic values.
function Assert-SourceDriveProperties {
    param(
        [string]$Directory,
        [bool]$Ready,
        [string]$DriveType,
        [string]$DriveFormat,
        [bool]$UseVss,
        [string]$Field = 'sources'
    )
    if (-not $Ready -or $DriveType -notin @('Fixed', 'Removable')) {
        Stop-InstallValidation -Code 'source_drive_unavailable' -Field $Field `
            -Message "The folder $Directory is on a drive that isn't ready or isn't a hard drive or USB drive on this PC, so it can't be backed up." `
            -Console "A backup source must be on a ready local fixed or removable drive: $Directory" -Path $Directory
    }
    if ($UseVss -and
        ($DriveType -ne 'Fixed' -or
         -not [string]::Equals($DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase))) {
        Stop-InstallValidation -Code 'source_vss_unsupported' -Field $Field `
            -Message "The folder $Directory is on a drive that can't be backed up while files are open (it must be a fixed NTFS drive). Choose a folder on your main drives, or turn off open-file backup." `
            -Console "VSS is enabled, so every source must be on a ready local fixed NTFS volume; use -DisableVss only for supported local removable or non-NTFS sources: $Directory" -Path $Directory
    }
}

function Assert-SourceDrive {
    param(
        [string]$Directory,
        [bool]$UseVss,
        [string]$Field = 'sources'
    )
    $root = [IO.Path]::GetPathRoot($Directory)
    if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:\\$') {
        Stop-InstallValidation -Code 'source_not_local' -Field $Field `
            -Message "The folder $Directory isn't on a local drive. Network folders aren't supported." `
            -Console "Backup sources must use a local drive-letter path; UNC and network sources are not supported: $Directory" -Path $Directory
    }
    $drive = [IO.DriveInfo]::new($root)
    $ready = [bool]$drive.IsReady
    Assert-SourceDriveProperties -Directory $Directory -Ready $ready -DriveType ([string]$drive.DriveType) `
        -DriveFormat $(if ($ready) { [string]$drive.DriveFormat } else { '' }) -UseVss $UseVss -Field $Field
}

function Get-RepositoryVolume {
    param(
        [string]$Path,
        [ValidateSet('repository', 'source', 'system')][string]$Scope = 'repository'
    )
    $notLocalCode = switch ($Scope) { 'source' { 'source_not_local' } 'system' { 'system_volume_unavailable' } default { 'repository_not_local' } }
    $unavailableCode = switch ($Scope) { 'source' { 'source_drive_unavailable' } 'system' { 'system_volume_unavailable' } default { 'repository_drive_unavailable' } }
    $field = switch ($Scope) { 'source' { 'sources' } 'system' { 'environment' } default { 'repository' } }
    $root = [IO.Path]::GetPathRoot($Path)
    if (-not $root -or $root.StartsWith('\\')) {
        Stop-InstallValidation -Code $notLocalCode -Field $field `
            -Message "Rewindle can only use drives on this PC that have a drive letter, such as D:. Network locations aren't supported." `
            -Console 'The alpha installer supports only local drive-letter repositories.' -Path $Path
    }
    $cacheKey = $root.ToUpperInvariant()
    if ($script:volumeCache.ContainsKey($cacheKey)) {
        return $script:volumeCache[$cacheKey]
    }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or $drive.DriveType -notin @([IO.DriveType]::Removable, [IO.DriveType]::Fixed)) {
        Stop-InstallValidation -Code $unavailableCode -Field $field `
            -Message "The drive $root isn't ready, or isn't a hard drive or USB drive on this PC." `
            -Console 'The alpha installer accepts only ready local fixed or removable drive-letter repositories.' -Path $Path
    }
    Add-Type -AssemblyName System.Management
    $device = $root.TrimEnd('\').Replace("'", "''")
    $searcher = [System.Management.ManagementObjectSearcher]::new(
        "SELECT VolumeSerialNumber FROM Win32_LogicalDisk WHERE DeviceID='$device'"
    )
    try {
        $records = @($searcher.Get())
    }
    finally {
        $searcher.Dispose()
    }
    if ($records.Count -ne 1 -or -not $records[0].VolumeSerialNumber) {
        Stop-InstallValidation -Code 'volume_serial_unreadable' -Field 'environment' `
            -Message "Windows would not tell setup the identity of the drive $root, so setup can't use it." `
            -Console "Could not read the repository volume serial: $root" -Path $Path
    }
    if (-not ('ResticBackuperInstaller.NativeVolume' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ResticBackuperInstaller {
  public static class NativeVolume {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeInformation(
      string root, System.Text.StringBuilder volume, int volumeSize,
      out uint serial, out uint maximumComponentLength, out uint fileSystemFlags,
      System.Text.StringBuilder fileSystemName, int fileSystemNameSize);
    public static UInt32[] Details(string root) {
      uint serial, maximum, flags;
      if (!GetVolumeInformation(root, null, 0, out serial, out maximum, out flags, null, 0))
        throw new Win32Exception(Marshal.GetLastWin32Error());
      return new UInt32[] { serial, maximum, flags };
    }
  }
}
'@
    }
    $details = [ResticBackuperInstaller.NativeVolume]::Details($root)
    $result = [ordered]@{
        root = $root
        serial = ([string]$records[0].VolumeSerialNumber).ToUpperInvariant()
        filesystem = [string]$drive.DriveFormat
        drive_type = [int]$drive.DriveType
        free_bytes = [long]$drive.AvailableFreeSpace
        maximum_component_length = [long]$details[1]
        filesystem_flags = [long]$details[2]
    }
    $script:volumeCache[$cacheKey] = $result
    return $result
}

function Assert-NtfsProtectedPath {
    param(
        [string]$Path,
        [string]$Label
    )
    $scope = if ($Label -eq 'Recovery tools') { 'repository' } else { 'system' }
    $volume = Get-RepositoryVolume -Path $Path -Scope $scope
    if (-not [string]::Equals([string]$volume.filesystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        $console = "$Label must remain on NTFS; observed $($volume.filesystem) at $($volume.root)"
        switch ($Label) {
            'Recovery tools' {
                Stop-InstallValidation -Code 'repository_not_ntfs' -Field 'repository' -Console $console -Path $Path `
                    -Message "The drive for the backup folder is formatted as $($volume.filesystem). Rewindle needs a drive formatted as NTFS."
            }
            'Google DriveFS cache' {
                Stop-InstallValidation -Code 'drivefs_cache_not_ntfs' -Field 'storage_mode' -Console $console -Path $Path `
                    -Message "The drive that holds Google Drive's cache is formatted as $($volume.filesystem). Rewindle needs it to be NTFS."
            }
            default {
                Stop-InstallValidation -Code 'system_volume_not_ntfs' -Field 'environment' -Console $console -Path $Path `
                    -Message "Windows' own drive for Rewindle's files is formatted as $($volume.filesystem). Rewindle needs NTFS there."
            }
        }
    }
}

function Test-DriveFsMount {
    param([Parameter(Mandatory)]$Volume)
    return (
        [int]$Volume.drive_type -eq [int][IO.DriveType]::Fixed -and
        [string]::Equals([string]$Volume.filesystem, 'FAT32', [StringComparison]::OrdinalIgnoreCase) -and
        ([long]$Volume.filesystem_flags -band 0x100) -ne 0 -and
        [long]$Volume.maximum_component_length -ge 64
    )
}

function Assert-LocalNtfsVolume {
    param([Parameter(Mandatory)]$Volume)
    if (-not [string]::Equals([string]$Volume.filesystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-InstallValidation -Code 'repository_not_ntfs' -Field 'repository' `
            -Message "The drive for the backup folder is formatted as $($Volume.filesystem). Rewindle needs a drive formatted as NTFS." `
            -Console "local_ntfs requires an NTFS repository volume; observed $($Volume.filesystem)." -Path ([string]$Volume.root)
    }
}

function Assert-VolumeFreeSpace {
    param(
        [Parameter(Mandatory)]$Volume,
        [Parameter(Mandatory)][int]$MinimumFreeGiB
    )
    if ([long]$Volume.free_bytes -lt ([long]$MinimumFreeGiB * 1GB)) {
        Stop-InstallValidation -Code 'repository_low_space' -Field 'repository' `
            -Message "The drive for the backup folder has less than $MinimumFreeGiB GB free. Choose a drive with more free space." `
            -Console "Repository volume has less than $MinimumFreeGiB GiB free." -Path ([string]$Volume.root)
    }
}

function Assert-DriveFsProviderTransaction {
    param([string]$Directory)
    Assert-NormalDirectory -Path $Directory
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
        if (-not [IO.File]::Exists($committed) -or [IO.File]::Exists($temporary)) {
            throw 'Google DriveFS did not expose the provider probe rename.'
        }
        $observed = [IO.File]::ReadAllBytes($committed)
        if ([Convert]::ToBase64String($observed) -cne [Convert]::ToBase64String($payload)) {
            throw 'Google DriveFS provider probe readback differed from the committed payload.'
        }
    }
    catch {
        Stop-InstallValidation -Code 'drivefs_provider_failed' -Field 'storage_mode' `
            -Message "Google Drive didn't accept a test file written to the backup folder. Make sure Google Drive for desktop is signed in and running, then try again." `
            -Console $_.Exception.Message -Path $Directory
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        foreach ($path in @($temporary, $committed)) {
            if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        }
    }
}

function Import-TrustedScheduledTasksModule {
    $manifest = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\Modules\ScheduledTasks\ScheduledTasks.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        Stop-InstallValidation -Code 'scheduled_tasks_module_missing' -Field 'environment' `
            -Message 'This copy of Windows is missing the part that schedules backups, so setup cannot continue.' `
            -Console "The protected Windows ScheduledTasks module is missing: $manifest" -Path $manifest
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

function New-RuntimeManifest {
    param(
        [string]$Root,
        [string]$Version
    )
    $files = @(
        Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
            Where-Object Name -notin @(
                'runtime-manifest.json',
                $primaryTaskEvidenceName,
                $cloudTaskEvidenceName
            ) |
            Sort-Object FullName
    )
    $manifest = [ordered]@{
        schema_version = 1
        product = $productName
        version = $Version
        created_utc = [DateTime]::UtcNow.ToString('o')
        file_count = $files.Count
        files = @(
            foreach ($file in $files) {
                [ordered]@{
                    relative_path = $file.FullName.Substring($Root.Length + 1)
                    bytes = $file.Length
                    sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
    }
    Write-Utf8NoBom -Path (Join-Path $Root 'runtime-manifest.json') -Text ($manifest | ConvertTo-Json -Depth 7)
    return $manifest
}

# ---------------------------------------------------------------------------------------------------------------------------
# Volumes, recommendation and the other facts the plan reports. The two functions that decide eligibility and the recommendation
# take plain objects so tests can feed synthetic volumes.
# ---------------------------------------------------------------------------------------------------------------------------

function Initialize-NativeSetup {
    if (-not ('ResticBackuperInstaller.NativeDisk' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace ResticBackuperInstaller {
  public static class NativeDisk {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr handle, uint code, IntPtr inBuffer, uint inSize, byte[] outBuffer, uint outSize, out uint returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr handle);
    // The physical disks that hold a volume (IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS). Opening the volume with no access rights
    // is enough, so this works for a standard user. Returns null when Windows will not say.
    public static int[] DiskNumbers(string drive) {
      IntPtr handle = CreateFileW("\\\\.\\" + drive, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
      if (handle == new IntPtr(-1)) { return null; }
      try {
        uint size = 1024;
        for (int attempt = 0; attempt < 4; attempt++) {
          byte[] buffer = new byte[size];
          uint returned;
          if (DeviceIoControl(handle, 0x00560000, IntPtr.Zero, 0, buffer, size, out returned, IntPtr.Zero)) {
            int count = BitConverter.ToInt32(buffer, 0);
            List<int> numbers = new List<int>();
            for (int index = 0; index < count; index++) { numbers.Add(BitConverter.ToInt32(buffer, 8 + 24 * index)); }
            return numbers.ToArray();
          }
          if (Marshal.GetLastWin32Error() != 234) { return null; }
          size *= 4;
        }
        return null;
      }
      finally { CloseHandle(handle); }
    }
  }
}
'@
    }
}

function Get-VolumeDiskNumbers {
    param([Parameter(Mandatory)][string]$Drive)
    try {
        Initialize-NativeSetup
        $numbers = [ResticBackuperInstaller.NativeDisk]::DiskNumbers($Drive.TrimEnd('\'))
        if ($null -eq $numbers -or $numbers.Count -eq 0) { return $null }
        return $numbers
    }
    catch {
        return $null
    }
}

# $Volume needs drive_type (fixed|removable|network|cdrom|ram|unknown), ready, filesystem and free_bytes.
function Get-VolumeEligibility {
    param(
        [Parameter(Mandatory)]$Volume,
        [Parameter(Mandatory)][long]$MinimumFreeBytes
    )
    $reason = $null
    $message = $null
    $type = [string]$Volume.drive_type
    if ($type -eq 'network') {
        $reason = 'network_drive'
        $message = "Network drives can't hold a Rewindle backup."
    }
    elseif ($type -eq 'cdrom') {
        $reason = 'optical_drive'
        $message = "CD and DVD drives can't hold a Rewindle backup."
    }
    elseif ($type -eq 'ram') {
        $reason = 'ram_disk'
        $message = "A RAM disk is erased when the PC restarts, so it can't hold a backup."
    }
    elseif ($type -notin @('fixed', 'removable')) {
        $reason = 'unknown_drive_type'
        $message = "Windows doesn't say what kind of drive this is, so Rewindle can't use it."
    }
    elseif (-not [bool]$Volume.ready) {
        $reason = 'not_ready'
        $message = "This drive isn't ready. It may be empty, locked or disconnected."
    }
    elseif (-not [string]::Equals([string]$Volume.filesystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        $reason = 'not_ntfs'
        $message = "This drive is formatted as $($Volume.filesystem). Rewindle needs a drive formatted as NTFS."
    }
    elseif ([long]$Volume.free_bytes -lt $MinimumFreeBytes) {
        $reason = 'low_free_space'
        $message = "This drive has less than $([Math]::Round($MinimumFreeBytes / 1GB, 1)) GB free."
    }
    return [pscustomobject]@{
        eligible = ($null -eq $reason)
        reason = $reason
        message = $message
    }
}

# Each volume needs root, eligible, filesystem, same_physical_disk_as_system (true, false or null) and free_bytes. The
# recommendation is the eligible NTFS volume that is known to be on a different physical disk from Windows and has the most
# free space (ties go to the lower drive letter). With no such volume nothing is recommended.
function Select-RecommendedVolume {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Volumes)
    $candidates = @(
        $Volumes | Where-Object {
            [bool]$_.eligible -and
            [string]::Equals([string]$_.filesystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase) -and
            $null -ne $_.same_physical_disk_as_system -and
            -not [bool]$_.same_physical_disk_as_system
        }
    )
    if ($candidates.Count -eq 0) {
        return $null
    }
    $best = $candidates |
        Sort-Object @{ Expression = { [long]$_.free_bytes }; Descending = $true }, @{ Expression = { [string]$_.root }; Descending = $false } |
        Select-Object -First 1
    return [string]$best.root
}

function Get-PlanVolumes {
    param([Parameter(Mandatory)][long]$MinimumFreeBytes)
    $systemRoot = [IO.Path]::GetPathRoot($systemDirectory)
    $systemDisks = Get-VolumeDiskNumbers -Drive $systemRoot
    $volumes = @()
    foreach ($disk in @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop | Sort-Object DeviceID)) {
        $root = ([string]$disk.DeviceID) + '\'
        $driveType = switch ([int]$disk.DriveType) {
            2 { 'removable' }
            3 { 'fixed' }
            4 { 'network' }
            5 { 'cdrom' }
            6 { 'ram' }
            default { 'unknown' }
        }
        $filesystem = [string]$disk.FileSystem
        $ready = (-not [string]::IsNullOrEmpty($filesystem)) -and $null -ne $disk.Size
        $isSystem = [string]::Equals($root, $systemRoot, [StringComparison]::OrdinalIgnoreCase)
        $samePhysical = $null
        if ($isSystem) {
            $samePhysical = $true
        }
        elseif ($ready -and $driveType -in @('fixed', 'removable') -and $null -ne $systemDisks) {
            $disks = Get-VolumeDiskNumbers -Drive $root
            if ($null -ne $disks) {
                $samePhysical = @($disks | Where-Object { $systemDisks -contains $_ }).Count -gt 0
            }
        }
        $volume = [pscustomobject][ordered]@{
            root = $root
            label = [string]$disk.VolumeName
            filesystem = $filesystem
            drive_type = $driveType
            size_bytes = if ($null -ne $disk.Size) { [long]$disk.Size } else { [long]0 }
            free_bytes = if ($null -ne $disk.FreeSpace) { [long]$disk.FreeSpace } else { [long]0 }
            is_system = $isSystem
            same_physical_disk_as_system = $samePhysical
            ready = $ready
        }
        $eligibility = Get-VolumeEligibility -Volume $volume -MinimumFreeBytes $MinimumFreeBytes
        $volume | Add-Member -NotePropertyName eligible -NotePropertyValue $eligibility.eligible
        $volume | Add-Member -NotePropertyName ineligible_reason -NotePropertyValue $eligibility.reason
        $volume | Add-Member -NotePropertyName ineligible_message -NotePropertyValue $eligibility.message
        $volumes += $volume
    }
    $recommendedRoot = Select-RecommendedVolume -Volumes $volumes
    foreach ($volume in $volumes) {
        $volume | Add-Member -NotePropertyName recommended `
            -NotePropertyValue ($null -ne $recommendedRoot -and [string]::Equals($volume.root, $recommendedRoot, [StringComparison]::OrdinalIgnoreCase))
    }
    return $volumes
}

function Get-OsSummary {
    $caption = $null
    $build = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = [string]$os.Caption
        $build = [string]$os.BuildNumber
    }
    catch {
        $build = [string][Environment]::OSVersion.Version.Build
    }
    $buildNumber = 0
    [void][int]::TryParse($build, [ref]$buildNumber)
    $x64 = [bool][Environment]::Is64BitOperatingSystem
    return [ordered]@{
        caption = $caption
        build = $build
        x64 = $x64
        supported = ($x64 -and $buildNumber -ge 10240)
    }
}

function Test-LegacyEngineInstalled {
    $config = Join-Path $programFilesRoot 'ResticPersonalBackup\backup-config.json'
    try {
        $attributes = [IO.File]::GetAttributes($config)
        return (-not ($attributes -band [IO.FileAttributes]::Directory))
    }
    catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
        return $false
    }
    catch {
        # Same rule as the dashboard: an unreadable root counts as installed, so it is never passed over.
        return $true
    }
}

function Get-RewindleInstallInfo {
    $rootExists = Test-Path -LiteralPath $installRoot
    $registered = Test-Path -LiteralPath $installRegistry
    if (-not $rootExists -and -not $registered) {
        return $null
    }
    $installedVersion = $null
    $versionPath = Join-Path $installRoot 'VERSION'
    try {
        if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
            $text = ([IO.File]::ReadAllText($versionPath)).Trim()
            if ($text -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { $installedVersion = $text }
        }
        if (-not $installedVersion -and $registered) {
            $text = [string](Get-ItemProperty -LiteralPath $installRegistry -ErrorAction Stop).DisplayVersion
            if ($text -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { $installedVersion = $text }
        }
    }
    catch {
    }
    return [ordered]@{
        version = $installedVersion
        install_root = $installRoot
    }
}

function Get-DriveFsInfo {
    $result = [ordered]@{ detected = $false; my_drive_root = $null }
    if (-not (Test-Path -LiteralPath $expectedDriveFsRoot -PathType Container)) {
        return $result
    }
    if (-not (Get-Process -Name GoogleDriveFS -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $result
    }
    try {
        $mount = Get-RepositoryVolume -Path $expectedDriveFsRoot
    }
    catch {
        return $result
    }
    if (Test-DriveFsMount -Volume $mount) {
        $result.detected = $true
        $result.my_drive_root = $expectedDriveFsRoot
    }
    return $result
}

function Get-PlanKnownFolders {
    $defaults = @(Get-DefaultSources)
    $folders = Get-KnownFolderPaths
    $list = @()
    foreach ($key in @('Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads', 'Favorites')) {
        $path = if ($folders.Contains($key)) { [string]$folders[$key] } else { '' }
        $exists = (-not [string]::IsNullOrWhiteSpace($path)) -and (Test-Path -LiteralPath $path -PathType Container)
        $selected = $false
        if ($exists) {
            $full = [IO.Path]::GetFullPath($path)
            $selected = @($defaults | Where-Object { [string]::Equals($_, $full, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        }
        $list += [ordered]@{
            key = $key
            path = if ([string]::IsNullOrWhiteSpace($path)) { $null } else { $path }
            exists = [bool]$exists
            default_selected = [bool]$selected
        }
    }
    return $list
}

# Can the unelevated account read the recovery key? These functions answer from the key file's DACL and the account's
# unelevated group list; docs/setup-contract.md, section 5 explains why that is enough and what it assumes.
function Convert-FileAccessMask {
    param([long]$Mask)
    # The generic rights are decimal because PowerShell reads 0x80000000 as a negative 32-bit number.
    $genericAll = [long]268435456
    $genericRead = [long]2147483648
    $genericWrite = [long]1073741824
    $genericExecute = [long]536870912
    $mapped = $Mask -band [long]33554431
    if (($Mask -band $genericAll) -ne 0) { $mapped = $mapped -bor [long]2032127 }      # FILE_ALL_ACCESS
    if (($Mask -band $genericRead) -ne 0) { $mapped = $mapped -bor [long]1179785 }     # FILE_GENERIC_READ
    if (($Mask -band $genericWrite) -ne 0) { $mapped = $mapped -bor [long]1179926 }    # FILE_GENERIC_WRITE
    if (($Mask -band $genericExecute) -ne 0) { $mapped = $mapped -bor [long]1179808 }  # FILE_GENERIC_EXECUTE
    return $mapped
}

function Test-DescriptorGrantsAccess {
    param(
        [Parameter(Mandatory)][Security.AccessControl.RawSecurityDescriptor]$Descriptor,
        [Parameter(Mandatory)][string[]]$Sids,
        [long]$Mask = 0x120089
    )
    $acl = $Descriptor.DiscretionaryAcl
    if ($null -eq $acl) {
        return $true
    }
    $remaining = $Mask
    foreach ($ace in $acl) {
        if ($ace -isnot [Security.AccessControl.CommonAce]) { continue }
        if (([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::InheritOnly) -ne 0) { continue }
        if ($Sids -notcontains $ace.SecurityIdentifier.Value) { continue }
        $aceMask = Convert-FileAccessMask -Mask ([long][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ace.AccessMask), 0))
        if ($ace.AceType -eq [Security.AccessControl.AceType]::AccessDenied) {
            if (($aceMask -band $remaining) -ne 0) { return $false }
        }
        elseif ($ace.AceType -eq [Security.AccessControl.AceType]::AccessAllowed) {
            $remaining = $remaining -band (-bnot $aceMask)
            if ($remaining -eq 0) { return $true }
        }
    }
    return ($remaining -eq 0)
}

# The groups the same account has when it is not elevated. An elevated token carries Administrators as an active group; the
# filtered token the account uses the rest of the time does not, unless User Account Control is off.
function Get-UnelevatedTokenSids {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sids = [Collections.Generic.List[string]]::new()
    [void]$sids.Add($current.User.Value)
    $filtered = $true
    try {
        $policies = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
        if ($policies.PSObject.Properties.Name -contains 'EnableLUA' -and [int]$policies.EnableLUA -eq 0) {
            $filtered = $false
        }
    }
    catch {
    }
    if ($current.User.Value -match '-500$') {
        # The built-in Administrator account is not filtered unless FilterAdministratorToken is set.
        $filtered = $false
        try {
            $policies = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
            if ($policies.PSObject.Properties.Name -contains 'FilterAdministratorToken' -and [int]$policies.FilterAdministratorToken -eq 1) {
                $filtered = $true
            }
        }
        catch {
        }
    }
    foreach ($group in $current.Groups) {
        $value = $group.Value
        if ($filtered -and ($value -eq 'S-1-5-32-544' -or $value -eq 'S-1-5-114')) { continue }
        [void]$sids.Add($value)
    }
    return $sids
}

function Test-FileReadableByUser {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Sids
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        if (-not $Sids) { $Sids = Get-UnelevatedTokenSids }
        $security = [IO.File]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
        $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($security.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access))
        return (Test-DescriptorGrantsAccess -Descriptor $descriptor -Sids $Sids)
    }
    catch {
        return $null
    }
}

# ---------------------------------------------------------------------------------------------------------------------------
# Validation stages. A real install runs them in this order and stops at the first problem (the finding's console text is the
# message it has always printed). -PlanOnly runs the same functions and collects what they report.
# ---------------------------------------------------------------------------------------------------------------------------

function Assert-ScheduleValue {
    if ($Schedule -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
        Stop-InstallValidation -Code 'schedule_invalid' -Field 'schedule' `
            -Message "The backup time '$Schedule' isn't a valid time. Use the 24-hour clock, for example 02:00." `
            -Console "Schedule must be a 24-hour time written HH:mm, for example 02:00 (received '$Schedule')."
    }
}

function Read-PayloadVersion {
    $versionFile = Join-Path $payloadRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        Stop-PayloadFinding -Code 'payload_incomplete' -Console 'Payload VERSION file is missing.'
    }
    $text = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    if ($text -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        Stop-InstallValidation -Code 'payload_version_invalid' -Field 'environment' `
            -Message 'The Rewindle setup files carry a version number setup does not understand. Download Rewindle again.' `
            -Console "Payload version is invalid: $text"
    }
    $script:version = $text
}

function Resolve-StorageSettings {
    if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        if ([string]::IsNullOrWhiteSpace($DriveFsMyDriveRoot)) {
            $script:DriveFsMyDriveRoot = $expectedDriveFsRoot
        }
        if ([string]::IsNullOrWhiteSpace($DriveFsCacheDirectory)) {
            $script:DriveFsCacheDirectory = $expectedDriveFsCache
        }
        $script:DriveFsMyDriveRoot = Resolve-InputPath -Path $DriveFsMyDriveRoot -Field 'storage_mode' `
            -NotAbsoluteCode 'drivefs_root_unsupported' `
            -NotAbsoluteMessage "Rewindle can only use Google Drive when it appears as $expectedDriveFsRoot." `
            -InvalidCode 'drivefs_root_unsupported' `
            -InvalidMessage "Rewindle can only use Google Drive when it appears as $expectedDriveFsRoot."
        $script:DriveFsCacheDirectory = Resolve-InputPath -Path $DriveFsCacheDirectory -Field 'storage_mode' `
            -NotAbsoluteCode 'drivefs_cache_unsupported' `
            -NotAbsoluteMessage "Rewindle expects Google Drive's cache in $expectedDriveFsCache." `
            -InvalidCode 'drivefs_cache_unsupported' `
            -InvalidMessage "Rewindle expects Google Drive's cache in $expectedDriveFsCache."
        if (-not [string]::Equals($DriveFsMyDriveRoot, $expectedDriveFsRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-InstallValidation -Code 'drivefs_root_unsupported' -Field 'storage_mode' `
                -Message "Rewindle can only use Google Drive when it appears as $expectedDriveFsRoot." `
                -Console "google_drivefs_stream requires the exact My Drive root $expectedDriveFsRoot" -Path $DriveFsMyDriveRoot
        }
        if (-not [string]::Equals($DriveFsCacheDirectory, $expectedDriveFsCache, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-InstallValidation -Code 'drivefs_cache_unsupported' -Field 'storage_mode' `
                -Message "Rewindle expects Google Drive's cache in $expectedDriveFsCache, the standard place for this Windows account." `
                -Console "drivefs_cache_directory must be the current user's Google DriveFS cache: $expectedDriveFsCache" -Path $DriveFsCacheDirectory
        }
    }
    elseif ($invocationParameters.ContainsKey('DriveFsMyDriveRoot') -or
        $invocationParameters.ContainsKey('DriveFsCacheDirectory')) {
        Stop-InstallValidation -Code 'drivefs_options_without_mode' -Field 'storage_mode' `
            -Message 'Google Drive folders were given, but backups are not set to be kept in Google Drive.' `
            -Console 'DriveFS path parameters require -RepositoryStorageMode google_drivefs_stream.'
    }
}

# Where setup keeps backups when the user did not say: the console asks, a plan proposes its recommended drive.
function Get-RepositoryInput {
    if ($Repository) {
        return
    }
    if ($PlanOnly) {
        $script:Repository = $planDefaultRepository
        if (-not $Repository) {
            Stop-InstallValidation -Code 'repository_required' -Field 'repository' `
                -Message 'Choose where your backups should be kept. No drive other than the Windows drive was found to suggest.' `
                -Console 'A repository path is required; no safe non-system default was found.'
        }
        return
    }
    if ($Unattended) {
        Stop-InstallValidation -Code 'repository_required' -Field 'repository' `
            -Message 'Choose where your backups should be kept.' -Console '-Repository is required with -Unattended.'
    }
    $defaultRepository = if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        Join-Path $DriveFsMyDriveRoot $defaultRepositorySuffix
    } else {
        Get-DefaultRepository
    }
    if ($defaultRepository) {
        $prompt = if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
            "Repository path strictly beneath $DriveFsMyDriveRoot [$defaultRepository]"
        } else {
            "Repository path (prefer a separate physical NTFS drive) [$defaultRepository]"
        }
        $answer = Read-Host $prompt
        $script:Repository = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultRepository } else { $answer.Trim() }
    }
    else {
        $answer = Read-Host 'Repository path on a local NTFS volume (prefer a separate physical drive)'
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Stop-InstallValidation -Code 'repository_required' -Field 'repository' `
                -Message 'Choose where your backups should be kept.' -Console 'A repository path is required; no safe non-system default was found.'
        }
        $script:Repository = $answer.Trim()
    }
}

function Resolve-RepositorySelection {
    Get-RepositoryInput
    $script:repositoryPath = Resolve-InputPath -Path $Repository -Field 'repository' `
        -NotAbsoluteCode 'repository_not_absolute' `
        -NotAbsoluteMessage "The backup folder '$Repository' isn't a complete folder path. Write it out in full, for example D:\Backups\Rewindle." `
        -InvalidCode 'repository_path_invalid' `
        -InvalidMessage "The backup folder '$Repository' isn't a valid folder path."
    # A network path must be refused before any probe could contact it.
    $pathRoot = [IO.Path]::GetPathRoot($repositoryPath)
    if ([string]::IsNullOrWhiteSpace($pathRoot) -or $pathRoot -notmatch '^[A-Za-z]:\\$') {
        Stop-InstallValidation -Code 'repository_not_local' -Field 'repository' `
            -Message "Rewindle can only keep backups on a drive that has a drive letter, such as D:. Network locations aren't supported." `
            -Console 'The alpha installer supports only local drive-letter repositories.' -Path $repositoryPath
    }
    $script:repositoryParent = Split-Path -Parent $repositoryPath
    if (-not $repositoryParent) {
        Stop-InstallValidation -Code 'repository_is_drive_root' -Field 'repository' `
            -Message 'Backups cannot be kept in the top level of a drive. Choose a folder inside it, for example D:\Rewindle.' `
            -Console 'Repository must not be a drive root.' -Path $repositoryPath
    }
    $script:recoveryTools = if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        Join-Path $programDataRoot 'ResticBackuperRecoveryTools'
    } else {
        Join-Path $repositoryParent 'RecoveryTools'
    }
    if ($RepositoryStorageMode -eq 'google_drivefs_stream' -and
        ((-not (Test-IsWithin -Candidate $repositoryPath -Parent $DriveFsMyDriveRoot)) -or
         [string]::Equals($repositoryPath, $DriveFsMyDriveRoot, [StringComparison]::OrdinalIgnoreCase))) {
        Stop-InstallValidation -Code 'repository_not_in_drivefs' -Field 'repository' `
            -Message "When backups are kept in Google Drive, the backup folder must be inside $DriveFsMyDriveRoot." `
            -Console "A google_drivefs_stream repository must be strictly beneath $DriveFsMyDriveRoot" -Path $repositoryPath
    }
    foreach ($protectedPath in @($installRoot, $stateRoot, $recoveryTools)) {
        if ((Test-IsWithin -Candidate $repositoryPath -Parent $protectedPath) -or (Test-IsWithin -Candidate $protectedPath -Parent $repositoryPath)) {
            Stop-InstallValidation -Code 'repository_overlaps_install' -Field 'repository' `
                -Message "The backup folder can't be inside, or contain, a folder Rewindle uses for itself ($protectedPath). Choose another folder." `
                -Console "Repository overlaps a protected ResticBackuper path: $protectedPath" -Path $repositoryPath
        }
    }
    $linkMessage = "The backup folder, or a folder above it, is a shortcut-like link that Rewindle won't follow. Choose a normal folder."
    Assert-NoReparsePath -Path $repositoryPath -Recurse -Code 'repository_has_reparse_point' -Field 'repository' -Message $linkMessage
    Assert-NoReparsePath -Path $repositoryParent -Code 'repository_has_reparse_point' -Field 'repository' -Message $linkMessage
    $protectedLinkMessage = "A folder Rewindle needs to protect contains a link, so setup can't use it safely. Remove the link or choose a different backup folder."
    Assert-NoReparsePath -Path $recoveryTools -Recurse -Code 'protected_path_reparse_point' -Field 'environment' -Message $protectedLinkMessage
    Assert-NoReparsePath -Path $installRoot -Code 'protected_path_reparse_point' -Field 'environment' -Message $protectedLinkMessage
    Assert-NoReparsePath -Path $stateRoot -Recurse -Code 'protected_path_reparse_point' -Field 'environment' -Message $protectedLinkMessage
    if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        $driveLinkMessage = "Google Drive's folders contain a link that Rewindle won't follow."
        Assert-NoReparsePath -Path $DriveFsMyDriveRoot -Code 'drivefs_reparse_point' -Field 'storage_mode' -Message $driveLinkMessage
        Assert-NoReparsePath -Path $DriveFsCacheDirectory -Recurse -Code 'drivefs_reparse_point' -Field 'storage_mode' -Message $driveLinkMessage
    }
    foreach ($existingDirectory in @($repositoryPath, $repositoryParent)) {
        if (Test-Path -LiteralPath $existingDirectory) {
            Assert-NormalDirectory -Path $existingDirectory -Code 'repository_not_a_folder' -Field 'repository' `
                -Message "'$existingDirectory' is a file or a link, not a normal folder. Choose a different backup folder."
        }
    }
    foreach ($existingDirectory in @($recoveryTools, $stateRoot)) {
        if (Test-Path -LiteralPath $existingDirectory) {
            Assert-NormalDirectory -Path $existingDirectory -Code 'protected_path_not_directory' -Field 'environment' `
                -Message "'$existingDirectory' is a file or a link where Rewindle needs a normal folder."
        }
    }
    Assert-RecoveryToolsCompatible -Path $recoveryTools -RepositoryPath $repositoryPath
    $script:repositoryPreviouslyInitialized = Test-Path -LiteralPath (Join-Path $repositoryPath 'config') -PathType Leaf
    if ((Test-Path -LiteralPath $repositoryPath -PathType Container) -and -not $repositoryPreviouslyInitialized) {
        if (@(Get-ChildItem -LiteralPath $repositoryPath -Force | Select-Object -First 1).Count -gt 0) {
            Stop-InstallValidation -Code 'repository_not_empty' -Field 'repository' `
                -Message "The backup folder '$repositoryPath' already contains other files. Choose an empty or new folder." `
                -Console "Repository path is nonempty but is not a Restic repository: $repositoryPath" -Path $repositoryPath
        }
    }
}

function Get-SourceCandidates {
    if (-not $SourceList) {
        $defaults = @(Get-DefaultSources)
        if ($PlanOnly) {
            $script:SourceList = $defaults -join ';'
        }
        elseif ($Unattended) {
            Stop-InstallValidation -Code 'sources_required' -Field 'sources' `
                -Message 'Choose at least one folder to back up.' -Console '-SourceList is required with -Unattended.'
        }
        else {
            $shown = $defaults -join ';'
            $answer = Read-Host "Source folders, separated by semicolons [$shown]"
            $script:SourceList = if ([string]::IsNullOrWhiteSpace($answer)) { $shown } else { $answer.Trim() }
        }
    }
    $candidates = @($SourceList.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($candidates.Count -eq 0) {
        Stop-InstallValidation -Code 'sources_required' -Field 'sources' `
            -Message 'Choose at least one folder to back up.' -Console 'At least one source directory is required.'
    }
    return $candidates
}

function Test-SourceCandidate {
    param(
        [string]$Candidate,
        [object[]]$Accepted,
        [Collections.Generic.HashSet[string]]$Seen
    )
    $source = Resolve-InputPath -Path $Candidate -Field 'sources' `
        -NotAbsoluteCode 'source_not_absolute' `
        -NotAbsoluteMessage "'$Candidate' isn't a complete folder path. Write it out in full, for example C:\Users\you\Documents." `
        -InvalidCode 'source_path_invalid' `
        -InvalidMessage "'$Candidate' isn't a valid folder path."
    # Reject UNC/network and unsupported drive classes before any filesystem
    # probe can contact a remote path or accept a source the manager cannot edit.
    Assert-SourceDrive -Directory $source -UseVss $useVss
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Stop-InstallValidation -Code 'source_not_found' -Field 'sources' `
            -Message "The folder $source can't be found, or Windows won't let setup open it." `
            -Console "Source directory does not exist: $source" -Path $source
    }
    if (-not $Seen.Add($source)) {
        Stop-InstallValidation -Code 'source_duplicate' -Field 'sources' `
            -Message "The folder $source is in the list more than once." `
            -Console "Duplicate source directory: $source" -Path $source
    }
    foreach ($existingSource in $Accepted) {
        if ((Test-IsWithin -Candidate $source -Parent $existingSource) -or (Test-IsWithin -Candidate $existingSource -Parent $source)) {
            Stop-InstallValidation -Code 'sources_overlap' -Field 'sources' `
                -Message "The folders $source and $existingSource overlap, because one is inside the other. Choose only one of them." `
                -Console "Configured sources must not contain one another: $source and $existingSource" -Path $source
        }
    }
    Assert-NoReparsePath -Path $source -Code 'source_has_reparse_point' -Field 'sources' `
        -Message "The folder $source (or a folder above it) is a link that Rewindle won't follow. Choose the real folder instead."
    if ($repositoryPath -and
        ((Test-IsWithin -Candidate $repositoryPath -Parent $source) -or (Test-IsWithin -Candidate $source -Parent $repositoryPath))) {
        Stop-InstallValidation -Code 'source_overlaps_repository' -Field 'sources' `
            -Message "The folder $source and the backup folder overlap, because one is inside the other. A backup can't be stored inside what it backs up." `
            -Console "Repository and source overlap: $source" -Path $source
    }
    foreach ($protectedPath in @($installRoot, $stateRoot)) {
        if ((Test-IsWithin -Candidate $source -Parent $protectedPath) -or (Test-IsWithin -Candidate $protectedPath -Parent $source)) {
            Stop-InstallValidation -Code 'source_overlaps_install' -Field 'sources' `
                -Message "The folder $source overlaps a folder Rewindle uses for itself and can't be backed up." `
                -Console "Source overlaps ResticBackuper runtime/state and is unsupported in this alpha: $source" -Path $source
        }
    }
    return $source
}

function Resolve-SourceSelection {
    $candidates = Get-SourceCandidates
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $accepted = @()
    foreach ($candidate in $candidates) {
        try {
            $accepted += Test-SourceCandidate -Candidate $candidate -Accepted $accepted -Seen $seen
        }
        catch {
            if (-not $PlanOnly) { throw }
            Add-PlanErrorRecord -ErrorRecord $_ -Field 'sources'
        }
    }
    $script:sources = @($accepted)
}

function Resolve-ProtectedBindings {
    if ((Test-IsWithin -Candidate $repositoryPath -Parent $canarySource) -or (Test-IsWithin -Candidate $canarySource -Parent $repositoryPath)) {
        Stop-InstallValidation -Code 'repository_overlaps_canary' -Field 'repository' `
            -Message "The backup folder can't be inside, or contain, a folder Rewindle uses for itself ($canarySource). Choose another folder." `
            -Console 'The repository overlaps ResticBackuper protected canary state. Choose another repository path.' -Path $repositoryPath
    }
    $script:configuredSources = @($sources)
    $script:canaryAlreadyCovered = $false
    foreach ($source in $sources) {
        if (Test-IsWithin -Candidate $canaryFile -Parent $source) {
            $script:canaryAlreadyCovered = $true
            break
        }
    }
    if (-not $canaryAlreadyCovered) {
        $script:configuredSources += $canarySource
    }
    foreach ($source in $configuredSources) {
        Assert-SourceDrive -Directory $source -UseVss $useVss -Field $(if ($source -eq $canarySource) { 'environment' } else { 'sources' })
    }
    $identities = [ordered]@{}
    foreach ($source in $configuredSources) {
        $sourceVolume = Get-RepositoryVolume -Path $source -Scope $(if ($source -eq $canarySource) { 'system' } else { 'source' })
        $identities[$source] = [ordered]@{
            expected_volume_serial = ([string]$sourceVolume.serial).ToUpperInvariant()
        }
    }
    $script:sourceIdentities = $identities
    Assert-NoReparsePath -Path $recoveryKey -Code 'recovery_key_path_unsafe' -Field 'environment' `
        -Message "The recovery key's location in your profile folder is a link, so setup can't use it safely."
    if (Test-Path -LiteralPath $recoveryKey) {
        $recoveryKeyItem = Get-Item -LiteralPath $recoveryKey -Force
        if ($recoveryKeyItem.PSIsContainer -or ($recoveryKeyItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-InstallValidation -Code 'recovery_key_path_unsafe' -Field 'environment' `
                -Message "Something other than a file is where Rewindle keeps the recovery key in your profile folder ($recoveryKey)." `
                -Console "Recovery key path is not a regular file: $recoveryKey" -Path $recoveryKey
        }
        if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
            Stop-InstallValidation -Code 'recovery_key_stale' -Field 'environment' `
                -Message "A recovery key from an earlier setup is still in your profile folder, but the password that goes with it is gone. Move that file somewhere safe, then run setup again." `
                -Console "A recovery key already exists but the matching DPAPI credential is absent. Move the stale key aside only after identifying it: $recoveryKey" -Path $recoveryKey
        }
    }
    foreach ($protectedBinding in @(
        @($installRoot, 'Protected runtime'),
        @($stateRoot, 'ProgramData state'),
        @($secretFile, 'DPAPI credential'),
        @($recoveryKey, 'Recovery key'),
        @($recoveryTools, 'Recovery tools')
    )) {
        Assert-NtfsProtectedPath -Path $protectedBinding[0] -Label $protectedBinding[1]
    }
}

function Assert-RepositoryTarget {
    $script:volume = Get-RepositoryVolume -Path $repositoryPath
    if ($RepositoryStorageMode -eq 'local_ntfs') {
        Assert-LocalNtfsVolume -Volume $volume
    }
    else {
        if (-not (Test-Path -LiteralPath $DriveFsMyDriveRoot -PathType Container)) {
            Stop-InstallValidation -Code 'drivefs_unavailable' -Field 'storage_mode' `
                -Message "Google Drive for desktop doesn't show $DriveFsMyDriveRoot. Make sure it is installed, signed in and running." `
                -Console "Google DriveFS My Drive is unavailable: $DriveFsMyDriveRoot" -Path $DriveFsMyDriveRoot
        }
        Assert-NormalDirectory -Path $DriveFsMyDriveRoot -Code 'drivefs_reparse_point' -Field 'storage_mode' `
            -Message "Google Drive's My Drive folder is a link that Rewindle won't follow."
        if (-not (Get-Process -Name GoogleDriveFS -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            Stop-InstallValidation -Code 'drivefs_not_running' -Field 'storage_mode' `
                -Message 'Google Drive for desktop is not running. Start it and wait until it finishes starting, then try again.' `
                -Console 'Google DriveFS provider process is not running.'
        }
        if (-not (Test-DriveFsMount -Volume $volume)) {
            Stop-InstallValidation -Code 'drivefs_mount_unsupported' -Field 'storage_mode' `
                -Message "The folder isn't the Google Drive streaming drive that Rewindle supports. Check that Google Drive for desktop is set to stream files." `
                -Console 'The selected path is not the supported Google DriveFS streaming FAT32 mount.' -Path $repositoryPath
        }
        if (-not (Test-Path -LiteralPath $DriveFsCacheDirectory -PathType Container)) {
            Stop-InstallValidation -Code 'drivefs_cache_unavailable' -Field 'storage_mode' `
                -Message "Google Drive's cache folder can't be found ($DriveFsCacheDirectory). Make sure Google Drive for desktop has been running." `
                -Console "Google DriveFS cache directory is unavailable: $DriveFsCacheDirectory" -Path $DriveFsCacheDirectory
        }
        Assert-NormalDirectory -Path $DriveFsCacheDirectory -Code 'drivefs_reparse_point' -Field 'storage_mode' `
            -Message "Google Drive's cache folder is a link that Rewindle won't follow."
        Assert-NtfsProtectedPath -Path $DriveFsCacheDirectory -Label 'Google DriveFS cache'
        $cacheFreeBytes = [long]([IO.DriveInfo]::new(
            [IO.Path]::GetPathRoot($DriveFsCacheDirectory))).AvailableFreeSpace
        $minimumCacheBytes = [Math]::Max([long]$MinimumFreeGiB * 1GB, [long]10GB)
        if ($cacheFreeBytes -lt $minimumCacheBytes) {
            $cacheGiB = [Math]::Round($minimumCacheBytes / 1GB, 1)
            Stop-InstallValidation -Code 'drivefs_cache_low_space' -Field 'storage_mode' `
                -Message "The drive that holds Google Drive's cache has less than $cacheGiB GB free." `
                -Console "Google DriveFS cache has less than $cacheGiB GiB free." -Path $DriveFsCacheDirectory
        }
        if (Test-Path -LiteralPath $repositoryPath -PathType Container) {
            $oversized = Get-ChildItem -LiteralPath $repositoryPath -Recurse -File -Force |
                Where-Object { $_.Length -ge [long]4GB } |
                Select-Object -First 1
            if ($oversized) {
                Stop-InstallValidation -Code 'drivefs_object_too_large' -Field 'storage_mode' `
                    -Message "A file in the backup folder is 4 GB or larger, which Google Drive can't hold for Rewindle ($($oversized.FullName))." `
                    -Console "DriveFS cannot host a repository object of 4 GiB or larger: $($oversized.FullName)" -Path $oversized.FullName
            }
        }
    }
    Assert-VolumeFreeSpace -Volume $volume -MinimumFreeGiB $MinimumFreeGiB
}

# Everything that would make a real install refuse because Rewindle, or something using its names, is already on this PC.
# Returns findings; it never throws.
function Get-InstallationConflicts {
    $conflicts = @()
    if (Test-Path -LiteralPath $installRoot) {
        $conflicts += New-InstallFinding -Code 'already_installed' -Field 'environment' `
            -Message 'Rewindle is already installed on this PC. Remove it first (your backups are kept), then run setup again.' `
            -Console "ResticBackuper is already installed at $installRoot. This alpha refuses in-place upgrades; uninstall the app binaries first (data is preserved)." `
            -Path $installRoot
    }
    if (Test-Path -LiteralPath $installRegistry) {
        $conflicts += New-InstallFinding -Code 'stale_registration' -Field 'environment' `
            -Message 'Windows still lists a Rewindle installation, so setup will not start. Remove Rewindle from Installed apps first.' `
            -Console 'A ResticBackuper uninstall registration already exists. Remove the prior app installation first.'
    }
    if (-not $SkipDashboard -and (Test-Path -LiteralPath $startMenuShortcut)) {
        $conflicts += New-InstallFinding -Code 'start_menu_shortcut_exists' -Field 'environment' `
            -Message 'A Start menu item named ResticBackuper already exists, so setup will not overwrite it.' `
            -Console "A Start Menu item already occupies the ResticBackuper shortcut path: $startMenuShortcut" -Path $startMenuShortcut
    }
    foreach ($taskName in @($backupTaskName, $dashboardTaskName)) {
        $existingTask = $null
        try { $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue } catch { }
        if ($existingTask) {
            $conflicts += New-InstallFinding -Code 'task_name_in_use' -Field 'environment' `
                -Message "A Windows scheduled task named $taskName already exists, so setup will not continue." `
                -Console "A scheduled task already uses the product name: $taskName" -Path $taskName
        }
    }
    return $conflicts
}

# Warnings the installer can raise; a finding with no console text is reported only to a plan.
function Get-InstallWarnings {
    $warnings = @()
    if ($null -ne $volume) {
        $systemVolume = [IO.Path]::GetPathRoot($systemDirectory)
        $repositoryOnSystemVolume = $volume.root -eq $systemVolume
        if ($RepositoryStorageMode -eq 'local_ntfs' -and $repositoryOnSystemVolume) {
            $warnings += New-InstallFinding -Code 'repository_on_system_disk' -Field 'repository' `
                -Message 'Your backups would be on the same drive as Windows. If that drive fails you could lose both, so a different physical drive is strongly recommended.' `
                -Console 'The repository is on the Windows system volume. This does not protect against failure or loss of that volume; a separate physical drive is strongly recommended.' `
                -Path $repositoryPath
        }
        elseif ($RepositoryStorageMode -eq 'local_ntfs') {
            $repositoryDisks = Get-VolumeDiskNumbers -Drive $volume.root
            $systemDisks = Get-VolumeDiskNumbers -Drive $systemVolume
            if ($null -ne $repositoryDisks -and $null -ne $systemDisks -and
                @($repositoryDisks | Where-Object { $systemDisks -contains $_ }).Count -gt 0) {
                $finding = New-InstallFinding -Code 'repository_on_system_disk' -Field 'repository' `
                    -Message 'Your backups would be on the same physical disk as Windows, just in another partition. If that disk fails you could lose both.' `
                    -Path $repositoryPath
                $finding.console = $null
                $warnings += $finding
            }
        }
    }
    if ($repositoryPreviouslyInitialized) {
        $finding = New-InstallFinding -Code 'repository_exists' -Field 'repository' `
            -Message 'The backup folder already holds a Rewindle backup. Setup will keep and reuse it, and earlier backups stay available.' `
            -Path $repositoryPath
        $finding.console = $null
        $warnings += $finding
    }
    return $warnings
}

# ---------------------------------------------------------------------------------------------------------------------------
# -PlanOnly
# ---------------------------------------------------------------------------------------------------------------------------

function ConvertTo-PlanFinding {
    param([object]$Finding)
    return [ordered]@{
        code = [string]$Finding.code
        field = [string]$Finding.field
        message = [string]$Finding.message
        path = $Finding.path
        detail = $Finding.detail
    }
}

function Add-PlanFinding {
    param(
        [Parameter(Mandatory)][object]$Finding,
        [Parameter(Mandatory)][ValidateSet('error', 'warning')][string]$Severity
    )
    # Not "$list = if (...) { ... }": an empty list would be unrolled into nothing.
    if ($Severity -eq 'error') { $list = $script:planErrors } else { $list = $script:planWarnings }
    foreach ($existing in $list) {
        if ($existing.code -eq $Finding.code -and [string]$existing.path -eq [string]$Finding.path) {
            return
        }
    }
    $list.Add((ConvertTo-PlanFinding -Finding $Finding))
}

function Add-PlanErrorRecord {
    param(
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Field = 'environment'
    )
    $finding = Get-InstallFinding -ErrorRecord $ErrorRecord
    if ($null -eq $finding) {
        $finding = New-InstallFinding -Code 'plan_internal_error' -Field $Field `
            -Message 'Setup hit an unexpected problem while checking this PC.' `
            -Console $ErrorRecord.Exception.Message
        $finding.detail = $ErrorRecord.Exception.Message
    }
    Add-PlanFinding -Finding $finding -Severity 'error'
}

function Invoke-PlanStage {
    param(
        [Parameter(Mandatory)][scriptblock]$Stage,
        [string]$Field = 'environment'
    )
    try {
        & $Stage
        return $true
    }
    catch {
        Add-PlanErrorRecord -ErrorRecord $_ -Field $Field
        return $false
    }
}

function Get-PlanEnvironmentPart {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Probe,
        $Default
    )
    try {
        return (& $Probe)
    }
    catch {
        $finding = New-InstallFinding -Code 'environment_probe_failed' -Field 'environment' `
            -Message "Setup could not read part of the information about this PC ($Name). The plan may be incomplete." `
            -Path $null
        $finding.detail = $_.Exception.Message
        Add-PlanFinding -Finding $finding -Severity 'warning'
        return $Default
    }
}

function Write-PlanDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json
    )
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Json + "`n")
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    Assert-FeedNoReparse -Path $Path -Label '-PlanOutput'
}

function Invoke-PlanMode {
    if ([string]::IsNullOrWhiteSpace($PlanOutput)) {
        throw '-PlanOnly requires -PlanOutput <absolute path of a new .json file in your temporary folder>.'
    }
    $outputPath = Resolve-SafeOutputPath -Path $PlanOutput -Label '-PlanOutput' -Extension '.json' `
        -AllowedRoots @([IO.Path]::GetTempPath())
    $script:planErrors = [Collections.Generic.List[object]]::new()
    $script:planWarnings = [Collections.Generic.List[object]]::new()
    $minimumFreeBytes = [long]$MinimumFreeGiB * 1GB

    # What this PC looks like.
    $volumes = @(Get-PlanEnvironmentPart -Name 'drives' -Default @() -Probe { Get-PlanVolumes -MinimumFreeBytes $minimumFreeBytes })
    $os = Get-PlanEnvironmentPart -Name 'Windows version' -Default $null -Probe { Get-OsSummary }
    $release = Get-PlanEnvironmentPart -Name '.NET Framework' -Default $null -Probe { Get-DotNetFrameworkRelease }
    $webView2 = Get-PlanEnvironmentPart -Name 'WebView2' -Default $null -Probe { Get-WebView2RuntimeVersion }
    $rewindleInstall = Get-PlanEnvironmentPart -Name 'existing installation' -Default $null -Probe { Get-RewindleInstallInfo }
    $legacy = Get-PlanEnvironmentPart -Name 'earlier edition' -Default $false -Probe { Test-LegacyEngineInstalled }
    $driveFs = Get-PlanEnvironmentPart -Name 'Google Drive' -Default ([ordered]@{ detected = $false; my_drive_root = $null }) -Probe { Get-DriveFsInfo }
    $knownFolders = @(Get-PlanEnvironmentPart -Name 'known folders' -Default @() -Probe { Get-PlanKnownFolders })
    $elevated = [bool](Get-PlanEnvironmentPart -Name 'elevation' -Default $false -Probe { Test-Administrator })
    $script:planDefaultRepository = $null
    $recommended = @($volumes | Where-Object { $_.recommended }) | Select-Object -First 1
    if ($recommended) {
        $script:planDefaultRepository = Join-Path $recommended.root $defaultRepositorySuffix
    }
    if ($installerRoots.default_repository_set) {
        $script:planDefaultRepository = $installerRoots.default_repository
    }
    $defaultSources = @(Get-PlanEnvironmentPart -Name 'default folders' -Default @() -Probe { Get-DefaultSources })

    # Validation, with the functions the real install uses. One problem per stage, one per source folder.
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        Add-PlanFinding -Severity 'error' -Finding (New-InstallFinding -Code 'os_not_64bit' -Field 'environment' `
            -Message 'Rewindle needs 64-bit Windows and the 64-bit version of Windows PowerShell.' `
            -Console 'ResticBackuper requires 64-bit Windows and a 64-bit Windows PowerShell process.')
    }
    [void](Invoke-PlanStage { Assert-MicrosoftSignedExecutable -Path $windowsPowerShell })
    [void](Invoke-PlanStage { Assert-MicrosoftSignedExecutable -Path $icacls })
    [void](Invoke-PlanStage { Assert-DotNetFramework48 })
    [void](Invoke-PlanStage { Import-TrustedScheduledTasksModule })
    if (Invoke-PlanStage { $script:payloadManifest = Assert-Payload }) {
        [void](Invoke-PlanStage { Read-PayloadVersion })
    }
    $scheduleOk = Invoke-PlanStage -Field 'schedule' { Assert-ScheduleValue }
    $storageOk = Invoke-PlanStage -Field 'storage_mode' { Resolve-StorageSettings }
    $repositoryOk = $false
    if ($storageOk -or $RepositoryStorageMode -eq 'local_ntfs') {
        $repositoryOk = Invoke-PlanStage -Field 'repository' { Resolve-RepositorySelection }
    }
    [void](Invoke-PlanStage -Field 'sources' { Resolve-SourceSelection })
    if ($repositoryOk) {
        [void](Invoke-PlanStage { Resolve-ProtectedBindings })
        [void](Invoke-PlanStage -Field 'repository' { Assert-RepositoryTarget })
    }
    foreach ($conflict in @(Get-InstallationConflicts)) {
        Add-PlanFinding -Finding $conflict -Severity 'error'
    }

    # Warnings.
    foreach ($warning in @(Get-InstallWarnings)) {
        Add-PlanFinding -Finding $warning -Severity 'warning'
    }
    if (-not $SkipDashboard -and -not $webView2) {
        Add-PlanFinding -Severity 'warning' -Finding (New-InstallFinding -Code 'webview2_missing' -Field 'environment' `
            -Message "The Microsoft Edge WebView2 component that the dashboard needs isn't installed. Setup will download it from Microsoft.")
    }
    if ($null -ne $os -and -not $os.supported) {
        Add-PlanFinding -Severity 'warning' -Finding (New-InstallFinding -Code 'os_unsupported' -Field 'environment' `
            -Message "This version of Windows isn't one Rewindle is tested on. It supports 64-bit Windows 10 and Windows 11.")
    }

    $version = if ($script:version) { $script:version } else {
        $fallback = Join-Path $scriptRoot 'VERSION'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            $text = ([IO.File]::ReadAllText($fallback)).Trim()
            if ($text -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { $text } else { $null }
        } else { $null }
    }
    $drivefsRootResolved = $null
    if ($RepositoryStorageMode -eq 'google_drivefs_stream' -and $DriveFsMyDriveRoot) {
        $drivefsRootResolved = $DriveFsMyDriveRoot
    }
    $plan = [ordered]@{
        schema = 'Rewindle.InstallPlan.v1'
        ok = ($planErrors.Count -eq 0)
        errors = @($planErrors)
        warnings = @($planWarnings)
        resolved = [ordered]@{
            repository = $script:repositoryPath
            storage_mode = $RepositoryStorageMode
            drivefs_my_drive_root = $drivefsRootResolved
            sources = @($script:sources)
            canary_source = $canarySource
            schedule = if ($scheduleOk) { $Schedule } else { $null }
            vss = [bool]$useVss
            minimum_free_bytes = $minimumFreeBytes
            estimated_source_bytes = $null
        }
        defaults = [ordered]@{
            repository = $script:planDefaultRepository
            storage_mode = 'local_ntfs'
            sources = @($defaultSources)
            schedule = '02:00'
        }
        environment = [ordered]@{
            version = $version
            os = $os
            powershell = $PSVersionTable.PSVersion.ToString()
            dotnet_framework_48 = ($null -ne $release -and $release -ge 528040)
            elevated = $elevated
            webview2 = $webView2
            existing_install = [ordered]@{
                rewindle = $rewindleInstall
                legacy_personal_edition = [bool]$legacy
            }
            volumes = @(
                foreach ($entry in $volumes) {
                    [ordered]@{
                        root = $entry.root
                        label = $entry.label
                        filesystem = $entry.filesystem
                        drive_type = $entry.drive_type
                        size_bytes = $entry.size_bytes
                        free_bytes = $entry.free_bytes
                        is_system = [bool]$entry.is_system
                        same_physical_disk_as_system = $entry.same_physical_disk_as_system
                        eligible = [bool]$entry.eligible
                        ineligible_reason = $entry.ineligible_reason
                        ineligible_message = $entry.ineligible_message
                        recommended = [bool]$entry.recommended
                    }
                }
            )
            drivefs = $driveFs
            known_folders = @($knownFolders)
        }
    }
    Write-PlanDocument -Path $outputPath -Json (ConvertTo-Json -InputObject $plan -Depth 8)
    return 0
}

if ($PlanOnly) {
    try {
        exit (Invoke-PlanMode)
    }
    catch {
        [Console]::Error.WriteLine("No plan was written: $($_.Exception.Message)")
        [Console]::Error.WriteLine($_.ScriptStackTrace)
        exit 1
    }
}

# ---------------------------------------------------------------------------------------------------------------------------
# Real installation
# ---------------------------------------------------------------------------------------------------------------------------

$installPhaseTitles = @{
    preflight = 'Checking your PC and the choices you made'
    webview2 = 'Making sure Microsoft Edge WebView2 is available'
    payload = 'Copying Rewindle onto this PC'
    canary = 'Preparing the restore test file'
    credential = 'Creating the backup password and storing it for your account'
    repository = 'Creating the encrypted backup repository'
    recovery_key = 'Writing your recovery key'
    permissions = 'Locking the Rewindle folders so only administrators can change them'
    tasks = 'Scheduling the daily backup and registering Rewindle with Windows'
    dashboard = 'Setting up the Rewindle dashboard'
    verification = 'Checking that everything was installed correctly'
    first_backup = 'Starting the first backup'
}
# What a failure in each phase is called when nothing more specific (a validation code) applies, and what is said about it.
$installPhaseFailures = @{
    preflight = @('preflight_failed', 'Setup could not finish checking this PC.')
    webview2 = @('webview2_install_failed', "Setup could not download or install Microsoft Edge WebView2, which the dashboard needs. Check your internet connection and try again.")
    payload = @('payload_copy_failed', "Setup could not copy Rewindle's program files.")
    canary = @('canary_failed', 'Setup could not prepare the restore test file.')
    credential = @('credential_failed', 'Setup could not create the backup password for your account.')
    repository = @('repository_initialization_failed', 'Setup could not create the encrypted backup repository.')
    recovery_key = @('recovery_key_failed', 'Setup could not write your recovery key.')
    permissions = @('permissions_failed', "Setup could not lock down Rewindle's folders.")
    tasks = @('task_registration_failed', 'Setup could not schedule the daily backup.')
    dashboard = @('dashboard_setup_failed', 'Setup could not set up the dashboard.')
    verification = @('verification_failed', 'Setup could not confirm that everything was installed correctly.')
}

function Start-InstallPhase {
    param([Parameter(Mandatory)][string]$Phase)
    Write-FeedPhase -Phase $Phase -State 'started' -Title $installPhaseTitles[$Phase]
}

function Complete-InstallPhase {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail
    )
    Write-FeedPhase -Phase $Phase -State 'completed' -Title $installPhaseTitles[$Phase] -Detail $Detail
}

function Skip-InstallPhase {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [string]$Detail
    )
    Write-FeedPhase -Phase $Phase -State 'skipped' -Title $installPhaseTitles[$Phase] -Detail $Detail
}

function Add-InstallWarning {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )
    $script:installWarnings.Add([ordered]@{ code = $Code; message = $Message })
}

# One initialization step creates the DPAPI credential, the repository and the recovery key. When it fails, what exists on disk
# says how far it got, so the feed blames the right phase.
function Set-InitializationFailurePhase {
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) { return }
    Complete-InstallPhase 'credential'
    Start-InstallPhase 'repository'
    if (Test-Path -LiteralPath (Join-Path $repositoryPath 'config') -PathType Leaf) {
        Complete-InstallPhase 'repository'
        Start-InstallPhase 'recovery_key'
    }
}

function Get-RecoveryKeyFacts {
    if (Test-Path -LiteralPath $recoveryKey -PathType Leaf) {
        return [ordered]@{
            path = $recoveryKey
            readable = (Test-FileReadableByUser -Path $recoveryKey)
        }
    }
    return [ordered]@{ path = $null; readable = $null }
}

function Write-InstallFailure {
    param(
        [Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord,
        [bool]$RolledBack = $false
    )
    if ($null -eq $script:FeedStream) { return }
    $phase = $script:FeedCurrentPhase
    $finding = Get-InstallFinding -ErrorRecord $ErrorRecord
    if ($null -ne $finding) {
        $code = [string]$finding.code
        $message = [string]$finding.message
    }
    elseif ($null -ne $phase -and $installPhaseFailures.ContainsKey($phase)) {
        $code = $installPhaseFailures[$phase][0]
        $message = $installPhaseFailures[$phase][1]
    }
    else {
        $code = 'setup_failed'
        $message = 'Setup could not finish.'
    }
    if ($RolledBack) {
        $message += ' Setup undid its changes. A backup repository and recovery key it had already created were kept.'
    }
    if ($phase) {
        Write-FeedPhase -Phase $phase -State 'failed' -Title $installPhaseTitles[$phase] -Detail $message
    }
    $keyFacts = Get-RecoveryKeyFacts
    Write-FeedResult -Ok $false -ErrorInfo ([ordered]@{
        code = $code
        message = $message
        detail = $ErrorRecord.Exception.Message
    }) -Fields ([ordered]@{
        install_root = $installRoot
        recovery_key_path = $keyFacts.path
        recovery_key_readable_by_user = $keyFacts.readable
        dashboard_executable = $null
        version = $script:version
        warnings = @($script:installWarnings)
    })
}

function Complete-InstallFeed {
    if (-not $script:FeedResultWritten) {
        Write-FeedResult -Ok $false -ErrorInfo ([ordered]@{
            code = 'setup_interrupted'
            message = 'Setup was stopped before it finished.'
            detail = $null
        }) -Fields ([ordered]@{
            install_root = $installRoot
            recovery_key_path = $null
            recovery_key_readable_by_user = $null
            dashboard_executable = $null
            version = $script:version
            warnings = @($script:installWarnings)
        })
    }
    Close-ProgressFeed
}

function Write-InstallSummary {
    Write-Host ''
    Write-Host "Rewindle $version installation summary" -ForegroundColor Cyan
    Write-Host "  Repository : $repositoryPath"
    Write-Host "  Storage    : $RepositoryStorageMode"
    if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        Write-Host "  DriveFS    : $DriveFsMyDriveRoot"
        Write-Host "  Cache      : $DriveFsCacheDirectory"
    }
    Write-Host "  Sources    : $($sources.Count)"
    foreach ($source in $sources) { Write-Host "    - $source" }
    if (-not $canaryAlreadyCovered) { Write-Host "    + protected restore canary ($canarySource)" }
    Write-Host "  Schedule   : $Schedule daily"
    Write-Host "  VSS        : $useVss"
    Write-Host "  Dashboard  : $(-not $SkipDashboard)"
    Write-Host '  First run  : real backup only when explicitly requested'
}

function Invoke-InstallPreflight {
    Start-InstallPhase 'preflight'
    Assert-ScheduleValue
    Assert-MicrosoftSignedExecutable -Path $windowsPowerShell
    Assert-MicrosoftSignedExecutable -Path $icacls
    Assert-DotNetFramework48

    if (-not (Test-Administrator)) {
        Invoke-SelfElevation
    }

    $script:identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $script:currentSid = $identity.User.Value
    if ($ExpectedUserSid -and $ExpectedUserSid -ne $currentSid) {
        Stop-InstallValidation -Code 'expected_user_mismatch' -Field 'environment' `
            -Message 'Setup was approved with a different Windows account than the one that started it. Run setup again and approve it with your own account.' `
            -Console 'Approve elevation with the same Windows account. CurrentUser DPAPI cannot be installed through a different administrator account.'
    }
    Import-TrustedScheduledTasksModule
    $script:payloadManifest = Assert-Payload
    Read-PayloadVersion
    Resolve-StorageSettings
    Resolve-RepositorySelection
    Resolve-SourceSelection
    Resolve-ProtectedBindings
    Assert-RepositoryTarget
    $conflicts = @(Get-InstallationConflicts)
    if ($conflicts.Count -gt 0) {
        Stop-InstallFinding -Finding $conflicts[0]
    }

    Write-InstallSummary
    foreach ($warning in @(Get-InstallWarnings)) {
        if ($warning.console) {
            Write-Warning $warning.console
        }
    }
    if (-not $Unattended) {
        $confirmation = Read-Host 'Install this configuration? [y/N]'
        if ($confirmation -notmatch '^(?i)y(?:es)?$') {
            throw 'Installation cancelled before any product files were created.'
        }
    }
    Complete-InstallPhase 'preflight'
}

function Invoke-WebView2Phase {
    if ($SkipDashboard) {
        Skip-InstallPhase 'webview2' 'The dashboard was not requested.'
        return
    }
    Start-InstallPhase 'webview2'
    $alreadyPresent = [bool](Get-WebView2RuntimeVersion)
    $script:webView2RuntimeVersion = Ensure-WebView2Runtime
    Write-Host "  WebView2   : $webView2RuntimeVersion" -ForegroundColor DarkGray
    Complete-InstallPhase 'webview2' $(if ($alreadyPresent) { "Already installed (version $webView2RuntimeVersion)." } else { "Installed (version $webView2RuntimeVersion)." })
}

# Read-only checks of what the installation just created. A failure here fails the install, so each check is a definite fact.
function Assert-InstallationVerified {
    function Stop-Verification {
        param([string]$What)
        Stop-InstallValidation -Code 'verification_failed' -Field 'environment' `
            -Message "Setup finished, but could not confirm that $What." -Console "Installation verification failed: $What."
    }
    $backupTask = Get-ScheduledTask -TaskName $backupTaskName -ErrorAction SilentlyContinue
    if (-not $backupTask) { Stop-Verification 'the daily backup task exists' }
    if ($backupTask.State -eq 'Disabled') { Stop-Verification 'the daily backup task is turned on' }
    $backupActions = @($backupTask.Actions)
    if ($backupActions.Count -ne 1 -or
        (Get-NormalizedPath ([string]$backupActions[0].Execute)) -ne (Get-NormalizedPath (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe'))) {
        Stop-Verification 'the daily backup task runs the Rewindle backup program'
    }
    if (-not $SkipDashboard) {
        if (-not (Get-ScheduledTask -TaskName $dashboardTaskName -ErrorAction SilentlyContinue)) { Stop-Verification 'the dashboard start-up task exists' }
        if (-not (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)) { Stop-Verification 'the Start menu shortcut exists' }
    }
    if (-not (Test-Path -LiteralPath $installRegistry)) { Stop-Verification 'Rewindle is listed in Installed apps' }
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) { Stop-Verification 'the backup password is stored for your account' }
    if (-not (Test-Path -LiteralPath $recoveryKey -PathType Leaf)) { Stop-Verification 'the recovery key was written' }
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryPath 'config') -PathType Leaf)) { Stop-Verification 'the backup repository was created' }
    if (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'repository.json') -PathType Leaf)) { Stop-Verification 'the repository was recorded' }
    if (-not (Test-Path -LiteralPath $canaryFile -PathType Leaf)) { Stop-Verification 'the restore test file exists' }
    $manifestPath = Join-Path $installRoot 'runtime-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Stop-Verification 'the list of installed files exists' }
    $installed = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    foreach ($entry in @($installed.files)) {
        $path = Join-Path $installRoot ([string]$entry.relative_path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path -Force).Length -ne [long]$entry.bytes) {
            Stop-Verification "the installed file $($entry.relative_path) is intact"
        }
    }
}

# Real installation: validate (the preflight phase), make sure WebView2 is present, then change the machine.
$preflightSucceeded = $false
$progressOpened = $false
try {
    if ($ProgressPath -and (Test-Administrator)) {
        Open-ProgressFeed -Path $ProgressPath -ExpectedSid $ExpectedUserSid
        $progressOpened = $true
    }
    Invoke-InstallPreflight
    Invoke-WebView2Phase
    $preflightSucceeded = $true
}
catch {
    Write-InstallFailure -ErrorRecord $_
    throw
}
finally {
    if (-not $preflightSucceeded -and $progressOpened) {
        Complete-InstallFeed
    }
}

try {
    Start-InstallPhase 'payload'
    if (-not (Test-Path -LiteralPath $repositoryParent -PathType Container)) {
        New-Item -ItemType Directory -Path $repositoryParent -Force | Out-Null
    }
    if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        Assert-DriveFsProviderTransaction -Directory $repositoryParent
    }
    New-Item -ItemType Directory -Path $installRoot | Out-Null
    $runtimeCreated = $true
    foreach ($item in Get-ChildItem -LiteralPath $payloadRoot -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $installRoot -Recurse -Force
    }
    Assert-TreeMatchesManifest -Root $installRoot -Manifest $payloadManifest -Label 'Installed payload' -Code 'payload_copy_failed'

    $stateDirectory = $stateRoot
    $configPath = Join-Path $installRoot 'backup-config.json'
    $configuration = [ordered]@{
        schema_version = 1
        plan_id = [Guid]::NewGuid().ToString('D')
        config_generation = 1
        repository = $repositoryPath
        repository_storage_mode = $RepositoryStorageMode
        repository_volume_serial = $volume.serial
        restic_executable = Join-Path $installRoot 'restic.exe'
        recovery_tools_directory = $recoveryTools
        python_executable = Join-Path $installRoot 'Python\python.exe'
        state_directory = $stateDirectory
        secret_file = $secretFile
        recovery_key_file = $recoveryKey
        exclude_file = Join-Path $installRoot 'excludes.txt'
        canary_file = $canaryFile
        hostname = [Environment]::MachineName
        scheduled_tag = 'scheduled'
        minimum_free_gib = $MinimumFreeGiB
        read_concurrency = 4
        use_vss = $useVss
        structural_check_after_backup = $true
        read_data_subset_weekday = 'Sunday'
        read_data_subset_parts = 30
        cloud_placeholder_policy = 'strict'
        change_anomaly = [ordered]@{
            enabled = $true
            file_change_ratio = 0.35
            deletion_ratio = 0.15
            data_added_ratio = 0.50
            minimum_changed_files = 1000
        }
        sources = @($configuredSources)
        source_identities = $sourceIdentities
    }
    if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        $configuration['drivefs_my_drive_root'] = $DriveFsMyDriveRoot
        $configuration['drivefs_cache_directory'] = $DriveFsCacheDirectory
    }
    Write-Utf8NoBom -Path $configPath -Text ($configuration | ConvertTo-Json -Depth 5)
    $runtimeManifest = New-RuntimeManifest -Root $installRoot -Version $version
    Complete-InstallPhase 'payload'

    Start-InstallPhase 'canary'
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot | Out-Null
    }
    else {
        Assert-NormalDirectory -Path $stateRoot
    }
    if (-not (Test-Path -LiteralPath $canarySource)) {
        New-Item -ItemType Directory -Path $canarySource | Out-Null
    }
    else {
        Assert-NormalDirectory -Path $canarySource
    }
    if (-not (Test-Path -LiteralPath $canaryFile)) {
        Copy-Item -LiteralPath (Join-Path $installRoot 'backup-canary.txt') -Destination $canaryFile
    }
    else {
        $canaryItem = Get-Item -LiteralPath $canaryFile -Force
        if ($canaryItem.PSIsContainer -or ($canaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Restore canary is not a regular file: $canaryFile"
        }
    }
    Complete-InstallPhase 'canary'

    # One initializer creates the DPAPI credential, the repository and the recovery key, so the three phases finish together.
    Start-InstallPhase 'credential'
    $python = Join-Path $installRoot 'Python\python.exe'
    $initializer = Join-Path $installRoot 'initialize_repository.py'
    Push-Location $installRoot
    try {
        & $python -I -S -B $initializer --config $configPath
        if ($LASTEXITCODE -ne 0) {
            throw "Repository initialization failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
    Complete-InstallPhase 'credential'
    Start-InstallPhase 'repository'
    Complete-InstallPhase 'repository' $(if ($repositoryPreviouslyInitialized) { 'An existing backup repository was reused.' })
    Start-InstallPhase 'recovery_key'
    Complete-InstallPhase 'recovery_key'

    Start-InstallPhase 'permissions'
    Set-ProtectedDirectory -Path $installRoot -UserSid $currentSid
    Set-ProtectedDirectory -Path $stateRoot -UserSid $currentSid
    if ($RepositoryStorageMode -eq 'local_ntfs') {
        Set-ProtectedDirectory -Path $repositoryPath -UserSid $currentSid
    }
    if (Test-Path -LiteralPath $recoveryTools -PathType Container) {
        Set-ProtectedDirectory -Path $recoveryTools -UserSid $currentSid
    }
    Complete-InstallPhase 'permissions'

    Start-InstallPhase 'tasks'
    $scheduleTime = [DateTime]::Today.Add([TimeSpan]::ParseExact($Schedule, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture))
    $backupAction = New-ScheduledTaskAction -Execute (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe') -WorkingDirectory $installRoot
    $backupTrigger = New-ScheduledTaskTrigger -Daily -At $scheduleTime
    $backupSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 7
    $backupPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $backupTaskName -Action $backupAction -Trigger $backupTrigger -Settings $backupSettings -Principal $backupPrincipal -Description 'Verified encrypted incremental Restic backup supervised by ResticBackuper.' | Out-Null
    $backupTaskCreated = $true

    New-Item -Path $installRegistry | Out-Null
    $registryCreated = $true
    New-ItemProperty -Path $installRegistry -Name DisplayName -Value 'Rewindle' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $installRegistry -Name DisplayVersion -Value $version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $installRegistry -Name Publisher -Value 'Victor Sotero' -PropertyType String -Force | Out-Null
    # The same project address as the dashboard's About section (src\dashboard\web\src\project.ts).
    New-ItemProperty -Path $installRegistry -Name URLInfoAbout -Value 'https://github.com/50sotero/rewindle' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $installRegistry -Name InstallLocation -Value $installRoot -PropertyType String -Force | Out-Null
    $uninstallCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $windowsPowerShell, (Join-Path $installRoot 'Uninstall-ResticBackuper.ps1')
    New-ItemProperty -Path $installRegistry -Name UninstallString -Value $uninstallCommand -PropertyType String -Force | Out-Null
    $quietUninstallCommand = $uninstallCommand + ' -Unattended'
    New-ItemProperty -Path $installRegistry -Name QuietUninstallString -Value $quietUninstallCommand -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $installRegistry -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $installRegistry -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null
    Complete-InstallPhase 'tasks'

    if (-not $SkipDashboard) {
        Start-InstallPhase 'dashboard'
        $dashboard = Join-Path $installRoot 'ResticBackuperDashboard.exe'
        $dashboardArguments = '--minimized --state-dir "{0}"' -f $stateRoot
        $dashboardAction = New-ScheduledTaskAction -Execute $dashboard -Argument $dashboardArguments -WorkingDirectory $installRoot
        $dashboardTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
        $dashboardSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $dashboardPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $dashboardTaskName -Action $dashboardAction -Trigger $dashboardTrigger -Settings $dashboardSettings -Principal $dashboardPrincipal -Description 'Least-privilege ResticBackuper dashboard with UAC-protected actions.' | Out-Null
        $dashboardTaskCreated = $true

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($startMenuShortcut)
        $shortcut.TargetPath = $dashboard
        $shortcut.Arguments = '--state-dir "{0}"' -f $stateRoot
        $shortcut.WorkingDirectory = $installRoot
        $shortcut.IconLocation = $dashboard + ',0'
        $shortcut.Description = 'Open the Rewindle dashboard'
        $shortcut.Save()
        $shortcutCreated = $true

        $dashboardDetail = $null
        try {
            Start-ScheduledTask -TaskName $dashboardTaskName
        }
        catch {
            Write-Warning "Dashboard auto-start failed; it remains installed and will retry at next logon: $($_.Exception.Message)"
            $dashboardDetail = 'The dashboard could not be started right now. It is installed and will start the next time you sign in.'
            Add-InstallWarning -Code 'dashboard_autostart_failed' -Message $dashboardDetail
        }
        Complete-InstallPhase 'dashboard' $dashboardDetail
    }
    else {
        Skip-InstallPhase 'dashboard' 'The dashboard was not requested.'
    }

    Start-InstallPhase 'verification'
    Assert-InstallationVerified
    $recoveryKeyReadable = Test-FileReadableByUser -Path $recoveryKey
    $verificationDetail = $null
    if ($recoveryKeyReadable -ne $true) {
        $verificationDetail = 'Your recovery key is stored where only an administrator can open it. Setup will need to help you save a copy.'
        Add-InstallWarning -Code 'recovery_key_not_readable_by_user' -Message $verificationDetail
    }
    Complete-InstallPhase 'verification' $verificationDetail

    if ($StartBackup) {
        Start-InstallPhase 'first_backup'
        try {
            Start-ScheduledTask -TaskName $backupTaskName
            $firstBackupStarted = $true
            Complete-InstallPhase 'first_backup'
        }
        catch {
            Write-Warning "The first backup did not start automatically; the scheduled installation remains intact: $($_.Exception.Message)"
            $firstBackupDetail = 'The first backup could not be started automatically. Start it from the dashboard.'
            Add-InstallWarning -Code 'first_backup_not_started' -Message $firstBackupDetail
            Skip-InstallPhase 'first_backup' $firstBackupDetail
        }
    }
    else {
        Skip-InstallPhase 'first_backup' 'A first backup was not requested.'
    }

    Write-Host ''
    Write-Host 'Rewindle installed successfully.' -ForegroundColor Green
    Write-Host "Recovery key: $recoveryKey" -ForegroundColor Yellow
    Write-Host 'Copy that key off this computer before relying on the backup.' -ForegroundColor Yellow
    if (-not $firstBackupStarted) {
        Write-Host "Start the first real backup with: Start-ScheduledTask -TaskName '$backupTaskName'"
    }
    [pscustomobject]@{
        product = $productName
        version = $version
        repository = $repositoryPath
        repository_storage_mode = $RepositoryStorageMode
        source_count = $configuredSources.Count
        user_source_count = $sources.Count
        schedule = $Schedule
        use_vss = $useVss
        webview2_runtime = $webView2RuntimeVersion
        backup_task = $backupTaskName
        dashboard_task = if ($dashboardTaskCreated) { $dashboardTaskName } else { $null }
        first_backup_started = $firstBackupStarted
        recovery_key_file = $recoveryKey
        repository_preserved_on_uninstall = $true
    } | ConvertTo-Json -Depth 4
    Write-FeedResult -Ok $true -ErrorInfo $null -Fields ([ordered]@{
        install_root = $installRoot
        recovery_key_path = $recoveryKey
        recovery_key_readable_by_user = $recoveryKeyReadable
        dashboard_executable = if ($SkipDashboard) { $null } else { Join-Path $installRoot 'ResticBackuperDashboard.exe' }
        version = $version
        warnings = @($script:installWarnings)
    })
    exit 0
}
catch {
    $caught = $_
    $failure = $caught.Exception.Message
    if ($script:FeedCurrentPhase -eq 'credential') {
        Set-InitializationFailurePhase
    }
    if ($dashboardTaskCreated) {
        Unregister-ScheduledTask -TaskName $dashboardTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($backupTaskCreated) {
        Unregister-ScheduledTask -TaskName $backupTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($shortcutCreated -and (Test-Path -LiteralPath $startMenuShortcut)) {
        Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue
    }
    if ($registryCreated -and (Test-Path -LiteralPath $installRegistry)) {
        Remove-Item -LiteralPath $installRegistry -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($runtimeCreated -and (Test-Path -LiteralPath $installRoot)) {
        $resolved = [IO.Path]::GetFullPath($installRoot)
        $expected = [IO.Path]::GetFullPath((Join-Path $programFilesRoot $productName))
        if ($resolved -eq $expected) {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-InstallFailure -ErrorRecord $caught -RolledBack $true
    Write-Error "INSTALLATION FAILED: $failure`nRepository, recovery key, recovery tools, and ProgramData state are intentionally preserved if they were created."
    exit 1
}
finally {
    Complete-InstallFeed
}
