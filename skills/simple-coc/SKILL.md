---
name: simple-coc
description: Run the measured Skyrim VR Windhelm-to-Dragonsreach COC comparison when the user says simple coc, including build identity, full render-scale telemetry, strict stabilization timings, and an appended CSV result. Do not use for static coc or the release qualification protocol.
---

# Simple COC

Use this skill only for the complete live protocol triggered by `simple coc`.
Read [references/protocol.md](references/protocol.md) completely before making
the first live call.

The trigger authorizes runtime-only DevBench telemetry, one runtime-only
`prepare_coc` fixture call, the initial positioning COC, the 20 measured COCs,
guarded capture cleanup, and the requested CSV update. It does not authorize
building, deploying, changing MO2 state, restarting Skyrim, saving settings,
changing DLSS/upscaling, Ghidra, ProcDump, or deleting evidence.

As soon as DevBench health and the exact producer Build ID are bound, call
`communityshaders.menu` `prepare_coc` exactly once as part of that same setup
interval. Run it in parallel with the remaining read-only identity and
capability discovery; do not defer it until positioning or telemetry arming.
It must leave `persisted: false`, enable developer/debug logging, and establish
only the runtime FOV/TAA `0.3/0.3/0.7` fixture. VR FPS Stabilizer remains the
exclusive owner of DLSS and upscaling.

Report as soon as DevBench is loaded and the exact producer identity has been
extracted, then continue without a second handshake. Stop immediately on a
PID/build mismatch, dead or unresponsive game control plane, aborted scenario,
or failed required telemetry lane. Never continue with direct unmeasured COCs
and never publish `n/a` for stabilization or retries merely because a required
measurement call was omitted.
