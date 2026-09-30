# Replay protocol validation — 2026-09-29

The final protocol-v2 Open Shaders Dragonsreach replay completed and its
full trace passed save/unload/reload verification. Initial protocol tests
ran with Skyrim closed. Earlier failed captures were deleted at the user's
request; the admission failure below is historical evidence, separate from
the successful process-49808 capture. Small diagnostic findings remain here.

## Failure evidence and resulting rules

- Tracy's Python process retained approximately 10 GiB belonging to unloaded
  workers. Explicit cyclic garbage collection reduced private usage from
  about 16.11 GiB to 6.14 GiB; unloading the current partial trace and collecting
  released the remainder, leaving about 0.06 GiB. The allocator limit is shared
  across workers. An empty instance registry did not establish cleanup. The
  protocol now requires garbage collection, namespace cleanup, no competing
  tasks and two actual private-memory/headroom receipts before capture.
- The game completed the interior replay at 19:19:22.764 UTC, while captured
  data ended around 19:19:03 UTC. The trace was rejected. A replay finishing
  does not prove complete trace coverage; the new acceptance rules check both
  CPU/frame and GPU coverage through the terminal boundary and saved-file
  reload before declaring the route complete.
- A long synchronous replay lost its MCP session response with HTTP 404.
  Its scheduler result was unavailable as an asynchronous run ID. The
  protocol now uses one asynchronous dispatch and short status requests with
  the returned ID; it forbids blind replay retries after a lost receipt.
- Reconnecting the inspected D3D11 collector yielded zero-frequency GPU
  timestamp errors and no completed GPU durations. No replay was dispatched
  after that gate failed. A process claim, fresh-game requirement and one
  collector connection per measured route avoid this recovery path. The
  underlying renderer/dependency was not modified or claimed fixed.
- Requested weather was remapped to different Helios variants, and a gallery
  pitch request was clamped in VR. Comparison images now require verified
  realized weather and camera transforms, separate from timing.

## Validation performed

- `python tests/test_tracy_replay_guard.py`: 21 tests passed, including real
  read-only Windows memory sampling. Tests cover hidden 10 GiB retention,
  physical/commit headroom, shared/cancelled work, missing data, GPU progress,
  zero-frequency rejection, stale readiness, exactly-once replay admission,
  process-claim reuse, timer expiry without polling, write failure during
  stop, owner mismatch, eval namespace cleanup and quantile calculations.
  Arming also rejects stale memory proof or proof from another collector PID.
  Invalid process-claim input requests disconnect without admitting replay.
- Source/package helper, protocol and skill bytes matched in that test.
- Existing Tracy protocol-83 synthetic producer, CPU-only: the actual MCP
  bindings correctly failed `gpu_timestamps_invalid`, requested disconnect
  and left `replayAdmitted=false`. No GPU gate was waived.
- A second fresh synthetic producer: the independent two-second timer
  requested disconnect after approximately 2.011 seconds, with no subsequent
  controller call needed. A host orchestration attempt to store a JavaScript
  function was rejected during this smoke test; the collector deadline still
  operated. The corrected follow-up verified the saved timer receipt.
- Asynchronous save, garbage collection, unload and reload preserved exactly
  327 frames, 325 zones, first timestamp 23072579661 ns and last timestamp
  28214701572 ns. Saved trace SHA-256:
  `0E359BA34CEE7D6AA12B59F46D788C9C7363CF33AFF3F2191C6A2F0B05E7E3B3`.
- After unloading the synthetic trace, collector private memory was
  65,798,144 bytes, with over 42 GB physical and 70 GB commit headroom.
  Raw synthetic evidence remains local, outside the distributed protocol.
- A final fresh synthetic producer exercised mandatory memory admission on
  the actual MCP process: two real low-memory samples one second apart were
  accepted, the 16384 MiB connection was bounded by a two-second smoke-test
  timer, and disconnect occurred after approximately 2.015 seconds. Final
  unload left no instances; two memory samples both read 66,068,480 private
  bytes with over 42 GB physical and 70 GB commit headroom.

## Live admission failure and timing revision

Open Shaders source `313277eed7546a024c35d5e7f6b80e52f719c3eb`, DLL SHA-256
`0CFA77B3997B1A1D96FBD86F5C1F46947F85D4B2357E28F454AA60BFB7FBB36B`,
DevBench 1.22.0+pt.1.17.0, process 18716 started
2026-09-29T20:36:06.1961723Z:

