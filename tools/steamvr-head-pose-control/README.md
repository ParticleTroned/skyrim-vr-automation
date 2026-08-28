# SteamVR head-pose control

This tool installs and controls the `codex_head_pose` OpenVR server driver used
with Valve's null display driver. The provider exists below Skyrim and CSX, so
SteamVR receives a valid standing head pose before DevBench starts.

`install` uses the bundled package at `../../drivers/codex_head_pose` when
`-DriverPackagePath` is omitted. An explicit package path can still select a
separately reviewed build.

```powershell
.\Invoke-SteamVRHeadPoseControl.ps1 install -EvidenceDirectory <evidence>

.\Invoke-SteamVRHeadPoseControl.ps1 inspect -Compact
.\Invoke-SteamVRHeadPoseControl.ps1 qualify -Compact
.\Invoke-SteamVRHeadPoseControl.ps1 set -EyeHeightMeters 1.68 -YawDegrees 0
```

The runtime contract is the versioned memory map
`Local\CSXVRHeadPose-v1`. Writers use an odd/even sequence transaction and the
driver acknowledges the applied even sequence. DevBench may become another
writer later, but is deliberately not required to bootstrap the pose.

`install` requires SteamVR to be stopped. It copies a validated package to a
stable user-local directory, records an ownership marker, registers the driver
with Valve's `vrpathreg`, and optionally writes an evidence receipt. It refuses
to replace an existing install; upgrades need a separately reviewed transaction.
