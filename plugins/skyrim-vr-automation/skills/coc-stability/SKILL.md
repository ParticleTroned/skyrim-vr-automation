---
name: coc-stability
description: Run a safe Skyrim VR COC stability and transition-throughput test when asked for a load-synchronized COC stress run or repeated cell-transition protocol.
---

# COC stability

Run cell changes one at a time. Never place multiple `coc` commands in one
fixed-delay scenario.

Read [references/protocol.md](references/protocol.md) before operating the game.

Before any COC, invoke `communityshaders.menu` with
`{"action":"prepare_coc","expectedBuildId":"<exact build ID>"}` exactly once.
Preserve the receipt and require `ready: true`, `persisted: false`, developer
mode active, the exact FOV plus TAA 0.3/0.7 fixture, and startup-active VR FPS
Stabilizer profile sync. This action may establish the runtime-only CSX
settings when Stabilizer is ready. It must not save them.

If `prepare_coc` is unavailable or returns `ready: false`, stop before the
start-cell COC. When `promptRequired` is true, tell the user the exact
`errorCode` and prerequisite. VR FPS Stabilizer cannot be installed or made
startup-active from a live test, so do not attempt another game operation.

Do not invoke `prepare_coc` again during start-cell establishment or the
measured assay. Do not add its settings to the per-transition waiter predicate.

Use plugin-provided direct DevBench MCP tools for every live operation. Start
continuous diagnostics once, then use one server-side stability waiter per
transition. The waiter must observe the exact destination, CSX profile
convergence, and the applicable two-eye presentation contract internally and
return only when the first coherent stable state is observed.

Do not replace the waiter with loading-menu checks, fixed delays, repeated
full-status responses, menu operations, or a PowerShell polling controller. If
the direct server does not expose the required waiter, stop and record the
capability gap instead of running a different protocol.

Dispatch the next transition immediately after the waiter succeeds. If the
waiter or current transition times out, stop without dispatching another game
command. Preserve the partial evidence and classify the run as failed
stability evidence, not completed performance evidence.
