# Porto: macOS Port Monitor

## Summary

Create a native SwiftUI menu-bar utility for macOS 26+ that:

- Lists listening ports and active network connections.
- Keeps listening ports visible by default and places active connections in a collapsed section.
- Groups entries by process and port.
- Refreshes automatically every 2 seconds.
- Shows compact `port · app` rows.
- Provides a compact `×` action that sends SIGTERM, then exposes a separate force-kill action if the process remains alive.
- Runs entirely from the menu bar without a main window.

## Implementation

- Create an XcodeGen-generated macOS application using Swift 6.3 and SwiftUI’s `MenuBarExtra`.
- Add a `PortMonitor` observable model that owns the refresh timer, loading state, current rows, and inline errors.
- Add a `PortScanner` service that invokes `/usr/sbin/lsof` and parses TCP/UDP listeners plus active connections into normalized records:

  ```swift
  enum PortActivityKind: String {
      case listener
      case connection
  }

  struct PortProcess: Identifiable, Equatable {
      let id: String        // activity kind + protocol + port + PID
      let port: Int
      let protocolName: String
      let pid: Int
      let processName: String
      let endpoints: [String]
      let activityKind: PortActivityKind
  }
  ```

- Group duplicate listener sockets for the same process and port, and group connection sockets separately. The activity kind must remain part of the identity so a listener and an active connection owned by the same process and port are not merged.
- Render a compact menu-bar popover with an expanded `Listeners` section first and a collapsed `Connections (n)` section second. Show only the port, process name, and action icon by default; reveal protocol and endpoint details on row expansion or hover.
- Add a `ProcessTerminator` service:
  - Send SIGTERM when the user clicks `×` and replace that icon with a rotating progress indicator while checking for exit.
  - If the process remains alive after the bounded check, restore the row and expose a separate compact force-kill icon; do not send SIGKILL automatically.
  - Expose a failure state if either signal is denied or the process cannot be revalidated.
  - Keep the row visible and show the failure through a compact inline indicator or tooltip rather than a persistent text label.
  - Revalidate the PID, process name, and associated port before signaling so an old row cannot target a reused PID. Treat a process that already exited as a successful stop.
- Include menu actions for manual refresh, opening the app’s About information, and quitting.
- Keep terminal integration out of this version but structure rows so future “open in terminal” and command-copy actions can be added cleanly.

## Lightweight performance plan

- Use one direct `/usr/sbin/lsof` subprocess per refresh, with `-nP` and protocol filters so lsof does not perform DNS lookups or service-name resolution. Do not invoke a shell, `ps`, or one subprocess per process/port.
- Request machine-readable field output from lsof and parse stdout once in memory. Deduplicate into a dictionary keyed by activity kind, protocol, port, and PID while parsing instead of creating an ungrouped socket array first.
- Run scanning away from the main actor on a dedicated lightweight worker. Keep at most one scan in flight; if a refresh tick arrives during a scan, coalesce it into one follow-up refresh rather than building a queue.
- Bound each subprocess with a short timeout. On timeout or non-zero exit, cancel/terminate the subprocess, retain the last successful snapshot, and expose a small non-blocking error state.
- Start with an immediate scan when the menu opens, refresh every 2 seconds only while the port list is visible, and cancel the refresh task when it closes. This preserves live results where they are used while avoiding continuous background polling and unnecessary battery use.
- Publish immutable, sorted rows only when their meaningful values change. Keep the raw lsof text and temporary parsing buffers local to a scan, and retain only the current grouped snapshot plus the current error.
- Keep the menu view simple: no per-row timers, animations, polling, network requests, or expensive process metadata lookups. Render endpoint details on demand rather than formatting them continuously.
- Perform termination checks only after an explicit user action. Use a short bounded exit check after SIGTERM, and never run a recurring process-existence check for every row.
- Avoid privileged helpers, launch daemons, login items, and elevated scans in v1. The app should use the current user’s permissions and report inaccessible processes without adding a resident service.
- Verify the result with Instruments and Activity Monitor: confirm zero lsof subprocesses while the menu is closed, never more than one scan subprocess, no queued scans, stable memory during a 10-minute open-menu run, and no measurable UI stalls while the list refreshes.

## Test plan

- Unit-test parsing for:
  - TCP listeners.
  - UDP listeners.
  - Established connections.
  - Multiple sockets sharing one PID and port.
  - Malformed or incomplete `lsof` output.
- Test refresh behavior at the 2-second interval and manual refresh.
- Test that scanning pauses when the menu closes and resumes with an immediate refresh when it opens.
- Test that listeners are visible by default and connections remain collapsed until expanded.
- Test that a listener and connection sharing the same process and port remain separate rows.
- Test slow, timed-out, malformed, and non-zero lsof results without overlapping subprocesses or losing the last valid snapshot.
- Profile closed-menu idle, an open menu with unchanged data, and a busy development machine with many connections.
- Test terminating a disposable local server and confirm the row disappears after refresh.
- Test permission/termination failure and confirm the row remains with an inline error.
- Build with XcodeGen and Xcode 26, then launch the actual `.app` and verify the menu-bar interaction on macOS 26.

## Assumptions

- “Ports currently running” means both local listeners and active connections.
- Listeners are the primary view; active connections are grouped separately in a collapsed section.
- Rows are process-level actions grouped by activity kind, protocol, and port. A stop action can close every port owned by that process, but the visible UI remains icon-only; tooltips and accessibility labels provide the clarification.
- No administrator-authentication helper is added in v1.
- No login-item registration or settings window is included initially.
