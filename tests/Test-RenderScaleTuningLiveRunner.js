// SPDX-License-Identifier: GPL-3.0-or-later

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const repositoryRoot = path.resolve(__dirname, "..");
const runnerSource = fs.readFileSync(
    path.join(repositoryRoot, "tools", "renderscale-tuning-live", "runner.js"), "utf8");
const runRenderScaleTuningLive = new Function(
    `${runnerSource}\nreturn runRenderScaleTuningLive;`)();
const buildId = "a".repeat(64);

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

function envelope(value) {
    return { content: [{ type: "text", text: JSON.stringify(value) }] };
}

function named(name, value = 0) {
    return { name, value };
}

function publicProfile(method = "dlss", qualityMode = "native_aa", renderScaleMode = false) {
    return {
        method: named(method),
        qualityMode: named(qualityMode),
        renderScaleMode,
        dlssProfile: named("K"),
        fsrRuntime: named("fsr3"),
    };
}

function initialBoundary() {
    const profile = publicProfile();
    return {
        revision: 1,
        profile: {
            method: profile.method.name,
            qualityMode: profile.qualityMode.name,
            renderScaleMode: profile.renderScaleMode,
            dlssProfile: profile.dlssProfile.name,
            fsrRuntime: profile.fsrRuntime.name,
        },
    };
}

function flatProfile(target) {
    return {
        method: target.method,
        qualityMode: {
            native_aa: 0,
            hoshipa: 1,
            ultra_quality: 2,
            quality: 3,
            balanced: 4,
            performance: 5,
            ultra_performance: 6,
        }[target.qualityMode],
        renderScaleMode: target.renderScaleMode,
        dlssProfile: target.dlssProfile,
        fsrRuntime: target.fsrRuntime,
    };
}

