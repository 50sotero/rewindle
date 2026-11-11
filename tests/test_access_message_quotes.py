"""The sentences Rewindle says when backups stop opening the way it expects, and the documents that quote them.

Each sentence lives in code, and docs/engine-contract.md, SECURITY.md and docs/architecture.md describe them. Nothing here keeps a
copy of a sentence: every one is read from the file that says it (Python constants through their syntax tree, C# and PowerShell
string literals through a pattern), so rewording a sentence in the code fails the test that finds the old words in a document.
Quotes are compared apart from apostrophe style (the dashboard writes a curly one) and line wrapping.

  T5  the dashboard's words for a run that ended as `repository_access_mismatch` (Telemetry.cs, RunDetailsWindow.cs)
  T6  recovery_health.py: backups made without a password that now ask for one
  T7  recovery_health.py: backups made with a password that now open without one
  T8  restore.py (and the protected manager's own copy): backups without a password that Restic now refuses with exit 12
"""

from __future__ import annotations

import ast
from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
TELEMETRY = SOURCE / "dashboard" / "Telemetry.cs"
RUN_DETAILS = SOURCE / "dashboard" / "RunDetailsWindow.cs"
RECOVERY_HEALTH = SOURCE / "recovery_health.py"
RESTORE = SOURCE / "restore.py"
MANAGE_RESTORE = SOURCE / "Manage-Restore.ps1"
ENGINE_CONTRACT = PROJECT / "docs" / "engine-contract.md"
ARCHITECTURE = PROJECT / "docs" / "architecture.md"
SECURITY = PROJECT / "SECURITY.md"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def plain(text: str) -> str:
    """The text apart from apostrophe style and line wrapping."""
    return " ".join(text.replace("\u2019", "'").split())


def python_constant(path: Path, name: str) -> str:
    """The string a module assigns to `name` at its top level, read from the syntax tree (the module is never imported)."""
    for node in ast.parse(read(path)).body:
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == name for target in node.targets):
            value = ast.literal_eval(node.value)
            if not isinstance(value, str):
                raise AssertionError(f"{name} in {path.name} is not a string")
            return value
    raise AssertionError(f"{path.name} has no top-level constant {name}")


def csharp_unescape(literal: str) -> str:
    """A C# string literal's body with its escapes (\\u2019, \\\", \\\\) decoded."""
    escapes = {'"': '"', "\\": "\\", "'": "'", "n": "\n", "t": "\t"}

    def decode(match: re.Match[str]) -> str:
        escape = match.group(1)
        return chr(int(escape[1:], 16)) if len(escape) == 5 else escapes[escape]

    return re.sub(r"\\(u[0-9a-fA-F]{4}|.)", decode, literal)


def csharp_case_text(path: Path, case: str) -> str:
    """The sentence a C# `case "<case>": return "...";` gives back."""
    match = re.search(r'case "%s":\s*return "((?:[^"\\\n]|\\.)*)";' % re.escape(case), read(path))
    if match is None:
        raise AssertionError(f'{path.name} has no `case "{case}": return "...";`')
    return csharp_unescape(match.group(1))


def powershell_string(path: Path, variable: str) -> str:
    """The single-quoted string a script assigns to `$variable` ('' is one apostrophe)."""
    match = re.search(r"^\$%s = '((?:[^']|'')*)'\s*$" % re.escape(variable), read(path), re.M)
    if match is None:
        raise AssertionError(f"{path.name} has no `${variable} = '...'`")
    return match.group(1).replace("''", "'")


def dashboard_text() -> str:
    """T5, as Telemetry.cs words it (run details and the Protection line use it)."""
    return csharp_case_text(TELEMETRY, "repository_access_mismatch")


def readiness_asks_text() -> str:
    return python_constant(RECOVERY_HEALTH, "NO_PASSWORD_NOW_ASKS_DETAIL")


def readiness_opens_text() -> str:
    return python_constant(RECOVERY_HEALTH, "PASSWORD_NOW_OPENS_FREELY_DETAIL")


def restore_text() -> str:
    return python_constant(RESTORE, "NOW_ASKS_FOR_A_PASSWORD_MESSAGE")


