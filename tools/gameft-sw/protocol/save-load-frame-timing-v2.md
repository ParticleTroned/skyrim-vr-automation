# game-ft protocol, revision 2

Status: versioned specification for the preserved runner. Migration
validation is offline and does not constitute live runtime qualification.

`game-ft` measures CPU/GPU frame times, irregular slow frames, stabilization after a
save load, and the associated render-scale relatch health. Minimize time
between the user's main-menu signal and recording. Perform provenance and
analysis after both measurements.

## Required workflow

Follow this saved protocol on every invocation. Change the protocol, runner,
measurement definitions or reporting workflow only when the user explicitly
requests that change. A tool failure does not authorize an alternative.

- Use `Invoke-SaveLoadTimingV2.ps1` for the measurement,
  `Show-SaveLoadTimingQuickReport.ps1` for the saved-window analysis, and
  `Compare-GameFtRuns.ps1` for comparisons. Do not replace them with an ad hoc
  scenario, receipt collector, boundary detector, calculator or formatter.
- Start each new run in a unique, empty run directory. Let the established
  runner create `runtime.json` from the current process. Never supply a
  literal PID, copy runtime metadata from another run, or select a run
  directory by latest modification time. Retain the exact run-directory path.
- Preserve the runner's markers, health receipts and measurement windows.
  Report a missing receipt or failed command explicitly. Do not reconstruct
  missing measurements or silently substitute another execution path.
- Present the timing and per-load health results before build provenance.
  Keep the existing save question, logger controls, measurement durations,
  CPU/GPU calculations and health-observation schedule.

## Operator sequence

1. The user reports that Skyrim is at the main menu/loading screen, before
   selecting the first save. Immediately activate fpsVR raw frame logging
   through its supported `fpsVRcmd.exe logging_startstop` command. This is a
   toggle: track recording ownership and do not toggle an already active
   recording off. Confirm activation with a bounded recording-state/file
   check. Treat `fpsVRcmd` output containing `Can't connect to fpsVR` as a
   failed command path even if the process exit code is zero. Abort before
   loading the first save if the already attached fpsVR logger cannot be
   controlled and raw CSV growth cannot be proven. Do not launch fpsVR as a
   standalone executable, terminate fpsVR, restart fpsVR, send the fpsVR
   logging hotkey, or restart SteamVR/Skyrim during a live `game-ft` session.
   Do not perform DLL hashing, MO2 scans, builds or report generation.
2. Load each user-selected save number in the supplied order. Use the exact
   selected saves, not COC or synthesized camera positions. Keep the HMD and
   player stationary at each loaded view. Record for exactly 60 seconds from
   the first visible rendered world frame after each load. Do not wait for
   relatch completion, a health pass, shader completion or smooth timings.
3. Immediately at the end of each interval, load the next selected save and
   repeat the same immediate 60-second measurement at its loaded view. No
   intervening head-turn, scene calibration, warm-up pass, analysis or DLL
   verification.
4. Stop the owned recording after the final selected save interval. Preserve
   the logs, analyze the retained timing and load-health evidence with the
   saved reporter, and present the results in chat. Then verify build
   provenance and report its outcome.

Use one continuous fpsVR recording across all selected loads. Mark each load
request and each world-entry boundary separately. Load durations remain
evidence outside the stationary 60-second windows. The minimum timed portion
is `60 seconds * selected-save-count`, plus actual loading and the necessary
load controls. Do not automatically add repeats.

The saved view does not lock physical HMD tracking. The user must keep the
same headset position/orientation relative to the tracking origin. Do not
recenter, move, change settings, or open dashboards during either hold. Keep
the existing caches; do not compile, purge or prewarm them as a prerequisite.
Record visible compilation or scene drift as a condition of the run afterward.

## Preparation outside the start signal

Resolve the existing logger command, permitted save-load control, available
save list and available load-event capture before the user announces the main
Keep the current MO2 profile
and installed build; the user owns launching and package selection.

Preflight fpsVR commandability before the user starts a live measurement
session. Do not restart fpsVR, SteamVR or Skyrim after the user is already at
the main loading screen or in game. If fpsVR is not commandable at live start,
abort before loading saves and report the exact preflight failure. Repair,
Steam-launch or attach fpsVR only before the live session begins.

At the beginning of every protocol run, ask the user which save numbers to
load unless the same message already provides them. Ask this exact question
before touching fpsVR, DevBench or the game:

```text
Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12.
Leading zeros are accepted and retained in the report wording.
```

The supplied order is the load order. A single save number is valid. Two,
three, five or more save numbers are valid. Each number must resolve to a
unique regular save in the current profile. Do not silently replace it with a
new autosave or another Continue target. Hash every selected save and co-save
after the measurements; preserve the paths actually loaded.

Use an already established structured save-load action where available.
Otherwise the user selects the saves while logging remains active. Do not
invent a load command, silently switch profiles or stop at an assumed scene.

## Measurement boundaries and timing source

