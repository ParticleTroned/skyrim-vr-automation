# MO2 test workspace control

This tool gives each automation task a unique MO2 profile cloned from an
explicitly configured, known-good `defaults.testProfileSource`. It never uses
the ordinary session default as an implicit template and never copies unknown
or unlisted saves.

The task must own an MO2 access lease. MO2, Skyrim, loaders, and active
RootBuilder deployment must be closed before `create`, `register-mod`, or
`release`. Release any evidence session before mutating the workspace. All
commands accept `-Compact` for one-line JSON.

```powershell
$workspace = .\Invoke-MO2WorkspaceControl.ps1 create `
  -AccessId $accessId -Label 'weather-api' -SavePolicy MainMenuOnly | ConvertFrom-Json
$workspaceId = $workspace.data.workspaceId

.\Invoke-MO2WorkspaceControl.ps1 register-mod `
  -AccessId $accessId -WorkspaceId $workspaceId `
  -ModName 'Codex Weather API Test 20260822' `
  -ModDirectory '<MO2 mods>\Codex Weather API Test 20260822' `
  -Placement Before -RelativeToMod 'Community Shaders' -Confirm:$false

# Prefer this form for a newly deployed DLL mod. It enables the mod, places it
# before every enabled loose-file provider of the exact path, and records the
# provider inventory and verified postcondition.
.\Invoke-MO2WorkspaceControl.ps1 register-mod `
  -AccessId $accessId -WorkspaceId $workspaceId `
  -ModName 'Codex Weather API Test 20260822' `
  -ModDirectory '<MO2 mods>\Codex Weather API Test 20260822' `
  -WinningPaths 'SKSE\Plugins\CommunityShaders.dll' -Confirm:$false

.\Invoke-MO2WorkspaceControl.ps1 release `
  -AccessId $accessId -WorkspaceId $workspaceId `
  -CleanupOwnedMods -Confirm:$false
.\Invoke-MO2Control.ps1 release-access -AccessId $accessId
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

`-WinningPaths` changes `register-mod` into an enabled winning-provider
transaction. `ensure-mod-wins` can subsequently re-check and reposition only a
mod already proven task-owned by that workspace. Winner proof intentionally
covers enabled loose-file providers in the exact profile. Overwrite, unmanaged
game files, and archives still require separate VFS evidence.
