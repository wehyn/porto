# Contributing to Porto

Porto is a macOS 26+ SwiftUI menu-bar utility. Contributions should preserve
the narrow product scope and the safety boundaries documented in `AGENTS.md`
and the specifications under `docs/`.

## Development environment

- macOS 26 or later
- Xcode 26.6 with Swift language mode 6
- XcodeGen 2.46.0

The generated `Porto.xcodeproj`, DerivedData, build products, signing state,
and local Xcode files are intentionally ignored. Run `xcodegen generate` after
adding or removing Swift source files.

## Verification

From the repository root, run the canonical checks:

```sh
./scripts/ci.sh
```

To create a local unsigned Release ZIP for manual inspection:

```sh
./scripts/package-unsigned.sh
```

The resulting files are written to `dist/`, which is ignored by Git.

## Change expectations

- Keep local scans on direct `/usr/sbin/lsof` execution.
- Keep remote scans on the reviewed fixed SSH command; do not interpolate UI
  text into remote commands.
- Preserve process, socket, and container revalidation before signaling.
- Keep SIGTERM as the first action and Force Kill as a separate confirmed
  action. Never add automatic SIGKILL escalation.
- Add focused regression tests for parser, identity, cancellation, SSH command,
  or process-control changes.
- Keep visible row controls icon-only while retaining tooltips and accessibility
  labels.

Please describe the user-visible behavior and verification performed in pull
requests. Do not include private SSH output, host details, key material, or
local machine state in commits or issue reports.
