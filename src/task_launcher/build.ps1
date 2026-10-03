param(
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $project)
# The version resources come from the repository's VERSION file (see build\RewindleVersion.ps1).
. (Join-Path $projectRoot 'build\RewindleVersion.ps1')
$version = Get-RewindleVersion -ProjectRoot $projectRoot
$framework = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$outputDirectory = Join-Path $project 'dist'
$output = Join-Path $outputDirectory 'ResticBackuperTaskLauncher.exe'

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The .NET Framework C# compiler is unavailable: $compiler"
}
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

$versionSource = Write-RewindleVersionSource -Version $version -Path (Join-Path $project 'obj\AssemblyVersion.g.cs')
$arguments = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/warn:4',
    ('/out:' + $output),
    (Join-Path $project 'AssemblyInfo.cs'),
    $versionSource,
    (Join-Path $project 'Program.cs')
)
if ($Configuration -eq 'Debug') {
    $arguments += @('/debug+', '/optimize-')
}

& $compiler @arguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Task launcher compilation failed with exit code $LASTEXITCODE."
}

$item = Get-Item -LiteralPath $output
[pscustomobject]@{
    executable = $item.FullName
    bytes = $item.Length
    sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    file_version = $item.VersionInfo.FileVersion
    configuration = $Configuration
} | ConvertTo-Json -Depth 3
