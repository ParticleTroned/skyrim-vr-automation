# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory)][string]$EvidenceDirectory,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$RuntimePath,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBuildId,
    [Parameter(Mandatory, ParameterSetName = 'Run')][ValidateSet('NVIDIA', 'AMD')][string]$GpuVendor,
    [Parameter(Mandatory, ParameterSetName = 'Run')][string]$FixtureManifestPath,
    [Parameter(ParameterSetName = 'Run')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedArtifactSha256,
    [Parameter(ParameterSetName = 'Run')][switch]$PrMode,
    [Parameter(ParameterSetName = 'Run')][string]$BaselinePath,
    [Parameter(ParameterSetName = 'Run')][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedBaselineBuildId,
    [Parameter(Mandatory, ParameterSetName = 'Finalize')][switch]$FinalizeReview,
    [string]$ProtocolPath = (Join-Path $PSScriptRoot 'protocol.v1.json'),
    [switch]$NoExit,
    [switch]$Compact
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RenderScaleQualification.psm1') -Force

function Get-NamedValue($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value.ToLowerInvariant() }
    $name = Get-CSXPropertyValue $Value 'name'
    return $(if ($null -ne $name) { ([string]$name).ToLowerInvariant() } else { ([string]$Value).ToLowerInvariant() })
}

function Get-SceneCellEditorId($Scene) {
    $cell = Get-CSXPropertyValue $Scene 'cell'
    if ($cell -is [string]) { return [string]$cell }
    return [string](Get-CSXPropertyValue $cell 'editorId')
}

function Assert-ToolActions($ToolDescriptor, [string[]]$Actions) {
    $available = @((Get-CSXPathValue $ToolDescriptor 'inputSchema.properties.action.enum'))
    foreach ($action in $Actions) {
        if ($action -notin $available) { throw "Tool '$($ToolDescriptor.name)' does not advertise required action '$action'." }
    }
}

function Assert-AuthoritativeRuntimeBinding($BindingIdentity, $Health) {
    if ($null -eq $BindingIdentity -or -not [bool](Get-CSXPropertyValue $BindingIdentity 'verified' $false)) {
        throw 'Authoritative runtime identity is missing or unverified.'
    }
    $expectedPid = [int](Get-CSXPropertyValue $BindingIdentity 'listenerPid' 0)
    $healthPid = [int](Get-CSXPropertyValue $Health 'pid' 0)
    $expectedExe = [string](Get-CSXPathValue $BindingIdentity 'health.exe')
    $healthExe = [string](Get-CSXPropertyValue $Health 'exe')
    if ($expectedPid -le 0 -or $healthPid -ne $expectedPid -or
        [string]::IsNullOrWhiteSpace($expectedExe) -or
        -not [string]::Equals($healthExe, $expectedExe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The raw MCP session health identity differs from the authoritative binding.'
    }
    $expectedStart = [string](Get-CSXPathValue $BindingIdentity 'process.startTimeUtc')
    $expectedPath = [string](Get-CSXPathValue $BindingIdentity 'process.path')
    if ([string]::IsNullOrWhiteSpace($expectedStart)) { throw 'Authoritative runtime identity omitted process start time.' }
    try {
        $process = Get-Process -Id $expectedPid -ErrorAction Stop
        $actualStart = $process.StartTime.ToUniversalTime().ToString('o')
        $actualPath = $(try { [string]$process.Path } catch { $null })
    }
    catch { throw "Could not revalidate the authoritative listener process: $($_.Exception.Message)" }
    if (-not [string]::Equals($actualStart, $expectedStart, [StringComparison]::Ordinal) -or
        (-not [string]::IsNullOrWhiteSpace($expectedPath) -and
            -not [string]::Equals($actualPath, $expectedPath, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'The authoritative listener process was replaced after tools/list binding.'
    }
    return [pscustomobject][ordered]@{
        verified = $true; pid = $expectedPid; exe = $healthExe; processPath = $actualPath; processStartTimeUtc = $actualStart
    }
}

function Invoke-BoundTool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)]$Arguments,
        [int]$OperationCapMs = 15000,
        [switch]$AllowSemanticFailure
    )
    $timeout = Get-CSXBoundedTimeoutSeconds -Stopwatch $script:orchestrationWatch -BudgetMs ([int]$script:protocol.timeBudget.orchestrationMs) -OperationCapMs $OperationCapMs
    return Invoke-CSXMcpTool -Connection $script:connection -Tool $Tool -Arguments $Arguments -TimeoutSeconds $timeout -AllowSemanticFailure:$AllowSemanticFailure
}

function Assert-CSXProducer($Value, [string]$Label) {
    $producer = Get-CSXPropertyValue $Value 'producer'
    if ($null -eq $producer) { throw "$Label did not return producer identity." }
    if ([string](Get-CSXPropertyValue $producer 'buildId') -ne $script:expectedBuildId) { throw "$Label returned a different CSX Build ID." }
}

function Get-UpscalingSnapshot([string]$CommandId) {
    $result = Invoke-BoundTool -Tool 'communityshaders.upscaling_api' -Arguments ([ordered]@{
        action = 'snapshot'; expectedBuildId = $script:expectedBuildId; clientId = 'csx-render-scale-qualification'; commandId = $CommandId
    })
    Assert-CSXProducer $result 'upscaling snapshot'
    if ((Get-NamedValue (Get-CSXPropertyValue $result 'status')) -ne 'success') { throw 'Upscaling snapshot was not successful.' }
    return $result
}

function Get-FeatureSettings([string]$CommandId) {
    $result = Invoke-BoundTool -Tool 'communityshaders.feature_api' -Arguments ([ordered]@{
        contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = $CommandId
        action = 'settings'; featureShortName = 'Upscaling'; expectedBuildId = $script:expectedBuildId
    })
    $producer = Get-CSXPathValue $result 'server.producer' (Get-CSXPropertyValue $result 'producer')
    if ($producer -and [string](Get-CSXPropertyValue $producer 'buildId') -ne $script:expectedBuildId) { throw 'Feature settings returned a different CSX Build ID.' }
    if ([string](Get-CSXPathValue $result 'result.status') -ne 'success') { throw 'Upscaling feature settings were unavailable.' }
    return $result
}

function Assert-FoveationSettings($SettingsResult) {
    $settings = Get-CSXPathValue $SettingsResult 'result.settings'
    if ($null -eq $settings) { throw 'Upscaling settings receipt omitted settings.' }
    $expected = Get-CSXFoveationTarget $script:protocol
    $mapping = [ordered]@{
        foveatedVendorDispatch = @('foveatedVendorDispatch')
        foveatedCenterArea = @('foveatedCenterArea')
        peripheryTAAEnable = @('periphery_taa_enable', 'peripheryTAAEnable')
        peripheryTAACenterArea = @('periphery_taa_center_area', 'peripheryTAACenterArea')
        peripheryTAAOuterScale = @('periphery_taa_outer_scale', 'peripheryTAAOuterScale')
    }
    foreach ($expectedName in $mapping.Keys) {
        $actual = $null
        foreach ($name in $mapping[$expectedName]) {
            $candidate = Get-CSXPropertyValue $settings $name
            if ($null -ne $candidate) { $actual = $candidate; break }
        }
        if ($null -eq $actual) { throw "Upscaling settings omitted '$expectedName'." }
        $wanted = $expected[$expectedName]
        if ($wanted -is [bool]) {
            if ([bool]$actual -ne [bool]$wanted) { throw "Foveation setting '$expectedName' does not match the fixture." }
        }
        elseif ([Math]::Abs([double]$actual - [double]$wanted) -gt 0.0001) { throw "Foveation setting '$expectedName' does not match the fixture." }
    }
}

function Assert-ExteriorSnapshot($SnapshotResult, [string]$ExpectedFsrRuntime = '') {
    $snapshot = Get-CSXPropertyValue $SnapshotResult 'snapshot'
    $profiles = Get-CSXPropertyValue $snapshot 'profiles'
    if ($null -eq $profiles) { throw 'Upscaling snapshot omitted profile agreement evidence.' }
    $runtime = $null
    foreach ($name in @('requested', 'effective', 'stable')) {
        $profile = Get-CSXPropertyValue $profiles $name
        if ($null -eq $profile -or (Get-NamedValue $profile.method) -ne 'fsr' -or (Get-NamedValue $profile.qualityMode) -ne 'hoshipa' -or -not [bool]$profile.renderScaleMode) {
            throw "Upscaling snapshot profile '$name' is not exact exterior FSR Hoshipa."
        }
        $profileRuntime = Get-NamedValue $profile.fsrRuntime
        if ($profileRuntime -notin @('fsr3', 'fsr4')) { throw "Upscaling snapshot profile '$name' omitted an authoritative FSR runtime." }
        if ($null -eq $runtime) { $runtime = $profileRuntime } elseif ($runtime -ne $profileRuntime) { throw 'Upscaling snapshot FSR runtime profiles disagree.' }
    }
    if ($ExpectedFsrRuntime -and $runtime -ne $ExpectedFsrRuntime) { throw "Upscaling snapshot FSR runtime drifted from '$ExpectedFsrRuntime' to '$runtime'." }
    return $runtime
}

function Assert-MethodAvailability($CapabilitiesResult) {
    $capabilities = Get-CSXPropertyValue $CapabilitiesResult 'capabilities'
    if ((Get-NamedValue $capabilities.runtime) -ne 'skyrim_vr') { throw 'The upscaling service is not bound to Skyrim VR.' }
    $mask = [uint64]$capabilities.availableMethodMask
    if (($mask -band (1L -shl 2)) -eq 0) { throw 'FSR is not currently available.' }
    if ($script:gpuVendor -eq 'NVIDIA' -and ($mask -band (1L -shl 3)) -eq 0) { throw 'NVIDIA qualification requires DLSS to be currently available.' }
}

function Assert-RenderScaleInactiveCaptures($Status, [switch]$AllowTrace) {
    if ([bool](Get-CSXPathValue $Status 'status.session.active' $false)) { throw 'A render-scale stress session is already active.' }
    if ([bool](Get-CSXPathValue $Status 'status.cpuPerformance.active' $false)) { throw 'A CPU performance session is already active.' }
    if (-not $AllowTrace -and [bool](Get-CSXPathValue $Status 'capture.active' $false)) { throw 'A DLSS trace session is already active.' }
}

function Invoke-DiagnosticStart([string]$Label) {
    foreach ($action in @('reset', 'cpu_performance_reset')) {
        $result = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = $action; expectedBuildId = $script:expectedBuildId })
        Assert-CSXProducer $result "$Label $action"
    }
    $script:ownsStressCapture = $true
    $stress = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'start'; expectedBuildId = $script:expectedBuildId })
    Assert-CSXProducer $stress "$Label start"
    $script:ownsCpuCapture = $true
    $cpu = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'cpu_performance_start'; expectedBuildId = $script:expectedBuildId })
    Assert-CSXProducer $cpu "$Label cpu_performance_start"
}

function Invoke-DiagnosticStop([string]$Label) {
    $cpu = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'cpu_performance_stop'; expectedBuildId = $script:expectedBuildId })
    Assert-CSXProducer $cpu "$Label CPU stop"
    $script:ownsCpuCapture = $false
    $stress = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'stop'; expectedBuildId = $script:expectedBuildId })
    Assert-CSXProducer $stress "$Label stress stop"
    $script:ownsStressCapture = $false
    return [pscustomobject][ordered]@{ cpu = $cpu; stress = $stress }
}

