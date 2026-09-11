// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const ownedReleaseEvents = new Set(["OwnedReleaseConsumed", "OwnedTargetPublished",
    "OwnedProviderPrepared", "OwnedReleaseEligibility"]);
const fenceObservationEvents = new Set([...ownedReleaseEvents, "RelatchDrainBegin", "RelatchDrainPending",
    "RelatchDrainReady", "RelatchDrainInvalidated", "RelatchCommitBegin", "RelatchSharedCleanup"]);
const identityFields = ["fsrRevision", "dlssRevision", "fsrTicketSerial", "dlssTicketSerial",
    "certificateSerial", "deviceIdentity", "contextIdentity", "queueIdentity"];
const targetRevisionFields = ["targetFSRRevision", "targetDLSSRevision", "targetQueueIdentity", "targetFenceIdentity"];
const positive = value => Number.isSafeInteger(value) && value > 0;
const nonnegative = value => Number.isSafeInteger(value) && value >= 0;
const opaque = value => value === null || typeof value === "string" &&
    /^[1-9][0-9]{0,19}$/.test(value) && BigInt(value) <= 0xffffffffffffffffn;
const optionalTick = value => value === null || positive(value);
const masks = value => nonnegative(value) && value <= 0xffffffff;

function validOwnedReleasePayload(event) {
    const proof = event.ownedRelease;
    if (!proof || proof.schemaVersion !== 1 || !nonnegative(proof.sourceGeneration) ||
        !nonnegative(proof.requiredProviders) || proof.requiredProviders > 3 ||
        !positive(event.generation) || !positive(event.beginFrame) || event.beginFrame > event.frame ||
        !identityFields.every(key => opaque(proof[key])) ||
        !targetRevisionFields.every(key => opaque(proof[key])) ||
        !optionalTick(proof.requestQueuedQpc) || !optionalTick(proof.blockingCleanupReadyQpc) ||
        !masks(proof.requiredObligations) || !masks(proof.satisfiedObligations) ||
        !["guard_exemption", "presentation"].includes(proof.eligibilityScope) ||
        !["oldProofConsumed", "targetPublished", "providerPrepared", "eligible"].every(key => typeof proof[key] === "boolean")) return false;
    if (proof.eligible && ((proof.satisfiedObligations & proof.requiredObligations) >>> 0) !== proof.requiredObligations) return false;
    if (proof.requiredProviders === 0 && (proof.oldProofConsumed || proof.eligible)) return false;
    return [proof.requestQueuedQpc, proof.blockingCleanupReadyQpc].every(tick => tick === null || tick <= event.timestampQpc);
}

function validFenceObservations(event) {
    if (event.drainFences === undefined) return true;
    if (!Array.isArray(event.drainFences)) return false;
    const roles = new Set();
    return event.drainFences.every(fence => {
        if (!fence || !["FSRHost", "FSRInterop", "FSRRuntime", "DLSSHost"].includes(fence.role) || roles.has(fence.role)) return false;
        roles.add(fence.role);
        return ["NotPolled", "Pending", "Ready", "Failed"].includes(fence.result) &&
            optionalTick(fence.issueQpc) && optionalTick(fence.readyQpc) &&
            ["deviceIdentity", "contextIdentity", "queueIdentity", "fenceIdentity", "fenceValue"].every(key => opaque(fence[key])) &&
            (fence.issueQpc === null || fence.issueQpc <= event.timestampQpc) &&
            (fence.readyQpc === null || positive(fence.issueQpc) && fence.readyQpc >= fence.issueQpc && fence.readyQpc <= event.timestampQpc) &&
            (fence.result !== "Ready" || positive(fence.readyQpc));
    });
}

function tickInterval(beginQpc, endQpc, frequency, reason = null) {
    const reasons = reason ? [reason] : [];
    if (!reason && (!positive(beginQpc) || !positive(endQpc))) reasons.push("endpoint_not_exposed");
    if (!reason && positive(beginQpc) && positive(endQpc) && endQpc < beginQpc) reasons.push("invalid_interval_order");
    return { status: reasons.length ? "not_available" : "complete", reasons,
        beginQpc: beginQpc ?? null, endQpc: endQpc ?? null,
        milliseconds: reasons.length ? null : (endQpc - beginQpc) * 1000 / frequency };
}

