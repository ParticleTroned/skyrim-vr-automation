# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkillPath = Join-Path $repositoryRoot 'skills\coc-stability\SKILL.md'
$sourceProtocolPath = Join-Path $repositoryRoot (
    'skills\coc-stability\references\protocol.md'
)
$pluginSkillPath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\coc-stability\SKILL.md'
)
$pluginProtocolPath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\coc-stability\references\protocol.md'
)
$sourceEvidencePath = Join-Path $repositoryRoot (
    'tools\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
)
$pluginEvidencePath = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\tools\coc-evidence-control\Invoke-CocEvidenceControl.ps1'
)

function Assert-Protocol {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

$skill = Get-Content -LiteralPath $sourceSkillPath -Raw
$protocol = Get-Content -LiteralPath $sourceProtocolPath -Raw

foreach ($requiredSkillText in @(
    'Before asking the user to load Skyrim',
    'tools/ghidra-mcp-control.ps1',
    'managed, ready, session-owned',
    'harmless Ghidra MCP health/list call',
    'game-owned DevBench endpoint',
    'installed loopback controller',
    'coc-evidence-control inspect',
    'waits exactly 10 seconds',
    'During that server wait',
    '"action":"prepare_coc"',
    'one monotonic 10-second watchdog',
    'one parallel',
    'VR FPS Stabilizer exclusively owns',
    'startPerformanceTelemetry: true',
    'continueOnError: false',
    'actual failed tool step',
    'make no further main-thread calls'
)) {
    Assert-Protocol $skill.Contains(
        $requiredSkillText,
        [StringComparison]::Ordinal
    ) "COC skill is missing: $requiredSkillText"
}

foreach ($requiredProtocolText in @(
    '## Pre-session Codex and evidence readiness',
    'tools/ghidra-mcp-control.ps1',
    'listenerOwnedBySession: true',
    'exclusively owns the persistent headless',
    'DevBench is game-owned',
    'not required to be live before Skyrim starts',
    'installed `devbench-control` loopback route',
    'successful MCP call',
    'coc-evidence-control arm',
    '## Fast start-cell establishment',
    'immediately queue one',
    'Queue that deadline before identity',
    'never postpone the scheduled COC',
    '## One-time post-load fixture gate',
    '"action": "prepare_coc"',
    'This fixture receipt is the only hard pre-measurement gate',
    '## Bounded parallel baseline',
    'same orchestration cell',
    'when the watchdog reaches 10 seconds, start the assay',
    'not permission to delay or cancel',
    '## Atomic diagnostics and measured assay',
    'startPerformanceTelemetry: true',
    'Do not issue separate',
    'continueOnError: false',
    'normal tool receipts',
    'actual failed tool step abort',
    '## Hard control failure and immediate analysis',
    'issue no more console, menu, qualification',
    'safe to quit Skyrim only after',
    'gpu_performance_stop',
    'Call it exactly once',
    'Never call',
    'communityshaders.renderscale'
)) {
    Assert-Protocol $protocol.Contains(
        $requiredProtocolText,
        [StringComparison]::Ordinal
    ) "COC protocol is missing: $requiredProtocolText"
}

$readinessPosition = $protocol.IndexOf(
    '## Pre-session Codex and evidence readiness',
    [StringComparison]::Ordinal
)
$startPosition = $protocol.IndexOf(
    '## Fast start-cell establishment',
    [StringComparison]::Ordinal
)
$fixturePosition = $protocol.IndexOf(
    '## One-time post-load fixture gate',
    [StringComparison]::Ordinal
)
$baselinePosition = $protocol.IndexOf(
    '## Bounded parallel baseline',
    [StringComparison]::Ordinal
)
$assayPosition = $protocol.IndexOf(
    '## Atomic diagnostics and measured assay',
    [StringComparison]::Ordinal
)
$failurePosition = $protocol.IndexOf(
    '## Hard control failure and immediate analysis',
    [StringComparison]::Ordinal
)
Assert-Protocol (
    $readinessPosition -ge 0 -and
    $readinessPosition -lt $startPosition -and
    $startPosition -lt $fixturePosition -and
    $fixturePosition -lt $baselinePosition -and
    $baselinePosition -lt $assayPosition -and
    $assayPosition -lt $failurePosition
) 'Readiness, start, fixture, baseline, assay, and failure phases are out of order.'

$assayText = $protocol.Substring($assayPosition)
Assert-Protocol (-not $assayText.Contains(
    'prepare_coc',
    [StringComparison]::Ordinal
)) 'The measured assay must not invoke or recheck prepare_coc.'
Assert-Protocol (([regex]::Matches(
    $protocol,
    '"action": "prepare_coc"'
)).Count -eq 1) 'The protocol must contain exactly one prepare_coc invocation.'
Assert-Protocol (-not $protocol.Contains(
    'continueOnError: true',
    [StringComparison]::Ordinal
)) 'A hard control failure must abort later COC dispatches.'
Assert-Protocol (([regex]::Matches(
    $protocol.Substring(
        $startPosition,
        $fixturePosition - $startPosition
    ),
    'coc WindhelmExterior01'
)).Count -eq 1) 'The timed start must dispatch exactly one Windhelm COC.'

foreach ($pair in @(
    @($sourceSkillPath, $pluginSkillPath, 'COC skill'),
    @($sourceProtocolPath, $pluginProtocolPath, 'COC protocol'),
    @($sourceEvidencePath, $pluginEvidencePath, 'COC evidence controller')
)) {
    $sourceHash = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash
    $pluginHash = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash
    Assert-Protocol ($sourceHash -eq $pluginHash) "$($pair[2]) package is stale."
}

$manifest = Get-Content -LiteralPath (
    Join-Path $repositoryRoot 'toolset.manifest.json'
) -Raw | ConvertFrom-Json
$evidenceEntry = @($manifest.tools | Where-Object {
    $_.name -eq 'coc-evidence-control'
})
Assert-Protocol ($evidenceEntry.Count -eq 1) (
    'COC evidence controller registration is missing or ambiguous.'
)
Assert-Protocol (
    $evidenceEntry[0].entryPoint -eq
        'tools/coc-evidence-control/Invoke-CocEvidenceControl.ps1'
) 'COC evidence controller entry point is incorrect.'

[pscustomobject][ordered]@{
    ok = $true
    readinessBeforeLiveStart = $true
    timedStartQueuedFirst = $true
    boundedParallelBaseline = $true
    firstCocOwnsPerformanceOrigin = $true
    semanticAnomaliesContinue = $true
    hardControlFailuresAbort = $true
    fidelityPredicatePreserved = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
