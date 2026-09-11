# Offline tuning summaries and comparisons

The finalizer preserves terminal results while independently reporting
execution, per-transition Task 2 evidence, full-history switch health,
per-pass performance, memory and reporting completeness. It reconstructs
these fields from retained receipts on every invocation. Summary schema v6
adds `switchHealth`, `switchTimings` and `changeAssessment`; the retained
terminal `render.verdict` has scope `terminal_condition_only`.

`DOES_NOT_MEET_STANDARD` describes a result that does not support an
improvement-or-neutral assessment. It does not mark a completed test as
failed. Recovered fidelity/vendor failures remain adverse observations.
Each pass includes raw cumulative acceptance, every unmet gate's observed
value/limit, applicability, full counters and exact owned metrics.

The fixed stretch-frame cutoff is diagnostic only when settling imposes
stretch. Report actual relatch/strict frames and milliseconds, stretch
episodes, total frames, duration and recovery; do not use that fixed cutoff
as a health penalty. A scaled-presentation gate after a proven native-AA
terminal target is a separately labeled contract mismatch. The exception
requires the exact native both-eye vendor proof; other gates stay active.
Neither interpretation changes the raw producer acceptance record.

After each canonical comparison-ledger update, generate the detailed
side-by-side analysis automatically, retaining partial runs and unknown
measurements. Pin the user-selected reference or the previous relevant
measured integration build. Compare every transition and pass, not only
the overall mean. Include relatch/strict frames and milliseconds, stretch
episode count, frames and duration **with baseline, candidate and deltas
in the per-pass and per-transition summary tables**. Include memory,
retry causes/waits, CPU/GPU counters, trace gaps and environmental limits.
PR inclusion is the user's decision; this analysis is not a PR requirement,
publication default, or merge gate.

```text
node tools/renderscale-tuning-finalizer/comparison.js --baseline-root <run> --candidate-root <run> --output-root <separate-output-directory> --provenance-path <file>
```

The shader repository's `tools/compare-render-scale-ledger.py` wraps this
command and verifies all retained numeric timing cells against its existing
canonical ledger. Use that wrapper once per update when it is available in
the working shader checkout. By default it leaves both source runs and the
ledger unchanged. Its optional `--finalize-candidate <request.json>` combines
candidate finalization with the comparison, and `--ledger-candidate` plus
`--expected-ledger-sha256` validates and publishes a prepared append-only
ledger update. Follow the shader repository's reporting guide for those
explicit mutation options.

Keep the same output directory to reuse results only after input, code,
protocol, deployment and output hashes match. The full scalar CSV and all
journal revisions remain preserved; ledger timing validation always runs.
`reporting-performance.json` retains stage timings and reuse decisions.
`--quiet` suppresses routine stdout without suppressing errors or evidence.
Brief useful progress updates are welcome; do not repeat extraction or
comparison generation merely to narrate progress or rewrite prose.

The standalone reporter emits `comparison.md`, `comparison.json` and
`comparison.csv`; all nonempty and missing pair entries remain represented.
Raw indexed receipt hashes and Build ID/source/owner identities are checked.

The provenance JSON has `baseline` and `candidate` objects with full
`sourceCommit`, `rendererBaseCommit`, `mainVRBaseCommit` and `evidence`.
Unknown provenance stays null. An actual compiled source is never silently
substituted for an older renderer base with a reporting bridge backport.

Formal improvement or neutrality also needs matching fixture fingerprints,
complete relevant evidence and an explicit versioned tolerance policy.
The optional `--policy-path` JSON has `id`, `absoluteToleranceMs`,
`relativeTolerancePercent` and `requiredPasses` (at least two). The reporter
never invents tolerances. Unmatched data remain useful descriptive evidence;
lower latency does not compensate for observed adverse health findings.

Relatch proof is qualification dispatch to `firstNewGenerationProven`.
Strict completion includes the remaining qualification conditions.
Producer-request-to-applied frame count is a separate interval. Missing or
inapplicable relatch boundaries are null, not zero; means include sample
counts. Stretch pass totals span the owned capture, while row totals span
the row diagnostic window. Profiler totals without fresh resolved samples
cannot support GPU milliseconds or FPS claims.

Validate with `node tests/Test-RenderScaleTuningFinalizer.js` and
`node tests/Test-RenderScaleSwitchComparison.js`. All tests use temporary
fixtures; comparison generation does not contact DevBench or replay a run.

The toolkit also ships `compare-ledger.py`, the portable implementation of
the shader repository's `tools/compare-render-scale-ledger.py` entry point.
Supply `--ledger <canonical-ledger.csv>` when invoking it from the toolkit;
the other arguments and content-verified reuse rules are identical. Use one
column per run ID and explicit lane/pass/ordinal metric rows, including
partial AMD runs. Legacy unprefixed NVIDIA rows remain supported, and
duplicate matching metrics fail closed. Keep the shader entry point and
this distributed copy synchronized when updating this workflow.

AMD output includes `laneQualification` separately from raw render and
Task 2 results. It checks the configured lane, retained capability evidence,
physical native/scaled backend and required fallback proof. Failed or
missing qualification prevents a supported comparison assessment; it does
not rewrite terminal render results. Blocked-lane memory is inapplicable
only with retained capability proof and no contradictory execution evidence.

