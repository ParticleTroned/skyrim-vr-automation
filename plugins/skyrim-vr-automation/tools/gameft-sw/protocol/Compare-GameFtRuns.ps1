param(
    [Parameter(Mandatory)][string]$BaselineSummary,
    [Parameter(Mandatory)][string[]]$ComparisonSummaries,
    [Parameter(Mandatory)][string]$BaselineLabel,
    [Parameter(Mandatory)][string[]]$ComparisonLabels,
    [string[]]$SaveLabels
)

$ErrorActionPreference = 'Stop'

function Expand-GameFtArgumentList {
    param([string[]]$Values)

    $expanded = [Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        foreach ($part in ([string]$value -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) {
                $expanded.Add($trimmed)
            }
        }
    }

    return [string[]]$expanded
}

$ComparisonSummaries = Expand-GameFtArgumentList $ComparisonSummaries
$ComparisonLabels = Expand-GameFtArgumentList $ComparisonLabels
$SaveLabels = Expand-GameFtArgumentList $SaveLabels

if ($ComparisonSummaries.Count -ne $ComparisonLabels.Count) {
    throw 'ComparisonSummaries and ComparisonLabels must have the same count.'
}

function Import-GameFtSummary {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path)) {
        throw "Summary not found: $Path"
    }

    $loaded = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($loaded -is [array]) {
        return $loaded
    }

    return @($loaded)
}

