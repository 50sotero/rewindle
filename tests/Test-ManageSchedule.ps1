#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$sourceManager = Join-Path $projectRoot 'src\Manage-Schedule.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot ('ResticBackuper-ScheduleManager-{0}' -f [Guid]::NewGuid().ToString('N'))
$encoding = [Text.UTF8Encoding]::new($false, $true)
$taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
$dayOrder = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

function Read-TaskDocument {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $script:taskXmlPath }
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    $stringReader = [IO.StringReader]::new([IO.File]::ReadAllText($Path, $encoding))
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
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $script:taskXmlPath }
    $document = Read-TaskDocument -Path $Path
    $payload = 'ResticBackuper.TaskXml.v1' + "`n" + $document.DocumentElement.OuterXml
    return Get-Sha256Hex -Bytes $encoding.GetBytes($payload)
}

function Get-NamespaceManager {
    param([Xml.XmlDocument]$Document)
    $manager = [Xml.XmlNamespaceManager]::new($Document.NameTable)
    $manager.AddNamespace('t', $taskNamespace)
    return ,$manager
}

function Get-PreservedProbe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = $script:taskXmlPath }
    $document = Read-TaskDocument -Path $Path
    $namespaceManager = Get-NamespaceManager -Document $document
    $root = $document.DocumentElement
    $values = [ordered]@{}
    foreach ($entry in ([ordered]@{
        registration = 't:RegistrationInfo'
        principal = 't:Principals'
        action = 't:Actions'
        idle = 't:Settings/t:IdleSettings'
        compatibility = 't:Settings/t:Compatibility'
        multiple_instances = 't:Settings/t:MultipleInstancesPolicy'
        execution_limit = 't:Settings/t:ExecutionTimeLimit'
        priority = 't:Settings/t:Priority'
    }).GetEnumerator()) {
        $node = $root.SelectSingleNode([string]$entry.Value, $namespaceManager)
        if ($null -eq $node) { throw "Fixture probe node is missing: $($entry.Key)" }
        $values[[string]$entry.Key] = $node.OuterXml
    }
    return $values
}

function Assert-ProbesEqual {
    param(
        [Collections.IDictionary]$Expected,
        [Collections.IDictionary]$Actual,
        [string]$Message
    )
    foreach ($key in $Expected.Keys) {
        Assert-True -Condition ([string]$Expected[$key] -eq [string]$Actual[$key]) `
            -Message "$Message ($key)"
    }
}

function New-Nonce {
    return Get-Sha256Hex -Bytes $encoding.GetBytes([Guid]::NewGuid().ToString('N'))
}

function Get-ExpectedRequestDigest {
    param(
        [string]$Sid,
        [string]$ExpectedFingerprint,
        [string]$Cadence,
        [string]$Time,
        [string]$Days,
        [string]$Enabled,
        [string]$StartWhenAvailable,
        [string]$WakeToRun,
        [string]$AllowStartOnBatteries,
        [string]$StopIfGoingOnBatteries,
        [string]$Nonce
    )
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($Days)) {
        foreach ($token in $Days.Split(',')) { [void]$selected.Add($token.Trim()) }
    }
    $canonicalDays = @($dayOrder | Where-Object { $selected.Contains($_) }) -join ','
    $payload = @(
        'ResticBackuper.ScheduleRequest.v1',
        $Sid,
        'apply',
        $ExpectedFingerprint,
        $Cadence.ToLowerInvariant(),
        $Time,
        $canonicalDays,
        $Enabled,
        $StartWhenAvailable,
        $WakeToRun,
        $AllowStartOnBatteries,
        $StopIfGoingOnBatteries,
        $Nonce
    ) -join "`n"
    return Get-Sha256Hex -Bytes $encoding.GetBytes($payload)
}

function Invoke-Manager {
    param(
        [string]$Cadence,
        [string]$Time,
        [string]$Days,
        [string]$Enabled,
        [string]$StartWhenAvailable,
        [string]$WakeToRun,
        [string]$AllowStartOnBatteries,
        [string]$StopIfGoingOnBatteries,
        [string]$ExpectedFingerprint = (Get-TaskFingerprint),
        [string]$Failure = 'None'
    )
    $nonce = New-Nonce
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:installedManager,
        '-Cadence', $Cadence,
        '-Time', $Time
    )
    if (-not [string]::IsNullOrWhiteSpace($Days)) {
        $arguments += @('-Days', $Days)
    }
    $arguments += @(
        '-Enabled', $Enabled,
        '-StartWhenAvailable', $StartWhenAvailable,
        '-WakeToRun', $WakeToRun,
        '-AllowStartOnBatteries', $AllowStartOnBatteries,
        '-StopIfGoingOnBatteries', $StopIfGoingOnBatteries,
        '-ExpectedCurrentFingerprint', $ExpectedFingerprint,
        '-ExpectedUserSid', $script:userSid,
        '-RequestNonce', $nonce,
        '-TestRoot', $fixtureRoot,
        '-TestFailure', $Failure
    )
    $priorErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $text = (& $powershell @arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorErrorPreference
    }
    try { $json = $text | ConvertFrom-Json }
    catch { throw "Schedule manager did not return JSON. exit=$exitCode output=$text" }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Json = $json
        Text = $text
        Nonce = $nonce
        ExpectedFingerprint = $ExpectedFingerprint
    }
}

