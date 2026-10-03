param(
    [string]$ExecutablePath = (Join-Path $PSScriptRoot '..\\dist\\ResticBackuperDashboard.exe'),
    # Never read the installed backup configuration, even when one exists. Continuous integration passes
    # this; without it the few checks that need a real installed plan run only when one is present.
    [switch]$SkipInstalledChecks
)

$ErrorActionPreference = 'Stop'
$flags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic
$constructorFlags = [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::NonPublic
$resolvedExecutable = [IO.Path]::GetFullPath($ExecutablePath)
if (-not (Test-Path -LiteralPath $resolvedExecutable -PathType Leaf)) {
    throw "Restore dashboard executable not found: $resolvedExecutable"
}

$assembly = [Reflection.Assembly]::LoadFrom($resolvedExecutable)
$dashboardType = $assembly.GetType('ResticBackuper.Dashboard.DashboardWindow', $true)
$restoreWindowType = $assembly.GetType('ResticBackuper.Dashboard.RestoreWindow', $true)
$configurationType = $assembly.GetType('ResticBackuper.Dashboard.SourceConfiguration', $true)
$sourceViewType = $assembly.GetType('ResticBackuper.Dashboard.BackupSourceView', $true)
$snapshotType = $assembly.GetType('ResticBackuper.Dashboard.RestoreSnapshot', $true)
$treeEntryType = $assembly.GetType('ResticBackuper.Dashboard.RestoreTreeEntry', $true)
$redactorType = $assembly.GetType('ResticBackuper.Dashboard.DiagnosticRedactor', $true)
$readerType = $assembly.GetType('ResticBackuper.Dashboard.TelemetryReader', $true)
$engineProfileType = $assembly.GetType('ResticBackuper.Dashboard.EngineProfile', $true)
Add-Type -AssemblyName System.Web.Extensions
$jsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$jsonSerializer.MaxJsonLength = [int]::MaxValue

function Get-PrivateField([object]$Target, [string]$Name) {
    $field = $Target.GetType().GetField($Name, $flags)
    if ($null -eq $field) { throw "Missing private field: $Name" }
    return $field
}

function Set-PrivateField([object]$Target, [string]$Name, [object]$Value) {
    (Get-PrivateField $Target $Name).SetValue($Target, $Value)
}

function Get-FieldValue([object]$Target, [string]$Name) {
    return (Get-PrivateField $Target $Name).GetValue($Target)
}

function Invoke-Private([object]$Target, [string]$Name, [object[]]$Arguments = @()) {
    $method = $Target.GetType().GetMethod($Name, $flags)
    if ($null -eq $method) { throw "Missing private method: $Name" }
    $invokeArguments = New-Object object[] $Arguments.Count
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($null -ne $argument -and $argument.GetType().FullName -eq 'System.Management.Automation.PSObject') {
            $invokeArguments[$index] = $argument.PSObject.BaseObject
        }
        else {
            $invokeArguments[$index] = $argument
        }
    }
    $result = $method.Invoke($Target.PSObject.BaseObject, [object[]]$invokeArguments)
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $Arguments[$index] = $invokeArguments[$index]
    }
    return $result
}

function Invoke-Static([Type]$Type, [string]$Name, [object[]]$Arguments = @()) {
    $method = $Type.GetMethod($Name, $flags)
    if ($null -eq $method) { throw "Missing private static method: $Name" }
    $invokeArguments = New-Object object[] $Arguments.Count
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($null -ne $argument -and $argument.GetType().FullName -eq 'System.Management.Automation.PSObject') {
            $invokeArguments[$index] = $argument.PSObject.BaseObject
        }
        else {
            $invokeArguments[$index] = $argument
        }
    }
    $result = $method.Invoke($null, [object[]]$invokeArguments)
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $Arguments[$index] = $invokeArguments[$index]
    }
    return $result
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Regression assertion failed: $Message" }
}

function New-GenericList([Type]$ItemType) {
    return ,([Activator]::CreateInstance([System.Collections.Generic.List``1].MakeGenericType($ItemType)))
}

function New-StringList([string[]]$Items) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Items) { [void]$list.Add($item) }
    return ,$list
}

# A SourceConfiguration that was never read from an installation. Its paths are the caller's, so the
# destination and overlap guards see realistic values and nothing outside the fixture is touched.
function New-SyntheticConfiguration([string]$InstallRoot, [string]$ConfigurationPath, [string]$RepositoryPath, [string]$StateDirectory, [string[]]$SourcePaths) {
    $configuration = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($configurationType)
    $sources = New-GenericList $sourceViewType
    foreach ($sourcePath in $SourcePaths) {
        [void]$sources.Add([Activator]::CreateInstance($sourceViewType, [object[]]@([string]$sourcePath, $false)))
    }
    $values = [ordered]@{
        'InstallRoot' = $InstallRoot
        'ConfigurationPath' = $ConfigurationPath
        'ManagerPath' = [IO.Path]::Combine($InstallRoot, 'Manage-Sources.ps1')
        'RepositoryPath' = $RepositoryPath
        'StateDirectory' = $StateDirectory
        'PlanId' = '4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31'
        'ConfigGeneration' = 1L
        'CloudPlaceholderPolicy' = 'strict'
        'Sources' = $sources
    }
    foreach ($name in $values.Keys) {
        $field = $configurationType.GetField('<' + $name + '>k__BackingField', $flags)
        if ($null -eq $field) { throw "Missing configuration field: $name" }
        $field.SetValue($configuration, $values[$name])
    }
    return $configuration
}

function Test-RestoreDestination([object]$Configuration, [string]$Path) {
    $arguments = New-Object object[] 2
    $arguments[0] = $Configuration
    $arguments[1] = $Path
    $inspection = Invoke-Static $dashboardType 'InspectRestoreFlowDestination' $arguments
    return [bool]$inspection.GetType().GetField('Valid', $flags).GetValue($inspection)
}

# What the destination check tells the person about a path it refused.
function Get-RestoreDestinationMessage([object]$Configuration, [string]$Path) {
    $arguments = New-Object object[] 2
    $arguments[0] = $Configuration
    $arguments[1] = $Path
    $inspection = Invoke-Static $dashboardType 'InspectRestoreFlowDestination' $arguments
    return [string]$inspection.GetType().GetField('Message', $flags).GetValue($inspection)
}

