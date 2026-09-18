# Porto Sparkle automatic updates execution ledger

Source of truth: `docs/09-16-2026-porto-sparkle-auto-update-spec.md`.

Release-sensitive work was completed only after the user authorized it. The
private key remains outside the repository; the public key, GitHub secret,
bridge version, tag, workflow, and published release were verified.

| ID | Objective | Owner | Scope | Status | Acceptance checks | Verification evidence | Commit/branch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | Add pinned Sparkle dependency and configuration contract | Root/worker | `project.yml`, `Porto/Resources/Info.plist`, configuration tests | DONE | Sparkle 2.9.2 resolves; plist contract tests pass; production key remains outside the repository | Fresh `plutil -lint`: OK; `xcodebuild -resolvePackageDependencies`: Sparkle @ 2.9.2; focused test: 1/1 passed; public key updated and GitHub secret configured after authorization | `b4e5ae3` |
| S2 | Add testable updater service and menu action | Root/worker | `Porto/Updates`, `PortoApp`, `PortPopoverView`, updater tests | DONE | Debug does not start/check production updater; enabled/disabled/state tests pass; menu action has source/accessibility coverage | Fresh focused tests: 10/10 passed; Debug build and exact app launch succeeded with no network handles or child processes; visual menu inspection was unavailable for the menu-bar-only surface | `b4e5ae3` |
| S3 | Add safe appcast wrapper and shell tests | Parfit/Root | `scripts/generate-sparkle-appcast.sh`, wrapper tests, `scripts/ci.sh` | DONE | stdin-only key path, validation/failure cases, CI hook pass | `zsh -n` passed; focused wrapper test passed; `git diff --check` passed; worker also reported `./scripts/ci.sh` with 174 XCTest cases and Debug build success | `b4e5ae3` |
| S4 | Extend unsigned tag workflow | Dewey/Root | `.github/workflows/unsigned-release.yml` | DONE | version/tool/archive/appcast checks are encoded; published workflow verified | YAML parse passed; extracted workflow shell blocks passed `bash -n`; workflow run 35048424039 passed all steps and published exactly three assets | `b4e5ae3` |
| S5 | Document update operations and trust boundary | Bernoulli/Root | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, base spec | DONE | user/maintainer/security docs align with the implemented release flow | Worker ran `git diff --check`, Markdown fence sanity checks, targeted stale/overclaiming searches, and verified its four-file scope | `b4e5ae3` |
| S6 | Prepare bridge release and publish | Root | version/key/secret/tag/release acceptance | DONE | v1.0.2/build 3 bridge is packaged and published with a verified signed appcast | Keychain export corrected; GitHub secret configured; local and published ZIP/checksum, appcast/archive signatures, exact assets, and stable latest feed verified; tag `v1.0.2` and workflow run 35048424039 succeeded | `fb98329`; tag `v1.0.2` |

# Porto battery-efficient monitoring execution ledger

Source of truth: `docs/plans/2026-09-18-20-21-porto-battery-efficiency.md`.

This section tracks the three bounded implementation sub-projects and the
final documentation/runtime acceptance pass. The existing Sparkle ledger above
is preserved unchanged.

| ID | Objective | Owner | Scope | Status | Acceptance checks | Verification evidence | Commit/branch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | Define adaptive cadence policy and per-target stability state | Root/worker | `RefreshCadencePolicy`, `TargetMonitorState`, focused policy tests | DONE | Exact normal/Low Power/failure sequences pass; `git diff --check` passed | Root fresh focused XCTest: 4/4 passed; `git diff --check` passed | `b24d0ce` |
| B2 | Integrate adaptive scheduling and initial-loading state | Root/worker | `PortMonitor` and monitor lifecycle tests | DONE | Adaptive success/failure delays, Low Power, reset, closure, and coalescing tests pass | Root fresh `PortMonitorTests`: 16/16 passed; Debug build and `git diff --check` passed | `f2ae75d` |
| B3 | Cache remote Docker metadata behind fixed scan commands | Root/worker | `SSHCommandRunner`, `RemotePortScanner`, remote tests | DONE | Exact command contracts, cache expiry/manual forcing, Docker-query failure protection, cancellation, and identity tests pass | Root fresh SSH/scanner/terminator suites: 44/44 passed after explicit Docker status-marker fix; `git diff --check` passed | `b3e302d`; follow-up `34655c0` |
| B4 | Reduce SwiftUI publication and selector/row work | Root/worker | `PortMonitor`, `PortPopoverView`, `PortProcessRow`, UI/accessibility tests | DONE | Meaningful-change publication, initial loading, row actions/accessibility, and selector behavior pass | Root fresh focused UI/monitor XCTest: 24/24 passed; `git diff --check` passed | `b6f7c8e` |
| B5 | Synchronize specifications and verify the real app | Root | two source-of-truth specs, optional README, CI, Debug app lifecycle | IN_PROGRESS | `./scripts/ci.sh`, build, closed/open menu-bar lifecycle, child-process, and final diff checks pass | `./scripts/ci.sh`: 190/190 XCTest cases passed, Debug build passed, Sparkle appcast tests passed; exact Debug app launch and closed-state child/socket probe passed; `git diff --check` passed. The native UI bridge timed out binding to the menu-bar-only app, so popover-open/manual/35-second live observations remain unverified. | docs `778064e`; code follow-up `34655c0` |

