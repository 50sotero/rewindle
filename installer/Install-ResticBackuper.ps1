[CmdletBinding()]
param(
    [string]$Repository,
    [ValidateSet('local_ntfs', 'google_drivefs_stream')]
    [string]$RepositoryStorageMode = 'local_ntfs',
    [string]$DriveFsMyDriveRoot,
    [string]$DriveFsCacheDirectory,
    [string]$SourceList,
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$Schedule = '02:00',
    [ValidateRange(1, 1048576)]
    [int]$MinimumFreeGiB = 10,
    [switch]$DisableVss,
    [switch]$SkipDashboard,
    [switch]$StartBackup,
    [switch]$Unattended,
    [string]$ExpectedUserSid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
$invocationParameters = @{} + $PSBoundParameters

if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'ResticBackuper requires 64-bit Windows and a 64-bit Windows PowerShell process.'
}

$productName = 'ResticBackuper'
$backupTaskName = 'ResticBackuper'
$dashboardTaskName = 'ResticBackuperDashboard'
$primaryTaskEvidenceName = 'scheduled-task.xml'
$cloudTaskEvidenceName = 'google-drive-verification-task.xml'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadRoot = Join-Path $scriptRoot 'payload'
$payloadManifestPath = Join-Path $scriptRoot 'payload-manifest.json'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$userProfileRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
$systemDirectory = [Environment]::SystemDirectory
$installRoot = Join-Path $programFilesRoot $productName
$stateRoot = Join-Path $programDataRoot $productName
$installRegistry = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResticBackuper'
$startMenuShortcut = Join-Path $programDataRoot 'Microsoft\Windows\Start Menu\Programs\ResticBackuper.lnk'
$icacls = Join-Path $systemDirectory 'icacls.exe'
$windowsPowerShell = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
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

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-DotNetFramework48 {
    $frameworkKey = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    try {
        $release = [long](Get-ItemProperty -LiteralPath $frameworkKey -Name Release -ErrorAction Stop).Release
    }
    catch {
        throw 'ResticBackuper requires the Microsoft .NET Framework 4.8 desktop runtime.'
    }
    if ($release -lt 528040) {
        throw "ResticBackuper requires the Microsoft .NET Framework 4.8 desktop runtime (release 528040 or newer); found release $release."
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
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a normal, non-reparse directory: $Path"
    }
}

function Assert-NoReparsePath {
    param(
        [string]$Path,
        [switch]$Recurse
    )
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not accepted in protected paths: $current"
            }
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    if ($Recurse -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $reparse = Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
        if ($reparse) {
            throw "Reparse point found in a protected tree: $($reparse.FullName)"
        }
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

function Assert-TreeMatchesManifest {
    param(
        [string]$Root,
        [object]$Manifest,
        [string]$Label
    )
    Assert-NormalDirectory -Path $Root
    Assert-NoReparsePath -Path $Root -Recurse
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($entry in $Manifest.files) {
        $relative = [string]$entry.relative_path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..' -or -not $seen.Add($relative)) {
            throw "Unsafe or duplicate $Label path: $relative"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $Root $relative))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label path escapes its root: $relative"
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "$Label entry is not a regular file: $relative"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($item.Length -ne [long]$entry.bytes -or $hash -ne [string]$entry.sha256) {
            throw "$Label integrity check failed: $relative"
        }
    }
    $actual = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)
    if ($actual.Count -ne $Manifest.file_count) {
        throw "$Label has unmanifested or missing files."
    }
    foreach ($file in $actual) {
        $relative = $file.FullName.Substring($Root.Length + 1)
        if (-not $seen.Contains($relative)) {
            throw "$Label contains an unmanifested file: $relative"
        }
    }
}

