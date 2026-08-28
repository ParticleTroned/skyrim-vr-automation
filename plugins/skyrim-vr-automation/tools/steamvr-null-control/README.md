# SteamVR null-HMD control

`Invoke-SteamVRNullControl.ps1` transactionally inspects, applies, starts, and
restores the Valve null-HMD route. Apply always takes an exact settings backup,
and restore requires its hash receipt.

Applying settings is not runtime proof. `start` launches SteamVR and succeeds
only after the current `vrserver` session logs both the Valve null driver load
and `Active HMD set to null.<configured serial>`. `inspect` therefore reports
`null-configured-runtime-stopped` separately from
`null-runtime-active-unqualified`. A qualified start also requires the
`codex_head_pose` provider to load, register its tracked device, acknowledge its
versioned shared-memory state, and appear as a valid standing HMD to the bundled
independent OpenVR probe.

The profile sets `dashboard.enableDashboard=false` so the generic-HMD
laser-mouse/dashboard route cannot be summoned. A resident `vrdashboard.exe`
is retained as process telemetry; its presence alone is not an input-conflict
signal. The controller never edits Valve's bindings and does not invent
controller devices.

Valve's null display driver does not provide the controlled standing pose this
automation requires. The separately installed `codex_head_pose` server driver
supplies one HMD pose and is mapped to `/user/head` with SteamVR
`TrackingOverrides`. Its default eye height is 1.68 metres; the controller can
update the pose through `Local\CSXVRHeadPose-v2`. The returned `inputContract`
marks the HMD pose provider ready only after both driver acknowledgement and an
application-observed OpenVR qualification. Controller input remains
unavailable, replay readiness remains false, and the broader measurement policy
remains fail-closed until its other runtime conflicts are separately qualified.

Before `start`, the controller reads the OpenVR registration file (normally
`%LOCALAPPDATA%\openvr\openvrpaths.vrpath`) and inventories every external
driver manifest with exact paths and hashes. An external driver declaring
`redirectsDisplay=true` conflicts with the forced null display path: `inspect`
returns `external-driver-conflict`, and `start` refuses with the exact driver
inventory. Use `-OpenVRPathsPath` for a nonstandard registration file. This
preflight also refuses startup when a registered driver cannot be classified;
it does not silently mutate or unregister third-party drivers.

For a measurement-qualified transaction with one classified redirector, pass
`-IsolateExternalDisplayRedirectors` to `apply`. The controller backs up and
hashes the exact OpenVR registration file, binds the selected driver root and
manifest hash into the apply receipt, removes only that registration, and
verifies that the remaining inventory is complete and conflict-free. If more
than one redirector is present, name every exact root in the
`-ExternalDisplayRedirectorRoot <root1>,<root2>` array. `start` refuses registration drift;
`restore` refuses to overwrite drift and restores the exact pre-apply bytes only
when the isolated-state hash and suppressed manifests still match the receipt.
The normal fail-closed path remains unchanged when this option is omitted.

Apply and restore are recoverable multi-file transactions. Before changing
either SteamVR settings or OpenVR registrations, the controller records each
exact target, preimage, and expected hash in a write-ahead journal. A failed
operation restores and verifies every target before reporting rollback; an
incomplete rollback is reported as `recovery-required`, never as success. The
next apply or restore resolves any nonterminal journal before beginning new
work, and a repeated restore recognizes a committed exact baseline as
`already-restored`.

For a specifically authorized coexistence diagnostic, `start
-AllowExternalDisplayRedirector` leaves every vendor registration untouched,
records the exact conflict inventory and override in the runtime receipt, and
keeps the resulting null-HMD route unqualified. It is not a compatibility or
measurement-readiness claim.

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

Runtime qualification invokes the independent OpenVR pose probe through the
central bounded-process controller. A probe cannot outlive its timeout. If a
start or qualification attempt fails, cleanup stops only SteamVR-root-owned
processes whose creation time belongs to that attempt and reports the verified
survivor inventory.

```powershell
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 apply -EvidenceDirectory <session-evidence> -IsolateExternalDisplayRedirectors -Compact
.\Invoke-SteamVRNullControl.ps1 start -EvidenceDirectory <session-evidence> -Compact
.\Invoke-SteamVRNullControl.ps1 inspect -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Compact
.\Invoke-SteamVRNullControl.ps1 stop -Force -Compact
.\Invoke-SteamVRNullControl.ps1 restore -EvidenceDirectory <session-evidence> -Compact
```

Install and independently qualify the provider through
`../steamvr-head-pose-control/Invoke-SteamVRHeadPoseControl.ps1`. Installation
requires SteamVR to be closed and uses the bundled native package by default.

Launch Skyrim only after `start` or `inspect` returns current-session runtime
proof, and do not interpret the `-unqualified` state as replay or measurement
readiness. Also use an MO2 profile that disables OpenComposite; a running null
SteamVR instance does not prove an application bypassing SteamVR is attached to
it.

Run `Test-SteamVRNullControl.ps1` after changing the control contract.
