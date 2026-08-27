# Deadline-driven COC stability protocol

## Fast start-cell establishment

At the moment the user confirms Skyrim VR is in-game, immediately queue one
async server scenario whose only steps are a 10,000 ms wait followed by exactly:

```text
coc WindhelmExterior01
```

Queue that deadline before any identity, status, capability, schema, or capture
call. While the server owns the 10-second clock, concurrently read the runtime
identity and exact CSX producer Build ID. Do not await one read before starting
the other, and do not add work after both finish. These reads may complete
early or late, but they never postpone the scheduled COC.

If the server does not accept the timed scenario, stop without substituting a
client sleep. After the COC step returns, wait for the load event and take one
exact-cell scene observation. Start-cell establishment is not measured and
does not yet assert render or stereo stability.

## One-time post-load fixture gate

Once Windhelm is loaded, invoke the direct `communityshaders.menu` tool once:

```json
{
  "action": "prepare_coc",
  "expectedBuildId": "<exact CSX Build ID>"
}
```

Require this receipt:

- `ready: true`, `promptRequired: false`, and `persisted: false`;
- `after.vr` and `after.inGame` are `true`;
- developer mode is active;
- foveated vendor dispatch is enabled;
- FOV center area is `0.3`;
- periphery TAA is enabled with center area `0.3` and outer scale `0.7`;
- VR FPS Stabilizer is startup-active for the session.

`prepare_coc` may idempotently correct developer mode and the FOV/TAA fixture
in memory. It must not save settings. Call it exactly once; do not repeat it in
the baseline or measured assay.

VR FPS Stabilizer exclusively owns all DLSS/upscaling changes. Never call
`communityshaders.renderscale` with `apply`, and never change method, quality,
preset, render scale, or dynamic policy through a menu or console command. The
protocol only observes and validates the profile selected by Stabilizer.

If this one-time action is missing, Stabilizer was not startup-active, or the
runtime fixture cannot be corrected, preserve the receipt and stop before
measurement because the assay fixture itself was never established.

## Baseline and profile fixture

After the gate, launch one parallel baseline bundle containing the exact scene,
the public upscaling snapshot, render-scale status, GPU telemetry status, and
any already-configured CSX image capture. Do not serialize these independent
reads. Do not probe for, install, or retry an optional capture provider on the
critical path; a missing provider is recorded while the user's in-headset
visual check and CSX two-eye fidelity evidence remain authoritative.

Require the exact cell, loaded player, stable lifecycle, expected
Stabilizer-selected profile, correct render/display dimensions, and applicable
two-eye presentation and fidelity evidence. Parallelism changes only latency,
never the fidelity predicate. This is the only pre-assay image-stability gate.

Use the approved Stabilizer fixture to define the expected profile for both
`WindhelmExterior01` and `WhiterunDragonsreach`. Do not derive a new target by
changing CSX. A later mismatch is recorded against the expected per-cell
profile and does not end the assay.

## Diagnostic sessions

Use the status records already returned by the parallel baseline bundle to
inspect render-scale stress, CPU telemetry, and GPU telemetry once. Do not issue
a second status chain and do not take over an active capture. Preserve retained
stopped-session evidence.

Start all diagnostics in one server setup scenario before transition 1. Within
each diagnostic, preserve reset-before-start ordering:

1. render-scale stress `reset` then `start`; retain `sessionId`;
2. `cpu_performance_reset` then `cpu_performance_start`; retain its `sessionId`;
3. `gpu_performance_reset` then `gpu_performance_start`; retain its nonnegative
   `startFrame`.

Keep all three sessions continuous across the complete assay. Do not restart
them between transitions and do not enable the readback probe.

## Deadline-driven measured assay

The measured run starts in `WindhelmExterior01`. Run exactly 20 alternating
transitions: odd ordinals target `WhiterunDragonsreach`; even ordinals target
`WindhelmExterior01`.