function requestObservation(retained, owner) {
    const preparation = retained?.waiter?.status?.preparation || retained?.waiter?.observation?.status?.preparation;
    if (!preparation) return { status: "not_exposed", reasons: ["request_queue_observation_not_exposed"], event: null };
    if (preparation.schemaVersion !== 1 || preparation.sessionId !== owner.sessionId ||
        preparation.qpcFrequency !== owner.qpcFrequency || !Array.isArray(preparation.events)) {
        return { status: "incomplete", reasons: ["request_queue_clock_or_owner_mismatch"], event: null };
    }
    const matches = preparation.events.filter(event => event?.event === "request_queued" &&
        event.sessionId === owner.sessionId && event.requestId === owner.requestId && event.transitionEpoch === owner.transitionEpoch);
    if (matches.length !== 1 || matches[0].occurrences !== 1 || !positive(matches[0].beginQpc) ||
        matches[0].beginQpc !== matches[0].endQpc || !nonnegative(matches[0].frame)) {
        return { status: "incomplete", reasons: [matches.length > 1 ? "request_queue_ambiguous" :
            matches.length === 0 ? "request_queue_endpoint_missing" : "request_queue_coalesced_or_invalid"], event: null };
    }
    return { status: "complete", reasons: [], event: matches[0], definition: "producer_request_queue_observation" };
}

function certificateIdentity(event) {
    const proof = event.ownedRelease;
    return { sourceGeneration: proof.sourceGeneration, targetGeneration: event.generation, beginFrame: event.beginFrame,
        requiredProviders: proof.requiredProviders,
        ...Object.fromEntries(identityFields.map(key => [key, proof[key]])) };
}

