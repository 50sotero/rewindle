[CmdletBinding()]
param(
    [switch]$AllowSystemInstall,
    [string]$Artifact
)

if ($env:GITHUB_ACTIONS -ne 'true') {
    throw 'This script performs a real installation and uninstallation. It runs only on a GitHub Actions runner, never on a developer machine.'
}
if ($env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This script runs only on a GitHub-hosted runner (RUNNER_ENVIRONMENT=github-hosted), which is a disposable machine.'
}
if (-not $AllowSystemInstall) {
    throw 'Pass -AllowSystemInstall to confirm that this disposable CI machine may be changed.'
}

# End-to-end test of the installer's machine-readable backend (docs/setup-contract.md) on the disposable hosted runner:
#   1. plan mode, run as a standard (non-administrator) account;
#   2. refused and failing installs, which must leave nothing behind and still end with a result line;
#   3. two complete cycles, each a real unattended install with a progress feed, run as a test administrator named by
#      -ExpectedUserSid, then an uninstall with a progress feed and a check that the machine is clean (only the data an
#      uninstall keeps remains). The first cycle installs the dashboard and also covers a refused second install, the recovery
#      key checks and a refused second uninstall; the second runs with -SkipDashboard to cover the skipped phases.
# It needs the release the build step produced. Hosted runners run every step as an administrator with UAC off, so the test
# accounts are real local users started through the secondary-logon service, the same pattern as the restore-manager step.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$projectRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).TrimEnd('\')
$version = (Get-Content -LiteralPath (Join-Path $projectRoot 'VERSION') -Raw).Trim()
if (-not $Artifact) { $Artifact = Join-Path $projectRoot "artifacts\Rewindle-v$version-windows-x64.zip" }
if (-not (Test-Path -LiteralPath $Artifact -PathType Leaf)) { throw "Release artifact is missing: $Artifact" }
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$administratorRole = [Security.Principal.WindowsBuiltInRole]::Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole($administratorRole)) {
    throw 'The hosted runner is expected to run this step as an administrator.'
}

$programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
$programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$installRoot = Join-Path $programFiles 'ResticBackuper'
$stateRoot = Join-Path $programData 'ResticBackuper'
$cloudToolsRoot = Join-Path $programData 'ResticBackuperRecoveryTools'
$shortcutPath = Join-Path $programData 'Microsoft\Windows\Start Menu\Programs\ResticBackuper.lnk'
$registryKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ResticBackuper'
$taskNames = @('ResticBackuper', 'ResticBackuperDashboard', 'ResticBackuperGoogleDriveSync')
# The phases of an install in the order the script emits them (docs/setup-contract.md, section 3.3).
$installPhaseOrder = @('preflight', 'webview2', 'payload', 'canary', 'credential', 'repository', 'recovery_key', 'permissions', 'tasks', 'dashboard', 'verification', 'first_backup')
$uninstallPhaseOrder = @('preflight', 'stop', 'tasks', 'program_files', 'shortcut', 'registration', 'verification')

# What of a Rewindle installation exists on this machine (an empty list means none).
function Get-InstallationFootprint {
    $found = @()
    foreach ($path in @($installRoot, $stateRoot, $cloudToolsRoot, $shortcutPath)) {
        if (Test-Path -LiteralPath $path) { $found += $path }
    }
    if (Test-Path -LiteralPath $registryKey) { $found += $registryKey }
    foreach ($name in $taskNames) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { $found += "task $name" }
    }
    return $found
}

$existing = @(Get-InstallationFootprint)
if ($existing.Count -gt 0) {
    throw "Refusing to run: Rewindle is already present on this machine ($($existing -join '; ')). This test only runs on a clean disposable runner."
}

$root = 'C:\rewindle-contract'
if (Test-Path -LiteralPath $root) { throw "Refusing to run: $root already exists." }
$bundle = Join-Path $root 'bundle'
$scripts = Join-Path $root 'scripts'
$logs = Join-Path $root 'logs'
$handoff = Join-Path $root 'handoff'
$docs = Join-Path $root 'sources\docs'
$photos = Join-Path $root 'sources\photos'
$planRepository = Join-Path $root 'plan-only\Backup'
$assertions = 0
$createdUsers = @()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw "FAILED: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $script:assertions++
    $expectedText = (@($Expected) | ForEach-Object { [string]$_ }) -join '|'
    $actualText = (@($Actual) | ForEach-Object { [string]$_ }) -join '|'
    if ($expectedText -cne $actualText) { throw "FAILED: $Message (expected '$expectedText', got '$actualText')" }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title"
}

function Grant-Access {
    param([string]$Path, [string]$User, [string]$Rights)
    & icacls.exe $Path /grant ('{0}:(OI)(CI){1}' -f $User, $Rights) /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant $User access to $Path." }
}

function New-TestUser {
    param([string]$Name, [switch]$Administrator)
    $password = 'Rw!' + [Guid]::NewGuid().ToString('N') + 'a9'
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    # New-LocalUser never prompts. BUILTIN\Users holds the local logon right the secondary-logon service needs.
    New-LocalUser -Name $Name -Password $secure -PasswordNeverExpires -AccountNeverExpires | Out-Null
    $script:createdUsers += $Name
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $Name
    if ($Administrator) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $Name }
    return [pscustomobject]@{
        Name = $Name
        Sid = (Get-LocalUser -Name $Name).SID.Value
        Credential = (New-Object System.Management.Automation.PSCredential($Name, $secure))
        # Only for registering the one-off tasks of Invoke-AsUserElevated; the account is deleted at the end of the test.
        Password = $password
    }
}

