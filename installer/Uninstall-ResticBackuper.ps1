[CmdletBinding()]
param(
    [switch]$Unattended,
    [string]$ExpectedUserSid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$trustedModuleRoot = [IO.Path]::Combine([Environment]::SystemDirectory, 'WindowsPowerShell', 'v1.0', 'Modules')
$env:PSModulePath = $trustedModuleRoot

if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'ResticBackuper requires 64-bit Windows and a 64-bit Windows PowerShell process.'
}

$productName = 'ResticBackuper'
$productDisplayName = 'Rewindle'
$backupTaskName = 'ResticBackuper'
$dashboardTaskName = 'ResticBackuperDashboard'
$cloudVerificationTaskName = 'ResticBackuperGoogleDriveSync'
$primaryTaskEvidenceName = 'scheduled-task.xml'
$cloudTaskEvidenceName = 'google-drive-verification-task.xml'
$programFilesRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$systemDirectory = [Environment]::SystemDirectory
$windowsPowerShell = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\powershell.exe'
$installRoot = Join-Path $programFilesRoot $productName
$stateRoot = Join-Path $programDataRoot $productName
$cloudVerificationRoot = Join-Path (
    $programDataRoot
) 'ResticBackuperCloudVerification'
$installRegistry = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResticBackuper'
$startMenuShortcut = Join-Path $programDataRoot 'Microsoft\Windows\Start Menu\Programs\ResticBackuper.lnk'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($Value.IndexOf([char]0) -ge 0 -or $Value.Contains('"')) {
        throw 'Uninstaller arguments cannot contain a quote or NUL character.'
    }
    $trailingBackslashes = [regex]::Match($Value, '\\+$').Value
    return '"' + $Value + $trailingBackslashes + '"'
}

function Invoke-SelfElevation {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $PSCommandPath),
        '-ExpectedUserSid', (Quote-ProcessArgument $sid)
    )
    if ($Unattended) {
        $arguments += '-Unattended'
    }
    $process = Start-Process `
        -FilePath $windowsPowerShell `
        -ArgumentList $arguments `
        -Verb RunAs `
        -WindowStyle Normal `
        -Wait `
        -PassThru
    exit $process.ExitCode
}

function Get-NormalizedPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Read-Utf8Json {
    param([string]$Path)

    $text = [IO.File]::ReadAllText(
        [IO.Path]::GetFullPath($Path),
        [Text.UTF8Encoding]::new($false, $true)
    )
    return $text | ConvertFrom-Json
}

function Assert-NormalDirectory {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a normal, non-reparse directory: $Path"
    }
}

function Assert-MicrosoftSignedExecutable {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required Windows executable is missing: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') {
        throw "Required Windows executable did not pass Microsoft signature validation: $Path"
    }
}

function Import-TrustedScheduledTasksModule {
    $manifest = Join-Path $systemDirectory 'WindowsPowerShell\v1.0\Modules\ScheduledTasks\ScheduledTasks.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "The protected Windows ScheduledTasks module is missing: $manifest"
    }
    $previousVariable = Get-Variable -Name PSModuleAutoLoadingPreference -ErrorAction SilentlyContinue
    $previousAutoLoading = if ($null -eq $previousVariable) { 'All' } else { [string]$previousVariable.Value }
    try {
        $script:PSModuleAutoLoadingPreference = 'None'
        Import-Module -Name $manifest -Force -ErrorAction Stop
    }
    finally {
        $script:PSModuleAutoLoadingPreference = $previousAutoLoading
    }
}

function Assert-OwnedRuntime {
    $expected = Get-NormalizedPath (Join-Path $programFilesRoot $productName)
    $actual = Get-NormalizedPath $installRoot
    if ($actual -ne $expected) {
        throw "Refusing unexpected install path: $actual"
    }
    Assert-NormalDirectory -Path $actual

    $manifestPath = Join-Path $actual 'runtime-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The runtime manifest is missing; refusing recursive removal.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or $manifest.product -ne $productName -or $manifest.file_count -ne @($manifest.files).Count) {
        throw 'The runtime manifest is not a valid ResticBackuper manifest.'
    }

    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$allowed.Add('runtime-manifest.json')
    [void]$allowed.Add($primaryTaskEvidenceName)
    [void]$allowed.Add($cloudTaskEvidenceName)
    foreach ($entry in $manifest.files) {
        $relative = [string]$entry.relative_path
        if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..' -or -not $allowed.Add($relative)) {
            throw "The runtime manifest contains an unsafe or duplicate path: $relative"
        }
    }

    foreach ($item in Get-ChildItem -LiteralPath $actual -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "The runtime contains a reparse point; refusing recursive removal: $($item.FullName)"
        }
        if (-not $item.PSIsContainer) {
            $relative = $item.FullName.Substring($actual.Length + 1)
            if (-not $allowed.Contains($relative)) {
                throw "The runtime contains an unowned file; refusing recursive removal: $relative"
            }
        }
    }
    return $manifest
}