function Format-GameFtMetric {
    param(
        $Value,
        [int]$Digits = 3
    )

    if ($null -eq $Value) {
        return 'n/a'
    }

    return ([math]::Round([double]$Value, $Digits)).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Format-GameFtDelta {
    param(
        $Value,
        [int]$Digits = 3
    )

    if ($null -eq $Value) {
        return 'n/a'
    }

    $rounded = [math]::Round([double]$Value, $Digits)
    if ($rounded -gt 0) {
        return '+' + $rounded.ToString("N$Digits", [Globalization.CultureInfo]::InvariantCulture)
    }

    return $rounded.ToString("N$Digits", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-GameFtSeconds {
    param($Value)

    if ($null -eq $Value) {
        return 'not reached'
    }

    return "$Value" + 's'
}

function Get-GameFtSaveLabel {
    param(
        $Run,
        [int]$Index
    )

    if ($SaveLabels -and $Index -lt $SaveLabels.Count) {
        return $SaveLabels[$Index]
    }

    if ($Run.name -match '^Save(\d+)_') {
        return ([int]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)).ToString('00')
    }

    return $Run.save
}

function Get-GameFtMetricValue {
    param(
        $Run,
        [Parameter(Mandatory)][string]$Metric
    )

    switch ($Metric) {
        'cpuAvg' { return $Run.cpuTailMeanMs }
        'cpuP95' { return $Run.cpuTailP95Ms }
        'cpuP99' { return $Run.cpuTailP99Ms }
        'cpuMax' { return $Run.cpuTailSpikeNoise.maxMs }
        'cpuSingle' { return $Run.cpuSingleSpikeFrequency.frequencyPerSecond }
        'cpuGroups' { return $Run.cpuSpikeGroups.frequencyPerSecond }
        'cpuDuty' { return $Run.cpuSpikeGroups.dutyPercent }
        'cpuStable' { return $Run.cpuPracticalStabilizationS }
        'gpuAvg' { return $Run.gpuTailMeanMs }
        'gpuP95' { return $Run.gpuTailP95Ms }
        'gpuP99' { return $Run.gpuTailP99Ms }
        'gpuMax' { return $Run.gpuTailSpikeNoise.maxMs }
        'gpuSingle' { return $Run.gpuSingleSpikeFrequency.frequencyPerSecond }
        'gpuGroups' { return $Run.gpuSpikeGroups.frequencyPerSecond }
        'gpuDuty' { return $Run.gpuSpikeGroups.dutyPercent }
        'gpuSettle' { return $Run.gpuSettlingS }
        default { throw "Unknown metric: $Metric" }
    }
}

function Format-GameFtMetricCell {
    param(
        $BaselineRun,
        $CurrentRun,
        [Parameter(Mandatory)][string]$Metric,
        [int]$Digits = 3,
        [string]$Suffix = '',
        [string]$DeltaSuffix = ''
    )

    $value = Get-GameFtMetricValue $CurrentRun $Metric
    if ($Metric -eq 'cpuStable' -or $Metric -eq 'gpuSettle') {
        return Format-GameFtSeconds $value
    }

    $cell = (Format-GameFtMetric $value $Digits) + $Suffix
    if ($null -ne $BaselineRun) {
        $baselineValue = Get-GameFtMetricValue $BaselineRun $Metric
        $delta = $value - $baselineValue
        $cell += ' (' + (Format-GameFtDelta $delta $Digits) + $DeltaSuffix + ')'
    }

    return $cell
}

function Format-GameFtStretch {
    param($Run)

    if ($Run.lifecycle.firstStretchCompleted) {
        $frames = $Run.lifecycle.firstStretchCompleted.stretchCompletedFrames
        $milliseconds = Format-GameFtMetric $Run.lifecycle.firstStretchCompleted.stretchCompletedMilliseconds 1
        return "${frames}f/${milliseconds}ms"
    }

    if ($Run.lifecycle.firstStretchStarted -and $Run.lifecycle.finalSample.stretchActiveAtStop) {
        return 'active at stop'
    }

    return 'none'
}

function Format-GameFtLifecycle {
    param($Run)

    $render = $Run.renderSettling.summary
    if (!$render -or $render -match ',\s+ms,') {
        if ($Run.renderSettling.kind -eq 'transition_metric') {
            $milliseconds = if ($null -ne $Run.renderSettling.settlingMilliseconds) {
                (Format-GameFtMetric $Run.renderSettling.settlingMilliseconds 1) + 'ms'
            } else {
                'ms unavailable'
            }
            $backend = if ($Run.renderSettling.backend) { $Run.renderSettling.backend } else { $Run.renderSettling.method }
            $render = "$($Run.renderSettling.totalFrames)f/$milliseconds/$backend/q$($Run.renderSettling.qualityMode)"
        }
    }

    return "$render; stretch $(Format-GameFtStretch $Run); final OK=$($Run.lifecycle.finalSuccessful)"
}

function Write-GameFtMarkdownTable {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Rows
    )

    Write-Output ''
    Write-Output $Title
    Write-Output ''

    $headers = @('Save', 'Metric', $BaselineLabel) + $ComparisonLabels
    Write-Output ('| ' + ($headers -join ' | ') + ' |')
    Write-Output ('| ' + (($headers | ForEach-Object { '---' }) -join ' | ') + ' |')

    foreach ($row in $Rows) {
        $cells = foreach ($header in $headers) {
            ([string]$row.$header).Replace('|', '/')
        }
        Write-Output ('| ' + ($cells -join ' | ') + ' |')
    }
}

$baseline = @(Import-GameFtSummary $BaselineSummary)
$comparisons = [Collections.Generic.List[object[]]]::new()
foreach ($summary in $ComparisonSummaries) {
    $comparisons.Add([object[]]@(Import-GameFtSummary $summary))
}

$runCount = $baseline.Count
foreach ($comparison in $comparisons) {
    if ($comparison.Count -ne $runCount) {
        throw 'All summaries must contain the same number of save rows.'
    }
}

$cpuMetrics = @(
    @{ Key='cpuAvg'; Name='Avg ms'; Digits=3 },
    @{ Key='cpuP95'; Name='P95 ms'; Digits=3 },
    @{ Key='cpuP99'; Name='P99 ms'; Digits=3 },
    @{ Key='cpuMax'; Name='Max ms'; Digits=3 },
    @{ Key='cpuSingle'; Name='Single spikes/s'; Digits=2 },
    @{ Key='cpuGroups'; Name='Group spikes/s'; Digits=2 },
    @{ Key='cpuDuty'; Name='Group duty'; Digits=2; Suffix='%'; DeltaSuffix=' pp' },
    @{ Key='cpuStable'; Name='CPU stable'; Digits=0 }
)

$gpuMetrics = @(
    @{ Key='gpuAvg'; Name='Avg ms'; Digits=3 },
    @{ Key='gpuP95'; Name='P95 ms'; Digits=3 },
    @{ Key='gpuP99'; Name='P99 ms'; Digits=3 },
    @{ Key='gpuMax'; Name='Max ms'; Digits=3 },
    @{ Key='gpuSingle'; Name='Single spikes/s'; Digits=2 },
    @{ Key='gpuGroups'; Name='Group spikes/s'; Digits=2 },
    @{ Key='gpuDuty'; Name='Group duty'; Digits=2; Suffix='%'; DeltaSuffix=' pp' },
    @{ Key='gpuSettle'; Name='GPU settle'; Digits=0 }
)

$cpuRows = for ($index = 0; $index -lt $runCount; $index++) {
    $baselineRun = $baseline[$index]
    foreach ($metric in $cpuMetrics) {
        $row = [ordered]@{
            Save = Get-GameFtSaveLabel $baselineRun $index
            Metric = $metric.Name
            $BaselineLabel = Format-GameFtMetricCell $null $baselineRun $metric.Key $metric.Digits $metric.Suffix $metric.DeltaSuffix
        }
        for ($comparisonIndex = 0; $comparisonIndex -lt $comparisons.Count; $comparisonIndex++) {
            $row[$ComparisonLabels[$comparisonIndex]] =
                Format-GameFtMetricCell $baselineRun $comparisons[$comparisonIndex][$index] $metric.Key $metric.Digits $metric.Suffix $metric.DeltaSuffix
        }
        [pscustomobject]$row
    }
}

$gpuRows = for ($index = 0; $index -lt $runCount; $index++) {
    $baselineRun = $baseline[$index]
    foreach ($metric in $gpuMetrics) {
        $row = [ordered]@{
            Save = Get-GameFtSaveLabel $baselineRun $index
            Metric = $metric.Name
            $BaselineLabel = Format-GameFtMetricCell $null $baselineRun $metric.Key $metric.Digits $metric.Suffix $metric.DeltaSuffix
        }
        for ($comparisonIndex = 0; $comparisonIndex -lt $comparisons.Count; $comparisonIndex++) {
            $row[$ComparisonLabels[$comparisonIndex]] =
                Format-GameFtMetricCell $baselineRun $comparisons[$comparisonIndex][$index] $metric.Key $metric.Digits $metric.Suffix $metric.DeltaSuffix
        }
        [pscustomobject]$row
    }
}

$lifecycleRows = for ($index = 0; $index -lt $runCount; $index++) {
    $row = [ordered]@{
        Save = Get-GameFtSaveLabel $baseline[$index] $index
        Metric = 'render/stretch/final'
        $BaselineLabel = Format-GameFtLifecycle $baseline[$index]
    }
    for ($comparisonIndex = 0; $comparisonIndex -lt $comparisons.Count; $comparisonIndex++) {
        $row[$ComparisonLabels[$comparisonIndex]] = Format-GameFtLifecycle $comparisons[$comparisonIndex][$index]
    }
    [pscustomobject]$row
}

Write-Output 'Deltas are relative to the baseline column. Positive frame-time and spike deltas are slower/noisier.'
Write-GameFtMarkdownTable 'CPU, final 10s' $cpuRows
Write-GameFtMarkdownTable 'GPU, final 10s' $gpuRows
Write-GameFtMarkdownTable 'Render-scale health' $lifecycleRows
