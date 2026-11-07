"""Clean-up of old backups in the dashboard: what it reads, what it trusts, how it binds a request, and what the page says.

The C# checks compile the dashboard's own RetentionManager.cs (with EngineProfile.cs and ElevatedRequestSecurity.cs) into a small
harness under the repository (Application Control may refuse new binaries in the temporary folder) and compare it with the engine's
Python code on the same inputs. The page's wording module (retention.ts) runs with Node. Nothing here reads an installation: every
file is a fixture in a disposable folder.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


PROJECT = Path(__file__).resolve().parents[1]
DASHBOARD = PROJECT / "src" / "dashboard"
WEB = DASHBOARD / "web"
NAMESPACE = "ResticBackuper.Dashboard"
sys.path.insert(0, str(PROJECT / "src"))

import retention  # noqa: E402
from secret_store import admin_only_writable_problem  # noqa: E402


PLAN = "12345678-1234-4abc-8def-1234567890ab"
REPO = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
USER = "S-1-5-21-1-2-3-1001"
FORBIDDEN = re.compile(r"snapshot|repositor|restic|engine|canary|prune|forget|retention|policy|protected task", re.IGNORECASE)

HARNESS_SOURCE = """
namespace {namespace}
{{
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Text;
    using System.Web.Script.Serialization;

    internal static class RetentionHarness
    {{
        private static string S(IDictionary<string, object> d, string name)
        {{
            object value;
            return d.TryGetValue(name, out value) && value != null ? Convert.ToString(value) : null;
        }}

        private static object ViewOf(RetentionView view)
        {{
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["mode"] = view.Mode;
            result["problem"] = view.Problem;
            result["google_drive"] = view.GoogleDrive;
            result["daily"] = view.KeepDaily;
            result["weekly"] = view.KeepWeekly;
            result["monthly"] = view.KeepMonthly;
            result["reset"] = view.ResetByReinstall;
            result["preview"] = view.PreviewStatus;
            result["blocked"] = view.BlockedReason;
            result["error"] = view.ErrorCode;
            result["remove"] = view.RemoveCount;
            result["keep"] = view.KeepCount;
            result["needs_files"] = view.NeedsFilesConfirmed;
            result["prune_pending"] = view.PrunePending;
            result["preview_sha"] = view.PreviewSha256;
            result["last_outcome"] = view.LastRun == null ? null : view.LastRun.Outcome;
            result["last_unverified"] = view.LastRun != null && view.LastRun.RemovalUnverified;
            result["last_check_unfinished"] = view.LastRun != null && view.LastRun.CheckUnfinished;
            List<object> earlier = new List<object>();
            foreach (RetentionEarlierChange change in view.EarlierChanges)
            {{
                earlier.Add(new object[] {{ change.FinishedUtc, change.Kind }});
            }}
            result["earlier"] = earlier.ToArray();
            result["earlier_unknown"] = view.EarlierChangesUnknown;
            return result;
        }}

        private static RetentionRequest RequestOf(IDictionary<string, object> d)
        {{
            RetentionRequest request = new RetentionRequest();
            request.Action = S(d, "action");
            request.Enabled = S(d, "enabled") ?? string.Empty;
            request.KeepDaily = S(d, "keep_daily") ?? string.Empty;
            request.KeepWeekly = S(d, "keep_weekly") ?? string.Empty;
            request.KeepMonthly = S(d, "keep_monthly") ?? string.Empty;
            request.PreviewSha256 = S(d, "preview") ?? string.Empty;
            request.RemoveSetSha256 = S(d, "remove_set") ?? string.Empty;
            request.RemoveCount = S(d, "remove_count") ?? string.Empty;
            request.ConfirmEarlierChanges = S(d, "confirm") ?? string.Empty;
            request.Nonce = S(d, "nonce");
            request.Digest = S(d, "digest");
            request.UserSid = S(d, "user");
            request.ConfigHash = S(d, "config");
            request.PlanId = S(d, "plan");
            request.ConfigGeneration = Convert.ToInt64(d["generation"]);
            return request;
        }}

        public static int Main(string[] args)
        {{
            JavaScriptSerializer json = new JavaScriptSerializer();
            json.MaxJsonLength = int.MaxValue;
            object[] cases = (object[])json.DeserializeObject(File.ReadAllText(args[0], Encoding.UTF8));
            List<object> results = new List<object>();
            foreach (object item in cases)
            {{
                IDictionary<string, object> c = (IDictionary<string, object>)item;
                string op = S(c, "op");
                EngineProfile.Activate(EngineProfile.FromId(S(c, "profile") ?? "rewindle"));
                RetentionFiles.TrustTemporaryFolderForTesting(S(c, "trust") == "True");
                object result = null;
                if (op == "acl") result = RetentionAcl.AdminOnlyWritable(S(c, "sddl"));
                else if (op == "install") result = RetentionDigests.InstallIdentity(File.ReadAllBytes(S(c, "path")));
                else if (op == "policy_digest") result = RetentionDigests.PolicyDigest(EngineProfile.Current.RetentionPolicySchema,
                    S(c, "plan"), S(c, "repo"), S(c, "install"), Convert.ToInt32(c["d"]), Convert.ToInt32(c["w"]), Convert.ToInt32(c["m"]));
                else if (op == "set_digest") result = RetentionDigests.SetDigest(S(c, "domain"), Array.ConvertAll((object[])c["ids"], x => (string)x));
                else if (op == "request_digest") result = RetentionDigests.RequestDigest(EngineProfile.Current.RetentionRequestDomain, RequestOf(c));
                else if (op == "capability") result = RetentionCapability.IsSupported(EngineProfile.Current, S(c, "root"));
                else if (op == "names")
                {{
                    Dictionary<string, object> names = new Dictionary<string, object>();
                    names["manager"] = EngineProfile.Current.RetentionManagerFileName;
                    names["request_domain"] = EngineProfile.Current.RetentionRequestDomain;
                    names["policy_schema"] = EngineProfile.Current.RetentionPolicySchema;
                    names["preview_schema"] = EngineProfile.Current.RetentionPreviewSchema;
                    names["history_schema"] = EngineProfile.Current.RetentionHistorySchema;
                    result = names;
                }}
                else if (op == "read") result = ViewOf(RetentionStateReader.Read(EngineProfile.Current, S(c, "state"), S(c, "install"),
                    S(c, "plan"), Convert.ToInt64(c["generation"]), null));
                else if (op == "read_protected")
                {{
                    RetentionFileRead read = RetentionFiles.ReadProtected(S(c, "path"), 1024 * 1024);
                    Dictionary<string, object> r = new Dictionary<string, object>();
                    r["exists"] = read.Exists;
                    r["problem"] = read.Problem;
                    r["sha"] = read.Sha256;
                    result = r;
                }}
                else if (op == "validate")
                {{
                    RetentionResultDocument document;
                    string error;
                    bool ok = RetentionManagerLauncher.TryValidateResultDocument(S(c, "json"),
                        RequestOf((IDictionary<string, object>)c["request"]), Convert.ToInt32(c["exit"]), out document, out error);
                    Dictionary<string, object> r = new Dictionary<string, object>();
                    r["ok"] = ok;
                    r["state"] = document == null ? null : document.State;
                    r["check_unfinished"] = document != null && document.CheckUnfinished;
                    r["history_recorded"] = document != null && document.HistoryRecorded;
                    result = r;
                }}
                else if (op == "arguments")
                {{
                    RetentionRequest request = RequestOf((IDictionary<string, object>)c["request"]);
                    result = RetentionManagerLauncher.BuildArguments(request, "C:\\\\Manager.ps1").ToArray();
                }}
                results.Add(result);
            }}
            Console.OutputEncoding = new UTF8Encoding(false);
            Console.WriteLine(json.Serialize(results));
            return 0;
        }}
    }}
}}
"""


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot_id(index: int) -> str:
    return f"{index:02x}" * 32


class Fixture:
    """An install root and a state folder as the engine leaves them after turning clean-up on and listing old backups."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.install = root / "ProgramFiles" / "ResticBackuper"
        self.state = root / "ProgramData" / "ResticBackuper"
        self.install.mkdir(parents=True)
        self.state.mkdir(parents=True)
        write_json(self.install / "backup-config.json", {"schema_version": 1, "plan_id": PLAN, "config_generation": 7,
                                                          "repository_storage_mode": "local_ntfs"})
        self.manifest()
        write_json(self.state / "last-success.json", {"schema_version": 1, "run_id": "r5", "state": "success",
                                                       "verification_complete": True, "snapshot_id": snapshot_id(5),
                                                       "repository_id": REPO, "plan_id": PLAN, "config_generation": 7})

    def manifest(self, version: str = "0.3.0", restic_hash: str = "1" * 64, installation: str | None = "5" * 64) -> None:
        document: dict = {"schema_version": 1, "version": version}
        if installation is not None:
            document["installation_id"] = installation
        write_json(self.install / "runtime-manifest.json", {
            **document, "files": [
                {"relative_path": "backup-config.json", "bytes": 1, "sha256": "2" * 64},
                {"relative_path": "restic.exe", "bytes": 1, "sha256": restic_hash},
                {"relative_path": "Python/python.exe", "bytes": 1, "sha256": "4" * 64},
                {"relative_path": "retention.py", "bytes": 1, "sha256": "3" * 64},
            ],
        })

    def policy(self, enabled: bool = True, counts=(7, 4, 6), **overrides) -> None:
        install_id = retention.install_identity(self.install)
        document = {
            "schema": retention.POLICY_SCHEMA, "schema_version": 1, "enabled": enabled,
            "keep_daily": counts[0], "keep_weekly": counts[1], "keep_monthly": counts[2], "group_by": "host,paths",
            "plan_id": PLAN, "repository_id": REPO, "install_id": install_id,
            "policy_sha256": retention.policy_digest(PLAN, REPO, install_id, *counts),
        }
        document.update(overrides)
        write_json(self.state / retention.POLICY_NAME, document)

    def preview(self, remove=(1, 2), keep=(3, 4, 5), **overrides) -> None:
        policy = json.loads((self.state / retention.POLICY_NAME).read_text(encoding="utf-8"))
        remove_ids = [snapshot_id(i) for i in remove]
        keep_ids = [snapshot_id(i) for i in keep]
        document = {
            "schema": retention.PREVIEW_SCHEMA, "schema_version": 1, "state": "ready", "blocked_reason": None, "error_code": None,
            "created_utc": "2026-09-30T10:00:00Z", "plan_id": PLAN, "config_generation": 7, "repository_id": REPO,
            "policy": {"keep_daily": 7, "keep_weekly": 4, "keep_monthly": 6, "group_by": "host,paths",
                       "policy_sha256": policy.get("policy_sha256")},
            "evidence": {"run_id": "r5", "last_success_sha256": sha(self.state / "last-success.json")},
            "remove_count": len(remove_ids), "keep_count": len(keep_ids),
            "remove_set_sha256": retention.set_digest(retention.REMOVE_SET_DOMAIN, remove_ids),
            "keep_set_sha256": retention.set_digest(retention.KEEP_SET_DOMAIN, keep_ids),
            "remove": [{"id": i, "time": f"2026-09-2{n}T02:00:00+02:00", "files": 100, "generation": 7} for n, i in enumerate(remove_ids)],
            "keep": [{"id": i, "time": f"2026-09-2{5 + n}T02:00:00+02:00", "files": 100, "generation": 7, "reasons": ["day"]}
                     for n, i in enumerate(keep_ids)],
            "earlier_changes": [], "earlier_changes_unknown": False, "first_cleanup": True, "needs_files_confirmed": True,
            "prune_pending": False, "future_dated_utc": None,
        }
        document.update(overrides)
        write_json(self.state / retention.PREVIEW_NAME, document)

    def read(self, **extra) -> dict:
        return {"op": "read", "state": str(self.state), "install": str(self.install), "plan": PLAN, "generation": 7, "trust": "True", **extra}


