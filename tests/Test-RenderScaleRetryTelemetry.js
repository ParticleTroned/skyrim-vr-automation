// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const assert = require("node:assert/strict");
const { retryTelemetry } = require("../tools/renderscale-tuning-finalizer/retry-telemetry.js");

function fixture() {
    const guard = { guardStartFrame: 11, minimumSettleFrames: 6,
        guardDeadlineFrame: 17, stableCycles: 2, requiredStableCycles: 2,
        proofDrivenRelease: false, settleGuardRequired: true };
    const viewport = role => ({ role, slot: 1, cacheHit: false,
        victimQuality: 3, victimPreset: 1, fenceResult: "Pending" });
    const events = [
        { event: "GuardArmed", timestampQpc: 110, frame: 11, ...guard },
        { event: "ViewportWaitBegin", timestampQpc: 120, frame: 12, viewport: viewport("FullEye") },
        { event: "Retry", timestampQpc: 121, frame: 12, retryKind: "Backend",
            reason: "dlss_viewport_recycle", sourceFile: "Upscaling.cpp", sourceLine: 100 },
        { event: "ViewportWaitEnd", timestampQpc: 130, frame: 13,
            reason: "viewport_preparation_ready", beginSequence: 2, beginQpc: 120, beginFrame: 12,
            pendingObservations: 2, viewport: { ...viewport("FullEye"), fenceResult: "Ready" } },
        { event: "ViewportReady", timestampQpc: 135, frame: 14,
            viewport: { ...viewport("SubmitStageFoveatedCenter"), cacheHit: true, fenceResult: "NotPolled" } },
        { event: "SettleGuardSatisfied", timestampQpc: 170, frame: 17, ...guard },
        { event: "PromotionCandidate", timestampQpc: 180, frame: 18, ...guard },
        { event: "Promoted", timestampQpc: 190, frame: 19, ...guard },
        { event: "Stable", timestampQpc: 200, frame: 20 },
    ].map((event, index) => ({ sequence: index + 1, sessionId: 1, requestId: 2,
        transitionEpoch: 3, generation: 5, reason: "observed", ...event }));
    return { waiter: { baseline: { stressSessionId: 1 },
        timing: { dispatchTick: 100, tickFrequency: 1000, strictSatisfiedTick: 210 },
        replacementTimeline: { firstPhysicalMutation: { replacementRequestId: 2, replacementTransitionEpoch: 3 },
            terminal: { replacementRequestId: 2, replacementTransitionEpoch: 3, tick: 210 } },
        status: { retryTelemetry: { schemaVersion: 1, devBenchOnly: true, sessionId: 1,
            qpcFrequency: 1000, capacity: 1024, retainedEvents: events.length,
            overwrittenEvents: 0, coalescedEvents: 0, events } } } };
}

function replaceEvents(value, events) {
    const capture = value.waiter.status.retryTelemetry;
    capture.events = events.map((event, index) => ({ sessionId: 1, requestId: 2,
        transitionEpoch: 3, generation: 5, reason: "observed", ...event, sequence: index + 1 }));
    capture.retainedEvents = capture.events.length;
    return value;
}

function drainEvent(event, timestampQpc, frame, pendingObservations, extra = {}) {
    return { event, timestampQpc, frame, pendingObservations, beginFrame: 11, ...extra };
}

