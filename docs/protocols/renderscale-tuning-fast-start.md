# Render-scale tuning fast start

This shared startup contract applies identically to the NVIDIA and AMD tuning
skills. It is complete for all work through exact Dragonsreach positioning.
Do not read Simple COC or Simple CSM instructions for either tuning assay.

## Minimal live admission

Use the named plugin-provided `mcp__devbench_vr__*` tools directly. Do not
enumerate the tool catalog, inspect tool descriptions, inspect plugin caches or
manifests, or open the bundled controller during a live run. If a named direct
tool is not callable, stop immediately; there is no fallback lane.

Do not measure, classify, or report startup duration. The first measured timing
origin is transition 1's `qualification_dispatch`. The first live action after
reading this contract is the parallel three-read batch below. Start it
immediately, with no local file, timer, script, progress message, or other
preflight action first.

After all three responses return, validate only the required fields named
below, then continue directly to `prepare_coc` and positioning. Do not add a
schema refresh, confirmation read, local evidence action, or model pause. Keep
the three decoded responses in memory until the positioning scenario returns
its accepted `runId`; persist them during its mandatory 10,000 ms settle.

Each direct MCP response must be written as its exact decoded JSON response
body before the first profile mutation; request identity, tool/action, lane,
transition, relative path, byte length, and SHA-256 belong in the index.
Transcript references and MCP/store keys are supplemental only and are never
durable evidence paths. Here, exact decoded JSON means a faithful
serialization that retains every returned field; it does not require
byte-for-byte equality with an in-memory or transport serialization.

The final on-disk files are authoritative. In one local PowerShell action, use
`Get-Item` and `Get-FileHash -Algorithm SHA256` on those files to populate the
index, then verify each indexed length and hash against the same final file
once. Do not compare a file against an in-memory serialization or use client
JavaScript encoding or crypto APIs. If every required file and index entry
matches, evidence initialization passed; a failure of a non-required helper is
not an evidence failure. Stop before the baseline only
when a required final file or the index is missing or unreadable, or an
on-disk length/hash mismatch remains. The runtime-only fixture and unmeasured
positioning COC require no cleanup. A receipt that fails after assay ownership
exists permits only ownership-guarded cleanup that is already safe.

Before positioning, use only these request rounds:

1. One parallel read-only batch containing only direct `inspect health`,
   `communityshaders.upscaling_api capabilities`, and
   `communityshaders.renderscale status`. The capabilities response already
   contains registry and producer data; do not call `registry` separately.
   Do not call `ping`, `inspect state`, or a pre-position API snapshot.
   Require:
   - health: one `SkyrimVR.exe` PID with `vr: true`;
   - capabilities: `status.name: success` and the exact CSX producer/Build ID;
     retain its payload for the lane-specific capability check during settle;
   - render-scale status: the same producer/Build ID, no terminal device loss
     or producer failure, `status.adapter.available: true`, and vendor ID
     `0x10DE`/4318 for NVIDIA or `0x1002`/4098 for AMD.
   A generic adapter string is not authoritative. If one read returns
   429/502/503/504 while health remains exact, retry only that read once
   immediately. Do not sleep or invoke an availability waiter.
2. Call `communityshaders.menu prepare_coc` exactly once and alone as a
   request. It is the first stateful call, but it must not occupy a separate
   model/action turn from the immediately following positioning submission.
   Require the runtime-only FOV/TAA `0.3/0.3/0.7`
   fixture, debug logging, and `persisted: false`. Compare each of
   `after.foveation.foveatedCenterArea`, `peripheryTAACenterArea`, and
   `peripheryTAAOuterScale` numerically with absolute tolerance `0.000001`;
   ordinary binary32 serialization drift within that tolerance is valid.
   Require all booleans, readiness, logging, and persistence fields exactly.
   Validate the decoded response in memory and immediately submit the
   positioning scenario. Persist it during the settle; do not write or rehash
   it first. It must not change DLSS, FSR, render scale, or any VR FPS
   Stabilizer setting.
3. Immediately submit one `scenario` with `async: true`,
   `continueOnError: false`, and these ordered steps:
   - `console exec` with exactly `coc WhiterunDragonsreach`;
   - a fixed 10,000 ms wait;
   - `inspect state`;
   - `inspect scene`;
   - `communityshaders.upscaling_api snapshot`;
   - `communityshaders.renderscale status`.

Any failed required field or fixture stops before the COC. Do not add another
readiness check, schema refresh, profiler query, telemetry action, screenshot,
or status call before the scenario is queued.

## Overlap the mandatory settle

As soon as the async scenario returns its `runId`, create one unique evidence
root named `.tmp/renderscale-tuning-<vendor>-<UTC>-evidence`. In one local
evidence action, write the three startup responses, `prepare_coc`, and the
positioning-acceptance receipt directly to their final `raw/startup` paths,
create required parent directories implicitly, create `receipt-index.json`,
and perform the host-filesystem verification above. Do not create an empty
directory tree or placeholder files first.

