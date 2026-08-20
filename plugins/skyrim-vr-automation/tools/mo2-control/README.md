# MO2 Control

MO2 Control is the shared, machine-readable entry point for Codex tasks that
inspect or validate the Skyrim VR Mod Organizer 2 installation.

Version `0.3.0` retains the bounded, single-owner lifecycle and adds a tested
retained-MO2 cycle: `stop-game` gracefully closes only the owned game, and a
subsequent `launch` asks the exact still-owned MO2 process to run the registered
executable again. A short-lived command helper is not treated as launch failure
while the game postcondition is still pending. The tool also supports explicit
safe-gated MO2 termination and closed-state lock release. It still does not edit a mod list, clean
overwrite, or move evidence.

## Quick start

From this directory in PowerShell:

```powershell
.\Invoke-MO2Control.ps1 help
.\Invoke-MO2Control.ps1 inspect
.\Invoke-MO2Control.ps1 validate -RequireClosed
.\Invoke-MO2Control.ps1 prepare -Label "null-hmd-baseline" -WhatIf
```

Use `-Compact` for one-line JSON. Override the configured defaults only with an
exact name:

```powershell
.\Invoke-MO2Control.ps1 validate `
  -Profile "Codex" `
  -Executable "Launch MGO - Do Not Unlock" `
  -RequireClosed
```

Exit code `0` means the command completed without a failed check. Exit code `2`
means validation was blocked or the tool itself failed. Warnings do not change
the exit code, but must be reviewed before a state-changing operation.

## Package layout

- `Invoke-MO2Control.ps1` — stable command-line entry point.
- `MO2Control.psm1` — inspection and validation implementation.
- `config/machine.example.json` — portable configuration template.
- `config/machine.local.json` — supported legacy ignored local paths and safety limits.
- `%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json` — preferred stable
  per-user configuration, independent of a checkout or plugin cache version.

Configuration precedence is explicit `-ConfigPath`,
`SKYRIM_VR_AUTOMATION_CONFIG`, the stable per-user path, then the legacy local
file. The result reports the selected source under `data.configuration`.
- `schemas/result.schema.json` — output contract.
- `MO2-RUNBOOK.md` — operating and recovery guidance.
- `tests/Test-MO2Control.ps1` — isolated fixture tests plus optional live checks.
- `sessions/` — reserved for a future single-owner session lock; never a capture
  store.

## Current contract

`inspect` reports:

- configured paths, profiles, exact selected profile, and registered
  executables;
- MO2, game, and VR runtime processes;
- bounded overwrite file count and byte usage;
- active and quarantined RootBuilder JSON state;
- fast D: session staging and L: archive availability;
- session-lock state.

`validate` adds blocking checks for the requested profile and executable,
registered binary and working directory, active RootBuilder JSON, overwrite
safety limits, storage, and (with `-RequireClosed`) MO2/game process state.

Profile fallback is never accepted as success. Quarantined
`*.corrupt-*.json` files are retained evidence and are warnings, not active
RootBuilder failures.

## Session lifecycle

`prepare` requires a closed game/MO2 state, validates one exact profile and
registered executable, creates a durable evidence manifest on staging storage,
and atomically acquires the shared lock. `launch` requires the returned session
identity and uses MO2's supported command line:

```text
ModOrganizer.exe --profile NAME run --executable NAME
```

`status` is bounded and non-mutating. `stop-game` requests normal closure of the
owned game/loader while preserving the exact owner MO2 PID, allowing controlled
relaunches without UI automation. `stop` requests normal window closure for the
whole owned chain and waits for a postcondition; neither command force-terminates. `release` removes only an
exactly owned lock after proving MO2 and the game are closed, while retaining
the evidence directory. All mutation commands have `-WhatIf`. Evidence
collection, archive verification, profile mutation, cache management, and
recovery remain deferred until separately bounded.

The retained cycle is:

```powershell
.\Invoke-MO2Control.ps1 stop-game -SessionId $sessionId
.\Invoke-MO2Control.ps1 launch -SessionId $sessionId
```

Resume is accepted only from a bounded stopped/failure state, with no game
process and exactly one MO2 process matching the session's original owner PID.

`terminate` is intentionally distinct from `stop`: it force-terminates only
MO2 processes owned by the active session, and only after proving that no game
or loader process is running and no RootBuilder `BuildData.json` remains.
