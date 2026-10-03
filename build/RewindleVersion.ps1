# The one place a build reads the release version. The repository's VERSION file is the source: the version resources of
# every binary (the dashboard, the task launcher, the setup program), the dashboard's application manifest and the version
# in src\dashboard\web\package.json follow it. Dot-source this file; it defines functions only and changes nothing.

function Get-RewindleVersion {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $path = Join-Path $ProjectRoot 'VERSION'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The VERSION file is missing: $path"
    }
    $text = (Get-Content -LiteralPath $path -Raw).Trim()
    if ($text -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$') {
        throw "VERSION is not a semantic version (major.minor.patch with an optional pre-release): '$text'"
    }
    $parts = @([long]$Matches[1], [long]$Matches[2], [long]$Matches[3], 0)
    # Windows version resources hold four numbers. The fourth is the pre-release's own number (alpha.1 is 1, rc.12 is 12),
    # and 0 for a release or a pre-release without one; the full text is kept as the informational version.
    if ($Matches[4] -and $Matches[4] -match '(\d+)$') {
        $parts[3] = [long]$Matches[1]
    }
    foreach ($part in $parts) {
        if ($part -gt 65534) {
            throw "VERSION '$text' has a number larger than a Windows version resource can hold (65534)."
        }
    }
    [pscustomobject]@{
        Text = $text
        FileVersion = ($parts -join '.')
    }
}

# Writes a C# file with the three version attributes, for the compiler to read beside the project's own AssemblyInfo.
function Write-RewindleVersionSource {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $text = @(
        '// Generated from the repository''s VERSION file by build\RewindleVersion.ps1. Do not edit; change VERSION instead.',
        'using System.Reflection;',
        '',
        ('[assembly: AssemblyVersion("{0}")]' -f $Version.FileVersion),
        ('[assembly: AssemblyFileVersion("{0}")]' -f $Version.FileVersion),
        ('[assembly: AssemblyInformationalVersion("{0}")]' -f $Version.Text),
        ''
    ) -join "`n"
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    return $Path
}

# Writes a copy of an application manifest whose assembly identity carries the version.
function Write-RewindleVersionedManifest {
    param(
        [Parameter(Mandatory = $true)]$Version,
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $source = [IO.File]::ReadAllText($Template)
    $pattern = '(<assemblyIdentity\s+version=")[^"]*(")'
    if (-not [regex]::IsMatch($source, $pattern)) {
        throw "The application manifest has no assemblyIdentity version to set: $Template"
    }
    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    $manifest = [regex]::Replace($source, $pattern, ('${1}' + $Version.FileVersion + '${2}'), 1)
    [IO.File]::WriteAllText($Path, $manifest, [Text.UTF8Encoding]::new($false))
    return $Path
}

# The version web\package.json states, read without changing anything.
function Get-RewindleWebPackageVersion {
    param([Parameter(Mandatory = $true)][string]$PackageJson)

    $package = Get-Content -LiteralPath $PackageJson -Raw | ConvertFrom-Json
    return [string]$package.version
}
