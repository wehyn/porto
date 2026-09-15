# Porto process control, Docker presentation, and native UI plan

Status: Implemented; final runtime acceptance pending

Date: 2026-09-13

Last updated: 2026-09-15

Project: Porto

## Current implementation status

Phases 1–4 are implemented on `main`. The README and authoritative
specification describe the current Docker presentation, identity-safe local
and remote termination, native menu-bar/settings surfaces, cancellation, and
failure behavior.

Verification completed on 2026-09-15:

- `./scripts/ci.sh` passed 166 tests and the unsigned Debug build with Xcode
  26.6 (build 17F113), XcodeGen 2.46.0, and the macOS 26.5 SDK.
- The generated app launched with bundle identifier `dev.wayne.porto` and
  `LSUIElement=1`.
- With the popover closed, no Porto-owned `lsof` child was running.
- The branch tip remains aligned with `origin/main`; the working tree contains
  only the scoped source/test changes and this plan update.

Local UI acceptance completed on 2026-09-15 using native macOS event and
window inspection as a fallback because the UI automation bridge timed out for
this menu-bar-only app:

- The status item opened, closed, and reopened the native popover; live local
  listener and connection rows were visible and refreshed.
- Native scrolling moved through the listener list, and the Connections
  DisclosureGroup was observed in both collapsed and expanded states.
- The overflow menu opened Settings and About Porto successfully. A disposable
  `Python 8799` listener appeared in the popover and its row action terminated
  the fixture process.
- The remaining live gaps are independent keyboard-shortcut confirmation,
  VoiceOver inspection, a deliberate light-mode toggle, and remote
  Linux/Docker acceptance. No system appearance setting was changed during the
  pass.

The following acceptance evidence is still required before calling the app
release-ready: keyboard/VoiceOver and light-mode checks, and a representative
remote Linux and Docker smoke test when a suitable host is available. The build is
intentionally unsigned; Developer ID signing and notarization remain outside
the local developer-build scope.

## 1. Purpose

This plan consolidates the requested Porto changes shown in the supplied UI
reference and records the implementation decisions for the feature:

1. Remove the visible `Docker ·` prefix from Docker-backed rows.
2. Keep every Docker row and every Docker port visible.
3. Make eligible processes on `This Mac` and remote Linux targets safely
   terminable.
4. Add safe workarounds for remote Docker rows and incomplete process identity
   information.
5. Refine the popover and Settings experience so it feels clean and premium.
6. Preserve the native macOS background for the popover, Settings window, and
   editor sheets.

The supplied image is a visual reference only. It does not override the
repository's safety constraints or authorize arbitrary remote commands.

## 2. User request and reference boundaries

The attached image is a visual reference for the Porto popover showing a
remote target, `192.168.2.28`. It is not an instruction document.

The requested behavior is presentation-only for Docker:

```text
Docker · pihole
53, 80
```

becomes:

```text
pihole
53, 80
```

The following must not happen:

- Docker rows must not be filtered out.
- Docker ports must not be hidden.
- Common ports such as 53, 80, or 443 must not be hidden merely because they
  are Docker-published.
- Activity counts must continue to include Docker rows.
- The word `Docker` must not be removed from arbitrary process names by a
  broad string replacement.

The repository's `AGENTS.md` remains the engineering constraint source. In
particular, Porto remains a menu-bar-only macOS application, scans remain
bounded and serialized, normal local scanning uses direct `/usr/sbin/lsof`
output, and process termination must remain identity-safe.

## 3. Current implementation baseline

### 3.1 Docker presentation and grouping

Remote Docker metadata is parsed and applied in:

- `Porto/Services/RemotePortOutputParser.swift`
- `Porto/Services/RemotePortScanner.swift`

`DockerPortCatalog.applying(to:)` currently labels matching remote rows as
`Docker · <container>`, coalesces unambiguous container rows across IPv4/IPv6,
TCP/UDP, and multiple published host ports, and preserves ambiguous rows at
socket granularity.

