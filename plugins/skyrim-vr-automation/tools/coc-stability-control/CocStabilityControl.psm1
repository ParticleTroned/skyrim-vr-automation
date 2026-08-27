# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\devbench-control\DevBenchControl.psm1') -Force

function Invoke-CocMcpRequest {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$Payload,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint `
        -Headers $Headers -Body ($Payload | ConvertTo-Json -Depth 50 -Compress) `
        -TimeoutSec $TimeoutSeconds
    return [pscustomobject]@{
        response = $response
        json = $response.Content | ConvertFrom-Json -Depth 80
    }
}

function Open-CocMcpSession {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    $baseHeaders = @{
        Accept = 'application/json, text/event-stream'
        'Content-Type' = 'application/json'
    }
    $initialize = Invoke-CocMcpRequest -Endpoint $Endpoint `
        -Headers $baseHeaders -TimeoutSeconds $TimeoutSeconds -Payload @{
            jsonrpc = '2.0'
            id = [DateTime]::UtcNow.Ticks
            method = 'initialize'
            params = @{
                protocolVersion = '2025-03-26'
                capabilities = @{}
                clientInfo = @{ name = 'CocStabilityControl'; version = '1.0' }
            }
        }
    $sessionHeader = $initialize.response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) {
        [string]$sessionHeader[0]
    } else {
        [string]$sessionHeader
    }
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        throw 'DevBench did not return an MCP session ID.'
    }

    $headers = @{
        Accept = 'application/json, text/event-stream'
        'Content-Type' = 'application/json'
        'Mcp-Session-Id' = $sessionId
    }
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Endpoint `
        -Headers $headers -TimeoutSec $TimeoutSeconds `
        -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' |
        Out-Null
    return [pscustomobject]@{ id = $sessionId; headers = $headers }
}

function Invoke-CocMcpTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][Collections.IDictionary]$Arguments,
        [pscustomobject]$Session,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    if ($null -eq $Session) {
        $Session = Open-CocMcpSession -Endpoint $Endpoint `
            -TimeoutSeconds $TimeoutSeconds
    }

    $call = Invoke-CocMcpRequest -Endpoint $Endpoint `
        -Headers $Session.headers -TimeoutSeconds $TimeoutSeconds -Payload @{
            jsonrpc = '2.0'
            id = [DateTime]::UtcNow.Ticks
            method = 'tools/call'
            params = @{ name = $Tool; arguments = $Arguments }
        }
    if ($call.json.PSObject.Properties['error']) {
        throw "DevBench tools/call failed: $($call.json.error | ConvertTo-Json -Compress)"
    }
    if ($call.json.result.PSObject.Properties['isError'] -and
        [bool]$call.json.result.isError) {
        $message = (@($call.json.result.content) | ForEach-Object text) -join "`n"
        throw "DevBench tool '$Tool' failed: $message"
    }

    $content = [Collections.Generic.List[object]]::new()
    foreach ($item in @($call.json.result.content)) {
        if ($item.type -eq 'text') {
            try { $content.Add(($item.text | ConvertFrom-Json -Depth 80)) }
            catch { $content.Add([string]$item.text) }
        } else {
            $content.Add($item)
        }
    }
    return [pscustomobject][ordered]@{
        tool = $Tool
        sessionId = $Session.id
        content = @($content)
        value = @($content | Select-Object -First 1)[0]
        rawResult = $call.json.result
    }
}

