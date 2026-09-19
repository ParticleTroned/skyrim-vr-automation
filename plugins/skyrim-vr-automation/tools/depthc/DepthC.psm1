#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-DepthCPlan {
    param([Parameter(Mandatory)][int[]]$SaveNumbers)
    $ordinal = 0; $scene = 0
    foreach ($number in $SaveNumbers) {
        if ($number -lt 0) { throw 'Save numbers must be nonnegative.' }
        $scene++
        $modeIndex = 0
        foreach ($mode in @(
            @{name='DLAA';method='dlss';qualityMode='native_aa';quality=0;renderScaleMode=$false},
            @{name='DLSS-RS-OFF';method='dlss';qualityMode='hoshipa';quality=1;renderScaleMode=$false},
            @{name='DLSS-RS-ON';method='dlss';qualityMode='hoshipa';quality=1;renderScaleMode=$true},
            @{name='FSR3-AA';method='fsr';qualityMode='native_aa';quality=0;renderScaleMode=$false},
            @{name='FSR3-RS-OFF';method='fsr';qualityMode='hoshipa';quality=1;renderScaleMode=$false},
            @{name='FSR3-RS-ON';method='fsr';qualityMode='hoshipa';quality=1;renderScaleMode=$true}
        )) {
            $modeIndex++; $conditionIndex=0
            foreach ($condition in @('Balanced','Performance','Legacy','Culling-OFF','Interior-OFF','Frustum-fast-ON','Backoff-ON','Balanced-repeat')) {
                $ordinal++; $conditionIndex++
                [pscustomobject]@{
                    ordinal=$ordinal; pairIndex=$scene; modeIndex=$modeIndex; conditionIndex=$conditionIndex
                    saveNumber=$number.ToString('00', [Globalization.CultureInfo]::InvariantCulture)
                    mode=$mode.name; method=$mode.method; qualityMode=$mode.qualityMode; quality=$mode.quality
                    renderScaleMode=$mode.renderScaleMode; condition=$condition
                    firstInSave=($modeIndex -eq 1 -and $conditionIndex -eq 1)
                    lastInSave=($modeIndex -eq 6 -and $conditionIndex -eq 8)
                }
            }
        }
    }
}

function Convert-DepthCProfile {
    param($Profile)
    $out = @{}
    $allowed = @{method=@('none','taa','dlss','fsr');qualityMode=@('native_aa','hoshipa','ultra_quality','quality','balanced','performance','ultra_performance');dlssProfile=@('J','K','L','M','F','E');fsrRuntime=@('fsr3','fsr4')}
    foreach ($key in $allowed.Keys) {
        if ($Profile.$key.name -cnotin $allowed[$key]) { throw "Unsupported profile $key." }
        $out[$key] = $Profile.$key.name
    }
    if ($Profile.renderScaleMode -isnot [bool]) { throw 'Missing profile render-scale flag.' }
    $out.renderScaleMode = $Profile.renderScaleMode
    return $out
}

function Assert-DepthCProfile {
    param($NamedProfile, [hashtable]$Target)
    $actual=Convert-DepthCProfile $NamedProfile
    foreach ($key in $Target.Keys) {
        if ($actual[$key] -cne $Target[$key]) { throw "Profile target changed: $key." }
    }
}

function Get-DepthCControlState {
    param($Status)
    $out = [ordered]@{}
    $depth=$Status.depthCulling
    if ($depth.schemaVersion -ne 1 -or $depth.available -cne $true) { throw 'Unknown or unavailable native depth-culling controls.' }
    $fields=@{depthCullingExteriorEnabled='masterEnabled';depthCullingInteriorEnabled='interiorEnabled';depthCullingPerformanceMode='performanceMode';depthCullingLegacyMode='legacyMode'}
    foreach ($key in $fields.Keys) {
        $value=$depth.($fields[$key])
        if ($value -isnot [bool]) { throw "Missing depth control $key." }
        $out[$key]=$value
    }
    foreach ($entry in @(
        @{key='fast';value=$Status.frustumFastPath.enabled},
        @{key='backoff';value=$Status.nativeFrustum.depthJobs.backoff.enabled},
        @{key='collection';value=$Status.nativeFrustum.enabled},
        @{key='detail';value=$Status.nativeFrustum.detailEnabled},
        @{key='temporalTelemetry';value=$Status.depthCulling.telemetryEnabled}
    )) {
        if ($entry.value -isnot [bool]) { throw "Missing diagnostic control $($entry.key)." }
        $out[$entry.key]=$entry.value
    }
    if (!$out.collection -or !$out.detail) { throw 'depthc requires matched enabled detailed native collection; it never changes diagnostic controls.' }
    return $out
}