function Invoke-EmergencyCleanup {
    param([Collections.Generic.List[string]]$Warnings)
    try {
        $cleanupConnection = New-CSXMcpConnection -Runtime $script:runtime -ClientName 'CSXRenderScaleQualificationCleanup'
        $cleanupHealth = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'inspect' -Arguments ([ordered]@{
            kind = 'health'
        }) -TimeoutSeconds 5
        $cleanupIdentity = Assert-AuthoritativeRuntimeBinding -BindingIdentity $script:bindingIdentity -Health $cleanupHealth
        Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'cleanup\runtime-identity.json') -Value $cleanupIdentity | Out-Null
        if ($script:visualStartMayBeOwned -and -not $script:activeVisualRequestId) {
            $uncertainScreenshot = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{
                contractMajor = 1; clientId = 'csx-render-scale-qualification-cleanup'; commandId = "$($script:runId)-cleanup-uncertain-screenshot-status"; action = 'status'
            }) -TimeoutSeconds 5 -AllowSemanticFailure
            $uncertainRequestId = [string](Get-CSXPathValue $uncertainScreenshot 'result.dispatcher.activeAcquisitionRequestId')
            if ($uncertainRequestId -match '\S') { $script:activeVisualRequestId = $uncertainRequestId }
            elseif ([int](Get-CSXPathValue $uncertainScreenshot 'result.dispatcher.activeSequences' 0) -ne 0) {
                throw 'An uncertain screenshot start left active work without a cancellable request ID.'
            }
        }
        if ($script:activeVisualRequestId) {
            Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{
                contractMajor = 1; clientId = 'csx-render-scale-qualification-cleanup'; commandId = "$($script:runId)-cleanup-cancel"
                action = 'request_cancel'; requestId = [string]$script:activeVisualRequestId
            }) -TimeoutSeconds 5 -AllowSemanticFailure | Out-Null
            $terminalStates = @('completed', 'completed_with_warnings', 'failed', 'failed_partial', 'cancelled', 'cancelled_partial', 'stopped')
            $cleanupReceipt = $null
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                $cleanupReceipt = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{
                    contractMajor = 1; clientId = 'csx-render-scale-qualification-cleanup'; commandId = "$($script:runId)-cleanup-get-$attempt"
                    action = 'request_get'; requestId = [string]$script:activeVisualRequestId
                }) -TimeoutSeconds 2 -AllowSemanticFailure
                if ([string](Get-CSXPathValue $cleanupReceipt 'result.state') -in $terminalStates) { break }
                Start-Sleep -Milliseconds 250
            }
            if ([string](Get-CSXPathValue $cleanupReceipt 'result.state') -notin $terminalStates) { throw 'Screenshot cancellation did not reach a terminal state within the cleanup bound.' }
            Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'cleanup\visual-terminal.json') -Value $cleanupReceipt | Out-Null
            $script:activeVisualRequestId = $null
        }
        $status = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'qualification_status'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        $transitionId = Get-CSXPathValue $status 'qualification.transitionId' (Get-CSXPropertyValue $status 'transitionId')
        $transitionOwnerId = [string](Get-CSXPathValue $status 'qualification.ownerId')
        if ($transitionId -and $transitionOwnerId -eq $script:runId -and
            [uint64]$transitionId -in @($script:ownedTransitionIds)) {
            Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{
                action = 'qualification_cancel'; transitionId = [uint64]$transitionId
                ownerId = $script:runId; expectedBuildId = $script:expectedBuildId
            }) -TimeoutSeconds 5 -AllowSemanticFailure | Out-Null
        }
        $trace = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        if ($script:traceMayBeOwned -and [bool](Get-CSXPathValue $trace 'capture.active' $false)) {
            Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'dlss_trace_stop'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure | Out-Null
        }
        $traceRead = if ($script:traceMayBeOwned) {
            Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'dlss_trace_read'; afterSequence = 0; limit = 16; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        }
        else { $null }
        $render = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'status'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        if ($script:ownsCpuCapture -and [bool](Get-CSXPathValue $render 'status.cpuPerformance.active' $false)) {
            Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'cpu_performance_stop'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure | Out-Null
        }
        if ($script:ownsStressCapture -and [bool](Get-CSXPathValue $render 'status.session.active' $false)) {
            Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'stop'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure | Out-Null
        }
        $postQualification = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'qualification_status'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        $postTrace = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        $postRender = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'status'; expectedBuildId = $script:expectedBuildId }) -TimeoutSeconds 5 -AllowSemanticFailure
        $postScreenshot = Invoke-CSXMcpTool -Connection $cleanupConnection -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{
            contractMajor = 1; clientId = 'csx-render-scale-qualification-cleanup'; commandId = "$($script:runId)-cleanup-final-screenshot-status"; action = 'status'
        }) -TimeoutSeconds 5 -AllowSemanticFailure
        foreach ($receipt in @($postQualification, $postTrace, $postRender, $postScreenshot) + $(if ($traceRead) { @($traceRead) } else { @() })) {
            if ($null -ne (Get-CSXPropertyValue $receipt 'error') -or (Get-CSXPropertyValue $receipt 'ok' $true) -eq $false) {
                throw 'Emergency cleanup returned a semantic failure.'
            }
        }
        $ownedQualificationStillActive = [bool](Get-CSXPathValue $postQualification 'qualification.active' $false) -and
            [string](Get-CSXPathValue $postQualification 'qualification.ownerId') -eq $script:runId -and
            [uint64](Get-CSXPathValue $postQualification 'qualification.transitionId' 0) -in @($script:ownedTransitionIds)
        if ($ownedQualificationStillActive -or
            ($script:traceMayBeOwned -and ([bool](Get-CSXPathValue $postTrace 'capture.active' $true) -or [bool](Get-CSXPathValue $traceRead 'capture.summary.active' $true))) -or
            ($script:ownsStressCapture -and [bool](Get-CSXPathValue $postRender 'status.session.active' $true)) -or
            ($script:ownsCpuCapture -and [bool](Get-CSXPathValue $postRender 'status.cpuPerformance.active' $true)) -or
            ($script:visualStartMayBeOwned -and ([int](Get-CSXPathValue $postScreenshot 'result.dispatcher.activeSequences' 1) -ne 0 -or
                [string](Get-CSXPathValue $postScreenshot 'result.dispatcher.activeAcquisitionRequestId') -match '\S'))) {
            throw 'Emergency cleanup postconditions were not idle.'
        }
        $script:ownsStressCapture = $false
        $script:ownsCpuCapture = $false
        $script:traceMayBeOwned = $false
        $script:visualStartMayBeOwned = $false
        $script:ownedTransitionIds.Clear()
        Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'cleanup\postconditions.json') -Value ([pscustomobject][ordered]@{
            qualification = $postQualification; trace = $postTrace; traceRead = $traceRead; renderScale = $postRender; screenshot = $postScreenshot
        }) | Out-Null
        if ($script:connection) { foreach ($row in @($cleanupConnection.transcript)) { $script:connection.transcript.Add($row) } }
    }
    catch { $Warnings.Add("Emergency cleanup could not be proved complete: $($_.Exception.Message)") }
}

function Test-RunnerOwnsRuntimeState {
    return $script:ownsStressCapture -or $script:ownsCpuCapture -or $script:traceMayBeOwned -or
        $script:visualStartMayBeOwned -or $null -ne $script:activeVisualRequestId -or $script:ownedTransitionIds.Count -gt 0
}

function Get-StretchSummary($StressStop) {
    $record = Get-CSXPropertyValue $StressStop 'record'
    if ([string](Get-CSXPropertyValue $record 'schema') -ne 'community-shaders.vr-render-scale.iteration' -or
        [int](Get-CSXPropertyValue $record 'schemaVersion' -1) -ne [int]$script:protocol.thresholds.stressRecordSchemaVersion) {
        throw 'Stress stop did not return the required schema-v13 immutable record.'
    }
    if ([bool](Get-CSXPathValue $record 'session.active' $true)) { throw 'Stress record was still active at stop.' }
    $presentation = Get-CSXPathValue $record 'presentationPath.allowedPresentationStretch'
    if ($null -eq $presentation) { throw 'Stress record omitted allowed presentation-stretch evidence.' }
    $episodes = [uint64](Get-CSXPropertyValue $presentation 'episodes' 0)
    $completed = [uint64](Get-CSXPropertyValue $presentation 'completedEpisodes' 0)
    $timed = [uint64](Get-CSXPropertyValue $presentation 'timedCompletedEpisodes' 0)
    $activeAtStop = [bool](Get-CSXPropertyValue $presentation 'activeAtStop' $true)
    $incompleteStereoAtStop = [bool](Get-CSXPropertyValue $presentation 'incompleteStereoCycleAtStop' $true)
    $incompleteStereoEyeMaskAtStop = [uint64](Get-CSXPropertyValue $presentation 'incompleteStereoCycleEyeMaskAtStop' ([uint64]::MaxValue))
    $timingComplete = [bool](Get-CSXPropertyValue $presentation 'completedTimingComplete' $false)
    $timingStatus = [string](Get-CSXPropertyValue $presentation 'timingStatus')
    if ($activeAtStop) { throw 'Presentation-stretch episode remained active at stress stop.' }
    if ($incompleteStereoAtStop -or $incompleteStereoEyeMaskAtStop -ne 0) { throw 'Presentation-stretch telemetry stopped with an incomplete stereo cycle.' }
    if ($episodes -ne $completed) { throw 'Presentation-stretch episode accounting was incomplete at stress stop.' }
    if ($completed -gt 0 -and (-not $timingComplete -or $timed -ne $completed -or $timingStatus -ne 'complete')) {
        throw 'Presentation-stretch timing was incomplete at stress stop.'
    }
    if ($completed -eq 0 -and $timingStatus -ne 'no_completed_episodes') { throw 'Zero-episode stretch timing status was incoherent.' }
    $frames = [uint64](Get-CSXPropertyValue $presentation 'completedFrames' 0)
    $maxFrames = [uint64](Get-CSXPropertyValue $presentation 'maximumObservedFrames' 0)
    return [pscustomobject][ordered]@{
        completedEpisodes = $completed; totalFrames = $frames
        meanFrames = $(if ($completed -gt 0) { [double](Get-CSXPropertyValue $presentation 'meanCompletedFrames' ([double]$frames / $completed)) } else { 0.0 })
        maxFrames = $maxFrames
        meanMs = $(if ($completed -gt 0) { [double](Get-CSXPropertyValue $presentation 'meanCompletedMilliseconds') } else { 0.0 })
        maxMs = $(if ($completed -gt 0) { [double](Get-CSXPropertyValue $presentation 'maximumCompletedMilliseconds') } else { 0.0 })
        qpcFrequency = [uint64](Get-CSXPropertyValue $presentation 'qpcFrequency' 0)
        activeAtStop = $activeAtStop; incompleteStereoCycleAtStop = $incompleteStereoAtStop; incompleteStereoCycleEyeMaskAtStop = $incompleteStereoEyeMaskAtStop
        timingComplete = $timingComplete; timingStatus = $timingStatus
        recordAccepted = [bool](Get-CSXPathValue $record 'verdict.accepted' $false)
    }
}

function Get-StressTransitionEvidence($StressStop, $Scenario, $WaitRecords, $Matrix = $null, [int]$ExpectedCount = 0, [switch]$RequireExactMenu) {
    $record = Get-CSXPropertyValue $StressStop 'record'
    $requests = @($record.events | Where-Object type -eq 'Request' | Sort-Object sequence)
    $metrics = @($record.metrics | Sort-Object transitionEpoch)
    $requestEpochs = @($requests | ForEach-Object { [uint64]$_.transitionEpoch })
    $metricEpochs = @($metrics | ForEach-Object { [uint64]$_.transitionEpoch })
    $terminalGate = @($record.verdict.gates | Where-Object name -eq 'terminal_state')
    $evidence = [pscustomobject][ordered]@{
        requestEvents = $requests.Count; uniqueRequestEpochs = @($requestEpochs | Sort-Object -Unique).Count
        metrics = $metrics.Count; uniqueMetricEpochs = @($metricEpochs | Sort-Object -Unique).Count
        coalescedDuplicateCount = [uint64](Get-CSXPathValue $record 'session.coalescedDuplicateCount' ([uint64]::MaxValue))
        overwrittenEvents = [uint64](Get-CSXPathValue $record 'session.overwrittenEvents' ([uint64]::MaxValue))
        terminalMetricClear = $terminalGate.Count -eq 1 -and [bool]$terminalGate[0].passed
        exactMenuCrossBindings = @()
    }
    if ($ExpectedCount -gt 0 -and ($requests.Count -ne $ExpectedCount -or $evidence.uniqueRequestEpochs -ne $ExpectedCount -or
        $metrics.Count -ne $ExpectedCount -or $evidence.uniqueMetricEpochs -ne $ExpectedCount)) {
        throw "Stress record did not retain exactly $ExpectedCount unique requests and metrics."
    }
    if ($evidence.coalescedDuplicateCount -ne 0 -or $evidence.overwrittenEvents -ne 0 -or -not $evidence.terminalMetricClear) {
        throw 'Stress record was coalesced, overwritten, or retained a current metric.'
    }
    if (-not $RequireExactMenu) { return $evidence }
    if ($ExpectedCount -ne 25) { throw 'The exact menu stress binding requires 25 transitions.' }
    $bindings = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 25; $index++) {
        $ordinal = $index + 1
        $expected = @($Matrix | Where-Object { [int]$_.ordinal -eq $ordinal }) | Select-Object -First 1
        $apply = Get-ScenarioStepResult $Scenario "menu-$($ordinal.ToString('D2'))-apply"
        $request = $requests[$index]
        $metric = @($metrics | Where-Object { [uint64]$_.transitionEpoch -eq [uint64]$request.transitionEpoch })
        if ($metric.Count -ne 1) { throw "Menu stress record metric binding failed at ordinal $ordinal." }
        $metric = $metric[0]
        $wait = $WaitRecords[$index]
        $waitEpoch = [uint64](Get-CSXPathValue $wait 'raw.renderScaleHealth.stable.transitionEpoch' (Get-CSXPathValue $wait 'raw.observation.physical.stable.transitionEpoch' 0))
        $methodName = ([string]$request.method).TrimStart('k').ToLowerInvariant()
        $metricMethodName = ([string]$metric.method).TrimStart('k').ToLowerInvariant()
        if ([uint64]$request.transitionEpoch -eq 0 -or [uint64]$apply.transitionEpoch -ne [uint64]$request.transitionEpoch -or
            [uint64]$apply.requestID -ne [uint64]$request.requestID -or ($waitEpoch -ne 0 -and $waitEpoch -ne [uint64]$request.transitionEpoch) -or
            $methodName -ne [string]$expected.method -or [bool]$request.active -ne [bool]$expected.renderScaleMode -or [int]$request.qualityMode -ne [int]$expected.qualityModeValue -or
            [uint64]$metric.requestID -ne [uint64]$request.requestID -or $metricMethodName -ne [string]$expected.method -or [int]$metric.qualityMode -ne [int]$expected.qualityModeValue -or
            -not [bool]$metric.completed -or [bool]$metric.superseded -or [uint64]$request.occurrences -ne 1) {
            throw "Menu stress record apply/request/wait/metric cross-binding failed at ordinal $ordinal."
        }
        $bindings.Add([pscustomobject][ordered]@{ ordinal = $ordinal; requestID = [uint64]$request.requestID; transitionEpoch = [uint64]$request.transitionEpoch; method = $methodName; qualityMode = [int]$request.qualityMode; renderScaleMode = [bool]$request.active })
    }
    $evidence.exactMenuCrossBindings = @($bindings)
    return $evidence
}