function New-CocMeasuredScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ProtocolConfig,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$OwnerId
    )

    $startCell = [string]$ProtocolConfig.startCellEditorId
    $interiorCell = [string]$ProtocolConfig.interiorCellEditorId
    if ($startCell -ne 'WindhelmExterior01' -or
        $interiorCell -ne 'WhiterunDragonsreach') {
        throw 'The protocol config does not describe the fixed COC route.'
    }
    $transitionCount = [int]$ProtocolConfig.transitionCount
    if ($transitionCount -ne 20) { throw 'The measured COC run must contain 20 transitions.' }

    $foveation = [ordered]@{
        foveatedVendorDispatch = [bool]$ProtocolConfig.foveation.foveatedVendorDispatch
        foveatedCenterArea = [double]$ProtocolConfig.foveation.foveatedCenterArea
        peripheryTAAEnable = [bool]$ProtocolConfig.foveation.peripheryTAAEnable
        peripheryTAACenterArea = [double]$ProtocolConfig.foveation.peripheryTAACenterArea
        peripheryTAAOuterScale = [double]$ProtocolConfig.foveation.peripheryTAAOuterScale
    }
    $steps = [Collections.Generic.List[object]]::new()
    $steps.Add([ordered]@{
        tool = 'communityshaders.renderscale'
        label = 'stress-reset'
        args = @{ action = 'reset'; expectedBuildId = $ExpectedBuildId }
    })
    $steps.Add([ordered]@{
        tool = 'communityshaders.renderscale'
        label = 'stress-start'
        args = @{ action = 'start'; expectedBuildId = $ExpectedBuildId }
    })

    for ($ordinal = 1; $ordinal -le $transitionCount; $ordinal++) {
        $cell = if (($ordinal % 2) -eq 1) { $interiorCell } else { $startCell }
        $transitionId = [uint64]$ordinal
        $dispatch = [ordered]@{
            action = 'qualification_dispatch'
            transitionId = $transitionId
            ownerId = $OwnerId
            expectedBuildId = $ExpectedBuildId
            cocCellEditorId = $cell
        }
        if ($ordinal -eq 1) { $dispatch.startPerformanceTelemetry = $true }

        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-begin"
            args = [ordered]@{
                action = 'qualification_begin'
                transitionId = $transitionId
                ownerId = $OwnerId
                expectedBuildId = $ExpectedBuildId
            }
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-dispatch"
            args = $dispatch
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-wait"
            args = [ordered]@{
                action = 'qualification_wait'
                transitionId = $transitionId
                ownerId = $OwnerId
                expectedBuildId = $ExpectedBuildId
                expectedCellEditorId = $cell
                foveation = $foveation
                timeoutMs = 10000
            }
        })
    }
    return [ordered]@{
        action = 'run'
        async = $true
        continueOnError = $false
        steps = @($steps)
    }
}

function Test-CocBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Results,
        [Parameter(Mandatory)][string]$ExpectedCell
    )

    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($name in @('state', 'scene', 'upscaling', 'renderscale', 'image')) {
        if (-not $Results.ContainsKey($name) -or $null -eq $Results[$name]) {
            $reasons.Add("baseline '$name' is incomplete")
        }
    }
    if ($reasons.Count -gt 0) {
        return [pscustomobject]@{ acceptable = $false; reasons = @($reasons) }
    }

    $state = $Results.state.value
    $scene = $Results.scene.value
    $upscaling = $Results.upscaling.value
    $renderScale = $Results.renderscale.value
    $actualCell = if ($scene.cell -is [string]) {
        [string]$scene.cell
    } else {
        [string]$scene.cell.editorId
    }
    if (-not [bool]$state.playerLoaded) { $reasons.Add('the player is not loaded') }
    if (-not [string]::Equals(
        $actualCell, $ExpectedCell, [StringComparison]::OrdinalIgnoreCase
    )) { $reasons.Add("the exact cell is '$actualCell'") }

    $stability = Test-DevBenchUpscalingStable `
        -UpscalingSnapshot $upscaling -RenderScaleStatus $renderScale
    foreach ($reason in @($stability.reasons)) { $reasons.Add([string]$reason) }
    $status = if ($renderScale.PSObject.Properties['status']) {
        $renderScale.status
    } else {
        $renderScale
    }
    $diagnostics = @(
        @{ name = 'stress'; property = 'session' },
        @{ name = 'CPU telemetry'; property = 'cpuPerformance' },
        @{ name = 'GPU telemetry'; property = 'gpuPerformance' }
    )
    foreach ($diagnostic in $diagnostics) {
        $property = $status.PSObject.Properties[$diagnostic.property]
        $activeProperty = if ($property -and $property.Value) {
            $property.Value.PSObject.Properties['active']
        } else {
            $null
        }
        if (-not $activeProperty) {
            $reasons.Add("$($diagnostic.name) ownership status is unavailable")
            continue
        }
        $diagnostic.active = [bool]$activeProperty.Value
        if ($diagnostic.active) {
            $reasons.Add("an unowned $($diagnostic.name) session is already active")
        }
    }
    return [pscustomobject][ordered]@{
        acceptable = $reasons.Count -eq 0
        reasons = @($reasons | Select-Object -Unique)
        actualCell = $actualCell
        stability = $stability
    }
}

Export-ModuleMember -Function Invoke-CocMcpTool, New-CocMeasuredScenario, Test-CocBaseline
