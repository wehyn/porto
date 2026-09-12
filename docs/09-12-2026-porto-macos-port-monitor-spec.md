# Porto macOS Port Monitor Product and Engineering Specification

- **Status:** Implementation ready
- **Date:** September 12, 2026
- **Product:** Porto
- **Platform:** macOS 26 and later
- **Audience:** Product, design, engineering, and QA

## 1. Purpose

Porto is a lightweight, menu-bar-only macOS utility for developers who need to
see which local processes are listening on ports or holding active Internet
connections and, when necessary, stop one of those processes. It can also
inspect one selected Linux host over SSH; that remote view is read-only and
never participates in process termination.

This specification defines the v1 product behavior, architecture, data contract, process-safety rules, error handling, performance limits, test coverage, and release acceptance criteria. **Must** is release-blocking, **should** requires a documented reason to omit, and **may** is optional.

## 2. Goals and success criteria

### 2.1 Goals

- Show useful local port activity within one click of the menu-bar icon.
- Show listeners and active connections together in one focused view without category controls.
- Refresh while the user is viewing the list without continuously polling in the background.
- Let the user request a graceful process stop and deliberately escalate to force kill only when necessary.
- Let the user select one literal SSH alias and inspect Linux TCP/UDP activity without remote controls.
- Remain responsive and low-overhead on a busy development machine.
- Protect against stale rows and PID reuse before every signal.

### 2.2 Release success criteria

V1 is acceptable only when all of the following are true:

- Opening Porto immediately starts a scan and presents current rows, a first-load state, or an actionable scan error.
- All visible listener and connection rows appear in one unified list with no category disclosure controls.
- This Mac remains the default target; a selected remote target hides configured common host-service ports, retains other valid rows, and marks visible rows read-only.
- Results refresh every 2 seconds while the popover is open and do not refresh while it is closed.
- There is never more than one Porto-owned local `lsof` or remote SSH scan child in flight.
- Normal stop never sends SIGKILL. Force Kill is unavailable until SIGTERM has failed to end the revalidated process within the defined grace period.
- Every signal attempt revalidates immutable process identity and the selected port activity.
- The generated `.app` is launched and exercised on macOS 26; a successful build alone is not acceptance.
- All automated tests and the manual acceptance checklist in this document pass.

## 3. Scope

### 3.1 Included in v1

- TCP listeners.
- Bound, unconnected UDP sockets, presented as listeners because UDP has no listening state.
- TCP sockets with a remote endpoint, including established and transitional states, presented as connections.
- Connected UDP sockets with a remote endpoint, presented as connections.
- Grouping by activity kind, transport protocol, local port, and process.
- A compact SwiftUI menu-bar popover.
- Automatic and manual refresh.
- SIGTERM followed by a separately initiated SIGKILL option when required.
- Standard About panel and Quit action.
- Inline, non-blocking scan and termination feedback.

### 3.2 Explicitly excluded from v1

- A main application window, Dock icon, or application-switcher presence.
- A settings window, launch-at-login support, notifications, global shortcuts, or persisted UI preferences.
- Administrator authentication, privileged helpers, launch daemons, or elevated scans.
- Port forwarding, firewall management, packet capture, bandwidth measurement, or historical activity.
- Search, filtering, sorting controls, process icons, code-signing metadata lookup, or application bundle resolution.
- Terminal launch, command copy, or IDE integration. The row/action design must leave room for these later.
- Arbitrary hostname entry, multi-host dashboards, containers, virtual machines, and remote controls. Remote inspection is limited to one literal SSH alias at a time.
- App Store, Developer ID distribution, notarization, auto-update, analytics, crash reporting, or telemetry. Public distribution requires a separate specification.

## 4. Definitions and classification

- **Local endpoint:** The address and port on this Mac, shown to the left of `->` in `lsof` output or as the only endpoint for an unconnected socket.
- **Remote endpoint:** The address and port to the right of `->`.
- **Local port:** The numeric port parsed from the local endpoint. This is the displayed and grouped port. For an outgoing connection it can be ephemeral.
- **Listener:** A TCP socket whose state is `LISTEN`, or a UDP socket with a local endpoint and no remote endpoint.
- **Connection:** A non-`LISTEN` TCP socket with local and remote endpoints, or a UDP socket with both endpoints.
- **Socket record:** One parsed `lsof` file set.
- **Row:** Socket records grouped by activity kind, protocol, local port, and process origin.
- **Process identity:** PID plus process start time obtained from the macOS process API. PID or process name alone is unsafe.
- **Visible:** The popover is actually presented, not merely that Porto is running or its menu-bar item exists.
- **Target:** Either This Mac or one literal alias discovered from the user's `~/.ssh/config`.
- **Remote row:** A socket parsed from the selected Linux host. Its Linux PID and process name are informational and it is never actionable.

Sockets without a numeric local port, with unsupported protocols, or that cannot be classified must be skipped individually and counted for diagnostics. They must not invalidate otherwise usable rows.

