# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2WorkspaceControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-workspace-control-' + [guid]::NewGuid().ToString('N'))
try {
    $mo2 = Join-Path $fixture 'MO2'; $profiles = Join-Path $mo2 'profiles'; $mods = Join-Path $mo2 'mods'
    $source = Join-Path $profiles 'Mad God Stable'; $loaderMod = Join-Path $mods 'Loader'; $sessions = Join-Path $fixture 'sessions'
    foreach ($p in @($source, (Join-Path $source 'saves'), $loaderMod, (Join-Path $mo2 'overwrite'), (Join-Path $mo2 'rb'), $sessions, (Join-Path $fixture 'archive'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    '+Loader' | Set-Content -LiteralPath (Join-Path $source 'modlist.txt') -Encoding utf8
    '*Skyrim.esm' | Set-Content -LiteralPath (Join-Path $source 'plugins.txt') -Encoding utf8
    'do-not-copy' | Set-Content -LiteralPath (Join-Path $source 'saves\unknown.ess') -Encoding utf8
    $mo2Exe = Join-Path $mo2 'ModOrganizer.exe'; $loader = Join-Path $loaderMod 'loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null; New-Item -ItemType File -Path $loader -Force | Out-Null
    $ini = Join-Path $mo2 'ModOrganizer.ini'
    "[General]`nselected_profile=@ByteArray(Codex)`n[customExecutables]`n1\title=@ByteArray(Test)`n1\binary=@ByteArray($loader)`n1\workingDirectory=@ByteArray($fixture)" | Set-Content -LiteralPath $ini -Encoding utf8
    $configPath = Join-Path $fixture 'config.json'; $lock = Join-Path $sessions 'lock.json'
    [ordered]@{
        contractVersion='0.4.0'; machine='fixture'; mo2=[ordered]@{root=$mo2;executable=$mo2Exe;ini=$ini;profilesDirectory=$profiles;modsDirectory=$mods;overwriteDirectory=(Join-Path $mo2 'overwrite');logsDirectory=(Join-Path $mo2 'logs');rootBuilderDefinitions=@();rootBuilderDataDirectory=(Join-Path $mo2 'rb');processNames=@('WorkspaceImpossibleMO2');gameProcessNames=@('WorkspaceImpossibleGame');runtimeProcessNames=@()};
        defaults=[ordered]@{profile='Mad God Stable';testProfileSource='Mad God Stable';executable='Test'};storage=[ordered]@{sessionStaging=$sessions;archive=(Join-Path $fixture 'archive')};limits=[ordered]@{maxEnumeratedFiles=100;overwriteWarningFiles=10;overwriteBlockFiles=50;overwriteWarningBytes=1024;overwriteBlockBytes=4096;launchPendingGraceSeconds=30};session=[ordered]@{lockFile=$lock}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'mo2-control\MO2Control.psm1') -Force
    $config = Read-MO2ControlConfig -ConfigPath $configPath
    $access = Invoke-MO2RequestAccess -Config $config -Label fixture; $accessId = [string]$access.data.access.accessId
    $created = & $entry create -ConfigPath $configPath -AccessId $accessId -Label weather -SavePolicy FreshGame -Confirm:$false | ConvertFrom-Json
    if (-not $created.ok -or $created.state -ne 'workspace-ready') { throw 'Workspace creation failed.' }
    if (Test-Path -LiteralPath (Join-Path $created.data.profilePath 'saves\unknown.ess')) { throw 'Workspace inherited an unknown save.' }
    $newMod = Join-Path $mods 'Owned Test Mod'; New-Item -ItemType Directory -Path $newMod -Force | Out-Null
    $registered = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -ModName 'Owned Test Mod' -ModDirectory $newMod -Placement After -RelativeToMod Loader -Confirm:$false | ConvertFrom-Json
    if (-not $registered.ok -or $registered.data.registration.marker -ne '-') { throw "Owned mod registration failed: $($registered | ConvertTo-Json -Depth 8 -Compress)" }
    $preexisting = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -ModName Loader -ModDirectory $loaderMod -NoExit -Confirm:$false | ConvertFrom-Json
    if ($preexisting.ok) { throw 'Workspace claimed a pre-existing mod.' }
    $released = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -CleanupOwnedMods -Confirm:$false | ConvertFrom-Json
    if (-not $released.ok -or (Test-Path -LiteralPath $created.data.profilePath) -or (Test-Path -LiteralPath $newMod)) { throw 'Workspace cleanup did not remove only its owned artifacts.' }
    if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $loaderMod)) { throw 'Workspace cleanup damaged stable state.' }
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    if (-not $releasedAccess.ok) { throw 'Access release failed.' }
    [pscustomobject]@{ok=$true; assertions=8; workspaceId=$created.data.workspaceId} | ConvertTo-Json
}
finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
