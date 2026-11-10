[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceInstaller = Join-Path $projectRoot 'src\install_google_drive_sync_task.ps1'
$sourceVerifier = Join-Path $projectRoot 'src\verify_my_drive_cloud_repository.ps1'
$sourcePasswordHelper = Join-Path (
    $projectRoot
) 'src\reveal-rclone-config-password.ps1'
$powershell = Join-Path (
    [System.IO.Directory]::GetParent([Environment]::SystemDirectory).FullName
) 'System32\WindowsPowerShell\v1.0\powershell.exe'
# A non-ASCII letter (A with a ring) in every fixture path. It is written as a code, not typed: this file has no byte order
# mark, so Windows PowerShell 5.1 would read a typed one in the ANSI code page as two other characters.
$nonAscii = [string][char]0x00C5
$fixtureRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('restic-cloud-task-' + $nonAscii + '-' + [Guid]::NewGuid().ToString('N'))
$taskName = 'ResticBackuperGoogleDriveSync-Test-' +
    [Guid]::NewGuid().ToString('N')
$assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)

    $script:assertions++
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Write-Utf8 {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Text
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-RuntimeManifest {
    param([Parameter(Mandatory)] [string]$Runtime)

    $files = @(
        Get-ChildItem -LiteralPath $Runtime -File -Recurse -Force |
            Where-Object Name -notin @(
                'runtime-manifest.json',
                'scheduled-task.xml',
                'google-drive-verification-task.xml'
            ) |
            Sort-Object FullName
    )
    Write-Utf8 `
        -Path (Join-Path $Runtime 'runtime-manifest.json') `
        -Text (([ordered]@{
            schema_version = 1
            file_count = $files.Count
            files = @(
                foreach ($file in $files) {
                    [ordered]@{
                        relative_path = $file.FullName.Substring(
                            $Runtime.Length + 1
                        )
                        bytes = [long]$file.Length
                        sha256 = Get-Sha256 -Path $file.FullName
                    }
                }
            )
        } | ConvertTo-Json -Depth 6))
}

function Write-AssetManifest {
    param([Parameter(Mandatory)] [string]$Root)

    $names = @(
        'rclone.exe',
        'rclone-readonly.conf',
        'rclone-config-password.clixml',
        'reveal-rclone-config-password.ps1'
    )
    Write-Utf8 `
        -Path (Join-Path $Root 'assets-manifest.json') `
        -Text (([ordered]@{
            schema_version = 1
            created_utc = [DateTime]::UtcNow.ToString('o')
            task_user_sid = (
                [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            )
            remote_name = 'ResticBackuperGoogleReadOnly'
            file_count = $names.Count
            files = @(
                foreach ($name in $names) {
                    $path = Join-Path $Root $name
                    $item = Get-Item -LiteralPath $path -Force
                    [ordered]@{
                        name = $name
                        bytes = [long]$item.Length
                        sha256 = Get-Sha256 -Path $path
                    }
                }
            )
        } | ConvertTo-Json -Depth 6))
}

function Invoke-Validation {
    param(
        [Parameter(Mandatory)] [string]$Installer,
        [Parameter(Mandatory)] [string]$Runtime,
        [Parameter(Mandatory)] [string]$Configuration,
        [Parameter(Mandatory)] [string]$CloudRoot
    )

    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = (
            & $powershell `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -ExecutionPolicy Bypass `
                -File $Installer `
                -TaskName $taskName `
                -ProtectedRoot $Runtime `
                -ConfigPath $Configuration `
                -CloudVerificationRoot $CloudRoot `
                -ValidateOnly 2>&1 |
                Out-String
        ).Trim()
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = $output
    }
}

function New-TaskDefinitionFixture {
    param(
        [Parameter(Mandatory)] [string]$UserSid,
        [Parameter(Mandatory)] [string]$Execute,
        [Parameter(Mandatory)] [string]$Arguments,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [string]$EnabledXml = ''
    )

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals>
    <Principal id="Author">
      <UserId>$UserSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-07-29T03:00:00+02:00</StartBoundary>
      <ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    $EnabledXml
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$Execute</Command>
      <Arguments>$Arguments</Arguments>
      <WorkingDirectory>$WorkingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

$tokens = $null
$parseErrors = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourceInstaller,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw 'Verification task installer did not parse before function extraction.'
}
foreach ($functionName in @(
    'Convert-TaskPrincipalToSid',
    'Assert-ProtectedRootAclDescriptor',
    'Assert-RegisteredTaskDefinition',
    'Write-AtomicTaskEvidence',
    'ConvertFrom-RcloneVersionText',
    'Get-RcloneVersion'
)) {
    $definitions = @(
        $installerAst.FindAll(
            {
                param($node)
                $node -is
                    [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
            },
            $true
        ) | ForEach-Object { $_.Extent.Text }
    )
    if ($definitions.Count -ne 1) {
        throw "Source function could not be extracted exactly: $functionName"
    }
    . ([scriptblock]::Create($definitions[0]))
}
$verifierTokens = $null
$verifierParseErrors = $null
$verifierAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourceVerifier,
    [ref]$verifierTokens,
    [ref]$verifierParseErrors
)
if ($verifierParseErrors.Count -ne 0) {
    throw 'Cloud verifier did not parse before atomic-writer extraction.'
}
$atomicJsonDefinitions = @(
    $verifierAst.FindAll(
        {
            param($node)
            $node -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Write-AtomicJson'
        },
        $true
    ) | ForEach-Object { $_.Extent.Text }
)
if ($atomicJsonDefinitions.Count -ne 1) {
    throw 'Cloud verifier atomic JSON writer could not be extracted exactly.'
}
. ([scriptblock]::Create($atomicJsonDefinitions[0]))

try {
    $runtime = Join-Path $fixtureRoot 'ProtectedRuntime'
    $driveRoot = Join-Path $fixtureRoot 'My Drive'
    $repository = Join-Path $driveRoot 'ResticBackups\Personal'
    $state = Join-Path $fixtureRoot 'ProtectedState'
    $cloudRoot = Join-Path $fixtureRoot 'CloudVerification'
    foreach ($directory in @(
        $runtime,
        $repository,
        $state,
        $cloudRoot,
        (Join-Path $cloudRoot 'runs'),
        (Join-Path $cloudRoot 'evidence')
    )) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $installedInstaller = Join-Path $runtime 'install_google_drive_sync_task.ps1'
    Copy-Item -LiteralPath $sourceInstaller -Destination $installedInstaller
    Write-Utf8 `
        -Path (Join-Path $runtime 'verify_my_drive_cloud_repository.ps1') `
        -Text '# manifest-authorized verifier fixture'
    Write-Utf8 `
        -Path (Join-Path $runtime 'verify_cloud_repository_inventory.py') `
        -Text '# manifest-authorized inventory fixture'
    Copy-Item `
        -LiteralPath $sourcePasswordHelper `
        -Destination (Join-Path $runtime 'reveal-rclone-config-password.ps1')
    $launcherFixture = Join-Path $runtime 'ResticBackuperTaskLauncher.exe'
    Write-Utf8 -Path $launcherFixture -Text 'manifest-authorized task launcher fixture'
    Write-Utf8 `
        -Path (Join-Path $repository 'config') `
        -Text '{"id":"fixture"}'
    [System.IO.File]::WriteAllBytes(
        (Join-Path $state 'run.lock'),
        [byte[]]@(0)
    )

    $configPath = Join-Path $runtime 'backup-config.json'
    $configuration = [ordered]@{
        schema_version = 1
        plan_id = '10000000-0000-4000-8000-000000000010'
        config_generation = 2
        repository = $repository
        repository_storage_mode = 'google_drivefs_stream'
        drivefs_my_drive_root = $driveRoot
        state_directory = $state
    }
    Write-Utf8 `
        -Path $configPath `
        -Text ($configuration | ConvertTo-Json -Depth 5)
    Write-Utf8 `
        -Path (Join-Path $state 'repository.json') `
        -Text (([ordered]@{
            schema_version = 1
            repository = $repository
            repository_id = 'a' * 64
        } | ConvertTo-Json -Depth 5))

    $assetPayloads = [ordered]@{
        'rclone.exe' = 'rclone fixture'
        'rclone-readonly.conf' = 'encrypted config fixture'
        'rclone-config-password.clixml' = 'DPAPI fixture'
        'reveal-rclone-config-password.ps1' = (
            [System.IO.File]::ReadAllText($sourcePasswordHelper)
        )
    }
    foreach ($entry in $assetPayloads.GetEnumerator()) {
        Write-Utf8 `
            -Path (Join-Path $cloudRoot ([string]$entry.Key)) `
            -Text ([string]$entry.Value)
    }
    Write-AssetManifest -Root $cloudRoot
    $primaryTaskEvidence = Join-Path $runtime 'scheduled-task.xml'
    $verificationTaskEvidence = Join-Path (
        $runtime
    ) 'google-drive-verification-task.xml'
    Write-Utf8 -Path $primaryTaskEvidence -Text '<primary-task-fixture />'
    Write-Utf8 `
        -Path $verificationTaskEvidence `
        -Text '<verification-task-fixture />'
    $primaryTaskEvidenceHash = Get-Sha256 -Path $primaryTaskEvidence
    Write-AtomicTaskEvidence `
        -Path $verificationTaskEvidence `
        -Xml '<verification-task-replaced />'
    $verificationTaskEvidenceHash = Get-Sha256 `
        -Path $verificationTaskEvidence
    Assert-True (
        [System.IO.File]::ReadAllText($verificationTaskEvidence) -ceq
            '<verification-task-replaced />'
    ) 'existing verification task evidence was not replaced atomically'
    Assert-True (
        @(Get-ChildItem -LiteralPath $runtime -File -Force |
            Where-Object Extension -in @('.tmp', '.bak')).Count -eq 0
    ) 'task evidence atomic replacement left a temporary or backup file'
    $newTaskEvidence = Join-Path $fixtureRoot 'new-task-evidence.xml'
    Write-AtomicTaskEvidence `
        -Path $newTaskEvidence `
        -Xml '<new-task-evidence />'
    Assert-True (
        [System.IO.File]::ReadAllText($newTaskEvidence) -ceq
            '<new-task-evidence />'
    ) 'new task evidence was not published atomically'

    $latestProof = Join-Path $fixtureRoot 'cloud-verification-latest.json'
    Write-Utf8 -Path $latestProof -Text '{"schema_version":1}'
    Write-AtomicJson `
        -Path $latestProof `
        -Value ([ordered]@{ schema_version = 2; state = 'verified' })
    $latestProofObject = Get-Content -LiteralPath $latestProof -Raw |
        ConvertFrom-Json
    Assert-True (
        [long]$latestProofObject.schema_version -eq 2 -and
        [string]$latestProofObject.state -ceq 'verified'
    ) 'existing latest cloud proof was not replaced atomically'
    Assert-True (
        @(Get-ChildItem -LiteralPath $fixtureRoot -File -Force |
            Where-Object Extension -in @('.tmp', '.bak')).Count -eq 0
    ) 'cloud proof atomic replacement left a temporary or backup file'
    $newProof = Join-Path $fixtureRoot 'new-cloud-proof.json'
    Write-AtomicJson `
        -Path $newProof `
        -Value ([ordered]@{ schema_version = 2; state = 'new' })
    Assert-True (
        [string](Get-Content -LiteralPath $newProof -Raw |
            ConvertFrom-Json).state -ceq 'new'
    ) 'new latest cloud proof was not published atomically'
    Write-RuntimeManifest -Runtime $runtime

    $valid = Invoke-Validation `
        -Installer $installedInstaller `
        -Runtime $runtime `
        -Configuration $configPath `
        -CloudRoot $cloudRoot
    Assert-True ($valid.ExitCode -eq 0) (
        "validation-only preflight failed: $($valid.Output)"
    )
    # The output passes through the console's code page, which may have no letter for a character in a path.
    Assert-True ($valid.Output -cmatch '^[\x00-\x7F]*$') (
        'validation output is not ASCII only'
    )
    $result = $valid.Output | ConvertFrom-Json
    Assert-True (
        ([string]$result.cloud_verification_root).Contains($nonAscii)
    ) 'a non-ASCII path did not survive the validation output'
    Assert-True ([string]$result.state -ceq 'validated') 'validation state'
    Assert-True ($result.task_registration_performed -eq $false) (
        'validation registered a task'
    )
    Assert-True ($result.verification_only -eq $true) (
        'task mode is not verification-only'
    )
    Assert-True ($result.source_copy_performed -eq $false) (
        'installer copied the live repository'
    )
    Assert-True (
        [string]$result.principal_logon_type -ceq 'InteractiveToken'
    ) 'principal logon type'
    Assert-True (
        [string]$result.principal_run_level -ceq 'HighestAvailable'
    ) 'principal run level'
    Assert-True ([string]$result.daily_time -ceq '03:00') 'daily trigger'
    Assert-True (
        [string]$result.multiple_instances -ceq 'IgnoreNew'
    ) 'non-overlap policy'
    Assert-True (
        [string]$result.cloud_verification_root -ceq
            [System.IO.Path]::GetFullPath($cloudRoot).TrimEnd('\')
    ) 'protected asset root binding'
    # The task starts the check through the task launcher, never Windows PowerShell itself, which would show a window.
    Assert-True (
        [string]$result.action_execute -ceq
            [System.IO.Path]::GetFullPath($launcherFixture)
    ) 'action does not start the protected task launcher'
    Assert-True (
        [string]$result.action_arguments -ceq
            ('--google-drive-check --expected-repository-id ' + ('a' * 64))
    ) 'action arguments are not the launcher Google Drive check'
    Assert-True (
        [string]$result.action_arguments -notmatch '(?i)(powershell|WindowStyle|-File)'
    ) 'action still starts Windows PowerShell'
    Assert-True (
        [string]$result.action_arguments -notmatch
            '(?i)(password|credential|secret|DestinationRoot|sync_repository_to_google_drive)'
    ) 'action exposes secrets or the retired mirror'
    Assert-True ($null -eq $result.rclone_version) (
        'assets without a recorded rclone version reported one'
    )
    Assert-True (
        [string]::IsNullOrWhiteSpace([string]$result.local_mirror_destination)
    ) 'a local mirror destination was emitted'
    Assert-True (
        (Get-Sha256 -Path $primaryTaskEvidence) -ceq
            $primaryTaskEvidenceHash
    ) 'validation changed the primary task evidence'
    Assert-True (
        (Get-Sha256 -Path $verificationTaskEvidence) -ceq
            $verificationTaskEvidenceHash
    ) 'validation changed the verification task evidence'

    # The rclone version recorded when the assets were provisioned is reported.
    $assetManifestPath = Join-Path $cloudRoot 'assets-manifest.json'
    $assetManifestText = [System.IO.File]::ReadAllText($assetManifestPath)
    $versionedManifest = $assetManifestText | ConvertFrom-Json
    $versionedManifest | Add-Member -NotePropertyName rclone_version -NotePropertyValue '1.74.4'
    Write-Utf8 -Path $assetManifestPath -Text ($versionedManifest | ConvertTo-Json -Depth 6)
    $versioned = Invoke-Validation `
        -Installer $installedInstaller `
        -Runtime $runtime `
        -Configuration $configPath `
        -CloudRoot $cloudRoot
    Assert-True ($versioned.ExitCode -eq 0) (
        "validation with a recorded rclone version failed: $($versioned.Output)"
    )
    Assert-True ([string]($versioned.Output | ConvertFrom-Json).rclone_version -ceq '1.74.4') (
        'the recorded rclone version was not reported'
    )
    Write-Utf8 -Path $assetManifestPath -Text $assetManifestText

    # A program folder without the task launcher cannot run the task.
    $launcherBytes = [System.IO.File]::ReadAllBytes($launcherFixture)
    Remove-Item -LiteralPath $launcherFixture -Force
    Write-RuntimeManifest -Runtime $runtime
    $noLauncher = Invoke-Validation `
        -Installer $installedInstaller `
        -Runtime $runtime `
        -Configuration $configPath `
        -CloudRoot $cloudRoot
    Assert-True ($noLauncher.ExitCode -ne 0) (
        'a runtime without the task launcher was accepted'
    )
    Assert-True ($noLauncher.Output -match 'does not authorize: ResticBackuperTaskLauncher\.exe') (
        "the missing-launcher failure was unclear: $($noLauncher.Output)"
    )
    [System.IO.File]::WriteAllBytes($launcherFixture, $launcherBytes)
    Write-RuntimeManifest -Runtime $runtime

    $unexpectedAsset = Join-Path $cloudRoot 'unexpected-helper.ps1'
    Write-Utf8 -Path $unexpectedAsset -Text '# unexpected fixture'
    $unexpected = Invoke-Validation `
        -Installer $installedInstaller `
        -Runtime $runtime `
        -Configuration $configPath `
        -CloudRoot $cloudRoot
    Assert-True ($unexpected.ExitCode -ne 0) (
        'an unmanifested protected-root entry was accepted'
    )
    Assert-True ($unexpected.Output -match 'unexpected entries') (
        'the unmanifested-root failure was unclear'
    )
    Remove-Item -LiteralPath $unexpectedAsset -Force

    [System.IO.File]::AppendAllText(
        (Join-Path $cloudRoot 'rclone.exe'),
        'tamper'
    )
    $tampered = Invoke-Validation `
        -Installer $installedInstaller `
        -Runtime $runtime `
        -Configuration $configPath `
        -CloudRoot $cloudRoot
    Assert-True ($tampered.ExitCode -ne 0) (
        'asset-manifest tampering was accepted'
    )
    Assert-True ($tampered.Output -match 'size or hash mismatch') (
        'asset tamper failure was unclear'
    )

    $installerText = Get-Content -LiteralPath $sourceInstaller -Raw
    Assert-True ($installerText -match '-LogonType Interactive') (
        'task is not registered interactive'
    )
    Assert-True ($installerText -match '-RunLevel Highest') (
        'task is not registered elevated'
    )
    Assert-True ($installerText -match '\[DateTime\]::Today\.AddHours\(3\)') (
        '03:00 trigger is missing'
    )
    Assert-True ($installerText -match '-MultipleInstances IgnoreNew') (
        'IgnoreNew is missing'
    )
    Assert-True ($installerText -notmatch '\bStart-ScheduledTask\b') (
        'installer can unexpectedly launch verification'
    )
    Assert-True (
        $installerText.IndexOf(
            '[System.IO.Directory]::CreateDirectory($stage)'
        ) -lt $installerText.IndexOf(
            'foreach ($entry in $sources.GetEnumerator())'
        ) -and
        $installerText.IndexOf(
            'Set-ProtectedDirectoryAcl',
            $installerText.IndexOf(
                '[System.IO.Directory]::CreateDirectory($stage)'
            )
        ) -lt $installerText.IndexOf(
            'foreach ($entry in $sources.GetEnumerator())'
        )
    ) 'the staging root is not protected before asset copy'
    Assert-True (
        $installerText -notmatch 'GoogleDriveZipBackup' -and
        $installerText -notmatch
            '(?m)^\s*\[string\]\$DestinationRoot\b' -and
        $installerText -notmatch
            '(?m)^\s*\$sourceScript\s*=.*sync_repository_to_google_drive'
    ) 'legacy mirror path remains'
    Assert-True (
        $installerText.Contains(
            '$primaryTaskEvidenceName = ''scheduled-task.xml'''
        ) -and
        $installerText.Contains(
            '$taskEvidenceName = ''google-drive-verification-task.xml'''
        )
    ) 'primary and verification task evidence paths are not distinct'

    # Provisioning asks the protected copy of rclone for its version before the manifest is written, refuses one older
    # than 1.65.0 (the first to report Google Drive SHA-256 checksums) and records it.
    $copyAt = $installerText.IndexOf('foreach ($entry in $sources.GetEnumerator())')
    $versionAt = $installerText.IndexOf(
        '$rcloneVersion = Get-RcloneVersion -Executable (Join-Path $stage ''rclone.exe'')'
    )
    $refuseAt = $installerText.IndexOf('if ($rcloneVersion -lt $minimumRcloneVersion) {')
    $manifestAt = $installerText.IndexOf('-Path (Join-Path $stage ''assets-manifest.json'')')
    Assert-True (
        $copyAt -gt 0 -and $versionAt -gt $copyAt -and $refuseAt -gt $versionAt -and $manifestAt -gt $refuseAt
    ) 'provisioning does not check the staged rclone version before writing the manifest'
    Assert-True (
        $installerText.Contains('$minimumRcloneVersion = [Version]''1.65.0''') -and
        $installerText.Contains('rclone_version = $rcloneVersion.ToString()')
    ) 'provisioning does not refuse rclone before 1.65.0 or record its version'

    foreach ($case in @(
        @("rclone v1.74.4`r`n- os/version: Microsoft Windows 11 (64 bit)`r`n", '1.74.4'),
        @('rclone v1.66.0-beta.7731.6a8ddbcc4', '1.66.0'),
        @("rclone v1.64.2`n", '1.64.2')
    )) {
        Assert-True (
            (ConvertFrom-RcloneVersionText -Text ([string]$case[0])) -eq [Version][string]$case[1]
        ) "rclone version text was misread: $($case[0])"
    }
    foreach ($text in @('', 'hello', 'rclone 1.74.4', 'rclone v1.74', "`nrclone v1.74.4", 'rclone v1.74.4 extra')) {
        $unreadable = $false
        try {
            [void](ConvertFrom-RcloneVersionText -Text $text)
        }
        catch {
            $unreadable = $_.Exception.Message -match 'could not be read'
        }
        Assert-True $unreadable "unreadable rclone version text was accepted: $text"
    }

    # Stand-ins for rclone.exe. The real one runs the same way: without a window, with Windows' own values as its
    # whole environment, and stopped if it takes too long.
    $standIns = Join-Path $fixtureRoot 'rclone-stand-ins'
    [System.IO.Directory]::CreateDirectory($standIns) | Out-Null
    $current = Join-Path $standIns 'current.cmd'
    Write-Utf8 -Path $current -Text (
        "@echo off`r`n" +
        "if not `"%RCLONE_CONFIG_PLANTED_TYPE%`"==`"`" exit /b 9`r`n" +
        "if not `"%RCLONE_ASK_PASSWORD%`"==`"false`" exit /b 8`r`n" +
        "if not `"%1`"==`"version`" exit /b 7`r`n" +
        "echo rclone v1.74.4`r`n" +
        "echo - os/version: Microsoft Windows 11 (64 bit)`r`n"
    )
    $old = Join-Path $standIns 'old.cmd'
    Write-Utf8 -Path $old -Text "@echo rclone v1.64.2`r`n"
    $failing = Join-Path $standIns 'failing.cmd'
    Write-Utf8 -Path $failing -Text "@echo something went wrong 1>&2`r`n@exit /b 3`r`n"
    $slow = Join-Path $standIns 'slow.cmd'
    Write-Utf8 -Path $slow -Text "@ping -n 4 127.0.0.1 >nul`r`n@echo rclone v1.74.4`r`n"

    $savedPlanted = [Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PLANTED_TYPE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('RCLONE_CONFIG_PLANTED_TYPE', 'sftp', 'Process')
        Assert-True ((Get-RcloneVersion -Executable $current) -eq [Version]'1.74.4') (
            'rclone version was not read, or ran with an inherited environment'
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('RCLONE_CONFIG_PLANTED_TYPE', $savedPlanted, 'Process')
    }
    Assert-True ((Get-RcloneVersion -Executable $old) -lt [Version]'1.65.0') 'an old rclone version was misread'
    $failed = $false
    try {
        [void](Get-RcloneVersion -Executable $failing)
    }
    catch {
        $failed = $_.Exception.Message -match 'exit code 3'
    }
    Assert-True $failed 'a failing rclone version run was accepted'
    $timedOut = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        [void](Get-RcloneVersion -Executable $slow -TimeoutSeconds 1)
    }
    catch {
        $timedOut = $_.Exception.Message -match 'within 1 seconds'
    }
    Assert-True ($timedOut -and $watch.Elapsed.TotalSeconds -lt 3) (
        'a stuck rclone version run was not stopped at its time limit'
    )

    $currentSid = (
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    )
    $safeAcl = [System.Security.AccessControl.DirectorySecurity]::new()
    $safeAcl.SetSecurityDescriptorSddlForm(
        (
            'O:BAD:P' +
            '(A;OICI;FA;;;SY)' +
            '(A;OICI;FA;;;BA)' +
            "(A;OICI;0x1200a9;;;$currentSid)" +
            '(A;IO;0x1200a9;;;OW)'
        )
    )
    Assert-ProtectedRootAclDescriptor `
        -Acl $safeAcl `
        -CurrentUserSid $currentSid
    Assert-True $true (
        'inherit-only OWNER RIGHTS managed-view omission was rejected'
    )

    $unsafeAcl = [System.Security.AccessControl.DirectorySecurity]::new()
    $unsafeAcl.SetSecurityDescriptorSddlForm(
        (
            'O:BAD:P' +
            '(A;OICI;FA;;;SY)' +
            '(A;OICI;FA;;;BA)' +
            "(A;OICI;0x1200a9;;;$currentSid)" +
            '(A;OICI;0x1200e9;;;OW)'
        )
    )
    $unsafeRejected = $false
    try {
        Assert-ProtectedRootAclDescriptor `
            -Acl $unsafeAcl `
            -CurrentUserSid $currentSid
    }
    catch {
        $unsafeRejected = $_.Exception.Message -match (
            'unsafe requester/owner'
        )
    }
    Assert-True $unsafeRejected 'write-capable OWNER RIGHTS entry was accepted'

    $missingSystemAcl = [System.Security.AccessControl.DirectorySecurity]::new()
    $missingSystemAcl.SetSecurityDescriptorSddlForm(
        (
            'O:BAD:P' +
            '(A;OICI;FA;;;BA)' +
            "(A;OICI;0x1200a9;;;$currentSid)"
        )
    )
    $missingSystemRejected = $false
    try {
        Assert-ProtectedRootAclDescriptor `
            -Acl $missingSystemAcl `
            -CurrentUserSid $currentSid
    }
    catch {
        $missingSystemRejected = $_.Exception.Message -match (
            'missing required identity S-1-5-18'
        )
    }
    Assert-True $missingSystemRejected (
        'missing SYSTEM full-control entry was accepted'
    )

    $taskExecute = $powershell
    $taskArguments = '-NoLogo -NoProfile'
    $taskWorkingDirectory = $runtime
    foreach ($enabledXml in @('', '<Enabled>true</Enabled>', '<Enabled>1</Enabled>')) {
        $taskXml = New-TaskDefinitionFixture `
            -UserSid $currentSid `
            -Execute $taskExecute `
            -Arguments $taskArguments `
            -WorkingDirectory $taskWorkingDirectory `
            -EnabledXml $enabledXml
        Assert-RegisteredTaskDefinition `
            -Xml $taskXml `
            -ExpectedExecute $taskExecute `
            -ExpectedArguments $taskArguments `
            -ExpectedWorkingDirectory $taskWorkingDirectory `
            -ExpectedUserSid $currentSid
        Assert-True $true (
            "valid optional Enabled representation was rejected: $enabledXml"
        )
    }
    foreach ($enabledXml in @(
        '<Enabled>false</Enabled>',
        '<Enabled>0</Enabled>',
        '<Enabled>perhaps</Enabled>',
        '<Enabled>true</Enabled><Enabled>true</Enabled>'
    )) {
        $rejected = $false
        try {
            Assert-RegisteredTaskDefinition `
                -Xml (New-TaskDefinitionFixture `
                    -UserSid $currentSid `
                    -Execute $taskExecute `
                    -Arguments $taskArguments `
                    -WorkingDirectory $taskWorkingDirectory `
                    -EnabledXml $enabledXml) `
                -ExpectedExecute $taskExecute `
                -ExpectedArguments $taskArguments `
                -ExpectedWorkingDirectory $taskWorkingDirectory `
                -ExpectedUserSid $currentSid
        }
        catch {
            $rejected = $true
        }
        Assert-True $rejected (
            "unsafe or invalid Enabled representation was accepted: $enabledXml"
        )
    }

    $uninstallerText = Get-Content `
        -LiteralPath (
            Join-Path $projectRoot 'installer\Uninstall-ResticBackuper.ps1'
        ) `
        -Raw
    Assert-True (
        $uninstallerText -match
            '\$cloudVerificationTaskName = ''ResticBackuperGoogleDriveSync'''
    ) 'uninstaller does not own the verification task'
    Assert-True (
        $uninstallerText -match
            '\$cloudTaskEvidenceName = ''google-drive-verification-task\.xml'''
    ) 'uninstaller rejects the generated protected task evidence'
    Assert-True (
        $uninstallerText -match
            '\$primaryTaskEvidenceName = ''scheduled-task\.xml'''
    ) 'uninstaller rejects the generated primary task evidence'
    Assert-True (
        $uninstallerText -match
            'verify_my_drive_cloud_repository\.ps1'
    ) 'uninstaller does not validate the verification-only action'
    # The uninstaller removes the Google Drive verification task only when it is this installation's: either form of its
    # action, exactly, from the program folder, in the root task folder. Its own functions run here against stand-in tasks.
    $uninstallerTokens = $null
    $uninstallerParseErrors = $null
    $uninstallerAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot 'installer\Uninstall-ResticBackuper.ps1'),
        [ref]$uninstallerTokens,
        [ref]$uninstallerParseErrors
    )
    if ($uninstallerParseErrors.Count -ne 0) {
        throw 'Uninstaller did not parse before function extraction.'
    }
    & {
        foreach ($functionName in @('Get-NormalizedPath', 'Assert-OwnedTask', 'Get-CloudTaskExpectation')) {
            $definitions = @(
                $uninstallerAst.FindAll(
                    {
                        param($node)
                        $node -is
                            [System.Management.Automation.Language.FunctionDefinitionAst] -and
                            $node.Name -eq $functionName
                    },
                    $true
                ) | ForEach-Object { $_.Extent.Text }
            )
            if ($definitions.Count -ne 1) {
                throw "Uninstaller function could not be extracted exactly: $functionName"
            }
            . ([scriptblock]::Create($definitions[0]))
        }
        # Stand-ins: the task Task Scheduler would return, and the uninstaller's refusal.
        function Get-ScheduledTask {
            [CmdletBinding()]
            param([string]$TaskName)
            return $standInTask
        }
        function Stop-UninstallValidation {
            param([string]$Code, [string]$Message, [string]$Console)
            throw "refused: $Code"
        }
        function New-StandInTask {
            param(
                [string]$Execute,
                [string]$Arguments,
                [string]$WorkingDirectory = $installRoot,
                [string]$TaskPath = '\'
            )
            return [pscustomobject]@{
                TaskPath = $TaskPath
                Actions = @(
                    [pscustomobject]@{
                        Execute = $Execute
                        Arguments = $Arguments
                        WorkingDirectory = $WorkingDirectory
                    }
                )
            }
        }
        function Test-UninstallerOwns {
            # As the uninstaller asks: by pattern when the program folder is gone, exactly when it names the repository.
            param([object]$Task, [string]$RepositoryId = '')
            $standInTask = $Task
            $expectation = Get-CloudTaskExpectation -Task $Task -RepositoryId $RepositoryId
            try {
                if ($RepositoryId) {
                    $owned = Assert-OwnedTask -TaskName 'ResticBackuperGoogleDriveSync' `
                        -ExpectedExecutable $expectation.Executable -ExpectedArguments $expectation.Arguments
                }
                else {
                    $owned = Assert-OwnedTask -TaskName 'ResticBackuperGoogleDriveSync' `
                        -ExpectedExecutable $expectation.Executable `
                        -ExpectedArgumentsPattern $expectation.ArgumentsPattern
                }
            }
            catch {
                if ([string]$_.Exception.Message -cne 'refused: task_not_owned') {
                    throw
                }
                return $false
            }
            return $null -ne $owned
        }

        $installRoot = Join-Path $fixtureRoot 'Program Files\ResticBackuper'
        $windowsPowerShell = $powershell
        $configurationPath = Join-Path $installRoot 'backup-config.json'
        $cloudVerificationRoot = Join-Path $fixtureRoot 'ProgramData\ResticBackuperCloudVerification'
        $launcher = Join-Path $installRoot 'ResticBackuperTaskLauncher.exe'
        $id = 'ab' * 32
        $otherId = 'cd' * 32
        $launcherArguments = '--google-drive-check --expected-repository-id ' + $id
        $earlierArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
            (Join-Path $installRoot 'verify_my_drive_cloud_repository.ps1') + '" -ConfigPath "' + $configurationPath +
            '" -CloudVerificationRoot "' + $cloudVerificationRoot + '" -ExpectedRepositoryId "' + $id + '"'
        $twoActions = New-StandInTask -Execute $launcher -Arguments $launcherArguments
        $twoActions.Actions = @($twoActions.Actions[0], $twoActions.Actions[0])

        foreach ($repositoryId in @('', $id)) {
            $when = if ($repositoryId) { 'with the program folder' } else { 'without the program folder' }
            Assert-True (
                Test-UninstallerOwns -Task (New-StandInTask -Execute $launcher -Arguments $launcherArguments) `
                    -RepositoryId $repositoryId
            ) "uninstaller does not recognize the task launcher action $when"
            Assert-True (
                Test-UninstallerOwns -Task (New-StandInTask -Execute $powershell -Arguments $earlierArguments) `
                    -RepositoryId $repositoryId
            ) "uninstaller does not recognize the earlier PowerShell action $when"
            foreach ($case in @(
                @('an extra argument', (New-StandInTask -Execute $launcher -Arguments ($launcherArguments + ' --verbose'))),
                @('a line break after the ID', (New-StandInTask -Execute $launcher -Arguments ($launcherArguments + "`n"))),
                @('a line break after the earlier action', (
                    New-StandInTask -Execute $powershell -Arguments ($earlierArguments + "`n"))),
                @('a short ID', (New-StandInTask -Execute $launcher -Arguments (
                    $launcherArguments.Substring(0, $launcherArguments.Length - 1)))),
                @('the launcher with the earlier arguments', (New-StandInTask -Execute $launcher -Arguments $earlierArguments)),
                @('Windows PowerShell with the launcher arguments', (
                    New-StandInTask -Execute $powershell -Arguments $launcherArguments)),
                @('another program', (New-StandInTask -Execute (Join-Path $fixtureRoot 'other.exe') -Arguments $launcherArguments)),
                @('another working folder', (
                    New-StandInTask -Execute $launcher -Arguments $launcherArguments -WorkingDirectory $fixtureRoot)),
                @('another task folder', (
                    New-StandInTask -Execute $launcher -Arguments $launcherArguments -TaskPath '\Other\')),
                @('two actions', $twoActions)
            )) {
                Assert-True (
                    -not (Test-UninstallerOwns -Task $case[1] -RepositoryId $repositoryId)
                ) "uninstaller owns a Google Drive task with $($case[0]) $when"
            }
        }
        # Without the program folder any well-formed ID is accepted; with it, only the registered one.
        Assert-True (
            Test-UninstallerOwns -Task (New-StandInTask -Execute $launcher -Arguments (
                '--google-drive-check --expected-repository-id ' + $otherId))
        ) 'uninstaller does not recognize a leftover task for another repository'
        Assert-True (
            -not (Test-UninstallerOwns -Task (New-StandInTask -Execute $launcher -Arguments (
                '--google-drive-check --expected-repository-id ' + $otherId)) -RepositoryId $id)
        ) 'uninstaller owns a task for another repository with the program folder'
        Assert-True (
            -not (Test-UninstallerOwns -Task (New-StandInTask -Execute $launcher -Arguments (
                '--google-drive-check --expected-repository-id ' + $id.ToUpperInvariant())))
        ) 'uninstaller owns a leftover task whose ID is in capitals'
    }
    Assert-True (
        $uninstallerText -match
            'Preserved cloud verification assets/evidence'
    ) 'uninstaller does not document preserved cloud evidence'

    [pscustomobject]@{
        tests = $assertions
        validation_only = $true
        task_registered = $false
        live_verification_started = $false
        repository_copy_performed = $false
        asset_tamper_rejected = $true
        dynamic_task_evidence_accepted = $true
        inherit_only_owner_rights_tolerated = $true
        unsafe_owner_rights_rejected = $true
        enabled_omission_accepted = $true
        disabled_or_invalid_task_rejected = $true
        existing_task_evidence_replaced = $true
        existing_latest_proof_replaced = $true
    } | ConvertTo-Json -Compress
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item `
            -LiteralPath $fixtureRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
