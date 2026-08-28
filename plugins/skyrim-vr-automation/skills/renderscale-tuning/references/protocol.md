# Render-scale tuning protocol

This is a correctness assay, not the Simple CSM throughput sweep. It proves
that a queued, deferred, refused, or preparing replacement cannot suppress the
last exact resource-proven stereo presentation before destructive mutation,
and that the old generation is never used after it becomes unsafe.

The transition model is fixed:

- A: the old generation is proven and currently presented.
- B: its replacement is blocked or preparing, with no destructive mutation.
- C: destructive mutation begins and the new contract is published.

During B, both eyes must retain the proven old generation. During C, the old
generation becomes inadmissible and presentation must fail closed until both
eyes prove the new generation.

## 1. Bind, discover, and prepare

Use the Simple COC identity path to bind the exact Skyrim VR PID, DevBench
endpoint, DLL Build ID, physical artifact path, artifact SHA-256, and producer
identity. List the current tools and retain their authoritative descriptions
before testing. Use unique run, stress, owner, transition, request, and trace
identities.

Run the single runtime-only `prepare_coc` action before the positioning COC.
Its receipt must prove debug logging plus the FOV/TAA `0.3/0.3/0.7` fixture.
It must not change DLSS, FSR, FSR4, quality mode, preset, render scale, or any
VR FPS Stabilizer setting.

Require a known shader-cache identity and record each row as `warm` or
`deliberately-deferred`. Never interrupt shader compilation. Keep Tracy,
DevBench CPU telemetry, DevBench GPU telemetry, and the profiler off for the
complete correctness assay. An exposed performance lane that is already
active must be stopped before the assay or the run is `BLOCKED`.

Before the first mutation, prove that the live responses directly expose all
fields in section 3. Field names may move within a versioned response, so
retain the schema/tool-description receipt and an exact raw JSON field-path
map for that Build ID. Do not derive a missing value from counters or related
fields. Stop before mutation when a core field is absent.

Position once with `coc WhiterunDragonsreach`, wait 10,000 ms server-side, and
require an advancing in-world frame in the exact cell with no blocking menu.
The positioning COC is not a measured transition. Establish DLSS enabled,
numeric quality mode 3 (Quality), a fixed viewpoint, strict stability, clean
provider lifecycle, no unresolved physical mutation, and no recovery. Both
eyes must report the same vendor path and contract generation.

Arm one fresh render-scale stress/event session plus the supported bounded
texture-lifetime, load-presentation, preparation, provider-lifecycle, and DLSS
trace lanes. Do not arm or start CPU, GPU, Tracy, or profiler capture. Record
one complete initial status and the initial log boundary.

## 2. Menu-close transition primitive

Community Shaders menu changes take effect after the menu closes. Each
measured replacement therefore uses one bounded, fail-closed server scenario
with `continueOnError: false` in this exact order:

1. `qualification_begin` with the run owner and unique transition ID.
2. One server-owned 5,000 ms settling wait.
3. `communityshaders.menu open`; require menu ownership.
4. Issue exactly one CS-menu-origin render-scale `apply` for the selected
   replacement while the menu remains open. Retain its exact request ID,
   transition epoch, disposition, and admission result.
5. Read one bounded pre-close status/event checkpoint. This is the required B
   interval; it must prove that no destructive mutation has started and both
   eyes still use the exact old generation. Do not poll for it.
6. `qualification_dispatch` with the same owner/transition and
   `startPerformanceTelemetry: false`. Record its server QPC immediately
   before the next action.
7. `communityshaders.menu close`. This releases the queued change and is the
   measured mutation origin.
8. `qualification_wait` for the exact cell, exact target profile, fixed
   foveation fixture, and `milestone: "strict"`, with `timeoutMs: 30000`.
   The event-driven waiter must return as soon as strict completion occurs;
   30 seconds is only its upper bound.
9. Read one final render-scale status plus transition-filtered bounded events.
10. Close the per-transition DLSS trace when the selected provider is DLSS.

Embedded tool errors are failed steps. A failed step must abort that scenario
and no later menu close or mutation may execute. Inspect each completed
transition before issuing the next one so terminal failures cannot be hidden
inside a longer batch. Never send a direct recovery apply.

