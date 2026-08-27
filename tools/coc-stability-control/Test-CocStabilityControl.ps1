# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'CocStabilityControl.psm1'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CocStabilityControl.ps1'
$configPath = Join-Path $PSScriptRoot 'stabilizer-targets.v1.json'
Import-Module $modulePath -Force

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 30
$scenario = New-CocMeasuredScenario -TargetConfig $config `
    -ExpectedBuildId ('a' * 64) -OwnerId 'test-owner'
$steps = @($scenario.steps)
$dispatches = @($steps | Where-Object label -like 'coc-*-dispatch')
$commands = @($steps | Where-Object label -like 'coc-*-command')
$waiters = @($steps | Where-Object label -like 'coc-*-wait')

if ($scenario.async -ne $true -or $scenario.continueOnError -ne $false) {
    throw 'The measured scenario is not one async fail-fast control batch.'
}
if ($steps.Count -ne 82 -or $dispatches.Count -ne 20 -or
    $commands.Count -ne 20 -or $waiters.Count -ne 20) {
    throw 'The measured scenario does not contain setup plus exactly 20 transitions.'
}
$telemetryDispatches = @($dispatches | Where-Object {
    $_.args.Contains('startPerformanceTelemetry') -and
    [bool]$_.args.startPerformanceTelemetry
})
if ($telemetryDispatches.Count -ne 1 -or
    -not [bool]$dispatches[0].args.startPerformanceTelemetry) {
    throw 'Only transition 1 may atomically start CPU and GPU telemetry.'
}
for ($index = 0; $index -lt 20; $index++) {
    $expected = if ((($index + 1) % 2) -eq 1) {
        'coc WhiterunDragonsreach'
    } else {
        'coc WindhelmExterior01'
    }
    if ([string]$commands[$index].args.command -ne $expected) {
        throw "Transition $($index + 1) has the wrong exact COC target."
    }
    if ([int]$waiters[$index].args.timeoutMs -ne 10000) {
        throw "Transition $($index + 1) does not use the fixed waiter deadline."
    }
}

$script = Get-Content -LiteralPath $scriptPath -Raw
foreach ($required in @(
    '[Diagnostics.Stopwatch]::GetTimestamp()',
    '[IO.FileMode]::CreateNew',
    "'baseline-complete'",
    "'deadline'",
    "-Tool 'communityshaders.menu'",
    "-Tool 'scenario'",
    'Start-ThreadJob',
    'CollectorStatePath'
)) {
    if (-not $script.Contains($required, [StringComparison]::Ordinal)) {
        throw "COC stability controller is missing: $required"
    }
}

[pscustomobject][ordered]@{
    ok = $true
    exactTransitions = 20
    atomicPerformanceOrigin = $true
    monotonicIndependentWatchdog = $true
    exactlyOnceDispatchClaim = $true
} | ConvertTo-Json
