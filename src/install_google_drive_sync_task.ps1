[CmdletBinding()]
param(
    [string]$TaskName = 'ResticBackuperGoogleDriveSync',
    [string]$ProtectedRoot = (
        [System.IO.Path]::Combine(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
            'ResticBackuper'
        )
    ),
    [string]$ConfigPath = (
        [System.IO.Path]::Combine(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
            'ResticBackuper',
            'backup-config.json'
        )
    ),
    [string]$CloudVerificationRoot = (
        [System.IO.Path]::Combine(
            [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::CommonApplicationData
            ),
            'ResticBackuperCloudVerification'
        )
    ),
    [string]$RcloneExecutableSource = '',
    [string]$RcloneConfigSource = '',
    [string]$RcloneCredentialSource = '',
    [string]$RclonePasswordHelperSource = '',
    [string]$ExpectedRcloneExecutableSha256 = '',
    [string]$ExpectedRcloneConfigSha256 = '',
    [string]$ExpectedRcloneCredentialSha256 = '',
    [string]$ExpectedRclonePasswordHelperSha256 = '',
    [string]$RemoteName = 'ResticBackuperGoogleReadOnly',
    [switch]$ProvisionAssets,
    [switch]$ValidateOnly
)

# First, before any command: modules load only from Windows' own folder, never from the person's Documents folder.
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$verifierName = 'verify_my_drive_cloud_repository.ps1'
$inventoryHelperName = 'verify_cloud_repository_inventory.py'
$passwordHelperName = 'reveal-rclone-config-password.ps1'
$installerName = 'install_google_drive_sync_task.ps1'
$launcherName = 'ResticBackuperTaskLauncher.exe'
$runtimeManifestName = 'runtime-manifest.json'
$primaryTaskEvidenceName = 'scheduled-task.xml'
$taskEvidenceName = 'google-drive-verification-task.xml'

function Test-SamePath {
    param(
        [Parameter(Mandatory)] [string]$Left,
        [Parameter(Mandatory)] [string]$Right
    )

    return [string]::Equals(
        [System.IO.Path]::GetFullPath($Left).TrimEnd('\'),
        [System.IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-DescendantPath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Parent,
        [Parameter(Mandatory)] [string]$Message
    )

    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $pathFull.StartsWith(
        $parentFull + '\',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw $Message
    }
}

function Assert-NormalDirectory {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required directory not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Directory is a reparse point or non-directory: $Path"
    }
    return $item
}

function Assert-NormalFile {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "File is a reparse point or non-file: $Path"
    }
    return $item
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)] [string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-Utf8Json {
    param([Parameter(Mandatory)] [string]$Path)

    $text = [System.IO.File]::ReadAllText(
        [System.IO.Path]::GetFullPath($Path),
        [System.Text.UTF8Encoding]::new($false, $true)
    )
    return $text | ConvertFrom-Json
}

function Assert-RuntimeManifest {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string[]]$RequiredPaths
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    Assert-NormalDirectory -Path $rootFull | Out-Null
    $manifestPath = Join-Path $rootFull $runtimeManifestName
    $manifestItem = Assert-NormalFile -Path $manifestPath
    if ($manifestItem.Length -gt 16MB) {
        throw 'The protected runtime manifest is unexpectedly large.'
    }
    $manifest = Read-Utf8Json -Path $manifestPath
    $records = @($manifest.files)
    if ($manifest.schema_version -ne 1 -or
        ($manifest.file_count -isnot [int] -and
            $manifest.file_count -isnot [long]) -or
        [long]$manifest.file_count -ne $records.Count) {
        throw 'The protected runtime manifest header or file count is invalid.'
    }

    $rootPrefix = $rootFull + '\'
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($record in $records) {
        $relative = [string]$record.relative_path
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathRooted($relative) -or
            $relative.Split('\') -contains '..' -or
            -not $seen.Add($relative)) {
            throw "The runtime manifest contains an unsafe or duplicate path: $relative"
        }
        $path = [System.IO.Path]::GetFullPath((Join-Path $rootFull $relative))
        if (-not $path.StartsWith(
            $rootPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "A runtime manifest path escapes its root: $relative"
        }
        $item = Assert-NormalFile -Path $path
        $sha256 = [string]$record.sha256
        if (($record.bytes -isnot [int] -and
                $record.bytes -isnot [long]) -or
            [long]$record.bytes -ne $item.Length -or
            $sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-Sha256Hex -Path $path) -cne $sha256) {
            throw "Protected runtime manifest size or hash mismatch: $relative"
        }
    }
    foreach ($required in $RequiredPaths) {
        if (-not $seen.Contains($required)) {
            throw "The protected runtime manifest does not authorize: $required"
        }
    }

    $manifestFull = [System.IO.Path]::GetFullPath($manifestPath)
    $dynamicTaskEvidence = @(
        [System.IO.Path]::GetFullPath(
            (Join-Path $rootFull $primaryTaskEvidenceName)
        ),
        [System.IO.Path]::GetFullPath(
            (Join-Path $rootFull $taskEvidenceName)
        )
    )
    $actual = @(
        Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force |
            Where-Object {
                $_.FullName -ne $manifestFull -and
                $_.FullName -notin $dynamicTaskEvidence
            }
    )
    if ($actual.Count -ne $records.Count) {
        throw 'The protected runtime contains unmanifested or missing files.'
    }
    foreach ($file in $actual) {
        $relative = $file.FullName.Substring($rootPrefix.Length)
        if (-not $seen.Contains($relative)) {
            throw "The protected runtime contains an unmanifested file: $relative"
        }
    }
}

function Assert-Elevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        throw 'Installing the verification task requires elevated PowerShell.'
    }
}

function Assert-ProtectedRootAclDescriptor {
    param(
        [Parameter(Mandatory)] [object]$Acl,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    $ownerSid = $Acl.GetOwner(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    if ($ownerSid -ne 'S-1-5-32-544' -or -not $Acl.AreAccessRulesProtected) {
        throw 'The runtime root must remain Administrators-owned and protected.'
    }
    $allowedSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-3-4',
        $CurrentUserSid
    )
    $requiredSids = @{
        'S-1-5-18' = $false
        'S-1-5-32-544' = $false
        $CurrentUserSid = $false
    }
    $sawCurrentUser = $false
    $dangerous = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($rule in $Acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    )) {
        $sid = $rule.IdentityReference.Value
        if ($rule.IsInherited -or
            $rule.AccessControlType -ne
                [System.Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowedSids) {
            throw "The protected runtime has an unexpected ACL entry for $sid."
        }
        $requiredSids[$sid] = $true
        if ($sid -in @('S-1-5-18', 'S-1-5-32-544') -and
            ($rule.FileSystemRights -band
                [System.Security.AccessControl.FileSystemRights]::FullControl) -ne
                [System.Security.AccessControl.FileSystemRights]::FullControl) {
            throw "The protected runtime ACL does not grant full control to $sid."
        }
        if ($sid -in @($CurrentUserSid, 'S-1-3-4')) {
            if ($sid -eq $CurrentUserSid) {
                $sawCurrentUser = $true
            }
            if (($rule.FileSystemRights -band $dangerous) -ne 0 -or
                ($rule.FileSystemRights -band
                    [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -ne
                    [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) {
                throw 'The runtime ACL grants unsafe requester/owner rights.'
            }
        }
    }
    if (-not $sawCurrentUser) {
        throw 'The runtime ACL lacks current-user read and execute access.'
    }
    # GetAccessRules can omit an explicit inherit-only OWNER RIGHTS ACE even
    # when the raw DACL and icacls retain it. It remains allowlisted and is
    # checked whenever surfaced; these effective managed-view entries are
    # always required.
    foreach ($sid in $requiredSids.Keys) {
        if (-not $requiredSids[$sid]) {
            throw "The protected runtime ACL is missing required identity $sid."
        }
    }
}

function Assert-ProtectedRootAcl {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    Assert-ProtectedRootAclDescriptor `
        -Acl (Get-Acl -LiteralPath $Path) `
        -CurrentUserSid $CurrentUserSid
}

function Set-ProtectedDirectoryAcl {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    $administrators = [System.Security.Principal.SecurityIdentifier]::new(
        'S-1-5-32-544'
    )
    $system = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $ownerRights = [System.Security.Principal.SecurityIdentifier]::new('S-1-3-4')
    $user = [System.Security.Principal.SecurityIdentifier]::new($CurrentUserSid)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($administrators)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $system,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        $allow
    ))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $administrators,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        $allow
    ))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $user,
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance,
        $propagation,
        $allow
    ))
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $ownerRights,
        [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
        $inheritance,
        $propagation,
        $allow
    ))
    Set-Acl -LiteralPath $Path -AclObject $acl

    $icacls = Join-Path ([Environment]::SystemDirectory) 'icacls.exe'
    Assert-NormalFile -Path $icacls | Out-Null
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) {
        & $icacls (Join-Path $Path '*') /reset /T /C /L | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Resetting protected cloud-verification child ACLs failed.'
        }
    }
    & $icacls $Path /setowner '*S-1-5-32-544' /T /C /L | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Assigning cloud-verification ownership failed.'
    }
}

