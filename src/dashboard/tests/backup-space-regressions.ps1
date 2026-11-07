# Backup drive space (the Backup location card) on the built dashboard. Dot-sourced by restore-flow-regressions.ps1, which loads the
# executable and the helpers used here (Assert-True, Invoke-Private, Set-PrivateField, New-TelemetryFixture, New-SyntheticConfiguration)
# and moves every engine folder under its temporary folder first. Nothing here reads a real backup drive or backup folder: the only drive
# that is asked is the one holding the temporary folder, and only its root (free space and size, no listing).
if ($null -eq $dashboardType -or $null -eq $readerType) {
    throw 'Run backup-space-regressions.ps1 through restore-flow-regressions.ps1, which loads the built dashboard.'
}

$spaceGiB = [long]1073741824
$spaceFactsType = $assembly.GetType('ResticBackuper.Dashboard.BackupSpaceFacts', $true)
$spaceEvaluatorType = $assembly.GetType('ResticBackuper.Dashboard.BackupSpaceEvaluator', $true)
$spaceStoreType = $assembly.GetType('ResticBackuper.Dashboard.DashboardSpaceWarningStore', $true)
$spaceViewType = $assembly.GetType('ResticBackuper.Dashboard.RunMetricView', $true)
$spaceSnapshotType = $assembly.GetType('ResticBackuper.Dashboard.TelemetrySnapshot', $true)
$spaceThemeType = $assembly.GetType('ResticBackuper.Dashboard.DashboardThemeManager', $true)

# Like Invoke-Static, but every argument is handed over as the object itself: a value PowerShell keeps in a wrapper (a parsed JSON
# document, for one) would otherwise reach the method as that wrapper. Out arguments are copied back, as Invoke-Static does.
function Invoke-SpaceStatic([Type]$Type, [string]$Name, [object[]]$Arguments = @()) {
    $method = $Type.GetMethod($Name, $flags)
    if ($null -eq $method) { throw "Missing static method: $Name" }
    $invokeArguments = New-Object 'object[]' $Arguments.Count
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        if ($null -ne $Arguments[$index]) { $invokeArguments[$index] = $Arguments[$index].PSObject.BaseObject }
    }
    $result = $method.Invoke($null, $invokeArguments)
    for ($index = 0; $index -lt $Arguments.Count; $index++) { $Arguments[$index] = $invokeArguments[$index] }
    return $result
}

# What the backups take, from last-success.json: measured by the Rewindle engine, estimated from Google Drive's count before the run
# plus what it saved (both engines' shapes), and nothing at all for a value that is not a whole number of bytes.
function Get-SpaceBackupsBytes([string]$Json) {
    $document = $jsonSerializer.DeserializeObject($Json)
    $arguments = @($document, $false)
    $bytes = Invoke-SpaceStatic $readerType 'ReadBackupsBytes' $arguments
    return [pscustomobject]@{ Bytes = [long]$bytes; Estimated = [bool]$arguments[1] }
}
$measured = Get-SpaceBackupsBytes '{"repository_bytes_after":227633266688}'
Assert-True ($measured.Bytes -eq 227633266688 -and -not $measured.Estimated) 'the size a verified backup measured was not read as measured'
$counted = Get-SpaceBackupsBytes '{"repository_bytes_after":null,"repository_readiness":{"total_bytes":1000},"summary":{"data_added_packed":24,"data_added":99}}'
Assert-True ($counted.Bytes -eq 1024 -and $counted.Estimated) 'the Google Drive count plus the saved data was not read as an estimate'
$legacyCounted = Get-SpaceBackupsBytes '{"repository_storage_preflight":{"total_bytes":1000},"summary":{"data_added":24}}'
Assert-True ($legacyCounted.Bytes -eq 1024 -and $legacyCounted.Estimated) 'the earlier edition''s Google Drive count was not read'
foreach ($odd in @('{}', '{"repository_bytes_after":"123"}', '{"repository_bytes_after":-5}', '{"repository_bytes_after":true}',
        '{"repository_bytes_after":1.5}', '{"repository_bytes_after":1e30}', '{"repository_readiness":{"total_bytes":"1000"}}',
        '{"repository_readiness":{"total_bytes":true}}', '{"repository_storage_preflight":{"total_bytes":-1}}')) {
    $read = Get-SpaceBackupsBytes $odd
    Assert-True ($read.Bytes -eq -1 -and -not $read.Estimated) ('a value that is not a size was read as one: ' + $odd)
}
Assert-True ((Get-SpaceBackupsBytes 'null').Bytes -eq -1) 'a missing last-success.json gave a size'

