# Fixed-HMD DevBench replay with Tracy

Protocol: `devbench-tracy-replay-v2`. This protocol uses the existing
DevBench controller/direct tools, Tracy MCP and screenshot provider. The
adjacent Python helper supplies admission checks and an independent stop
timer inside the existing collector; it does not install another profiler,
change instrumentation, or modify either renderer. Read this entire file
before starting a route. Do not improvise repairs during a measurement.
The [initial validation record](tracy-replay-validation-20260929.md) separates
regression/synthetic checks from the still-required full game validation.

## Inputs and ownership

Supply explicit paths for the managed workspace manifest, DevBench runtime
metadata when using the controller, deployed renderer DLL, route JSON,
Tracy Python/helper paths, and an empty attempt evidence directory. Keep a
separate campaign directory for immutable process claims and shared settings,
route, image-pose and weather/time manifests. No drive letter, modlist name,
MCP port, source commit, or form ID is a machine default.

Select one DevBench lane using `skills/devbench-control/SKILL.md`. Direct
tools are mandatory when callable. Otherwise use the maintained controller,
never ad hoc HTTP. Every measured call on that lane uses the performance
neutrality guard. Use zero mutation retries. A missing CSX Build ID is allowed
for Open Shaders; process and physical DLL hash verification remain mandatory.

Run exactly the requested campaign order. For the OS/CSX comparison that is
OS interior, OS exterior, CSX interior, CSX exterior. Each measured route
requires a fresh Skyrim process and one Tracy connection. Warm-up and image
acquisition may precede that connection in the same process. A disconnect
consumes that process for this protocol, even when replay was not dispatched.
Do not reconnect to recover GPU timestamps. Keep the process claim outside
the attempt directory so deleting a failed trace cannot erase this rule.

## Gates before connecting Tracy

Complete these in order; save observed values and receipts, not a checklist
of unsupported booleans. Any missing or failing gate blocks measurement.

1. **Capabilities and identity.** Pin renderer source, DLL SHA-256/size,
   available build manifest, DevBench version/hash, recording hash, Tracy
   client/collector protocol versions, OS/GPU/driver, and process PID plus
   start UTC. Inspect the exact enabled AIO, loose overrides, unmanaged Data
   and Overwrite. Record the current tool schemas, including asynchronous
   replay/status, camera and screenshot support. Do not infer methods from
   another fork. Verify disk space for the trace and full exports (at least
   twice the collector cap). Never change packages with the game running.
2. **VR and settings.** Qualify null HMD and fixed application-observed pose
   using the existing null/head-pose controllers. Preserve origin, height,
   IPD, both projection matrices, per-eye resolution, refresh/reprojection
   policy, graphics settings, assets, INIs and load order. Pin actual engine,
   DLSS input/output and foveal dimensions, not just menu labels. Disable
   unrelated tracing, overlays and automatic quality/location overrides.
   Verify Unified Water is actually loaded in both forks. Preserve the shared
   comparison preset and effective settings; do not use old fork-parity
   optimization presets or their different route/blinding requirements.
3. **Route qualification without Tracy.** Read the physical JSON, determine
   its actual scheduled duration and all toggle commands, and record its
   default scene-restoration behavior. Replay once asynchronously, observe
   the complete terminal receipt and explicit scene, camera, pose-driver,
   input-release and menu postconditions. A successful scheduler alone is
   insufficient. Finish shader/streaming warm-up; all compilation must be
   complete with no errors before proceeding. Do not attach a pilot collector.
4. **Images outside timing.** Follow the image section below. Restore normal
   camera and screenshot settings, then reset the route's known initial
   toggle/equipment state. A recorded `tgm` toggle needs an observed initial
   state for every warm-up/replay; do not blindly toggle twice. Prove there
   are no active camera/input owners or pending screenshot jobs.