function createMock(semanticFailureOrdinal) {
    let revision = 1;
    let stressSession = 0;
    let stressActive = false;
    let cpuActive = false;
    let gpuActive = false;
    let textureActive = false;
    let probeActive = false;
    let transitionOrdinal = 0;
    let traceSession = 0;
    let traceActive = false;
    let traceRecords = [];
    const scenarioCalls = [];
    const stores = new Map();
    const notifications = [];

    function traceSummary() {
        return {
            active: traceActive,
            sessionID: traceSession,
            totalRecords: traceRecords.length,
            setConstantsCalls: traceRecords.length > 0 ? 1 : 0,
            evaluateCalls: traceRecords.length > 0 ? 1 : 0,
        };
    }

    function toolResult(step) {
        const args = step.args || {};
        if (step.label === "baseline-stress-start" || step.label === "measured-stress-start") {
            stressSession += 1;
            stressActive = true;
            return { status: { session: { id: stressSession, active: true } } };
        }
        if (args.action === "stop") {
            stressActive = false;
            return { status: { session: { id: stressSession, active: false } } };
        }
        if (args.action === "texture_lifetime_start") textureActive = true;
        if (args.action === "texture_lifetime_stop") textureActive = false;
        if (args.action === "probe_start") probeActive = true;
        if (args.action === "probe_stop") probeActive = false;
        if (args.action === "cpu_performance_stop") cpuActive = false;
        if (args.action === "gpu_performance_stop") gpuActive = false;
        if (args.action === "dlss_trace_status") {
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_reset") {
            traceSession += 1;
            traceActive = false;
            traceRecords = [];
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_start") {
            traceActive = true;
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_stop") {
            traceActive = false;
            return { action: args.action, capture: traceSummary() };
        }
        if (args.action === "dlss_trace_read") {
            return {
                action: args.action,
                capture: {
                    summary: traceSummary(),
                    records: traceRecords,
                    afterSequence: args.afterSequence,
                    limit: args.limit,
                },
            };
        }
        if (args.action === "status") {
            return {
                status: {
                    session: { id: stressSession, active: stressActive },
                    loadPresentationProbe: { active: probeActive },
                },
            };
        }
        if (args.action === "cpu_performance_status") {
            return { cpuPerformance: { active: cpuActive, sessionId: cpuActive ? 11 : 0 } };
        }
        if (args.action === "gpu_performance_status") return { capture: { active: gpuActive } };
        if (args.action === "texture_lifetime_status") return { capture: { active: textureActive } };
        if (step.label === "profile-apply") return { apply: { disposition: { name: "queued" } } };
        return {};
    }

    async function scenario(args) {
        scenarioCalls.push(args);
        const applyStep = args.steps.find((step) => step.label === "profile-apply");
        const waitStep = args.steps.find((step) => step.label === "qualification-wait");
        const firstMeasured = args.steps.some((step) =>
            step.label === "qualification-dispatch" && step.args.startPerformanceTelemetry === true);
        if (firstMeasured) {
            cpuActive = true;
            gpuActive = true;
        }
        if (applyStep && !args.steps.some((step) => step.label === "baseline-stress-start")) {
            transitionOrdinal += 1;
        }
        const results = args.steps.map((step) => {
            if (step.wait !== undefined) return { kind: "wait", ms: step.wait };
            if (step.label !== "qualification-wait") {
                return { label: step.label, result: toolResult(step) };
            }
            revision += 1;
            const target = applyStep.args.target;
            const profile = flatProfile(target);
            const semanticFailure = semanticFailureOrdinal > 0 &&
                ((transitionOrdinal - 1) % 33) + 1 === semanticFailureOrdinal;
            if (traceActive && target.method === "dlss") {
                traceRecords = [
                    { sequence: 1, eye: "left", qualityMode: profile.qualityMode },
                    { sequence: 2, eye: "right", qualityMode: profile.qualityMode },
                ];
            }
            return {
                label: step.label,
                result: {
                    action: "qualification_wait",
                    transitionId: waitStep.args.transitionId,
                    ownerId: waitStep.args.ownerId,
                    satisfied: !semanticFailure,
                    outcome: semanticFailure ? "timeout" : "stable",
                    timing: { elapsedMs: 1, dispatchTick: 10, stableTick: 11 },
                    frames: { dispatch: 10, stable: 11 },
                    milestoneTimings: { presentationElapsedMs: 1, cleanupElapsedMs: 1 },
                    replacementTimeline: {
                        firstPhysicalMutation: {
                            selectedPresentationDisposition: "PresentationStretch",
                        },
                    },
                    presentationStable: true,
                    cleanupDrained: true,
                    outstandingCleanupDebt: {
                        engineTargetRetirement: { pending: false, pendingReleaseCount: 0 },
                        intermediateRetirement: { pendingSets: 0 },
                    },
                    baseline: { stressSessionId: stressSession },
                    upscalingSnapshot: {
                        stateRevision: revision,
                        activeOperationId: 0,
                        requested: profile,
                        effective: profile,
                        stable: profile,
                    },
                    observation: {
                        facts: {
                            stressSession: true,
                            exactCell: true,
                            loadedInWorld: true,
                            apiOperationClear: true,
                            physicalMutationClear: true,
                            terminalClear: true,
                        },
                    },
                },
            };
        });
        return envelope({
            ok: true,
            aborted: false,
            stepsRun: args.steps.length,
            results,
        });
    }

    return {
        context: {
            tools: {
                mcp__devbench_vr__scenario: scenario,
                mcp__devbench_vr__communityshaders_renderscale: async () =>
                    envelope({ qualification: { active: false, lastEvidence: null } }),
            },
            store: (key, value) => stores.set(key, value),
            notify: (value) => notifications.push(value),
        },
        scenarioCalls,
        stores,
        notifications,
    };
}

