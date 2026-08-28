# NVIDIA render-scale tuning protocol

This is the NVIDIA public-API correctness and measurement assay. It does not
run the Simple CSM matrix and never mutates a profile through
`communityshaders.renderscale`.

## 1. Bind and prepare

Apply Simple COC identity binding, schema discovery, fail-closed scenario
probe, evidence paths, and the single runtime-only `prepare_coc` action. The
receipt must prove debug logging and the FOV/TAA `0.3/0.3/0.7` fixture without
changing any upscaling or VR FPS Stabilizer setting.

Require the bound active D3D adapter to be NVIDIA. Require the live
`communityshaders.upscaling_api` description to expose `registry`,
`capabilities`, `snapshot`, `apply`, `operation`, and `events`, plus guarded
`expectedBuildId`, `expectedStateRevision`, `clientId`, `commandId`, `target`,
`purpose`, and `persistence` inputs. Retain the tool description and registry,
producer, capability, session, and Build-ID receipts. Never select the lane
from an unbound inventory entry.

Load `matrix.v1.json` relative to this installed skill. Require schema version
1, adapter vendor `nvidia`, exactly 33 entries with ordinals 1 through 33, a
5,000 ms pace, and a 30,000 ms completion upper bound. Do not reorder,
deduplicate, replace, or infer entries.

Position once with a server scenario containing `coc WhiterunDragonsreach`
and a 10,000 ms wait. Require the exact editor ID, loaded player, advancing
in-world frames, no blocking menu, and the same Build ID. This is the only COC
and is not measured.

## 2. Establish the NVIDIA baseline

Start a short baseline-only stress session, then read one authoritative API
snapshot. Require a complete stable profile and no active operation. Clone the
complete stable profile, set only `method: dlss`,
`qualityMode: hoshipa`, `renderScaleMode: true`, and dormant
`fsrRuntime: fsr3`, and preserve its `dlssProfile`. Begin a baseline
qualification and dispatch it immediately before applying the profile with the
snapshot's exact `stateRevision`, exact Build ID, unique baseline client and
command IDs, `purpose: direct`, and `persistence: runtime_only`.

Wait for the operation and a strict DLSS Hoshipa qualification to complete,
returning immediately on success with 30,000 ms only as the deadline. Require
coherent DLSS evaluation in both eyes, correct scaled dimensions, exact
generation/resource ownership, clean mutation and lifecycle state, and no
terminal failure. Stop the baseline-only stress session.

Now arm one fresh measured Simple CSM telemetry set in a bounded fan-out:
stress, texture lifetime, load presentation, provider lifecycle, resource
publication, preparation, CPU, GPU, profiler, fidelity, stereo, retry,
failure, memory, and queue evidence. Reset and require CPU/GPU capture to be
inactive and pre-arm only the profiler. Start CPU, GPU, and profiler timing
immediately before measured transition 1; that first measured apply, not the
positioning COC or initial-state apply, is their timing origin.

## 3. Exact public-API transition primitive

For each matrix entry, use unique transition, qualification, client, and
command IDs. Preserve every response even when it is anomalous.

1. Wait exactly 5,000 ms server-side.
2. Read the authoritative API snapshot and record its Build ID, session ID,
   `stateRevision`, profile-presence flags, complete configured/requested/
   applying/effective/stable/persisted profiles, conditions, operation state,
   and physical dimensions.
3. Require a complete stable active profile. Clone it; mutate only `method`,
   `qualityMode`, and `renderScaleMode` from the destination. For FSR entries
   also set `fsrRuntime: fsr3`. Preserve the current `dlssProfile` and preserve
   dormant `fsrRuntime` on None, TAA, DLAA, and DLSS entries.
4. Call `qualification_begin` for timing ownership. This does not select a
   profile and does not create a vendor target.
5. On transition 1 only, start the pre-armed profiler immediately before
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
8. For vendor destinations, call `qualification_wait` in Dragonsreach with the
   exact vendor target, fixed foveation fixture, `milestone: strict`, and
   `timeoutMs: 30000`. Map quality strings to qualifier values
   `native_aa=0`, `hoshipa=1`, `ultra_quality=2`, `quality=3`, `balanced=4`,
   `performance=5`, and `ultra_performance=6`. Include configured
   `fsrRuntime: fsr3` only for FSR; physical backend proof remains separate.
9. For None and TAA, wait up to 30,000 ms for the public operation to complete
   and the existing DevBench `upscalingStable` barrier in Dragonsreach to
   return. Both waits return as soon as satisfied. Do not call a vendor
   qualification waiter or manufacture a DLSS/FSR target. Then release the
   timing-only qualification owner with `qualification_cancel`; its expected
   cancellation receipt closes the bracket and is not a render failure.
10. Read the operation, transition-filtered API events, authoritative API
    snapshot, render-scale status, preparation trace, and applicable DLSS
    trace. Inspect the completed transition before allowing the next apply.

Every entry has exactly one begin, one dispatch, one apply, and one terminal
qualification receipt: a strict waiter receipt for a vendor destination or an
expected timing-owner cancellation after None/TAA stability. The public API
must be the sole mutation path. Do not open the CS menu and do
not call `communityshaders.renderscale` action `apply`. No external
frame-timing source is used.

## 4. Completion and evidence rules

For DLSS, DLAA, FSR render scale, and FSR Native AA require requested, API,
and physical profiles to agree; correct native or scaled dimensions; coherent
both-eye presentation; exact provider generation and resource ownership; and
strict completion. Record first physical-profile match, first coherent stereo
presentation, `presentationStable`, `cleanupDrained`, and strict completion
separately. Cleanup may follow presentation and must not replace its timing.

For None and TAA require the public operation to complete; the authoritative
method to be exact; `qualityMode: native_aa`; `renderScaleMode: false`; native
physical dimensions; advancing coherent in-world `upscalingStable`; no
unresolved physical mutation; and no vendor evaluation treated as the active
presentation. If the receipt cannot expose an exact native presentation
generation, record that named tooling gap and classify generation proof
`INCONCLUSIVE`; do not derive or fabricate it.

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

Unsupported preparation providers are `n/a`, never zero. Preserve raw values
before summarizing. Archive any log before reading it under the repository's
log-preservation contract.

## 5. NVIDIA verdict and output

DLAA must remain distinguishable from TAA and None and must perform coherent
native-resolution DLSS evaluation. TAA and None must not retain DLSS as the
active presentation. Every FSR destination must retain configured FSR3 and
resolve coherently to `fsr_host` or `fsr_runtime`; `fsr4_runtime` is a failure.
Changing the logical native method must not retain the previous vendor.

No exact temporal/input tuple may receive duplicate Streamline evaluation. A
single `eErrorDuplicatedConstants` or stretch fallback is preserved as a
semantic anomaly and allowed to recover within the current 30-second deadline;
it is not an immediate protocol abort. Fail the transition if it becomes a
terminal error, violates ownership/fidelity, or misses the deadline. Never
accept stale DLSS output after destructive mutation. A proven old provider may
remain active only before mutation begins.

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