function Get-DiagnosticFailureLowerBound($WaitRecords) {
    $total = 0L
    foreach ($record in $WaitRecords) {
        $delta = Get-CSXPropertyValue $record.diagnostics 'delta' $record.diagnostics
        $counts = @(foreach ($path in @(
            'stress.failureEvents', 'presentation.vendorFailureStretchEyeObservations', 'presentation.boundsMismatchFallbackEyeObservations',
            'failures.fidelityMismatches', 'failures.transition', 'failures.outOfMemory', 'failures.deviceLost',
            'failures.dlssLifecycle', 'failures.fsrLifecycle', 'failures.memoryTrim', 'failures.retirementFence',
            'dlssTrace.droppedRecords', 'dlssTrace.duplicatedConstantsFailures', 'dlssTrace.evaluateFailures'
        )) { [long](Get-CSXPathValue $delta $path 0) })
        if ($counts.Count -gt 0) { $total += [long](($counts | Measure-Object -Maximum).Maximum) }
    }
    return $total
}

function Get-RenderScaleFailureEventCount($WaitRecords) {
    return [long](($WaitRecords | ForEach-Object {
        $delta = Get-CSXPropertyValue $_.diagnostics 'delta' $_.diagnostics
        [long](Get-CSXPathValue $delta 'stress.failureEvents' 0)
    } | Measure-Object -Sum).Sum)
}

function Get-DiagnosticFailureBreakdown($WaitRecords) {
    $breakdown = [ordered]@{}
    foreach ($path in @(
        'stress.failureEvents', 'presentation.vendorFailureStretchEyeObservations', 'presentation.boundsMismatchFallbackEyeObservations',
        'failures.fidelityMismatches', 'failures.transition', 'failures.outOfMemory', 'failures.deviceLost',
        'failures.dlssLifecycle', 'failures.fsrLifecycle', 'failures.memoryTrim', 'failures.retirementFence',
        'dlssTrace.droppedRecords', 'dlssTrace.duplicatedConstantsFailures', 'dlssTrace.evaluateFailures'
    )) {
        $breakdown[$path] = [long](($WaitRecords | ForEach-Object {
            $delta = Get-CSXPropertyValue $_.diagnostics 'delta' $_.diagnostics
            [long](Get-CSXPathValue $delta $path 0)
        } | Measure-Object -Sum).Sum)
    }
    return [pscustomobject]$breakdown
}

function Get-FailedTransitionCount($WaitRecords, [int]$ExpectedCount) {
    $observedFailures = @($WaitRecords | Where-Object {
        -not [bool]$_.satisfied -or $null -eq $_.elapsedMs -or (Get-DiagnosticFailureLowerBound @($_)) -gt 0
    }).Count
    return $observedFailures + [Math]::Max(0, $ExpectedCount - @($WaitRecords).Count)
}

function Assert-WaitRecords($Records, [int]$ExpectedCount, [string]$Assay, $ExpectedMatrix = $null) {
    if ($Records.Count -ne $ExpectedCount) { throw "$Assay returned $($Records.Count) qualification waits; expected $ExpectedCount." }
    if (@($Records | Where-Object { -not $_.satisfied -or $null -eq $_.elapsedMs }).Count -ne 0) { throw "$Assay contains an unsatisfied or untimed transition." }
    if (@($Records.transitionId | Sort-Object -Unique).Count -ne $ExpectedCount) { throw "$Assay transition identities are not unique." }
    $expectedFoveation = Get-CSXFoveationTarget $script:protocol
    for ($index = 0; $index -lt $ExpectedCount; $index++) {
        $record = $Records[$index]
        $ordinal = $index + 1
        $isCoc = $Assay -like 'COC*'
        $expectedId = if ($isCoc) { [uint64]$ordinal } else { [uint64](100 + $ordinal) }
        if ([int]$record.ordinal -ne $ordinal -or [uint64]$record.transitionId -ne $expectedId) { throw "$Assay label/ordinal/transitionId mapping failed at ordinal $ordinal." }
        $expectedCell = if ($isCoc -and $ordinal % 2 -eq 1) { [string]$script:protocol.fixture.interiorCellEditorId } else { [string]$script:protocol.fixture.startCellEditorId }
        if (-not [string]::Equals([string](Get-CSXPathValue $record 'raw.currentCell.editorId'), $expectedCell, [StringComparison]::OrdinalIgnoreCase)) { throw "$Assay transition $ordinal observed the wrong exact cell." }
        $profileSource = if ($isCoc) {
            if ($ordinal % 2 -eq 1) { if ($script:gpuVendor -eq 'NVIDIA') { $script:protocol.fixture.profiles.nvidiaInterior } else { $script:protocol.fixture.profiles.amdInterior } } else { $script:protocol.fixture.profiles.sharedExterior }
        }
        else { @($ExpectedMatrix | Where-Object { [int]$_.ordinal -eq $ordinal }) | Select-Object -First 1 }
        $expectedTarget = Add-CSXExactRuntimeToProfile -Profile $profileSource -FsrRuntime $script:fsrRuntime
        if (($record.target | ConvertTo-Json -Depth 10 -Compress) -ne ($expectedTarget | ConvertTo-Json -Depth 10 -Compress)) { throw "$Assay transition $ordinal target receipt differs from the canonical matrix." }
        if (-not (Test-CSXFoveationEvidence -Evidence $record.foveation -Expected $expectedFoveation -Target $record.target)) { throw "$Assay transition $($record.ordinal) did not prove the exact foveation fixture." }
    }
}

function Assert-MenuPolicies($Scenario, $Records) {
    foreach ($record in $Records) {
        $label = "menu-$($record.ordinal.ToString('D2'))-apply"
        $step = @($Scenario.results | Where-Object label -eq $label) | Select-Object -First 1
        $apply = Get-CSXPropertyValue $step 'result'
        if ($null -eq $apply -or -not [bool](Get-CSXPropertyValue $apply 'accepted' $false)) { throw "Menu transition $($record.ordinal) was not accepted." }
        if ([string](Get-CSXPropertyValue $apply 'disposition') -in @('rejected', 'no_change', 'coalesced')) { throw "Menu transition $($record.ordinal) used forbidden disposition '$($apply.disposition)'." }
        $delta = Get-CSXPropertyValue $record.diagnostics 'delta' $record.diagnostics
        $retries = [uint64](Get-CSXPathValue $delta 'stress.retryEvents' 0)
        if ($retries -gt [uint64]$script:protocol.thresholds.menuMaximumRetriesPerTransition) { throw "Menu transition $($record.ordinal) exceeded the retry threshold." }
        $frames = [uint64](Get-CSXPathValue $record.raw 'timing.elapsedFrames' 0)
        $pressure = [bool](Get-CSXPathValue $record.raw 'observed.pressureProtected' $false)
        $frameLimit = if ($pressure) { [uint64]$script:protocol.thresholds.menuMaximumPressureProtectedStableFrames } else { [uint64]$script:protocol.thresholds.menuMaximumOrdinaryStableFrames }
        if ($frames -eq 0 -or $frames -gt $frameLimit) { throw "Menu transition $($record.ordinal) stabilization frame count is invalid or over threshold." }
    }
}

function Get-ScenarioStepResult($Scenario, [string]$StepLabel) {
    $steps = @($Scenario.results | Where-Object label -eq $StepLabel)
    if ($steps.Count -ne 1) { throw "Scenario did not return exactly one '$StepLabel' step." }
    $result = Get-CSXPropertyValue $steps[0] 'result'
    if ($null -eq $result) { throw "Scenario step '$StepLabel' omitted its result." }
    return $result
}

function Assert-RecoveryScenario($Scenario, [string]$Label, [string]$FsrRuntime, [double]$ElapsedMs = 0, [switch]$NoRecoveryBarrier) {
    if (-not [bool]$Scenario.ok -or [bool]$Scenario.aborted) { throw "$Label recovery scenario failed." }
    $wait = $null
    if (-not $NoRecoveryBarrier) {
        $wait = @($Scenario.results | Where-Object label -eq "$Label-recovery-30000ms") | Select-Object -First 1
        if ($null -eq $wait -or [long](Get-CSXPropertyValue $wait 'ms' -1) -ne 30000) { throw "$Label recovery did not preserve the exact 30,000 ms server barrier." }
        if ($ElapsedMs -lt [int]$script:protocol.timeBudget.recoveryMinimumElapsedMs -or $ElapsedMs -gt [int]$script:protocol.timeBudget.recoveryMaximumElapsedMs) {
            throw "$Label recovery wall clock was $ElapsedMs ms, outside the versioned 30-second barrier tolerance."
        }
    }
    $scene = Get-ScenarioStepResult $Scenario "$Label-recovery-scene"
    $health = Get-ScenarioStepResult $Scenario "$Label-recovery-health"
    $qualification = Get-ScenarioStepResult $Scenario "$Label-recovery-qualification-status"
    $trace = Get-ScenarioStepResult $Scenario "$Label-recovery-dlss-trace-status"
    $render = Get-ScenarioStepResult $Scenario "$Label-recovery-renderscale-status"
    $upscaling = Get-ScenarioStepResult $Scenario "$Label-recovery-upscaling-snapshot"
    $settings = Get-ScenarioStepResult $Scenario "$Label-recovery-feature-settings"
    $screenshot = Get-ScenarioStepResult $Scenario "$Label-recovery-screenshot-status"
    $cell = Get-SceneCellEditorId $scene
    if (-not [string]::Equals($cell, [string]$script:protocol.fixture.startCellEditorId, [StringComparison]::OrdinalIgnoreCase)) { throw "$Label recovery observed wrong cell '$cell'." }
    $bindingIdentity = Assert-AuthoritativeRuntimeBinding -BindingIdentity $script:bindingIdentity -Health $health
    $gpuIdentity = Get-CSXLiveGpuFixtureEvidence -Adapter (Get-CSXPathValue $render 'status.adapter') -Manifest $script:fixtureManifest -GpuVendor $script:gpuVendor
    if ([bool](Get-CSXPathValue $qualification 'qualification.active' $true)) { throw "$Label recovery found a qualification owner." }
    if ([bool](Get-CSXPathValue $trace 'capture.active' $true)) { throw "$Label recovery found an active DLSS trace." }
    if ([bool](Get-CSXPathValue $render 'status.session.active' $false) -or [bool](Get-CSXPathValue $render 'status.cpuPerformance.active' $false)) { throw "$Label recovery found an active diagnostic session." }
    $controller = Get-CSXPathValue $render 'status.controller'
    if ([string](Get-CSXPropertyValue $controller 'state') -ne 'Active' -or [string](Get-CSXPropertyValue $controller 'physicalPhase') -ne 'ContractPublished' -or
        [string](Get-CSXPropertyValue $controller 'presentationPhase') -notin @('StereoProven', 'Released') -or
        [bool](Get-CSXPathValue $controller 'currentMetrics.valid' $true)) { throw "$Label recovery controller was not settled on the exterior contract." }
    if ([bool](Get-CSXPathValue $controller 'memoryTrim.pending' $true) -or [uint64](Get-CSXPathValue $controller 'retirement.pendingSets' 1) -ne 0 -or
        [bool](Get-CSXPathValue $controller 'retirement.fencePending' $true) -or [bool](Get-CSXPathValue $controller 'retirement.capacityBlocked' $true) -or
        [uint64](Get-CSXPathValue $controller 'retirement.nextCleanupFrame' 1) -ne 0 -or [bool](Get-CSXPathValue $controller 'engineTargetRetirement.pending' $true) -or
        [bool](Get-CSXPathValue $controller 'engineTargetRetirement.fencePending' $true) -or [bool](Get-CSXPathValue $controller 'engineTargetRetirement.capacityBlocked' $true)) {
        throw "$Label recovery found trim or retirement work outstanding."
    }
    $gate = Get-CSXPathValue $render 'status.vendorWorkGate'
    if ([bool](Get-CSXPropertyValue $gate 'active' $true) -or [uint64](Get-CSXPropertyValue $gate 'activeMask' 1) -ne 0 -or
        [uint64](Get-CSXPropertyValue $gate 'effectiveLifecycleMask' 1) -ne 0 -or [bool](Get-CSXPropertyValue $gate 'recoveryPending' $true) -or
        [bool](Get-CSXPropertyValue $gate 'relatchPending' $true) -or [bool](Get-CSXPropertyValue $gate 'profileTransitionPending' $true)) {
        throw "$Label recovery vendor work gate was not idle."
    }
    $fsrLifecycle = Get-CSXPropertyValue $controller 'fsrLifecycle'
    $dlssLifecycle = Get-CSXPropertyValue $controller 'dlssLifecycle'
    if ([string]$fsrLifecycle.phase -ne 'Ready' -or -not [bool]$fsrLifecycle.resourcesPresent -or -not [bool]$fsrLifecycle.readyForContract -or [uint64]$fsrLifecycle.failures -ne 0 -or
        [string]$dlssLifecycle.phase -ne 'Inactive' -or [bool]$dlssLifecycle.resourcesPresent -or [uint64]$dlssLifecycle.failures -ne 0) {
        throw "$Label recovery vendor lifecycles were not quiescent and exact."
    }
    $fidelityEyes = @(Get-CSXPathValue $controller 'fidelity.eyes')
    $presentationEyes = @(Get-CSXPathValue $controller 'presentation.eyes')
    if (-not [bool](Get-CSXPathValue $controller 'fidelity.bothEyesValid' $false) -or [uint64](Get-CSXPathValue $controller 'fidelity.evaluationEyeMask' 0) -ne 3 -or
        $fidelityEyes.Count -ne 2 -or @($fidelityEyes | Where-Object { -not [bool]$_.valid -or -not [bool]$_.evaluated }).Count -ne 0 -or
        [uint64]$fidelityEyes[0].frame -ne [uint64]$fidelityEyes[1].frame -or $presentationEyes.Count -ne 2 -or
        @($presentationEyes | Where-Object { -not [bool]$_.valid -or [string]$_.path -ne 'VendorEvaluated' -or [string]$_.method -ne 'fsr' }).Count -ne 0 -or
        [uint64]$presentationEyes[0].frame -ne [uint64]$presentationEyes[1].frame -or
        [uint64]$presentationEyes[0].transitionEpoch -ne [uint64]$presentationEyes[1].transitionEpoch -or
        [uint64]$presentationEyes[0].contractGeneration -ne [uint64]$presentationEyes[1].contractGeneration -or
        [uint64](Get-CSXPathValue $controller 'presentation.consecutiveBothEyesVendorFrames' 0) -lt 2) {
        throw "$Label recovery did not prove a coherent two-eye vendor presentation."
    }
    $fsrDispatch = Get-CSXPathValue $render 'status.fsrDispatch'
    if (-not [bool]$fsrDispatch.fsrBackendConverged -or -not [bool]$fsrDispatch.actualDispatchBothEyesValid -or
        -not [bool]$fsrDispatch.actualDispatchBackendConverged -or [bool]$fsrDispatch.actualRuntimeFallbackObserved -or
        -not [bool]$fsrDispatch.contractReady -or [bool]$fsrDispatch.shaderCompilationActive) { throw "$Label recovery FSR dispatch was not coherent and fallback-free." }
    if ([int](Get-CSXPathValue $screenshot 'result.dispatcher.pendingOperations' 1) -ne 0 -or
        [int](Get-CSXPathValue $screenshot 'result.dispatcher.activeSequences' 1) -ne 0 -or
        [string](Get-CSXPathValue $screenshot 'result.dispatcher.activeAcquisitionRequestId') -match '\S' -or
        [int](Get-CSXPathValue $screenshot 'result.worker.outstandingArtifacts' 1) -ne 0) { throw "$Label recovery found screenshot work still active." }
    Assert-FoveationSettings $settings
    [void](Assert-ExteriorSnapshot -SnapshotResult $upscaling -ExpectedFsrRuntime $FsrRuntime)
    return [pscustomobject][ordered]@{ wait = $wait; scene = $scene; health = $health; bindingIdentity = $bindingIdentity; gpuIdentity = $gpuIdentity; qualification = $qualification; trace = $trace; renderScale = $render; upscaling = $upscaling; settings = $settings; screenshot = $screenshot }
}