function ConvertTo-LiteralList {
    param([string[]]$Values)
    return (($Values | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', ')
}

# Runs a script as a test user and waits for it. The script body is a template: {{NAME}} markers are replaced by the values.
function Invoke-AsUser {
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template,
        [hashtable]$Values = @{},
        [int]$TimeoutSeconds = 1200
    )
    $body = $Template
    foreach ($key in $Values.Keys) { $body = $body.Replace('{{' + $key + '}}', [string]$Values[$key]) }
    $scriptPath = Join-Path $scripts "$Name.ps1"
    [IO.File]::WriteAllText($scriptPath, $body, [Text.UTF8Encoding]::new($true))
    $stdout = Join-Path $logs "$Name.stdout.log"
    $stderr = Join-Path $logs "$Name.stderr.log"
    $process = Start-Process -FilePath $windowsPowerShell `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath `
        -Credential $User.Credential -LoadUserProfile -WorkingDirectory $root `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "$Name did not finish within $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    return [pscustomobject]@{
        Name = $Name
        ExitCode = [int]$process.ExitCode
        Stdout = $(if (Test-Path -LiteralPath $stdout) { [IO.File]::ReadAllText($stdout) } else { '' })
        Stderr = $(if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr) } else { '' })
    }
}

# Runs a script as a test user with that user's full (elevated) token and waits for it. Hosted runners keep User Account
# Control on, so a process started with the user's credentials (Invoke-AsUser) gets the filtered token, as the setup wizard does.
# A task registered with the user's password at the highest run level gets the full token without a prompt: the token the
# person approves in Windows' prompt, which the installer needs (it must run as the account that started setup).
function Invoke-AsUserElevated {
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template,
        [hashtable]$Values = @{},
        [int]$TimeoutSeconds = 1200
    )
    $body = $Template
    foreach ($key in $Values.Keys) { $body = $body.Replace('{{' + $key + '}}', [string]$Values[$key]) }
    $scriptPath = Join-Path $scripts "$Name.ps1"
    [IO.File]::WriteAllText($scriptPath, $body, [Text.UTF8Encoding]::new($true))
    $stdout = Join-Path $logs "$Name.stdout.log"
    $stderr = Join-Path $logs "$Name.stderr.log"
    $exitPath = Join-Path $logs "$Name.exit.txt"
    $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    # The task has no console to read, so the wrapper redirects the streams and always leaves the exit code in a file.
    $command = @(
        '$code = 1'
        ('try {{ & {0} 1> {1} 2> {2}; $code = if ($LASTEXITCODE -is [int]) {{ $LASTEXITCODE }} else {{ 0 }} }}' -f (& $quote $scriptPath), (& $quote $stdout), (& $quote $stderr))
        ('catch {{ [IO.File]::AppendAllText({0}, ($_ | Out-String)); $code = 1 }}' -f (& $quote $stderr))
        ('finally {{ [IO.File]::WriteAllText({0}, [string]$code) }}' -f (& $quote $exitPath))
        'exit $code'
    ) -join [Environment]::NewLine
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $taskName = 'RewindleContract-' + $Name + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -WorkingDirectory $root
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds ($TimeoutSeconds + 120))
    Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User $User.Name -Password $User.Password -RunLevel Highest | Out-Null
    try {
        $started = [DateTime]::UtcNow
        Start-ScheduledTask -TaskName $taskName
        while (-not (Test-Path -LiteralPath $exitPath)) {
            if (([DateTime]::UtcNow - $started).TotalSeconds -gt $TimeoutSeconds) {
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                throw "$Name did not finish within $TimeoutSeconds seconds."
            }
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            # 267009: running; 267011: not run yet. Anything else with no exit file means the task could not start the script.
            if (([DateTime]::UtcNow - $started).TotalSeconds -gt 15 -and (Test-Path -LiteralPath $exitPath) -eq $false -and
                $info.LastTaskResult -notin @(0, 267009, 267011) -and (Get-ScheduledTask -TaskName $taskName).State -ne 'Running') {
                throw "$Name could not be started as $($User.Name) (task result 0x$('{0:X8}' -f $info.LastTaskResult))."
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Name = $Name
        ExitCode = [int]([IO.File]::ReadAllText($exitPath).Trim())
        Stdout = $(if (Test-Path -LiteralPath $stdout) { [IO.File]::ReadAllText($stdout) } else { '' })
        Stderr = $(if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr) } else { '' })
    }
}

function Show-Run {
    param($Run)
    Write-Host "--- $($Run.Name): exit code $($Run.ExitCode)"
    if ($Run.Stdout.Trim()) { Write-Host '--- stdout'; Write-Host $Run.Stdout }
    if ($Run.Stderr.Trim()) { Write-Host '--- stderr'; Write-Host $Run.Stderr }
}

# A file the wrapper wrote to tell this script where the user's progress or plan file is.
function Get-HandoffPath {
    param([string]$Name)
    $path = Join-Path $handoff $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "The wrapper did not report where it put its file ($Name)." }
    return ([IO.File]::ReadAllText($path)).Trim()
}

# Parses a progress feed and checks the envelope every line must have.
function Read-ProgressFeed {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "the progress feed exists ($Path)"
    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'the feed has no byte-order mark'
    $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
    Assert-True ($text.Length -gt 0 -and $text.EndsWith("`n")) 'the feed ends with a line feed'
    $lines = @()
    $previousTime = [DateTime]::MinValue
    $sequence = 0
    foreach ($line in ($text.TrimEnd("`n") -split "`n")) {
        $entry = $line | ConvertFrom-Json
        $sequence++
        Assert-Equal 'Rewindle.InstallProgress.v1' $entry.schema "line $sequence has the schema id"
        Assert-Equal $sequence $entry.seq "line $sequence carries the next sequence number"
        Assert-True ($entry.time -cmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$') "line $sequence has an ISO-8601 UTC time ($($entry.time))"
        $stamp = [DateTime]::ParseExact($entry.time, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
        Assert-True ($stamp -ge $previousTime) "line $sequence is not earlier than the line before"
        $previousTime = $stamp
        Assert-True (@('phase', 'result') -contains $entry.type) "line $sequence has a known type"
        $lines += $entry
    }
    Assert-Equal 'result' $lines[$lines.Count - 1].type 'the last line is the result'
    Assert-Equal 1 @($lines | Where-Object { $_.type -eq 'result' }).Count 'there is exactly one result line'
    return $lines
}

function Get-PhaseSequence {
    param($Lines)
    return @($Lines | Where-Object { $_.type -eq 'phase' } | ForEach-Object { '{0}:{1}' -f $_.phase, $_.state })
}

# The phase lines a complete run must produce: every phase in order, started then completed, except those that are skipped.
function Get-ExpectedSequence {
    param([string[]]$Order, [string[]]$Skipped = @())
    $sequence = @()
    foreach ($phase in $Order) {
        if ($Skipped -contains $phase) { $sequence += "${phase}:skipped" }
        else { $sequence += "${phase}:started", "${phase}:completed" }
    }
    return $sequence
}

$planTemplate = @'
$ErrorActionPreference = 'Stop'
$directory = Join-Path ([IO.Path]::GetTempPath()) ('RewindleSetup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
$planPath = Join-Path $directory 'plan.json'
[IO.File]::WriteAllText('{{HANDOFF}}', $planPath)
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '{{SCRIPT}}', '-PlanOnly', '-PlanOutput', $planPath) + @({{ARGUMENTS}})
& '{{POWERSHELL}}' @arguments
exit $LASTEXITCODE
'@

# Creates the progress folder the way the wizard does (as the unelevated user, owned by that user) and runs a script with the
# progress path. The folder's owner is set to the account explicitly because an administrator's token owns new objects as the
# Administrators group.
$progressTemplate = @'
$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$directory = Join-Path ([IO.Path]::GetTempPath()) ('RewindleSetup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null
$security = [IO.Directory]::GetAccessControl($directory)
$security.SetOwner([Security.Principal.SecurityIdentifier]::new($sid))
[IO.Directory]::SetAccessControl($directory, $security)
$progress = Join-Path $directory 'progress.jsonl'
[IO.File]::WriteAllText('{{HANDOFF}}', $progress)
$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '{{SCRIPT}}', '-Unattended', '-ExpectedUserSid', $sid, '-ProgressPath', $progress) + @({{ARGUMENTS}})
& '{{POWERSHELL}}' @arguments
exit $LASTEXITCODE
'@

$elevationProbe = @'
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
'@

$readProbe = @'
try { $null = [IO.File]::ReadAllText('{{PATH}}'); 'READABLE' } catch { 'DENIED' }
'@

function Get-WebView2Version {
    foreach ($key in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )) {
        if (Test-Path -LiteralPath $key) {
            $value = [string](Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue).pv
            if ($value -match '^\d+(\.\d+){1,3}$') { return $value }
        }
    }
    return $null
}

# One complete cycle on the clean machine: an install with a progress feed, what it leaves, an uninstall with a progress feed,
# and what that leaves. -Extras adds the checks that only need to run once.
function Invoke-InstallCycle {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)]$AdministratorUser,
        [Parameter(Mandatory)]$StandardUser,
        [Parameter(Mandatory)][string]$InstallerScript,
        [switch]$SkipDashboard,
        [switch]$Extras
    )
    Write-Section "$Label : a real install with a progress feed"
    $dashboard = -not $SkipDashboard
    $arguments = @('-Repository', $Repository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1', '-Schedule', '03:15')
    if ($SkipDashboard) { $arguments += '-SkipDashboard' }
    $installName = "install-$Id"
    $run = Invoke-AsUserElevated -User $AdministratorUser -Name $installName -Template $progressTemplate -TimeoutSeconds 1800 -Values @{
        HANDOFF = Join-Path $handoff "$installName.txt"; SCRIPT = $InstallerScript; POWERSHELL = $windowsPowerShell
        ARGUMENTS = (ConvertTo-LiteralList $arguments)
    }
    Show-Run $run
    $feedPath = Get-HandoffPath "$installName.txt"
    if (Test-Path -LiteralPath $feedPath) { Write-Host '--- progress feed'; Write-Host ([IO.File]::ReadAllText($feedPath)) }
    Assert-Equal 0 $run.ExitCode "$Label : the install exits 0"
    $lines = Read-ProgressFeed $feedPath
    $skipped = @('first_backup')
    if ($SkipDashboard) { $skipped += @('webview2', 'dashboard') }
    Assert-Equal (Get-ExpectedSequence -Order $installPhaseOrder -Skipped $skipped) @(Get-PhaseSequence $lines) "$Label : the phases arrive in the documented order"
    foreach ($entry in @($lines | Where-Object { $_.type -eq 'phase' })) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($entry.title)) "$Label : phase line for $($entry.phase) has a title"
        Assert-True ($entry.state -ne 'failed') "$Label : phase $($entry.phase) did not fail"
        if ($entry.state -eq 'skipped') { Assert-True (-not [string]::IsNullOrWhiteSpace($entry.detail)) "$Label : the skipped phase $($entry.phase) says why" }
    }
    $result = $lines[$lines.Count - 1]
    Assert-True ($result.ok -eq $true -and $null -eq $result.error) "$Label : the install ends with a successful result line"
    Assert-Equal $installRoot $result.install_root "$Label : result.install_root"
    Assert-Equal $version $result.version "$Label : result.version"
    if ($dashboard) {
        Assert-Equal (Join-Path $installRoot 'ResticBackuperDashboard.exe') $result.dashboard_executable "$Label : result.dashboard_executable"
        Assert-True (Test-Path -LiteralPath $result.dashboard_executable -PathType Leaf) "$Label : the dashboard program exists"
    }
    else {
        Assert-True ($null -eq $result.dashboard_executable) "$Label : there is no dashboard program without the dashboard"
    }
    Assert-True (Test-Path -LiteralPath $result.recovery_key_path -PathType Leaf) "$Label : the recovery key file exists"
    Assert-Equal 'ResticBackuper-RecoveryKey.txt' (Split-Path -Leaf $result.recovery_key_path) "$Label : the recovery key has its documented name"
    Assert-True ($result.recovery_key_readable_by_user -eq $true) "$Label : the installer reports that the user can read the recovery key"
    Assert-True (@($result.PSObject.Properties.Name) -contains 'warnings') "$Label : the result carries its warnings array"

    # What is on the machine.
    Assert-True (Test-Path -LiteralPath (Join-Path $installRoot 'runtime-manifest.json') -PathType Leaf) "$Label : the runtime manifest exists"
    Assert-True (Test-Path -LiteralPath (Join-Path $Repository 'config') -PathType Leaf) "$Label : the repository was initialized"
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'repository-password.dpapi.json') -PathType Leaf) "$Label : the password is stored"
    Assert-True (Test-Path -LiteralPath $registryKey) "$Label : the Installed apps entry exists"
    Assert-True ($null -ne (Get-ScheduledTask -TaskName 'ResticBackuper' -ErrorAction SilentlyContinue)) "$Label : the backup task exists"
    Assert-Equal $dashboard ($null -ne (Get-ScheduledTask -TaskName 'ResticBackuperDashboard' -ErrorAction SilentlyContinue)) "$Label : the dashboard task exists exactly when the dashboard was installed"
    Assert-Equal $dashboard (Test-Path -LiteralPath $shortcutPath -PathType Leaf) "$Label : the Start menu shortcut exists exactly when the dashboard was installed"
    $configuration = [IO.File]::ReadAllText((Join-Path $installRoot 'backup-config.json')) | ConvertFrom-Json
    Assert-Equal $Repository $configuration.repository "$Label : the configuration names the repository"
    Assert-Equal $result.recovery_key_path $configuration.recovery_key_file "$Label : the configuration names the recovery key the result reports"
    Assert-True ([IO.File]::ReadAllText($result.recovery_key_path) -match '(?m)^Password:\s*\S{40,}') "$Label : the recovery key holds a password"
    $manifestBefore = (Get-FileHash -LiteralPath (Join-Path $installRoot 'runtime-manifest.json') -Algorithm SHA256).Hash

    if ($Extras) {
        # The recovery key: readable by its own account, not by another account.
        $keyProbe = Invoke-AsUser -User $AdministratorUser -Name 'read-key-owner' -Template $readProbe -Values @{ PATH = $result.recovery_key_path }
        Assert-Equal 'READABLE' $keyProbe.Stdout.Trim() "$Label : the installing account reads the recovery key"
        $keyProbe = Invoke-AsUser -User $StandardUser -Name 'read-key-other' -Template $readProbe -Values @{ PATH = $result.recovery_key_path }
        Assert-Equal 'DENIED' $keyProbe.Stdout.Trim() "$Label : another account cannot read the recovery key"

        Write-Section "$Label : a second install must refuse and change nothing"
        $run = Invoke-AsUserElevated -User $AdministratorUser -Name 'install-again' -Template $progressTemplate -Values @{
            HANDOFF = Join-Path $handoff 'install-again.txt'; SCRIPT = $InstallerScript; POWERSHELL = $windowsPowerShell
            ARGUMENTS = (ConvertTo-LiteralList $arguments)
        }
        Assert-True ($run.ExitCode -ne 0) "$Label : a second install fails"
        $again = Read-ProgressFeed (Get-HandoffPath 'install-again.txt')
        Assert-Equal @('preflight:started', 'preflight:failed') @(Get-PhaseSequence $again) "$Label : the second install stops in the preflight"
        Assert-Equal 'already_installed' $again[$again.Count - 1].error.code "$Label : the second install says Rewindle is already installed"
        Assert-Equal $manifestBefore (Get-FileHash -LiteralPath (Join-Path $installRoot 'runtime-manifest.json') -Algorithm SHA256).Hash "$Label : the refused install did not touch the installation"
    }

    Write-Section "$Label : uninstall with a progress feed"
    $uninstallName = "uninstall-$Id"
    $run = Invoke-AsUserElevated -User $AdministratorUser -Name $uninstallName -Template $progressTemplate -TimeoutSeconds 900 -Values @{
        HANDOFF = Join-Path $handoff "$uninstallName.txt"; SCRIPT = (Join-Path $installRoot 'Uninstall-ResticBackuper.ps1'); POWERSHELL = $windowsPowerShell; ARGUMENTS = ''
    }
    Show-Run $run
    $uninstallFeedPath = Get-HandoffPath "$uninstallName.txt"
    if (Test-Path -LiteralPath $uninstallFeedPath) { Write-Host '--- progress feed'; Write-Host ([IO.File]::ReadAllText($uninstallFeedPath)) }
    Assert-Equal 0 $run.ExitCode "$Label : the uninstall exits 0"
    $lines = Read-ProgressFeed $uninstallFeedPath
    $uninstallSkipped = @()
    if ($SkipDashboard) { $uninstallSkipped += 'shortcut' }
    Assert-Equal (Get-ExpectedSequence -Order $uninstallPhaseOrder -Skipped $uninstallSkipped) @(Get-PhaseSequence $lines) "$Label : the uninstall phases arrive in the documented order"
    $uninstallResult = $lines[$lines.Count - 1]
    Assert-True ($uninstallResult.ok -eq $true -and $null -eq $uninstallResult.error) "$Label : the uninstall ends with a successful result line"
    Assert-Equal 'uninstall' $uninstallResult.operation "$Label : the result names the operation"
    Assert-True ($uninstallResult.removed.install_root -eq $true) "$Label : the program folder is reported removed"
    $expectedTasks = if ($dashboard) { @('ResticBackuper', 'ResticBackuperDashboard') } else { @('ResticBackuper') }
    Assert-Equal $expectedTasks @($uninstallResult.removed.scheduled_tasks | Sort-Object) "$Label : the scheduled tasks are reported removed"
    Assert-Equal $dashboard $uninstallResult.removed.start_menu_shortcut "$Label : the shortcut is reported removed exactly when it existed"
    Assert-True ($uninstallResult.removed.installed_apps_entry -eq $true) "$Label : the Installed apps entry is reported removed"
    Assert-Equal $stateRoot $uninstallResult.kept.state_root "$Label : the uninstall keeps the state folder"
    Assert-Equal $Repository $uninstallResult.kept.repository "$Label : the uninstall keeps the repository"
    Assert-Equal $result.recovery_key_path $uninstallResult.kept.recovery_key "$Label : the uninstall keeps the recovery key"
    Assert-True (-not [string]::IsNullOrWhiteSpace($uninstallResult.kept.recovery_tools)) "$Label : the uninstall reports the recovery tools it keeps"

    Write-Section "$Label : the machine is clean, and only the kept data remains"
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) "$Label : the program folder is gone"
    Assert-True (-not (Test-Path -LiteralPath $shortcutPath)) "$Label : the Start menu shortcut is gone"
    Assert-True (-not (Test-Path -LiteralPath $registryKey)) "$Label : the Installed apps entry is gone"
    foreach ($name in $taskNames) {
        Assert-True ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) "$Label : the scheduled task $name is gone"
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $Repository 'config') -PathType Leaf) "$Label : the repository is kept"
    Assert-True (Test-Path -LiteralPath $result.recovery_key_path -PathType Leaf) "$Label : the recovery key is kept"
    Assert-True (Test-Path -LiteralPath $stateRoot -PathType Container) "$Label : the state folder is kept"
    Assert-True (Test-Path -LiteralPath $uninstallResult.kept.recovery_tools -PathType Container) "$Label : the recovery tools are kept"
    Assert-Equal @($stateRoot) @(Get-InstallationFootprint) "$Label : only the state folder remains of the Rewindle footprint (the repository and recovery key live elsewhere)"

    if ($Extras) {
        $run = Invoke-AsUserElevated -User $AdministratorUser -Name 'uninstall-again' -Template $progressTemplate -Values @{
            HANDOFF = Join-Path $handoff 'uninstall-again.txt'; SCRIPT = (Join-Path $bundle 'payload\Uninstall-ResticBackuper.ps1'); POWERSHELL = $windowsPowerShell; ARGUMENTS = ''
        }
        Assert-True ($run.ExitCode -ne 0) "$Label : a second uninstall fails"
        $nothing = Read-ProgressFeed (Get-HandoffPath 'uninstall-again.txt')
        Assert-Equal @('preflight:started', 'preflight:failed') @(Get-PhaseSequence $nothing) "$Label : the second uninstall stops in the preflight"
        Assert-Equal 'not_installed' $nothing[$nothing.Count - 1].error.code "$Label : the second uninstall says nothing is installed"

        # An Installed apps entry left behind by a removed program folder: Windows' own entry points at the missing
        # uninstaller and setup refuses to install over it, so the uninstaller clears it after its usual ownership check.
        New-Item -Path $registryKey -Force | Out-Null
        New-ItemProperty -Path $registryKey -Name 'DisplayName' -Value 'ResticBackuper' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $registryKey -Name 'InstallLocation' -Value $installRoot -PropertyType String -Force | Out-Null
        $run = Invoke-AsUserElevated -User $AdministratorUser -Name 'uninstall-leftovers' -Template $progressTemplate -Values @{
            HANDOFF = Join-Path $handoff 'uninstall-leftovers.txt'; SCRIPT = (Join-Path $bundle 'payload\Uninstall-ResticBackuper.ps1'); POWERSHELL = $windowsPowerShell; ARGUMENTS = ''
        }
        Show-Run $run
        Assert-Equal 0 $run.ExitCode "$Label : an uninstall clears a leftover Installed apps entry"
        $leftovers = Read-ProgressFeed (Get-HandoffPath 'uninstall-leftovers.txt')
        $leftoverResult = $leftovers[$leftovers.Count - 1]
        Assert-True ($leftoverResult.ok -eq $true) "$Label : the leftover cleanup ends with a successful result line"
        Assert-True ($leftoverResult.removed.install_root -eq $false) "$Label : the leftover cleanup reports that the program files were already gone"
        Assert-True ($leftoverResult.removed.installed_apps_entry -eq $true) "$Label : the leftover cleanup reports the Installed apps entry as removed"
        Assert-True (@(Get-PhaseSequence $leftovers) -contains 'program_files:skipped') "$Label : the leftover cleanup skips the program files"
        Assert-True (-not (Test-Path -LiteralPath $registryKey)) "$Label : the leftover Installed apps entry is gone"

        # A Google Drive verification task left behind on its own: matched without the deleted configuration (verifier and
        # configuration paths, evidence folder, a well-formed repository ID, this account) and removed.
        $cloudArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
            (Join-Path $installRoot 'verify_my_drive_cloud_repository.ps1') + '" -ConfigPath "' + (Join-Path $installRoot 'backup-config.json') +
            '" -CloudVerificationRoot "' + (Join-Path $programData 'ResticBackuperCloudVerification') + '" -ExpectedRepositoryId "' + ('ab' * 32) + '"'
        Register-ScheduledTask -TaskName 'ResticBackuperGoogleDriveSync' -TaskPath '\' `
            -Action (New-ScheduledTaskAction -Execute $windowsPowerShell -Argument $cloudArguments -WorkingDirectory $installRoot) `
            -Principal (New-ScheduledTaskPrincipal -UserId $AdministratorUser.Name -LogonType Interactive) | Out-Null
        $run = Invoke-AsUserElevated -User $AdministratorUser -Name 'uninstall-cloud-leftover' -Template $progressTemplate -Values @{
            HANDOFF = Join-Path $handoff 'uninstall-cloud-leftover.txt'; SCRIPT = (Join-Path $bundle 'payload\Uninstall-ResticBackuper.ps1'); POWERSHELL = $windowsPowerShell; ARGUMENTS = ''
        }
        Show-Run $run
        Assert-Equal 0 $run.ExitCode "$Label : an uninstall clears a leftover Google Drive verification task"
        $cloudLeftover = Read-ProgressFeed (Get-HandoffPath 'uninstall-cloud-leftover.txt')
        Assert-True (@($cloudLeftover[$cloudLeftover.Count - 1].removed.scheduled_tasks) -contains 'ResticBackuperGoogleDriveSync') "$Label : the leftover cleanup reports the Google Drive task as removed"
        Assert-True ($null -eq (Get-ScheduledTask -TaskName 'ResticBackuperGoogleDriveSync' -ErrorAction SilentlyContinue)) "$Label : the leftover Google Drive task is gone"
    }

    # Leave a clean machine for the next cycle: the data an uninstall keeps is removed here, because this test created it.
    Remove-Item -LiteralPath $stateRoot -Recurse -Force
    Remove-Item -LiteralPath $result.recovery_key_path -Force
    Remove-Item -LiteralPath (Split-Path -Parent $Repository) -Recurse -Force
    Assert-Equal @() @(Get-InstallationFootprint) "$Label : nothing of Rewindle remains after the test removed the data an uninstall keeps"
}

$administratorUser = $null
$standardUser = $null
$succeeded = $false
try {
    Write-Section 'Preparing the disposable machine'
    New-Item -ItemType Directory -Path $root, $scripts, $logs, $handoff, $docs, $photos | Out-Null
    [IO.File]::WriteAllText((Join-Path $docs 'document.txt'), 'contract test document', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $photos 'photo.txt'), 'contract test photo', [Text.UTF8Encoding]::new($false))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $Artifact).Path, $bundle)
    $installerScript = Join-Path $bundle 'Install-ResticBackuper.ps1'
    Assert-True (Test-Path -LiteralPath $installerScript -PathType Leaf) 'the release bundle holds the installer'
    Assert-True (Test-Path -LiteralPath (Join-Path $bundle 'payload\Uninstall-ResticBackuper.ps1') -PathType Leaf) 'the release payload holds the uninstaller'
    Start-Service -Name seclogon
    $standardUser = New-TestUser -Name 'rwd-contract-std'
    $administratorUser = New-TestUser -Name 'rwd-contract-admin' -Administrator
    foreach ($user in @($standardUser, $administratorUser)) {
        Grant-Access -Path $root -User $user.Name -Rights 'RX'
        Grant-Access -Path $logs -User $user.Name -Rights 'M'
        Grant-Access -Path $handoff -User $user.Name -Rights 'M'
    }
    Write-Host "Test accounts created: $($standardUser.Name) (standard), $($administratorUser.Name) (administrator)"

    Write-Section 'The accounts are what the test needs them to be'
    $probe = Invoke-AsUser -User $standardUser -Name 'probe-standard-elevation' -Template $elevationProbe
    if ($probe.ExitCode -ne 0) { Show-Run $probe; throw 'The standard test account could not run a process.' }
    Assert-Equal 'False' $probe.Stdout.Trim() 'the standard test account is not an administrator'
    $probe = Invoke-AsUser -User $administratorUser -Name 'probe-admin-filtered' -Template $elevationProbe
    if ($probe.ExitCode -ne 0) { Show-Run $probe; throw 'The administrator test account could not run a process.' }
    Write-Host "The administrator test account's ordinary token is elevated: $($probe.Stdout.Trim()) (False while User Account Control is on)"
    $probe = Invoke-AsUserElevated -User $administratorUser -Name 'probe-admin-elevation' -Template $elevationProbe
    if ($probe.ExitCode -ne 0) { Show-Run $probe; throw 'The administrator test account could not run an elevated task.' }
    Assert-Equal 'True' $probe.Stdout.Trim() 'the administrator test account runs elevated through its task, as after approving the Windows prompt'

    # ---------------------------------------------------------------------------------------------------------------------
    Write-Section '1. Plan mode as a standard user'
    $planArguments = ConvertTo-LiteralList @('-Repository', $planRepository, '-SourceList', "$docs;$photos", '-Schedule', '02:00', '-MinimumFreeGiB', '1')
    $run = Invoke-AsUser -User $standardUser -Name 'plan-standard' -Template $planTemplate -Values @{
        HANDOFF = Join-Path $handoff 'plan-standard.txt'; SCRIPT = $installerScript; ARGUMENTS = $planArguments; POWERSHELL = $windowsPowerShell
    }
    if ($run.ExitCode -ne 0) { Show-Run $run }
    Assert-Equal 0 $run.ExitCode 'the plan run as a standard user exits 0'
    Assert-Equal '' $run.Stdout.Trim() 'plan mode prints nothing'
    $planPath = Get-HandoffPath 'plan-standard.txt'
    Assert-Equal @('plan.json') @(Get-ChildItem -LiteralPath (Split-Path -Parent $planPath) -Force | ForEach-Object Name) 'the plan is the only file in the standard user''s setup folder'
    $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json
    Assert-Equal 'Rewindle.InstallPlan.v1' $plan.schema 'plan schema id'
    if (-not $plan.ok) { $plan | ConvertTo-Json -Depth 8 | Write-Host }
    Assert-True $plan.ok "the plan for a valid configuration is ok (errors: $(@($plan.errors | ForEach-Object code) -join ', '))"
    Assert-True ($plan.environment.elevated -eq $false) 'the plan ran without elevation'
    Assert-Equal $version $plan.environment.version 'the plan reports the bundle version'
    Assert-Equal $planRepository $plan.resolved.repository 'resolved repository'
    Assert-Equal @($docs, $photos) @($plan.resolved.sources) 'resolved sources'
    Assert-True ($plan.environment.dotnet_framework_48 -eq $true) '.NET Framework 4.8 is reported'
    Assert-True (@($plan.environment.volumes).Count -ge 1) 'volumes are listed'
    Assert-True (@($plan.environment.volumes | Where-Object { $_.is_system }).Count -eq 1) 'exactly one system volume'
    Assert-True (@($plan.environment.volumes | Where-Object { $_.recommended }).Count -le 1) 'at most one recommended volume'
    foreach ($entry in @($plan.environment.volumes | Where-Object { $_.recommended })) {
        Assert-True ($entry.eligible -and $entry.filesystem -ieq 'NTFS' -and $entry.same_physical_disk_as_system -eq $false) 'the recommended volume is eligible NTFS on another physical disk'
    }
    Assert-Equal 7 @($plan.environment.known_folders).Count 'seven known folders are listed'
    Assert-True ($null -eq $plan.environment.existing_install.rewindle) 'no installation is reported on the clean runner'
    if ([IO.Path]::GetPathRoot($planRepository) -ieq [IO.Path]::GetPathRoot($env:SystemRoot)) {
        Assert-True (@($plan.warnings | Where-Object { $_.code -eq 'repository_on_system_disk' }).Count -eq 1) 'a repository on the Windows drive is warned about'
    }
    Assert-Equal @() @(Get-InstallationFootprint) 'plan mode left nothing installed'
    Assert-True (-not (Test-Path -LiteralPath $planRepository)) 'plan mode did not create the repository folder'

    $run = Invoke-AsUser -User $standardUser -Name 'plan-standard-invalid' -Template $planTemplate -Values @{
        HANDOFF = Join-Path $handoff 'plan-standard-invalid.txt'; SCRIPT = $installerScript; POWERSHELL = $windowsPowerShell
        ARGUMENTS = (ConvertTo-LiteralList @('-Repository', 'relative\path', '-SourceList', "$docs;$root\no-such-folder", '-Schedule', '25:00', '-MinimumFreeGiB', '1'))
    }
    if ($run.ExitCode -ne 0) { Show-Run $run }
    Assert-Equal 0 $run.ExitCode 'a plan with problems still exits 0'
    $invalid = [IO.File]::ReadAllText((Get-HandoffPath 'plan-standard-invalid.txt')) | ConvertFrom-Json
    Assert-True (-not $invalid.ok) 'the plan for invalid input is not ok'
    foreach ($code in @('repository_not_absolute', 'source_not_found', 'schedule_invalid')) {
        Assert-True (@($invalid.errors | Where-Object { $_.code -eq $code }).Count -ge 1) "the plan reports $code"
    }

    # ---------------------------------------------------------------------------------------------------------------------
    Write-Section '2. Installs that must fail cleanly'
    if (-not (Get-WebView2Version)) {
        # Fetch the WebView2 runtime up front, with retries, so a flaky download cannot fail the contract test. If it still
        # fails, the installer tries on its own.
        for ($attempt = 1; $attempt -le 3 -and -not (Get-WebView2Version); $attempt++) {
            $bootstrapper = Join-Path $root 'MicrosoftEdgeWebview2Setup.exe'
            try {
                Invoke-WebRequest -UseBasicParsing -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $bootstrapper
                $signature = Get-AuthenticodeSignature -LiteralPath $bootstrapper
                if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike '*Microsoft*') { throw 'The WebView2 bootstrapper is not signed by Microsoft.' }
                Start-Process -FilePath $bootstrapper -ArgumentList '/silent', '/install' -Wait
            }
            catch { Write-Host "WebView2 pre-installation attempt $attempt failed: $($_.Exception.Message)"; Start-Sleep -Seconds 5 }
        }
        Write-Host "WebView2 runtime before the install: $(Get-WebView2Version)"
    }
    $firstRepository = Join-Path $root 'install\Backup'
    $common = @('-Repository', $firstRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1')

    $run = Invoke-AsUserElevated -User $administratorUser -Name 'install-bad-schedule' -Template $progressTemplate -Values @{
        HANDOFF = Join-Path $handoff 'install-bad-schedule.txt'; SCRIPT = $installerScript; POWERSHELL = $windowsPowerShell
        ARGUMENTS = (ConvertTo-LiteralList ($common + @('-Schedule', '99:99')))
    }
    Assert-True ($run.ExitCode -ne 0) 'an install with an invalid schedule fails'
    $lines = Read-ProgressFeed (Get-HandoffPath 'install-bad-schedule.txt')
    Assert-Equal @('preflight:started', 'preflight:failed') @(Get-PhaseSequence $lines) 'a refused install reports preflight started and failed'
    $result = $lines[$lines.Count - 1]
    Assert-True ($result.ok -eq $false) 'the failed install ends with ok false'
    Assert-Equal 'schedule_invalid' $result.error.code 'the failed install carries the validation code'
    Assert-True (-not [string]::IsNullOrWhiteSpace($result.error.message)) 'the failed install carries a message'
    Assert-Equal 'failed' @($lines | Where-Object { $_.type -eq 'phase' })[1].state 'the failed phase line'
    Assert-Equal @() @(Get-InstallationFootprint) 'a refused install changed nothing'
    Assert-True (-not (Test-Path -LiteralPath $firstRepository)) 'a refused install created no repository'

    $run = Invoke-AsUserElevated -User $administratorUser -Name 'install-bad-progress-path' -Template @'
$ErrorActionPreference = 'Stop'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$outside = Join-Path $env:SystemRoot 'rewindle-contract-progress.jsonl'
& '{{POWERSHELL}}' -NoProfile -ExecutionPolicy Bypass -File '{{SCRIPT}}' -Unattended -ExpectedUserSid $sid -ProgressPath $outside {{ARGUMENTS}}
exit $LASTEXITCODE
'@ -Values @{ SCRIPT = $installerScript; POWERSHELL = $windowsPowerShell; ARGUMENTS = (($common | ForEach-Object { "'" + $_ + "'" }) -join ' ') }
    Assert-True ($run.ExitCode -ne 0) 'an install with a progress path outside the temporary folder is refused'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'rewindle-contract-progress.jsonl'))) 'no progress file was created outside the temporary folder'
    Assert-Equal @() @(Get-InstallationFootprint) 'a refused progress path changed nothing'

    # ---------------------------------------------------------------------------------------------------------------------
    Invoke-InstallCycle -Id 'cycle1' -Label 'cycle 1 (with the dashboard)' -Repository $firstRepository -AdministratorUser $administratorUser `
        -StandardUser $standardUser -InstallerScript $installerScript -Extras
    Invoke-InstallCycle -Id 'cycle2' -Label 'cycle 2 (without the dashboard)' -Repository (Join-Path $root 'install-2\Backup') -AdministratorUser $administratorUser `
        -StandardUser $standardUser -InstallerScript $installerScript -SkipDashboard

    $succeeded = $true
    [pscustomobject]@{
        ok = $true
        assertions = $assertions
        plan_as_standard_user = 'passed'
        failing_installs = 'passed'
        install_with_progress = 'passed'
        install_without_dashboard = 'passed'
        uninstall_with_progress = 'passed'
        machine_clean_after_uninstall = 'passed'
    } | ConvertTo-Json
}
catch {
    Write-Host "TEST FAILED: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    if (Test-Path -LiteralPath $logs) {
        foreach ($log in Get-ChildItem -LiteralPath $logs -File | Sort-Object LastWriteTime | Select-Object -Last 6) {
            Write-Host "--- $($log.Name)"
            Write-Host ([IO.File]::ReadAllText($log.FullName))
        }
    }
    throw
}
finally {
    # Best-effort cleanup of the disposable machine; a failure here never hides the result above.
    try {
        if (Test-Path -LiteralPath $installRoot) {
            $leftover = Join-Path $installRoot 'Uninstall-ResticBackuper.ps1'
            if ((Test-Path -LiteralPath $leftover) -and $null -ne $administratorUser) {
                $cleanup = Invoke-AsUserElevated -User $administratorUser -Name 'cleanup-uninstall' -TimeoutSeconds 600 -Values @{ SCRIPT = $leftover; SID = $administratorUser.Sid; POWERSHELL = $windowsPowerShell } -Template @'
& '{{POWERSHELL}}' -NoProfile -ExecutionPolicy Bypass -File '{{SCRIPT}}' -Unattended -ExpectedUserSid '{{SID}}'
exit $LASTEXITCODE
'@
                if ($cleanup.ExitCode -ne 0) { Write-Host 'The cleanup uninstall did not succeed.'; Show-Run $cleanup }
            }
        }
        foreach ($name in $taskNames) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
        foreach ($path in @($installRoot, $stateRoot, $cloudToolsRoot, $shortcutPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $registryKey) { Remove-Item -LiteralPath $registryKey -Recurse -Force -ErrorAction SilentlyContinue }
        foreach ($user in $createdUsers) {
            $account = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
            if ($account) {
                $profileSid = $account.SID.Value
                Remove-LocalUser -Name $user -ErrorAction SilentlyContinue
                Get-CimInstance Win32_UserProfile -Filter "SID='$profileSid'" -ErrorAction SilentlyContinue | Remove-CimInstance -ErrorAction SilentlyContinue
            }
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch { Write-Host "Cleanup problem: $($_.Exception.Message)" }
}
if (-not $succeeded) { exit 1 }
