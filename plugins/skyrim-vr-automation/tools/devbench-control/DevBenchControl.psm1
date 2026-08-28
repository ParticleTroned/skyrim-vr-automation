# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Get-DevBenchSemanticStatus {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $known = $false
    $reasons = [Collections.Generic.List[string]]::new()
    $codes = [Collections.Generic.List[string]]::new()
    $states = [Collections.Generic.List[string]]::new()
    $retryableHints = [Collections.Generic.List[bool]]::new()
    $guardCodes = @('producer_mismatch', 'contract_mismatch', 'unsupported_contract_major', 'idempotency_conflict')
    $successNames = @('success', 'ok', 'ready', 'completed', 'accepted', 'idle', 'available')
    $transientNames = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running')

    function Visit-Value($Value, [string]$Path) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        if ($Value -is [Collections.IDictionary]) {
            $properties = @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            $index = 0
            foreach ($entry in $Value) { Visit-Value $entry "$Path[$index]"; $index++ }
            return
        }
        else {
            $properties = @($Value.PSObject.Properties)
        }

        foreach ($property in $properties) {
            $name = [string]$property.Name
            $childPath = if ([string]::IsNullOrWhiteSpace($Path)) { $name } else { "$Path.$name" }
            $child = $property.Value
            if ($name -eq 'ok' -and $null -ne $child) {
                $script:semanticKnown = $true
                if (-not [bool]$child) { $reasons.Add("$childPath is false") }
            }
            elseif ($name -eq 'aborted' -and [bool]$child) {
                $script:semanticKnown = $true
                $reasons.Add("$childPath is true")
            }
            elseif ($name -eq 'retryable' -and $null -ne $child) {
                $script:semanticKnown = $true
                if ([bool]$child) { $retryableHints.Add($true) }
            }
            elseif ($name -eq 'code' -and $child -is [string] -and -not [string]::IsNullOrWhiteSpace($child)) {
                $script:semanticKnown = $true
                if (-not $codes.Contains([string]$child)) { $codes.Add([string]$child) }
                if ([string]$child -notin $successNames) { $reasons.Add("$childPath is '$child'") }
            }
            elseif ($name -eq 'state' -and $child -is [string] -and -not [string]::IsNullOrWhiteSpace($child)) {
                if (-not $states.Contains([string]$child)) { $states.Add([string]$child) }
            }
            elseif ($name -in @('status', 'resultStatus') -and $null -ne $child) {
                $nameProperty = $child.PSObject.Properties['name']
                $valueProperty = $child.PSObject.Properties['value']
                if ($nameProperty) {
                    $script:semanticKnown = $true
                    $statusName = [string]$nameProperty.Value
                    if (-not $codes.Contains($statusName)) { $codes.Add($statusName) }
                    if ($statusName -notin $successNames) { $reasons.Add("$childPath.name is '$statusName'") }
                }
                if ($valueProperty) {
                    $script:semanticKnown = $true
                    if ([int64]$valueProperty.Value -ne 0) { $reasons.Add("$childPath.value is $($valueProperty.Value)") }
                }
            }
            Visit-Value $child $childPath
        }
    }

    $script:semanticKnown = $false
    try {
        foreach ($item in @($Content)) { Visit-Value $item 'content' }
        $known = $script:semanticKnown
    }
    finally {
        Remove-Variable semanticKnown -Scope Script -ErrorAction SilentlyContinue
    }
    $guarded = @($codes | Where-Object { $_ -in $guardCodes }).Count -gt 0
    $transient = $retryableHints.Count -gt 0 -or @($codes + $states | Where-Object { $_ -in $transientNames }).Count -gt 0
    $ok = $reasons.Count -eq 0
    $outcome = if ($ok) { if ($transient) { 'accepted-transient' } else { 'success' } } elseif ($guarded) { 'guard-rejected' } else { 'failure' }
    return [pscustomobject][ordered]@{
        known = $known
        ok = $ok
        outcome = $outcome
        guarded = $guarded
        transient = $transient
        codes = @($codes)
        states = @($states)
        reasons = @($reasons | Select-Object -Unique)
    }
}

