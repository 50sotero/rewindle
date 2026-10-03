[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compatibility entry point for older test runners. The former local-mirror
# workflow is retired; the authoritative coverage now verifies the protected,
# direct-My-Drive verification task.
$projectRoot = Split-Path -Parent $PSScriptRoot
$verificationTest = Join-Path (
    $PSScriptRoot
) 'Test-GoogleDriveVerificationTaskInstaller.ps1'
$resultText = (& $verificationTest | Out-String).Trim()
$result = $resultText | ConvertFrom-Json
if ($result.validation_only -ne $true -or
    $result.task_registered -ne $false -or
    $result.repository_copy_performed -ne $false -or
    $result.asset_tamper_rejected -ne $true) {
    throw 'The direct Google Drive verification-task test did not pass.'
}

$buildText = Get-Content `
    -LiteralPath (Join-Path $projectRoot 'build\Build-Release.ps1') `
    -Raw
$installerText = Get-Content `
    -LiteralPath (Join-Path $projectRoot 'installer\Install-ResticBackuper.ps1') `
    -Raw
foreach ($text in @($buildText, $installerText)) {
    foreach ($required in @(
        'verify_my_drive_cloud_repository.ps1',
        'verify_cloud_repository_inventory.py',
        'reveal-rclone-config-password.ps1',
        'install_google_drive_sync_task.ps1'
    )) {
        if ($text -notmatch [regex]::Escape($required)) {
            throw "The release pipeline omits direct-cloud payload: $required"
        }
    }
    foreach ($retired in @(
        'sync_repository_to_google_drive.ps1',
        'verify_google_drive_upload.py'
    )) {
        if ($text -match [regex]::Escape($retired)) {
            throw "The release pipeline still packages retired mirror code: $retired"
        }
    }
}

[pscustomobject]@{
    tests = [int]$result.tests + 8
    compatibility_entry_point = $true
    architecture = 'single_my_drive_repository_direct_cloud_verification'
    local_mirror_packaged = $false
    repository_copy_performed = $false
} | ConvertTo-Json -Compress
