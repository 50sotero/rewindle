"""The nightly Google Drive check and the installer that sets it up each read `rclone version` and each refuse an rclone
older than 1.65.0, the first that reports Google Drive's SHA-256 checksums. Each script carries its own copy of the
reader (ConvertFrom-RcloneVersionText) and of the oldest allowed version, so one could change and the other not, and
the installer would then set up a check that refuses its own rclone, or the check would run with one it should refuse.

This test loads both copies the way PowerShell does (its parser, not a pattern match on the text), feeds them the same
`rclone version` outputs in one Windows PowerShell 5.1 run, and fails when they read any of them differently or when
the two oldest versions differ. It also fails, rather than passes empty, when a function or a version is missing,
and when a script's call site no longer gets its version from that reader (a third, looser parse inlined there would
otherwise go unseen).
"""

import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / "src" / "install_google_drive_sync_task.ps1"
VERIFIER = PROJECT / "src" / "verify_my_drive_cloud_repository.ps1"

OLDEST_ALLOWED = "1.65.0"
REFUSED = "refused"

# Whether each plain version is older than the oldest allowed one. They differ from it in the major number (0, 2), in
# the minor number alone with more digits (1.100.0 is newer than 1.65.0 as a number, older as text), and by one patch.
TOO_OLD = {
    "0.99.0": True,
    "1.64.2": True,
    "1.64.9": True,
    "1.65.0": False,
    "1.65.1": False,
    "1.74.4": False,
    "1.100.0": False,
    "2.0.0": False,
}

# Anchors for the shared reader: what a few inputs must give on both sides, so that two readers that both accept
# everything, or both refuse everything, cannot pass.
CASES = []


def add_case(label, text, expected=None):
    """`expected` is the version both readers must give, REFUSED, or None when only their agreement matters."""
    CASES.append((label, text, expected))


def full_output(first_line, line_break):
    lines = [
        first_line,
        "- os/version: Microsoft Windows 11 Home 25H2 (64 bit)",
        "- os/kernel: 10.0.26200.1 (x86_64)",
        "- os/type: windows",
        "- os/arch: amd64",
        "- go/version: go1.25.3",
        "- go/linking: static",
        "- go/tags: cmount",
    ]
    return line_break.join(lines) + line_break


# Plain releases, with and without a line break after them.
for version in ("1.74.4", "1.65.0", "1.64.2"):
    add_case("plain " + version, "rclone v" + version, version)
    add_case("plain " + version + " with LF", "rclone v" + version + "\n", version)
    add_case("plain " + version + " with CRLF", "rclone v" + version + "\r\n", version)
    add_case("full output of " + version + " with LF", full_output("rclone v" + version, "\n"), version)
    add_case("full output of " + version + " with CRLF", full_output("rclone v" + version, "\r\n"), version)
for version in ("1.64.9", "1.65.1", "0.99.0", "2.0.0", "1.100.0"):
    add_case("plain " + version, "rclone v" + version, version)
add_case("full output without a final line break", full_output("rclone v1.74.4", "\n").rstrip("\n"), "1.74.4")
add_case("full output with lone CR line breaks", full_output("rclone v1.74.4", "\r"))
add_case(
    "full output with mixed line breaks", "rclone v1.74.4\r\n- os/arch: amd64\n- go/version: go1.25.3\r\n", "1.74.4"
)
add_case("version 0.0.0", "rclone v0.0.0\n")
add_case("largest numbers", "rclone v9999.9999.999999\n")
add_case("leading zeros", "rclone v01.074.004\n")

# Leading and trailing white space.
add_case("leading spaces", "   rclone v1.74.4\n", "1.74.4")
add_case("trailing spaces", "rclone v1.74.4   \n", "1.74.4")
add_case("leading and trailing spaces", "  rclone v1.74.4  \r\n", "1.74.4")
add_case("leading and trailing tabs", "\trclone v1.74.4\t\n", "1.74.4")
add_case("trailing spaces then CRLF and more lines", "rclone v1.74.4 \r\n- os/arch: amd64\r\n", "1.74.4")
add_case("leading no-break space", "\u00a0rclone v1.74.4\n")
add_case("trailing no-break space", "rclone v1.74.4\u00a0\n")
add_case("leading em space", "\u2003rclone v1.74.4\n")
add_case("leading byte order mark", "\ufeffrclone v1.74.4\n")
add_case("only white space before the version on its line", " \t \rclone v1.74.4\n")

