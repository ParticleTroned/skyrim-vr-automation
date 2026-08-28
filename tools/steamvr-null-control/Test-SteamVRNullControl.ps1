[CmdletBinding()]
param()

Set-StrictMode -Version Latest
# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot 'Invoke-SteamVRNullControl.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('steamvr-null-control-' + [guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$resolvedFixture = [IO.Path]::GetFullPath($fixture)
if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Fixture escaped the temporary directory: $resolvedFixture"
}
$failures = [Collections.Generic.List[string]]::new()
$passes = [Collections.Generic.List[string]]::new()

function Assert-Test([bool]$Condition, [string]$Name) {
    if ($Condition) { $passes.Add($Name) } else { $failures.Add($Name) }
}

$windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
if ($windowsPowerShell) {
    $legacyResult = & $windowsPowerShell.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry inspect -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $legacyResult.ok -and $legacyResult.state -eq 'unsupported-powershell-version' -and $legacyResult.errors[0] -match 'pwsh\.exe') 'Windows PowerShell receives an explicit PowerShell 7 compatibility failure'
}

try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $settingsPath = Join-Path $fixture 'steamvr.vrsettings'
    $profilePath = Join-Path $fixture 'null.json'
    $evidence = Join-Path $fixture 'evidence'
    $isolationEvidence = Join-Path $fixture 'evidence-isolation'
    $failureEvidence = Join-Path $fixture 'evidence-failure'
    $steamVrRoot = Join-Path $fixture 'SteamVR'
    $startupPath = Join-Path $steamVrRoot 'bin\win64\vrstartup.exe'
    $serverLogPath = Join-Path $fixture 'vrserver.txt'
    $openVrPathsPath = Join-Path $fixture 'openvrpaths.vrpath'
    $externalDriverRoot = Join-Path $fixture 'VirtualDesktopDriver'
    $headPoseDriverRoot = Join-Path $fixture 'HeadPoseDriver'
    New-Item -ItemType Directory -Path $externalDriverRoot | Out-Null
    New-Item -ItemType Directory -Path $headPoseDriverRoot | Out-Null
    [ordered]@{ name = 'codex_head_pose'; alwaysActivate = $true; redirectsDisplay = $false } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $headPoseDriverRoot 'driver.vrdrivermanifest') -Encoding utf8
    [ordered]@{ version = 1; external_drivers = @($headPoseDriverRoot) } | ConvertTo-Json | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    New-Item -ItemType Directory -Path $evidence | Out-Null
    New-Item -ItemType Directory -Path $isolationEvidence | Out-Null
    New-Item -ItemType Directory -Path $failureEvidence | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $startupPath) -Force | Out-Null
    [IO.File]::WriteAllBytes($startupPath, [byte[]]@(0))
    $originalText = "{`r`n  `"steamvr`": { `"enableHomeApp`": true },`r`n  `"unrelated`": { `"value`": 7 }`r`n}`r`n"
    [IO.File]::WriteAllText($settingsPath, $originalText, [Text.UTF8Encoding]::new($false))
    [ordered]@{
        steamvr = [ordered]@{ forcedDriver = 'null'; requireHmd = $false; activateMultipleDrivers = $true; enableHomeApp = $false }
        dashboard = [ordered]@{ enableDashboard = $false }
        driver_null = [ordered]@{ enable = $true; serialNumber = 'Fixture'; modelNumber = 'Fixture'; windowWidth = 2160; windowHeight = 1200; renderWidth = 1512; renderHeight = 1680; displayFrequency = 90.0 }
        driver_codex_head_pose = [ordered]@{ enable = $true; serialNumber = 'CSX-NULL-HMD-POSE-1'; modelNumber = 'Fixture Pose'; positionX = 0.0; eyeHeightMeters = 1.68; positionZ = 0.0; yawDegrees = 0.0; pitchDegrees = 0.0; rollDegrees = 0.0 }
        TrackingOverrides = [ordered]@{ '/devices/codex_head_pose/CSX-NULL-HMD-POSE-1' = '/user/head' }
        headPoseProviderContract = [ordered]@{ driverName = 'codex_head_pose'; registeredDevicePath = '/devices/codex_head_pose/CSX-NULL-HMD-POSE-1'; semanticTarget = '/user/head'; sharedMemoryName = "Local\CSXVRHeadPose-fixture-$([guid]::NewGuid().ToString('N'))"; sharedMemoryVersion = 1; minimumQualifiedEyeHeightMeters = 1.0; maximumQualifiedEyeHeightMeters = 2.5 }
        automationInputContract = [ordered]@{ hmdPoseProvider = 'codex-head-pose-v2'; hmdPoseControl = 'shared-memory-v2'; controllerInput = 'unavailable'; dashboardInput = 'disabled'; replayReady = $false; measurementReady = $false; qualificationRequired = 'fixture qualification' }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $profilePath -Encoding utf8

    $inspectBefore = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($inspectBefore.ok -and $inspectBefore.state -eq 'null-inactive') 'inspect identifies inactive null profile'

    $stop = & $entry stop -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($stop.ok -and $stop.state -eq 'already-stopped') 'stop recognizes an already closed SteamVR state'

    $dry = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($dry.ok -and $dry.state -eq 'dry-run') 'apply dry-run succeeds'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $evidence 'steamvr.vrsettings.before'))) 'apply dry-run creates no backup'

    $applied = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -Compact | ConvertFrom-Json
    Assert-Test ($applied.ok -and $applied.state -eq 'null-applied') 'apply writes effective null profile'
    if (-not $applied.ok) { throw "Fixture apply failed: $($applied.errors -join '; ')" }
    $appliedJson = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test ($appliedJson['unrelated']['value'] -eq 7) 'apply preserves unrelated settings'
    Assert-Test ($appliedJson['dashboard']['enableDashboard'] -eq $false) 'apply disables the dashboard generic-HMD input route'
    Assert-Test ($appliedJson['driver_codex_head_pose']['eyeHeightMeters'] -eq 1.68 -and $appliedJson['TrackingOverrides']['/devices/codex_head_pose/CSX-NULL-HMD-POSE-1'] -eq '/user/head') 'apply configures the synthetic head pose and semantic override'
    Assert-Test (Test-Path -LiteralPath (Join-Path $evidence 'steamvr-null-receipt.json')) 'apply writes hash receipt'
    $appliedText = [IO.File]::ReadAllText($settingsPath)

    $otherSettingsPath = Join-Path $fixture 'other-steamvr.vrsettings'
    [IO.File]::WriteAllText($otherSettingsPath, $originalText, [Text.UTF8Encoding]::new($false))
    $wrongPathRestore = & $entry restore -SettingsPath $otherSettingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $wrongPathRestore.ok -and $wrongPathRestore.state -eq 'blocked' -and $wrongPathRestore.errors[0] -match 'settings path') 'restore refuses a settings path different from its apply receipt'

    [IO.File]::AppendAllText($settingsPath, "`n")
    $settingsDriftRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $settingsDriftRestore.ok -and $settingsDriftRestore.state -eq 'blocked' -and $settingsDriftRestore.errors[0] -match 'settings.*changed|settings.*drift') 'restore refuses SteamVR settings drift after apply'
    [IO.File]::WriteAllText($settingsPath, $appliedText, [Text.UTF8Encoding]::new($false))

    $inspectConfigured = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($inspectConfigured.ok -and $inspectConfigured.state -eq 'null-configured-runtime-stopped' -and -not $inspectConfigured.data.runtime.active) 'inspect distinguishes configured settings from a proven runtime'
    Assert-Test (-not $inspectConfigured.data.inputContract.replayReady -and $inspectConfigured.data.inputContract.controllerInput -eq 'unavailable' -and $inspectConfigured.data.inputContract.hmdPoseControl -eq 'shared-memory-v2') 'inspect exposes controlled HMD pose while keeping controller replay unavailable'

    $startDry = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($startDry.ok -and $startDry.state -eq 'dry-run' -and $startDry.data.startupPath -eq $startupPath) 'start dry-run validates the configured transaction and exact startup path'

    [ordered]@{ name = 'VirtualDesktop'; alwaysActivate = $true; redirectsDisplay = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $externalDriverRoot 'driver.vrdrivermanifest') -Encoding utf8
    [ordered]@{ version = 1; external_drivers = @($headPoseDriverRoot, $externalDriverRoot) } | ConvertTo-Json | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    $conflictInspect = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($conflictInspect.ok -and $conflictInspect.state -eq 'external-driver-conflict' -and $conflictInspect.data.externalDrivers.conflicts[0].name -eq 'VirtualDesktop') 'inspect reports exact external display-driver conflicts'
    $conflictStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $conflictStart.ok -and $conflictStart.state -eq 'external-driver-conflict') 'start refuses an external OpenVR display redirector'
    $conflictOverrideStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -AllowExternalDisplayRedirector -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test ($conflictOverrideStart.ok -and $conflictOverrideStart.state -eq 'dry-run' -and $conflictOverrideStart.data.externalDisplayRedirectorAllowed) 'explicit diagnostic override permits a dry-run while retaining the driver inventory'

    $restored = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -Compact | ConvertFrom-Json
    Assert-Test ($restored.ok -and $restored.state -eq 'restored' -and $restored.data.backupRetained) 'restore succeeds and retains backup'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText) 'restore is exact-byte identical'

    $openVrTextBeforeIsolation = [IO.File]::ReadAllText($openVrPathsPath)
    $isolationDry = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -IsolateExternalDisplayRedirectors -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($isolationDry.ok -and $isolationDry.state -eq 'dry-run' -and $isolationDry.data.externalDriverIsolation.targets[0].name -eq 'VirtualDesktop') 'isolation dry-run identifies the sole exact redirector'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $isolationEvidence 'openvrpaths.vrpath.before'))) 'isolation dry-run creates no OpenVR registration backup'

    $isolatedApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -IsolateExternalDisplayRedirectors -Compact | ConvertFrom-Json
    Assert-Test ($isolatedApply.ok -and $isolatedApply.state -eq 'null-applied' -and $isolatedApply.data.externalDriverIsolation.enabled) 'apply transaction isolates the exact external display redirector'
    if (-not $isolatedApply.ok) { throw "Fixture isolation apply failed: $($isolatedApply.errors -join '; ')" }
    $isolatedPaths = Get-Content -LiteralPath $openVrPathsPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test (@($isolatedPaths['external_drivers']).Count -eq 1 -and [IO.Path]::GetFullPath([string]$isolatedPaths['external_drivers'][0]) -eq [IO.Path]::GetFullPath($headPoseDriverRoot)) 'isolation retains the non-redirecting head-pose driver only'
    Assert-Test (Test-Path -LiteralPath (Join-Path $isolationEvidence 'openvrpaths.vrpath.before')) 'isolation writes an exact OpenVR registration backup'

    $isolatedInspect = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($isolatedInspect.ok -and $isolatedInspect.state -eq 'null-configured-runtime-stopped' -and $isolatedInspect.data.externalDrivers.conflicts.Count -eq 0) 'inspect accepts the conflict-free isolated registration state'
    $isolatedStartDry = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($isolatedStartDry.ok -and $isolatedStartDry.state -eq 'dry-run' -and $isolatedStartDry.data.externalDriverIsolation.enabled -and -not $isolatedStartDry.data.inputContract.measurementReady) 'isolated start validates its receipt while runtime readiness remains fail-closed'

    $isolatedText = [IO.File]::ReadAllText($openVrPathsPath)
    $failedRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -InternalTestFailurePoint restore-after-settings -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedRestore.ok -and $failedRestore.errors[0] -match 'exact applied state was restored') 'two-file restore failure reports verified rollback to the applied state'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $appliedText -and [IO.File]::ReadAllText($openVrPathsPath) -ceq $isolatedText) 'two-file restore failure leaves neither target partially restored'

    $drift = Get-Content -LiteralPath $openVrPathsPath -Raw | ConvertFrom-Json -AsHashtable
    $drift['unrelated_test_drift'] = $true
    $drift | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    $driftStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $driftStart.ok -and $driftStart.state -eq 'external-driver-isolation-drift') 'start refuses OpenVR registration drift after isolation'
    $driftRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $driftRestore.ok -and $driftRestore.state -eq 'blocked' -and $driftRestore.errors[0] -match 'registration file changed') 'restore refuses to overwrite unclassified OpenVR registration drift'

    [IO.File]::WriteAllText($openVrPathsPath, $isolatedText, [Text.UTF8Encoding]::new($false))
    $isolatedRestoreDry = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($isolatedRestoreDry.ok -and $isolatedRestoreDry.data.externalDriverIsolation.enabled -and $isolatedRestoreDry.data.wouldRestoreOpenVRPaths) 'restore dry-run reports exact external-driver restoration'
    $isolatedRestore = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact | ConvertFrom-Json
    Assert-Test ($isolatedRestore.ok -and $isolatedRestore.state -eq 'restored' -and $isolatedRestore.data.openVRPathsRestoredSha256) 'restore reinstates the exact external-driver registration transaction'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText) 'isolation restore keeps SteamVR settings exact-byte identical'
    Assert-Test ([IO.File]::ReadAllText($openVrPathsPath) -ceq $openVrTextBeforeIsolation) 'isolation restore keeps OpenVR registrations exact-byte identical'

    $isolatedRestoreAgain = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $isolationEvidence -Compact | ConvertFrom-Json
    Assert-Test ($isolatedRestoreAgain.ok -and $isolatedRestoreAgain.state -eq 'already-restored') 'restore retry recognizes the committed exact baseline without rewriting it'

    $failedApply = & $entry apply -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $failureEvidence -IsolateExternalDisplayRedirectors -InternalTestFailurePoint apply-after-openvr -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $failedApply.ok -and $failedApply.errors[0] -match 'every exact backup was restored') 'two-file apply failure reports verified rollback to the original state'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText -and [IO.File]::ReadAllText($openVrPathsPath) -ceq $openVrTextBeforeIsolation) 'two-file apply failure leaves neither target partially mutated'
}
finally {
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 4
if ($failures.Count -gt 0) { exit 1 }
