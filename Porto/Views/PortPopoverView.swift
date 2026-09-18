import AppKit
import SwiftUI

internal func connectionsAccessibilityLabel(connectionCount: Int, isExpanded: Bool) -> String {
    "Connections, \(connectionCount), \(isExpanded ? "expanded" : "collapsed")"
}

enum RefreshIndicatorPresentation: Equatable {
    case arrow
    case progress
}

func refreshIndicatorPresentation(
    isManualRefreshing: Bool,
    reduceMotion: Bool
) -> RefreshIndicatorPresentation {
    isManualRefreshing && !reduceMotion ? .progress : .arrow
}

struct PortPopoverView: View {
    nonisolated internal static let popoverWidth: CGFloat = 300
    nonisolated internal static let targetSelectorHorizontalPadding: CGFloat = 14
    nonisolated internal static let targetSelectorActionButtonSize: CGFloat = 44
    nonisolated internal static let targetSelectorActionSpacing: CGFloat = 4
    nonisolated internal static let targetSelectorActionButtonSpacing: CGFloat = 0
    nonisolated internal static let targetSelectorWidth: CGFloat =
        popoverWidth - (targetSelectorHorizontalPadding * 2)
            - (targetSelectorActionButtonSize * 2)
            - targetSelectorActionSpacing
            - targetSelectorActionButtonSpacing

    @ObservedObject var monitor: PortMonitor
    @ObservedObject var presentationObserver: MenuPresentationObserver
    @ObservedObject var updater: PortoUpdater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            targetSelector
            Divider().opacity(0.65)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    activitySummary
                    if monitor.isInitialLoading {
                        scanningState
                    } else if !monitor.hasSnapshot, (monitor.scanError != nil || monitor.remoteFailure != nil) {
                        firstLoadErrorState
                    } else {
                        listenerRows
                        connectionSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: Self.popoverWidth, height: 560)
        .confirmationDialog(forceKillTitle, isPresented: forceKillPromptBinding, titleVisibility: .visible) {
            Button("Force Kill", role: .destructive) { monitor.confirmForceKill() }
            Button("Cancel", role: .cancel) { monitor.cancelForceKillPrompt() }
        } message: {
            Text(forceKillMessage)
        }
    }

    private func openSettings() {
        openWindow(id: "settings")
        SettingsWindowPresenter.bringToFront()
    }

    private var targetSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Self.targetSelectorActionSpacing) {
                TargetSelectorControl(
                    targets: monitor.availableTargets,
                    selection: targetBinding,
                    isDisabled: monitor.isTargetPickerDisabled
                )
                .frame(width: Self.targetSelectorWidth, alignment: .leading)

                HStack(spacing: Self.targetSelectorActionButtonSpacing) {
                    refreshButton
                    overflowMenu
                }
            }
            if monitor.profiles.isEmpty {
                Text("Add a remote server profile in Settings to inspect another machine over SSH.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Self.targetSelectorHorizontalPadding)
        .padding(.vertical, 9)
    }

    private var refreshButton: some View {
        Button(action: monitor.refresh) {
            refreshIndicator
        }
        .buttonStyle(.borderless)
        .frame(width: Self.targetSelectorActionButtonSize, height: Self.targetSelectorActionButtonSize)
        .accessibilityLabel("Refresh ports")
        .help("Refresh ports")
        .keyboardShortcut("r", modifiers: [.command])
    }

    @ViewBuilder
    private var refreshIndicator: some View {
        switch refreshIndicatorPresentation(
            isManualRefreshing: monitor.isManualRefreshing,
            reduceMotion: reduceMotion
        ) {
        case .arrow:
            Image(systemName: "arrow.clockwise")
                .imageScale(.medium)
        case .progress:
            ProgressView()
                .controlSize(.small)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Settings…") { openSettings() }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
                .help("Check for available Porto updates")
                .accessibilityLabel("Check for Updates")
                .accessibilityHint("Checks whether a newer version of Porto is available")
            Divider()
            Button("About Porto") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Divider()
            Button("Quit Porto") { monitor.quitApplication() }
        } label: {
            Image(systemName: "ellipsis.circle").imageScale(.medium)
        }
        .menuStyle(.borderlessButton)
        .frame(width: Self.targetSelectorActionButtonSize, height: Self.targetSelectorActionButtonSize)
        .accessibilityLabel("Porto menu")
        .help("About Porto and Quit Porto")
    }

    private var targetBinding: Binding<PortTarget> {
        Binding(
            get: { monitor.selectedTarget },
            set: { newTarget in monitor.selectTarget(newTarget) }
        )
    }

    private var activitySummary: some View {
            Label {
                Text("\(monitor.listenerRows.count) listening · \(monitor.connectionRows.count) connections")
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(monitor.listenerRows.count) listening, \(monitor.connectionRows.count) connections")
    }

    @ViewBuilder
    private var listenerRows: some View {
        if monitor.listenerRows.isEmpty && monitor.connectionRows.isEmpty {
            Text("No ports found")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(monitor.listenerRows) { row in processRow(row) }
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if !monitor.connectionRows.isEmpty {
            DisclosureGroup(isExpanded: $monitor.connectionsExpanded) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(monitor.connectionRows) { row in processRow(row) }
                }
                .padding(.top, 4)
            } label: {
                Label("Connections (\(monitor.connectionRows.count))", systemImage: "link")
                    .font(.callout.weight(.medium))
            }
            .accessibilityLabel(
                connectionsAccessibilityLabel(
                    connectionCount: monitor.connectionRows.count,
                    isExpanded: monitor.connectionsExpanded
                )
            )
        }
    }

    private func processRow(_ row: PortProcess) -> some View {
        PortProcessRow(
            row: row,
            targetDisplayName: monitor.selectedTarget.displayName,
            terminationState: monitor.terminationState(for: row),
            isOwnProcess: monitor.isOwnProcess(row),
            isTerminationDisabled: monitor.isTerminationDisabled(for: row),
            onStop: { monitor.requestStop(for: row) },
            onForceKill: { monitor.requestForceKill(for: row) }
        )
    }

    private var scanningState: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .accessibilityLabel("Scanning ports")
    }

    private var firstLoadErrorState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                monitor.remoteFailure?.userMessage ?? monitor.scanError?.firstLoadMessage ?? "Port scan failed.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            Button("Retry", action: monitor.retry).buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var footer: some View {
        if let error = monitor.scanError, monitor.hasSnapshot {
            errorFooter(error.userMessage)
        } else if let error = monitor.remoteFailure, monitor.hasSnapshot {
            errorFooter(error.userMessage)
        }
    }

    private func errorFooter(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 4)
            Button(action: monitor.retry) { refreshIndicator }
                .buttonStyle(.borderless)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Retry port scan")
                .help("Retry port scan")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
    }

    private var forceKillTitle: String {
        guard let row = monitor.forceKillPrompt else { return "Force Kill" }
        return "Force kill \(row.processName)?"
    }

    private var forceKillMessage: String {
        guard let row = monitor.forceKillPrompt else { return "" }
        if row.isDockerContainer {
            return "Force killing container \(row.processName) prevents cleanup and can lose unsaved work."
        }
        return "Force killing \(row.processName) (PID \(row.pid ?? 0)) prevents cleanup and can lose unsaved work."
    }

    private var forceKillPromptBinding: Binding<Bool> {
        Binding(get: { monitor.forceKillPrompt != nil }, set: { if !$0 { monitor.cancelForceKillPrompt() } })
    }
}

