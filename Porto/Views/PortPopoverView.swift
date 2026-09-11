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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if !monitor.hasSnapshot && monitor.isScanning {
                        scanningState
                    } else if !monitor.hasSnapshot, let error = monitor.scanError {
                        firstLoadErrorState(error)
                    } else {
                        listenerSection
                        connectionSection
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 360)
        .frame(minHeight: 180, maxHeight: 560)
        .background(.regularMaterial)
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
        HStack(spacing: 8) {
            Text("Porto")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: monitor.refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(monitor.isScanning && !reduceMotion ? 360 : 0))
                    .animation(
                        monitor.isScanning && !reduceMotion
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: monitor.isScanning
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
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Porto menu")
            .help("About Porto and Quit Porto")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var listenerSection: some View {
        DisclosureGroup(isExpanded: $monitor.listenersExpanded) {
            sectionRows(
                rows: monitor.listenerRows,
                emptyText: "No listeners found"
            )
        } label: {
            SectionTitle(title: "Listeners")
        }
        .accessibilityValue("\(monitor.listenerRows.count) grouped rows")
    }

    private var connectionSection: some View {
        DisclosureGroup(isExpanded: $monitor.connectionsExpanded) {
            sectionRows(
                rows: monitor.connectionRows,
                emptyText: "No active connections found"
            )
        } label: {
            SectionTitle(title: "Connections", count: monitor.connectionRows.count)
        }
        .accessibilityValue("\(monitor.connectionRows.count) grouped rows")
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
    private func sectionRows(rows: [PortProcess], emptyText: String) -> some View {
        if !monitor.hasSnapshot && monitor.isScanning {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning")
        } else if rows.isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    PortProcessRow(row: row, monitor: monitor)
                }
            }
        }
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
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
            .accessibilityElement(children: .contain)
        } else if let lastScan = monitor.lastSuccessfulScanAt {
            Text("Updated \(lastScan, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .accessibilityLabel("Last successful scan \(lastScan.formatted(date: .abbreviated, time: .shortened))")
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

private struct SectionTitle: View {
    let title: String
    let count: Int?

    init(title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let count {
                Text("(\(count))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            count.map { "\(title), \($0) grouped rows" } ?? title
        )
    }
}