function Set-TaskNodeText {
    param([string]$XPath, [string]$Value)
    $document = Read-TaskDocument
    $namespaceManager = Get-NamespaceManager -Document $document
    $node = $document.DocumentElement.SelectSingleNode($XPath, $namespaceManager)
    if ($null -eq $node) { throw "Cannot tamper missing test node: $XPath" }
    $node.InnerText = $Value
    Write-TaskDocument -Document $document
}

function Assert-Schedule {
    param(
        [string]$Cadence,
        [string]$Time,
        [string[]]$Days,
        [bool]$Enabled,
        [bool]$StartWhenAvailable,
        [bool]$WakeToRun,
        [bool]$AllowStartOnBatteries,
        [bool]$StopIfGoingOnBatteries
    )
    $document = Read-TaskDocument
    $namespaceManager = Get-NamespaceManager -Document $document
    $root = $document.DocumentElement
    $boundary = $root.SelectSingleNode('t:Triggers/t:CalendarTrigger/t:StartBoundary', $namespaceManager).InnerText
    Assert-True -Condition ($boundary.Substring(11, 5) -eq $Time) -Message 'installed time'
    $daily = $root.SelectSingleNode('t:Triggers/t:CalendarTrigger/t:ScheduleByDay', $namespaceManager)
    $weekly = $root.SelectSingleNode('t:Triggers/t:CalendarTrigger/t:ScheduleByWeek', $namespaceManager)
    if ($Cadence -eq 'Daily') {
        Assert-True -Condition ($null -ne $daily -and $null -eq $weekly) -Message 'daily trigger shape'
        Assert-True -Condition ($daily.SelectSingleNode('t:DaysInterval', $namespaceManager).InnerText -eq '1') -Message 'daily interval'
    }
    else {
        Assert-True -Condition ($null -eq $daily -and $null -ne $weekly) -Message 'weekly trigger shape'
        $actualDays = @(
            $weekly.SelectSingleNode('t:DaysOfWeek', $namespaceManager).SelectNodes('*') |
                ForEach-Object { $_.LocalName.Substring(0, 3) }
        )
        Assert-True -Condition (($actualDays -join ',') -eq ($Days -join ',')) -Message 'weekly selected days'
        Assert-True -Condition ($weekly.SelectSingleNode('t:WeeksInterval', $namespaceManager).InnerText -eq '1') -Message 'weekly interval'
    }
    $settings = $root.SelectSingleNode('t:Settings', $namespaceManager)
    $xmlEnabled = $settings.SelectSingleNode('t:Enabled', $namespaceManager).InnerText -eq 'true'
    $xmlStart = $settings.SelectSingleNode('t:StartWhenAvailable', $namespaceManager).InnerText -eq 'true'
    $xmlWake = $settings.SelectSingleNode('t:WakeToRun', $namespaceManager).InnerText -eq 'true'
    $xmlAllowBattery = $settings.SelectSingleNode('t:DisallowStartIfOnBatteries', $namespaceManager).InnerText -eq 'false'
    $xmlStopBattery = $settings.SelectSingleNode('t:StopIfGoingOnBatteries', $namespaceManager).InnerText -eq 'true'
    Assert-True -Condition ($xmlEnabled -eq $Enabled) -Message 'installed enabled flag'
    Assert-True -Condition ($xmlStart -eq $StartWhenAvailable) -Message 'installed start-when-available flag'
    Assert-True -Condition ($xmlWake -eq $WakeToRun) -Message 'installed wake flag'
    Assert-True -Condition ($xmlAllowBattery -eq $AllowStartOnBatteries) -Message 'installed allow-start-on-battery flag'
    Assert-True -Condition ($xmlStopBattery -eq $StopIfGoingOnBatteries) -Message 'installed stop-on-battery flag'
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $script:installRoot = Join-Path $fixtureRoot 'ProgramFiles\ResticBackuper'
    $stateRoot = Join-Path $fixtureRoot 'ProgramData\ResticBackuper'
    $adapterRoot = Join-Path $fixtureRoot 'TaskAdapter'
    foreach ($directory in @($script:installRoot, $stateRoot, $adapterRoot)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $script:installedManager = Join-Path $script:installRoot 'Manage-Schedule.ps1'
    Copy-Item -LiteralPath $sourceManager -Destination $script:installedManager
    $launcher = Join-Path $script:installRoot 'ResticBackuperTaskLauncher.exe'
    [IO.File]::WriteAllText($launcher, "fixture launcher`n", $encoding)
    $script:taskXmlPath = Join-Path $adapterRoot 'ResticBackuper.xml'
    $taskStatePath = Join-Path $adapterRoot 'ResticBackuper.state'
    [IO.File]::WriteAllText($taskStatePath, 'Ready', $encoding)
    $script:userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    $escapedLauncher = [Security.SecurityElement]::Escape($launcher)
    $escapedInstallRoot = [Security.SecurityElement]::Escape($script:installRoot)
    $fixtureXml = @"
<Task version="1.4" xmlns="$taskNamespace">
  <RegistrationInfo>
    <Date>2026-07-20T02:00:00</Date>
    <Author>Disposable schedule-manager fixture</Author>
    <Description>Encrypted backup fixture metadata that must be preserved.</Description>
    <URI>\ResticBackuper</URI>
    <SecurityDescriptor>D:P(A;;FA;;;$script:userSid)</SecurityDescriptor>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-07-20T02:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$script:userSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>true</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>true</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <Compatibility>Win8</Compatibility>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>$escapedLauncher</Command><WorkingDirectory>$escapedInstallRoot</WorkingDirectory></Exec>
  </Actions>
</Task>
"@
    [IO.File]::WriteAllText($script:taskXmlPath, $fixtureXml.Trim(), $encoding)
    $originalFixtureXml = [IO.File]::ReadAllText($script:taskXmlPath, $encoding)
    $originalFingerprint = Get-TaskFingerprint
    $originalProbe = Get-PreservedProbe

    $weekly = Invoke-Manager `
        -Cadence 'SelectedDays' -Time '03:45' -Days 'Fri,Mon,Wed' `
        -Enabled '1' -StartWhenAvailable '1' -WakeToRun '0' `
        -AllowStartOnBatteries '0' -StopIfGoingOnBatteries '1' `
        -ExpectedFingerprint $originalFingerprint
    Assert-True -Condition ($weekly.ExitCode -eq 0 -and [bool]$weekly.Json.ok) `
        -Message "selected-days update succeeded: $($weekly.Text)"
    Assert-True -Condition ([bool]$weekly.Json.changed) -Message 'selected-days update reports changed'
    Assert-True -Condition (-not [bool]$weekly.Json.backup_started) -Message 'schedule update explicitly reports no backup start'
    Assert-True -Condition ([string]$weekly.Json.action -eq 'apply') -Message 'result action'
    Assert-True -Condition ([string]$weekly.Json.request_nonce -eq $weekly.Nonce) -Message 'result nonce binding'
    Assert-True -Condition ([string]$weekly.Json.request_user_sid -eq $script:userSid) -Message 'result SID binding'
    Assert-True -Condition ([string]$weekly.Json.expected_current_fingerprint -eq $originalFingerprint) -Message 'result baseline binding'
    $expectedDigest = Get-ExpectedRequestDigest `
        -Sid $script:userSid -ExpectedFingerprint $originalFingerprint `
        -Cadence 'SelectedDays' -Time '03:45' -Days 'Fri,Mon,Wed' `
        -Enabled '1' -StartWhenAvailable '1' -WakeToRun '0' `
        -AllowStartOnBatteries '0' -StopIfGoingOnBatteries '1' -Nonce $weekly.Nonce
    Assert-True -Condition ([string]$weekly.Json.request_digest -eq $expectedDigest) -Message 'canonical request digest'
    Assert-True -Condition ([string]$weekly.Json.schedule.cadence -eq 'SelectedDays') -Message 'result cadence'
    Assert-True -Condition ([string]$weekly.Json.schedule.time -eq '03:45') -Message 'result time'
    Assert-True -Condition ((@($weekly.Json.schedule.days) -join ',') -eq 'Mon,Wed,Fri') -Message 'result canonical selected days'
    Assert-Schedule `
        -Cadence 'SelectedDays' -Time '03:45' -Days @('Mon', 'Wed', 'Fri') `
        -Enabled $true -StartWhenAvailable $true -WakeToRun $false `
        -AllowStartOnBatteries $false -StopIfGoingOnBatteries $true
    Assert-ProbesEqual -Expected $originalProbe -Actual (Get-PreservedProbe) `
        -Message 'weekly update preserved every probed non-schedule field'

    $weeklyFingerprint = Get-TaskFingerprint
    Assert-True -Condition ([string]$weekly.Json.installed_fingerprint -eq $weeklyFingerprint) -Message 'verified installed fingerprint'
    $idempotent = Invoke-Manager `
        -Cadence 'SelectedDays' -Time '03:45' -Days 'Mon,Wed,Fri' `
        -Enabled '1' -StartWhenAvailable '1' -WakeToRun '0' `
        -AllowStartOnBatteries '0' -StopIfGoingOnBatteries '1' `
        -ExpectedFingerprint $weeklyFingerprint
    Assert-True -Condition ($idempotent.ExitCode -eq 0 -and [bool]$idempotent.Json.ok -and -not [bool]$idempotent.Json.changed) `
        -Message 'idempotent request performs no registration'
    Assert-True -Condition ((Get-TaskFingerprint) -eq $weeklyFingerprint) -Message 'idempotent request leaves task unchanged'

    $daily = Invoke-Manager `
        -Cadence 'Daily' -Time '01:30' -Days '' `
        -Enabled '0' -StartWhenAvailable '0' -WakeToRun '1' `
        -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
        -ExpectedFingerprint $weeklyFingerprint
    Assert-True -Condition ($daily.ExitCode -eq 0 -and [bool]$daily.Json.ok) `
        -Message "daily update succeeded: $($daily.Text)"
    Assert-Schedule `
        -Cadence 'Daily' -Time '01:30' -Days @() `
        -Enabled $false -StartWhenAvailable $false -WakeToRun $true `
        -AllowStartOnBatteries $true -StopIfGoingOnBatteries $false
    Assert-ProbesEqual -Expected $originalProbe -Actual (Get-PreservedProbe) `
        -Message 'daily update preserved every probed non-schedule field'

    $dailyFingerprint = Get-TaskFingerprint
    $stale = Invoke-Manager `
        -Cadence 'Daily' -Time '04:00' -Days '' `
        -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
        -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
        -ExpectedFingerprint $originalFingerprint
    Assert-True -Condition ($stale.ExitCode -eq 1 -and -not [bool]$stale.Json.ok -and
        [string]$stale.Json.error -match 'changed after it was reviewed') -Message 'stale baseline rejected'
    Assert-True -Condition ((Get-TaskFingerprint) -eq $dailyFingerprint) -Message 'stale request leaves task unchanged'

    $duplicateDays = Invoke-Manager `
        -Cadence 'SelectedDays' -Time '04:00' -Days 'Mon,mon' `
        -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
        -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
        -ExpectedFingerprint $dailyFingerprint
    Assert-True -Condition ($duplicateDays.ExitCode -eq 1 -and [string]$duplicateDays.Json.error -match 'duplicated') `
        -Message 'duplicate selected day rejected'
    $missingDays = Invoke-Manager `
        -Cadence 'SelectedDays' -Time '04:00' -Days '' `
        -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
        -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
        -ExpectedFingerprint $dailyFingerprint
    Assert-True -Condition ($missingDays.ExitCode -eq 1 -and [string]$missingDays.Json.error -match 'at least one day') `
        -Message 'empty selected-days request rejected'
    Assert-True -Condition ((Get-TaskFingerprint) -eq $dailyFingerprint) -Message 'invalid day requests leave task unchanged'

    [IO.File]::WriteAllText($taskStatePath, 'Running', $encoding)
    try {
        $running = Invoke-Manager `
            -Cadence 'Daily' -Time '05:00' -Days '' `
            -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
            -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
            -ExpectedFingerprint $dailyFingerprint
        Assert-True -Condition ($running.ExitCode -eq 1 -and [string]$running.Json.error -match 'task is Running') `
            -Message 'running task rejected'
        Assert-True -Condition ((Get-TaskFingerprint) -eq $dailyFingerprint) -Message 'running-task rejection leaves task unchanged'
    }
    finally {
        [IO.File]::WriteAllText($taskStatePath, 'Ready', $encoding)
    }

    $validDailyXml = [IO.File]::ReadAllText($script:taskXmlPath, $encoding)
    foreach ($tamper in @(
        [pscustomobject]@{ XPath = 't:Actions/t:Exec/t:Command'; Value = 'C:\Windows\System32\cmd.exe'; Error = 'launcher' },
        [pscustomobject]@{ XPath = 't:Principals/t:Principal/t:UserId'; Value = 'S-1-5-18'; Error = 'principal' },
        [pscustomobject]@{ XPath = 't:Settings/t:Priority'; Value = '5'; Error = 'Priority' },
        [pscustomobject]@{ XPath = 't:Triggers/t:CalendarTrigger/t:StartBoundary'; Value = '2026-07-20T01:30:45'; Error = 'exact minute' }
    )) {
        [IO.File]::WriteAllText($script:taskXmlPath, $validDailyXml, $encoding)
        Set-TaskNodeText -XPath $tamper.XPath -Value $tamper.Value
        $tamperedFingerprint = Get-TaskFingerprint
        $tampered = Invoke-Manager `
            -Cadence 'Daily' -Time '06:00' -Days '' `
            -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
            -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
            -ExpectedFingerprint $tamperedFingerprint
        Assert-True -Condition ($tampered.ExitCode -eq 1 -and [string]$tampered.Json.error -match $tamper.Error) `
            -Message "unsafe baseline rejected: $($tamper.XPath)"
        Assert-True -Condition ((Get-TaskFingerprint) -eq $tamperedFingerprint) `
            -Message "unsafe baseline was not registered: $($tamper.XPath)"
    }
    [IO.File]::WriteAllText($script:taskXmlPath, $validDailyXml, $encoding)
    $dailyFingerprint = Get-TaskFingerprint

    foreach ($failure in @('Verify', 'Register')) {
        $beforeFailure = Get-TaskFingerprint
        $failureResult = Invoke-Manager `
            -Cadence 'SelectedDays' -Time '07:15' -Days 'Tue,Thu' `
            -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
            -AllowStartOnBatteries '0' -StopIfGoingOnBatteries '1' `
            -ExpectedFingerprint $beforeFailure -Failure $failure
        Assert-True -Condition ($failureResult.ExitCode -eq 1 -and -not [bool]$failureResult.Json.ok) `
            -Message "$failure failure returns an error"
        Assert-True -Condition ([bool]$failureResult.Json.rollback_performed -and [bool]$failureResult.Json.rollback_verified) `
            -Message "$failure failure reports verified rollback"
        Assert-True -Condition ([string]$failureResult.Json.error -match 'rolled back') `
            -Message "$failure failure error is explicit"
        Assert-True -Condition ((Get-TaskFingerprint) -eq $beforeFailure) `
            -Message "$failure failure restored the exact baseline fingerprint"
        Assert-ProbesEqual -Expected $originalProbe -Actual (Get-PreservedProbe) `
            -Message "$failure rollback preserved non-schedule fields"
    }

    foreach ($rollbackFailure in @('RollbackRegister', 'RollbackVerify')) {
        [IO.File]::WriteAllText($script:taskXmlPath, $validDailyXml, $encoding)
        $beforeFailure = Get-TaskFingerprint
        $failureResult = Invoke-Manager `
            -Cadence 'SelectedDays' -Time '08:15' -Days 'Tue,Thu' `
            -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
            -AllowStartOnBatteries '0' -StopIfGoingOnBatteries '1' `
            -ExpectedFingerprint $beforeFailure -Failure $rollbackFailure
        Assert-True -Condition ($failureResult.ExitCode -eq 1 -and [bool]$failureResult.Json.rollback_performed -and
            -not [bool]$failureResult.Json.rollback_verified -and [string]$failureResult.Json.error -match 'rollback needs attention') `
            -Message "$rollbackFailure surfaces an unverified rollback"
    }
    [IO.File]::WriteAllText($script:taskXmlPath, $validDailyXml, $encoding)
    $dailyFingerprint = Get-TaskFingerprint

    $lockPath = Join-Path $stateRoot 'run.lock'
    $heldLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $hiddenTaskXml = "$script:taskXmlPath.hidden"
    try {
        if ($heldLock.Length -eq 0) { $heldLock.WriteByte(0); $heldLock.Flush($true) }
        $heldLock.Lock(0, 1)
        Move-Item -LiteralPath $script:taskXmlPath -Destination $hiddenTaskXml
        $locked = Invoke-Manager `
            -Cadence 'Daily' -Time '09:00' -Days '' `
            -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
            -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
            -ExpectedFingerprint $dailyFingerprint
        Assert-True -Condition ($locked.ExitCode -eq 1 -and [string]$locked.Json.error -match 'already running') `
            -Message 'byte-range lock blocks schedule mutation before task-adapter access'
    }
    finally {
        if (Test-Path -LiteralPath $hiddenTaskXml) {
            Move-Item -LiteralPath $hiddenTaskXml -Destination $script:taskXmlPath
        }
        $heldLock.Unlock(0, 1)
        $heldLock.Dispose()
    }

    foreach ($journalName in @('repository-relocation.journal.json', 'plan-migration.journal.json', 'credential-rotation.journal.json')) {
        $journalPath = Join-Path $stateRoot $journalName
        [IO.File]::WriteAllText($journalPath, "{}`n", $encoding)
        try {
            $journalBlocked = Invoke-Manager `
                -Cadence 'Daily' -Time '09:30' -Days '' `
                -Enabled '1' -StartWhenAvailable '1' -WakeToRun '1' `
                -AllowStartOnBatteries '1' -StopIfGoingOnBatteries '0' `
                -ExpectedFingerprint $dailyFingerprint
            Assert-True -Condition ($journalBlocked.ExitCode -eq 1 -and
                [string]$journalBlocked.Json.error -match 'pending protected-operation journal') `
                -Message "$journalName blocks schedule mutation"
            Assert-True -Condition ((Get-TaskFingerprint) -eq $dailyFingerprint) `
                -Message "$journalName leaves task unchanged"
        }
        finally {
            [IO.File]::Delete($journalPath)
        }
    }

    $managerText = Get-Content -LiteralPath $sourceManager -Raw
    Assert-True -Condition ($managerText -match "#requires -Version 5\.1") -Message 'manager pins Windows PowerShell 5.1'
    Assert-True -Condition ($managerText -match '\$env:PSModulePath\s*=\s*\$trustedModuleRoot') -Message 'module search path is restricted'
    Assert-True -Condition ($managerText -match 'ScheduledTasks\\Export-ScheduledTask' -and
        $managerText -match 'ScheduledTasks\\Register-ScheduledTask' -and
        $managerText -match 'ScheduledTasks\\Get-ScheduledTask') -Message 'all task access is module-qualified'
    Assert-True -Condition ($managerText -notmatch '(?i)Start-ScheduledTask|Stop-ScheduledTask|restic\.exe|backup\.py|dry_run\.py') `
        -Message 'schedule manager contains no backup or task-start command'
    Assert-True -Condition ($managerText -match 'ResticBackuper\.TaskXml\.v1' -and
        $managerText -match 'ResticBackuper\.ScheduleRequest\.v1') -Message 'fingerprint and request digest are domain separated'

    $global:LASTEXITCODE = 0
    [pscustomobject]@{
        ok = $true
        tests = 27
        windows_powershell_51 = 'passed'
        selected_days = 'passed'
        daily = 'passed'
        flags = 'passed'
        idempotent = 'passed'
        baseline_binding = 'passed'
        nonce_digest_sid_binding = 'passed'
        exact_task_validation = 'passed'
        preserve_other_xml = 'passed'
        running_rejected = 'passed'
        register_verify_rollback = 'passed'
        rollback_failure_reported = 'passed'
        byte_lock_before_task_access = 'passed'
        no_task_start_or_backup = 'passed'
        task_scheduler_host_access = 'not used (disposable XML adapter only)'
    } | ConvertTo-Json -Depth 3
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $safePrefix = $temporaryRoot + '\ResticBackuper-ScheduleManager-'
    if ($resolvedFixture.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
