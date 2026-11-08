"""WSL links and special files that the pinned Restic cannot store are left out of a run.

Restic 0.19.1 on Windows sees a WSL symbolic link, FIFO, or character or block
device on an NTFS drive as an irregular file, fails it, and ends the run with
exit 3, so the backup is never verified and restore and clean-up refuse to run.
The source walk finds them by their reparse tag (tests/test_plan_preflight.py),
and backup.py leaves each one out of that run with a generated exclusion file
that names exactly its path. These tests check the lines of that file, the
backup command and status.json, and, where the release build's pinned
restic.exe is present, what Restic itself leaves out.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "src"
sys.path.insert(0, str(SOURCE))
EXCLUDES = SOURCE / "excludes.txt"
RESTIC = PROJECT / "build" / "build-output" / "ResticBackuper" / "payload" / "restic.exe"

import backup  # noqa: E402
import restic_common  # noqa: E402


PLAN_ID = "30000000-0000-4000-8000-000000000003"
PLAN_TAG = "restic-backuper-plan:" + PLAN_ID
GENERATION_TAG = "restic-backuper-generation:1"
REPOSITORY_ID = "f" * 64
NO_TAGS = {"lx_symlink": 0, "lx_fifo": 0, "lx_chr": 0, "lx_blk": 0}
NOTHING_KEPT_IN = {"count": 0, "reasons": {}, "samples": []}


def found_in(configured: str, *relative_paths: str, tag: str = "lx_symlink") -> dict[str, object]:
    """One source's entry in preflight_sources' "unarchivable_links"."""
    return {
        "configured_path": configured,
        "entries": [{"relative_path": path, "tag": tag} for path in relative_paths],
        "not_left_out": {"count": 0, "reasons": {}, "samples": []},
    }


class ExclusionLineTests(unittest.TestCase):
    def test_each_character_restic_reads_specially_is_escaped(self) -> None:
        cases = {
            "C:/Users/you/plain name.txt": "C:/Users/you/plain name.txt",
            "C:/Users/you/a[b]": "C:/Users/you/a[[]b]",
            "C:/Users/you/c[d": "C:/Users/you/c[[]d",
            "C:/Users/you/m]n": "C:/Users/you/m]n",
            "C:/Users/you/x$y": "C:/Users/you/x$$y",
            "C:/Users/you/$HOME/x$$y": "C:/Users/you/$$HOME/x$$$$y",
            "C:/Users/you/q*r?": "C:/Users/you/q[*]r[?]",
            # Only white space at the very end is trimmed by Restic.
            "C:/Users/you/ lead/mid dle/trail ": "C:/Users/you/ lead/mid dle/trail[ ]",
            "C:/Users/you/two  ": "C:/Users/you/two[ ][ ]",
            "C:/Users/you/wide\u3000\xa0": "C:/Users/you/wide[\u3000][\xa0]",
            # The space is not at the end, so only "[" and "$" change.
            "C:/Users/you/[$ ]": "C:/Users/you/[[]$$ ]",
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(expected, backup.restic_literal_exclude(path))

    def test_lines_start_from_each_source_as_configured(self) -> None:
        # A short (8.3) name and the letter case stay as configured: that is the
        # path Restic is given, and so the one it walks.
        config = {
            "sources": [r"E:\PROJEC~1\App", "D:\\"],
            "canary_file": r"E:\PROJEC~1\App\backup-canary.txt",
        }
        lines, record = backup.unarchivable_exclusions(
            config,
            [
                found_in(
                    r"E:\PROJEC~1\App", "wsl\\bin\\python3", "mid dle \\notes [1]$draft\xa0"
                ),
                found_in("D:\\", "dev\\null", tag="lx_chr"),
            ],
        )
        self.assertEqual(
            [
                "E:/PROJEC~1/App/wsl/bin/python3",
                "E:/PROJEC~1/App/mid dle /notes [[]1]$$draft[\xa0]",
                "D:/dev/null",
            ],
            lines,
        )
        self.assertEqual(
            {
                "count": 3,
                "samples": [
                    r"E:\PROJEC~1\App\wsl\bin\python3",
                    "E:\\PROJEC~1\\App\\mid dle \\notes [1]$draft\xa0",
                    r"D:\dev\null",
                ],
                "tags": {"lx_symlink": 2, "lx_fifo": 0, "lx_chr": 1, "lx_blk": 0},
                "not_left_out": NOTHING_KEPT_IN,
            },
            record,
        )

    def test_nothing_found_gives_no_lines_and_an_empty_record(self) -> None:
        config = {"sources": [r"C:\Data"], "canary_file": r"C:\Data\canary.txt"}
        for found in (None, []):
            with self.subTest(found=found):
                self.assertEqual(
                    (
                        [],
                        {
                            "count": 0,
                            "samples": [],
                            "tags": NO_TAGS,
                            "not_left_out": NOTHING_KEPT_IN,
                        },
                    ),
                    backup.unarchivable_exclusions(config, found),
                )

    def test_a_line_must_name_one_path_strictly_inside_its_source(self) -> None:
        config = {"sources": [r"C:\Data"], "canary_file": r"C:\Data\backup-canary.txt"}
        unusable = (
            "",
            ".",
            "..",
            "a\\..\\..\\Windows",
            "a\\.\\b",
            "a\\\\b",
            "a/b",
            "C:x",
            "line\nbreak",
            # Windows drops these before Restic matches, so the line would name another item.
            "trail ",
            "dot.",
            "...",
        )
        for relative in unusable:
            with self.subTest(relative=relative):
                with self.assertRaisesRegex(RuntimeError, "unusable relative path"):
                    backup.unarchivable_exclusions(config, [found_in(r"C:\Data", relative)])
        with self.assertRaisesRegex(RuntimeError, "not strictly inside"):
            backup.unarchivable_exclusions(
                config, [found_in(r"C:\Data", "backup-canary.txt")]
            )
        with self.assertRaisesRegex(RuntimeError, "outside the configured sources"):
            backup.unarchivable_exclusions(config, [found_in(r"C:\Other", "link")])
        with self.assertRaisesRegex(RuntimeError, "unknown reparse tag"):
            backup.unarchivable_exclusions(
                config, [found_in(r"C:\Data", "link", tag="junction")]
            )

    def test_entries_kept_in_are_counted_and_sampled_across_sources(self) -> None:
        config = {"sources": [r"C:\Data", r"E:\Projects"], "canary_file": r"C:\Data\c.txt"}

        def kept_in(configured: str, count: int, reason: str) -> dict[str, object]:
            return {
                "configured_path": configured,
                "entries": [],
                "not_left_out": {
                    "count": count,
                    "reasons": {reason: count},
                    "samples": [
                        {"relative_path": f"link-{index}\udc80", "tag": "lx_fifo", "reason": reason}
                        for index in range(min(count, 20))
                    ],
                },
            }

        lines, record = backup.unarchivable_exclusions(
            config,
            [kept_in(r"C:\Data", 15, "case_twin"), kept_in(r"E:\Projects", 30, "over_limit")],
        )
        self.assertEqual([], lines)
        self.assertEqual(0, record["count"])
        kept = record["not_left_out"]
        self.assertEqual(45, kept["count"])
        self.assertEqual({"case_twin": 15, "over_limit": 30}, kept["reasons"])
        self.assertEqual(20, len(kept["samples"]))
        self.assertEqual(
            {"path": "C:\\Data\\link-0\ufffd", "tag": "lx_fifo", "reason": "case_twin"},
            kept["samples"][0],
        )
        self.assertEqual("E:\\Projects\\link-4\ufffd", kept["samples"][19]["path"])
        # A name that is not valid Unicode reaches status.json as U+FFFD.
        json.dumps(record, ensure_ascii=False).encode("utf-8")


class BackupRun:
    """One backup._run_locked run against fake Restic, with the given preflight findings."""

    def __init__(self, root: Path) -> None:
        self.source = root / "source"
        self.source.mkdir()
        (root / "repository").mkdir()
        self.state = root / "state"
        self.state.mkdir()
        self.excludes = root / "excludes.txt"
        self.excludes.write_text("**/__pycache__\n", encoding="utf-8", newline="\n")
        restic = root / "restic.exe"
        restic.write_bytes(b"fixture")
        canary = self.source / "canary.txt"
        canary.write_text("canary\n", encoding="utf-8", newline="\n")
        self.config: dict[str, object] = {
            "plan_id": PLAN_ID,
            "config_generation": 1,
            "scheduled_tag": "scheduled",
            "state_directory": str(self.state),
            "repository": str(root / "repository"),
            "repository_volume_serial": "A1B2C3D4",
            "hostname": "LINKS-TEST",
            "sources": [str(self.source)],
            "exclude_file": str(self.excludes),
            "restic_executable": str(restic),
            "canary_file": str(canary),
            "use_vss": False,
            "read_concurrency": 2,
            "structural_check_after_backup": True,
            "read_data_subset_parts": 0,
            "source_identities": {str(self.source): {"expected_volume_serial": "A1B2C3D4"}},
            "cloud_placeholder_policy": "strict",
        }
        self.backup_commands: list[list[str]] = []

    @property
    def generated(self) -> Path:
        return self.state / "unarchivable-excludes.txt"

    def document(self, name: str) -> dict[str, object]:
        return json.loads((self.state / name).read_text(encoding="utf-8"))

    def log_events(self) -> list[dict[str, object]]:
        (log,) = (self.state / "logs").glob("backup-*.jsonl.log")
        return [
            json.loads(line)
            for line in log.read_text(encoding="utf-8").splitlines()
            if line.startswith("{")
        ]

    def expected_command(self, *extra_exclusions: str) -> list[str]:
        """Today's backup command, with any generated exclusion file after the installed list."""
        return [
            "restic",
            "backup",
            str(self.source),
            "--iexclude-file",
            str(self.excludes),
            *[item for path in extra_exclusions for item in ("--iexclude-file", path)],
            "--exclude-caches",
            "--skip-if-unchanged",
            "--no-scan",
            "--read-concurrency",
            "2",
            "--group-by",
            "host,paths,tags",
            "--host",
            "LINKS-TEST",
            "--tag",
            "scheduled",
            "--tag",
            PLAN_TAG,
            "--tag",
            GENERATION_TAG,
        ]

    def run(self, found: object = None, *, backup_exit: int = 0) -> int:
        source = str(self.source)
        snapshot_calls = 0

        def fake_capture(command, **_kwargs):
            nonlocal snapshot_calls
            if command[1] == "cat":
                return subprocess.CompletedProcess(
                    ["restic"], 0, json.dumps({"id": REPOSITORY_ID, "version": 2}), ""
                )
            snapshot_calls += 1
            payload = []
            if snapshot_calls > 1:
                payload = [
                    {
                        "id": "new-snapshot",
                        "hostname": "LINKS-TEST",
                        "tags": ["scheduled", PLAN_TAG, GENERATION_TAG],
                        "paths": [source],
                        "time": "2026-11-09T02:00:00Z",
                    }
                ]
            return subprocess.CompletedProcess(["restic"], 0, json.dumps(payload), "")

        def fake_stream(command, _log, on_line=None, **_kwargs):
            if command[1] == "backup":
                self.backup_commands.append(list(command))
                # Restic has read the generated file by the time it reports.
                if "--iexclude-file" in command[5:]:
                    path = Path(command[command.index("--iexclude-file", 5) + 1])
                    self.generated_bytes = path.read_bytes()
                on_line(
                    json.dumps(
                        {
                            "message_type": "summary",
                            "snapshot_id": "new-snapshot",
                            "total_files_processed": 1,
                            "total_bytes_processed": 1,
                            "files_new": 1,
                            "files_changed": 0,
                            "data_added": 1,
                        }
                    )
                )
                return backup_exit
            if command[1] == "check":
                return 0
            raise AssertionError(f"unexpected fake Restic verb: {command[1]}")

        ready: dict[str, object] = {
            "schema_version": 1,
            "policy": "strict",
            "status": "ready",
            "sources": [
                {
                    "configured_path": source,
                    "canonical_path": source,
                    "readiness": "ready",
                    "volume_identity": "match",
                    "overall_status": "ready",
                }
            ],
            "failures": [],
        }
        if found is not None:
            ready["unarchivable_links"] = found
        with (
            mock.patch.object(backup, "validate_repository_volume"),
            mock.patch.object(backup, "ensure_free_space", return_value=1),
            mock.patch.object(backup, "preflight_sources", return_value=ready),
            mock.patch.object(backup, "restic_base", return_value=["restic"]),
            mock.patch.object(backup, "run_capture", side_effect=fake_capture),
            mock.patch.object(backup, "stream_command", side_effect=fake_stream),
            mock.patch.object(backup, "verify_canary", return_value={"verified": True}),
            mock.patch.object(
                backup, "process_start_filetime", return_value="133733333333333333"
            ),
        ):
            return backup._run_locked(
                argparse.Namespace(tag=None, scheduled=False), self.config
            )


