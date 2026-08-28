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

The runtime contract is the owner-only, version-2 memory map
`Local\CSXVRHeadPose-v2`. Writers take a named single-writer lease, use
interlocked odd/even sequence publication, and include a random command nonce.
The driver acknowledges that exact nonce and sequence and exposes its current
process identity and instance nonce. DevBench may become another writer later,
but is deliberately not required to bootstrap the pose.

`qualify` always requires the bounded independent OpenVR probe. The probe must
observe the standing pose, finite and distinct left/right eye transforms, a
plausible eye separation, and a valid recommended render target. Using
`-SkipOpenVRProbe` is diagnostic and explicitly unqualified.

`install` requires SteamVR to be stopped. It copies a validated package to a
stable user-local directory, records an ownership marker, registers the driver
with Valve's `vrpathreg`, and optionally writes an evidence receipt. Registration
is independently proven as exactly one canonical path in the authoritative
OpenVR inventory. Upgrades use a write-ahead journal; failure quarantines the
uncommitted replacement and restores and verifies both the old installation and
the exact registration-file preimage.