class DashboardRetentionHarnessTests(unittest.TestCase):
    results: list

    @classmethod
    def setUpClass(cls) -> None:
        framework = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "Microsoft.NET" / "Framework64" / "v4.0.30319"
        compiler = framework / "csc.exe"
        if not compiler.is_file():
            raise unittest.SkipTest("The .NET Framework C# compiler is unavailable.")
        cls.harness_directory = tempfile.TemporaryDirectory(prefix=".retention-harness-", dir=PROJECT)
        cls.fixture_directory = tempfile.TemporaryDirectory(prefix="rw-retention-")
        temp = Path(cls.harness_directory.name)
        cls.executable = temp / "RetentionHarness.exe"
        harness = temp / "RetentionHarness.cs"
        harness.write_text(textwrap.dedent(HARNESS_SOURCE.format(namespace=NAMESPACE)), encoding="utf-8")
        compiled = subprocess.run(
            [str(compiler), "/nologo", "/target:exe", "/warn:4", f"/out:{cls.executable}", f"/main:{NAMESPACE}.RetentionHarness",
             f"/reference:{framework / 'System.dll'}", f"/reference:{framework / 'System.Core.dll'}",
             f"/reference:{framework / 'System.Web.Extensions.dll'}",
             str(DASHBOARD / "EngineProfile.cs"), str(DASHBOARD / "ElevatedRequestSecurity.cs"), str(DASHBOARD / "RetentionManager.cs"),
             str(harness)],
            capture_output=True, text=True, check=False,
        )
        if compiled.returncode != 0:
            raise AssertionError("Retention harness compilation failed:\n" + compiled.stdout + compiled.stderr)
        cls.root = Path(cls.fixture_directory.name)

    @classmethod
    def tearDownClass(cls) -> None:
        for name in ("harness_directory", "fixture_directory"):
            if hasattr(cls, name):
                getattr(cls, name).cleanup()

    def run_cases(self, cases: list) -> list:
        path = self.root / f"cases-{len(cases)}-{id(cases)}.json"
        write_json(path, cases)
        completed = subprocess.run([str(self.executable), str(path)], capture_output=True, encoding="utf-8", check=False, timeout=120)
        if completed.returncode != 0:
            raise AssertionError(completed.stdout + completed.stderr)
        return json.loads(completed.stdout)

    def fixture(self, name: str) -> Fixture:
        return Fixture(self.root / name)

    # ---- What it trusts ----------------------------------------------------------------------------------------------------

    def test_the_admin_only_check_agrees_with_the_engine_on_real_shapes(self) -> None:
        shapes = [
            # Written by an administrator into the protected state folder: inherited, user and OWNER RIGHTS may only read.
            "O:BAD:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;" + USER + ")(A;ID;0x1200a9;;;OW)",
            # The same file where Windows made the user its owner: OWNER RIGHTS limits the owner to reading.
            "O:" + USER + "D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;" + USER + ")(A;ID;0x1200a9;;;OW)",
            # A user owner without OWNER RIGHTS can rewrite the access list.
            "O:" + USER + "D:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;" + USER + ")",
            # The DPAPI password file's form: the user has Full Control.
            "O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;" + USER + ")",
            # Inherited write for Users.
            "O:BAD:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1301bf;;;BU)",
            # Deny entries and entries that apply only to children are skipped.
            "O:BAD:(D;;FA;;;WD)(A;OICIIO;FA;;;CO)(A;;FA;;;BA)(A;;FR;;;BU)",
            # Generic write for Everyone.
            "O:BAD:(A;;FA;;;BA)(A;;GW;;;WD)",
            # No access list, or an empty one.
            "O:BAD:NO_ACCESS_CONTROL",
            "O:BAD:",
            "O:SYD:P(A;;FA;;;SY)",
            # The state folder as the installer protects it: owned by Administrators, the user and OWNER RIGHTS may only read.
            "O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;" + USER + ")(A;OICI;0x1200a9;;;OW)",
            # A folder where Users may create files and folders (as ProgramData itself allows): not admin-only.
            "O:BAD:AI(A;OICIID;FA;;;SY)(A;OICIID;FA;;;BA)(A;OICIID;0x1200a9;;;BU)(A;CIID;0x116;;;BU)",
        ]
        answers = self.run_cases([{"op": "acl", "sddl": sddl} for sddl in shapes])
        for sddl, answer in zip(shapes, answers):
            with self.subTest(sddl=sddl):
                expected = admin_only_writable_problem(sddl, owner_limited_by_owner_rights=True) is None
                self.assertEqual(answer, expected)
        self.assertEqual(answers[:4], [True, True, False, False])
        self.assertEqual(answers[-2:], [True, False])

    def test_files_the_user_can_change_are_not_trusted_unless_a_test_says_so(self) -> None:
        fixture = self.fixture("acl")
        path = fixture.state / "last-success.json"
        untrusted, trusted = self.run_cases([
            {"op": "read_protected", "path": str(path), "trust": "False"},
            {"op": "read_protected", "path": str(path), "trust": "True"},
        ])
        self.assertEqual((untrusted["exists"], untrusted["problem"]), (True, "unprotected"))
        self.assertIsNone(trusted["problem"])
        self.assertEqual(trusted["sha"], sha(path))

    # ---- Digests shared with the engine and the manager ------------------------------------------------------------------

    def test_install_identity_policy_and_request_digests_match_the_engine(self) -> None:
        fixture = self.fixture("digests")
        ids = [snapshot_id(3), snapshot_id(1), snapshot_id(2)]
        unnamed = self.fixture("digests-unnamed")
        unnamed.manifest(installation=None)
        install, unnamed_install, policy, removal, request = self.run_cases([
            {"op": "install", "path": str(fixture.install / "runtime-manifest.json")},
            {"op": "install", "path": str(unnamed.install / "runtime-manifest.json")},
            {"op": "policy_digest", "plan": PLAN, "repo": REPO, "install": "a" * 64, "d": 14, "w": 8, "m": 24},
            {"op": "set_digest", "domain": retention.REMOVE_SET_DOMAIN, "ids": ids},
            {"op": "request_digest", "action": "apply", "user": USER, "config": "a" * 64, "plan": PLAN, "generation": 7,
             "preview": "b" * 64, "remove_set": "c" * 64, "remove_count": "2", "confirm": "1", "nonce": "d" * 64},
        ])
        self.assertEqual(install, retention.install_identity(fixture.install))
        # A manifest the installer wrote names its installation; one that does not cannot bind a setting.
        self.assertIsNone(unnamed_install)
        self.assertEqual(policy, "84a15a61186356399ad62e0fd1c3c688841a2724a8082ca7ea5879b1da72f7ab")
        self.assertEqual(policy, retention.policy_digest(PLAN, REPO, "a" * 64, 14, 8, 24))
        self.assertEqual(removal, retention.set_digest(retention.REMOVE_SET_DOMAIN, ids))
        # The same vector tests\\Test-ManageRetention.ps1 checks against the manager.
        self.assertEqual(request, "dc98255ecec19bc0c56d1edcc522694560baeaadbb7355673b2755e4e4b49995")

    def test_the_manager_gets_only_the_arguments_of_its_action(self) -> None:
        base = {"user": USER, "config": "a" * 64, "plan": PLAN, "generation": 7, "nonce": "d" * 64, "digest": "e" * 64}
        off, apply = self.run_cases([
            {"op": "arguments", "request": {**base, "action": "configure", "enabled": "0"}},
            {"op": "arguments", "request": {**base, "action": "apply", "preview": "b" * 64, "remove_set": "c" * 64,
                                            "remove_count": "2", "confirm": "1"}},
        ])
        self.assertIn("-Enabled", off)
        self.assertNotIn("-KeepDaily", off)
        self.assertNotIn("-ExpectedRemoveCount", off)
        self.assertNotIn("-Enabled", apply)
        self.assertEqual(apply[apply.index("-ExpectedRemoveCount") + 1], "2")
        self.assertEqual(apply[apply.index("-RequestDigest") + 1], "e" * 64)
        self.assertEqual(apply[apply.index("-File") + 1], "C:\\Manager.ps1")

    # ---- Capability and the legacy profile ---------------------------------------------------------------------------------

    def test_capability_needs_the_exact_block_and_the_legacy_profile_has_none(self) -> None:
        capabilities = json.loads((PROJECT / "src" / "engine-capabilities.json").read_text(encoding="utf-8"))
        roots = {}
        for name, block in {
            "shipped": capabilities.get("retention"),
            "missing": None,
            "wrong_manager": {**capabilities["retention"], "manager": "Manage-Other.ps1"},
            "wrong_domain": {**capabilities["retention"], "request_domain": "ResticBackuper.RetentionRequest.v2"},
        }.items():
            root = self.root / f"capability-{name}"
            document = {key: value for key, value in capabilities.items() if key != "retention"}
            if block is not None:
                document["retention"] = block
            write_json(root / "engine-capabilities.json", document)
            roots[name] = root
        shipped, missing, wrong_manager, wrong_domain, legacy, names_rewindle, names_legacy = self.run_cases([
            {"op": "capability", "root": str(roots["shipped"])},
            {"op": "capability", "root": str(roots["missing"])},
            {"op": "capability", "root": str(roots["wrong_manager"])},
            {"op": "capability", "root": str(roots["wrong_domain"])},
            {"op": "capability", "root": str(roots["shipped"]), "profile": "legacy"},
            {"op": "names"},
            {"op": "names", "profile": "legacy"},
        ])
        self.assertEqual((shipped, missing, wrong_manager, wrong_domain, legacy), (True, False, False, False, False))
        self.assertEqual(names_rewindle, {
            "manager": "Manage-Retention.ps1", "request_domain": "ResticBackuper.RetentionRequest.v1",
            "policy_schema": retention.POLICY_SCHEMA, "preview_schema": retention.PREVIEW_SCHEMA, "history_schema": retention.HISTORY_SCHEMA,
        })
        self.assertEqual(set(names_legacy.values()), {None})

    # ---- Reading the records -----------------------------------------------------------------------------------------------

    def test_off_on_stale_and_reinstalled(self) -> None:
        off = self.fixture("off")
        on = self.fixture("on")
        on.policy()
        on.preview()
        stale = self.fixture("stale")
        stale.policy()
        stale.preview()
        evidence = json.loads((stale.state / "last-success.json").read_text(encoding="utf-8"))
        evidence["run_id"] = "r6"
        write_json(stale.state / "last-success.json", evidence)
        updated = self.fixture("updated")
        updated.policy()
        updated.preview()
        updated.manifest(version="0.4.0")
        # The same release installed again (after an uninstall, or as a repair): the installer wrote a new installation_id.
        reinstalled = self.fixture("reinstalled")
        reinstalled.policy()
        reinstalled.preview()
        reinstalled.manifest(installation="6" * 64)
        # A folder change or a move of the backup location rewrites the manifest but keeps the installation.
        moved = self.fixture("moved")
        moved.policy()
        moved.preview()
        manifest = json.loads((moved.install / "runtime-manifest.json").read_text(encoding="utf-8"))
        manifest["files"][0]["sha256"] = "9" * 64
        manifest["created_utc"] = "2026-09-20T00:00:00Z"
        manifest["last_update_reason"] = "Protected repository relocated"
        write_json(moved.install / "runtime-manifest.json", manifest)
        unnamed = self.fixture("unnamed")
        unnamed.policy()
        unnamed.manifest(installation=None)
        disabled = self.fixture("disabled")
        disabled.policy(enabled=False, counts=(30, 10, 12))
        other_plan = self.fixture("other-plan")
        other_plan.policy(plan_id="87654321-4321-4cba-8fed-ba0987654321")
        drive = self.fixture("drive")
        write_json(drive.install / "backup-config.json", {"repository_storage_mode": "google_drivefs_stream"})
        tampered = self.fixture("tampered")
        tampered.policy()
        tampered.preview(remove_set_sha256="f" * 64)
        forged = self.fixture("forged")
        forged.policy(counts=(7, 4, 6), keep_daily=8)
        views = self.run_cases([x.read() for x in (off, on, stale, updated, disabled, other_plan, drive, tampered, forged,
                                                   reinstalled, moved, unnamed)])
        (off_view, on_view, stale_view, updated_view, disabled_view, other_view, drive_view, tampered_view, forged_view,
         reinstalled_view, moved_view, unnamed_view) = views
        self.assertEqual((off_view["mode"], off_view["daily"], off_view["weekly"], off_view["monthly"]), ("off", 14, 8, 24))
        self.assertEqual((on_view["mode"], on_view["preview"], on_view["remove"], on_view["keep"]), ("on", "ready", 2, 3))
        self.assertTrue(on_view["needs_files"])
        self.assertEqual(on_view["preview_sha"], sha(on.state / retention.PREVIEW_NAME))
        self.assertEqual((stale_view["mode"], stale_view["preview"]), ("on", "stale"))
        self.assertEqual((updated_view["mode"], updated_view["reset"]), ("off", True))
        self.assertEqual((reinstalled_view["mode"], reinstalled_view["reset"]), ("off", True))
        self.assertEqual((moved_view["mode"], moved_view["preview"], moved_view["reset"]), ("on", "ready", False))
        self.assertEqual((unnamed_view["mode"], unnamed_view["problem"]), ("unknown", "install_unreadable"))
        self.assertEqual((disabled_view["mode"], disabled_view["daily"], disabled_view["weekly"]), ("off", 30, 10))
        self.assertEqual((other_view["mode"], other_view["reset"]), ("off", False))
        self.assertTrue(drive_view["google_drive"])
        # The list shown must be the list a removal is bound to.
        self.assertEqual((tampered_view["preview"], tampered_view["remove"]), ("error", 0))
        # A setting whose digest does not match its counts is not on.
        self.assertEqual(forged_view["mode"], "off")

    def test_only_an_explicit_no_skips_checking_files(self) -> None:
        # The engine writes needs_files_confirmed: false only for a list whose backups the person already looked over. A list
        # without the field (an older or damaged one), with null, or with anything but false asks for the tick.
        cases = {"no": False, "yes": True, "null": None, "text": "false", "number": 0, "missing": ...}
        fixtures = []
        for name, value in cases.items():
            fixture = self.fixture(f"files-{name}")
            fixture.policy()
            fixture.preview(first_cleanup=False, needs_files_confirmed=None if value is ... else value)
            if value is ...:
                path = fixture.state / retention.PREVIEW_NAME
                document = json.loads(path.read_text(encoding="utf-8"))
                del document["needs_files_confirmed"]
                write_json(path, document)
            fixtures.append(fixture)
        views = self.run_cases([fixture.read() for fixture in fixtures])
        answers = {name: view["needs_files"] for name, view in zip(cases, views)}
        self.assertEqual(answers, {"no": False, "yes": True, "null": True, "text": True, "number": True, "missing": True})
        for name, view in zip(cases, views):
            with self.subTest(name=name):
                self.assertEqual((view["mode"], view["preview"]), ("on", "ready"))

    def test_the_last_clean_up_says_when_nobody_could_confirm_the_removal_or_the_check_did_not_finish(self) -> None:
        entry = {"request_nonce": "1" * 64, "started_utc": "2026-09-30T10:00:00Z", "finished_utc": "2026-09-30T10:05:00Z",
                 "confirmed_count": 2, "removed_set_sha256": "2" * 64, "prune_mode": "none", "files_confirmed": True,
                 "keep_daily": 7, "keep_weekly": 4, "keep_monthly": 6, "free_bytes_before": None, "free_bytes_after": 1}
        runs = {
            "unverified": {**entry, "outcome": "partial", "removed_count": 0, "prune_completed": False, "check_completed": False,
                           "check_unfinished": False, "removal_unverified": True},
            "unfinished": {**entry, "outcome": "check_failed", "removed_count": 2, "prune_completed": True, "check_completed": False,
                           "check_unfinished": True, "removal_unverified": False},
            # An entry from before these fields existed.
            "older": {**entry, "outcome": "check_failed", "removed_count": 2, "prune_completed": True, "check_completed": False},
        }
        fixtures = []
        for name, run in runs.items():
            fixture = self.fixture(f"last-{name}")
            fixture.policy()
            fixture.preview()
            write_json(fixture.state / retention.HISTORY_NAME, {"schema": retention.HISTORY_SCHEMA, "schema_version": 1,
                                                                "plan_id": PLAN, "updated_utc": "2026-09-30T10:05:00Z", "entries": [run]})
            fixtures.append(fixture)
        unverified, unfinished, older = self.run_cases([fixture.read() for fixture in fixtures])
        self.assertEqual((unverified["last_outcome"], unverified["last_unverified"], unverified["last_check_unfinished"]),
                         ("partial", True, False))
        self.assertEqual((unfinished["last_outcome"], unfinished["last_unverified"], unfinished["last_check_unfinished"]),
                         ("check_failed", False, True))
        self.assertEqual((older["last_outcome"], older["last_unverified"], older["last_check_unfinished"]), ("check_failed", False, False))

    def test_each_earlier_backup_is_read_with_its_kind(self) -> None:
        fixture = self.fixture("earlier-kinds")
        fixture.policy()
        fixture.preview(earlier_changes=[
            {"finished_utc": "2026-09-29T00:30:00Z", "kind": "unknown"},
            {"finished_utc": "2026-09-28T00:30:00Z", "kind": "not_compared"},
            {"finished_utc": "2026-09-27T00:30:00Z", "kind": "hold"},
            {"finished_utc": "2026-09-26T00:30:00Z", "kind": "something_new"},
            {"finished_utc": "2026-09-25T00:30:00Z"},
        ], earlier_changes_unknown=True, first_cleanup=False)
        none = self.fixture("earlier-none")
        none.policy()
        none.preview()
        view, none_view = self.run_cases([fixture.read(), none.read()])
        # A kind this dashboard does not know, or none at all, is read as "unknown": never as a backup that held.
        self.assertEqual(view["earlier"], [
            ["2026-09-29T00:30:00Z", "unknown"], ["2026-09-28T00:30:00Z", "not_compared"], ["2026-09-27T00:30:00Z", "hold"],
            ["2026-09-26T00:30:00Z", "unknown"], ["2026-09-25T00:30:00Z", "unknown"],
        ])
        self.assertTrue(view["earlier_unknown"])
        self.assertTrue(view["needs_files"])
        self.assertEqual((none_view["earlier"], none_view["earlier_unknown"]), ([], False))

    def test_blocked_lists_and_unreadable_settings(self) -> None:
        blocked = self.fixture("blocked")
        blocked.policy()
        blocked.preview(state="blocked", blocked_reason="change_review_open", remove=(), keep=())
        unknown_code = self.fixture("unknown-code")
        unknown_code.policy()
        unknown_code.preview(state="blocked", blocked_reason="something_new", remove=(), keep=())
        unreadable = self.fixture("unreadable")
        (unreadable.state / retention.POLICY_NAME).write_text("{not json", encoding="utf-8")
        untrusted = self.fixture("untrusted")
        untrusted.policy()
        blocked_view, unknown_view, unreadable_view, untrusted_view = self.run_cases([
            blocked.read(), unknown_code.read(), unreadable.read(), untrusted.read(trust="False"),
        ])
        self.assertEqual((blocked_view["preview"], blocked_view["blocked"]), ("blocked", "change_review_open"))
        self.assertEqual((unknown_view["preview"], unknown_view["blocked"]), ("blocked", "policy_inactive"))
        self.assertEqual(unreadable_view["mode"], "unknown")
        # Without the test-only trust, the fixture's own permissions make the state folder untrusted: nothing is read or offered.
        self.assertEqual((untrusted_view["mode"], untrusted_view["problem"]), ("unknown", "state_unprotected"))

    # ---- What a result must say ----------------------------------------------------------------------------------------------

    def result_document(self, request: dict, **overrides) -> dict:
        document = {
            "schema_version": 1, "request_nonce": request["nonce"], "request_digest": request["digest"],
            "request_user_sid": request["user"], "action": request["action"], "expected_config_sha256": request["config"],
            "plan_id": request["plan"], "config_generation": request["generation"],
            "enabled": request.get("enabled", ""), "keep_daily": request.get("keep_daily", ""),
            "keep_weekly": request.get("keep_weekly", ""), "keep_monthly": request.get("keep_monthly", ""),
            "expected_preview_sha256": request.get("preview", ""), "expected_remove_set_sha256": request.get("remove_set", ""),
            "expected_remove_count": request.get("remove_count", ""), "confirm_earlier_changes": request.get("confirm", ""),
            "ok": True, "state": "removed", "refusal_code": None, "removed_count": 2, "removed_set_sha256": request.get("remove_set"),
            "prune_completed": True, "check_completed": True, "history_recorded": True, "preview_sha256": "9" * 64,
        }
        document.update(overrides)
        return document

    def test_a_result_is_accepted_only_when_every_binding_and_the_outcome_agree(self) -> None:
        request = {"action": "apply", "user": USER, "config": "a" * 64, "plan": PLAN, "generation": 7, "nonce": "d" * 64,
                   "digest": "e" * 64, "preview": "b" * 64, "remove_set": "c" * 64, "remove_count": "2", "confirm": "1"}
        good = self.result_document(request)
        variants = {
            "exact": (good, 0, True),
            "nonce": ({**good, "request_nonce": "0" * 64}, 0, False),
            "digest": ({**good, "request_digest": "0" * 64}, 0, False),
            "user": ({**good, "request_user_sid": "S-1-5-21-9"}, 0, False),
            "action": ({**good, "action": "preview"}, 0, False),
            "config": ({**good, "expected_config_sha256": "0" * 64}, 0, False),
            "plan": ({**good, "plan_id": "87654321-4321-4cba-8fed-ba0987654321"}, 0, False),
            "generation": ({**good, "config_generation": 8}, 0, False),
            "count_field": ({**good, "expected_remove_count": "3"}, 0, False),
            "confirm_field": ({**good, "confirm_earlier_changes": "0"}, 0, False),
            "ok_but_failed_exit": (good, 1, False),
            "not_ok_but_exit_zero": ({**good, "ok": False}, 0, False),
            "fewer_removed": ({**good, "removed_count": 1}, 0, False),
            "another_removed_list": ({**good, "removed_set_sha256": "0" * 64}, 0, False),
            "space_not_freed_but_removed": ({**good, "prune_completed": False}, 0, False),
            "partial": ({**good, "ok": False, "state": "partial", "removed_count": 1, "removed_set_sha256": "1" * 64}, 4, True),
            "partial_wrong_exit": ({**good, "ok": False, "state": "partial", "removed_count": 1}, 1, False),
            "refused": ({**good, "ok": False, "state": "refused", "refusal_code": "busy", "removed_count": None}, 2, True),
            "refused_without_reason": ({**good, "ok": False, "state": "refused", "removed_count": None}, 2, False),
            "refused_unknown_reason": ({**good, "ok": False, "state": "refused", "refusal_code": "because"}, 2, False),
            "configure_state_for_apply": ({**good, "state": "configured"}, 0, False),
            "preview_changed": ({**good, "ok": False, "state": "preview_changed", "removed_count": None}, 3, True),
            # The space was freed, then the check of the rest did not finish: only ever as check_failed, after freeing.
            "check_unfinished": ({**good, "ok": False, "state": "check_failed", "check_completed": False, "check_unfinished": True}, 6, True),
            "check_unfinished_before_freeing": ({**good, "ok": False, "state": "check_failed", "prune_completed": False,
                                                 "check_completed": False, "check_unfinished": True}, 6, False),
            "check_unfinished_on_space_pending": ({**good, "ok": False, "state": "space_pending", "prune_completed": False,
                                                   "check_completed": False, "check_unfinished": True}, 5, False),
            "space_pending_unrecorded": ({**good, "ok": False, "state": "space_pending", "prune_completed": False,
                                          "check_completed": False, "history_recorded": False}, 5, True),
            "unverified_without_a_count": ({**good, "ok": False, "state": "partial", "removed_count": 0, "removal_unverified": True,
                                            "prune_completed": False, "check_completed": False}, 4, True),
        }
        cases = [{"op": "validate", "request": request, "exit": exit_code, "json": json.dumps(document)}
                 for document, exit_code, _expected in variants.values()]
        answers = self.run_cases(cases)
        for (name, (_document, _exit, expected)), answer in zip(variants.items(), answers):
            with self.subTest(name=name):
                self.assertEqual(answer["ok"], expected)
        named = dict(zip(variants, answers))
        self.assertTrue(named["check_unfinished"]["check_unfinished"])
        self.assertFalse(named["exact"]["check_unfinished"])
        self.assertFalse(named["space_pending_unrecorded"]["history_recorded"])

    def test_a_configure_result_names_the_requested_setting(self) -> None:
        request = {"action": "configure", "user": USER, "config": "a" * 64, "plan": PLAN, "generation": 7, "nonce": "d" * 64,
                   "digest": "e" * 64, "enabled": "1", "keep_daily": "14", "keep_weekly": "8", "keep_monthly": "24"}
        good = self.result_document(request, state="configured", removed_count=None, removed_set_sha256=None)
        accepted, other_counts, disabled = self.run_cases([
            {"op": "validate", "request": request, "exit": 0, "json": json.dumps(good)},
            {"op": "validate", "request": request, "exit": 0, "json": json.dumps({**good, "keep_daily": "7"})},
            {"op": "validate", "request": request, "exit": 0, "json": json.dumps({**good, "state": "disabled"})},
        ])
        self.assertEqual((accepted["ok"], other_counts["ok"], disabled["ok"]), (True, False, False))


