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
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 20
    )

    $session = Open-CocMcpSession -Endpoint $Endpoint `
        -TimeoutSeconds $TimeoutSeconds
    $list = Invoke-CocMcpRequest -Endpoint $Endpoint `
        -Headers $session.headers -TimeoutSeconds $TimeoutSeconds -Payload @{
            jsonrpc = '2.0'
            id = [DateTime]::UtcNow.Ticks
            method = 'tools/list'
            params = @{}
        }
    if ($list.json.PSObject.Properties['error']) {
        throw "DevBench tools/list failed: $($list.json.error | ConvertTo-Json -Compress)"
    }
    if (@($list.json.result.tools | Where-Object name -eq $Tool).Count -ne 1) {
        throw "DevBench tool '$Tool' is missing or ambiguous."
    }

    $call = Invoke-CocMcpRequest -Endpoint $Endpoint `
        -Headers $session.headers -TimeoutSeconds $TimeoutSeconds -Payload @{
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
        sessionId = $session.id
        content = @($content)
        value = @($content | Select-Object -First 1)[0]
        rawResult = $call.json.result
    }
}

function Get-CocTarget {
    param(
        [Parameter(Mandatory)]$TargetConfig,
        [Parameter(Mandatory)][string]$Cell
    )

    $property = $TargetConfig.profiles.PSObject.Properties[$Cell]
    if (-not $property) { throw "No Stabilizer target is defined for '$Cell'." }
    $source = $property.Value
    $target = [ordered]@{
        method = [string]$source.method
        qualityMode = [int]$source.qualityMode
        renderScaleMode = [bool]$source.renderScaleMode
    }
    if ($source.PSObject.Properties['dlssProfile']) {
        $target.dlssProfile = [string]$source.dlssProfile
    }
    if ($source.PSObject.Properties['fsrRuntime']) {
        $target.fsrRuntime = [string]$source.fsrRuntime
    }
    return $target
}

function New-CocMeasuredScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TargetConfig,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$OwnerId
    )

    $startCell = [string]$TargetConfig.startCellEditorId
    $interiorCell = [string]$TargetConfig.interiorCellEditorId
    if ($startCell -ne 'WindhelmExterior01' -or
        $interiorCell -ne 'WhiterunDragonsreach') {
        throw 'The target fixture does not describe the fixed COC route.'
    }
    $transitionCount = [int]$TargetConfig.transitionCount
    if ($transitionCount -ne 20) { throw 'The measured COC run must contain 20 transitions.' }

    $foveation = [ordered]@{
        foveatedVendorDispatch = [bool]$TargetConfig.foveation.foveatedVendorDispatch
        foveatedCenterArea = [double]$TargetConfig.foveation.foveatedCenterArea
        peripheryTAAEnable = [bool]$TargetConfig.foveation.peripheryTAAEnable
        peripheryTAACenterArea = [double]$TargetConfig.foveation.peripheryTAACenterArea
        peripheryTAAOuterScale = [double]$TargetConfig.foveation.peripheryTAAOuterScale
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
            tool = 'console'
            label = "coc-$($ordinal.ToString('D2'))-command"
            args = @{ action = 'exec'; command = "coc $cell"; capture = $false }
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
                target = Get-CocTarget -TargetConfig $TargetConfig -Cell $cell
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
        [Parameter(Mandatory)][string]$ExpectedCell,
        [Parameter(Mandatory)]$TargetConfig
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
    $expectedProfile = $TargetConfig.profiles.PSObject.Properties[
        $ExpectedCell
    ].Value
    if ((Get-DevBenchNamedValue $stability.method) -ne
        (Get-DevBenchNamedValue $expectedProfile.method)) {
        $reasons.Add('the effective method differs from the Stabilizer fixture')
    }
    if ((Get-DevBenchNamedValue $stability.qualityMode) -ne
        (Get-DevBenchNamedValue $expectedProfile.qualityModeName)) {
        $reasons.Add('the effective quality mode differs from the Stabilizer fixture')
    }
    if ([bool]$stability.effectiveRenderScaleMode -ne
        [bool]$expectedProfile.renderScaleMode) {
        $reasons.Add('the effective render-scale mode differs from the Stabilizer fixture')
    }
    if ($expectedProfile.PSObject.Properties['dlssProfile'] -and
        (Get-DevBenchNamedValue $stability.dlssProfile) -ne
        (Get-DevBenchNamedValue $expectedProfile.dlssProfile)) {
        $reasons.Add('the effective DLSS profile differs from the Stabilizer fixture')
    }

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
