# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [ValidateRange(3, 10000)][int]$Samples = 120,
    [ValidateRange(0, 100)][int]$WarmupSamples = 5,
    [ValidateRange(50, 60000)][int]$IntervalMs = 250,
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-McpRequest {
    param([string]$Endpoint, [hashtable]$Headers, $Payload)
    $body = $Payload | ConvertTo-Json -Depth 30 -Compress
    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint -Headers $Headers -Body $body -TimeoutSec 15
    [pscustomobject]@{ response = $response; json = ($response.Content | ConvertFrom-Json -Depth 60) }
}

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

if ([string]::IsNullOrWhiteSpace($RuntimePath)) {
    throw 'RuntimePath is required. Pass -RuntimePath or set CSX_DEVBENCH_RUNTIME_PATH.'
}
if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) { throw "DevBench runtime metadata does not exist: $RuntimePath" }
$runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
$endpoint = "http://127.0.0.1:$([int]$runtime.port)/mcp"
$baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }

function Initialize-McpSession {
    $initialize = Invoke-McpRequest -Endpoint $endpoint -Headers $baseHeaders -Payload @{
        jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{
            protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = @{ name = 'CSXProfilerMeasure'; version = '1.1' }
        }
    }
    $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
    $script:headers = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $endpoint -Headers $script:headers -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSec 15 | Out-Null
}

Initialize-McpSession
$sessionReconnects = 0

function Invoke-ProfilerAction {
    param([string]$Action)
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $script:requestId++
            $rpc = Invoke-McpRequest -Endpoint $endpoint -Headers $script:headers -Payload @{
                jsonrpc = '2.0'; id = $script:requestId; method = 'tools/call'; params = @{
                    name = 'communityshaders.profiler'; arguments = @{ action = $Action }
                }
            }
            if ($rpc.json.PSObject.Properties['error']) { throw "Profiler RPC failed: $($rpc.json.error | ConvertTo-Json -Compress)" }
            if ($rpc.json.result.PSObject.Properties['isError'] -and $rpc.json.result.isError) {
                throw (($rpc.json.result.content | ForEach-Object { $_.text }) -join "`n")
            }
            return ($rpc.json.result.content[0].text | ConvertFrom-Json -Depth 60)
        }
        catch {
            if ($attempt -eq 0) {
                Initialize-McpSession
                $script:sessionReconnects++
                continue
            }
            throw
        }
    }
}

$requestId = 1
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$startedUtc = [DateTime]::UtcNow
$enableResult = Invoke-ProfilerAction -Action 'enable'
for ($warmupIndex = 1; $warmupIndex -le $WarmupSamples; $warmupIndex++) {
    Invoke-ProfilerAction -Action 'status' | Out-Null
    Start-Sleep -Milliseconds $IntervalMs
}
$records = [System.Collections.Generic.List[object]]::new()
for ($sampleIndex = 1; $sampleIndex -le $Samples; $sampleIndex++) {
    $response = Invoke-ProfilerAction -Action 'status'
    $status = $response.status
    $records.Add([pscustomobject][ordered]@{
        sample = $sampleIndex
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        frame = [long]$status.frame_count
        capturedFrame = [long]$status.capturedFrameCount
        resolvedTotalMs = [double]$status.resolvedTotalMs
        resolvedCpuTotalMs = [double]$status.resolvedCpuTotalMs
        acquiredSlots = [int]$status.acquiredSlots
        slotRefusals = [int]$status.slotRefusals
        timers = @($status.timers)
    })
    if ($sampleIndex -lt $Samples) { Start-Sleep -Milliseconds $IntervalMs }
}
$endedUtc = [DateTime]::UtcNow

$timerRows = [System.Collections.Generic.List[object]]::new()
foreach ($record in $records) {
    foreach ($timer in $record.timers) {
        $timerRows.Add([pscustomobject][ordered]@{
            sample = $record.sample
            timestampUtc = $record.timestampUtc
            frame = $record.frame
            name = [string]$timer.name
            activeGpu = [bool]$timer.activeGpu
            activeCpu = [bool]$timer.activeCpu
            hasGpu = [bool]$timer.hasGpu
            hasCpu = [bool]$timer.hasCpu
            gpuMs = [double]$timer.gpuMs
            topLevelMs = [double]$timer.topLevelMs
            cpuMs = [double]$timer.cpuMs
        })
    }
}

$timerSummaries = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($timerRows | Group-Object name | Sort-Object Name)) {
    $activeRows = @($group.Group | Where-Object { $_.activeGpu -and $_.hasGpu })
    $gpuValues = [double[]]@($activeRows | ForEach-Object { $_.gpuMs })
    $topValues = [double[]]@($activeRows | ForEach-Object { $_.topLevelMs })
    $cpuValues = [double[]]@($group.Group | Where-Object { $_.activeCpu -and $_.hasCpu } | ForEach-Object { $_.cpuMs })
    $timerSummaries.Add([pscustomobject][ordered]@{
        name = $group.Name
        observedSamples = $group.Count
        activeGpuSamples = $activeRows.Count
        gpuMs = Get-MetricSummary -Values $gpuValues
        topLevelMs = Get-MetricSummary -Values $topValues
        cpuMs = Get-MetricSummary -Values $cpuValues
    })
}

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    label = $Label
    startedUtc = $startedUtc.ToString('o')
    endedUtc = $endedUtc.ToString('o')
    durationSeconds = ($endedUtc - $startedUtc).TotalSeconds
    requestedSamples = $Samples
    warmupSamples = $WarmupSamples
    collectedSamples = $records.Count
    intervalMs = $IntervalMs
    endpoint = $endpoint
    sessionReconnects = $sessionReconnects
    profilerEnableResult = $enableResult
    resolvedTotalMs = Get-MetricSummary -Values ([double[]]@($records | ForEach-Object { $_.resolvedTotalMs }))
    resolvedCpuTotalMs = Get-MetricSummary -Values ([double[]]@($records | ForEach-Object { $_.resolvedCpuTotalMs }))
    maxSlotRefusals = [int](($records | Measure-Object slotRefusals -Maximum).Maximum)
    timers = $timerSummaries
}

$safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
$rawPath = Join-Path $EvidenceDirectory "$safeLabel.raw.json"
$summaryPath = Join-Path $EvidenceDirectory "$safeLabel.summary.json"
$csvPath = Join-Path $EvidenceDirectory "$safeLabel.timers.csv"
$records | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $rawPath -Encoding utf8
$summary | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$timerSummaries | ForEach-Object {
    [pscustomobject][ordered]@{
        name = $_.name
        observedSamples = $_.observedSamples
        activeGpuSamples = $_.activeGpuSamples
        gpuMeanMs = $_.gpuMs.mean
        gpuMedianMs = $_.gpuMs.median
        gpuP95Ms = $_.gpuMs.p95
        gpuP99Ms = $_.gpuMs.p99
        gpuMaxMs = $_.gpuMs.max
        topLevelMeanMs = $_.topLevelMs.mean
        cpuMeanMs = $_.cpuMs.mean
    }
} | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

[pscustomobject][ordered]@{
    ok = $true
    label = $Label
    rawPath = $rawPath
    summaryPath = $summaryPath
    csvPath = $csvPath
    summary = $summary
} | ConvertTo-Json -Depth 60