function ownedDrainFixture({ providers = ["FSR"], earlyProvider = null, pending = true } = {}) {
    const ready = (provider, tick, frame, polls) => drainEvent("RelatchDrainReady", tick, frame, polls,
        { reason: `${provider.toLowerCase()}_relatch_drain_ready` });
    const events = [drainEvent("RelatchDrainBegin", 110, 11, 0)];
    if (earlyProvider) events.push(ready(earlyProvider, 115, 11, 1));
    if (pending) {
        events.push(drainEvent("RelatchDrainPending", 120, 12, 1),
            { event: "Retry", timestampQpc: 121, frame: 12, retryKind: "Backend",
                reason: "render_target_relatch_requeued", sourceFile: "Upscaling.cpp", sourceLine: 101 });
    }
    providers.filter(provider => provider !== earlyProvider).forEach((provider, index) => {
        events.push(ready(provider, 150 + index, 15, pending ? 2 : 1));
    });
    events.push({ event: "RelatchAdmitted", timestampQpc: 155, frame: 15 },
        drainEvent("RelatchCommitBegin", 160, 16, pending ? 3 : 2),
        drainEvent("RelatchSharedCleanup", 170, 17, pending ? 3 : 2),
        { event: "Applied", timestampQpc: 180, frame: 18, generation: 0, beginFrame: 0 },
        { event: "Stable", timestampQpc: 190, frame: 19 });
    return replaceEvents(fixture(), events);
}

function testAdditiveEventCompatibility() {
    const original = retryTelemetry(fixture());
    const value = fixture();
    const events = value.waiter.status.retryTelemetry.events;
    events.splice(5, 0, { ...events[4], event: "ViewportFutureObservation", timestampQpc: 140 });
    replaceEvents(value, events);
    let result = retryTelemetry(value);
    assert.equal(result.status, "complete");
    assert.equal(result.retryCount, original.retryCount);
    assert.deepEqual(result.stabilization, original.stabilization.map(entry => ({
        ...entry, candidateSequence: entry.candidateSequence + 1 })));
    assert.equal(result.waits[0].observedWaitMs, original.waits[0].observedWaitMs);
    assert.deepEqual(result.compatibility.unknownEventTypes, ["ViewportFutureObservation"]);
    assert.equal(result.compatibility.unknownEventCount, 1);
    assert.equal(result.compatibility.ownerUnknownEventCount, 1);
    assert.equal(result.events[5].event, "ViewportFutureObservation");

    const older = fixture();
    older.waiter.status.retryTelemetry.events.unshift({ event: "FutureOlderOwner", timestampQpc: 50,
        frame: 5, requestId: 99 });
    replaceEvents(older, older.waiter.status.retryTelemetry.events);
    older.waiter.status.retryTelemetry.events[4].beginSequence++;
    result = retryTelemetry(older);
    assert.equal(result.retryCount, 1);
    assert.equal(result.compatibility.unknownEventCount, 1);
    assert.equal(result.compatibility.ownerUnknownEventCount, 0);

    for (const corrupt of [event => { event.event = ""; }, event => { event.event = "  "; },
        event => { event.event = " Retry "; }, event => { event.event = "Future Event"; },
        event => { event.event = 42; }, event => { event.timestampQpc = 0; },
        event => { event.timestampQpc = 119; }, event => { event.sequence++; },
        event => { event.sessionId++; }, event => { event.requestId = 0; },
        event => { event.transitionEpoch = -1; }, event => { event.frame = -1; },
        event => { event.reason = ""; }]) {
        const bad = structuredClone(value);
        corrupt(bad.waiter.status.retryTelemetry.events[5]);
        result = retryTelemetry(bad);
        assert.equal(result.status, "incomplete");
        assert.equal(result.retryCount, null);
        assert.equal(result.waits[0].observedWaitMs, null);
    }
    const missing = fixture();
    missing.waiter.status.retryTelemetry.events[3].event = "FutureWaitEnd";
    result = retryTelemetry(missing);
    assert.equal(result.retryCount, 1);
    assert.equal(result.waits[0].observedWaitMs, null);
    assert.ok(result.reasons.includes("viewport_wait_unresolved"));
    const major = fixture();
    major.waiter.status.retryTelemetry.schemaVersion = 2;
    assert.equal(retryTelemetry(major).status, "unsupported_schema");
    const missingStable = fixture();
    missingStable.waiter.status.retryTelemetry.events.at(-1).event = "FutureStable";
    result = retryTelemetry(missingStable);
    assert.equal(result.retryCount, 1);
    assert.equal(result.retries[0].retryToStableMs, null);
    assert.ok(result.reasons.includes("retry_stable_endpoint_missing"));
}

