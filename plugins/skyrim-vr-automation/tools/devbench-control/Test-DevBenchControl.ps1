# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) { if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) } }

$identityTimestamp = '2026-10-03T20:08:36.7654641Z'
$parsedIdentity = ('{"processStartTimeUtc":"' + $identityTimestamp + '"}') | ConvertFrom-Json
Assert-Test ((ConvertTo-DevBenchUtcTimestamp $parsedIdentity.processStartTimeUtc) -ceq $identityTimestamp) 'JSON-materialized process timestamps preserve all seven fractional digits'
Assert-Test ((ConvertTo-DevBenchUtcTimestamp '2026-10-03T21:08:36.7654641+01:00') -ceq $identityTimestamp) 'equivalent explicit offsets identify the same process-start instant'
Assert-Test ((ConvertTo-DevBenchUtcTimestamp ([DateTimeOffset]::Parse($identityTimestamp))) -ceq $identityTimestamp) 'DateTimeOffset identity retains exact UTC ticks'
Assert-Test ((ConvertTo-DevBenchUtcTimestamp '2026-10-03T20:08:36.7654642Z') -cne (ConvertTo-DevBenchUtcTimestamp $parsedIdentity.processStartTimeUtc)) 'one-tick process-start drift remains an identity mismatch'
$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    Assert-Test ((ConvertTo-DevBenchUtcTimestamp $parsedIdentity.processStartTimeUtc) -ceq $identityTimestamp) 'identity normalization is independent of current culture'
}
finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
foreach ($invalidTimestamp in @('2026-10-03T20:08:36', '10/03/2026 20:08:36', 'not-a-date', [DateTime]::SpecifyKind([DateTime]::UtcNow, [DateTimeKind]::Unspecified))) {
    $rejected = $false
    try { $null = ConvertTo-DevBenchUtcTimestamp $invalidTimestamp } catch { $rejected = $true }
    Assert-Test $rejected 'ambiguous or invalid identity timestamps fail closed'
}

$success = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ status = [pscustomobject]@{ name = 'success'; value = 0 } })
Assert-Test ($success.known -and $success.ok) 'semantic status recognizes a successful API payload'
$conflict = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ status = [pscustomobject]@{ name = 'idempotency_conflict'; value = 12 } })
Assert-Test ($conflict.known -and -not $conflict.ok) 'semantic status rejects a non-success API payload'
$scenario = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ ok = $false; aborted = $true })
Assert-Test ($scenario.known -and -not $scenario.ok -and $scenario.reasons.Count -eq 2) 'semantic status preserves scenario failure reasons'
$producerMismatch = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch'; message = 'wrong build' } })
Assert-Test ($producerMismatch.known -and -not $producerMismatch.ok -and $producerMismatch.guarded -and $producerMismatch.outcome -eq 'guard-rejected') 'producer mismatch is a known guarded rejection'
$transient = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ result = [pscustomobject]@{ state = 'service_unavailable' } })
Assert-Test ($transient.transient -and $transient.states -contains 'service_unavailable') 'transient service state is classified recursively'
$unknown = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ playerLoaded = $true })
Assert-Test (-not $unknown.known -and $unknown.ok) 'unclassified content remains transport-successful'
$neutralPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false; performanceEpoch = 7; physicalStateKnown = $true })
Assert-Test ($neutralPerformance.known -and $neutralPerformance.neutral -and $neutralPerformance.performanceEpoch -eq 7) 'proven disarmed standalone probe permits performance measurement'
$distortedPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $true; performanceEpoch = 8; physicalStateKnown = $true })
Assert-Test ($distortedPerformance.known -and -not $distortedPerformance.neutral -and $distortedPerformance.reason -eq 'intrusive-temporal-probe-armed') 'armed standalone probe rejects performance measurement'
$unprovenPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false; performanceEpoch = 9; physicalStateKnown = $false })
Assert-Test ($unprovenPerformance.known -and -not $unprovenPerformance.neutral -and $unprovenPerformance.reason -eq 'performance-physical-state-unproven') 'unproven physical cleanup fails closed'
$unknownPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false })
Assert-Test (-not $unknownPerformance.known -and -not $unknownPerformance.neutral -and $unknownPerformance.reason -eq 'performance-ownership-state-missing') 'registered legacy probe without ownership epoch fails closed'
$guardBefore = [pscustomobject]@{ applicable = $true; neutral = $true; performanceEpoch = 12; reason = 'intrusive-temporal-probe-disarmed' }
$guardAfter = [pscustomobject]@{ applicable = $true; neutral = $true; performanceEpoch = 12; reason = 'intrusive-temporal-probe-disarmed' }
$stableWindow = Test-DevBenchPerformanceWindow -Before $guardBefore -After $guardAfter
Assert-Test ($stableWindow.valid -and $stableWindow.sameEpoch) 'unchanged neutral probe epoch admits a measurement window'
$guardAfter.performanceEpoch = 13
$changedWindow = Test-DevBenchPerformanceWindow -Before $guardBefore -After $guardAfter
Assert-Test (-not $changedWindow.valid -and $changedWindow.reason -eq 'performance-probe-epoch-changed') 'arm/disarm activity invalidates a measurement window'
$schedulerOnly = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 2; result = [pscustomobject]@{ ok = $true; aborted = $false; stepsRun = 2397; elapsedMs = 161035 } })
Assert-Test (-not $schedulerOnly.known -and $schedulerOnly.ok -and $schedulerOnly.schedulerOnly -and $schedulerOnly.outcome -eq 'scheduler-complete-unverified') 'replay scheduler completion is not promoted to semantic success'
$verifiedReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 3; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; postconditions = [pscustomobject]@{ ok = $true } })
Assert-Test ($verifiedReplay.known -and $verifiedReplay.ok -and -not $verifiedReplay.schedulerOnly) 'explicit replay postconditions establish semantic evidence'
$nullEvidenceReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 4; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; semantic = $null; assertions = @() })
Assert-Test (-not $nullEvidenceReplay.known -and $nullEvidenceReplay.schedulerOnly) 'null or empty outcome fields do not verify replay semantics'
$failedAssertionReplay = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ done = $true; ok = $true; runId = 5; result = [pscustomobject]@{ ok = $true; stepsRun = 10 }; assertions = @([pscustomobject]@{ passed = $false }) })
Assert-Test ($failedAssertionReplay.known -and -not $failedAssertionReplay.ok -and -not $failedAssertionReplay.schedulerOnly) 'explicit failed assertions reject replay semantics'
$readOnlyInspect = Test-DevBenchReadOnlyRequest -ToolName inspect -Arguments @{ kind = 'scene' }
$readOnlyMenu = Test-DevBenchReadOnlyRequest -ToolName menu -Arguments @{ action = 'list' }
$mutatingMenu = Test-DevBenchReadOnlyRequest -ToolName menu -Arguments @{ action = 'open'; name = 'InventoryMenu' }
Assert-Test ($readOnlyInspect -and $readOnlyMenu -and -not $mutatingMenu) 'read-only request classification is explicit and action-sensitive'
$inspectSemantic = Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments @{ kind = 'state' } -Content @([pscustomobject]@{ playerLoaded = $true; frame = 42 })
Assert-Test ($inspectSemantic.known -and $inspectSemantic.ok -and $inspectSemantic.outcome -eq 'read-contract-satisfied') 'structured read-only responses satisfy RequireSuccess semantics'
$recordSemantic = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content @([pscustomobject]@{ action = 'start'; recording = $true; correlationId = 'capture-1' })
Assert-Test ($recordSemantic.known -and $recordSemantic.ok -and $recordSemantic.outcome -eq 'record-start-contract-satisfied') 'record start validates the running receipt and correlation identity'
$recordMismatch = Get-DevBenchCallSemanticStatus -ToolName record -Arguments @{ action = 'start'; correlationId = 'capture-1' } -Content @([pscustomobject]@{ action = 'start'; recording = $true; correlationId = 'other' })
Assert-Test ($recordMismatch.known -and -not $recordMismatch.ok) 'record start rejects a mismatched correlation identity'
$recordStop = '{"action":"stop","path":"recording.json","sampleCount":2,"trackingSampleCount":2,"recordedMs":100,"limitReached":false,"meta":{"format":"devbench-recording-3","correlationId":"capture-1","sampleCount":2,"trackingSampleCount":2,"recordedMs":100,"limitReached":false}}' | ConvertFrom-Json
$recordStopSemantic = Get-DevBenchCallSemanticStatus record @{ action = 'stop'; expectedCorrelationId = 'capture-1' } @($recordStop)
Assert-Test ($recordStopSemantic.known -and $recordStopSemantic.ok) 'record stop accepts a persisted receipt correlated to its guarded recording'
Assert-Test (-not (Get-DevBenchCallSemanticStatus record @{ action = 'stop'; expectedCorrelationId = 'other' } @($recordStop)).known) 'record stop rejects a receipt for another recording'
Assert-Test (-not (Get-DevBenchCallSemanticStatus record @{ action = 'stop' } @($recordStop)).known) 'record stop without an ownership guard cannot establish verified cleanup'
$recordStop.path = ''
Assert-Test (-not (Get-DevBenchCallSemanticStatus record @{ action = 'stop'; expectedCorrelationId = 'capture-1' } @($recordStop)).known) 'record stop requires a persisted recording path'
$recordStop.path = 'recording.json'
$recordStop.meta.sampleCount = 3
Assert-Test (-not (Get-DevBenchCallSemanticStatus record @{ action = 'stop'; expectedCorrelationId = 'capture-1' } @($recordStop)).known) 'record stop rejects contradictory receipt metadata'
$recordStop.meta.sampleCount = 2
$recordStop.limitReached = $true
$recordStop.meta.limitReached = $true
Assert-Test ((Get-DevBenchCallSemanticStatus record @{ action = 'stop'; expectedCorrelationId = 'capture-1' } @($recordStop)).known) 'record stop preserves a successfully persisted limited recording for caller classification'
$recordStop | Add-Member error 'recording ownership changed'
Assert-Test (-not (Get-DevBenchCallSemanticStatus record @{ action = 'stop'; expectedCorrelationId = 'capture-1' } @($recordStop)).ok) 'record stop never promotes an explicit persistence or ownership error'
$readFailure = Get-DevBenchCallSemanticStatus -ToolName inspect -Arguments @{ kind = 'state' } -Content @([pscustomobject]@{ error = 'main thread busy' })
Assert-Test ($readFailure.known -and -not $readFailure.ok -and $readFailure.outcome -eq 'read-contract-failed') 'read-only adapters never promote a structured error to success'
$incompleteMenu = Get-DevBenchCallSemanticStatus -ToolName menu -Arguments @{ action = 'list' } -Content @([pscustomobject]@{ openMenus = @() })
Assert-Test (-not $incompleteMenu.known) 'read-only adapters require the tool-specific response shape'

