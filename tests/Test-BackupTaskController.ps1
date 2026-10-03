$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scheduleSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\TaskSchedule.cs') -Raw -Encoding UTF8
$controllerSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\BackupTaskController.cs') -Raw -Encoding UTF8
$controllerSource = $controllerSource -replace '^(using [^\r\n]+;\r?\n)+\r?\n', ''
function Join-DashboardSources {
    param([string[]]$Parts)
    $usingPattern = '(?m)^using\s+[^;]+;\s*\r?\n'
    $usings = @($Parts | ForEach-Object {
        [regex]::Matches($_, $usingPattern) | ForEach-Object { $_.Value.Trim() }
    } | Sort-Object -Unique)
    $bodies = @($Parts | ForEach-Object { [regex]::Replace($_, $usingPattern, '') })
    return ($usings -join [Environment]::NewLine) + [Environment]::NewLine + ($bodies -join [Environment]::NewLine)
}
$engineProfileSource = Get-Content -LiteralPath (Join-Path $project 'src\dashboard\EngineProfile.cs') -Raw -Encoding UTF8
$harnessSource = @'
namespace ResticBackuper.Dashboard
{
    public static class BackupTaskValidationHarness
    {
        public static bool Validate(
            string xml,
            string expectedLauncher,
            string installRoot,
            out string error)
        {
            return BackupTaskController.TryValidateTaskXml(
                xml,
                expectedLauncher,
                installRoot,
                out error);
        }
    }
}
'@
Add-Type -TypeDefinition ((Join-DashboardSources @($engineProfileSource, $scheduleSource, $controllerSource)) + [Environment]::NewLine + $harnessSource) `
    -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Xml.dll')

$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$installRoot = 'C:\Program Files\ResticBackuper'
$launcher = Join-Path $installRoot 'ResticBackuperTaskLauncher.exe'
$script:tests = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $script:tests++
    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function New-TaskXml {
    param(
        [string]$Actions,
        [string]$Principals,
        [string]$Trigger = '<CalendarTrigger><StartBoundary>2026-07-21T02:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>',
        [string]$Context = 'Author',
        [string]$Uri = '\ResticBackuper',
        [string]$MultipleInstances = 'IgnoreNew',
        [string]$Enabled = 'true',
        [string]$AllowDemandStart = 'true'
    )
    return @"
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><URI>$Uri</URI></RegistrationInfo>
  <Triggers>$Trigger</Triggers>
  <Principals>$Principals</Principals>
  <Settings>
    <MultipleInstancesPolicy>$MultipleInstances</MultipleInstancesPolicy>
    <AllowHardTerminate>true</AllowHardTerminate>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>$AllowDemandStart</AllowStartOnDemand>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <WakeToRun>true</WakeToRun>
    <Enabled>$Enabled</Enabled>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="$Context">$Actions</Actions>
</Task>
"@
}

$principal = "<Principal id=`"Author`"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal>"
$action = "<Exec><Command>$launcher</Command><WorkingDirectory>$installRoot</WorkingDirectory></Exec>"

function Test-TaskXml {
    param([string]$Xml)
    $errorText = $null
    $valid = [ResticBackuper.Dashboard.BackupTaskValidationHarness]::Validate(
        $Xml,
        $launcher,
        $installRoot,
        [ref]$errorText)
    return [pscustomobject]@{ Valid = $valid; Error = $errorText }
}

Assert-Equal $true (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal)).Valid 'Known-good daily task must pass.'

$weekly = '<CalendarTrigger><StartBoundary>2026-07-21T03:15:00</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><WeeksInterval>1</WeeksInterval><DaysOfWeek><Monday/><Friday/></DaysOfWeek></ScheduleByWeek></CalendarTrigger>'
Assert-Equal $true (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal -Trigger $weekly)).Valid 'Known-good selected-days task must pass.'

$extraAction = $action + "<Exec><Command>$env:SystemRoot\System32\cmd.exe</Command></Exec>"
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $extraAction -Principals $principal)).Valid 'Multiple actions must fail.'

$comHandler = '<ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler>'
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $comHandler -Principals $principal)).Valid 'Non-Exec action must fail.'

$extraPrincipal = $principal + $principal.Replace('Author', 'Other')
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $action -Principals $extraPrincipal)).Valid 'Multiple principals must fail.'
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal -Context 'Other')).Valid 'Action context mismatch must fail.'

$wrongCommand = $action.Replace($launcher, "$env:SystemRoot\System32\cmd.exe")
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $wrongCommand -Principals $principal)).Valid 'Wrong command must fail.'

$arguments = $action.Replace('</Command>', '</Command><Arguments>unexpected</Arguments>')
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $arguments -Principals $principal)).Valid 'Arguments must fail.'

$wrongDirectory = $action.Replace($installRoot + '</WorkingDirectory>', 'C:\Windows</WorkingDirectory>')
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $wrongDirectory -Principals $principal)).Valid 'Wrong working directory must fail.'
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal -Enabled 'false')).Valid 'Paused task must not allow a manual start.'
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal -AllowDemandStart 'false')).Valid 'Demand start disabled must fail.'
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal -MultipleInstances 'Parallel')).Valid 'Parallel instances must fail.'

$repeating = '<CalendarTrigger><StartBoundary>2026-07-21T02:00:00</StartBoundary><Repetition><Interval>PT1H</Interval></Repetition><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>'
Assert-Equal $false (Test-TaskXml (New-TaskXml -Actions $action -Principals $principal -Trigger $repeating)).Valid 'Repeating trigger must fail.'
Assert-Equal $false (Test-TaskXml '<Task').Valid 'Malformed XML must fail.'

[pscustomobject]@{
    ok = $true
    tests = $script:tests
    fixture_task_validated = $true
    live_task_queried = $false
    production_task_started = $false
} | ConvertTo-Json