function Assert-DashboardAssetsManifest {
    param(
        [string]$Root,
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Dashboard assets manifest is missing: $ManifestPath"
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or -not ($manifest.PSObject.Properties.Name -contains 'files')) {
        throw 'Dashboard assets manifest schema is invalid.'
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
            throw "Dashboard assets manifest contains an unsafe or duplicate path: $relative"
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
            throw "Dashboard assets manifest contains an unexpected path: $relative"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $Root $relative))
        $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Dashboard assets manifest path escapes its root: $relative"
        }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Dashboard assets manifest member is not a regular file: $relative"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        [long]$bytes = 0
        if (
            -not [long]::TryParse([string]$entry.bytes, [ref]$bytes) -or
            $bytes -lt 0 -or
            $item.Length -ne $bytes -or
            $hash -ne [string]$entry.sha256
        ) {
            throw "Dashboard assets manifest integrity check failed: $relative"
        }
    }
    foreach ($required in @(
        'web\index.html',
        'Microsoft.Web.WebView2.Core.dll',
        'Microsoft.Web.WebView2.Wpf.dll',
        'WebView2Loader.dll'
    )) {
        if (-not $seen.Contains($required)) {
            throw "Dashboard assets manifest is missing required member: $required"
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
        Assert-MicrosoftSignedExecutable -Path $bootstrapper
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
        throw "Installer payload is missing: $payloadRoot"
    }
    if (-not (Test-Path -LiteralPath $payloadManifestPath -PathType Leaf)) {
        throw "Installer payload manifest is missing: $payloadManifestPath"
    }
    $manifest = Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.file_count -ne @($manifest.files).Count) {
        throw 'Installer payload manifest header/count is invalid.'
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
            throw "Installer payload lacks a required component: $relative"
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
            throw "RecoveryTools contains an unexpected entry: $($entry.FullName)"
        }
    }
    if ($expected.Count -ne 0) {
        $missing = @($expected | Sort-Object) -join ', '
        throw "RecoveryTools is incomplete; missing: $missing"
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Path 'recovery-manifest.json') -Raw | ConvertFrom-Json
    $recoveryConfig = Get-Content -LiteralPath (Join-Path $Path 'backup-config.json') -Raw | ConvertFrom-Json
    if (
        $manifest.schema_version -ne 1 -or
        (Get-NormalizedPath ([string]$manifest.repository)) -ne (Get-NormalizedPath $RepositoryPath) -or
        (Get-NormalizedPath ([string]$recoveryConfig.repository)) -ne (Get-NormalizedPath $RepositoryPath)
    ) {
        throw 'RecoveryTools belongs to another repository or has invalid metadata.'
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
        return (Join-Path $candidates[0].RootDirectory.FullName 'ResticBackups\Personal')
    }
    return $null
}

function Get-DefaultSources {
    $candidates = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyVideos),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyMusic),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Favorites),
        (Join-Path $userProfileRoot 'Downloads'),
        (Join-Path $userProfileRoot 'Saved Games')
    )
    return @(
        $candidates |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
            ForEach-Object { [IO.Path]::GetFullPath($_) } |
            Select-Object -Unique
    )
}

function Assert-SourceDrive {
    param(
        [string]$Directory,
        [bool]$UseVss
    )
    $root = [IO.Path]::GetPathRoot($Directory)
    if ([string]::IsNullOrWhiteSpace($root) -or $root -notmatch '^[A-Za-z]:\\$') {
        throw "Backup sources must use a local drive-letter path; UNC and network sources are not supported: $Directory"
    }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or
        $drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) {
        throw "A backup source must be on a ready local fixed or removable drive: $Directory"
    }
    if ($UseVss -and
        ($drive.DriveType -ne [IO.DriveType]::Fixed -or
         -not [string]::Equals([string]$drive.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase))) {
        throw "VSS is enabled, so every source must be on a ready local fixed NTFS volume; use -DisableVss only for supported local removable or non-NTFS sources: $Directory"
    }
}

