# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CSXPropertyValue {
    param($InputObject, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        return $(if ($InputObject.Contains($Name)) { $InputObject[$Name] } else { $Default })
    }
    $property = $InputObject.PSObject.Properties[$Name]
    return $(if ($property) { $property.Value } else { $Default })
}

function Get-CSXPathValue {
    param($InputObject, [Parameter(Mandatory)][string]$Path, $Default = $null)
    $value = $InputObject
    foreach ($part in $Path.Split('.')) {
        $sentinel = [object]::new()
        $next = Get-CSXPropertyValue -InputObject $value -Name $part -Default $sentinel
        if ([object]::ReferenceEquals($next, $sentinel)) { return $Default }
        $value = $next
    }
    return $value
}

function Write-CSXJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [int]$Depth = 80)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $fullPath
}

function Write-CSXTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Value)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$fullPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Value, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
    return $fullPath
}

function Get-CSXFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Evidence file does not exist: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CSXObjectSha256 {
    param([Parameter(Mandatory)]$Value)
    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Assert-CSXProtocol {
    param([Parameter(Mandatory)]$Protocol)
    if ([string]$Protocol.schema -ne 'csx-render-scale-pr-v1' -or [int]$Protocol.protocolRevision -ne 1) {
        throw 'The protocol must be csx-render-scale-pr-v1 revision 1.'
    }
    if ([string]$Protocol.requiredMethodsCommit -ne 'b46edeaed14c41ad41225641c3a4943f1db25db6') {
        throw 'The protocol does not bind the required DLSS trace methods commit.'
    }
    if ([string]$Protocol.fixtureManifestSchema -ne 'csx-render-scale-fixture-v1' -or [int]$Protocol.thresholds.stressRecordSchemaVersion -ne 13) {
        throw 'The protocol must bind fixture schema v1 and stress-record schema v13.'
    }
    if ([int]$Protocol.timeBudget.orchestrationMs -ne 600000 -or [int]$Protocol.timeBudget.recoveryMs -ne 30000 -or
        [int]$Protocol.timeBudget.recoveryMinimumElapsedMs -ne 29900 -or [int]$Protocol.timeBudget.recoveryMaximumElapsedMs -ne 35000) {
        throw 'The protocol must preserve the 600 second cap and 30 second recovery barriers.'
    }
    if ([int]$Protocol.cocAssay.transitionCount -ne 20) { throw 'COC assay must contain exactly 20 transitions.' }
    if ([string]$Protocol.fixture.startCellEditorId -ne 'WindhelmExterior01' -or
        [string]$Protocol.fixture.interiorCellEditorId -ne 'WhiterunDragonsreach' -or
        [string]$Protocol.cocAssay.firstTarget -ne 'WhiterunDragonsreach' -or
        [string]$Protocol.cocAssay.secondTarget -ne 'WindhelmExterior01') {
        throw 'Protocol revision 1 requires the exact Windhelm/Dragonsreach COC fixture.'
    }
    $foveation = $Protocol.fixture.foveation
    if (-not [bool]$foveation.foveatedVendorDispatch -or [double]$foveation.foveatedCenterArea -ne 0.3 -or
        -not [bool]$foveation.peripheryTAAEnable -or [double]$foveation.peripheryTAACenterArea -ne 0.3 -or
        [double]$foveation.peripheryTAAOuterScale -ne 0.7) {
        throw 'Protocol revision 1 requires foveation 0.3 plus periphery TAA 0.3/0.7.'
    }
    $nvidiaInterior = $Protocol.fixture.profiles.nvidiaInterior
    $amdInterior = $Protocol.fixture.profiles.amdInterior
    $sharedExterior = $Protocol.fixture.profiles.sharedExterior
    if ([string]$nvidiaInterior.method -ne 'dlss' -or [int]$nvidiaInterior.qualityModeValue -ne 0 -or
        [bool]$nvidiaInterior.renderScaleMode -or [string]$nvidiaInterior.dlssProfile -ne 'K' -or
        [int]$nvidiaInterior.dlssPresetValue -ne 1 -or [string]$amdInterior.method -ne 'fsr' -or
        [int]$amdInterior.qualityModeValue -ne 0 -or [bool]$amdInterior.renderScaleMode -or
        [string]$sharedExterior.method -ne 'fsr' -or [int]$sharedExterior.qualityModeValue -ne 1 -or
        -not [bool]$sharedExterior.renderScaleMode) {
        throw 'Protocol revision 1 requires exact NVIDIA DLAA/K, AMD AA, and shared FSR Hoshipa profiles.'
    }
    if ((@($Protocol.cocAssay.diagnostics) -join ',') -ne 'render_scale_stress,cpu_performance' -or
        [int]$Protocol.menuAssay.traceReadLimit -ne 16) {
        throw 'Protocol revision 1 requires both diagnostics and the exact DLSS trace read bound.'
    }
    foreach ($matrixName in @('nvidiaMatrix', 'amdMatrix')) {
        $matrix = @($Protocol.menuAssay.$matrixName)
        if ($matrix.Count -ne 25) { throw "$matrixName must contain exactly 25 transitions." }
        for ($i = 0; $i -lt $matrix.Count; $i++) {
            if ([int]$matrix[$i].ordinal -ne $i + 1) { throw "$matrixName ordinals must be contiguous from 1 to 25." }
            $labels = @('native_aa', 'hoshipa', 'ultra_quality', 'quality', 'balanced', 'performance', 'ultra_performance')
            $quality = [int]$matrix[$i].qualityModeValue
            if ($quality -lt 0 -or $quality -gt 6 -or [string]$matrix[$i].qualityMode -ne $labels[$quality] -or [bool]$matrix[$i].renderScaleMode -ne ($quality -ne 0)) {
                throw "$matrixName has incoherent quality label/value/render-scale state at ordinal $($i + 1)."
            }
            if ($i -gt 0) {
                $left = "$($matrix[$i - 1].method)|$($matrix[$i - 1].qualityModeValue)|$($matrix[$i - 1].renderScaleMode)"
                $right = "$($matrix[$i].method)|$($matrix[$i].qualityModeValue)|$($matrix[$i].renderScaleMode)"
                if ($left -eq $right) { throw "$matrixName contains an adjacent duplicate at ordinal $($i + 1)." }
            }
        }
        $last = $matrix[-1]
        if ($last.method -ne 'fsr' -or $last.qualityMode -ne 'hoshipa' -or -not [bool]$last.renderScaleMode) {
            throw "$matrixName must finish at FSR Hoshipa with render scale active."
        }
    }
    $canonicalNvidia = @(
        'dlss|0','dlss|1','dlss|2','dlss|3','dlss|4','dlss|5','dlss|6','fsr|6','fsr|5','fsr|4','fsr|3','fsr|2','fsr|1','fsr|0','dlss|0','fsr|0','fsr|1','dlss|1','dlss|6','fsr|6','fsr|0','dlss|0','dlss|1','fsr|0','fsr|1'
    )
    $canonicalAmd = @(
        'fsr|0','fsr|1','fsr|2','fsr|3','fsr|4','fsr|5','fsr|6','fsr|0','fsr|6','fsr|0','fsr|1','fsr|0','fsr|2','fsr|3','fsr|0','fsr|4','fsr|0','fsr|5','fsr|0','fsr|6','fsr|1','fsr|6','fsr|0','fsr|6','fsr|1'
    )
    $actualNvidia = @($Protocol.menuAssay.nvidiaMatrix | ForEach-Object { "$($_.method)|$([int]$_.qualityModeValue)" })
    $actualAmd = @($Protocol.menuAssay.amdMatrix | ForEach-Object { "$($_.method)|$([int]$_.qualityModeValue)" })
    if (($actualNvidia -join ',') -ne ($canonicalNvidia -join ',') -or ($actualAmd -join ',') -ne ($canonicalAmd -join ',')) {
        throw 'Protocol revision 1 requires the exact canonical NVIDIA and AMD menu orders.'
    }
    $nvidiaMethods = @($Protocol.menuAssay.nvidiaMatrix.method | Sort-Object -Unique)
    if ('dlss' -notin $nvidiaMethods -or 'fsr' -notin $nvidiaMethods) { throw 'NVIDIA matrix must exercise DLSS and FSR.' }
    if (@($Protocol.menuAssay.amdMatrix | Where-Object method -ne 'fsr').Count -ne 0) { throw 'AMD matrix must be FSR-only.' }
    if ([int]$Protocol.visualAssay.replicates -ne 3 -or [int]$Protocol.visualAssay.frameCount -ne 16 -or
        [string]$Protocol.visualAssay.schedule.basis -ne 'wall_clock' -or
        [int]$Protocol.visualAssay.schedule.intervalMs -ne 4000 -or
        [int]$Protocol.visualAssay.schedule.startDelayMs -ne 0 -or
        [string]$Protocol.visualAssay.schedule.pausePolicy -ne 'hold' -or
        [string]$Protocol.visualAssay.source.kind -ne 'hmd_submission' -or
        [string]$Protocol.visualAssay.source.fallback -ne 'reject' -or
        (@($Protocol.visualAssay.outputs) -join ',') -ne 'side_by_side,left_eye,right_eye' -or
        [string]$Protocol.visualAssay.format -ne 'png' -or
        [string]$Protocol.visualAssay.colourContract -ne 'sdr_srgb' -or
        [string]$Protocol.visualAssay.overwrite -ne 'never' -or
        (@($Protocol.visualAssay.reviewOrdinals) -join ',') -ne '1,8,16') {
        throw 'Visual assay must be three 16-frame, one-minute sequences reviewed at 1/8/16.'
    }
    if (-not [bool]$Protocol.thresholds.prBaselineRequired -or
        [int]$Protocol.thresholds.visualRequestedFramesPerReplicate -ne 16 -or
        [int]$Protocol.thresholds.visualWrittenFramesPerReplicate -ne 16 -or
        [int]$Protocol.thresholds.visualDroppedFramesPerReplicate -ne 0 -or
        [int]$Protocol.thresholds.visualFailedFramesPerReplicate -ne 0 -or
        [int]$Protocol.thresholds.visualMinimumElapsedMsPerReplicate -ne 59000 -or
        [int]$Protocol.thresholds.visualMaximumElapsedMsPerReplicate -ne 65000) {
        throw 'The protocol must require a PR baseline and exact 16/0 visual capture counts.'
    }
    $allocated = [int]$Protocol.timeBudget.cocAssayMs + [int]$Protocol.timeBudget.menuAssayMs +
        [int]$Protocol.timeBudget.visualAssayMs + 2 * [int]$Protocol.timeBudget.recoveryMs
    if ($allocated -gt [int]$Protocol.timeBudget.orchestrationMs) { throw 'Assay allocations exceed the orchestration cap.' }
    $canonicalRevisionOneSha256 = 'ab103791639ef80776272ac73cacc2cb85e98adddaa63fa47d1a6154bcca121d'
    if ((Get-CSXObjectSha256 -Value $Protocol) -ne $canonicalRevisionOneSha256) {
        throw 'The revision-1 protocol definition changed; publish a new protocol revision instead.'
    }
}

function Get-CSXQualificationProtocol {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Protocol does not exist: $fullPath" }
    $raw = Get-Content -LiteralPath $fullPath -Raw
    $protocol = $raw | ConvertFrom-Json -Depth 100
    Assert-CSXProtocol -Protocol $protocol
    return [pscustomobject][ordered]@{
        path = $fullPath
        sha256 = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        protocol = $protocol
    }
}

function Get-CSXFixtureManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Fixture manifest does not exist: $fullPath" }
    $manifest = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json -Depth 50
    if ([string]$manifest.schema -ne 'csx-render-scale-fixture-v1') { throw 'Fixture manifest schema must be csx-render-scale-fixture-v1.' }
    foreach ($pathName in @(
        'fixtureId', 'save.id', 'save.sha256', 'camera.id', 'camera.configurationSha256',
        'vrFpsStabilizer.version', 'vrFpsStabilizer.configurationSha256',
        'gpu.vendor', 'gpu.deviceId', 'gpu.driverVersion',
        'hmd.model', 'hmd.runtime', 'hmd.runtimeVersion'
    )) {
        $value = [string](Get-CSXPathValue $manifest $pathName)
        if ($value -notmatch '\S') { throw "Fixture manifest requires '$pathName'." }
        if ($value -match '^(replace[-_ ]|example$|placeholder$|unknown$|todo$|changeme$)') { throw "Fixture manifest '$pathName' still contains an example placeholder." }
    }
    foreach ($pathName in @('save.sha256', 'camera.configurationSha256', 'vrFpsStabilizer.configurationSha256')) {
        $hash = [string](Get-CSXPathValue $manifest $pathName)
        if ($hash -notmatch '^[A-Fa-f0-9]{64}$' -or $hash -match '^0{64}$') { throw "Fixture manifest '$pathName' must be a real, nonzero SHA-256." }
    }
    if (-not [string]::Equals([string]$manifest.gpu.vendor, $GpuVendor, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture GPU vendor '$($manifest.gpu.vendor)' does not match requested matrix '$GpuVendor'."
    }
    $refreshHz = [double](Get-CSXPathValue $manifest 'hmd.refreshHz' 0)
    if (-not [double]::IsFinite($refreshHz) -or $refreshHz -le 0) { throw "Fixture manifest requires a positive finite 'hmd.refreshHz'." }
    return [pscustomobject][ordered]@{
        path = $fullPath
        sha256 = Get-CSXFileSha256 $fullPath
        manifest = $manifest
    }
}

function ConvertTo-CSXHashtable {
    param([Parameter(Mandatory)]$Value)
    return ($Value | ConvertTo-Json -Depth 80 -Compress | ConvertFrom-Json -AsHashtable -Depth 80)
}

function Add-CSXExactRuntimeToProfile {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime)
    $method = [string](Get-CSXPropertyValue $Profile 'method')
    if ($method -notin @('dlss', 'fsr')) { throw "Unsupported qualification profile method '$method'." }
    $qualityMode = Get-CSXPropertyValue $Profile 'qualityModeValue'
    if ($null -eq $qualityMode) { throw 'Qualification profiles require numeric qualityModeValue.' }
    $target = [ordered]@{
        method = $method
        qualityMode = [int]$qualityMode
        renderScaleMode = [bool](Get-CSXPropertyValue $Profile 'renderScaleMode')
    }
    if ($method -eq 'dlss') {
        $profile = [string](Get-CSXPropertyValue $Profile 'dlssProfile' 'K')
        if ($profile -notin @('J', 'K', 'L', 'M', 'F', 'E')) { throw "Unsupported DLSS profile '$profile'." }
        $target['dlssProfile'] = $profile
    }
    else { $target['fsrRuntime'] = $FsrRuntime }
    return $target
}

