---
name: simple-coc
description: Run the measured Skyrim VR Windhelm-to-Dragonsreach COC comparison when the user says simple coc, including build identity, full render-scale telemetry, strict stabilization timings, and a preserved CSV comparison. Do not use for static coc or the release qualification protocol.
---

# Simple COC

Use this skill only for the complete live protocol triggered by `simple coc`.
Read [references/protocol.md](references/protocol.md) completely before making
the first live call.

The trigger authorizes runtime-only DevBench telemetry, one runtime-only
`prepare_coc` fixture call, the initial positioning COC, the 20 measured COCs,
guarded capture cleanup, and the requested CSV comparison. It does not authorize
building, deploying, changing MO2 state, restarting Skyrim, saving settings,
changing DLSS/upscaling, Ghidra, ProcDump, or deleting evidence.

The separate explicit command `frozen Ghidra` authorizes only the frozen-image
forensic branch in the protocol for the already-bound session. Never infer that
authorization from a freeze, timeout, or the original `simple coc` command.

As soon as DevBench health and the exact producer Build ID are bound, call
`communityshaders.menu` `prepare_coc` exactly once as the first stateful call
and validate its receipt before making another stateful call.
Reuse a successful build binding and fixture receipt from this same live
PID/session when already available; do not repeat successful verification or
setup. Otherwise bind health and producer once and prepare the fixture once.
Before the unmeasured positioning COC, use the already exposed core tool
contracts. Dispatch positioning immediately after binding and fixture readiness;
do not add registry, menu, or other discovery round trips. Do not query the
profiler service or reset telemetry there.

Use exactly one live DevBench transport, with plugin-provided direct MCP tools
mandatory when callable. After exact-cell positioning, reuse that lane's schema
inventory and complete measurement admission: query telemetry lanes and
reset each supported lane once in one synchronous, fail-closed DevBench
scenario. Validate every reset receipt, then arm captures in a second
synchronous, fail-closed scenario. The server runs the steps serially; the
client validates the complete transcript before the measured scenario. Do not
run a deliberate invalid-request or stop-on-error probe during a live COC
assay; runner error semantics belong in toolkit validation. Only independent
read-only calls may run concurrently. Never repeat a successful setup action.
Do not start CPU or GPU counters;
transition 1's atomic dispatch remains their sole timing origin. Explicitly enable and
verify an exposed
profiler API before queuing the measured scenario. `start_capture` must never
be the first profiler mutation. An exposed API returning `disabled` is a
failed required lane, not `unsupported` evidence.
It must leave `persisted: false`, enable developer/debug logging, and establish
only the runtime FOV/TAA `0.3/0.3/0.7` fixture. VR FPS Stabilizer remains the
exclusive owner of DLSS and upscaling.

Report as soon as DevBench is loaded and the exact producer identity has been
extracted, then continue without a second handshake. Stop immediately on a
PID/build mismatch, dead or unresponsive game control plane, aborted scenario,
or failed required telemetry lane. Never continue with direct unmeasured COCs
and never publish `n/a` for stabilization or retries merely because a required
measurement call was omitted.

Each measured block ends with one render-scale status receipt. Preserve its
transition-filtered preparation events and summaries for admission/early exit,
shader cache, SSS/SSGI, DLSS/FSR/FSR4, D3D creation, total preparation,
request-to-prepared, and prepared-to-creator. This must not add polling or
change Stabilizer-owned settings.

For a repository that has migrated to immutable numbered ledgers, preserve
the completed run and a local comparison CSV. Publish a new numbered ledger
only in the identified PR's reporting workflow; never recreate the removed
monolithic ledger or append to an immutable history archive.

Record wall-clock durations for binding/fixture, positioning, post-position
reads, reset batch, arm batch, and time to transition 1 dispatch. These are
setup diagnostics; they must not add waits or alter the measured window.
