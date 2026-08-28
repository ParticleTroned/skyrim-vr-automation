# AMD render-scale tuning protocol

This is the AMD public-API correctness and measurement assay. It runs three
separate backend lanes and never runs the Simple CSM matrix or mutates a
profile through `communityshaders.renderscale`.

## 1. Bind and prepare

Apply Simple COC identity binding, schema discovery, fail-closed scenario
probe, evidence paths, and the single runtime-only `prepare_coc` action. The
receipt must prove debug logging and the FOV/TAA `0.3/0.3/0.7` fixture without
changing any upscaling or VR FPS Stabilizer setting.

Require the bound active D3D adapter to be AMD. Require the live
`communityshaders.upscaling_api` description to expose `registry`,
`capabilities`, `snapshot`, `apply`, `operation`, and `events`, plus guarded
`expectedBuildId`, `expectedStateRevision`, `clientId`, `commandId`, `target`,
`purpose`, and `persistence` inputs. Retain the tool description and registry,
producer, capability, session, and Build-ID receipts. Never select the lane
from an unbound inventory entry.

Load `matrix.v1.json` relative to this installed skill. Require schema version
1, adapter vendor `amd`, exactly three named lanes, exactly 31 entries with
ordinals 1 through 31, a 5,000 ms pace, and a 30,000 ms completion upper bound.
Do not reorder, deduplicate, replace, or infer entries.

Position once with a server scenario containing `coc WhiterunDragonsreach`
and a 10,000 ms wait. Require the exact editor ID, loaded player, advancing
in-world frames, no blocking menu, and the same Build ID. This is the only COC
and is not measured.

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
snapshot. Require a complete stable profile and no active operation. Clone the
complete stable profile; set only `method: fsr`,
`qualityMode: hoshipa`, `renderScaleMode: true`, and the lane's configured
`fsrRuntime`; preserve `dlssProfile`. Begin a baseline qualification and
dispatch it immediately before applying the profile with the snapshot's exact
`stateRevision`, exact Build ID, unique lane-baseline client and command IDs,
`purpose: direct`, and `persistence: runtime_only`.

Wait for the operation and a strict FSR Hoshipa qualification to complete,
returning immediately on success with 30,000 ms only as the deadline. Require
coherent FSR evaluation in both eyes, correct scaled dimensions, exact
generation/resource ownership, the lane's physical backend, clean mutation
and lifecycle state, and no terminal failure. Stop the baseline-only stress
session.

Now arm one fresh measured Simple CSM telemetry set for that lane in a bounded
fan-out: stress, texture lifetime, load presentation, provider lifecycle,
resource publication, preparation, CPU, GPU, profiler, fidelity, stereo,
retry, failure, memory, and queue evidence. Reset and require CPU/GPU capture
to be inactive and pre-arm only the profiler. Start CPU, GPU, and profiler
timing immediately before that lane's measured transition 1 and stop only that
lane's owned sessions after transition 31. Do not combine capture windows
across lanes.

## 4. Exact public-API transition primitive

For each matrix entry, use IDs unique across the entire AMD run and preserve
every response even when it is anomalous.

1. Wait exactly 5,000 ms server-side.
2. Read the authoritative API snapshot and record its Build ID, session ID,
   `stateRevision`, profile-presence flags, complete configured/requested/
   applying/effective/stable/persisted profiles, conditions, operation state,
   and physical dimensions.
3. Require a complete stable active profile. Clone it; mutate only `method`,
   `qualityMode`, and `renderScaleMode` from the destination. For FSR entries
   also set the lane's configured `fsrRuntime`. Preserve `dlssProfile` and
   preserve the lane runtime as dormant state on None and TAA entries.
4. Call `qualification_begin` for timing ownership. This does not select a
   profile and does not create a vendor target.
5. On lane transition 1 only, start the pre-armed profiler immediately before
   `qualification_dispatch`. Dispatch every transition immediately before the
   API apply; set `startPerformanceTelemetry: true` only on transition 1 so
   CPU/GPU counters and the transition QPC/frame share that timing origin.
6. Call only `communityshaders.upscaling_api` action `apply` with the cloned
   complete target, the immediately preceding snapshot `stateRevision`, exact
   Build ID, unique `clientId` and `commandId`, `purpose: direct`, and
   `persistence: runtime_only`.
7. Treat a stale revision, producer mismatch, rejected disposition, embedded
   error, restart requirement, or non-retryable admission failure as a failed
   step. Do not send a recovery apply or the next matrix entry.
8. For FSR destinations, call `qualification_wait` in Dragonsreach with the
   exact FSR target, lane runtime, fixed foveation fixture,
   `milestone: strict`, and `timeoutMs: 30000`. Map quality strings to values
   `native_aa=0`, `hoshipa=1`, `ultra_quality=2`, `quality=3`, `balanced=4`,
   `performance=5`, and `ultra_performance=6`. Configured runtime matching and
   physical backend matching are separate requirements.
9. For None and TAA, wait up to 30,000 ms for the public operation to complete
   and the existing DevBench `upscalingStable` barrier in Dragonsreach to
   return. Both waits return as soon as satisfied. Do not call a vendor
   qualification waiter or manufacture an FSR target. Then release the
   timing-only qualification owner with `qualification_cancel`; its expected
   cancellation receipt closes the bracket and is not a render failure.
10. Read the operation, transition-filtered API events, authoritative API
    snapshot, render-scale status, preparation trace, and provider-lifecycle
    evidence. Inspect the completed transition before allowing the next apply.

Every entry has exactly one begin, one dispatch, one apply, and one terminal
qualification receipt: a strict waiter receipt for an FSR destination or an
expected timing-owner cancellation after None/TAA stability. The public API is
the sole mutation path. Do not open the CS menu and do not
call `communityshaders.renderscale` action `apply`. No external frame-timing
source is used.

## 5. Completion and evidence rules

For FSR render scale and FSR Native AA require requested, API, and physical
profiles to agree; correct scaled or native dimensions; coherent both-eye FSR
presentation; exact provider generation and resource ownership; and strict
completion. Record first physical match, first coherent stereo presentation,
`presentationStable`, `cleanupDrained`, and strict completion separately.

For None and TAA require the public operation to complete; exact authoritative
method; `qualityMode: native_aa`; `renderScaleMode: false`; native dimensions;
advancing coherent in-world `upscalingStable`; no unresolved physical
mutation; and no FSR evaluation treated as active presentation. If exact native
presentation generation is unavailable, retain that tooling gap and classify
generation proof `INCONCLUSIVE`; never calculate or fabricate it.

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