Use one async server-side scenario containing the complete transition sequence
so client round trips cannot create idle gaps. Set `continueOnError: true`
intentionally: every imperfect result or step error is assay evidence, and the
bounded 20-transition batch must not be rejected as fail-fast. For every
ordinal:

1. call `qualification_begin` with a unique transition ID and one run owner ID;
2. place `qualification_dispatch` immediately adjacent to the COC step with no
   intervening action, then dispatch exactly one `coc <target>`;
3. call `qualification_wait` once with the same ownership pair, exact target
   cell, expected Stabilizer profile, and `timeoutMs: 10000`.

The measured transition timer begins at the COC command. It excludes
`qualification_begin`, diagnostic setup, and all other preparation. The
adjacent dispatch marker arms the server QPC clock at that command boundary;
report the measurement as COC-to-first-stable or COC-to-deadline latency.

Advance immediately when the waiter returns a coherent stable state. If it
reaches the 10-second deadline, preserve the final observation and advance
immediately after the timed-out waiter releases its ownership. Do not add fixed
inter-transition waits, menu checks, or client-side polling.

A timeout, exact-profile mismatch, lifecycle delay, fidelity fault, or
presentation fault is a normal anomaly receipt. It affects the final verdict,
but the remaining transitions still run. This deliberately lets a faulty build
accumulate a useful error history.

Do not cancel the bounded server batch for a normal anomaly or a tool-step
error. If Skyrim exits, DevBench disappears, producer or diagnostic ownership
changes, a COC is rejected, or the waiter disappears, later guarded steps may
also return errors; preserve every receipt and let the fixed batch terminate.
A normal `qualification_wait` timeout is a semantic anomaly receipt, not a
reason to stop or restart the client-side orchestration. The final verdict is
interrupted when fewer than 20 COCs report `dispatched: true`.

## Stability interpretation

Shared stability requirements are exact destination cell and loaded player;
provider check complete; no active operation, restart requirement, loading or
method transition, relatch, first-world-frame wait, post-load recovery,
provider wait, resource recovery, device loss, unresolved physical mutation,
vendor work gate, pending trim, or resource retirement; agreed requested,
effective, and stable profiles; and positive render/display dimensions.

When render scale is active, require the owner-bound applied/stable physical
contract, correct method/quality/backend/dimensions, ready lifecycle, valid
two-eye fidelity, and at least two completed both-eye vendor presentation
frames. `ContractPublished` is a transient publication phase; steady-state
stability is proved by durable owner keys and matching applied/stable contracts,
not by requiring that transient phase to still be current.

For vendor presentation, use the last completed both-eye compositor frame and
cycle as the durable coherent pair. A snapshot may legitimately show one
current eye on the next frame/cycle while the other still represents that last
completed pair. Do not require the two instantaneous current-eye frame fields
to be identical. Reject stale completed-pair evidence, invalid paths, epoch or
generation mismatches, transition flags, and a snapshot where both current
eyes have moved beyond the recorded completed pair.

For native resolution, require valid frame-coherent `NativeOriginal` eyes,
inactive render-scale flags, matching render/display dimensions, and agreed
native profiles.

## Cleanup and final evaluation

After transition 20, always attempt owned cleanup while the control plane is
available:

1. `gpu_performance_stop` with the captured `expectedStartFrame`;
2. `cpu_performance_stop` with the captured `expectedSessionId`;
3. render-scale stress `stop` with the captured `expectedSessionId`.

Preserve all raw transition receipts and diagnostic final records. Report
requested and dispatched transition counts, stable and anomalous counts, each
ordinal/target/outcome/deadline/profile/stereo/lifecycle result, and CPU/GPU
telemetry. Compute latency statistics for stable transitions separately from
deadline-hit counts.

The verdict is `clean` only if all 20 transitions dispatched and stabilized
without anomalies. If all 20 dispatched but one or more were imperfect, the
verdict is `completed_with_anomalies`. Use an interrupted verdict only when a
real control failure prevented dispatching all requested transitions.
