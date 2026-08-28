# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) { if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) } }

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

$ready = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test ($ready.ready -and -not $ready.retryable -and $ready.statePath -eq 'content.result.state') 'service readiness prefers result.state'
$waiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'compiling' } })
Assert-Test (-not $waiting.ready -and $waiting.retryable -and -not $waiting.terminalFailure) 'compiling service remains retryable'
$dispatchWaiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'main_thread_dispatch_failed'; retryable = $true } })
Assert-Test (-not $dispatchWaiting.ready -and $dispatchWaiting.retryable -and -not $dispatchWaiting.terminalFailure) 'explicitly retryable dispatch failure remains retryable'
$guarded = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch' } })
Assert-Test (-not $guarded.ready -and $guarded.terminalFailure) 'guard rejection terminates readiness wait'

$hudOnly = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false })
Assert-Test $hudOnly.satisfied 'HUD-only menu state is non-blocking'
$inventory = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu'); messageBoxOpen = $false })
Assert-Test (-not $inventory.satisfied -and $inventory.blockingMenus[0] -eq 'InventoryMenu') 'non-HUD menus remain blocking'
$modal = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $true })
Assert-Test (-not $modal.satisfied) 'message boxes remain blocking'

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
    profilePresence = 27; flags = 57; activeOperationId = 0
    transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
    renderScaleStatus = [pscustomobject]@{ name = 'active'; value = 5 }
    observedConditions = [pscustomobject]@{ names = @() }
    profiles = [pscustomobject]@{ requested = $renderProfile; effective = $renderProfile; stable = $renderProfile }
    dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2096; renderEyeHeight = 2328 }
}
$renderStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus (New-TestRenderScaleStatus)
Assert-Test ($renderStable.satisfied -and $renderStable.stereoEvidence -eq 'render_scale_fidelity') 'render-scale stability requires a latched coherent stereo contract'
$gatedStatus = New-TestRenderScaleStatus
$gatedStatus.vendorWorkGate.loadingMenu = $true
$renderGated = Test-DevBenchUpscalingStable -UpscalingSnapshot $renderSnapshot -RenderScaleStatus $gatedStatus
Assert-Test (-not $renderGated.satisfied -and $renderGated.reasons -match 'loadingMenu') 'loading presentation prevents a stable render-scale verdict'

$nativeProfile = New-TestUpscalingProfile -Method 'dlss' -RenderScale $false
$nativeSnapshot = [pscustomobject]@{
    profilePresence = 11; flags = 1; activeOperationId = 0
    transitionState = [pscustomobject]@{ name = 'idle'; value = 0 }
    renderScaleStatus = [pscustomobject]@{ name = 'disabled'; value = 0 }
    observedConditions = [pscustomobject]@{ names = @() }
    profiles = [pscustomobject]@{ requested = $nativeProfile; effective = $nativeProfile; stable = $nativeProfile }
    dimensions = [pscustomobject]@{ displayEyeWidth = 2468; displayEyeHeight = 2740; renderEyeWidth = 2468; renderEyeHeight = 2740 }
}
$nativeStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test ($nativeStable.satisfied -and $nativeStable.stereoEvidence -eq 'native_pipeline_frames') 'native-resolution stability uses converged profiles and advancing world frames'
$nativeTaaProfile = New-TestUpscalingProfile -Method 'taa' -RenderScale $false
$nativeProjectedNone = New-TestUpscalingProfile -Method 'none' -RenderScale $false
$nativeSnapshot.profilePresence = 27
$nativeSnapshot.transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
$nativeSnapshot.profiles.requested = $nativeProjectedNone
$nativeSnapshot.profiles.effective = $nativeTaaProfile
$nativeSnapshot.profiles.stable = $nativeProjectedNone
$nativeTaaStatus = New-TestRenderScaleStatus -RenderScale $false
$nativeTaaStatus.controller.state = 'Active'
$nativeTaaStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSnapshot -RenderScaleStatus $nativeTaaStatus -ExpectedProfile $nativeTaaProfile
Assert-Test ($nativeTaaStable.satisfied -and $nativeTaaStable.expectedProfileMatches) 'targeted native TAA accepts its active native controller state without treating the render-scale projection as a profile mismatch'
$nativeWrongTarget = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSnapshot -RenderScaleStatus $nativeTaaStatus -ExpectedProfile $nativeProjectedNone
Assert-Test (-not $nativeWrongTarget.satisfied -and $nativeWrongTarget.reasons -contains 'effective native profile does not match the expected target') 'targeted native stability rejects a different effective profile'
$nativeSnapshot.transitionState = [pscustomobject]@{ name = 'active'; value = 6 }
$nativeTaaStatus.controller.state = 'Idle'
$nativeSplitState = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSnapshot -RenderScaleStatus $nativeTaaStatus -ExpectedProfile $nativeTaaProfile
Assert-Test (-not $nativeSplitState.satisfied -and $nativeSplitState.reasons -contains "native-resolution controller state is 'active/idle'") 'targeted native stability rejects split controller states'
$nativeSnapshot.transitionState = [pscustomobject]@{ name = 'idle'; value = 0 }
$nativeFsrProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeSnapshot.profiles.requested = $nativeFsrProfile
$nativeSnapshot.profiles.effective = $nativeFsrProfile
$nativeSnapshot.profiles.stable = $nativeFsrProfile
$nativeFsrStable = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test ($nativeFsrStable.satisfied -and $nativeFsrStable.method -eq 'fsr') 'native-resolution stability follows the effective method without prescribing DLSS or FSR'
$mismatchedProfile = New-TestUpscalingProfile -Method 'fsr' -RenderScale $false
$nativeSnapshot.profiles.effective = $nativeProfile
$nativeSnapshot.profiles.requested = $mismatchedProfile
$nativeMismatch = Test-DevBenchUpscalingStable -UpscalingSnapshot $nativeSnapshot -RenderScaleStatus (New-TestRenderScaleStatus -RenderScale $false)
Assert-Test (-not $nativeMismatch.satisfied -and $nativeMismatch.reasons -contains 'requested and effective profiles differ') 'native-resolution stability rejects profile divergence'

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

