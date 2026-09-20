# SPDX-License-Identifier: GPL-3.0-or-later
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $repositoryRoot 'skills/simple-csm-rs/scripts/New-SimpleCsmRsPlan.ps1'
$protocolPath = Join-Path $repositoryRoot 'tools/render-scale-qualification/protocol.v1.json'
$canonical = Get-Content -LiteralPath $protocolPath -Raw | ConvertFrom-Json -Depth 30
$before = (Get-FileHash -LiteralPath $protocolPath).Hash
$simpleCsmRsProtocol = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills/simple-csm-rs/references/protocol.md') -Raw
$simpleCsmRsSkill = Get-Content -LiteralPath (Join-Path $repositoryRoot 'skills/simple-csm-rs/SKILL.md') -Raw
function Assert-Test([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
Assert-Test $simpleCsmRsProtocol.Contains('startup budget is 60,000 ms') 'Startup budget is missing.'
Assert-Test $simpleCsmRsProtocol.Contains('continueOnError: true') 'Per-transition continuation policy is missing.'
Assert-Test $simpleCsmRsProtocol.Contains('complete matrix even when individual transitions fail') 'Failed-transition completion policy is missing.'
Assert-Test $simpleCsmRsProtocol.Contains('start the stress, CPU, GPU') 'Explicit CPU/GPU arm starts are missing.'
Assert-Test (!$simpleCsmRsSkill.Contains('prepare_coc')) 'The Simple CSM RS skill still requires prepare_coc.'
foreach ($adapter in @('nvidia', 'amd')) {
    foreach ($runtime in @('fsr3', 'fsr4')) {
        $plan = & $generator -Adapter $adapter -FsrRuntime $runtime | ConvertFrom-Json -Depth 30
        $expectedCount = if ($adapter -eq 'nvidia') { 43 } else { 42 }
        Assert-Test ($plan.transitionCount -eq $expectedCount) 'Expanded transition count changed.'
        Assert-Test ($plan.canonicalSha256 -ceq $before) 'Plan does not identify its source bytes.'
        Assert-Test ($plan.pacingMs -eq 5000 -and $plan.recoveryTimeoutMs -eq 30000) 'Timing changed.'
        Assert-Test ((@($plan.transitions.ordinal) -join ',') -eq ((1..$expectedCount) -join ',')) 'Non-unique/unordered transition IDs.'
        foreach ($source in $canonical.menuAssay.($adapter + 'Matrix')) {
            $legs = @($plan.transitions | Where-Object sourceOrdinal -EQ $source.ordinal)
            $expectedLegs = if ($source.qualityModeValue -eq 0) { 'native-aa' } else { 'off,on' }
            Assert-Test ((@($legs.leg) -join ',') -ceq $expectedLegs) 'Wrong OFF/ON order or native-AA expansion.'
            foreach ($leg in $legs) {
                Assert-Test ($leg.waitBeforeApplyMs -eq 5000) 'A leg lost its independent pacing wait.'
                Assert-Test ($leg.target.method -ceq $source.method -and $leg.target.qualityMode -ceq $source.qualityMode -and $leg.qualityModeValue -eq $source.qualityModeValue) 'Profile/quality changed during expansion.'
                Assert-Test ($leg.target.renderScaleMode -is [bool] -and $leg.target.renderScaleMode -eq ($leg.leg -eq 'on')) 'RS state differs from leg.'
                Assert-Test ($leg.target.fsrRuntime -ceq $runtime -and $leg.target.dlssProfile -ceq 'K') 'Provider preference or DLSS preset changed.'
            }
        }
    }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('simple-csm-rs-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    foreach ($case in @('future-schema', 'future-revision', 'bad-count', 'bad-ordinal', 'bad-quality', 'bad-rs', 'amd-dlss')) {
        $bad = Get-Content -LiteralPath $protocolPath -Raw | ConvertFrom-Json -Depth 30
        switch ($case) {
            'future-schema' { $bad.schema = 'future' }
            'future-revision' { $bad.protocolRevision = 999 }
            'bad-count' { $bad.menuAssay.amdMatrix = @($bad.menuAssay.amdMatrix | Select-Object -Skip 1) }
            'bad-ordinal' { $bad.menuAssay.amdMatrix[0].ordinal = 2 }
            'bad-quality' { $bad.menuAssay.amdMatrix[0].qualityMode = 'quality' }
            'bad-rs' { $bad.menuAssay.amdMatrix[0].renderScaleMode = $true }
            'amd-dlss' { $bad.menuAssay.amdMatrix[0].method = 'dlss' }
        }
        $bad | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $fixture -Encoding utf8
        $rejected = $false
        try { $null = & $generator -Adapter amd -FsrRuntime fsr3 -ProtocolPath $fixture } catch { $rejected = $true }
        Assert-Test $rejected "Malformed plan accepted: $case"
    }
} finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture } }
Assert-Test ((Get-FileHash -LiteralPath $protocolPath).Hash -ceq $before) 'Canonical qualification matrix was modified.'
foreach ($relative in @('SKILL.md', 'references/protocol.md', 'scripts/New-SimpleCsmRsPlan.ps1')) {
    $source = Join-Path $repositoryRoot "skills/simple-csm-rs/$relative"
    $packaged = Join-Path $repositoryRoot "plugins/skyrim-vr-automation/skills/simple-csm-rs/$relative"
    Assert-Test ((Get-FileHash -LiteralPath $source).Hash -ceq (Get-FileHash -LiteralPath $packaged).Hash) "Package mismatch: $relative"
}
[ordered]@{ ok=$true; protocol='simple-csm-rs'; nvidiaTransitions=43; amdTransitions=42; pacingMs=5000; malformedCasesRejected=7; canonicalUnchanged=$true; sourceAndPluginMatch=$true } | ConvertTo-Json
