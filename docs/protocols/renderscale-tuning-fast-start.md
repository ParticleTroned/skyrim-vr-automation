# Render-scale tuning post-position contract

This contract starts only after the NVIDIA or AMD skill's synchronous
Dragonsreach positioning scenario returns. The vendor `SKILL.md` owns the
runtime fixture and positioning request so no reference-file read or local
evidence action can delay the COC.

## Validate the one positioning response

Require top-level `ok: true`, `aborted: false`, and `stepsRun: 8`. Use the
labeled results already returned by that scenario; do not issue confirmation
reads. Require:

- `position-health`: one live `SkyrimVR.exe` PID with `vr: true`;
- `position-state` and `position-scene`: a loaded player in exact
  `WhiterunDragonsreach`;
- `position-capabilities`: success, the fixture's exact producer/Build ID, and
  every method, quality, and runtime required by the selected matrix;
- `position-snapshot`: the same Build ID, a complete authoritative public
  snapshot, and no active operation;
- `position-renderscale`: the same Build ID, no terminal or unresolved
  physical failure, an available adapter, and vendor ID `0x10DE`/4318 for
  NVIDIA or `0x1002`/4098 for AMD.

The synchronous response is the positioning observation. Report positioning
as soon as it returns; do not create an evidence directory, convert JSON,
decode Base64, hash files, or read another reference first. A failed scenario
or required field stops without replaying the COC.

Then read the selected matrix, vendor protocol, and this contract completely
in one local read action. Do not load Simple COC or Simple CSM instructions,
enumerate tools, inspect schemas, or run another admission/reset scenario.

Keep the exact `prepare_coc` and positioning responses in context when the
client retains them, but they are not measurement evidence. Never replay a
startup call, stop a measured run, or delay transition 1 because either startup
response expired from the client response store. Record
`startup_receipts_not_retained` as a non-blocking evidence anomaly and continue.
Write retained startup responses only during finalization; failure to preserve
them is not a render, control, or assay failure.

Every later mutation and ownership scenario remains synchronous with
`async: false` and `continueOnError: false`.

## Baseline and measured ownership

Reuse the post-position public snapshot and its exact `stateRevision` when it
is complete, has no active operation, and still matches the bound Build ID.

From this point until transition 1 has been dispatched, do not run a local
command, create an evidence directory, locate a ledger, hash or serialize a
receipt, search documentation or source, inspect a tool schema, or prepare a
report. The only permitted work is to materialize the values already returned,
run the baseline scenario, run the handoff scenario, and begin transition 1's
prescribed 5,000 ms settle. The ledger path is the repository-relative
`docs/development/vr-render-scale-comparison-ledger.csv`; never search for it.

Use these fixed substitutions without discovery:

- `B`: exact bound Build ID;
- `R`: post-position `stateRevision`;
- `T` and `O`: new nonzero transition ID and unique owner ID;
- `C` and `K`: unique client and command IDs;
- `P`: complete string-valued API profile described by the vendor protocol;
- `Q`: the same profile with numeric quality (`native_aa=0`, `hoshipa=1`,
  `ultra_quality=2`, `quality=3`, `balanced=4`, `performance=5`,
  `ultra_performance=6`);
- `F`: exactly `{ "foveatedVendorDispatch": true,
  "foveatedCenterArea": 0.3, "peripheryTAAEnable": true,
  "peripheryTAACenterArea": 0.3, "peripheryTAAOuterScale": 0.7 }`.

The six baseline scenario steps have these complete tool/argument shapes; add
no field and perform no lookup:

| Label | Tool | Arguments |
| --- | --- | --- |
| `baseline-stress-reset` | `communityshaders.renderscale` | `{"action":"reset","expectedBuildId":"B"}` |
| `baseline-stress-start` | `communityshaders.renderscale` | `{"action":"start","expectedBuildId":"B"}` |
| `qualification-begin` | `communityshaders.renderscale` | `{"action":"qualification_begin","transitionId":T,"ownerId":"O","expectedBuildId":"B"}` |
| `qualification-dispatch` | `communityshaders.renderscale` | `{"action":"qualification_dispatch","transitionId":T,"ownerId":"O","startPerformanceTelemetry":false,"expectedBuildId":"B"}` |
| `profile-apply` | `communityshaders.upscaling_api` | `{"action":"apply","expectedBuildId":"B","expectedStateRevision":R,"target":P,"purpose":"direct","persistence":"runtime_only","clientId":"C","commandId":"K","reason":"render-scale tuning baseline"}` |
| `qualification-wait` | `communityshaders.renderscale` | `{"action":"qualification_wait","transitionId":T,"ownerId":"O","expectedCellEditorId":"WhiterunDragonsreach","timeoutMs":30000,"milestone":"strict","target":Q,"foveation":F,"expectedBuildId":"B"}` |

