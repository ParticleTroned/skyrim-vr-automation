# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('inspect', 'set', 'qualify', 'install')]
    [string]$Command = 'inspect',

    [string]$MapName = 'Local\CSXVRHeadPose-v1',

    [Nullable[double]]$PositionX,
    [Nullable[double]]$EyeHeightMeters,
    [Nullable[double]]$PositionZ,
    [Nullable[double]]$YawDegrees,
    [Nullable[double]]$PitchDegrees,
    [Nullable[double]]$RollDegrees,
    [Nullable[bool]]$Enabled,

    [ValidateRange(0.25, 10.0)]
    [double]$MinimumEyeHeightMeters = 1.0,

    [ValidateRange(0.25, 10.0)]
    [double]$MaximumEyeHeightMeters = 2.5,

    [ValidateRange(100, 10000)]
    [int]$AcknowledgementTimeoutMilliseconds = 2000,

    [switch]$NoWait,

    [string]$DriverPackagePath,

    [string]$InstallRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CSX-VR-Automation\SteamVR\drivers\codex_head_pose' } else { $null }),

    [string]$PoseProbePath,

    [string]$VRPathRegPath = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64\vrpathreg.exe',

    [string]$OpenVRPathsPath = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'openvr\openvrpaths.vrpath' } else { $null }),

    [string]$EvidenceDirectory,

    [switch]$SkipOpenVRProbe,
    [switch]$Upgrade,

    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PoseMagic = 0x48505343
$script:PoseVersion = 1
$script:PoseSize = 88

