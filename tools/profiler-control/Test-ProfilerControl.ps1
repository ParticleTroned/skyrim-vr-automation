# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$passes = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Test([bool]$Condition, [string]$Message) {
    if ($Condition) { $passes.Add($Message) }
    else { $failures.Add($Message) }
}

function New-Timer([string]$Name, [double]$GpuMs) {
    [pscustomobject][ordered]@{
        name = $Name
        activeGpu = $true
        hasGpu = $true
        gpuMs = $GpuMs
        topLevelMs = $GpuMs
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('csx-profiler-control-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test root escaped the temporary directory: $resolvedTestRoot"
}

try {
    New-Item -ItemType Directory -Path $resolvedTestRoot -Force | Out-Null
    $stateAPath = Join-Path $resolvedTestRoot 'state-a.raw.json'
    $stateBPath = Join-Path $resolvedTestRoot 'state-b.raw.json'
    $summaryPath = Join-Path $resolvedTestRoot 'invalid.summary.json'
    $outputPath = Join-Path $resolvedTestRoot 'comparison'

    @(
        [pscustomobject]@{
            resolvedTotalMs = 10.0
            resolvedCpuTotalMs = 1.0
            timers = @(
                (New-Timer 'Upscaling::Synthetic' 4.0),
                (New-Timer 'VolumetricLighting::Synthetic' 2.0)
            )
        },
        [pscustomobject]@{
            resolvedTotalMs = 12.0
            resolvedCpuTotalMs = 2.0
            timers = @(
                (New-Timer 'Upscaling::Synthetic' 6.0),
                (New-Timer 'VolumetricLighting::Synthetic' 1.0)
            )
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateAPath -Encoding utf8

    @(
        [pscustomobject]@{ resolvedTotalMs = 0.0; resolvedCpuTotalMs = 0.0; timers = @() },
        [pscustomobject]@{
            resolvedTotalMs = 1.0
            resolvedCpuTotalMs = 0.1
            timers = @((New-Timer 'DeferredComposite' 1.0))
        }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateBPath -Encoding utf8

    [pscustomobject]@{
        schemaVersion = 1
        resolvedTotalMs = [pscustomobject]@{ mean = 10.0 }
        timers = @([pscustomobject]@{ name = 'Upscaling::Synthetic'; activeGpuSamples = 2 })
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8

    $compare = Join-Path $PSScriptRoot 'Compare-CSXProfiler.ps1'
    $result = & $compare -InputPath @($stateAPath, $stateBPath) -OutputDirectory $outputPath -ReferenceLabel 'state-a' | ConvertFrom-Json
    Assert-Test ($result.ok -and (Test-Path -LiteralPath $result.featureCsvPath -PathType Leaf)) 'comparison writes feature output'

    $states = @(Import-Csv -LiteralPath $result.csvPath)
    $stateB = @($states | Where-Object label -eq 'state-b')[0]
    Assert-Test ([int]$stateB.steadySamples -eq 1) 'comparison excludes timerless warm-up records'

    $features = @(Import-Csv -LiteralPath $result.featureCsvPath)
    $upscalingA = @($features | Where-Object { $_.state -eq 'state-a' -and $_.feature -eq 'Upscaling' })[0]
    $volumetricA = @($features | Where-Object { $_.state -eq 'state-a' -and $_.feature -eq 'VolumetricLighting' })[0]
    $upscalingB = @($features | Where-Object { $_.state -eq 'state-b' -and $_.feature -eq 'Upscaling' })[0]
    Assert-Test ([Math]::Abs([double]$upscalingA.weightedMeanMs - 5.0) -lt 0.000001) 'weighted feature mean uses active-sample fraction'
    Assert-Test ([Math]::Abs([double]$volumetricA.weightedMeanMs - 1.5) -lt 0.000001) 'weighted feature mean aggregates multiple samples'
    Assert-Test ([int]$upscalingB.timerCount -eq 0 -and [double]$upscalingB.weightedMeanMs -eq 0.0) 'unloaded feature emits an explicit zero row'

    $schemaError = $null
    try {
        & $compare -InputPath $summaryPath -OutputDirectory (Join-Path $resolvedTestRoot 'invalid-output') | Out-Null
    }
    catch { $schemaError = $_.Exception.Message }
    Assert-Test ($schemaError -like 'Profiler comparison requires per-sample *.raw.json input*') 'aggregated summary input fails with a specific schema error'

    $measureText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Measure-CSXProfiler.ps1') -Raw
    Assert-Test ($measureText -match "'skyrimvrupscaler\.temporalProbe'") 'capture preflights the standalone temporal probe'
    Assert-Test ($measureText -match 'Test-DevBenchPerformanceNeutral') 'capture consumes the shared structured performance guard'
    $guardIndex = $measureText.IndexOf('if (-not $performanceGuard.neutral)', [StringComparison]::Ordinal)
    $enableIndex = $measureText.IndexOf("Invoke-ProfilerAction -Action 'enable'", [StringComparison]::Ordinal)
    Assert-Test ($guardIndex -ge 0 -and $enableIndex -gt $guardIndex) 'performance guard rejects before profiler enable mutation'
    Assert-Test ($measureText -match 'schemaVersion = 2') 'capture preserves the accepted guard in summary schema 2'
}
finally {
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $failures.Count -eq 0
    passed = $passes.Count
    failed = $failures.Count
    passes = @($passes)
    failures = @($failures)
} | ConvertTo-Json -Depth 10

if ($failures.Count -gt 0) { exit 1 }
