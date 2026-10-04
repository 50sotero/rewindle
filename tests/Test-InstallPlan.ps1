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
    'Assert-VolumeFreeSpace', 'Test-DriveFsMount', 'Convert-FileAccessMask', 'Test-DescriptorGrantsAccess'))))

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
    Assert-Equal @('repository', 'storage_mode', 'drivefs_my_drive_root', 'sources', 'canary_source', 'schedule', 'vss', 'minimum_free_bytes', 'estimated_source_bytes') @($plan.resolved.PSObject.Properties.Name) 'resolved properties'
    Assert-Equal $goodRepository $plan.resolved.repository 'resolved repository'
    Assert-Equal 'local_ntfs' $plan.resolved.storage_mode 'resolved storage mode'
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
    Assert-Equal @('rewindle', 'legacy_personal_edition') @($environment.existing_install.PSObject.Properties.Name) 'existing_install properties'
    Assert-True ($null -eq $environment.existing_install.rewindle) 'a fresh fixture has no Rewindle installation'
    Assert-True ($environment.existing_install.legacy_personal_edition -eq $false) 'a fresh fixture has no legacy edition'
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
    $linkRoots = New-RootsSet -Name 'linked-state'
    New-Junction -Link (Join-Path $linkRoots.ProgramData 'ResticBackuper') -Target $realFolder
    [void](Test-Invalid 'state folder that is a junction' @{} 'protected_path_reparse_point' 'environment' $linkRoots)

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
    # 7. The progress feed writer
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
        progress_feed = 'passed'
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
