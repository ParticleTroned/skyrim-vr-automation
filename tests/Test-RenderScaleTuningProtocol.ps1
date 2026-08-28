# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repositoryRoot 'skills\renderscale-tuning'
$pluginRoot = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\renderscale-tuning'
$sourceSkill = Join-Path $sourceRoot 'SKILL.md'
$sourceProtocol = Join-Path $sourceRoot 'references\protocol.md'
$pluginSkill = Join-Path $pluginRoot 'SKILL.md'
$pluginProtocol = Join-Path $pluginRoot 'references\protocol.md'

foreach ($pair in @(
    @($sourceSkill, $pluginSkill),
    @($sourceProtocol, $pluginProtocol)
)) {
    foreach ($path in $pair) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Render-scale tuning protocol file is missing: $path"
        }
    }
    if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
        throw 'Render-scale tuning source/package parity failed.'
    }
}

$skill = Get-Content -LiteralPath $sourceSkill -Raw
$protocol = Get-Content -LiteralPath $sourceProtocol -Raw

foreach ($required in @(
    'name: renderscale-tuning',
    'exact user command',
    '`renderscale-tuning acceptance`',
    '25-step matrix as part of this skill',
    'one positioning COC to `WhiterunDragonsreach`',
    'does not authorize a build',
    'VR FPS Stabilizer remains the sole owner',
    'Do not calculate, infer, rename, or substitute'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Render-scale tuning skill is missing: $required"
    }
}

foreach ($required in @(
    '`prepare_coc`',
    'FOV/TAA `0.3/0.3/0.7` fixture',
    '`coc WhiterunDragonsreach`',
    'Keep Tracy,',
    'DevBench CPU telemetry',
    'DevBench GPU telemetry',
    '`startPerformanceTelemetry: false`',
    '`timeoutMs: 30000`',
    '30 seconds is only its upper bound',
    'exactly three complete DLSS pairs',
    'currentPresentationProven',
    'currentPresentationGeneration',
    'replacementAdmissionBlocked',
    '`replacementAdmissionBlockReasons`',
    '`physicalMutationStarted` frame and QPC',
    'actual left-eye path and generation',
    'actual right-eye path and generation',
    'current, completed, and published publication generation',
    'published width and height versus expected width and height',
    'D3D device match and D3D context match',
    'shader-cache wait time and cache outcome',
    'SSS and SSGI prewarming time and outcome',
    'DLSS, FSR, and FSR4 preparation time and outcome',
    'request-to-prepared latency',
    'prepared-to-creator latency',
    'Never recreate `dimensionsMatch` with protocol-side math',
    'Classify each transition and every matrix row',
    'Run this section only for `renderscale-tuning acceptance`'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Render-scale tuning protocol is missing: $required"
    }
}

$ordered = @(
    'communityshaders.menu open',
    'CS-menu-origin render-scale `apply`',
    'Read one bounded pre-close status/event checkpoint',
    '`qualification_dispatch`',
    '`communityshaders.menu close`',
    '`qualification_wait`'
)
$prior = -1
foreach ($token in $ordered) {
    $index = $protocol.IndexOf($token, [StringComparison]::Ordinal)
    if ($index -le $prior) {
        throw "Menu-close transition ordering is missing or invalid at: $token"
    }
    $prior = $index
}

$matrixRows = @([regex]::Matches($protocol, '(?m)^\| (?:[1-9]|1[0-5]) \|'))
if ($matrixRows.Count -ne 15) {
    throw "Expected exactly 15 matrix rows, found $($matrixRows.Count)."
}
if ($protocol -match 'startPerformanceTelemetry:\s*true') {
    throw 'Correctness protocol must never start performance telemetry.'
}
foreach ($unsupported in @('external SteamVR', 'SteamVR frame-timing')) {
    if ($skill.Contains($unsupported, [StringComparison]::OrdinalIgnoreCase) -or
        $protocol.Contains($unsupported, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Protocol retains unsupported acceptance step: $unsupported"
    }
}

[pscustomobject][ordered]@{
    ok = $true
    trigger = 'renderscale-tuning'
    initialCell = 'WhiterunDragonsreach'
    primaryTransitions = 6
    matrixRows = 15
    performanceTelemetry = $false
    sourceAndPluginMatch = $true
} | ConvertTo-Json
