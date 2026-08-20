# Automation repository rules

- Treat every game, MO2, SteamVR, profile, and cache mutation as an attributable
  transaction. Inspect first and preserve its result with the test record.
- Never silently fall back to a different MO2 profile, executable, runtime,
  configuration file, or null-HMD profile.
- Require MO2 and Skyrim to be closed before profile or package mutation.
- Require SteamVR to be closed before applying or restoring null-HMD settings.
- Retain exact backups and receipts until the associated test evidence has been
  classified. Never delete unclassified MO2 overwrite or shader-cache content.
- Keep automated waits bounded and report the observed postcondition. A CTD is
  useful evidence, not permission for unbounded retries.
- Tests must use temporary fixtures by default. Live checks must be explicitly
  selected and read-only unless the user has placed a state change in scope.
- Machine-specific paths belong only in ignored `machine.local.json` files,
  explicit parameters, or documented environment variables.
