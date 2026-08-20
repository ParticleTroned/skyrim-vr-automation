# Compatibility and boundaries

## PowerShell

PowerShell 7 or later is required. The controllers use modern JSON conversion
features and return structured JSON suitable for another automation layer.

## CSX and DevBench

`devbench-control` is a client, not the in-game server. It expects a running CSX
build to publish `runtime.json` and implement MCP protocol `2025-03-26` on the
loopback interface. The runtime metadata path must be supplied explicitly or by
`CSX_DEVBENCH_RUNTIME_PATH`.

## MO2

MO2 Control reads a local configuration matching
`tools/mo2-control/config/machine.example.json`. It uses the exact configured
profile and registered executable and refuses profile fallback. Its isolated
tests do not require a live MO2 installation.

## SteamVR null-HMD

The controller's conventional defaults target a standard Steam installation.
Nonstandard installations must pass `-SettingsPath` and `-SteamVRRoot`. The
null-HMD profile is repository-relative and is therefore portable.

## Deliberate exclusions

This repository does not contain CSX binaries, shaders, compiled shader caches,
MO2 mods, presets, game files, SteamVR settings, runtime secrets, or collected
test evidence. Those remain local operational inputs or outputs.
