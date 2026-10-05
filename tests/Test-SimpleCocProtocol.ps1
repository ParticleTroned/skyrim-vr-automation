# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repositoryRoot 'skills\simple-coc\SKILL.md'
$sourceProtocol = Join-Path $repositoryRoot 'skills\simple-coc\references\protocol.md'
$sourceDevBench = Join-Path $repositoryRoot 'skills\devbench-control\SKILL.md'
$sourceForensics = Join-Path $repositoryRoot (
    'skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)
$pluginSkill = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\SKILL.md'
)
$pluginProtocol = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\references\protocol.md'
)
$pluginDevBench = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\devbench-control\SKILL.md'
)
$pluginForensics = Join-Path $repositoryRoot (
    'plugins\skyrim-vr-automation\skills\simple-coc\scripts\Start-FrozenGhidra.ps1'
)

foreach ($pair in @(
    @($sourceSkill, $pluginSkill),
    @($sourceProtocol, $pluginProtocol),
    @($sourceDevBench, $pluginDevBench),
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
$devBench = Get-Content -LiteralPath $sourceDevBench -Raw
foreach ($required in @(
    'Choose exactly one live transport before the first live call',
    'mandatory and',
    'do not run the bundled controller''s `list`',
    'do not create or resolve a controller',
    'Never cross transports to perform a readiness wait',
    'do not start a controller availability'
)) {
    if (-not $devBench.Contains($required, [StringComparison]::Ordinal)) {
        throw "DevBench one-lane contract is missing: $required"
    }
}
foreach ($required in @(
    '`prepare_coc` exactly once as the first stateful call',
    'Before the unmeasured positioning COC',
    'Dispatch positioning immediately',
    'do not repeat successful verification',
    'invalid-request or stop-on-error probe',
    'After exact-cell positioning',
    'complete measurement',
    'one synchronous, fail-closed DevBench',
    'synchronous, fail-closed scenario',
    'read-only calls may run concurrently',
    'transition 1''s atomic dispatch remains their sole timing origin',
    '`persisted: false`',
    'developer/debug logging',
    'FOV/TAA `0.3/0.3/0.7`',
    'exclusive owner of DLSS and upscaling',
    'transition-filtered preparation events',
    'prepared-to-creator',
    'immutable numbered ledgers',
    'separate explicit command `frozen Ghidra`'
)) {
    if (-not $skill.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC skill is missing: $required"
    }
}

foreach ($required in @(
    '"action":"prepare_coc"',
    'as the first',
    'Only independent read-only calls may run concurrently',
    'one synchronous `scenario`',
    'stepsRun` equal to the submitted step count',
    '`dlss_trace_reset`',
    '`dlss_trace_start`',
    'partial transcript',
    'start-frame guard',
    'foreign-owned active lane stops setup',
    'reset receipts to show CPU and GPU',
    'do not issue another CPU/GPU reset',
    'never fan out `start`, `reset`, or `set_enabled` calls',
    'run another discovery or reset cycle',
    'exactly one live DevBench transport',
    'plugin-provided direct MCP tools are callable',
    'their exposed tool descriptions as the live schema inventory',
    'Do not run the bundled controller''s `list`',
    'switch transport lanes during the run',
    'Do not generate or edit task-local orchestration scripts',
    'do not open a bundled-controller session',
    'Do not perform any profiler readiness wait before positioning',
    '`-TimeoutSeconds 10`',
    '`-MaxTransientRetries 0`',
    'outer budget and return on its first successful receipt',
    'Do not repeat the positioning COC',
    'capture.requiresEnabled: true',
    '`contractMajor: 1`',
    'Reuse an already successful identity binding',
    'immediately dispatch the positioning COC',
    'Do not run a deliberate invalid-request or stop-on-error probe',
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
    'with `-pvr`',
    'Do not invent a PR number',
    'vr-render-scale-ledger-0001-history.csv',
    'State explicitly when no canonical ledger was updated.'
)) {
    if (-not $protocol.Contains($required, [StringComparison]::Ordinal)) {
        throw "Simple COC protocol is missing: $required"
    }
}
foreach ($forbidden in @(
    'stateful reset calls one at a time',
    'Require and preserve each receipt before the next stateful action',
    'but omits only the required `frameCount`',
    'After the negative proof passes',
    'preflight negative probe proved',
    'bounded setup fan-out',
    'reset CPU/GPU telemetry',
    'refresh the live schema inventory exactly once',
    "after the controller's short retry budget"
)) {
    if ($protocol.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Simple COC retains a redundant or concurrent setup rule: $forbidden"
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

$bindingSection = $protocol.Substring(
    $bindPosition,
    $positioningPosition - $bindPosition
)
foreach ($forbidden in @(
    'communityshaders.profiler_api',
    '`serviceReady`',
    'reset each supported telemetry lane'
)) {
    if ($bindingSection.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "Simple COC binding still gates positioning on measurement service: $forbidden"
    }
}
$measurementAdmissionPosition = $protocol.IndexOf(
    'complete this measurement-admission gate',
    [StringComparison]::Ordinal
)
if ($measurementAdmissionPosition -le $positioningPosition) {
    throw 'Simple COC measurement admission must follow positioning.'
}

$resetBatchPosition = $protocol.IndexOf(
    'After discovery, construct one synchronous `scenario`',
    [StringComparison]::Ordinal
)
$armBatchPosition = $protocol.IndexOf(
    'After validating the reset transcript, construct one synchronous `scenario`',
    [StringComparison]::Ordinal
)
$measuredPosition = $protocol.IndexOf(
    '## 4. Run the measured scenario',
    [StringComparison]::Ordinal
)
if ($resetBatchPosition -le $measurementAdmissionPosition -or
    $armBatchPosition -le $resetBatchPosition -or
    $measuredPosition -le $armBatchPosition) {
    throw 'Simple COC setup batches are not ordered before measured dispatch.'
}
foreach ($batch in @(
    @{ name = 'reset'; text = $protocol.Substring($resetBatchPosition, $armBatchPosition - $resetBatchPosition); actions = @('`reset`', '`cpu_performance_reset`', '`gpu_performance_reset`', '`dlss_trace_reset`', '`texture_lifetime_reset`', '`probe_reset`') },
    @{ name = 'arm'; text = $protocol.Substring($armBatchPosition, $measuredPosition - $armBatchPosition); actions = @('render-scale `start`', '`dlss_trace_start`', '`texture_lifetime_start`', '`probe_start`', '`set_enabled`') }
)) {
    $prior = -1
    foreach ($action in $batch.actions) {
        $position = $batch.text.IndexOf($action, [StringComparison]::Ordinal)
        if ($position -le $prior) {
            throw "Simple COC $($batch.name) batch omits or reorders $action."
        }
        $prior = $position
    }
}

[pscustomobject][ordered]@{
    ok = $true
    fixtureDuringBinding = $true
    debugLogging = $true
    runtimeOnly = $true
    sourceAndPluginMatch = $true
} | ConvertTo-Json
