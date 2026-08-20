# Skyrim VR Automation Toolkit

This repository provides external PowerShell automation for repeatable Skyrim
VR development and testing. The controls cover Mod Organizer 2, SteamVR's null
HMD, profile transactions, and shader-cache comparisons. CSX DevBench is an
optional integration rather than the identity or boundary of the toolkit.

## Included tools

- `tools/mo2-control` — exact-profile MO2 inspection and a bounded,
  single-owner launch lifecycle.
- `tools/mo2-profile-control` — transactional toggling of an exact MO2
  `modlist.txt` marker.
- `tools/steamvr-null-control` — transactional null-HMD apply/restore and
  bounded SteamVR shutdown.
- `tools/devbench-control` — a small MCP client for the DevBench endpoint
  exposed by a running CSX build.
- `tools/shader-cache-control` — shader-cache inventory and comparison reports.

The preserved null-HMD profile is `profiles/steamvr-null.profile.json`.

## Local setup

The repository contains no tracked machine paths or credentials. Copy the MO2
example configuration and edit only the ignored local copy:

```powershell
Copy-Item .\tools\mo2-control\config\machine.example.json `
  .\tools\mo2-control\config\machine.local.json
```

DevBench runtime discovery is supplied either explicitly or through an
environment variable:

```powershell
$env:CSX_DEVBENCH_RUNTIME_PATH = 'C:\Path\To\overwrite\SKSE\Plugins\devbench\runtime.json'
.\tools\devbench-control\Invoke-DevBenchControl.ps1 list
```

For SteamVR, pass nonstandard paths with `-SettingsPath` and `-SteamVRRoot`.
The bundled null-HMD profile is resolved relative to the controller script.

For a stable machine-local discovery path, create a directory junction of your
choice that points to the repository, for example:

```text
C:\Tools\skyrim-vr-automation
```

The toolkit remains independent of any source tree it exercises.

## Safety model

Run inspection or a dry run before mutation. MO2 commands require exact profile,
executable, and session ownership; null-HMD apply takes an exact backup and
restore verifies its receipt; profile edits are exact-marker transactions.
Nothing here deletes unclassified MO2 overwrite content or shader caches.

Run the isolated suite with:

```powershell
.\tests\Test-Toolset.ps1
```

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
