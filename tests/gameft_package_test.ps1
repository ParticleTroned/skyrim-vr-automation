#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$checks = 0
foreach ($base in @($root, (Join-Path $root 'plugins/skyrim-vr-automation'))) {
    $directory = Join-Path $base 'tools/gameft-sw'
    Import-Module (Join-Path $directory 'GameFtStackWait.psm1') -Force
    foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File | Where-Object Extension -in '.ps1', '.psm1') {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        $checks++
    }
    $pins = Assert-GameFtScripts (Join-Path $directory 'protocol')
    if ($pins.Count -ne 3) { throw 'Incomplete saved protocol bundle.' }
    $checks++
}
foreach ($name in @('gameft-sw', 'gameft-sw-analysis')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root "tools/$name") -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1', '.py', '.json', '.md', '.wprp') {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
        $packaged = Join-Path $root "plugins/skyrim-vr-automation/$relative"
        if (!(Test-Path -LiteralPath $packaged -PathType Leaf) -or
            (Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath $packaged).Hash) {
            throw "Packaged gameft file is missing or differs from source: $relative"
        }
        $checks++
    }
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gameft-pins-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
foreach ($name in $pins.Keys) { Copy-Item -LiteralPath (Join-Path $directory "protocol/$name") -Destination $fixture }
Add-Content -LiteralPath (Join-Path $fixture 'Invoke-SaveLoadTimingV2.ps1') -Value '# changed fixture'
$rejected = $false
try { Assert-GameFtScripts $fixture | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'Changed protocol was accepted.' }
$checks++
Write-Output "gameft package: $checks checks passed; fixture retained at $fixture"
