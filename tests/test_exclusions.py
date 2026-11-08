"""The default exclusion list (src/excludes.txt): what it leaves out, and what it says.

Restic reads the list with ``--iexclude-file``, so every rule matches whatever
the letter case. A one-word rule such as ``**/coverage`` therefore also left out
a home user's "Coverage" folder of insurance papers. These tests pin the list to
developer folders only, with Restic's own rules where the pinned Restic build is
present, and with the same rules written out here everywhere else.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
EXCLUDES = SOURCE / "excludes.txt"
RESTIC = PROJECT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"
# Set by CI's step after the release build, where a missing pinned restic.exe
# fails instead of skipping.
REQUIRE_PINNED_RESTIC = os.environ.get("REWINDLE_REQUIRE_PINNED_RESTIC") == "1"

import credential_repair  # noqa: E402
import restic_common  # noqa: E402


HOME = "C:/Users/you"

# Files a backup must keep: personal folders that only share a name with a
# developer folder, the parts of a developer folder that are not tool output,
# and a project folder that was itself made into a Python environment (its own
# code sits next to pyvenv.cfg, so a rule keyed on that file would drop it).
KEPT_FILES = (
    "Documents/Insurance/Coverage/policy.pdf",
    "Documents/Insurance/Coverage/Car/renewal.pdf",
    "Documents/Coverage.txt",
    "Documents/Venv/notes.txt",
    "Documents/.cache/notes.txt",
    ".cache/notes.txt",
    ".cache/other-tool/settings.json",
    "Projects/web/coverage/index.html",
    "Projects/py/venv/pyvenv.cfg",
    "Projects/inplace/pyvenv.cfg",
    "Projects/inplace/main.py",
)

# Reproducible developer output the list exists to leave out.
LEFT_OUT_FILES = (
    "Projects/web/node_modules/pkg/index.js",
    "Projects/web/coverage/lcov.info",
    "Projects/web/coverage/coverage-final.json",
    "Projects/web/coverage/coverage-summary.json",
    "Projects/web/coverage/clover.xml",
    "Projects/web/coverage/cobertura-coverage.xml",
    "Projects/web/coverage/lcov-report/index.html",
    "Projects/py/.venv/Lib/site-packages/pkg/__init__.py",
    "Projects/py/venv/Lib/site-packages/pkg/__init__.py",
    "Projects/py/venv/Scripts/python.exe",
    "Projects/py/venv/bin/python",
    "Projects/py/htmlcov/index.html",
    "Projects/py/.coverage",
    "Projects/py/pkg/__pycache__/mod.cpython-314.pyc",
    ".cache/huggingface/hub/model.bin",
    ".cache/torch/hub/weights.pt",
    ".cache/whisper/base.pt",
    ".cache/puppeteer/chrome/chrome.exe",
    ".cache/selenium/chromedriver/chromedriver.exe",
    ".cache/pre-commit/repo/hook.py",
)

# Folders the backup's own preflight must still walk (it checks them for
# online-only files, because the backup reads them), and folders it may skip
# whole because the backup leaves them out.
WALKED_FOLDERS = (
    "Documents/Insurance/Coverage",
    "Documents/Venv",
    "Documents/.cache",
    ".cache",
    "Projects/web/coverage",
    "Projects/py/venv",
)
SKIPPED_FOLDERS = (
    "Projects/web/node_modules",
    "Projects/web/coverage/lcov-report",
    "Projects/py/.venv",
    "Projects/py/venv/Lib",
    "Projects/py/venv/Scripts",
    ".cache/huggingface",
    ".cache/torch",
)


def active_patterns() -> list[str]:
    return [
        line.strip()
        for line in EXCLUDES.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def comment_text() -> str:
    """The list's notes as one line, so rewrapping them changes nothing."""
    return " ".join(
        line.lstrip()[1:].strip()
        for line in EXCLUDES.read_text(encoding="utf-8").splitlines()
        if line.lstrip().startswith("#") and line.lstrip()[1:].strip()
    )


