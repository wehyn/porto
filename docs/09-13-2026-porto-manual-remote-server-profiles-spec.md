# Porto Remote Server Profiles and SSH Connection Discovery Specification

## Problem Statement

Porto needs a clear, self-contained remote-server setup experience. Users may
already have useful SSH connection entries on this Mac, but those entries
should be proposed for review rather than silently becoming Porto targets.
Porto must also support a fully manual path for hosts that are not represented
in local SSH configuration.

The user wants Porto to always start on **This Mac**, and to connect to a
remote server only after the user has explicitly enabled and selected a server
profile in Porto Settings. Multiple remote profiles must be supported, but
Porto should inspect only one selected remote server at a time.

The user also wants remote process controls to be available. Remote
termination must remain bounded and identity-safe: it must use only the
configured SSH user's permissions, send SIGTERM before offering Force Kill,
and refuse to signal when the remote process no longer matches the row.

## Solution

Add a dedicated Settings screen where the user can discover, add, and manage
local remote-server profiles. The Add SSH Connection flow presents safe,
locally detected SSH candidates with a display ID and direct host/address. The
user explicitly selects candidates and presses Add to save them. An Add
manually action opens a form for entering the ID/display name, host, username,
SSH port, enabled state, and optional private-key file selected with a native
file picker.

New profiles start disabled. Saving a profile never connects to it. Enabling a
profile makes it available in Porto's target picker; selecting that enabled
profile starts the remote scan. Porto always starts on This Mac and does not
remember a remote target between launches.

The picker may read bounded, safe literal entries from `~/.ssh/config` and its
Include files to propose candidates, but discovery never contacts a host or
executes SSH. Once added, Porto materializes the candidate's direct host,
username, port, and optional key path into the profile and uses those values
directly with `/usr/bin/ssh`; runtime connections do not resolve aliases or
other SSH configuration. Key-based authentication remains mandatory, the
user's SSH agent remains usable, and normal `known_hosts` verification is
required. Password prompts, jump hosts, privilege escalation, and arbitrary
remote commands remain unsupported.

Remote inspection continues to use Porto's fixed Linux `ss` query and existing
TCP/UDP parsing, grouping, filtering, refresh, stale-snapshot, and Docker
metadata behavior. Remote rows become conditionally actionable: Stop sends
SIGTERM after remote revalidation, and Force Kill becomes available only if
the process survives the grace period and the user confirms the destructive
action.

## User Stories