function Get-DevBenchServiceState {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $found = [Collections.Generic.List[object]]::new()
    function Visit-State($Value, [string]$Path) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        $properties = if ($Value -is [Collections.IDictionary]) {
            @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            $i = 0; foreach ($entry in $Value) { Visit-State $entry "$Path[$i]"; $i++ }; return
        }
        else { @($Value.PSObject.Properties) }
        foreach ($property in $properties) {
            $childPath = if ($Path) { "$Path.$($property.Name)" } else { [string]$property.Name }
            if ([string]$property.Name -eq 'state' -and $property.Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $priority = if ($childPath -match '(^|\.)result\.state$') { 0 } elseif ($childPath -eq 'content.state') { 1 } else { 2 }
                $found.Add([pscustomobject]@{ state = [string]$property.Value; path = $childPath; priority = $priority })
            }
            Visit-State $property.Value $childPath
        }
    }
    foreach ($item in @($Content)) { Visit-State $item 'content' }
    return @($found | Sort-Object priority, path | Select-Object -First 1)
}

function Test-DevBenchServiceReady {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Content,
        [string[]]$AcceptedStates = @('ready', 'idle', 'available', 'completed', 'success', 'ok'),
        [string[]]$RetryableStates = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running')
    )
    $semantic = Get-DevBenchSemanticStatus -Content $Content
    $stateRecord = @(Get-DevBenchServiceState -Content $Content | Select-Object -First 1)
    $state = if ($stateRecord.Count -gt 0) { [string]$stateRecord[0].state } else { $null }
    $retryable = $semantic.transient -or ($state -in $RetryableStates)
    $terminalFailure = -not $semantic.ok -and -not $retryable
    $ready = if ($state) { $state -in $AcceptedStates } else { $semantic.known -and $semantic.ok -and -not $retryable }
    return [pscustomobject][ordered]@{
        ready = $ready
        retryable = $retryable
        terminalFailure = $terminalFailure
        state = $state
        statePath = if ($stateRecord.Count -gt 0) { $stateRecord[0].path } else { $null }
        semantic = $semantic
    }
}

function Test-DevBenchNoBlockingMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MenuState,
        [string[]]$IgnoredMenus = @('HUD Menu')
    )
    $openMenus = if ($MenuState.PSObject.Properties['openMenus']) { @($MenuState.openMenus) } else { @() }
    $blocking = @($openMenus | Where-Object { $_ -notin $IgnoredMenus })
    $messageBoxOpen = $MenuState.PSObject.Properties['messageBoxOpen'] -and [bool]$MenuState.messageBoxOpen
    return [pscustomobject][ordered]@{
        satisfied = $blocking.Count -eq 0 -and -not $messageBoxOpen
        openMenus = $openMenus
        ignoredMenus = @($IgnoredMenus)
        blockingMenus = $blocking
        messageBoxOpen = [bool]$messageBoxOpen
    }
}

function Get-DevBenchNamedValue {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value.ToLowerInvariant() }
    $name = $Value.PSObject.Properties['name']
    if ($name -and $null -ne $name.Value) {
        return ([string]$name.Value).ToLowerInvariant()
    }
    return ([string]$Value).ToLowerInvariant()
}