# The reserve and the storage mode, from the plan, the way the engine reads them, and never a reason to refuse the plan.
function Get-SpaceSettings([string]$Json) {
    $arguments = @($jsonSerializer.DeserializeObject($Json), $null, $null)
    [void](Invoke-SpaceStatic $configurationType 'ReadSpaceSettings' $arguments)
    return [pscustomobject]@{ Mode = [string]$arguments[1]; Reserve = [long]$arguments[2] }
}
$tenGiB = Get-SpaceSettings '{"minimum_free_gib":10}'
Assert-True ($tenGiB.Reserve -eq 10 * $spaceGiB -and $tenGiB.Mode -eq 'local_ntfs') 'a reserve of 10 GiB was not read as 10 GiB on a drive'
$halves = Get-SpaceSettings '{"minimum_free_gib":2.5,"repository_storage_mode":"google_drivefs_stream"}'
Assert-True ($halves.Reserve -eq 2684354560 -and $halves.Mode -eq 'google_drivefs_stream') 'a fractional reserve or the Google Drive mode was not read'
foreach ($odd in @('{}', '{"minimum_free_gib":"10"}', '{"minimum_free_gib":-1}', '{"minimum_free_gib":true}', '{"minimum_free_gib":1e40}',
        '{"minimum_free_gib":null}', '{"repository_storage_mode":"something_else"}')) {
    $settings = Get-SpaceSettings $odd
    Assert-True ($settings.Reserve -eq -1 -and $settings.Mode -eq 'local_ntfs') ('an unusable reserve or mode was read as one: ' + $odd)
}
$noDocument = Get-SpaceSettings 'null'
Assert-True ($noDocument.Reserve -eq -1 -and $noDocument.Mode -eq 'local_ntfs') 'a missing document gave a reserve'

# The size reaches the snapshot, a failed run keeps its failure code, and each run in the history says what kind it was and when it finished.
$spaceFixture = New-TelemetryFixture
Write-TelemetryStatus $spaceFixture.State 'run-space' 'success'
[IO.File]::WriteAllText((Join-Path $spaceFixture.State 'last-success.json'), '{"schema_version":1,"run_id":"run-space","state":"success","repository_bytes_after":5000}', $utf8)
$spaceLoad = $spaceFixture.Reader.Load()
Assert-True ($spaceLoad.BackupsBytes -eq 5000 -and -not $spaceLoad.BackupsBytesEstimated) 'the measured size in last-success.json did not reach the snapshot'
$spaceRun = @($spaceLoad.History | Where-Object { $_.RunId -eq 'run-space' })
Assert-True ($spaceRun.Count -eq 1 -and $spaceRun[0].TypeKey -eq 'backup' -and $spaceRun[0].FinishedUtc -gt $spaceRun[0].StartedLocal.ToUniversalTime()) 'a run in the history did not carry its kind and finish time'
Assert-True ($spaceLoad.FailureCode -eq '') 'a verified run carried a failure code'
$lowSpaceStarted = [DateTime]::UtcNow.AddMinutes(-3)
[IO.File]::WriteAllText((Join-Path $spaceFixture.State 'status.json'), $jsonSerializer.Serialize(@{
    'schema_version' = 1; 'run_id' = 'run-low-space'; 'state' = 'failed'; 'failure_code' = 'repository_low_space'
    'started_utc' = $lowSpaceStarted.ToString('o'); 'finished_utc' = $lowSpaceStarted.AddSeconds(5).ToString('o'); 'summary' = @{}
}), $utf8)
$lowSpaceLoad = $spaceFixture.Reader.Load()
Assert-True ($lowSpaceLoad.IsFailure -and $lowSpaceLoad.FailureCode -eq 'repository_low_space') 'a run stopped for lack of space did not keep its failure code'
Assert-True ($lowSpaceLoad.StatusDetail -match 'never anything inside the backup folder') ('the low-space failure did not say to leave the backup folder alone: ' + $lowSpaceLoad.StatusDetail)
Assert-True ($lowSpaceLoad.BackupsBytes -eq 5000) 'a failed run lost the size of the last verified backup'

