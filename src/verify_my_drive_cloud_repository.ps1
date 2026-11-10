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

# First, before any command: modules load only from Windows' own folder, never from the person's Documents folder.
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What the check is doing, for the failure record it leaves when it stops (see the trap below the functions).
$script:checkStep = 'checking_setup'
$script:checkFailureDetail = $null
$script:failureRecordTarget = $null

# Task Scheduler stops the task after 12 hours. The check stops itself well before that, so it can say why.
$checkTimeBudget = [TimeSpan]::FromHours(11)
# A check that Windows starts at sign-in or wake-up, to make up for a night the PC was off or asleep, can start before
# Google Drive for desktop and the network are back. It waits for them this long.
$googleDriveWait = [TimeSpan]::FromMinutes(30)
$networkWait = [TimeSpan]::FromMinutes(15)
# On such a late start the missed backup starts at about the same moment; it gets this long to take the run lock first.
$backupHeadStart = [TimeSpan]::FromMinutes(15)
# How long the check waits for a backup (or a protected change) that holds the run lock.
$backupWait = [TimeSpan]::FromHours(6)
# Runs kept besides the new one (and the one that holds the latest proof); older run folders are removed.
$previousRunsKept = 4
# Google Drive's SHA-256 checksums, which the inventory compares, need rclone 1.65.0 or later.
$minimumRcloneVersion = [Version]'1.65.0'

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

function Get-CanaryFolderSnapshotPath {
    param([Parameter(Mandatory)] [string]$CanaryPath)

    # The check restores the canary's own folder through Restic's
    # snapshotID:subfolder selector, so that folder can't be a drive root:
    # selecting one would restore everything backed up from that drive.
    $folder = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($CanaryPath)
    )
    if ([string]::IsNullOrEmpty($folder) -or
        $folder -eq [System.IO.Path]::GetPathRoot($folder)) {
        throw 'The canary must be inside a folder, not at the root of a drive.'
    }
    return Convert-ToResticSnapshotPath -Path $folder
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

function New-NativeChildEnvironment {
    # The complete environment of every rclone, Restic and Python child. This
    # task runs elevated, but Windows builds its environment from the user's
    # profile (HKCU\Environment included), which the user can change without
    # approval, and all three read settings from it: an inherited
    # RCLONE_CONFIG_<remote>_TYPE replaces the backend (and can run a program),
    # a token variable points the check at another account, and
    # RESTIC_PASSWORD_FILE stops every check. So nothing is inherited: the
    # Windows values come from the Windows API, TEMP and TMP point at this
    # run's protected folder, and only the settings this script chose are
    # added. PSModulePath is Windows' own module folder, for the rclone
    # password helper's Windows PowerShell.
    param(
        [Parameter(Mandatory)] [string]$TemporaryDirectory,
        [System.Collections.IDictionary]$Settings = @{}
    )

    $system = [Environment]::SystemDirectory
    $windows = [System.IO.Directory]::GetParent($system).FullName
    $environment = [ordered]@{
        SystemRoot = $windows
        windir = $windows
        SystemDrive = [System.IO.Path]::GetPathRoot($windows).TrimEnd('\')
        ComSpec = (Join-Path $system 'cmd.exe')
        PATH = (@(
            $system,
            $windows,
            (Join-Path $system 'Wbem'),
            (Join-Path $system 'WindowsPowerShell\v1.0')
        ) -join ';')
        PATHEXT = '.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC'
        OS = 'Windows_NT'
        NUMBER_OF_PROCESSORS = [string][Environment]::ProcessorCount
        PSModulePath = (Join-Path $system 'WindowsPowerShell\v1.0\Modules')
        TEMP = $TemporaryDirectory
        TMP = $TemporaryDirectory
    }
    $architecture = [Environment]::GetEnvironmentVariable(
        'PROCESSOR_ARCHITECTURE',
        'Process'
    )
    if ($architecture -cin @('AMD64', 'x86', 'ARM64')) {
        $environment['PROCESSOR_ARCHITECTURE'] = $architecture
    }
    foreach ($name in @($Settings.Keys)) {
        if ([string]$name -cnotmatch '^(RCLONE|RESTIC)_[A-Z_]{1,64}\z') {
            throw 'A native child setting has an unexpected name.'
        }
        $environment[[string]$name] = [string]$Settings[$name]
    }
    return $environment
}

function Get-ReadOnlyRemoteSpec {
    # The remote as an rclone connection string. Its options outrank the
    # configuration file and every RCLONE_* variable, so the read-only scope
    # and the My Drive root hold whatever the configuration or the
    # environment says.
    param(
        [Parameter(Mandatory)] [string]$RemoteName,
        [Parameter(Mandatory)] [string]$RootFolderId
    )

    if ($RemoteName -cnotmatch '^[A-Za-z0-9._-]{1,80}\z') {
        throw 'The read-only rclone remote name is invalid.'
    }
    if ($RootFolderId -cnotmatch '^[A-Za-z0-9_-]{1,128}\z') {
        throw 'The Google Drive root folder ID is invalid.'
    }
    return $RemoteName + ',scope=drive.readonly,root_folder_id=' + $RootFolderId
}

function Get-RemainingMilliseconds {
    param([Parameter(Mandatory)] [DateTime]$DeadlineUtc)

    $milliseconds = ($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
    return [int][Math]::Max(0, [Math]::Min([double][int]::MaxValue, $milliseconds))
}

function Get-NativeProcessTree {
    # The processes that this one started, and the ones they started, as exact process IDs with their start times.
    # Windows gives the ID of a process that has exited to new processes, so a process counts as a child only when it
    # started after the parent it names (the second of slack covers the two clocks' different precision).
    param(
        [Parameter(Mandatory)] [int]$RootId,
        [Parameter(Mandatory)] [DateTime]$RootStarted
    )

    $processes = @(CimCmdlets\Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    $tree = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ Id = $RootId; Started = $RootStarted })
    while ($pending.Count -gt 0) {
        $parent = $pending.Dequeue()
        foreach ($candidate in $processes) {
            $started = $candidate.CreationDate
            if ([int]$candidate.ParentProcessId -ne [int]$parent.Id -or
                [int]$candidate.ProcessId -eq [int]$parent.Id -or
                $null -eq $started -or
                ([DateTime]$started) -lt ([DateTime]$parent.Started).AddSeconds(-1)) {
                continue
            }
            $child = [pscustomobject]@{
                Id = [int]$candidate.ProcessId
                Started = [DateTime]$started
            }
            $tree.Add($child)
            $pending.Enqueue($child)
        }
    }
    return ,$tree.ToArray()
}

function Stop-ExactProcess {
    # Stops one process by its exact ID, and only while that ID still names the process that started at that time.
    param(
        [Parameter(Mandatory)] [int]$Id,
        [Parameter(Mandatory)] [DateTime]$Started
    )

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($Id)
    }
    catch {
        return
    }
    try {
        if (-not $process.HasExited -and
            [Math]::Abs(($process.StartTime - $Started).TotalSeconds) -lt 1) {
            $process.Kill()
        }
    }
    catch { }
    finally {
        $process.Dispose()
    }
}