## 3. Mandatory raw telemetry

Preserve the initial snapshot, pre-close checkpoint, apply receipt,
qualification receipt, final snapshot, transition events, preparation events,
stress receipt, and applicable provider trace. For every transition, extract
the following values directly and retain their raw response paths:

### Admission and presentation ownership

- `currentPresentationProven` and `currentPresentationGeneration`;
- current-presentation D3D device identity and provider resource generation;
- replacement request ID and replacement transition epoch;
- `replacementAdmissionBlocked` and every exact
  `replacementAdmissionBlockReasons` value;
- preparation state and outcome, including admission and every early-exit
  reason;
- provider lifecycle state;
- earliest destructive provider invalidation, dirtying, teardown, or resource
  destruction, including `physicalMutationStarted` frame and QPC;
- engine-target creator entry and unresolved physical mutation;
- selected presentation disposition;
- actual left-eye path and generation and actual right-eye path and generation;
- completed-output reuse, strong ownership, identity, and immutability proof.

`physicalMutationStarted` means the earliest destructive change to the current
presentation contract. Engine-target creator entry alone is too late and may
not substitute for it.

### Publication and completion

- current, completed, and published publication generation;
- published width and height versus expected width and height;
- publication `complete` and deferred-setup acknowledgement;
- D3D device match and D3D context match;
- new contract publication generation;
- first presentation-stable frame and QPC;
- first cleanup-drained frame and QPC;
- strict-completion frame and QPC.

Keep the producer's boolean dimension match when present, but retain all four
raw dimensions too. Never recreate `dimensionsMatch` with protocol-side math.

### Preparation timing and failures

- admission time and each early-exit category;
- shader-cache wait time and cache outcome;
- SSS and SSGI prewarming time and outcome;
- DLSS, FSR, and FSR4 preparation time and outcome, including unsupported
  providers as explicit `n/a` rather than zero;
- D3D object-creation time and outcome;
- total preparation time;
- request-to-prepared latency;
- prepared-to-creator latency;
- retry count, queue/work-gate state, memory admission, retirement/cleanup
  debt, bounds state, vendor result, and terminal failure state.

Retain every Simple CSM resource-publication, texture-lifetime,
load-presentation, fidelity, stereo, retry, memory, queue, provider-lifecycle,
and preparation field that is still exposed. The list above strengthens that
contract; it does not discard useful existing fields.

When a CSX log must be read, first copy its original bytes to
`D:\Coding\GitHub\CS logs` using the repository log-preservation naming
contract, then verify byte length and SHA-256. Record the archived path.

## 4. Primary practical assay

Run exactly three complete DLSS pairs in Dragonsreach:

1. Quality (3) to Balanced (4).
2. Balanced (4) to Quality (3).

Use the menu-close primitive for all six transitions. Before menu close, the
old provider resource and device must remain exact and both eyes must either
evaluate that provider or reuse one exact, strongly owned, immutable completed
stereo output. A queued request, incomplete preparation, work gate, memory
refusal, nonblocking trim, or unrelated retirement debt must not by itself
select black keepalive or stretch during an ordinary world frame.

After destructive mutation, never evaluate the old provider or reuse its
completed output without explicit continuing ownership and immutability proof.
Recovery, stretch, black keepalive, or quarantine is permitted only when the
new state requires it. The next normal vendor presentation must use the newly
published generation in both eyes. Presentation stability may precede cleanup;
strict completion requires both.

## 5. Fifteen-row coverage matrix

Report every row. Execute only supported safe states; never fabricate a
deferral or create unsafe pressure merely to fill the matrix.

