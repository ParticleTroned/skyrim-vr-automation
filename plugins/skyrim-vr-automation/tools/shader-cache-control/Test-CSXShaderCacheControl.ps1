[CmdletBinding()]
param()

Set-StrictMode -Version Latest
# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()

function Assert-Test([bool]$Condition, [string]$Message) {
    if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('csx-shader-cache-test-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Test root escaped the temporary directory: $resolvedTestRoot"
}

try {
    $reference = Join-Path $resolvedTestRoot 'reference'
    $candidate = Join-Path $resolvedTestRoot 'candidate'
    $output = Join-Path $resolvedTestRoot 'output'
    New-Item -ItemType Directory -Path $reference, $candidate -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $reference 'Lighting'), (Join-Path $candidate 'Lighting') -Force | Out-Null

    [IO.File]::WriteAllBytes((Join-Path $reference 'same.bin'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $candidate 'same.bin'), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $reference 'Lighting\changed.bin'), [byte[]](1, 2, 3, 4))
    [IO.File]::WriteAllBytes((Join-Path $candidate 'Lighting\changed.bin'), [byte[]](1, 2))
    [IO.File]::WriteAllBytes((Join-Path $reference 'only-reference.bin'), [byte[]](5, 6, 7))
    [IO.File]::WriteAllBytes((Join-Path $candidate 'only-candidate.bin'), [byte[]](8, 9, 10, 11, 12))

    $compare = Join-Path $PSScriptRoot 'Compare-CSXShaderCache.ps1'
    $result = & $compare -ReferencePath $reference -CandidatePath $candidate -OutputDirectory $output -ReferenceLabel enabled -CandidateLabel unloaded | ConvertFrom-Json
    $comparison = $result.summary.comparison
    Assert-Test ($result.ok -and (Test-Path -LiteralPath $result.csvPath -PathType Leaf)) 'comparison writes all outputs'
    Assert-Test ([int]$comparison.identicalFiles -eq 1) 'identical content is recognized by hash'
    Assert-Test ([int]$comparison.changedFiles -eq 1) 'same relative path with changed content is reported'
    Assert-Test ([int]$comparison.onlyReferenceFiles -eq 1 -and [int]$comparison.onlyCandidateFiles -eq 1) 'exclusive files are counted in both directions'
    Assert-Test ([long]$comparison.candidateByteDelta -eq 0) 'total byte delta is exact'
    $lighting = @($comparison.differenceGroups | Where-Object { $_.topLevel -eq 'Lighting' -and $_.status -eq 'changed' })[0]
    Assert-Test ([int]$lighting.files -eq 1 -and [long]$lighting.byteDelta -eq -2) 'top-level difference group includes byte delta'

    $transaction = Join-Path $PSScriptRoot 'Invoke-CSXShaderCacheTransaction.ps1'
    $liveCache = Join-Path $resolvedTestRoot 'live\ShaderCache'
    $evidence = Join-Path $resolvedTestRoot 'transaction'
    New-Item -ItemType Directory -Path $liveCache -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'baseline.bin'), [byte[]](1, 4, 9))
    Set-Content -LiteralPath (Join-Path $liveCache 'Info.ini') -Value @('[Cache]', 'ShaderCacheABI = snapshot-abi') -Encoding utf8
    $snap = & $transaction snapshot -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test ($snap.ok -and (Test-Path -LiteralPath $snap.data.receiptPath -PathType Leaf)) 'transaction snapshots an exact cache with a receipt'
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'baseline.bin'), [byte[]](2, 5, 10))
    [IO.File]::WriteAllBytes((Join-Path $liveCache 'new.bin'), [byte[]](7, 8))
    $different = & $transaction verify -CachePath $liveCache -EvidenceDirectory $evidence -NoExit | ConvertFrom-Json
    Assert-Test (-not $different.ok -and -not $different.data.matches) 'transaction verification detects physical cache mutation'
    $restore = & $transaction restore -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    $verified = & $transaction verify -CachePath $liveCache -EvidenceDirectory $evidence -NoExit | ConvertFrom-Json
    Assert-Test ($restore.ok -and $verified.ok -and $verified.data.matches) 'transaction restores and verifies the exact baseline'
    Assert-Test (Test-Path -LiteralPath $restore.data.displacedPath -PathType Container) 'transaction retains the displaced cache tree'

    'rollback-original' | Set-Content -LiteralPath (Join-Path $liveCache 'rollback.txt') -Encoding utf8
    $rollbackOriginal = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    $failedRestore = & $transaction restore -CachePath $liveCache -EvidenceDirectory $evidence -BlockingProcessNames @('fixture-process-that-does-not-exist') -InternalTestFailurePoint restore-after-activate -Confirm:$false -NoExit | ConvertFrom-Json
    $rollbackAfter = & $transaction inspect -CachePath $liveCache -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedRestore.ok -and $failedRestore.errors[0] -match 'exact original cache was restored') 'restore failure reports verified rollback rather than success'
    Assert-Test ($rollbackAfter.data.treeSha256 -eq $rollbackOriginal.data.treeSha256) 'restore failure removes the uncommitted replacement and restores the exact displaced tree'
    Remove-Item -LiteralPath (Join-Path $liveCache 'rollback.txt') -Force

    $snapshotSeed = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence `
        -SourceCachePath (Join-Path $evidence 'cache.before') -ExpectedSourceTreeSha256 $snap.data.inventory.treeSha256 `
        -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test ($snapshotSeed.ok) 'transaction accepts its receipt-owned cache.before snapshot as a seed source'

    $seedSource = Join-Path $resolvedTestRoot 'seed\CompatibleBaseline'
    New-Item -ItemType Directory -Path $seedSource -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $seedSource 'Info.ini') -Value @('[Cache]', 'ShaderCacheABI = old-abi', '', '[Feature]', 'Enabled = true', 'Version = 1-0-0') -Encoding utf8
    [IO.File]::WriteAllBytes((Join-Path $seedSource 'seed.bin'), [byte[]](11, 12, 13))
    $seedInventory = & $transaction inspect -CachePath $seedSource -NoExit | ConvertFrom-Json
    $seed = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence -SourceCachePath $seedSource `
        -ExpectedSourceTreeSha256 $seedInventory.data.treeSha256 -ShaderCacheAbiOverride 'new-abi' `
        -CompatibilityReason 'Fixture proves a compatible scheduling-only contract change.' `
        -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test ($seed.ok -and (Test-Path -LiteralPath $seed.data.seedReceiptPath -PathType Leaf)) 'transaction seeds a verified arbitrarily named source cache with a receipt'
    if (-not $seed.ok) { throw "Seed fixture failed: $($seed.errors -join '; ')" }
    Assert-Test ((Get-Content -LiteralPath (Join-Path $liveCache 'Info.ini') -Raw) -match 'ShaderCacheABI\s*=\s*new-abi') 'seed records the explicit compatible ABI override in Info.ini'
    Assert-Test (Test-Path -LiteralPath $seed.data.displacedPath -PathType Container) 'seed retains the displaced cache tree'
    $wrongHash = & $transaction seed -CachePath $liveCache -EvidenceDirectory $evidence -SourceCachePath $seedSource `
        -ExpectedSourceTreeSha256 ('0' * 64) -BlockingProcessNames @('fixture-process-that-does-not-exist') -Confirm:$false -NoExit | ConvertFrom-Json
    Assert-Test (-not $wrongHash.ok -and $wrongHash.errors[0] -match 'hash mismatch') 'seed rejects a source whose exact tree hash is not the approved identity'

    $mods = Join-Path $resolvedTestRoot 'mods'
    $profile = Join-Path $resolvedTestRoot 'modlist.txt'
    New-Item -ItemType Directory -Path (Join-Path $mods 'Enabled Cache\ShaderCache'), (Join-Path $mods 'Disabled Cache\ShaderCache') -Force | Out-Null
    Set-Content -LiteralPath $profile -Value @('+Enabled Cache', '-Disabled Cache') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $mods 'Enabled Cache\Info.ini') -Value @('[Feature]', 'Version=1.2.3') -Encoding utf8
    $providers = & $transaction providers -ProfilePath $profile -ModsPath $mods -DeepInventory -NoExit | ConvertFrom-Json
    Assert-Test ($providers.ok -and $providers.data.providers.Count -eq 2) 'provider inventory finds enabled and disabled physical cache providers'
    Assert-Test ($providers.data.enabledProviders -eq 1 -and $providers.data.disabledProviders -eq 1) 'provider inventory preserves exact MO2 marker state'

    $dllRelativePath = 'SKSE\Plugins\CommunityShaders.dll'
    New-Item -ItemType Directory -Path (Join-Path $mods 'Enabled Cache\SKSE\Plugins'), (Join-Path $mods 'Disabled Cache\SKSE\Plugins') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $mods "Enabled Cache\$dllRelativePath"), [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes((Join-Path $mods "Disabled Cache\$dllRelativePath"), [byte[]](4, 5, 6))
    $fileProviders = & $transaction providers -ProfilePath $profile -ModsPath $mods -RelativeCachePath $dllRelativePath -DeepInventory -NoExit | ConvertFrom-Json
    Assert-Test ($fileProviders.ok -and $fileProviders.data.providers.Count -eq 2) 'provider inventory supports an exact relative file'
    Assert-Test ($fileProviders.data.effectiveWinnerAmongEnabledMods.modName -eq 'Enabled Cache') 'provider inventory identifies the enabled loose-file winner'
    Assert-Test ($fileProviders.data.providers[0].providerType -eq 'file' -and $fileProviders.data.providers[0].inventory.files -eq 1) 'file provider inventory includes its physical hash record'
}
finally {
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

[pscustomobject][ordered]@{
    ok = $failures.Count -eq 0
    passed = $passes.Count
    failed = $failures.Count
    passes = @($passes)
    failures = @($failures)
} | ConvertTo-Json -Depth 10

if ($failures.Count -gt 0) { exit 1 }
