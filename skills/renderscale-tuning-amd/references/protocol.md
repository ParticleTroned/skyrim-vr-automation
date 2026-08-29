# AMD render-scale tuning protocol

This is the AMD public-API correctness and measurement assay. It runs three
separate backend lanes and never runs the Simple CSM matrix or mutates a
profile through `communityshaders.renderscale`.

## 1. Bind and prepare

Apply Simple COC identity binding, core control discovery, evidence paths, and
the single runtime-only `prepare_coc` action. The receipt must prove debug
logging and the FOV/TAA `0.3/0.3/0.7` fixture without changing any upscaling
or VR FPS Stabilizer setting.
Select exactly one live DevBench transport lane before the first live call. If
plugin-provided direct MCP tools are callable, use them exclusively for every
AMD lane baseline, transition, evidence read, and guarded cleanup. Treat direct
MCP tool descriptions as the schema inventory; do not open the bundled
controller, run its `list`, or start its availability waits. The bundled
controller may be the sole live lane only if direct MCP was unavailable before
the run. Never switch or mix transport lanes.

If direct health succeeds while a redundant controller attempt returns a
transport error, retain that receipt as a runner-path anomaly and continue on
the direct lane. It is not DevBench unavailability and does not block the assay.
Do not generate or edit task-local orchestration scripts during live preflight
or baseline setup; load the installed protocol and matrix once and issue their
actions directly. Evidence files remain permitted.

Use the exact Simple COC order: `prepare_coc` is the first stateful call and
runs alone. Never call the profiler service, run the fail-closed proof, or reset
telemetry before positioning.

Require the bound active D3D adapter to be AMD. Require the live
`communityshaders.upscaling_api` description to expose `registry`,
`capabilities`, `snapshot`, `apply`, `operation`, and `events`, plus guarded
`expectedBuildId`, `expectedStateRevision`, `clientId`, `commandId`, `target`,
`purpose`, and `persistence` inputs. Retain the tool description and registry,
producer, capability, session, and Build-ID receipts. Never select the lane
from an unbound inventory entry.

Require `communityshaders.upscaling_api` to be executable as a DevBench
scenario `tool` step, not merely callable as a top-level client tool. All
scenarios in this protocol use `async: false`. A missing scenario registration
or a non-synchronous scenario receipt is `BLOCKED`; the dispatch and apply
cannot otherwise share one serialized server sequence.

Require public capabilities to expose FSR and every matrix quality mode before
any baseline. A missing method or quality is `BLOCKED`; do not substitute a
nearby supported state.

The public snapshot serializes each enum as `{ "value", "name" }`. Preserve
that raw object in evidence, but build the next `apply.target` from the
effective profile's `name` fields only: `method.name`, `qualityMode.name`,
`dlssProfile.name`, and `fsrRuntime.name`. Never submit a raw wrapper object,
numeric enum, defaulted field, or an inferred provider value. At a settled
boundary, require complete configured and effective profiles with no active
operation. The controller requested/stable stream is separate physical
evidence: it must agree for scaled FSR state. For TAA, None, and FSR Native
AA, requested/stable may instead be an inactive native None projection only
when the API reports no active operation and configured/effective are exact.
That projection never replaces the public effective target.

Load `matrix.v1.json` relative to this installed skill. Require schema version
1, adapter vendor `amd`, exactly three named lanes, exactly 31 entries with
ordinals 1 through 31, a 5,000 ms pace, and a 30,000 ms completion upper bound.
Do not reorder, deduplicate, replace, or infer entries.

Position once with an `async: false` server scenario containing
`coc WhiterunDragonsreach` and a 10,000 ms wait. Require the exact editor ID, loaded player, advancing
in-world frames, no blocking menu, and the same Build ID. This is the only COC
and is not measured.

