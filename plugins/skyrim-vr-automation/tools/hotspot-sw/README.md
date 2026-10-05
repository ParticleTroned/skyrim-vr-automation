# hotspot-sw: a manual walk through a CPU hotspot

Use this separate protocol for the perf-branch DevBench build. It does not
change game-ft, gameft-sw, frustrum or depthc, and does not change rendering
settings, shader quality, resolution, culling mode or experimental controls.
Do not pool its measurements with fixed-head gameft-sw holds: it adds 10 Hz
pose capture and five-second status snapshots.

## User flow

1. Make a save near the sensitive position, preferably outside the slow area.
2. Launch the perf build and fpsVR normally through the existing VR session.
3. Say hotspot-sw. Ask which ONE save number to load unless supplied; do not
   assume the new save is 13. Confirm the main loading screen and selected
   culling/upscaling settings. Alternatively accept explicit already-in-game
   admission without loading another save.
4. On start, verify recorder readiness, start WPR, fpsVR raw logging, pose
   recording and owned render-scale health capture BEFORE loading the save.
5. Once loaded, stand still facing the initial view for about 20 seconds.
   Walk to the slow position, hold the problem view for about 20 seconds,
   walk beyond it until performance recovers, then hold another 20 seconds.
   Repeat the route if useful. Looking away and back while standing is also
   useful; it creates separate view segments. No in-game instructions or
   checkpoint presses are required.
6. Say stop and LEAVE SKYRIM RUNNING. Stop and preserve the owned captures;
   confirm all finalization before telling the user it is safe to close.
   The default safety limit is ten minutes, including loading. Game exit,
   timeout, unsupported/changed telemetry and capture loss retain a partial
   run. Game exit stops the host recorder loop and requests WPR/fpsVR cleanup,
   but the in-memory trajectory and final health receipt may be lost.
   Closing Skyrim is therefore an emergency termination, not normal completion.

Do not start measurement from a tooling request. Prepare permission/recorder
validation before the live start. Never restart fpsVR, Skyrim or SteamVR to
repair logging. Do not compile, analyze ETLs, deploy or rotate plugin caches
during the walk. Only bounded capture-status monitoring runs concurrently.

## Captured evidence

- Same owned WPR CpuStackWait profile and validated worker as gameft-sw:
  sampled CPU, context switches and ready-thread stacks. Capture continuously
  across loading, walking, looking, stopping and recovery. No live WPA export.
- Continuous fpsVR raw frame samples, using the hash-pinned game-ft logging
  helpers. A pre-existing user-owned logger is preserved and admission fails;
  do not toggle it blindly. Stop only the logger/file started by this run.
- DevBench recording at 100 ms: player world XYZ/yaw/pitch, physical HMD
  tracking-space position/orientation, device validity/origin, engine frame,
  and menu/input/lifecycle events. No screenshots or synthetic input.
- Read-only render-scale status every five seconds, with complete
  nativeFrustum/depthJobs, culling, preparation, routing, relatch, stretch and
  stereo fields. Require installed, active native-frustum schema 2, depth-job
  schema 1 and a stable collection generation. Require guarded health-session
  ownership schema 1. The user selects diagnostic collection before capture;
  do not silently activate a different culling/fast-path/backoff setting.
- Full effective-settings/producer snapshots before and after capture.
  Physical DLL/AIO/PDB/vendor provenance follows the first timing report.
  Bind the measured process by PID AND start time and pin its runtime Build ID.
  A branch/archive name is not compiled-source provenance.

The player-pose trajectory currently serializes player coordinates and angles,
not all captured camera-node fields. Preserve player coordinates and raw HMD
tracking transforms separately; do not claim an exact world-space rendered-eye
transform or assume a metres-to-game-units conversion. This is enough to locate
a pause along this route, but not an automatic guarantee of identical views
between launches. This host capability is separate from CSX's perf telemetry;
an old DevBench host may require an update even with the right CSX AIO.

## Automatic segmentation (version 1)

Classification is offline, with raw samples retained:

- A pause starts at the first sample of a spatially bounded segment and is
  confirmed after two seconds. All samples must remain within 4 game units of
  the initial player position, 3 cm of initial HMD tracking position, 3 degrees
  of initial HMD orientation and 3 degrees of initial player yaw/pitch.
  Comparing against the segment origin prevents slow cumulative drift from
  masquerading as standing still. These are declared analysis tolerances,
  not claims that a 3-degree view change cannot affect performance.
- Turning in place starts another view segment. Walking/short pauses remain in
  the source timeline. Gaps over 350 ms, invalid tracking, stale engine frames,
  blocking menus or tracking-origin changes split segments. Never interpolate
  across them or use loading/menu frames in a stationary mean.
- Keep every pause >=2 seconds. Only pauses >=20 seconds get the main CPU/GPU
  comparison, using their final ten seconds exclusively. Pose stillness does
  not prove render-scale recovery or timing stability. Retain active stretch
  and unresolved backend/stereo state as such; never call these healthy
  because the camera stopped.