function Assert-ProtectedTreeAcl {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    Assert-ProtectedRootAcl `
        -Path $Path `
        -CurrentUserSid $CurrentUserSid
    $allowedSids = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-3-4',
        $CurrentUserSid
    )
    $dangerous = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse) {
        if (($item.Attributes -band
            [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Protected cloud-verification storage contains a reparse point: $($item.FullName)"
        }
        $acl = Get-Acl -LiteralPath $item.FullName
        $ownerSid = ([System.Security.Principal.NTAccount]$acl.Owner).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
        if ($ownerSid -ne 'S-1-5-32-544') {
            throw 'A cloud-verification child is not Administrators-owned.'
        }
        foreach ($rule in $acl.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier]
        )) {
            $sid = $rule.IdentityReference.Value
            if ($rule.AccessControlType -ne
                    [System.Security.AccessControl.AccessControlType]::Allow -or
                $sid -notin $allowedSids -or
                ($sid -in @($CurrentUserSid, 'S-1-3-4') -and
                    ($rule.FileSystemRights -band $dangerous) -ne 0)) {
                throw 'Cloud-verification child ACL grants an unexpected or unsafe right.'
            }
        }
    }
}

function Write-NewUtf8Json {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Value
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace a cloud-verification asset manifest: $Path"
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 7) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-VerifiedAssetManifest {
    param(
        [Parameter(Mandatory)] [string]$Root,
        # Lets the password helper's file differ from its record, which a refresh cut short leaves behind, so that
        # Get-PasswordHelperRefreshPlan can tell whether this installer can finish it. Every other check still applies.
        [switch]$AllowPasswordHelperMismatch
    )

    $manifestPath = Join-Path $Root 'assets-manifest.json'
    $manifestItem = Assert-NormalFile -Path $manifestPath
    if ($manifestItem.Length -gt 1MB) {
        throw 'The cloud-verification asset manifest is unexpectedly large.'
    }
    $manifest = Read-Utf8Json -Path $manifestPath
    $requiredNames = @(
        'rclone.exe',
        'rclone-readonly.conf',
        'rclone-config-password.clixml',
        'reveal-rclone-config-password.ps1'
    )
    $records = @($manifest.files)
    if ($manifest.schema_version -ne 1 -or
        [string]$manifest.remote_name -notmatch '^[A-Za-z0-9._-]{1,80}$' -or
        ($manifest.file_count -isnot [int] -and
            $manifest.file_count -isnot [long]) -or
        [long]$manifest.file_count -ne $requiredNames.Count -or
        $records.Count -ne $requiredNames.Count) {
        throw 'The cloud-verification asset manifest header is invalid.'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($record in $records) {
        $name = [string]$record.name
        if ($name -notin $requiredNames -or -not $seen.Add($name)) {
            throw 'The asset manifest has an unsafe or duplicate file name.'
        }
        $path = Join-Path $Root $name
        $item = Assert-NormalFile -Path $path
        if (($record.bytes -isnot [int] -and
                $record.bytes -isnot [long]) -or
            [string]$record.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Cloud-verification asset size or hash mismatch: $name"
        }
        $actualSha256 = Get-Sha256Hex -Path $path
        if ($actualSha256 -ceq [string]$record.sha256 -and [long]$record.bytes -eq $item.Length) {
            continue
        }
        if (-not ($AllowPasswordHelperMismatch -and
                $name -ceq 'reveal-rclone-config-password.ps1' -and
                $actualSha256 -cne [string]$record.sha256)) {
            throw "Cloud-verification asset size or hash mismatch: $name"
        }
    }
    $allowedRootNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($name in (
        $requiredNames + @('assets-manifest.json', 'runs', 'evidence')
    )) {
        [void]$allowedRootNames.Add($name)
    }
    $rootItems = @(Get-ChildItem -LiteralPath $Root -Force)
    if ($rootItems.Count -ne $allowedRootNames.Count) {
        throw 'The cloud-verification asset root has unexpected entries.'
    }
    foreach ($item in $rootItems) {
        if (-not $allowedRootNames.Contains($item.Name) -or
            ($item.Name -in @('runs', 'evidence') -and -not $item.PSIsContainer) -or
            ($item.Name -notin @('runs', 'evidence') -and $item.PSIsContainer)) {
            throw 'The cloud-verification asset root has an unsafe entry.'
        }
    }
    return $manifest
}

function ConvertFrom-RcloneVersionText {
    # The version on the first line of `rclone version` ("rclone v1.74.4", or "rclone v1.66.0-beta.7731.6a8ddbcc4").
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Text)

    $firstLine = ([string](($Text -split "`n", 2)[0])).Trim()
    if ($firstLine -cnotmatch (
        '^rclone v(?<major>[0-9]{1,4})\.(?<minor>[0-9]{1,4})\.(?<patch>[0-9]{1,6})' +
        '(?:-[0-9A-Za-z.+-]{1,120})?$'
    )) {
        throw 'The rclone version could not be read.'
    }
    return [Version]::new(
        [int]$Matches['major'],
        [int]$Matches['minor'],
        [int]$Matches['patch']
    )
}

function Get-RcloneVersion {
    # Runs `rclone version` without a window, with Windows' own values as its whole environment and nothing to read
    # on its standard input, and returns the version it reports. It is stopped (that process only) if it takes long.
    param(
        [Parameter(Mandatory)] [string]$Executable,
        [ValidateRange(1, 600)] [int]$TimeoutSeconds = 60
    )

    $system = [Environment]::SystemDirectory
    $windows = [System.IO.Directory]::GetParent($system).FullName
    $info = [System.Diagnostics.ProcessStartInfo]::new($Executable)
    $info.Arguments = 'version'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.WorkingDirectory = Split-Path -Parent $Executable
    $info.EnvironmentVariables.Clear()
    $info.EnvironmentVariables['SystemRoot'] = $windows
    $info.EnvironmentVariables['windir'] = $windows
    $info.EnvironmentVariables['SystemDrive'] = [System.IO.Path]::GetPathRoot($windows).TrimEnd('\')
    $info.EnvironmentVariables['PATH'] = $system + ';' + $windows
    $info.EnvironmentVariables['RCLONE_ASK_PASSWORD'] = 'false'
    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "rclone did not report its version within $TimeoutSeconds seconds."
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]]@($stdout, $stderr),
                10000)) {
            throw 'The output of rclone version could not be read.'
        }
        if ($process.ExitCode -ne 0) {
            throw "rclone version failed with exit code $($process.ExitCode)."
        }
        return ConvertFrom-RcloneVersionText -Text $stdout.Result
    }
    finally {
        $process.Dispose()
    }
}

function Assert-RcloneVersionAllowed {
    # The check compares Google Drive's SHA-256 checksums, which rclone reports from 1.65.0 on. An older rclone could never
    # pass it, so it is refused.
    param([Parameter(Mandatory)] [Version]$Version)

    $minimum = [Version]'1.65.0'
    if ($Version -lt $minimum) {
        $tooOld = 'rclone {0} is older than {1}, the first version that reports Google Drive SHA-256 checksums.'
        throw ($tooOld -f $Version, $minimum)
    }
}

