# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'apply', 'restore', 'stop')]
    [string]$Command = 'inspect',

    [string]$SettingsPath = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings',

    [string]$NullProfilePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\profiles\steamvr-null.profile.json')),

    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',

    [string]$EvidenceDirectory,

    [switch]$WhatIf,

    [switch]$Force,

    [switch]$NoExit,

    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SteamVRProcesses {
    $records = @()
    foreach ($name in @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup', 'vrdashboard', 'vrwebhelper')) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $records += [pscustomobject][ordered]@{
                name = $process.ProcessName
                id = $process.Id
                startTimeUtc = $(try { $process.StartTime.ToUniversalTime().ToString('o') } catch { $null })
                path = $(try { $process.Path } catch { $null })
            }
        }
    }
    return @($records | Sort-Object name, id)
}

function Get-HashOrNull {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
    }
    return $null
}

function Read-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 32
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        $null = Read-JsonHashtable -Path $temporary
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-EffectiveState {
    param(
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)]$Profile
    )
    $steamvr = if ($Settings.ContainsKey('steamvr')) { $Settings['steamvr'] } else { @{} }
    $driver = if ($Settings.ContainsKey('driver_null')) { $Settings['driver_null'] } else { @{} }
    $expectedSteamVR = $Profile['steamvr']
    $expectedDriver = $Profile['driver_null']

    $checks = [ordered]@{}
    foreach ($key in @('forcedDriver', 'requireHmd', 'activateMultipleDrivers', 'enableHomeApp')) {
        $checks["steamvr.$key"] = [ordered]@{
            actual = if ($steamvr.ContainsKey($key)) { $steamvr[$key] } else { $null }
            expected = $expectedSteamVR[$key]
            matches = $steamvr.ContainsKey($key) -and $steamvr[$key] -eq $expectedSteamVR[$key]
        }
    }
    foreach ($key in @('enable', 'serialNumber', 'modelNumber', 'windowWidth', 'windowHeight', 'renderWidth', 'renderHeight', 'displayFrequency')) {
        $checks["driver_null.$key"] = [ordered]@{
            actual = if ($driver.ContainsKey($key)) { $driver[$key] } else { $null }
            expected = $expectedDriver[$key]
            matches = $driver.ContainsKey($key) -and $driver[$key] -eq $expectedDriver[$key]
        }
    }
    return [pscustomobject][ordered]@{
        active = @($checks.Values | Where-Object { -not $_.matches }).Count -eq 0
        checks = $checks
    }
}

function New-Result {
    param([bool]$Ok, [string]$State, $Data, [string[]]$Errors = @())
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @($Errors)
        data = $Data
    }
}

