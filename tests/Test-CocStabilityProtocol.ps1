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
    'Before any COC',
    'communityshaders.menu',
    '"action":"prepare_coc"',
    'exactly once',
    'persisted: false',
    'startup-active VR FPS',
    'monitor-first gate',
    'exclusive owner of upscaling profile changes',
    'Never guess it',
    'upscaling apply action',
    'Do not invoke `prepare_coc` again',
    'Do not add its settings to the per-transition waiter predicate'
)) {
    Assert-Protocol $skill.Contains($requiredSkillText, [StringComparison]::Ordinal) `
        "COC skill is missing: $requiredSkillText"
}

foreach ($requiredProtocolText in @(
    '## One-time pre-assay gate',
    '"action": "prepare_coc"',
    'before any COC',
    '`after.developerMode.active` is `true`',
    '`after.foveation.ready` is `true`',
    '`after.vrFpsStabilizer.activeForSession` is `true`',
    '`vr_fps_stabilizer_required`',
    'partial mutation',
    'activate or configure VR FPS Stabilizer and restart',
    'exclusive owner of upscaling profile changes',
    'Stabilizer-owned fixture',
    'Never guess a target',
    'does not authorize an upscaling mutation',
    'Do not call `prepare_coc`',
    'do not add these preflight facts to the per-transition waiter'
)) {
    Assert-Protocol $protocol.Contains($requiredProtocolText, [StringComparison]::Ordinal) `
        "COC protocol is missing: $requiredProtocolText"
}

$preflightPosition = $protocol.IndexOf('## One-time pre-assay gate', [StringComparison]::Ordinal)
$fixturePosition = $protocol.IndexOf('## Configured comparison fixture', [StringComparison]::Ordinal)
$assayPosition = $protocol.IndexOf('## Non-overlap invariant', [StringComparison]::Ordinal)
Assert-Protocol ($preflightPosition -ge 0 -and $preflightPosition -lt $fixturePosition) `
    'The one-time gate must precede fixture and start-cell handling.'
Assert-Protocol ($assayPosition -gt $fixturePosition) `
    'The measured assay section must follow the pre-assay fixture.'

$assayText = $protocol.Substring($assayPosition)
Assert-Protocol (-not $assayText.Contains('prepare_coc', [StringComparison]::Ordinal)) `
    'The measured assay must not invoke or recheck prepare_coc.'
Assert-Protocol (([regex]::Matches($protocol, '"action": "prepare_coc"')).Count -eq 1) `
    'The protocol must contain exactly one prepare_coc invocation.'
Assert-Protocol (-not $protocol.Contains('"action": "apply"', [StringComparison]::Ordinal)) `
    'The COC protocol must not contain an upscaling apply action.'
Assert-Protocol ($protocol.Contains('It validates the profile but does not', [StringComparison]::Ordinal)) `
    'The waiter target must be documented as validation, not mutation.'
Assert-Protocol ([regex]::IsMatch($protocol, 'read-only\s+assertion')) `
    'The waiter target must be a read-only profile assertion.'

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
    repeatedDuringAssay = $false
    sourceAndPluginMatch = $true
} | ConvertTo-Json