async function testNvidia() {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-nvidia", "references", "matrix.v1.json")));
    const mock = createMock(3);
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "nvidia",
        runId: "nvidia-test",
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {},
        matrix,
    });
    assert(result.ok === true && result.status === "COMPLETE", "NVIDIA mock run did not complete.");
    assert(result.lanes[0].passes.length === 2, "NVIDIA mock did not run two passes.");
    assert(result.lanes[0].passes.every((pass) => pass.rows.length === 33), "NVIDIA mock row count is wrong.");
    assert(mock.notifications.length === 66, "NVIDIA progress count is wrong.");
    assert(mock.notifications.filter((row) => row.satisfied === false).length === 2,
        "NVIDIA semantic failures did not continue through both passes.");
    assert(mock.notifications.every((row) => row.cleanupDrained === true),
        "Structured cleanup debt was not projected from cleanupDrained.");
    assert(mock.notifications.filter((row) => row.satisfied === true).every((row) =>
        row.presentationStretchTerminalRecovery === true),
        "Recovered stretch was misclassified from structured cleanup debt.");
    assert(mock.notifications.filter((row) => row.satisfied === false).every((row) =>
        row.presentationStretchTerminalRecovery === false),
        "Failed stretch was incorrectly projected as recovered.");
    assert(mock.stores.has("nvidia-test:nvidia:pass-2:transition-33"),
        "NVIDIA terminal receipt was not retained.");
    const expectedTraceRows = matrix.transitions.filter((row) =>
        matrix.destinations[row.destination].method === "dlss").length * 2;
    const retainedTraceRows = [...mock.stores.entries()].filter(([key, value]) =>
        key.includes(":transition-") && value.traceRead);
    assert(retainedTraceRows.length === expectedTraceRows,
        "NVIDIA per-row trace evidence count is wrong.");
    const tracedScenarios = mock.scenarioCalls.filter((call) =>
        call.steps.some((step) => step.label === "dlss-trace-read"));
    assert(tracedScenarios.length === expectedTraceRows,
        "NVIDIA bounded trace reads were not executed per DLSS row.");
    for (const call of tracedScenarios) {
        const tail = call.steps.slice(-2);
        assert(tail[0].label === "dlss-trace-stop" &&
            tail[1].label === "dlss-trace-read" &&
            tail[1].args.limit === matrix.traceReadLimit,
        "NVIDIA trace stop/read ordering or bound is wrong.");
    }
    for (const [, retained] of retainedTraceRows) {
        assert(retained.traceReset.action === "dlss_trace_reset",
            "NVIDIA trace reset receipt was not retained.");
        assert(retained.traceStart.action === "dlss_trace_start",
            "NVIDIA trace start receipt was not retained.");
        assert(retained.traceStop.action === "dlss_trace_stop",
            "NVIDIA trace stop receipt was not retained.");
        assert(retained.traceRead.action === "dlss_trace_read" &&
            retained.traceRead.capture.records.length === 2,
            "NVIDIA raw trace window was not retained.");
    }
}

async function testAmd() {
    const matrix = JSON.parse(fs.readFileSync(path.join(
        repositoryRoot, "skills", "renderscale-tuning-amd", "references", "matrix.v1.json")));
    const mock = createMock(0);
    const result = await runRenderScaleTuningLive({
        ...mock.context,
        variant: "amd",
        runId: "amd-test",
        buildId,
        initialBoundary: initialBoundary(),
        capabilities: {
            supportedFSRRuntimeMask: 1,
            fsrRuntimeUnavailableConditions: [{ mask: 0 }, { mask: 1 }],
        },
        matrix,
    });
    assert(result.ok === true && result.status === "COMPLETE", "AMD mock run did not complete.");
    const fsr3 = result.lanes.find((lane) => lane.id === "explicit_fsr3");
    const fallback = result.lanes.find((lane) => lane.id === "fsr4_to_fsr3_fallback");
    assert(fsr3 && fsr3.passes.length === 2, "AMD FSR3 lane did not run two passes.");
    assert(fallback && fallback.passes.length === 2, "AMD fallback lane did not run two passes.");
    assert(fsr3.passes.every((pass) => pass.rows.length === 31), "AMD mock row count is wrong.");
    assert(fallback.passes.every((pass) => pass.rows.length === 31), "AMD fallback row count is wrong.");
    assert(mock.notifications.length === 124, "AMD progress count is wrong.");
    const capabilityEnvelope = mock.stores.get("amd-test:amd:dlss-trace-capability");
    assert(capabilityEnvelope, "AMD DLSS trace capability lifecycle was not retained.");
    const capability = JSON.parse(capabilityEnvelope.content[0].text);
    const capabilityResults = new Map(capability.results.map((entry) =>
        [entry.label, entry.result]));
    assert(capabilityResults.get("amd-dlss-trace-reset").action === "dlss_trace_reset",
        "AMD trace reset receipt was not retained.");
    assert(capabilityResults.get("amd-dlss-trace-start").action === "dlss_trace_start",
        "AMD trace start receipt was not retained.");
    assert(capabilityResults.get("amd-dlss-trace-stop").action === "dlss_trace_stop",
        "AMD trace stop receipt was not retained.");
    const capabilityRead = capabilityResults.get("amd-dlss-trace-read");
    assert(capabilityRead.action === "dlss_trace_read" &&
        capabilityRead.capture.records.length === 0 &&
        capabilityRead.capture.limit === matrix.traceReadLimit,
        "AMD capability trace raw window is not empty.");
    const amdTransitionTrace = mock.scenarioCalls.some((call) =>
        call.steps.some((step) => step.label === "dlss-trace-start"));
    assert(amdTransitionTrace === false, "AMD matrix started a per-row DLSS trace.");
}

Promise.all([testNvidia(), testAmd()]).then(() => {
    process.stdout.write("Render-scale tuning live runner tests passed.\n");
}).catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
});