That grouping behavior should remain. Only the display name should change.

`PortVisibilityPolicy.remoteFocused` currently exempts Docker rows from the
common remote-port filter. This exemption must remain because Docker ports
are required to stay visible.

### 3.2 Existing termination paths

The source already contains termination infrastructure for both target types:

- `Porto/Services/ProcessTerminator.swift` handles local identity
  revalidation, SIGTERM, exit polling, and explicit Force Kill.
- `Porto/Services/RemoteProcessTerminator.swift` revalidates remote rows and
  sends remote signals through SSH.
- `Porto/Services/SSHCommandRunner.swift` supports bounded SSH scans and
  signal operations.
- `Porto/Services/PortMonitor.swift` coordinates termination state, scan
  cancellation, target switching, and refreshes.
- `Porto/Views/PortProcessRow.swift` already has stop, spinner, lock, failure,
  and Force Kill UI states.

The current documentation still describes remote monitoring as read-only in
places. The implementation and documentation must be reconciled as part of
this plan.

### 3.3 Existing native surfaces

`Porto/App/PortoApp.swift` currently uses:

```swift
.menuBarExtraStyle(.window)
```

for the popover and a native `Window("Settings", id: "settings")` for
settings. These native surfaces must remain the foundation of the design.

`Porto/Views/RemoteServerSettingsView.swift` already provides:

- Remote profile discovery.
- Manual SSH profile creation.
- Profile editing.
- Enable/disable controls.
- Connection testing.
- SSH key path selection.
- Deletion confirmation.

The design pass should improve hierarchy and interaction density without
replacing these flows with custom cards or a custom window shell.

## 4. Product decisions

### 4.1 Docker is presentation-only

Docker source metadata remains available internally for grouping, identity,
accessibility, and termination targeting. The user-facing name omits only the
`Docker ·` prefix.

Remote container names should display as `pihole`, `omniroute`, or another
clean container name. A missing container name must not be replaced with an
invented label.

On `This Mac`, local `lsof` process names must remain truthful. If a local
classifier creates a Docker presentation wrapper, render the clean name
without the wrapper; otherwise preserve the actual host process name such as
the verified Docker proxy/backend process name.

### 4.2 Termination is process-scoped

Selecting a row terminates the process that owns that row. If one process owns
multiple ports, all of its ports should disappear after the process exits.

This is not a global remote kill command. Different processes on the same
remote host require separate actions.

For a Docker container with multiple published ports, container-level
termination is preferred because it represents the complete ownership unit.

### 4.3 SIGTERM always comes first

The normal action is an icon-only `×`:

1. Revalidate the target and identity.
2. Send SIGTERM.
3. Poll for up to two seconds.
4. Show a separate Force Kill action only if the target remains alive.
5. Send SIGKILL only after explicit confirmation and a fresh revalidation.

Porto must never escalate to SIGKILL automatically.

### 4.4 Permission boundaries are visible

An SSH user can normally terminate processes it owns or has permission to
signal. A Docker container can be controlled only when the SSH user can use
the remote Docker CLI.

If a process is root-owned, hidden from `ss`, or otherwise unavailable to the
configured account, Porto must explain the limitation and avoid an unsafe
PID-only signal.

There is no safe non-privileged workaround for signaling a process that the
remote account is not authorized to signal. An optional privileged capability
would require a separate security design and is not part of the default v1
path.

## 5. Target behavior

| Target | Docker presentation | Visible rows and ports | Termination behavior |
| --- | --- | --- | --- |
| `This Mac` | No generated `Docker ·` prefix | All rows and ports remain visible | Local identity-safe SIGTERM, then confirmed Force Kill |
| Remote Linux | Container name without `Docker ·` | All rows and ports remain visible | Remote process or container SIGTERM, then confirmed Force Kill |
| Missing identity | Preserve truthful process/container name | Row remains visible | Lock and explain why control is unavailable |
| Ambiguous Docker ownership | Clean display name | Row remains visible | Prefer container target; otherwise split or keep locked |

