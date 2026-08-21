# MO2 Profile Control

`Invoke-MO2ProfileControl.ps1` inspects, enables, disables, or restores one exact
mod marker in an MO2 profile's `modlist.txt`. Every mutation retains a backup and
emits a receipt; it does not launch MO2 or select a fallback profile. `-WhatIf`
previews enable and disable operations without creating evidence or changing the
profile.

For noninteractive orchestration, pass `-Confirm:$false` only after the caller
has authorized the exact transaction. A bare `-Confirm` requests an interactive
PowerShell prompt and is converted into a clear blocked error when no prompt
host exists. `-NoExit` prevents the script from terminating a larger host.

The default blocking process set is `ModOrganizer`, `SkyrimVR`, and
`sksevr_loader`. `-BlockingProcessNames` exists for alternate installations and
isolated fixtures; an operational override must still name every process that
can own the target profile.

Run `tests/Test-MO2ProfileControl.ps1` after changing the contract.