- Report CPU and GPU separately: mean, P95/P99, isolated-spike frequency and
  clustered-spike frequency/length using the pinned game-ft definitions.
  Deltas use the first eligible pause as a clearly labelled within-run
  reference; inspect whether it is actually the healthy starting view.
  Do not call these repeat statistics or pool different locations/modes.
- Also inspect the continuous fpsVR track during movement. Pause windows are
  for comparable summaries, not the sole evidence of where cost rises/falls.

Recording elapsed milliseconds are aligned to host QPC through bracketed
record-status calls. Intersect their origin bounds, retain the uncertainty and
reject inconsistent clocks or >500 ms uncertainty. UTC alignment uses host
QPC/UTC markers and rejects a >100 ms wall-clock shift. Window boundaries are
conservatively inside the measured pause and before cleanup. They remain
bounded observations, not exact instruction/frame synchronization.

Status polling intervals remain marked in the evidence and attributed in WPR;
do not silently remove expensive samples. Snapshot deltas are cumulative,
per-thread/pass and only meaningful within one collection generation.
Never turn counter resets, overflow, mixed generations, sampled-only detail,
unknown camera indices or in-flight work into zero work or per-eye counts.

## Commands (source checkout on automation dev)

Use explicit local paths from the actual machine configuration. In particular,
RecordingDirectory must be the physical MO2 output directory backing
Data/SKSE/Plugins/devbench/recordings, not an assumed virtual game path.
A new unique RunDirectory is required. Use an elevated PowerShell 7 after the
existing recorder-validation receipt has passed.

~~~powershell
$parameters = @{
    RunDirectory = '<new evidence directory>'
    SaveNumberText = '13'
    RuntimePath = '<selected devbench-runtime.json>'
    FpsVrCmd = '<Steam fpsVR/fpsVRcmd.exe>'
    FpsVrCsvDirectory = '<Documents/fpsVR/CSV>'
    RecordingDirectory = '<physical DevBench recordings directory>'
    ArchiveDirectory = 'D:\Coding\GitHub\CS logs'
    RecorderValidationPath = '<existing valid recorder-validation.json>'
}
./tools/hotspot-sw/Invoke-HotspotSw.ps1 start @parameters

# From another host command while the start process continues:
pwsh ./tools/hotspot-sw/Invoke-HotspotSw.ps1 stop -RunDirectory '<same directory>'
pwsh ./tools/hotspot-sw/Invoke-HotspotSw.ps1 status -RunDirectory '<same directory>'

# Only after measurement/copy verification, with no subsequent assay active:
python ./tools/hotspot-sw/analyze_hotspot.py --run-directory '<same directory>'
pwsh ./tools/hotspot-sw/Show-HotspotTiming.ps1 -RunDirectory '<same directory>'
~~~

Start remains alive as the capture owner; do not launch it through a transient
shell that immediately exits. The existing WPR worker also stops on owner exit.
A killed host may leave fpsVR logging or a limited pose recording needing
explicit ownership reconciliation; do not claim every recorder finalized.

## Reporting and interpretation

Present the stationary-window CPU/GPU table FIRST, then verify physical build
provenance and analyze WPR. Include each pause's coordinates, HMD orientation,
duration, before/inside/after interpretation, clock uncertainty and health
snapshot references. All archive copies must match original size/SHA-256
before reading their samples. Preserve source files.

Use hotspot-windows.csv to select the exact process lifetime and intervals in
WPA. Compare rendering-thread running/ready/wait time and sampled stack work,
then worker work and the waits delaying the render thread. Normalize execution
to actually observed frames and show wall-time totals separately.

Priorities: compound-frustum and sphere tests (live-identified native regions),
depth-job dispatch/callback/no-work evidence, draw/material setup, light-owner
snapshots, LOD/terrain/shadow callers, submit/relatch and driver/GPU waits.
More culling tests is different from more geometry admitted downstream.
Sampled helper wall durations include preemption/waits, not just CPU work.
WPR CPU evidence cannot by itself identify an expensive GPU shader pass.

The ETL must finish with the owned instance, no lost events/buffers and sampled,
CSwitch and ReadyThread stacks. Reuse the existing xperf/WPA validation and
scheduler_coverage.py policy: 10 ms tolerance for each 10,000 ms comparison
window. Pending or failed trace finalization is not complete analysis.
Reprojection/throttling is unavailable unless separately recorded; infer no
particular compositor mode from a twofold fpsVR change alone.

This first experiment is observational: no automatic setting changes, safety
removal, inferred culling fix, WPR-derived GPU timing or automatic replay.

## Validation

Offline tests and parser checks do not validate a live perf build/DevBench host.
The first live capture must confirm pose persistence, fpsVR logging and ETL
coverage. No game was loaded to develop this protocol.

~~~powershell
python -m unittest discover -s tests -p test_hotspot_sw.py -v
pwsh ./tests/Test-HotspotSw.ps1
~~~
