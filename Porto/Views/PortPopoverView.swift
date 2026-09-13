import AppKit
import SwiftUI

struct PortPopoverView: View {
    @ObservedObject var monitor: PortMonitor
    @ObservedObject var presentationObserver: MenuPresentationObserver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)
            targetSelector
            Divider().opacity(0.65)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    activitySummary
                    if monitor.isScanning && !monitor.hasSnapshot {
                        scanningState
                    } else if !monitor.hasSnapshot, (monitor.scanError != nil || monitor.remoteFailure != nil) {
                        firstLoadErrorState
                    } else {
                        listenerRows
                        connectionSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 360, height: 560)
        .confirmationDialog(forceKillTitle, isPresented: forceKillPromptBinding, titleVisibility: .visible) {
            Button("Force Kill", role: .destructive) { monitor.confirmForceKill() }
            Button("Cancel", role: .cancel) { monitor.cancelForceKillPrompt() }
        } message: {
            Text(forceKillMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Porto").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: monitor.refresh) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.medium)
                    .rotationEffect(.degrees(monitor.isManualRefreshing && !reduceMotion ? 360 : 0))
                    .animation(
                        monitor.isManualRefreshing && !reduceMotion
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: monitor.isManualRefreshing
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh ports")
            .help("Refresh ports")
            .keyboardShortcut("r", modifiers: [.command])

            Menu {
                Button("Settings…") { openSettings() }
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
            .accessibilityLabel("Porto menu")
            .help("About Porto and Quit Porto")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func openSettings() {
        openWindow(id: "settings")
        Task { @MainActor in
            await Task.yield()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
        }
    }

    private var targetSelector: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("WATCHING").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Target", selection: targetBinding) {
                ForEach(monitor.availableTargets, id: \.self) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(monitor.isTargetPickerDisabled)
            .accessibilityLabel("Port monitoring target")
            Text(monitor.targetStatusText)
                .font(.caption)
                .foregroundStyle(monitor.remoteFailure == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if monitor.profiles.isEmpty {
                Text("Add a remote server profile in Settings to inspect another machine over SSH.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var targetBinding: Binding<PortTarget> {
        Binding(
            get: { monitor.selectedTarget },
            set: { newTarget in monitor.selectTarget(newTarget) }
        )
    }

    private var activitySummary: some View {
        Text("\(monitor.listenerRows.count) listening   \(monitor.connectionRows.count) connections")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(monitor.listenerRows.count) listening, \(monitor.connectionRows.count) connections")
    }

    @ViewBuilder
    private var listenerRows: some View {
        if monitor.listenerRows.isEmpty && monitor.connectionRows.isEmpty {
            Text("No ports found").font(.callout).foregroundStyle(.secondary).padding(.vertical, 4)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(monitor.listenerRows) { row in PortProcessRow(row: row, monitor: monitor) }
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if !monitor.connectionRows.isEmpty {
            DisclosureGroup(isExpanded: $monitor.connectionsExpanded) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(monitor.connectionRows) { row in PortProcessRow(row: row, monitor: monitor) }
                }
                .padding(.top, 4)
            } label: {
                Text("Connections (\(monitor.connectionRows.count))").font(.callout.weight(.medium))
            }
            .accessibilityLabel("Connections, \(monitor.connectionRows.count), collapsed by default")
        }
    }

    private var scanningState: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(monitor.isRemoteTarget ? "Connecting over SSH…" : "Scanning…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
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
            errorFooter(error.userMessage + " Showing last results.")
        }
    }

    private func errorFooter(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 4)
            Button(action: monitor.retry) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).accessibilityLabel("Retry port scan").help("Retry port scan")
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
        return "Force killing \(row.processName) (PID \(row.pid ?? 0)) prevents cleanup and can lose unsaved work."
    }

    private var forceKillPromptBinding: Binding<Bool> {
        Binding(get: { monitor.forceKillPrompt != nil }, set: { if !$0 { monitor.cancelForceKillPrompt() } })
    }
}