| Row | Current/replacement and context | Required observation |
|---:|---|---|
| 1 | Warm DLSS Quality to Balanced, ordinary world | Old DLSS until mutation; coherent new DLSS after it |
| 2 | Warm FSR Quality to Balanced, ordinary world | Old FSR until mutation; coherent new FSR after it |
| 3 | DLSS with required SSGI/SSS preparation incomplete | Old DLSS remains active until preparation completes |
| 4 | FSR/provider preparation deferred | Protected old-FSR handoff |
| 5 | Memory admission refused | Old generation remains active; no mutation before admission |
| 6 | Natural work gate, nonblocking trim, or unrelated retirement | Cleanup debt does not control current presentation |
| 7 | Cross-provider DLSS to FSR | DLSS until invalidation, protected fallback, coherent FSR |
| 8 | Current proof missing, dirty, or wrong generation | Never evaluate unproven provider; use fail-safe presentation |
| 9 | Teardown started before engine creator | Old provider is inadmissible immediately |
| 10 | Creator entered or physical mutation unresolved | Previous generation is never treated as current |
| 11 | New contract published | Both eyes use the new generation |
| 12 | Replacement queued across CS menu open/close | Menu composition allowed; old generation resumes after close only if still unmutated |
| 13 | Loading/post-load cover, Breezehome door then controlled COC route | Cover/stretch allowed; stable handoff to new generation |
| 14 | Main menu or RaceSex ownership | Context fallback allowed; replacement remains deferred |
| 15 | Native or fixed-vendor current contract with deferred replacement | Native/fixed presentation stays truthful; invent no provider proof |

Use a task-specific cache missing only required SSGI/SSS permutations for row
3 and never interrupt compilation. Use warm same/cross-provider transitions
for provider deferral. Capture row 6 only when the gate occurs naturally. Run
row 5 in game only with an advertised safe DevBench admission fixture or a
naturally reproduced condition; otherwise require its focused offline policy
test and mark in-game evidence `BLOCKED`. Rows 8 through 10 and 14 likewise
require an advertised safe fixture or natural bounded observation. Row 13 may
use the preserved Breezehome door route followed by the controlled
WindhelmExterior01/WhiterunDragonsreach route only after separate explicit
authorization; otherwise report it `BLOCKED` in the base run.

## 6. Stop, classify, and report

Stop task-owned traces and sessions after the selected matrix completes or at
the first terminal failure. Preserve all evidence before cleanup. Do not
change the final profile merely for tidiness.

Classify each transition and every matrix row as `PASS`, `FAIL`, `BLOCKED`, or
`INCONCLUSIVE` with exact evidence paths:

- `PASS`: exact old provider remains stereo-usable before mutation;
  replacement failures do not erase current proof; no mixed eyes/generations;
  no queue-only ordinary-world black/stretch; old provider is never used after
  mutation/device/resource invalidation; recovery fails closed; both eyes
  converge on the new publication; strict completion succeeds; and there is
  no OOM, device loss, fidelity/bounds mismatch, vendor failure, or terminal
  fallback.
- `FAIL`: mixed-eye/generation presentation; old-provider use after mutation;
  acceptance of wrong device/resource/publication; queue-only ordinary-world
  black keepalive; stale completed-output reuse without ownership proof; or
  any hard render-scale, OOM, device-loss, fidelity, bounds, or vendor failure.
  Stop further mutations immediately.
- `BLOCKED`: a required schema field, safe fixture, controlled context, exact
  identity, or supported action is unavailable before the row begins.
- `INCONCLUSIVE`: the pre-mutation event interval was missed, earliest
  invalidation cannot be distinguished from creator entry, disposition or
  per-eye generation is unavailable after dispatch, requested deferral did not
  occur, or cache/profile state drifted.

The summary must include exact identity, cache state, performance-lane-off
proof, all raw field-path mappings, six primary transition records, the
15-row matrix, terminal failures, and immutable evidence paths. Visible image
quality alone is never proof.

## 7. Explicit acceptance extension

Run this section only for `renderscale-tuning acceptance`. After the core
correctness assay, invoke the existing complete 20-transition render-scale
qualification without weakening its evidence contract. Preserve its complete
evidence directory and `csx-render-scale-pr-v1` summary. Require zero hard
failures, OOM, device loss, fidelity mismatch, vendor failure, and
bounds-mismatch fallback; Dragonsreach at most 24 frames; Windhelm at most 20;
mean at most 22; worst at most 24; at most 9 retries; at most 428 stretch-target
observations; and no more than 18 consecutive stretch frames.

Run the separate read-only external SteamVR frame-timing comparison against
the `main-VR` baseline with identical settings, scene, cache, and runtime.
Keep in-game profiling off in both comparison runs. Report every acceptance
threshold and evidence path; do not turn absent external evidence into a pass.
