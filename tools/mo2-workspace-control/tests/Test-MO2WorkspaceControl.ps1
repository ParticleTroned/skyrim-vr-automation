# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-MO2WorkspaceControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-workspace-control-' + [guid]::NewGuid().ToString('N'))
$previousFixtureRoot = $env:SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT
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
    $env:SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT = $fixture
    $mo2 = Join-Path $fixture 'MO2'; $profiles = Join-Path $mo2 'profiles'; $mods = Join-Path $mo2 'mods'
    $source = Join-Path $profiles 'Mad God Stable'; $loaderMod = Join-Path $mods 'Loader'; $sessions = Join-Path $fixture 'sessions'
    foreach ($p in @($source, (Join-Path $source 'saves'), $loaderMod, (Join-Path $loaderMod 'SKSE\Plugins'), (Join-Path $mo2 'overwrite'), (Join-Path $mo2 'rb'), $sessions, (Join-Path $fixture 'archive'))) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    '+Loader' | Set-Content -LiteralPath (Join-Path $source 'modlist.txt') -Encoding utf8
    '*Skyrim.esm' | Set-Content -LiteralPath (Join-Path $source 'plugins.txt') -Encoding utf8
    "[custom_overwrites]`r`nSynthesis=Synthesis Patch (SFW)`r`n" | Set-Content -LiteralPath (Join-Path $source 'settings.ini') -Encoding utf8 -NoNewline
    'do-not-copy' | Set-Content -LiteralPath (Join-Path $source 'saves\unknown.ess') -Encoding utf8
    'known-good-save' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.ess') -Encoding utf8
    'known-good-cosave' | Set-Content -LiteralPath (Join-Path $source 'saves\Save2_KnownGood.skse') -Encoding utf8
    'existing-provider' | Set-Content -LiteralPath (Join-Path $loaderMod 'SKSE\Plugins\Example.dll') -Encoding utf8
    $mo2Exe = Join-Path $mo2 'ModOrganizer.exe'; $loader = Join-Path $loaderMod 'loader.exe'
    New-Item -ItemType File -Path $mo2Exe -Force | Out-Null; New-Item -ItemType File -Path $loader -Force | Out-Null
    $ini = Join-Path $mo2 'ModOrganizer.ini'
    [IO.File]::WriteAllText($ini, "[General]`r`nselected_profile=@ByteArray(Codex)`r`n[customExecutables]`r`n1\title=@ByteArray(Test)`r`n1\binary=@ByteArray($loader)`r`n1\workingDirectory=@ByteArray($fixture)`r`n", [Text.UTF8Encoding]::new($false))
    $configPath = Join-Path $fixture 'config.json'; $lock = Join-Path $sessions 'lock.json'
    $fixtureManifestPath = Join-Path $fixture 'known-good-saves.json'
    $saveFiles = @('Save2_KnownGood.ess', 'Save2_KnownGood.skse') | ForEach-Object {
        $path = Join-Path $source (Join-Path 'saves' $_)
        [ordered]@{ relativePath = $_; bytes = [long](Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    [ordered]@{ contractVersion='1.0.0'; sourceProfile='Mad God Stable'; profileFingerprintSha256=(Get-TestProfileFingerprint $source); defaultFixtureId='interior'; fixtures=@([ordered]@{id='interior';label='Known-good interior';location='TestCell';loadName='Save2_KnownGood';files=$saveFiles}) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding utf8
    [ordered]@{
        contractVersion='0.4.0'; machine='fixture'; mo2=[ordered]@{root=$mo2;executable=$mo2Exe;ini='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\MO2\ModOrganizer.ini';profilesDirectory='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\MO2\profiles';modsDirectory='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\MO2\mods';overwriteDirectory=(Join-Path $mo2 'overwrite');logsDirectory=(Join-Path $mo2 'logs');rootBuilderDefinitions=@();rootBuilderDataDirectory=(Join-Path $mo2 'rb');processNames=@('WorkspaceImpossibleMO2');gameProcessNames=@('WorkspaceImpossibleGame');runtimeProcessNames=@()};
        defaults=[ordered]@{profile='Mad God Stable';testProfileSource='Mad God Stable';newGameFixtureManifest='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\known-good-saves.json';executable='Test'};storage=[ordered]@{sessionStaging='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\sessions';archive='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\archive'};limits=[ordered]@{maxEnumeratedFiles=100;overwriteWarningFiles=10;overwriteBlockFiles=50;overwriteWarningBytes=1024;overwriteBlockBytes=4096;launchPendingGraceSeconds=30};session=[ordered]@{lockFile='%SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT%\sessions\lock.json'}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding utf8
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'mo2-control\MO2Control.psm1') -Force
    $config = Read-MO2ControlConfig -ConfigPath $configPath
    $access = Invoke-MO2RequestAccess -Config $config -Label fixture; $accessId = [string]$access.data.access.accessId
    $legacyId = '20260825t174017z-legacy-fixture-06166c48'
    $legacyProfileName = 'Codex Task - ' + $legacyId
    $legacyProfilePath = Join-Path $profiles $legacyProfileName
    New-Item -ItemType Directory -Path $legacyProfilePath -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'modlist.txt'), (Join-Path $source 'plugins.txt'), (Join-Path $source 'settings.ini') -Destination $legacyProfilePath
    $workspaceRoot = Join-Path $sessions 'workspaces'
    New-Item -ItemType Directory -Path $workspaceRoot -Force | Out-Null
    $legacyManifestPath = Join-Path $workspaceRoot ($legacyId + '.json')
    [ordered]@{
        contractVersion = '1.2.0'; workspaceId = $legacyId; accessId = 'retired-access'; status = 'ready'
        profile = $legacyProfileName; profilePath = $legacyProfilePath
        sourceProfile = 'Mad God Stable'; sourceProfilePath = $source
        registeredMods = @(); initialModNames = @('Loader')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $legacyManifestPath -Encoding utf8
    $preservedCache = Join-Path $mods 'Synthesis Patch (SFW)\ShaderCache\preserved.bin'
    New-Item -ItemType Directory -Path (Split-Path -Parent $preservedCache) -Force | Out-Null
    'user-owned-cache' | Set-Content -LiteralPath $preservedCache -Encoding utf8
    $legacyManifestHash = (Get-FileHash -LiteralPath $legacyManifestPath -Algorithm SHA256).Hash
    $preservedCacheHash = (Get-FileHash -LiteralPath $preservedCache -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($ini, ([IO.File]::ReadAllText($ini) -replace 'selected_profile=@ByteArray\(Codex\)', ('selected_profile=@ByteArray(' + $legacyProfileName + ')')), [Text.UTF8Encoding]::new($false))
    $legacyInspection = Invoke-MO2Inspect -Config $config
    if (-not $legacyInspection.data.selectedTaskWorkspace.legacy -or -not $legacyInspection.data.selectedTaskWorkspace.recoverable -or
        @($legacyInspection.checks | Where-Object { $_.name -eq 'selected-task-workspace' -and $_.status -eq 'warn' }).Count -ne 1) {
        throw 'MO2 inspection did not identify the selected recoverable legacy workspace.'
    }
    $wrongLegacyRecovery = & $entry recover-legacy-selection -ConfigPath $configPath -AccessId $accessId -WorkspaceId '20260825t174017z-wrong-fixture-06166c48' -NoExit -Confirm:$false -Compact | ConvertFrom-Json
    if ($wrongLegacyRecovery.ok -or (Get-Content -LiteralPath $ini -Raw) -notmatch [regex]::Escape("selected_profile=@ByteArray($legacyProfileName)")) {
        throw 'Legacy selection recovery accepted a mismatched workspace identity.'
    }
    $legacyDryRun = & $entry recover-legacy-selection -ConfigPath $configPath -AccessId $accessId -WorkspaceId $legacyId -WhatIf -Compact | ConvertFrom-Json
    if (-not $legacyDryRun.ok -or $legacyDryRun.state -ne 'dry-run' -or $legacyDryRun.data.approval.reusableApprovalEligible -or
        (Get-Content -LiteralPath $ini -Raw) -notmatch [regex]::Escape("selected_profile=@ByteArray($legacyProfileName)")) {
        throw 'Legacy selection recovery dry-run changed state or exposed reusable approval.'
    }
    $legacyRecovery = & $entry recover-legacy-selection -ConfigPath $configPath -AccessId $accessId -WorkspaceId $legacyId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $legacyRecovery.ok -or $legacyRecovery.state -ne 'legacy-selection-recovered' -or
        (Get-Content -LiteralPath $ini -Raw) -notmatch 'selected_profile=@ByteArray\(Mad God Stable\)' -or
        -not (Test-Path -LiteralPath $legacyProfilePath -PathType Container) -or
        (Get-FileHash -LiteralPath $legacyManifestPath -Algorithm SHA256).Hash -cne $legacyManifestHash -or
        (Get-FileHash -LiteralPath $preservedCache -Algorithm SHA256).Hash -cne $preservedCacheHash -or
        -not (Test-Path -LiteralPath $legacyRecovery.data.selectedProfileRecovery.receiptPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $legacyRecovery.data.recoveryReceiptPath -PathType Leaf)) {
        throw 'Legacy selection recovery did not preserve the legacy workspace and cache while restoring the stable profile.'
    }
    $fixtureStatusRaw = & $entry fixture-status -ConfigPath $configPath -Compact
    if ($fixtureStatusRaw -match "`r|`n") { throw 'Compact workspace output was not one line.' }
    $fixtureStatus = $fixtureStatusRaw | ConvertFrom-Json
    if (-not $fixtureStatus.ok -or $fixtureStatus.state -ne 'fixture-valid') { throw 'Fixture status did not validate the original manifest.' }
    if (-not $fixtureStatus.data.approval.reusableApprovalEligible -or @($fixtureStatus.data.approval.reusablePrefix).Count -ne 6 -or $fixtureStatus.data.approval.reusablePrefix[4] -ne [IO.Path]::GetFullPath($entry) -or $fixtureStatus.data.approval.reusablePrefix[5] -ne 'fixture-status') { throw 'Fixture status did not expose its exact reusable approval prefix.' }
    'stable-profile-drift' | Set-Content -LiteralPath (Join-Path $source 'fixture-drift.txt') -Encoding utf8
    $staleStatus = & $entry fixture-status -ConfigPath $configPath -Compact | ConvertFrom-Json
    if ($staleStatus.state -ne 'fixture-stale' -or $staleStatus.data.expectedProfileFingerprintSha256 -eq $staleStatus.data.actualProfileFingerprintSha256) { throw 'Fixture drift did not report expected and actual fingerprints.' }
    $refreshedFixture = & $entry refresh-fixture -ConfigPath $configPath -AccessId $accessId -Confirm:$false -Compact | ConvertFrom-Json
    if (-not $refreshedFixture.ok -or -not $refreshedFixture.data.valid -or -not (Test-Path -LiteralPath $refreshedFixture.data.backupPath -PathType Leaf)) { throw 'Guarded fixture refresh did not preserve and verify the manifest.' }
    if ($refreshedFixture.data.approval.reusableApprovalEligible -or [string]::IsNullOrWhiteSpace([string]$refreshedFixture.data.approval.oneShotReason)) { throw 'Shared fixture replacement was not explicitly classified as a one-shot approval.' }
    $created = & $entry create -ConfigPath $configPath -AccessId $accessId -Label weather -SavePolicy FreshGame -Confirm:$false | ConvertFrom-Json
    if (-not $created.ok -or $created.state -ne 'workspace-ready') { throw 'Workspace creation failed.' }
    $expectedManifestPath = Join-Path (Join-Path $sessions 'workspaces') ($created.data.workspaceId + '.json')
    if (-not (Test-Path -LiteralPath $expectedManifestPath -PathType Leaf)) { throw 'Workspace storage path did not expand its environment variable.' }
    if ($created.data.profileName -ne $created.data.profile -or $created.data.profileDirectory -ne $created.data.profilePath -or $created.data.modListPath -ne (Join-Path $created.data.profilePath 'modlist.txt')) { throw 'Workspace profile identity fields are not explicit and canonical.' }
    if (Test-Path -LiteralPath (Join-Path $created.data.profilePath 'saves\unknown.ess')) { throw 'Workspace inherited an unknown save.' }
    if (-not (Test-Path -LiteralPath $created.data.runtimeOutput.sentinelPath -PathType Leaf)) { throw 'Workspace did not create its owned ShaderCache sentinel.' }
    if ((Get-Content -LiteralPath (Join-Path $created.data.profilePath 'settings.ini') -Raw) -notmatch "(?m)^Test=$([regex]::Escape([string]$created.data.runtimeOutput.modName))\r?$") { throw 'Workspace did not bind the exact runtime executable to its owned output mod.' }
    if ((Get-Content -LiteralPath (Join-Path $created.data.profilePath 'settings.ini') -Raw) -notmatch '(?m)^Synthesis=Synthesis Patch \(SFW\)\r?$') { throw 'Workspace replaced an unrelated executable output mapping.' }
    if (@(Get-Content -LiteralPath $created.data.modListPath | Where-Object { $_ -ceq ('+' + [string]$created.data.runtimeOutput.modName) }).Count -ne 1) { throw 'Workspace runtime-output mod is not enabled exactly once.' }
    $initialIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId
    if (-not $initialIsolation.ok -or $initialIsolation.cachePlan.exists) { throw 'Fresh workspace runtime-output isolation was not valid and unprepared.' }
    $unpreparedSession = Invoke-MO2Prepare -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -Label fixture-unprepared -WhatIf
    if ($unpreparedSession.ok -or @($unpreparedSession.errors | Where-Object { $_ -match 'shader-cache prepare plan' }).Count -ne 1) { throw 'MO2 prepare did not fail closed before the bound cache plan existed.' }
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
    $cacheEvidence = [string]$created.data.runtimeOutput.cacheEvidenceDirectory
    New-Item -ItemType Directory -Path $cacheEvidence -Force | Out-Null
    $planPath = [string]$created.data.runtimeOutput.cachePlanPath
    [ordered]@{
        contractVersion='1.1.0';state='prepared';cachePath=[string]$created.data.runtimeOutput.cachePath
        cacheBinding=[ordered]@{
            mode='mo2-winning-loose-provider';profilePath=[string]$created.data.modListPath
            profileSha256=(Get-FileHash -LiteralPath $created.data.modListPath -Algorithm SHA256).Hash
            modsPath=$mods;relativeCachePath='ShaderCache';modName=[string]$created.data.runtimeOutput.modName
            modRoot=[string]$created.data.runtimeOutput.modPath;cachePath=[string]$created.data.runtimeOutput.cachePath
        }
        requireMaterializedOutput=$true
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $planPath -Encoding utf8
    $modListBytes = [IO.File]::ReadAllBytes([string]$created.data.modListPath)
    Add-Content -LiteralPath $created.data.modListPath -Value '# plan drift' -Encoding utf8
    $staleIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    [IO.File]::WriteAllBytes([string]$created.data.modListPath, $modListBytes)
    if ($staleIsolation.ok -or @($staleIsolation.errors | Where-Object { $_ -match 'exact task profile' }).Count -ne 1) { throw 'A cache plan with a stale modlist hash authorized launch.' }
    $preparedIsolation = Get-MO2TaskWorkspaceIsolation -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -RequirePreparedCache
    if (-not $preparedIsolation.ok) { throw "Prepared task isolation did not validate: $($preparedIsolation.errors -join '; ')" }
    $preparedSession = Invoke-MO2Prepare -Config $config -Profile $created.data.profileName -Executable Test -AccessId $accessId -Label fixture-prepared -WhatIf
    if (-not $preparedSession.ok -or $preparedSession.state -ne 'dry-run') { throw 'MO2 prepare did not accept the exact bound open cache plan.' }
    $openRelease = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -CleanupOwnedMods -NoExit -Confirm:$false | ConvertFrom-Json
    if ($openRelease.ok -or -not (Test-Path -LiteralPath $created.data.profilePath -PathType Container) -or -not (Test-Path -LiteralPath $created.data.runtimeOutput.modPath -PathType Container)) { throw 'Workspace release did not retain an open cache transaction and its owned paths.' }
    [ordered]@{
        contractVersion='1.1.0';state='complete';planPath=$planPath
        cacheBinding=[ordered]@{modName=[string]$created.data.runtimeOutput.modName;cachePath=[string]$created.data.runtimeOutput.cachePath}
        workingTree=[ordered]@{materializedFiles=0}
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $created.data.runtimeOutput.cacheCompletionPath -Encoding utf8
    $emptyRelease = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -CleanupOwnedMods -NoExit -Confirm:$false | ConvertFrom-Json
    if ($emptyRelease.ok -or -not (Test-Path -LiteralPath $created.data.runtimeOutput.modPath -PathType Container)) { throw 'Workspace release accepted a cache completion without materialized output.' }
    [ordered]@{
        contractVersion='1.1.0';state='complete';planPath=$planPath
        cacheBinding=[ordered]@{modName=[string]$created.data.runtimeOutput.modName;cachePath=[string]$created.data.runtimeOutput.cachePath}
        workingTree=[ordered]@{materializedFiles=1}
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $created.data.runtimeOutput.cacheCompletionPath -Encoding utf8
    $released = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $created.data.workspaceId -CleanupOwnedMods -Confirm:$false | ConvertFrom-Json
    if (-not $released.ok -or (Test-Path -LiteralPath $created.data.profilePath) -or (Test-Path -LiteralPath $newMod)) { throw "Workspace cleanup did not remove only its owned artifacts: $($released | ConvertTo-Json -Depth 12 -Compress)" }
    if (Test-Path -LiteralPath $created.data.runtimeOutput.modPath -PathType Container) { throw 'Workspace cleanup retained its already-preserved task runtime-output mod.' }
    if (-not (Test-Path -LiteralPath $released.data.runtimeOutputPreservation.receiptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $released.data.runtimeOutputPreservation.preservedPath -PathType Container)) { throw 'Workspace release did not preserve exact runtime-output evidence before cleanup.' }
    if ((Get-Content -LiteralPath $ini -Raw) -notmatch 'selected_profile=@ByteArray\(Mad God Stable\)') { throw 'Workspace release did not select the stable source before deleting the task profile.' }
    if (-not (Test-Path -LiteralPath $released.data.selectedProfileRelease.backupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $released.data.selectedProfileRelease.receiptPath -PathType Leaf)) { throw 'Workspace release did not retain exact INI backup and receipt evidence.' }
    if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $loaderMod)) { throw 'Workspace cleanup damaged stable state.' }
    $releasedVerified = & $entry release -ConfigPath $configPath -AccessId $accessId -WorkspaceId $verified.data.workspaceId -Confirm:$false | ConvertFrom-Json
    if (-not $releasedVerified.ok -or (Test-Path -LiteralPath $verified.data.profilePath)) { throw 'Verified fixture workspace cleanup failed.' }
    $releasedAccess = Invoke-MO2ReleaseAccess -Config $config -AccessId $accessId
    if (-not $releasedAccess.ok) { throw 'Access release failed.' }
    [pscustomobject]@{ok=$true; assertions=46; workspaceId=$created.data.workspaceId} | ConvertTo-Json
}
finally {
    $env:SKYRIM_VR_AUTOMATION_TEST_FIXTURE_ROOT = $previousFixtureRoot
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