1. As a Porto user, I want Porto to start on This Mac, so that opening the app never unexpectedly connects to a remote server.
2. As a Porto user, I want a Settings screen, so that I can manage remote servers without editing SSH configuration files.
3. As a Porto user, I want to add a remote server with a friendly display name, so that the target picker is easy to understand.
4. As a Porto user, I want to enter a hostname or IP address separately from the username, so that Porto can construct a predictable SSH connection.
5. As a Porto user, I want the username to be required, so that every remote profile clearly identifies the account Porto will use.
6. As a Porto user, I want the SSH port to default to 22, so that normal servers require no extra setup.
7. As a Porto user, I want to change the SSH port, so that I can monitor servers using a nonstandard SSH port.
8. As a Porto user, I want to choose a private key with a native file picker, so that I do not need to type or paste a sensitive path manually.
9. As a Porto user, I want Porto to use my SSH agent when no profile-specific key is selected, so that keys already loaded in the agent continue to work.
10. As a Porto user, I want Porto never to store private-key contents or passwords, so that profile persistence does not become credential storage.
11. As a Porto user, I want profiles stored only on this Mac, so that server details are not synchronized or sent to another service.
12. As a Porto user, I want display names to be unique, so that two target-picker entries cannot be confused.
13. As a Porto user, I want invalid host, username, and port values rejected, so that Porto cannot interpret profile fields as shell commands or malformed SSH arguments.
14. As a Porto user, I want to save a profile even when its server is temporarily unavailable, so that a transient outage does not erase my configuration.
15. As a Porto user, I want new profiles to start disabled, so that adding a profile has no network side effect.
16. As a Porto user, I want an Enabled toggle for every profile, so that I can explicitly control which saved servers Porto may contact.
17. As a Porto user, I want disabled profiles excluded from the target picker, so that I can tell which servers are currently available for inspection.
18. As a Porto user, I want enabling a profile not to connect immediately, so that changing a setting only authorizes the profile and does not start an unexpected scan.
19. As a Porto user, I want selecting an enabled profile to start its scan, so that remote inspection happens only through an intentional target choice.
20. As a Porto user, I want Test Connection to be a deliberate Settings action, so that I can verify a profile without saving or selecting it first.
21. As a Porto user, I want Test Connection disabled for disabled profiles, so that a disabled profile can never launch an SSH process.
22. As a Porto user, I want multiple remote profiles, so that I can manage all of my development and hosted servers in one place.
23. As a Porto user, I want profiles listed alphabetically by display name, so that the Settings list and target picker remain predictable.
24. As a Porto user, I want only one remote server selected at a time, so that Porto remains lightweight and does not create multiple concurrent remote scans.
25. As a Porto user, I want Porto to retain the selected profile while the popover is open, so that normal refreshes continue inspecting the same server.
26. As a Porto user, I want closing the popover to stop remote refreshes, so that Porto does not keep polling remote servers while hidden.
27. As a Porto user, I want reopening Porto to preserve This Mac as the application-start default, so that a later launch never begins with a remote connection.
28. As a Porto user, I want editing a selected profile to cancel the old scan and reconnect using the new values on the next refresh, so that stale connection details are not used.
29. As a Porto user, I want disabling the selected profile to return Porto to This Mac and cancel remote work, so that an off profile is never contacted.
30. As a Porto user, I want deleting the selected profile to return Porto to This Mac, so that no deleted server remains active.
31. As a Porto user, I want deletion to require confirmation, so that an accidental click does not remove a saved profile.
32. As a Porto user, I want a failed connection to leave the profile enabled, so that I can retry after fixing the network, key, or server.
33. As a Porto user, I want Porto to require a pre-trusted host key, so that the app cannot silently accept an impersonated or unexpected server.
34. As a Porto user, I want Porto to use the standard known-hosts verification flow, so that I can establish trust once through normal SSH tooling and then use Porto.
35. As a Porto user, I want password and passphrase prompts disabled, so that Porto remains noninteractive and key-only.
36. As a Porto user, I want Porto to connect directly to the configured host, so that profiles do not depend on aliases, includes, Match rules, or jump-host configuration.
37. As a Porto user, I want remote listeners displayed, so that I can see services accepting connections on the selected Linux server.
38. As a Porto user, I want remote active connections displayed, so that I can inspect outbound and established activity as well as listeners.
39. As a Porto user, I want remote rows to retain the existing TCP/UDP classification and Docker labeling, so that changing profile setup does not change the meaning of the port monitor.
40. As a Porto user, I want remote Stop controls for rows with verified process ownership, so that I can gracefully stop a remote process from Porto.
41. As a Porto user, I want remote Stop to send SIGTERM first, so that the process has an opportunity to clean up.
42. As a Porto user, I want Force Kill to appear only after SIGTERM fails to end the process, so that SIGKILL is an escalation rather than the default action.
43. As a Porto user, I want Force Kill to require confirmation, so that destructive process termination is intentional.
44. As a Porto user, I want remote Force Kill to use only the configured SSH user's permissions, so that Porto never silently escalates privileges.
45. As a Porto user, I want remote actions available for listeners and connections, so that I can stop the process regardless of which kind of socket row exposed it.
46. As a Porto user, I want rows without a remote PID or owner to show disabled controls, so that Porto never tries to kill a process using only a port number.
47. As a Porto user, I want Porto to revalidate the PID, process name, local port, and socket owner before every remote signal, so that a stale row cannot terminate a replacement process.
48. As a Porto user, I want termination canceled when remote identity changes, so that Porto fails safely instead of guessing which process to kill.
49. As a Porto user, I want termination canceled when the profile is disabled, deleted, or no longer selected, so that actions cannot escape their original target.
50. As a Porto user, I want only one scan or termination workflow active at a time, so that remote commands remain bounded and results cannot race each other.
51. As a Porto user, I want Porto to reuse its existing compact progress and failure treatment, so that remote actions do not introduce a second, complicated status system.
52. As a Porto user, I want raw SSH output, private-key contents, and process snapshots kept out of the UI and logs, so that sensitive connection details are not disclosed.
53. As a Porto user, I want local This Mac scanning and process termination to continue working as before, so that adding remote profiles does not regress the primary Porto workflow.
54. As a Porto user, I want Porto to remain a menu-bar-only app, so that Settings does not introduce a Dock icon or an unrelated main application window.
55. As a Porto user, I want Porto to propose safe SSH connections already configured on this Mac, so that I do not need to retype common hosts.
56. As a Porto user, I want to select detected connections before pressing Add, so that discovery never saves or contacts a server by itself.
57. As a Porto user, I want an Add manually action with ID, host, and username fields, so that I can add a server that was not detected locally.
58. As a Porto user, I want to refresh the detected list, so that configuration changes appear without restarting Porto.