function Stop-NativeProcessTree {
    # Stops a native step that ran past its deadline, and everything it started (Restic starts rclone), each by its
    # exact process ID. The children are listed first, while their parent is still there to name them.
    param([Parameter(Mandatory)] [System.Diagnostics.Process]$Process)

    $tree = @()
    try {
        $tree = Get-NativeProcessTree -RootId $Process.Id -RootStarted $Process.StartTime
    }
    catch { }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
        }
    }
    catch { }
    foreach ($child in $tree) {
        Stop-ExactProcess -Id ([int]$child.Id) -Started ([DateTime]$child.Started)
    }
}

function Format-PlainDuration {
    param([Parameter(Mandatory)] [TimeSpan]$Duration)

    $minutes = [long][Math]::Max(1, [Math]::Round($Duration.TotalMinutes))
    $hours = [long][Math]::Floor($minutes / 60)
    $rest = $minutes % 60
    $parts = @()
    if ($hours -eq 1) { $parts += '1 hour' }
    elseif ($hours -gt 1) { $parts += ('{0} hours' -f $hours) }
    if ($rest -eq 1) { $parts += '1 minute' }
    elseif ($rest -gt 1) { $parts += ('{0} minutes' -f $rest) }
    return ($parts -join ' ')
}

function Get-NativeTimeoutSeconds {
    # How long one native step may run: a fixed allowance, plus time for the repository's size at a slow but working
    # rate, and never past the end of the check's own time. A step that has no time left stops the check.
    param(
        [Parameter(Mandatory)] [double]$BaseSeconds,
        [Parameter(Mandatory)] [DateTime]$CheckDeadlineUtc,
        [long]$Bytes = 0,
        [double]$BytesPerSecond = 0,
        [long]$Files = 0,
        [double]$SecondsPerFile = 0
    )

    $seconds = $BaseSeconds
    if ($Bytes -gt 0 -and $BytesPerSecond -gt 0) {
        $seconds += $Bytes / $BytesPerSecond
    }
    if ($Files -gt 0 -and $SecondsPerFile -gt 0) {
        $seconds += $Files * $SecondsPerFile
    }
    $left = ($CheckDeadlineUtc - [DateTime]::UtcNow).TotalSeconds
    if ($left -lt 1) {
        Stop-Check `
            -Message 'The check used up its time before this step could start.' `
            -ReasonCode 'out_of_time' `
            -Reason (
                'The check ran out of time before ' + (Get-CheckStepLabel -Step $script:checkStep) + '.'
            ) `
            -NextStep 'Leave this PC on, awake and online overnight. Rewindle checks again tonight.'
    }
    return [int][Math]::Ceiling([Math]::Min($seconds, $left))
}

function Invoke-NativeToFiles {
    param(
        [Parameter(Mandatory)] [string]$Executable,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$StdoutPath,
        [Parameter(Mandatory)] [string]$StderrPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)] [ValidateRange(1, 2147483)] [int]$TimeoutSeconds
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
    # Nothing is inherited from this process (see New-NativeChildEnvironment).
    $start.EnvironmentVariables.Clear()
    foreach ($name in @($Environment.Keys)) {
        $start.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
    }
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
        $copies = [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)
        # Every step has a deadline sized for it (see Get-NativeTimeoutSeconds). The output is complete once the program
        # and everything it started have closed it, so both waits count against the same deadline.
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $finished = $process.WaitForExit(
            (Get-RemainingMilliseconds -DeadlineUtc $deadline)
        ) -and [System.Threading.Tasks.Task]::WaitAll(
            $copies,
            (Get-RemainingMilliseconds -DeadlineUtc $deadline)
        )
        if (-not $finished) {
            Stop-NativeProcessTree -Process $process
            try { [void][System.Threading.Tasks.Task]::WaitAll($copies, 10000) } catch { }
            # A step whose deadline was the end of the check's own time ran out of that time, not of its own.
            $checkDeadline = Get-Variable -Name 'checkDeadlineUtc' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
            if ($checkDeadline -is [DateTime] -and [DateTime]::UtcNow.AddSeconds(5) -ge $checkDeadline) {
                Stop-Check `
                    -Message 'A native verification step was stopped when the check used up its time.' `
                    -ReasonCode 'out_of_time' `
                    -Reason ('The check ran out of time while ' + (Get-CheckStepLabel -Step $script:checkStep) + '.') `
                    -NextStep 'Leave this PC on, awake and online overnight. Rewindle checks again tonight.'
            }
            Stop-Check `
                -Message ('A native verification step did not finish within {0} seconds and was stopped.' -f $TimeoutSeconds) `
                -ReasonCode 'timed_out' `
                -Reason (
                    'The check stopped because ' + (Get-CheckStepLabel -Step $script:checkStep) +
                    ' took longer than ' + (Format-PlainDuration -Duration ([TimeSpan]::FromSeconds($TimeoutSeconds))) + '.'
                ) `
                -NextStep 'Leave this PC on, awake and online overnight. Rewindle checks again tonight.'
        }
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
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Environment,
        [Parameter(Mandatory)] [string]$Operation,
        [Parameter(Mandatory)] [ValidateRange(1, 2147483)] [int]$TimeoutSeconds
    )

    $exitCode = Invoke-NativeToFiles `
        -Executable $Executable `
        -Arguments $Arguments `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath `
        -Environment $Environment `
        -TimeoutSeconds $TimeoutSeconds
    if ($exitCode -ne 0) {
        throw "$Operation failed closed with exit code $exitCode. Review its private run log."
    }
}

function Enter-ProtectedRunLock {
    # The run lock, or $null while a backup or a protected change holds it.
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

function Enter-ProtectedRunLockWhenFree {
    # A backup or a protected change holds the run lock while it runs; the check waits for it instead of giving up.
    # Each try takes the lock at once if it is free and gives it back nothing otherwise, as the backup's own try does.
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [DateTime]$DeadlineUtc,
        [double]$PollSeconds = 30
    )

    $waitStartedUtc = [DateTime]::UtcNow
    while ($true) {
        $stream = Enter-ProtectedRunLock -Path $Path
        if ($null -ne $stream) {
            return $stream
        }
        $remaining = Get-RemainingMilliseconds -DeadlineUtc $DeadlineUtc
        if ($remaining -le 0) {
            Stop-Check `
                -Message 'A backup or protected change held the run lock until the check stopped waiting.' `
                -ReasonCode 'backup_still_running' `
                -Reason (
                    'A backup was still running after ' +
                    (Format-PlainDuration -Duration ($DeadlineUtc - $waitStartedUtc)) +
                    ", so the check couldn't start."
                ) `
                -NextStep 'Open Activity to see whether a backup is stuck. Rewindle checks again tonight.'
        }
        [System.Threading.Thread]::Sleep(
            [int][Math]::Min([double]$remaining, $PollSeconds * 1000)
        )
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

function Get-CheckStepLabel {
    # What the check was doing at each step, in words for the dashboard ("It stopped while ...").
    param([Parameter(Mandatory)] [string]$Step)

    switch -CaseSensitive ($Step) {
        'checking_setup' { return 'checking its own setup' }
        'waiting_for_google_drive' { return 'waiting for Google Drive for desktop' }
        'waiting_for_network' { return 'waiting for an internet connection' }
        'waiting_for_backup' { return 'waiting for a backup to finish' }
        'checking_latest_backup' { return 'checking your latest backup' }
        'checking_rclone' { return 'starting its Google Drive tool (rclone)' }
        'opening_local_backup' { return 'opening your backup in the Google Drive folder on this PC' }
        'connecting_to_google_drive' { return 'connecting to your backup in Google Drive' }
        'listing_google_drive' { return "listing your backup's files in Google Drive" }
        'comparing_files' { return 'comparing the files in Google Drive with your backup on this PC' }
        'listing_cloud_backups' { return 'listing the backups in Google Drive' }
        'test_restore' { return 'restoring a test file from Google Drive' }
        'saving_result' { return 'saving its result' }
    }
    return 'checking the copy in Google Drive'
}

function Set-CheckStep {
    param([Parameter(Mandatory)] [string]$Step)

    $script:checkStep = $Step
    $script:checkFailureDetail = $null
}

function New-CheckFailureDetail {
    param(
        [Parameter(Mandatory)] [string]$ReasonCode,
        [Parameter(Mandatory)] [string]$Reason,
        [Parameter(Mandatory)] [string]$NextStep
    )

    return [pscustomobject][ordered]@{
        reason_code = $ReasonCode
        reason = $Reason
        next_step = $NextStep
    }
}

function Stop-Check {
    # Stops the check with a reason the person can act on. The message goes to the task's own error output; the reason
    # and the next step go to the failure record the dashboard shows (see the trap below the functions).
    param(
        [Parameter(Mandatory)] [string]$Message,
        [Parameter(Mandatory)] [string]$ReasonCode,
        [Parameter(Mandatory)] [string]$Reason,
        [Parameter(Mandatory)] [string]$NextStep
    )

    $script:checkFailureDetail = New-CheckFailureDetail `
        -ReasonCode $ReasonCode `
        -Reason $Reason `
        -NextStep $NextStep
    throw $Message
}

