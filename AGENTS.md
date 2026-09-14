# Porto Agent Instructions

## Project

Porto is a lightweight macOS 26+ SwiftUI menu-bar utility for inspecting local
network listeners and active connections, optionally inspecting one selected
Linux profile over SSH, with user-triggered process termination.

Use `docs/09-13-2026-porto-manual-remote-server-profiles-spec.md` as the source
of truth for remote setup behavior; keep README.md user-facing and consistent
with the checked-in implementation.

## Delegation

The default is for the main agent to do the work. Delegate only when a task splits into at least two independent, bounded, non-overlapping workstreams with clear file ownership.

Do not delegate small tasks, sequential steps, or tightly coupled changes. Research, independent test suites, and code review may be parallelized when useful. Edits should normally be performed sequentially unless file ownership is clearly separated.

The main agent always owns planning, integration, and final verification across the combined result.

## Engineering workflow

- Inspect the actual files, runtime, and acceptance surface before making conclusions or changes.
- Preserve unrelated tracked and untracked work; do not overwrite, reset, clean,
  or remove it unless that action is explicitly in scope.
- Use `apply_patch` for source and documentation edits.
- Keep changes focused and reversible.
- Run the canonical `./scripts/ci.sh` verification for implementation changes, plus focused checks for the changed subsystem.
- For user-visible or runtime behavior changes, validate the real macOS application; a build alone is not sufficient. Do not require unrelated test categories when they are outside the changed subsystem.

## Porto-specific constraints

- Target macOS 26+ with SwiftUI `MenuBarExtra` and an XcodeGen-generated Xcode project.
- Keep the app menu-bar-only with no main window or Dock presence; a native secondary Settings window is permitted.
- Show listeners by default; keep active connections in a collapsed section.
- For local scanning, invoke `/usr/sbin/lsof` directly with machine-readable `-nP` output; do not invoke a local shell or create one subprocess per row. Remote scanning may use only the reviewed, source-defined command over direct SSH, with no UI-provided interpolation.
- Keep at most one scan in flight, pause normal scanning while the menu is
  closed, and refresh every 2 seconds while it is visible.
- Use SIGTERM for the `×` action first. Show a spinner while checking, then expose a separate Force Kill action only if the process remains alive; never send SIGKILL automatically.
- Revalidate macOS `ProcessIdentity` and the targeted socket before signaling
  local processes; immediately before remote signaling, validate the
  target-scoped process/socket identity or container identity.
- Do not add privileged helpers, launch daemons, or elevated scans in v1.
- Keep visible row actions icon-only, while providing useful tooltips and accessibility labels.

## Git

- Keep commits focused and describe the behavior they introduce.
- Never commit generated artifacts such as `DerivedData` or build products, credentials, local machine state, or signing artifacts.
- Inspect the diff and run relevant tests before pushing; push only when explicitly requested.
