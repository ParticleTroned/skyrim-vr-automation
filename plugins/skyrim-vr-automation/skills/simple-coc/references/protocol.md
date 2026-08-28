# Simple COC protocol

## Fixed assay

- Running game: Skyrim VR with the player loaded.
- Initial position: `WindhelmExterior01`, followed by one server-owned
  10,000 ms stabilization wait.
- Measured transitions: exactly 20 COCs, odd transitions to
  `WhiterunDragonsreach` and even transitions to `WindhelmExterior01`.
- Pacing: one server-owned 10,000 ms wait before every measured COC.
- Fixture: foveated center `0.3`, vendor dispatch enabled, periphery-TAA
  center `0.3`, periphery TAA enabled, outer scale `0.7`.
- Diagnostics: developer mode active and an `info` or less-verbose CSX log
  level raised to `debug`; an already-more-verbose level remains unchanged.
- Qualification: one strict waiter per transition, 30,000 ms timeout, no
  target profile. VR FPS Stabilizer owns profile selection.
- Scenario: one async DevBench scenario with `continueOnError: false`.
- Output: append one commit-headed column to
  `docs/development/vr-render-scale-comparison-ledger.csv`.

## 1. Bind DevBench and the build

Call DevBench health and require `SkyrimVR.exe`, `vr: true`, a live PID, and a
loaded player. Read the producer through `communityshaders.upscaling_api`
`snapshot`. Preserve the full Build ID, full source commit, source description,
dirty flag, configuration, shader-cache ABI, compiler identity, PID, and port.

As soon as health and the exact Build ID are bound, start one direct
`communityshaders.menu` call with
`{"action":"prepare_coc","expectedBuildId":"<exact Build ID>"}`. Run the
remaining read-only producer/capability discovery in parallel with that call.
Do not defer `prepare_coc` until after the Windhelm positioning COC
or telemetry arming, and do not call it a second time.

Require `ready: true`, `promptRequired: false`, and `persisted: false`. The
`after` receipt must prove:

- `vr: true` and `inGame: true`;
- `developerMode.active: true`, with logging at `debug` or an already-more-
  verbose level;
- foveated vendor dispatch enabled with center area `0.3`;
- periphery TAA enabled with center area `0.3` and outer scale `0.7`;
- startup-active VR FPS Stabilizer.

The call may idempotently change only developer logging and the runtime
FOV/TAA fixture. It must not save settings or change method, quality, preset,
render scale, or any other Stabilizer-owned policy. A rejected call, missing
fixture field, non-ready receipt, persisted change, or producer mismatch stops
the run.

Before any COC, tell the user that DevBench and the fixture are ready and print
the exact Build ID and source commit. Continue automatically after this update.
Bind every Community Shaders call to that exact Build ID. Fixture setup is
outside the measured window, which begins only at transition 1's atomic
`qualification_dispatch`.

## 2. Position at Windhelm

Run one server scenario containing:

1. `console` with `coc WindhelmExterior01`;
2. a 10,000 ms server wait.

After it completes, require the exact Windhelm editor ID and a loaded player.
Do not count this positioning COC among the 20 measured transitions.

## 3. Arm all relevant render-scale telemetry

Refresh the live tool schemas before the run. Required capture lanes are:

- render-scale stress events and transition metrics;
- strict qualification timing and health receipts;
- CPU performance telemetry;
- GPU performance telemetry;
- DLSS dispatch trace when the producer exposes it;
- texture-lifetime telemetry when the producer exposes it;
- load-presentation probe when it is exposed as a bounded DevBench capture;
- Community Shaders profiler status/timers when available.
- render-target resource-publication telemetry from the same render-scale
  status/qualification observation as each transition.
- bounded render-scale preparation telemetry, including raw events plus all
  admission/early-exit, shader-cache, SSS/SSGI prewarm, DLSS/FSR/FSR4, D3D,
  total, request-to-prepared, and prepared-to-creator timings.

Reset each supported capture lane before use. Start stress capture before the
first qualification. Start auxiliary trace, lifetime, probe, and profiler
lanes immediately before transition 1's dispatch. Transition 1 must set
`startPerformanceTelemetry: true`, which starts CPU and GPU telemetry on the
same dispatch frame as the first measured COC. Later transitions set it to
false.

Do not call memory trim, apply an upscaling profile, change a preset, or enable
an unbounded screenshot/readback stream. Those alter the assay rather than
measure it. If a named optional lane is absent, record `unsupported`; if it is
present but fails to arm, stop rather than silently downgrade the run.

## 4. Run the measured scenario