function Install-ProtectedCloudAssets {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    if (Test-Path -LiteralPath $Target) {
        throw (
            'Refusing to overwrite existing protected cloud-verification assets. To keep using them, register the ' +
            'check without -ProvisionAssets; that also brings their password helper up to date.'
        )
    }
    if ($RemoteName -notmatch '^[A-Za-z0-9._-]{1,80}$') {
        throw 'The read-only rclone remote name is invalid.'
    }
    $sources = [ordered]@{
        'rclone.exe' = [ordered]@{
            path = $RcloneExecutableSource
            sha256 = $ExpectedRcloneExecutableSha256
        }
        'rclone-readonly.conf' = [ordered]@{
            path = $RcloneConfigSource
            sha256 = $ExpectedRcloneConfigSha256
        }
        'rclone-config-password.clixml' = [ordered]@{
            path = $RcloneCredentialSource
            sha256 = $ExpectedRcloneCredentialSha256
        }
        'reveal-rclone-config-password.ps1' = [ordered]@{
            path = $RclonePasswordHelperSource
            sha256 = $ExpectedRclonePasswordHelperSha256
        }
    }
    foreach ($source in $sources.Values) {
        if ([string]::IsNullOrWhiteSpace([string]$source.path) -or
            [string]$source.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'ProvisionAssets requires four explicit sources and lowercase SHA-256 values.'
        }
        $sourcePath = [System.IO.Path]::GetFullPath([string]$source.path)
        Assert-NormalFile -Path $sourcePath |
            Out-Null
        if ((Get-Sha256Hex -Path $sourcePath) -cne [string]$source.sha256) {
            throw 'A cloud-verification asset source does not match its expected SHA-256.'
        }
    }

    $parent = Split-Path -Parent $Target
    Assert-NormalDirectory -Path $parent | Out-Null
    $stage = Join-Path $parent (
        '.ResticBackuperCloudVerification.setup-' +
        [Guid]::NewGuid().ToString('N')
    )
    $promoted = $false
    try {
        [System.IO.Directory]::CreateDirectory($stage) | Out-Null
        Set-ProtectedDirectoryAcl `
            -Path $stage `
            -CurrentUserSid $CurrentUserSid
        Assert-ProtectedRootAcl `
            -Path $stage `
            -CurrentUserSid $CurrentUserSid
        foreach ($entry in $sources.GetEnumerator()) {
            [System.IO.File]::Copy(
                [System.IO.Path]::GetFullPath([string]$entry.Value.path),
                (Join-Path $stage ([string]$entry.Key)),
                $false
            )
        }
        [System.IO.Directory]::CreateDirectory((Join-Path $stage 'runs')) |
            Out-Null
        [System.IO.Directory]::CreateDirectory((Join-Path $stage 'evidence')) |
            Out-Null
        $records = @(
            foreach ($name in $sources.Keys) {
                $path = Join-Path $stage ([string]$name)
                $item = Get-Item -LiteralPath $path -Force
                [ordered]@{
                    name = [string]$name
                    bytes = [long]$item.Length
                    sha256 = Get-Sha256Hex -Path $path
                }
            }
        )
        foreach ($record in $records) {
            if ([string]$record.sha256 -cne
                [string]$sources[[string]$record.name].sha256) {
                throw 'A staged cloud-verification asset changed during protected copy.'
            }
        }
        # The protected copy that will run is asked for its version, which the manifest records. An rclone too old to
        # report Google Drive's SHA-256 checksums could never pass the check.
        $rcloneVersion = Get-RcloneVersion -Executable (Join-Path $stage 'rclone.exe')
        Assert-RcloneVersionAllowed -Version $rcloneVersion
        Write-NewUtf8Json `
            -Path (Join-Path $stage 'assets-manifest.json') `
            -Value ([ordered]@{
                schema_version = 1
                created_utc = [DateTime]::UtcNow.ToString('o')
                task_user_sid = $CurrentUserSid
                remote_name = $RemoteName
                rclone_version = $rcloneVersion.ToString()
                file_count = $records.Count
                files = $records
            })
        Set-ProtectedDirectoryAcl `
            -Path $stage `
            -CurrentUserSid $CurrentUserSid
        Assert-ProtectedTreeAcl `
            -Path $stage `
            -CurrentUserSid $CurrentUserSid
        [void](Read-VerifiedAssetManifest -Root $stage)
        [System.IO.Directory]::Move($stage, $Target)
        $promoted = $true
        Assert-ProtectedTreeAcl `
            -Path $Target `
            -CurrentUserSid $CurrentUserSid
        return Read-VerifiedAssetManifest -Root $Target
    }
    finally {
        if (-not $promoted -and
            (Test-Path -LiteralPath $stage -PathType Container) -and
            $stage.StartsWith(
                [System.IO.Path]::GetFullPath($parent).TrimEnd('\') + '\.ResticBackuperCloudVerification.setup-',
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-KnownPasswordHelperGenerations {
    # Every rclone password helper a Rewindle build has carried, oldest first, by the SHA-256 of the file as each kind of
    # build has it: local builds check it out with LF line endings, release builds with CRLF. Both forms of one helper are
    # the same generation. tests/test_my_drive_cloud_verifier.py fails until a changed helper is added here as the next one.
    $generations = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in @(
        # 1: 0.2.0-alpha.1 and 0.2.0-alpha.2.
        @(1, '5f30dafbc8512db3c97f1dbed0fc0bc99db528d6110d517e28926ff7ef395b2a'),
        @(1, '092c8263d9377b5ff1facd3217ca683dc026a82ba83d1429cea67510dc2a1496'),
        # 2: loads PowerShell modules only from Windows' own folder.
        @(2, '690001286d10be7ae62d4e5d89814c2b1597b84134537e66979ea72a94f9189a'),
        @(2, '1b15c85d39b67f1bc2f385e64a7f692e63360f737fe768b28cd110d87503ff15'),
        # 3: wrote the password as UTF-8; on a development branch for a few hours only.
        @(3, '6731d28baedd9535771de9974ed731fdc163cef73554b76ea6f172bf0b344a09'),
        @(3, '726b33761dc2b67344367fcd3d47e1f1080e3d61dc5e5c6720a6979c4c39f154'),
        # 4: writes the password as UTF-8 and never holds it in a string.
        @(4, '406bec4929ecc496903afa2ba1ace63b9c89d887afb996b045dc1b41275457e7'),
        @(4, 'd0aa6277c005fbc3c171c868d8036e23d94944afbd1d6d611ea4b8d36a220a83')
    )) {
        $generations.Add([string]$entry[1], [int]$entry[0])
    }
    return $generations
}

function Get-PasswordHelperRefreshPlan {
    # What registering the check again does with the protected password helper:
    #   current  - the assets hold the packaged helper's generation, in either line ending; nothing changes.
    #   refresh  - they hold an earlier generation; Update-ProtectedPasswordHelper puts the packaged helper in.
    #   finish   - a refresh was cut short after it had replaced the helper; only the manifest's record is brought up to date.
    #   newer, unknown, packaged_unknown - refused: assets from a newer Rewindle; a helper no Rewindle shipped, or a state no
    #   refresh leaves; a packaged helper missing from the list.
    # RecordedSha256 is the helper's hash in assets-manifest.json, PresentSha256 the hash of the helper file in the assets
    # root, PackagedSha256 the hash of the helper in the protected runtime.
    param(
        [Parameter(Mandatory)] [string]$RecordedSha256,
        [Parameter(Mandatory)] [string]$PresentSha256,
        [Parameter(Mandatory)] [string]$PackagedSha256,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Generations
    )

    if (-not $Generations.ContainsKey($PackagedSha256)) {
        return 'packaged_unknown'
    }
    if (-not $Generations.ContainsKey($RecordedSha256) -or -not $Generations.ContainsKey($PresentSha256)) {
        return 'unknown'
    }
    $packaged = [int]$Generations[$PackagedSha256]
    $recorded = [int]$Generations[$RecordedSha256]
    $present = [int]$Generations[$PresentSha256]
    if ($PresentSha256 -ceq $RecordedSha256) {
        if ($recorded -eq $packaged) {
            return 'current'
        }
        if ($recorded -lt $packaged) {
            return 'refresh'
        }
        return 'newer'
    }
    # The helper file is not the one recorded. Only a refresh cut short between its two steps leaves that, and then the
    # file is a later generation than the record.
    if ($present -le $recorded) {
        return 'unknown'
    }
    if ($present -eq $packaged) {
        return 'finish'
    }
    if ($present -lt $packaged) {
        return 'refresh'
    }
    return 'newer'
}

function Assert-PasswordHelperPlanAllowed {
    param(
        [Parameter(Mandatory)] [string]$Plan,
        [Parameter(Mandatory)] [string]$Root
    )

    if ($Plan -ceq 'packaged_unknown') {
        throw (
            'This version of Rewindle does not recognise its own rclone password helper. Reinstall Rewindle, then ' +
            'register the check again.'
        )
    }
    if ($Plan -ceq 'newer') {
        throw (
            'The protected rclone assets were set up by a newer version of Rewindle, so they were left as they are. ' +
            'Install that version or a later one, then register the check again.'
        )
    }
    if ($Plan -ceq 'unknown') {
        $unknown = (
            'The protected rclone assets hold a password helper that no version of Rewindle shipped, so they were ' +
            'left as they are. Move {0} aside, then set up the check again with -ProvisionAssets, as Rewindle''s ' +
            'guide to Google Drive describes.'
        )
        throw ($unknown -f $Root)
    }
    if ($Plan -cnotin @('current', 'refresh', 'finish')) {
        throw "Unexpected password helper plan: $Plan"
    }
}

function Get-Sha256HexOfBytes {
    param([Parameter(Mandatory)] [byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-NewFileBytes {
    # A new file that holds exactly these bytes, written through to the disk before this returns.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [byte[]]$Bytes
    )

    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function New-RefreshedAssetManifest {
    # The manifest as it was, every field in its order, with the helper's size and hash changed.
    param(
        [Parameter(Mandatory)] [object]$Manifest,
        [Parameter(Mandatory)] [string]$HelperName,
        [Parameter(Mandatory)] [long]$HelperBytes,
        [Parameter(Mandatory)] [string]$HelperSha256
    )

    $value = [ordered]@{}
    foreach ($property in $Manifest.PSObject.Properties) {
        if ($property.Name -cne 'files') {
            $value[$property.Name] = $property.Value
            continue
        }
        $value['files'] = @(
            foreach ($record in @($property.Value)) {
                $copy = [ordered]@{}
                foreach ($field in $record.PSObject.Properties) {
                    $copy[$field.Name] = $field.Value
                }
                if ([string]$record.name -ceq $HelperName) {
                    $copy['bytes'] = $HelperBytes
                    $copy['sha256'] = $HelperSha256
                }
                $copy
            }
        )
    }
    return $value
}

function Enter-ProtectedRunLock {
    # The run lock that backups and the check take, or $null while one of them, or another protected change, holds it.
    # The same open and byte lock as the check's own; the file and its permissions stay as they are.
    param([Parameter(Mandatory)] [string]$Path)

    $item = Assert-NormalFile -Path $Path
    if ($item.Length -lt 1) {
        throw 'The protected run-lock handshake is empty.'
    }
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
    }
    catch [System.IO.IOException] {
        # A sharing violation: another program has the file open and shares it with no one.
        if (($_.Exception.HResult -band 0xFFFF) -eq 32) {
            return $null
        }
        throw
    }
    try {
        $stream.Lock(0, 1)
        return $stream
    }
    catch [System.IO.IOException] {
        $stream.Dispose()
        # A lock violation means a backup or a protected change holds the lock. Any other error is a real one.
        if (($_.Exception.HResult -band 0xFFFF) -eq 33) {
            return $null
        }
        throw
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Exit-ProtectedRunLock {
    param([System.IO.FileStream]$Stream)

    if ($null -eq $Stream) { return }
    try { $Stream.Unlock(0, 1) } finally { $Stream.Dispose() }
}

function Get-MoveFileNativeMethods {
    # MoveFileExW, emitted in memory (Reflection.Emit, run only) and never compiled, as Manage-Repository.ps1 does:
    # csc.exe would work through %TEMP%, which the user's own programs can change while this runs elevated.
    $cached = Get-Variable -Name 'moveFileNativeMethods' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $cached) {
        return $cached
    }
    $assemblyName = [Reflection.AssemblyName]::new(
        'ResticBackuper.GoogleDriveCheckInstaller.Native.' + [Guid]::NewGuid().ToString('N')
    )
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    $module = $assembly.DefineDynamicModule($assemblyName.Name)
    $type = $module.DefineType(
        'ResticBackuper.GoogleDriveCheckInstaller.NativeMethods',
        [Reflection.TypeAttributes]'Public, Class, Sealed, Abstract'
    )
    $dllImport = [Runtime.InteropServices.DllImportAttribute]
    $method = $type.DefineMethod(
        'MoveFileExW',
        [Reflection.MethodAttributes]'Public, Static, PinvokeImpl, HideBySig',
        [bool],
        [Type[]]@([string], [string], [uint32])
    )
    $method.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
        $dllImport.GetConstructor([Type[]]@([string])),
        [object[]]@('kernel32.dll'),
        [Reflection.FieldInfo[]]@(
            $dllImport.GetField('SetLastError'),
            $dllImport.GetField('CallingConvention'),
            $dllImport.GetField('CharSet'),
            $dllImport.GetField('EntryPoint'),
            $dllImport.GetField('ExactSpelling')
        ),
        [object[]]@(
            $true,
            [Runtime.InteropServices.CallingConvention]::Winapi,
            [Runtime.InteropServices.CharSet]::Unicode,
            'MoveFileExW',
            $true
        )
    ))
    $native = $type.CreateType()
    Set-Variable -Name 'moveFileNativeMethods' -Scope Script -Value $native
    return $native
}

function Move-FileReplacing {
    # Renames Source over Target, on the same volume, in one step: Target always names the old file or the new one, never
    # nothing, which File.Replace does not promise. A file that another program has open just then is tried again.
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Target
    )

    $native = Get-MoveFileNativeMethods
    # MOVEFILE_REPLACE_EXISTING (1) and MOVEFILE_WRITE_THROUGH (8).
    $flags = [uint32]9
    for ($attempt = 1; $true; $attempt++) {
        if ($native::MoveFileExW($Source, $Target, $flags)) {
            return
        }
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        # Access denied, a sharing violation or a lock violation: usually another program reading the file at that moment.
        if ($attempt -ge 5 -or $code -notin @(5, 32, 33)) {
            $failed = 'Could not replace {0} ({1}). Close any program that has it open, then register the check again.'
            throw ($failed -f $Target, [ComponentModel.Win32Exception]::new($code).Message)
        }
        [System.Threading.Thread]::Sleep(200)
    }
}

function Update-ProtectedPasswordHelper {
    # Brings the protected assets to the packaged password helper (plan 'refresh'), or finishes a refresh that was cut
    # short after it had replaced the helper (plan 'finish'). Only the helper and assets-manifest.json change.
    #
    # The files they replace are kept in a new folder under evidence\, where the check looks only at permissions. The
    # replacements are written into that folder first, so they take the same permissions as everything else under the
    # assets root, and are checked before anything is swapped. The swaps happen while the run lock is held, so no backup
    # or check runs meanwhile, and each is one rename. If the manifest cannot be swapped after the helper was, the earlier
    # helper goes back; if even that fails, registering the check again finishes the refresh.
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [ValidateSet('refresh', 'finish')] [string]$Plan,
        [Parameter(Mandatory)] [string]$HelperName,
        [Parameter(Mandatory)] [string]$PackagedHelperPath,
        [Parameter(Mandatory)] [string]$PackagedHelperSha256,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Generations,
        [Parameter(Mandatory)] [string]$RunLockPath,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    $changed = 'The protected rclone assets changed while this setup ran, so they were left as they are. Run it again.'
    $manifestPath = Join-Path $Root 'assets-manifest.json'
    $helperPath = Join-Path $Root $HelperName
    $evidence = Join-Path $Root 'evidence'
    Assert-NormalDirectory -Path $evidence | Out-Null
    foreach ($path in @($manifestPath, $helperPath, $PackagedHelperPath)) {
        if ((Assert-NormalFile -Path $path).Length -gt 1MB) {
            throw "Unexpectedly large protected file: $path"
        }
    }

    # Each file is read once: the bytes that are checked are the bytes that are kept and written.
    $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $helperBytes = [System.IO.File]::ReadAllBytes($helperPath)
    $manifestSha256 = Get-Sha256HexOfBytes -Bytes $manifestBytes
    $presentSha256 = Get-Sha256HexOfBytes -Bytes $helperBytes
    $manifest = [System.Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes) | ConvertFrom-Json
    $records = @(@($manifest.files) | Where-Object { [string]$_.name -ceq $HelperName })
    if ($records.Count -ne 1) {
        throw $changed
    }
    $recordedSha256 = [string]$records[0].sha256
    if ((Get-PasswordHelperRefreshPlan `
            -RecordedSha256 $recordedSha256 `
            -PresentSha256 $presentSha256 `
            -PackagedSha256 $PackagedHelperSha256 `
            -Generations $Generations) -cne $Plan) {
        throw $changed
    }
    if ($Plan -ceq 'refresh') {
        $newHelperBytes = [System.IO.File]::ReadAllBytes($PackagedHelperPath)
        if ((Get-Sha256HexOfBytes -Bytes $newHelperBytes) -cne $PackagedHelperSha256) {
            throw 'The packaged rclone password helper changed while this setup ran. Run it again.'
        }
    }
    else {
        $newHelperBytes = $helperBytes
    }
    $newHelperSha256 = Get-Sha256HexOfBytes -Bytes $newHelperBytes
    # Written as the installer writes every manifest (Write-NewUtf8Json): UTF-8 without a byte order mark, then a line break.
    $newManifest = New-RefreshedAssetManifest `
        -Manifest $manifest `
        -HelperName $HelperName `
        -HelperBytes $newHelperBytes.Length `
        -HelperSha256 $newHelperSha256
    $newManifestBytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        ($newManifest | ConvertTo-Json -Depth 7) + [Environment]::NewLine
    )
    $newManifestSha256 = Get-Sha256HexOfBytes -Bytes $newManifestBytes

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
    $copy = Join-Path $evidence ('password-helper-' + $stamp + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    if (Test-Path -LiteralPath $copy) {
        throw "Refusing to reuse a protected folder: $copy"
    }
    $stagedHelper = Join-Path $copy ($HelperName + '.new')
    $stagedManifest = Join-Path $copy 'assets-manifest.json.new'
    $lock = $null
    $swapStarted = $false
    try {
        [System.IO.Directory]::CreateDirectory($copy) | Out-Null
        Write-NewFileBytes -Path (Join-Path $copy 'assets-manifest.json.previous') -Bytes $manifestBytes
        if ($Plan -ceq 'refresh') {
            Write-NewFileBytes -Path (Join-Path $copy ($HelperName + '.previous')) -Bytes $helperBytes
            Write-NewFileBytes -Path $stagedHelper -Bytes $newHelperBytes
        }
        Write-NewFileBytes -Path $stagedManifest -Bytes $newManifestBytes
        # A file keeps its permissions when it is renamed, so the new ones must meet the check's rules already.
        Assert-ProtectedTreeAcl -Path $Root -CurrentUserSid $CurrentUserSid

        $lock = Enter-ProtectedRunLock -Path $RunLockPath
        if ($null -eq $lock) {
            throw (
                'A backup, the Google Drive check or another protected change is running, so the protected rclone ' +
                'assets were left as they are. Register the check again once it has finished.'
            )
        }
        # Under the lock: the files are still the ones read above, and the replacements still the ones written.
        if ((Get-Sha256Hex -Path $manifestPath) -cne $manifestSha256 -or
            (Get-Sha256Hex -Path $helperPath) -cne $presentSha256 -or
            (Get-Sha256Hex -Path $stagedManifest) -cne $newManifestSha256 -or
            ($Plan -ceq 'refresh' -and (Get-Sha256Hex -Path $stagedHelper) -cne $newHelperSha256)) {
            throw $changed
        }
        $swapStarted = $true
        if ($Plan -ceq 'refresh') {
            Move-FileReplacing -Source $stagedHelper -Target $helperPath
        }
        Move-FileReplacing -Source $stagedManifest -Target $manifestPath
        if ((Get-Sha256Hex -Path $helperPath) -cne $newHelperSha256 -or
            (Get-Sha256Hex -Path $manifestPath) -cne $newManifestSha256) {
            throw 'The refreshed rclone password helper could not be confirmed. Register the check again.'
        }
    }
    finally {
        if ($swapStarted -and $Plan -ceq 'refresh') {
            # The helper was swapped and the manifest was not: the earlier helper goes back, so the two agree again.
            try {
                if ((Get-Sha256Hex -Path $helperPath) -ceq $newHelperSha256 -and
                    (Get-Sha256Hex -Path $manifestPath) -ceq $manifestSha256) {
                    $rollback = Join-Path $copy ($HelperName + '.rollback')
                    Write-NewFileBytes -Path $rollback -Bytes $helperBytes
                    Move-FileReplacing -Source $rollback -Target $helperPath
                }
            }
            catch {
                Write-Warning (
                    'The earlier rclone password helper could not be put back (' + $_.Exception.Message + '). ' +
                    'Registering the check again finishes the update.'
                )
            }
        }
        Exit-ProtectedRunLock -Stream $lock
        if (-not $swapStarted) {
            # Nothing was swapped: the folder holds only copies made here.
            Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{
        RecordedHelperSha256 = $recordedSha256
        HelperSha256 = $newHelperSha256
        PreviousManifestSha256 = $manifestSha256
        ManifestSha256 = $newManifestSha256
        PreviousCopy = $copy
    }
}

function Get-AssetPasswordHelperPlan {
    # The plan for the password helper in the protected assets (Get-PasswordHelperRefreshPlan), from the manifest as read,
    # the helper file in the assets root and the packaged helper's hash, with the hash the manifest records. A plan that
    # is refused throws here, with what to do.
    param(
        [Parameter(Mandatory)] [object]$Manifest,
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$HelperName,
        [Parameter(Mandatory)] [string]$PackagedHelperSha256
    )

    $records = @(@($Manifest.files) | Where-Object { [string]$_.name -ceq $HelperName })
    if ($records.Count -ne 1) {
        throw 'Protected rclone assets do not contain the packaged password helper.'
    }
    $recordedSha256 = [string]$records[0].sha256
    $plan = Get-PasswordHelperRefreshPlan `
        -RecordedSha256 $recordedSha256 `
        -PresentSha256 (Get-Sha256Hex -Path (Join-Path $Root $HelperName)) `
        -PackagedSha256 $PackagedHelperSha256 `
        -Generations (Get-KnownPasswordHelperGenerations)
    Assert-PasswordHelperPlanAllowed -Plan $plan -Root $Root
    return [pscustomobject]@{
        Plan = $plan
        RecordedSha256 = $recordedSha256
    }
}

function Invoke-PasswordHelperRefresh {
    # The refresh as registering the check runs it: Update-ProtectedPasswordHelper, then the assets read again as strictly
    # as the check reads them, their permissions checked again, and the helper confirmed as the packaged one's
    # generation. Returns the fields of the installer's report that change.
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [ValidateSet('refresh', 'finish')] [string]$Plan,
        [Parameter(Mandatory)] [string]$HelperName,
        [Parameter(Mandatory)] [string]$PackagedHelperPath,
        [Parameter(Mandatory)] [string]$PackagedHelperSha256,
        [Parameter(Mandatory)] [string]$RunLockPath,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    $generations = Get-KnownPasswordHelperGenerations
    $refresh = Update-ProtectedPasswordHelper `
        -Root $Root `
        -Plan $Plan `
        -HelperName $HelperName `
        -PackagedHelperPath $PackagedHelperPath `
        -PackagedHelperSha256 $PackagedHelperSha256 `
        -Generations $generations `
        -RunLockPath $RunLockPath `
        -CurrentUserSid $CurrentUserSid
    [void](Read-VerifiedAssetManifest -Root $Root)
    Assert-ProtectedTreeAcl -Path $Root -CurrentUserSid $CurrentUserSid
    $helperSha256 = Get-Sha256Hex -Path (Join-Path $Root $HelperName)
    if ((Get-PasswordHelperRefreshPlan `
            -RecordedSha256 $helperSha256 `
            -PresentSha256 $helperSha256 `
            -PackagedSha256 $PackagedHelperSha256 `
            -Generations $generations) -cne 'current') {
        throw 'The refreshed rclone password helper could not be confirmed. Register the check again.'
    }
    return [ordered]@{
        asset_manifest_sha256 = Get-Sha256Hex -Path (Join-Path $Root 'assets-manifest.json')
        password_helper_refresh = 'performed'
        password_helper_previous_sha256 = $refresh.RecordedHelperSha256
        password_helper_previous_copy = $refresh.PreviousCopy
    }
}

function Import-TrustedScheduledTasksModule {
    $moduleRoot = Join-Path (
        [Environment]::SystemDirectory
    ) 'WindowsPowerShell\v1.0\Modules'
    $manifestPath = Join-Path $moduleRoot 'ScheduledTasks\ScheduledTasks.psd1'
    $item = Assert-NormalFile -Path $manifestPath
    Microsoft.PowerShell.Core\Import-Module `
        -Name $item.FullName `
        -Force `
        -ErrorAction Stop
}

function Convert-TaskPrincipalToSid {
    param([Parameter(Mandatory)] [string]$UserId)

    try {
        return ([System.Security.Principal.SecurityIdentifier]$UserId).Value
    }
    catch {
        return ([System.Security.Principal.NTAccount]$UserId).Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    }
}

function Assert-RegisteredTaskDefinition {
    param(
        [Parameter(Mandatory)] [string]$Xml,
        [Parameter(Mandatory)] [string]$ExpectedExecute,
        [Parameter(Mandatory)] [string]$ExpectedArguments,
        [Parameter(Mandatory)] [string]$ExpectedWorkingDirectory,
        [Parameter(Mandatory)] [string]$ExpectedUserSid
    )

    [xml]$document = $Xml
    $namespaces = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespaces.AddNamespace(
        't',
        'http://schemas.microsoft.com/windows/2004/02/mit/task'
    )
    $actions = @($document.SelectNodes(
        '/t:Task/t:Actions/t:Exec',
        $namespaces
    ))
    $triggers = @($document.SelectNodes(
        '/t:Task/t:Triggers/*',
        $namespaces
    ))
    $principals = @($document.SelectNodes(
        '/t:Task/t:Principals/t:Principal',
        $namespaces
    ))
    if ($actions.Count -ne 1 -or
        $triggers.Count -ne 1 -or
        $principals.Count -ne 1) {
        throw 'The task must have exactly one action, trigger, and principal.'
    }
    if ([string]$actions[0].Command -cne $ExpectedExecute -or
        [string]$actions[0].Arguments -cne $ExpectedArguments -or
        [string]$actions[0].WorkingDirectory -cne $ExpectedWorkingDirectory) {
        throw 'The registered task action does not match the protected verifier.'
    }
    if ([string]$actions[0].Arguments -match
        '(?i)(password|credential|secret|DestinationRoot|sync_repository_to_google_drive)') {
        throw 'The registered action exposes a secret or legacy mirror argument.'
    }
    $principal = $principals[0]
    if ([string]$principal.LogonType -cne 'InteractiveToken' -or
        [string]$principal.RunLevel -cne 'HighestAvailable' -or
        (Convert-TaskPrincipalToSid -UserId ([string]$principal.UserId)) -cne
            $ExpectedUserSid) {
        throw 'The task principal is not current-user InteractiveToken/Highest.'
    }
    $daily = $triggers[0]
    $start = [System.DateTimeOffset]::Parse([string]$daily.StartBoundary)
    if ($daily.LocalName -cne 'CalendarTrigger' -or
        [string]$daily.ScheduleByDay.DaysInterval -cne '1' -or
        $start.Hour -ne 3 -or
        $start.Minute -ne 0 -or
        $start.Second -ne 0) {
        throw 'The verification task is not daily at 03:00 local time.'
    }
    $settings = $document.SelectSingleNode(
        '/t:Task/t:Settings',
        $namespaces
    )
    $enabledNodes = @(
        if ($null -ne $settings) {
            $settings.SelectNodes('t:Enabled', $namespaces)
        }
    )
    $enabled = $true
    if ($enabledNodes.Count -eq 1) {
        $enabledText = [string]$enabledNodes[0].InnerText
        if ($enabledText -cin @('true', '1')) {
            $enabled = $true
        }
        elseif ($enabledText -cin @('false', '0')) {
            $enabled = $false
        }
        else {
            throw 'The verification task Enabled setting is invalid.'
        }
    }
    elseif ($enabledNodes.Count -gt 1) {
        throw 'The verification task contains duplicate Enabled settings.'
    }
    if ($null -eq $settings -or
        [string]$settings.MultipleInstancesPolicy -cne 'IgnoreNew' -or
        [string]$settings.StartWhenAvailable -cne 'true' -or
        -not $enabled) {
        throw 'The verification task settings are unsafe or incomplete.'
    }
}

function Write-AtomicTaskEvidence {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Xml
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    $temporary = Join-Path $directory (
        'task-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $backup = Join-Path $directory (
        'task-' + [Guid]::NewGuid().ToString('N') + '.bak'
    )
    try {
        [System.IO.File]::WriteAllText(
            $temporary,
            $Xml,
            [System.Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [System.IO.File]::Replace(
                $temporary,
                $fullPath,
                $backup,
                $true
            )
            [System.IO.File]::Delete($backup)
        }
        elseif (Test-Path -LiteralPath $fullPath) {
            throw 'The protected task evidence path is not a normal file.'
        }
        else {
            [System.IO.File]::Move($temporary, $fullPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

if ($TaskName -notmatch '^[A-Za-z0-9._-]{1,120}$') {
    throw 'The scheduled task name is invalid.'
}
$protectedRootFull = [System.IO.Path]::GetFullPath($ProtectedRoot).TrimEnd('\')
$configPathFull = [System.IO.Path]::GetFullPath($ConfigPath)
$verifierPath = Join-Path $protectedRootFull $verifierName
$inventoryHelperPath = Join-Path $protectedRootFull $inventoryHelperName
$passwordHelperPath = Join-Path $protectedRootFull $passwordHelperName
$installerPath = Join-Path $protectedRootFull $installerName
$launcherPath = Join-Path $protectedRootFull $launcherName
$taskEvidencePath = Join-Path $protectedRootFull $taskEvidenceName
if (-not (Test-SamePath -Left $PSScriptRoot -Right $protectedRootFull) -or
    -not (Test-SamePath -Left $PSCommandPath -Right $installerPath) -or
    -not (Test-SamePath `
        -Left $configPathFull `
        -Right (Join-Path $protectedRootFull 'backup-config.json'))) {
    throw 'Run only the manifest-authorized installer from the protected runtime.'
}

Assert-RuntimeManifest `
    -Root $protectedRootFull `
    -RequiredPaths @(
        'backup-config.json',
        $installerName,
        $verifierName,
        $inventoryHelperName,
        $passwordHelperName,
        $launcherName
    )
foreach ($path in @(
    $configPathFull,
    $installerPath,
    $verifierPath,
    $inventoryHelperPath,
    $passwordHelperPath,
    $launcherPath
)) {
    Assert-NormalFile -Path $path | Out-Null
}
$packagedPasswordHelperSha256 = Get-Sha256Hex -Path $passwordHelperPath
if ([string]::IsNullOrWhiteSpace($RclonePasswordHelperSource)) {
    $RclonePasswordHelperSource = $passwordHelperPath
}
elseif (-not (Test-SamePath `
        -Left $RclonePasswordHelperSource `
        -Right $passwordHelperPath)) {
    throw 'The rclone password helper must be the manifest-authorized packaged helper.'
}
if ([string]::IsNullOrWhiteSpace($ExpectedRclonePasswordHelperSha256)) {
    $ExpectedRclonePasswordHelperSha256 = $packagedPasswordHelperSha256
}
elseif ($ExpectedRclonePasswordHelperSha256 -cne
    $packagedPasswordHelperSha256) {
    throw 'The expected rclone password-helper hash does not match the protected runtime.'
}

$configuration = Read-Utf8Json -Path $configPathFull
foreach ($property in @(
    'repository',
    'repository_storage_mode',
    'drivefs_my_drive_root',
    'state_directory',
    'plan_id',
    'config_generation'
)) {
    if ($configuration.PSObject.Properties.Name -notcontains $property -or
        [string]::IsNullOrWhiteSpace([string]$configuration.$property)) {
        throw "The protected configuration is missing: $property"
    }
}
if ([string]$configuration.repository_storage_mode -cne
    'google_drivefs_stream') {
    throw 'The verification task requires google_drivefs_stream storage mode.'
}
$localRepositoryFull = [System.IO.Path]::GetFullPath(
    [string]$configuration.repository
).TrimEnd('\')
$myDriveRootFull = [System.IO.Path]::GetFullPath(
    [string]$configuration.drivefs_my_drive_root
).TrimEnd('\')
Assert-DescendantPath `
    -Path $localRepositoryFull `
    -Parent $myDriveRootFull `
    -Message 'The live repository must be strictly below the My Drive root.'
Assert-NormalDirectory -Path $myDriveRootFull | Out-Null
Assert-NormalDirectory -Path $localRepositoryFull | Out-Null
Assert-NormalFile -Path (Join-Path $localRepositoryFull 'config') | Out-Null

$parsedPlanId = [Guid]::Empty
if (-not [Guid]::TryParseExact(
        [string]$configuration.plan_id,
        'D',
        [ref]$parsedPlanId
    ) -or
    $parsedPlanId -eq [Guid]::Empty -or
    $parsedPlanId.ToString('D') -cne [string]$configuration.plan_id -or
    ($configuration.config_generation -isnot [int] -and
        $configuration.config_generation -isnot [long]) -or
    [long]$configuration.config_generation -lt 1) {
    throw 'The protected plan identity or generation is invalid.'
}

$stateDirectoryFull = [System.IO.Path]::GetFullPath(
    [string]$configuration.state_directory
)
$runLockPath = Join-Path $stateDirectoryFull 'run.lock'
$repositoryStatePath = Join-Path $stateDirectoryFull 'repository.json'
$runLockItem = Assert-NormalFile -Path $runLockPath
if ($runLockItem.Length -lt 1) {
    throw 'The protected run-lock handshake is empty.'
}
$repositoryStateItem = Assert-NormalFile -Path $repositoryStatePath
if ($repositoryStateItem.Length -gt 1MB) {
    throw 'Protected repository identity state is unexpectedly large.'
}
$repositoryState = Read-Utf8Json -Path $repositoryStatePath
$repositoryId = [string]$repositoryState.repository_id
if ($repositoryState.schema_version -ne 1 -or
    $repositoryId -cnotmatch '^[0-9a-f]{64}$' -or
    -not (Test-SamePath `
        -Left ([string]$repositoryState.repository) `
        -Right $localRepositoryFull)) {
    throw 'Protected repository identity state does not match the live repository.'
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$account = $identity.Name
$userSid = $identity.User.Value
$cloudVerificationRootFull = [System.IO.Path]::GetFullPath(
    $CloudVerificationRoot
).TrimEnd('\')
$canonicalCloudVerificationRoot = [System.IO.Path]::Combine(
    [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::CommonApplicationData
    ),
    'ResticBackuperCloudVerification'
)
# The task launcher starts the check only from its own Program Files folder. This comes first: a runtime anywhere else is
# refused whatever cloud-verification root it was given.
$canonicalProtectedRoot = [System.IO.Path]::Combine(
    [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
    'ResticBackuper'
)
if (-not $ValidateOnly -and
    -not (Test-SamePath `
        -Left $protectedRootFull `
        -Right $canonicalProtectedRoot)) {
    throw 'The verification task runs only from the Program Files runtime.'
}
if (-not $ValidateOnly -and
    -not (Test-SamePath `
        -Left $cloudVerificationRootFull `
        -Right $canonicalCloudVerificationRoot)) {
    throw 'Production cloud-verification assets are fixed to protected ProgramData storage.'
}
if ($ProvisionAssets -and $ValidateOnly) {
    $validationAssets = @(
        @($RcloneExecutableSource, $ExpectedRcloneExecutableSha256),
        @($RcloneConfigSource, $ExpectedRcloneConfigSha256),
        @($RcloneCredentialSource, $ExpectedRcloneCredentialSha256),
        @($RclonePasswordHelperSource, $ExpectedRclonePasswordHelperSha256)
    )
    foreach ($asset in $validationAssets) {
        $source = [string]$asset[0]
        $expectedHash = [string]$asset[1]
        if ([string]::IsNullOrWhiteSpace($source) -or
            $expectedHash -cnotmatch '^[0-9a-f]{64}$') {
            throw 'ProvisionAssets requires four explicit sources and lowercase SHA-256 values.'
        }
        $sourceFull = [System.IO.Path]::GetFullPath($source)
        Assert-NormalFile -Path $sourceFull | Out-Null
        if ((Get-Sha256Hex -Path $sourceFull) -cne $expectedHash) {
            throw 'A cloud-verification asset source does not match its expected SHA-256.'
        }
    }
    $assetManifest = $null
}
elseif ($ProvisionAssets) {
    Assert-Elevated
    $assetManifest = Install-ProtectedCloudAssets `
        -Target $cloudVerificationRootFull `
        -CurrentUserSid $userSid
}
else {
    Assert-NormalDirectory -Path $cloudVerificationRootFull | Out-Null
    # The helper's file may differ from its record here only so that the plan below can recognise a refresh that was cut
    # short; the plan refuses anything else.
    $assetManifest = Read-VerifiedAssetManifest `
        -Root $cloudVerificationRootFull `
        -AllowPasswordHelperMismatch
    if (-not $ValidateOnly) {
        Assert-ProtectedTreeAcl `
            -Path $cloudVerificationRootFull `
            -CurrentUserSid $userSid
    }
}
if ($null -ne $assetManifest -and
    $assetManifest.PSObject.Properties.Name -contains 'task_user_sid' -and
    [string]$assetManifest.task_user_sid -cne $userSid) {
    throw 'Protected rclone assets are bound to another Windows account.'
}
# The protected assets keep a copy of the password helper from when they were set up. A helper of the packaged one's
# generation, in either line ending, stays; an earlier one Rewindle shipped is replaced when the task is registered
# (Invoke-PasswordHelperRefresh, below); anything else is refused, also under -ValidateOnly.
$passwordHelperPlan = $null
$recordedPasswordHelperSha256 = $null
if ($null -ne $assetManifest) {
    $passwordHelperState = Get-AssetPasswordHelperPlan `
        -Manifest $assetManifest `
        -Root $cloudVerificationRootFull `
        -HelperName $passwordHelperName `
        -PackagedHelperSha256 $packagedPasswordHelperSha256
    $passwordHelperPlan = $passwordHelperState.Plan
    $recordedPasswordHelperSha256 = $passwordHelperState.RecordedSha256
}
# The task starts the check through the task launcher, which runs the verifier in Windows PowerShell without a window
# (Task Scheduler starting powershell.exe itself shows a console window for a moment, even with -WindowStyle Hidden) and
# with Windows' own environment. The launcher takes the verifier, the configuration and the evidence folder from its own
# program folder and from Windows; only the repository ID is passed.
$arguments = '--google-drive-check --expected-repository-id ' + $repositoryId
if ($arguments -match
    '(?i)(password|credential|secret|DestinationRoot|sync_repository_to_google_drive)') {
    throw 'The verification action would expose a secret or legacy mirror argument.'
}

$validation = [ordered]@{
    schema_version = 1
    state = 'validated'
    task_name = $TaskName
    task_registration_performed = $false
    verification_only = $true
    source_copy_performed = $false
    asset_provisioning_requested = [bool]$ProvisionAssets
    asset_provisioning_performed = [bool]($ProvisionAssets -and -not $ValidateOnly)
    principal_logon_type = 'InteractiveToken'
    principal_run_level = 'HighestAvailable'
    daily_time = '03:00'
    multiple_instances = 'IgnoreNew'
    protected_root = $protectedRootFull
    protected_config = $configPathFull
    installed_verifier = $verifierPath
    installed_inventory_helper = $inventoryHelperPath
    local_repository = $localRepositoryFull
    my_drive_root = $myDriveRootFull
    plan_id = $parsedPlanId.ToString('D')
    config_generation = [long]$configuration.config_generation
    repository_id = $repositoryId
    run_lock_path = $runLockPath
    cloud_verification_root = $cloudVerificationRootFull
    asset_manifest = if ($null -eq $assetManifest) {
        $null
    } else {
        Join-Path $cloudVerificationRootFull 'assets-manifest.json'
    }
    asset_manifest_sha256 = if ($null -eq $assetManifest) {
        $null
    } else {
        Get-Sha256Hex -Path (
            Join-Path $cloudVerificationRootFull 'assets-manifest.json'
        )
    }
    # Recorded when the assets were provisioned; assets provisioned by an earlier version have none.
    rclone_version = if ($null -ne $assetManifest -and
        $assetManifest.PSObject.Properties.Name -contains 'rclone_version') {
        [string]$assetManifest.rclone_version
    } else {
        $null
    }
    # 'needed' when registering the task replaces the protected password helper (and the one it replaces is named),
    # 'performed' once it has, 'not_needed' when the assets already hold the packaged helper's generation.
    password_helper_refresh = if ($null -eq $passwordHelperPlan) {
        $null
    } elseif ($passwordHelperPlan -ceq 'current') {
        'not_needed'
    } else {
        'needed'
    }
    password_helper_previous_sha256 = if ($null -ne $passwordHelperPlan -and $passwordHelperPlan -cne 'current') {
        $recordedPasswordHelperSha256
    } else {
        $null
    }
    password_helper_previous_copy = $null
    action_execute = $launcherPath
    action_arguments = $arguments
    action_working_directory = $protectedRootFull
    local_mirror_destination = $null
}
if ($ValidateOnly) {
    # ASCII only, with any other character as a JSON \u escape: this text passes through the console's code page, which may
    # have no letter for a character in a path.
    [regex]::Replace(
        ($validation | ConvertTo-Json -Depth 5),
        '[^\x00-\x7F]',
        { param($match) '\u{0:x4}' -f [int][char]$match.Value }
    )
    return
}

Assert-Elevated
Assert-ProtectedRootAcl `
    -Path $protectedRootFull `
    -CurrentUserSid $userSid
Import-TrustedScheduledTasksModule

$existingTask = ScheduledTasks\Get-ScheduledTask `
    -TaskName $TaskName `
    -ErrorAction SilentlyContinue
$previousXml = $null
$previousTaskEvidence = $null
if ($null -ne $existingTask) {
    if ([string]$existingTask.State -eq 'Running') {
        throw 'Refusing to replace a running Google Drive task.'
    }
    if ((Convert-TaskPrincipalToSid `
        -UserId ([string]$existingTask.Principal.UserId)) -cne $userSid) {
        throw 'Refusing to replace a Google Drive task owned by another account.'
    }
    $previousXml = ScheduledTasks\Export-ScheduledTask -TaskName $TaskName
}
if (Test-Path -LiteralPath $taskEvidencePath -PathType Leaf) {
    $previousTaskEvidence = [System.IO.File]::ReadAllText(
        $taskEvidencePath,
        [System.Text.Encoding]::UTF8
    )
}

# After an update that changed the password helper, the protected assets still hold the earlier one. It is replaced
# here, after every check above and before the task is registered, and the assets are then checked again as they are.
if ($null -ne $passwordHelperPlan -and $passwordHelperPlan -cne 'current') {
    $passwordHelperRefresh = Invoke-PasswordHelperRefresh `
        -Root $cloudVerificationRootFull `
        -Plan $passwordHelperPlan `
        -HelperName $passwordHelperName `
        -PackagedHelperPath $passwordHelperPath `
        -PackagedHelperSha256 $packagedPasswordHelperSha256 `
        -RunLockPath $runLockPath `
        -CurrentUserSid $userSid
    foreach ($field in @($passwordHelperRefresh.Keys)) {
        $validation[$field] = $passwordHelperRefresh[$field]
    }
}

$action = ScheduledTasks\New-ScheduledTaskAction `
    -Execute $launcherPath `
    -Argument $arguments `
    -WorkingDirectory $protectedRootFull
$dailyTrigger = ScheduledTasks\New-ScheduledTaskTrigger `
    -Daily `
    -At ([DateTime]::Today.AddHours(3))
# New-ScheduledTaskTrigger writes the start in UTC, which keeps the task at one UTC moment and moves it an hour whenever the
# clocks change. Without an offset it stays at 03:00 local time all year.
$dailyTrigger.StartBoundary = [DateTime]::Today.AddHours(3).ToString(
    'yyyy-MM-dd''T''HH:mm:ss',
    [Globalization.CultureInfo]::InvariantCulture)
$taskPrincipal = ScheduledTasks\New-ScheduledTaskPrincipal `
    -UserId $account `
    -LogonType Interactive `
    -RunLevel Highest
$settings = ScheduledTasks\New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 12)
$description = (
    'Verification only: compares the sole streamed My Drive Restic repository ' +
    'with a read-only Google Drive API inventory and verifies a direct-cloud ' +
    'restore. It never copies, mirrors, deletes, or prunes repository files.'
)

$registrationAttempted = $false
try {
    $registrationAttempted = $true
    ScheduledTasks\Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $dailyTrigger `
        -Principal $taskPrincipal `
        -Settings $settings `
        -Description $description `
        -Force | Out-Null
    $registeredTask = ScheduledTasks\Get-ScheduledTask `
        -TaskName $TaskName `
        -ErrorAction Stop
    if ([string]$registeredTask.State -eq 'Disabled') {
        throw 'The newly registered verification task is unexpectedly disabled.'
    }
    $registeredXml = ScheduledTasks\Export-ScheduledTask -TaskName $TaskName
    Assert-RegisteredTaskDefinition `
        -Xml $registeredXml `
        -ExpectedExecute $launcherPath `
        -ExpectedArguments $arguments `
        -ExpectedWorkingDirectory $protectedRootFull `
        -ExpectedUserSid $userSid
    Write-AtomicTaskEvidence `
        -Path $taskEvidencePath `
        -Xml $registeredXml

    $validation.state = 'installed'
    $validation.task_registration_performed = $true
    $validation.task_state = [string]$registeredTask.State
    $validation.task_definition_evidence = $taskEvidencePath
    $validation.task_definition_sha256 = Get-Sha256Hex -Path $taskEvidencePath
    $validation | ConvertTo-Json -Depth 5
}
catch {
    $installFailure = $_
    if ($registrationAttempted) {
        try {
            if ($null -ne $previousXml) {
                ScheduledTasks\Register-ScheduledTask `
                    -TaskName $TaskName `
                    -Xml $previousXml `
                    -Force | Out-Null
            }
            else {
                $partialTask = ScheduledTasks\Get-ScheduledTask `
                    -TaskName $TaskName `
                    -ErrorAction SilentlyContinue
                if ($null -ne $partialTask) {
                    ScheduledTasks\Unregister-ScheduledTask `
                        -TaskName $TaskName `
                        -Confirm:$false `
                        -ErrorAction Stop
                }
            }
            if ($null -ne $previousTaskEvidence) {
                Write-AtomicTaskEvidence `
                    -Path $taskEvidencePath `
                    -Xml $previousTaskEvidence
            }
            elseif (Test-Path -LiteralPath $taskEvidencePath -PathType Leaf) {
                Remove-Item `
                    -LiteralPath $taskEvidencePath `
                    -Force `
                    -ErrorAction Stop
            }
        }
        catch {
            throw (
                'Verification task installation and rollback both failed. ' +
                "Install: $($installFailure.Exception.Message) " +
                "Rollback: $($_.Exception.Message)"
            )
        }
    }
    throw $installFailure
}
