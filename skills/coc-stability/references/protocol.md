# Deadline-driven COC stability protocol

## Pre-session Codex and evidence readiness

Complete this phase before asking the user to load Skyrim. Do not defer it into
the live start window.

1. Locate Community Shaders' canonical `tools/ghidra-mcp-control.ps1` and call
   `status`. Require `ok: true`, `state: ready`, `managed: true`,
   `endpointReady: true`, and `listenerOwnedBySession: true`. If it is stopped,
   call `start`; it reuses the persistent project and saved paths. Only a first
   setup may supply the GitHub `ghidra_*_PUBLIC` installation, Java home, and
   exact analysis program for the intended build.
2. Inspect the current Codex tool registry and require the Ghidra MCP tools to
   be present. Confirm `devbench_vr` remains registered at
   `http://127.0.0.1:8921/mcp` and the installed `devbench-control` entrypoint
   is present. DevBench is game-owned, so its endpoint and direct MCP tools are
   not required to be live before Skyrim starts.
3. Make one harmless Ghidra MCP health, version, or project-list call. The
   installed GitHub files and a ready controller receipt are not substitutes
   for a successful call through the current Codex window.
4. Run `coc-evidence-control inspect`. Require its CDB/WinDbg, ProcDump, and
   free-space checks to pass.
5. Run `coc-evidence-control arm` for `SkyrimVR.exe` and retain the returned
   state path, collector PID/start time, capture directory, and tool hashes.
   `armed-waiting` is the expected state before Skyrim starts.

The repository Ghidra controller exclusively owns the persistent headless
GhidrAssistMCP server and project. The evidence controller discovers the
installed GitHub `codex-ghidra-live` layout but owns only ProcDump and CDB.
ProcDump is the live collector because it can already be waiting for the game
and can capture both an unhandled exception and a Windows hang. It uses full
dumps, a two-dump limit, and no normal-exit or first-chance trigger. CDB/WinDbg
and Ghidra MCP are the post-capture analyzers.

If the Ghidra MCP tool is absent, its call fails, DevBench registration or its
local controller is missing, or local evidence readiness fails, stop before the
game is loaded. Start the managed Ghidra MCP server through the repository
controller as needed, restart Codex so Ghidra tools are attached, and repeat
this phase. Do not diagnose a missing installation merely from a missing tool.

A readiness receipt is reusable only while all of these remain true:

- the same Codex window still exposes Ghidra MCP and the DevBench controller;
- the exact DevBench loopback registration is unchanged;
- the Ghidra receipt still proves the same managed process and owned listener;
- the owned ProcDump PID and start time still match the state receipt;
- `coc-evidence-control status` reports a live monitor;
- after Skyrim starts, exactly the intended game PID is observed.

A new Codex window, missing tool, exited collector, or new Skyrim PID requires
the corresponding recheck or re-arm before another live trigger.

## Fast start-cell establishment

Before the live signal, select the direct DevBench MCP route if it is attached;
otherwise select the installed `devbench-control` loopback route. At the moment
the user confirms Skyrim VR is in-game, immediately queue one async server
scenario whose only steps are a 10,000 ms wait followed by exactly:

```text
coc WindhelmExterior01
```

Queue that deadline before live endpoint discovery, identity, status,
capability, schema, or capture calls. The selected loopback controller may make
the minimum connection needed to submit that known scenario; it must not run a
discovery/status chain first. While the server owns the 10-second clock,
concurrently read runtime identity and the exact CSX producer Build ID. Do not
await one read before starting the other, and do not add work after both finish.
These reads may complete early or late, but never postpone the scheduled COC.

If the server does not accept the timed scenario, stop without substituting a
client sleep. After the COC step returns, wait for the load event and take one
exact-cell scene observation. Start-cell establishment is not measured.

Call `coc-evidence-control status` off the game control plane and bind the
collector receipt to the observed Skyrim PID. Do not add this local check ahead
of the already-scheduled Windhelm COC.

## One-time post-load fixture gate

Once Windhelm is loaded, invoke the direct `communityshaders.menu` tool once:

```json
{
  "action": "prepare_coc",
  "expectedBuildId": "<exact CSX Build ID>"
}
```

Require:

- `ready: true`, `promptRequired: false`, and `persisted: false`;
- `after.vr` and `after.inGame` are true;
- developer mode is active;
- foveated vendor dispatch is enabled;
- FOV center area is 0.3;
- periphery TAA is enabled with center area 0.3 and outer scale 0.7;
- VR FPS Stabilizer was startup-active for this session.

`prepare_coc` may idempotently correct developer mode and the FOV/TAA fixture
in memory. It must not save settings. Call it exactly once.

VR FPS Stabilizer exclusively owns every DLSS/upscaling change. Never call
`communityshaders.renderscale` with `apply`, and never change method, quality,
preset, render scale, or dynamic policy through a menu or console command. The
protocol observes the profile selected by Stabilizer.

This fixture receipt is the only hard pre-measurement gate. If the action is
missing, Stabilizer was not startup-active, or the runtime fixture cannot be
corrected, preserve the receipt and stop because the controlled fixture was
never established.

## Bounded parallel baseline

Start one monotonic 10-second watchdog immediately when the successful
`prepare_coc` receipt arrives. In the same orchestration cell, launch one
parallel bundle containing:

- exact scene/player state;
- the public upscaling snapshot and render-scale lifecycle/status;
- render-scale stress, CPU telemetry, and GPU telemetry status;
- already-configured CSX image capture, when available.

Do not serialize these reads. Do not perform capability discovery, schema
search, capture-provider probing, installation, retries, or a second status
chain. Missing optional capture remains evidence; the in-headset visual check
and CSX two-eye evidence remain valid fidelity inputs.

