---
name: simple-csm-rs
description: Run the separate Simple CSM render-scale OFF/ON variant when the user says simple csm rs. Retain each DLSS/FSR upscaling quality and use five-second pacing; leave simple csm unchanged.
---

# Simple CSM RS

Trigger: `simple csm rs`. This is a separate protocol, not an alias or revision
of `simple csm` or release qualification.

Before live calls, read this variant's [protocol](references/protocol.md).
It is self-contained. Do not inherit Simple COC, Simple CSM, or release
qualification gates.

This is a timed stress sweep. Verify the live DLL/build once, capture one
initial public-API settings snapshot, then start the server-side five-second
matrix immediately. VR FPS Stabilizer, `VRFpsStabilizer.ini`, fixture actions,
COCs, scene stabilization, per-transition qualification, and intermediate
telemetry reads are not part of this assay.

Use [scripts/New-SimpleCsmRsPlan.ps1](scripts/New-SimpleCsmRsPlan.ps1) with the
live producer's adapter vendor. It produces a read-only plan and never contacts
the game. Do not hand-copy or deduplicate the canonical entries.

This trigger authorizes the expanded plan's runtime-only profile changes. It
does not authorize a fixture action, COC, build, deployment, restart, INI edit,
saved settings change or another assay. DevBench is required; an Info-only
diagnostic DLL cannot run this protocol.
