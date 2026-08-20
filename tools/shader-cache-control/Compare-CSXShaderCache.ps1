# SPDX-License-Identifier: GPL-3.0-or-later

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReferencePath,
    [Parameter(Mandatory)][string]$CandidatePath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ReferenceLabel = 'reference',
    [string]$CandidateLabel = 'candidate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Inventory([string]$Root) {
    $resolved = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Shader-cache root is not a directory: $resolved"
    }
    $items = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $resolved -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath($resolved, $file.FullName).Replace('/', '\')
        if ($items.ContainsKey($relative)) { throw "Duplicate relative cache path: $relative" }
        $items.Add($relative, [pscustomobject][ordered]@{
            relativePath = $relative
            fullPath = $file.FullName
            bytes = [long]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        })
    }
    [pscustomobject][ordered]@{
        root = $resolved
        files = $items
        fileCount = $items.Count
        bytes = [long](($items.Values | Measure-Object bytes -Sum).Sum)
    }
}

$reference = Get-Inventory $ReferencePath
$candidate = Get-Inventory $CandidatePath
$allPaths = @($reference.files.Keys + $candidate.files.Keys | Sort-Object -Unique)
$rows = foreach ($relative in $allPaths) {
    $hasReference = $reference.files.ContainsKey($relative)
    $hasCandidate = $candidate.files.ContainsKey($relative)
    $referenceItem = if ($hasReference) { $reference.files[$relative] } else { $null }
    $candidateItem = if ($hasCandidate) { $candidate.files[$relative] } else { $null }
    $same = $hasReference -and $hasCandidate -and $referenceItem.sha256 -eq $candidateItem.sha256
    [pscustomobject][ordered]@{
        relativePath = $relative
        status = if ($same) { 'identical' } elseif (-not $hasReference) { "only-$CandidateLabel" } elseif (-not $hasCandidate) { "only-$ReferenceLabel" } else { 'changed' }
        referenceBytes = if ($hasReference) { $referenceItem.bytes } else { $null }
        candidateBytes = if ($hasCandidate) { $candidateItem.bytes } else { $null }
        referenceSha256 = if ($hasReference) { $referenceItem.sha256 } else { $null }
        candidateSha256 = if ($hasCandidate) { $candidateItem.sha256 } else { $null }
    }
}

$differences = @($rows | Where-Object status -ne 'identical')
$differenceGroups = @($differences |
    Group-Object {
        $top = ($_.relativePath -split '\\', 2)[0]
        "$top|$($_.status)"
    } |
    ForEach-Object {
        $parts = $_.Name -split '\|', 2
        $referenceBytes = [long](($_.Group | Measure-Object referenceBytes -Sum).Sum)
        $candidateBytes = [long](($_.Group | Measure-Object candidateBytes -Sum).Sum)
        [pscustomobject][ordered]@{
            topLevel = $parts[0]
            status = $parts[1]
            files = $_.Count
            referenceBytes = $referenceBytes
            candidateBytes = $candidateBytes
            byteDelta = $candidateBytes - $referenceBytes
        }
    } |
    Sort-Object @{ Expression = 'files'; Descending = $true }, topLevel, status)
$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    reference = [pscustomobject][ordered]@{ label = $ReferenceLabel; path = $reference.root; files = $reference.fileCount; bytes = $reference.bytes }
    candidate = [pscustomobject][ordered]@{ label = $CandidateLabel; path = $candidate.root; files = $candidate.fileCount; bytes = $candidate.bytes }
    comparison = [pscustomobject][ordered]@{
        unionFiles = $rows.Count
        identicalFiles = @($rows | Where-Object status -eq 'identical').Count
        changedFiles = @($rows | Where-Object status -eq 'changed').Count
        onlyReferenceFiles = @($rows | Where-Object status -eq "only-$ReferenceLabel").Count
        onlyCandidateFiles = @($rows | Where-Object status -eq "only-$CandidateLabel").Count
        candidateByteDelta = [long]$candidate.bytes - [long]$reference.bytes
        differenceGroups = $differenceGroups
        onlyReferencePaths = @($rows | Where-Object status -eq "only-$ReferenceLabel" | ForEach-Object relativePath)
        onlyCandidatePaths = @($rows | Where-Object status -eq "only-$CandidateLabel" | ForEach-Object relativePath)
    }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$jsonPath = Join-Path $OutputDirectory 'shader-cache-comparison.json'
$csvPath = Join-Path $OutputDirectory 'shader-cache-differences.csv'
$markdownPath = Join-Path $OutputDirectory 'shader-cache-comparison.md'
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$differences | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$md = [Collections.Generic.List[string]]::new()
$md.Add('# CSX compiled shader-cache comparison')
$md.Add('')
$md.Add("Reference: ``$ReferenceLabel`` — $($reference.fileCount) files, $($reference.bytes) bytes.")
$md.Add("Candidate: ``$CandidateLabel`` — $($candidate.fileCount) files, $($candidate.bytes) bytes.")
$md.Add('')
$md.Add('| Identical | Changed | Only reference | Only candidate | Candidate byte delta |')
$md.Add('|---:|---:|---:|---:|---:|')
$md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $summary.comparison.identicalFiles, $summary.comparison.changedFiles, $summary.comparison.onlyReferenceFiles, $summary.comparison.onlyCandidateFiles, $summary.comparison.candidateByteDelta))
$md.Add('')
$md.Add('All non-identical rows, with both SHA-256 values, are in `shader-cache-differences.csv`.')
$md.Add('')
$md.Add('## Difference groups')
$md.Add('')
$md.Add('| Top-level path | Status | Files | Reference bytes | Candidate bytes | Delta |')
$md.Add('|---|---|---:|---:|---:|---:|')
foreach ($group in $differenceGroups) {
    $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $group.topLevel, $group.status, $group.files, $group.referenceBytes, $group.candidateBytes, $group.byteDelta))
}
$md.Add('')
$md.Add("## Files only in $ReferenceLabel")
$md.Add('')
foreach ($path in $summary.comparison.onlyReferencePaths) { $md.Add("- ``$path``") }
$md.Add('')
$md.Add("## Files only in $CandidateLabel")
$md.Add('')
foreach ($path in $summary.comparison.onlyCandidatePaths) { $md.Add("- ``$path``") }
$md | Set-Content -LiteralPath $markdownPath -Encoding utf8

[pscustomobject][ordered]@{
    ok = $true
    jsonPath = $jsonPath
    csvPath = $csvPath
    markdownPath = $markdownPath
    summary = $summary
} | ConvertTo-Json -Depth 12