# Betas and development builds.
add_case("beta with build and branch", "rclone v1.66.0-beta.7863.abc1234.master", "1.66.0")
add_case("beta with LF", "rclone v1.66.0-beta.7731.6a8ddbcc4\n", "1.66.0")
add_case("beta with full output and CRLF", full_output("rclone v1.66.0-beta.7863.abc1234.master", "\r\n"), "1.66.0")
add_case("DEV build", "rclone v1.66.0-DEV\n", "1.66.0")
add_case("DEV build with full output", full_output("rclone v1.74.0-DEV", "\n"), "1.74.0")
add_case("lower case dev build", "rclone v1.66.0-dev\n")
add_case("bare beta label", "rclone v1.66.0-beta\n")
add_case("release candidate", "rclone v1.66.0-rc.1\n")
add_case("suffix with a plus sign", "rclone v1.66.0-beta.1+sha.abc\n")
add_case("beta of a version before the oldest allowed", "rclone v1.64.3-beta.7000.abcdef.master\n", "1.64.3")
add_case("beta of the oldest allowed version", "rclone v1.65.0-beta.7000.abcdef.master\n", "1.65.0")
add_case("suffix of 120 characters", "rclone v1.66.0-" + "a" * 120 + "\n")
add_case("suffix of 121 characters", "rclone v1.66.0-" + "a" * 121 + "\n")
add_case("empty suffix", "rclone v1.66.0-\n")
add_case("suffix with a space", "rclone v1.66.0-beta 1\n")
add_case("plus metadata without a hyphen", "rclone v1.66.0+build.5\n")
add_case("beta with a hyphenated branch name", "rclone v1.66.0-beta.7731.6a8ddbcc4.fix-sftp-hang\n", "1.66.0")
add_case("suffix with a doubled hyphen", "rclone v1.66.0--beta\n")
for character, name in (
    ("_", "an underscore"),
    ("/", "a slash"),
    ("~", "a tilde"),
    (":", "a colon"),
    ("@", "an at sign"),
):
    add_case("suffix with " + name, "rclone v1.66.0-beta.1" + character + "x\n")

# Not a full version, or not worded like rclone's own first line.
add_case("major and minor only", "rclone v1.74", REFUSED)
add_case("major and minor only with LF", "rclone v1.74\n", REFUSED)
add_case("major and minor only with a beta suffix", "rclone v1.74-beta.1\n")
add_case("four numbers", "rclone v1.74.4.1\n")
add_case("version without the word rclone", "v1.74.4\n", REFUSED)
add_case("bare number", "1.74.4\n", REFUSED)
add_case("version word first", "version v1.74.4\n")
add_case("colon after the name", "rclone: v1.74.4\n")
add_case("rclone version wording", "rclone version v1.74.4\n")
add_case("upper case name", "RCLONE v1.74.4\n")
add_case("capitalised name", "Rclone v1.74.4\n")
add_case("upper case v", "rclone V1.74.4\n")
add_case("no v", "rclone 1.74.4\n", REFUSED)
add_case("two spaces before the version", "rclone  v1.74.4\n")
add_case("tab before the version", "rclone\tv1.74.4\n")
add_case("text after the version", "rclone v1.74.4 extra\n")
add_case("name after the version", "v1.74.4 rclone\n", REFUSED)

# The version is not on the first line.
add_case("version on the second line", "go/version: go1.25.3\nrclone v1.74.4\n", REFUSED)
add_case("blank line first", "\nrclone v1.74.4\n", REFUSED)
add_case("blank CRLF line first", "\r\nrclone v1.74.4\r\n", REFUSED)
add_case("warning line first", "WARNING: something happened\r\nrclone v1.74.4\r\n- os/arch: amd64\r\n", REFUSED)