function Get-CheckFailureDescription {
    # The plain reason and next step for a check that stopped at this step, unless the place that stopped it gave its own.
    param(
        [Parameter(Mandatory)] [string]$Step,
        [AllowNull()] [object]$Detail
    )

    if ($null -ne $Detail) {
        return $Detail
    }
    $again = 'Rewindle checks again tonight.'
    $report = 'If this keeps happening, choose Save problem report in Settings.'
    $setUpAgain = "Set up the Google Drive check again, as Rewindle's guide to Google Drive describes."
    $online = 'Make sure this PC is online overnight. ' + $again
    switch -CaseSensitive ($Step) {
        'checking_setup' {
            return New-CheckFailureDetail -ReasonCode 'setup_changed' -NextStep $setUpAgain -Reason (
                'Something the check needs on this PC is missing or has changed since the check was set up.')
        }
        'waiting_for_google_drive' {
            return New-CheckFailureDetail -ReasonCode 'google_drive_not_ready' -Reason (
                "Google Drive for desktop wasn't ready.") -NextStep (
                'Make sure Google Drive for desktop is running and signed in. ' + $again)
        }
        'waiting_for_network' {
            return New-CheckFailureDetail -ReasonCode 'offline' -Reason (
                'This PC had no internet connection.') -NextStep (
                'Leave this PC connected to the internet overnight. ' + $again)
        }
        'waiting_for_backup' {
            # A backup that runs too long has words of its own (see Enter-ProtectedRunLockWhenFree).
            return New-CheckFailureDetail -ReasonCode 'run_lock_unusable' -NextStep ($again + ' ' + $report) -Reason (
                "Rewindle couldn't tell whether a backup was running.")
        }
        'checking_latest_backup' {
            return New-CheckFailureDetail -ReasonCode 'latest_backup_unusable' -Reason (
                "Your latest backup couldn't be matched with the backup in Google Drive.") -NextStep (
                'Choose Back up now, or wait for the next automatic backup. The check after it covers it.')
        }
        'checking_rclone' {
            return New-CheckFailureDetail -ReasonCode 'rclone_failed' -NextStep $setUpAgain -Reason (
                "The program the check uses to read Google Drive (rclone) didn't start.")
        }
        'opening_local_backup' {
            return New-CheckFailureDetail -ReasonCode 'local_backup_unreadable' -Reason (
                "Rewindle couldn't open your backup in the Google Drive folder on this PC.") -NextStep (
                'Make sure Google Drive for desktop is running and signed in. ' + $again)
        }
        'connecting_to_google_drive' {
            return New-CheckFailureDetail -ReasonCode 'google_drive_unreachable' -Reason (
                "Rewindle couldn't open your backup directly in Google Drive. The connection or the check's " +
                "Google sign-in didn't work.") -NextStep (
                "Make sure this PC is online overnight. If this keeps happening, the check's Google sign-in " +
                "needs to be set up again, as Rewindle's guide to Google Drive describes.")
        }
        'listing_google_drive' {
            return New-CheckFailureDetail -ReasonCode 'google_drive_list_failed' -NextStep $online -Reason (
                "Rewindle couldn't list your backup's files in Google Drive.")
        }
        'comparing_files' {
            return New-CheckFailureDetail -ReasonCode 'compare_failed' -NextStep ($again + ' ' + $report) -Reason (
                "Rewindle couldn't compare the files in Google Drive with your backup on this PC.")
        }
        'listing_cloud_backups' {
            return New-CheckFailureDetail -ReasonCode 'google_drive_backups_unlisted' -NextStep $online -Reason (
                "Rewindle couldn't list the backups in Google Drive.")
        }
        'test_restore' {
            return New-CheckFailureDetail -ReasonCode 'test_restore_failed' -NextStep ($again + ' ' + $report) -Reason (
                "A test restore of a small file from Google Drive didn't work.")
        }
        'saving_result' {
            return New-CheckFailureDetail -ReasonCode 'result_not_saved' -NextStep $again -Reason (
                "The check finished, but Rewindle couldn't save its result.")
        }
    }
    return New-CheckFailureDetail -ReasonCode 'check_failed' -NextStep ($again + ' ' + $report) -Reason (
        'The check stopped before it finished.')
}

function Format-FileCount {
    param([Parameter(Mandatory)] [long]$Count)

    if ($Count -eq 1) {
        return '1 file'
    }
    return $Count.ToString('N0', [Globalization.CultureInfo]::InvariantCulture) + ' files'
}

