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
mandatory when callable. Submit the positioning COC and its 10,000 ms dwell
asynchronously. After exact-cell positioning is proven, reuse that lane's
schema inventory and complete measurement admission. Do this while its server-owned stabilization wait is still running:
query telemetry lanes and
reset each supported lane once in one synchronous, fail-closed DevBench
scenario. Validate every reset receipt, then arm captures in a second
synchronous, fail-closed scenario. Never wait for the whole Windhelm dwell and
then begin admission, and never shorten or duplicate the dwell. The overlap
does not authorize a stateful telemetry call before exact-cell proof. The
server runs each batch serially; the client validates the complete transcript
before measured dispatch. Do not run a deliberate invalid-request or stop-on-error probe
during a live COC assay; runner error semantics belong in toolkit validation.
Only independent read-only calls may run concurrently.
Never repeat a successful setup action.
Do not start CPU or GPU counters;
transition 1's atomic dispatch remains their sole timing origin. Explicitly enable and
verify an exposed
profiler API before queuing the measured scenario. `start_capture` must never
be the first profiler mutation. An exposed API returning `disabled` is a
failed required lane, not `unsupported` evidence.
It must leave `persisted: false`, enable developer/debug logging, and establish
only the runtime FOV/TAA `0.3/0.3/0.7` fixture. VR FPS Stabilizer remains the
exclusive owner of DLSS and upscaling.

The only startup update to the user is one concise admission line containing
the exact Build ID and source commit. Do not report successful fixture,
inventory, profiler, reset, or arm results. Preserve their full receipts
directly in evidence and return only compact gate fields to the model context;
surface a failure immediately and concisely. Continue without a second
handshake. Transition 1's dispatch must occur within 120,000 ms of the trigger
or the run stops before measured dispatch with a deadline result. Stop
immediately on a PID/build mismatch, dead or unresponsive game control plane,
aborted scenario, or failed required telemetry lane. Never continue with
direct unmeasured COCs and never publish `n/a` for stabilization or retries
merely because a required measurement call was omitted.

Run the 20 measured COCs as four fail-fast five-transition scenario batches
under the same owner and capture sessions. After validating each batch, report
only `5/20`, `10/20`, `15/20`, or `20/20` complete and the exact current cell,
then queue the next batch without waiting for user input. Do not print batch
transcripts or intermediate telemetry results.

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
