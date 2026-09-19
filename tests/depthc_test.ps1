#Requires -Version 7.0
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'tools/frustrum/Frustrum.psm1') -Force
Import-Module (Join-Path $repo 'tools/depthc/DepthC.psm1') -Force
$checks=0
function Test-DepthCAssert([bool]$Value,[string]$Message){$script:checks++;if(!$Value){throw $Message}}
$plan=@(New-DepthCPlan @(8,11))
Test-DepthCAssert ($plan.Count -eq 96) 'Six modes/eight conditions must be retained per save.'
Test-DepthCAssert (($plan | Where-Object firstInSave).Count -eq 2) 'Each save must load once.'
Test-DepthCAssert (($plan | Where-Object lastInSave).Count -eq 2) 'Each save requires restoration.'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('depthc-'+[guid]::NewGuid().ToString('N'))
foreach($folder in @('tools/depthc','tools/frustrum','tools/gameft-sw/protocol')){New-Item -ItemType Directory -Path (Join-Path $fixture $folder) -Force | Out-Null}
Copy-Item (Join-Path $repo 'tools/depthc/DepthC.psm1') (Join-Path $fixture 'tools/depthc/DepthC.psm1')
Copy-Item (Join-Path $repo 'tools/frustrum/Frustrum.psm1') (Join-Path $fixture 'tools/frustrum/Frustrum.psm1')
$runner=Get-Content (Join-Path $repo 'tools/gameft-sw/protocol/Invoke-SaveLoadTimingV2.ps1') -Raw
$runner=$runner.Replace('$clock = [Diagnostics.Stopwatch]::StartNew()','$clock = $global:DepthCTestClock')
$runnerPath=Join-Path $fixture 'tools/gameft-sw/protocol/Invoke-SaveLoadTimingV2.ps1'
[IO.File]::WriteAllText($runnerPath,$runner)
$controller=Join-Path $fixture 'controller.ps1'
@'
param($Tool,$ArgumentsJson,$EvidenceLabel,[int]$RequestTimeoutSeconds,[int]$TimeoutSeconds,[switch]$SkipRuntimeIdentityVerification,[Parameter(ValueFromRemainingArguments)]$Unused)
$a=$ArgumentsJson|ConvertFrom-Json -AsHashtable
$global:DepthCCalls.Add(@{label=$EvidenceLabel;tool=$Tool;args=$a;time=$global:DepthCTestClock.Elapsed.TotalSeconds;requestTimeout=$RequestTimeoutSeconds;timeout=$TimeoutSeconds;skipIdentity=[bool]$SkipRuntimeIdentityVerification})
if($Tool.StartsWith('communityshaders.') -and $a.expectedBuildId -ne ('a'*64)){throw 'Missing build identity.'}
function NamedProfile($p){$out=@{};foreach($k in $p.Keys){$out[$k]=if($k -eq 'renderScaleMode'){$p[$k]}else{@{name=$p[$k];value=0}}};return $out}
if($Tool -eq 'communityshaders.upscaling_api'){
 $p=@{status=@{name='success'}}
 switch($a.action){
  'snapshot'{$p.snapshot=@{stateRevision=1;profiles=@{configured=(NamedProfile $global:DepthCProfile);effective=(NamedProfile $global:DepthCProfile)}}}
  'preflight'{$p.preflight=@{requiresRestart=$false;willPersist=$false;decision=@{name='apply_synchronously'};normalizedTarget=(NamedProfile $a.target)}}
  'apply'{
   if($a.persistence -ne 'runtime_only'){throw 'Persistent write attempted.'}
   $global:DepthCProfile=$a.target
   if($global:DepthCFailure -eq 'profile-timeout' -and $EvidenceLabel -notmatch 'restore'){throw 'Profile timeout after applying.'}
   $p.apply=@{requiresRestart=$false;willPersist=$false;disposition=@{name='applied_synchronously'};operationId=1;normalizedTarget=(NamedProfile $a.target)}
  }
  'operation'{$p.operation=@{state=@{name='completed'};result=@{name='success'};target=(NamedProfile $global:DepthCProfile);effective=(NamedProfile $global:DepthCProfile)}}
  default {throw 'Unknown profile action.'}
 }
 @{transportOk=$true;data=@{rawResult=@{isError=$false};content=@($p)}}|ConvertTo-Json -Depth 30 -Compress
 return
}
if($Tool -eq 'communityshaders.menu'){
 $map=@{set_depth_culling_enabled='masterEnabled';set_depth_culling_interior_enabled='interiorEnabled';set_depth_culling_performance_mode='performanceMode';set_depth_culling_legacy_mode='legacyMode';set_frustum_fast_path_enabled='fast';set_depth_job_backoff_enabled='backoff'}
 if($a.action -ne 'status'){
  if(!$map.ContainsKey($a.action)){throw 'Unexpected setting mutation.'}
  $global:DepthCFlags[$map[$a.action]]=$a.enabled
  if($global:DepthCFailure -eq 'setter-timeout' -and $EvidenceLabel -notmatch 'restore'){throw 'Setter timeout after applying.'}
 }
}
if($Tool -eq 'game' -and $a.action -eq 'load'){$global:DepthCSerial++;$global:DepthCProfile=@{method='dlss';qualityMode='native_aa';renderScaleMode=$false;dlssProfile='K';fsrRuntime='fsr4'}}
if($a.action -eq 'start'){
 if($global:DepthCFailure -eq 'start-not-applied'){throw 'HTTP response lost before dispatch.'}
 $global:DepthCActive=$true;$global:DepthCSessionId++;$global:DepthCOwner=$a.captureOwnerToken
 if($global:DepthCFailure -eq 'foreign-start'){
  $global:DepthCOwner='f'*32;throw 'Foreign start raced the request.'
 }
 if($global:DepthCFailure -in @('lost-start','lost-status') -and $EvidenceLabel -eq 'save-1-phase-health-start'){throw 'HTTP response lost after session started.'}
 if($global:DepthCFailure -eq 'lost-initial-start' -and $EvidenceLabel -eq 'save-1-health-start'){throw 'Initial start response lost.'}

}
if($global:DepthCFailure -eq 'lost-status' -and $EvidenceLabel -like '*reconcile-1-owner-status'){throw 'Status transport unavailable.'}
if($global:DepthCFailure -eq 'lost-initial-start' -and $Tool -eq 'game' -and $a.action -eq 'load'){throw 'Fixture ends after initial-start recovery.'}
if($a.action -eq 'stop'){
 if($a.expectedSessionId -ne $global:DepthCSessionId -or $a.expectedOwnerToken -cne $global:DepthCOwner){throw 'Stop ownership mismatch.'}
 $global:DepthCActive=$false
}
$q=if($global:DepthCProfile.qualityMode -eq 'native_aa'){0}else{1}
$rs=$global:DepthCProfile.renderScaleMode
$flags=$global:DepthCFlags
$depth=@{schemaVersion=1;available=$true;masterEnabled=$flags.masterEnabled;interiorEnabled=$flags.interiorEnabled;performanceMode=$flags.performanceMode;legacyMode=$flags.legacyMode;telemetryEnabled=$true;currentInterior=$true;currentCellFormId=123;cacheRefreshPending=$false;nativeEnabled=($flags.masterEnabled -and $flags.interiorEnabled)}
$status=@{
 session=@{active=$global:DepthCActive;id=$global:DepthCSessionId;ownerSchemaVersion=$(if($global:DepthCFailure -eq 'missing-owner-schema'){0}else{1});ownerToken=$global:DepthCOwner};frame=1;depthCulling=$depth
 runtimeRouting=@{runtimeDLSSPreset=([array]::IndexOf(@('J','K','L','M','F','E'),$global:DepthCProfile.dlssProfile));configuredFsrRuntime=$global:DepthCProfile.fsrRuntime;configuredMethod=$global:DepthCProfile.method;runtimeMethod=$global:DepthCProfile.method;runtimeQualityMode=$q;renderScaleRequested=$rs;renderScaleLatched=$rs;presentationUpscalingActive=$rs}
 frustumFastPath=@{schemaVersion=2;implementation='single_traversal';installed=$true;enabled=$flags.fast;verification=$false;mismatchLatched=$false;effectiveMode=$(if($flags.fast){'fast'}else{'native'})}
 nativeFrustum=@{schemaVersion=2;enabled=$true;active=$true;detailEnabled=$true;collectionGeneration=1;collectionGenerationAtEnd=1;depthJobs=@{schemaVersion=1;installed=$true;active=$true;backoff=@{schemaVersion=1;enabled=$flags.backoff;active=$flags.backoff;control=[int]$flags.backoff;controlAtEnd=[int]$flags.backoff}}}
 vendorWorkGate=@{stabilizerSync=@{loadingSerial=$global:DepthCSerial};mainMenu=$false;loadingMenu=$false;completedWorldFrame=$true;active=$false;recoveryPending=$false;relatchPending=$false;relatchInProgress=$false;profileTransitionPending=$false;postLoadResetPending=$false}
 compositorSubmission=@{schemaVersion=1;observedDropCount=0;current=@{poisoned=$false};droppedObservations=0;lastCompleted=@{valid=$true;poisoned=$false;eyeMask=3;frame=1;compositorCycleToken=1;methodValue=$(if($global:DepthCProfile.method -eq 'dlss'){3}else{2});qualityMode=$q;renderScaleMode=$rs;mainPassCompletedFrame=1;mainPassFsrDispatchFrame=1;mainPassFsrDispatchPath='kHostFsr31';mainPassFsrDispatchSerial=1}}
 mainPassDispatch=@{completedVendorFrame=1;fsrDispatch=@{valid=$true;frame=1;serial=1;path='kHostFsr31'}}
 fsrDispatch=@{actualDispatchFrame=1;shaderCompilationActive=$false;authoritativeFsr4RuntimeEnabled=$false;actualDispatchBothEyesValid=$true;actualDispatchBackendConverged=$true;actualDispatchBackend='fsr_host';actualRuntimeFallbackObserved=$false}
}
$gateNames=@('terminal_state','no_failures','no_out_of_memory','no_device_loss','fidelity_invariants','presentation_stretch_complete_stereo_at_stop','presentation_stretch_inactive_at_stop','retirement_drained','common_target_predrain','memory_trim_failures','memory_trim_drained','backend_ready','vendor_lifecycle_mutation_released','presentation_recovered')
$record=@{schema='community-shaders.vr-render-scale.iteration';schemaVersion=14;acceptance=@{gates=@($gateNames|ForEach-Object{@{name=$_;passed=$true}})};presentationPath=@{allowedPresentationStretch=@{episodeActive=$false;activeAtStop=$false;incompleteStereoCycleAtStop=$false}}}
switch($global:DepthCFailure){
 'active-tail' {$record.presentationPath.allowedPresentationStretch.activeAtStop=$true}
 'stereo' {$record.presentationPath.allowedPresentationStretch.incompleteStereoCycleAtStop=$true}
 'missing-gate' {$record.acceptance.gates=@($record.acceptance.gates|Where-Object name -NE 'backend_ready')}
 'future-schema' {$record.schemaVersion=15}
 'compile' {$status.fsrDispatch.shaderCompilationActive=$true}
 'preset-drift' {if($EvidenceLabel -eq 'save-1-health-9'){$status.runtimeRouting.runtimeDLSSPreset=2}}
 'runtime-drift' {if($EvidenceLabel -eq 'save-1-health-9'){$status.runtimeRouting.configuredFsrRuntime='fsr3'}}
 'health-mode' {if($EvidenceLabel -eq 'save-1-health-9'){$status.runtimeRouting.runtimeQualityMode=3}}
 'health-control' {if($EvidenceLabel -eq 'save-1-health-9'){$status.depthCulling.masterEnabled=$false}}
 'health-generation' {if($EvidenceLabel -eq 'save-1-health-9'){$status.nativeFrustum.collectionGeneration=2}}
 'wrong-fsr' {if($global:DepthCProfile.method -eq 'fsr'){$status.fsrDispatch.actualDispatchBackend='fsr4_runtime';$status.mainPassDispatch.fsrDispatch.path='kRuntimeFsr4';$status.compositorSubmission.lastCompleted.mainPassFsrDispatchPath='kRuntimeFsr4'}}
 'stale-proof' {$status.frame=10}
 'poisoned-proof' {$status.compositorSubmission.current.poisoned=$true}
 'future-proof' {$status.compositorSubmission.schemaVersion=2}
 'missing-mainpass' {$status.compositorSubmission.lastCompleted.mainPassCompletedFrame=0}
 'dropped-proof' {if($EvidenceLabel -eq 'save-1-health-9'){$status.compositorSubmission.droppedObservations=1}}
 'fsr-fallback' {if($global:DepthCProfile.method -eq 'fsr'){$status.mainPassDispatch.fsrDispatch.path='kHostFsr31Fallback';$status.compositorSubmission.lastCompleted.mainPassFsrDispatchPath='kHostFsr31Fallback';$status.fsrDispatch.actualRuntimeFallbackObserved=$true}}
 'exterior' {$status.depthCulling.currentInterior=$false;$status.depthCulling.nativeEnabled=$flags.masterEnabled}
 'pending-cache' {$status.depthCulling.cacheRefreshPending=$true}

}
$p=@{status=$status;record=$record}
if($Tool -eq 'game' -and $a.action -eq 'list'){$p=@{dir='fixture';saves=@(@{name='Save8_Test';meta=@{saveNumber=8;saveType='save';location='A'}},@{name='Save11_Test';meta=@{saveNumber=11;saveType='save';location='B'}})}}
@{transportOk=$true;data=@{rawResult=@{isError=$false};content=@($p)}}|ConvertTo-Json -Depth 30 -Compress
'@|Set-Content $controller
function Invoke-DepthCFixture([string]$Name){
 $run=Join-Path $fixture $Name;New-Item -ItemType Directory $run|Out-Null
 @{pid=123;exe='fixture';port=8921}|ConvertTo-Json|Set-Content (Join-Path $run 'runtime.json')
 $global:DepthCCalls=[Collections.Generic.List[object]]::new()
 $global:DepthCTestClock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0.0}}
 $global:DepthCSerial=0;$global:DepthCActive=$false;$global:DepthCSessionId=0;$global:DepthCOwner=''
 $global:DepthCFlags=@{masterEnabled=$true;interiorEnabled=$true;performanceMode=$true;legacyMode=$false;fast=$false;backoff=$false}
 $global:DepthCProfile=@{method='dlss';qualityMode='native_aa';renderScaleMode=$false;dlssProfile='K';fsrRuntime='fsr4'}
 function Get-Process {param([int]$Id) [pscustomobject]@{Id=$Id;StartTime=[datetime]'2026-09-19T00:00:00Z'}}
 function Start-Sleep {param([int]$Milliseconds)$global:DepthCTestClock.Elapsed.TotalSeconds+=$Milliseconds/1000.0}
 &$runnerPath -DepthC -RunDirectory $run -SaveNumberText '08, 11' -FpsVrCmd unused -Controller $controller -SkipFpsVrControl -ExpectedBuildId ('a'*64)|Out-Null
 return $run
}
# A successful start with a lost HTTP reply must remain attributable and stoppable.
$global:DepthCFailure='lost-start';$lostStart=Invoke-DepthCFixture 'lost-start'
Test-DepthCAssert (!$global:DepthCActive) 'Lost start reply leaked an active recorder.'
Test-DepthCAssert (@($global:DepthCCalls|Where-Object label -EQ 'save-1-phase-health-start').Count -eq 1) 'Lost start was replayed.'
$lostMarkers=@(Get-Content (Join-Path $lostStart 'markers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
Test-DepthCAssert (@($lostMarkers|Where-Object label -EQ 'requested-holds-complete').Count -eq 1) 'Exact-owner reconciliation did not finish the matrix.'
foreach($failure in @('foreign-start','start-not-applied','missing-owner-schema','lost-initial-start')){
 $global:DepthCFailure=$failure;$failed=Invoke-DepthCFixture $failure
 $m=@(Get-Content (Join-Path $failed 'markers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
 Test-DepthCAssert (@($m|Where-Object label -EQ 'run-error').Count -eq 1) "Missing failure for $failure."
 $stops=@($global:DepthCCalls|Where-Object {$_.tool -eq 'communityshaders.renderscale' -and $_.args.action -eq 'stop'})
 Test-DepthCAssert (($failure -eq 'lost-initial-start' -and $stops.Count -eq 1) -or ($failure -ne 'lost-initial-start' -and $stops.Count -eq 0)) "Unsafe or missing cleanup for $failure."
 Test-DepthCAssert ($global:DepthCActive -eq ($failure -eq 'foreign-start')) "Wrong final ownership for $failure."
 Test-DepthCAssert (@($global:DepthCCalls|Where-Object {$_.args.action -eq 'start'}).Count -le 1) 'Indeterminate start was repeated.'
}
$global:DepthCFailure='';$run=Invoke-DepthCFixture 'matrix'
$markers=@(Get-Content (Join-Path $run 'markers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
Test-DepthCAssert (@($markers|Where-Object label -EQ 'requested-holds-complete').Count -eq 1) "Matrix did not complete: $((@($markers|Where-Object label -EQ 'run-error').detail|ConvertTo-Json -Compress))"
$calls=@($global:DepthCCalls)
foreach($call in @($calls|Where-Object {$_.args.action -in @('start','stop')})){
 Test-DepthCAssert ($call.requestTimeout -eq 10 -and $call.timeout -eq 15 -and $call.skipIdentity) 'Recorder setup must use bounded longer deadlines with deferred physical provenance.'
}
foreach($call in @($calls|Where-Object label -Match '-health-(1|5|9|19)$')){
 Test-DepthCAssert ($call.requestTimeout -eq 3 -and $call.timeout -eq 8) 'Measured health-call deadline changed.'
}

Test-DepthCAssert (@($calls|Where-Object {$_.tool -eq 'game' -and $_.args.action -eq 'load'}).Count -eq 2) 'Wrong load count.'
Test-DepthCAssert (@($markers|Where-Object label -Match '^save-\d+-load-world-entry$').Count -eq 2) 'Actual world entries conflated with phases.'
Test-DepthCAssert (@($markers|Where-Object label -Match '^save-\d+-phase-entry$').Count -eq 96) 'Missing matrix phase anchors.'
foreach($n in 1..96){
 $entry=$markers|Where-Object label -EQ "save-$n-phase-entry";$end=$markers|Where-Object label -EQ "save-$n-hold-end"
 Test-DepthCAssert ($end.detail.durationSeconds -ge 20 -and $end.detail.durationSeconds -lt 20.11) 'Wrong hold duration.'
 foreach($second in @(1,5,9,19)){
  $call=$calls|Where-Object label -EQ "save-$n-health-$second";$offset=$call.time-$entry.elapsedSeconds
  Test-DepthCAssert ($offset -ge $second -and $offset -lt $second+0.11) 'Depthc health schedule changed.'
 }
}
Test-DepthCAssert ($global:DepthCFlags.performanceMode -and !$global:DepthCFlags.fast -and !$global:DepthCFlags.backoff) 'Original controls not restored.'
Test-DepthCAssert ($global:DepthCProfile.qualityMode -eq 'native_aa' -and $global:DepthCProfile.fsrRuntime -eq 'fsr4' -and $global:DepthCProfile.dlssProfile -eq 'K') 'Original profile/presets not restored.'

$quick=foreach($p in $plan){[pscustomobject]@{save="save-$($p.ordinal)";name=$(if($p.pairIndex -eq 1){'Save8_Test'}else{'Save11_Test'});timingComplete=$true;cpuTailMeanMs=$(if($p.conditionIndex -eq 1){10}else{9});gpuTailMeanMs=8;lifecycle=@{finalSuccessful=$true}}}
ConvertTo-Json -InputObject @($quick) -Depth 10|Set-Content (Join-Path $run 'quick-summary.json')
$table=&(Join-Path $repo 'tools/depthc/Show-DepthCComparison.ps1') -RunDirectory $run
Test-DepthCAssert (($table -join "`n").Contains('9 (-1.000)')) 'Depthc comparison delta is incorrect.'
$reported=@(Get-Content (Join-Path $run 'depthc-summary.json') -Raw|ConvertFrom-Json)
Test-DepthCAssert ($reported.Count -eq 96 -and @($reported|Where-Object {!$_.complete}).Count -eq 0) 'Depthc condition identity/completeness lost.'
$quick=@($quick|Where-Object save -NE 'save-2')
ConvertTo-Json -InputObject $quick -Depth 10|Set-Content (Join-Path $run 'quick-summary.json')
$table=&(Join-Path $repo 'tools/depthc/Show-DepthCComparison.ps1') -RunDirectory $run
Test-DepthCAssert (($table -join "`n").Contains('Performance: Incomplete phase')) 'Missing matrix phase silently compared.'

# Synthetic CSV proves only the explicit phase tail is measured, not load/warmup/tail.
$timing=Join-Path $fixture 'timing';New-Item -ItemType Directory $timing|Out-Null
$base=[datetime]'2026-09-19T00:00:00Z'
$timingMarkers=@(
 @{label='depthc-policy';utc=$base.ToString('o');elapsedSeconds=0;qpc=0;qpcFrequency=1;detail=@{schema='depthc-v1';holdSeconds=20;tailSeconds=10}},
 @{label='save-1-load-world-entry';utc=$base.AddSeconds(5).ToString('o');elapsedSeconds=5;qpc=5;qpcFrequency=1;detail=@{}},
 @{label='save-1-phase-entry';utc=$base.AddSeconds(60).ToString('o');elapsedSeconds=60;qpc=60;qpcFrequency=1;detail=@{name='Save8_Test';location='A';holdSeconds=20}},
 @{label='save-1-hold-end';utc=$base.AddSeconds(80).ToString('o');elapsedSeconds=80;qpc=80;qpcFrequency=1;detail=@{}}
)
$timingMarkers|ForEach-Object{$_|ConvertTo-Json -Compress}|Set-Content (Join-Path $timing 'markers.jsonl')
$csv=@('fixture','x/y/z/2026-09-19T00:00:00Z','SteamVR Time,FPS,GPU frametime,CPU frametime,GPU Usage,CPU Usage')
foreach($tick in 0..899){$t=$tick/10.0;$cpu=if($t -ge 70 -and $t -lt 80){10}elseif($t -ge 60 -and $t -lt 70){25}else{999};$gpu=if($t -ge 70 -and $t -lt 80){8}else{777};$csv+="$t,90,$gpu,$cpu,1,1"}
$csvPath=Join-Path $timing 'fixture.csv';$csv|Set-Content $csvPath
&(Join-Path $repo 'tools/gameft-sw/protocol/Show-SaveLoadTimingQuickReport.ps1') -RunDirectory $timing -FpsVrCsv $csvPath|Out-Null
$timed=Get-Content (Join-Path $timing 'quick-summary.json') -Raw|ConvertFrom-Json
Test-DepthCAssert ($timed.cpuTailMeanMs -eq 10 -and $timed.gpuTailMeanMs -eq 8 -and $timed.samples -eq 200 -and $timed.tailStartSeconds -eq 10) 'Phase final ten seconds not isolated.'
Test-DepthCAssert ($timed.cpuSingleSpikeFrequency.frequencyPerSecond -eq 0 -and $timed.gpuSpikeGroups.frequencyPerSecond -eq 0) 'Warmup spikes leaked into tail noise.'
# Empty/gapped tails remain unavailable, never a complete zero-cost measurement.
$csv | Select-Object -First 680 | Set-Content $csvPath
&(Join-Path $repo 'tools/gameft-sw/protocol/Show-SaveLoadTimingQuickReport.ps1') -RunDirectory $timing -FpsVrCsv $csvPath|Out-Null
$missingTail=Get-Content (Join-Path $timing 'quick-summary.json') -Raw|ConvertFrom-Json
Test-DepthCAssert ($missingTail.timingComplete -eq $false -and $null -eq $missingTail.cpuTailMeanMs) 'Empty tail fabricated a zero-cost result.'
Import-Module (Join-Path $repo 'tools/gameft-sw/GameFtStackWait.psm1') -Force
$trace=Join-Path $timing 'stack-wait';New-Item -ItemType Directory $trace|Out-Null
[IO.File]::WriteAllBytes((Join-Path $trace 'cpu-stack-wait.etl'),[byte[]]@(1))
@{schema='csx-stack-wait-trace-v1';state='stopped';stopReason='requested';errors=@();qpcFrequency=1;startedQpc=0;stopRequestedQpc=90}|ConvertTo-Json|Set-Content (Join-Path $trace 'trace-result.json')
$covered=Get-StackWaitResult $timing
Test-DepthCAssert ($covered.stackWaitComplete -and $covered.coverage.Count -eq 1) 'WPR coverage ignored phase anchor or counted load as phase.'
($timingMarkers|Where-Object label -NE 'save-1-hold-end')|ForEach-Object{$_|ConvertTo-Json -Compress}|Set-Content (Join-Path $timing 'markers.jsonl')
Test-DepthCAssert (!(Get-StackWaitResult $timing).stackWaitComplete) 'Missing phase end accepted by WPR coverage.'

foreach($failure in @('active-tail','stereo','missing-gate','future-schema','compile','setter-timeout','profile-timeout','health-mode','health-control','health-generation','wrong-fsr','stale-proof','poisoned-proof','future-proof','missing-mainpass','dropped-proof','fsr-fallback','pending-cache','preset-drift','runtime-drift')){
 $global:DepthCFailure=$failure;$failed=Invoke-DepthCFixture $failure
 $m=@(Get-Content (Join-Path $failed 'markers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
 Test-DepthCAssert (@($m|Where-Object label -EQ 'run-error').Count -eq 1) "Accepted $failure."
 Test-DepthCAssert (@($m|Where-Object label -EQ 'requested-holds-complete').Count -eq 0) 'Failed run labeled complete.'
 Test-DepthCAssert (!$global:DepthCActive -and $global:DepthCFlags.performanceMode) 'Failed run did not restore control/health scope.'
 Test-DepthCAssert ($global:DepthCProfile.qualityMode -eq 'native_aa' -and $global:DepthCProfile.fsrRuntime -eq 'fsr4') 'Failed run did not restore profile.'
}
# Historical drops are admissible only after the producer has consumed the
# discontinuity and supplied a fresh coherent pair; independent frames cannot join.
$evidence=(Get-Content (Join-Path $run 'save-1-phase-admission.json') -Raw|ConvertFrom-Json).data.content[0]
$mode=$plan[0]
$mode|Add-Member -NotePropertyName dlssPreset -NotePropertyValue 1 -Force
$mode|Add-Member -NotePropertyName fsrRuntime -NotePropertyValue fsr4 -Force
$evidence.status.compositorSubmission.droppedObservations=3
$evidence.status.compositorSubmission.observedDropCount=3
Test-DepthCAssert (Test-DepthCMode $evidence.status $mode) 'Consumed historical loss wrongly poisons all later valid cycles.'
$evidence.status.compositorSubmission.observedDropCount=2
Test-DepthCAssert (!(Test-DepthCMode $evidence.status $mode)) 'Unconsumed dropped submission accepted.'
$fsrEvidence=(Get-Content (Join-Path $run 'save-25-phase-admission.json') -Raw|ConvertFrom-Json).data.content[0]
$fsrMode=$plan[24]
$fsrMode|Add-Member -NotePropertyName dlssPreset -NotePropertyValue 1 -Force
$fsrMode|Add-Member -NotePropertyName fsrRuntime -NotePropertyValue fsr3 -Force
Test-DepthCAssert (Test-DepthCMode $fsrEvidence.status $fsrMode) 'Coherent native FSR3 shared stereo dispatch rejected.'
$fsrEvidence.status.compositorSubmission.lastCompleted.mainPassFsrDispatchFrame=0
Test-DepthCAssert (!(Test-DepthCMode $fsrEvidence.status $fsrMode)) 'Neighbor-frame FSR native dispatch combined with another submitted frame.'
$fsrActiveEvidence=(Get-Content (Join-Path $run 'save-41-phase-admission.json') -Raw|ConvertFrom-Json).data.content[0]
$fsrActiveMode=$plan[40]
$fsrActiveMode|Add-Member -NotePropertyName dlssPreset -NotePropertyValue 1 -Force
$fsrActiveMode|Add-Member -NotePropertyName fsrRuntime -NotePropertyValue fsr3 -Force
$fsrActiveEvidence.status.fsrDispatch.actualDispatchFrame=0
Test-DepthCAssert (!(Test-DepthCMode $fsrActiveEvidence.status $fsrActiveMode)) 'Neighbor-frame FSR scaled dispatch combined with another submitted frame.'
$global:DepthCFailure='exterior';$exterior=Invoke-DepthCFixture 'exterior'
$m=@(Get-Content (Join-Path $exterior 'markers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
Test-DepthCAssert (@($m|Where-Object label -Match 'depthc-inapplicable$').Count -eq 12) 'Interior control was measured on exterior or silently omitted.'
Test-DepthCAssert (@($m|Where-Object label -Match '^save-\d+-phase-entry$').Count -eq 84) 'Exterior matrix hold count is wrong.'
Test-DepthCAssert (@($m|Where-Object label -EQ 'requested-holds-complete').Count -eq 1) 'Exterior matrix failed.'
Write-Output "depthc: $checks checks passed; offline fixtures retained at $fixture"
