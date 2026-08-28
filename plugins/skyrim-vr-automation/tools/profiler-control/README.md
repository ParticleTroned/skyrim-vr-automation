# CSX profiler control

`Measure-CSXProfiler.ps1` routes every profiler operation through the central,
identity-bound DevBench controller. It records the prior profiler enable state,
enables only when needed, and restores and verifies the exact prior state in a
`finally` path. Each accepted sample has a strictly advancing frame ID and
finite GPU/CPU metrics. A unique capture directory retains the raw JSON,
summary, timer CSV, DevBench invocation journals, and recovery receipt.

```powershell
.\Measure-CSXProfiler.ps1 `
  -Label 'breezehome-enabled' `
  -EvidenceDirectory '.\evidence\<session>\profiler' `
  -ContextJson '{"environment":{"mo2Profile":"Task-42","scene":"Breezehome still","hmdMode":"null","renderResolution":"2112x2112"},"treatment":{"shaderState":"enabled"}}' `
  -Samples 120 -WarmupSamples 5 -IntervalMs 250
```

Supply DevBench runtime metadata with `-RuntimePath` or set
`CSX_DEVBENCH_RUNTIME_PATH`. No installation-specific path is built into the
collector.

`ContextJson` is mandatory. Its `environment` object identifies the MO2
profile, scene, HMD mode, and render resolution; `treatment` records the
intended variable such as shader state. The environment and exact runtime
identity form the comparison fingerprint.

`Compare-CSXProfiler.ps1` accepts two or more raw captures, removes unresolved
samples whose timer array is empty, and emits total and per-timer
JSON/CSV/Markdown comparisons. It also emits weighted per-frame estimates for
Screen Space Shadows, Skylighting, Volumetric Lighting, and Upscaling. Missing
features receive explicit zero rows, distinguishing absence from a lost row.
Aggregated `*.summary.json` input is rejected with a specific schema error.
Every input needs at least three unique fresh frames, finite metrics, and the
same environment/runtime fingerprint.

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
