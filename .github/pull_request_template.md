## What and why

<!-- What does this change, and why is it needed? Link the issue it addresses, if any. -->

## Safety

<!-- Does this touch ACLs, elevation, scheduled tasks, password handling, restore behavior or repository writes?
     If so, explain the effect on each invariant below. Write "None" if it does not. -->

## Never-weaken checklist

This change keeps every one of these intact (see [CONTRIBUTING.md](https://github.com/50sotero/rewindle/blob/main/CONTRIBUTING.md#never-weaken-these)):

- [ ] **UAC and elevation boundary.** The dashboard still runs with standard rights, never writes protected configuration, never reads the repository password, and makes changes only through managers and helpers started by fixed path with a UAC prompt, bound to the user's SID.
- [ ] **Nonce- and digest-bound requests.** Manager requests still carry a fresh nonce and a domain-separated SHA-256 digest, and results are still accepted only from the protected results folder when every binding, size and ACL matches.
- [ ] **Path guards.** No UNC or network paths, no junctions, symbolic links or other reparse points, DOS 8.3 aliases expanded before comparison, no overlap between sources, repository, runtime and state, and restores only into new or empty targets with no overwrite.
- [ ] **Runtime-manifest hashes.** Payload and runtime manifest checks are unchanged, with no new exemptions or unmanifested files.
- [ ] **Administrator-launch refusal.** The dashboard still refuses to start with an administrator token.
- [ ] **Disabled-while-busy actions.** Protected actions are still disabled, with a reason, while a backup, repair or other protected operation runs.
- [ ] Nothing new deletes, forgets or prunes repository data automatically or by default.

## Tests

<!-- Tick what you ran, and paste any failures you could not resolve. -->

- [ ] `py -3.14 -m unittest discover -s tests`
- [ ] `powershell.exe -NoProfile -ExecutionPolicy Bypass -File src\dashboard\tests\restore-flow-regressions.ps1 -SkipInstalledChecks` (after `pwsh .\src\dashboard\build.ps1`)
- [ ] The affected suites in `tests\*.ps1`, for example `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-ManageSources.ps1`
- [ ] `pwsh .\build\Build-Release.ps1` followed by `pwsh .\tests\Test-ReleaseArtifact.ps1` (for engine, installer or build changes)
- [ ] New or changed behavior has tests

## Housekeeping

- [ ] No real paths, user names, host names, volume serials, logs, repositories, DPAPI envelopes, recovery keys or build output are committed.
- [ ] The version is only in `VERSION` (and the `package.json` files the dashboard build updates from it).
- [ ] README, `docs/` and the `Unreleased` section of `CHANGELOG.md` are updated where users would notice the change.
- [ ] `docs/engine-contract.md` is updated if the dashboard's interface with an engine changed.
