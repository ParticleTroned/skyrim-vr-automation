#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repo 'tools/frustrum/Frustrum.psm1') -Force
$checks = 0
function Assert-FrustrumTest([bool]$Condition, [string]$Message) {
    $script:checks++
    if (!$Condition) { throw $Message }
}
function Assert-FrustrumRejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-FrustrumTest $rejected 'Invalid frustum evidence accepted.'
}
$plan = @(New-FrustrumPlan @(8,11,8))
Assert-FrustrumTest (($plan.saveNumber -join ',') -ceq '08,08,11,11,08,08') 'Save/pair order changed.'
Assert-FrustrumTest (($plan.mode -join ',') -ceq 'OFF,ON,OFF,ON,OFF,ON') 'OFF/ON order changed.'
Assert-FrustrumTest (($plan.ordinal -join ',') -eq '1,2,3,4,5,6') 'Ordinals can overwrite evidence.'
Assert-FrustrumTest (@(New-FrustrumPlan @(8)).Count -eq 2) 'Single-save pair unsupported.'
$state = [pscustomobject]@{schemaVersion=2;implementation='single_traversal';installed=$true;enabled=$false;verification=$false;mismatchLatched=$false;effectiveMode='native'}
Assert-FrustrumState $state $false
Assert-FrustrumRejected { Assert-FrustrumState $state $true }
foreach ($bad in @(
    @{key='schemaVersion';value=3}, @{key='implementation';value='other'},
    @{key='installed';value=$false}, @{key='enabled';value='false'},
    @{key='verification';value=$true}, @{key='mismatchLatched';value=$true},
    @{key='effectiveMode';value='fast'}
)) {
    $original = $state.($bad.key)
    $state.($bad.key) = $bad.value
    Assert-FrustrumRejected { Assert-FrustrumState $state }
    $state.($bad.key) = $original
}
Assert-FrustrumRejected { Assert-FrustrumState $null }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('frustrum-' + [guid]::NewGuid().ToString('N'))
$protocol = Join-Path $fixture 'tools/gameft-sw/protocol'
New-Item -ItemType Directory -Path $protocol -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixture 'tools/frustrum') | Out-Null
Copy-Item (Join-Path $repo 'tools/frustrum/Frustrum.psm1') (Join-Path $fixture 'tools/frustrum/Frustrum.psm1')
$runner = Get-Content (Join-Path $repo 'tools/gameft-sw/protocol/Invoke-SaveLoadTimingV2.ps1') -Raw
# Replace only the clock source; execute the actual runner with fake I/O and virtual sleeps.
$clockLine = '$clock = [Diagnostics.Stopwatch]::StartNew()'
Assert-FrustrumTest ($runner.Split($clockLine).Count -eq 2) 'Runner clock injection is ambiguous.'
$runner = $runner.Replace($clockLine, '$clock = $global:FrustrumTestClock')
$runnerPath = Join-Path $protocol 'Invoke-SaveLoadTimingV2.ps1'
[IO.File]::WriteAllText($runnerPath, $runner)
$controller = Join-Path $fixture 'fake-controller.ps1'
@'
param($Tool, $ArgumentsJson, $EvidenceLabel, [Parameter(ValueFromRemainingArguments)]$Unused)
$arguments = $ArgumentsJson | ConvertFrom-Json
$global:FrustrumCalls.Add([pscustomobject]@{label=$EvidenceLabel;tool=$Tool;arguments=$arguments;time=$global:FrustrumTestClock.Elapsed.TotalSeconds})
if ($Tool.StartsWith('communityshaders.') -and $global:FrustrumRequireIdentity -and $arguments.expectedBuildId -ne ('a'*64)) { throw 'Missing Build ID guard.' }
if ($Tool -eq 'communityshaders.menu') {
    $expectedAction = if ($global:TestBackoff) { 'set_depth_job_backoff_enabled' } else { 'set_frustum_fast_path_enabled' }
    if ($arguments.action -ne $expectedAction) { throw 'Wrong toggle selected.' }
    if ($global:FrustrumEnabled -ne $arguments.enabled) { $global:TestControl += 2; $global:TestCollection++ }
    $global:FrustrumEnabled = $arguments.enabled
    if ($global:FrustrumFailure -eq 'setter' -and $EvidenceLabel -ne 'frustrum-restore') { throw 'Setter Timeout after applying.' }
}
if ($Tool -eq 'game' -and $arguments.action -eq 'load') { $global:FrustrumSerial++ }
if ($arguments.action -eq 'start') { $global:FrustrumActive = $true }
if ($arguments.action -eq 'stop') { $global:FrustrumActive = $false }
if ($global:FrustrumFailure -eq 'mode' -and $EvidenceLabel -eq 'save-2-health-20') { $global:FrustrumEnabled = $false }
if ($global:FrustrumFailure -eq 'stopmode' -and $EvidenceLabel -eq 'save-2-health-stop') { $global:FrustrumEnabled = $false }
$fastEnabled = if ($global:TestBackoff) { $false } else { $global:FrustrumEnabled }
$control = $global:TestControl + [int]$global:FrustrumEnabled
$status = @{
    session=@{active=$global:FrustrumActive;id=1}; frame=1
    frustumFastPath=@{schemaVersion=2;implementation='single_traversal';installed=$true;enabled=$fastEnabled;verification=$false;mismatchLatched=$false;effectiveMode=$(if($fastEnabled){'fast'}else{'native'})}
    nativeFrustum=@{schemaVersion=2;enabled=$true;active=$true;detailEnabled=$true;collectionGeneration=$global:TestCollection;collectionGenerationAtEnd=$global:TestCollection
        depthJobs=@{schemaVersion=1;installed=$true;active=$true;backoff=@{schemaVersion=1;enabled=$global:FrustrumEnabled;active=$global:FrustrumEnabled;control=$control;controlAtEnd=$control;warmupEndMarkers=8;maximumPauseInstructionsPerDispatch=32}}}
    vendorWorkGate=@{stabilizerSync=@{loadingSerial=$global:FrustrumSerial};mainMenu=$false;loadingMenu=$false;completedWorldFrame=$true}
}
if ($global:TestBackoff -and $EvidenceLabel -eq 'save-2-health-20') {
    switch ($global:FrustrumFailure) {
        'generation' { $status.nativeFrustum.collectionGeneration++ }
        'control' { $status.nativeFrustum.depthJobs.backoff.control += 2; $status.nativeFrustum.depthJobs.backoff.controlAtEnd += 2 }
        'fastpath' { $status.frustumFastPath.enabled = $true }
        'future' { $status.nativeFrustum.depthJobs.backoff.schemaVersion = 2 }
        'inactive' { $status.nativeFrustum.depthJobs.backoff.active = $false }
    }
}
$payload = @{status=$status}
if ($arguments.action -eq 'list') {
    $payload = @{dir='fixture';saves=@(
        @{name='Save8_Test';meta=@{saveNumber=8;saveType='save';location='A'}},
        @{name='Save11_Test';meta=@{saveNumber=11;saveType='save';location='B'}}
    )}
}
@{transportOk=$true;data=@{rawResult=@{isError=$false};content=@($payload)}} | ConvertTo-Json -Depth 20 -Compress
'@ | Set-Content -LiteralPath $controller
function Invoke-FrustrumFixture([string]$Name, [switch]$Ordinary, [switch]$Backoff) {
    $run = Join-Path $fixture $Name
    New-Item -ItemType Directory -Path $run | Out-Null
    @{pid=123;exe='fixture';port=8921} | ConvertTo-Json | Set-Content (Join-Path $run 'runtime.json')
    $global:FrustrumCalls = [Collections.Generic.List[object]]::new()
    $global:FrustrumTestClock = [pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0.0}}
    $global:TestBackoff = [bool]$Backoff
    $global:TestControl = 0
    $global:TestCollection = 0
    $global:FrustrumEnabled = $true
    $global:FrustrumActive = $false
    $global:FrustrumSerial = 0
    $global:FrustrumRequireIdentity = !$Ordinary
    function Start-Sleep { param([int]$Milliseconds) $global:FrustrumTestClock.Elapsed.TotalSeconds += $Milliseconds / 1000.0 }
    & $runnerPath -RunDirectory $run -SaveNumberText '08, 11' -FpsVrCmd 'unused' -Controller $controller -SkipFpsVrControl -FrustumPaired:(!$Ordinary) -DepthJobBackoff:$Backoff -ExpectedBuildId ('a'*64) | Out-Null
    return $run
}
$global:FrustrumFailure = ''
$run = Invoke-FrustrumFixture 'paired'
$calls = @($global:FrustrumCalls)
$loads = @($calls | Where-Object { $_.tool -eq 'game' -and $_.arguments.action -eq 'load' })
Assert-FrustrumTest (($loads.arguments.name -join ',') -eq 'Save8_Test,Save8_Test,Save11_Test,Save11_Test') 'Runner did not reload exact saves in pairs.'
$toggles = @($calls | Where-Object tool -EQ 'communityshaders.menu')
Assert-FrustrumTest (($toggles.arguments.enabled -join ',') -eq 'False,True,False,True,True') 'Toggle order/restoration failed.'
$markers = @(Get-Content (Join-Path $run 'markers.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
foreach ($ordinal in 1..4) {
    $entry = $markers | Where-Object label -EQ "save-$ordinal-world-entry"
    $end = $markers | Where-Object label -EQ "save-$ordinal-hold-end"
    Assert-FrustrumTest ($end.detail.durationSeconds -ge 60 -and $end.detail.durationSeconds -lt 60.1) 'Hold duration changed.'
    foreach ($second in @(1,5,20,49,59)) {
        $sample = $calls | Where-Object label -EQ "save-$ordinal-health-$second"
        $offset = $sample.time - $entry.elapsedSeconds
        Assert-FrustrumTest ($offset -ge $second -and $offset -lt $second+0.11) 'Health schedule changed.'
    }
    $setter = $calls | Where-Object label -EQ "save-$ordinal-frustrum-set"
    $load = $calls | Where-Object label -EQ "save-$ordinal-load"
    Assert-FrustrumTest ($setter.time -le $load.time) 'Toggle occurred after load.'
}
Assert-FrustrumTest (@($markers | Where-Object label -EQ 'requested-holds-complete').Count -eq 1) 'Pair run did not complete.'
Assert-FrustrumTest ($global:FrustrumEnabled -and !$global:FrustrumActive) 'Normal cleanup failed.'

$summary = foreach ($ordinal in 1..4) {
    [pscustomobject]@{save="save-$ordinal";name=$(if($ordinal -le 2){'Save8_Test'}else{'Save11_Test'});cpuTailMeanMs=$(if($ordinal%2){10}else{9});gpuTailMeanMs=8;lifecycle=@{finalSuccessful=$true}}
}
$summary | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $run 'quick-summary.json')
$table = & (Join-Path $repo 'tools/frustrum/Show-FrustrumComparison.ps1') -RunDirectory $run
Assert-FrustrumTest (($table -join "`n").Contains('9 (-1.000)')) 'ON minus OFF delta is incorrect.'
Assert-FrustrumTest (($table -join "`n").Contains('| 08 |')) 'Save labels lost.'
$paired = @(Get-Content (Join-Path $run 'frustrum-summary.json') -Raw | ConvertFrom-Json)
Assert-FrustrumTest ($paired.Count -eq 4 -and @($paired | Where-Object { !$_.complete }).Count -eq 0) 'Complete pair reporting failed.'
$summary | Select-Object -First 3 | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $run 'quick-summary.json')
$table = & (Join-Path $repo 'tools/frustrum/Show-FrustrumComparison.ps1') -RunDirectory $run
Assert-FrustrumTest (($table -join "`n").Contains('incomplete OFF/ON pair')) 'Missing ON leg silently compared.'

