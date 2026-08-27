---
name: coc-stability
description: Run a fast, deadline-driven Skyrim VR COC stability assay that preserves imperfect transitions instead of stopping at the first stability fault.
---

# COC stability

Read [references/protocol.md](references/protocol.md) before operating the game.

After Skyrim VR is confirmed in-game, allow one 10-second settle period. Use
that same window for the build/runtime read, then issue exactly one isolated
`coc WindhelmExterior01`. Do not serialize redundant preflight checks ahead of
that first COC.

After Windhelm loads, invoke `communityshaders.menu` with
`{"action":"prepare_coc","expectedBuildId":"<exact build ID>"}` exactly once.
Require `ready: true`, `persisted: false`, startup-active VR FPS Stabilizer,
developer mode, and the FOV/TAA 0.3/0.3/0.7 fixture. The action may correct
those runtime-only CSX settings. It must not save settings or change the
upscaling method, quality, preset, render scale, or dynamic policy.

VR FPS Stabilizer exclusively owns every DLSS/upscaling change. Observe and
validate its per-cell profiles; never use a CSX apply action to select one.

Only after the one-time fixture gate, establish an exact Windhelm image,
stereo, lifecycle, and profile baseline. Then start one continuous render-scale
stress session, one CPU telemetry session, and one GPU telemetry session.
Retain their ownership identities.

Run all 20 alternating measured transitions, beginning with
`WhiterunDragonsreach`. Prefer one server-side scenario for the complete
sequence. Start each transition timer at its actual COC command, excluding
`qualification_begin` and all setup. Advance immediately on a stable result,
or advance at the absolute 10-second COC-to-result deadline with the imperfect
receipt preserved.

A qualification timeout or a profile, fidelity, presentation, or lifecycle
imperfection is assay evidence, not a reason to stop. Stop only for loss of the
game/control plane, build-identity change, diagnostic ownership corruption,
rejected COC dispatch, or loss of the required waiter capability. Never overlap
two unresolved waiter calls; a timed-out waiter must return its terminal receipt
before the next transition starts.

After transition 20, stop GPU telemetry using its guarded start frame, then CPU
telemetry and render-scale stress using their session IDs. Classify a fully
stable run as `clean`; classify a complete run containing any imperfect
transition as `completed_with_anomalies`.