5. **World state.** Resolve and force one explicit weather editor ID that
   survives the modlist's weather replacement. Verify observed weather,
   transition percentage, dry/wet state and hour. A vanilla `fw` command can
   be remapped to different weather on each use; requested weather is not
   evidence of actual weather. Set and verify the shared start game hour,
   timescale and scene immediately before the measured dispatch. Preserve
   request UTC, observed game hour and terminal hour. Do not silently freeze
   time or use `tfc 1`. Store the realized shared values for the other fork.
6. **Collector cleanup.** List Tracy instances AND background tasks. Finish
   owned saves/exports. For each owned inactive instance run `CLEANUP_EVAL`
   from the helper, then `unload_capture`. Do not unload another task's
   instance. Require an empty instance list and no pending/running/cancelled
   tasks. Tracy's task cancellation does not stop an executor thread, so a
   cancelled task is unproven, not idle.
7. **Real memory proof.** Resolve the actual Tracy Python server PID and start
   time from its endpoint/process command line, not its virtual-environment
   launcher PID. Read private bytes and system free physical/commit memory
   twice one second apart. Both private-memory samples must be at most
   **512 MiB**. Both available physical and available commit memory must be
   at least **capture cap + 8192 MiB**. Use **16384 MiB** for this campaign;
   never unlimited, and do not change the cap between forks. If either
   sample fails, do not connect. Restart only the proven task-owned idle
   collector if safe; otherwise report the shared-owner blocker. Recheck
   identity, instances, tasks and memory after any restart.

For Windows, resolve and preserve the process identity with the existing
shell tool, then read memory using the helper in ordinary Python (no WMI
permission or additional package is required):

```powershell
$collector = Get-Process -Id $CollectorProcessId -ErrorAction Stop
[ordered]@{
    pid = $collector.Id
    startedUtc = $collector.StartTime.ToUniversalTime().ToString('o')
    utc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json
```

```python
import runpy
helpers = runpy.run_path(helper_path)
memory = helpers["windows_memory"](collector_pid)
```

Pass the parsed instances, tasks and each memory receipt to
`require_clean_collector(instances, tasks, memory, 16384)` in the helper.
This check is offline and must pass before `live_connect`. Save the full
inputs and result. Do not substitute working set for private bytes: paging
can make a retained multi-GB trace look small. An empty instance registry is
also insufficient. Python eval functions can retain their globals, `ctx` and
snapshots of other workers in reference cycles; Tracy's allocator budget is
shared across workers. Use the helper's `eval_code` for every guard call;
it clears the per-eval namespace even on errors. Clear temporary eval
namespaces after extraction too, collect garbage before unloading, and
repeat this physical-memory proof after each file reload.

## Bounded measured capture

Prepare all call arguments, output paths, status handling and the `finally`
cleanup before connecting. Verify the asynchronous warm-up already exercised
the exact replay/status schemas. No settings investigation, image capture,
large zone export, source editing or dependency repair belongs in this window.

1. Preserve the empty-collector memory proof and process claim path
   `<campaign>/processes/<pid>-<start-identity>.json`. It must not exist.
   Apply and verify the prepared world state before connecting. Call
   `live_connect` exactly once with a unique attempt alias and the pinned
   16384 MiB cap. Immediately call `prepare` through one Tracy `eval`:

   ```python
   # Generate code locally; pass the returned string to the existing eval tool.
   code = eval_code(helper_path, {
       "action": "prepare", "owner": attempt_id, "expectedPid": game_pid,
       "preflight": {"instances": [], "tasks": completed_tasks,
                     "memorySamples": two_saved_memory_receipts,
                     "limitMiB": 16384},
       "processStartedUtc": game_start_utc, "seconds": 180,
       "processClaimPath": process_claim_path,
       "receiptPath": absolute_attempt_path + "/collector-guard.json"
   })
   ```

   All directories must already exist. The exclusive claim prevents another
   capture in the same game process. The 180-second timer runs inside Tracy's
   Python process and disconnects independently of DevBench, the assistant
   and MCP response delivery. It is a ceiling, not a requested capture length.
   The observed interior warm-up took 72.93 seconds; 180 seconds allows two
   such route durations plus approximately 30 seconds of control overhead.
   Stop immediately after completion. This margin does not add a pilot or
   intentional idle capture. Use the same cap for both comparison builds.
   For another route, qualify its duration and control overhead before
   choosing a deadline; do not derive a tight ceiling from metadata alone.
   If preparation fails, disconnect immediately and reject the attempt.
   Arming itself verifies that both low-memory samples belong to this exact
   collector PID, are at least one second apart and no more than 30 seconds
   old. Supply the actual preserved instance/task responses, never a manually
   invented clean result. The empty array above represents a verified empty
   response. Save the preflight before connecting so it stays within that age.
