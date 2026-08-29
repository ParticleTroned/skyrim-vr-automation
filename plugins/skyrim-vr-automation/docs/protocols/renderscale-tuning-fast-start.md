# Render-scale tuning fast start

This shared startup contract applies identically to the NVIDIA and AMD tuning
skills. It is complete for all work through exact Dragonsreach positioning.
Do not read Simple COC or Simple CSM instructions for either tuning assay.

## Direct lane and startup timing

Use only callable plugin-provided tools whose names start with
`mcp__devbench_vr__`. Inspect their current in-memory descriptions, including
deferred tools, as the callable action and input-schema inventory. Tool
descriptions do not advertise result fields; validate output evidence only in
the structured receipt from the action that owns it. Do not inspect plugin
cache paths, manifests, marketplace files, or the bundled controller during a
live run. There is no fallback transport and no lane switching.

The first live action after reading this contract is the parallel five-read
DevBench batch below. Start it immediately. Before that batch, do not create a
directory, file, `.gitkeep`, receipt index, timer file, script, or other local
artifact; do not run a local command; and do not announce readiness. No local
evidence setup may delay the first DevBench request.

After all five read-only responses return, create one unique evidence root
named `.tmp/renderscale-tuning-<vendor>-<UTC>-evidence` and write the five
receipts directly to their final `raw/startup` paths. Create required parent
directories implicitly with those writes, then create `receipt-index.json`.
Do not create an empty directory tree or placeholder files first. Complete
this as one local evidence action before `prepare_coc`.

Each direct MCP response must be written as its exact decoded JSON response
body before the next mutation; request identity, tool/action, lane, transition,
relative path, byte length, and SHA-256 belong in the index. Transcript
references and MCP/store keys are supplemental only and are never durable
evidence paths. If initialization, writing, or rehash verification fails, stop
before `prepare_coc`; preserve the failure. Because the batch is read-only, a
local evidence-creation failure here requires no game cleanup. A receipt that
fails after assay ownership exists permits only ownership-guarded cleanup that
is already safe.

Start `startupReadElapsedMs` immediately before dispatching the parallel
read-only batch and stop it as soon as the final response returns. A result
over 10,000 ms is the preserved `slow_startup_reads` efficiency anomaly, not
an admission failure when every required read succeeded and its identity and
state are coherent. A successful batch never waits out a fixed window.

After the startup receipts pass and are rehash-verified, continue directly to
`prepare_coc` without progress commentary, a schema refresh, or another model
pause. Attempt to start a fresh monotonic `positioningDispatchElapsedMs`
measurement immediately before `prepare_coc`. Its 30,000 ms value is an
efficiency target, not an admission gate. Record `slow_positioning_dispatch`
when an accepted scenario exceeds the target. If the timer was not started,
record
`positioning_dispatch_timer_not_started`, store the elapsed value as `null`,
and dispatch immediately; never stop or delay a valid assay solely because
this client-side startup metric is unavailable. Only failure to obtain an
accepted positioning `runId` within the bounded tool call blocks the assay.
The required post-COC 10,000 ms settle is outside this measurement, and
startup-read time never contributes to it.

Write both elapsed fields and their optional efficiency anomalies into
`receipt-index.json` and the final summary; do not reconstruct missing values
later from frame numbers or transcript timestamps. This startup measurement
never replaces or changes transition 1's authoritative CPU/GPU timing origin.

Before positioning, use only these request rounds:

1. One parallel read-only batch containing direct `inspect health`, `inspect
   state`, `communityshaders.upscaling_api registry`, `capabilities`, and
   `communityshaders.renderscale status`. Retain every receipt. Do not add
   `ping`: the required health read is the stronger liveness proof. Do not add
   a pre-position API snapshot: the positioning scenario owns the first
   snapshot used by admission and baseline.
   Require one live Skyrim VR PID, a loaded player, and the exact CSX Build
   ID/producer. Require `status.adapter.available: true` from the render-scale
   status receipt and exact `status.adapter.vendorId`: `0x10DE`/4318 for the
   NVIDIA lane or `0x1002`/4098 for the AMD lane. A generic process inventory,
   adapter description string, or upscaling API receipt is not authoritative
   GPU identity. Require every callable action and input field used by the
   lane, including `qualification_wait` with `target.method` values `none`,
   `taa`, `dlss`, and `fsr`. Do not search the tool descriptions for output
   fields such as `milestoneTimings` or `replacementTimeline`. If a read
   returns 429/502/503/504 while the off-thread health receipt remains exact,
   retry only the failed read once immediately. The retry remains part of
   `startupReadElapsedMs`; it does not borrow from the fresh positioning
   budget. No fixed sleep or availability waiter is permitted.
2. Call `communityshaders.menu prepare_coc` exactly once and alone as a
   request. It is the first stateful call, but it must not occupy a separate
   model/action turn from the immediately following positioning submission.
   Require the runtime-only FOV/TAA `0.3/0.3/0.7`
   fixture, debug logging, and `persisted: false`. Compare each of
   `after.foveation.foveatedCenterArea`, `peripheryTAACenterArea`, and
   `peripheryTAAOuterScale` numerically with absolute tolerance `0.000001`;
   ordinary binary32 serialization drift within that tolerance is valid.
   Require all booleans, readiness, logging, and persistence fields exactly.
   Validate the already-decoded response and rehash its one durable write in
   the same orchestrated turn; do not reread the file, emit progress
   commentary, return for model deliberation, or pause for a second fixture
   check before the positioning scenario. It must not change DLSS, FSR, render
   scale, or any VR FPS Stabilizer setting.