function Get-CSXFoveationTarget {
    param([Parameter(Mandatory)]$Protocol)
    $source = $Protocol.fixture.foveation
    return [ordered]@{
        foveatedVendorDispatch = [bool]$source.foveatedVendorDispatch
        foveatedCenterArea = [double]$source.foveatedCenterArea
        peripheryTAAEnable = [bool]$source.peripheryTAAEnable
        peripheryTAACenterArea = [double]$source.peripheryTAACenterArea
        peripheryTAAOuterScale = [double]$source.peripheryTAAOuterScale
    }
}

function New-CSXCocScenario {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$RunId
    )
    $foveation = Get-CSXFoveationTarget $Protocol
    $interior = if ($GpuVendor -eq 'NVIDIA') { $Protocol.fixture.profiles.nvidiaInterior } else { $Protocol.fixture.profiles.amdInterior }
    $exterior = $Protocol.fixture.profiles.sharedExterior
    $steps = [Collections.Generic.List[object]]::new()
    for ($ordinal = 1; $ordinal -le [int]$Protocol.cocAssay.transitionCount; $ordinal++) {
        $isInterior = ($ordinal % 2) -eq 1
        $cell = if ($isInterior) { [string]$Protocol.fixture.interiorCellEditorId } else { [string]$Protocol.fixture.startCellEditorId }
        $profile = Add-CSXExactRuntimeToProfile -Profile $(if ($isInterior) { $interior } else { $exterior }) -FsrRuntime $FsrRuntime
        $transitionId = [uint64]$ordinal
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-begin"
            args = [ordered]@{ action = 'qualification_begin'; transitionId = $transitionId; expectedBuildId = $ExpectedBuildId }
        })
        $steps.Add([ordered]@{
            tool = 'console'
            label = "coc-$($ordinal.ToString('D2'))-dispatch"
            args = [ordered]@{ action = 'exec'; command = "coc $cell"; capture = $false }
        })
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'
            label = "coc-$($ordinal.ToString('D2'))-wait"
            args = [ordered]@{
                action = 'qualification_wait'
                transitionId = $transitionId
                timeoutMs = [int]$Protocol.timeBudget.cocTransitionMs
                expectedCellEditorId = $cell
                target = $profile
                foveation = $foveation
                expectedBuildId = $ExpectedBuildId
            }
        })
    }
    return [ordered]@{ action = 'run'; async = $false; steps = @($steps); continueOnError = $false }
}

function New-CSXMenuScenario {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$ExpectedCellEditorId,
        [Parameter(Mandatory)][string]$RunId
    )
    $matrixName = if ($GpuVendor -eq 'NVIDIA') { 'nvidiaMatrix' } else { 'amdMatrix' }
    $matrix = @($Protocol.menuAssay.$matrixName)
    $foveation = Get-CSXFoveationTarget $Protocol
    $steps = [Collections.Generic.List[object]]::new()
    $steps.Add([ordered]@{
        tool = 'communityshaders.renderscale'; label = 'menu-dlss_trace_status-preflight'
        args = [ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $ExpectedBuildId }
    })
    if ($GpuVendor -eq 'AMD') {
        foreach ($action in @('dlss_trace_reset', 'dlss_trace_start', 'dlss_trace_stop')) {
            $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "amd-capability-$action"; args = [ordered]@{ action = $action; expectedBuildId = $ExpectedBuildId } })
        }
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = 'amd-capability-dlss_trace_read'
            args = [ordered]@{ action = 'dlss_trace_read'; afterSequence = 0; limit = [int]$Protocol.menuAssay.traceReadLimit; expectedBuildId = $ExpectedBuildId }
        })
    }
    foreach ($entry in $matrix) {
        $ordinal = [int]$entry.ordinal
        $prefix = "menu-$($ordinal.ToString('D2'))"
        $isDLSS = [string]$entry.method -eq 'dlss'
        if ($isDLSS) {
            foreach ($action in @('dlss_trace_reset', 'dlss_trace_start')) {
                $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "$prefix-$action"; args = [ordered]@{ action = $action; expectedBuildId = $ExpectedBuildId } })
            }
        }
        $transitionId = [uint64](100 + $ordinal)
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = "$prefix-begin"
            args = [ordered]@{ action = 'qualification_begin'; transitionId = $transitionId; expectedBuildId = $ExpectedBuildId }
        })
        $apply = [ordered]@{
            action = 'apply'; method = [string]$entry.method; enabled = [bool]$entry.renderScaleMode
            qualityMode = [int]$entry.qualityModeValue; expectedBuildId = $ExpectedBuildId
        }
        if ($isDLSS) { $apply['dlssPreset'] = 1 }
        $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "$prefix-apply"; args = $apply })
        $target = Add-CSXExactRuntimeToProfile -Profile $entry -FsrRuntime $FsrRuntime
        $steps.Add([ordered]@{
            tool = 'communityshaders.renderscale'; label = "$prefix-wait"
            args = [ordered]@{
                action = 'qualification_wait'; transitionId = $transitionId
                timeoutMs = [int]$Protocol.timeBudget.menuTransitionMs
                expectedCellEditorId = $ExpectedCellEditorId; target = $target
                foveation = $foveation; expectedBuildId = $ExpectedBuildId
            }
        })
        if ($isDLSS) {
            $steps.Add([ordered]@{ tool = 'communityshaders.renderscale'; label = "$prefix-dlss_trace_stop"; args = [ordered]@{ action = 'dlss_trace_stop'; expectedBuildId = $ExpectedBuildId } })
            $steps.Add([ordered]@{
                tool = 'communityshaders.renderscale'; label = "$prefix-dlss_trace_read"
                args = [ordered]@{ action = 'dlss_trace_read'; afterSequence = 0; limit = [int]$Protocol.menuAssay.traceReadLimit; expectedBuildId = $ExpectedBuildId }
            })
        }
    }
    return [pscustomobject][ordered]@{ matrixName = $matrixName; matrix = $matrix; scenario = [ordered]@{ action = 'run'; async = $false; steps = @($steps); continueOnError = $false } }
}

