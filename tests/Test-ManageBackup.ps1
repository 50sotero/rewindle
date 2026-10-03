#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$sourceManager = Join-Path $projectRoot 'src\Manage-Backup.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot ('ResticBackuper-BackupManager-{0}' -f [Guid]::NewGuid().ToString('N'))
$encoding = [Text.UTF8Encoding]::new($false, $true)
$taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$script:testCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:testCount++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Match {
    param([string]$Pattern, [string]$Value, [string]$Message)
    $script:testCount++
    if ($Value -notmatch $Pattern) { throw "Assertion failed: $Message. Value: $Value" }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Write-Json {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12) + "`n"), $encoding)
}

function Read-Json {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, $encoding) | ConvertFrom-Json
}

function Read-TaskDocument {
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    $stringReader = [IO.StringReader]::new([IO.File]::ReadAllText($script:taskXmlPath, $encoding))
    try {
        $reader = [Xml.XmlReader]::Create($stringReader, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $false
        $document.XmlResolver = $null
        $document.Load($reader)
        return $document
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stringReader.Dispose()
    }
}

function Write-TaskDocument {
    param([Xml.XmlDocument]$Document)
    [IO.File]::WriteAllText($script:taskXmlPath, $Document.OuterXml, $encoding)
}

function Get-TaskFingerprint {
    $document = Read-TaskDocument
    $payload = 'ResticBackuper.TaskXml.v1' + "`n" + $document.DocumentElement.OuterXml
    return Get-Sha256Hex -Bytes $encoding.GetBytes($payload)
}

function Set-TaskNodeText {
    param([string]$XPath, [string]$Value)
    $document = Read-TaskDocument
    $manager = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $manager.AddNamespace('t', $taskNamespace)
    $node = $document.DocumentElement.SelectSingleNode($XPath, $manager)
    if ($null -eq $node) { throw "Missing task fixture node: $XPath" }
    $node.InnerText = $Value
    Write-TaskDocument -Document $document
}

function New-PathSecurityRecord {
    param(
        [string]$Path,
        [string]$Kind,
        [string]$Owner = 'S-1-5-32-544',
        [bool]$Protected = $false
    )
    return [ordered]@{
        path = $Path
        kind = $Kind
        normal = $true
        reparse = $false
        owner_sid = $Owner
        inheritance_protected = $Protected
        system_full = $true
        administrators_full = $true
        user_read_execute = $true
        owner_rights_read_execute = $true
        unexpected_identity = $false
        user_write = $false
        owner_rights_write = $false
    }
}

function New-ActiveStatus {
    param(
        [string]$RunId = $script:runId,
        [string]$State = 'backing_up',
        [object]$WrapperPid = $script:wrapperPid,
        [object]$WrapperStartFileTime = $script:wrapperStart,
        [object]$LauncherPid = $script:launcherPid,
        [object]$LauncherStartFileTime = $script:launcherStart,
        [string]$ChannelId = $script:channelId,
        [string]$ChannelFingerprint = $script:channelFingerprint
    )
    return [ordered]@{
        schema_version = 1
        run_id = $RunId
        state = $State
        started_utc = '2026-07-20T22:45:00Z'
        finished_utc = $null
        wrapper_pid = $WrapperPid
        wrapper_start_filetime = $WrapperStartFileTime
        launcher_pid = $LauncherPid
        launcher_start_filetime = $LauncherStartFileTime
        cancel_channel_id = $ChannelId
        cancel_channel_fingerprint = $ChannelFingerprint
        cancel_requested_utc = $null
        cancel_signal_sent_utc = $null
        cancel_outcome = $null
        exit_code = $null
    }
}

function New-TerminalStatus {
    param(
        [string]$RunId = $script:runId,
        [string]$State = 'success',
        [int]$ExitCode = 0,
        [AllowNull()][string]$CancelOutcome = $null
    )
    $value = New-ActiveStatus -RunId $RunId -State $State
    $value.finished_utc = '2026-07-20T22:50:00Z'
    $value.exit_code = $ExitCode
    $value.cancel_outcome = if ($PSBoundParameters.ContainsKey('CancelOutcome')) { $CancelOutcome } else { $null }
    return $value
}

function Reset-Fixtures {
    if (Test-Path -LiteralPath $script:signalPath) {
        Remove-Item -LiteralPath $script:signalPath -Force
    }
    [IO.File]::WriteAllText($script:taskStatePath, 'Running', $encoding)
    [IO.File]::WriteAllText($script:taskXmlPath, $script:validTaskXml, $encoding)
    Write-Json -Path $script:statusPath -Value (New-ActiveStatus)
    Write-Json -Path $script:statusAfterPath -Value (New-TerminalStatus)
    Write-Json -Path $script:processesPath -Value ([ordered]@{
        schema_version = 1
        processes = @(
            [ordered]@{
                pid = $script:wrapperPid
                running = $true
                executable = $script:pythonPath
                start_filetime = $script:wrapperStart
            },
            [ordered]@{
                pid = $script:launcherPid
                running = $true
                executable = $script:launcherPath
                start_filetime = $script:launcherStart
            }
        )
    })
    Write-Json -Path $script:channelPath -Value ([ordered]@{
        schema_version = 1
        exists = $true
        event_name = $script:eventName
        required_rights = $script:eventRights
        open_denied = $false
        owner_sid = 'S-1-5-32-544'
        group_sid = 'S-1-5-32-544'
        dacl_protected = $true
        system_full = $true
        administrators_full = $true
        unexpected_ace = $false
        signal_failure = $false
    })
    Write-Json -Path $script:securityPath -Value ([ordered]@{
        schema_version = 1
        paths = [ordered]@{
            install_root = New-PathSecurityRecord -Path $script:installRoot -Kind directory -Protected $true
            manager = New-PathSecurityRecord -Path $script:installedManager -Kind file
            launcher = New-PathSecurityRecord -Path $script:launcherPath -Kind file
            python = New-PathSecurityRecord -Path $script:pythonPath -Kind file
            state_root = New-PathSecurityRecord -Path $script:stateRoot -Kind directory -Protected $true
            status = New-PathSecurityRecord -Path $script:statusPath -Kind file -Owner $script:userSid
        }
    })
}

function New-Nonce {
    return Get-Sha256Hex -Bytes $encoding.GetBytes([Guid]::NewGuid().ToString('N'))
}

function Get-ExpectedDigest {
    param(
        [string]$RunId,
        [int]$WrapperPid,
        [string]$Fingerprint,
        [string]$Nonce,
        [string]$Sid
    )
    $payload = @(
        'ResticBackuper.BackupControlRequest.v1',
        $Sid,
        'cancel',
        $RunId,
        $WrapperPid.ToString([Globalization.CultureInfo]::InvariantCulture),
        $Fingerprint,
        $Nonce
    ) -join "`n"
    return Get-Sha256Hex -Bytes $encoding.GetBytes($payload)
}

function Invoke-Manager {
    param(
        [string]$RequestedRunId = $script:runId,
        [int]$RequestedWrapperPid = $script:wrapperPid,
        [string]$TaskFingerprint = (Get-TaskFingerprint),
        [string]$ExpectedSid = $script:userSid,
        [string]$Scenario = 'None'
    )
    $nonce = New-Nonce
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:installedManager,
        '-Action', 'Cancel',
        '-RunId', $RequestedRunId,
        '-ExpectedWrapperPid', [string]$RequestedWrapperPid,
        '-ExpectedTaskFingerprint', $TaskFingerprint,
        '-ExpectedUserSid', $ExpectedSid,
        '-ResultPath', $script:testResultPath,
        '-RequestNonce', $nonce,
        '-TestRoot', $fixtureRoot,
        '-TestScenario', $Scenario
    )
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = (& $powershell @arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $priorPreference }
    try { $json = $text | ConvertFrom-Json }
    catch { throw "Backup manager did not return JSON. exit=$exitCode output=$text" }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Json = $json
        Text = $text
        Nonce = $nonce
        RunId = $RequestedRunId
        WrapperPid = $RequestedWrapperPid
        Fingerprint = $TaskFingerprint
        Sid = $ExpectedSid
    }
}