2. `prepare` arms the timer, takes two GPU observations 0.75 seconds apart,
   validates progress and admits exactly once inside the collector process.
   Both samples must match the game PID, be connected, have positive GPU
   durations and no Tracy D3D11 timestamp/disjoint errors. Frames, trace time
   and GPU sample count must advance. Failure disconnects and prevents
   admission. Save the returned `readiness` and `admission` boundaries.
   Keep these operations inside the collector to avoid unnecessary capture
   overhead. Readiness has no arbitrary wall-clock expiry: admission checks
   the same connected process, GPU errors and non-regressing progress.
   Transport delay alone is not evidence that GPU data became invalid.
   The overall deadline and memory cap bound stalls and runaway collection.
   Do not infer GPU health from CPU zones or context names.
   This checks the one measured connection; it does not start a pilot.
3. Immediately dispatch the already prepared, short synchronous DevBench
   `scenario`: reapply the pinned weather/hour, wait for a rendered tick,
   inspect scene, then invoke `record` with `async:true` and the pinned
   recording path/scene/coupling arguments. The outer scenario returns the
   queued inner replay without waiting for the route. Preserve that inner
   replay's actual run ID and all world receipts immediately; reject a world
   mismatch even if replay was queued. No additional investigation or host
   calls belong between `prepare` and this dispatch. Preserve the interval
   between admission and dispatch as boundary uncertainty. A generic semantic
   adapter may call the queued payload unverified; that never authorizes a
   second dispatch. Never use a long synchronous replay: MCP session
   retirement can lose its result while the game continues running.
4. Poll `record {action:status, runId:<returned ID>}` on the selected lane
   with short requests, approximately once a second. Preserve every response
   and UTC boundary. Bound individual requests to ten seconds and stop at
   the first terminal receipt. The receipt's run ID must match; `done=true`
   and `ok=true` still require the complete inner result, expected step count,
   explicit assertions/postconditions and ownership cleanup. Plain
   `record status` without a run ID describes the recorder, not this replay.
   A single read-only status timeout is not proof that replay failed: keep
   polling the same known run ID while the process and collector remain
   healthy, within the overall watchdog. Never repeat the replay mutation.
   If the queued receipt is lost, inspect existing ownership; never dispatch
   a second replay. An unresolved owner fails this attempt.
5. At verified terminal completion, call `finish` in one Tracy eval. It
   observes GPU progress across a 0.75-second drain and immediately stops
   with reason `replay_complete`, preserving both observations. A drain
   with missing progress or GPU errors rejects completion and still
   disconnects. Record its actual duration; a slow response alone does not
   invalidate healthy, complete data. Never spread the drain across
   transport calls.
   Require `stopReason=replay_complete` and no failure/error fields. An
   existing deadline/failure remains a failure. On any caller exception use
   `stop` with reason `failure` in `finally`; the independent deadline remains
   armed until stop. Do not wait for analysis or a user reply before stopping.
   A timer stop, spontaneous disconnect, memory cap, process change, missing
   terminal receipt or GPU error rejects the attempt. Never reconnect to
   extend or splice a partial capture.
