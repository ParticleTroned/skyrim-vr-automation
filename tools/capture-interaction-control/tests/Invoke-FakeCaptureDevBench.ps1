# SPDX-License-Identifier: GPL-3.0-or-later

param(
    [Parameter(Position=0)][string]$Command, [string]$Tool,
    [string]$ArgumentsJson, [string]$RuntimePath, [string]$ExpectedRuntimeIdentityJson, [switch]$RequireSuccess,
    [switch]$Compact, [switch]$NoExit, [switch]$SkipRuntimeIdentityVerification
)
$ErrorActionPreference = 'Stop'
$fixtureRoot = [IO.Path]::GetFullPath($env:CAPTURE_INTERACTION_FAKE_ROOT)
if (-not ([IO.Path]::GetFileName($fixtureRoot)).StartsWith('capture-interaction-test-')) { throw 'Invalid test fixture root.' }
if ($env:CAPTURE_INTERACTION_EXPECTED_IDENTITY -and $ExpectedRuntimeIdentityJson -ne $env:CAPTURE_INTERACTION_EXPECTED_IDENTITY) { throw 'Capture runtime identity binding was lost.' }
if ($Command -eq 'list') {
    $properties = @{correlationId=@{type='string'};maximumDurationMs=@{type='integer'}}
    if ($env:CAPTURE_INTERACTION_SCENARIO -ne 'old-record-schema') { $properties.expectedCorrelationId = @{type='string'} }
    @{ok=$true;data=@{tools=@(@{name='record';inputSchema=@{properties=$properties}},@{name='input';inputSchema=@{properties=@{controlToken=@{type='string'};action=@{enum=@('observe','status','sequence','stop')}}}})}} | ConvertTo-Json -Depth 15 -Compress
    return
}
$arguments = $ArgumentsJson | ConvertFrom-Json -Depth 80
[IO.File]::AppendAllText((Join-Path $fixtureRoot 'calls.log'), "$Tool/$($arguments.action)`n")
[IO.File]::AppendAllText((Join-Path $fixtureRoot 'calls.ndjson'), (@{tool=$Tool;arguments=$arguments} | ConvertTo-Json -Depth 80 -Compress) + "`n")
$dataPath = Join-Path $fixtureRoot 'fake-state.json'
$data = if (Test-Path -LiteralPath $dataPath) { Get-Content -LiteralPath $dataPath -Raw | ConvertFrom-Json -Depth 80 } else {
    [pscustomobject]@{ recording=$false; recordState='idle'; correlationId=''; maximumDurationMs=14400000; vrOwner=''; vrToken=''; vrGeneration=1; vrStopped=$false; restorePolls=0; manifestPath='' }
}
$scenario = [string]$env:CAPTURE_INTERACTION_SCENARIO
$value = $null
$failure = $null
if ($Tool -eq 'record') {
    if ($arguments.action -eq 'start') {
        $data.recording = $true; $data.recordState = 'running'; $data.correlationId = $arguments.correlationId
        $data.maximumDurationMs = $arguments.maximumDurationMs
        $value = @{ action='start'; recording=$true; correlationId=$data.correlationId; maximumRetainedFrames=60000; maximumDurationMs=$data.maximumDurationMs }
    }
    elseif ($arguments.action -eq 'stop') {
        if ($env:CAPTURE_INTERACTION_FAIL_CLEANUP -eq '1') { $failure = 'fixture record stop failure' }
        elseif ($arguments.expectedCorrelationId -ne $data.correlationId) { $value = @{error='recording correlation changed before stop'} }
        else {
            $data.recording = $false; $data.recordState = 'idle'
            $value = @{ action='stop'; path='recording.json'; meta=@{correlationId=$data.correlationId}; limitReached=($scenario -eq 'record-limit'); limitReason='fixture duration limit' }
        }
    }
    else {
        $value = @{ recording=($data.recording -and $scenario -ne 'record-limit'); state=$data.recordState; correlationId=$(if ($scenario -eq 'record-owner') {'other-session'} else {$data.correlationId}); maximumRetainedFrames=60000; maximumDurationMs=$data.maximumDurationMs; limitReached=($scenario -eq 'record-limit'); limitReason='fixture duration limit' }
    }
}
elseif ($Tool -eq 'communityshaders.screenshot') {
    if ($arguments.action -eq 'request_cancel' -and $env:CAPTURE_INTERACTION_FAIL_CLEANUP -eq '1') { $failure = 'fixture screenshot cancel failure' }
    elseif ($arguments.action -eq 'sequence_start' -and $env:CAPTURE_INTERACTION_FAIL_VISUAL_START -eq '1') { $failure = 'fixture visual start failure' }
    elseif ($arguments.action -in @('sequence_start','capture')) {
        $descriptor = if ($arguments.action -eq 'capture') { $arguments.capture } else { $arguments.sequence.capture }
        if ($descriptor.source.kind -ne 'hmd_submission' -or $descriptor.source.fallback -ne 'reject') { throw 'Unexpected capture source.' }
        $image = Join-Path $descriptor.destination.directory 'frame-left.png'
        [IO.File]::WriteAllBytes($image, [byte[]](1,2,3))
        $child = @{ ordinal=4; requestId='child-4'; state='completed'; scheduledEngineFrame=44; actual=@{acquisition=@{sourceKind='hmd_submission';engineFrame=48;compositorCycle=52}}; artifacts=@(@{path=$image;bytes=3;committed=$true;sha256=(Get-FileHash -LiteralPath $image).Hash;actual=@{view='left_eye';format='png';colourContract='sdr_srgb';width=100;height=100}}) }
        $data.manifestPath = Join-Path $descriptor.destination.directory 'sequence.manifest.json'
        @{requestId='req-1';children=@($child)} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $data.manifestPath -Encoding utf8
        $value = @{ok=$true;result=@{requestId='req-1';state='running';terminal=$false}}
        if ($env:CAPTURE_INTERACTION_BREAK_SESSION_DIRECTORY) {
            $target = [IO.Path]::GetFullPath($env:CAPTURE_INTERACTION_BREAK_SESSION_DIRECTORY)
            if (-not $target.StartsWith($fixtureRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Deletion target escaped fixture root.' }
            if (Test-Path -LiteralPath $target -PathType Container) { Remove-Item -LiteralPath $target -Recurse -Force }
            'blocked-session-directory' | Set-Content -LiteralPath $target -Encoding utf8
        }
    }
    elseif ($arguments.action -eq 'request_get') {
        $terminalState = if ($scenario -eq 'screenshot-failed') {'failed_partial'} else {'completed'}
        $value = @{ok=$true;result=@{requestId='req-1';state=$terminalState;terminal=$true;manifest=@{finalPath=$data.manifestPath;partialPath=$null}}}
    }
    else { $value = @{ok=$true;result=@{requestId='req-1';state='stop_requested'}} }
}
elseif ($Tool -eq 'input' -and $arguments.action -eq 'sequence') {
    $data.vrOwner = $arguments.owner; $data.vrToken = 'fixture-owned-token'; $data.vrStopped = $false; $data.restorePolls = 0
    $value = @{action='sequence';queued=$true;owner=$data.vrOwner;controlToken=$data.vrToken;generation=$data.vrGeneration}
}
elseif ($Tool -eq 'input' -and $arguments.action -eq 'status' -and $arguments.device -eq 'vrTrackedSet') {
    if ($data.vrToken -and $env:CAPTURE_INTERACTION_SESSION_PATH) {
        $session = Get-Content -LiteralPath $env:CAPTURE_INTERACTION_SESSION_PATH -Raw | ConvertFrom-Json -Depth 80
        if ($session.vrAction.accepted.controlToken -ne $data.vrToken) { throw 'Control token was not durably retained before polling.' }
    }
    $generation = if ($scenario -eq 'superseded') { $data.vrGeneration + 1 } else { $data.vrGeneration }
    $active = $scenario -eq 'timeout' -and -not $data.vrStopped
    $restoring = $scenario -eq 'restore-pending' -and $data.restorePolls -lt 3
    if ($data.vrStopped) { $data.restorePolls++ }
    $value = @{device='vrTrackedSet';ready=$true;active=$active;starting=$false;restoring=$restoring;generation=$generation;owner=$data.vrOwner;lastCompletion=@{owner=$data.vrOwner;generation=$generation;completed=($scenario -ne 'interrupted' -and -not $data.vrStopped);controllerIndicesRestored=(-not $restoring);restorationPending=$restoring}}
}
elseif ($Tool -eq 'input' -and $arguments.action -in @('stop','releaseAll')) {
    if ($arguments.action -ne 'stop' -or $arguments.controlToken -ne $data.vrToken -or $arguments.owner -ne $data.vrOwner) { throw 'Attempted input cleanup without exact ownership token.' }
    $data.vrStopped = $true
    $value = @{action='stop';generation=$data.vrGeneration;restorationPending=($scenario -eq 'restore-pending');restored=($scenario -ne 'restore-pending')}
}
elseif ($Tool -eq 'input' -and $arguments.action -eq 'observe') {
    $pose = @{available=$true;connected=$true;valid=$true;index=0;trackingResult=200;matrix=@(1,0,0,0,0,1,0,0,0,0,1,0);velocity=@(0,0,0);angularVelocity=@(0,0,0)}
    $left = $pose.Clone(); $left.index = 1; $left.controller = @{packetNumber=1;pressed=0;touched=0;axes=@(@(0,0),@(0,0),@(0,0),@(0,0),@(0,0))}
    $right = $left.Clone(); $right.index = 2
    $value = @{action='observe';source='physical_openvr';frame=@{tMs=0;seq=1;originCode=1;hmd=$pose;left=$left;right=$right}}
}
elseif ($Tool -eq 'input' -and $arguments.action -eq 'tap') {
    if (-not $arguments.PSObject.Properties['durationMs'] -or $arguments.durationMs -lt 10 -or $arguments.durationMs -gt 5000) { throw 'Missing or invalid keyboard durationMs.' }
    $value = @{action='tap';released=$true;durationMs=$arguments.durationMs}
}
elseif ($Tool -eq 'menu') { $value = @{openMenus=@('HUD Menu');messageBoxOpen=$false} }
elseif ($Tool -eq 'inspect') { $value = @{playerLoaded=$true;frame=40} }
else { $value = @{ok=$true} }
$data | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $dataPath -Encoding utf8
if ($failure) { @{ok=$false;data=$null;errors=@($failure)} | ConvertTo-Json -Compress }
else { @{ok=$true;data=@{content=@($value)};errors=@()} | ConvertTo-Json -Depth 100 -Compress }
