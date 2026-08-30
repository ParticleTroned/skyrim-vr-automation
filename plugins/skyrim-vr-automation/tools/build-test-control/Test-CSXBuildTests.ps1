# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('csx-build-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $fixture 'ScreenshotApiTests.exe') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $fixture 'not-a-test.exe') -Force | Out-Null
    $entry = Join-Path $PSScriptRoot 'Invoke-CSXBuildTests.ps1'
    $explicit = Join-Path $fixture 'ScreenshotApiTests.exe'
    $result = (& $entry -BuildDirectory $fixture -TestExecutablePath $explicit -DiscoveryOnly -NoExit | ConvertFrom-Json)
    $outside = Join-Path (Split-Path -Parent $fixture) ('OutsideTests-' + [guid]::NewGuid().ToString('N') + '.exe')
    New-Item -ItemType File -Path $outside -Force | Out-Null
    $outsideResult = (& $entry -BuildDirectory $fixture -TestExecutablePath $outside -DiscoveryOnly -NoExit | ConvertFrom-Json)
    $source = Get-Content -LiteralPath $entry -Raw
    $ok = $result.ok -and $result.route -eq 'discovery-only' -and $result.directTestExecutables.Count -eq 1 -and $result.directTestExecutables[0] -eq $explicit
    $ok = $ok -and -not $outsideResult.ok -and $outsideResult.errors[0] -match 'outside the approved build root'
    $ok = $ok -and $source -notmatch 'Get-ChildItem[^\r\n]*-Recurse' -and $source -match 'Invoke-BoundedProcess\.ps1'
    [pscustomobject][ordered]@{ ok = $ok; passed = if ($ok) { 3 } else { 0 }; failed = if ($ok) { 0 } else { 1 }; result = $result; outside = $outsideResult } | ConvertTo-Json -Depth 20
    if (-not $ok) { exit 1 }
    Remove-Item -LiteralPath $outside -Force
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