function Get-InventoryFailureDetail {
    # The plain reason for what the inventory helper found, or $null for a category that has no words of its own.
    param(
        [Parameter(Mandatory)] [string]$Category,
        [Parameter(Mandatory)] [long]$Count
    )

    $again = 'Rewindle checks again tonight.'
    $report = 'If this keeps happening, choose Save problem report in Settings.'
    $upload = 'Leave this PC on with Google Drive for desktop running until it has uploaded everything. ' + $again
    $fileCount = [Math]::Max([long]1, $Count)
    $files = Format-FileCount -Count $fileCount
    switch -CaseSensitive ($Category) {
        'cloud_files_missing' {
            if ($fileCount -eq 1) {
                $reason = "1 file of your backup isn't in Google Drive yet."
            }
            else {
                $reason = "$files of your backup aren't in Google Drive yet."
            }
            return New-CheckFailureDetail -ReasonCode $Category -NextStep $upload -Reason $reason
        }
        'cloud_files_extra' {
            return New-CheckFailureDetail -ReasonCode $Category -Reason (
                "Google Drive has $files in your backup folder that the backup on this PC doesn't have.") -NextStep (
                'Make sure nothing else changes your backup folder in Google Drive. ' + $again + ' ' + $report)
        }
        'cloud_size_mismatch' {
            if ($fileCount -eq 1) {
                $reason = (
                    "1 file in Google Drive isn't the same size as on this PC. Google Drive for desktop may still " +
                    'be uploading it.')
            }
            else {
                $reason = (
                    "$files in Google Drive aren't the same size as on this PC. Google Drive for desktop may still " +
                    'be uploading them.')
            }
            return New-CheckFailureDetail -ReasonCode $Category -NextStep $upload -Reason $reason
        }
        'cloud_content_mismatch' {
            if ($fileCount -eq 1) {
                $reason = "1 file in Google Drive doesn't match the one on this PC."
            }
            else {
                $reason = "$files in Google Drive don't match the ones on this PC."
            }
            return New-CheckFailureDetail -ReasonCode $Category -NextStep ($again + ' ' + $report) -Reason $reason
        }
        'local_repository_changed' {
            return New-CheckFailureDetail -ReasonCode $Category -NextStep $again -Reason (
                'Your backup changed while it was being checked.')
        }
    }
    return $null
}

function Write-CheckFailureRecord {
    # The record of a check that stopped, for the dashboard: when, at which step, why in plain words, and what to do. It
    # replaces the one before; a check that passes removes it (see Remove-CheckFailureRecord).
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Target,
        [Parameter(Mandatory)] [string]$Step,
        [AllowNull()] [object]$Detail,
        [AllowEmptyString()] [string]$Message = ''
    )

    $description = Get-CheckFailureDescription -Step $Step -Detail $Detail
    # The error itself, on one line and bounded, for anyone who looks at the file.
    $technical = ([regex]::Replace($Message, '[\x00-\x1f]+', ' ')).Trim()
    if ($technical.Length -gt 500) {
        $technical = $technical.Substring(0, 500)
    }
    $record = [ordered]@{
        schema_version = 1
        record_kind = 'direct_my_drive_cloud_check_failure'
        state = 'failed'
        run_id = [string]$Target['RunId']
        started_utc = ([DateTime]$Target['StartedUtc']).ToString('o')
        failed_utc = [DateTime]::UtcNow.ToString('o')
        step = $Step
        step_label = Get-CheckStepLabel -Step $Step
        reason_code = [string]$description.reason_code
        reason = [string]$description.reason
        next_step = [string]$description.next_step
        technical_detail = $technical
        plan_id = $Target['PlanId']
        config_generation = $Target['ConfigGeneration']
    }
    Write-AtomicJson -Path ([string]$Target['Path']) -Value $record
    Assert-ProtectedAcl `
        -Path ([string]$Target['Path']) `
        -CurrentUserSid ([string]$Target['CurrentUserSid'])
}

function Remove-CheckFailureRecord {
    param([Parameter(Mandatory)] [string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        [System.IO.File]::Delete($Path)
    }
}

function Assert-RecordableEvidenceFolder {
    # First of all, the two protected folders a failure record goes to: the cloud-verification root and its evidence
    # folder. Only these are looked at here (the whole tree is checked further on), so a problem anywhere else can still
    # be recorded, and nothing is ever written where the task's user could have put a link.
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$EvidenceRoot,
        [Parameter(Mandatory)] [string]$CurrentUserSid
    )

    Assert-NormalDirectory -Path $Root | Out-Null
    Assert-ProtectedAcl `
        -Path $Root `
        -CurrentUserSid $CurrentUserSid `
        -RequireProtectedInheritance
    Assert-NormalDirectory -Path $EvidenceRoot | Out-Null
    Assert-ProtectedAcl `
        -Path $EvidenceRoot `
        -CurrentUserSid $CurrentUserSid
}

function Wait-Until {
    # Polls the condition until it holds ($true) or the deadline passes ($false).
    param(
        [Parameter(Mandatory)] [scriptblock]$Condition,
        [Parameter(Mandatory)] [DateTime]$DeadlineUtc,
        [Parameter(Mandatory)] [double]$PollSeconds
    )

    while ($true) {
        if ([bool](& $Condition)) {
            return $true
        }
        $remaining = Get-RemainingMilliseconds -DeadlineUtc $DeadlineUtc
        if ($remaining -le 0) {
            return $false
        }
        [System.Threading.Thread]::Sleep(
            [int][Math]::Min([double]$remaining, $PollSeconds * 1000)
        )
    }
}

function Wait-ForMyDriveRepository {
    # Google Drive for desktop puts the Google Drive folder back a little after sign-in, and a check that Windows starts
    # then must not fail for that. It waits for the folder and the repository in it.
    param(
        [Parameter(Mandatory)] [string]$MyDriveRoot,
        [Parameter(Mandatory)] [string]$Repository,
        [Parameter(Mandatory)] [DateTime]$DeadlineUtc,
        [double]$PollSeconds = 15
    )

    $repositoryConfig = Join-Path $Repository 'config'
    $ready = Wait-Until -DeadlineUtc $DeadlineUtc -PollSeconds $PollSeconds -Condition {
        [System.IO.Directory]::Exists($MyDriveRoot) -and
            [System.IO.File]::Exists($repositoryConfig)
    }
    if ($ready) {
        return
    }
    $again = 'Rewindle checks again tonight.'
    if (-not [System.IO.Directory]::Exists($MyDriveRoot)) {
        Stop-Check `
            -Message "The streamed My Drive root did not appear in time: $MyDriveRoot" `
            -ReasonCode 'google_drive_folder_missing' `
            -Reason (
                "Your Google Drive folder ($MyDriveRoot) wasn't there. Google Drive for desktop may not have been " +
                'running, or it may use another drive letter now.') `
            -NextStep (
                'Make sure Google Drive for desktop starts when you sign in, stays signed in and keeps the drive ' +
                'letter it had when the check was set up. ' + $again)
    }
    Stop-Check `
        -Message "The repository did not appear below the streamed My Drive root in time: $Repository" `
        -ReasonCode 'backup_folder_missing' `
        -Reason "Your backup folder ($Repository) wasn't in your Google Drive folder." `
        -NextStep (
            'Make sure Google Drive for desktop is signed in to the Google account that holds your backups. ' + $again)
}

function Test-GoogleDriveReachable {
    # Whether Windows has a network and can look up Google Drive's address within 10 seconds. Nothing is sent to Google.
    if (-not [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()) {
        return $false
    }
    try {
        $lookup = [System.Net.Dns]::GetHostAddressesAsync('www.googleapis.com')
        if (-not $lookup.Wait(10000)) {
            return $false
        }
        return @($lookup.Result).Count -gt 0
    }
    catch {
        return $false
    }
}

function Wait-ForNetwork {
    param(
        [Parameter(Mandatory)] [DateTime]$DeadlineUtc,
        [double]$PollSeconds = 15
    )

    $ready = Wait-Until -DeadlineUtc $DeadlineUtc -PollSeconds $PollSeconds -Condition {
        Test-GoogleDriveReachable
    }
    if (-not $ready) {
        Stop-Check `
            -Message 'Google Drive could not be reached before the check stopped waiting.' `
            -ReasonCode 'offline' `
            -Reason "This PC couldn't reach Google Drive's servers." `
            -NextStep 'Leave this PC connected to the internet overnight. Rewindle checks again tonight.'
    }
}

function Get-LatestBackupStartUtc {
    # When the latest backup started, from the backup's own status file, or $null when that can't be read.
    param([Parameter(Mandatory)] [string]$StatusPath)

    try {
        if (-not [System.IO.File]::Exists($StatusPath)) {
            return $null
        }
        $item = Get-Item -LiteralPath $StatusPath -Force
        if ($item.PSIsContainer -or
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
            $item.Length -gt 4MB) {
            return $null
        }
        $status = Read-Utf8Json -Path $StatusPath
        if ($null -eq $status -or
            $status.PSObject.Properties.Name -notcontains 'started_utc') {
            return $null
        }
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParse(
            [string]$status.started_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor
                [Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$parsed
        )) {
            return [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
        }
    }
    catch { }
    return $null
}

function Wait-ForBackupHeadStart {
    # After a night the PC was off or asleep, Windows starts the missed backup and this check at about the same moment,
    # and the one that takes the run lock second gives up: a backup that can't start waits for the next night. So while
    # the latest backup is more than 20 hours old (a backup is due, or was missed), the check gives a backup time to start
    # first. Until a backup starts or that time is up it only reads the backup's status file: trying the run lock could
    # itself be what stops the backup.
    param(
        [Parameter(Mandatory)] [string]$StatusPath,
        [Parameter(Mandatory)] [DateTime]$CheckStartedUtc,
        [Parameter(Mandatory)] [TimeSpan]$HeadStart,
        [double]$PollSeconds = 15
    )

    $latestStartUtc = Get-LatestBackupStartUtc -StatusPath $StatusPath
    if ($null -ne $latestStartUtc -and
        ($CheckStartedUtc - $latestStartUtc) -lt [TimeSpan]::FromHours(20)) {
        return $false
    }
    [void](Wait-Until `
        -DeadlineUtc ([DateTime]::UtcNow.Add($HeadStart)) `
        -PollSeconds $PollSeconds `
        -Condition {
            $currentStartUtc = Get-LatestBackupStartUtc -StatusPath $StatusPath
            $null -ne $currentStartUtc -and
                ($null -eq $latestStartUtc -or $currentStartUtc -gt $latestStartUtc)
        })
    return $true
}