function Get-HashOrNull([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
    return $null
}

function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function New-Result([bool]$Ok, [string]$State, $Data, [string[]]$Errors = @()) {
    [pscustomobject][ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $Ok
        state = $State
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        errors = @($Errors)
        data = $Data
    }
}

function Open-PoseMap([IO.MemoryMappedFiles.MemoryMappedFileRights]$Rights) {
    return [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($MapName, $Rights)
}

function Read-PoseState {
    $mapping = $null
    $view = $null
    try {
        $mapping = Open-PoseMap -Rights ([IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
        $view = $mapping.CreateViewAccessor(0, $script:PoseSize, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $firstSequence = $view.ReadUInt64(8)
            if (($firstSequence % 2) -ne 0) {
                [Threading.Thread]::Sleep(1)
                continue
            }
            $state = [ordered]@{
                magic = $view.ReadUInt32(0)
                version = $view.ReadUInt16(4)
                size = $view.ReadUInt16(6)
                requestedSequence = $firstSequence
                appliedSequence = $view.ReadUInt64(16)
                status = $view.ReadUInt32(24)
                enabled = ($view.ReadUInt32(28) -band 1) -eq 1
                positionX = $view.ReadDouble(32)
                eyeHeightMeters = $view.ReadDouble(40)
                positionZ = $view.ReadDouble(48)
                quaternionW = $view.ReadDouble(56)
                quaternionX = $view.ReadDouble(64)
                quaternionY = $view.ReadDouble(72)
                quaternionZ = $view.ReadDouble(80)
            }
            $secondSequence = $view.ReadUInt64(8)
            if ($firstSequence -eq $secondSequence -and ($secondSequence % 2) -eq 0) {
                $state['available'] = $true
                $state['stable'] = $true
                $state['protocolValid'] = $state.magic -eq $script:PoseMagic -and $state.version -eq $script:PoseVersion -and $state.size -eq $script:PoseSize
                $state['acknowledged'] = $state.requestedSequence -gt 0 -and $state.appliedSequence -eq $state.requestedSequence -and $state.status -eq 1
                $state['eyeHeightQualified'] = $state.eyeHeightMeters -ge $MinimumEyeHeightMeters -and $state.eyeHeightMeters -le $MaximumEyeHeightMeters
                $state['qualified'] = $state.protocolValid -and $state.acknowledged -and $state.eyeHeightQualified -and $state.enabled
                return [pscustomobject]$state
            }
        }
        throw 'The shared pose changed continuously and could not be read atomically.'
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; error = 'The head-pose provider is not running.' }
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
    }
}

function Convert-EulerToQuaternion([double]$Yaw, [double]$Pitch, [double]$Roll) {
    $halfYaw = $Yaw * [Math]::PI / 360.0
    $halfPitch = $Pitch * [Math]::PI / 360.0
    $halfRoll = $Roll * [Math]::PI / 360.0
    $cy = [Math]::Cos($halfYaw); $sy = [Math]::Sin($halfYaw)
    $cp = [Math]::Cos($halfPitch); $sp = [Math]::Sin($halfPitch)
    $cr = [Math]::Cos($halfRoll); $sr = [Math]::Sin($halfRoll)
    return @(
        ($cy * $cp * $cr + $sy * $sp * $sr)
        ($cy * $sp * $cr + $sy * $cp * $sr)
        ($sy * $cp * $cr - $cy * $sp * $sr)
        ($cy * $cp * $sr - $sy * $sp * $cr)
    )
}

function Set-PoseState {
    $current = Read-PoseState
    if (-not $current.available) { throw $current.error }
    if (-not $current.protocolValid) { throw 'The running head-pose provider uses an incompatible shared-memory contract.' }

    $x = if ($null -ne $PositionX) { [double]$PositionX } else { [double]$current.positionX }
    $y = if ($null -ne $EyeHeightMeters) { [double]$EyeHeightMeters } else { [double]$current.eyeHeightMeters }
    $z = if ($null -ne $PositionZ) { [double]$PositionZ } else { [double]$current.positionZ }
    $active = if ($null -ne $Enabled) { [bool]$Enabled } else { [bool]$current.enabled }
    foreach ($value in @($x, $y, $z)) {
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or [Math]::Abs($value) -gt 1000.0) {
            throw 'Pose positions must be finite and within 1000 metres of the origin.'
        }
    }

    $orientationSupplied = $null -ne $YawDegrees -or $null -ne $PitchDegrees -or $null -ne $RollDegrees
    $quaternion = if ($orientationSupplied) {
        Convert-EulerToQuaternion `
            -Yaw $(if ($null -ne $YawDegrees) { [double]$YawDegrees } else { 0.0 }) `
            -Pitch $(if ($null -ne $PitchDegrees) { [double]$PitchDegrees } else { 0.0 }) `
            -Roll $(if ($null -ne $RollDegrees) { [double]$RollDegrees } else { 0.0 })
    }
    else { @($current.quaternionW, $current.quaternionX, $current.quaternionY, $current.quaternionZ) }

    $mapping = $null
    $view = $null
    try {
        $mapping = Open-PoseMap -Rights ([IO.MemoryMappedFiles.MemoryMappedFileRights]::ReadWrite)
        $view = $mapping.CreateViewAccessor(0, $script:PoseSize, [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
        $baseSequence = [uint64]$current.requestedSequence
        if (($baseSequence % 2) -ne 0) { $baseSequence++ }
        $oddSequence = $baseSequence + 1
        $requestedSequence = $baseSequence + 2
        $view.Write(8, [uint64]$oddSequence)
        $view.Write(24, [uint32]0)
        $view.Write(28, [uint32]$(if ($active) { 1 } else { 0 }))
        $view.Write(32, $x); $view.Write(40, $y); $view.Write(48, $z)
        $view.Write(56, [double]$quaternion[0]); $view.Write(64, [double]$quaternion[1])
        $view.Write(72, [double]$quaternion[2]); $view.Write(80, [double]$quaternion[3])
        $view.Flush()
        $view.Write(8, [uint64]$requestedSequence)
        $view.Flush()
    }
    finally {
        if ($view) { $view.Dispose() }
        if ($mapping) { $mapping.Dispose() }
    }

    if ($NoWait) {
        return New-Result -Ok $true -State 'pose-submitted' -Data @{ requestedSequence = $requestedSequence; acknowledged = $false }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($AcknowledgementTimeoutMilliseconds)
    do {
        [Threading.Thread]::Sleep(10)
        $observed = Read-PoseState
        if ($observed.available -and $observed.appliedSequence -eq $requestedSequence) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $observed.available -or $observed.appliedSequence -ne $requestedSequence) {
        return New-Result -Ok $false -State 'pose-acknowledgement-timeout' -Data @{ requestedSequence = $requestedSequence; observed = $observed } -Errors @('The provider did not acknowledge the pose before the bounded deadline.')
    }
    if ($observed.status -ne 1) {
        return New-Result -Ok $false -State 'pose-rejected' -Data @{ requestedSequence = $requestedSequence; observed = $observed } -Errors @('The provider rejected the pose as invalid.')
    }
    return New-Result -Ok $true -State 'pose-applied' -Data @{ requestedSequence = $requestedSequence; pose = $observed }
}

function Invoke-PoseProbe {
    $resolvedProbe = if (-not [string]::IsNullOrWhiteSpace($PoseProbePath)) { $PoseProbePath } elseif (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { Join-Path $InstallRoot 'tools\csx_openvr_pose_probe.exe' } else { $null }
    if ([string]::IsNullOrWhiteSpace($resolvedProbe) -or -not (Test-Path -LiteralPath $resolvedProbe -PathType Leaf)) {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $resolvedProbe; error = 'The independent OpenVR pose probe is not installed.' }
    }
    try {
        $output = @(& $resolvedProbe 2>&1)
        $exitCode = $LASTEXITCODE
        $payload = ($output -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
        return [pscustomobject][ordered]@{
            available = $true
            qualified = $exitCode -eq 0 -and $payload.ok -and $payload.standing.connected -and $payload.standing.valid -and [double]$payload.standing.position[1] -ge $MinimumEyeHeightMeters -and [double]$payload.standing.position[1] -le $MaximumEyeHeightMeters
            probePath = $resolvedProbe
            exitCode = $exitCode
            observation = $payload
        }
    }
    catch {
        return [pscustomobject][ordered]@{ available = $false; qualified = $false; probePath = $resolvedProbe; error = $_.Exception.Message }
    }
}

function Install-Driver {
    if ([string]::IsNullOrWhiteSpace($DriverPackagePath)) {
        $bundledPackage = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'drivers\codex_head_pose'
        if (Test-Path -LiteralPath $bundledPackage -PathType Container) {
            $DriverPackagePath = $bundledPackage
        }
        else {
            throw 'install requires -DriverPackagePath because no bundled driver package is present.'
        }
    }
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) { throw 'The stable driver install root could not be resolved.' }
    if (-not (Test-Path -LiteralPath $VRPathRegPath -PathType Leaf)) { throw "vrpathreg.exe does not exist: $VRPathRegPath" }
    foreach ($name in @('vrserver', 'vrmonitor', 'vrcompositor', 'vrstartup')) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { throw 'SteamVR must be stopped before installing the head-pose driver.' }
    }
    $source = [IO.Path]::GetFullPath($DriverPackagePath)
    foreach ($relative in @('driver.vrdrivermanifest', 'bin\win64\driver_codex_head_pose.dll', 'resources\settings\default.vrsettings', 'tools\csx_openvr_pose_probe.exe', 'tools\openvr_api.dll', 'licenses\OpenVR-LICENSE.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative) -PathType Leaf)) { throw "Driver package is missing $relative" }
    }
    $target = [IO.Path]::GetFullPath($InstallRoot)
    $previousInstall = $null
    if (Test-Path -LiteralPath $target) {
        $marker = Join-Path $target '.csx-vr-automation-driver.json'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Refusing to replace an unowned driver directory: $target" }
        $owned = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($owned.driverName -ne 'codex_head_pose') { throw "The existing driver marker does not identify codex_head_pose: $marker" }
        if (-not $Upgrade) { throw "The driver is already installed. Use -Upgrade to retain and replace the owned installation: $target" }
        $previousInstall = "$target.previous-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))"
        if (Test-Path -LiteralPath $previousInstall) { throw "The retained upgrade path already exists: $previousInstall" }
    }

    $parent = Split-Path -Parent $target
    $staging = "$target.staging-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    try {
        Copy-Item -LiteralPath $source -Destination $staging -Recurse
        $marker = [ordered]@{
            schemaVersion = 1
            driverName = 'codex_head_pose'
            installedUtc = [DateTime]::UtcNow.ToString('o')
            sourcePackage = $source
            dllSha256 = Get-HashOrNull (Join-Path $staging 'bin\win64\driver_codex_head_pose.dll')
            poseProbeSha256 = Get-HashOrNull (Join-Path $staging 'tools\csx_openvr_pose_probe.exe')
        }
        Write-JsonAtomic -Path (Join-Path $staging '.csx-vr-automation-driver.json') -Value $marker
        if ($previousInstall) { Move-Item -LiteralPath $target -Destination $previousInstall }
        Move-Item -LiteralPath $staging -Destination $target
        $findOutput = & $VRPathRegPath finddriver codex_head_pose 2>&1
        if ($LASTEXITCODE -eq 1) {
            $registrationOutput = & $VRPathRegPath adddriver $target 2>&1
            if ($LASTEXITCODE -ne 0) { throw "vrpathreg adddriver failed ($LASTEXITCODE): $($registrationOutput -join ' ')" }
            $findOutput = & $VRPathRegPath finddriver codex_head_pose 2>&1
        }
        if ($LASTEXITCODE -ne 0) { throw "The installed driver registration could not be found exactly once ($LASTEXITCODE): $($findOutput -join ' ')" }
        $receipt = [ordered]@{
            schemaVersion = 1
            installedUtc = [DateTime]::UtcNow.ToString('o')
            installRoot = $target
            manifestSha256 = Get-HashOrNull (Join-Path $target 'driver.vrdrivermanifest')
            dllSha256 = Get-HashOrNull (Join-Path $target 'bin\win64\driver_codex_head_pose.dll')
            poseProbeSha256 = Get-HashOrNull (Join-Path $target 'tools\csx_openvr_pose_probe.exe')
            previousInstallRoot = $previousInstall
            openVrPathsPath = $OpenVRPathsPath
            openVrPathsSha256 = Get-HashOrNull $OpenVRPathsPath
            registration = @($findOutput)
        }
        if ($EvidenceDirectory) {
            New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
            $receiptPath = Join-Path $EvidenceDirectory ("steamvr-head-pose-install-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).receipt.json")
            Write-JsonAtomic -Path $receiptPath -Value $receipt
            $receipt['receiptPath'] = $receiptPath
        }
        return New-Result -Ok $true -State $(if ($previousInstall) { 'driver-upgraded' } else { 'driver-installed' }) -Data $receipt
    }
    catch {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        if ($previousInstall -and -not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $previousInstall)) {
            Move-Item -LiteralPath $previousInstall -Destination $target
        }
        throw
    }
}

try {
    switch ($Command) {
        'inspect' {
            $pose = Read-PoseState
            $result = New-Result -Ok $true -State $(if ($pose.available) { 'provider-running' } else { 'provider-stopped' }) -Data @{ mapName = $MapName; pose = $pose }
        }
        'qualify' {
            $pose = Read-PoseState
            $applicationPose = if ($SkipOpenVRProbe) { [pscustomobject][ordered]@{ available = $false; qualified = $true; skipped = $true } } else { Invoke-PoseProbe }
            $qualified = [bool]$pose.qualified -and [bool]$applicationPose.qualified
            $qualificationErrors = @()
            if (-not $pose.qualified) { $qualificationErrors += 'The running provider does not expose an acknowledged standing head pose within the configured height range.' }
            if (-not $applicationPose.qualified) { $qualificationErrors += 'The independent OpenVR client did not observe a valid standing HMD pose within the configured height range.' }
            $result = New-Result -Ok $qualified -State $(if ($qualified) { 'head-pose-qualified' } else { 'head-pose-not-qualified' }) -Data @{ mapName = $MapName; pose = $pose; applicationPose = $applicationPose; minimumEyeHeightMeters = $MinimumEyeHeightMeters; maximumEyeHeightMeters = $MaximumEyeHeightMeters } -Errors $qualificationErrors
        }
        'set' { $result = Set-PoseState }
        'install' { $result = Install-Driver }
    }
}
catch {
    $result = New-Result -Ok $false -State 'blocked' -Data @{ mapName = $MapName; installRoot = $InstallRoot } -Errors @($_.Exception.Message)
}

$jsonParameters = @{ InputObject = $result; Depth = 16 }
if ($Compact) { $jsonParameters['Compress'] = $true }
ConvertTo-Json @jsonParameters
if (-not $result.ok -and -not $NoExit) { exit 2 }