# Empty output and garbage.
add_case("empty output", "", REFUSED)
add_case("only spaces", "   ", REFUSED)
add_case("only a line break", "\n", REFUSED)
add_case("only a CRLF line break", "\r\n", REFUSED)
add_case("garbage", "hello", REFUSED)
add_case("the name alone", "rclone", REFUSED)
add_case("the name and a v", "rclone v", REFUSED)
add_case("letters for numbers", "rclone vX.Y.Z", REFUSED)
add_case("a non-numeric patch", "rclone v1.74.x\n")
add_case("a negative number", "rclone v-1.2.3\n")
add_case("an error message", "Failed to load config file \"rclone.conf\": permission denied\n", REFUSED)
add_case("markup", "<html><body>rclone v1.74.4</body></html>\n")
add_case("a NUL after the version", "rclone v1.74.4\u0000\n")
add_case("full-width digits", "rclone v\uff11.\uff17\uff14.\uff14\n")
add_case("Arabic-Indic digits", "rclone v\u0661.\u0667\u0664.\u0664\n")
add_case("major of five digits", "rclone v10000.1.1\n")
add_case("minor of five digits", "rclone v1.10000.1\n")
add_case("patch of seven digits", "rclone v1.1.1000000\n")

LABELS = [label for label, _, _ in CASES]
if len(set(LABELS)) != len(LABELS):
    raise AssertionError("two inputs of the version parity test share a label")

