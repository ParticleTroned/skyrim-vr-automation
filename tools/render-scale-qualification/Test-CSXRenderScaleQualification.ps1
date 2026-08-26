# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$module = Join-Path $PSScriptRoot 'RenderScaleQualification.psm1'
$protocolPath = Join-Path $PSScriptRoot 'protocol.v1.json'
Import-Module $module -Force

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('csx-render-scale-qualification-' + [guid]::NewGuid().ToString('N'))
try {
    $record = Get-CSXQualificationProtocol -Path $protocolPath
    $protocol = $record.protocol
    Assert-Test ($record.sha256 -match '^[a-f0-9]{64}$') 'Protocol hash is not SHA-256.'
    Assert-Test ($protocol.requiredMethodsCommit -eq 'b46edeaed14c41ad41225641c3a4943f1db25db6') 'Required methods commit is not frozen.'
    $reorderedProtocol = ($protocol | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $first = $reorderedProtocol.menuAssay.nvidiaMatrix[0]
    $reorderedProtocol.menuAssay.nvidiaMatrix[0] = $reorderedProtocol.menuAssay.nvidiaMatrix[1]
    $reorderedProtocol.menuAssay.nvidiaMatrix[1] = $first
    $reorderRejected = $false
    try { Assert-CSXProtocol -Protocol $reorderedProtocol } catch { $reorderRejected = $true }
    Assert-Test $reorderRejected 'A reordered canonical menu matrix was accepted.'
    foreach ($mutation in @('cell', 'foveation', 'visual', 'gate')) {
        $changedProtocol = ($protocol | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
        switch ($mutation) {
            cell { $changedProtocol.fixture.interiorCellEditorId = 'WhiterunBanneredMare' }
            foveation { $changedProtocol.fixture.foveation.peripheryTAAOuterScale = 0.6 }
            visual { $changedProtocol.visualAssay.source.fallback = 'game_mirror' }
            gate { $changedProtocol.thresholds.maximumPresentationStretchEpisodeFrames = 3 }
        }
        $mutationRejected = $false
        try { Assert-CSXProtocol -Protocol $changedProtocol } catch { $mutationRejected = $true }
        Assert-Test $mutationRejected "A revision-1 $mutation mutation was accepted."
    }
    $moduleSource = Get-Content -LiteralPath $module -Raw
    $toolCallBody = [regex]::Match($moduleSource, '(?s)function Invoke-CSXMcpTool.*?(?=function Get-CSXRemainingMilliseconds)').Value
    Assert-Test ($toolCallBody -match 'Invoke-WebRequest' -and $toolCallBody -notmatch 'Invoke-CSXRetriedWebRequest') 'Mutating MCP tools/call can still be replayed.'

    $cocNvidia = New-CSXCocScenario -Protocol $protocol -GpuVendor NVIDIA -FsrRuntime fsr4 -ExpectedBuildId ('a' * 64) -RunId test
    Assert-Test (@($cocNvidia.steps).Count -eq 60) 'COC scenario is not exactly begin/coc/wait x20.'
    Assert-Test (@($cocNvidia.steps | Where-Object tool -eq 'console').Count -eq 20) 'COC scenario does not contain exactly 20 console COCs.'
    $cocWaits = @($cocNvidia.steps | Where-Object label -like 'coc-*-wait')
    Assert-Test ($cocWaits.Count -eq 20 -and @($cocWaits.args.timeoutMs | Sort-Object -Unique)[0] -eq 120000) 'COC waiter ceiling is incorrect.'
    Assert-Test ($cocWaits[0].args.target.method -eq 'dlss' -and $cocWaits[0].args.target.dlssProfile -eq 'K' -and -not $cocWaits[0].args.target.renderScaleMode) 'NVIDIA interior target is not exact DLAA/K.'
    Assert-Test ($cocWaits[1].args.target.method -eq 'fsr' -and $cocWaits[1].args.target.fsrRuntime -eq 'fsr4' -and $cocWaits[1].args.target.qualityMode -eq 1) 'Exterior target did not freeze the FSR runtime.'
    Assert-Test ($cocWaits[0].args.foveation.peripheryTAAEnable -and [double]$cocWaits[0].args.foveation.peripheryTAAOuterScale -eq 0.7) 'COC waiter omitted the exact foveation target.'

    $nvidiaMenu = New-CSXMenuScenario -Protocol $protocol -GpuVendor NVIDIA -FsrRuntime fsr3 -ExpectedBuildId ('b' * 64) -ExpectedCellEditorId WindhelmExterior01 -RunId test
    Assert-Test (@($nvidiaMenu.scenario.steps | Where-Object label -like 'menu-*-wait').Count -eq 25) 'NVIDIA menu matrix does not contain 25 waits.'
    Assert-Test (@($nvidiaMenu.scenario.steps | Where-Object { $_.label -like 'menu-*-dlss_trace_read' }).Count -eq @($protocol.menuAssay.nvidiaMatrix | Where-Object method -eq dlss).Count) 'NVIDIA DLSS transitions are not individually traced.'
    $lastNvidiaWait = @($nvidiaMenu.scenario.steps | Where-Object label -eq 'menu-25-wait')[0]
    Assert-Test ($lastNvidiaWait.args.target.method -eq 'fsr' -and $lastNvidiaWait.args.target.qualityMode -eq 1) 'NVIDIA matrix does not end at FSR Hoshipa.'

    $amdMenu = New-CSXMenuScenario -Protocol $protocol -GpuVendor AMD -FsrRuntime fsr3 -ExpectedBuildId ('c' * 64) -ExpectedCellEditorId WindhelmExterior01 -RunId test
    Assert-Test (@($amdMenu.scenario.steps | Where-Object label -like 'menu-*-wait').Count -eq 25) 'AMD menu matrix does not contain 25 waits.'
    Assert-Test (@($amdMenu.scenario.steps | Where-Object { $_.label -like 'menu-*-apply' -and $_.args.method -ne 'fsr' }).Count -eq 0) 'AMD matrix attempts a non-FSR apply.'
    Assert-Test (@($amdMenu.scenario.steps | Where-Object label -like 'amd-capability-dlss_trace_*').Count -eq 4) 'AMD matrix omitted the zero-dispatch DLSS trace lifecycle check.'

    $recovery = New-CSXRecoveryScenario -Protocol $protocol -ExpectedBuildId ('d' * 64) -RunId test -FsrRuntime fsr4 -RecoveryLabel one
    Assert-Test (@($recovery.steps | Where-Object { $null -ne (Get-CSXPropertyValue $_ 'wait') }).Count -eq 1 -and [int]$recovery.steps[0].wait -eq 30000) 'Recovery does not contain exactly one 30 second server wait.'
    Assert-Test (@($recovery.steps | Where-Object { [string](Get-CSXPathValue $_ 'args.action') -in @('qualification_begin', 'qualification_wait', 'qualification_cancel') }).Count -eq 0) 'Recovery incorrectly uses a fresh-transition waiter.'
    Assert-Test (@($recovery.steps | Where-Object { (Get-CSXPropertyValue $_ 'tool') -eq 'communityshaders.screenshot' }).Count -eq 1) 'Recovery omitted screenshot readiness.'

    $visualRequest = New-CSXVisualSequenceRequest -Protocol $protocol -RunId test -Replicate 1 -DestinationDirectory $fixture
    Assert-Test ($visualRequest.sequence.frameCount -eq 16 -and $visualRequest.sequence.schedule.basis -eq 'wall_clock' -and $visualRequest.sequence.schedule.intervalMs -eq 4000) 'Visual wall-clock sequence is incorrect.'
    Assert-Test (@($visualRequest.sequence.capture.outputs).Count -eq 3 -and $visualRequest.sequence.capture.source.fallback -eq 'reject') 'Visual sequence does not request all stereo views with reject fallback.'

    $summary = Get-CSXMetricSummary -Values ([double[]]@(1, 2, 3, 4)) -IncludeRate
    Assert-Test ($summary.total -eq 10 -and $summary.median -eq 2.5 -and $summary.mean -eq 2.5 -and [Math]::Abs($summary.sampleStandardDeviation - 1.2909944487) -lt 0.000001 -and $summary.p95 -eq 4 -and $summary.transitionsPerMinute -eq 24000) 'Metric summary does not use the required definitions.'
    $wilson = Get-CSXWilsonInterval -Failures 0 -Trials 20
    Assert-Test ($wilson.lower -eq 0 -and $wilson.upper -gt 0.16 -and $wilson.upper -lt 0.17) 'Wilson 95% interval is incorrect.'

    $traceSummary = [pscustomobject]@{
        active = $false; sessionID = 7; capacity = 256; retainedRecords = 3; totalRecords = 4; overwrittenRecords = 1; droppedRecords = 0
        setConstantsCalls = 2; evaluateCalls = 2; duplicatedConstantsFailures = 0; evaluateFailures = 0
        lastDuplicatedConstantsFailureFound = $false; lastEvaluateFailureFound = $false
    }
    $traceStartSummary = [pscustomobject]@{
        active = $true; sessionID = 7; capacity = 256; retainedRecords = 0; totalRecords = 0; overwrittenRecords = 0; droppedRecords = 0
        setConstantsCalls = 0; evaluateCalls = 0; duplicatedConstantsFailures = 0; evaluateFailures = 0
        lastDuplicatedConstantsFailureFound = $false; lastEvaluateFailureFound = $false
    }
    $traceResetSummary = [pscustomobject]@{
        active = $false; sessionID = 6; capacity = 256; retainedRecords = 0; totalRecords = 0; overwrittenRecords = 0; droppedRecords = 0
        setConstantsCalls = 0; evaluateCalls = 0; duplicatedConstantsFailures = 0; evaluateFailures = 0
        lastDuplicatedConstantsFailureFound = $false; lastEvaluateFailureFound = $false
    }
    $leftSignature = [pscustomobject]@{
        traceSessionID = 7; frame = 30; frameToken = 40; requestedViewport = 0; resolvedViewport = 0; eye = 0
        output = [pscustomobject]@{ width = 100; height = 100 }; extentIn = [pscustomobject]@{ width = 70; height = 70 }
        extentOut = [pscustomobject]@{ width = 100; height = 100 }; qualityMode = 1; dlssPreset = 1
        streamlineConstants = [pscustomobject]@{ cameraFOV = @(1, 2) }
        resources = [pscustomobject]@{ colorIn = '0x0000000000000001'; colorOut = '0x0000000000000002'; depth = '0x0000000000000003'; motionVectors = '0x0000000000000004' }
    }
    $rightSignature = [pscustomobject]@{
        traceSessionID = 7; frame = 30; frameToken = 40; requestedViewport = 1; resolvedViewport = 1; eye = 1
        output = [pscustomobject]@{ width = 100; height = 100 }; extentIn = [pscustomobject]@{ width = 70; height = 70 }
        extentOut = [pscustomobject]@{ width = 100; height = 100 }; qualityMode = 1; dlssPreset = 1
        streamlineConstants = [pscustomobject]@{ cameraFOV = @(1, 2) }
        resources = [pscustomobject]@{ colorIn = '0x0000000000000011'; colorOut = '0x0000000000000012'; depth = '0x0000000000000013'; motionVectors = '0x0000000000000014' }
    }
    $leftConstants = [pscustomobject]@{ sequence = 1; timestampQPC = 10; stage = 'set_constants'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $leftSignature }
    $rightConstants = [pscustomobject]@{ sequence = 3; timestampQPC = 11; stage = 'set_constants'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $rightSignature }
    $traceRecords = @(
        [pscustomobject]@{ current = [pscustomobject]@{ sequence = 2; timestampQPC = 11; stage = 'evaluate'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $leftSignature }; previousConstantsFound = $true; previousConstants = $leftConstants },
        [pscustomobject]@{ current = $rightConstants; previousConstantsFound = $false },
        [pscustomobject]@{ current = [pscustomobject]@{ sequence = 4; timestampQPC = 12; stage = 'evaluate'; resultCode = 0; threadID = 1; compositorCycle = 20; signature = $rightSignature }; previousConstantsFound = $true; previousConstants = $rightConstants }
    )
    $traceWaitResults = @(foreach ($ordinal in 1..25) {
        [pscustomobject]@{
            label = "menu-$($ordinal.ToString('D2'))-wait"
            result = [pscustomobject]@{ target = [pscustomobject]@{ method = $(if ($ordinal -eq 1) { 'dlss' } else { 'fsr' }); qualityMode = 1 } }
        }
    })
    $traceScenario = [pscustomobject]@{ results = @($traceWaitResults) + @(
        [pscustomobject]@{ label = 'menu-dlss_trace_status-preflight'; result = [pscustomobject]@{ action = 'dlss_trace_status'; capture = $traceResetSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_reset'; result = [pscustomobject]@{ action = 'dlss_trace_reset'; capture = $traceResetSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_start'; result = [pscustomobject]@{ action = 'dlss_trace_start'; capture = $traceStartSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_stop'; result = [pscustomobject]@{ action = 'dlss_trace_stop'; capture = $traceSummary } },
        [pscustomobject]@{ label = 'menu-01-dlss_trace_read'; result = [pscustomobject]@{ action = 'dlss_trace_read'; capture = [pscustomobject]@{
            summary = $traceSummary; afterSequence = 0; limit = 16; availableFromSequence = 2; requestedSequenceOverwritten = $true
            latestSequence = 4; lastReturnedSequence = 4; moreAvailable = $false; records = $traceRecords
        } } }
    ) }
    $traceCheck = Test-CSXDLSSScenarioEvidence -ScenarioResult $traceScenario -GpuVendor NVIDIA
    Assert-Test ($traceCheck.ok -and $traceCheck.warnings.Count -eq 1) 'Ring overwrite was not classified as partial raw detail only.'
    $traceSummary.droppedRecords = 1
    Assert-Test (-not (Test-CSXDLSSScenarioEvidence -ScenarioResult $traceScenario -GpuVendor NVIDIA).ok) 'Dropped DLSS records did not fail the trace gate.'
    $traceSummary.droppedRecords = 0
    $truncatedTrace = $traceScenario | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $truncatedRead = @($truncatedTrace.results | Where-Object label -eq 'menu-01-dlss_trace_read')[0]
    $truncatedRead.result.capture.records = @($truncatedRead.result.capture.records | Select-Object -First 2)
    Assert-Test (-not (Test-CSXDLSSScenarioEvidence -ScenarioResult $truncatedTrace -GpuVendor NVIDIA).ok) 'A truncated DLSS read page passed retained-record completeness.'

    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $fixtureManifestPath = Join-Path $fixture 'fixture.json'
    Write-CSXJsonFile -Path $fixtureManifestPath -Value ([pscustomobject][ordered]@{
        schema = 'csx-render-scale-fixture-v1'; fixtureId = 'test-fixture'
        save = [pscustomobject]@{ id = 'save'; sha256 = ('1' * 64) }
        camera = [pscustomobject]@{ id = 'camera'; configurationSha256 = ('2' * 64) }
        vrFpsStabilizer = [pscustomobject]@{ version = '1.0'; configurationSha256 = ('3' * 64) }
        gpu = [pscustomobject]@{ vendor = 'NVIDIA'; deviceId = '0x2684'; driverVersion = '32.0.15.9000' }
        hmd = [pscustomobject]@{ model = 'hmd'; runtime = 'SteamVR'; runtimeVersion = 'runtime'; refreshHz = 90 }
        attestation = [pscustomobject]@{ operatorId = 'offline-test'; recordedUtc = '2026-08-26T12:00:00Z'; operatorAttestedFields = @('save', 'camera', 'vrFpsStabilizer', 'hmd') }
    }) | Out-Null
    $fixtureRecord = Get-CSXFixtureManifest -Path $fixtureManifestPath -GpuVendor NVIDIA
    Assert-Test ($fixtureRecord.sha256 -match '^[a-f0-9]{64}$') 'Fixture manifest was not hash-bound.'
    $liveGpu = Get-CSXLiveGpuFixtureEvidence -Adapter ([pscustomobject]@{
        available = $true; driverVersionAvailable = $true; vendorId = 0x10DE; deviceId = 0x2684
        driverVersion = '32.0.15.9000'; description = 'NVIDIA test adapter'; luidHigh = 1; luidLow = 2
    }) -Manifest $fixtureRecord.manifest -GpuVendor NVIDIA
    Assert-Test ($liveGpu.verified -and $liveGpu.deviceId -eq '0x2684') 'Live GPU identity was not bound to the fixture.'
    $wrongGpuRejected = $false
    try {
        Get-CSXLiveGpuFixtureEvidence -Adapter ([pscustomobject]@{
            available = $true; driverVersionAvailable = $true; vendorId = 0x1002; deviceId = 0x2684; driverVersion = '32.0.15.9000'
        }) -Manifest $fixtureRecord.manifest -GpuVendor NVIDIA | Out-Null
    } catch { $wrongGpuRejected = $true }
    Assert-Test $wrongGpuRejected 'A live adapter from the wrong vendor was accepted.'
    $wrongDriverRejected = $false
    try {
        Get-CSXLiveGpuFixtureEvidence -Adapter ([pscustomobject]@{
            available = $true; driverVersionAvailable = $true; vendorId = 0x10DE; deviceId = 0x2684; driverVersion = '32.0.15.9999'
        }) -Manifest $fixtureRecord.manifest -GpuVendor NVIDIA | Out-Null
    } catch { $wrongDriverRejected = $true }
    Assert-Test $wrongDriverRejected 'A mismatched live driver version was accepted.'
    $fixtureMismatchRejected = $false
    try { Get-CSXFixtureManifest -Path $fixtureManifestPath -GpuVendor AMD | Out-Null } catch { $fixtureMismatchRejected = $true }
    Assert-Test $fixtureMismatchRejected 'Fixture GPU mismatch was accepted.'
    $candidateRoot = Join-Path $fixture 'candidate'
    $baselineRoot = Join-Path $candidateRoot 'baseline'
    New-Item -ItemType Directory -Path (Join-Path $candidateRoot 'visual') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $baselineRoot 'visual') -Force | Out-Null
    $candidateSamples = [Collections.Generic.List[object]]::new()
    $baselineSamples = [Collections.Generic.List[object]]::new()
    foreach ($replicate in 1..3) {
        foreach ($ordinal in @(1, 8, 16)) {
            $candidateArtifacts = [Collections.Generic.List[object]]::new()
            $baselineArtifacts = [Collections.Generic.List[object]]::new()
            foreach ($view in @('left_eye', 'right_eye', 'side_by_side')) {
                $relative = "visual/rep-${replicate}-ord-${ordinal}-${view}.png"
                $candidatePath = Join-Path $candidateRoot $relative
                $baselinePath = Join-Path $baselineRoot $relative
                [IO.File]::WriteAllText($candidatePath, "candidate-$replicate-$ordinal-$view", [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($baselinePath, "baseline-$replicate-$ordinal-$view", [Text.UTF8Encoding]::new($false))
                $candidateArtifacts.Add([pscustomobject]@{ view = $view; path = $relative; sha256 = Get-CSXFileSha256 $candidatePath })
                $baselineArtifacts.Add([pscustomobject]@{ view = $view; path = $relative; sha256 = Get-CSXFileSha256 $baselinePath })
            }
            $candidateSamples.Add([pscustomobject]@{ replicate = $replicate; ordinal = $ordinal; artifacts = @($candidateArtifacts) })
            $baselineSamples.Add([pscustomobject]@{ replicate = $replicate; ordinal = $ordinal; artifacts = @($baselineArtifacts) })
        }
    }
    $candidateIndex = [pscustomobject]@{ schema = 'csx-render-scale-visual-index-v1'; runId = 'candidate'; samples = @($candidateSamples) }
    $baselineIndex = [pscustomobject]@{ schema = 'csx-render-scale-visual-index-v1'; runId = 'baseline'; samples = @($baselineSamples) }
    $baselineIndexPath = Write-CSXJsonFile -Path (Join-Path $baselineRoot 'visual-index.json') -Value $baselineIndex
    $baselineIndexHash = Get-CSXFileSha256 $baselineIndexPath
    $baselineRunPath = Write-CSXJsonFile -Path (Join-Path $baselineRoot 'run.json') -Value ([pscustomobject]@{
        schema = 'csx-render-scale-pr-v1'; status = 'PASS'; runId = 'baseline'
        runtime = [pscustomobject]@{ buildId = ('f' * 64) }
        assays = [pscustomobject]@{ visual = [pscustomobject]@{ indexPath = 'visual-index.json'; indexSha256 = $baselineIndexHash } }
    })
    $baselineRunHash = Get-CSXFileSha256 $baselineRunPath
    $candidateIndexPath = Write-CSXJsonFile -Path (Join-Path $candidateRoot 'visual-index.json') -Value $candidateIndex
    $candidateIndexHash = Get-CSXFileSha256 $candidateIndexPath
    $raw = [pscustomobject][ordered]@{
        schema = 'csx-render-scale-pr-v1-raw'; runId = 'candidate'; prMode = $true
        protocol = [pscustomobject]@{ schema = 'csx-render-scale-pr-v1'; revision = 1; sha256 = $record.sha256 }
        fixture = [pscustomobject]@{ gpuVendor = 'NVIDIA'; fingerprint = 'fixture' }
        runtime = [pscustomobject]@{ buildId = ('e' * 64) }
        time = [pscustomobject]@{ orchestrationElapsedMs = 500000; performanceElapsedMs = 450000 }
        assays = [pscustomobject]@{
            coc = [pscustomobject]@{ completed = 20; records = @(); statistics = [pscustomobject]@{ median = 1; p95 = 2; max = 2 }; failureCount = 0; failureWilson95 = $wilson; stretch = [pscustomobject]@{ meanFrames = 1; meanMs = 1; maxFrames = 2; maxMs = 2 } }
            menu = [pscustomobject]@{ matrixName = 'nvidiaMatrix'; completed = 25; records = @(); statistics = [pscustomobject]@{ median = 1; p95 = 2 }; dlssTrace = [pscustomobject]@{ outcome = 'dispatch_validated' } }
            visual = [pscustomobject]@{ completedReplicates = 3; indexPath = 'visual-index.json'; indexSha256 = $candidateIndexHash }
        }
        baseline = [pscustomobject]@{ path = 'baseline/run.json'; runSha256 = $baselineRunHash; baselineRunId = 'baseline'; visualIndexPath = 'baseline/visual-index.json'; visualIndexSha256 = $baselineIndexHash }
        automatedGates = [pscustomobject]@{ passed = $true; failures = @() }; warnings = @()
    }
    Write-CSXJsonFile -Path (Join-Path $candidateRoot 'run.raw.json') -Value $raw | Out-Null
    $review = New-CSXVisualReviewTemplate -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -BaselineVisualIndex $baselineIndex
    $review.reviewer.id = 'offline-test'; $review.reviewer.kind = 'human'; $review.reviewedUtc = [DateTime]::UtcNow.ToString('o'); $review.overallVerdict = 'pass'
    foreach ($sample in $review.samples) {
        foreach ($name in @('sharpness', 'blur', 'shimmer', 'stereoAlignment', 'equalEyeScale', 'geometryCorrespondence', 'renderScaleLatch')) { $sample.verdicts.$name = 'no_regression' }
    }
    $reviewResult = Test-CSXVisualReview -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -Review $review -BaselineVisualIndex $baselineIndex
    Assert-Test $reviewResult.ok 'A correctly hash-bound PR visual review did not pass.'
    $duplicateReview = ($review | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100)
    $duplicateReview.samples[0].candidateArtifacts[2] = $duplicateReview.samples[0].candidateArtifacts[1]
    Assert-Test (-not (Test-CSXVisualReview -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -Review $duplicateReview -BaselineVisualIndex $baselineIndex).ok) 'A duplicated candidate artifact binding was accepted.'
    Write-CSXJsonFile -Path (Join-Path $candidateRoot 'visual-review.json') -Value $review | Out-Null
    $final = Update-CSXQualificationReport -EvidenceDirectory $candidateRoot
    Assert-Test ($final.report.status -eq 'PASS') "Offline review finalization did not produce PASS: $($final.report.errors -join ' | ')"
    $localRoot = Join-Path $fixture 'local'
    New-Item -ItemType Directory -Path (Join-Path $localRoot 'visual') -Force | Out-Null
    foreach ($sample in $candidateSamples) {
        foreach ($artifact in $sample.artifacts) {
            Copy-Item -LiteralPath (Join-Path $candidateRoot $artifact.path) -Destination (Join-Path $localRoot $artifact.path)
        }
    }
    Write-CSXJsonFile -Path (Join-Path $localRoot 'visual-index.json') -Value $candidateIndex | Out-Null
    $localRaw = $raw | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $localRaw.schema = 'csx-render-scale-local-v1-raw'; $localRaw.prMode = $false; $localRaw.baseline = $null
    $localRaw.automatedGates | Add-Member -NotePropertyName infrastructureErrors -NotePropertyValue @() -Force
    Write-CSXJsonFile -Path (Join-Path $localRoot 'run.raw.json') -Value $localRaw | Out-Null
    $localReview = New-CSXVisualReviewTemplate -EvidenceDirectory $localRoot -RunRaw $localRaw -VisualIndex $candidateIndex
    $localReview.reviewer.id = 'offline-test'; $localReview.reviewer.kind = 'human'; $localReview.reviewedUtc = [DateTime]::UtcNow.ToString('o'); $localReview.overallVerdict = 'pass'
    foreach ($sample in $localReview.samples) {
        foreach ($name in @('sharpness', 'blur', 'shimmer', 'stereoAlignment', 'equalEyeScale', 'geometryCorrespondence', 'renderScaleLatch')) { $sample.verdicts.$name = 'pass' }
    }
    Write-CSXJsonFile -Path (Join-Path $localRoot 'visual-review.json') -Value $localReview | Out-Null
    $localFinal = Update-CSXQualificationReport -EvidenceDirectory $localRoot
    Assert-Test ($localFinal.report.status -eq 'LOCAL_PASS' -and $localFinal.report.schema -eq 'csx-render-scale-local-v1' -and
        [IO.Path]::GetFileName($localFinal.summaryPath) -eq 'qualification-summary.md') 'Standalone evidence could be confused with a passing PR qualification.'
    $localRaw.automatedGates.infrastructureErrors = @('synthetic transport failure')
    Write-CSXJsonFile -Path (Join-Path $localRoot 'run.raw.json') -Value $localRaw | Out-Null
    $infrastructureFinal = Update-CSXQualificationReport -EvidenceDirectory $localRoot
    Assert-Test ($infrastructureFinal.report.status -eq 'INFRASTRUCTURE_ERROR') 'Infrastructure failure was not classified separately.'
    [IO.File]::AppendAllText((Join-Path $candidateRoot $candidateSamples[0].artifacts[0].path), 'tamper')
    Assert-Test (-not (Test-CSXVisualReview -EvidenceDirectory $candidateRoot -RunRaw $raw -VisualIndex $candidateIndex -Review $review -BaselineVisualIndex $baselineIndex).ok) 'Tampered candidate image did not invalidate the review.'

    [pscustomobject]@{ ok = $true; protocolSha256 = $record.sha256; cocTransitions = 20; nvidiaMenuTransitions = 25; amdMenuTransitions = 25; visualSamples = 9 } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