fpsVR raw CPU/GPU frame times are authoritative for this timing comparison.
Keep the original columns and units. Inspect their installed format and
scope after capture; never replace them with CSX internal pass timings,
GPU utilization, aggregate history or reciprocal FPS.

For each load, define `t=0` as the first rendered world frame after loading,
not the load command, a shell response, or presentation-stable. Retain the
load-complete/loading-menu event and its producer timestamp/frame ID where
available. Correlate its clock with fpsVR timestamps and record uncertainty.
Logging starts before loading so analysis can recover the correct boundary
without losing the early unstable frames.

The measured window is `[0,60)` and the average window is always `[50,60)`.
Do not choose a later or smoother ten seconds. Loading-screen frames do not
enter those averages. Frames after world entry do enter them even if a
relatch, stretch episode or settling is still active.

If the first world frame cannot be established, preserve the capture and
report the boundary uncertainty. A chat acknowledgement or approximate
observed boundary cannot support an exact or sub-second stabilization claim.
Do not silently call an approximate interval exact.

## Required render-scale and relatch health during both loads

Health readout is a required part of this assay, not optional post-run
provenance. For each load, start the frame-time interval at world entry and
capture the producer's render-scale status immediately afterward while
fpsVR continues recording. Keep the raw response with its producer frame,
timestamp, load identity and capture latency. Preserve transient relatch
events from an already armed producer recorder and a state observation near
the end of each hold. Buffer this evidence; parse, compare and hash it only
after the second hold. Do not delay the second save load for reporting or
provenance, or wait for a health pass before measuring.

Use the same bounded health-observation schedule for both builds. Retain
its sample timestamps so any perturbation of the frame-time trace is visible.
Do not claim a run has complete health coverage if the live status call or
the required transient evidence was unavailable. Preserve the CPU/GPU result
and explicitly mark the health portion incomplete.

Retain CSX producer load/transition telemetry alongside fpsVR. fpsVR alone
does not contain relatch health. Prefer existing retained producer events;
arm any necessary observational recorder before the first load. Retrieve
and analyze retained data after both holds. Do not enable CSX performance
profiling or a renderer/temporal probe to obtain these timings.

If a supported collector must be armed to preserve transient load events,
record its ownership and overhead and use the same capture mode on both
builds. Do not add per-frame client polling. Any necessary bounded load-event
observation must have a recorded cadence. A final healthy status snapshot
cannot establish the history or reconstruct missing milestones.

Keep separate records for every load, for example
`MAIN-MENU -> SAVE-5`, `SAVE-5 -> SAVE-7`, and so on.
Attribute evidence using the request/operation identity, transition epoch,
contract generation, physical backend and both-eye generation/dispatch data.
Do not combine counters or milestones from different loads. Retain raw
session counters plus per-load baselines/deltas when available; if only a
session total survives, label it as such.

For each load report the following supported producer evidence:

| Evidence | Report |
| --- | --- |
| Relatch and release | Pending/queued/in-progress/frame-pending/post-load-settle state, owner obligations, retries and reasons |
| Presentation stable | First observed frames and milliseconds, with its explicit timing origin |
| Cleanup drained | First observed frames and milliseconds, cleanup tail and outstanding retirement/release debt |
| Strict completion | Separate result, frames/milliseconds, failure masks and reasons |
| Stretch | Episode count, completed/active frames, duration, raw bound result and its classification |
| Stereo | Both-eye evidence, generation agreement, complete compositor cycle and failures |
| Backend identity | Requested/configured/executed/physical backend agreement and dispatch failures |
| End of each hold | Active stretch/relatch, incomplete stereo cycle, remaining authoritative owners/debt and failed health gates |

Keep presentation-stable and cleanup-drained as separate milestones. Report
load-dispatch-relative and world-entry-relative times distinctly; convert
only when both clock-correlated origins exist. Health completion never
controls the start or duration of the performance window.

Apply the producer/consumer contract supported by that exact build. Preserve
a failed diagnostic-only stretch bound as a failed raw diagnostic without
turning it into a health rejection. Other applicable failed health gates,
active stretch at stop, incomplete stereo, backend and retirement failures
remain failures. A superseded transition metric is retained as evidence, but
the per-load health verdict is based on the terminal completed generation and
terminal hard gates for that load. Do not infer a classification for unknown
fields or accept unknown future schemas. Missing historical telemetry is
unavailable, not a pass; report the timing capture even when load-health
evidence is incomplete.

If a load has no completed transition metric but the terminal status shows a
completed stretch, `activeAtStop=false`, complete stereo, backend ready,
presentation recovered, and `controller.applied.origin=recovery_relatch`, report
the render-scale state as settled after stretch via recovery relatch. Do not
describe that case as an unsettled load. State that the transition-metric
duration is unavailable. If no recovery relatch or completed transition exists
and the stretch is still active at the end of the 60-second measurement, state
in the health column that the game was still in stretch at measurement stop.

## Averages, stabilization and irregular frame noise