function Get-DepthCConditionControls {
    param([string]$Condition, $Original)
    $out=@{};foreach($key in $Original.Keys){$out[$key]=$Original[$key]}
    $out.depthCullingExteriorEnabled=$true; $out.depthCullingInteriorEnabled=$true
    $out.depthCullingPerformanceMode=$false; $out.depthCullingLegacyMode=$false
    $out.fast=$false; $out.backoff=$false
    switch ($Condition) {
        'Balanced' { }
        'Balanced-repeat' { }
        'Performance' { $out.depthCullingPerformanceMode=$true }
        'Legacy' { $out.depthCullingLegacyMode=$true }
        'Culling-OFF' { $out.depthCullingExteriorEnabled=$false }
        'Interior-OFF' { $out.depthCullingInteriorEnabled=$false }
        'Frustum-fast-ON' { $out.fast=$true }
        'Backoff-ON' { $out.backoff=$true }
        default { throw 'Unknown depthc condition.' }
    }
    return $out
}

function Assert-DepthCControls {
    param($Status, $Expected)
    $actual=Get-DepthCControlState $Status
    foreach($key in $Expected.Keys){if($actual[$key] -cne $Expected[$key]){throw "Depthc control changed: $key."}}
    Assert-FrustrumState $Status.frustumFastPath ([bool]$Expected.fast)
    $native=$Status.nativeFrustum; $jobs=$native.depthJobs; $backoff=$jobs.backoff
    foreach($value in @($native.collectionGeneration,$native.collectionGenerationAtEnd,$backoff.control,$backoff.controlAtEnd)){
        if(($value -isnot [long] -and $value -isnot [int]) -or $value -lt 0){throw 'Invalid diagnostic generation/control.'}
    }
    if ($native.schemaVersion -ne 2 -or $jobs.schemaVersion -ne 1 -or $backoff.schemaVersion -ne 1 -or
        $native.active -cne $true -or $jobs.installed -cne $true -or $jobs.active -cne $true -or
        $backoff.active -cne $Expected.backoff -or $backoff.control -ne $backoff.controlAtEnd -or
        $native.collectionGeneration -ne $native.collectionGenerationAtEnd) { throw 'Invalid or changing native diagnostics/backoff admission.' }
}

function Get-DepthCRouting {
    param($Status)
    $routing = $Status.runtimeRouting
    foreach ($key in @('configuredMethod','runtimeMethod')) {
        if ($routing.$key -isnot [string] -or !$routing.$key) { throw "Missing live routing $key." }
    }
    if ($routing.runtimeQualityMode -isnot [long] -and $routing.runtimeQualityMode -isnot [int]) { throw 'Missing live quality identity.' }
    foreach ($key in @('renderScaleRequested','renderScaleLatched','presentationUpscalingActive')) {
        if ($routing.$key -isnot [bool]) { throw "Invalid live routing $key." }
    }
    if(($routing.runtimeDLSSPreset -isnot [long] -and $routing.runtimeDLSSPreset -isnot [int]) -or $routing.runtimeDLSSPreset -lt 0 -or $routing.runtimeDLSSPreset -gt 5 -or
        $routing.configuredFsrRuntime -cnotin @('fsr3','fsr4')){throw 'Missing current vendor preset/runtime identity.'}
    # Order is fixed so identity comparison is independent of producer JSON key order.
    [ordered]@{
        configuredMethod=$routing.configuredMethod; runtimeMethod=$routing.runtimeMethod
        quality=$routing.runtimeQualityMode; dlssPreset=$routing.runtimeDLSSPreset; fsrRuntime=$routing.configuredFsrRuntime; renderScaleRequested=$routing.renderScaleRequested
        renderScaleLatched=$routing.renderScaleLatched; presentationUpscalingActive=$routing.presentationUpscalingActive
    } | ConvertTo-Json -Compress
}

