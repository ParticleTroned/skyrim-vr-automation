---
name: renderscale-tuning-amd
description: Run the AMD Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning amd, using separate explicit-FSR4, explicit-FSR3, and FSR4-to-FSR3-fallback 31-transition lanes with full telemetry. Do not use for NVIDIA, simple csm, or release qualification.
---

# AMD render-scale tuning

Use this skill only for the exact user command `renderscale-tuning amd` or
`renderscale-tuning-amd`. Never infer this GPU lane from inventory alone.

Before the first live call, read these files completely in order:

1. [Simple COC skill](../simple-coc/SKILL.md)
2. [Simple COC protocol](../simple-coc/references/protocol.md)
3. [Simple CSM protocol](../simple-csm/references/protocol.md)
4. [AMD matrix](references/matrix.v1.json)
5. [AMD tuning protocol](references/protocol.md)

Reuse Simple CSM only for binding, preparation, Dragonsreach positioning,
five-second pacing, telemetry ownership, evidence preservation, cleanup, and
CSV mechanics. Do not execute or alter its 25-step matrix. This skill's public
API protocol and three 31-entry lanes replace its mutation sequence,
qualification handling, grouping, and verdict rules.

The trigger authorizes one positioning COC to `WhiterunDragonsreach`, one
initial runtime-only profile apply per runnable lane, and exactly 31 measured
runtime-only `communityshaders.upscaling_api` applies per runnable lane. It
does not authorize a
build, deployment, MO2 edit, Stabilizer edit, INI edit, persistence, game
restart, unsafe pressure/fault injection, another protocol, or any
`communityshaders.renderscale` mutation. VR FPS Stabilizer settings remain
outside this assay.

Require the bound active adapter to be AMD and the live public API to expose
every action and field named by the protocol. A mismatch or missing core field
is `BLOCKED`. Never fabricate FSR4 support or an FSR4-unavailable condition.

The installed plugin's direct `mcp__devbench_vr__*` tools are the only permitted
DevBench transport. Search the complete callable tool catalog, including
deferred tools, before declaring them unavailable. Never use the bundled
controller for this assay.
