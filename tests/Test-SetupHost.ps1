[CmdletBinding()]
param(
    # Instead of running the checks, draw Setup's native screens (the missing-runtime screen and its progress and failure states,
    # light and dark) to PNG files in this folder, for a look at them. Nothing else runs.
    [string]$RenderScreens
)

# Compiles installer\setup\*.cs, except the two files that need the WebView2 libraries and a screen (Program.cs, SetupWindow.cs) and
# the folder chooser's COM interop, together with tests\SetupHostTests.cs, and runs the result. The checks cover the installer
# contract (arguments, plan files, progress lines), the progress-file reader, ZIP unpacking, the workspace, folder measurement,
# plan mode (against a stub script, never the real installer), the install and uninstall flow (against a fake launcher, so no
# elevation), the message bridge and its validation, and the Microsoft signature check. It never starts the setup program, the
# installer, the uninstaller or Restic, and it writes only below a temporary folder of its own.
# Windows PowerShell 5.1 and the .NET Framework 4.8 compiler, as the build uses.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).TrimEnd('\')
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The .NET Framework 4.8 C# compiler is unavailable: $compiler"
}

$excluded = @('Program.cs', 'SetupWindow.cs', 'FolderPicker.cs', 'AssemblyInfo.cs')
$sources = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'installer\setup') -Filter '*.cs' -File |
        Where-Object { $excluded -notcontains $_.Name } |
        Sort-Object Name |
        ForEach-Object { $_.FullName }
)
$sources += Join-Path $projectRoot 'tests\SetupHostTests.cs'

$work = Join-Path ([IO.Path]::GetTempPath()) ('rewindle-setup-host-test-build-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $exe = Join-Path $work 'SetupHostTests.exe'
    $references = @(
        (Join-Path $framework 'System.dll'),
        (Join-Path $framework 'System.Core.dll'),
        (Join-Path $framework 'System.Web.Extensions.dll'),
        (Join-Path $framework 'System.IO.Compression.dll'),
        (Join-Path $framework 'System.IO.Compression.FileSystem.dll'),
        (Join-Path $framework 'System.Drawing.dll'),
        (Join-Path $framework 'WPF\WindowsBase.dll'),
        (Join-Path $framework 'WPF\PresentationCore.dll'),
        (Join-Path $framework 'WPF\PresentationFramework.dll'),
        (Join-Path $env:SystemRoot 'Microsoft.NET\assembly\GAC_MSIL\System.Xaml\v4.0_4.0.0.0__b77a5c561934e089\System.Xaml.dll')
    )
    $arguments = @('/nologo', '/target:exe', '/platform:x64', '/warn:4', '/codepage:65001', ('/out:' + $exe))
    foreach ($reference in $references) { $arguments += '/reference:' + $reference }
    $arguments += $sources
    & $compiler @arguments
    if ($LASTEXITCODE -ne 0) { throw "The setup host tests did not compile (exit code $LASTEXITCODE)." }

    $runArguments = @()
    if ($RenderScreens) {
        $runArguments = @('--render', [IO.Path]::GetFullPath($RenderScreens), '--icon', (Join-Path $projectRoot 'src\dashboard\assets\dashboard-icon.ico'))
    }
    & $exe @runArguments
    if ($LASTEXITCODE -ne 0) { throw "The setup host checks failed (exit code $LASTEXITCODE)." }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