- Warm-up run 3 completed all 6814 steps in 72930 ms, with no failed steps,
  successful scene/menu assertions, finished pose driver and input cleanup.
  The camera returned to VR state 9 without a free-camera owner. Shader
  compilation completed 142/142 tasks with zero failures.
- Nine PNG images were saved: full stereo and both eyes at the entrance,
  main hall and gallery. Requested and actual camera transforms, weather,
  hour and capture frames are retained in local attempt evidence. This is
  image acquisition, not a completed OS/CSX quality comparison.
- Collector private usage was 66,035,712 bytes in both admission samples.
  GPU readiness passed at 20:52:47.708556 UTC, with 132 positive GPU pass
  types and 38,933 samples, after advancing from 23,983 samples. No GPU
  timestamp errors were observed.
- The world-reset controller call and tool transport delayed admission
  until approximately 20:53:01.3 UTC, 13.6 seconds after readiness. The
  eight-second expiry rejected admission despite healthy GPU evidence.
  No measured replay was dispatched. This was an automation sequencing
  failure, not an Open Shaders performance or GPU timestamp failure.
- The collector stopped at 20:53:06.480 UTC and was fully unloaded. Its
  final diagnostic held 1356 frame markers and 90,742 GPU samples without
  timestamp errors. Two subsequent private-memory samples both read
  64,258,048 bytes. No raw partial trace was retained.

Protocol v2 removes the arbitrary readiness expiry and maximum observation
interval. Live process/connection, error and progress checks remain. Combined
`prepare` and `finish` operations perform sampling inside one collector call,
avoiding transport overhead between samples and admission or disconnect.
A slow final drain is retained as a timing diagnostic rather than rejected
solely by duration. GPU failures and incomplete coverage still reject data.
The overall watchdog changes from 100 to 180 seconds: two observed 72.93-second
routes plus approximately 30 seconds of control margin. It is only a backstop;
normal capture still stops immediately at verified completion. The 16384 MiB
memory cap and physical-memory admission remain unchanged.

Validation after this revision:

- `python tests/test_tracy_replay_guard.py`: 31 tests passed, including
  healthy admission after a 14-second delay, longer observation/drain
  intervals, retained regression/error rejection, combined admission and
  completion, the 180-second configured ceiling, independent timer stop,
  and source/package parity.
- At that revision checkpoint no new game connection had been made after
  the failed attempt. The following fresh process supplies the subsequent
  live validation; offline tests alone did not establish a game baseline.

## Successful protocol-v2 interior capture

Measured automation source: `032b87d09219eda698c17ae9407194d2858b995a`.
Open Shaders source and DLL hash match those recorded above. DevBench remains
1.22.0+pt.1.17.0. Process 49808 started at 2026-09-29T21:07:06.0186079Z.
Unified Water was loaded, with the matched comparison preset and fixed
SteamVR null HMD qualified before capture.

- Untraced warm-up run 4 completed all 6814 steps in 71037 ms. Measured run
  12 completed all 6814 steps in 68226 ms, with successful scene/menu
  assertions, finished pose driver, input cleanup and camera restoration.
- Engine log replay boundaries are 2026-09-29T21:20:15.540Z through
  21:21:23.791Z. Requested game hour was 8.149421691894531; observed hour at
  dispatch was 8.14944839477539. The same requested hour is pinned for CSX.
- One Tracy connection captured the entire replay. The independent guard
  stopped with `replay_complete`; no GPU timestamp error or resource/deadline
  failure was recorded. Positive GPU occurrences cover every replay second
  and continue about 11.354 seconds beyond engine completion.
- The saved file is 388233863 bytes, SHA-256
  `93BAD4926820A67BEDBAFE00F3272FFD86A71CCB07B3DA77A055AF2AFC22455A`.
  Save, unload and reload preserved 5999 frame markers, 295928078 CPU zones,
  809698 GPU zones, first timestamp 744305694611 ns and final timestamp
  868319015154 ns. Allocated-zone counts are not positive-occurrence counts.
- Nine PNGs preserve full stereo and both eyes at entrance, hall and gallery.
  All CRCs and decoded payload lengths passed. Both separate eye images at
  each viewpoint were visually checked without HUD/capture notifications.
  The full-stereo display helper rejected its image transfer; all three
  stereo pairs were then visually checked through half-resolution review
  copies made with existing Windows imaging. Originals remain unchanged.
- Clear weather was observed at dispatch. A cloudy reading about 80 seconds
  after completion is interior metadata and does not establish a change
  within the measurement window or justify repeating the run.
- Six shader-compilation tasks occurred about 55.58 seconds after replay
  start, totaling 132.616 ms across task scopes, maximum 32.450 ms. They
  remain visible in the results and are not reclassified as a frame stall.
