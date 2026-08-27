# Release procedure

1. Set the same SemVer in `.codex-plugin/plugin.json` and
   `toolset.manifest.json`; finalize the matching changelog entry.
2. Run `scripts/Build-CodexMarketplacePlugin.ps1` and review the generated
   `plugins/skyrim-vr-automation` tree. It must contain no `*.local.json`,
   sessions, fixture-refresh evidence, or machine-specific paths.
3. Run `tests/Test-Toolset.ps1` and the official plugin and skill validators.
4. Test the marketplace from a clean checkout. Run the doctor before any live
   MO2 or SteamVR operation.
5. Commit the generated package with its canonical sources, tag `vX.Y.Z`, and
   publish release notes derived from `CHANGELOG.md`.
6. Verify install from the tag, then update the marketplace's documented stable
   reference when appropriate. Never move an existing version tag.
