---
name: renderscale-tuning-amd
description: Run the AMD Skyrim VR public-upscaling-API render-scale tuning assay when the user says renderscale-tuning amd, repeating each explicit-FSR4, explicit-FSR3, and FSR4-to-FSR3-fallback 31-transition lane once in the same process with full telemetry. Do not use for NVIDIA, simple csm, or release qualification.
---

# AMD render-scale tuning

Use only for exact command `renderscale-tuning amd` or
`renderscale-tuning-amd`. Never infer this lane from inventory.

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

Do not replay a failed or lost positioning scenario. Require decoded root
`ok`/`aborted`/`stepsRun`, labeled `results[].result`, exact cell at
`position-scene.result.cell.editorId`, snapshot at
`position-snapshot.result.snapshot`, and adapter at
`position-renderscale.result.status.adapter`. Emit only a compact `notify()`.

## Post-position handoff

Only after positioning, load [the AMD live fast path](references/live-fast-path.md)
and [matrix](references/matrix.v1.json) together in one nested local read inside
the still-running orchestration cell. Do not emit them. Follow the live path
immediately without a model pause. Do not read the shared detailed contract or
AMD protocol during startup or between measured rows.

Do not load Simple COC or Simple CSM instructions. Do not execute or alter
Simple CSM's 25-step matrix. This trigger authorizes
one positioning COC, one runtime-only baseline per pass and runnable lane, and
exactly 62 measured runtime-only `communityshaders.upscaling_api` applies per
runnable lane. It does not authorize a build, deployment, MO2/Stabilizer/INI
edit, persistence, restart, unsafe pressure/fault injection, another protocol,
or render-scale mutation. VR FPS Stabilizer settings remain outside this assay.

Require the structured positioning receipt's bound adapter to be AMD; missing
core fields are `BLOCKED`. Never fabricate FSR4 support or unavailability.
Direct `mcp__devbench_vr__*` tools are the only permitted transport. Do not
enumerate tools or inspect fallbacks; if a named tool is not callable, stop and
never use the bundled controller.
