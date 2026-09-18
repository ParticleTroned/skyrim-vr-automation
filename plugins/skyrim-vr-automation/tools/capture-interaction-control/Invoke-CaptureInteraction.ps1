# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('capabilities', 'start', 'status', 'observe', 'act', 'wait-save', 'stop', 'abort')]
    [string]$Command,
    [string]$SessionPath,
    [string]$SessionDirectory,
    [string]$RuntimePath = $env:CSX_DEVBENCH_RUNTIME_PATH,
    [string]$ExpectedRuntimeIdentityJson,
    [ValidateSet('none', 'on-demand', 'sequence')]
    [string]$VisualMode = 'on-demand',
    [ValidateSet('left_eye', 'right_eye', 'side_by_side', 'framed_combined', 'source_native')]
    [string]$PreferredView = 'left_eye',
    [ValidateRange(10, 5000)][int]$RecordIntervalMs = 50,
    [ValidateRange(10, 14400000)][int]$RecordMaximumDurationMs = 14400000,
    [ValidateRange(50, 60000)][int]$FrameIntervalMs = 500,
    [ValidateRange(1, 10000)][int]$MaximumFrames = 2400,
    [ValidateRange(1, 120)][int]$CaptureTimeoutSeconds = 20,
    [ValidateRange(1, 55)][int]$ActionTimeoutSeconds = 15,
    [switch]$AllowNoPlayer,
    [string]$ActionName,
    [string]$ActionArgumentsJson = '{}',
    [string]$DirectTool,
    [string]$DirectArgumentsJson = '{}',
    [switch]$ObserveAfterAction,
    [string]$SaveDirectory,
    [string]$SaveNamePattern = '*',
    [string]$SinceUtc,
    [ValidateRange(0, 10000)][int]$SaveStableMilliseconds = 1000,
    [ValidateRange(1, 55)][int]$WaitTimeoutSeconds = 30,
    [ValidateRange(100, 5000)][int]$WaitPollMilliseconds = 500,
    [string]$DevBenchScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control\Invoke-DevBenchControl.ps1'),
    [switch]$SkipRuntimeIdentityVerification,
    [switch]$Compact,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CaptureInteractionControl.psm1') -Force

$stateFileName = 'capture-interaction.session.json'
$screenshotTool = 'communityshaders.screenshot'

function Write-JsonAtomic([string]$Path, $Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Value | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $temporary -Encoding utf8
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force } }
}

function Resolve-StatePath([switch]$ForCreate) {
    if (-not [string]::IsNullOrWhiteSpace($SessionPath)) { return [IO.Path]::GetFullPath($SessionPath) }
    if (-not [string]::IsNullOrWhiteSpace($SessionDirectory)) { return Join-Path ([IO.Path]::GetFullPath($SessionDirectory)) $stateFileName }
    if ($ForCreate) { throw '-SessionDirectory or -SessionPath is required for start.' }
    throw '-SessionPath or -SessionDirectory is required.'
}

