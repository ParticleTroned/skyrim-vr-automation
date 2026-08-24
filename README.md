# Skyrim VR Automation Toolkit

This repository provides external PowerShell automation for repeatable Skyrim
VR development and testing. The controls cover Mod Organizer 2, SteamVR's null
HMD, profile transactions, and reusable compiled shader-cache management. CSX DevBench is an
optional integration rather than the identity or boundary of the toolkit.

## Included tools

- `tools/modlist-control` — fail-closed registration and persistent selection
  of exact named MO2 machine configurations.

- `tools/doctor` — configuration discovery, environment validation, and
  non-overwriting initialization of the stable per-user MO2 config.
- `tools/feedback-control` — durable local reporter/maintainer feedback with
  atomic receipts, lifecycle events, deduplication hints, and explicit
  sanitized export.
- `tools/mo2-control` — exact-profile MO2 inspection, cooperative cross-task
  access leases, and a bounded single-owner launch lifecycle.
- `tools/mo2-profile-control` — transactional toggling of an exact MO2
  `modlist.txt` marker and guarded registration of a newly deployed mod.
- `tools/mo2-workspace-control` — unique task profiles cloned from an explicit
  stable source, with empty saves and strict ownership of newly created mods.
- `tools/steamvr-null-control` — transactional null-HMD apply/restore and
  bounded SteamVR shutdown.
- `tools/devbench-control` — a small MCP client for the DevBench endpoint
  exposed by a running CSX build, with listener/process/build/artifact binding
  and normalized semantic results.
- `tools/profiler-control` — repeatable DevBench profiler capture and
  multi-state comparison reports.
- `tools/shader-cache-control` — provider discovery, physical cache
  snapshot/restore transactions, compatibility-ranked known-working cache
  catalogs, task seeding/restoration/promotion, and comparison reports.
- `tools/process-control` — bounded exact-process execution with classified,
  evidence-backed retries for known transient failures.
- `tools/build-test-control` — CTest-aware branch testing with a direct-test
  fallback when a configured build contains test binaries but registers none.

The preserved null-HMD profile is `profiles/steamvr-null.profile.json`.

## Codex plugin

The repository publishes a Codex marketplace plugin. Its six skills connect a
new task to the bundled implementations and their operational contracts:

- `$feedback-control` records unexpected automation behaviour and concrete
  enhancement requests in a durable local queue; it never publishes them.
- `$mo2-control` routes MO2 inspection, exact-profile lifecycle management,
  and transactional profile edits.
- `$steamvr-null-hmd` routes backed-up SteamVR null-HMD apply/restore and
  bounded runtime shutdown.
- `$devbench-control` discovers and calls the exact loopback DevBench MCP API.
- `$profiler-control` captures bounded GPU/CPU timer evidence and compares runs.
- `$shader-cache-control` prepares tasks from compatible known-working compiled
  caches, restores prior state, promotes verified results, and compares trees
  by SHA-256.

Install from the public Git marketplace:

```text
codex plugin marketplace add Treatid2/skyrim-vr-automation --ref main
codex plugin add skyrim-vr-automation@skyrim-vr-tools
```

The reproducible marketplace package lives under
`plugins/skyrim-vr-automation`; canonical sources remain at repository root.
See `docs/INSTALL-CODEX.md` for upgrades, removal, and release pinning. Restart
Codex after installing or updating.

## Local setup

The repository contains no tracked machine paths or credentials. The preferred
MO2 configuration is independent of the checkout or plugin cache. Initialize
it with the bundled doctor:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 init
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 inspect
```

For one MO2 installation, edit
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`. For multiple portable
modlists, register and select exact named configs instead:

```powershell
.\tools\modlist-control\Invoke-SkyrimVRModlist.ps1 register -Name main -ConfigPath C:\staging\main.json
.\tools\modlist-control\Invoke-SkyrimVRModlist.ps1 select -Name main
.\tools\modlist-control\Invoke-SkyrimVRModlist.ps1 list
```

An explicit `-ConfigPath`, `SKYRIM_VR_AUTOMATION_CONFIG`, or
`SKYRIM_VR_AUTOMATION_MODLIST` can override the persisted selection. The
resolver never chooses an arbitrary named config.

DevBench runtime discovery is supplied either explicitly or through an
environment variable:

```powershell
$env:CSX_DEVBENCH_RUNTIME_PATH = 'C:\Path\To\overwrite\SKSE\Plugins\devbench\runtime.json'
.\tools\devbench-control\Invoke-DevBenchControl.ps1 list
```

For SteamVR, pass nonstandard paths with `-SettingsPath` and `-SteamVRRoot`.
The bundled null-HMD profile is resolved relative to the controller script.

The toolkit remains independent of any source tree it exercises.

## Safety model

Run inspection or a dry run before mutation. MO2 commands require exact access,
profile, executable, and session ownership. Each test task uses its own cloned
workspace profile and may remove only mods that its workspace proved were new;
tasks release MO2 access whenever
they can continue without it. Null-HMD apply takes an exact backup and
restore verifies its receipt; profile edits are exact-marker transactions;
cache restoration retains the displaced tree and verifies both sides before
cleanup. Nothing here deletes unclassified MO2 overwrite content or shader
caches.

Unexpected automation behaviour is submitted through `feedback-control`.
Tasks receive a durable `AUTO-...` receipt; only the maintainer triages,
resolves, or deliberately exports a sanitized record. Queue contents stay
local and are never sent to GitHub automatically.

Run the isolated suite with:

```powershell
.\tests\Test-Toolset.ps1
```

Support, privacy, terms, compatibility, clean-install, and release contracts
are documented in the repository root and `docs/`.

The optional MO2 live check is read-only:

```powershell
.\tests\Test-Toolset.ps1 -IncludeLiveMO2
```

## Project status and disclaimer

This is an independent, unofficial community project. It is not affiliated
with or endorsed by Bethesda Game Studios, ZeniMax Media, Valve, Mod Organizer
2, Community Shaders, CSX, or OpenComposite. Product and project names are used
only to identify compatible software; their trademarks belong to their
respective owners.

The tools can modify local MO2 profiles and SteamVR settings. Review the safety
model and keep the generated backups and receipts. The software is provided
without warranty.

## License

Copyright (C) 2026 Treatid2.

This project is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version (`GPL-3.0-or-later`). See
[LICENSE](LICENSE) for the complete terms.
