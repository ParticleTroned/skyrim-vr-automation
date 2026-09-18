// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const ownedDrainEvents = new Set(["RelatchDrainBegin", "RelatchDrainPending", "RelatchDrainReady",
    "RelatchDrainInvalidated", "RelatchCommitBegin", "RelatchSharedCleanup"]);
const providerReasons = new Map([["fsr_relatch_drain_ready", "FSR"], ["dlss_relatch_drain_ready", "DLSS"]]);

function observedInterval(begin, end, clock, unavailableReason) {
    const reasons = [];
    if (unavailableReason) reasons.push(unavailableReason);
    else if (!begin || !end) reasons.push(!begin ? "begin_endpoint_missing" : "end_endpoint_missing");
    else if (!clock.windowComplete) reasons.push("event_window_incomplete");
    else if (end.sequence <= begin.sequence || end.timestampQpc < begin.timestampQpc || end.frame < begin.frame) {
        reasons.push("invalid_interval_order");
    }
    const valid = reasons.length === 0;
    return { status: valid ? "complete" : unavailableReason ? "not_available" : "incomplete", reasons,
        beginSequence: begin?.sequence ?? null, endSequence: end?.sequence ?? null,
        beginQpc: begin?.timestampQpc ?? null, endQpc: end?.timestampQpc ?? null,
        beginFrame: begin?.frame ?? null, endFrame: end?.frame ?? null,
        frames: valid ? end.frame - begin.frame : null,
        milliseconds: valid ? (end.timestampQpc - begin.timestampQpc) * 1000 / clock.qpcFrequency : null };
}

function ownedDrainTelemetry(events, clock) {
    const attempts = [];
    let active = null;
    const start = begin => {
        const attempt = { begin, events: [], uncorrelatedEvents: [], reasons: [], closure: null };
        attempts.push(attempt);
        return attempt;
    };
    for (const event of events) {
        if (event.event === "RelatchDrainBegin") {
            if (active) active.reasons.push("closure_missing_before_next_begin");
            active = start(event);
        }
        if (ownedDrainEvents.has(event.event)) {
            if (!active) active = start(null);
            const begin = active.begin;
            if (begin && (event.generation !== begin.generation || event.beginFrame !== begin.beginFrame)) {
                active.reasons.push("drain_identity_mismatch");
                active.uncorrelatedEvents.push(event);
                continue;
            }
            active.events.push(event);
            if (event.event === "RelatchDrainInvalidated") {
                active.closure = event;
                active = null;
            }
        } else if (event.event === "Applied" && active) {
            active.events.push(event);
            active.closure = event;
            active = null;
        }
    }
    const analyzed = attempts.map(attempt => analyzeAttempt(attempt, clock));
    const reasons = [...new Set(analyzed.flatMap(attempt => attempt.reasons))];
    return { schemaVersion: 1, status: !analyzed.length ? "not_observed" : reasons.length ? "incomplete" : "complete",
        reasons, attempts: analyzed };
}

