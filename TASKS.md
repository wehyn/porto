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
