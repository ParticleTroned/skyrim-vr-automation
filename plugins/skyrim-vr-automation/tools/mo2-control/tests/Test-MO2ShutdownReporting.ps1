# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('mo2-shutdown-reporting-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MO2Control.psm1') -Force
$module = Get-Module MO2Control
try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    & $module {
        param($Fixture)
        $script:testRoot = $Fixture
        $script:testClosed = $false
        $script:testGameRemains = $false
        $script:testCloseCalls = 0
        $script:testAccess = $null

        # Replace process/desktop boundaries; production handlers and timestamp
        # persistence operate only on this test's temporary session files.
        function Get-MO2InspectionData {
            param($Config, $RequestedProfile, $RequestedExecutable)
            [pscustomobject]@{
                processes = [pscustomobject]@{
                    mo2 = @($(if (-not $script:testClosed -or $script:testCloseCalls -eq 0) { [pscustomobject]@{ id = 1234 } }))
                    game = @($(if ($script:testGameRemains) { [pscustomobject]@{ id = 5678 } }))
                }
                sessionLock = [pscustomobject]@{ exists = $true }
                requested = [pscustomobject]@{ profile = 'Fixture'; executable = 'Fixture' }
                config = [pscustomobject]@{ mo2Executable = (Join-Path $script:testRoot 'MO2.exe') }
            }
        }
        function Get-MO2OwnedSession {
            param($Config, $SessionId)
            [pscustomobject]@{ path = $Config.session.lockFile; data = (Get-Content -LiteralPath $Config.session.lockFile -Raw | ConvertFrom-Json) }
        }
        function Get-MO2OwnedAccessLease { param($Config, $AccessId) $script:testAccess }
        function Resolve-MO2OwnedProcessTarget {
            param($Config, $Owned, $Processes, [switch]$AdoptDetachedOwner)
            [pscustomobject]@{ ok = $true; ownerPid = 1234; targets = @($Processes) }
        }
        function Test-MO2InteractiveDesktop { $true }
        function Assert-MO2ExactProcessTargets { param($Config, $Processes) }
        function Get-MO2WindowSnapshot { param($Processes) }
        function Get-Process { param($Id, $ErrorAction) $null }
        function Invoke-MO2CooperativeClose {
            param($Config, $InitialProcesses, $EvidenceDirectory, $TimeoutSeconds)
            $script:testCloseCalls++
            [pscustomobject]@{ closed = $script:testClosed }
        }
        function New-MO2DurableSessionController {
            param($Config, $SessionPath, [switch]$WhatIf)
            [pscustomobject]@{ controllerPath = (Join-Path $SessionPath 'controller.ps1'); configPath = (Join-Path $SessionPath 'config.json'); receiptPath = (Join-Path $SessionPath 'controller.json') }
        }
        function Write-MO2OwnedSessionAtomic {
            param($Owned, $Value)
            Write-MO2JsonAtomic -Path $Owned.path -Value $Value
        }
        function New-MO2ActionResult {
            param($Config, $Command, $Ok, $State, $Data, $Errors)
            [pscustomobject]@{ ok = $Ok; state = $State; data = $Data; errors = $Errors }
        }

        $config = [pscustomobject]@{
            storage = [pscustomobject]@{ sessionStaging = $Fixture }
            session = [pscustomobject]@{ lockFile = (Join-Path $Fixture 'lock.json') }
            mo2 = [pscustomobject]@{ profilesDirectory = $Fixture }
        }
        $assertions = 0
        foreach ($command in @('close', 'recover-close', 'stop')) {
            foreach ($completed in @($false, $true)) {
                $script:testClosed = $completed
                $script:testCloseCalls = 0
                $sessionPath = Join-Path $Fixture ($command + '-' + $completed)
                New-Item -ItemType Directory -Path $sessionPath | Out-Null
                $session = [pscustomobject]@{ status = 'mo2-open'; sessionId = 'fixture'; sessionPath = $sessionPath; profile = 'Fixture'; executable = 'Fixture'; ownerPid = 1234 }
                Write-MO2JsonAtomic -Path (Join-Path $sessionPath 'session.json') -Value $session
                Write-MO2JsonAtomic -Path $config.session.lockFile -Value $session
                if ($command -eq 'recover-close') {
                    $script:testAccess = [pscustomobject]@{ sessionId = $null; data = [pscustomobject]@{ runtimeRoute = (Resolve-MO2RuntimeRouteContract -RuntimeRoute SteamVRNull); generation = 1L } }
                    $result = Invoke-MO2RecoverClose -Config $config -AccessId 'fixture-access' -TimeoutSeconds 1
                }
                elseif ($command -eq 'stop') { $result = Invoke-MO2Stop -Config $config -SessionId fixture -TimeoutSeconds 1 }
                else { $result = Invoke-MO2Close -Config $config -SessionId fixture -TimeoutSeconds 1 }
                $expectedState = if ($command -eq 'stop') { if ($completed) { 'stopped' } else { 'stop-incomplete' } } else { if ($completed) { 'mo2-closed' } else { 'close-incomplete' } }
                $completionProperty = if ($command -eq 'stop') { 'stoppedUtc' } else { 'closedUtc' }
                $attemptProperty = if ($command -eq 'stop') { 'stopAttemptedUtc' } else { 'closeAttemptedUtc' }
                $expectedProperty = if ($completed) { $completionProperty } else { $attemptProperty }
                $absentProperty = if ($completed) { $attemptProperty } else { $completionProperty }
                $lock = Get-Content -LiteralPath $config.session.lockFile -Raw | ConvertFrom-Json
                $manifest = Get-Content -LiteralPath (Join-Path $lock.sessionPath 'session.json') -Raw | ConvertFrom-Json
                if ($result.ok -ne $completed -or $result.state -ne $expectedState -or $script:testCloseCalls -ne 1) { throw "$command returned the wrong shutdown outcome." }
                foreach ($record in @($lock, $manifest)) {
                    if ($record.status -ne $expectedState -or -not $record.PSObject.Properties[$expectedProperty] -or $record.PSObject.Properties[$absentProperty]) { throw "$command persisted a misleading timestamp (completed=$completed)." }
                    $null = [DateTimeOffset]::Parse($record.$expectedProperty)
                }
                if ($lock.$expectedProperty -cne $manifest.$expectedProperty) { throw "$command lock and session timestamps differ." }
                $assertions++
            }
        }

        $script:testClosed = $false
        $script:testGameRemains = $true
        $script:testCloseCalls = 0
        $previousStop = $lock.stoppedUtc
        $result = Invoke-MO2Stop -Config $config -SessionId fixture -TimeoutSeconds 1
        foreach ($path in @($config.session.lockFile, (Join-Path $lock.sessionPath 'session.json'))) {
            $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($record.status -ne 'game-stop-incomplete' -or -not $record.stopAttemptedUtc -or $record.stoppedUtc -cne $previousStop) { throw 'Failed game shutdown overwrote a historical completion or lost the attempt timestamp.' }
        }
        if ($result.ok -or $script:testCloseCalls -ne 0) { throw 'Failed game shutdown attempted MO2 close.' }
        $assertions++

        $publicLock = [pscustomobject]@{
            exists = $true; valid = $true; path = $config.session.lockFile; leaseId = 'public-lease'; sessionId = 'fixture'; status = 'close-incomplete'
            ownerPid = 1234; ownerRunning = $true; ownerIdentityMatched = $true; acquisitionMode = 'explicit-access'
            data = [pscustomobject]@{ accessId = 'private-credential'; sessionPath = $Fixture; controllerPath = (Join-Path $Fixture 'controller.ps1'); estimatedReleaseUtc = '2000-01-01T00:00:00Z' }
        }
        $summary = Get-MO2AccessLeaseSummary -Lock $publicLock
        if ($summary.state -ne 'session-held' -or $summary.sessionStatus -ne 'close-incomplete' -or $summary.ownerPid -ne 1234 -or
            -not $summary.ownerRunning -or -not $summary.ownerIdentityMatched -or -not $summary.estimateOverdue -or
            $summary.sessionPath -ne $Fixture -or $summary.controllerPath -ne $publicLock.data.controllerPath -or
            ($summary | ConvertTo-Json -Depth 10) -match 'private-credential|accessId') { throw 'Public lease diagnostics lost ownership evidence, exposed credentials or treated an overdue lease as available.' }
        $assertions++
        [pscustomobject]@{ ok = $true; assertions = $assertions; live = $false } | ConvertTo-Json
    } $fixture
}
finally {
    Remove-Module $module -Force
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedFixture) -notlike 'mo2-shutdown-reporting-*') { throw 'Refusing cleanup outside the shutdown test fixture.' }
    if (Test-Path -LiteralPath $resolvedFixture) { Remove-Item -LiteralPath $resolvedFixture -Recurse -Force }
}
