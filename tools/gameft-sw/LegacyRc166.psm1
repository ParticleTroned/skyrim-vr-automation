#Requires -Version 7.0
Set-StrictMode -Version Latest

function Assert-LegacyRc166Producer {
    param($Payload, [string]$ExpectedBuildId)
    if ($Payload.producer.sourceCommit -cne '2eef86720e5c6a48e6fa9ad93506a1f2093d0f2f' -or
        $Payload.producer.sourceDirty -isnot [bool] -or $Payload.producer.sourceDirty -or
        $Payload.producer.buildId -notmatch '^[a-fA-F0-9]{64}$' -or
        ($ExpectedBuildId -and $Payload.producer.buildId -cne $ExpectedBuildId)) {
        throw 'The explicitly supported RC166 producer identity is missing or changed.'
    }
}

function Test-LegacyRc166LoadBoundary {
    param($State, $Menus, [int]$ProcessId, [long]$PreviousFrame, [bool]$FreshLoadObserved)
    if ($State.pid -ne $ProcessId -or $State.vr -isnot [bool] -or !$State.vr -or
        $State.playerLoaded -isnot [bool] -or $null -eq $State.frame -or
        $null -eq $Menus.openMenus -or $Menus.messageBoxOpen -isnot [bool]) {
        throw 'RC166 load observation lacks typed process/player/menu evidence.'
    }
    $blocked = @($Menus.openMenus | Where-Object { $_ -in @('Main Menu', 'Loading Menu', 'LoadingMenu') }).Count -gt 0
    return $FreshLoadObserved -and $State.playerLoaded -and !$blocked -and
        !$Menus.messageBoxOpen -and $State.frame -gt $PreviousFrame
}

function Invoke-LegacyRc166Snapshot {
    param([string]$Controller, [string]$RuntimePath, [string]$Directory,
        [string]$Label, [int]$ProcessId, [string]$BuildId)
    $payloads = @{}
    foreach ($operation in @(
        @{ name = 'identity'; tool = 'inspect'; arguments = @{ kind = 'health' } },
        @{ name = 'profiler'; tool = 'communityshaders.profiler'; arguments = @{ action = 'status' } }
    )) {
        if ($operation.name -eq 'profiler' -and $BuildId) { $operation.arguments.expectedBuildId = $BuildId }
        $raw = & $Controller call -RuntimePath $RuntimePath -SkipRuntimeIdentityVerification `
            -EvidenceDirectory $Directory -EvidenceLabel "$Label-legacy-$($operation.name)" `
            -Tool $operation.tool -ArgumentsJson ($operation.arguments | ConvertTo-Json -Compress) `
            -RequirePerformanceNeutral -TimeoutSeconds 8 -RequestTimeoutSeconds 3 -MaxTransientRetries 0 -NoExit -Compact
        $raw | Set-Content -LiteralPath (Join-Path $Directory "$Label-legacy-$($operation.name).json")
        $response = $raw | ConvertFrom-Json -Depth 60
        if (!$response.transportOk -or $response.data.rawResult.isError -or $response.errors) {
            throw "RC166 $($operation.name) inspection failed."
        }
        $payloads[$operation.name] = @($response.data.content)[0]
    }
    $identity = $payloads.identity
    $profiler = $payloads.profiler
    if ($identity.pid -ne $ProcessId -or $identity.vr -isnot [bool] -or !$identity.vr) {
        throw 'RC166 inspection answered from a different process/runtime.'
    }
    Assert-LegacyRc166Producer $profiler $BuildId
    if ($profiler.action -cne 'status' -or $profiler.status.enabled -isnot [bool] -or $profiler.status.enabled) {
        throw 'RC166 user-enabled profiler state is active or unknown.'
    }
    return [pscustomobject]@{
        schema = 'gameft-sw-legacy-rc166-snapshot-v1'; processId = $ProcessId
        producer = $profiler.producer
        missingEvidence = @('cpu_burst_snapshot', 'effective feature settings', 'accepted draw observers', 'render-thread identity', 'strict render-scale lifecycle')
        profilerNote = 'Legacy status requests one capture before/after all holds; continuous user capture is disabled.'
    }
}

Export-ModuleMember -Function Assert-LegacyRc166Producer, Test-LegacyRc166LoadBoundary, Invoke-LegacyRc166Snapshot
