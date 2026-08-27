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
    $steamVrRoot = Join-Path $fixture 'SteamVR'
    $startupPath = Join-Path $steamVrRoot 'bin\win64\vrstartup.exe'
    $serverLogPath = Join-Path $fixture 'vrserver.txt'
    $openVrPathsPath = Join-Path $fixture 'openvrpaths.vrpath'
    $externalDriverRoot = Join-Path $fixture 'VirtualDesktopDriver'
    New-Item -ItemType Directory -Path $externalDriverRoot | Out-Null
    [ordered]@{ version = 1; external_drivers = @() } | ConvertTo-Json | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    New-Item -ItemType Directory -Path $evidence | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $startupPath) -Force | Out-Null
    [IO.File]::WriteAllBytes($startupPath, [byte[]]@(0))
    $originalText = "{`r`n  `"steamvr`": { `"enableHomeApp`": true },`r`n  `"unrelated`": { `"value`": 7 }`r`n}`r`n"
    [IO.File]::WriteAllText($settingsPath, $originalText, [Text.UTF8Encoding]::new($false))
    [ordered]@{
        steamvr = [ordered]@{ forcedDriver = 'null'; requireHmd = $false; activateMultipleDrivers = $false; enableHomeApp = $false }
        dashboard = [ordered]@{ enableDashboard = $false }
        driver_null = [ordered]@{ enable = $true; serialNumber = 'Fixture'; modelNumber = 'Fixture'; windowWidth = 2160; windowHeight = 1200; renderWidth = 1512; renderHeight = 1680; displayFrequency = 90.0 }
        automationInputContract = [ordered]@{ hmdPoseProvider = 'valve-null-fixed'; hmdPoseControl = 'unavailable'; controllerInput = 'unavailable'; dashboardInput = 'disabled'; replayReady = $false; measurementReady = $false; qualificationRequired = 'fixture qualification' }
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
    $appliedJson = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    Assert-Test ($appliedJson['unrelated']['value'] -eq 7) 'apply preserves unrelated settings'
    Assert-Test ($appliedJson['dashboard']['enableDashboard'] -eq $false) 'apply disables the dashboard generic-HMD input route'
    Assert-Test (Test-Path -LiteralPath (Join-Path $evidence 'steamvr-null-receipt.json')) 'apply writes hash receipt'

    $inspectConfigured = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($inspectConfigured.ok -and $inspectConfigured.state -eq 'null-configured-runtime-stopped' -and -not $inspectConfigured.data.runtime.active) 'inspect distinguishes configured settings from a proven runtime'
    Assert-Test (-not $inspectConfigured.data.inputContract.replayReady -and $inspectConfigured.data.inputContract.controllerInput -eq 'unavailable') 'inspect states that controller replay and controlled HMD pose are unavailable'

    $startDry = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact | ConvertFrom-Json
    Assert-Test ($startDry.ok -and $startDry.state -eq 'dry-run' -and $startDry.data.startupPath -eq $startupPath) 'start dry-run validates the configured transaction and exact startup path'

    [ordered]@{ name = 'VirtualDesktop'; alwaysActivate = $true; redirectsDisplay = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $externalDriverRoot 'driver.vrdrivermanifest') -Encoding utf8
    [ordered]@{ version = 1; external_drivers = @($externalDriverRoot) } | ConvertTo-Json | Set-Content -LiteralPath $openVrPathsPath -Encoding utf8
    $conflictInspect = & $entry inspect -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -Compact | ConvertFrom-Json
    Assert-Test ($conflictInspect.ok -and $conflictInspect.state -eq 'external-driver-conflict' -and $conflictInspect.data.externalDrivers.conflicts[0].name -eq 'VirtualDesktop') 'inspect reports exact external display-driver conflicts'
    $conflictStart = & $entry start -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -WhatIf -Compact -NoExit | ConvertFrom-Json
    Assert-Test (-not $conflictStart.ok -and $conflictStart.state -eq 'external-driver-conflict') 'start refuses an external OpenVR display redirector'

    $restored = & $entry restore -SettingsPath $settingsPath -NullProfilePath $profilePath -SteamVRRoot $steamVrRoot -ServerLogPath $serverLogPath -OpenVRPathsPath $openVrPathsPath -EvidenceDirectory $evidence -Compact | ConvertFrom-Json
    Assert-Test ($restored.ok -and $restored.state -eq 'restored' -and $restored.data.backupRetained) 'restore succeeds and retains backup'
    Assert-Test ([IO.File]::ReadAllText($settingsPath) -ceq $originalText) 'restore is exact-byte identical'
}
finally {
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 4
if ($failures.Count -gt 0) { exit 1 }
