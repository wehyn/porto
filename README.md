# Porto

Porto is a macOS 26+ menu-bar utility for viewing TCP/UDP listeners and active
connections on This Mac or one selected Linux host. It uses the installed
`/usr/sbin/lsof` for local inspection and OpenSSH plus Linux `ss` for remote
inspection. Local and eligible remote termination is protected by process,
socket, and container revalidation.

## Requirements

- macOS 26 or later
- XcodeGen 2.46.0 or a compatible XcodeGen release
- Xcode 26 with Swift language mode 6

The last-verified environment is macOS 27.0 (build 26A428), Xcode 26.6 (build
17F113), Swift 6.3.3, and XcodeGen 2.46.0. Repository CI currently selects
macOS 26 with Xcode 26.6 and checks the Xcode build identifier; it does not
independently validate every version listed here. Recheck the command contract
and built app when the environment changes. `Porto.xcodeproj` is generated from
`project.yml` and is ignored by Git, as are DerivedData, build products, signing
state, and local Xcode files.

## Verify and build

The canonical repository verification path generates the project, runs tests,
and performs an unsigned Debug build:

```sh
./scripts/ci.sh
```

For a deterministic local Debug app build outside that CI path, run from the
repository root:

```sh
xcodegen generate
xcodebuild -project Porto.xcodeproj -scheme Porto -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/PortoDerivedData build
```

Append `CODE_SIGNING_ALLOWED=NO` for an unsigned build. The CI script already
uses that setting. Set `PORTO_EXPECTED_XCODE_BUILD` only when intentionally
accepting a newly audited Xcode build.

## Launch the generated app

After the deterministic local Debug build above, launch the app with:

```sh
open .build/PortoDerivedData/Build/Products/Debug/Porto.app
```

Porto is a background menu-bar app with no Dock icon or main application window;
Settings opens as a native secondary window. Click the network status item to
open the popover. Opening it starts a scan; while it is visible, refreshes are
requested every 2 seconds. Closing it cancels the refresh loop, pending scans,
and active remote control workflow. The overflow menu contains Settings, About
Porto, and Quit Porto.

The activity view has one body: listeners appear first, and active connections
are in a collapsed section. Rows are not individually expandable. Rows show
the process or container name with its local port or ordered published-port
list beneath it. For remote published-Docker rows, IPv4/IPv6, TCP/UDP, and
matching published ports may be combined into one logical Docker row; different
containers remain separate.
Common infrastructure ports are hidden according to the target, while custom
project ports remain visible. Docker-published remote rows and their published
host ports remain visible even when they use a common port. Docker display names
are presentation-only and are never control targets.

On This Mac, Porto reports the actual local process names returned by `lsof`.
Docker and OrbStack host-side listeners are therefore local host processes, not
remote container rows or renamed container names. OrbStack's published
listeners appear in the This Mac scan while OrbStack is running.

## Remote Linux profiles

Porto always starts on **This Mac**. Add remote server profiles in Settings
using a display name, host, username, port, and optional private-key path. New
profiles are disabled; enabling one makes it available in the target picker,
and selecting it starts inspection of that profile. SSH configuration is used
only to discover and import connection candidates in Settings. It is not a
runtime target-selection mechanism.

At runtime, Porto connects directly to the saved host, username, and port,
using the optional saved key plus the user's inherited SSH agent and
known-host trust. It does not resolve aliases or apply `ProxyJump`,
`ProxyCommand`, `Match`, `Include`, or other SSH-config directives at runtime.
Password and passphrase prompts are disabled, and the host key must already be
trusted through normal OpenSSH verification. The remote command is a fixed,
bounded `ss` inspection with optional bounded Docker publication metadata; it
is not assembled from profile display text. The detailed contract is in
[`docs/09-13-2026-porto-manual-remote-server-profiles-spec.md`](docs/09-13-2026-porto-manual-remote-server-profiles-spec.md)
and [`SSHCommandRunner.swift`](Porto/Services/SSHCommandRunner.swift).

Remote targets hide common host-service ports (22, 53, 80, 123, 137–139,
161–162, 443, 445, and 5353), retain custom project ports, and hide ownerless
non-Docker rows. A remote Docker-published row may be controlled only through
a validated container ID; Porto never falls back to a Docker host PID or uses
the display name as a target. Other eligible remote process rows use validated
Linux process and socket identity. The SSH account must have the required
inspection, signaling, or Docker permissions. Porto does not install helpers,
use `sudo`/`doas`, or bypass permissions.

The `×` action sends SIGTERM after revalidation and checks for exit for up to 2
seconds. Force Kill is a separate, explicit, confirmed action that performs
fresh validation before SIGKILL; Porto never escalates automatically. Closing
the popover cancels the workflow, and stale results or signals are not allowed
to publish afterward.

Normal remote scans run only while the popover is visible. Explicit user
actions, such as Retry or Test Connection for an enabled profile, may start a
bounded SSH request.
Failures use bounded backoff. One successful parsed snapshot per target may be
retained in memory until Porto quits, so a failed refresh can show stale rows;
a failed refresh never replaces those rows with an empty list. Porto does not
persist or log raw command output. It makes no network requests other than SSH
operations intentionally started for a selected or explicitly tested profile.

## Troubleshooting

If the target picker is empty, add or import a profile in Settings and enable
it. Check that the saved host, username, port, optional key, agent, and
known-host trust are correct, then test the profile from Settings. Confirm the
Linux account can run `ss -H -n -O -a -t -u -p -e`; for Docker rows, confirm it
can access the Docker CLI and daemon. A listener is evidence on the selected
server, not a reachability or public-exposure test.

## Runtime acceptance

On the accepted macOS environment, verify the menu-bar icon, the single
activity body, listener-first ordering, collapsed connections section, native
scrolling, and non-expandable rows. Use a disposable current-user TCP server
to exercise SIGTERM and a SIGTERM-ignoring fixture to verify that Force Kill
appears only after the grace period and requires confirmation. Activity Monitor
should show no normal `lsof` child while the popover is closed and never more
than one while it is open.

For remote acceptance, verify that Porto starts on This Mac, connects only
after a profile is enabled and selected, uses noninteractive direct SSH, and
keeps controls disabled when remote identity or permissions cannot be verified.

Porto does not persist port/process data or collect telemetry. It does not use
privileged helpers or elevated scans.