## Implementation Decisions

- The SSH configuration catalog is used only as a local proposal source for the
  Add SSH Connection picker. It performs bounded reads of `~/.ssh/config` and
  safe literal Include files, never contacts a host, launches SSH, executes
  config-driven commands, or silently imports a candidate.

- Discovery accepts only literal Host entries and conservative scalar metadata:
  a safe HostName when present, a safe User when present, a valid Port, and a
  literal IdentityFile path. Wildcards, negated patterns, Match-controlled
  values, token expansion, shell fragments, and unsafe values are ignored.
  Missing metadata uses direct defaults (the Host entry itself, the local
  username, port 22, and no profile-specific key).

- A discovered candidate is not a target or a persisted profile. The user must
  select it and press Add. Import creates a new disabled profile with a stable
  profile UUID; later scans pass the materialized fields directly and never
  consult the alias or SSH configuration again.

- A remote target is represented by a stable profile identifier, not by an SSH
  alias or resolved hostname. This permits multiple profiles to use the same
  host with different usernames, ports, or keys.

- The remote profile data contract contains a stable identifier, display name,
  host, username, port, optional identity-file URL or path, and enabled state.
  New profiles default to disabled. Profile identifiers remain stable when a
  profile is edited so cached target state and SwiftUI identity do not change
  merely because the host details changed.

- Profile persistence is local-only. A small profile store serializes profile
  metadata in local application preferences. It does not persist port
  snapshots, process lists, SSH output, passwords, passphrases, private-key
  contents, or telemetry.

- The profile store is injected behind a protocol or equivalent test seam.
  Production uses the app's local preferences; tests use an isolated in-memory
  or temporary preferences store. Store writes are atomic enough that a failed
  update cannot silently replace the entire profile list with an empty list.

- Settings is a dedicated secondary configuration window opened from the
  existing overflow menu. Porto remains a menu-bar-only application without a
  Dock presence or main content window.

- Settings presents all saved profiles alphabetically by display name. It
  supports add, edit, delete, enable, disable, choose-key-file, save, cancel,
  and Test Connection actions. There is no drag-to-reorder control in the first
  version.

- The target picker contains This Mac first, followed by enabled remote
  profiles in alphabetical display-name order. Disabled profiles remain
  visible in Settings but are not selectable targets and cannot start scans.

- The application starts with This Mac selected and does not persist the last
  selected target. Saving, enabling, or editing a profile does not itself
  select it or open an SSH connection.

- Disabling or deleting the selected profile increments the active session,
  cancels the remote scanner, clears pending remote work, and switches to This
  Mac. Deletion requires confirmation. Editing a selected enabled profile
  cancels the old scan and permits a new scan on the next normal refresh.

- A failed Test Connection or remote scan does not disable a profile. The
  profile remains available for a later retry. Required-field and validation
  failures prevent saving; connection failures do not.

- The host field accepts one hostname or IP address, including IPv4 and IPv6
  literals. It rejects whitespace, control characters, NUL values, shell
  fragments, and combined values such as `user@host`. The username is kept in a
  separate required field and is passed as its own SSH argument. The port is an
  integer from 1 through 65535 and defaults to 22.

- Display names are required and unique under a case-insensitive comparison.
  Hostnames may repeat when the profiles differ in user, port, key, or other
  stored connection details.

- Key selection uses a native file picker. Porto stores only the selected file
  reference or path and never reads, copies, or embeds private-key material.
  A missing, unreadable, or rejected key does not erase the profile; it causes
  the explicit test or scan to fail with the existing compact failure treatment.

- Authentication is key-only. Porto inherits the user's SSH agent environment
  and may pass the profile's selected identity file. It disables password and
  passphrase prompts. A passphrase-protected key may work when already
  unlocked by the user's agent; Porto does not provide an interactive prompt.

- Remote execution launches the system OpenSSH executable directly through
  `Foundation.Process`. The command builder passes host, username, port, and
  optional identity file as separate arguments. It uses an explicit empty SSH
  configuration or equivalent so user aliases and connection directives cannot
  override the manual profile. Standard known-hosts verification remains
  enabled and unknown or changed host keys are rejected.

- Remote SSH execution remains noninteractive and bounded. It disables TTY
  allocation, password prompts, local commands, forwarding, remote-command
  replacement, and Porto-owned persistent control masters. It preserves the
  existing connect timeout, output limits, cancellation behavior, and
  single-child guarantee.

- Direct connections are the only supported topology. Jump hosts, tunnels,
  proxy commands, arbitrary SSH options, and user-entered remote commands are
  out of scope.