6. Verify disconnected and let background statistics finish, reporting
   progress through bounded individual polls. Offline processing, save and
   export have no fixed success cutoff: they can legitimately take longer
   for a large complete trace. Diagnose a stalled worker separately from
   whether the captured data are complete.
   Save with the existing asynchronous `save_trace`, retain task ID, poll to
   completion and verify the nonempty physical file plus SHA-256/size. This
   offline save can exceed the capture deadline without recording more data.
   Release the guard (`release`); retain its receipt including any timer,
   disconnect or journal error. Such errors cannot be silently accepted.
7. Export and verify the required data below before declaring this route
   complete. Run `CLEANUP_EVAL`, unload, prove empty/low-memory, reload just
   this saved file, wait for background processing, and confirm the same
   frame/CPU counts, timeline endpoints and named CPU/GPU timing statistics.
   Compare reloaded GPU counts with the saved live GPU-context counts:
   the live global counter counts zone begins, while context counts advance
   on the first GPU timestamp. Preserve both counters and their difference;
   do not mistake begun zones lacking timestamps for lost measured timings.
   Unexplained differences remain a failed verification. Finish extraction
   from one loaded trace at a time, then unload and prove low memory again.

Check positive GPU coverage throughout the walking portion and beyond its
terminal boundary. A zero-sample interval during initial scene restoration
requires a preserved enclosing frame interval with no intervening frame
marks, wholly before the walking portion. Retain that loading pause in the
full-replay statistics and report it separately. Do not waive unexplained
GPU gaps while rendering or classify every loading pause as collector loss.

Every guard request has `owner` and `action`. `prepare` takes the arming
fields shown above; `finish` needs only the owner. `stop` takes `reason` and
`status` reads the timer receipt. Low-level `arm`, `observe`, `ready` and
`admit` remain available for focused tests, but the measured route uses the
combined operations. A caller cannot admit the same replay twice. The helper
does not dispatch DevBench or stop Skyrim; its role is to bound collector
ownership. Follow the full protocol's gates and use the existing DevBench
transport for all game operations.

## Route definitions and matched images

Pin the actual installed files; different hashes require review before use.

| Route | Pinned recording | Start hour | Required interpretation |
| --- | --- | --- | --- |
| Interior | `DragonsreachTorchThirdPerson.json`, SHA-256 `1CA4569E6CDFDEFD1F34C6FB32E24A448C0F4F74DFDDD51D186B19BB5299256B` | 8.149421691894531 | Metadata duration 61549 ms; qualified source has 6814 replay steps including restoration. Preserve exact async arguments, torch/third-person route and VR camera restoration. |
| Exterior | `GuardianStonesToWhiterun.json`, SHA-256 `5B92A737078732C1ECA7B924BAE7D27E088EB1E2935ED47243E198DF96214686` | 14.362698554992676 | Metadata says 90611 ms but 3397 pose waits total 33970 ms. Use measured boundaries. VR requires explicit `force=true`; independently verify Tamriel, path and camera because force relaxes scene checks. |

These flat recordings contain no tracked-head motion. They are usable for a
controlled VR-to-VR comparison only with the same qualified fixed HMD and
pose-interpolated player path. They do not establish flat/VR equivalence.
Use the installed recipe's restoration mode consistently. Cell restoration
does not necessarily restore recorded hour/weather; anchored restoration
can re-trigger weather replacements. Preserve resolved editor IDs and
requested/observed state rather than assuming either behavior.

For the September OS/CSX campaign, the resolved Dragonsreach weather is
`Helios_SkyrimClearTU`, not an arbitrary replacement of `SkyrimClearTU_A`.
Resolve its form ID from the current load order on each machine. Qualify and
pin the exterior's realized clear weather before its OS measurement, then
use the same editor ID and observed state for CSX.

Keep interior weather observations as scene metadata. A weather reading
taken after an interior replay does not establish a change during its
measurement window and must not alone invalidate the run or require a
repeat. Distinguish that observation from measured lighting/image changes.

