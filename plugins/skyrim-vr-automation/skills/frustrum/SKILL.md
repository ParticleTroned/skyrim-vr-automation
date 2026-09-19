---
name: frustrum
description: "Run the Skyrim VR frustum fast-path comparison when the user invokes frustrum: measure each save OFF, reload the same save ON, then advance, preserving gameft-sw timing, health and stack/wait tracing."
---

# frustrum

Read [the paired protocol](../../tools/frustrum/README.md) and its linked
[gameft-sw rules](../../tools/gameft-sw/README.md) before the live start.
Ask the exact save-number question unless numbers accompany the request;
confirm readiness at the main loading screen before measurement.

Use `../../tools/frustrum/Invoke-Frustrum.ps1`. The runner owns the toggle:
each requested save is loaded with Experimental Frustum Fast Path OFF,
measured, reloaded ON and measured before the next save. It restores the
original toggle afterward. Do not change depth-culling mode, verification,
camera/headset pose, profiles or unrelated settings to make a run pass.

Use explicit fpsVR, archive, durable run-directory and recorder-validation
paths. Keep the headset fixed and campaign settings matched. Prepare WPR
before the live start. Do not launch/restart fpsVR or rotate plugins during
measurement. No game DLL rebuild is part of this protocol.

Present the generated OFF/ON comparison with ON-minus-OFF deltas and health
before physical build provenance or WPR analysis. Use the paired plan and
markers for WPR windows; never pair rows from different save occurrences or
infer windows from graph shape. Keep incomplete pairs visible. The fixed
OFF-first order may favor the warmer second load; preserve that limitation.