$inputCapabilities = '{"contract":{"name":"devbench.input","version":{"major":2,"minor":0}},"capabilities":{"keyboard":{"available":true,"actions":["status","tap"]},"vrTrackedSet":{"available":false,"actions":["status","observe"]}}}' | ConvertFrom-Json
$capabilitiesSemantic = Get-DevBenchCallSemanticStatus input @{ action = 'capabilities' } @($inputCapabilities)
Assert-Test ($capabilitiesSemantic.known -and $capabilitiesSemantic.ok) 'input capabilities read succeeds even when a reported device is unavailable'
Assert-Test (Test-DevBenchReadOnlyRequest input @{ action = 'capabilities' }) 'input capabilities is a narrowly allowlisted read'
$inputCapabilities.contract.version.major = 3
Assert-Test (-not (Get-DevBenchCallSemanticStatus input @{ action = 'capabilities' } @($inputCapabilities)).known) 'unknown input capability contract versions remain unverified'
$inputCapabilities.contract.version.major = 2
$inputCapabilities.capabilities.vrTrackedSet.actions = @('status')
Assert-Test (-not (Get-DevBenchCallSemanticStatus input @{ action = 'capabilities' } @($inputCapabilities)).known) 'input capability response requires the tracked observation schema'
Assert-Test (-not (Get-DevBenchCallSemanticStatus input @{ action = 'sequence' } @($inputCapabilities)).known) 'capability payload cannot acknowledge an input mutation'

function New-TestMenuContract([string]$Action) {
    return [pscustomobject]@{
        action = $Action; producer = [pscustomobject]@{ component = 'CommunityShaders'; buildId = ('a' * 64) }
        status = [pscustomobject]@{
            menuEnabled = $false; menuSessionOpen = $false; depthCullingConfiguredPolicy = 'hybrid'
            depthCullingExteriorEnabled = $true; depthCullingInteriorMinExtent = [double][single]0.1
            depthCullingTemporal = [pscustomobject]@{
                telemetryEnabled = $false; cullingEnabled = $true; policy = 'hybrid'; cullingEpoch = 2
                measurementWindow = [pscustomobject]@{ id = 1; current = $true }
                hybrid = [pscustomobject]@{ state = 'inactive' }
            }
        }
    }
}
$menuContract = New-TestMenuContract status
$menuSemantic = Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'status' } @($menuContract)
Assert-Test ($menuSemantic.known -and $menuSemantic.ok -and $menuSemantic.states -contains 'inactive') 'menu status classifies the read without treating nested inactive diagnostics as an operation failure'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'open' } @($menuContract)).known) 'menu status cannot acknowledge an unhandled mutation'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'status'; expectedBuildId = ('b' * 64) } @($menuContract)).known) 'legacy read adapter does not accept a different expected producer'
Assert-Test (-not (Test-DevBenchReadOnlyRequest communityshaders.menu @{ action = 'set_depth_culling_method' })) 'depth setters retain complete mutation identity requirements'
$menuContract | Add-Member error 'main thread busy'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'status' } @($menuContract)).ok) 'menu read errors reject an otherwise matching payload'
$snapshot = New-TestMenuContract depth_culling_snapshot
$snapshot | Add-Member depthCullingTemporal $snapshot.status.depthCullingTemporal
$snapshot | Add-Member frame 42
$snapshot.PSObject.Properties.Remove('status')
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'depth_culling_snapshot' } @($snapshot)).known) 'narrow depth snapshot accepts its frame and depth diagnostics without a menu status'
$snapshot.frame = $false
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'depth_culling_snapshot' } @($snapshot)).known) 'depth snapshot rejects a boolean frame'