Capture PNG full stereo plus both separate eyes when exposed. Keep HUD,
exposure, torch/equipment, null pose, projected FOV, hour/weather and temporal
settling identical. Save actual camera transforms and dimensions alongside
requested values: camera pitch/yaw may clamp or differ in VR. A screenshot
with a different observed camera is not a matched view. Wait at least six
seconds after each screenshot before another to avoid notification overlays;
verify the images themselves and repeat only image acquisition if needed.
Use ordinary free camera, never `tfc 1`. Restore normal camera in `finally`.

Interior reference requests, in the camera API's documented units:

| View | x | y | z | yaw (rad) | pitch (rad) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Entrance | -448 | -128 | -150 | 0 | 0 |
| Main hall | -448 | 1600 | 200 | 0 | 0 |
| Upper gallery | -784 | 1719 | 640 | 1.714786 | 0.35 |

The gallery request previously produced an observed yaw near 1.723928 and
pitch near 0.052325. Qualify the realized view before freezing the campaign
manifest; do not claim requested pitch 0.35 was applied. Define exterior
views from the pinned route's guardian, approach and actual endpoint,
record their realized transforms on OS, and replay those exact views on CSX.
Images remain labeled OS/CSX; this campaign does not request blinding.

Dispatch paced image scenarios with `async:true`; keep short request
timeouts for admission and status reads, not for the scenario's full
duration. Retain the actual `runId` and poll that owner until its terminal
transcript is saved. Then resolve every accepted screenshot request to its
terminal artifact receipt, verify its physical PNG and hash, and only then
restore the camera. Do not restore it in an unconditional `finally` while
server-side ownership is unresolved. A failed image write blocks Tracy
admission; retain its diagnostic and fix the cause before another benchmark.
Do not silently replace a failed native eye capture with a crop or a later
frame. Any changed acquisition protocol needs explicit campaign review and
matching treatment of both forks.

The pinned exterior recording actually ends in `Riverwood02`, despite its
`GuardianStonesToWhiterun` filename. Preserve the supplied path in both
forks and label the actual endpoint; do not silently extend it to Whiterun.
The OS exterior qualified `Helios_SkyrimClearTU` at the requested start hour
14.362698554992676 and timescale 1. Record weather/hour at dispatch and
periodically during this exterior replay, with the same control cadence on
CSX. The observed 103319 ms warm-up supports a 240-second outer watchdog
(two route durations plus about 30 seconds of transport margin); completion
still stops capture immediately. Keep the exact realized camera transforms
and screenshot requests in the campaign manifest, not machine-specific paths
in the distributed protocol.

## Completeness, extraction and comparison

Preserve a manifest linking identity/settings/scene receipts, route hash,
null-HMD qualification, memory proofs, replay arguments/run ID/full terminal
result, timer receipt, raw trace/hash, all images/hashes/observed transforms,
raw numeric exports and their summaries. Record UTC and monotonic capture,
dispatch, completion, stop and save boundaries separately from game hour.

Require trace coverage before dispatch through verified replay completion,
positive GPU samples throughout the measured interval and its end, and no
timestamp errors anywhere in the capture. The trace's final event must not
precede the terminal window. Check whole timeline/frame coverage as well as
per-second GPU occurrence coverage; inspect missing bins against known
loading phases and require the same treatment in both forks. A final CPU
event alone does not establish GPU coverage. Reject an unexplained trailing
gap or missing interval rather than filling it with zero or interpolating it.

Use shared frame/section/zone boundaries if both builds expose them. Otherwise
retain bracketing trace `lastNs` observations plus DevBench dispatch/terminal
UTC receipts and the full asynchronous status polling intervals. These are
brackets with transport/collector lag, not an exact clock conversion. Report
the selected window, uncertainty and sensitivity to boundary frames. Do not
claim exact route-only timing from host UTC or `get_capture_time` alone.
Retain raw capture so analysis can be corrected without another game run.