function Get-RepositoryVolume {
    param([string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    if (-not $root -or $root.StartsWith('\\')) {
        throw 'The alpha installer supports only local drive-letter repositories.'
    }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or $drive.DriveType -notin @([IO.DriveType]::Removable, [IO.DriveType]::Fixed)) {
        throw 'The alpha installer accepts only ready local fixed or removable drive-letter repositories.'
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
        throw "Could not read the repository volume serial: $root"
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
    return [ordered]@{
        root = $root
        serial = ([string]$records[0].VolumeSerialNumber).ToUpperInvariant()
        filesystem = [string]$drive.DriveFormat
        drive_type = [int]$drive.DriveType
        free_bytes = [long]$drive.AvailableFreeSpace
        maximum_component_length = [long]$details[1]
        filesystem_flags = [long]$details[2]
    }
}

function Assert-NtfsProtectedPath {
    param(
        [string]$Path,
        [string]$Label
    )
    $volume = Get-RepositoryVolume -Path $Path
    if (-not [string]::Equals([string]$volume.filesystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must remain on NTFS; observed $($volume.filesystem) at $($volume.root)"
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

Assert-MicrosoftSignedExecutable -Path $windowsPowerShell
Assert-MicrosoftSignedExecutable -Path $icacls
Assert-DotNetFramework48

if (-not (Test-Administrator)) {
    Invoke-SelfElevation
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $identity.User.Value
if ($ExpectedUserSid -and $ExpectedUserSid -ne $currentSid) {
    throw 'Approve elevation with the same Windows account. CurrentUser DPAPI cannot be installed through a different administrator account.'
}
Import-TrustedScheduledTasksModule
$payloadManifest = Assert-Payload
$versionFile = Join-Path $payloadRoot 'VERSION'
if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw 'Payload VERSION file is missing.'
}
$version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Payload version is invalid: $version"
}

$expectedDriveFsRoot = 'G:\My Drive'
$expectedDriveFsCache = Join-Path ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::LocalApplicationData)) 'Google\DriveFS'
if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
    if ([string]::IsNullOrWhiteSpace($DriveFsMyDriveRoot)) {
        $DriveFsMyDriveRoot = $expectedDriveFsRoot
    }
    if ([string]::IsNullOrWhiteSpace($DriveFsCacheDirectory)) {
        $DriveFsCacheDirectory = $expectedDriveFsCache
    }
    $DriveFsMyDriveRoot = Get-NormalizedPath $DriveFsMyDriveRoot
    $DriveFsCacheDirectory = Get-NormalizedPath $DriveFsCacheDirectory
    if (-not [string]::Equals($DriveFsMyDriveRoot, $expectedDriveFsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "google_drivefs_stream requires the exact My Drive root $expectedDriveFsRoot"
    }
    if (-not [string]::Equals($DriveFsCacheDirectory, $expectedDriveFsCache, [StringComparison]::OrdinalIgnoreCase)) {
        throw "drivefs_cache_directory must be the current user's Google DriveFS cache: $expectedDriveFsCache"
    }
}
elseif ($invocationParameters.ContainsKey('DriveFsMyDriveRoot') -or
    $invocationParameters.ContainsKey('DriveFsCacheDirectory')) {
    throw 'DriveFS path parameters require -RepositoryStorageMode google_drivefs_stream.'
}

if (-not $Repository) {
    if ($Unattended) {
        throw '-Repository is required with -Unattended.'
    }
    $defaultRepository = if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
        Join-Path $DriveFsMyDriveRoot 'ResticBackups\Personal'
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
        $Repository = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultRepository } else { $answer.Trim() }
    }
    else {
        $answer = Read-Host 'Repository path on a local NTFS volume (prefer a separate physical drive)'
        if ([string]::IsNullOrWhiteSpace($answer)) {
            throw 'A repository path is required; no safe non-system default was found.'
        }
        $Repository = $answer.Trim()
    }
}
$repositoryPath = Get-NormalizedPath $Repository
$repositoryParent = Split-Path -Parent $repositoryPath
if (-not $repositoryParent) {
    throw 'Repository must not be a drive root.'
}
$recoveryTools = if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
    Join-Path $programDataRoot 'ResticBackuperRecoveryTools'
} else {
    Join-Path $repositoryParent 'RecoveryTools'
}
if ($RepositoryStorageMode -eq 'google_drivefs_stream' -and
    ((-not (Test-IsWithin -Candidate $repositoryPath -Parent $DriveFsMyDriveRoot)) -or
     [string]::Equals($repositoryPath, $DriveFsMyDriveRoot, [StringComparison]::OrdinalIgnoreCase))) {
    throw "A google_drivefs_stream repository must be strictly beneath $DriveFsMyDriveRoot"
}
foreach ($protectedPath in @($installRoot, $stateRoot, $recoveryTools)) {
    if ((Test-IsWithin -Candidate $repositoryPath -Parent $protectedPath) -or (Test-IsWithin -Candidate $protectedPath -Parent $repositoryPath)) {
        throw "Repository overlaps a protected ResticBackuper path: $protectedPath"
    }
}
Assert-NoReparsePath -Path $repositoryPath -Recurse
Assert-NoReparsePath -Path $repositoryParent
Assert-NoReparsePath -Path $recoveryTools -Recurse
Assert-NoReparsePath -Path $installRoot
Assert-NoReparsePath -Path $stateRoot -Recurse
if ($RepositoryStorageMode -eq 'google_drivefs_stream') {
    Assert-NoReparsePath -Path $DriveFsMyDriveRoot
    Assert-NoReparsePath -Path $DriveFsCacheDirectory -Recurse
}
foreach ($existingDirectory in @($repositoryPath, $repositoryParent, $recoveryTools, $stateRoot)) {
    if (Test-Path -LiteralPath $existingDirectory) {
        Assert-NormalDirectory -Path $existingDirectory
    }
}
Assert-RecoveryToolsCompatible -Path $recoveryTools -RepositoryPath $repositoryPath
$repositoryPreviouslyInitialized = Test-Path -LiteralPath (Join-Path $repositoryPath 'config') -PathType Leaf
if ((Test-Path -LiteralPath $repositoryPath -PathType Container) -and -not $repositoryPreviouslyInitialized) {
    if (@(Get-ChildItem -LiteralPath $repositoryPath -Force | Select-Object -First 1).Count -gt 0) {
        throw "Repository path is nonempty but is not a Restic repository: $repositoryPath"
    }
}

