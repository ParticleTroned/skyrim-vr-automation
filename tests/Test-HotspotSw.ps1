#Requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$tool=Join-Path $root 'tools/hotspot-sw'
python -m unittest discover -s (Join-Path $root 'tests') -p test_hotspot_sw.py
if($LASTEXITCODE -ne 0){throw 'Hotspot segmentation tests failed.'}
Import-Module (Join-Path $tool 'HotspotSw.psm1') -Force
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('hotspot-sw-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Require($Condition,[string]$Message){if(!$Condition){throw $Message}}
try {
    foreach($path in Get-ChildItem $tool -Recurse -File | Where-Object Extension -In '.ps1','.psm1'){
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($path.FullName,[ref]$tokens,[ref]$errors)
        Require (!$errors.Count) "Parse errors in $($path.Name): $errors"
    }
    $source=Join-Path $fixture 'source.csv'
    $archive=Join-Path $fixture 'archive'
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('fixture')
    $lines.Add('fpsVR/start/utc/2026-09-19T12:00:00Z')
    $lines.Add('SteamVR Time,FPS,GPU frametime,CPU frametime,GPU Usage,CPU Usage')
    for($i=0;$i -lt 6000;$i++){
        $t=$i/100.0
        $cpu=if($t -ge 40 -and $t -lt 50){16}else{8}
        $gpu=if($t -ge 40 -and $t -lt 50){11}else{10}
        if($t -lt 10 -or $t -ge 55){$cpu=999;$gpu=999}
        if($i -in @(2000,2200,2201,2202)){$cpu=12}
        $lines.Add(('{0},100,{1},{2},0,0' -f $t.ToString([Globalization.CultureInfo]::InvariantCulture),$gpu,$cpu))
    }
    $lines|Set-Content -LiteralPath $source -Encoding utf8
    $receipt=Save-HotspotArtifact $source $archive
    $receipt|ConvertTo-Json|Set-Content (Join-Path $fixture 'fpsvr-archive.json')
    $second=Save-HotspotArtifact $source $archive
    Require ($receipt.archivePath -ne $second.archivePath) 'Archive overwrote previous evidence.'
    Require ((Get-FileHash $source).Hash -eq $receipt.sha256) 'Source preservation failed.'
    @{schema='hotspot-sw-segments-v1';windows=@(
        @{pause=1;startUtc='2026-09-19T12:00:15Z';endUtc='2026-09-19T12:00:25Z'},
        @{pause=2;startUtc='2026-09-19T12:00:40Z';endUtc='2026-09-19T12:00:50Z'}
    )}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $fixture 'hotspot-segments.json')
    & (Join-Path $tool 'Show-HotspotTiming.ps1') -RunDirectory $fixture
    $report=@(Get-Content (Join-Path $fixture 'hotspot-timing.json') -Raw|ConvertFrom-Json)
    Require ([math]::Abs($report[0].cpu.mean-8.016) -lt .00001) 'Mean included samples outside the tail.'
    Require ($report[1].cpu.mean -eq 16 -and $report[1].gpu.mean -eq 11) 'Separate CPU/GPU windows incorrect.'
    Require ($report[0].cpuIsolated.count -eq 1 -and $report[0].cpuClusteredPerSecond -eq .1) 'Single and clustered spikes were mixed.'
    Require ([math]::Abs($report[1].cpuDeltaMs-7.984) -lt .00001) 'Reference delta incorrect.'
    Add-Content -LiteralPath $receipt.archivePath -Value 'tampered'
    $failed=$false
    try {& (Join-Path $tool 'Show-HotspotTiming.ps1') -RunDirectory $fixture}catch{$failed=$true}
    Require $failed 'Changed archived evidence was accepted.'
    $native=[pscustomobject]@{schemaVersion=2;installed=$true;active=$true;enabled=$true;collectionGeneration=1;collectionGenerationAtEnd=1;depthJobs=[pscustomobject]@{schemaVersion=1;installed=$true}}
    Assert-HotspotFrustum ([pscustomobject]@{nativeFrustum=$native})
    $native.collectionGenerationAtEnd=2
    $failed=$false
    try {Assert-HotspotFrustum ([pscustomobject]@{nativeFrustum=$native})}catch{$failed=$true}
    Require $failed 'Mixed telemetry generations were accepted.'
    @{schema='hotspot-sw-v1';state='recording'}|ConvertTo-Json|Set-Content (Join-Path $fixture 'hotspot-sw.json')
    & (Join-Path $tool 'Invoke-HotspotSw.ps1') stop -RunDirectory $fixture
    Require (Test-Path (Join-Path $fixture 'stop-requested')) 'Stop request was not recorded.'
    @{schema='future';state='recording'}|ConvertTo-Json|Set-Content (Join-Path $fixture 'hotspot-sw.json')
    $failed=$false
    try {& (Join-Path $tool 'Invoke-HotspotSw.ps1') stop -RunDirectory $fixture}catch{$failed=$true}
    Require $failed 'Future session schema accepted.'
    Write-Output 'PASS: parser, pinned statistics, exact tail windows, spike groups, evidence hashes, telemetry generations and stop control.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(!$resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or !(Split-Path $resolved -Leaf).StartsWith('hotspot-sw-test-')){throw 'Unexpected fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