NODE_RUNNER = r"""
import { readFileSync } from 'node:fs';
const [moduleUrl, inputPath] = process.argv.slice(1);
const mod = await import(moduleUrl);
const data = JSON.parse(readFileSync(inputPath, 'utf8'));
const out = { cards: {}, results: {}, summaries: {}, refusals: {}, blocked: {}, errors: {}, stages: {}, lastRuns: {}, misc: {} };
for (const [name, state] of Object.entries(data.states)) out.cards[name] = mod.cardModel(state, 'en-GB');
for (const [name, review] of Object.entries(data.reviews)) out.results[name] = mod.resultScreen(review);
for (const [d, w, m] of data.counts) out.summaries[`${d}/${w}/${m}`] = mod.historySummary(d, w, m);
for (const code of data.codes) { out.refusals[code] = mod.refusalReason(code) + ' ' + mod.refusalNextStep(code); out.blocked[code] = mod.blockedSentence(code, '2031-01-02T00:00:00Z', 'en-GB'); }
for (const code of ['records_unprotected', 'listing_failed', 'latest_backup_missing', 'failed', 'anything']) out.errors[code] = mod.errorSentence(code);
for (const stage of ['approval', 'listing', 'checking', 'freeing', 'verifying']) out.stages[stage] = mod.stageSentence(stage, 3);
for (const [name, run] of Object.entries(data.lastRuns)) out.lastRuns[name] = mod.lastRunSentence(run, 'en-GB');
out.filesChecks = {};
for (const [name, [changes, unknown]] of Object.entries(data.filesChecks)) {
  out.filesChecks[name] = { card: mod.filesCheckSentence(changes, unknown, 'card', 'en-GB'), list: mod.filesCheckSentence(changes, unknown, 'list', 'en-GB') };
}
const limits = data.states.off.limits;
out.misc.parse = [mod.parseCount('daily', '14', limits), mod.parseCount('daily', '6', limits), mod.parseCount('daily', '91', limits), mod.parseCount('daily', '1.5', limits), mod.parseCount('monthly', '120', limits), mod.parseCount('weekly', '', limits)];
out.misc.clamp = [mod.clampCount('daily', 3, limits), mod.clampCount('weekly', 500, limits), mod.clampCount('monthly', 24.4, limits)];
out.misc.countError = mod.countError('weekly', limits);
out.misc.groups = mod.groupByMonth([{ when: '2025-12-31T23:00:00-05:00' }, { when: '2026-01-01T02:00:00+02:00' }, { when: '2025-12-02T02:00:00Z' }], 'en-GB').map(g => [g.key, g.label, g.items.length]);
out.misc.reasons = mod.reasonsLabel(['latest', 'day', 'week', 'month', 'checked', 'before_change']);
out.misc.busy = [mod.retentionBusyNote(null), mod.retentionBusyNote(data.states.running), mod.retentionBusyNote(data.states.listing)];
console.log(JSON.stringify(out));
"""

