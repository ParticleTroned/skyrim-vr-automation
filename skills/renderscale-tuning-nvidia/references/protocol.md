# NVIDIA render-scale tuning protocol

This is the NVIDIA public-API correctness and measurement assay. It does not
run the Simple CSM matrix and never mutates a profile through
`communityshaders.renderscale`.

## 1. Bind and prepare

The NVIDIA `SKILL.md` owns runtime-only `prepare_coc` and the one synchronous
Dragonsreach positioning scenario before this file is read. Apply the shared
post-position contract to that returned scenario, then use it for baseline and
measured-owner handoff. Do not repeat its reads or add another preflight phase.

Use the installed plugin's direct DevBench MCP tools exclusively for every
NVIDIA baseline, transition, evidence read, and guarded cleanup. Do not
enumerate tools, audit schemas, use a controller, switch lanes, or generate a
local orchestration script. If one of the named direct calls is unavailable,
stop with `plugin_direct_unavailable`; there is no fallback transport.

Require `status.adapter.available: true` and NVIDIA vendor ID `0x10DE`/4318 in
the positioning `communityshaders.renderscale status` result. This is the
bound active D3D adapter; do not substitute generic process inventory or a
description string. Retain the fixture receipt and the single positioning
scenario response.

Require public capabilities to expose DLSS, FSR, every matrix quality mode,
and FSR3 before the baseline. Missing capability is `BLOCKED`; do not replace a
provider or quality with a nearby supported one.

The public snapshot serializes each enum as `{ "value", "name" }`. Preserve
that raw object in evidence, but build the next `apply.target` from the
effective profile's `name` fields only: `method.name`, `qualityMode.name`,
`dlssProfile.name`, and `fsrRuntime.name`. Never submit a raw wrapper object,
numeric enum, defaulted field, or an inferred provider value. At a settled
boundary, require complete configured, requested, effective, and stable public
profiles with no active operation; requested/effective/stable must agree with
the exact completed target for every destination. The render-scale
controller's applied/stable resource records are separate physical evidence.
At native resolution they remain inactive with backend `none`, but retain the
exact logical method and never replace a public profile.

Load the packaged `matrix.v1.json` with this protocol only after the
synchronous positioning response returns, and execute it unchanged. Its
structure is an offline package invariant; do not revalidate or summarize it.

## 2. Establish the NVIDIA baseline

Reuse the authoritative post-position API snapshot. Require complete configured
and effective profiles, physical stable evidence, and no active operation.
Clone the effective profile through its
`name` fields, set only `method: dlss`,
`qualityMode: hoshipa`, `renderScaleMode: true`, and dormant
`fsrRuntime: fsr3`, and preserve `dlssProfile`. Run one synchronous
(`async: false`), fail-closed mutation scenario: reset then start the short
baseline-only stress session, `qualification_begin`, then
`qualification_dispatch` with `startPerformanceTelemetry: false`, then the
public API `apply` as the immediately following step, then the strict DLSS
Hoshipa `qualification_wait` as the final step. Use the shared contract's exact
six labels and wrapper paths. Bind the apply to the
snapshot's exact `stateRevision`, exact Build ID, unique baseline client and
command IDs, `purpose: direct`, and `persistence: runtime_only`.

The final waiter step uses the same owner and transition, the full
dispatch-relative `timeoutMs: 30000`, exact target and foveation fixture, and
`milestone: strict`; never calculate or pass a client-side remaining budget.
Do not add an independent operation wait. After the complete scenario returns,
require
coherent DLSS evaluation in both eyes, correct scaled dimensions, exact
generation/resource ownership, clean mutation and lifecycle state, and no
terminal failure. Require `milestoneTimings` and `replacementTimeline` in this
terminal receipt as directed by the shared contract; they are output evidence,
not tool-description fields.