function testOwnedDrainTelemetry() {
    for (const providers of [["FSR"], ["DLSS"], ["FSR", "DLSS"]]) {
        const result = retryTelemetry(ownedDrainFixture({ providers }));
        assert.equal(result.status, "complete");
        const attempt = result.ownedDrain.attempts[0];
        assert.equal(attempt.status, "complete");
        assert.deepEqual(attempt.observedProviders, providers);
        assert.equal(attempt.pollObservations, 3, "Poll observations include ready and commit polls.");
        assert.equal(attempt.identity.targetGeneration, 5);
        assert.equal(attempt.identity.requiredProviders, null);
        assert.ok(attempt.identityReasons.includes("required_provider_set_not_exposed"));
        assert.ok(attempt.identityReasons.includes("applied_target_generation_not_exposed"));
        assert.equal(attempt.intervals.beginToFirstPending.milliseconds, 10);
        assert.equal(attempt.intervals.pendingToReady.milliseconds, providers.length === 2 ? 31 : 30);
        assert.equal(attempt.intervals.pendingToReady.frames, 3);
        assert.equal(attempt.intervals.commitToSharedCleanup.milliseconds, 10);
        assert.equal(attempt.intervals.commitToApplied.milliseconds, 20);
        assert.equal(result.retries[0].intervals.requeueToAdmission.milliseconds, 34);
        assert.equal(result.retries[0].intervals.retryToStable.frames, 7);
    }
    const dual = retryTelemetry(ownedDrainFixture({ providers: ["DLSS", "FSR"], earlyProvider: "DLSS" }));
    assert.equal(dual.ownedDrain.attempts[0].intervals.pendingToReady.milliseconds, 30,
        "The final provider Ready, rather than an earlier provider Ready, closes the observed wait.");
    const highQpc = ownedDrainFixture({ providers: ["DLSS", "FSR"], earlyProvider: "DLSS" });
    const ticks = [1513463800459, 1513463802003, 1513463802006, 1513463802170,
        1513464268690, 1513464269178, 1513464270354, 1513464271469, 1513464790121, 1513469394388];
    highQpc.waiter.status.retryTelemetry.events.forEach((event, index) => {
        event.timestampQpc = ticks[index];
        event.frame = index < 4 ? 28188 : index < 9 ? 28189 : 28197;
        if (event.beginFrame) event.beginFrame = 28188;
    });
    highQpc.waiter.status.retryTelemetry.qpcFrequency = 10000000;
    highQpc.waiter.timing = { dispatchTick: 1513459822883, tickFrequency: 10000000, strictSatisfiedTick: 1513472047346 };
    highQpc.waiter.replacementTimeline.terminal.tick = 1513472047346;
    const measured = retryTelemetry(highQpc).ownedDrain.attempts[0];
    assert.equal(measured.intervals.pendingToReady.milliseconds, 46.6684);
    assert.equal(measured.intervals.pendingToReady.frames, 1);
    assert.equal(measured.intervals.readyToCommit.milliseconds, 0.1664);
    assert.equal(measured.intervals.readyToCommit.frames, 0);
    const noPending = retryTelemetry(ownedDrainFixture({ pending: false, providers: ["FSR", "DLSS"] }));
    assert.equal(noPending.status, "complete");
    assert.equal(noPending.retryCount, 0);
    assert.equal(noPending.ownedDrain.attempts[0].intervals.pendingToReady.milliseconds, null);
    assert.deepEqual(noPending.ownedDrain.attempts[0].intervals.pendingToReady.reasons, ["pending_not_observed"]);

    for (const corrupt of [event => { event.generation = 0; }, event => { event.beginFrame = 0; },
        event => { event.beginFrame--; }, event => { event.pendingObservations++; }]) {
        const bad = ownedDrainFixture();
        corrupt(bad.waiter.status.retryTelemetry.events[0]);
        const result = retryTelemetry(bad);
        assert.equal(result.retryCount, null, "Known drain events retain strict producer field validation.");
        assert.equal(result.ownedDrain.attempts[0].intervals.pendingToReady.milliseconds, null);
    }

    for (const [corrupt, reason] of [
        [events => { events[0].event = "FutureDrainBegin"; }, "drain_begin_missing"],
        [events => { events[3].event = "FutureReady"; }, "ready_endpoint_missing"],
        [events => { events[7].event = "FutureApplied"; }, "applied_endpoint_missing"],
        [events => { events[3].generation++; }, "drain_identity_mismatch"],
        [events => { events[3].beginFrame++; }, "drain_identity_mismatch"],
        [events => { events[5].pendingObservations = 1; }, "poll_observations_regressed"],
        [events => { events.splice(4, 0, { ...events[3], timestampQpc: 151 }); }, "duplicate_provider_ready_without_new_poll"]
    ]) {
        const bad = ownedDrainFixture();
        corrupt(bad.waiter.status.retryTelemetry.events);
        replaceEvents(bad, bad.waiter.status.retryTelemetry.events);
        const result = retryTelemetry(bad);
        assert.equal(result.status, "incomplete");
        assert.equal(result.retryCount, 1, "An owned-drain gap must not erase verified Retry events.");
        assert.ok(result.ownedDrain.reasons.includes(reason), reason);
    }
    const repeated = ownedDrainFixture();
    const repeatedEvents = repeated.waiter.status.retryTelemetry.events;
    repeatedEvents.splice(7, 0, drainEvent("RelatchCommitBegin", 175, 17, 4));
    replaceEvents(repeated, repeatedEvents);
    const retry = retryTelemetry(repeated).ownedDrain.attempts[0];
    assert.equal(retry.status, "complete");
    assert.equal(retry.commits.length, 2);
    assert.equal(retry.commits[0].status, "retried");
    assert.equal(retry.commits[0].intervals.commitToApplied.milliseconds, null);
    assert.equal(retry.commits[1].intervals.commitToApplied.milliseconds, 5);
    assert.equal(retry.commits[1].intervals.commitToSharedCleanup.milliseconds, null);

    const separated = ownedDrainFixture();
    const second = separated.waiter.status.retryTelemetry.events;
    const first = [drainEvent("RelatchDrainBegin", 101, 11, 0),
        drainEvent("RelatchDrainPending", 102, 11, 1),
        drainEvent("RelatchDrainInvalidated", 103, 11, 2, { reason: "relatch_drain_owner_changed" })];
    replaceEvents(separated, [...first, ...second]);
    const attempts = retryTelemetry(separated).ownedDrain.attempts;
    assert.equal(attempts.length, 2);
    assert.equal(attempts[0].status, "invalidated");
    assert.equal(attempts[0].identity.beginFrame, attempts[1].identity.beginFrame);
    assert.notEqual(attempts[0].beginSequence, attempts[1].beginSequence);
    assert.equal(attempts[0].intervals.pendingToReady.milliseconds, null);
    assert.equal(attempts[1].intervals.pendingToReady.milliseconds, 30);

    const noClosure = structuredClone(separated);
    noClosure.waiter.status.retryTelemetry.events[2].event = "FutureInvalidated";
    const unclosed = retryTelemetry(noClosure);
    assert.ok(unclosed.ownedDrain.attempts[0].reasons.includes("closure_missing_before_next_begin"));
    assert.equal(unclosed.ownedDrain.attempts[0].intervals.pendingToReady.milliseconds, null);
}