After exact-cell positioning, complete the Simple COC measurement-admission
phase once: reuse the selected lane's schema inventory, query the profiler, run
the one-step negative scenario, and reset supported telemetry lanes serially.
The proof must report step `ok: false`, scenario `aborted: true`, `stepsRun: 1`,
and embedded `invalid_field` with `continueOnError: false`. A transient profiler
read gets only Simple COC's immediate-return 10-second recovery budget on the
same selected lane. A direct run never starts a controller availability wait.
If the selected lane does not recover or the proof fails, this protocol is
`BLOCKED` before any lane baseline mutation. Do not reposition, repeat
successful admission work, or start a second readiness wait.

## 2. Select and isolate the three lanes

Run each supported lane as a separate 31-transition measurement session in
this order:

1. `explicit_fsr4`: configured `fsrRuntime: fsr4`; physical backend must be
   `fsr4_runtime`.
2. `explicit_fsr3`: configured `fsrRuntime: fsr3`; physical backend must be
   `fsr_host` or `fsr_runtime`.
3. `fsr4_to_fsr3_fallback`: configured `fsrRuntime: fsr4`; a documented live
   FSR4-unavailable condition and fallback flag must be present; physical
   backend must be `fsr_host` or `fsr_runtime`.

Use the public capabilities and unavailable-condition masks, never AMD model
names, to determine whether a lane is runnable. If FSR4 is unavailable, mark
the explicit-FSR4 lane `BLOCKED`; this is expected on AMD hardware without
supported FSR4 execution. If no natural or advertised safe FSR4-unavailable
condition exists, mark the fallback lane `BLOCKED`. Never corrupt resources,
exhaust memory, disable hardware, or fabricate a condition to force it. A
blocked lane does not prevent another independently valid lane from running.

## 3. Establish each lane baseline

Start a short baseline-only stress session, then read one authoritative API
snapshot. Require complete configured and effective profiles, physical stable
evidence, and no active operation. Clone the effective profile through its
`name` fields; set only `method: fsr`,
`qualityMode: hoshipa`, `renderScaleMode: true`, and the lane's configured
`fsrRuntime`; preserve `dlssProfile`. Run one synchronous (`async: false`),
fail-closed mutation scenario: `qualification_begin`, then
`qualification_dispatch` with
`startPerformanceTelemetry: false`, then the public API `apply` as the
immediately following step. Bind the apply to the snapshot's exact
`stateRevision`, exact Build ID, unique lane-baseline client and command IDs,
`purpose: direct`, and `persistence: runtime_only`.

Use one 30,000 ms monotonic deadline from baseline dispatch. Pass only that
deadline's remaining QPC budget to the strict FSR Hoshipa waiter; it must
return upon the first successful receipt. Do not add an independent operation
wait. Require
coherent FSR evaluation in both eyes, correct scaled dimensions, exact
generation/resource ownership, the lane's physical backend, clean mutation
and lifecycle state, and no terminal failure. Stop the baseline-only stress
session.

Now arm one fresh measured Simple CSM telemetry set for that lane with
stateful telemetry actions serialized in its short ownership sequence: stress,
texture lifetime, load presentation, and profiler pre-arm. Require and retain
each receipt before starting the next stateful action; provider lifecycle,
resource publication, preparation, fidelity, stereo, retry, failure, memory,
and queue remain status evidence. Only read-only discovery/status calls may run
in parallel. For the first lane, reuse the CPU/GPU reset receipts from
measurement admission, require both captures inactive, and do not issue another
reset. Before each later lane, after the preceding lane's guarded stop receipt,
serialize exactly one CPU reset and one GPU reset to clear its measurements and
require
both captures inactive. In the first measured mutation scenario, start the
profiler immediately before dispatch; dispatch then starts CPU/GPU capture on
its QPC/frame. Stop only that lane's owned sessions after transition 31. Do not
combine capture windows across lanes.

## 4. Exact public-API transition primitive

For each matrix entry, use IDs unique across the entire AMD run and preserve
every response even when it is anomalous.
Use the same caller-generated `transitionId` and `ownerId` for that entry's
begin, dispatch, wait, and any cancellation; never reuse either pair.

