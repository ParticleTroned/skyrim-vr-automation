# gameft-sw scheduler accounting

For each saved final ten-second measurement window, retain the reconstructed
running, ready and waiting durations. Their sum is compared with 10,000 ms.

The absolute accounting-error tolerance is **10 ms, inclusive**:

`abs(runningMs + readyMs + waitMs - 10000) <= 10`

The user changed this analysis rule from 5 ms to 10 ms on 2026-09-18.
`scheduler_coverage.py` is the shared policy for subsequent analyses and
reassessments. Missing, nonnumeric and nonfinite errors do not pass.

Keep the measured durations and signed error unchanged. Record the policy ID
and tolerance beside each reassessed verdict. Preserve historical receipts
and their original verdicts; a new report can classify the same measured
error under the current policy without rewriting the historical receipt.

For example, 10,005.360 ms accounted time passes the current rule with
+5.360 ms error. Both +10 ms and -10 ms pass; errors beyond either boundary
do not. No per-window user exception is required for values inside the bound.

This rule does not change fpsVR statistics, measurement windows, spike rules,
render-health gates, trace-loss requirements or symbol/provenance checks.
It is offline analysis policy and adds no production instrumentation.