Only when that labeled waiter subreceipt is strictly satisfied, use the shared
contract's one synchronous handoff scenario to stop the
baseline-only stress owner and arm the fresh measured stress, texture lifetime,
load presentation, and profiler owners in its short ownership sequence.
An unsatisfied or missing waiter subreceipt bypasses handoff and permits only
the baseline stress owner's guarded stop.
Do not issue a separate CPU/GPU reset during pass 1. Transition 1 dispatch
requires both captures inactive and atomically resets/starts them. Retain each
stateful receipt;
provider lifecycle, resource publication, preparation, fidelity, stereo,
retry, failure, memory, and queue remain status evidence. In the first measured
mutation scenario, call profiler API `clear_history` immediately before
dispatch; do not use bounded `start_capture` or invent `frameCount`. Dispatch
then starts CPU/GPU capture on its QPC/frame. That first measured apply, not
the positioning COC or initial-state apply, is their timing origin.

Execute the exact matrix twice in the same Skyrim process. Call them `pass 1`
and `pass 2`; use IDs unique across both passes and never alter the matrix,
pacing, completion deadline, cell, fixture, or provider rules.

After pass 1 transition 33, stop and preserve only pass 1's owned telemetry
under `raw/pass-1/finalization`.
Record a raw cooldown-start memory snapshot, then run exactly one synchronous
server-owned 10,000 ms wait containing no mutation or telemetry action. Record
a raw cooldown-end snapshot and require the same PID and Build ID, advancing
world frames, no active public operation, drained cleanup debt, and no leaked
owner or capture. Do not require memory usage to decrease during cooldown;
pressure and growth are evidence, not a mutation gate.

Repeat only section 2's fail-closed baseline mutation and strict waiter with
new IDs, without another COC or its pass 1 handoff. After strict baseline
cleanup, arm fresh pass 2 owners and serialize exactly one CPU reset and one
GPU reset after confirming pass 1's captures are inactive. Pass 2 transition 1
is the new CPU/GPU timing origin. Execute all 33 transitions once more;
section 5 performs the single guarded pass 2 stop. Do not start a third pass.
A semantic pass 1 failure does not suppress pass 2 when control, identity,
ownership, liveness, and cleanup remain safe; an interrupted or unsafe pass 1
stops before further mutation and asks the user.

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
   interruption, not a profile result. Use only the selected live lane's short
   bounded retry budget for that exact snapshot. While unavailable, do not
   launch a scenario, cancel, or apply. If it does not recover, record
   `pre_snapshot_transport_unavailable`, stop future mutations, preserve the
   exact error receipt and task-owned session IDs, send no further DevBench
   calls, and ask the user immediately to repair or restart the control plane.
   Do not attempt cleanup until the user explicitly directs it and the control
   plane responds. Do not consume the 30-second completion deadline or add
   another extended wait.
2. Require complete configured, requested, effective, and stable API profiles,
   exact requested/effective/stable agreement, and no active operation.
   Construct the complete API target from the effective profile's `name`
   fields; mutate only `method`, `qualityMode`, and
   `renderScaleMode` from the destination. For FSR entries also set
   `fsrRuntime: fsr3`. Preserve `dlssProfile` and preserve dormant
   `fsrRuntime` on None, TAA, DLAA, and DLSS entries. Record the separate
   render-scale controller applied/stable resource keys as physical telemetry;
   for a native target they must be inactive with backend `none` and retain
   that target's exact method.
3. Materialize the snapshot-derived string target and every guarded apply
   argument before submitting one synchronous (`async: false`) server scenario with
   `continueOnError: false`. Its consecutive mutation steps are
   `qualification_begin`, the transition-1 profiler start when applicable,
   `qualification_dispatch`, `communityshaders.upscaling_api` `apply`, and the
   target-correlated `qualification_wait` as the final step. Label the last two
   steps `profile-apply` and `qualification-wait`.
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
   exactly `queued`. `rejected`, `applied_synchronously`, `no_change`, a
   stale revision, producer mismatch, embedded error, restart requirement, or
   non-retryable admission failure is a control failure: cancel the owner only
   if needed, preserve receipts, and stop further mutations. Never retry,
   recover, or substitute a matrix row.
