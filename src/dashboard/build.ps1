param(
    [string]$Configuration = 'Release',
    [switch]$SkipWeb
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $project)
# The repository's VERSION file is the only version: the executable's version resources, its manifest and web\package.json
# follow it (see build\RewindleVersion.ps1).
. (Join-Path $projectRoot 'build\RewindleVersion.ps1')
. (Join-Path $projectRoot 'build\RewindleWebView2.ps1')
$version = Get-RewindleVersion -ProjectRoot $projectRoot
$generatedDirectory = Join-Path $project 'obj'
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$outputDirectory = Join-Path $project 'dist'
# The name the release build (build\Build-Release.ps1), the installer and the uninstaller expect.
$output = Join-Path $outputDirectory 'ResticBackuperDashboard.exe'
$icon = Join-Path $project 'assets\dashboard-icon.ico'

# Node.js bundles the interface and npm reads its dependency license notices, so both must be here before anything is downloaded or
# compiled. The accepted versions are the range web\package.json declares, which is Vite 7's own.
$nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$npmCommand = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeCommand -or -not $npmCommand) {
    throw 'Node.js 22.12 or newer, with npm on PATH, is needed to build the dashboard interface. Install it from https://nodejs.org/, open a new PowerShell window and run build.ps1 again. The README lists the requirements.'
}
if (-not $SkipWeb) {
    $nodeVersionText = [string](& $nodeCommand.Source --version | Select-Object -First 1)
    $nodeVersion = $null
    if ($nodeVersionText -match '^v(\d+\.\d+\.\d+)') { $nodeVersion = [version]$Matches[1] }
    if (-not $nodeVersion -or -not (($nodeVersion -ge [version]'22.12.0') -or ($nodeVersion.Major -eq 20 -and $nodeVersion -ge [version]'20.19.0'))) {
        throw "Node.js 22.12 or newer (or 20.19 and later 20.x) is needed to build the dashboard interface, and this PowerShell found '$nodeVersionText'. Install the current LTS from https://nodejs.org/, open a new PowerShell window and run build.ps1 again."
    }
}

# The pinned WebView2 SDK, shared with Rewindle Setup (build\RewindleWebView2.ps1): fetched and hash-checked here when it is not unpacked yet.
$webView = Get-RewindleWebView2Sdk -ProjectRoot $projectRoot
$webViewPackage = $webView.PackageRoot
$webViewAssembly = $webView.WpfAssembly

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "The .NET Framework 4.8 C# compiler is unavailable: $compiler"
}
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) {
    throw "The dashboard application icon is unavailable: $icon"
}
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

if ($SkipWeb) {
    # -SkipWeb reuses the web build and the installed dependencies of an earlier run; the license notices below are read from them.
    if (-not (Test-Path -LiteralPath (Join-Path $outputDirectory 'web\index.html') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $project 'web\node_modules') -PathType Container)) {
        throw 'The -SkipWeb switch reuses an earlier web build, and there is none here (dist\web\index.html or web\node_modules is missing). Run build.ps1 once without -SkipWeb.'
    }
} else {
    Push-Location (Join-Path $project 'web')
    try {
        # web\package.json (and its lockfile) carry the version from VERSION. A VERSION that was changed by hand is copied into
        # both here, with npm's own command so the lockfile stays consistent; commit the two files with the new VERSION.
        if ((Get-RewindleWebPackageVersion -PackageJson (Join-Path $project 'web\package.json')) -cne $version.Text) {
            & npm.cmd version $version.Text --no-git-tag-version --allow-same-version --ignore-scripts | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'The dashboard web package version could not be set from VERSION.' }
        }
        # --ignore-scripts: nothing in the lockfile needs an install script to build (esbuild runs from the platform package npm installs
        # beside it), so no dependency's script runs on a machine that is building what an elevated installer will deploy.
        & npm.cmd ci --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Dashboard web dependencies could not be installed.' }
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw 'Dashboard web build failed.' }
    } finally { Pop-Location }
}