Use the approved Stabilizer fixture to define the expected profile for
`WindhelmExterior01` and `WhiterunDragonsreach`. Never derive a target by
changing CSX. Record exact cell, lifecycle, requested/effective/stable profiles,
render/display dimensions, and two-eye presentation/fidelity.

If the complete bundle proves the expected baseline before the watchdog, start
the measured assay immediately. Otherwise, when the watchdog reaches 10
seconds, start the assay with the latest completed evidence. A slow, missing,
or faulty baseline value is an anomaly, not permission to delay or cancel the
20-transition history.

The only diagnostic ownership exception is an already-active CPU, GPU, or
stress session not owned by this run. Do not take it over. Preserve its receipt
and classify the assay as interrupted because atomic run ownership cannot be
established.

## Atomic diagnostics and measured assay

The measured run starts in `WindhelmExterior01`. Run exactly 20 alternating
transitions: odd ordinals target `WhiterunDragonsreach` and even ordinals target
`WindhelmExterior01`.

Use one async server scenario for setup and the complete transition sequence:

1. render-scale stress `reset` then `start`; retain its `sessionId`;
2. for transition 1, call `qualification_begin` with a unique transition ID and
   run owner ID;
3. call `qualification_dispatch` with
   `startPerformanceTelemetry: true` immediately adjacent to exactly one COC;
4. call `qualification_wait` once with the same ownership pair, exact target
   cell, expected Stabilizer profile, and `timeoutMs: 10000`;
5. repeat begin, adjacent dispatch plus one COC, and one waiter for transitions
   2 through 20, omitting `startPerformanceTelemetry` after transition 1.

Do not issue separate `cpu_performance_reset`, `cpu_performance_start`,
`gpu_performance_reset`, or `gpu_performance_start` actions. The first dispatch
atomically resets/starts both performance captures on its dispatch frame and
returns the CPU session ID and GPU start frame used for guarded cleanup.

The adjacent dispatch marker defines the first COC command boundary. Therefore
the CPU window, GPU window, and transition timer exclude the Windhelm settle,
fixture correction, baseline, stress setup, and client latency. Report only
this first-COC-through-final-transition interval as assay performance data.

Set `continueOnError: false`. This does not make semantic stability faults
fail-fast: `qualification_wait` returns timeout, profile, lifecycle, fidelity,
and presentation anomalies as normal tool receipts, so the scenario advances.
It does make an actual failed tool step abort the remaining scenario. A rejected
COC, ownership loss, vanished waiter, or main-thread timeout is a control-plane
failure; dispatching further COCs after it cannot add valid evidence.

Advance immediately after each coherent waiter receipt. Do not add fixed
inter-transition waits, menu checks, client polling, or per-transition client
round trips.

## Fidelity interpretation

Shared stability requires the exact destination cell and loaded player;
provider check complete; no active operation, restart requirement, loading or
method transition, relatch, first-world-frame wait, post-load recovery,
provider wait, resource recovery, device loss, unresolved physical mutation,
vendor work gate, pending trim, or resource retirement; agreed requested,
effective, and stable profiles; and positive render/display dimensions.

When render scale is active, require the owner-bound applied/stable physical
contract, correct method/quality/backend/dimensions, ready lifecycle, valid
two-eye fidelity, and at least two completed both-eye vendor presentation
frames. `ContractPublished` is transient; steady state is proved by durable
owner keys and matching applied/stable contracts.

For vendor presentation, use the last completed both-eye compositor frame and
cycle as the coherent pair. One current eye may already be on the next pair.
Reject stale completed-pair evidence, invalid paths, epoch/generation mismatch,
transition flags, or a snapshot where both current eyes moved beyond the
recorded completed pair.

For native resolution, require frame-coherent `NativeOriginal` eyes, inactive
render-scale flags, matching render/display dimensions, and agreed native
profiles.

## Hard control failure and immediate analysis

After a failed scenario tool step, a DevBench 504, a non-advancing main thread,
a CTD, or loss of the server:

1. issue no more console, menu, qualification, or other main-thread calls;
2. preserve the scenario progress marker and every completed receipt;
3. use the local evidence controller only to observe the already-armed ProcDump
   monitor and wait until the dump exists and its length/write time settle;
4. preserve the dump, Community Shaders log, DevBench log, Build ID, DLL, and
   matching PDB;
5. analyze the dump first with CDB/WinDbg, then correlate implicated code and
   symbols through the already-verified managed Ghidra MCP lane.

Tell the user it is safe to quit Skyrim only after the collector has finalized
the dump. Do not repeatedly retry COCs or status calls against the hung main
thread.

## Cleanup and final evaluation

After transition 20, and only while DevBench/main-thread control is responsive:

1. `gpu_performance_stop` with the first dispatch's `expectedStartFrame`;
2. `cpu_performance_stop` with its `expectedSessionId`;
3. render-scale stress `stop` with its `expectedSessionId`.

After all dump activity is settled, stop the owned ProcDump monitor through
`coc-evidence-control stop`. Never cancel an unowned collector.

Preserve all raw transition receipts and final diagnostic records. Report
requested and dispatched transition counts, stable and anomalous counts, every
ordinal/target/outcome/deadline/profile/stereo/lifecycle result, and CPU/GPU
telemetry. Compute stable-transition latency separately from deadline hits.

The verdict is `clean` only if all 20 transitions dispatched and stabilized
without anomalies. If all 20 dispatched but one or more were imperfect, use
`completed_with_anomalies`. Use `interrupted` only when a real control failure
prevented all requested COCs from being dispatched.