function New-CSXRecoveryScenario {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$ExpectedBuildId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('fsr3', 'fsr4')][string]$FsrRuntime,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$RecoveryLabel
    )
    return [ordered]@{
        action = 'run'
        async = $false
        steps = @(
            [ordered]@{ wait = [int]$Protocol.timeBudget.recoveryMs; label = "$RecoveryLabel-recovery-30000ms" },
            [ordered]@{
                tool = 'inspect'; label = "$RecoveryLabel-recovery-scene"
                args = [ordered]@{ kind = 'scene' }
            },
            [ordered]@{
                tool = 'inspect'; label = "$RecoveryLabel-recovery-health"
                args = [ordered]@{ kind = 'health' }
            },
            [ordered]@{
                tool = 'communityshaders.renderscale'; label = "$RecoveryLabel-recovery-qualification-status"
                args = [ordered]@{ action = 'qualification_status'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.renderscale'; label = "$RecoveryLabel-recovery-dlss-trace-status"
                args = [ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.renderscale'; label = "$RecoveryLabel-recovery-renderscale-status"
                args = [ordered]@{ action = 'status'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.upscaling_api'; label = "$RecoveryLabel-recovery-upscaling-snapshot"
                args = [ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$RunId-$RecoveryLabel-recovery-upscaling"; action = 'snapshot'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.feature_api'; label = "$RecoveryLabel-recovery-feature-settings"
                args = [ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$RunId-$RecoveryLabel-recovery-settings"; action = 'settings'; featureShortName = 'Upscaling'; expectedBuildId = $ExpectedBuildId }
            },
            [ordered]@{
                tool = 'communityshaders.screenshot'; label = "$RecoveryLabel-recovery-screenshot-status"
                args = [ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$RunId-$RecoveryLabel-recovery-screenshot"; action = 'status' }
            }
        )
        continueOnError = $false
        expected = [ordered]@{
            cellEditorId = [string]$Protocol.fixture.startCellEditorId
            target = Add-CSXExactRuntimeToProfile -Profile $Protocol.fixture.profiles.sharedExterior -FsrRuntime $FsrRuntime
            foveation = Get-CSXFoveationTarget $Protocol
        }
    }
}

function New-CSXVisualSequenceRequest {
    param(
        [Parameter(Mandatory)]$Protocol,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateRange(1, 3)][int]$Replicate,
        [Parameter(Mandatory)][string]$DestinationDirectory
    )
    $encoding = [ordered]@{ format = [string]$Protocol.visualAssay.format; colourContract = [string]$Protocol.visualAssay.colourContract }
    $outputs = @($Protocol.visualAssay.outputs | ForEach-Object {
        [ordered]@{ view = [string]$_; encoding = $encoding; nameSuffix = ([string]$_ -replace '_', '-') }
    })
    return [ordered]@{
        contractMajor = 1; clientId = 'csx-render-scale-qualification'
        commandId = "$RunId-visual-$($Replicate.ToString('D2'))-start"; action = 'sequence_start'
        sequence = [ordered]@{
            frameCount = [int]$Protocol.visualAssay.frameCount; useSettings = $false
            schedule = ConvertTo-CSXHashtable $Protocol.visualAssay.schedule
            backpressure = [ordered]@{ policy = 'skip'; maximumConsecutiveSkips = 10 }
            failurePolicy = 'continue'
            capture = [ordered]@{
                source = ConvertTo-CSXHashtable $Protocol.visualAssay.source
                outputs = $outputs
                destination = [ordered]@{ policy = 'absolute'; directory = [IO.Path]::GetFullPath($DestinationDirectory); baseName = "$RunId-rep-$($Replicate.ToString('D2'))"; overwrite = 'never' }
                clipboard = 'none'
                tags = [ordered]@{ suite = 'csx-render-scale-pr-v1'; replicate = [string]$Replicate }
            }
            packaging = [ordered]@{ frameManifest = $true; previewVideo = [ordered]@{ requested = $false; required = $false } }
        }
    }
}

function Invoke-CSXRetriedWebRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Headers,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][ValidateRange(1, 600)][int]$TimeoutSeconds
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $remaining = $TimeoutSeconds - [int][Math]::Ceiling($watch.Elapsed.TotalSeconds)
        if ($remaining -lt 1) { throw 'DevBench HTTP retry budget expired.' }
        try {
            return Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Uri -Headers $Headers -Body $Body -TimeoutSec $remaining
        }
        catch {
            $statusCode = 0
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $statusCode = [int]$_.Exception.Response.StatusCode }
            $retryable = $statusCode -in @(429, 502, 503, 504) -or
                $_.Exception.Message -match '(?i)timed out|timeout|temporarily unavailable|connection (was )?(closed|reset|refused)|forcibly closed'
            if (-not $retryable -or $attempt -eq 3) { throw }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

function New-CSXInfrastructureException {
    param([Parameter(Mandatory)][string]$Message, [Exception]$InnerException)
    $exception = if ($InnerException) {
        [InvalidOperationException]::new($Message, $InnerException)
    }
    else { [InvalidOperationException]::new($Message) }
    $exception.Data['CSXFailureClass'] = 'infrastructure'
    return $exception
}

function New-CSXMcpConnection {
    param([Parameter(Mandatory)]$Runtime, [string]$ClientName = 'CSXRenderScaleQualification')
    $port = [int](Get-CSXPropertyValue $Runtime 'port')
    if ($port -lt 1 -or $port -gt 65535) { throw 'Runtime metadata has an invalid port.' }
    $endpoint = "http://127.0.0.1:$port/mcp"
    $baseHeaders = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json' }
    $body = [ordered]@{
        jsonrpc = '2.0'; id = 1; method = 'initialize'
        params = [ordered]@{ protocolVersion = '2025-03-26'; capabilities = @{}; clientInfo = [ordered]@{ name = $ClientName; version = '1.0' } }
    } | ConvertTo-Json -Depth 20 -Compress
    $response = Invoke-CSXRetriedWebRequest -Uri $endpoint -Headers $baseHeaders -Body $body -TimeoutSeconds 15
    $sessionHeader = $response.Headers['Mcp-Session-Id']
    $sessionId = if ($sessionHeader -is [array]) { [string]$sessionHeader[0] } else { [string]$sessionHeader }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'DevBench did not return an MCP session ID.' }
    $headers = @{ Accept = 'application/json, text/event-stream'; 'Content-Type' = 'application/json'; 'Mcp-Session-Id' = $sessionId }
    Invoke-CSXRetriedWebRequest -Uri $endpoint -Headers $headers -Body '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' -TimeoutSeconds 15 | Out-Null
    return [pscustomobject][ordered]@{
        endpoint = $endpoint; headers = $headers; sessionId = $sessionId; requestId = 1L
        transcript = [Collections.Generic.List[object]]::new()
        serviceSessions = @{}
    }
}

function Invoke-CSXMcpTool {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)]$Arguments,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 15,
        [switch]$AllowSemanticFailure
    )
    $Connection.requestId = [long]$Connection.requestId + 1L
    $transcriptRecorded = $false
    $request = [ordered]@{
        jsonrpc = '2.0'; id = $Connection.requestId; method = 'tools/call'
        params = [ordered]@{ name = $Tool; arguments = $Arguments }
    }
    $started = [DateTime]::UtcNow
    $body = $request | ConvertTo-Json -Depth 100 -Compress
    try {
        try {
            # A lost response is an uncertain mutation outcome; never replay tools/call.
            $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $Connection.endpoint -Headers $Connection.headers -Body $body -TimeoutSec $TimeoutSeconds
        }
        catch {
            throw (New-CSXInfrastructureException -Message "DevBench tools/call transport failed for '$Tool'; the request was not replayed." -InnerException $_.Exception)
        }
        try { $rpc = $response.Content | ConvertFrom-Json -Depth 100 }
        catch { throw (New-CSXInfrastructureException -Message "DevBench returned malformed JSON-RPC for '$Tool'." -InnerException $_.Exception) }
        if ($rpc.PSObject.Properties['error']) {
            throw (New-CSXInfrastructureException -Message "DevBench tools/call failed: $($rpc.error | ConvertTo-Json -Depth 20 -Compress)")
        }
        if ($rpc.result.PSObject.Properties['isError'] -and [bool]$rpc.result.isError) {
            throw (New-CSXInfrastructureException -Message "DevBench tool '$Tool' failed: $(($rpc.result.content | ForEach-Object text) -join "`n")")
        }
        $content = [Collections.Generic.List[object]]::new()
        foreach ($item in @($rpc.result.content)) {
            if ($item.type -eq 'text') {
                try { $content.Add(($item.text | ConvertFrom-Json -Depth 100)) } catch { $content.Add([string]$item.text) }
            }
            else { $content.Add($item) }
        }
        $value = if ($content.Count -eq 1) { $content[0] } else { @($content) }
        $errorValue = Get-CSXPropertyValue $value 'error'
        $okValue = Get-CSXPropertyValue $value 'ok' $true
        $semanticFailure = $null -ne $errorValue -or $okValue -eq $false
        if ($semanticFailure) {
            $Connection.transcript.Add([pscustomobject][ordered]@{
                startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
                tool = $Tool; arguments = $Arguments; response = $value; ok = $false
                error = $(if ($null -ne $errorValue) { [string]$errorValue } else { 'semantic failure' })
            })
            $transcriptRecorded = $true
            if (-not $AllowSemanticFailure) {
                throw "DevBench tool '$Tool' returned semantic failure: $($value | ConvertTo-Json -Depth 30 -Compress)"
            }
        }
        $serverSession = Get-CSXPathValue $value 'server.sessionId'
        if ($serverSession) {
            if ($Connection.serviceSessions.ContainsKey($Tool) -and $Connection.serviceSessions[$Tool] -ne $serverSession) {
                throw (New-CSXInfrastructureException -Message "Service session changed for '$Tool'.")
            }
            $Connection.serviceSessions[$Tool] = [string]$serverSession
        }
        if (-not $transcriptRecorded) {
            $Connection.transcript.Add([pscustomobject][ordered]@{
                startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
                tool = $Tool; arguments = $Arguments; response = $value; ok = $true; error = $null
            })
            $transcriptRecorded = $true
        }
        return $value
    }
    catch {
        if (-not $transcriptRecorded) {
            $Connection.transcript.Add([pscustomobject][ordered]@{
                startedUtc = $started.ToString('o'); completedUtc = [DateTime]::UtcNow.ToString('o')
                tool = $Tool; arguments = $Arguments; response = $null; ok = $false; error = $_.Exception.Message
            })
        }
        throw
    }
}

function Get-CSXRemainingMilliseconds {
    param([Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch, [Parameter(Mandatory)][int]$BudgetMs)
    return [Math]::Max(0, $BudgetMs - [int][Math]::Ceiling($Stopwatch.Elapsed.TotalMilliseconds))
}

function Get-CSXBoundedTimeoutSeconds {
    param(
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$BudgetMs,
        [Parameter(Mandatory)][int]$OperationCapMs
    )
    $remaining = Get-CSXRemainingMilliseconds -Stopwatch $Stopwatch -BudgetMs $BudgetMs
    $bounded = [Math]::Min($remaining, $OperationCapMs)
    if ($bounded -lt 1000) { throw 'Less than one whole second remains on the orchestration deadline.' }
    return [Math]::Floor($bounded / 1000.0)
}

function Get-CSXNearestRankPercentile {
    param([Parameter(Mandatory)][double[]]$Values, [Parameter(Mandatory)][ValidateRange(0, 1)][double]$Percentile)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $index = [Math]::Max(0, [Math]::Min($sorted.Count - 1, [Math]::Ceiling($Percentile * $sorted.Count) - 1))
    return [double]$sorted[$index]
}

function Get-CSXMedian {
    param([Parameter(Mandatory)][double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-CSXMetricSummary {
    param([AllowEmptyCollection()][double[]]$Values, [switch]$IncludeRate)
    if ($null -eq $Values -or $Values.Count -eq 0) {
        return [pscustomobject][ordered]@{ count = 0; total = $null; min = $null; median = $null; mean = $null; sampleStandardDeviation = $null; coefficientOfVariation = $null; p95 = $null; max = $null; transitionsPerMinute = $null }
    }
    $measure = $Values | Measure-Object -Sum -Average -Minimum -Maximum
    $mean = [double]$measure.Average
    $variance = if ($Values.Count -gt 1) { [double](($Values | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum) / ($Values.Count - 1) } else { 0.0 }
    $sd = [Math]::Sqrt($variance)
    return [pscustomobject][ordered]@{
        count = $Values.Count; total = [double]$measure.Sum; min = [double]$measure.Minimum
        median = Get-CSXMedian -Values $Values
        mean = $mean; sampleStandardDeviation = $sd
        coefficientOfVariation = $(if ($mean -ne 0) { $sd / $mean } else { $null })
        p95 = Get-CSXNearestRankPercentile -Values $Values -Percentile 0.95
        max = [double]$measure.Maximum
        transitionsPerMinute = $(if ($IncludeRate -and [double]$measure.Sum -gt 0) { 60000.0 * $Values.Count / [double]$measure.Sum } else { $null })
    }
}

function Get-CSXWilsonInterval {
    param([Parameter(Mandatory)][int]$Failures, [Parameter(Mandatory)][int]$Trials)
    if ($Trials -le 0 -or $Failures -lt 0 -or $Failures -gt $Trials) { return [pscustomobject][ordered]@{ lower = $null; upper = $null; confidence = 0.95 } }
    $z = 1.95996398454005
    $p = [double]$Failures / $Trials
    $denominator = 1.0 + ($z * $z / $Trials)
    $center = ($p + ($z * $z / (2.0 * $Trials))) / $denominator
    $half = $z * [Math]::Sqrt(($p * (1.0 - $p) / $Trials) + ($z * $z / (4.0 * $Trials * $Trials))) / $denominator
    return [pscustomobject][ordered]@{ lower = [Math]::Max(0.0, $center - $half); upper = [Math]::Min(1.0, $center + $half); confidence = 0.95 }
}

function Get-CSXQualificationWaitRecords {
    param([Parameter(Mandatory)]$ScenarioResult, [Parameter(Mandatory)][string]$LabelPrefix)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($step in @($ScenarioResult.results)) {
        $label = [string](Get-CSXPropertyValue $step 'label')
        if ($label -notmatch "^$([regex]::Escape($LabelPrefix))-(?<ordinal>\d{2})-wait$") { continue }
        $payload = Get-CSXPropertyValue $step 'result'
        $satisfied = [bool](Get-CSXPropertyValue $payload 'satisfied' $false)
        $elapsed = Get-CSXPathValue $payload 'timing.elapsedMs' (Get-CSXPropertyValue $payload 'elapsedMs')
        $records.Add([pscustomobject][ordered]@{
            ordinal = [int]$Matches.ordinal; transitionId = [uint64](Get-CSXPropertyValue $payload 'transitionId')
            satisfied = $satisfied; elapsedMs = $(if ($null -ne $elapsed) { [double]$elapsed } else { $null })
            target = Get-CSXPropertyValue $payload 'target'; foveation = Get-CSXPropertyValue $payload 'foveation'
            diagnostics = Get-CSXPropertyValue $payload 'diagnostics'; raw = $payload
        })
    }
    return @($records | Sort-Object ordinal)
}

function Test-CSXFoveationEvidence {
    param([Parameter(Mandatory)]$Evidence, [Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Target)
    $expectedReceipt = Get-CSXPropertyValue $Evidence 'target' (Get-CSXPropertyValue $Evidence 'expected')
    $observed = Get-CSXPropertyValue $Evidence 'observed'
    if ($null -eq $observed) { $observed = $Evidence }
    $settings = Get-CSXPropertyValue $observed 'settings'
    $physical = Get-CSXPropertyValue $observed 'physical'
    if ($null -eq $expectedReceipt -or $null -eq $settings -or $null -eq $physical) { return $false }
    $tolerance = [double](Get-CSXPropertyValue $Evidence 'floatTolerance' (Get-CSXPropertyValue $expectedReceipt 'floatTolerance' 0.0001))
    foreach ($name in @('foveatedVendorDispatch', 'peripheryTAAEnable')) {
        if ([bool](Get-CSXPropertyValue $expectedReceipt $name) -ne [bool](Get-CSXPropertyValue $Expected $name)) { return $false }
        if ([bool](Get-CSXPropertyValue $settings $name) -ne [bool](Get-CSXPropertyValue $Expected $name)) { return $false }
    }
    foreach ($name in @('foveatedCenterArea', 'peripheryTAACenterArea', 'peripheryTAAOuterScale')) {
        if ([Math]::Abs([double](Get-CSXPropertyValue $expectedReceipt $name) - [double](Get-CSXPropertyValue $Expected $name)) -gt $tolerance) { return $false }
        if ([Math]::Abs([double](Get-CSXPropertyValue $settings $name) - [double](Get-CSXPropertyValue $Expected $name)) -gt $tolerance) { return $false }
    }
    $active = [bool](Get-CSXPropertyValue $Target 'renderScaleMode')
    $physicalVendor = Get-CSXPropertyValue $physical 'foveatedVendorDispatch'
    $physicalPeriphery = Get-CSXPropertyValue $physical 'peripheryTAAEnable' (Get-CSXPropertyValue $physical 'peripheryTAA')
    if ($null -eq $physicalVendor -or $null -eq $physicalPeriphery) { return $false }
    if ([bool]$physicalVendor -ne ($active -and [bool]$Expected.foveatedVendorDispatch)) { return $false }
    if ([bool]$physicalPeriphery -ne ($active -and [bool]$Expected.peripheryTAAEnable)) { return $false }
    return $true
}

function Test-CSXDLSSCaptureSummary {
    param([Parameter(Mandatory)]$Summary, [switch]$RequireDispatch, [switch]$RequireZeroDispatch)
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($field in @('droppedRecords', 'duplicatedConstantsFailures', 'evaluateFailures')) {
        if ([uint64](Get-CSXPropertyValue $Summary $field ([uint64]::MaxValue)) -ne 0) { $errors.Add("$field is nonzero or missing") }
    }
    if ([bool](Get-CSXPropertyValue $Summary 'lastDuplicatedConstantsFailureFound' $true)) { $errors.Add('a duplicated-constants failure is pinned') }
    if ([bool](Get-CSXPropertyValue $Summary 'lastEvaluateFailureFound' $true)) { $errors.Add('an evaluate failure is pinned') }
    $total = [uint64](Get-CSXPropertyValue $Summary 'totalRecords' 0)
    $evaluations = [uint64](Get-CSXPropertyValue $Summary 'evaluateCalls' 0)
    $constants = [uint64](Get-CSXPropertyValue $Summary 'setConstantsCalls' 0)
    if ($RequireDispatch -and ($total -eq 0 -or $evaluations -eq 0 -or $constants -eq 0)) { $errors.Add('no DLSS constants/evaluation dispatch evidence was captured') }
    if ($RequireZeroDispatch -and ($total -ne 0 -or $evaluations -ne 0 -or $constants -ne 0)) { $errors.Add('AMD capability-only trace unexpectedly captured a DLSS dispatch') }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; errors = @($errors); partialRawDetail = [uint64](Get-CSXPropertyValue $Summary 'overwrittenRecords' 0) -gt 0 }
}

function Test-CSXDLSSRetainedRecords {
    param([Parameter(Mandatory)]$Capture, [Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][int]$ExpectedQualityMode)
    $errors = [Collections.Generic.List[string]]::new()
    $records = @($Capture.records)
    if ($records.Count -eq 0 -or $records.Count -gt 16) { $errors.Add('bounded read did not retain between one and 16 records') }
    if ([uint64](Get-CSXPropertyValue $Capture 'afterSequence' ([uint64]::MaxValue)) -ne 0 -or
        [int](Get-CSXPropertyValue $Capture 'limit' 0) -ne 16) { $errors.Add('bounded read paging contract changed') }
    $sequences = [Collections.Generic.List[uint64]]::new()
    $evaluations = [Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $current = Get-CSXPropertyValue $record 'current'
        $signature = Get-CSXPropertyValue $current 'signature'
        $sequence = [uint64](Get-CSXPropertyValue $current 'sequence' 0)
        $stage = [string](Get-CSXPropertyValue $current 'stage')
        $eye = [int](Get-CSXPropertyValue $signature 'eye' -1)
        $requestedViewport = Get-CSXPropertyValue $signature 'requestedViewport'
        $resolvedViewport = Get-CSXPropertyValue $signature 'resolvedViewport'
        if ($sequence -eq 0 -or [uint64](Get-CSXPropertyValue $current 'timestampQPC' 0) -eq 0 -or
            [uint64](Get-CSXPropertyValue $current 'threadID' 0) -eq 0 -or [uint64](Get-CSXPropertyValue $current 'compositorCycle' 0) -eq 0) {
            $errors.Add('a retained record omitted sequence, QPC, thread, or compositor-cycle identity')
        }
        if ($stage -notin @('constants_cache_reuse', 'set_constants', 'evaluate') -or [int](Get-CSXPropertyValue $current 'resultCode' -1) -ne 0) {
            $errors.Add('a retained record has an invalid stage or non-success result')
        }
        if ([uint64](Get-CSXPropertyValue $signature 'traceSessionID' 0) -ne [uint64]$Summary.sessionID -or
            [uint64](Get-CSXPropertyValue $signature 'frameToken' 0) -eq 0 -or $eye -notin @(0, 1) -or
            $null -eq $requestedViewport -or $null -eq $resolvedViewport -or [int]$resolvedViewport -ne $eye -or
            [uint64](Get-CSXPathValue $signature 'output.width' 0) -eq 0 -or [uint64](Get-CSXPathValue $signature 'output.height' 0) -eq 0 -or
            [uint64](Get-CSXPathValue $signature 'extentIn.width' 0) -eq 0 -or [uint64](Get-CSXPathValue $signature 'extentIn.height' 0) -eq 0 -or
            [uint64](Get-CSXPathValue $signature 'extentOut.width' 0) -eq 0 -or [uint64](Get-CSXPathValue $signature 'extentOut.height' 0) -eq 0 -or
            [int](Get-CSXPropertyValue $signature 'qualityMode' -1) -ne $ExpectedQualityMode -or [int](Get-CSXPropertyValue $signature 'dlssPreset' -1) -ne 1) {
            $errors.Add('a retained record has invalid session, frame, eye, dimensions, quality, or preset identity')
        }
        $constants = Get-CSXPropertyValue $signature 'streamlineConstants'
        $resources = Get-CSXPropertyValue $signature 'resources'
        if ($null -eq $constants -or $null -eq $resources -or $null -eq (Get-CSXPropertyValue $constants 'cameraFOV')) {
            $errors.Add('a retained record omitted Streamline constants or resource identity')
        }
        foreach ($resourceName in @('colorIn', 'colorOut', 'depth', 'motionVectors')) {
            $resource = [string](Get-CSXPropertyValue $resources $resourceName)
            if ($resource -notmatch '^0x[0-9A-Fa-f]{16}$' -or $resource -eq '0x0000000000000000') {
                $errors.Add("a retained record has invalid $resourceName resource identity")
            }
        }
        if ($stage -eq 'evaluate') {
            $previous = Get-CSXPropertyValue $record 'previousConstants'
            $previousSignature = Get-CSXPropertyValue $previous 'signature'
            if (-not [bool](Get-CSXPropertyValue $record 'previousConstantsFound' $false) -or $null -eq $previous -or
                [int](Get-CSXPropertyValue $previous 'resultCode' -1) -ne 0 -or
                [uint64](Get-CSXPropertyValue $previousSignature 'traceSessionID' 0) -ne [uint64]$Summary.sessionID) {
                $errors.Add('an evaluation record is not correlated to successful constants')
            }
            else {
                foreach ($path in @('frameToken', 'resolvedViewport', 'eye', 'output.width', 'output.height', 'qualityMode', 'dlssPreset')) {
                    if ([string](Get-CSXPathValue $previousSignature $path) -ne [string](Get-CSXPathValue $signature $path)) {
                        $errors.Add("an evaluation/constants pair disagrees on $path")
                    }
                }
                if ([uint64](Get-CSXPropertyValue $previous 'compositorCycle' 0) -ne [uint64](Get-CSXPropertyValue $current 'compositorCycle' 0)) {
                    $errors.Add('an evaluation/constants pair disagrees on compositor cycle')
                }
                foreach ($resourceName in @('colorIn', 'colorOut', 'depth', 'motionVectors')) {
                    if ([string](Get-CSXPathValue $previousSignature "resources.$resourceName") -ne [string](Get-CSXPathValue $signature "resources.$resourceName")) {
                        $errors.Add("an evaluation/constants pair disagrees on $resourceName resource")
                    }
                }
            }
        }
        $sequences.Add($sequence)
        if ($stage -eq 'evaluate') { $evaluations.Add($current) }
    }
    if (@($sequences | Sort-Object -Unique).Count -ne $records.Count -or
        (@($sequences) -join ',') -ne (@($sequences | Sort-Object) -join ',')) { $errors.Add('retained record sequences are duplicate or unordered') }
    $stereoPairFound = $false
    foreach ($group in @($evaluations | Group-Object { "$(Get-CSXPropertyValue $_ 'compositorCycle')|$(Get-CSXPathValue $_ 'signature.frameToken')|$(Get-CSXPathValue $_ 'signature.frame')" })) {
        $eyes = @($group.Group | ForEach-Object { [int](Get-CSXPathValue $_ 'signature.eye' -1) } | Sort-Object -Unique)
        if (($eyes -join ',') -ne '0,1') { continue }
        $viewports = @($group.Group | ForEach-Object { [int](Get-CSXPathValue $_ 'signature.resolvedViewport' -1) } | Sort-Object -Unique)
        if (($viewports -join ',') -ne '0,1') { continue }
        $identities = @($group.Group | ForEach-Object {
            "$(Get-CSXPathValue $_ 'signature.output.width')|$(Get-CSXPathValue $_ 'signature.output.height')|$(Get-CSXPathValue $_ 'signature.qualityMode')|$(Get-CSXPathValue $_ 'signature.dlssPreset')"
        } | Sort-Object -Unique)
        if ($identities.Count -eq 1) { $stereoPairFound = $true; break }
    }
    if (-not $stereoPairFound) { $errors.Add('bounded records contain no coherent two-eye evaluation pair') }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; records = $records.Count; stereoPairFound = $stereoPairFound; errors = @($errors | Select-Object -Unique) }
}

function Test-CSXDLSSScenarioEvidence {
    param([Parameter(Mandatory)]$ScenarioResult, [Parameter(Mandatory)][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor)
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $groups = [Collections.Generic.List[object]]::new()
    $preflightSteps = @($ScenarioResult.results | Where-Object label -eq 'menu-dlss_trace_status-preflight')
    $preflight = $preflightSteps | Select-Object -First 1
    $preflightSummary = Get-CSXPathValue $preflight 'result.capture'
    if ($preflightSteps.Count -ne 1 -or [string](Get-CSXPathValue $preflight 'result.action') -ne 'dlss_trace_status' -or
        $null -eq $preflightSummary -or [bool](Get-CSXPropertyValue $preflightSummary 'active' $true)) {
        $errors.Add('Menu DLSS trace preflight was missing, duplicated, mislabeled, or active.')
    }
    if ($GpuVendor -eq 'AMD') {
        $amdSteps = [ordered]@{}
        foreach ($action in @('reset', 'start', 'stop', 'read')) {
            $matches = @($ScenarioResult.results | Where-Object label -eq "amd-capability-dlss_trace_$action")
            if ($matches.Count -ne 1) { $errors.Add("AMD DLSS trace requires exactly one $action receipt.") }
            $amdSteps[$action] = $matches | Select-Object -First 1
        }
        $reset = $amdSteps.reset
        $start = $amdSteps.start
        $stop = $amdSteps.stop
        $read = $amdSteps.read
        $resetSummary = Get-CSXPathValue $reset 'result.capture'
        $startSummary = Get-CSXPathValue $start 'result.capture'
        $stopSummary = Get-CSXPathValue $stop 'result.capture'
        $readCapture = Get-CSXPathValue $read 'result.capture'
        $readSummary = Get-CSXPropertyValue $readCapture 'summary'
        if ($null -eq $resetSummary -or $null -eq $startSummary -or $null -eq $stopSummary -or $null -eq $readSummary) { $errors.Add('AMD DLSS trace lifecycle evidence is missing.') }
        else {
            if ([string](Get-CSXPathValue $reset 'result.action') -ne 'dlss_trace_reset' -or [string](Get-CSXPathValue $start 'result.action') -ne 'dlss_trace_start' -or
                [string](Get-CSXPathValue $stop 'result.action') -ne 'dlss_trace_stop' -or [string](Get-CSXPathValue $read 'result.action') -ne 'dlss_trace_read') {
                $errors.Add('AMD DLSS trace lifecycle action identity changed.')
            }
            if ([bool]$resetSummary.active -or -not [bool]$startSummary.active -or [bool]$stopSummary.active -or [bool]$readSummary.active) { $errors.Add('AMD DLSS trace lifecycle states are incoherent.') }
            if ([uint64]$startSummary.sessionID -ne [uint64]$stopSummary.sessionID -or [uint64]$stopSummary.sessionID -ne [uint64]$readSummary.sessionID) { $errors.Add('AMD DLSS trace session identity changed.') }
            foreach ($summary in @($resetSummary, $readSummary)) {
                $zero = Test-CSXDLSSCaptureSummary -Summary $summary -RequireZeroDispatch
                foreach ($error in $zero.errors) { $errors.Add("AMD trace: $error") }
            }
            if (@($readCapture.records).Count -ne 0 -or [uint64](Get-CSXPropertyValue $readCapture 'afterSequence' ([uint64]::MaxValue)) -ne 0 -or [int](Get-CSXPropertyValue $readCapture 'limit' 0) -ne 16) {
                $errors.Add('AMD capability-only trace read was not the exact empty bounded page.')
            }
            $groups.Add([pscustomobject][ordered]@{ kind = 'capability_only'; ordinal = $null; summary = $readSummary; validation = [pscustomobject]@{ ok = $errors.Count -eq 0 } })
        }
    }
    else {
        $waitSteps = @($ScenarioResult.results | Where-Object { [string]$_.label -match '^menu-\d{2}-wait$' })
        $expectedOrdinals = @($waitSteps | Where-Object { [string](Get-CSXPathValue $_ 'result.target.method') -eq 'dlss' } | ForEach-Object {
            if ([string]$_.label -match '^menu-(?<ordinal>\d{2})-wait$') { [int]$Matches.ordinal }
        } | Sort-Object -Unique)
        if ($waitSteps.Count -ne 25 -or $expectedOrdinals.Count -eq 0) { $errors.Add('NVIDIA trace validation did not receive the complete 25-wait canonical matrix.') }
        foreach ($ordinal in $expectedOrdinals) {
            $prefix = "menu-$($ordinal.ToString('D2'))"
            foreach ($action in @('reset', 'start', 'stop', 'read')) {
                if (@($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_$action").Count -ne 1) {
                    $errors.Add("menu ${ordinal}: expected exactly one dlss_trace_$action receipt")
                }
            }
        }
        $readSteps = @($ScenarioResult.results | Where-Object { [string]$_.label -match '^menu-\d{2}-dlss_trace_read$' })
        foreach ($read in $readSteps) {
            if ([string]$read.label -notmatch '^menu-(?<ordinal>\d{2})-dlss_trace_read$') { continue }
            $ordinal = [int]$Matches.ordinal
            $prefix = "menu-$($ordinal.ToString('D2'))"
            $reset = @($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_reset") | Select-Object -First 1
            $start = @($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_start") | Select-Object -First 1
            $stop = @($ScenarioResult.results | Where-Object label -eq "$prefix-dlss_trace_stop") | Select-Object -First 1
            $wait = @($ScenarioResult.results | Where-Object label -eq "$prefix-wait") | Select-Object -First 1
            $resetSummary = Get-CSXPathValue $reset 'result.capture'
            $startSummary = Get-CSXPathValue $start 'result.capture'
            $stopSummary = Get-CSXPathValue $stop 'result.capture'
            $capture = Get-CSXPathValue $read 'result.capture'
            $summary = Get-CSXPropertyValue $capture 'summary'
            if ($null -eq $resetSummary -or $null -eq $startSummary -or $null -eq $stopSummary -or $null -eq $summary -or $null -eq $wait) {
                $errors.Add("DLSS trace evidence is missing for menu ordinal $ordinal.")
                continue
            }
            if ([string](Get-CSXPathValue $reset 'result.action') -ne 'dlss_trace_reset' -or [string](Get-CSXPathValue $start 'result.action') -ne 'dlss_trace_start' -or
                [string](Get-CSXPathValue $stop 'result.action') -ne 'dlss_trace_stop' -or [string](Get-CSXPathValue $read 'result.action') -ne 'dlss_trace_read') {
                $errors.Add("DLSS trace action identity changed at menu ordinal $ordinal.")
            }
            $resetCheck = Test-CSXDLSSCaptureSummary -Summary $resetSummary -RequireZeroDispatch
            foreach ($error in $resetCheck.errors) { $errors.Add("menu ${ordinal} reset: $error") }
            if ([bool]$resetSummary.active -or -not [bool]$startSummary.active -or [bool]$stopSummary.active -or [bool]$summary.active) { $errors.Add("DLSS trace lifecycle is incoherent at menu ordinal $ordinal.") }
            if ([uint64]$startSummary.sessionID -ne [uint64]$stopSummary.sessionID -or [uint64]$stopSummary.sessionID -ne [uint64]$summary.sessionID) { $errors.Add("DLSS trace session mismatch at menu ordinal $ordinal.") }
            foreach ($counter in @('totalRecords', 'overwrittenRecords', 'droppedRecords', 'setConstantsCalls', 'evaluateCalls', 'duplicatedConstantsFailures', 'evaluateFailures')) {
                if ([uint64](Get-CSXPropertyValue $stopSummary $counter ([uint64]::MaxValue)) -ne [uint64](Get-CSXPropertyValue $summary $counter ([uint64]::MaxValue))) {
                    $errors.Add("menu ${ordinal}: stop/read counter '$counter' changed")
                }
            }
            $checked = Test-CSXDLSSCaptureSummary -Summary $summary -RequireDispatch
            foreach ($error in $checked.errors) { $errors.Add("menu ${ordinal}: $error") }
            $recordCheck = Test-CSXDLSSRetainedRecords -Capture $capture -Summary $summary -ExpectedQualityMode ([int](Get-CSXPathValue $wait 'result.target.qualityMode' -1))
            foreach ($error in $recordCheck.errors) { $errors.Add("menu ${ordinal}: $error") }
            if ($checked.partialRawDetail) { $warnings.Add("menu ${ordinal}: ring overwrite produced partial raw detail; pinned counters remain authoritative.") }
            $groups.Add([pscustomobject][ordered]@{ kind = 'dlss_dispatch'; ordinal = $ordinal; summary = $summary; validation = [pscustomobject][ordered]@{ summary = $checked; records = $recordCheck } })
        }
        if ($groups.Count -eq 0) { $errors.Add('No scoped NVIDIA DLSS trace sessions were preserved.') }
        $expectedGroups = $expectedOrdinals.Count
        if ($groups.Count -ne $expectedGroups -or $readSteps.Count -ne $expectedGroups) { $errors.Add("Scoped NVIDIA trace evidence count $($groups.Count) differs from the $expectedGroups canonical DLSS transitions.") }
    }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; groups = @($groups); errors = @($errors | Select-Object -Unique); warnings = @($warnings | Select-Object -Unique) }
}

function Get-CSXPairedComparison {
    param([Parameter(Mandatory)][object[]]$Candidate, [Parameter(Mandatory)][object[]]$Baseline)
    if ($Candidate.Count -ne $Baseline.Count) { throw 'Candidate and baseline transition counts differ.' }
    $deltas = [Collections.Generic.List[double]]::new()
    $percent = [Collections.Generic.List[double]]::new()
    for ($i = 0; $i -lt $Candidate.Count; $i++) {
        if ([int]$Candidate[$i].ordinal -ne [int]$Baseline[$i].ordinal) { throw "Paired transition ordinal mismatch at index $i." }
        $candidateMs = [double]$Candidate[$i].elapsedMs
        $baselineMs = [double]$Baseline[$i].elapsedMs
        if ($candidateMs -lt 0 -or $baselineMs -le 0) { throw "Invalid paired timing at ordinal $($Candidate[$i].ordinal)." }
        $deltas.Add($candidateMs - $baselineMs)
        $percent.Add(100.0 * ($candidateMs - $baselineMs) / $baselineMs)
    }
    $candidateSummary = Get-CSXMetricSummary -Values ([double[]]@($Candidate.elapsedMs)) -IncludeRate
    $baselineSummary = Get-CSXMetricSummary -Values ([double[]]@($Baseline.elapsedMs)) -IncludeRate
    $aggregate = [ordered]@{}
    foreach ($metric in @('total', 'median', 'mean', 'p95', 'max')) {
        $candidateValue = [double](Get-CSXPropertyValue $candidateSummary $metric)
        $baselineValue = [double](Get-CSXPropertyValue $baselineSummary $metric)
        if ($baselineValue -le 0) { throw "Baseline aggregate $metric must be positive." }
        $aggregate[$metric] = [pscustomobject][ordered]@{
            candidateMs = $candidateValue
            baselineMs = $baselineValue
            deltaMs = $candidateValue - $baselineValue
            percent = 100.0 * ($candidateValue - $baselineValue) / $baselineValue
        }
    }
    return [pscustomobject][ordered]@{
        count = $Candidate.Count
        candidate = $candidateSummary
        baseline = $baselineSummary
        aggregateDelta = [pscustomobject]$aggregate
        pairedOrdinalDelta = [pscustomobject][ordered]@{
            milliseconds = Get-CSXMetricSummary -Values ([double[]]@($deltas))
            percent = Get-CSXMetricSummary -Values ([double[]]@($percent))
        }
    }
}

function Assert-CSXVisualIndexSet {
    param([Parameter(Mandatory)]$VisualIndex, [Parameter(Mandatory)][string]$Label, [string]$ExpectedRunId = '')
    if ([string]$VisualIndex.schema -ne 'csx-render-scale-visual-index-v1') { throw "$Label visual index schema is invalid." }
    if ($ExpectedRunId -and [string]$VisualIndex.runId -ne $ExpectedRunId) { throw "$Label visual index run identity is invalid." }
    $samples = @($VisualIndex.samples)
    if ($samples.Count -ne 9) { throw "$Label visual index must contain exactly nine review samples." }
    $identities = @($samples | ForEach-Object { "$([int]$_.replicate):$([int]$_.ordinal)" })
    $expected = @(foreach ($replicate in 1..3) { foreach ($ordinal in @(1, 8, 16)) { "${replicate}:${ordinal}" } })
    if (@($identities | Sort-Object -Unique).Count -ne 9 -or (@($identities | Sort-Object) -join ',') -ne (@($expected | Sort-Object) -join ',')) {
        throw "$Label visual index has duplicate, missing, or unexpected sample identities."
    }
    foreach ($sample in $samples) {
        $artifacts = @($sample.artifacts)
        $views = @($artifacts | ForEach-Object { [string]$_.view })
        if ($artifacts.Count -ne 3 -or @($views | Sort-Object -Unique).Count -ne 3 -or
            (@($views | Sort-Object) -join ',') -ne 'left_eye,right_eye,side_by_side') {
            throw "$Label visual sample $($sample.replicate)/$($sample.ordinal) must bind the three exact views once each."
        }
        $paths = @($artifacts | ForEach-Object { [string]$_.path })
        $hashes = @($artifacts | ForEach-Object { [string]$_.sha256 })
        if (@($paths | Sort-Object -Unique).Count -ne 3 -or @($hashes | Where-Object { $_ -match '^[a-f0-9]{64}$' }).Count -ne 3) {
            throw "$Label visual sample $($sample.replicate)/$($sample.ordinal) has duplicate paths or invalid SHA-256 bindings."
        }
    }
}

function Resolve-CSXEvidencePath {
    param([Parameter(Mandatory)][string]$EvidenceRoot, [Parameter(Mandatory)][string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw "Review artifact path must be relative: $RelativePath" }
    $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Review artifact escapes the evidence root: $RelativePath" }
    return $resolved
}

function New-CSXVisualReviewTemplate {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        $BaselineVisualIndex = $null
    )
    $prMode = [bool]$RunRaw.prMode
    Assert-CSXVisualIndexSet -VisualIndex $VisualIndex -Label 'Candidate' -ExpectedRunId ([string]$RunRaw.runId)
    if ($prMode) { Assert-CSXVisualIndexSet -VisualIndex $BaselineVisualIndex -Label 'Baseline' -ExpectedRunId ([string]$RunRaw.baseline.baselineRunId) }
    $samples = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($VisualIndex.samples | Sort-Object replicate, ordinal)) {
        $baseline = $null
        if ($prMode) {
            $baseline = @($BaselineVisualIndex.samples | Where-Object { [int]$_.replicate -eq [int]$candidate.replicate -and [int]$_.ordinal -eq [int]$candidate.ordinal }) | Select-Object -First 1
            if ($null -eq $baseline) { throw "Baseline visual sample is missing for rep $($candidate.replicate), ordinal $($candidate.ordinal)." }
        }
        $samples.Add([pscustomobject][ordered]@{
            replicate = [int]$candidate.replicate; ordinal = [int]$candidate.ordinal
            candidateArtifacts = @($candidate.artifacts)
            baselineArtifacts = $(if ($prMode) { @($baseline.artifacts) } else { @() })
            verdicts = [pscustomobject][ordered]@{
                sharpness = $null; blur = $null; shimmer = $null; stereoAlignment = $null
                equalEyeScale = $null; geometryCorrespondence = $null; renderScaleLatch = $null
            }
            notes = ''
        })
    }
    $rawPath = Join-Path $EvidenceDirectory 'run.raw.json'
    return [pscustomobject][ordered]@{
        schema = 'csx-render-scale-visual-review-v1'; comparisonMode = $(if ($prMode) { 'pr_baseline' } else { 'standalone' })
        runId = [string]$RunRaw.runId; protocolSha256 = [string]$RunRaw.protocol.sha256
        runRawSha256 = Get-CSXFileSha256 $rawPath
        baselineRunSha256 = $(if ($prMode) { [string]$RunRaw.baseline.runSha256 } else { $null })
        reviewer = [pscustomobject][ordered]@{ id = $null; kind = $null }
        reviewedUtc = $null; samples = @($samples); overallVerdict = $null
    }
}

function Test-CSXVisualReview {
    param(
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [Parameter(Mandatory)]$RunRaw,
        [Parameter(Mandatory)]$VisualIndex,
        [Parameter(Mandatory)]$Review,
        $BaselineVisualIndex = $null
    )
    $errors = [Collections.Generic.List[string]]::new()
    $prMode = [bool]$RunRaw.prMode
    try { Assert-CSXVisualIndexSet -VisualIndex $VisualIndex -Label 'Candidate' -ExpectedRunId ([string]$RunRaw.runId) } catch { $errors.Add($_.Exception.Message) }
    if ($prMode) { try { Assert-CSXVisualIndexSet -VisualIndex $BaselineVisualIndex -Label 'Baseline' -ExpectedRunId ([string]$RunRaw.baseline.baselineRunId) } catch { $errors.Add($_.Exception.Message) } }
    if ([string]$Review.schema -ne 'csx-render-scale-visual-review-v1') { $errors.Add('Visual review schema is invalid.') }
    if ([string]$Review.runId -ne [string]$RunRaw.runId -or [string]$Review.protocolSha256 -ne [string]$RunRaw.protocol.sha256) { $errors.Add('Visual review run/protocol binding does not match.') }
    if ([string]$Review.runRawSha256 -ne (Get-CSXFileSha256 (Join-Path $EvidenceDirectory 'run.raw.json'))) { $errors.Add('Visual review run.raw SHA-256 binding does not match.') }
    if ([string](Get-CSXPathValue $Review 'reviewer.id') -notmatch '\S' -or [string](Get-CSXPathValue $Review 'reviewer.kind') -notin @('human', 'image_model')) { $errors.Add('Reviewer identity and kind are required.') }
    $reviewed = [DateTimeOffset]::MinValue
    $reviewedValue = Get-CSXPropertyValue $Review 'reviewedUtc'
    $reviewedValid = if ($reviewedValue -is [DateTime]) {
        $reviewed = [DateTimeOffset]$reviewedValue
        $true
    }
    elseif ($reviewedValue -is [DateTimeOffset]) {
        $reviewed = $reviewedValue
        $true
    }
    else { [DateTimeOffset]::TryParse([string]$reviewedValue, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$reviewed) }
    if (-not $reviewedValid) { $errors.Add('reviewedUtc is not a valid timestamp.') }
    $expectedMode = if ($prMode) { 'pr_baseline' } else { 'standalone' }
    if ([string]$Review.comparisonMode -ne $expectedMode) { $errors.Add("Visual comparisonMode must be $expectedMode.") }
    if ($prMode -and [string]$Review.baselineRunSha256 -ne [string]$RunRaw.baseline.runSha256) { $errors.Add('Visual review baseline run SHA-256 binding does not match.') }
    if ($prMode) {
        try {
            $baselineRunPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath ([string]$RunRaw.baseline.path)
            if ((Get-CSXFileSha256 $baselineRunPath) -ne [string]$RunRaw.baseline.runSha256) { $errors.Add('Bundled baseline run SHA-256 changed.') }
        }
        catch { $errors.Add($_.Exception.Message) }
    }
    $expectedSamples = @($VisualIndex.samples | Sort-Object replicate, ordinal)
    $reviewSamples = @($Review.samples | Sort-Object replicate, ordinal)
    if ($reviewSamples.Count -ne $expectedSamples.Count) { $errors.Add('Visual review sample count does not match the capture index.') }
    $reviewIdentities = @($reviewSamples | ForEach-Object { "$([int]$_.replicate):$([int]$_.ordinal)" })
    if (@($reviewIdentities | Sort-Object -Unique).Count -ne $reviewSamples.Count) { $errors.Add('Visual review contains duplicate sample identities.') }
    for ($i = 0; $i -lt [Math]::Min($reviewSamples.Count, $expectedSamples.Count); $i++) {
        $actual = $reviewSamples[$i]; $expected = $expectedSamples[$i]
        if ([int]$actual.replicate -ne [int]$expected.replicate -or [int]$actual.ordinal -ne [int]$expected.ordinal) { $errors.Add("Visual review sample identity differs at index $i."); continue }
        $actualCandidateArtifacts = @($actual.candidateArtifacts)
        $actualCandidateIdentities = @($actualCandidateArtifacts | ForEach-Object { "$([string]$_.view)|$([string]$_.path)|$([string]$_.sha256)" })
        if ($actualCandidateArtifacts.Count -ne @($expected.artifacts).Count -or
            @($actualCandidateIdentities | Sort-Object -Unique).Count -ne $actualCandidateArtifacts.Count) {
            $errors.Add("Candidate artifact set is incomplete or duplicated for rep $($actual.replicate), ordinal $($actual.ordinal).")
        }
        foreach ($binding in $actualCandidateArtifacts) {
            $match = @($expected.artifacts | Where-Object { $_.view -eq $binding.view -and $_.path -eq $binding.path -and $_.sha256 -eq $binding.sha256 })
            if ($match.Count -ne 1) { $errors.Add("Candidate artifact binding differs for rep $($actual.replicate), ordinal $($actual.ordinal), view $($binding.view)."); continue }
            try {
                $path = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath ([string]$binding.path)
                if ((Get-CSXFileSha256 $path) -ne [string]$binding.sha256) { $errors.Add("Candidate artifact SHA-256 changed: $($binding.path)") }
            } catch { $errors.Add($_.Exception.Message) }
        }
        if ($prMode) {
            $baseline = @($BaselineVisualIndex.samples | Where-Object { [int]$_.replicate -eq [int]$actual.replicate -and [int]$_.ordinal -eq [int]$actual.ordinal }) | Select-Object -First 1
            $actualBaselineJson = $actual.baselineArtifacts | ConvertTo-Json -Depth 20 -Compress
            $expectedBaselineJson = $baseline.artifacts | ConvertTo-Json -Depth 20 -Compress
            if ($null -eq $baseline -or $actualBaselineJson -ne $expectedBaselineJson) {
                $errors.Add("Baseline artifact bindings differ for rep $($actual.replicate), ordinal $($actual.ordinal).")
            }
            else {
                $baselineIndexPath = Resolve-CSXEvidencePath -EvidenceRoot $EvidenceDirectory -RelativePath ([string]$RunRaw.baseline.visualIndexPath)
                $baselineRoot = Split-Path -Parent $baselineIndexPath
                foreach ($binding in @($actual.baselineArtifacts)) {
                    try {
                        $path = Resolve-CSXEvidencePath -EvidenceRoot $baselineRoot -RelativePath ([string]$binding.path)
                        if ((Get-CSXFileSha256 $path) -ne [string]$binding.sha256) { $errors.Add("Baseline artifact SHA-256 changed: $($binding.path)") }
                    } catch { $errors.Add($_.Exception.Message) }
                }
            }
        }
        $requiredVerdict = if ($prMode) { 'no_regression' } else { 'pass' }
        foreach ($name in @('sharpness', 'blur', 'shimmer', 'stereoAlignment', 'equalEyeScale', 'geometryCorrespondence', 'renderScaleLatch')) {
            if ([string](Get-CSXPathValue $actual "verdicts.$name") -ne $requiredVerdict) { $errors.Add("$name verdict is not '$requiredVerdict' for rep $($actual.replicate), ordinal $($actual.ordinal).") }
        }
    }
    if ([string]$Review.overallVerdict -ne 'pass') { $errors.Add('Visual review overallVerdict is not pass.') }
    return [pscustomobject][ordered]@{ ok = $errors.Count -eq 0; errors = @($errors); reviewer = $Review.reviewer; reviewedUtc = $Review.reviewedUtc }
}

function Update-CSXQualificationReport {
    param([Parameter(Mandatory)][string]$EvidenceDirectory)
    $root = [IO.Path]::GetFullPath($EvidenceDirectory)
    $rawPath = Join-Path $root 'run.raw.json'
    $indexPath = Join-Path $root 'visual-index.json'
    if (-not (Test-Path -LiteralPath $rawPath -PathType Leaf) -or -not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw 'run.raw.json and visual-index.json are required.' }
    $raw = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json -Depth 100
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 100
    $errors = [Collections.Generic.List[string]]::new()
    try {
        Assert-CSXVisualIndexSet -VisualIndex $index -Label 'Candidate' -ExpectedRunId ([string]$raw.runId)
        if ((Get-CSXFileSha256 $indexPath) -ne [string](Get-CSXPathValue $raw 'assays.visual.indexSha256')) { $errors.Add('Candidate visual-index SHA-256 binding does not match.') }
    }
    catch { $errors.Add($_.Exception.Message) }
    foreach ($failure in @($raw.automatedGates.failures)) { $errors.Add([string]$failure) }
    $reviewState = 'REVIEW_PENDING'
    $reviewResult = $null
    $reviewPath = Join-Path $root 'visual-review.json'
    if (Test-Path -LiteralPath $reviewPath -PathType Leaf) {
        try {
            $review = Get-Content -LiteralPath $reviewPath -Raw | ConvertFrom-Json -Depth 100
            $baselineIndex = $null
            if ([bool]$raw.prMode) {
                $baselineIndexPath = Resolve-CSXEvidencePath -EvidenceRoot $root -RelativePath ([string]$raw.baseline.visualIndexPath)
                if (-not (Test-Path -LiteralPath $baselineIndexPath -PathType Leaf)) { throw "Baseline visual index is missing: $baselineIndexPath" }
                $baselineIndex = Get-Content -LiteralPath $baselineIndexPath -Raw | ConvertFrom-Json -Depth 100
                Assert-CSXVisualIndexSet -VisualIndex $baselineIndex -Label 'Baseline' -ExpectedRunId ([string]$raw.baseline.baselineRunId)
                if ((Get-CSXFileSha256 $baselineIndexPath) -ne [string]$raw.baseline.visualIndexSha256) { throw 'Bundled baseline visual-index SHA-256 changed.' }
            }
            $reviewResult = Test-CSXVisualReview -EvidenceDirectory $root -RunRaw $raw -VisualIndex $index -Review $review -BaselineVisualIndex $baselineIndex
            if ($reviewResult.ok) { $reviewState = 'PASS' } else { foreach ($error in $reviewResult.errors) { $errors.Add($error) }; $reviewState = 'FAIL' }
        }
        catch { $errors.Add("Visual review validation failed: $($_.Exception.Message)"); $reviewState = 'FAIL' }
    }
    $status = if ($errors.Count -gt 0) { 'FAIL' } elseif ($reviewState -eq 'PASS') { 'PASS' } else { 'REVIEW_PENDING' }
    $report = [pscustomobject][ordered]@{
        schema = 'csx-render-scale-pr-v1'; status = $status; runId = $raw.runId
        generatedUtc = [DateTime]::UtcNow.ToString('o'); prMode = [bool]$raw.prMode
        protocol = $raw.protocol; fixture = $raw.fixture; runtime = $raw.runtime
        time = $raw.time; assays = $raw.assays; recoveries = Get-CSXPropertyValue $raw 'recoveries'; baseline = $raw.baseline
        automatedGates = $raw.automatedGates
        visualReview = [pscustomobject][ordered]@{ state = $reviewState; result = $reviewResult; path = $(if (Test-Path -LiteralPath $reviewPath) { $reviewPath } else { $null }) }
        warnings = @($raw.warnings); errors = @($errors | Select-Object -Unique)
        evidenceDirectory = $root
    }
    $runPath = Write-CSXJsonFile -Path (Join-Path $root 'run.json') -Value $report
    Write-CSXJsonFile -Path (Join-Path $root 'failures.json') -Value ([pscustomobject][ordered]@{
        schema = 'csx-render-scale-qualification-failures-v1'
        runId = $raw.runId
        status = $status
        errors = @($errors | Select-Object -Unique)
        warnings = @($raw.warnings)
    }) | Out-Null
    $cocCompleted = Get-CSXPathValue $raw 'assays.coc.completed' 0
    $cocMedian = Get-CSXPathValue $raw 'assays.coc.statistics.median'
    $cocP95 = Get-CSXPathValue $raw 'assays.coc.statistics.p95'
    $cocMax = Get-CSXPathValue $raw 'assays.coc.statistics.max'
    $cocFailures = Get-CSXPathValue $raw 'assays.coc.failureCount' 0
    $cocWilsonLower = Get-CSXPathValue $raw 'assays.coc.failureWilson95.lower'
    $cocWilsonUpper = Get-CSXPathValue $raw 'assays.coc.failureWilson95.upper'
    $stretchMeanFrames = Get-CSXPathValue $raw 'assays.coc.stretch.meanFrames'
    $stretchMeanMs = Get-CSXPathValue $raw 'assays.coc.stretch.meanMs'
    $stretchMaxFrames = Get-CSXPathValue $raw 'assays.coc.stretch.maxFrames'
    $stretchMaxMs = Get-CSXPathValue $raw 'assays.coc.stretch.maxMs'
    $menuName = Get-CSXPathValue $raw 'assays.menu.matrixName' 'not-run'
    $menuCompleted = Get-CSXPathValue $raw 'assays.menu.completed' 0
    $menuMedian = Get-CSXPathValue $raw 'assays.menu.statistics.median'
    $menuP95 = Get-CSXPathValue $raw 'assays.menu.statistics.p95'
    $traceOutcome = Get-CSXPathValue $raw 'assays.menu.dlssTrace.outcome' 'not-run'
    $visualCompleted = Get-CSXPathValue $raw 'assays.visual.completedReplicates' 0
    $cocStats = Get-CSXPathValue $raw 'assays.coc.statistics'
    $menuStats = Get-CSXPathValue $raw 'assays.menu.statistics'
    $baselineBuild = Get-CSXPathValue $raw 'baseline.baselineBuildId' 'not applicable'
    $baselineRun = Get-CSXPathValue $raw 'baseline.baselineRunId' 'not applicable'
    $fixtureId = Get-CSXPathValue $raw 'fixture.manifest.fixtureId' 'unknown'
    $fixtureFingerprint = Get-CSXPathValue $raw 'fixture.fingerprint' 'unknown'
    $recoveryOne = Get-CSXPathValue $raw 'recoveries.one.state' 'not-run'
    $recoveryTwo = Get-CSXPathValue $raw 'recoveries.two.state' 'not-run'
    $recoveryOneWall = Get-CSXPathValue $raw 'recoveries.one.wallClockMs' 'not-run'
    $recoveryTwoWall = Get-CSXPathValue $raw 'recoveries.two.wallClockMs' 'not-run'
    $traceGroups = @(Get-CSXPathValue $raw 'assays.menu.dlssTrace.evidence.groups' @())
    $traceSetConstants = [uint64](($traceGroups | ForEach-Object { [uint64](Get-CSXPropertyValue $_.summary 'setConstantsCalls' 0) } | Measure-Object -Sum).Sum)
    $traceEvaluates = [uint64](($traceGroups | ForEach-Object { [uint64](Get-CSXPropertyValue $_.summary 'evaluateCalls' 0) } | Measure-Object -Sum).Sum)
    $traceDropped = [uint64](($traceGroups | ForEach-Object { [uint64](Get-CSXPropertyValue $_.summary 'droppedRecords' 0) } | Measure-Object -Sum).Sum)
    $cocDelta = Get-CSXPathValue $raw 'baseline.cocPaired.aggregateDelta'
    $menuDelta = Get-CSXPathValue $raw 'baseline.menuPaired.aggregateDelta'
    $speedLine = if ([bool]$raw.prMode) {
        $cocMedianDelta = Get-CSXPathValue $cocDelta 'median.percent' 'unavailable'
        $cocP95Delta = Get-CSXPathValue $cocDelta 'p95.percent' 'unavailable'
        $menuMedianDelta = Get-CSXPathValue $menuDelta 'median.percent' 'unavailable'
        $menuP95Delta = Get-CSXPathValue $menuDelta 'p95.percent' 'unavailable'
        "- Speed vs baseline: COC median $cocMedianDelta%, p95 $cocP95Delta%; menu median $menuMedianDelta%, p95 $menuP95Delta%."
    }
    else { '- Speed vs baseline: not applicable (standalone run).' }
    $markdown = @(
        '## Render-scale qualification', '',
        "- Protocol: csx-render-scale-pr-v1 revision $($raw.protocol.revision), SHA-256 $($raw.protocol.sha256).",
        "- Required DLSS trace methods: commit $(Get-CSXPathValue $raw 'protocol.requiredMethodsCommit' 'unknown'); dlss_trace_status, dlss_trace_reset, dlss_trace_start, dlss_trace_stop, dlss_trace_read.",
        "- Result: **$status**; GPU matrix: $(Get-CSXPathValue $raw 'fixture.gpuVendor' 'unknown') / $menuName.",
        "- Candidate build: $($raw.runtime.buildId); baseline build/run: $baselineBuild / $baselineRun.",
        "- Fixture: $fixtureId; fingerprint $fixtureFingerprint.",
        "- Time: $($raw.time.orchestrationElapsedMs) ms automated (limit 600000 ms); $($raw.time.performanceElapsedMs) ms performance interval.",
        "- Recovery barriers: first $recoveryOne / $recoveryOneWall ms; second $recoveryTwo / $recoveryTwoWall ms (30,000 ms requested each).",
        "- COC: $cocCompleted/20 stable; wall $((Get-CSXPathValue $raw 'assays.coc.wallClockMs')) ms; total $((Get-CSXPropertyValue $cocStats 'total')) ms; min $((Get-CSXPropertyValue $cocStats 'min')) ms; median $cocMedian ms; mean $((Get-CSXPropertyValue $cocStats 'mean')) ms; SD $((Get-CSXPropertyValue $cocStats 'sampleStandardDeviation')) ms; CV $((Get-CSXPropertyValue $cocStats 'coefficientOfVariation')); p95 $cocP95 ms; max $cocMax ms; rate $((Get-CSXPropertyValue $cocStats 'transitionsPerMinute'))/min.",
        "- COC failures: $cocFailures events in $((Get-CSXPathValue $raw 'assays.coc.failedTransitions' 0)) transitions; Wilson 95% CI [$cocWilsonLower, $cocWilsonUpper].",
        "- Presentation stretch: mean $stretchMeanFrames frames / $stretchMeanMs ms; max $stretchMaxFrames frames / $stretchMaxMs ms; incomplete stereo at stop $((Get-CSXPathValue $raw 'assays.coc.stretch.incompleteStereoCycleAtStop' 'unknown')).",
        "- CS menu: $menuCompleted/25 stable; wall $((Get-CSXPathValue $raw 'assays.menu.wallClockMs')) ms; total $((Get-CSXPropertyValue $menuStats 'total')) ms; min $((Get-CSXPropertyValue $menuStats 'min')) ms; median $menuMedian ms; mean $((Get-CSXPropertyValue $menuStats 'mean')) ms; SD $((Get-CSXPropertyValue $menuStats 'sampleStandardDeviation')) ms; CV $((Get-CSXPropertyValue $menuStats 'coefficientOfVariation')); p95 $menuP95 ms; max $((Get-CSXPropertyValue $menuStats 'max')) ms; rate $((Get-CSXPropertyValue $menuStats 'transitionsPerMinute'))/min.",
        "- DLSS trace: $traceOutcome; $($traceGroups.Count) scoped sessions; $traceSetConstants constants calls; $traceEvaluates evaluate calls; $traceDropped dropped records.",
        "- Visual captures: $visualCompleted/3 complete, $((Get-CSXPathValue $raw 'assays.visual.validatedChildReceipts' 0))/48 child receipts validated; review $reviewState.",
        $speedLine,
        "- Evidence: $root", ''
    ) -join [Environment]::NewLine
    if ($status -ne 'PASS') {
        $markdown += "`nThis is not a passing PR qualification. " + $(if ($status -eq 'REVIEW_PENDING') { 'Complete visual-review.json and rerun -FinalizeReview.' } else { 'See run.json errors.' }) + "`n"
    }
    $summaryPath = Write-CSXTextFile -Path (Join-Path $root 'pr-summary.md') -Value $markdown
    return [pscustomobject][ordered]@{ report = $report; runPath = $runPath; summaryPath = $summaryPath }
}

Export-ModuleMember -Function Assert-CSXProtocol, Get-CSXQualificationProtocol, Get-CSXFixtureManifest, Write-CSXJsonFile, Write-CSXTextFile, Get-CSXFileSha256,
    Get-CSXPropertyValue, Get-CSXPathValue, ConvertTo-CSXHashtable, Add-CSXExactRuntimeToProfile, Get-CSXFoveationTarget,
    New-CSXCocScenario, New-CSXMenuScenario, New-CSXRecoveryScenario, New-CSXVisualSequenceRequest,
    New-CSXMcpConnection, Invoke-CSXMcpTool, Get-CSXRemainingMilliseconds, Get-CSXBoundedTimeoutSeconds,
    Get-CSXNearestRankPercentile, Get-CSXMedian, Get-CSXMetricSummary, Get-CSXWilsonInterval, Get-CSXQualificationWaitRecords,
    Test-CSXFoveationEvidence, Test-CSXDLSSCaptureSummary, Test-CSXDLSSScenarioEvidence, Get-CSXPairedComparison,
    Assert-CSXVisualIndexSet, Resolve-CSXEvidencePath, New-CSXVisualReviewTemplate, Test-CSXVisualReview, Update-CSXQualificationReport
