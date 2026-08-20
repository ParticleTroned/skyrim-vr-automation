## MO2 automation

For Skyrim VR Mod Organizer 2 inspection, validation, launch preparation, or
session-artifact handling, begin with the shared runbook and tool at
`<repository>\tools\mo2-control`.

- Run `Invoke-MO2Control.ps1 inspect` before reasoning from assumed MO2 state.
- Run `Invoke-MO2Control.ps1 validate -RequireClosed` before changing profiles,
  mod-list state, RootBuilder state, or deployed packages.
- Use the exact `Codex` profile and exact registered executable unless the user
  names another target. Never accept MO2 profile fallback.
- Version 0.3.0 implements the bounded single-owner lifecycle described in
  `MO2-RUNBOOK.md`. Do not invent unimplemented control commands.
- Use the configured staging and archive locations. Do not accumulate evidence
  in the game folder or overwrite, and never delete unclassified overwrite
  content.