function ownedReleaseTelemetry(events, clock, retained, owner) {
    const stages = events.filter(event => ownedReleaseEvents.has(event.event));
    const request = requestObservation(retained, owner);
    const admitted = events.find(event => event.event === "RelatchAdmitted");
    const requestToAdmission = tickInterval(request.event?.beginQpc, admitted?.timestampQpc, clock.qpcFrequency,
        !clock.windowComplete ? "event_window_incomplete" : request.status !== "complete" ? request.reasons[0] : null);
    if (requestToAdmission.status === "complete") {
        requestToAdmission.frames = admitted.frame >= request.event.frame ? admitted.frame - request.event.frame : null;
        if (requestToAdmission.frames === null) {
            requestToAdmission.status = "incomplete";
            requestToAdmission.reasons.push("request_queue_frame_after_admission");
            requestToAdmission.milliseconds = null;
        }
    }
    const fences = new Map();
    for (const event of events) for (const fence of fenceObservationEvents.has(event.event) && validFenceObservations(event) ? event.drainFences || [] : []) {
        const key = JSON.stringify([event.generation, event.beginFrame, fence.role, fence.deviceIdentity,
            fence.contextIdentity, fence.queueIdentity, fence.fenceIdentity, fence.fenceValue, fence.issueQpc]);
        const previous = fences.get(key);
        if (!previous || fence.readyQpc !== null || previous.observation.readyQpc === null) {
            fences.set(key, { observation: fence, sequence: event.sequence,
                issueToObservedReady: tickInterval(fence.issueQpc, fence.readyQpc, clock.qpcFrequency,
                    !clock.windowComplete ? "event_window_incomplete" : null) });
        }
    }
    const attempts = [];
    let active = null;
    for (const event of events) {
        if (ownedReleaseEvents.has(event.event) && !validOwnedReleasePayload(event)) continue;
        if (event.event === "OwnedReleaseConsumed") {
            if (active && !active.promotion) active.closure = "replaced";
            active = { consumed: event, identity: certificateIdentity(event), events: [], reasons: [], promotion: null };
            attempts.push(active);
        }
        if (ownedReleaseEvents.has(event.event)) {
            if (!active) {
                active = { consumed: null, identity: certificateIdentity(event), events: [], reasons: [], promotion: null };
                attempts.push(active);
            }
            if (JSON.stringify(certificateIdentity(event)) !== JSON.stringify(active.identity)) active.reasons.push("certificate_identity_mismatch");
            active.events.push(event);
        } else if (active && ["ProofRevoked", "Failure"].includes(event.event)) {
            active.events.push(event);
            if (event.event === "Failure") active.closure = "failed";
        } else if (active && event.event === "Promoted") {
            active.promotion = event;
            active.events.push(event);
            active = null;
        }
    }
    const analyzed = attempts.map(attempt => {
        const publication = attempt.events.find(event => event.event === "OwnedTargetPublished");
        const prepared = attempt.events.find(event => event.event === "OwnedProviderPrepared");
        const eligibility = attempt.events.filter(event => event.event === "OwnedReleaseEligibility").at(-1);
        const revoked = attempt.events.filter(event => event.event === "ProofRevoked").at(-1);
        const drainBegin = events.filter(event => event.event === "RelatchDrainBegin" && attempt.consumed &&
            event.sequence < attempt.consumed.sequence).at(-1);
        const readyCandidates = events.filter(event => event.event === "RelatchDrainReady" && attempt.consumed && drainBegin &&
            event.sequence > drainBegin.sequence && event.sequence < attempt.consumed.sequence &&
            event.generation === attempt.identity.targetGeneration && event.beginFrame === attempt.identity.beginFrame &&
            !events.some(boundary => boundary.event === "RelatchDrainInvalidated" &&
                boundary.sequence > event.sequence && boundary.sequence < attempt.consumed.sequence));
        const readyReasons = [];
        const providerReadiness = [];
        for (const [mask, provider, prefix] of [[1, "FSR", "fsr"], [2, "DLSS", "dlss"]]) {
            if (!(attempt.identity.requiredProviders & mask)) continue;
            const candidates = readyCandidates.filter(event => event.reason === `${prefix}_relatch_drain_ready`);
            const fields = ["sourceGeneration", "targetGeneration", "beginFrame", "requiredProviders",
                "deviceIdentity", "contextIdentity", "queueIdentity", `${prefix}Revision`, `${prefix}TicketSerial`];
            const latest = candidates.at(-1);
            const matching = latest?.ownedRelease && fields.every(key =>
                certificateIdentity(latest)[key] === attempt.identity[key]) ? latest : null;
            if (!matching) readyReasons.push(candidates.length ? `${prefix}_ready_certificate_identity_missing_or_mismatched` : `${prefix}_ready_endpoint_missing`);
            providerReadiness.push({ provider, sequence: matching?.sequence ?? null, event: matching ?? null });
        }
        if (!attempt.consumed) readyReasons.push("consumed_endpoint_not_observed");
        const ready = !readyReasons.length ? providerReadiness.map(provider => provider.event).sort((a, b) => a.sequence - b.sequence).at(-1) : null;
        const reasons = [...attempt.reasons];
        if (!clock.windowComplete) reasons.push("event_window_incomplete");
        const consumptionClaimed = attempt.events.some(event => event.ownedRelease?.oldProofConsumed);
        if (!attempt.consumed && (consumptionClaimed || eligibility?.ownedRelease.eligible)) reasons.push("consumed_endpoint_missing");
        if (attempt.consumed && !attempt.consumed.ownedRelease.oldProofConsumed) reasons.push("consumption_not_confirmed");
        if (attempt.consumed && attempt.events.some(event => event.ownedRelease && !event.ownedRelease.oldProofConsumed)) {
            reasons.push("consumption_claim_regressed");
        }
        if (publication && !publication.ownedRelease.targetPublished) reasons.push("target_publication_not_confirmed");
        if (prepared && !prepared.ownedRelease.providerPrepared) reasons.push("target_preparation_not_confirmed");
        const certificateRevoked = Boolean(revoked && (!eligibility || revoked.sequence > eligibility.sequence));
        const guardExemptionClaimed = eligibility?.ownedRelease.eligible === true &&
            eligibility.ownedRelease.eligibilityScope === "guard_exemption" && !certificateRevoked;
        if (attempt.promotion && !eligibility) reasons.push("promotion_eligibility_endpoint_missing");
        if (attempt.promotion && eligibility?.ownedRelease.eligibilityScope === "presentation" &&
            (!eligibility.ownedRelease.eligible || revoked && revoked.sequence > eligibility.sequence)) {
            reasons.push("promotion_without_current_eligibility");
        }
        if (attempt.promotion && guardExemptionClaimed && (!publication || !prepared)) reasons.push("promotion_stage_endpoint_missing");
        if (publication && prepared && prepared.sequence < publication.sequence) reasons.push("preparation_precedes_publication");
        if (publication && eligibility && eligibility.sequence < publication.sequence) reasons.push("eligibility_precedes_publication");
        const targetSnapshots = attempt.events.filter(event => ["OwnedTargetPublished", "OwnedProviderPrepared", "OwnedReleaseEligibility"].includes(event.event));
        if (targetSnapshots.some(event => targetRevisionFields.some(key =>
            event.ownedRelease[key] !== targetSnapshots[0].ownedRelease[key]))) reasons.push("target_identity_mismatch");
        const identityReasons = attempt.identity.certificateSerial === null ? ["certificate_serial_not_exposed_tuple_correlated"] : [];
        if (attempt.promotion) {
            if (!attempt.promotion.generation) identityReasons.push("promotion_target_generation_not_exposed");
            else if (attempt.promotion.generation !== attempt.identity.targetGeneration) reasons.push("promotion_target_generation_mismatch");
        }
        for (const key of ["deviceIdentity", "contextIdentity",
            ...(attempt.identity.requiredProviders & 1 ? ["fsrRevision", "fsrTicketSerial"] : []),
            ...(attempt.identity.requiredProviders & 2 ? ["dlssRevision", "dlssTicketSerial"] : [])]) {
            if (attempt.identity[key] === null) {
                (consumptionClaimed || eligibility?.ownedRelease.eligible ? reasons : identityReasons).push(`certificate_${key}_not_exposed`);
            }
        }
        const valid = reasons.length === 0;
        const guardExempt = valid && !readyReasons.length && guardExemptionClaimed;
        const interval = (begin, end) => {
            const result = tickInterval(begin?.timestampQpc, end?.timestampQpc, clock.qpcFrequency,
                valid ? null : "certificate_evidence_invalid");
            return { ...result, beginSequence: begin?.sequence ?? null, endSequence: end?.sequence ?? null,
                beginFrame: begin?.frame ?? null, endFrame: end?.frame ?? null,
                frames: result.status === "complete" && end.frame >= begin.frame ? end.frame - begin.frame : null };
        };
        return { status: !valid ? "incomplete" : certificateRevoked ? "revoked" : !consumptionClaimed ? "not_consumed" : eligibility?.ownedRelease.eligible === false ? "denied" :
            readyReasons.length ? "unproven" : attempt.promotion ? "complete" : "observed", reasons: [...new Set(reasons)], identity: attempt.identity,
            identityReasons, closure: attempt.closure ?? null,
            eligibilityScope: eligibility?.ownedRelease.eligibilityScope ?? null,
            guardExempt, guardExemptionClaimed, certificateRevoked, providerReadiness,
            readinessStatus: readyReasons.length ? "not_available" : "complete", readinessReasons: readyReasons,
            unavailableFields: [!publication && "target_publication_not_observed", !prepared && "provider_preparation_not_observed",
                !eligibility && "release_eligibility_not_observed", !attempt.promotion && "promotion_not_observed"].filter(Boolean),
            consumedSequence: attempt.consumed?.sequence ?? null, publicationSequence: publication?.sequence ?? null,
            preparedSequence: prepared?.sequence ?? null, eligibilitySequence: eligibility?.sequence ?? null,
            promotionSequence: attempt.promotion?.sequence ?? null,
            promotionCorrelation: attempt.promotion ? certificateRevoked ? "request_epoch_after_revoked_certificate" :
                "request_epoch_and_open_certificate_sequence" : null,
            events: attempt.events,
            intervals: { readyToConsumed: readyReasons.length ?
                    { ...tickInterval(null, attempt.consumed?.timestampQpc, clock.qpcFrequency, readyReasons[0]), reasons: readyReasons } : interval(ready, attempt.consumed),
                consumedToTargetPublished: interval(attempt.consumed, publication),
                targetPublishedToProviderPrepared: interval(publication, prepared),
                targetPublishedToEligibility: interval(publication, eligibility),
                eligibilityToProviderPrepared: eligibility?.ownedRelease.eligibilityScope === "presentation" ?
                    tickInterval(null, null, clock.qpcFrequency, "presentation_eligibility_follows_provider_preparation") : interval(eligibility, prepared),
                providerPreparedToPromotion: interval(prepared, attempt.promotion),
                eligibilityToPromotion: interval(eligibility, attempt.promotion),
                consumedToBlockingCleanupReady: tickInterval(attempt.consumed?.timestampQpc,
                    eligibility?.ownedRelease.blockingCleanupReadyQpc, clock.qpcFrequency,
                    valid ? null : "certificate_evidence_invalid") } };
    });
    const reasons = [...new Set(analyzed.flatMap(attempt => attempt.reasons))];
    if (stages.some(event => !validOwnedReleasePayload(event))) reasons.push("invalid_stage_payload");
    return { schemaVersion: 1, status: !stages.length ? "not_exposed" : reasons.length ? "incomplete" : "complete",
        reasons, unavailableFields: stages.length ? [] : ["owned_release_stage_events_not_exposed"],
        requestObservation: request, requestToAdmission, fences: [...fences.values()], attempts: analyzed };
}