1. Run a synchronous (`async: false`), server-owned 5,000 ms settling scenario. It contains no
   mutation. Read the authoritative API snapshot immediately after it and
   record its Build ID, session ID,
   `stateRevision`, profile-presence flags, complete configured/requested/
   applying/effective/stable/persisted profiles, conditions, operation state,
   and physical dimensions.
   A 429/502/503/504 from this read-only snapshot is a control-plane
   interruption, not a profile result. Use only the selected live lane's short
   bounded retry budget for that exact snapshot. While unavailable, do not
   launch a scenario, cancel, or apply. If it does not recover, record
   `pre_snapshot_transport_unavailable`, stop future mutations, preserve the
   exact error receipt and task-owned session IDs, send no further DevBench
   calls, and ask the user immediately to repair or restart the control plane.
   Do not attempt cleanup until the user explicitly directs it and the control
   plane responds. Do not consume the 30-second completion deadline or add
   another extended wait.
2. Require complete configured and effective API profiles and no active
   operation. Construct its complete API target from the effective profile's
   `name` fields; mutate only `method`, `qualityMode`, and
   `renderScaleMode` from the destination. For FSR entries also set the lane's
   configured `fsrRuntime`. Preserve `dlssProfile` and preserve the lane
   runtime as dormant state on None and TAA entries. For scaled FSR state,
   require the controller requested/stable profiles to agree with effective.
   For settled TAA, None, and FSR Native AA, an inactive native None controller
   projection is valid only when there is no active operation,
   configured/effective match the completed public target, and requested/stable
   both report None with render scale disabled. It is telemetry, not
   `pre_snapshot_profile_incoherent`; never use it to construct or replace the
   API target.
3. Materialize the snapshot-derived string target and every guarded apply
   argument before submitting one synchronous (`async: false`) server scenario with
   `continueOnError: false`. Its consecutive mutation steps are
   `qualification_begin`, the lane-transition-1 profiler start when applicable,
   `qualification_dispatch`, and `communityshaders.upscaling_api` `apply`.
   No wait, snapshot, client round trip, menu action, or other tool may appear
   between dispatch and apply. Scenario steps cannot interpolate earlier
   results, so no snapshot-dependent value may be deferred to scenario
   execution. Set `startPerformanceTelemetry: true` only on
   lane transition 1 so CPU/GPU counters and the transition QPC/frame share the
   actual apply's timing origin. Set it false on every other transition.
4. Apply only the constructed target with the immediately preceding snapshot
   `stateRevision`, exact Build ID, unique `clientId` and `commandId`,
   `purpose: direct`, and `persistence: runtime_only`. Require API status and
   result status `success`, `idempotentReplay: false`, admitted state revision
   equal to the snapshot revision, normalized target exact, and disposition
   exactly `applied_synchronously` or `queued`. `rejected`, `no_change`, a
   stale revision, producer mismatch, embedded error, restart requirement, or
   non-retryable admission failure is a control failure: cancel the owner only
   if needed, preserve receipts, and stop further mutations. Never retry,
   recover, or substitute a matrix row.
5. Start one shared 30,000 ms monotonic deadline at the dispatch QPC. For FSR
   destinations, call `qualification_wait` in Dragonsreach with only the
   current remaining QPC budget and return upon its first successful receipt. Use the
   exact FSR target, lane runtime, fixed foveation fixture,
   `milestone: strict`, and `timeoutMs: 30000`. Map quality strings to values
   `native_aa=0`, `hoshipa=1`, `ultra_quality=2`, `quality=3`, `balanced=4`,
   `performance=5`, and `ultra_performance=6`. The `vendor_native` FSR Native
   AA target has native API render-scale state but must still prove active FSR
   evaluation. Its exact effective API profile is the public target; the
   controller requested/stable render-scale projections may be `none` and are
   retained as telemetry, not used to reject that API target. Configured runtime
   matching and physical backend proof remain separate and `none` is a failure.
