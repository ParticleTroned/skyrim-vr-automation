# SteamVR null-HMD control

`Invoke-SteamVRNullControl.ps1` transactionally inspects, applies, starts, and
restores the Valve null-HMD route. Apply always takes an exact settings backup,
and restore requires its hash receipt.

Applying settings is not runtime proof. `start` launches SteamVR and succeeds
only after the current `vrserver` session logs both the Valve null driver load
and `Active HMD set to null.<configured serial>`. `inspect` therefore reports
`null-configured-runtime-stopped` separately from
`null-runtime-active-unqualified`.

The profile sets `dashboard.enableDashboard=false` so the generic-HMD
laser-mouse/dashboard route is not invited into a headless run. Startup waits
through a short stabilization window and fails with `dashboard-input-conflict`
if `vrdashboard.exe` nevertheless appears. The controller never edits Valve's
bindings and does not invent controller devices.

Valve's null driver supplies a fixed HMD pose but exposes neither a controlled
head-pose input nor controller inputs. The returned `inputContract` therefore
marks `hmdPoseControl` and `controllerInput` unavailable and keeps
`replayReady` and `measurementReady` false. Driver activation is sufficient
for rendering and screenshots, but is not proof that Skyrim received a sane
standing eye height or coherent stereo transforms. Replay and render
measurement must remain fail-closed until an application-observed pose
qualification receipt exists.

Before `start`, the controller reads the OpenVR registration file (normally
`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`) and inventories every external
driver manifest with exact paths and hashes. An external driver declaring
`redirectsDisplay=true` conflicts with the forced null display path: `inspect`
returns `external-driver-conflict`, and `start` refuses with the exact driver
inventory. Use `-OpenVRPathsPath` for a nonstandard registration file. This
preflight also refuses startup when a registered driver cannot be classified;
it does not mutate or unregister third-party drivers.

The default null-HMD profile is resolved from
`../../profiles/steamvr-null.profile.json`. Pass `-SettingsPath` and
`-SteamVRRoot` for nonstandard Steam installations.
The controller requires PowerShell 7 or newer. Windows PowerShell 5.1 returns
the structured state `unsupported-powershell-version` with an exact `pwsh.exe`
migration instruction before reaching unsupported JSON parameters.

`stop` first requests SteamVR's normal shutdown and waits for a closed-state
postcondition. If the null-driver runtime does not accept that request, inspect
the returned exact process inventory and retry with `stop -Force`. The forced
path validates every target executable is inside `SteamVRRoot` before stopping
it; it does not target Steam, Virtual Desktop, or unrelated same-name binaries.
Same-name processes outside the configured root are reported as unproven but
are never used as stop, start, apply, or restore blockers.

```powershell
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 start -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 inspect -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Force -Compact
.\Invoke-SteamVRNullControl.ps1 restore -EvidenceDirectory <session-evidence> -Compact
```

Launch Skyrim only after `start` or `inspect` returns current-session runtime
proof, and do not interpret the `-unqualified` state as replay or measurement
readiness. Also use an MO2 profile that disables OpenComposite; a running null
SteamVR instance does not prove an application bypassing SteamVR is attached to
it.

Run `Test-SteamVRNullControl.ps1` after changing the control contract.
