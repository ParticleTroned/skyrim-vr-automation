# Deadline-driven COC stability protocol

## Two-command operator handshake

The first command is `start COC protocol`, issued while Skyrim is at its main
menu/load window. It authorizes only readiness. Register or verify tools, start
external analyzers and the dump collector, make the required harmless calls,
report `ready to load`, and return control to the user. Do not issue a console
command, COC, load, or in-game probe.

The user then loads into the game. After the user can see that loading is
complete, the second command is `start`. That command alone authorizes fast
start-cell establishment and the measured assay. Do not repeat readiness work
on this critical path.

If Codex must restart during readiness, keep Skyrim at the main menu and keep
the owned Ghidra and ProcDump processes alive. In the new window, the user
repeats `start COC protocol`; resume readiness and report `ready to load` only
after both MCP tool calls pass. Never treat that first command as the second
`start` command.

## Main-menu Codex and evidence readiness

Complete this phase when Skyrim reaches its main menu/load window and before a
save or test world is loaded. Do not defer it into the in-game start window.

1. Resolve the one live `SkyrimVR.exe` PID. Require the trusted workspace's
   project-scoped `.codex/config.toml` to declare `devbench_vr` at
   `http://127.0.0.1:8921/mcp` and `ghidra` at
   `http://127.0.0.1:8080/mcp`. Do not treat a volatile global `codex mcp add`
   result as durable registration. Restart Codex after repairing project
   configuration, then verify both exact live identities. Require the installed
   `devbench-control` entrypoint.
