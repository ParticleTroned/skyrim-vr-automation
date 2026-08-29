---
name: devbench-control
description: "Inspect and call the MCP tools exposed by a running CSX DevBench server through one selected transport. Use for DevBench discovery, capability inspection, structured tool calls, screenshot API probing, performance API probing, or diagnosing runtime metadata and session failures."
---

# DevBench Control

Choose exactly one live transport before the first live call. When the
plugin-provided direct MCP tools are callable, they are the mandatory and
exclusive lane for live discovery, calls, waits, screenshots, and performance
capture. Treat their exposed tool descriptions as the live schema inventory;
do not run the bundled controller's `list`, open another loopback MCP session,
or switch transport lanes during that run.

Use the bundled client as the sole live lane only when direct MCP is unavailable
before the first live call. It also remains available for offline validation or
a required durable receipt that direct MCP cannot expose. Never choose the
loopback HTTP path merely for convenience, mix it with a healthy direct lane,
or construct HTTP or MCP requests ad hoc.

## Contract

1. Read `../../tools/devbench-control/README.md` completely before the first
   bundled-controller call or offline validation. A direct-only live run does
   not need that controller reference.
2. State in commentary that this skill governs the DevBench interaction.
3. On the controller fallback lane, obtain runtime discovery from explicit
   `-RuntimePath` or `CSX_DEVBENCH_RUNTIME_PATH`. Never search an arbitrary MO2
   tree for a plausible runtime file or fall back to another endpoint. On the
   direct lane, use its bound tools and do not create or resolve a controller
   runtime file.
4. On the direct lane, use the exposed direct tool definitions as authoritative
   schema inventory. On the bundled-controller fallback lane, call `list` before
   using a tool whose current name or input schema has not been established.
5. On the direct lane, call the exact exposed tool with structured arguments.
   On the controller fallback lane, use
   `call -Tool <exact-name> -ArgumentsJson <json>`. Parse the structured result
   and preserve errors as evidence; never infer success from a visible in-game
   effect alone.
6. Keep runtime identity verification enabled. Supply build/artifact
   expectations when testing a newly deployed DLL, and use `-RequireSuccess`
   when a semantic failure must fail the orchestration step.
7. On the controller fallback lane, prefer
   `wait -Condition noBlockingMenu` over the server `noMenu` condition when
   Skyrim's permanent HUD is open.
8. Keep readiness recovery on the selected lane. On the direct lane, repeat
   only the unresolved read-only health or action call within its explicit
   bounded deadline and return on its first success. On the controller fallback
   lane, use `wait -Condition toolAvailable -Tool <exact-name>` or
   `serviceReady` with a read-only `-ArgumentsJson` action and an explicit
   bounded timeout. Never cross transports to perform a readiness wait.
9. On the controller fallback lane, use `-ExpectedErrorCode` for deliberate
   guard tests such as `producer_mismatch`; do not reinterpret an unrequested
   API failure as a pass on either lane.
10. Preserve the controller's `sessionCleanup` receipt with the command result.
   Cleanup is successful when it reports `closed`, `already_absent`, or
   `not_opened`; a cleanup failure is diagnostic and never changes the primary
   operation result.
11. If direct health succeeds but a redundant controller attempt returns a
    transport error, preserve that receipt as a runner-path anomaly. Continue
    on the already-selected direct lane; do not start a controller availability
    wait or classify the live DevBench service as unavailable.

The bundled fallback entry point is:

```text
../../tools/devbench-control/Invoke-DevBenchControl.ps1
```

Both DevBench transports are loopback-only but can still mutate a running CSX
session.
Inspection or diagnosis does not authorize state changes. Keep screenshot,
capture, or profiling receipts with the associated MO2 session evidence.

For offline render-scale evidence, use the shared module normalizers for both
resource publication and `status.preparation`. The preparation normalizer keeps
the raw bounded events and exposes every stage summary; never rebuild producer
dimensions, outcomes, reasons, or durations from adjacent fields.
