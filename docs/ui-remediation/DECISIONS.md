# Architecture decisions — ZOO-01 remediation

## ADR-001 — Preview and confirm before any system mutation

**Status:** Accepted (implemented in commit `e5574fa7679219b44091a8c5ca75ffcb8cdbad9e`)

**Context.** The original button called `startFix()` directly. The sequence edits
`/etc/hosts`, firewall rules, DHCP leases, deletes user Zoom data, kills Zoom
processes, removes existing installs, downloads a package, and runs privileged
installer/permission/DNS commands. A user could trigger all of this with one tap
and no advance knowledge of the targets.

**Decision.** `prepareFixPreview()` runs first and only reads state. It produces
`FixPreviewItem` values typed as File / Process / Setting / Download. The view
renders them and offers **Confirm and Run** and **Cancel**. `confirmFix()` is the
only entry point into `prepareForRun()` + `runSequence()`, and it is guarded by
`isConfirmationPending`. `startFix()` was removed so no caller can bypass the
gate.

**Rejected alternatives.**

- *Immediate action with a one-line warning label*: does not tell the user what
  files, processes, or settings will change; fails the P0 requirement.
- *Generic `NSAlert` yes/no with static text*: cannot reflect the current
  machine state, so it would not be a meaningful preview.
- *Opt-out "don't ask again" toggle*: would let users silently re-enter the
  original unsafe flow; out of scope for a P0 fix.
- *Simulated/dry-run repair*: would not enumerate real detected targets and
  would duplicate the detectors, creating drift from the real sequence.

**Risks / residual work.** The preview reflects state at preview time; a process
or file can appear between preview and confirmation. The shared detector helpers
keep rule drift low, but the snapshot is not a transaction. The preview is text,
not a visual diff of file contents. Owner should confirm the level of detail is
sufficient for their users.

## ADR-002 — Cancellation by process termination plus step-boundary checks

**Status:** Accepted (implemented)

**Context.** `ShellExecutor` launched `Process` objects and blocked on
`waitUntilExit()`; there was no way to stop a running command. `Task.cancel()`
alone would not terminate a child shell/osascript process.

**Decision.** Introduce `ProcessRegistry`, shared by `ZoomFixService` and its
`ShellExecutor`. Every launched process is registered and unregistered around
`waitUntilExit()`. `cancelFix()` sets `isCancellationRequested` and calls
`cancelAll()`, which terminates running tracked processes. The executor checks
the registry flag immediately after launch to cover the gap between the run
loop's check and process start. The run loop checks the flag before each step
and after each step, marking subsequent steps `.skipped` and interrupted work
`.cancelled`. `reset()` is called at the start of preview and of each confirmed
run so a prior cancellation cannot kill read-only preflight commands or a later
run.

**Rejected alternatives.**

- *`Task.cancel()` only*: Swift task cancellation is cooperative; the detached
  `DispatchQueue` process would keep mutating the system.
- *Ignore cancellation until the current step finishes*: not a real cancellation
  path; a privileged install or large download can take significant time.
- *Transactional rollback / backup-and-restore of all targets*: much larger
  scope, would require elevated backups of `/etc/hosts`, firewall state, and
  application bundles, and is beyond this P0 UI remediation.

**Risks / residual work.**

- Terminating `osascript` may not terminate a shell script it already handed to
  a privileged execution context; no macOS runtime test was possible here.
- Cancellation does not undo mutations from steps that already succeeded. The
  UI says so explicitly, and the outcome marks partial/cancelled steps.
- A `Process` that exits between `isRunning` check and `terminate()` is benign
  (`terminate()` on an exited process is tolerated by Foundation).
- The shared registry flag is reset at preview/run start; concurrent runs are
  already prevented by `isRunning`/`isConfirmationPending` guards.

## ADR-003 — Outcome built from recorded step results

**Status:** Accepted (implemented)

**Context.** The previous `finish()` set a single boolean-derived status. Logs
contained errors but there was no structured post-action report, so users could
not tell which changes actually failed.

**Decision.** `runSequence()` accumulates `StepResult` values (`ok`, `failed`,
`cancelled`, `skipped`) with detail text. `finish(results:)` derives
`FixOutcomeState` and a summary from those results plus `[warn]` log lines.
The view lists failed steps, advisory warnings, and not-completed steps.

**Rejected alternatives.**

- *Keep a generic "Finished with warnings" banner*: cannot name failures.
- *Reuse the activity log as the outcome*: unstructured and easy to miss; the
  requirement is a post-action result surface.

**Risks / residual work.** Advisory checks (`checkTLSTrust`, `checkSIPStatus`)
set `hadErrors` but produce warnings rather than failed steps; the outcome
reports them under "Advisory warnings" and chooses `.completedWithWarnings`.
Owner should confirm that taxonomy matches expectations.

AI-Model: Big Pickle (opencode/big-pickle)
AI-Provider: opencode
AI-Role: Drafted
