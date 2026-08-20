# CSX compiled shader-cache control

`Compare-CSXShaderCache.ps1` inventories two preserved cache trees by relative
path, byte size, and SHA-256. It writes a compact JSON/Markdown summary plus a
CSV containing every added, removed, or content-changed file.

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

Run `Test-CSXShaderCacheControl.ps1` after changing the comparison logic.
