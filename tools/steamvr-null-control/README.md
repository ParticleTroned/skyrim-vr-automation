# SteamVR null-HMD control

`Invoke-SteamVRNullControl.ps1` transactionally inspects, applies, and restores
the Valve null-HMD user overrides. Apply always takes an exact backup and
restore requires its hash receipt.

The default null-HMD profile is resolved from
`../../profiles/steamvr-null.profile.json`. Pass `-SettingsPath` and
`-SteamVRRoot` for nonstandard Steam installations.

`stop` first requests SteamVR's normal shutdown and waits for a closed-state
postcondition. If the null-driver runtime does not accept that request, inspect
the returned exact process inventory and retry with `stop -Force`. The forced
path validates every target executable is inside `SteamVRRoot` before stopping
it; it does not target Steam, Virtual Desktop, or unrelated same-name binaries.

```powershell
.\Invoke-SteamVRNullControl.ps1 stop -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Force -Compact
```

Run `Test-SteamVRNullControl.ps1` after changing the control contract.