## 5. User experience

### 5.1 Menu-bar presence

- Porto must use SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- The status item must use a monochrome template-style network symbol that adapts to menu-bar appearance.
- The accessible menu-bar label must be `Porto`.
- `LSUIElement` must be `true`. Porto must have no `WindowGroup`, main window, Dock icon, or application-switcher entry.
- Porto does not expose a preference for removing or hiding its menu-bar item in v1.
- App launch must not scan until the popover is first opened.

### 5.2 Popover layout

- The popover is 360 points wide, with minimum content height 180 points and maximum height 560 points or available screen height, whichever is smaller.
- Overflowing content uses native vertical scrolling; Porto must not simulate or intercept scrolling.
- A fixed header contains `Porto`, a manual refresh button, and an overflow menu.
- The refresh button has accessibility label and help text `Refresh ports`. When the popover has keyboard focus, Command-R invokes the same coalesced refresh path.
- The scrollable body contains one unified list of listener and connection rows.
- The footer may contain compact error status without persistent verbose text.
- The overflow menu contains `About Porto` and `Quit Porto`.
- `About Porto` opens the standard macOS About panel. This is the only secondary panel allowed in v1.

### 5.3 Unified activity list and empty state

- Listeners and connections appear together in one list; no category labels or disclosure controls are shown.
- Rows sort by local port ascending, process name case-insensitively, TCP before UDP, then PID ascending across both activity kinds.
- An empty list says `No ports found`.
- A first load with no snapshot shows one progress indicator and `Scanning…`, not false empty states.

### 5.4 Rows and details

- A row shows the process name with the local port beneath it and an icon-only process action aligned with the name. Rows are not expandable and do not expose per-process disclosure controls.
- Ports use tabular digits. Long process names truncate without displacing the action.
- Each row is keyboard-focusable. Protocol, PID, socket state, and endpoint data remain internal scan and revalidation data rather than standard row content.

### 5.5 Refresh behavior

- Opening the popover triggers an immediate scan even when a snapshot exists.
- While visible, the monitor requests refresh every 2 seconds from the preceding request.
- Closing cancels the refresh loop and pending coalesced refresh. It asks an in-flight normal `lsof` child to terminate because the result is no longer needed.
- Manual refresh starts immediately when idle or becomes the one pending refresh when a scan is running.
- The refresh icon spins only during a user-requested manual refresh; background refreshes leave it static.
- An unchanged successful scan retains equal row arrays while updating scan diagnostics.
- A successful empty scan replaces the prior snapshot with an empty list.
- A failed scan retains the last successful snapshot and marks it stale.

### 5.6 Stop and force kill

- Normal stop is an icon-only `×` with accessibility label `Stop <process name>` and help text `Send SIGTERM to process <name> (PID <pid>). This can close all ports owned by the process.`
- Clicking `×` sends no signal until revalidation succeeds. SIGTERM does not require confirmation in v1.
- During revalidation and the bounded exit check, every row for the same process identity shows progress and disables duplicate stop actions.
- Only one termination workflow may revalidate or signal at a time. While it is active, termination actions for other processes are disabled without hiding them.
- If the process exits, remove all its rows immediately and request a coalesced refresh.
- If it remains alive, restore its rows and expose a separate icon-only Force Kill action for that process. Normal stop may remain available for retry.
- Force Kill has destructive styling, accessibility label `Force kill <process name>`, and help text explaining that SIGKILL prevents cleanup.
- Activating Force Kill presents a confirmation naming the process and PID and warning that unsaved work can be lost. Only confirmation sends SIGKILL.
- Canceling changes no process state.
- Force-kill eligibility belongs to the current immutable process identity and disappears when that identity exits or changes.
- Porto never exposes termination controls for its own PID. If Porto appears, it is non-actionable with help text `Porto cannot stop itself.`

### 5.7 Target selection and remote Linux view

- The target selector is placed under `WATCHING` and contains `This Mac` plus literal aliases read from `~/.ssh/config`. Aliases are discovered from files only; picker population never launches SSH or executes configuration helpers.
- This Mac is selected by default. A target change invalidates the old scan session before cancellation, cancels the old remote work, and starts one scan for the new target only after the old runner has released its child.
- Remote status uses `Connecting over SSH…`, `Available over SSH · updated just now · read-only`, `Refreshing… · read-only`, and `Reconnecting… · showing in-memory results`. It must not say `SSH connected` while idle because scans use short-lived SSH children.
- Remote rows show a lock/read-only treatment and expose no stop or force-kill action. This guard exists in the view, monitor, model, and terminator layers.
- Remote snapshots hide common host-service ports (22, 53, 80, 123, 137–139, 161–162, 443, 445, and 5353) and ownerless non-Docker rows after parsing while retaining custom project ports. Published Docker ports are exempt from the common-port filter and labeled `Docker · <container>` using optional `docker ps` metadata. Diagnostics continue to report all valid records received from `ss`.
- One successful snapshot is retained in memory per target until quit. A failure keeps that target's rows and marks them stale; a first failure shows an actionable retry without a false empty success.
- A listener is evidence on the selected server, not a claim about reachability from another network or the public Internet. Missing Linux process metadata does not hide an otherwise valid socket.

