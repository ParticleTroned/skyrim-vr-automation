# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory)][string]$ContextJson,
    [ValidateRange(3, 10000)][int]$Samples = 120,
    [ValidateRange(0, 100)][int]$WarmupSamples = 5,
    [ValidateRange(50, 60000)][int]$IntervalMs = 250,
    [ValidateRange(1, 30)][int]$FreshFrameTimeoutSeconds = 5,
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$DevBenchControlPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 80), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -Depth 80
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function ConvertTo-CanonicalValue($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $ordered[$key] = ConvertTo-CanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable]) { return @($Value | ForEach-Object { ConvertTo-CanonicalValue $_ }) }
    $properties = [ordered]@{}
    $names = [string[]]@($Value.PSObject.Properties.Name)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) { $properties[$name] = ConvertTo-CanonicalValue $Value.$name }
    return $properties
}

function Get-CanonicalHash($Value) {
    $json = (ConvertTo-CanonicalValue $Value) | ConvertTo-Json -Depth 80 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($json)))
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    return [double]$sorted[[Math]::Max(0, [Math]::Min($sorted.Count - 1, [Math]::Ceiling($Percentile * $sorted.Count) - 1))]
}

function Get-MetricSummary([double[]]$Values) {
    if ($Values.Count -eq 0) { return [pscustomobject][ordered]@{ count = 0; mean = $null; median = $null; p95 = $null; p99 = $null; min = $null; max = $null } }
    $measure = $Values | Measure-Object -Average -Minimum -Maximum
    return [pscustomobject][ordered]@{
        count = $Values.Count; mean = [double]$measure.Average
        median = Get-Percentile $Values 0.5; p95 = Get-Percentile $Values 0.95; p99 = Get-Percentile $Values 0.99
        min = [double]$measure.Minimum; max = [double]$measure.Maximum
    }
}

function Assert-Finite([double]$Value, [string]$Name) {
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw "Profiler metric '$Name' is not finite." }
}

if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.' }
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
$context = $ContextJson | ConvertFrom-Json -AsHashtable -Depth 40
if (-not $context.ContainsKey('environment') -or -not ($context.environment -is [Collections.IDictionary])) { throw 'ContextJson requires an environment object.' }
foreach ($required in @('mo2Profile', 'scene', 'hmdMode', 'renderResolution')) {
    if (-not $context.environment.ContainsKey($required) -or [string]::IsNullOrWhiteSpace([string]$context.environment[$required])) { throw "ContextJson environment requires '$required'." }
}
if (-not $context.ContainsKey('treatment')) { $context['treatment'] = [ordered]@{} }

$control = if ([string]::IsNullOrWhiteSpace($DevBenchControlPath)) { Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control\Invoke-DevBenchControl.ps1' } else { [IO.Path]::GetFullPath($DevBenchControlPath) }
if (-not (Test-Path -LiteralPath $control -PathType Leaf)) { throw "The central DevBench controller is unavailable: $control" }
$transactionId = [guid]::NewGuid().ToString('N')
$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
if ([string]::IsNullOrWhiteSpace($safeLabel)) { $safeLabel = 'capture' }
$runDirectory = Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) "profiler-$safeLabel-$transactionId"
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$receiptPath = Join-Path $runDirectory 'capture.receipt.json'
$receipt = [ordered]@{
    schemaVersion = 2; operation = 'measure-profiler'; transactionId = $transactionId; state = 'prepared'
    label = $Label; runtimePath = [IO.Path]::GetFullPath($RuntimePath); context = $context
    preparedUtc = [DateTime]::UtcNow.ToString('o'); priorEnabled = $null; finalEnabled = $null
    stateRestored = $false; restoreErrors = @(); captureError = $null
}
Write-JsonAtomic $receiptPath $receipt

function Invoke-ProfilerAction([string]$Action) {
    $arguments = @{ action = $Action } | ConvertTo-Json -Compress
    $call = & $control call -Tool 'communityshaders.profiler' -ArgumentsJson $arguments -RuntimePath $RuntimePath -EvidenceDirectory $runDirectory -EvidenceLabel "profiler-$Action" -RequireSuccess -NoExit -Compact | ConvertFrom-Json -Depth 80
    if (-not $call.ok) { throw "DevBench profiler '$Action' failed: $($call.errors -join '; ')" }
    $payload = @($call.data.content | Where-Object { $null -ne $_ } | Select-Object -First 1)
    if ($payload.Count -ne 1) { throw "DevBench profiler '$Action' returned no structured content." }
    return [pscustomobject][ordered]@{ payload = $payload[0]; runtimeIdentity = $call.runtimeIdentity; evidencePath = $call.invocationEvidencePath }
}

function Get-ProfilerStatus($Envelope) {
    $payload = $Envelope.payload
    $status = if ($payload.PSObject.Properties['status']) { $payload.status } else { $payload }
    if (-not $status.PSObject.Properties['frame_count']) { throw 'Profiler status omitted frame_count.' }
    return $status
}

