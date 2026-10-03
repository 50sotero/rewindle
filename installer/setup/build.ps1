[CmdletBinding()]
param(
    # The release ZIP (build\Build-Release.ps1 makes it) that the setup program carries and unpacks.
    [Parameter(Mandatory = $true)][string]$BundleArchive,
    # Where the setup program is written.
    [Parameter(Mandatory = $true)][string]$Output,
    # Reuses the wizard's web build of an earlier run (src\dashboard\build-output\setup-web) instead of building it again.
    [switch]$SkipWeb
)

# Builds Rewindle Setup: the wizard's web files (src\dashboard\web, the setup.html entry), the WPF and WebView2 host in this
# folder, and one executable that embeds the release bundle, the wizard's web files and the pinned WebView2 libraries.
# Build-Release.ps1 calls this; it can also be run alone once the release ZIP exists.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = [IO.Path]::GetFullPath((Join-Path $project '..\..')).TrimEnd('\')
$webRoot = Join-Path $projectRoot 'src\dashboard\web'
$webOutput = Join-Path $projectRoot 'src\dashboard\build-output\setup-web'
$generatedDirectory = Join-Path $project 'obj'
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$icon = Join-Path $projectRoot 'src\dashboard\assets\dashboard-icon.ico'
# VERSION is the only version: this program's version resources and manifest follow it (build\RewindleVersion.ps1).
. (Join-Path $projectRoot 'build\RewindleVersion.ps1')
. (Join-Path $projectRoot 'build\RewindleWebView2.ps1')
. (Join-Path $projectRoot 'build\RewindleZip.ps1')
$version = Get-RewindleVersion -ProjectRoot $projectRoot

if (-not (Test-Path -LiteralPath $BundleArchive -PathType Leaf)) {
    throw "The release bundle to embed is missing: $BundleArchive"
}
# Paths are made absolute from PowerShell's own location: the compiler and [IO.Path] work from the process's directory, which is not it.
$bundlePath = (Resolve-Path -LiteralPath $BundleArchive).ProviderPath
$outputPath = if ([IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location).ProviderPath $Output }
$outputPath = [IO.Path]::GetFullPath($outputPath)
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The .NET Framework 4.8 C# compiler is unavailable: $compiler"
}
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) {
    throw "The application icon is unavailable: $icon"
}

# ---- the wizard's web files ---------------------------------------------------------------------------------------------------

if (-not $SkipWeb) {
    $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $npmCommand = Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nodeCommand -or -not $npmCommand) {
        throw 'Node.js 22.12 or newer, with npm on PATH, is needed to build the setup wizard. Install it from https://nodejs.org/, open a new PowerShell window and run the build again.'
    }
    Push-Location $webRoot
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $webRoot 'node_modules') -PathType Container)) {
            # --ignore-scripts, as in the dashboard's build: no dependency's install script runs on a machine that is building what
            # an elevated installer will deploy.
            & npm.cmd ci --ignore-scripts --no-audit --no-fund
            if ($LASTEXITCODE -ne 0) { throw 'The wizard web dependencies could not be installed.' }
        }
        # Type-checks the whole web project, then builds the wizard with its own Vite entry (vite.setup.config.ts), into
        # src\dashboard\build-output\setup-web. The dashboard's build has only index.html as an input, so none of this reaches it.
        & npm.cmd run build:setup
        if ($LASTEXITCODE -ne 0) { throw 'The setup wizard web build failed.' }
    } finally { Pop-Location }
}

if (-not (Test-Path -LiteralPath (Join-Path $webOutput 'setup.html') -PathType Leaf)) {
    throw "The wizard's web build is missing setup.html: $webOutput. Run this build without -SkipWeb."
}

