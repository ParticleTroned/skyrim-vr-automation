# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'apply', 'start', 'restore', 'stop')]
    [string]$Command = 'inspect',

    [string]$SettingsPath = 'C:\Program Files (x86)\Steam\config\steamvr.vrsettings',

    [string]$NullProfilePath,

    [string]$SteamVRRoot = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR',

    [string]$ServerLogPath = 'C:\Program Files (x86)\Steam\logs\vrserver.txt',

    [string]$OpenVRPathsPath = $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath' } else { $null }),

    [string]$EvidenceDirectory,

    [switch]$WhatIf,

    [switch]$Force,

    [ValidateRange(5, 120)]
    [int]$StartupTimeoutSeconds = 45,

    [switch]$NoExit,

    [switch]$Compact
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $versionFailure = [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $false
        state = 'unsupported-powershell-version'
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @("steamvr-null-control requires PowerShell 7.0 or newer; current host is $($PSVersionTable.PSVersion). Invoke the script with pwsh.exe, not Windows PowerShell powershell.exe.")
        data = @{ requiredPowerShellVersion = '7.0'; actualPowerShellVersion = [string]$PSVersionTable.PSVersion; requiredExecutable = 'pwsh.exe' }
    }
    $versionJsonParameters = @{ InputObject = $versionFailure; Depth = 8 }
    if ($Compact) { $versionJsonParameters['Compress'] = $true }
    ConvertTo-Json @versionJsonParameters
    if (-not $NoExit) { exit 2 }
    return
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($NullProfilePath)) {
    $NullProfilePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\profiles\steamvr-null.profile.json'))
}

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
        $stream = $null
        $algorithm = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $algorithm = [Security.Cryptography.SHA256]::Create()
            return [Convert]::ToHexString($algorithm.ComputeHash($stream))
        }
        finally {
            if ($algorithm) { $algorithm.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

function Get-SharedTextTail([string]$Path, [int]$Count) {
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        $lines = @($reader.ReadToEnd() -split "`r?`n")
        if ($lines.Count -le $Count) { return $lines }
        return @($lines[($lines.Count - $Count)..($lines.Count - 1)])
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Read-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

function Get-ExternalDriverInventory {
    param([string]$Path)
    $drivers = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject][ordered]@{ path = $null; exists = $false; sha256 = $null; drivers = @(); conflicts = @(); errors = @('The OpenVR paths file could not be resolved because LOCALAPPDATA is unavailable.') }
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ path = $resolvedPath; exists = $false; sha256 = $null; drivers = @(); conflicts = @(); errors = @() }
    }
    try {
        $paths = Read-JsonHashtable -Path $resolvedPath
        foreach ($rootValue in @($paths['external_drivers'])) {
            if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
            $root = [IO.Path]::GetFullPath([string]$rootValue)
            $manifestPath = Join-Path $root 'driver.vrdrivermanifest'
            $record = [ordered]@{
                root = $root
                manifestPath = $manifestPath
                manifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
                manifestSha256 = $null
                name = $null
                alwaysActivate = $false
                redirectsDisplay = $false
                conflictsWithNullDisplay = $false
                error = $null
            }
            if ($record.manifestExists) {
                try {
                    $manifest = Read-JsonHashtable -Path $manifestPath
                    $record.manifestSha256 = Get-HashOrNull $manifestPath
                    $record.name = if ($manifest.ContainsKey('name')) { [string]$manifest['name'] } else { [IO.Path]::GetFileName($root) }
                    $record.alwaysActivate = $manifest.ContainsKey('alwaysActivate') -and [bool]$manifest['alwaysActivate']
                    $record.redirectsDisplay = $manifest.ContainsKey('redirectsDisplay') -and [bool]$manifest['redirectsDisplay']
                    $record.conflictsWithNullDisplay = [bool]$record.redirectsDisplay
                }
                catch { $record.error = $_.Exception.Message }
            }
            else { $record.error = 'External driver registration has no driver.vrdrivermanifest.' }
            $drivers.Add([pscustomobject]$record)
            if (-not [string]::IsNullOrWhiteSpace([string]$record.error)) { $errors.Add("External driver '$root' could not be classified: $($record.error)") }
        }
    }
    catch { $errors.Add($_.Exception.Message) }
    $conflicts = @($drivers | Where-Object conflictsWithNullDisplay)
    return [pscustomobject][ordered]@{
        path = $resolvedPath
        exists = $true
        sha256 = Get-HashOrNull $resolvedPath
        drivers = @($drivers)
        conflicts = $conflicts
        errors = @($errors)
    }
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
    $dashboard = if ($Settings.ContainsKey('dashboard')) { $Settings['dashboard'] } else { @{} }
    $driver = if ($Settings.ContainsKey('driver_null')) { $Settings['driver_null'] } else { @{} }
    $expectedSteamVR = $Profile['steamvr']
    $expectedDashboard = $Profile['dashboard']
    $expectedDriver = $Profile['driver_null']

    $checks = [ordered]@{}
    foreach ($key in @('forcedDriver', 'requireHmd', 'activateMultipleDrivers', 'enableHomeApp')) {
        $checks["steamvr.$key"] = [ordered]@{
            actual = if ($steamvr.ContainsKey($key)) { $steamvr[$key] } else { $null }
            expected = $expectedSteamVR[$key]
            matches = $steamvr.ContainsKey($key) -and $steamvr[$key] -eq $expectedSteamVR[$key]
        }
    }
    foreach ($key in $expectedDashboard.Keys) {
        $checks["dashboard.$key"] = [ordered]@{
            actual = if ($dashboard.ContainsKey($key)) { $dashboard[$key] } else { $null }
            expected = $expectedDashboard[$key]
            matches = $dashboard.ContainsKey($key) -and $dashboard[$key] -eq $expectedDashboard[$key]
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

function Get-LogTimestampUtc([string]$Line) {
    if ($Line -notmatch '^(?<timestamp>[A-Za-z]{3}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{4}\s+\d{2}:\d{2}:\d{2}\.\d{3})\s+\[') {
        return $null
    }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        $Matches.timestamp,
        'ddd MMM d yyyy HH:mm:ss.fff',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal,
        [ref]$parsed)) {
        return $null
    }
    return $parsed.UtcDateTime
}

function Get-NullRuntimeEvidence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Processes,
        [Parameter(Mandatory)]$Profile
    )
    $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
    $owned = @($Processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    $server = @($owned | Where-Object name -eq 'vrserver' | Sort-Object startTimeUtc | Select-Object -First 1)
    $serverStartUtc = if ($server.Count -eq 1 -and $server[0].startTimeUtc) { [DateTime]::Parse([string]$server[0].startTimeUtc).ToUniversalTime() } else { $null }
    $loaded = $null
    $active = $null
    $tail = @()
    if ($serverStartUtc -and (Test-Path -LiteralPath $ServerLogPath -PathType Leaf)) {
        $tail = @(Get-SharedTextTail -Path $ServerLogPath -Count 2000)
        $minimumUtc = $serverStartUtc.AddSeconds(-3)
        foreach ($line in $tail) {
            $timestampUtc = Get-LogTimestampUtc -Line $line
            if (-not $timestampUtc -or $timestampUtc -lt $minimumUtc) { continue }
            if ($line -match 'Loaded server driver null .*driver_null\.dll') {
                $loaded = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match "Active HMD set to null\.$([regex]::Escape([string]$Profile['driver_null']['serialNumber']))") {
                $active = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
        }
    }
    return [pscustomobject][ordered]@{
        active = $server.Count -eq 1 -and $null -ne $loaded -and $null -ne $active
        serverProcess = if ($server.Count -eq 1) { $server[0] } else { $null }
        steamVrProcesses = $owned
        unprovenProcesses = @($Processes | Where-Object { $_ -notin $owned })
        serverLogPath = $ServerLogPath
        serverLogSha256 = Get-HashOrNull $ServerLogPath
        driverLoaded = $loaded
        activeHmd = $active
        dashboardProcesses = @($owned | Where-Object name -eq 'vrdashboard')
        dashboardSuppressed = @($owned | Where-Object name -eq 'vrdashboard').Count -eq 0
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
    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'automationInputContract')) {
        if (-not $profile.ContainsKey($section)) { throw "Null-HMD profile is missing '$section'." }
    }
    $processes = @(Get-SteamVRProcesses)
    $resolvedSteamVRRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
    $ownedProcesses = @($processes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase)
    })
    $unprovenProcesses = @($processes | Where-Object { $_ -notin $ownedProcesses })
    $effective = Get-EffectiveState -Settings $settings -Profile $profile
    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
    $externalDrivers = Get-ExternalDriverInventory -Path $OpenVRPathsPath

    if ($Command -eq 'stop') {
        if ($ownedProcesses.Count -eq 0) {
            $result = New-Result -Ok $true -State 'already-stopped' -Data @{ processes = @(); unprovenProcesses = $unprovenProcesses; force = [bool]$Force }
        }
        elseif ($WhatIf) {
            $result = New-Result -Ok $true -State 'dry-run' -Data @{ processes = $ownedProcesses; unprovenProcesses = $unprovenProcesses; force = [bool]$Force }
        }
        else {
            if ($Force) {
                $resolvedRoot = [IO.Path]::GetFullPath($SteamVRRoot).TrimEnd('\') + '\'
                foreach ($process in $ownedProcesses) {
                    if ([string]::IsNullOrWhiteSpace([string]$process.path)) {
                        throw "Cannot prove executable ownership for SteamVR PID $($process.id)."
                    }
                    $resolvedProcessPath = [IO.Path]::GetFullPath([string]$process.path)
                    if (-not $resolvedProcessPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Refusing to terminate PID $($process.id): '$resolvedProcessPath' is outside '$resolvedRoot'."
                    }
                }
                foreach ($process in $ownedProcesses) {
                    Stop-Process -Id ([int]$process.id) -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                $monitor = @($ownedProcesses | Where-Object name -eq 'vrmonitor' | Select-Object -First 1)
                if ($monitor.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$monitor[0].path)) {
                    $helper = Start-Process -FilePath ([string]$monitor[0].path) -ArgumentList '-shutdown' -WindowStyle Hidden -PassThru
                    $null = $helper.WaitForExit(5000)
                }
                foreach ($process in @($ownedProcesses | Where-Object name -eq 'vrmonitor')) {
                    $live = Get-Process -Id ([int]$process.id) -ErrorAction SilentlyContinue
                    if ($live) { $null = $live.CloseMainWindow() }
                }
            }

            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                Start-Sleep -Milliseconds 250
                    $remaining = @(Get-SteamVRProcesses | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
                        [IO.Path]::GetFullPath([string]$_.path).StartsWith($resolvedSteamVRRoot, [StringComparison]::OrdinalIgnoreCase)
                    })
            } while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

            if ($remaining.Count -eq 0) {
                $result = New-Result -Ok $true -State 'stopped' -Data @{ processesBefore = $ownedProcesses; unprovenProcesses = $unprovenProcesses; remaining = @(); force = [bool]$Force }
            }
            else {
                $result = New-Result -Ok $false -State 'stop-incomplete' -Data @{ processesBefore = $ownedProcesses; unprovenProcesses = $unprovenProcesses; remaining = $remaining; force = [bool]$Force } -Errors @(
                    $(if ($Force) { 'One or more verified SteamVR processes remained after forced termination.' } else { 'SteamVR did not accept the graceful shutdown request; retry with -Force after reviewing the exact process inventory.' })
                )
            }
        }
    }
    elseif ($Command -eq 'inspect') {
        $state = if ($externalDrivers.errors.Count -gt 0) { 'external-driver-inventory-failed' } elseif ($externalDrivers.conflicts.Count -gt 0) { 'external-driver-conflict' } elseif ($runtime.active -and -not $runtime.dashboardSuppressed) { 'dashboard-input-conflict' } elseif ($runtime.active -and $effective.active) { 'null-runtime-active-unqualified' } elseif ($effective.active) { 'null-configured-runtime-stopped' } else { 'null-inactive' }
        $result = New-Result -Ok $true -State $state -Data @{
            settingsPath = $SettingsPath
            settingsSha256 = Get-HashOrNull $SettingsPath
            profilePath = $NullProfilePath
            profileSha256 = Get-HashOrNull $NullProfilePath
            processes = $processes
            effective = $effective
            runtime = $runtime
            externalDrivers = $externalDrivers
            inputContract = $profile['automationInputContract']
        }
    }
    elseif ($Command -eq 'start') {
        if ($externalDrivers.errors.Count -gt 0) {
            $result = New-Result -Ok $false -State 'external-driver-inventory-failed' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers } -Errors @('The external OpenVR driver inventory could not be read reliably; refusing null-HMD startup.')
        }
        elseif ($externalDrivers.conflicts.Count -gt 0) {
            $names = @($externalDrivers.conflicts | ForEach-Object { if ([string]::IsNullOrWhiteSpace([string]$_.name)) { $_.root } else { $_.name } })
            $result = New-Result -Ok $false -State 'external-driver-conflict' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers } -Errors @("Refusing null-HMD startup because external OpenVR display driver(s) redirect the display path: $($names -join ', '). Disable or unregister the exact driver registration, then inspect again.")
        }
        elseif (-not $effective.active) {
            $result = New-Result -Ok $false -State 'null-not-configured' -Data @{ effective = $effective; runtime = $runtime } -Errors @('Apply the null-HMD settings transaction before starting SteamVR.')
        }
        elseif ($runtime.active -and -not $runtime.dashboardSuppressed) {
            $result = New-Result -Ok $false -State 'dashboard-input-conflict' -Data @{ effective = $effective; runtime = $runtime; inputContract = $profile['automationInputContract'] } -Errors @('vrdashboard.exe is active even though dashboard.enableDashboard=false. The generic-HMD pointer route is not isolated; do not replay input or collect measurements.')
        }
        elseif ($runtime.active) {
            $result = New-Result -Ok $true -State 'already-running-unqualified' -Data @{ effective = $effective; runtime = $runtime; inputContract = $profile['automationInputContract'] }
        }
        elseif ($ownedProcesses.Count -gt 0) {
            $result = New-Result -Ok $false -State 'ambiguous-runtime' -Data @{ effective = $effective; runtime = $runtime; processes = $ownedProcesses; unprovenProcesses = $unprovenProcesses } -Errors @('SteamVR processes are running from the configured root, but current-session null-driver activation is not proven. Stop and inspect them before retrying.')
        }
        else {
            if ([string]::IsNullOrWhiteSpace($EvidenceDirectory) -or -not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
                throw 'start requires an existing -EvidenceDirectory owned by the apply transaction.'
            }
            $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $startupPath = Join-Path $SteamVRRoot 'bin\win64\vrstartup.exe'
            if (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) { throw "SteamVR startup executable does not exist: $startupPath" }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{ startupPath = $startupPath; effective = $effective; runtime = $runtime }
            }
            else {
                $startedUtc = [DateTime]::UtcNow
                $launcher = Start-Process -FilePath $startupPath -WindowStyle Hidden -PassThru
                $deadline = $startedUtc.AddSeconds($StartupTimeoutSeconds)
                do {
                    Start-Sleep -Milliseconds 250
                    $processes = @(Get-SteamVRProcesses)
                    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
                } while (-not $runtime.active -and [DateTime]::UtcNow -lt $deadline)
                if ($runtime.active) {
                    Start-Sleep -Seconds 2
                    $processes = @(Get-SteamVRProcesses)
                    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
                }
                $runtimeReceiptPath = Join-Path $EvidenceDirectory 'steamvr-null-runtime.receipt.json'
                $runtimeReceipt = [ordered]@{
                    schemaVersion = 1
                    startedUtc = $startedUtc.ToString('o')
                    launcherPid = $launcher.Id
                    startupPath = $startupPath
                    runtimeActive = [bool]$runtime.active
                    runtime = $runtime
                }
                Write-JsonAtomic -Path $runtimeReceiptPath -Value $runtimeReceipt
                if ($runtime.active -and -not $runtime.dashboardSuppressed) {
                    $result = New-Result -Ok $false -State 'dashboard-input-conflict' -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; inputContract = $profile['automationInputContract'] } -Errors @('SteamVR activated the null HMD, but vrdashboard.exe is active. The generic-HMD pointer route is not isolated; do not replay input or collect measurements.')
                }
                elseif ($runtime.active) {
                    $result = New-Result -Ok $true -State 'null-runtime-started-unqualified' -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; inputContract = $profile['automationInputContract'] }
                }
                else {
                    $result = New-Result -Ok $false -State 'startup-incomplete' -Data @{ effective = $effective; runtime = $runtime; processes = $processes; runtimeReceiptPath = $runtimeReceiptPath } -Errors @('SteamVR started, but current-session Valve null-driver and active-HMD log proof was not observed before the timeout.')
                }
            }
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
            throw 'EvidenceDirectory is required for apply and restore.'
        }
        if (-not (Test-Path -LiteralPath $EvidenceDirectory -PathType Container)) {
            throw "Evidence directory does not exist: $EvidenceDirectory"
        }
        if ($ownedProcesses.Count -gt 0) {
            throw "SteamVR must be stopped before $Command. Running from configured root: $($ownedProcesses.name -join ', ')"
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
                    foreach ($section in @('steamvr', 'dashboard', 'driver_null')) {
                        if (-not $settings.ContainsKey($section)) { $settings[$section] = [ordered]@{} }
                        foreach ($key in $profile[$section].Keys) { $settings[$section][$key] = $profile[$section][$key] }
                    }
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
