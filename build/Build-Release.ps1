[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$projectRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).TrimEnd('\')
$dependenciesPath = Join-Path $projectRoot 'dependencies.json'
$versionPath = Join-Path $projectRoot 'VERSION'
$cacheRoot = Join-Path $projectRoot '.cache'
$buildOutputRoot = Join-Path $projectRoot 'build\build-output'
$bundleRoot = Join-Path $buildOutputRoot 'ResticBackuper'
$payloadRoot = Join-Path $bundleRoot 'payload'
$artifactsRoot = Join-Path $projectRoot 'artifacts'
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
# VERSION is the release's only version; the dashboard, task launcher and setup program take theirs from it too.
. (Join-Path $projectRoot 'build\RewindleVersion.ps1')

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Assert-PathWithinProject {
    param([string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    $prefix = $projectRoot + '\'
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Build path escapes the project: $candidate"
    }
    return $candidate
}

function Reset-BuildDirectory {
    $resolved = Assert-PathWithinProject $buildOutputRoot
    $expected = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\build-output'))
    if ($resolved -ne $expected) {
        throw "Unexpected build output path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
}

function Get-VerifiedArchive {
    param(
        [string]$Name,
        [string]$Url,
        [string]$ExpectedSha256
    )
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $destination = Assert-PathWithinProject (Join-Path $cacheRoot $Name)
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $partial = $destination + '.partial'
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
        try {
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
            Move-Item -LiteralPath $partial -Destination $destination
        }
        finally {
            if (Test-Path -LiteralPath $partial) {
                Remove-Item -LiteralPath $partial -Force
            }
        }
    }
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "Checksum mismatch for $Name. Expected $ExpectedSha256, observed $actual. Delete the cached file and retry only after investigating."
    }
    return $destination
}

function Copy-PayloadFile {
    param([string]$Source, [string]$RelativeDestination)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required payload source is missing: $Source"
    }
    $destination = Join-Path $payloadRoot $RelativeDestination
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $destination -Force
}

