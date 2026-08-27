---
name: coc-stability
description: Run a fast, deadline-driven Skyrim VR COC stability assay that preserves imperfect transitions instead of stopping at the first stability fault.
---

# COC stability

Use this entrypoint for live operation. Read
[references/protocol.md](references/protocol.md) only when maintaining or
diagnosing the protocol; rereading it must never delay the live 10-second
start.

When the user confirms Skyrim VR is in-game, make the first operation an async
server scenario that waits exactly 10 seconds and dispatches one isolated
`coc WindhelmExterior01`. During that server wait, read runtime identity and
the exact CSX Build ID concurrently. Do not put capability discovery, schema
searches, sequential status calls, or capture-provider probing ahead of the
first COC.

After Windhelm loads, call `communityshaders.menu` once with
`{"action":"prepare_coc","expectedBuildId":"<exact build ID>"}`. Require
`ready: true`, `persisted: false`, startup-active VR FPS Stabilizer,
developer mode, and the FOV/TAA 0.3/0.3/0.7 fixture. It may correct only those
runtime CSX settings and must not save.

VR FPS Stabilizer exclusively owns every DLSS/upscaling change. Observe its
per-cell profiles; never apply an upscaling method, quality, preset, render
scale, or dynamic policy through CSX.

After the gate, collect the exact-cell, profile, lifecycle, stereo, diagnostic,
and already-available image evidence in one parallel baseline bundle. Do not
turn optional screenshot-provider discovery into a blocking pre-assay gate.
Start one continuous render-scale stress session, CPU telemetry session, and
GPU telemetry session in one setup scenario, retaining their owner identities.

Run all 20 alternating measured transitions in one async server scenario with
`continueOnError: true`. Each transition is exactly
`qualification_begin`, adjacent `qualification_dispatch` plus COC, then one
`qualification_wait` with a 10-second deadline. The command-boundary dispatch
tick excludes setup and client latency. A stable receipt advances immediately;
a timeout or other imperfect receipt also advances immediately and remains
assay evidence. Do not split ordinary transitions into client round trips.

After transition 20, attempt guarded GPU, CPU, and stress cleanup. Classify a
fully stable run as `clean`; classify a complete imperfect run as
`completed_with_anomalies`; use an interrupted verdict only when the server
cannot dispatch all 20 COCs.
