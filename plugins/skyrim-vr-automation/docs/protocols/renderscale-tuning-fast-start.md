# Render-scale tuning post-position contract

This contract starts only after the NVIDIA or AMD skill's synchronous
Dragonsreach positioning scenario returns. The vendor `SKILL.md` owns the
runtime fixture and positioning request so no reference-file read or local
evidence action can delay the COC.

## Validate the one positioning response

Require top-level `ok: true`, `aborted: false`, and `stepsRun: 8`. Use the
labeled results already returned by that scenario; do not issue confirmation
reads. Require:

- `position-health`: one live `SkyrimVR.exe` PID with `vr: true`;
- `position-state` and `position-scene`: a loaded player in exact
  `WhiterunDragonsreach`;
- `position-capabilities`: success, the fixture's exact producer/Build ID, and
  every method, quality, and runtime required by the selected matrix;
- `position-snapshot`: the same Build ID, a complete authoritative public
  snapshot, and no active operation;
- `position-renderscale`: the same Build ID, no terminal or unresolved
  physical failure, an available adapter, and vendor ID `0x10DE`/4318 for
  NVIDIA or `0x1002`/4098 for AMD.

The synchronous response is the positioning observation. Report positioning
as soon as it returns; do not create an evidence directory, convert JSON,
decode Base64, hash files, or read another reference first. A failed scenario
or required field stops without replaying the COC.

Then read the selected matrix, vendor protocol, and this contract completely
in one local read action. Do not load Simple COC or Simple CSM instructions,
enumerate tools, inspect schemas, or run another admission/reset scenario.

Keep the exact `prepare_coc` and positioning responses in context. Do not write
startup evidence before transition 1. Persist both responses unchanged with
transition 1's required evidence batch before transition 2, index their final
on-disk byte lengths and SHA-256 values with PowerShell `Get-Item` and
`Get-FileHash`, and never compare them with an in-memory reserialization. If
the assay stops before transition 1, make one best-effort final evidence write;
failure to write unmeasured startup receipts is not a render failure.

Every later mutation and ownership scenario remains synchronous with
`async: false` and `continueOnError: false`.

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
