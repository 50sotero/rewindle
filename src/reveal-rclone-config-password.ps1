[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CredentialPath
)

# First, before any command: modules load only from Windows' own folder, never from the person's Documents folder.
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot
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
# rclone reads the password from standard output as UTF-8, up to the line break. The console's text writer would encode
# it in the console's code page instead, and a letter outside English would reach rclone as the wrong bytes. So the
# password goes out as UTF-8 bytes on the raw output stream. It is held only in arrays that are cleared afterwards,
# never in a string, which could not be cleared.
$secret = $credential.Password
$pointer = [IntPtr]::Zero
$passwordChars = $null
$passwordBytes = $null
try {
    $passwordChars = New-Object char[] $secret.Length
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
    [Runtime.InteropServices.Marshal]::Copy($pointer, $passwordChars, 0, $passwordChars.Length)
    if ($passwordChars.Length -eq 0 -or
        [Array]::IndexOf($passwordChars, [char]13) -ge 0 -or
        [Array]::IndexOf($passwordChars, [char]10) -ge 0) {
        throw 'The protected rclone configuration password is invalid.'
    }
    try {
        # Strict: a password that is not valid text stops here rather than reaching rclone changed.
        $passwordBytes = [System.Text.UTF8Encoding]::new($false, $true).GetBytes($passwordChars)
    }
    catch {
        throw 'The protected rclone configuration password is invalid.'
    }
    $standardOutput = [Console]::OpenStandardOutput()
    $standardOutput.Write($passwordBytes, 0, $passwordBytes.Length)
    $standardOutput.Write([byte[]]@(13, 10), 0, 2)
    $standardOutput.Flush()
}
finally {
    if ($null -ne $passwordBytes) {
        [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
    }
    if ($null -ne $passwordChars) {
        [Array]::Clear($passwordChars, 0, $passwordChars.Length)
    }
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $secret.Dispose()
}
