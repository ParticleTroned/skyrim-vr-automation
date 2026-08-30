---
name: devbench-control
description: "Inspect and call the MCP tools exposed by a running CSX DevBench server through one selected transport. Use for DevBench discovery, capability inspection, structured tool calls, screenshot API probing, performance API probing, or diagnosing runtime metadata and session failures."
---

# DevBench Control

Choose exactly one live transport before the first live call. When the complete
callable catalog exposes direct `mcp__devbench_vr__` tools, they are the
mandatory and exclusive lane. A generic scenario dispatcher does not prove that
an ownership-bearing or intrusive custom action is callable. If the exact typed
action is absent, report that protocol action unavailable; do not send it
through the dispatcher or switch transports. Use the bundled client as the sole
live lane only when direct MCP is unavailable before the first call. Never
construct HTTP or MCP requests ad hoc.

## Contract

1. Read `../../tools/devbench-control/README.md` completely before the first
   bundled-controller call or offline validation.
2. State in commentary that this skill governs the DevBench interaction.
3. On the bundled lane, obtain runtime discovery from explicit `-RuntimePath`
   or `CSX_DEVBENCH_RUNTIME_PATH`. Never search an arbitrary MO2 tree for a
   plausible runtime file and never fall back to another endpoint. On the
   direct lane, use its bound tools and do not resolve a controller runtime.
4. On the direct lane, use the exposed tool definitions as the authoritative
   action and input-schema inventory. On the bundled lane, call `list` before
   using a tool whose name or schema has not already been established.
5. Call the exact direct tool with structured arguments, or use
   `call -Tool <exact-name> -ArgumentsJson <json>` on the bundled lane. Parse
   the structured result and preserve errors as evidence. Do not infer success
   from a visible in-game effect alone.
6. Keep runtime identity verification enabled. Supply build/artifact
   expectations when testing a newly deployed DLL, and use `-RequireSuccess`
   when a semantic failure must fail a bundled-controller step.
7. On the bundled lane, prefer `wait -Condition noBlockingMenu` over the server
   `noMenu` condition when Skyrim's permanent HUD is open. For a
   controllerless unattended readiness barrier, use
   `-DismissBlockingMenus InventoryMenu -MaxMenuDismissals 1` with
   `-MinimumMenuStableSeconds 5` only when that exact stale menu is expected.
   This recovery is opt-in and must not run as a background monitor.
8. Keep readiness recovery on the selected lane. On the direct lane, repeat
   only the unresolved read-only call within its explicit bounded deadline. On
   the bundled lane, use `wait -Condition toolAvailable -Tool <exact-name>`
   with an explicit timeout and optional `-ProgressLogPath`, or use
   `serviceReady` with a read-only `-ArgumentsJson` action.
9. On the bundled lane, use `-ExpectedErrorCode` for deliberate guard tests
   such as `producer_mismatch`; do not reinterpret an unrequested API failure
   as a pass on either lane.
10. Every timing, frame-rate, CPU, or GPU measurement on the bundled lane must
    pass `-RequirePerformanceNeutral`. The controller queries the registered
    standalone temporal-probe owner and rejects an unproven or changed epoch.
    On the direct lane, apply the equivalent explicit before/after check for
    `performanceDistorted: false`, `physicalStateKnown: true`, and a stable
    ownership epoch. Never disarm the probe unless the user separately
    authorized that mutation.
11. Set `-MaxTransientRetries 0` for ownership-bearing actions. If a response
    is lost, inspect the existing owner on the same lane; never replay the
    action or clean up its evidence prematurely.

The bundled fallback entry point is:

```text
../../tools/devbench-control/Invoke-DevBenchControl.ps1
```

Both DevBench transports are loopback-only but can still mutate a running CSX
session. Inspection or diagnosis does not authorize state changes. Keep
screenshot, capture, or profiling receipts with the associated MO2 session
evidence.