class BackupCommandTests(unittest.TestCase):
    def test_one_link_is_left_out_with_a_second_exclusion_file(self) -> None:
        with tempfile.TemporaryDirectory(prefix="unarchivable-one-") as root_text:
            run = BackupRun(Path(root_text))
            source = str(run.source)
            result = run.run([found_in(source, "wsl\\link [1]$x")])

            self.assertEqual(0, result)
            self.assertEqual(
                [run.expected_command(str(run.generated))], run.backup_commands
            )
            line = source.replace("\\", "/") + "/wsl/link [[]1]$$x"
            # UTF-8 without a byte order mark, LF line endings, one line per link.
            expected_bytes = (line + "\n").encode("utf-8")
            self.assertEqual(expected_bytes, run.generated_bytes)
            self.assertEqual(expected_bytes, run.generated.read_bytes())

            status = run.document("status.json")
            self.assertEqual("success", status["state"])
            self.assertEqual(
                {
                    "count": 1,
                    "samples": [source + "\\wsl\\link [1]$x"],
                    "tags": {**NO_TAGS, "lx_symlink": 1},
                    "not_left_out": NOTHING_KEPT_IN,
                },
                status["unarchivable_links"],
            )
            self.assertNotIn("unarchivable_links", status["source_preflight"])
            self.assertEqual(
                status["unarchivable_links"],
                run.document("last-success.json")["unarchivable_links"],
            )
            # The change-anomaly comparison still hashes only the installed list.
            self.assertEqual(
                hashlib.sha256(run.excludes.read_bytes()).hexdigest(),
                status["exclude_file_sha256"],
            )
            (event,) = [
                event
                for event in run.log_events()
                if event.get("wrapper_event") == "unarchivable_links_left_out"
            ]
            self.assertEqual(1, event["count"])
            self.assertEqual(0, event["not_left_out"])
            self.assertEqual(str(run.generated), event["exclude_file"])

    def test_without_links_the_command_is_unchanged_and_a_stale_file_is_removed(self) -> None:
        for found in (None, []):
            with self.subTest(found=found):
                with tempfile.TemporaryDirectory(prefix="unarchivable-none-") as root_text:
                    run = BackupRun(Path(root_text))
                    run.generated.write_text(
                        "C:/Users/you/left over\n", encoding="utf-8", newline="\n"
                    )
                    self.assertEqual(0, run.run(found))
                    self.assertEqual([run.expected_command()], run.backup_commands)
                    self.assertFalse(run.generated.exists())
                    status = run.document("status.json")
                    self.assertEqual(0, status["unarchivable_links"]["count"])
                    self.assertEqual(
                        [],
                        [
                            event
                            for event in run.log_events()
                            if event.get("wrapper_event") == "unarchivable_links_left_out"
                        ],
                    )

    def test_links_kept_in_still_end_the_run_as_partial(self) -> None:
        with tempfile.TemporaryDirectory(prefix="unarchivable-partial-") as root_text:
            run = BackupRun(Path(root_text))
            source = str(run.source)
            kept_in = {
                "configured_path": source,
                "entries": [],
                "not_left_out": {
                    "count": 1,
                    "reasons": {"case_twin": 1},
                    "samples": [
                        {"relative_path": "Link", "tag": "lx_symlink", "reason": "case_twin"}
                    ],
                },
            }
            self.assertEqual(3, run.run([kept_in], backup_exit=3))
            self.assertEqual([run.expected_command()], run.backup_commands)
            status = run.document("status.json")
            self.assertEqual("partial", status["state"])
            self.assertFalse(status["verification_complete"])
            self.assertFalse((run.state / "last-success.json").exists())
            self.assertEqual(
                {
                    "count": 1,
                    "reasons": {"case_twin": 1},
                    "samples": [
                        {"path": source + "\\Link", "tag": "lx_symlink", "reason": "case_twin"}
                    ],
                },
                status["unarchivable_links"]["not_left_out"],
            )