## 6. Data model and grouping

The implementation may refine names but must preserve these semantics:

```swift
enum PortActivityKind: String, Sendable {
    case listener
    case connection
}

enum TransportProtocol: String, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

struct Endpoint: Hashable, Sendable {
    let rawValue: String
    let localPort: Int
    let hasRemoteEndpoint: Bool
    let socketState: String?
}

enum PortProcessOrigin: Hashable, Sendable, Codable {
    case local(ProcessIdentity)
    case remote(targetID: PortTargetID, pid: Int32?)
}

struct PortProcess: Identifiable, Equatable, Sendable {
    let id: String
    let origin: PortProcessOrigin
    let localPort: Int
    let transport: TransportProtocol
    let processName: String
    let endpoints: [Endpoint]
    let activityKind: PortActivityKind
}
```

`PortProcess.id` is a stable serialization of activity kind, transport, local
port, and origin. Local rows include process start time; a missing local
identity uses a scan-generation-scoped fallback and produces a non-actionable
row. Remote rows are target-scoped and use the Linux PID plus normalized name,
socket cookie, inode, or a canonical endpoint tuple. A remote PID is never
treated as a macOS `ProcessIdentity` and can never enable termination.

The grouping key is:

```text
activity kind + transport protocol + local port + process origin
```

Consequences:

- IPv4 and IPv6 sockets with the same key become one row.
- Duplicate endpoint-and-state observations are removed. State remains attached to its endpoint so grouped sockets with different states are represented accurately.
- Listener and connection records on the same local port remain separate.
- TCP and UDP on the same local port remain separate.
- The same process and port can appear in both sections.
- Termination state is keyed by `ProcessIdentity` because a signal affects the process, not one socket.

## 7. Scanner contract

### 7.1 Invocation

`PortScanner` launches exactly one direct executable per normal scan:

```text
/usr/sbin/lsof -nP -w -iTCP -iUDP -F0pcfPntT -Ts
```

Pass arguments separately to `Process`. Do not invoke a shell. Do not use `ps`, `netstat`, one subprocess per row, DNS lookup, service-name lookup, or per-process bundle metadata during normal scanning.

- `-nP` keeps hosts and ports numeric.
- `-w` suppresses warnings that would pollute diagnostics.
- `-iTCP -iUDP` selects TCP and UDP Internet sockets.
- `-F0pcfPntT` requests NUL-delimited PID, command, file boundary, protocol, name, type, and TCP/TPI fields.
- `-Ts` explicitly requests TCP state.

The executable URL is fixed in code and never contains user-controlled text.

### 7.2 Capture, limits, and exit status

- Capture stdout and stderr separately and drain both concurrently to prevent pipe backpressure.
- Decode field payloads as UTF-8 with lossy replacement; invalid bytes must not crash the scan.
- Cap stdout at 16 MiB and stderr at 64 KiB. Exceeding either fails as `outputTooLarge`, terminates the child, and retains the prior snapshot.
- Apply a 3-second wall-clock timeout. On timeout call `Process.terminate()` for the scanner-owned child. If it remains after 500 milliseconds, Porto may SIGKILL only that `lsof` child. This exception never applies to a monitored user process.
- Cancellation on popover close follows the same child cleanup but shows no user error.
- Exit 0 with parseable or empty output is successful.
- Exit 1 with empty stdout and stderr is a successful empty scan because this is normal `lsof` no-match behavior.
- Signal termination, timeout, limit breach, launch failure, non-empty malformed output with zero valid records, and other non-zero exits are failures.
- Partial output from a failed process never replaces the last successful snapshot.
- Exit 0 with at least one valid record may publish those records even when individual malformed records were skipped; expose the skipped count only in diagnostics.
- Debug diagnostics may record duration, exit status, byte counts, and parse counts but never raw endpoints.

### 7.3 Parser rules

- A `p` field starts a process set and an `f` field starts a file/socket set.
- Associate `c` with the process and `t`, `P`, `n`, and `TST=` with the current file set.
- NUL terminates a field; newlines that delimit process or file sets must be consumed as structural separators. Flush the current file set at the next `f`, the next `p`, and end of input.
- Fields may be absent, repeated, unknown, or out of order. Skip incomplete file sets rather than trapping.
- Ignore unknown field identifiers and unknown `T` subfields for forward compatibility.
- Split the `n` field on the first `->` to detect a remote endpoint.
- Parse the numeric local port from the final colon-delimited local component while respecting bracketed IPv6. Accept only `1...65535`.
- Preserve complete numeric endpoint text for display; never resolve names.
- TCP `LISTEN` is a listener. Other TCP records require a remote endpoint and are connections.
- UDP with a remote endpoint is a connection; UDP without one is a listener.
- Normalize protocol and state to uppercase.
- During byte parsing, deduplicate into a preliminary dictionary keyed by activity kind, protocol, local port, and PID instead of building an unbounded flat socket list. For local rows, replace bare PID with `ProcessIdentity`; remote rows retain a target-scoped owner or socket identity.
- Deduplicate endpoint observations by normalized endpoint text and socket state, then sort them before publishing so unchanged scans compare equal.

