# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('capture-interaction-test-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = [IO.Path]::GetFullPath($root)
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Import-Module (Join-Path $PSScriptRoot 'CaptureInteractionControl.psm1') -Force
    $pose = [pscustomobject]@{ available=$true; connected=$true; valid=$true; index=0; trackingResult=200; matrix=@(1,0,0,0,0,1,0,0,0,0,1,0); velocity=@(0,0,0); angularVelocity=@(0,0,0) }
    $controller = [pscustomobject]@{ available=$true; connected=$true; valid=$true; index=1; trackingResult=200; matrix=@(1,0,0,0,0,1,0,0,0,0,1,0); velocity=@(0,0,0); angularVelocity=@(0,0,0); controller=[pscustomobject]@{ packetNumber=4; pressed=99; touched=99; axes=@(@(0,0),@(0,0),@(0,0),@(0,0),@(0,0)) } }
    $frame = [pscustomobject]@{ tMs=0; seq=1; originCode=1; hmd=$pose; left=$controller; right=($controller | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
    $frame.right.index = 2
    $compiled = @(New-CaptureInteractionFrames -ObservedFrame $frame -ActionName 'accept')
    Assert-Test ($compiled.Count -eq 3) 'accept compiles into neutral, active, and released frames'
    Assert-Test ($compiled[0].right.controller.pressed -eq 0 -and $compiled[1].right.controller.pressed -eq 8589934592 -and $compiled[2].right.controller.pressed -eq 0) 'accept changes only the bounded active state'
    Assert-Test ($compiled[0].right.index -eq 2 -and $compiled[1].hmd.matrix[0] -eq 1) 'named actions preserve observed tracked poses'
    Assert-Test ($compiled[0].right.controller.packetNumber -lt $compiled[1].right.controller.packetNumber -and $compiled[1].right.controller.packetNumber -lt $compiled[2].right.controller.packetNumber) 'controller packets advance for every transition'
    $key = New-CaptureInteractionFrames -ActionName key-tap -ActionArguments ([pscustomobject]@{ key='space'; holdMs=5000 })
    Assert-Test ($key.arguments.durationMs -eq 5000 -and -not $key.arguments.PSObject.Properties['holdMs']) 'keyboard taps compile without VR poses and emit the supported durationMs field'
    foreach ($invalidDuration in @(9,5001)) {
        $rejected = $false
        try { $null = New-CaptureInteractionFrames -ActionName key-tap -ActionArguments ([pscustomobject]@{ key='space'; holdMs=$invalidDuration }) } catch { $rejected = $true }
        Assert-Test $rejected 'keyboard duration outside DevBench limits must be rejected'
    }

    $actualLeft = [pscustomobject]@{ view='left_eye'; format='png'; colourContract='sdr_srgb'; width=100; height=100 }
    $actualRight = [pscustomobject]@{ view='right_eye'; format='png'; colourContract='sdr_srgb'; width=100; height=100 }
    $acquisition = [pscustomobject]@{ acquisition=[pscustomobject]@{ sourceKind='hmd_submission'; engineFrame=25; compositorCycle=40 } }
    $receipt = [pscustomobject]@{ requestId='req'; state='running'; children=@(
        [pscustomobject]@{ ordinal=1; actual=$acquisition; scheduledEngineFrame=10; artifacts=@([pscustomobject]@{ actual=$actualLeft;path='old.png';committed=$true }) },
        [pscustomobject]@{ ordinal=2; actual=$acquisition; scheduledEngineFrame=20; artifacts=@([pscustomobject]@{ actual=$actualRight;path='right.png';committed=$true },[pscustomobject]@{ actual=$actualLeft;path='latest.png';committed=$true }) }
    ) }
    $latest = Get-CaptureInteractionLatestFrame -Receipt $receipt -PreferredView left_eye
    Assert-Test ($latest.path -eq 'latest.png' -and $latest.ordinal -eq 2 -and $latest.engineFrame -eq 25 -and $latest.scheduledEngineFrame -eq 20) 'latest-frame selection uses nested actual metadata and acquired frame rather than scheduled frame'
    $partialReceipt = [pscustomobject]@{ requestId='partial'; state='running'; children=@(
        [pscustomobject]@{ ordinal=2; actual=$acquisition; scheduledEngineFrame=20; artifacts=@([pscustomobject]@{ actual=$actualLeft;path='stale-left.png';committed=$true }) },
        [pscustomobject]@{ ordinal=3; actual=$acquisition; scheduledEngineFrame=30; artifacts=@([pscustomobject]@{ actual=$actualRight;path='current-right.png';committed=$true }) }
    ) }
    $partialLatest = Get-CaptureInteractionLatestFrame -Receipt $partialReceipt -PreferredView left_eye
    Assert-Test ($partialLatest.path -eq 'current-right.png') 'latest-frame selection never prefers an older eye over the newest committed frame'
    $manifestPath = Join-Path $root 'frames/sequence.json'
    $sequenceReceipt = [pscustomobject]@{
        requestId='sequence'; kind='sequence'; state='completed'; actual=[pscustomobject]@{}
        manifest=[pscustomobject]@{finalPath=$manifestPath;partialPath="$manifestPath.partial"}
        observedManifest=[pscustomobject]@{path=$manifestPath}
        artifacts=@([pscustomobject]@{path=$manifestPath;committed=$true})
        children=$receipt.children
    }
    $sequenceLatest = Get-CaptureInteractionLatestFrame -Receipt $sequenceReceipt
    Assert-Test ($sequenceLatest.path -eq (Join-Path $root 'frames/latest.png') -and $sequenceLatest.engineFrame -eq 25) 'sequence packaging manifests are not images and child image paths resolve against the observed manifest'
    $sequenceReceipt.artifacts[0].path = Join-Path $root 'frames/unknown.json'
    $rejectedPackaging = $false
    try { $null = Get-CaptureInteractionLatestFrame -Receipt $sequenceReceipt } catch { $rejectedPackaging = $true }
    Assert-Test $rejectedPackaging 'unrecognized committed sequence artifacts remain invalid'
    $sequenceReceipt.artifacts[0].path = $manifestPath
    $sequenceReceipt.children[1].artifacts[1].path = '../escaped.png'
    $rejectedEscape = $false
    try { $null = Get-CaptureInteractionLatestFrame -Receipt $sequenceReceipt } catch { $rejectedEscape = $true }
    Assert-Test $rejectedEscape 'relative image paths cannot escape the observed manifest directory'
    $sequenceReceipt.children[1].artifacts[1].path = 'latest.png'
    $acquisition.acquisition.sourceKind = 'desktop_mirror'
    $rejectedSource = $false
    try { $null = Get-CaptureInteractionLatestFrame -Receipt $receipt } catch { $rejectedSource = $true }
    Assert-Test $rejectedSource 'source mismatch cannot be presented as an HMD frame'

    Add-Type -AssemblyName System.Drawing.Common
    $viewSession = Join-Path $root 'viewing-fixture'
    $viewFrames = Join-Path $viewSession 'frames'
    New-Item -ItemType Directory -Path $viewFrames -Force | Out-Null
    $viewOriginal = Join-Path $viewFrames 'noise.png'
    $bitmap = [Drawing.Bitmap]::new(256, 256, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
    try {
        $locked = $bitmap.LockBits([Drawing.Rectangle]::new(0,0,256,256), [Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)
        try {
            $pixels = [byte[]]::new($locked.Stride * 256)
            [Random]::new(7).NextBytes($pixels)
            [Runtime.InteropServices.Marshal]::Copy($pixels, 0, $locked.Scan0, $pixels.Length)
        }
        finally { $bitmap.UnlockBits($locked) }
        $bitmap.Save($viewOriginal, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
    $originalHash = (Get-FileHash -LiteralPath $viewOriginal).Hash
    $viewFrame = [pscustomobject]@{
        path=$viewOriginal;view='left_eye';format='png';colourContract='sdr_srgb';width=256;height=256
        bytes=(Get-Item -LiteralPath $viewOriginal).Length;sha256=$originalHash;committed=$true
        ordinal=8;engineFrame=25;requestId='frame-8';acquisition=[pscustomobject]@{sourceKind='hmd_submission';engineFrame=25}
    }
    $originalSubmission = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-original'
    Assert-Test ($originalSubmission.path -eq $viewOriginal -and $originalSubmission.mimeType -eq 'image/png' -and -not $originalSubmission.viewing.derivative -and $originalSubmission.original.sha256 -eq $originalHash) 'small verified PNGs are submitted losslessly with original provenance'
    $viewSubmission = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-jpeg' -MaximumBytes 32768
    Assert-Test ($viewSubmission.mimeType -eq 'image/jpeg' -and $viewSubmission.bytes -le 32768 -and $viewSubmission.viewing.derivative -and $viewSubmission.viewing.lossy -and $viewSubmission.viewing.jpegQuality -lt 95 -and $viewSubmission.viewing.attemptedQualities.Count -le 11) 'large viewing images use a bounded deterministic JPEG quality fallback'
    $preview = [Drawing.Image]::FromFile($viewSubmission.path)
    try { Assert-Test ($preview.Width -eq 256 -and $preview.Height -eq 256) 'viewing derivatives preserve full image dimensions' }
    finally { $preview.Dispose() }
    $previewWriteTime = (Get-Item -LiteralPath $viewSubmission.path).LastWriteTimeUtc
    $repeatSubmission = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-repeat' -MaximumBytes 32768
    Assert-Test ($repeatSubmission.path -eq $viewSubmission.path -and $repeatSubmission.sha256 -eq $viewSubmission.sha256 -and (Get-Item -LiteralPath $viewSubmission.path).LastWriteTimeUtc -eq $previewWriteTime) 'matching deterministic viewing artifacts are reused without rewriting'
    Assert-Test ((Get-FileHash -LiteralPath $viewOriginal).Hash -eq $originalHash -and $viewSubmission.original.acquisition.sourceKind -eq 'hmd_submission' -and $viewSubmission.original.requestId -eq 'frame-8') 'viewing conversion preserves original bytes and HMD acquisition identity'
    $viewRejected = $false
    try { $null = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-too-small' -MaximumBytes 1 } catch { $viewRejected = $_.Exception.Message -match 'No full-resolution viewing JPEG fits' }
    Assert-Test $viewRejected 'an impossible byte budget fails explicitly without resizing the image'
    $viewFrame.sha256 = ('0' * 64)
    $viewRejected = $false
    try { $null = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-wrong-hash' } catch { $viewRejected = $_.Exception.Message -match 'SHA-256' }
    Assert-Test $viewRejected 'viewing artifacts cannot be made from mismatched original bytes'
    $viewFrame.sha256 = $originalHash
    $viewRejected = $false
    try { $null = New-CaptureInteractionFrameSubmission $viewFrame $viewSession (Join-Path $viewSession 'different-frames') 'view-outside' } catch { $viewRejected = $_.Exception.Message -match 'escaped' }
    Assert-Test $viewRejected 'viewing sources must remain inside the owned frames directory'
    [IO.File]::WriteAllBytes($viewSubmission.path, [byte[]](1,2,3))
    $viewRejected = $false
    try { $null = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-conflict' -MaximumBytes 32768 } catch { $viewRejected = $_.Exception.Message -match 'conflicts' }
    Assert-Test ($viewRejected -and (Get-Item -LiteralPath $viewSubmission.path).Length -eq 3) 'conflicting existing derivatives fail without overwriting evidence'
    $corruptOriginal = Join-Path $viewFrames 'corrupt.png'
    [IO.File]::WriteAllBytes($corruptOriginal, [byte[]]::new(24))
    $corruptFrame = $viewFrame | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $corruptFrame.path = $corruptOriginal
    $corruptFrame.bytes = 24
    $corruptFrame.sha256 = (Get-FileHash -LiteralPath $corruptOriginal).Hash
    $viewRejected = $false
    try { $null = New-CaptureInteractionFrameSubmission $corruptFrame $viewSession $viewFrames 'view-corrupt' } catch { $viewRejected = $_.Exception.Message -match 'not a PNG' }
    Assert-Test $viewRejected 'a matching file hash cannot make malformed bytes a viewing image'
    $viewFrame.width = 257
    $viewRejected = $false
    try { $null = New-CaptureInteractionFrameSubmission $viewFrame $viewSession $viewFrames 'view-dimensions' } catch { $viewRejected = $_.Exception.Message -match 'dimensions differ' }
    Assert-Test $viewRejected 'viewing submission requires the encoded dimensions to match the capture receipt'

    $saveRoot = Join-Path $root 'saves'
    New-Item -ItemType Directory -Path $saveRoot -Force | Out-Null
    $utcBoundary = ConvertTo-CaptureInteractionUtcBoundary -Value '2026-08-26T09:30:58.715Z'
    $savePath = Join-Path $saveRoot 'Save3_Test_WhiterunWorld.ess'
    [IO.File]::WriteAllBytes($savePath, [byte[]](1,2,3,4))
    [IO.File]::SetLastWriteTimeUtc($savePath, [DateTime]::SpecifyKind([DateTime]'2026-08-26T09:33:10', [DateTimeKind]::Utc))
    $saveCandidates = @(Get-CaptureInteractionSaveCandidates -Directory $saveRoot -SinceUtc $utcBoundary -NamePattern 'Save3*')
    Assert-Test ($saveCandidates.Count -eq 1 -and $saveCandidates[0].name -eq 'Save3_Test_WhiterunWorld.ess') 'save boundary parsing and comparison remain UTC-safe in non-UTC local time'

    $fake = Join-Path $PSScriptRoot 'tests/Invoke-FakeCaptureDevBench.ps1'
    $runtime = Join-Path $root 'runtime.json'
    '{}' | Set-Content -LiteralPath $runtime -Encoding utf8
    $env:CAPTURE_INTERACTION_FAKE_ROOT = $root
    $env:CAPTURE_INTERACTION_EXPECTED_IDENTITY = '{"pid":123,"buildId":"fixture-build"}'
    $entry = Join-Path $PSScriptRoot 'Invoke-CaptureInteraction.ps1'
    $session = Join-Path $root 'session'
    $started = & $entry start -SessionDirectory $session -RuntimePath $runtime -ExpectedRuntimeIdentityJson $env:CAPTURE_INTERACTION_EXPECTED_IDENTITY -VisualMode sequence -MaximumFrames 10 -FrameIntervalMs 500 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($started.ok -and $started.state -eq 'session-started' -and $started.data.screenshot.requestId -eq 'req-1') 'sequence session starts recording and screenshot capture under one session'
    $observed = & $entry observe -SessionDirectory $session -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($observed.ok -and $observed.data.observation.latestFrame.ordinal -eq 4) 'observe composites runtime state and the latest committed frame'
    Assert-Test ($observed.data.observation.frameSubmission.mimeType -eq 'image/png' -and $observed.data.observation.frameSubmission.original.sha256 -eq $observed.data.observation.latestFrame.sha256) 'observe automatically supplies a bounded viewing artifact with its original source hash'
    Assert-Test (Test-Path -LiteralPath $observed.data.observationPath -PathType Leaf) 'observe persists a latest-observation receipt'
    $env:CAPTURE_INTERACTION_SESSION_PATH = $started.data.statePath
    $acted = & $entry act -SessionDirectory $session -ActionName accept -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($acted.ok -and $acted.state -eq 'action-submitted' -and $acted.data.action.receipt.compiledFrames.Count -eq 3 -and -not $acted.data.action.receipt.terminal.active) 'named action observes, submits, and awaits one atomic tracked-set sequence'
    $keyActed = & $entry act -SessionDirectory $session -ActionName key-tap -ActionArgumentsJson '{"key":"space","holdMs":123}' -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($keyActed.ok -and $keyActed.data.action.receipt.result.durationMs -eq 123) 'keyboard dispatch preserves the requested duration'
    $stopped = & $entry stop -SessionDirectory $session -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact | ConvertFrom-Json -Depth 100
    Assert-Test ($stopped.ok -and $stopped.state -eq 'stopped' -and $stopped.data.recording.stopReceipt.path -eq 'recording.json') 'stop finalizes visual capture before state recording and persists receipts'
    $calls = @(Get-Content -LiteralPath (Join-Path $root 'calls.ndjson') | ConvertFrom-Json -Depth 80)
    Assert-Test (@($calls | Where-Object { $_.tool -eq 'record' -and $_.arguments.action -eq 'stop' -and $_.arguments.expectedCorrelationId -eq $started.data.sessionId }).Count -eq 1) 'record stop uses the accepted correlation guard'
    Assert-Test (@($calls | Where-Object { $_.tool -eq 'input' -and $_.arguments.action -in @('stop','releaseAll') }).Count -eq 0) 'normally completed VR action needs no release mutation'
    $wrongIdentity = & $entry observe -SessionDirectory $session -ExpectedRuntimeIdentityJson '{"pid":456}' -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $wrongIdentity.ok -and $wrongIdentity.errors[0] -match 'identity') 'a resumed command cannot replace the persisted runtime identity'
    Remove-Item Env:CAPTURE_INTERACTION_EXPECTED_IDENTITY

    function Start-FixtureSession([string]$Name, [string]$Mode = 'none') {
        Remove-Item -LiteralPath (Join-Path $root 'fake-state.json') -ErrorAction SilentlyContinue
        Remove-Item Env:CAPTURE_INTERACTION_SCENARIO -ErrorAction SilentlyContinue
        $created = & $entry start -SessionDirectory (Join-Path $root $Name) -RuntimePath $runtime -VisualMode $Mode -MaximumFrames 10 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
        Assert-Test $created.ok "Fixture session $Name starts."
        $env:CAPTURE_INTERACTION_SESSION_PATH = $created.data.statePath
        return $created.data
    }
    foreach ($scenario in @('timeout', 'restore-pending')) {
        $testSession = Start-FixtureSession $scenario
        $env:CAPTURE_INTERACTION_SCENARIO = $scenario
        $failed = & $entry act -SessionPath $testSession.statePath -ActionName accept -ActionTimeoutSeconds 1 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
        Assert-Test (-not $failed.ok -and $failed.data.vrAction.accepted.controlToken -eq 'fixture-owned-token' -and $failed.data.vrAction.state -eq 'uncertain') 'a timed out or unrestored action preserves its cleanup token and uncertainty'
        $savedAction = Get-Content -LiteralPath $testSession.statePath -Raw | ConvertFrom-Json -Depth 80
        Assert-Test ($savedAction.vrAction.accepted.generation -eq 1 -and $savedAction.vrAction.error) 'accepted generation and failure survive in the durable session'
        $cleaned = & $entry abort -SessionPath $testSession.statePath -ActionTimeoutSeconds 1 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
        Assert-Test ($cleaned.ok -and $cleaned.data.vrAction.state -eq 'restored' -and $cleaned.data.vrAction.terminal.lastCompletion.controllerIndicesRestored) 'abort uses the token and waits through restorationPending for the exact generation'
    }
    $testSession = Start-FixtureSession 'superseded'
    $env:CAPTURE_INTERACTION_SCENARIO = 'superseded'
    $failed = & $entry act -SessionPath $testSession.statePath -ActionName accept -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $failed.ok -and $failed.errors[0] -match 'generation') 'an inactive later generation cannot prove this action completed'
    $beforeCleanup = @(Get-Content -LiteralPath (Join-Path $root 'calls.log') | Where-Object { $_ -eq 'input/stop' }).Count
    $cleaned = & $entry abort -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    $afterCleanup = @(Get-Content -LiteralPath (Join-Path $root 'calls.log') | Where-Object { $_ -eq 'input/stop' }).Count
    Assert-Test (-not $cleaned.ok -and $beforeCleanup -eq $afterCleanup -and $cleaned.data.vrAction.accepted.controlToken) 'cleanup never releases a superseding owner and retains the unresolved token'

    $testSession = Start-FixtureSession 'interrupted'
    $env:CAPTURE_INTERACTION_SCENARIO = 'interrupted'
    $failed = & $entry act -SessionPath $testSession.statePath -ActionName accept -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $failed.ok -and $failed.data.vrAction.state -eq 'restored' -and -not $failed.data.vrAction.terminal.lastCompletion.completed) 'restored interrupted input is retained as a failed action'
    $null = & $entry stop -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit

    $testSession = Start-FixtureSession 'record-limit'
    $env:CAPTURE_INTERACTION_SCENARIO = 'record-limit'
    $observedLimit = & $entry observe -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $observedLimit.ok -and $observedLimit.data.observation.recording.value.limitReached) 'observation exposes recording coverage loss'
    $limitedAction = & $entry act -SessionPath $testSession.statePath -ActionName accept -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $limitedAction.ok) 'recording limit prevents further input mutation'
    $limitedStop = & $entry stop -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $limitedStop.ok -and $limitedStop.data.recording.stopReceipt.path -eq 'recording.json' -and $limitedStop.data.recording.stopReceipt.limitReached) 'limited recording is persisted but never classified complete'

    $testSession = Start-FixtureSession 'record-owner'
    $env:CAPTURE_INTERACTION_SCENARIO = 'record-owner'
    $beforeCleanup = @(Get-Content -LiteralPath (Join-Path $root 'calls.log') | Where-Object { $_ -eq 'record/stop' }).Count
    $foreignStop = & $entry stop -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    $afterCleanup = @(Get-Content -LiteralPath (Join-Path $root 'calls.log') | Where-Object { $_ -eq 'record/stop' }).Count
    Assert-Test (-not $foreignStop.ok -and $beforeCleanup -eq $afterCleanup) 'foreign recording is never stopped'

    $testSession = Start-FixtureSession 'screenshot-failed' 'sequence'
    $env:CAPTURE_INTERACTION_SCENARIO = 'screenshot-failed'
    $failedFrame = & $entry observe -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $failedFrame.ok -and $failedFrame.data.observation.screenshot.receipt.state -eq 'failed_partial') 'terminal screenshot failure remains visible alongside retained partial images'
    $failedStop = & $entry stop -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $failedStop.ok -and $failedStop.data.screenshot.terminalReceipt.state -eq 'failed_partial') 'finalization preserves failed screenshot outcomes'

    $testSession = Start-FixtureSession 'manifest-source' 'sequence'
    $fakeState = Get-Content -LiteralPath (Join-Path $root 'fake-state.json') -Raw | ConvertFrom-Json -Depth 80
    $manifest = Get-Content -LiteralPath $fakeState.manifestPath -Raw | ConvertFrom-Json -Depth 80
    $manifest.children[0].actual.acquisition.sourceKind = 'desktop_mirror'
    $manifest | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $fakeState.manifestPath -Encoding utf8
    $badSource = & $entry observe -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $badSource.ok -and -not $badSource.data.observation.frameSubmission -and $badSource.data.observation.screenshot.receipt.observedManifest) 'a manifest source mismatch preserves diagnostics and refuses frame submission'
    $null = & $entry stop -SessionPath $testSession.statePath -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit

    Remove-Item -LiteralPath (Join-Path $root 'fake-state.json')
    $oversized = & $entry start -SessionDirectory (Join-Path $root 'oversized') -RuntimePath $runtime -VisualMode sequence -MaximumFrames 10000 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $oversized.ok -and $oversized.errors[0] -match 'budget') 'impossible sequence coverage is rejected before recording starts'
    $env:CAPTURE_INTERACTION_SCENARIO = 'old-record-schema'
    $oldHost = & $entry start -SessionDirectory (Join-Path $root 'old-host') -RuntimePath $runtime -VisualMode none -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $oldHost.ok -and $oldHost.errors[0] -match 'expectedCorrelationId') 'old runtimes that ignore ownership guards are rejected by the advertised schema'
    Remove-Item Env:CAPTURE_INTERACTION_SCENARIO

    $env:CAPTURE_INTERACTION_FAIL_VISUAL_START = '1'
    $env:CAPTURE_INTERACTION_FAIL_CLEANUP = '1'
    $failedVisualSession = Join-Path $root 'failed-visual-session'
    $failedVisual = & $entry start -SessionDirectory $failedVisualSession -RuntimePath $runtime -VisualMode sequence -MaximumFrames 10 -FrameIntervalMs 500 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $failedVisual.ok -and $failedVisual.state -eq 'cleanup-uncertain' -and $failedVisual.data.sessionId -and $failedVisual.data.recordAccepted -and $failedVisual.data.cleanup.errors.Count -eq 1) 'visual-start failure returns recording identity and truthful uncertain cleanup evidence'
    Remove-Item Env:CAPTURE_INTERACTION_FAIL_VISUAL_START -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root 'fake-state.json')

    $failedStateSession = Join-Path $root 'failed-state-session'
    $env:CAPTURE_INTERACTION_BREAK_SESSION_DIRECTORY = $failedStateSession
    $failedState = & $entry start -SessionDirectory $failedStateSession -RuntimePath $runtime -VisualMode sequence -MaximumFrames 10 -FrameIntervalMs 500 -DevBenchScriptPath $fake -SkipRuntimeIdentityVerification -Compact -NoExit | ConvertFrom-Json -Depth 100
    Assert-Test (-not $failedState.ok -and $failedState.state -eq 'cleanup-uncertain' -and $failedState.data.screenshotRequestId -eq 'req-1' -and $failedState.data.cleanup.errors.Count -ge 2) 'state-persistence failure returns screenshot and recording recovery identities when cleanup also fails'

    [pscustomobject]@{ ok=$true; sessionPath=$started.data.statePath; actionCount=(Get-CaptureInteractionActionCatalog).actions.Count } | ConvertTo-Json -Compress
}
finally {
    Remove-Item Env:CAPTURE_INTERACTION_FAKE_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:CAPTURE_INTERACTION_FAIL_VISUAL_START -ErrorAction SilentlyContinue
    Remove-Item Env:CAPTURE_INTERACTION_FAIL_CLEANUP -ErrorAction SilentlyContinue
    Remove-Item Env:CAPTURE_INTERACTION_BREAK_SESSION_DIRECTORY -ErrorAction SilentlyContinue
    Remove-Item Env:CAPTURE_INTERACTION_SESSION_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:CAPTURE_INTERACTION_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:CAPTURE_INTERACTION_EXPECTED_IDENTITY -ErrorAction SilentlyContinue
    $resolvedCleanup = [IO.Path]::GetFullPath($root)
    if ($resolvedCleanup -ne $fixtureRoot -or -not ([IO.Path]::GetFileName($resolvedCleanup)).StartsWith('capture-interaction-test-')) { throw 'Fixture cleanup target changed.' }
    if (Test-Path -LiteralPath $resolvedCleanup) { Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force }
}
