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