# The page's state: every key, the empty display of an unknown figure, and only words from fixed lists.
function New-SpaceFacts([hashtable]$Values) {
    $facts = [Activator]::CreateInstance($spaceFactsType)
    foreach ($name in $Values.Keys) { $spaceFactsType.GetProperty($name).SetValue($facts, $Values[$name]) }
    return $facts
}
$okFacts = New-SpaceFacts @{ Reading = 'ready'; Drive = 'D:'; FreeBytes = 96 * $spaceGiB; TotalBytes = 931 * $spaceGiB; ReserveBytes = 10 * $spaceGiB; BackupsBytes = [long]-1; HistoryReadable = $true }
$okResult = Invoke-SpaceStatic $spaceEvaluatorType 'Evaluate' @($okFacts)
$okState = Invoke-SpaceStatic $dashboardType 'SerializeWebSpaceState' @($okFacts, $okResult)
foreach ($key in @('kind', 'reading', 'drive', 'freeBytes', 'freeDisplay', 'totalBytes', 'totalDisplay', 'backupsBytes', 'backupsDisplay',
        'backupsEstimated', 'reserveBytes', 'reserveDisplay', 'forecast', 'level', 'reason', 'warnWeeks', 'runStoppedForSpace')) {
    Assert-True ($okState.ContainsKey($key)) ('the backup space state has no ' + $key)
}
foreach ($key in @('state', 'weeksLeft', 'weeksRounded', 'weeklyBytes', 'weeklyDisplay')) {
    Assert-True ($okState['forecast'].ContainsKey($key)) ('the backup space forecast has no ' + $key)
}
Assert-True ($okState['kind'] -eq 'drive' -and $okState['reading'] -eq 'ready' -and $okState['drive'] -eq 'D:') 'the backup space state did not name the drive'
Assert-True ($okState['freeBytes'] -eq 96 * $spaceGiB -and $okState['freeDisplay'] -match '^96[.,]0 GiB$' -and $okState['totalDisplay'] -eq '931 GiB') 'the free space and size were not sent with their displays'
Assert-True ($okState['backupsBytes'] -eq -1 -and $okState['backupsDisplay'] -eq '' -and -not $okState['backupsEstimated']) 'an unknown size had a display'
Assert-True ($okState['level'] -eq 'low' -and $okState['reason'] -eq 'percent' -and $okState['forecast']['state'] -eq 'learning') ('a nearly full drive with no forecast was not low: ' + $okState['level'] + '/' + $okState['reason'])
Assert-True ($null -eq $okState['forecast']['weeksLeft'] -and $okState['forecast']['weeklyDisplay'] -eq '' -and $okState['warnWeeks'] -eq 8) 'a learning forecast sent a number of weeks'
$okJson = $jsonSerializer.Serialize($okState)
Assert-True ($okJson -match '"weeksLeft":null' -and $okJson -notmatch [regex]::Escape($tempRoot)) 'the backup space state did not serialize as the page expects'

