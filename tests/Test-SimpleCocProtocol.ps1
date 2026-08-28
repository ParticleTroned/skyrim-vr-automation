# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repositoryRoot 'skills\simple-coc\SKILL.md'
$sourceProtocol = Join-Path $repositoryRoot 'skills\simple-coc\references\protocol.md'
$sourceForensics = Join-Path $repositoryRoot (
    'skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)
$pluginSkill = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\SKILL.md'
)
$pluginProtocol = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\references\protocol.md'
)
$pluginForensics = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)

foreach ($pair in @(
    @($sourceSkill, $pluginSkill),
    @($sourceProtocol, $pluginProtocol),
    @($sourceForensics, $pluginForensics)
)) {
    foreach ($path in $pair) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Simple COC protocol file is missing: $path"
        }
    }
    if ((Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash) {
        throw 'Simple COC package content is stale.'
    }
}

$skill = Get-Content -LiteralPath $sourceSkill -Raw
$protocol = Get-Content -LiteralPath $sourceProtocol -Raw
foreach ($required in @(
    'one concurrent',
    'refresh schemas, discover telemetry',
    'Do not serialize independent calls',
    'transition 1''s atomic dispatch remains their sole timing origin',
    '`persisted: false`',
    'developer/debug logging',
    'FOV/TAA `0.3/0.3/0.7`',
    'exclusive owner of DLSS and upscaling',
    'transition-filtered preparation events',
    'prepared-to-creator',
    'separate explicit command `frozen Ghidra`'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC skill is missing: $required"
    }
}

foreach ($required in @(
    '"action":"prepare_coc"',
    'bounded setup fan-out',
    'reset each supported lane',
    'Do not poll',
    'start stress, trace, lifetime, and probe',
    'one concurrent bounded fan-out',
    'run another discovery or reset cycle',
    'capture.requiresEnabled: true',
    '`contractMajor: 1`',
    'but omits only the required `frameCount`',
    '`invalid_field`',
    'stop before the',
    '`set_enabled`',
    '`enabled: true`',
    '`result.state: "running"`',
    'must abort the scenario before',
    'Never reinterpret exposed-but-',
    'Restore the profiler enabled state',
    '`developerMode.active: true`',
    'logging at `debug`',
    'foveated vendor dispatch enabled with center area `0.3`',
    'periphery TAA enabled with center area `0.3` and outer scale `0.7`',
    'must not save settings or change method, quality, preset',
    'begins only at transition 1''s atomic',
    '`status.preparation` trace',
    'request-to-prepared',
    'preparation availability',
    '20 preparation status',
    'scripts/Start-FrozenGhidra.ps1',
    'cryptographic producer identity',
    'programMatchesExpectation: true',
    'with `-pvr`'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC protocol is missing: $required"
    }
}

$forensics = Get-Content -LiteralPath $sourceForensics -Raw
foreach ($required in @(
    'Starting Ghidra requires an explicit user request',
    "RelativeCachePath = 'SKSE\Plugins\CommunityShaders.dll'",
    "'tools\build_provenance.py'",
    "'CSX-{0}-{1}'",
    'ProjectName = $projectName',
    'programMatchesExpectation'
)) {
    if (-not $forensics.Contains($required, [StringComparison]::Ordinal)) {
        throw "Frozen Ghidra helper is missing: $required"
    }
}

$bindPosition = $protocol.IndexOf(
    '## 1. Bind DevBench and the build',
    [StringComparison]::Ordinal
)
$preparePosition = $protocol.IndexOf(
    '"action":"prepare_coc"',
    [StringComparison]::Ordinal
)
$positioningPosition = $protocol.IndexOf(
    '## 2. Position at Windhelm',
    [StringComparison]::Ordinal
)
if ($bindPosition -lt 0 -or $preparePosition -le $bindPosition -or
    $positioningPosition -le $preparePosition) {
    throw 'Simple COC fixture setup is not inside the DevBench binding phase.'
}

[pscustomobject][ordered]@{
    ok = $true
    fixtureDuringBinding = $true
    debugLogging = $true
    runtimeOnly = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