function Measure-LocalRepository {
    # The repository's file count and size, from the folder listing alone (no file is read): the native steps' deadlines
    # are sized from them. Links are not followed.
    param([Parameter(Mandatory)] [string]$Path)

    $files = 0L
    $bytes = 0L
    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push([System.IO.DirectoryInfo]::new($Path))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in $directory.EnumerateFileSystemInfos()) {
            if ($entry -is [System.IO.DirectoryInfo]) {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $pending.Push($entry)
                }
                continue
            }
            $files++
            $bytes += ([System.IO.FileInfo]$entry).Length
        }
    }
    return [pscustomobject][ordered]@{
        files = $files
        bytes = $bytes
    }
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

function Get-RunIdFromProofPath {
    # The run that holds a proof (runs\<run id>\verification-proof.json), or an empty string.
    param([AllowEmptyString()] [string]$ProofPath)

    if ([string]::IsNullOrWhiteSpace($ProofPath)) {
        return ''
    }
    $runId = Split-Path -Leaf (Split-Path -Parent $ProofPath)
    if ($runId -cmatch '^[0-9]{8}T[0-9]{9}Z-[0-9a-f]{8}$') {
        return $runId
    }
    return ''
}

function Remove-OldCheckRuns {
    # Each run keeps its proof, its native logs and its restored test file in a protected folder of its own. Only the
    # newest few are kept, with the one that holds the latest proof; the others are removed, so the folder (and the
    # permission check of all of it at the start of every run) stays small. Run IDs begin with their UTC start time, so
    # they sort by age. Anything else in the folder is left alone. Runs from before this version also kept a copy of the
    # encrypted rclone configuration, which the kept runs lose now.
    param(
        [Parameter(Mandatory)] [string]$RunsRoot,
        [Parameter(Mandatory)] [int]$Keep,
        [AllowEmptyString()] [string]$KeepRunId = ''
    )

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $RunsRoot -Force)) {
        if ($item.PSIsContainer -and
            ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and
            $item.Name -cmatch '^[0-9]{8}T[0-9]{9}Z-[0-9a-f]{8}$') {
            $names.Add($item.Name)
        }
    }
    $sorted = $names.ToArray()
    [Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    [Array]::Reverse($sorted)
    # Housekeeping never stops a check: whatever can't be removed now (a file still in use) is tried again next time.
    for ($index = 0; $index -lt $sorted.Length; $index++) {
        $runPath = Join-Path $RunsRoot $sorted[$index]
        if ($index -lt $Keep -or $sorted[$index] -ceq $KeepRunId) {
            try { Remove-RunFile -Path (Join-Path $runPath 'rclone-readonly.conf') } catch { }
            continue
        }
        try { Remove-RunFolder -Path $runPath } catch { }
    }
}

function Remove-RunFile {
    # Deletes one file of a run, read-only or not, if it is there.
    param([Parameter(Mandatory)] [string]$Path)

    $file = [System.IO.FileInfo]::new($Path)
    if (-not $file.Exists) {
        return
    }
    if (($file.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
        $file.Attributes = $file.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }
    $file.Delete()
}

function Remove-RunFolder {
    # Deletes one run's folder with everything in it. Read-only entries are made writable first; links are removed, never
    # followed.
    param([Parameter(Mandatory)] [string]$Path)

    $pending = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $pending.Push([System.IO.DirectoryInfo]::new($Path))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in $directory.EnumerateFileSystemInfos()) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                $entry.Attributes = $entry.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            }
            if ($entry -is [System.IO.DirectoryInfo]) {
                $pending.Push($entry)
            }
        }
    }
    [System.IO.Directory]::Delete($Path, $true)
}

# Every error from here on, from this script's own checks and from the native steps alike, stops the check. Once the
# folder for the failure record has been found safe (see Assert-RecordableEvidenceFolder), the check first leaves a
# record of where it stopped and why, for the dashboard. The error then ends the task as before.
trap {
    if ($null -ne $script:failureRecordTarget) {
        try {
            Write-CheckFailureRecord `
                -Target $script:failureRecordTarget `
                -Step $script:checkStep `
                -Detail $script:checkFailureDetail `
                -Message ([string]$_.Exception.Message)
        }
        catch {
            # Not even that could be written. Task Scheduler still records the task's error.
        }
    }
    break
}

