# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$operationalRoot = Join-Path $repositoryRoot 'tools'
$forbidden = @(
    ('L:' + '\Codex'),
    ('D:' + '\Games\Skyrim\MadGod2'),
    ('Mark-' + 'SkyrimVR'),
    ('CS-OCU-' + 'Rationalisation')
)
$extensions = @('.ps1', '.psm1', '.md', '.json')
$violations = [System.Collections.Generic.List[object]]::new()

foreach ($file in Get-ChildItem -LiteralPath $operationalRoot -Recurse -File) {
    if ($file.FullName -like '*\.git\*' -or $file.Name -eq 'machine.local.json') { continue }
    if ($file.Extension -notin $extensions) { continue }
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($needle in $forbidden) {
        if ($content.Contains($needle, [StringComparison]::OrdinalIgnoreCase)) {
            $violations.Add([pscustomobject]@{
                file = [IO.Path]::GetRelativePath($repositoryRoot, $file.FullName)
                forbidden = $needle
            })
        }
    }
}

$result = [pscustomobject][ordered]@{
    ok = $violations.Count -eq 0
    checkedRoot = $repositoryRoot
    violations = @($violations)
}
$result | ConvertTo-Json -Depth 5
if (-not $result.ok) { exit 1 }
