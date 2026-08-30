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

Run the fixture call and positioning scenario in one orchestration cell using
the installed direct tools. Immediately `store()` each exact response under
run-unique `startup-prepare` and `startup-positioning` keys. Keep each returned
envelope in its local variable for live control; do not call `load()`, compare
object identity, stringify, or otherwise verify the stored copy during startup.
Emit only a compact positioning projection with `notify()`; do not end the
orchestration cell.
Do not create a file, hash, encode, or expand either startup response here;
finalization materializes both stored responses.

Every direct tool result in this cell is one MCP envelope. Decode it exactly
once by requiring `content[0].type: "text"` and applying `JSON.parse` to
`content[0].text`. Do not recursively search the envelope, use
`structuredContent`, or guess another wrapper shape. Preserve the original
envelope with `store()`; use only the decoded object for control decisions.

The first live call is `communityshaders.menu` with exactly
`{"action":"prepare_coc"}`. In its decoded object require top-level
`ready: true`, `persisted: false`, a 64-character producer Build ID, and then
validate readiness and the runtime-only fixture only under `after`: active
Skyrim VR/in-game readiness and VR FPS Stabilizer, debug logging, and FOV/TAA
`0.3/0.3/0.7`. Compare the three `after.foveation` floating-point values with
absolute tolerance `0.000001`. The `before` object is historical evidence;
never validate the fixture from `before`.

Once this first live call returns, any client, orchestration, storage, or
validation error ends this invocation without replaying `prepare_coc`, the
positioning scenario, or any earlier live call. Never correct and restart the
live prefix in place; ask the user to invoke the protocol again.

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

Do not replay a failed or lost positioning scenario. Decode its MCP envelope
once and validate only the fixed scenario paths: the decoded root owns
`ok`/`aborted`/`stepsRun`; each labeled `results[]` entry owns its `result`;
`position-scene.result.cell.editorId` owns exact cell identity;
`position-snapshot.result.snapshot` owns the public snapshot; and
`position-renderscale.result.status.adapter` owns adapter identity. Store the
exact envelope, emit the compact positioning update, and continue in the same
orchestration cell. Do not inspect files, schemas, or alternate paths when one
of these exact projections is absent.

## Live fast path

After positioning, load only [the NVIDIA matrix](references/matrix.v1.json)
with one nested local read inside the still-running orchestration cell. Parse
it in memory and do not emit its contents. Do not read the shared detailed
contract or NVIDIA protocol during startup or between measured rows.

Immediately use the decoded `position-snapshot` as the baseline boundary.
Build the runtime-only DLSS Hoshipa target from its effective profile names,
preserving `dlssProfile`, and set dormant `fsrRuntime: fsr3`. Run one
fail-closed scenario in this order: render-scale `reset`, render-scale `start`,
`qualification_begin`, `qualification_dispatch` with
`startPerformanceTelemetry: false`, public-API `apply`, and strict
`qualification_wait`. Use unique nonempty string owner/client/command IDs, a
numeric transition ID, the exact state revision and Build ID, Dragonsreach,
the `0.3/0.3/0.7` fixture, `persistence: runtime_only`, and the full
dispatch-relative `timeoutMs: 30000`.

On strict baseline success, immediately run one handoff scenario: stop the
exact baseline stress session, start measured stress, reset/start texture
lifetime, reset/start load presentation, and enable the profiler. Then execute
the matrix twice. Keep each complete pass in this same orchestration cell.
Each row scenario starts with the sole 5,000 ms wait, then optional owned DLSS
trace reset/start, `qualification_begin`, transition-1 profiler history clear,
`qualification_dispatch`, public-API `apply`, strict `qualification_wait`, and
optional owned DLSS trace stop. Transition 1 alone sets
`startPerformanceTelemetry: true`. Construct each target from the preceding
terminal waiter's authoritative stable profile and state revision plus the
matrix destination. Store the exact terminal waiter immediately and emit only
a compact projection. Do not pause for model reasoning, read files, write
evidence, hash, or issue a confirmation read between rows.

Continue after a semantic row failure only when the terminal receipt proves
the owner closed, zero active operation, matching PID/Build ID, and no device
loss, OOM, producer terminal failure, or unresolved mutation. Otherwise stop
future mutations and perform only ownership-guarded cleanup. After pass 1,
finalize its owned sessions, take the memory boundary, run the one server-owned
10,000 ms cooldown, establish the fresh pass-2 baseline and owners, and repeat
the unchanged matrix. Only after a pass completes or is interrupted may the
runner read the
[shared detailed contract](../../docs/protocols/renderscale-tuning-fast-start.md)
and [NVIDIA protocol](references/protocol.md) for cumulative evidence,
reporting, cleanup verification, and ledger finalization.

The shared detailed contract and NVIDIA protocol are self-contained. Do
not load or inherit Simple COC or Simple CSM instructions.
Do not execute or alter Simple CSM's 25-step matrix.

The trigger authorizes one positioning COC to `WhiterunDragonsreach`, one
runtime-only baseline apply before each of two passes, and exactly 66 measured
runtime-only profile applies across two identical 33-transition passes through
`communityshaders.upscaling_api`. It does not authorize
a build, deployment, MO2 edit, Stabilizer edit, INI edit, persistence, game
restart, fault injection, another protocol, or any
`communityshaders.renderscale` mutation. VR FPS Stabilizer settings remain
outside this assay.

Require the positioning render-scale status receipt to identify the bound
active adapter as NVIDIA. Validate required output fields only in the
structured producer receipt that owns them. A mismatch or missing core field
is `BLOCKED`. Preserve missing
optional native-presentation generation evidence as a tooling gap; never invent
it.

The installed plugin's direct `mcp__devbench_vr__*` tools are the only permitted
DevBench transport. Do not enumerate the tool catalog or inspect fallback
transports during startup. If a named direct tool is not callable, stop; never
use the bundled controller for this assay.
