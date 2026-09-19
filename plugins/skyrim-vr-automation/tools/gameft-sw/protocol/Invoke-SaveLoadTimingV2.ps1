param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [switch]$LegacyRc166,
    [switch]$FrustumPaired,
    [switch]$DepthC,
    [switch]$DepthJobBackoff,
    [string]$ExpectedBuildId,
    [switch]$ResumeSecond,
    [int]$FirstSaveNumber = -1,
    [int[]]$SaveNumbers,
    [string]$SaveNumberText,
    [Parameter(Mandatory)][string]$FpsVrCmd,
    [string]$Controller = (Join-Path $PSScriptRoot '../../devbench-control/Invoke-DevBenchControl.ps1'),
    [int]$DevBenchPort = 8921,
    [switch]$SkipFpsVrControl
)
$ErrorActionPreference = 'Stop'
if ($FrustumPaired -and $DepthC) { throw 'Choose exactly one frustum protocol.' }
if ($DepthC) {
    $FrustumPaired = $true
    if ($DepthJobBackoff) { throw 'depthc owns its complete condition matrix.' }
    Import-Module (Join-Path $PSScriptRoot '../../depthc/DepthC.psm1') -Force
}
if ($DepthJobBackoff -and !$FrustumPaired) { throw 'DepthJobBackoff requires the paired protocol.' }
if ($LegacyRc166) { Import-Module (Join-Path $PSScriptRoot '../LegacyRc166.psm1') -Force }
if ($FrustumPaired) {
    if ($LegacyRc166 -or $ResumeSecond -or $ExpectedBuildId -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'frustrum requires the current DevBench Build ID and a complete non-legacy run.'
    }
    Import-Module (Join-Path $PSScriptRoot '../../frustrum/Frustrum.psm1') -Force
}
$pairedAction = if ($DepthJobBackoff) { 'set_depth_job_backoff_enabled' } else { 'set_frustum_fast_path_enabled' }
$pairedControl = $null
$pairedCollection = $null
function Assert-PairedState($Status, [Nullable[bool]]$ExpectedEnabled = $null) {
    if ($DepthJobBackoff) { Assert-DepthJobBackoffState $Status $ExpectedEnabled $pairedControl $pairedCollection }
    else { Assert-FrustrumState $Status.frustumFastPath $ExpectedEnabled }
}
function Get-PairedEnabled($Status) {
    if ($DepthJobBackoff) { return $Status.nativeFrustum.depthJobs.backoff.enabled }
    return $Status.frustumFastPath.enabled
}
function Set-PairedToggle([string]$label, $leg) {
    # Arm restoration before dispatch because a timed-out setter may still apply.
    $script:frustumRestoreNeeded = $true
    $toggle = Call "$label-frustrum-set" 'communityshaders.menu' @{action=$pairedAction;enabled=$leg.enabled}
    if ($DepthJobBackoff) {
        $script:pairedControl = $null; $script:pairedCollection = $null
        Assert-PairedState $toggle.status $leg.enabled
        $script:pairedControl = $toggle.status.nativeFrustum.depthJobs.backoff.control
        $script:pairedCollection = $toggle.status.nativeFrustum.collectionGeneration
    } else { Assert-PairedState $toggle.status $leg.enabled }
}
function Wait-LiveRecovery([string]$label, $Mode=$null) {
    $deadline = $clock.Elapsed.TotalSeconds + 120
    $attempt = 0
    do {
        $attempt++
        $evidence = Call "$label-recovery-$attempt" 'communityshaders.renderscale' @{action='record'}
        if ((Test-DepthCRecovered $evidence) -and (!$Mode -or (Test-DepthCMode $evidence.status $Mode))) { return $evidence }
        if ($clock.Elapsed.TotalSeconds -ge $deadline) { throw "$label render recovery did not complete within 120 seconds." }
        Start-Sleep -Milliseconds 1000
    } while ($true)
}
function Invoke-DepthCProfileCall([string]$label,[string]$action,[hashtable]$Extra=@{}) {
    $args=@{action=$action;contractMajor=1;clientId='depthc';commandId=([guid]::NewGuid().ToString('N'))}
    foreach($key in $Extra.Keys){$args[$key]=$Extra[$key]}
    $payload=Call $label 'communityshaders.upscaling_api' $args
    if ($payload.status.name -cne 'success') { throw "$label profile API did not succeed." }
    return $payload
}
function Set-DepthCProfile([string]$label,[hashtable]$Target) {
    $snapshot=Invoke-DepthCProfileCall "$label-profile-before" 'snapshot'
    $request=@{target=$Target;expectedStateRevision=$snapshot.snapshot.stateRevision;purpose='direct';persistence='runtime_only'}
    $preflight=Invoke-DepthCProfileCall "$label-profile-preflight" 'preflight' $request
    if ($preflight.preflight.requiresRestart -cne $false -or $preflight.preflight.willPersist -cne $false -or
        $preflight.preflight.decision.name -cnotin @('no_change','apply_synchronously','queue')) { throw "$label profile preflight rejected." }
    Assert-DepthCProfile $preflight.preflight.normalizedTarget $Target
    $applied=Invoke-DepthCProfileCall "$label-profile-apply" 'apply' $request
    if ($applied.apply.requiresRestart -cne $false -or $applied.apply.willPersist -cne $false -or
        $applied.apply.disposition.name -cnotin @('no_change','applied_synchronously','queued')) { throw "$label profile apply rejected." }
    Assert-DepthCProfile $applied.apply.normalizedTarget $Target
    $deadline=$clock.Elapsed.TotalSeconds+120; $poll=0
    if ($applied.apply.operationId -gt 0) {
        do {
            $poll++
            $operation=Invoke-DepthCProfileCall "$label-operation-$poll" 'operation' @{operationId=$applied.apply.operationId}
            Assert-DepthCProfile $operation.operation.target $Target
            if ($operation.operation.state.name -eq 'completed') {
                if ($operation.operation.result.name -cne 'success') { throw 'Profile operation completed without success.' }
                Assert-DepthCProfile $operation.operation.effective $Target
                break
            }
            if ($operation.operation.state.name -cnotin @('queued','waiting_for_safe_point','preparing','applying','stabilizing') -or
                $clock.Elapsed.TotalSeconds -ge $deadline) { throw "$label profile operation failed or timed out." }
            Start-Sleep -Milliseconds 1000
        } while ($true)
    } elseif ($applied.apply.disposition.name -eq 'queued') { throw 'Queued profile has no operation identity.' }
    $after=Invoke-DepthCProfileCall "$label-profile-after" 'snapshot'
    Assert-DepthCProfile $after.snapshot.profiles.configured $Target
    Assert-DepthCProfile $after.snapshot.profiles.effective $Target
}
function Set-DepthCControls([string]$label,$Target) {
    $state=(Call "$label-controls-before" 'communityshaders.menu' @{action='status'}).status
    $actions=[ordered]@{
        backoff='set_depth_job_backoff_enabled'; fast='set_frustum_fast_path_enabled'
        depthCullingLegacyMode='set_depth_culling_legacy_mode'; depthCullingPerformanceMode='set_depth_culling_performance_mode'
        depthCullingExteriorEnabled='set_depth_culling_enabled'; depthCullingInteriorEnabled='set_depth_culling_interior_enabled'
    }
    foreach($key in $actions.Keys){
        $actual=Get-DepthCControlState $state
        if($actual[$key] -cne $Target[$key]){
            $state=(Call "$label-control-$key" 'communityshaders.menu' @{action=$actions[$key];enabled=[bool]$Target[$key]}).status
        }
    }
    Assert-DepthCControls $state $Target
    return $state
}
function Restore-DepthCScene([string]$label) {
    if (!$depthCRestoreNeeded) { return }
    $errors=@()
    try { [void](Set-DepthCControls "$label-restore" $depthCOriginalControls) } catch { $errors+=$_.Exception.Message }
    try { Set-DepthCProfile "$label-restore" $depthCOriginalProfile } catch { $errors+=$_.Exception.Message }
    if($errors.Count){throw ($errors -join '; ')}
    $script:depthCRestoreNeeded=$false
    Mark "$label-depthc-restored" @{profile=$depthCOriginalProfile;controls=$depthCOriginalControls}
}
$depthCOriginalControls=$null; $depthCOriginalProfile=$null; $depthCRestoreNeeded=$false
$depthCExpectedControls=$null
$liveRouting = $null
$frustumOriginal = $null
$frustumRestoreNeeded = $false
$fpsVrCsvDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'fpsVR\CSV'
$journal = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$sessionId = $null
$depthCOwnerToken = $null
$depthCPendingOwner = $null
$depthCForeignRecorder = $false
$fpsVrStarted = $false
$fpsVrWasAlreadyRecording = $false
function Format-SaveNumber([int]$SaveNumber) {
    return $SaveNumber.ToString('00', [Globalization.CultureInfo]::InvariantCulture)
}
function Convert-SaveNumberText([string]$Text) {
    $numbers = @()
    foreach ($part in ($Text -split ',')) {
        $trimmed = $part.Trim()
        if (!$trimmed) { continue }
        if ($trimmed -notmatch '^\d+$') { throw "Invalid save number '$trimmed'. Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12." }
        $numbers += [int]::Parse($trimmed, [Globalization.CultureInfo]::InvariantCulture)
    }
    return [int[]]$numbers
}
function Get-SaveNumberFromEntry($SaveEntry) {
    if ($SaveEntry.meta -and $SaveEntry.meta.saveNumber -ne $null -and $SaveEntry.meta.saveType -eq 'save') {
        return [int]$SaveEntry.meta.saveNumber
    }
    if ($SaveEntry.name -match '^Save(\d+)_') {
        return [int]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}
function Mark([string]$Label, $Detail) {
    $entry = [ordered]@{label=$Label;utc=[DateTime]::UtcNow.ToString('o');elapsedSeconds=$clock.Elapsed.TotalSeconds;qpc=[Diagnostics.Stopwatch]::GetTimestamp();qpcFrequency=[Diagnostics.Stopwatch]::Frequency;detail=$Detail}
    $journal.Add($entry)
    $entry | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath "$RunDirectory\markers.jsonl"
}
function Call([string]$Label,[string]$Tool,[hashtable]$Arguments,[switch]$Neutral,[switch]$Setup) {
    if ($DepthC -and $Tool -eq 'communityshaders.renderscale' -and $Arguments.action -eq 'stop') {
        if (!$depthCOwnerToken) { throw 'Cannot stop an unattributed depthc recorder.' }
        $Arguments.expectedOwnerToken=$depthCOwnerToken
        $Setup=$true
    }
    if($Setup){
        $currentProcess=Get-Process -Id $depthCProcessId -ErrorAction Stop
        if($currentProcess.StartTime.ToUniversalTime().Ticks -ne $depthCProcessStartTicks){throw 'Measured Skyrim process identity changed.'}
    }
    $requestSeconds=if($Setup){10}else{3}
    $timeoutSeconds=if($Setup){15}else{8}
    if ($FrustumPaired -and $Tool.StartsWith('communityshaders.')) { $Arguments.expectedBuildId = $ExpectedBuildId }
    $argsJson = $Arguments | ConvertTo-Json -Depth 15 -Compress
    Mark "$Label-request" $Arguments
    $raw = & $controller call -RuntimePath "$RunDirectory\runtime.json" -SkipRuntimeIdentityVerification -AllowUnprovenGameMutation -EvidenceDirectory $RunDirectory -EvidenceLabel $Label -Tool $Tool -ArgumentsJson $argsJson -RequirePerformanceNeutral:$Neutral -TimeoutSeconds $timeoutSeconds -RequestTimeoutSeconds $requestSeconds -MaxTransientRetries 0 -NoExit -Compact
    $raw | Set-Content -LiteralPath "$RunDirectory\$Label.json"
    $response = $raw | ConvertFrom-Json
    Mark "$Label-response" @{transportOk=$response.transportOk;semantic=$response.semantic;errors=$response.errors}
    if (!$response.transportOk -or $response.data.rawResult.isError) { throw "$Label failed: $($response.errors)" }
    $payload = @($response.data.content)[0]
    if($DepthC -and $Tool -eq 'communityshaders.renderscale' -and $Arguments.action -eq 'record' -and $sessionId){
        if(!$payload.status.session.active -or $payload.status.session.id -ne $sessionId -or $payload.status.session.ownerToken -cne $depthCOwnerToken){throw 'Measured capture ownership changed.'}
    }
    if ($payload.error -or $payload.errorCode) { throw "$Label returned an error: $($payload | ConvertTo-Json -Compress -Depth 4)" }
    return $payload
}
function Resolve-DepthCStart([string]$Label) {
    # Read-only reconciliation never repeats the mutating start request.
    $observed=Call "$Label-owner-status" 'communityshaders.renderscale' @{action='status'} -Neutral -Setup
    $session=$observed.status.session
    if($session.ownerSchemaVersion -ne 1){throw 'Capture ownership schema is missing or unsupported.'}
    if($session.active -and $session.ownerToken -ceq $depthCPendingOwner -and $session.id -gt 0){
        $script:sessionId=$session.id
        $script:depthCOwnerToken=$depthCPendingOwner
        $script:depthCPendingOwner=$null
        Mark "$Label-start-reconciled" @{sessionId=$session.id;ownerToken=$depthCOwnerToken}
        return $observed
    }
    if($session.active){
        $script:depthCForeignRecorder=$true
        Mark 'health-owner-conflict-error' @{sessionId=$session.id;reason='Foreign capture active; restoration withheld.'}
        $script:depthCPendingOwner=$null
        throw 'A foreign capture owns the recorder; no stop or restoration will target it.'
    }
    return $null
}
function Start-DepthCHealth([string]$Label) {
    $before=Call "$Label-owner-before" 'communityshaders.renderscale' @{action='status'} -Neutral -Setup
    if($before.status.session.ownerSchemaVersion -ne 1){throw 'depthc requires capture ownership schema 1; install the updated DevBench AIO.'}
    if($before.status.session.active){$script:depthCForeignRecorder=$true;throw 'Another recorder is already active.'}
    $script:depthCPendingOwner=[guid]::NewGuid().ToString('N')
    $script:depthCOwnerToken=$null
    try {
        $started=Call $Label 'communityshaders.renderscale' @{action='start';captureOwnerToken=$depthCPendingOwner} -Neutral -Setup
    } catch {
        $failure=$_.Exception.Message
        Mark "$Label-start-indeterminate" @{message=$failure;ownerToken=$depthCPendingOwner}
        # The producer cancels unclaimed work after five seconds. An admitted
        # task can finish later; bounded observation retains uncertain ownership.
        foreach($attempt in 1..3){
            try {$recovered=Resolve-DepthCStart "$Label-reconcile-$attempt"} catch {
                if($depthCForeignRecorder){throw}
                Mark "$Label-reconcile-error-$attempt" @{message=$_.Exception.Message}
                $recovered=$null
            }
            if($recovered){return $recovered}
            if($attempt -lt 3){Start-Sleep -Milliseconds 1000}
        }
        throw "$failure; capture start remains unresolved after bounded reconciliation."
    }
    $session=$started.status.session
    if($session.ownerSchemaVersion -ne 1 -or !$session.active -or $session.id -le 0 -or $session.ownerToken -cne $depthCPendingOwner){
        throw 'Start receipt did not prove the exact capture owner.'
    }
    $script:sessionId=$session.id
    $script:depthCOwnerToken=$depthCPendingOwner
    $script:depthCPendingOwner=$null
    return $started
}
function Ensure-RuntimeMetadata {
    $runtimePath = "$RunDirectory\runtime.json"
    if (Test-Path -LiteralPath $runtimePath) { return }
    $skyrim = Get-Process SkyrimVR -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$skyrim) { throw 'SkyrimVR process is not running; cannot create DevBench runtime metadata.' }
    [pscustomobject]@{
        port = $DevBenchPort
        pid = $skyrim.Id
        exe = 'SkyrimVR.exe'
    } | ConvertTo-Json | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    Mark 'runtime-metadata-created' @{path=$runtimePath;port=$DevBenchPort;pid=$skyrim.Id;exe='SkyrimVR.exe'}
}
function Invoke-FpsVrToggle([string]$Label) {
    if ($SkipFpsVrControl) { Mark "$Label-skipped" @{reason='SkipFpsVrControl'}; return }
    if (!(Test-Path -LiteralPath $FpsVrCmd)) { throw "fpsVR command not found: $FpsVrCmd" }
    Mark "$Label-request" @{command=$FpsVrCmd;argument='logging_startstop'}
    $output = & $FpsVrCmd logging_startstop 2>&1
    Mark "$Label-response" @{exitCode=$LASTEXITCODE;output=($output -join "`n")}
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
    if (($output -join "`n") -match "Can't connect to fpsVR") {
        throw "$Label could not connect to the SteamVR-attached fpsVR logger; aborting without fallback."
    }
}
function Get-LatestFpsVrRawFile {
    if (!(Test-Path -LiteralPath $fpsVrCsvDirectory)) { return $null }
    return Get-ChildItem -LiteralPath $fpsVrCsvDirectory -Filter 'Frametimes#Raw#*.csv' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}
