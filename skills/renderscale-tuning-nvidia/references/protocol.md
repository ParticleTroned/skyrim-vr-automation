# NVIDIA render-scale tuning protocol

This is the NVIDIA public-API correctness and measurement assay. It does not
run the Simple CSM matrix and never mutates a profile through
`communityshaders.renderscale`.

## 1. Bind and prepare

Apply Simple COC identity binding, core control discovery, evidence paths, and
the single runtime-only `prepare_coc` action. The receipt must prove debug
logging and the FOV/TAA `0.3/0.3/0.7` fixture without changing any upscaling
or VR FPS Stabilizer setting.
Use the exact Simple COC order: `prepare_coc` is the first stateful call and
runs alone. Never call the profiler service, run the fail-closed proof, or reset
telemetry before positioning.

Require the bound active D3D adapter to be NVIDIA. Require the live
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

Require public capabilities to expose DLSS, FSR, every matrix quality mode,
and FSR3 before the baseline. Missing capability is `BLOCKED`; do not replace a
provider or quality with a nearby supported one.

The public snapshot serializes each enum as `{ "value", "name" }`. Preserve
that raw object in evidence, but build the next `apply.target` from the
effective profile's `name` fields only: `method.name`, `qualityMode.name`,
`dlssProfile.name`, and `fsrRuntime.name`. Never submit a raw wrapper object,
numeric enum, defaulted field, or an inferred provider value. At a settled
boundary, require complete configured and effective profiles with no active
operation. The controller requested/stable stream is separate physical
evidence: it must agree for scaled vendor state. For TAA, None, DLAA, and FSR
Native AA, requested/stable may instead be an inactive native None projection
only when the API reports no active operation and configured/effective are
exact. That projection never replaces the public effective target.

Load `matrix.v1.json` relative to this installed skill. Require schema version
1, adapter vendor `nvidia`, exactly 33 entries with ordinals 1 through 33, a
5,000 ms pace, and a 30,000 ms completion upper bound. Do not reorder,
deduplicate, replace, or infer entries.

Position once with an `async: false` server scenario containing
`coc WhiterunDragonsreach` and a 10,000 ms wait. Require the exact editor ID, loaded player, advancing
in-world frames, no blocking menu, and the same Build ID. This is the only COC
and is not measured.

After exact-cell positioning, complete the Simple COC measurement-admission
phase once: refresh telemetry schemas, query the profiler, run the one-step
negative scenario, and reset supported telemetry lanes serially. The proof
must report step `ok: false`, scenario `aborted: true`, `stepsRun: 1`, and
embedded `invalid_field` with `continueOnError: false`. A transient profiler
read gets only Simple COC's immediate-return 10-second recovery budget. If it
does not recover or the proof fails, this protocol is `BLOCKED` before the
baseline mutation. Do not reposition, repeat successful admission work, or
start a second readiness wait.

## 2. Establish the NVIDIA baseline

Start a short baseline-only stress session, then read one authoritative API
snapshot. Require complete configured and effective profiles, physical stable
evidence, and no active operation. Clone the effective profile through its
`name` fields, set only `method: dlss`,
`qualityMode: hoshipa`, `renderScaleMode: true`, and dormant
`fsrRuntime: fsr3`, and preserve `dlssProfile`. Run one synchronous
(`async: false`), fail-closed mutation scenario: `qualification_begin`, then
`qualification_dispatch` with `startPerformanceTelemetry: false`, then the
public API `apply` as the immediately following step. Bind the apply to the
snapshot's exact `stateRevision`, exact Build ID, unique baseline client and
command IDs, `purpose: direct`, and `persistence: runtime_only`.

Use one 30,000 ms monotonic deadline from baseline dispatch. Pass only that
deadline's remaining QPC budget to the strict DLSS Hoshipa waiter; it must
return upon the first successful receipt. Do not add an independent operation
wait. Require
coherent DLSS evaluation in both eyes, correct scaled dimensions, exact
generation/resource ownership, clean mutation and lifecycle state, and no
terminal failure. Stop the baseline-only stress session.

Now arm one fresh measured Simple CSM telemetry set with stateful telemetry
actions serialized in its short ownership sequence: stress, texture lifetime,
load presentation, and profiler pre-arm. Reuse the CPU/GPU reset receipts from
measurement admission, require both captures to be inactive, and do not issue
another CPU/GPU reset. Require and retain each stateful receipt before starting
the next action; provider lifecycle, resource publication, preparation,
fidelity, stereo, retry, failure, memory, and queue remain status evidence. Only
read-only discovery/status calls may run in parallel. In the first measured
mutation scenario, start the profiler immediately before dispatch; dispatch
then starts CPU/GPU capture on its QPC/frame. That first measured apply, not
the positioning COC or initial-state apply, is their timing origin.

## 3. Exact public-API transition primitive