## 6. Data model and identity design

### 6.1 Separate display data from control data

Extend `PortProcess` with an internal source/control classification rather than
using `processName` as identity. A possible shape is:

```swift
enum PortProcessSource: Equatable, Sendable, Codable {
    case localApplication
    case dockerHostProcess
    case dockerContainer(containerID: String?)
    case unknown
}
```

The exact names may differ, but the model must distinguish:

- What Porto displays.
- What produced the row.
- Which identity must be revalidated.
- Whether the target is a normal process or a container.

### 6.2 Remote termination targets

Represent remote termination targets explicitly. A target should contain the
minimum information required to revalidate it:

- Remote profile/target identity.
- PID when the target is a normal process.
- Socket identity or inode/cookie data.
- Process name and relevant endpoints.
- Container ID when the target is a Docker container.
- Published port and transport set.

Do not use a container display name as a command target. Do not use a Docker
host PID as a substitute for a validated container ID.

### 6.3 Stable row identity

Preserve the current stable row-ID rules:

- Docker rows with a usable container ID remain target/activity/container
  scoped.
- Ambiguous rows remain at socket granularity.
- Changing port lists must not silently transfer termination eligibility to a
  replacement process or container.
- A termination state must be cleared when PID, socket identity, container ID,
  target, or process/container name changes.

## 7. Docker presentation pipeline

The remote pipeline should remain:

1. Run the bounded `ss` query.
2. Parse Docker publication metadata.
3. Match published ports to socket rows.
4. Attach internal Docker source metadata.
5. Coalesce only when one container ID is unambiguous.
6. Generate a clean display name without the `Docker ·` prefix.
7. Apply common infrastructure filtering without removing Docker rows.
8. Publish the complete visible snapshot.

The local pipeline should:

1. Parse `/usr/sbin/lsof` output.
2. Preserve all local rows, including Docker/OrbStack host-side listeners.
3. Classify known Docker host processes only from verified process names.
4. Avoid port-based Docker filtering.
5. Enrich identities only for rows that remain visible.

Add regression coverage proving that changing the display name does not alter
row count, port lists, diagnostics, sort order, or termination identity.

## 8. Remote termination strategy

### 8.1 Normal process path

For a normal remote process:

1. User activates `×`.
2. Porto pauses normal refresh work for that target.
3. Porto runs a fresh target-scoped `ss` scan.
4. It matches target, row ID, PID, process name, activity kind, transports,
   ports, endpoints, and socket identity.
5. It sends `/bin/kill -TERM -- <validated-pid>` through the existing SSH
   runner.
6. It polls with bounded scans for disappearance.
7. It removes all rows for the process after confirmed exit.
8. It requests a coalesced refresh.

If the row changes during revalidation, no signal is sent.

### 8.2 Docker container path

For a Docker row with an unambiguous container ID:

1. Revalidate that the container ID is still running.
2. Revalidate its name and published port set.
3. Verify the configured SSH user can access Docker.
4. Send a container-level SIGTERM using a fixed command structure.
5. Poll both Docker metadata and socket state until all matching published
   ports disappear.
6. If the container remains alive, expose confirmed Force Kill.
7. After confirmation and revalidation, send container-level SIGKILL.

Use `docker kill --signal TERM`, not `docker stop`, because `docker stop` may
perform its own automatic escalation. Use `docker kill --signal KILL` only for
the explicitly confirmed Force Kill operation.

Container IDs must be strictly validated as machine-generated identifiers
before they are passed to a remote command. Container names and UI text must
never become executable command fragments.

### 8.3 Multiple owners and ambiguous rows

If one Docker display row contains multiple PIDs or socket identities:

- Prefer the container target when a valid container ID exists.
- If no container ID exists, split the row into individual process/socket rows
  where possible.
