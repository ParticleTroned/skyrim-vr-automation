# CSX profiler control

`Measure-CSXProfiler.ps1` opens one DevBench MCP session, enables the CSX
profiler, discards a configurable warm-up period, and records resolved GPU/CPU
timer samples to raw JSON, a summary JSON, and timer CSV. If DevBench expires
the MCP session during a longer capture, the collector reinitializes it and
records the reconnect count in the summary without shortening the sample set.

```powershell
.\Measure-CSXProfiler.ps1 `
  -Label 'breezehome-enabled' `
  -EvidenceDirectory '.\evidence\<session>\profiler' `
  -Samples 120 -WarmupSamples 5 -IntervalMs 250
```

Supply DevBench runtime metadata with `-RuntimePath` or set
`CSX_DEVBENCH_RUNTIME_PATH`. No installation-specific path is built into the
collector.

`Compare-CSXProfiler.ps1` accepts two or more raw captures, removes any older
unresolved samples whose timer array is empty, and emits total and per-timer
JSON/CSV/Markdown comparisons. It also emits weighted per-frame estimates for
Screen Space Shadows, Skylighting, Volumetric Lighting, and Upscaling. Missing
features receive explicit zero rows, distinguishing absence from a lost row.
Aggregated `*.summary.json` input is rejected with a specific schema error.

```powershell
.\Compare-CSXProfiler.ps1 `
  -InputPath @('.\enabled.raw.json', '.\disabled.raw.json', '.\unloaded.raw.json') `
  -OutputDirectory '.\comparison' `
  -ReferenceLabel 'enabled'
```

Interpret the total as the active CSX profiler block, not whole-frame render
time. Feature-state changes can alter render resolution and therefore the cost
of passes that remain; do not add timer deltas as if the rendering paths were
otherwise identical.

Run the synthetic regression suite after changing either script:

```powershell
.\Test-ProfilerControl.ps1
```
