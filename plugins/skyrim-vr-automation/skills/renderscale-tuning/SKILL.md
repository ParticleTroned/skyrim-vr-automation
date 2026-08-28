---
name: renderscale-tuning
description: Run the Skyrim VR replacement-admission versus current-presentation correctness assay when the user says renderscale-tuning, using CS-menu-close release and full generation, ownership, mutation, preparation, and stereo telemetry. Do not use for simple csm or release qualification.
---

# Render-scale tuning

Use this skill only for the live protocol triggered by the exact user command
`renderscale-tuning` or the explicit extended command
`renderscale-tuning acceptance`.

Before the first live call, read these files completely in order:

1. [Simple COC skill](../simple-coc/SKILL.md)
2. [Simple COC protocol](../simple-coc/references/protocol.md)
3. [Replacement-admission protocol](references/protocol.md)

Reuse Simple COC's exact producer binding, runtime-only debug/FOV/TAA fixture,
evidence preservation, and task-owned cleanup. The replacement-admission
protocol overrides its initial cell, mutation sequence, telemetry ownership,
qualification timing, result schema, and verdict rules. Never run the Simple
CSM 25-step matrix as part of this skill.

The base trigger authorizes one positioning COC to `WhiterunDragonsreach` and
only the safe menu-close transitions selected by the replacement-admission
matrix. It does not authorize a build, deployment, MO2 edit, Stabilizer edit,
device-loss injection, resource corruption, artificial memory exhaustion,
Skyrim restart, or another protocol. VR FPS Stabilizer remains the sole owner
of its settings.

`renderscale-tuning acceptance` additionally authorizes the existing complete
20-transition render-scale qualification described in the final acceptance
section. Never infer that wider authorization from the base trigger.

Before mutation, require the live tool descriptions and response fields named
by the protocol. Do not calculate, infer, rename, or substitute missing
generation, ownership, mutation, publication, presentation, or timing facts.
A missing core field is `BLOCKED`; a missed bounded interval is
`INCONCLUSIVE`.
