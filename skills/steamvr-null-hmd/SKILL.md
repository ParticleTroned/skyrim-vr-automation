---
name: steamvr-null-hmd
description: "Inspect, apply, restore, or stop SteamVR's Valve null-HMD configuration through a transactional controller. Use for null HMD, HMD null, SteamVR null driver, headless VR testing, SteamVR test-runtime switching, restoration of normal headset settings, or investigation of the exact SteamVR processes and overrides involved."
---

# SteamVR Null HMD

Use the bundled controller rather than editing `steamvr.vrsettings` directly.

## Load the contract

Before acting, read `../../tools/steamvr-null-control/README.md` completely and
inspect the parameter block in
`../../tools/steamvr-null-control/Invoke-SteamVRNullControl.ps1`. Treat the
repository-root `AGENTS.md` as binding operational policy. The bundled default
profile is `../../profiles/steamvr-null.profile.json`.

Resolve these paths from this skill's installed location; do not assume a
particular drive letter for the plugin itself.

## Operating sequence

1. State in commentary that this skill is governing the null-HMD operation.
2. Run `inspect -Compact` first and retain the JSON result as the before-state.
   If it reports `external-driver-conflict`, do not start SteamVR; report the
   exact redirecting driver inventory. This controller does not unregister
   third-party drivers.
3. Before `apply` or `restore`, prove SteamVR is closed. Use `stop -Compact`
   first; if it does not close, review the returned exact process inventory
   before using `stop -Force -Compact`.
4. Create or select one attributable evidence directory for the test. Preview
   `apply` or `restore` with `-WhatIf`, then perform the authorized operation
   using the same `-EvidenceDirectory`.
5. Parse the JSON postcondition. After `apply`, require `state` to be
   `null-applied` and the effective profile checks to match. After `restore`,
   require the restored settings hash to match the exact backup.
6. Treat `null-runtime-started-unqualified` and
   `null-runtime-active-unqualified` as rendering availability only. The
   `inputContract` deliberately declares controlled HMD pose and controllers
   unavailable; do not replay controller input or collect render measurements
   until a separate application-observed pose qualification exists. Stop on
   `dashboard-input-conflict`.
7. Run `inspect -Compact` again and preserve the before/after results, exact
   backup, receipt, hashes, and evidence-directory identity.

## Safety and recovery

- Inspection is read-only. Do not change runtime state for a diagnostic-only
  request.
- Never apply or restore while any SteamVR process remains. Do not stop Steam,
  Virtual Desktop, OpenComposite, or unrelated same-name processes.
- `apply` must create a new exact backup and receipt. Never replace an existing
  backup; use a new evidence directory for a new transaction.
- `restore` must use the evidence directory from its corresponding apply and
  must verify the receipt and backup hash. Retain both afterward.
- Use `-SettingsPath` and `-SteamVRRoot` for nonstandard installations. Never
  silently fall back to the default installation paths.
- Invoke the controller with PowerShell 7 `pwsh.exe`. Do not work around its
  explicit Windows PowerShell compatibility rejection.
- A launch failure or CTD is evidence. Record the runtime state and analyze the
  result before another attempt.

When a test also uses MO2, complete the runtime transition before invoking the
`$mo2-control` lifecycle. Do not infer which runtime Skyrim actually used from
the presence of SteamVR processes alone; record the route separately.
