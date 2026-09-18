# gameft-sw: game-ft with CPU stacks and waits

This opt-in diagnostic protocol uses the saved `game-ft` runner and reporter
unchanged. Its purpose is to identify CPU work or waits behind fpsVR spikes,
including clustered slow frames. It does not replace physical-HMD render-scale
qualification. `game-ft` remains the protocol for ordinary timing comparisons.

## Invocation

When the user says `gameft-sw`, ask exactly this before touching the game:

```text
Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12.
```

Use the supplied order and leading-zero labels. If numbers accompany the start
request, use them directly. The user launches the selected DevBench build and
fpsVR through Steam/SteamVR and waits at Skyrim VR's main loading screen.
Prepare WPR permissions/tools outside the live start; do not restart any of
these applications. Do not build or deploy during measurement.

Before launching Skyrim, validate the recorder from an elevated PowerShell 7:

```powershell
pwsh ./tools/gameft-sw/Test-GameFtStackWaitRecorder.ps1
```

If Skyrim is already open, ask the user to confirm the main loading screen,
then pass `-MainMenuConfirmed`. This permits the isolated recorder check before
any save is loaded; it never runs during a measured hold or requires restarting
Skyrim or fpsVR.

This records three seconds of local CPU work and waits through the same owned
worker, stops and saves the ETL, then uses WPT `xperf` to require sampled CPU,
context-switch and ready-thread events with stacks and zero lost events or
buffers. It sends no game or fpsVR controls. The default recorder is the
installed Windows Performance Toolkit `wpr.exe`; an explicit `-WprPath` is
supported. Versions older than 10.0.19650.0 are rejected, including the Windows
10 system recorder with its known `0x80010106` finalization failure.

Successful validation is retained under `build/gameft-sw`. The live wrapper
checks that receipt before accessing the session. Changed recorder/control or
analysis binaries, Windows version, profile or recording/validation scripts
require fresh validation before measurement. Failed, missing or changed evidence
prevents loading any save. A cached valid receipt makes this a file check at
live start, not an extra recording or warm-up inside the measurement.

Then run from an elevated PowerShell 7 with the existing SteamVR session intact:

```powershell
pwsh ./tools/gameft-sw/Invoke-GameFtStackWait.ps1 -SaveNumberText '05, 07, 08' `
  -FpsVrCmd '<fpsVR installation>/fpsVRcmd.exe' -ArchiveDirectory '<log archive>'
