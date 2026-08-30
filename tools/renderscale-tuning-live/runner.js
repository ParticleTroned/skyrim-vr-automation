// SPDX-License-Identifier: GPL-3.0-or-later

async function runRenderScaleTuningLive(context) {
    "use strict";

    const {
        tools, store, notify, variant, runId, buildId,
        initialBoundary, capabilities, matrix,
    } = context;
    const scenarioTool = tools.mcp__devbench_vr__scenario;
    const renderScaleTool = tools.mcp__devbench_vr__communityshaders_renderscale;
    if (typeof scenarioTool !== "function" || typeof renderScaleTool !== "function") {
        throw new Error("plugin_direct_unavailable");
    }

    const quality = Object.freeze({
        native_aa: 0,
        hoshipa: 1,
        ultra_quality: 2,
        quality: 3,
        balanced: 4,
        performance: 5,
        ultra_performance: 6,
    });
    const qualityName = Object.freeze(Object.fromEntries(
        Object.entries(quality).map(([name, value]) => [value, name])));
    const foveation = Object.freeze({
        foveatedVendorDispatch: true,
        foveatedCenterArea: 0.3,
        peripheryTAAEnable: true,
        peripheryTAACenterArea: 0.3,
        peripheryTAAOuterScale: 0.7,
    });

    function decodeEnvelope(envelope) {
        const block = envelope && envelope.content && envelope.content[0];
        if (!block || block.type !== "text" || typeof block.text !== "string") {
            throw new Error("invalid_mcp_envelope");
        }
        return JSON.parse(block.text);
    }

    function resultMap(root) {
        return new Map((root.results || [])
            .filter((entry) => entry && typeof entry.label === "string")
            .map((entry) => [entry.label, entry.result]));
    }

    function requireScenario(root, stepCount) {
        if (!root || root.ok !== true || root.aborted !== false ||
            root.stepsRun !== stepCount || !Array.isArray(root.results)) {
            throw new Error("scenario_failed");
        }
        return resultMap(root);
    }

    // A terminal qualification receipt uses the flat qualification snapshot.
    function terminalBoundary(waiter) {
        const snapshot = waiter.upscalingSnapshot;
        const profile = snapshot.effective;
        return {
            revision: snapshot.stateRevision,
            profile: {
                method: profile.method,
                qualityMode: qualityName[profile.qualityMode],
                renderScaleMode: profile.renderScaleMode,
                dlssProfile: profile.dlssProfile,
                fsrRuntime: profile.fsrRuntime,
            },
        };
    }

    function targetFor(boundary, destination, fsrRuntime) {
        return {
            method: destination.method,
            qualityMode: destination.qualityMode,
            renderScaleMode: destination.renderScaleMode,
            dlssProfile: boundary.profile.dlssProfile,
            fsrRuntime: fsrRuntime || destination.fsrRuntime || boundary.profile.fsrRuntime,
        };
    }

    function waiterTarget(target) {
        const result = {
            method: target.method,
            qualityMode: quality[target.qualityMode],
            renderScaleMode: target.renderScaleMode,
        };
        if (target.method === "dlss") result.dlssProfile = target.dlssProfile;
        if (target.method === "fsr") result.fsrRuntime = target.fsrRuntime;
        return result;
    }

    function toolStep(label, tool, args) {
        return { label, tool, args };
    }

    async function scenario(steps) {
        const envelope = await scenarioTool({
            action: "run",
            async: false,
            continueOnError: false,
            steps,
        });
        return { envelope, root: decodeEnvelope(envelope) };
    }

    async function renderScale(args) {
        const envelope = await renderScaleTool(args);
        return { envelope, root: decodeEnvelope(envelope) };
    }

    function ids(laneIndex, pass, ordinal, baseline) {
        const serial = laneIndex * 100 + pass * 40 + ordinal;
        const stem = `${runId}-${variant}-${laneIndex}-${pass}-${baseline ? "b" : ordinal}`;
        return {
            transitionId: (baseline ? 900000 : 100000) + serial,
            ownerId: `${stem}-owner`,
            clientId: `${stem}-client`,
            commandId: `${stem}-apply`,
            profilerClientId: `${stem}-profiler-client`,
            profilerCommandId: `${stem}-profiler-clear`,
        };
    }

    function qualificationSteps(boundary, target, identifiers, baseline, firstRow) {
        const steps = [];
        if (baseline) {
            steps.push(toolStep("baseline-stress-reset", "communityshaders.renderscale", {
                action: "reset", expectedBuildId: buildId,
            }));
            steps.push(toolStep("baseline-stress-start", "communityshaders.renderscale", {
                action: "start", expectedBuildId: buildId,
            }));
        } else {
            steps.push({ label: "transition-pace", wait: matrix.pacingMilliseconds });
            if (variant === "nvidia" && target.method === "dlss") {
                steps.push(toolStep("dlss-trace-reset", "communityshaders.renderscale", {
                    action: "dlss_trace_reset", expectedBuildId: buildId,
                }));
                steps.push(toolStep("dlss-trace-start", "communityshaders.renderscale", {
                    action: "dlss_trace_start", expectedBuildId: buildId,
                }));
            }
        }
        steps.push(toolStep("qualification-begin", "communityshaders.renderscale", {
            action: "qualification_begin",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            expectedBuildId: buildId,
        }));
        if (firstRow) {
            steps.push(toolStep("profiler-clear-history", "communityshaders.profiler_api", {
                contractMajor: 1,
                clientId: identifiers.profilerClientId,
                commandId: identifiers.profilerCommandId,
                action: "clear_history",
                expectedBuildId: buildId,
            }));
        }
        steps.push(toolStep("qualification-dispatch", "communityshaders.renderscale", {
            action: "qualification_dispatch",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            startPerformanceTelemetry: firstRow,
            expectedBuildId: buildId,
        }));
        steps.push(toolStep("profile-apply", "communityshaders.upscaling_api", {
            action: "apply",
            expectedBuildId: buildId,
            expectedStateRevision: boundary.revision,
            target,
            purpose: "direct",
            persistence: "runtime_only",
            clientId: identifiers.clientId,
            commandId: identifiers.commandId,
            reason: baseline ? "render-scale tuning baseline" : "render-scale tuning transition",
        }));
        steps.push(toolStep("qualification-wait", "communityshaders.renderscale", {
            action: "qualification_wait",
            transitionId: identifiers.transitionId,
            ownerId: identifiers.ownerId,
            expectedCellEditorId: "WhiterunDragonsreach",
            timeoutMs: matrix.completionTimeoutMilliseconds,
            milestone: "strict",
            target: waiterTarget(target),
            foveation,
            expectedBuildId: buildId,
        }));
        if (!baseline && variant === "nvidia" && target.method === "dlss") {
            steps.push(toolStep("dlss-trace-stop", "communityshaders.renderscale", {
                action: "dlss_trace_stop", expectedBuildId: buildId,
            }));
        }
        return steps;
    }

    function safeTerminal(waiter, identifiers) {
        const facts = waiter && waiter.observation && waiter.observation.facts;
        return waiter && waiter.action === "qualification_wait" &&
            waiter.transitionId === identifiers.transitionId &&
            waiter.ownerId === identifiers.ownerId &&
            waiter.upscalingSnapshot && waiter.upscalingSnapshot.activeOperationId === 0 &&
            facts && facts.stressSession === true && facts.exactCell === true &&
            facts.loadedInWorld === true && facts.apiOperationClear === true &&
            facts.physicalMutationClear === true && facts.terminalClear === true;
    }

    async function recoverTerminal(identifiers) {
        const status = await renderScale({
            action: "qualification_status",
            expectedBuildId: buildId,
        });
        store(`${runId}:recovery:${identifiers.transitionId}`, status.envelope);
        const qualification = status.root.qualification;
        const waiter = qualification && qualification.lastEvidence;
        if (qualification && qualification.active === false && waiter &&
            waiter.transitionId === identifiers.transitionId &&
            waiter.ownerId === identifiers.ownerId) {
            return waiter;
        }
        throw new Error("terminal_receipt_unavailable");
    }

    async function closeOpenQualification(identifiers) {
        const status = await renderScale({
            action: "qualification_status",
            expectedBuildId: buildId,
        });
        const qualification = status.root.qualification;
        if (qualification && qualification.active === true &&
            qualification.transitionId === identifiers.transitionId &&
            qualification.ownerId === identifiers.ownerId) {
            await renderScale({
                action: "qualification_cancel",
                transitionId: identifiers.transitionId,
                ownerId: identifiers.ownerId,
                expectedBuildId: buildId,
            });
        }
    }

    async function baseline(boundary, lane, laneIndex, pass) {
        const target = targetFor(
            boundary, matrix.destinations[matrix.initialDestination], lane.configuredFsrRuntime);
        const identifiers = ids(laneIndex, pass, 0, true);
        const steps = qualificationSteps(boundary, target, identifiers, true, false);
        let response;
        try {
            response = await scenario(steps);
        } catch {
            const waiter = await recoverTerminal(identifiers);
            const stressSessionId = waiter.baseline && waiter.baseline.stressSessionId;
            if (!safeTerminal(waiter, identifiers) || waiter.satisfied !== true ||
                !waiter.milestoneTimings || !waiter.replacementTimeline) {
                throw new Error("baseline_failed");
            }
            return { boundary: terminalBoundary(waiter), stressSessionId, waiter };
        }
        const entries = resultMap(response.root);
        const start = entries.get("baseline-stress-start");
        const stressSessionId = start && start.status && start.status.session.id;
        const waiter = entries.get("qualification-wait");
        store(`${runId}:${lane.id}:pass-${pass}:baseline`, response.envelope);
        if (!response.root.ok || !waiter || !safeTerminal(waiter, identifiers) ||
            waiter.satisfied !== true || !waiter.milestoneTimings ||
            !waiter.replacementTimeline) {
            await closeOpenQualification(identifiers);
            if (stressSessionId) {
                await renderScale({
                    action: "stop", expectedSessionId: stressSessionId,
                    expectedBuildId: buildId,
                });
            }
            throw new Error("baseline_failed");
        }
        return { boundary: terminalBoundary(waiter), stressSessionId, waiter };
    }

    async function armOwners(baselineResult, lane, laneIndex, pass, resetPerformance) {
        const stem = `${runId}-${variant}-${laneIndex}-${pass}`;
        const steps = [
            toolStep("baseline-stress-stop", "communityshaders.renderscale", {
                action: "stop", expectedSessionId: baselineResult.stressSessionId,
                expectedBuildId: buildId,
            }),
            toolStep("measured-stress-start", "communityshaders.renderscale", {
                action: "start", expectedBuildId: buildId,
            }),
            toolStep("texture-lifetime-reset", "communityshaders.renderscale", {
                action: "texture_lifetime_reset", expectedBuildId: buildId,
            }),
            toolStep("texture-lifetime-start", "communityshaders.renderscale", {
                action: "texture_lifetime_start", expectedBuildId: buildId,
            }),
            toolStep("load-presentation-reset", "communityshaders.renderscale", {
                action: "probe_reset", expectedBuildId: buildId,
            }),
            toolStep("load-presentation-start", "communityshaders.renderscale", {
                action: "probe_start", expectedBuildId: buildId,
            }),
        ];
        if (resetPerformance) {
            steps.push(toolStep("cpu-performance-reset", "communityshaders.renderscale", {
                action: "cpu_performance_reset", expectedBuildId: buildId,
            }));
            steps.push(toolStep("gpu-performance-reset", "communityshaders.renderscale", {
                action: "gpu_performance_reset", expectedBuildId: buildId,
            }));
        }
        steps.push(toolStep("profiler-enable", "communityshaders.profiler_api", {
            contractMajor: 1,
            clientId: `${stem}-profiler-client`,
            commandId: `${stem}-profiler-enable`,
            action: "set_enabled",
            enabled: true,
            expectedBuildId: buildId,
        }));
        const response = await scenario(steps);
        const entries = requireScenario(response.root, steps.length);
        const start = entries.get("measured-stress-start");
        const sessionId = start.status.session.id;
        store(`${runId}:${lane.id}:pass-${pass}:handoff`, response.envelope);
        return sessionId;
    }

    async function transition(boundary, lane, laneIndex, pass, row) {
        const destination = matrix.destinations[row.destination];
        const target = targetFor(boundary, destination, lane.configuredFsrRuntime);
        const identifiers = ids(laneIndex, pass, row.ordinal, false);
        const steps = qualificationSteps(
            boundary, target, identifiers, false, row.ordinal === 1);
        let response;
        try {
            response = await scenario(steps);
        } catch {
            const waiter = await recoverTerminal(identifiers);
            store(`${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`, { waiter });
            if (!safeTerminal(waiter, identifiers)) throw new Error("transition_unsafe");
            return { boundary: terminalBoundary(waiter), waiter };
        }
        const entries = resultMap(response.root);
        const waiter = entries.get("qualification-wait");
        store(`${runId}:${lane.id}:pass-${pass}:transition-${row.ordinal}`, {
            apply: entries.get("profile-apply"),
            waiter,
            traceStop: entries.get("dlss-trace-stop") || null,
        });
        if (!response.root.ok || !waiter) {
            await closeOpenQualification(identifiers);
            throw new Error("transition_scenario_failed");
        }
        if (!safeTerminal(waiter, identifiers)) throw new Error("transition_unsafe");
        notify({
            lane: lane.id,
            pass,
            ordinal: row.ordinal,
            target,
            satisfied: waiter.satisfied === true,
            outcome: waiter.outcome,
            elapsedMs: waiter.timing ? waiter.timing.elapsedMs : null,
        });
        return { boundary: terminalBoundary(waiter), waiter };
    }

    async function status(lane, pass, suffix) {
        const response = await scenario([
            toolStep("render-status", "communityshaders.renderscale", {
                action: "status", expectedBuildId: buildId,
            }),
            toolStep("cpu-status", "communityshaders.renderscale", {
                action: "cpu_performance_status", expectedBuildId: buildId,
            }),
            toolStep("gpu-status", "communityshaders.renderscale", {
                action: "gpu_performance_status", expectedBuildId: buildId,
            }),
            toolStep("texture-status", "communityshaders.renderscale", {
                action: "texture_lifetime_status", expectedBuildId: buildId,
            }),
        ]);
        const entries = requireScenario(response.root, 4);
        store(`${runId}:${lane.id}:pass-${pass}:${suffix}`, response.envelope);
        return entries;
    }

    async function cleanup(lane, pass, stressSessionId) {
        const before = await status(lane, pass, "final-status-before-cleanup");
        const render = before.get("render-status").status;
        const cpu = before.get("cpu-status").cpuPerformance;
        const gpu = before.get("gpu-status").capture;
        const texture = before.get("texture-status").capture;
        const steps = [];
        if (render.session.active) {
            steps.push(toolStep("measured-stress-stop", "communityshaders.renderscale", {
                action: "stop", expectedSessionId: stressSessionId, expectedBuildId: buildId,
            }));
        }
        if (cpu.active) {
            const args = { action: "cpu_performance_stop", expectedBuildId: buildId };
            if (cpu.sessionId) args.expectedSessionId = cpu.sessionId;
            steps.push(toolStep("cpu-performance-stop", "communityshaders.renderscale", args));
        }
        if (gpu.active) {
            steps.push(toolStep("gpu-performance-stop", "communityshaders.renderscale", {
                action: "gpu_performance_stop", expectedBuildId: buildId,
            }));
        }
        if (texture.active) {
            steps.push(toolStep("texture-lifetime-stop", "communityshaders.renderscale", {
                action: "texture_lifetime_stop", expectedBuildId: buildId,
            }));
        }
        if (render.loadPresentationProbe.active) {
            steps.push(toolStep("load-presentation-stop", "communityshaders.renderscale", {
                action: "probe_stop", expectedBuildId: buildId,
            }));
        }
        steps.push(toolStep("profiler-disable", "communityshaders.profiler_api", {
            contractMajor: 1,
            clientId: `${runId}-${lane.id}-${pass}-cleanup-client`,
            commandId: `${runId}-${lane.id}-${pass}-cleanup-disable`,
            action: "set_enabled",
            enabled: false,
            expectedBuildId: buildId,
        }));
        const response = await scenario(steps);
        requireScenario(response.root, steps.length);
        store(`${runId}:${lane.id}:pass-${pass}:cleanup`, response.envelope);
        await status(lane, pass, "final-status-after-cleanup");
    }

    async function cooldown(lane, pass) {
        const response = await scenario([{ label: "memory-cooldown", wait: 10000 }]);
        requireScenario(response.root, 1);
        store(`${runId}:${lane.id}:pass-${pass}:cooldown`, response.envelope);
        await status(lane, pass, "cooldown-end");
    }

    function lanes() {
        if (variant === "nvidia") {
            return [{
                id: "nvidia",
                configuredFsrRuntime: matrix.initialDormantFsrRuntime,
                runnable: true,
            }];
        }
        const unavailable = capabilities.fsrRuntimeUnavailableConditions;
        const fsr3 = (capabilities.supportedFSRRuntimeMask & 1) !== 0 &&
            unavailable[0].mask === 0;
        const fsr4 = (capabilities.supportedFSRRuntimeMask & 2) !== 0;
        const fsr4Unavailable = unavailable[1].mask !== 0;
        return matrix.lanes.map((lane) => ({
            ...lane,
            runnable: lane.id === "explicit_fsr4" ? fsr4 && unavailable[1].mask === 0 :
                lane.id === "explicit_fsr3" ? fsr3 : fsr3 && fsr4Unavailable,
        }));
    }

    let boundary = initialBoundary;
    const summary = { ok: true, status: "COMPLETE", variant, runId, lanes: [] };
    let passSequence = 0;
    const selectedLanes = lanes();
    for (let laneIndex = 0; laneIndex < selectedLanes.length; laneIndex += 1) {
        const lane = selectedLanes[laneIndex];
        const laneSummary = { id: lane.id, status: lane.runnable ? "COMPLETE" : "BLOCKED", passes: [] };
        summary.lanes.push(laneSummary);
        if (!lane.runnable) continue;
        for (let pass = 1; pass <= 2; pass += 1) {
            passSequence += 1;
            let stressSessionId = 0;
            try {
                const base = await baseline(boundary, lane, laneIndex + 1, pass);
                boundary = base.boundary;
                stressSessionId = await armOwners(
                    base, lane, laneIndex + 1, pass, passSequence > 1);
                const rows = [];
                for (const row of matrix.transitions) {
                    const completed = await transition(
                        boundary, lane, laneIndex + 1, pass, row);
                    boundary = completed.boundary;
                    rows.push({ ordinal: row.ordinal, satisfied: completed.waiter.satisfied === true });
                }
                await cleanup(lane, pass, stressSessionId);
                stressSessionId = 0;
                laneSummary.passes.push({ pass, status: "COMPLETE", rows });
                if (pass === 1) await cooldown(lane, pass);
            } catch (error) {
                if (stressSessionId) {
                    try { await cleanup(lane, pass, stressSessionId); } catch { }
                }
                summary.ok = false;
                summary.status = "INTERRUPTED";
                laneSummary.status = "INTERRUPTED";
                laneSummary.passes.push({
                    pass,
                    status: "INTERRUPTED",
                    error: error instanceof Error ? error.message : String(error),
                });
                store(`${runId}:live-result`, summary);
                return summary;
            }
        }
    }
    store(`${runId}:live-result`, summary);
    return summary;
}