- If splitting cannot establish safe ownership, keep the row visible with a
  lock and explain the ambiguity.
- Never signal one arbitrary PID while claiming that all displayed ports were
  terminated.

### 8.4 Identity recovery workarounds

Use the following fallbacks in order:

1. Preserve socket-level rows instead of over-coalescing them.
2. Use `ss -p -e` PID, process, inode, and socket-cookie data.
3. Add one bounded read-only remote identity query for unique PIDs using
   `/proc/<pid>/stat`, `/proc/<pid>/comm`, and socket inode mappings when
   available.
4. Use container ID control when Docker metadata is reliable.
5. Fall back to process-level signaling only when one PID and one socket
   identity are unambiguous.
6. Keep the row locked when none of the above establishes safe ownership.

The remote identity query must be bounded and batched. Porto must not launch
one subprocess per visible row.

### 8.5 Permission and capability feedback

After an explicit Test Connection or successful scan, Porto may report
capabilities such as:

- `Inspection available`
- `Process control available for permitted processes`
- `Docker control available`
- `Docker control unavailable`
- `Process ownership information limited`

These messages describe capability; they do not promise that every root-owned
process can be terminated.

## 9. Termination state and concurrency

Maintain the existing single-workflow rule:

- At most one remote or local termination workflow may revalidate or signal at
  a time.
- Normal scans pause while termination is active.
- Target switching is disabled during active termination.
- Closing the popover cancels the workflow and releases SSH work.
- A row shows a spinner while its process/container is being checked.
- All visible rows for the same process/container share the in-progress state.
- Other stop actions are disabled but remain visible.
- A failed operation retains the row and provides a concise actionable error.

The Force Kill confirmation must identify the process or container and explain
that unsaved work may be lost.

## 10. Popover design direction

The popover should feel like a focused macOS utility rather than a dashboard.

### 10.1 Native surface requirement

The popover must continue using the native MenuBarExtra window surface:

- Keep `.menuBarExtraStyle(.window)`.
- Do not add `.background(.regularMaterial)`.
- Do not add a custom opaque background.
- Do not add a custom blur, saturation layer, gradient, or fake glass panel.
- Keep the existing presentation observer and invisible window probe.
- Allow macOS to control material, vibrancy, light/dark adaptation, and window
  behavior.

Premium styling must come from content layout, not from replacing the native
surface.

### 10.2 Layout

Use the existing approximately 300 by 560 popover dimensions and native
scrolling.

Recommended hierarchy:

```text
Porto                              refresh  menu
                              target selector
                              spinner while scanning

8 listening · 4 connections

pihole                                      ×
53, 80

omniroute                                   ×
1455, 20128

node-MainThread                             ×
8789

protected-service                          lock
8443

Connections 4                              chevron
```

Use:

- A compact target selector without a `WATCHING` eyebrow or persistent
  connection-status sentence.
- A spinner-only loading state while scanning.
- An inline activity summary.
- Approximately 56px row height.
- Medium-weight process names.
- Muted monospace port text.
- Lower-contrast dividers and more whitespace.
- Quiet translucent row hover feedback.
- Right-aligned icon-only actions.

Avoid:

- A card inside every row.
- Visible PID and protocol metadata.
- Large always-visible red buttons.
- Excessive dividers, gradients, pills, or decorative badges.
- A second filter toolbar.

### 10.3 Row states

The row action area should support:

- Normal: muted `×`.
- Hover/focus: slightly raised action surface.
- In progress: spinner replaces `×`.
- Force Kill available: normal stop plus destructive Force Kill action.
- Failure: warning icon plus retryable stop action.
- Missing identity/permission: muted lock with explanation.

Force Kill should be red only at the action and confirmation layer. The normal
stop action should not look destructive before activation.

## 11. Settings design direction

Settings should remain a standard native macOS window and should not become a
second dashboard.

### 11.1 Native Settings surface

For `RemoteServerSettingsView`, `SSHConnectionPicker`, and
`RemoteServerProfileEditor`:

