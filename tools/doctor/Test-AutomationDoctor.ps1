# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-doctor-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $target = Join-Path $fixture 'config\machine.local.json'
    $script = Join-Path $PSScriptRoot 'Invoke-SkyrimVRAutomationDoctor.ps1'
    $dry = & (Get-Process -Id $PID).Path -NoProfile -File $script init -UserConfigPath $target -WhatIf | ConvertFrom-Json
    if (-not $dry.ok -or $dry.state -ne 'dry-run' -or (Test-Path -LiteralPath $target)) { throw 'Doctor init dry-run failed.' }
    $created = (& (Get-Process -Id $PID).Path -NoProfile -File $script init -UserConfigPath $target | ConvertFrom-Json)
    if (-not $created.ok -or -not (Test-Path -LiteralPath $target)) { throw 'Doctor init did not create the target.' }
    $inspected = & (Get-Process -Id $PID).Path -NoProfile -File $script inspect -ConfigPath $target -UserConfigPath $target -NoExit | ConvertFrom-Json
    $fixtureCheck = @($inspected.checks | Where-Object name -eq 'verified-fixture-manifest')
    if ($fixtureCheck.Count -ne 1 -or $fixtureCheck[0].status -ne 'warn' -or [string]::IsNullOrWhiteSpace([string]$fixtureCheck[0].data.exampleManifestPath)) { throw 'Doctor did not report the configured verified-fixture manifest state.' }
    $second = & (Get-Process -Id $PID).Path -NoProfile -File $script init -UserConfigPath $target 2>&1
    if ($LASTEXITCODE -eq 0 -or (($second -join "`n") -notmatch 'not overwritten')) { throw 'Doctor init overwrote or did not reject an existing target.' }
    [pscustomobject]@{ ok = $true; target = $target } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
