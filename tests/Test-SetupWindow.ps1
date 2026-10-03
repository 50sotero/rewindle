[CmdletBinding()]
param(
    # Where the screenshots and the step log go.
    [Parameter(Mandatory = $true)][string]$Output,
    [ValidateSet('light', 'dark')][string[]]$Theme = @('light', 'dark'),
    # happy: a whole install. plan-failure: the first check of the PC fails and "Try again" goes through. install-failure: the installer
    # reports a failure part-way. declined: the first Windows prompt is declined and "Try again" goes through. all: the four.
    [ValidateSet('happy', 'plan-failure', 'install-failure', 'declined', 'all')][string[]]$Case = @('happy'),
    # The window's size in device-independent pixels.
    [double]$Width = 960,
    [double]$Height = 680,
    # Builds the wizard's web files first (npm run build:setup); otherwise the last build in src\dashboard\build-output\setup-web is used.
    [switch]$BuildWeb
)

# Opens the real Rewindle Setup window (the real web view, the real wizard bundle and the real message bridge from installer\setup) in
# front of a scripted stand-in for the installer, clicks through every screen of an install and takes a screenshot of each. It needs a
# desktop and the Microsoft Edge WebView2 Runtime, so it is for the person working on the wizard and not part of CI.
#
# It never starts the setup program, the installer, the uninstaller, Restic or the dashboard: plan mode is answered by a fake, the
# elevated launcher is a fake that only writes progress lines, the places where an installed Rewindle would be looked for are folders
# of the run's own, and the file and Save dialogs are never opened. Windows PowerShell 5.1, as the build uses.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).TrimEnd('\')
. (Join-Path $projectRoot 'build\RewindleWebView2.ps1')
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$webView = Get-RewindleWebView2Sdk -ProjectRoot $projectRoot
$web = Join-Path $projectRoot 'src\dashboard\build-output\setup-web'

if ($BuildWeb -or -not (Test-Path -LiteralPath (Join-Path $web 'setup.html'))) {
    Push-Location (Join-Path $projectRoot 'src\dashboard\web')
    try {
        & npm.cmd run build:setup
        if ($LASTEXITCODE -ne 0) { throw 'The wizard web build failed.' }
    } finally { Pop-Location }
}

$sources = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'installer\setup') -Filter '*.cs' -File |
        Where-Object { $_.Name -ne 'Program.cs' } |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
$sources += Join-Path $projectRoot 'tests\SetupWindowSmoke.cs'

$work = Join-Path ([IO.Path]::GetTempPath()) ('rewindle-setup-window-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $exe = Join-Path $work 'SetupWindowSmoke.exe'
    # The WebView2 libraries are referenced to compile against, and deliberately not copied next to the program: it has to find them the
    # way the setup program does, from the folder it unpacks them to.
    $references = @(
        $webView.WpfAssembly, $webView.CoreAssembly,
        (Join-Path $framework 'System.dll'),
        (Join-Path $framework 'System.Core.dll'),
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
    $manifest = Join-Path $projectRoot 'installer\setup\app.manifest'
    $arguments = @('/nologo', '/target:winexe', '/platform:x64', '/warn:4', '/codepage:65001', ('/out:' + $exe), ('/win32manifest:' + $manifest))
    foreach ($reference in $references) { $arguments += '/reference:' + $reference }
    $arguments += '/reference:' + (Join-Path $framework 'System.IO.Compression.FileSystem.dll')
    $arguments += $sources
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "The window test did not compile (exit code $LASTEXITCODE)." }

    # The three libraries the way the build embeds them: the managed pair and the native loader, from the pinned package.
    $libraries = Join-Path $work 'libraries'
    New-Item -ItemType Directory -Path $libraries | Out-Null
    Copy-Item -LiteralPath $webView.CoreAssembly, $webView.WpfAssembly, $webView.LoaderDll -Destination $libraries

    New-Item -ItemType Directory -Path $Output -Force | Out-Null
    $cases = if ($Case -contains 'all') { @('happy', 'plan-failure', 'install-failure', 'declined') } else { $Case }
    foreach ($caseName in $cases) {
    foreach ($name in $Theme) {
        $process = Start-Process -FilePath $exe -PassThru -Wait -ArgumentList @(
            '--web', ('"' + $web + '"'),
            '--libs', ('"' + $libraries + '"'),
            '--icon', ('"' + (Join-Path $projectRoot 'src\dashboard\assets\dashboard-icon.ico') + '"'),
            '--out', ('"' + [IO.Path]::GetFullPath($Output) + '"'),
            '--theme', $name,
            '--case', $caseName,
            '--width', $Width.ToString([Globalization.CultureInfo]::InvariantCulture),
            '--height', $Height.ToString([Globalization.CultureInfo]::InvariantCulture)
        )
        Get-Content -LiteralPath (Join-Path $Output "smoke-$caseName-$name.log") -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        if ($process.ExitCode -ne 0) { throw "The $caseName window test ($name theme) failed (exit code $($process.ExitCode))." }
    }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
