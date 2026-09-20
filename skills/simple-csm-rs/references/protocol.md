# Simple CSM RS stress protocol

## Purpose

Measure the stability and performance cost of rapidly switching every
render-scale OFF/ON profile. This is a stress sweep, not a release
qualification or visual-proof protocol.

## Start sequence

Do exactly two read-only actions before the sweep:

1. Verify the live Community Shaders DLL/build identity once.
2. Capture one public-upscaling API snapshot of the starting settings.

Then immediately submit the complete matrix as one server-owned scenario.
Do not perform fixture preparation, a COC, scene settling, an INI read, a
Stabilizer check, a second snapshot, preflight, qualification dispatch or
waiter, profile-operation polling, or any intermediate telemetry read.

The startup budget is 60,000 ms from the first live binding call to the
server accepting the matrix scenario. Plan generation is local and does not
count against this budget. Do not add readiness waits, retries, or discovery
round trips to the startup path.

The build ID is an immutable parameter on every mutation. This does not add a
new provenance check.

If an interrupted earlier Simple CSM RS run left captures owned by this assay,
stop those exact recorded session IDs before the two read-only actions. Do not
discover or poll for captures. A normal start has no cleanup step.

## Matrix and pacing

Generate the plan with `New-SimpleCsmRsPlan.ps1` from the adapter and the
initial FSR runtime preference. The current canonical NVIDIA plan has 43
applies and the AMD plan has 42; report the generated count rather than an
assumed count.

For every entry, submit one public API `apply` with:

- `clientId: "simple-csm-rs"`;
- a stable unique command ID;
- the verified `expectedBuildId`;
- `purpose: "direct"` and `persistence: "runtime_only"`; and
- the plan target exactly as generated.

The scenario must use `continueOnError: true`, apply the target, and then wait
exactly 5,000 ms before the next target. It must be sequential and
server-owned. Do not add a wait before the first apply, qualification work,
client pacing, retries, or validation between applies. A rejected apply or
other per-transition evidence failure is retained as that transition's failed
result, and the next planned apply always proceeds. The scenario must submit
and finish the complete matrix even when individual transitions fail.

Non-native quality with Render Scale OFF is an intended target. Never replace
it with native AA, DLAA, FSR AA, or an ON target.

## Telemetry

Arm the bounded DevBench stress, CPU, GPU, profiler, texture-lifetime,
presentation-probe, and DLSS trace telemetry as the first server-side steps,
using `continueOnError: true`. Reset only those owned capture buffers as part
of arming. Preserve every arm failure, then continue into the matrix; an
arm/evidence failure is recorded and never suppresses later transition
results. After reset, explicitly start the stress, CPU, GPU, DLSS trace,
texture-lifetime, and presentation-probe captures, then enable the profiler
and start its bounded capture. Do not read telemetry during the sweep.

The profiler `start_capture` call includes `contractMajor: 1`. Its bounded
capture is a sample of the start of the stress sequence; do not make another
capture request during the sweep.

After the final five-second window, take one read-only end batch and then stop
the owned captures. Preserve the scenario transcript and the end snapshots of:

- render-scale stress record and status;
- CPU and GPU performance telemetry;
- profiler capture;
- texture lifetime, presentation probe, and DLSS trace summaries; and
- any operation failures returned in the server scenario transcript.

Analyze after capture shutdown. Group results by method, quality, and
Render Scale state. Report the completed, rejected, and no-change applies;
five-second pacing; controller retries and deferrals; lifecycle, resource,
memory, retirement, main-pass, stereo, CPU queue/packet, and GPU pipeline
counters; and performance samples. Do not invent a pass/fail proof field that
the runtime did not expose.

## Cleanup

Stop only captures owned by this run, using their recorded session IDs. Leave
the final profile runtime-only and do not restore or persist the initial
settings. Do not repeat DLL identity or settings verification at the end.
