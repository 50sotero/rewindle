"""The wrappers tests/Test-InstallerContract.ps1 starts the installer through, run here with a stand-in installer.

Test-InstallerContract.ps1 runs only on CI's disposable machine: it installs Rewindle for real, as scheduled tasks under two
test accounts. Such a run is a template script that a task starts with its streams captured (1> and 2>, see
Invoke-AsUserElevated). Windows PowerShell then turns every line that a program started by the template writes to stderr into
an error record, so a template that started the installer under $ErrorActionPreference = 'Stop' ended at the first such line
while the installer was still working: on CI the initializer's one-line refusal cut an install off before it wrote its result.
Here every template that starts the script under test runs that way (the plan template too, which today runs through
Invoke-AsUser instead), from the suite's own text, with a stand-in that writes to stderr halfway through, and must wait for it
and pass its exit code on.
"""

from __future__ import annotations

import base64
from contextlib import contextmanager
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid


PROJECT = Path(__file__).resolve().parents[1]
SUITE = PROJECT / "tests" / "Test-InstallerContract.ps1"
SYSTEM = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
WINDOWS_POWERSHELL = SYSTEM / "WindowsPowerShell" / "v1.0" / "powershell.exe"
CREATE_NO_WINDOW = 0x08000000
REFUSAL = "The backups in this location do not match the choice made in Setup."

# The stand-in for the installer (or the uninstaller). Like the installer, it starts a program in its own console with
# Diagnostics.Process and no redirection, so the program's stderr line goes straight to the stand-in's stderr; then it works on
# for a moment and exits with a code of its own, which a template's 'exit $LASTEXITCODE' must pass on.
STAND_IN = f"""$ErrorActionPreference = 'Stop'
$folder = $env:REWINDLE_STAND_IN_FOLDER
[IO.File]::WriteAllText((Join-Path $folder 'started.txt'), [string]$PID)
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $env:ComSpec
$start.Arguments = '/d /c "echo {REFUSAL} 1>&2 & exit /b 4"'
$start.UseShellExecute = $false
$process = [Diagnostics.Process]::Start($start)
$process.WaitForExit()
$refused = $process.ExitCode
Start-Sleep -Milliseconds 1500
[IO.File]::WriteAllText((Join-Path $folder 'finished.txt'), [string]$refused)
Write-Output 'The stand-in finished.'
exit 3
"""


def suite_text() -> str:
    return SUITE.read_text(encoding="utf-8")


def templates(text: str) -> dict[str, str]:
    """Every here-string in the suite that starts a script with '{{POWERSHELL}}', by the line its body starts on."""
    found = {}
    for match in re.finditer(r"@'\n(.*?)\n'@", text, re.DOTALL):
        body = match.group(1)
        if "& '{{POWERSHELL}}'" in body:
            found[f"line {text.count(chr(10), 0, match.start(1)) + 1}"] = body
    return found


@contextmanager
def ordinary_folder():
    """A new folder in the temporary folder with the access it inherits from there.

    Not tempfile's: since Python 3.13 its folders carry an OWNER RIGHTS entry, which .NET Framework's access-list round trip
    in the progress template drops, locking an account without elevation out of the folder that template makes.
    """
    path = Path(tempfile.gettempdir()) / f"rewindle-contract-wrapper-{uuid.uuid4().hex}"
    path.mkdir()
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


def read_log(path: Path) -> str:
    """A log the task wrote: Windows PowerShell's 1> and 2> write UTF-16 with a byte-order mark, [IO.File] UTF-8."""
    data = path.read_bytes() if path.is_file() else b""
    for mark, encoding in ((b"\xff\xfe", "utf-16-le"), (b"\xef\xbb\xbf", "utf-8")):
        if data.startswith(mark):
            return data[len(mark):].decode(encoding, errors="replace")
    return data.decode("utf-8", errors="replace")


def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def task_command(text: str, paths: dict[str, str]) -> str:
    """The command Invoke-AsUserElevated gives the scheduled task, built from the suite's own lines with these paths."""
    start = text.index("    $command = @(\n") + len("    $command = @(\n")
    end = text.index("\n    ) -join [Environment]::NewLine", start)
    lines = []
    for raw in text[start:end].split("\n"):
        item = raw.strip()
        literal = re.fullmatch(r"'((?:[^']|'')*)'", item)
        if literal:
            lines.append(literal.group(1).replace("''", "'"))
            continue
        formatted = re.fullmatch(r"\('((?:[^']|'')*)' -f (.+)\)", item)
        if not formatted:
            raise AssertionError(f"an unexpected line in Invoke-AsUserElevated's task command: {item}")
        names = re.findall(r"\(& \$quote \$(\w+)\)", formatted.group(2))
        # .NET's String.Format and Python's str.format read {0} and {{ }} the same way.
        lines.append(formatted.group(1).replace("''", "'").format(*(ps_quote(paths[name]) for name in names)))
    return "\n".join(lines)