# The card on the built window: the Rewindle engine forecasts, the earlier personal edition says it cannot, a run in progress keeps
# what was said before it (never a "too full" its own writes caused), and a run that failed for lack of space is told to the page.
$spaceConfig = New-SyntheticConfiguration $installRoot $planConfigurationFile $repositoryRoot $stateRoot @($sourceRoot)
$configurationType.GetField('<MinimumFreeBytes>k__BackingField', $flags).SetValue($spaceConfig, [long](10 * $spaceGiB))
$configurationType.GetField('<RepositoryStorageMode>k__BackingField', $flags).SetValue($spaceConfig, 'local_ntfs')
$spaceHistory = New-GenericList $spaceViewType
foreach ($day in 0..14) {
    $view = [Activator]::CreateInstance($spaceViewType)
    $view.RunId = 'space-run-' + $day
    $view.TypeKey = 'backup'
    $view.Success = $true
    $view.FinishedUtc = [DateTime]::SpecifyKind([DateTime]'2026-10-01T02:10:00', [DateTimeKind]::Utc).AddDays($day)
    $view.StoredBytes = $spaceGiB
    [void]$spaceHistory.Add($view)
}
$spaceSnapshot = [Activator]::CreateInstance($spaceSnapshotType)
$spaceSnapshot.History = $spaceHistory
$spaceSnapshot.BackupsBytes = 212 * $spaceGiB
$spaceWindow = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
Set-PrivateField $spaceWindow 'currentSourceConfiguration' $spaceConfig
Set-PrivateField $spaceWindow 'lastSnapshot' $spaceSnapshot
Set-PrivateField $spaceWindow 'repositoryVolumePath' ([string]$repositoryRoot)
Set-PrivateField $spaceWindow 'repositoryVolumeReady' $true
Set-PrivateField $spaceWindow 'repositoryVolumeRead' $true
Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](96 * $spaceGiB))
Set-PrivateField $spaceWindow 'repositoryVolumeTotalBytes' ([long](931 * $spaceGiB))
Set-PrivateField $spaceWindow 'spaceWarningWeeks' 8
$rewindleSpace = Invoke-Private $spaceWindow 'BuildWebSpaceState'
Assert-True ($rewindleSpace['forecast']['state'] -eq 'growing' -and $rewindleSpace['level'] -eq 'ok' -and $rewindleSpace['backupsBytes'] -eq 212 * $spaceGiB) ('the Rewindle engine''s card did not forecast: ' + $rewindleSpace['forecast']['state'] + '/' + $rewindleSpace['level'])
Assert-True ([double]$rewindleSpace['forecast']['weeksLeft'] -eq 12.29 -and $rewindleSpace['forecast']['weeksRounded'] -eq 12) ('the weeks left were not (96 - 10) GiB at 7 GiB a week: ' + $rewindleSpace['forecast']['weeksLeft'])
$forecastsProperty = $engineProfileType.GetProperty('ForecastsBackupSpace', $flags)
$rewindleProfile = $engineProfileType.GetProperty('Rewindle', $flags).GetValue($null)
$legacyProfile = $engineProfileType.GetProperty('Legacy', $flags).GetValue($null)
Assert-True ([bool]$forecastsProperty.GetValue($rewindleProfile) -and -not [bool]$forecastsProperty.GetValue($legacyProfile)) 'only the Rewindle engine forecasts the backup drive'
[void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($legacyProfile))
try {
    $spaceSnapshot.BackupsBytes = -1
    Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](412 * $spaceGiB))
    $legacySpace = Invoke-Private $spaceWindow 'BuildWebSpaceState'
    Assert-True ($legacySpace['forecast']['state'] -eq 'unavailable' -and $legacySpace['level'] -eq 'ok' -and $legacySpace['backupsBytes'] -eq -1) ('the earlier edition was given a forecast: ' + $legacySpace['forecast']['state'] + '/' + $legacySpace['level'])
    Assert-True ($null -eq $legacySpace['forecast']['weeksLeft'] -and $legacySpace['freeBytes'] -eq 412 * $spaceGiB -and $legacySpace['reserveBytes'] -eq 10 * $spaceGiB) 'the earlier edition lost what the dashboard reads itself'
    Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](5 * $spaceGiB))
    $legacyFull = Invoke-Private $spaceWindow 'BuildWebSpaceState'
    Assert-True ($legacyFull['level'] -eq 'full' -and $legacyFull['reason'] -eq 'reserve') 'the earlier edition was not told its drive is too full for the next backup'
    # Only the reserve rules: a drive mostly full of other files is not amber for good there, since no warning choice could tune it.
    Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](60 * $spaceGiB))
    $legacyRoomy = Invoke-Private $spaceWindow 'BuildWebSpaceState'
    Assert-True ($legacyRoomy['level'] -eq 'ok' -and $legacyRoomy['reason'] -eq '') ('the earlier edition was amber with 60 GiB free above a 10 GiB reserve: ' + $legacyRoomy['level'] + '/' + $legacyRoomy['reason'])
    Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](14 * $spaceGiB))
    $legacyLow = Invoke-Private $spaceWindow 'BuildWebSpaceState'
    Assert-True ($legacyLow['level'] -eq 'low' -and $legacyLow['reason'] -eq 'percent') 'the earlier edition was not warned below 1.5 times the reserve'
    # Started while a backup runs, with nothing said before it: there is still no forecast, so Settings offers no Low space warning.
    Set-PrivateField $spaceWindow 'idleSpaceResult' $null
    Set-PrivateField $spaceWindow 'idleSpacePath' $null
    $spaceSnapshot.IsActive = $true
    $legacyStartedDuringRun = Invoke-Private $spaceWindow 'BuildWebSpaceState'
    Assert-True ($legacyStartedDuringRun['forecast']['state'] -eq 'unavailable' -and $legacyStartedDuringRun['level'] -eq 'unknown') ('the earlier edition, started during a backup, was given a forecast to tune: ' + $legacyStartedDuringRun['forecast']['state'] + '/' + $legacyStartedDuringRun['level'])
}
finally {
    [void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($engineProfileType.GetProperty('Rewindle', $flags).GetValue($null)))
    $spaceSnapshot.BackupsBytes = 212 * $spaceGiB
    $spaceSnapshot.IsActive = $false
}
# On the Rewindle engine the same start during a run has a forecast to come, so the warning choice stays.
Set-PrivateField $spaceWindow 'idleSpaceResult' $null
Set-PrivateField $spaceWindow 'idleSpacePath' $null
$spaceSnapshot.IsActive = $true
$rewindleStartedDuringRun = Invoke-Private $spaceWindow 'BuildWebSpaceState'
Assert-True ($rewindleStartedDuringRun['forecast']['state'] -eq 'unknown' -and $rewindleStartedDuringRun['level'] -eq 'unknown') ('the Rewindle engine, started during a backup, did not wait for the run to end: ' + $rewindleStartedDuringRun['forecast']['state'] + '/' + $rewindleStartedDuringRun['level'])
$spaceSnapshot.IsActive = $false
$fullBeforeRun = Invoke-Private $spaceWindow 'BuildWebSpaceState'
Assert-True ($fullBeforeRun['level'] -eq 'full') 'a drive below the reserve was not too full'
$spaceSnapshot.IsActive = $true
$duringRun = Invoke-Private $spaceWindow 'BuildWebSpaceState'
Assert-True ($duringRun['level'] -eq 'unknown' -and $duringRun['freeBytes'] -eq 5 * $spaceGiB) 'a running backup was called too full, or its figures stopped moving'
Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](40 * $spaceGiB))
$spaceSnapshot.IsActive = $false
$lowBeforeRun = Invoke-Private $spaceWindow 'BuildWebSpaceState'
Assert-True ($lowBeforeRun['level'] -eq 'low' -and $lowBeforeRun['reason'] -eq 'forecast') 'a drive full within the warning was not low'
$spaceSnapshot.IsActive = $true
Set-PrivateField $spaceWindow 'repositoryVolumeFreeBytes' ([long](2 * $spaceGiB))
$heldLow = Invoke-Private $spaceWindow 'BuildWebSpaceState'
Assert-True ($heldLow['level'] -eq 'low' -and $heldLow['reason'] -eq 'forecast' -and $heldLow['freeBytes'] -eq 2 * $spaceGiB) 'a running backup did not keep the warning it had, with live figures'
$spaceSnapshot.IsActive = $false
$spaceSnapshot.IsFailure = $true
$spaceSnapshot.FailureCode = 'repository_low_space'
Assert-True ([bool](Invoke-Private $spaceWindow 'BuildWebSpaceState')['runStoppedForSpace']) 'a run stopped for lack of space was not told to the page'
$spaceSnapshot.IsFailure = $false
Set-PrivateField $spaceWindow 'repositoryVolumeRead' $false
Assert-True ((Invoke-Private $spaceWindow 'BuildWebSpaceState')['reading'] -eq 'checking') 'a drive not read yet was not still being checked'
Set-PrivateField $spaceWindow 'repositoryVolumeRead' $true
Set-PrivateField $spaceWindow 'repositoryVolumePath' ([string](Join-Path $tempRoot 'another-location'))
Assert-True ((Invoke-Private $spaceWindow 'BuildWebSpaceState')['reading'] -eq 'checking') 'a reading of the previous location was used for a new one'
Set-PrivateField $spaceWindow 'currentSourceConfiguration' $null
Assert-True ($null -eq (Invoke-Private $spaceWindow 'BuildWebSpaceState')) 'a window with no plan sent a backup space state'