- Remote inspection continues to run the source-controlled fixed Linux `ss`
  query with numeric addresses and ports, one socket per line, TCP and UDP
  selection, process metadata when permitted, and extended socket metadata.
  Optional bounded Docker metadata remains part of the existing remote scan
  behavior and is not configurable per profile.

- The existing remote parser continues to classify TCP LISTEN records as
  listeners, unconnected bound UDP sockets as listeners, and records with a
  concrete peer as connections. Existing grouping, common-port filtering,
  Docker coalescing, diagnostics, stale snapshots, retry backoff, and
  popover-visible refresh behavior are preserved.

- Remote scan status must describe a short-lived SSH command rather than a
  persistent connection. The status must not imply that Porto maintains an
  idle SSH session. Remote rows are no longer universally read-only, but rows
  without enough process metadata remain non-actionable.

- The monitor remains the orchestration seam for target selection, profile
  enablement, scan cancellation, stale-state handling, and termination
  lifecycle. It receives a profile store, remote scanner factory, and remote
  terminator or equivalent injected collaborators so target transitions can be
  tested without a live server.

- Remote process controls are available for listener and connection rows when
  the row contains a usable remote PID and owner identity. If process metadata
  is unavailable, the control is presented as disabled with the existing
  minimal lock/help treatment. Porto never attempts a remote kill by port
  number alone.

- Remote Stop follows the existing two-stage termination state machine. It
  cancels or waits for the active scan, revalidates the remote row, sends
  SIGTERM through the selected profile, and waits through a bounded grace
  period. If the process remains alive, the row exposes Force Kill for that
  current remote identity.

- Force Kill is never automatic. It requires an explicit confirmation and a
  fresh remote revalidation immediately before sending SIGKILL. The action is
  available only to the configured SSH user; Porto never invokes `sudo`,
  `doas`, a privileged helper, a remote agent, or a remote service installation.

- Remote revalidation must confirm the same target profile, PID, process name,
  local port, and socket ownership represented by the row. If the process has
  exited, the socket disappeared, the owner changed, the process name changed,
  the profile was disabled, or the selected target changed, Porto aborts the
  signal attempt and requests or permits a fresh scan.

- Remote termination commands are built from reviewed command shapes and
  validated scalar values. No user-supplied shell fragment, profile display
  name, raw endpoint, or arbitrary command is interpolated into a remote shell
  command. The remote action runner shares the existing cancellation,
  timeout, single-flight, and late-result rejection rules.

- The existing compact spinner, failure indicator, confirmation dialog, and
  accessibility/help conventions are reused. This feature does not add a
  separate remote-specific status taxonomy or expose raw SSH stderr.

- Local scanning continues to use the existing direct `/usr/sbin/lsof` path,
  local process identity checks, and local SIGTERM/Force Kill behavior. The
  manual profile feature must not change local visibility policy or local
  termination safeguards.

- Existing application target and row identity contracts are extended so a
  remote profile identifier and remote process identity cannot be confused with
  a macOS `ProcessIdentity`. Remote identity is target-scoped and must never be
  accepted by the local Darwin signal sender.

- No automatic connection or automatic profile save occurs during discovery.
  Existing literal SSH entries, including entries such as OrbStack's `orb`,
  are merely user-selectable proposals. Include traversal is bounded and safe;
  Match, wildcard, negated, ProxyJump, ProxyCommand, and other connection
  behavior are not carried into the saved profile or runtime command.

## Testing Decisions

- Tests must assert externally visible behavior and safety outcomes rather than
  private implementation details. The primary seam is the monitor with an
  injected profile store, remote scanner, and remote terminator. This allows
  profile lifecycle, target selection, cancellation, default-local behavior,
  and termination decisions to be tested without a live SSH host.

- Profile model and store tests must cover required fields, host validation,
  username validation, port defaulting and range checking, case-insensitive
  display-name uniqueness, stable identifiers, disabled-by-default behavior,
  local persistence, atomic replacement, multiple profiles, alphabetical
  ordering, and save-on-connection-failure behavior.

- Settings interaction tests or manual acceptance must cover opening Settings
  from the overflow menu, adding and editing profiles, native key selection,
  disabled Test Connection, explicit Test Connection, save/cancel behavior,
  deletion confirmation, enablement, and the absence of automatic connections
  on save or enable.

- SSH discovery and picker tests must cover bounded local config reads,
  metadata/default extraction, literal and unsafe entry handling, Include and
  Match boundaries, deterministic ordering and stable candidate IDs, explicit
  selection, duplicate filtering, field mapping, disabled-by-default imports,
  refresh, Add manually, and the absence of SSH/network side effects while
  the picker is opened or refreshed.

