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
    $replaySchedulerReceipts = [Collections.Generic.List[string]]::new()
    $explicitOutcomeEvidence = [Collections.Generic.List[string]]::new()
    $guardCodes = @('producer_mismatch', 'contract_mismatch', 'unsupported_contract_major', 'idempotency_conflict')
    $successNames = @('success', 'ok', 'ready', 'completed', 'accepted', 'idle', 'available')
    $transientNames = @('service_unavailable', 'initializing', 'starting', 'waiting_for_safe_point', 'loading_transition', 'relatch_pending', 'compiling', 'pending', 'queued', 'running')

    function Test-ExplicitOutcomeValue($Value) {
        if ($null -eq $Value) { return $false }
        if ($Value -is [bool]) { return $true }
        if ($Value -is [string] -or $Value -is [ValueType]) { return $false }
        if ($Value -is [Collections.IDictionary]) {
            $evidenceProperties = @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            foreach ($entry in $Value) { if (Test-ExplicitOutcomeValue $entry) { return $true } }
            return $false
        }
        else {
            $evidenceProperties = @($Value.PSObject.Properties)
        }
        foreach ($property in $evidenceProperties) {
            $name = [string]$property.Name
            if ($name -in @('ok', 'success', 'passed', 'failed', 'aborted', 'code', 'state', 'status', 'resultStatus') -and $null -ne $property.Value) {
                return $true
            }
            if (Test-ExplicitOutcomeValue $property.Value) { return $true }
        }
        return $false
    }

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

        $propertyNames = @($properties | ForEach-Object { [string]$_.Name })
        if ($propertyNames -contains 'done' -and $propertyNames -contains 'runId' -and $propertyNames -contains 'result') {
            $resultProperty = @($properties | Where-Object Name -eq 'result' | Select-Object -First 1)
            if ($resultProperty.Count -eq 1 -and $null -ne $resultProperty[0].Value -and
                $resultProperty[0].Value.PSObject.Properties['stepsRun']) {
                $replaySchedulerReceipts.Add($Path)
            }
        }
        foreach ($evidenceName in @('semantic', 'postconditions', 'outcomeChecks', 'assertions')) {
            $evidenceProperty = @($properties | Where-Object Name -eq $evidenceName | Select-Object -First 1)
            if ($evidenceProperty.Count -eq 1 -and (Test-ExplicitOutcomeValue $evidenceProperty[0].Value)) {
                $explicitOutcomeEvidence.Add("$Path.$evidenceName")
            }
        }

        foreach ($property in $properties) {
            $name = [string]$property.Name
            $childPath = if ([string]::IsNullOrWhiteSpace($Path)) { $name } else { "$Path.$name" }
            $child = $property.Value
            if ($name -eq 'ok' -and $null -ne $child) {
                $script:semanticKnown = $true
                if (-not [bool]$child) { $reasons.Add("$childPath is false") }
            }
            elseif ($name -in @('success', 'passed') -and $child -is [bool]) {
                $script:semanticKnown = $true
                if (-not [bool]$child) { $reasons.Add("$childPath is false") }
            }
            elseif ($name -eq 'failed' -and $child -is [bool]) {
                $script:semanticKnown = $true
                if ([bool]$child) { $reasons.Add("$childPath is true") }
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
    $schedulerOnly = $replaySchedulerReceipts.Count -gt 0 -and $explicitOutcomeEvidence.Count -eq 0 -and $reasons.Count -eq 0
    if ($schedulerOnly) { $known = $false }
    $guarded = @($codes | Where-Object { $_ -in $guardCodes }).Count -gt 0
    $transient = $retryableHints.Count -gt 0 -or @($codes + $states | Where-Object { $_ -in $transientNames }).Count -gt 0
    $ok = $reasons.Count -eq 0
    $outcome = if ($schedulerOnly) { 'scheduler-complete-unverified' } elseif ($ok) { if ($transient) { 'accepted-transient' } else { 'success' } } elseif ($guarded) { 'guard-rejected' } else { 'failure' }
    return [pscustomobject][ordered]@{
        known = $known
        ok = $ok
        outcome = $outcome
        guarded = $guarded
        transient = $transient
        codes = @($codes)
        states = @($states)
        reasons = @($reasons | Select-Object -Unique)
        schedulerOnly = $schedulerOnly
        schedulerReceiptPaths = @($replaySchedulerReceipts)
        explicitOutcomeEvidence = @($explicitOutcomeEvidence)
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
    $probeReturnedContent = @($Content).Count -gt 0
    # Transport success or arbitrary non-empty content proves only that the
    # tool answered. Readiness requires a recognized positive contract state;
    # otherwise polling an unknown payload could repeatedly dispatch work and
    # then promote the unclassified response to ready.
    $ready = if ($state) { $state -in $AcceptedStates } elseif ($semantic.known) { $semantic.ok -and -not $retryable } else { $false }
    return [pscustomobject][ordered]@{
        ready = $ready
        retryable = $retryable
        terminalFailure = $terminalFailure
        state = $state
        statePath = if ($stateRecord.Count -gt 0) { $stateRecord[0].path } else { $null }
        probeReturnedContent = $probeReturnedContent
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

function Get-DevBenchMenuDismissalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$MenuObservation,
        [string[]]$DismissBlockingMenus = @()
    )
    $requested = @($DismissBlockingMenus |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)
    $blocking = if ($MenuObservation.PSObject.Properties['blockingMenus']) {
        @($MenuObservation.blockingMenus)
    }
    else {
        @()
    }
    $messageBoxOpen = $MenuObservation.PSObject.Properties['messageBoxOpen'] -and
        [bool]$MenuObservation.messageBoxOpen
    $dismiss = @($blocking | Where-Object { $_ -in $requested })
    $retained = @($blocking | Where-Object { $_ -notin $requested })
    $permitted = -not $messageBoxOpen -and $dismiss.Count -gt 0 -and $retained.Count -eq 0
    $reason = if ($messageBoxOpen) {
        'message-box-requires-explicit-answer'
    }
    elseif ($retained.Count -gt 0) {
        'unlisted-blocking-menu'
    }
    elseif ($dismiss.Count -eq 0) {
        'no-listed-menu-open'
    }
    else {
        'explicit-menu-dismissal'
    }
    return [pscustomobject][ordered]@{
        permitted = $permitted
        reason = $reason
        requestedMenus = $requested
        dismissMenus = $dismiss
        retainedMenus = $retained
        messageBoxOpen = [bool]$messageBoxOpen
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

function Resolve-DevBenchServiceProbeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ToolDefinition,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][bool]$ArgumentsSupplied,
        [Parameter(Mandatory)][string]$ToolName
    )

    if ($ArgumentsSupplied) {
        throw "serviceReady does not accept explicit -ArgumentsJson because an arbitrary action cannot be proven read-only across retries. Use toolAvailable for registration-only waits or omit -ArgumentsJson so the controller can synthesize a qualified probe."
    }

    $schemaProperty = $ToolDefinition.PSObject.Properties['inputSchema']
    if (-not $schemaProperty -or $null -eq $schemaProperty.Value) {
        throw "serviceReady cannot safely probe '$ToolName' because tools/list did not publish an inputSchema. Use toolAvailable when registration is sufficient."
    }
    $schema = $schemaProperty.Value
    $requiredProperty = $schema.PSObject.Properties['required']
    [string[]]$required = @()
    if ($requiredProperty -and $null -ne $requiredProperty.Value) {
        $required = @($requiredProperty.Value | ForEach-Object { [string]$_ })
    }
    if ($required.Count -eq 0) {
        return [pscustomobject][ordered]@{ arguments = $Arguments; source = 'schema-empty-valid'; synthesizedAction = $null }
    }

    $missing = @($required | Where-Object { -not $Arguments.Contains($_) })
    if ($missing.Count -eq 0) {
        return [pscustomobject][ordered]@{ arguments = $Arguments; source = 'schema-satisfied'; synthesizedAction = $null }
    }
    $supportedEnvelope = @('contractMajor', 'clientId', 'commandId', 'action')
    $unknownRequired = @($missing | Where-Object { $_ -notin $supportedEnvelope })
    if ($unknownRequired.Count -gt 0) {
        throw "serviceReady cannot synthesize a qualified read-only probe for '$ToolName'; required field(s) are not part of the registry envelope: $($unknownRequired -join ', '). Use toolAvailable or add a reviewed tool-specific probe adapter."
    }

    $propertiesProperty = $schema.PSObject.Properties['properties']
    $properties = if ($propertiesProperty) { $propertiesProperty.Value } else { $null }
    $action = $null
    if ($missing -contains 'action') {
        $actionSchema = if ($properties) { $properties.PSObject.Properties['action'] } else { $null }
        $enumProperty = if ($actionSchema) { $actionSchema.Value.PSObject.Properties['enum'] } else { $null }
        $allowedActions = if ($enumProperty) { @($enumProperty.Value | ForEach-Object { [string]$_ }) } else { @() }
        if ($allowedActions.Count -eq 0 -or $allowedActions -contains 'registry') { $action = 'registry' }
        elseif ($allowedActions -contains 'capabilities') { $action = 'capabilities' }
        else {
            throw "serviceReady cannot synthesize a qualified read-only probe for '$ToolName'; action supports neither registry nor capabilities. Use toolAvailable or add a reviewed tool-specific probe adapter."
        }
    }

    $resolved = [ordered]@{}
    foreach ($key in $Arguments.Keys) { $resolved[[string]$key] = $Arguments[$key] }
    if ($missing -contains 'contractMajor') {
        $contractSchema = if ($properties) { $properties.PSObject.Properties['contractMajor'] } else { $null }
        $constProperty = if ($contractSchema) { $contractSchema.Value.PSObject.Properties['const'] } else { $null }
        $defaultProperty = if ($contractSchema) { $contractSchema.Value.PSObject.Properties['default'] } else { $null }
        $resolved['contractMajor'] = if ($constProperty) { [int]$constProperty.Value } elseif ($defaultProperty) { [int]$defaultProperty.Value } else { 1 }
    }
    if ($missing -contains 'clientId') { $resolved['clientId'] = 'devbench-control-service-ready' }
    if ($missing -contains 'commandId') { $resolved['commandId'] = "service-ready-$([guid]::NewGuid().ToString('N'))" }
    if ($missing -contains 'action') { $resolved['action'] = $action }

    return [pscustomobject][ordered]@{ arguments = $resolved; source = 'schema-registry-envelope'; synthesizedAction = $action }
}

function Test-DevBenchPerformanceNeutral {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $observations = [Collections.Generic.List[object]]::new()
    $scan = [pscustomobject]@{ sawDistortionField = $false }
    function Visit-PerformanceState($Value) {
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) { return }
        $properties = if ($Value -is [Collections.IDictionary]) {
            @($Value.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value } })
        }
        elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
            foreach ($entry in $Value) { Visit-PerformanceState $entry }
            return
        }
        else { @($Value.PSObject.Properties) }

        $distortion = @($properties | Where-Object Name -eq 'performanceDistorted') | Select-Object -First 1
        if ($null -ne $distortion) {
            $scan.sawDistortionField = $true
            $epoch = @($properties | Where-Object Name -eq 'performanceEpoch') | Select-Object -First 1
            $physical = @($properties | Where-Object Name -eq 'physicalStateKnown') | Select-Object -First 1
            $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
            $epochIsInteger = $null -ne $epoch -and
                @($integerTypes | Where-Object { $_.IsInstanceOfType($epoch.Value) }).Count -gt 0
            if ($distortion.Value -is [bool] -and $epochIsInteger -and
                $null -ne $physical -and $physical.Value -is [bool]) {
                $observations.Add([pscustomobject][ordered]@{
                    distorted = [bool]$distortion.Value
                    epoch = [uint64]$epoch.Value
                    physicalStateKnown = [bool]$physical.Value
                })
            }
        }
        foreach ($property in $properties) { Visit-PerformanceState $property.Value }
    }

    foreach ($item in @($Content)) { Visit-PerformanceState $item }
    $known = $observations.Count -gt 0
    $distorted = @($observations | Where-Object distorted).Count -gt 0
    $physicalStateKnown = $known -and
        @($observations | Where-Object { -not $_.physicalStateKnown }).Count -eq 0
    $epochs = @($observations | ForEach-Object epoch | Sort-Object -Unique)
    $epochKnown = $epochs.Count -eq 1
    return [pscustomobject][ordered]@{
        known = $known
        neutral = $known -and -not $distorted -and $physicalStateKnown -and $epochKnown
        performanceDistorted = $distorted
        performanceEpoch = if ($epochKnown) { [uint64]$epochs[0] } else { $null }
        physicalStateKnown = $physicalStateKnown
        reason = if (-not $known -and $scan.sawDistortionField) {
            'performance-ownership-state-missing'
        }
        elseif (-not $known) {
            'performance-distortion-state-missing'
        }
        elseif ($distorted) {
            'intrusive-temporal-probe-armed'
        }
        elseif (-not $physicalStateKnown) {
            'performance-physical-state-unproven'
        }
        elseif (-not $epochKnown) {
            'performance-epoch-ambiguous'
        }
        else {
            'intrusive-temporal-probe-disarmed'
        }
    }
}