### 7.4 Process identity enrichment

- Enrich each distinct PID once per scan, not per row, using `proc_pidinfo` with `PROC_PIDTBSDINFO` or an equivalently stable public macOS process API.
- Store process start seconds and microseconds.
- A row whose identity cannot be retrieved remains visible but non-actionable.
- Display name comes from the `lsof` `c` field. It is not immutable identity and cannot be the sole PID-reuse defense.
- Identity work runs off the main actor and is bounded by the distinct PIDs in the scan.

### 7.5 Remote scanner contract

Remote inspection is enabled only for a selected literal SSH alias. `SSHHostCatalog`
reads `~/.ssh/config` and bounded `Include` files without launching a process or
opening a connection. It accepts safe literal aliases, ignores wildcards,
negation, and `Match` blocks, sorts and de-duplicates them deterministically,
and retains the prior catalog on a transient read failure.

`SSHCommandRunner` launches exactly one direct `/usr/bin/ssh` child with the
following arguments (the alias is passed after `--`):

```text
/usr/bin/ssh -T -n -o BatchMode=yes -o ConnectTimeout=3 -o ConnectionAttempts=1 -o NumberOfPasswordPrompts=0 -o PermitLocalCommand=no -o ClearAllForwardings=yes -o RequestTTY=no -o RemoteCommand=none -o ControlMaster=no -o ControlPath=none -- <literal-ssh-alias> LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/sh -c 'ss -H -n -O -a -t -u -p -e; ss_status=$?; printf "__PORTO_DOCKER__\n"; if command -v docker >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then timeout -k 1 1 docker ps --format "{{.ID}}\t{{.Names}}\t{{.Ports}}" 2>/dev/null || true; fi; exit "$ss_status"'
```

The command and its environment are fixed except for inherited SSH settings
(including `SSH_AUTH_SOCK`) and `LC_ALL=C`. `ss` output is drained concurrently,
bounded at 16 MiB stdout and 256 KiB stderr, and has a five-second total
deadline. Cancellation, timeout, read failure, or overflow terminates the
local SSH child, waits up to 500 milliseconds, force-kills only that child if
needed, and awaits cleanup. Remote command output is decoded and parsed without
shell interpolation; raw output is never surfaced or persisted.

The parser supports numeric IPv4/IPv6, wildcard, loopback, and interface-
qualified endpoints; TCP `LISTEN` and unconnected UDP are listeners, while
remote-endpoint TCP/UDP rows are connections. Owner metadata is optional. A
successful empty result is valid, and a successful remote row is always marked
with its target origin and read-only state. The optional Docker section maps
published host ports to running container names without changing socket
diagnostics. The Docker query is bounded and is skipped when `timeout` is
unavailable; a Docker failure never replaces a successful `ss` result. Exit
status 255 alone is a generic transport failure; bounded
`LC_ALL=C` diagnostics may classify authentication, host-key, reachability,
timeout, or missing/incompatible `ss` failures.

## 8. Refresh and concurrency architecture

### 8.1 Components

- `PortMonitor` is a `@MainActor` observable model for rows, presentation, section expansion, scan status, timestamps, errors, and per-process termination state.
- `PortScanner` is an injected `Sendable` service or actor for subprocess execution and parsing away from the main actor.
- `LsofRunner` is the single serialized owner of every normal and targeted `lsof` child.
- `SSHHostCatalog` reads the user's SSH configuration files with bounded, deterministic include traversal.
- `RemotePortScanner` and its actor-owned `SSHCommandRunner` perform one fixed, read-only Linux `ss` query plus optional `docker ps` publication metadata for the selected alias.
- `ProcessInspector` reads immutable process identity and existence.
- `ProcessTerminator` coordinates validation and signaling away from the main actor.
- `MenuPresentationObserver` reports actual popover presentation.
- Scanner, terminator, signal sender, and monotonic clock abstractions are injectable for deterministic tests.

### 8.2 Single-flight state machine

```text
idle -> scanning -> idle
          |          ^
          + pending -+
```

