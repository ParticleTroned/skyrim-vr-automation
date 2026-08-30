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
OpenVR inventory. Install and upgrade callers serialize through a bounded lock
keyed by the canonical install root and OpenVR registration file. The
authoritative journal and exact registration preimage live in a deterministic
per-user control directory; caller evidence journals are secondary mirrors.
Every later install invocation discovers and recovers a nonterminal journal
before it validates a new package or evidence directory. Recovery is
phase-aware and idempotent: it quarantines an uncommitted replacement/staging
tree, restores the retained owned installation, restores exact registration
bytes, and verifies original marker/DLL provenance. A registration command
whose result was not journalled is accepted for rollback only when its semantic
driver inventory differs from the preimage solely by the one canonical target.
Unclassified target or registration drift fails for manual recovery.

The install lock is bounded by `-InstallLockTimeoutMilliseconds`. Its control
root is fixed under Windows LocalApplicationData; the fixture-only environment
override is accepted only for targets within the OS temporary directory.