function Test-FpsVrRawRecordingActive {
    $file = Get-LatestFpsVrRawFile
    if (!$file) { return $false }
    $firstLength = $file.Length
    $firstWrite = $file.LastWriteTimeUtc
    Start-Sleep -Milliseconds 600
    $again = Get-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    return ($again -and ($again.Length -gt $firstLength -or $again.LastWriteTimeUtc -gt $firstWrite))
}
function Wait-FpsVrRawRecordingActive([double]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-FpsVrRawRecordingActive) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Start-FpsVrRawLogging {
    if ($SkipFpsVrControl) { Mark 'fpsvr-start-skipped' @{reason='SkipFpsVrControl'}; return }
    if (Wait-FpsVrRawRecordingActive 2.0) {
        $script:fpsVrWasAlreadyRecording = $true
        $active = Get-LatestFpsVrRawFile
        Mark 'fpsvr-already-recording' @{path=$active.FullName;length=$active.Length}
        return
    }
    Invoke-FpsVrToggle 'fpsvr-start'
    if (!(Wait-FpsVrRawRecordingActive 8.0)) { throw 'fpsVR raw logging did not begin growing after start.' }
    $script:fpsVrStarted = $true
    $active = Get-LatestFpsVrRawFile
    Mark 'fpsvr-recording-confirmed' @{path=$active.FullName;length=$active.Length}
}
function Stop-OwnedFpsVrRawLogging {
    if ($fpsVrStarted -and !$fpsVrWasAlreadyRecording) { Invoke-FpsVrToggle 'fpsvr-stop' }
}
try {
    if ($SaveNumberText) { $SaveNumbers = Convert-SaveNumberText $SaveNumberText }
    if ((!$SaveNumbers -or $SaveNumbers.Count -eq 0) -and $FirstSaveNumber -ge 0) { $SaveNumbers = @($FirstSaveNumber) }
    if (!$SaveNumbers -or $SaveNumbers.Count -eq 0) {
        throw 'Save numbers are required. Ask: Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12.'
    }
    $displaySaveNumbers = @($SaveNumbers | ForEach-Object { Format-SaveNumber $_ })
    Mark 'policy' @{protocol=$(if($DepthC){'depthc'}else{'game-ft'});provenance='deferred until after all holds by user instruction';savePolicy="explicit user authorization for save numbers: $($displaySaveNumbers -join ', ')";worldEntryBoundary=$(if($DepthC){'actual load entry separate from settled phase anchor'}else{'first observed completed world frame after a fresh loading serial; polling uncertainty retained'});timerSeconds=$(if($DepthC){20}else{60});tailSeconds=10;healthAcceptance='terminal completed generation and hard terminal gates; superseded metrics are retained as evidence'}
    Ensure-RuntimeMetadata
    if($DepthC){
        $runtime=Get-Content -LiteralPath "$RunDirectory/runtime.json" -Raw | ConvertFrom-Json
        $depthCProcessId=$runtime.pid
        $depthCProcessStartTicks=(Get-Process -Id $depthCProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
    }
    if (!(Test-Path -LiteralPath "$RunDirectory\save-selection.json")) {
        [void](Call 'save-selection' 'game' @{action='list'})
    }
    if (!(Test-Path -LiteralPath "$RunDirectory\main-menu-health.json")) {
        [void](Call 'main-menu-health' 'communityshaders.renderscale' @{action='status'} -Neutral)
    }
    if (!$FrustumPaired) { Start-FpsVrRawLogging }
    $selection = (Get-Content -LiteralPath "$RunDirectory\save-selection.json" -Raw | ConvertFrom-Json).data.content[0]
    $selectedSaves = @()
    foreach ($saveNumber in $SaveNumbers) {
        $matches = @($selection.saves | Where-Object { (Get-SaveNumberFromEntry $_) -eq $saveNumber })
        if ($matches.Count -ne 1) { throw "Save $(Format-SaveNumber $saveNumber) is not unique." }
        $selectedSaves += $matches[0]
    }
    $beforePath = if ($ResumeSecond) { "$RunDirectory\save-1-retained-health.json" } else { "$RunDirectory\main-menu-health.json" }
    $before = (Get-Content -LiteralPath $beforePath -Raw | ConvertFrom-Json).data.content[0].status
    if ($before.session.active) { throw 'An unrelated stress session is active.' }
    if ($FrustumPaired) {
        if (!$DepthC) { Assert-PairedState $before }
        $frustumOriginal = Get-PairedEnabled $before
        $pairPlan = if ($DepthC) { @(New-DepthCPlan $SaveNumbers) } else { @(New-FrustrumPlan $SaveNumbers) }
        $pairPlan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $(if ($DepthC) { "$RunDirectory/depthc-plan.json" } else { "$RunDirectory/frustrum-plan.json" })
        if ($DepthC) {
            Mark 'depthc-policy' @{schema='depthc-v1';holdSeconds=20;tailSeconds=10;healthSeconds=@(1,5,9,19);plan=$pairPlan;anchor='settled_control_phase';metricSettling='render recovery does not prove frame-time stability'}
        }
        else { Mark 'frustrum-policy' @{protocol='frustrum';version=1;controlledToggle=$pairedAction;depthJobBackoff=[bool]$DepthJobBackoff;order='OFF then ON for each save';originalEnabled=$frustumOriginal;plan=$pairPlan} }
    }
    if ($FrustumPaired) { Start-FpsVrRawLogging }
    $ordinal = if ($ResumeSecond) { 1 } else { 0 }
    $targets = if ($ResumeSecond) { @($selectedSaves | Select-Object -Skip 1) } else { $selectedSaves }
    if ($FrustumPaired) { $targets = @($pairPlan | ForEach-Object { $selectedSaves[$_.pairIndex - 1] }) }
    foreach ($save in $targets) {
        $ordinal++
        $label = "save-$ordinal"
        if ($FrustumPaired) {
            $leg = $pairPlan[$ordinal - 1]
            Mark $(if ($DepthC) { "$label-live-phase" } else { "$label-frustrum-leg" }) $leg
            if (!$DepthC) { Set-PairedToggle $label $leg }
        }
        $startLabel = "$label-health-start"
        $started = if ($LegacyRc166) { Call "$label-legacy-health-start" 'communityshaders.renderscale' @{action='status'} -Neutral }
            elseif ($DepthC) { Start-DepthCHealth $startLabel }
            else { Call $startLabel 'communityshaders.renderscale' @{action='start'} -Neutral }
        if (!$LegacyRc166 -and !$started.status.session.active) { throw "$label health recorder did not become active." }
        if (!$LegacyRc166) { $sessionId = $started.status.session.id }
        if ($FrustumPaired -and !$DepthC) { Assert-PairedState $started.status $leg.enabled }
        $before = $started.status
        if (!$DepthC -or $leg.firstInSave) {
        $oldSerial = $before.vendorWorkGate.stabilizerSync.loadingSerial
        if ($LegacyRc166) {
            $loadState = Call "$label-legacy-before-load" 'inspect' @{kind='state'}
            $legacyProcessId = (Get-Content -LiteralPath "$RunDirectory/runtime.json" -Raw | ConvertFrom-Json).pid
            $legacyPreviousFrame = $loadState.frame
            $freshLegacyLoad = $false
        }
        Mark "$label-load-boundary" @{name=$save.name;location=$save.meta.location;oldLoadingSerial=$oldSerial}
        Write-Output "Loading $($save.name)"
        $loaded = Call "$label-load" 'game' @{action='load';name=$save.name;dir=$selection.dir}
        $loadDeadline = $clock.Elapsed.TotalSeconds + 120
        $poll = 0
        $lastNotWorld = $clock.Elapsed.TotalSeconds
        do {
            if ($clock.Elapsed.TotalSeconds -ge $loadDeadline) { throw "$label did not reach an observed world frame within 120 seconds." }
            $poll++
            try {
                if ($LegacyRc166) {
                    $menus = Call "$label-legacy-menu-$poll" 'menu' @{action='list'}
                    if (@($menus.openMenus | Where-Object { $_ -in @('Loading Menu','LoadingMenu') }).Count) { $freshLegacyLoad = $true }
                    $loadState = Call "$label-legacy-entry-$poll" 'inspect' @{kind='state'}
                    if ($loadState.playerLoaded -is [bool] -and !$loadState.playerLoaded) { $freshLegacyLoad = $true }
                    $world = Test-LegacyRc166LoadBoundary $loadState $menus $legacyProcessId $legacyPreviousFrame $freshLegacyLoad
                } else { $observation = Call "$label-entry-$poll" 'communityshaders.renderscale' @{action='status'} }
            }
            catch {
                if ($_.Exception.Message -notmatch 'Timeout|timed.out|was canceled|main_thread_busy|main_thread_in_progress|main_thread_timeout') { throw }
                Mark "$label-loading-transient" @{message=$_.Exception.Message}
                $world=$false
                Start-Sleep -Milliseconds 200
                continue
            }
            if (!$LegacyRc166) {
                $gate = $observation.status.vendorWorkGate
                $fresh = $gate.stabilizerSync.loadingSerial -gt $oldSerial
                $world = $fresh -and !$gate.mainMenu -and !$gate.loadingMenu -and $gate.completedWorldFrame
            }
            if (!$world) { $lastNotWorld=$clock.Elapsed.TotalSeconds; Start-Sleep -Milliseconds 200 }
        } until ($world)
        if ($FrustumPaired -and !$DepthC) { Assert-PairedState $observation.status $leg.enabled }
        $origin = $clock.Elapsed.TotalSeconds
        if ($LegacyRc166) {
            Mark "$label-world-entry" @{name=$save.name;frame=$loadState.frame;lastNotWorldElapsedSeconds=$lastNotWorld;observationElapsedSeconds=$origin;boundaryExact=$false;boundarySource='legacy_player_loaded_menu_clear';completedWorldFrameVerified=$false}
        } else { Mark $(if ($DepthC) { "$label-load-world-entry" } else { "$label-world-entry" }) @{name=$save.name;frame=$observation.status.frame;loadingSerial=$gate.stabilizerSync.loadingSerial;lastNotWorldElapsedSeconds=$lastNotWorld;observationElapsedSeconds=$origin;stabilizerSync=$gate.stabilizerSync;boundaryExact=$false} }
        }
        if ($DepthC) {
            if ($leg.firstInSave) {
                [void](Wait-LiveRecovery "$label-initial")
                $profile=Invoke-DepthCProfileCall "$label-original" 'snapshot'
                $depthCOriginalProfile=Convert-DepthCProfile $profile.snapshot.profiles.configured
                $menu=(Call "$label-original-controls" 'communityshaders.menu' @{action='status'}).status
                $depthCOriginalControls=Get-DepthCControlState $menu
                if($depthCOriginalControls.depthCullingPerformanceMode -and $depthCOriginalControls.depthCullingLegacyMode){throw 'Both temporal policy flags are set; exact restoration via supported setters is unavailable.'}
                Assert-DepthCControls $menu $depthCOriginalControls
                if ($menu.depthCulling.currentInterior -isnot [bool]) { throw 'Current interior/exterior cell is unknown.' }
                $depthCInterior=$menu.depthCulling.currentInterior
                $depthCWorldEntryLabel="$label-load-world-entry"
                Mark "$label-depthc-original" @{profile=$depthCOriginalProfile;controls=$depthCOriginalControls;interior=$depthCInterior}
                $depthCRestoreNeeded=$true
            }
            if ($leg.condition -eq 'Interior-OFF' -and !$depthCInterior) {
                $stop=Call "$label-inapplicable-stop" 'communityshaders.renderscale' @{action='stop';expectedSessionId=$sessionId} -Neutral
                $sessionId=$null
                Mark "$label-depthc-inapplicable" @{reason='Exterior cell: interior-only control cannot affect this scene';condition=$leg.condition;mode=$leg.mode}
                continue
            }
            $baselineControls=Get-DepthCConditionControls 'Balanced' $depthCOriginalControls
            [void](Set-DepthCControls "$label-baseline" $baselineControls)
            if ($leg.conditionIndex -eq 1) {
                $target=@{}; foreach($key in $depthCOriginalProfile.Keys){$target[$key]=$depthCOriginalProfile[$key]}
                $target.method=$leg.method; $target.qualityMode=$leg.qualityMode; $target.renderScaleMode=$leg.renderScaleMode
                if($leg.method -eq 'fsr'){$target.fsrRuntime='fsr3'}
                Set-DepthCProfile $label $target
            }
            $leg | Add-Member -NotePropertyName dlssPreset -NotePropertyValue ([array]::IndexOf(@('J','K','L','M','F','E'),$target.dlssProfile)) -Force
            $leg | Add-Member -NotePropertyName fsrRuntime -NotePropertyValue $target.fsrRuntime -Force
            $depthCExpectedControls=Get-DepthCConditionControls $leg.condition $depthCOriginalControls
            [void](Set-DepthCControls $label $depthCExpectedControls)
            $recovered=Wait-LiveRecovery $label $leg
            Assert-DepthCMode $recovered.status $leg
            $liveRouting=Get-DepthCRouting $recovered.status
            $setupStop=Call "$label-setup-stop" 'communityshaders.renderscale' @{action='stop';expectedSessionId=$sessionId} -Neutral
            $sessionId=$null
            Assert-DepthCRecovered $setupStop $liveRouting $leg
            $started=Start-DepthCHealth "$label-phase-health-start"
            if(!$started.status.session.active){throw 'Phase health recorder did not start.'}
            $sessionId=$started.status.session.id
            $admission=Call "$label-phase-admission" 'communityshaders.renderscale' @{action='record'}
            Assert-DepthCRecovered $admission $liveRouting $leg
            Assert-DepthCControls $admission.status $depthCExpectedControls
            $depthCDropped=$admission.status.compositorSubmission.droppedObservations
            $depthCCell=$admission.status.depthCulling.currentCellFormId
            $depthCCollection=$admission.status.nativeFrustum.collectionGeneration
            $depthCBackoffControl=$admission.status.nativeFrustum.depthJobs.backoff.control
            $origin=$clock.Elapsed.TotalSeconds
            Mark "$label-phase-entry" @{name=$save.name;location=$save.meta.location;kind='settled_control_phase';condition=$leg.condition;sceneIndex=$leg.pairIndex;mode=$leg.mode;routing=$liveRouting;actualWorldEntryLabel=$depthCWorldEntryLabel;holdSeconds=20;tailStartSeconds=10;compositorDroppedObservations=$depthCDropped;observationElapsedSeconds=$origin}
            Write-Output "$label $($leg.mode) / $($leg.condition): 20-second phase after render recovery; CPU/GPU noise remains measured."
        } else { Write-Output "$label world observed; 60-second hold started." }
        $holdSeconds=if($DepthC){20}else{60}
        $healthSeconds=if($DepthC){@(1,5,9,19)}else{@(1,5,20,49,59)}
        foreach ($sample in $healthSeconds) {
            while ($clock.Elapsed.TotalSeconds -lt $origin+$sample) { Start-Sleep -Milliseconds 100 }
            $observation = if ($LegacyRc166) { Call "$label-legacy-health-$sample" 'communityshaders.renderscale' @{action='status'} }
                else { Call "$label-health-$sample" 'communityshaders.renderscale' @{action='record'} }
            if ($FrustumPaired -and !$DepthC) { Assert-PairedState $observation.status $leg.enabled }
            if ($DepthC) {
                Assert-DepthCRecovered $observation $liveRouting $leg
                Assert-DepthCControls $observation.status $depthCExpectedControls
                if ($observation.status.compositorSubmission.droppedObservations -ne $depthCDropped -or $observation.status.depthCulling.currentCellFormId -ne $depthCCell -or $observation.status.nativeFrustum.collectionGeneration -ne $depthCCollection -or
                    $observation.status.nativeFrustum.depthJobs.backoff.control -ne $depthCBackoffControl) { throw 'Diagnostic generation/control changed within depthc hold.' }
            }
            $before = $observation.status
        }
        while ($clock.Elapsed.TotalSeconds -lt $origin+$holdSeconds) { Start-Sleep -Milliseconds 50 }
        Mark "$label-hold-end" @{name=$save.name;originElapsedSeconds=$origin;durationSeconds=$clock.Elapsed.TotalSeconds-$origin}
        Write-Output "$label $holdSeconds-second hold complete."
        if ($LegacyRc166) {
            $stopped = Call "$label-legacy-health-stop" 'communityshaders.renderscale' @{action='status'} -Neutral
            Mark "$label-legacy-health-unavailable" @{strictLifecycle='not exposed by this build';statusFrame=$stopped.status.frame}
        } else {
            $stopped = Call "$label-health-stop" 'communityshaders.renderscale' @{action='stop';expectedSessionId=$sessionId} -Neutral
            Mark "$label-health-recorder-stopped" @{sessionId=$sessionId;statusFrame=$stopped.status.frame}
        }
        $sessionId = $null
        if ($FrustumPaired) {
            if (!$DepthC) { Assert-PairedState $stopped.status $leg.enabled }
            if ($DepthC) {
                Assert-DepthCRecovered $stopped $liveRouting $leg
                Assert-DepthCControls $stopped.status $depthCExpectedControls
                if ($stopped.status.compositorSubmission.droppedObservations -ne $depthCDropped -or $stopped.status.depthCulling.currentCellFormId -ne $depthCCell -or $stopped.status.nativeFrustum.collectionGeneration -ne $depthCCollection -or $stopped.status.nativeFrustum.depthJobs.backoff.control -ne $depthCBackoffControl) { throw 'Diagnostic control changed at stop.' }
            }
            Mark $(if ($DepthC) { "$label-live-verified" } else { "$label-frustrum-verified" }) $leg
        }
        $before = $stopped.status
        if ($DepthC -and $leg.lastInSave) { Restore-DepthCScene $label }
    }
    Mark 'requested-holds-complete' @{saveNumbers=$displaySaveNumbers}
} catch {
    Mark 'run-error' @{message=$_.Exception.Message}
    Write-Output "MEASUREMENT ERROR: $($_.Exception.Message)"
} finally {
    if ($DepthC -and $depthCPendingOwner) {
        try { [void](Resolve-DepthCStart 'final-start') }
        catch { Mark 'health-start-cleanup-error' @{message=$_.Exception.Message;ownerToken=$depthCPendingOwner} }
        if($depthCPendingOwner){Mark 'health-start-unresolved' @{ownerToken=$depthCPendingOwner;reason='No attributable active session; do not replay or stop another owner.'}}
    }
    if ($sessionId) {
        try { $stopped = Call 'health-stop' 'communityshaders.renderscale' @{action='stop';expectedSessionId=$sessionId} -Neutral; Mark 'health-recorder-stopped' @{sessionId=$sessionId} }
        catch { Mark 'health-cleanup-error' @{sessionId=$sessionId;message=$_.Exception.Message}; Write-Output "Health cleanup needs inspection: $($_.Exception.Message)" }
    }
    if ($DepthC -and $depthCRestoreNeeded -and !$depthCForeignRecorder) {
        try { Restore-DepthCScene 'final' }
        catch { Mark 'depthc-cleanup-error' @{message=$_.Exception.Message}; Write-Output "Depthc restoration needs inspection: $($_.Exception.Message)" }
    }
    if ($frustumRestoreNeeded) {
        try {
            $restored = Call 'frustrum-restore' 'communityshaders.menu' @{action=$pairedAction;enabled=$frustumOriginal}
            $restoredEnabled = Get-PairedEnabled $restored.status
            if ($restoredEnabled -isnot [bool] -or $restoredEnabled -ne $frustumOriginal) { throw 'Original paired toggle was not restored.' }
            Mark 'frustrum-restored' @{enabled=$frustumOriginal}
        } catch { Mark 'frustrum-cleanup-error' @{message=$_.Exception.Message}; Write-Output "Frustum restoration needs inspection: $($_.Exception.Message)" }
    }
    if ($fpsVrStarted) {
        try { Stop-OwnedFpsVrRawLogging }
        catch { Mark 'fpsvr-stop-error' @{message=$_.Exception.Message}; Write-Output "fpsVR stop needs inspection: $($_.Exception.Message)" }
    }
    $journalName = if ($ResumeSecond) { 'resume-journal.json' } else { 'run-journal.json' }
    $journal | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath "$RunDirectory\$journalName"
    Write-Output "CAPTURE CONTROL COMPLETE: $RunDirectory"
}