- At most one normal scan task exists, and at most one local `lsof` or remote SSH child belongs to Porto at a time.
- A request during `scanning` sets one Boolean pending flag; later requests add nothing.
- After completion, run one follow-up only if pending is true and the popover is still visible.
- A stop action has priority over automatic refresh: it cancels or waits for the current normal child to exit, then starts targeted validation through the same `LsofRunner`. Timer/manual requests received meanwhile coalesce into one later normal refresh.
- Canceling a normal scan to prioritize termination is an expected internal cancellation: it retains the current snapshot and shows no scan error.
- Suspend normal scanning for the full active termination workflow, including the bounded exit check. Preserve at most one pending refresh and run it when the workflow returns to an idle or force-eligible state and the popover is visible.
- Generation tokens or structured cancellation prevent an older visibility session from publishing into a newer one.
- UI publication occurs only on the main actor.
- Swift 6 strict-concurrency warnings in project-owned code are treated as errors.
- A target change increments the session before cancellation; a late result is
  discarded unless its scan token, target ID, and session generation all match.

### 8.3 Popover lifecycle

`MenuBarExtra(isInserted:)` describes whether a status item exists, not whether its popover is open, so it must not drive polling.

- Content may issue provisional `onAppear` and `onDisappear` signals.
- `MenuPresentationObserver` binds to the containing window and observes public AppKit window visibility, key, and close notifications for that exact window without private APIs or assumptions about every app window.
- `PortMonitor.isPresented` is true only while the popover is visibly presented and becomes false promptly after dismissal.
- Automated tests cover the observer abstraction. Runtime tests prove that status-item toggle, outside click, Escape, app switching, and quit all stop periodic scanning.
- If macOS 26 behavior differs, implementation must change to meet the observable no-background-scan requirement rather than weaken it.

## 9. Process termination safety

Termination is a This Mac capability only. `ProcessTerminator` accepts local
socket validation and immutable macOS process identities; a remote-origin row
is rejected before it can reach validation or a signal sender. Remote Linux
PIDs, names, cookies, and endpoints are informational and Porto never sends a
remote signal or invokes `sudo`, `doas`, `ss --kill`, or an installed helper.

### 9.1 Revalidation before SIGTERM

For the selected row, perform this exact sequence:

1. Reject Porto's own PID and any row without immutable identity.
2. Query current process identity and require PID plus start time to match the row.
3. Through the shared `LsofRunner`, run one targeted direct validation as `/usr/sbin/lsof -nP -w -a -p <pid> -iTCP -iUDP -F0pcfPntT -Ts`. The `-a` is required so PID and Internet-socket selections are combined. Require a socket matching the selected activity kind, protocol, and local port. This is user-triggered validation, not one subprocess per displayed row.
4. If the PID no longer exists, treat the stop as successful and refresh.
5. If identity changed or the selected socket is gone, send no signal, report `The process changed before it could be stopped`, and refresh.
6. Query immutable identity again after `lsof` exits and require it still to match, closing the PID-reuse window created by validation work.
7. Require the current process name to match the row as additional defense, then call `Darwin.kill(pid, SIGTERM)` and capture `errno` immediately on failure.

The targeted validation uses the same parser and classification rules as a normal scan.
It also uses the same 3-second timeout, concurrent pipe draining, output limits, exit interpretation, and cancellation-safe cleanup.

### 9.2 Graceful-exit check

- After SIGTERM, poll identity every 100 milliseconds for at most 2 seconds using `ProcessInspector`; do not repeatedly launch `lsof`.
- Exit means PID absence or a changed start time. PID reuse therefore means the original process exited.
- App quit cancels the check. Popover close does not abandon user-requested termination; it may finish without UI animation and cannot start recurring background scans.
- If the original identity survives 2 seconds, expose Force Kill.
- Reaching the grace timeout ends the active termination workflow; force eligibility is durable row state, not a background task.

### 9.3 Revalidation before SIGKILL

After explicit confirmation:

1. Repeat immutable identity validation.
2. Repeat targeted socket validation for the selected row.
3. Repeat immutable identity validation immediately after targeted `lsof` returns.
4. Send SIGKILL only if all validations match.
5. Poll identity for at most 1 second, then refresh.
6. If it remains alive or anything fails, retain rows and show an error.

Porto never automatically escalates a monitored process from SIGTERM to SIGKILL.

### 9.4 Result handling

- `ESRCH`: treat as already exited and successful.
- `EPERM` or `EACCES`: report permission denied and keep the row.
- Identity or socket mismatch: send no signal, report stale target, and refresh.
- Other `errno`: show a generic failure with system error description in a tooltip, never raw command output.
- Termination errors are scoped to process identity and clear on retry, process replacement, or a later successful scan where that identity is absent.

## 10. Loading, stale data, and errors

### 10.1 Priority

Show only the highest-priority current condition:

1. Termination failure on affected rows.
2. Scan failure or stale snapshot in header/footer.
3. Skipped-record count in diagnostic help only.

### 10.2 User messages