function Assert-OwnedTask {
    param(
        [string]$TaskName,
        [string]$ExpectedExecutable,
        [string]$ExpectedArguments = ''
    )
    $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) {
        return $null
    }
    if ($tasks.Count -ne 1) {
        throw "More than one scheduled task uses the protected name: $TaskName"
    }
    $task = $tasks[0]
    $expected = Get-NormalizedPath $ExpectedExecutable
    $actions = @($task.Actions)
    if ($actions.Count -ne 1) {
        throw "Scheduled task '$TaskName' is not owned by this installation."
    }
    $workingDirectory = Get-NormalizedPath ([Environment]::ExpandEnvironmentVariables([string]$actions[0].WorkingDirectory))
    if (
        $task.TaskPath -ne '\' -or
        (Get-NormalizedPath ([Environment]::ExpandEnvironmentVariables([string]$actions[0].Execute))) -ne $expected -or
        $workingDirectory -ne (Get-NormalizedPath $installRoot) -or
        ([string]$actions[0].Arguments) -ne $ExpectedArguments
    ) {
        throw "Scheduled task '$TaskName' is not owned by this installation."
    }
    return $task
}

function Convert-TaskPrincipalToSid {
    param([string]$UserId)

    try {
        return ([Security.Principal.SecurityIdentifier]$UserId).Value
    }
    catch {
        return ([Security.Principal.NTAccount]$UserId).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
}

function Stop-OwnedProcesses {
    param(
        [string]$ProcessName,
        [string]$ExpectedExecutable
    )
    $expected = Get-NormalizedPath $ExpectedExecutable
    $stopped = @()
    foreach ($process in Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        try {
            $actual = Get-NormalizedPath $process.MainModule.FileName
            if ($actual -eq $expected) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $stopped += $process
            }
        }
        catch [System.ComponentModel.Win32Exception] {
            throw "Could not verify process $($process.Id); refusing runtime removal."
        }
        catch [InvalidOperationException] {
            continue
        }
    }
    foreach ($process in $stopped) {
        if (-not $process.WaitForExit(10000)) {
            throw "Owned process did not exit; runtime is preserved: $ProcessName ($($process.Id))"
        }
    }
}

Assert-MicrosoftSignedExecutable -Path $windowsPowerShell