# The Low space warning: exactly 4, 8 or 12 weeks, kept beside the theme file, and anything odd in that file is the default.
function Test-SpaceWarningPayload([object]$Weeks) {
    $payload = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    if ($null -ne $Weeks) { $payload['weeks'] = $Weeks }
    $arguments = @($payload, 0)
    $accepted = [bool](Invoke-SpaceStatic $dashboardType 'TryParseSpaceWarningWeeks' $arguments)
    return [pscustomobject]@{ Accepted = $accepted; Weeks = [int]$arguments[1] }
}
foreach ($weeks in @('4', '8', '12')) {
    $parsed = Test-SpaceWarningPayload $weeks
    Assert-True ($parsed.Accepted -and $parsed.Weeks -eq [int]$weeks) ('the Low space warning refused ' + $weeks + ' weeks')
}
foreach ($weeks in @('5', '', 'eight', ' 8', '08', $null)) {
    Assert-True (-not (Test-SpaceWarningPayload $weeks).Accepted) ('the Low space warning took ' + [string]$weeks)
}
Assert-True ((Invoke-SpaceStatic $dashboardType 'SpaceWarningAnswer' @(8, $false)) -eq 'Rewindle will warn you 8 weeks before the backup drive is full.') 'the answer for a drive was not the expected sentence'
Assert-True ((Invoke-SpaceStatic $dashboardType 'SpaceWarningAnswer' @(4, $true)) -eq 'Rewindle will warn you 4 weeks before your Google storage is full.') 'the answer for Google storage was not the expected sentence'

