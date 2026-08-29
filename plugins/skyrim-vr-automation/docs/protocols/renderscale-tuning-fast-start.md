# Render-scale tuning fast start

This shared startup contract applies identically to the NVIDIA and AMD tuning
skills. It is complete for all work through exact Dragonsreach positioning.
Do not read Simple COC or Simple CSM instructions for either tuning assay.

## Direct lane and startup budget

Use only callable plugin-provided tools whose names start with
`mcp__devbench_vr__`. Inspect their current in-memory descriptions, including
deferred tools, as the schema inventory. Do not inspect plugin cache paths,
manifests, marketplace files, or the bundled controller during a live run.
There is no fallback transport and no lane switching.

Before the first live request, create one unique evidence root named
`.tmp/renderscale-tuning-<vendor>-<UTC>-evidence` with `raw/startup`,
`raw/baseline`, `raw/transitions`, and `raw/finalization` children. Create
`receipt-index.json` there. Each direct MCP response must be written as its
exact decoded JSON response body before the next mutation; request identity,
tool/action, lane, transition, relative path, byte length, and SHA-256 belong
in the index. Transcript references and MCP/store keys are supplemental only
and are never durable evidence paths. A receipt that cannot be written and
rehash-verified stops future mutations; preserve the write failure and perform
only ownership-guarded cleanup that is already safe.

Start a local monotonic startup budget with the first live request. The
positioning scenario must be accepted within 30 seconds. Its required
post-COC 10,000 ms settle is outside that dispatch budget. A successful call
returns immediately; never wait out a fixed retry window.

Before positioning, use only these request rounds:

1. One parallel read-only batch containing direct `ping`, `inspect health`,
   `inspect state`, `communityshaders.upscaling_api registry`, `capabilities`,
   and `snapshot`. Retain every receipt. Require one live Skyrim VR PID, a
   loaded player, the exact CSX Build ID/producer, and the requested adapter
   vendor. Require every action and field used by the lane, including
   `qualification_wait` with `target.method` values `none`, `taa`, `dlss`, and
   `fsr`. If a read returns 429/502/503/504 while the off-thread health receipt
   remains exact, retry only the failed read once immediately within the same
   startup budget. No fixed sleep or availability waiter is permitted.
   Require the direct render-scale tool description to advertise independent
   `milestoneTimings` and the `replacementTimeline`; otherwise stop with
   `plugin_contract_outdated` before the fixture or COC.
2. Call `communityshaders.menu prepare_coc` exactly once and alone. It is the
   first stateful call. Require the runtime-only FOV/TAA `0.3/0.3/0.7` fixture,
   debug logging, and `persisted: false`. It must not change DLSS,
   FSR, render scale, or any VR FPS Stabilizer setting.
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

Persist the positioning terminal response and all three post-position
admission rounds under `raw/startup`. Persist the baseline begin/dispatch/apply
scenario, strict waiter, and owner-handoff responses under `raw/baseline`.
Index and rehash each batch before its next mutation. The evidence bundle is
invalid if these response bodies exist only in the transcript.

The positioning scenario is the only `async: true` scenario in the assay.
Every mutation, admission, reset, and ownership scenario remains synchronous
with `async: false` and `continueOnError: false` so embedded tool failures stop
the sequence.

## Post-position admission

After exact-cell positioning, perform exactly three client request rounds:

1. Query profiler `registry` and `snapshot` together as one parallel read-only
   batch. A transient response gets only one immediate retry of the failed
   read within the immediate-return 10-second recovery budget; it does not
   start an availability waiter or another transport.
2. Run the one-step negative profiler scenario using profiler `start_capture`
   with its required identity fields but without `frameCount`. It must return
   step
   `ok: false`, scenario `aborted: true`, `stepsRun: 1`, and embedded
   `invalid_field` for omitted `frameCount` with `continueOnError: false`.
3. Run one synchronous fail-closed scenario containing each supported reset
   action exactly once in serial order: render-scale `reset`,
   `texture_lifetime_reset`, `probe_reset`, `dlss_trace_reset`,
   `cpu_performance_reset`, `gpu_performance_reset`, and profiler
   `clear_history`. Retain the per-step receipts and require every capture
   inactive.

A failed proof or reset stops before baseline mutation. Never repeat successful
admission work.

## Baseline and measured-owner handoff

Reuse the post-position public snapshot and its exact `stateRevision` when it
is complete, has no active operation, and still matches the bound Build ID.
Admission resets do not justify another snapshot.

Start the baseline with one synchronous fail-closed scenario containing the
baseline-only stress start, `qualification_begin`, `qualification_dispatch`
with `startPerformanceTelemetry: false`, and the immediately following public
API `apply`. Then call the strict target-correlated `qualification_wait` once
with only the remaining portion of the single 30,000 ms QPC deadline. It must
return as soon as strict coherence succeeds; do not add an operation poll,
receipt sleep, or second 30-second window.

Only after strict waiter success, use one synchronous fail-closed handoff
scenario to stop the baseline stress session with its exact ownership guard,
start the measured stress, texture-lifetime, and load-presentation owners, and
pre-arm the profiler with `set_enabled`. This does not start a profiler
capture; the lane protocol starts that capture immediately before transition
1 dispatch. Retain every owner receipt. CPU and GPU performance captures must
remain inactive: transition 1's `qualification_dispatch` is their sole
reset/start and timing origin. A failed baseline waiter starts no measured
owner; stop only the baseline stress session with its ownership guard and
follow the lane's terminal failure rules.
