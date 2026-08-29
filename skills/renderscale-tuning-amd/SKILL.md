---
name: renderscale-tuning-amd
description: Run the AMD Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning amd, repeating each explicit-FSR4, explicit-FSR3, and FSR4-to-FSR3-fallback 31-transition lane once in the same process with full telemetry. Do not use for NVIDIA, simple csm, or release qualification.
---

# AMD render-scale tuning

Use this skill only for the exact user command `renderscale-tuning amd` or
`renderscale-tuning-amd`. Never infer this GPU lane from inventory alone.

Before the first live call, read only the shared
[fast-start contract](../../docs/protocols/renderscale-tuning-fast-start.md)
completely and follow it through acceptance of the asynchronous positioning
scenario. As soon as its `runId` is accepted, read these files completely while
the server performs the required 10-second settle:

1. [AMD matrix](references/matrix.v1.json)
2. [AMD tuning protocol](references/protocol.md)

The shared startup and AMD protocol are self-contained. Do not load or inherit
Simple COC or Simple CSM instructions. Do not execute or alter Simple CSM's
25-step matrix.

The trigger authorizes one positioning COC to `WhiterunDragonsreach`, one
runtime-only baseline apply before each pass in a runnable lane, and exactly 62
measured runtime-only `communityshaders.upscaling_api` applies across two
identical 31-transition passes per runnable lane. It does not authorize a
build, deployment, MO2 edit, Stabilizer edit, INI edit, persistence, game
restart, unsafe pressure/fault injection, another protocol, or any
`communityshaders.renderscale` mutation. VR FPS Stabilizer settings remain
outside this assay.

Require the shared startup render-scale status receipt to identify the bound
active adapter as AMD. Validate required output fields only in the structured
producer receipt that owns them. A mismatch or missing core field is
`BLOCKED`. Never fabricate FSR4
support or an FSR4-unavailable condition.

The installed plugin's direct `mcp__devbench_vr__*` tools are the only permitted
DevBench transport. Do not enumerate the tool catalog or inspect fallback
transports during startup. If a named direct tool is not callable, stop; never
use the bundled controller for this assay.