Export complete frame boundaries and CPU/GPU occurrence start/duration data
for every exposed pass used in the comparison. `get_*_occurrences` defaults
to a sample cap: request at least the recorded total count plus one, check
counts, and never accept silent truncation. Preserve raw names, source IDs,
threads/contexts, units and completeness. Export one pass at a time to disk
outside capture, not huge arrays through a chat response. Release large
Python arrays and eval namespaces before the next file is loaded. When very
frequent CPU hooks would duplicate gigabytes of events, retain their raw
events in the verified trace and export exact duration histograms plus
per-frame counts/totals computed from every exposed occurrence. Record this
storage choice explicitly; do not truncate samples.

Check the installed binding implementation before interpreting its counts.
The inspected protocol-83 occurrence API uses positive-duration statistics
indexes, merges source locations by name and exposes no per-occurrence GPU
context/eye ID. Its total allocated-zone counters also include records absent
from those indexes. Preserve both counts and the difference without calling
it lost capture data or inventing zero durations. Source IDs, zero-duration
records and individual GPU eye attribution remain unavailable through this
API; retain the original trace for later inspection.

Calculate count, mean, median, p95 and p99 in ms with the same definition on
both builds. `summarize_ns` specifies linear-interpolated quantiles. Keep
these distinct:

- Frame intervals from Tracy's primary frame markers, including pacing/waits.
- CPU work from an equivalent measured CPU frame/root scope, when present.
- GPU frame cost from an equivalent enclosing GPU scope, when present.
- Per-pass CPU and GPU costs, with dispatch count, scope and nesting labels.

Do not label frame intervals as CPU busy time, add overlapping/inclusive
zones into a GPU frame total, or infer missing CPU/GPU numbers. If a common
whole-frame scope does not exist, report that metric as unavailable and show
the shared frame intervals and matching passes that do exist. Map equivalent
pass scopes explicitly; report unmatched zones separately, including work
from nominally disabled features. Give both cost per invocation and cost per
frame where occurrence attribution permits it. Show compact side-by-side
graphs and tables with OS, CSX, absolute ms delta and percent delta; include
tail percentiles and number of valid samples. Compare differences only; do
not add optimization proposals to this campaign.

Use the same count of full repetitions per fork; one completed run per
requested route is a descriptive comparison without repeatability claims.
Do not silently add or pool repetitions. Assess image differences separately
for center/periphery, seams, edge detail, shadow/AO, water, temporal artifacts
and stereo consistency. Static PNGs cannot prove temporal stability; label
that limit instead of inferring ghosting from one frame.

Only report **ready for the next route** when the full trace is verified,
all available numeric data are exported, images are visually checked,
the manifest is complete and owned collector memory is released. A replay
can finish successfully while the performance capture fails. Preserve that
distinction. Failed data may be deleted when explicitly requested, after
retaining the small failure classification and protocol regression record;
never delete shader caches, build outputs, saves or another task's evidence.

## Validation and known limits

Run `python tests/test_tracy_replay_guard.py`. Its fake workers exercise
memory admission, GPU progress/error rejection, exactly-once admission,
transport-delay tolerance, independent deadline/disconnect,
namespace-cycle cleanup and quantiles.
An existing small synthetic Tracy producer can verify arm/stop/save/unload
against the actual bindings without launching Skyrim or a captured pilot.
CPU-only synthetic data must fail the GPU gate; never waive that gate to
make a smoke test pass. Record offline/synthetic and real game validation
separately. A tested guard is not a claim that a full game capture succeeded.

The protocol prevents accepting retained-memory, missing-GPU and truncated
captures; it cannot guarantee a game or driver never fails. The inspected
Tracy D3D11 dependency can lose query recovery across a disconnect. A fresh
game process and one connection avoid that observed path without changing
renderer code; this is not a permanent dependency fix.
