param(
    [Parameter(Mandatory)][string]$RunDirectory,
    [switch]$LegacyRc166,
    [switch]$ResumeSecond,
    [int]$FirstSaveNumber = -1,
    [int[]]$SaveNumbers,
    [string]$SaveNumberText,
    [Parameter(Mandatory)][string]$FpsVrCmd,
    [string]$Controller = (Join-Path $PSScriptRoot '../../devbench-control/Invoke-DevBenchControl.ps1'),
    [int]$DevBenchPort = 8921,
    [switch]$SkipFpsVrControl
)
$ErrorActionPreference = 'Stop'
if ($LegacyRc166) { Import-Module (Join-Path $PSScriptRoot '../LegacyRc166.psm1') -Force }
$fpsVrCsvDirectory = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'fpsVR\CSV'
$journal = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$sessionId = $null
$fpsVrStarted = $false
$fpsVrWasAlreadyRecording = $false
function Format-SaveNumber([int]$SaveNumber) {
    return $SaveNumber.ToString('00', [Globalization.CultureInfo]::InvariantCulture)
}
function Convert-SaveNumberText([string]$Text) {
    $numbers = @()
    foreach ($part in ($Text -split ',')) {
        $trimmed = $part.Trim()
        if (!$trimmed) { continue }
        if ($trimmed -notmatch '^\d+$') { throw "Invalid save number '$trimmed'. Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12." }
        $numbers += [int]::Parse($trimmed, [Globalization.CultureInfo]::InvariantCulture)
    }
    return [int[]]$numbers
}
function Get-SaveNumberFromEntry($SaveEntry) {
    if ($SaveEntry.meta -and $SaveEntry.meta.saveNumber -ne $null -and $SaveEntry.meta.saveType -eq 'save') {
        return [int]$SaveEntry.meta.saveNumber
    }
    if ($SaveEntry.name -match '^Save(\d+)_') {
        return [int]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}
function Mark([string]$Label, $Detail) {
    $entry = [ordered]@{label=$Label;utc=[DateTime]::UtcNow.ToString('o');elapsedSeconds=$clock.Elapsed.TotalSeconds;qpc=[Diagnostics.Stopwatch]::GetTimestamp();qpcFrequency=[Diagnostics.Stopwatch]::Frequency;detail=$Detail}
    $journal.Add($entry)
    $entry | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath "$RunDirectory\markers.jsonl"
}
function Call([string]$Label,[string]$Tool,[hashtable]$Arguments,[switch]$Neutral) {
    $argsJson = $Arguments | ConvertTo-Json -Depth 15 -Compress
    Mark "$Label-request" $Arguments
    $raw = & $controller call -RuntimePath "$RunDirectory\runtime.json" -SkipRuntimeIdentityVerification -AllowUnprovenGameMutation -EvidenceDirectory $RunDirectory -EvidenceLabel $Label -Tool $Tool -ArgumentsJson $argsJson -RequirePerformanceNeutral:$Neutral -TimeoutSeconds 8 -RequestTimeoutSeconds 3 -MaxTransientRetries 0 -NoExit -Compact
    $raw | Set-Content -LiteralPath "$RunDirectory\$Label.json"
    $response = $raw | ConvertFrom-Json
    Mark "$Label-response" @{transportOk=$response.transportOk;semantic=$response.semantic;errors=$response.errors}
    if (!$response.transportOk -or $response.data.rawResult.isError) { throw "$Label failed: $($response.errors)" }
    $payload = @($response.data.content)[0]
    if ($payload.error -or $payload.errorCode) { throw "$Label returned an error: $($payload | ConvertTo-Json -Compress -Depth 4)" }
    return $payload
}
function Ensure-RuntimeMetadata {
    $runtimePath = "$RunDirectory\runtime.json"
    if (Test-Path -LiteralPath $runtimePath) { return }
    $skyrim = Get-Process SkyrimVR -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$skyrim) { throw 'SkyrimVR process is not running; cannot create DevBench runtime metadata.' }
    [pscustomobject]@{
        port = $DevBenchPort
        pid = $skyrim.Id
        exe = 'SkyrimVR.exe'
    } | ConvertTo-Json | Set-Content -LiteralPath $runtimePath -Encoding UTF8
    Mark 'runtime-metadata-created' @{path=$runtimePath;port=$DevBenchPort;pid=$skyrim.Id;exe='SkyrimVR.exe'}
}
function Invoke-FpsVrToggle([string]$Label) {
    if ($SkipFpsVrControl) { Mark "$Label-skipped" @{reason='SkipFpsVrControl'}; return }
    if (!(Test-Path -LiteralPath $FpsVrCmd)) { throw "fpsVR command not found: $FpsVrCmd" }
    Mark "$Label-request" @{command=$FpsVrCmd;argument='logging_startstop'}
    $output = & $FpsVrCmd logging_startstop 2>&1
    Mark "$Label-response" @{exitCode=$LASTEXITCODE;output=($output -join "`n")}
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
    if (($output -join "`n") -match "Can't connect to fpsVR") {
        throw "$Label could not connect to the SteamVR-attached fpsVR logger; aborting without fallback."
    }
}
function Get-LatestFpsVrRawFile {
    if (!(Test-Path -LiteralPath $fpsVrCsvDirectory)) { return $null }
    return Get-ChildItem -LiteralPath $fpsVrCsvDirectory -Filter 'Frametimes#Raw#*.csv' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}
