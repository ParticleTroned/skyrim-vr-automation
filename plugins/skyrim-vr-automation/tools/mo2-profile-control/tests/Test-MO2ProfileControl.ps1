# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2ProfileControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-profile-control-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $profile = Join-Path $fixture 'modlist.txt'
    $evidence = Join-Path $fixture 'evidence'
    $original = [Text.Encoding]::UTF8.GetBytes("#fixture`r`n+Exact Test Mod`r`n-Enable Test Mod`r`n-Other Mod`r`n")
    [IO.File]::WriteAllBytes($profile, $original)
    $originalHash = (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash
    $fixtureProcessNames = @('MO2ProfileControlImpossibleFixtureProcess')
    $mods = Join-Path $fixture 'mods'
    $newMod = Join-Path $mods 'New Test Mod'
    New-Item -ItemType Directory -Path $newMod -Force | Out-Null

    $registerEvidence = Join-Path $fixture 'register-evidence'
    $registered = & $script register -ProfilePath $profile -ModName 'New Test Mod' -ModDirectory $newMod -Placement After -RelativeToMod 'Exact Test Mod' -EvidenceDirectory $registerEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($registered.enabled -or $registered.marker -ne '-') { throw 'Register did not create one disabled marker.' }
    $registeredLines = Get-Content -LiteralPath $profile
    if ($registeredLines[2] -ne '-New Test Mod') { throw 'Register did not honor exact relative placement.' }
    $registerRestored = & $script restore -ProfilePath $profile -ModName 'New Test Mod' -EvidenceDirectory $registerEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($null -ne $registerRestored.marker -or (Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Register restore did not remove the owned marker byte-identically.' }

    $inspect = & $script inspect -ProfilePath $profile -ModName 'Exact Test Mod' -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $inspect.enabled) { throw 'Inspect did not report the enabled marker.' }
    $enableInspect = & $script inspect -ProfilePath $profile -ModName 'Enable Test Mod' -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($enableInspect.enabled) { throw 'Inspect did not report the disabled marker.' }

    $disabled = & $script disable -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory $evidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($disabled.enabled -or $disabled.sha256 -eq $originalHash) { throw 'Disable did not change exactly the marker state.' }

    $restored = & $script restore -ProfilePath $profile -ModName 'Exact Test Mod' -EvidenceDirectory $evidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $restored.enabled -or $restored.sha256 -ne $originalHash) { throw 'Restore did not reproduce the original hash.' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($profile))) { throw 'Restore was not byte-identical.' }

    $whatIfEvidence = Join-Path $fixture 'whatif-evidence'
    $null = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $whatIfEvidence -BlockingProcessNames $fixtureProcessNames -WhatIf
    if ((Get-FileHash -LiteralPath $profile -Algorithm SHA256).Hash -ne $originalHash) { throw 'Enable WhatIf changed the profile.' }
    if (Test-Path -LiteralPath $whatIfEvidence) { throw 'Enable WhatIf created evidence files.' }

    $enableEvidence = Join-Path $fixture 'enable-evidence'
    $enabled = & $script enable -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $enableEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if (-not $enabled.enabled -or $enabled.sha256 -eq $originalHash) { throw 'Enable did not change exactly the marker state.' }
    $receipt = Get-Content -LiteralPath (Join-Path $enableEvidence 'modlist-control.receipt.json') -Raw | ConvertFrom-Json
    if ($receipt.operation -ne 'enable') { throw 'Enable receipt did not record its operation.' }

    $enableRestored = & $script restore -ProfilePath $profile -ModName 'Enable Test Mod' -EvidenceDirectory $enableEvidence -BlockingProcessNames $fixtureProcessNames | ConvertFrom-Json
    if ($enableRestored.enabled -or $enableRestored.sha256 -ne $originalHash) { throw 'Enable restore did not reproduce the original marker state.' }
    if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$original, [byte[]][IO.File]::ReadAllBytes($profile))) { throw 'Enable restore was not byte-identical.' }

    [pscustomobject]@{ ok = $true; assertions = 14; restoredSha256 = $enableRestored.sha256 } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
