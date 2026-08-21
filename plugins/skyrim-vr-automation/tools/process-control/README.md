# Bounded process control

`Invoke-BoundedProcess.ps1` runs an exact executable with an argument array,
captures each attempt, enforces a wall-clock timeout, and writes an optional
receipt plus stdout/stderr logs. It retries only when output matches an explicit
`-RetryPatterns` entry; arbitrary build failures are never retried.

The defaults recognize the transient MSVC dependency `.d.json` permission
failure observed during CSX builds and make at most two attempts.

```powershell
.\Invoke-BoundedProcess.ps1 -FilePath cmake `
  -ArgumentList @('--build', 'build\ALL', '--config', 'Release') `
  -WorkingDirectory 'L:\Source\CSX' `
  -EvidenceDirectory 'D:\Evidence\build'
```

Use `-NoExit` when composing several tools in one PowerShell host.
