# MO2 test workspace control

This tool gives each automation task a unique MO2 profile cloned from an
explicitly configured, known-good `defaults.testProfileSource`. It never uses
the ordinary session default as an implicit template and never copies saves.

The task must own an MO2 access lease. MO2, Skyrim, loaders, and active
RootBuilder deployment must be closed before `create`, `register-mod`, or
`release`. Release any evidence session before mutating the workspace.

```powershell
$workspace = .\Invoke-MO2WorkspaceControl.ps1 create `
  -AccessId $accessId -Label 'weather-api' -SavePolicy MainMenuOnly | ConvertFrom-Json
$workspaceId = $workspace.data.workspaceId

.\Invoke-MO2WorkspaceControl.ps1 register-mod `
  -AccessId $accessId -WorkspaceId $workspaceId `
  -ModName 'Codex Weather API Test 20260822' `
  -ModDirectory '<MO2 mods>\Codex Weather API Test 20260822' `
  -Placement Before -RelativeToMod 'Community Shaders' -Confirm:$false

.\Invoke-MO2WorkspaceControl.ps1 release `
  -AccessId $accessId -WorkspaceId $workspaceId `
  -CleanupOwnedMods -Confirm:$false
.\Invoke-MO2Control.ps1 release-access -AccessId $accessId
```

`MainMenuOnly` never authorizes loading a save. `FreshGame` records that a
genuine New Game action is required; this release does not synthesize that
action, and `coc APStartCell` is explicitly not equivalent. `VerifiedFixture` requires a fixture
manifest whose `profileFingerprintSha256` exactly matches the source profile.
An arbitrary inherited save is never a baseline.

At creation the tool records every existing mod directory. A workspace may
register only an exact mod directory absent from that snapshot. It refuses to
claim, replace, or delete a pre-existing shared mod. Cleanup is restricted to
the exact generated profile and registered task-owned mods; the stable source
profile must remain byte-identical.
