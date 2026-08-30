---
name: renderscale-tuning-nvidia
description: Run the NVIDIA Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning nvidia, repeating the exact 33-transition None, TAA, DLAA, DLSS, and FSR3 matrix once in the same process with full telemetry. Do not use for AMD, simple csm, or release qualification.
---

# NVIDIA render-scale tuning

Use this skill only for the exact user command `renderscale-tuning nvidia` or
`renderscale-tuning-nvidia`. Never infer this GPU lane from inventory alone.

## Immediate positioning

Use only the named direct `mcp__devbench_vr__*` tools. Do not read a reference,
run a local command, create evidence, enumerate tools, or inspect a fallback
before positioning.

The first live call is `mcp__devbench_vr__communityshaders_menu` with exactly
`{"action":"prepare_coc"}`. Make it immediately, without commentary or local
work, and keep it with `mcp__devbench_vr__scenario` in one orchestration cell.
Store the exact envelopes under run-unique `startup-prepare` and
`startup-positioning` keys, but control from the local responses. Do not call
`load()`, compare object identity, stringify, or create evidence during startup;
finalization materializes both stored responses.

Decode each envelope once from `content[0].type: "text"` with `JSON.parse` of
`content[0].text`. Require `prepare_coc` top-level `ready: true`,
`persisted: false`, a 64-character producer Build ID, and only its `after`
readiness, Stabilizer, and debug state. Verify the `after.foveation` FOV/TAA
`0.3/0.3/0.7` fixture within
`0.000001`. Never validate the fixture from `before`. After any live call, an
error stops the invocation; never correct and restart or replay the live prefix.

Immediately submit the following synchronous scenario, replacing only
`<bound-build-id>` with that producer Build ID. Do not insert commentary,
another call, or local work between the fixture and this request.

```json
{"action":"run","async":false,"continueOnError":false,"steps":[
  {"label":"position-coc","tool":"console","args":{"action":"exec","command":"coc WhiterunDragonsreach"}},
  {"label":"position-settle","wait":10000},
  {"label":"position-health","tool":"inspect","args":{"kind":"health"}},
  {"label":"position-state","tool":"inspect","args":{"kind":"state"}},
  {"label":"position-scene","tool":"inspect","args":{"kind":"scene"}},
  {"label":"position-capabilities","tool":"communityshaders.upscaling_api","args":{"action":"capabilities","expectedBuildId":"<bound-build-id>"}},
  {"label":"position-snapshot","tool":"communityshaders.upscaling_api","args":{"action":"snapshot","expectedBuildId":"<bound-build-id>"}},
  {"label":"position-renderscale","tool":"communityshaders.renderscale","args":{"action":"status","expectedBuildId":"<bound-build-id>"}}
]}
```

Do not replay a failed or lost positioning scenario. Require decoded root
`ok`/`aborted`/`stepsRun`, labeled `results[].result`, exact cell at
`position-scene.result.cell.editorId`, snapshot at
`position-snapshot.result.snapshot`, and adapter at
`position-renderscale.result.status.adapter`. Emit only a compact `notify()`.

## Post-position handoff

Only after positioning, load [the NVIDIA live fast path](references/live-fast-path.md)
and [matrix](references/matrix.v1.json) together in one nested local read inside
the still-running orchestration cell. Do not emit them. Follow the live path
immediately without a model pause. Do not read the shared detailed contract or
NVIDIA protocol during startup or between measured rows.

Do not load Simple COC or Simple CSM instructions. Do not execute or alter
Simple CSM's 25-step matrix. This trigger authorizes
one positioning COC, two runtime-only baselines, and exactly 66 measured
runtime-only `communityshaders.upscaling_api` applies. It does not authorize a
build, deployment, MO2/Stabilizer/INI edit, persistence, restart, fault
injection, another protocol, or render-scale mutation. VR FPS Stabilizer
settings remain outside this assay.

Require the structured positioning receipt's bound adapter to be NVIDIA;
missing core fields are `BLOCKED`, while missing optional native-generation
evidence is a tooling gap. Direct `mcp__devbench_vr__*` tools are the only
permitted transport. Do not enumerate tools or inspect fallbacks; if a named
tool is not callable, stop and never use the bundled controller.
