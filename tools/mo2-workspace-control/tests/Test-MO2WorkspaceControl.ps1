# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param([switch]$DiscoveryOnly)

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2WorkspaceControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-workspace-control-' + [guid]::NewGuid().ToString('N'))
function Get-TestProfileFingerprint([string]$Path) {
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName)
        if ($relative -match '^(?i:saves)[\\/]') { continue }
        $records += [pscustomobject][ordered]@{ path = $relative; bytes = [long]$file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
    }
    $canonical = $records | ConvertTo-Json -Compress -Depth 4
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical)))
}
try {
    $mo2 = Join-Path $fixture 'MO2'; $profiles = Join-Path $mo2 'profiles'; $mods = Join-Path $mo2 'mods'
    $source = Join-Path $profiles 'Mad God Stable'; $loaderMod = Join-Path $mods 'Loader'; $sessions = Join-Path $fixture 'sessions'
    foreach ($p in @($source, (Join-Path $source 'saves'), $loaderMod, (Join-Path $loaderMod 'SKSE\Plugins'), (Join-Path $mo2 'overwrite'), (Join-Path $mo2 'rb'), $sessions, (Join-Path $fixture 'archive'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    '+Loader' | Set-Content -LiteralPath (Join-Path $source 'modlist.txt') -Encoding utf8
    '*Skyrim.esm' | Set-Content -LiteralPath (Join-Path $source 'plugins.txt') -Encoding utf8
    'do-not-copy' | Set-Content -LiteralPath (Join-Path $source 'saves\unknown.ess') -Encoding utf8
    'known-good-save' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.ess') -Encoding utf8
    'known-good-cosave' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.skse') -Encoding utf8
    'existing-provider' | Set-Content -LiteralPath (Join-Path $loaderMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    foreach ($cachePath in @(
        (Join-Path $mo2 'overwrite\ShaderCache'),
        (Join-Path $mo2 'overwrite\ShaderCache.Previous'),
        (Join-Path $mo2 'overwrite\Root\Data\ShaderCache.Swap')
    )) {
        New-Item -ItemType Directory -Path $cachePath -Force | Out-Null
        ('compiled-' + [IO.Path]::GetFileName($cachePath)) | Set-Content -LiteralPath (Join-Path $cachePath 'fixture.bin') -Encoding utf8
    }
    $mo2Exe = Join-Path $mo2 'ModOrganizer.exe'; $loader = Join-Path $loaderMod 'loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null; New-Item -ItemType File -Path $loader -Force | Out-Null
    $ini = Join-Path $mo2 'ModOrganizer.ini'
    [IO.File]::WriteAllText(
        $ini,
        "[General]`r`nselected_profile=@ByteArray(Codex)`r`n[customExecutables]`r`n1\title=@ByteArray(Test)`r`n1\binary=@ByteArray($loader)`r`n1\workingDirectory=@ByteArray($fixture)`r`n",
        [Text.UTF8Encoding]::new($false))
    $configPath = Join-Path $fixture 'config.json'; $lock = Join-Path $sessions 'lock.json'
    $fixtureManifestPath = Join-Path $fixture 'known-good-saves.json'
    $saveFiles = @('Save2_KnownGood.ess', 'Save2_KnownGood.skse') | ForEach-Object {
        $path = Join-Path $source (Join-Path 'saves' $_)
        [ordered]@{ relativePath = $_; bytes = [long](Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    [ordered]@{ contractVersion='1.0.0'; sourceProfile='Mad God Stable'; profileFingerprintSha256=(Get-TestProfileFingerprint $source); defaultFixtureId='interior'; fixtures=@([ordered]@{id='interior';label='Known-good interior';location='TestCell';loadName='Save2_KnownGood';files=$saveFiles}) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding utf8
    [ordered]@{
        contractVersion='0.4.0'; machine='fixture'; mo2=[ordered]@{root=$mo2;executable=$mo2Exe;ini=$ini;profilesDirectory=$profiles;modsDirectory=$mods;overwriteDirectory=(Join-Path $mo2 'overwrite');logsDirectory=(Join-Path $mo2 'logs');rootBuilderDefinitions=@();rootBuilderDataDirectory=(Join-Path $mo2 'rb');processNames=@('WorkspaceImpossibleMO2');gameProcessNames=@('WorkspaceImpossibleGame');runtimeProcessNames=@()};
        defaults=[ordered]@{profile='Mad God Stable';testProfileSource='Mad God Stable';newGameFixtureManifest=$fixtureManifestPath;executable='Test'};storage=[ordered]@{sessionStaging=$sessions;archive=(Join-Path $fixture 'archive')};limits=[ordered]@{maxEnumeratedFiles=100;overwriteWarningFiles=10;overwriteBlockFiles=50;overwriteWarningBytes=1024;overwriteBlockBytes=4096;launchPendingGraceSeconds=30};session=[ordered]@{lockFile=$lock}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'mo2-control\MO2Control.psm1') -Force
    $config = Read-MO2ControlConfig -ConfigPath $configPath
    $access = Invoke-MO2RequestAccess -Config $config -Label fixture; $accessId = [string]$access.data.access.accessId
    $fixtureStatusRaw = & $entry fixture-status -ConfigPath $configPath -Compact
    if ($fixtureStatusRaw -match "`r|`n") { throw 'Compact workspace output was not one line.' }
    $fixtureStatus = $fixtureStatusRaw | ConvertFrom-Json
    if (-not $fixtureStatus.ok -or $fixtureStatus.state -ne 'fixture-valid') { throw 'Fixture status did not validate the original manifest.' }
    if (-not $fixtureStatus.data.approval.reusableApprovalEligible -or @($fixtureStatus.data.approval.reusablePrefix).Count -ne 6 -or $fixtureStatus.data.approval.reusablePrefix[4] -ne [IO.Path]::GetFullPath($entry) -or $fixtureStatus.data.approval.reusablePrefix[5] -ne 'fixture-status') { throw 'Fixture status did not expose its exact reusable approval prefix.' }
    $unconfiguredPath = Join-Path $fixture 'config-no-fixture.json'
    $unconfigured = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $unconfigured.defaults.PSObject.Properties.Remove('newGameFixtureManifest')
    $unconfigured | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $unconfiguredPath -Encoding utf8
    $unconfiguredStatus = & $entry fixture-status -ConfigPath $unconfiguredPath -Compact | ConvertFrom-Json
    if (-not $unconfiguredStatus.ok -or $unconfiguredStatus.state -ne 'fixture-not-configured' -or @($unconfiguredStatus.data.guidance).Count -lt 3 -or -not (Test-Path -LiteralPath $unconfiguredStatus.data.exampleManifestPath -PathType Leaf)) { throw 'Fixture discovery did not explain an unconfigured manifest.' }
    $missingPath = Join-Path $fixture 'config-missing-fixture.json'
    $unconfigured.defaults | Add-Member -NotePropertyName newGameFixtureManifest -NotePropertyValue (Join-Path $fixture 'missing.json')
    $unconfigured | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $missingPath -Encoding utf8
    $missingStatus = & $entry fixture-status -ConfigPath $missingPath -Compact | ConvertFrom-Json
    if (-not $missingStatus.ok -or $missingStatus.state -ne 'fixture-manifest-missing' -or -not $missingStatus.data.configured -or $missingStatus.data.manifestExists) { throw 'Fixture discovery did not distinguish a configured missing manifest.' }
    if ($DiscoveryOnly) {
        $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
        if (-not $releasedAccess.ok) { throw 'Discovery-only access release failed.' }
        [pscustomobject]@{ ok = $true; assertions = 2; mode = 'discovery-only' } | ConvertTo-Json
        return
    }
    $blockedCreate = & $entry create -ConfigPath $configPath -AccessId $accessId -Label blocked-by-cache -SavePolicy FreshGame -Confirm:$false -NoExit | ConvertFrom-Json
    if ($blockedCreate.ok -or $blockedCreate.errors[0] -notmatch 'prepare-source') { throw 'Workspace creation did not block unmanaged ShaderCache folders in overwrite.' }
    $prepared = & $entry prepare-source -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $prepared.ok -or $prepared.state -ne 'migrated' -or @($prepared.data.movedDirectories).Count -ne 3) { throw "Stable source cache preparation failed: $($prepared | ConvertTo-Json -Depth 8 -Compress)" }
    if ($prepared.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$prepared.data.approval.oneShotReason)) { throw 'Shader-cache migration was not classified as one-shot.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $mo2 'overwrite') -Directory -Recurse -Force | Where-Object Name -Match '^(?i:ShaderCache)(?:[.]|$)').Count -ne 0) { throw 'ShaderCache directories remained in overwrite after preparation.' }
    if ((Get-Content -LiteralPath (Join-Path $source 'modlist.txt') -Raw) -notmatch ('(?m)^\+' + [regex]::Escape([string]$prepared.data.modName) + '\r?$')) { throw 'Migrated shader-cache mod was not enabled in the stable source.' }
    foreach ($move in @($prepared.data.movedDirectories)) { if (-not (Test-Path -LiteralPath ([string]$move.destinationPath) -PathType Container)) { throw "Migrated ShaderCache destination is missing: $($move.destinationPath)" } }
    'stable-profile-drift' | Set-Content -LiteralPath (Join-Path $source 'fixture-drift.txt') -Encoding utf8
    $staleStatus = & $entry fixture-status -ConfigPath $configPath -Compact | ConvertFrom-Json
    if ($staleStatus.state -ne 'fixture-stale' -or $staleStatus.data.expectedProfileFingerprintSha256 -eq $staleStatus.data.actualProfileFingerprintSha256) { throw 'Fixture drift did not report expected and actual fingerprints.' }
    $refreshedFixture = & $entry refresh-fixture -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $refreshedFixture.ok -or -not $refreshedFixture.data.valid -or -not (Test-Path -LiteralPath $refreshedFixture.data.backupPath -PathType Leaf)) { throw 'Guarded fixture refresh did not preserve and verify the manifest.' }
    if ($refreshedFixture.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$refreshedFixture.data.approval.oneShotReason)) { throw 'Shared fixture replacement was not explicitly classified as a one-shot approval.' }
    $created = & $entry create -ConfigPath $configPath -AccessId $accessId -Label weather -SavePolicy FreshGame -Confirm:$false | ConvertFrom-Json
    if (-not $created.ok -or $created.state -ne 'workspace-ready') { throw 'Workspace creation failed.' }
    if ($created.data.profileName -ne $created.data.profile -or $created.data.profileDirectory -ne $created.data.profilePath -or $created.data.modListPath -ne (Join-Path $created.data.profilePath 'modlist.txt')) { throw 'Workspace profile identity fields are not explicit and canonical.' }
    if (Test-Path -LiteralPath (Join-Path $created.data.profilePath 'saves\unknown.ess')) { throw 'Workspace inherited an unknown save.' }
    $verified = & $entry create -ConfigPath $configPath -AccessId $accessId -Label verified -SavePolicy VerifiedFixture -Confirm:$false | ConvertFrom-Json
    if (-not $verified.ok -or -not $verified.data.copiedVerifiedSaves -or $verified.data.saveFixture.id -ne 'interior') { throw 'Verified fixture workspace was not created from the configured default.' }
    foreach ($name in @('Save2_KnownGood.ess', 'Save2_KnownGood.skse')) {
        $copied = Join-Path $verified.data.profilePath (Join-Path 'saves' $name)
        $sourceSave = Join-Path $source (Join-Path 'saves' $name)
        if (-not (Test-Path -LiteralPath $copied -PathType Leaf) -or (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $sourceSave -Algorithm SHA256).Hash) { throw "Verified fixture did not copy exact save file: $name" }
    }
    if (Test-Path -LiteralPath (Join-Path $verified.data.profilePath 'saves\unknown.ess')) { throw 'Verified fixture copied an unlisted save.' }
    $newMod = Join-Path $mods 'Owned Test Mod'; New-Item -ItemType Directory -Path $newMod -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $newMod 'SKSE\Plugins') -Force | Out-Null
    'task-provider' | Set-Content -LiteralPath (Join-Path $newMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    $registered = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -ModName 'Owned Test Mod' -ModDirectory $newMod -WinningPaths 'SKSE\Plugins\Example.dll' -Confirm:$false | ConvertFrom-Json
    if (-not $registered.ok -or -not $registered.data.registration.enabled) { throw "Owned winning mod registration failed: $($registered | ConvertTo-Json -Depth 8 -Compress)" }
    $winnerReceipt = Get-Content -LiteralPath $registered.data.registration.receiptPath -Raw | ConvertFrom-Json
    if (-not $winnerReceipt.winnerProof.verified -or $winnerReceipt.relativeToMod -ne 'Loader') { throw 'Workspace registration did not prove the task DLL wins.' }
    $ensured = & $entry ensure-mod-wins -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -ModName 'Owned Test Mod' -WinningPaths 'SKSE\Plugins\Example.dll' -Confirm:$false | ConvertFrom-Json
    if (-not $ensured.ok -or $ensured.state -ne 'winner-verified') { throw 'Workspace could not re-verify its task-owned winning mod.' }
    $preexisting = & $entry register-mod -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -ModName Loader -ModDirectory $loaderMod -NoExit -Confirm:$false | ConvertFrom-Json
    if ($preexisting.ok) { throw 'Workspace claimed a pre-existing mod.' }
    $released = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -CleanupOwnedMods -Confirm:$false | ConvertFrom-Json
    if (-not $released.ok -or (Test-Path -LiteralPath $created.data.profilePath) -or (Test-Path -LiteralPath $newMod)) { throw "Workspace cleanup did not remove only its owned artifacts: $($released | ConvertTo-Json -Depth 12 -Compress)" }
    if ((Get-Content -LiteralPath $ini -Raw) -notmatch 'selected_profile=@ByteArray\(Mad God Stable\)') { throw 'Workspace release did not select the stable source before deleting the task profile.' }
    if (-not (Test-Path -LiteralPath $released.data.selectedProfileRelease.backupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $released.data.selectedProfileRelease.receiptPath -PathType Leaf)) { throw 'Workspace release did not retain exact INI backup and receipt evidence.' }
    if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $loaderMod)) { throw 'Workspace cleanup damaged stable state.' }
    $releasedVerified = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $verified.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $releasedVerified.ok -or (Test-Path -LiteralPath $verified.data.profilePath)) { throw 'Verified fixture workspace cleanup failed.' }
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    if (-not $releasedAccess.ok) { throw 'Access release failed.' }
    [pscustomobject]@{ok=$true; assertions=35; workspaceId=$created.data.workspaceId} | ConvertTo-Json
}
finally { if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force } }
