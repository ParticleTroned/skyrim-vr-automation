// SPDX-License-Identifier: GPL-3.0-or-later

function tracyResult(response, objectRequired = false) {
    if (!response || response.isError) {
        throw new Error(`tracy_tool_error: ${JSON.stringify(response)}`);
    }
    let value = response.structuredContent?.result;
    if (value === undefined) {
        const text = (response.content || []).filter(item => item.type === "text");
        if (text.length !== 1) throw new Error("tracy_result_missing_or_ambiguous");
        value = text[0].text;
    }
    if (typeof value === "string") {
        if (/^\s*Error:/i.test(value)) throw new Error(value);
        if (objectRequired) value = JSON.parse(value);
    }
    if (objectRequired && (!value || typeof value !== "object" || Array.isArray(value))) {
        throw new Error("tracy_object_result_required");
    }
    return value;
}

/** Run the prepared replay through the existing MCP tools without a chat hand-off. */
async function runTracyReplay(api, options) {
    const { alias, expectedPid, codes } = options;
    if (typeof alias !== "string" || !alias.trim() ||
        !Number.isSafeInteger(expectedPid) || expectedPid <= 0 ||
        typeof options.address !== "string" || !options.address ||
        !Number.isSafeInteger(options.port) || options.port < 1 || options.port > 65535 ||
        !Number.isSafeInteger(options.memoryLimitMiB) ||
        options.memoryLimitMiB < 1024 || options.memoryLimitMiB > 32768 ||
        !["prepare", "finish", "abort"].every(key => typeof codes?.[key] === "string" && codes[key]) ||
        !["reserveProcess", "liveConnect", "eval", "replay"].every(key => typeof api[key] === "function")) {
        throw new Error("tracy_runner_inputs_missing");
    }
    const journal = [];
    const record = (label, value) => journal.push({ label, utc: new Date().toISOString(), value });
    const evaluate = async (action) => {
        const raw = await api.eval({ instance_id: alias, code: codes[action] });
        record(action, raw);
        return tracyResult(raw, true);
    };
    let attempted = false;
    let finished = false;
    let failure = null;
    try {
        // A lost connection response still consumes this process for the protocol.
        const reservation = await api.reserveProcess();
        record("reservation", reservation);
        if (reservation?.pid !== expectedPid || reservation?.owner !== alias ||
            typeof reservation?.startedUtc !== "string" || !reservation.startedUtc) {
            throw new Error("tracy_reservation_unproven");
        }
        attempted = true;
        const raw = await api.liveConnect({ address: options.address, port: options.port,
            alias, memory_limit_mb: options.memoryLimitMiB });
        record("connected", raw);
        tracyResult(raw); // Success prose is evidence, never an instance identifier.
        const prepared = await evaluate("prepare");
        if (prepared.readiness?.ready !== true || prepared.admission?.pid !== expectedPid ||
            prepared.admission?.connected !== true) throw new Error("tracy_admission_unproven");
        record("replayDispatch", { alias });
        const replay = await api.replay();
        record("replayTerminal", replay);
        if (replay?.verified !== true) throw new Error("tracy_replay_terminal_unproven");
        const stopped = await evaluate("finish");
        if (stopped.stopReason !== "replay_complete" || stopped.disconnectRequested !== true ||
            stopped.pid !== expectedPid || stopped.owner !== alias ||
            stopped.failure || stopped.disconnectError || stopped.persistenceError) {
            throw new Error("tracy_completion_unproven");
        }
        finished = true;
    } catch (error) {
        failure = String(error);
        record("failure", failure);
    } finally {
        if (attempted && !finished) {
            try {
                const aborted = await evaluate("abort");
                if (aborted.disconnectRequested !== true || aborted.pid !== expectedPid ||
                    aborted.owner !== alias || aborted.disconnectError || aborted.persistenceError) {
                    throw new Error("tracy_abort_unproven");
                }
            } catch (error) {
                record("cleanupFailure", String(error));
            }
        }
    }
    // Disconnect is asynchronous; the caller must verify it, save and release offline.
    return { ok: finished, alias, failure, journal };
}
