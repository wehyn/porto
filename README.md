# Porto

Porto is a macOS 26+ menu-bar utility for viewing TCP/UDP listeners and active
connections on This Mac or one selected Linux host. It uses the installed
`/usr/sbin/lsof` directly for local inspection and OpenSSH plus Linux `ss` for
remote inspection. Local and eligible remote termination remains behind
identity and socket/container revalidation.

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
a user-requested refresh. Closing it cancels the refresh loop, pending scans,
and any in-progress remote control workflow. Use the overflow menu for
Settings, About Porto, and Quit Porto.

The default view is developer-focused for This Mac: it hides known macOS
infrastructure plus Zen and Discord helper processes by name, while keeping
custom project ports visible. Remote targets hide common host-service ports
(22, 53, 80, 123, 137–139, 161–162, 443, 445, and 5353) while keeping custom
project ports visible. Remote `Unknown process` rows are hidden; every Docker
row and every published Docker host port is retained—even when it uses a common
host-service port—and the display name is the container name without the
generated `Docker ·` prefix. Docker display names are presentation-only and are
never used as control targets. IPv4/IPv6, TCP/UDP,
and multiple published host-port records for the same target, container ID, and
activity kind are shown as one logical row. The row lists each host port once
(for example, `53, 80`) and combines protocol and endpoint details; different
containers remain separate even when their visible names match. The filter is
applied after parsing, so scan diagnostics still account for every valid remote
record. Rows without a usable Docker ID stay at socket-level granularity.
Listeners appear first, with active connections in a collapsed section, sorted
by the first local port in each row.

OrbStack runs on this Mac rather than as a separate remote target. Its
host-published listeners are included in the This Mac scan while OrbStack is
running and disappear when it is stopped. Porto keeps OrbStack's generated
`orb` SSH alias available as an explicit proposal, while omitting the
key-only `github.com` entry.

## Remote Linux targets

Porto discovers literal Linux aliases from `~/.ssh/config` when the popover
opens. It does not connect or run `Match exec` just to populate the picker.
Wildcard, negated, and `Match`-only entries are ignored; the key-only
`github.com` entry is also omitted. Other aliases, including OrbStack's
local-only `orb`, are sorted and passed to OpenSSH exactly as configured. To
add a remote target, configure it in OpenSSH first:

```sshconfig
Host porto-linux
    HostName 192.0.2.10
    User wayne
    IdentityFile ~/.ssh/id_ed25519
```

The selected alias is used with `/usr/bin/ssh` and the user's existing agent,
keys, port, `ProxyJump`, and known-host configuration. Porto is noninteractive:
password/passphrase prompts are disabled, and the host key must already be
trusted through normal OpenSSH verification. User-configured `ProxyCommand`,
`KnownHostsCommand`, and other SSH helpers remain part of the user's trust
boundary and may have their own side effects.

Each visible remote refresh launches the following bounded command. The alias
is one argument after `--`; the remote command is a source-code constant and is
never built from UI input:

```text
/usr/bin/ssh -T -n -o BatchMode=yes -o ConnectTimeout=3 -o ConnectionAttempts=1 -o NumberOfPasswordPrompts=0 -o PermitLocalCommand=no -o ClearAllForwardings=yes -o RequestTTY=no -o RemoteCommand=none -o ControlMaster=no -o ControlPath=none -- <literal-alias> LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c 'ss -H -n -O -a -t -u -p -e; ss_status=$?; printf "__PORTO_DOCKER__\n"; if command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then timeout -k 1 1 docker ps --format "{{.ID}}\t{{.Names}}\t{{.Ports}}" 2>/dev/null || true; fi; exit "$ss_status"'
```

The Linux host must provide an `ss` implementation with the fixed iproute2
options shown above. Porto optionally reads published ports with a bounded
`docker ps` query when the configured SSH account can access both Docker and
the existing `timeout` utility; containers without a published host port are
not represented by that metadata. A Docker metadata timeout or failure never
changes the `ss` result. Ownerless non-Docker rows are hidden unless they match
a published Docker port. Eligible remote process rows can be controlled
through the validated Linux PID and socket identity. Eligible Docker rows are
controlled at container level through a validated container ID; Porto never
falls back to a Docker host PID and never uses the display name as a target.
The SSH account must have permission to signal the process or use the Docker
CLI/daemon. Porto does not install helpers, invoke `sudo`/`doas`, change
configuration, or bypass permissions; unavailable capabilities leave the row
visible with controls disabled or an explanatory failure.

Remote control is one bounded, cancellable workflow shared by scans and signal
operations. The `×` action revalidates the target before sending SIGTERM, then
checks for exit for up to 2 seconds. Force Kill is a separate, explicit,
confirmed action that performs fresh validation before SIGKILL; Porto never
escalates automatically. Closing the popover cancels the active workflow and
its SSH child, and no stale result or signal may publish afterward.

Remote scans run only while the popover is visible (or after an explicit retry).
Completion schedules the next visible refresh after 2 seconds. Failures use
bounded backoff of 2, 4, 8, 16, then 30 seconds. One successful snapshot per
target is retained in memory until Porto quits; a failed refresh shows that
target's last results as stale and never replaces them with an empty list.
Remote scans use short-lived SSH children; Porto does not present a persistent
connection state. A listener is evidence on the selected server, not a
reachability or public-exposure test.

Troubleshooting follows the status shown in the popover: add a literal alias if
the picker is empty; establish the host key and noninteractive credentials with
the normal `ssh <alias>` workflow; check that the host is reachable; and verify
that `ss -H -n -O -a -t -u -p -e` works for the configured Linux user. Porto does
not display or store raw SSH stderr, endpoints, process lists, or snapshots.

## Runtime acceptance

On the accepted macOS environment, verify that the menu-bar icon is present,
all visible activity appears in one list, rows show the process name with its
local port or ordered host-port list beneath it and no category or per-process disclosures, and scrolling
remains native. Use a disposable
current-user TCP server to exercise SIGTERM and a
SIGTERM-ignoring fixture to verify that Force Kill appears only after the grace
period and requires confirmation. Activity Monitor should show no normal
`lsof` child while the popover is closed and never more than one while it is
open.

Porto does not persist port/process data or collect telemetry. Selecting a
remote target intentionally sends the fixed scan or validated control command
through the user's SSH configuration; This Mac scans remain local and Porto
does not make any other network requests. Porto does not use privileged helpers
or elevated scans.