if (-not $SourceList) {
    $defaults = Get-DefaultSources
    if ($Unattended) {
        throw '-SourceList is required with -Unattended.'
    }
    $shown = $defaults -join ';'
    $answer = Read-Host "Source folders, separated by semicolons [$shown]"
    $SourceList = if ([string]::IsNullOrWhiteSpace($answer)) { $shown } else { $answer.Trim() }
}
$useVss = -not $DisableVss
$sourceCandidates = @($SourceList.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($sourceCandidates.Count -eq 0) {
    throw 'At least one source directory is required.'
}
$sourceSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$sources = @()
foreach ($candidate in $sourceCandidates) {
    $source = Get-NormalizedPath $candidate
    # Reject UNC/network and unsupported drive classes before any filesystem
    # probe can contact a remote path or accept a source the manager cannot edit.
    Assert-SourceDrive -Directory $source -UseVss $useVss
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Source directory does not exist: $source"
    }
    if (-not $sourceSet.Add($source)) {
        throw "Duplicate source directory: $source"
    }
    foreach ($existingSource in $sources) {
        if ((Test-IsWithin -Candidate $source -Parent $existingSource) -or (Test-IsWithin -Candidate $existingSource -Parent $source)) {
            throw "Configured sources must not contain one another: $source and $existingSource"
        }
    }
    Assert-NoReparsePath -Path $source
    if ((Test-IsWithin -Candidate $repositoryPath -Parent $source) -or (Test-IsWithin -Candidate $source -Parent $repositoryPath)) {
        throw "Repository and source overlap: $source"
    }
    foreach ($protectedPath in @($installRoot, $stateRoot)) {
        if ((Test-IsWithin -Candidate $source -Parent $protectedPath) -or (Test-IsWithin -Candidate $protectedPath -Parent $source)) {
            throw "Source overlaps ResticBackuper runtime/state and is unsupported in this alpha: $source"
        }
    }
    $sources += $source
}

