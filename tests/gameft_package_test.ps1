#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$directory = Join-Path $root 'tools/gameft-sw'
Import-Module (Join-Path $directory 'GameFtStackWait.psm1') -Force
$checks = 0
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
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('gameft-pins-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
foreach ($name in $pins.Keys) { Copy-Item -LiteralPath (Join-Path $directory "protocol/$name") -Destination $fixture }
Add-Content -LiteralPath (Join-Path $fixture 'Invoke-SaveLoadTimingV2.ps1') -Value '# changed fixture'
$rejected = $false
try { Assert-GameFtScripts $fixture | Out-Null } catch { $rejected = $true }
if (!$rejected) { throw 'Changed protocol was accepted.' }
$checks++
Write-Output "gameft package: $checks checks passed; fixture retained at $fixture"