function Test-DepthCRecovered {
    param($Payload)
    $record = $Payload.record
    if ($record.schema -cne 'community-shaders.vr-render-scale.iteration' -or $record.schemaVersion -ne 14) {
        throw 'depthc requires iteration record schema 14; missing/future evidence is unsupported.'
    }
    $depth=$Payload.status.depthCulling
    if($depth.schemaVersion -ne 1 -or $depth.available -cne $true -or !$depth.currentCellFormId){throw 'Missing native depth-culling admission state.'}
    foreach($key in @('masterEnabled','interiorEnabled','currentInterior','nativeEnabled','cacheRefreshPending')){if($depth.$key -isnot [bool]){throw "Missing depth-culling $key."}}
    $expectedNative=$depth.masterEnabled -and (!$depth.currentInterior -or $depth.interiorEnabled)
    if($depth.cacheRefreshPending -or $depth.nativeEnabled -ne $expectedNative){return $false}
    $routing = $Payload.status.runtimeRouting
    if ($Payload.status.fsrDispatch.shaderCompilationActive -isnot [bool]) { throw 'Missing shader compilation status.' }
    if ($Payload.status.fsrDispatch.shaderCompilationActive) { return $false }
    $null = Get-DepthCRouting $Payload.status
    $ready = $true
    $gate = $Payload.status.vendorWorkGate
    foreach ($key in @('active','mainMenu','loadingMenu','recoveryPending','relatchPending','relatchInProgress','profileTransitionPending','postLoadResetPending')) {
        if ($gate.$key -isnot [bool]) { throw "Missing recovery status $key." }
        if ($gate.$key) { $ready = $false }
    }
    if ($gate.completedWorldFrame -isnot [bool]) { throw 'Missing completed-world-frame evidence.' }
    if (!$gate.completedWorldFrame) { $ready = $false }
    $required = @('terminal_state','no_failures','no_out_of_memory','no_device_loss','fidelity_invariants',
        'presentation_stretch_complete_stereo_at_stop','presentation_stretch_inactive_at_stop',
        'retirement_drained','common_target_predrain','memory_trim_failures','memory_trim_drained',
        'backend_ready','vendor_lifecycle_mutation_released')
    if ($routing.renderScaleRequested) {
        $required += 'presentation_recovered'
        if (!$routing.renderScaleLatched -or !$routing.presentationUpscalingActive) { $ready = $false }
    } elseif ($routing.renderScaleLatched -or $routing.presentationUpscalingActive) { $ready = $false }
    foreach ($name in $required) {
        $values = @($record.acceptance.gates | Where-Object name -CEQ $name)
        if ($values.Count -ne 1 -or $values[0].passed -isnot [bool]) { throw "Missing/ambiguous recovery gate $name." }
        if (!$values[0].passed) { $ready = $false }
    }
    $stretch = $record.presentationPath.allowedPresentationStretch
    foreach ($key in @('episodeActive','activeAtStop','incompleteStereoCycleAtStop')) {
        if ($stretch.$key -isnot [bool]) { throw "Missing stretch/stereo evidence $key." }
        if ($stretch.$key) { $ready = $false }
    }
    return $ready
}

function Assert-DepthCRecovered {
    param($Payload, [string]$RoutingIdentity, $Mode = $null)
    if (!(Test-DepthCRecovered $Payload)) { throw 'The settled scene lost render recovery, stereo completeness or debt-free health.' }
    if ($Mode) { Assert-DepthCMode $Payload.status $Mode }
    if ($RoutingIdentity -and (Get-DepthCRouting $Payload.status) -cne $RoutingIdentity) {
        throw 'The selected/executed upscaling profile changed within the settled scene.'
    }
}


