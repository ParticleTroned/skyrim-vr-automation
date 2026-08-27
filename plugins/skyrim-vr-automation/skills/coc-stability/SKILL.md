---
name: coc-stability
description: Run a fast, deadline-driven Skyrim VR COC stability assay that preserves semantic anomalies but stops dispatching after a real control failure.
---

# COC stability

Use this entrypoint for live operation. Read
[references/protocol.md](references/protocol.md) while maintaining or
diagnosing the protocol, never after the user has entered the live start
window.

Use a strict two-command handshake. At Skyrim's main menu/load window the user
says `start COC protocol`; perform readiness only, report `ready to load`, and
stop. Do not issue a COC or another in-game command. After the user loads into
the game, visually confirms it is loaded, and says `start`, begin the timed live
path.

When Skyrim reaches its main menu/load window, and before loading into the test
world, establish the analysis environment. In parallel, use Community Shaders'
`tools/ghidra-mcp-control.ps1` to start or verify the managed Ghidra server and
run `coc-evidence-control inspect` plus `arm` against the exact Skyrim PID.
Require CDB/WinDbg, ProcDump, dump storage, and an owned collector. Require the
trusted project `.codex/config.toml` to declare the exact DevBench and Ghidra
loopback endpoints; do not rely on volatile global registration state. Confirm
the current Codex window exposes both MCP tool families and make one harmless
call through each. An enabled UI toggle is not proof. If either tool
family is absent, leave Skyrim at the main menu, keep the external servers and
collector running, restart Codex, and repeat only the tool-call checks. Retain
the Ghidra and ProcDump receipts. Report readiness only after every required
receipt and real MCP call passes, then wait for the user's second command.

When the user confirms Skyrim VR is visibly loaded and says `start`, make the
first live operation an async DevBench server scenario that waits exactly 10
seconds and dispatches one isolated `coc WindhelmExterior01`. During that
server wait, read runtime identity and the exact CSX Build ID concurrently. Do
not put discovery or sequential status calls ahead of this COC.

After Windhelm loads, call `communityshaders.menu` once with
`{"action":"prepare_coc","expectedBuildId":"<exact build ID>"}`. Require
`ready: true`, `persisted: false`, startup-active VR FPS Stabilizer,
developer mode, and the FOV/TAA 0.3/0.3/0.7 fixture. It may correct only those
runtime CSX settings and must not save.

VR FPS Stabilizer exclusively owns every DLSS/upscaling change. Observe its
per-cell profiles; never apply an upscaling method, quality, preset, render
scale, or dynamic policy through CSX.

Start one monotonic 10-second watchdog immediately after the fixture receipt.
In the same orchestration cell, collect the exact-cell, profile, lifecycle,
stereo, diagnostic-status, and already-available image evidence in one parallel
bundle. Do not probe providers or retry checks. A complete acceptable bundle
starts the assay immediately; otherwise the watchdog starts it at 10 seconds
and the incomplete or faulty baseline remains evidence.

Run the stress reset/start and all 20 alternating transitions in one async
server scenario. On transition 1, `qualification_dispatch` uses
`startPerformanceTelemetry: true` immediately adjacent to the COC, so CPU and
GPU counters share the first COC command boundary and exclude setup. Use
`continueOnError: false`: semantic timeout/profile/fidelity/lifecycle faults are
normal successful waiter receipts and continue, while an actual failed tool
step or lost main thread aborts later COCs immediately. Do not split ordinary
transitions into client round trips.

After transition 20, attempt guarded GPU, CPU, stress, and ProcDump cleanup only
while their control planes are responsive. On CTD or hang, make no further
main-thread calls; wait for the already-armed dump to settle, preserve it, and
analyze it with WinDbg and the managed Ghidra MCP server before telling the user
it is safe to quit.

Classify a fully stable run as `clean` and a complete imperfect run as
`completed_with_anomalies`. Use an interrupted verdict only when a hard control
failure prevented all 20 COCs from being dispatched.
