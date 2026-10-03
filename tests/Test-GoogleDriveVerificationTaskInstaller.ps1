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
$fixtureRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ('restic-cloud-task-Å-' + [Guid]::NewGuid().ToString('N'))
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
    'Write-AtomicTaskEvidence'
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
    $result = $valid.Output | ConvertFrom-Json
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
    Assert-True (
        [string]$result.action_arguments -match
            'verify_my_drive_cloud_repository\.ps1'
    ) 'action omits protected verifier'
    Assert-True (
        [string]$result.action_arguments -notmatch
            '(?i)(password|credential|secret|DestinationRoot|sync_repository_to_google_drive)'
    ) 'action exposes secrets or the retired mirror'
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
