# Install the Codex plugin

## From GitHub

Add the repository marketplace and install the available plugin:

```text
codex plugin marketplace add Treatid2/skyrim-vr-automation --ref main
codex plugin add skyrim-vr-automation@skyrim-vr-tools
```

Restart Codex after a new installation. Run the doctor before a live workflow:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 inspect
```

Initialize the stable MO2 configuration at
`%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json` and then edit the copied
example, or migrate an existing file with `-SourceConfigPath`:

```powershell
.\tools\doctor\Invoke-SkyrimVRAutomationDoctor.ps1 init
```

An explicit `-ConfigPath` takes precedence, followed by
`SKYRIM_VR_AUTOMATION_CONFIG`, the stable per-user path, and the legacy ignored
checkout-local path. The doctor reports which source won.

## Upgrade

```text
codex plugin marketplace upgrade skyrim-vr-tools
codex plugin add skyrim-vr-automation@skyrim-vr-tools
```

Review `CHANGELOG.md`, rerun the doctor, and restart Codex. Pin a marketplace
checkout to a release tag with `--ref vX.Y.Z` when reproducibility matters.

## Remove

```text
codex plugin remove skyrim-vr-automation@skyrim-vr-tools
codex plugin marketplace remove skyrim-vr-tools
```

Removal does not delete per-user configuration, MO2 session evidence, SteamVR
backup receipts, or profiler/cache reports.
