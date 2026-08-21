---
name: devbench-control
description: "Inspect and call the loopback MCP tools exposed by a running CSX DevBench server. Use for DevBench discovery, capability inspection, structured tool calls, screenshot API probing, performance API probing, or diagnosing runtime metadata and session failures."
---

# DevBench Control

Use the bundled client rather than constructing HTTP or MCP requests ad hoc.

## Contract

1. Read `../../tools/devbench-control/README.md` completely before the first
   call. Resolve paths from this installed skill.
2. State in commentary that this skill governs the DevBench interaction.
3. Obtain runtime discovery from explicit `-RuntimePath` or
   `CSX_DEVBENCH_RUNTIME_PATH`. Never search an arbitrary MO2 tree for a
   plausible runtime file and never fall back to another endpoint.
4. Call `list` before using a tool whose current name or input schema has not
   already been established in this run. Treat that response as authoritative.
5. Use `call -Tool <exact-name> -ArgumentsJson <json>`, parse the structured
   result, and preserve errors as evidence. Do not infer success from a visible
   in-game effect alone.
6. Keep runtime identity verification enabled. Supply build/artifact
   expectations when testing a newly deployed DLL, and use `-RequireSuccess`
   when a semantic failure must fail the orchestration step.
7. Prefer client `wait -Condition noBlockingMenu` over the server `noMenu`
   condition when Skyrim's permanent HUD is open.

The entry point is:

```text
../../tools/devbench-control/Invoke-DevBenchControl.ps1
```

DevBench calls are loopback-only but can still mutate a running CSX session.
Inspection or diagnosis does not authorize state changes. Keep screenshot,
capture, or profiling receipts with the associated MO2 session evidence.
