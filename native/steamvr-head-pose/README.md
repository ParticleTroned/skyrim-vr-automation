# CSX SteamVR head-pose provider

This Windows OpenVR server driver supplies the tracked head pose missing from
Valve's display-only null HMD. It exposes one generic tracked device and is
mapped to `/user/head` through SteamVR's `TrackingOverrides` setting. It does
not expose controllers.

The default standing pose is `(0, 1.68, 0)` metres with identity orientation.
The driver also publishes a versioned shared-memory control block named
`Local\CSXVRHeadPose-v1`. The automation controller is the initial writer;
DevBench can implement the same contract later without becoming a SteamVR
bootstrap dependency.

Build with:

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release
```

Set `CSX_OPENVR_SDK_ROOT` to an OpenVR checkout to avoid downloading the pinned
SDK revision during configuration. The packaged driver is written under
`build/package/codex_head_pose`.
