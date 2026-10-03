[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$sourceManager = Join-Path $projectRoot 'src\Manage-Sources.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $temporaryRoot ('ResticBackuper-SourceManager-{0}' -f [Guid]::NewGuid().ToString('N'))
$encoding = [Text.UTF8Encoding]::new($false)
$script:childProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$script:crashCounter = 0
$script:provedChildAliveCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 20) + "`n"), $encoding)
}

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-FileRecord {
    param([string]$Name, [string]$Path, [string]$Property = 'name')
    $record = [ordered]@{
        bytes = (Get-Item -LiteralPath $Path).Length
        sha256 = Get-Hash -Path $Path
    }
    $ordered = [ordered]@{}
    $ordered[$Property] = $Name
    foreach ($key in $record.Keys) { $ordered[$key] = $record[$key] }
    return $ordered
}

function Invoke-Manager {
    param(
        [string]$Action,
        [string]$Path,
        [int]$FailAfterPublish = 0,
        [string]$RequestNonce = ''
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:installedManager,
        '-ExpectedUserSid', $script:userSid,
        '-TestRoot', $fixtureRoot,
        '-TestAllowElevatedProcess'
    )
    if ($Action -in @('Add', 'Remove')) { $arguments += @("-$Action", $Path) }
    if ($FailAfterPublish -gt 0) { $arguments += @('-TestFailAfterPublish', [string]$FailAfterPublish) }
    if (-not [string]::IsNullOrEmpty($RequestNonce)) { $arguments += @('-RequestNonce', $RequestNonce) }
    $text = (& $powershell @arguments 2>&1 | Out-String).Trim()
    $exitCode = $LASTEXITCODE
    try { $json = $text | ConvertFrom-Json }
    catch { throw "Manager did not return JSON. exit=$exitCode output=$text" }
    return [pscustomobject]@{ ExitCode = $exitCode; Json = $json; Text = $text }
}

