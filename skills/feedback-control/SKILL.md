---
name: feedback-control
description: "Record durable local feedback about the Skyrim VR automation toolkit and triage, resolve, or explicitly export it. Use whenever an automation command behaves unexpectedly, its contract is ambiguous, a safety edge case is discovered, or a task identifies a concrete enhancement or major time-saver. Also use when asked to inspect, maintain, deduplicate, export, or report the local automation feedback queue."
---

# Automation Feedback Control

Use the bundled feedback controller instead of leaving automation desires only
in task prose or publishing them directly:

```text
../../tools/feedback-control/Invoke-AutomationFeedback.ps1
```

Read `../../tools/feedback-control/README.md` completely before the first
submission or maintainer operation in a task. Resolve paths from this skill's
installed location.

## Reporter contract

1. Preserve the exact structured tool result and relevant evidence first.
2. Submit one focused record per independently actionable behaviour. Keep
   observed facts, expected behaviour, and implementation suggestions in their
   separate fields.
3. Select the narrowest area and kind. Mark a task blocked only when the
   tooling issue actually prevented useful progress.
4. Pass sanitized operation parameters only. Never record credentials.
5. Retain the returned `AUTO-...` receipt. Say **feedback recorded** only when
   the command returns `ok: true`, `state: recorded`, and that receipt.
   Otherwise say **feedback noted in this task report**.
6. Use `amend` to attach later evidence. Do not edit queue files directly.

Feedback submission is local and does not authorize changes to automation
source, GitHub issues, pull requests, messages, or publication.

## Maintainer contract

The designated toolkit maintainer uses `list`, `get`, `triage`, `accept`,
`duplicate`, `defer`, `decline`, `resolve`, and `reopen`, passing
`-ActorRole maintainer`. Amendments also require an actor and an explicit
`reporter` or `maintainer` role. Preserve actor,
reason, commit, pull-request, and release links in lifecycle events. Reproduce
and classify reports before changing public source when practical.

Actor roles are audit declarations within a cooperative same-user local tool,
not authentication. Do not expose the feedback root as a remote mutation API.

`export` is the only sharing preparation operation. It requires an explicit
path, is sanitized by default, and still requires review. Never publish the
export automatically.

## Storage and privacy

The controller chooses a local queue by explicit parameter, environment,
machine configuration, Codex home, or local application data—in that order.
Base reports and lifecycle events are immutable, atomically written files.
Evidence paths remain local; ordinary exports retain names, sizes and hashes
but omit paths, task identity, profile/session context, and parameters.

Do not delete queue records or event files. Resolve, decline, or mark duplicate
instead so repeated failures and the audit trail remain visible.