- Launch failure: `Port scan could not start.`
- Timeout: `Port scan timed out. Showing the last results.`
- Permission/access issue: `Some port information is unavailable.`
- Malformed output: `Port data could not be read. Showing the last results.`
- Output limit: `Port data exceeded the safe limit. Showing the last results.`
- Other failure: `Port scan failed. Showing the last results.`

When no snapshot exists, omit `Showing the last results.` and display a retry action. Full technical detail belongs in tooltip and debug log, not persistent row text.

### 10.3 Freshness

- Store scan diagnostics and stale state.
- Clear scan error only after success.
- Never merge partial failed output into the snapshot.
- Never flicker to empty between scans.

## 11. Accessibility and interaction

- Every icon-only button has a unique accessibility label and useful help text.
- Every action is reachable by keyboard without hover.
- Focus order follows header, the unified activity list, then footer.
- Focused controls retain a visible focus ring.
- Color is never the only status signal.
- Support increased contrast, Reduce Motion, and system text sizing where SwiftUI provides them. A progress spinner may rotate because it conveys work; decorative animation is prohibited.
- Use semantic system colors and preserve light, dark, and high-contrast legibility.
- Truncated text exposes the full value through accessibility and help.
- VoiceOver announces list state, process details, stop progress, errors, and force-kill confirmation.

## 12. Performance and resources

- Closed popover: zero recurring timers, zero normal `lsof` or SSH children, and no scan CPU activity after user-requested termination work settles.
- Open popover: at most one normal scan and one pending request; across local and selected-remote work there is at most one Porto-owned `lsof` or SSH child.
- No per-row timers, polling, subprocesses, bundle lookups, or continuous animations. A remote SSH request occurs only for the selected target while visible or after an explicit retry.
- Process launch, pipe reads, parsing, sorting, and identity enrichment run off the main actor.
- Publish sorted immutable rows only when meaningful values change.
- Retain only the current successful grouped snapshot, current errors, timestamps, and termination states. Release raw scan data after each scan.
- During a 10-minute open test, memory stabilizes after warm-up with no sustained Porto-attributable growth.
- Scrolling, dismissal, and buttons remain responsive during refresh. Instruments shows no Porto scan work blocking the main thread for 100 milliseconds or longer.
- Closing prevents a pending scan from starting within 100 milliseconds of close notification and promptly terminates an already-running normal child.

## 13. Privacy and security

- This Mac processing is local and makes no network requests. Selecting a remote target is the explicit exception: Porto sends only the fixed `ss` query through the user's `/usr/bin/ssh` configuration and receives its bounded result; it collects no telemetry.
- Do not persist port lists, IP addresses, process lists, raw `lsof`/`ss` output, or termination history.
- Debug logs omit raw endpoints and command output. PID, aggregate counts, duration, result category, and exit code are allowed.
- Do not accept executable paths, shell fragments, PIDs, or signal values from external input.
- Do not use private frameworks or private SwiftUI/AppKit APIs.
- App Sandbox is disabled in v1 because Porto executes `/usr/sbin/lsof` and inspects/signals peer processes. Hardened runtime and distribution entitlements wait for the distribution plan.
- Signals operate only on current, revalidated snapshot rows. There is no arbitrary PID entry.
- Remote inspection trusts the user's SSH configuration, including any configured
  `ProxyJump`, `ProxyCommand`, `KnownHostsCommand`, or `Match exec` helper. Porto
  does not disable normal host-key verification, replace known-host files, or
  accept passwords, passphrases, or keys in its UI.

## 14. Project and build configuration

### 14.1 Layout

```text
project.yml
Porto/
  App/
  Models/
  Services/
  Views/
  Resources/
PortoTests/
  Fixtures/
scripts/
docs/
```

`Porto.xcodeproj` is generated locally and not committed; `project.yml` is authoritative. `.gitignore` and README must state this.

### 14.2 XcodeGen requirements

- Project and app target: `Porto`.
- Unit-test target: `PortoTests`, dependent on `Porto`.
- Shared `Porto` scheme with build, run, test, profile, analyze, and archive actions.
- Product: macOS application; deployment target: macOS 26.0.
- Swift language mode 6 using the Swift 6.3 compiler in the compatible Xcode 26 toolchain. Record the exact accepted Xcode build in the README and CI configuration rather than assuming a point release.
- Bundle identifier: `dev.wayne.porto` unless changed before first signed release.
- Marketing version `1.0.0`; build `1`.
- Generated Info.plist contains `LSUIElement: true`.
- App Sandbox disabled.
- Project-owned Swift warnings are errors in CI.
- Use standard architectures supported by the macOS 26 SDK; do not hard-code one architecture.
- No third-party runtime dependencies in v1.

Unsigned CI may set `CODE_SIGNING_ALLOWED=NO`. Runtime acceptance uses a locally runnable signed or ad-hoc-signed Debug app. Public signing and notarization are outside v1.

### 14.3 Reproducible commands

README must document commands equivalent to:

```text
xcodegen generate
xcodebuild -project Porto.xcodeproj -scheme Porto -destination 'platform=macOS' test
xcodebuild -project Porto.xcodeproj -scheme Porto -configuration Debug -destination 'platform=macOS' build
```

It also documents the DerivedData `.app` path and actual launch procedure. DerivedData, build products, local signing state, credentials, and machine-specific Xcode files are ignored by Git.

## 15. Test strategy

### 15.1 Parser tests

Fixtures must cover:

- IPv4 and IPv6 TCP listeners.
- Wildcard, loopback, and interface-bound listener addresses.
- Bound and connected UDP sockets.
- TCP `ESTABLISHED`, transitional remote states, and `LISTEN`.
- Bracketed IPv6 and IPv4 endpoints.
- Outgoing ephemeral local ports.
- Multiple sockets sharing a grouping key.
- TCP and UDP sharing a local port.
- Listener and connection sharing process and port.
- Same port owned by different PIDs.
- Duplicate endpoints and multiple states.
- NUL-delimited process and file boundaries.
- Missing, repeated, unknown, out-of-order, invalid UTF-8, and malformed fields.
- Missing command, protocol, endpoint, PID, or numeric port.
- Ports 1 and 65535 plus rejected 0 and 65536.
- Empty output and nonempty output with no valid records.
- Deterministic row and endpoint sorting.

Fixtures are sanitized and contain no user-specific public IPs or process data.

### 15.2 Scanner and concurrency tests

- Fixed executable and exact arguments.
- Success, empty exit 1, malformed, non-zero, launch failure, excessive output, timeout, and cancellation.
- Concurrent stdout/stderr draining.
- Last-valid-snapshot retention on every failure.
- Successful empty result replacing the snapshot.
- Immediate open scan and 2-second schedule with an injected clock.
- Pause and child cancellation on close.
- One in-flight normal scan and one coalesced follow-up during refresh bursts.
- One total `lsof` child when targeted validation overlaps a scheduled or manual refresh request.
- A single global active termination workflow; other signal actions remain disabled until it settles.
- Normal scans suspended during revalidation and the bounded exit check, followed by one coalesced refresh.
- Old-generation result suppression after close/reopen.
- Equal rows not republished.
- One identity lookup per distinct PID per scan.
- Remote target selection, fixed SSH argument contract, bounded output and
  timeout/cancellation cleanup, diagnostic classification, target-scoped IDs,
  ownerless sockets, per-target cache retention, stale-result suppression,
  bounded failure backoff, and read-only termination guards.

### 15.3 Termination tests

Injected inspector, validator, signal sender, and clock cover:

- Matching identity/socket and successful SIGTERM exit.
- Already-exited process.
- Reused PID with different start time.
- Changed process name.
- Disappeared selected socket while process remains.
- `EPERM`, `EACCES`, `ESRCH`, and unexpected `errno`.
- Grace timeout exposes Force Kill without sending it.
- Force Kill cancel, identity mismatch, socket mismatch, success, and still-alive failure.
- Shared termination state across one process's rows.
- Self-PID action unavailable.
- Popover closure during bounded exit check.
- No repeated `lsof` during 100-millisecond identity polling.

At least one integration test starts a disposable current-user TCP server, discovers it, uses the real service to send SIGTERM, and verifies exit and row removal. A separate disposable process that ignores SIGTERM verifies force-kill eligibility; SIGKILL occurs only after explicit test confirmation. Teardown always cleans up fixtures.

### 15.4 UI and accessibility tests

- First-load, populated, empty, stale, and scan-error states.
- Unified listener and connection list with deterministic cross-kind sorting.
- Stable row identity across refresh.
- Keyboard traversal through the unified list.
- VoiceOver labels/values and icon help.
- Light, dark, increased-contrast, and Reduce Motion behavior.
- Force-kill confirmation names process and PID.
- Long names, many endpoints, and enough rows for native scrolling.

### 15.5 Manual runtime and profiling

Run the generated Debug `.app` on macOS 26 and verify:

- Menu-bar icon with no Dock or application-switcher presence.
- Popover sizing, scrolling, dismissal, and reopening on tested display edges.
- Immediate open scan and stopped periodic scanning after status-item toggle, outside click, Escape, or app switch.
- Activity Monitor shows no normal `lsof` or SSH child while closed and never more than one Porto-owned scan child while open.
- Stable memory and no interaction stalls over 10 minutes.
- Usable behavior with hundreds of connection rows.
- Disposable server graceful stop and explicit force-kill fixture behavior.
- Permission failure keeps its row with accessible feedback.
- About uses the standard panel; Quit ends tasks and child processes.

### 15.6 Remote runtime acceptance