For each matrix entry, use unique transition, qualification, client, and
command IDs. Preserve every response even when it is anomalous.
Use the same caller-generated `transitionId` and `ownerId` for that entry's
begin, dispatch, wait, and any cancellation; never reuse either pair.

1. Run a synchronous (`async: false`), server-owned 5,000 ms settling scenario. It contains no
   mutation. Read the authoritative API snapshot immediately after it and
   record its Build ID, session ID,
   `stateRevision`, profile-presence flags, complete configured/requested/
   applying/effective/stable/persisted profiles, conditions, operation state,
   and physical dimensions.
   A 429/502/503/504 from this read-only snapshot is a control-plane
   interruption, not a profile result. Use only the controller's short bounded
   retry budget for that exact snapshot. While unavailable, do not launch a
   scenario, cancel, or apply. If it does not recover, record
   `pre_snapshot_transport_unavailable`, stop future mutations, preserve the
   exact error receipt and task-owned session IDs, send no further DevBench
   calls, and ask the user immediately to repair or restart the control plane.
   Do not attempt cleanup until the user explicitly directs it and the control
   plane responds. Do not consume the 30-second completion deadline or add
   another extended wait.
2. Require complete configured and effective API profiles and no active
   operation. Construct its complete API target from the effective profile's
   `name` fields; mutate only `method`, `qualityMode`, and
   `renderScaleMode` from the destination. For FSR entries also set
   `fsrRuntime: fsr3`. Preserve `dlssProfile` and preserve dormant
   `fsrRuntime` on None, TAA, DLAA, and DLSS entries. For scaled vendor state,
   require the controller requested/stable profiles to agree with effective.
   For settled TAA, None, DLAA, and FSR Native AA, an inactive native None
   controller projection is valid only when there is no active operation,
   configured/effective match the completed public target, and requested/stable
   both report None with render scale disabled. It is telemetry, not
   `pre_snapshot_profile_incoherent`; never use it to construct or replace the
   API target.
3. Materialize the snapshot-derived string target and every guarded apply
   argument before submitting one synchronous (`async: false`) server scenario with
   `continueOnError: false`. Its consecutive mutation steps are
   `qualification_begin`, the transition-1 profiler start when applicable,
   `qualification_dispatch`, and `communityshaders.upscaling_api` `apply`.
   No wait, snapshot, client round trip, menu action, or other tool may appear
   between dispatch and apply. Scenario steps cannot interpolate earlier
   results, so no snapshot-dependent value may be deferred to scenario
   execution. Set `startPerformanceTelemetry: true` only on
   transition 1 so CPU/GPU counters and the transition QPC/frame share the
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
5. Start one shared 30,000 ms monotonic deadline at the dispatch QPC. For
   vendor destinations, call `qualification_wait` in Dragonsreach with only
   the current remaining QPC budget; it must return upon its first successful receipt. Use the
   exact vendor target, fixed foveation fixture, `milestone: strict`, and
   `timeoutMs: 30000`. Map quality strings to qualifier values
   `native_aa=0`, `hoshipa=1`, `ultra_quality=2`, `quality=3`, `balanced=4`,
   `performance=5`, and `ultra_performance=6`. Include configured
   `fsrRuntime: fsr3` only for FSR. Include the preserved `dlssProfile.name`
   for DLSS and DLAA. A `vendor_native` target (DLAA or FSR Native AA) has a
   native API render-scale state but must still prove active vendor evaluation.
   Its exact effective API profile is the public target; the controller's
   requested/stable render-scale projections may be `none` and are retained as
   telemetry, not used to reject that API target. Physical backend proof
   remains separate and `none` is a failure.
6. For None and TAA, do not call a vendor qualification waiter or manufacture
   a DLSS/FSR target. Call DevBench `upscalingStable` in Dragonsreach exactly
   once with only the shared deadline's remaining budget and the complete
   normalized apply target as `-ExpectedProfileJson`. The target-correlated
   native barrier requires the authoritative effective runtime profile to
   equal that target, render scale to remain disabled, no active operation,
   and either `idle/idle` or `active/active` native controller state. Native
   TAA legitimately reports `active/active`; its render-scale controller
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
   snapshot, render-scale status, preparation trace, and applicable DLSS
   trace. Inspect the completed transition before allowing the next apply.

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
qualification receipt: a strict waiter receipt for a vendor destination or an
expected timing-owner cancellation after None/TAA stability. The public API
must be the sole mutation path. Do not open the CS menu and do
not call `communityshaders.renderscale` action `apply`. No external
frame-timing source is used.

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

## 4. Completion and evidence rules

For scaled DLSS and FSR, require requested, effective, stable, and physical
profiles to agree; scaled dimensions; coherent both-eye presentation; exact
provider generation and resource ownership; and strict completion. For
`vendor_native` DLAA and FSR Native AA, require the exact effective public API
profile plus an active physical DLSS or FSR contract at native dimensions. The
controller requested/stable render-scale projections may be `none`; retain
them as telemetry, but do not compare them with the effective vendor profile.
In every vendor case, require coherent vendor presentation, lifecycle and
two-eye fidelity proof. A physical backend of `none` is a failure. Record first
physical-profile match, first coherent stereo presentation,
`presentationStable`, `cleanupDrained`, and strict completion separately.
Cleanup may follow presentation and must not replace its timing.