$methodReceipt = New-TestMenuContract set_depth_culling_method
$methodReceipt | Add-Member method hybrid
$methodReceipt | Add-Member persisted $false
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_method'; method = 'hybrid' } @($methodReceipt)).known) 'depth method setter verifies requested method and observed configured policy'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_method'; method = 'legacy' } @($methodReceipt)).known) 'depth method setter rejects a mismatched observed policy'
$methodReceipt.persisted = 0
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_method'; method = 'hybrid' } @($methodReceipt)).known) 'depth method setter requires a boolean persistence acknowledgement'
$legacyReceipt = New-TestMenuContract set_depth_culling_legacy_mode
$legacyReceipt | Add-Member enabled $true
$legacyReceipt | Add-Member method legacy
$legacyReceipt | Add-Member persisted $false
$legacyReceipt.status.depthCullingConfiguredPolicy = 'legacy'
$legacyReceipt.status | Add-Member depthCullingLegacyMode $true
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_legacy_mode'; enabled = $true } @($legacyReceipt)).known) 'legacy depth setter verifies requested flag and observed configured policy'
$legacyReceipt.status.depthCullingLegacyMode = $false
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_legacy_mode'; enabled = $true } @($legacyReceipt)).known) 'legacy depth setter rejects contradictory observed mode'
$telemetryReceipt = New-TestMenuContract set_depth_culling_telemetry_enabled
$telemetryReceipt | Add-Member enabled $false
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_telemetry_enabled'; enabled = $false } @($telemetryReceipt)).known) 'telemetry disable verifies false as a real requested and observed value'
$telemetryReceipt.status.depthCullingTemporal.telemetryEnabled = $true
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_telemetry_enabled'; enabled = $false } @($telemetryReceipt)).known) 'telemetry setter rejects contradictory observed state'
$resetReceipt = New-TestMenuContract reset_depth_culling_telemetry
$resetReceipt | Add-Member reset $true
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'reset_depth_culling_telemetry' } @($resetReceipt)).known) 'telemetry reset requires its current explicit measurement window'
$resetReceipt.status.depthCullingTemporal.measurementWindow.current = $false
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'reset_depth_culling_telemetry' } @($resetReceipt)).known) 'telemetry reset rejects an obsolete measurement window'
$busyReset = [pscustomobject]@{ error = 'busy'; errorCode = 'depth_culling_telemetry_busy'; retrySafe = $true }
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'reset_depth_culling_telemetry' } @($busyReset)).ok) 'busy telemetry reset remains a rejected operation'
$settingsReceipt = New-TestMenuContract set_depth_culling_settings
$settingsReceipt | Add-Member persisted $false
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_settings'; depthCulling = @{ exteriorEnabled = $true; interiorMinExtent = 0.1 } } @($settingsReceipt)).known) 'depth settings verify requested fields with native float precision'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_settings'; depthCulling = @{ exteriorEnabled = $false } } @($settingsReceipt)).known) 'depth settings reject a mismatched observed setting'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'set_depth_culling_settings'; depthCulling = @{ unexpected = 1 } } @($settingsReceipt)).known) 'depth settings do not acknowledge unknown fields'
$renderScaleReceipt = [pscustomobject]@{ action = 'status'; producer = $settingsReceipt.producer; status = [pscustomobject]@{ frame = 42; modeStatus = 'Disabled'; controller = [pscustomobject]@{ state = 'inactive' } } }
Assert-Test ((Get-DevBenchCallSemanticStatus communityshaders.renderscale @{ action = 'status' } @($renderScaleReceipt)).known) 'render-scale status accepts disabled diagnostics as a successful read'
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.renderscale @{ action = 'start' } @($renderScaleReceipt)).known) 'render-scale status does not acknowledge a capture mutation'
$renderScaleReceipt.status.PSObject.Properties.Remove('controller')
Assert-Test (-not (Get-DevBenchCallSemanticStatus communityshaders.renderscale @{ action = 'status' } @($renderScaleReceipt)).known) 'incomplete render-scale status remains unverified'
$guardReceipt = [pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch' } }
$guardSemantic = Get-DevBenchCallSemanticStatus communityshaders.menu @{ action = 'status' } @($guardReceipt)
Assert-Test ($guardSemantic.known -and -not $guardSemantic.ok -and $guardSemantic.guarded) 'legacy adapters preserve generic guarded rejection'

$ready = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test ($ready.ready -and -not $ready.retryable -and $ready.statePath -eq 'content.result.state') 'service readiness prefers result.state'
$waiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'compiling' } })
Assert-Test (-not $waiting.ready -and $waiting.retryable -and -not $waiting.terminalFailure) 'compiling service remains retryable'
$dispatchWaiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'main_thread_dispatch_failed'; retryable = $true } })
Assert-Test (-not $dispatchWaiting.ready -and $dispatchWaiting.retryable -and -not $dispatchWaiting.terminalFailure) 'explicitly retryable dispatch failure remains retryable'
$guarded = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch' } })
Assert-Test (-not $guarded.ready -and $guarded.terminalFailure) 'guard rejection terminates readiness wait'
$inspectReady = Test-DevBenchServiceReady -Content @([pscustomobject]@{ playerLoaded = $true; cell = 'Whiterun' })
Assert-Test (-not $inspectReady.ready -and $inspectReady.probeReturnedContent -and -not $inspectReady.semantic.known) 'a successful unclassified response never proves service readiness'
$textUnknown = Test-DevBenchServiceReady -Content @('answered')
Assert-Test (-not $textUnknown.ready -and $textUnknown.probeReturnedContent -and -not $textUnknown.semantic.known) 'arbitrary non-empty text never proves service readiness'
$emptyUnknown = Test-DevBenchServiceReady -Content @()
Assert-Test (-not $emptyUnknown.ready -and -not $emptyUnknown.probeReturnedContent) 'empty unknown content never proves service readiness'

$hudOnly = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false })
Assert-Test $hudOnly.satisfied 'HUD-only menu state is non-blocking'
$inventory = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu'); messageBoxOpen = $false })
Assert-Test (-not $inventory.satisfied -and $inventory.blockingMenus[0] -eq 'InventoryMenu') 'non-HUD menus remain blocking'
$modal = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $true })
Assert-Test (-not $modal.satisfied) 'message boxes remain blocking'
$inventoryDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory -DismissBlockingMenus @('InventoryMenu')
Assert-Test ($inventoryDismissal.permitted -and $inventoryDismissal.dismissMenus[0] -eq 'InventoryMenu') 'explicitly listed blocking menu permits bounded dismissal'
$unlistedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory
Assert-Test (-not $unlistedDismissal.permitted -and $unlistedDismissal.reason -eq 'unlisted-blocking-menu') 'menu dismissal remains opt-in'
$mixedMenus = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu', 'MapMenu'); messageBoxOpen = $false })
$mixedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $mixedMenus -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $mixedDismissal.permitted -and $mixedDismissal.retainedMenus[0] -eq 'MapMenu') 'unlisted blocking menus prevent partial dismissal'
$modalDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $modal -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $modalDismissal.permitted -and $modalDismissal.reason -eq 'message-box-requires-explicit-answer') 'message boxes are never auto-dismissed'

function New-TestUpscalingProfile([string]$Method = 'dlss', [bool]$RenderScale = $true) {
    [pscustomobject]@{
        method = [pscustomobject]@{ name = $Method; value = $(if ($Method -eq 'dlss') { 3 } elseif ($Method -eq 'fsr') { 2 } else { 1 }) }
        qualityMode = [pscustomobject]@{ name = $(if ($RenderScale) { 'hoshipa' } else { 'native_aa' }); value = $(if ($RenderScale) { 1 } else { 0 }) }
        renderScaleMode = $RenderScale
        dlssProfile = [pscustomobject]@{ name = 'K'; value = 1 }
        fsrRuntime = [pscustomobject]@{ name = 'fsr3'; value = 0 }
    }
}

function New-TestRenderScaleStatus([bool]$RenderScale = $true) {
    $eye = { param([uint32]$Frame) [pscustomobject]@{ frame = $Frame; evaluated = $true; valid = $true } }
    $presentationEye = { param([uint32]$Frame) [pscustomobject]@{ frame = $Frame; valid = $true; path = 'VendorEvaluated'; loadingOrMenuContext = $false; transitionCooldown = $false } }
    [pscustomobject]@{
        frame = 105
        upscalingSnapshot = [pscustomobject]@{ stateRevision = 12 }
        modeStatus = $(if ($RenderScale) { 'Active' } else { 'Disabled' })
        vendorWorkGate = [pscustomobject]@{
            active = $false; completedWorldFrame = $true; loadingMenu = $false; loadingPresentationActive = $false
            postLoadResetPending = $false; relatchQueued = $false; relatchInProgress = $false; relatchFramePending = $false
            relatchPostLoadSettle = $false; recoveryPending = $false; relatchPending = $false; profileTransitionPending = $false
        }
        fsrDispatch = [pscustomobject]@{
            actualDispatchBothEyesValid = $true; actualDispatchBackendConverged = $true; actualRuntimeFallbackObserved = $false
            shaderCompilationActive = $false; contractReady = $true; contractLifecyclePhase = 'Ready'
        }
        controller = [pscustomobject]@{
            state = $(if ($RenderScale) { 'Active' } else { 'Idle' })
            presentationPhase = $(if ($RenderScale) { 'released' } else { 'idle' })
            terminalFailureSignaled = $false; terminalDeviceLossSignaled = $false; unresolvedPhysicalMutationEpoch = 0
            targetEpoch = 7
            stable = [pscustomobject]@{ valid = $RenderScale; active = $RenderScale; contractGeneration = $(if ($RenderScale) { 4 } else { 0 }) }
            fidelity = [pscustomobject]@{
                active = $RenderScale; bothEyesValid = $RenderScale; evaluationEyeMask = $(if ($RenderScale) { 3 } else { 0 })
                invariantEyeMask = $(if ($RenderScale) { 3 } else { 0 }); lastMismatchMask = 0
                eyes = @((& $eye 105), (& $eye 105))
            }
            presentation = [pscustomobject]@{
                consecutiveBothEyesVendorFrames = $(if ($RenderScale) { 3 } else { 0 })
                eyes = @((& $presentationEye 105), (& $presentationEye 104))
            }
            postLoadRecovery = [pscustomobject]@{ active = $false }
            memoryTrim = [pscustomobject]@{ pending = $false }
            retirement = [pscustomobject]@{ pendingSets = 0; fencePending = $false; capacityBlocked = $false }
            engineTargetRetirement = [pscustomobject]@{ pending = $false }
            dlssLifecycle = [pscustomobject]@{ resourcesPresent = $true; readyForContract = $true; phase = 'Ready'; failures = 0 }
        }
    }
}

