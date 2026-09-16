# Capture interaction control

`Invoke-CaptureInteraction.ps1` is the host-side observation/action layer over
DevBench recording, atomic OpenVR tracked-set input, and the CSX screenshot v1
service. It does not encode video and does not invent missing game state.

Every session has one UUID and one durable session document. State recording
starts first. Optional stereo capture starts second and rolls recording back if
it cannot be accepted. Stop reverses that order so the state trace encloses all
captured frames. `none`, `on-demand`, and `sequence` visual modes all retain the
same interaction and state contract.

```powershell
pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 start `
  -SessionDirectory D:\CodexScratch\...\interaction `
  -RuntimePath D:\CSX-MO2-Sessions\...\devbench-runtime.json `
  -VisualMode sequence -FrameIntervalMs 500

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 observe `
  -SessionDirectory D:\CodexScratch\...\interaction

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 act `
  -SessionDirectory D:\CodexScratch\...\interaction `
  -ActionName accept -ObserveAfterAction

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 wait-save `
  -SessionDirectory D:\CodexScratch\...\interaction `
  -SaveDirectory D:\MO2\profiles\Task\saves -SaveNamePattern 'Save3*'

pwsh -NoProfile -File .\Invoke-CaptureInteraction.ps1 stop `
  -SessionDirectory D:\CodexScratch\...\interaction
```

`observe` writes `latest-observation.json` and returns a composite snapshot of
the latest committed CSX frame, screenshot request state, recording status,
game state, open menus, tracked-set injection state, and the current physical
HMD/controller set. `data.observation.frameSubmission.path` is the image to
submit to an image-capable model. It is deliberately the newest completed
artifact, not the oldest unprocessed member of a backlog. Stereo artifacts and
the CSX frame manifest remain intact for evidence.

Named actions are declared in `actions.v1.json`. Controller actions first use
the read-only DevBench tracked-set observation, preserve all three current
poses, neutralize stale input state, and then compile a bounded atomic sequence.
The call waits for that exact sequence generation to become terminal before it
returns, preventing a following action from colliding with an active owner.
The accepted owner, generation and cleanup token are written to the session and
action journal before polling. Inactive input is only terminal after the same
generation's controller-index restoration is proven. Timeout, interruption and
supersession remain failures with their latest status attached. `stop` and
`abort` release only the retained token's generation and wait through pending
restoration; they never release a later owner's input.

`key-tap` uses DevBench keyboard input, accepts `holdMs` from 10 through 5000,
and sends that value as the keyboard API's `durationMs`. It does not require a
VR pose to compile. `-DirectTool` with
`-DirectArgumentsJson` is an explicit passthrough for operations not represented
by the catalog; every action is appended to `actions.ndjson`.

`wait-save` uses the session start timestamp by default, parses explicit
`-SinceUtc` values as `DateTimeOffset`, compares only UTC values, and requires a
matching `.ess` file to retain identical size and last-write time for the
requested stability interval. Its bounded receipt includes the resolved UTC
boundary and every observed candidate; it never stops the capture implicitly.

The tool never launches Skyrim or MO2 and never allocates scratch implicitly.
The caller supplies a managed capture allocation or another explicit evidence
directory and remains responsible for promotion/release. Runtime identity
verification is on by default; the bypass exists only for isolated tests.

Pass `-ExpectedRuntimeIdentityJson` at start to pin the exact inspected producer
and process. The controller stores that binding and forwards it through the
selected DevBench controller on every subsequent operation. Resumed commands
may omit the parameter or repeat the identical serialized binding; they cannot
replace it with a different runtime.

Admission reads the live tool catalog and requires `record` to advertise
`correlationId`, `maximumDurationMs`, and `expectedCorrelationId`, plus atomic
input `observe` and `controlToken`. This rejects older hosts that would silently
ignore the stop guard. Recording starts with the capture session UUID and stops
with that UUID as `expectedCorrelationId`, checked atomically by DevBench. A
foreign recording is preserved. Every observation and action checks recording
correlation and limit state. A limited recording is still finalized to disk;
its truncation reason remains a failure in the result.

`-RecordMaximumDurationMs` defaults to four hours, subject to DevBench's bounded
retention. Sequence admission also checks its planned duration and pose-sample
budget. The default `MaximumFrames` is 2400 (20 minutes at 500 ms), leaving
headroom in the 60,000-sample recording budget at the default 50 ms interval.
Input activity shares a separate tracking/activity budget and can exhaust it
earlier; retained limit diagnostics must be checked throughout a run.

Sequence receipts reference a partial or final manifest instead of inlining
children. Observation reads that manifest only inside the owned frames directory
and verifies its request identity. Image metadata comes from each committed
artifact's `actual` object; source and acquired frame come from the child's
`actual.acquisition`. A scheduled frame is retained separately. Source or
encoding mismatches suppress image submission and preserve the offending receipt.
This observation pointer does not replace an assay's full stereo-pair,
dimension, hash, provenance and image-quality validation.

Run the isolated contract fixtures with:

```powershell
pwsh -NoProfile -File .\Test-CaptureInteractionControl.ps1
```

The fixtures exercise the real controller with a fake transport, including
ownership changes, pending restoration, recording truncation, old schemas,
terminal screenshot failures and manifest source mismatches. They send no game
input and never contact a live DevBench server.