For None and TAA require the public operation target and effective profile to
match the complete target; the authoritative effective method to be exact;
`qualityMode: native_aa`; `renderScaleMode: false`; native physical-contract
evidence from the producer; advancing coherent in-world target-correlated
`upscalingStable`; no
unresolved physical mutation; and no vendor evaluation treated as the active
presentation. Their requested/stable controller state may remain the inactive
native None physical projection; record it separately and never require it to
equal the public effective TAA profile. If the receipt cannot expose an exact
native presentation generation, record `generationEvidence: "not_exposed"` and
retain raw dimensions but do not calculate native or `dimensionsMatch` booleans.
Native-generation evidence is optional: mark only that evidence facet
`INCONCLUSIVE`; do not relabel a core `PASS`, make control unsafe, or block the
next row solely because it is absent.

Keep these contracts separate:

- None: no vendor upscaling and no TAA.
- TAA: native TAA without vendor evaluation.
- DLAA: native-resolution DLSS evaluation.
- FSR Native AA: native-resolution FSR evaluation.

Every transition record must retain direct raw paths for:

- dispatch/marker frame and QPC, API revisions, operation ID, disposition,
  admission route, replacement admission state and all reasons;
- first physical match, first coherent both-eye presentation, presentation,
  cleanup, and strict frame/QPC timings;
- current/completed/published publication generations; expected and published
  dimensions; `complete`; deferred-setup acknowledgement; D3D device/context
  matches; and producer `dimensionsMatch` without protocol-side arithmetic;
- desired, authoritative, stable-resource, lifecycle, actual-dispatch, and
  both-eye backends; configured runtime; fallback flag; provider/resource
  generations; selected disposition; mutation state; and per-eye paths;
- admission and early exits; shader-cache waits; SSS/SSGI prewarm; DLSS, FSR,
  and FSR4 preparation; D3D creation; total preparation;
  request-to-prepared and prepared-to-creator latency;
- retries, consecutive stretch frames, queue/work gate, retirement and cleanup
  debt, memory admission, failure/fallback masks, vendor results, and terminal
  state;
- CPU/GPU telemetry and profiler capture from transition 1 through transition
  33, plus all stress, fidelity, stereo, lifetime, load-presentation, and trace
  session identities.

Before each DLSS or DLAA transition, reset and start exactly one owned bounded
DLSS trace. Stop and read that same trace after the terminal receipt. A missing
trace action is `BLOCKED`; an exposed trace action that fails is a control
failure. Do not start a DLSS trace for FSR, TAA, or None.

Unsupported preparation providers are `n/a`, never zero. Preserve raw values
before summarizing. Archive any log before reading it under the repository's
log-preservation contract.

## 5. NVIDIA verdict and output

DLAA must remain distinguishable from TAA and None and must perform coherent
native-resolution DLSS evaluation. TAA and None must not retain DLSS as the
active presentation. Every FSR destination must retain configured FSR3 and
resolve coherently to `fsr_host` or `fsr_runtime`; `fsr4_runtime` is a failure.
Changing the logical native method must not retain the previous vendor.

No exact temporal/input tuple may receive duplicate Streamline evaluation. An
`eErrorDuplicatedConstants` is a transition `FAIL` even if presentation recovers;
continue the current wait through its shared deadline and, if control and
fidelity recover, continue later matrix rows to preserve the error history.
Stretch alone remains a recorded anomaly unless its failure mask, duration, or
ownership/fidelity evidence violates this protocol. Never accept stale DLSS
output after destructive mutation. A proven old provider may remain active only
before mutation begins.

After transition 33, stop only task-owned telemetry and retain final status.
Append one uniquely headed result column using the Simple COC ledger mechanics
and produce separate tables for:

1. NVIDIA DLSS and DLAA transitions.
2. NVIDIA FSR3 transitions.
3. NVIDIA provider-crossing transitions.
4. NVIDIA TAA and None transitions.

For TAA/None separate vendor-to-TAA, vendor-to-None, TAA-to-vendor,
None-to-vendor, and TAA-to-None results. Include native restoration,
creator/mutation duration, first coherent native presentation, cleanup, and
stale-provider evidence. Never average None, TAA, DLAA, and FSR Native AA.

Classify every transition `PASS`, `FAIL`, `BLOCKED`, or `INCONCLUSIVE`.
Preserve semantic anomalies and continue only when control, PID, build,
required tools, and mutation ownership remain valid. Stop future mutations on
a scenario abort, transport/control failure, identity mismatch, terminal
render failure, device loss, OOM, or ownership/fidelity violation. Print the
complete tables and evidence paths, then stop; do not start another protocol.