When representative Linux hosts are available, verify a Debian/Ubuntu host,
an independently packaged iproute2 host, and a non-root account with incomplete
process visibility. Compare Porto's rows with the exact `ss -H -n -O -a -t -u
-p -e` output, including TCP/UDP classification, IPv4/IPv6 endpoints, wildcard
listeners, stable IDs, and retained ownerless sockets. Exercise authentication,
host-key, unreachable, timeout, and incompatible-`ss` failures; switch targets
while SSH is delayed; confirm cancellation leaves no child or stale rows; and
verify that no remote file, service, configuration change, privilege
escalation, or signal is attempted. Treat ordinary SSH authentication and audit
logging as expected user-owned side effects, not as Porto persistence.

## 16. Acceptance traceability

| ID | Release requirement | Verification |
| --- | --- | --- |
| AC-01 | Menu-bar-only app with no main window or Dock presence | Built-app manual test |
| AC-02 | Listeners and connections appear together in one unified list without category controls | UI and manual tests |
| AC-03 | TCP/UDP classification and grouping follow Sections 4 and 7 | Parser fixtures |
| AC-04 | Immediate open scan and 2-second visible-only refresh | Clock test and runtime observation |
| AC-05 | One total Porto-owned `lsof` or SSH child; one normal scan and one coalesced refresh maximum | Concurrency tests and Activity Monitor |
| AC-06 | Failure retains valid snapshot; successful empty scan clears it | Scanner tests |
| AC-07 | Normal stop revalidates identity and selected socket | Termination tests |
| AC-08 | SIGTERM gets 2 seconds; SIGKILL needs confirmation and fresh validation | Integration and UI tests |
| AC-09 | Icon-only actions are keyboard and VoiceOver accessible | Accessibility audit |
| AC-10 | Closed state has no recurring scanner or child | Instruments and Activity Monitor |
| AC-11 | Generate, test, build, and actual app launch all succeed | Clean-checkout release check |
| AC-12 | No raw port/process data is persisted or emitted outside an explicit selected SSH scan | Code review and filesystem/network observation |
| AC-13 | Remote aliases, fixed command, read-only rows, cache isolation, and bounded failures | Catalog/runner/parser/monitor tests and Linux acceptance |

## 17. Delivery sequence and definition of done

Implement in these verifiable milestones:

1. XcodeGen project, menu-bar shell, About, Quit, and presentation lifecycle.
2. Models, byte-safe parser, fixtures, grouping, sorting, and tests.
3. Single-flight scanner, timeout/cancellation, snapshots, and concurrency tests.
4. Unified activity list, rows, loading/empty/error UI, and accessibility.
5. Process identity, revalidation, SIGTERM, force-kill confirmation, and failure tests.
6. Real-process integration tests, profiling, built-app acceptance, and README.

The feature is done only when:

- Every **must** requirement is implemented or this specification is formally changed.
- Automated tests pass from a clean generated project.
- The complete built-app checklist passes.
- Instruments and Activity Monitor meet the resource requirements.
- The final diff contains no build products, DerivedData, credentials, signing artifacts, machine state, or unrelated work.
- Known limitations are documented without contradicting this specification.

## 18. Assumptions and resolved decisions

- “Ports currently running” includes local listeners and active connections, with listeners primary.
- Connection counts mean grouped rows; endpoint counts stay inside rows.
- Displayed port always means local port, including ephemeral client ports.
- Stop is process-level and can close every socket and unsaved task owned by that process; it does not claim to close only one port.
- SIGTERM is immediate after validation. SIGKILL is separate, confirmed, and never automatic for a monitored process.
- PID plus start time is identity. PID plus name alone is insufficient.
- Current-user visibility and permissions define what Porto can inspect or stop. Lack of privilege is reported, not bypassed.
- Section expansion lasts one popover session. No preferences are persisted.
- The initial deliverable is a locally runnable developer build. Public distribution is intentionally outside v1 rather than unspecified.

## 19. Future-compatible extension points

These are not v1 requirements, but architecture must not prevent them:

- Row action menu for terminal launch, diagnostic command copy, or revealing an owning app.
- Search and user-selectable sorting.
- Launch at login and persisted preferences.
- Signed and notarized distribution.
- Process icons and application bundle metadata.
- Historical snapshots or change highlighting, subject to a new privacy specification.

Future actions must use a row-action abstraction rather than changing parser or grouping identity.

## 20. Technical basis

- Apple [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra) documentation defines a menu-bar scene, recommends `LSUIElement` for menu-bar-only apps, and identifies the window style for data-rich content.
- Apple [`MenuBarExtraStyle.window`](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window) documentation defines the popover-like window presentation used by Porto.
- The installed macOS `lsof(8)` manual is authoritative for field identifiers, NUL termination, process/file set boundaries, `-T` state selection, and option semantics. The exact commands in this specification were exercised against the installed `/usr/sbin/lsof` during specification review.
- The [XcodeGen ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md) is authoritative for macOS target, deployment target, Info.plist, test target, and shared scheme configuration.

Implementation must re-run the documented command-contract and built-app lifecycle acceptance checks after any supported macOS, Xcode, Swift, XcodeGen, or `lsof` version change.