5. The final scenario step is `qualification_wait`. For vendor destinations,
   pass the full
   dispatch-relative `timeoutMs: 30000`; never calculate or pass a client-side
   remaining budget. This is the one shared 30,000 ms monotonic deadline from
   dispatch, not a second window. It must return upon its first successful
   receipt. Use the
   exact vendor target, fixed foveation fixture, and `milestone: strict`. Map
   quality strings to qualifier values
   `native_aa=0`, `hoshipa=1`, `ultra_quality=2`, `quality=3`, `balanced=4`,
   `performance=5`, and `ultra_performance=6`. Include configured
   `fsrRuntime: fsr3` only for FSR. Include the preserved `dlssProfile.name`
   for DLSS and DLAA. A `vendor_native` target (DLAA or FSR Native AA) has a
   native API render-scale state but must still prove fixed-resolution vendor
   evaluation. Its public requested/effective/stable profiles must all equal
   the exact target. Its render-scale controller resource key remains inactive
   with backend `none`; that resource key is never vendor-execution evidence.
   The waiter must instead return `nativeVendorExecution.required: true` and
   `sameFrameBothEyesValid: true`, with each eye's `presentationFrame` equal to
   its `dispatchFrame`. Both eyes must report the same non-`none`
   `actualBackend`: exactly `dlss` for DLAA, or `fsr_host`/`fsr_runtime` for
   FSR Native AA. FSR Native AA must additionally report one shared nonzero
   `dispatchSerial` for its combined-stereo dispatch. Preserve
   `actualRuntimeFallbackObserved`; do not derive it or `actualBackend` from
   the render-scale resource key. The exact foveation fixture and coherent
   two-eye native presentation remain required. A missing or mismatched native
   vendor receipt is a failure, not `INCONCLUSIVE`.
   The direct tool transport must outlive the current server waiter budget by
   five seconds without changing the shared 30-second measurement deadline. A
   successful waiter still returns immediately and never waits out that
   envelope.

   If the mutation-and-wait scenario response is lost, apply the shared
   contract's owner-correlated recovery rule immediately. Never replay the
   scenario, apply, or waiter. Recover matching terminal `lastEvidence` from
   the already-running server scenario. Require `active: false` and matching
   owner/transition IDs before trace stop or row classification.
   This recovery rule applies to both vendor and native qualification waits. If
   no terminal receipt can be recovered within the original deadline plus its
   five-second receipt bound, preserve all task-owned session IDs, stop future
   calls, and ask the user.
6. For None and TAA, use the same final scenario `qualification_wait` in
   Dragonsreach with the full dispatch-relative `timeoutMs: 30000`. Pass
   `milestone: strict` and the exact native target:
   `method: none` or
   `method: taa`, `qualityMode: 0`, and `renderScaleMode: false`; omit
   `dlssProfile` and `fsrRuntime`. This is a native target, not a manufactured
   DLSS/FSR target. The target-correlated server barrier requires the
   authoritative requested/effective/stable profiles to equal that target,
   render scale to remain disabled, no active operation, advancing coherent
   native presentation, and either `idle/idle` or `active/active` native
   controller state. Native TAA legitimately reports `active/active`. Its
   physical render-scale resource key remains inactive with backend `none` but
   retains method TAA. Do not poll `operation` or start a second 30-second window.
   Read that apply's operation exactly once after the terminal waiter receipt;
   require its target and effective profile to match, its state to be
   `completed`, and the final snapshot to have no active operation. The waiter
   closes the timing owner; do not call `qualification_cancel` after any
   terminal waiter receipt. Cancellation is only for an owner that has not
   entered its waiter. On the next pre-apply snapshot, require the public
   requested/effective/stable profiles to remain exact and preserve the
   separate inactive native physical key as telemetry.
   The terminal waiter receipt closes the timing bracket and is not a render
   failure.
7. Read the operation, transition-filtered API events, authoritative API
   snapshot, render-scale status, preparation trace, and applicable DLSS
   trace. Inspect the completed transition before allowing the next apply.

For each transition, persist the exact decoded response bodies in one local
batch under `raw/transitions/transition-NN/`: settle scenario, pre-snapshot,
mutation-and-wait scenario (or recovered
`qualification_status.lastEvidence` when that scenario response is lost),
operation, API events, final snapshot,
render-scale status, preparation trace, and any DLSS trace lifecycle receipts.
Add and rehash their `receipt-index.json` entries before the next apply. Never
substitute a transcript reference or MCP/store key for one of these files.
This transition evidence requirement does not include `prepare_coc` or the
positioning scenario. Missing startup receipts are a non-blocking anomaly and
never stop a valid matrix.

