param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [string]$FpsVrCsv
)
$ErrorActionPreference = 'Stop'
function Read-Markers {
    Get-Content -LiteralPath (Join-Path $RunDirectory 'markers.jsonl') |
        Where-Object { $_.Trim() } |
        ForEach-Object { $_ | ConvertFrom-Json }
}
function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if (!$Values -or $Values.Count -eq 0) { return $null }
    $sorted = [double[]]($Values | Sort-Object)
    $rank = ($sorted.Count - 1) * $Percentile
    $lo = [Math]::Floor($rank)
    $hi = [Math]::Ceiling($rank)
    if ($lo -eq $hi) { return $sorted[$lo] }
    return $sorted[$lo] + (($sorted[$hi] - $sorted[$lo]) * ($rank - $lo))
}
function ConvertTo-UtcDateTime($Value) {
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
function Get-Stats([double[]]$Values) {
    if (!$Values -or $Values.Count -eq 0) { return $null }
    $avg = ($Values | Measure-Object -Average).Average
    $variance = 0.0
    if ($Values.Count -gt 1) {
        foreach ($v in $Values) { $variance += [Math]::Pow($v - $avg, 2) }
        $variance /= ($Values.Count - 1)
    }
    $p5 = Get-Percentile $Values 0.05
    $p95 = Get-Percentile $Values 0.95
    [pscustomobject]@{
        count = $Values.Count
        mean = $avg
        median = Get-Percentile $Values 0.50
        sd = [Math]::Sqrt($variance)
        p95 = $p95
        p99 = Get-Percentile $Values 0.99
        max = ($Values | Measure-Object -Maximum).Maximum
        p95MinusP5 = $p95 - $p5
    }
}
function Get-Stabilization([object[]]$Rows, [string]$Column, [double]$TailMean, [double]$Tolerance) {
    foreach ($t in 0..50) {
        $ok = $true
        foreach ($windowStart in $t..55) {
            if ($windowStart + 5 -gt 60) { continue }
            $values = @($Rows | Where-Object { $_.relative -ge $windowStart -and $_.relative -lt ($windowStart + 5) } | ForEach-Object { $_.$Column })
            if ($values.Count -eq 0) { $ok = $false; break }
            $mean = ($values | Measure-Object -Average).Average
            if ([Math]::Abs($mean - $TailMean) -gt $Tolerance) { $ok = $false; break }
        }
        if ($ok) { return $t }
    }
    return $null
}
function Get-SpikeNoise([object[]]$Rows, [string]$Column, [double]$TailMedian) {
    $aboveHalf = 0
    $aboveOne = 0
    $aboveTwo = 0
    $jumpHalf = 0
    $jumpOne = 0
    $jumpTwo = 0
    $maxValue = 0.0
    $maxJump = 0.0
    $previous = $null
    foreach ($row in $Rows) {
        $value = [double]$row.$Column
        if ($value -gt $maxValue) { $maxValue = $value }
        if ($value -gt $TailMedian + 0.5) { $aboveHalf++ }
        if ($value -gt $TailMedian + 1.0) { $aboveOne++ }
        if ($value -gt $TailMedian + 2.0) { $aboveTwo++ }
        if ($null -ne $previous) {
            $jump = $value - $previous
            if ($jump -gt $maxJump) { $maxJump = $jump }
            if ($jump -gt 0.5) { $jumpHalf++ }
            if ($jump -gt 1.0) { $jumpOne++ }
            if ($jump -gt 2.0) { $jumpTwo++ }
        }
        $previous = $value
    }
    [pscustomobject]@{
        overHalfMsPerSecond = [Math]::Round($aboveHalf / 60.0, 2)
        overOneMsPerSecond = [Math]::Round($aboveOne / 60.0, 2)
        overTwoMsPerSecond = [Math]::Round($aboveTwo / 60.0, 2)
        positiveJumpsOverHalfMsPerSecond = [Math]::Round($jumpHalf / 60.0, 2)
        positiveJumpsOverOneMsPerSecond = [Math]::Round($jumpOne / 60.0, 2)
        positiveJumpsOverTwoMsPerSecond = [Math]::Round($jumpTwo / 60.0, 2)
        maxMs = [Math]::Round($maxValue, 3)
        maxPositiveJumpMs = [Math]::Round($maxJump, 3)
    }
}
function Get-BaselineStability([object[]]$Rows, [string]$Column) {
    $allWindows = @()
    foreach ($start in 0..55) {
        $values = @($Rows | Where-Object { $_.relative -ge $start -and $_.relative -lt ($start + 5) } | ForEach-Object { $_.$Column })
        if ($values.Count -eq 0) { continue }
        $stats = Get-Stats ([double[]]$values)
        $allWindows += [pscustomobject]@{
            startSecond = $start
            medianMs = [Math]::Round($stats.median, 3)
            p95Ms = [Math]::Round($stats.p95, 3)
            p99Ms = [Math]::Round($stats.p99, 3)
            maxMs = [Math]::Round($stats.max, 3)
        }
    }
    $windows = @()
    foreach ($start in 40,45,50,55) {
        $values = @($Rows | Where-Object { $_.relative -ge $start -and $_.relative -lt ($start + 5) } | ForEach-Object { $_.$Column })
        if ($values.Count -eq 0) { continue }
        $stats = Get-Stats ([double[]]$values)
        $sorted = [double[]]($values | Sort-Object)
        $trimStart = [Math]::Floor($sorted.Count * 0.10)
        $trimEnd = [Math]::Ceiling($sorted.Count * 0.90) - 1
        $trimmed = if ($trimEnd -ge $trimStart) { [double[]]$sorted[$trimStart..$trimEnd] } else { $sorted }
        $windows += [pscustomobject]@{
            startSecond = $start
            medianMs = [Math]::Round($stats.median, 3)
            trimmedMeanMs = [Math]::Round((($trimmed | Measure-Object -Average).Average), 3)
            p95Ms = [Math]::Round($stats.p95, 3)
            p99Ms = [Math]::Round($stats.p99, 3)
            maxMs = [Math]::Round($stats.max, 3)
        }
    }
    $tailMedianValues = @($windows | ForEach-Object { $_.medianMs })
    $tailMedian = if ($tailMedianValues.Count -gt 0) { ($tailMedianValues | Measure-Object -Average).Average } else { $null }
    $threshold = 0.75
    $settledAt = $null
    if ($null -ne $tailMedian) {
        foreach ($candidate in 0..50) {
            $remaining = @($allWindows | Where-Object { $_.startSecond -ge $candidate -and $_.startSecond -le 55 })
            if ($remaining.Count -lt 2) { continue }
            $outside = @($remaining | Where-Object { [Math]::Abs($_.medianMs - $tailMedian) -gt $threshold })
            if ($outside.Count -eq 0) {
                $settledAt = $candidate
                break
            }
        }
    }
    if ($windows.Count -lt 4) {
        return [pscustomobject]@{stable=$false;reason='missing last-20s windows';settledAtSecond=$null;medianRangeMs=$null;windows=$windows;allWindows=$allWindows}
    }
    $medianValues = @($windows | ForEach-Object { $_.medianMs })
    $range = (($medianValues | Measure-Object -Maximum).Maximum - ($medianValues | Measure-Object -Minimum).Minimum)
    [pscustomobject]@{
        stable = ($range -le $threshold)
        rule = 'scan whole 60s; settled when all later 5s medians stay within 0.75 ms of the final-20s median baseline'
        settledAtSecond = $settledAt
        final20MedianBaselineMs = [Math]::Round($tailMedian, 3)
        medianRangeMs = [Math]::Round($range, 3)
        thresholdMs = $threshold
        windows = $windows
        allWindows = $allWindows
    }
}
function Get-TailSpikeNoise([object[]]$Rows, [string]$Column, [double]$TailMedian) {
    $result = Get-SpikeNoise $Rows $Column $TailMedian
    $scale = [Math]::Max(1.0, 60.0 / 10.0)
    $result.overHalfMsPerSecond = [Math]::Round($result.overHalfMsPerSecond * $scale, 2)
    $result.overOneMsPerSecond = [Math]::Round($result.overOneMsPerSecond * $scale, 2)
    $result.overTwoMsPerSecond = [Math]::Round($result.overTwoMsPerSecond * $scale, 2)
    $result.positiveJumpsOverHalfMsPerSecond = [Math]::Round($result.positiveJumpsOverHalfMsPerSecond * $scale, 2)
    $result.positiveJumpsOverOneMsPerSecond = [Math]::Round($result.positiveJumpsOverOneMsPerSecond * $scale, 2)
    $result.positiveJumpsOverTwoMsPerSecond = [Math]::Round($result.positiveJumpsOverTwoMsPerSecond * $scale, 2)
    return $result
}
function Get-SingleSpikeFrequency([object[]]$Rows, [string]$Column, [double]$TailMedian) {
    $threshold = $TailMedian + 2.0
    $count = 0
    for ($i = 1; $i -lt ($Rows.Count - 1); $i++) {
        $previous = [double]$Rows[$i - 1].$Column
        $current = [double]$Rows[$i].$Column
        $next = [double]$Rows[$i + 1].$Column
        if ($current -ge $threshold -and $previous -lt $threshold -and $next -lt $threshold) {
            $count++
        }
    }
    [pscustomobject]@{
        thresholdMs = [Math]::Round($threshold, 3)
        count = $count
        frequencyPerSecond = [Math]::Round($count / 10.0, 2)
    }
}
function Get-SpikeGroups([object[]]$Rows, [string]$Column, [double]$TailMedian) {
    $threshold = $TailMedian + 2.0
    $groups = @()
    $current = $null
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $row = $Rows[$i]
        $value = [double]$row.$Column
        if ($value -ge $threshold) {
            if (!$current) {
                $current = [ordered]@{
                    startRelative = [double]$row.relative
                    endRelative = [double]$row.relative
                    samples = 0
                    peakMs = $value
                }
            }
            $current.samples++
            $current.endRelative = [double]$row.relative
            if ($value -gt $current.peakMs) { $current.peakMs = $value }
        } elseif ($current) {
            $groups += [pscustomobject]$current
            $current = $null
        }
    }
    if ($current) {
        $groups += [pscustomobject]$current
    }
    $sampleCount = 0
    foreach ($group in $groups) { $sampleCount += [int]$group.samples }
    $maxSamples = if ($groups.Count -gt 0) { (@($groups | ForEach-Object { [int]$_.samples }) | Measure-Object -Maximum).Maximum } else { 0 }
    $maxPeak = if ($groups.Count -gt 0) { (@($groups | ForEach-Object { [double]$_.peakMs }) | Measure-Object -Maximum).Maximum } else { $null }
    [pscustomobject]@{
        thresholdMs = [Math]::Round($threshold, 3)
        groupCount = $groups.Count
        frequencyPerSecond = [Math]::Round($groups.Count / 10.0, 2)
        sampleCount = $sampleCount
        dutyPercent = if ($Rows.Count -gt 0) { [Math]::Round(($sampleCount * 100.0) / $Rows.Count, 2) } else { 0.0 }
        maxGroupSamples = $maxSamples
        maxPeakMs = if ($null -ne $maxPeak) { [Math]::Round($maxPeak, 3) } else { $null }
        groups = $groups
    }
}
function Get-WindowRows([object[]]$Rows, [datetime]$OriginUtc) {
    @($Rows | ForEach-Object {
        $relative = ($_.utc - $OriginUtc).TotalSeconds
        if ($relative -ge 0 -and $relative -lt 60) {
            [pscustomobject]@{relative=$relative;cpu=$_.cpu;gpu=$_.gpu}
        }
    })
}
function Get-HealthVerdict([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return 'health receipt missing' }
    $payload = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).data.content[0]
    $record = $payload.record
    if (!$record) { return 'record missing' }
    $runtimeRouting = if ($record.runtimeRouting) { $record.runtimeRouting } else { $payload.status.runtimeRouting }
    $controllerApplied = if ($record.controller -and $record.controller.applied) { $record.controller.applied } else { $payload.status.controller.applied }
    $gates = @($record.acceptance.gates)
    $allowedStretch = $record.presentationPath.allowedPresentationStretch
    $nativePresentationExpected = $false
    if ($runtimeRouting -and $runtimeRouting.renderScaleRequested -eq $false -and $runtimeRouting.presentationUpscalingActive -eq $false) {
        $nativePresentationExpected = $true
    } elseif ($controllerApplied -and $controllerApplied.renderScaleMode -eq $false -and $controllerApplied.qualityMode -eq 0) {
        $nativePresentationExpected = $true
    }
    $backend = if ($controllerApplied -and $controllerApplied.backend) { [string]$controllerApplied.backend } elseif ($runtimeRouting -and $runtimeRouting.runtimeMethod) { [string]$runtimeRouting.runtimeMethod } else { 'unknown' }
    $quality = if ($controllerApplied -and $null -ne $controllerApplied.qualityMode) { [int]$controllerApplied.qualityMode } elseif ($runtimeRouting -and $null -ne $runtimeRouting.runtimeQualityMode) { [int]$runtimeRouting.runtimeQualityMode } else { -1 }
    $mode = if ($nativePresentationExpected) {
        'Native/no render-scale (None/q0)'
    } elseif ($controllerApplied -and $controllerApplied.active -eq $true) {
        "$($backend.ToUpperInvariant())/q$quality active"
    } else {
        "$($backend.ToUpperInvariant())/q$quality selected"
    }
    $hardFailures = @()
    $stretchActiveAtStop = $false
    $incompleteStereoAtStop = $false
    $stretchSummary = 'no stretch'
    if ($allowedStretch) {
        $stretchActiveAtStop = ($allowedStretch.activeAtStop -eq $true -or $allowedStretch.episodeActive -eq $true)
        $incompleteStereoAtStop = ($allowedStretch.incompleteStereoCycleAtStop -eq $true)
        if (($allowedStretch.completedEpisodes -as [int]) -gt 0) {
            $stretchSummary = "stretch completed $($allowedStretch.completedFrames)f/$([Math]::Round([double]$allowedStretch.completedMilliseconds, 1))ms"
            if ($stretchActiveAtStop) {
                $stretchSummary += '; still active at stop'
            } else {
                $stretchSummary += '; ended before stop'
            }
        } elseif ($stretchActiveAtStop) {
            $stretchSummary = 'stretch still active at stop'
        }
    }
    if ($stretchActiveAtStop -or ($gates | Where-Object { $_.name -eq 'presentation_stretch_inactive_at_stop' -and -not $_.passed })) { $hardFailures += 'active stretch at measurement stop' }
    if ($incompleteStereoAtStop -or ($gates | Where-Object { $_.name -eq 'presentation_stretch_complete_stereo_at_stop' -and -not $_.passed })) { $hardFailures += 'incomplete stereo at measurement stop' }
    if ($gates | Where-Object { $_.name -in @('retirement_drained','vendor_lifecycle_mutation_released') -and -not $_.passed }) { $hardFailures += 'retirement/release debt' }
    $backendReadyGate = @($gates | Where-Object { $_.name -eq 'backend_ready' }) | Select-Object -Last 1
    $presentationRecoveredGate = @($gates | Where-Object { $_.name -eq 'presentation_recovered' }) | Select-Object -Last 1
    if (!$nativePresentationExpected -and $backendReadyGate -and -not $backendReadyGate.passed) {
        $hardFailures += 'backend not ready'
    }
    if (!$nativePresentationExpected -and $presentationRecoveredGate -and -not $presentationRecoveredGate.passed) {
        $hardFailures += 'presentation not recovered'
    }
    if ($record.failures -and @($record.failures).Count -gt 0) { $hardFailures += 'producer failures' }
    $metrics = @($record.metrics)
    $completed = @($metrics | Where-Object { $_.completed -and !$_.superseded })
    $superseded = @($metrics | Where-Object { $_.superseded })
    if ($hardFailures.Count -gt 0) { return "FAIL hard gates: $($hardFailures -join ', ')" }
    $stereoSummary = if ($incompleteStereoAtStop) { 'stereo incomplete at stop' } else { 'stereo complete at stop' }
    $presentationSummary = if ($nativePresentationExpected) {
        'native presentation expected'
    } elseif (!$presentationRecoveredGate -or $presentationRecoveredGate.passed) {
        'presentation recovered'
    } else {
        'presentation not recovered'
    }
    $debtSummary = 'no owner/retirement debt'
    if ($completed.Count -gt 0) {
        $latest = $completed | Sort-Object stableFrame | Select-Object -Last 1
        $note = if ($superseded.Count -gt 0) { "; retained $($superseded.Count) superseded metric(s)" } else { '' }
        return "$mode; settled metric $($latest.totalFrames)f to stableFrame $($latest.stableFrame); $presentationSummary; $stretchSummary; $stereoSummary; $debtSummary$note"
    }
    $presentationRecovered = ($nativePresentationExpected -or !$presentationRecoveredGate -or $presentationRecoveredGate.passed)
    $backendReady = (!$backendReadyGate -or $backendReadyGate.passed)
    $relatchedAfterStretch = $false
    if ($controllerApplied -and
        $controllerApplied.valid -eq $true -and
        $controllerApplied.origin -eq 'recovery_relatch' -and
        $allowedStretch -and
        (($allowedStretch.completedEpisodes -as [int]) -gt 0) -and
        -not $stretchActiveAtStop -and
        -not $incompleteStereoAtStop -and
        $presentationRecovered -and
            $backendReady) {
        $relatchedAfterStretch = $true
    }
    if ($relatchedAfterStretch) {
        return "$mode; recovery_relatch applied after stretch; metric duration unavailable; $presentationSummary; $stretchSummary; $stereoSummary; $debtSummary"
    }
    return "$mode; no completed metric or recovery relatch; $presentationSummary; $stretchSummary; $stereoSummary; $debtSummary"
}
function Get-SettlingEvidence([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { return $null }
    $payload = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).data.content[0]
    $record = $payload.record
    if (!$record) { return $null }
    $metrics = @($record.metrics)
    $completed = @($metrics | Where-Object { $_.completed -and !$_.superseded })
    if ($completed.Count -eq 0) {
        $controllerApplied = if ($record.controller -and $record.controller.applied) { $record.controller.applied } else { $payload.status.controller.applied }
        $runtimeRouting = if ($record.runtimeRouting) { $record.runtimeRouting } else { $payload.status.runtimeRouting }
        $allowedStretch = $record.presentationPath.allowedPresentationStretch
        $gates = @($record.acceptance.gates)
        $presentationRecoveredGate = @($gates | Where-Object { $_.name -eq 'presentation_recovered' }) | Select-Object -Last 1
        $backendReadyGate = @($gates | Where-Object { $_.name -eq 'backend_ready' }) | Select-Object -Last 1
        $nativePresentationExpected = $false
        if ($runtimeRouting -and $runtimeRouting.renderScaleRequested -eq $false -and $runtimeRouting.presentationUpscalingActive -eq $false) {
            $nativePresentationExpected = $true
        } elseif ($controllerApplied -and $controllerApplied.renderScaleMode -eq $false -and $controllerApplied.qualityMode -eq 0) {
            $nativePresentationExpected = $true
        }
        $stretchActiveAtStop = $false
        $incompleteStereoAtStop = $false
        if ($allowedStretch) {
            $stretchActiveAtStop = ($allowedStretch.activeAtStop -eq $true -or $allowedStretch.episodeActive -eq $true)
            $incompleteStereoAtStop = ($allowedStretch.incompleteStereoCycleAtStop -eq $true)
        }
        if ($stretchActiveAtStop) {
            return [pscustomobject]@{available=$false;reason='still in stretch at measurement stop; no completed transition metric'}
        }
        if ($incompleteStereoAtStop) {
            return [pscustomobject]@{available=$false;reason='incomplete stereo cycle at measurement stop; no completed transition metric'}
        }
        $presentationRecovered = ($nativePresentationExpected -or !$presentationRecoveredGate -or $presentationRecoveredGate.passed)
        $backendReady = (!$backendReadyGate -or $backendReadyGate.passed)
        if ($controllerApplied -and
            $controllerApplied.valid -eq $true -and
            $controllerApplied.origin -eq 'recovery_relatch' -and
            $allowedStretch -and
            (($allowedStretch.completedEpisodes -as [int]) -gt 0) -and
            $presentationRecovered -and
            $backendReady) {
            return [pscustomobject]@{
                available = $true
                kind = 'post_stretch_recovery_relatch'
                summary = "settled after completed stretch via recovery_relatch; no metric duration; $($controllerApplied.backend)/q$($controllerApplied.qualityMode)"
                requestId = $controllerApplied.requestID
                transitionEpoch = $controllerApplied.transitionEpoch
                contractGeneration = $controllerApplied.contractGeneration
                method = $controllerApplied.method
                backend = $controllerApplied.backend
                qualityMode = $controllerApplied.qualityMode
                requestedFrame = $null
                stableFrame = $controllerApplied.queuedFrame
                totalFrames = $null
                settlingMilliseconds = $null
                stretchFrames = $allowedStretch.completedFrames
                stretchMilliseconds = $allowedStretch.completedMilliseconds
            }
        }
        return [pscustomobject]@{available=$false;reason='no completed transition metric'}
    }
    $metric = $completed | Sort-Object stableFrame | Select-Object -Last 1
    $preparation = if ($record.preparation) { $record.preparation } else { $payload.status.preparation }
    $retryTelemetry = if ($record.retryTelemetry) { $record.retryTelemetry } else { $payload.status.retryTelemetry }
    $requestEvent = @($preparation.events | Where-Object {
        $_.event -eq 'request_queued' -and
        $_.requestId -eq $metric.requestID -and
        $_.transitionEpoch -eq $metric.transitionEpoch
    }) | Select-Object -First 1
    $stableEvent = @($retryTelemetry.events | Where-Object {
        $_.event -eq 'Stable' -and
        $_.requestId -eq $metric.requestID -and
        $_.transitionEpoch -eq $metric.transitionEpoch
    }) | Select-Object -Last 1
    $settlingMilliseconds = $null
    if ($requestEvent -and $stableEvent -and $retryTelemetry.qpcFrequency -gt 0) {
        $settlingMilliseconds = [Math]::Round((($stableEvent.timestampQpc - $requestEvent.beginQpc) * 1000.0) / $retryTelemetry.qpcFrequency, 1)
    }
    [pscustomobject]@{
        available = $true
        kind = 'transition_metric'
        summary = "$($metric.totalFrames) frame(s), $settlingMilliseconds ms, $($metric.backend)/q$($metric.qualityMode)"
        requestId = $metric.requestID
        transitionEpoch = $metric.transitionEpoch
        contractGeneration = $metric.contractGeneration
        method = $metric.method
        backend = $metric.backend
        qualityMode = $metric.qualityMode
        requestedFrame = $metric.requestedFrame
        stableFrame = $metric.stableFrame
        totalFrames = $metric.totalFrames
        settlingMilliseconds = $settlingMilliseconds
    }
}
function Get-ModeText($Applied, $Routing) {
    $native = $false
    if ($Routing -and $Routing.renderScaleRequested -eq $false -and $Routing.presentationUpscalingActive -eq $false) {
        $native = $true
    } elseif ($Applied -and $Applied.renderScaleMode -eq $false -and $Applied.qualityMode -eq 0) {
        $native = $true
    }
    if ($native) { return 'Native/no render-scale' }
    $backend = if ($Applied -and $Applied.backend) { [string]$Applied.backend } elseif ($Routing -and $Routing.runtimeMethod) { [string]$Routing.runtimeMethod } else { 'unknown' }
    $quality = if ($Applied -and $null -ne $Applied.qualityMode) { [int]$Applied.qualityMode } elseif ($Routing -and $null -ne $Routing.runtimeQualityMode) { [int]$Routing.runtimeQualityMode } else { -1 }
    return "$($backend.ToUpperInvariant())/q$quality"
}
function Get-GatePassed($Gates, [string]$Name) {
    $gate = @($Gates | Where-Object { $_.name -eq $Name }) | Select-Object -Last 1
    if (!$gate) { return $null }
    return ($gate.passed -eq $true)
}
function Get-LifecycleEvidence([int]$Index, [datetime]$EntryUtc) {
    $files = @(Get-ChildItem -LiteralPath $RunDirectory -Filter "save-$Index-health*.json" |
        Where-Object { $_.Name -notlike '*start.json' } |
        Sort-Object {
            if ($_.Name -match 'health-(\d+)') { [int]$Matches[1] }
            elseif ($_.Name -match 'stop') { 60 }
            else { -1 }
        })
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ summary = 'health snapshots missing'; samples = @() }
    }
    $samples = @()
    foreach ($file in $files) {
        $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        $payload = $json.data.content[0]
        $record = $payload.record
        $status = $payload.status
        if (!$record -or !$status) { continue }
        $timestampUtc = ConvertTo-UtcDateTime $json.timestampUtc
        $applied = $status.controller.applied
        $routing = $status.runtimeRouting
        $gates = @($record.acceptance.gates)
        $allowedStretch = $record.presentationPath.allowedPresentationStretch
        $completedMetrics = @($record.metrics | Where-Object { $_.completed -and -not $_.superseded })
        $latestMetric = $completedMetrics | Sort-Object stableFrame | Select-Object -Last 1
        $sampleSecond = if ($file.Name -match 'health-(\d+)') { [int]$Matches[1] } elseif ($file.Name -match 'stop') { 60 } else { [int][Math]::Round(($timestampUtc - $EntryUtc).TotalSeconds) }
        $samples += [pscustomobject]@{
            file = $file.Name
            sampleSecond = $sampleSecond
            observedAfterWorldEntrySeconds = [Math]::Round(($timestampUtc - $EntryUtc).TotalSeconds, 3)
            mode = Get-ModeText $applied $routing
            backend = $applied.backend
            method = $applied.method
            qualityMode = $applied.qualityMode
            active = $applied.active
            valid = $applied.valid
            origin = $applied.origin
            requestId = $applied.requestID
            transitionEpoch = $applied.transitionEpoch
            contractGeneration = $applied.contractGeneration
            queuedFrame = $applied.queuedFrame
            nativePresentationExpected = ($routing.renderScaleRequested -eq $false -and $routing.presentationUpscalingActive -eq $false) -or ($applied.renderScaleMode -eq $false -and $applied.qualityMode -eq 0)
            completedMetricCount = $completedMetrics.Count
            metricFrames = if ($latestMetric) { $latestMetric.totalFrames } else { $null }
            metricStableFrame = if ($latestMetric) { $latestMetric.stableFrame } else { $null }
            stretchEpisodes = if ($allowedStretch) { $allowedStretch.episodes } else { $null }
            completedStretchEpisodes = if ($allowedStretch) { $allowedStretch.completedEpisodes } else { $null }
            stretchCompletedFrames = if ($allowedStretch) { $allowedStretch.completedFrames } else { $null }
            stretchCompletedMilliseconds = if ($allowedStretch) { $allowedStretch.completedMilliseconds } else { $null }
            stretchActiveAtStop = if ($allowedStretch) { ($allowedStretch.activeAtStop -eq $true -or $allowedStretch.episodeActive -eq $true) } else { $null }
            incompleteStereoAtStop = if ($allowedStretch) { $allowedStretch.incompleteStereoCycleAtStop -eq $true } else { $null }
            presentationRecovered = Get-GatePassed $gates 'presentation_recovered'
            backendReady = Get-GatePassed $gates 'backend_ready'
            retirementDrained = Get-GatePassed $gates 'retirement_drained'
            lifecycleReleased = Get-GatePassed $gates 'vendor_lifecycle_mutation_released'
        }
    }
    if ($samples.Count -eq 0) {
        return [pscustomobject]@{ summary = 'health snapshots missing usable records'; samples = @() }
    }
    $first = $samples | Sort-Object sampleSecond | Select-Object -First 1
    $final = $samples | Sort-Object sampleSecond | Select-Object -Last 1
    $firstMetric = $samples | Where-Object { $_.completedMetricCount -gt 0 } | Sort-Object sampleSecond | Select-Object -First 1
    $firstRecovery = $samples | Where-Object { $_.origin -eq 'recovery_relatch' } | Sort-Object sampleSecond | Select-Object -First 1
    $firstStretchStarted = $samples | Where-Object { ($_.stretchEpisodes -as [int]) -gt 0 } | Sort-Object sampleSecond | Select-Object -First 1
    $firstStretchCompleted = $samples | Where-Object { ($_.completedStretchEpisodes -as [int]) -gt 0 } | Sort-Object sampleSecond | Select-Object -First 1
    $parts = @()
    $parts += "$($first.mode) observed by +$($first.sampleSecond)s"
    if ($first.active -eq $true -or $first.nativePresentationExpected) {
        $parts += 'mode already applied at first health sample'
    } else {
        $parts += 'mode not yet applied at first health sample'
    }
    if ($firstMetric) {
        $duration = Get-SettlingEvidence (Join-Path $RunDirectory "save-$Index-health-stop.json")
        $metricText = if ($duration -and $duration.settlingMilliseconds -ne $null) {
            "$($firstMetric.metricFrames)f/$($duration.settlingMilliseconds)ms"
        } else {
            "$($firstMetric.metricFrames)f"
        }
        $parts += "completed latch metric observed by +$($firstMetric.sampleSecond)s ($metricText)"
    } elseif ($firstRecovery) {
        $parts += "recovery_relatch observed by +$($firstRecovery.sampleSecond)s; metric duration unavailable"
    } else {
        $parts += 'no completed latch metric or recovery relatch observed'
    }
    if ($firstStretchStarted) {
        if ($firstStretchCompleted) {
            $parts += "stretch started by +$($firstStretchStarted.sampleSecond)s and completed by +$($firstStretchCompleted.sampleSecond)s ($($firstStretchCompleted.stretchCompletedFrames)f/$([Math]::Round([double]$firstStretchCompleted.stretchCompletedMilliseconds, 1))ms)"
        } else {
            $parts += "stretch started by +$($firstStretchStarted.sampleSecond)s and had not completed in captured health samples"
        }
    } else {
        $parts += 'no stretch observed'
    }
    $finalOk = $false
    if ($final.nativePresentationExpected) {
        $finalOk = ($final.valid -eq $true -and $final.backendReady -ne $false -and $final.retirementDrained -ne $false -and $final.lifecycleReleased -ne $false -and $final.stretchActiveAtStop -ne $true -and $final.incompleteStereoAtStop -ne $true)
    } else {
        $finalOk = ($final.active -eq $true -and $final.valid -eq $true -and $final.presentationRecovered -ne $false -and $final.backendReady -ne $false -and $final.retirementDrained -ne $false -and $final.lifecycleReleased -ne $false -and $final.stretchActiveAtStop -ne $true -and $final.incompleteStereoAtStop -ne $true)
    }
    if ($finalOk) {
        $parts += "final +$($final.sampleSecond)s successful: $($final.mode), stretch inactive, stereo complete, no owner/retirement debt"
    } else {
        $fail = @()
        if ($final.stretchActiveAtStop -eq $true) { $fail += 'stretch still active' }
        if ($final.incompleteStereoAtStop -eq $true) { $fail += 'stereo incomplete' }
        if ($final.backendReady -eq $false -and -not $final.nativePresentationExpected) { $fail += 'backend not ready' }
        if ($final.presentationRecovered -eq $false -and -not $final.nativePresentationExpected) { $fail += 'presentation not recovered' }
        if ($final.retirementDrained -eq $false -or $final.lifecycleReleased -eq $false) { $fail += 'owner/retirement debt' }
        if ($final.valid -ne $true) { $fail += 'invalid controller state' }
        if ($fail.Count -eq 0) { $fail += 'unknown final-state failure' }
        $parts += "final +$($final.sampleSecond)s NOT successful: $($fail -join ', ')"
    }
    [pscustomobject]@{
        summary = ($parts -join '; ')
        firstSample = $first
        firstCompletedMetric = $firstMetric
        firstRecoveryRelatch = $firstRecovery
        firstStretchStarted = $firstStretchStarted
        firstStretchCompleted = $firstStretchCompleted
        finalSample = $final
        finalSuccessful = $finalOk
        samples = $samples
    }
}
if (!$FpsVrCsv) {
    $archiveReceipt = Join-Path $RunDirectory 'fpsvr-archive.json'
    if (Test-Path -LiteralPath $archiveReceipt) {
        $receipt = Get-Content -LiteralPath $archiveReceipt -Raw | ConvertFrom-Json
        $FpsVrCsv = if ($receipt.archivePath) { $receipt.archivePath } else { $receipt.archive }
    }
}
if (!$FpsVrCsv -or !(Test-Path -LiteralPath $FpsVrCsv)) { throw 'fpsVR CSV not found. Pass -FpsVrCsv or archive it first.' }
$lines = Get-Content -LiteralPath $FpsVrCsv
$headerUtc = [datetime]::Parse(($lines[1] -split '/',4)[3]).ToUniversalTime()
$rows = @()
for ($i = 3; $i -lt $lines.Count; $i++) {
    if (!$lines[$i].Trim()) { continue }
    $parts = $lines[$i] | ConvertFrom-Csv -Header 'SteamVR Time','FPS','GPU frametime','CPU frametime','GPU Usage','CPU Usage'
    $steam = [double]$parts.'SteamVR Time'
    if ($rows.Count -eq 0) { $firstSteam = $steam }
    $rows += [pscustomobject]@{
        utc = $headerUtc.AddSeconds($steam - $firstSteam)
        gpu = [double]$parts.'GPU frametime'
        cpu = [double]$parts.'CPU frametime'
    }
}
$markers = @(Read-Markers)
$summary = @()
$worldEntries = @($markers | Where-Object { $_.label -match '^save-\d+-world-entry$' } | Sort-Object elapsedSeconds)
$saveIndexes = @($worldEntries | ForEach-Object { [int](($_.label -replace '^save-','') -replace '-world-entry$','') } | Sort-Object -Unique)
foreach ($index in $saveIndexes) {
    $entry = $markers | Where-Object { $_.label -eq "save-$index-world-entry" } | Select-Object -Last 1
    if (!$entry) {
        $summary += [pscustomobject]@{save="save-$index";status='missing world-entry marker'}
        continue
    }
    $originUtc = ConvertTo-UtcDateTime $entry.utc
    $window = Get-WindowRows $rows $originUtc
    $tail = @($window | Where-Object { $_.relative -ge 50 -and $_.relative -lt 60 })
    $cpuTail = Get-Stats ([double[]]@($tail | ForEach-Object { $_.cpu }))
    $gpuTail = Get-Stats ([double[]]@($tail | ForEach-Object { $_.gpu }))
    $cpuStrictTolerance = [Math]::Max(0.10, 0.02 * $cpuTail.mean)
    $gpuStrictTolerance = [Math]::Max(0.10, 0.02 * $gpuTail.mean)
    $cpuPracticalTolerance = [Math]::Max(0.25, 0.03 * $cpuTail.mean)
    $gpuPracticalTolerance = [Math]::Max(0.25, 0.03 * $gpuTail.mean)
    $cpuSpikes = Get-SpikeNoise $window 'cpu' $cpuTail.median
    $gpuSpikes = Get-SpikeNoise $window 'gpu' $gpuTail.median
    $cpuTailSpikes = Get-TailSpikeNoise $tail 'cpu' $cpuTail.median
    $gpuTailSpikes = Get-TailSpikeNoise $tail 'gpu' $gpuTail.median
    $cpuSingleSpikes = Get-SingleSpikeFrequency $tail 'cpu' $cpuTail.median
    $gpuSingleSpikes = Get-SingleSpikeFrequency $tail 'gpu' $gpuTail.median
    $cpuSpikeGroups = Get-SpikeGroups $tail 'cpu' $cpuTail.median
    $gpuSpikeGroups = Get-SpikeGroups $tail 'gpu' $gpuTail.median
    $cpuBaseline = Get-BaselineStability $window 'cpu'
    $gpuBaseline = Get-BaselineStability $window 'gpu'
    $health = Get-HealthVerdict (Join-Path $RunDirectory "save-$index-health-stop.json")
    $settling = Get-SettlingEvidence (Join-Path $RunDirectory "save-$index-health-stop.json")
    $lifecycle = Get-LifecycleEvidence $index $originUtc
    $summary += [pscustomobject]@{
        save = "save-$index"
        name = $entry.detail.name
        location = $entry.detail.location
        samples = $window.Count
        cpuTailMeanMs = [Math]::Round($cpuTail.mean, 3)
        gpuTailMeanMs = [Math]::Round($gpuTail.mean, 3)
        cpuTailSdMs = [Math]::Round($cpuTail.sd, 3)
        gpuTailSdMs = [Math]::Round($gpuTail.sd, 3)
        cpuTailP95Ms = [Math]::Round($cpuTail.p95, 3)
        gpuTailP95Ms = [Math]::Round($gpuTail.p95, 3)
        cpuTailP99Ms = [Math]::Round($cpuTail.p99, 3)
        gpuTailP99Ms = [Math]::Round($gpuTail.p99, 3)
        cpuStrictStabilizationS = Get-Stabilization $window 'cpu' $cpuTail.mean $cpuStrictTolerance
        gpuStrictStabilizationS = Get-Stabilization $window 'gpu' $gpuTail.mean $gpuStrictTolerance
        cpuPracticalStabilizationS = Get-Stabilization $window 'cpu' $cpuTail.mean $cpuPracticalTolerance
        gpuPracticalStabilizationS = Get-Stabilization $window 'gpu' $gpuTail.mean $gpuPracticalTolerance
        gpuSettlingS = Get-Stabilization $window 'gpu' $gpuTail.mean $gpuPracticalTolerance
        cpuSpikeNoise = $cpuSpikes
        gpuSpikeNoise = $gpuSpikes
        cpuTailSpikeNoise = $cpuTailSpikes
        gpuTailSpikeNoise = $gpuTailSpikes
        cpuSingleSpikeFrequency = $cpuSingleSpikes
        gpuSingleSpikeFrequency = $gpuSingleSpikes
        cpuSpikeGroups = $cpuSpikeGroups
        gpuSpikeGroups = $gpuSpikeGroups
        cpuBaselineStability = $cpuBaseline
        gpuBaselineStability = $gpuBaseline
        renderSettling = $settling
        health = if ($lifecycle -and $lifecycle.summary) { $lifecycle.summary } else { $health }
        stopStateHealth = $health
        lifecycle = $lifecycle
    }
}
$summaryPath = Join-Path $RunDirectory 'quick-summary.json'
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath
$summary | Format-Table -AutoSize
Write-Output "Quick summary saved: $summaryPath"
