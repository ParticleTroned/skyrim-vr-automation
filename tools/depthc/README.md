# depthc: settled-scene depth-control matrix

`depthc` is a separate, explicitly authorized assay. `gameft-sw` and
reload-paired `frustrum` retain their existing 60-second protocols.

Ask exactly unless save numbers were supplied:

> Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12.

Confirm main-menu readiness, fixed headset, fpsVR attached to SteamVR and
the intended build/settings. Do not start from a development request alone.
Use the established [gameft-sw recorder validation](../gameft-sw/README.md)
before loading; never restart the game, SteamVR or fpsVR to repair logging.

```powershell
pwsh ./tools/depthc/Invoke-DepthC.ps1 -SaveNumberText '08, 11, 13' `
  -FpsVrCmd '<fpsVR>/fpsVRcmd.exe' -ArchiveDirectory '<archive>'
```

Each chosen save occurrence is loaded **once**, in supplied order. Any number
of saves and repeated numbers are supported. In that same scene the runner
uses the versioned public upscaling API to test these six modes:

| Mode | Method / quality | Render scale |
| --- | --- | --- |
| DLAA | DLSS / native AA | OFF |
| DLSS-RS-OFF | DLSS / Hoshipa (q1) | OFF |
| DLSS-RS-ON | DLSS / Hoshipa (q1) | ON |
| FSR3-AA | explicit FSR3 / native AA | OFF |
| FSR3-RS-OFF | explicit FSR3 / Hoshipa (q1) | OFF |
| FSR3-RS-ON | explicit FSR3 / Hoshipa (q1) | ON |

DLSS model/preset is preserved from the loaded save; FSR3 is explicit, not
an inferred FSR4 fallback. Mode changes are runtime-only, revision-guarded,
preflighted and operation-confirmed. An unsupported/restart-needed mode,
unknown schema, changed profile or missing physical evidence aborts rather
than silently using another mode. The save's original profile and controls
are restored before advancing and on failures. No settings are saved. Two simultaneously enabled legacy/performance flags
are rejected before mutation because the supported menu normalizes them
and cannot restore that malformed combination exactly.

For **each mode**, measure these conditions in order. Each begins from the
Balanced baseline, so only one behavior variable differs:

| Condition | Change from baseline |
| --- | --- |
| Balanced | Master/interior culling ON; fast path and backoff OFF |
| Performance | Performance temporal-culling policy |
| Legacy | Legacy temporal-culling policy |
| Culling-OFF | Native master depth culling OFF |
| Interior-OFF | Interior depth culling OFF; explicit N/A on exterior saves |
| Frustum-fast-ON | Experimental frustum traversal fast path ON |
| Backoff-ON | DevBench depth-job backoff ON |
| Balanced-repeat | Return to baseline to expose time/cache drift |

Native count/detail diagnostics and temporal telemetry remain fixed across
conditions. Detailed native collection must already be ON; this assay does
not compare collection OFF to production. Fast-path verification must be
OFF without a mismatch latch. The native master and interior controls,
temporal policy, traversal optimization and job-backoff experiment are
distinct controls, not different names for one optimization.

After every mode/condition change, require observed render recovery before
starting a **20-second** measurement. There is no arbitrary 60-second warmup
and no reload between conditions or modes. Admission requires the actual
requested/executed profile and physical backend, no loading/relatch/recovery
work, no active shader compilation, no active stretch or incomplete stereo,
and no retirement/lifecycle debt. Recovery waits are bounded at 120 seconds.
Native culling must have consumed its requested location policy. Changes in
profile/control/cell or health failure during a hold abort the sequence.

Six modes take at least 16 minutes of measured holds per interior save
(14 minutes per exterior save), plus loading, mode recovery and control
round trips. Keep sufficient disk space for the continuous WPR trace.

CPU/GPU means, P95/P99, maxima, isolated spikes and spike groups use **only
the final 10 seconds**, `[10,20)`, through the existing statistical functions.
The adapted health schedule is +1/+5/+9/+19 seconds and stop. Render recovery
does not prove CPU/GPU time is stable or spike-free; settling/noise remains
a separate measured result. Existing protocols retain their +1/+5/+20/+49/
+59 schedule and `[50,60)` timing windows.

One continuous fpsVR/WPR recording covers the complete matrix. Preparation,
loads and inter-condition changes are excluded from every timing window.
`depthc-v1` policy, `depthc-plan.json` and globally unique phase ordinals
identify all conditions. Actual loads use `save-N-load-world-entry`;
measured phases use `save-N-phase-entry` with `kind=settled_control_phase`.
These are different events. WPR must use the phase marker's `[10,20)` QPC
window and the original PID/lifetime; never infer it from graph shape.

Present `depthc-comparison.md` before DLL provenance or stack analysis.
Comparisons are within the same save occurrence and mode against Balanced;
missing/inapplicable conditions remain explicit, never zero-cost results.
A usable tail must cover both endpoints within 0.25 seconds and have no
nonmonotonic samples or gaps over 0.5 seconds; inadequate coverage is
unavailable, not a zero average. This admission rule applies only to depthc.
The final Balanced repeat measures drift. Tracing overhead remains present.
User-observed popping is separate visual evidence; record its condition/time
without claiming render-health success proves visibility correctness.

Offline checks: `pwsh ./tests/depthc_test.ps1`, plus the existing
`frustrum_test.ps1`, `gameft_stack_wait_test.ps1`,
`gameft_legacy_rc166_test.ps1` and `gameft_package_test.ps1` suites.

Fresh compositor schema 1 is required: a recent coherent two-eye submission
matching the executed profile, without current cycle poisoning. Native AA
and fixed-resolution vendor modes must prove main-pass completion in that
pair. Explicit FSR3 additionally requires a fresh host/runtime FSR3 dispatch;
FSR4 and fallback paths are rejected. Physical FSR dispatch must have the
exact same frame as the completed compositor pair. Fixed-resolution FSR
uses the physical dispatch captured inside that pair; independently sampled
adjacent frames are retried rather than joined. The producer must consume
any observation loss and rebuild a coherent pair before admission.
Historic dropped observations remain
in phase markers; any increase during a condition invalidates it. Current
DLSS model and FSR preference are pinned in existing health samples.

Recorder setup uses a 10-second HTTP deadline and a 15-second controller
budget, exceeding the producer's five-second main-thread admission deadline.
Measured health requests keep their existing three/eight-second budgets.
Capture ownership schema 1 is required. Each start carries a fresh
`captureOwnerToken`; a lost reply triggers at most three read-only status
checks, plus a final cleanup check. The start is never replayed. Only the
exact token and session ID may be adopted or stopped (`expectedOwnerToken`
and `expectedSessionId`). Lifecycle calls revalidate process identity as
well as the pinned Build ID. Unknown ownership aborts dispatch and remains
explicit; a foreign recorder is never stopped or modified by restoration.
This setup-only reconciliation happens before the measurement anchor.

The interrupted Save 20 attempt on 2026-09-19 exposed a three-second start
response timeout: session 6 started after session 5 stopped, but the runner
lost the returned ID and skipped cleanup. The owned session was stopped;
all data from that attempt were discarded at the user's request. It is not
a benchmark result. `tests/depthc_test.ps1` retains the lost-response
regression, exact-owner recovery, foreign/no-start protection, restoration,
and unchanged hold/tail/deadline checks. Feedback:
`AUTO-20260919-065533158-1504D7E7`.