$canarySource = Join-Path $stateRoot 'Canary'
$canaryFile = Join-Path $canarySource 'backup-canary.txt'
if ((Test-IsWithin -Candidate $repositoryPath -Parent $canarySource) -or (Test-IsWithin -Candidate $canarySource -Parent $repositoryPath)) {
    throw 'The repository overlaps ResticBackuper protected canary state. Choose another repository path.'
}
$configuredSources = @($sources)
$canaryAlreadyCovered = $false
foreach ($source in $sources) {
    if (Test-IsWithin -Candidate $canaryFile -Parent $source) {
        $canaryAlreadyCovered = $true
        break
    }
}
if (-not $canaryAlreadyCovered) {
    $configuredSources += $canarySource
}
foreach ($source in $configuredSources) {
    Assert-SourceDrive -Directory $source -UseVss $useVss
}
$sourceIdentities = [ordered]@{}
foreach ($source in $configuredSources) {
    $sourceVolume = Get-RepositoryVolume -Path $source
    $sourceIdentities[$source] = [ordered]@{
        expected_volume_serial = ([string]$sourceVolume.serial).ToUpperInvariant()
    }
}
$recoveryKey = Join-Path $userProfileRoot 'ResticBackuper-RecoveryKey.txt'
$secretFile = Join-Path $stateRoot 'repository-password.dpapi.json'
Assert-NoReparsePath -Path $recoveryKey
if (Test-Path -LiteralPath $recoveryKey) {
    $recoveryKeyItem = Get-Item -LiteralPath $recoveryKey -Force
    if ($recoveryKeyItem.PSIsContainer -or ($recoveryKeyItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Recovery key path is not a regular file: $recoveryKey"
    }
    if (-not (Test-Path -LiteralPath $secretFile -PathType Leaf)) {
        throw "A recovery key already exists but the matching DPAPI credential is absent. Move the stale key aside only after identifying it: $recoveryKey"
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

$volume = Get-RepositoryVolume -Path $repositoryPath
if ($RepositoryStorageMode -eq 'local_ntfs') {
    if (-not [string]::Equals([string]$volume.filesystem, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw "local_ntfs requires an NTFS repository volume; observed $($volume.filesystem)."
    }
}
else {
    if (-not (Test-Path -LiteralPath $DriveFsMyDriveRoot -PathType Container)) {
        throw "Google DriveFS My Drive is unavailable: $DriveFsMyDriveRoot"
    }
    Assert-NormalDirectory -Path $DriveFsMyDriveRoot
    if (-not (Get-Process -Name GoogleDriveFS -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        throw 'Google DriveFS provider process is not running.'
    }
    if ([int]$volume.drive_type -ne [int][IO.DriveType]::Fixed -or
        -not [string]::Equals([string]$volume.filesystem, 'FAT32', [StringComparison]::OrdinalIgnoreCase) -or
        ([long]$volume.filesystem_flags -band 0x100) -eq 0 -or
        [long]$volume.maximum_component_length -lt 64) {
        throw 'The selected path is not the supported Google DriveFS streaming FAT32 mount.'
    }
    if (-not (Test-Path -LiteralPath $DriveFsCacheDirectory -PathType Container)) {
        throw "Google DriveFS cache directory is unavailable: $DriveFsCacheDirectory"
    }
    Assert-NormalDirectory -Path $DriveFsCacheDirectory
    Assert-NtfsProtectedPath -Path $DriveFsCacheDirectory -Label 'Google DriveFS cache'
    $cacheFreeBytes = [long]([IO.DriveInfo]::new(
        [IO.Path]::GetPathRoot($DriveFsCacheDirectory))).AvailableFreeSpace
    $minimumCacheBytes = [Math]::Max([long]$MinimumFreeGiB * 1GB, [long]10GB)
    if ($cacheFreeBytes -lt $minimumCacheBytes) {
        throw "Google DriveFS cache has less than $([Math]::Round($minimumCacheBytes / 1GB, 1)) GiB free."
    }
    if (Test-Path -LiteralPath $repositoryPath -PathType Container) {
        $oversized = Get-ChildItem -LiteralPath $repositoryPath -Recurse -File -Force |
            Where-Object { $_.Length -ge [long]4GB } |
            Select-Object -First 1
        if ($oversized) {
            throw "DriveFS cannot host a repository object of 4 GiB or larger: $($oversized.FullName)"
        }
    }
}
$minimumBytes = [long]$MinimumFreeGiB * 1GB
if ($volume.free_bytes -lt $minimumBytes) {
    throw "Repository volume has less than $MinimumFreeGiB GiB free."
}

if (Test-Path -LiteralPath $installRoot) {
    throw "ResticBackuper is already installed at $installRoot. This alpha refuses in-place upgrades; uninstall the app binaries first (data is preserved)."
}
if (Test-Path -LiteralPath $installRegistry) {
    throw 'A ResticBackuper uninstall registration already exists. Remove the prior app installation first.'
}
if (-not $SkipDashboard -and (Test-Path -LiteralPath $startMenuShortcut)) {
    throw "A Start Menu item already occupies the ResticBackuper shortcut path: $startMenuShortcut"
}
foreach ($taskName in @($backupTaskName, $dashboardTaskName)) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        throw "A scheduled task already uses the product name: $taskName"
    }
}

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
$systemVolume = [IO.Path]::GetPathRoot($systemDirectory)
$repositoryOnSystemVolume = $volume.root -eq $systemVolume
if ($RepositoryStorageMode -eq 'local_ntfs' -and $repositoryOnSystemVolume) {
    Write-Warning 'The repository is on the Windows system volume. This does not protect against failure or loss of that volume; a separate physical drive is strongly recommended.'
}
if (-not $Unattended) {
    $confirmation = Read-Host 'Install this configuration? [y/N]'
    if ($confirmation -notmatch '^(?i)y(?:es)?$') {
        throw 'Installation cancelled before any product files were created.'
    }
}

if (-not $SkipDashboard) {
    $webView2RuntimeVersion = Ensure-WebView2Runtime
    Write-Host "  WebView2   : $webView2RuntimeVersion" -ForegroundColor DarkGray
}

try {
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
    Assert-TreeMatchesManifest -Root $installRoot -Manifest $payloadManifest -Label 'Installed payload'

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

    Set-ProtectedDirectory -Path $installRoot -UserSid $currentSid
    Set-ProtectedDirectory -Path $stateRoot -UserSid $currentSid
    if ($RepositoryStorageMode -eq 'local_ntfs') {
        Set-ProtectedDirectory -Path $repositoryPath -UserSid $currentSid
    }
    if (Test-Path -LiteralPath $recoveryTools -PathType Container) {
        Set-ProtectedDirectory -Path $recoveryTools -UserSid $currentSid
    }

    $scheduleTime = [DateTime]::Today.Add([TimeSpan]::ParseExact($Schedule, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture))
    $backupAction = New-ScheduledTaskAction -Execute (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe') -WorkingDirectory $installRoot
    $backupTrigger = New-ScheduledTaskTrigger -Daily -At $scheduleTime
    $backupSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 7
    $backupPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $backupTaskName -Action $backupAction -Trigger $backupTrigger -Settings $backupSettings -Principal $backupPrincipal -Description 'Verified encrypted incremental Restic backup supervised by ResticBackuper.' | Out-Null
    $backupTaskCreated = $true

    if (-not $SkipDashboard) {
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
    }

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

    if ($dashboardTaskCreated) {
        try {
            Start-ScheduledTask -TaskName $dashboardTaskName
        }
        catch {
            Write-Warning "Dashboard auto-start failed; it remains installed and will retry at next logon: $($_.Exception.Message)"
        }
    }
    if ($StartBackup) {
        try {
            Start-ScheduledTask -TaskName $backupTaskName
            $firstBackupStarted = $true
        }
        catch {
            Write-Warning "The first backup did not start automatically; the scheduled installation remains intact: $($_.Exception.Message)"
        }
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
    exit 0
}
catch {
    $failure = $_.Exception.Message
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
    Write-Error "INSTALLATION FAILED: $failure`nRepository, recovery key, recovery tools, and ProgramData state are intentionally preserved if they were created."
    exit 1
}