try {
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "SteamVR settings file does not exist: $SettingsPath"
    }
    if (-not (Test-Path -LiteralPath $NullProfilePath -PathType Leaf)) {
        throw "Null-HMD profile does not exist: $NullProfilePath"
    }
    $settings = Read-JsonHashtable -Path $SettingsPath
    $profile = Read-JsonHashtable -Path $NullProfilePath
    foreach ($section in @('steamvr', 'driver_null')) {
        if (-not $profile.ContainsKey($section)) { throw "Null-HMD profile is missing '$section'." }
    }
    $processes = @(Get-SteamVRProcesses)
    $effective = Get-EffectiveState -Settings $settings -Profile $profile

    if ($Command -eq 'stop') {
        if ($processes.Count -eq 0) {
            $result = New-Result -Ok $true -State 'already-stopped' -Data @{ processes = @(); force = [bool]$Force }
        }
        elseif ($WhatIf) {
            $result = New-Result -Ok $true -State 'dry-run' -Data @{ processes = $processes; force = [bool]$Force }
        }
        else {
            if ($Force) {
                $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
                foreach ($process in $processes) {
                    if ([string]::IsNullOrWhiteSpace([string]$process.path)) {
                        throw "Cannot prove executable ownership for SteamVR PID $($process.id)."
                    }
                    $resolvedProcessPath = [IO.Path]::GetFullPath([string]$process.path)
                    if (-not $resolvedProcessPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing to terminate PID $($process.id): '$resolvedProcessPath' is outside '$resolvedRoot'."
                    }
                }
                foreach ($process in $processes) {
                    Stop-Process -Id ([int]$process.id) -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                $monitor = @($processes | Where-Object name -eq 'vrmonitor' | Select-Object -First 1)
                if ($monitor.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$monitor[0].path)) {
                    $helper = Start-Process -FilePath ([string]$monitor[0].path) -ArgumentList '-shutdown' -WindowStyle Hidden -PassThru
                    $null = $helper.WaitForExit(5000)
                }
                foreach ($process in @($processes | Where-Object name -eq 'vrmonitor')) {
                    $live = Get-Process -Id ([int]$process.id) -ErrorAction SilentlyContinue
                    if ($live) { $null = $live.CloseMainWindow() }
                }
            }

            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 250
                $remaining = @(Get-SteamVRProcesses)
            } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

            if ($remaining.Count -eq 0) {
                $result = New-Result -Ok $true -State 'stopped' -Data @{ processesBefore = $processes; remaining = @(); force = [bool]$Force }
            }
            else {
                $result = New-Result -Ok $false -State 'stop-incomplete' -Data @{ processesBefore = $processes; remaining = $remaining; force = [bool]$Force } -Errors @(
                    $(if ($Force) { 'One or more verified SteamVR processes remained after forced termination.' } else { 'SteamVR did not accept the graceful shutdown request; retry with -Force after reviewing the exact process inventory.' })
                )
            }
        }
    }
    elseif ($Command -eq 'inspect') {
        $result = New-Result -Ok $true -State $(if ($effective.active) { 'null-active' } else { 'null-inactive' }) -Data @{
            settingsPath = $SettingsPath
            settingsSha256 = Get-HashOrNull $SettingsPath
            profilePath = $NullProfilePath
            profileSha256 = Get-HashOrNull $NullProfilePath
            processes = $processes
            effective = $effective
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
            throw 'EvidenceDirectory is required for apply and restore.'
        }
        if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
            throw "Evidence directory does not exist: $EvidenceDirectory"
        }
        if ($processes.Count -gt 0) {
            throw "SteamVR must be stopped before $Command. Running: $($processes.name -join ', ')"
        }
        $backupPath = Join-Path $EvidenceDirectory 'steamvr.vrsettings.before'
        $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'

        if ($Command -eq 'apply') {
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                throw "Refusing to replace the existing exact backup: $backupPath"
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldBackup = $SettingsPath
                    backupPath = $backupPath
                    wouldApplyProfile = $NullProfilePath
                    settingsSha256Before = Get-HashOrNull $SettingsPath
                }
            }
            else {
                Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
                $beforeHash = Get-HashOrNull $backupPath
                try {
                    if (-not $settings.ContainsKey('steamvr')) { $settings['steamvr'] = [ordered]@{} }
                    if (-not $settings.ContainsKey('driver_null')) { $settings['driver_null'] = [ordered]@{} }
                    foreach ($key in $profile['steamvr'].Keys) { $settings['steamvr'][$key] = $profile['steamvr'][$key] }
                    foreach ($key in $profile['driver_null'].Keys) { $settings['driver_null'][$key] = $profile['driver_null'][$key] }
                    Write-JsonAtomic -Path $SettingsPath -Value $settings
                    $afterSettings = Read-JsonHashtable -Path $SettingsPath
                    $afterEffective = Get-EffectiveState -Settings $afterSettings -Profile $profile
                    if (-not $afterEffective.active) { throw 'The written settings do not match the null-HMD profile.' }
                    $receipt = [ordered]@{
                        schemaVersion = 1
                        appliedUtc = [DateTime]::UtcNow.ToString('o')
                        settingsPath = $SettingsPath
                        backupPath = $backupPath
                        settingsSha256Before = $beforeHash
                        settingsSha256Null = Get-HashOrNull $SettingsPath
                        profilePath = $NullProfilePath
                        profileSha256 = Get-HashOrNull $NullProfilePath
                    }
                    Write-JsonAtomic -Path $receiptPath -Value $receipt
                }
                catch {
                    Copy-Item -LiteralPath $backupPath -Destination $SettingsPath -Force
                    throw "Null-HMD apply failed and the exact backup was restored. $($_.Exception.Message)"
                }
                $result = New-Result -Ok $true -State 'null-applied' -Data @{
                    settingsPath = $SettingsPath
                    backupPath = $backupPath
                    receiptPath = $receiptPath
                    settingsSha256Before = $beforeHash
                    settingsSha256Null = Get-HashOrNull $SettingsPath
                    effective = $afterEffective
                }
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Exact backup is missing: $backupPath" }
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $receipt = Read-JsonHashtable -Path $receiptPath
            $backupHash = Get-HashOrNull $backupPath
            if ($backupHash -ne $receipt['settingsSha256Before']) { throw 'The exact backup hash does not match the apply receipt.' }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldRestore = $backupPath
                    settingsPath = $SettingsPath
                    expectedSha256 = $backupHash
                    backupRetained = $true
                }
            }
            else {
                $temporary = "$SettingsPath.restore.$([guid]::NewGuid().ToString('N')).tmp"
                try {
                    Copy-Item -LiteralPath $backupPath -Destination $temporary
                    Move-Item -LiteralPath $temporary -Destination $SettingsPath -Force
                }
                finally {
                    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
                }
                $restoredHash = Get-HashOrNull $SettingsPath
                if ($restoredHash -ne $backupHash) { throw 'Restored SteamVR settings hash does not match the exact backup.' }
                $result = New-Result -Ok $true -State 'restored' -Data @{
                    settingsPath = $SettingsPath
                    restoredSha256 = $restoredHash
                    backupPath = $backupPath
                    backupRetained = $true
                }
            }
        }
    }
}
catch {
    $result = New-Result -Ok $false -State 'blocked' -Data @{ settingsPath = $SettingsPath; profilePath = $NullProfilePath; evidenceDirectory = $EvidenceDirectory } -Errors @($_.Exception.Message)
}

$jsonParameters = @{ InputObject = $result; Depth = 20 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
