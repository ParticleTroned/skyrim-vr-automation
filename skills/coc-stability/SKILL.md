---
name: coc-stability
description: Run a safe Skyrim VR COC stability and transition-throughput test when asked for a load-synchronized COC stress run or repeated cell-transition protocol.
---

# COC stability

Run cell changes one at a time. Never place multiple `coc` commands in one
fixed-delay scenario.

Read [references/protocol.md](references/protocol.md) before operating the game.

Use plugin-provided direct DevBench MCP tools for live calls and polling. Use
the bundled DevBench controller only for the `upscalingStable` barrier, because
the direct server does not expose its exact-cell, CSX-convergence, stereo, and
advancing-frame predicate as one atomic wait.

The next transition may start immediately after the barrier succeeds. If the
barrier or the current transition times out, stop the run without dispatching
another game command. Preserve the partial evidence and classify the run as a
failed stability run, not as completed performance evidence.