function Get-DevBenchResourcePublicationTelemetry {
    [CmdletBinding()]
    param($Response)

    function Get-PublicationMember($Value, [string]$Name) {
        if ($null -eq $Value -or $Value -is [ValueType] -or $Value -is [string]) {
            return $null
        }
        if ($Value -is [Collections.IDictionary]) {
            return $(if ($Value.Contains($Name)) { $Value[$Name] } else { $null })
        }
        $property = $Value.PSObject.Properties[$Name]
        return $(if ($property) { $property.Value } else { $null })
    }

    function New-PublicationTelemetry($Publication, [string]$SourcePath) {
        $fields = @(
            'current', 'currentGeneration', 'completedGeneration',
            'publishedGeneration', 'expectedWidth', 'expectedHeight',
            'publishedWidth', 'publishedHeight', 'complete',
            'deferredSetupAcknowledged', 'deviceMatches', 'contextMatches'
        )
        $missing = [Collections.Generic.List[string]]::new()
        $values = [ordered]@{}
        foreach ($field in $fields) {
            $values[$field] = Get-PublicationMember $Publication $field
            if ($null -eq $values[$field]) { $missing.Add($field) }
        }
        return [pscustomobject][ordered]@{
            schema = 'csx-resource-publication-telemetry-v1'
            available = $null -ne $Publication
            sourcePath = $SourcePath
            missingFields = @($missing)
            current = $values.current
            currentGeneration = $values.currentGeneration
            completedGeneration = $values.completedGeneration
            publishedGeneration = $values.publishedGeneration
            expectedWidth = $values.expectedWidth
            expectedHeight = $values.expectedHeight
            publishedWidth = $values.publishedWidth
            publishedHeight = $values.publishedHeight
            complete = $values.complete
            deferredSetupAcknowledged = $values.deferredSetupAcknowledged
            deviceMatches = $values.deviceMatches
            contextMatches = $values.contextMatches
            evaluated = Get-PublicationMember $Publication 'evaluated'
            present = Get-PublicationMember $Publication 'present'
            generationMatchesCurrent = Get-PublicationMember $Publication 'generationMatchesCurrent'
            generationMatchesCompleted = Get-PublicationMember $Publication 'generationMatchesCompleted'
            dimensionsMatch = Get-PublicationMember $Publication 'dimensionsMatch'
        }
    }

    $queue = [Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ value = $Response; path = '$'; depth = 0 })
    while ($queue.Count -gt 0) {
        $entry = $queue.Dequeue()
        $publication = Get-PublicationMember $entry.value 'resourcePublication'
        if ($null -ne $publication) {
            return New-PublicationTelemetry $publication "$($entry.path).resourcePublication"
        }
        if ([int]$entry.depth -ge 3) { continue }
        foreach ($name in @('value', 'result', 'status', 'observation')) {
            $child = Get-PublicationMember $entry.value $name
            if ($null -ne $child) {
                $queue.Enqueue([pscustomobject]@{
                        value = $child
                        path = "$($entry.path).$name"
                        depth = [int]$entry.depth + 1
                    })
            }
        }
    }
    return New-PublicationTelemetry $null $null
}

function Test-DevBenchUpscalingProfilesEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    foreach ($name in @('method', 'qualityMode', 'renderScaleMode', 'dlssProfile', 'fsrRuntime')) {
        $leftProperty = $Left.PSObject.Properties[$name]
        $rightProperty = $Right.PSObject.Properties[$name]
        if (-not $leftProperty -or -not $rightProperty) { return $false }
        $leftValue = if ($name -eq 'renderScaleMode') { [bool]$leftProperty.Value } else { Get-DevBenchNamedValue $leftProperty.Value }
        $rightValue = if ($name -eq 'renderScaleMode') { [bool]$rightProperty.Value } else { Get-DevBenchNamedValue $rightProperty.Value }
        if ($leftValue -ne $rightValue) { return $false }
    }
    return $true
}