- Timing uses retained UTC/trace observation brackets rather than a shared
  marker. Observed offset spread is 8.415 ms, with unknown receive lag.
  The estimated replay window contains 3676 frame intervals: mean 18.562 ms,
  median 18.963 ms, p95 29.086 ms, p99 34.314 ms. Excluding the eight initial
  restoration/assertion steps gives 3287 intervals: mean 18.766 ms, median
  19.471 ms, p95 29.375 ms, p99 34.153 ms. Boundary sensitivity is preserved.
  These are frame intervals, not total CPU or GPU busy times; those enclosing
  scopes are unavailable in this trace. Per-pass CPU/GPU scopes are exposed.
- All 543 exposed names were processed without sample truncation: 279859813
  positive-duration CPU occurrences and 420212 positive-duration GPU
  occurrences. Exact histograms, per-frame counts/totals and compact raw
  occurrence files passed count/hash checks. Raw events for six very frequent
  CPU names remain in the verified trace rather than duplicated as gigabytes
  of tuple files. Statistics-index filtering explains why these counts are
  not interchangeable with allocated-zone counters; omitted categories are
  not individually enumerated by the installed API.
- After export and unload, no collector instance or active task remained.
  Two final samples both measured 89956352 private bytes (85.79 MiB), with
  more than 35 GB physical and 44 GB commit headroom. The earlier retained
  worker-memory problem did not recur.
- Final DLL, DevBench, preset and recording hashes matched their preflight
  identities. All 31 focused guard regression tests passed after the protocol
  clarifications. Source and packaged documentation remain identical.

## Successful protocol-v2 exterior capture

Measured automation source: `b8070e2f0005eda9f225bab910d1dd73c19d8c5e`.
Open Shaders source, DLL hash and DevBench version match the interior.
Process 23188 started at 2026-09-29T21:55:58.5859899Z. All 37 effective
feature settings, the preset and nine profile files matched the interior.
Unified Water and fixed-null-HMD qualification passed. The runtime log
confirmed DLSS Quality input 1008x1120 and output 1512x1680 per eye.

- The pinned exterior recording actually ends in Riverwood02 despite its
  GuardianStonesToWhiterun filename. Both forks must use this exact path.
- Untraced warm-up run 4 completed 6804 steps in 103319 ms. Measured run 11
  completed 6804 steps in 100573 ms, without failed steps, with successful
  scene/menu assertions, finished pose driver and no held input.
- Engine replay boundaries: 2026-09-29T22:20:47.791Z through 22:22:28.388Z.
  Requested hour 14.362698554992676, dispatch hour 14.362725257873535,
  timescale 1. Helios_SkyrimClearTU was observed at dispatch, all eight
  in-replay checks and the later postcondition. The resolved weather ID,
  control cadence and camera transforms are pinned for CSX.
- One fresh Tracy connection used the unchanged 16384 MiB memory cap.
  Twice the observed 103.319-second warm-up plus margin justified a 240-second
  outer watchdog. The guard stopped on replay_complete, without GPU errors
  or resource/deadline failures. Conversation compaction followed stop.
- Saved trace: 242741061 bytes, SHA-256
  `EF4D761E1221BFE91B28FFA383D74907ADD12B63B1F5236EA2A85DD6E989E709`.
  Reload preserved 5037 frame markers, 160068877 CPU zones, first timestamp
  1476446102689 ns, last timestamp 1601054528407 ns, and every named CPU/GPU
  timing statistic. Live GPU begin count was 763228; live context count and
  reloaded count were both 763077. Source inspection established the 151
  difference as begun zones without their first GPU timestamp: live global
  count advances on begin, context count on timestamp, and reload sums the
  serialized context counts. This is not lost measured timing data.
- Positive GPU samples cover every walking second and continue 12.048 s
  beyond replay end. Replay seconds 4 and 5 have no samples; both lie inside
  one preserved 3.761-second frame gap during exterior restoration, before
  the walk. The full-replay statistics retain this loading pause. Requiring
  a sample in every wall-clock second would incorrectly reject loading.
- Estimated full replay: 4127 intervals, mean 24.371 ms, median 21.002 ms,
  p95 36.918 ms, p99 44.464 ms. Excluding 9954 ms of initial restoration:
  3817 intervals, mean 23.744 ms, median 21.351 ms, p95 37.111 ms,
  p99 43.898 ms. Observed UTC/trace offset spread was 17.412 ms; unknown
  receive lag and boundary sensitivity remain explicit limitations.