3. Immediately submit one `scenario` with `async: true`,
   `continueOnError: false`, and these ordered steps:
   - `console exec` with exactly `coc WhiterunDragonsreach`;
   - a fixed 10,000 ms wait;
   - `inspect state`;
   - `inspect scene`;
   - `menu list`;
   - `communityshaders.upscaling_api snapshot`;
   - `communityshaders.renderscale status`;
   - `communityshaders.renderscale qualification_status`.

Any unresolved readiness or fixture failure stops before the COC and asks the
user. Do not add another readiness check, schema refresh, profiler query,
telemetry action, screenshot, or status call before the scenario is queued.

## Overlap the mandatory settle

As soon as the async scenario returns its `runId`, read the selected lane's
matrix and full protocol completely while the server performs the 10,000 ms
settle. In the same interval, persist and index the startup round,
`prepare_coc`, and positioning-acceptance receipts. Do not wait first. After
both files are loaded, query that `runId`.
If it is still running, query status at most once per second until the settle
plus a five-second receipt envelope expires. Never send a second COC.

The terminal transcript must prove exact `WhiterunDragonsreach`, a loaded
player, advancing in-world frames, no blocking menu, unchanged PID/Build ID,
no active qualification, and an authoritative public snapshot. Reuse these
receipts for post-position admission and the initial baseline. Do not repeat
the same state, scene, menu, render-scale, or API reads merely to reconfirm
them.

Persist the positioning terminal response and the post-position reset scenario
under `raw/startup`. Persist the baseline begin/dispatch/apply
scenario, strict waiter, and owner-handoff responses under `raw/baseline`.
Index and rehash each batch before its next mutation. The evidence bundle is
invalid if these response bodies exist only in the transcript.

The positioning scenario is the only `async: true` scenario in the assay.
Every mutation, admission, reset, and ownership scenario remains synchronous
with `async: false` and `continueOnError: false` so embedded tool failures stop
the sequence.

## Post-position admission

After exact-cell positioning, run one synchronous fail-closed scenario
containing each supported reset action exactly once in serial order:
render-scale `reset`, `texture_lifetime_reset`, `probe_reset`,
`dlss_trace_reset`, `cpu_performance_reset`, `gpu_performance_reset`, and
profiler `clear_history`. Retain the per-step receipts and require every
capture inactive. A failed reset stops before baseline mutation.

Do not query profiler `registry` or `snapshot`, and do not run a deliberately
invalid profiler scenario during an assay. Schema validation and embedded-error
propagation are DevBench offline tests; repeating them here adds latency without
measuring the running build. On reset success, continue directly into the
baseline sequence below in the same orchestrated action turn. Do not add
another read, progress update, or model pause.

## Baseline and measured-owner handoff

Reuse the post-position public snapshot and its exact `stateRevision` when it
is complete, has no active operation, and still matches the bound Build ID.
Admission resets do not justify another snapshot.

Start the baseline with one synchronous fail-closed scenario containing the
baseline-only stress start, `qualification_begin`, `qualification_dispatch`
with `startPerformanceTelemetry: false`, and the immediately following public
API `apply`. Without returning for model deliberation, call the strict
target-correlated `qualification_wait` once in the same orchestrated action
turn. Pass the full dispatch-relative `timeoutMs: 30000`; DevBench measures it
from `qualification_dispatch`. Never calculate or pass a client-side remaining
timeout. The waiter must return as soon as strict coherence succeeds; do not
add an operation poll, receipt sleep, progress commentary, or second 30-second
window.

A client-side serialization or receipt-delivery error is not a terminal
qualification result. Before writing evidence, reporting feedback, cancelling,
cleaning up, or pausing for commentary, read `qualification_status` once with
the exact `expectedBuildId`, then validate its returned ownership pair:

- If that exact owner is active with `phase: dispatched`, no waiter is active.
  Reissue the identical `qualification_wait` once immediately. Keep the same
  owner, transition, target, foveation, milestone, and full `timeoutMs: 30000`;
  the server's dispatch-relative deadline is unchanged. If this reissue returns
  `qualification_wait_active`, follow the `waiting` branch below.
- If that exact owner is active with `phase: waiting`, do not replay the
  waiter. Read only `qualification_status` through the original deadline, then
  allow at most five additional seconds to retrieve its already-terminal
  matching `lastEvidence`.
- If the owner is inactive and matching `lastEvidence` is present, use that as
  the terminal waiter receipt.

Any different owner, transition, Build ID, or missing terminal evidence after
that bound stops future mutations and asks the user. Never reapply the profile
or create a second measurement window. Record the client error after the
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
baseline stress session with its exact
ownership guard, start the measured stress, texture-lifetime, and
load-presentation owners, and pre-arm the profiler with `set_enabled`. This
does not start a profiler capture; the lane protocol starts that capture
immediately before transition 1 dispatch. Retain every owner receipt. CPU and
GPU performance captures must remain inactive: transition 1's
`qualification_dispatch` is their sole reset/start and timing origin. A failed
baseline waiter starts no measured owner; stop only the baseline stress session
with its ownership guard and follow the lane's terminal failure rules.