GATES = ["no_verified_backup", "last_backup_not_verified", "folders_changed", "change_review_open", "pending_change", "clock_problem",
         "future_dated_backup", "backup_location_unavailable", "google_drive_not_supported", "policy_inactive"]
REFUSALS = GATES + ["busy", "preview_mismatch", "earlier_changes_not_confirmed"]


def web_state(**overrides) -> dict:
    state = {
        "mode": "on", "unsupportedReason": "", "keepDaily": 14, "keepWeekly": 8, "keepMonthly": 24,
        "limits": {"daily": [7, 90], "weekly": [4, 104], "monthly": [6, 120]}, "recommended": {"daily": 14, "weekly": 8, "monthly": 24},
        "resetByReinstall": False, "problem": "",
        "preview": {"status": "ready", "blocked": "", "errorCode": "", "checkedAt": "2026-09-30T10:00:00Z", "removeCount": 12,
                    "keepCount": 40, "oldestRemoveAt": "2025-09-03T02:00:00+02:00", "newestRemoveAt": "2026-08-01T02:00:00+02:00",
                    "earlierChanges": [], "earlierChangesUnknown": False, "futureDatedAt": "", "prunePending": False},
        "lastRun": None, "operation": {"active": False, "action": "", "stage": "", "count": 0, "percent": None}, "notice": None,
        "canConfigure": {"enabled": True, "help": ""}, "canTurnOff": {"enabled": True, "help": ""},
        "canReview": {"enabled": True, "help": ""}, "canCheckNow": {"enabled": True, "help": ""}, "review": None,
    }
    preview = overrides.pop("preview", None)
    state.update(overrides)
    if preview is not None:
        state["preview"] = {**state["preview"], **preview}
    return state