private struct TargetSelectorControl: NSViewRepresentable {
    let targets: [PortTarget]
    @Binding var selection: PortTarget
    let isDisabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionDidChange(_:))
        button.setAccessibilityLabel("Port monitoring target")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self

        let targetSignature = targets.map {
            TargetSignature(id: $0.id.rawValue, displayName: $0.displayName)
        }
        if context.coordinator.targetSignature != targetSignature {
            button.removeAllItems()
            for target in targets {
                button.addItem(withTitle: target.displayName)
                button.lastItem?.representedObject = target.id.rawValue
            }
            context.coordinator.targetSignature = targetSignature
            context.coordinator.selectionID = nil
        }
        let selectionID = selection.id.rawValue
        if context.coordinator.selectionID != selectionID {
            if let index = button.itemArray.firstIndex(where: { $0.representedObject as? String == selectionID }) {
                button.selectItem(at: index)
            }
            context.coordinator.selectionID = selectionID
        }
        let enabled = !isDisabled
        if context.coordinator.isEnabled != enabled {
            button.isEnabled = enabled
            context.coordinator.isEnabled = enabled
        }
    }

    final class Coordinator: NSObject {
        var parent: TargetSelectorControl
        var targetSignature: [TargetSignature]?
        var selectionID: String?
        var isEnabled: Bool?

        init(parent: TargetSelectorControl) {
            self.parent = parent
        }

        @MainActor @objc func selectionDidChange(_ sender: NSPopUpButton) {
            guard let targetID = sender.selectedItem?.representedObject as? String,
                  let target = parent.targets.first(where: { $0.id.rawValue == targetID }) else {
                return
            }
            parent.selection = target
        }
    }

    struct TargetSignature: Equatable {
        let id: String
        let displayName: String
    }
}
