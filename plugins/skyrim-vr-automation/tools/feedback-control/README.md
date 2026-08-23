# Automation feedback control

`Invoke-AutomationFeedback.ps1` provides a durable local mailbox between tasks
that use the Skyrim VR automation toolkit and the maintainer who updates it.
It never publishes feedback, evidence, or machine details.

## Storage resolution

The queue root is selected in this order:

1. `-FeedbackRoot`
2. `SKYRIM_VR_AUTOMATION_FEEDBACK_ROOT`
3. `storage.feedback` in the explicit, environment-selected, or stable
   `%LOCALAPPDATA%\SkyrimVRAutomation\machine.local.json`
4. `$CODEX_HOME\state\skyrim-vr-automation\feedback` when running in Codex
5. `%LOCALAPPDATA%\SkyrimVRAutomation\feedback`

Base reports and lifecycle events are immutable JSON files. Writers take a
bounded local lock, write through a temporary file, flush it, and atomically
publish the completed document. A task may claim that feedback was recorded
only after the controller returns `state: recorded` and a receipt.

## Reporter workflow

```powershell
$tool = '.\tools\feedback-control\Invoke-AutomationFeedback.ps1'

& $tool submit `
  -Area mo2 `
  -Kind defect `
  -Severity high `
  -Summary 'Unlock dialog was classified as the main window' `
  -Observed 'The close controller requested window close instead of exact Unlock.' `
  -Expected 'Classify the structural Unlock dialog before choosing a close action.' `
  -Operation 'mo2-control close' `
  -EvidencePath 'D:\Evidence\session.json'
```

Preserve the returned `AUTO-...` receipt in the task report. Use `amend` to
add evidence or correct an open record. `list-mine` requires a task identity
from `-ReporterTaskId`, `CODEX_THREAD_ID`, or `CODEX_TASK_ID`.

Do not put credentials in free text or `-ParametersJson`. Observed facts,
expected behaviour, and suggested implementation must remain distinct.

## Maintainer workflow

```powershell
& $tool list -Status new,triaged
& $tool triage -FeedbackId AUTO-... -Actor maintainer -Note 'Reproduced.'
& $tool accept -FeedbackId AUTO-... -Actor maintainer
& $tool resolve -FeedbackId AUTO-... -Actor maintainer `
  -Resolution 'Added structural Unlock classification and a regression test.' `
  -Commit abc123 -PullRequest 'https://github.com/example/repo/pull/1' `
  -Release 0.7.0
```

Supported lifecycle operations are `triage`, `accept`, `duplicate`, `defer`,
`decline`, `resolve`, and `reopen`. Terminal records must be reopened before
amendment. Duplicate and resolution links are preserved in the event journal.

## Export boundary

`export` requires an explicit output path and never contacts GitHub. By
default it omits operation parameters, reporter/task identity, profile/session
context, and evidence paths. It retains evidence names, sizes and hashes.
`-IncludeLocalPaths` is an explicit exception. Every export says that human or
maintainer review is required before sharing because free text can still
contain private information.

```powershell
& $tool export -FeedbackId AUTO-... -Format markdown `
  -OutputPath '.\feedback-for-review.md'
```

GitHub issues and pull requests remain deliberate maintainer actions after
local reproduction, deduplication and sanitization.
