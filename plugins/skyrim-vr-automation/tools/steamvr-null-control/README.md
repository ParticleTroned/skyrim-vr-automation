# SteamVR null-HMD control

`Invoke-SteamVRNullControl.ps1` transactionally inspects, applies, starts, and
restores the Valve null-HMD route. Apply always takes an exact settings backup,
and restore requires its hash receipt.

Applying settings is not runtime proof. `start` launches SteamVR and succeeds
only after the current `vrserver` session logs both the Valve null driver load
and `Active HMD set to null.<configured serial>`. `inspect` therefore reports
`null-configured-runtime-stopped` separately from `null-runtime-active`.

The default null-HMD profile is resolved from
`../../profiles/steamvr-null.profile.json`. Pass `-SettingsPath` and
`-SteamVRRoot` for nonstandard Steam installations.
The default is resolved after script parameter binding so Windows PowerShell
child-process invocation cannot observe an empty `$PSScriptRoot` while
evaluating the parameter default.

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
proof. Also use an MO2 profile that disables OpenComposite; a running null
SteamVR instance does not prove an application bypassing SteamVR is attached to
it.

Run `Test-SteamVRNullControl.ps1` after changing the control contract.