function Get-ExpectedSourceRequestDigest {
    param([string]$Action, [string]$CanonicalPath, [string]$Nonce)
    # The same domain-separated payload the dashboard's SourceManagerLauncher hashes before elevation.
    $payload = 'ResticBackuper.SourceRequest.v1' + "`n" + $script:userSid + "`n" + $Action.ToLowerInvariant() + "`n" +
        $CanonicalPath + "`n" + $Nonce
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($payload))
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function New-RequestNonce {
    $bytes = [byte[]]::new(32)
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Assert-BoundResult {
    param([object]$Result, [string]$Action, [string]$CanonicalPath, [string]$Nonce)
    $json = $Result.Json
    Assert-True -Condition ([int]$json.schema_version -eq 1) -Message "bound $Action result has schema_version 1"
    Assert-True -Condition ([string]$json.request_nonce -ceq $Nonce) -Message "bound $Action result echoes the exact nonce"
    Assert-True -Condition ([string]$json.request_user_sid -ceq $script:userSid) -Message "bound $Action result names the requesting SID"
    Assert-True -Condition ([string]$json.action -ceq $Action.ToLowerInvariant()) -Message "bound $Action result names its action"
    $expectedDigest = Get-ExpectedSourceRequestDigest -Action $Action -CanonicalPath $CanonicalPath -Nonce $Nonce
    Assert-True -Condition ([string]$json.request_digest -ceq $expectedDigest) `
        -Message "bound $Action result digest matches the dashboard's domain-separated request digest"
}

function Assert-RuntimeManifest {
    $manifest = Get-Content -LiteralPath $script:runtimeManifestPath -Raw | ConvertFrom-Json
    $records = @($manifest.files)
    Assert-True -Condition ([int]$manifest.file_count -eq $records.Count) -Message 'runtime manifest count'
    foreach ($record in $records) {
        $path = Join-Path $script:installRoot ([string]$record.relative_path)
        Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "runtime payload exists: $path"
        Assert-True -Condition ([long]$record.bytes -eq (Get-Item -LiteralPath $path).Length) -Message "runtime bytes: $path"
        Assert-True -Condition ([string]$record.sha256 -eq (Get-Hash -Path $path)) -Message "runtime hash: $path"
    }
    Assert-True -Condition ([string]$manifest.product -eq 'ResticBackuper') -Message 'runtime product metadata preserved'
    Assert-True -Condition ([string]$manifest.last_update_reason -eq 'Protected source configuration changed') -Message 'runtime update reason'
}

function Assert-RecoveryManifest {
    $manifest = Get-Content -LiteralPath $script:recoveryManifestPath -Raw | ConvertFrom-Json
    foreach ($record in @($manifest.files)) {
        $path = Join-Path $script:recoveryRoot ([string]$record.name)
        Assert-True -Condition ([long]$record.bytes -eq (Get-Item -LiteralPath $path).Length) -Message "recovery bytes: $path"
        Assert-True -Condition ([string]$record.sha256 -eq (Get-Hash -Path $path)) -Message "recovery hash: $path"
    }
    Assert-True -Condition ([string]$manifest.standalone_manifest_marker -eq 'preserve-me') -Message 'recovery manifest custom metadata'
}

function Get-TransactionDigests {
    $result = [ordered]@{}
    foreach ($path in @(
        $script:configPath,
        $script:runtimeManifestPath,
        $script:recoveryConfigPath,
        $script:recoveryManifestPath
    )) { $result[$path] = Get-Hash -Path $path }
    return $result
}

function Assert-DigestsEqual {
    param([Collections.IDictionary]$Expected, [Collections.IDictionary]$Actual, [string]$Message)
    foreach ($path in $Expected.Keys) {
        Assert-True -Condition ([string]$Expected[$path] -eq [string]$Actual[$path]) -Message "$Message ($path)"
    }
}

function Assert-TransactionValid {
    Assert-RuntimeManifest
    Assert-RecoveryManifest
    $live = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    $recovery = Get-Content -LiteralPath $script:recoveryConfigPath -Raw | ConvertFrom-Json
    $liveSources = @($live.sources)
    $recoverySources = @($recovery.sources)
    Assert-True -Condition (($liveSources -join "`n") -ceq ($recoverySources -join "`n")) `
        -Message 'protected and recovery source lists match exactly'
    Assert-True -Condition ([string]$live.plan_id -ceq [string]$recovery.plan_id) `
        -Message 'protected and recovery plan identities match exactly'
    Assert-True -Condition ([long]$live.config_generation -eq [long]$recovery.config_generation) `
        -Message 'protected and recovery configuration generations match exactly'
    Assert-True -Condition (($live.source_identities | ConvertTo-Json -Depth 10 -Compress) -ceq
        ($recovery.source_identities | ConvertTo-Json -Depth 10 -Compress)) `
        -Message 'protected and recovery source volume identities match exactly'
    $canaryMatches = @($liveSources | Where-Object { [string]$_ -ieq $script:canarySource })
    Assert-True -Condition ($canaryMatches.Count -eq 1) -Message 'protected canary remains exactly once'
    Assert-True -Condition ($liveSources.Count -ge 2) -Message 'at least one user source and canary remain'
}

function Assert-RunLockAvailable {
    $stream = [IO.File]::Open($script:lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    $locked = $false
    try {
        if ($stream.Length -eq 0) { $stream.WriteByte(0); $stream.Flush($true) }
        $stream.Seek(0, [IO.SeekOrigin]::Begin) | Out-Null
        $stream.Lock(0, 1)
        $locked = $true
    }
    catch {
        throw "The run lock was not released synchronously: $($_.Exception.Message)"
    }
    finally {
        if ($locked) { $stream.Unlock(0, 1) }
        $stream.Dispose()
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value.Contains('"')) { throw 'Disposable child-process argument contains an unsupported quote.' }
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Stop-ManagerAtBoundary {
    param(
        [Parameter(Mandatory = $true)] [string]$Boundary,
        [Parameter(Mandatory = $true)] [string]$Path,
        [int]$FailAfterPublish = 0
    )
    $script:crashCounter++
    $stem = 'crash-{0:D2}-{1}' -f $script:crashCounter, $Boundary
    $sentinel = Join-Path $fixtureRoot "$stem.sentinel"
    $stdout = Join-Path $fixtureRoot "$stem.stdout.txt"
    $stderr = Join-Path $fixtureRoot "$stem.stderr.txt"
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script:installedManager,
        '-ExpectedUserSid', $script:userSid,
        '-TestRoot', $fixtureRoot,
        '-TestAllowElevatedProcess',
        '-Add', $Path,
        '-TestPauseAfter', $Boundary,
        '-TestPauseSentinelPath', $sentinel
    )
    if ($FailAfterPublish -gt 0) {
        $arguments += @('-TestFailAfterPublish', [string]$FailAfterPublish)
    }
    $argumentLine = (($arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' ')
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentLine -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $script:childProcesses.Add($process)

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $sentinelText = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) { break }
        if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
            try {
                # CreateNew makes the name visible before the child has written
                # and flushed its content. Wait for the exact record rather
                # than treating mere path visibility as the durable boundary.
                $candidateText = [IO.File]::ReadAllText($sentinel, [Text.Encoding]::UTF8)
                if ($candidateText.Trim() -ceq $Boundary) {
                    $sentinelText = $candidateText
                    break
                }
            }
            catch [IO.IOException] { }
        }
        Start-Sleep -Milliseconds 50
    }
    if ($null -eq $sentinelText) {
        $outText = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
        $errText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
        $process.Refresh()
        $exitDescription = if ($process.HasExited) { [string]$process.ExitCode } else { 'still-running' }
        throw "Child did not durably reach $Boundary within 30 seconds. exit=$exitDescription stdout=$outText stderr=$errText"
    }
    Assert-True -Condition ($sentinelText.Trim() -ceq $Boundary) `
        -Message "$Boundary sentinel was durably written with the exact boundary"
    $process.Refresh()
    Assert-True -Condition (-not $process.HasExited) -Message "child is demonstrably alive at $Boundary before forced termination"
    $script:provedChildAliveCount++
    Stop-Process -Id $process.Id -Force
    Assert-True -Condition ($process.WaitForExit(10000)) -Message "forced child exited at $Boundary"
    $process.Refresh()
    Assert-True -Condition $process.HasExited -Message "child remains stopped at $Boundary"
}

function Invoke-WrappersBlockedByJournal {
    $pythonInterpreter = (Get-Command python.exe -ErrorAction Stop).Source
    foreach ($wrapper in @('backup.py', 'dry_run.py')) {
        $previousErrorPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $wrapperOutput = (& $pythonInterpreter -I (Join-Path $projectRoot "src\$wrapper") --config $script:configPath 2>&1 | Out-String)
            $wrapperExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorPreference
        }
        Assert-True -Condition ($wrapperExit -eq 75) -Message "$wrapper fails closed with exit 75 while a journal is pending: $wrapperOutput"
        Assert-True -Condition ($wrapperOutput -match 'source-update recovery is pending') `
            -Message "$wrapper reports the pending recovery journal"
        Assert-RunLockAvailable
    }
}

function Invoke-RecoveryAndAssertOld {
    param([Collections.IDictionary]$Expected, [string]$Boundary)
    $result = Invoke-Manager -Action 'List' -Path ''
    Assert-True -Condition ($result.ExitCode -eq 0 -and [bool]$result.Json.ok) `
        -Message "List recovered interrupted $Boundary transaction: $($result.Text)"
    Assert-DigestsEqual -Expected $Expected -Actual (Get-TransactionDigests) `
        -Message "$Boundary recovery restored exact OLD four-file hashes"
    Assert-True -Condition (-not (Test-Path -LiteralPath $script:journalPath)) `
        -Message "$Boundary recovery deleted the committed undo journal"
    Assert-TransactionValid
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $script:installRoot = Join-Path $fixtureRoot 'ProgramFiles\ResticBackuper'
    $stateRoot = Join-Path $fixtureRoot 'ProgramData\ResticBackuper'
    $repositoryRoot = Join-Path $fixtureRoot 'Repository'
    $repository = Join-Path $repositoryRoot 'Personal'
    $script:recoveryRoot = Join-Path $repositoryRoot 'RecoveryTools'
    $sourceRoot = Join-Path $fixtureRoot 'Sources'
    $firstSource = Join-Path $sourceRoot 'Documents'
    $secondSource = Join-Path $sourceRoot 'Pictures'
    $otherOfflineSource = Join-Path $sourceRoot 'Music'
    $addSource = Join-Path $sourceRoot 'NewFolder'
    $replacementSource = Join-Path $sourceRoot 'Replacement'
    $nestedSource = Join-Path $firstSource 'Nested'
    $script:canarySource = Join-Path $stateRoot 'Canary'
    foreach ($directory in @(
        $script:installRoot, (Join-Path $script:installRoot 'Python'), $stateRoot,
        $repository, $script:recoveryRoot, $firstSource, $secondSource, $otherOfflineSource,
        $addSource, $replacementSource, $nestedSource, $script:canarySource
    )) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

    $script:installedManager = Join-Path $script:installRoot 'Manage-Sources.ps1'
    Copy-Item -LiteralPath $sourceManager -Destination $script:installedManager
    foreach ($file in @(
        (Join-Path $script:installRoot 'restic.exe'),
        (Join-Path $script:installRoot 'Python\python.exe'),
        (Join-Path $script:installRoot 'excludes.txt'),
        (Join-Path $repository 'config')
    )) { [IO.File]::WriteAllText($file, "fixture`n", $encoding) }
    $canary = Join-Path $script:canarySource 'backup-canary.txt'
    [IO.File]::WriteAllText($canary, "fixture canary`n", $encoding)

    $script:configPath = Join-Path $script:installRoot 'backup-config.json'
    $config = [ordered]@{
        schema_version = 1
        plan_id = '11111111-1111-4111-8111-111111111111'
        config_generation = 1
        repository = $repository
        repository_volume_serial = 'A1B2C3D4'
        restic_executable = Join-Path $script:installRoot 'restic.exe'
        recovery_tools_directory = $script:recoveryRoot
        python_executable = Join-Path $script:installRoot 'Python\python.exe'
        state_directory = $stateRoot
        secret_file = Join-Path $stateRoot 'repository-password.dpapi.json'
        recovery_key_file = Join-Path $fixtureRoot 'RecoveryKey.txt'
        exclude_file = Join-Path $script:installRoot 'excludes.txt'
        canary_file = $canary
        hostname = 'FIXTURE'
        scheduled_tag = 'scheduled'
        cloud_placeholder_policy = 'strict'
        use_vss = $true
        sources = @($firstSource, $secondSource, $script:canarySource)
        source_identities = [ordered]@{
            $firstSource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
            $secondSource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
            $script:canarySource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
        }
    }
    Write-JsonFile -Path $script:configPath -Value $config

    $script:runtimeManifestPath = Join-Path $script:installRoot 'runtime-manifest.json'
    $runtimeFiles = @(
        Get-ChildItem -LiteralPath $script:installRoot -Recurse -File |
            Where-Object Name -ne 'runtime-manifest.json' |
            Sort-Object FullName
    )
    $runtimeManifest = [ordered]@{
        schema_version = 1
        product = 'ResticBackuper'
        version = 'test'
        created_utc = '2026-01-01T00:00:00Z'
        file_count = $runtimeFiles.Count
        files = @(
            foreach ($file in $runtimeFiles) {
                New-FileRecord -Name $file.FullName.Substring($script:installRoot.Length + 1) -Path $file.FullName -Property 'relative_path'
            }
        )
    }
    Write-JsonFile -Path $script:runtimeManifestPath -Value $runtimeManifest
    [IO.File]::WriteAllText(
        (Join-Path $script:installRoot 'scheduled-task.xml'),
        "<primary-task-fixture />`n",
        $encoding
    )
    [IO.File]::WriteAllText(
        (Join-Path $script:installRoot 'google-drive-verification-task.xml'),
        "<verification-task-fixture />`n",
        $encoding
    )

    $recoveryConfig = [ordered]@{
        schema_version = 1
        plan_id = '11111111-1111-4111-8111-111111111111'
        config_generation = 1
        repository = $repository
        repository_volume_serial = 'A1B2C3D4'
        restic_executable = 'X:\Standalone\restic.exe'
        recovery_tools_directory = 'X:\Standalone\RecoveryTools'
        python_executable = 'X:\Standalone\python.exe'
        state_directory = 'X:\Standalone\state'
        secret_file = 'X:\Standalone\secret.json'
        recovery_key_file = 'X:\Standalone\recovery.txt'
        exclude_file = 'X:\Standalone\excludes.txt'
        canary_file = $canary
        hostname = 'FIXTURE'
        scheduled_tag = 'scheduled'
        cloud_placeholder_policy = 'strict'
        standalone_marker = 'preserve-me'
        use_vss = $true
        sources = @($firstSource, $secondSource, $script:canarySource)
        source_identities = [ordered]@{
            $firstSource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
            $secondSource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
            $script:canarySource = [ordered]@{ expected_volume_serial = 'A1B2C3D4' }
        }
    }
    $script:recoveryConfigPath = Join-Path $script:recoveryRoot 'backup-config.json'
    $recoveryPayloads = @('restic.exe', 'restore.py', 'secret_store.py', 'RECOVERY.md', 'restic-release.json')
    foreach ($name in $recoveryPayloads) {
        [IO.File]::WriteAllText((Join-Path $script:recoveryRoot $name), "fixture $name`n", $encoding)
    }
    Write-JsonFile -Path $script:recoveryConfigPath -Value $recoveryConfig
    $allRecoveryPayloads = @('restic.exe', 'restore.py', 'secret_store.py', 'backup-config.json', 'RECOVERY.md', 'restic-release.json')
    $script:recoveryManifestPath = Join-Path $script:recoveryRoot 'recovery-manifest.json'
    $recoveryManifest = [ordered]@{
        schema_version = 1
        created_utc = '2026-01-01T00:00:00Z'
        repository = $repository
        standalone_manifest_marker = 'preserve-me'
        files = @(
            foreach ($name in $allRecoveryPayloads) {
                New-FileRecord -Name $name -Path (Join-Path $script:recoveryRoot $name)
            }
        )
        note = 'The repository password is intentionally not stored in this bundle.'
    }
    Write-JsonFile -Path $script:recoveryManifestPath -Value $recoveryManifest
    $script:userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:lockPath = Join-Path $stateRoot 'run.lock'
    $script:journalPath = Join-Path $stateRoot 'source-update.journal.json'

    $addResult = Invoke-Manager -Action 'Add' -Path $addSource
    Assert-True -Condition ($addResult.ExitCode -eq 0 -and [bool]$addResult.Json.ok) -Message "add succeeded: $($addResult.Text)"
    Assert-True -Condition ([string]$addResult.Json.canary_source -eq $script:canarySource) -Message 'exact canary source is reported as required'
    $liveAfterAdd = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    $recoveryAfterAdd = Get-Content -LiteralPath $script:recoveryConfigPath -Raw | ConvertFrom-Json
    Assert-True -Condition (@($liveAfterAdd.sources) -contains $addSource) -Message 'live source added'
    Assert-True -Condition (@($recoveryAfterAdd.sources) -contains $addSource) -Message 'recovery source added'
    Assert-True -Condition ([string]$recoveryAfterAdd.standalone_marker -eq 'preserve-me') -Message 'recovery standalone field preserved'
    Assert-True -Condition ([string]$recoveryAfterAdd.restic_executable -eq 'X:\Standalone\restic.exe') -Message 'recovery executable field preserved'
    Assert-RuntimeManifest
    Assert-RecoveryManifest

    $removeResult = Invoke-Manager -Action 'Remove' -Path $addSource
    Assert-True -Condition ($removeResult.ExitCode -eq 0 -and [bool]$removeResult.Json.ok) -Message "remove succeeded: $($removeResult.Text)"
    Assert-True -Condition (-not (@((Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json).sources) -contains $addSource)) -Message 'source removed'
    Assert-RuntimeManifest
    Assert-RecoveryManifest

    # The dashboard's nonce-bound result channel: the same request digest on both sides, the exact
    # generation transition and canonical path, and fail-closed nonce validation that changes nothing.
    $boundNonce = New-RequestNonce
    $beforeBoundAdd = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    $boundAdd = Invoke-Manager -Action 'Add' -Path ($addSource + '\.') -RequestNonce $boundNonce
    Assert-True -Condition ($boundAdd.ExitCode -eq 0 -and [bool]$boundAdd.Json.ok) -Message "bound add succeeded: $($boundAdd.Text)"
    Assert-BoundResult -Result $boundAdd -Action 'Add' -CanonicalPath $addSource -Nonce $boundNonce
    Assert-True -Condition ([string]$boundAdd.Json.path -ceq $addSource) -Message 'bound add reports the exact canonical path'
    Assert-True -Condition ([string]$boundAdd.Json.plan_id -ceq [string]$beforeBoundAdd.plan_id) -Message 'bound add reports the plan identity'
    Assert-True -Condition ([long]$boundAdd.Json.previous_config_generation -eq [long]$beforeBoundAdd.config_generation -and
        [long]$boundAdd.Json.config_generation -eq ([long]$beforeBoundAdd.config_generation + 1)) `
        -Message 'bound add reports the exact one-step generation transition'
    $boundRemoveNonce = New-RequestNonce
    $boundRemove = Invoke-Manager -Action 'Remove' -Path $addSource -RequestNonce $boundRemoveNonce
    Assert-True -Condition ($boundRemove.ExitCode -eq 0 -and [bool]$boundRemove.Json.ok) -Message "bound remove succeeded: $($boundRemove.Text)"
    Assert-BoundResult -Result $boundRemove -Action 'Remove' -CanonicalPath $addSource -Nonce $boundRemoveNonce
    Assert-True -Condition ([string]$boundRemove.Json.path -ceq $addSource) -Message 'bound remove reports the exact configured path'
    Assert-TransactionValid
    foreach ($invalidNonce in @(('A' * 64), ('a' * 63), 'not-a-nonce')) {
        $beforeInvalidNonce = Get-TransactionDigests
        $invalidNonceResult = Invoke-Manager -Action 'Add' -Path $addSource -RequestNonce $invalidNonce
        Assert-True -Condition ($invalidNonceResult.ExitCode -eq 1 -and [string]$invalidNonceResult.Json.error -match 'nonce is invalid') `
            -Message "invalid request nonce rejected: $invalidNonce"
        Assert-DigestsEqual -Expected $beforeInvalidNonce -Actual (Get-TransactionDigests) -Message 'invalid nonce changed no tracked file'
    }
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'SourceManagerResults'))) `
        -Message 'disposable tests never create the protected result directory'

    $offlinePeerAdd = Invoke-Manager -Action 'Add' -Path $otherOfflineSource
    Assert-True -Condition ($offlinePeerAdd.ExitCode -eq 0 -and [bool]$offlinePeerAdd.Json.ok) `
        -Message "second eventual-offline source added: $($offlinePeerAdd.Text)"
    [IO.Directory]::Delete($secondSource, $true)
    [IO.Directory]::Delete($otherOfflineSource, $true)
    $firstOfflineRemoval = Invoke-Manager -Action 'Remove' -Path $secondSource
    Assert-True -Condition ($firstOfflineRemoval.ExitCode -eq 0 -and [bool]$firstOfflineRemoval.Json.ok) `
        -Message "one missing source can be removed while a different source is also offline: $($firstOfflineRemoval.Text)"
    $sourcesAfterFirstOfflineRemoval = @((Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json).sources)
    Assert-True -Condition (-not ($sourcesAfterFirstOfflineRemoval -contains $secondSource)) `
        -Message 'first offline source removed from protected config'
    Assert-True -Condition ($sourcesAfterFirstOfflineRemoval -contains $otherOfflineSource) `
        -Message 'different offline source remains configured until explicitly removed'
    Assert-TransactionValid

    $secondOfflineRemoval = Invoke-Manager -Action 'Remove' -Path $otherOfflineSource
    Assert-True -Condition ($secondOfflineRemoval.ExitCode -eq 0 -and [bool]$secondOfflineRemoval.Json.ok) `
        -Message "second missing source can then be removed: $($secondOfflineRemoval.Text)"
    $sourcesAfterBothOfflineRemovals = @((Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json).sources)
    Assert-True -Condition (-not ($sourcesAfterBothOfflineRemovals -contains $secondSource)) `
        -Message 'first offline source stays removed'
    Assert-True -Condition (-not ($sourcesAfterBothOfflineRemovals -contains $otherOfflineSource)) `
        -Message 'second offline source removed from protected config'
    Assert-TransactionValid

    $beforeCanaryFailure = Get-TransactionDigests
    $canaryResult = Invoke-Manager -Action 'Remove' -Path $script:canarySource
    Assert-True -Condition ($canaryResult.ExitCode -eq 1 -and [string]$canaryResult.Json.error -match 'canary.*cannot be removed') -Message 'exact canary source removal rejected'
    Assert-DigestsEqual -Expected $beforeCanaryFailure -Actual (Get-TransactionDigests) -Message 'canary rejection changed no tracked file'

    $beforeLastFailure = Get-TransactionDigests
    $lastResult = Invoke-Manager -Action 'Remove' -Path $firstSource
    Assert-True -Condition ($lastResult.ExitCode -eq 1 -and [string]$lastResult.Json.error -match 'last user') -Message 'last user source removal rejected'
    Assert-DigestsEqual -Expected $beforeLastFailure -Actual (Get-TransactionDigests) -Message 'last-source rejection changed no tracked file'

    $nestedResult = Invoke-Manager -Action 'Add' -Path $nestedSource
    Assert-True -Condition ($nestedResult.ExitCode -eq 1 -and [string]$nestedResult.Json.error -match 'contains|contained') -Message 'nested source rejected'

    foreach ($failurePoint in 1..4) {
        $beforeRollback = Get-TransactionDigests
        $rollbackResult = Invoke-Manager -Action 'Add' -Path $addSource -FailAfterPublish $failurePoint
        Assert-True -Condition ($rollbackResult.ExitCode -eq 1 -and [string]$rollbackResult.Json.error -match 'rolled back') -Message "injected publish failure $failurePoint rolled back"
        Assert-DigestsEqual -Expected $beforeRollback -Actual (Get-TransactionDigests) -Message "rollback $failurePoint restored every tracked file"
    }

    $oldDigests = Get-TransactionDigests
    $forwardBoundaries = @('JournalPrepared', 'Publish1', 'Publish2', 'Publish3', 'Publish4', 'NewVerified')
    foreach ($boundary in $forwardBoundaries) {
        Stop-ManagerAtBoundary -Boundary $boundary -Path $addSource
        Assert-True -Condition (Test-Path -LiteralPath $script:journalPath -PathType Leaf) `
            -Message "$boundary forced termination retained the undo journal"
        if ($boundary -eq 'JournalPrepared') {
            Invoke-WrappersBlockedByJournal
        }
        Invoke-RecoveryAndAssertOld -Expected $oldDigests -Boundary $boundary
    }

    foreach ($boundary in @('Undo1', 'Undo2', 'Undo3', 'Undo4')) {
        Stop-ManagerAtBoundary -Boundary $boundary -Path $addSource -FailAfterPublish 4
        Assert-True -Condition (Test-Path -LiteralPath $script:journalPath -PathType Leaf) `
            -Message "$boundary forced termination retained the undo journal"
        Invoke-RecoveryAndAssertOld -Expected $oldDigests -Boundary $boundary
    }

    Stop-ManagerAtBoundary -Boundary 'JournalDeleted' -Path $addSource
    Assert-True -Condition (-not (Test-Path -LiteralPath $script:journalPath)) `
        -Message 'JournalDeleted is the commit point and leaves no journal'
    $committedNewDigests = Get-TransactionDigests
    foreach ($path in $oldDigests.Keys) {
        Assert-True -Condition ([string]$committedNewDigests[$path] -cne [string]$oldDigests[$path]) `
            -Message "JournalDeleted committed NEW bytes for every protected target ($path)"
    }
    $committedLive = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    Assert-True -Condition (@($committedLive.sources) -contains $addSource) `
        -Message 'JournalDeleted retains the newly added source'
    Assert-TransactionValid
    $postCommitList = Invoke-Manager -Action 'List' -Path ''
    Assert-True -Condition ($postCommitList.ExitCode -eq 0 -and [bool]$postCommitList.Json.ok) `
        -Message "post-commit list validates exact NEW state: $($postCommitList.Text)"
    Assert-DigestsEqual -Expected $committedNewDigests -Actual (Get-TransactionDigests) `
        -Message 'post-commit List retained exact NEW four-file hashes'
    Assert-TransactionValid

    $removeCommittedSource = Invoke-Manager -Action 'Remove' -Path $addSource
    Assert-True -Condition ($removeCommittedSource.ExitCode -eq 0 -and [bool]$removeCommittedSource.Json.ok) `
        -Message "committed test source removed after post-commit validation: $($removeCommittedSource.Text)"
    Assert-TransactionValid
    Assert-True -Condition ($script:provedChildAliveCount -eq 11) `
        -Message 'all eleven abrupt-boundary tests proved the child alive before Stop-Process -Force'

    [IO.Directory]::Delete($firstSource, $true)
    $replacementAdd = Invoke-Manager -Action 'Add' -Path $replacementSource
    Assert-True -Condition ($replacementAdd.ExitCode -eq 0 -and [bool]$replacementAdd.Json.ok) `
        -Message "a new online source can be added while the sole existing user source is offline: $($replacementAdd.Text)"
    $liveDuringReplacement = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    $recoveryDuringReplacement = Get-Content -LiteralPath $script:recoveryConfigPath -Raw | ConvertFrom-Json
    Assert-True -Condition (@($liveDuringReplacement.sources) -contains $firstSource) `
        -Message 'offline source remains configured until explicitly removed'
    Assert-True -Condition (@($liveDuringReplacement.sources) -contains $replacementSource) `
        -Message 'online replacement was added to protected config'
    Assert-True -Condition (@($recoveryDuringReplacement.sources) -contains $firstSource) `
        -Message 'offline source remains in recovery config during replacement'
    Assert-True -Condition (@($recoveryDuringReplacement.sources) -contains $replacementSource) `
        -Message 'online replacement was added to recovery config'
    Assert-TransactionValid

    $offlineSoleRemoval = Invoke-Manager -Action 'Remove' -Path $firstSource
    Assert-True -Condition ($offlineSoleRemoval.ExitCode -eq 0 -and [bool]$offlineSoleRemoval.Json.ok) `
        -Message "offline former sole source can be removed after adding its replacement: $($offlineSoleRemoval.Text)"
    $liveAfterReplacement = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
    $recoveryAfterReplacement = Get-Content -LiteralPath $script:recoveryConfigPath -Raw | ConvertFrom-Json
    Assert-True -Condition (-not (@($liveAfterReplacement.sources) -contains $firstSource)) `
        -Message 'offline old source removed from protected config'
    Assert-True -Condition (-not (@($recoveryAfterReplacement.sources) -contains $firstSource)) `
        -Message 'offline old source removed from recovery config'
    Assert-True -Condition ((@($liveAfterReplacement.sources) -join "`n") -ceq (@($replacementSource, $script:canarySource) -join "`n")) `
        -Message 'protected config contains exactly replacement plus required canary'
    Assert-True -Condition ((@($recoveryAfterReplacement.sources) -join "`n") -ceq (@($replacementSource, $script:canarySource) -join "`n")) `
        -Message 'recovery config contains exactly replacement plus required canary'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $script:canarySource 'backup-canary.txt') -PathType Leaf) `
        -Message 'required canary file remains online throughout source replacement'
    Assert-TransactionValid

    $heldLock = [IO.File]::Open($script:lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        if ($heldLock.Length -eq 0) { $heldLock.WriteByte(0); $heldLock.Flush($true) }
        $heldLock.Lock(0, 1)
        $lockResult = Invoke-Manager -Action 'Add' -Path $addSource
        Assert-True -Condition ($lockResult.ExitCode -eq 1 -and [string]$lockResult.Json.error -match 'already running') -Message 'exact byte lock blocks a concurrent source edit'
        $pythonInterpreter = (Get-Command python.exe -ErrorAction Stop).Source
        foreach ($wrapper in @('backup.py', 'dry_run.py')) {
            $previousErrorPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $wrapperOutput = (& $pythonInterpreter -I (Join-Path $projectRoot "src\$wrapper") --config $script:configPath 2>&1 | Out-String)
                $wrapperExit = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorPreference
            }
            Assert-True -Condition ($wrapperExit -eq 75) -Message "PowerShell byte lock blocks $wrapper with exit 75: $wrapperOutput"
        }
    }
    finally {
        $heldLock.Unlock(0, 1)
        $heldLock.Dispose()
    }

    $managerText = Get-Content -LiteralPath $sourceManager -Raw
    Assert-True -Condition ($managerText -notmatch '(?i)restic[^\r\n]*(forget|prune|delete)') -Message 'manager contains no snapshot-forget/prune/delete command'
    Assert-True -Condition ($managerText.Contains("'ResticBackuper.SourceRequest.v1'") -and
        $managerText.Contains("Join-Path `$stateRoot 'SourceManagerResults'") -and
        $managerText.Contains('[IO.FileMode]::CreateNew') -and
        $managerText -match '(?s)if \(-not \$isTestMode\) \{\s+Initialize-ResultChannel') `
        -Message 'installed runs require the nonce-bound, create-new protected result channel'
    $dashboardEngineText = Get-Content -LiteralPath (Join-Path $projectRoot 'src\dashboard\EngineProfile.cs') -Raw
    Assert-True -Condition ($dashboardEngineText.Contains('CreateCommon("ResticBackuper")') -and
        $dashboardEngineText.Contains('profile.SourceRequestDomain = product + ".SourceRequest.v1";')) `
        -Message 'the dashboard Rewindle profile uses the same source request domain'
    $installerText = Get-Content -LiteralPath (Join-Path $projectRoot 'installer\Install-ResticBackuper.ps1') -Raw
    Assert-True -Condition ($installerText -match "'Manage-Sources\.ps1'") -Message 'installer packages the protected manager'
    $global:LASTEXITCODE = 0
    [pscustomobject]@{
        ok = $true
        tests = 23
        add_remove = 'passed'
        nonce_bound_result_channel = 'passed'
        exact_canary_required = 'passed'
        nested_rejected = 'passed'
        four_file_rollback = 'passed'
        abrupt_forward_recovery_boundaries = $forwardBoundaries.Count
        abrupt_undo_recovery_boundaries = 4
        abrupt_commit_boundary = 'passed'
        children_alive_before_force_kill = $script:provedChildAliveCount
        pending_journal_backup_dry_run_exit_75_and_unlock = 'passed'
        byte_lock = 'passed'
        powershell_python_lock_interop = 'passed'
        recovery_fields_preserved = 'passed'
        two_simultaneously_offline_source_removals = 'passed'
        offline_sole_source_replacement = 'passed'
        runtime_manifest_after_add_remove = 'passed'
    } | ConvertTo-Json -Depth 3
}
finally {
    foreach ($process in $script:childProcesses) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                [void]$process.WaitForExit(10000)
            }
        }
        catch { }
        finally { $process.Dispose() }
    }
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    $safePrefix = $temporaryRoot + '\ResticBackuper-SourceManager-'
    if ($resolvedFixture.StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