$checkStartedUtc = [DateTime]::UtcNow
$checkDeadlineUtc = $checkStartedUtc.Add($checkTimeBudget)
$runId = $checkStartedUtc.ToString('yyyyMMddTHHmmssfffZ') + '-' +
    ([Guid]::NewGuid().ToString('N').Substring(0, 8))
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
$runsRoot = Join-Path $cloudVerificationRootFull 'runs'
$evidenceRoot = Join-Path $cloudVerificationRootFull 'evidence'
$latestProofPath = Join-Path $evidenceRoot 'latest-verification.json'
$failureRecordPath = Join-Path $evidenceRoot 'latest-failure.json'
if (-not $ValidateOnly) {
    Assert-RecordableEvidenceFolder `
        -Root $cloudVerificationRootFull `
        -EvidenceRoot $evidenceRoot `
        -CurrentUserSid $currentUserSid
    $script:failureRecordTarget = @{
        Path = $failureRecordPath
        CurrentUserSid = $currentUserSid
        RunId = $runId
        StartedUtc = $checkStartedUtc
        PlanId = $null
        ConfigGeneration = $null
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
if (-not $ValidateOnly) {
    Set-CheckStep 'waiting_for_google_drive'
    Wait-ForMyDriveRepository `
        -MyDriveRoot $myDriveRootFull `
        -Repository $localRepositoryFull `
        -DeadlineUtc ([DateTime]::UtcNow.Add($googleDriveWait))
    Set-CheckStep 'checking_setup'
}
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
$canaryFolderSnapshotPath = Get-CanaryFolderSnapshotPath `
    -CanaryPath $canaryReferenceFull
$canaryLeaf = Split-Path -Leaf $canaryReferenceFull

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
$backupStatusPath = Join-Path $stateDirectory 'status.json'
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
if ($null -ne $script:failureRecordTarget) {
    $script:failureRecordTarget['PlanId'] = $parsedPlanId.ToString('D')
    $script:failureRecordTarget['ConfigGeneration'] = $configGeneration
}

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

$latestProofRunId = ''
try {
    if (Test-Path -LiteralPath $latestProofPath -PathType Leaf) {
        $latestProofDocument = Read-Utf8Json -Path $latestProofPath
        if ($null -ne $latestProofDocument -and
            $latestProofDocument.PSObject.Properties.Name -contains 'immutable_proof') {
            $latestProofRunId = Get-RunIdFromProofPath `
                -ProofPath ([string]$latestProofDocument.immutable_proof)
        }
    }
}
catch {
    $latestProofRunId = ''
}
# The whole folder passed its permission check above, so nothing in an old run can be a link the task's user made.
# Housekeeping never stops a check.
try {
    Remove-OldCheckRuns `
        -RunsRoot $runsRoot `
        -Keep $previousRunsKept `
        -KeepRunId $latestProofRunId
}
catch { }

$runDirectory = Join-Path $runsRoot $runId
$restoreTarget = Join-Path $runDirectory 'restore'
[System.IO.Directory]::CreateDirectory($restoreTarget) | Out-Null
Assert-ProtectedAcl `
    -Path $runDirectory `
    -CurrentUserSid $currentUserSid
Assert-ProtectedAcl `
    -Path $restoreTarget `
    -CurrentUserSid $currentUserSid
# The children's temporary and rclone cache folders, inside this protected
# run instead of the user's own folders. Removed when the run ends.
$nativeTemporaryDirectory = Join-Path $runDirectory 'temp'
$rcloneCacheDirectory = Join-Path $runDirectory 'rclone-cache'
foreach ($directory in @($nativeTemporaryDirectory, $rcloneCacheDirectory)) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    Assert-ProtectedAcl `
        -Path $directory `
        -CurrentUserSid $currentUserSid
}
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
$rcloneVersionStdout = Join-Path $runDirectory 'rclone-version.stdout.log'
$rcloneVersionStderr = Join-Path $runDirectory 'rclone-version.stderr.log'
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

$runLock = $null
try {
    # The program that reads Google Drive must report Google Drive's SHA-256 checksums, which the inventory compares;
    # rclone does from 1.65.0 on. This is checked before anything that takes long.
    Set-CheckStep 'checking_rclone'
    $rcloneVersionEnvironment = New-NativeChildEnvironment `
        -TemporaryDirectory $nativeTemporaryDirectory `
        -Settings ([ordered]@{
            RCLONE_ASK_PASSWORD = 'false'
        })
    Invoke-RequiredNative `
        -Executable $rcloneExecutable `
        -Arguments @('version') `
        -StdoutPath $rcloneVersionStdout `
        -StderrPath $rcloneVersionStderr `
        -Environment $rcloneVersionEnvironment `
        -Operation 'The rclone version check' `
        -TimeoutSeconds (Get-NativeTimeoutSeconds -BaseSeconds 120 -CheckDeadlineUtc $checkDeadlineUtc)
    $rcloneVersionItem = Assert-NormalFile -Path $rcloneVersionStdout
    if ($rcloneVersionItem.Length -gt 64KB) {
        throw 'The rclone version output is unexpectedly large.'
    }
    $rcloneVersion = ConvertFrom-RcloneVersionText -Text (
        [System.IO.File]::ReadAllText(
            $rcloneVersionStdout,
            [System.Text.UTF8Encoding]::new($false, $false)
        )
    )
    if ($rcloneVersion -lt $minimumRcloneVersion) {
        Stop-Check `
            -Message (
                'rclone {0} is older than {1}, the first version that reports Google Drive SHA-256 checksums.' -f
                $rcloneVersion, $minimumRcloneVersion
            ) `
            -ReasonCode 'rclone_too_old' `
            -Reason (
                ("The check's copy of rclone is version {0}, but it needs {1} or later to read Google Drive's " +
                'file checksums.') -f $rcloneVersion, $minimumRcloneVersion
            ) `
            -NextStep (
                ("Set up the Google Drive check again with rclone {0} or later, as Rewindle's guide to " +
                'Google Drive describes.') -f $minimumRcloneVersion
            )
    }

    Set-CheckStep 'waiting_for_network'
    Wait-ForNetwork -DeadlineUtc ([DateTime]::UtcNow.Add($networkWait))

    Set-CheckStep 'waiting_for_backup'
    [void](Wait-ForBackupHeadStart `
        -StatusPath $backupStatusPath `
        -CheckStartedUtc $checkStartedUtc `
        -HeadStart $backupHeadStart)
    $backupWaitDeadlineUtc = [DateTime]::UtcNow.Add($backupWait)
    if ($backupWaitDeadlineUtc -gt $checkDeadlineUtc) {
        $backupWaitDeadlineUtc = $checkDeadlineUtc
    }
    $runLock = Enter-ProtectedRunLockWhenFree `
        -Path $runLockPath `
        -DeadlineUtc $backupWaitDeadlineUtc

    Set-CheckStep 'checking_latest_backup'
    $configSha256 = Get-Sha256Hex -Path $configPathFull
    if ($configSha256 -cne $preLockConfigSha256) {
        Stop-Check `
            -Message 'The protected backup configuration changed while verification acquired the run lock.' `
            -ReasonCode 'settings_changed' `
            -Reason 'Your backup settings changed while the check was waiting to start.' `
            -NextStep 'Rewindle checks again tonight.'
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
        Stop-Check `
            -Message 'The latest successful backup evidence does not match the active My Drive repository.' `
            -ReasonCode 'no_verified_backup' `
            -Reason "There's no finished, verified backup of your current backup settings yet." `
            -NextStep 'Choose Back up now, or wait for the next automatic backup. The check after it covers it.'
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
            Stop-Check `
                -Message 'The Restic repository contains a lock; cloud verification requires an idle repository.' `
                -ReasonCode 'repository_locked' `
                -Reason 'Your backup was still marked as in use, as happens when a backup stops part way.' `
                -NextStep (
                    'Choose Check recovery readiness on Protection; if it finds leftover locks, choose Repair stale ' +
                    'locks. Rewindle checks again tonight.')
        }
    }

    $powershellExecutable = Join-Path (
        [System.IO.Directory]::GetParent(
            [Environment]::SystemDirectory
        ).FullName
    ) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-NormalFile -Path $powershellExecutable | Out-Null
    # -f binds tighter than +, so the two halves are joined before -f. Without
    # these inner parentheses only the second half was formatted: rclone was
    # asked to start a program named {0}, and every check failed in seconds.
    $rclonePasswordCommand = (
        ('"{0}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-File "{1}" -CredentialPath "{2}"') -f
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
    # Restic and rclone (which Restic starts) get the settings below on top of
    # the fixed list; the inventory helper gets the fixed list alone.
    $cloudEnvironment = New-NativeChildEnvironment `
        -TemporaryDirectory $nativeTemporaryDirectory `
        -Settings ([ordered]@{
            RCLONE_CONFIG = [System.IO.Path]::GetFullPath($rcloneRunConfig)
            RCLONE_PASSWORD_COMMAND = $rclonePasswordCommand
            RCLONE_ASK_PASSWORD = 'false'
            RCLONE_CACHE_DIR = $rcloneCacheDirectory
            RESTIC_PASSWORD_COMMAND = $resticPasswordCommand
        })
    $helperEnvironment = New-NativeChildEnvironment `
        -TemporaryDirectory $nativeTemporaryDirectory
    $readOnlyRemote = Get-ReadOnlyRemoteSpec `
        -RemoteName $RemoteName `
        -RootFolderId $CloudRootFolderId

    # Each native step's deadline is sized from the repository: its file count for the Google Drive listing, its bytes
    # for the steps that read it (the inventory helper reads all of it through Google Drive for desktop, which downloads
    # it). The rates are slow on purpose, so a deadline only stops a step that is stuck.
    Set-CheckStep 'opening_local_backup'
    try {
        $localRepositorySize = Measure-LocalRepository -Path $localRepositoryFull
    }
    catch {
        # Only the deadlines are sized from this. Without it, each step may use the rest of the check's time.
        $localRepositorySize = [pscustomobject][ordered]@{
            files = 10000000L
            bytes = 1PB
        }
    }
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
        -Environment $cloudEnvironment `
        -Operation 'Local Restic repository authentication' `
        -TimeoutSeconds (Get-NativeTimeoutSeconds -BaseSeconds 900 -CheckDeadlineUtc $checkDeadlineUtc)
    $localConfig = Read-Utf8Json -Path $localCatStdout

    Set-CheckStep 'connecting_to_google_drive'
    $remoteRepository = 'rclone:' + $readOnlyRemote + ':' + $CloudRepositoryPath
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
        -Environment $cloudEnvironment `
        -Operation 'Direct-cloud Restic repository authentication' `
        -TimeoutSeconds (Get-NativeTimeoutSeconds -BaseSeconds 900 -CheckDeadlineUtc $checkDeadlineUtc)
    $cloudConfig = Read-Utf8Json -Path $cloudCatStdout

    $localRepositoryId = [string]$localConfig.id
    $cloudRepositoryId = [string]$cloudConfig.id
    if ($localRepositoryId -cnotmatch '^[0-9a-f]{64}$' -or
        $cloudRepositoryId -cnotmatch '^[0-9a-f]{64}$' -or
        $localRepositoryId -cne $cloudRepositoryId) {
        Stop-Check `
            -Message 'The local and direct-cloud Restic repository identities do not match.' `
            -ReasonCode 'repository_mismatch' `
            -Reason "The backup in Google Drive isn't the same backup as the one in the Google Drive folder on this PC." `
            -NextStep (
                'Make sure Google Drive for desktop is signed in to the Google account the check was set up with. ' +
                'If this keeps happening, choose Save problem report in Settings.')
    }
    if ($ExpectedRepositoryId -and
        $localRepositoryId -cne $ExpectedRepositoryId) {
        Stop-Check `
            -Message 'The authenticated repository does not match ExpectedRepositoryId.' `
            -ReasonCode 'repository_not_expected' `
            -Reason "The backup in your Google Drive folder isn't the one the check was set up for." `
            -NextStep "Set up the Google Drive check again, as Rewindle's guide to Google Drive describes."
    }
    if ([string]$lastSuccess.repository_id -cne $localRepositoryId) {
        Stop-Check `
            -Message 'The latest successful backup is bound to a different repository identity.' `
            -ReasonCode 'no_verified_backup' `
            -Reason "There's no finished, verified backup of your current backup settings yet." `
            -NextStep 'Choose Back up now, or wait for the next automatic backup. The check after it covers it.'
    }

    Set-CheckStep 'listing_google_drive'
    Invoke-RequiredNative `
        -Executable $rcloneExecutable `
        -Arguments @(
            'lsjson',
            ($readOnlyRemote + ':' + $CloudRepositoryPath),
            '--recursive',
            '--files-only',
            '--hash-type', 'MD5',
            '--hash-type', 'SHA-256'
        ) `
        -StdoutPath $cloudInventoryPath `
        -StderrPath $rcloneStderr `
        -Environment $cloudEnvironment `
        -Operation 'Direct Google Drive inventory' `
        -TimeoutSeconds (Get-NativeTimeoutSeconds `
            -BaseSeconds 1800 `
            -Files $localRepositorySize.files `
            -SecondsPerFile 1 `
            -CheckDeadlineUtc $checkDeadlineUtc)

    Set-CheckStep 'comparing_files'
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
        -StderrPath $inventoryHelperStderr `
        -Environment $helperEnvironment `
        -TimeoutSeconds (Get-NativeTimeoutSeconds `
            -BaseSeconds 1800 `
            -Bytes $localRepositorySize.bytes `
            -BytesPerSecond 2MB `
            -CheckDeadlineUtc $checkDeadlineUtc)
    if ($inventoryHelperExit -ne 0) {
        $category = 'inventory_verification_failed_closed'
        $categoryCount = 0L
        try {
            $helperResult = Read-Utf8Json -Path $inventoryHelperStdout
            $helperFields = @($helperResult.PSObject.Properties.Name)
            if ($helperFields -contains 'category' -and
                [string]$helperResult.category -match '^[a-z0-9_]{1,80}$') {
                $category = [string]$helperResult.category
            }
            if ($helperFields -contains 'count' -and
                ($helperResult.count -is [int] -or $helperResult.count -is [long]) -and
                [long]$helperResult.count -ge 0) {
                $categoryCount = [long]$helperResult.count
            }
        }
        catch { }
        $inventoryMessage = "Direct Google Drive inventory verification failed closed: $category."
        $inventoryDetail = Get-InventoryFailureDetail -Category $category -Count $categoryCount
        if ($null -eq $inventoryDetail) {
            throw $inventoryMessage
        }
        Stop-Check `
            -Message $inventoryMessage `
            -ReasonCode ([string]$inventoryDetail.reason_code) `
            -Reason ([string]$inventoryDetail.reason) `
            -NextStep ([string]$inventoryDetail.next_step)
    }
    $inventoryProof = Read-Utf8Json -Path $inventoryProofPath
    if ([string]$inventoryProof.state -cne 'verified' -or
        $inventoryProof.exact_file_inventory_verified -ne $true -or
        $inventoryProof.path_case_size_md5_sha256_verified -ne $true) {
        throw 'The inventory helper did not publish complete exact-match evidence.'
    }

    Set-CheckStep 'listing_cloud_backups'
    Invoke-RequiredNative `
        -Executable $resticExecutable `
        -Arguments ($resticCloudCommon + @('snapshots', '--json')) `
        -StdoutPath $snapshotStdout `
        -StderrPath $snapshotStderr `
        -Environment $cloudEnvironment `
        -Operation 'Direct-cloud Restic snapshot listing' `
        -TimeoutSeconds (Get-NativeTimeoutSeconds -BaseSeconds 1800 -CheckDeadlineUtc $checkDeadlineUtc)
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
        Stop-Check `
            -Message (
                'The latest successfully verified backup is not the latest ' +
                'snapshot in the direct-cloud repository.'
            ) `
            -ReasonCode 'latest_backup_not_in_google_drive' `
            -Reason "Google Drive doesn't have your latest backup yet." `
            -NextStep (
                'Leave this PC on with Google Drive for desktop running until it has uploaded everything. ' +
                'Rewindle checks again tonight.')
    }

    Set-CheckStep 'test_restore'
    $referenceItem = Get-Item -LiteralPath $canaryReferenceFull -Force
    $expectedCanaryBytes = [long]$referenceItem.Length
    $expectedCanarySha256 = Get-Sha256Hex -Path $canaryReferenceFull
    # Restore the canary's own folder through Restic's snapshotID:subfolder
    # selector, as the backup's canary check does, so only the canary lands in
    # the run folder. Restoring the file with --include also recreated each
    # parent folder with the source's owner and ACL: C:\ProgramData is
    # SYSTEM-owned and lets Users write, so the protected-tree check below
    # failed, and the folder it left behind failed every later run at its start.
    Invoke-RequiredNative `
        -Executable $resticExecutable `
        -Arguments ($resticCloudCommon + @(
            'restore', ($SnapshotId + ':' + $canaryFolderSnapshotPath),
            '--target', $restoreTarget,
            '--verify'
        )) `
        -StdoutPath $restoreStdout `
        -StderrPath $restoreStderr `
        -Environment $cloudEnvironment `
        -Operation 'Independent direct-cloud Restic restore' `
        -TimeoutSeconds (Get-NativeTimeoutSeconds `
            -BaseSeconds 1800 `
            -Bytes $localRepositorySize.bytes `
            -BytesPerSecond 32MB `
            -CheckDeadlineUtc $checkDeadlineUtc)

    $testRestoreMismatch = 'A test file restored from Google Drive did not match the original on this PC.'
    $testRestoreNextStep = 'Rewindle checks again tonight. If this keeps happening, choose Save problem report in Settings.'
    $restoredEntries = @(Get-ChildItem -LiteralPath $restoreTarget -Force)
    if ($restoredEntries.Count -ne 1 -or
        -not [string]::Equals(
            $restoredEntries[0].Name,
            $canaryLeaf,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        Stop-Check `
            -Message 'The direct-cloud restore must bring back the canary and nothing else.' `
            -ReasonCode 'test_restore_mismatch' `
            -Reason $testRestoreMismatch `
            -NextStep $testRestoreNextStep
    }
    $restoredCanary = Join-Path $restoreTarget $canaryLeaf
    Assert-NormalFile -Path $restoredCanary | Out-Null
    $restoredItem = Get-Item -LiteralPath $restoredCanary -Force
    $restoredSha256 = Get-Sha256Hex -Path $restoredCanary
    if ([long]$restoredItem.Length -ne $expectedCanaryBytes -or
        $restoredSha256 -cne $expectedCanarySha256) {
        Stop-Check `
            -Message 'The direct-cloud restored canary failed its length or SHA-256 check.' `
            -ReasonCode 'test_restore_mismatch' `
            -Reason $testRestoreMismatch `
            -NextStep $testRestoreNextStep
    }

    Set-CheckStep 'checking_setup'
    if ((Get-Sha256Hex -Path $configPathFull) -cne $configSha256) {
        Stop-Check `
            -Message 'The protected backup configuration changed during cloud verification.' `
            -ReasonCode 'settings_changed' `
            -Reason 'Your backup settings changed while the check was running.' `
            -NextStep 'Rewindle checks again tonight.'
    }
    [void](Read-VerifiedAssetManifest `
        -Root $cloudVerificationRootFull `
        -ExpectedUserSid $currentUserSid)
    Assert-ProtectedTree `
        -Root $cloudVerificationRootFull `
        -CurrentUserSid $currentUserSid

    Set-CheckStep 'saving_result'
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
        # The scope the check asks Google for on every call. It cannot narrow what the stored sign-in was granted when
        # it was made, and the check does not look that up, so the proof does not claim it.
        rclone_scope_requested = 'drive.readonly'
        rclone_token_scope_verified = $false
        rclone_version = $rcloneVersion.ToString()
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
    # A check that passed leaves no failure record behind (the dashboard also goes by the times, should this fail), and
    # nothing after this point is a failure of the check.
    try { Remove-CheckFailureRecord -Path $failureRecordPath } catch { }
    $script:failureRecordTarget = $null
    Write-Output $latestProofPath
}
finally {
    # Restic and rclone keep nothing there that the proof needs.
    foreach ($directory in @($nativeTemporaryDirectory, $rcloneCacheDirectory)) {
        try { [System.IO.Directory]::Delete($directory, $true) } catch { }
    }
    # The per-run copy of the encrypted rclone configuration (in which rclone may have refreshed its sign-in) is needed
    # only while rclone runs.
    try { Remove-RunFile -Path $rcloneRunConfig } catch { }
    Exit-ProtectedRunLock -Stream $runLock
}