function Assert-FailedClosed {
    param([pscustomobject]$Result, [string]$Pattern, [string]$Message)
    Assert-True -Condition ($Result.ExitCode -eq 1 -and -not [bool]$Result.Json.ok -and
        -not [bool]$Result.Json.requested -and -not [bool]$Result.Json.already_finished) `
        -Message "$Message returns a bound failure"
    Assert-Match -Pattern $Pattern -Value ([string]$Result.Json.error) -Message $Message
    Assert-True -Condition (-not (Test-Path -LiteralPath $script:signalPath)) `
        -Message "$Message does not signal a channel"
}

try {
    foreach ($directory in @(
        $fixtureRoot,
        (Join-Path $fixtureRoot 'ProgramFiles\ResticBackuper'),
        (Join-Path $fixtureRoot 'ProgramFiles\ResticBackuper\Python'),
        (Join-Path $fixtureRoot 'ProgramData\ResticBackuper'),
        (Join-Path $fixtureRoot 'ControlAdapter')
    )) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

    $script:installRoot = Join-Path $fixtureRoot 'ProgramFiles\ResticBackuper'
    $script:stateRoot = Join-Path $fixtureRoot 'ProgramData\ResticBackuper'
    $adapterRoot = Join-Path $fixtureRoot 'ControlAdapter'
    $script:installedManager = Join-Path $script:installRoot 'Manage-Backup.ps1'
    $script:launcherPath = Join-Path $script:installRoot 'ResticBackuperTaskLauncher.exe'
    $script:pythonPath = Join-Path $script:installRoot 'Python\python.exe'
    $script:statusPath = Join-Path $script:stateRoot 'status.json'
    $script:taskXmlPath = Join-Path $adapterRoot 'ResticBackuper.xml'
    $script:taskStatePath = Join-Path $adapterRoot 'ResticBackuper.state'
    $script:securityPath = Join-Path $adapterRoot 'security.json'
    $script:processesPath = Join-Path $adapterRoot 'processes.json'
    $script:channelPath = Join-Path $adapterRoot 'channel.json'
    $script:statusAfterPath = Join-Path $adapterRoot 'status-after.json'
    $script:signalPath = Join-Path $adapterRoot 'signal.json'
    $script:testResultPath = Join-Path $script:stateRoot 'unused-test-result.json'
    Copy-Item -LiteralPath $sourceManager -Destination $script:installedManager
    [IO.File]::WriteAllText($script:launcherPath, "fixture launcher`n", $encoding)
    [IO.File]::WriteAllText($script:pythonPath, "fixture python`n", $encoding)

    $script:userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:runId = '20260720T224500-ab12cd34'
    $script:otherRunId = '20260720T224600-de56fa78'
    $script:wrapperPid = 4321
    $script:launcherPid = 1234
    $script:wrapperStart = '134139123456789012'
    $script:launcherStart = '134139123450000000'
    $script:channelId = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
    $script:eventName = 'Local\ResticBackuper.Cancel.' + $script:channelId
    $script:channelFingerprint = Get-Sha256Hex -Bytes $encoding.GetBytes($script:eventName)
    $script:eventRights = [int]([Security.AccessControl.EventWaitHandleRights]::ReadPermissions -bor `
        [Security.AccessControl.EventWaitHandleRights]::Modify -bor `
        [Security.AccessControl.EventWaitHandleRights]::Synchronize)

    $escapedLauncher = [Security.SecurityElement]::Escape($script:launcherPath)
    $escapedInstallRoot = [Security.SecurityElement]::Escape($script:installRoot)
    $script:validTaskXml = @"
<Task version="1.4" xmlns="$taskNamespace">
  <RegistrationInfo><Author>fixture</Author><Description>preserve</Description><URI>\ResticBackuper</URI></RegistrationInfo>
  <Triggers><CalendarTrigger><StartBoundary>2026-07-20T02:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>$script:userSid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable><RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable><IdleSettings><StopOnIdleEnd>true</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings><AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle><WakeToRun>true</WakeToRun><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>$escapedLauncher</Command><WorkingDirectory>$escapedInstallRoot</WorkingDirectory></Exec></Actions>
</Task>
"@

    Reset-Fixtures
    $valid = Invoke-Manager
    Assert-True -Condition ($valid.ExitCode -eq 0 -and [bool]$valid.Json.ok -and
        [bool]$valid.Json.requested -and -not [bool]$valid.Json.already_finished) `
        -Message "valid cancellation signal succeeds: $($valid.Text)"
    Assert-True -Condition ([string]$valid.Json.action -eq 'cancel' -and
        [string]$valid.Json.run_id -eq $script:runId -and
        [string]$valid.Json.request_nonce -eq $valid.Nonce -and
        [string]$valid.Json.request_user_sid -eq $script:userSid) `
        -Message 'result binds action, run, nonce, and SID'
    $expectedDigest = Get-ExpectedDigest -RunId $valid.RunId -WrapperPid $valid.WrapperPid `
        -Fingerprint $valid.Fingerprint -Nonce $valid.Nonce -Sid $valid.Sid
    Assert-True -Condition ([string]$valid.Json.request_digest -eq $expectedDigest) `
        -Message 'result request digest matches exact cancellation contract'
    $signal = Read-Json -Path $script:signalPath
    Assert-True -Condition ([bool]$signal.set -and [string]$signal.event_name -eq $script:eventName -and
        [string]$signal.cancel_channel_id -eq $script:channelId -and [int]$signal.requested_rights -eq $script:eventRights) `
        -Message 'only the exact derived event is signaled with ReadPermissions|Modify|Synchronize'

    # A run is cancellable in the wrapper's preflight phases too: each passes a cancellation checkpoint.
    foreach ($preflightState in @('checking_repository_storage', 'preflighting_sources', 'authenticating_repository')) {
        Reset-Fixtures
        Write-Json -Path $script:statusPath -Value (New-ActiveStatus -State $preflightState)
        $preflight = Invoke-Manager
        Assert-True -Condition ($preflight.ExitCode -eq 0 -and [bool]$preflight.Json.ok -and
            [bool]$preflight.Json.requested -and -not [bool]$preflight.Json.already_finished) `
            -Message "cancellation is accepted during $preflightState`: $($preflight.Text)"
    }
    Reset-Fixtures
    Write-Json -Path $script:statusPath -Value (New-ActiveStatus -State 'not_a_backup_phase')
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'state is invalid' -Message 'unknown backup state'

    Reset-Fixtures
    Write-Json -Path $script:statusPath -Value (New-TerminalStatus)
    [IO.File]::WriteAllText($script:taskStatePath, 'Ready', $encoding)
    $finished = Invoke-Manager
    Assert-True -Condition ($finished.ExitCode -eq 0 -and [bool]$finished.Json.ok -and
        -not [bool]$finished.Json.requested -and [bool]$finished.Json.already_finished -and
        -not (Test-Path -LiteralPath $script:signalPath)) -Message "same-run terminal race returns already_finished: $($finished.Text)"

    Reset-Fixtures
    $raced = Invoke-Manager -Scenario 'FinishBeforeSignal'
    Assert-True -Condition ($raced.ExitCode -eq 0 -and [bool]$raced.Json.already_finished -and
        -not [bool]$raced.Json.requested -and -not (Test-Path -LiteralPath $script:signalPath)) `
        -Message 'run finishing after event open is not signaled'

    Reset-Fixtures
    Write-Json -Path $script:statusAfterPath -Value (New-ActiveStatus -RunId $script:otherRunId)
    $replaced = Invoke-Manager -Scenario 'ReplaceBeforeSignal'
    Assert-FailedClosed -Result $replaced -Pattern 'another run' -Message 'replacement-run race'

    Reset-Fixtures
    $staleRun = Invoke-Manager -RequestedRunId $script:otherRunId
    Assert-FailedClosed -Result $staleRun -Pattern 'another run' -Message 'stale run ID'
    Reset-Fixtures
    $stalePid = Invoke-Manager -RequestedWrapperPid 9999
    Assert-FailedClosed -Result $stalePid -Pattern 'wrapper PID differs' -Message 'stale wrapper PID'

    foreach ($processTamper in @(
        [pscustomobject]@{ Index = 0; Field = 'start_filetime'; Value = '134139123456789099'; Pattern = 'wrapper.*identity'; Name = 'wrapper start identity' },
        [pscustomobject]@{ Index = 0; Field = 'executable'; Value = 'C:\Windows\System32\cmd.exe'; Pattern = 'wrapper.*identity'; Name = 'wrapper executable' },
        [pscustomobject]@{ Index = 1; Field = 'start_filetime'; Value = '134139123450000099'; Pattern = 'launcher.*identity'; Name = 'launcher start identity' },
        [pscustomobject]@{ Index = 1; Field = 'executable'; Value = 'C:\Windows\System32\cmd.exe'; Pattern = 'launcher.*identity'; Name = 'launcher executable' }
    )) {
        Reset-Fixtures
        $processes = Read-Json -Path $script:processesPath
        $processes.processes[$processTamper.Index].$($processTamper.Field) = $processTamper.Value
        Write-Json -Path $script:processesPath -Value $processes
        $result = Invoke-Manager
        Assert-FailedClosed -Result $result -Pattern $processTamper.Pattern -Message $processTamper.Name
    }

    Reset-Fixtures
    [IO.File]::WriteAllText($script:taskStatePath, 'Ready', $encoding)
    $notRunning = Invoke-Manager
    Assert-FailedClosed -Result $notRunning -Pattern 'still marked active' -Message 'non-running task with active status'

    foreach ($taskTamper in @(
        [pscustomobject]@{ XPath = 't:Actions/t:Exec/t:Command'; Value = 'C:\Windows\System32\cmd.exe'; Pattern = 'launcher'; Name = 'wrong task action' },
        [pscustomobject]@{ XPath = 't:Principals/t:Principal/t:UserId'; Value = 'S-1-5-18'; Pattern = 'principal'; Name = 'wrong task principal' },
        [pscustomobject]@{ XPath = 't:Settings/t:Priority'; Value = '5'; Pattern = 'Priority'; Name = 'wrong fixed task setting' }
    )) {
        Reset-Fixtures
        Set-TaskNodeText -XPath $taskTamper.XPath -Value $taskTamper.Value
        $result = Invoke-Manager -TaskFingerprint (Get-TaskFingerprint)
        Assert-FailedClosed -Result $result -Pattern $taskTamper.Pattern -Message $taskTamper.Name
    }
    Reset-Fixtures
    $baselineFingerprint = Get-TaskFingerprint
    Set-TaskNodeText -XPath 't:Triggers/t:CalendarTrigger/t:StartBoundary' -Value '2026-07-20T03:00:00'
    $staleTask = Invoke-Manager -TaskFingerprint $baselineFingerprint
    Assert-FailedClosed -Result $staleTask -Pattern 'changed after.*reviewed' -Message 'stale task fingerprint'

    Reset-Fixtures
    $status = Read-Json -Path $script:statusPath
    $status.cancel_channel_id = 'invalid-channel'
    Write-Json -Path $script:statusPath -Value $status
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'channel identity' -Message 'invalid channel ID'
    Reset-Fixtures
    $status = Read-Json -Path $script:statusPath
    $status.cancel_channel_fingerprint = 'f' * 64
    Write-Json -Path $script:statusPath -Value $status
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'fingerprint' -Message 'tampered channel fingerprint'

    foreach ($channelTamper in @(
        [pscustomobject]@{ Field = 'exists'; Value = $false; Pattern = 'does not exist'; Name = 'missing event' },
        [pscustomobject]@{ Field = 'open_denied'; Value = $true; Pattern = 'denied'; Name = 'medium-token/open failure' },
        [pscustomobject]@{ Field = 'owner_sid'; Value = 'S-1-5-18'; Pattern = 'security descriptor'; Name = 'wrong event owner' },
        [pscustomobject]@{ Field = 'unexpected_ace'; Value = $true; Pattern = 'security descriptor'; Name = 'unexpected event ACE' },
        [pscustomobject]@{ Field = 'event_name'; Value = 'Local\ResticBackuper.Cancel.' + ('d' * 64); Pattern = 'identity'; Name = 'wrong event object' },
        [pscustomobject]@{ Field = 'required_rights'; Value = 2; Pattern = 'access mask'; Name = 'wrong event rights' },
        [pscustomobject]@{ Field = 'signal_failure'; Value = $true; Pattern = 'could not be signaled'; Name = 'event Set failure' }
    )) {
        Reset-Fixtures
        $channel = Read-Json -Path $script:channelPath
        $channel.$($channelTamper.Field) = $channelTamper.Value
        Write-Json -Path $script:channelPath -Value $channel
        $result = Invoke-Manager
        Assert-FailedClosed -Result $result -Pattern $channelTamper.Pattern -Message $channelTamper.Name
    }

    foreach ($securityTamper in @(
        [pscustomobject]@{ Key = 'manager'; Field = 'reparse'; Value = $true; Pattern = 'identity is unsafe'; Name = 'manager reparse/symlink' },
        [pscustomobject]@{ Key = 'install_root'; Field = 'owner_sid'; Value = 'S-1-5-18'; Pattern = 'owner is unsafe'; Name = 'Program Files owner' },
        [pscustomobject]@{ Key = 'state_root'; Field = 'user_write'; Value = $true; Pattern = 'unsafe ACL capability'; Name = 'ProgramData user-write ACL' },
        [pscustomobject]@{ Key = 'status'; Field = 'owner_sid'; Value = 'S-1-5-19'; Pattern = 'owner is unsafe'; Name = 'status owner' },
        [pscustomobject]@{ Key = 'status'; Field = 'reparse'; Value = $true; Pattern = 'identity is unsafe'; Name = 'status reparse/symlink' },
        [pscustomobject]@{ Key = 'launcher'; Field = 'path'; Value = 'C:\Windows\System32\cmd.exe'; Pattern = 'identity is unsafe'; Name = 'protected path substitution' }
    )) {
        Reset-Fixtures
        $security = Read-Json -Path $script:securityPath
        $security.paths.$($securityTamper.Key).$($securityTamper.Field) = $securityTamper.Value
        Write-Json -Path $script:securityPath -Value $security
        $result = Invoke-Manager
        Assert-FailedClosed -Result $result -Pattern $securityTamper.Pattern -Message $securityTamper.Name
    }

    Reset-Fixtures
    $status = Read-Json -Path $script:statusPath
    $status.wrapper_start_filetime = 134139123456789012
    Write-Json -Path $script:statusPath -Value $status
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'decimal string' -Message 'numeric wrapper FILETIME'
    Reset-Fixtures
    $status = Read-Json -Path $script:statusPath
    $status.cancel_signal_sent_utc = '2026-07-20T22:46:00Z'
    Write-Json -Path $script:statusPath -Value $status
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'without acknowledgement' -Message 'signal timestamp without wrapper acknowledgement'
    Reset-Fixtures
    $status = Read-Json -Path $script:statusPath
    $status.state = 'cancelling'
    Write-Json -Path $script:statusPath -Value $status
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'lacks wrapper acknowledgement' -Message 'cancelling state without acknowledgement'
    Reset-Fixtures
    $status = Read-Json -Path $script:statusPath
    $status.cancel_requested_utc = '2026-07-20T22:46:00Z'
    $status.cancel_outcome = 'finished_before_cancellation_took_effect'
    Write-Json -Path $script:statusPath -Value $status
    Assert-FailedClosed -Result (Invoke-Manager) -Pattern 'already resolved' -Message 'resolved active cancellation channel reuse'
    Reset-Fixtures
    Write-Json -Path $script:statusPath -Value (New-TerminalStatus -State 'cancel_failed' -ExitCode 1 -CancelOutcome 'ctrl_break_signal_failed')
    [IO.File]::WriteAllText($script:taskStatePath, 'Ready', $encoding)
    $cancelFailed = Invoke-Manager
    Assert-True -Condition ($cancelFailed.ExitCode -eq 0 -and [bool]$cancelFailed.Json.already_finished -and
        -not [bool]$cancelFailed.Json.requested) -Message 'cancel_failed is terminal and never signaled'

    Reset-Fixtures
    $wrongSid = Invoke-Manager -ExpectedSid 'S-1-5-18'
    Assert-FailedClosed -Result $wrongSid -Pattern 'same Windows account' -Message 'same-SID binding'

    $managerText = Get-Content -LiteralPath $sourceManager -Raw
    foreach ($marker in @(
        '#requires -Version 5.1',
        "`$productName = 'ResticBackuper'",
        "`$taskName = 'ResticBackuper'",
        'ResticBackuper.BackupControlRequest.v1',
        'EventWaitHandle]::OpenExisting',
        'EventWaitHandleRights]::ReadPermissions',
        'EventWaitHandleRights]::Modify',
        'EventWaitHandleRights]::Synchronize',
        'Assert-EventSecurity',
        'ScheduledTasks\Export-ScheduledTask',
        'ScheduledTasks\Get-ScheduledTask'
    )) {
        Assert-True -Condition ($managerText.Contains($marker)) -Message "manager security marker exists: $marker"
    }
    foreach ($forbidden in @(
        'Stop-ScheduledTask',
        'Start-ScheduledTask',
        'schtasks',
        '/End',
        'TerminateProcess',
        'Register-ScheduledTask',
        'restic.exe',
        'backup.py',
        'dry_run.py',
        '.Kill('
    )) {
        Assert-True -Condition ($managerText.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -lt 0) `
            -Message "manager excludes direct backup/task/process control: $forbidden"
    }

    $global:LASTEXITCODE = 0
    [pscustomobject]@{
        ok = $true
        tests = $script:testCount
        valid_unique_event_signal = 'passed'
        stale_run_pid_process = 'passed'
        task_identity_fingerprint = 'passed'
        program_files_program_data_security = 'passed'
        status_and_channel_tampering = 'passed'
        race_already_finished = 'passed'
        result_digest_nonce_sid = 'passed'
        task_scheduler_adapter_only = $true
        process_adapter_only = $true
        event_adapter_only = $true
        production_task_or_run_touched = $false
    } | ConvertTo-Json -Depth 3
}
finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $safePrefix = $temporaryRoot + '\ResticBackuper-BackupManager-'
    if ($resolved.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