function Test-FpsVrRawRecordingActive {
    $file = Get-LatestFpsVrRawFile
    if (!$file) { return $false }
    $firstLength = $file.Length
    $firstWrite = $file.LastWriteTimeUtc
    Start-Sleep -Milliseconds 600
    $again = Get-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    return ($again -and ($again.Length -gt $firstLength -or $again.LastWriteTimeUtc -gt $firstWrite))
}
function Wait-FpsVrRawRecordingActive([double]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-FpsVrRawRecordingActive) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Start-FpsVrRawLogging {
    if ($SkipFpsVrControl) { Mark 'fpsvr-start-skipped' @{reason='SkipFpsVrControl'}; return }
    if (Wait-FpsVrRawRecordingActive 2.0) {
        $script:fpsVrWasAlreadyRecording = $true
        $active = Get-LatestFpsVrRawFile
        Mark 'fpsvr-already-recording' @{path=$active.FullName;length=$active.Length}
        return
    }
    Invoke-FpsVrToggle 'fpsvr-start'
    if (!(Wait-FpsVrRawRecordingActive 8.0)) { throw 'fpsVR raw logging did not begin growing after start.' }
    $script:fpsVrStarted = $true
    $active = Get-LatestFpsVrRawFile
    Mark 'fpsvr-recording-confirmed' @{path=$active.FullName;length=$active.Length}
}
function Stop-OwnedFpsVrRawLogging {
    if ($fpsVrStarted -and !$fpsVrWasAlreadyRecording) { Invoke-FpsVrToggle 'fpsvr-stop' }
}
try {
    if ($SaveNumberText) { $SaveNumbers = Convert-SaveNumberText $SaveNumberText }
    if ((!$SaveNumbers -or $SaveNumbers.Count -eq 0) -and $FirstSaveNumber -ge 0) { $SaveNumbers = @($FirstSaveNumber) }
    if (!$SaveNumbers -or $SaveNumbers.Count -eq 0) {
        throw 'Save numbers are required. Ask: Which save numbers should I load? Give comma-separated numbers, for example 05 or 05, 07 or 05, 07, 12.'
    }
    $displaySaveNumbers = @($SaveNumbers | ForEach-Object { Format-SaveNumber $_ })
    Mark 'policy' @{protocol='game-ft';provenance='deferred until after all holds by user instruction';savePolicy="explicit user authorization for save numbers: $($displaySaveNumbers -join ', ')";worldEntryBoundary='first observed completed world frame after a fresh loading serial; polling uncertainty retained';timerSeconds=60;tailSeconds=10;healthAcceptance='terminal completed generation and hard terminal gates; superseded metrics are retained as evidence'}
    Ensure-RuntimeMetadata
    if (!(Test-Path -LiteralPath "$RunDirectory\save-selection.json")) {
        [void](Call 'save-selection' 'game' @{action='list'})
    }
    if (!(Test-Path -LiteralPath "$RunDirectory\main-menu-health.json")) {
        [void](Call 'main-menu-health' 'communityshaders.renderscale' @{action='status'} -Neutral)
    }
    Start-FpsVrRawLogging
    $selection = (Get-Content -LiteralPath "$RunDirectory\save-selection.json" -Raw | ConvertFrom-Json).data.content[0]
    $selectedSaves = @()
    foreach ($saveNumber in $SaveNumbers) {
        $matches = @($selection.saves | Where-Object { (Get-SaveNumberFromEntry $_) -eq $saveNumber })
        if ($matches.Count -ne 1) { throw "Save $(Format-SaveNumber $saveNumber) is not unique." }
        $selectedSaves += $matches[0]
    }
    $beforePath = if ($ResumeSecond) { "$RunDirectory\save-1-retained-health.json" } else { "$RunDirectory\main-menu-health.json" }
    $before = (Get-Content -LiteralPath $beforePath -Raw | ConvertFrom-Json).data.content[0].status
    if ($before.session.active) { throw 'An unrelated stress session is active.' }
    $ordinal = if ($ResumeSecond) { 1 } else { 0 }
    $targets = if ($ResumeSecond) { @($selectedSaves | Select-Object -Skip 1) } else { $selectedSaves }
    foreach ($save in $targets) {
        $ordinal++
        $label = "save-$ordinal"
        $startLabel = "$label-health-start"
        $started = if ($LegacyRc166) { Call "$label-legacy-health-start" 'communityshaders.renderscale' @{action='status'} -Neutral }
            else { Call $startLabel 'communityshaders.renderscale' @{action='start'} -Neutral }
        if (!$LegacyRc166 -and !$started.status.session.active) { throw "$label health recorder did not become active." }
        if (!$LegacyRc166) { $sessionId = $started.status.session.id }
        $before = $started.status
        $oldSerial = $before.vendorWorkGate.stabilizerSync.loadingSerial
        if ($LegacyRc166) {
            $loadState = Call "$label-legacy-before-load" 'inspect' @{kind='state'}
            $legacyProcessId = (Get-Content -LiteralPath "$RunDirectory/runtime.json" -Raw | ConvertFrom-Json).pid
            $legacyPreviousFrame = $loadState.frame
            $freshLegacyLoad = $false
        }
        Mark "$label-load-boundary" @{name=$save.name;location=$save.meta.location;oldLoadingSerial=$oldSerial}
        Write-Output "Loading $($save.name)"
        $loaded = Call "$label-load" 'game' @{action='load';name=$save.name;dir=$selection.dir}
        $loadDeadline = $clock.Elapsed.TotalSeconds + 120
        $poll = 0
        $lastNotWorld = $clock.Elapsed.TotalSeconds
        do {
            if ($clock.Elapsed.TotalSeconds -ge $loadDeadline) { throw "$label did not reach an observed world frame within 120 seconds." }
            $poll++
            try {
                if ($LegacyRc166) {
                    $menus = Call "$label-legacy-menu-$poll" 'menu' @{action='list'}
                    if (@($menus.openMenus | Where-Object { $_ -in @('Loading Menu','LoadingMenu') }).Count) { $freshLegacyLoad = $true }
                    $loadState = Call "$label-legacy-entry-$poll" 'inspect' @{kind='state'}
                    if ($loadState.playerLoaded -is [bool] -and !$loadState.playerLoaded) { $freshLegacyLoad = $true }
                    $world = Test-LegacyRc166LoadBoundary $loadState $menus $legacyProcessId $legacyPreviousFrame $freshLegacyLoad
                } else { $observation = Call "$label-entry-$poll" 'communityshaders.renderscale' @{action='status'} }
            }
            catch {
                if ($_.Exception.Message -notmatch 'Timeout|timed.out|was canceled|main_thread_busy|main_thread_in_progress|main_thread_timeout') { throw }
                Mark "$label-loading-transient" @{message=$_.Exception.Message}
                $world=$false
                Start-Sleep -Milliseconds 200
                continue
            }
            if (!$LegacyRc166) {
                $gate = $observation.status.vendorWorkGate
                $fresh = $gate.stabilizerSync.loadingSerial -gt $oldSerial
                $world = $fresh -and !$gate.mainMenu -and !$gate.loadingMenu -and $gate.completedWorldFrame
            }
            if (!$world) { $lastNotWorld=$clock.Elapsed.TotalSeconds; Start-Sleep -Milliseconds 200 }
        } until ($world)
        $origin = $clock.Elapsed.TotalSeconds
        if ($LegacyRc166) {
            Mark "$label-world-entry" @{name=$save.name;frame=$loadState.frame;lastNotWorldElapsedSeconds=$lastNotWorld;observationElapsedSeconds=$origin;boundaryExact=$false;boundarySource='legacy_player_loaded_menu_clear';completedWorldFrameVerified=$false}
        } else { Mark "$label-world-entry" @{name=$save.name;frame=$observation.status.frame;loadingSerial=$gate.stabilizerSync.loadingSerial;lastNotWorldElapsedSeconds=$lastNotWorld;observationElapsedSeconds=$origin;stabilizerSync=$gate.stabilizerSync;boundaryExact=$false} }
        Write-Output "$label world observed; 60-second hold started."
        foreach ($sample in @(1,5,20,49,59)) {
            while ($clock.Elapsed.TotalSeconds -lt $origin+$sample) { Start-Sleep -Milliseconds 100 }
            $observation = if ($LegacyRc166) { Call "$label-legacy-health-$sample" 'communityshaders.renderscale' @{action='status'} }
                else { Call "$label-health-$sample" 'communityshaders.renderscale' @{action='record'} }
            $before = $observation.status
        }
        while ($clock.Elapsed.TotalSeconds -lt $origin+60) { Start-Sleep -Milliseconds 50 }
        Mark "$label-hold-end" @{name=$save.name;originElapsedSeconds=$origin;durationSeconds=$clock.Elapsed.TotalSeconds-$origin}
        Write-Output "$label 60-second hold complete."
        if ($LegacyRc166) {
            $stopped = Call "$label-legacy-health-stop" 'communityshaders.renderscale' @{action='status'} -Neutral
            Mark "$label-legacy-health-unavailable" @{strictLifecycle='not exposed by this build';statusFrame=$stopped.status.frame}
        } else {
            $stopped = Call "$label-health-stop" 'communityshaders.renderscale' @{action='stop';expectedSessionId=$sessionId} -Neutral
            Mark "$label-health-recorder-stopped" @{sessionId=$sessionId;statusFrame=$stopped.status.frame}
        }
        $sessionId = $null
        $before = $stopped.status
    }
    Mark 'requested-holds-complete' @{saveNumbers=$displaySaveNumbers}
} catch {
    Mark 'run-error' @{message=$_.Exception.Message}
    Write-Output "MEASUREMENT ERROR: $($_.Exception.Message)"
} finally {
    if ($sessionId) {
        try { $stopped = Call 'health-stop' 'communityshaders.renderscale' @{action='stop';expectedSessionId=$sessionId} -Neutral; Mark 'health-recorder-stopped' @{sessionId=$sessionId} }
        catch { Mark 'health-cleanup-error' @{sessionId=$sessionId;message=$_.Exception.Message}; Write-Output "Health cleanup needs inspection: $($_.Exception.Message)" }
    }
    if ($fpsVrStarted) {
        try { Stop-OwnedFpsVrRawLogging }
        catch { Mark 'fpsvr-stop-error' @{message=$_.Exception.Message}; Write-Output "fpsVR stop needs inspection: $($_.Exception.Message)" }
    }
    $journalName = if ($ResumeSecond) { 'resume-journal.json' } else { 'run-journal.json' }
    $journal | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath "$RunDirectory\$journalName"
    Write-Output "CAPTURE CONTROL COMPLETE: $RunDirectory"
}