# Runs in Windows PowerShell 5.1. It reads the two scripts with PowerShell's own parser, takes the reader and the
# oldest allowed version out of each by its syntax tree (evaluating nothing but the [Version]'x.y.z' literal), checks
# that each call site gets its version from the reader, runs both readers on every input, and prints one JSON document
# that holds only ASCII.
PROBE = r"""using namespace System.Management.Automation.Language

[CmdletBinding()]
param([Parameter(Mandatory)] [string]$PayloadPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:problems = @()
function Add-Problem {
    param([string]$Message)

    $script:problems += $Message
}

function Read-ScriptTree {
    param([string]$Path, [string]$Label)

    if (-not [System.IO.File]::Exists($Path)) {
        Add-Problem "The $Label script was not found."
        return $null
    }
    $tokens = $null
    $errors = $null
    $tree = [Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        Add-Problem ("The $Label script does not parse: " + $errors[0].Message)
        return $null
    }
    return $tree
}

function Get-OneFunction {
    param($Tree, [string]$Name, [string]$Label)

    if ($null -eq $Tree) {
        return $null
    }
    $found = @($Tree.FindAll({ $args[0] -is [FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -ieq $Name })
    if ($found.Count -ne 1) {
        Add-Problem "The $Label script defines $Name $($found.Count) times; it must define it exactly once."
        return $null
    }
    return $found[0]
}

function Get-VersionLiteral {
    param($Assignment, [string]$Label)

    # The right side of `$x = [Version]'1.65.0'` is a command expression (Windows PowerShell 5.1) or a pipeline of one
    # (other versions); nothing else is read as a literal.
    $right = $Assignment.Right
    if ($right -is [PipelineAst] -and $right.PipelineElements.Count -eq 1) {
        $right = $right.PipelineElements[0]
    }
    $expression = $null
    if ($right -is [CommandExpressionAst]) {
        $expression = $right.Expression
    }
    $isLiteral = ($expression -is [ConvertExpressionAst]) -and
        ($expression.Child -is [StringConstantExpressionAst]) -and
        (@('Version', 'System.Version') -contains $expression.Type.TypeName.FullName)
    $text = ''
    if ($isLiteral) {
        $text = [string]$expression.Child.Value
    }
    if (-not $isLiteral -or $text -cnotmatch '^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,6}$') {
        Add-Problem ("$Label is not a [Version]'x.y.z' literal: " + $Assignment.Extent.Text)
        return $null
    }
    return [Version]$text
}

function Get-MinimumVersion {
    param($Container, [string]$VariableName, [string]$Label, $Tree, [switch]$ScriptLevel)

    if ($null -eq $Container) {
        return $null
    }
    $assignments = @($Container.FindAll({ $args[0] -is [AssignmentStatementAst] }, $true) |
        Where-Object {
            $_.Left -is [VariableExpressionAst] -and
            (($_.Left.VariablePath.UserPath -ireplace '^script:', '') -ieq $VariableName)
        })
    if ($assignments.Count -ne 1) {
        Add-Problem "$Label assigns `$$VariableName $($assignments.Count) times; it must be assigned exactly once."
        return $null
    }
    if ($ScriptLevel) {
        $parent = $assignments[0].Parent
        if ($parent -isnot [NamedBlockAst] -or -not [object]::ReferenceEquals($parent.Parent, $Tree)) {
            Add-Problem "$Label is not assigned at the top level of its script."
            return $null
        }
    }
    return Get-VersionLiteral -Assignment $assignments[0] -Label $Label
}

function Get-AssignedCommandName {
    param($Assignment)

    # The command on the right side of `$x = Name -Arg ...` (a pipeline of one command, or the command itself), or ''.
    $right = $Assignment.Right
    if ($right -is [PipelineAst] -and $right.PipelineElements.Count -eq 1) {
        $right = $right.PipelineElements[0]
    }
    if ($right -is [CommandAst]) {
        return [string]$right.GetCommandName()
    }
    return ''
}

function Test-AssignedFromCommand {
    param($Tree, [string]$VariableName, [string]$CommandName, [string]$Label)

    if ($null -eq $Tree) {
        return
    }
    $assignments = @($Tree.FindAll({ $args[0] -is [AssignmentStatementAst] }, $true) |
        Where-Object { $_.Left -is [VariableExpressionAst] -and ($_.Left.VariablePath.UserPath -ieq $VariableName) })
    if ($assignments.Count -ne 1) {
        Add-Problem "$Label assigns `$$VariableName $($assignments.Count) times; it must be assigned exactly once."
        return
    }
    if ((Get-AssignedCommandName -Assignment $assignments[0]) -ine $CommandName) {
        Add-Problem "$Label does not get `$$VariableName from ${CommandName}: $($assignments[0].Extent.Text)"
    }
}

function Test-ReturnsOnlyFromCommand {
    param($FunctionAst, [string]$CommandName, [string]$Label)

    if ($null -eq $FunctionAst) {
        return
    }
    $returns = @($FunctionAst.FindAll({ $args[0] -is [ReturnStatementAst] }, $true))
    $others = @($returns | Where-Object {
        $pipeline = $_.Pipeline
        -not ($pipeline -is [PipelineAst] -and $pipeline.PipelineElements.Count -eq 1 -and
            $pipeline.PipelineElements[0] -is [CommandAst] -and
            ([string]$pipeline.PipelineElements[0].GetCommandName()) -ieq $CommandName)
    })
    if ($returns.Count -eq 0 -or $others.Count -gt 0) {
        Add-Problem (
            "$Label must return only the result of $CommandName; it has $($returns.Count) return statements, " +
            "$($others.Count) of them from something else."
        )
    }
}

function Test-CalledWithVariable {
    param($Tree, [string]$CommandName, [string]$ParameterName, [string]$VariableName, [string]$Label)

    if ($null -eq $Tree) {
        return
    }
    $calls = @($Tree.FindAll({ $args[0] -is [CommandAst] }, $true) |
        Where-Object { ([string]$_.GetCommandName()) -ieq $CommandName })
    if ($calls.Count -ne 1) {
        Add-Problem "$Label calls $CommandName $($calls.Count) times; it must call it exactly once."
        return
    }
    $elements = @($calls[0].CommandElements)
    $passes = $false
    for ($i = 0; $i -lt $elements.Count - 1; $i++) {
        if ($elements[$i] -is [CommandParameterAst] -and $elements[$i].ParameterName -ieq $ParameterName -and
            $elements[$i + 1] -is [VariableExpressionAst] -and
            ($elements[$i + 1].VariablePath.UserPath -ieq $VariableName)) {
            $passes = $true
        }
    }
    if (-not $passes) {
        Add-Problem "$Label does not call $CommandName with -$ParameterName `$${VariableName}: $($calls[0].Extent.Text)"
    }
}

function New-Invoker {
    param($FunctionAst, [string]$Call)

    if ($null -eq $FunctionAst) {
        return $null
    }
    return [scriptblock]::Create($FunctionAst.Extent.Text + [Environment]::NewLine + $FunctionAst.Name + $Call)
}

function Invoke-Reader {
    param([scriptblock]$Block, [string]$Text)

    try {
        $output = @(& $Block $Text)
    }
    catch {
        return [ordered]@{ ok = $false; odd = $false; version = ''; message = [string]$_.Exception.Message }
    }
    if ($output.Count -eq 1 -and $output[0] -is [Version]) {
        return [ordered]@{ ok = $true; odd = $false; version = $output[0].ToString(); message = '' }
    }
    return [ordered]@{
        ok = $false; odd = $true; version = ''; message = 'The reader did not return exactly one version.'
    }
}

$payload = [System.IO.File]::ReadAllText($PayloadPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$installerTree = Read-ScriptTree -Path ([string]$payload.installer) -Label 'installer'
$verifierTree = Read-ScriptTree -Path ([string]$payload.verifier) -Label 'verifier'
$installerReader = Get-OneFunction -Tree $installerTree -Name 'ConvertFrom-RcloneVersionText' -Label 'installer'
$verifierReader = Get-OneFunction -Tree $verifierTree -Name 'ConvertFrom-RcloneVersionText' -Label 'verifier'
$installerAssert = Get-OneFunction -Tree $installerTree -Name 'Assert-RcloneVersionAllowed' -Label 'installer'
$installerMinimum = Get-MinimumVersion -Container $installerAssert -VariableName 'minimum' `
    -Label 'The installer minimum (in Assert-RcloneVersionAllowed)'
$verifierMinimum = Get-MinimumVersion -Container $verifierTree -VariableName 'minimumRcloneVersion' `
    -Label 'The verifier minimum' -Tree $verifierTree -ScriptLevel

# The verifier decides at one place in its run: `$rcloneVersion -lt $minimumRcloneVersion`. The probe repeats that
# comparison below, so it must be there, once.
if ($null -ne $verifierTree) {
    $comparisons = @($verifierTree.FindAll({ $args[0] -is [BinaryExpressionAst] }, $true) |
        Where-Object {
            $_.Operator -eq [TokenKind]::Ilt -and
            $_.Left -is [VariableExpressionAst] -and ($_.Left.VariablePath.UserPath -ieq 'rcloneVersion') -and
            $_.Right -is [VariableExpressionAst] -and ($_.Right.VariablePath.UserPath -ieq 'minimumRcloneVersion')
        })
    if ($comparisons.Count -ne 1) {
        Add-Problem (
            "The verifier compares `$rcloneVersion -lt `$minimumRcloneVersion $($comparisons.Count) times; " +
            'it must do it exactly once.'
        )
    }
}

# Each script feeds its decision from the shared reader: the verifier's `$rcloneVersion` is the reader's result, the
# installer's Get-RcloneVersion returns only the reader's result, and the installer passes what it got to the check.
Test-AssignedFromCommand -Tree $verifierTree -VariableName 'rcloneVersion' `
    -CommandName 'ConvertFrom-RcloneVersionText' -Label 'The verifier'
$installerGetter = Get-OneFunction -Tree $installerTree -Name 'Get-RcloneVersion' -Label 'installer'
Test-ReturnsOnlyFromCommand -FunctionAst $installerGetter -CommandName 'ConvertFrom-RcloneVersionText' `
    -Label 'The installer Get-RcloneVersion'
Test-AssignedFromCommand -Tree $installerTree -VariableName 'rcloneVersion' -CommandName 'Get-RcloneVersion' `
    -Label 'The installer'
Test-CalledWithVariable -Tree $installerTree -CommandName 'Assert-RcloneVersionAllowed' -ParameterName 'Version' `
    -VariableName 'rcloneVersion' -Label 'The installer'

$installerRead = New-Invoker -FunctionAst $installerReader -Call ' -Text $args[0]'
$verifierRead = New-Invoker -FunctionAst $verifierReader -Call ' -Text $args[0]'
$installerRefuse = New-Invoker -FunctionAst $installerAssert -Call ' -Version $args[0]'

$results = @()
if ($null -ne $installerRead -and $null -ne $verifierRead) {
    foreach ($item in @($payload.inputs)) {
        $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$item.b64))
        $row = [ordered]@{
            index = [int]$item.index
            installer = Invoke-Reader -Block $installerRead -Text $text
            verifier = Invoke-Reader -Block $verifierRead -Text $text
        }
        foreach ($side in @('installer', 'verifier')) {
            $row[$side]['too_old'] = $null
            $row[$side]['refusal'] = ''
            if (-not $row[$side]['ok']) {
                continue
            }
            $version = [Version]$row[$side]['version']
            if ($side -eq 'installer') {
                # The installer's own decision: Assert-RcloneVersionAllowed as the installer defines it.
                if ($null -ne $installerRefuse) {
                    try {
                        & $installerRefuse $version | Out-Null
                        $row[$side]['too_old'] = $false
                    }
                    catch {
                        $row[$side]['too_old'] = $true
                        $row[$side]['refusal'] = [string]$_.Exception.Message
                    }
                }
            }
            elseif ($null -ne $verifierMinimum) {
                # The verifier's own decision: the comparison its run makes against its script-level minimum.
                $row[$side]['too_old'] = [bool]($version -lt $verifierMinimum)
            }
        }
        $results += $row
    }
}

$report = [ordered]@{
    problems = @($script:problems)
    installer_minimum = $(if ($null -ne $installerMinimum) { $installerMinimum.ToString() } else { '' })
    verifier_minimum = $(if ($null -ne $verifierMinimum) { $verifierMinimum.ToString() } else { '' })
    results = @($results)
}
$json = ConvertTo-Json -InputObject $report -Depth 6 -Compress
$evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) '\u{0:x4}' -f [int][char]$m.Value }
[Console]::Out.Write([regex]::Replace($json, '[^\x20-\x7e]', $evaluator))
"""


