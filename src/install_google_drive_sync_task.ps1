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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$verifierName = 'verify_my_drive_cloud_repository.ps1'
$inventoryHelperName = 'verify_cloud_repository_inventory.py'
$passwordHelperName = 'reveal-rclone-config-password.ps1'
$installerName = 'install_google_drive_sync_task.ps1'
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
    param([Parameter(Mandatory)] [string]$Root)

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
            [long]$record.bytes -ne $item.Length -or
            [string]$record.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-Sha256Hex -Path $path) -cne [string]$record.sha256) {
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

function Install-ProtectedCloudAssets {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    if (Test-Path -LiteralPath $Target) {
        throw 'Refusing to overwrite existing protected cloud-verification assets.'
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
        Write-NewUtf8Json `
            -Path (Join-Path $stage 'assets-manifest.json') `
            -Value ([ordered]@{
                schema_version = 1
                created_utc = [DateTime]::UtcNow.ToString('o')
                task_user_sid = $CurrentUserSid
                remote_name = $RemoteName
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
        $passwordHelperName
    )
foreach ($path in @(
    $configPathFull,
    $installerPath,
    $verifierPath,
    $inventoryHelperPath,
    $passwordHelperPath
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
    $assetManifest = Read-VerifiedAssetManifest `
        -Root $cloudVerificationRootFull
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
if ($null -ne $assetManifest) {
    $assetHelperRecords = @(
        $assetManifest.files |
            Where-Object {
                [string]$_.name -ceq $passwordHelperName
            }
    )
    if ($assetHelperRecords.Count -ne 1 -or
        [string]$assetHelperRecords[0].sha256 -cne
            $packagedPasswordHelperSha256) {
        throw 'Protected rclone assets do not contain the packaged password helper.'
    }
}
$powershell = Join-Path (
    [System.IO.Directory]::GetParent([Environment]::SystemDirectory).FullName
) 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-NormalFile -Path $powershell | Out-Null
$arguments = (
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-WindowStyle Hidden -File "' + $verifierPath + '" ' +
    '-ConfigPath "' + $configPathFull + '" ' +
    '-CloudVerificationRoot "' + $cloudVerificationRootFull + '" ' +
    '-ExpectedRepositoryId "' + $repositoryId + '"'
)
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
    action_execute = $powershell
    action_arguments = $arguments
    action_working_directory = $protectedRootFull
    local_mirror_destination = $null
}
if ($ValidateOnly) {
    $validation | ConvertTo-Json -Depth 5
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

$action = ScheduledTasks\New-ScheduledTaskAction `
    -Execute $powershell `
    -Argument $arguments `
    -WorkingDirectory $protectedRootFull
$dailyTrigger = ScheduledTasks\New-ScheduledTaskTrigger `
    -Daily `
    -At ([DateTime]::Today.AddHours(3))
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
        -ExpectedExecute $powershell `
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
