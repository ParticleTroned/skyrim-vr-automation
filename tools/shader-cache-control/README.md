# CSX compiled shader-cache control

`Compare-CSXShaderCache.ps1` inventories two preserved cache trees by relative
path, byte size, and SHA-256. It writes a compact JSON/Markdown summary plus a
CSV containing every added, removed, or content-changed file.

`Invoke-CSXShaderCacheTransaction.ps1` handles live physical cache trees as
attributable transactions. It can enumerate every MO2 mod that provides the
cache path, snapshot and verify an exact tree, seed a verified baseline, or
restore it while preserving the displaced tree and both inventories. Snapshot,
seed, and restore refuse to run while MO2, Skyrim, or the SKSE loader is active.

`Invoke-CSXShaderCacheCatalog.ps1` composes those primitives into reusable task
cache management. It stores immutable, content-addressed cache objects and
separate snapshot manifests carrying the cache ABI, game runtime, render path,
shader-source hash, optional build and preset hashes, normalized tags, status,
and receipt provenance. There is no mutable index to repair: `list` validates
the manifests and derives the catalog view from disk.

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

## Reusing known-working caches between tasks

Configure a permanent catalog outside MO2 and the checkout:

```json
{
  "storage": {
    "shaderCacheCatalog": "D:\\SkyrimVRAutomation\\ShaderCacheCatalog"
  }
}
```

`-CatalogRoot` takes precedence, followed by
`CSX_SHADER_CACHE_CATALOG_ROOT`, the configured path, `CODEX_HOME`, and the
user-local application-data fallback. A catalog candidate is never accepted
from its label alone. The hard compatibility gates are known-working status,
exact shader-cache ABI, game runtime, render path, required tags, and—by
default—exact shader-source SHA-256. Among compatible candidates, exact source,
build, and preset matches rank first, followed by broader verified coverage and
recency. `select` returns both the ranking and explicit exclusion reasons.

First admit a receipt-proven snapshot:

```powershell
.\Invoke-CSXShaderCacheCatalog.ps1 capture `
  -SourceCachePath 'D:\Evidence\known-good\cache.before' `
  -ExpectedSourceTreeSha256 '<exact cache tree hash>' `
  -SourceReceiptPath 'D:\Evidence\known-good\shader-cache-transaction.receipt.json' `
  -ShaderCacheAbi '<exact ABI>' `
  -ShaderSourceSha256 '<exact source-tree SHA-256>' `
  -BuildId '<build identity>' `
  -PresetSha256 '<preset SHA-256>' `
  -Tags quality,full-render `
  -SnapshotStatus known-working `
  -Label 'quality full-render known good' `
  -Confirm:$false
```

For an MO2 task, create and enable a uniquely named task cache mod containing
`ShaderCache\.codex-vfs-sentinel.txt`. Put it at the winning loose-mod priority,
then bind preparation to that exact provider. Do not infer global `overwrite` as
the write target: MO2 can route new VFS files into an enabled provider or an
executable-specific output mod.

Prepare the closed task cache immediately before launching MO2:

```powershell
.\Invoke-CSXShaderCacheCatalog.ps1 prepare `
  -ProfilePath 'D:\MO2\profiles\Task Profile\modlist.txt' `
  -ModsPath 'D:\MO2\mods' `
  -CacheModName 'Codex Task Cache - task-id' `
  -EvidenceDirectory 'D:\Evidence\task-id\shader-cache' `
  -ShaderCacheAbi '<exact ABI>' `
  -ShaderSourceSha256 '<exact source-tree SHA-256>' `
  -BuildId '<build identity>' `
  -PresetSha256 '<preset SHA-256>' `
  -RequiredTags quality,full-render `
  -RequireMaterializedOutput `
  -Confirm:$false
```

`prepare` always snapshots the caller's exact current cache first. It then
selects the best compatible known-working snapshot and seeds it only when it is
different. With no match it safely leaves the current tree in use; add
`-RequireMatch` when a task must not proceed without a catalog baseline.
Provider-bound preparation enumerates the exact profile, requires
`-CacheModName` to be the winning enabled loose provider, records the modlist
hash and physical provider path, and rejects a conflicting `-CachePath`.
When `-BuildId` is supplied, preparation also fails closed unless the winning
loose `SKSE\Plugins\CommunityShaders.dll` provider has a matching
`CSX.BuildManifest.json`, artifact hash, and shader-cache ABI. The task plan
records both bindings so a cache provider proof cannot mask a different DLL
winner. Completion revalidates the DLL identity as well as the cache provider.
Unbound paths whose parent is MO2 `overwrite` are refused because that physical
tree is not proof of the runtime VFS write destination.

After the game and MO2 are closed, complete the cache transaction:

```powershell
.\Invoke-CSXShaderCacheCatalog.ps1 complete `
  -EvidenceDirectory 'D:\Evidence\task-id\shader-cache' `
  -WorkingSetStatus known-working `
  -Promote -Label 'verified task result' `
  -Confirm:$false
```

`complete` preserves the task-produced cache, restores the exact pre-task tree,
and records a completion receipt. Promotion is opt-in and is refused unless the
caller explicitly classifies the task result as `known-working`. An unverified
or failed task result is still preserved as evidence but is not added to the
catalog. A shader-source mismatch remains excluded unless
`-AllowSourceMismatch` is accompanied by a concrete `-CompatibilityReason`;
this exception does not bypass ABI, runtime, render-path, status, or tag gates.

For a provider-bound plan, `complete` re-enumerates the profile and fails closed
if the modlist or winning provider changed. When preparation used
`-RequireMaterializedOutput`, completion ignores only the automation sentinel
and `.gitkeep`; if no real cache file exists, it writes
`shader-cache-task.materialization-failure.json`, leaves the transaction open,
and does not restore or remove the live provider tree. Complete the cache before
releasing the task workspace so a routing defect cannot delete the only copy of
compiled output.

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

Run `Test-CSXShaderCacheControl.ps1` after changing comparison or transaction
logic, and `Test-CSXShaderCacheCatalog.ps1` after changing catalog selection or
task lifecycle logic.