function ownedReleaseReport(transitions) {
    const rows = [], fences = [];
    const ms = value => Number.isFinite(value?.milliseconds) ? value.milliseconds.toFixed(2) : "n.d.";
    for (const row of transitions) {
        const release = row.retryTelemetry?.ownedRelease;
        if (!release || release.status === "not_exposed") continue;
        const label = `${row.lane || "default"} | ${row.pass} | ${row.ordinal}`;
        for (const attempt of release.attempts || []) {
            const spans = attempt.intervals;
            const gaps = [...attempt.reasons, ...attempt.readinessReasons, ...attempt.unavailableFields];
            rows.push(`| ${label} | ${attempt.status} | ${attempt.guardExempt} | ${ms(release.requestToAdmission)} | ` +
                `${ms(spans.readyToConsumed)} | ${ms(spans.consumedToTargetPublished)} | ` +
                `${ms(spans.targetPublishedToProviderPrepared)} | ${ms(spans.providerPreparedToPromotion)} | ${gaps.join("; ") || "none"} |`);
        }
        for (const fence of release.fences || []) fences.push(`| ${label} | ${fence.observation.role} | ` +
            `${ms(fence.issueToObservedReady)} | ${fence.issueToObservedReady.reasons.join("; ") || "none"} |`);
    }
    if (!rows.length && !fences.length) return "";
    return "## Owned release stages\n\n" +
        "Guard exemption does not enable vendor dispatch. Provider preparation and coherent stereo still gate promotion. " +
        "Denied, revoked and unproven receipts do not establish proof-driven release. " +
        "Intervals use producer CPU observations; fence readiness is not the exact GPU completion time. " +
        "Displayed milliseconds are rounded to two decimals; exact QPC, frame endpoints and full precision remain in summary.json and transitions.csv.\n\n" +
        "| Lane | Pass | Row | Certificate | Guard exempt | Request to admission ms | All ready to consumed ms | Consumed to published ms | Published to provider prepared ms | Provider prepared to promoted ms | Gaps |\n" +
        "| --- | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |\n" + rows.join("\n") + "\n\n" +
        "| Lane | Pass | Row | Fence | Issue to observed ready ms | Gaps |\n" +
        "| --- | ---: | ---: | --- | ---: | --- |\n" + fences.join("\n") + "\n\n";
}

module.exports = { ownedReleaseEvents, validOwnedReleasePayload, validFenceObservations, ownedReleaseTelemetry, ownedReleaseReport };
