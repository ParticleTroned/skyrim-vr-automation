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

    $mods = Join-Path $resolvedTestRoot 'mods'
    $profile = Join-Path $resolvedTestRoot 'modlist.txt'
    New-Item -ItemType Directory -Path (Join-Path $mods 'Enabled Cache\ShaderCache'), (Join-Path $mods 'Disabled Cache\ShaderCache') -Force | Out-Null
    Set-Content -LiteralPath $profile -Value @('+Enabled Cache', '-Disabled Cache') -Encoding utf8
    Set-Content -LiteralPath (Join-Path $mods 'Enabled Cache\Info.ini') -Value @('[Feature]', 'Version=1.2.3') -Encoding utf8
    $providers = & $transaction providers -ProfilePath $profile -ModsPath $mods -DeepInventory -NoExit | ConvertFrom-Json
    Assert-Test ($providers.ok -and $providers.data.providers.Count -eq 2) 'provider inventory finds enabled and disabled physical cache providers'
    Assert-Test ($providers.data.enabledProviders -eq 1 -and $providers.data.disabledProviders -eq 1) 'provider inventory preserves exact MO2 marker state'
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
