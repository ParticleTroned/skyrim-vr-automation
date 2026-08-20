# MO2 Profile Control

`Invoke-MO2ProfileControl.ps1` inspects or transactionally toggles one exact mod
marker in an MO2 profile's `modlist.txt`. Mutation retains a backup and emits a
receipt; it does not launch MO2 or select a fallback profile.

The default blocking process set is `ModOrganizer`, `SkyrimVR`, and
`sksevr_loader`. `-BlockingProcessNames` exists for alternate installations and
isolated fixtures; an operational override must still name every process that
can own the target profile.

Run `tests/Test-MO2ProfileControl.ps1` after changing the contract.