function New-PayloadManifest {
    $files = @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Force | Sort-Object FullName)
    $manifest = [ordered]@{
        schema_version = 1
        product = 'ResticBackuper'
        version = $version
        file_count = $files.Count
        files = @(
            foreach ($file in $files) {
                [ordered]@{
                    relative_path = $file.FullName.Substring($payloadRoot.Length + 1)
                    bytes = $file.Length
                    sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
    }
    Write-Utf8NoBom -Path (Join-Path $bundleRoot 'payload-manifest.json') -Text ($manifest | ConvertTo-Json -Depth 8)
    return $manifest
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
        if (-not [long]::TryParse([string]$entry.bytes, [ref]$bytes) -or $bytes -lt 0 -or $item.Length -ne $bytes -or $hash -ne [string]$entry.sha256) {
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

function New-DeterministicZip {
    param([string]$SourceDirectory, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $fixedTimestamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            foreach ($file in Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Force | Sort-Object FullName) {
                $relative = $file.FullName.Substring($SourceDirectory.Length + 1).Replace('\', '/')
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $fixedTimestamp
                $input = [IO.File]::OpenRead($file.FullName)
                $output = $entry.Open()
                try {
                    $input.CopyTo($output)
                }
                finally {
                    $output.Dispose()
                    $input.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $dependenciesPath -PathType Leaf) -or -not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw 'dependencies.json or VERSION is missing.'
}
$dependencies = Get-Content -LiteralPath $dependenciesPath -Raw | ConvertFrom-Json
$releaseVersion = Get-RewindleVersion -ProjectRoot $projectRoot
$version = $releaseVersion.Text
if ($dependencies.schema_version -ne 1 -or $version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw 'Dependency metadata or VERSION is invalid.'
}

# Every executable the release ships states the release's own version, so a stale build is never packaged.
function Assert-ReleaseBinaryVersion {
    param([string]$Path)
    $info = (Get-Item -LiteralPath $Path).VersionInfo
    if ($info.ProductVersion -cne $version -or $info.FileVersion -cne $releaseVersion.FileVersion) {
        throw ("{0} states version {1} (file {2}), not the release version {3} (file {4}) from VERSION." -f
            (Split-Path -Leaf $Path), $info.ProductVersion, $info.FileVersion, $version, $releaseVersion.FileVersion)
    }
}

$pythonArchive = Get-VerifiedArchive `
    -Name ("python-{0}-embed-amd64.zip" -f $dependencies.python.version) `
    -Url $dependencies.python.archive_url `
    -ExpectedSha256 $dependencies.python.archive_sha256
$resticArchive = Get-VerifiedArchive `
    -Name ("restic-{0}-windows-amd64.zip" -f $dependencies.restic.version) `
    -Url $dependencies.restic.archive_url `
    -ExpectedSha256 $dependencies.restic.archive_sha256

Reset-BuildDirectory
$pythonRoot = Join-Path $payloadRoot 'Python'
New-Item -ItemType Directory -Path $pythonRoot -Force | Out-Null
Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonRoot -Force
$pythonLicense = Join-Path $pythonRoot 'LICENSE.txt'
if (-not (Test-Path -LiteralPath (Join-Path $pythonRoot 'python.exe') -PathType Leaf) -or -not (Test-Path -LiteralPath $pythonLicense -PathType Leaf)) {
    throw 'Python embeddable archive did not contain python.exe and LICENSE.txt at its root.'
}

$resticExtract = Join-Path $buildOutputRoot 'restic-extract'
New-Item -ItemType Directory -Path $resticExtract -Force | Out-Null
Expand-Archive -LiteralPath $resticArchive -DestinationPath $resticExtract -Force
$resticCandidates = @(Get-ChildItem -LiteralPath $resticExtract -Recurse -Filter '*.exe' -File)
if ($resticCandidates.Count -ne 1) {
    throw "Expected exactly one executable in the Restic archive; found $($resticCandidates.Count)."
}
$resticExecutable = $resticCandidates[0].FullName
$resticHash = (Get-FileHash -LiteralPath $resticExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
if ($resticHash -ne ([string]$dependencies.restic.executable_sha256).ToLowerInvariant()) {
    throw "Restic executable checksum mismatch. Expected $($dependencies.restic.executable_sha256), observed $resticHash."
}

& (Join-Path $projectRoot 'src\task_launcher\build.ps1') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Task launcher build failed.' }
& (Join-Path $projectRoot 'src\dashboard\build.ps1') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Dashboard build failed.' }
Assert-ReleaseBinaryVersion (Join-Path $projectRoot 'src\task_launcher\dist\ResticBackuperTaskLauncher.exe')
Assert-ReleaseBinaryVersion (Join-Path $projectRoot 'src\dashboard\dist\ResticBackuperDashboard.exe')
if ((Get-RewindleWebPackageVersion -PackageJson (Join-Path $projectRoot 'src\dashboard\web\package.json')) -cne $version) {
    throw 'src\dashboard\web\package.json does not carry the version in VERSION.'
}

$dashboardOutputRoot = Join-Path $projectRoot 'src\dashboard\dist'
$dashboardAssetsManifestPath = Join-Path $dashboardOutputRoot 'dashboard-assets.json'
$dashboardAssetsManifest = Assert-DashboardAssetsManifest `
    -Root $dashboardOutputRoot `
    -ManifestPath $dashboardAssetsManifestPath

foreach ($name in @(
    'backup.py',
    'dry_run.py',
    'initialize_repository.py',
    'refresh_recovery_tools.py',
    'recovery_health.py',
    'credential_repair.py',
    'stale_lock_repair.py',
    'key_rotation.py',
    'anomaly_review.py',
    'restic_common.py',
    'restore.py',
    'secret_store.py',
    'verify_my_drive_cloud_repository.ps1',
    'verify_cloud_repository_inventory.py',
    'reveal-rclone-config-password.ps1',
    'install_google_drive_sync_task.ps1',
    'Manage-Sources.ps1',
    'Manage-Schedule.ps1',
    'Manage-Backup.ps1',
    'Manage-Repository.ps1',
    'Manage-Restore.ps1',
    # Read by the dashboard (never written) to learn that Manage-Restore.ps1 serves restore approval sessions.
    'engine-capabilities.json',
    'backup-canary.txt',
    'excludes.txt',
    'RECOVERY.md',
    'restic-release.json'
)) {
    Copy-PayloadFile -Source (Join-Path $projectRoot "src\$name") -RelativeDestination $name
}
Copy-PayloadFile -Source $resticExecutable -RelativeDestination 'restic.exe'
Copy-PayloadFile -Source (Join-Path $projectRoot 'src\task_launcher\dist\ResticBackuperTaskLauncher.exe') -RelativeDestination 'ResticBackuperTaskLauncher.exe'
Copy-PayloadFile -Source (Join-Path $projectRoot 'src\dashboard\dist\ResticBackuperDashboard.exe') -RelativeDestination 'ResticBackuperDashboard.exe'
foreach ($entry in @($dashboardAssetsManifest.files)) {
    $relative = ([string]$entry.relative_path).Replace('/', '\')
    Copy-PayloadFile `
        -Source (Join-Path $dashboardOutputRoot $relative) `
        -RelativeDestination $relative
}
Copy-PayloadFile -Source $dashboardAssetsManifestPath -RelativeDestination 'dashboard-assets.json'
Copy-PayloadFile -Source (Join-Path $projectRoot 'installer\Uninstall-ResticBackuper.ps1') -RelativeDestination 'Uninstall-ResticBackuper.ps1'
Copy-PayloadFile -Source $versionPath -RelativeDestination 'VERSION'
Copy-PayloadFile -Source (Join-Path $projectRoot 'LICENSE') -RelativeDestination 'LICENSE'
Copy-PayloadFile -Source (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') -RelativeDestination 'THIRD_PARTY_NOTICES.md'
Copy-PayloadFile -Source $dependenciesPath -RelativeDestination 'dependencies.json'
Copy-PayloadFile -Source (Join-Path $projectRoot 'licenses\RESTIC.txt') -RelativeDestination 'licenses\RESTIC.txt'
Copy-PayloadFile -Source $pythonLicense -RelativeDestination 'licenses\PYTHON.txt'

foreach ($name in @('Install.cmd', 'Install-ResticBackuper.ps1')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot "installer\$name") -Destination (Join-Path $bundleRoot $name) -Force
}
foreach ($name in @('README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'dependencies.json', 'VERSION')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $bundleRoot $name) -Force
}
$bundleLicenses = Join-Path $bundleRoot 'licenses'
New-Item -ItemType Directory -Path $bundleLicenses -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'licenses\RESTIC.txt') `
    -Destination (Join-Path $bundleLicenses 'RESTIC.txt') -Force
Copy-Item -LiteralPath $pythonLicense `
    -Destination (Join-Path $bundleLicenses 'PYTHON.txt') -Force
$manifest = New-PayloadManifest

$dashboardExecutablePath = Join-Path $payloadRoot 'ResticBackuperDashboard.exe'
$dashboardExecutableSha256 = (Get-FileHash -LiteralPath $dashboardExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
$dashboardAssetsManifestSha256 = (Get-FileHash -LiteralPath (Join-Path $payloadRoot 'dashboard-assets.json') -Algorithm SHA256).Hash.ToLowerInvariant()
$bundleId = 'Rewindle/{0}/{1}/{2}' -f $version, $dashboardExecutableSha256, $dashboardAssetsManifestSha256

$buildInfo = [ordered]@{
    schema_version = 1
    product = 'ResticBackuper'
    version = $version
    bundle_id = $bundleId
    platform = 'windows-x64'
    dashboard = [ordered]@{
        executable = 'ResticBackuperDashboard.exe'
        executable_sha256 = $dashboardExecutableSha256
        assets_manifest = 'dashboard-assets.json'
        assets_manifest_sha256 = $dashboardAssetsManifestSha256
    }
    python = [ordered]@{
        version = [string]$dependencies.python.version
        archive_sha256 = [string]$dependencies.python.archive_sha256
    }
    restic = [ordered]@{
        version = [string]$dependencies.restic.version
        archive_sha256 = [string]$dependencies.restic.archive_sha256
        executable_sha256 = [string]$dependencies.restic.executable_sha256
    }
    payload_file_count = $manifest.file_count
}
Write-Utf8NoBom -Path (Join-Path $bundleRoot 'BUILD-INFO.json') -Text ($buildInfo | ConvertTo-Json -Depth 6)

New-Item -ItemType Directory -Path $artifactsRoot -Force | Out-Null
$artifactName = "Rewindle-v$version-windows-x64.zip"
$artifactPath = Assert-PathWithinProject (Join-Path $artifactsRoot $artifactName)
New-DeterministicZip -SourceDirectory $bundleRoot -Destination $artifactPath
$artifactHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = $artifactPath + '.sha256'
Write-Utf8NoBom -Path $checksumPath -Text ("$artifactHash *$artifactName`n")

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The .NET Framework 4.8 C# compiler is unavailable: $compiler"
}
$setupArtifactName = "Rewindle-v$version-windows-x64-setup.exe"
$setupArtifactPath = Assert-PathWithinProject (Join-Path $artifactsRoot $setupArtifactName)
$setupSource = Join-Path $projectRoot 'installer\RewindleSetup.cs'
$setupIcon = Join-Path $projectRoot 'src\dashboard\assets\dashboard-icon.ico'
$setupArguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    ('/out:' + $setupArtifactPath),
    ('/reference:' + (Join-Path $framework 'System.dll')),
    ('/reference:' + (Join-Path $framework 'System.IO.Compression.dll')),
    ('/reference:' + (Join-Path $framework 'System.IO.Compression.FileSystem.dll')),
    ('/reference:' + (Join-Path $framework 'System.Windows.Forms.dll')),
    ('/resource:' + $artifactPath + ',REWINDLE_BUNDLE')
)
if (Test-Path -LiteralPath $setupIcon -PathType Leaf) {
    $setupArguments += '/win32icon:' + $setupIcon
}
$setupVersionSource = Write-RewindleVersionSource -Version $releaseVersion `
    -Path (Assert-PathWithinProject (Join-Path $buildOutputRoot 'RewindleSetup.Version.g.cs'))
$setupArguments += $setupVersionSource
$setupArguments += $setupSource
& $compiler @setupArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setupArtifactPath -PathType Leaf)) {
    throw "Rewindle setup compilation failed with exit code $LASTEXITCODE."
}
Assert-ReleaseBinaryVersion $setupArtifactPath
$setupHash = (Get-FileHash -LiteralPath $setupArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
$setupChecksumPath = $setupArtifactPath + '.sha256'
Write-Utf8NoBom -Path $setupChecksumPath -Text ("$setupHash *$setupArtifactName`n")

[pscustomobject]@{
    version = $version
    artifact = $artifactPath
    bytes = (Get-Item -LiteralPath $artifactPath).Length
    sha256 = $artifactHash
    checksum_file = $checksumPath
    setup_artifact = $setupArtifactPath
    setup_bytes = (Get-Item -LiteralPath $setupArtifactPath).Length
    setup_sha256 = $setupHash
    setup_checksum_file = $setupChecksumPath
    payload_files = $manifest.file_count
    restic_version = [string]$dependencies.restic.version
    python_version = [string]$dependencies.python.version
} | ConvertTo-Json -Depth 5
