# CSX compiled shader-cache control

`Compare-CSXShaderCache.ps1` inventories two preserved cache trees by relative
path, byte size, and SHA-256. It writes a compact JSON/Markdown summary plus a
CSV containing every added, removed, or content-changed file.

`Invoke-CSXShaderCacheTransaction.ps1` handles live physical cache trees as
attributable transactions. It can enumerate every MO2 mod that provides the
cache path, snapshot and verify an exact tree, seed a verified baseline, or
restore it while preserving the displaced tree and both inventories. Snapshot,
seed, and restore refuse to run while MO2, Skyrim, or the SKSE loader is active.

```powershell
.\Compare-CSXShaderCache.ps1 `
  -ReferencePath '.\enabled\ShaderCache' `
  -CandidatePath '.\unloaded\ShaderCache' `
  -ReferenceLabel enabled `
  -CandidateLabel unloaded `
  -OutputDirectory '.\comparison'
```

This is read-only with respect to both cache roots. Keep snapshots outside the
live MO2 overwrite tree so harness safety limits measure active state rather
than evidence copies.

```powershell
.\Invoke-CSXShaderCacheTransaction.ps1 providers `
  -ProfilePath 'D:\MO2\profiles\Profile\modlist.txt' `
  -ModsPath 'D:\MO2\mods' -DeepInventory

.\Invoke-CSXShaderCacheTransaction.ps1 snapshot `
  -CachePath 'D:\MO2\mods\Cache Mod\ShaderCache' `
  -EvidenceDirectory 'D:\Evidence\cache-transaction' -Confirm:$false

.\Invoke-CSXShaderCacheTransaction.ps1 verify `
  -CachePath 'D:\MO2\mods\Cache Mod\ShaderCache' `
  -EvidenceDirectory 'D:\Evidence\cache-transaction'

.\Invoke-CSXShaderCacheTransaction.ps1 seed `
  -CachePath 'D:\MO2\mods\Cache Mod\ShaderCache' `
  -SourceCachePath 'D:\Preserved\Compatible Baseline\ShaderCache' `
  -ExpectedSourceTreeSha256 '<exact inventory hash>' `
  -EvidenceDirectory 'D:\Evidence\cache-transaction'
```

`seed` requires the existing snapshot receipt for the same live cache and
evidence directory, verifies the exact source tree, stages it, swaps it into
place, and preserves the displaced live tree. A deliberately compatible
seed source may use any non-root directory name; its exact expected tree hash
is mandatory. `ShaderCache` remains the default and required leaf for the live,
destructively swapped target. A deliberately compatible
cache-contract change may use `-ShaderCacheAbiOverride`, but only together with
an explicit `-CompatibilityReason`; the original and replacement ABI, reason,
source identity, seeded identity, and displaced identity are retained in the
seed receipt. This exception is for proven non-bytecode changes, not a way to
silence an unknown ABI mismatch.

`providers` also accepts an exact relative loose-file path through
`-RelativeCachePath` (for example
`SKSE\Plugins\CommunityShaders.dll`). It enumerates every physical provider,
marks the earliest enabled mod provider as the winner among enabled loose mods,
and explicitly leaves overwrite, unmanaged-file, archive, and runtime
deployment resolution to separate VFS evidence.

Restore never silently discards the current tree: it copies the displaced
contents into the evidence directory, verifies that copy, and only then removes
the temporary sibling used for the atomic swap.

Run `Test-CSXShaderCacheControl.ps1` after changing the comparison logic.