$renderProfile = New-TestUpscalingProfile
$renderSnapshot = [pscustomobject]@{
    stateRevision = 12
    profilePresence = 27; flags = 57; activeOperationId = 0
    transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
    renderScaleStatus = [pscustomobject]@{ name = 'active'; value = 5 }
    observedConditions = [pscustomobject]@{ names = @() }
    profiles = [pscustomobject]@{ requested = $renderProfile; effective = $renderProfile; stable = $renderProfile }
    dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2096; renderEyeHeight = 2328 }
}
$renderStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test ($renderStable.satisfied -and $renderStable.stereoEvidence -eq 'render_scale_fidelity') 'render-scale stability requires a latched coherent stereo contract'
$wrongScaledProfile = New-TestUpscalingProfile -Method 'fsr'
$wrongScaledTarget = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus (New-TestRenderScaleStatus) -ExpectedProfile $wrongScaledProfile
Assert-Test (-not $wrongScaledTarget.satisfied -and $wrongScaledTarget.reasons -contains 'effective scaled profile does not match the expected target') 'targeted scaled stability rejects a different effective profile'
$gatedStatus = New-TestRenderScaleStatus
$gatedStatus.vendorWorkGate.loadingMenu = $true
$renderGated = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $gatedStatus
Assert-Test (-not $renderGated.satisfied -and $renderGated.reasons -match 'loadingMenu') 'loading presentation prevents a stable render-scale verdict'

function New-TestNativeSnapshot {
    param(
        $RequestedProfile,
        $EffectiveProfile,
        $StableProfile,
        [ValidateSet('idle', 'active')][string]$TransitionState = 'idle',
        [int]$ProfilePresence = 11
    )
    if ($null -eq $RequestedProfile) { $RequestedProfile = New-TestUpscalingProfile -Method 'dlss' -RenderScale $false }
    if ($null -eq $EffectiveProfile) { $EffectiveProfile = $RequestedProfile }
    if ($null -eq $StableProfile) { $StableProfile = $EffectiveProfile }
    [pscustomobject]@{
        stateRevision = 12
        profilePresence = $ProfilePresence; flags = 1; activeOperationId = 0
        transitionState = [pscustomobject]@{ name = $TransitionState; value = $(if ($TransitionState -eq 'active') { 6 } else { 0 }) }
        renderScaleStatus = [pscustomobject]@{ name = 'disabled'; value = 0 }
        observedConditions = [pscustomobject]@{ names = @() }
        profiles = [pscustomobject]@{ requested = $RequestedProfile; effective = $EffectiveProfile; stable = $StableProfile }
        dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2468; renderEyeHeight = 2740 }
    }
}

