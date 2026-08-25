---
name: shader-cache-control
description: "Select, seed, preserve, promote, inventory, and compare CSX compiled shader-cache trees with exact compatibility metadata and receipts. Use for avoiding unnecessary shader recompilation in a Skyrim VR task, preparing or completing a task cache, extending known-working cache baselines, shader-family output comparisons, compilation-state evidence, or determining which files differ between controlled runs."
---

# Shader Cache Control

Read `../../tools/shader-cache-control/README.md` completely. Use:

```text
../../tools/shader-cache-control/Compare-CSXShaderCache.ps1
../../tools/shader-cache-control/Invoke-CSXShaderCacheTransaction.ps1
../../tools/shader-cache-control/Invoke-CSXShaderCacheCatalog.ps1
```

## Comparison contract

1. State in commentary that this skill governs the cache comparison.
2. Accept only two preserved snapshot directories. Never point the comparer at
   a cache that the game or compiler can still mutate.
3. Keep snapshots and generated reports outside live MO2 overwrite, RootBuilder
   data, and active compiled-shader directories.
4. Record the exact build, preset, shader state, scene/run, and capture time for
   both trees. Hash results establish file identity, not semantic equivalence.
5. Preserve JSON and CSV output with the corresponding profiler and MO2
   evidence. Do not delete or normalize cache files to make comparisons align.

Comparison is read-only with respect to both inputs. For an explicitly
authorized live-cache test, first run `providers`, then `snapshot`; use
`verify` after the run. `restore` requires MO2/Skyrim closed and preserves the
displaced physical tree before completing. Cache unloading, clearing, or
replacement is never implied by a request to compare caches.

## Task cache lifecycle

1. For a Skyrim task that may compile CSX shaders, create and enable a uniquely
   named task-owned loose mod containing
   `ShaderCache\.codex-vfs-sentinel.txt`, and make it the winning loose
   `ShaderCache` provider. Determine the exact shader-cache ABI, game runtime,
   render path, shader-source SHA-256, build identity, preset SHA-256, and task
   tags. Do not infer the runtime write target, semantic compatibility, or
   priority from names or timestamps.
2. With MO2 and Skyrim closed, call catalog `prepare` before the MO2 session
   with the exact `-ProfilePath`, `-ModsPath`, `-CacheModName`, and
   `-RequireMaterializedOutput`. Retain `shader-cache-task.plan.json` with the
   task evidence. No compatible match is nonfatal unless the task requires
   `-RequireMatch`. Never substitute an unproven global overwrite path for the
   bound winning provider.
3. Never clear a live cache merely to get a clean experiment. Use the task plan
   and exact seeding transaction. A source mismatch requires both
   `-AllowSourceMismatch` and a written `-CompatibilityReason`; it never
   bypasses ABI, runtime, render-path, known-working, or required-tag gates.
4. After MO2 and Skyrim are closed, call catalog `complete` before releasing
   the task workspace. It revalidates the profile and winning provider,
   preserves the task result, and restores the exact pre-task cache. If
   materialization is missing, retain the task mod and open transaction,
   diagnose the VFS routing, and retry completion only after real output is
   present. Promote only after the run provides affirmative evidence that the
   result is known-working.
5. Preserve the plan, transaction receipts, completion receipt, catalog
   manifest, source/build/preset identities, profiler evidence, and any cache
   comparison report together. Do not delete content-addressed objects or edit
   immutable manifests by hand.