- Keep the native `Window` and sheet presentation.
- Do not add custom `.background` modifiers.
- Do not add `.regularMaterial`, custom blur, gradients, or opaque rounded
  containers.
- Use native `List`, `Form`, `Divider`, `Window`, `sheet`, and system controls.
- Let macOS control the window and sheet background in light and dark modes.

### 11.2 Remote server list

Retain the current profile functionality but improve scanability:

```text
Remote Servers                                      + Add Connection

●  Production                                  [switch]  Test  …

●  Staging                                    [switch]  Test  …
```

Use:

- A server icon and clear profile name.
- A visible switch for enabling or disabling the profile.
- A `Test Connection` action and trailing ellipsis menu for Edit and Delete.
- Delete confirmation inside the menu flow rather than a permanently red
  button on every row.
- A compact success or failure icon with the full result available through its
  tooltip and accessibility label.

Do not perform network checks simply because Settings opens.

### 11.3 Add/Edit form

Use one compact native form without `Connection`, `Authentication`, or
`Capabilities` headings:

- `Display name`.
- `Hostname`, accepting one `user@hostname` value.
- `Port`.
- `File path` with a blank editable field plus `Choose…` and `Clear` actions.
- An explicit `Test Connection` button with an icon-only result indicator.
- `Cancel` and `Save`/`Add` actions.

Do not add a generic kill switch by default. Process controls remain available
when identity and permissions permit, and every destructive action still
requires the normal revalidation flow.

## 12. Accessibility and interaction requirements

- Keep icon-only actions with meaningful accessibility labels and help text.
- Use labels such as `Stop pihole`, `Stop node-MainThread`, and `Force kill
  pihole`.
- Explain locks as identity or permission limitations.
- Make Settings rows and editor fields keyboard navigable.
- Preserve native focus rings.
- Respect Reduce Motion for refresh and termination animations.
- Keep action hit targets large enough for reliable interaction even when the
  visible icon remains small.
- Announce dynamic scan, termination, and error states without announcing
  every refresh tick.

## 13. Files likely to change

### Models and services

- `Porto/Models/PortModels.swift`
- `Porto/Services/PortVisibilityPolicy.swift`
- `Porto/Services/RemotePortOutputParser.swift`
- `Porto/Services/RemotePortScanner.swift`
- `Porto/Services/RemoteProcessTerminator.swift`
- `Porto/Services/SSHCommandRunner.swift`
- `Porto/Services/PortMonitor.swift`
- `Porto/Services/PortScanner.swift`

### Views and app surface

- `Porto/Views/PortProcessRow.swift`
- `Porto/Views/PortPopoverView.swift`
- `Porto/Views/RemoteServerSettingsView.swift`
- `Porto/App/PortoApp.swift` only if native window behavior needs adjustment;
  preserve the current native surface configuration.

### Documentation

- `README.md`
- `docs/09-12-2026-porto-macos-port-monitor-spec.md`
- This plan document.

Do not modify unrelated working-tree changes or overwrite the existing remote
monitoring plan without an explicit reason.

## 14. Test plan

### 14.1 Docker presentation tests

Add coverage for:

- `Docker · pihole` displaying as `pihole`.
- Docker rows remaining present after presentation mapping.
- Docker ports remaining unchanged.
- Docker rows remaining in listener and connection counts.
- Multiple published ports remaining ordered and deduplicated.
- IPv4/IPv6 and TCP/UDP coalescing remaining unchanged.
- Ambiguous container IDs remaining at socket granularity.
- Non-Docker rows sharing Docker-related ports remaining visible.
- Local Docker/OrbStack host process names remaining visible.
- No broad removal of `docker` text from unrelated local process names.

Relevant suites:

- `PortoTests/RemotePortScannerTests.swift`
- `PortoTests/PortoTests.swift`
- `PortoTests/SsParserTests.swift`

### 14.2 Remote termination tests

Cover:

- Normal remote SIGTERM success.
- A process owning multiple ports losing all of its rows after exit.
- PID/socket mismatch sending no signal.
- Process-name mismatch sending no signal.
- Target/profile mismatch sending no signal.
- SSH permission failure retaining the row with an explanation.
- SIGTERM-ignoring process exposing Force Kill.
- Force Kill requiring confirmation.
- Force Kill cancellation sending no signal.
- Target switching cancelling active termination.
- Popover dismissal cancelling active termination.
- Stale snapshots never being signaled.
- One process owning multiple visible rows sharing termination state.

Relevant suites:

- `PortoTests/RemoteProcessTerminatorTests.swift`
- `PortoTests/RemoteMonitorTests.swift`
- `PortoTests/PortoTests.swift`
- `PortoTests/SSHCommandRunnerTests.swift`

### 14.3 Docker termination tests

Cover:

- A valid container ID selecting container-level termination.
- Multiple published ports disappearing after container termination.
- Container SIGTERM occurring before container SIGKILL.
- Force Kill requiring confirmation.
- Invalid or changed container IDs sending no signal.
- Docker CLI unavailable or denied producing a clear failure.
- Docker failure never falling back to an arbitrary PID.
- Ambiguous Docker rows being split or remaining locked.

### 14.4 Native surface and UI tests

Verify manually on the built app:

- Native popover background remains visible.
- Native Settings background remains visible.
- Native sheet backgrounds remain visible.
- No custom opaque or fake-glass layer is added.
- Light/dark appearance remains macOS-controlled.
- Popover dimensions remain usable.
- Native scrolling works for large lists.
- Settings rows, forms, and sheets remain keyboard accessible.
- Long names and long port lists do not clip or overlap.

## 15. Implementation phases

### Phase 0: Preserve and baseline

1. Record the existing worktree with `git status --short`.
2. Preserve the existing modified SSH catalog files and untracked documents.
3. Run the current relevant tests before changing behavior.
4. Capture representative local `lsof` names with Docker Desktop/OrbStack
   running, without storing sensitive endpoints in the repository.

### Phase 1: Internal identity and presentation

1. Add explicit Docker/process source metadata.
2. Separate display name from source and termination target.
3. Remove only the `Docker ·` display prefix.
4. Preserve Docker rows, ports, counts, grouping, and diagnostics.
5. Add parser/model regression tests.

### Phase 2: Remote termination capability

1. Consolidate process-level remote revalidation.
2. Add container-level remote termination for validated container IDs.
3. Add batched remote identity enrichment where `ss` data is insufficient.
4. Split ambiguous rows when safe; otherwise retain a lock.
5. Preserve serialized SSH work and cancellation behavior.
6. Add process, container, permission, stale-target, and Force Kill tests.

### Phase 3: Popover polish

1. Refine hierarchy, typography, spacing, and row states.
2. Keep the native MenuBarExtra background untouched.
3. Keep connections collapsed.
4. Align action icons and accessibility labels.
5. Validate empty, stale, error, spinner, lock, and Force Kill states.

### Phase 4: Settings polish

1. Refine the native remote-profile list.
2. Move destructive profile actions into an ellipsis menu.
3. Keep the editor as one compact native form without redundant section headings.
4. Add icon-only capability feedback after explicit connection tests.
5. Keep native window and sheet backgrounds untouched.

### Phase 5: Documentation and acceptance

1. [x] Update the README and authoritative specification.
2. [x] Document that Docker labels are hidden but rows and ports remain
   visible.
3. [x] Document process-level and container-level remote termination.
4. [x] Document permission limits and safe fallbacks.
5. [x] Run CI, generate the project, build the app, and launch the generated
   Debug app; the current run passed 166 tests and the unsigned Debug build.
6. [ ] Complete keyboard/VoiceOver/light-mode checks and live remote Linux and
   Docker acceptance. The local popover, Settings, About, scrolling, and
   disposable termination walkthrough were completed with the native UI
   fallback noted above.