$nativeProfile = New-TestUpscalingProfile -Method 'dlss' -RenderScale $false
$nativeStable = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test ($nativeStable.satisfied -and $nativeStable.stereoEvidence -eq 'native_pipeline_frames') 'native-resolution stability uses converged profiles and advancing world frames'
$nativeTaaProfile = New-TestUpscalingProfile -Method 'taa' -RenderScale $false
$nativeProjectedNone = New-TestUpscalingProfile -Method 'none' -RenderScale $false
$nativeTaaSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeProjectedNone -EffectiveProfile $nativeTaaProfile -StableProfile $nativeProjectedNone -TransitionState active -ProfilePresence 27
$nativeTaaStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeTaaStatus.controller.state = 'Active'
$nativeTaaStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeTaaSnapshot -RenderScaleStatus $nativeTaaStatus -ExpectedProfile $nativeTaaProfile
Assert-Test ($nativeTaaStable.satisfied -and $nativeTaaStable.expectedProfileMatches) 'targeted native TAA accepts its active native controller state without treating the render-scale projection as a profile mismatch'
$nativeWrongTargetSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeProjectedNone -EffectiveProfile $nativeTaaProfile -StableProfile $nativeProjectedNone -TransitionState active -ProfilePresence 27
$nativeWrongTargetStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeWrongTargetStatus.controller.state = 'Active'
$nativeWrongTarget = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeWrongTargetSnapshot -RenderScaleStatus $nativeWrongTargetStatus -ExpectedProfile $nativeProjectedNone
Assert-Test (-not $nativeWrongTarget.satisfied -and $nativeWrongTarget.reasons -contains 'effective native profile does not match the expected target') 'targeted native stability rejects a different effective profile'
$nativeSplitSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeProjectedNone -EffectiveProfile $nativeTaaProfile -StableProfile $nativeProjectedNone -TransitionState active -ProfilePresence 27
$nativeSplitStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeSplitStatus.controller.state = 'Idle'
$nativeSplitState = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSplitSnapshot -RenderScaleStatus $nativeSplitStatus -ExpectedProfile $nativeTaaProfile
Assert-Test (-not $nativeSplitState.satisfied -and $nativeSplitState.reasons -contains "native-resolution controller state is 'active/idle'") 'targeted native stability rejects split controller states'
$nativeFsrProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeFsrSnapshot = New-TestNativeSnapshot -RequestedProfile $nativeFsrProfile -EffectiveProfile $nativeFsrProfile -StableProfile $nativeFsrProfile -ProfilePresence 27
$nativeFsrStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeFsrSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test ($nativeFsrStable.satisfied -and $nativeFsrStable.method -eq 'fsr') 'native-resolution stability follows the effective method without prescribing DLSS or FSR'
$nativePhysicalStatus = New-TestRenderScaleStatus -RenderScale $false
$nativePhysicalStatus.controller.stable.active = $true
$nativePhysicalState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $nativePhysicalStatus
Assert-Test (-not $nativePhysicalState.satisfied -and $nativePhysicalState.reasons -contains 'an active physical render-scale contract remains for a native-resolution profile') 'native-resolution stability rejects a contradictory active physical contract'
$missingNativeStableActivity = New-TestRenderScaleStatus -RenderScale $false
$missingNativeStableActivity.controller.stable.PSObject.Properties.Remove('active')
$missingNativeStableActivityState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $missingNativeStableActivity
Assert-Test (-not $missingNativeStableActivityState.satisfied -and $missingNativeStableActivityState.reasons -contains 'stable render-scale activity telemetry is missing for a native-resolution profile') 'native-resolution stability rejects missing physical contract activity telemetry'
$missingNativeFidelityActivity = New-TestRenderScaleStatus -RenderScale $false
$missingNativeFidelityActivity.controller.fidelity.PSObject.Properties.Remove('active')
$missingNativeFidelityActivityState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $missingNativeFidelityActivity
Assert-Test (-not $missingNativeFidelityActivityState.satisfied -and $missingNativeFidelityActivityState.reasons -contains 'render-scale fidelity activity telemetry is missing for a native-resolution profile') 'native-resolution stability rejects missing fidelity activity telemetry'
$invalidNativeActivity = New-TestRenderScaleStatus -RenderScale $false
$invalidNativeActivity.controller.stable.active = 'false'
$invalidNativeActivityState = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus $invalidNativeActivity
Assert-Test (-not $invalidNativeActivityState.satisfied -and $invalidNativeActivityState.reasons -contains 'stable render-scale activity telemetry has invalid type for a native-resolution profile') 'native-resolution stability rejects coerced physical contract activity telemetry'
$invalidCompletedFrame = New-TestRenderScaleStatus
$invalidCompletedFrame.vendorWorkGate.completedWorldFrame = 'false'
$invalidCompletedFrameState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $invalidCompletedFrame
Assert-Test (-not $invalidCompletedFrameState.satisfied -and $invalidCompletedFrameState.reasons -contains 'completed world-frame telemetry has invalid type') 'render-scale stability rejects truthy strings for completed world-frame authority'
$invalidRecoveryBoolean = New-TestRenderScaleStatus
$invalidRecoveryBoolean.controller.postLoadRecovery.active = 'false'
$invalidRecoveryBooleanState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $invalidRecoveryBoolean
Assert-Test (-not $invalidRecoveryBooleanState.satisfied -and $invalidRecoveryBooleanState.reasons -contains 'post-load render-scale recovery active telemetry has invalid type') 'render-scale stability rejects coerced nested recovery telemetry'
$invalidDimensionSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$invalidDimensionSnapshot.dimensions.displayEyeWidth = 'wide'
$invalidDimensionState = Test-DevBenchUpscalingStable -UpscalingSnapshot $invalidDimensionSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test (-not $invalidDimensionState.satisfied -and $invalidDimensionState.reasons -contains 'upscaling dimensions are not materialized') 'upscaling stability rejects nonnumeric dimensions without throwing'
$overflowDimensionSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$overflowDimensionSnapshot.dimensions.renderEyeHeight = [uint64]::MaxValue
$overflowDimensionState = Test-DevBenchUpscalingStable -UpscalingSnapshot $overflowDimensionSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test (-not $overflowDimensionState.satisfied -and $overflowDimensionState.reasons -contains 'upscaling dimensions are not materialized') 'upscaling stability rejects dimensions outside the UInt32 contract without throwing'
$mismatchedProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeMismatchSnapshot = New-TestNativeSnapshot -RequestedProfile $mismatchedProfile -EffectiveProfile $nativeProfile -StableProfile $nativeFsrProfile -ProfilePresence 27
$nativeMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeMismatchSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test (-not $nativeMismatch.satisfied -and $nativeMismatch.reasons -contains 'requested and effective profiles differ') 'native-resolution stability rejects profile divergence'
$statusProfileMismatch = New-TestRenderScaleStatus
$mismatchedPhysicalSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$mismatchedPhysicalSnapshot.renderScaleStatus = [pscustomobject]@{ name = 'disabled'; value = 0 }
$renderStatusMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $mismatchedPhysicalSnapshot -RenderScaleStatus $statusProfileMismatch
Assert-Test (-not $renderStatusMismatch.satisfied -and $renderStatusMismatch.reasons -contains 'render-scale status disagrees with the effective profile') 'physical render-scale status must agree with the effective profile'
$revisionMismatchStatus = New-TestRenderScaleStatus
$revisionMismatchStatus.upscalingSnapshot.stateRevision = 13
$revisionMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $revisionMismatchStatus
Assert-Test (-not $revisionMismatch.satisfied -and $revisionMismatch.reasons -contains 'upscaling and render-scale observations are not revision-correlated') 'cross-RPC upscaling evidence requires a shared state revision'
$invalidExpectedProfile = New-TestUpscalingProfile -RenderScale $false
$invalidExpectedProfile.renderScaleMode = 'false'
$invalidExpected = Test-DevBenchUpscalingStable -UpscalingSnapshot (New-TestNativeSnapshot -RequestedProfile $nativeProfile) -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false) -ExpectedProfile $invalidExpectedProfile
Assert-Test (-not $invalidExpected.satisfied -and $invalidExpected.reasons -contains 'the expected upscaling profile has invalid field types') 'expected profile boolean fields reject truthy strings'
$missingSnapshotFields = Test-DevBenchUpscalingStable -UpscalingSnapshot ([pscustomobject]@{}) -RenderScaleStatus ([pscustomobject]@{})
Assert-Test (-not $missingSnapshotFields.satisfied -and $missingSnapshotFields.reasons -contains 'render-scale controller telemetry is missing') 'missing optional snapshot fields fail closed without a strict-mode exception'
$partialRenderStatus = New-TestRenderScaleStatus
$partialRenderStatus.controller.PSObject.Properties.Remove('fidelity')
$partialRenderState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $partialRenderStatus
Assert-Test (-not $partialRenderState.satisfied -and $partialRenderState.reasons -contains 'render-scale fidelity telemetry is missing') 'partial active controller telemetry fails closed without a strict-mode exception'
$partialProfileSnapshot = $renderSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$partialProfileSnapshot.profiles.effective.PSObject.Properties.Remove('qualityMode')
$partialProfileState = Test-DevBenchUpscalingStable -UpscalingSnapshot $partialProfileSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test (-not $partialProfileState.satisfied -and $partialProfileState.reasons -contains 'the effective upscaling profile has invalid field types') 'partial effective profiles fail closed without a strict-mode exception'

$requiredRecoveryTelemetry = @(
    [pscustomobject]@{ parent = 'postLoadRecovery'; field = 'active'; reason = 'post-load render-scale recovery active telemetry is missing' },
    [pscustomobject]@{ parent = 'memoryTrim'; field = 'pending'; reason = 'render-scale memory trim pending telemetry is missing' },
    [pscustomobject]@{ parent = 'retirement'; field = 'pendingSets'; reason = 'render-scale retirement pending-set telemetry is missing' },
    [pscustomobject]@{ parent = 'retirement'; field = 'fencePending'; reason = 'render-scale retirement fence telemetry is missing' },
    [pscustomobject]@{ parent = 'retirement'; field = 'capacityBlocked'; reason = 'render-scale retirement capacity telemetry is missing' },
    [pscustomobject]@{ parent = 'engineTargetRetirement'; field = 'pending'; reason = 'engine render-target retirement pending telemetry is missing' }
)
foreach ($case in $requiredRecoveryTelemetry) {
    $partialStatus = New-TestRenderScaleStatus
    $partialStatus.controller.($case.parent).PSObject.Properties.Remove($case.field)
    $partialState = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $partialStatus
    Assert-Test (-not $partialState.satisfied -and $partialState.reasons -contains $case.reason) "missing $($case.parent).$($case.field) telemetry fails closed"
}

$resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response ([pscustomobject]@{
        status = [pscustomobject]@{
            resourcePublication = [pscustomobject]@{
                current = $true; currentGeneration = 17; completedGeneration = 17; publishedGeneration = 17
                expectedWidth = 1644; expectedHeight = 1826; publishedWidth = 1644; publishedHeight = 1826
                complete = $true; deferredSetupAcknowledged = $true; deviceMatches = $true; contextMatches = $true
                evaluated = $true; present = $true; generationMatchesCurrent = $true
                generationMatchesCompleted = $true; dimensionsMatch = $true
            }
        }
    })
Assert-Test ($resourcePublication.available -and $resourcePublication.current -and
    $resourcePublication.currentGeneration -eq 17 -and $resourcePublication.completedGeneration -eq 17 -and
    $resourcePublication.publishedGeneration -eq 17 -and $resourcePublication.expectedWidth -eq 1644 -and
    $resourcePublication.expectedHeight -eq 1826 -and $resourcePublication.publishedWidth -eq 1644 -and
    $resourcePublication.publishedHeight -eq 1826 -and $resourcePublication.complete -and
    $resourcePublication.deferredSetupAcknowledged -and $resourcePublication.deviceMatches -and
    $resourcePublication.contextMatches -and $resourcePublication.missingFields.Count -eq 0) 'resource-publication telemetry retains generations, dimensions, setup, and D3D identity'
$missingPublication = Get-DevBenchResourcePublicationTelemetry -Response ([pscustomobject]@{ status = [pscustomobject]@{} })
Assert-Test (-not $missingPublication.available -and $missingPublication.missingFields -contains 'publishedGeneration') 'missing resource-publication telemetry remains explicit'

