---
name: renderscale-tuning-nvidia
description: Run the NVIDIA Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning nvidia, repeating the exact 33-transition None, TAA, DLAA, DLSS, and FSR3 matrix once in the same process with full telemetry. Do not use for AMD, simple csm, or release qualification.
---

# NVIDIA render-scale tuning

Use this skill only for the exact user command `renderscale-tuning nvidia` or
`renderscale-tuning-nvidia`. Never infer this GPU lane from inventory alone.

Before the first live call, read only the shared
[fast-start contract](../../docs/protocols/renderscale-tuning-fast-start.md)
completely and follow it through acceptance of the asynchronous positioning
scenario. As soon as its `runId` is accepted, read these files completely while
the server performs the required 10-second settle:

1. [NVIDIA matrix](references/matrix.v1.json)
2. [NVIDIA tuning protocol](references/protocol.md)

The shared startup and NVIDIA protocol are self-contained. Do not load or
inherit Simple COC or Simple CSM instructions. Do not execute or alter Simple
CSM's 25-step matrix.

The trigger authorizes one positioning COC to `WhiterunDragonsreach`, one
runtime-only baseline apply before each of two passes, and exactly 66 measured
runtime-only profile applies across two identical 33-transition passes through
`communityshaders.upscaling_api`. It does not authorize
a build, deployment, MO2 edit, Stabilizer edit, INI edit, persistence, game
restart, fault injection, another protocol, or any
`communityshaders.renderscale` mutation. VR FPS Stabilizer settings remain
outside this assay.

Require the shared startup render-scale status receipt to identify the bound
active adapter as NVIDIA. Tool descriptions prove callable actions and inputs;
validate required output fields only in the structured producer receipt that
owns them. A mismatch or missing core field is `BLOCKED`. Preserve missing
optional native-presentation generation evidence as a tooling gap; never invent
it.

The installed plugin's direct `mcp__devbench_vr__*` tools are the only permitted
DevBench transport. Search the complete callable tool catalog, including
deferred tools, before declaring them unavailable. Never use the bundled
controller for this assay.