if (-not (Test-Administrator)) {
    Invoke-SelfElevation
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $identity.User.Value
if ($ExpectedUserSid -and $ExpectedUserSid -ne $currentSid) {
    throw 'Approve elevation with the same Windows account that started uninstall.'
}
Import-TrustedScheduledTasksModule

$null = Assert-OwnedRuntime
$configuration = $null
$configurationPath = Join-Path $installRoot 'backup-config.json'
if (Test-Path -LiteralPath $configurationPath -PathType Leaf) {
    try {
        $configuration = Read-Utf8Json -Path $configurationPath
    }
    catch {
        Write-Warning "Could not read display-only uninstall metadata; continuing with protected runtime ownership checks: $($_.Exception.Message)"
    }
}
$backupTask = Assert-OwnedTask `
    -TaskName $backupTaskName `
    -ExpectedExecutable (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe')
$dashboardExecutable = Join-Path $installRoot 'ResticBackuperDashboard.exe'
$dashboardArguments = '--minimized --state-dir "{0}"' -f $stateRoot
$dashboardTask = Assert-OwnedTask `
    -TaskName $dashboardTaskName `
    -ExpectedExecutable $dashboardExecutable `
    -ExpectedArguments $dashboardArguments

$cloudTask = $null
$cloudTaskCandidate = Get-ScheduledTask `
    -TaskName $cloudVerificationTaskName `
    -ErrorAction SilentlyContinue
if ($null -ne $cloudTaskCandidate) {
    if ($null -eq $configuration -or
        [string]$configuration.repository_storage_mode -cne
            'google_drivefs_stream') {
        throw 'The Google Drive verification task lacks matching protected configuration.'
    }
    $repositoryStatePath = Join-Path $stateRoot 'repository.json'
    if (-not (Test-Path -LiteralPath $repositoryStatePath -PathType Leaf)) {
        throw 'The Google Drive verification task lacks protected repository identity.'
    }
    $repositoryState = Read-Utf8Json -Path $repositoryStatePath
    $repositoryId = [string]$repositoryState.repository_id
    if ($repositoryState.schema_version -ne 1 -or
        $repositoryId -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-NormalizedPath ([string]$repositoryState.repository)) -ne
            (Get-NormalizedPath ([string]$configuration.repository))) {
        throw 'The Google Drive verification task repository identity is invalid.'
    }
    $cloudArguments = (
        '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-WindowStyle Hidden -File "' +
        (Join-Path $installRoot 'verify_my_drive_cloud_repository.ps1') +
        '" -ConfigPath "' + $configurationPath +
        '" -CloudVerificationRoot "' + $cloudVerificationRoot +
        '" -ExpectedRepositoryId "' + $repositoryId + '"'
    )
    $cloudTask = Assert-OwnedTask `
        -TaskName $cloudVerificationTaskName `
        -ExpectedExecutable $windowsPowerShell `
        -ExpectedArguments $cloudArguments
    if ($null -eq $cloudTask -or
        (Convert-TaskPrincipalToSid `
            -UserId ([string]$cloudTask.Principal.UserId)) -cne
        $currentSid) {
        throw 'The Google Drive verification task belongs to another account.'
    }
}

if (-not $Unattended) {
    Write-Host ''
    Write-Host "$productDisplayName uninstall" -ForegroundColor Cyan
    Write-Host "  App runtime : $installRoot"
    Write-Host "  Preserved   : $stateRoot"
    if ($configuration) {
        Write-Host "  Repository  : $($configuration.repository) (preserved)"
        Write-Host "  Recovery key: $($configuration.recovery_key_file) (preserved)"
    }
    $confirmation = Read-Host 'Remove the app runtime and scheduled tasks? Backup data is kept. [y/N]'
    if ($confirmation -notmatch '^(?i)y(?:es)?$') {
        throw 'Uninstall cancelled before any changes were made.'
    }
}

foreach ($task in @($cloudTask, $dashboardTask, $backupTask)) {
    if ($task -and $task.State -eq 'Running') {
        Stop-ScheduledTask -InputObject $task -ErrorAction Stop
    }
}
$stopDeadline = [DateTime]::UtcNow.AddSeconds(20)
foreach ($taskName in @(
    $cloudVerificationTaskName,
    $dashboardTaskName,
    $backupTaskName
)) {
    while ([DateTime]::UtcNow -lt $stopDeadline) {
        $currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $currentTask -or $currentTask.State -ne 'Running') {
            break
        }
        Start-Sleep -Milliseconds 250
    }
    $currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($currentTask -and $currentTask.State -eq 'Running') {
        throw "Scheduled task did not stop; runtime is preserved: $taskName"
    }
}
Stop-OwnedProcesses -ProcessName 'ResticBackuperDashboard' -ExpectedExecutable $dashboardExecutable
Stop-OwnedProcesses -ProcessName 'ResticBackuperTaskLauncher' -ExpectedExecutable (Join-Path $installRoot 'ResticBackuperTaskLauncher.exe')
foreach ($task in @($cloudTask, $dashboardTask, $backupTask)) {
    if ($task) {
        Unregister-ScheduledTask -InputObject $task -Confirm:$false
    }
}

$resolved = Get-NormalizedPath $installRoot
$expected = Get-NormalizedPath (Join-Path $programFilesRoot $productName)
if ($resolved -ne $expected) {
    throw "Install path changed during uninstall: $resolved"
}
Set-Location -LiteralPath $systemDirectory
Remove-Item -LiteralPath $resolved -Recurse -Force

if (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startMenuShortcut)
    if ((Get-NormalizedPath $shortcut.TargetPath) -eq (Get-NormalizedPath $dashboardExecutable)) {
        Remove-Item -LiteralPath $startMenuShortcut -Force
    }
    else {
        Write-Warning "Preserved a Start Menu shortcut with an unexpected target: $startMenuShortcut"
    }
}

if (Test-Path -LiteralPath $installRegistry) {
    $registration = Get-ItemProperty -LiteralPath $installRegistry
    if (($registration.DisplayName -eq $productName -or $registration.DisplayName -eq $productDisplayName) -and
        (Get-NormalizedPath ([string]$registration.InstallLocation)) -eq (Get-NormalizedPath $installRoot)) {
        Remove-Item -LiteralPath $installRegistry -Recurse -Force
    }
    else {
        Write-Warning 'Preserved an uninstall registry entry with unexpected ownership metadata.'
    }
}

Write-Host ''
Write-Host "$productDisplayName app components were removed." -ForegroundColor Green
Write-Host "Preserved backup state: $stateRoot"
if (Test-Path -LiteralPath $cloudVerificationRoot -PathType Container) {
    Write-Host "Preserved cloud verification assets/evidence: $cloudVerificationRoot"
}
if ($configuration) {
    Write-Host "Preserved repository: $($configuration.repository)"
    Write-Host "Preserved recovery key: $($configuration.recovery_key_file)"
    Write-Host "Preserved recovery tools: $($configuration.recovery_tools_directory)"
}
exit 0