$expectations = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921; pid = 123; exe = 'SkyrimVR.exe'; buildId = 'build-1'; dllPath = 'C:\Test\CommunityShaders.dll'; artifactSha256 = 'ABC' })
Assert-Test ($expectations.port -eq 8921 -and $expectations.pid -eq 123 -and $expectations.exe -eq 'SkyrimVR.exe') 'runtime expectations preserve process identity fields'
Assert-Test ($expectations.buildId -eq 'build-1' -and $expectations.artifactPath -like '*CommunityShaders.dll' -and $expectations.artifactSha256 -eq 'ABC') 'runtime expectations preserve build and deployed artifact identity'
$legacy = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921 })
Assert-Test ($null -eq $legacy.pid -and $null -eq $legacy.exe) 'legacy port-only runtime metadata remains supported'

$entryPointText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') -Raw
Assert-Test ($entryPointText -notmatch '(?im)^\s*\$pid\s*=') 'entry point never assigns PowerShell reserved PID variable'
Assert-Test ($entryPointText -match '\$expectations\.buildId\s+-and\s+\$actualBuildId\s+-and') 'deferred build identity never compares a missing runtime build ID'
Assert-Test ($entryPointText -match '\$Command -eq ''wait'' -and \$statusCode -eq 404') 'transient MCP 404 recovery is restricted to bounded waits'
Assert-Test ($entryPointText -match 'mcp-session-reinitialized') 'bounded waits reinitialize invalidated MCP sessions'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$Command -eq ''wait''\)') 'unsatisfied waits fail even without RequireSuccess'
Assert-Test ($entryPointText -match '\[string\]\$EvidenceLabel') 'runtime binding evidence accepts an explicit invocation label'
Assert-Test ($entryPointText -match 'devbench-runtime-binding\.\$safeLabel\.\$stamp\.\$PID\.json') 'parallel runtime bindings use invocation-unique filenames'
Assert-Test ($entryPointText -match 'function Test-WaitRetryableException') 'bounded waits classify exhausted transient probe failures'
Assert-Test ($entryPointText -match "state = 'transport_retry'") 'serviceReady carries transient probe exhaustion into the outer wait'
Assert-Test ($entryPointText -match 'probeError = \$_.Exception.Message') 'wait observations preserve the transient probe error'
Assert-Test ($entryPointText -match "phase = 'initialize'; recovery = 'outer-wait-retry'") 'wait initialization failures remain inside the outer timeout state machine'
Assert-Test ($entryPointText -match '\$null -eq \$headers') 'bounded waits establish or re-establish the MCP session inside the polling loop'
Assert-Test ($entryPointText -match '\[switch\]\$AcceptAlreadyLoaded') 'playerLoaded exposes an explicit compatibility opt-out for freshness'
Assert-Test ($entryPointText -match '\$playerTransitionObserved') 'playerLoaded requires an observed unloaded-to-loaded transition by default'
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
