[CmdletBinding()]
param(
    [switch]$KeepWorkspace
)

# Hermetic tests of the installer's machine-readable backend (docs/setup-contract.md): plan mode, the progress feed writer
# and the pure decision functions. Everything is built in a disposable folder under the temporary directory, plan mode runs
# in child processes that are pointed at fixture roots instead of the real Program Files, ProgramData and profile folders
# (the REWINDLE_SETUP_TEST_ROOTS hook that only -PlanOnly honors), and nothing here ever starts an install or an uninstall.
# It runs unelevated and also elevated (the hosted CI runner is an administrator).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).TrimEnd('\')
$installerScript = Join-Path $projectRoot 'installer\Install-ResticBackuper.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$workspaceName = 'Rewindle-InstallPlan-' + [Guid]::NewGuid().ToString('N')
$workspace = Join-Path ([IO.Path]::GetTempPath()) $workspaceName
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:assertions = 0
$script:planRuns = 0
$utf8 = [Text.UTF8Encoding]::new($false)

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
    if ($expectedText -cne $actualText) {
        throw "FAILED: $Message (expected '$expectedText', got '$actualText')"
    }
}

function Write-Text {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

$script:junctions = [Collections.Generic.List[string]]::new()
function New-Junction {
    param([string]$Link, [string]$Target)
    $output = & cmd.exe /c mklink /J ('"' + $Link + '"') ('"' + $Target + '"') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not create the test junction: $output" }
    $script:junctions.Add($Link)
}

function Remove-Junction {
    param([string]$Link)
    # Deletes the link itself; never recursive, so the target is never followed.
    if (Test-Path -LiteralPath $Link) { [IO.Directory]::Delete($Link) }
}

function Set-OwnerToCurrentUser {
    param([string]$Path)
    # An elevated administrator creates folders owned by the Administrators group; the unelevated wizard's folders belong to
    # the user. Make the fixture look like the latter.
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($currentSid))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $trailing = [regex]::Match($Value, '\\+$').Value
    return '"' + $Value.Replace('"', '\"') + $trailing + '"'
}

# ------------------------------------------------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------------------------------------------------

$installerText = [IO.File]::ReadAllText($installerScript)
$requiredPayload = [Collections.Generic.List[string]]::new()
$dashboardPayload = [Collections.Generic.List[string]]::new()
$requiredBlock = [regex]::Match($installerText, '(?s)\$required = @\((.*?)\r?\n    \)')
Assert-True $requiredBlock.Success 'the payload list in Assert-Payload is found'
foreach ($line in $requiredBlock.Groups[1].Value -split "\r?\n") {
    $entry = [regex]::Match($line, "^\s*'([^']+)',?\s*$")
    if ($entry.Success) { $requiredPayload.Add($entry.Groups[1].Value) }
}
foreach ($entry in [regex]::Matches($installerText, "\`$required \+= '([^']+)'")) {
    $dashboardPayload.Add($entry.Groups[1].Value)
}
Assert-True ($requiredPayload.Count -gt 30 -and $dashboardPayload.Count -ge 6) 'the required payload files were read from the installer'

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# A bundle laid out like the release: Install-ResticBackuper.ps1, payload\ and payload-manifest.json.
function New-Bundle {
    param(
        [string]$Name,
        [switch]$NoPayload,
        [switch]$WithoutDashboard,
        [string[]]$OmitFromManifestAndDisk = @(),
        [string]$Version = '9.9.9-fixture.1'
    )
    $bundle = Join-Path $workspace "bundles\$Name"
    New-Item -ItemType Directory -Path $bundle -Force | Out-Null
    Copy-Item -LiteralPath $installerScript -Destination (Join-Path $bundle 'Install-ResticBackuper.ps1')
    if ($NoPayload) { return $bundle }
    $payload = Join-Path $bundle 'payload'
    $names = @($requiredPayload)
    if (-not $WithoutDashboard) { $names += @($dashboardPayload) }
    $names = @($names | Where-Object { $OmitFromManifestAndDisk -notcontains $_ })
    foreach ($relative in $names) {
        $text = if ($relative -eq 'VERSION') { $Version } else { "fixture payload file $relative" }
        if ($relative -ne 'dashboard-assets.json') { Write-Text -Path (Join-Path $payload $relative) -Text $text }
    }
    if (-not $WithoutDashboard -and ($names -contains 'dashboard-assets.json')) {
        $assets = @()
        foreach ($relative in @('web\index.html', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.Wpf.dll', 'WebView2Loader.dll')) {
            $path = Join-Path $payload $relative
            $assets += [ordered]@{ relative_path = $relative.Replace('\', '/'); bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-Sha256 $path) }
        }
        Write-Text -Path (Join-Path $payload 'dashboard-assets.json') -Text (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; files = $assets }) -Depth 4)
    }
    $files = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $payload -Recurse -File -Force | Sort-Object FullName)) {
        $files += [ordered]@{
            relative_path = $file.FullName.Substring($payload.Length + 1)
            bytes = $file.Length
            sha256 = (Get-Sha256 $file.FullName)
        }
    }
    $manifest = [ordered]@{ schema_version = 1; product = 'ResticBackuper'; version = $Version; file_count = $files.Count; files = $files }
    Write-Text -Path (Join-Path $bundle 'payload-manifest.json') -Text (ConvertTo-Json -InputObject $manifest -Depth 6)
    return $bundle
}

# Fixture roots: where the plan believes Program Files, ProgramData and the profile are.
function New-RootsSet {
    param([string]$Name, [switch]$NoDefaultRepository)
    $base = Join-Path $workspace "roots\$Name"
    $set = [ordered]@{
        Base = $base
        ProgramFiles = Join-Path $base 'ProgramFiles'
        ProgramData = Join-Path $base 'ProgramData'
        Profile = Join-Path $base 'Profile'
        LocalAppData = Join-Path $base 'LocalAppData'
        DriveFsRoot = Join-Path $base 'DriveFs\My Drive'
        DefaultRepository = Join-Path $base 'Backups\Default'
    }
    foreach ($key in @('ProgramFiles', 'ProgramData', 'Profile', 'LocalAppData')) { New-Item -ItemType Directory -Path $set[$key] -Force | Out-Null }
    foreach ($folder in @('Documents', 'Pictures')) { New-Item -ItemType Directory -Path (Join-Path $set.Profile $folder) -Force | Out-Null }
    $json = [ordered]@{
        program_files = $set.ProgramFiles
        program_data = $set.ProgramData
        user_profile = $set.Profile
        local_app_data = $set.LocalAppData
        drivefs_my_drive_root = $set.DriveFsRoot
        known_folders = [ordered]@{
            Desktop = Join-Path $set.Profile 'Desktop'
            Documents = Join-Path $set.Profile 'Documents'
            Pictures = Join-Path $set.Profile 'Pictures'
            Music = Join-Path $set.Profile 'Music'
            Videos = Join-Path $set.Profile 'Videos'
            Downloads = Join-Path $set.Profile 'Downloads'
            Favorites = Join-Path $set.Profile 'Favorites'
            SavedGames = Join-Path $set.Profile 'Saved Games'
        }
    }
    $json['default_repository'] = if ($NoDefaultRepository) { '' } else { $set.DefaultRepository }
    $set['Json'] = ConvertTo-Json -InputObject $json -Depth 4 -Compress
    return $set
}

function Invoke-ProcessCapture {
    param([string]$FileName, [string[]]$Arguments, [hashtable]$Environment, [int]$TimeoutSeconds = 180)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FileName
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "The child process did not finish in $TimeoutSeconds seconds."
    }
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.Result; Error = $errTask.Result }
}

# Runs `Install-ResticBackuper.ps1 -PlanOnly` in a child process whose temporary folder and machine roots are fixtures.
function Invoke-Plan {
    param(
        [Parameter(Mandatory)][string]$Bundle,
        [Parameter(Mandatory)]$Roots,
        [Parameter(Mandatory)][string]$Temp,
        [string[]]$Arguments = @(),
        [string]$PlanPath,
        [switch]$NoPlanOutputArgument
    )
    $script:planRuns++
    if (-not $PlanPath) { $PlanPath = Join-Path $Temp ('plan-' + [Guid]::NewGuid().ToString('N') + '.json') }
    # PowerShell variable names ignore case, so the local list must not be called $arguments next to the parameter $Arguments.
    $childArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Bundle 'Install-ResticBackuper.ps1'), '-PlanOnly')
    if (-not $NoPlanOutputArgument) { $childArguments += @('-PlanOutput', $PlanPath) }
    $childArguments += $Arguments
    $result = Invoke-ProcessCapture -FileName $windowsPowerShell -Arguments $childArguments -Environment @{
        TEMP = $Temp
        TMP = $Temp
        REWINDLE_SETUP_TEST_ROOTS = $Roots.Json
    }
    $plan = $null
    if ($PlanPath -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
        $bytes = [IO.File]::ReadAllBytes($PlanPath)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'the plan file has no byte-order mark'
        $plan = $utf8.GetString($bytes) | ConvertFrom-Json
    }
    return [pscustomobject]@{ ExitCode = $result.ExitCode; Output = $result.Output; Error = $result.Error; Plan = $plan; PlanPath = $PlanPath }
}

function Get-ErrorCodes {
    param($Plan)
    return @(@($Plan.errors) | ForEach-Object { [string]$_.code })
}

function Get-WarningCodes {
    param($Plan)
    return @(@($Plan.warnings) | ForEach-Object { [string]$_.code })
}

function Assert-PlanError {
    param($Run, [string]$Code, [string]$Field, [string]$Label)
    Assert-True ($Run.ExitCode -eq 0) "$Label : exit code 0 although the plan is not ok (stderr: $($Run.Error))"
    Assert-True ($null -ne $Run.Plan) "$Label : a plan was written"
    $found = @(@($Run.Plan.errors) | Where-Object { $_.code -ceq $Code })
    Assert-True ($found.Count -ge 1) "$Label : error $Code is reported (got: $((Get-ErrorCodes $Run.Plan) -join ', '))"
    Assert-Equal $Field $found[0].field "$Label : $Code belongs to the $Field field"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$found[0].message)) "$Label : $Code has a message"
    Assert-True (-not $Run.Plan.ok) "$Label : ok is false"
}

# ------------------------------------------------------------------------------------------------------------------------
# Snapshots for the "no side effects" proof
# ------------------------------------------------------------------------------------------------------------------------

function Get-TreeSnapshot {
    param([string[]]$Roots)
    $lines = foreach ($root in $Roots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName | ForEach-Object {
                # NTFS refreshes a folder's cached time lazily (merely opening the folder can change what its parent lists), so
                # folders are compared by name and attributes and only files by size and time.
                if ($_.PSIsContainer) { '{0}|dir|{1}' -f $_.FullName, [int]$_.Attributes }
                else { '{0}|{1}|{2}|{3}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks, [int]$_.Attributes }
            }
        }
    }
    return ($lines -join "`n")
}

function Get-RegistrySnapshot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients'
    )
    $lines = foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) {
            $item = Get-Item -LiteralPath $key
            "$key|values=" + (@($item.GetValueNames() | Sort-Object | ForEach-Object { $_ + '=' + [string]$item.GetValue($_) }) -join ';')
            "$key|subkeys=" + (@($item.GetSubKeyNames() | Sort-Object) -join ';')
        }
        else { "$key|absent" }
    }
    return ($lines -join "`n")
}

function Get-TaskSnapshot {
    try {
        return (@(Get-ScheduledTask -ErrorAction Stop | Sort-Object TaskPath, TaskName | ForEach-Object { '{0}{1}' -f $_.TaskPath, $_.TaskName }) -join "`n")
    }
    catch { return 'tasks unavailable' }
}

# ------------------------------------------------------------------------------------------------------------------------
# Functions under test, taken from the installer without running it
# ------------------------------------------------------------------------------------------------------------------------

$parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseInput($installerText, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'the installer parses'
function Get-InstallerFunctionText {
    param([string[]]$Name)
    $found = $installerAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $text = foreach ($functionName in $Name) {
        $match = @($found | Where-Object { $_.Name -eq $functionName })
        if ($match.Count -ne 1) { throw "The installer does not define exactly one function named $functionName." }
        $match[0].Extent.Text
    }
    return ($text -join "`n`n")
}

. ([scriptblock]::Create((Get-InstallerFunctionText -Name @(
    'New-InstallFinding', 'Stop-InstallFinding', 'Stop-InstallValidation', 'Get-InstallFinding',
    'Get-VolumeEligibility', 'Select-RecommendedVolume', 'Assert-SourceDriveProperties', 'Assert-LocalNtfsVolume',
    'Assert-VolumeFreeSpace', 'Test-DriveFsMount', 'Convert-FileAccessMask', 'Test-DescriptorGrantsAccess',
    'Get-MicrosoftSignerProblem', 'Get-AuthenticodeSignerFacts', 'Assert-MicrosoftSignedExecutable',
    'Test-TrustedStateOwner', 'Assert-StateFolderOwner', 'New-ProtectedDirectorySecurity'))))

$regionMatch = [regex]::Match($installerText, '(?s)# region progress-feed.*?# endregion progress-feed')
Assert-True $regionMatch.Success 'the progress feed region is found'
. ([scriptblock]::Create($regionMatch.Value))

function Get-FindingCode {
    param([scriptblock]$Action)
    try { & $Action } catch {
        $finding = Get-InstallFinding -ErrorRecord $_
        if ($null -eq $finding) { return "not-a-finding: $($_.Exception.Message)" }
        return [string]$finding.code
    }
    return 'no-finding'
}

$summary = $null
try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null

    # ====================================================================================================================
    # 1. The plan document: shape, types and the happy path
    # ====================================================================================================================
    $bundle = New-Bundle -Name 'full'
    $roots = New-RootsSet -Name 'base'
    $temp = Join-Path $workspace 'temp-base'
    New-Item -ItemType Directory -Path $temp | Out-Null
    $repositoryRoot = Join-Path $workspace 'repositories'
    $docs = Join-Path $workspace 'sources\docs'
    $photos = Join-Path $workspace 'sources\photos'
    foreach ($path in @($repositoryRoot, $docs, $photos)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $goodRepository = Join-Path $repositoryRoot 'good\Backup'
    $baseArguments = @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1', '-Schedule', '03:30')

    $treeRoots = @($roots.Base, $docs, $photos, $repositoryRoot, (Join-Path $workspace 'bundles'))
    $before = [pscustomobject]@{
        Tree = Get-TreeSnapshot -Roots $treeRoots
        Temp = Get-TreeSnapshot -Roots @($temp)
        Registry = Get-RegistrySnapshot
        Tasks = Get-TaskSnapshot
    }
    Assert-True ($before.Temp -eq '') 'the fixture temporary folder starts empty'

    $run = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments
    $plan = $run.Plan
    Assert-Equal 0 $run.ExitCode "the plan run exits 0 (stderr: $($run.Error))"
    Assert-Equal '' $run.Output.Trim() 'plan mode prints nothing to the console'
    Assert-True ($null -ne $plan) 'a plan was written'

    # --- no side effects: only the plan file appeared, and the machine state did not move ---
    $after = [pscustomobject]@{
        Tree = Get-TreeSnapshot -Roots $treeRoots
        Temp = @(Get-ChildItem -LiteralPath $temp -Force | ForEach-Object Name)
        Registry = Get-RegistrySnapshot
        Tasks = Get-TaskSnapshot
    }
    Assert-Equal @((Split-Path -Leaf $run.PlanPath)) $after.Temp 'the plan file is the only file plan mode left in the temporary folder'
    $treeDifference = @(Compare-Object -ReferenceObject @($before.Tree -split "`n") -DifferenceObject @($after.Tree -split "`n") | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
    Assert-True ($before.Tree -ceq $after.Tree) "plan mode left the fixture roots, sources, repositories and bundle untouched (differences: $($treeDifference -join ' ## '))"
    Assert-True ($before.Registry -ceq $after.Registry) 'plan mode did not change the uninstall, startup or WebView2 registry keys'
    Assert-True ($before.Tasks -ceq $after.Tasks) 'plan mode did not change the scheduled tasks'
    Assert-True (-not (Test-Path -LiteralPath $goodRepository)) 'plan mode did not create the repository folder'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $roots.ProgramFiles 'ResticBackuper'))) 'plan mode did not create an install folder'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $roots.ProgramData 'ResticBackuper'))) 'plan mode did not create a state folder'

    # --- schema ---
    $topLevel = @($plan.PSObject.Properties.Name)
    Assert-Equal @('schema', 'ok', 'errors', 'warnings', 'resolved', 'defaults', 'environment') $topLevel 'the plan has exactly the documented top-level properties, in order'
    Assert-Equal 'Rewindle.InstallPlan.v1' $plan.schema 'schema id'
    Assert-True ($plan.ok -is [bool]) 'ok is a boolean'
    Assert-True ($plan.ok -eq $true) "the plan for a valid configuration is ok (errors: $((Get-ErrorCodes $plan) -join ', '))"
    Assert-Equal @() @($plan.errors) 'no errors for a valid configuration'
    $allowedFields = @('repository', 'sources', 'schedule', 'storage_mode', 'environment')
    foreach ($finding in @(@($plan.errors) + @($plan.warnings))) {
        Assert-True ($allowedFields -contains $finding.field) "finding $($finding.code) names a documented field"
        Assert-True ($finding.code -cmatch '^[a-z][a-z0-9_]*$') "finding code $($finding.code) is a snake_case identifier"
    }
    Assert-Equal @('repository', 'storage_mode', 'repository_access', 'existing_repository_access', 'drivefs_my_drive_root', 'sources', 'canary_source', 'schedule', 'vss', 'minimum_free_bytes', 'estimated_source_bytes') @($plan.resolved.PSObject.Properties.Name) 'resolved properties'
    Assert-Equal $goodRepository $plan.resolved.repository 'resolved repository'
    Assert-Equal 'local_ntfs' $plan.resolved.storage_mode 'resolved storage mode'
    Assert-Equal 'password' $plan.resolved.repository_access 'a new backup location with nothing asked for resolves to a password'
    Assert-True ($null -eq $plan.resolved.existing_repository_access) 'a new backup location has no backups, so no recorded way of opening them'
    Assert-True ($null -eq $plan.resolved.drivefs_my_drive_root) 'no DriveFS root in local mode'
    Assert-Equal @($docs, $photos) @($plan.resolved.sources) 'resolved sources, in the order given'
    Assert-Equal (Join-Path $roots.ProgramData 'ResticBackuper\Canary') $plan.resolved.canary_source 'canary source'
    Assert-Equal '03:30' $plan.resolved.schedule 'resolved schedule'
    Assert-True ($plan.resolved.vss -eq $true) 'VSS is on by default'
    Assert-Equal 1073741824 $plan.resolved.minimum_free_bytes 'minimum_free_bytes is the requested number of bytes'
    Assert-True ($null -eq $plan.resolved.estimated_source_bytes) 'estimated_source_bytes stays null'
    Assert-Equal @('repository', 'storage_mode', 'sources', 'schedule') @($plan.defaults.PSObject.Properties.Name) 'defaults properties'
    Assert-Equal $roots.DefaultRepository $plan.defaults.repository 'the default repository comes from the (hooked) recommendation'
    Assert-Equal 'local_ntfs' $plan.defaults.storage_mode 'default storage mode'
    Assert-Equal '02:00' $plan.defaults.schedule 'default schedule'
    Assert-Equal @((Join-Path $roots.Profile 'Documents'), (Join-Path $roots.Profile 'Pictures')) @($plan.defaults.sources) 'default sources are the known folders that exist'

    $environment = $plan.environment
    Assert-Equal @('version', 'os', 'powershell', 'dotnet_framework_48', 'elevated', 'webview2', 'existing_install', 'volumes', 'drivefs', 'known_folders') @($environment.PSObject.Properties.Name) 'environment properties'
    Assert-Equal '9.9.9-fixture.1' $environment.version 'environment.version comes from the payload'
    Assert-Equal @('caption', 'build', 'x64', 'supported') @($environment.os.PSObject.Properties.Name) 'os properties'
    Assert-True ($environment.os.x64 -is [bool] -and $environment.os.supported -is [bool]) 'os flags are booleans'
    Assert-True ($environment.os.build -cmatch '^\d+$') 'os build is the build number'
    Assert-True ($environment.powershell -cmatch '^5\.1\.') 'powershell is the 5.1 version'
    Assert-True ($environment.dotnet_framework_48 -is [bool]) 'dotnet_framework_48 is a boolean'
    Assert-True ($environment.elevated -eq $isElevated) 'elevated reports the real elevation of the process'
    Assert-True ($null -eq $environment.webview2 -or $environment.webview2 -cmatch '^\d+(\.\d+){1,3}$') 'webview2 is a version or null'
    Assert-Equal @('rewindle', 'legacy_personal_edition', 'kept_repository', 'kept_repository_access') @($environment.existing_install.PSObject.Properties.Name) 'existing_install properties'
    Assert-True ($null -eq $environment.existing_install.rewindle) 'a fresh fixture has no Rewindle installation'
    Assert-True ($environment.existing_install.legacy_personal_edition -eq $false) 'a fresh fixture has no legacy edition'
    Assert-True ($null -eq $environment.existing_install.kept_repository) 'a fresh fixture has no backups kept from an earlier installation'
    Assert-True ($null -eq $environment.existing_install.kept_repository_access) 'and so no recorded way of opening them'
    $volumes = @($environment.volumes)
    Assert-True ($volumes.Count -ge 1) 'at least one volume is listed'
    $volumeProperties = @('root', 'label', 'filesystem', 'drive_type', 'size_bytes', 'free_bytes', 'is_system', 'same_physical_disk_as_system', 'eligible', 'ineligible_reason', 'ineligible_message', 'recommended')
    foreach ($entry in $volumes) {
        Assert-Equal $volumeProperties @($entry.PSObject.Properties.Name) "volume $($entry.root) properties"
        Assert-True ($entry.root -cmatch '^[A-Z]:\\$') "volume root $($entry.root) is a drive root"
        Assert-True (@('fixed', 'removable', 'network', 'cdrom', 'ram', 'unknown') -contains $entry.drive_type) "volume $($entry.root) drive type is documented"
        Assert-True ($entry.label -is [string] -and $entry.filesystem -is [string]) "volume $($entry.root) label and filesystem are strings"
        Assert-True ($entry.eligible -is [bool] -and $entry.recommended -is [bool] -and $entry.is_system -is [bool]) "volume $($entry.root) flags are booleans"
        Assert-True ($null -eq $entry.same_physical_disk_as_system -or $entry.same_physical_disk_as_system -is [bool]) "volume $($entry.root) same_physical_disk_as_system is true, false or null"
        Assert-True (($entry.eligible -and $null -eq $entry.ineligible_reason) -or (-not $entry.eligible -and $entry.ineligible_reason -cmatch '^[a-z_]+$')) "volume $($entry.root) has a reason exactly when it is ineligible"
        if ($entry.recommended) {
            Assert-True ($entry.eligible -and $entry.filesystem -ieq 'NTFS' -and $entry.same_physical_disk_as_system -eq $false) "the recommended volume $($entry.root) is eligible NTFS on another physical disk"
        }
    }
    Assert-True (@($volumes | Where-Object { $_.recommended }).Count -le 1) 'at most one volume is recommended'
    Assert-Equal 1 @($volumes | Where-Object { $_.is_system }).Count 'exactly one volume is the system volume'
    Assert-True (@($volumes | Where-Object { $_.is_system })[0].same_physical_disk_as_system -eq $true) 'the system volume is on the system disk'
    Assert-Equal @('detected', 'my_drive_root') @($environment.drivefs.PSObject.Properties.Name) 'drivefs properties'
    Assert-True ($environment.drivefs.detected -is [bool]) 'drivefs.detected is a boolean'
    Assert-Equal @('Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads', 'Favorites') @(@($environment.known_folders) | ForEach-Object key) 'known folder keys and order'
    foreach ($folder in @($environment.known_folders)) {
        Assert-Equal @('key', 'path', 'exists', 'default_selected') @($folder.PSObject.Properties.Name) "known folder $($folder.key) properties"
        Assert-True ($folder.exists -is [bool] -and $folder.default_selected -is [bool]) "known folder $($folder.key) flags are booleans"
    }
    $documentsFolder = @($environment.known_folders | Where-Object { $_.key -eq 'Documents' })[0]
    $desktopFolder = @($environment.known_folders | Where-Object { $_.key -eq 'Desktop' })[0]
    Assert-True ($documentsFolder.exists -and $documentsFolder.default_selected) 'an existing known folder is selected by default'
    Assert-True (-not $desktopFolder.exists -and -not $desktopFolder.default_selected) 'a missing known folder is neither existing nor selected'

    # The same-drive warning must appear exactly when the repository volume is the system volume.
    $systemRoot = [IO.Path]::GetPathRoot([Environment]::SystemDirectory)
    $repositoryOnSystemVolume = [string]::Equals([IO.Path]::GetPathRoot($goodRepository), $systemRoot, [StringComparison]::OrdinalIgnoreCase)
    if ($repositoryOnSystemVolume) {
        Assert-True ((Get-WarningCodes $plan) -contains 'repository_on_system_disk') 'a repository on the Windows drive is warned about'
    }
    # (On another partition of the same physical disk the plan warns too; whether this machine's temp folder is on one is not known.)
    $planVolume = @($plan.environment.volumes | Where-Object { $_.root -ieq [IO.Path]::GetPathRoot($goodRepository) })[0]
    Assert-True ($null -ne $planVolume) 'the repository volume is among the listed volumes'
    if ($planVolume.same_physical_disk_as_system -eq $false) {
        Assert-True ((Get-WarningCodes $plan) -notcontains 'repository_on_system_disk') 'a repository on a different physical disk is not warned about'
    }

    # --- a second run with the same output path must refuse (create-new) and must not touch the first plan ---
    $firstHash = Get-Sha256 $run.PlanPath
    $again = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments -PlanPath $run.PlanPath
    Assert-True ($again.ExitCode -ne 0) 'a plan is never written over an existing file'
    Assert-True ($again.Error -match 'already exists') 'the refusal says the file already exists'
    Assert-Equal $firstHash (Get-Sha256 $run.PlanPath) 'the earlier plan is unchanged'

    # --- plan with no arguments at all: the defaults are resolved (no real drive is probed thanks to the fixture default) ---
    $noArguments = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-MinimumFreeGiB', '1')
    Assert-Equal 0 $noArguments.ExitCode 'a plan with only defaults is written'
    Assert-Equal $roots.DefaultRepository $noArguments.Plan.resolved.repository 'without -Repository the resolved repository is the default'
    Assert-Equal @($noArguments.Plan.defaults.sources) @($noArguments.Plan.resolved.sources) 'without -SourceList the resolved sources are the defaults'
    Assert-Equal '02:00' $noArguments.Plan.resolved.schedule 'without -Schedule the schedule is 02:00'
    $noDefaultRoots = New-RootsSet -Name 'no-default' -NoDefaultRepository
    $noDefault = Invoke-Plan -Bundle $bundle -Roots $noDefaultRoots -Temp $temp -Arguments @('-MinimumFreeGiB', '1')
    Assert-PlanError $noDefault 'repository_required' 'repository' 'no repository and no recommended drive'
    Assert-True ($null -eq $noDefault.Plan.defaults.repository) 'defaults.repository is null when no drive is recommended'

    # ====================================================================================================================
    # 2. One error code per invalid input
    # ====================================================================================================================
    $cases = Join-Path $workspace 'cases'
    New-Item -ItemType Directory -Path $cases | Out-Null
    function Test-Invalid {
        param([string]$Label, [hashtable]$Arguments, [string]$Code, [string]$Field, $RootsSet = $roots, [string]$BundlePath = $bundle, [string[]]$Extra = @())
        $parameters = [ordered]@{ Repository = $goodRepository; SourceList = "$docs;$photos"; Schedule = '03:30' }
        foreach ($key in $Arguments.Keys) { $parameters[$key] = $Arguments[$key] }
        $argumentList = @('-MinimumFreeGiB', '1')
        foreach ($key in $parameters.Keys) { $argumentList += @("-$key", [string]$parameters[$key]) }
        $argumentList += $Extra
        $result = Invoke-Plan -Bundle $BundlePath -Roots $RootsSet -Temp $temp -Arguments $argumentList
        Assert-PlanError $result $Code $Field $Label
        return $result
    }

    # repository
    [void](Test-Invalid 'relative repository' @{ Repository = 'relative\folder' } 'repository_not_absolute' 'repository')
    $started = Get-Date
    [void](Test-Invalid 'network repository' @{ Repository = '\\rewindle-no-such-host.invalid\share\backup' } 'repository_not_local' 'repository')
    Assert-True (((Get-Date) - $started).TotalSeconds -lt 60) 'a network repository is refused without contacting the network'
    [void](Test-Invalid 'drive root repository' @{ Repository = $systemRoot } 'repository_is_drive_root' 'repository')
    $overlapRoots = New-RootsSet -Name 'overlap'
    [void](Test-Invalid 'repository inside the install folder' @{ Repository = (Join-Path $overlapRoots.ProgramFiles 'ResticBackuper\repo') } 'repository_overlaps_install' 'repository' $overlapRoots)
    [void](Test-Invalid 'repository around the state folder' @{ Repository = $overlapRoots.ProgramData } 'repository_overlaps_install' 'repository' $overlapRoots)
    $fileAsRepository = Join-Path $cases 'a-file'
    Write-Text -Path $fileAsRepository -Text 'not a folder'
    [void](Test-Invalid 'repository that is a file' @{ Repository = $fileAsRepository } 'repository_not_a_folder' 'repository')
    $realFolder = Join-Path $cases 'junction-real'
    New-Item -ItemType Directory -Path $realFolder | Out-Null
    $junction = Join-Path $cases 'junction-link'
    New-Junction -Link $junction -Target $realFolder
    [void](Test-Invalid 'repository below a junction' @{ Repository = (Join-Path $junction 'repo') } 'repository_has_reparse_point' 'repository')
    $nonEmpty = Join-Path $cases 'non-empty-repository'
    Write-Text -Path (Join-Path $nonEmpty 'stray.txt') -Text 'someone else''s file'
    [void](Test-Invalid 'repository with unrelated files' @{ Repository = $nonEmpty } 'repository_not_empty' 'repository')
    $toolsParent = Join-Path $cases 'tools-parent'
    Write-Text -Path (Join-Path $toolsParent 'RecoveryTools\unrelated.txt') -Text 'x'
    [void](Test-Invalid 'recovery tools folder with unrelated files' @{ Repository = (Join-Path $toolsParent 'repo') } 'recovery_tools_conflict' 'repository')
    $lowSpace = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1048576')
    Assert-PlanError $lowSpace 'repository_low_space' 'repository' 'a petabyte of free space is required'
    Assert-Equal 1125899906842624 $lowSpace.Plan.resolved.minimum_free_bytes 'minimum_free_bytes follows -MinimumFreeGiB'
    $reuse = Join-Path $cases 'existing-repository'
    Write-Text -Path (Join-Path $reuse 'config') -Text 'a restic repository config'
    $reused = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-Repository', $reuse, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1')
    Assert-True ((Get-WarningCodes $reused.Plan) -contains 'repository_exists') 'an existing repository is a warning, not an error'
    Assert-True ((Get-ErrorCodes $reused.Plan) -notcontains 'repository_not_empty') 'an existing repository is not refused as non-empty'

    # sources
    [void](Test-Invalid 'empty source list' @{ SourceList = ';' } 'sources_required' 'sources')
    [void](Test-Invalid 'relative source' @{ SourceList = "$docs;relative\source" } 'source_not_absolute' 'sources')
    [void](Test-Invalid 'network source' @{ SourceList = "$docs;\\rewindle-no-such-host.invalid\share" } 'source_not_local' 'sources')
    [void](Test-Invalid 'missing source' @{ SourceList = "$docs;" + (Join-Path $cases 'no-such-folder') } 'source_not_found' 'sources')
    [void](Test-Invalid 'duplicate source' @{ SourceList = "$docs;$photos;$docs" } 'source_duplicate' 'sources')
    New-Item -ItemType Directory -Path (Join-Path $docs 'inner') -Force | Out-Null
    [void](Test-Invalid 'nested sources' @{ SourceList = "$docs;" + (Join-Path $docs 'inner') } 'sources_overlap' 'sources')
    [void](Test-Invalid 'source behind a junction' @{ SourceList = "$docs;$junction" } 'source_has_reparse_point' 'sources')
    [void](Test-Invalid 'source that contains the repository' @{ Repository = (Join-Path $docs 'backup'); SourceList = $docs } 'source_overlaps_repository' 'sources')
    $installFolder = Join-Path $overlapRoots.ProgramFiles 'ResticBackuper\data'
    New-Item -ItemType Directory -Path $installFolder -Force | Out-Null
    [void](Test-Invalid 'source inside the install folder' @{ SourceList = "$docs;$installFolder" } 'source_overlaps_install' 'sources' $overlapRoots)
    $twoMissing = "$docs;" + (Join-Path $cases 'missing-one') + ';' + (Join-Path $cases 'missing-two')
    $twoErrors = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', $twoMissing, '-MinimumFreeGiB', '1')
    Assert-Equal 2 @(@($twoErrors.Plan.errors) | Where-Object { $_.code -eq 'source_not_found' }).Count 'every bad source folder is reported, not only the first'
    Assert-True (@(@($twoErrors.Plan.errors) | Where-Object { $_.code -eq 'source_not_found' } | Where-Object { $_.path })[0].path -like '*missing-*') 'a source error names the folder in path'
    Assert-Equal @($docs) @($twoErrors.Plan.resolved.sources) 'resolved.sources lists only the folders that passed'

    # schedule and storage mode
    foreach ($badTime in @('25:00', '02:60', '2:00', 'noon', '02-00')) {
        [void](Test-Invalid "schedule $badTime" @{ Schedule = $badTime } 'schedule_invalid' 'schedule')
    }
    $badSchedule = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1', '-Schedule', '99:99')
    Assert-True ($null -eq $badSchedule.Plan.resolved.schedule) 'an invalid schedule is not echoed as resolved'
    foreach ($goodTime in @('00:00', '09:05', '23:59')) {
        $okRun = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1', '-Schedule', $goodTime)
        Assert-True ((Get-ErrorCodes $okRun.Plan) -notcontains 'schedule_invalid') "schedule $goodTime is accepted"
    }
    [void](Test-Invalid 'DriveFS option without DriveFS mode' @{ DriveFsMyDriveRoot = $roots.DriveFsRoot } 'drivefs_options_without_mode' 'storage_mode')
    $drivefsRepository = Join-Path $roots.DriveFsRoot 'Backups\Repo'
    $driveFsArguments = @{ RepositoryStorageMode = 'google_drivefs_stream'; Repository = $drivefsRepository }
    [void](Test-Invalid 'DriveFS root other than My Drive' ($driveFsArguments + @{ DriveFsMyDriveRoot = (Join-Path $cases 'Other Drive') }) 'drivefs_root_unsupported' 'storage_mode')
    [void](Test-Invalid 'DriveFS cache other than the standard one' ($driveFsArguments + @{ DriveFsCacheDirectory = (Join-Path $cases 'other-cache') }) 'drivefs_cache_unsupported' 'storage_mode')
    [void](Test-Invalid 'DriveFS repository outside My Drive' @{ RepositoryStorageMode = 'google_drivefs_stream'; Repository = $goodRepository } 'repository_not_in_drivefs' 'repository')
    [void](Test-Invalid 'Google Drive not mounted' $driveFsArguments 'drivefs_unavailable' 'storage_mode')
    New-Item -ItemType Directory -Path $roots.DriveFsRoot -Force | Out-Null
    $mounted = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-MinimumFreeGiB', '1', '-RepositoryStorageMode', 'google_drivefs_stream', '-Repository', $drivefsRepository, '-SourceList', "$docs;$photos")
    $mountCodes = Get-ErrorCodes $mounted.Plan
    Assert-True (($mountCodes -contains 'drivefs_not_running') -or ($mountCodes -contains 'drivefs_mount_unsupported')) "an ordinary folder is not the Google Drive streaming mount (got: $($mountCodes -join ', '))"
    Assert-Equal $roots.DriveFsRoot $mounted.Plan.resolved.drivefs_my_drive_root 'resolved.drivefs_my_drive_root is set in DriveFS mode'
    Assert-Equal 'google_drivefs_stream' $mounted.Plan.resolved.storage_mode 'resolved storage mode in DriveFS mode'

    # existing installation, legacy edition, stale recovery key, protected folders
    $installedRoots = New-RootsSet -Name 'installed'
    Write-Text -Path (Join-Path $installedRoots.ProgramFiles 'ResticBackuper\VERSION') -Text '1.2.3-test'
    Write-Text -Path (Join-Path $installedRoots.ProgramFiles 'ResticPersonalBackup\backup-config.json') -Text '{}'
    $installed = Test-Invalid 'Rewindle already installed' @{} 'already_installed' 'environment' $installedRoots
    Assert-Equal '1.2.3-test' $installed.Plan.environment.existing_install.rewindle.version 'existing_install.rewindle.version'
    Assert-Equal (Join-Path $installedRoots.ProgramFiles 'ResticBackuper') $installed.Plan.environment.existing_install.rewindle.install_root 'existing_install.rewindle.install_root'
    Assert-True ($installed.Plan.environment.existing_install.legacy_personal_edition -eq $true) 'the legacy personal edition is detected'
    $shortcutRoots = New-RootsSet -Name 'shortcut'
    Write-Text -Path (Join-Path $shortcutRoots.ProgramData 'Microsoft\Windows\Start Menu\Programs\ResticBackuper.lnk') -Text 'not a real shortcut'
    [void](Test-Invalid 'Start menu item in the way' @{} 'start_menu_shortcut_exists' 'environment' $shortcutRoots)
    $skipDashboardRun = Invoke-Plan -Bundle $bundle -Roots $shortcutRoots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1', '-SkipDashboard')
    Assert-True ((Get-ErrorCodes $skipDashboardRun.Plan) -notcontains 'start_menu_shortcut_exists') 'without the dashboard a Start menu item is no obstacle'
    $keyRoots = New-RootsSet -Name 'stale-key'
    Write-Text -Path (Join-Path $keyRoots.Profile 'ResticBackuper-RecoveryKey.txt') -Text 'stale'
    [void](Test-Invalid 'stale recovery key' @{} 'recovery_key_stale' 'environment' $keyRoots)
    Write-Text -Path (Join-Path $keyRoots.ProgramData 'ResticBackuper\repository-password.dpapi.json') -Text '{}'
    $keyWithSecret = Invoke-Plan -Bundle $bundle -Roots $keyRoots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1')
    Assert-True ((Get-ErrorCodes $keyWithSecret.Plan) -notcontains 'recovery_key_stale') 'a recovery key with its credential is not stale'
    if ($isElevated) {
        # The folder an install leaves belongs to Administrators, and such a folder is used.
        $keyState = Join-Path $keyRoots.ProgramData 'ResticBackuper'
        $keyStateAcl = Get-Acl -LiteralPath $keyState
        $keyStateAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        Set-Acl -LiteralPath $keyState -AclObject $keyStateAcl
        $keyWithSecret = Invoke-Plan -Bundle $bundle -Roots $keyRoots -Temp $temp -Arguments @('-Repository', $goodRepository, '-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1')
        Assert-True ((Get-ErrorCodes $keyWithSecret.Plan) -notcontains 'state_folder_untrusted') 'a state folder Administrators own is trusted'
    }
    else {
        Assert-True ((Get-ErrorCodes $keyWithSecret.Plan) -contains 'state_folder_untrusted') 'a state folder this account made is not trusted, even with a credential file in it'
    }
    $linkRoots = New-RootsSet -Name 'linked-state'
    New-Junction -Link (Join-Path $linkRoots.ProgramData 'ResticBackuper') -Target $realFolder
    [void](Test-Invalid 'state folder that is a junction' @{} 'protected_path_reparse_point' 'environment' $linkRoots)
    # Any account can create a folder in ProgramData. A state folder that Administrators or SYSTEM don't own is refused, and
    # nothing in it is read: not a broken plan file, not one a reinstall would adopt, not a journal the managers would act on.
    foreach ($planted in @(
        @{ Name = 'foreign-state-garbage'; PlanState = 'garbage'; Label = 'a state folder another account made, with a broken plan file' },
        @{ Name = 'foreign-state-plan'; PlanState = '{"schema_version": 1, "plan_id": "0badc0de-0000-4000-8000-000000000000", "config_generation": 41}'; Label = 'a state folder another account made, with a plan to adopt' }
    )) {
        $foreignRoots = New-RootsSet -Name $planted.Name
        $foreignState = Join-Path $foreignRoots.ProgramData 'ResticBackuper'
        Write-Text -Path (Join-Path $foreignState 'plan-state.json') -Text $planted.PlanState
        Write-Text -Path (Join-Path $foreignState 'repository-relocation.journal.json') -Text '{"schema_version": 1}'
        Set-OwnerToCurrentUser $foreignState
        $foreignBefore = Get-TreeSnapshot -Roots @($foreignRoots.Base)
        $foreign = Test-Invalid $planted.Label @{} 'state_folder_untrusted' 'environment' $foreignRoots
        $foreignFinding = @(@($foreign.Plan.errors) | Where-Object { $_.code -ceq 'state_folder_untrusted' })
        Assert-Equal 1 $foreignFinding.Count "$($planted.Label): reported once, although two stages check it"
        Assert-Equal $foreignState $foreignFinding[0].path "$($planted.Label): the finding names the folder"
        Assert-True ($foreignFinding[0].message -like "*$foreignState*") "$($planted.Label): the message names the folder"
        Assert-True ((Get-ErrorCodes $foreign.Plan) -notcontains 'preserved_state_unreadable') "$($planted.Label): the plan file in it was not read"
        Assert-True ($foreignBefore -ceq (Get-TreeSnapshot -Roots @($foreignRoots.Base))) "$($planted.Label): nothing was moved or changed"
    }

    # the payload (the same integrity check as a real install: manifest, sizes, SHA-256 values and no unlisted files)
    $noPayload = New-Bundle -Name 'no-payload' -NoPayload
    [void](Test-Invalid 'no payload' @{} 'payload_missing' 'environment' $roots $noPayload)
    $incomplete = New-Bundle -Name 'incomplete' -OmitFromManifestAndDisk @('restic.exe')
    [void](Test-Invalid 'payload without restic.exe' @{} 'payload_incomplete' 'environment' $roots $incomplete)
    $badVersion = New-Bundle -Name 'bad-version' -Version 'not a version'
    [void](Test-Invalid 'unreadable payload version' @{} 'payload_version_invalid' 'environment' $roots $badVersion)
    $resized = New-Bundle -Name 'resized'
    Add-Content -LiteralPath (Join-Path $resized 'payload\restic.exe') -Value 'one byte too many'
    [void](Test-Invalid 'payload file of the wrong size' @{} 'payload_corrupt' 'environment' $roots $resized)
    $retouched = New-Bundle -Name 'retouched'
    [IO.File]::WriteAllText((Join-Path $retouched 'payload\restic.exe'), 'fixture payload file restic.EXE', $utf8)
    [void](Test-Invalid 'payload file changed without changing its size' @{} 'payload_corrupt' 'environment' $roots $retouched)
    $unlisted = New-Bundle -Name 'unlisted'
    Write-Text -Path (Join-Path $unlisted 'payload\extra-file.txt') -Text 'not in the manifest'
    [void](Test-Invalid 'payload with a file the manifest does not list' @{} 'payload_corrupt' 'environment' $roots $unlisted)
    $missingFile = New-Bundle -Name 'missing-file'
    Remove-Item -LiteralPath (Join-Path $missingFile 'payload\restic.exe') -Force
    [void](Test-Invalid 'payload missing a file the manifest lists' @{} 'payload_corrupt' 'environment' $roots $missingFile)
    $noDashboardBundle = New-Bundle -Name 'no-dashboard' -WithoutDashboard
    $withoutDashboardFlag = Invoke-Plan -Bundle $noDashboardBundle -Roots $roots -Temp $temp -Arguments ($baseArguments + @('-SkipDashboard'))
    Assert-True ($withoutDashboardFlag.Plan.ok -eq $true) "with -SkipDashboard the dashboard files are not required (errors: $((Get-ErrorCodes $withoutDashboardFlag.Plan) -join ', '))"
    $withoutDashboardFiles = Invoke-Plan -Bundle $noDashboardBundle -Roots $roots -Temp $temp -Arguments $baseArguments
    Assert-True ((Get-ErrorCodes $withoutDashboardFiles.Plan) -contains 'payload_incomplete') 'without -SkipDashboard the dashboard files are required'

    # a plan collects problems from several fields at once
    $several = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments @('-Repository', 'relative', '-SourceList', ';', '-Schedule', '77:77', '-MinimumFreeGiB', '1')
    foreach ($code in @('repository_not_absolute', 'sources_required', 'schedule_invalid')) {
        Assert-True ((Get-ErrorCodes $several.Plan) -contains $code) "several problems are reported together ($code)"
    }

    # ====================================================================================================================
    # 3. The output path is guarded
    # ====================================================================================================================
    $tempBefore = Get-TreeSnapshot -Roots @($temp)
    $outside = Join-Path $workspace 'outside-temp'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $refusals = @(
        @{ Label = 'a path outside the temporary folder'; Path = (Join-Path $outside 'plan.json'); Message = 'temporary folder' },
        @{ Label = 'a relative path'; Path = 'plan.json'; Message = 'absolute' },
        @{ Label = 'a network path'; Path = '\\rewindle-no-such-host.invalid\share\plan.json'; Message = 'absolute' },
        @{ Label = 'the wrong extension'; Path = (Join-Path $temp 'plan.txt'); Message = '.json' },
        @{ Label = 'a folder that does not exist'; Path = (Join-Path $temp 'missing-folder\plan.json'); Message = 'does not exist' }
    )
    foreach ($refusal in $refusals) {
        $refused = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments -PlanPath $refusal.Path
        Assert-True ($refused.ExitCode -ne 0) "$($refusal.Label) is refused (exit $($refused.ExitCode))"
        Assert-True ($refused.Error -match 'No plan was written') "$($refusal.Label): the refusal is explained on stderr"
        Assert-True ($refused.Error -match [regex]::Escape($refusal.Message)) "$($refusal.Label): the explanation mentions '$($refusal.Message)' (got: $($refused.Error.Trim()))"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $outside 'plan.json'))) 'nothing was written outside the temporary folder'
    # The short (8.3) spelling of the temporary folder names the same folder (when the volume has short names at all).
    $shortTemp = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($temp).ShortPath
    $viaShortName = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments -PlanPath (Join-Path $shortTemp 'plan-by-short-name.json')
    Assert-Equal 0 $viaShortName.ExitCode "a plan path spelled with the short name of the temporary folder is accepted ($shortTemp; stderr: $($viaShortName.Error))"
    Assert-True (Test-Path -LiteralPath (Join-Path $temp 'plan-by-short-name.json') -PathType Leaf) 'the plan was written into the temporary folder'
    $junctionTarget = Join-Path $temp 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    $junctionInTemp = Join-Path $temp 'junction-in-temp'
    New-Junction -Link $junctionInTemp -Target $junctionTarget
    $viaJunction = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments -PlanPath (Join-Path $junctionInTemp 'plan.json')
    Assert-True ($viaJunction.ExitCode -ne 0 -and $viaJunction.Error -match 'reparse point') 'a path through a junction is refused'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $junctionTarget 'plan.json'))) 'nothing was written through the junction'
    $viaFileJunction = Join-Path $temp 'plan-existing-dir.json'
    New-Item -ItemType Directory -Path $viaFileJunction | Out-Null
    $overDirectory = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments -PlanPath $viaFileJunction
    Assert-True ($overDirectory.ExitCode -ne 0) 'an existing folder at the output path is refused'
    $withoutOutput = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments $baseArguments -NoPlanOutputArgument
    Assert-True ($withoutOutput.ExitCode -ne 0 -and $withoutOutput.Error -match 'PlanOutput') '-PlanOnly without -PlanOutput is refused'
    $withProgress = Invoke-Plan -Bundle $bundle -Roots $roots -Temp $temp -Arguments ($baseArguments + @('-ProgressPath', (Join-Path $temp 'p.jsonl')))
    Assert-True ($withProgress.ExitCode -ne 0 -and $withProgress.Error -match 'ProgressPath') '-PlanOnly cannot be combined with -ProgressPath'
    Remove-Junction $junctionInTemp
    Remove-Item -LiteralPath $viaFileJunction -Force
    Remove-Item -LiteralPath $junctionTarget -Recurse -Force
    $leftovers = @(Get-ChildItem -LiteralPath $temp -Force | Where-Object { $_.Name -notlike 'plan-*.json' })
    Assert-Equal @() @($leftovers | ForEach-Object Name) 'refused runs left nothing but earlier plan files in the temporary folder'

    # ====================================================================================================================
    # 4. Volume eligibility and the recommendation, with synthetic volumes
    # ====================================================================================================================
    function New-SyntheticVolume {
        param([string]$Root, [string]$Type = 'fixed', [string]$FileSystem = 'NTFS', [long]$FreeGiB = 100, $SamePhysical = $false, [bool]$Ready = $true)
        $volume = [pscustomobject][ordered]@{
            root = $Root; label = ''; filesystem = $FileSystem; drive_type = $Type; size_bytes = [long]1TB
            free_bytes = [long]$FreeGiB * 1GB; is_system = ($Root -eq 'C:\'); same_physical_disk_as_system = $SamePhysical; ready = $Ready
        }
        $eligibility = Get-VolumeEligibility -Volume $volume -MinimumFreeBytes 10GB
        $volume | Add-Member -NotePropertyName eligible -NotePropertyValue $eligibility.eligible
        $volume | Add-Member -NotePropertyName reason -NotePropertyValue $eligibility.reason
        return $volume
    }
    $ten = [long]10GB
    Assert-True (Get-VolumeEligibility (New-SyntheticVolume 'D:\') $ten).eligible 'an NTFS fixed drive with space is eligible'
    foreach ($expectation in @(
        @{ Type = 'network'; Reason = 'network_drive' }, @{ Type = 'cdrom'; Reason = 'optical_drive' },
        @{ Type = 'ram'; Reason = 'ram_disk' }, @{ Type = 'unknown'; Reason = 'unknown_drive_type' }
    )) {
        $verdict = Get-VolumeEligibility (New-SyntheticVolume 'Z:\' -Type $expectation.Type) $ten
        Assert-Equal @($false, $expectation.Reason) @($verdict.eligible, $verdict.reason) "a $($expectation.Type) drive is ineligible ($($expectation.Reason))"
        Assert-True (-not [string]::IsNullOrWhiteSpace($verdict.message)) "a $($expectation.Type) drive has a plain explanation"
    }
    Assert-Equal 'not_ready' (Get-VolumeEligibility (New-SyntheticVolume 'R:\' -FileSystem '' -Ready $false) $ten).reason 'a drive that is not ready is ineligible'
    foreach ($fileSystem in @('FAT32', 'exFAT', 'ReFS')) {
        Assert-Equal 'not_ntfs' (Get-VolumeEligibility (New-SyntheticVolume 'E:\' -FileSystem $fileSystem) $ten).reason "$fileSystem is not NTFS"
    }
    Assert-True (Get-VolumeEligibility (New-SyntheticVolume 'E:\' -FileSystem 'ntfs') $ten).eligible 'the file system name is compared without regard to case'
    Assert-Equal 'low_free_space' (Get-VolumeEligibility (New-SyntheticVolume 'E:\' -FreeGiB 9) $ten).reason 'a drive with less than the minimum free is ineligible'
    Assert-True (Get-VolumeEligibility (New-SyntheticVolume 'E:\' -FreeGiB 10) $ten).eligible 'a drive with exactly the minimum free is eligible'
    Assert-True (Get-VolumeEligibility (New-SyntheticVolume 'F:\' -Type 'removable') $ten).eligible 'a removable NTFS drive is eligible'

    $system = New-SyntheticVolume 'C:\' -SamePhysical $true -FreeGiB 500
    $other = New-SyntheticVolume 'D:\' -FreeGiB 200
    $bigger = New-SyntheticVolume 'E:\' -FreeGiB 800
    $partition = New-SyntheticVolume 'F:\' -FreeGiB 900 -SamePhysical $true
    $unknown = New-SyntheticVolume 'G:\' -FreeGiB 950 -SamePhysical $null
    $fat = New-SyntheticVolume 'H:\' -FreeGiB 990 -FileSystem 'FAT32'
    $network = New-SyntheticVolume 'Z:\' -Type 'network' -FreeGiB 999
    $small = New-SyntheticVolume 'I:\' -FreeGiB 3
    Assert-Equal 'D:\' (Select-RecommendedVolume -Volumes @($system, $other)) 'the only other physical disk is recommended'
    Assert-Equal 'E:\' (Select-RecommendedVolume -Volumes @($system, $other, $bigger)) 'the volume with the most free space wins'
    Assert-Equal 'E:\' (Select-RecommendedVolume -Volumes @($bigger, $system, $other)) 'the order of the list does not matter'
    Assert-Equal 'E:\' (Select-RecommendedVolume -Volumes @($system, $other, $bigger, $partition, $unknown, $fat, $network, $small)) 'partitions of the system disk, unknown disks, non-NTFS, network and ineligible volumes are never recommended'
    Assert-True ($null -eq (Select-RecommendedVolume -Volumes @($system))) 'with only the system volume nothing is recommended'
    Assert-True ($null -eq (Select-RecommendedVolume -Volumes @($system, $partition))) 'a second partition of the system disk is not recommended'
    Assert-True ($null -eq (Select-RecommendedVolume -Volumes @($system, $unknown))) 'a volume whose disk is unknown is not recommended'
    Assert-True ($null -eq (Select-RecommendedVolume -Volumes @($system, $fat, $network, $small))) 'ineligible volumes are not recommended'
    Assert-True ($null -eq (Select-RecommendedVolume -Volumes @())) 'with no volumes nothing is recommended'
    Assert-Equal 'D:\' (Select-RecommendedVolume -Volumes @((New-SyntheticVolume 'E:\' -FreeGiB 100), (New-SyntheticVolume 'D:\' -FreeGiB 100))) 'equal free space goes to the lower drive letter'
    Assert-Equal 'F:\' (Select-RecommendedVolume -Volumes @($system, (New-SyntheticVolume 'F:\' -Type 'removable' -FreeGiB 300), $other)) 'a removable NTFS drive on another disk can be recommended'

    # ====================================================================================================================
    # 5. Findings raised by the shared checks
    # ====================================================================================================================
    Assert-Equal 'repository_not_ntfs' (Get-FindingCode { Assert-LocalNtfsVolume -Volume ([pscustomobject]@{ root = 'E:\'; filesystem = 'exFAT' }) }) 'a non-NTFS repository volume'
    Assert-Equal 'no-finding' (Get-FindingCode { Assert-LocalNtfsVolume -Volume ([pscustomobject]@{ root = 'E:\'; filesystem = 'NTFS' }) }) 'an NTFS repository volume passes'
    Assert-Equal 'repository_low_space' (Get-FindingCode { Assert-VolumeFreeSpace -Volume ([pscustomobject]@{ root = 'E:\'; free_bytes = 5GB }) -MinimumFreeGiB 10 }) 'too little free space'
    Assert-Equal 'no-finding' (Get-FindingCode { Assert-VolumeFreeSpace -Volume ([pscustomobject]@{ root = 'E:\'; free_bytes = 10GB }) -MinimumFreeGiB 10 }) 'exactly enough free space passes'
    Assert-Equal 'source_drive_unavailable' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $false -DriveType 'Fixed' -DriveFormat '' -UseVss $true }) 'a source on a drive that is not ready'
    Assert-Equal 'source_drive_unavailable' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $true -DriveType 'Network' -DriveFormat 'NTFS' -UseVss $false }) 'a source on a network drive'
    Assert-Equal 'source_drive_unavailable' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $true -DriveType 'CDRom' -DriveFormat 'CDFS' -UseVss $false }) 'a source on an optical drive'
    Assert-Equal 'source_vss_unsupported' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $true -DriveType 'Removable' -DriveFormat 'NTFS' -UseVss $true }) 'a removable source with VSS on'
    Assert-Equal 'source_vss_unsupported' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $true -DriveType 'Fixed' -DriveFormat 'exFAT' -UseVss $true }) 'a non-NTFS source with VSS on'
    Assert-Equal 'no-finding' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $true -DriveType 'Removable' -DriveFormat 'exFAT' -UseVss $false }) 'a removable exFAT source is fine with VSS off'
    Assert-Equal 'no-finding' (Get-FindingCode { Assert-SourceDriveProperties -Directory 'X:\a' -Ready $true -DriveType 'Fixed' -DriveFormat 'NTFS' -UseVss $true }) 'a fixed NTFS source is fine with VSS on'
    function New-Mount {
        param([int]$Type = [int][IO.DriveType]::Fixed, [string]$FileSystem = 'FAT32', [long]$Flags = 0x100, [long]$Component = 255)
        return [pscustomobject]@{ drive_type = $Type; filesystem = $FileSystem; filesystem_flags = $Flags; maximum_component_length = $Component }
    }
    Assert-True (Test-DriveFsMount -Volume (New-Mount)) 'the Google Drive streaming mount is recognized'
    Assert-True (-not (Test-DriveFsMount -Volume (New-Mount -Type ([int][IO.DriveType]::Removable)))) 'a removable drive is not the Google Drive mount'
    Assert-True (-not (Test-DriveFsMount -Volume (New-Mount -FileSystem 'NTFS'))) 'an NTFS drive is not the Google Drive mount'
    Assert-True (-not (Test-DriveFsMount -Volume (New-Mount -Flags 0))) 'a drive without the expected file system flag is not the Google Drive mount'
    Assert-True (-not (Test-DriveFsMount -Volume (New-Mount -Component 63))) 'a drive with short file names is not the Google Drive mount'
    $finding = New-InstallFinding -Code 'x_test' -Field 'repository' -Message 'Friendly.' -Console 'Console.' -Path 'C:\p'
    Assert-Equal 'Console.' $(try { Stop-InstallFinding -Finding $finding } catch { $_.Exception.Message }) 'a finding throws its console text so the console path prints what it always printed'
    Assert-Equal 'Friendly.' $(try { Stop-InstallFinding -Finding $finding } catch { (Get-InstallFinding -ErrorRecord $_).message }) 'the same exception carries the friendly message'
    Assert-True ($null -eq $(try { throw 'plain' } catch { Get-InstallFinding -ErrorRecord $_ })) 'a plain exception is not a finding'

    # ====================================================================================================================
    # 6. Can the account read a file? (the recovery key finding)
    # ====================================================================================================================
    $user = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
    function New-Descriptor { param([string]$Aces) return [Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BA' + $Aces) }
    Assert-True (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor "D:P(A;;FA;;;$user)(A;;FA;;;SY)(A;;FA;;;BA)") -Sids @($user)) 'the key the engine writes (full control for the user, SYSTEM and Administrators) is readable by the user'
    Assert-True (-not (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor 'D:P(A;;FA;;;SY)(A;;FA;;;BA)') -Sids @($user))) 'a key only SYSTEM and Administrators can open is not readable by the user'
    Assert-True (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor 'D:P(A;;FA;;;SY)(A;;FA;;;BA)') -Sids @($user, 'S-1-5-32-544')) 'the same key is readable while the account holds Administrators'
    Assert-True (-not (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor "D:P(D;;FR;;;$user)(A;;FA;;;$user)") -Sids @($user))) 'an explicit deny for the user wins over a later allow'
    Assert-True (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor "D:P(A;;FR;;;$user)(D;;FR;;;$user)") -Sids @($user)) 'an allow before a deny is honored in ACL order'
    Assert-True (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor 'D:P(A;;GR;;;BU)') -Sids @($user, 'S-1-5-32-545')) 'generic read granted to the Users group is readable by a member'
    Assert-True (-not (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor 'D:P(A;;GR;;;BU)') -Sids @($user))) 'generic read granted to a group the account is not in does not help'
    Assert-True (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor 'D:P(A;;GA;;;WD)') -Sids @($user, 'S-1-1-0')) 'generic all granted to Everyone is readable'
    Assert-True (-not (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor "D:P(A;;FW;;;$user)") -Sids @($user))) 'write access alone does not allow reading'
    Assert-True (-not (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor "D:P(A;OICIIO;FA;;;$user)") -Sids @($user))) 'an inherit-only entry does not apply to the object itself'
    Assert-True (-not (Test-DescriptorGrantsAccess -Descriptor (New-Descriptor 'D:P') -Sids @($user))) 'an empty DACL grants nothing'
    $nullDacl = [Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BA')
    Assert-True (Test-DescriptorGrantsAccess -Descriptor $nullDacl -Sids @($user)) 'a missing DACL grants everyone access'
    # And against a real file: a file that only this user and SYSTEM may open.
    $keyFile = Join-Path $workspace 'key-fixture.txt'
    Write-Text -Path $keyFile -Text 'fixture'
    $fileAcl = Get-Acl -LiteralPath $keyFile
    $fileAcl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($fileAcl.Access)) { [void]$fileAcl.RemoveAccessRule($rule) }
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($currentSid), 'FullControl', 'Allow'))
    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-18'), 'FullControl', 'Allow'))
    Set-Acl -LiteralPath $keyFile -AclObject $fileAcl
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @('Get-UnelevatedTokenSids', 'Test-FileReadableByUser'))))
    Assert-True ((Test-FileReadableByUser -Path $keyFile -Sids @($currentSid)) -eq $true) 'a real file with the engine key ACL is readable by its user'
    Assert-True ((Test-FileReadableByUser -Path $keyFile -Sids @('S-1-5-32-545')) -eq $false) 'the same file is not readable by an account that only holds the Users group'
    Assert-True ((Test-FileReadableByUser -Path (Join-Path $workspace 'no-such-file.txt')) -eq $false) 'a missing file is not readable'
    $tokenSids = @(Get-UnelevatedTokenSids)
    Assert-True ($tokenSids -contains $currentSid) 'the unelevated SID list holds the account itself'
    Assert-True ((Test-FileReadableByUser -Path $keyFile) -eq $true) 'with the real token the account reads its own key'

    # ====================================================================================================================
    # 7. Who signed a Windows tool or the WebView2 installer
    # ====================================================================================================================
    $root2010 = '3B1EFD3A66EA28B16697394703A72CA340A05BD5'
    $root2011 = '8F43288AD272F3103B6FB1428485EA3014C0BCFE'
    $identityRoot2020 = 'F40042E2E5F7E8EF8189FED15519AECE42C3BFA2'
    $publicRoot = 'DF3C24F9BFD666761B268073FE06D1CC8D4F82A4'
    $leafThumbprint = '1111111111111111111111111111111111111111'
    $intermediateThumbprint = '2222222222222222222222222222222222222222'
    $microsoftSubject = "C=US`r`nS=Washington`r`nL=Redmond`r`nO=Microsoft Corporation`r`nCN=Microsoft Corporation"
    $windowsSubject = "C=US`r`nS=Washington`r`nL=Redmond`r`nO=Microsoft Corporation`r`nCN=Microsoft Windows"
    function Test-Signer {
        param([string]$Status = 'Valid', [string]$Subject = $microsoftSubject, [string[]]$Chain = @($leafThumbprint, $intermediateThumbprint, $root2011), [bool]$ChainValid = $true, [bool]$OSBinary = $false)
        return Get-MicrosoftSignerProblem -Status $Status -Subject $Subject -ChainThumbprints $Chain -ChainValid $ChainValid -IsOSBinary $OSBinary
    }
    Assert-True ($null -eq (Test-Signer)) 'Microsoft Corporation through Microsoft Root Certificate Authority 2011 passes'
    Assert-True ($null -eq (Test-Signer -Subject $windowsSubject -Chain @($leafThumbprint, $intermediateThumbprint, $root2010))) 'Microsoft Windows (O=Microsoft Corporation) through Microsoft Root Certificate Authority 2010 passes'
    Assert-True ($null -eq (Test-Signer -Subject "O=Microsoft Corporation`nCN=Microsoft Corporation" -Chain @($leafThumbprint, $intermediateThumbprint, '8f43 288a d272 f310 3b6f b142 8485 ea30 14c0 bcfe'))) 'line feeds alone, and a thumbprint with spaces in lower case, read the same'
    Assert-True ($null -eq (Test-Signer -Subject $windowsSubject -Chain @() -ChainValid $false -OSBinary $true)) 'a file Windows reports as its own passes without its chain'
    foreach ($refused in @(
        @{ Label = 'an organization that merely contains Microsoft'; Subject = "C=US`r`nO=Contoso Microsoftware Ltd`r`nCN=Contoso Microsoftware Ltd" },
        @{ Label = 'Microsoft Corporation in the common name only'; Subject = "C=US`r`nO=Contoso Ltd`r`nCN=Microsoft Corporation" },
        @{ Label = 'an organization that starts with Microsoft Corporation'; Subject = "O=Microsoft Corporation Fan Club`r`nCN=x" },
        @{ Label = 'a quoted organization with Microsoft Corporation in it'; Subject = "O=`"Microsoft Corporation, Evil`"`r`nCN=x" },
        @{ Label = 'two organizations'; Subject = "O=Microsoft Corporation`r`nO=Contoso Ltd`r`nCN=x" },
        @{ Label = 'a second organization in a multi-valued part'; Subject = "O=Contoso Ltd`r`nCN=x + O=Microsoft Corporation" },
        @{ Label = 'the name in another case'; Subject = "o=microsoft corporation`r`nCN=x" },
        @{ Label = 'a value with line breaks that would look like an organization'; Subject = "CN=`"x`r`nO=Microsoft Corporation`r`ny`"" },
        @{ Label = 'no organization'; Subject = "C=US`r`nCN=Microsoft Corporation" },
        @{ Label = 'an empty subject'; Subject = '' }
    )) {
        $problem = Test-Signer -Subject $refused.Subject
        Assert-True (-not [string]::IsNullOrEmpty($problem)) "refused: $($refused.Label)"
        $problem = Test-Signer -Subject $refused.Subject -OSBinary $true
        Assert-True (-not [string]::IsNullOrEmpty($problem)) "refused even for a file Windows reports as its own: $($refused.Label)"
    }
    foreach ($refused in @(
        @{ Label = "Microsoft's root for other publishers"; Chain = @($leafThumbprint, $intermediateThumbprint, $identityRoot2020); Valid = $true },
        @{ Label = "a public certificate authority's root"; Chain = @($leafThumbprint, $intermediateThumbprint, $publicRoot); Valid = $true },
        @{ Label = 'a one-certificate chain'; Chain = @($root2011); Valid = $true },
        @{ Label = 'no chain'; Chain = @(); Valid = $true },
        @{ Label = 'a chain that did not validate'; Chain = @($leafThumbprint, $intermediateThumbprint, $root2011); Valid = $false },
        @{ Label = 'a Microsoft root that is not the last element'; Chain = @($leafThumbprint, $root2011, $intermediateThumbprint); Valid = $true }
    )) {
        $problem = Test-Signer -Chain $refused.Chain -ChainValid $refused.Valid
        Assert-True (-not [string]::IsNullOrEmpty($problem)) "refused: $($refused.Label)"
    }
    foreach ($status in @('NotSigned', 'HashMismatch', 'NotTrusted', 'UnknownError', 'valid', '')) {
        Assert-True (-not [string]::IsNullOrEmpty((Test-Signer -Status $status -OSBinary $true))) "refused: a signature whose status is '$status'"
    }

    # The check itself, with Windows' answer about the file replaced by a certificate made here and never stored.
    $signedFixture = Join-Path $workspace 'signed-fixture.exe'
    Write-Text -Path $signedFixture -Text 'not really a program'
    function New-FixtureSignature {
        param([string]$Subject, [bool]$OSBinary = $false)
        $key = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($Subject, $key, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
        return [pscustomobject]@{ Status = 'Valid'; SignatureType = 'Authenticode'; SignerCertificate = $certificate; IsOSBinary = $OSBinary }
    }
    foreach ($case in @(
        @{ Subject = 'CN=Microsoft Corporation, O=Contoso Microsoft Fans Ltd, C=US'; OSBinary = $false; Code = 'system_tool_untrusted'; Label = 'a valid signature by a publisher with Microsoft in its name' },
        @{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'; OSBinary = $false; Code = 'system_tool_untrusted'; Label = "a valid signature named Microsoft Corporation that doesn't lead to Microsoft's root" },
        @{ Subject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US'; OSBinary = $true; Code = 'no-finding'; Label = 'a file Windows reports as its own' }
    )) {
        $fixtureSignature = New-FixtureSignature -Subject $case.Subject -OSBinary $case.OSBinary
        $code = & {
            function Get-AuthenticodeSignature { param([string]$LiteralPath) return $fixtureSignature }
            Get-FindingCode { Assert-MicrosoftSignedExecutable -Path $signedFixture }
        }
        Assert-Equal $case.Code $code "the signer check: $($case.Label)"
    }
    $webViewCode = & {
        function Get-AuthenticodeSignature { param([string]$LiteralPath) return (New-FixtureSignature -Subject 'CN=Microsoft Corporation, O=Contoso Microsoft Fans Ltd, C=US') }
        Get-FindingCode { Assert-MicrosoftSignedExecutable -Path $signedFixture -Code 'webview2_installer_untrusted' }
    }
    Assert-Equal 'webview2_installer_untrusted' $webViewCode 'a WebView2 installer with the wrong signer is refused with its own code'
    Assert-Equal 'system_tool_untrusted' (Get-FindingCode { Assert-MicrosoftSignedExecutable -Path $signedFixture }) 'an unsigned file is refused'
    Assert-Equal 'system_tool_missing' (Get-FindingCode { Assert-MicrosoftSignedExecutable -Path (Join-Path $workspace 'no-such-tool.exe') }) 'a missing file is reported as missing'
    # And Microsoft's real signatures pass: a .NET Framework file (Windows signs it through a catalog), and when the build has
    # unpacked it, the pinned WebView2 SDK's loader, which carries its own Microsoft signature as the WebView2 installer does.
    $frameworkCompiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Assert-Equal 'no-finding' (Get-FindingCode { Assert-MicrosoftSignedExecutable -Path $frameworkCompiler }) 'the .NET Framework compiler passes'
    foreach ($loader in @(Get-ChildItem -Path (Join-Path $projectRoot 'src\dashboard\.packages\webview2.*\runtimes\win-x64\native\WebView2Loader.dll') -ErrorAction SilentlyContinue)) {
        $loaderFacts = Get-AuthenticodeSignerFacts -Path $loader.FullName
        Assert-True ($loaderFacts.status -eq 'Valid' -and -not $loaderFacts.os_binary -and $loaderFacts.chain_valid) "the WebView2 SDK's loader has a valid signature of its own and a chain ($($loader.FullName))"
        Assert-True (@($root2010, $root2011) -contains @($loaderFacts.chain)[-1]) "the WebView2 SDK's loader leads to one of Microsoft's roots (got $(@($loaderFacts.chain) -join ' > '))"
        Assert-Equal 'no-finding' (Get-FindingCode { Assert-MicrosoftSignedExecutable -Path $loader.FullName }) "the WebView2 SDK's loader passes"
        # Invoke-HeldExecutable runs this check while it holds the downloaded file open with only reading shared, and the
        # check opens the file again to read the certificates it carries. It still passes under that hold.
        $loaderHold = [IO.File]::Open($loader.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $heldLoaderFacts = Get-AuthenticodeSignerFacts -Path $loader.FullName
            Assert-True ($heldLoaderFacts.status -eq 'Valid' -and $heldLoaderFacts.chain_valid -and (@($root2010, $root2011) -contains @($heldLoaderFacts.chain)[-1])) "while held as a download is held, the loader's signature and chain read the same (got $(@($heldLoaderFacts.chain) -join ' > '))"
            Assert-Equal 'no-finding' (Get-FindingCode { Assert-MicrosoftSignedExecutable -Path $loader.FullName }) "the WebView2 SDK's loader passes while it is held as a download is held"
        }
        finally {
            $loaderHold.Dispose()
        }
    }

    # ====================================================================================================================
    # 8. Who owns the state folder
    # ====================================================================================================================
    foreach ($trusted in @('S-1-5-32-544', 'S-1-5-18')) {
        Assert-True (Test-TrustedStateOwner -OwnerSid $trusted) "$trusted may own the state folder"
    }
    foreach ($untrusted in @($currentSid, 'S-1-5-32-545', 'S-1-1-0', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', 's-1-5-32-544', '', $null)) {
        Assert-True (-not (Test-TrustedStateOwner -OwnerSid $untrusted)) "'$untrusted' may not own the state folder"
    }
    $ownedState = Join-Path $workspace 'owner-fixture\ResticBackuper'
    New-Item -ItemType Directory -Path $ownedState -Force | Out-Null
    Set-OwnerToCurrentUser $ownedState
    # Assert-StateFolderOwner reads $stateRoot and $PlanOnly and asks Get-FeedOwnerSid for the owner. Each is defined in a scope
    # of its own here (a function statement, which never replaces the one outside), so the real Get-FeedOwnerSid stays in place
    # for the progress feed checks below. The stub's answer has a name of its own: Assert-StateFolderOwner has an $owner.
    function Get-StateOwnerCode {
        param([string]$Folder, [scriptblock]$Owner, [bool]$PlanMode = $false)
        return & {
            $stateRoot = $Folder
            $PlanOnly = $PlanMode
            $stateOwnerAnswer = $Owner
            if ($stateOwnerAnswer) {
                function Get-FeedOwnerSid { param([string]$Path) return (& $stateOwnerAnswer) }
            }
            Get-FindingCode { Assert-StateFolderOwner }
        }
    }
    Assert-Equal 'no-finding' (Get-StateOwnerCode -Folder $ownedState -Owner { 'S-1-5-32-544' }) 'a state folder Administrators own passes'
    Assert-Equal 'no-finding' (Get-StateOwnerCode -Folder $ownedState -Owner { 'S-1-5-18' }) 'a state folder SYSTEM owns passes'
    Assert-Equal 'state_folder_untrusted' (Get-StateOwnerCode -Folder $ownedState -Owner { 'S-1-5-32-545' }) 'a state folder the Users group owns is refused'
    Assert-Equal 'state_folder_untrusted' (Get-StateOwnerCode -Folder $ownedState) 'a real state folder this account owns is refused'
    Assert-Equal 'state_folder_untrusted' (Get-StateOwnerCode -Folder $ownedState -PlanMode $true) 'and so it is in plan mode'
    $denied = { throw [UnauthorizedAccessException]::new('Access is denied.') }
    Assert-Equal 'state_folder_untrusted' (Get-StateOwnerCode -Folder $ownedState -Owner $denied) 'an install treats an owner it cannot read as untrusted'
    Assert-Equal 'no-finding' (Get-StateOwnerCode -Folder $ownedState -Owner $denied -PlanMode $true) 'plan mode leaves an owner it cannot read to the install'
    Assert-Equal 'no-finding' (Get-StateOwnerCode -Folder (Join-Path $workspace 'owner-fixture\Missing')) 'no state folder, nothing to check'
    # The folder the canary phase creates: owned by Administrators, with a protected list that lets only them and SYSTEM change it.
    $protectedSecurity = New-ProtectedDirectorySecurity -UserSid $currentSid
    Assert-Equal 'S-1-5-32-544' $protectedSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value 'a new state folder is owned by Administrators'
    Assert-True $protectedSecurity.AreAccessRulesProtected 'a new state folder inherits nothing from ProgramData'
    $protectedRules = @($protectedSecurity.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
        '{0}={1}/{2}/{3}' -f $_.IdentityReference.Value, $_.AccessControlType, $_.FileSystemRights, $_.InheritanceFlags
    } | Sort-Object)
    $expectedRules = @(@('S-1-5-18=Allow/FullControl', 'S-1-5-32-544=Allow/FullControl', "$currentSid=Allow/ReadAndExecute, Synchronize", 'S-1-3-4=Allow/ReadAndExecute, Synchronize') |
        ForEach-Object { $_ + '/ContainerInherit, ObjectInherit' } | Sort-Object)
    Assert-Equal $expectedRules $protectedRules 'only Administrators and SYSTEM may change a new state folder, and what it holds inherits that'

    # ====================================================================================================================
    # 9. The progress feed writer
    # ====================================================================================================================
    $feedBase = Join-Path $workspace 'feed'
    $feedDirectory = Join-Path $feedBase 'RewindleSetup-feed-test'
    New-Item -ItemType Directory -Path $feedDirectory -Force | Out-Null
    foreach ($owned in @($workspace, (Split-Path -Parent $workspace), $feedBase, $feedDirectory)) {
        if ($owned.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) { Set-OwnerToCurrentUser $owned }
    }
    $feedPath = Join-Path $feedDirectory 'progress.jsonl'
    Open-ProgressFeed -Path $feedPath -ExpectedSid $currentSid
    Assert-True ($null -ne $script:FeedStream) 'the feed opens for a folder the expected user owns inside the temporary folder'
    Assert-True (Test-Path -LiteralPath $feedPath -PathType Leaf) 'the feed file exists as soon as it is opened'
    $reader = [IO.FileStream]::new($feedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        function Read-FeedText { $reader.Position = 0; return [IO.StreamReader]::new($reader, $utf8, $false, 1024, $true).ReadToEnd() }
        Assert-Equal '' (Read-FeedText) 'nothing is written before the first phase'
        Write-FeedPhase -Phase 'preflight' -State 'started' -Title 'Checking your PC'
        $text = Read-FeedText
        Assert-True ($text.EndsWith("`n")) 'every line is flushed and ends with a line feed as soon as it is written'
        $first = $text.TrimEnd("`n") | ConvertFrom-Json
        Assert-Equal @('schema', 'seq', 'time', 'type', 'phase', 'state', 'title', 'detail') @($first.PSObject.Properties.Name) 'a phase line has the documented properties in order'
        Assert-Equal 'Rewindle.InstallProgress.v1' $first.schema 'phase line schema'
        Assert-Equal 1 $first.seq 'the first line is sequence 1'
        Assert-True ($first.time -cmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$') 'time is ISO-8601 UTC'
        Assert-Equal @('phase', 'preflight', 'started', 'Checking your PC') @($first.type, $first.phase, $first.state, $first.title) 'phase line values'
        Assert-True ($null -eq $first.detail) 'an absent detail is null'
        Assert-Equal 'preflight' $script:FeedCurrentPhase 'the current phase is tracked'
        Write-FeedPhase -Phase 'preflight' -State 'completed' -Title 'Checking your PC' -Detail "All good, with a quote ' and a newline`nin it"
        Assert-True ($null -eq $script:FeedCurrentPhase) 'completing the phase clears it'
        Write-FeedPhase -Phase 'webview2' -State 'skipped' -Title 'WebView2' -Detail 'Not requested.'
        Write-FeedResult -Ok $true -ErrorInfo $null -Fields ([ordered]@{ install_root = 'C:\Program Files\ResticBackuper'; recovery_key_path = 'C:\k.txt'; recovery_key_readable_by_user = $true; dashboard_executable = $null; version = '1.0.0' })
        Write-FeedResult -Ok $false -ErrorInfo ([ordered]@{ code = 'x'; message = 'y' })
        Write-FeedPhase -Phase 'late' -State 'started' -Title 'After the result'
        $lines = @((Read-FeedText).TrimEnd("`n") -split "`n")
        Assert-True ($lines.Count -ge 5) 'all lines arrived'
        $parsed = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal @(1, 2, 3, 4, 5) @($parsed | Select-Object -First 5 | ForEach-Object seq) 'sequence numbers count up by one'
        $result = $parsed[3]
        Assert-Equal @('schema', 'seq', 'time', 'type', 'ok', 'error', 'install_root', 'recovery_key_path', 'recovery_key_readable_by_user', 'dashboard_executable', 'version') @($result.PSObject.Properties.Name) 'the result line carries the documented properties'
        Assert-Equal 'result' $result.type 'the result line type'
        Assert-True ($result.ok -eq $true -and $null -eq $result.error) 'a successful result has ok true and a null error'
        Assert-True ($parsed[2].detail -eq 'Not requested.') 'a skipped phase carries its explanation'
        Assert-True ($parsed[1].detail -like "*quote '*newline*") 'special characters survive a round trip on one line'
        Assert-True ($lines[1] -notmatch "[\r\n]") 'a detail with a newline stays on one line'
        Assert-True (@($lines | Where-Object { ($_ | ConvertFrom-Json).type -eq 'result' }).Count -eq 1) 'only one result line is ever written'
    }
    finally { $reader.Dispose() }
    Close-ProgressFeed
    Assert-True ($null -eq $script:FeedStream) 'closing the feed releases it'
    Write-FeedPhase -Phase 'after-close' -State 'started' -Title 'Ignored'
    Assert-True (@([IO.File]::ReadAllLines($feedPath)).Count -ge 5) 'writes after closing are ignored without an error'
    $bytes = [IO.File]::ReadAllBytes($feedPath)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'the feed has no byte-order mark'
    $feedAcl = Get-Acl -LiteralPath $feedPath
    Assert-True (@($feedAcl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $currentSid -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData) }).Count -ge 1) 'the expected user can read the feed'

    # a failing result: the failed phase and the error
    $script:FeedResultWritten = $false
    $failedPath = Join-Path $feedDirectory 'failed.jsonl'
    Open-ProgressFeed -Path $failedPath -ExpectedSid $currentSid
    Write-FeedPhase -Phase 'payload' -State 'started' -Title 'Copying'
    Write-FeedPhase -Phase 'payload' -State 'failed' -Title 'Copying' -Detail 'Disk full.'
    Write-FeedResult -Ok $false -ErrorInfo ([ordered]@{ code = 'payload_copy_failed'; message = 'Disk full.' }) -Fields ([ordered]@{ install_root = 'C:\x' })
    Close-ProgressFeed
    $failedLines = @([IO.File]::ReadAllLines($failedPath) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-Equal @('phase', 'phase', 'result') @($failedLines | ForEach-Object type) 'a failed run ends with a phase failure and a result'
    Assert-Equal 'failed' $failedLines[1].state 'the failed state'
    Assert-True ($failedLines[2].ok -eq $false -and $failedLines[2].error.code -eq 'payload_copy_failed' -and $failedLines[2].error.message -eq 'Disk full.') 'the result carries error.code and error.message'

    # the feed refuses unsafe paths and writes nothing for them
    function Assert-FeedRefused {
        param([string]$Label, [string]$Path, [string]$Sid = $currentSid, [string]$Reason)
        $refused = $false
        $message = ''
        try { Open-ProgressFeed -Path $Path -ExpectedSid $Sid } catch { $refused = $true; $message = $_.Exception.Message }
        Assert-True $refused "$Label is refused"
        Assert-True ($null -eq $script:FeedStream) "$Label leaves no feed open"
        if ($Reason) { Assert-True ($message -match $Reason) "$Label : the reason mentions '$Reason' (got: $message)" }
        Close-ProgressFeed
    }
    $existing = Join-Path $feedDirectory 'existing.jsonl'
    Write-Text -Path $existing -Text 'already here'
    Assert-FeedRefused 'an existing file' $existing -Reason 'already exists'
    Assert-Equal 'already here' ([IO.File]::ReadAllText($existing)) 'the existing file was not touched'
    Assert-FeedRefused 'a path outside the temporary folder' (Join-Path $env:SystemRoot 'rewindle-feed-test.jsonl') -Reason 'temporary folder'
    Assert-FeedRefused 'a file directly in the temporary folder' (Join-Path ([IO.Path]::GetTempPath()) 'rewindle-feed-direct.jsonl') -Reason 'temporary folder'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) 'rewindle-feed-direct.jsonl'))) 'nothing was created directly in the temporary folder'
    Assert-FeedRefused 'a relative path' 'progress.jsonl' -Reason 'absolute'
    Assert-FeedRefused 'a network path' '\\rewindle-no-such-host.invalid\share\progress.jsonl' -Reason 'absolute'
    Assert-FeedRefused 'the wrong extension' (Join-Path $feedDirectory 'progress.json') -Reason '\.jsonl'
    Assert-FeedRefused 'a missing folder' (Join-Path $feedDirectory 'missing\progress.jsonl') -Reason 'does not exist'
    $feedReal = Join-Path $feedBase 'RewindleSetup-real'
    New-Item -ItemType Directory -Path $feedReal | Out-Null
    Set-OwnerToCurrentUser $feedReal
    $feedLink = Join-Path $feedBase 'RewindleSetup-link'
    New-Junction -Link $feedLink -Target $feedReal
    Assert-FeedRefused 'a path through a junction' (Join-Path $feedLink 'progress.jsonl') -Reason 'reparse point'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $feedReal 'progress.jsonl'))) 'nothing was created behind the junction'
    $ownerRefused = $false
    $ownerMessage = ''
    try {
        [void](Resolve-SafeOutputPath -Path (Join-Path $feedDirectory 'progress-other.jsonl') -Label '-ProgressPath' -Extension '.jsonl' `
            -AllowedRoots @([IO.Path]::GetTempPath()) -RequireStrictlyBelow -RequiredOwnerSid 'S-1-5-32-545')
    }
    catch { $ownerRefused = $true; $ownerMessage = $_.Exception.Message }
    Assert-True ($ownerRefused -and $ownerMessage -match 'owned by') "a folder owned by someone else is refused (got: $ownerMessage)"
    Assert-FeedRefused 'a missing expected user' (Join-Path $feedDirectory 'progress-nosid.jsonl') -Sid '' -Reason 'ExpectedUserSid'
    Assert-FeedRefused 'an invalid expected user' (Join-Path $feedDirectory 'progress-badsid.jsonl') -Sid 'not-a-sid' -Reason 'security identifier'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $feedDirectory 'progress-other.jsonl'))) 'a refused path is never created'
    $secondOpen = Join-Path $feedDirectory 'twice.jsonl'
    Open-ProgressFeed -Path $secondOpen -ExpectedSid $currentSid
    $reopened = $false
    try { Open-ProgressFeed -Path (Join-Path $feedDirectory 'twice-2.jsonl') -ExpectedSid $currentSid } catch { $reopened = $true }
    Assert-True $reopened 'the feed cannot be opened twice'
    Close-ProgressFeed
    Remove-Junction $feedLink

    # ====================================================================================================================
    # 10. Native calls are emitted in memory: nothing goes through the temporary folder
    # ====================================================================================================================
    # The installer and the uninstaller run elevated with the account's own %TEMP%, which its unelevated programs can change.
    # Compiling P/Invoke code with csc.exe writes its source, command line and assembly there and loads the assembly back, so
    # the scripts emit their native calls in memory instead. A child process with TEMP and TMP pointed at an empty, watched
    # folder defines every installer function, calls each helper that uses native code, and reports what appeared there.
    $watchedTemp = Join-Path $workspace 'watched-temp'
    $nativeFolderName = 'A folder with a long name for short-name expansion'
    $nativeFolder = Join-Path $workspace $nativeFolderName
    New-Item -ItemType Directory -Path $watchedTemp, $nativeFolder | Out-Null
    $usedLetters = @([Environment]::GetLogicalDrives() | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() })
    $unusedLetter = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') | Where-Object { $usedLetters -notcontains $_ } | Select-Object -First 1
    Assert-True ($null -ne $unusedLetter) 'a drive letter nobody uses is found for the error check'
    $nativeProbe = Join-Path $workspace 'native-probe.ps1'
    Write-Text -Path $nativeProbe -Text @'
param([string]$Installer, [string]$Watched, [string]$Folder, [string]$UnusedRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$created = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$watcher = [IO.FileSystemWatcher]::new($Watched)
$watcher.IncludeSubdirectories = $true
$null = Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $created -Action { $Event.MessageData.Enqueue($EventArgs.Name) }
$watcher.EnableRaisingEvents = $true
$text = [IO.File]::ReadAllText($Installer)
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] })) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
. ([scriptblock]::Create([regex]::Match($text, '(?s)# region progress-feed.*?# endregion progress-feed').Value))
$script:volumeCache = @{}
$script:installerNative = $null
function Get-ProbeValue {
    param([scriptblock]$Probe)
    try { & $Probe } catch { 'error: ' + $_.Exception.Message }
}
$result = [ordered]@{}
$short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Folder).ShortPath
$result.short_leaf = Split-Path -Leaf $short
$result.long_leaf = Get-ProbeValue { Split-Path -Leaf (Get-FeedLongPath $short) }
$result.system_disks = @(Get-ProbeValue { Get-VolumeDiskNumbers -Drive ([IO.Path]::GetPathRoot([Environment]::SystemDirectory)) })
$result.volume = Get-ProbeValue {
    $volume = Get-RepositoryVolume -Path $Folder -Scope 'system'
    [ordered]@{
        filesystem = $volume.filesystem
        maximum_component_length = $volume.maximum_component_length
        filesystem_flags = $volume.filesystem_flags
        serial_well_formed = ([string]$volume.serial -cmatch '^[0-9A-F]{8}$')
    }
}
$result.unused_drive_error = Get-ProbeValue {
    $native = Get-InstallerNativeMethods
    [uint32]$serial = 0
    [uint32]$maximum = 0
    [uint32]$flags = 0
    $ok = $native::GetVolumeInformationW($UnusedRoot, $null, 0, [ref]$serial, [ref]$maximum, [ref]$flags, $null, 0)
    $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($ok) { 'succeeded' } else { $code }
}
$result.set_last_error = @(Get-ProbeValue {
    $native = Get-InstallerNativeMethods
    foreach ($name in @('GetVolumeInformationW', 'CreateFileW', 'DeviceIoControl', 'CloseHandle')) {
        $import = @($native.GetMethod($name).GetCustomAttributes([Runtime.InteropServices.DllImportAttribute], $false))[0]
        '{0}={1}' -f $name, ($import.Value -eq 'kernel32.dll' -and $import.SetLastError -and $import.EntryPoint -ceq $name)
    }
})
Start-Sleep -Milliseconds 500
$watcher.EnableRaisingEvents = $false
$names = [Collections.Generic.List[string]]::new()
$item = $null
while ($created.TryDequeue([ref]$item)) { $names.Add($item) }
$result.created_in_temp = @($names)
ConvertTo-Json -InputObject $result -Depth 4 -Compress
'@
    $probeRun = Invoke-ProcessCapture -FileName $windowsPowerShell -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $nativeProbe, '-Installer', $installerScript,
        '-Watched', $watchedTemp, '-Folder', $nativeFolder, '-UnusedRoot', ($unusedLetter + ':\')
    ) -Environment @{ TEMP = $watchedTemp; TMP = $watchedTemp }
    Assert-Equal 0 $probeRun.ExitCode "the native-call probe ran (stderr: $($probeRun.Error))"
    $nativeResult = $probeRun.Output | ConvertFrom-Json
    Assert-Equal @() @($nativeResult.created_in_temp) 'the installer''s native helpers created nothing in %TEMP% (a compiler would leave its .cs, .cmdline and .dll files there)'
    Assert-Equal $nativeFolderName $nativeResult.long_leaf "the feed's path check expands a short (8.3) name ($($nativeResult.short_leaf))"
    $systemDisks = @($nativeResult.system_disks)
    Assert-True ($systemDisks.Count -ge 1 -and @($systemDisks | Where-Object { $_ -isnot [int] -and $_ -isnot [long] }).Count -eq 0) "the disks that hold the system drive are found (got: $($systemDisks -join ', '))"
    Assert-True ($nativeResult.volume -isnot [string]) "the volume of a local folder is read (got: $($nativeResult.volume))"
    $nativeDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($nativeFolder))
    Assert-Equal $nativeDrive.DriveFormat $nativeResult.volume.filesystem 'the volume reports its file system'
    Assert-True ($nativeResult.volume.maximum_component_length -gt 0 -and $nativeResult.volume.filesystem_flags -ne 0) 'the volume reports its longest name and its file-system flags'
    Assert-True $nativeResult.volume.serial_well_formed 'the volume serial is eight hexadecimal digits'
    Assert-True (@(3, 15) -contains $nativeResult.unused_drive_error) "a call on an unused drive letter reports Windows' own error, so SetLastError is set (got: $($nativeResult.unused_drive_error))"
    Assert-Equal @('GetVolumeInformationW=True', 'CreateFileW=True', 'DeviceIoControl=True', 'CloseHandle=True') @($nativeResult.set_last_error) 'every emitted call imports kernel32 by its exact name with SetLastError'

    # ====================================================================================================================
    # 11. A downloaded program is checked and run while held open
    # ====================================================================================================================
    # The WebView2 bootstrapper is downloaded into a folder only administrators can change and held open, with only reading
    # shared, from before its signature check until it has exited. A copy of cmd.exe stands in for it here; nothing is
    # downloaded, and the real folder (under ProgramData) is created only where these checks run elevated, as in CI.
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @('Invoke-HeldExecutable', 'New-AdministratorsOnlyFolderSecurity', 'New-AdministratorsOnlyFolder'))))
    $script:signatureChecks = [Collections.Generic.List[object]]::new()
    $script:signatureRejected = $false
    # Stands in for the real check: it records what it was asked, tries everything another program could do to the file
    # while it is being checked, and passes or rejects as the test says.
    function Assert-MicrosoftSignedExecutable {
        param([string]$Path, [string]$Code)
        $refused = [ordered]@{}
        foreach ($attempt in @(
            @{ Name = 'write'; Action = { [IO.File]::Open($Path, 'Open', 'ReadWrite', 'ReadWrite').Dispose() } },
            @{ Name = 'delete'; Action = { [IO.File]::Delete($Path) } },
            @{ Name = 'rename'; Action = { [IO.File]::Move($Path, $Path + '.moved') } },
            @{ Name = 'rename the folder'; Action = { $parent = Split-Path -Parent $Path; [IO.Directory]::Move($parent, $parent + '-moved') } }
        )) {
            $refused[$attempt.Name] = $false
            try { & $attempt.Action } catch { $refused[$attempt.Name] = $true }
        }
        $script:signatureChecks.Add([pscustomobject]@{ Path = $Path; Code = $Code; Refused = $refused })
        if ($script:signatureRejected) { throw 'The test rejected the signature.' }
    }
    $heldFolder = Join-Path $workspace 'held'
    New-Item -ItemType Directory -Path $heldFolder | Out-Null
    $systemShell = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $heldProgram = Join-Path $heldFolder 'bootstrapper.exe'
    Copy-Item -LiteralPath $systemShell -Destination $heldProgram
    # The program tries to rename its own file while it runs: Windows allows that for a running program nobody holds.
    $heldExit = Invoke-HeldExecutable -Path $heldProgram -ArgumentList @('/d', '/c', ('ren "' + $heldProgram + '" swapped.exe')) -Code 'webview2_installer_untrusted'
    Assert-Equal 1 $script:signatureChecks.Count 'the signature is checked once, before the program runs'
    Assert-Equal $heldProgram $script:signatureChecks[0].Path 'the downloaded file itself is checked'
    Assert-Equal 'webview2_installer_untrusted' $script:signatureChecks[0].Code 'a rejected signature reports the WebView2 installer code'
    foreach ($name in @('write', 'delete', 'rename', 'rename the folder')) {
        Assert-True $script:signatureChecks[0].Refused[$name] "while it is checked, the file is held: $name is refused"
    }
    Assert-Equal 1 $heldExit 'while it runs, the program cannot rename its own file (cmd reports the failed rename)'
    Assert-True ((Test-Path -LiteralPath $heldProgram -PathType Leaf) -and -not (Test-Path -LiteralPath (Join-Path $heldFolder 'swapped.exe'))) 'the checked file stayed in place while it ran'
    [IO.File]::Delete($heldProgram)
    Assert-True (-not (Test-Path -LiteralPath $heldProgram)) 'the hold is released once the program has exited'
    # The same rename without the hold succeeds, so the hold is what kept the file in place.
    $freeProgram = Join-Path $heldFolder 'unheld.exe'
    Copy-Item -LiteralPath $systemShell -Destination $freeProgram
    $freeRun = Start-Process -FilePath $freeProgram -ArgumentList @('/d', '/c', ('ren "' + $freeProgram + '" unheld-swapped.exe')) -WindowStyle Hidden -Wait -PassThru
    Assert-True ($freeRun.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $heldFolder 'unheld-swapped.exe'))) 'without the hold, a running program can rename its own file'
    # A program that fails the check never runs, and is released.
    $script:signatureRejected = $true
    $rejectedProgram = Join-Path $heldFolder 'rejected.exe'
    $ranMarker = Join-Path $heldFolder 'ran.txt'
    Copy-Item -LiteralPath $systemShell -Destination $rejectedProgram
    $rejected = $false
    try { [void](Invoke-HeldExecutable -Path $rejectedProgram -ArgumentList @('/d', '/c', ('echo ran> "' + $ranMarker + '"')) -Code 'webview2_installer_untrusted') }
    catch { $rejected = $true }
    Assert-True ($rejected -and -not (Test-Path -LiteralPath $ranMarker)) 'a program that fails the signature check is never run'
    [IO.File]::Delete($rejectedProgram)
    Assert-True (-not (Test-Path -LiteralPath $rejectedProgram)) 'and its hold is released'

    # The folder it is downloaded into: owned by Administrators, inheriting nothing, full control for Administrators and SYSTEM.
    $folderSecurity = New-AdministratorsOnlyFolderSecurity
    Assert-Equal 'S-1-5-32-544' $folderSecurity.GetOwner([Security.Principal.SecurityIdentifier]).Value 'the protected folder is owned by Administrators'
    Assert-True $folderSecurity.AreAccessRulesProtected 'the protected folder inherits nothing from its parent'
    $folderRules = @($folderSecurity.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    Assert-Equal @('S-1-5-18', 'S-1-5-32-544') @($folderRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object) 'only SYSTEM and Administrators are named in the protected folder'
    foreach ($rule in $folderRules) {
        Assert-True ($rule.AccessControlType -eq 'Allow' -and $rule.FileSystemRights -eq 'FullControl' -and -not $rule.IsInherited -and
            $rule.InheritanceFlags -eq 'ContainerInherit, ObjectInherit' -and $rule.PropagationFlags -eq 'None') "$($rule.IdentityReference.Value) has full control of the protected folder and everything in it"
    }
    $protectedParent = Join-Path $workspace 'protected-parent'
    New-Item -ItemType Directory -Path $protectedParent | Out-Null
    if ($isElevated) {
        $protectedFolder = New-AdministratorsOnlyFolder -Parent $protectedParent
        Assert-True ((Split-Path -Leaf $protectedFolder) -cmatch '^RewindleSetup-[0-9a-f]{32}$') 'the protected folder follows the Setup bootstrap''s name pattern'
        $protectedAcl = [IO.Directory]::GetAccessControl($protectedFolder)
        Assert-True ($protectedAcl.AreAccessRulesProtected -and $protectedAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'the protected folder was created owned by Administrators and inheriting nothing'
        [IO.Directory]::Delete($protectedFolder)
    }
    else {
        # A standard user cannot make Administrators the owner, so the folder is refused outright, never left open.
        $folderRefused = $false
        try { [void](New-AdministratorsOnlyFolder -Parent $protectedParent) } catch { $folderRefused = $true }
        Assert-True $folderRefused 'without an administrator token the protected folder is refused'
        Assert-Equal @() @(Get-ChildItem -LiteralPath $protectedParent -Force | ForEach-Object Name) 'and nothing is left behind'
    }

    # ====================================================================================================================
    # 12. Where an earlier installation kept its backups (the state folder an uninstall leaves)
    # ====================================================================================================================
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @('Test-TrustedStateOwner', 'Test-KeptRepositoryPath', 'ConvertTo-KeptRecordTime', 'Get-RecordedRepositoryAccess', 'Get-KeptRepository', 'Get-RepositoryInput'))))
    # Only a state folder that Administrators or SYSTEM own is read (section 8). This account owns the fixture folders, so for
    # the fixture state folder Get-FeedOwnerSid answers $script:keptStateOwner ($null: the owner can't be read). The stand-in is
    # defined in a scope of its own, so the real Get-FeedOwnerSid stays in place for the progress feed checks below.
    $script:keptStateOwner = 'S-1-5-32-544'
    function Use-KeptStateOwner {
        param([scriptblock]$Action)
        return & {
            function Get-FeedOwnerSid {
                param([string]$Path)
                if ($Path -ne $stateRoot) { throw "Unexpected owner lookup: $Path" }
                if ($null -eq $script:keptStateOwner) { throw [UnauthorizedAccessException]::new('Access is denied.') }
                return $script:keptStateOwner
            }
            & $Action
        }
    }
    function Find-KeptRepository { return (Use-KeptStateOwner { Get-KeptRepository }) }
    function Write-KeptRecord {
        param([string]$Folder, [string]$Name, $Record)
        $text = if ($Record -is [string]) { $Record } else { ConvertTo-Json -InputObject $Record -Depth 4 }
        Write-Text -Path (Join-Path $Folder $Name) -Text $text
    }
    function Set-ReadDenied {
        param([string]$Path, [bool]$Denied)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($currentSid), 'ReadData', 'Deny')
        $security = [IO.File]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
        if ($Denied) { $security.AddAccessRule($rule) } else { [void]$security.RemoveAccessRule($rule) }
        [IO.File]::SetAccessControl($Path, $security)
    }
    $planId = '11111111-2222-4333-8444-555555555555'
    $keptFirst = Join-Path $repositoryRoot 'kept\ResticBackups\Personal'
    $keptMoved = Join-Path $repositoryRoot 'moved\Backups'
    $setUp = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00.123456Z'; repository = $keptFirst; repository_storage_mode = 'local_ntfs' }
    $afterMove = [ordered]@{ schema_version = 1; plan_id = $planId; config_generation = 2; started_utc = '2026-10-02T02:00:00.5Z'; finished_utc = '2026-10-02T02:21:07.250001Z'; repository = $keptMoved; repository_storage_mode = 'local_ntfs' }

    # --- the reader, against a state folder of its own ---
    $stateRoot = Join-Path $workspace 'kept-unit\ResticBackuper'
    $secretFile = Join-Path $stateRoot 'repository-password.dpapi.json'
    function Reset-KeptState {
        param([hashtable]$Records = @{}, [switch]$NoSecret)
        if (Test-Path -LiteralPath $stateRoot) { Remove-Item -LiteralPath $stateRoot -Recurse -Force }
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        if (-not $NoSecret) { Write-Text -Path $secretFile -Text '{}' }
        foreach ($name in $Records.Keys) { Write-KeptRecord -Folder $stateRoot -Name $name -Record $Records[$name] }
    }
    function Get-KeptPath { $found = Find-KeptRepository; if ($null -eq $found) { return '<none>' } return [string]$found.repository }
    Remove-Item -LiteralPath (Split-Path -Parent $stateRoot) -Recurse -Force -ErrorAction SilentlyContinue
    Assert-True ($null -eq (Find-KeptRepository)) 'no state folder: nothing was kept'
    Reset-KeptState -Records @{ 'repository.json' = $setUp }
    $found = Find-KeptRepository
    Assert-Equal @($keptFirst, 'local_ntfs') @($found.repository, $found.storage_mode) 'repository.json names the kept backups and how they are stored'
    Reset-KeptState -Records @{ 'repository.json' = $setUp } -NoSecret
    Assert-Equal '<none>' (Get-KeptPath) 'without the stored password setup could not carry on with them, so none is reported'

    # Nothing is read from a state folder that Administrators or SYSTEM don't own, or that is a link: any account can create it.
    Reset-KeptState -Records @{ 'repository.json' = $setUp }
    $script:keptStateOwner = 'S-1-5-18'
    Assert-Equal $keptFirst (Get-KeptPath) 'a state folder SYSTEM owns is read'
    foreach ($owner in @($currentSid, 'S-1-5-32-545', $null)) {
        $script:keptStateOwner = $owner
        Assert-Equal '<none>' (Get-KeptPath) "a state folder owned by '$owner' names no kept backups"
    }
    $script:keptStateOwner = 'S-1-5-32-544'
    Set-OwnerToCurrentUser $stateRoot
    Assert-Equal '<none>' (& { $found = Get-KeptRepository; if ($null -eq $found) { '<none>' } else { [string]$found.repository } }) 'a real state folder this account owns names no kept backups'
    $keptLink = Join-Path $workspace 'kept-unit\Linked'
    New-Junction -Link $keptLink -Target $stateRoot
    $realKeptState = $stateRoot
    $stateRoot = $keptLink
    $secretFile = Join-Path $keptLink 'repository-password.dpapi.json'
    try { Assert-Equal '<none>' (Get-KeptPath) 'a state folder that is a link names no kept backups' }
    finally {
        $stateRoot = $realKeptState
        $secretFile = Join-Path $stateRoot 'repository-password.dpapi.json'
        Remove-Junction $keptLink
    }
    $cloud = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = (Join-Path $workspace 'console\My Drive\Rewindle\Backups'); repository_storage_mode = 'google_drivefs_stream' }
    Reset-KeptState -Records @{ 'repository.json' = $cloud }
    Assert-Equal 'google_drivefs_stream' (Find-KeptRepository).storage_mode 'backups kept in Google Drive are reported as such'
    $noMode = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = $keptFirst }
    Reset-KeptState -Records @{ 'repository.json' = $noMode }
    Assert-Equal 'local_ntfs' (Find-KeptRepository).storage_mode 'a record without a storage mode is local'

    # How the backups open is part of the record: absent means a password (every record written before the choice existed), no
    # password needs no stored password, and anything else is passed over like an unknown storage mode.
    function Copy-Record {
        param($Record, [hashtable]$Set = @{})
        $copy = [ordered]@{}
        foreach ($key in $Record.Keys) { $copy[$key] = $Record[$key] }
        foreach ($key in $Set.Keys) { $copy[$key] = $Set[$key] }
        return $copy
    }
    Reset-KeptState -Records @{ 'repository.json' = $setUp }
    Assert-Equal 'password' (Find-KeptRepository).repository_access 'a record that does not say how the backups open means a password'
    $setUpWithout = Copy-Record $setUp @{ repository_access = 'no_password' }
    Reset-KeptState -Records @{ 'repository.json' = $setUpWithout }
    $found = Find-KeptRepository
    Assert-Equal @($keptFirst, 'local_ntfs', 'no_password') @($found.repository, $found.storage_mode, $found.repository_access) 'a record of backups without a password is reported as such'
    Reset-KeptState -Records @{ 'repository.json' = $setUpWithout } -NoSecret
    $found = Find-KeptRepository
    Assert-Equal @($keptFirst, 'no_password') @($found.repository, $found.repository_access) 'backups without a password need no stored password, so they are reported without one'
    Reset-KeptState -Records @{ 'repository.json' = (Copy-Record $setUp @{ repository_access = 'password' }) } -NoSecret
    Assert-Equal '<none>' (Get-KeptPath) 'backups with a password and no stored password are still not reported'
    foreach ($value in @('Password', 'NO_PASSWORD', 'none', '', 7, $true, $null)) {
        Reset-KeptState -Records @{ 'repository.json' = (Copy-Record $setUp @{ repository_access = $value }) }
        Assert-Equal '<none>' (Get-KeptPath) "a record that says '$value' about how the backups open names no kept backups"
    }
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'last-success.json' = (Copy-Record $afterMove @{ repository_access = 'Password' }) }
    Assert-Equal $keptFirst (Get-KeptPath) 'a newer record with a way of opening that setup does not know is passed over for an older one'
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'status.json' = (Copy-Record $afterMove @{ repository_access = 'no_password' }) }
    $found = Find-KeptRepository
    Assert-Equal @($keptMoved, 'no_password') @($found.repository, $found.repository_access) 'the newest record says how the backups open'

    # The newest record wins: a backup after a move of the backup location names the new place, and a later rewrite of
    # repository.json (updated_utc) wins over older backups.
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'last-success.json' = $afterMove; 'status.json' = $afterMove }
    Assert-Equal $keptMoved (Get-KeptPath) 'a backup after a move names the place the backups were moved to'
    # Manage-Repository.ps1 rewrites repository.json when a move completes, keeping initialized_utc and adding relocated_utc.
    # Until the next backup, the backups before the move still name the old place, so the time of the move counts.
    $beforeMove = [ordered]@{ schema_version = 1; plan_id = $planId; config_generation = 2; started_utc = '2026-10-01T02:00:00Z'; finished_utc = '2026-10-01T02:20:00Z'; repository = $keptFirst; repository_storage_mode = 'local_ntfs' }
    $relocated = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00.123456Z'; relocated_utc = '2026-10-01T09:30:00.1234567Z'; repository = $keptMoved; repository_storage_mode = 'local_ntfs' }
    Reset-KeptState -Records @{ 'repository.json' = $relocated; 'last-success.json' = $beforeMove; 'status.json' = $beforeMove }
    Assert-Equal $keptMoved (Get-KeptPath) 'a move completed after the last backup names the place the backups were moved to'
    $rewritten = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; updated_utc = '2026-10-03T08:00:00Z'; repository = $keptFirst }
    Reset-KeptState -Records @{ 'repository.json' = $rewritten; 'last-success.json' = $afterMove }
    Assert-Equal $keptFirst (Get-KeptPath) 'a later updated_utc in repository.json wins over an older backup'
    $failedLater = [ordered]@{ schema_version = 1; started_utc = '2026-10-05T02:00:00Z'; finished_utc = $null; repository = (Join-Path $repositoryRoot 'later'); repository_storage_mode = 'local_ntfs' }
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'last-success.json' = $afterMove; 'status.json' = $failedLater }
    Assert-Equal (Join-Path $repositoryRoot 'later') (Get-KeptPath) 'the newest run counts even when it did not finish'
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'last-success.json' = '{not json' }
    Assert-Equal $keptFirst (Get-KeptPath) 'a record that is not JSON is passed over for an older one'
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'status.json' = ([ordered]@{ schema_version = 1; started_utc = 'yesterday'; repository = $keptMoved }) }
    Assert-Equal $keptFirst (Get-KeptPath) 'a record without a readable time is passed over'
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'status.json' = $afterMove }
    Set-ReadDenied -Path (Join-Path $stateRoot 'status.json') -Denied $true
    try { Assert-Equal $keptFirst (Get-KeptPath) 'a record this account may not read is passed over' }
    finally { Set-ReadDenied -Path (Join-Path $stateRoot 'status.json') -Denied $false }

    # Anything odd in a record means "not known".
    $odd = @(
        @('schema_version 2', ([ordered]@{ schema_version = 2; initialized_utc = '2026-09-01T10:00:00Z'; repository = $keptFirst })),
        @('no schema_version', ([ordered]@{ initialized_utc = '2026-09-01T10:00:00Z'; repository = $keptFirst })),
        @('an unknown storage mode', ([ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = $keptFirst; repository_storage_mode = 'network' })),
        @('no time', ([ordered]@{ schema_version = 1; repository = $keptFirst })),
        @('a time that is not ISO-8601', ([ordered]@{ schema_version = 1; initialized_utc = '09/01/2026 10:00'; repository = $keptFirst })),
        @('no repository', ([ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z' })),
        @('a number for a repository', ([ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = 42 })),
        @('a JSON list', '[{"schema_version": 1}]'),
        @('JSON null', 'null'),
        @('an empty file', '')
    )
    foreach ($case in $odd) {
        Reset-KeptState -Records @{ 'repository.json' = $case[1] }
        Assert-Equal '<none>' (Get-KeptPath) "a record with $($case[0]) names no kept backups"
    }
    # Only strings are checked here: no drive is opened, and the letters are ones a test PC is unlikely to have.
    foreach ($bad in @('relative\Backups', '\\server\share\Backups', '\\?\Q:\Backups', 'Q:', 'Q:\', 'Q:Backups', 'Q:\Backups\', 'Q:\Backups\..\Other',
        'Q:\Backups\.\Rewindle', 'Q:\Backups\\Rewindle', 'Q:\Backups.', 'Q:\Back"ups', "Q:\Back`tups", 'Q:\Backups:stream', 'Q:\Back*ups', '', ('Q:\' + ('x' * 1100)))) {
        Assert-True (-not (Test-KeptRepositoryPath -Value $bad)) "'$bad' is not a backup folder to suggest"
        Reset-KeptState -Records @{ 'repository.json' = ([ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = $bad }) }
        Assert-Equal '<none>' (Get-KeptPath) "a record naming '$bad' names no kept backups"
    }
    foreach ($good in @('Q:\ResticBackups\Personal', 'r:\Rewindle\Backups', 'Q:\My Drive\Rewindle Backups', ('Q:\Fotos e v' + [char]0x00ED + 'deos'))) {
        Assert-True (Test-KeptRepositoryPath -Value $good) "'$good' is a backup folder to suggest"
    }
    $utcMoment = [datetime]::new(2026, 10, 2, 2, 21, 7, [DateTimeKind]::Utc)
    Assert-Equal $utcMoment.Ticks (ConvertTo-KeptRecordTime -Value $utcMoment).UtcTicks 'a time PowerShell already read as a date is used as it is'
    Assert-Equal $utcMoment.Ticks (ConvertTo-KeptRecordTime -Value '2026-10-02T02:21:07Z').UtcTicks 'an ISO-8601 UTC time is read as UTC'
    Assert-Equal $utcMoment.Ticks (ConvertTo-KeptRecordTime -Value '2026-10-02T04:21:07+02:00').UtcTicks 'an offset is honored'

    # --- the console installer suggests the kept folder at its prompt ---
    $script:consoleLines = [Collections.Generic.List[string]]::new()
    function Invoke-ConsoleRepositoryPrompt {
        param([string]$Mode)
        $script:Repository = $null
        $script:consolePrompt = $null
        $script:consoleLines.Clear()
        & {
            # Stand-ins for the console and for the drive scan, so nothing on this PC is asked or listed.
            function Read-Host { param([string]$Prompt) $script:consolePrompt = $Prompt; return '' }
            function Write-Host { param([object]$Object) $script:consoleLines.Add([string]$Object) }
            function Get-DefaultRepository { return (Join-Path $workspace 'console\Usual\ResticBackups\Personal') }
            $PlanOnly = $false
            $Unattended = $false
            $Repository = $null
            $RepositoryStorageMode = $Mode
            $DriveFsMyDriveRoot = Join-Path $workspace 'console\My Drive'
            $defaultRepositorySuffix = 'ResticBackups\Personal'
            Use-KeptStateOwner { Get-RepositoryInput }
        }
        return $script:Repository
    }
    Reset-KeptState -Records @{ 'repository.json' = $setUp; 'last-success.json' = $afterMove }
    Assert-Equal $keptMoved (Invoke-ConsoleRepositoryPrompt -Mode 'local_ntfs') 'pressing Enter at the console keeps the kept backups'
    Assert-True ([string]$script:consolePrompt).Contains("[$keptMoved]") "the console prompt shows the kept folder as its default (got: $($script:consolePrompt))"
    Assert-True (@($script:consoleLines | Where-Object { $_.Contains("earlier installation are in $keptMoved.") }).Count -eq 1) 'the console says where the earlier backups are'
    Assert-Equal (Join-Path $workspace 'console\My Drive\ResticBackups\Personal') (Invoke-ConsoleRepositoryPrompt -Mode 'google_drivefs_stream') 'local backups are not suggested for a Google Drive install'
    Assert-True (@($script:consoleLines | Where-Object { $_.Contains('-RepositoryStorageMode local_ntfs') }).Count -eq 1) 'the console says how to keep using local backups'
    Reset-KeptState
    Assert-Equal (Join-Path $workspace 'console\Usual\ResticBackups\Personal') (Invoke-ConsoleRepositoryPrompt -Mode 'local_ntfs') 'with nothing kept the console suggests the usual folder'
    Assert-Equal 0 $script:consoleLines.Count 'with nothing kept the console says nothing about earlier backups'

    # --- plan mode reports it, as the wizard's first plan sees it (no choices yet) ---
    $keptRoots = New-RootsSet -Name 'kept'
    $keptState = Join-Path $keptRoots.ProgramData 'ResticBackuper'
    Write-Text -Path (Join-Path $keptState 'repository-password.dpapi.json') -Text '{}'
    Write-KeptRecord -Folder $keptState -Name 'repository.json' -Record $setUp
    if ($isElevated) {
        # The folder an install leaves belongs to Administrators, and only such a folder is read.
        $keptStateAcl = Get-Acl -LiteralPath $keptState
        $keptStateAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        Set-Acl -LiteralPath $keptState -AclObject $keptStateAcl
        $keptRun = Invoke-Plan -Bundle $bundle -Roots $keptRoots -Temp $temp -Arguments @('-MinimumFreeGiB', '1')
        Assert-Equal 0 $keptRun.ExitCode "a plan over the state an uninstall kept is written (stderr: $($keptRun.Error))"
        Assert-Equal $keptFirst $keptRun.Plan.environment.existing_install.kept_repository 'existing_install.kept_repository names the kept backups'
        Assert-Equal 'password' $keptRun.Plan.environment.existing_install.kept_repository_access 'a kept record that does not say how the backups open is reported as a password'
        Write-KeptRecord -Folder $keptState -Name 'repository.json' -Record $setUpWithout
        Remove-Item -LiteralPath (Join-Path $keptState 'repository-password.dpapi.json')
        $keptWithoutRun = Invoke-Plan -Bundle $bundle -Roots $keptRoots -Temp $temp -Arguments @('-MinimumFreeGiB', '1')
        Assert-Equal @($keptFirst, 'no_password') @($keptWithoutRun.Plan.environment.existing_install.kept_repository, $keptWithoutRun.Plan.environment.existing_install.kept_repository_access) 'kept backups without a password are reported as such, with no stored password'
        Write-KeptRecord -Folder $keptState -Name 'repository.json' -Record $setUp
        Write-Text -Path (Join-Path $keptState 'repository-password.dpapi.json') -Text '{}'
        Assert-True ($null -eq $keptRun.Plan.environment.existing_install.rewindle) 'kept state alone is not an installation'
        Assert-Equal $keptRoots.DefaultRepository $keptRun.Plan.defaults.repository 'defaults.repository stays the recommendation'
        Assert-Equal @(Get-ErrorCodes $noArguments.Plan) @(Get-ErrorCodes $keptRun.Plan) 'the kept state adds no error'
        Assert-Equal @(Get-WarningCodes $noArguments.Plan) @(Get-WarningCodes $keptRun.Plan) 'the kept state adds no warning'
        Write-KeptRecord -Folder $keptState -Name 'last-success.json' -Record $afterMove
        $movedRun = Invoke-Plan -Bundle $bundle -Roots $keptRoots -Temp $temp -Arguments @('-MinimumFreeGiB', '1')
        Assert-Equal $keptMoved $movedRun.Plan.environment.existing_install.kept_repository 'after a move of the backup location the plan names the new place'
        Assert-Equal @(Get-ErrorCodes $noArguments.Plan) @(Get-ErrorCodes $movedRun.Plan) 'the kept plan identity adds no error'
        # Records this account can't read, or that are malformed, mean "not known": no error, no warning, a plan all the same.
        Write-KeptRecord -Folder $keptState -Name 'last-success.json' -Record '{not json'
        Write-KeptRecord -Folder $keptState -Name 'status.json' -Record ([ordered]@{ schema_version = 1; started_utc = '2026-10-05T02:00:00Z'; repository = 'relative\Backups' })
        Set-ReadDenied -Path (Join-Path $keptState 'repository.json') -Denied $true
        try { $brokenRun = Invoke-Plan -Bundle $bundle -Roots $keptRoots -Temp $temp -Arguments @('-MinimumFreeGiB', '1') }
        finally { Set-ReadDenied -Path (Join-Path $keptState 'repository.json') -Denied $false }
        Assert-Equal 0 $brokenRun.ExitCode "unreadable and malformed records still give a plan (stderr: $($brokenRun.Error))"
        Assert-True ($null -eq $brokenRun.Plan.environment.existing_install.kept_repository) 'unreadable and malformed records name no kept backups'
        Assert-Equal @(Get-ErrorCodes $noArguments.Plan) @(Get-ErrorCodes $brokenRun.Plan) 'unreadable and malformed records add no error'
        Assert-Equal @(Get-WarningCodes $noArguments.Plan) @(Get-WarningCodes $brokenRun.Plan) 'unreadable and malformed records add no warning'
    }
    else {
        # A standard user cannot make Administrators the owner, and a state folder this account owns is never read: the plan
        # names no kept backups and reports the folder instead (section 2), and adds nothing else.
        Set-OwnerToCurrentUser $keptState
        $untrustedRun = Invoke-Plan -Bundle $bundle -Roots $keptRoots -Temp $temp -Arguments @('-MinimumFreeGiB', '1')
        Assert-Equal 0 $untrustedRun.ExitCode "a plan over a kept state folder this account owns is written (stderr: $($untrustedRun.Error))"
        Assert-True ($null -eq $untrustedRun.Plan.environment.existing_install.kept_repository) 'a state folder this account owns names no kept backups'
        Assert-True ($null -eq $untrustedRun.Plan.environment.existing_install.kept_repository_access) 'and no way of opening them'
        Assert-True ((Get-ErrorCodes $untrustedRun.Plan) -contains 'state_folder_untrusted') 'the plan reports the state folder this account owns'
        Assert-Equal @(Get-ErrorCodes $noArguments.Plan) @(Get-ErrorCodes $untrustedRun.Plan | Where-Object { $_ -cne 'state_folder_untrusted' }) 'the untrusted kept state adds no other error'
        Assert-Equal @(Get-WarningCodes $noArguments.Plan) @(Get-WarningCodes $untrustedRun.Plan) 'the untrusted kept state adds no warning'
    }

    # ====================================================================================================================
    # 13. Which configuration generation a reinstall over kept state writes
    # ====================================================================================================================
    # The generation a reinstall keeps only when the latest verified backup is of the highest generation on record and was made
    # with exactly the scope being written: the same folders on the same drives, exclusion list, computer and backup location,
    # a location that already holds the repository. Anything else starts the next generation, as every reinstall did before.
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @('Get-NormalizedPath', 'Get-PreservedPlanIdentity', 'Get-ContinuedConfigGeneration'))))
    $continuedRoot = Join-Path $workspace 'continued'
    $continuedSources = @(
        (Join-Path $continuedRoot 'Users\Person\Documents'),
        (Join-Path $continuedRoot 'Photos'),
        (Join-Path $continuedRoot 'ProgramData\ResticBackuper\canary')
    )
    $continuedBackups = Join-Path $continuedRoot 'Backups'
    # The installed exclusion list, and its SHA-256 as backup.py records it (bytes hashed here, not with Get-FileHash).
    $continuedExcludeFile = Join-Path $continuedRoot 'Program Files\ResticBackuper\excludes.txt'
    Write-Text -Path $continuedExcludeFile -Text "**/node_modules`n**/__pycache__`n"
    $continuedExcludes = -join ([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($continuedExcludeFile)) | ForEach-Object { $_.ToString('x2') })
    $otherExcludeFile = Join-Path $continuedRoot 'other\excludes.txt'
    Write-Text -Path $otherExcludeFile -Text "**/node_modules`n"
    $continuedSnapshot = 'c' * 64
    # The configuration as the install builds it (the fields the comparison reads).
    function New-ContinuedConfiguration {
        param([string[]]$Sources = $continuedSources, [hashtable]$Serials = @{}, [string]$ExcludeFile = $continuedExcludeFile)
        $identities = [ordered]@{}
        foreach ($source in $Sources) {
            $serial = if ($Serials.ContainsKey($source)) { $Serials[$source] } else { 'A1B2C3D4' }
            $identities[$source] = [ordered]@{ expected_volume_serial = $serial }
        }
        return [ordered]@{
            schema_version = 1
            plan_id = $planId
            config_generation = 1
            repository = $continuedBackups
            repository_storage_mode = 'local_ntfs'
            repository_volume_serial = '0BADF00D'
            exclude_file = $ExcludeFile
            hostname = 'REWINDLE-PC'
            sources = @($Sources)
            source_identities = $identities
        }
    }
    # last-success.json as backup.py writes it after a verified backup (the fields the comparison reads).
    function New-VerifiedBackupRecord {
        param([long]$Generation = 3)
        return [ordered]@{
            schema_version = 1
            state = 'success'
            verification_complete = $true
            plan_id = $planId
            config_generation = $Generation
            snapshot_id = $continuedSnapshot
            hostname = 'REWINDLE-PC'
            tag = 'scheduled'
            repository = $continuedBackups
            repository_storage_mode = 'local_ntfs'
            repository_volume_serial = '0BADF00D'
            exclude_file_sha256 = $continuedExcludes
            sources = @($continuedSources)
            source_identities = @(foreach ($source in $continuedSources) {
                [ordered]@{
                    configured_path = $source; canonical_path = $source; readiness = 'ready'; expected_volume_serial = 'A1B2C3D4'
                    observed_volume_serial = 'A1B2C3D4'; volume_identity = 'match'; overall_status = 'ready'
                }
            })
        }
    }
    function Get-Continued {
        param($Record = (New-VerifiedBackupRecord), [long]$Highest = 3, [bool]$RepositoryKept = $true,
            $Configuration = (New-ContinuedConfiguration))
        # Read back through JSON, as Get-PreservedPlanIdentity reads it from the state folder.
        $evidence = if ($null -eq $Record) { $null } elseif ($Record -is [string]) { $Record | ConvertFrom-Json } else { $Record | ConvertTo-Json -Depth 6 | ConvertFrom-Json }
        $preserved = [pscustomobject]@{ plan_id = $planId; config_generation = $Highest; last_success = $evidence }
        return (Get-ContinuedConfigGeneration -PreservedPlan $preserved -Configuration $Configuration -RepositoryKept $RepositoryKept)
    }
    function Edit-VerifiedBackupRecord {
        param([scriptblock]$Change)
        $record = New-VerifiedBackupRecord
        & $Change $record
        return $record
    }

    # --- the same scope keeps the generation ---
    Assert-Equal 3 (Get-Continued) 'a reinstall with the same choices keeps the generation of the latest verified backup'
    Assert-Equal 3 (Get-Continued -Record (Edit-VerifiedBackupRecord { param($r) $r.state = 'success_unchanged' })) 'an unchanged verified backup counts the same'
    Assert-Equal 3 (Get-Continued -Record (Edit-VerifiedBackupRecord {
        param($r)
        $r.hostname = 'rewindle-pc'
        $r.repository = $continuedBackups.ToUpperInvariant() + '\'
        $r.repository_volume_serial = '0badf00d'
        $r.sources = @($continuedSources[2].ToUpperInvariant(), $continuedSources[0], ($continuedSources[1] + '\'))
        foreach ($item in $r.source_identities) { $item.configured_path = $item.configured_path.ToLowerInvariant(); $item.observed_volume_serial = 'a1b2c3d4' }
    })) 'names compare as Windows compares them, in any order'

    # --- anything else starts the next generation ---
    Assert-Equal 4 (Get-Continued -Record $null) 'no verified backup on record starts the next generation'
    Assert-Equal 4 (Get-Continued -RepositoryKept $false) 'a backup location that holds no repository yet starts the next generation'
    Assert-Equal 4 (Get-Continued -Record (New-VerifiedBackupRecord -Generation 2)) 'a verified backup older than the newest generation on record (a folder change or a move since) starts the next one'
    Assert-Equal 4 (Get-Continued -Configuration (New-ContinuedConfiguration -ExcludeFile $otherExcludeFile)) 'another exclusion list starts the next generation'
    Assert-Equal 4 (Get-Continued -Configuration (New-ContinuedConfiguration -ExcludeFile (Join-Path $continuedRoot 'missing\excludes.txt'))) 'an exclusion list that can''t be read starts the next generation'
    $bumps = [ordered]@{
        'a failed run' = { param($r) $r.state = 'failed' }
        'an incomplete run' = { param($r) $r.state = 'partial' }
        'verification not finished' = { param($r) $r.verification_complete = $false }
        'verification recorded as text' = { param($r) $r.verification_complete = 'true' }
        'a generation recorded as text' = { param($r) $r.config_generation = '3' }
        'no snapshot' = { param($r) $r.snapshot_id = $null }
        'a short snapshot ID' = { param($r) $r.snapshot_id = 'cccccccc' }
        'another computer' = { param($r) $r.hostname = 'OTHER-PC' }
        'another backup location' = { param($r) $r.repository = Join-Path $continuedRoot 'Elsewhere' }
        'a backup location that is not a path' = { param($r) $r.repository = 'Backups' }
        'another storage kind' = { param($r) $r.repository_storage_mode = 'google_drivefs_stream' }
        'another drive under the backup location' = { param($r) $r.repository_volume_serial = '12345678' }
        'one folder fewer then' = { param($r) $r.sources = @($continuedSources[0], $continuedSources[2]) }
        'one folder more then' = { param($r) $r.sources = @($continuedSources + (Join-Path $continuedRoot 'Music')) }
        'another folder then' = { param($r) $r.sources = @((Join-Path $continuedRoot 'Music'), $continuedSources[1], $continuedSources[2]) }
        'a folder listed twice' = { param($r) $r.sources = @($continuedSources[0], $continuedSources[0], $continuedSources[2]) }
        'folders as one text' = { param($r) $r.sources = $continuedSources -join ';' }
        'a folder on another drive then' = { param($r) $r.source_identities[1].observed_volume_serial = '0BADC0DE' }
        'a drive that did not match' = { param($r) $r.source_identities[1].volume_identity = 'mismatch' }
        'a folder whose drive was not checked' = { param($r) $r.source_identities = @($r.source_identities[0], $r.source_identities[2]) }
        'a drive check listed twice' = { param($r) $r.source_identities = @($r.source_identities[0], $r.source_identities[0], $r.source_identities[2]) }
        'a drive check without its serial' = { param($r) $r.source_identities[0].Remove('observed_volume_serial') }
        'no exclusion list' = { param($r) $r.Remove('exclude_file_sha256') }
        'no folders' = { param($r) $r.Remove('sources') }
    }
    foreach ($label in $bumps.Keys) {
        Assert-Equal 4 (Get-Continued -Record (Edit-VerifiedBackupRecord $bumps[$label])) "the next generation after $label"
    }
    Assert-Equal 4 (Get-Continued -Record '{"state": "success"}') 'a record that says too little starts the next generation'
    Assert-Equal 4 (Get-Continued -Record '[]') 'a record that is not one starts the next generation'
    $moreFolders = @($continuedSources + (Join-Path $continuedRoot 'Music'))
    Assert-Equal 4 (Get-Continued -Configuration (New-ContinuedConfiguration -Sources $moreFolders)) 'a folder added at the reinstall starts the next generation'
    Assert-Equal 4 (Get-Continued -Configuration (New-ContinuedConfiguration -Sources $continuedSources[0, 2])) 'a folder left out at the reinstall starts the next generation'
    Assert-Equal 4 (Get-Continued -Configuration (New-ContinuedConfiguration -Serials @{ $continuedSources[0] = '0BADC0DE' })) 'a folder now on another drive starts the next generation'
    $otherPc = New-ContinuedConfiguration
    $otherPc['hostname'] = 'OTHER-PC'
    Assert-Equal 4 (Get-Continued -Configuration $otherPc) 'another computer name starts the next generation'
    $otherLocation = New-ContinuedConfiguration
    $otherLocation['repository'] = Join-Path $continuedRoot 'Elsewhere'
    Assert-Equal 4 (Get-Continued -Configuration $otherLocation) 'another backup location starts the next generation'
    $otherKind = New-ContinuedConfiguration
    $otherKind['repository_storage_mode'] = 'google_drivefs_stream'
    Assert-Equal 4 (Get-Continued -Configuration $otherKind) 'another kind of backup location starts the next generation'

    # --- from the state folder an uninstall keeps, through Get-PreservedPlanIdentity ---
    & {
        $stateRoot = Join-Path $workspace 'continued-state\ResticBackuper'
        $PlanOnly = $false
        function Get-FeedOwnerSid { param([string]$Path) return 'S-1-5-32-544' }
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        Write-Text -Path (Join-Path $stateRoot 'plan-state.json') -Text (ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; plan_id = $planId; config_generation = 3; updated_utc = '2026-11-09T02:00:00Z' }))
        Write-Text -Path (Join-Path $stateRoot 'last-success.json') -Text (ConvertTo-Json -InputObject (New-VerifiedBackupRecord) -Depth 6)
        Write-Text -Path (Join-Path $stateRoot 'status.json') -Text (ConvertTo-Json -InputObject (New-VerifiedBackupRecord) -Depth 6)
        $kept = Get-PreservedPlanIdentity
        Assert-Equal @($planId, 3, $continuedSnapshot) @($kept.plan_id, $kept.config_generation, $kept.last_success.snapshot_id) 'the kept plan comes with its latest verified backup'
        $continued = Get-ContinuedConfigGeneration -PreservedPlan $kept -Configuration (New-ContinuedConfiguration) -RepositoryKept $true
        Assert-Equal 3 $continued 'a reinstall over a backed-up installation, with the same choices, keeps its generation'

        # A run of a newer generation failed since (a folder was added, then the PC was reinstalled before a backup worked).
        $failed = New-VerifiedBackupRecord -Generation 4
        $failed.state = 'failed'
        $failed.verification_complete = $false
        Write-Text -Path (Join-Path $stateRoot 'status.json') -Text (ConvertTo-Json -InputObject $failed -Depth 6)
        $kept = Get-PreservedPlanIdentity
        Assert-Equal 4 $kept.config_generation 'the newest generation on record is the failed run''s'
        $continued = Get-ContinuedConfigGeneration -PreservedPlan $kept -Configuration (New-ContinuedConfiguration) -RepositoryKept $true
        Assert-Equal 5 $continued 'with a verified backup only of an older generation, the reinstall starts the next one'

        # Only the plan, as Test-InstallerContract.ps1 records it: no backup has been verified.
        Remove-Item -LiteralPath (Join-Path $stateRoot 'last-success.json'), (Join-Path $stateRoot 'status.json')
        $kept = Get-PreservedPlanIdentity
        Assert-True ($null -eq $kept.last_success) 'without last-success.json no verified backup comes with the kept plan'
        $continued = Get-ContinuedConfigGeneration -PreservedPlan $kept -Configuration (New-ContinuedConfiguration) -RepositoryKept $true
        Assert-Equal 4 $continued 'without a verified backup the reinstall starts the next generation, as before'
    }

    # ====================================================================================================================
    # 13b. How the backups open: with a password (the default, and what every earlier installation has) or without one
    # ====================================================================================================================
    # No record written before the choice existed says how the backups open, and that means a password everywhere. The functions
    # run in this process with stand-ins for the console and for the installed program; the plans run in child processes against
    # fixture roots. Nothing here starts an install, and the program a real install asks about the backups is never started.
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @(
        'Get-NormalizedPath', 'Get-RecordedRepositoryAccess', 'Test-SameFolderPath', 'Get-RecoveryToolsRepositoryAccess',
        'Get-ExistingRepositoryAccess', 'Get-RepositoryAccessDecision', 'Get-RepositoryAccessDifferenceMessage',
        'Assert-RepositoryAccessValue', 'Assert-NoPendingKeyChange', 'Resolve-RepositoryAccess', 'Get-NoPasswordWarning',
        'ConvertTo-RepositoryAccessChoice', 'Read-RepositoryAccessChoice', 'Invoke-RepositoryAccessQuestion',
        'Get-RepositoryAccessRefusalMessage', 'Get-RepositoryAccessFromDetectionExit', 'Get-RepositoryPhaseDetail',
        'Invoke-RepositoryAccessDetection', 'Get-InstallPhaseTitle', 'Start-InstallPhase', 'Complete-InstallPhase',
        'Skip-InstallPhase', 'Set-InitializationFailurePhase', 'Write-InstallSummary'))))
    $installPhaseTitles = $null
    $noPasswordPhaseTitles = $null
    foreach ($table in @('installPhaseTitles', 'noPasswordPhaseTitles')) {
        $tableText = [regex]::Match($installerText, '(?s)\$' + $table + ' = @\{.*?\n\}')
        Assert-True $tableText.Success "the installer's $table table is found"
        . ([scriptblock]::Create($tableText.Value))
    }
    $script:repositoryAccessMode = $null
    $script:existingRepositoryAccess = $null
    $script:repositoryAccessSource = $null
    $invocationParameters = @{}
    $RepositoryAccess = $null
    $PlanOnly = $false
    $Unattended = $false
    function Show-Value { param($Value) if ($null -eq $Value) { return '<null>' } return [string]$Value }

    # --- the reader of a record: an absent value means a password, and only the two exact spellings are believed ---
    foreach ($case in @(
        @('no repository_access', ([pscustomobject]@{ repository = 'x' }), 'password'),
        @('password', ([pscustomobject]@{ repository_access = 'password' }), 'password'),
        @('no_password', ([pscustomobject]@{ repository_access = 'no_password' }), 'no_password'),
        @('a capital letter', ([pscustomobject]@{ repository_access = 'Password' }), '<null>'),
        @('capitals', ([pscustomobject]@{ repository_access = 'NO_PASSWORD' }), '<null>'),
        @('a number', ([pscustomobject]@{ repository_access = 7 }), '<null>'),
        @('a boolean', ([pscustomobject]@{ repository_access = $true }), '<null>'),
        @('null', ([pscustomobject]@{ repository_access = $null }), '<null>'),
        @('an empty text', ([pscustomobject]@{ repository_access = '' }), '<null>'),
        @('a list', ([pscustomobject]@{ repository_access = @('password') }), '<null>')
    )) {
        Assert-Equal $case[2] (Show-Value (Get-RecordedRepositoryAccess -Record $case[1])) "a record with $($case[0]) means $($case[2])"
    }
    Assert-True ($null -eq (Get-RecordedRepositoryAccess -Record $null)) 'no record says nothing'

    # --- how the recovery tools next to the backups record them (both files must name this folder and agree) ---
    $accessUnit = Join-Path $workspace 'access-unit'
    $repositoryPath = Join-Path $accessUnit 'Backups'
    $recoveryTools = Join-Path $accessUnit 'RecoveryTools'
    $script:repositoryPreviouslyInitialized = $true
    function New-ToolsRecord {
        param([string]$Repository, $Access = '<absent>')
        $record = [ordered]@{ schema_version = 1; repository = $Repository }
        if (-not ($Access -is [string] -and $Access -ceq '<absent>')) { $record['repository_access'] = $Access }
        return $record
    }
    # Writes the seven files a real install leaves there; a record that is $null leaves that file out.
    function Set-ToolsFixture {
        param([string]$Folder = $recoveryTools, $Config, $Manifest)
        if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force }
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        foreach ($name in @('restic.exe', 'restore.py', 'secret_store.py', 'RECOVERY.md', 'restic-release.json')) {
            Write-Text -Path (Join-Path $Folder $name) -Text "fixture $name"
        }
        if ($null -ne $Config) { Write-KeptRecord -Folder $Folder -Name 'backup-config.json' -Record $Config }
        if ($null -ne $Manifest) { Write-KeptRecord -Folder $Folder -Name 'recovery-manifest.json' -Record $Manifest }
    }
    function Get-ToolsAccess { return (Show-Value (Get-RecoveryToolsRepositoryAccess)) }
    Remove-Item -LiteralPath $accessUnit -Recurse -Force -ErrorAction SilentlyContinue
    Assert-Equal '<null>' (Get-ToolsAccess) 'no recovery tools folder: nothing is recorded'
    New-Item -ItemType Directory -Path $recoveryTools -Force | Out-Null
    Write-Text -Path (Join-Path $recoveryTools 'RECOVERY.md') -Text 'only this'
    Assert-Equal '<null>' (Get-ToolsAccess) 'recovery tools with neither record: nothing is recorded'
    $own = New-ToolsRecord -Repository $repositoryPath
    $ownWithout = New-ToolsRecord -Repository $repositoryPath -Access 'no_password'
    $ownWith = New-ToolsRecord -Repository $repositoryPath -Access 'password'
    foreach ($case in @(
        @('both without repository_access (an older installation)', $own, $own, 'password'),
        @('both naming a password', $ownWith, $ownWith, 'password'),
        @('both naming no password', $ownWithout, $ownWithout, 'no_password'),
        @('no password in one, nothing in the other', $ownWithout, $own, 'unknown'),
        @('no password in one, a password in the other', $ownWithout, $ownWith, 'unknown'),
        @('a password in one, no password in the other', $ownWith, $ownWithout, 'unknown'),
        @('a capital letter in both', (New-ToolsRecord -Repository $repositoryPath -Access 'Password'), (New-ToolsRecord -Repository $repositoryPath -Access 'Password'), 'unknown'),
        @('a number in one', $own, (New-ToolsRecord -Repository $repositoryPath -Access 7), 'unknown'),
        @('the other folder in one', (New-ToolsRecord -Repository (Join-Path $accessUnit 'Elsewhere')), $own, 'unknown'),
        @('the other folder in the other', $own, (New-ToolsRecord -Repository (Join-Path $accessUnit 'Elsewhere')), 'unknown'),
        @('this folder spelled in capitals in both', (New-ToolsRecord -Repository $repositoryPath.ToUpperInvariant() -Access 'no_password'), (New-ToolsRecord -Repository $repositoryPath.ToUpperInvariant() -Access 'no_password'), 'no_password'),
        @('no repository in one', ([ordered]@{ schema_version = 1 }), $own, 'unknown'),
        @('a number for the repository', ([ordered]@{ schema_version = 1; repository = 42 }), $own, 'unknown'),
        @('a list in one', '[1, 2]', $own, 'unknown'),
        @('text that is not JSON in one', $own, '{not json', 'unknown'),
        @('an empty file in one', '', $own, 'unknown'),
        @('JSON null in one', 'null', $own, 'unknown')
    )) {
        Set-ToolsFixture -Config $case[1] -Manifest $case[2]
        Assert-Equal $case[3] (Get-ToolsAccess) "recovery tools with $($case[0]) say $($case[3])"
    }
    Set-ToolsFixture -Config $own -Manifest $null
    Assert-Equal 'unknown' (Get-ToolsAccess) 'recovery tools with only the configuration say unknown'
    Set-ToolsFixture -Config $null -Manifest $own
    Assert-Equal 'unknown' (Get-ToolsAccess) 'recovery tools with only the manifest say unknown'

    # --- how the backups already in the chosen folder are recorded: the kept record, then the recovery tools, then unknown ---
    $stateRoot = Join-Path $workspace 'kept-unit\ResticBackuper'
    $secretFile = Join-Path $stateRoot 'repository-password.dpapi.json'
    $keptHere = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = $repositoryPath; repository_storage_mode = 'local_ntfs' }
    $keptHereWithout = Copy-Record $keptHere @{ repository_access = 'no_password' }
    $keptElsewhere = [ordered]@{ schema_version = 1; initialized_utc = '2026-09-01T10:00:00Z'; repository = (Join-Path $accessUnit 'Elsewhere'); repository_storage_mode = 'local_ntfs'; repository_access = 'no_password' }
    function Get-ExistingAccess { return (Show-Value (Use-KeptStateOwner { Get-ExistingRepositoryAccess })) }
    Reset-KeptState -Records @{ 'repository.json' = $keptHereWithout }
    Set-ToolsFixture -Config $ownWith -Manifest $ownWith
    $script:repositoryPreviouslyInitialized = $false
    Assert-Equal '<null>' (Get-ExistingAccess) 'a location that holds no backups has no recorded way of opening them, whatever the records say'
    $script:repositoryPreviouslyInitialized = $true
    Assert-Equal 'no_password' (Get-ExistingAccess) 'the kept record that names this folder wins over the recovery tools'
    Reset-KeptState -Records @{ 'repository.json' = (Copy-Record $keptHere) }
    Assert-Equal 'password' (Get-ExistingAccess) 'a kept record that does not say how the backups open means a password'
    Reset-KeptState -Records @{ 'repository.json' = $keptHereWithout } -NoSecret
    Assert-Equal 'no_password' (Get-ExistingAccess) 'backups without a password are found in the kept record without any stored password'
    Reset-KeptState -Records @{ 'repository.json' = $keptElsewhere }
    Set-ToolsFixture -Config $ownWithout -Manifest $ownWithout
    Assert-Equal 'no_password' (Get-ExistingAccess) 'a kept record for another folder is passed over for the recovery tools'
    Set-ToolsFixture -Config $ownWith -Manifest $ownWith
    Assert-Equal 'password' (Get-ExistingAccess) 'the recovery tools say a password'
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force
    Assert-Equal 'unknown' (Get-ExistingAccess) 'a folder with backups that no record describes is unknown'
    Reset-KeptState
    Assert-Equal 'unknown' (Get-ExistingAccess) 'no kept state and no recovery tools: unknown'
    Reset-KeptState -Records @{ 'repository.json' = (Copy-Record $keptHere) } -NoSecret
    Set-ToolsFixture -Config $ownWithout -Manifest $ownWithout
    Assert-Equal 'no_password' (Get-ExistingAccess) 'a kept record of backups with a password and no stored password is not used, so the recovery tools answer'
    $keptHereCapitals = Copy-Record $keptHere @{ repository = $repositoryPath.ToUpperInvariant(); repository_access = 'no_password' }
    Reset-KeptState -Records @{ 'repository.json' = $keptHereCapitals }
    Set-ToolsFixture -Config $ownWith -Manifest $ownWith
    Assert-Equal 'no_password' (Get-ExistingAccess) 'the kept record names the folder as Windows compares names, not letter for letter'

    # --- the choice that is made ---
    foreach ($case in @(
        @('a password was asked for, backups without one are recorded', 'password', 'no_password', 'password', 'parameter'),
        @('no password was asked for, backups with one are recorded', 'no_password', 'password', 'no_password', 'parameter'),
        @('nothing asked, a password recorded', '', 'password', 'password', 'recorded'),
        @('nothing asked, no password recorded', '', 'no_password', 'no_password', 'recorded'),
        @('nothing asked, backups no record describes', '', 'unknown', '<null>', '<null>'),
        @('nothing asked, no backups', '', '', 'password', 'default'),
        @('no password asked for, no backups', 'no_password', '', 'no_password', 'parameter'),
        @('no password asked for, backups no record describes', 'no_password', 'unknown', 'no_password', 'parameter')
    )) {
        $decision = Get-RepositoryAccessDecision -Given $case[1] -Existing $case[2]
        Assert-Equal @($case[3], $case[4]) @((Show-Value $decision.access), (Show-Value $decision.source)) "the decision when $($case[0])"
    }
    $noPasswordDiffers = 'The backups in this location were made without a password. If they still open without one, Setup stops before changing anything. Choose no password to continue them, or choose another location.'
    $passwordDiffers = 'The backups in this location were made with a password. If they still need one, Setup stops before changing anything. Choose a password to continue them, or choose another location.'
    Assert-Equal $noPasswordDiffers (Get-RepositoryAccessDifferenceMessage -Existing 'no_password' -Chosen 'password') 'a password asked for over backups without one is warned about'
    Assert-Equal $passwordDiffers (Get-RepositoryAccessDifferenceMessage -Existing 'password' -Chosen 'no_password') 'no password asked for over backups with one is warned about'
    foreach ($pair in @(@('password', 'password'), @('no_password', 'no_password'), @('unknown', 'password'), @('unknown', 'no_password'), @('', 'password'), @('password', ''))) {
        Assert-True ($null -eq (Get-RepositoryAccessDifferenceMessage -Existing $pair[0] -Chosen $pair[1])) "nothing contradicts when '$($pair[0])' is recorded and '$($pair[1])' is chosen"
    }

    # --- the parameter is checked in exact case ---
    $invocationParameters = @{ RepositoryAccess = 'x' }
    foreach ($value in @('No_Password', 'PASSWORD', 'Password', 'NO_PASSWORD', 'no password', '')) {
        $RepositoryAccess = $value
        Assert-Equal 'repository_access_invalid' (Get-FindingCode { Assert-RepositoryAccessValue }) "'$value' is refused for the case it is written in"
    }
    foreach ($value in @('password', 'no_password')) {
        $RepositoryAccess = $value
        Assert-Equal 'no-finding' (Get-FindingCode { Assert-RepositoryAccessValue }) "'$value' is accepted"
    }
    $invocationParameters = @{}
    $RepositoryAccess = 'Whatever'
    Assert-Equal 'no-finding' (Get-FindingCode { Assert-RepositoryAccessValue }) 'a parameter that was not given is not checked'
    $RepositoryAccess = $null

    # --- Resolve-RepositoryAccess puts it together and starts afresh each time ---
    function Resolve-Access {
        param($Given, [bool]$Initialized)
        $invocationParameters = if ($null -ne $Given) { @{ RepositoryAccess = $Given } } else { @{} }
        $RepositoryAccess = $Given
        $script:repositoryPreviouslyInitialized = $Initialized
        $code = Get-FindingCode { Use-KeptStateOwner { Resolve-RepositoryAccess } }
        return [pscustomobject]@{ Code = $code; Access = (Show-Value $script:repositoryAccessMode); Source = (Show-Value $script:repositoryAccessSource); Existing = (Show-Value $script:existingRepositoryAccess) }
    }
    Reset-KeptState
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force -ErrorAction SilentlyContinue
    $resolved = Resolve-Access -Given $null -Initialized $false
    Assert-Equal @('no-finding', 'password', 'default', '<null>') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'a new location, nothing asked: a password by default'
    $resolved = Resolve-Access -Given 'no_password' -Initialized $false
    Assert-Equal @('no-finding', 'no_password', 'parameter', '<null>') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'a new location, no password asked for'
    $resolved = Resolve-Access -Given 'password' -Initialized $false
    Assert-Equal @('no-finding', 'password', 'parameter', '<null>') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'a new location, a password asked for'
    Set-ToolsFixture -Config $ownWithout -Manifest $ownWithout
    $resolved = Resolve-Access -Given $null -Initialized $true
    Assert-Equal @('no-finding', 'no_password', 'recorded', 'no_password') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'existing backups without a password keep their way'
    $resolved = Resolve-Access -Given 'password' -Initialized $true
    Assert-Equal @('no-finding', 'password', 'parameter', 'no_password') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'a contradicting choice is kept as asked, so the install can refuse it, and the record is reported beside it'
    $resolved = Resolve-Access -Given $null -Initialized $false
    Assert-Equal @('no-finding', 'password', 'default', '<null>') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'nothing is carried over from an earlier resolution'
    Set-ToolsFixture -Config $own -Manifest $own
    $resolved = Resolve-Access -Given $null -Initialized $true
    Assert-Equal @('no-finding', 'password', 'recorded', 'password') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'existing backups recorded before the choice existed keep their password'
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force
    $resolved = Resolve-Access -Given $null -Initialized $true
    Assert-Equal @('no-finding', '<null>', '<null>', 'unknown') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'existing backups that no record describes are left for the install to ask'
    $resolved = Resolve-Access -Given 'no_password' -Initialized $true
    Assert-Equal @('no-finding', 'no_password', 'parameter', 'unknown') @($resolved.Code, $resolved.Access, $resolved.Source, $resolved.Existing) 'an unknown way of opening is no reason to refuse a choice'
    $resolved = Resolve-Access -Given 'No_Password' -Initialized $false
    Assert-Equal 'repository_access_invalid' $resolved.Code 'a choice in the wrong case stops the resolution'

    # An unfinished change to the keys of earlier backups can only be finished with a password.
    Reset-KeptState
    Write-Text -Path (Join-Path $stateRoot 'credential-rotation.journal.json') -Text '{}'
    Assert-Equal 'repository_access_rotation_pending' (Resolve-Access -Given 'no_password' -Initialized $false).Code 'no password is refused while a change of the keys is waiting'
    Assert-Equal 'no-finding' (Resolve-Access -Given $null -Initialized $false).Code 'a password is no problem while a change of the keys is waiting'
    Assert-Equal 'no-finding' (Resolve-Access -Given 'password' -Initialized $true).Code 'asking for a password is no problem either'
    Set-ToolsFixture -Config $ownWithout -Manifest $ownWithout
    Assert-Equal 'repository_access_rotation_pending' (Resolve-Access -Given $null -Initialized $true).Code 'backups without a password that are recorded so are refused too'
    $script:repositoryAccessMode = 'password'
    Assert-True ($null -eq $(try { Assert-NoPendingKeyChange } catch { 'refused' })) 'with a password nothing is refused'
    $script:repositoryAccessMode = 'no_password'
    $finding = $(try { Assert-NoPendingKeyChange } catch { Get-InstallFinding -ErrorRecord $_ })
    Assert-Equal @('repository_access_rotation_pending', 'repository', $stateRoot) @($finding.code, $finding.field, $finding.path) 'the refusal names the field and the state folder'
    Assert-True ($finding.message.Contains('To finish it, run Setup with a password') -and $finding.message.Contains($stateRoot) -and $finding.message.Contains('move the folder')) 'the refusal says what to do'
    $script:repositoryAccessMode = $null
    Assert-True ($null -eq $(try { Assert-NoPendingKeyChange } catch { 'refused' })) 'while the mode is not known nothing is refused'
    Reset-KeptState
    Remove-Item -LiteralPath $recoveryTools -Recurse -Force -ErrorAction SilentlyContinue

    # --- the console: what is said, and what a typed answer means ---
    foreach ($answer in @('y', 'Y', 'yes', 'YES', 'Yes', ' yes ')) {
        Assert-Equal 'no_password' (Show-Value (ConvertTo-RepositoryAccessChoice -Answer $answer)) "'$answer' chooses no password"
    }
    foreach ($answer in @('', ' ', 'n', 'N', 'no', 'NO', 'No')) {
        Assert-Equal 'password' (Show-Value (ConvertTo-RepositoryAccessChoice -Answer $answer)) "'$answer' keeps the password"
    }
    Assert-Equal 'password' (Show-Value (ConvertTo-RepositoryAccessChoice -Answer $null)) 'pressing Enter with nothing typed keeps the password'
    foreach ($answer in @('maybe', 'yess', 'ye', '1', 'nope', 'y e s', 'password', 'no_password')) {
        Assert-True ($null -eq (ConvertTo-RepositoryAccessChoice -Answer $answer)) "'$answer' is not an answer"
    }
    function Invoke-ConsoleScript {
        # Runs the action with stand-ins for the console and returns what was said and asked, in order.
        param([scriptblock]$Action, [string[]]$Answers = @())
        $script:consoleEvents = [Collections.Generic.List[string]]::new()
        $script:consoleAnswers = [Collections.Generic.Queue[string]]::new([string[]]$Answers)
        & {
            function Read-Host {
                param([string]$Prompt)
                $script:consoleEvents.Add('ask: ' + $Prompt)
                if ($script:consoleAnswers.Count -eq 0) { throw 'The console was asked more than the test planned.' }
                return $script:consoleAnswers.Dequeue()
            }
            function Write-Host { param([object]$Object, [string]$ForegroundColor) $script:consoleEvents.Add('say: ' + [string]$Object) }
            function Write-Warning { param([string]$Message) $script:consoleEvents.Add('warn: ' + $Message) }
            & $Action
        } | Out-Null
        return ,@($script:consoleEvents)
    }
    $noPasswordWarning = 'Anyone who can open the backup folder can restore every backed-up file, including saved sign-ins. That includes the folder in Google Drive or on a lost USB drive.'
    $askText = 'ask: Make backups without a password? Type yes for no password, or press Enter to keep the password (recommended)'
    Assert-Equal $noPasswordWarning (Get-NoPasswordWarning) 'the sentences said before the choice are the owner''s own'
    $events = Invoke-ConsoleScript -Answers @('maybe', 'YES') -Action { $script:answerChoice = Read-RepositoryAccessChoice }
    Assert-Equal 'no_password' $script:answerChoice 'a yes after a wrong answer chooses no password'
    Assert-Equal @($askText, $askText) @($events | Where-Object { $_.StartsWith('ask: ') }) 'it asks the same question until the answer is one it understands'
    Assert-True ($events.IndexOf('say: ' + $noPasswordWarning) -ge 0 -and $events.IndexOf('say: ' + $noPasswordWarning) -lt $events.IndexOf($askText)) 'the consequence is said before the question'
    Assert-True ($events.IndexOf('say: You can''t change this later for these backups.') -ge 0 -and $events.IndexOf('say: You can''t change this later for these backups.') -lt $events.IndexOf($askText)) 'and so is the fact that it can''t be changed later'
    Assert-Equal 1 @($events | Where-Object { $_ -ceq 'say: Please type yes or no, or press Enter.' }).Count 'a wrong answer is told once to try again'
    $events = Invoke-ConsoleScript -Answers @('') -Action { $script:answerChoice = Read-RepositoryAccessChoice }
    Assert-Equal 'password' $script:answerChoice 'Enter keeps the password'
    $PlanOnly = $true
    $events = Invoke-ConsoleScript -Action { $script:answerChoice = Read-RepositoryAccessChoice }
    Assert-True ($null -eq $script:answerChoice -and $events.Count -eq 0) 'a plan asks nothing and says nothing'
    $PlanOnly = $false
    $Unattended = $true
    $events = Invoke-ConsoleScript -Action { $script:answerChoice = Read-RepositoryAccessChoice }
    Assert-True ($null -eq $script:answerChoice -and $events.Count -eq 0) 'an unattended run asks nothing and says nothing'
    $Unattended = $false

    # The question is asked only for a location without backups and with nothing asked for on the command line.
    function Set-Resolved { param($Mode, $Source) $script:repositoryAccessMode = $Mode; $script:repositoryAccessSource = $Source }
    Set-Resolved 'password' 'default'
    $events = Invoke-ConsoleScript -Answers @('yes') -Action { Invoke-RepositoryAccessQuestion }
    Assert-Equal @('no_password', 'prompt') @($script:repositoryAccessMode, $script:repositoryAccessSource) 'a yes to the question chooses no password, and the choice came from the prompt'
    Set-Resolved 'password' 'default'
    $events = Invoke-ConsoleScript -Answers @('') -Action { Invoke-RepositoryAccessQuestion }
    Assert-Equal @('password', 'prompt') @($script:repositoryAccessMode, $script:repositoryAccessSource) 'Enter keeps the password, and that too was the person''s choice'
    Set-Resolved 'password' 'default'
    $Unattended = $true
    $events = Invoke-ConsoleScript -Action { Invoke-RepositoryAccessQuestion }
    $Unattended = $false
    Assert-True ($events.Count -eq 0 -and $script:repositoryAccessMode -ceq 'password' -and $script:repositoryAccessSource -ceq 'default') 'an unattended run keeps the default without asking'
    foreach ($case in @(@('parameter', 'no_password'), @('parameter', 'password'), @('detected', 'password'), @('prompt', 'password'))) {
        Set-Resolved $case[1] $case[0]
        $events = Invoke-ConsoleScript -Action { Invoke-RepositoryAccessQuestion }
        Assert-Equal 0 $events.Count "nothing is asked or said when the choice came from '$($case[0])' ($($case[1]))"
    }
    Set-Resolved 'password' 'recorded'
    $events = Invoke-ConsoleScript -Action { Invoke-RepositoryAccessQuestion }
    Assert-Equal @('say: These backups were made with a password, so Setup keeps them that way.') $events 'backups with a password are said to be kept that way'
    Set-Resolved 'no_password' 'recorded'
    $events = Invoke-ConsoleScript -Action { Invoke-RepositoryAccessQuestion }
    Assert-Equal @('say: These backups were made without a password, so Setup keeps them that way.') $events 'backups without a password are said to be kept that way'
    Set-Resolved $null $null
    $events = Invoke-ConsoleScript -Action { Invoke-RepositoryAccessQuestion }
    Assert-Equal @('say: Setup will check whether these backups have a password and keep them that way.') $events 'backups no record describes are said to be checked'
    Reset-KeptState
    Write-Text -Path (Join-Path $stateRoot 'credential-rotation.journal.json') -Text '{}'
    Set-Resolved 'password' 'default'
    Assert-Equal 'repository_access_rotation_pending' (Get-FindingCode { [void](Invoke-ConsoleScript -Answers @('yes') -Action { Invoke-RepositoryAccessQuestion }) }) 'choosing no password at the prompt is refused while a change of the keys is waiting'
    Reset-KeptState
    $script:repositoryAccessMode = $null
    $script:repositoryAccessSource = $null

    # --- what Setup says when the backups don't open the way it expected ---
    $ending = ' Setup undid its changes, and your backups were not touched.'
    $chosenWithPassword = 'The backups in this location are protected by a password, but you chose no password. To continue these backups, choose a password. To start without one, choose another location.' + $ending
    $chosenWithoutPassword = 'The backups in this location were made without a password, but you chose a password. To continue these backups, choose no password. To start with a password, choose another location.' + $ending
    $changedOutside = 'These backups no longer match what Setup recorded for them, usually because they were changed outside Rewindle. Setup can''t carry on with them here. Choose another location, or see Switching an existing backup in Rewindle''s guide.' + $ending
    $unreadable = 'Setup couldn''t open the backups in this location to continue them. Check that the backup drive or Google Drive folder is connected and available, then try again.' + $ending
    foreach ($source in @('parameter', 'prompt', 'default')) {
        Assert-Equal $chosenWithPassword (Get-RepositoryAccessRefusalMessage -ExitCode 4 -Source $source) "exit 4, choice from '$source'"
        Assert-Equal $chosenWithoutPassword (Get-RepositoryAccessRefusalMessage -ExitCode 5 -Source $source) "exit 5, choice from '$source'"
    }
    foreach ($source in @('recorded', 'detected')) {
        foreach ($exit in @(4, 5)) {
            Assert-Equal $changedOutside (Get-RepositoryAccessRefusalMessage -ExitCode $exit -Source $source) "exit $exit, choice from '$source': the records no longer match"
        }
    }
    foreach ($source in @('parameter', 'prompt', 'recorded', 'detected', 'default')) {
        Assert-Equal $unreadable (Get-RepositoryAccessRefusalMessage -ExitCode 6 -Source $source) "exit 6, choice from '$source'"
    }
    foreach ($message in @($chosenWithPassword, $chosenWithoutPassword, $changedOutside, $unreadable)) {
        Assert-True (-not $message.ToLowerInvariant().Contains('restic') -and -not $message.ToLowerInvariant().Contains('snapshot') -and -not $message.ToLowerInvariant().Contains('repository')) 'a refusal uses plain words'
    }

    # --- the installed program is asked which way unknown backups open, and only that ---
    $script:detectionCalls = [Collections.Generic.List[object]]::new()
    $script:detectionExit = 0
    function Invoke-ProtectedPython {
        param([string]$Python, [string[]]$Arguments, [string]$WorkingDirectory, [string]$TemporaryDirectory)
        $script:detectionCalls.Add([pscustomobject]@{ Python = $Python; Arguments = @($Arguments); WorkingDirectory = $WorkingDirectory; TemporaryDirectory = $TemporaryDirectory })
        return $script:detectionExit
    }
    $installRoot = 'C:\Fixture\Program Files\ResticBackuper'
    $python = Join-Path $installRoot 'Python\python.exe'
    $initializer = Join-Path $installRoot 'initialize_repository.py'
    $script:protectedTemporaryFolder = 'C:\Fixture\ProgramData\RewindleSetup-fixture'
    foreach ($case in @(@(20, 'no_password', 'detected'), @(21, 'password', 'detected'), @(22, 'password', 'default'))) {
        $script:detectionCalls.Clear()
        $script:detectionExit = $case[0]
        $script:repositoryAccessMode = $null
        $script:repositoryAccessSource = $null
        Invoke-RepositoryAccessDetection
        Assert-Equal @($case[1], $case[2]) @($script:repositoryAccessMode, $script:repositoryAccessSource) "the program's answer $($case[0]) means $($case[1]) ($($case[2]))"
        Assert-Equal 1 $script:detectionCalls.Count "one question is asked of the program (answer $($case[0]))"
    }
    $asked = $script:detectionCalls[0]
    Assert-Equal @($python, $installRoot, $script:protectedTemporaryFolder) @($asked.Python, $asked.WorkingDirectory, $asked.TemporaryDirectory) 'the installed Python is run from the program folder with the protected temporary folder'
    Assert-Equal @('-I', '-S', '-B', $initializer, '--detect-access', '--repository', $repositoryPath, '--restic', (Join-Path $installRoot 'restic.exe')) @($asked.Arguments) 'the question names the backup folder and the installed Restic'
    foreach ($exit in @(0, 1, 2, 6, 23, 137, -1)) {
        $script:detectionExit = $exit
        $script:repositoryAccessMode = $null
        $script:repositoryAccessSource = $null
        $finding = $(try { Invoke-RepositoryAccessDetection } catch { Get-InstallFinding -ErrorRecord $_ })
        Assert-True ($null -ne $finding -and $finding.code -ceq 'repository_access_unreadable' -and $finding.field -ceq 'repository') "an answer of $exit means the backups could not be read"
        Assert-Equal $unreadable $finding.message "the answer $exit is explained in the words for backups that can't be opened"
        Assert-True ($null -eq $script:repositoryAccessMode) "nothing is decided from an answer of $exit"
    }
    Reset-KeptState
    Write-Text -Path (Join-Path $stateRoot 'credential-rotation.journal.json') -Text '{}'
    $script:detectionExit = 20
    Assert-Equal 'repository_access_rotation_pending' (Get-FindingCode { Invoke-RepositoryAccessDetection }) 'backups without a password found while a change of the keys is waiting are refused'
    $script:detectionExit = 21
    Assert-Equal 'no-finding' (Get-FindingCode { Invoke-RepositoryAccessDetection }) 'backups with a password found while a change of the keys is waiting are not'
    Reset-KeptState
    Remove-Item -LiteralPath 'function:Invoke-ProtectedPython'
    $script:repositoryAccessMode = $null
    $script:repositoryAccessSource = $null
    foreach ($case in @(@(20, 'no_password', 'detected'), @(21, 'password', 'detected'), @(22, 'password', 'default'))) {
        $found = Get-RepositoryAccessFromDetectionExit -ExitCode $case[0]
        Assert-Equal @($case[1], $case[2]) @($found.access, $found.source) "the answer $($case[0]) of the program"
    }
    foreach ($exit in @(0, 1, 2, 3, 4, 5, 6, 19, 23, 255, -1)) {
        Assert-True ($null -eq (Get-RepositoryAccessFromDetectionExit -ExitCode $exit)) "the answer $exit of the program is not one of the three"
    }

    # --- what the repository phase says, and what the phases are called ---
    $script:repositoryPreviouslyInitialized = $false
    foreach ($mode in @('password', 'no_password')) {
        $script:repositoryAccessMode = $mode
        $script:repositoryAccessSource = 'parameter'
        Assert-True ($null -eq (Get-RepositoryPhaseDetail)) "a new backup location says nothing special ($mode)"
    }
    $script:repositoryPreviouslyInitialized = $true
    $keptAndReused = 'Your existing backups in this location were kept and reused.'
    foreach ($case in @(
        @('password', 'recorded', $keptAndReused),
        @('password', 'default', $keptAndReused),
        @('password', 'parameter', $keptAndReused),
        @('no_password', 'recorded', "$keptAndReused They have no password."),
        @('no_password', 'parameter', "$keptAndReused They have no password."),
        @('password', 'detected', "$keptAndReused They have a password, so Setup kept that."),
        @('no_password', 'detected', "$keptAndReused They have no password, so Setup kept that.")
    )) {
        $script:repositoryAccessMode = $case[0]
        $script:repositoryAccessSource = $case[1]
        Assert-Equal $case[2] (Get-RepositoryPhaseDetail) "the repository phase for $($case[0]) chosen by '$($case[1])'"
    }
    $script:repositoryPreviouslyInitialized = $false
    foreach ($mode in @('password', $null)) {
        $script:repositoryAccessMode = $mode
        foreach ($phase in @($installPhaseTitles.Keys)) {
            Assert-Equal $installPhaseTitles[$phase] (Get-InstallPhaseTitle -Phase $phase) "the title of '$phase' for $(Show-Value $mode) is the usual one"
        }
    }
    $script:repositoryAccessMode = 'no_password'
    Assert-Equal @('credential', 'recovery_key', 'repository') @($noPasswordPhaseTitles.Keys | Sort-Object) 'only the three phases about a password, a location and a key are renamed'
    foreach ($phase in @($installPhaseTitles.Keys)) {
        $expected = if ($noPasswordPhaseTitles.ContainsKey($phase)) { $noPasswordPhaseTitles[$phase] } else { $installPhaseTitles[$phase] }
        Assert-Equal $expected (Get-InstallPhaseTitle -Phase $phase) "the title of '$phase' for backups without a password"
    }
    Assert-Equal @('Choosing no password', 'Creating the backup location', 'Saving the recovery tools') @($noPasswordPhaseTitles['credential'], $noPasswordPhaseTitles['repository'], $noPasswordPhaseTitles['recovery_key']) 'the titles for backups without a password'
    foreach ($title in @($noPasswordPhaseTitles.Values)) {
        Assert-True (-not $title.ToLowerInvariant().Contains('encrypted') -and -not $title.ToLowerInvariant().Contains('recovery key')) "'$title' makes no claim about encryption or a key"
    }

    # --- the feed names the phases, with the titles of the mode ---
    $initRepository = Join-Path $workspace 'init-state\Backups'
    $secretFile = Join-Path $workspace 'init-state\ResticBackuper\repository-password.dpapi.json'
    $repositoryPath = $initRepository
    function Get-InitializationFeed {
        param([string]$Name, [string]$Mode, [bool]$SecretExists, [bool]$ConfigExists, [string]$Started)
        foreach ($path in @($secretFile, (Join-Path $initRepository 'config'))) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if ($SecretExists) { Write-Text -Path $secretFile -Text '{}' }
        if ($ConfigExists) { Write-Text -Path (Join-Path $initRepository 'config') -Text 'a restic repository config' }
        $script:repositoryAccessMode = $Mode
        $script:FeedResultWritten = $false
        $path = Join-Path $feedDirectory "init-$Name.jsonl"
        Open-ProgressFeed -Path $path -ExpectedSid $currentSid
        Start-InstallPhase $Started
        Set-InitializationFailurePhase
        Close-ProgressFeed
        return @([IO.File]::ReadAllLines($path) | ForEach-Object { $_ | ConvertFrom-Json } | ForEach-Object { '{0} {1} {2}' -f $_.phase, $_.state, $_.title })
    }
    Assert-Equal @('credential started Creating the backup password and storing it for your account') (Get-InitializationFeed -Name 'password-nothing' -Mode 'password' -SecretExists $false -ConfigExists $false -Started 'credential') 'with a password and nothing on disk the credential phase is the one that failed'
    Assert-Equal @(
        'credential started Creating the backup password and storing it for your account',
        'credential completed Creating the backup password and storing it for your account',
        'repository started Creating the encrypted backup location'
    ) (Get-InitializationFeed -Name 'password-secret' -Mode 'password' -SecretExists $true -ConfigExists $false -Started 'credential') 'with a password and a stored password the repository phase is the one that failed'
    Assert-Equal @(
        'credential started Creating the backup password and storing it for your account',
        'credential completed Creating the backup password and storing it for your account',
        'repository started Creating the encrypted backup location',
        'repository completed Creating the encrypted backup location',
        'recovery_key started Writing your recovery key'
    ) (Get-InitializationFeed -Name 'password-config' -Mode 'password' -SecretExists $true -ConfigExists $true -Started 'credential') 'with a password and a backup location the recovery key phase is the one that failed'
    # Without a password nothing is inferred from the place the stored password would be, whatever an earlier install left there.
    Assert-Equal @('repository started Creating the backup location') (Get-InitializationFeed -Name 'none-secret' -Mode 'no_password' -SecretExists $true -ConfigExists $false -Started 'repository') 'without a password an older stored password changes nothing: the repository phase is the one that failed'
    Assert-Equal @('repository started Creating the backup location') (Get-InitializationFeed -Name 'none-nothing' -Mode 'no_password' -SecretExists $false -ConfigExists $false -Started 'repository') 'without a password and nothing on disk the repository phase is the one that failed'
    Assert-Equal @(
        'repository started Creating the backup location',
        'repository completed Creating the backup location',
        'recovery_key started Saving the recovery tools'
    ) (Get-InitializationFeed -Name 'none-config' -Mode 'no_password' -SecretExists $true -ConfigExists $true -Started 'repository') 'without a password a backup location on disk means the recovery tools are what failed'
    $script:repositoryAccessMode = $null

    # --- the summary before the confirmation ---
    function Get-SummaryEvents {
        param($Mode)
        $version = '9.9.9-fixture.1'
        $repositoryPath = 'D:\Backups'
        $RepositoryStorageMode = 'local_ntfs'
        $sources = @('C:\Documents')
        $canaryAlreadyCovered = $true
        $canarySource = 'C:\Canary'
        $Schedule = '02:00'
        $useVss = $true
        $SkipDashboard = $false
        $script:repositoryAccessMode = $Mode
        return (Invoke-ConsoleScript -Action { Write-InstallSummary })
    }
    $summaryEvents = Get-SummaryEvents -Mode 'password'
    Assert-True ($summaryEvents -contains 'say:   Password   : yes (recommended)') 'the summary says a password is used, and that it is recommended'
    Assert-Equal 0 @($summaryEvents | Where-Object { $_.StartsWith('warn: ') }).Count 'a password raises no warning'
    $summaryEvents = Get-SummaryEvents -Mode 'no_password'
    Assert-True ($summaryEvents -contains 'say:   Password   : none') 'the summary says there is no password'
    Assert-Equal @('warn: ' + $noPasswordWarning) @($summaryEvents | Where-Object { $_.StartsWith('warn: ') }) 'and warns in the owner''s own words'
    Assert-True ($summaryEvents.IndexOf('say:   Password   : none') -lt $summaryEvents.IndexOf('say:   Sources    : 1')) 'the password line comes before the folders'
    $summaryEvents = Get-SummaryEvents -Mode $null
    Assert-True ($summaryEvents -contains 'say:   Password   : the same as the backups already in this location') 'backups that no record describes are said to keep their way'
    Assert-Equal 0 @($summaryEvents | Where-Object { $_.StartsWith('warn: ') }).Count 'and raise no warning'
    $script:repositoryAccessMode = $null

    # ----- plans, in child processes against fixture roots -----
    $accessCases = Join-Path $workspace 'access-cases'
    $accessBase = @('-SourceList', "$docs;$photos", '-MinimumFreeGiB', '1', '-Schedule', '03:30')
    function Get-AccessPlan {
        param([string]$Repository, [string[]]$Extra = @(), $RootsSet = $roots)
        return (Invoke-Plan -Bundle $bundle -Roots $RootsSet -Temp $temp -Arguments (@('-Repository', $Repository) + $accessBase + $Extra))
    }
    # Backups that exist: a Restic config file, and the recovery tools Setup leaves next to them.
    function New-ExistingBackups {
        param([string]$Name, $Config, $Manifest, [switch]$NoTools)
        $parent = Join-Path $accessCases $Name
        $repository = Join-Path $parent 'Backups'
        Write-Text -Path (Join-Path $repository 'config') -Text 'a restic repository config'
        if (-not $NoTools) {
            $configRecord = if ($Config -is [string] -and $Config -ceq '<absent>') { New-ToolsRecord -Repository $repository } else { New-ToolsRecord -Repository $repository -Access $Config }
            $manifestRecord = if ($Manifest -is [string] -and $Manifest -ceq '<absent>') { New-ToolsRecord -Repository $repository } else { New-ToolsRecord -Repository $repository -Access $Manifest }
            Set-ToolsFixture -Folder (Join-Path $parent 'RecoveryTools') -Config $configRecord -Manifest $manifestRecord
        }
        return $repository
    }
    function Show-Plan {
        param($Run)
        Assert-Equal 0 $Run.ExitCode "the plan is written (stderr: $($Run.Error))"
        return [pscustomobject]@{
            Access = (Show-Value $Run.Plan.resolved.repository_access)
            Existing = (Show-Value $Run.Plan.resolved.existing_repository_access)
            Errors = @(Get-ErrorCodes $Run.Plan)
            Warnings = @(Get-WarningCodes $Run.Plan)
        }
    }
    $freshAccess = Join-Path $accessCases 'fresh\Backups'
    $defaultPlan = Show-Plan (Get-AccessPlan -Repository $freshAccess)
    Assert-Equal @('password', '<null>') @($defaultPlan.Access, $defaultPlan.Existing) 'a plan for a new location, with nothing asked, resolves to a password'
    foreach ($value in @('password', 'no_password')) {
        $run = Get-AccessPlan -Repository $freshAccess -Extra @('-RepositoryAccess', $value)
        $shown = Show-Plan $run
        Assert-Equal @($value, '<null>') @($shown.Access, $shown.Existing) "-RepositoryAccess $value is resolved as asked for a new location"
        Assert-Equal @($defaultPlan.Warnings) @($shown.Warnings) "-RepositoryAccess $value adds no warning for a new location"
        Assert-Equal @($defaultPlan.Errors) @($shown.Errors) "-RepositoryAccess $value adds no error for a new location"
    }
    foreach ($value in @('NO_PASSWORD', 'Password', 'No_Password', 'PASSWORD')) {
        $run = Get-AccessPlan -Repository $freshAccess -Extra @('-RepositoryAccess', $value)
        Assert-PlanError $run 'repository_access_invalid' 'repository' "-RepositoryAccess $value (Windows PowerShell ignores the case of a value set)"
        Assert-True ($null -eq $run.Plan.resolved.repository_access) "-RepositoryAccess $value resolves to nothing"
    }
    $bogus = Get-AccessPlan -Repository $freshAccess -Extra @('-RepositoryAccess', 'bogus')
    Assert-True ($bogus.ExitCode -ne 0 -and $null -eq $bogus.Plan) 'a value that is no spelling of either choice stops the script before any plan is written'
    Assert-True ($bogus.Error.Contains('RepositoryAccess')) 'and the message names the parameter'

    # Backups that already exist keep their way, and a choice that contradicts it is warned about.
    $oldShape = New-ExistingBackups -Name 'old-shape' -Config '<absent>' -Manifest '<absent>'
    $shown = Show-Plan (Get-AccessPlan -Repository $oldShape)
    Assert-Equal @('password', 'password') @($shown.Access, $shown.Existing) 'backups recorded without the new key behave as they always did: a password'
    Assert-True ($shown.Warnings -contains 'repository_exists' -and $shown.Warnings -cnotcontains 'repository_access_differs') 'and nothing is said about them beyond what was always said'
    $shown = Show-Plan (Get-AccessPlan -Repository $oldShape -Extra @('-RepositoryAccess', 'password'))
    Assert-True ($shown.Warnings -cnotcontains 'repository_access_differs') 'asking for a password over backups recorded without the key is no contradiction'
    $withoutBackups = New-ExistingBackups -Name 'without-password' -Config 'no_password' -Manifest 'no_password'
    $run = Get-AccessPlan -Repository $withoutBackups
    $shown = Show-Plan $run
    Assert-Equal @('no_password', 'no_password') @($shown.Access, $shown.Existing) 'backups recorded as having no password keep that way'
    Assert-True ($shown.Warnings -cnotcontains 'repository_access_differs' -and $shown.Warnings -contains 'repository_exists') 'and a plan that asks for nothing says nothing against them'
    $run = Get-AccessPlan -Repository $withoutBackups -Extra @('-RepositoryAccess', 'password')
    $shown = Show-Plan $run
    Assert-Equal @('password', 'no_password') @($shown.Access, $shown.Existing) 'a password asked for over backups without one is resolved as asked, beside what is recorded'
    $differs = @(@($run.Plan.warnings) | Where-Object { $_.code -ceq 'repository_access_differs' })
    Assert-Equal 1 $differs.Count 'and warned about'
    Assert-Equal @('repository', $noPasswordDiffers, $withoutBackups) @($differs[0].field, $differs[0].message, $differs[0].path) 'the warning is the one for backups without a password, about this folder'
    Assert-True ($shown.Errors -cnotcontains 'repository_access_differs') 'it is a warning, never an error'
    $shown = Show-Plan (Get-AccessPlan -Repository $withoutBackups -Extra @('-RepositoryAccess', 'no_password'))
    Assert-True ($shown.Warnings -cnotcontains 'repository_access_differs') 'asking for no password over backups without one is no contradiction'
    $withBackups = New-ExistingBackups -Name 'with-password' -Config 'password' -Manifest 'password'
    $run = Get-AccessPlan -Repository $withBackups -Extra @('-RepositoryAccess', 'no_password')
    $shown = Show-Plan $run
    Assert-Equal @('no_password', 'password') @($shown.Access, $shown.Existing) 'no password asked for over backups with one is resolved as asked, beside what is recorded'
    $differs = @(@($run.Plan.warnings) | Where-Object { $_.code -ceq 'repository_access_differs' })
    Assert-Equal @(1, $passwordDiffers) @($differs.Count, $differs[0].message) 'and warned about with the words for backups with a password'
    $shown = Show-Plan (Get-AccessPlan -Repository $withBackups)
    Assert-Equal @('password', 'password') @($shown.Access, $shown.Existing) 'backups recorded with a password keep it'

    # Backups that no record describes: the install asks them, so the plan resolves nothing.
    $undescribed = New-ExistingBackups -Name 'no-records' -NoTools
    $shown = Show-Plan (Get-AccessPlan -Repository $undescribed)
    Assert-Equal @('<null>', 'unknown') @($shown.Access, $shown.Existing) 'backups that no record describes are unknown, and nothing is resolved'
    Assert-True ($shown.Warnings -contains 'repository_exists' -and $shown.Warnings -cnotcontains 'repository_access_differs') 'and the plan says only what it always did'
    foreach ($value in @('password', 'no_password')) {
        $shown = Show-Plan (Get-AccessPlan -Repository $undescribed -Extra @('-RepositoryAccess', $value))
        Assert-Equal @($value, 'unknown') @($shown.Access, $shown.Existing) "-RepositoryAccess $value over backups no record describes is resolved as asked"
        Assert-True ($shown.Warnings -cnotcontains 'repository_access_differs') "-RepositoryAccess $value contradicts nothing when nothing is recorded"
    }
    foreach ($case in @(@('disagreeing', 'no_password', 'password'), @('half-recorded', 'no_password', '<absent>'), @('capital-letter', 'Password', 'Password'))) {
        $repository = New-ExistingBackups -Name "records-$($case[0])" -Config $case[1] -Manifest $case[2]
        $shown = Show-Plan (Get-AccessPlan -Repository $repository)
        Assert-Equal @('<null>', 'unknown') @($shown.Access, $shown.Existing) "recovery tools that $($case[0]) say nothing the plan can use"
    }

    # A recovery key left behind is held against the install only for backups known to have a password.
    $staleRoots = New-RootsSet -Name 'stale-key-access'
    Write-Text -Path (Join-Path $staleRoots.Profile 'ResticBackuper-RecoveryKey.txt') -Text 'left over'
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $staleRoots
    Assert-PlanError $run 'recovery_key_stale' 'environment' 'a stale recovery key with a password by default'
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $staleRoots -Extra @('-RepositoryAccess', 'password')
    Assert-PlanError $run 'recovery_key_stale' 'environment' 'a stale recovery key with a password asked for'
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $staleRoots -Extra @('-RepositoryAccess', 'no_password')
    $shown = Show-Plan $run
    Assert-True ($shown.Errors -cnotcontains 'recovery_key_stale' -and $shown.Errors -cnotcontains 'recovery_key_path_unsafe') 'without a password a recovery key left behind is none of the install''s business'
    Assert-Equal 'no_password' $shown.Access 'and the plan still resolves no password'
    $run = Get-AccessPlan -Repository $undescribed -RootsSet $staleRoots
    $shown = Show-Plan $run
    Assert-True ($shown.Errors -cnotcontains 'recovery_key_stale') 'while it is not known whether the backups have a password a recovery key left behind is not held against the install'
    $run = Get-AccessPlan -Repository $withBackups -RootsSet $staleRoots
    Assert-PlanError $run 'recovery_key_stale' 'environment' 'a stale recovery key beside backups recorded with a password'
    $run = Get-AccessPlan -Repository $withoutBackups -RootsSet $staleRoots
    $shown = Show-Plan $run
    Assert-True ($shown.Errors -cnotcontains 'recovery_key_stale') 'a stale recovery key beside backups recorded without a password is nothing'
    # Something other than a file where the recovery key goes: unsafe for backups with a password, nothing without one.
    $oddKeyRoots = New-RootsSet -Name 'odd-key-access'
    New-Item -ItemType Directory -Path (Join-Path $oddKeyRoots.Profile 'ResticBackuper-RecoveryKey.txt') -Force | Out-Null
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $oddKeyRoots
    Assert-PlanError $run 'recovery_key_path_unsafe' 'environment' 'a folder where the recovery key goes stops backups with a password'
    $shown = Show-Plan (Get-AccessPlan -Repository $freshAccess -RootsSet $oddKeyRoots -Extra @('-RepositoryAccess', 'no_password'))
    Assert-True ($shown.Errors -cnotcontains 'recovery_key_path_unsafe') 'without a password the place of a recovery key is not checked'
    Assert-Equal 'no_password' $shown.Access 'and the plan still resolves no password over that folder'
    # (An unfinished change of the keys is only a problem for no password; the state folder here is the fixture's, which this
    # account owns, so the plan reports that too and the check is on the one code.)
    $journalRoots = New-RootsSet -Name 'rotation-journal'
    Write-Text -Path (Join-Path $journalRoots.ProgramData 'ResticBackuper\credential-rotation.journal.json') -Text '{}'
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $journalRoots -Extra @('-RepositoryAccess', 'no_password')
    Assert-PlanError $run 'repository_access_rotation_pending' 'repository' 'no password asked for while a change of the keys is waiting'
    $pending = @(@($run.Plan.errors) | Where-Object { $_.code -ceq 'repository_access_rotation_pending' })[0]
    Assert-Equal (Join-Path $journalRoots.ProgramData 'ResticBackuper') $pending.path 'the refusal names the state folder'
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $journalRoots
    Assert-True ((Get-ErrorCodes $run.Plan) -cnotcontains 'repository_access_rotation_pending') 'a password is no problem while a change of the keys is waiting'
    $run = Get-AccessPlan -Repository $freshAccess -RootsSet $journalRoots -Extra @('-RepositoryAccess', 'password')
    Assert-True ((Get-ErrorCodes $run.Plan) -cnotcontains 'repository_access_rotation_pending') 'asking for a password is no problem either'
    $run = Get-AccessPlan -Repository $withoutBackups -RootsSet $journalRoots
    Assert-PlanError $run 'repository_access_rotation_pending' 'repository' 'backups recorded without a password while a change of the keys is waiting'

    # ====================================================================================================================
    # 14. Rolling back a failed install: what it started stops first, runtime-manifest.json goes last, and the folder is checked
    # ====================================================================================================================
    # The rollback helpers run in this process against a fixture program folder. Copies of the system's ping program stand in
    # for the dashboard, under a name no real program uses, and no scheduled task is ever looked up.
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @(
        'Get-NormalizedPath', 'Write-Utf8NoBom', 'New-RuntimeManifest', 'Stop-OwnedProcesses', 'Stop-InstalledPrograms',
        'Remove-RuntimeContent', 'Remove-InstalledRuntime', 'Write-InstallFailure'))))
    $productName = 'ResticBackuper'
    $primaryTaskEvidenceName = 'scheduled-task.xml'
    $cloudTaskEvidenceName = 'google-drive-verification-task.xml'
    $systemDirectory = [Environment]::SystemDirectory
    $version = '9.9.9-fixture.1'
    # The long spelling of the temporary folder, as a program's own path reports it (a hosted runner's is an 8.3 short name).
    New-Item -ItemType Directory -Path (Join-Path $workspace 'rollback') -Force | Out-Null
    $rollbackBase = Get-FeedLongPath (Join-Path $workspace 'rollback')
    $programFilesRoot = Join-Path $rollbackBase 'Program Files'
    $installRoot = Join-Path $programFilesRoot $productName
    $rollbackManifest = Join-Path $installRoot 'runtime-manifest.json'
    $fixtureProgram = 'RewindleRollbackFixture'
    $pingProgram = Join-Path $env:SystemRoot 'System32\PING.EXE'
    $script:fixtureProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
    $script:heldFiles = [Collections.Generic.List[IDisposable]]::new()

    function New-RollbackFixture {
        param([switch]$NoManifest)
        Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'the previous rollback fixture is gone'
        foreach ($relative in @('backup-config.json', 'VERSION', 'Python\python.txt', 'Python\Lib\site.py', 'web\index.html', 'WebView2Loader.dll')) {
            Write-Text -Path (Join-Path $installRoot $relative) -Text "rollback fixture $relative"
        }
        Copy-Item -LiteralPath $pingProgram -Destination (Join-Path $installRoot "$fixtureProgram.exe")
        if (-not $NoManifest) { [void](New-RuntimeManifest -Root $installRoot -Version $version) }
    }
    function Start-FixtureProgram {
        param([string]$Path, [string]$WorkingDirectory)
        $process = Start-Process -FilePath $Path -ArgumentList @('-n', '120', '127.0.0.1') -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru
        $script:fixtureProcesses.Add($process)
        Start-Sleep -Milliseconds 300
        Assert-True (-not $process.HasExited) "the fixture program $Path runs"
        return $process
    }
    function Lock-FixtureFile {
        param([string]$Path)
        # Open for reading and shared for reading only, so the file can be neither deleted nor written while it is held.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $script:heldFiles.Add($stream)
        return $stream
    }
    function Get-FixtureFiles {
        if (-not (Test-Path -LiteralPath $installRoot)) { return @() }
        return @(Get-ChildItem -LiteralPath $installRoot -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($installRoot.Length + 1) } | Sort-Object)
    }
    function Read-RollbackManifest { return ([IO.File]::ReadAllText($rollbackManifest) | ConvertFrom-Json) }

    $savedDirectory = [Environment]::CurrentDirectory
    Push-Location -LiteralPath $workspace
    try {
        # --- every install names itself: clean-up of old backups is bound to it, so a reinstall of the same release
        # starts with clean-up off (retention.install_identity) ---
        New-RollbackFixture
        $firstInstallation = [string](Read-RollbackManifest).installation_id
        [void](New-RuntimeManifest -Root $installRoot -Version $version)
        $secondInstallation = [string](Read-RollbackManifest).installation_id
        Assert-True ($firstInstallation -cmatch '^[0-9a-f]{64}$' -and $secondInstallation -cmatch '^[0-9a-f]{64}$') 'runtime-manifest.json names its installation'
        Assert-True ($firstInstallation -cne $secondInstallation) 'each install of the same release writes a new installation_id'
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'the installation fixture is removed'

        # --- the dashboard the install started still runs from the program folder ---
        New-RollbackFixture
        $originalManifest = [IO.File]::ReadAllText($rollbackManifest)
        $running = Start-FixtureProgram -Path (Join-Path $installRoot "$fixtureProgram.exe") -WorkingDirectory $installRoot
        $otherCopy = Join-Path $rollbackBase "Elsewhere\$fixtureProgram.exe"
        New-Item -ItemType Directory -Path (Split-Path -Parent $otherCopy) -Force | Out-Null
        Copy-Item -LiteralPath $pingProgram -Destination $otherCopy
        $other = Start-FixtureProgram -Path $otherCopy -WorkingDirectory (Split-Path -Parent $otherCopy)
        Assert-Equal $installRoot (Remove-InstalledRuntime -Root $installRoot -Attempts 1) 'a program folder still in use is reported as left, not as removed'
        Assert-Equal @("$fixtureProgram.exe", 'runtime-manifest.json') (Get-FixtureFiles) 'everything but the running program and runtime-manifest.json is removed'
        Assert-Equal $originalManifest ([IO.File]::ReadAllText($rollbackManifest)) 'runtime-manifest.json stays as it was, since it lists the program left'
        Stop-InstalledPrograms -TaskName @() -ProgramName @($fixtureProgram)
        Assert-True ($running.WaitForExit(5000)) 'stopping what the install started ends the program running from the program folder'
        Assert-True (-not $other.HasExited) 'a program with the same name elsewhere is left running'
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'once the program is stopped the program folder is removed'
        Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'the program folder is really gone'

        # --- a file that is still open: runtime-manifest.json is kept with it ---
        New-RollbackFixture
        $held = Lock-FixtureFile (Join-Path $installRoot 'WebView2Loader.dll')
        Assert-Equal $installRoot (Remove-InstalledRuntime -Root $installRoot -Attempts 2) 'a file still open leaves the program folder'
        Assert-Equal @('runtime-manifest.json', 'WebView2Loader.dll') (Get-FixtureFiles) 'only the open file and runtime-manifest.json are left'
        Assert-True (@((Read-RollbackManifest).files | ForEach-Object relative_path) -contains 'WebView2Loader.dll') 'runtime-manifest.json lists the file left'
        $held.Dispose()
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'once the file is closed the program folder is removed'
        Assert-True (-not (Test-Path -LiteralPath $installRoot)) 'the program folder is gone after the second try'

        # --- a failure before runtime-manifest.json was written: one is written for what is left ---
        New-RollbackFixture -NoManifest
        $held = Lock-FixtureFile (Join-Path $installRoot 'Python\Lib\site.py')
        Assert-Equal $installRoot (Remove-InstalledRuntime -Root $installRoot -Attempts 2) 'a file still open leaves a program folder that had no list of files'
        Assert-Equal @('Python\Lib\site.py', 'runtime-manifest.json') (Get-FixtureFiles) 'the open file and a new runtime-manifest.json are left'
        $written = Read-RollbackManifest
        Assert-Equal @('Python\Lib\site.py') @($written.files | ForEach-Object relative_path) 'the new runtime-manifest.json lists exactly the file left'
        Assert-True ($written.schema_version -eq 1 -and $written.product -eq $productName -and $written.file_count -eq 1) 'it is a manifest the uninstaller accepts (schema, product, count)'
        Assert-Equal (Get-Sha256 (Join-Path $installRoot 'Python\Lib\site.py')) $written.files[0].sha256 'it carries the file hash'
        $held.Dispose()
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'that folder is removed once the file is closed'

        # --- a file left that runtime-manifest.json does not list: the list is written again ---
        New-RollbackFixture
        Write-Text -Path (Join-Path $installRoot 'Python\added-later.txt') -Text 'written after the list of files'
        $held = Lock-FixtureFile (Join-Path $installRoot 'Python\added-later.txt')
        Assert-Equal $installRoot (Remove-InstalledRuntime -Root $installRoot -Attempts 2) 'an unlisted file still open leaves the program folder'
        Assert-Equal @('Python\added-later.txt') @((Read-RollbackManifest).files | ForEach-Object relative_path) 'runtime-manifest.json is written again to list it'
        $held.Dispose()
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'that folder is removed once the file is closed'

        # --- only the folder itself is in use, as some process's working directory ---
        New-RollbackFixture
        $inside = Start-FixtureProgram -Path $pingProgram -WorkingDirectory $installRoot
        Assert-Equal $installRoot (Remove-InstalledRuntime -Root $installRoot -Attempts 2) 'a program folder that is still a working directory is reported as left'
        Assert-Equal @('runtime-manifest.json') (Get-FixtureFiles) 'only a runtime-manifest.json is left in it'
        $written = Read-RollbackManifest
        Assert-True ($written.schema_version -eq 1 -and $written.product -eq $productName -and $written.file_count -eq 0 -and @($written.files).Count -eq 0) 'the empty folder still has a list of files, with no file in it'
        $inside.Kill()
        Assert-True ($inside.WaitForExit(5000)) 'the fixture working directory is released'
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'then the empty folder is removed'

        # --- a reparse point is neither followed nor removed ---
        New-RollbackFixture
        $manifestBefore = [IO.File]::ReadAllText($rollbackManifest)
        $outside = Join-Path $rollbackBase 'Outside'
        Write-Text -Path (Join-Path $outside 'precious.txt') -Text 'outside the program folder'
        $link = Join-Path $installRoot 'Python\Linked'
        New-Junction -Link $link -Target $outside
        Assert-Equal $installRoot (Remove-InstalledRuntime -Root $installRoot -Attempts 1) 'a program folder with a junction in it is reported as left'
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'precious.txt') -PathType Leaf) 'nothing behind the junction is removed'
        Assert-True (Test-Path -LiteralPath $link) 'the junction itself is left for the uninstaller to refuse'
        Assert-Equal $manifestBefore ([IO.File]::ReadAllText($rollbackManifest)) 'runtime-manifest.json is not rewritten to vouch for a junction'
        Remove-Junction $link
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'without the junction the program folder is removed'

        # --- only the program folder itself is ever removed ---
        $elsewhere = Join-Path $rollbackBase 'Elsewhere\ResticBackuper'
        Write-Text -Path (Join-Path $elsewhere 'keep.txt') -Text 'not the program folder'
        Assert-Equal $elsewhere (Remove-InstalledRuntime -Root $elsewhere) 'another folder is reported as left'
        Assert-True (Test-Path -LiteralPath (Join-Path $elsewhere 'keep.txt') -PathType Leaf) 'and nothing in it is removed'
        Assert-True ($null -eq (Remove-InstalledRuntime -Root $installRoot)) 'a program folder that is already gone counts as removed'
    }
    finally {
        foreach ($stream in $script:heldFiles) { $stream.Dispose() }
        foreach ($process in $script:fixtureProcesses) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        }
        Pop-Location
        [Environment]::CurrentDirectory = $savedDirectory
    }

    # --- the progress feed says Setup undid its changes only when the program folder is gone ---
    $installPhaseTitles = $null
    $installPhaseFailures = $null
    foreach ($table in @('installPhaseTitles', 'noPasswordPhaseTitles', 'installPhaseFailures')) {
        $tableText = [regex]::Match($installerText, '(?s)\$' + $table + ' = @\{.*?\n\}')
        Assert-True $tableText.Success "the installer's $table table is found"
        . ([scriptblock]::Create($tableText.Value))
    }
    # Backups with a password are what these checks have always been about; the other mode follows them.
    $script:repositoryAccessMode = 'password'
    function Get-RecoveryKeyFacts { return [ordered]@{ path = $null; readable = $null } }
    $script:installWarnings = [Collections.Generic.List[object]]::new()
    $lateFailure = $(try { throw 'Updating the recovery key failed with exit code 1.' } catch { $_ })
    $rollbackMessages = @{}
    foreach ($case in @('gone', 'left')) {
        $script:FeedResultWritten = $false
        $rollbackFeed = Join-Path $feedDirectory "rollback-$case.jsonl"
        Open-ProgressFeed -Path $rollbackFeed -ExpectedSid $currentSid
        Write-FeedPhase -Phase 'verification' -State 'started' -Title $installPhaseTitles['verification']
        Write-InstallFailure -ErrorRecord $lateFailure -RolledBack $true -Leftover $(if ($case -eq 'left') { $installRoot } else { $null })
        Close-ProgressFeed
        $rollbackLines = @([IO.File]::ReadAllLines($rollbackFeed) | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal @('phase', 'phase', 'result') @($rollbackLines | ForEach-Object type) "$case : the feed ends with the failed phase and the result"
        Assert-Equal $rollbackLines[2].error.message $rollbackLines[1].detail "$case : the failed phase says the same as the result"
        Assert-Equal 'verification_failed' $rollbackLines[2].error.code "$case : the code is the failed phase's"
        $rollbackMessages[$case] = [string]$rollbackLines[2].error.message
    }
    Assert-True ($rollbackMessages['gone'].EndsWith(' Setup undid its changes. Backups and the recovery key it had already created were kept.')) "with the program folder gone Setup says it undid its changes (got: $($rollbackMessages['gone']))"
    $leftMessage = $rollbackMessages['left']
    Assert-True (-not $leftMessage.Contains('Setup undid its changes.')) "with program files left Setup does not say it undid all its changes (got: $leftMessage)"
    foreach ($text in @("some of Rewindle's program files could not be removed", 'Restart your PC', 'run Setup again', 'Reinstall or repair', 'were kept.')) {
        Assert-True $leftMessage.Contains($text) "with program files left the message says '$text' (got: $leftMessage)"
    }
    foreach ($word in @('restic', 'repository', 'snapshot', 'engine')) {
        Assert-True (-not $leftMessage.ToLowerInvariant().Contains($word)) "the message for program files left uses plain words (found '$word')"
    }

    # --- the same for backups without a password, and for the refusals about how the backups open ---
    function Get-FailureLines {
        param([string]$Name, $ErrorRecord, [bool]$Gone, [string]$StartedPhase = 'verification')
        $script:FeedResultWritten = $false
        $path = Join-Path $feedDirectory "failure-$Name.jsonl"
        Open-ProgressFeed -Path $path -ExpectedSid $currentSid
        Write-FeedPhase -Phase $StartedPhase -State 'started' -Title (Get-InstallPhaseTitle -Phase $StartedPhase)
        Write-InstallFailure -ErrorRecord $ErrorRecord -RolledBack $true -Leftover $(if ($Gone) { $null } else { $installRoot })
        Close-ProgressFeed
        return @([IO.File]::ReadAllLines($path) | ForEach-Object { $_ | ConvertFrom-Json })
    }
    foreach ($mode in @('no_password', $null)) {
        $script:repositoryAccessMode = $mode
        $label = if ($null -eq $mode) { 'unknown' } else { $mode }
        $lines = Get-FailureLines -Name "tail-$label-gone" -ErrorRecord $lateFailure -Gone $true
        $message = [string]$lines[2].error.message
        Assert-True ($message.EndsWith(' Setup undid its changes. Backups it had already created were kept.')) "$label : with the program folder gone the tail mentions no recovery key (got: $message)"
        Assert-True (-not $message.Contains('recovery key')) "$label : and says nothing about a recovery key"
        $lines = Get-FailureLines -Name "tail-$label-left" -ErrorRecord $lateFailure -Gone $false
        $message = [string]$lines[2].error.message
        Assert-True ($message.EndsWith('Reinstall or repair, which removes them first. Backups it had already created were kept.') -and -not $message.Contains('Setup undid its changes.') -and -not $message.Contains('recovery key')) "$label : with program files left the tail mentions no recovery key (got: $message)"
        foreach ($text in @("some of Rewindle's program files could not be removed", 'Restart your PC', 'run Setup again')) {
            Assert-True $message.Contains($text) "$label : with program files left the message says '$text'"
        }
        Assert-Equal @('schema', 'seq', 'time', 'type', 'ok', 'error', 'install_root', 'recovery_key_path', 'recovery_key_readable_by_user', 'dashboard_executable', 'version', 'repository_access', 'warnings') @($lines[2].PSObject.Properties.Name) "$label : the result carries the access after the version and before the warnings"
        Assert-Equal (Show-Value $mode) (Show-Value $lines[2].repository_access) "$label : the result says how the backups open, or null when that was not decided"
    }
    $script:repositoryAccessMode = 'password'
    $lines = Get-FailureLines -Name 'tail-password' -ErrorRecord $lateFailure -Gone $true
    Assert-Equal 'password' $lines[2].repository_access 'a failure with a password reports it'
    Assert-Equal @($null, $null) @($lines[2].recovery_key_path, $lines[2].recovery_key_readable_by_user) 'the key facts are the stand-in''s here'

    # The refusals end by themselves, and take no other tail.
    $refusalEnding = ' Setup undid its changes, and your backups were not touched.'
    $refusalCases = @(
        @('mismatch', 'repository_access_mismatch', (Get-RepositoryAccessRefusalMessage -ExitCode 4 -Source 'parameter')),
        @('mismatch-recorded', 'repository_access_mismatch', (Get-RepositoryAccessRefusalMessage -ExitCode 5 -Source 'recorded')),
        @('unreadable', 'repository_access_unreadable', (Get-RepositoryAccessRefusalMessage -ExitCode 6 -Source 'detected'))
    )
    foreach ($case in $refusalCases) {
        $refusal = $(try { Stop-InstallValidation -Code $case[1] -Field 'repository' -Message $case[2] } catch { $_ })
        foreach ($setup in @(@('password', 'credential'), @('no_password', 'repository'))) {
            $script:repositoryAccessMode = $setup[0]
            $lines = Get-FailureLines -Name "$($case[0])-$($setup[0])-gone" -ErrorRecord $refusal -Gone $true -StartedPhase $setup[1]
            Assert-Equal @('phase', 'phase', 'result') @($lines | ForEach-Object type) "$($case[0]) ($($setup[0])): the feed ends with the failed phase and the result"
            Assert-Equal @($setup[1], 'failed', $case[1]) @($lines[1].phase, $lines[1].state, $lines[2].error.code) "$($case[0]) ($($setup[0])): the phase that was running failed, with the refusal's code"
            Assert-Equal $case[2] $lines[2].error.message "$($case[0]) ($($setup[0])): the message is the refusal itself, with no tail added"
            Assert-Equal $case[2] $lines[1].detail "$($case[0]) ($($setup[0])): the failed phase says the same"
            Assert-True ($lines[2].error.message.EndsWith($refusalEnding)) "$($case[0]) ($($setup[0])): it says Setup undid its changes and the backups were not touched"
            $lines = Get-FailureLines -Name "$($case[0])-$($setup[0])-left" -ErrorRecord $refusal -Gone $false -StartedPhase $setup[1]
            $message = [string]$lines[2].error.message
            Assert-True ($message.EndsWith('Reinstall or repair, which removes them first. Your backups were not touched.') -and -not $message.Contains('Setup undid its changes,') -and -not $message.Contains('Setup undid its changes.')) "$($case[0]) ($($setup[0])): with program files left it does not say Setup undid everything, and still says the backups were not touched (got: $message)"
            Assert-True ($message.StartsWith($case[2].Substring(0, $case[2].Length - $refusalEnding.Length))) "$($case[0]) ($($setup[0])): with program files left the refusal's own words come first"
        }
    }
    $script:repositoryAccessMode = 'no_password'
    $lines = Get-FailureLines -Name 'phase-title' -ErrorRecord $refusal -Gone $true -StartedPhase 'repository'
    Assert-Equal 'Creating the backup location' $lines[1].title 'the failed repository phase of a backup without a password is called by its own title'

    # A failure of the initializer that nothing classified: the repository phase's own words, by mode.
    $plainFailure = $(try { throw 'Repository initialization failed with exit code 3.' } catch { $_ })
    $script:repositoryAccessMode = 'password'
    $lines = Get-FailureLines -Name 'initializer-password' -ErrorRecord $plainFailure -Gone $true -StartedPhase 'repository'
    Assert-Equal @('repository_initialization_failed', 'Setup could not create the encrypted backup repository. Setup undid its changes. Backups and the recovery key it had already created were kept.') @($lines[2].error.code, $lines[2].error.message) 'the repository phase of a backup with a password fails in the words it always used'
    foreach ($mode in @('no_password', $null)) {
        $script:repositoryAccessMode = $mode
        $lines = Get-FailureLines -Name "initializer-$(if ($null -eq $mode) { 'unknown' } else { $mode })" -ErrorRecord $plainFailure -Gone $true -StartedPhase 'repository'
        Assert-Equal @('repository_initialization_failed', 'Setup could not create the backup location. Setup undid its changes. Backups it had already created were kept.') @($lines[2].error.code, $lines[2].error.message) "the repository phase fails without a word about an encrypted place when the mode is $(Show-Value $mode)"
    }
    $script:repositoryAccessMode = $null

    # The facts about a recovery key: none for backups without a password, whatever an earlier installation left behind.
    . ([scriptblock]::Create((Get-InstallerFunctionText -Name @('Get-RecoveryKeyFacts')).Replace('function Get-RecoveryKeyFacts', 'function Get-RealRecoveryKeyFacts')))
    function Test-FileReadableByUser { param([string]$Path) return $true }
    $recoveryKey = Join-Path $workspace 'older-key\ResticBackuper-RecoveryKey.txt'
    Write-Text -Path $recoveryKey -Text 'an older key'
    $script:repositoryAccessMode = 'no_password'
    $facts = Get-RealRecoveryKeyFacts
    Assert-True ($null -eq $facts.path -and $null -eq $facts.readable) 'backups without a password report no recovery key, although an older one is there'
    foreach ($mode in @('password', $null)) {
        $script:repositoryAccessMode = $mode
        $facts = Get-RealRecoveryKeyFacts
        Assert-Equal @($recoveryKey, 'True') @($facts.path, $facts.readable) "a key that is there is reported when the mode is $(Show-Value $mode)"
    }
    Remove-Item -LiteralPath $recoveryKey -Force
    $facts = Get-RealRecoveryKeyFacts
    Assert-True ($null -eq $facts.path -and $null -eq $facts.readable) 'and none when there is no key'
    Remove-Item -LiteralPath 'function:Test-FileReadableByUser'
    $script:repositoryAccessMode = $null

    $summary = [pscustomobject]@{
        ok = $true
        tests = $script:assertions
        plan_runs = $script:planRuns
        elevated = $isElevated
        schema = 'passed'
        no_side_effects = 'passed'
        error_codes = 'passed'
        output_path_guards = 'passed'
        volume_recommendation = 'passed'
        recovery_key_access_check = 'passed'
        signer_check = 'passed'
        state_folder_owner = 'passed'
        progress_feed = 'passed'
        native_calls_compile_nothing = 'passed'
        downloaded_program_held = 'passed'
        kept_repository = 'passed'
        continued_generation = 'passed'
        repository_access = 'passed'
        rollback = 'passed'
    }
}
catch {
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    throw
}
finally {
    if (-not $KeepWorkspace -and (Test-Path -LiteralPath $workspace)) {
        $resolved = [IO.Path]::GetFullPath($workspace)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\Rewindle-InstallPlan-'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -ne $workspaceName) {
            throw "Refusing to remove an unexpected test workspace: $resolved"
        }
        # Junctions are removed first so that recursive deletion never follows one.
        foreach ($link in @($script:junctions)) { Remove-Junction $link }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if ($null -ne $summary) { $summary | ConvertTo-Json -Depth 3 }