function Wait-VisualSequence($StartResponse, [int]$Replicate) {
    $requestId = [string](Get-CSXPathValue $StartResponse 'result.requestId')
    if ([string]::IsNullOrWhiteSpace($requestId)) { throw "Visual replicate $Replicate did not return a requestId." }
    $script:activeVisualRequestId = $requestId
    $terminal = @('completed', 'completed_with_warnings', 'failed', 'failed_partial', 'cancelled', 'cancelled_partial', 'stopped')
    do {
        $remaining = Get-CSXRemainingMilliseconds -Stopwatch $script:orchestrationWatch -BudgetMs ([int]$script:protocol.timeBudget.orchestrationMs)
        if ($remaining -le 0) { throw 'The orchestration deadline expired while a screenshot sequence was active.' }
        if ($script:visualWatch.Elapsed.TotalMilliseconds -ge [int]$script:protocol.timeBudget.visualAssayMs) { throw 'The visual assay exceeded its 195 second allocation.' }
        $receipt = Invoke-BoundTool -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{
            contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$($script:runId)-visual-$($Replicate.ToString('D2'))-poll-$([guid]::NewGuid().ToString('N'))"
            action = 'request_get'; requestId = $requestId
        })
        $state = [string](Get-CSXPathValue $receipt 'result.state')
        if ($state -in $terminal) { break }
        Start-Sleep -Milliseconds ([Math]::Min([int]$script:protocol.timeBudget.screenshotPollMs, $remaining))
    } while ($true)
    $script:activeVisualRequestId = $null
    $script:visualStartMayBeOwned = $false
    if ($state -ne 'completed') { throw "Visual replicate $Replicate ended in '$state', not completed." }
    $effective = Get-CSXPathValue $receipt 'result.effective'
    if ([int](Get-CSXPropertyValue $effective 'frameCount' 0) -ne 16 -or
        [string](Get-CSXPathValue $effective 'schedule.basis') -ne 'wall_clock' -or
        [int](Get-CSXPathValue $effective 'schedule.intervalMs' 0) -ne 4000 -or
        [int](Get-CSXPathValue $effective 'schedule.startDelayMs' -1) -ne 0 -or
        [string](Get-CSXPathValue $effective 'schedule.pausePolicy') -ne 'hold') {
        throw "Visual replicate $Replicate did not preserve the exact one-minute wall-clock schedule."
    }
    $acceptedUtc = [DateTimeOffset]::MinValue
    $terminalUtc = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string](Get-CSXPathValue $receipt 'result.acceptedUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedUtc) -or
        -not [DateTimeOffset]::TryParse([string](Get-CSXPathValue $receipt 'result.terminalUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$terminalUtc)) {
        throw "Visual replicate $Replicate omitted valid acceptance/terminal timestamps."
    }
    $elapsedMs = ($terminalUtc - $acceptedUtc).TotalMilliseconds
    if ($elapsedMs -lt [int]$script:protocol.thresholds.visualMinimumElapsedMsPerReplicate -or
        $elapsedMs -gt [int]$script:protocol.thresholds.visualMaximumElapsedMsPerReplicate) {
        throw "Visual replicate $Replicate elapsed $elapsedMs ms instead of the required one-minute span."
    }
    $counts = Get-CSXPathValue $receipt 'result.counts'
    $thresholds = $script:protocol.thresholds
    if ([int]$counts.requested -ne [int]$thresholds.visualRequestedFramesPerReplicate -or
        [int]$counts.scheduled -ne [int]$thresholds.visualRequestedFramesPerReplicate -or
        [int]$counts.acquired -ne [int]$thresholds.visualWrittenFramesPerReplicate -or
        [int]$counts.written -ne [int]$thresholds.visualWrittenFramesPerReplicate -or
        [int]$counts.dropped -ne [int]$thresholds.visualDroppedFramesPerReplicate -or
        [int]$counts.failed -ne [int]$thresholds.visualFailedFramesPerReplicate -or [int]$counts.inFlight -ne 0) {
        throw "Visual replicate $Replicate did not meet the exact 16 written / zero drop/failure gate."
    }
    $manifestPath = [string](Get-CSXPathValue $receipt 'result.manifest.finalPath')
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Visual replicate $Replicate has no final manifest." }
    $manifestPath = [IO.Path]::GetFullPath($manifestPath)
    $rootPrefix = $script:evidenceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $manifestPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Visual replicate $Replicate manifest escaped the evidence directory." }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 100
    if ([string]$manifest.state -ne 'final' -or [string]$manifest.requestId -ne $requestId) { throw "Visual replicate $Replicate manifest identity is invalid." }
    if ([string](Get-CSXPathValue $manifest 'capture.source.kind') -ne 'hmd_submission' -or [string](Get-CSXPathValue $manifest 'capture.source.fallback') -ne 'reject' -or
        [string](Get-CSXPathValue $manifest 'capture.destination.overwrite') -ne 'never') { throw "Visual replicate $Replicate manifest changed the source/fallback/overwrite contract." }
    $manifestHash = Get-CSXFileSha256 $manifestPath
    $manifestArtifact = @((Get-CSXPathValue $receipt 'result.artifacts') | Where-Object { [IO.Path]::GetFullPath([string]$_.path) -eq $manifestPath }) | Select-Object -First 1
    if ($null -eq $manifestArtifact -or -not [bool]$manifestArtifact.committed -or [string]$manifestArtifact.sha256 -ne $manifestHash) {
        throw "Visual replicate $Replicate manifest receipt/file SHA-256 binding failed."
    }
    return [pscustomobject][ordered]@{ replicate = $Replicate; requestId = $requestId; elapsedMs = $elapsedMs; receipt = $receipt; manifestPath = $manifestPath; manifestSha256 = $manifestHash; manifest = $manifest }
}

function Get-PngDimensions([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $header = [byte[]]::new(24)
        if ($stream.Read($header, 0, 24) -ne 24 -or ($header[0..7] -join ',') -ne '137,80,78,71,13,10,26,10') { throw "Artifact is not a complete PNG: $Path" }
        $width = [uint32](([uint32]$header[16] -shl 24) -bor ([uint32]$header[17] -shl 16) -bor ([uint32]$header[18] -shl 8) -bor $header[19])
        $height = [uint32](([uint32]$header[20] -shl 24) -bor ([uint32]$header[21] -shl 16) -bor ([uint32]$header[22] -shl 8) -bor $header[23])
        if ($width -eq 0 -or $height -eq 0) { throw "PNG has zero dimensions: $Path" }
        return [pscustomobject][ordered]@{ width = $width; height = $height }
    }
    finally { $stream.Dispose() }
}

function Test-VisualChildReceipt($ChildReceipt, $Run, [int]$Ordinal) {
    $result = Get-CSXPropertyValue $ChildReceipt 'result'
    if ([string]$result.state -ne 'completed' -or [string]$result.parentRequestId -ne [string]$Run.requestId -or [int]$result.sequenceOrdinal -ne $Ordinal) {
        throw "Visual rep $($Run.replicate), ordinal $Ordinal child identity/state is invalid."
    }
    $acceptedUtc = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string](Get-CSXPropertyValue $result 'acceptedUtc'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$acceptedUtc)) {
        throw "Visual rep $($Run.replicate), ordinal $Ordinal omitted a valid acceptedUtc timestamp."
    }
    if ([string](Get-CSXPathValue $result 'effective.source.kind') -ne 'hmd_submission' -or [string](Get-CSXPathValue $result 'effective.source.fallback') -ne 'reject' -or
        [string](Get-CSXPathValue $result 'effective.destination.overwrite') -ne 'never') { throw "Visual rep $($Run.replicate), ordinal $Ordinal used a source fallback or overwrite contract." }
    if (@($result.warnings).Count -ne 0 -or $null -ne (Get-CSXPropertyValue $result 'error')) { throw "Visual rep $($Run.replicate), ordinal $Ordinal returned warnings or an error." }
    if ([int](Get-CSXPathValue $result 'artifactProgress.expected' -1) -ne 3 -or [int](Get-CSXPathValue $result 'artifactProgress.terminal' -1) -ne 3 -or
        [int](Get-CSXPathValue $result 'artifactProgress.successful' -1) -ne 3) { throw "Visual rep $($Run.replicate), ordinal $Ordinal did not commit exactly three artifacts." }
    $outputs = @(Get-CSXPathValue $result 'effective.outputs')
    $views = @($outputs | ForEach-Object { [string]$_.view })
    if ($outputs.Count -ne 3 -or (@($views | Sort-Object) -join ',') -ne 'left_eye,right_eye,side_by_side') { throw "Visual rep $($Run.replicate), ordinal $Ordinal changed the exact view set." }
    foreach ($output in $outputs) {
        if ([string](Get-CSXPathValue $output 'encoding.format') -ne 'png' -or [string](Get-CSXPathValue $output 'encoding.colourContract') -ne 'sdr_srgb') {
            throw "Visual rep $($Run.replicate), ordinal $Ordinal changed its PNG/sdr_srgb encoding."
        }
    }
    $artifacts = [Collections.Generic.List[object]]::new()
    foreach ($output in $outputs) {
        $suffix = [string]$output.nameSuffix
        $matches = @($result.artifacts | Where-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_.path).EndsWith("_$suffix", [StringComparison]::Ordinal) })
        if ($matches.Count -ne 1) { throw "Visual rep $($Run.replicate), ordinal $Ordinal did not bind one artifact to view '$($output.view)'." }
        $artifact = $matches[0]
        $path = [IO.Path]::GetFullPath([string]$artifact.path)
        $rootPrefix = $script:evidenceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Screenshot artifact escaped the evidence directory: $path" }
        if (-not [bool]$artifact.committed -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Screenshot artifact is not committed: $path" }
        $hash = Get-CSXFileSha256 $path
        if ([string]$artifact.sha256 -ne $hash) { throw "Screenshot receipt hash differs for $path" }
        $dimensions = Get-PngDimensions $path
        $artifacts.Add([pscustomobject][ordered]@{
            view = [string]$output.view; path = [IO.Path]::GetRelativePath($script:evidenceRoot, $path)
            sha256 = $hash; width = $dimensions.width; height = $dimensions.height
        })
    }
    $left = @($artifacts | Where-Object view -eq 'left_eye')[0]
    $right = @($artifacts | Where-Object view -eq 'right_eye')[0]
    $stereo = @($artifacts | Where-Object view -eq 'side_by_side')[0]
    if ($left.width -ne $right.width -or $left.height -ne $right.height -or $stereo.width -ne 2 * $left.width -or $stereo.height -ne $left.height) {
        throw "Visual rep $($Run.replicate), ordinal $Ordinal did not preserve equal eye planes and side-by-side geometry."
    }
    $manifestChild = @($Run.manifest.children | Where-Object { [int]$_.ordinal -eq $Ordinal })
    if ($manifestChild.Count -ne 1 -or [string]$manifestChild[0].requestId -ne [string]$result.requestId -or [string]$manifestChild[0].state -ne 'completed') {
        throw "Visual rep $($Run.replicate), ordinal $Ordinal manifest child binding is invalid."
    }
    if ($null -ne $manifestChild[0].artifact) {
        $manifestArtifactHash = [string]$manifestChild[0].artifact.sha256
        if (@($artifacts | Where-Object sha256 -eq $manifestArtifactHash).Count -ne 1) { throw "Visual rep $($Run.replicate), ordinal $Ordinal manifest artifact hash is not bound to its receipt." }
    }
    return [pscustomobject][ordered]@{ ordinal = $Ordinal; requestId = [string]$result.requestId; acceptedUtc = $acceptedUtc; receipt = $ChildReceipt; artifacts = @($artifacts | Sort-Object view) }
}

