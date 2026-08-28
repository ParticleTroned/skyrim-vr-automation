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

    [string]$HeadPoseDriverRoot = $(if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'CSX-VR-Automation\SteamVR\drivers\codex_head_pose' } else { $null }),

    [string]$EvidenceDirectory,

    [switch]$WhatIf,

    [switch]$Force,

    [switch]$AllowExternalDisplayRedirector,

    [switch]$IsolateExternalDisplayRedirectors,

    [string[]]$ExternalDisplayRedirectorRoot = @(),

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

function Get-NormalizedPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-ExternalDisplayIsolationTargets {
    param(
        [Parameter(Mandatory)]$Inventory,
        [string[]]$RequestedRoots = @()
    )
    if ($Inventory.errors.Count -gt 0) {
        throw 'External display-driver isolation requires a complete, error-free OpenVR driver inventory.'
    }
    $conflicts = @($Inventory.conflicts)
    if ($conflicts.Count -eq 0) {
        throw 'External display-driver isolation was requested, but no registered display redirector is present.'
    }

    $requested = @($RequestedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Get-NormalizedPath $_ } | Select-Object -Unique)
    if ($requested.Count -eq 0) {
        if ($conflicts.Count -ne 1) {
            throw "External display-driver isolation found $($conflicts.Count) redirectors. Specify every exact root with -ExternalDisplayRedirectorRoot."
        }
        return @($conflicts)
    }

    $selected = [Collections.Generic.List[object]]::new()
    foreach ($root in $requested) {
        $matches = @($conflicts | Where-Object { (Get-NormalizedPath ([string]$_.root)) -eq $root })
        if ($matches.Count -ne 1) {
            throw "Requested external display redirector '$root' is not one exact classified conflict."
        }
        $selected.Add($matches[0])
    }
    $unselected = @($conflicts | Where-Object { (Get-NormalizedPath ([string]$_.root)) -notin $requested })
    if ($unselected.Count -gt 0) {
        throw "External display-driver isolation must account for every redirector. Unselected: $(@($unselected.root) -join ', ')"
    }
    return @($selected)
}

function Disable-ExternalDriverRegistrations {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Targets
    )
    $document = Read-JsonHashtable -Path $Path
    $registered = @($document['external_drivers'])
    $targetRoots = @($Targets | ForEach-Object { Get-NormalizedPath ([string]$_.root) })
    $removed = [Collections.Generic.List[string]]::new()
    $retained = [Collections.Generic.List[string]]::new()
    foreach ($rootValue in $registered) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) { continue }
        $normalized = Get-NormalizedPath ([string]$rootValue)
        if ($normalized -in $targetRoots) { $removed.Add($normalized) } else { $retained.Add([string]$rootValue) }
    }
    if ($removed.Count -ne $targetRoots.Count) {
        throw "OpenVR registration changed before isolation. Expected to remove $($targetRoots.Count) exact roots, found $($removed.Count)."
    }
    $document['external_drivers'] = @($retained)
    Write-JsonAtomic -Path $Path -Value $document
    return [pscustomobject][ordered]@{ removedRoots = @($removed); retainedRoots = @($retained) }
}

function Copy-FileAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $temporary = "$Destination.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
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
    $headPoseDriver = if ($Settings.ContainsKey('driver_codex_head_pose')) { $Settings['driver_codex_head_pose'] } else { @{} }
    $trackingOverrides = if ($Settings.ContainsKey('TrackingOverrides')) { $Settings['TrackingOverrides'] } else { @{} }
    $expectedSteamVR = $Profile['steamvr']
    $expectedDashboard = $Profile['dashboard']
    $expectedDriver = $Profile['driver_null']
    $expectedHeadPoseDriver = $Profile['driver_codex_head_pose']
    $expectedTrackingOverrides = $Profile['TrackingOverrides']

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
    foreach ($key in $expectedHeadPoseDriver.Keys) {
        $checks["driver_codex_head_pose.$key"] = [ordered]@{
            actual = if ($headPoseDriver.ContainsKey($key)) { $headPoseDriver[$key] } else { $null }
            expected = $expectedHeadPoseDriver[$key]
            matches = $headPoseDriver.ContainsKey($key) -and $headPoseDriver[$key] -eq $expectedHeadPoseDriver[$key]
        }
    }
    foreach ($key in $expectedTrackingOverrides.Keys) {
        $checks["TrackingOverrides.$key"] = [ordered]@{
            actual = if ($trackingOverrides.ContainsKey($key)) { $trackingOverrides[$key] } else { $null }
            expected = $expectedTrackingOverrides[$key]
            matches = $trackingOverrides.ContainsKey($key) -and $trackingOverrides[$key] -eq $expectedTrackingOverrides[$key]
        }
    }
    return [pscustomobject][ordered]@{
        active = @($checks.Values | Where-Object { -not $_.matches }).Count -eq 0
        checks = $checks
    }
}

