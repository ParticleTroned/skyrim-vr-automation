---
name: renderscale-tuning-nvidia
description: Run the NVIDIA Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning nvidia, repeating the exact 33-transition None, TAA, DLAA, DLSS, and FSR3 matrix once in the same process with full telemetry. Do not use for AMD, simple csm, or release qualification.
---

# NVIDIA render-scale tuning

Use only for exact command `renderscale-tuning nvidia` or
`renderscale-tuning-nvidia`. Never infer this lane from inventory.

## Immediate positioning

Apart from reading this SKILL, use named direct `mcp__devbench_vr__*`
tools. Before positioning, do not read references, run other local commands,
create evidence, enumerate tools, or inspect fallbacks.

After the required skill announcement, use one `functions.exec` with nested
direct tools: first `mcp__devbench_vr__communityshaders_menu` with exactly
`{"action":"prepare_coc"}`, then `mcp__devbench_vr__scenario`. Never call
Scenario first or issue either as a standalone tool.
Store the exact envelopes under run-unique `startup-prepare` and
`startup-positioning` keys, but control from the local responses. Do not call
`load()`, compare object identity, stringify, or create evidence during startup;
finalization materializes both stored responses.

Decode each envelope once from `content[0].type: "text"` with `JSON.parse` of
`content[0].text`. Admit `prepare_coc` only from these exact paths: top-level
`ready: true`, `persisted: false`, 64-character `producer.buildId`;
`after.ready`, `after.vr`, `after.inGame`,
`after.vrFpsStabilizer.activeForSession`, `after.developerMode.active`,
`after.foveation.ready`, `after.foveation.foveatedVendorDispatch`, and
`after.foveation.peripheryTAAEnable` all `true`; and
`after.developerMode.logLevel: "debug"`. Require `after.foveation` values
`foveatedCenterArea: 0.3`, `peripheryTAACenterArea: 0.3`, and
`peripheryTAAOuterScale: 0.7` within `0.000001`. No other `before` or `after`
field gates admission; do not infer aliases. After any live-call error, stop;
never correct, restart, or replay the live prefix.

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

Require `ok:true`,`aborted:false`,`stepsRun:8`; 7 tool entries have
label/`.result`; wait `results[1]` has `kind:"wait"`/`ms:10000` and no
label/result; cell/snapshot/adapter at `position-scene.result.cell.editorId`,
`position-snapshot.result.snapshot`,
`position-renderscale.result.status.adapter`. Emit compact `notify()`.

## Post-position handoff

After positioning, read the [NVIDIA live path](references/live-fast-path.md)
and [matrix](references/matrix.v1.json) together. This sole post-COC model
handoff interprets actionable prose; never expect a code block or local runner.
Compile the next `functions.exec` to own baseline and uninterrupted measurement.
Read the detailed contract and NVIDIA protocol only at pass finalization.

Scope is one positioning COC, two runtime-only baselines, and exactly 66
measured runtime-only `communityshaders.upscaling_api` applies. Never load/run
Simple COC/CSM or alter Simple CSM's 25-step matrix. It does not authorize a
build, deployment, MO2/Stabilizer/INI edit, persistence, restart, fault
injection, another protocol, or render-scale mutation. VR FPS Stabilizer stays
outside this assay.

Require the structured positioning receipt's bound adapter to be NVIDIA;
missing core fields are `BLOCKED`, while missing optional native-generation
evidence is a tooling gap. Direct `mcp__devbench_vr__*` tools are the only
permitted transport. Do not enumerate tools or inspect fallbacks; if a named
tool is not callable, stop and never use the bundled controller.