foreach ($failure in @('setter','mode','stopmode')) {
    $global:FrustrumFailure = $failure
    $failedRun = Invoke-FrustrumFixture $failure
    $failedMarkers = @(Get-Content (Join-Path $failedRun 'markers.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-FrustrumTest (@($failedMarkers | Where-Object label -EQ 'run-error').Count -eq 1) 'Mode/setter failure accepted.'
    Assert-FrustrumTest (@($failedMarkers | Where-Object label -EQ 'requested-holds-complete').Count -eq 0) 'Failed run called complete.'
    Assert-FrustrumTest ($global:FrustrumEnabled -and !$global:FrustrumActive) 'Failed-run cleanup did not restore original state.'
    Assert-FrustrumTest (@($global:FrustrumCalls | Where-Object label -EQ 'save-3-load').Count -eq 0) 'Continued after failure.'
}
$global:FrustrumFailure = ''
$ordinary = Invoke-FrustrumFixture 'ordinary' -Ordinary
Assert-FrustrumTest (@($global:FrustrumCalls | Where-Object tool -EQ 'communityshaders.menu').Count -eq 0) 'Ordinary game-ft changes the toggle.'
Assert-FrustrumTest (@($global:FrustrumCalls | Where-Object { $_.tool -eq 'game' -and $_.arguments.action -eq 'load' }).Count -eq 2) 'Ordinary save sequence changed.'
$global:FrustrumFailure = ''
$backoffRun = Invoke-FrustrumFixture 'backoff' -Backoff
$backoffMarkers = @(Get-Content (Join-Path $backoffRun 'markers.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
Assert-FrustrumTest (@($backoffMarkers | Where-Object label -EQ 'requested-holds-complete').Count -eq 1) 'Backoff pair did not complete.'
$backoffCalls = @($global:FrustrumCalls)
$backoffSetters = @($backoffCalls | Where-Object tool -EQ 'communityshaders.menu')
Assert-FrustrumTest (@($backoffSetters | Where-Object { $_.arguments.action -ne 'set_depth_job_backoff_enabled' }).Count -eq 0) 'Backoff toggled fast path.'
Assert-FrustrumTest (($backoffSetters.arguments.enabled -join ',') -eq 'False,True,False,True,True') 'Backoff order/restoration changed.'
foreach ($ordinal in 1..4) {
    $entry = $backoffMarkers | Where-Object label -EQ "save-$ordinal-world-entry"
    $end = $backoffMarkers | Where-Object label -EQ "save-$ordinal-hold-end"
    Assert-FrustrumTest ($end.detail.durationSeconds -ge 60 -and $end.detail.durationSeconds -lt 60.1) 'Backoff hold changed.'
    foreach ($second in @(1,5,20,49,59)) {
        $sample = $backoffCalls | Where-Object label -EQ "save-$ordinal-health-$second"
        $offset = $sample.time - $entry.elapsedSeconds
        Assert-FrustrumTest ($offset -ge $second -and $offset -lt $second+0.11) 'Backoff health schedule changed.'
    }
}
foreach ($failure in @('setter','mode','stopmode','generation','control','fastpath','future','inactive')) {
    $global:FrustrumFailure = $failure
    $failedRun = Invoke-FrustrumFixture "backoff-$failure" -Backoff
    $failedMarkers = @(Get-Content (Join-Path $failedRun 'markers.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-FrustrumTest (@($failedMarkers | Where-Object label -EQ 'run-error').Count -eq 1) "Backoff accepted $failure."
    Assert-FrustrumTest (@($failedMarkers | Where-Object label -EQ 'requested-holds-complete').Count -eq 0) 'Failed backoff called complete.'
    Assert-FrustrumTest ($global:FrustrumEnabled -and !$global:FrustrumActive) 'Backoff cleanup failed.'
    Assert-FrustrumTest (@($global:FrustrumCalls | Where-Object label -EQ 'save-3-load').Count -eq 0) 'Backoff continued after failure.'
}
foreach ($path in @('tools/frustrum/Frustrum.psm1','tools/frustrum/Invoke-Frustrum.ps1','tools/frustrum/Show-FrustrumComparison.ps1','tools/gameft-sw/Invoke-GameFtStackWait.ps1','tools/gameft-sw/protocol/Invoke-SaveLoadTimingV2.ps1')) {
    $tokens=$null; $errors=$null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $path), [ref]$tokens, [ref]$errors)
    Assert-FrustrumTest (!$errors.Count) "Syntax error in $path"
}
Write-Output "frustrum: $checks checks passed; offline fixtures retained at $fixture"