function Get-VisualIndexSamples($VisualRuns) {
    $samples = [Collections.Generic.List[object]]::new()
    $children = [Collections.Generic.List[object]]::new()
    foreach ($run in $VisualRuns) {
        if (@($run.manifest.children).Count -ne 16 -or @($run.manifest.children.ordinal | Sort-Object -Unique).Count -ne 16) { throw "Visual rep $($run.replicate) manifest does not contain 16 unique children." }
        foreach ($ordinal in 1..16) {
            $child = @($run.manifest.children | Where-Object { [int]$_.ordinal -eq [int]$ordinal }) | Select-Object -First 1
            if ($null -eq $child) { throw "Visual rep $($run.replicate) manifest omitted ordinal $ordinal." }
            $childReceipt = Invoke-BoundTool -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{
                contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$($script:runId)-visual-$($run.replicate)-child-$ordinal"
                action = 'request_get'; requestId = [string]$child.requestId
            })
            $validated = Test-VisualChildReceipt -ChildReceipt $childReceipt -Run $run -Ordinal $ordinal
            $children.Add([pscustomobject][ordered]@{ replicate = [int]$run.replicate; ordinal = $ordinal; requestId = $validated.requestId; acceptedUtc = $validated.acceptedUtc.ToString('o'); receipt = $validated.receipt; artifacts = $validated.artifacts })
            if ($ordinal -in @($script:protocol.visualAssay.reviewOrdinals)) {
                $samples.Add([pscustomobject][ordered]@{ replicate = [int]$run.replicate; ordinal = [int]$ordinal; artifacts = $validated.artifacts })
            }
        }
        $replicateChildren = @($children | Where-Object replicate -eq [int]$run.replicate | Sort-Object ordinal)
        $childSpanMs = ($replicateChildren[-1].acceptedUtc -as [DateTimeOffset]) - ($replicateChildren[0].acceptedUtc -as [DateTimeOffset])
        $childSpanMs = $childSpanMs.TotalMilliseconds
        if ($childSpanMs -lt [int]$script:protocol.thresholds.visualMinimumElapsedMsPerReplicate -or
            $childSpanMs -gt [int]$script:protocol.thresholds.visualMaximumElapsedMsPerReplicate) {
            throw "Visual rep $($run.replicate) child acceptance span was $childSpanMs ms, not one minute."
        }
    }
    return [pscustomobject][ordered]@{ samples = @($samples); children = @($children) }
}

function Get-VisualFixtureObservation([string]$Label, [string]$FsrRuntime) {
    $scenarioRequest = New-CSXRecoveryScenario -Protocol $script:protocol -ExpectedBuildId $script:expectedBuildId -RunId $script:runId -FsrRuntime $FsrRuntime -RecoveryLabel $Label
    $scenarioRequest.steps = @($scenarioRequest.steps | Where-Object { -not $_.Contains('wait') })
    $scenario = Invoke-BoundTool -Tool 'scenario' -Arguments $scenarioRequest -OperationCapMs 10000
    $evidence = Assert-RecoveryScenario -Scenario $scenario -Label $Label -FsrRuntime $FsrRuntime -NoRecoveryBarrier
    return [pscustomobject][ordered]@{ label = $Label; request = $scenarioRequest; result = $scenario; evidence = $evidence }
}

function Resolve-BaselineRun([string]$Path, [string]$ExpectedBuildId, [string]$CandidateBuildId) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'PR mode requires -BaselinePath.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedBuildId)) { throw 'PR mode requires -ExpectedBaselineBuildId.' }
    $resolved = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved = Join-Path $resolved 'run.json' }
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Baseline run does not exist: $resolved" }
    $run = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 100
    if ([string]$run.schema -ne 'csx-render-scale-pr-v1' -or [string]$run.status -ne 'PASS') { throw 'PR baseline must be a passing csx-render-scale-pr-v1 run.' }
    $actualBuildId = ([string](Get-CSXPathValue $run 'runtime.buildId')).ToLowerInvariant()
    if ($actualBuildId -notmatch '^[a-f0-9]{64}$' -or $actualBuildId -ne $ExpectedBuildId.ToLowerInvariant()) {
        throw 'PR baseline Build ID does not match -ExpectedBaselineBuildId.'
    }
    if ($actualBuildId -eq $CandidateBuildId.ToLowerInvariant()) { throw 'Candidate and baseline Build IDs must differ.' }
    $root = Split-Path -Parent $resolved
    $indexRelative = [string](Get-CSXPathValue $run 'assays.visual.indexPath')
    if ([string]::IsNullOrWhiteSpace($indexRelative)) { throw 'Baseline run omits its relative visual index path.' }
    $indexPath = Resolve-CSXEvidencePath -EvidenceRoot $root -RelativePath $indexRelative
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { throw 'Baseline visual index is missing.' }
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 100
    Assert-CSXVisualIndexSet -VisualIndex $index -Label 'Baseline' -ExpectedRunId ([string]$run.runId)
    $indexSha256 = Get-CSXFileSha256 $indexPath
    if ($indexSha256 -ne [string](Get-CSXPathValue $run 'assays.visual.indexSha256')) { throw 'Baseline run does not pin the matching visual-index SHA-256.' }
    foreach ($sample in @($index.samples)) {
        foreach ($artifact in @($sample.artifacts)) {
            $artifactPath = Resolve-CSXEvidencePath -EvidenceRoot $root -RelativePath ([string]$artifact.path)
            if ((Get-CSXFileSha256 $artifactPath) -ne [string]$artifact.sha256) { throw "Baseline artifact hash mismatch: $($artifact.path)" }
        }
    }
    return [pscustomobject][ordered]@{ path = $resolved; sha256 = Get-CSXFileSha256 $resolved; run = $run; root = $root; visualIndexPath = $indexPath; visualIndexSha256 = $indexSha256; visualIndex = $index }
}

function Copy-BaselineBundle($Baseline) {
    $destinationRoot = Join-Path $script:evidenceRoot 'baseline'
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    $runDestination = Join-Path $destinationRoot 'run.json'
    $indexDestination = Join-Path $destinationRoot 'visual-index.json'
    Copy-Item -LiteralPath $Baseline.path -Destination $runDestination
    Copy-Item -LiteralPath $Baseline.visualIndexPath -Destination $indexDestination
    if ((Get-CSXFileSha256 $runDestination) -ne $Baseline.sha256) { throw 'Copied baseline run hash changed.' }
    if ((Get-CSXFileSha256 $indexDestination) -ne $Baseline.visualIndexSha256) { throw 'Copied baseline visual-index hash changed.' }
    foreach ($sample in @($Baseline.visualIndex.samples)) {
        foreach ($artifact in @($sample.artifacts)) {
            $source = Resolve-CSXEvidencePath -EvidenceRoot $Baseline.root -RelativePath ([string]$artifact.path)
            $destination = Resolve-CSXEvidencePath -EvidenceRoot $destinationRoot -RelativePath ([string]$artifact.path)
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if (Test-Path -LiteralPath $destination) { throw "Baseline bundle path collision: $($artifact.path)" }
            Copy-Item -LiteralPath $source -Destination $destination
            if ((Get-CSXFileSha256 $destination) -ne [string]$artifact.sha256) { throw "Copied baseline artifact hash changed: $($artifact.path)" }
        }
    }
    return [pscustomobject][ordered]@{ path = 'baseline/run.json'; visualIndexPath = 'baseline/visual-index.json'; visualIndexSha256 = $Baseline.visualIndexSha256; runSha256 = $Baseline.sha256 }
}

function Convert-ToTransitionRows($Records, $Matrix, [string]$Assay) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($record in @($Records)) {
        $entry = if ($null -ne $Matrix) { @($Matrix | Where-Object { [int]$_.ordinal -eq [int]$record.ordinal }) | Select-Object -First 1 } else { $null }
        $target = Get-CSXPropertyValue $record 'target'
        $method = if ($entry) { [string]$entry.method } else { [string](Get-CSXPropertyValue $target 'method') }
        $qualityMode = if ($entry) { [int]$entry.qualityModeValue } else { [int](Get-CSXPropertyValue $target 'qualityMode' -1) }
        $renderScale = if ($entry) { [bool]$entry.renderScaleMode } else { [bool](Get-CSXPropertyValue $target 'renderScaleMode') }
        $rows.Add([pscustomobject][ordered]@{
            assay = $Assay; ordinal = [int]$record.ordinal; transitionId = [uint64]$record.transitionId
            method = $method; qualityMode = $qualityMode; renderScaleMode = $renderScale
            elapsedMs = $(if ($null -eq $record.elapsedMs) { $null } else { [double]$record.elapsedMs })
            elapsedFrames = [uint64](Get-CSXPathValue $record 'raw.timing.elapsedFrames' 0)
            satisfied = [bool]$record.satisfied
        })
    }
    return @($rows)
}

function Write-TransitionEvidence($CocRows, $MenuRows) {
    $all = @($CocRows) + @($MenuRows)
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'transitions.json') -Value ([pscustomobject][ordered]@{ schema = 'csx-render-scale-transitions-v1'; rows = $all }) | Out-Null
    $csv = (($all | Select-Object assay, ordinal, transitionId, method, qualityMode, renderScaleMode, elapsedMs, elapsedFrames, satisfied | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine) + [Environment]::NewLine
    Write-CSXTextFile -Path (Join-Path $script:evidenceRoot 'transitions.csv') -Value $csv | Out-Null
    foreach ($entry in @(
        [pscustomobject]@{ name = 'coc'; rows = @($CocRows) },
        [pscustomobject]@{ name = 'menu'; rows = @($MenuRows) }
    )) {
        Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot "$($entry.name)\transitions.json") -Value ([pscustomobject][ordered]@{
            schema = 'csx-render-scale-transitions-v1'
            assay = $entry.name
            rows = $entry.rows
        }) | Out-Null
        $assayCsv = (($entry.rows | Select-Object assay, ordinal, transitionId, method, qualityMode, renderScaleMode, elapsedMs, elapsedFrames, satisfied | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine) + [Environment]::NewLine
        Write-CSXTextFile -Path (Join-Path $script:evidenceRoot "$($entry.name)\transitions.csv") -Value $assayCsv | Out-Null
    }
}

function Get-MenuStrata($Rows) {
    $byMethod = [ordered]@{}
    foreach ($method in @($Rows.method | Sort-Object -Unique)) {
        $byMethod[$method] = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object method -eq $method | ForEach-Object elapsedMs)) -IncludeRate
    }
    $byRenderScale = [ordered]@{
        off = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object { -not $_.renderScaleMode } | ForEach-Object elapsedMs)) -IncludeRate
        on = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object renderScaleMode | ForEach-Object elapsedMs)) -IncludeRate
    }
    $combined = [ordered]@{}
    foreach ($method in @($Rows.method | Sort-Object -Unique)) {
        foreach ($state in @($false, $true)) {
            $key = "$method-render-scale-$(if ($state) { 'on' } else { 'off' })"
            $combined[$key] = Get-CSXMetricSummary -Values ([double[]]@($Rows | Where-Object { $_.method -eq $method -and $_.renderScaleMode -eq $state } | ForEach-Object elapsedMs)) -IncludeRate
        }
    }
    return [pscustomobject][ordered]@{ byMethod = [pscustomobject]$byMethod; byRenderScaleState = [pscustomobject]$byRenderScale; combined = [pscustomobject]$combined }
}

if ($FinalizeReview) {
    try {
        $updated = Update-CSXQualificationReport -EvidenceDirectory $EvidenceDirectory
        $result = [pscustomobject][ordered]@{ ok = $updated.report.status -in @('PASS', 'LOCAL_PASS'); status = $updated.report.status; runPath = $updated.runPath; summaryPath = $updated.summaryPath; errors = @($updated.report.errors) }
    }
    catch { $result = [pscustomobject][ordered]@{ ok = $false; status = 'INFRASTRUCTURE_ERROR'; runPath = $null; summaryPath = $null; errors = @($_.Exception.Message) } }
    $result | ConvertTo-Json -Depth 80 -Compress:$Compact
    if (-not $NoExit) { if ($result.status -in @('PASS', 'LOCAL_PASS')) { exit 0 } elseif ($result.status -eq 'REVIEW_PENDING') { exit 3 } elseif ($result.status -eq 'INFRASTRUCTURE_ERROR') { exit 4 } else { exit 2 } }
    return
}

