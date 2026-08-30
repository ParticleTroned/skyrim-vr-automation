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

function Test-DevBenchPerformanceNeutral {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Content)

    $observations = [Collections.Generic.List[bool]]::new()
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
        foreach ($property in $properties) {
            if ([string]$property.Name -eq 'performanceDistorted' -and
                $property.Value -is [bool]) {
                $observations.Add([bool]$property.Value)
            }
            Visit-PerformanceState $property.Value
        }
    }

    foreach ($item in @($Content)) { Visit-PerformanceState $item }
    $known = $observations.Count -gt 0
    $distorted = @($observations | Where-Object { $_ }).Count -gt 0
    return [pscustomobject][ordered]@{
        known = $known
        neutral = $known -and -not $distorted
        performanceDistorted = $distorted
        reason = if (-not $known) {
            'performance-distortion-state-missing'
        }
        elseif ($distorted) {
            'intrusive-temporal-probe-armed'
        }
        else {
            'intrusive-temporal-probe-disarmed'
        }
    }
}

Export-ModuleMember -Function Get-DevBenchSemanticStatus, Get-DevBenchServiceState, Test-DevBenchServiceReady, Test-DevBenchNoBlockingMenu, Get-DevBenchMenuDismissalPlan, Get-DevBenchRuntimeExpectations, Test-DevBenchPerformanceNeutral