def run_probe():
    """Runs PROBE in Windows PowerShell 5.1 with no window and returns its report."""
    payload = {
        "installer": str(INSTALLER),
        "verifier": str(VERIFIER),
        "inputs": [
            {"index": index, "b64": base64.b64encode(text.encode("utf-8")).decode("ascii")}
            for index, (_, text, _) in enumerate(CASES)
        ],
    }
    system = os.environ.get("SystemRoot", r"C:\Windows")
    powershell = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    # A test run from PowerShell 7 hands that PowerShell's module folders down; 5.1 cannot load its own modules from
    # them. Only Windows' own folder is allowed, as the scripts under test do for themselves. The inherited key is
    # dropped first, whatever its case, so the child's environment holds one PSModulePath.
    environment = {key: value for key, value in os.environ.items() if key.upper() != "PSMODULEPATH"}
    environment["PSModulePath"] =os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "Modules")
    with tempfile.TemporaryDirectory(prefix="rewindle-version-parity-", ignore_cleanup_errors=True) as temp:
        script = Path(temp) / "probe.ps1"
        data = Path(temp) / "payload.json"
        script.write_bytes(PROBE.encode("ascii"))
        data.write_bytes(json.dumps(payload).encode("ascii"))
        completed = subprocess.run(
            [
                powershell,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
                str(data),
            ],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=600,
            check=False,
            env=environment,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    errors = completed.stderr.decode("utf-8", errors="replace")
    if completed.returncode != 0:
        raise AssertionError(
            f"the PowerShell probe failed with exit code {completed.returncode}:\n"
            + completed.stdout.decode("utf-8", errors="replace")
            + errors
        )
    try:
        output = completed.stdout.decode("ascii")
    except UnicodeDecodeError as error:
        raise AssertionError(f"the PowerShell probe printed something that is not ASCII: {error}") from error
    try:
        return json.loads(output)
    except ValueError as error:
        raise AssertionError(f"the PowerShell probe did not print JSON: {error}\n{output}\n{errors}") from error


@unittest.skipUnless(sys.platform == "win32", "Windows PowerShell 5.1 is Windows-only")
class RcloneVersionParityTests(unittest.TestCase):
    report = None

    @classmethod
    def setUpClass(cls):
        cls.report = run_probe()

    def complete_report(self):
        """The report, after checking that both scripts gave the probe everything it needs."""
        self.assertEqual(
            [],
            self.report["problems"],
            "the version check cannot be compared: a reader, an oldest allowed version or a call site is missing or not "
            "as expected",
        )
        self.assertEqual(len(CASES), len(self.report["results"]), "the probe did not read every input")
        return self.report

    def rows(self):
        report = self.complete_report()
        for (label, text, expected), row in zip(CASES, report["results"]):
            yield label, text, expected, row["installer"], row["verifier"]

    def test_both_scripts_define_the_reader_and_the_oldest_allowed_version(self):
        report = self.report
        self.assertEqual([], report["problems"])
        self.assertTrue(report["installer_minimum"], "the installer's oldest allowed version was not found")
        self.assertTrue(report["verifier_minimum"], "the verifier's oldest allowed version was not found")
        self.assertEqual(len(CASES), len(report["results"]))

    def test_every_input_is_read_the_same_way_by_both_scripts(self):
        different_wording = []
        for label, _, _, installer, verifier in self.rows():
            with self.subTest(label):
                self.assertFalse(installer["odd"], installer["message"])
                self.assertFalse(verifier["odd"], verifier["message"])
                self.assertEqual(
                    installer["ok"],
                    verifier["ok"],
                    f"one script reads this input and the other refuses it: installer {installer}, verifier {verifier}",
                )
                self.assertEqual(
                    installer["version"],
                    verifier["version"],
                    f"installer read {installer['version']}, verifier read {verifier['version']}",
                )
                if installer["message"] != verifier["message"]:
                    different_wording.append((label, installer["message"], verifier["message"]))
        # The wording of a refusal is each script's own business: it is reported, not compared.
        for label, installer_message, verifier_message in different_wording:
            sys.stderr.write(
                f"note: refusal worded differently for {label!r}: installer {installer_message!r}, "
                f"verifier {verifier_message!r}\n"
            )

    def test_known_inputs_are_read_as_expected_by_both_scripts(self):
        parsed = 0
        refused = 0
        for label, _, expected, installer, verifier in self.rows():
            if expected is None:
                continue
            for side, result in (("installer", installer), ("verifier", verifier)):
                with self.subTest(label, side=side):
                    if expected == REFUSED:
                        self.assertFalse(result["ok"], f"{side} accepted {label}: {result['version']}")
                    else:
                        self.assertTrue(result["ok"], f"{side} refused {label}: {result['message']}")
                        self.assertEqual(expected, result["version"])
            parsed += expected != REFUSED
            refused += expected == REFUSED
        # Enough inputs of each kind that readers which accept everything, or refuse everything, fail.
        self.assertGreaterEqual(parsed, 25)
        self.assertGreaterEqual(refused, 15)

    def test_both_scripts_require_the_same_oldest_version_1_65_0(self):
        report = self.complete_report()
        self.assertEqual(
            report["installer_minimum"],
            report["verifier_minimum"],
            f"installer minimum {report['installer_minimum']}, verifier minimum {report['verifier_minimum']}",
        )
        self.assertEqual(OLDEST_ALLOWED, report["installer_minimum"], "the installer's oldest allowed version")
        self.assertEqual(OLDEST_ALLOWED, report["verifier_minimum"], "the verifier's oldest allowed version")

    def test_1_64_2_and_1_65_0_are_decided_the_same_way_by_both_scripts(self):
        decided = {}
        for label, _, _, installer, verifier in self.rows():
            if installer["ok"] and verifier["ok"]:
                with self.subTest(label):
                    self.assertIsNotNone(installer["too_old"], f"the installer made no decision about {label}")
                    self.assertIsNotNone(verifier["too_old"], f"the verifier made no decision about {label}")
                    self.assertEqual(
                        installer["too_old"],
                        verifier["too_old"],
                        f"installer too old: {installer['too_old']}, verifier too old: {verifier['too_old']}",
                    )
                    if installer["too_old"]:
                        self.assertIn("older than", installer["refusal"])
                decided[label] = (installer["too_old"], verifier["too_old"])
        for version, too_old in TOO_OLD.items():
            self.assertEqual(
                (too_old, too_old),
                decided["plain " + version],
                f"{version} should be {'older than' if too_old else 'no older than'} the oldest allowed version",
            )
        self.assertGreaterEqual(len(decided), 25)


if __name__ == "__main__":
    unittest.main()
