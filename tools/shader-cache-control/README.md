# CSX compiled shader-cache control

`Compare-CSXShaderCache.ps1` inventories two preserved cache trees by relative
path, byte size, and SHA-256. It writes a compact JSON/Markdown summary plus a
CSV containing every added, removed, or content-changed file.

`Invoke-CSXShaderCacheTransaction.ps1` handles live physical cache trees as
attributable transactions. It can enumerate every MO2 mod that provides the
cache path, snapshot and verify an exact tree, or restore it while preserving
the displaced tree and both inventories. Snapshot and restore refuse to run
while MO2, Skyrim, or the SKSE loader is active.

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
```

Restore never silently discards the current tree: it copies the displaced
contents into the evidence directory, verifies that copy, and only then removes
the temporary sibling used for the atomic swap.

Run `Test-CSXShaderCacheControl.ps1` after changing the comparison logic.
