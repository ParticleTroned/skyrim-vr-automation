# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) {
    if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) }
}
function Copy-Fixture($Value) { $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20 }
$runtime = [pscustomobject]@{ plugin = 'devbench'; version = '1.22.0'; pid = 42; port = 8921; exe = 'SkyrimVR.exe'; frame = 100 }
$ledger = [pscustomobject]@{
    consumers = @([pscustomobject]@{ name = 'CommunityShaders'; atEpoch = 1; atFrame = 0 })
    registrations = @([pscustomobject]@{ name = 'ping'; kind = 'tool'; replaced = $false; atEpoch = 1; atFrame = 0 })
}
$absent = Get-DevBenchDirectPerformanceGuard -Runtime $runtime -Registrants $ledger
Assert-Test ($absent.neutral -and -not $absent.applicable -and $null -eq $absent.performanceEpoch) 'fresh absence is not applicable without inventing an epoch'
Assert-Test ($absent.physicalStateKnown -and $absent.reason -eq 'standalone-temporal-probe-not-registered') 'absence has an explicit qualified reason'
foreach ($bad in @($null, [pscustomobject]@{}, [pscustomobject]@{ consumers = @() },
    [pscustomobject]@{ consumers = @(); registrations = 'missing' },
    [pscustomobject]@{ consumers = @(); registrations = @([pscustomobject]@{ name = 'ping' }) })) {
    $guard = Get-DevBenchDirectPerformanceGuard -Runtime $runtime -Registrants $bad
    Assert-Test (-not $guard.neutral -and -not $guard.physicalStateKnown) 'missing or malformed ledger fails closed'
}
$truncated = Copy-Fixture $ledger
$truncated | Add-Member -NotePropertyName truncated -NotePropertyValue $true
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $truncated).neutral) 'truncated registration evidence is rejected'
$badRuntime = Copy-Fixture $runtime
$badRuntime.pid = '42'
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $badRuntime $ledger).neutral) 'string process identity is rejected'
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $null $ledger).neutral) 'missing runtime identity is rejected'
$ownerOnly = Copy-Fixture $ledger
$ownerOnly.consumers += [pscustomobject]@{ name = 'SkyrimVRUpscaler'; atEpoch = 1; atFrame = 0 }
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $ownerOnly).neutral) 'standalone owner without probe registration is unknown rather than absent'
$otherStandalone = Copy-Fixture $ledger
$otherStandalone.registrations += [pscustomobject]@{ name = 'skyrimvrupscaler.status'; kind = 'tool'; replaced = $false }
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $otherStandalone).neutral) 'other standalone registration prevents absent-owner inference'
$registered = Copy-Fixture $ledger
$registered.registrations += [pscustomobject]@{ name = 'skyrimvrupscaler.temporalProbe'; kind = 'tool'; replaced = $false; atEpoch = 1; atFrame = 0 }
$neutralStatus = [pscustomobject]@{ performanceDistorted = $false; physicalStateKnown = $true; performanceEpoch = 7 }
$neutral = Get-DevBenchDirectPerformanceGuard $runtime $registered -ProbeContent @($neutralStatus)
Assert-Test ($neutral.applicable -and $neutral.neutral -and $neutral.performanceEpoch -eq 7) 'registered neutral probe uses actual ownership evidence'
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $registered).neutral) 'registered but unavailable status never becomes not applicable'
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $registered -ProbeContent @([pscustomobject]@{ performanceDistorted = $false })).neutral) 'legacy probe fails closed'
$armed = Copy-Fixture $neutralStatus
$armed.performanceDistorted = $true
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $registered -ProbeContent @($armed)).neutral) 'armed probe fails closed'
$unknownPhysical = Copy-Fixture $neutralStatus
$unknownPhysical.physicalStateKnown = $false
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $registered -ProbeContent @($unknownPhysical)).neutral) 'unproven physical state fails closed'
$failedStatus = Copy-Fixture $neutralStatus
$failedStatus | Add-Member -NotePropertyName ok -NotePropertyValue $false
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $registered -ProbeContent @($failedStatus)).neutral) 'semantic failure cannot be overridden by nested neutral fields'
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $ledger -ProbeContent @($neutralStatus)).neutral) 'status without registration is inconsistent'
$replaced = Copy-Fixture $registered
$replaced.registrations[-1].replaced = $true
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $replaced -ProbeContent @($neutralStatus)).neutral) 'replaced ownership is not silently accepted'
$duplicate = Copy-Fixture $registered
$duplicate.registrations += $duplicate.registrations[-1]
Assert-Test (-not (Get-DevBenchDirectPerformanceGuard $runtime $duplicate -ProbeContent @($neutralStatus)).neutral) 'duplicate registrations fail closed'
$laterRuntime = Copy-Fixture $runtime
$laterRuntime.frame = 120
$laterAbsent = Get-DevBenchDirectPerformanceGuard $laterRuntime $ledger
Assert-Test ((Test-DevBenchPerformanceWindow $absent $laterAbsent).valid) 'stable absence permits the temporal-probe window'
Assert-Test (-not (Test-DevBenchPerformanceWindow $absent $neutral).valid) 'probe registration during a window invalidates it'
$newProcess = Copy-Fixture $runtime
$newProcess.pid = 43
Assert-Test (-not (Test-DevBenchPerformanceWindow $absent (Get-DevBenchDirectPerformanceGuard $newProcess $ledger)).valid) 'new process cannot reuse absent-probe evidence'
$oldFrame = Copy-Fixture $runtime
$oldFrame.frame = 90
Assert-Test (-not (Test-DevBenchPerformanceWindow $absent (Get-DevBenchDirectPerformanceGuard $oldFrame $ledger)).valid) 'frame rollback invalidates a direct window'
$laterLedger = Copy-Fixture $ledger
$laterLedger.registrations += [pscustomobject]@{ name = 'new.tool'; kind = 'tool'; replaced = $false }
Assert-Test (-not (Test-DevBenchPerformanceWindow $absent (Get-DevBenchDirectPerformanceGuard $laterRuntime $laterLedger)).valid) 'ledger changes force fresh qualification'
$laterNeutral = Get-DevBenchDirectPerformanceGuard $laterRuntime $registered -ProbeContent @($neutralStatus)
Assert-Test ((Test-DevBenchPerformanceWindow $neutral $laterNeutral).valid) 'unchanged registered ownership permits the window'
$newEpoch = Copy-Fixture $neutralStatus
$newEpoch.performanceEpoch = 8
Assert-Test (-not (Test-DevBenchPerformanceWindow $neutral (Get-DevBenchDirectPerformanceGuard $laterRuntime $registered -ProbeContent @($newEpoch))).valid) 'arm/disarm epoch drift invalidates a direct window'
$legacyGuard = [pscustomobject]@{ applicable = $false; neutral = $true; performanceEpoch = $null; reason = 'standalone-temporal-probe-not-registered' }
Assert-Test (-not (Test-DevBenchPerformanceWindow $absent $legacyGuard).valid) 'direct evidence cannot be mixed with a different transport guard'

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 10
if ($failures.Count -gt 0) { exit 1 }
