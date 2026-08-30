# SPDX-License-Identifier: GPL-3.0-or-later

Set-StrictMode -Version Latest

function Assert-CSXNoCacheReparsePoint {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Purpose)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Purpose traverses a reparse point: $($item.FullName)" }
        $item = if ($item -is [IO.FileInfo]) { $item.Directory } else { $item.Parent }
    }
}

function Get-CSXShaderCacheTreeInventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [ValidateRange(1, 1000000)][int]$MaxFiles = 20000,
        [ValidateRange(1, [long]::MaxValue)][long]$MaxBytes = 21474836480,
        [ValidateRange(1, 128)][int]$MaxDepth = 24,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 120,
        [string]$ProgressActivity = 'Inventorying shader cache'
    )
    $resolved = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "Shader-cache root is not a directory: $resolved" }
    Assert-CSXNoCacheReparsePoint -Path $resolved -Purpose 'Shader-cache inventory root'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $pending = [Collections.Generic.Queue[object]]::new()
    $pending.Enqueue([pscustomobject]@{ path = $resolved; depth = 0 })
    $files = [Collections.Generic.List[object]]::new()
    $totalBytes = [long]0
    $maximumDepthObserved = 0
    $lastProgressMilliseconds = [long]0
    try {
        while ($pending.Count -gt 0) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Shader-cache inventory exceeded its $TimeoutSeconds second deadline." }
            $directory = $pending.Dequeue()
            $maximumDepthObserved = [Math]::Max($maximumDepthObserved, [int]$directory.depth)
            foreach ($item in @(Get-ChildItem -LiteralPath ([string]$directory.path) -Force -ErrorAction Stop)) {
                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Shader-cache inventory exceeded its $TimeoutSeconds second deadline." }
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Shader-cache inventory encountered a reparse point: $($item.FullName)" }
                if ($item.PSIsContainer) {
                    $nextDepth = [int]$directory.depth + 1
                    if ($nextDepth -gt $MaxDepth) { throw "Shader-cache inventory exceeded its depth bound of $MaxDepth." }
                    $pending.Enqueue([pscustomobject]@{ path = $item.FullName; depth = $nextDepth })
                    continue
                }
                if ($files.Count + 1 -gt $MaxFiles) { throw "Shader-cache inventory exceeded its file-count bound of $MaxFiles." }
                $totalBytes += [long]$item.Length
                if ($totalBytes -gt $MaxBytes) { throw "Shader-cache inventory exceeded its byte bound of $MaxBytes." }
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Shader-cache inventory exceeded its $TimeoutSeconds second deadline." }
                $files.Add([pscustomobject][ordered]@{
                    relativePath = [IO.Path]::GetRelativePath($resolved, $item.FullName).Replace('/', '\')
                    bytes = [long]$item.Length
                    sha256 = $hash
                })
                if ($timer.ElapsedMilliseconds - $lastProgressMilliseconds -ge 1000) {
                    Write-Progress -Activity $ProgressActivity -Status ("{0} files, {1} bytes" -f $files.Count, $totalBytes)
                    $lastProgressMilliseconds = $timer.ElapsedMilliseconds
                }
            }
        }
    }
    finally { Write-Progress -Activity $ProgressActivity -Completed }

    $files = @($files | Sort-Object relativePath)
    $canonical = ($files | ForEach-Object { '{0}|{1}|{2}' -f $_.relativePath, $_.bytes, $_.sha256 }) -join "`n"
    $treeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical)))
    return [pscustomobject][ordered]@{
        root = $resolved
        files = $files.Count
        bytes = $totalBytes
        treeSha256 = $treeHash
        entries = $files
        elapsedMilliseconds = [long]$timer.ElapsedMilliseconds
        maximumDepthObserved = $maximumDepthObserved
        limits = [pscustomobject][ordered]@{ maxFiles = $MaxFiles; maxBytes = $MaxBytes; maxDepth = $MaxDepth; timeoutSeconds = $TimeoutSeconds }
    }
}
