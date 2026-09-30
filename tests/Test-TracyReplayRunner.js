// SPDX-License-Identifier: GPL-3.0-or-later

// Runs in the existing functions JavaScript runtime; no live tools or game required.
async function testTracyReplayRunner(run, parse, connectionResponse) {
    const alias = "csx-dragonsreach-20260930-p40968";
    const passed = [];
    function assert(value, message) { if (!value) throw new Error(message); }
    function envelope(value) {
        return { isError: false, content: [{ type: "text", text: JSON.stringify(value) }] };
    }
    async function check(name, changes, expected, expectedCalls) {
        const calls = [];
        const api = {
            reserveProcess: async () => {
                calls.push("reserve");
                if (changes.reserveError) throw new Error("already reserved");
                return { pid: 40968, owner: alias, startedUtc: "2026-09-30T10:18:57.5660638Z" };
            },
            liveConnect: async (args) => {
                calls.push("connect");
                assert(args.alias === alias, "connection alias changed");
                if (changes.connectError) throw new Error("connection reply lost");
                return changes.connectResult || connectionResponse;
            },
            eval: async (args) => {
                calls.push(args.code);
                assert(args.instance_id === alias, "used success prose as instance ID");
                if (changes[args.code + "Error"]) throw new Error(args.code + " failed");
                if (changes[args.code + "Result"]) return changes[args.code + "Result"];
                if (args.code === "prepare") return envelope({ readiness: { ready: true },
                    admission: { pid: 40968, connected: true } });
                return envelope({ pid: 40968, owner: alias, disconnectRequested: true,
                    stopReason: args.code === "finish" ? "replay_complete" : "failure_before_guard" });
            },
            replay: async () => {
                calls.push("replay");
                if (changes.replayError) throw new Error("replay failed");
                return { verified: !changes.unverified };
            },
        };
        const result = await run(api, { alias, expectedPid: 40968, address: "127.0.0.1",
            port: 8086, memoryLimitMiB: 16384,
            codes: { prepare: "prepare", finish: "finish", abort: "abort" } });
        assert(result.ok === expected, name + ": incorrect verdict");
        assert(JSON.stringify(calls) === JSON.stringify(expectedCalls), name + ": incorrect call order");
        if (changes.abortError) {
            assert(result.failure.includes("prepare"), "cleanup replaced original error");
            assert(result.journal.some(entry => entry.label === "cleanupFailure"), "lost cleanup error");
        }
        passed.push(name);
    }
    await check("actual success sentence uses requested alias", {}, true,
        ["reserve", "connect", "prepare", "replay", "finish"]);
    await check("content-only success sentence", { connectResult: { content: connectionResponse.content } },
        true, ["reserve", "connect", "prepare", "replay", "finish"]);
    await check("no reconnect after reservation failure", { reserveError: true }, false, ["reserve"]);
    await check("lost connect response aborts exact alias", { connectError: true }, false,
        ["reserve", "connect", "abort"]);
    await check("MCP connect error aborts before guard", { connectResult: { isError: true } }, false,
        ["reserve", "connect", "abort"]);
    await check("plain Error with isError false blocks replay", { prepareResult: {
        isError: false, content: [{ type: "text", text: "Error: Instance not found" }] } }, false,
        ["reserve", "connect", "prepare", "abort"]);
    await check("early eval failure aborts before guard", { prepareError: true }, false,
        ["reserve", "connect", "prepare", "abort"]);
    await check("bad admission never dispatches replay", { prepareResult: envelope({ readiness: { ready: true } }) },
        false, ["reserve", "connect", "prepare", "abort"]);
    await check("unverified replay is rejected", { unverified: true }, false,
        ["reserve", "connect", "prepare", "replay", "abort"]);
    await check("replay exception stops capture", { replayError: true }, false,
        ["reserve", "connect", "prepare", "replay", "abort"]);
    await check("finish exception still aborts", { finishError: true }, false,
        ["reserve", "connect", "prepare", "replay", "finish", "abort"]);
    await check("deadline is not success", { finishResult: envelope({ stopReason: "deadline" }) }, false,
        ["reserve", "connect", "prepare", "replay", "finish", "abort"]);
    await check("cleanup failure preserves original error", { prepareError: true, abortError: true }, false,
        ["reserve", "connect", "prepare", "abort"]);
    for (const raw of [null, { isError: true }, envelope("not an object"),
        { structuredContent: { result: "Error: failed" }, isError: false }]) {
        let rejected = false;
        try { parse(raw, true); } catch { rejected = true; }
        assert(rejected, "invalid result accepted");
    }
    passed.push("invalid envelopes rejected");
    return { passed: passed.length, cases: passed };
}