def review_state(status: str, reason: str = "", removed: int = 2, confirmed: int = 5) -> dict:
    return {"removeCount": confirmed, "keepCount": 4, "newestKeptAt": "", "earlierChanges": [], "earlierChangesUnknown": False,
            "needsFilesConfirmed": False, "pruneOnly": False, "changed": False, "running": False, "captureKey": "k", "months": [],
            "page": {"list": "remove", "offset": 0, "total": 0, "size": 100, "rows": []},
            "result": {"status": status, "removedCount": removed, "confirmedCount": confirmed, "freedDisplay": "1.2 GiB", "reason": reason}}


class RetentionWordingTests(unittest.TestCase):
    report: dict

    @classmethod
    def setUpClass(cls) -> None:
        node = shutil.which("node")
        if not node:
            raise unittest.SkipTest("Node.js is unavailable")
        states = {
            "legacy": web_state(mode="unsupported", unsupportedReason="legacy", preview=None),
            "older": web_state(mode="unsupported", unsupportedReason="older_service"),
            "drive": web_state(mode="unsupported", unsupportedReason="google_drive"),
            "unknown": web_state(mode="unknown"),
            "off": web_state(mode="off"),
            "reset": web_state(mode="off", resetByReinstall=True),
            "ready": web_state(),
            "ready_one": web_state(preview={"removeCount": 1, "keepCount": 1, "newestRemoveAt": "2025-09-03T02:00:00+02:00"}),
            "ready_earlier": web_state(preview={"earlierChanges": [{"at": "2026-09-20T00:30:00Z", "kind": "hold"}]}),
            # An updated install: its earlier backups were logged by an older backup service that did not say whether they were
            # compared, and one was the first after a folder change. Neither changed far more files than usual.
            "ready_unknown_kind": web_state(preview={"earlierChanges": [{"at": "2026-09-29T00:30:00Z", "kind": "unknown"}],
                                                     "earlierChangesUnknown": True}),
            "ready_not_compared": web_state(preview={"earlierChanges": [{"at": "2026-09-28T00:30:00Z", "kind": "not_compared"}]}),
            # A hold among others is the one the card names, with its own date.
            "ready_mixed": web_state(preview={"earlierChanges": [{"at": "2026-09-29T00:30:00Z", "kind": "unknown"},
                                                                 {"at": "2026-09-21T00:30:00Z", "kind": "hold"}],
                                              "earlierChangesUnknown": True}),
            "ready_record_unknown": web_state(preview={"earlierChangesUnknown": True}),
            "first_read": web_state(mode="unknown", problem="not_read", preview=None),
            "plan_loading": web_state(mode="unknown", problem="plan_unavailable", preview=None),
            "nothing": web_state(preview={"removeCount": 0}),
            "prune_only": web_state(preview={"removeCount": 0, "prunePending": True}),
            "stale": web_state(preview={"status": "stale"}),
            "none": web_state(preview={"status": "none"}),
            "error": web_state(preview={"status": "error", "errorCode": "listing_failed"}),
            "running": web_state(operation={"active": True, "action": "apply", "stage": "freeing", "count": 12, "percent": 40}),
            "listing": web_state(operation={"active": True, "action": "preview", "stage": "listing", "count": 0, "percent": None}),
            "busy_review": web_state(canReview={"enabled": False, "help": "Wait for the running backup to finish."}),
        }
        for gate in GATES:
            states[f"blocked_{gate}"] = web_state(preview={"status": "blocked", "blocked": gate, "futureDatedAt": "2031-01-02T00:00:00Z"})
        reviews = {status: review_state(status) for status in
                   ["removed", "nothing_to_remove", "declined", "preview_changed", "partial", "space_pending", "check_failed", "failed", "unconfirmed"]}
        reviews["partial_unverified"] = review_state("partial", "unverified")
        reviews["space_pending_unrecorded"] = review_state("space_pending", "unrecorded")
        reviews["space_pending_earlier"] = review_state("space_pending", removed=0, confirmed=0)
        reviews["check_unfinished"] = review_state("check_failed", "unfinished")
        reviews["check_unfinished_earlier"] = review_state("check_failed", "unfinished", removed=0, confirmed=0)
        reviews["preview_changed_closed"] = review_state("preview_changed", "closed")
        for code in REFUSALS:
            reviews[f"refused_{code}"] = review_state("refused", code)
        last_runs = {outcome: {"finishedAt": "2026-09-01T03:00:00Z", "outcome": outcome, "removedCount": 3, "confirmedCount": 5, "freedDisplay": "",
                               "unverified": False, "checkUnfinished": False}
                     for outcome in ["removed", "nothing_to_remove", "partial", "space_pending", "check_failed", "failed"]}
        last_runs["removed_freed"] = {**last_runs["removed"], "freedDisplay": "4.1 GiB"}
        last_runs["partial_unverified"] = {**last_runs["partial"], "removedCount": 0, "unverified": True}
        last_runs["check_unfinished"] = {**last_runs["check_failed"], "checkUnfinished": True}
        last_runs["space_pending_earlier"] = {**last_runs["space_pending"], "removedCount": 0, "confirmedCount": 0}
        files_checks = {
            "hold": [[{"at": "2026-09-20T00:30:00Z", "kind": "hold"}], False],
            "hold_no_date": [[{"at": "", "kind": "hold"}], False],
            "not_compared": [[{"at": "2026-09-28T00:30:00Z", "kind": "not_compared"}], False],
            "unknown": [[{"at": "2026-09-29T00:30:00Z", "kind": "unknown"}, {"at": "2026-09-28T00:30:00Z", "kind": "unknown"}], True],
            "mixed": [[{"at": "2026-09-29T00:30:00Z", "kind": "not_compared"}, {"at": "2026-09-21T00:30:00Z", "kind": "hold"}], True],
            "record_unknown": [[], True],
            "first": [[], False],
        }
        data = {"states": states, "reviews": reviews, "codes": REFUSALS, "filesChecks": files_checks,
                "counts": [[14, 8, 24], [7, 4, 6], [90, 104, 120], [13, 7, 23], [21, 12, 36], [15, 9, 30]], "lastRuns": last_runs}
        with tempfile.TemporaryDirectory(prefix="rw-retention-wording-") as folder:
            input_path = Path(folder) / "input.json"
            write_json(input_path, data)
            completed = subprocess.run(
                [node, "--no-warnings", "--experimental-strip-types", "--input-type=module", "-e", NODE_RUNNER,
                 (WEB / "src" / "retention.ts").as_uri(), str(input_path)],
                capture_output=True, encoding="utf-8", timeout=60, check=False,
            )
        if completed.returncode != 0 and "ERR_UNKNOWN_FILE_EXTENSION" in completed.stderr:
            raise unittest.SkipTest("this Node.js cannot run TypeScript files")
        if completed.returncode != 0:
            raise AssertionError(completed.stderr)
        cls.report = json.loads(completed.stdout)

    def card(self, name: str) -> dict:
        return self.report["cards"][name]

    def buttons(self, name: str) -> list[str]:
        return [button["label"] for button in self.card(name)["buttons"]]

    def test_every_sentence_uses_the_persons_words_and_never_the_services(self) -> None:
        texts: list[str] = []
        for card in self.report["cards"].values():
            texts += [card["main"], *card["lines"], *[button["label"] for button in card["buttons"]]]
        for screen in self.report["results"].values():
            texts += [screen["title"], screen["text"]]
        for group in ("summaries", "refusals", "blocked", "errors", "stages", "lastRuns"):
            texts += list(self.report[group].values())
        texts += [self.report["misc"]["countError"], self.report["misc"]["reasons"], *[x for x in self.report["misc"]["busy"] if x]]
        for check in self.report["filesChecks"].values():
            texts += [x for x in (check["card"], check["list"]) if x]
        for text in texts:
            with self.subTest(text=text):
                self.assertTrue(text)
                self.assertIsNone(FORBIDDEN.search(text))
                self.assertNotIn("backup drive", text)

    def test_unsupported_and_legacy_cards_offer_nothing(self) -> None:
        for name in ("legacy", "older", "drive"):
            with self.subTest(name=name):
                self.assertEqual(self.card(name)["main"], "Rewindle keeps every backup.")
                self.assertEqual(self.card(name)["buttons"], [])
        self.assertIn("earlier personal edition", self.card("legacy")["lines"][0])
        self.assertIn("Reinstall or repair", self.card("older")["lines"][0])
        self.assertIn("Google Drive", self.card("drive")["lines"][0])

    def test_off_is_the_default_card_and_offers_only_turning_it_on(self) -> None:
        self.assertEqual(self.card("off")["main"], "Rewindle keeps every backup.")
        self.assertEqual(self.buttons("off"), ["Turn on clean-up…"])
        self.assertIn("only after you check the list and confirm it", self.card("off")["lines"][0])
        self.assertIn("reinstalled or updated", self.card("reset")["lines"][0])
        self.assertIn("Nothing was removed", self.card("reset")["lines"][0])
        self.assertEqual(self.buttons("unknown"), ["Try again"])

    def test_the_on_card_for_each_list_state(self) -> None:
        self.assertEqual(self.card("ready")["main"],
                         "Clean-up is on: keeping a backup for each of the last 14 days, 8 weeks and 24 months.")
        self.assertRegex(self.card("ready")["lines"][0], r"^12 old backups can be removed, from .+ to .+\. 40 backups stay\.$")
        self.assertEqual(self.buttons("ready"), ["Review and remove…", "Change…", "Turn off"])
        self.assertRegex(self.card("ready_one")["lines"][0], r"^1 old backup can be removed, from [^.]+\. 1 backup stays\.$")
        self.assertRegex(self.card("ready_earlier")["lines"][1],
                         r"^A backup on 20 Sept? 2026 changed far more files than usual\. Before anything is removed, you’ll be asked "
                         r"to check that your files look right\.$")
        self.assertEqual(self.card("nothing")["lines"][0], "Nothing to remove right now. Rewindle offers to check again after your next backup.")
        self.assertEqual(self.buttons("nothing"), ["Change…", "Turn off"])
        self.assertEqual(self.buttons("prune_only")[0], "Finish freeing space")
        for name in ("stale", "none", "error"):
            with self.subTest(name=name):
                self.assertIn("Check now", self.buttons(name))
        for gate in GATES:
            with self.subTest(gate=gate):
                card = self.card(f"blocked_{gate}")
                self.assertNotIn("Review and remove…", self.buttons(f"blocked_{gate}"))
                self.assertEqual(card["lines"][0], self.report["blocked"][gate])
        # Each reason says what to do or that nothing needs doing.
        for gate, sentence in self.report["blocked"].items():
            with self.subTest(gate=gate):
                self.assertRegex(sentence, r"Choose|Look at|Correct|shows what to do|starts after|stay where they are|save a problem report")
        self.assertIn("2031", self.report["blocked"]["future_dated_backup"])
        self.assertEqual(self.card("busy_review")["buttons"][0]["ability"]["enabled"], False)

    def test_only_a_backup_that_held_is_called_unusual(self) -> None:
        checks = self.report["filesChecks"]
        alarm = re.compile(r"far more files|unusual|missing or damaged|only good copies", re.IGNORECASE)
        ask = "Before anything is removed, you’ll be asked to check that your files look right."
        not_compared_card = f"Rewindle couldn’t compare some recent backups with the ones before them. {ask}"
        not_compared_list = ("Rewindle couldn’t compare some recent backups with the ones before them, so check that your files look "
                             "right before you continue.")
        # A backup whose changes held clean-up back is named with its own date, on the card and in the list.
        self.assertRegex(checks["hold"]["card"], r"^A backup on 20 Sept? 2026 changed far more files than usual\. Before anything")
        self.assertRegex(checks["hold"]["list"], r"^A backup on 20 Sept? 2026 changed far more files than usual, and those changes weren’t confirmed\.")
        self.assertTrue(checks["hold_no_date"]["card"].startswith("A recent backup changed far more files than usual."))
        self.assertRegex(checks["mixed"]["card"], r"^A backup on 21 Sept? 2026 changed far more files than usual\.")
        # One that could not be compared, or whose record does not say (an older backup service), is never called unusual.
        for name in ("not_compared", "unknown"):
            with self.subTest(kind=name):
                self.assertEqual(checks[name]["card"], not_compared_card)
                self.assertEqual(checks[name]["list"], not_compared_list)
                self.assertIsNone(alarm.search(checks[name]["card"] + " " + checks[name]["list"]))
        self.assertEqual(checks["record_unknown"]["card"], ask)
        self.assertEqual(checks["record_unknown"]["list"],
                         "Rewindle couldn’t read all its records of earlier backups, so check that your files look right before you continue.")
        self.assertEqual(checks["first"]["card"], "")
        self.assertTrue(checks["first"]["list"].startswith("This is the first clean-up, so check that your files look right"))
        for name in ("record_unknown", "first"):
            with self.subTest(case=name):
                self.assertIsNone(alarm.search(checks[name]["card"] + " " + checks[name]["list"]))
        # The same on the card, for an updated install and for a backup after a folder change.
        for name in ("ready_unknown_kind", "ready_not_compared"):
            with self.subTest(card=name):
                lines = self.card(name)["lines"]
                self.assertEqual(lines[1], not_compared_card)
                for line in lines:
                    self.assertIsNone(alarm.search(line))
        self.assertRegex(self.card("ready_mixed")["lines"][1], r"^A backup on 21 Sept? 2026 changed far more files than usual\.")
        self.assertEqual(self.card("ready_record_unknown")["lines"][1], ask)
        self.assertEqual(len(self.card("ready")["lines"]), 1)

    def test_the_first_read_is_neutral(self) -> None:
        for name in ("first_read", "plan_loading"):
            with self.subTest(name=name):
                card = self.card(name)
                self.assertEqual((card["main"], card["tone"], card["buttons"], card["lines"]),
                                 ("Checking the clean-up setting…", "neutral", [], []))
        # A setting that was read and could not be trusted still says so, with what to do.
        self.assertEqual((self.card("unknown")["main"], self.card("unknown")["tone"]),
                         ("Rewindle couldn’t read the clean-up setting.", "warning"))

    def test_running_steps_and_the_busy_note(self) -> None:
        running = self.card("running")
        self.assertEqual((running["main"], running["buttons"], running["busy"]), ("Removing old backups…", [], True))
        self.assertIn("is skipped", running["lines"][1])
        self.assertEqual(self.report["stages"]["checking"], "Checking the list, then removing 3 old backups…")
        self.assertIn("backup location", self.report["stages"]["freeing"])
        busy = self.report["misc"]["busy"]
        self.assertEqual(busy[0], "")
        self.assertIn("a backup that’s due meanwhile is skipped", busy[1])
        self.assertIn("checking for old backups", busy[2])

    def test_result_screens(self) -> None:
        results = self.report["results"]
        self.assertEqual(results["removed"]["title"], "Old backups removed")
        self.assertIn("freed 1.2 GiB", results["removed"]["text"])
        self.assertIn("didn’t allow it", results["declined"]["text"])
        self.assertIn("Here is the new list", results["preview_changed"]["text"])
        self.assertIn("Removed 2 of 5 backups", results["partial"]["text"])
        self.assertIn("The other 3 are still there", results["partial"]["text"])
        self.assertIn("Nothing outside the list you confirmed was removed", results["partial_unverified"]["text"])
        self.assertIn("Check recovery readiness", results["check_failed"]["text"])
        self.assertIn("can only remove backups on the list you saw", results["unconfirmed"]["text"])
        # When the list could not be read back, nobody knows how many went: it never says that some did.
        self.assertIn("Some backups on the list may have been removed", results["partial_unverified"]["text"])
        self.assertIn("Settings shows what’s there now", results["partial_unverified"]["text"])
        # After the backups were removed, a later step that didn't finish says the backups went and what is left to do.
        self.assertEqual(results["space_pending"]["title"], "Backups removed, space not freed yet")
        self.assertIn("Removed 2 old backups, but freeing their space didn’t finish", results["space_pending"]["text"])
        self.assertIn("Choose Finish freeing space in Settings", results["space_pending"]["text"])
        self.assertIn("freed the next time old backups are removed", results["space_pending_unrecorded"]["text"])
        self.assertNotIn("Finish freeing space", results["space_pending_unrecorded"]["text"])
        self.assertNotIn("Removed 0", results["space_pending_earlier"]["text"])
        self.assertIn("backups removed earlier didn’t finish", results["space_pending_earlier"]["text"])
        self.assertEqual(results["check_unfinished"]["title"], "Backups removed, check didn’t finish")
        self.assertIn("Removed 2 old backups and freed the space", results["check_unfinished"]["text"])
        self.assertIn("Check recovery readiness", results["check_unfinished"]["text"])
        self.assertNotIn("found a problem", results["check_unfinished"]["text"])
        self.assertNotIn("Removed 0", results["check_unfinished_earlier"]["text"])
        self.assertIn("found a problem", results["check_failed"]["text"])
        # A changed list with nothing new to offer ends the dialog with a next step instead of a list that can't be shown.
        self.assertIn("Here is the new list", results["preview_changed"]["text"])
        self.assertNotIn("Here is the new list", results["preview_changed_closed"]["text"])
        self.assertIn("Close this", results["preview_changed_closed"]["text"])
        # A backup that finished while the list was open: plain words and a next step.
        self.assertEqual(results["refused_preview_mismatch"]["text"],
                         "Nothing was removed because the list is out of date. Close this list and choose Check now.")
        for code in REFUSALS:
            with self.subTest(code=code):
                self.assertTrue(results[f"refused_{code}"]["text"].startswith("Nothing was removed because "))
                self.assertNotIn("something it needs", results[f"refused_{code}"]["text"])

    def test_counts_summaries_and_months(self) -> None:
        summaries = self.report["summaries"]
        self.assertEqual(summaries["14/8/24"],
                         "You can go back to any day in the last 2 weeks, any week in roughly the last 2 months and any month in the last 2 years.")
        self.assertEqual(summaries["7/4/6"],
                         "You can go back to any day in the last 7 days, any week in the last 4 weeks and any month in the last 6 months.")
        self.assertEqual(summaries["90/104/120"],
                         "You can go back to any day in the last 90 days, any week in roughly the last 24 months and any month in the last 10 years.")
        self.assertIn("13 days", summaries["13/7/23"])
        self.assertIn("3 weeks", summaries["21/12/36"])
        self.assertIn("30 months", summaries["15/9/30"])
        self.assertEqual(self.report["misc"]["parse"], [14, None, None, None, 120, None])
        self.assertEqual(self.report["misc"]["clamp"], [7, 104, 24])
        self.assertEqual(self.report["misc"]["countError"], "Choose a number from 4 to 104.")
        # Each backup is in the month of its own recorded time, across a year boundary.
        self.assertEqual([group[0] for group in self.report["misc"]["groups"]], ["2026-01", "2025-12"])
        self.assertEqual([group[2] for group in self.report["misc"]["groups"]], [1, 2])
        self.assertEqual(self.report["misc"]["groups"][1][1], "December 2025")

    def test_last_run_lines_always_end_with_what_happened_or_what_to_do(self) -> None:
        runs = self.report["lastRuns"]
        self.assertIn("freed 4.1 GiB", runs["removed_freed"])
        self.assertIn("Choose Review and remove to try again", runs["partial"])
        self.assertIn("Choose Review and remove to try again", runs["failed"])
        self.assertIn("Check recovery readiness", runs["check_failed"])
        self.assertIn("freeing their space didn’t finish", runs["space_pending"])
        self.assertNotIn("removed 0", runs["space_pending_earlier"])
        self.assertIn("The next clean-up frees it", runs["space_pending_earlier"])
        # Nobody knows how many went: it never claims a count, and never that the rest are all still there.
        self.assertNotIn("removing 0", runs["partial_unverified"])
        self.assertNotIn("The rest are still there", runs["partial_unverified"])
        self.assertIn("stopped before Rewindle could confirm which backups on the list were removed", runs["partial_unverified"])
        self.assertIn("The next clean-up finishes it", runs["partial_unverified"])
        self.assertIn("didn’t finish", runs["check_unfinished"])
        self.assertNotIn("found a problem", runs["check_unfinished"])
        self.assertIn("Check recovery readiness", runs["check_unfinished"])