In parallel with that local action, read the selected lane's matrix and full
protocol completely while the server performs the 10,000 ms settle. Do not
wait first. After both files are loaded and the evidence batch is verified,
query that `runId`.
If it is still running, query status at most once per second until the settle
plus a five-second receipt envelope expires. Never send a second COC.

If required on-disk verification still fails, allow the positioning scenario
to reach its terminal receipt and preserve the local failure, but stop before
the baseline, telemetry ownership, or profile mutation.

The terminal transcript must prove exact `WhiterunDragonsreach`, a loaded
player, advancing in-world frames, unchanged PID/Build ID, an authoritative
public snapshot with no active operation, and no terminal or unresolved
physical render-scale failure. Reuse these receipts for the initial baseline.
Do not repeat the same state, scene, render-scale, or API reads.

Persist the positioning terminal response under `raw/startup`. Persist the
complete baseline mutation-and-wait scenario and, only after strict success,
its owner-handoff response under `raw/baseline`.
The labeled apply and waiter subreceipts remain inside the exact scenario body;
do not manufacture separate direct-call receipts for them.
Index and rehash each batch before its next mutation. The evidence bundle is
invalid if these response bodies exist only in the transcript.

The positioning scenario is the only `async: true` scenario in the assay.
Every mutation and ownership scenario remains synchronous with `async: false`
and `continueOnError: false`. Do not run a separate post-position admission,
schema, reset, profiler, or negative-test scenario.

## Baseline and measured ownership

Reuse the post-position public snapshot and its exact `stateRevision` when it
is complete, has no active operation, and still matches the bound Build ID.

Start the baseline with one synchronous fail-closed scenario containing six
labeled tool steps in this exact order: `baseline-stress-reset`,
`baseline-stress-start`, `qualification-begin`, `qualification-dispatch`,
`profile-apply`, and `qualification-wait`. This is the only pre-baseline reset.
The apply immediately follows dispatch, and the strict target-correlated waiter
immediately follows apply inside the same server-owned scenario. Pass the full
dispatch-relative `timeoutMs: 30000`; DevBench measures it from
`qualification_dispatch`. Never calculate or pass a client-side remaining
timeout. Do not inspect, validate, persist, or comment on the scenario response
until the server has executed the waiter and returned the complete six-step
transcript.

After the scenario returns, read only its fixed wrapper shape. Require
top-level `ok: true`, `aborted: false`, and `stepsRun: 6`. The apply receipt is
`results[]` entry `label: profile-apply`, under `result.apply`; its disposition
is `result.apply.disposition.name`. The waiter receipt is the unique entry
`label: qualification-wait`, under `result`, with
`result.action: qualification_wait`. Never search another wrapper location or
run another waiter because a client-side field lookup failed.

If the containing scenario response is lost or cannot be decoded, do not replay
the scenario, apply, or waiter. Before writing evidence, reporting feedback,
cancelling, cleaning up, or pausing for commentary, read
`qualification_status` once with the exact `expectedBuildId`, then validate its
returned ownership pair. For the exact active owner in `dispatched` or
`waiting`, allow the already-running server scenario to reach the original
deadline and recover matching terminal `lastEvidence`; do not call
`qualification_wait` independently. If the owner is inactive and matching
`lastEvidence` is present, use it as the terminal waiter receipt. Allow at most
five additional seconds only to retrieve already-terminal evidence. Any
different owner, transition, Build ID, or missing terminal evidence after that
bound stops future mutations and asks the user. Never reapply the profile or
create a second measurement window. Record the client error only after the
qualification owner is terminal. This owner-correlated recovery rule applies
to every baseline and measured waiter in both vendor assays.

The terminal baseline waiter receipt is the first authoritative output-contract
proof. Require its independent `milestoneTimings` and `replacementTimeline`
objects. If either object is absent, record `plugin_contract_outdated`, preserve
the receipt, stop the baseline stress session with its ownership guard, and
stop before measured-owner handoff or transition 1. Never infer either object
from a tool description or later status snapshot.

Only after strict waiter success and that receipt check, continue without a
model pause into one synchronous fail-closed handoff scenario to stop the
baseline stress session with its exact ownership guard, start measured stress,
reset then start texture-lifetime, reset then start load-presentation, and
pre-arm the profiler with `set_enabled`. Do not clear profiler history here;
transition 1 starts its capture with `clearHistory: true` immediately before
dispatch. Transition 1's `qualification_dispatch` is the sole CPU/GPU
reset/start and timing origin. Retain every owner receipt. A failed or
unsatisfied baseline waiter, a missing waiter subreceipt, or an incomplete
scenario must never invoke this handoff scenario because it contains measured
owner start actions. The handoff scenario is never a cleanup path. Stop only
the baseline stress session with one
ownership-guarded `stop` call, start no measured owner, and follow the lane's
terminal failure rules.