$preparationResponse = [pscustomobject]@{
    status = [pscustomobject]@{
        preparation = [pscustomobject]@{
            schemaVersion = 1; devBenchOnly = $true; active = $true
            sessionId = 9; qpcFrequency = 10000000; retainedEvents = 3
            capacity = 512; overwrittenEvents = 0; coalescedEvents = 2
            events = @(
                [pscustomobject]@{
                    sequence = 1; sessionId = 9; requestId = 17
                    transitionEpoch = 41; event = 'admission_check'
                    outcome = 'eligible'; occurrences = 1; reasons = @()
                    durationQpcTicks = 100; durationMs = 0.01
                    bytecodeCompilationMs = 0; d3dObjectCreationMs = 0
                },
                [pscustomobject]@{
                    sequence = 2; sessionId = 9; requestId = 17
                    transitionEpoch = 41; event = 'sss_raymarch_prewarm'
                    outcome = 'ready'; occurrences = 1; reasons = @()
                    durationQpcTicks = 500; durationMs = 0.05
                    bytecodeCompilationMs = 0.03; d3dObjectCreationMs = 0.02
                },
                [pscustomobject]@{
                    sequence = 3; sessionId = 9; requestId = 18
                    transitionEpoch = 42; event = 'total_preparation'
                    outcome = 'ready'; occurrences = 1; reasons = @()
                    durationQpcTicks = 900; durationMs = 0.09
                    bytecodeCompilationMs = 0.03; d3dObjectCreationMs = 0.02
                }
            )
        }
    }
}
$preparation = Get-DevBenchRenderScalePreparationTelemetry `
    -Response $preparationResponse -TransitionEpoch 41
Assert-Test ($preparation.available -and $preparation.filterApplied -and
    $preparation.sessionId -eq 9 -and $preparation.capacity -eq 512 -and
    $preparation.allEventCount -eq 3 -and $preparation.eventCount -eq 2 -and
    $preparation.stages.admission_check.observed -and
    $preparation.stages.sss_raymarch_prewarm.bytecodeCompilationMs.total -eq 0.03 -and
    -not $preparation.stages.total_preparation.observed -and
    $preparation.events[1].requestId -eq 17) 'preparation telemetry retains raw records, stage timings, and exact transition filtering'
foreach ($eventName in @(
    'request_queued', 'admission_check', 'early_exit',
    'shader_cache_busy_wait', 'sss_raymarch_prewarm', 'ssgi_prewarm',
    'dlss_preparation', 'fsr_preparation', 'fsr4_preparation',
    'd3d_object_creation', 'total_preparation', 'request_to_prepared',
    'prepared_to_creator'
)) {
    Assert-Test ($null -ne $preparation.stages.PSObject.Properties[$eventName]) `
        "preparation telemetry exposes the '$eventName' stage"
}
$missingPreparation = Get-DevBenchRenderScalePreparationTelemetry `
    -Response ([pscustomobject]@{ status = [pscustomobject]@{} })
Assert-Test (-not $missingPreparation.available -and
    $missingPreparation.missingFields -contains 'events') 'missing preparation telemetry remains explicit'
$mainReady = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'Main Menu'); messageBoxOpen = $false })
Assert-Test $mainReady.satisfied 'mainMenuReady represents the normal main-menu state without treating Main Menu as blocking'
$mainVrReady = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('Main Menu', 'Mist Menu', 'Fader Menu'); messageBoxOpen = $false })
Assert-Test $mainVrReady.satisfied 'mainMenuReady accepts the normal Skyrim VR mist and fader overlays'
$mainMissing = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false })
Assert-Test (-not $mainMissing.satisfied) 'mainMenuReady requires the main menu rather than accepting gameplay'
$mainObscured = Test-DevBenchMainMenuReady -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'Main Menu', 'MessageBoxMenu'); messageBoxOpen = $true })
Assert-Test (-not $mainObscured.satisfied -and $mainObscured.unexpectedMenus -contains 'MessageBoxMenu') 'mainMenuReady rejects modal or unexpected overlays'

$expectations = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921; pid = 123; exe = 'SkyrimVR.exe'; buildId = 'build-1'; dllPath = 'C:\Test\CommunityShaders.dll'; artifactSha256 = 'ABC' })
Assert-Test ($expectations.port -eq 8921 -and $expectations.pid -eq 123 -and $expectations.exe -eq 'SkyrimVR.exe') 'runtime expectations preserve process identity fields'
Assert-Test ($expectations.buildId -eq 'build-1' -and $expectations.artifactPath -like '*CommunityShaders.dll' -and $expectations.artifactSha256 -eq 'ABC') 'runtime expectations preserve build and deployed artifact identity'
$legacy = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921 })
Assert-Test ($null -eq $legacy.pid -and $null -eq $legacy.exe) 'legacy port-only runtime metadata remains supported'

$versionedTool = [pscustomobject]@{
    name = 'communityshaders.profiler'
    inputSchema = [pscustomobject]@{
        type = 'object'
        required = @('contractMajor', 'clientId', 'commandId', 'action')
        properties = [pscustomobject]@{
            contractMajor = [pscustomobject]@{ type = 'integer'; const = 1 }
            action = [pscustomobject]@{ type = 'string'; enum = @('registry', 'status', 'start') }
        }
    }
}
$autoProbe = Resolve-DevBenchServiceProbeArguments -ToolDefinition $versionedTool -Arguments @{} -ArgumentsSupplied:$false -ToolName $versionedTool.name
Assert-Test ($autoProbe.source -eq 'schema-registry-envelope' -and $autoProbe.arguments.action -eq 'registry' -and $autoProbe.arguments.contractMajor -eq 1) 'serviceReady synthesizes a non-mutating registry envelope for versioned tools'
Assert-Test ($autoProbe.arguments.clientId -eq 'devbench-control-service-ready' -and $autoProbe.arguments.commandId -like 'service-ready-*') 'synthesized service probes carry stable client and unique command identities'
$explicitProbeRejected = $false
try { $null = Resolve-DevBenchServiceProbeArguments -ToolDefinition $versionedTool -Arguments @{ action = 'start' } -ArgumentsSupplied:$true -ToolName $versionedTool.name }
catch { $explicitProbeRejected = $_.Exception.Message -match 'does not accept explicit' }
Assert-Test $explicitProbeRejected 'serviceReady rejects explicit arguments that could dispatch mutation on every poll'
$simpleTool = [pscustomobject]@{ name = 'simple'; inputSchema = [pscustomobject]@{ type = 'object'; properties = [pscustomobject]@{} } }
$simpleProbe = Resolve-DevBenchServiceProbeArguments -ToolDefinition $simpleTool -Arguments @{} -ArgumentsSupplied:$false -ToolName $simpleTool.name
Assert-Test ($simpleProbe.source -eq 'schema-empty-valid' -and $simpleProbe.arguments.Count -eq 0) 'schema-valid empty probes remain empty'

$entryPointText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') -Raw
$entryPointPath = Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'
$parseErrors = $null
$tokens = $null
$entryPointAst = [Management.Automation.Language.Parser]::ParseFile($entryPointPath, [ref]$tokens, [ref]$parseErrors)
$terminalWriterAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-TerminalInvocationEvidence' }, $true))[0]
Invoke-Expression $terminalWriterAst.Extent.Text
$headerReaderAst = @($entryPointAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-McpSessionHeaderValue' }, $true))[0]
Invoke-Expression $headerReaderAst.Extent.Text
$missingHeader = Get-McpSessionHeaderValue -Response ([pscustomobject]@{ Headers = @{} })
$arrayHeader = Get-McpSessionHeaderValue -Response ([pscustomobject]@{ Headers = @{ 'Mcp-Session-Id' = @('owned-session', 'ignored') } })
Assert-Test ([string]::IsNullOrWhiteSpace($missingHeader) -and $arrayHeader -eq 'owned-session') 'session header lookup preserves missing-header parse failures and normalizes present array values'
$completedFixture = [pscustomobject][ordered]@{ ok = $true; transportOk = $true; semantic = [pscustomobject]@{ known = $true; ok = $true }; data = [pscustomobject]@{ value = 42 }; errors = @() }
$completionWriteSucceeded = Write-TerminalInvocationEvidence -Result $completedFixture -FailurePrefix 'fixture completion write failed' -WriteAction { throw 'fixture persistence fault' }
Assert-Test (-not $completionWriteSucceeded -and $completedFixture.ok -and $completedFixture.transportOk -and $completedFixture.data.value -eq 42 -and $completedFixture.evidenceWarnings[0] -match 'fixture persistence fault' -and -not $completedFixture.evidenceJournalFinalized) 'post-completion journal failure preserves the exact completed response and reports evidence loss'
Assert-Test ($entryPointText -notmatch '(?im)^\s*\$pid\s*=') 'entry point never assigns PowerShell reserved PID variable'
Assert-Test ($entryPointText -match '\$expectations\.buildId\s+-and\s+\$actualBuildId\s+-and') 'deferred build identity never compares a missing runtime build ID'
Assert-Test ($entryPointText -match '\$Command -eq ''wait'' -and \$statusCode -eq 404') 'transient MCP 404 recovery is restricted to bounded waits'
Assert-Test ($entryPointText -match 'full-runtime-rebind-required') 'bounded waits route invalidated MCP sessions through a full runtime rebind'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$RequirePerformanceNeutral\) -and -not \$semantic\.known') 'required semantic outcomes reject unknown responses'
Assert-Test ($entryPointText -match 'ok = \[bool\]\$observation\.satisfied') 'wait semantics retain the observed unsatisfied condition'
Assert-Test ($entryPointText -match '\$Command -eq ''call'' -and -not \$readOnlyCall -and -not \$runtimeIdentity\.complete') 'only mutation-capable calls require complete runtime identity'
Assert-Test ($entryPointText -match 'if \(\$Command -eq ''call''\) \{[\s\S]{0,100}-not \$semantic\.known -or -not \$semantic\.ok') 'mutation-capable calls fail closed on unknown semantic outcomes'
Assert-Test ($entryPointText -match '\[string\]\$ExpectedRuntimeIdentityJson') 'controller accepts an exact prior runtime identity for pre-dispatch continuity'
Assert-Test ($entryPointText.IndexOf('Expected runtime identity is invalid:') -lt $entryPointText.IndexOf("Update-InvocationEvidence -State 'dispatching'")) 'runtime identity continuity is verified before mutation dispatch'
Assert-Test ($entryPointText -match '\$Tool -eq ''communityshaders\.profiler''') 'profiler calls have an explicit semantic contract adapter'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''status''[\s\S]{0,180}\.status\.PSObject\.Properties\[''frame_count''\]') 'profiler status requires a frame-bearing status payload'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''enable''[\s\S]{0,160}\[bool\]\$profilerPayload\[0\]\.enabled') 'profiler enable requires observed enabled state'
Assert-Test ($entryPointText -match '\$requestedAction -eq ''disable''[\s\S]{0,180}-not \[bool\]\$profilerPayload\[0\]\.enabled') 'profiler disable requires observed disabled state'
Assert-Test ($entryPointText -match 'outcome = ''profiler-contract-satisfied''') 'accepted profiler responses report their contract-specific outcome'
Assert-Test ($entryPointText -match 'Invoke-ToolRpc -Name \$Tool -Arguments \$arguments -Headers \$headers -Mutation:\(-not \$readOnlyCall\)') 'user calls carry their explicit retry-safety classification'
Assert-Test ($entryPointText -match 'not-retried-indeterminate') 'ambiguous mutation transport failures are not replayed'
Assert-Test ($entryPointText -match 'Update-InvocationEvidence -State \$\(if \(\$indeterminateMutation\) \{ ''indeterminate'' \}') 'indeterminate mutation outcomes are durably journaled'
Assert-Test ($entryPointText -match '\$headers = \$null[\s\S]{0,300}probeError') 'wait probe transport failures force full session and identity rebind'
Assert-Test ($entryPointText -match '-TimeoutSec \(Get-RequestTimeoutSeconds\)') 'wait requests consume only their remaining operation budget'
Assert-Test ($entryPointText -match '\$operationStartedUtc = \[DateTime\]::UtcNow' -and $entryPointText -match '\$operationDeadlineUtc = \$operationStartedUtc.AddSeconds\(\$TimeoutSeconds\)' -and $entryPointText -notmatch '\[Math\]::Min\(15,') 'blocking calls use the declared operation budget instead of a fixed 15-second transport cap'
Assert-Test ($entryPointText -notmatch 'Start-Sleep -Milliseconds \$currentDelay') 'wait poll delays cannot exceed the operation deadline'
Assert-Test ($entryPointText -match 'mcp-session-reinitialized') 'bounded waits reinitialize invalidated MCP sessions'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$Command -eq ''wait''\)') 'unsatisfied waits fail even without RequireSuccess'
Assert-Test ($entryPointText -match 'function Close-McpSession') 'entry point defines deterministic MCP session cleanup'
Assert-Test ($entryPointText -match '-Method Delete') 'owned MCP sessions are closed through the server lifecycle endpoint'
Assert-Test ($entryPointText -match "state = 'already_absent'") 'an already-retired MCP session is a successful cleanup'
Assert-Test ($entryPointText -match 'Close-OwnedMcpSession -Endpoint \$endpoint -Headers \$sessionHeaders') 'partially opened MCP sessions are cleaned before rethrowing'
Assert-Test ($entryPointText -match 'Add-Member -NotePropertyName sessionCleanup') 'controller results preserve a structured session cleanup receipt'
Assert-Test ($entryPointText -match "clientInfo = @\{ name = 'DevBenchControl'; version = '1\.5' \}") 'MCP client identity records the timeout-envelope revision'
Assert-Test ($entryPointText -match '\[int\]\$RequestTimeoutSeconds = 15') 'controller exposes its default request timeout'
Assert-Test ($entryPointText -match '\$arguments\.ContainsKey\(''timeoutMs''\)') 'controller detects a server-owned timeout budget'
Assert-Test ($entryPointText -match 'Ceiling\(\$serverTimeoutMilliseconds / 1000\.0\)') 'controller converts the server budget without truncation'
Assert-Test ($entryPointText -match '\$serverTimeoutSeconds \+ 5') 'controller keeps a five-second receipt envelope beyond the server budget'
Assert-Test ($entryPointText -match 'function Set-ServerWaitBudgetAtDispatch' -and $entryPointText -match '\$script:operationDeadlineUtc = \$now.AddSeconds\(\$requiredOperationSeconds\)' -and $entryPointText -match 'Set-ServerWaitBudgetAtDispatch -Arguments \$Arguments') 'server-owned waits extend the actual operation deadline at dispatch'
Assert-Test ($entryPointText -match 'operationDeadlineUtc = \$script:operationDeadlineUtc.ToString') 'receipts expose the effective operation deadline'
Assert-Test ($entryPointText -match 'serverTimeoutDispatchRemainingSeconds') 'receipts expose the remaining dispatch allowance for a server-owned wait'
Assert-Test ($entryPointText -match 'function Close-AllMcpSessions') 'controller retains cleanup evidence for every issued MCP session'
Assert-Test ($entryPointText -match 'Close-McpSessionForRebind') 'session rebind requires a successful prior cleanup reconciliation'
Assert-Test ($entryPointText -match 'elseif \(\$Condition -eq ''upscalingStable''\)[\s\S]+?catch \{[\s\S]+?Close-McpSessionForRebind -Headers \$headers[\s\S]+?\$headers = \$null') 'upscalingStable discards retryably invalidated sessions before another observation'
Assert-Test ($entryPointText -match "DevBenchMcpSessionId" -and $entryPointText -match "returned malformed JSON") 'malformed initialization JSON preserves an already-issued MCP session identity'
Assert-Test ($entryPointText -match "DevBenchCleanupUncertain" -and $entryPointText -match 'refusing automatic rebind') 'uncertain partial-session cleanup is never classified for automatic rebind'
Assert-Test ($entryPointText -match "invocationRecord\['sessionCleanup'\]") 'final MCP cleanup evidence is written to the durable invocation journal'
Assert-Test ($entryPointText -match "Session cleanup evidence could not be journaled" -and $entryPointText -match 'evidenceJournalFinalized') 'a final journal failure is reported without suppressing the completed controller result'
Assert-Test ($entryPointText -match "outcome = 'tool-unavailable'" -and $entryPointText -match "codes = @\('tool_unavailable'\)") 'missing optional tools retain a structured unavailable outcome without dispatch'
Assert-Test ($entryPointText -match 'method = ''tools/list''[\s\S]{0,400}currentTools') 'performance boundaries refresh the live tool registry'
Assert-Test ($entryPointText -match 'function Invoke-ToolRpc[\s\S]{0,300}Invoke-McpRequest') 'tool calls use the shared deadline-bounded request path'
Assert-Test ($entryPointText -match 'requestTimeoutSeconds = \$script:requestTimeoutSecondsForRpc') 'receipts expose the effective request timeout'
Assert-Test ($entryPointText -match '\[string\]\$EvidenceLabel') 'runtime binding evidence accepts an explicit invocation label'
Assert-Test ($entryPointText -match 'devbench-runtime-binding\.\$safeLabel\.\$stamp\.\$PID\.json') 'parallel runtime bindings use invocation-unique filenames'
Assert-Test ($entryPointText -match 'function Test-WaitRetryableException') 'bounded waits classify exhausted transient probe failures'
Assert-Test ($entryPointText -match "state = 'transport_retry'") 'serviceReady carries transient probe exhaustion into the outer wait'
Assert-Test ($entryPointText -match 'probeError = \$_.Exception.Message') 'wait observations preserve the transient probe error'
Assert-Test ($entryPointText -match "phase = 'initialize'; recovery = 'outer-wait-retry'") 'wait initialization failures remain inside the outer timeout state machine'
Assert-Test ($entryPointText -match '\$null -eq \$headers') 'bounded waits establish or re-establish the MCP session inside the polling loop'
Assert-Test ($entryPointText -match '\[switch\]\$AcceptAlreadyLoaded') 'playerLoaded exposes an explicit compatibility opt-out for freshness'
Assert-Test ($entryPointText -match '\$playerTransitionObserved') 'playerLoaded requires an observed unloaded-to-loaded transition by default'
Assert-Test ($entryPointText -match '\[string\[\]\]\$DismissBlockingMenus') 'menu recovery requires an explicit menu allowlist'
Assert-Test ($entryPointText -match 'action = ''close''; name = \$menuName') 'menu recovery uses the registered menu close action'
Assert-Test ($entryPointText -match '\[int\]\$MinimumMenuStableSeconds') 'menu recovery can require a continuous stable window'
Assert-Test ($entryPointText -match '\$menuStableSinceUtc = \$null') 'a blocking observation resets menu stabilization'
Assert-Test ($entryPointText -match '\[switch\]\$RequirePerformanceNeutral') 'performance calls expose an explicit fail-closed guard'
Assert-Test ($entryPointText -match "'skyrimvrupscaler\.temporalProbe'") 'performance guard queries the standalone probe owner'
Assert-Test ($entryPointText -match 'toolCallSkipped = \$true') 'distorted performance guard skips the requested tool call'
Assert-Test ($entryPointText -match 'Test-DevBenchPerformanceWindow') 'guarded calls verify the probe again after the requested tool returns'
Assert-Test ($entryPointText -match "outcome = 'guard-invalidated'") 'changed probe ownership invalidates completed measurement calls'

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('devbench-control-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $runtimePath = Join-Path $fixture 'runtime.json'
    [IO.File]::WriteAllText($runtimePath, '{"port":65534}', [Text.UTF8Encoding]::new($false))
    $entryPoint = Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1'
    $guardResult = & $entryPoint call -Tool scenario -ArgumentsJson '{"steps":[{"consoleCommand":"tfc 1"}]}' -RuntimePath $runtimePath -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $guardResult.ok -and $guardResult.errors[0] -match 'confirmed null-camera crash path') 'tfc 1 is rejected before transport dispatch'
    Assert-Test (Test-Path -LiteralPath $guardResult.invocationEvidencePath -PathType Leaf) 'guard rejection preserves a durable invocation journal'
    $guardEvidence = Get-Content -LiteralPath $guardResult.invocationEvidencePath -Raw | ConvertFrom-Json
    Assert-Test ($guardEvidence.state -eq 'guard-rejected' -and $null -eq $guardEvidence.dispatchedUtc) 'guard evidence proves no request was dispatched'

    $missingRuntime = Join-Path $fixture 'missing-runtime.json'
    $failedResult = & $entryPoint list -RuntimePath $missingRuntime -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $failedResult.ok -and (Test-Path -LiteralPath $failedResult.invocationEvidencePath -PathType Leaf)) 'pre-dispatch failures return durable evidence'
    $failedEvidence = Get-Content -LiteralPath $failedResult.invocationEvidencePath -Raw | ConvertFrom-Json
    Assert-Test ($failedEvidence.state -eq 'failed' -and $failedEvidence.errors.Count -eq 1) 'failed invocation journal preserves its terminal error'

    $freshManifest = Join-Path $fixture 'fresh-workspace.json'
    [pscustomobject]@{ status = 'ready'; savePolicy = 'FreshGame'; profilePath = (Join-Path $fixture 'profile'); saveFixture = $null } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $freshManifest -Encoding utf8
    $freshResult = & $entryPoint call -Tool game -ArgumentsJson '{"action":"load","name":"Save 3"}' -RuntimePath $runtimePath -WorkspaceManifestPath $freshManifest -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $freshResult.ok -and $freshResult.errors[0] -match "FreshGame.*forbids") 'FreshGame policy rejects a direct save load before dispatch'
    $consoleLoadResult = & $entryPoint call -Tool console -ArgumentsJson '{"command":"load Save 3"}' -RuntimePath $runtimePath -WorkspaceManifestPath $freshManifest -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $consoleLoadResult.ok -and $consoleLoadResult.errors[0] -match "FreshGame.*forbids") 'console load rerouting cannot bypass workspace save policy'

    $verifiedManifest = Join-Path $fixture 'verified-workspace.json'
    [pscustomobject]@{ status = 'ready'; savePolicy = 'VerifiedFixture'; profilePath = (Join-Path $fixture 'profile'); copiedVerifiedSaves = $true; saveFixture = [pscustomobject]@{ loadName = 'Breezehome 003' } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $verifiedManifest -Encoding utf8
    $mismatchResult = & $entryPoint call -Tool scenario -ArgumentsJson '{"steps":[{"tool":"game","args":{"action":"load","name":"Other Save"}}]}' -RuntimePath $runtimePath -WorkspaceManifestPath $verifiedManifest -EvidenceDirectory $fixture -NoExit -Compact | ConvertFrom-Json
    Assert-Test (-not $mismatchResult.ok -and $mismatchResult.errors[0] -match 'load name mismatch') 'nested scenario loads must match the exact VerifiedFixture selector'
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Assert-Test ($entryPointText -match "Condition 'upscalingStable' requires -ExpectedCell") 'upscalingStable cannot accept a stale source scene'
Assert-Test ($entryPointText -match '\[string\]\$ExpectedProfileJson') 'upscalingStable accepts a complete expected profile when a protocol needs target correlation'
Assert-Test ($entryPointText -match 'ExpectedProfileJson requires') 'upscalingStable rejects incomplete expected profile data'
Assert-Test ($entryPointText -match 'ExpectedProfile \$expectedUpscalingProfile') 'upscalingStable passes the expected profile into the stability predicate'
Assert-Test ($entryPointText -match "scene\.cell\.PSObject\.Properties\['editorId'\]") 'upscalingStable reads the structured live scene cell editor ID'
Assert-Test ($entryPointText -match '\$stableCandidateCount -ge \$StableSamples') 'upscalingStable requires consecutive stable observations'
Assert-Test ($entryPointText -match '\$stableFrameAdvance -ge \$MinimumStableFrameAdvance') 'upscalingStable requires advancing world frames'
Assert-Test ($entryPointText -match 'elapsedMs = \[Math\]::Round') 'bounded waits report measured elapsed time'

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 10
if ($failures.Count -gt 0) { exit 1 }