Start a fresh render-scale stress session. Generate one unique owner from the
Build ID and UTC time. For transition IDs 1 through 20, append this block:

1. `qualification_begin` with the exact owner and transition ID;
2. `{ "wait": 10000 }`;
3. `qualification_dispatch` with `cocCellEditorId` set to the odd/even
   destination; use `startPerformanceTelemetry: true` only on transition 1;
4. `qualification_wait` with the same owner/transition, exact expected editor
   ID, fixed foveation fixture, `milestone: "strict"`, `timeoutMs: 30000`, and
   no `target` field;
5. render-scale `status` with the exact Build ID. Retain its bounded
   `status.preparation` trace, filtered to the transition epoch returned by the
   waiter. This read occurs after strict completion and is not another waiter.

From the strict receipt's render-scale observation, extract current,
current/completed/published generations, expected/published width and height,
`complete`, `deferredSetupAcknowledged`, `deviceMatches`, and `contextMatches`.
Preserve missing fields as missing evidence; do not infer them from profile or
stereo telemetry.

Preserve the preparation ring/session/QPC metadata and original event objects,
including identity, generations, D3D device, profile, dimensions, frames,
occurrences, outcome/reasons, QPC duration, bytecode compilation, and D3D
creation. Summaries may aggregate those records but must not replace them.

The dispatch itself issues the only COC for that transition. Never add a
separate console COC. An exact block therefore produces one timing origin, one
COC, one strict result, and one post-wait telemetry snapshot. There must be
exactly 20 dispatch receipts, 20 waiter receipts, and 20 preparation status
receipts.

Preserve every result, including semantic anomalies. A successful waiter may
report an unsatisfied milestone; that is measured evidence. Stop future COCs
only when DevBench aborts the scenario or reports a transport, PID, build, or
required-tool failure.

## 5. Extract and finalize

After transition 20, while the exact control plane remains responsive:

1. Read health, final scene, upscaling snapshot, render-scale status,
   qualification status, profiler status, and all armed telemetry statuses.
2. Stop CPU, GPU, stress, trace, texture-lifetime, probe, and profiler captures
   only with the ownership guards returned when they started.
3. Retain the complete stress record, all 20 qualification results, trace and
   lifetime records, and the final health snapshot.

For Dragonsreach, Windhelm, and overall, calculate strict stabilization mean
frames and worst frames from the 20 waiter receipts. Sum recoverable retries
and classify their reasons. Also extract:

- fixed waits, scenario elapsed time, and harness overhead;
- presentation, cleanup, and strict timing per transition;
- hard failures, OOM, device loss, fidelity mismatches, lifecycle failures,
  and backend deferrals;
- session/lifetime stretch observations, completed episodes and frames,
  maximum stretch frames and QPC duration, vendor failures, and bounds
  fallbacks;
- render/output dimensions, scale, profiles, both-eye validity, lifecycle,
  latch/contract generations, full resource-publication telemetry, and final
  cell;
- per-transition and session preparation-stage events and timings, including
  ring overwrite/coalescing evidence;
- memory pressure, process-private growth, trims, retirement/fence state, and
  pending cleanup;
- CPU queue hold/wait metrics, strong-packet counters, GPU capture counters,
  trace results, texture-lifetime results, probe results, and profiler timers.

Stabilization means, worst frames, and retry totals are mandatory. If any is
missing, classify the run as interrupted and do not append a completed CSV
column.

## CSV contract

Read `docs/development/vr-render-scale-comparison-ledger.csv`. Keep `metric` as
the first column and never replace the pinned main-VR PrePR19 or RC166 columns.
Append the new run as the rightmost column. Use the full source commit as the
header; if that commit already exists, use
`<full-commit>__<yyyyMMddTHHmmssZ>` so CSV headers remain unique while the
commit stays visible at the top.

Populate every existing metric. Add new metric rows for newly emitted harness
data rather than discarding it, filling earlier columns with `n/a`. Use
`unsupported` only for a lane the loaded producer does not expose and `n/a`
only for information the producer genuinely did not emit. Include the full
Build ID, source description, dirty state, fixture, scenario identity, and
verdict. Edit the CSV with `apply_patch`, parse it after editing, and run
`git diff --check`. Do not build or run repository tests.

Add rows for preparation availability, retained/overwritten/coalesced counts,
and each named stage's record/occurrence count plus duration, bytecode, and D3D
timing summaries. Keep the complete raw preparation events in run evidence;
the CSV is a comparison view, not their replacement.

Finally, tell the user the run verdict and print the complete comparison table
for the two pinned references plus the newly appended run.