$references = @(
    $webViewAssembly,
    (Join-Path $webViewPackage 'lib\net462\Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $framework 'System.dll'),
    (Join-Path $framework 'System.Core.dll'),
    (Join-Path $framework 'System.Xml.dll'),
    (Join-Path $framework 'System.Web.Extensions.dll'),
    (Join-Path $framework 'System.IO.Compression.dll'),
    (Join-Path $framework 'System.IO.Compression.FileSystem.dll'),
    (Join-Path $framework 'System.Drawing.dll'),
    (Join-Path $framework 'System.Windows.Forms.dll'),
    (Join-Path $framework 'WPF\WindowsBase.dll'),
    (Join-Path $framework 'WPF\PresentationCore.dll'),
    (Join-Path $framework 'WPF\PresentationFramework.dll'),
    (Join-Path $env:SystemRoot 'Microsoft.NET\assembly\GAC_MSIL\System.Xaml\v4.0_4.0.0.0__b77a5c561934e089\System.Xaml.dll')
)
foreach ($reference in $references) {
    if (-not (Test-Path -LiteralPath $reference)) {
        throw "Required .NET Framework assembly is unavailable: $reference"
    }
}

$versionSource = Write-RewindleVersionSource -Version $version -Path (Join-Path $generatedDirectory 'AssemblyVersion.g.cs')
$manifest = Write-RewindleVersionedManifest -Version $version -Template (Join-Path $project 'app.manifest') `
    -Path (Join-Path $generatedDirectory 'app.manifest')
$sources = @(
    (Join-Path $project 'AssemblyInfo.cs'),
    $versionSource,
    (Join-Path $project 'AtomicFile.cs'),
    (Join-Path $project 'EngineProfile.cs'),
    (Join-Path $project 'CrashLog.cs'),
    (Join-Path $project 'Program.cs'),
    (Join-Path $project 'SourceConfiguration.cs'),
    (Join-Path $project 'RepositoryManager.cs'),
    (Join-Path $project 'RepositoryLocationWindow.cs'),
    (Join-Path $project 'RestoreManager.cs'),
    (Join-Path $project 'RestoreWindow.cs'),
    (Join-Path $project 'RecoveryHealthManager.cs'),
    (Join-Path $project 'RecoveryReadinessWindow.cs'),
    (Join-Path $project 'RunDetailsWindow.cs'),
    (Join-Path $project 'DiagnosticExporter.cs'),
    (Join-Path $project 'Telemetry.cs'),
    (Join-Path $project 'TaskSchedule.cs'),
    (Join-Path $project 'BackupFreshness.cs'),
    (Join-Path $project 'ScheduleManagerLauncher.cs'),
    (Join-Path $project 'ScheduleEditorWindow.cs'),
    (Join-Path $project 'BackupTaskController.cs'),
    (Join-Path $project 'BackupCancellationController.cs'),
    (Join-Path $project 'DashboardTheme.cs'),
    (Join-Path $project 'DashboardMotion.cs'),
    (Join-Path $project 'DashboardVisualStyle.cs'),
    (Join-Path $project 'RunChart.cs'),
    (Join-Path $project 'DashboardWindow.cs'),
    (Join-Path $project 'DashboardWindow.SourcePicker.cs'),
    (Join-Path $project 'DashboardWindow.RestoreFlow.cs'),
    (Join-Path $project 'DashboardWindow.Web.cs')
)
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Dashboard source file is unavailable: $source"
    }
}

# The sources are UTF-8 without a byte-order mark and some hold non-ASCII text (check marks, ellipses, bullets), so the encoding is
# pinned here instead of being left to the compiler's guess and the machine's ANSI code page.
$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/warn:4',
    '/codepage:65001',
    ('/out:' + $output),
    ('/win32icon:' + $icon),
    ('/win32manifest:' + $manifest)
)
if ($Configuration -eq 'Debug') {
    $arguments += @('/debug+', '/optimize-')
}
foreach ($reference in $references) {
    $arguments += '/reference:' + $reference
}
$arguments += $sources

& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) {
    throw "Dashboard compilation failed with exit code $LASTEXITCODE."
}

$item = Get-Item -LiteralPath $output
Copy-Item -LiteralPath $webViewAssembly -Destination $outputDirectory -Force
Copy-Item -LiteralPath (Join-Path $webViewPackage 'lib\net462\Microsoft.Web.WebView2.Core.dll') -Destination $outputDirectory -Force
Copy-Item -LiteralPath (Join-Path $webViewPackage 'runtimes\win-x64\native\WebView2Loader.dll') -Destination $outputDirectory -Force
$licenseDirectory = Join-Path $outputDirectory 'licenses'
# Rebuilt from nothing every time, so the notice of a dependency that has since been removed does not stay in the bundle or in its manifest.
if (Test-Path -LiteralPath $licenseDirectory) { Remove-Item -LiteralPath $licenseDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $licenseDirectory -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $project 'web\vendor\BEAUTIFULUI-MIT-LICENSE.txt') -Destination $licenseDirectory -Force
Copy-Item -LiteralPath (Join-Path $webViewPackage 'LICENSE.txt') -Destination (Join-Path $licenseDirectory 'WebView2-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $webViewPackage 'NOTICE.txt') -Destination (Join-Path $licenseDirectory 'WebView2-NOTICE.txt') -Force
Push-Location (Join-Path $project 'web')
try {
    $dependencyDirectories = & npm.cmd ls --omit=dev --all --parseable
    if ($LASTEXITCODE -ne 0) { throw 'Could not collect web dependency license notices.' }
} finally { Pop-Location }
$modulesPrefix = [IO.Path]::GetFullPath((Join-Path $project 'web\node_modules')) + '\'
# A runtime package that really ships no license file would be listed here (its folder under web\node_modules, with the reason) once it has
# been checked by hand. None is today, so a package that stops shipping one after an update stops the build instead of leaving the bundle short.
$noticeFileExceptions = @{}
$noticePattern = '^(LICEN[CS]E|NOTICE|COPYING|COPYRIGHT|OFL)([-._].*)?$'
foreach ($dependencyDirectory in $dependencyDirectories) {
    if (-not $dependencyDirectory.StartsWith($modulesPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $packageName = $dependencyDirectory.Substring($modulesPrefix.Length)
    $notices = @(Get-ChildItem -LiteralPath $dependencyDirectory -File | Where-Object { $_.Name -match $noticePattern })
    if ($notices.Count -eq 0 -and -not $noticeFileExceptions.ContainsKey($packageName)) {
        $licenseNote = 'its package.json could not be read'
        try {
            $packageInfo = Get-Content -LiteralPath (Join-Path $dependencyDirectory 'package.json') -Raw | ConvertFrom-Json
            $declaredLicense = $packageInfo.license
            if ($declaredLicense -isnot [string]) { $declaredLicense = $packageInfo.license.type }
            $licenseNote = 'its package.json license field: ' + $(if ($declaredLicense) { $declaredLicense } else { 'none declared' })
        } catch { }
        throw ("The web dependency '{0}' ships no license file ({1}), so there is no notice to put in dist\licenses. Check how it is licensed and bundle its notice by hand, or add it to the exceptions list in build.ps1 with the reason." -f $packageName, $licenseNote)
    }
    foreach ($notice in $notices) {
        $noticeDestination = Join-Path $licenseDirectory ('web-dependencies\' + $packageName)
        New-Item -ItemType Directory -Path $noticeDestination -Force | Out-Null
        Copy-Item -LiteralPath $notice.FullName -Destination $noticeDestination -Force
    }
}
$assetFiles = @(
    foreach ($assetFolder in @('web', 'licenses')) {
        Get-ChildItem -LiteralPath (Join-Path $outputDirectory $assetFolder) -File -Recurse
    }
    foreach ($assetName in @('Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll')) {
        Get-Item -LiteralPath (Join-Path $outputDirectory $assetName)
    }
)
$assetManifest = [ordered]@{
    schema_version = 1
    files = @($assetFiles | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            relative_path = $_.FullName.Substring($outputDirectory.Length + 1).Replace('\', '/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
}
$assetManifestPath = Join-Path $outputDirectory 'dashboard-assets.json'
[IO.File]::WriteAllText($assetManifestPath, ($assetManifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    executable = $item.FullName
    bytes = $item.Length
    sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    file_version = $item.VersionInfo.FileVersion
    product_version = $item.VersionInfo.ProductVersion
    configuration = $Configuration
    assets_manifest = $assetManifestPath
    assets_manifest_sha256 = (Get-FileHash -LiteralPath $assetManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 3