Calculate CPU and GPU independently, using all valid unique raw samples.

- Tail mean M: arithmetic mean of frame times in `[50,60)`.
- Mean stabilization: earliest integer second T in 0..50 for which every
  complete five-second window beginning at T or later and ending by 60 is
  within `M +/- max(0.10 ms, 0.02 * M)`. Advance windows by one second and
  require at least ten seconds of subsequent observation. Otherwise report
  `not stabilized within 60 s`; retain the actual tail average.
- Noise stabilization: apply the same rule to the five-second `P95 - P5`
  spread, relative to the tail spread, with tolerance
  `max(0.10 ms, 0.20 * tail spread)`. A stationary noisy trace is still noisy.
- Report mean, median, sample SD, P95, P99, maximum and `P95 - P5` for the
  whole minute and the final ten seconds, separately for CPU and GPU.
- Report positive adjacent jumps `max(0, x[i] - x[i-1])`: P95, maximum and
  count above 0.50 ms per second. Include zero jumps in the distribution.
  Also count frames above the tail median plus 0.50 ms per second.
- Preserve slow frames. Do not smooth them away, discard outliers, pair
  across missing frames/window boundaries or replace missing values by zero.
- Retain sample/missing counts, dropped/reprojected frames and display-budget
  exceedance where available. Do not assume periodic sawtooth behavior.

These are fixed assay definitions, not vendor guarantees. Stabilization has
one-second analysis resolution using five-second windows; it is retrospective.

## Reporting and provenance after measurement

Present one row per save, followed by the load-health details:

| Save | CPU average, final 10 s (ms) | GPU average, final 10 s (ms) | CPU stabilization (s) | GPU stabilization (s) | CPU/GPU noise (SD, P99, maximum, jumps/s) | Relatch health |
| --- | --- | --- | --- | --- | --- | --- |

For side-by-side comparisons, use `Compare-GameFtRuns.ps1` instead of an
ad-hoc PowerShell extractor. Do not use helper names that collide with
PowerShell aliases, including `r`, `R`, `rv` or `RV`; these resolve to history
or variable-removal aliases and can corrupt the report path. The comparison
script uses explicit `Format-GameFt...` function names and emits Markdown
directly, so it is the fastest supported reporting route after
`Show-SaveLoadTimingQuickReport.ps1` has written each `quick-summary.json`.

Include the two 60-second raw traces and expanded final-ten-second plots,
using consistent axes across builds. Report timing and health results
separately, with boundary uncertainty and missing evidence made explicit.

Report one row per selected save. CPU and GPU averages are always from the
final ten seconds of that save's 60-second window. Report final-ten-second
P95, P99, maximum and single-spike frequency for CPU and GPU beside those
averages. A single spike is one isolated raw fpsVR sample in the final ten
seconds at least `+2.0 ms` above that device's final-ten-second median, with
neighboring samples below that threshold. Report the existing GPU settling
rule unchanged. Report completed stretch duration separately from terminal
health. The health column must answer the lifecycle question directly:
selected mode at the first health sample after world entry, whether that mode
was already applied, when the first completed latch metric or recovery relatch
was observed, whether stretch started and completed, the stretch duration, and
whether the final sample was successfully latched with stretch inactive, stereo
complete, backend/presentation in the expected mode, and no owner/retirement
debt. Present the CPU/GPU timing rows and the per-load terminal health verdict
in chat immediately after log preservation and analysis. Do not run
provenance, hashing, MO2 inspection or identity scans until that result table
has been sent to the user in chat. Then verify the runtime producer
Build ID/source and physical DLL
SHA-256/size against the enabled AIO manifest and receipt. Resolve any loose
provider ambiguity then. Record compiler/options, actual upscaler/backend,
settings, HMD/runtime/driver, refresh/reprojection settings, logger version,
both save/co-save hashes and observed scene/cache conditions. Preserve
original supplied logs under the repository's archive policy before analysis.

If subsequent identity or evidence checks fail, retain the measurements and
label the affected comparison unverified/inconclusive; do not erase them or
invent provenance. Compare each save number only with the same save number
across builds. A selected save sequence is exploratory; repeat only when
requested or agreed, keeping the same load order. No runtime rendering
changes, commits, builds or deployments are part of this measurement protocol.

Use the exact run's retained producer identity and runtime metadata for
post-run provenance. A current listener or health PID that differs from the
recorded PID is an identity failure. Preserve that failure; never overwrite
the recorded PID or disable the identity check to make it pass. A newly
discovered process cannot prove which DLL produced an earlier measurement.

A commit label is verified only when retained runtime source/Build ID and
the physical DLL, manifest and receipt agree for that measured session.
Keep user-supplied build names as user-reported labels until then. Repository
HEAD, a recently generated archive and another run's identity are not build
provenance for this run. If verification fails, report `build unverified`
with the exact reason; do not present a commit assignment as established.

This targeted bisect assay does not replace canonical physical-HMD
render-scale qualification or relax its scene/count/visual requirements.