Start the baseline with one synchronous fail-closed scenario containing six
labeled tool steps in this exact order: `baseline-stress-reset`,
`baseline-stress-start`, `qualification-begin`, `qualification-dispatch`,
`profile-apply`, and `qualification-wait`. This is the only pre-baseline reset.
The apply immediately follows dispatch, and the strict target-correlated waiter
immediately follows apply inside the same server-owned scenario. Pass the full
dispatch-relative `timeoutMs: 30000`; DevBench measures it from
`qualification_dispatch`. Never calculate or pass a client-side remaining
timeout. Do not inspect, validate, persist, or comment on the scenario response
until the server has executed the waiter and returned the complete six-step
transcript.

After the scenario returns, read only its fixed wrapper shape. Require
top-level `ok: true`, `aborted: false`, and `stepsRun: 6`. The apply receipt is
`results[]` entry `label: profile-apply`, under `result.apply`; its disposition
is `result.apply.disposition.name`. The waiter receipt is the unique entry
`label: qualification-wait`, under `result`, with
`result.action: qualification_wait`. Never search another wrapper location or
run another waiter because a client-side field lookup failed.

If the containing scenario response is lost or cannot be decoded, do not replay
the scenario, apply, or waiter. Before writing evidence, reporting feedback,
cancelling, cleaning up, or pausing for commentary, read
`qualification_status` once with the exact `expectedBuildId`, then validate its
returned ownership pair. For the exact active owner in `dispatched` or
`waiting`, allow the already-running server scenario to reach the original
deadline and recover matching terminal `lastEvidence`; do not call
`qualification_wait` independently. If the owner is inactive and matching
`lastEvidence` is present, use it as the terminal waiter receipt. Allow at most
five additional seconds only to retrieve already-terminal evidence. Any
different owner, transition, Build ID, or missing terminal evidence after that
bound stops future mutations and asks the user. Never reapply the profile or
create a second measurement window. Record the client error only after the
qualification owner is terminal. This owner-correlated recovery rule applies
to every baseline and measured waiter in both vendor assays.

The terminal baseline waiter receipt is the first authoritative output-contract
proof. Require its independent `milestoneTimings` and `replacementTimeline`
objects. If either object is absent, record `plugin_contract_outdated`, preserve
the receipt, stop the baseline stress session with its ownership guard, and
stop before measured-owner handoff or transition 1. Never infer either object
from a tool description or later status snapshot.

Only after strict waiter success and that receipt check, continue without a
model pause into one synchronous fail-closed handoff scenario to stop the
baseline stress session with its exact ownership guard, start measured stress,
reset then start texture-lifetime, reset then start load-presentation, and
pre-arm the profiler with `set_enabled`. The baseline session guard is the
positive integer at the `baseline-stress-start` result's
`result.status.session.id`. Use exactly these handoff steps, replacing `S`,
`C`, and `K` with that session ID and unique profiler command IDs:

| Label | Tool | Arguments |
| --- | --- | --- |
| `baseline-stress-stop` | `communityshaders.renderscale` | `{"action":"stop","expectedSessionId":S,"expectedBuildId":"B"}` |
| `measured-stress-start` | `communityshaders.renderscale` | `{"action":"start","expectedBuildId":"B"}` |
| `texture-lifetime-reset` | `communityshaders.renderscale` | `{"action":"texture_lifetime_reset","expectedBuildId":"B"}` |
| `texture-lifetime-start` | `communityshaders.renderscale` | `{"action":"texture_lifetime_start","expectedBuildId":"B"}` |
| `load-presentation-reset` | `communityshaders.renderscale` | `{"action":"probe_reset","expectedBuildId":"B"}` |
| `load-presentation-start` | `communityshaders.renderscale` | `{"action":"probe_start","expectedBuildId":"B"}` |
| `profiler-enable` | `communityshaders.profiler_api` | `{"contractMajor":1,"clientId":"C","commandId":"K","action":"set_enabled","enabled":true,"expectedBuildId":"B"}` |

Do not clear profiler history here. Transition 1 inserts exactly
`{"contractMajor":1,"clientId":"C","commandId":"K","action":"clear_history","expectedBuildId":"B"}`
as a `communityshaders.profiler_api` step immediately before
`qualification_dispatch`; use new client/command IDs and do not use
`start_capture` or invent `frameCount`. Transition 1's
`qualification_dispatch` is the sole CPU/GPU reset/start and timing origin.
Immediately begin transition 1's 5,000 ms settling scenario after the handoff
returns. Retain every owner receipt. A failed or
unsatisfied baseline waiter, a missing waiter subreceipt, or an incomplete
scenario must never invoke this handoff scenario because it contains measured
owner start actions. The handoff scenario is never a cleanup path. Stop only
the baseline stress session with one
ownership-guarded `stop` call, start no measured owner, and follow the lane's
terminal failure rules.
