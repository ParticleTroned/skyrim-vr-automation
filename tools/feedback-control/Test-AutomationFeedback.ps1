# SPDX-License-Identifier: GPL-3.0-or-later

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('skyrim-vr-feedback-' + [guid]::NewGuid().ToString('N'))
$script = Join-Path $PSScriptRoot 'Invoke-AutomationFeedback.ps1'
$powerShell = (Get-Process -Id $PID).Path

function Invoke-Feedback([string[]]$Arguments) {
    $raw = & $powerShell -NoProfile -File $script @Arguments -FeedbackRoot $fixture -Compact 2>&1
    $exitCode = $LASTEXITCODE
    $json = ($raw -join "`n") | ConvertFrom-Json -Depth 50
    return [pscustomobject]@{ exitCode = $exitCode; result = $json; raw = $raw }
}

try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    $evidence = Join-Path $fixture 'private\evidence.txt'
    New-Item -ItemType Directory -Path (Split-Path -Parent $evidence) -Force | Out-Null
    [IO.File]::WriteAllText($evidence, 'durable evidence', [Text.UTF8Encoding]::new($false))

    $created = Invoke-Feedback @(
        'submit', '-Area', 'mo2', '-Kind', 'defect', '-Severity', 'high',
        '-Summary', 'Unlock dialog misclassified', '-Observed', "Observed at $evidence",
        '-Expected', 'Exact Unlock is selected.', '-Suggestion', 'Inspect button structure first.',
        '-Operation', 'mo2-control close', '-ParametersJson', '{"safe":true}',
        '-ReporterTaskId', 'task-one', '-SessionId', 'session-one', '-ProfilePath', 'C:\Private\Profile',
        '-EvidencePath', $evidence, '-Blocked'
    )
    if ($created.exitCode -ne 0 -or -not $created.result.ok -or $created.result.state -ne 'recorded') { throw 'Submit failed.' }
    $id = [string]$created.result.data.receipt
    if ($id -notmatch '^AUTO-\d{8}-\d{9}-[A-F0-9]{8}$') { throw "Unexpected receipt: $id" }
    $itemPath = Join-Path $fixture "items\$id.json"
    if (-not (Test-Path -LiteralPath $itemPath -PathType Leaf)) { throw 'Durable item was not written.' }
    if ($created.result.data.feedback.evidence[0].sha256 -ne (Get-FileHash -LiteralPath $evidence -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Evidence hash was not preserved.' }

    $read = Invoke-Feedback @('get', '-FeedbackId', $id)
    if ($read.result.data.feedback.status -ne 'new' -or -not $read.result.data.feedback.blocked) { throw 'Initial folded state is incorrect.' }

    $amended = Invoke-Feedback @('amend', '-FeedbackId', $id, '-Observed', 'Corrected observation.', '-BlockedState', 'false', '-Actor', 'task-one')
    if (-not $amended.result.ok -or $amended.result.data.feedback.observed -ne 'Corrected observation.' -or $amended.result.data.feedback.blocked) { throw 'Amend did not fold correctly.' }

    foreach ($transition in @(
        @('triage', '-FeedbackId', $id, '-Actor', 'maintainer', '-Note', 'Reproduced.'),
        @('accept', '-FeedbackId', $id, '-Actor', 'maintainer'),
        @('resolve', '-FeedbackId', $id, '-Actor', 'maintainer', '-Resolution', 'Fixed with regression coverage.', '-Commit', 'abc123', '-PullRequest', 'https://example.invalid/pr/1', '-Release', '0.7.0')
    )) {
        $changed = Invoke-Feedback $transition
        if (-not $changed.result.ok) { throw "Transition failed: $($transition[0])" }
    }
    $resolved = (Invoke-Feedback @('get', '-FeedbackId', $id)).result.data.feedback
    if ($resolved.status -ne 'resolved' -or $resolved.resolutionLinks.commit -ne 'abc123') { throw 'Resolution state is incomplete.' }

    $closedAmend = Invoke-Feedback @('amend', '-FeedbackId', $id, '-Observed', 'Must fail.')
    if ($closedAmend.exitCode -eq 0 -or $closedAmend.result.ok) { throw 'Terminal feedback accepted an amendment without reopen.' }
    $reopened = Invoke-Feedback @('reopen', '-FeedbackId', $id, '-Actor', 'maintainer')
    if (-not $reopened.result.ok -or $reopened.result.data.feedback.status -ne 'reopened') { throw 'Reopen failed.' }

    $possibleDuplicate = Invoke-Feedback @('submit', '-Area', 'mo2', '-Kind', 'defect', '-Summary', 'Unlock dialog misclassified', '-Observed', 'Second occurrence.', '-Expected', 'Exact Unlock is selected.', '-ReporterTaskId', 'task-two')
    if (-not $possibleDuplicate.result.ok -or @($possibleDuplicate.result.data.possibleDuplicates).Count -ne 1) { throw 'Duplicate fingerprint was not reported.' }
    $duplicateId = [string]$possibleDuplicate.result.data.receipt
    $duplicate = Invoke-Feedback @('duplicate', '-FeedbackId', $duplicateId, '-DuplicateOf', $id, '-Actor', 'maintainer')
    if (-not $duplicate.result.ok -or $duplicate.result.data.feedback.duplicateOf -ne $id) { throw 'Duplicate transition failed.' }

    $mine = Invoke-Feedback @('list-mine', '-ReporterTaskId', 'task-two')
    if (-not $mine.result.ok -or $mine.result.data.total -ne 1 -or $mine.result.data.feedback[0].feedbackId -ne $duplicateId) { throw 'list-mine filtering failed.' }
    $filtered = Invoke-Feedback @('list', '-Status', 'duplicate', '-AreaFilter', 'mo2', '-Limit', '10')
    if (-not $filtered.result.ok -or $filtered.result.data.total -ne 1) { throw 'Maintainer list filtering failed.' }

    $publicMarkdown = Join-Path $fixture 'exports\public.md'
    $exported = Invoke-Feedback @('export', '-FeedbackId', $id, '-Format', 'markdown', '-OutputPath', $publicMarkdown)
    if (-not $exported.result.ok -or -not (Test-Path -LiteralPath $publicMarkdown -PathType Leaf)) { throw 'Markdown export failed.' }
    $markdown = Get-Content -LiteralPath $publicMarkdown -Raw
    if ($markdown.Contains($evidence, [StringComparison]::OrdinalIgnoreCase) -or $markdown.Contains('C:\Private', [StringComparison]::OrdinalIgnoreCase)) { throw 'Default export leaked local paths.' }
    if ($markdown -notmatch 'Review this export before sharing') { throw 'Export omitted its review warning.' }

    $jobs = @()
    for ($i = 0; $i -lt 6; $i++) {
        $jobs += Start-Job -ScriptBlock {
            param($Pwsh, $Tool, $Root, $Index)
            & $Pwsh -NoProfile -File $Tool submit -FeedbackRoot $Root -Compact -Area process -Kind enhancement -Summary "Concurrent $Index" -Observed 'Observed.' -Expected 'Expected.' -ReporterTaskId "job-$Index"
        } -ArgumentList $powerShell, $script, $fixture, $i
    }
    $concurrent = @($jobs | Wait-Job | Receive-Job | ForEach-Object { $_ | ConvertFrom-Json -Depth 50 })
    $jobs | Remove-Job -Force
    if ($concurrent.Count -ne 6 -or @($concurrent | Where-Object { -not $_.ok }).Count -ne 0 -or @($concurrent.data.receipt | Sort-Object -Unique).Count -ne 6) { throw 'Concurrent submissions were not unique and successful.' }

    $all = Invoke-Feedback @('list', '-Limit', '100')
    if (-not $all.result.ok -or $all.result.data.total -ne 8) { throw 'Queue count after concurrent writes is incorrect.' }
    $tempNoise = Join-Path $fixture 'items\.interrupted.tmp'
    [IO.File]::WriteAllText($tempNoise, '{invalid')
    $afterNoise = Invoke-Feedback @('list', '-Limit', '100')
    if (-not $afterNoise.result.ok -or $afterNoise.result.data.total -ne 8) { throw 'Interrupted temporary file affected queue reads.' }

    $legacyConfig = Join-Path $fixture 'legacy-machine.local.json'
    [IO.File]::WriteAllText($legacyConfig, '{"storage":{"archive":"D:\\Archive"}}', [Text.UTF8Encoding]::new($false))
    $legacyRoot = Join-Path $fixture 'legacy-default'
    $previousOverride = $env:SKYRIM_VR_AUTOMATION_FEEDBACK_ROOT
    try {
        $env:SKYRIM_VR_AUTOMATION_FEEDBACK_ROOT = $legacyRoot
        $legacy = & $powerShell -NoProfile -File $script submit -ConfigPath $legacyConfig -Compact -Area doctor -Kind ambiguity -Summary 'Legacy configuration probe' -Observed 'No feedback field exists.' -Expected 'Fallback remains valid.' | ConvertFrom-Json -Depth 50
        if (-not $legacy.ok -or $legacy.data.storage.source -ne 'environment') { throw 'Legacy machine config without storage.feedback broke fallback resolution.' }
    }
    finally { $env:SKYRIM_VR_AUTOMATION_FEEDBACK_ROOT = $previousOverride }

    [pscustomobject]@{ ok = $true; feedbackRoot = $fixture; primaryReceipt = $id; records = $all.result.data.total } | ConvertTo-Json
}
finally {
    if (Get-Job -ErrorAction SilentlyContinue) { Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