function Get-ProfilerEnabled($Status) {
    foreach ($name in @('enabled', 'profilerEnabled', 'active')) {
        if ($Status.PSObject.Properties[$name]) { return [bool]$Status.$name }
    }
    throw 'Profiler status did not report its current enabled state; mutation is not authorized without a restorable preimage.'
}

$records = [Collections.Generic.List[object]]::new()
$runtimeIdentity = $null
$captureFailure = $null
$startedUtc = [DateTime]::UtcNow
try {
    $initialEnvelope = Invoke-ProfilerAction 'status'
    $initialStatus = Get-ProfilerStatus $initialEnvelope
    $runtimeIdentity = $initialEnvelope.runtimeIdentity
    $priorEnabled = Get-ProfilerEnabled $initialStatus
    $stableRuntimeIdentity = [ordered]@{
        listenerPid = $runtimeIdentity.listenerPid
        processPath = $runtimeIdentity.process.path
        processStartTimeUtc = $runtimeIdentity.process.startTimeUtc
        buildId = $runtimeIdentity.build.buildId
        artifactPath = $runtimeIdentity.artifact.path
        artifactSha256 = $runtimeIdentity.artifact.sha256
    }
    $receipt.priorEnabled = $priorEnabled
    $receipt.runtimeIdentity = $runtimeIdentity
    $receipt.stableRuntimeIdentity = $stableRuntimeIdentity
    $receipt.contextFingerprint = Get-CanonicalHash ([ordered]@{ environment = $context.environment; runtimeIdentity = $stableRuntimeIdentity })
    $receipt.treatmentFingerprint = Get-CanonicalHash $context.treatment
    $receipt.state = 'prior-state-recorded'
    Write-JsonAtomic $receiptPath $receipt
    if (-not $priorEnabled) { $null = Invoke-ProfilerAction 'enable' }
    $receipt.state = 'sampling'
    Write-JsonAtomic $receiptPath $receipt

    $lastFrame = [long]-1
    for ($warmup = 0; $warmup -lt $WarmupSamples; $warmup++) {
        $warmupStatus = Get-ProfilerStatus (Invoke-ProfilerAction 'status')
        $lastFrame = [Math]::Max($lastFrame, [long]$warmupStatus.frame_count)
        Start-Sleep -Milliseconds $IntervalMs
    }
    for ($sampleIndex = 1; $sampleIndex -le $Samples; $sampleIndex++) {
        $freshDeadline = [DateTime]::UtcNow.AddSeconds($FreshFrameTimeoutSeconds)
        do {
            $envelope = Invoke-ProfilerAction 'status'
            $status = Get-ProfilerStatus $envelope
            $frame = [long]$status.frame_count
            if ($frame -gt $lastFrame) { break }
            Start-Sleep -Milliseconds ([Math]::Min(50, $IntervalMs))
        } while ([DateTime]::UtcNow -lt $freshDeadline)
        if ($frame -le $lastFrame) { throw "Profiler did not advance beyond frame $lastFrame within $FreshFrameTimeoutSeconds seconds." }
        $resolvedTotal = [double]$status.resolvedTotalMs
        $resolvedCpuTotal = [double]$status.resolvedCpuTotalMs
        Assert-Finite $resolvedTotal 'resolvedTotalMs'
        Assert-Finite $resolvedCpuTotal 'resolvedCpuTotalMs'
        foreach ($timer in @($status.timers)) {
            foreach ($metric in @('gpuMs', 'topLevelMs', 'cpuMs')) {
                if ($timer.PSObject.Properties[$metric]) { Assert-Finite ([double]$timer.$metric) "$($timer.name).$metric" }
            }
        }
        $records.Add([pscustomobject][ordered]@{
            sample = $sampleIndex; timestampUtc = [DateTime]::UtcNow.ToString('o'); frame = $frame
            capturedFrame = [long]$status.capturedFrameCount; resolvedTotalMs = $resolvedTotal; resolvedCpuTotalMs = $resolvedCpuTotal
            acquiredSlots = [int]$status.acquiredSlots; slotRefusals = [int]$status.slotRefusals; timers = @($status.timers)
            invocationEvidencePath = $envelope.evidencePath
            contextFingerprint = $receipt.contextFingerprint; treatmentFingerprint = $receipt.treatmentFingerprint
        })
        $lastFrame = $frame
        if ($sampleIndex -lt $Samples) { Start-Sleep -Milliseconds $IntervalMs }
    }
}
catch {
    $captureFailure = $_.Exception.Message
    $receipt.captureError = $captureFailure
}
finally {
    $restoreErrors = [Collections.Generic.List[string]]::new()
    if ($null -ne $receipt.priorEnabled) {
        try {
            $finalStatus = Get-ProfilerStatus (Invoke-ProfilerAction 'status')
            $finalEnabled = Get-ProfilerEnabled $finalStatus
            if ($finalEnabled -ne [bool]$receipt.priorEnabled) {
                $null = Invoke-ProfilerAction $(if ($receipt.priorEnabled) { 'enable' } else { 'disable' })
                $finalStatus = Get-ProfilerStatus (Invoke-ProfilerAction 'status')
                $finalEnabled = Get-ProfilerEnabled $finalStatus
            }
            $receipt.finalEnabled = $finalEnabled
            $receipt.stateRestored = $finalEnabled -eq [bool]$receipt.priorEnabled
            if (-not $receipt.stateRestored) { $restoreErrors.Add('Profiler enable state did not return to its exact prior value.') }
        }
        catch { $restoreErrors.Add($_.Exception.Message) }
    }
    $receipt.restoreErrors = @($restoreErrors)
    $receipt.state = if ($restoreErrors.Count -gt 0) { 'recovery-required' } elseif ($captureFailure) { 'rolled-back' } else { 'completed' }
    $receipt.completedUtc = [DateTime]::UtcNow.ToString('o')
    Write-JsonAtomic $receiptPath $receipt
}