function Test-DevBenchPerformanceWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )

    $applicable = [bool]$Before.applicable -or [bool]$After.applicable
    $sameApplicability = [bool]$Before.applicable -eq [bool]$After.applicable
    $sameEpoch = -not $applicable -or
        ($null -ne $Before.performanceEpoch -and
            $null -ne $After.performanceEpoch -and
            [uint64]$Before.performanceEpoch -eq [uint64]$After.performanceEpoch)
    $valid = $sameApplicability -and [bool]$Before.neutral -and
        [bool]$After.neutral -and $sameEpoch
    return [pscustomobject][ordered]@{
        valid = $valid
        applicable = $applicable
        sameEpoch = $sameEpoch
        before = $Before
        after = $After
        reason = if (-not $sameApplicability) {
            'performance-probe-registration-changed'
        }
        elseif (-not [bool]$Before.neutral) {
            [string]$Before.reason
        }
        elseif (-not [bool]$After.neutral) {
            [string]$After.reason
        }
        elseif (-not $sameEpoch) {
            'performance-probe-epoch-changed'
        }
        else {
            'performance-window-neutral'
        }
    }
}

Export-ModuleMember -Function Get-DevBenchSemanticStatus, Get-DevBenchServiceState, Test-DevBenchServiceReady, Test-DevBenchNoBlockingMenu, Get-DevBenchMenuDismissalPlan, Get-DevBenchRuntimeExpectations, Resolve-DevBenchServiceProbeArguments, Test-DevBenchPerformanceNeutral, Test-DevBenchPerformanceWindow
