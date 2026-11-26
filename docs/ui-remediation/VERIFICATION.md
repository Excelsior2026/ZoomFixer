# Verification record — ZOO-01 remediation

All results below are **static source verification** unless explicitly labeled
otherwise. No app was launched, no repair was executed, and no macOS UI was
rendered.

## Environment

- Worktree: `/Users/temporary/ui-ux-review/worktrees/wave2/Excelsior2026__ZoomFixer`
- Branch: `fix/ui-remediation/zoomfixer-p0`
- Baseline: `554c704cf961ed4b1edd2d2cb1dcf1ef6e1be079`
- Implementation commit: `e5574fa7679219b44091a8c5ca75ffcb8cdbad9e`
- Toolchain: Apple Swift 6.1.2 (`swift-driver 1.120.5`, target
  `x86_64-apple-macosx15.0`); SDK `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`
- `xcode-select -p` → `/Library/Developer/CommandLineTools`

## 1. Baseline gate — PASSED

Command (run before any edit):

```sh
git rev-parse HEAD && git status --short && git branch --show-current
```

Result:

```text
554c704cf961ed4b1edd2d2cb1dcf1ef6e1be079
fix/ui-remediation/zoomfixer-p0
```

(`git status --short` produced no lines: clean tree.)

## 2. Preview/confirmation path in the view — PASSED

Command:

```sh
grep -n -E 'prepareFixPreview|confirmFix|cancelPreview|cancelFix|previewItems|lastOutcome|Cancel Repair' ZoomFixer/Views/ContentView.swift
```

Result:

```text
17:                Button(action: viewModel.prepareFixPreview) {
43:                        if viewModel.previewItems.isEmpty {
49:                                    ForEach(viewModel.previewItems) { item in
68:                            Button("Confirm and Run") { viewModel.confirmFix() }
70:                            Button("Cancel") { viewModel.cancelPreview() }
92:                    Button("Cancel Repair") { viewModel.cancelFix() }
112:            if let outcome = viewModel.lastOutcome {
```

Assertion: the primary action calls the preview, not a mutating action; explicit
Confirm, preview Cancel, in-run Cancel, preview list, and outcome panel are all
present.

## 3. Service wiring and confirmation guard — PASSED

Command:

```sh
grep -n -E 'func prepareFixPreview|func buildPreview|func confirmFix|guard isConfirmationPending|func cancelFix|func cancelPreview|func clearOutcome|func finish\(results|isCancellationRequested|processRegistry.cancelAll|processRegistry.reset' ZoomFixer/Services/ZoomFixService.swift
```

Result:

```text
86:    private var isCancellationRequested = false
97:    func prepareFixPreview() {
99:        processRegistry.reset()
110:    private func buildPreview() async {
216:    func confirmFix() {
217:        guard isConfirmationPending, !isRunning else { return }
228:    func cancelPreview() {
229:        guard isConfirmationPending else { return }
239:    func cancelFix() {
241:        isCancellationRequested = true
243:        processRegistry.cancelAll()
251:    func clearOutcome() {
291:            if isCancellationRequested {
303:                if isCancellationRequested {
311:                if isCancellationRequested {
955:        processRegistry.reset()
956:        isCancellationRequested = false
984:    private func finish(results: [StepResult]) {
1014:        cancellationRequested = isCancellationRequested
```

Assertion: only `confirmFix()` enters the run, and it requires
`isConfirmationPending`; `prepareForRun()` resets both cancellation flag and
registry before each confirmed run.

## 4. No bypass of the confirmation gate — PASSED

Command:

```sh
grep -rn 'startFix' ZoomFixer; echo "grep_exit=$?"
```

Result:

```text
grep_exit=1
```

Assertion: no `startFix` symbol remains in the compiled source, so no direct
call can skip preview/confirmation.

## 5. Preview performs read-only inspection only — PASSED

Command:

```sh
sed -n '/private func buildPreview/,/^    }$/p' ZoomFixer/Services/ZoomFixService.swift | grep -nE 'readOnlyOutput|shell.run'
```

Result:

```text
5:        let hosts = await readOnlyOutput("cat /etc/hosts 2>/dev/null || true")
27:        let interfaces = apipaInterfaces(in: await readOnlyOutput("ifconfig -a 2>/dev/null || true"))
37:        let processOutput = await readOnlyOutput("pgrep -fl 'zoom.us' 2>/dev/null || true")
59:        let preferenceOutput = await readOnlyOutput("printf '%s\\n' \"$HOME\"/Library/Preferences/us.zoom.* 2>/dev/null || true")
68:        let foundPaths = await readOnlyOutput(zoomInstallationDiscoveryCommand())
```

`zoomInstallationDiscoveryCommand()` is
`find /Applications "$HOME/Applications" "$HOME/Library/Application Support" -maxdepth 4 -iname "zoom*.app" 2>/dev/null`.
No `rm`, `installer`, `pkill`, `killall`, `ipconfig set`, `chown`, `chmod`, or
`requireAdmin: true` call occurs in `buildPreview`. Preview and repair share
`zoomBlockingHostLines(in:)`, `apipaInterfaces(in:)`,
`zoomApplicationCandidates()`, and `zoomInstallationDiscoveryCommand()`, so the
listed targets are derived from the same rules used by the mutation steps.

## 6. Cancellation path trace — PASSED

Command:

```sh
grep -n -E 'func cancelAll|process.terminate\(\)|isCancellationRequested|registry.register|registry.unregister|func reset' ZoomFixer/Helpers/ShellExecutor.swift
```

Result:

```text
32:    var isCancellationRequested: Bool {
40:    func reset() {
46:    func cancelAll() {
53:            process.terminate()
151:        let token = registry.register(process)
153:            registry.unregister(token)
158:        if registry.isCancellationRequested && process.isRunning {
159:            process.terminate()
```

Trace: `ContentView.swift:92` → `ZoomFixService.cancelFix()` (`:239-246`,
sets flag and calls `processRegistry.cancelAll()`) → `ProcessRegistry.cancelAll()`
(`ShellExecutor.swift:46-54`, sets flag and terminates active processes) →
`ShellExecutor.runProcessSync()` (`:151-159`, registers every process, unregisters
on exit, and terminates a process launched after cancellation was requested) →
`runSequence()` (`ZoomFixService.swift:290-322`, skips unstarted steps and marks
interrupted steps `.cancelled`) → `finish(results:)` (`:984-1016`, builds the
outcome with `.cancelled` state and skipped-step list).

## 7. Swift syntax / type check — PASSED (static only)

Commands:

```sh
swiftc --version
swiftc -frontend -parse ZoomFixer/Views/ContentView.swift ZoomFixer/Services/ZoomFixService.swift ZoomFixer/Helpers/ShellExecutor.swift ZoomFixer/Services/DownloadService.swift ZoomFixer/ZoomFixerApp.swift
swiftc -typecheck -sdk "$(xcrun --show-sdk-path)" -target x86_64-apple-macosx12.0 ZoomFixer/ZoomFixerApp.swift ZoomFixer/Views/ContentView.swift ZoomFixer/Services/ZoomFixService.swift ZoomFixer/Services/DownloadService.swift ZoomFixer/Helpers/ShellExecutor.swift ZoomFixer/Helpers/PrivilegedHelper.swift > /tmp/zoomfix_typecheck3.log 2>&1
```

Results:

```text
swiftc --version:
swift-driver version: 1.120.5 Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)
Target: x86_64-apple-macosx15.0

swiftc -frontend -parse: exit 0, no output
swiftc -typecheck: exit=0, errors=0, warnings=11
```

The same two commands were re-run after the final source edit (the registry
reset in `prepareFixPreview()`): `parse_exit=0`, `typecheck_exit=0`, `errors=0`,
`warnings=11`.

Warning parity check. Baseline sources were extracted from the baseline commit
with:

```sh
mkdir -p /private/var/folders/_l/bsf9jt7s65g187mlr93kbzk40000gp/T/opencode/zoomfix_baseline
git archive HEAD | tar -x -C /private/var/folders/_l/bsf9jt7s65g187mlr93kbzk40000gp/T/opencode/zoomfix_baseline
```

(the second command was run while HEAD was still the baseline commit), then the
same `swiftc -typecheck` command was run in that directory:

```text
baseline: exit=0, errors=0, warnings=11
remediated: exit=0, errors=0, warnings=11
diff of normalized warning lines: no output
```

Assertion: no new compiler warnings were introduced. This is a source-level
type check, **not** a SwiftUI render, app launch, or Xcode build.

## 8. Xcode build / sign — BLOCKED

Command:

```sh
xcodebuild -list -project ZoomFixer.xcodeproj
```

Result (exit 1):

```text
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

Exact reason: only Command Line Tools are installed; full Xcode (and its
SwiftUI build/signing toolchain) is unavailable in this environment. No build,
archive, code-signing, or runtime claim is made.

## 9. Runtime / visual / interaction verification — NOT RUN

- App launch and manual click-through: not run (no Xcode/macOS UI session here).
- Real system mutation test: intentionally not run; it would alter host
  configuration, firewall, and installed applications.
- Cancellation under a live privileged prompt: not run. This is the main
  residual risk (see `docs/ui-remediation/DECISIONS.md`, ADR-002).
- Docker sandbox flows: unchanged and not exercised.

## Failures encountered and lessons

- First typecheck pass introduced 12 new warnings (11 "no async operations
  occur within await" from marking the sequence `@MainActor`, plus one
  non-sendable `ShellExecutor` capture). Fixed by removing redundant `await`
  calls on main-actor helpers and conforming `ProcessRegistry` to
  `@unchecked Sendable` (lock-protected) and `ShellExecutor` to `Sendable`.
  Final warning count equals the baseline's 11.
- Review found that `ProcessRegistry`'s cancellation flag would survive into a
  subsequent preview after a cancelled run and terminate read-only preflight
  commands. Fixed by calling `processRegistry.reset()` in
  `prepareFixPreview()` as well as `prepareForRun()` before committing.
- `xcodebuild` is unavailable with the active developer directory; this was
  recorded as a blocker rather than worked around with a build claim.

## Residual risks needing owner decision

1. Confirm that text preflight detail is sufficient (ADR-001).
2. Confirm cancellation semantics for privileged `osascript` child processes
   and accept that completed steps are not rolled back (ADR-002).
3. Confirm warning/failure taxonomy for advisory checks (ADR-003).

## Summary

| Check | Classification |
| --- | --- |
| Baseline HEAD/branch/clean tree gate | PASSED |
| Preview + confirm wiring in view | PASSED |
| Confirmation guard in service; no bypass | PASSED |
| Read-only preview commands | PASSED (static) |
| Cancellation path end to end | PASSED (static source trace) |
| Swift parse and typecheck | PASSED (static; 0 errors, 11 warnings = baseline) |
| Xcode build and signing | BLOCKED (Xcode not installed) |
| Runtime / visual / real mutation test | NOT RUN |
| Findings remaining | ZOO-01 addressed in source; owner acceptance pending |

AI-Model: Big Pickle (opencode/big-pickle)
AI-Provider: opencode
AI-Role: Authored verification record
