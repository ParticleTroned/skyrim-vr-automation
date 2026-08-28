# Automation source-review remediation — 2026-08-28

This ledger records the phased repair of the automation source reviewed from
`Treatid2/skyrim-vr-automation` main commit
`79cb85cd3884ea71a89730ced39273b7c32c74e2`, plus the unpushed SteamVR
semantic-restore candidate at `dcabc766f8aefaf50270546a6abd36ebd2683191`.
The repair branch is `codex/automation-hardening-phase-0`.

The review package described 37 findings: 13 blockers, 16 high-severity, and
8 medium-severity findings. The changes below address the source-contract
classes rather than treating individual symptoms as isolated patches.

## Repair sequence

| Phase | Repair | Commit | Qualification |
| --- | --- | --- | --- |
| 0 | Reproduce traversal, stale-state, mutation, and qualification gaps with synthetic guards | `2943325` | New tests fail against the reviewed source |
| 0 | Fail closed on immediate path, state, and result-contract violations | `8643542` | Focused tool tests |
| 1 | Put child processes under one bounded runner with total budgets, exact executable identity, owned cleanup, and retained logs | `052fdd0` | Process, doctor, and build-test suites |
| 2 | Journal DevBench mutations before dispatch and make timeout/target-exit outcomes exactly once and attributable | `f51ca2d` | Canonical and packaged DevBench suites |
| 3 | Serialize MO2 lease transitions and generation changes | `8e3da1d` | MO2 concurrency and stale-writer tests |
| 4 | Journal profile mutations before changes and recover interrupted operations | `24b00ab` | Profile transaction tests |
| 4 | Make task workspaces exact-profile, access-owned, resumable, reparse-safe, and recoverable | `1272b97` | Workspace lifecycle tests |
| 5 | Make shader-cache swaps inventory-bound, reparse-safe, journalled, and recoverable | `e90dd7b` | Cache catalog and transaction tests |
| 6 | Make SteamVR/null-HMD changes transactional and recoverable | `502036a` | Synthetic SteamVR configuration tests |
| 7 | Version and acknowledge the shared head-pose protocol; validate application-facing stereo state; make driver installation transactional | `7ae3717` | Native Release build, controller tests, and stereo probe contract tests |
| 7 | Require qualified profiler context, fresh unique frames, finite metrics, stable runtime identity, and exact state restoration | `ef9bed5` | Profiler and DevBench adapter suites |
| 8 | Derive SteamVR semantic restore expectations from exact backups, not receipts; reject duplicate/missing targets and receipt disagreement | `4738e63` | 43 canonical and 43 packaged SteamVR tests |
| 8 | Separate public MO2 lease identity from bearer output, bind owner liveness to PID plus start time, require explicit feedback actor roles, and recursively redact exports | `e504a2e` | 90 canonical and 90 packaged MO2 tests; canonical and packaged feedback lifecycle tests |

## Review-class closure

The blocker classes are closed in source as follows:

- Unbounded or orphanable process execution now has one owner, one total
  timeout, exact path checks, bounded cleanup, and durable logs.
- Mutating DevBench calls are journalled before dispatch and cannot silently
  become a second mutation after an ambiguous result.
- MO2 profile, workspace, access, and cache mutations serialize ownership and
  carry recoverable pre/post state rather than relying on optimistic cleanup.
- Null-HMD and OpenVR registration changes restore from exact backups and do
  not trust a receipt to define the expected state.
- Head-pose shared memory has an explicit version, writer nonce, sequence
  acknowledgement, mutex, ACL, and driver identity; stereo qualification
  checks both eye transforms and render-target geometry.
- Profiler captures are rejected unless their environment, frames, numeric
  values, and runtime identity make the comparison meaningful.

The high and medium classes are closed by the same structural changes plus:

- direct-child path confinement and reparse-point rejection;
- generation-bound MO2 updates and stale-writer preservation;
- exact task/profile ownership and additive shared-mod policy;
- cache compatibility metadata and controlled promotion;
- recursively sanitized feedback export fields;
- canonical-versus-packaged distribution equivalence checks.

## Deliberate trust boundaries

Two limitations remain explicit rather than being disguised as security:

1. MO2 is a cooperative, same-Windows-user resource manager. Competing-task
   status exposes only a public `leaseId`, never the supplied `accessId`, and
   the API no longer echoes a wrong credential. Existing workspace evidence
   still records the access identity needed for local resume/audit. Converting
   every persisted workspace to hashed-at-rest credentials is a breaking data
   migration and is tracked separately; do not expose the state directories to
   untrusted local or remote users.
2. Feedback `ActorRole` is an audit declaration, not authentication. Maintainer
   transitions require the explicit maintainer role, but the tool remains a
   local same-user mailbox. It must not be published as a remote mutation API
   without a real capability/identity layer.

## Qualification boundary

The source repair is covered by deterministic and synthetic tests. It does not
claim that a unit test substitutes for live Skyrim VR qualification. Before a
release is tagged, run the existing live matrix for:

- normal live HMD and SteamVR null-HMD startup/restore;
- the installed head-pose provider and stereo screenshot API;
- DevBench mutations during target exit and timeout;
- matched profiler captures with identical profile, scene, resolution, and
  HMD mode;
- MO2 interruption recovery while RootBuilder and shader-cache transactions
  are active.

No live MO2, Skyrim, or SteamVR mutation is required merely to merge these
source-contract repairs; those tests are release qualification evidence.
