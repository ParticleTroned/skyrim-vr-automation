#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HotspotSw.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../gameft-sw/GameFtStackWait.psm1') -Force
$protocol=Join-Path $PSScriptRoot '../gameft-sw/protocol'
[void](Assert-GameFtScripts $protocol)
. (Get-HotspotPinnedFunctions (Join-Path $protocol 'Show-SaveLoadTimingQuickReport.ps1') @('Get-Percentile','Get-Stats','Get-SingleSpikeFrequency','Get-SpikeGroups'))
$receipt=Get-Content (Join-Path $RunDirectory 'fpsvr-archive.json') -Raw|ConvertFrom-Json
if ((Get-Item -LiteralPath $receipt.archivePath).Length -ne $receipt.byteLength -or (Get-FileHash -LiteralPath $receipt.archivePath).Hash -ne $receipt.sha256) {throw 'fpsVR archive verification failed.'}
$segments=Get-Content (Join-Path $RunDirectory 'hotspot-segments.json') -Raw|ConvertFrom-Json -Depth 100
if ($segments.schema -cne 'hotspot-sw-segments-v1') {throw 'Unknown segment schema.'}
$lines=Get-Content -LiteralPath $receipt.archivePath
$headerUtc=[datetime]::Parse(($lines[1] -split '/',4)[3]).ToUniversalTime()
$firstSteam=$null
$rows=@(for($i=3;$i -lt $lines.Count;$i++){
    if(!$lines[$i].Trim()){continue}
    $parts=$lines[$i]|ConvertFrom-Csv -Header 'SteamVR Time','FPS','GPU frametime','CPU frametime','GPU Usage','CPU Usage'
    $steam=[double]$parts.'SteamVR Time'
    if($null -eq $firstSteam){$firstSteam=$steam}
    $cpuValue=[double]$parts.'CPU frametime';$gpuValue=[double]$parts.'GPU frametime'
    foreach($value in @($steam,$cpuValue,$gpuValue)) {
        if([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0){throw 'Invalid fpsVR sample.'}
    }
    [pscustomobject]@{utc=$headerUtc.AddSeconds($steam-$firstSteam);cpu=$cpuValue;gpu=$gpuValue}
})
$reports=@(foreach($window in $segments.windows){
    $start=([datetime]$window.startUtc).ToUniversalTime()
    $end=([datetime]$window.endUtc).ToUniversalTime()
    $tail=@($rows|Where-Object {$_.utc -ge $start -and $_.utc -lt $end}|ForEach-Object {
        [pscustomobject]@{relative=($_.utc-$start).TotalSeconds;cpu=$_.cpu;gpu=$_.gpu}
    })
    if($tail.Count -lt 2 -or $tail[0].relative -gt .25 -or $tail[-1].relative -lt 9.75){throw "fpsVR does not cover pause $($window.pause)."}
    for($i=1;$i -lt $tail.Count;$i++){
        if($tail[$i].relative -le $tail[$i-1].relative -or $tail[$i].relative-$tail[$i-1].relative -gt .5){throw "fpsVR sample gap in pause $($window.pause)."}
    }
    $cpu=Get-Stats ([double[]]$tail.cpu);$gpu=Get-Stats ([double[]]$tail.gpu)
    [pscustomobject]@{
        pause=$window.pause;startUtc=$start;endUtc=$end;cpu=$cpu;gpu=$gpu
        cpuIsolated=Get-SingleSpikeFrequency $tail 'cpu' $cpu.median
        gpuIsolated=Get-SingleSpikeFrequency $tail 'gpu' $gpu.median
        cpuGroups=Get-SpikeGroups $tail 'cpu' $cpu.median
        gpuGroups=Get-SpikeGroups $tail 'gpu' $gpu.median
    }
})
if($reports.Count) {
    $reference=$reports[0]
    foreach($report in $reports) {
        $report|Add-Member referencePause $reference.pause
        $report|Add-Member cpuDeltaMs ($report.cpu.mean-$reference.cpu.mean)
        $report|Add-Member gpuDeltaMs ($report.gpu.mean-$reference.gpu.mean)
        $report|Add-Member cpuClusteredPerSecond (@($report.cpuGroups.groups|Where-Object samples -GE 2).Count/10.0)
        $report|Add-Member gpuClusteredPerSecond (@($report.gpuGroups.groups|Where-Object samples -GE 2).Count/10.0)
    }
}
$reports|ConvertTo-Json -Depth 30|Set-Content (Join-Path $RunDirectory 'hotspot-timing.json')
$reports|Select-Object pause,@{n='CPU ms';e={'{0:F3}' -f $_.cpu.mean}},@{n='GPU ms';e={'{0:F3}' -f $_.gpu.mean}},@{n='CPU delta';e={'{0:F3}' -f $_.cpuDeltaMs}},@{n='GPU delta';e={'{0:F3}' -f $_.gpuDeltaMs}},@{n='CPU P95/P99';e={'{0:F3}/{1:F3}' -f $_.cpu.p95,$_.cpu.p99}},@{n='GPU P95/P99';e={'{0:F3}/{1:F3}' -f $_.gpu.p95,$_.gpu.p99}}|Format-Table -AutoSize
Write-Output 'Present timing now. Physical DLL provenance, telemetry interpretation and WPR stack/wait analysis follow.'