6. For None and TAA, do not call a vendor qualification waiter or manufacture
   an FSR target. Call DevBench `upscalingStable` in Dragonsreach exactly once
   with only the shared deadline's remaining budget and the complete normalized
   apply target as `-ExpectedProfileJson`. The target-correlated native barrier
   requires the authoritative effective runtime profile to equal that target,
   render scale to remain disabled, no active operation, and either
   `idle/idle` or `active/active` native controller state. Native TAA
   legitimately reports `active/active`; its render-scale controller
   projection may remain `None` and must not be compared with the effective
   TAA profile. Do not poll `operation` or start a second 30-second window.
   Read that apply's operation exactly once after the barrier; require its
   target and effective profile to match, its state to be `completed`, and the
   final snapshot to have no active operation before releasing the timing-only
   owner with `qualification_cancel`. On the next pre-apply snapshot, preserve
   a settled native None controller projection as physical telemetry when there
   is no active operation, its configured/effective API profile matches the
   completed TAA or None target, and requested/stable are inactive None. Do
   not relabel it as an incoherent profile or wait for it to become TAA.
   That expected cancellation closes the timing bracket and is not a render
   failure.
7. Read the operation, transition-filtered API events, authoritative API
   snapshot, render-scale status, preparation trace, and provider-lifecycle
   evidence. Inspect the completed transition before allowing the next apply.

A semantic strict timeout, unsatisfied milestone, or native-stability timeout
is a recorded transition `FAIL` or `INCONCLUSIVE`, not permission to hide the
row or retry it. Continue with the next matrix row only when the game remains
responsive, the qualification owner is closed, the final snapshot has no active
operation or unresolved physical mutation, and exact PID/build ownership still
holds. Otherwise stop future mutations without attempting repair.

Except for the pre-snapshot transport-unavailable path, which asks the user
before any further call, preserve the terminal receipt first on every stop
path. Then stop only a task-owned trace, profiler, or telemetry session using
its exact returned ownership guard. A cleanup failure is a separately recorded
anomaly and never authorizes another apply, retry, recovery, or substitution.

Every entry has exactly one begin, one dispatch, one apply, and one terminal
qualification receipt: a strict waiter receipt for an FSR destination or an
expected timing-owner cancellation after None/TAA stability. The public API is
the sole mutation path. Do not open the CS menu and do not
call `communityshaders.renderscale` action `apply`. No external frame-timing
source is used.

For every entry, distinguish the pre-mutation interval from destructive
mutation using the producer's `physicalMutationStarted` evidence, whose first
true observation is provider invalidation, dirtying, teardown, or destruction
(not merely engine-target creator entry). Before it becomes true, a queued,
deferred, rejected, or preparing replacement must retain the exact proven old
stereo presentation: current generation, provider resource, D3D device, and
both-eye path must remain exact, or a completed stereo output must retain
explicit ownership and immutability proof. In an ordinary world frame, a
queued or refused replacement alone must not select black keepalive or stretch.

Once destructive mutation begins or a new contract is published, the old
provider and completed output are no longer admissible without continuing
ownership and immutability proof. Require both eyes to converge on the newly
published generation before a normal vendor presentation passes. Recovery,
stretch, quarantine, or keepalive is permitted only as a protected fail-closed
outcome. A mixed eye, mixed generation, wrong resource/device/generation,
stale old-provider dispatch after mutation, or ordinary-world fallback caused
solely by pre-mutation replacement admission is a transition `FAIL`.

## 5. Completion and evidence rules

For scaled FSR, require requested, effective, stable, and physical profiles to
agree; scaled dimensions; coherent both-eye FSR presentation; exact provider
generation and resource ownership; and strict completion. For `vendor_native`
FSR Native AA, require the exact effective public API profile and an active
physical FSR contract at native dimensions. The controller requested/stable
render-scale projections may be `none`; retain them as telemetry, but do not
compare them with the effective vendor profile. Require coherent vendor
presentation, lifecycle and two-eye fidelity proof. A physical backend of
`none` is a failure. Record first physical match, first coherent stereo
presentation, `presentationStable`, `cleanupDrained`, and strict completion
separately.

