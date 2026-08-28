# CSX SteamVR head-pose provider

This Windows OpenVR server driver supplies the tracked head pose missing from
Valve's display-only null HMD. It exposes one generic tracked device and is
mapped to `/user/head` through SteamVR's `TrackingOverrides` setting. It does
not expose controllers.

The default standing pose is `(0, 1.68, 0)` metres with identity orientation.
The driver also publishes the version-2 shared-memory control block
`Local\CSXVRHeadPose-v2`. It is created with an owner-only ACL and a fresh
driver-instance nonce; a pre-existing mapping is rejected. Writers serialize
through a named mutex, publish with aligned interlocked sequence fields, and
receive acknowledgement of the exact command nonce and sequence. DevBench can
implement the same contract later without becoming a SteamVR bootstrap
dependency.

The independent probe qualifies both the standing HMD pose and distinct,
finite per-eye transforms with a plausible eye separation and render target.

Build with:

```powershell
cmake -S . -B build -A x64
cmake --build build --config Release
```

Set `CSX_OPENVR_SDK_ROOT` to an OpenVR checkout to avoid downloading the pinned
SDK revision during configuration. The packaged driver is written under
`build/package/codex_head_pose`.