$script:connection = $null
$script:orchestrationWatch = $null
$script:protocol = $null
$script:runtime = $null
$script:runId = "rsq-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$script:expectedBuildId = $ExpectedBuildId.ToLowerInvariant()
$script:gpuVendor = $GpuVendor
$script:evidenceRoot = [IO.Path]::GetFullPath($EvidenceDirectory)
$warnings = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
$infrastructureFailures = [Collections.Generic.List[string]]::new()
$assays = [ordered]@{ coc = $null; menu = $null; visual = $null }
$recoveries = [ordered]@{
    one = [pscustomobject][ordered]@{ state = 'not-run'; requestedDurationMs = 30000; wallClockMs = $null; evidence = 'recovery-1.json' }
    two = [pscustomobject][ordered]@{ state = 'not-run'; requestedDurationMs = 30000; wallClockMs = $null; evidence = 'recovery-2.json' }
}
$fixture = $null
$fixtureManifestRecord = $null
$runtimeEvidence = $null
$baselineEvidence = $null
$liveGpuEvidence = $null
$timeEvidence = [ordered]@{ deadlineStartsAfterRuntimeBinding = $true; orchestrationElapsedMs = $null; performanceElapsedMs = $null; within600Seconds = $false }
$performanceWatch = [Diagnostics.Stopwatch]::new()
$script:visualWatch = [Diagnostics.Stopwatch]::new()
$script:activeVisualRequestId = $null
$script:visualStartMayBeOwned = $false
$script:boundHealth = $null
$script:bindingIdentity = $null
$script:fixtureManifest = $null
$script:ownsStressCapture = $false
$script:ownsCpuCapture = $false
$script:traceMayBeOwned = $false
$script:ownedTransitionIds = [Collections.Generic.HashSet[uint64]]::new()
$script:phase = 'preflight'
$script:evidenceWritable = $false
$protocolRecord = $null

