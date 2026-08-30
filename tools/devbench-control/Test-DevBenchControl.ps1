# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevBenchControl.psm1') -Force
$passes = [Collections.Generic.List[string]]::new()
$failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) { if ($Condition) { $passes.Add($Message) } else { $failures.Add($Message) } }

$success = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ status = [pscustomobject]@{ name = 'success'; value = 0 } })
Assert-Test ($success.known -and $success.ok) 'semantic status recognizes a successful API payload'
$conflict = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ status = [pscustomobject]@{ name = 'idempotency_conflict'; value = 12 } })
Assert-Test ($conflict.known -and -not $conflict.ok) 'semantic status rejects a non-success API payload'
$scenario = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ ok = $false; aborted = $true })
Assert-Test ($scenario.known -and -not $scenario.ok -and $scenario.reasons.Count -eq 2) 'semantic status preserves scenario failure reasons'
$producerMismatch = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch'; message = 'wrong build' } })
Assert-Test ($producerMismatch.known -and -not $producerMismatch.ok -and $producerMismatch.guarded -and $producerMismatch.outcome -eq 'guard-rejected') 'producer mismatch is a known guarded rejection'
$transient = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ result = [pscustomobject]@{ state = 'service_unavailable' } })
Assert-Test ($transient.transient -and $transient.states -contains 'service_unavailable') 'transient service state is classified recursively'
$unknown = Get-DevBenchSemanticStatus -Content @([pscustomobject]@{ playerLoaded = $true })
Assert-Test (-not $unknown.known -and $unknown.ok) 'unclassified content remains transport-successful'

$neutralPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $false })
Assert-Test ($neutralPerformance.known -and $neutralPerformance.neutral) 'disarmed standalone probe permits performance measurement'
$distortedPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ performanceDistorted = $true })
Assert-Test ($distortedPerformance.known -and -not $distortedPerformance.neutral -and $distortedPerformance.reason -eq 'intrusive-temporal-probe-armed') 'armed standalone probe rejects performance measurement'
$unknownPerformance = Test-DevBenchPerformanceNeutral -Content @(
    [pscustomobject]@{ stateCode = 2 })
Assert-Test (-not $unknownPerformance.known -and -not $unknownPerformance.neutral) 'registered legacy probe without distortion state fails closed'

$ready = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'ready' } })
Assert-Test ($ready.ready -and -not $ready.retryable -and $ready.statePath -eq 'content.result.state') 'service readiness prefers result.state'
$waiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ ok = $true; result = [pscustomobject]@{ state = 'compiling' } })
Assert-Test (-not $waiting.ready -and $waiting.retryable -and -not $waiting.terminalFailure) 'compiling service remains retryable'
$dispatchWaiting = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'main_thread_dispatch_failed'; retryable = $true } })
Assert-Test (-not $dispatchWaiting.ready -and $dispatchWaiting.retryable -and -not $dispatchWaiting.terminalFailure) 'explicitly retryable dispatch failure remains retryable'
$guarded = Test-DevBenchServiceReady -Content @([pscustomobject]@{ error = [pscustomobject]@{ code = 'producer_mismatch' } })
Assert-Test (-not $guarded.ready -and $guarded.terminalFailure) 'guard rejection terminates readiness wait'

$hudOnly = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $false })
Assert-Test $hudOnly.satisfied 'HUD-only menu state is non-blocking'
$inventory = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu'); messageBoxOpen = $false })
Assert-Test (-not $inventory.satisfied -and $inventory.blockingMenus[0] -eq 'InventoryMenu') 'non-HUD menus remain blocking'
$modal = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu'); messageBoxOpen = $true })
Assert-Test (-not $modal.satisfied) 'message boxes remain blocking'
$inventoryDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory -DismissBlockingMenus @('InventoryMenu')
Assert-Test ($inventoryDismissal.permitted -and $inventoryDismissal.dismissMenus[0] -eq 'InventoryMenu') 'explicitly listed blocking menu permits bounded dismissal'
$unlistedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $inventory
Assert-Test (-not $unlistedDismissal.permitted -and $unlistedDismissal.reason -eq 'unlisted-blocking-menu') 'menu dismissal remains opt-in'
$mixedMenus = Test-DevBenchNoBlockingMenu -MenuState ([pscustomobject]@{ openMenus = @('HUD Menu', 'InventoryMenu', 'MapMenu'); messageBoxOpen = $false })
$mixedDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $mixedMenus -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $mixedDismissal.permitted -and $mixedDismissal.retainedMenus[0] -eq 'MapMenu') 'unlisted blocking menus prevent partial dismissal'
$modalDismissal = Get-DevBenchMenuDismissalPlan -MenuObservation $modal -DismissBlockingMenus @('InventoryMenu')
Assert-Test (-not $modalDismissal.permitted -and $modalDismissal.reason -eq 'message-box-requires-explicit-answer') 'message boxes are never auto-dismissed'