# What the destination check read about the drive of a path: whether it passed, the room the drive had (null when it was not read) and
# the drive's name.
function Get-RestoreDestinationSpace([object]$Configuration, [string]$Path) {
    $arguments = New-Object object[] 2
    $arguments[0] = $Configuration
    $arguments[1] = $Path
    $inspection = Invoke-Static $dashboardType 'InspectRestoreFlowDestination' $arguments
    $inspectionType = $inspection.GetType()
    return [pscustomobject]@{
        Valid = [bool]$inspectionType.GetField('Valid', $flags).GetValue($inspection)
        FreeBytes = $inspectionType.GetField('FreeBytes', $flags).GetValue($inspection)
        Drive = [string]$inspectionType.GetField('Drive', $flags).GetValue($inspection)
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('rewindle-restore-regression-' + [Guid]::NewGuid().ToString('N'))
$junction = Join-Path $tempRoot 'reparse-parent'
$junctionTarget = Join-Path $tempRoot 'junction-target'
New-Item -ItemType Directory -Path $tempRoot, $junctionTarget -Force | Out-Null
$skipped = New-Object System.Collections.Generic.List[string]
# Every Windows folder an engine path is built from (Program Files, ProgramData, %LOCALAPPDATA%, %TEMP%) is moved under the temporary
# folder for the whole run, so nothing below can read or write a real installation, its state or the dashboard's own folder. The
# dashboard refuses a root outside the temporary folder.
$engineFixtureRoot = Join-Path $tempRoot 'engine-roots'
[void]$engineProfileType.GetMethod('UseFolderRootsForTesting', $flags).Invoke($null, [object[]]@([string]$engineFixtureRoot))
[void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($engineProfileType.GetProperty('Rewindle', $flags).GetValue($null)))
try {
    # The backup plan every restore-flow check below runs against: a fixture inside the temporary folder,
    # never the installed configuration.
    $planRoot = Join-Path $tempRoot 'plan'
    $installRoot = Join-Path $planRoot 'install'
    $stateRoot = Join-Path $planRoot 'state'
    $repositoryRoot = Join-Path $planRoot 'repository'
    $sourceRoot = Join-Path $planRoot 'sources\Documents'
    New-Item -ItemType Directory -Path $installRoot, $stateRoot, $repositoryRoot, $sourceRoot -Force | Out-Null
    $planConfigurationFile = Join-Path $installRoot 'backup-config.json'
    [IO.File]::WriteAllText($planConfigurationFile, '{"plan_id":"4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31","config_generation":1,"fixture":true}', (New-Object System.Text.UTF8Encoding($false)))
    $config = New-SyntheticConfiguration $installRoot $planConfigurationFile $repositoryRoot $stateRoot @($sourceRoot)
    $configHash = Invoke-Static $dashboardType 'ComputeRestoreFlowConfigHash' @($config)
    Assert-True ($configHash -match '^[0-9a-f]{64}$') 'the fixture plan did not produce a configuration hash'

    # The installed plan is only consulted for the few checks that re-read it, and never when
    # -SkipInstalledChecks is given.
    $installedConfig = $null
    if ($SkipInstalledChecks) {
        $installedSkip = 'SKIPPED: installed-plan checks were turned off with -SkipInstalledChecks'
    }
    else {
        $installedSkip = 'SKIPPED: no installed backup configuration on this computer'
        # Only this read looks at the real installation (the active engine's protected configuration), and only without
        # -SkipInstalledChecks; the fixture folders are restored straight after it.
        [void]$engineProfileType.GetMethod('UseFolderRootsForTesting', $flags).Invoke($null, [object[]]@([string]$null))
        try {
            $installedSelection = Invoke-Static $engineProfileType 'Select' @([string]$null)
            [void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($installedSelection.Profile))
            try { $installedConfig = Invoke-Static $configurationType 'Load' } catch { $installedConfig = $null }
        }
        finally {
            [void]$engineProfileType.GetMethod('UseFolderRootsForTesting', $flags).Invoke($null, [object[]]@([string]$engineFixtureRoot))
        }
    }

    $dashboard = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
    $snapshotList = New-GenericList $snapshotType
    $treeList = New-GenericList $treeEntryType
    $snapshot = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($snapshotType)
    $snapshotType.GetField('<Id>k__BackingField', $flags).SetValue($snapshot, 'snapshot')
    $snapshotType.GetField('<ShortId>k__BackingField', $flags).SetValue($snapshot, 'snap')
    $snapshotType.GetField('<Time>k__BackingField', $flags).SetValue($snapshot, '2026-09-14T00:00:00Z')
    $snapshotType.GetField('<Hostname>k__BackingField', $flags).SetValue($snapshot, 'regression')
    $snapshotType.GetField('<ConfigGeneration>k__BackingField', $flags).SetValue($snapshot, 1L)
    $snapshotType.GetField('<FileCount>k__BackingField', $flags).SetValue($snapshot, 1L)
    $snapshotType.GetField('<ByteCount>k__BackingField', $flags).SetValue($snapshot, 1L)
    $snapshotType.GetField('<SourceSummary>k__BackingField', $flags).SetValue($snapshot, 'regression')
    $snapshotType.GetField('<BindingState>k__BackingField', $flags).SetValue($snapshot, 'plan_bound')
    [void]$snapshotList.Add($snapshot)
    $observed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $selectedPaths = New-StringList @('/Documents')
    [void]$observed.Add('/Documents')
    Set-PrivateField $dashboard 'restoreFlowSnapshots' $snapshotList
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' $treeList
    Set-PrivateField $dashboard 'restoreFlowObservedPaths' $observed
    Set-PrivateField $dashboard 'restoreFlowSelectedPaths' $selectedPaths
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $true
    Set-PrivateField $dashboard 'restoreFlowTreePath' '/Documents'
    Set-PrivateField $dashboard 'restoreFlowReviewReady' $true
    Set-PrivateField $dashboard 'restoreFlowReviewFingerprint' 'review-token'
    Invoke-Private $dashboard 'SelectRestoreFlowSnapshot' @('new-snapshot') | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowSelectedPaths').Count -eq 0) 'changing snapshots retained selected paths'
    Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowWholeSnapshotSelected')) 'changing snapshots retained whole-snapshot scope'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowObservedPaths').Count -eq 0) 'changing snapshots retained observed browser paths'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreeEntries').Count -eq 0) 'changing snapshots retained tree entries'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreePath') -eq '/') 'changing snapshots retained tree path'
    Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowReviewReady')) 'changing snapshots retained review token'

    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationChecking' $false
    Set-PrivateField $dashboard 'restoreFlowSelectedSnapshotId' 'snapshot'
    Set-PrivateField $dashboard 'restoreFlowSelectedPaths' (New-StringList @())
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationValid' $false
    $validationArgs = [object[]]@($null, $null)
    Invoke-Private $dashboard 'BuildRestoreFlowValidation' $validationArgs | Out-Null
    $validationErrors = $validationArgs[0]
    Assert-True ($validationErrors.Count -ge 2) 'empty restore scope did not produce validation errors'
    Assert-True ([string]::Join(' | ', $validationErrors) -match 'entire snapshot') 'empty restore scope did not explain explicit whole-snapshot selection'
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $true
    $validationArgs = [object[]]@($null, $null)
    Invoke-Private $dashboard 'BuildRestoreFlowValidation' $validationArgs | Out-Null
    Assert-True (-not ([string]::Join(' | ', $validationArgs[0]) -match 'one or more snapshot paths')) 'explicit whole-snapshot scope was still rejected as empty'

    # A whole snapshot larger than the room the destination check found is warned about, never refused: the warning joins the warnings
    # (the errors, which decide whether the restore can go on, are untouched), and only for a whole-snapshot scope of a snapshot that
    # reports its size, for a destination that passed its check and whose drive said how much room it has. The room is a stored figure:
    # nothing here asks a drive.
    $gib = 1073741824L
    $snapshotType.GetField('<ByteCount>k__BackingField', $flags).SetValue($snapshot, 5L * $gib)
    function Get-SpaceValidation([object]$FreeBytes, [bool]$Valid = $true) {
        Set-PrivateField $dashboard 'restoreFlowDestinationValid' $Valid
        Set-PrivateField $dashboard 'restoreFlowDestinationFreeBytes' $FreeBytes
        $spaceArgs = [object[]]@($null, $null)
        Invoke-Private $dashboard 'BuildRestoreFlowValidation' $spaceArgs | Out-Null
        return ,$spaceArgs
    }
    Set-PrivateField $dashboard 'restoreFlowDestinationChecking' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationDrive' 'E:'
    $tight = Get-SpaceValidation ([long]($gib * 3 / 2))
    Assert-True ($tight[1].Count -eq 1 -and ([string]$tight[1][0]) -like 'This snapshot is about * but only * is free on E:. The restore may stop part-way.') ('a whole snapshot larger than the free space did not warn: ' + [string]::Join(' | ', $tight[1]))
    Assert-True ($tight[0].Count -eq 0) 'the free-space warning was reported as an error'
    # Five GiB and a twentieth more is what a whole snapshot of five GiB needs: that much room is enough, one byte less is not.
    Assert-True ((Get-SpaceValidation 5637144576L)[1].Count -eq 0) 'a drive with exactly the room a snapshot needs was warned about'
    Assert-True ((Get-SpaceValidation 5637144575L)[1].Count -eq 1) 'a drive one byte short of the room a snapshot needs was not warned about'
    Assert-True ((Get-SpaceValidation $null)[1].Count -eq 0) 'a drive that would not say how much room it has was warned about'
    Assert-True ((Get-SpaceValidation ([long]1) $false)[1].Count -eq 0) 'a destination that failed its check was warned about its room'
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $false
    Set-PrivateField $dashboard 'restoreFlowSelectedPaths' (New-StringList @('/Documents'))
    Assert-True ((Get-SpaceValidation ([long]1))[1].Count -eq 0) 'a restore of chosen paths was warned about the size of the whole snapshot'
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $true
    Set-PrivateField $dashboard 'restoreFlowSelectedPaths' (New-StringList @())
    $snapshotType.GetField('<ByteCount>k__BackingField', $flags).SetValue($snapshot, 0L)
    Assert-True ((Get-SpaceValidation ([long]1))[1].Count -eq 0) 'a snapshot that does not report its size was warned about'
    $snapshotType.GetField('<ByteCount>k__BackingField', $flags).SetValue($snapshot, 1L)
    Set-PrivateField $dashboard 'restoreFlowDestinationValid' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationFreeBytes' $null
    Set-PrivateField $dashboard 'restoreFlowDestinationDrive' ''

    $forgedPayload = [System.Collections.Generic.Dictionary[string,object]]::new()
    $forgedPayload['snapshotId'] = 'snapshot'
    $forgedPayload['paths'] = '/Forged'
    $forgedPayload['wholeSnapshot'] = $false
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $false
    Set-PrivateField $dashboard 'restoreFlowObservedPaths' (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
    $forgedArgs = [object[]]@($forgedPayload, $null)
    $forgedResult = Invoke-Private $dashboard 'SelectRestoreFlowPaths' $forgedArgs
    Assert-True (-not [bool]$forgedResult) 'unobserved selected path was accepted'

    Set-PrivateField $dashboard 'restoreFlowConfiguration' $config
    Set-PrivateField $dashboard 'restoreFlowConfigHash' $configHash
    Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $config.ConfigGeneration
    Set-PrivateField $dashboard 'restoreFlowPlanId' $config.PlanId
    $reviewPaths = New-StringList @('/Documents')
    $picturePaths = New-StringList @('/Pictures')
    $fingerprintArgsA = New-Object object[] 5
    $fingerprintArgsA[0] = $config
    $fingerprintArgsA[1] = 'snapshot'
    $fingerprintArgsA[2] = $reviewPaths
    $fingerprintArgsA[3] = $false
    $fingerprintArgsA[4] = 'C:\RewindleRestoreRegression'
    $fingerprintA = Invoke-Private $dashboard 'ComputeRestoreFlowReviewFingerprint' $fingerprintArgsA
    $fingerprintArgsB = New-Object object[] 5
    $fingerprintArgsB[0] = $config
    $fingerprintArgsB[1] = 'snapshot'
    $fingerprintArgsB[2] = $picturePaths
    $fingerprintArgsB[3] = $false
    $fingerprintArgsB[4] = 'C:\RewindleRestoreRegression'
    $fingerprintB = Invoke-Private $dashboard 'ComputeRestoreFlowReviewFingerprint' $fingerprintArgsB
    $fingerprintArgsC = New-Object object[] 5
    $fingerprintArgsC[0] = $config
    $fingerprintArgsC[1] = 'snapshot'
    $fingerprintArgsC[2] = $reviewPaths
    $fingerprintArgsC[3] = $false
    $fingerprintArgsC[4] = 'C:\RewindleRestoreRegression-2'
    $fingerprintC = Invoke-Private $dashboard 'ComputeRestoreFlowReviewFingerprint' $fingerprintArgsC
    Assert-True ($fingerprintA -ne $fingerprintB) 'editing selected paths did not invalidate the review fingerprint'
    Assert-True ($fingerprintA -ne $fingerprintC) 'editing destination did not invalidate the review fingerprint'

    # A baseline that no longer matches the installed plan is refused. This re-reads the installed
    # configuration, so it only runs where one exists.
    if ($null -ne $installedConfig) {
        Set-PrivateField $dashboard 'restoreFlowOpen' $true
        Set-PrivateField $dashboard 'restoreFlowConfiguration' $installedConfig
        Set-PrivateField $dashboard 'restoreFlowConfigHash' 'stale-config-hash'
        Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $installedConfig.ConfigGeneration
        Set-PrivateField $dashboard 'restoreFlowPlanId' $installedConfig.PlanId
        $freshArgs = [object[]]@($null, $null)
        $freshResult = Invoke-Private $dashboard 'TryGetFreshRestoreFlowConfiguration' $freshArgs
        Assert-True (-not [bool]$freshResult) 'stale configuration was accepted after review'
        Assert-True ((Get-FieldValue $dashboard 'restoreFlowStatus') -eq 'failed') 'stale configuration did not move the flow to failed state'
        Assert-True ((Get-FieldValue $dashboard 'restoreFlowFailedOperation') -eq 'config') 'stale configuration was not recorded as a configuration failure'
        Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'reload') 'Try again after a configuration change did not route to Reload Restore'
        Set-PrivateField $dashboard 'restoreFlowConfiguration' $config
        Set-PrivateField $dashboard 'restoreFlowConfigHash' $configHash
        Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $config.ConfigGeneration
        Set-PrivateField $dashboard 'restoreFlowPlanId' $config.PlanId
    }
    else {
        $skipped.Add($installedSkip + ' (stale-configuration rejection)')
        Set-PrivateField $dashboard 'restoreFlowOpen' $true
        Set-PrivateField $dashboard 'restoreFlowFailedOperation' 'config'
        Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'reload') 'Try again after a configuration change did not route to Reload Restore'
    }
    $failureArgs = [object[]]@('Read failed', 'The protected read failed.', 'error')
    Invoke-Private $dashboard 'SetRestoreFlowFailure' $failureArgs | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStatus') -eq 'failed') 'error result leaked an invalid restore-flow status'

    # Reload Restore recaptures the baseline and resets the flow exactly like opening it.
    Set-PrivateField $dashboard 'restoreFlowSnapshots' $snapshotList
    Set-PrivateField $dashboard 'restoreFlowObservedPaths' $observed
    Set-PrivateField $dashboard 'restoreFlowDestinationPath' 'C:\RewindleRestoreRegression'
    Set-PrivateField $dashboard 'restoreFlowTreeError' 'stale folder error'
    $reloadArgs = [object[]]@($config, $configHash)
    Invoke-Private $dashboard 'ResetRestoreFlowSession' $reloadArgs | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowConfigHash') -eq $configHash) 'reload did not recapture the configuration baseline'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStep') -eq 'backup') 'reload did not restart at Choose a backup'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowSnapshots').Count -eq 0) 'reload kept snapshots from the previous plan'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowObservedPaths').Count -eq 0) 'reload kept observed browser paths'
    Assert-True ([string]::IsNullOrEmpty([string](Get-FieldValue $dashboard 'restoreFlowDestinationPath'))) 'reload kept the previous destination'
    Assert-True ([string]::IsNullOrEmpty([string](Get-FieldValue $dashboard 'restoreFlowTreeError'))) 'reload kept a stale folder error'
    Assert-True ([string]::IsNullOrEmpty([string](Get-FieldValue $dashboard 'restoreFlowFailedOperation'))) 'reload kept the failed-operation marker'

    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    Set-PrivateField $dashboard 'restoreFlowStep' 'review'
    Set-PrivateField $dashboard 'backupStartInProgress' $true
    $guardArgs = [object[]]@($null)
    $guardResult = Invoke-Private $dashboard 'CheckRestoreFlowOperationGuards' $guardArgs
    Assert-True (-not [bool]$guardResult) 'active backup was accepted at restore launch guard'
    Set-PrivateField $dashboard 'backupStartInProgress' $false

    $cancelArgs = [object[]]@($null)
    Set-PrivateField $dashboard 'restoreFlowBusy' $true
    Set-PrivateField $dashboard 'restoreFlowStep' 'progress'
    $cancelResult = Invoke-Private $dashboard 'CancelRestoreFlow' $cancelArgs
    Assert-True (-not [bool]$cancelResult) 'active protected restore was reported as cancellable'
    Assert-True ([string]$cancelArgs[0] -match 'cannot be cancelled') 'active restore cancellation rejection was unclear'

    # Try again returns to the step that can recover from the failure.
    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    Set-PrivateField $dashboard 'restoreFlowSnapshots' $snapshotList
    Set-PrivateField $dashboard 'restoreFlowFailedOperation' 'restore'
    Set-PrivateField $dashboard 'restoreFlowResultStatus' 'cancelled'
    Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'review') 'declined restore approval did not route Try again back to Review'
    Set-PrivateField $dashboard 'restoreFlowResultStatus' 'error'
    Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'destination') 'failed restore did not route Try again to a new destination'
    Set-PrivateField $dashboard 'restoreFlowFailedOperation' 'snapshots'
    Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'snapshots') 'failed snapshot read did not route Try again to the snapshot list'

    # A folder that cannot be read keeps the user on Choose files with the previous listing.
    $previousTree = New-GenericList $treeEntryType
    [void]$previousTree.Add([Runtime.Serialization.FormatterServices]::GetUninitializedObject($treeEntryType))
    Set-PrivateField $dashboard 'restoreFlowStep' 'files'
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' (New-GenericList $treeEntryType)
    $treeFailureArgs = [object[]]@('/Broken', 'The folder could not be read.', '/Documents', $previousTree)
    Invoke-Private $dashboard 'FailRestoreFlowTreeRead' $treeFailureArgs | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStep') -eq 'files') 'a folder read failure ended the flow on the error screen'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStatus') -eq 'ready') 'a folder read failure left the flow in a failed status'
    Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowBusy')) 'a folder read failure left the flow busy'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreePath') -eq '/Documents') 'a folder read failure discarded the previous folder path'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreeEntries').Count -eq 1) 'a folder read failure discarded the previous listing'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreeError') -eq 'The folder could not be read.') 'a folder read failure did not publish its reason'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreeErrorPath') -eq '/Broken') 'a folder read failure did not remember the folder to retry'
    Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'files') 'a folder read failure did not keep Try again on Choose files'

    # The check that the plan is unchanged, made after a protected read, can fail to complete (the plan file locked, or being
    # rewritten). That ends the read as a failure Try again can recover from, rather than leaving the dialog loading for good.
    $unreadablePlan = 'The protected backup configuration could not be checked. The file is in use.'
    Set-PrivateField $dashboard 'restoreFlowBusy' $true
    Set-PrivateField $dashboard 'restoreFlowStatus' 'loading'
    Set-PrivateField $dashboard 'restoreFlowStep' 'backup'
    Set-PrivateField $dashboard 'restoreFlowFailedOperation' ''
    Set-PrivateField $dashboard 'restoreFlowSnapshots' $snapshotList
    $checkArgs = [object[]]@('snapshots', $unreadablePlan, $null, $null, $null)
    Invoke-Private $dashboard 'EndRestoreFlowReadAfterFailedCheck' $checkArgs | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStatus') -eq 'failed' -and (Get-FieldValue $dashboard 'restoreFlowStep') -eq 'error') 'a configuration check that could not complete left the snapshot read loading'
    Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowBusy')) 'a configuration check that could not complete left the flow busy'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowResultError') -eq $unreadablePlan) 'a configuration check that could not complete did not say why'
    Assert-True ((Invoke-Private $dashboard 'ResolveRestoreFlowRetryRoute') -eq 'snapshots') 'Try again after a configuration check that could not complete did not read the snapshots again'
    # A plan that changed is already a result of its own, and is not overwritten by the generic failure.
    Set-PrivateField $dashboard 'restoreFlowBusy' $true
    Set-PrivateField $dashboard 'restoreFlowStatus' 'failed'
    Set-PrivateField $dashboard 'restoreFlowStep' 'error'
    Set-PrivateField $dashboard 'restoreFlowFailedOperation' 'config'
    Set-PrivateField $dashboard 'restoreFlowResultError' 'The protected backup plan changed while Restore was open.'
    $checkArgs = [object[]]@('snapshots', $unreadablePlan, $null, $null, $null)
    Invoke-Private $dashboard 'EndRestoreFlowReadAfterFailedCheck' $checkArgs | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowFailedOperation') -eq 'config' -and (Get-FieldValue $dashboard 'restoreFlowResultError') -match 'plan changed') 'a configuration check that could not complete overwrote the configuration-changed result'
    Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowBusy')) 'a configuration-changed result left the flow busy'
    # After a folder read it is the folder that reports the problem, on Choose files, with the listing the person already had.
    Set-PrivateField $dashboard 'restoreFlowBusy' $true
    Set-PrivateField $dashboard 'restoreFlowStatus' 'loading'
    Set-PrivateField $dashboard 'restoreFlowStep' 'files'
    Set-PrivateField $dashboard 'restoreFlowFailedOperation' ''
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' (New-GenericList $treeEntryType)
    $checkArgs = [object[]]@('tree', $unreadablePlan, '/Broken', '/Documents', $previousTree)
    Invoke-Private $dashboard 'EndRestoreFlowReadAfterFailedCheck' $checkArgs | Out-Null
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStep') -eq 'files' -and (Get-FieldValue $dashboard 'restoreFlowStatus') -eq 'ready') 'a configuration check that could not complete after a folder read left Choose files'
    Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowBusy')) 'a configuration check that could not complete after a folder read left the flow busy'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreeError') -eq $unreadablePlan -and (Get-FieldValue $dashboard 'restoreFlowTreeErrorPath') -eq '/Broken') 'a configuration check that could not complete after a folder read did not report it on the folder'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreeEntries').Count -eq 1) 'a configuration check that could not complete after a folder read discarded the previous listing'

    $mklink = New-Object Diagnostics.ProcessStartInfo
    $mklink.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $mklink.Arguments = '/c mklink /J "' + $junction + '" "' + $junctionTarget + '"'
    $mklink.UseShellExecute = $false
    $mklink.CreateNoWindow = $true
    $junctionProcess = [Diagnostics.Process]::Start($mklink)
    $junctionProcess.WaitForExit()
    Assert-True ($junctionProcess.ExitCode -eq 0 -and (Test-Path -LiteralPath $junction)) 'could not create temporary reparse-point test fixture'

    Assert-True (-not (Test-RestoreDestination $config '\\server\share\restore')) 'UNC destination was accepted'
    Assert-True (-not (Test-RestoreDestination $config ([string](Join-Path $junction 'new-child')))) 'destination through a reparse parent was accepted'
    # The refusal says what a reparse point is in the terms people meet it in, so a OneDrive folder is not a mystery.
    Assert-True ((Get-RestoreDestinationMessage $config ([string](Join-Path $junction 'new-child'))) -match 'OneDrive') 'a destination through a link did not explain what a reparse point is'

    $existingFile = Join-Path $tempRoot 'existing.txt'
    [IO.File]::WriteAllText($existingFile, 'protected')
    Assert-True (-not (Test-RestoreDestination $config ([string]$existingFile))) 'existing-file destination passed no-overwrite validation'

    # A restore must never land inside, or on top of, the repository, the app state, the installation, or a
    # protected folder, and a folder that holds any of them is no better. A separate folder is the control:
    # unless it is accepted, a rejection above could be for some other reason.
    if (Test-RestoreDestination $config ([string](Join-Path $tempRoot 'restore-ok'))) {
        # A destination that passes also says how much room its drive has, for the warning about a whole snapshot that will not fit; a
        # refused one reads nothing. Reading the room never turns a pass into a refusal.
        $space = Get-RestoreDestinationSpace $config ([string](Join-Path $tempRoot 'restore-ok'))
        Assert-True ($space.Valid -and $null -ne $space.FreeBytes -and [long]$space.FreeBytes -ge 0) 'a destination that passed its check did not report the free space on its drive'
        Assert-True ($space.Drive -eq [IO.Path]::GetPathRoot($tempRoot).TrimEnd('\')) ('the destination check named the wrong drive: ' + $space.Drive)
        $refusedSpace = Get-RestoreDestinationSpace $config ([string]$existingFile)
        Assert-True ((-not $refusedSpace.Valid) -and $null -eq $refusedSpace.FreeBytes) 'a refused destination reported free space'
        Assert-True (-not (Test-RestoreDestination $config ([string](Join-Path $repositoryRoot 'restore')))) 'destination inside the repository was accepted'
        Assert-True (-not (Test-RestoreDestination $config ([string]$stateRoot))) 'the app state folder was accepted as a destination'
        Assert-True (-not (Test-RestoreDestination $config ([string](Join-Path $installRoot 'restore')))) 'destination inside the installation was accepted'
        Assert-True (-not (Test-RestoreDestination $config ([string](Join-Path $sourceRoot 'Restored')))) 'destination inside a protected folder was accepted'
        Assert-True (-not (Test-RestoreDestination $config ([string]$planRoot))) 'a folder containing the repository and protected folders was accepted'
    }
    else {
        $skipped.Add('SKIPPED: the temporary folder is not an ordinary local folder on this computer (overlap guards)')
    }

    # A drive root is refused like any folder that holds something, but the refusal says what is special about it and names a
    # folder to use instead. The plan sits on a drive the system drive is not, so no overlap guard answers before the emptiness
    # check does. Nothing is written, and only the system drive's root is listed.
    $systemDriveRoot = [IO.Path]::GetPathRoot($env:SystemRoot)
    Assert-True ([bool](Invoke-Static $dashboardType 'IsRestoreFlowDriveRoot' @($systemDriveRoot))) 'a drive root was not recognised as one'
    Assert-True ([bool](Invoke-Static $dashboardType 'IsRestoreFlowDriveRoot' @('e:\'))) 'a lower-case drive root was not recognised as one'
    Assert-True (-not [bool](Invoke-Static $dashboardType 'IsRestoreFlowDriveRoot' @('E:\Restores'))) 'a folder on a drive was mistaken for its root'
    Assert-True (-not [bool](Invoke-Static $dashboardType 'IsRestoreFlowDriveRoot' @(''))) 'an empty path was mistaken for a drive root'
    $otherDrive = if ($systemDriveRoot.StartsWith('Z', [StringComparison]::OrdinalIgnoreCase)) { 'Y:' } else { 'Z:' }
    $rootPlan = $otherDrive + '\RewindleFixture'
    $rootConfig = New-SyntheticConfiguration $rootPlan ($rootPlan + '\backup-config.json') ($rootPlan + '\repository') ($rootPlan + '\state') @(($rootPlan + '\sources'))
    if (Test-RestoreDestination $rootConfig $systemDriveRoot) {
        $skipped.Add('SKIPPED: the system drive root is empty on this computer (drive root wording)')
    }
    else {
        $rootMessage = Get-RestoreDestinationMessage $rootConfig $systemDriveRoot
        Assert-True ($rootMessage -match 'drive root' -and $rootMessage -match 'Rewindle restore') ('a drive root was refused without saying so or naming a folder to use: ' + $rootMessage)
    }

    # Declining Windows approval writes nothing, so Try again returns to Review with scope and destination
    # intact. Review re-reads the installed plan, so this too runs only where one exists.
    $retryDestination = [string](Join-Path $tempRoot 'retry-destination')
    if ($null -ne $installedConfig -and (Test-RestoreDestination $installedConfig $retryDestination)) {
        $installedHash = Invoke-Static $dashboardType 'ComputeRestoreFlowConfigHash' @($installedConfig)
        Set-PrivateField $dashboard 'restoreFlowOpen' $true
        Set-PrivateField $dashboard 'restoreFlowBusy' $false
        Set-PrivateField $dashboard 'restoreFlowDestinationChecking' $false
        Set-PrivateField $dashboard 'restoreFlowConfiguration' $installedConfig
        Set-PrivateField $dashboard 'restoreFlowConfigHash' $installedHash
        Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $installedConfig.ConfigGeneration
        Set-PrivateField $dashboard 'restoreFlowPlanId' $installedConfig.PlanId
        Set-PrivateField $dashboard 'restoreFlowSnapshots' $snapshotList
        Set-PrivateField $dashboard 'restoreFlowSelectedSnapshotId' 'snapshot'
        Set-PrivateField $dashboard 'restoreFlowSelectedPaths' (New-StringList @())
        Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $true
        Set-PrivateField $dashboard 'restoreFlowDestinationPath' $retryDestination
        Set-PrivateField $dashboard 'restoreFlowDestinationValid' $true
        Set-PrivateField $dashboard 'restoreFlowStep' 'error'
        Set-PrivateField $dashboard 'restoreFlowStatus' 'failed'
        Set-PrivateField $dashboard 'restoreFlowFailedOperation' 'restore'
        Set-PrivateField $dashboard 'restoreFlowResultStatus' 'cancelled'
        $retryArgs = [object[]]@($null)
        $retryResult = Invoke-Private $dashboard 'RetryRestoreFlow' $retryArgs
        Assert-True ([bool]$retryResult) 'Try again after a declined restore approval was rejected'
        Assert-True ((Get-FieldValue $dashboard 'restoreFlowStep') -eq 'review') 'Try again after a declined restore approval did not return to Review'
        Assert-True ([bool](Get-FieldValue $dashboard 'restoreFlowReviewReady')) 'Try again after a declined restore approval did not rebuild the review'
        Assert-True ((Get-FieldValue $dashboard 'restoreFlowDestinationPath') -eq $retryDestination) 'Try again discarded the destination'
        Assert-True ([bool](Get-FieldValue $dashboard 'restoreFlowWholeSnapshotSelected')) 'Try again discarded the restore scope'
    }
    else {
        $skipped.Add($installedSkip + ' (Try again after declined approval)')
    }

    # Diagnostics export: object keys can carry paths too (source_identities is keyed by every protected
    # folder), so they are scrubbed like values, and the self-check then accepts the result. Only strings
    # are used here, so nothing is read from disk and no real account or folder is involved.
    $fakeProfile = 'C:\Users\your-user'
    $fakeState = 'C:\ProgramData\RewindleFixture'
    $redactionSources = @(($fakeProfile + '\Documents'), ($fakeProfile + '\Pictures'))
    $redactionConfig = New-SyntheticConfiguration 'C:\Program Files\RewindleFixture' 'C:\Program Files\RewindleFixture\backup-config.json' 'D:\RewindleFixture\repository' $fakeState $redactionSources
    $redactionIdentities = [System.Collections.Generic.Dictionary[string,object]]::new()
    foreach ($identityPath in @($redactionSources + 'E:\Elsewhere\One' + 'E:\Elsewhere\Two')) {
        $identity = [System.Collections.Generic.Dictionary[string,object]]::new()
        $identity['expected_volume_serial'] = '0A1B2C3D'
        $redactionIdentities[[string]$identityPath] = $identity
    }
    $redactionDocument = [System.Collections.Generic.Dictionary[string,object]]::new()
    $redactionDocument['schema_version'] = 1
    $redactionDocument['repository'] = 'D:\RewindleFixture\repository'
    $redactionDocument['sources'] = [object[]]$redactionSources
    $redactionDocument['source_identities'] = $redactionIdentities
    # Free text names a path under a redacted root. The path goes whole, whichever way its slashes lean: the file and folder names
    # under the root are personal, so none of them may survive, while the reason an error message puts after the path ("...: Access
    # is denied.") stays readable. An unknown root loses the path the same way, and the root's own kind stays in the token.
    $redactionDocument['message'] = 'wrote ' + $fakeState + '\logs\backup-run.log: disk full'
    $redactionDocument['forward_slashes'] = 'copy ' + ($fakeProfile -replace '\\', '/') + '/Documents/Taxes/2025/return.pdf: failed'
    $redactionDocument['unknown_root'] = 'open E:\Elsewhere\Photos\Holiday\beach.jpg: The system cannot find the file specified.'
    $redactionDocument['quoted'] = 'Could not find file ''' + $fakeProfile + '\Documents\Bob''s Files\a.txt''. Try again.'
    # A security identifier is an account's name in numbers. This one sits under no key that is known to hold one.
    $redactionDocument['group_note'] = 'group S-1-5-21-4444444444-5555555555-6666666666-513 was denied'
    $redactionDocument['request_user_sid'] = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    # What a failed run records: the paths it affected, and the events of its log.
    $redactionDocument['affected_paths'] = [object[]]@(($fakeProfile + '\Documents\Taxes\2025\return.pdf'), 'E:\Elsewhere\One\secret notes.txt')
    $failedError = [System.Collections.Generic.Dictionary[string,object]]::new()
    $failedError['message'] = 'open ' + $fakeProfile + '\Pictures\Family\birthday.jpg: Access is denied.'
    $failedEvent = [System.Collections.Generic.Dictionary[string,object]]::new()
    $failedEvent['message_type'] = 'error'
    $failedEvent['item'] = $fakeProfile + '\Pictures\Family\birthday.jpg'
    $failedEvent['error'] = $failedError
    $redactionDocument['events'] = [object[]]@($failedEvent)
    $redactor = [Activator]::CreateInstance($redactorType, $constructorFlags, $null, [object[]]@($redactionConfig.PSObject.BaseObject, $redactionDocument), $null)
    $cleanDocument = Invoke-Private $redactor 'Sanitize' @($redactionDocument, 'configuration')
    $redactedJson = $jsonSerializer.Serialize($cleanDocument.PSObject.BaseObject)
    try {
        Invoke-Private $redactor 'AssertSafe' @($redactedJson) | Out-Null
    }
    catch {
        throw ('Regression assertion failed: the diagnostic redaction self-check rejected a redacted configuration. ' + $_.Exception.Message)
    }
    Assert-True ($redactedJson -notmatch 'your-user') 'redacted diagnostics kept the account name'
    Assert-True ($redactedJson -notmatch '(?i)[a-z]:\\') 'redacted diagnostics kept a drive path'
    foreach ($personal in 'Taxes', 'return\.pdf', 'backup-run', 'Holiday', 'beach\.jpg', 'secret notes', 'Family', 'birthday', 'Bob', 'a\.txt', 'S-1-5-21', '4444444444', '1111111111') {
        Assert-True ($redactedJson -notmatch $personal) ('redacted diagnostics kept ' + $personal + ' from a path or an account ID')
    }
    $redactedObject = $jsonSerializer.DeserializeObject($redactedJson)
    Assert-True ($redactedObject['message'] -eq 'wrote <state-path>/<redacted>: disk full') ('a path under the state folder was not taken whole, or its reason was cut: ' + $redactedObject['message'])
    Assert-True ($redactedObject['forward_slashes'] -eq 'copy <source-path:1>/<redacted>: failed') ('a path written with forward slashes was not taken whole: ' + $redactedObject['forward_slashes'])
    Assert-True ($redactedObject['unknown_root'] -eq 'open <windows-path>: The system cannot find the file specified.') ('a path under no known root lost its reason: ' + $redactedObject['unknown_root'])
    Assert-True ($redactedObject['quoted'] -eq 'Could not find file ''<source-path:1>/<redacted>''. Try again.') ('a quoted path with an apostrophe in a name was cut short: ' + $redactedObject['quoted'])
    Assert-True ($redactedObject['group_note'] -eq 'group <sid> was denied') ('an account ID in free text was not replaced: ' + $redactedObject['group_note'])
    Assert-True ($redactedObject['request_user_sid'] -eq '<redacted>') 'a key that ends in _sid kept its account ID'
    Assert-True (@($redactedObject['affected_paths']).Count -eq 2 -and $redactedObject['affected_paths'][0] -eq '<source-path:1>/<redacted>') ('an affected path under a protected folder was not reduced to its folder: ' + ($redactedObject['affected_paths'] -join ' | '))
    Assert-True ($redactedObject['events'][0]['item'] -eq '<source-path:2>/<redacted>' -and $redactedObject['events'][0]['error']['message'] -eq 'open <source-path:2>/<redacted>: Access is denied.') 'a log event kept names from its path or lost its reason'
    $redactedIdentityKeys = @($redactedObject['source_identities'].Keys)
    Assert-True ($redactedIdentityKeys.Count -eq 4) 'scrubbing object keys merged distinct source identities'
    Assert-True ($redactedIdentityKeys -contains '<source-path:1>') 'a known source key was not replaced by its token'
    Assert-True (($redactedIdentityKeys | Where-Object { $_ -like '<windows-path>*' }).Count -eq 2) 'unknown source keys were not scrubbed and kept distinct'
    # The self-check itself stays strict: a leaked drive path (either kind of slash), network path or account ID is still refused,
    # and an address on the web or a redacted token is not mistaken for one.
    foreach ($leak in @('{"path":"C:\\Users\\your-user\\Documents"}', '{"path":"\\\\server\\share\\folder"}', '{"C:\\Users\\your-user":"key"}', '{"path":"C:/Users/your-user/Documents"}', '{"path":"//server/share/folder"}', '{"owner":"S-1-5-21-4444444444-5555555555-6666666666-513"}')) {
        $rejected = $false
        try { Invoke-Private $redactor 'AssertSafe' @($leak) | Out-Null } catch { $rejected = $true }
        Assert-True $rejected ('the diagnostic redaction self-check accepted a leaked path: ' + $leak)
    }
    try { Invoke-Private $redactor 'AssertSafe' @('{"link":"https://example.invalid/a/b","kept":"\u003csource-path:1\u003e/\u003credacted\u003e"}') | Out-Null }
    catch { throw ('Regression assertion failed: the diagnostic redaction self-check refused a web address or a redacted path. ' + $_.Exception.Message) }

    # Run history: a dry-run baseline older than every kept run is offered again on every refresh. It does
    # not survive the 400-run cap, so it must not rewrite (and flush) the whole history each time. Every
    # path is an override under the temporary folder; the real dashboard folder is never touched.
    $telemetryRoot = Join-Path $tempRoot 'telemetry'
    $telemetryState = Join-Path $telemetryRoot 'state'
    $telemetryCache = Join-Path $telemetryRoot 'dashboard'
    New-Item -ItemType Directory -Path $telemetryState, $telemetryCache -Force | Out-Null
    $offsiteOverride = Join-Path $telemetryRoot 'latest-verification.json'
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($offsiteOverride, '{}', $utf8)
    $baselineStarted = [DateTime]::UtcNow.AddDays(-900)
    [IO.File]::WriteAllText((Join-Path $telemetryState 'dry-run-latest.json'), $jsonSerializer.Serialize(@{
        'schema_version' = 1
        'run_id' = 'dry-run-baseline'
        'state' = 'clean'
        'started_utc' = $baselineStarted.ToString('o')
        'finished_utc' = $baselineStarted.AddMinutes(5).ToString('o')
    }), $utf8)
    $seededRuns = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 400; $index++) {
        $started = [DateTime]::UtcNow.AddDays(-30).AddHours(-1 * $index)
        $seededRuns.Add(@{
            'run_id' = ('run-{0:D4}' -f $index)
            'type' = 'backup'
            'state' = 'success'
            'success' = $true
            'started_utc' = $started.ToString('o')
            'finished_utc' = $started.AddMinutes(1).ToString('o')
            'duration_seconds' = 60.0
            'restic_duration_seconds' = 50.0
            'files' = 10
            'processed_bytes' = 1000
            'stored_bytes' = 100
            'snapshot_id' = ('snap{0:D4}' -f $index)
            'source_fingerprint' = ''
        })
    }
    $historyFile = Join-Path $telemetryCache 'run-history.json'
    [IO.File]::WriteAllText($historyFile, $jsonSerializer.Serialize(@{
        'schema_version' = 1
        'updated_utc' = [DateTime]::UtcNow.ToString('o')
        'history_truncated' = $true
        'runs' = $seededRuns
    }), $utf8)
    [IO.File]::SetLastWriteTimeUtc($historyFile, [DateTime]::UtcNow.AddDays(-1))
    $historyTicksBefore = [IO.File]::GetLastWriteTimeUtc($historyFile).Ticks
    $historyHashBefore = (Get-FileHash -LiteralPath $historyFile -Algorithm SHA256).Hash
    # Earlier versions wrote live-samples.json every ten seconds during a run and nothing ever read it back. The reader no
    # longer writes it, and removes the one they left (a plain file with that name, in its own folder, and nothing else).
    $retiredSamples = Join-Path $telemetryCache 'live-samples.json'
    $retiredNeighbour = Join-Path $telemetryCache 'keep-me.json'
    [IO.File]::WriteAllText($retiredSamples, '{"schema_version":1,"samples":[]}', $utf8)
    [IO.File]::WriteAllText($retiredNeighbour, '{}', $utf8)
    $reader = [Activator]::CreateInstance($readerType, $constructorFlags, $null, [object[]]@([string]$telemetryState, $false, [string]$offsiteOverride), $null)
    Set-PrivateField $reader 'dashboardDirectory' $telemetryCache
    Set-PrivateField $reader 'historyPath' $historyFile
    Set-PrivateField $reader 'persistenceReady' $true
    $firstLoad = $reader.Load()
    $secondLoad = $reader.Load()
    Assert-True (-not (Test-Path -LiteralPath $retiredSamples)) 'the live-samples file that earlier versions left behind was not removed'
    Assert-True (Test-Path -LiteralPath $retiredNeighbour) 'removing the retired live-samples file took another file with it'
    Assert-True ($firstLoad.History.Count -eq 400 -and $secondLoad.History.Count -eq 400) 'the run history was not capped at 400 runs'
    Assert-True ($secondLoad.HistoryTruncated) 'a capped run history did not say it was truncated'
    # The page is told the limit by name (the dashboard sends it with its state) instead of keeping a copy of the number.
    Assert-True ([int]$readerType.GetField('HistoryLimit', $flags).GetValue($null) -eq $firstLoad.History.Count) 'the history limit the page is told is not the number of runs the history keeps'
    Assert-True ([IO.File]::GetLastWriteTimeUtc($historyFile).Ticks -eq $historyTicksBefore) 'refreshing with an evicted baseline rewrote the run history'
    Assert-True ((Get-FileHash -LiteralPath $historyFile -Algorithm SHA256).Hash -eq $historyHashBefore) 'refreshing with an evicted baseline changed the run history'
    # A genuinely new run still persists.
    $newStarted = [DateTime]::UtcNow.AddMinutes(-10)
    [IO.File]::WriteAllText((Join-Path $telemetryState 'status.json'), $jsonSerializer.Serialize(@{
        'schema_version' = 1
        'run_id' = 'run-new'
        'state' = 'success'
        'started_utc' = $newStarted.ToString('o')
        'finished_utc' = $newStarted.AddMinutes(1).ToString('o')
        'snapshot_id' = 'snapnew0'
        'summary' = @{ 'total_files_processed' = 5; 'total_bytes_processed' = 500; 'data_added' = 50; 'total_duration' = 3.5 }
    }), $utf8)
    $thirdLoad = $reader.Load()
    Assert-True ($thirdLoad.History.Count -eq 400) 'a new run changed the size of the capped history'
    Assert-True ((Get-Content -LiteralPath $historyFile -Raw) -match 'run-new') 'a new run was not persisted to the run history'
    Assert-True ([IO.File]::GetLastWriteTimeUtc($historyFile).Ticks -ne $historyTicksBefore) 'a new run did not update the run history file'
    Assert-True (-not (Test-Path -LiteralPath $retiredSamples)) 'a run wrote live samples that nothing reads'

    # What the reader does with a file it depends on that cannot be used. Every path below is under the temporary folder (the state folder,
    # the dashboard's own folder, the history file and each place an off-site proof can come from), so nothing outside it is read or
    # written, whatever this computer has installed.
    function New-TelemetryFixture([string]$LegacyProof = '', [bool]$CreateStateFolder = $true) {
        $fixtureRoot = Join-Path $telemetryRoot ('fx-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $fixtureState = Join-Path $fixtureRoot 'state'
        $fixtureCache = Join-Path $fixtureRoot 'dashboard'
        New-Item -ItemType Directory -Path $fixtureCache -Force | Out-Null
        if ($CreateStateFolder) { New-Item -ItemType Directory -Path $fixtureState -Force | Out-Null }
        $noProof = [string](Join-Path $fixtureRoot 'no-such-proof.json')
        if (-not $LegacyProof) { $LegacyProof = $noProof }
        $fixtureReader = [Activator]::CreateInstance($readerType, $constructorFlags, $null, [object[]]@([string]$fixtureState, $false, $noProof), $null)
        Set-PrivateField $fixtureReader 'dashboardDirectory' $fixtureCache
        Set-PrivateField $fixtureReader 'historyPath' (Join-Path $fixtureCache 'run-history.json')
        Set-PrivateField $fixtureReader 'legacyLocalOffsiteStatusPath' $LegacyProof
        Set-PrivateField $fixtureReader 'persistenceReady' $true
        return [pscustomobject]@{ Reader = $fixtureReader; Root = $fixtureRoot; State = $fixtureState; Cache = $fixtureCache; History = (Join-Path $fixtureCache 'run-history.json') }
    }
    function Write-TelemetryStatus([string]$StateFolder, [string]$RunId, [string]$RunState) {
        $runStarted = [DateTime]::UtcNow.AddMinutes(-10)
        [IO.File]::WriteAllText((Join-Path $StateFolder 'status.json'), $jsonSerializer.Serialize(@{
            'schema_version' = 1
            'run_id' = $RunId
            'state' = $RunState
            'started_utc' = $runStarted.ToString('o')
            'finished_utc' = $runStarted.AddMinutes(1).ToString('o')
            'snapshot_id' = 'snapfix0'
            'summary' = @{ 'total_files_processed' = 5; 'total_bytes_processed' = 500; 'data_added' = 50; 'total_duration' = 3.5 }
        }), $utf8)
    }
    function Set-StatusGraceExpired([object]$FixtureReader) {
        Set-PrivateField $FixtureReader 'lastGoodStatusTimestamp' ([long]([Diagnostics.Stopwatch]::GetTimestamp() - 11 * [Diagnostics.Stopwatch]::Frequency))
    }
    function New-HistoryRecord([string]$RunId, [string]$RecordType, [double]$DaysAgo) {
        $recordStarted = [DateTime]::UtcNow.AddDays(-1 * $DaysAgo)
        return @{
            'run_id' = $RunId; 'type' = $RecordType; 'state' = 'success'; 'success' = $true
            'started_utc' = $recordStarted.ToString('o'); 'finished_utc' = $recordStarted.AddMinutes(1).ToString('o')
            'duration_seconds' = 60.0; 'restic_duration_seconds' = 50.0; 'files' = 10; 'processed_bytes' = 1000; 'stored_bytes' = 100
            'snapshot_id' = 'snapold0'; 'source_fingerprint' = ''
        }
    }

    # A status that cannot be read for a moment is not a failed backup. status.json is replaced by every run, so a read can land on a copy that
    # is cut short or that another program holds: the last good reading stands in for a few seconds, and a gap that lasts longer is reported
    # as an unavailable status (a warning, never a failure) in one fixed sentence that names the file and quotes neither it nor its path.
    $statusFixture = New-TelemetryFixture
    $statusFile = Join-Path $statusFixture.State 'status.json'
    Write-TelemetryStatus $statusFixture.State 'run-glitch' 'success'
    $readable = $statusFixture.Reader.Load()
    Assert-True ($readable.StateKey -eq 'success' -and $readable.RunId -eq 'run-glitch' -and -not $readable.IsStatusUnavailable) 'a readable status was not described as the run it holds'
    $readableText = [IO.File]::ReadAllText($statusFile)
    [IO.File]::WriteAllText($statusFile, $readableText.Substring(0, 40), $utf8)
    $glitch = $statusFixture.Reader.Load()
    Assert-True ($glitch.StateKey -eq 'success' -and $glitch.RunId -eq 'run-glitch' -and -not $glitch.IsStatusUnavailable -and -not $glitch.IsFailure) 'a status that could not be read for a moment was reported as a problem'
    Set-StatusGraceExpired $statusFixture.Reader
    $gap = $statusFixture.Reader.Load()
    Assert-True ($gap.StateKey -eq 'telemetry_error' -and $gap.IsStatusUnavailable) 'a status that stayed unreadable was still described as the last good one'
    Assert-True ((-not $gap.IsFailure) -and (-not $gap.IsSuccess) -and (-not $gap.IsActive)) 'an unreadable status was called failed, verified or running'
    Assert-True ($gap.StatusDetail -match 'status\.json is not valid JSON') ('an unreadable status did not name the file and the reason: ' + $gap.StatusDetail)
    Assert-True ($gap.StatusDetail -notmatch [regex]::Escape($statusFixture.Root) -and $gap.StatusDetail -notmatch 'run-glitch|schema_version') 'the reason for an unreadable status quoted the file or its path'
    [IO.File]::WriteAllText($statusFile, $readableText, $utf8)
    $recovered = $statusFixture.Reader.Load()
    Assert-True ($recovered.StateKey -eq 'success' -and -not $recovered.IsStatusUnavailable) 'a status that could be read again was still reported as unavailable'
    $holder = New-Object System.IO.FileStream($statusFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Set-StatusGraceExpired $statusFixture.Reader
        $held = $statusFixture.Reader.Load()
        Assert-True ($held.StateKey -eq 'telemetry_error' -and $held.StatusDetail -match 'in use by another program') ('a status held by another program was not said to be: ' + $held.StatusDetail)
    }
    finally { $holder.Dispose() }
    # A state folder that is there with nothing in it is waiting for the first backup. One that is not there is a service that is not installed,
    # which is found without creating anything.
    $emptyFixture = New-TelemetryFixture
    $waitingSnapshot = $emptyFixture.Reader.Load()
    Assert-True ($waitingSnapshot.StateKey -eq 'waiting' -and -not $waitingSnapshot.IsStatusUnavailable) 'a state folder with no run in it was not waiting for the first backup'
    $absentFixture = New-TelemetryFixture '' $false
    $absentState = [string]$absentFixture.State
    Assert-True (-not (Test-Path -LiteralPath $absentState)) 'the missing state folder of the fixture exists'
    $notInstalledSnapshot = $absentFixture.Reader.Load()
    Assert-True ($notInstalledSnapshot.StateKey -eq 'not_installed' -and $notInstalledSnapshot.IsStatusUnavailable -and -not $notInstalledSnapshot.IsFailure) 'a missing state folder was not told apart from a first backup that has not happened'
    Assert-True ($notInstalledSnapshot.StatusLabel -eq 'Engine not installed' -and $notInstalledSnapshot.StatusDetail -match '--state-dir' -and $notInstalledSnapshot.StatusDetail -match 'Requirements') 'a missing state folder did not say what to do'
    Assert-True (-not (Test-Path -LiteralPath $absentState)) 'looking for a missing state folder created it'

    # The old local-mirror status file is retired evidence: it sits under the user's own profile, where anything running as that user can
    # write it. It is noticed and never read, so even a proof-shaped file (or a file that is not JSON at all) says only that a direct cloud
    # verification is required; with no such file there is nothing to say.
    $legacyProofFile = Join-Path $telemetryRoot 'legacy-offsite-status.json'
    [IO.File]::WriteAllText($legacyProofFile, '{"schema_version":2,"proof_kind":"direct_my_drive_cloud_repository_verification","verification_phase":"post_activation","state":"verified","provider_upload_state":"fully_synced"}', $utf8)
    $legacyFixture = New-TelemetryFixture $legacyProofFile
    $legacySnapshot = $legacyFixture.Reader.Load()
    $legacyOffsite = $legacySnapshot.OffsiteStatus
    Assert-True ([string]$legacyOffsite.Kind -eq 'StatusUnavailable' -and -not $legacyOffsite.ProviderUploadConfirmed -and -not $legacyOffsite.RestoreVerified) 'a proof-shaped legacy local file stood for a verified cloud copy'
    Assert-True ($legacyOffsite.StatusLabel -eq 'Direct cloud verification required' -and $legacyOffsite.StatusDetail -match 'retired') 'the retired legacy evidence did not say it is retired'
    [IO.File]::WriteAllText($legacyProofFile, 'this is not JSON, and is not looked at', $utf8)
    $legacyAgain = $legacyFixture.Reader.Load().OffsiteStatus
    Assert-True ($legacyAgain.StatusLabel -eq 'Direct cloud verification required') 'the legacy local file was read instead of only noticed'
    Assert-True ([string]$emptyFixture.Reader.Load().OffsiteStatus.Kind -eq 'NotConfigured') 'a backup with no cloud evidence at all was not left as not configured'

    # A run history that exists but cannot be read is never replaced by a guess. It is read again on the next refreshes (a run that finishes
    # meanwhile is held in memory, not written over it), and only a file that stays unreadable is moved aside, under a name nothing else has,
    # before a new history is started.
    $brokenFixture = New-TelemetryFixture
    Write-TelemetryStatus $brokenFixture.State 'run-after-trouble' 'success'
    [IO.File]::WriteAllText($brokenFixture.History, '{"schema_version":1,"runs":[{"run_id":"precious","type":"backup"', $utf8)
    $brokenHash = (Get-FileHash -LiteralPath $brokenFixture.History -Algorithm SHA256).Hash
    foreach ($attempt in 1..5) {
        $brokenLoad = $brokenFixture.Reader.Load()
        Assert-True ((Get-FileHash -LiteralPath $brokenFixture.History -Algorithm SHA256).Hash -eq $brokenHash) ('an unreadable run history was written over on refresh ' + $attempt)
        Assert-True (@(Get-ChildItem -LiteralPath $brokenFixture.Cache -Filter 'run-history.json.corrupt-*').Count -eq 0) ('a run history that might still come back was set aside on refresh ' + $attempt)
        Assert-True ($brokenLoad.RunId -eq 'run-after-trouble') 'a run that finished while the history was unreadable was not shown'
    }
    [void]$brokenFixture.Reader.Load()
    $asideFiles = @(Get-ChildItem -LiteralPath $brokenFixture.Cache -Filter 'run-history.json.corrupt-*')
    Assert-True ($asideFiles.Count -eq 1 -and $asideFiles[0].Name -match '^run-history\.json\.corrupt-\d{8}T\d{6}Z-[0-9a-f]{32}$') 'a run history that stayed unreadable was not set aside under a unique name'
    Assert-True ((Get-FileHash -LiteralPath $asideFiles[0].FullName -Algorithm SHA256).Hash -eq $brokenHash) 'the run history that was set aside was not kept exactly as it was'
    Assert-True ((Test-Path -LiteralPath $brokenFixture.History) -and ((Get-Content -LiteralPath $brokenFixture.History -Raw) -match 'run-after-trouble')) 'a new run history was not started once the unreadable one was set aside'
    # A history that a newer version wrote is read for what it holds and left exactly as it is.
    $newerFixture = New-TelemetryFixture
    Write-TelemetryStatus $newerFixture.State 'run-new-version' 'success'
    [IO.File]::WriteAllText($newerFixture.History, $jsonSerializer.Serialize(@{ 'schema_version' = 2; 'future_field' = $true; 'runs' = @((New-HistoryRecord 'run-from-the-future' 'backup' 3)) }), $utf8)
    $newerHash = (Get-FileHash -LiteralPath $newerFixture.History -Algorithm SHA256).Hash
    [void]$newerFixture.Reader.Load()
    $newerLoad = $newerFixture.Reader.Load()
    Assert-True ((Get-FileHash -LiteralPath $newerFixture.History -Algorithm SHA256).Hash -eq $newerHash) 'a run history written by a newer version was rewritten'
    Assert-True (@($newerLoad.History | Where-Object { $_.RunId -eq 'run-from-the-future' }).Count -eq 1) 'a run history written by a newer version was not read'
    # Records of a kind this version does not draw are kept when it rewrites the file, and are never shown.
    $keepFixture = New-TelemetryFixture
    Write-TelemetryStatus $keepFixture.State 'run-with-company' 'success'
    $foreignRecord = New-HistoryRecord 'restore-run' 'restore' 2
    $foreignRecord['custom_marker'] = 'keep-me-please'
    [IO.File]::WriteAllText($keepFixture.History, $jsonSerializer.Serialize(@{ 'schema_version' = 1; 'runs' = @((New-HistoryRecord 'run-before' 'backup' 3), $foreignRecord) }), $utf8)
    $keepLoad = $keepFixture.Reader.Load()
    $keptText = Get-Content -LiteralPath $keepFixture.History -Raw
    Assert-True ($keptText -match 'run-with-company' -and $keptText -match 'run-before') 'the run history was not rewritten with the new run'
    Assert-True ($keptText -match 'keep-me-please' -and $keptText -match '"type":"restore"') 'a record of a kind this version does not draw was dropped when the history was rewritten'
    Assert-True (@($keepLoad.History).Count -eq 2 -and @($keepLoad.History | Where-Object { $_.RunId -eq 'restore-run' }).Count -eq 0) 'a record of a kind this version does not draw was shown as a run'

    # Run details: a long, busy log still opens and its timeline stays readable. Consecutive restic progress updates
    # collapse into the newest one (so the newest 250 events reach back through the whole run), times are local, counts
    # carry units, a log past the old 64 MB refusal opens from its tail, and a tail that starts inside a multi-byte
    # character does not stop it. The copied summary keeps its first lines and adds the full start and the totals.
    # Everything is a fixture under the temporary folder.
    $runDetailsReaderType = $assembly.GetType('ResticBackuper.Dashboard.RunDetailsReader', $true)
    $runViewType = $assembly.GetType('ResticBackuper.Dashboard.RunMetricView', $true)
    $detailsLogs = Join-Path $stateRoot 'logs'
    New-Item -ItemType Directory -Path $detailsLogs -Force | Out-Null
    $detailsStartLocal = [DateTime]::new(2026, 10, 2, 12, 0, 0, [DateTimeKind]::Local)
    $detailsStartUtc = $detailsStartLocal.ToUniversalTime()
    function Get-DetailsStamp([double]$Seconds) { return $detailsStartUtc.AddSeconds($Seconds).ToString('yyyy-MM-ddTHH:mm:ss.ffffffK') }
    function Get-RunDetails([string]$RunId) {
        $view = [Activator]::CreateInstance($runViewType)
        $runViewType.GetProperty('StartedLocal').SetValue($view, $detailsStartLocal)
        $runViewType.GetProperty('RunId').SetValue($view, $RunId)
        $runViewType.GetProperty('TypeLabel').SetValue($view, 'Backup')
        $runViewType.GetProperty('StateLabel').SetValue($view, 'Verified')
        $runViewType.GetProperty('Success').SetValue($view, $true)
        $runViewType.GetProperty('DurationSeconds').SetValue($view, 123.0)
        $runViewType.GetProperty('Files').SetValue($view, [long]12480)
        $runViewType.GetProperty('ProcessedBytes').SetValue($view, [long]4883456789)
        $runViewType.GetProperty('StoredBytes').SetValue($view, [long]25690112)
        $runViewType.GetProperty('SnapshotShort').SetValue($view, 'abcdef12')
        return $runDetailsReaderType.GetMethod('Load', $flags).Invoke($null, [object[]]@($config, $view))
    }
    $detailsLines = @(
        ('{"wrapper_event":"backup_started","utc":"' + (Get-DetailsStamp 0) + '"}'),
        ('{"message_type":"status","utc":"' + (Get-DetailsStamp 5) + '","files_done":10,"bytes_done":1048576}'),
        ('{"message_type":"status","utc":"' + (Get-DetailsStamp 6) + '","files_done":20,"bytes_done":5678901234}'),
        ('{"message_type":"status","utc":"' + (Get-DetailsStamp 7) + '","files_done":30,"bytes_done":6000000000}'),
        ('{"message_type":"error","utc":"' + (Get-DetailsStamp 8) + '","item":"C:\\x\\y.txt","error":{"message":"locked"}}'),
        ('{"message_type":"status","utc":"' + (Get-DetailsStamp 9) + '","files_done":40,"bytes_done":7000000000}'),
        ('{"message_type":"summary","utc":"' + (Get-DetailsStamp 10) + '","total_files_processed":12480,"total_bytes_processed":4883456789}'),
        ('{"wrapper_event":"later_day","utc":"' + $detailsStartUtc.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ') + '"}'),
        '{"wrapper_event":"odd_stamp","utc":"not a date, and long enough to matter"}'
    )
    [IO.File]::WriteAllText((Join-Path $detailsLogs 'backup-run-one.jsonl.log'), (($detailsLines -join "`n") + "`n"), $utf8)
    $details = Get-RunDetails 'run-one'
    $detailEvents = @($details.Events)
    Assert-True ($detailEvents.Count -eq 7) ('consecutive progress updates were not collapsed into the newest one: ' + $detailEvents.Count + ' events')
    Assert-True ($detailEvents[0] -eq '12:00:00  backup started') ('an event time was not shown in local time: ' + $detailEvents[0])
    Assert-True ($detailEvents[1] -match '^12:00:07  progress: 30 files, 5\W59 GiB$') ('the collapsed progress line was not the newest, or its size had no unit: ' + $detailEvents[1])
    Assert-True ($detailEvents[3] -match '^12:00:09  progress: 40 files, 6\W52 GiB$') ('a progress update after an error was dropped: ' + $detailEvents[3])
    Assert-True ($detailEvents[4] -match '^12:00:10  Restic summary: 12\W480 files, 4\W55 GiB processed$') ('the summary had no units: ' + $detailEvents[4])
    Assert-True ($detailEvents[5] -match '^2026-10-03 12:00:00  later day$') ('an event on another day did not carry its date: ' + $detailEvents[5])
    Assert-True ($detailEvents[6] -match '^not a date, and long enough to matter  odd stamp$') ('a time that is not a date was relabelled: ' + $detailEvents[6])
    Assert-True (-not $details.EventsTruncated -and [string]::IsNullOrEmpty($details.LogNote)) 'a short readable log was reported as cut or damaged'
    $copyLines = $details.CopyText() -split "`r?`n"
    Assert-True ($copyLines[0] -eq 'Rewindle backup run details' -and $copyLines[3] -eq 'Result: Verified') 'the copied run summary changed its first lines'
    Assert-True (($copyLines -join "`n") -match 'Started at: 2026-10-02 12:00:00 [+-]\d\d:\d\d') 'the copied run summary did not carry the full start with its time zone'
    Assert-True (($copyLines -join "`n") -match 'Files: .*\n.*Processed: .*\n.*Stored: ') 'the copied run summary did not carry the run totals'

    $bigLogPath = Join-Path $detailsLogs 'backup-run-big.jsonl.log'
    $bigLog = [IO.File]::Create($bigLogPath)
    $bigLog.SetLength(70MB)
    [void]$bigLog.Seek(0, [IO.SeekOrigin]::End)
    $bigTail = $utf8.GetBytes("`n" + ($detailsLines -join "`n") + "`n")
    $bigLog.Write($bigTail, 0, $bigTail.Length)
    $bigLog.Dispose()
    $bigDetails = Get-RunDetails 'run-big'
    Assert-True ($bigDetails.EventsTruncated -and @($bigDetails.Events).Count -eq 7) 'a log past 64 MB was refused or read from the wrong end'
    foreach ($shift in 0..1) {
        $multiByteRow = '{"wrapper_event":"' + ('a' * $shift) + (([string][char]0xE9) * 60) + '","utc":"2026-10-02T01:00:00Z"}'
        $multiByteRows = [int](5MB / ($utf8.GetByteCount($multiByteRow) + 1)) + 10
        $multiByteText = New-Object System.Text.StringBuilder
        for ($index = 0; $index -lt $multiByteRows; $index++) { [void]$multiByteText.Append($multiByteRow).Append("`n") }
        [IO.File]::WriteAllText((Join-Path $detailsLogs 'backup-run-utf.jsonl.log'), $multiByteText.ToString(), $utf8)
        $multiByteDetails = Get-RunDetails 'run-utf'
        Assert-True ($multiByteDetails.EventsTruncated -and @($multiByteDetails.Events).Count -eq 250 -and [string]::IsNullOrEmpty($multiByteDetails.LogNote)) 'a log tail that began inside a multi-byte character could not be read'
    }

    # Every refresh loads fresh run objects, and giving the history list the same runs again clears and restores its selection, so a
    # list is only bound again when the signature of what it shows differs: not for identical runs, but for any change to one.
    function New-HistoryRun([string]$RunId, [double]$Seconds, [string]$Snapshot) {
        $view = [Activator]::CreateInstance($runViewType)
        $runViewType.GetProperty('RunId').SetValue($view, $RunId)
        $runViewType.GetProperty('StartedLocal').SetValue($view, $detailsStartLocal)
        $runViewType.GetProperty('TypeLabel').SetValue($view, 'Backup')
        $runViewType.GetProperty('StateLabel').SetValue($view, 'Verified')
        $runViewType.GetProperty('Success').SetValue($view, $true)
        $runViewType.GetProperty('DurationSeconds').SetValue($view, $Seconds)
        $runViewType.GetProperty('SnapshotShort').SetValue($view, $Snapshot)
        return $view
    }
    function Get-HistorySignature([object[]]$Runs) {
        $list = New-GenericList $runViewType
        foreach ($run in $Runs) { [void]$list.Add($run) }
        $signatureArgs = New-Object object[] 1
        $signatureArgs[0] = $list
        return [string](Invoke-Static $dashboardType 'BuildHistoryContentSignature' $signatureArgs)
    }
    $historyBefore = Get-HistorySignature @((New-HistoryRun 'run-a' 60.0 'aaaa1111'), (New-HistoryRun 'run-b' 61.5 'bbbb2222'))
    Assert-True ($historyBefore -eq (Get-HistorySignature @((New-HistoryRun 'run-a' 60.0 'aaaa1111'), (New-HistoryRun 'run-b' 61.5 'bbbb2222')))) 'a history of identical runs, loaded again, was taken for a changed one'
    Assert-True ($historyBefore -ne (Get-HistorySignature @((New-HistoryRun 'run-a' 60.0 'aaaa1111'), (New-HistoryRun 'run-b' 62.0 'bbbb2222')))) 'a run that took longer was not noticed'
    Assert-True ($historyBefore -ne (Get-HistorySignature @((New-HistoryRun 'run-a' 60.0 'aaaa1111'), (New-HistoryRun 'run-b' 61.5 'cccc3333')))) 'a run with another snapshot was not noticed'
    Assert-True ($historyBefore -ne (Get-HistorySignature @((New-HistoryRun 'run-a' 60.0 'aaaa1111'), (New-HistoryRun 'run-b' 61.5 'bbbb2222'), (New-HistoryRun 'run-c' 10.0 'dddd4444')))) 'a new run was not noticed'

    # While the protected restore waits for the Windows prompt the page is told so; once approved, or on any other
    # step, it is not. A cancelled approval keeps the host's own headline, and a headline the host does not have is sent
    # as null so the page words it.
    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowSnapshots' (New-GenericList $snapshotType)
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' (New-GenericList $treeEntryType)
    Set-PrivateField $dashboard 'restoreFlowSelectedPaths' (New-StringList @())
    Set-PrivateField $dashboard 'restoreFlowStep' 'progress'
    Set-PrivateField $dashboard 'restoreFlowAwaitingApproval' $true
    $awaitingState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True ($awaitingState['progress']['awaitingApproval'] -eq $true) 'the page was not told the restore is waiting for Windows approval'
    Set-PrivateField $dashboard 'restoreFlowAwaitingApproval' $false
    Assert-True ((Invoke-Private $dashboard 'BuildWebRestoreFlowState')['progress']['awaitingApproval'] -eq $false) 'the page was still told to wait after approval'
    Set-PrivateField $dashboard 'restoreFlowAwaitingApproval' $true
    Set-PrivateField $dashboard 'restoreFlowStep' 'files'
    Assert-True ((Invoke-Private $dashboard 'BuildWebRestoreFlowState')['progress']['awaitingApproval'] -eq $false) 'the approval wait leaked outside the restore step'
    Set-PrivateField $dashboard 'restoreFlowAwaitingApproval' $false
    Set-PrivateField $dashboard 'restoreFlowStep' 'error'
    Set-PrivateField $dashboard 'restoreFlowResultStatus' 'cancelled'
    Set-PrivateField $dashboard 'restoreFlowMessageTitle' 'Windows approval cancelled'
    Assert-True ((Invoke-Private $dashboard 'BuildWebRestoreFlowState')['result']['title'] -eq 'Windows approval cancelled') 'a cancelled approval did not keep its own headline'
    Set-PrivateField $dashboard 'restoreFlowMessageTitle' ''
    Assert-True ($null -eq (Invoke-Private $dashboard 'BuildWebRestoreFlowState')['result']['title']) 'a missing host headline was replaced with a fixed one'
    # The protected manager reports no file counts, so none are published for the page to show as placeholders.
    Assert-True (-not (Invoke-Private $dashboard 'BuildWebRestoreFlowState')['result'].ContainsKey('restoredFiles')) 'the restore result carried a placeholder file count'

    # What the destination check read about its drive reaches the page as words, with the warning the review step shows again; a drive
    # that would not say how much room it has publishes nothing. The fields the checks below rely on are put back afterwards.
    $spaceFields = 'restoreFlowSnapshots', 'restoreFlowSelectedSnapshotId', 'restoreFlowWholeSnapshotSelected', 'restoreFlowDestinationChecking', 'restoreFlowDestinationValid', 'restoreFlowDestinationDrive', 'restoreFlowDestinationFreeBytes'
    $spaceBefore = @{}
    # Read through the field itself, not Get-FieldValue: a function's output unrolls a list, which would put back an empty list as null.
    foreach ($field in $spaceFields) { $spaceBefore[$field] = (Get-PrivateField $dashboard $field).GetValue($dashboard) }
    $snapshotType.GetField('<ByteCount>k__BackingField', $flags).SetValue($snapshot, 5L * $gib)
    Set-PrivateField $dashboard 'restoreFlowSnapshots' $snapshotList
    Set-PrivateField $dashboard 'restoreFlowSelectedSnapshotId' 'snapshot'
    Set-PrivateField $dashboard 'restoreFlowWholeSnapshotSelected' $true
    Set-PrivateField $dashboard 'restoreFlowDestinationChecking' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationValid' $true
    Set-PrivateField $dashboard 'restoreFlowDestinationDrive' 'E:'
    Set-PrivateField $dashboard 'restoreFlowDestinationFreeBytes' ([long]($gib * 3 / 2))
    $spaceState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True ($spaceState['destination']['drive'] -eq 'E:' -and -not [string]::IsNullOrEmpty([string]$spaceState['destination']['freeDisplay'])) 'the page was not told how much room the destination drive has'
    Assert-True (([string]$spaceState['validation']['spaceWarning']) -like '*is free on E:*' -and @($spaceState['validation']['warnings']) -contains ([string]$spaceState['validation']['spaceWarning'])) 'the free-space warning did not reach the page as one of its warnings'
    Set-PrivateField $dashboard 'restoreFlowDestinationFreeBytes' $null
    $unknownSpaceState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True ([string]::IsNullOrEmpty([string]$unknownSpaceState['destination']['freeDisplay']) -and [string]::IsNullOrEmpty([string]$unknownSpaceState['destination']['drive']) -and [string]::IsNullOrEmpty([string]$unknownSpaceState['validation']['spaceWarning'])) 'a drive that would not say how much room it has was published as if it had'
    $snapshotType.GetField('<ByteCount>k__BackingField', $flags).SetValue($snapshot, 1L)
    foreach ($field in $spaceFields) { Set-PrivateField $dashboard $field $spaceBefore[$field] }

    # The folder listing travels with every state push, so a large folder is cut short (folders first, so every subfolder can still be
    # opened) and the page is told how many entries there are. It is only sent on Choose files, and the page is told how many paths one
    # restore may name. A listing that fits is sent whole, in the order the host has it.
    $bigTree = New-GenericList $treeEntryType
    foreach ($index in 1..1500) {
        $entryType = if ($index % 15 -eq 0) { 'dir' } else { 'file' }
        [void]$bigTree.Add([Activator]::CreateInstance($treeEntryType, $constructorFlags, $null, [object[]]@(('Item ' + $index), ('/Folder/Item ' + $index), $entryType, [long]($index * 10)), $null))
    }
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' $bigTree
    Set-PrivateField $dashboard 'restoreFlowStep' 'files'
    $bigState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True (@($bigState['tree']['entries']).Count -eq 1000) 'a folder of 1,500 entries was not cut short to 1,000'
    Assert-True ($bigState['tree']['total'] -eq 1500 -and $bigState['tree']['truncated'] -eq $true) 'the page was not told a cut-short listing is not the whole folder'
    Assert-True ($bigState['tree']['entries'][0]['type'] -eq 'dir' -and $bigState['tree']['entries'][99]['type'] -eq 'dir' -and $bigState['tree']['entries'][100]['type'] -eq 'file') 'a cut-short listing did not put the folders first'
    Assert-True ($bigState['limits']['maxPaths'] -eq 64) 'the page was not told how many paths one restore may name'
    Set-PrivateField $dashboard 'restoreFlowStep' 'destination'
    $quietState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True (@($quietState['tree']['entries']).Count -eq 0 -and $quietState['tree']['total'] -eq 1500 -and $quietState['tree']['truncated'] -eq $false) 'the folder listing was sent from a step that does not use it'
    $smallTree = New-GenericList $treeEntryType
    foreach ($index in 1..3) {
        [void]$smallTree.Add([Activator]::CreateInstance($treeEntryType, $constructorFlags, $null, [object[]]@(('Item ' + $index), ('/Item ' + $index), $(if ($index -eq 2) { 'dir' } else { 'file' }), [long]$index), $null))
    }
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' $smallTree
    Set-PrivateField $dashboard 'restoreFlowStep' 'files'
    $smallState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True (@($smallState['tree']['entries']).Count -eq 3 -and $smallState['tree']['truncated'] -eq $false) 'a listing that fits was cut short'
    Assert-True ($smallState['tree']['entries'][0]['name'] -eq 'Item 1' -and $smallState['tree']['entries'][1]['type'] -eq 'dir') 'a listing that fits was reordered'
    # The page is told the host's limit, and the host keeps enforcing it.
    $sixtyFourPaths = (1..64 | ForEach-Object { '/Folder ' + $_ }) -join "`n"
    Assert-True (@(Invoke-Static $dashboardType 'ParseRestoreFlowPaths' @($sixtyFourPaths)).Count -eq 64) 'a selection of 64 paths was refused'
    $refusedLargeSelection = $false
    try { Invoke-Static $dashboardType 'ParseRestoreFlowPaths' @($sixtyFourPaths + "`n/Folder 65") | Out-Null } catch { $refusedLargeSelection = $_.Exception.ToString() -match 'at most 64' }
    Assert-True $refusedLargeSelection 'a selection of 65 paths was accepted'
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' (New-GenericList $treeEntryType)
    Set-PrivateField $dashboard 'restoreFlowStep' 'error'

    # Whether a restore can start right now is published, so the page can say why Restore now waits before it is pressed. It is
    # only a hint: the same guard runs again when the restore is requested (checked above).
    Set-PrivateField $dashboard 'backupStartInProgress' $false
    $freeState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True ([string]::IsNullOrEmpty([string]$freeState['startBlocked'])) 'the page was told a restore is blocked while nothing is running'
    Set-PrivateField $dashboard 'backupStartInProgress' $true
    $blockedState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True (([string]$blockedState['startBlocked']) -match 'active backup') 'the page was not told why a restore cannot start while a backup is starting'
    Set-PrivateField $dashboard 'backupStartInProgress' $false

    # The result screen's Open and Copy carry no path: they act on the folder the finished restore reported (restoreFlowResultTarget),
    # only once a restore has ended with files to look at (success or partial), only while that folder is the destination that was checked
    # or inside it, and only if it exists. Every refusal below stops before anything is launched or copied; the cases that are allowed are
    # checked through the guard they share, which touches neither Explorer nor the clipboard.
    Assert-True ([bool](Invoke-Private $dashboard 'IsRestoreFlowCommand' @('restoreFlowOpenDestination'))) 'Open restored folder is not a restore-flow command'
    Assert-True ([bool](Invoke-Private $dashboard 'IsRestoreFlowCommand' @('restoreFlowCopyDestination'))) 'Copy path is not a restore-flow command'
    $resultFolder = [string](Join-Path $tempRoot 'restored-result')
    $resultChild = [string](Join-Path $resultFolder 'Documents')
    $resultElsewhere = [string](Join-Path $tempRoot 'restored-elsewhere')
    $resultSibling = $resultFolder + '-sibling'
    New-Item -ItemType Directory -Path $resultChild, $resultElsewhere, $resultSibling -Force | Out-Null
    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationPath' $resultFolder
    Set-PrivateField $dashboard 'restoreFlowResultTarget' $resultFolder
    foreach ($resultCommand in @('restoreFlowOpenDestination', 'restoreFlowCopyDestination')) {
        foreach ($earlyStep in @('backup', 'files', 'destination', 'review', 'progress', 'error')) {
            Set-PrivateField $dashboard 'restoreFlowStep' $earlyStep
            $commandArgs = [object[]]@($resultCommand, $null, $null)
            Assert-True (-not [bool](Invoke-Private $dashboard 'ExecuteRestoreFlowCommand' $commandArgs)) ($resultCommand + ' was accepted on the ' + $earlyStep + ' step')
            Assert-True ([string]$commandArgs[2] -match 'once a restore has finished') ($resultCommand + ' gave no reason on the ' + $earlyStep + ' step')
        }
    }
    foreach ($resultStep in @('success', 'partial')) {
        Set-PrivateField $dashboard 'restoreFlowStep' $resultStep
        Set-PrivateField $dashboard 'restoreFlowResultTarget' $resultFolder
        $folderArgs = [object[]]@($null, $null)
        Assert-True ([bool](Invoke-Private $dashboard 'TryGetRestoreFlowResultFolder' $folderArgs)) ('the folder a restore reported was refused on the ' + $resultStep + ' step')
        Assert-True ([string]$folderArgs[0] -eq $resultFolder) ('the folder offered after the ' + $resultStep + ' step was not the one the restore reported')
    }
    Set-PrivateField $dashboard 'restoreFlowStep' 'success'
    Set-PrivateField $dashboard 'restoreFlowResultTarget' $resultChild
    $folderArgs = [object[]]@($null, $null)
    Assert-True ([bool](Invoke-Private $dashboard 'TryGetRestoreFlowResultFolder' $folderArgs)) 'a folder inside the checked destination was refused'
    Set-PrivateField $dashboard 'restoreFlowResultTarget' ($resultFolder + '\')
    $folderArgs = [object[]]@($null, $null)
    Assert-True ([bool](Invoke-Private $dashboard 'TryGetRestoreFlowResultFolder' $folderArgs) -and [string]$folderArgs[0] -eq $resultFolder) 'a trailing separator on the reported folder was not normalised away'
    foreach ($refused in @(
        @{ Target = $resultElsewhere; Why = 'a folder outside the checked destination' },
        @{ Target = $resultSibling; Why = 'a sibling whose name only starts like the destination' },
        @{ Target = (Join-Path $resultFolder 'missing'); Why = 'a folder that does not exist' },
        @{ Target = ''; Why = 'a restore that reported no folder' },
        @{ Target = $null; Why = 'a restore with no target at all' })) {
        Set-PrivateField $dashboard 'restoreFlowResultTarget' $refused.Target
        $folderArgs = [object[]]@($null, $null)
        Assert-True (-not [bool](Invoke-Private $dashboard 'TryGetRestoreFlowResultFolder' $folderArgs)) ('Open and Copy accepted ' + $refused.Why)
        Assert-True ([string]::IsNullOrEmpty([string]$folderArgs[0])) ('a folder was handed out for ' + $refused.Why)
    }
    Set-PrivateField $dashboard 'restoreFlowResultTarget' $resultFolder
    Set-PrivateField $dashboard 'restoreFlowBusy' $true
    $folderArgs = [object[]]@($null, $null)
    Assert-True (-not [bool](Invoke-Private $dashboard 'TryGetRestoreFlowResultFolder' $folderArgs)) 'Open and Copy were accepted while the flow was still working'
    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    Set-PrivateField $dashboard 'restoreFlowOpen' $false
    $folderArgs = [object[]]@($null, $null)
    Assert-True (-not [bool](Invoke-Private $dashboard 'TryGetRestoreFlowResultFolder' $folderArgs)) 'Open and Copy were accepted after the flow was closed'
    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowResultTarget' $null
    Set-PrivateField $dashboard 'restoreFlowStep' 'error'

    # One Windows approval per restore. Choosing a backup reads none of its folders (its root is read only when the person asks to
    # browse it, and "Everything in this snapshot" needs no folder at all), every folder read once is shown again from the flow's
    # own listings, the installed engine decides between one restore session and one approval per step, and a session (here a
    # stand-in broker in this process, behind the dashboard's real client) serves every listing and one restore under one
    # approval. Fixtures under the temporary folder only; nothing is elevated and no manager is started.
    $sessionHostType = $assembly.GetType('ResticBackuper.Dashboard.RestoreSessionHost', $true)
    $sessionCapabilityType = $assembly.GetType('ResticBackuper.Dashboard.RestoreSessionCapability', $true)
    $sessionLauncherType = $assembly.GetType('ResticBackuper.Dashboard.RestoreSessionLauncher', $true)
    $restoreLauncherType = $assembly.GetType('ResticBackuper.Dashboard.RestoreManagerLauncher', $true)
    $restoreProgressType = $assembly.GetType('ResticBackuper.Dashboard.RestoreManagerProgress', $true)
    $rewindleEngine = $engineProfileType.GetProperty('Rewindle', $flags).GetValue($null)
    $legacyEngine = $engineProfileType.GetProperty('Legacy', $flags).GetValue($null)
    $secondSnapshot = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($snapshotType)
    foreach ($pair in @(@('Id', 'second-snapshot'), @('ShortId', 'second'), @('Time', '2026-09-15T00:00:00Z'), @('Hostname', 'regression'), @('SourceSummary', 'regression'), @('BindingState', 'plan'))) {
        $snapshotType.GetField('<' + $pair[0] + '>k__BackingField', $flags).SetValue($secondSnapshot, $pair[1])
    }
    $twoSnapshots = New-GenericList $snapshotType
    [void]$twoSnapshots.Add($snapshot)
    [void]$twoSnapshots.Add($secondSnapshot)
    function New-TreeEntries([string]$Folder, [int]$Count) {
        $list = New-GenericList $treeEntryType
        foreach ($index in 1..$Count) {
            [void]$list.Add([Activator]::CreateInstance($treeEntryType, $constructorFlags, $null, [object[]]@(('item ' + $index), ($Folder.TrimEnd('/') + '/item ' + $index), 'file', [long]$index), $null))
        }
        return ,$list
    }
    function New-Payload([hashtable]$Values) {
        $payload = [System.Collections.Generic.Dictionary[string,object]]::new()
        foreach ($key in $Values.Keys) { $payload[$key] = $Values[$key] }
        return ,$payload
    }

    # Choosing a backup goes on to Choose files and reads nothing; restoring all of it needs no folder.
    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    Set-PrivateField $dashboard 'restoreFlowDestinationChecking' $false
    Set-PrivateField $dashboard 'restoreFlowSnapshots' $twoSnapshots
    Set-PrivateField $dashboard 'restoreFlowSelectedSnapshotId' 'snapshot'
    Set-PrivateField $dashboard 'restoreFlowTreeEntries' (New-TreeEntries '/Documents' 2)
    Set-PrivateField $dashboard 'restoreFlowTreeLoaded' $true
    Set-PrivateField $dashboard 'restoreFlowObservedPaths' (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
    [void](Invoke-Private $dashboard 'StoreRestoreFlowTreeListing' @('snapshot', '/Documents', (New-TreeEntries '/Documents' 2)))
    $operationBefore = [int](Get-FieldValue $dashboard 'restoreFlowOperationGeneration')
    $chooseArgs = [object[]]@((New-Payload @{ step = 'files'; snapshotId = 'second-snapshot' }), $null)
    Assert-True ([bool](Invoke-Private $dashboard 'NavigateRestoreFlow' $chooseArgs)) ('choosing a backup was refused: ' + [string]$chooseArgs[1])
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowStep') -eq 'files' -and -not (Get-FieldValue $dashboard 'restoreFlowBusy') -and
        [int](Get-FieldValue $dashboard 'restoreFlowOperationGeneration') -eq $operationBefore) 'choosing a backup started a protected read'
    Assert-True ((Get-FieldValue $dashboard 'restoreFlowSelectedSnapshotId') -eq 'second-snapshot' -and -not (Get-FieldValue $dashboard 'restoreFlowTreeLoaded') -and
        (Get-FieldValue $dashboard 'restoreFlowTreeEntries').Count -eq 0) 'choosing another backup kept the other backup''s folder'
    Assert-True ($null -eq (Get-FieldValue $dashboard 'restoreFlowTreeCache')) 'choosing another backup kept the other backup''s folder listings'
    $unreadState = Invoke-Private $dashboard 'BuildWebRestoreFlowState'
    Assert-True ($unreadState['tree']['loaded'] -eq $false -and $unreadState['step'] -eq 'files') 'the page was not told that no folder of the chosen backup was read'
    $wholeArgs = [object[]]@((New-Payload @{ snapshotId = 'second-snapshot'; paths = ''; wholeSnapshot = $true }), $null)
    Assert-True ([bool](Invoke-Private $dashboard 'SelectRestoreFlowPaths' $wholeArgs)) ('Everything in this snapshot was refused before a folder was read: ' + [string]$wholeArgs[1])
    $destinationArgs = [object[]]@((New-Payload @{ step = 'destination' }), $null)
    Assert-True ([bool](Invoke-Private $dashboard 'NavigateRestoreFlow' $destinationArgs) -and (Get-FieldValue $dashboard 'restoreFlowStep') -eq 'destination') 'a whole-snapshot restore could not go on to its destination without a folder read'
    Assert-True ([int](Get-FieldValue $dashboard 'restoreFlowOperationGeneration') -eq $operationBefore -and -not (Get-FieldValue $dashboard 'restoreFlowBusy')) 'restoring everything read a folder'
    $againArgs = [object[]]@((New-Payload @{ step = 'files'; snapshotId = 'second-snapshot' }), $null)
    Assert-True ([bool](Invoke-Private $dashboard 'NavigateRestoreFlow' $againArgs) -and [bool](Get-FieldValue $dashboard 'restoreFlowWholeSnapshotSelected')) 'going back to the same backup dropped what was chosen from it'
    $unknownArgs = [object[]]@((New-Payload @{ step = 'files'; snapshotId = 'not-a-listed-snapshot' }), $null)
    Assert-True (-not [bool](Invoke-Private $dashboard 'NavigateRestoreFlow' $unknownArgs) -and (Get-FieldValue $dashboard 'restoreFlowSelectedSnapshotId') -eq 'second-snapshot') 'a backup outside the protected history was chosen'

    # The flow's folder listings: bounded, per snapshot, and gone with the snapshot.
    Invoke-Private $dashboard 'ClearRestoreFlowTreeCache' | Out-Null
    foreach ($index in 1..300) { [void](Invoke-Private $dashboard 'StoreRestoreFlowTreeListing' @('second-snapshot', ('/Folder ' + $index), (New-TreeEntries ('/Folder ' + $index) 1))) }
    $cacheField = Get-FieldValue $dashboard 'restoreFlowTreeCache'
    $cachedArgs = [object[]]@('second-snapshot', '/Folder 300', $null)
    $evictedArgs = [object[]]@('second-snapshot', '/Folder 1', $null)
    $otherArgs = [object[]]@('snapshot', '/Folder 300', $null)
    Assert-True ($cacheField.Count -eq 256 -and [bool](Invoke-Private $dashboard 'TryGetCachedRestoreFlowTree' $cachedArgs) -and -not [bool](Invoke-Private $dashboard 'TryGetCachedRestoreFlowTree' $evictedArgs)) 'the folder listings are not bounded, newest kept'
    Assert-True (-not [bool](Invoke-Private $dashboard 'TryGetCachedRestoreFlowTree' $otherArgs)) 'a folder listing was served for another snapshot'
    Invoke-Private $dashboard 'SelectRestoreFlowSnapshot' @('snapshot') | Out-Null
    Assert-True ($null -eq (Get-FieldValue $dashboard 'restoreFlowTreeCache')) 'changing snapshots kept the folder listings'

    # A folder that was read once is shown again without a read. Browse files checks the plan first, so the plan is a fixture under
    # the temporary engine folders; it is removed again below, before the engine checks look for installs.
    $fixtureInstall = Join-Path $engineFixtureRoot 'ProgramFiles\ResticBackuper'
    $fixtureState = Join-Path $engineFixtureRoot 'ProgramData\ResticBackuper'
    New-Item -ItemType Directory -Path $fixtureInstall, $fixtureState -Force | Out-Null
    $fixtureSource = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
    $fixtureIdentities = [ordered]@{}
    $fixtureIdentities[$fixtureSource] = [ordered]@{ expected_volume_serial = 'ABCD1234' }
    $fixturePlan = [ordered]@{
        schema_version = 1; plan_id = '4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31'; config_generation = 3; cloud_placeholder_policy = 'strict'
        repository = $repositoryRoot; state_directory = $fixtureState; sources = @($fixtureSource); source_identities = $fixtureIdentities
    }
    $fixturePlanPath = Join-Path $fixtureInstall 'backup-config.json'
    try {
        [IO.File]::WriteAllText($fixturePlanPath, (ConvertTo-Json -InputObject $fixturePlan -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        $fixtureConfig = Invoke-Static $configurationType 'Load'
        $fixtureHash = Invoke-Static $dashboardType 'ComputeRestoreFlowConfigHash' @($fixtureConfig)
        Set-PrivateField $dashboard 'restoreFlowConfiguration' $fixtureConfig
        Set-PrivateField $dashboard 'restoreFlowConfigHash' $fixtureHash
        Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $fixtureConfig.ConfigGeneration
        Set-PrivateField $dashboard 'restoreFlowPlanId' $fixtureConfig.PlanId
        Set-PrivateField $dashboard 'restoreFlowSnapshots' $twoSnapshots
        Set-PrivateField $dashboard 'restoreFlowSelectedSnapshotId' 'snapshot'
        Set-PrivateField $dashboard 'restoreFlowObservedPaths' (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal))
        Set-PrivateField $dashboard 'restoreFlowStep' 'files'
        Set-PrivateField $dashboard 'restoreFlowTreeLoaded' $false
        [void](Invoke-Private $dashboard 'StoreRestoreFlowTreeListing' @('snapshot', '/Docs', (New-TreeEntries '/Docs' 2)))
        $operationBefore = [int](Get-FieldValue $dashboard 'restoreFlowOperationGeneration')
        $browseArgs = [object[]]@((New-Payload @{ snapshotId = 'snapshot'; path = '/Docs' }), $null)
        Assert-True ([bool](Invoke-Private $dashboard 'BeginRestoreFlowBrowseFiles' $browseArgs)) ('a folder that was already read could not be opened again: ' + [string]$browseArgs[1])
        Assert-True (-not (Get-FieldValue $dashboard 'restoreFlowBusy') -and [int](Get-FieldValue $dashboard 'restoreFlowOperationGeneration') -eq $operationBefore) 'a folder that was already read was read again'
        Assert-True ((Get-FieldValue $dashboard 'restoreFlowTreePath') -eq '/Docs' -and (Get-FieldValue $dashboard 'restoreFlowTreeEntries').Count -eq 2 -and
            [bool](Get-FieldValue $dashboard 'restoreFlowTreeLoaded') -and (Get-FieldValue $dashboard 'restoreFlowObservedPaths').Contains('/Docs/item 1')) 'a folder shown again from the listings is not the folder, or cannot be selected from'
        Assert-True ((Invoke-Private $dashboard 'BuildWebRestoreFlowState')['tree']['loaded'] -eq $true) 'the page was not told the folder was read'
        $docsArgs = [object[]]@((New-Payload @{ snapshotId = 'snapshot'; paths = '/Docs/item 2'; wholeSnapshot = $false }), $null)
        Assert-True ([bool](Invoke-Private $dashboard 'SelectRestoreFlowPaths' $docsArgs)) 'a path from a folder shown again could not be selected'
    }
    catch {
        if (Test-Path -LiteralPath $fixturePlanPath) { Remove-Item -LiteralPath $fixturePlanPath -Force }
        throw
    }
    $nullLauncherRefused = $false
    try { [void][Activator]::CreateInstance($sessionHostType, $constructorFlags, $null, [object[]]@($null), $null) }
    catch { $nullLauncherRefused = $_.Exception.ToString() -match 'ArgumentNullException' }
    Assert-True $nullLauncherRefused 'a restore session host accepted no launcher'
    function Wait-Until([scriptblock]$Condition, [int]$Milliseconds = 5000) {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
        while (-not (& $Condition) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        return [bool](& $Condition)
    }

    Add-Type -ReferencedAssemblies System.Core, System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
namespace RewindleRegression {
  // A stand-in for Manage-Restore.ps1 -Operation session that answers in this process, so the pipe's server is the process the
  // dashboard is told it started. It checks what a broker checks of the hello and answers with bound result documents.
  public static class FakeRestoreBroker {
    public static string Mode = "normal";
    public static int WrongServerProcessId;
    public static int Launches, Hellos, Closes, BadHellos;
    public static List<string> Requests = new List<string>();
    static string Field(object request, string name) {
      object value = request.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public).GetValue(request);
      return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
    }
    public static void Reset(string mode) { Mode = mode; Launches = 0; Hellos = 0; Closes = 0; BadHellos = 0; lock (Requests) Requests.Clear(); }
    public static Process Launch(ProcessStartInfo start, object request) {
      Launches++;
      if (Mode == "decline") throw new Win32Exception(1223);
      Dictionary<string, string> info = new Dictionary<string, string>();
      foreach (string name in new[] { "Nonce", "Digest", "UserSid", "ConfigHash", "PlanId", "ConfigGeneration", "PipeName", "SessionTokenSha256", "IdleTimeoutSeconds", "LifetimeSeconds", "DashboardProcessId" })
        info[name] = Field(request, name);
      if (start.Verb != "runas" || start.Arguments.IndexOf("-Operation session", StringComparison.Ordinal) < 0 ||
          start.Arguments.IndexOf(info["Digest"], StringComparison.Ordinal) < 0 || start.Arguments.IndexOf(info["SessionTokenSha256"], StringComparison.Ordinal) < 0)
        throw new InvalidOperationException("The session was not asked for as an elevated session request.");
      ManualResetEvent created = new ManualResetEvent(false);
      string mode = Mode;
      Thread thread = new Thread(delegate() {
        // A broker thread that fails must not take the test process down with it.
        try { Serve(info, mode, created); } catch (Exception) { created.Set(); }
      });
      thread.IsBackground = true;
      thread.Start();
      created.WaitOne(10000);
      return mode == "wrongServer" ? Process.GetProcessById(WrongServerProcessId) : Process.GetCurrentProcess();
    }
    static byte[] Hash(byte[] bytes) { using (SHA256 sha = SHA256.Create()) return sha.ComputeHash(bytes); }
    static string Hex(byte[] bytes) { StringBuilder b = new StringBuilder(); foreach (byte x in bytes) b.Append(x.ToString("x2")); return b.ToString(); }
    static Dictionary<string, object> Read(Stream stream) {
      byte[] header = ReadExactly(stream, 4); if (header == null) return null;
      int length = BitConverter.ToInt32(header, 0);
      byte[] body = ReadExactly(stream, length); if (body == null) return null;
      return new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(body)) as Dictionary<string, object>;
    }
    static byte[] ReadExactly(Stream stream, int count) {
      byte[] buffer = new byte[count]; int offset = 0;
      while (offset < count) { int read; try { read = stream.Read(buffer, offset, count - offset); } catch (IOException) { return null; } if (read <= 0) return null; offset += read; }
      return buffer;
    }
    static void Write(Stream stream, object message) {
      JavaScriptSerializer serializer = new JavaScriptSerializer(); serializer.MaxJsonLength = int.MaxValue;
      byte[] body = Encoding.UTF8.GetBytes(serializer.Serialize(message));
      byte[] header = BitConverter.GetBytes(body.Length);
      stream.Write(header, 0, 4); stream.Write(body, 0, body.Length); stream.Flush();
    }
    static void Serve(Dictionary<string, string> info, string mode, ManualResetEvent created) {
      NamedPipeServerStream server;
      try { server = new NamedPipeServerStream(info["PipeName"], PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous); }
      finally { created.Set(); }
      using (server) {
        IAsyncResult waiting = server.BeginWaitForConnection(null, null);
        if (!waiting.AsyncWaitHandle.WaitOne(30000)) return;
        server.EndWaitForConnection(waiting);
        Dictionary<string, object> hello = Read(server);
        if (hello == null) return;
        Hellos++;
        string token = hello.ContainsKey("session_token") ? hello["session_token"] as string : null;
        if (token == null || Hex(Hash(Encoding.UTF8.GetBytes(token))) != info["SessionTokenSha256"] ||
            (hello["protocol"] as string) != "ResticBackuper.RestoreSession.v1" || Convert.ToString(hello["dashboard_process_id"]) != info["DashboardProcessId"]) {
          BadHellos++; return;
        }
        Write(server, new Dictionary<string, object> {
          { "type", "ready" }, { "protocol", "ResticBackuper.RestoreSession.v1" }, { "request_nonce", info["Nonce"] },
          { "request_digest", info["Digest"] }, { "broker_process_id", Process.GetCurrentProcess().Id },
          { "idle_timeout_seconds", int.Parse(info["IdleTimeoutSeconds"]) }, { "lifetime_seconds", int.Parse(info["LifetimeSeconds"]) } });
        int served = 0;
        while (true) {
          Dictionary<string, object> message = Read(server);
          if (message == null) return;
          string type = message["type"] as string;
          if (type == "close") { Closes++; Write(server, new Dictionary<string, object> { { "type", "closed" }, { "reason", "client_closed" } }); return; }
          if (mode == "closeAfterFirst" && served == 1) { Write(server, new Dictionary<string, object> { { "type", "closed" }, { "reason", "idle_timeout" } }); return; }
          string action = (string)message["action"];
          lock (Requests) Requests.Add(action + " " + message["tree_path"]);
          if (mode == "oversized") { server.Write(BitConverter.GetBytes(9 * 1024 * 1024), 0, 4); return; }
          object id = message["request_id"];
          Write(server, new Dictionary<string, object> { { "type", "progress" }, { "request_id", id }, { "stage", "reading" }, { "message", "Reading." }, { "percent", 35 } });
          string snapshotId = (string)message["snapshot_id"], treePath = (string)message["tree_path"], target = (string)message["target"];
          bool legacy = (string)message["allow_legacy_unbound"] == "1";
          object payload;
          if (action == "list_snapshots") {
            payload = new Dictionary<string, object> {
              { "schema", "ResticBackuper.SnapshotList.v1" }, { "schema_version", 1 },
              { "binding", new Dictionary<string, object> { { "plan_id", info["PlanId"] }, { "legacy_match_policy", "exact-host-scheduled-tags-and-sources" } } },
              { "snapshots", new object[] { new Dictionary<string, object> {
                { "id", new string('a', 64) }, { "short_id", "aaaaaaaa" }, { "time", "2026-09-14T00:00:00Z" }, { "hostname", "regression" },
                { "binding_state", "plan" }, { "plan_id", info["PlanId"] }, { "config_generation", 1 }, { "paths", new object[] { "C:\\Fixture" } } } } } };
          } else if (action == "list_tree") {
            payload = new Dictionary<string, object> {
              { "schema", "ResticBackuper.SnapshotTree.v1" }, { "schema_version", 1 }, { "snapshot_id", snapshotId }, { "snapshot_binding", "plan" },
              { "snapshot", new Dictionary<string, object> { { "binding_state", "plan" }, { "plan_id", info["PlanId"] } } },
              { "entries", new object[] { new Dictionary<string, object> { { "name", "a.txt" }, { "path", treePath.TrimEnd('/') + "/a.txt" }, { "type", "file" }, { "size", 3 } } } } };
          } else {
            payload = new Dictionary<string, object> {
              { "schema", "ResticBackuper.RestoreReport.v1" }, { "schema_version", 1 }, { "snapshot_id", snapshotId }, { "snapshot_binding", "plan" },
              { "plan_id", info["PlanId"] }, { "target", target }, { "result", "verified" }, { "verified", true }, { "partial_target_retained", false }, { "restic_exit_code", 0 } };
          }
          Dictionary<string, object> result = new Dictionary<string, object> {
            { "schema_version", 1 }, { "request_nonce", mode == "foreignNonce" ? new string('9', 64) : info["Nonce"] }, { "request_digest", info["Digest"] },
            { "request_user_sid", info["UserSid"] }, { "action", action }, { "expected_config_sha256", info["ConfigHash"] },
            { "plan_id", info["PlanId"] }, { "config_generation", long.Parse(info["ConfigGeneration"]) }, { "allow_legacy_unbound", legacy },
            { "snapshot_id", snapshotId.Length == 0 ? null : snapshotId }, { "tree_path", treePath.Length == 0 ? null : treePath },
            { "target", target.Length == 0 ? null : target },
            { "includes_sha256", Hex(Hash(Convert.FromBase64String((string)message["includes_base64"]))) },
            { "ok", true }, { "backend_exit_code", 0 }, { "history_recorded", action == "restore" ? (object)true : null }, { "history_error", null },
            { "payload", payload }, { "error", null } };
          Write(server, new Dictionary<string, object> { { "type", "result" }, { "request_id", id }, { "exit_code", 0 }, { "result", result } });
          served++;
          if (action == "restore") return;
        }
      }
    }
  }
}
'@
    $fakeBroker = [RewindleRegression.FakeRestoreBroker]
    $fakeLaunch = [Delegate]::CreateDelegate($sessionLauncherType, $fakeBroker.GetMethod('Launch'))
    function New-SessionHost { return [Activator]::CreateInstance($sessionHostType, $constructorFlags, $null, [object[]]@($fakeLaunch), $null) }
    function Get-HostValue([object]$SessionHost, [string]$Name) { return $sessionHostType.GetProperty($Name, $flags).GetValue($SessionHost) }
    $progressSeen = New-Object System.Collections.Generic.List[string]
    $onProgress = [System.Management.Automation.LanguagePrimitives]::ConvertTo(
        { param($progress) $progressSeen.Add([string]$progress.Stage) },
        [Action``1].MakeGenericType($restoreProgressType))
    $restoreLaunchMethod = @{}
    foreach ($method in $restoreLauncherType.GetMethods($flags)) {
        if (@($method.GetParameters() | Where-Object { $_.ParameterType -eq $sessionHostType }).Count -gt 0) { $restoreLaunchMethod[$method.Name] = $method }
    }
    function Invoke-SessionList([object]$SessionHost) {
        return $restoreLaunchMethod['ListSnapshots'].Invoke($null, [object[]]@($config, $SessionHost, $null, $null, $onProgress))
    }
    function Invoke-SessionTree([object]$SessionHost, [string]$Folder) {
        return $restoreLaunchMethod['ListTree'].Invoke($null, [object[]]@($config, ('a' * 64), $Folder, $false, $SessionHost, $null, $null, $onProgress))
    }
    function Invoke-SessionRestore([object]$SessionHost, [string]$Destination) {
        return $restoreLaunchMethod['Restore'].Invoke($null, [object[]]@($config, ('a' * 64), $Destination, (New-StringList @('/a.txt')), $false, $SessionHost, $null, $null, $onProgress))
    }
    # The stand-in is started in place of the installed manager, which must be there (it is never run).
    [IO.File]::WriteAllText((Join-Path $installRoot 'Manage-Restore.ps1'), "# never run by the regression suite`n", (New-Object System.Text.UTF8Encoding($false)))
    $sessionDestination = [string](Join-Path $tempRoot 'session-restore')

    # One approval serves every listing and the one restore; only a session that ended asks again.
    $fakeBroker::Reset('normal')
    $sessionHost = New-SessionHost
    $listed = Invoke-SessionList $sessionHost
    Assert-True ($listed.Succeeded -and $listed.Snapshots.Count -eq 1 -and $fakeBroker::Launches -eq 1 -and $fakeBroker::Hellos -eq 1) ('a session did not list snapshots: ' + $listed.ErrorMessage)
    Assert-True ([bool](Get-HostValue $sessionHost 'HasLiveSession') -and $progressSeen.Contains('reading')) 'a session did not stay open, or its progress was not passed on'
    $rootRead = Invoke-SessionTree $sessionHost '/'
    $folderRead = Invoke-SessionTree $sessionHost '/Docs'
    Assert-True ($rootRead.Succeeded -and $folderRead.Succeeded -and $folderRead.Entries.Count -eq 1 -and $fakeBroker::Launches -eq 1) ('folder reads in a session asked Windows again: ' + $fakeBroker::Launches + ' ' + $folderRead.ErrorMessage)
    $restored = Invoke-SessionRestore $sessionHost $sessionDestination
    Assert-True ($restored.Succeeded -and $restored.Report.Verified -and $fakeBroker::Launches -eq 1) ('a session restore did not complete in the approved session: ' + $restored.ErrorMessage)
    Assert-True (-not [bool](Get-HostValue $sessionHost 'HasLiveSession')) 'a session stayed open after its one restore'
    $afterRestore = Invoke-SessionTree $sessionHost '/'
    Assert-True ($afterRestore.Succeeded -and $fakeBroker::Launches -eq 2) 'a read after the session''s one restore did not start a new session'
    Assert-True (($fakeBroker::Requests -join '|') -eq 'list_snapshots |list_tree /|list_tree /Docs|restore |list_tree /') ('the sessions did not serve the requests in order: ' + ($fakeBroker::Requests -join '|'))
    Invoke-Private $sessionHost 'Close' | Out-Null
    Assert-True ((Wait-Until { $fakeBroker::Closes -eq 1 }) -and [bool](Get-HostValue $sessionHost 'IsClosed')) 'closing the host did not close its session'
    $closedRead = Invoke-SessionList $sessionHost
    Assert-True (-not $closedRead.Succeeded -and $fakeBroker::Launches -eq 2) 'a closed host started another session'

    # A session that ended on its own (idle, lifetime, a changed plan) is replaced, once, for a request it never read.
    $fakeBroker::Reset('closeAfterFirst')
    $sessionHost = New-SessionHost
    Assert-True ((Invoke-SessionList $sessionHost).Succeeded -and $fakeBroker::Launches -eq 1) 'the first request of a session failed'
    $replaced = Invoke-SessionTree $sessionHost '/'
    Assert-True ($replaced.Succeeded -and $fakeBroker::Launches -eq 2) ('a session that had ended was not replaced for the next request: ' + $replaced.ErrorMessage)
    Invoke-Private $sessionHost 'Close' | Out-Null

    # A declined approval is a cancelled step, as without a session.
    $fakeBroker::Reset('decline')
    $sessionHost = New-SessionHost
    $declined = Invoke-SessionList $sessionHost
    Assert-True ($declined.UserCancelled -and -not $declined.Succeeded -and $fakeBroker::Launches -eq 1) 'a declined approval was not reported as cancelled'
    Set-PrivateField $dashboard 'restoreFlowApprovalSession' $sessionHost
    Assert-True ((Invoke-Private $dashboard 'RestoreFlowApprovalNotice') -match 'ask once' -and [int](Get-HostValue $sessionHost 'Opened') -eq 0) 'a declined approval was described as an ended session'
    Set-PrivateField $dashboard 'restoreFlowApprovalSession' $null
    Invoke-Private $sessionHost 'Close' | Out-Null

    # The pipe's server must be the process that was started: anyone could create a pipe of that name first.
    $bystander = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
    try {
        $fakeBroker::Reset('wrongServer')
        $fakeBroker::WrongServerProcessId = $bystander.Id
        $sessionHost = New-SessionHost
        $squatted = Invoke-SessionList $sessionHost
        Assert-True (-not $squatted.Succeeded -and $squatted.ErrorMessage -match 'could not be verified' -and $fakeBroker::Hellos -eq 0) ('the dashboard talked to a pipe whose server it did not start: ' + $squatted.ErrorMessage)
        Invoke-Private $sessionHost 'Close' | Out-Null
    }
    finally { try { $bystander.Kill() } catch { } }

    # A frame over the limit, or a result bound to another request, ends the session and is never accepted.
    $fakeBroker::Reset('oversized')
    $sessionHost = New-SessionHost
    $oversized = Invoke-SessionList $sessionHost
    Assert-True (-not $oversized.Succeeded -and $oversized.ErrorMessage -match 'size limit' -and -not [bool](Get-HostValue $sessionHost 'HasLiveSession')) ('an oversized session frame was accepted: ' + $oversized.ErrorMessage)
    Invoke-Private $sessionHost 'Close' | Out-Null
    $fakeBroker::Reset('foreignNonce')
    $sessionHost = New-SessionHost
    $foreign = Invoke-SessionList $sessionHost
    Assert-True (-not $foreign.Succeeded -and $foreign.ErrorMessage -match 'did not match this request') ('a session result bound to another request was accepted: ' + $foreign.ErrorMessage)
    Invoke-Private $sessionHost 'Close' | Out-Null

    # The installed engine decides: a session needs the profile's broker and the engine's own capability document.
    $capabilityRoot = Join-Path $tempRoot 'capabilities'
    New-Item -ItemType Directory -Path $capabilityRoot -Force | Out-Null
    $capabilityPath = Join-Path $capabilityRoot 'engine-capabilities.json'
    $repositoryCapabilities = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\engine-capabilities.json') -Raw
    function Test-SessionCapability([object]$EngineProfile, [string]$Root) { return [bool]$sessionCapabilityType.GetMethod('IsSupported', $flags).Invoke($null, [object[]]@($EngineProfile, $Root)) }
    Assert-True (-not (Test-SessionCapability $rewindleEngine $capabilityRoot)) 'an engine without a capability document was given a session'
    [IO.File]::WriteAllText($capabilityPath, $repositoryCapabilities, (New-Object System.Text.UTF8Encoding($false)))
    Assert-True (Test-SessionCapability $rewindleEngine $capabilityRoot) 'the engine''s own capability document was not accepted'
    Assert-True (-not (Test-SessionCapability $legacyEngine $capabilityRoot)) 'the legacy personal edition was given a session'
    foreach ($forged in @(
        $repositoryCapabilities.Replace('RestoreSession.v1', 'RestoreSession.v9'),
        $repositoryCapabilities.Replace('RestoreRequest.v3', 'RestoreRequest.v2'),
        $repositoryCapabilities.Replace('EngineCapabilities.v1', 'EngineCapabilities.v2'),
        $repositoryCapabilities.Replace('"schema_version": 1', '"schema_version": 2'),
        $repositoryCapabilities.Replace('Manage-Restore.ps1', 'Other.ps1'),
        '[1]',
        ($repositoryCapabilities + (' ' * 17000)))) {
        [IO.File]::WriteAllText($capabilityPath, $forged, (New-Object System.Text.UTF8Encoding($false)))
        Assert-True (-not (Test-SessionCapability $rewindleEngine $capabilityRoot)) ('a capability document that does not name this engine''s session was accepted: ' + $forged.Substring(0, [Math]::Min(60, $forged.Length)))
    }
    [IO.File]::WriteAllText((Join-Path $junctionTarget 'engine-capabilities.json'), $repositoryCapabilities, (New-Object System.Text.UTF8Encoding($false)))
    Assert-True (-not (Test-SessionCapability $rewindleEngine $junction)) 'a capability document behind a link was accepted'
    # Opening Restore picks the session or the per-step approvals from that.
    [IO.File]::WriteAllText((Join-Path $installRoot 'engine-capabilities.json'), $repositoryCapabilities, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-Private $dashboard 'ResetRestoreFlowSession' @($config, $configHash) | Out-Null
    $openedHost = Get-FieldValue $dashboard 'restoreFlowApprovalSession'
    Assert-True ($null -ne $openedHost -and (Invoke-Private $dashboard 'BuildWebRestoreFlowState')['approval']['session'] -eq $true) 'Restore did not use one session with an engine that serves them'
    Assert-True ((Invoke-Private $dashboard 'RestoreFlowApprovalNotice') -eq 'Windows will ask once to allow Rewindle to read and restore from your backup.') 'the page was not told Windows asks once'
    Remove-Item -LiteralPath (Join-Path $installRoot 'engine-capabilities.json') -Force
    Invoke-Private $dashboard 'ResetRestoreFlowSession' @($config, $configHash) | Out-Null
    Assert-True ([bool](Get-HostValue $openedHost 'IsClosed')) 'reopening Restore kept the previous session'
    Assert-True ($null -eq (Get-FieldValue $dashboard 'restoreFlowApprovalSession') -and (Invoke-Private $dashboard 'BuildWebRestoreFlowState')['approval']['session'] -eq $false) 'an engine without sessions was not given one approval per step'
    Assert-True ((Invoke-Private $dashboard 'RestoreFlowApprovalNotice') -match 'each protected step') 'the per-step approvals were described as one'

    # The flow's session ends with the flow, and with a plan that changed.
    $fakeBroker::Reset('normal')
    $flowHost = New-SessionHost
    Assert-True ((Invoke-SessionList $flowHost).Succeeded -and [bool](Get-HostValue $flowHost 'HasLiveSession')) 'the flow''s session did not open'
    Set-PrivateField $dashboard 'restoreFlowApprovalSession' $flowHost
    Assert-True ((Invoke-Private $dashboard 'RestoreFlowApprovalNotice') -match 'ended, so Windows will ask again') 'a session that had been approved was not described as ended when it asks again'
    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowBusy' $false
    [void](Invoke-Private $dashboard 'StoreRestoreFlowTreeListing' @('snapshot', '/', (New-TreeEntries '/' 1)))
    $closeArgs = [object[]]@($null)
    Assert-True ([bool](Invoke-Private $dashboard 'CloseRestoreFlow' $closeArgs)) 'Restore could not be closed'
    Assert-True ([bool](Get-HostValue $flowHost 'IsClosed') -and (Wait-Until { $fakeBroker::Closes -eq 1 }) -and $null -eq (Get-FieldValue $dashboard 'restoreFlowApprovalSession') -and
        $null -eq (Get-FieldValue $dashboard 'restoreFlowTreeCache')) 'closing Restore kept its session or its folder listings'
    $fakeBroker::Reset('normal')
    $changedHost = New-SessionHost
    Assert-True ((Invoke-SessionList $changedHost).Succeeded) 'the session for the plan change did not open'
    Set-PrivateField $dashboard 'restoreFlowOpen' $true
    Set-PrivateField $dashboard 'restoreFlowApprovalSession' $changedHost
    Set-PrivateField $dashboard 'restoreFlowConfiguration' $fixtureConfig
    Set-PrivateField $dashboard 'restoreFlowConfigHash' ('0' * 64)
    Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $fixtureConfig.ConfigGeneration
    Set-PrivateField $dashboard 'restoreFlowPlanId' $fixtureConfig.PlanId
    [void](Invoke-Private $dashboard 'StoreRestoreFlowTreeListing' @('snapshot', '/', (New-TreeEntries '/' 1)))
    $staleArgs = [object[]]@($null, $null)
    Assert-True (-not [bool](Invoke-Private $dashboard 'TryGetFreshRestoreFlowConfiguration' $staleArgs)) 'a changed plan was accepted'
    Assert-True ([bool](Get-HostValue $changedHost 'IsClosed') -and (Wait-Until { $fakeBroker::Closes -eq 1 }) -and $null -eq (Get-FieldValue $dashboard 'restoreFlowTreeCache')) 'a changed plan kept the session or the folder listings'
    Remove-Item -LiteralPath $fixturePlanPath -Force
    Set-PrivateField $dashboard 'restoreFlowConfiguration' $config
    Set-PrivateField $dashboard 'restoreFlowConfigHash' $configHash
    Set-PrivateField $dashboard 'restoreFlowConfigGeneration' $config.ConfigGeneration
    Set-PrivateField $dashboard 'restoreFlowPlanId' $config.PlanId
    Set-PrivateField $dashboard 'restoreFlowStep' 'error'
    Set-PrivateField $dashboard 'restoreFlowOpen' $true

    # A schedule that cannot be read has a stable summary and nothing in its detail; the reason Windows gave travels on its own
    # for the page to word, and the outcome of a schedule change shows only while it is current (or the change is under way).
    $unreadableReason = 'Technical: access denied (0x80070005) while reading the task'
    Set-PrivateField $dashboard 'currentTaskSchedule' $null
    Set-PrivateField $dashboard 'scheduleReadError' $unreadableReason
    $unreadableState = Invoke-Private $dashboard 'BuildWebScheduleState'
    Assert-True ($unreadableState['summary'] -eq 'Schedule unavailable') 'an unreadable schedule was summarised with the raw error'
    Assert-True ([string]::IsNullOrEmpty([string]$unreadableState['detail'])) 'an unreadable schedule repeated the raw error as its detail'
    Assert-True ($unreadableState['error'] -eq $unreadableReason) 'an unreadable schedule did not publish its reason'
    Assert-True ($null -eq $unreadableState['notice']) 'a schedule notice showed although no change was made'
    Set-PrivateField $dashboard 'scheduleNoticeText' 'Schedule updated and independently verified.'
    Set-PrivateField $dashboard 'scheduleNoticeTone' 'success'
    Set-PrivateField $dashboard 'scheduleNoticeExpiresUtc' ([DateTime]::UtcNow.AddMinutes(1))
    $noticeState = Invoke-Private $dashboard 'BuildWebScheduleState'
    Assert-True ($noticeState['notice']['text'] -eq 'Schedule updated and independently verified.' -and $noticeState['notice']['tone'] -eq 'success') 'the outcome of a schedule change did not reach the page'
    Set-PrivateField $dashboard 'scheduleNoticeExpiresUtc' ([DateTime]::UtcNow.AddMinutes(-1))
    Assert-True ($null -eq (Invoke-Private $dashboard 'BuildWebScheduleState')['notice']) 'the outcome of a schedule change did not lapse'
    Set-PrivateField $dashboard 'scheduleOperationInProgress' $true
    Assert-True ($null -ne (Invoke-Private $dashboard 'BuildWebScheduleState')['notice']) 'the progress of a schedule change lapsed while Windows approval was still pending'
    Set-PrivateField $dashboard 'scheduleOperationInProgress' $false

    # All seven selected days read "Every day", in words only: the cadence stays SelectedDays, so what is compared and what the
    # protected manager is asked to write do not change. A daily schedule and a partial selection read as they always did.
    $canonicalizerType = $assembly.GetType('ResticBackuper.Dashboard.TaskScheduleCanonicalizer', $true)
    $cadenceType = $assembly.GetType('ResticBackuper.Dashboard.BackupScheduleCadence', $true)
    $selectedDaysCadence = [Enum]::Parse($cadenceType, 'SelectedDays')
    $dailyCadence = [Enum]::Parse($cadenceType, 'Daily')
    $twoOClock = [TimeSpan]::FromHours(2)
    $everyWeekday = [DayOfWeek[]]@('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    $workWeek = [DayOfWeek[]]@('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
    Assert-True ((Invoke-Static $canonicalizerType 'CreateSummary' @($selectedDaysCadence, $twoOClock, $everyWeekday, $true)) -eq 'Every day at 02:00') 'a schedule on all seven days was not summarised as every day'
    Assert-True ((Invoke-Static $canonicalizerType 'CreateSummary' @($selectedDaysCadence, $twoOClock, $everyWeekday, $false)) -eq ('Paused ' + [char]0x2014 + ' Every day at 02:00')) 'a paused schedule on all seven days lost its paused marker'
    Assert-True ((Invoke-Static $canonicalizerType 'CreateSummary' @($selectedDaysCadence, $twoOClock, $workWeek, $true)) -eq 'Mon, Tue, Wed, Thu, Fri at 02:00') 'a partial selection of days was not listed'
    Assert-True ((Invoke-Static $canonicalizerType 'CreateSummary' @($dailyCadence, $twoOClock, [DayOfWeek[]]@(), $true)) -eq 'Daily at 02:00') 'a daily schedule was no longer summarised as daily'

    # The schedule editor takes a time as 2:00 and 2.30 as well as 02:00, and still refuses anything that is not a time of day.
    $scheduleEditorType = $assembly.GetType('ResticBackuper.Dashboard.ScheduleEditorWindow', $true)
    foreach ($case in @(
        @{ Text = '02:00'; Expected = '02:00' }, @{ Text = '2:00'; Expected = '02:00' }, @{ Text = '2.30'; Expected = '02:30' },
        @{ Text = ' 18:45 '; Expected = '18:45' }, @{ Text = '0:00'; Expected = '00:00' }, @{ Text = '23:59'; Expected = '23:59' })) {
        $timeArgs = [object[]]@($case.Text, $null)
        Assert-True ([bool](Invoke-Static $scheduleEditorType 'TryParseTime' $timeArgs)) ("the schedule editor refused the time '" + $case.Text + "'")
        $parsed = [TimeSpan]$timeArgs[1]
        Assert-True (($parsed.Hours.ToString('00') + ':' + $parsed.Minutes.ToString('00')) -eq $case.Expected) ("the schedule editor read the time '" + $case.Text + "' as " + $parsed)
    }
    foreach ($text in @('24:00', '2:60', '7:5', '12', 'ab', '', '   ', '1:2:3', '-1:00')) {
        $timeArgs = [object[]]@($text, $null)
        Assert-True (-not [bool](Invoke-Static $scheduleEditorType 'TryParseTime' $timeArgs)) ("the schedule editor accepted '" + $text + "' as a time")
    }

    # A crashed web view is reloaded on its own at most three times in five minutes, then the notice with
    # its Reload button takes over, so a crash loop cannot spin. The allowance comes back with time.
    $recoveryTimes = [System.Collections.Generic.List[DateTime]]::new()
    Set-PrivateField $dashboard 'webPresentationRecoveryUtc' $recoveryTimes
    $allowances = @(1..4 | ForEach-Object { [bool](Invoke-Private $dashboard 'TryBeginWebPresentationRecovery') })
    Assert-True (($allowances -join ',') -eq 'True,True,True,False') 'automatic web view reloads were not capped at three'
    $recoveryTimes.Clear()
    foreach ($attempt in 1..3) { $recoveryTimes.Add([DateTime]::UtcNow.AddMinutes(-6)) }
    Assert-True ([bool](Invoke-Private $dashboard 'TryBeginWebPresentationRecovery')) 'the automatic reload allowance did not return after five minutes'
    # A missing WebView2 Runtime is told apart from any other start-up failure, because only it offers the download.
    $webViewCore = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path -Parent $resolvedExecutable) 'Microsoft.Web.WebView2.Core.dll'))
    $missingRuntime = [Activator]::CreateInstance($webViewCore.GetType('Microsoft.Web.WebView2.Core.WebView2RuntimeNotFoundException', $true), [object[]]@('no runtime'))
    $fileNotFound = [System.Runtime.InteropServices.COMException]::new('file not found', -2147024894)
    $otherFailure = [System.Runtime.InteropServices.COMException]::new('access denied', -2147024891)
    Assert-True ([bool](Invoke-Static $dashboardType 'IsWebViewRuntimeMissing' @($missingRuntime))) 'WebView2RuntimeNotFoundException was not recognised as a missing runtime'
    Assert-True ([bool](Invoke-Static $dashboardType 'IsWebViewRuntimeMissing' @($fileNotFound))) 'an ERROR_FILE_NOT_FOUND start-up failure was not recognised as a missing runtime'
    Assert-True (-not [bool](Invoke-Static $dashboardType 'IsWebViewRuntimeMissing' @($otherFailure))) 'another start-up failure was reported as a missing runtime'
    Assert-True (-not [bool](Invoke-Static $dashboardType 'IsWebViewRuntimeMissing' @([InvalidOperationException]::new('boom')))) 'a generic failure was reported as a missing runtime'

    # A page that stops answering may only be busy, so it is not reloaded at the first report (that would throw away what it holds and
    # spend the automatic reloads on a slow page). The browser repeats its report every few seconds while the page is stuck: the notice
    # is raised once, when it has been stuck for fifteen seconds, and a quiet spell means it recovered and starts the count over.
    $reportStart = [DateTime]::UtcNow
    $reportOutcomes = foreach ($second in 0, 5, 10, 14, 16, 20, 40, 45, 50, 54, 56) { [bool](Invoke-Private $dashboard 'NoteWebPresentationUnresponsiveReport' @($reportStart.AddSeconds($second))) }
    Assert-True (($reportOutcomes -join ',') -eq 'False,False,False,False,True,False,False,False,False,False,True') ('the not-responding notice was not raised once per stuck episode, after fifteen seconds: ' + ($reportOutcomes -join ','))

    # Backup freshness around a change of the clocks, in a fixed zone (US Eastern) so that the result does not depend on this computer's
    # own. In the hour that repeats when the clocks go back, a local reading fits two UTC moments an hour apart and both are real, so
    # the clocks agree when either fits; a local time that never exists is still an anomaly. A slot in that hour is due from its first
    # occurrence, so a backup that ran at either one covers it. Pure arithmetic: nothing is read from disk.
    $evaluatorType = $assembly.GetType('ResticBackuper.Dashboard.BackupFreshnessEvaluator', $true)
    $taskScheduleType = $assembly.GetType('ResticBackuper.Dashboard.TaskSchedule', $true)
    $taskStateType = $assembly.GetType('ResticBackuper.Dashboard.BackupTaskState', $true)
    $easternTime = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $evaluate = @($evaluatorType.GetMethods($flags) | Where-Object { $_.Name -eq 'Evaluate' -and $_.GetParameters().Count -eq 7 })[0]
    Assert-True ($null -ne $evaluate) 'the freshness evaluator has no overload that takes a covered-through moment'
    # `Flags` are the schedule's settings in the order of its constructor: enabled, start when available, wake to run, allow start on
    # batteries, stop if going on batteries, allow demand start.
    function New-FreshnessSchedule([TimeSpan]$TimeOfDay, [bool[]]$Flags = @($true, $false, $false, $false, $true, $true)) {
        # Built a value at a time: an empty array in an array literal would vanish from the argument list.
        $values = New-Object 'System.Collections.Generic.List[object]'
        [void]$values.Add([Enum]::Parse($cadenceType, 'Daily'))
        [void]$values.Add($TimeOfDay)
        [void]$values.Add([Array]::CreateInstance([DayOfWeek], 0))
        foreach ($flag in $Flags) { [void]$values.Add($flag) }
        foreach ($text in 'ResticPersonalBackup', 'S-1-5-21-0-0-0-1000', 'launcher.exe', 'C:\fixture') { [void]$values.Add($text) }
        [void]$values.Add([Enum]::Parse($taskStateType, 'Ready'))
        [void]$values.Add($null)
        [void]$values.Add('fingerprint')
        return [Activator]::CreateInstance($taskScheduleType, $constructorFlags, $null, $values.ToArray(), $null)
    }
    function Get-FreshnessState($Schedule, [string]$VerifiedUtc, [string]$NowLocal, [string]$NowUtc, [string]$CoveredUtc = '') {
        $moment = { param([string]$text) [DateTime]::SpecifyKind([DateTime]::Parse($text, [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc) }
        $verified = $null
        if ($VerifiedUtc) { $verified = [Nullable[DateTime]](& $moment $VerifiedUtc) }
        $covered = $null
        if ($CoveredUtc) { $covered = [Nullable[DateTime]](& $moment $CoveredUtc) }
        $local = [DateTime]::SpecifyKind([DateTime]::Parse($NowLocal, [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Unspecified)
        $arguments = [object[]]@($Schedule, $verified, $local, (& $moment $NowUtc), $easternTime, [TimeSpan]::FromHours(2), $covered)
        $freshness = $evaluate.Invoke($null, $arguments)
        return [string]$freshness.State
    }
    $twoAm = New-FreshnessSchedule ([TimeSpan]::FromHours(2))
    $oneThirty = New-FreshnessSchedule ([TimeSpan]::FromMinutes(90))
    $sixPm = New-FreshnessSchedule ([TimeSpan]::FromHours(18))
    # On 2026-11-01, 02:00 EDT falls back to 01:00 EST, so local 01:30 happens at 05:30Z and again at 06:30Z.
    Assert-True ((Get-FreshnessState $twoAm '2026-10-31 06:40' '2026-11-01 01:30' '2026-11-01 05:30') -ne 'ClockAnomaly') 'the first pass through the repeated hour was called a clock anomaly'
    Assert-True ((Get-FreshnessState $twoAm '2026-10-31 06:40' '2026-11-01 01:30' '2026-11-01 06:30') -ne 'ClockAnomaly') 'the second pass through the repeated hour was called a clock anomaly'
    Assert-True ((Get-FreshnessState $twoAm '2026-10-31 06:40' '2026-11-01 01:30' '2026-11-01 07:30') -eq 'ClockAnomaly') 'a local reading an hour from UTC inside the repeated hour was not called an anomaly'
    Assert-True ((Get-FreshnessState $twoAm '2026-11-01 07:10' '2026-11-01 12:00' '2026-11-01 16:00') -eq 'ClockAnomaly') 'a reading an hour off outside the repeated hour was not called an anomaly'
    # On 2026-03-08, 02:00 EST jumps to 03:00 EDT, so local 02:30 never exists.
    Assert-True ((Get-FreshnessState $twoAm '2026-03-07 07:10' '2026-03-08 02:30' '2026-03-08 07:30') -eq 'ClockAnomaly') 'a local time that does not exist was not called an anomaly'
    Assert-True ((Get-FreshnessState $oneThirty '2026-11-01 05:40' '2026-11-01 10:00' '2026-11-01 15:00') -eq 'Healthy') 'a backup that ran at the first of two 01:30s was called overdue'
    Assert-True ((Get-FreshnessState $oneThirty '2026-10-31 05:40' '2026-11-01 10:00' '2026-11-01 15:00') -eq 'Overdue') 'a backup that missed the 01:30 slot was not called overdue'
    # Moving the run times leaves slots earlier today that the task never had (set to 18:00 at 20:30 and there was no 18:00 run today).
    # A backup that was current at the change is not held to them; the first slot after the change is still required.
    $morningBackup = '2026-10-03 06:05'
    $changedAt = '2026-10-04 00:30'
    Assert-True ((Get-FreshnessState $sixPm $morningBackup '2026-10-03 21:00' '2026-10-04 01:00') -eq 'Overdue') 'the changed-schedule fixture did not start out overdue'
    Assert-True ((Get-FreshnessState $sixPm $morningBackup '2026-10-03 21:00' '2026-10-04 01:00' $changedAt) -eq 'Healthy') 'a slot from before the schedule changed was held against a backup that was current at the change'
    Assert-True ((Get-FreshnessState $sixPm $morningBackup '2026-10-04 21:00' '2026-10-05 01:00' $changedAt) -eq 'Overdue') 'the first slot after the change was not required of the backup'
    Assert-True ((Get-FreshnessState $sixPm $morningBackup '2026-10-03 21:00' '2026-10-04 01:00' '2026-10-05 00:00') -eq 'Overdue') 'a covered-through moment in the future was believed'
    Assert-True ([bool](Invoke-Static $evaluatorType 'SameRunTimes' @($twoAm, (New-FreshnessSchedule ([TimeSpan]::FromHours(2)))))) 'two schedules at the same time were not recognised as the same run times'
    Assert-True (-not [bool](Invoke-Static $evaluatorType 'SameRunTimes' @($twoAm, $sixPm))) 'two schedules at different times were recognised as the same run times'

    # The tray's "Backup started" balloon is for a backup starting, not for every phase of one (the state key is the phase), and not for a
    # dashboard that was opened in the middle of a run. A hidden tray icon stands in: the balloon's title shows which message was raised.
    Add-Type -AssemblyName System.Windows.Forms
    $telemetrySnapshotType = $assembly.GetType('ResticBackuper.Dashboard.TelemetrySnapshot', $true)
    $balloonDashboard = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
    $balloonIcon = New-Object System.Windows.Forms.NotifyIcon
    try {
        Set-PrivateField $balloonDashboard 'trayIcon' $balloonIcon
        function Get-BalloonTitle([string]$StateKey, [bool]$Active, [bool]$Success, [bool]$Failure) {
            $next = [Activator]::CreateInstance($telemetrySnapshotType, $constructorFlags, $null, @(), $null)
            $next.StateKey = $StateKey
            $next.IsActive = $Active
            $next.IsSuccess = $Success
            $next.IsFailure = $Failure
            $next.StatusDetail = 'fixture'
            $balloonIcon.BalloonTipTitle = '(none)'
            Invoke-Private $balloonDashboard 'HandleStateTransition' @($next) | Out-Null
            return [string]$balloonIcon.BalloonTipTitle
        }
        Assert-True ((Get-BalloonTitle 'backing_up' $true $false $false) -eq '(none)') 'a dashboard opened in the middle of a run announced a start'
        Assert-True ((Get-BalloonTitle 'verifying_snapshot' $true $false $false) -eq '(none)') 'a phase change inside a run announced a start'
        Assert-True ((Get-BalloonTitle 'checking_repository' $true $false $false) -eq '(none)') 'a second phase change inside a run announced a start'
        Assert-True ((Get-BalloonTitle 'success' $false $true $false) -eq 'Backup verified') 'a run that finished did not say Backup verified'
        Assert-True ((Get-BalloonTitle 'starting' $true $false $false) -eq 'Backup started') 'a backup starting did not say Backup started'
        Assert-True ((Get-BalloonTitle 'backing_up' $true $false $false) -eq '(none)') 'the phase after a start announced another start'
        Assert-True ((Get-BalloonTitle 'cancelling' $true $false $false) -eq '(none)') 'a cancel being carried out announced a start'
        Assert-True ((Get-BalloonTitle 'cancelled' $false $false $false) -eq '(none)') 'a cancelled run raised a balloon of its own from the state change'
        Assert-True ((Get-BalloonTitle 'starting' $true $false $false) -eq 'Backup started') 'a backup that starts after a cancelled one did not say Backup started'
        Assert-True ((Get-BalloonTitle 'failed' $false $false $true) -eq 'Backup needs attention') 'a failed run did not say Backup needs attention'
    }
    finally {
        $balloonIcon.Dispose()
    }

    # A status that cannot be read is no news. It raises no balloon of its own, and it is not a state that a run left or entered: the first
    # readable snapshot after it is compared with the last readable one, so a run that was already announced is not announced again after a
    # gap in its file, while a run that really changed (or finished meanwhile) still is. Hidden tray icon, no window.
    $gapDashboard = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
    $gapIcon = New-Object System.Windows.Forms.NotifyIcon
    try {
        Set-PrivateField $gapDashboard 'trayIcon' $gapIcon
        function Get-GapBalloonTitle([string]$StateKey, [bool]$Active, [bool]$Success, [bool]$Failure, [bool]$Unavailable, [string]$RunId) {
            $next = [Activator]::CreateInstance($telemetrySnapshotType, $constructorFlags, $null, @(), $null)
            $next.StateKey = $StateKey
            $next.IsActive = $Active
            $next.IsSuccess = $Success
            $next.IsFailure = $Failure
            $next.IsStatusUnavailable = $Unavailable
            $next.RunId = $RunId
            $next.StatusDetail = 'fixture'
            $gapIcon.BalloonTipTitle = '(none)'
            Invoke-Private $gapDashboard 'HandleStateTransition' @($next) | Out-Null
            return [string]$gapIcon.BalloonTipTitle
        }
        function Get-GapBalloonTitleForUnreadable() { return Get-GapBalloonTitle 'telemetry_error' $false $false $false $true '' }
        Assert-True ((Get-GapBalloonTitle 'success' $false $true $false $false 'run-a') -eq '(none)') 'the first readable status raised a balloon'
        Assert-True ((Get-GapBalloonTitleForUnreadable) -eq '(none)') 'an unreadable status raised a balloon of its own'
        Assert-True ((Get-GapBalloonTitle 'success' $false $true $false $false 'run-a') -eq '(none)') 'a run that was already announced was announced again after a gap in its status'
        Assert-True ((Get-GapBalloonTitleForUnreadable) -eq '(none)') 'a second unreadable status raised a balloon'
        Assert-True ((Get-GapBalloonTitle 'success' $false $true $false $false 'run-b') -eq 'Backup verified') 'a run that finished while the status could not be read was not announced'
        Assert-True ((Get-GapBalloonTitleForUnreadable) -eq '(none)') 'an unreadable status raised a balloon after a verified run'
        Assert-True ((Get-GapBalloonTitle 'failed' $false $false $true $false 'run-c') -eq 'Backup needs attention') 'a failure that arrived after a gap in the status was not announced'
        Assert-True ((Get-GapBalloonTitleForUnreadable) -eq '(none)') 'an unreadable status raised a balloon after a failed run'
        Assert-True ((Get-GapBalloonTitle 'failed' $false $false $true $false 'run-c') -eq '(none)') 'a failure that was already announced was announced again after a gap in the status'
        Assert-True ((Get-GapBalloonTitle 'backing_up' $true $false $false $false 'run-d') -eq 'Backup started') 'a backup that started was not announced'
        Assert-True ((Get-GapBalloonTitleForUnreadable) -eq '(none)') 'an unreadable status raised a balloon during a run'
        Assert-True ((Get-GapBalloonTitle 'verifying_snapshot' $true $false $false $false 'run-d') -eq '(none)') 'a gap in the status made the next phase of a run look like a new start'
    }
    finally {
        $gapIcon.Dispose()
    }

    # The tray icon's hover text says where the backup stands, in a form that fits the 63 characters a tray icon allows (a longer text makes
    # NotifyIcon throw). Hidden tray icon, no window; the schedule is unknown, so only the last verified time speaks.
    $hoverDashboard = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
    $hoverIcon = New-Object System.Windows.Forms.NotifyIcon
    try {
        Set-PrivateField $hoverDashboard 'trayIcon' $hoverIcon
        function Get-TrayHoverText([scriptblock]$Shape) {
            $next = [Activator]::CreateInstance($telemetrySnapshotType, $constructorFlags, $null, @(), $null)
            & $Shape $next
            Invoke-Private $hoverDashboard 'UpdateTrayText' @($next) | Out-Null
            return [string]$hoverIcon.Text
        }
        Assert-True ((Get-TrayHoverText { param($snapshot) $snapshot.IsStatusUnavailable = $true }) -eq 'Rewindle - status unavailable') ('the tray did not say that the status is unavailable: ' + $hoverIcon.Text)
        Assert-True ((Get-TrayHoverText { param($snapshot) $snapshot.IsActive = $true; $snapshot.Percent = 0.42 }) -eq 'Rewindle - backup running 42%') ('the tray did not show a running backup: ' + $hoverIcon.Text)
        Assert-True ((Get-TrayHoverText { param($snapshot) $snapshot.IsFailure = $true }) -eq 'Rewindle - last backup needs attention') ('the tray did not say that the last backup needs attention: ' + $hoverIcon.Text)
        Assert-True ((Get-TrayHoverText { param($snapshot) $snapshot.LastVerifiedFinishedUtc = [DateTime]::UtcNow.AddHours(-2) }) -eq 'Rewindle - verified 2 h ago') ('the tray did not say how long ago a backup was verified: ' + $hoverIcon.Text)
        Assert-True ((Get-TrayHoverText { param($snapshot) $snapshot.LastVerifiedFinishedUtc = [DateTime]::UtcNow.AddDays(-3) }) -eq 'Rewindle - verified 3 days ago') ('the tray did not count days: ' + $hoverIcon.Text)
        Assert-True ((Get-TrayHoverText { param($snapshot) $snapshot.LastVerifiedFinishedUtc = [DateTime]::UtcNow.AddSeconds(-5) }) -eq 'Rewindle - verified just now') ('the tray did not say a backup was just verified: ' + $hoverIcon.Text)
        Assert-True ((Get-TrayHoverText { param($snapshot) }) -eq 'Rewindle - no verified backup yet') ('the tray did not say that no backup is verified yet: ' + $hoverIcon.Text)
        Assert-True ($hoverIcon.Text.Length -le 63) 'the tray hover text is longer than a tray icon allows'
    }
    finally {
        $hoverIcon.Dispose()
    }

    # What the page is told about the backup service. engineFound is false only once the host is sure nothing is installed, and `problem` is the
    # one fixed sentence for a configuration that is not in use (and empty while one is). The words of an exception never reach it: they can
    # name a path.
    $setupDashboard = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
    $beforeFirstRead = Invoke-Private $setupDashboard 'BuildWebSetupState'
    Assert-True ($beforeFirstRead['engineFound'] -eq $true -and [string]$beforeFirstRead['problem'] -eq '') 'the page was told the service is missing before anything was read'
    Set-PrivateField $setupDashboard 'sourceInstallationMissing' $true
    Set-PrivateField $setupDashboard 'sourceConfigurationNote' 'Engine not installed: Rewindle did not find the backup engine it reports on.'
    $missingSetup = Invoke-Private $setupDashboard 'BuildWebSetupState'
    Assert-True ($missingSetup['engineFound'] -eq $false -and [string]$missingSetup['problem'] -eq 'Engine not installed: Rewindle did not find the backup engine it reports on.') 'the page was not told the service is missing'
    Assert-True (-not [string]::IsNullOrEmpty([string]$missingSetup['appVersion']) -and ([string]$missingSetup['expectedConfig']) -like '*backup-config.json') 'the page was not given what a bug report about a missing service needs'
    Assert-True ([string]$missingSetup['engine'] -eq 'Rewindle engine' -and [string]$missingSetup['engineProfile'] -eq 'rewindle' -and [string]$missingSetup['engineVersion'] -eq '') ('the page was not told which engine is missing: ' + [string]$missingSetup['engine'])
    Set-PrivateField $setupDashboard 'currentSourceConfiguration' $config
    $inUseSetup = Invoke-Private $setupDashboard 'BuildWebSetupState'
    Assert-True ([string]$inUseSetup['problem'] -eq '') 'a configuration that is in use still carried a problem'
    $missingServiceType = $assembly.GetType('ResticBackuper.Dashboard.BackupInstallationMissingException', $true)
    $missingError = [Activator]::CreateInstance($missingServiceType, $constructorFlags, $null, [object[]]@('C:\Program Files\RewindleFixture\backup-config.json'), $null)
    Assert-True ($missingError -is [System.IO.FileNotFoundException]) 'a missing installation is no longer a FileNotFoundException, which other callers rely on'
    $missingSentence = [string](Invoke-Static $dashboardType 'DescribeSourceConfigurationProblem' @($missingError))
    Assert-True ($missingSentence -match 'Engine not installed' -and $missingSentence -match 'did not find the backup engine' -and $missingSentence -match 'Requirements') ('a missing installation was not described in plain words: ' + $missingSentence)
    $leakySentence = [string](Invoke-Static $dashboardType 'DescribeSourceConfigurationProblem' @([System.IO.IOException]::new('The process cannot access the file C:\Users\your-user\secret.json')))
    Assert-True ($leakySentence -notmatch 'your-user|secret' -and $leakySentence -match 'could not be read') ('the words of an exception reached the sentence the page shows: ' + $leakySentence)
    $deniedSentence = [string](Invoke-Static $dashboardType 'DescribeSourceConfigurationProblem' @([System.UnauthorizedAccessException]::new('Access to the path C:\Program Files\RewindleFixture is denied.')))
    Assert-True ($deniedSentence -match 'access denied' -and $deniedSentence -notmatch 'RewindleFixture') ('a refused configuration was not described without its path: ' + $deniedSentence)

    # The crash log: an entry per error, the same error not written again within a minute (and counted when the next one comes), a size
    # that stays bounded, and no exception for a place that cannot be written. Its folder is pointed inside the temporary folder.
    $crashLogType = $assembly.GetType('ResticBackuper.Dashboard.CrashLog', $true)
    $crashFolder = Join-Path $tempRoot 'crash-log'
    $crashLogType.GetField('directoryOverride', $flags).SetValue($null, $crashFolder)
    try {
        $crashPath = $crashLogType.GetProperty('FilePath', $flags).GetValue($null)
        Assert-True ($crashPath -eq (Join-Path $crashFolder 'crash.log')) 'the crash log was not placed in its own folder'
        function New-CrashError([string]$Message) { try { throw (New-Object System.InvalidOperationException $Message) } catch { return $_.Exception } }
        [void]$crashLogType.GetMethod('Write', $flags).Invoke($null, [object[]]@('Dispatcher', (New-CrashError 'first failure')))
        $crashText = [IO.File]::ReadAllText($crashPath)
        Assert-True ($crashText -match '^\[\d{4}-\d\d-\d\dT[\d:.]+Z\] Dispatcher' -and $crashText -match 'System\.InvalidOperationException: first failure') 'a crash log entry lacked its time, source or exception'
        foreach ($repeat in 1..5) { [void]$crashLogType.GetMethod('Write', $flags).Invoke($null, [object[]]@('Dispatcher', (New-CrashError 'first failure'))) }
        Assert-True (([regex]::Matches([IO.File]::ReadAllText($crashPath), 'first failure')).Count -eq 1) 'the same error was written again within a minute'
        [void]$crashLogType.GetMethod('Write', $flags).Invoke($null, [object[]]@('Dispatcher', (New-CrashError 'a different failure')))
        Assert-True ([IO.File]::ReadAllText($crashPath) -match 'happened 5 more times') 'the entry after a repeated error did not say how often it repeated'
        $longText = 'x' * 9000
        foreach ($count in 1..80) { [void]$crashLogType.GetMethod('Write', $flags).Invoke($null, [object[]]@('Stress', (New-CrashError ('failure number ' + $count + ' ' + $longText)))) }
        Assert-True (Test-Path -LiteralPath ($crashPath + '.old')) 'a crash log past its limit was not set aside'
        Assert-True ((Get-Item -LiteralPath $crashPath).Length -le 300KB -and (Get-Item -LiteralPath ($crashPath + '.old')).Length -le 300KB) 'the crash log grew past its limit'
        # The same log in a diagnostic bundle: newest part only, and every path, address and token in it redacted (the self-check is
        # the one every other document gets). With no log there is no document.
        $diagnosticsType = $assembly.GetType('ResticBackuper.Dashboard.DiagnosticExporter', $true)
        Remove-Item -LiteralPath $crashFolder -Recurse -Force
        Assert-True ($null -eq (Invoke-Static $diagnosticsType 'BuildCrashLog' @($redactor))) 'a diagnostic bundle made a crash log document where there is no log'
        New-Item -ItemType Directory -Path $crashFolder -Force | Out-Null
        $leakyLog = @(
            '[2026-10-03T08:00:00.000Z] Dispatcher',
            ('System.IO.FileNotFoundException: Could not find file ''' + $fakeProfile + '\Documents\notes.txt''.'),
            ('Contact someone@example.com, or use ' + ('A' * 120) + ' as the token, or see \\fileserver\share\folder.'))
        [IO.File]::WriteAllLines($crashPath, $leakyLog, (New-Object System.Text.UTF8Encoding($false)))
        $crashDocument = Invoke-Static $diagnosticsType 'BuildCrashLog' @($redactor)
        Assert-True ($null -ne $crashDocument) 'a diagnostic bundle left out a crash log it could make safe'
        $crashJson = $jsonSerializer.Serialize($crashDocument.PSObject.BaseObject)
        Assert-True ($crashJson -notmatch 'your-user' -and $crashJson -notmatch '(?i)[a-z]:\\' -and $crashJson -notmatch 'someone@example\.com' -and $crashJson -notmatch 'A{100}' -and $crashJson -notmatch 'fileserver') 'the crash log in a diagnostic bundle kept a name, path, address or token'
        $crashLogType.GetField('directoryOverride', $flags).SetValue($null, 'Z:\no-such-drive\nowhere')
        [void]$crashLogType.GetMethod('Write', $flags).Invoke($null, [object[]]@('Nowhere', (New-CrashError 'cannot be written')))
    }
    finally {
        $crashLogType.GetField('directoryOverride', $flags).SetValue($null, $null)
    }

    # A diagnostic bundle says what it could not include, and why: a document is read with the sharing a writer allows (one that is being
    # rewritten used to go missing without a word), tried again when it is locked or half-written, and each refusal has a fixed reason code.
    # Fixtures under the temporary folder only.
    $diagnosticsType = $assembly.GetType('ResticBackuper.Dashboard.DiagnosticExporter', $true)
    $tryReadDocument = @($diagnosticsType.GetMethods($flags) | Where-Object { $_.Name -eq 'TryReadObject' -and $_.GetParameters().Count -eq 2 })[0]
    Assert-True ($null -ne $tryReadDocument) 'the diagnostic exporter has no reader that says why a document was left out'
    $diagnosticReadRoot = Join-Path $tempRoot 'diagnostic-read'
    New-Item -ItemType Directory -Path $diagnosticReadRoot -Force | Out-Null
    function Read-DiagnosticDocument([string]$Path) {
        $readArguments = [object[]]@($Path, $null)
        $readDocument = $tryReadDocument.Invoke($null, $readArguments)
        return [pscustomobject]@{ Found = ($null -ne $readDocument); Reason = [string]$readArguments[1] }
    }
    $absentDocument = Read-DiagnosticDocument ([string](Join-Path $diagnosticReadRoot 'absent.json'))
    Assert-True ((-not $absentDocument.Found) -and $absentDocument.Reason -eq 'missing') ('a document that is not there was not reported as missing: ' + $absentDocument.Reason)
    $plainDocumentPath = Join-Path $diagnosticReadRoot 'plain.json'
    [IO.File]::WriteAllText($plainDocumentPath, '{"state":"success"}', $utf8)
    $plainDocument = Read-DiagnosticDocument ([string]$plainDocumentPath)
    Assert-True ($plainDocument.Found -and $plainDocument.Reason -eq '') 'a readable document was not read'
    $damagedDocumentPath = Join-Path $diagnosticReadRoot 'damaged.json'
    [IO.File]::WriteAllText($damagedDocumentPath, '{"state":"succ', $utf8)
    $damagedDocument = Read-DiagnosticDocument ([string]$damagedDocumentPath)
    Assert-True ((-not $damagedDocument.Found) -and $damagedDocument.Reason -eq 'invalid_json') ('a document that is not valid JSON was not reported as such: ' + $damagedDocument.Reason)
    $largeDocumentPath = Join-Path $diagnosticReadRoot 'large.json'
    [IO.File]::WriteAllBytes($largeDocumentPath, (New-Object byte[] (4MB + 1)))
    $largeDocument = Read-DiagnosticDocument ([string]$largeDocumentPath)
    Assert-True ((-not $largeDocument.Found) -and $largeDocument.Reason -eq 'too_large') ('a document past the size limit was not reported as too large: ' + $largeDocument.Reason)
    $writerPath = Join-Path $diagnosticReadRoot 'being-written.json'
    [IO.File]::WriteAllText($writerPath, '{"state":"running"}', $utf8)
    $documentWriter = New-Object System.IO.FileStream($writerPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $sharedDocument = Read-DiagnosticDocument ([string]$writerPath)
        Assert-True $sharedDocument.Found 'a document that its writer holds open for writing could not be read'
    }
    finally { $documentWriter.Dispose() }
    $lockedPath = Join-Path $diagnosticReadRoot 'locked.json'
    [IO.File]::WriteAllText($lockedPath, '{"state":"running"}', $utf8)
    $documentLock = New-Object System.IO.FileStream($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockedDocument = Read-DiagnosticDocument ([string]$lockedPath)
        Assert-True ((-not $lockedDocument.Found) -and $lockedDocument.Reason -eq 'locked') ('a locked document was not reported as locked: ' + $lockedDocument.Reason)
    }
    finally { $documentLock.Dispose() }

    # The latest run's log is read from a line boundary, so a log whose tail is cut in the middle of a multi-byte character still exports (the
    # strict decoder used to throw on the cut and cost the whole bundle). The head here is one unbroken line of two-byte characters, and the
    # tail is an even number of bytes, so the cut lands on a continuation byte; only the lines after it are events, and the command and
    # traceback of an event are still left out.
    $diagnosticLogs = Join-Path $stateRoot 'logs'
    New-Item -ItemType Directory -Path $diagnosticLogs -Force | Out-Null
    $twoByteCharacter = [string][char]0xE9
    $logTail = ((1..3 | ForEach-Object { '{"wrapper_event":"event-' + $_ + '","utc":"2026-10-02T01:00:0' + $_ + 'Z","command":["secret.exe"],"traceback":"never shown"}' }) -join "`n") + "`n"
    if (($utf8.GetByteCount($logTail) % 2) -ne 0) { $logTail = $logTail.TrimEnd("`n") + " `n" }
    $logHeadBytes = $utf8.GetBytes(($twoByteCharacter * 1200000) + "`n")
    $logTailBytes = $utf8.GetBytes($logTail)
    $logBytes = New-Object byte[] ($logHeadBytes.Length + $logTailBytes.Length)
    [Array]::Copy($logHeadBytes, 0, $logBytes, 0, $logHeadBytes.Length)
    [Array]::Copy($logTailBytes, 0, $logBytes, $logHeadBytes.Length, $logTailBytes.Length)
    [IO.File]::WriteAllBytes((Join-Path $diagnosticLogs 'backup-diag-utf.jsonl.log'), $logBytes)
    $logSnapshot = [Activator]::CreateInstance($telemetrySnapshotType, $constructorFlags, $null, @(), $null)
    $logSnapshot.RunId = 'diag-utf'
    $logArguments = [object[]]@($config, $logSnapshot, $null)
    $logDocument = Invoke-Static $diagnosticsType 'BuildLatestLogEvents' $logArguments
    Assert-True ($null -ne $logDocument -and [string]$logArguments[2] -eq '') 'a log with a multi-byte character at the cut was left out of the bundle'
    $logEvents = @($logDocument['events'])
    Assert-True ($logDocument['tail_truncated'] -eq $true -and $logEvents.Count -eq 3) ('the log tail did not hold exactly the three whole lines after the cut: ' + $logEvents.Count)
    Assert-True ($logEvents[0].ContainsKey('wrapper_event') -and -not $logEvents[0].ContainsKey('command') -and -not $logEvents[0].ContainsKey('traceback')) 'an exported log event kept its command or traceback'
    $logSnapshot.RunId = 'diag-none'
    $noLogArguments = [object[]]@($config, $logSnapshot, $null)
    Assert-True ($null -eq (Invoke-Static $diagnosticsType 'BuildLatestLogEvents' $noLogArguments) -and [string]$noLogArguments[2] -eq 'missing') 'a run with no log was not reported as missing'

    # Where a bundle may be saved is decided in one place, before the Save dialog closes as well as when the export starts: not inside a
    # protected folder, the backup location or the service's own folders, and only as a .zip. The default folder offered is never one of those.
    $destinationCheck = $diagnosticsType.GetMethod('ValidateDestination', $flags)
    function Test-DiagnosticDestination([string]$Path) {
        try { [void]$destinationCheck.Invoke($null, [object[]]@($config, $Path)); return '' }
        catch { return $_.Exception.ToString() }
    }
    if ((Test-DiagnosticDestination ([string](Join-Path $tempRoot 'bundle.zip'))) -eq '') {
        Assert-True ((Test-DiagnosticDestination ([string](Join-Path $sourceRoot 'bundle.zip'))) -match 'cannot be saved inside') 'a bundle inside a protected folder was accepted, or refused without saying why'
        Assert-True ((Test-DiagnosticDestination ([string](Join-Path $repositoryRoot 'bundle.zip'))) -match 'cannot be saved inside') 'a bundle inside the backup location was accepted, or refused without saying why'
        Assert-True ((Test-DiagnosticDestination ([string](Join-Path $installRoot 'bundle.zip'))) -match 'cannot be saved inside') 'a bundle inside the service folder was accepted, or refused without saying why'
        Assert-True ((Test-DiagnosticDestination ([string](Join-Path $tempRoot 'bundle.txt'))) -match 'must use a \.zip') 'a bundle that is not a .zip was accepted'
        # The folder the Save dialog opens in is the first candidate where a bundle is accepted, never one inside a protected folder: the
        # Desktop and Documents are common ones, so with both protected the answer is the next folder that is allowed. The candidates are given
        # here, so no drive is listed or asked; a blank one, one that is not there and none at all are skipped.
        $allowedFolder = [string](Join-Path $tempRoot 'diagnostics-allowed')
        New-Item -ItemType Directory -Path $allowedFolder -Force | Out-Null
        $protectedFolders = @([Environment]::GetFolderPath('DesktopDirectory'), [Environment]::GetFolderPath('MyDocuments')) | Where-Object { $_ }
        $crowdedPlan = New-SyntheticConfiguration 'C:\Program Files\RewindleFixture' 'C:\Program Files\RewindleFixture\backup-config.json' 'D:\RewindleFixture\repository' 'C:\ProgramData\RewindleFixture' @($protectedFolders)
        $candidateFolders = New-StringList (@($protectedFolders) + @('', [string](Join-Path $tempRoot 'no-such-folder'), $allowedFolder))
        $offeredFolder = Invoke-Static $dashboardType 'FirstAcceptedDiagnosticsFolder' @($crowdedPlan, $candidateFolders)
        Assert-True ([string]$offeredFolder -eq $allowedFolder) ('the Save dialog was not started in the first folder where a bundle is allowed: ' + $offeredFolder)
        Assert-True ($null -eq (Invoke-Static $dashboardType 'FirstAcceptedDiagnosticsFolder' @($null, $candidateFolders))) 'a default folder was offered with no plan to check it against'
        Assert-True ($null -eq (Invoke-Static $dashboardType 'FirstAcceptedDiagnosticsFolder' @($crowdedPlan, (New-StringList @($protectedFolders))))) 'a default folder was offered although every candidate was protected'
    }
    else {
        $skipped.Add('SKIPPED: the temporary folder is not an ordinary local folder on this computer (diagnostic destination)')
    }

    # The installed plan is read in a way that never keeps its writer out. The installed manager replaces that file, and a reader that shares
    # only for reading makes the replacement fail while the file is being read (and fails itself while a rewrite is under way). A plan that
    # someone else holds open for writing and deleting is read, with or without a byte order mark; one that is cut short, is not an object or
    # is too large is still refused. The install root is the active engine's folder under the Program Files folder (ResticBackuper for
    # Rewindle, ResticPersonalBackup for the legacy personal edition), not an assumed drive C.
    # Fixtures under the temporary folder: the installed plan is not read.
    $planReadRoot = Join-Path $tempRoot 'plan-read'
    New-Item -ItemType Directory -Path $planReadRoot -Force | Out-Null
    $readPlanDocument = $configurationType.GetMethod('ReadConfigurationDocument', $flags)
    Assert-True ($null -ne $readPlanDocument) 'the reader of the installed plan is missing'
    $planJson = '{"plan_id":"4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31","config_generation":1}'
    $sharedPlan = Join-Path $planReadRoot 'shared.json'
    [IO.File]::WriteAllText($sharedPlan, $planJson, (New-Object System.Text.UTF8Encoding($false)))
    $planWriter = New-Object System.IO.FileStream($sharedPlan, [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $sharedDocument = $readPlanDocument.Invoke($null, [object[]]@([string]$sharedPlan))
        Assert-True ($sharedDocument['plan_id'] -eq '4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31' -and [long]$sharedDocument['config_generation'] -eq 1) 'a plan held open for writing could not be read'
    }
    finally { $planWriter.Dispose() }
    $bomPlan = Join-Path $planReadRoot 'bom.json'
    [IO.File]::WriteAllText($bomPlan, $planJson, (New-Object System.Text.UTF8Encoding($true)))
    $bomDocument = $readPlanDocument.Invoke($null, [object[]]@([string]$bomPlan))
    Assert-True ($bomDocument['plan_id'] -eq '4e1b8c0a-5f27-4d3a-9b61-0c7d2a9e5f31') 'a plan written with a byte order mark could not be read'
    foreach ($case in @(@('cut-short', '{"plan_id":"4e1b8c0a-5f27', 'ArgumentException'), @('not-an-object', '[1,2]', 'InvalidDataException'))) {
        $badPlan = Join-Path $planReadRoot ($case[0] + '.json')
        [IO.File]::WriteAllText($badPlan, $case[1], (New-Object System.Text.UTF8Encoding($false)))
        $planRefusal = ''
        try { [void]$readPlanDocument.Invoke($null, [object[]]@([string]$badPlan)) } catch { $planRefusal = $_.Exception.ToString() }
        Assert-True ($planRefusal -match $case[2]) ('a plan that is ' + $case[0] + ' was not refused as ' + $case[2])
    }
    $largePlan = Join-Path $planReadRoot 'large.json'
    [IO.File]::WriteAllBytes($largePlan, (New-Object byte[] (1MB + 1)))
    $largePlanRefusal = ''
    try { [void]$readPlanDocument.Invoke($null, [object[]]@([string]$largePlan)) } catch { $largePlanRefusal = $_.Exception.ToString() }
    Assert-True ($largePlanRefusal -match 'unexpectedly large') 'a plan past the size limit was read'
    $fixtureProgramFiles = Join-Path $engineFixtureRoot 'ProgramFiles'
    $expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $fixtureProgramFiles 'ResticBackuper'))
    Assert-True ((Invoke-Static $configurationType 'ResolveProtectedInstallRoot') -eq $expectedInstallRoot) 'the install root is not the ResticBackuper folder under the Program Files folder'

    # Engine profiles: which engine is chosen, the identities each one owns, and the checks that stay the same for both. Fixture folders
    # only (see UseFolderRootsForTesting above); the selection only asks whether <install root>\backup-config.json is a file.
    $rewindleProfile = $engineProfileType.GetProperty('Rewindle', $flags).GetValue($null)
    $legacyProfile = $engineProfileType.GetProperty('Legacy', $flags).GetValue($null)
    function Get-ProfileValue([object]$EngineProfile, [string]$Name) { return $EngineProfile.GetType().GetProperty($Name, $flags).GetValue($EngineProfile) }
    function Select-Engine([string]$Requested) { return Invoke-Static $engineProfileType 'Select' @($Requested) }
    $nothingInstalled = Select-Engine $null
    Assert-True ([object]::ReferenceEquals($nothingInstalled.Profile, $rewindleProfile) -and -not $nothingInstalled.Installed -and -not $nothingInstalled.Requested) 'with no engine installed Rewindle was not chosen and reported as not installed'
    $searched = @($nothingInstalled.SearchedConfigurationPaths())
    Assert-True ($searched.Count -eq 2 -and $searched[0] -eq (Join-Path $expectedInstallRoot 'backup-config.json') -and $searched[1] -eq (Join-Path ([IO.Path]::GetFullPath((Join-Path $fixtureProgramFiles 'ResticPersonalBackup'))) 'backup-config.json')) ('the not-installed notice was not told where both engines were looked for: ' + ($searched -join ' | '))
    $legacyRoot = Join-Path $fixtureProgramFiles 'ResticPersonalBackup'
    $rewindleRoot = Join-Path $fixtureProgramFiles 'ResticBackuper'
    New-Item -ItemType Directory -Path $legacyRoot, $rewindleRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rewindleRoot 'backup-config.json') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'backup-config.json'), '{}', $utf8)
    $legacyOnly = Select-Engine $null
    Assert-True ([object]::ReferenceEquals($legacyOnly.Profile, $legacyProfile) -and $legacyOnly.Installed) 'an existing legacy personal install was not chosen (a folder named backup-config.json must not count as a Rewindle install)'
    [IO.Directory]::Delete((Join-Path $rewindleRoot 'backup-config.json'))
    [IO.File]::WriteAllText((Join-Path $rewindleRoot 'backup-config.json'), '{}', $utf8)
    [IO.File]::WriteAllText((Join-Path $rewindleRoot 'VERSION'), "0.2.0-alpha.1`n", $utf8)
    $bothInstalled = Select-Engine $null
    Assert-True ([object]::ReferenceEquals($bothInstalled.Profile, $rewindleProfile) -and $bothInstalled.Installed) 'Rewindle was not preferred when both engines are installed'
    $overridden = Select-Engine 'legacy'
    Assert-True ([object]::ReferenceEquals($overridden.Profile, $legacyProfile) -and $overridden.Requested -and $overridden.Installed) '--engine legacy did not override the Rewindle preference'
    Assert-True ([string](Invoke-Private $rewindleProfile 'ReadEngineVersion') -eq '0.2.0-alpha.1' -and [string](Invoke-Private $legacyProfile 'ReadEngineVersion') -eq 'not recorded by this edition') 'the engine versions were not read from the install'
    [IO.File]::WriteAllText((Join-Path $rewindleRoot 'VERSION'), "not a version; see the release notes`n", $utf8)
    Assert-True ([string](Invoke-Private $rewindleProfile 'ReadEngineVersion') -eq 'unknown') 'an engine version file that is not a version reached the page'
    Remove-Item -LiteralPath (Join-Path $rewindleRoot 'backup-config.json') -Force
    $requestedMissing = Select-Engine 'rewindle'
    Assert-True ([object]::ReferenceEquals($requestedMissing.Profile, $rewindleProfile) -and $requestedMissing.Requested -and -not $requestedMissing.Installed) '--engine rewindle without a Rewindle install was not reported as not installed'
    $refusedEngine = ''
    try { [void](Invoke-Static $engineProfileType 'FromId' @('personal')) } catch { $refusedEngine = $_.Exception.ToString() }
    Assert-True ($refusedEngine -match 'ArgumentException') 'an unknown --engine value was not refused'
    $appOptionsType = $assembly.GetType('ResticBackuper.Dashboard.AppOptions', $true)
    $parsedOptions = Invoke-Static $appOptionsType 'Parse' @(,[string[]]@('--engine', 'Legacy', '--minimized'))
    Assert-True ([string]$parsedOptions.EngineOverride -eq 'legacy' -and $parsedOptions.StartMinimized) 'the --engine option was not parsed'
    foreach ($badArguments in @(@('--engine'), @('--engine', 'other'), @('--engine', 'rewindle', '--engine', 'legacy'))) {
        $optionRefusal = ''
        try { [void](Invoke-Static $appOptionsType 'Parse' @(,[string[]]$badArguments)) } catch { $optionRefusal = $_.Exception.ToString() }
        Assert-True ($optionRefusal -match 'ArgumentException') ('bad --engine arguments were accepted: ' + ($badArguments -join ' '))
    }
    $refusedRoot = ''
    try { [void]$engineProfileType.GetMethod('UseFolderRootsForTesting', $flags).Invoke($null, [object[]]@([string]$env:SystemRoot)) } catch { $refusedRoot = $_.Exception.ToString() }
    Assert-True ($refusedRoot -match 'temporary folder') 'the test folder override accepted a folder outside the temporary folder'
    foreach ($identity in @(
        @('ProductDirectoryName', 'ResticBackuper', 'ResticPersonalBackup'),
        @('BackupTaskName', 'ResticBackuper', 'ResticPersonalBackup'),
        @('LauncherFileName', 'ResticBackuperTaskLauncher.exe', 'ResticBackupTaskLauncher.exe'),
        @('SourceRequestDomain', 'ResticBackuper.SourceRequest.v1', 'ResticPersonalBackup.SourceRequest.v1'),
        @('RestoreRequestDomain', 'ResticBackuper.RestoreRequest.v2', 'ResticPersonalBackup.RestoreRequest.v2'),
        @('TaskXmlFingerprintDomain', 'ResticBackuper.TaskXml.v1', 'ResticPersonalBackup.TaskXml.v1'),
        @('CancelEventPrefix', 'Local\ResticBackuper.Cancel.', 'Local\ResticPersonalBackup.Cancel.'),
        @('InstanceMutexName', 'Local\ResticBackuperDashboard.Instance', 'Local\ResticPersonalBackupDashboard.Instance'),
        @('CloudVerificationProofRelativePath', 'evidence\latest-verification.json', 'latest-verification.json'),
        @('DashboardDataDirectoryName', 'ResticBackuperDashboard', 'ResticPersonalBackupDashboard'),
        @('GoogleDriveSyncTaskName', 'ResticBackuperGoogleDriveSync', 'ResticPersonalBackupGoogleDriveSync'),
        @('RecoveryToolsDirectoryName', 'ResticBackuperRecoveryTools', ''))) {
        Assert-True ([string](Get-ProfileValue $rewindleProfile $identity[0]) -eq $identity[1] -and [string](Get-ProfileValue $legacyProfile $identity[0]) -eq $identity[2]) ('the engine identity ' + $identity[0] + ' is wrong')
    }
    Assert-True ((Invoke-Private $rewindleProfile 'IsAnomalyReviewScope' @('anomaly_review_acknowledgement')) -and -not (Invoke-Private $legacyProfile 'IsAnomalyReviewScope' @('anomaly_review_acknowledgement')) -and (Invoke-Private $legacyProfile 'IsAnomalyReviewScope' @('offsite_promotion')) -and -not (Invoke-Private $rewindleProfile 'IsAnomalyReviewScope' @('anything_else'))) 'an engine accepted another engine''s anomaly review scope'
    # Neither engine pins a repository path: a cloud proof is bound to the installed plan's repository (tests\test_dashboard_offsite_status.py).
    Assert-True ((Get-ProfileValue $rewindleProfile 'CloudProofRequiresAssetBinding') -and -not (Get-ProfileValue $legacyProfile 'CloudProofRequiresAssetBinding') -and $null -eq $engineProfileType.GetProperty('FixedCloudBinding', $flags)) 'the cloud proof bindings of the engines are wrong'
    [void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($legacyProfile))
    try {
        Assert-True ((Invoke-Static $configurationType 'ResolveProtectedInstallRoot') -eq [IO.Path]::GetFullPath($legacyRoot)) 'the legacy install root is not the ResticPersonalBackup folder under the Program Files folder'
        $legacyStateRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $engineFixtureRoot 'ProgramData') 'ResticPersonalBackup'))
        Assert-True ([IO.Path]::GetFullPath([string](Invoke-Private $legacyProfile 'StateDirectory')) -eq $legacyStateRoot) 'the legacy state folder is not ResticPersonalBackup under ProgramData'
    }
    finally {
        [void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($rewindleProfile))
    }
    Assert-True ([string](Invoke-Private $rewindleProfile 'CloudVerificationProofPath') -eq (Join-Path (Join-Path $engineFixtureRoot 'ProgramData') 'ResticBackuperCloudVerification\evidence\latest-verification.json')) 'the Rewindle cloud proof is not read from its evidence folder'
    $cloudPathFor = $readerType.GetMethod('CloudPathForLocalRepository', $flags)
    Assert-True ([string]$cloudPathFor.Invoke($null, [object[]]@('G:\My Drive\Backups\Laptop', 'G:\My Drive')) -eq 'Backups/Laptop') 'the Rewindle cloud path was not derived from the repository below My Drive'
    foreach ($outside in @(@('G:\My Drive', 'G:\My Drive'), @('G:\Other\Backups', 'G:\My Drive'), @('G:\My Drive\..\Escape', 'G:\My Drive'))) {
        Assert-True ([string]$cloudPathFor.Invoke($null, [object[]]@($outside[0], $outside[1])) -eq '') ('a repository that is not strictly below My Drive got a cloud path: ' + $outside[0])
    }

    # The backup-location window shows where it is: steps already done are checked, the current one is a dot, a failure is a cross on the
    # step it stopped at (there is no step of its own for it), and a folder that cannot be used leaves nothing selected on the first step.
    # The window is built but never shown, and no folder is read or manager started.
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $themeManagerType = $assembly.GetType('ResticBackuper.Dashboard.DashboardThemeManager', $true)
    $themePreferenceType = $assembly.GetType('ResticBackuper.Dashboard.DashboardThemePreference', $true)
    $dialogPalette = $themeManagerType.GetMethod('Resolve').Invoke($null, @([Enum]::Parse($themePreferenceType, 'Midnight'))).Palette
    # The first-close hint is claimed once, ever. Its marker is a small file beside the theme preference, in the same per-user folder (a
    # temporary one here, through the isolated-root override), that is looked for and never read. A marker that is already there, or whose
    # place is taken by something else, is not written over, and the hint is then not said: better silent than repeated at every start.
    $hintFolder = [string](Join-Path $tempRoot 'tray-hint')
    $hintMarker = Join-Path $hintFolder 'tray-hint-shown.json'
    $hintOverride = $themeManagerType.GetField('settingsDirectoryOverride', $flags)
    $hintOverrideBefore = $hintOverride.GetValue($null)
    try {
        [void]$themeManagerType.GetMethod('UseSettingsRootForSmokeTesting', $flags).Invoke($null, [object[]]@($hintFolder))
        $claimHint = $themeManagerType.GetMethod('TryClaimTrayHint', $flags)
        Assert-True ([bool]$claimHint.Invoke($null, [object[]]@())) 'the first close did not claim the tray hint'
        Assert-True (Test-Path -LiteralPath $hintMarker -PathType Leaf) 'claiming the tray hint left no marker'
        Assert-True (-not [bool]$claimHint.Invoke($null, [object[]]@())) 'the tray hint was claimed a second time'
        Remove-Item -LiteralPath $hintMarker -Force
        New-Item -ItemType Directory -Path $hintMarker -Force | Out-Null
        Assert-True (-not [bool]$claimHint.Invoke($null, [object[]]@())) 'the tray hint was claimed over something that took the marker place'
        Assert-True (Test-Path -LiteralPath $hintMarker -PathType Container) 'claiming the tray hint replaced what was in the marker place'
    }
    finally {
        $hintOverride.SetValue($null, $hintOverrideBefore)
    }
    $relocationType = $assembly.GetType('ResticBackuper.Dashboard.RepositoryLocationWindow', $true)
    $relocationStageType = $assembly.GetType('ResticBackuper.Dashboard.RepositoryLocationStage', $true)
    $relocation = [Activator]::CreateInstance($relocationType, $flags, $null, [object[]]@($config, $dialogPalette), $null)
    $setStage = @($relocationType.GetMethods($flags) | Where-Object { $_.Name -eq 'SetStage' -and $_.GetParameters().Count -eq 2 })[0]
    function Set-RelocationStage([string]$Stage, [string]$Message) { [void]$setStage.Invoke($relocation, [object[]]@([Enum]::Parse($relocationStageType, $Stage), $Message)) }
    function Get-RelocationField([string]$Name) { return $relocationType.GetField($Name, $flags).GetValue($relocation) }
    function Get-BrushColor($Brush) { return ([System.Windows.Media.SolidColorBrush]$Brush).Color.ToString() }
    function Get-RelocationSteps() { $items = Get-RelocationField 'stageItems'; return @('Selecting', 'Reviewing', 'WaitingForApproval', 'Copying', 'Verifying', 'Activating', 'Complete' | ForEach-Object { $items[[Enum]::Parse($relocationStageType, $_)] }) }
    $check = [string][char]0x2713; $dot = [string][char]0x25CF; $ring = [string][char]0x25CB; $cross = [string][char]0x2715
    Assert-True ((Get-RelocationField 'stageItems').Count -eq 7) 'the backup-location window lists a step for a failure that has not happened'
    Set-RelocationStage 'Copying' 'Approval received.'
    $steps = Get-RelocationSteps
    Assert-True ($steps[0].Text.StartsWith($check) -and $steps[2].Text.StartsWith($check) -and $steps[3].Text.StartsWith($dot) -and $steps[4].Text.StartsWith($ring)) 'the steps were not drawn as done, current and ahead'
    Assert-True ((Get-BrushColor $steps[0].Foreground) -eq (Get-BrushColor $dialogPalette.Success) -and (Get-BrushColor $steps[4].Foreground) -eq (Get-BrushColor $dialogPalette.TextTertiary)) 'done and pending steps were not told apart by color'
    Assert-True ((Get-RelocationField 'headline').Text -eq 'Copying your backups') 'the headline did not change with the step'
    Set-RelocationStage 'Failed' 'The protected repository relocation failed.'
    $steps = Get-RelocationSteps
    Assert-True ($steps[3].Text.StartsWith($cross) -and (Get-BrushColor $steps[3].Foreground) -eq (Get-BrushColor $dialogPalette.Danger)) 'a failure was not a red cross on the step it stopped at'
    Assert-True ((Get-RelocationField 'stageBadge').Text -eq 'FAILED' -and (Get-BrushColor (Get-RelocationField 'stageBadge').Foreground) -eq (Get-BrushColor $dialogPalette.Danger) -and (Get-BrushColor (Get-RelocationField 'detail').Foreground) -eq (Get-BrushColor $dialogPalette.Danger)) 'a failure was not red in the badge and the message'
    Set-RelocationStage 'Complete' 'The new repository is active.'
    Assert-True (@(Get-RelocationSteps | Where-Object { -not $_.Text.StartsWith($check) }).Count -eq 0 -and (Get-BrushColor (Get-RelocationField 'stageBadge').Foreground) -eq (Get-BrushColor $dialogPalette.Success)) 'a finished relocation did not check every step in green'
    $relocationType.GetField('selectedRepository', $flags).SetValue($relocation, 'D:\SomethingFromBefore')
    (Get-RelocationField 'newPathValue').Text = 'D:\SomethingFromBefore'
    (Get-RelocationField 'primaryButton').IsEnabled = $true
    [void]$relocationType.GetMethod('RejectDestination', $flags).Invoke($relocation, [object[]]@('This is already the active repository.'))
    Assert-True ($null -eq (Get-RelocationField 'selectedRepository') -and (Get-RelocationField 'newPathValue').Text -eq 'No folder selected') 'a folder that cannot be used left the earlier pick on screen'
    Assert-True (-not (Get-RelocationField 'primaryButton').IsEnabled -and (Get-RelocationField 'primaryButton').Content -eq 'Choose a folder first') 'a folder that cannot be used left the copy button available'
    Assert-True ((Get-RelocationField 'stageBadge').Text -eq 'SELECTING' -and (Get-RelocationField 'detail').Text -eq 'This is already the active repository.' -and (Get-BrushColor (Get-RelocationField 'detail').Foreground) -eq (Get-BrushColor $dialogPalette.Danger)) 'a folder that cannot be used was reported as a failure of the relocation, or without saying why in red'
    [void]$relocationType.GetMethod('ShowCloseNotice', $flags).Invoke($relocation, @())
    Assert-True ((Get-RelocationField 'closeNotice').Visibility -eq 'Visible' -and (Get-RelocationField 'closeNotice').Text -like 'Copying cannot be cancelled safely*') 'closing the window during the copy did not say why it stayed open'

    # A control takes the animations that dialogs, buttons and bars ask for. AnimateDouble used to hand an animation only to a freezable (the transforms), so a
    # control's opacity, height and progress value jumped to their end values and only the transforms moved. The motion preference is Full for the check and is
    # put back to System after (Windows High Contrast always refuses motion, so the check is skipped there). Nothing is shown.
    $visualStyleType = $assembly.GetType('ResticBackuper.Dashboard.DashboardVisualStyle', $true)
    $motionType = $assembly.GetType('ResticBackuper.Dashboard.DashboardMotion', $true)
    $motionPreferenceType = $assembly.GetType('ResticBackuper.Dashboard.DashboardMotionPreference', $true)
    $setMotionPreference = $motionType.GetMethod('SetPreference', $flags)
    $animateDouble = $visualStyleType.GetMethod('AnimateDouble', $flags, $null, [Type[]]@([System.Windows.DependencyObject], [System.Windows.DependencyProperty], [double], [TimeSpan], [bool]), $null)
    $animateProgress = $visualStyleType.GetMethod('AnimateProgressValue', $flags)
    Assert-True (($null -ne $animateDouble) -and ($null -ne $animateProgress)) 'the animation helpers the dialogs and bars use are missing'
    if (-not [System.Windows.SystemParameters]::HighContrast) {
        try {
            [void]$setMotionPreference.Invoke($null, [object[]]@([Enum]::Parse($motionPreferenceType, 'Full')))
            $fadeIn = New-Object System.Windows.Controls.Border
            $fadeIn.Opacity = 0.0
            [void]$animateDouble.Invoke($null, [object[]]@($fadeIn.PSObject.BaseObject, [System.Windows.UIElement]::OpacityProperty, 1.0, [TimeSpan]::FromMilliseconds(200), $true))
            Assert-True $fadeIn.HasAnimatedProperties 'a control was sent to its end opacity instead of being animated'
            $alreadyThere = New-Object System.Windows.Controls.Border
            [void]$animateDouble.Invoke($null, [object[]]@($alreadyThere.PSObject.BaseObject, [System.Windows.UIElement]::OpacityProperty, 1.0, [TimeSpan]::FromMilliseconds(200), $false))
            Assert-True (-not $alreadyThere.HasAnimatedProperties) 'an end value that was already showing was animated'
            $bar = New-Object System.Windows.Controls.ProgressBar
            $bar.Maximum = 100
            $bar.Value = 10
            [void]$animateProgress.Invoke($null, [object[]]@($bar.PSObject.BaseObject, 60.0))
            Assert-True $bar.HasAnimatedProperties 'a progress bar jumped to its value instead of easing toward it'
            [void]$animateProgress.Invoke($null, [object[]]@($bar.PSObject.BaseObject, 5.0))
            Assert-True ((-not $bar.HasAnimatedProperties) -and $bar.Value -eq 5) 'a progress bar swept backwards instead of starting over in place'
            [void]$setMotionPreference.Invoke($null, [object[]]@([Enum]::Parse($motionPreferenceType, 'Reduced')))
            $reduced = New-Object System.Windows.Controls.Border
            $reduced.Opacity = 0.0
            [void]$animateDouble.Invoke($null, [object[]]@($reduced.PSObject.BaseObject, [System.Windows.UIElement]::OpacityProperty, 1.0, [TimeSpan]::FromMilliseconds(200), $true))
            Assert-True ((-not $reduced.HasAnimatedProperties) -and $reduced.Opacity -eq 1.0) 'reduced motion animated a control instead of setting it at once'
        }
        finally {
            [void]$setMotionPreference.Invoke($null, [object[]]@([Enum]::Parse($motionPreferenceType, 'System')))
        }
    }

    # The backup-location window picks its folder with the one picker the rest of the app uses, owned by the window it was asked from.
    $pickFolder = $dashboardType.GetMethod('PickFolder', $flags)
    Assert-True (($null -ne $pickFolder) -and $pickFolder.IsStatic) 'there is no static folder picker the backup-location window can call with its own window as the owner'
    Assert-True ((@($pickFolder.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ',') -eq 'IntPtr,String,String,String') 'the folder picker no longer takes an owner handle, a title, a button label and a fallback description'

    # The Daylight palette's grey text clears WCAG AA (4.5:1) on every surface it is drawn on, and its two grey tiers stay apart. The tertiary (helper lines,
    # pending steps) was 4.2:1 on the page and on the soft surface, and the secondary moved with it. Windows High Contrast replaces the palette with system
    # colors, which this does not judge.
    if (-not [System.Windows.SystemParameters]::HighContrast) {
        function Get-RelativeLuminance([object]$Brush) {
            $color = ([System.Windows.Media.SolidColorBrush]$Brush).Color
            $channels = @(foreach ($value in @($color.R, $color.G, $color.B)) { $unit = $value / 255.0; if ($unit -le 0.03928) { $unit / 12.92 } else { [math]::Pow(($unit + 0.055) / 1.055, 2.4) } })
            return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
        }
        function Get-ContrastRatio([object]$Foreground, [object]$Background) {
            $first = Get-RelativeLuminance $Foreground
            $second = Get-RelativeLuminance $Background
            return ([math]::Max($first, $second) + 0.05) / ([math]::Min($first, $second) + 0.05)
        }
        $daylightPalette = $themeManagerType.GetMethod('Resolve').Invoke($null, @([Enum]::Parse($themePreferenceType, 'Daylight'))).Palette
        foreach ($surfaceName in 'BackgroundTop', 'BackgroundBottom', 'Surface', 'SurfaceSoft') {
            foreach ($textName in 'TextSecondary', 'TextTertiary') {
                $ratio = Get-ContrastRatio $daylightPalette.$textName $daylightPalette.$surfaceName
                Assert-True ($ratio -ge 4.5) ('the Daylight ' + $textName + ' is only ' + [math]::Round($ratio, 2) + ':1 on ' + $surfaceName)
            }
        }
        Assert-True ((Get-ContrastRatio $daylightPalette.TextSecondary $daylightPalette.BackgroundTop) -ge ((Get-ContrastRatio $daylightPalette.TextTertiary $daylightPalette.BackgroundTop) + 1.0)) 'the Daylight secondary and tertiary text are no longer two distinct tiers'
    }

    # A backup request that Windows accepted and that started nothing (the task waits for AC power, say) leaves no run behind. When the
    # 45-second wait ends with no run since the request, the tray says so once, and only while the status can be read; the Back up now help
    # then carries the same note until a run shows up. A stand-in button, a hidden tray icon and a canary-bearing plan are all it needs, and
    # nothing is requested or shown.
    $requestDashboard = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($dashboardType)
    $requestIcon = New-Object System.Windows.Forms.NotifyIcon
    try {
        $canaryFolders = New-GenericList $sourceViewType
        [void]$canaryFolders.Add([Activator]::CreateInstance($sourceViewType, [object[]]@('C:\RewindleFixture\canary', $true)))
        $canaryPlan = New-SyntheticConfiguration 'C:\Program Files\RewindleFixture' 'C:\Program Files\RewindleFixture\backup-config.json' 'D:\RewindleFixture\repository' 'C:\ProgramData\RewindleFixture' @('C:\RewindleFixture\canary')
        $configurationType.GetField('<Sources>k__BackingField', $flags).SetValue($canaryPlan, $canaryFolders)
        $requestButton = New-Object System.Windows.Controls.Button
        Set-PrivateField $requestDashboard 'backupNowButton' $requestButton
        Set-PrivateField $requestDashboard 'trayIcon' $requestIcon
        Set-PrivateField $requestDashboard 'currentSourceConfiguration' $canaryPlan
        $plainHelp = 'Start a backup now. Windows will ask for approval.'
        function New-RunSnapshot([string]$RunId, [bool]$Active) {
            $next = [Activator]::CreateInstance($telemetrySnapshotType, $constructorFlags, $null, @(), $null)
            $next.RunId = $RunId
            $next.StateKey = if ($Active) { 'backing_up' } else { 'success' }
            $next.IsActive = $Active
            $next.IsSuccess = -not $Active
            return $next
        }
        function Wait-ForRequest([string]$BaselineRunId, [double]$SecondsLeft) {
            Set-PrivateField $requestDashboard 'backupRequestBaselineRunId' $BaselineRunId
            Set-PrivateField $requestDashboard 'backupRequestPendingUntilUtc' ([DateTime]::UtcNow.AddSeconds($SecondsLeft))
        }
        function Update-RequestButton($Snapshot) {
            $requestIcon.BalloonTipTitle = '(none)'
            Invoke-Private $requestDashboard 'UpdateBackupButton' @($Snapshot) | Out-Null
            return [string]$requestIcon.BalloonTipTitle
        }
        Wait-ForRequest 'run-a' 30
        Assert-True ((Update-RequestButton (New-RunSnapshot 'run-a' $false)) -eq '(none)' -and [string]$requestButton.Content -like 'Request sent*') 'a request that is still within its wait was reported as not started'
        Wait-ForRequest 'run-a' (-1)
        Assert-True ((Update-RequestButton (New-RunSnapshot 'run-a' $false)) -eq 'Backup has not started') 'a request that ended its wait with no run was not reported'
        Assert-True ($requestButton.Content -eq 'Back up now' -and $requestButton.IsEnabled -and [string]$requestButton.ToolTip -like ($plainHelp + '*did not start*AC power*')) ('the Back up now help did not carry the note, or the button stayed off: ' + $requestButton.ToolTip)
        Assert-True ((Update-RequestButton (New-RunSnapshot 'run-a' $false)) -eq '(none)' -and [string]$requestButton.ToolTip -like '*did not start*') 'the not-started warning was raised more than once for one request, or the note was dropped while no run had appeared'
        Assert-True ((Update-RequestButton (New-RunSnapshot 'run-b' $false)) -eq '(none)' -and [string]$requestButton.ToolTip -eq $plainHelp) 'a run that appeared did not clear the note'
        Wait-ForRequest 'run-b' (-1)
        Assert-True ((Update-RequestButton (New-RunSnapshot 'run-c' $false)) -eq '(none)' -and [string]$requestButton.ToolTip -eq $plainHelp) 'a request that did start a run was reported as not started'
        Set-PrivateField $requestDashboard 'webTelemetryError' 'The status file is being rewritten.'
        Wait-ForRequest 'run-c' (-1)
        Assert-True ((Update-RequestButton (New-RunSnapshot 'run-c' $false)) -eq '(none)' -and [string]$requestButton.ToolTip -eq $plainHelp) 'a request was reported as not started while the status could not be read'
        Set-PrivateField $requestDashboard 'webTelemetryError' $null
        # The battery hint before a request: only for a task that waits for AC power and only on battery, and never without a schedule.
        $powerOffline = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Offline
        Set-PrivateField $requestDashboard 'currentTaskSchedule' $null
        Assert-True (-not [bool](Invoke-Private $requestDashboard 'BackupTaskWaitsForAcPowerNow')) 'the battery hint was raised with no schedule to read'
        Set-PrivateField $requestDashboard 'currentTaskSchedule' (New-FreshnessSchedule ([TimeSpan]::FromHours(2)))
        Assert-True ([bool](Invoke-Private $requestDashboard 'BackupTaskWaitsForAcPowerNow') -eq $powerOffline) 'the battery hint did not follow the power state for a task that waits for AC power'
    }
    finally {
        $requestIcon.Dispose()
    }

    # The recovery-readiness window explains its dimmed buttons: each button's accessible name is its visible label, its tooltip is its
    # help text, a line above the buttons says what is available, and the key button's label and the choice it makes come from the same
    # report (a stale label must not decide between resuming and rotating). Built but never shown, because showing it starts the
    # protected inspection; synthetic reports only.
    $readinessType = $assembly.GetType('ResticBackuper.Dashboard.RecoveryReadinessWindow', $true)
    $healthCheckType = $assembly.GetType('ResticBackuper.Dashboard.RecoveryHealthCheck', $true)
    $healthReportType = $assembly.GetType('ResticBackuper.Dashboard.RecoveryHealthReport', $true)
    $readiness = [Activator]::CreateInstance($readinessType, $flags, $null, [object[]]@($config, $dialogPalette), $null)
    function Get-ReadinessField([string]$Name) { return $readinessType.GetField($Name, $flags).GetValue($readiness) }
    function New-HealthReport([string]$Overall, [object[]]$Checks) {
        $typed = [Activator]::CreateInstance([System.Collections.Generic.List``1].MakeGenericType($healthCheckType))
        foreach ($item in $Checks) {
            $typed.Add([Activator]::CreateInstance($healthCheckType, $flags, $null, [object[]]@($item[0], $item[1], $item[0], $item[2]), $null))
        }
        return $healthReportType.GetMethod('Success', $flags).Invoke($null, [object[]]@($Overall, 'abcdef0123456789', [long]2, [Nullable[long]][long]500000000000, [long]1000000000, [Nullable[long]][long]0, 0, 0, $typed))
    }
    function Set-ReadinessReport($Report) { [void]$readinessType.GetMethod('ApplyReport', $flags).Invoke($readiness, [object[]]@($Report)) }
    $passing = @(@('active_credential', 'pass', 'ok'), @('recovery_key', 'pass', 'ok'), @('recovery_bundle', 'pass', 'ok'), @('last_verification', 'pass', 'ok'), @('pending_transaction', 'pass', 'none'), @('restore_drill', 'pass', 'recent'))
    Set-ReadinessReport (New-HealthReport 'healthy' $passing)
    foreach ($buttonName in 'drillButton', 'repairButton', 'lockRepairButton', 'keyRotationButton') {
        $button = Get-ReadinessField $buttonName
        $help = [System.Windows.Automation.AutomationProperties]::GetHelpText($button)
        Assert-True ([System.Windows.Automation.AutomationProperties]::GetName($button) -eq [string]$button.Content) ($buttonName + ' has an accessible name other than its visible label')
        Assert-True (-not [string]::IsNullOrWhiteSpace($help) -and $button.ToolTip.Text -eq $help) ($buttonName + ' has no tooltip carrying its help text')
    }
    Assert-True ((Get-ReadinessField 'actionHint').Text -like 'Nothing to repair: all checks passed.*') 'a healthy report did not say that nothing needs repair'
    Set-ReadinessReport (New-HealthReport 'warning' @(@('active_credential', 'pass', 'ok'), @('recovery_key', 'pass', 'ok'), @('recovery_bundle', 'pass', 'ok'), @('last_verification', 'pass', 'ok'), @('pending_transaction', 'warn', 'A key rotation was interrupted: credential-rotation.journal.json is waiting.'), @('restore_drill', 'warn', 'due')))
    Assert-True ((Get-ReadinessField 'keyRotationButton').Content -eq 'Resume key rotation' -and (Get-ReadinessField 'resumingRotation') -eq $true -and (Get-ReadinessField 'keyRotationButton').IsEnabled) 'an interrupted rotation did not turn the button into Resume key rotation'
    Assert-True ((Get-ReadinessField 'actionHint').Text -like '*Resume key rotation*') 'the line above the buttons did not list Resume key rotation'
    Set-ReadinessReport (New-HealthReport 'healthy' $passing)
    Assert-True ((Get-ReadinessField 'resumingRotation') -eq $false -and (Get-ReadinessField 'keyRotationButton').Content -eq 'Rotate keys') 'the key button kept resuming after a report that has no interrupted rotation'
    Set-ReadinessReport (New-HealthReport 'failed' @(@('active_credential', 'fail', 'The credential could not unlock the repository.'), @('recovery_key', 'pass', 'ok'), @('recovery_bundle', 'pass', 'ok'), @('last_verification', 'pass', 'ok'), @('pending_transaction', 'pass', 'none')))
    Assert-True ((Get-ReadinessField 'repairButton').IsEnabled -and -not (Get-ReadinessField 'keyRotationButton').IsEnabled -and (Get-ReadinessField 'actionHint').Text -like '*Repair active credential*') 'a broken active credential did not offer exactly the credential repair'
    Set-ReadinessReport $null
    Assert-True ((Get-ReadinessField 'actionHint').Text -like 'Actions are unavailable*' -and -not (Get-ReadinessField 'keyRotationButton').IsEnabled) 'with no report the actions were not explained as unavailable'

    # The dialogs draw from the page tokens instead of each choosing its own: the primary button is ink on the canvas (the page's bg-ink with
    # text-canvas) in the schedule, location and readiness dialogs alike, the other buttons are the quiet look, and accent text is one
    # hue in both themes (the page's --accent-ink). Windows High Contrast uses the system colors, so the hues are only checked without it.
    # The windows are built and never shown.
    if (-not [System.Windows.SystemParameters]::HighContrast) {
        $daylightPalette = $themeManagerType.GetMethod('Resolve').Invoke($null, @([Enum]::Parse($themePreferenceType, 'Daylight'))).Palette
        foreach ($case in @(@('Midnight', $dialogPalette, '#FF91E2D6'), @('Daylight', $daylightPalette, '#FF10655D'))) {
            $themeName = $case[0]
            $themePalette = $case[1]
            Assert-True ((Get-BrushColor $themePalette.PrimaryButton) -eq (Get-BrushColor $themePalette.TextPrimary)) ('the ' + $themeName + ' primary button is not the page ink')
            Assert-True ((Get-BrushColor $themePalette.PrimaryButtonText) -eq (Get-BrushColor $themePalette.BackgroundBottom)) ('the ' + $themeName + ' primary button label is not the page canvas')
            Assert-True ((Get-BrushColor $themePalette.AccentInk) -eq $case[2]) ('the ' + $themeName + ' accent text is not the page accent ink')
        }
    }
    else {
        $skipped.Add('SKIPPED: Windows High Contrast is on, so the palettes are the system colors (dialog token hues)')
    }
    $inkButton = Get-BrushColor $dialogPalette.PrimaryButton
    $quietButton = Get-BrushColor $dialogPalette.ButtonBackground
    Assert-True ((Get-BrushColor (Get-RelocationField 'primaryButton').Background) -eq $inkButton -and (Get-BrushColor (Get-ReadinessField 'refreshButton').Background) -eq $inkButton) 'the location and readiness dialogs did not use the page primary button'
    Assert-True ((Get-BrushColor (Get-RelocationField 'closeButton').Background) -eq $quietButton -and (Get-BrushColor (Get-ReadinessField 'closeButton').Background) -eq $quietButton) 'the other buttons of the location and readiness dialogs were not the quiet look'
    # One name for each schedule option wherever it appears: the editor's own check boxes, the review of a change, and the summary
    # that Settings shows under Run conditions. The primary button is named for what it does (Review changes is the Protection button
    # that approves a held change set).
    $optionSchedule = New-FreshnessSchedule ([TimeSpan]::FromHours(2)) @($true, $true, $true, $true, $false, $true)
    $optionTextType = $assembly.GetType('ResticBackuper.Dashboard.ScheduleOptionText', $true)
    function Get-OptionText([string]$Name) { return [string]$optionTextType.GetField($Name, $flags).GetValue($null) }
    $bullet = ' ' + [char]0x2022 + ' '
    Assert-True ([string]$optionSchedule.SettingsSummary -eq ((Get-OptionText 'RunMissed') + $bullet + (Get-OptionText 'Wake') + $bullet + (Get-OptionText 'StartOnBattery') + $bullet + (Get-OptionText 'FinishIfUnplugged'))) ('the Settings summary of the schedule options did not use the shared wording: ' + $optionSchedule.SettingsSummary)
    $requestType = $assembly.GetType('ResticBackuper.Dashboard.ScheduleChangeRequest', $true)
    $optionRequest = Invoke-Static $requestType 'FromInstalled' @($optionSchedule)
    $reviewLines = @(Invoke-Static $scheduleEditorType 'BuildReviewDetails' @($optionRequest))
    Assert-True ($reviewLines.Count -ge 4 -and $reviewLines[0] -eq (Get-OptionText 'RunMissed') -and $reviewLines[1] -eq (Get-OptionText 'Wake') -and $reviewLines[2] -eq (Get-OptionText 'StartOnBattery') -and $reviewLines[3] -eq (Get-OptionText 'FinishIfUnplugged')) 'the review of a schedule change did not use the shared wording'
    $editor = [Activator]::CreateInstance($scheduleEditorType, $flags, $null, [object[]]@($optionSchedule, $dialogPalette), $null)
    function Get-EditorField([string]$Name) { return $scheduleEditorType.GetField($Name, $flags).GetValue($editor) }
    Assert-True ((Get-EditorField 'reviewButton').Content -eq 'Review schedule' -and (Get-BrushColor (Get-EditorField 'reviewButton').Background) -eq $inkButton) 'the schedule editor primary button was not Review schedule in the page primary look'
    Assert-True ((Get-EditorField 'startWhenAvailableCheck').Content -eq (Get-OptionText 'RunMissed') -and (Get-EditorField 'wakeCheck').Content -eq (Get-OptionText 'Wake') -and (Get-EditorField 'finishOnBatteryCheck').Content -eq (Get-OptionText 'FinishIfUnplugged')) 'the schedule editor options did not use the shared wording'
}
finally {
    [void]$engineProfileType.GetMethod('UseFolderRootsForTesting', $flags).Invoke($null, [object[]]@([string]$null))
    [void]$engineProfileType.GetMethod('Activate', $flags).Invoke($null, [object[]]@($engineProfileType.GetProperty('Rewindle', $flags).GetValue($null)))
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    $allowedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\rewindle-restore-regression-'
    if (-not $resolvedTempRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFullPath($junction) -ne (Join-Path $resolvedTempRoot 'reparse-parent')) {
        throw 'Temporary regression cleanup target is outside the expected directory.'
    }
    if (Test-Path -LiteralPath $junction) {
        [IO.Directory]::Delete($junction)
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

foreach ($note in $skipped) { Write-Output $note }
Write-Output 'Regressions passed: snapshot scope reset, explicit whole-snapshot validation, observed-path enforcement, review invalidation, reload, retry routing, inline folder-read failures, launch guards, honest cancellation, UNC/reparse/no-overwrite/overlap destination guards and their plain-language refusals, diagnostics redaction of object keys, of whole paths (either slash, any root) and of account IDs, capped run history that is not rewritten for an evicted baseline, no live samples written and the old file removed, readable run-details timelines from long and odd logs, the restore approval wait, one Windows approval per restore session (every listing and one restore, a new session only after one ended, closed with the flow and a changed plan, a declined approval, a pipe served by another process, oversized and foreign frames), no folder read on choosing a backup or restoring all of it, folder listings kept per snapshot and bounded, the session-or-per-step choice from the installed engine, the published reason a restore cannot start, Open and Copy on a restore result acting only on the folder the restore reported once it has finished, an unreadable schedule and the outcome of a schedule change, schedule summaries for every day and lenient schedule times, capped automatic web view reloads, missing-runtime detection, a configuration check that could not complete ending the read it followed, cut-short folder listings and the published path limit, history lists bound again only when a run differs, one not-responding notice per stuck web view, backup freshness across a change of the clocks and of the run times, the tray balloon for a backup starting once per run, the not-started note for an accepted backup request that started nothing, the bounded crash log and its redacted copy in a diagnostic bundle, the installed plan read without keeping its writer out (and still refused when cut short, not an object or too large) with an install root that follows Program Files, the backup-location window''s done/current/failed steps and refused folders, the recovery-readiness window''s explained actions, the free-space warning for a whole snapshot that will not fit (a warning and never an error), the history limit the page is told, the schedule, location and readiness dialogs sharing the page tokens and the schedule wording, a status that cannot be read for a moment, a missing state folder, the retired legacy cloud file, a run history that is never written over while it is unreadable, the tray hover text and first-close hint, the setup state the page is told, and diagnostics that say what they left out and read a log cut inside a character.'