if ($receipt.restoreErrors.Count -gt 0) { throw "Profiler capture requires state recovery: $($receipt.restoreErrors -join '; '). Receipt: $receiptPath" }
if ($captureFailure) { throw "$captureFailure Profiler state was restored. Receipt: $receiptPath" }
if ($records.Count -ne $Samples -or @($records.frame | Sort-Object -Unique).Count -ne $Samples) { throw 'Profiler capture did not produce the requested number of unique fresh frames.' }

$endedUtc = [DateTime]::UtcNow
$timerRows = foreach ($record in $records) {
    foreach ($timer in $record.timers) {
        [pscustomobject][ordered]@{
            sample = $record.sample; timestampUtc = $record.timestampUtc; frame = $record.frame; name = [string]$timer.name
            activeGpu = [bool]$timer.activeGpu; activeCpu = [bool]$timer.activeCpu; hasGpu = [bool]$timer.hasGpu; hasCpu = [bool]$timer.hasCpu
            gpuMs = [double]$timer.gpuMs; topLevelMs = [double]$timer.topLevelMs; cpuMs = [double]$timer.cpuMs
        }
    }
}
$timerSummaries = foreach ($group in ($timerRows | Group-Object name | Sort-Object Name)) {
    $activeGpu = @($group.Group | Where-Object { $_.activeGpu -and $_.hasGpu })
    [pscustomobject][ordered]@{
        name = $group.Name; observedSamples = $group.Count; activeGpuSamples = $activeGpu.Count
        gpuMs = Get-MetricSummary ([double[]]@($activeGpu.gpuMs)); topLevelMs = Get-MetricSummary ([double[]]@($activeGpu.topLevelMs))
        cpuMs = Get-MetricSummary ([double[]]@($group.Group | Where-Object { $_.activeCpu -and $_.hasCpu } | ForEach-Object cpuMs))
    }
}
$summary = [pscustomobject][ordered]@{
    schemaVersion = 2; transactionId = $transactionId; label = $Label; startedUtc = $startedUtc.ToString('o'); endedUtc = $endedUtc.ToString('o')
    durationSeconds = ($endedUtc - $startedUtc).TotalSeconds; requestedSamples = $Samples; warmupSamples = $WarmupSamples; collectedSamples = $records.Count
    uniqueFreshFrames = @($records.frame | Sort-Object -Unique).Count; intervalMs = $IntervalMs; runtimeIdentity = $runtimeIdentity
    context = $context; contextFingerprint = $receipt.contextFingerprint; treatmentFingerprint = $receipt.treatmentFingerprint
    priorProfilerEnabled = $receipt.priorEnabled; profilerStateRestored = $receipt.stateRestored; receiptPath = $receiptPath
    resolvedTotalMs = Get-MetricSummary ([double[]]@($records.resolvedTotalMs)); resolvedCpuTotalMs = Get-MetricSummary ([double[]]@($records.resolvedCpuTotalMs))
    maxSlotRefusals = [int](($records | Measure-Object slotRefusals -Maximum).Maximum); timers = @($timerSummaries)
}
$rawPath = Join-Path $runDirectory "$safeLabel.raw.json"
$summaryPath = Join-Path $runDirectory "$safeLabel.summary.json"
$csvPath = Join-Path $runDirectory "$safeLabel.timers.csv"
Write-JsonAtomic $rawPath @($records)
Write-JsonAtomic $summaryPath $summary
$timerSummaries | ForEach-Object {
    [pscustomobject][ordered]@{ name = $_.name; observedSamples = $_.observedSamples; activeGpuSamples = $_.activeGpuSamples; gpuMeanMs = $_.gpuMs.mean; gpuMedianMs = $_.gpuMs.median; gpuP95Ms = $_.gpuMs.p95; gpuP99Ms = $_.gpuMs.p99; gpuMaxMs = $_.gpuMs.max; topLevelMeanMs = $_.topLevelMs.mean; cpuMeanMs = $_.cpuMs.mean }
} | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

[pscustomobject][ordered]@{ ok = $true; label = $Label; transactionId = $transactionId; rawPath = $rawPath; summaryPath = $summaryPath; csvPath = $csvPath; receiptPath = $receiptPath; summary = $summary } | ConvertTo-Json -Depth 80