@unittest.skipUnless(os.name == "nt" and WINDOWS_POWERSHELL.is_file(), "needs Windows PowerShell 5.1")
class InstallerContractWrapperTests(unittest.TestCase):
    def test_the_suite_has_the_templates_and_the_task_command_this_test_reads(self) -> None:
        text = suite_text()
        # The plan, the progress feed, the progress path outside the temporary folder, and the clean-up uninstall.
        self.assertEqual(4, len(templates(text)), sorted(templates(text)))
        command = task_command(text, {"scriptPath": "S", "stdout": "O", "stderr": "E", "exitPath": "X"})
        self.assertIn("& 'S' 1> 'O' 2> 'E'", command)

    def test_every_template_waits_for_the_script_and_passes_its_exit_code_on_when_it_writes_to_stderr(self) -> None:
        text = suite_text()
        for line, template in sorted(templates(text).items()):
            with self.subTest(template=line), ordinary_folder() as root:
                stand_in = root / "stand-in.ps1"
                stand_in.write_text(STAND_IN, encoding="utf-8-sig", newline="\n")
                values = {
                    "HANDOFF": str(root / "handoff.txt"),
                    "SCRIPT": str(stand_in),
                    "POWERSHELL": str(WINDOWS_POWERSHELL),
                    "ARGUMENTS": "",
                    "SID": "S-1-5-21-1-2-3-1001",
                }
                body = template
                for key, value in values.items():
                    body = body.replace("{{" + key + "}}", value)
                self.assertNotIn("{{", body)
                wrapper = root / "wrapper.ps1"
                # As Invoke-AsUserElevated writes it: UTF-8 with a byte-order mark.
                wrapper.write_text(body, encoding="utf-8-sig", newline="\n")
                paths = {
                    "scriptPath": str(wrapper),
                    "stdout": str(root / "wrapper.stdout.log"),
                    "stderr": str(root / "wrapper.stderr.log"),
                    "exitPath": str(root / "wrapper.exit.txt"),
                }
                encoded = base64.b64encode(task_command(text, paths).encode("utf-16-le")).decode("ascii")
                environment = dict(os.environ)
                # The unit step runs under PowerShell 7, whose module path Windows PowerShell must not inherit.
                environment["PSModulePath"] = str(WINDOWS_POWERSHELL.parent / "Modules")
                environment["REWINDLE_STAND_IN_FOLDER"] = str(root)
                environment["TEMP"] = environment["TMP"] = str(root)
                try:
                    subprocess.run(
                        [str(WINDOWS_POWERSHELL), "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
                        cwd=root, env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=120, check=False,
                        creationflags=CREATE_NO_WINDOW,
                    )
                    finished_when_the_task_ended = (root / "finished.txt").is_file()
                    stderr = read_log(Path(paths["stderr"]))
                    stdout = read_log(Path(paths["stdout"]))
                    self.assertTrue((root / "started.txt").is_file(), "the template started the stand-in")
                    self.assertTrue(finished_when_the_task_ended, "the template waited for the stand-in to finish:\n" + stderr)
                    self.assertEqual("3", Path(paths["exitPath"]).read_text(encoding="utf-8").strip(), "the stand-in's exit code")
                    self.assertEqual("4", (root / "finished.txt").read_text(encoding="utf-8").strip())
                    self.assertIn("The stand-in finished.", stdout)
                    # The line itself is kept in the stderr log, where Show-Run prints it.
                    self.assertIn(REFUSAL, " ".join(stderr.split()))
                finally:
                    # Without the fix the template ends first and the stand-in runs on: let it finish before the folder goes.
                    deadline = time.monotonic() + 15
                    while (root / "started.txt").is_file() and not (root / "finished.txt").is_file() and time.monotonic() < deadline:
                        time.sleep(0.2)
                    time.sleep(0.3)


if __name__ == "__main__":
    unittest.main()
