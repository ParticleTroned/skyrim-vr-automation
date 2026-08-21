# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$marketplacePath = Join-Path $repositoryRoot '.agents\plugins\marketplace.json'
$marketplace = Get-Content -LiteralPath $marketplacePath -Raw | ConvertFrom-Json
$entry = @($marketplace.plugins | Where-Object name -eq 'skyrim-vr-automation')
if ($entry.Count -ne 1) { throw 'Marketplace must contain exactly one skyrim-vr-automation entry.' }
$pluginRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $entry[0].source.path))
if (-not (Test-Path -LiteralPath (Join-Path $pluginRoot '.codex-plugin\plugin.json') -PathType Leaf)) { throw 'Marketplace plugin manifest is missing.' }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-distribution-' + [guid]::NewGuid().ToString('N'))
try {
    $rebuilt = Join-Path $fixture 'skyrim-vr-automation'
    $buildResult = & (Join-Path $repositoryRoot 'scripts\Build-CodexMarketplacePlugin.ps1') -OutputDirectory $rebuilt | ConvertFrom-Json
    if (-not $buildResult.ok) { throw 'Distribution builder failed.' }

    $publishedFiles = @(Get-ChildItem -LiteralPath $pluginRoot -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($pluginRoot, $_.FullName) } | Sort-Object)
    $rebuiltFiles = @(Get-ChildItem -LiteralPath $rebuilt -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($rebuilt, $_.FullName) } | Sort-Object)
    if (($publishedFiles -join "`n") -ne ($rebuiltFiles -join "`n")) { throw 'Committed marketplace package file set is stale.' }
    foreach ($relative in $rebuiltFiles) {
        $a = (Get-FileHash -LiteralPath (Join-Path $pluginRoot $relative) -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath (Join-Path $rebuilt $relative) -Algorithm SHA256).Hash
        if ($a -ne $b) { throw "Committed marketplace package is stale: $relative" }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $rebuilt '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    $sourceManifest = Get-Content -LiteralPath (Join-Path $repositoryRoot '.codex-plugin\plugin.json') -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'skyrim-vr-automation' -or $manifest.version -ne $sourceManifest.version) { throw 'Rebuilt plugin identity/version is incorrect.' }
    foreach ($skill in @('mo2-control', 'steamvr-null-hmd', 'devbench-control', 'profiler-control', 'shader-cache-control')) {
        if (-not (Test-Path -LiteralPath (Join-Path $rebuilt "skills\$skill\SKILL.md") -PathType Leaf)) { throw "Missing installed skill: $skill" }
    }
    if (@(Get-ChildItem -LiteralPath $rebuilt -Recurse -File -Filter machine.local.json).Count -ne 0) { throw 'Distribution contains machine.local.json.' }

    $simulatedCache = Join-Path $fixture "cache\skyrim-vr-automation\$($manifest.version)"
    New-Item -ItemType Directory -Path (Split-Path -Parent $simulatedCache) -Force | Out-Null
    Copy-Item -LiteralPath $rebuilt -Destination $simulatedCache -Recurse
    foreach ($entryPoint in @(
        'tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1',
        'tools\mo2-control\Invoke-MO2Control.ps1',
        'tools\steamvr-null-control\Invoke-SteamVRNullControl.ps1',
        'tools\devbench-control\Invoke-DevBenchControl.ps1',
        'tools\devbench-control\DevBenchControl.psm1',
        'tools\profiler-control\Measure-CSXProfiler.ps1',
        'tools\shader-cache-control\Compare-CSXShaderCache.ps1',
        'tools\shader-cache-control\Invoke-CSXShaderCacheTransaction.ps1',
        'tools\process-control\Invoke-BoundedProcess.ps1'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $simulatedCache $entryPoint) -PathType Leaf)) { throw "Installed entry point is missing: $entryPoint" }
    }

    [pscustomobject][ordered]@{ ok = $true; marketplace = $marketplace.name; pluginVersion = $manifest.version; files = $rebuiltFiles.Count; simulatedCache = $simulatedCache } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