class RetentionStaticTests(unittest.TestCase):
    @staticmethod
    def split_source(text: str, quotes: str) -> tuple[list[str], str]:
        """The string literals of a source file, and the file with its comments and literals blanked out."""
        found: list[str] = []
        code: list[str] = []
        index, length = 0, len(text)
        while index < length:
            if text.startswith("//", index):
                end = text.find("\n", index)
                index = length if end < 0 else end
                continue
            if text.startswith("/*", index):
                end = text.find("*/", index + 2)
                index = length if end < 0 else end + 2
                continue
            quote = text[index]
            if quote in quotes:
                end, value = index + 1, []
                while end < length and text[end] != quote:
                    if text[end] == "\\":
                        value.append(text[end:end + 2])
                        end += 2
                        continue
                    if quote != "`" and text[end] == "\n":
                        break
                    value.append(text[end])
                    end += 1
                found.append("".join(value))
                code.append('""')
                index = end + 1
                continue
            code.append(quote)
            index += 1
        return found, "".join(code)

    @classmethod
    def sentences(cls, text: str, quotes: str, jsx: bool = True) -> list[str]:
        """Literals with a space in them (sentences, not identifiers or class names), and JSX text."""
        literals, code = cls.split_source(text, quotes)
        literals = [re.sub(r"\$\{[^}]*\}", "…", item) for item in literals]
        found = [item for item in literals if " " in item and not re.fullmatch(r"[\w\- .:/@\[\]=…]*-[\w\- .:/@\[\]=…]*", item)]
        for part in re.findall(r">([^<>{}]*)(?=[<{])", code) if jsx else []:
            part = part.strip()
            if re.match(r"[A-Z]", part) and not re.search(r";|=|&&|\|\||\w\.\w", part):
                found.append(part)
        return found

    def test_the_scanner_finds_sentences_and_skips_code(self) -> None:
        sample = "const a = 'Keep it';\n// a forget comment\nconst b = cls('old-backups-x y-z');\n<p>Text shown here</p>{x}\n"
        self.assertEqual(self.sentences(sample, "'\"`"), ["Keep it", "Text shown here"])

    def test_nothing_the_page_shows_uses_the_services_own_words(self) -> None:
        files = [WEB / "src" / "retention.ts", WEB / "components" / "primitives" / "RetentionCard.tsx",
                 WEB / "components" / "primitives" / "RetentionDialogs.tsx"]
        checked = 0
        for path in files:
            for sentence in self.sentences(path.read_text(encoding="utf-8"), "'\"`"):
                checked += 1
                with self.subTest(path=path.name, sentence=sentence):
                    self.assertIsNone(FORBIDDEN.search(sentence))
        host = (DASHBOARD / "DashboardWindow.Retention.cs").read_text(encoding="utf-8")
        for sentence in self.sentences(host, '"', jsx=False):
            checked += 1
            with self.subTest(path="DashboardWindow.Retention.cs", sentence=sentence):
                self.assertIsNone(FORBIDDEN.search(sentence))
        self.assertGreater(checked, 100)

    def test_only_the_dialogs_own_buttons_turn_it_on_or_remove_backups(self) -> None:
        dialogs = (WEB / "components" / "primitives" / "RetentionDialogs.tsx").read_text(encoding="utf-8")
        for path in (WEB / "src").rglob("*.ts*"):
            if "demo" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=path.name):
                self.assertNotIn("send('retentionApply'", text)
                self.assertNotIn("send('retentionConfigure'", text)
        card = (WEB / "components" / "primitives" / "RetentionCard.tsx").read_text(encoding="utf-8")
        self.assertNotIn("send('retentionApply'", card)
        self.assertNotIn("send('retentionConfigure'", card)
        # In the dialogs, each send is inside a submit handler, and no effect sends either.
        for command in ("retentionApply", "retentionConfigure"):
            for match in re.finditer(re.escape(f"send('{command}'"), dialogs):
                before = dialogs[:match.start()]
                handler = before[before.rfind("const "):]
                self.assertRegex(handler, r"^const (submit|remove) = \(event: FormEvent\) => \{")
        effects = re.findall(r"useEffect\((.*?)\}, \[[^\]]*\]\)", dialogs, flags=re.DOTALL)
        self.assertGreaterEqual(len(effects), 4)
        for effect in effects:
            self.assertNotIn("send(", effect)

    def test_the_host_routes_and_gates_every_clean_up_command(self) -> None:
        web = (DASHBOARD / "DashboardWindow.Web.cs").read_text(encoding="utf-8")
        self.assertIn('state["retention"] = BuildWebRetentionState();', web)
        self.assertIn("ApplyRetentionBusyToActions(actions);", web)
        # The refusal hook runs before any other routing; the commands themselves only after run details and the Restore flow.
        execute = web[web.index("private bool ExecuteWebCommand("):]
        self.assertLess(execute.index("RetentionBlocksCommand(command, out error)"), execute.index("IsRunDetailsCommand(command)"))
        self.assertLess(execute.index("restoreFlowOpen && command != \"refresh\""), execute.index("IsRetentionCommand(command)"))
        build = (DASHBOARD / "build.ps1").read_text(encoding="utf-8")
        self.assertIn("RetentionManager.cs", build)
        self.assertIn("DashboardWindow.Retention.cs", build)
        types = (WEB / "src" / "native-types.ts").read_text(encoding="utf-8")
        once = (WEB / "src" / "oneShot.ts").read_text(encoding="utf-8")
        for command in ("retentionConfigure", "retentionCheckNow", "retentionOpenReview", "retentionApply"):
            with self.subTest(command=command):
                self.assertIn(f"'{command}'", types[types.index("PROTECTED_COMMANDS"):])
                self.assertIn(f"'{command}'", once)

    def test_the_legacy_profile_reads_nothing_for_clean_up(self) -> None:
        host = (DASHBOARD / "DashboardWindow.Retention.cs").read_text(encoding="utf-8")
        build = host[host.index("private Dictionary<string, object> BuildWebRetentionState()"):]
        legacy = build.index("if (!RetentionSupportedByProfile())")
        self.assertLess(legacy, build.index("RefreshRetentionStateAsync();"))
        self.assertIn('state["unsupportedReason"] = "legacy";', build[legacy:legacy + 300])
        self.assertIn("if (!RetentionSupportedByProfile() || !RetentionCapabilityAvailable())", host)
        self.assertIn(
            'internal const string RetentionUnavailableMessage =\n            "Clean-up of old backups isn\'t available for this backup service.";',
            host,
        )


if __name__ == "__main__":
    unittest.main()