A semantic strict timeout, unsatisfied milestone, or native-stability timeout
is a recorded transition `FAIL` or `INCONCLUSIVE`, not permission to hide the
row or retry it. Continue with the next matrix row only when the game remains
responsive, the qualification owner is closed, the final snapshot has no active
operation or unresolved physical mutation, and exact PID/build ownership still
holds. Otherwise stop future mutations without attempting repair.

A completed transition-level physical-contract, presentation, lifecycle, or
both-eye fidelity mismatch makes that row `FAIL`; it does not by itself make
control unsafe. Once its terminal receipt is preserved, its trace owner is
closed, and the conditions above are clean, continue to the next matrix row so
the assay retains the build's error history. Stop only for unresolved ownership
or mutation, a still-active owner/operation, stale or mixed resources still in
use, producer terminal failure, device loss, OOM, identity loss, or transport
loss whose terminal receipt cannot be recovered.

Except for the pre-snapshot transport-unavailable path, which asks the user
before any further call, preserve the terminal receipt first on every stop
path. Then stop only a task-owned trace, profiler, or telemetry session using
its exact returned ownership guard. A cleanup failure is a separately recorded
anomaly and never authorizes another apply, retry, recovery, or substitution.

Every entry has exactly one begin, one dispatch, one apply, and one terminal
qualification receipt from the same strict waiter for every destination. The
public API must be the sole mutation path. Do not open the CS menu and do
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
`vendor_native` DLAA and FSR Native AA, require exact public
requested/effective/stable profiles plus fixed-resolution vendor execution at
native dimensions. The render-scale controller resource key is inactive with
backend `none`; its logical method must still be exact, and
`qualification_wait.nativeVendorExecution` is authoritative for same-frame,
both-eye vendor execution. Take `actualBackend`, the per-eye dispatch frames
and serials, and `actualRuntimeFallbackObserved` directly from that receipt.
Never substitute the render-scale resource backend. DLAA requires `dlss`; FSR
Native AA requires `fsr_host` or `fsr_runtime` and one shared nonzero dispatch
serial. For scaled vendor state, also require lifecycle and render-scale
fidelity proof. A missing or mismatched native vendor receipt is a failure.
Record first
physical-profile match, first coherent stereo presentation,
`presentationStable`, `cleanupDrained`, and strict completion separately.
Use the one strict receipt's `milestoneTimings`; preserve presentation,
cleanup, and strict first-observation frame/QPC/elapsed values, the signed
presentation-to-cleanup delta, `cleanupTailMs`/frames, and
`sameObservation`. Cleanup may follow presentation and must not replace its
timing. Equal values count as a measured zero tail only when
`sameObservation: true`; they are never filled from strict completion.

For None and TAA require the public operation target and
requested/effective/stable profiles to match the complete target;
`qualityMode: native_aa`; `renderScaleMode: false`; native physical-contract
evidence from the producer; advancing coherent in-world target-correlated
native `qualification_wait` receipt; no
unresolved physical mutation; and no vendor evaluation treated as the active
presentation. Record the inactive backend-`none` render-scale resource key
separately; its method must equal the target. If the receipt cannot expose an exact
native presentation generation, record `generationEvidence: "not_exposed"` and
retain raw dimensions but do not calculate native or `dimensionsMatch` booleans.
Native-generation evidence is optional: mark only that evidence facet
`INCONCLUSIVE`; do not relabel a core `PASS`, make control unsafe, or block the
next row solely because it is absent.
When every required native contract check passes and only exact native
generation is unavailable, the transition classification must remain `PASS`;
record `nativeGenerationEvidence: INCONCLUSIVE` with reason `not_exposed`.

Keep these contracts separate:

- None: no vendor upscaling and no TAA.
- TAA: native TAA without vendor evaluation.
- DLAA: native-resolution DLSS evaluation.
- FSR Native AA: native-resolution FSR evaluation.

Every transition record must retain direct raw paths for:

- pass number, transition ordinal, dispatch/marker frame and QPC, API
  revisions, operation ID, disposition,
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

Project these producer fields verbatim from the terminal receipt's
`replacementTimeline` into `summary.json`, `transitions.csv`, and the rendered
report: `currentPresentationProven`, `currentPresentationGeneration`,
`replacementAdmissionBlocked`, `replacementAdmissionBlockReasons`,
`physicalMutationStarted`, and `selectedPresentationDisposition`. Also retain
the current presentation device/resource identity, both-eye path/generation,
completed-output reuse/ownership proof, and the relative raw receipt paths plus
their SHA-256 values. Use `lastPreMutation` for the pre-mutation facet,
`blockedPreMutation` for blocked-admission proof, and
`firstPhysicalMutation` for the mutation boundary. A missing required timeline
entry makes only that evidence facet `INCONCLUSIVE`; do not invent it from a
later status snapshot.

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

After pass 2 transition 33, stop only task-owned telemetry and retain final
status. Persist every pass 2 stop/final-status response under
`raw/pass-2/finalization`, then verify
that every `receipt-index.json` entry exists and matches its byte length and
SHA-256 before producing summaries or appending the ledger. An evidence root
containing only `summary.json` and `transitions.csv` is incomplete and cannot
support a ledger append.
Append one uniquely headed result column only after the complete two-pass
comparison.

### Memory confirmation result

Produce a dedicated memory table with columns for pass 1 start/end/delta,
cooldown start/end/delta, pass 2 start/end/delta, and the pass-2/pass-1 growth
ratio. Include process private MiB, system commit MiB, DXGI process usage MiB,
memory pressure, live tracked texture count, and estimated live tracked
texture MiB. Preserve the raw start/end receipts for both passes and both
cooldown snapshots; never substitute the final status for a missing boundary.
Store transitions under `raw/pass-1/transitions` and
`raw/pass-2/transitions`, and store the six memory boundaries under
`raw/memory`. Index every file in `receipt-index.json`.
Write a `memoryConfirmation` object to `summary.json` containing
`passesCompleted`, `cooldownMilliseconds`, the three boundary groups, all
computed deltas and ratios, `predicateInputs`, and `verdict`. Include `pass`
in every `transitions.csv` row.

Compute a ratio only when the pass 1 delta is positive; otherwise report
`n/a`. Classify memory separately from render correctness:

- `retention_signal` requires pass 2 process-private and system-commit growth
  each to be at least 75 percent of its positive pass 1 growth, plus positive
  pass 2 DXGI growth or an increase in pass 2 live texture count or bytes.
- `initialization_dominated` requires pass 2 process-private and system-commit
  growth each to be no more than 25 percent of its positive pass 1 growth and
  no positive pass 2 increase in DXGI usage, live texture count, or live
  texture bytes.
- Every other complete comparison is `inconclusive`. A missing repeat is
  `repeat_not_completed`, makes the assay `INTERRUPTED`, and forbids a ledger
  append.

Neither `retention_signal` nor Normal final pressure proves or disproves a
leak. Print the memory classification, its exact predicate inputs, and the
render verdict separately. Memory growth alone never changes a transition's
`PASS`/`FAIL` classification, and the protocol never starts a third pass.

### Ledger append transaction

Treat each comparison-ledger column append as one transaction. Use exactly
`docs/development/vr-render-scale-comparison-ledger.csv`; never search for a
ledger. Read and parse it once after both passes finish, retain its original
hash, and compose the
complete candidate before any ledger write. Reject the candidate unless it has
the same ordered metric rows and row count, exactly one additional rightmost
column, a unique nonempty header, and zero changed pre-existing parsed cell
values under ordinal comparison. Do not normalize, reorder, or otherwise
rewrite an existing cell.

Require these five distinct metric rows before composing the candidate:
`runtime_device_loss_failures`, `runtime_oom_failures`,
`runtime_producer_terminal_failures`,
`vendor_native_qualification_failures`, and
`credible_liveness_timeouts`. If any row is absent, preserve the run evidence,
do not modify the ledger, and report `ledger_failure_schema_outdated`.