Ledger CSV reads admit complete JSON detail cells up to the file byte length
and restore the caller's parser limit afterward. Numeric audits and
historical-cell validation share this reader; no caller-side CSV override
or truncation is needed.

## Retry event compatibility and owned drain timing

Retry schema 1 permits additive event names. Validate every event's common
envelope, session, sequence and QPC ordering across the retained ring; apply
event-specific validation only to known kinds. Preserve unknown kinds with
explicit `compatibility` diagnostics, excluding them from known counts and
intervals. An additive event in an earlier transition must not invalidate
the current transition's verified retry count. Unsupported schema versions,
malformed envelopes and overwritten transition windows remain reporting
gaps. An unknown event cannot substitute for a missing known endpoint.

`ownedDrain` interprets `RelatchDrainBegin`, `RelatchDrainPending`,
`RelatchDrainReady`, `RelatchDrainInvalidated`, `RelatchCommitBegin` and
`RelatchSharedCleanup`. Match attempts by session, request, epoch, target
generation, begin frame and begin sequence. Never pair across a new begin or
invalidation. Retain ordered commit attempts and provider-specific ready
events; a provider may become ready before another reports pending. The
last observed provider readiness before commit supplies the ready endpoint,
not the first provider's readiness. Report begin-to-first-pending,
pending-to-ready, ready-to-commit, commit-to-shared-cleanup and
commit-to-applied in frames and milliseconds with their exact endpoints.
Commit-to-shared-cleanup is elapsed time to a phase marker, not an isolated
cleanup cost. The producer's `pendingObservations` counts polls, including
ready polls; expose it as `pollObservations` without changing the raw field.

Keep missing or ambiguous interval endpoints null with specific reasons;
do not infer cancellation from an unterminated attempt. Older producers do
not expose source generation, device identity, required-provider set or
resource revisions; keep those fields explicitly unavailable. This limits ownership
verification without erasing valid observed timing. An invalid individual
attempt must not erase an independently verified retry count. Keep the
six-frame guard and its overlap with stereo qualification separate.

New producers add `ownedRelease` schema 1 and `drainFences` observations.
`OwnedReleaseConsumed`, `OwnedTargetPublished`, `OwnedProviderPrepared` and
`OwnedReleaseEligibility` identify successful old-ticket consumption/reset,
physical target publication, actual target provider preparation, and release
eligibility respectively. Analyze these in `retryTelemetry.ownedRelease`,
separately from the old drain attempt that closes at `Applied`. Correlate
the exact owner, source/target generations, required providers, old provider
revisions and tickets, and opaque device/context/queue identities. Keep
target provider revisions and queue/fence identities separate from the old
drain identities. Opaque values and resource revisions are decimal strings,
not JavaScript numbers; absent optional observations are null.
The all-ready endpoint requires the latest Ready for every required provider,
matching its own ticket/revision and the shared certificate identity before
consumption, with no intervening invalidation. Missing or stale readiness
leaves that interval unavailable and the derived guard-exempt flag false;
the producer's original eligibility claim remains in the retained event.

`eligibilityScope=guard_exemption` permits omission of the settle guard;
it does not enable vendor dispatch. Target preparation and coherent stereo
still gate final promotion. Required/satisfied obligation bits mean old
provider drained (1), reset completed (2), detached retirement owned (4),
physical target published (8), target provider prepared (16), and coherent
stereo (32). Detached retirement ownership is not observed completion of
its fences. A denied or revoked exemption can end in ordinary conservative
promotion; retain that outcome without claiming proof-driven release.
Missing preparation after revocation remains explicitly unavailable.
An explicit unconsumed receipt with denied eligibility is `not_consumed`;
a missing consumption event for a receipt that claims consumption is a gap.

The request-to-admission interval uses the unique same-owner, same-clock
`preparation.events` request_queued observation, never the API dispatch
timestamp as a substitute. Fence issue/observed-ready QPC values come from
existing End/Signal and readiness polls, without additional GPU work. They
measure CPU observation times, not the exact instant GPU execution ended.
Report each fence interval and ready-to-consumed, consumed-to-publication,
publication-to-provider-preparation, publication-to-eligibility, and
provider-preparation/eligibility-to-promotion intervals with exact QPC
endpoints. Missing blocking-cleanup completion remains null. A legacy
Promoted event with generation zero is correlated by owner and the open
certificate sequence, with target-generation proof explicitly unavailable.
Old runs remain `ownedRelease.status=not_exposed`; do not infer these stages
from their aggregate stretch or shared-cleanup markers.

When producer telemetry changes, update its offline interpretation and
fixtures together. Run `node tests/Test-OwnedReleaseTelemetry.js`,
`node tests/Test-RenderScaleRetryTelemetry.js`,
`node tests/Test-RenderScaleTuningFinalizer.js` and
`node tests/Test-RenderScaleSwitchComparison.js`, including valid additive
events in a previous cumulative window, malformed events, missing endpoints
and multi-provider drain sequences. Keep source and packaged tools and
protocol references identical.

A reporter compatibility failure is repaired from the immutable journal.
Preserve the earlier incomplete outputs, record the corrected reporter
revision, then re-finalize the same run and refresh its existing ledger
column, comparisons and reports. Verify the raw hash, every numeric timing
and complete summary/comparison reconstruction; preserve historical run
cells. Do not replay measurements or change the startup/settling protocol
to repair an offline reporting failure.