- Monitor behavior tests must cover This Mac as the initial target, enabled
  profiles as the only remote targets, multiple enabled profiles, alphabetical
  target ordering, selection-triggered scans, one active target, disabled or
  deleted selected profiles returning to This Mac, profile edits reconnecting
  on the next refresh, failures retaining enabled state, popover-close
  cancellation, and rejection of late results.

- SSH command contract tests must verify direct executable launch, explicit
  profile arguments, empty-config behavior, default and custom ports,
  username separation, optional identity-file handling, inherited agent
  environment, host-key verification options, no password prompts, no TTY,
  no forwarding, no persistent control master, bounded execution, cancellation,
  and rejection of unsafe host or username values. Tests must prove that key
  contents are never read or placed in command arguments.

- Existing remote parser and scanner tests remain authoritative for `ss`
  classification, IPv4/IPv6 handling, TCP/UDP grouping, missing process
  metadata, Docker labels, common-port filtering, diagnostics, timeout
  mapping, and stale snapshots. The target identity in those tests changes from
  an alias to a stable profile identifier.

- Remote termination tests must use a fake remote command executor or equivalent
  injected terminator. They must prove that Stop sends SIGTERM only after
  revalidation, Force Kill is unavailable before the grace period, Force Kill
  requires confirmation, SIGKILL is sent only after a second revalidation, the
  configured SSH user's permissions are the only authority, no sudo/doas path
  is attempted, listeners and connections can be actioned, missing PIDs disable
  controls, and PID/name/port/socket-owner changes cancel the action.

- Termination tests must also cover profile disablement, target changes,
  cancellation, remote process exit, permission failure, host-key failure,
  connection timeout, malformed validation output, and a late remote result
  that must not publish into a different target session.

- Manual runtime acceptance must launch the generated macOS application and
  verify the menu-bar-only surface, This Mac startup behavior, Settings window,
  local-only persistence, profile enablement, alphabetical targets, direct
  connection behavior, pre-trusted host-key enforcement, key-only login, and
  no background remote command while the popover is closed.

- Manual remote termination acceptance must use a disposable Linux process owned
  by the configured SSH user. It must verify graceful SIGTERM, Force Kill after
  the grace period, confirmation, missing-owner disabled controls, and refusal
  to signal a replacement process after the original row becomes stale.

- The final verification must run the existing automated suite plus the new
  profile, settings, command-contract, monitor, and remote-termination tests.
  A successful build alone is not sufficient acceptance.

## Out of Scope

- Network-wide host discovery, Bonjour/mDNS probing, ARP scanning, reachability
  checks, authentication attempts, or any remote command while populating the
  picker.
- Applying SSH aliases, Include semantics, Match rules, ProxyJump,
  ProxyCommand, tunnels, forwarding, or arbitrary SSH options to a runtime
  Porto connection. The picker may read bounded literal config metadata only.
- Password authentication, passphrase prompts, password storage, and private-key
  content storage.
- iCloud or any other profile synchronization.
- Automatic connection when a profile is saved or enabled.
- Background scans of all enabled servers or a multi-host dashboard.
- Remote termination by port number without verified process ownership.
- `sudo`, `doas`, privileged helpers, remote agents, launch daemons, or
  administrator authentication.
- Remote firewall changes, socket destruction, packet capture, traffic
  measurement, historical activity, notifications, telemetry, or raw SSH logs.
- Changing the existing This Mac scanner, local visibility policy, or local
  process-safety contract.
- Drag-to-reorder profiles, profile groups, search, tags, or per-server custom
  scan filters.

## Further Notes

- This specification supersedes the earlier remote-target decisions that made
  SSH aliases the target model and all remote rows read-only. The manual profile
  model and conditionally actionable remote rows are intentional product
  changes, not optional refinements.

- The profile's enabled state is an authorization boundary for network access,
  not a connection state. Enabling makes a profile selectable; selecting it is
  what starts inspection. Test Connection is an explicit Settings action and
  must obey the same enabled requirement.

- Existing remote scan results remain in-memory only and remain scoped to the
  profile identifier. A failed refresh may show the last successful snapshot as
  stale, but disabling or deleting the profile must prevent that profile from
  being contacted again.

- The highest test seam is the monitor and its injected collaborators. Lower
  command-contract tests are still required because direct SSH argument safety
  and profile-to-command mapping cannot be proven by parser tests alone.

- The issue-tracker publication step requires the project's configured tracker
  and the `ready-for-agent` triage label vocabulary. Those integrations were
  not available in the current environment, so this file is a local draft until
  the project setup is completed.