## 16. Verification commands

From the repository root:

```sh
xcodegen generate
./scripts/ci.sh
xcodebuild -project Porto.xcodeproj -scheme Porto -destination 'platform=macOS' test
xcodebuild -project Porto.xcodeproj -scheme Porto -configuration Debug -destination 'platform=macOS' build
```

Then launch the generated Debug app and verify the actual menu-bar item and
popover. The build passing is not sufficient acceptance.

## 17. Runtime acceptance checklist

### Presentation

- [ ] `This Mac` keeps Docker/OrbStack rows and ports visible.
- [ ] Remote targets keep Docker rows and ports visible.
- [ ] `Docker · pihole` displays as `pihole`.
- [ ] Listener and connection counts remain correct.
- [ ] Non-Docker rows using the same ports remain visible.

### Termination

- [ ] Eligible local process rows show `×`.
- [ ] Eligible remote process rows show `×`.
- [ ] A process owning multiple ports loses all of its rows after SIGTERM.
- [ ] Docker containers with multiple published ports can use a validated
      container-level SIGTERM path.
- [x] SIGTERM precedes Force Kill.
- [x] Force Kill requires confirmation.
- [x] A disposable local Python listener was terminated through its row action.
- [ ] Stale, ambiguous, or unauthorized rows do not send a signal.
- [ ] Errors explain whether identity, permissions, SSH, or Docker access is
      the limiting factor.

### Native appearance

- [x] Porto popover uses the native macOS background.
- [x] Settings uses the native macOS window background.
- [ ] SSH picker uses the native sheet background.
- [ ] Profile editor uses the native sheet background.
- [ ] No custom blur, gradient, opaque card, or fake-glass surface is present.
- [ ] Light/dark appearance follows macOS.

### App behavior

- [x] Porto remains menu-bar-only.
- [ ] No Dock icon or main window is introduced.
- [x] Scans pause while the popover is closed.
- [ ] No more than one scan is active at a time.
- [ ] Termination and refresh controls remain responsive.
- [x] Native scrolling remains usable with large result sets.
- [ ] Keyboard shortcuts are confirmed on the live popover.
- [ ] VoiceOver exposes the live popover labels and expanded/collapsed state.

## 18. Risks and mitigations

### Docker display name is mistaken for identity

Mitigation: keep source metadata, container ID, socket identity, and display
name separate.

### A Docker row represents multiple host-side processes

Mitigation: prefer container-level control; otherwise split rows or retain a
lock instead of signaling an arbitrary PID.

### Remote account cannot inspect or signal a process

Mitigation: use bounded capability reporting and explain the permission limit.
Do not guess, silently elevate, or use PID-only signaling.

### `ss` output lacks stable socket identity

Mitigation: preserve socket granularity, add bounded `/proc` enrichment, and
keep the row locked if identity remains ambiguous.

### Native background is accidentally replaced during visual polish

Mitigation: treat the absence of custom background/material modifiers as a
release acceptance criterion for the popover, Settings window, and sheets.

## 19. Explicitly out of scope

- Hiding Docker rows or Docker ports.
- Hiding common ports globally.
- A global remote “kill all processes” button.
- Automatic SIGKILL escalation.
- Unrestricted shell commands built from UI text.
- `sudo`, `doas`, privileged helpers, launch daemons, or elevated scans in the
  default v1 implementation.
- Docker container removal, restart, image management, or compose management.
- Persistent port/process history or telemetry.
- A custom replacement for native macOS window and sheet backgrounds.

## 20. Definition of done

The work is complete when Porto shows the same complete set of Docker and
non-Docker ports, displays Docker container names without the `Docker ·`
prefix, safely terminates every process/container that the configured account
can unambiguously control, clearly explains rows that require more permission
or identity data, preserves the SIGTERM-first lifecycle, and presents the
popover and Settings surfaces using native macOS backgrounds.