function Test-DevBenchUpscalingStable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$UpscalingSnapshot,
        [Parameter(Mandatory)]$RenderScaleStatus
    )

    $snapshot = if ($UpscalingSnapshot.PSObject.Properties['snapshot']) { $UpscalingSnapshot.snapshot } else { $UpscalingSnapshot }
    $renderStatus = if ($RenderScaleStatus.PSObject.Properties['status']) { $RenderScaleStatus.status } else { $RenderScaleStatus }
    $reasons = [Collections.Generic.List[string]]::new()
    function Require-StableValue([bool]$Condition, [string]$Reason) {
        if (-not $Condition) { $reasons.Add($Reason) }
    }

    $profilePresence = if ($snapshot.PSObject.Properties['profilePresence']) { [uint32]$snapshot.profilePresence } else { 0u }
    $flags = if ($snapshot.PSObject.Properties['flags']) { [uint64]$snapshot.flags } else { 0u }
    $renderScaleStatusName = Get-DevBenchNamedValue $snapshot.renderScaleStatus
    $transitionState = Get-DevBenchNamedValue $snapshot.transitionState
    $renderScaleActive = $renderScaleStatusName -eq 'active'
    $profiles = $snapshot.profiles
    $hasRequested = ($profilePresence -band 0x2u) -ne 0
    $hasEffective = ($profilePresence -band 0x8u) -ne 0
    $hasStable = ($profilePresence -band 0x10u) -ne 0
    $criticalConditions = @(
        'loading_transition', 'relatch_pending', 'transition_pending',
        'first_world_frame_pending', 'post_load_recovery',
        'provider_check_pending', 'provider_unavailable', 'restart_required',
        'resource_recovery'
    )
    $conditionNames = if ($snapshot.observedConditions -and $snapshot.observedConditions.PSObject.Properties['names']) {
        @($snapshot.observedConditions.names | ForEach-Object { ([string]$_).ToLowerInvariant() })
    } else { @() }
    $blockingConditions = @($conditionNames | Where-Object { $_ -in $criticalConditions })

    Require-StableValue (($flags -band 0x1u) -ne 0) 'provider check is incomplete'
    Require-StableValue (($flags -band 0x2u) -eq 0) 'an upscaling transition is active'
    Require-StableValue (($flags -band 0x4u) -eq 0) 'an upscaling restart is required'
    Require-StableValue ([uint64]$snapshot.activeOperationId -eq 0) 'an upscaling operation is still active'
    Require-StableValue ($blockingConditions.Count -eq 0) "blocking upscaling conditions remain: $($blockingConditions -join ', ')"
    Require-StableValue ($hasRequested -and $hasEffective) 'requested and effective profiles are not both authoritative'
    if ($hasRequested -and $hasEffective) {
        Require-StableValue (Test-DevBenchUpscalingProfilesEqual $profiles.requested $profiles.effective) 'requested and effective profiles differ'
    }
    if ($hasStable -and $hasEffective) {
        Require-StableValue (Test-DevBenchUpscalingProfilesEqual $profiles.stable $profiles.effective) 'stable and effective profiles differ'
    }
    Require-StableValue (
        [uint32]$snapshot.dimensions.displayEyeWidth -gt 0 -and
        [uint32]$snapshot.dimensions.displayEyeHeight -gt 0 -and
        [uint32]$snapshot.dimensions.renderEyeWidth -gt 0 -and
        [uint32]$snapshot.dimensions.renderEyeHeight -gt 0
    ) 'upscaling dimensions are not materialized'

    $controller = $renderStatus.controller
    $gate = $renderStatus.vendorWorkGate
    Require-StableValue (-not [bool]$controller.terminalFailureSignaled) 'render-scale terminal failure is signaled'
    Require-StableValue (-not [bool]$controller.terminalDeviceLossSignaled) 'render-scale device loss is signaled'
    Require-StableValue ([uint64]$controller.unresolvedPhysicalMutationEpoch -eq 0) 'a physical render-scale mutation remains unresolved'
    Require-StableValue (-not [bool]$gate.active) 'the vendor work gate is active'
    Require-StableValue ([bool]$gate.completedWorldFrame) 'no completed destination world frame is available'
    foreach ($name in @('loadingMenu', 'loadingPresentationActive', 'postLoadResetPending', 'relatchQueued', 'relatchInProgress', 'relatchFramePending', 'relatchPostLoadSettle', 'recoveryPending', 'relatchPending', 'profileTransitionPending')) {
        $property = $gate.PSObject.Properties[$name]
        if ($property) { Require-StableValue (-not [bool]$property.Value) "vendor work gate '$name' remains active" }
    }
    if ($controller.postLoadRecovery) {
        Require-StableValue (-not [bool]$controller.postLoadRecovery.active) 'post-load render-scale recovery is active'
    }
    if ($controller.memoryTrim) {
        Require-StableValue (-not [bool]$controller.memoryTrim.pending) 'render-scale memory trim is pending'
    }
    if ($controller.retirement) {
        Require-StableValue (
            [uint32]$controller.retirement.pendingSets -eq 0 -and
            -not [bool]$controller.retirement.fencePending -and
            -not [bool]$controller.retirement.capacityBlocked
        ) 'render-scale resource retirement is pending'
    }
    if ($controller.engineTargetRetirement) {
        Require-StableValue (-not [bool]$controller.engineTargetRetirement.pending) 'engine render-target retirement is pending'
    }

    $method = if ($hasEffective) { Get-DevBenchNamedValue $profiles.effective.method } else { $null }
    $qualityMode = if ($hasEffective) { Get-DevBenchNamedValue $profiles.effective.qualityMode } else { $null }
    $effectiveRenderScaleMode = if ($hasEffective) { [bool]$profiles.effective.renderScaleMode } else { $false }
    $dlssProfile = if ($hasEffective) { Get-DevBenchNamedValue $profiles.effective.dlssProfile } else { $null }
    $fsrRuntime = if ($hasEffective) { Get-DevBenchNamedValue $profiles.effective.fsrRuntime } else { $null }
    $stereoEvidence = 'native_pipeline_frames'
    if ($renderScaleActive) {
        $stereoEvidence = 'render_scale_fidelity'
        Require-StableValue (($flags -band 0x10u) -ne 0 -and ($flags -band 0x20u) -ne 0) 'render-scale is not both latched and active'
        Require-StableValue ($hasStable) 'the stable render-scale profile is not authoritative'
        Require-StableValue ($transitionState -eq 'active') "render-scale transition state is '$transitionState'"
        Require-StableValue ((Get-DevBenchNamedValue $renderStatus.modeStatus) -eq 'active') 'render-scale mode status is not active'
        Require-StableValue ((Get-DevBenchNamedValue $controller.state) -eq 'active') 'render-scale controller is not active'
        Require-StableValue ((Get-DevBenchNamedValue $controller.presentationPhase) -in @('stereo_proven', 'released')) 'stereo presentation has not been proven or released'
        Require-StableValue ([bool]$controller.stable.valid -and [bool]$controller.stable.active) 'stable render-scale contract is invalid or inactive'

        $fidelity = $controller.fidelity
        Require-StableValue ([bool]$fidelity.active -and [bool]$fidelity.bothEyesValid) 'both render-scale eyes are not valid'
        Require-StableValue ([uint32]$fidelity.evaluationEyeMask -eq 3 -and [uint32]$fidelity.invariantEyeMask -eq 3) 'both-eye evaluation or invariant mask is incomplete'
        Require-StableValue ([uint32]$fidelity.lastMismatchMask -eq 0) 'the latest render-scale fidelity observation mismatched'
        $fidelityEyes = @($fidelity.eyes)
        Require-StableValue ($fidelityEyes.Count -eq 2) 'render-scale fidelity did not expose two eyes'
        if ($fidelityEyes.Count -eq 2) {
            Require-StableValue (@($fidelityEyes | Where-Object { -not [bool]$_.valid -or -not [bool]$_.evaluated }).Count -eq 0) 'one or more render-scale eyes are invalid or unevaluated'
            Require-StableValue ([Math]::Abs([int64]$fidelityEyes[0].frame - [int64]$fidelityEyes[1].frame) -le 1) 'render-scale eye observations are not frame-coherent'
        }

        $presentation = $controller.presentation
        $presentationEyes = @($presentation.eyes)
        Require-StableValue ([uint32]$presentation.consecutiveBothEyesVendorFrames -ge 2) 'fewer than two consecutive stereo vendor frames are proven'
        Require-StableValue ($presentationEyes.Count -eq 2) 'render-scale presentation did not expose two eyes'
        if ($presentationEyes.Count -eq 2) {
            $paths = @($presentationEyes | ForEach-Object { Get-DevBenchNamedValue $_.path } | Select-Object -Unique)
            Require-StableValue (@($presentationEyes | Where-Object { -not [bool]$_.valid -or [bool]$_.loadingOrMenuContext -or [bool]$_.transitionCooldown }).Count -eq 0) 'one or more presentation eyes remain invalid or transitional'
            Require-StableValue ($paths.Count -eq 1 -and $paths[0] -eq 'vendorevaluated') 'both eyes are not using the same vendor-evaluated presentation path'
        }

        if ($method -eq 'fsr') {
            $fsr = $renderStatus.fsrDispatch
            Require-StableValue ([bool]$fsr.actualDispatchBothEyesValid -and [bool]$fsr.actualDispatchBackendConverged) 'FSR did not prove a converged two-eye dispatch'
            Require-StableValue (-not [bool]$fsr.actualRuntimeFallbackObserved) 'FSR runtime fallback is active'
            Require-StableValue (-not [bool]$fsr.shaderCompilationActive) 'shader compilation is active'
            Require-StableValue ([bool]$fsr.contractReady -and (Get-DevBenchNamedValue $fsr.contractLifecyclePhase) -eq 'ready') 'FSR runtime contract is not ready'
        }
        elseif ($method -eq 'dlss') {
            $lifecycle = $controller.dlssLifecycle
            Require-StableValue ([bool]$lifecycle.resourcesPresent -and [bool]$lifecycle.readyForContract) 'DLSS runtime resources are not ready'
            Require-StableValue ((Get-DevBenchNamedValue $lifecycle.phase) -eq 'ready' -and [uint32]$lifecycle.failures -eq 0) 'DLSS runtime lifecycle is not cleanly ready'
        }
    }
    else {
        Require-StableValue ($transitionState -eq 'idle') "native-resolution transition state is '$transitionState'"
        Require-StableValue (($flags -band 0x10u) -eq 0 -and ($flags -band 0x20u) -eq 0) 'render-scale remains latched or active for a native-resolution profile'
        Require-StableValue ((Get-DevBenchNamedValue $controller.state) -eq 'idle') 'render-scale controller has not returned to idle'
    }

    $signature = if ($hasEffective) {
        @(
            $method,
            (Get-DevBenchNamedValue $profiles.effective.qualityMode),
            [bool]$profiles.effective.renderScaleMode,
            (Get-DevBenchNamedValue $profiles.effective.dlssProfile),
            (Get-DevBenchNamedValue $profiles.effective.fsrRuntime),
            [uint32]$snapshot.dimensions.displayEyeWidth,
            [uint32]$snapshot.dimensions.displayEyeHeight,
            [uint32]$snapshot.dimensions.renderEyeWidth,
            [uint32]$snapshot.dimensions.renderEyeHeight,
            [uint64]$controller.targetEpoch,
            [uint32]$controller.stable.contractGeneration
        ) -join '|'
    } else { $null }

    return [pscustomobject][ordered]@{
        satisfied = $reasons.Count -eq 0
        renderScaleActive = $renderScaleActive
        stereoEvidence = $stereoEvidence
        method = $method
        qualityMode = $qualityMode
        effectiveRenderScaleMode = $effectiveRenderScaleMode
        dlssProfile = $dlssProfile
        fsrRuntime = $fsrRuntime
        frame = [uint32]$renderStatus.frame
        signature = $signature
        resourcePublication = Get-DevBenchResourcePublicationTelemetry -Response $RenderScaleStatus
        reasons = @($reasons | Select-Object -Unique)
    }
}

