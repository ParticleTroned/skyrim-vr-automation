// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const assert = require("node:assert/strict");
const { retryTelemetry } = require("../tools/renderscale-tuning-finalizer/retry-telemetry.js");

function fixture() {
    const proof = { schemaVersion: 1, sourceGeneration: 4, requiredProviders: 3,
        fsrRevision: "7", dlssRevision: "8", fsrTicketSerial: "9", dlssTicketSerial: "10",
        targetFSRRevision: "11", targetDLSSRevision: "12", certificateSerial: null,
        deviceIdentity: "18446744073709551614", contextIdentity: "22", queueIdentity: "23",
        targetQueueIdentity: "25", targetFenceIdentity: "26", requestQueuedQpc: null,
        blockingCleanupReadyQpc: null, requiredObligations: 15, satisfiedObligations: 3,
        oldProofConsumed: true, targetPublished: false, providerPrepared: false,
        eligible: false, eligibilityScope: "guard_exemption" };
    const fence = { role: "FSRRuntime", result: "Pending", issueQpc: 113, readyQpc: null,
        deviceIdentity: "21", contextIdentity: null, queueIdentity: "23", fenceIdentity: "24", fenceValue: "3" };
    const drain = { beginFrame: 11, pendingObservations: 2 };
    const events = [
        { event: "RelatchAdmitted", timestampQpc: 110, frame: 11 },
        { event: "RelatchDrainBegin", timestampQpc: 112, frame: 11, ...drain, pendingObservations: 0 },
        { event: "RelatchDrainPending", timestampQpc: 115, frame: 11, ...drain, pendingObservations: 1,
            drainFences: [fence] },
        { event: "RelatchDrainReady", timestampQpc: 129, frame: 13, ...drain,
            reason: "dlss_relatch_drain_ready", ownedRelease: { ...proof, oldProofConsumed: false } },
        { event: "RelatchDrainReady", timestampQpc: 130, frame: 13, ...drain,
            reason: "fsr_relatch_drain_ready", ownedRelease: { ...proof, oldProofConsumed: false },
            drainFences: [{ ...fence, result: "Ready", readyQpc: 128 }] },
        { event: "RelatchCommitBegin", timestampQpc: 132, frame: 13, ...drain },
        { event: "RelatchSharedCleanup", timestampQpc: 135, frame: 13, ...drain },
        { event: "OwnedReleaseConsumed", timestampQpc: 138, frame: 13, ownedRelease: proof },
        { event: "OwnedTargetPublished", timestampQpc: 150, frame: 15,
            ownedRelease: { ...proof, targetPublished: true, satisfiedObligations: 11 } },
        { event: "OwnedReleaseEligibility", timestampQpc: 152, frame: 15,
            ownedRelease: { ...proof, targetPublished: true, eligible: true, satisfiedObligations: 15 } },
        { event: "Applied", timestampQpc: 155, frame: 15, generation: 0 },
        { event: "OwnedProviderPrepared", timestampQpc: 170, frame: 17,
            ownedRelease: { ...proof, targetPublished: true, providerPrepared: true, eligible: true, satisfiedObligations: 31 } },
        { event: "Promoted", timestampQpc: 190, frame: 19, generation: 0 },
        { event: "Stable", timestampQpc: 200, frame: 20 }
    ];
    const value = { waiter: { baseline: { stressSessionId: 1 },
        timing: { dispatchTick: 100, tickFrequency: 1000, strictSatisfiedTick: 210 },
        replacementTimeline: { firstPhysicalMutation: { replacementRequestId: 2, replacementTransitionEpoch: 3 },
            terminal: { replacementRequestId: 2, replacementTransitionEpoch: 3, tick: 210 } },
        status: { preparation: { schemaVersion: 1, sessionId: 1, qpcFrequency: 1000,
            events: [{ event: "request_queued", sessionId: 1, requestId: 2, transitionEpoch: 3,
                beginQpc: 101, endQpc: 101, occurrences: 1, frame: 10 }] },
        retryTelemetry: { schemaVersion: 1, devBenchOnly: true, sessionId: 1, qpcFrequency: 1000,
            capacity: 1024, overwrittenEvents: 0, coalescedEvents: 0, events } } } };
    return resequence(value);
}

function resequence(value) {
    const capture = value.waiter.status.retryTelemetry;
    capture.events = capture.events.map((event, index) => ({ sessionId: 1, requestId: 2, transitionEpoch: 3,
        generation: 5, beginFrame: 11, reason: "observed", ...event, sequence: index + 1 }));
    capture.retainedEvents = capture.events.length;
    return value;
}

