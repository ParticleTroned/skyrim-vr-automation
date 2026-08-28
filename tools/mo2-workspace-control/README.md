# MO2 test workspace control

This tool gives each automation task a unique MO2 profile cloned from an
explicitly configured, known-good `defaults.testProfileSource`. It never uses
the ordinary session default as an implicit template and never copies unknown
or unlisted saves.

The task must own an MO2 access lease. MO2, Skyrim, loaders, and active
RootBuilder deployment must be closed before `create`, `register-mod`, or
`release`. Release any evidence session before mutating the workspace. All
commands accept `-Compact` for one-line JSON.

For elevated use, follow `../mo2-control/APPROVALS.md`. Every result reports a
literal command-specific `data.approval.reusablePrefix`. `create`,
`register-mod`, and `ensure-mod-wins` are eligible for narrow reusable approval;
`refresh-fixture`, `recover-legacy-selection`, and `release` remain one-shot
because they replace shared metadata, change shared profile selection, or
recursively remove exact owned paths.

```text
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> create -AccessId <literal-access-id> -Label weather-api -SavePolicy MainMenuOnly -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> register-mod -AccessId <literal-access-id> -WorkspaceId <literal-workspace-id> -ModName "Codex Weather API Test 20260822" -ModDirectory "<exact-mod-directory>" -WinningPaths "SKSE\Plugins\CommunityShaders.dll" -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> recover-legacy-selection -AccessId <literal-access-id> -WorkspaceId <literal-workspace-id> -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2WorkspaceControl.ps1> release -AccessId <literal-access-id> -WorkspaceId <literal-workspace-id> -CleanupOwnedMods -Confirm:$false -Compact
<absolute-pwsh.exe> -NoProfile -NonInteractive -File <absolute-Invoke-MO2Control.ps1> release-access -AccessId <literal-access-id> -Compact
```

`MainMenuOnly` never authorizes loading a save. `FreshGame` records that a
genuine New Game action is required; this release does not synthesize that
action, and `coc APStartCell` is explicitly not equivalent.

`VerifiedFixture` is the deterministic automation form of “new game”. It uses
`-FixtureManifestPath`, or `defaults.newGameFixtureManifest`, and selects
`-FixtureId` or the manifest's `defaultFixtureId`. The manifest fingerprint must
match the exact stable source profile. Every listed save/co-save is verified by
path, size, and SHA-256 before and after copying; no other save is copied. The
result reports the fixture ID, location, and `loadName` for a later game-load
adapter. See `save-fixtures.example.json` for the portable schema.
Environment variables in the manifest path, including `%LOCALAPPDATA%`, are
expanded before the path is normalized.
The controller applies the same expansion and unresolved-variable check to its
configured MO2 INI, profiles, mods, and session-staging paths before any read
or write.

Use `fixture-status` to compare the manifest's expected stable-profile
fingerprint and declared save hashes with their current actual values without
changing anything. `refresh-fixture` is the separately authorized repair path:
it requires the exact access lease and closed-state proof, preserves the prior
manifest and a receipt, refreshes only the selected declared fixture, and
verifies the postcondition. It never invents a replacement save path.

At creation the tool records every existing mod directory. A workspace may
register only an exact mod directory absent from that snapshot. It refuses to
claim, replace, or delete a pre-existing shared mod. Cleanup is restricted to
the exact generated profile and registered task-owned mods; the stable source
profile must remain byte-identical. Before deleting a task profile, `release`
atomically selects and verifies its stable source in `ModOrganizer.ini`, keeps
the exact prior INI bytes and receipt, and only then removes the task profile.
Workspace manifests and results expose `profileName`, `profileDirectory`, and
`modListPath` while retaining the legacy `profile` and `profilePath` fields.

Creation also makes one unique `Codex Runtime Output - <workspace-id>` mod,
enables it ahead of every loose `ShaderCache` provider, writes
`ShaderCache/.codex-vfs-sentinel.txt`, and maps the exact
`defaults.executable` to that mod in the cloned profile's
`[custom_overwrites]` section. Existing mappings, including mappings owned by
unrelated executables, remain unchanged. The result returns
`runtimeOutput.cachePrepareArguments`; pass those exact `ProfilePath`,
`ModsPath`, `CacheModName`, and `EvidenceDirectory` values to shader-cache
catalog `prepare` together with `-RequireMaterializedOutput` and the build's
compatibility metadata.

MO2 `prepare` and `launch` fail closed for every `Codex Task -` profile unless
that output mapping is still exact, the task mod remains the effective enabled
loose cache provider, and its cache plan is open and bound to the current
modlist hash. After game and MO2 shutdown, run shader-cache catalog `complete`
before workspace `release`. Release refuses an open transaction, a completion
without materialized files, or unclassified output without a plan. It retains
a hash-verified copy of the complete task output before `-CleanupOwnedMods`
may remove the owned mod. A failure leaves the profile, output mod, and
transaction evidence in place.

`-WinningPaths` changes `register-mod` into an enabled winning-provider
transaction. `ensure-mod-wins` can subsequently re-check and reposition only a
mod already proven task-owned by that workspace. Winner proof intentionally
covers enabled loose-file providers in the exact profile. Overwrite, unmanaged
game files, and archives still require separate VFS evidence.

`recover-legacy-selection` is the bounded migration path for a retained task
profile created before runtime-output isolation. It requires the current
access lease and closed-state proof, identifies one exact legacy manifest, and
atomically selects the configured stable source profile. It preserves the
legacy profile, mods, shader caches, and manifest unchanged while retaining an
exact MO2 INI backup and receipt. It refuses current isolated workspaces,
ambiguous ownership, a mismatched workspace ID, or a noncanonical source.
