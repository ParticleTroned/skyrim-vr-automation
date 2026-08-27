# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkillPath = Join-Path $repositoryRoot 'skills\coc-stability\SKILL.md'
$sourceProtocolPath = Join-Path $repositoryRoot 'skills\coc-stability\references\protocol.md'
$pluginSkillPath = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\coc-stability\SKILL.md'
$pluginProtocolPath = Join-Path $repositoryRoot 'plugins\skyrim-vr-automation\skills\coc-stability\references\protocol.md'

function Assert-Protocol {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$skill = Get-Content -LiteralPath $sourceSkillPath -Raw
$protocol = Get-Content -LiteralPath $sourceProtocolPath -Raw

foreach ($requiredSkillText in @(
    'confirmed in-game',
    'one 10-second settle period',
    '`coc WindhelmExterior01`',
    'communityshaders.menu',
    '"action":"prepare_coc"',
    'exactly once',
    'persisted: false',
    'startup-active VR FPS',
    'exclusively owns every DLSS/upscaling change',
    'one GPU telemetry session',
    'Start each transition timer at its actual COC command',
    'absolute 10-second COC-to-result deadline',
    'completed_with_anomalies'
)) {
    Assert-Protocol $skill.Contains($requiredSkillText, [StringComparison]::Ordinal) `
        "COC skill is missing: $requiredSkillText"
}

foreach ($requiredProtocolText in @(
    '## Fast start-cell establishment',
    '## One-time post-load fixture gate',
    '## Baseline and profile fixture',
    '## Diagnostic sessions',
    '## Deadline-driven measured assay',
    '## Stability interpretation',
    '## Cleanup and final evaluation',
    'one 10-second settle period',
    'coc WindhelmExterior01',
    '"action": "prepare_coc"',
    'VR FPS Stabilizer exclusively owns all DLSS/upscaling changes',
    '`gpu_performance_reset` then `gpu_performance_start`',
    '`timeoutMs: 10000`',
    'The measured transition timer begins at the COC command',
    '`qualification_begin`, diagnostic setup',
    '`continueOnError: false`',
    '`ContractPublished` is a transient publication phase',
    'Do not require the two instantaneous current-eye frame fields',
    '`gpu_performance_stop` with the captured `expectedStartFrame`',
    '`completed_with_anomalies`'
)) {
    Assert-Protocol $protocol.Contains($requiredProtocolText, [StringComparison]::Ordinal) `
        "COC protocol is missing: $requiredProtocolText"
}

$startPosition = $protocol.IndexOf('## Fast start-cell establishment', [StringComparison]::Ordinal)
$fixturePosition = $protocol.IndexOf('## One-time post-load fixture gate', [StringComparison]::Ordinal)
$baselinePosition = $protocol.IndexOf('## Baseline and profile fixture', [StringComparison]::Ordinal)
$diagnosticsPosition = $protocol.IndexOf('## Diagnostic sessions', [StringComparison]::Ordinal)
$assayPosition = $protocol.IndexOf('## Deadline-driven measured assay', [StringComparison]::Ordinal)
$cleanupPosition = $protocol.IndexOf('## Cleanup and final evaluation', [StringComparison]::Ordinal)
Assert-Protocol ($startPosition -ge 0 -and $startPosition -lt $fixturePosition) `
    'The 10-second start-cell establishment must precede the post-load gate.'
Assert-Protocol ($fixturePosition -lt $baselinePosition -and $baselinePosition -lt $diagnosticsPosition) `
    'The post-load gate and baseline must precede diagnostic startup.'
Assert-Protocol ($diagnosticsPosition -lt $assayPosition -and $assayPosition -lt $cleanupPosition) `
    'Diagnostics, measured assay, and cleanup are out of order.'

$assayText = $protocol.Substring($assayPosition)
Assert-Protocol (-not $assayText.Contains('prepare_coc', [StringComparison]::Ordinal)) `
    'The measured assay must not invoke or recheck prepare_coc.'
Assert-Protocol (([regex]::Matches($protocol, '"action": "prepare_coc"')).Count -eq 1) `
    'The protocol must contain exactly one prepare_coc invocation.'
Assert-Protocol (-not $protocol.Contains(
        'If the waiter or current transition times out, stop',
        [StringComparison]::Ordinal)) `
    'The protocol still contains the obsolete fail-fast timeout rule.'
Assert-Protocol (-not $protocol.Contains(
        'Default transition deadline: 120 seconds',
        [StringComparison]::Ordinal)) `
    'The protocol still contains the obsolete 120-second transition deadline.'

$sourceSkillHash = (Get-FileHash -LiteralPath $sourceSkillPath -Algorithm SHA256).Hash
$pluginSkillHash = (Get-FileHash -LiteralPath $pluginSkillPath -Algorithm SHA256).Hash
$sourceProtocolHash = (Get-FileHash -LiteralPath $sourceProtocolPath -Algorithm SHA256).Hash
$pluginProtocolHash = (Get-FileHash -LiteralPath $pluginProtocolPath -Algorithm SHA256).Hash
Assert-Protocol ($sourceSkillHash -eq $pluginSkillHash) `
    'The packaged COC skill is stale.'
Assert-Protocol ($sourceProtocolHash -eq $pluginProtocolHash) `
    'The packaged COC protocol is stale.'

[pscustomobject][ordered]@{
    ok = $true
    prepareInvocations = 1
    startupSettleMs = 10000
    transitionDeadlineMs = 10000
    timingOrigin = 'coc_command'
    repeatedDuringAssay = $false
    continueOnAnomaly = $true
    gpuTelemetry = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