function Get-HeadPoseSharedState {
    param([Parameter(Mandatory)]$Contract)
    $mapping = $null
    $view = $null
    try {
        $mapping = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting(
            [string]$Contract['sharedMemoryName'],
            [IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        $view = $mapping.CreateViewAccessor(0, 88, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        $firstSequence = $view.ReadUInt64(8)
        $state = [ordered]@{
            magic = $view.ReadUInt32(0)
            version = $view.ReadUInt16(4)
            size = $view.ReadUInt16(6)
            requestedSequence = $firstSequence
            appliedSequence = $view.ReadUInt64(16)
            status = $view.ReadUInt32(24)
            flags = $view.ReadUInt32(28)
            position = @($view.ReadDouble(32), $view.ReadDouble(40), $view.ReadDouble(48))
            quaternion = @($view.ReadDouble(56), $view.ReadDouble(64), $view.ReadDouble(72), $view.ReadDouble(80))
        }
        $secondSequence = $view.ReadUInt64(8)
        $state['stable'] = $firstSequence -eq $secondSequence -and ($secondSequence % 2) -eq 0
        $state['available'] = $true
        $state['protocolValid'] = $state.magic -eq 0x48505343 -and $state.version -eq [int]$Contract['sharedMemoryVersion'] -and $state.size -eq 88
        $state['acknowledged'] = $state.stable -and $state.requestedSequence -gt 0 -and $state.appliedSequence -eq $state.requestedSequence -and $state.status -eq 1
        $state['eyeHeightQualified'] = $state.position[1] -ge [double]$Contract['minimumQualifiedEyeHeightMeters'] -and $state.position[1] -le [double]$Contract['maximumQualifiedEyeHeightMeters']
        $state['qualified'] = $state.protocolValid -and $state.acknowledged -and $state.eyeHeightQualified -and (($state.flags -band 1) -eq 1)
        return [pscustomobject]$state
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The head-pose shared-memory provider is not running.' }
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = $_.Exception.Message }
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
    }
}

function Get-ApplicationHeadPose {
    param([Parameter(Mandatory)]$Contract)
    if ([string]::IsNullOrWhiteSpace($HeadPoseDriverRoot)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The stable head-pose driver root could not be resolved.' }
    }
    $probePath = Join-Path $HeadPoseDriverRoot ([string]$Contract['poseProbeRelativePath'])
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $probePath; error = 'The independent OpenVR pose probe is not installed.' }
    }
    try {
        $output = @(& $probePath 2>&1)
        $exitCode = $LASTEXITCODE
        $payload = ($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
        $qualified = $exitCode -eq 0 -and $payload.ok -and $payload.standing.connected -and $payload.standing.valid -and
            [double]$payload.standing.position[1] -ge [double]$Contract['minimumQualifiedEyeHeightMeters'] -and
            [double]$payload.standing.position[1] -le [double]$Contract['maximumQualifiedEyeHeightMeters']
        return [pscustomobject][ordered]@{
            available = $true
            qualified = $qualified
            probePath = $probePath
            exitCode = $exitCode
            observation = $payload
        }
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $probePath; error = $_.Exception.Message }
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
    $headPoseLoaded = $null
    $headPoseRegistered = $null
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
            if ($line -match 'Loaded server driver codex_head_pose .*driver_codex_head_pose\.dll') {
                $headPoseLoaded = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
            if ($line -match 'codex_head_pose: registered synthetic head-pose device at configured standing pose') {
                $headPoseRegistered = [pscustomobject]@{ timestampUtc = $timestampUtc.ToString('o'); line = $line }
            }
        }
    }
    $headPoseState = Get-HeadPoseSharedState -Contract $Profile['headPoseProviderContract']
    $applicationHeadPose = if ($server.Count -eq 1 -and [bool]$headPoseState.qualified) { Get-ApplicationHeadPose -Contract $Profile['headPoseProviderContract'] } else { [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The provider is not ready for an application-facing pose probe.' } }
    return [pscustomobject][ordered]@{
        active = $server.Count -eq 1 -and $null -ne $loaded -and $null -ne $active
        serverProcess = if ($server.Count -eq 1) { $server[0] } else { $null }
        steamVrProcesses = $owned
        unprovenProcesses = @($Processes | Where-Object { $_ -notin $owned })
        serverLogPath = $ServerLogPath
        serverLogSha256 = Get-HashOrNull $ServerLogPath
        driverLoaded = $loaded
        activeHmd = $active
        headPoseDriverLoaded = $headPoseLoaded
        headPoseDeviceRegistered = $headPoseRegistered
        headPoseState = $headPoseState
        applicationHeadPose = $applicationHeadPose
        headPoseReady = $server.Count -eq 1 -and $null -ne $headPoseLoaded -and $null -ne $headPoseRegistered -and [bool]$headPoseState.qualified -and [bool]$applicationHeadPose.qualified
        dashboardProcesses = @($owned | Where-Object name -eq 'vrdashboard')
        dashboardSuppressed = $Profile['dashboard'].ContainsKey('enableDashboard') -and -not [bool]$Profile['dashboard']['enableDashboard']
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

function Get-RuntimeInputContract {
    param(
        [Parameter(Mandatory)]$BaseContract,
        [Parameter(Mandatory)]$Effective,
        [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)]$ExternalDrivers,
        [bool]$DiagnosticDisplayOverride = $false
    )
    $contract = ($BaseContract | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable)
    $blockers = [Collections.Generic.List[string]]::new()
    if (-not [bool]$Effective.active) { $blockers.Add('null-profile-not-effective') }
    if (-not [bool]$Runtime.active) { $blockers.Add('null-runtime-not-active') }
    if (-not [bool]$Runtime.headPoseReady) { $blockers.Add('head-pose-not-qualified') }
    if ($ExternalDrivers.errors.Count -gt 0) { $blockers.Add('external-driver-inventory-incomplete') }
    if ($ExternalDrivers.conflicts.Count -gt 0) { $blockers.Add('external-display-redirector-present') }
    if ($DiagnosticDisplayOverride) { $blockers.Add('diagnostic-display-override') }
    $contract['measurementReady'] = $blockers.Count -eq 0
    $contract['measurementBlockers'] = @($blockers)
    $contract['dashboardProcessTelemetryOnly'] = $true
    return $contract
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
    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides', 'headPoseProviderContract', 'automationInputContract')) {
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
        $providerDriver = @($externalDrivers.drivers | Where-Object name -eq ([string]$profile['headPoseProviderContract']['driverName']))
        $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers
        $state = if ($externalDrivers.errors.Count -gt 0) { 'external-driver-inventory-failed' } elseif ($providerDriver.Count -ne 1) { 'head-pose-provider-unavailable' } elseif ($externalDrivers.conflicts.Count -gt 0) { 'external-driver-conflict' } elseif ($runtime.active -and -not $runtime.headPoseReady) { 'head-pose-provider-not-ready' } elseif ($runtime.active -and $effective.active) { 'null-runtime-active-head-pose-ready' } elseif ($effective.active) { 'null-configured-runtime-stopped' } else { 'null-inactive' }
        $result = New-Result -Ok $true -State $state -Data @{
            settingsPath = $SettingsPath
            settingsSha256 = Get-HashOrNull $SettingsPath
            profilePath = $NullProfilePath
            profileSha256 = Get-HashOrNull $NullProfilePath
            processes = $processes
            effective = $effective
            runtime = $runtime
            externalDrivers = $externalDrivers
            inputContract = $inputContract
        }
    }
    elseif ($Command -eq 'start') {
        $providerDriver = @($externalDrivers.drivers | Where-Object name -eq ([string]$profile['headPoseProviderContract']['driverName']))
        if ($externalDrivers.errors.Count -gt 0) {
            $result = New-Result -Ok $false -State 'external-driver-inventory-failed' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers } -Errors @('The external OpenVR driver inventory could not be read reliably; refusing null-HMD startup.')
        }
        elseif ($providerDriver.Count -ne 1) {
            $result = New-Result -Ok $false -State 'head-pose-provider-unavailable' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; requiredDriverName = $profile['headPoseProviderContract']['driverName'] } -Errors @('The CSX SteamVR head-pose driver must be installed and registered exactly once before null-HMD startup.')
        }
        elseif ($externalDrivers.conflicts.Count -gt 0 -and -not $AllowExternalDisplayRedirector) {
            $names = @($externalDrivers.conflicts | ForEach-Object { if ([string]::IsNullOrWhiteSpace([string]$_.name)) { $_.root } else { $_.name } })
            $result = New-Result -Ok $false -State 'external-driver-conflict' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; explicitDiagnosticOverrideRequired = $true } -Errors @("Refusing null-HMD startup because external OpenVR display driver(s) redirect the display path: $($names -join ', '). Disable or unregister the exact driver registration, or use -AllowExternalDisplayRedirector only for an explicitly authorized diagnostic coexistence run.")
        }
        elseif (-not $effective.active) {
            $result = New-Result -Ok $false -State 'null-not-configured' -Data @{ effective = $effective; runtime = $runtime } -Errors @('Apply the null-HMD settings transaction before starting SteamVR.')
        }
        elseif ($runtime.active -and -not $runtime.headPoseReady) {
            $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
            $result = New-Result -Ok $false -State 'head-pose-provider-not-ready' -Data @{ effective = $effective; runtime = $runtime; inputContract = $inputContract } -Errors @('The Valve null display is active, but the synthetic standing head pose is not qualified.')
        }
        elseif ($runtime.active) {
            $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
            $result = New-Result -Ok $true -State 'already-running-head-pose-ready' -Data @{ effective = $effective; runtime = $runtime; inputContract = $inputContract }
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
            $applyReceipt = Read-JsonHashtable -Path $receiptPath
            $isolation = if ($applyReceipt.ContainsKey('externalDriverIsolation')) { $applyReceipt['externalDriverIsolation'] } else { $null }
            $isolationDrift = $null -ne $isolation -and [bool]$isolation['enabled'] -and (Get-HashOrNull ([string]$isolation['openVRPathsPath'])) -ne [string]$isolation['sha256Isolated']
            $startupPath = Join-Path $SteamVRRoot 'bin\win64\vrstartup.exe'
            if (-not (Test-Path -LiteralPath $startupPath -PathType Leaf)) { throw "SteamVR startup executable does not exist: $startupPath" }
            if ($isolationDrift) {
                $result = New-Result -Ok $false -State 'external-driver-isolation-drift' -Data @{ effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; externalDriverIsolation = $isolation } -Errors @('The OpenVR registration file no longer matches the isolated apply receipt. Refusing startup until the drift is classified or the exact transaction is restored.')
            }
            elseif ($WhatIf) {
                $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
                $result = New-Result -Ok $true -State 'dry-run' -Data @{ startupPath = $startupPath; effective = $effective; runtime = $runtime; externalDrivers = $externalDrivers; externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector; externalDriverIsolation = $isolation; inputContract = $inputContract }
            }
            else {
                $startedUtc = [DateTime]::UtcNow
                $launcher = Start-Process -FilePath $startupPath -WindowStyle Hidden -PassThru
                $deadline = $startedUtc.AddSeconds($StartupTimeoutSeconds)
                do {
                    Start-Sleep -Milliseconds 250
                    $processes = @(Get-SteamVRProcesses)
                    $runtime = Get-NullRuntimeEvidence -Processes $processes -Profile $profile
                } while ((-not $runtime.active -or -not $runtime.headPoseReady) -and [DateTime]::UtcNow -lt $deadline)
                if ($runtime.active -and $runtime.headPoseReady) {
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
                    externalDrivers = $externalDrivers
                    externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector
                }
                Write-JsonAtomic -Path $runtimeReceiptPath -Value $runtimeReceipt
                $inputContract = Get-RuntimeInputContract -BaseContract $profile['automationInputContract'] -Effective $effective -Runtime $runtime -ExternalDrivers $externalDrivers -DiagnosticDisplayOverride ([bool]$AllowExternalDisplayRedirector)
                if ($runtime.active -and -not $runtime.headPoseReady) {
                    $result = New-Result -Ok $false -State 'head-pose-provider-not-ready' -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; inputContract = $inputContract } -Errors @('SteamVR activated the Valve null display, but the synthetic standing head pose was not loaded and acknowledged.')
                }
                elseif ($runtime.active) {
                    $result = New-Result -Ok $true -State $(if ($AllowExternalDisplayRedirector) { 'null-runtime-started-head-pose-ready-unqualified-display-route' } else { 'null-runtime-started-head-pose-ready' }) -Data @{ effective = $effective; runtime = $runtime; runtimeReceiptPath = $runtimeReceiptPath; inputContract = $inputContract; externalDrivers = $externalDrivers; externalDisplayRedirectorAllowed = [bool]$AllowExternalDisplayRedirector; externalDriverIsolation = $isolation }
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
        $openVRPathsBackupPath = Join-Path $EvidenceDirectory 'openvrpaths.vrpath.before'
        $receiptPath = Join-Path $EvidenceDirectory 'steamvr-null-receipt.json'

        if ($Command -eq 'apply') {
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                throw "Refusing to replace the existing exact backup: $backupPath"
            }
            $isolationTargets = if ($IsolateExternalDisplayRedirectors) { @(Get-ExternalDisplayIsolationTargets -Inventory $externalDrivers -RequestedRoots $ExternalDisplayRedirectorRoot) } else { @() }
            if ($IsolateExternalDisplayRedirectors -and (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) {
                throw "Refusing to replace the existing exact OpenVR registration backup: $openVRPathsBackupPath"
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldBackup = $SettingsPath
                    backupPath = $backupPath
                    wouldApplyProfile = $NullProfilePath
                    settingsSha256Before = Get-HashOrNull $SettingsPath
                    externalDriverIsolation = [ordered]@{
                        enabled = [bool]$IsolateExternalDisplayRedirectors
                        openVRPathsPath = $OpenVRPathsPath
                        wouldBackupPath = if ($IsolateExternalDisplayRedirectors) { $openVRPathsBackupPath } else { $null }
                        targets = $isolationTargets
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
                $beforeHash = Get-HashOrNull $backupPath
                $openVRPathsBeforeHash = $null
                $openVRPathsIsolatedHash = $null
                $isolationMutation = $null
                if ($IsolateExternalDisplayRedirectors) {
                    if (-not (Test-Path -LiteralPath $OpenVRPathsPath -PathType Leaf)) { throw "OpenVR registration file does not exist: $OpenVRPathsPath" }
                    Copy-Item -LiteralPath $OpenVRPathsPath -Destination $openVRPathsBackupPath
                    $openVRPathsBeforeHash = Get-HashOrNull $openVRPathsBackupPath
                }
                try {
                    if ($IsolateExternalDisplayRedirectors) {
                        $isolationMutation = Disable-ExternalDriverRegistrations -Path $OpenVRPathsPath -Targets $isolationTargets
                        $isolatedInventory = Get-ExternalDriverInventory -Path $OpenVRPathsPath
                        if ($isolatedInventory.errors.Count -gt 0 -or $isolatedInventory.conflicts.Count -gt 0) {
                            throw 'External display-driver isolation did not produce a complete, conflict-free OpenVR inventory.'
                        }
                        foreach ($target in $isolationTargets) {
                            if (@($isolatedInventory.drivers | Where-Object { (Get-NormalizedPath ([string]$_.root)) -eq (Get-NormalizedPath ([string]$target.root)) }).Count -ne 0) {
                                throw "External display redirector remained registered after isolation: $($target.root)"
                            }
                        }
                        $openVRPathsIsolatedHash = Get-HashOrNull $OpenVRPathsPath
                    }
                    foreach ($section in @('steamvr', 'dashboard', 'driver_null', 'driver_codex_head_pose', 'TrackingOverrides')) {
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
                        externalDriverIsolation = [ordered]@{
                            enabled = [bool]$IsolateExternalDisplayRedirectors
                            openVRPathsPath = if ($IsolateExternalDisplayRedirectors) { [IO.Path]::GetFullPath($OpenVRPathsPath) } else { $null }
                            backupPath = if ($IsolateExternalDisplayRedirectors) { $openVRPathsBackupPath } else { $null }
                            sha256Before = $openVRPathsBeforeHash
                            sha256Isolated = $openVRPathsIsolatedHash
                            targets = $isolationTargets
                            mutation = $isolationMutation
                        }
                    }
                    Write-JsonAtomic -Path $receiptPath -Value $receipt
                }
                catch {
                    Copy-FileAtomic -Source $backupPath -Destination $SettingsPath
                    if ($IsolateExternalDisplayRedirectors -and (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) {
                        Copy-FileAtomic -Source $openVRPathsBackupPath -Destination $OpenVRPathsPath
                    }
                    throw "Null-HMD apply failed and every exact backup was restored. $($_.Exception.Message)"
                }
                $result = New-Result -Ok $true -State 'null-applied' -Data @{
                    settingsPath = $SettingsPath
                    backupPath = $backupPath
                    receiptPath = $receiptPath
                    settingsSha256Before = $beforeHash
                    settingsSha256Null = Get-HashOrNull $SettingsPath
                    effective = $afterEffective
                    externalDriverIsolation = $receipt['externalDriverIsolation']
                }
            }
        }
        else {
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Exact backup is missing: $backupPath" }
            if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw "Apply receipt is missing: $receiptPath" }
            $receipt = Read-JsonHashtable -Path $receiptPath
            $backupHash = Get-HashOrNull $backupPath
            if ($backupHash -ne $receipt['settingsSha256Before']) { throw 'The exact backup hash does not match the apply receipt.' }
            $isolation = if ($receipt.ContainsKey('externalDriverIsolation')) { $receipt['externalDriverIsolation'] } else { $null }
            $restoreExternalDrivers = $null -ne $isolation -and [bool]$isolation['enabled']
            if ($restoreExternalDrivers) {
                if ([IO.Path]::GetFullPath([string]$isolation['openVRPathsPath']) -ne [IO.Path]::GetFullPath($OpenVRPathsPath)) {
                    throw 'The requested OpenVR registration path does not match the apply receipt.'
                }
                if (-not (Test-Path -LiteralPath $openVRPathsBackupPath -PathType Leaf)) { throw "Exact OpenVR registration backup is missing: $openVRPathsBackupPath" }
                if ((Get-HashOrNull $openVRPathsBackupPath) -ne [string]$isolation['sha256Before']) { throw 'The exact OpenVR registration backup hash does not match the apply receipt.' }
                if ((Get-HashOrNull $OpenVRPathsPath) -ne [string]$isolation['sha256Isolated']) { throw 'The OpenVR registration file changed after isolation. Refusing to overwrite unclassified registration drift.' }
                foreach ($target in @($isolation['targets'])) {
                    if ((Get-HashOrNull ([string]$target['manifestPath'])) -ne [string]$target['manifestSha256']) {
                        throw "Suppressed driver manifest changed after apply: $($target['manifestPath'])"
                    }
                }
            }
            if ($WhatIf) {
                $result = New-Result -Ok $true -State 'dry-run' -Data @{
                    wouldRestore = $backupPath
                    settingsPath = $SettingsPath
                    expectedSha256 = $backupHash
                    backupRetained = $true
                    externalDriverIsolation = $isolation
                    wouldRestoreOpenVRPaths = if ($restoreExternalDrivers) { $openVRPathsBackupPath } else { $null }
                }
            }
            else {
                Copy-FileAtomic -Source $backupPath -Destination $SettingsPath
                if ($restoreExternalDrivers) { Copy-FileAtomic -Source $openVRPathsBackupPath -Destination $OpenVRPathsPath }
                $restoredHash = Get-HashOrNull $SettingsPath
                if ($restoredHash -ne $backupHash) { throw 'Restored SteamVR settings hash does not match the exact backup.' }
                if ($restoreExternalDrivers -and (Get-HashOrNull $OpenVRPathsPath) -ne [string]$isolation['sha256Before']) { throw 'Restored OpenVR registration hash does not match the exact backup.' }
                $result = New-Result -Ok $true -State 'restored' -Data @{
                    settingsPath = $SettingsPath
                    restoredSha256 = $restoredHash
                    backupPath = $backupPath
                    backupRetained = $true
                    externalDriverIsolation = $isolation
                    openVRPathsRestoredSha256 = if ($restoreExternalDrivers) { Get-HashOrNull $OpenVRPathsPath } else { $null }
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
