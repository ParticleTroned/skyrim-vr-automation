# Load-synchronized COC protocol

## Configured comparison fixture

- Use the start cell and exact COC target sequence selected by the user.
- Run the requested number of measured transitions.
- Do not use a fixed inter-transition delay.
- Default transition deadline: 120 seconds.
- Default stability proof: two matching samples spanning at least five game
  frames.

Start-cell establishment is not a measured transition. If needed, issue one
isolated COC to the configured start cell, wait for the same stability barrier,
and only then start the diagnostic sessions and measured run.

## Non-overlap invariant

Exactly one transition may be unresolved. Never build a scenario containing
the complete alternating sequence. A console result of `queued: true` proves
only admission; it does not prove that the load completed.

For each measured transition:

1. Preserve the source scene, DevBench health, upscaling snapshot, render-scale
   status, and dispatch timestamp.
2. Start one asynchronous DevBench scenario containing only:
   - `console`: the exact `coc <target>` command;
   - wait for `Loading Menu` to open;
   - wait for `Loading Menu` to close;
   - wait until `playerLoaded`;
   - wait until `noBlockingMenu`.
3. Poll only that scenario run ID. Do not send another gameplay command.
4. If it does not complete within 120 seconds, stop the test fail-closed.
5. After it completes, invoke the bundled controller:

   ```powershell
   pwsh ./tools/devbench-control/Invoke-DevBenchControl.ps1 wait `
     -RuntimePath <exact-runtime.json> `
     -Condition upscalingStable `
     -ExpectedCell <exact-target> `
     -TimeoutSeconds 120 `
     -PollMilliseconds 100 `
     -StableSamples 2 `
     -MinimumStableFrameAdvance 5 `
     -EvidenceDirectory <task-evidence-directory> `
     -EvidenceLabel <transition-label>
   ```

6. Preserve the returned scene, profile signature, frames, stereo-evidence
   class, attempts, and elapsed time.
7. When and only when the barrier reports `satisfied: true`, dispatch the next
   transition immediately.

The exact target-cell requirement prevents the source world's cached loaded
state from satisfying the barrier before the queued `coc` executes.

## CSX stability definition

Shared requirements for every method:

- exact destination cell and loaded player;
- no blocking menu;
- provider check complete;
- no active operation, restart requirement, loading transition, method
  transition, relatch, first-world-frame wait, post-load recovery, provider
  wait, or resource recovery;
- requested and effective profiles agree;
- positive render and display dimensions;
- identical profile signature across consecutive advancing frames;
- no terminal failure, device loss, unresolved physical mutation, vendor work
  gate, pending memory trim, or resource retirement.

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
intentionally inactive. Require the render-scale controller to be idle and the
render-scale latched/active flags to be clear. Requested and effective native
profiles must agree across advancing world frames. Record the stereo-evidence
class as `native_pipeline_frames`; do not claim the stronger render-scale
two-eye contract.

Do not prescribe the method, quality mode, or render-scale policy. VR
Stabilizer, environment rules, or the user's setup may legitimately select a
different profile at each destination. Detect the effective mode and apply the
corresponding active or native-resolution stability checks.

## Diagnostic sessions

Before transition 1:

1. Verify the exact producer build ID and runtime identity.
2. Verify the render-scale stress session and CPU telemetry are inactive. Fail
   instead of taking over an existing capture.
3. Reset and start the render-scale stress session.
4. Reset and start `cpu_performance_*` telemetry when exposed.

After the final stability barrier, stop CPU telemetry and then stop the
render-scale stress session. The render-scale stop result contains the final
iteration record. Do not enable the load-presentation readback probe unless a
visual/readback experiment explicitly requires it; its extra GPU work would
contaminate a transition-throughput measurement.

## Performance result

For each transition report:

- target and ordinal;
- scenario load elapsed milliseconds;
- post-load CSX stability-barrier elapsed milliseconds;
- total transition-to-stable milliseconds;
- start and stable frames;
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
