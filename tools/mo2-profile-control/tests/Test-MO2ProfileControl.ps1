# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2ProfileControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-profile-control-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $profile = Join-Path $fixture 'modlist.txt'
    $evidence = Join-Path $fixture 'evidence'
    $original = [Text.Encoding]::UTF8.GetBytes("#fixture`r`n+Exact Test Mod`r`n-Other Mod`r`n")
    [IO.File]::WriteAllBytes($profile, $original)
    $originalHash = (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash
    $fixtureProcessNames = @('MO2ProfileControlImpossibleFixtureProcess')

    $inspect = & $script inspect -ProfilePath $profile -ModName 'Exact Test Mod' -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $inspect.enabled) { throw 'Inspect did not report the enabled marker.' }

    $disabled = & $script disable -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory $evidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($disabled.enabled -or $disabled.sha256 -eq $originalHash) { throw 'Disable did not change exactly the marker state.' }

    $restored = & $script restore -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory $evidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $restored.enabled -or $restored.sha256 -ne $originalHash) { throw 'Restore did not reproduce the original hash.' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($profile))) { throw 'Restore was not byte-identical.' }

    [pscustomobject]@{ ok = $true; assertions = 4; restoredSha256 = $restored.sha256 } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