```

One invocation starts stack/wait recording, delegates all save loads and fpsVR
recording to `tools/gameft-sw/protocol/Invoke-SaveLoadTimingV2.ps1`, and requests
trace stop after all holds. It checks the saved runner/reporter/comparison
hashes; missing or changed scripts cause an explicit failure, never a fallback.
The runner, reporter and comparison scripts are versioned together under
`tools/gameft-sw/protocol/`. Update their pins only for an authorized
protocol revision. The migration changes path/parameter plumbing only;
measurement windows, sample pacing and calculations retain their source.

The new snapshot capability is checked before loading. It must return
`csx-cpu-burst-snapshot-v1`, `devbenchOnly=true`, the current Skyrim process,
a valid Build ID, and inactive CSX profiler capture. Unsupported production,
older DevBench or unknown future schemas abort before any save is loaded.
Physical DLL hashing remains deferred until after presenting timing results.

## Preserved timing and health rules

### Explicit RC166 compatibility

The user-authorized `-LegacyRc166` option supports the clean producer source
`2eef86720e5c6a48e6fa9ad93506a1f2093d0f2f` without replacing its original
vendor DLLs. It rejects other sources and changed Build IDs. Standard runs
retain their existing snapshot and world-frame requirements.

This older producer lacks `cpu_burst_snapshot` and `vendorWorkGate`.
The compatibility path observes a fresh loading menu or unloaded player,
then a loaded player with an advancing frame and no loading/main menu.
This is an approximate load boundary, not proof of the first completed
world frame. Preserve that distinction when comparing its final `[50,60)`
windows with standard runs. WPR configuration, fpsVR control, 60-second
holds, sample schedule and statistical calculations remain unchanged.

Read-only legacy status receipts replace unsupported stress lifecycle
collection at the same sample times. They remain separate from standard
health receipts: absent stretch, strict completion and final stereo evidence
are unavailable, never a health pass. The legacy profiler status verifies
continuous user capture is disabled; that old action itself requests one
capture before/after all holds. Effective feature settings and accepted-draw
observer snapshots are unavailable. These differences and the compatibility
script hash are retained in the run receipt. RC166 comparisons describe the
whole build and its bundled libraries, not an isolated source/culling effect.

-   One continuous fpsVR raw recording; 60 seconds per selected save from the
    runner's observed world-entry boundary, with its uncertainty retained.
-   CPU/GPU averages, P95, P99, isolated spikes and spike groups use the saved
    reporter and its final `[50,60)` windows. CPU/GPU settling rules are unchanged.
-   The original health samples and per-load recorders remain unchanged.
    Report selected mode, initial latch, recovery relatch, stretch duration and
    final latch/stereo/backend/retirement status for DLSS/render-scale and native
    AA alike. An active stretch at stop remains a failure.
-   No extra polling or effective-settings snapshots inside a measured hold.
    Full effective settings and preset compatibility are captured before the
    first load and after the final hold; per-save mode evidence is the existing
    health receipt. The snapshots do not prove transient settings between them.
-   The original fpsVR ownership rule applies. Never kill/restart fpsVR or use
    a standalone launch, keyboard fallback or an alternate measurement runner.

## Additional evidence and production boundary

`communityshaders.profiler` action `cpu_burst_snapshot` is compiled only under
`DEVBENCH_BRIDGE_ENABLED`. It schedules one read-only main-thread snapshot on
explicit request: feature settings and constraints through the feature API,
the published preset decision, accepted-draw subscriber/callback/replay/fault
counters, active subscription IDs and callback addresses, OCU requested/active
state, profiler capture state, frame, PID, main-thread ID and QPC bounds.
Map callback addresses to ETW loaded images and symbols to identify third-party
observers. Observer identity inspection uses a nonblocking lifecycle lock;
`acceptedDrawObserversComplete=false` reports contention, never zero active
observers. No new render-loop hooks, timers, counters or polling run
automatically, including in a DevBench build.

WPR runs outside the DLL, with the explicit `CpuStackWait.wprp` profile:
process/thread lifetimes, loaded images, sampled CPU stacks, context switches
and ReadyThread stacks. It does not alter the system sampling interval.
The worker uses a unique instance name for every start/status/stop, never a
global cancel. It stops on the wrapper's request, wrapper process exit, or
`30 + 240 * save-count` seconds. Deadlines are capture safety bounds, not
measurement windows. Start failure prevents game-ft from starting.
The worker runs in a hidden independent PowerShell process so parent failure
does not leave an unbounded recording. A failure to stop is retained explicitly
in `trace-result.json`; recover only that recorded instance, never another WPR
session. WPR may require elevation or refuse an incompatible existing session.

The worker writes `trace-ready.json`, `trace-result.json`, WPR command logs and
`cpu-stack-wait.etl` under the exact run's `stack-wait` directory. The settings
receipts include QPC bounds; `markers.jsonl` supplies each save's world entry,
hold end and health-request boundaries. Do not identify windows from graph
shape or from a different run. WPR collector status preserves lost-event
counts; inspect these and trace coverage before claiming complete stack/wait
evidence. A generated ETL alone does not prove complete or symbolized stacks.

## Reporting order

1. Preserve the exact fpsVR file named by this run's recording-confirmation
   marker under `${LOG_ARCHIVE}`, verifying original/copy size and
   SHA-256 before analysis. If a pre-existing user-owned recording is still
   growing, preservation fails explicitly; do not stop it or analyze an
   unverified partial copy.
2. Use the saved quick reporter and present its CPU/GPU and per-save health
   table in chat immediately, before provenance and before waiting for ETL
   merging or symbol processing. Report trace finalization as pending until
   `trace-result.json` confirms stop. Never silently label tracing failures as
   complete. Preserve partial timing/health results when capture fails.
3. Verify producer Build ID/source against the measured process's physical
   DLL, AIO manifest and receipt using the established provenance procedure.
   Preserve the exact matching PDB. Do not assign a commit from repository
   HEAD, an archive filename or a user-supplied label.
4. Inspect the completed ETL in WPA: filter to the recorded PID/lifetime and
   the marker-defined hold/tail intervals. Use **CPU Usage (Sampled)** for work
   stacks and **CPU Usage (Precise)** for running/ready/wait durations and
   switch/ready stacks. Correlate spike intervals and health calls by QPC,
   retaining boundary uncertainty. Report top stacks, wait causes, thread IDs,
   symbol gaps and lost events separately from fpsVR frame-time statistics.

Scheduler reconstruction accepts an absolute accounting error of **10 ms**
per **10,000 ms** tail window, including the boundary. Use the shared
`tools/gameft-sw-analysis/scheduler_coverage.py` policy in the sibling
`skyrim-vr-automation` repository. Preserve measured durations and signed
errors. Reports must name the applied policy/tolerance; historical receipts
keep their original verdicts. This user-requested rule replaces the former
5 ms tolerance as of 2026-09-18 and does not change timing or health rules.

After presenting the timing table, inspect trace finalization without another
live game call:

```powershell
pwsh ./tools/gameft-sw/Get-GameFtStackWaitResult.ps1 -RunDirectory '<exact run directory>'
```

This checks the owned stop receipt and QPC coverage of each saved hold.
`stackWaitComplete` describes capture coverage only; stack attribution still
requires ETL lost-event and symbol review. A pending or failed result must
remain visible even when fpsVR measurements succeeded.

Label every result `gameft-sw (stack/wait tracing active)`. Tracing has overhead;
compare performance claims only with equally instrumented runs. Historical
game-ft values may be shown as context with that limitation, without declaring
a regression or improvement from tracing overhead. Do not change the saved
statistics, drop spikes or turn missing stack symbols into a root-cause claim.

Microsoft references: [WPR commands](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options),
[recording profiles](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/authoring-recording-profiles),
[WPR instance ownership](https://devblogs.microsoft.com/performance-diagnostics/controlling-the-event-session-name-with-the-instance-name/).

## Repository ownership

The automation repository owns this protocol and its offline tests. Run from
the automation source checkout. It is not installed into an active plugin
cache by this migration. Supply machine-specific fpsVR and archive paths
explicitly; the default DevBench controller is in this same checkout.
An existing CSX checkout may retain ignored legacy copies for an active
measurement; do not replace them or its validated recorder mid-run.

Offline checks (no game, recorder or fpsVR controls):

```powershell
pwsh ./tests/gameft_stack_wait_test.ps1
pwsh ./tests/gameft_legacy_rc166_test.ps1
pwsh ./tests/gameft_package_test.ps1
```
