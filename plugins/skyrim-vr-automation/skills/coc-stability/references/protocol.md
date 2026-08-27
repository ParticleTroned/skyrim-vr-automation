# Load-synchronized COC protocol

## Configured comparison fixture

- Use the start cell and exact COC target sequence selected by the user.
- Run the requested number of measured transitions.
- Do not use a fixed inter-transition delay.
- Default transition deadline: 120 seconds.
- Stability ends at the first coherent state that satisfies the applicable
  exact-cell, profile, lifecycle, and two-eye presentation contract.

Start-cell establishment is not a measured transition. If needed, issue one
isolated COC to the configured start cell, wait for the same stability barrier,
and only then start the diagnostic sessions and measured run.

## Non-overlap invariant

Exactly one transition may be unresolved. A console result of `queued: true`
proves only admission; it does not prove that the load completed.

For each measured transition:

1. Call `qualification_begin` with a unique transition ID and owner ID to
   preserve the source scene and diagnostic baselines.
2. Call `qualification_dispatch` with the same ownership pair to mark the
   server QPC/frame. Require its accepted receipt before submitting the exact
   `coc <target>` command, then call one bounded `qualification_wait` with that
   pair. The waiter continuously observes live state without returning each
   intermediate snapshot to the client. The dispatch acknowledgement is part
   of the measured absolute latency.
3. Require `playerLoaded` and the exact destination cell before testing CSX
   stability. This prevents the source world's still-loaded state from passing
   before the queued COC executes.
4. Stop the timer at the first coherent stable observation. Return that
   observation with one final upscaling snapshot and one render-scale health
   record.
5. Validate every top-level MCP response. When and only when the waiter reports
   `satisfied: true` and `outcome: stable`, preserve its evidence and dispatch
   the next transition. A monolithic scenario whose tool steps ignore semantic
   JSON failures is not an acceptable substitute.

Do not wait for loading-menu open/close events, query or manipulate menus, add
a fixed recovery delay, or transfer repeated full status responses. These are
not stability requirements and add observer overhead. If no direct MCP waiter
can evaluate this predicate server-side, stop fail-closed and report the
missing capability; do not substitute a PowerShell polling loop.

The exact target-cell requirement prevents the source world's cached loaded
state from satisfying the barrier before the queued `coc` executes.

## CSX stability definition

Shared requirements for every method:

- exact destination cell and loaded player;
- provider check complete;
- no active operation, restart requirement, loading transition, method
  transition, relatch, first-world-frame wait, post-load recovery, provider
  wait, or resource recovery;
- requested and effective profiles agree;
- positive render and display dimensions;
- no terminal failure, device loss, unresolved physical mutation, vendor work
  gate, pending memory trim, or resource retirement.

The stability decision uses the first internally coherent observation. The
diagnostic session remains continuous throughout the run, so historical
stretch, fallback, fidelity, lifecycle, and recovery counters are retained as
evidence but do not delay a currently stable frame.

When render-scale is active, additionally require:

- upscaling API flags say render-scale is both latched and active;
- render-scale mode and controller state are `active`;
- an authoritative stable physical contract matches the requested and
  effective method, quality, backend, and dimensions;
- stereo presentation is `stereo_proven` or `released`;
- both fidelity eyes are evaluated, valid, frame-coherent, and mismatch-free;
- both presentation eyes are valid, non-transitional, and use the same
  `VendorEvaluated` path;
- at least two consecutive both-eye vendor frames;
- for DLSS, the DLSS lifecycle is ready with resources and no failures;
- for FSR, both dispatch eyes and their backend converge, the runtime contract
  is ready, no runtime fallback is observed, and shader compilation is idle.

For native-resolution DLSS, FSR, TAA/AA, or DLAA, render-scale fidelity is
intentionally inactive. The render-scale controller may remain `Active` while
its applied and stable contracts are valid and inactive. Require render-scale
status to be disabled, latched/active flags to be clear, render and display
dimensions to match, and both presentation eyes to be valid, frame-coherent,
non-transitional, and on `NativeOriginal`. Requested, effective, and stable
native profiles must agree. Record the stereo-evidence class as
`native_pipeline_frames`; do not claim the stronger render-scale fidelity
contract.

Do not prescribe the method, quality mode, or render-scale policy. VR
Stabilizer, environment rules, or the user's setup may legitimately select a
different profile at each destination. Detect the effective mode and apply the
corresponding active or native-resolution stability checks.

## Diagnostic sessions

Before transition 1:

1. Verify the exact producer build ID and runtime identity.
2. Verify the render-scale stress session and CPU telemetry are inactive. Fail
   instead of taking over an existing capture, and preserve their retained
   stopped-session records before reset.
3. Reset and start the render-scale stress session, retaining its returned
   session identity for guarded stop/cleanup.
4. Reset and start `cpu_performance_*` telemetry when exposed. Retain its
   nonzero `cpuPerformance.sessionId`; status and stop must return that same
   identity, and stop must send it as `expectedSessionId`. A reset clears the
   inactive retained ID to zero.

These sessions measure continuously. Do not restart them between transitions.
The per-transition waiter observes their live state; it does not initiate a new
measurement.

After the final stability barrier, stop CPU telemetry and then stop the
render-scale stress session. The render-scale stop result contains the final
iteration record. Do not enable the load-presentation readback probe unless a
visual/readback experiment explicitly requires it; its extra GPU work would
contaminate a transition-throughput measurement.

## Performance result

For each transition report:

- target and ordinal;
- dispatch-to-first-stable elapsed milliseconds using the server QPC mark;
- dispatch and stable frames;
- profile signature, method, render-scale state, and stereo-evidence class;
- relatch/recovery, stretch, fallback, fidelity, and lifecycle deltas.

For the run report count, total time, minimum, median, mean, p95, maximum, and
transitions per minute. Transition latency is the primary throughput measure.
CPU telemetry is primary implementation cost evidence; GPU counters are
secondary context and must come from a separately controlled profiler capture
when requested.

Compare builds only when fixture, target sequence, transition count, settings,
method, viewport, stability thresholds, and diagnostics match exactly. Exclude
any run that times out, overlaps transitions, changes settings, or lacks the
final stable barrier.

When this protocol feeds revision 4 of the render-scale qualification, require
the complete `dlss_trace_status`, `dlss_trace_reset`, `dlss_trace_start`,
`dlss_trace_stop`, and `dlss_trace_read` lifecycle introduced by
`b46edeaed14c41ad41225641c3a4943f1db25db6`. Publish every immutable producer
JSON/CSV file, all 144 visual PNGs, and all six blinded image-model batch
records through the closed, hash-bound `automation-artifacts.json` inventory.
The same invocation must reopen that set, replay its identities and ordered
receipt bindings, derive render-scale latch from owner-bound telemetry, and
reject unlisted or altered artifacts. Baseline publication copies the selected
closed set and final review while flattening an earlier comparison to one
generation instead of recursively copying historical baselines.
