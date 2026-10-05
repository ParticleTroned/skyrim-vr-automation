#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position=0)][ValidateSet('start','stop','status')][string]$Command,
    [Parameter(Mandatory)][string]$RunDirectory,
    [string]$SaveNumberText,
    [switch]$AlreadyInGame,
    [string]$FpsVrCmd,
    [string]$FpsVrCsvDirectory,
    [string]$RecordingDirectory,
    [string]$ArchiveDirectory,
    [string]$RuntimePath,
    [string]$Controller = (Join-Path $PSScriptRoot '../devbench-control/Invoke-DevBenchControl.ps1'),
    [string]$RecorderValidationPath,
    [string]$WprPath,
    [ValidateRange(60,900)][int]$MaximumSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HotspotSw.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../gameft-sw/GameFtStackWait.psm1') -Force
$RunDirectory = [IO.Path]::GetFullPath($RunDirectory)
$statePath = Join-Path $RunDirectory 'hotspot-sw.json'
if ($Command -ne 'start') {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schema -cne 'hotspot-sw-v1') { throw 'Unsupported hotspot session schema.' }
    if ($Command -eq 'stop') {
        if ($state.state -in @('starting','recording')) {
            [IO.File]::WriteAllText((Join-Path $RunDirectory 'stop-requested'), [DateTime]::UtcNow.ToString('o'))
            Write-Output 'Stop requested. Leave Skyrim running until capture finalization is confirmed.'
        } else { Write-Output "Session is $($state.state); no new stop dispatched." }
    } else { $state | ConvertTo-Json -Depth 30 }
    return
}
if ($AlreadyInGame -eq (![string]::IsNullOrWhiteSpace($SaveNumberText))) {
    throw 'Choose one: -AlreadyInGame, or one exact -SaveNumberText to load from the main menu.'
}
if ($SaveNumberText -and $SaveNumberText -notmatch '^\d{1,5}$') { throw 'Specify one save number, for example 13.' }
foreach ($path in @($FpsVrCmd,$RuntimePath,$Controller,$RecorderValidationPath)) {
    if (!$path -or !(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing required file: $path" }
}
foreach ($path in @($FpsVrCsvDirectory,$RecordingDirectory,$ArchiveDirectory)) {
    if (!$path -or !(Test-Path -LiteralPath $path -PathType Container)) { throw "Missing explicit evidence directory: $path" }
}
if (Test-Path -LiteralPath $RunDirectory) { throw 'A new run directory is required.' }
$gameFt = Join-Path $PSScriptRoot '../gameft-sw/protocol'
$hashes = Assert-GameFtScripts $gameFt
Assert-StackWaitElevation
$WprPath = (Resolve-StackWaitWpr $WprPath).path
$validation = Assert-StackWaitRecorderValidation $WprPath $RecorderValidationPath
$runtime = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
$game = Get-Process -Id $runtime.pid -ErrorAction Stop
if ($game.ProcessName -ne 'SkyrimVR') { throw 'Runtime PID must identify SkyrimVR.' }
$gameStart = $game.StartTime.ToUniversalTime().Ticks
$runId = 'hotspot-sw-' + [guid]::NewGuid().ToString('N')
$traceDirectory = Join-Path $RunDirectory 'stack-wait'
[void][IO.Directory]::CreateDirectory($traceDirectory)
[IO.File]::Copy([IO.Path]::GetFullPath($RuntimePath), (Join-Path $RunDirectory 'runtime.json'), $false)
$RuntimePath = Join-Path $RunDirectory 'runtime.json'
$capture = Join-Path $PSScriptRoot '../capture-interaction-control/Invoke-CaptureInteraction.ps1'
$captureDirectory = Join-Path $RunDirectory 'interaction'
$state = [ordered]@{
    schema='hotspot-sw-v1'; protocol='hotspot-sw'; runId=$runId; state='starting'
    processId=$game.Id; processStartTicks=$gameStart; maximumSeconds=$MaximumSeconds
    startedUtc=[DateTime]::UtcNow.ToString('o'); qpcFrequency=[Diagnostics.Stopwatch]::Frequency
    save=$SaveNumberText; alreadyInGame=[bool]$AlreadyInGame
    errors=@(); stopReason=$null; runtimeBuildId=$null; baseScriptHashes=$hashes
    provenance='pending after timing report'; recorderValidation=$validation
    poseIntervalMs=100; statusIntervalSeconds=5
}
Write-StackWaitJson $statePath $state
$clock=[Diagnostics.Stopwatch]::StartNew()
$worker=$null; $recordOwner=$null; $healthOwner=[guid]::NewGuid().ToString('N')
$healthId=$null; $healthAttempted=$false; $captureAttempted=$false
$fpsVrStarted=$false; $fpsVrWasAlreadyRecording=$false; $SkipFpsVrControl=$false
$script:fpsVrCsvDirectory=$FpsVrCsvDirectory
$script:fpsPath=$null
function Mark([string]$Label, $Detail) {
    $entry=@{label=$Label;utc=[DateTime]::UtcNow.ToString('o');qpc=[Diagnostics.Stopwatch]::GetTimestamp();qpcFrequency=[Diagnostics.Stopwatch]::Frequency;detail=$Detail}
    $entry|ConvertTo-Json -Depth 30 -Compress|Add-Content -LiteralPath (Join-Path $RunDirectory 'markers.jsonl')
    if ($Label -in @('fpsvr-recording-confirmed','fpsvr-already-recording')) { $script:fpsPath=$Detail.path }
}
function Assert-GameProcess {
    $current=Get-Process -Id $game.Id -ErrorAction SilentlyContinue
    if (!$current -or $current.StartTime.ToUniversalTime().Ticks -ne $gameStart) { throw 'Measured Skyrim process exited or changed.' }
}
function Call([string]$Label,[string]$Tool,[hashtable]$Arguments) {
    Assert-GameProcess
    if ($Tool.StartsWith('communityshaders.') -and $state.runtimeBuildId) { $Arguments.expectedBuildId=$state.runtimeBuildId }
    $begin=[Diagnostics.Stopwatch]::GetTimestamp()
    Mark "$Label-request" @{tool=$Tool;arguments=$Arguments}
    try {
        $parameters=@{RuntimePath=$RuntimePath;Tool=$Tool;ArgumentsJson=($Arguments|ConvertTo-Json -Depth 20 -Compress);TimeoutSeconds=8;RequestTimeoutSeconds=3;MaxTransientRetries=0;NoExit=$true;Compact=$true;SkipRuntimeIdentityVerification=$true}
        if ($Tool -eq 'game' -and $Arguments.action -eq 'load') {$parameters.AllowUnprovenGameMutation=$true}
        $raw=& $Controller call @parameters
        $raw|Set-Content -LiteralPath (Join-Path $RunDirectory "$Label.json") -Encoding utf8
        $reply=$raw|ConvertFrom-Json -Depth 100
        if (!$reply.transportOk -or $reply.data.rawResult.isError) {throw "DevBench call failed: $Label"}
        $payload=@($reply.data.content)[0]
        if ($payload.PSObject.Properties['error'] -or $payload.PSObject.Properties['errorCode']) {throw "$Label rejected: $($payload|ConvertTo-Json -Depth 6 -Compress)"}
        return $payload
    } finally {Mark "$Label-response" @{beginQpc=$begin}}
}
function Record-Clock([string]$Label) {
    $begin=[Diagnostics.Stopwatch]::GetTimestamp()
    $record=Call $Label 'record' @{action='status'}
    $end=[Diagnostics.Stopwatch]::GetTimestamp()
    if ($record.correlationId -cne $recordOwner -or !$record.recording -or $record.limitReached) {throw 'Pose recorder stopped, reached a limit or changed owner.'}
    Mark 'record-clock' @{beginQpc=$begin;endQpc=$end;elapsedMs=$record.elapsedMs;correlationId=$recordOwner}
}
# Reuse the hash-pinned fpsVR implementation, without executing its save runner.
. (Get-HotspotPinnedFunctions (Join-Path $gameFt 'Invoke-SaveLoadTimingV2.ps1') @('Invoke-FpsVrToggle','Get-LatestFpsVrRawFile','Test-FpsVrRawRecordingActive','Wait-FpsVrRawRecordingActive','Start-FpsVrRawLogging','Stop-OwnedFpsVrRawLogging','Get-SaveNumberFromEntry'))
try {
    $before=Invoke-StackWaitSnapshot $Controller $RuntimePath $traceDirectory 'before' $game.Id
    $state.runtimeBuildId=$before.producer.buildId
    $initial=Call 'initial-status' 'communityshaders.renderscale' @{action='status'}
    Assert-HotspotFrustum $initial.status
    if ($initial.status.session.ownerSchemaVersion -ne 1 -or $initial.status.session.active) {throw 'Guarded health recorder must be available and inactive.'}
    $generation=$initial.status.nativeFrustum.collectionGeneration
    $backoff=$initial.status.nativeFrustum.depthJobs.backoff.control
    $fast=$initial.status.frustumFastPath.enabled
    if (!$AlreadyInGame -and !$initial.status.vendorWorkGate.mainMenu) {throw 'Reach the main loading screen before requesting a save load.'}
    if ($AlreadyInGame -and ($initial.status.vendorWorkGate.mainMenu -or $initial.status.vendorWorkGate.loadingMenu -or !$initial.status.vendorWorkGate.completedWorldFrame)) {throw 'AlreadyInGame requires a loaded world.'}
    $selected=$null
    if (!$AlreadyInGame) {
        $selection=Call 'save-selection' 'game' @{action='list'}
        $matches=@($selection.saves|Where-Object {(Get-SaveNumberFromEntry $_) -eq [int]$SaveNumberText})
        if ($matches.Count -ne 1) {throw 'Requested save is missing or ambiguous; no save loaded.'}
        $selected=$matches[0]
    }
    $capability=& $capture capabilities -RuntimePath $RuntimePath -VisualMode none -DevBenchScriptPath $Controller -Compact -NoExit -SkipRuntimeIdentityVerification | ConvertFrom-Json -Depth 100
    $capability|ConvertTo-Json -Depth 100|Set-Content (Join-Path $RunDirectory 'capture-capabilities.json')
    if (!$capability.ok) {throw 'Guarded pose/tracking recording is unsupported; no save loaded.'}
    if (Wait-FpsVrRawRecordingActive 2) {throw 'fpsVR already has a user-owned recording. Leave it untouched; finish it before this separately owned capture.'}
    $config=Join-Path $traceDirectory 'worker.json'
    $profile=Join-Path $traceDirectory 'CpuStackWait.wprp'
    [IO.File]::Copy((Join-Path $PSScriptRoot '../gameft-sw/CpuStackWait.wprp'),$profile,$false)
    Write-StackWaitJson $config @{Directory=$traceDirectory;WprPath=$WprPath;ProfilePath=$profile;Instance=$runId;MaximumSeconds=($MaximumSeconds+45);OwnerProcessId=$PID;OwnerStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks}
    $worker=Start-StackWaitWorker $traceDirectory $config
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while (!(Test-Path (Join-Path $traceDirectory 'trace-ready.json'))) {
        if ($worker.HasExited -or [DateTime]::UtcNow -gt $deadline) {throw 'WPR did not start; no save loaded.'}
        Start-Sleep -Milliseconds 100
    }
    Start-FpsVrRawLogging
    if ($fpsVrWasAlreadyRecording) {throw 'fpsVR ownership changed during admission; foreign recording preserved.'}
    $captureAttempted=$true
    $started=& $capture start -SessionDirectory $captureDirectory -RuntimePath $RuntimePath -VisualMode none -AllowNoPlayer -RecordIntervalMs 100 -RecordMaximumDurationMs (($MaximumSeconds+20)*1000) -DevBenchScriptPath $Controller -Compact -NoExit -SkipRuntimeIdentityVerification | ConvertFrom-Json -Depth 100
    if (!$started.ok) {throw 'Pose recorder start failed; see capture recovery receipt.'}
    $recordOwner=$started.data.sessionId
    Record-Clock 'clock-before-load'
    $healthAttempted=$true
    $startedHealth=Call 'health-start' 'communityshaders.renderscale' @{action='start';captureOwnerToken=$healthOwner}
    if (!$startedHealth.status.session.active -or $startedHealth.status.session.ownerToken -cne $healthOwner) {throw 'Health recorder ownership was not confirmed.'}
    $healthId=$startedHealth.status.session.id
    $state.state='recording'
    Write-StackWaitJson $statePath $state
    if ($selected) {
        [void](Call 'load' 'game' @{action='load';name=$selected.name;dir=$selection.dir})
    }
    Mark 'manual-walk-start' @{save=$SaveNumberText}
    Write-Output 'Capture running. Walk into the hotspot, hold the view for about 20 seconds, move out, and hold again. Say stop when finished.'
    $deadline=$clock.Elapsed.TotalSeconds+$MaximumSeconds
    $nextStatus=0.0; $ordinal=0
    while (!(Test-Path -LiteralPath (Join-Path $RunDirectory 'stop-requested'))) {
        try {Assert-GameProcess} catch {$state.stopReason='game_exited';throw}
        if ($clock.Elapsed.TotalSeconds -ge $deadline) {$state.stopReason='deadline';break}
        if (Test-Path -LiteralPath (Join-Path $traceDirectory 'trace-result.json')) {throw 'WPR stopped before the walk ended.'}
        if ($clock.Elapsed.TotalSeconds -ge $nextStatus) {
            $ordinal++
            # Record misses without blocking the walk or repeating a mutation.
            try {
                Record-Clock "clock-$ordinal"
                $observation=Call "health-$ordinal" 'communityshaders.renderscale' @{action='status'}
                Assert-HotspotFrustum $observation.status
                if ($observation.status.nativeFrustum.collectionGeneration -ne $generation -or $observation.status.nativeFrustum.depthJobs.backoff.control -ne $backoff -or $observation.status.frustumFastPath.enabled -ne $fast) {throw 'Diagnostic collection or experimental controls changed during the walk.'}
                if ($observation.status.session.ownerToken -cne $healthOwner -or !$observation.status.session.active) {throw 'Health capture ownership changed.'}
            } catch {
                Mark 'observation-gap' @{message=$_.Exception.Message}
                $state.errors+= $_.Exception.Message
                if ($_.Exception.Message -notmatch '(?i)timeout|timed.out|main_thread_busy|main_thread_in_progress|main_thread_timeout') {throw}
            }
            $nextStatus=$clock.Elapsed.TotalSeconds+5
        }
        Start-Sleep -Milliseconds 200
    }
    if (!$state.stopReason) {$state.stopReason='requested'}
} catch {
    if (!$state.stopReason) {$state.stopReason='error'}
    $state.errors+=$_.Exception.Message
} finally {
    # Request independent recorder shutdown even if the evidence disk has failed.
    try {
        if ($worker) {[IO.File]::WriteAllText((Join-Path $traceDirectory 'stop-trace'),'stop owned trace')}
    } catch {$state.errors+=$_.Exception.Message}
    try {Mark 'measurement-end' @{reason=$state.stopReason}} catch {$state.errors+=$_.Exception.Message}
    $state.state='finalizing'
    try {Write-StackWaitJson $statePath $state} catch {$state.errors+=$_.Exception.Message}
    if ($healthAttempted) {
        try {
            $owner=Call 'health-owner-at-stop' 'communityshaders.renderscale' @{action='status'}
            if ($owner.status.session.active -and $owner.status.session.ownerToken -ceq $healthOwner) {
                [void](Call 'health-stop' 'communityshaders.renderscale' @{action='stop';expectedSessionId=$owner.status.session.id;expectedOwnerToken=$healthOwner})
            } else {throw 'Owned health recorder unavailable at stop; no foreign recorder stopped.'}
        } catch {$state.errors+=$_.Exception.Message}
    }
    if ($captureAttempted) {
        try {
            $stopped=& $capture stop -SessionDirectory $captureDirectory -DevBenchScriptPath $Controller -Compact -NoExit -SkipRuntimeIdentityVerification | ConvertFrom-Json -Depth 100
            if (!$stopped.ok) {throw 'Pose recording finalization failed; inspect interaction session receipts.'}
            $name=[IO.Path]::GetFileName([string]$stopped.data.recording.stopReceipt.path)
            if (!$name -or $name -notmatch '^recording_\d+\.json$') {throw 'Unknown recording artifact filename.'}
            $saved=Save-HotspotArtifact (Join-Path $RecordingDirectory $name) $ArchiveDirectory
            Write-StackWaitJson (Join-Path $RunDirectory 'pose-archive.json') $saved
            Write-Output "Preserved pose recording: $($saved.archivePath) (SHA-256 and size verified)"
        } catch {$state.errors+=$_.Exception.Message}
    }
    if ($fpsVrStarted -and !$fpsVrWasAlreadyRecording) {
        try {
            $latest=Get-LatestFpsVrRawFile
            if (!$latest -or $latest.FullName -ne $fpsPath) {throw 'fpsVR file ownership changed; no toggle sent.'}
            if (Test-FpsVrRawRecordingActive) {Stop-OwnedFpsVrRawLogging}
            Start-Sleep -Milliseconds 1000
            $saved=Save-HotspotArtifact $fpsPath $ArchiveDirectory
            Write-StackWaitJson (Join-Path $RunDirectory 'fpsvr-archive.json') $saved
            Write-Output "Preserved fpsVR CSV: $($saved.archivePath) (SHA-256 and size verified)"
        } catch {$state.errors+=$_.Exception.Message}
    }
    try {
        if ($state.runtimeBuildId) {[void](Invoke-StackWaitSnapshot $Controller $RuntimePath $traceDirectory 'after' $game.Id $state.runtimeBuildId)}
    } catch {$state.errors+=$_.Exception.Message}
    $state.state=if($state.stopReason -eq 'requested' -and !$state.errors.Count){'captured'}else{'interrupted'}
    $state.finishedUtc=[DateTime]::UtcNow.ToString('o')
    $state.traceFinalization='check stack-wait/trace-result.json; ETL loss and symbol validation pending'
    Write-StackWaitJson $statePath $state
    Write-Output "Timing/pose capture $($state.state). WPR finalization is separate; keep receipts. Run: python tools/hotspot-sw/analyze_hotspot.py --run-directory <this run>"
}
if ($state.errors.Count) {throw "Hotspot capture incomplete: $($state.errors -join '; ')"}
