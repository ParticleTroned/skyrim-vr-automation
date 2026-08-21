# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('bounded-process-test-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $fixture = Join-Path $root 'fixture.ps1'
    $state = Join-Path $root 'state.txt'
    @'
param([string]$StatePath)
if (-not (Test-Path -LiteralPath $StatePath)) {
    Set-Content -LiteralPath $StatePath -Value first
    [Console]::Error.WriteLine('compiler output.d.json: Permission denied')
    exit 5
}
Write-Output 'second attempt succeeded'
'@ | Set-Content -LiteralPath $fixture -Encoding utf8
    $tool = Join-Path $PSScriptRoot 'Invoke-BoundedProcess.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $result = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $fixture, '-StatePath', $state) -WorkingDirectory $root -EvidenceDirectory (Join-Path $root 'evidence') -NoExit | ConvertFrom-Json
    if (-not $result.ok -or $result.attemptsRun -ne 2 -or -not $result.retried) { throw 'Expected one classified retry followed by success.' }
    $nonRetry = & $tool -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 7') -WorkingDirectory $root -MaxAttempts 3 -NoExit | ConvertFrom-Json
    if ($nonRetry.ok -or $nonRetry.attemptsRun -ne 1) { throw 'Unclassified failures must not be retried.' }
    [pscustomobject][ordered]@{ ok = $true; assertions = 2; receipt = $result.attemptsRun } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