Also require `memory_confirmation_passes`,
`memory_process_private_mib_pass1_pass2_ratio`,
`memory_system_commit_mib_pass1_pass2_ratio`,
`memory_dxgi_usage_mib_pass1_pass2_ratio`,
`memory_live_textures_pass1_cooldown_pass2`,
`memory_live_texture_mib_pass1_cooldown_pass2`,
`memory_pressure_pass1_cooldown_pass2`, and
`memory_confirmation_verdict`. Store both pass deltas and the ratio in the
three growth cells as `<pass1-delta>/<pass2-delta>/<ratio>`. Store resource
and pressure cells as
`<pass1-end>/<cooldown-start>-><cooldown-end>/<pass2-start>-><pass2-end>`.
Never collapse the memory classification into the render verdict.

Populate those rows from preserved receipts, never from the number of
transitions classified `FAIL`:

- Count device loss and OOM only when the runtime reports those exact terminal
  conditions.
- Count producer terminal failures only when the producer reports a terminal
  failure. A qualification-terminal result is not a producer terminal failure.
- Count a vendor-native qualification failure when native vendor execution
  proof is absent or mismatched without device loss, OOM, or producer terminal
  evidence. This records a qualification/observer failure, not a runtime-hard
  failure.
- Count a credible liveness timeout only when the shared deadline expires and
  independent bound-operation or game-progress evidence proves a genuine
  stall. A transport failure, missing observation, or observer mismatch is not
  a credible liveness timeout.

Print all five counts separately in the summary and result tables and retain
the underlying transition reasons. The legacy `hard_transition_failures` and
`hard_failures_oom_device_loss` rows are ambiguous; if present, write
`n/a; legacy aggregate disabled` in the new result cell rather than a failure
total. Never sum qualification or liveness results into a runtime-hard metric.

Apply the validated candidate with a single in-place `Update File` operation
for the ledger path. Never combine `Delete File` and `Add File` operations for
that path in one `apply_patch`, and never delete and recreate the ledger. If the
append cannot be represented as one in-place update, stop before modifying the
ledger and report `ledger_append_unrepresentable`; retain the run evidence and
do not rerun the assay.

After the write, parse the ledger again and repeat every candidate invariant,
confirm that the original hash changed, and run `git diff --check`. Report
`ledger_append_validation_failed` rather than claiming an append if any check
fails. A ledger finalization failure does not invalidate or permit rewriting
the preserved assay evidence.

### Result tables

Produce separate tables for:

1. NVIDIA DLSS and DLAA transitions.
2. NVIDIA FSR3 transitions.
3. NVIDIA provider-crossing transitions.
4. NVIDIA TAA and None transitions.

Show pass 1 and pass 2 side by side for every transition. Preserve each
pass's classification and timings, and report whether every failure or anomaly
recurred, recovered, or appeared only in the repeat. Never average the passes
or replace either pass with the memory classification.

For TAA/None separate vendor-to-TAA, vendor-to-None, TAA-to-vendor,
None-to-vendor, and TAA-to-None results. Include native restoration,
creator/mutation duration, first coherent native presentation, cleanup, and
stale-provider evidence. Never average None, TAA, DLAA, and FSR Native AA.

Classify every transition `PASS`, `FAIL`, `BLOCKED`, or `INCONCLUSIVE`.
Preserve semantic anomalies and continue only when control, PID, build,
required tools, and mutation ownership remain valid. A qualification-terminal
row failure is not a producer terminal failure. Stop future mutations on a
scenario abort, unrecoverable transport/control failure, identity mismatch,
device loss, OOM, leaked owner/session, active operation, unresolved physical
mutation, or stale/mixed resources that remain in use. Do not stop solely
because a completed row recorded a physical or fidelity mismatch.

If the matrix ends early, label every entry that was never dispatched
`NOT RUN`, never `BLOCKED`. Reserve `BLOCKED` for a row whose required admission
or precondition failed before its mutation. Report the overall assay as
`INTERRUPTED` while retaining the exact classifications of completed rows; do
not convert it to overall `FAIL` merely because later rows were not run. Do not
append the comparison ledger for an interrupted matrix. Print the complete
tables and evidence paths, then stop; do not start another protocol.
