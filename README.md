# Porto

Porto is a macOS 26+ menu-bar utility for viewing local TCP/UDP listeners and
active connections. It uses the installed `/usr/sbin/lsof` directly and keeps
process termination behind identity and socket revalidation.

## Requirements

- macOS 26 or later
- XcodeGen 2.46.0 or a compatible XcodeGen release
- Xcode 26 with Swift language mode 6

The accepted local verification environment is macOS 27.0 (build 26A428),
Xcode 26.6 (build 17F113), Swift 6.3.3, and XcodeGen 2.46.0. Re-run the
command-contract and built-app checks when any of these versions or the
installed `lsof` changes.

`Porto.xcodeproj` is generated locally from `project.yml` and is intentionally
ignored by Git. DerivedData, build products, signing state, and machine-local
Xcode files are also ignored.

## Generate, test, and build

Run from the repository root:

```sh
xcodegen generate
xcodebuild -project Porto.xcodeproj -scheme Porto -destination 'platform=macOS' test
xcodebuild -project Porto.xcodeproj -scheme Porto -configuration Debug -destination 'platform=macOS' build
```

For unsigned CI, append `CODE_SIGNING_ALLOWED=NO` to the `xcodebuild` command.
The repository CI entry point is `scripts/ci.sh`; it checks the accepted Xcode
build before generating the project and running the test/build commands. Set
`PORTO_EXPECTED_XCODE_BUILD` only when intentionally accepting a newly audited
toolchain.

## Launch the generated app

After the Debug build, launch the app from DerivedData:

```sh
open ~/Library/Developer/Xcode/DerivedData/Porto-*/Build/Products/Debug/Porto.app
```

Porto is an agent/background menu-bar app, so it has no Dock icon or main
window. Click the `Porto` network status item to open the popover. Opening it
starts the first scan; while it remains visible, refreshes are requested every
2 seconds. These background updates are silent; the refresh button only indicates
a user-requested refresh. Closing it stops recurring scans. Use the overflow menu for About
Porto and Quit Porto.

The default view is developer-focused: it hides known macOS infrastructure plus
Zen and Discord helper processes by name, while keeping custom project ports
visible.
Listeners and active connections appear together in one list, sorted by local
port.

## Runtime acceptance

On the accepted macOS environment, verify that the menu-bar icon is present,
all visible activity appears in one list, rows show the process name with its
local port beneath it and no category or per-process disclosures, and scrolling
remains native. Use a disposable
current-user TCP server to exercise SIGTERM and a
SIGTERM-ignoring fixture to verify that Force Kill appears only after the grace
period and requires confirmation. Activity Monitor should show no normal
`lsof` child while the popover is closed and never more than one while it is
open.

No port/process data is persisted or sent over the network. Porto does not use
privileged helpers or elevated scans.