2. In one parallel local setup group:
   - call Community Shaders' canonical `tools/ghidra-mcp-control.ps1 status
     -ProgramPath <exact intended CSX DLL>`; if stopped or mismatched, stop only
     its managed session and call `start -ProgramPath <exact intended CSX DLL>`;
   - run `coc-evidence-control inspect` and require CDB/WinDbg, ProcDump, and
     free-space readiness;
   - arm ProcDump with `-TargetPid <exact Skyrim PID>`, unless an existing owned
     waiting collector has attached to that same PID. The automatic monitor is
     exception-triggered, not window-hang-triggered.
3. Require the Ghidra receipt to report `ok: true`, `state: ready`,
   `managed: true`, `endpointReady: true`, `listenerOwnedBySession: true`,
   `pyGhidraReady: true`, and `programMatchesExpectation: true`. Its active
   program path and SHA-256 must match the intended DLL, not merely share its
   filename or project name. Prefer `listenerOwnershipSource` equal to
   `session-binding`, which verifies the saved listener PID and process start
   time without privileged process-tree access. A legacy session may use one
   ancestry-proven check to capture that binding. Its selected persistent
   analysis project must match the intended build.
4. Inspect the current Codex tool registry and require both DevBench and Ghidra
   MCP tool families to be attached to this window. An enabled settings toggle
   is not proof.
5. Make one harmless Ghidra `eval_python` call that reads the active program
   path/hash and one harmless DevBench health/identity call. The Python call
   must execute successfully; tool presence alone does not prove that the
   Ghidra instance was launched through PyGhidra. Require DevBench to identify VR,
   `SkyrimVR.exe`, the exact PID, and port 8921.
6. Run one synchronous DevBench scenario containing only a
   `communityshaders.renderscale` `qualification_wait` without an expected
   cell. Do not begin or dispatch a qualification. Require the embedded
   `missing_expected_cell` receipt to produce scenario `ok:false`,
   `aborted:true`, `stepsRun:1`, and step `ok:false`. This harmless negative
   probe proves that `continueOnError:false` recognizes extension-domain
   errors before the live sequence can dispatch multiple COCs.

If either MCP tool family is absent, leave Skyrim at the main menu and keep the
managed Ghidra server and owned ProcDump collector running. Restart Codex while
both game-owned DevBench and Ghidra endpoints are available, then repeat only
steps 4 and 5. Do not restart Skyrim, Ghidra, or ProcDump merely to attach the
tools to a new Codex window.

The repository Ghidra controller exclusively owns the persistent headless
GhidrAssistMCP server and project. The evidence controller discovers the
installed GitHub `codex-ghidra-live` layout but owns only ProcDump and CDB.
ProcDump is the live crash collector because it can already be waiting for an
unhandled exception. It uses full dumps, a two-dump limit, and no normal-exit,
first-chance, or automatic five-second window-hang trigger. A healthy Skyrim
COC can stop pumping window messages for longer than that heuristic and must
not consume the crash quota. For a visually confirmed freeze, use the evidence
controller's explicit `capture-hang` action; it cancels the owned exception
monitor, captures one full dump of the exact PID, and labels the trigger as
`operator-confirmed-hang`. CDB/WinDbg and Ghidra MCP are the post-capture
analyzers.

If a real local readiness check or harmless MCP call fails after attachment,
stop at the main menu and preserve the receipt. Do not diagnose a missing
installation merely from a missing tool.

When every check passes, report `ready to load` with the exact Skyrim PID,
DevBench and Ghidra endpoint identities, managed Ghidra PID/listener ownership,
ProcDump PID/state path/capture directory, CDB path, and installed automation
plugin version. Stop and wait for the user's in-game `start`; this readiness
report does not authorize any game command.

A readiness receipt is reusable only while all of these remain true:

- the same Codex window still exposes both MCP tool families;
- the exact DevBench loopback registration is unchanged;
- the Ghidra receipt still proves the same managed process and owned listener;
- PyGhidra remains callable and the active program still matches the intended
  artifact path and SHA-256;
- the owned ProcDump PID and start time still match the state receipt;
- `coc-evidence-control status` reports a live monitor;
- DevBench and ProcDump still identify the same exact Skyrim PID.

A new Codex window, missing tool, exited collector, or new Skyrim PID requires
the corresponding recheck or re-arm before another live trigger.

## Fast start-cell establishment

At the moment the user confirms Skyrim VR is visibly loaded and says `start`,
immediately queue one async DevBench server scenario whose only steps are a
10,000 ms wait followed by exactly:

```text
coc WindhelmExterior01
```

Queue that deadline before identity, status, capability, schema, or capture
calls. Do not run another discovery or readiness chain. While the server owns
the 10-second clock, concurrently read runtime identity and the exact CSX
producer Build ID. Do not await one read before starting the other, and do not
add work after both finish. These reads may complete early or late, but never
postpone the scheduled COC.

If the server does not accept the timed scenario, stop without substituting a
client sleep. After the COC step returns, wait for the load event and take one
exact-cell scene observation. Start-cell establishment is not measured.

Call `coc-evidence-control status` off the game control plane and bind the
collector receipt to the observed Skyrim PID. Require `armed-attached`; a dump
from the successful start-cell COC is an anomaly because the exception-only
monitor should still be live. Do not add this local check ahead of the
already-scheduled Windhelm COC.

## One-time post-load fixture gate

Once Windhelm is loaded, invoke `coc-stability-control run` once with the exact
Skyrim PID, Build ID, owned collector state path, and evidence root. From this
point the controller owns the fixture, baseline deadline, and measured scenario
submission. Do not separately invoke `prepare_coc`, baseline reads, or the
scenario.

The controller invokes the direct `communityshaders.menu` tool once:

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

This boundary also forbids deriving or validating Stabilizer policy from the
machine or filesystem. Do not enumerate graphics adapters, choose an
AMD/NVIDIA-specific target, inspect or compare Stabilizer INIs, resolve an MO2
winning file, or invoke `mo2-control` for an upscaling decision. Multiple
adapters or configuration files require no resolution by this protocol; the
running public CSX profile is the sole observation source.

This fixture receipt is the only hard pre-measurement gate. If the action is
missing, Stabilizer was not startup-active, or the runtime fixture cannot be
corrected, preserve the receipt and stop because the controlled fixture was
never established.

## Bounded parallel baseline

The controller starts one monotonic 10-second watchdog immediately when the
successful `prepare_coc` receipt arrives. In parallel thread jobs it launches
one bundle containing:

- exact scene/player state;
- the public upscaling snapshot and render-scale lifecycle/status;
- render-scale stress, CPU telemetry, and GPU telemetry status;
- already-configured CSX image capture, when available.

Do not serialize these reads. Do not perform capability discovery, schema
search, capture-provider probing, installation, retries, or a second status
chain. Missing optional capture remains evidence; the in-headset visual check
and CSX two-eye evidence remain valid fidelity inputs.

Do not define or send an expected upscaling target. VR FPS Stabilizer owns the
selection for `WindhelmExterior01` and `WhiterunDragonsreach`. Record the exact
cell, lifecycle, coherent observed requested/effective/stable profiles,
render/display dimensions, and two-eye presentation/fidelity without changing
CSX upscaling state.

Do not precede that observation with hardware inventory, Stabilizer INI
inspection, or MO2 file resolution. Those checks neither establish fidelity nor
authorize a target and must not delay the watchdog or measured scenario.

Before launching baseline calls, the controller creates the complete measured
scenario and starts an independent monotonic watchdog job. The watchdog and an
early-success path compete for one atomic file claim. The winner submits the
scenario exactly once. If the complete bundle proves the expected baseline
before the watchdog, the early path starts the assay immediately. Otherwise,
at 10 seconds the watchdog starts it with the latest completed evidence. A
slow, missing, or faulty baseline value cannot block the watchdog and is an
anomaly, not permission to delay or cancel the 20-transition history.

The only diagnostic ownership exception is an already-active CPU, GPU, or
stress session not owned by this run. Do not take it over. Preserve its receipt
and classify the assay as interrupted because atomic run ownership cannot be
established.

## Atomic diagnostics and measured assay

The measured run starts in `WindhelmExterior01`. Run exactly 20 alternating
transitions: odd ordinals target `WhiterunDragonsreach` and even ordinals target
`WindhelmExterior01`.

Use the one async server scenario generated and submitted by
`coc-stability-control` for setup and the complete transition sequence:

1. render-scale stress `reset` then `start`; retain its `sessionId`;
2. for transition 1, call `qualification_begin` with a unique transition ID and
   run owner ID;
3. call `qualification_dispatch` with
   `startPerformanceTelemetry: true` immediately adjacent to exactly one COC;
4. call `qualification_wait` once with the same ownership pair, exact target
   cell, no `target` argument, and `timeoutMs: 10000`; require its externally
   owned observation mode to return the coherent Stabilizer-selected profile;
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
It does make an actual failed tool step abort the remaining scenario. DevBench
must classify a top-level embedded tool `error` or `ok:false` as a failed step
and preserve the complete receipt. A rejected COC, ownership loss, vanished
waiter, or main-thread timeout is a control-plane failure; dispatching further
COCs after it cannot add valid evidence.

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
3. for a CTD, use the local evidence controller to observe the already-armed
   exception monitor and wait until its dump settles; for a visually confirmed
   hang, invoke its one explicit `capture-hang` action, then wait until that dump
   settles;
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