$spaceSettingsFolder = [string](Join-Path $tempRoot 'space-warning-settings')
$spaceOverride = $spaceThemeType.GetField('settingsDirectoryOverride', $flags)
$spaceOverrideBefore = $spaceOverride.GetValue($null)
try {
    [void]$spaceThemeType.GetMethod('UseSettingsRootForSmokeTesting', $flags).Invoke($null, [object[]]@($spaceSettingsFolder))
    $spaceStorePath = [string](Invoke-SpaceStatic $spaceStoreType 'GetPath')
    Assert-True ($spaceStorePath -eq (Join-Path $spaceSettingsFolder 'space-warning.json')) ('the Low space warning is not kept beside the theme file: ' + $spaceStorePath)
    function Get-StoredSpaceWarning {
        $arguments = @(0)
        $found = [bool](Invoke-SpaceStatic $spaceStoreType 'TryLoad' $arguments)
        return [pscustomobject]@{ Found = $found; Weeks = [int]$arguments[0] }
    }
    $nothingStored = Get-StoredSpaceWarning
    Assert-True (-not $nothingStored.Found -and $nothingStored.Weeks -eq 8) 'with nothing kept the Low space warning was not 8 weeks'
    Assert-True ([bool](Invoke-SpaceStatic $spaceStoreType 'TrySave' @(4))) 'the Low space warning could not be kept'
    $stored = Get-StoredSpaceWarning
    Assert-True ($stored.Found -and $stored.Weeks -eq 4) 'the Low space warning that was kept was not read back'
    Assert-True ([IO.File]::ReadAllText($spaceStorePath) -eq '{"schema_version":1,"warn_weeks":4}') 'the Low space warning file has an unexpected shape'
    Assert-True (-not [bool](Invoke-SpaceStatic $spaceStoreType 'TrySave' @(5))) 'a Low space warning of 5 weeks was kept'
    Assert-True ((Get-StoredSpaceWarning).Weeks -eq 4) 'a refused Low space warning replaced the kept one'
    foreach ($odd in @('not json', '{"schema_version":2,"warn_weeks":4}', '{"schema_version":1,"warn_weeks":5}', '{"schema_version":1,"warn_weeks":"4"}', ('{"schema_version":1,"warn_weeks":4,"pad":"' + ('x' * 5000) + '"}'))) {
        [IO.File]::WriteAllText($spaceStorePath, $odd, $utf8)
        $oddRead = Get-StoredSpaceWarning
        Assert-True (-not $oddRead.Found -and $oddRead.Weeks -eq 8) ('an odd Low space warning file was used: ' + $odd.Substring(0, [Math]::Min(40, $odd.Length)))
    }
}
finally {
    $spaceOverride.SetValue($null, $spaceOverrideBefore)
}

# Only the root of the drive that holds the temporary folder is asked (its free space and size), never a listing.
$driveArguments = @([string]$tempRoot, [long]0, [long]0)
Assert-True ([bool](Invoke-SpaceStatic $dashboardType 'TryReadDriveSpace' $driveArguments)) 'the free space of the temporary folder''s drive could not be read'
Assert-True ([long]$driveArguments[1] -ge 0 -and [long]$driveArguments[2] -gt 0 -and [long]$driveArguments[1] -le [long]$driveArguments[2]) 'the free space read was larger than the drive'
$noDriveArguments = @([string]'relative\folder', [long]0, [long]0)
Assert-True (-not [bool](Invoke-SpaceStatic $dashboardType 'TryReadDriveSpace' $noDriveArguments) -and [long]$noDriveArguments[1] -eq -1) 'a path with no drive gave a free space'
Assert-True ((Invoke-SpaceStatic $dashboardType 'DriveLetterOf' @('d:\Backups\Rewindle')) -eq 'D:' -and (Invoke-SpaceStatic $dashboardType 'DriveLetterOf' @('\\server\share\Backups')) -eq '') 'only a drive letter is published as the drive'
