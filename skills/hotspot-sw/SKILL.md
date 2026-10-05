---
name: hotspot-sw
description: Record a user-guided Skyrim VR CPU hotspot walk with WPR, fpsVR, player/HMD poses and perf-branch culling/depth-job telemetry, automatically segmenting stationary views after capture.
---

# hotspot-sw

Read ../../tools/hotspot-sw/README.md. This is separate from gameft-sw.

Ask for one save number unless supplied and confirm readiness at the main
loading screen. Accept an explicit already-in-game start without a reload.
The user walks and looks manually; do not inject head/controller input.

Use the perf-branch DevBench build, unchanged selected settings, and the source
automation dev wrapper. Do not build or restart applications at live start.
Validate WPR before measurement. Start all recorders before the authorized
save load. Use explicit physical fpsVR/recording/archive paths.

Tell the user to hold the healthy view, hotspot view and recovered view for
about 20 seconds each. Additional pauses/turns are detected from recording.
Stop only on the user's stop, process exit, failure or safety deadline; a return
to normal CPU time is not permission to stop the run.

On stop, leave Skyrim running until owned pose/fpsVR captures and WPR are
finalized. Keep interrupted runs. Report timing before physical provenance and
WPA analysis. Automatic stillness is not a render-health or stability verdict.
Do not substitute fixed-save holds, graph-derived boundaries, or live WPA work.