function event(value, kind) {
    return value.waiter.status.retryTelemetry.events.find(entry => entry.event === kind);
}

function testOwnedReleaseTelemetry() {
    const complete = retryTelemetry(fixture());
    assert.equal(complete.status, "complete");
    assert.equal(complete.ownedDrain.attempts[0].status, "complete");
    const release = complete.ownedRelease;
    assert.equal(release.status, "complete");
    assert.equal(release.requestToAdmission.milliseconds, 9);
    assert.equal(release.requestToAdmission.frames, 1);
    assert.equal(release.fences.length, 1);
    assert.equal(release.fences[0].issueToObservedReady.milliseconds, 15);
    const attempt = release.attempts[0];
    assert.equal(attempt.status, "complete");
    assert.equal(attempt.identity.deviceIdentity, "18446744073709551614");
    assert.equal(attempt.intervals.readyToConsumed.milliseconds, 8);
    assert.equal(attempt.intervals.consumedToTargetPublished.milliseconds, 12);
    assert.equal(attempt.intervals.targetPublishedToProviderPrepared.milliseconds, 20);
    assert.equal(attempt.intervals.targetPublishedToProviderPrepared.frames, 2);
    assert.equal(attempt.intervals.targetPublishedToEligibility.milliseconds, 2);
    assert.equal(attempt.intervals.eligibilityToProviderPrepared.milliseconds, 18);
    assert.equal(attempt.intervals.providerPreparedToPromotion.milliseconds, 20);
    assert.equal(attempt.intervals.consumedToBlockingCleanupReady.milliseconds, null,
        "Detached retirement ownership does not imply blocking-cleanup fence completion.");
    assert.ok(attempt.identityReasons.includes("promotion_target_generation_not_exposed"));
    assert.ok(attempt.preparedSequence > complete.ownedDrain.attempts[0].closureSequence,
        "Applied closes the old drain, not the owned-release certificate.");

    for (const [mutate, reason] of [
        [value => { event(value, "OwnedProviderPrepared").ownedRelease.fsrTicketSerial = "99"; }, "certificate_identity_mismatch"],
        [value => { event(value, "OwnedProviderPrepared").ownedRelease.targetQueueIdentity = "99"; }, "target_identity_mismatch"],
        [value => { event(value, "Promoted").generation = 6; }, "promotion_target_generation_mismatch"],
        [value => { event(value, "OwnedReleaseConsumed").ownedRelease.oldProofConsumed = false; }, "consumption_not_confirmed"],
        [value => { event(value, "OwnedTargetPublished").ownedRelease.targetPublished = false; }, "target_publication_not_confirmed"],
        [value => { event(value, "OwnedProviderPrepared").ownedRelease.providerPrepared = false; }, "target_preparation_not_confirmed"],
        [value => { event(value, "OwnedProviderPrepared").event = "FuturePreparation"; }, "promotion_stage_endpoint_missing"],
        [value => { event(value, "OwnedReleaseConsumed").event = "FutureConsumption"; }, "consumed_endpoint_missing"],
        [value => { event(value, "OwnedReleaseEligibility").event = "FutureEligibility"; }, "promotion_eligibility_endpoint_missing"]
    ]) {
        const value = fixture();
        mutate(value);
        const result = retryTelemetry(resequence(value));
        assert.equal(result.status, "incomplete", reason);
        assert.ok(result.ownedRelease.reasons.includes(reason), reason);
        assert.equal(result.retryCount, 0, "Correlation gaps preserve independently verified retry counts.");
    }

    for (const corrupt of [proof => { proof.deviceIdentity = 18446744073709551614; },
        proof => { proof.schemaVersion = 2; }, proof => { proof.targetQueueIdentity = "0"; },
        proof => { proof.deviceIdentity = "18446744073709551616"; },
        proof => { proof.eligible = "true"; }, proof => { proof.satisfiedObligations = 7; },
        proof => { proof.blockingCleanupReadyQpc = 211; }, proof => { proof.requiredProviders = 4; },
        proof => { delete proof.eligibilityScope; }]) {
        const value = fixture();
        corrupt(event(value, "OwnedReleaseEligibility").ownedRelease);
        const result = retryTelemetry(value);
        assert.equal(result.status, "incomplete");
        assert.equal(result.retryCount, null, "Malformed known payloads invalidate the event window.");
    }

    for (const corrupt of [fence => { fence.readyQpc = 112; }, fence => { fence.readyQpc = 131; },
        fence => { fence.fenceIdentity = 24; }, fence => { fence.role = "FutureFence"; }]) {
        const value = fixture();
        const fsrReady = value.waiter.status.retryTelemetry.events.find(entry => entry.drainFences?.[0].readyQpc);
        corrupt(fsrReady.drainFences[0]);
        assert.equal(retryTelemetry(value).status, "incomplete");
    }

    const older = fixture();
    older.waiter.status.retryTelemetry.events = older.waiter.status.retryTelemetry.events.filter(entry => !entry.event.startsWith("Owned"));
    for (const entry of older.waiter.status.retryTelemetry.events) delete entry.ownedRelease;
    delete older.waiter.status.preparation;
    const oldResult = retryTelemetry(resequence(older));
    assert.equal(oldResult.status, "complete");
    assert.equal(oldResult.ownedRelease.status, "not_exposed");
    assert.equal(oldResult.ownedRelease.requestToAdmission.milliseconds, null);

    for (const corrupt of [preparation => { preparation.qpcFrequency++; },
        preparation => { preparation.events[0].occurrences = 2; },
        preparation => { preparation.events.push({ ...preparation.events[0] }); },
        preparation => { preparation.events[0].requestId++; }]) {
        const value = fixture();
        corrupt(value.waiter.status.preparation);
        const result = retryTelemetry(value);
        assert.equal(result.ownedRelease.requestObservation.status, "incomplete");
        assert.equal(result.ownedRelease.requestToAdmission.milliseconds, null);
        assert.equal(result.ownedRelease.attempts[0].intervals.readyToConsumed.milliseconds, 8);
    }

    const additive = fixture();
    additive.waiter.status.retryTelemetry.events.splice(12, 0, { event: "FutureOwnedStage",
        timestampQpc: 180, frame: 18, drainFences: "future_event_specific_payload",
        futurePayload: { precise: "18446744073709551614" } });
    const additiveResult = retryTelemetry(resequence(additive));
    assert.equal(additiveResult.status, "complete");
    assert.deepEqual(additiveResult.compatibility.unknownEventTypes, ["FutureOwnedStage"]);
    assert.deepEqual(additiveResult.events.find(entry => entry.event === "FutureOwnedStage").futurePayload,
        { precise: "18446744073709551614" });

    const denied = fixture();
    event(denied, "OwnedReleaseEligibility").ownedRelease.eligible = false;
    event(denied, "OwnedProviderPrepared").event = "FutureConservativePreparation";
    const deniedResult = retryTelemetry(denied);
    assert.equal(deniedResult.status, "complete");
    assert.equal(deniedResult.ownedRelease.attempts[0].status, "denied");
    assert.equal(deniedResult.ownedRelease.attempts[0].guardExempt, false,
        "A denied guard exemption does not forbid eventual conservative promotion.");

    const revoked = fixture();
    event(revoked, "OwnedProviderPrepared").event = "ProofRevoked";
    const revokedResult = retryTelemetry(revoked);
    assert.equal(revokedResult.status, "complete");
    assert.equal(revokedResult.ownedRelease.attempts[0].status, "revoked");
    assert.equal(revokedResult.ownedRelease.attempts[0].guardExempt, false);
    assert.ok(revokedResult.ownedRelease.attempts[0].unavailableFields.includes("provider_preparation_not_observed"));

    const unsignedMask = fixture();
    const unsignedProof = event(unsignedMask, "OwnedReleaseEligibility").ownedRelease;
    unsignedProof.requiredObligations = unsignedProof.satisfiedObligations = 0x8000000f;
    assert.equal(retryTelemetry(unsignedMask).status, "complete");

    const notConsumed = fixture();
    notConsumed.waiter.status.retryTelemetry.events = notConsumed.waiter.status.retryTelemetry.events.filter(entry =>
        !["OwnedReleaseConsumed", "OwnedProviderPrepared"].includes(entry.event));
    for (const entry of notConsumed.waiter.status.retryTelemetry.events.filter(entry => entry.ownedRelease)) {
        entry.ownedRelease.oldProofConsumed = false;
        entry.ownedRelease.eligible = false;
        entry.ownedRelease.fsrTicketSerial = null;
        entry.ownedRelease.satisfiedObligations = 8;
    }
    const notConsumedResult = retryTelemetry(resequence(notConsumed));
    assert.equal(notConsumedResult.status, "complete");
    assert.equal(notConsumedResult.ownedRelease.attempts[0].status, "not_consumed");
    assert.equal(notConsumedResult.ownedRelease.attempts[0].intervals.readyToConsumed.milliseconds, null);

    for (const mutation of [value => { event(value, "RelatchDrainReady").event = "FutureReadyObservation"; },
        value => { event(value, "RelatchDrainReady").ownedRelease.dlssTicketSerial = "99"; }]) {
        const value = fixture();
        mutation(value);
        const result = retryTelemetry(value).ownedRelease.attempts[0];
        assert.equal(result.intervals.readyToConsumed.milliseconds, null);
        assert.equal(result.guardExempt, false);
        assert.equal(result.guardExemptionClaimed, true);
    }
    const zeroProviders = fixture();
    event(zeroProviders, "OwnedReleaseConsumed").ownedRelease.requiredProviders = 0;
    assert.equal(retryTelemetry(zeroProviders).status, "incomplete");

    for (const [position, tick, frame] of [[11, 165, 16], [12, 180, 18]]) {
        const failed = fixture();
        failed.waiter.status.retryTelemetry.events.splice(position, 0,
            { event: "Failure", timestampQpc: tick, frame, reason: "provider_failure" });
        const failedResult = retryTelemetry(resequence(failed));
        const failedAttempt = failedResult.ownedRelease.attempts[0];
        assert.equal(failedResult.status, "complete", "Observed runtime failure is not a reporting failure.");
        assert.equal(failedAttempt.status, "failed");
        assert.equal(failedAttempt.guardExempt, false);
        assert.equal(failedAttempt.closure, "failed");
        assert.equal(failedAttempt.promotionSequence, null);
        assert.equal(failedAttempt.promotionCorrelation, null);
        assert.equal(failedAttempt.intervals.eligibilityToPromotion.milliseconds, null);
        assert.equal(failedAttempt.intervals.failureToRecoveryPromotion.milliseconds, 190 - tick);
        assert.equal(failedAttempt.recoveryPromotionCorrelation, "same_request_epoch_after_failure_no_certificate_attribution");
        assert.ok(failedAttempt.followingEvents.some(entry => entry.event === "Promoted"));
        if (position === 11) assert.equal(failedAttempt.preparedSequence, null,
            "Preparation after failure cannot restore the failed certificate.");
    }

    for (const corrupt of [proof => { proof.targetPublished = false; },
        proof => { proof.oldProofConsumed = false; }, proof => { proof.targetFSRRevision = null; },
        proof => { proof.targetDLSSRevision = null; }, proof => { proof.requiredObligations = 0; },
        proof => { proof.requiredObligations = 8; }]) {
        const invalidEligibility = fixture();
        corrupt(event(invalidEligibility, "OwnedReleaseEligibility").ownedRelease);
        const result = retryTelemetry(invalidEligibility);
        assert.equal(result.status, "incomplete");
        assert.equal(result.retryCount, null);
        assert.equal(result.ownedRelease.attempts[0].guardExempt, false);
    }

    const hostOnly = fixture();
    for (const entry of hostOnly.waiter.status.retryTelemetry.events.filter(entry => entry.ownedRelease)) {
        entry.ownedRelease.targetQueueIdentity = null;
        entry.ownedRelease.targetFenceIdentity = null;
    }
    const hostOnlyResult = retryTelemetry(hostOnly);
    assert.equal(hostOnlyResult.status, "complete");
    assert.equal(hostOnlyResult.ownedRelease.attempts[0].guardExempt, true);
    assert.equal(event(hostOnly, "OwnedReleaseEligibility").ownedRelease.providerPrepared, false,
        "Guard eligibility precedes actual provider preparation.");

    const cleanupOwnership = fixture();
    event(cleanupOwnership, "OwnedReleaseEligibility").ownedRelease.blockingCleanupReadyQpc = 151;
    const ownershipInterval = retryTelemetry(cleanupOwnership).ownedRelease.attempts[0].intervals.consumedToBlockingCleanupReady;
    assert.equal(ownershipInterval.milliseconds, 13);
    assert.equal(ownershipInterval.definition, "consumed_to_observed_cleanup_ownership_ready_not_fence_completion");

}

if (require.main === module) {
    testOwnedReleaseTelemetry();
    console.log("Owned-release telemetry tests passed (stage timing, identity, compatibility, unavailable evidence, and corruption).");
}
module.exports = { fixture, testOwnedReleaseTelemetry };
