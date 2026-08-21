# DevBench Control

`Invoke-DevBenchControl.ps1` lists and calls the MCP tools exposed by a running
CSX DevBench server. Supply runtime metadata with `-RuntimePath` or set
`CSX_DEVBENCH_RUNTIME_PATH`; no machine-specific path is compiled into the
client.

```powershell
.\Invoke-DevBenchControl.ps1 list -RuntimePath 'C:\Path\To\runtime.json'
.\Invoke-DevBenchControl.ps1 call -Tool 'tool_name' -ArgumentsJson '{}'
.\Invoke-DevBenchControl.ps1 call -Tool 'tool_name' -ArgumentsJson '{}' -RequireSuccess
.\Invoke-DevBenchControl.ps1 wait -Condition noBlockingMenu -TimeoutSeconds 30
```

The client communicates only with the loopback endpoint and reports structured
JSON. By default it binds the endpoint to the owning listener PID and DevBench's
off-thread `inspect health` identity before returning. Runtime metadata may add
`pid`/`processId` and `exe`/`executable`; supplied values become strict
expectations. Pass `-EvidenceDirectory` to preserve this binding with the run.
When available, add `buildId`, `artifactPath`/`dllPath`, and
`artifactSha256` to runtime metadata (or pass their explicit parameter
equivalents). The controller queries the CSX registry bridge and hashes the
deployed DLL, binding source build, physical artifact, endpoint, and process in
one evidence record.

`ok` reflects transport success unless `-RequireSuccess` is supplied. Every
call also reports `transportOk` and a normalized `semantic` result, so an API
payload such as `idempotency_conflict` cannot be mistaken for successful work.

`wait -Condition noBlockingMenu` polls the menu tool client-side, ignores only
the explicitly listed `-IgnoredMenus` (HUD by default), and always reports the
actual timeout and final observation. This avoids the server-side `noMenu`
condition being held open forever by Skyrim's permanent HUD menu.

Use `-ToolFilter` or `-NamesOnly` to reduce a large authoritative `list`
response. `-NoExit` keeps failures as structured JSON without terminating a
larger PowerShell orchestration host. A missing runtime file, identity mismatch,
or unreachable endpoint is a blocked result.
