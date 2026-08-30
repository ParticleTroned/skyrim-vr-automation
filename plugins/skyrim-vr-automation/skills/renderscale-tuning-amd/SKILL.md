---
name: renderscale-tuning-amd
description: Run the AMD Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning amd, repeating each explicit-FSR4, explicit-FSR3, and FSR4-to-FSR3-fallback 31-transition lane once in the same process with full telemetry. Do not use for NVIDIA, simple csm, or release qualification.
---

# AMD render-scale tuning

Use this skill only for the exact user command `renderscale-tuning amd` or
`renderscale-tuning-amd`. Never infer this GPU lane from inventory alone.

## Immediate positioning

Use only the named direct `mcp__devbench_vr__*` tools. Do not read a reference,
run a local command, create evidence, enumerate tools, or inspect a fallback
before positioning.

Run the fixture call and positioning scenario in one orchestration cell using
the installed direct tools. Immediately `store()` each exact response under
run-unique `startup-prepare` and `startup-positioning` keys and verify both keys
with `load()` in memory. Return only a compact positioning projection to chat.
Do not create a file, hash, encode, or expand either startup response here;
finalization materializes both stored responses.

The first live call is `communityshaders.menu` with exactly
`{"action":"prepare_coc"}`. Require `ready: true`, `persisted: false`, a
64-character producer Build ID, active Skyrim VR/in-game readiness and VR FPS
Stabilizer, debug logging, and runtime-only FOV/TAA `0.3/0.3/0.7`. Compare the
three floating-point fixture values with absolute tolerance `0.000001`.

Immediately submit the following synchronous scenario, replacing only
`<bound-build-id>` with that producer Build ID. Do not insert commentary,
another call, or local work between the fixture and this request.

```json
{
  "action": "run",
  "async": false,
  "continueOnError": false,
  "steps": [
    {
      "label": "position-coc",
      "tool": "console",
      "args": {
        "action": "exec",
        "command": "coc WhiterunDragonsreach"
      }
    },
    { "label": "position-settle", "wait": 10000 },
    {
      "label": "position-health",
      "tool": "inspect",
      "args": { "kind": "health" }
    },
    {
      "label": "position-state",
      "tool": "inspect",
      "args": { "kind": "state" }
    },
    {
      "label": "position-scene",
      "tool": "inspect",
      "args": { "kind": "scene" }
    },
    {
      "label": "position-capabilities",
      "tool": "communityshaders.upscaling_api",
      "args": {
        "action": "capabilities",
        "expectedBuildId": "<bound-build-id>"
      }
    },
    {
      "label": "position-snapshot",
      "tool": "communityshaders.upscaling_api",
      "args": {
        "action": "snapshot",
        "expectedBuildId": "<bound-build-id>"
      }
    },
    {
      "label": "position-renderscale",
      "tool": "communityshaders.renderscale",
      "args": {
        "action": "status",
        "expectedBuildId": "<bound-build-id>"
      }
    }
  ]
}
```

Do not replay a failed or lost positioning scenario. After its response is
stored, report positioning immediately. Then read the
[shared post-position contract](../../docs/protocols/renderscale-tuning-fast-start.md),
[AMD matrix](references/matrix.v1.json), and
[AMD tuning protocol](references/protocol.md) completely in one local read
action and continue without a model pause.

The shared post-position contract and AMD protocol are self-contained. Do not
load or inherit Simple COC or Simple CSM instructions.
Do not execute or alter Simple CSM's 25-step matrix.

The trigger authorizes one positioning COC to `WhiterunDragonsreach`, one
runtime-only baseline apply before each pass in a runnable lane, and exactly 62
measured runtime-only `communityshaders.upscaling_api` applies across two
identical 31-transition passes per runnable lane. It does not authorize a
build, deployment, MO2 edit, Stabilizer edit, INI edit, persistence, game
restart, unsafe pressure/fault injection, another protocol, or any
`communityshaders.renderscale` mutation. VR FPS Stabilizer settings remain
outside this assay.

Require the positioning render-scale status receipt to identify the bound
active adapter as AMD. Validate required output fields only in the structured
producer receipt that owns them. A mismatch or missing core field is
`BLOCKED`. Never fabricate FSR4
support or an FSR4-unavailable condition.

The installed plugin's direct `mcp__devbench_vr__*` tools are the only permitted
DevBench transport. Do not enumerate the tool catalog or inspect fallback
transports during startup. If a named direct tool is not callable, stop; never
use the bundled controller for this assay.
