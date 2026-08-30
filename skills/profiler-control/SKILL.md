---
name: profiler-control
description: "Collect bounded CSX GPU and CPU profiler samples through DevBench and compare preserved captures. Use for render-time measurements, shader-state comparisons, enabled-versus-disabled-versus-unloaded experiments, timer baselines, or profiler evidence reports."
---

# Profiler Control

Read `../../tools/profiler-control/README.md` completely before capturing or
comparing data. Use these entry points:

```text
../../tools/profiler-control/Measure-CSXProfiler.ps1
../../tools/profiler-control/Compare-CSXProfiler.ps1
```

## Capture contract

1. State in commentary that this skill governs profiling. Apply
   `$devbench-control` when endpoint discovery or tool schema inspection is
   needed, and `$mo2-control` when a game lifecycle or mod-state transaction is
   in scope.
2. Establish the exact build, MO2 profile, scene, HMD mode, resolution, shader
   state, warm-up, sample count, and interval before comparing captures.
3. A capture enables the CSX profiler. That mutation requires the user's run or
   measurement authority; a request to review existing data does not.
4. Before enabling the profiler, the collector must read the registered
   standalone `skyrimvrupscaler.temporalProbe` status and reject capture unless
   `performanceDistorted` is explicitly false. A registered older probe with no
   such field fails closed. Never disarm it as part of profiler collection.
5. Write to a dedicated evidence directory outside live MO2 overwrite and
   shader-cache trees. Keep raw JSON; summaries alone cannot be re-analysed.
6. Compare at least two raw captures and identify the reference explicitly.
   Treat the total as the active CSX profiler block, not whole-frame cost. Do
   not sum correlated timer deltas into a fictional independent total.

Failed or partial captures are evidence. Record reconnects, missing timers,
scene drift, compilation activity, CTDs, and state changes instead of silently
retrying or substituting a different run.