def pinned_restic_present() -> bool:
    if not RESTIC.is_file():
        return False
    release = json.loads((SOURCE / "restic-release.json").read_text(encoding="utf-8"))
    digest = hashlib.sha256(RESTIC.read_bytes()).hexdigest()
    return digest == release["executable_sha256"]


def extended(path: str) -> str:
    """A Win32 path Windows takes as written, keeping a trailing space."""
    return "\\\\?\\" + path


def make_wsl_special_file(path: str, tag: int, data: bytes = b"") -> None:
    """Create an empty file carrying a WSL reparse tag, as WSL stores its links on NTFS."""
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    create_file = kernel32.CreateFileW
    create_file.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    create_file.restype = wintypes.HANDLE
    device_io_control = kernel32.DeviceIoControl
    device_io_control.argtypes = [
        wintypes.HANDLE,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        wintypes.LPVOID,
    ]
    device_io_control.restype = wintypes.BOOL
    close_handle = kernel32.CloseHandle
    close_handle.argtypes = [wintypes.HANDLE]
    generic_write = 0x40000000
    create_new = 1
    file_flag_open_reparse_point = 0x00200000
    file_flag_backup_semantics = 0x02000000
    fsctl_set_reparse_point = 0x000900A4
    handle = create_file(
        path,
        generic_write,
        0,
        None,
        create_new,
        file_flag_open_reparse_point | file_flag_backup_semantics,
        None,
    )
    if handle in (None, wintypes.HANDLE(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        # REPARSE_DATA_BUFFER: tag, data length, reserved, then the data.
        buffer = struct.pack("<IHH", tag, len(data), 0) + data
        raw = ctypes.create_string_buffer(buffer, len(buffer))
        returned = wintypes.DWORD()
        if not device_io_control(
            handle,
            fsctl_set_reparse_point,
            raw,
            len(buffer),
            None,
            0,
            ctypes.byref(returned),
            None,
        ):
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        close_handle(handle)


@unittest.skipUnless(
    os.name == "nt" and pinned_restic_present(),
    "needs the release build's pinned restic.exe (run build\\Build-Release.ps1)",
)
class PinnedResticUnarchivableTests(unittest.TestCase):
    """What the pinned Restic leaves out with the generated file, in a throwaway repository."""

    maxDiff = None

    def restic(self, root: Path) -> list[str]:
        # Only what Restic needs: no inherited RESTIC_* setting can point it at any other backup.
        self.environment = {
            name: os.environ[name] for name in ("SYSTEMROOT", "TEMP", "TMP") if name in os.environ
        }
        self.environment["RESTIC_PASSWORD"] = "unarchivable-test-only"
        common = [str(RESTIC), "--repo", str(root / "repository"), "--no-cache"]
        initialized = self.run_restic([*common, "init"])
        self.assertEqual(0, initialized.returncode, initialized.stderr)
        return common

    def run_restic(self, command: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=300,
            env=self.environment,
        )

    def dry_run(
        self, common: list[str], source: Path, *exclusion_files: Path, vss: bool = False
    ) -> tuple[subprocess.CompletedProcess[str], set[str], list[str]]:
        """The exit, the files and folders Restic would save below the source, and its errors."""
        listed = self.run_restic(
            [
                *common,
                "--json",
                "backup",
                str(source),
                "--dry-run",
                "-vv",
                "--iexclude-file",
                str(EXCLUDES),
                *[item for path in exclusion_files for item in ("--iexclude-file", str(path))],
                "--exclude-caches",
                *(["--use-fs-snapshot"] if vss else []),
            ]
        )
        marker = "/" + source.name + "/"
        saved: set[str] = set()
        errors: list[str] = []
        # Restic writes its JSON error messages to stderr.
        for line in (listed.stdout + "\n" + listed.stderr).splitlines():
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(message, dict):
                continue
            item = str(message.get("item") or "")
            if message.get("message_type") == "error":
                errors.append(json.dumps(message))
            elif (
                message.get("message_type") == "verbose_status"
                and message.get("action") == "new"
                and marker in item
            ):
                saved.add(item.split(marker, 1)[1])
        return listed, saved, errors

    def generate(
        self, root: Path, config: dict[str, object], found: list[dict[str, object]]
    ) -> Path:
        lines, _record = backup.unarchivable_exclusions(config, found)
        generated = root / "state" / backup.UNARCHIVABLE_EXCLUDES_NAME
        restic_common.atomic_write_text(generated, "\n".join(lines) + "\n")
        return generated

    def test_tricky_names_are_left_out_exactly_and_look_alikes_are_kept(self) -> None:
        # Each name would match something else, or nothing, if it were not
        # escaped: "[ab]" is a class matching "a" and "b", "$y" is an empty
        # variable, "c[d" is a broken class, and Restic trims the white space
        # at the end of a line. "trail " and "trail" are look-alikes only: no
        # line can name "trail " (see the end of this test).
        tricky = ("a[b]", "[ab]", "c[d", "m]n", "x$y", "nbsp\xa0", "wide\u3000", "dir [1]")
        look_alikes = (
            "ab", "a", "b", "cd", "mn", "x", "y", "x$$y", "nbsp", "wide", "dir 1", "trail ", "trail"
        )
        with tempfile.TemporaryDirectory(prefix="rewindle-unarchivable-names-") as root_text:
            root = Path(root_text)
            source = root / "probe-source"
            source.mkdir()
            try:
                for name in (*tricky, *look_alikes):
                    path = extended(str(source) + "\\" + name)
                    if name.startswith("dir"):
                        os.mkdir(path)
                        path += "\\inside.txt"
                    with open(path, "w", encoding="ascii", newline="\n") as handle:
                        handle.write(f"fixture {len(name)}\n")
                self.assertIn("trail ", os.listdir(extended(str(source))))
                common = self.restic(root)
                every_file = {
                    name + "/inside.txt" if name.startswith("dir") else name
                    for name in (*tricky, *look_alikes)
                }
                listed, saved, errors = self.dry_run(common, source)
                self.assertEqual(0, listed.returncode, listed.stderr)
                self.assertEqual(
                    every_file, {item for item in saved if item and not item.endswith("/")}
                )

                config = {"sources": [str(source)], "canary_file": str(root / "canary.txt")}
                generated = self.generate(
                    root, config, [found_in(str(source), *tricky)]
                )
                listed, saved, errors = self.dry_run(common, source, generated)
                self.assertEqual(0, listed.returncode, listed.stderr)
                self.assertEqual([], errors)
                self.assertEqual(
                    sorted(
                        name + "/inside.txt" if name.startswith("dir") else name
                        for name in look_alikes
                    ),
                    sorted(item for item in saved if item and not item.endswith("/")),
                )
                self.assertNotIn("dir [1]/", saved)
                self.assertIn("dir 1/", saved)

                # Why the walk keeps a name ending in a space in: Restic looks an
                # item up by its full Windows path, which drops the space, so even
                # an exactly escaped line never matches it. (Restic lists "trail "
                # here only because it reads "trail" in its place.)
                with self.assertRaisesRegex(RuntimeError, "unusable relative path"):
                    backup.unarchivable_exclusions(config, [found_in(str(source), "trail ")])
                class_line = root / "class-line.txt"
                class_line.write_text(
                    backup.restic_literal_exclude(
                        str(source).replace("\\", "/") + "/trail "
                    )
                    + "\n",
                    encoding="utf-8",
                    newline="\n",
                )
                self.assertTrue(class_line.read_text(encoding="utf-8").endswith("/trail[ ]\n"))
                listed, saved, errors = self.dry_run(common, source, class_line)
                self.assertEqual(0, listed.returncode, listed.stderr)
                self.assertIn("trail ", saved)
                self.assertIn("trail", saved)
            finally:
                # Windows drops the trailing space unless the path is taken as written.
                trailing = extended(str(source) + "\\trail ")
                if os.path.lexists(trailing):
                    os.remove(trailing)

    def test_a_real_wsl_link_fails_the_run_unless_it_is_left_out(self) -> None:
        with tempfile.TemporaryDirectory(prefix="rewindle-unarchivable-link-") as root_text:
            root = Path(root_text)
            source = root / "probe-source"
            (source / "repo").mkdir(parents=True)
            (source / "repo" / "readme.txt").write_text("fixture\n", encoding="ascii")
            try:
                # As WSL stores `ln -s readme.txt link` and `mkfifo pipe`.
                make_wsl_special_file(
                    str(source / "repo" / "link"),
                    restic_common.IO_REPARSE_TAG_LX_SYMLINK,
                    struct.pack("<I", 2) + b"readme.txt",
                )
                make_wsl_special_file(
                    str(source / "repo" / "pipe"), restic_common.IO_REPARSE_TAG_LX_FIFO
                )
            except OSError as error:
                self.skipTest(f"Windows refused to create a WSL special file here: {error}")

            # The real walk, through the real preflight, finds both by their tag.
            configured = str(source)
            config = {
                "sources": [configured],
                "source_identities": {configured: {"expected_volume_serial": "A1B2C3D4"}},
                "cloud_placeholder_policy": "strict",
                "canary_file": str(root / "canary.txt"),
            }
            preflight = restic_common.preflight_sources(
                config, volume_serial_reader=lambda _path: "A1B2C3D4"
            )
            self.assertEqual("ready", preflight["status"], preflight["failures"])
            found = preflight["unarchivable_links"]
            self.assertEqual(
                [
                    {"relative_path": "repo\\link", "tag": "lx_symlink"},
                    {"relative_path": "repo\\pipe", "tag": "lx_fifo"},
                ],
                sorted(found[0]["entries"], key=lambda entry: entry["relative_path"]),
            )
            generated = self.generate(root, config, found)
            common = self.restic(root)

            modes = [False]
            if restic_common.is_administrator():
                modes.append(True)
            for vss in modes:
                with self.subTest(use_fs_snapshot=vss):
                    listed, saved, errors = self.dry_run(common, source, vss=vss)
                    text = listed.stdout + listed.stderr
                    other_errors = [error for error in errors if "irregular" not in error]
                    if vss and (other_errors or listed.returncode not in (0, 3)):
                        self.skipTest(
                            "Windows could not make a VSS snapshot here: "
                            + (" ".join(other_errors) or text)[-500:]
                        )
                    self.assertEqual(3, listed.returncode, text[-2000:])
                    self.assertEqual(2, len(errors), errors)
                    for error in errors:
                        self.assertIn('unsupported file type \\"irregular\\"', error)

                    listed, saved, errors = self.dry_run(common, source, generated, vss=vss)
                    self.assertEqual(0, listed.returncode, (listed.stdout + listed.stderr)[-2000:])
                    self.assertEqual([], errors)
                    self.assertIn("repo/readme.txt", saved)
                    self.assertNotIn("repo/link", saved)
                    self.assertNotIn("repo/pipe", saved)


if __name__ == "__main__":
    unittest.main()
