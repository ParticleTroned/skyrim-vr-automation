# COC evidence control

Invoke-CocEvidenceControl.ps1 prepares the local crash/hang evidence lane
before a live Skyrim VR COC assay.

It verifies:

- ProcDump and CDB/WinDbg are available;
- the dump drive has at least 100 GiB free by default.

The arm command starts one hidden ProcDump monitor for SkyrimVR.exe. It records
full dumps for unhandled exceptions and Windows hangs, caps the run at two
dumps, and does not create a normal-process-exit dump. The returned state path
owns later status and stop operations.

The controller discovers the sibling `codex-ghidra-live` GitHub folder.
Portable overrides are `CSX_COC_EVIDENCE_ROOT`, `CSX_PROCDUMP_PATH`,
`CSX_CDB_PATH`, and `CSX_COC_DUMP_ROOT`.

The controller owns only local dump collection and WinDbg analyzer readiness.
Before a live assay, Codex must use Community Shaders'
`tools/ghidra-mcp-control.ps1` to prove the managed Ghidra server is ready,
make a harmless Ghidra MCP call, and confirm that the DevBench MCP tools are
present in the current Codex window.