For None and TAA require the public operation target and effective profile to
match the complete target; exact authoritative effective method;
`qualityMode: native_aa`; `renderScaleMode: false`; native dimensions;
producer-native physical-contract evidence; advancing coherent in-world
target-correlated `upscalingStable`; no unresolved physical
mutation; and no FSR evaluation treated as active presentation. Their
requested/stable controller state may remain the inactive native None physical
projection; record it separately and never require it to equal the public
effective TAA profile. If exact native presentation generation is unavailable,
record `generationEvidence: "not_exposed"` and retain raw dimensions but do not
calculate native or `dimensionsMatch` booleans. Native-generation evidence is
optional: mark only that evidence facet `INCONCLUSIVE`; do not relabel a core
`PASS`, make control unsafe, or block the next row solely because it is absent.

None, TAA, and FSR Native AA are distinct contracts: None has neither FSR nor
TAA, TAA is native non-vendor TAA, and FSR Native AA performs native-resolution
FSR evaluation.

Every transition record must retain direct raw paths for:

- dispatch/marker frame and QPC, API revisions, operation ID, disposition,
  admission route, replacement admission state and all reasons;
- first physical match, first coherent both-eye presentation, presentation,
  cleanup, and strict frame/QPC timings;
- current/completed/published publication generations; expected and published
  dimensions; `complete`; deferred-setup acknowledgement; D3D device/context
  matches; and producer `dimensionsMatch` without protocol-side arithmetic;
- configured runtime, desired/authoritative/stable-resource/lifecycle/actual-
  dispatch/both-eye backends, fallback flag, provider/resource generations,
  selected disposition, mutation state, and per-eye paths;
- admission and early exits; shader-cache waits; SSS/SSGI prewarm; DLSS, FSR,
  and FSR4 preparation; D3D creation; total preparation;
  request-to-prepared and prepared-to-creator latency;
- retries, consecutive stretch frames, queue/work gate, retirement and cleanup
  debt, memory admission, failure/fallback masks, vendor results, and terminal
  state;
- per-lane CPU/GPU telemetry and profiler capture, plus all stress, fidelity,
  stereo, lifetime, load-presentation, and trace session identities.

Perform one bounded DLSS trace capability lifecycle before the first AMD lane:
status, reset, start, stop, and read. Require zero DLSS dispatch records. A
missing trace action is `unsupported`; an exposed action that fails is a
control failure. Do not start a DLSS trace during AMD matrix transitions.

Unsupported preparation providers are `n/a`, never zero. Preserve raw values
before summarizing. Archive any log before reading it under the repository's
log-preservation contract.

## 6. AMD verdict and output

FSR Native AA must remain distinguishable from TAA and None. TAA and None must
restore native dimensions without treating FSR as active presentation.
Explicit FSR4 must physically use `fsr4_runtime`; explicit FSR3 must use
`fsr_host` or `fsr_runtime`. In the fallback lane, configured FSR4 and resolved
FSR3 must remain separate facts, and a coherent documented fallback is not a
failure. Returning from TAA or None must restore the lane's intended backend.
Never accept stale FSR generation/resource identity after mutation.

After each lane's transition 31, stop only its owned telemetry and retain final
status. Append one uniquely headed result column per completed lane using the
Simple COC ledger mechanics and produce separate tables for:

1. AMD explicit FSR4.
2. AMD explicit FSR3.
3. AMD FSR4-to-FSR3 fallback.
4. AMD TAA and None transitions, separated by lane.

For TAA/None separate vendor-to-TAA, vendor-to-None, TAA-to-vendor,
None-to-vendor, and TAA-to-None results. Include native restoration,
creator/mutation duration, first coherent native presentation, cleanup, and
stale-provider evidence. Never average None, TAA, and FSR Native AA.

Classify every transition and lane `PASS`, `FAIL`, `BLOCKED`, or
`INCONCLUSIVE`. Preserve semantic anomalies and continue only while control,
PID, build, required tools, and mutation ownership remain valid. Stop the
current lane on a scenario abort, transport/control failure, identity mismatch,
terminal render failure, device loss, OOM, or ownership/fidelity violation;
do not let one lane's blocked precondition invalidate another lane. Print the
complete tables and evidence paths, then stop; do not start another protocol.
