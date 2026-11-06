"""The GitHub workflows run only reviewed action code, and the release workflow signs what it builds.

A tag such as actions/checkout@v7 can be moved to other code at any time, so every action is pinned to a full commit
SHA with its release in a comment. The release workflow also records signed build provenance (a GitHub artifact
attestation) for the setup program and the ZIPs, in a job of its own that alone may mint the signing token, and the
README tells people how to check a download with it. These checks read the workflow files as text (the standard
library has no YAML reader); the attestation itself can only be checked by a real workflow run.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


PROJECT = Path(__file__).resolve().parents[1]
WORKFLOWS = PROJECT / ".github" / "workflows"
INSTALLERS = WORKFLOWS / "installers.yml"
REPOSITORY = "50sotero/rewindle"
USES = re.compile(r"^\s*(?:-\s+)?uses:\s*(?P<target>\S+)\s*(?:#\s*(?P<comment>.*?))?\s*$")
PINNED = re.compile(r"^(?P<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?)@(?P<sha>[0-9a-f]{40})$")
ATTEST_ACTIONS = ("actions/attest", "actions/attest-build-provenance")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def block_after(lines: list[str], index: int) -> list[str]:
    """The lines indented deeper than lines[index], up to the next line at its level or above."""
    indent = len(lines[index]) - len(lines[index].lstrip(" "))
    block: list[str] = []
    for line in lines[index + 1 :]:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and len(line) - len(line.lstrip(" ")) <= indent:
            break
        block.append(line)
    return block


def keyed_block(lines: list[str], key: str, indent: int) -> list[str] | None:
    pattern = re.compile(rf"^ {{{indent}}}{re.escape(key)}:\s*$")
    found = [index for index, line in enumerate(lines) if pattern.match(line)]
    if not found:
        return None
    if len(found) > 1:
        raise AssertionError(f"{key} appears more than once at indent {indent}")
    return block_after(lines, found[0])


def simple_mapping(lines: list[str]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for line in lines:
        stripped = line.split("#", 1)[0].strip()
        if stripped:
            key, _, value = stripped.partition(":")
            mapping[key.strip()] = value.strip()
    return mapping


def jobs(text: str) -> dict[str, list[str]]:
    lines = text.splitlines()
    body = keyed_block(lines, "jobs", 0)
    if body is None:
        raise AssertionError("workflow has no jobs")
    result: dict[str, list[str]] = {}
    for index, line in enumerate(body):
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            result[match.group(1)] = block_after(body, index)
    return result


def top_level_permissions(text: str) -> dict[str, str] | None:
    lines = text.splitlines()
    for line in lines:
        if re.match(r"^permissions:\s*\S", line.split("#", 1)[0]):
            raise AssertionError(f"workflow-level permissions must be a mapping: {line}")
    block = keyed_block(lines, "permissions", 0)
    return None if block is None else simple_mapping(block)


def job_permissions(job: list[str]) -> dict[str, str] | None:
    for line in job:
        if re.match(r"^    permissions:\s*\S", line.split("#", 1)[0]):
            raise AssertionError(f"job permissions must be a mapping: {line}")
    block = keyed_block(job, "permissions", 4)
    return None if block is None else simple_mapping(block)


class PinnedActionTests(unittest.TestCase):
    def test_every_action_is_pinned_to_a_full_commit_sha_with_its_release(self) -> None:
        workflows = sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
        self.assertTrue(workflows)
        seen = 0
        for workflow in workflows:
            for number, line in enumerate(read(workflow).splitlines(), start=1):
                if not re.match(r"^\s*(?:-\s+)?uses:", line):
                    continue
                seen += 1
                with self.subTest(workflow=workflow.name, line=number):
                    match = USES.match(line)
                    self.assertIsNotNone(match, line)
                    target = match.group("target")
                    self.assertFalse(target.startswith(("./", "docker://")), "only pinned published actions")
                    self.assertRegex(target, PINNED, "pin the action to a full 40-character commit SHA")
                    self.assertRegex(
                        match.group("comment") or "",
                        r"^v\d+\.\d+(?:\.\d+)?$",
                        "name the exact release the SHA belongs to",
                    )
        self.assertGreater(seen, 0)


class BuildProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = read(INSTALLERS)
        cls.jobs = jobs(cls.text)
        cls.attesting = {
            name: lines
            for name, lines in cls.jobs.items()
            if any(
                (match := USES.match(line)) and match.group("target").split("@", 1)[0] in ATTEST_ACTIONS
                for line in lines
            )
        }

    def test_the_release_workflow_attests_the_files_it_publishes(self) -> None:
        self.assertEqual(1, len(self.attesting), "exactly one job attests the release files")
        job = next(iter(self.attesting.values()))
        text = "\n".join(job)
        uses = [USES.match(line) for line in job if USES.match(line)]
        attest = [match for match in uses if match.group("target").split("@", 1)[0] in ATTEST_ACTIONS]
        self.assertEqual(1, len(attest))
        self.assertRegex(attest[0].group("target"), PINNED)
        subjects = text.split("subject-path:", 1)[1]
        self.assertIn("artifacts/*.exe", subjects)
        self.assertIn("artifacts/*.zip", subjects)

    def test_the_attested_files_are_the_ones_the_build_uploads(self) -> None:
        name, job = next(iter(self.attesting.items()))
        text = "\n".join(job)
        build = [other for other in self.jobs if other != name]
        self.assertEqual(1, len(build))
        self.assertRegex(text, rf"(?m)^    needs:\s*\[?\s*{re.escape(build[0])}\s*\]?\s*$")
        build_text = "\n".join(self.jobs[build[0]])
        self.assertIn("actions/upload-artifact@", build_text)
        self.assertIn("actions/download-artifact@", text)
        uploaded = re.search(r"upload-artifact@\S+[^\n]*\n(?:.*\n)*?\s+name:\s*(\S+)", build_text)
        downloaded = re.search(r"download-artifact@\S+[^\n]*\n(?:.*\n)*?\s+name:\s*(\S+)", text)
        self.assertIsNotNone(uploaded)
        self.assertIsNotNone(downloaded)
        self.assertEqual(uploaded.group(1), downloaded.group(1))
        self.assertIn("path: artifacts", text)

    def test_only_the_attesting_job_may_mint_a_signing_token(self) -> None:
        self.assertEqual({"contents": "read"}, top_level_permissions(self.text))
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                permissions = job_permissions(job)
                if name in self.attesting:
                    self.assertEqual(
                        {"contents": "read", "id-token": "write", "attestations": "write"}, permissions
                    )
                else:
                    self.assertIn(permissions, (None, {"contents": "read"}))
        for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
            if workflow != INSTALLERS:
                with self.subTest(workflow=workflow.name):
                    self.assertNotRegex(read(workflow), r"id-token:\s*write")
                    self.assertNotRegex(read(workflow), r"attestations:\s*write")

    def test_the_readme_shows_how_to_check_a_download(self) -> None:
        readme = read(PROJECT / "README.md")
        section = readme.split("### Download and verify", 1)[1].split("\n### ", 1)[0]
        self.assertRegex(section, rf"gh attestation verify \S+ --repo {re.escape(REPOSITORY)}")
        # An attestation is not a code signature; the README must not claim otherwise.
        self.assertIn("not code-signed", section)


if __name__ == "__main__":
    unittest.main()