def restic_rule_excludes(pattern: str, path: str) -> bool:
    """Restic's documented exclude rules, letter case ignored as with --iexclude-file.

    A pattern is split into path parts. ``**`` stands for any number of parts,
    and any other part is a filepath.Match pattern for exactly one path part. A
    pattern that does not start at a drive or the root may start at any folder,
    and a rule that matches a folder leaves out everything inside it.
    """
    pattern_parts = [
        part for part in pattern.replace("\\", "/").casefold().split("/") if part
    ]
    path_parts = [part for part in path.replace("\\", "/").casefold().split("/") if part]
    anchored = pattern.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", pattern)
    if not anchored and pattern_parts[:1] != ["**"]:
        pattern_parts.insert(0, "**")

    def match(pattern_index: int, path_index: int) -> bool:
        if pattern_index == len(pattern_parts):
            return path_index > 0
        part = pattern_parts[pattern_index]
        if part == "**":
            return any(
                match(pattern_index + 1, next_index)
                for next_index in range(path_index, len(path_parts) + 1)
            )
        return (
            path_index < len(path_parts)
            and fnmatch.fnmatchcase(path_parts[path_index], part)
            and match(pattern_index + 1, path_index + 1)
        )

    return match(0, 0)


def shipped_list_excludes(path: str) -> bool:
    return any(restic_rule_excludes(pattern, path) for pattern in active_patterns())


class ShippedExclusionListTests(unittest.TestCase):
    def test_personal_folders_that_share_a_developer_name_are_backed_up(self) -> None:
        for relative in KEPT_FILES:
            # Any letter case: the backup reads the list with --iexclude-file.
            for spelling in dict.fromkeys((relative, relative.upper(), relative.lower())):
                with self.subTest(path=spelling):
                    self.assertFalse(
                        shipped_list_excludes(f"{HOME}/{spelling}"),
                        f"the default list leaves out {spelling}",
                    )

    def test_developer_output_is_still_left_out(self) -> None:
        for relative in LEFT_OUT_FILES:
            with self.subTest(path=relative):
                self.assertTrue(
                    shipped_list_excludes(f"{HOME}/{relative}"),
                    f"the default list backs up {relative}",
                )

    def test_preflight_skips_only_folders_the_backup_leaves_out(self) -> None:
        rules = restic_common._literal_directory_exclusion_rules(EXCLUDES)
        for relative in WALKED_FOLDERS:
            with self.subTest(walked=relative):
                self.assertFalse(
                    restic_common._directory_is_definitely_excluded(
                        f"{HOME}/{relative}".replace("/", "\\"), rules
                    )
                )
        for relative in SKIPPED_FOLDERS:
            with self.subTest(skipped=relative):
                self.assertTrue(
                    restic_common._directory_is_definitely_excluded(
                        f"{HOME}/{relative}".replace("/", "\\"), rules
                    )
                )
                self.assertTrue(shipped_list_excludes(f"{HOME}/{relative}"))

    def test_rules_name_no_bare_folder_that_people_use_for_their_own_files(self) -> None:
        # One-part rules match a folder of that name anywhere, in any letter case.
        for word in ("coverage", "venv", ".cache"):
            with self.subTest(word=word):
                self.assertNotIn(f"**/{word}", [p.casefold() for p in active_patterns()])

    def test_list_stays_free_of_variables_and_whole_folder_wildcards(self) -> None:
        for pattern in active_patterns():
            with self.subTest(pattern=pattern):
                # Restic expands $NAME in an exclude file, and the backup runs
                # with a trimmed environment.
                self.assertNotIn("$", pattern)
                for protected in (".git", ".codex-worktrees"):
                    self.assertFalse(
                        restic_common._exclude_can_touch_protected_tree(
                            pattern, protected
                        )
                    )

    def test_backup_and_dry_run_pass_only_the_list_and_tagged_caches(self) -> None:
        # The rules above describe everything left out only while the backup
        # and the dry run add no other exclusion flag. A flag that leaves out a
        # whole folder because of a file inside it (--exclude-if-present
        # pyvenv.cfg, say) would drop the project kept in KEPT_FILES.
        flag = re.compile(r"[\"'](--i?exclude[-a-z]*)[\"']")
        for name in ("backup.py", "dry_run.py"):
            with self.subTest(module=name):
                text = (SOURCE / name).read_text(encoding="utf-8")
                self.assertEqual(
                    {"--iexclude-file", "--exclude-caches"},
                    set(flag.findall(text)),
                )

    def test_notes_do_not_invite_editing_the_installed_list(self) -> None:
        notes = comment_text()
        self.assertNotRegex(
            notes,
            r"(?i)customi[sz]e|review .* this file|edit this file|change this file",
        )
        self.assertIn("changes only with a Rewindle update", notes)
        self.assertIn("Protection", notes)

    def test_an_edited_installed_list_fails_the_runtime_check(self) -> None:
        # Why the notes say so: protected repairs and changes check every
        # installed file against the runtime manifest.
        with tempfile.TemporaryDirectory(prefix="rewindle-excludes-") as root_text:
            install = Path(root_text) / "Install"
            required = (
                "backup-config.json",
                "credential_repair.py",
                "key_rotation.py",
                "anomaly_review.py",
                "recovery_health.py",
                "restic_common.py",
                "secret_store.py",
                "restic.exe",
                r"Python\python.exe",
            )
            for relative in required:
                path = install / Path(relative)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"fixture {relative}\n", encoding="utf-8")
            installed_list = install / "excludes.txt"
            installed_list.write_bytes(EXCLUDES.read_bytes())
            rows = [
                {
                    "relative_path": relative,
                    "bytes": (install / Path(relative)).stat().st_size,
                    "sha256": restic_common.sha256_file(install / Path(relative)),
                }
                for relative in (*required, "excludes.txt")
            ]
            (install / "runtime-manifest.json").write_text(
                json.dumps({"schema_version": 1, "file_count": len(rows), "files": rows}),
                encoding="utf-8",
            )
            credential_repair.validate_runtime_manifest(install)

            with installed_list.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write("**/Videos\n")
            with self.assertRaisesRegex(RuntimeError, "does not match its manifest"):
                credential_repair.validate_runtime_manifest(install)


