# Compatibility and boundaries

## PowerShell

PowerShell 7 or later is required. The controllers use modern JSON conversion
features and return structured JSON suitable for another automation layer.

## CSX and DevBench

`devbench-control` is a client, not the in-game server. It expects a running CSX
build to publish `runtime.json` and implement MCP protocol `2025-03-26` on the
loopback interface. The runtime metadata path must be supplied explicitly or by
`CSX_DEVBENCH_RUNTIME_PATH`.

`profiler-control` uses that same runtime contract to collect and compare the
resolved CSX GPU/CPU timer block. Its totals are not whole-frame GPU time.

`coc-stability` requires the server-side render-scale qualification begin,
dispatch-mark, and wait actions. It stops when the exact waiter contract is
unavailable instead of substituting loading-menu checks, client polling, or
fixed delays.

`render-scale-qualification` requires exact CSX runtime/build binding, verifies
any supplied artifact binding, and depends on the server-side render-scale
qualification waiter, the upscaling and feature APIs, and HMD-submission
screenshot sequences. Its frozen protocol includes all five DLSS trace actions
introduced by
`b46edeaed14c41ad41225641c3a4943f1db25db6`: status, reset, start, stop, and
read. A server that does not advertise the full contract fails preflight.
The render-scale status must also expose the live D3D adapter vendor, device,
and driver identity. The runner binds those values to the selected vendor
matrix and fixture manifest, and it never retries an uncertain mutating MCP
call.

## MO2

MO2 Control reads a configuration matching
`tools/mo2-control/config/machine.example.json`. Resolution is deterministic:
explicit `-ConfigPath`, `SKYRIM_VR_AUTOMATION_CONFIG`, the stable per-user
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`, then the legacy ignored
checkout-local file. The selected source is reported and no alternate profile,
executable, or configuration is silently substituted. Isolated tests do not
require a live MO2 installation.

## SteamVR null-HMD

The controller's conventional defaults target a standard Steam installation.
Nonstandard installations must pass `-SettingsPath` and `-SteamVRRoot`. The
null-HMD profile is repository-relative and is therefore portable.

## Deliberate exclusions

This repository does not contain CSX binaries, shaders, compiled shader caches,
MO2 mods, presets, game files, SteamVR settings, runtime secrets, or collected
test evidence. Those remain local operational inputs or outputs.
