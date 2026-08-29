---
name: renderscale-tuning-nvidia
description: Run the NVIDIA Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning nvidia, using the exact 33-transition None, TAA, DLAA, DLSS, and FSR3 matrix with full telemetry. Do not use for AMD, simple csm, or release qualification.
---

# NVIDIA render-scale tuning

Use this skill only for the exact user command `renderscale-tuning nvidia` or
`renderscale-tuning-nvidia`. Never infer this GPU lane from inventory alone.

Before the first live call, read these files completely in order:

1. [Simple COC skill](../simple-coc/SKILL.md)
2. [Simple COC protocol](../simple-coc/references/protocol.md)
3. [Simple CSM protocol](../simple-csm/references/protocol.md)
4. [NVIDIA matrix](references/matrix.v1.json)
5. [NVIDIA tuning protocol](references/protocol.md)

Reuse Simple CSM only for binding, preparation, Dragonsreach positioning,
five-second pacing, telemetry ownership, evidence preservation, cleanup, and
CSV mechanics. Do not execute or alter its 25-step matrix. This skill's public
API protocol and 33-entry JSON matrix replace its mutation sequence,
qualification handling, grouping, and verdict rules.

The trigger authorizes one positioning COC to `WhiterunDragonsreach`, one
initial runtime-only profile apply, and exactly 33 measured runtime-only
profile applies through `communityshaders.upscaling_api`. It does not authorize
a build, deployment, MO2 edit, Stabilizer edit, INI edit, persistence, game
restart, fault injection, another protocol, or any
`communityshaders.renderscale` mutation. VR FPS Stabilizer settings remain
outside this assay.

Require the bound active adapter to be NVIDIA and the live public API to expose
every action and field named by the protocol. A mismatch or missing core field
is `BLOCKED`. Preserve missing optional native-presentation generation evidence
as a tooling gap; never invent it.

The installed plugin's direct `mcp__devbench_vr__*` tools are the only permitted
DevBench transport. Search the complete callable tool catalog, including
deferred tools, before declaring them unavailable. Never use the bundled
controller for this assay.