# Porto grouped process rows execution ledger

Source of truth: `docs/plans/2026-09-18-20-56-grouped-process-rows.md`.

This ledger tracks the shared aggregation contract, local and remote scanner
integration, identity-safe termination, and final app acceptance. It does not
replace the plan or permit workers to edit shared execution state.

| ID | Objective | Owner | Scope | Status | Acceptance checks | Verification evidence | Commit/branch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | Update the source-of-truth grouping contract | Root/docs worker | `docs/09-12-2026-porto-macos-port-monitor-spec.md`, adjacent docs only if stale | DONE | Grouped normal process rows, Docker boundaries, visibility/revalidation, counts, and acceptance cases are explicit; unrelated dirty files preserved | Worker adjacent-doc search and root fresh `git diff --check -- docs/09-12-2026-porto-macos-port-monitor-spec.md README.md docs/09-13-2026-porto-manual-remote-server-profiles-spec.md` passed; only the two specs changed | — |
| G2 | Add shared aggregation tests and implementation | Worker/Root | `PortoTests/PortProcessGroupingTests.swift`, `Porto/Services/PortProcessGrouping.swift`, model comments if needed | DONE | Red test observed before production code; local/remote grouping, safety boundaries, stable IDs, deterministic sorting pass | Worker RED: missing API; root final focused shared suite: 10/10 passed after stable-ID/display-name and local-unverified fallback refinements; `git diff --check` passed | — |
| G3 | Integrate local scanner publication and validation | Worker | `Porto/Services/PortScanner.swift`, `PortoTests/PortScannerGroupingTests.swift`, local existing tests only if required | DONE | Red scanner tests observed; grouped listener/connection publication, multi-port validation, same-name PID separation pass | Worker RED: 4 tests/7 assertion failures; root final focused local grouping suite: 4/4 passed; full CI retained all local scanner coverage at 211/211; `git diff --check` passed | — |
| G4 | Integrate remote visible and revalidation snapshots | Worker | `Porto/Services/RemotePortScanner.swift`, `PortoTests/RemotePortScannerTests.swift` | DONE | Normal listeners/connections group; Docker cases stay intact; hidden ports remain in grouped revalidation snapshot | Worker RED: 22 tests/9 assertion failures; root final focused remote scanner suite: 22/22 passed, with shared grouping 10/10; hidden/visible IDs and Docker coverage passed | — |
| G5 | Extend remote aggregate termination revalidation | Worker/Root | `Porto/Services/RemoteProcessTerminator.swift`, optional `PortMonitor.swift`, `PortoTests/RemoteProcessTerminatorTests.swift` | DONE | Full represented port/transport/endpoint/socket subset is checked fail-closed; SIGTERM/Force Kill safety remains intact | Fresh focused termination tests: 16/16 passed; full CI retained the existing local/remote monitor and SIGTERM/Force Kill coverage; root audit confirmed `PortMonitor` remains process/container scoped with strict initiating-row identity comparison | — |
| G6 | Verify UI count and accessibility contract | Root/Tester | `Porto/Views/PortPopoverView.swift`, `Porto/Views/PortProcessRow.swift`, focused accessibility tests | DONE | Existing row rendering and listenerRows/connectionRows count source remain correct; focused tests pass | Final focused selection: 59/59 passed, including 7 accessibility tests; source audit confirmed grouped ports/transports/endpoints remain visible and Connections stays collapsed by default | — |
| G7 | Independent grouped-row verification and review | Tester/Root | Combined diff and focused/full test surfaces | DONE | Fresh targeted suites, `git diff --check`, and independent review findings resolved | Independent tester reported 125/125 targeted tests and fresh CI success; root final focused selection passed 59/59, final CI passed 211/211, `git diff --check` passed, and root source/diff audit found no actionable issue. Reviewer delegates did not return, so no reviewer findings are claimed | — |
| G8 | Full CI and real app acceptance | Root | `./scripts/ci.sh`, Debug build/launch, final worktree | DONE_WITH_LIMITATION | Full suite/build pass; actual menu-bar surface checked where available; residual manual limits recorded | Final `./scripts/ci.sh`: 211/211 XCTest cases, Debug build, and Sparkle checks passed. The rebuilt dedicated Debug app launched through the `PORTO_DEBUG_POPOVER=1` harness; CUA inspection showed grouped local rows and the collapsed/expanded Connections count. Live remote homeserver/VPS cases remain unverified because no live profile was available | — |
