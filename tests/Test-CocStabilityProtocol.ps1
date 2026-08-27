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
    'first operation an async',
    'waits exactly 10 seconds',
    'During that server wait',
    '"action":"prepare_coc"',
    'persisted: false',
    'startup-active VR FPS',
    'one parallel baseline bundle',
    'VR FPS Stabilizer exclusively owns',
    'continueOnError: true',
    'qualification_dispatch',
    '10-second deadline',
    'Do not split ordinary transitions into client round trips'
)) {
    Assert-Protocol $skill.Contains($requiredSkillText, [StringComparison]::Ordinal) `
        "COC skill is missing: $requiredSkillText"
}

foreach ($requiredProtocolText in @(
    '## Fast start-cell establishment',
    'immediately queue one',
    'Queue that deadline before any identity',
    'concurrently read the runtime',
    'never postpone the scheduled COC',
    '## One-time post-load fixture gate',
    '"action": "prepare_coc"',
    'one parallel baseline bundle',
    'Parallelism changes only latency,',
    'one server setup scenario',
    'one async server-side scenario',
    '`continueOnError: true`',
    'fixed batch terminate',
    '`dispatched: true`',
    '`ContractPublished` is a transient',
    'last completed both-eye compositor frame',
    '`gpu_performance_stop` with the captured `expectedStartFrame`',
    'Call it exactly once; do not repeat it',
    'Never call',
    '`communityshaders.renderscale` with `apply`'
)) {
    Assert-Protocol $protocol.Contains($requiredProtocolText, [StringComparison]::Ordinal) `
        "COC protocol is missing: $requiredProtocolText"
}

$startPosition = $protocol.IndexOf('## Fast start-cell establishment', [StringComparison]::Ordinal)
$preflightPosition = $protocol.IndexOf('## One-time post-load fixture gate', [StringComparison]::Ordinal)
$baselinePosition = $protocol.IndexOf('## Baseline and profile fixture', [StringComparison]::Ordinal)
$diagnosticPosition = $protocol.IndexOf('## Diagnostic sessions', [StringComparison]::Ordinal)
$assayPosition = $protocol.IndexOf('## Deadline-driven measured assay', [StringComparison]::Ordinal)
Assert-Protocol ($startPosition -ge 0 -and $startPosition -lt $preflightPosition) `
    'The timed Windhelm start must precede the post-load fixture gate.'
Assert-Protocol ($preflightPosition -lt $baselinePosition -and
    $baselinePosition -lt $diagnosticPosition -and
    $diagnosticPosition -lt $assayPosition) `
    'Gate, parallel baseline, diagnostics, and measured assay are out of order.'

$assayText = $protocol.Substring($assayPosition)
Assert-Protocol (-not $assayText.Contains('prepare_coc', [StringComparison]::Ordinal)) `
    'The measured assay must not invoke or recheck prepare_coc.'
Assert-Protocol (([regex]::Matches($protocol, '"action": "prepare_coc"')).Count -eq 1) `
    'The protocol must contain exactly one prepare_coc invocation.'
Assert-Protocol (-not $protocol.Contains('continueOnError: false', [StringComparison]::Ordinal)) `
    'The anomaly-accumulating batch must not advertise fail-fast execution.'
Assert-Protocol (([regex]::Matches(
    $protocol.Substring($startPosition, $preflightPosition - $startPosition),
    'coc WindhelmExterior01'
)).Count -eq 1) 'The timed start section must dispatch exactly one Windhelm COC.'

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
    timedStartQueuedFirst = $true
    parallelPreflight = $true
    anomalyAccumulation = $true
    fidelityPredicatePreserved = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