function testRetryTelemetry() {
    const value = fixture();
    let result = retryTelemetry(value);
    assert.equal(result.status, "complete");
    assert.equal(result.outcome, "available");
    assert.equal(result.retryCount, 1);
    assert.equal(result.waits[0].observedWaitMs, 10);
    assert.equal(result.retries[0].retryToStableMs, 79);
    assert.equal(result.stabilization[0].readyToCandidateMs, 45);
    assert.equal(result.stabilization[0].candidateToPromotionMs, 10);

    for (const corrupt of [
        capture => { capture.retainedEvents--; },
        capture => { capture.events[2].sequence = capture.events[1].sequence; },
        capture => { capture.events[2].timestampQpc = 119; },
        capture => { capture.events[2].sourceFile = ""; },
        capture => { capture.events[2].frame = -1; },
        capture => { capture.events[2] = null; },
        capture => { capture.events[2].event = 42; },
    ]) {
        const bad = fixture();
        corrupt(bad.waiter.status.retryTelemetry);
        result = retryTelemetry(bad);
        assert.equal(result.status, "incomplete");
        assert.equal(result.outcome, "n/a");
        assert.equal(result.retryCount, null);
        assert.ok(result.waits.every(wait => wait.observedWaitMs === null));
        assert.ok(result.stabilization.every(entry => entry.readyToCandidateMs === null));
    }
    for (const corrupt of [
        events => { events[3].generation = 6; },
        events => { events[3].beginFrame++; },
        events => { events[3].pendingObservations = 0; },
        events => { events[3].event = "RelatchAdmitted"; },
    ]) {
        const bad = fixture();
        corrupt(bad.waiter.status.retryTelemetry.events);
        result = retryTelemetry(bad);
        assert.equal(result.status, "incomplete");
        assert.equal(result.retryCount, 1, "A missing wait endpoint must not erase a verified retry count.");
        assert.equal(result.waits[0].observedWaitMs, null);
        assert.equal(result.stabilization[0].readyToCandidateMs, null);
    }
    for (const corrupt of [
        events => { events[0].event = "GuardCleared"; },
        events => { events[5].frame = 16; },
        events => { events[6].guardDeadlineFrame = 16; },
        events => { events[6].stableCycles = 1; },
        events => { events[7].event = "GuardCleared"; },
    ]) {
        const bad = fixture();
        corrupt(bad.waiter.status.retryTelemetry.events);
        result = retryTelemetry(bad);
        assert.equal(result.stabilization[0].status, "incomplete");
        assert.equal(result.stabilization[0].readyToCandidateMs, null);
        assert.equal(result.stabilization[0].candidateToPromotionMs, null);
    }
    const overflow = fixture(), capture = overflow.waiter.status.retryTelemetry;
    capture.overwrittenEvents = 5;
    capture.capacity = capture.events.length;
    capture.events.forEach(event => { event.sequence += 5; if (event.beginSequence) event.beginSequence += 5; });
    assert.equal(retryTelemetry(overflow).retryCount, null);
    capture.events.unshift({ ...capture.events[0], sequence: 6, timestampQpc: 50,
        frame: 5, event: "Applied", requestId: 99 });
    capture.events.slice(1).forEach(event => { event.sequence++; if (event.beginSequence) event.beginSequence++; });
    capture.retainedEvents++;
    capture.capacity++;
    result = retryTelemetry(overflow);
    assert.equal(result.status, "complete", "Old overwritten events outside the covered window are not a current gap.");
    assert.equal(result.retryCount, 1);

    const changedOwner = fixture();
    changedOwner.waiter.replacementTimeline.firstPhysicalMutation.replacementRequestId = 98;
    assert.equal(retryTelemetry(changedOwner).retryCount, null);
    assert.equal(retryTelemetry(null).status, "not_exposed");
    assert.equal(retryTelemetry(null).outcome, "n/a");
    testAdditiveEventCompatibility();
    testOwnedDrainTelemetry();
}

if (require.main === module) {
    testRetryTelemetry();
    process.stdout.write("Render-scale retry telemetry tests passed.\n");
}
module.exports = { fixture, ownedDrainFixture, testRetryTelemetry };
