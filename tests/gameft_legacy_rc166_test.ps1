#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/gameft-sw/LegacyRc166.psm1') -Force
$checks = 0
function Assert-LegacyTest([bool]$Condition, [string]$Message) {
    $script:checks++
    if (!$Condition) { throw $Message }
}
function Assert-LegacyRejected([scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-LegacyTest $rejected 'Invalid legacy evidence accepted'
}
$state = [pscustomobject]@{ pid = 123; vr = $true; playerLoaded = $true; frame = 11 }
$menus = [pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false }
Assert-LegacyTest (Test-LegacyRc166LoadBoundary $state $menus 123 10 $true) 'Fresh observed load rejected'
Assert-LegacyTest (!(Test-LegacyRc166LoadBoundary $state $menus 123 10 $false)) 'Prior world accepted'
Assert-LegacyTest (!(Test-LegacyRc166LoadBoundary $state $menus 123 11 $true)) 'Stale frame accepted'
foreach ($menu in @('Main Menu', 'Loading Menu', 'LoadingMenu')) {
    $menus.openMenus = @($menu)
    Assert-LegacyTest (!(Test-LegacyRc166LoadBoundary $state $menus 123 10 $true)) 'Loading/menu frame accepted'
}
$menus.openMenus = @()
$state.playerLoaded = $false
Assert-LegacyTest (!(Test-LegacyRc166LoadBoundary $state $menus 123 10 $true)) 'Unloaded player accepted'
$state.playerLoaded = 'true'
Assert-LegacyRejected { Test-LegacyRc166LoadBoundary $state $menus 123 10 $true }
$state.playerLoaded = $true
Assert-LegacyRejected { Test-LegacyRc166LoadBoundary $state $menus 124 10 $true }
$producer = [pscustomobject]@{ sourceCommit = '2eef86720e5c6a48e6fa9ad93506a1f2093d0f2f'; sourceDirty = $false; buildId = ('a' * 64) }
$payload = [pscustomobject]@{ producer = $producer }
Assert-LegacyRc166Producer $payload ('a' * 64)
Assert-LegacyRejected { Assert-LegacyRc166Producer $payload ('b' * 64) }
$producer.sourceCommit = ('0' * 40)
Assert-LegacyRejected { Assert-LegacyRc166Producer $payload }
$producer.sourceCommit = '2eef86720e5c6a48e6fa9ad93506a1f2093d0f2f'
$producer.sourceDirty = $true
Assert-LegacyRejected { Assert-LegacyRc166Producer $payload }
Write-Output "RC166 legacy boundary/identity: $checks checks passed"
