# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$InputPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ReferenceLabel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    [double]$sorted[$index]
}

function Get-MetricSummary {
    param([double[]]$Values)
    if ($Values.Count -eq 0) {
        return [pscustomobject][ordered]@{ count = 0; mean = $null; median = $null; p95 = $null; p99 = $null; min = $null; max = $null }
    }
    $measure = $Values | Measure-Object -Average -Minimum -Maximum
    [pscustomobject][ordered]@{
        count = $Values.Count
        mean = [double]$measure.Average
        median = Get-Percentile -Values $Values -Percentile 0.5
        p95 = Get-Percentile -Values $Values -Percentile 0.95
        p99 = Get-Percentile -Values $Values -Percentile 0.99
        min = [double]$measure.Minimum
        max = [double]$measure.Maximum
    }
}

$states = [System.Collections.Generic.List[object]]::new()
foreach ($path in $InputPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Profiler raw file does not exist: $path" }
    $label = [IO.Path]::GetFileName($path) -replace '\.raw\.json$', ''
    $records = @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 60)
    $firstTimer = @($records | ForEach-Object { @($_.timers) } | Select-Object -First 1)
    if ($firstTimer.Count -gt 0 -and 'activeGpu' -notin $firstTimer[0].PSObject.Properties.Name) {
        throw "Profiler comparison requires per-sample *.raw.json input; '$path' contains aggregated timer rows."
    }
    $steady = @($records | Where-Object { @($_.timers).Count -gt 0 })
    $timerRows = foreach ($record in $steady) {
        foreach ($timer in @($record.timers)) {
            if ([bool]$timer.activeGpu -and [bool]$timer.hasGpu) {
                [pscustomobject]@{ name = [string]$timer.name; gpuMs = [double]$timer.gpuMs; topLevelMs = [double]$timer.topLevelMs }
            }
        }
    }
    $timers = foreach ($group in ($timerRows | Group-Object name | Sort-Object Name)) {
        [pscustomobject][ordered]@{
            name = $group.Name
            gpuMs = Get-MetricSummary -Values ([double[]]@($group.Group | ForEach-Object gpuMs))
            topLevelMs = Get-MetricSummary -Values ([double[]]@($group.Group | ForEach-Object topLevelMs))
        }
    }
    $states.Add([pscustomobject][ordered]@{
        label = $label
        path = (Resolve-Path -LiteralPath $path).Path
        requestedSamples = $records.Count
        steadySamples = $steady.Count
        discardedWarmupSamples = $records.Count - $steady.Count
        resolvedTotalMs = Get-MetricSummary -Values ([double[]]@($steady | ForEach-Object resolvedTotalMs))
        resolvedCpuTotalMs = Get-MetricSummary -Values ([double[]]@($steady | ForEach-Object resolvedCpuTotalMs))
        timers = @($timers)
    })
}

if ([string]::IsNullOrWhiteSpace($ReferenceLabel)) { $ReferenceLabel = $states[0].label }
$reference = @($states | Where-Object label -eq $ReferenceLabel)
if ($reference.Count -ne 1) { throw "Reference label must match exactly one input: $ReferenceLabel" }
$referenceMean = [double]$reference[0].resolvedTotalMs.mean