# The sample-data bridge and its invented computers (web\src\setup\mock) are for `npm run dev:setup` and the `setup-demo` build only.
# main.tsx imports them behind a build-time constant, so the build above leaves them out; this checks the result rather than the
# source, the way the dashboard's sample data is kept out of its bundle. A single hit stops the build.
$forbidden = @(
    'rewindle-setup-sample-bridge', 'installSetupSampleBridge', 'mockSetupBridge',
    'no-second-drive', 'legacy-installed', 'uac-declined', 'key-unreadable', 'install-failure', 'plan-errors', 'unsupported-os'
)
$webFiles = @(Get-ChildItem -LiteralPath $webOutput -Recurse -File)
foreach ($file in $webFiles) {
    if ($file.Extension -in @('.map')) {
        throw "A source map is in the wizard's web bundle and would ship in the setup program: $($file.FullName)"
    }
    if ($file.Extension -in @('.js', '.css', '.html', '.svg', '.json', '.mjs')) {
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($marker in $forbidden) {
            if ($text.Contains($marker)) {
                throw "Sample data ('$marker') is in the wizard's web bundle ($($file.Name)), so it would ship in the setup program. Build it without the setup-demo mode."
            }
        }
    }
}
$htmlPages = @($webFiles | Where-Object { $_.Extension -eq '.html' })
if ($htmlPages.Count -ne 1 -or $htmlPages[0].Name -ne 'setup.html') {
    throw "The wizard's web bundle must contain setup.html and no other page; found: $(($htmlPages | ForEach-Object Name) -join ', ')"
}

# And the other direction: the dashboard's own payload must not carry any of the wizard.
$dashboardWeb = Join-Path $projectRoot 'src\dashboard\dist\web'
if (Test-Path -LiteralPath $dashboardWeb -PathType Container) {
    $leaked = @(Get-ChildItem -LiteralPath $dashboardWeb -Recurse -File | Where-Object { $_.Name -like 'setup*' })
    if ($leaked.Count -gt 0) {
        throw "Wizard files are in the dashboard's web bundle: $(($leaked | ForEach-Object Name) -join ', ')"
    }
}

New-Item -ItemType Directory -Path $generatedDirectory -Force | Out-Null
$webArchive = Join-Path $generatedDirectory 'setup-web.zip'
New-DeterministicZip -SourceDirectory $webOutput -Destination $webArchive

# ---- the compiler's inputs ----------------------------------------------------------------------------------------------------

$webView = Get-RewindleWebView2Sdk -ProjectRoot $projectRoot
$references = @(
    $webView.WpfAssembly,
    $webView.CoreAssembly,
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
foreach ($reference in $references + @($webView.LoaderDll)) {
    if (-not (Test-Path -LiteralPath $reference)) {
        throw "A required assembly or library is unavailable: $reference"
    }
}

$versionSource = Write-RewindleVersionSource -Version $version -Path (Join-Path $generatedDirectory 'AssemblyVersion.g.cs')
$manifest = Write-RewindleVersionedManifest -Version $version -Template (Join-Path $project 'app.manifest') `
    -Path (Join-Path $generatedDirectory 'app.manifest')
$sources = @(Get-ChildItem -LiteralPath $project -Filter '*.cs' -File | Sort-Object Name | ForEach-Object { $_.FullName })
if ($sources.Count -eq 0) {
    throw "Rewindle Setup's sources are missing: $project"
}

New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null

# The sources are UTF-8 without a byte-order mark and hold typographic apostrophes, so the encoding is pinned here instead of being
# left to the compiler's guess and the machine's ANSI code page.
$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/warn:4',
    '/codepage:65001',
    ('/out:' + $outputPath),
    ('/win32icon:' + $icon),
    ('/win32manifest:' + $manifest),
    # The release bundle, the wizard's pages, the application icon and the three WebView2 libraries travel inside the program and
    # are unpacked to a temporary folder when it runs (installer\setup\SetupWorkspace.cs names them the same way).
    ('/resource:' + $bundlePath + ',REWINDLE_BUNDLE'),
    ('/resource:' + $webArchive + ',REWINDLE_SETUP_WEB'),
    ('/resource:' + $icon + ',REWINDLE_ICON'),
    ('/resource:' + $webView.CoreAssembly + ',REWINDLE_WEBVIEW2_CORE'),
    ('/resource:' + $webView.WpfAssembly + ',REWINDLE_WEBVIEW2_WPF'),
    ('/resource:' + $webView.LoaderDll + ',REWINDLE_WEBVIEW2_LOADER')
)
foreach ($reference in $references) {
    $arguments += '/reference:' + $reference
}
$arguments += $versionSource
$arguments += $sources

& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "Rewindle Setup compilation failed with exit code $LASTEXITCODE."
}

$item = Get-Item -LiteralPath $outputPath
[pscustomobject]@{
    executable = $item.FullName
    bytes = $item.Length
    sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    file_version = $item.VersionInfo.FileVersion
    product_version = $item.VersionInfo.ProductVersion
    web_files = $webFiles.Count
    sources = $sources.Count
} | ConvertTo-Json -Depth 3
