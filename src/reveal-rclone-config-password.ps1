[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CredentialPath
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

$helperPath = [System.IO.Path]::GetFullPath($PSCommandPath)
$helperItem = Get-Item -LiteralPath $helperPath -Force -ErrorAction Stop
if ($helperItem.PSIsContainer -or
    ($helperItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'The rclone password helper is not a normal protected file.'
}
$helperRoot = Split-Path -Parent $helperPath
$expectedCredentialPath = Join-Path (
    $helperRoot
) 'rclone-config-password.clixml'
$credentialPathFull = [System.IO.Path]::GetFullPath($CredentialPath)
if (-not (Test-SamePath `
        -Left $credentialPathFull `
        -Right $expectedCredentialPath)) {
    throw 'The rclone configuration credential must be beside its protected helper.'
}
$credentialItem = Get-Item `
    -LiteralPath $credentialPathFull `
    -Force `
    -ErrorAction Stop
if ($credentialItem.PSIsContainer -or
    ($credentialItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
    $credentialItem.Length -lt 1 -or
    $credentialItem.Length -gt 1MB) {
    throw 'The rclone configuration credential is not a normal protected file.'
}

$credential = Import-Clixml -LiteralPath $credentialPathFull
if ($credential -isnot [System.Management.Automation.PSCredential]) {
    throw 'The protected rclone configuration credential has an invalid type.'
}
$pointer = [IntPtr]::Zero
$plainText = $null
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $credential.Password
    )
    $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrEmpty($plainText) -or
        $plainText.IndexOfAny([char[]]@("`r", "`n")) -ge 0) {
        throw 'The protected rclone configuration password is invalid.'
    }
    [Console]::Out.WriteLine($plainText)
}
finally {
    $plainText = $null
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}