$rows = foreach ($state in $states) {
    [pscustomobject][ordered]@{
        label = $state.label
        requestedSamples = $state.requestedSamples
        steadySamples = $state.steadySamples
        totalMeanMs = $state.resolvedTotalMs.mean
        totalMedianMs = $state.resolvedTotalMs.median
        totalP95Ms = $state.resolvedTotalMs.p95
        totalP99Ms = $state.resolvedTotalMs.p99
        totalMinMs = $state.resolvedTotalMs.min
        totalMaxMs = $state.resolvedTotalMs.max
        deltaVsReferenceMs = [double]$state.resolvedTotalMs.mean - $referenceMean
        ratioVsReference = if ($referenceMean -ne 0.0) { [double]$state.resolvedTotalMs.mean / $referenceMean } else { $null }
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$jsonPath = Join-Path $OutputDirectory 'profiler-state-comparison.json'
$csvPath = Join-Path $OutputDirectory 'profiler-state-comparison.csv'
$markdownPath = Join-Path $OutputDirectory 'profiler-state-comparison.md'
$timerCsvPath = Join-Path $OutputDirectory 'profiler-timer-comparison.csv'
$timerMarkdownPath = Join-Path $OutputDirectory 'profiler-timer-comparison.md'
$featureCsvPath = Join-Path $OutputDirectory 'profiler-feature-comparison.csv'
$featureMarkdownPath = Join-Path $OutputDirectory 'profiler-feature-comparison.md'
[pscustomobject][ordered]@{
    schemaVersion = 1
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    referenceLabel = $ReferenceLabel
    states = @($states)
    comparison = @($rows)
} | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
$timerRows = foreach ($state in $states) {
    foreach ($timer in $state.timers) {
        [pscustomobject][ordered]@{
            state = $state.label
            timer = $timer.name
            samples = $timer.gpuMs.count
            meanMs = $timer.gpuMs.mean
            medianMs = $timer.gpuMs.median
            p95Ms = $timer.gpuMs.p95
            p99Ms = $timer.gpuMs.p99
            maxMs = $timer.gpuMs.max
            topLevelMeanMs = $timer.topLevelMs.mean
        }
    }
}
$timerRows | Export-Csv -LiteralPath $timerCsvPath -NoTypeInformation -Encoding utf8
$featurePrefixes = @('ScreenSpaceShadows', 'Skylighting', 'VolumetricLighting', 'Upscaling')
$featureRows = foreach ($state in $states) {
    foreach ($feature in $featurePrefixes) {
        $matches = @($timerRows | Where-Object { $_.state -eq $state.label -and $_.timer -like "$feature::*" })
        $weightedMeanMs = 0.0
        if ($state.steadySamples -gt 0 -and $matches.Count -gt 0) {
            $weightedTerms = @($matches | ForEach-Object {
                [double]$_.meanMs * [int]$_.samples / [int]$state.steadySamples
            })
            $weightedMeanMs = [double](($weightedTerms | Measure-Object -Sum).Sum)
        }
        [pscustomobject][ordered]@{
            state = $state.label
            feature = $feature
            timerCount = $matches.Count
            weightedMeanMs = $weightedMeanMs
            activeTimerSamples = if ($matches.Count -gt 0) { [int](($matches | Measure-Object samples -Sum).Sum) } else { 0 }
        }
    }
}
$featureRows | Export-Csv -LiteralPath $featureCsvPath -NoTypeInformation -Encoding utf8
$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# CSX profiler state comparison')
$md.Add('')
$md.Add("Reference: ``$ReferenceLabel``. Samples without resolved timers are excluded as warm-up.")
$md.Add('')
$md.Add('| State | Steady samples | Mean GPU (ms) | Median | P95 | Delta vs reference | Ratio |')
$md.Add('|---|---:|---:|---:|---:|---:|---:|')
foreach ($row in $rows) {
    $md.Add(('| {0} | {1} | {2:N4} | {3:N4} | {4:N4} | {5:N4} | {6:N3} |' -f $row.label, $row.steadySamples, $row.totalMeanMs, $row.totalMedianMs, $row.totalP95Ms, $row.deltaVsReferenceMs, $row.ratioVsReference))
}
$md | Set-Content -LiteralPath $markdownPath -Encoding utf8
$timerMd = [System.Collections.Generic.List[string]]::new()
$timerMd.Add('# CSX profiler timer comparison')
$timerMd.Add('')
$timerMd.Add('Only timers with a mean of at least 0.001 ms in one state are shown. Missing entries mean the timer was not registered or active in that state.')
$timerMd.Add('')
$timerMd.Add('| Timer | State | Samples | Mean (ms) | Median | P95 |')
$timerMd.Add('|---|---|---:|---:|---:|---:|')
$materialTimers = @($timerRows | Group-Object timer | Where-Object { ($_.Group | Measure-Object meanMs -Maximum).Maximum -ge 0.001 } | Sort-Object { -[double](($_.Group | Measure-Object meanMs -Maximum).Maximum) })
foreach ($timerGroup in $materialTimers) {
    foreach ($timerRow in ($timerGroup.Group | Sort-Object state)) {
        $timerMd.Add(('| {0} | {1} | {2} | {3:N4} | {4:N4} | {5:N4} |' -f $timerRow.timer, $timerRow.state, $timerRow.samples, $timerRow.meanMs, $timerRow.medianMs, $timerRow.p95Ms))
    }
}
$timerMd | Set-Content -LiteralPath $timerMarkdownPath -Encoding utf8
$featureMd = [System.Collections.Generic.List[string]]::new()
$featureMd.Add('# CSX relevant-feature timer comparison')
$featureMd.Add('')
$featureMd.Add('Weighted mean is each active timer mean multiplied by its active-sample fraction, then summed by feature. It is a per-frame estimate for the named timers, not an independently measured frame total.')
$featureMd.Add('')
$featureMd.Add('| State | Feature | Timers | Weighted mean (ms) | Active timer samples |')
$featureMd.Add('|---|---|---:|---:|---:|')
foreach ($featureRow in $featureRows) {
    $featureMd.Add(('| {0} | {1} | {2} | {3:N4} | {4} |' -f $featureRow.state, $featureRow.feature, $featureRow.timerCount, $featureRow.weightedMeanMs, $featureRow.activeTimerSamples))
}
$featureMd | Set-Content -LiteralPath $featureMarkdownPath -Encoding utf8

[pscustomobject][ordered]@{
    ok = $true
    referenceLabel = $ReferenceLabel
    jsonPath = $jsonPath
    csvPath = $csvPath
    markdownPath = $markdownPath
    timerCsvPath = $timerCsvPath
    timerMarkdownPath = $timerMarkdownPath
    featureCsvPath = $featureCsvPath
    featureMarkdownPath = $featureMarkdownPath
    comparison = @($rows)
} | ConvertTo-Json -Depth 20
