---
name: shader-cache-control
description: "Inventory and compare two preserved CSX compiled shader-cache trees by path, size, and SHA-256. Use for cache baseline extension, shader-family output comparisons, compilation-state evidence, or determining which files differ between controlled runs."
---

# Shader Cache Control

Read `../../tools/shader-cache-control/README.md` completely. Use:

```text
../../tools/shader-cache-control/Compare-CSXShaderCache.ps1
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

This tool is read-only with respect to both inputs. Cache unloading, clearing,
or replacement is a separate mutation and is never implied by a request to
compare caches.