class TheCodeAgreesWithItselfTests(unittest.TestCase):
    def test_the_sentences_were_found_and_are_four_different_ones(self) -> None:
        # A pattern that found nothing would make every comparison below pass on an empty text.
        texts = [dashboard_text(), readiness_asks_text(), readiness_opens_text(), restore_text()]
        for text in texts:
            self.assertGreater(len(text), 80)
            self.assertTrue(text.startswith("These backups now "), text)
            self.assertTrue(text.endswith("."), text)
        self.assertEqual(4, len({plain(text) for text in texts}))

    def test_both_dashboard_windows_say_the_same_thing_for_a_run_that_ended_as_a_changed_backup(self) -> None:
        self.assertEqual(plain(dashboard_text()), plain(csharp_case_text(RUN_DETAILS, "repository_access_mismatch")))

    def test_the_protected_restore_manager_has_the_text_restore_py_says(self) -> None:
        # The manager shows its own copy, and only when it is the whole of restore.py's last line, so the two must be one text.
        self.assertEqual(restore_text(), powershell_string(MANAGE_RESTORE, "backupsNowAskForAPasswordMessage"))


class TheDocumentsQuoteTheCodeTests(unittest.TestCase):
    def test_the_engine_contract_quotes_the_four_sentences(self) -> None:
        contract = plain(read(ENGINE_CONTRACT))
        for name, text in (
            ("T5", dashboard_text()),
            ("T6", readiness_asks_text()),
            ("T7", readiness_opens_text()),
            ("T8", restore_text()),
        ):
            with self.subTest(text=name):
                self.assertIn(plain(text), contract)

    def test_security_quotes_what_the_dashboard_and_the_readiness_check_say(self) -> None:
        security = plain(read(SECURITY))
        for name, text in (("T5", dashboard_text()), ("T6", readiness_asks_text()), ("T7", readiness_opens_text())):
            with self.subTest(text=name):
                self.assertIn(plain(text), security)

    def test_the_restore_sentence_points_to_a_guide_that_exists_and_says_what_it_promises(self) -> None:
        text = restore_text()
        self.assertIn("RECOVERY.md in the recovery tools folder next to your backups", text)
        guide = plain(read(SOURCE / "RECOVERY.md"))
        # What the sentence leans on: the guide tells a person who knows that password how to restore with Restic itself.
        self.assertIn("these backups now have a password, usually because one was added outside Rewindle", guide)
        self.assertIn(
            'Run the commands under "Recovery-key restore" without the option, and give Restic the password that was added when it asks',
            guide,
        )

    def test_the_architecture_notes_give_the_next_step_the_dashboard_text_gives(self) -> None:
        text = plain(dashboard_text())
        self.assertIn("start new backups in another place", text)
        self.assertNotIn("SECURITY.md", text)  # the dashboard's text has no pointer, so the notes must not claim one
        notes = read(ARCHITECTURE)
        start = notes.index("- Backups made without a password that now ask for one")
        bullet = plain(notes[start:].split("\n- ", 1)[0])
        self.assertIn("`repository_access_mismatch`", bullet)
        self.assertIn("tells the person to start new backups in another place, instead of advising a check of the backup drive", bullet)
        self.assertIn("Nothing is retried or switched.", bullet)
        self.assertNotIn("SECURITY.md", bullet)
        self.assertNotIn("Switching an existing backup", bullet)
        # Where a text still names the SECURITY.md section (T7, and the installer's refusal), the section exists to be named.
        self.assertIn("SECURITY.md", plain(readiness_opens_text()))
        self.assertRegex(read(SECURITY), r"(?m)^## Switching an existing backup\s*$")

    def test_the_engine_contract_says_how_restore_py_and_its_manager_pass_the_restore_sentence_on(self) -> None:
        contract = plain(read(ENGINE_CONTRACT))
        start = contract.index("When Restic answers exit 12 (the backups now ask for a password) to any way `restore.py` reads")
        paragraph = contract[start:].split("The restore drill runs with no key", 1)[0]
        # Every way restore.py reads the backups says it, and the manager passes it on for every kind of request.
        self.assertIn("(a listing, a folder, a search, a restore, the drill)", paragraph)
        self.assertIn(plain(restore_text()), paragraph)
        self.assertIn("`Manage-Restore.ps1` has its own copy of that text", paragraph)
        self.assertIn("for every request kind (listing, folder, search, restore, drill)", paragraph)
        self.assertIn("when it is the whole of `restore.py`'s last stderr line", paragraph)
        self.assertIn("it reads no other stderr", paragraph)
        # The manager's copy is only as honest as the exact text it compares; the prefix restore.py gives that line is documented.
        self.assertIn("after `RESTORE FAILED: `", paragraph)
        self.assertIn('print(f"RESTORE FAILED: {error}", file=sys.stderr)', read(RESTORE))
        self.assertIn("'RESTORE FAILED: ' + $backupsNowAskForAPasswordMessage", read(MANAGE_RESTORE))


if __name__ == "__main__":
    unittest.main()