def pinned_restic_present() -> bool:
    if not RESTIC.is_file():
        return False
    release = json.loads((SOURCE / "restic-release.json").read_text(encoding="utf-8"))
    digest = hashlib.sha256(RESTIC.read_bytes()).hexdigest()
    return digest == release["executable_sha256"]


@unittest.skipUnless(
    os.name == "nt" and (pinned_restic_present() or REQUIRE_PINNED_RESTIC),
    "needs the release build's pinned restic.exe (run build\\Build-Release.ps1)",
)
class PinnedResticExclusionTests(unittest.TestCase):
    """The same files, through the pinned Restic in a throwaway backup."""

    maxDiff = None

    @classmethod
    def setUpClass(cls) -> None:
        if not pinned_restic_present():
            raise AssertionError(
                f"REWINDLE_REQUIRE_PINNED_RESTIC is set, but {RESTIC} is missing "
                "or is not the pinned release"
            )

    def test_pinned_restic_keeps_personal_folders_and_leaves_out_developer_output(self) -> None:
        tagged_cache = ("Projects/tool-cache/CACHEDIR.TAG", "Projects/tool-cache/blob.bin")
        with tempfile.TemporaryDirectory(prefix="rewindle-exclusions-") as root_text:
            root = Path(root_text)
            source = root / "probe-source"
            for relative in (*KEPT_FILES, *LEFT_OUT_FILES, *tagged_cache):
                path = source / Path(relative)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture\n", encoding="ascii")
            (source / tagged_cache[0]).write_text(
                "Signature: 8a477f597d28d172789f06886806bc55\n", encoding="ascii"
            )
            # Only what Restic needs: no inherited RESTIC_* settings can point
            # it at any other backup.
            environment = {
                name: os.environ[name]
                for name in ("SYSTEMROOT", "TEMP", "TMP")
                if name in os.environ
            }
            environment["RESTIC_PASSWORD"] = "exclusion-test-only"
            repository = root / "repository"
            common = [str(RESTIC), "--repo", str(repository), "--no-cache"]
            initialized = subprocess.run(
                [*common, "init"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=120,
                env=environment,
            )
            self.assertEqual(0, initialized.returncode, initialized.stderr)
            # The exclusion flags backup.py and dry_run.py pass (see the
            # flag test above), in a dry run that lists every file it would save.
            listed = subprocess.run(
                [
                    *common,
                    "--json",
                    "backup",
                    str(source),
                    "--dry-run",
                    "-vv",
                    "--iexclude-file",
                    str(EXCLUDES),
                    "--exclude-caches",
                ],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=120,
                env=environment,
            )
            self.assertEqual(0, listed.returncode, listed.stderr)
            saved: set[str] = set()
            for line in listed.stdout.splitlines():
                message = json.loads(line)
                item = str(message.get("item") or "")
                if (
                    message.get("message_type") == "verbose_status"
                    and message.get("action") == "new"
                    and "/probe-source/" in item
                    and not item.endswith("/")
                ):
                    saved.add(item.split("/probe-source/", 1)[1])

            self.assertEqual(
                sorted(KEPT_FILES + tagged_cache[:1]),
                sorted(saved),
            )
            # The rules written out above agree with Restic on every file.
            for relative in (*KEPT_FILES, *LEFT_OUT_FILES):
                with self.subTest(path=relative):
                    self.assertEqual(
                        relative not in saved,
                        shipped_list_excludes(f"{HOME}/{relative}"),
                    )


if __name__ == "__main__":
    unittest.main()
