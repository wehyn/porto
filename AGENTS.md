# Porto Agent Instructions

## Project

Porto is a lightweight macOS 26+ SwiftUI menu-bar utility for inspecting local network listeners and active connections, with user-triggered process termination.

## Delegation

The default is for the main agent to do the work. Delegate only when a task splits into at least two independent, bounded, non-overlapping workstreams with clear file ownership.

Do not delegate small tasks, sequential steps, or tightly coupled changes. Research, independent test suites, and code review may be parallelized when useful. Edits should normally be performed sequentially unless file ownership is clearly separated.

The main agent always owns planning, integration, and final verification across the combined result.

## Engineering workflow

- Inspect the actual files, runtime, and acceptance surface before making conclusions or changes.
- Preserve unrelated user work and generated files that are not part of the task.
- Use `apply_patch` for source and documentation edits.
- Keep changes focused and reversible.
- Validate the real macOS application after implementation; a build alone is not sufficient.
- Add tests for parsers, concurrency, process termination, and failure paths before declaring the feature complete.

## Porto-specific constraints

- Target macOS 26+ with SwiftUI `MenuBarExtra` and an XcodeGen-generated Xcode project.
- Keep the app menu-bar-only with no main window or Dock presence.
- Show listeners by default; keep active connections in a collapsed section.
- Use direct, machine-readable `/usr/sbin/lsof` output with `-nP`; do not invoke a shell or create one subprocess per row.
- Keep at most one scan in flight, pause scanning while the menu is closed, and refresh every 2 seconds while it is visible.
- Use SIGTERM for the `×` action first. Show a spinner while checking, then expose a separate Force Kill action only if the process remains alive; never send SIGKILL automatically.
- Revalidate process identity before signaling to protect against stale rows and PID reuse.
- Do not add privileged helpers, launch daemons, or elevated scans in v1.
- Keep visible row actions icon-only, while providing useful tooltips and accessibility labels.

## Git

- Keep commits focused and describe the behavior they introduce.
- Never commit `DerivedData`, build products, credentials, local machine state, or signing artifacts.
- Inspect the diff and run relevant tests before pushing.