function analyzeAttempt(attempt, clock) {
    const { begin, events, closure } = attempt;
    const reasons = [...attempt.reasons];
    if (!begin) reasons.push("drain_begin_missing");
    if (!closure) reasons.push("drain_closure_missing");
    if (!clock.windowComplete) reasons.push("event_window_incomplete");
    const owned = events.filter(event => ownedDrainEvents.has(event.event));
    let previousPolls = -1;
    const readyByProvider = new Map();
    for (const event of owned) {
        if (event.pendingObservations < previousPolls) reasons.push("poll_observations_regressed");
        previousPolls = event.pendingObservations;
        if (event.event === "RelatchDrainReady") {
            const provider = providerReasons.get(event.reason);
            if (!provider) reasons.push("ready_provider_identity_unknown");
            else {
                const previous = readyByProvider.get(provider);
                if (previous && event.pendingObservations <= previous.pendingObservations) {
                    reasons.push("duplicate_provider_ready_without_new_poll");
                }
                readyByProvider.set(provider, event);
            }
        }
    }
    const pending = events.find(event => event.event === "RelatchDrainPending");
    const commits = events.filter(event => event.event === "RelatchCommitBegin");
    const cleanups = events.filter(event => event.event === "RelatchSharedCleanup");
    const invalidated = closure?.event === "RelatchDrainInvalidated";
    if (cleanups.length > 1) reasons.push("duplicate_shared_cleanup");
    if (cleanups.some(cleanup => !commits.some(commit => commit.sequence < cleanup.sequence))) {
        reasons.push("cleanup_commit_begin_missing");
    }
    if (!invalidated && !commits.length) reasons.push("commit_begin_missing");
    if (!invalidated && closure?.event !== "Applied") reasons.push("applied_endpoint_missing");
    for (const commit of commits) {
        if (!events.some(event => event.event === "RelatchDrainReady" && event.sequence < commit.sequence)) {
            reasons.push("ready_endpoint_missing");
        }
    }
    // Closure gaps do not erase intervals whose own endpoints and ownership are retained.
    const invalid = reasons.some(reason => ["drain_begin_missing", "drain_identity_mismatch",
        "event_window_incomplete", "poll_observations_regressed", "ready_provider_identity_unknown",
        "duplicate_provider_ready_without_new_poll", "duplicate_shared_cleanup",
        "cleanup_commit_begin_missing"].includes(reason));
    const intervalClock = { ...clock, windowComplete: clock.windowComplete && !invalid };
    const commitResults = commits.map((commit, index) => {
        const next = commits[index + 1];
        const ready = events.filter(event => event.event === "RelatchDrainReady" &&
            event.sequence < commit.sequence).at(-1);
        const cleanup = cleanups.find(event => event.sequence > commit.sequence && (!next || event.sequence < next.sequence));
        const applied = closure?.event === "Applied" && closure.sequence > commit.sequence && !next ? closure : null;
        return { sequence: commit.sequence, timestampQpc: commit.timestampQpc, frame: commit.frame,
            pollObservations: commit.pendingObservations,
            status: next ? "retried" : applied ? "applied" : invalidated ? "invalidated" : "unresolved",
            intervals: {
                readyToCommit: observedInterval(ready, commit, intervalClock),
                commitToSharedCleanup: observedInterval(commit, cleanup, intervalClock,
                    !cleanup ? "shared_cleanup_not_observed_for_commit" : null),
                commitToApplied: observedInterval(commit, applied, intervalClock, next ? "commit_retried" : null)
            } };
    });
    const firstCommit = commits[0];
    const finalReady = events.filter(event => event.event === "RelatchDrainReady" &&
        (!firstCommit || event.sequence < firstCommit.sequence)).at(-1);
    const emptyCommit = { readyToCommit: observedInterval(finalReady, null, intervalClock),
        commitToSharedCleanup: observedInterval(null, null, intervalClock),
        commitToApplied: observedInterval(null, null, intervalClock) };
    const intervals = {
        beginToFirstPending: observedInterval(begin, pending, intervalClock, !pending ? "pending_not_observed" : null),
        pendingToReady: observedInterval(pending, finalReady, intervalClock,
            invalidated ? "drain_invalidated" : !pending ? "pending_not_observed" : null),
        ...(commitResults[0]?.intervals || emptyCommit)
    };
    for (const interval of [intervals.beginToFirstPending, intervals.pendingToReady,
        ...commitResults.flatMap(commit => Object.values(commit.intervals))]) {
        if (interval.reasons.includes("invalid_interval_order")) reasons.push("invalid_interval_order");
    }
    const identityEvent = begin || events[0];
    const identityReasons = ["source_generation_not_exposed", "device_identity_not_exposed",
        "required_provider_set_not_exposed", "provider_resource_revisions_not_exposed"];
    if (closure?.event === "Applied") identityReasons.push("applied_target_generation_not_exposed");
    return { beginSequence: begin?.sequence ?? null,
        status: reasons.length ? "incomplete" : invalidated ? "invalidated" : "complete",
        reasons: [...new Set(reasons)],
        identity: { sessionId: identityEvent?.sessionId ?? null, requestId: identityEvent?.requestId ?? null,
            transitionEpoch: identityEvent?.transitionEpoch ?? null, targetGeneration: begin?.generation ?? null,
            beginFrame: begin?.beginFrame ?? null, beginSequence: begin?.sequence ?? null,
            sourceGeneration: null, deviceIdentity: null, requiredProviders: null, providerResourceRevisions: null },
        identityReasons, appliedCorrelation: closure?.event === "Applied" ? "owner_and_open_attempt_sequence" : null,
        closureSequence: closure?.sequence ?? null, closureReason: closure?.reason ?? null,
        observedProviders: [...readyByProvider.keys()],
        pollObservations: owned.length ? owned.at(-1).pendingObservations : null,
        events, uncorrelatedEvents: attempt.uncorrelatedEvents, commits: commitResults, intervals };
}

module.exports = { ownedDrainEvents, observedInterval, ownedDrainTelemetry };