function Read-State([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Capture interaction session does not exist: $Path" }
    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 80
    if ([string]$state.contractVersion -ne '1.0.0') { throw "Unsupported capture interaction session contract '$($state.contractVersion)'." }
    return $state
}

function Convert-Arguments([string]$Json, [string]$Label) {
    try { return $Json | ConvertFrom-Json -AsHashtable -Depth 80 -ErrorAction Stop }
    catch { throw "$Label is invalid JSON: $($_.Exception.Message)" }
}

function Invoke-DevBench([string]$Tool, [hashtable]$Arguments, [string]$Runtime, [switch]$RequireSuccess) {
    if (-not (Test-Path -LiteralPath $DevBenchScriptPath -PathType Leaf)) { throw "DevBench controller does not exist: $DevBenchScriptPath" }
    $parameters = @{
        Tool = $Tool
        ArgumentsJson = ($Arguments | ConvertTo-Json -Depth 80 -Compress)
        RuntimePath = $Runtime
        Compact = $true
        NoExit = $true
    }
    if ($RequireSuccess) { $parameters['RequireSuccess'] = $true }
    if ($SkipRuntimeIdentityVerification) { $parameters['SkipRuntimeIdentityVerification'] = $true }
    if ($ExpectedRuntimeIdentityJson) { $parameters['ExpectedRuntimeIdentityJson'] = $ExpectedRuntimeIdentityJson }
    $raw = & $DevBenchScriptPath call @parameters
    $response = $raw | ConvertFrom-Json -Depth 100
    if (-not $response.ok) { throw "DevBench tool '$Tool' failed: $(@($response.errors) -join '; ')" }
    $content = @($response.data.content)
    if ($content.Count -lt 1) { throw "DevBench tool '$Tool' returned no content." }
    if ($RequireSuccess) {
        $value = $content[0]
        if ((Get-CaptureInteractionProperty $value 'ok' $true) -eq $false -or (Get-CaptureInteractionProperty $value 'error')) {
            throw "DevBench tool '$Tool' rejected the operation: $($value | ConvertTo-Json -Depth 80 -Compress)"
        }
    }
    return [pscustomobject][ordered]@{ value = $content[0]; envelope = $response }
}

function Invoke-Probe([string]$Tool, [hashtable]$Arguments, [string]$Runtime) {
    try {
        $call = Invoke-DevBench -Tool $Tool -Arguments $Arguments -Runtime $Runtime -RequireSuccess
        return [pscustomobject][ordered]@{ ok = $true; value = $call.value; error = $null }
    }
    catch { return [pscustomobject][ordered]@{ ok = $false; value = $null; error = $_.Exception.Message } }
}

function Get-CaptureTransportContract([string]$Runtime) {
    $parameters = @{ RuntimePath=$Runtime; Compact=$true; NoExit=$true }
    if ($SkipRuntimeIdentityVerification) { $parameters.SkipRuntimeIdentityVerification = $true }
    if ($ExpectedRuntimeIdentityJson) { $parameters.ExpectedRuntimeIdentityJson = $ExpectedRuntimeIdentityJson }
    $catalog = & $DevBenchScriptPath list @parameters | ConvertFrom-Json -Depth 100
    if (-not $catalog.ok) { throw "DevBench catalog discovery failed: $(@($catalog.errors) -join '; ')" }
    $recordTools = @($catalog.data.tools | Where-Object name -eq 'record')
    $inputTools = @($catalog.data.tools | Where-Object name -eq 'input')
    if ($recordTools.Count -ne 1 -or $inputTools.Count -ne 1) { throw 'DevBench must advertise recording and input tools.' }
    foreach ($required in @('correlationId','maximumDurationMs','expectedCorrelationId')) {
        if (-not $recordTools[0].inputSchema.properties.PSObject.Properties[$required]) { throw "DevBench record schema lacks '$required'; use a compatible guarded-recording build." }
    }
    if (-not $inputTools[0].inputSchema.properties.PSObject.Properties['controlToken'] -or
        'observe' -notin @($inputTools[0].inputSchema.properties.action.enum)) { throw 'DevBench input schema lacks atomic observation or token-owned cleanup.' }
    return [pscustomobject]@{ recording=$recordTools[0]; input=$inputTools[0]; verifiedUtc=[DateTime]::UtcNow.ToString('o') }
}

function Wait-VRActionTerminal($Accepted, $State) {
    $generation = [uint64]$Accepted.generation
    $deadline = [DateTime]::UtcNow.AddSeconds($ActionTimeoutSeconds)
    do {
        $status = (Invoke-DevBench -Tool 'input' -Arguments @{ action='status'; device='vrTrackedSet' } -Runtime ([string]$State.runtimePath) -RequireSuccess).value
        $owned = Get-CaptureInteractionProperty $State 'vrAction'
        if ($owned) { $owned | Add-Member -NotePropertyName lastStatus -NotePropertyValue $status -Force }
        if ([uint64]$status.generation -ne $generation) { throw "VR action generation $generation does not match observed generation $($status.generation)." }
        if ([bool]$status.active -and [string]$status.owner -ne [string]$Accepted.owner) { throw 'VR action owner changed before completion.' }
        if (-not [bool]$status.active -and -not [bool]$status.starting -and -not [bool]$status.restoring) {
            $completion = Get-CaptureInteractionProperty $status 'lastCompletion'
            if ([uint64](Get-CaptureInteractionProperty $completion 'generation' 0) -ne $generation -or
                [string](Get-CaptureInteractionProperty $completion 'owner') -ne [string]$Accepted.owner) {
                throw 'VR terminal completion does not match the accepted owner and generation.'
            }
            if ([bool](Get-CaptureInteractionProperty $completion 'controllerIndicesRestored' $false) -and
                -not [bool](Get-CaptureInteractionProperty $completion 'restorationPending' $false)) { return $status }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "VR action generation $generation did not become terminal within $ActionTimeoutSeconds seconds."
}

function Stop-OwnedVRAction($State) {
    $owned = Get-CaptureInteractionProperty $State 'vrAction'
    if (-not $owned -or [string]$owned.state -in @('completed', 'restored')) { return $null }
    $accepted = $owned.accepted
    if (-not $accepted -or -not (Get-CaptureInteractionProperty $accepted 'controlToken') -or
        [string](Get-CaptureInteractionProperty $accepted 'owner') -ne "capture-interaction:$($State.sessionId)") {
        throw 'Pending VR action has no proven cleanup token and owner; input was not released.'
    }
    $status = (Invoke-DevBench 'input' @{ action='status'; device='vrTrackedSet' } ([string]$State.runtimePath) -RequireSuccess).value
    $owned | Add-Member -NotePropertyName lastStatus -NotePropertyValue $status -Force
    if ([uint64]$status.generation -ne [uint64]$accepted.generation) { throw 'Pending VR action generation changed; input was not released.' }
    if ([bool]$status.active -and [string]$status.owner -ne [string]$accepted.owner) { throw 'Pending VR action owner changed; input was not released.' }
    if ([bool]$status.active -or [bool]$status.starting -or [bool]$status.restoring) {
        $owned.stopReceipt = (Invoke-DevBench 'input' @{ action='stop'; device='vrTrackedSet'; owner=[string]$accepted.owner; controlToken=[string]$accepted.controlToken } ([string]$State.runtimePath) -RequireSuccess).value
        Write-JsonAtomic -Path ([string]$State.statePath) -Value $State
    }
    $owned.terminal = Wait-VRActionTerminal -Accepted $accepted -State $State
    $owned.state = 'restored'
    Write-JsonAtomic -Path ([string]$State.statePath) -Value $State
    return $owned
}

function Get-RecordingIssues($Value, [string]$SessionId, [switch]$RequireRunning) {
    $issues = [Collections.Generic.List[string]]::new()
    if ([string](Get-CaptureInteractionProperty $Value 'correlationId') -ne $SessionId) { $issues.Add('Recording correlationId does not match this capture session.') }
    if ([bool](Get-CaptureInteractionProperty $Value 'limitReached' $false)) { $issues.Add("Recording limit reached: $(Get-CaptureInteractionProperty $Value 'limitReason').") }
    if ($RequireRunning -and -not [bool](Get-CaptureInteractionProperty $Value 'recording' $false)) { $issues.Add('The correlated state recording is not running.') }
    return @($issues)
}

function Stop-OwnedRecording([string]$Runtime, [string]$SessionId) {
    $status = (Invoke-DevBench 'record' @{ action='status' } $Runtime -RequireSuccess).value
    if ([string](Get-CaptureInteractionProperty $status 'correlationId') -ne $SessionId) { throw 'Recording ownership changed; record.stop was not dispatched.' }
    return (Invoke-DevBench 'record' @{ action='stop'; expectedCorrelationId=$SessionId } $Runtime -RequireSuccess).value
}

function New-ScreenshotCommand([string]$SessionId, [string]$Action) {
    return [ordered]@{
        contractMajor = 1
        contractMinor = 0
        action = $Action
        clientId = "capture-interaction/$SessionId"
        commandId = [guid]::NewGuid().ToString('N')
    }
}

function New-CaptureDescriptor([string]$Directory, [string]$BaseName, [string]$SessionId) {
    return [ordered]@{
        source = [ordered]@{ kind = 'hmd_submission'; fallback = 'reject' }
        outputs = @(
            [ordered]@{ view = 'left_eye'; nameSuffix = 'left'; encoding = [ordered]@{ format = 'png'; colourContract = 'sdr_srgb' } },
            [ordered]@{ view = 'right_eye'; nameSuffix = 'right'; encoding = [ordered]@{ format = 'png'; colourContract = 'sdr_srgb' } }
        )
        destination = [ordered]@{ policy = 'absolute'; directory = $Directory; baseName = $BaseName; overwrite = 'never' }
        clipboard = 'none'
        tags = [ordered]@{ captureInteractionSessionId = $SessionId }
    }
}

function Get-ScreenshotReceipt([string]$RequestId, $State) {
    $arguments = New-ScreenshotCommand ([string]$State.sessionId) 'request_get'
    $arguments['requestId'] = $RequestId
    $call = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime ([string]$State.runtimePath) -RequireSuccess
    $receipt = @(Find-CaptureInteractionScreenshotReceipt -Value $call.value -RequestId $RequestId)
    if ($receipt.Count -ne 1) { throw "Screenshot request_get did not expose receipt '$RequestId'." }
    $manifest = Get-CaptureInteractionProperty $receipt[0] 'manifest'
    $manifestPath = Get-CaptureInteractionProperty $manifest 'finalPath'
    if ($manifestPath -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'Committed screenshot manifest is missing.' }
    if (-not $manifestPath) { $manifestPath = Get-CaptureInteractionProperty $manifest 'partialPath' }
    if ($manifestPath -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $frameRoot = [IO.Path]::GetFullPath([string]$State.framesDirectory).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        $resolvedManifest = [IO.Path]::GetFullPath([string]$manifestPath)
        if (-not $resolvedManifest.StartsWith($frameRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Screenshot manifest escaped the owned frames directory.' }
        $document = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json -Depth 100
        if ([string](Get-CaptureInteractionProperty $document 'requestId') -ne $RequestId) { throw 'Screenshot manifest request identity mismatch.' }
        $receipt[0] | Add-Member -NotePropertyName children -NotePropertyValue @($document.children) -Force
        $receipt[0] | Add-Member -NotePropertyName observedManifest -NotePropertyValue ([pscustomobject]@{ path=$resolvedManifest; document=$document }) -Force
    }
    return $receipt[0]
}

function Wait-ScreenshotTerminal([string]$RequestId, $State) {
    $deadline = [DateTime]::UtcNow.AddSeconds($CaptureTimeoutSeconds)
    do {
        $receipt = Get-ScreenshotReceipt -RequestId $RequestId -State $State
        if ($receipt.PSObject.Properties['terminal'] -and [bool]$receipt.terminal) { return $receipt }
        if ([string]$receipt.state -in @('completed', 'completed_with_warnings', 'stopped', 'cancelled', 'cancelled_partial', 'failed', 'failed_partial', 'rejected')) { return $receipt }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Screenshot request '$RequestId' did not become terminal within $CaptureTimeoutSeconds seconds."
}

function Start-OnDemandCapture($State) {
    $arguments = New-ScreenshotCommand ([string]$State.sessionId) 'capture'
    $arguments['useSettings'] = $false
    $baseName = 'observe-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $arguments['capture'] = New-CaptureDescriptor ([string]$State.framesDirectory) $baseName ([string]$State.sessionId)
    $call = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime ([string]$State.runtimePath) -RequireSuccess
    $receipt = @(Find-CaptureInteractionScreenshotReceipt -Value $call.value | Select-Object -First 1)
    if ($receipt.Count -ne 1) { throw 'Screenshot capture did not expose an accepted request receipt.' }
    return Wait-ScreenshotTerminal -RequestId ([string]$receipt[0].requestId) -State $State
}

function Get-CompositeObservation($State, [switch]$CaptureOnDemand) {
    $record = Invoke-Probe 'record' @{ action = 'status' } ([string]$State.runtimePath)
    $menus = Invoke-Probe 'menu' @{ action = 'list' } ([string]$State.runtimePath)
    $game = Invoke-Probe 'inspect' @{ kind = 'state' } ([string]$State.runtimePath)
    $inputStatus = Invoke-Probe 'input' @{ action = 'status'; device = 'vrTrackedSet' } ([string]$State.runtimePath)
    $trackedSet = Invoke-Probe 'input' @{ action = 'observe'; device = 'vrTrackedSet' } ([string]$State.runtimePath)
    $issues = [Collections.Generic.List[string]]::new()
    if (-not $record.ok) { $issues.Add([string]$record.error) }
    else { foreach ($issue in @(Get-RecordingIssues $record.value ([string]$State.sessionId) -RequireRunning)) { $issues.Add($issue) } }
    $screenshotReceipt = $null
    $screenshotError = $null
    try {
        if ([string]$State.visualMode -eq 'sequence' -and $State.screenshot.requestId) {
            $screenshotReceipt = Get-ScreenshotReceipt -RequestId ([string]$State.screenshot.requestId) -State $State
        }
        elseif ([string]$State.visualMode -eq 'on-demand' -and $CaptureOnDemand -and $issues.Count -eq 0) {
            $screenshotReceipt = Start-OnDemandCapture -State $State
        }
        if ($screenshotReceipt -and [string]$screenshotReceipt.state -in @('failed','failed_partial','rejected','cancelled','cancelled_partial')) {
            $issues.Add("Screenshot request ended in '$($screenshotReceipt.state)'.")
        }
        $latest = if ($screenshotReceipt) { Get-CaptureInteractionLatestFrame -Receipt $screenshotReceipt -PreferredView ([string]$State.preferredView) } else { $null }
        if ($screenshotReceipt -and [string]$screenshotReceipt.state -in @('completed','completed_with_warnings') -and -not $latest) {
            $issues.Add('Completed screenshot request has no committed HMD PNG to observe.')
        }
    }
    catch { $screenshotError = $_.Exception.Message; $latest = $null; $issues.Add($screenshotError) }
    $observationId = [guid]::NewGuid().ToString('N')
    $observation = [pscustomobject][ordered]@{
        contractVersion = '1.0.0'
        observationId = $observationId
        captureInteractionSessionId = [string]$State.sessionId
        observedUtc = [DateTime]::UtcNow.ToString('o')
        ok = $issues.Count -eq 0
        errors = @($issues)
        latestFrame = $latest
        frameSubmission = $(if ($latest) { [pscustomobject][ordered]@{ kind = 'image-file'; path = [string]$latest.path; mimeType = 'image/png'; view = [string]$latest.view; observationId = $observationId; ordinal = $latest.ordinal; engineFrame = $latest.engineFrame } } else { $null })
        screenshot = [pscustomobject][ordered]@{ mode = [string]$State.visualMode; receipt = $screenshotReceipt; error = $screenshotError }
        recording = $record
        game = $game
        menus = $menus
        input = [pscustomobject][ordered]@{ status = $inputStatus; trackedSet = $trackedSet }
    }
    $observationPath = Join-Path ([string]$State.sessionDirectory) 'latest-observation.json'
    Write-JsonAtomic -Path $observationPath -Value $observation
    return [pscustomobject][ordered]@{ observation = $observation; observationPath = $observationPath }
}

function Add-ActionLog($State, $Entry) {
    $path = Join-Path ([string]$State.sessionDirectory) 'actions.ndjson'
    $line = $Entry | ConvertTo-Json -Depth 80 -Compress
    [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    return $path
}

function Invoke-CaptureStartupCleanup($Recovery) {
    $errors = [Collections.Generic.List[string]]::new()
    $screenshotTerminal = $null
    $recordStop = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Recovery.screenshotRequestId)) {
        try {
            $cancel = New-ScreenshotCommand ([string]$Recovery.sessionId) 'request_cancel'
            $cancel['requestId'] = [string]$Recovery.screenshotRequestId
            $null = Invoke-DevBench -Tool $screenshotTool -Arguments $cancel -Runtime ([string]$Recovery.runtimePath) -RequireSuccess
            $transientState = [pscustomobject]@{ sessionId = $Recovery.sessionId; runtimePath = $Recovery.runtimePath; framesDirectory = (Join-Path $Recovery.sessionDirectory 'frames') }
            $screenshotTerminal = Wait-ScreenshotTerminal -RequestId ([string]$Recovery.screenshotRequestId) -State $transientState
        }
        catch { $errors.Add("screenshot: $($_.Exception.Message)") }
    }
    if ([bool]$Recovery.recordAccepted) {
        try { $recordStop = Stop-OwnedRecording ([string]$Recovery.runtimePath) ([string]$Recovery.sessionId) }
        catch { $errors.Add("record: $($_.Exception.Message)") }
    }
    $Recovery.cleanup = [pscustomobject][ordered]@{
        state = $(if ($errors.Count -eq 0) { 'verified' } else { 'uncertain' })
        attemptedUtc = [DateTime]::UtcNow.ToString('o')
        screenshotTerminal = $screenshotTerminal
        recordStop = $recordStop
        errors = @($errors)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Recovery.receiptPath)) {
        try { Write-JsonAtomic -Path ([string]$Recovery.receiptPath) -Value $Recovery }
        catch { $errors.Add("recovery-receipt: $($_.Exception.Message)") }
    }
    if ($errors.Count -gt 0) {
        $Recovery.cleanup.state = 'uncertain'
        $Recovery.cleanup.errors = @($errors)
    }
    return $Recovery
}

$failureData = $null
try {
    if ($Command -eq 'capabilities') {
        if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw '-RuntimePath or CSX_DEVBENCH_RUNTIME_PATH is required.' }
        $transportContract = Get-CaptureTransportContract $RuntimePath
        $catalog = Get-CaptureInteractionActionCatalog
        $input = Invoke-Probe 'input' @{ action = 'capabilities' } $RuntimePath
        $recording = Invoke-Probe 'record' @{ action = 'status' } $RuntimePath
        $trackedSet = Invoke-Probe 'input' @{ action = 'observe'; device = 'vrTrackedSet' } $RuntimePath
        $screenshots = Invoke-Probe $screenshotTool (New-ScreenshotCommand 'capabilities' 'capabilities') $RuntimePath
        $data = [pscustomobject][ordered]@{
            contractVersion = '1.0.0'; visualModes = @('none', 'on-demand', 'sequence')
            actions = $catalog; directToolPassthrough = $true; input = $input; recording = $recording; trackedSet = $trackedSet; screenshots = $screenshots; transportContract=$transportContract
        }
        $probeErrors = @(@($input,$recording,$trackedSet) + $(if ($VisualMode -ne 'none') {@($screenshots)} else {@()}) | Where-Object { -not $_.ok } | ForEach-Object error)
        $result = [pscustomobject][ordered]@{ ok = $probeErrors.Count -eq 0; command = $Command; state = 'capabilities'; data = $data; errors = $probeErrors }
    }
    elseif ($Command -eq 'start') {
        if ([string]::IsNullOrWhiteSpace($RuntimePath)) { throw '-RuntimePath or CSX_DEVBENCH_RUNTIME_PATH is required.' }
        $resolvedStatePath = Resolve-StatePath -ForCreate
        $resolvedSessionDirectory = Split-Path -Parent $resolvedStatePath
        if (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf) { throw "Refusing to overwrite an existing session: $resolvedStatePath" }
        $transportContract = Get-CaptureTransportContract $RuntimePath
        $recordStatus = (Invoke-DevBench 'record' @{ action='status' } $RuntimePath -RequireSuccess).value
        foreach ($required in @('correlationId', 'maximumRetainedFrames', 'limitReached', 'state')) {
            if (-not $recordStatus.PSObject.Properties[$required]) { throw "DevBench recording lacks required '$required' evidence." }
        }
        if ([string]$recordStatus.state -ne 'idle') { throw "Recording service is '$($recordStatus.state)'; it belongs to an existing capture." }
        $initialTrackedSet = (Invoke-DevBench 'input' @{ action='observe'; device='vrTrackedSet' } $RuntimePath -RequireSuccess).value
        if (-not $initialTrackedSet.PSObject.Properties['frame']) { throw 'DevBench atomic tracked-set observation returned no frame.' }
        if ($VisualMode -eq 'sequence') {
            $plannedMs = [long]$MaximumFrames * $FrameIntervalMs + 2L * $CaptureTimeoutSeconds * 1000
            if ($plannedMs -gt $RecordMaximumDurationMs -or [Math]::Ceiling($plannedMs / $RecordIntervalMs) -ge [long]$recordStatus.maximumRetainedFrames) {
                throw 'Requested sequence exceeds the duration or pose-sample recording budget; reduce MaximumFrames or increase RecordIntervalMs.'
            }
        }
        New-Item -ItemType Directory -Path $resolvedSessionDirectory -Force | Out-Null
        $framesDirectory = Join-Path $resolvedSessionDirectory 'frames'
        if ($VisualMode -ne 'none') { New-Item -ItemType Directory -Path $framesDirectory -Force | Out-Null }
        $sessionId = [guid]::NewGuid().ToString()
        $recordCall = Invoke-DevBench -Tool 'record' -Arguments @{ action = 'start'; intervalMs = $RecordIntervalMs; maximumDurationMs = $RecordMaximumDurationMs; allowNoPlayer = [bool]$AllowNoPlayer; correlationId = $sessionId } -Runtime $RuntimePath -RequireSuccess
        $failureData = [pscustomobject][ordered]@{
            contractVersion = '1.0.0'; operation = 'capture-start-recovery'; sessionId = $sessionId
            runtimePath = [IO.Path]::GetFullPath($RuntimePath); sessionDirectory = $resolvedSessionDirectory
            expectedRuntimeIdentityJson = $ExpectedRuntimeIdentityJson
            intendedStatePath = $resolvedStatePath; receiptPath = (Join-Path $resolvedSessionDirectory 'capture-start-recovery.json')
            recordAccepted = $true; recordStartReceipt = $recordCall.value; screenshotRequestId = $null
            screenshotStartReceipt = $null; cleanup = $null
        }
        $screenshotState = [pscustomobject][ordered]@{ requestId = $null; startReceipt = $null }
        try {
            Write-JsonAtomic -Path ([string]$failureData.receiptPath) -Value $failureData
            $startIssues = @(Get-RecordingIssues $recordCall.value $sessionId -RequireRunning)
            if ($startIssues.Count -gt 0) { throw ($startIssues -join '; ') }
            if ($VisualMode -eq 'sequence') {
                $arguments = New-ScreenshotCommand $sessionId 'sequence_start'
                $arguments['sequence'] = [ordered]@{
                    frameCount = $MaximumFrames
                    useSettings = $false
                    schedule = [ordered]@{ basis = 'wall_clock'; intervalMs = $FrameIntervalMs; startDelayMs = 0; pausePolicy = 'hold' }
                    backpressure = [ordered]@{ policy = 'skip'; maximumConsecutiveSkips = 20 }
                    failurePolicy = 'continue'
                    capture = New-CaptureDescriptor $framesDirectory 'frame' $sessionId
                    packaging = [ordered]@{ frameManifest = $true; previewVideo = [ordered]@{ requested = $false; required = $false; framesPerSecond = [Math]::Max(1, [int](1000 / $FrameIntervalMs)) } }
                }
                $started = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime $RuntimePath -RequireSuccess
                $receipt = @(Find-CaptureInteractionScreenshotReceipt -Value $started.value | Select-Object -First 1)
                if ($receipt.Count -ne 1) { throw 'Screenshot sequence did not expose an accepted request receipt.' }
                $screenshotState.requestId = [string]$receipt[0].requestId
                $screenshotState.startReceipt = $receipt[0]
                $failureData.screenshotRequestId = [string]$receipt[0].requestId
                $failureData.screenshotStartReceipt = $receipt[0]
                Write-JsonAtomic -Path ([string]$failureData.receiptPath) -Value $failureData
            }
        }
        catch {
            $startupFailure = $_.Exception.Message
            $failureData = Invoke-CaptureStartupCleanup -Recovery $failureData
            throw "Visual capture start failed after recording began; cleanup is '$($failureData.cleanup.state)'. $startupFailure"
        }
        $state = [pscustomobject][ordered]@{
            contractVersion = '1.0.0'; sessionId = $sessionId; status = 'active'
            createdUtc = [DateTime]::UtcNow.ToString('o'); updatedUtc = [DateTime]::UtcNow.ToString('o')
            sessionDirectory = $resolvedSessionDirectory; statePath = $resolvedStatePath; runtimePath = [IO.Path]::GetFullPath($RuntimePath)
            expectedRuntimeIdentityJson = $ExpectedRuntimeIdentityJson
            visualMode = $VisualMode; preferredView = $PreferredView; framesDirectory = $framesDirectory
            recording = [pscustomobject][ordered]@{ startReceipt = $recordCall.value; stopReceipt = $null }
            screenshot = $screenshotState; vrAction = $null; transportContract = $transportContract; initialTrackedSet = $initialTrackedSet; stopErrors = @()
        }
        try { Write-JsonAtomic -Path $resolvedStatePath -Value $state }
        catch {
            $startupFailure = $_.Exception.Message
            $failureData = Invoke-CaptureStartupCleanup -Recovery $failureData
            throw "Session-state persistence failed after capture start; cleanup is '$($failureData.cleanup.state)'. $startupFailure"
        }
        $failureData = $null
        $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = 'session-started'; data = $state; errors = @() }
    }
    else {
        $resolvedStatePath = Resolve-StatePath
        $state = Read-State $resolvedStatePath
        $savedIdentity = [string](Get-CaptureInteractionProperty $state 'expectedRuntimeIdentityJson')
        if ($ExpectedRuntimeIdentityJson -and $ExpectedRuntimeIdentityJson -ne $savedIdentity) { throw 'Expected runtime identity differs from the immutable capture session binding.' }
        $ExpectedRuntimeIdentityJson = $savedIdentity
        if ($Command -eq 'status') {
            $data = $state
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = [string]$state.status; data = $data; errors = @() }
        }
        elseif ($Command -eq 'observe') {
            if ([string]$state.status -ne 'active') { throw "Session is '$($state.status)', not active." }
            $data = Get-CompositeObservation -State $state -CaptureOnDemand
            $result = [pscustomobject][ordered]@{ ok = $data.observation.ok; command = $Command; state = 'observed'; data = $data; errors = @($data.observation.errors) }
        }
        elseif ($Command -eq 'act') {
            if ([string]$state.status -ne 'active') { throw "Session is '$($state.status)', not active." }
            $recordStatus = (Invoke-DevBench 'record' @{ action='status' } ([string]$state.runtimePath) -RequireSuccess).value
            $recordIssues = @(Get-RecordingIssues $recordStatus ([string]$state.sessionId) -RequireRunning)
            if ($recordIssues.Count -gt 0) { throw ($recordIssues -join '; ') }
            $pending = Get-CaptureInteractionProperty $state 'vrAction'
            if ($pending -and [string]$pending.state -notin @('completed', 'restored')) { throw 'Previous VR action requires owned cleanup before another action.' }
            $actionId = [guid]::NewGuid().ToString('N')
            $startedUtc = [DateTime]::UtcNow.ToString('o')
            if (-not [string]::IsNullOrWhiteSpace($DirectTool)) {
                $directArgs = Convert-Arguments $DirectArgumentsJson 'DirectArgumentsJson'
                $call = Invoke-DevBench -Tool $DirectTool -Arguments $directArgs -Runtime ([string]$state.runtimePath) -RequireSuccess
                $actionReceipt = [pscustomobject][ordered]@{ mode = 'direct'; tool = $DirectTool; arguments = $directArgs; result = $call.value }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($ActionName)) { throw '-ActionName or -DirectTool is required for act.' }
                $actionArgs = Convert-Arguments $ActionArgumentsJson 'ActionArgumentsJson'
                if ($ActionName -eq 'key-tap') {
                    $compiled = New-CaptureInteractionFrames -ActionName $ActionName -ActionArguments ([pscustomobject]$actionArgs)
                    $keyArgs = [hashtable]($compiled.arguments | ConvertTo-Json -Compress | ConvertFrom-Json -AsHashtable)
                    $keyArgs.owner = "capture-interaction:$($state.sessionId)"
                    $call = Invoke-DevBench -Tool 'input' -Arguments $keyArgs -Runtime ([string]$state.runtimePath) -RequireSuccess
                    $actionReceipt = [pscustomobject][ordered]@{ mode = 'named'; name = $ActionName; compiled = $compiled; result = $call.value }
                }
                else {
                    $observed = Invoke-DevBench -Tool 'input' -Arguments @{ action = 'observe'; device = 'vrTrackedSet' } -Runtime ([string]$state.runtimePath) -RequireSuccess
                    if (-not $observed.value.PSObject.Properties['frame']) { throw 'Tracked-set observation returned no frame.' }
                    $frames = @(New-CaptureInteractionFrames -ObservedFrame $observed.value.frame -ActionName $ActionName -ActionArguments ([pscustomobject]$actionArgs))
                    $inputArgs = @{ action = 'sequence'; device = 'vrTrackedSet'; owner = "capture-interaction:$($state.sessionId)"; tailMs = 50; frames = $frames }
                    $call = Invoke-DevBench -Tool 'input' -Arguments $inputArgs -Runtime ([string]$state.runtimePath) -RequireSuccess
                    $owned = [pscustomobject][ordered]@{ actionId=$actionId; accepted=$call.value; state='accepted'; terminal=$null; lastStatus=$null; stopReceipt=$null; error=$null }
                    $state | Add-Member -NotePropertyName vrAction -NotePropertyValue $owned -Force
                    $failureData = $state
                    try {
                        Write-JsonAtomic -Path $resolvedStatePath -Value $state
                        $null = Add-ActionLog $state ([pscustomobject]@{ actionId=$actionId; sessionId=$state.sessionId; event='accepted'; acceptedUtc=[DateTime]::UtcNow.ToString('o'); receipt=$owned })
                        if (-not (Get-CaptureInteractionProperty $call.value 'controlToken') -or
                            [uint64](Get-CaptureInteractionProperty $call.value 'generation' 0) -eq 0 -or
                            [string](Get-CaptureInteractionProperty $call.value 'owner') -ne [string]$inputArgs.owner) {
                            throw 'Accepted VR sequence lacks its expected owner, generation or cleanup token.'
                        }
                        $owned.terminal = Wait-VRActionTerminal -Accepted $call.value -State $state
                        $owned.state = 'restored'
                        if (-not [bool]$owned.terminal.lastCompletion.completed) { throw 'VR action ended before completing its sequence; restoration is verified.' }
                        $owned.state = 'completed'
                        Write-JsonAtomic -Path $resolvedStatePath -Value $state
                    }
                    catch {
                        $owned.error = $_.Exception.Message
                        if ($owned.state -ne 'restored') { $owned.state = 'uncertain' }
                        try {
                            Write-JsonAtomic -Path $resolvedStatePath -Value $state
                            $null = Add-ActionLog $state ([pscustomobject]@{ actionId=$actionId; sessionId=$state.sessionId; event='failed'; receipt=$owned })
                        } catch { $owned.error += "; evidence persistence failed: $($_.Exception.Message)" }
                        throw $owned.error
                    }
                    $failureData = $null
                    $actionReceipt = [pscustomobject][ordered]@{ mode = 'named'; name = $ActionName; arguments = $actionArgs; observedFrame = $observed.value; compiledFrames = $frames; result = $call.value; terminal = $owned.terminal }
                }
            }
            $entry = [pscustomobject][ordered]@{ actionId = $actionId; sessionId = [string]$state.sessionId; startedUtc = $startedUtc; completedUtc = [DateTime]::UtcNow.ToString('o'); receipt = $actionReceipt }
            $actionLogPath = Add-ActionLog -State $state -Entry $entry
            $after = if ($ObserveAfterAction) { Get-CompositeObservation -State $state -CaptureOnDemand } else { $null }
            $result = [pscustomobject][ordered]@{ ok = $true; command = $Command; state = 'action-submitted'; data = [pscustomobject][ordered]@{ action = $entry; actionLogPath = $actionLogPath; observation = $after }; errors = @() }
        }
        elseif ($Command -eq 'wait-save') {
            if ([string]$state.status -ne 'active') { throw "Session is '$($state.status)', not active." }
            if ([string]::IsNullOrWhiteSpace($SaveDirectory)) { throw 'wait-save requires -SaveDirectory.' }
            $boundaryText = if ([string]::IsNullOrWhiteSpace($SinceUtc)) { [string]$state.createdUtc } else { $SinceUtc }
            $boundary = ConvertTo-CaptureInteractionUtcBoundary -Value $boundaryText
            $deadline = [DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
            $observations = [Collections.Generic.List[object]]::new()
            $matched = $null
            do {
                $candidates = @(Get-CaptureInteractionSaveCandidates -Directory $SaveDirectory -SinceUtc $boundary -NamePattern $SaveNamePattern)
                $observations.Add([pscustomobject][ordered]@{ observedUtc=[DateTime]::UtcNow.ToString('o'); candidates=$candidates })
                if ($candidates.Count -gt 0) {
                    $candidate = $candidates[-1]
                    if ($SaveStableMilliseconds -eq 0) { $matched = $candidate; break }
                    Start-Sleep -Milliseconds $SaveStableMilliseconds
                    $after = @(Get-CaptureInteractionSaveCandidates -Directory $SaveDirectory -SinceUtc $boundary -NamePattern $SaveNamePattern | Where-Object path -eq $candidate.path)
                    if ($after.Count -eq 1 -and [long]$after[0].bytes -eq [long]$candidate.bytes -and [string]$after[0].lastWriteUtc -eq [string]$candidate.lastWriteUtc) { $matched = $after[0]; break }
                }
                Start-Sleep -Milliseconds $WaitPollMilliseconds
            } while ([DateTime]::UtcNow -lt $deadline)
            $waitReceipt = [pscustomobject][ordered]@{
                contractVersion='1.0.0'; sessionId=[string]$state.sessionId
                boundaryUtc=$boundary.ToString('o'); namePattern=$SaveNamePattern
                stableMilliseconds=$SaveStableMilliseconds; timeoutSeconds=$WaitTimeoutSeconds
                completedUtc=[DateTime]::UtcNow.ToString('o'); matched=$matched; observations=@($observations)
            }
            $waitPath = Join-Path ([string]$state.sessionDirectory) ('save-wait-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
            Write-JsonAtomic -Path $waitPath -Value $waitReceipt
            $result = [pscustomobject][ordered]@{ ok=($null -ne $matched); command=$Command; state=$(if ($matched) {'save-stable'} else {'timeout'}); data=[pscustomobject][ordered]@{ receipt=$waitReceipt; receiptPath=$waitPath }; errors=$(if ($matched) {@()} else {@("No stable matching save appeared before the $WaitTimeoutSeconds-second deadline.")}) }
        }
        else {
            $failureData = $state
            $errors = [Collections.Generic.List[string]]::new()
            $screenshotReceipt = $null
            if ($state.screenshot.requestId) {
                try {
                    $screenshotReceipt = Get-ScreenshotReceipt -RequestId ([string]$state.screenshot.requestId) -State $state
                    if ([string]$screenshotReceipt.state -notin @('completed','completed_with_warnings','stopped','cancelled','cancelled_partial','failed','failed_partial','rejected')) {
                        $action = if ($Command -eq 'stop') { 'sequence_stop' } else { 'request_cancel' }
                        $arguments = New-ScreenshotCommand ([string]$state.sessionId) $action
                        $arguments['requestId'] = [string]$state.screenshot.requestId
                        $null = Invoke-DevBench -Tool $screenshotTool -Arguments $arguments -Runtime ([string]$state.runtimePath) -RequireSuccess
                        $screenshotReceipt = Wait-ScreenshotTerminal -RequestId ([string]$state.screenshot.requestId) -State $state
                    }
                }
                catch { $errors.Add($_.Exception.Message) }
            }
            try { $null = Stop-OwnedVRAction -State $state } catch { $errors.Add($_.Exception.Message) }
            $recordStop = $null
            if (-not $state.recording.stopReceipt) {
                try { $recordStop = Stop-OwnedRecording ([string]$state.runtimePath) ([string]$state.sessionId) } catch { $errors.Add($_.Exception.Message) }
            } else { $recordStop = $state.recording.stopReceipt }
            if ($recordStop -and [bool](Get-CaptureInteractionProperty $recordStop 'limitReached' $false)) { $errors.Add("Recording was truncated: $(Get-CaptureInteractionProperty $recordStop 'limitReason').") }
            if ($screenshotReceipt -and [string]$screenshotReceipt.state -in @('failed','failed_partial','rejected')) { $errors.Add("Screenshot request ended in '$($screenshotReceipt.state)'.") }
            $state.status = if ($errors.Count -eq 0) { if ($Command -eq 'stop') { 'stopped' } else { 'aborted' } } else { 'stopped-with-errors' }
            $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
            $state.recording.stopReceipt = $recordStop
            $state.screenshot | Add-Member -NotePropertyName terminalReceipt -NotePropertyValue $screenshotReceipt -Force
            $state.stopErrors = @($errors)
            Write-JsonAtomic -Path $resolvedStatePath -Value $state
            $result = [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; command = $Command; state = [string]$state.status; data = $state; errors = @($errors) }
        }
    }
}
catch {
    $cleanup = Get-CaptureInteractionProperty $failureData 'cleanup'
    $failureState = if ($cleanup -and [string]$cleanup.state -eq 'uncertain') { 'cleanup-uncertain' } else { 'tool-error' }
    $result = [pscustomobject][ordered]@{ ok = $false; command = $Command; state = $failureState; data = $failureData; errors = @($_.Exception.Message) }
}

$json = @{ InputObject = $result; Depth = 100 }
if ($Compact) { $json['Compress'] = $true }
ConvertTo-Json @json
if (-not $result.ok -and -not $NoExit) { exit 2 }
