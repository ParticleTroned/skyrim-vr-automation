---
name: gameft-sw
description: Run the preserved Skyrim VR save-load frame-time assay with fpsVR and CPU stack/wait tracing when the user invokes gameft-sw. Use frustrum for paired fast-path OFF/ON reloads.
---

# gameft-sw

Read [the maintained protocol](../../tools/gameft-sw/README.md) before the
live start. Use its exact save-number question unless numbers accompany the
request, preserve the requested order and confirm main-menu readiness.

Invoke `../../tools/gameft-sw/Invoke-GameFtStackWait.ps1`; use the bundled
reporter and marker-defined windows. Do not substitute an ad hoc runner,
formatter or boundary detector. Keep campaign settings and headset position
fixed; follow any supplied campaign preflight without silently changing it.

Use explicit machine-specific fpsVR and archive paths. For an installed
bundle, also supply `-RunDirectory` and `-RecorderValidationPath` outside the
versioned plugin cache. Reuse known paths and complete recorder validation
before the measurement. Never restart fpsVR, SteamVR or Skyrim to repair
logging, and never rotate plugins or build during a hold.

Present CPU/GPU timing and per-save health before physical DLL provenance
and WPR analysis. Retain partial results and missing evidence. Source labels
come from verified runtime/build receipts, not the user's archive name.

For the user-requested `depthc` matrix, use [its separate skill](../depthc/SKILL.md)
and 20-second phase protocol instead of modifying gameft-sw.