function Test-DepthCMode {
    param($Status, $Mode)
    $r=$Status.runtimeRouting
    if ($r.configuredMethod -cne $Mode.method -or $r.runtimeMethod -cne $Mode.method -or
        $r.runtimeDLSSPreset -ne $Mode.dlssPreset -or $r.configuredFsrRuntime -cne $Mode.fsrRuntime -or
        $r.runtimeQualityMode -ne $Mode.quality -or $r.renderScaleRequested -cne $Mode.renderScaleMode -or
        $r.renderScaleLatched -cne $Mode.renderScaleMode -or $r.presentationUpscalingActive -cne $Mode.renderScaleMode) { return $false }
    $proof=$Status.compositorSubmission
    if ($proof.schemaVersion -ne 1 -or $proof.current.poisoned -isnot [bool] -or
        ($proof.droppedObservations -isnot [long] -and $proof.droppedObservations -isnot [int]) -or $proof.droppedObservations -lt 0) {
        throw 'Missing/unknown compositor submission proof.'
    }
    if(($proof.observedDropCount -isnot [long] -and $proof.observedDropCount -isnot [int]) -or $proof.observedDropCount -lt 0){throw 'Missing compositor loss-consumption identity.'}
    if($proof.observedDropCount -ne $proof.droppedObservations){return $false}
    $pair=$proof.lastCompleted
    foreach($key in @('valid','poisoned','renderScaleMode')){if($pair.$key -isnot [bool]){throw "Invalid compositor proof $key."}}
    foreach($key in @('eyeMask','frame','compositorCycleToken','methodValue','qualityMode','mainPassCompletedFrame')){
        if(($pair.$key -isnot [long] -and $pair.$key -isnot [int]) -or $pair.$key -lt 0){throw "Invalid compositor proof $key."}
    }
    if(($Status.frame -isnot [long] -and $Status.frame -isnot [int]) -or $Status.frame -lt 0){throw 'Invalid current frame.'}
    $method=if($Mode.method -eq 'dlss'){3}else{2}
    if($proof.current.poisoned -or !$pair.valid -or $pair.poisoned -or $pair.eyeMask -ne 3 -or
        $pair.methodValue -ne $method -or $pair.qualityMode -ne $Mode.quality -or $pair.renderScaleMode -cne $Mode.renderScaleMode -or
        $pair.frame -gt $Status.frame -or $Status.frame-$pair.frame -gt 2){return $false}
    if(!$Mode.renderScaleMode -and $pair.mainPassCompletedFrame -ne $pair.frame){return $false}
    if($Mode.method -eq 'fsr'){
        if($Mode.renderScaleMode -and $Status.fsrDispatch.authoritativeFsr4RuntimeEnabled -cne $false){return $false}
        if($Mode.renderScaleMode){
            $dispatch=$Status.fsrDispatch
            foreach($key in @('actualDispatchBothEyesValid','actualDispatchBackendConverged','actualRuntimeFallbackObserved')){if($dispatch.$key -isnot [bool]){throw "Invalid physical FSR flag $key."}}
            if(($dispatch.actualDispatchFrame -isnot [long] -and $dispatch.actualDispatchFrame -isnot [int]) -or $dispatch.actualDispatchFrame -lt 0){throw 'Missing physical FSR frame identity.'}
            if($dispatch.actualDispatchBothEyesValid -cne $true -or $dispatch.actualDispatchBackendConverged -cne $true -or
                $dispatch.actualDispatchBackend -cnotin @('fsr_host','fsr_runtime') -or $dispatch.actualRuntimeFallbackObserved -cne $false -or
                $dispatch.actualDispatchFrame -ne $pair.frame -or $dispatch.actualDispatchFrame -gt $Status.frame -or $Status.frame-$dispatch.actualDispatchFrame -gt 2){return $false}
        }else{
            foreach($key in @('mainPassFsrDispatchFrame','mainPassFsrDispatchSerial')){
                if(($pair.$key -isnot [long] -and $pair.$key -isnot [int]) -or $pair.$key -lt 0){throw 'Missing fixed-resolution FSR dispatch proof in the completed pair.'}
            }
            if($pair.mainPassFsrDispatchSerial -le 0 -or $pair.mainPassFsrDispatchPath -cnotin @('kHostFsr31','kRuntimeFsr31') -or
                $pair.mainPassFsrDispatchFrame -ne $pair.frame){return $false}
        }
    }
    return $true
}

function Assert-DepthCMode {
    param($Status, $Mode)
    if(!(Test-DepthCMode $Status $Mode)){throw 'Requested/executed mode and fresh both-eye physical dispatch are not proven.'}
}

Export-ModuleMember -Function New-DepthCPlan, Get-DepthCRouting, Test-DepthCRecovered, Assert-DepthCRecovered, Convert-DepthCProfile, Assert-DepthCProfile, Get-DepthCControlState, Get-DepthCConditionControls, Assert-DepthCControls, Assert-DepthCMode, Test-DepthCMode