- All 582 exposed names were processed: 153149822 positive CPU occurrences
  and 448488 positive GPU occurrences. Histogram counts/totals, raw file
  sizes/hashes, no-truncation checks and full walking GPU coverage passed.
  Twelve shader-compilation scopes within replay totaled 78.413 ms;
  inclusive task time alone is not an inferred frame stall.
- Nine PNGs passed CRC/payload checks, with full stereo and both eyes at
  Guardian Stones, the Riverwood approach and Riverwood endpoint. All views
  were visually inspected; stereo review used half-resolution previews.
  Originals and exact realized transforms remain unchanged.
- Final renderer, DevBench, preset and recording hashes matched preflight.
  After export/unload, the instance registry was empty, all tasks completed,
  and two memory samples both read 93921280 private bytes (89.57 MiB), with
  over 35 GB physical and 45 GB commit headroom. No retained worker recurred.
- This follow-up changes protocol documentation only. The prior 31 focused
  guard tests remain the implementation validation; no new guard code or
  shader change was made. Source/package documentation parity was checked.

Both OS routes are captured and extracted. CSX runs and side-by-side quality
and performance comparisons remain pending. Raw trace, settings, identity,
route, image, replay, timing and extraction evidence remain local; no raw
game evidence is bundled into the distributed automation package.

## Image ownership correction, 2026-09-30

CSX process 44312 completed its 6814-step Dragonsreach warm-up, but no
Tracy connection or measured replay was made. Its local image runner sent
a synchronous scenario containing 20.1 seconds of declared waits through
a ten-second request timeout, then restored the camera while the scenario
continued. Asynchronous admission and terminal-owner tracking corrected
the local runner. Separate PNG publication failures persisted after that
correction; these are renderer storage errors, not a reason to loosen the
benchmark admission gate or substitute a derived eye image.

The controller now reserves the existing receipt allowance beyond declared
synchronous scenario pacing, including repeats and nested child timeouts.
Asynchronous admission and status reads keep their short request budgets.
The protocol requires the scenario transcript and every screenshot's
terminal artifact receipt before camera cleanup and Tracy admission.

Validation: `pwsh tools/devbench-control/Test-DevBenchControl.ps1` passed
250 checks. New cases cover the 20.1-second image sequence, asynchronous
admission, owner status, nested repeats, asynchronous child exclusion and
conditional waits. Adversarial review added checks against the actual dispatch
function for slow preflight, paced requests and asynchronous admission. Only
known asynchronous scenario/record semantics exclude a server wait; other
tools retain their explicit timeout. Fixed-build in-game image qualification
and the CSX benchmark remain pending; the rejected attempt is not a measurement.

## Tracy connection hand-off correction, 2026-09-30

CSX process 40968 completed warm-up and nine native screenshot publications
with the corrected screenshot DLL (source `2467ba77cbfc1ed886a062cdea27b4f031b864ba`).
The assistant then used the Tracy connection success sentence as an instance
ID. Admission and the first cleanup call both addressed that invalid ID;
no measured replay started. The correct literal alias was disconnected,
unloaded and verified absent; collector private memory was 91865088 bytes.
The user requested deletion of the entire attempt's images and capture data.
Only the small failure/regression record and consumed-process marker remain.

Protocol v3 and the maintained JavaScript hand-off bind the requested alias
before connect. The process claim is flushed before any connection attempt,
including lost responses. Cleanup verifies that claim and PID, and works
before a collector guard exists. Other owners remain untouched. Textual
Tracy errors cannot pass admission, and cleanup errors preserve the original
failure. No renderer, screenshot encoding or profiler instrumentation changed.

Review also moved image decoding, visual comparison and report work after
capture stop. The prepared sequence continues from warm-up/images through
memory proof, connection, GPU admission and replay without host analysis.
World-time reset/inspection/replay remain adjacent steps in one scenario.
The reference is each OS run's observed dispatch game hour: interior
8.14944839477539 and exterior 14.362725257873535. Both were measured after
the final time reset; neither includes the preceding preparation delay.
These are dispatch-boundary observations, not first-rendered-frame clocks.

Validation: `python tests/test_tracy_replay_guard.py` passed 37 tests.
`testTracyReplayRunner` passed 14 mocked hand-off/parser cases in the existing
functions JavaScript runtime, using the preserved actual connection response.
Cases include text errors, pre-guard failure, lost connect response,
reservation failure, missing admission, replay/finish errors and cleanup
error retention. Source/package parity is part of the Python suite. No new
live connection was attempted; the fresh-process CSX measurement is pending.
