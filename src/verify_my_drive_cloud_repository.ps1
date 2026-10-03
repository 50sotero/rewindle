[CmdletBinding()]
param(
    [string]$ConfigPath = (
        [System.IO.Path]::Combine(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
            'ResticBackuper',
            'backup-config.json'
        )
    ),
    [string]$LocalRepository = '',
    [string]$MyDriveRoot = '',
    [string]$CloudVerificationRoot = (
        [System.IO.Path]::Combine(
            [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::CommonApplicationData
            ),
            'ResticBackuperCloudVerification'
        )
    ),
    [string]$CloudRootFolderId = 'root',
    [string]$CloudRepositoryPath = '',
    [string]$ExpectedRepositoryId = '',
    [string]$SnapshotId = '',
    [string]$CanarySnapshotPath = '',
    [string]$CanaryReferencePath = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Test-PathsOverlap {
    param(
        [Parameter(Mandatory)] [string]$Left,
        [Parameter(Mandatory)] [string]$Right
    )

    $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\')
    $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\')
    return [string]::Equals(
        $leftFull,
        $rightFull,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
        $leftFull.StartsWith(
            $rightFull + '\',
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $rightFull.StartsWith(
            $leftFull + '\',
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

function Assert-NormalFile {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required verification input not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Verification input is a reparse point or non-file: $Path"
    }
    return $item
}

function Assert-NormalDirectory {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required verification directory not found: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Verification directory is a reparse point or non-directory: $Path"
    }
    return $item
}

function Assert-ProtectedAcl {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$CurrentUserSid,
        [switch]$RequireProtectedInheritance
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A protected cloud-verification path is a reparse point: $Path"
    }
    $acl = Get-Acl -LiteralPath $Path
    $ownerSid = ([System.Security.Principal.NTAccount]$acl.Owner).Translate(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    if ($ownerSid -ne 'S-1-5-32-544' -or
        ($RequireProtectedInheritance -and -not $acl.AreAccessRulesProtected)) {
        throw 'Cloud-verification storage must be Administrators-owned with protected inheritance.'
    }

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
    $sawSystemFull = $false
    $sawAdministratorsFull = $false
    foreach ($rule in $acl.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]
    )) {
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -ne
                [System.Security.AccessControl.AccessControlType]::Allow -or
            $sid -notin $allowedSids) {
            throw "Cloud-verification storage has an unexpected ACL entry for $sid."
        }
        if ($sid -eq 'S-1-5-18' -and
            ($rule.FileSystemRights -band
                [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                [System.Security.AccessControl.FileSystemRights]::FullControl) {
            $sawSystemFull = $true
        }
        if ($sid -eq 'S-1-5-32-544' -and
            ($rule.FileSystemRights -band
                [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                [System.Security.AccessControl.FileSystemRights]::FullControl) {
            $sawAdministratorsFull = $true
        }
        if ($sid -in @($CurrentUserSid, 'S-1-3-4') -and
            ($rule.FileSystemRights -band $dangerous) -ne 0) {
            throw 'Cloud-verification storage grants the task user write access outside elevation.'
        }
    }
    if (-not $sawSystemFull -or -not $sawAdministratorsFull) {
        throw 'Cloud-verification storage lacks required SYSTEM/Administrators control.'
    }
}

function Assert-ProtectedTree {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    Assert-NormalDirectory -Path $Root | Out-Null
    Assert-ProtectedAcl `
        -Path $Root `
        -CurrentUserSid $CurrentUserSid `
        -RequireProtectedInheritance
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        Assert-ProtectedAcl `
            -Path $item.FullName `
            -CurrentUserSid $CurrentUserSid
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)] [string]$Path)

    $stream = [System.IO.File]::Open(
        [System.IO.Path]::GetFullPath($Path),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
            $sha256.ComputeHash($stream)
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Read-Utf8Json {
    param([Parameter(Mandatory)] [string]$Path)

    $text = [System.IO.File]::ReadAllText(
        [System.IO.Path]::GetFullPath($Path),
        [System.Text.UTF8Encoding]::new($false, $true)
    )
    return $text | ConvertFrom-Json
}

function ConvertTo-ResticSnapshotSortKey {
    param([Parameter(Mandatory)] [string]$Value)

    if ($Value.Length -gt 64 -or
        $Value -cnotmatch (
            '^(?<whole>[0-9]{4}-[0-9]{2}-[0-9]{2}T' +
            '[0-9]{2}:[0-9]{2}:[0-9]{2})' +
            '(?:\.(?<fraction>[0-9]{1,9}))?' +
            '(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$'
        )) {
        throw 'A Restic snapshot has an invalid RFC3339 timestamp.'
    }

    $wholeSecond = [string]$Matches['whole']
    $fraction = [string]$Matches['fraction']
    $zone = [string]$Matches['zone']
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        $wholeSecond + $zone,
        "yyyy-MM-dd'T'HH:mm:ssK",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )) {
        throw 'A Restic snapshot has an invalid RFC3339 timestamp.'
    }

    $fractionPadded = $fraction.PadRight(9, '0')
    $ticksWithinSecond = [int]::Parse(
        $fractionPadded.Substring(0, 7),
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture
    )
    $subTickNanoseconds = [int]::Parse(
        $fractionPadded.Substring(7, 2),
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture
    )
    return [pscustomobject][ordered]@{
        utc_ticks = [long]$parsed.UtcDateTime.Ticks + $ticksWithinSecond
        sub_tick_nanoseconds = $subTickNanoseconds
    }
}

function Get-ResticSnapshotListingFromJson {
    param([Parameter(Mandatory)] [string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json) -or $Json.Length -gt 64MB) {
        throw 'The direct-cloud Restic snapshot listing is empty or unexpectedly large.'
    }
    try {
        # Windows PowerShell 5.1 emits a top-level JSON array as one pipeline
        # object. Assign it first, require Object[], then enumerate explicitly.
        $document = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    }
    catch {
        throw 'The direct-cloud Restic snapshot listing is invalid JSON.'
    }
    if ($document -isnot [System.Array]) {
        throw 'The direct-cloud Restic snapshot listing must be a top-level array.'
    }
    $snapshots = [object[]]$document
    if ($snapshots.Count -lt 1) {
        throw 'The direct-cloud Restic repository contains no snapshots.'
    }

    $seenIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $validated = [System.Collections.Generic.List[object]]::new()
    $latestUtcTicks = [long]::MinValue
    $latestSubTickNanoseconds = -1
    foreach ($snapshot in $snapshots) {
        if ($null -eq $snapshot -or
            $snapshot.GetType().FullName -cne
                'System.Management.Automation.PSCustomObject') {
            throw 'The direct-cloud Restic snapshot listing contains a non-object item.'
        }
        $propertyNames = @($snapshot.PSObject.Properties.Name)
        if ($propertyNames -notcontains 'id' -or
            $propertyNames -notcontains 'time' -or
            $snapshot.id -isnot [string] -or
            $snapshot.time -isnot [string]) {
            throw 'A direct-cloud Restic snapshot lacks a string id or time.'
        }
        $id = [string]$snapshot.id
        $time = [string]$snapshot.time
        if ($id -cnotmatch '^[0-9a-f]{64}$' -or -not $seenIds.Add($id)) {
            throw 'A direct-cloud Restic snapshot has an invalid or duplicate identity.'
        }
        $sortKey = ConvertTo-ResticSnapshotSortKey -Value $time
        $record = [pscustomobject][ordered]@{
            id = $id
            time = $time
            utc_ticks = [long]$sortKey.utc_ticks
            sub_tick_nanoseconds = [int]$sortKey.sub_tick_nanoseconds
        }
        $validated.Add($record)
        if ($record.utc_ticks -gt $latestUtcTicks -or
            ($record.utc_ticks -eq $latestUtcTicks -and
                $record.sub_tick_nanoseconds -gt
                    $latestSubTickNanoseconds)) {
            $latestUtcTicks = [long]$record.utc_ticks
            $latestSubTickNanoseconds = [int]$record.sub_tick_nanoseconds
        }
    }

    $latestSnapshotIds = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $validated) {
        if ($record.utc_ticks -eq $latestUtcTicks -and
            $record.sub_tick_nanoseconds -eq $latestSubTickNanoseconds) {
            $latestSnapshotIds.Add([string]$record.id)
        }
    }
    return [pscustomobject][ordered]@{
        count = $validated.Count
        snapshots = [object[]]$validated.ToArray()
        latest_snapshot_ids = [string[]]$latestSnapshotIds.ToArray()
        latest_utc_ticks = $latestUtcTicks
        latest_sub_tick_nanoseconds = $latestSubTickNanoseconds
    }
}

function Read-VerifiedAssetManifest {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$ExpectedUserSid
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
        [string]$manifest.task_user_sid -cne $ExpectedUserSid -or
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
            throw 'The cloud-verification asset manifest has an unsafe or duplicate name.'
        }
        $path = Join-Path $Root $name
        $item = Assert-NormalFile -Path $path
        $sha256 = [string]$record.sha256
        if (($record.bytes -isnot [int] -and
                $record.bytes -isnot [long]) -or
            [long]$record.bytes -ne $item.Length -or
            $sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-Sha256Hex -Path $path) -cne $sha256) {
            throw "Cloud-verification asset size or hash mismatch: $name"
        }
    }
    foreach ($name in $requiredNames) {
        if (-not $seen.Contains($name)) {
            throw "The cloud-verification asset manifest omits: $name"
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

function Convert-ToResticSnapshotPath {
    param([Parameter(Mandatory)] [string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -notmatch '^[A-Za-z]:\\$') {
        throw 'The canary must use a local drive-letter path.'
    }
    $drive = $root.Substring(0, 1)
    $tail = $fullPath.Substring($root.Length).TrimStart('\').Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($tail)) {
        throw 'The canary path cannot be a volume root.'
    }
    return '/' + $drive + '/' + $tail
}

function Write-NewJson {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Value
    )

    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace immutable verification evidence: $Path"
    }
    $directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory (
        'proof-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        [System.IO.File]::WriteAllText(
            $temporary,
            (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporary, $Path)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Value
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory (
        'latest-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $backup = Join-Path $directory (
        'latest-' + [Guid]::NewGuid().ToString('N') + '.bak'
    )
    try {
        [System.IO.File]::WriteAllText(
            $temporary,
            (($Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
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
            throw 'The latest verification evidence path is not a regular file.'
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

function ConvertTo-NativeArgument {
    param([AllowEmptyString()] [string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-NativeToFiles {
    param(
        [Parameter(Mandatory)] [string]$Executable,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$StdoutPath,
        [Parameter(Mandatory)] [string]$StderrPath
    )

    foreach ($path in @($StdoutPath, $StderrPath)) {
        if (Test-Path -LiteralPath $path) {
            throw "Refusing to replace a private native output file: $path"
        }
    }
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [System.IO.Path]::GetFullPath($Executable)
    $start.Arguments = (@(
        foreach ($argument in $Arguments) {
            ConvertTo-NativeArgument -Value ([string]$argument)
        }
    ) -join ' ')
    $start.WorkingDirectory = Split-Path -Parent $start.FileName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = $null
    $stderr = $null
    try {
        $stdout = [System.IO.File]::Open(
            $StdoutPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        $stderr = [System.IO.File]::Open(
            $StderrPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        if (-not $process.Start()) {
            throw 'The native verification process did not start.'
        }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask))
        $process.WaitForExit()
        $stdout.Flush($true)
        $stderr.Flush($true)
        return [int]$process.ExitCode
    }
    finally {
        if ($null -ne $stdout) { $stdout.Dispose() }
        if ($null -ne $stderr) { $stderr.Dispose() }
        $process.Dispose()
    }
}

function Invoke-RequiredNative {
    param(
        [Parameter(Mandatory)] [string]$Executable,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$StdoutPath,
        [Parameter(Mandatory)] [string]$StderrPath,
        [Parameter(Mandatory)] [string]$Operation
    )

    $exitCode = Invoke-NativeToFiles `
        -Executable $Executable `
        -Arguments $Arguments `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath
    if ($exitCode -ne 0) {
        throw "$Operation failed closed with exit code $exitCode. Review its private run log."
    }
}

function Enter-ProtectedRunLock {
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
    catch [System.UnauthorizedAccessException] {
        throw (
            'The protected run-lock handshake requires the elevated verification ' +
            'task; its ACL was not changed.'
        )
    }
    try {
        $stream.Lock(0, 1)
        return $stream
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

function Assert-SafeCloudPath {
    param([Parameter(Mandatory)] [string]$Path)

    if ($Path.Contains('\') -or
        $Path.StartsWith('/') -or
        $Path.EndsWith('/') -or
        @($Path.Split('/') | Where-Object {
            $_ -in @('', '.', '..') -or $_ -match '[\x00-\x1f]'
        }).Count -gt 0) {
        throw 'The cloud repository path is invalid.'
    }
}

$configPathFull = [System.IO.Path]::GetFullPath($ConfigPath)
$configItem = Assert-NormalFile -Path $configPathFull
if ($configItem.Length -gt 4MB) {
    throw 'The protected backup configuration is unexpectedly large.'
}
$config = Read-Utf8Json -Path $configPathFull
$preLockConfigSha256 = Get-Sha256Hex -Path $configPathFull
foreach ($property in @(
    'repository',
    'repository_storage_mode',
    'drivefs_my_drive_root',
    'restic_executable',
    'python_executable',
    'secret_file',
    'state_directory',
    'canary_file',
    'plan_id',
    'config_generation'
)) {
    if ($config.PSObject.Properties.Name -notcontains $property -or
        [string]::IsNullOrWhiteSpace([string]$config.$property)) {
        throw "Protected backup configuration is missing $property."
    }
}
if ([string]$config.repository_storage_mode -cne 'google_drivefs_stream') {
    throw 'Direct cloud verification requires google_drivefs_stream storage mode.'
}

$configuredRepository = [System.IO.Path]::GetFullPath(
    [string]$config.repository
).TrimEnd('\')
$configuredMyDriveRoot = [System.IO.Path]::GetFullPath(
    [string]$config.drivefs_my_drive_root
).TrimEnd('\')
$localRepositoryFull = if ([string]::IsNullOrWhiteSpace($LocalRepository)) {
    $configuredRepository
} else {
    [System.IO.Path]::GetFullPath($LocalRepository).TrimEnd('\')
}
$myDriveRootFull = if ([string]::IsNullOrWhiteSpace($MyDriveRoot)) {
    $configuredMyDriveRoot
} else {
    [System.IO.Path]::GetFullPath($MyDriveRoot).TrimEnd('\')
}
if (-not (Test-SamePath -Left $configuredRepository -Right $localRepositoryFull) -or
    -not (Test-SamePath -Left $configuredMyDriveRoot -Right $myDriveRootFull)) {
    throw 'The explicit My Drive paths do not match the protected configuration.'
}
Assert-DescendantPath `
    -Path $localRepositoryFull `
    -Parent $myDriveRootFull `
    -Message 'The live repository must be strictly below the streamed My Drive root.'
Assert-NormalDirectory -Path $myDriveRootFull | Out-Null
Assert-NormalDirectory -Path $localRepositoryFull | Out-Null
Assert-NormalFile -Path (Join-Path $localRepositoryFull 'config') | Out-Null

$derivedCloudPath = $localRepositoryFull.Substring(
    $myDriveRootFull.Length
).TrimStart('\').Replace('\', '/')
if ([string]::IsNullOrWhiteSpace($CloudRepositoryPath)) {
    $CloudRepositoryPath = $derivedCloudPath
}
Assert-SafeCloudPath -Path $CloudRepositoryPath
if (-not [string]::Equals(
    $derivedCloudPath,
    $CloudRepositoryPath,
    [System.StringComparison]::Ordinal
)) {
    throw 'The cloud path does not exactly map to the configured My Drive repository.'
}
if ($CloudRootFolderId -cne 'root') {
    throw 'The verifier is fail-closed to the Google Drive My Drive root.'
}
if ($ExpectedRepositoryId -and $ExpectedRepositoryId -cnotmatch '^[0-9a-f]{64}$') {
    throw 'ExpectedRepositoryId must be a lowercase complete Restic repository ID.'
}

$canaryReferenceFull = if ([string]::IsNullOrWhiteSpace($CanaryReferencePath)) {
    [System.IO.Path]::GetFullPath([string]$config.canary_file)
} else {
    [System.IO.Path]::GetFullPath($CanaryReferencePath)
}
if (-not (Test-SamePath -Left $canaryReferenceFull -Right ([string]$config.canary_file))) {
    throw 'The canary reference must be the protected configured canary.'
}
$derivedCanarySnapshotPath = Convert-ToResticSnapshotPath `
    -Path $canaryReferenceFull
if ([string]::IsNullOrWhiteSpace($CanarySnapshotPath)) {
    $CanarySnapshotPath = $derivedCanarySnapshotPath
}
if ($CanarySnapshotPath -cne $derivedCanarySnapshotPath) {
    throw 'The explicit canary snapshot path does not match the configured canary.'
}
Assert-NormalFile -Path $canaryReferenceFull | Out-Null

$resticExecutable = [System.IO.Path]::GetFullPath(
    [string]$config.restic_executable
)
$pythonExecutable = [System.IO.Path]::GetFullPath(
    [string]$config.python_executable
)
$secretFile = [System.IO.Path]::GetFullPath([string]$config.secret_file)
$stateDirectory = [System.IO.Path]::GetFullPath(
    [string]$config.state_directory
)
$secretStore = Join-Path (
    Split-Path -Parent $configPathFull
) 'secret_store.py'
$inventoryHelper = Join-Path $PSScriptRoot 'verify_cloud_repository_inventory.py'
$runLockPath = Join-Path $stateDirectory 'run.lock'
$lastSuccessPath = Join-Path $stateDirectory 'last-success.json'
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentUserSid = $identity.User.Value
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
    throw 'Production cloud verification is fixed to protected ProgramData storage.'
}
if ((Test-PathsOverlap `
        -Left $cloudVerificationRootFull `
        -Right $myDriveRootFull) -or
    (Test-PathsOverlap `
        -Left $cloudVerificationRootFull `
        -Right $stateDirectory)) {
    throw 'Cloud-verification assets and evidence must be isolated from My Drive and protected backup state.'
}
Assert-ProtectedTree `
    -Root $cloudVerificationRootFull `
    -CurrentUserSid $currentUserSid
$assetManifest = Read-VerifiedAssetManifest `
    -Root $cloudVerificationRootFull `
    -ExpectedUserSid $currentUserSid
$RemoteName = [string]$assetManifest.remote_name
$rcloneExecutable = Join-Path $cloudVerificationRootFull 'rclone.exe'
$rcloneConfigMaster = Join-Path $cloudVerificationRootFull 'rclone-readonly.conf'
$rcloneCredentialPath = Join-Path (
    $cloudVerificationRootFull
) 'rclone-config-password.clixml'
$rclonePasswordHelperPath = Join-Path (
    $cloudVerificationRootFull
) 'reveal-rclone-config-password.ps1'
$runsRoot = Join-Path $cloudVerificationRootFull 'runs'
$evidenceRoot = Join-Path $cloudVerificationRootFull 'evidence'
Assert-NormalDirectory -Path $runsRoot | Out-Null
Assert-NormalDirectory -Path $evidenceRoot | Out-Null
foreach ($requiredFile in @(
    $resticExecutable,
    $pythonExecutable,
    $secretFile,
    $secretStore,
    $inventoryHelper,
    $runLockPath,
    $lastSuccessPath,
    $rcloneExecutable,
    $rcloneConfigMaster,
    $rcloneCredentialPath,
    $rclonePasswordHelperPath
)) {
    Assert-NormalFile -Path $requiredFile | Out-Null
}
$rcloneProgram = $rcloneExecutable.Replace('\', '/')

$parsedPlanId = [Guid]::Empty
if (-not [Guid]::TryParseExact(
        [string]$config.plan_id,
        'D',
        [ref]$parsedPlanId
    ) -or
    $parsedPlanId -eq [Guid]::Empty -or
    $parsedPlanId.ToString('D') -cne [string]$config.plan_id -or
    ($config.config_generation -isnot [int] -and
        $config.config_generation -isnot [long]) -or
    [long]$config.config_generation -lt 1) {
    throw 'The protected configuration plan identity or generation is invalid.'
}
$configGeneration = [long]$config.config_generation

if ($ValidateOnly) {
    [ordered]@{
        schema_version = 1
        state = 'validated'
        verification_only = $true
        source_copy_performed = $false
        config_path = $configPathFull
        local_repository = $localRepositoryFull
        my_drive_root = $myDriveRootFull
        cloud_root_folder_id = $CloudRootFolderId
        cloud_repository_path = $CloudRepositoryPath
        canary_snapshot_path = $CanarySnapshotPath
        plan_id = $parsedPlanId.ToString('D')
        config_generation = $configGeneration
        run_lock_path = $runLockPath
        cloud_verification_root = $cloudVerificationRootFull
        asset_manifest = (Join-Path $cloudVerificationRootFull 'assets-manifest.json')
        evidence_root = $evidenceRoot
    } | ConvertTo-Json -Depth 5
    return
}

$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' +
    ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$runDirectory = Join-Path $runsRoot $runId
$restoreTarget = Join-Path $runDirectory 'restore'
[System.IO.Directory]::CreateDirectory($restoreTarget) | Out-Null
Assert-ProtectedAcl `
    -Path $runDirectory `
    -CurrentUserSid $currentUserSid
Assert-ProtectedAcl `
    -Path $restoreTarget `
    -CurrentUserSid $currentUserSid
$rcloneRunConfig = Join-Path $runDirectory 'rclone-readonly.conf'
[System.IO.File]::Copy($rcloneConfigMaster, $rcloneRunConfig, $false)
if ((Get-Sha256Hex -Path $rcloneRunConfig) -cne
    (Get-Sha256Hex -Path $rcloneConfigMaster)) {
    throw 'The protected per-run rclone configuration copy is not exact.'
}
Assert-ProtectedAcl `
    -Path $rcloneRunConfig `
    -CurrentUserSid $currentUserSid
$cloudInventoryPath = Join-Path $runDirectory 'cloud-inventory.json'
$inventoryProofPath = Join-Path $runDirectory 'inventory-proof.json'
$finalProofPath = Join-Path $runDirectory 'verification-proof.json'
$latestProofPath = Join-Path $evidenceRoot 'latest-verification.json'
$localCatStdout = Join-Path $runDirectory 'restic-local-cat-config.stdout.json'
$localCatStderr = Join-Path $runDirectory 'restic-local-cat-config.stderr.log'
$cloudCatStdout = Join-Path $runDirectory 'restic-cloud-cat-config.stdout.json'
$cloudCatStderr = Join-Path $runDirectory 'restic-cloud-cat-config.stderr.log'
$rcloneStderr = Join-Path $runDirectory 'rclone-cloud-inventory.stderr.log'
$inventoryHelperStdout = Join-Path $runDirectory 'inventory-helper.stdout.json'
$inventoryHelperStderr = Join-Path $runDirectory 'inventory-helper.stderr.log'
$snapshotStdout = Join-Path $runDirectory 'restic-cloud-snapshots.stdout.json'
$snapshotStderr = Join-Path $runDirectory 'restic-cloud-snapshots.stderr.log'
$restoreStdout = Join-Path $runDirectory 'restic-cloud-restore.stdout.log'
$restoreStderr = Join-Path $runDirectory 'restic-cloud-restore.stderr.log'

$environmentNames = @(
    'RCLONE_CONFIG',
    'RCLONE_PASSWORD_COMMAND',
    'RCLONE_ASK_PASSWORD',
    'RCLONE_DRIVE_SCOPE',
    'RCLONE_DRIVE_ROOT_FOLDER_ID',
    'RESTIC_PASSWORD_COMMAND'
)
$priorEnvironment = @{}
foreach ($name in $environmentNames) {
    $priorEnvironment[$name] = [Environment]::GetEnvironmentVariable(
        $name,
        'Process'
    )
}

$runLock = $null
try {
    $runLock = Enter-ProtectedRunLock -Path $runLockPath
    $configSha256 = Get-Sha256Hex -Path $configPathFull
    if ($configSha256 -cne $preLockConfigSha256) {
        throw 'The protected backup configuration changed while verification acquired the run lock.'
    }

    $lastSuccess = Read-Utf8Json -Path $lastSuccessPath
    $lastSnapshotId = [string]$lastSuccess.snapshot_id
    if ($lastSuccess.state -notin @('success', 'success_unchanged') -or
        $lastSuccess.verification_complete -ne $true -or
        [string]$lastSuccess.plan_id -cne $parsedPlanId.ToString('D') -or
        [long]$lastSuccess.config_generation -ne $configGeneration -or
        -not (Test-SamePath `
            -Left ([string]$lastSuccess.repository) `
            -Right $localRepositoryFull) -or
        [string]$lastSuccess.repository_storage_mode -cne
            'google_drivefs_stream' -or
        $lastSnapshotId -cnotmatch '^[0-9a-f]{64}$') {
        throw 'The latest successful backup evidence does not match the active My Drive repository.'
    }
    if ([string]::IsNullOrWhiteSpace($SnapshotId)) {
        $SnapshotId = $lastSnapshotId
    }
    if ($SnapshotId -cne $lastSnapshotId) {
        throw 'SnapshotId must match the latest successfully verified backup.'
    }

    $repositoryLocksPath = Join-Path $localRepositoryFull 'locks'
    if (Test-Path -LiteralPath $repositoryLocksPath -PathType Container) {
        $repositoryLocks = @(
            Get-ChildItem `
                -LiteralPath $repositoryLocksPath `
                -File `
                -Force `
                -ErrorAction Stop
        )
        if ($repositoryLocks.Count -gt 0) {
            throw 'The Restic repository contains a lock; cloud verification requires an idle repository.'
        }
    }

    $powershellExecutable = Join-Path (
        [System.IO.Directory]::GetParent(
            [Environment]::SystemDirectory
        ).FullName
    ) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-NormalFile -Path $powershellExecutable | Out-Null
    $rclonePasswordCommand = (
        '"{0}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-File "{1}" -CredentialPath "{2}"' -f
        $powershellExecutable,
        ([System.IO.Path]::GetFullPath($rclonePasswordHelperPath)),
        ([System.IO.Path]::GetFullPath($rcloneCredentialPath))
    )
    $resticPasswordCommand = (
        '"{0}" -I -S -B "{1}" reveal --secret-file "{2}"' -f
        $pythonExecutable,
        $secretStore,
        $secretFile
    )
    [Environment]::SetEnvironmentVariable(
        'RCLONE_CONFIG',
        [System.IO.Path]::GetFullPath($rcloneRunConfig),
        'Process'
    )
    [Environment]::SetEnvironmentVariable(
        'RCLONE_PASSWORD_COMMAND',
        $rclonePasswordCommand,
        'Process'
    )
    [Environment]::SetEnvironmentVariable(
        'RCLONE_ASK_PASSWORD',
        'false',
        'Process'
    )
    [Environment]::SetEnvironmentVariable(
        'RCLONE_DRIVE_SCOPE',
        'drive.readonly',
        'Process'
    )
    [Environment]::SetEnvironmentVariable(
        'RCLONE_DRIVE_ROOT_FOLDER_ID',
        $CloudRootFolderId,
        'Process'
    )
    [Environment]::SetEnvironmentVariable(
        'RESTIC_PASSWORD_COMMAND',
        $resticPasswordCommand,
        'Process'
    )

    Invoke-RequiredNative `
        -Executable $resticExecutable `
        -Arguments @(
            '--repo', $localRepositoryFull,
            '--no-lock',
            '--no-cache',
            'cat',
            'config'
        ) `
        -StdoutPath $localCatStdout `
        -StderrPath $localCatStderr `
        -Operation 'Local Restic repository authentication'
    $localConfig = Read-Utf8Json -Path $localCatStdout

    $remoteRepository = 'rclone:' + $RemoteName + ':' + $CloudRepositoryPath
    $resticCloudCommon = @(
        '--repo', $remoteRepository,
        '--no-lock',
        '--no-cache',
        '-o', ('rclone.program=' + $rcloneProgram),
        '-o', 'rclone.timeout=2m'
    )
    Invoke-RequiredNative `
        -Executable $resticExecutable `
        -Arguments ($resticCloudCommon + @('cat', 'config')) `
        -StdoutPath $cloudCatStdout `
        -StderrPath $cloudCatStderr `
        -Operation 'Direct-cloud Restic repository authentication'
    $cloudConfig = Read-Utf8Json -Path $cloudCatStdout

    $localRepositoryId = [string]$localConfig.id
    $cloudRepositoryId = [string]$cloudConfig.id
    if ($localRepositoryId -cnotmatch '^[0-9a-f]{64}$' -or
        $cloudRepositoryId -cnotmatch '^[0-9a-f]{64}$' -or
        $localRepositoryId -cne $cloudRepositoryId) {
        throw 'The local and direct-cloud Restic repository identities do not match.'
    }
    if ($ExpectedRepositoryId -and
        $localRepositoryId -cne $ExpectedRepositoryId) {
        throw 'The authenticated repository does not match ExpectedRepositoryId.'
    }
    if ([string]$lastSuccess.repository_id -cne $localRepositoryId) {
        throw 'The latest successful backup is bound to a different repository identity.'
    }

    Invoke-RequiredNative `
        -Executable $rcloneExecutable `
        -Arguments @(
            'lsjson',
            ($RemoteName + ':' + $CloudRepositoryPath),
            '--recursive',
            '--files-only',
            '--hash-type', 'MD5',
            '--hash-type', 'SHA-256'
        ) `
        -StdoutPath $cloudInventoryPath `
        -StderrPath $rcloneStderr `
        -Operation 'Direct Google Drive inventory'

    $inventoryHelperExit = Invoke-NativeToFiles `
        -Executable $pythonExecutable `
        -Arguments @(
            '-I',
            '-S',
            '-B',
            $inventoryHelper,
            '--local-repository', $localRepositoryFull,
            '--cloud-inventory', $cloudInventoryPath,
            '--proof', $inventoryProofPath
        ) `
        -StdoutPath $inventoryHelperStdout `
        -StderrPath $inventoryHelperStderr
    if ($inventoryHelperExit -ne 0) {
        $category = 'inventory_verification_failed_closed'
        try {
            $helperResult = Read-Utf8Json -Path $inventoryHelperStdout
            if ([string]$helperResult.category -match '^[a-z0-9_]{1,80}$') {
                $category = [string]$helperResult.category
            }
        }
        catch { }
        throw "Direct Google Drive inventory verification failed closed: $category."
    }
    $inventoryProof = Read-Utf8Json -Path $inventoryProofPath
    if ([string]$inventoryProof.state -cne 'verified' -or
        $inventoryProof.exact_file_inventory_verified -ne $true -or
        $inventoryProof.path_case_size_md5_sha256_verified -ne $true) {
        throw 'The inventory helper did not publish complete exact-match evidence.'
    }

    Invoke-RequiredNative `
        -Executable $resticExecutable `
        -Arguments ($resticCloudCommon + @('snapshots', '--json')) `
        -StdoutPath $snapshotStdout `
        -StderrPath $snapshotStderr `
        -Operation 'Direct-cloud Restic snapshot listing'
    $snapshotItem = Assert-NormalFile -Path $snapshotStdout
    if ($snapshotItem.Length -lt 2 -or $snapshotItem.Length -gt 64MB) {
        throw 'The direct-cloud Restic snapshot listing is empty or unexpectedly large.'
    }
    $snapshotListingJson = [System.IO.File]::ReadAllText(
        [System.IO.Path]::GetFullPath($snapshotStdout),
        [System.Text.UTF8Encoding]::new($false, $true)
    )
    $snapshotListing = Get-ResticSnapshotListingFromJson `
        -Json $snapshotListingJson
    $latestSnapshotMatches = $false
    $verifiedSnapshotTime = ''
    foreach ($snapshotRecord in $snapshotListing.snapshots) {
        if ([string]$snapshotRecord.id -ceq $SnapshotId) {
            $verifiedSnapshotTime = [string]$snapshotRecord.time
            if ($SnapshotId -in
                [string[]]$snapshotListing.latest_snapshot_ids) {
                $latestSnapshotMatches = $true
            }
        }
    }
    if (-not $latestSnapshotMatches) {
        throw (
            'The latest successfully verified backup is not the latest ' +
            'snapshot in the direct-cloud repository.'
        )
    }

    $referenceItem = Get-Item -LiteralPath $canaryReferenceFull -Force
    $expectedCanaryBytes = [long]$referenceItem.Length
    $expectedCanarySha256 = Get-Sha256Hex -Path $canaryReferenceFull
    Invoke-RequiredNative `
        -Executable $resticExecutable `
        -Arguments ($resticCloudCommon + @(
            'restore', $SnapshotId,
            '--target', $restoreTarget,
            '--include', $CanarySnapshotPath,
            '--verify'
        )) `
        -StdoutPath $restoreStdout `
        -StderrPath $restoreStderr `
        -Operation 'Independent direct-cloud Restic restore'

    $relativeCanary = $CanarySnapshotPath.TrimStart('/').Replace('/', '\')
    $restoredCanary = Join-Path $restoreTarget $relativeCanary
    Assert-NormalFile -Path $restoredCanary | Out-Null
    $restoredItem = Get-Item -LiteralPath $restoredCanary -Force
    $restoredSha256 = Get-Sha256Hex -Path $restoredCanary
    if ([long]$restoredItem.Length -ne $expectedCanaryBytes -or
        $restoredSha256 -cne $expectedCanarySha256) {
        throw 'The direct-cloud restored canary failed its length or SHA-256 check.'
    }
    if ((Get-Sha256Hex -Path $configPathFull) -cne $configSha256) {
        throw 'The protected backup configuration changed during cloud verification.'
    }
    [void](Read-VerifiedAssetManifest `
        -Root $cloudVerificationRootFull `
        -ExpectedUserSid $currentUserSid)
    Assert-ProtectedTree `
        -Root $cloudVerificationRootFull `
        -CurrentUserSid $currentUserSid

    $proof = [ordered]@{
        schema_version = 2
        proof_kind = 'direct_my_drive_cloud_repository_verification'
        run_id = $runId
        state = 'verified'
        verified_utc = [DateTime]::UtcNow.ToString('o')
        verification_mode = 'google_drive_api_readonly_rclone_backend'
        verification_phase = 'post_activation'
        plan_id = $parsedPlanId.ToString('D')
        config_generation = $configGeneration
        repository_storage_mode = 'google_drivefs_stream'
        config_repository = $configuredRepository
        intended_repository = $localRepositoryFull
        intended_storage_mode = 'google_drivefs_stream'
        local_repository = $localRepositoryFull
        my_drive_root = $myDriveRootFull
        cloud_root_folder_id = $CloudRootFolderId
        cloud_repository_path = $CloudRepositoryPath
        repository_identity_verified = $true
        repository_id = $localRepositoryId
        local_repository_id = $localRepositoryId
        cloud_repository_id = $cloudRepositoryId
        repository_version = [int]$cloudConfig.version
        exact_file_inventory_verified = $true
        path_case_size_md5_sha256_verified = $true
        files = [long]$inventoryProof.files
        bytes = [long]$inventoryProof.bytes
        verified_files = [long]$inventoryProof.files
        verified_bytes = [long]$inventoryProof.bytes
        missing_files = [long]$inventoryProof.missing_files
        extra_files = [long]$inventoryProof.extra_files
        mismatched_files = [long]$inventoryProof.mismatched_files
        size_mismatches = 0
        hash_mismatches = 0
        content_mismatches = 0
        inventory_fingerprint_sha256 = [string]$inventoryProof.inventory_fingerprint_sha256
        cloud_inventory_document_sha256 = [string]$inventoryProof.cloud_inventory_document_sha256
        cloud_objects_with_ids = [long]$inventoryProof.cloud_objects_with_ids
        snapshot_id = $SnapshotId
        snapshot_time = $verifiedSnapshotTime
        direct_cloud_snapshot_count = [long]$snapshotListing.count
        direct_cloud_latest_snapshot_verified = $true
        canary_snapshot_path = $CanarySnapshotPath
        canary_reference = $canaryReferenceFull
        canary_bytes = $expectedCanaryBytes
        canary_sha256 = $restoredSha256
        direct_cloud_restore_verified = $true
        provider_upload_state = 'fully_synced'
        restore_verification_state = 'verified'
        restore_target = $restoreTarget
        restored_canary = $restoredCanary
        run_lock_held = $true
        rclone_scope = 'drive.readonly'
        native_capture_mode = 'binary_stream_copy'
        cloud_verification_assets_manifest_sha256 = (
            Get-Sha256Hex -Path (
                Join-Path $cloudVerificationRootFull 'assets-manifest.json'
            )
        )
        inventory_proof = $inventoryProofPath
        backup_config_sha256 = $configSha256
    }
    Write-NewJson -Path $finalProofPath -Value $proof
    $immutableProofSha256 = Get-Sha256Hex -Path $finalProofPath
    $latestProof = [ordered]@{}
    foreach ($entry in $proof.GetEnumerator()) {
        $latestProof[$entry.Key] = $entry.Value
    }
    $latestProof['immutable_proof'] = $finalProofPath
    $latestProof['immutable_proof_sha256'] = $immutableProofSha256
    Write-AtomicJson -Path $latestProofPath -Value $latestProof
    Assert-ProtectedAcl `
        -Path $finalProofPath `
        -CurrentUserSid $currentUserSid
    Assert-ProtectedAcl `
        -Path $latestProofPath `
        -CurrentUserSid $currentUserSid
    Write-Output $latestProofPath
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable(
            $name,
            $priorEnvironment[$name],
            'Process'
        )
    }
    Exit-ProtectedRunLock -Stream $runLock
}
