#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunDirectory)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'DepthC.psm1') -Force
$plan=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'depthc-plan.json') -Raw|ConvertFrom-Json)
$summary=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'quick-summary.json') -Raw|ConvertFrom-Json)
$markers=@(Get-Content -LiteralPath (Join-Path $RunDirectory 'markers.jsonl')|ForEach-Object{$_|ConvertFrom-Json})
$policy=@($markers|Where-Object label -EQ 'depthc-policy')
if($policy.Count -ne 1 -or $policy[0].detail.schema -cne 'depthc-v1' -or $policy[0].detail.holdSeconds -ne 20 -or $policy[0].detail.tailSeconds -ne 10){throw 'Unknown depthc policy.'}
$expected=@(New-DepthCPlan @($plan|Where-Object firstInSave|ForEach-Object{[int]$_.saveNumber}))
if($expected.Count -ne $plan.Count){throw 'Incomplete depthc plan.'}
for($i=0;$i -lt $plan.Count;$i++){
 foreach($key in @('ordinal','pairIndex','modeIndex','conditionIndex','saveNumber','mode','method','qualityMode','quality','renderScaleMode','condition','firstInSave','lastInSave')){
  if($plan[$i].$key -cne $expected[$i].$key){throw "Plan mismatch at $i / $key."}
 }
}
$all=@();$output=[Collections.Generic.List[string]]::new()
$output.Add('# depthc: settled depth-control matrix')
$output.Add('')
$output.Add('CPU/GPU statistics use [10,20) seconds of each 20-second condition. Deltas are versus Balanced in the SAME save occurrence and rendering mode. Tracing is active. Balanced-repeat shows drift; render recovery does not certify frame-time stability.')
foreach($group in @($plan|Group-Object pairIndex,modeIndex)){
 $phases=@($group.Group|Sort-Object ordinal);$completeRows=@();$missing=@()
 foreach($phase in $phases){
  $key="save-$($phase.ordinal)";$found=@($summary|Where-Object save -EQ $key)
  $complete=$found.Count -eq 1 -and $found[0].timingComplete -eq $true
  foreach($suffix in @('phase-entry','hold-end','health-recorder-stopped','live-verified')){
   if(@($markers|Where-Object label -EQ "$key-$suffix").Count -ne 1){$complete=$false}
  }
  $inapplicable=@($markers|Where-Object label -EQ "$key-depthc-inapplicable")
  if($inapplicable.Count -gt 1 -or ($inapplicable.Count -and $complete)){throw 'Ambiguous depthc applicability.'}
  $reason=if($inapplicable.Count){$inapplicable[0].detail.reason}elseif(!$complete){if($found.Count -eq 1 -and $found[0].timingReason){$found[0].timingReason}else{'Incomplete phase or missing timing/health/control evidence'}}else{$null}
  $row=if($complete){$found[0]}else{$null}
  $item=[pscustomobject]@{sceneIndex=$phase.pairIndex;saveNumber=$phase.saveNumber;mode=$phase.mode;condition=$phase.condition;ordinal=$phase.ordinal;complete=$complete;applicable=(!$inapplicable.Count);reason=$reason;result=$row;rawTiming=$(if($found.Count -eq 1){$found[0]}else{$null})}
  $all+=$item
  if($complete){
   $projected=$row | ConvertTo-Json -Depth 25 | ConvertFrom-Json
   $projected | Add-Member -NotePropertyName renderSettling -NotePropertyValue @{summary="$($phase.mode); render recovery confirmed before phase"} -Force
   $projected | Add-Member -NotePropertyName lifecycle -NotePropertyValue @{finalSuccessful=$true} -Force
   $item.result=$projected
   $completeRows+=$item
  }else{$missing+="$($phase.condition): $reason"}
 }
 $output.Add('');$output.Add("## Save $($phases[0].saveNumber), occurrence $($phases[0].pairIndex), $($phases[0].mode)");$output.Add('')
 foreach($text in $missing){$output.Add($text)}
 $base=@($completeRows|Where-Object condition -EQ 'Balanced');$comparisons=@($completeRows|Where-Object condition -NE 'Balanced')
 if($base.Count -ne 1 -or !$comparisons.Count){$output.Add('No complete baseline/condition comparison available.');continue}
 $basePath=Join-Path $RunDirectory "depthc-$($phases[0].ordinal)-baseline.json"
 ConvertTo-Json -InputObject @($base[0].result) -Depth 25|Set-Content -LiteralPath $basePath
 $paths=@();$labels=@()
 foreach($comparison in $comparisons){
  if($comparison.result.name -cne $base[0].result.name){throw 'Different saves paired.'}
  $path=Join-Path $RunDirectory "depthc-$($comparison.ordinal)-comparison.json"
  ConvertTo-Json -InputObject @($comparison.result) -Depth 25|Set-Content -LiteralPath $path
  $paths+=$path;$labels+=$comparison.condition
 }
 $table=&(Join-Path $PSScriptRoot '../gameft-sw/protocol/Compare-GameFtRuns.ps1') -BaselineSummary $basePath -ComparisonSummaries $paths -BaselineLabel Balanced -ComparisonLabels $labels -SaveLabels $phases[0].saveNumber
 foreach($line in $table){$output.Add([string]$line)}
}
ConvertTo-Json -InputObject $all -Depth 25|Set-Content -LiteralPath (Join-Path $RunDirectory 'depthc-summary.json')
$output|Set-Content -LiteralPath (Join-Path $RunDirectory 'depthc-comparison.md')
$output
