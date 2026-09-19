# frustrum: paired frustum fast-path assay

This variant of [gameft-sw](../gameft-sw/README.md) measures each requested
save twice, in the supplied order: fast path **OFF**, then reload the exact
same save with the fast path **ON**, then move to the next save. It changes
only `Experimental Frustum Fast Path`, not the depth-culling policy.

When the user says `frustrum`, ask this exact question unless save numbers
were supplied with the request:

> Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12.

Confirm readiness at the main loading screen, with fpsVR attached to
SteamVR, the headset fixed and the same campaign settings. Never start a
run merely because the protocol was created. Use the existing recorder
validation and campaign preflight; no build, deployment or heavy analysis
during measurement.

```powershell
pwsh ./tools/frustrum/Invoke-Frustrum.ps1 -SaveNumberText '08, 11, 09' `
  -FpsVrCmd '<fpsVR installation>/fpsVRcmd.exe' -ArchiveDirectory '<log archive>'
```

That example records six holds: `08 OFF, 08 ON, 11 OFF, 11 ON, 09 OFF, 09 ON`.
One save and repeated save numbers are supported. Each occurrence has its
own pair index and unique measurement ordinals; receipts cannot overwrite
each other. The toggle is applied before loading, outside the hold, and
the original setting is restored after the last hold or on failure.
It is never saved to the user's configuration file.

All other gameft-sw rules remain unchanged: one continuous fpsVR/WPR
capture, 60 seconds per observed world entry, final `[50,60)` statistics,
the existing CPU/GPU settling and spike definitions, health samples at
1/5/20/49/59 seconds and stop, scheduler tolerance 10 ms, and timing/health
results before physical build provenance and WPR analysis. Only the WPR
safety deadline scales with the doubled number of holds. No new in-hold
requests are added; existing receipts verify the requested/effective mode.

The current DevBench `single_traversal` schema 2 must be installed, with
verification disabled and no mismatch latch. Unknown/missing schemas,
unsupported builds, mode changes, or verification activity fail closed.
The Build ID from the wrapper's existing initial snapshot pins CSX calls.
Detached verification is a separate correctness check, not part of timing.
RC166 and resuming only one leg of a pair are unsupported.

The maintained runner and reporter are shared, not forked algorithms.
`frustrum-plan.json` and the per-leg markers identify OFF/ON receipts and
WPR intervals. `quick-summary.json` retains every available measurement;
`frustrum-summary.json` attaches pair/mode identity and completeness.
`frustrum-comparison.md` uses the unchanged game-ft comparator for CPU,
GPU, P95/P99, spikes/groups, settling, health and ON-minus-OFF deltas.
Incomplete pairs remain explicit and are not paired with another save.

Keep native-frustum telemetry settings equal between legs and retain their
raw receipts. Counter deltas apply within each leg because changing the
toggle advances collection generation. Sampled status cannot prove that
an unobserved transient toggle did not occur. Fixed OFF-first ordering may
favor the warmer second load; repeat the assay before claiming a gain.
Tracing/diagnostic overhead remains present in both legs.

Offline validation (no game, fpsVR or WPR controls):

```powershell
pwsh ./tests/frustrum_test.ps1
pwsh ./tests/gameft_stack_wait_test.ps1
pwsh ./tests/gameft_legacy_rc166_test.ps1
pwsh ./tests/gameft_package_test.ps1
```

## Depth-job backoff pair

The explicit `-DepthJobBackoff` option controls DevBench-only depth-job
backoff instead of Frustum Fast Path. One save is supported: `-SaveNumberText '13' -DepthJobBackoff`. Fast Path must already be OFF and stays OFF.
The same runner, OFF/reload/ON plan, 60-second holds, health schedule,
fpsVR calculations and WPR capture remain unchanged. Status must prove
installed/active detailed job collection and backoff schema 1. Each existing
health receipt verifies the selected mode and unchanged control/collection
generation; unknown state fails closed. Backoff is restored on exit, including
after a setter timeout. Reports explicitly label depth-job backoff OFF/ON.
The fixed OFF-first warm-up limitation applies. Pause activity must be checked
from counters afterward; enabled status alone does not prove execution.

For the separately requested six-mode depth-control matrix with one load per
save and 20-second settled-scene measurements, use [depthc](../depthc/README.md).