$expectations = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921; pid = 123; exe = 'SkyrimVR.exe'; buildId = 'build-1'; dllPath = 'C:\Test\CommunityShaders.dll'; artifactSha256 = 'ABC' })
Assert-Test ($expectations.port -eq 8921 -and $expectations.pid -eq 123 -and $expectations.exe -eq 'SkyrimVR.exe') 'runtime expectations preserve process identity fields'
Assert-Test ($expectations.buildId -eq 'build-1' -and $expectations.artifactPath -like '*CommunityShaders.dll' -and $expectations.artifactSha256 -eq 'ABC') 'runtime expectations preserve build and deployed artifact identity'
$legacy = Get-DevBenchRuntimeExpectations -Runtime ([pscustomobject]@{ port = 8921 })
Assert-Test ($null -eq $legacy.pid -and $null -eq $legacy.exe) 'legacy port-only runtime metadata remains supported'

$entryPointText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-DevBenchControl.ps1') -Raw
Assert-Test ($entryPointText -notmatch '(?im)^\s*\$pid\s*=') 'entry point never assigns PowerShell reserved PID variable'
Assert-Test ($entryPointText -match '\$expectations\.buildId\s+-and\s+\$actualBuildId\s+-and') 'deferred build identity never compares a missing runtime build ID'
Assert-Test ($entryPointText -match '\$Command -eq ''wait'' -and \$statusCode -eq 404') 'transient MCP 404 recovery is restricted to bounded waits'
Assert-Test ($entryPointText -match 'mcp-session-reinitialized') 'bounded waits reinitialize invalidated MCP sessions'
Assert-Test ($entryPointText -match '\(\$RequireSuccess -or \$RequirePerformanceNeutral -or \$Command -eq ''wait''\)') 'unsatisfied waits fail even without RequireSuccess'
Assert-Test ($entryPointText -match '\[string\]\$EvidenceLabel') 'runtime binding evidence accepts an explicit invocation label'
Assert-Test ($entryPointText -match 'devbench-runtime-binding\.\$safeLabel\.\$stamp\.\$PID\.json') 'parallel runtime bindings use invocation-unique filenames'
Assert-Test ($entryPointText -match 'function Test-WaitRetryableException') 'bounded waits classify exhausted transient probe failures'
Assert-Test ($entryPointText -match "state = 'transport_retry'") 'serviceReady carries transient probe exhaustion into the outer wait'
Assert-Test ($entryPointText -match 'probeError = \$_.Exception.Message') 'wait observations preserve the transient probe error'
Assert-Test ($entryPointText -match '\[string\[\]\]\$DismissBlockingMenus') 'menu recovery requires an explicit menu allowlist'
Assert-Test ($entryPointText -match 'action = ''close''; name = \$menuName') 'menu recovery uses the registered menu close action'
Assert-Test ($entryPointText -match '\[int\]\$MinimumMenuStableSeconds') 'menu recovery can require a continuous stable window'
Assert-Test ($entryPointText -match '\$menuStableSinceUtc = \$null') 'a blocking observation resets menu stabilization'
Assert-Test ($entryPointText -match '\[switch\]\$RequirePerformanceNeutral') 'performance calls expose an explicit fail-closed guard'
Assert-Test ($entryPointText -match "'skyrimvrupscaler\.temporalProbe'") 'performance guard queries the standalone probe owner'
Assert-Test ($entryPointText -match 'toolCallSkipped = \$true') 'distorted performance guard skips the requested tool call'

[pscustomobject][ordered]@{ ok = $failures.Count -eq 0; passed = $passes.Count; failed = $failures.Count; passes = @($passes); failures = @($failures) } | ConvertTo-Json -Depth 10
if ($failures.Count -gt 0) { exit 1 }