function Get-DevBenchRuntimeExpectations {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Runtime)
    $pidValue = $null
    foreach ($name in @('pid', 'processId')) {
        $property = $Runtime.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value) { $pidValue = [int]$property.Value; break }
    }
    $exeValue = $null
    foreach ($name in @('exe', 'executable')) {
        $property = $Runtime.PSObject.Properties[$name]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $exeValue = [string]$property.Value; break }
    }
    $buildId = if ($Runtime.PSObject.Properties['buildId']) { [string]$Runtime.buildId } else { $null }
    $artifactPath = if ($Runtime.PSObject.Properties['artifactPath']) { [string]$Runtime.artifactPath } elseif ($Runtime.PSObject.Properties['dllPath']) { [string]$Runtime.dllPath } else { $null }
    $artifactSha256 = if ($Runtime.PSObject.Properties['artifactSha256']) { [string]$Runtime.artifactSha256 } else { $null }
    return [pscustomobject][ordered]@{ port = [int]$Runtime.port; pid = $pidValue; exe = $exeValue; buildId = $buildId; artifactPath = $artifactPath; artifactSha256 = $artifactSha256 }
}

Export-ModuleMember -Function Get-DevBenchSemanticStatus, Get-DevBenchServiceState, Test-DevBenchServiceReady, Test-DevBenchNoBlockingMenu, Get-DevBenchNamedValue, Get-DevBenchResourcePublicationTelemetry, Test-DevBenchUpscalingProfilesEqual, Test-DevBenchUpscalingStable, Get-DevBenchRuntimeExpectations