try {
    $protocolRecord = Get-CSXQualificationProtocol -Path $ProtocolPath
    $script:protocol = $protocolRecord.protocol
    if ($PrMode -and [bool]$script:protocol.thresholds.prBaselineRequired -and
        ([string]::IsNullOrWhiteSpace($BaselinePath) -or [string]::IsNullOrWhiteSpace($ExpectedBaselineBuildId))) {
        throw 'PR mode requires a matching baseline artifact and explicit baseline Build ID.'
    }
    if (Test-Path -LiteralPath $script:evidenceRoot) {
        if (@(Get-ChildItem -LiteralPath $script:evidenceRoot -Force).Count -ne 0) { throw 'EvidenceDirectory must be new or empty; existing evidence is never overwritten.' }
    }
    else { New-Item -ItemType Directory -Path $script:evidenceRoot -Force | Out-Null }
    $script:evidenceWritable = $true
    Copy-Item -LiteralPath $protocolRecord.path -Destination (Join-Path $script:evidenceRoot 'protocol.json')
    $runtimeFull = [IO.Path]::GetFullPath($RuntimePath)
    if (-not (Test-Path -LiteralPath $runtimeFull -PathType Leaf)) { throw "Runtime metadata does not exist: $runtimeFull" }
    $script:runtime = Get-Content -LiteralPath $runtimeFull -Raw | ConvertFrom-Json -Depth 50
    if ([string](Get-CSXPropertyValue $script:runtime 'buildId') -and [string]$script:runtime.buildId -ne $script:expectedBuildId) { throw 'Runtime metadata Build ID differs from -ExpectedBuildId.' }
    $controller = Join-Path (Split-Path -Parent $PSScriptRoot) 'devbench-control\Invoke-DevBenchControl.ps1'
    $bindingDirectory = Join-Path $script:evidenceRoot 'binding'
    $arguments = @('list', '-RuntimePath', $runtimeFull, '-ExpectedBuildId', $script:expectedBuildId, '-EvidenceDirectory', $bindingDirectory, '-EvidenceLabel', 'render-scale-qualification', '-NoExit', '-Compact')
    if (-not [string]::IsNullOrWhiteSpace($ExpectedArtifactSha256)) { $arguments += @('-ExpectedArtifactSha256', $ExpectedArtifactSha256.ToLowerInvariant()) }
    $bindingRaw = & $controller @arguments 2>&1
    $binding = ($bindingRaw -join "`n") | ConvertFrom-Json -Depth 100
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'binding\authoritative-list.json') -Value $binding | Out-Null
    if (-not [bool]$binding.ok) { throw "Exact DevBench runtime binding failed: $($binding.errors -join ' ')" }
    $script:bindingIdentity = Get-CSXPropertyValue $binding 'runtimeIdentity'
    $tools = @(Get-CSXPathValue $binding 'data.tools')
    $requiredTools = @('scenario', 'console', 'inspect', 'communityshaders.renderscale', 'communityshaders.upscaling_api', 'communityshaders.feature_api', 'communityshaders.screenshot')
    foreach ($name in $requiredTools) { if (@($tools | Where-Object name -eq $name).Count -ne 1) { throw "Authoritative tools/list did not expose exactly one '$name'." } }
    $renderDescriptor = @($tools | Where-Object name -eq 'communityshaders.renderscale')[0]
    Assert-ToolActions $renderDescriptor @('qualification_status', 'qualification_begin', 'qualification_dispatch', 'qualification_wait', 'qualification_cancel', 'dlss_trace_status', 'dlss_trace_reset', 'dlss_trace_start', 'dlss_trace_stop', 'dlss_trace_read', 'reset', 'start', 'stop', 'apply', 'cpu_performance_reset', 'cpu_performance_start', 'cpu_performance_stop')
    Assert-ToolActions (@($tools | Where-Object name -eq 'communityshaders.screenshot')[0]) @('capabilities', 'status', 'sequence_start', 'request_get', 'request_cancel')

    # The hard wall-clock deadline starts only after exact runtime/tool binding.
    $script:orchestrationWatch = [Diagnostics.Stopwatch]::StartNew()
    $fixtureManifestRecord = Get-CSXFixtureManifest -Path $FixtureManifestPath -GpuVendor $GpuVendor
    $script:fixtureManifest = $fixtureManifestRecord.manifest
    Copy-Item -LiteralPath $fixtureManifestRecord.path -Destination (Join-Path $script:evidenceRoot 'fixture-manifest.json')
    if ((Get-CSXFileSha256 (Join-Path $script:evidenceRoot 'fixture-manifest.json')) -ne $fixtureManifestRecord.sha256) { throw 'Copied fixture manifest SHA-256 changed.' }
    $script:connection = New-CSXMcpConnection -Runtime $script:runtime
    $health = Invoke-BoundTool -Tool 'inspect' -Arguments ([ordered]@{ kind = 'health' })
    $script:boundHealth = $health
    $rawSessionIdentity = Assert-AuthoritativeRuntimeBinding -BindingIdentity $script:bindingIdentity -Health $health
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'binding\raw-session-identity.json') -Value $rawSessionIdentity | Out-Null
    $qualificationStatus = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{
        action = 'qualification_status'; expectedBuildId = $script:expectedBuildId
    })
    if ([bool](Get-CSXPathValue $qualificationStatus 'qualification.active' $false)) {
        throw 'A render-scale qualification transition is already active.'
    }
    $scene = Invoke-BoundTool -Tool 'inspect' -Arguments ([ordered]@{ kind = 'scene' })
    $cell = Get-SceneCellEditorId $scene
    if (-not [string]::Equals($cell, [string]$script:protocol.fixture.startCellEditorId, [StringComparison]::OrdinalIgnoreCase)) { throw "Start fixture must already be $($script:protocol.fixture.startCellEditorId); actual cell is '$cell'." }
    $renderStatus = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'status'; expectedBuildId = $script:expectedBuildId })
    Assert-CSXProducer $renderStatus 'render-scale status'
    $liveGpuEvidence = Get-CSXLiveGpuFixtureEvidence -Adapter (Get-CSXPathValue $renderStatus 'status.adapter') -Manifest $fixtureManifestRecord.manifest -GpuVendor $GpuVendor
    Assert-RenderScaleInactiveCaptures $renderStatus
    $traceStatus = Invoke-BoundTool -Tool 'communityshaders.renderscale' -Arguments ([ordered]@{ action = 'dlss_trace_status'; expectedBuildId = $script:expectedBuildId })
    Assert-CSXProducer $traceStatus 'DLSS trace preflight'
    if ([bool](Get-CSXPathValue $traceStatus 'capture.active' $false)) { throw 'A DLSS trace was already active.' }
    $capabilities = Invoke-BoundTool -Tool 'communityshaders.upscaling_api' -Arguments ([ordered]@{ action = 'capabilities'; expectedBuildId = $script:expectedBuildId; clientId = 'csx-render-scale-qualification'; commandId = "$($script:runId)-capabilities" })
    Assert-CSXProducer $capabilities 'upscaling capabilities'
    Assert-MethodAvailability $capabilities
    $snapshot = Get-UpscalingSnapshot "$($script:runId)-preflight-snapshot"
    $fsrRuntime = Assert-ExteriorSnapshot $snapshot
    $script:fsrRuntime = $fsrRuntime
    $settings = Get-FeatureSettings "$($script:runId)-preflight-settings"
    Assert-FoveationSettings $settings
    $screenshotCapabilities = Invoke-BoundTool -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$($script:runId)-screenshot-capabilities"; action = 'capabilities' })
    foreach ($value in @('hmd_submission')) { if ($value -notin @(Get-CSXPathValue $screenshotCapabilities 'result.sources')) { throw "Screenshot capability '$value' is unavailable." } }
    foreach ($value in @('side_by_side', 'left_eye', 'right_eye')) { if ($value -notin @(Get-CSXPathValue $screenshotCapabilities 'result.views')) { throw "Screenshot view '$value' is unavailable." } }
    if ('wall_clock' -notin @(Get-CSXPathValue $screenshotCapabilities 'result.scheduleBases')) { throw 'Screenshot wall-clock scheduling is unavailable.' }
    $screenshotStatus = Invoke-BoundTool -Tool 'communityshaders.screenshot' -Arguments ([ordered]@{ contractMajor = 1; clientId = 'csx-render-scale-qualification'; commandId = "$($script:runId)-screenshot-status"; action = 'status' })
    if ([int](Get-CSXPathValue $screenshotStatus 'result.dispatcher.pendingOperations' 0) -ne 0 -or [int](Get-CSXPathValue $screenshotStatus 'result.worker.outstandingArtifacts' 0) -ne 0) { throw 'Screenshot service was not idle at preflight.' }
    $fixtureObject = [ordered]@{
        protocolSha256 = $protocolRecord.sha256; gpuVendor = $GpuVendor; fsrRuntime = $fsrRuntime
        fixtureManifest = [ordered]@{ schema = [string]$fixtureManifestRecord.manifest.schema; fixtureId = [string]$fixtureManifestRecord.manifest.fixtureId; sha256 = $fixtureManifestRecord.sha256; path = 'fixture-manifest.json'; identity = $fixtureManifestRecord.manifest }
        cells = [ordered]@{ exterior = $script:protocol.fixture.startCellEditorId; interior = $script:protocol.fixture.interiorCellEditorId }
        foveation = Get-CSXFoveationTarget $script:protocol
        matrixName = $(if ($GpuVendor -eq 'NVIDIA') { 'nvidiaMatrix' } else { 'amdMatrix' })
        dimensions = Get-CSXPathValue $snapshot 'snapshot.dimensions'
        upscalingCapabilities = Get-CSXPropertyValue $capabilities 'capabilities'
        screenshotContract = Get-CSXPropertyValue $screenshotCapabilities 'contract'
        runtime = [ordered]@{ vr = Get-CSXPropertyValue $health 'vr'; exe = Get-CSXPropertyValue $health 'exe'; hmd = Get-CSXPathValue $screenshotCapabilities 'server.runtime.hmd' }
        verification = [ordered]@{
            liveGpu = $liveGpuEvidence
            operatorAttestation = [ordered]@{
                operatorId = [string]$fixtureManifestRecord.manifest.attestation.operatorId
                recordedUtc = [string]$fixtureManifestRecord.manifest.attestation.recordedUtc
                fields = @($fixtureManifestRecord.manifest.attestation.operatorAttestedFields)
            }
        }
    }
    $fixtureJson = $fixtureObject | ConvertTo-Json -Depth 80 -Compress
    $fixtureHashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fixtureJson))
    $fixtureHash = [Convert]::ToHexString($fixtureHashBytes).ToLowerInvariant()
    $fixture = [pscustomobject][ordered]@{ gpuVendor = $GpuVendor; fsrRuntime = $fsrRuntime; matrixName = $fixtureObject.matrixName; fingerprint = $fixtureHash; manifest = $fixtureObject.fixtureManifest; inputs = $fixtureObject }
    $runtimeEvidence = [pscustomobject][ordered]@{ buildId = $script:expectedBuildId; artifactSha256 = $ExpectedArtifactSha256; binding = $binding.runtimeIdentity; health = $health }

    $baseline = if ($PrMode) { Resolve-BaselineRun -Path $BaselinePath -ExpectedBuildId $ExpectedBaselineBuildId -CandidateBuildId $script:expectedBuildId } else { $null }
    if ($PrMode) {
        if ([string]$baseline.run.fixture.fingerprint -ne $fixtureHash) { throw 'PR baseline fixture fingerprint does not match the candidate.' }
        if ([string]$baseline.run.protocol.sha256 -ne $protocolRecord.sha256) { throw 'PR baseline protocol hash does not match the candidate.' }
    }

    # Assay 1: one server-side scenario, no client polling between COCs.
    $script:phase = 'qualification'
    Invoke-DiagnosticStart 'COC'
    $cocScenarioRequest = New-CSXCocScenario -Protocol $script:protocol -GpuVendor $GpuVendor -FsrRuntime $fsrRuntime -ExpectedBuildId $script:expectedBuildId -RunId $script:runId
    foreach ($transitionId in 1..20) { [void]$script:ownedTransitionIds.Add([uint64]$transitionId) }
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'coc\scenario.request.json') -Value $cocScenarioRequest | Out-Null
    $performanceWatch.Start()
    $cocWallWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $cocScenario = Invoke-BoundTool -Tool 'scenario' -Arguments $cocScenarioRequest -OperationCapMs ([int]$script:protocol.timeBudget.cocAssayMs) -AllowSemanticFailure
    }
    catch { Invoke-EmergencyCleanup $warnings; throw }
    $cocWallWatch.Stop()
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'coc\scenario.result.json') -Value $cocScenario | Out-Null
    $cocDiagnostics = Invoke-DiagnosticStop 'COC'
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'coc\diagnostics.json') -Value $cocDiagnostics | Out-Null
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'coc\stress-record.json') -Value $cocDiagnostics.stress.record | Out-Null
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'coc\cpu-record.json') -Value $cocDiagnostics.cpu.cpuPerformance | Out-Null
    $cocRecords = @(Get-CSXQualificationWaitRecords -ScenarioResult $cocScenario -LabelPrefix 'coc')
    $cocFailureCount = Get-RenderScaleFailureEventCount $cocRecords
    $cocDiagnosticFailureLowerBound = Get-DiagnosticFailureLowerBound $cocRecords
    $cocFailureBreakdown = Get-DiagnosticFailureBreakdown $cocRecords
    $cocFailedTransitions = Get-FailedTransitionCount $cocRecords 20
    $cocTimes = [double[]]@($cocRecords | Where-Object { $null -ne $_.elapsedMs } | ForEach-Object elapsedMs)
    $cocRows = @(Convert-ToTransitionRows -Records $cocRecords -Matrix $null -Assay 'coc')
    $stretch = $null
    $stretchError = $null
    try { $stretch = Get-StretchSummary $cocDiagnostics.stress } catch { $stretchError = $_.Exception.Message }
    $cocStressTransitions = $null
    $cocStressError = $null
    try {
        $cocStressTransitions = Get-StressTransitionEvidence -StressStop $cocDiagnostics.stress -Scenario $cocScenario -WaitRecords $cocRecords -ExpectedCount 20
    }
    catch { $cocStressError = $_.Exception.Message }
    $assays.coc = [pscustomobject][ordered]@{
        completed = $cocRecords.Count; wallClockMs = [Math]::Round($cocWallWatch.Elapsed.TotalMilliseconds, 3); records = $cocRows; statistics = Get-CSXMetricSummary -Values $cocTimes -IncludeRate
        strata = [pscustomobject][ordered]@{
            interior = Get-CSXMetricSummary -Values ([double[]]@($cocRecords | Where-Object { $_.ordinal % 2 -eq 1 } | ForEach-Object elapsedMs)) -IncludeRate
            exterior = Get-CSXMetricSummary -Values ([double[]]@($cocRecords | Where-Object { $_.ordinal % 2 -eq 0 } | ForEach-Object elapsedMs)) -IncludeRate
        }
        failureCount = $cocFailureCount; diagnosticFailureLowerBound = $cocDiagnosticFailureLowerBound; failureBreakdown = $cocFailureBreakdown; failedTransitions = $cocFailedTransitions; failureWilson95 = Get-CSXWilsonInterval -Failures $cocFailedTransitions -Trials 20
        stretch = $stretch; stressTransitions = $cocStressTransitions
        validation = [pscustomobject][ordered]@{ scenarioOk = [bool]$cocScenario.ok -and -not [bool]$cocScenario.aborted; stretchError = $stretchError; stressRecordError = $cocStressError }
        evidence = [pscustomobject][ordered]@{ scenarioRequest = 'coc/scenario.request.json'; scenarioResult = 'coc/scenario.result.json'; stressRecord = 'coc/stress-record.json'; cpuRecord = 'coc/cpu-record.json' }
    }
    Write-TransitionEvidence -CocRows $cocRows -MenuRows @()
    if (-not [bool]$cocScenario.ok -or [bool]$cocScenario.aborted) { throw 'COC scenario failed or aborted.' }
    Assert-WaitRecords $cocRecords 20 'COC assay'
    if ($stretchError) { throw $stretchError }
    if ($cocStressError) { throw $cocStressError }
    if (-not $stretch.recordAccepted) { throw 'COC schema-v13 stress record verdict failed.' }
    if ($cocDiagnosticFailureLowerBound -ne 0 -or $cocFailedTransitions -ne 0) { throw "COC assay recorded $cocFailureCount render-scale failure events and diagnostic failures in $cocFailedTransitions transitions." }
    if ([double]$stretch.maxFrames -gt [double]$script:protocol.thresholds.maximumPresentationStretchEpisodeFrames -or [double]$stretch.meanFrames -gt [double]$script:protocol.thresholds.maximumMeanPresentationStretchEpisodeFrames) { throw 'COC presentation stretch exceeded the versioned threshold.' }

    $recoveryOneRequest = New-CSXRecoveryScenario -Protocol $script:protocol -ExpectedBuildId $script:expectedBuildId -RunId $script:runId -FsrRuntime $fsrRuntime -RecoveryLabel one
    $recoveries.one.state = 'RUNNING'
    $recoveryOneWatch = [Diagnostics.Stopwatch]::StartNew()
    $recoveryOne = Invoke-BoundTool -Tool 'scenario' -Arguments $recoveryOneRequest -OperationCapMs 35000 -AllowSemanticFailure
    $recoveryOneWatch.Stop()
    $recoveryOneElapsedMs = [Math]::Round($recoveryOneWatch.Elapsed.TotalMilliseconds, 3)
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'recovery-1.json') -Value ([ordered]@{ requestedDurationMs = 30000; wallClockMs = $recoveryOneElapsedMs; request = $recoveryOneRequest; result = $recoveryOne; evidence = $null }) | Out-Null
    try { $recoveryOneEvidence = Assert-RecoveryScenario $recoveryOne 'one' $fsrRuntime $recoveryOneElapsedMs }
    catch { $recoveries.one.state = 'FAIL'; throw }
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'recovery-1.json') -Value ([ordered]@{ requestedDurationMs = 30000; wallClockMs = $recoveryOneElapsedMs; request = $recoveryOneRequest; result = $recoveryOne; evidence = $recoveryOneEvidence }) | Out-Null
    $recoveries.one = [pscustomobject][ordered]@{ state = 'PASS'; requestedDurationMs = 30000; wallClockMs = $recoveryOneElapsedMs; evidence = 'recovery-1.json' }

    # Assay 2: deterministic CS-menu path with scoped trace sessions.
    Invoke-DiagnosticStart 'menu'
    $menuBuild = New-CSXMenuScenario -Protocol $script:protocol -GpuVendor $GpuVendor -FsrRuntime $fsrRuntime -ExpectedBuildId $script:expectedBuildId -ExpectedCellEditorId ([string]$script:protocol.fixture.startCellEditorId) -RunId $script:runId
    foreach ($transitionId in 101..125) { [void]$script:ownedTransitionIds.Add([uint64]$transitionId) }
    $script:traceMayBeOwned = $true
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'menu\scenario.request.json') -Value $menuBuild.scenario | Out-Null
    $menuWallWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $menuScenario = Invoke-BoundTool -Tool 'scenario' -Arguments $menuBuild.scenario -OperationCapMs ([int]$script:protocol.timeBudget.menuAssayMs) -AllowSemanticFailure
    }
    catch { Invoke-EmergencyCleanup $warnings; throw }
    $menuWallWatch.Stop()
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'menu\scenario.result.json') -Value $menuScenario | Out-Null
    $menuDiagnostics = Invoke-DiagnosticStop 'menu'
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'menu\diagnostics.json') -Value $menuDiagnostics | Out-Null
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'menu\stress-record.json') -Value $menuDiagnostics.stress.record | Out-Null
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'menu\cpu-record.json') -Value $menuDiagnostics.cpu.cpuPerformance | Out-Null
    $menuRecords = @(Get-CSXQualificationWaitRecords -ScenarioResult $menuScenario -LabelPrefix 'menu')
    $menuFailureCount = Get-RenderScaleFailureEventCount $menuRecords
    $menuDiagnosticFailureLowerBound = Get-DiagnosticFailureLowerBound $menuRecords
    $menuFailureBreakdown = Get-DiagnosticFailureBreakdown $menuRecords
    $menuFailedTransitions = Get-FailedTransitionCount $menuRecords 25
    $traceEvidence = Test-CSXDLSSScenarioEvidence -ScenarioResult $menuScenario -GpuVendor $GpuVendor
    foreach ($warning in $traceEvidence.warnings) { $warnings.Add($warning) }
    $menuTimes = [double[]]@($menuRecords | Where-Object { $null -ne $_.elapsedMs } | ForEach-Object elapsedMs)
    $menuRows = @(Convert-ToTransitionRows -Records $menuRecords -Matrix $menuBuild.matrix -Assay 'menu')
    $menuStretch = $null
    $menuStretchError = $null
    try { $menuStretch = Get-StretchSummary $menuDiagnostics.stress } catch { $menuStretchError = $_.Exception.Message }
    $menuStressTransitions = $null
    $menuStressError = $null
    try {
        $menuStressTransitions = Get-StressTransitionEvidence -StressStop $menuDiagnostics.stress -Scenario $menuScenario -WaitRecords $menuRecords -Matrix $menuBuild.matrix -ExpectedCount 25 -RequireExactMenu
    }
    catch { $menuStressError = $_.Exception.Message }
    $assays.menu = [pscustomobject][ordered]@{
        matrixName = $menuBuild.matrixName; completed = $menuRecords.Count; wallClockMs = [Math]::Round($menuWallWatch.Elapsed.TotalMilliseconds, 3); records = $menuRows
        statistics = Get-CSXMetricSummary -Values $menuTimes -IncludeRate; strata = Get-MenuStrata $menuRows
        failureCount = $menuFailureCount; diagnosticFailureLowerBound = $menuDiagnosticFailureLowerBound; failureBreakdown = $menuFailureBreakdown; failedTransitions = $menuFailedTransitions; failureWilson95 = Get-CSXWilsonInterval -Failures $menuFailedTransitions -Trials 25
        stretch = $menuStretch; stressTransitions = $menuStressTransitions
        dlssTrace = [pscustomobject][ordered]@{
            outcome = $(if (-not $traceEvidence.ok) { 'failed' } elseif ($GpuVendor -eq 'NVIDIA') { 'dispatch_validated' } else { 'capability_lifecycle_only_zero_dispatch' })
            evidence = $traceEvidence
        }
        validation = [pscustomobject][ordered]@{ scenarioOk = [bool]$menuScenario.ok -and -not [bool]$menuScenario.aborted; stretchError = $menuStretchError; stressRecordError = $menuStressError }
        evidence = [pscustomobject][ordered]@{ scenarioRequest = 'menu/scenario.request.json'; scenarioResult = 'menu/scenario.result.json'; stressRecord = 'menu/stress-record.json'; cpuRecord = 'menu/cpu-record.json'; dlssTraces = 'menu/dlss-traces.json' }
    }
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'menu\dlss-traces.json') -Value ([pscustomobject][ordered]@{ readLimit = [int]$script:protocol.menuAssay.traceReadLimit; detail = 'bounded_partial_raw_records_with_authoritative_summary_and_pinned_failures'; evidence = $traceEvidence }) | Out-Null
    Write-TransitionEvidence -CocRows $cocRows -MenuRows $menuRows
    if (-not [bool]$menuScenario.ok -or [bool]$menuScenario.aborted) { throw 'CS-menu scenario failed or aborted.' }
    Assert-WaitRecords $menuRecords 25 'CS-menu assay' $menuBuild.matrix
    Assert-MenuPolicies $menuScenario $menuRecords
    if ($menuStretchError) { throw $menuStretchError }
    if ($menuStressError) { throw $menuStressError }
    if (-not $menuStretch.recordAccepted) { throw 'CS-menu schema-v13 stress record verdict failed.' }
    if ($menuDiagnosticFailureLowerBound -ne 0 -or $menuFailedTransitions -ne 0) { throw 'CS-menu assay recorded a render-scale or diagnostic failure.' }
    if (-not $traceEvidence.ok) { throw "DLSS trace validation failed: $($traceEvidence.errors -join ' ')" }
    $script:traceMayBeOwned = $false

    $recoveryTwoRequest = New-CSXRecoveryScenario -Protocol $script:protocol -ExpectedBuildId $script:expectedBuildId -RunId $script:runId -FsrRuntime $fsrRuntime -RecoveryLabel two
    $recoveries.two.state = 'RUNNING'
    $recoveryTwoWatch = [Diagnostics.Stopwatch]::StartNew()
    $recoveryTwo = Invoke-BoundTool -Tool 'scenario' -Arguments $recoveryTwoRequest -OperationCapMs 35000 -AllowSemanticFailure
    $recoveryTwoWatch.Stop()
    $recoveryTwoElapsedMs = [Math]::Round($recoveryTwoWatch.Elapsed.TotalMilliseconds, 3)
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'recovery-2.json') -Value ([ordered]@{ requestedDurationMs = 30000; wallClockMs = $recoveryTwoElapsedMs; request = $recoveryTwoRequest; result = $recoveryTwo; evidence = $null }) | Out-Null
    try { $recoveryTwoEvidence = Assert-RecoveryScenario $recoveryTwo 'two' $fsrRuntime $recoveryTwoElapsedMs }
    catch { $recoveries.two.state = 'FAIL'; throw }
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'recovery-2.json') -Value ([ordered]@{ requestedDurationMs = 30000; wallClockMs = $recoveryTwoElapsedMs; request = $recoveryTwoRequest; result = $recoveryTwo; evidence = $recoveryTwoEvidence }) | Out-Null
    $recoveries.two = [pscustomobject][ordered]@{ state = 'PASS'; requestedDurationMs = 30000; wallClockMs = $recoveryTwoElapsedMs; evidence = 'recovery-2.json' }

    # Assay 3: three sequential one-minute asynchronous HMD sequences.
    $visualRuns = [Collections.Generic.List[object]]::new()
    $visualObservations = [Collections.Generic.List[object]]::new()
    $assays.visual = [pscustomobject][ordered]@{
        state = 'in_progress'; completedReplicates = 0; wallClockMs = 0.0
        requestedFrames = 48; validatedChildReceipts = 0; reviewOrdinals = @(1, 8, 16)
        indexPath = $null; indexSha256 = $null; fixtureObservations = @(); runs = @()
    }
    $script:visualWatch.Start()
    $visualObservations.Add((Get-VisualFixtureObservation -Label 'visual-before-1' -FsrRuntime $fsrRuntime))
    $assays.visual.fixtureObservations = @($visualObservations | ForEach-Object { [pscustomobject][ordered]@{ label = $_.label; ok = [bool]$_.result.ok } })
    for ($replicate = 1; $replicate -le 3; $replicate++) {
        $destination = Join-Path $script:evidenceRoot "visual\rep-$($replicate.ToString('D2'))"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        $request = New-CSXVisualSequenceRequest -Protocol $script:protocol -RunId $script:runId -Replicate $replicate -DestinationDirectory $destination
        Write-CSXJsonFile -Path (Join-Path $destination 'sequence.request.json') -Value $request | Out-Null
        $script:visualStartMayBeOwned = $true
        $start = Invoke-BoundTool -Tool 'communityshaders.screenshot' -Arguments $request
        $run = Wait-VisualSequence -StartResponse $start -Replicate $replicate
        Write-CSXJsonFile -Path (Join-Path $destination 'sequence.terminal.json') -Value $run.receipt | Out-Null
        $visualRuns.Add($run)
        $visualObservations.Add((Get-VisualFixtureObservation -Label "visual-after-$replicate" -FsrRuntime $fsrRuntime))
        $assays.visual.completedReplicates = $visualRuns.Count
        $assays.visual.wallClockMs = [Math]::Round($script:visualWatch.Elapsed.TotalMilliseconds, 3)
        $assays.visual.fixtureObservations = @($visualObservations | ForEach-Object { [pscustomobject][ordered]@{ label = $_.label; ok = [bool]$_.result.ok } })
        $assays.visual.runs = @($visualRuns | ForEach-Object { [pscustomobject][ordered]@{
            replicate = $_.replicate; requestId = $_.requestId
            manifestPath = [IO.Path]::GetRelativePath($script:evidenceRoot, $_.manifestPath); manifestSha256 = $_.manifestSha256
            terminalReceiptPath = "visual/rep-$($_.replicate.ToString('D2'))/sequence.terminal.json"
        } })
    }
    $visualIntegrity = Get-VisualIndexSamples @($visualRuns)
    foreach ($replicate in 1..3) {
        Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot "visual\rep-$($replicate.ToString('D2'))\children.receipts.json") -Value @($visualIntegrity.children | Where-Object replicate -eq $replicate) | Out-Null
    }
    $visualIndex = [pscustomobject][ordered]@{ schema = 'csx-render-scale-visual-index-v1'; runId = $script:runId; samples = @($visualIntegrity.samples) }
    Assert-CSXVisualIndexSet -VisualIndex $visualIndex -Label 'Candidate' -ExpectedRunId $script:runId
    $visualIndexPath = Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'visual-index.json') -Value $visualIndex
    $visualIndexSha256 = Get-CSXFileSha256 $visualIndexPath
    $script:visualWatch.Stop()
    $performanceWatch.Stop()
    if ($script:visualWatch.Elapsed.TotalMilliseconds -gt [int]$script:protocol.timeBudget.visualAssayMs) {
        throw 'The visual assay, including all 48 child-receipt integrity checks, exceeded its 195 second allocation.'
    }
    $assays.visual = [pscustomobject][ordered]@{
        state = 'complete'; completedReplicates = $visualRuns.Count; wallClockMs = [Math]::Round($script:visualWatch.Elapsed.TotalMilliseconds, 3)
        requestedFrames = 48; validatedChildReceipts = @($visualIntegrity.children).Count; reviewOrdinals = @(1, 8, 16)
        indexPath = 'visual-index.json'; indexSha256 = $visualIndexSha256
        fixtureObservations = @($visualObservations | ForEach-Object { [pscustomobject][ordered]@{ label = $_.label; ok = [bool]$_.result.ok } })
        runs = @($visualRuns | ForEach-Object { [pscustomobject][ordered]@{
            replicate = $_.replicate; requestId = $_.requestId
            manifestPath = [IO.Path]::GetRelativePath($script:evidenceRoot, $_.manifestPath); manifestSha256 = $_.manifestSha256
            terminalReceiptPath = "visual/rep-$($_.replicate.ToString('D2'))/sequence.terminal.json"
            childReceiptsPath = "visual/rep-$($_.replicate.ToString('D2'))/children.receipts.json"
        } })
    }

    if ($PrMode) {
        $candidateCoc = @($assays.coc.records | Select-Object ordinal, elapsedMs)
        $candidateMenu = @($assays.menu.records | Select-Object ordinal, elapsedMs)
        $cocComparison = Get-CSXPairedComparison -Candidate $candidateCoc -Baseline @($baseline.run.assays.coc.records)
        $menuComparison = Get-CSXPairedComparison -Candidate $candidateMenu -Baseline @($baseline.run.assays.menu.records)
        $cocSpeedGate = [double]$cocComparison.aggregateDelta.median.percent -le [double]$script:protocol.thresholds.cocMedianRegressionPercent -and [double]$cocComparison.aggregateDelta.p95.percent -le [double]$script:protocol.thresholds.cocP95RegressionPercent
        $menuSpeedGate = [double]$menuComparison.aggregateDelta.median.percent -le [double]$script:protocol.thresholds.menuMedianRegressionPercent -and [double]$menuComparison.aggregateDelta.p95.percent -le [double]$script:protocol.thresholds.menuP95RegressionPercent
        $bundle = Copy-BaselineBundle $baseline
        $baselineEvidence = [pscustomobject][ordered]@{
            path = $bundle.path; runSha256 = $bundle.runSha256; visualIndexPath = $bundle.visualIndexPath; visualIndexSha256 = $bundle.visualIndexSha256
            candidateRunId = $script:runId; baselineRunId = [string]$baseline.run.runId
            baselineBuildId = [string]$baseline.run.runtime.buildId; expectedBaselineBuildId = $ExpectedBaselineBuildId.ToLowerInvariant()
            cocPaired = $cocComparison; menuPaired = $menuComparison
            gates = [pscustomobject][ordered]@{ cocAggregateMedianP95 = $cocSpeedGate; menuAggregateMedianP95 = $menuSpeedGate }
        }
        if (-not $cocSpeedGate) { throw 'COC aggregate median/p95 performance regression exceeded the versioned threshold.' }
        if (-not $menuSpeedGate) { throw 'Menu aggregate median/p95 performance regression exceeded the versioned threshold.' }
    }

    $script:orchestrationWatch.Stop()
    $timeEvidence.orchestrationElapsedMs = [Math]::Round($script:orchestrationWatch.Elapsed.TotalMilliseconds, 3)
    $timeEvidence.performanceElapsedMs = [Math]::Round($performanceWatch.Elapsed.TotalMilliseconds, 3)
    $timeEvidence.within600Seconds = $timeEvidence.orchestrationElapsedMs -le [int]$script:protocol.timeBudget.orchestrationMs
    if (-not $timeEvidence.within600Seconds) { throw 'The run exceeded the 600 second orchestration deadline.' }
    $script:phase = 'evidence_finalization'
    $raw = [pscustomobject][ordered]@{
        schema = $(if ($PrMode) { 'csx-render-scale-pr-v1-raw' } else { 'csx-render-scale-local-v1-raw' }); runId = $script:runId; createdUtc = [DateTime]::UtcNow.ToString('o'); prMode = [bool]$PrMode
        protocol = [pscustomobject][ordered]@{ schema = $script:protocol.schema; revision = $script:protocol.protocolRevision; sha256 = $protocolRecord.sha256; requiredMethodsCommit = $script:protocol.requiredMethodsCommit }
        fixture = $fixture; runtime = $runtimeEvidence; time = $timeEvidence; assays = [pscustomobject]$assays; recoveries = [pscustomobject]$recoveries; baseline = $baselineEvidence
        automatedGates = [pscustomobject][ordered]@{ passed = $true; failures = @(); infrastructureErrors = @() }
        warnings = @($warnings | Select-Object -Unique)
    }
    $rawPath = Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'run.raw.json') -Value $raw
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'mcp-transcript.json') -Value @($script:connection.transcript) | Out-Null
    $baselineIndex = if ($PrMode) {
        $bundledBaselineIndexPath = Resolve-CSXEvidencePath -EvidenceRoot $script:evidenceRoot -RelativePath ([string]$baselineEvidence.visualIndexPath)
        Get-Content -LiteralPath $bundledBaselineIndexPath -Raw | ConvertFrom-Json -Depth 100
    }
    else { $null }
    $template = New-CSXVisualReviewTemplate -EvidenceDirectory $script:evidenceRoot -RunRaw $raw -VisualIndex $visualIndex -BaselineVisualIndex $baselineIndex
    Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'visual-review.template.json') -Value $template | Out-Null
    $updated = Update-CSXQualificationReport -EvidenceDirectory $script:evidenceRoot
    $result = [pscustomobject][ordered]@{ ok = $false; status = $updated.report.status; runPath = $updated.runPath; summaryPath = $updated.summaryPath; reviewTemplatePath = (Join-Path $script:evidenceRoot 'visual-review.template.json'); errors = @($updated.report.errors) }
}
catch {
    $failureClass = [string]$_.Exception.Data['CSXFailureClass']
    $isInfrastructureFailure = $failureClass -eq 'infrastructure' -or $script:phase -in @('preflight', 'evidence_finalization')
    if ($isInfrastructureFailure) { $infrastructureFailures.Add($_.Exception.Message) } else { $failures.Add($_.Exception.Message) }
    if ($script:connection -and $script:runtime -and (Test-RunnerOwnsRuntimeState)) { Invoke-EmergencyCleanup $warnings }
    if ($script:orchestrationWatch -and $script:orchestrationWatch.IsRunning) { $script:orchestrationWatch.Stop() }
    if ($performanceWatch.IsRunning) { $performanceWatch.Stop() }
    if ($script:orchestrationWatch) {
        $timeEvidence.orchestrationElapsedMs = [Math]::Round($script:orchestrationWatch.Elapsed.TotalMilliseconds, 3)
        $timeEvidence.within600Seconds = $timeEvidence.orchestrationElapsedMs -le 600000
    }
    $timeEvidence.performanceElapsedMs = [Math]::Round($performanceWatch.Elapsed.TotalMilliseconds, 3)
    if (-not $script:evidenceWritable) {
        $result = [pscustomobject][ordered]@{
            ok = $false; status = 'INFRASTRUCTURE_ERROR'; runPath = $null
            summaryPath = $null; reviewTemplatePath = $null
            errors = @($failures) + @($infrastructureFailures)
        }
    }
    else { try {
        if (-not (Test-Path -LiteralPath $script:evidenceRoot -PathType Container)) { New-Item -ItemType Directory -Path $script:evidenceRoot -Force | Out-Null }
        if ($script:connection) { Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'mcp-transcript.json') -Value @($script:connection.transcript) | Out-Null }
        if (-not (Test-Path -LiteralPath (Join-Path $script:evidenceRoot 'visual-index.json') -PathType Leaf)) {
            Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'visual-index.json') -Value ([pscustomobject][ordered]@{ schema = 'csx-render-scale-visual-index-v1'; runId = $script:runId; samples = @() }) | Out-Null
        }
        $protocolSummary = if ($script:protocol) { [pscustomobject][ordered]@{ schema = $script:protocol.schema; revision = $script:protocol.protocolRevision; sha256 = $(if ($protocolRecord) { $protocolRecord.sha256 } else { $null }); requiredMethodsCommit = $script:protocol.requiredMethodsCommit } } else { $null }
        $raw = [pscustomobject][ordered]@{
            schema = $(if ($PrMode) { 'csx-render-scale-pr-v1-raw' } else { 'csx-render-scale-local-v1-raw' }); runId = $script:runId; createdUtc = [DateTime]::UtcNow.ToString('o'); prMode = [bool]$PrMode
            protocol = $protocolSummary; fixture = $fixture; runtime = $runtimeEvidence; time = $timeEvidence; assays = [pscustomobject]$assays; recoveries = [pscustomobject]$recoveries; baseline = $baselineEvidence
            automatedGates = [pscustomobject][ordered]@{ passed = $false; failures = @($failures); infrastructureErrors = @($infrastructureFailures) }; warnings = @($warnings | Select-Object -Unique)
        }
        Write-CSXJsonFile -Path (Join-Path $script:evidenceRoot 'run.raw.json') -Value $raw | Out-Null
        $updated = Update-CSXQualificationReport -EvidenceDirectory $script:evidenceRoot
        $result = [pscustomobject][ordered]@{ ok = $false; status = $updated.report.status; runPath = $updated.runPath; summaryPath = $updated.summaryPath; reviewTemplatePath = $null; errors = @($updated.report.errors) }
    }
    catch { $result = [pscustomobject][ordered]@{ ok = $false; status = 'INFRASTRUCTURE_ERROR'; runPath = $null; summaryPath = $null; reviewTemplatePath = $null; errors = @($failures) + @($infrastructureFailures) + @("Evidence finalization failed: $($_.Exception.Message)") } } }
}

$result | ConvertTo-Json -Depth 100 -Compress:$Compact
if (-not $NoExit) {
    if ($result.status -in @('PASS', 'LOCAL_PASS')) { exit 0 }
    elseif ($result.status -eq 'REVIEW_PENDING') { exit 3 }
    elseif ($result.status -eq 'INFRASTRUCTURE_ERROR') { exit 4 }
    else { exit 2 }
}
