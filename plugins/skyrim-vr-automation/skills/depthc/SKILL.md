---
name: depthc
description: Run the Skyrim VR settled-scene depth-control matrix when the user invokes depthc. Loads each chosen save once, tests six DLAA/DLSS/FSR3 rendering modes with depth-control conditions, and measures 20 seconds after render recovery using fpsVR and stack/wait tracing.
---

# depthc

Read [the maintained depthc protocol](../../tools/depthc/README.md) before
the live start. Ask its exact save-number question unless numbers accompany
the request, preserve their order and confirm main-menu readiness. Preparing
this protocol does not authorize starting a measurement.

Invoke `../../tools/depthc/Invoke-DepthC.ps1` with the requested save list,
explicit fpsVR and archive paths, and durable run/recorder-validation paths
outside the installed cache. Reuse the existing validated recorder. Never
substitute an ad hoc runner, restart fpsVR/SteamVR, or build during a hold.

The runner owns one load per save, the six-mode/eight-condition matrix,
runtime-only profile/control mutations and restoration. Keep all other
campaign settings and the headset fixed. Do not edit Stabilizer INIs or
manually change conditions during measurement. An unsupported profile,
missing proof, crash or failed health check ends dispatch; do not retry or
silently skip the failure. Interior-only control is explicitly inapplicable
on exterior saves.

Use the saved phase markers and final `[10,20)` seconds for timing and WPR.
Actual world entry and render-recovered condition entry are different events.
Render recovery does not imply CPU/GPU noise has stopped. Use the maintained
reporter; present CPU/GPU statistics, deltas and health before physical DLL
provenance or stack analysis. Retain every incomplete/inapplicable condition.

Use `gameft-sw` for the unchanged 60-second save-load assay and `frustrum`
for the unchanged OFF/reload/ON experiment; neither is an alias for depthc.
