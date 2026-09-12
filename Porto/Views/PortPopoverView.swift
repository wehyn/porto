import AppKit
import SwiftUI

struct PortPopoverView: View {
    @ObservedObject var monitor: PortMonitor
    @ObservedObject var presentationObserver: MenuPresentationObserver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .opacity(0.65)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if !monitor.hasSnapshot && monitor.isScanning {
                        scanningState
                    } else if !monitor.hasSnapshot, let error = monitor.scanError {
                        firstLoadErrorState(error)
                    } else {
                        activityRows
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 360)
        .frame(minHeight: 180, maxHeight: 560)
        .confirmationDialog(
            forceKillTitle,
            isPresented: forceKillPromptBinding,
            titleVisibility: .visible
        ) {
            Button("Force Kill", role: .destructive) {
                monitor.confirmForceKill()
            }
            Button("Cancel", role: .cancel) {
                monitor.cancelForceKillPrompt()
            }
        } message: {
            Text(forceKillMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Porto")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: monitor.refresh) {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.medium)
                    .rotationEffect(.degrees(monitor.isManualRefreshing && !reduceMotion ? 360 : 0))
                    .animation(
                        monitor.isManualRefreshing && !reduceMotion
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: monitor.isManualRefreshing
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh ports")
            .help("Refresh ports")
            .keyboardShortcut("r", modifiers: [.command])

            Menu {
                Button("About Porto") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit Porto") {
                    monitor.quitApplication()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.medium)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Porto menu")
            .help("About Porto and Quit Porto")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var activityRows: some View {
        if monitor.allRows.isEmpty {
            Text("No ports found")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .accessibilityLabel("No ports found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(monitor.allRows) { row in
                    PortProcessRow(row: row, monitor: monitor)
                }
            }
        }
    }

    private var scanningState: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scanning")
    }

    private func firstLoadErrorState(_ error: ScanFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.firstLoadMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Button("Retry", action: monitor.retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var footer: some View {
        if let error = monitor.scanError, monitor.hasSnapshot {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error.userMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(action: monitor.retry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry port scan")
                .help("Retry port scan")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            .accessibilityElement(children: .contain)
        }
    }

    private var forceKillTitle: String {
        guard let row = monitor.forceKillPrompt else { return "Force Kill" }
        return "Force kill \(row.processName)?"
    }

    private var forceKillMessage: String {
        guard let row = monitor.forceKillPrompt else { return "" }
        return "Force killing \(row.processName) (PID \(row.pid)) prevents cleanup and can lose unsaved work."
    }

    private var forceKillPromptBinding: Binding<Bool> {
        Binding(
            get: { monitor.forceKillPrompt != nil },
            set: { presented in
                if !presented { monitor.cancelForceKillPrompt() }
            }
        )
    }
}
