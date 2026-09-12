import SwiftUI

struct PortProcessRow: View {
    let row: PortProcess
    @ObservedObject var monitor: PortMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.processName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.processName)
                Text("\(row.localPort)")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .contentShape(Rectangle())
        .focusable()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .padding(.vertical, 2)
    }

    private var accessibilitySummary: String {
        let process = row.processName.isEmpty ? "Unknown process" : row.processName
        let activity = row.activityKind == .listener ? "listener" : "connection"
        let endpoints = row.endpoints.map(\.rawValue).joined(separator: ", ")
        let access = row.isRemote ? ", read-only" : ""
        return "\(monitor.selectedTarget.displayName), \(process), \(row.transport.rawValue), local port \(row.localPort), \(activity), \(endpoints)\(access)"
    }

    @ViewBuilder
    private var actions: some View {
        if row.isRemote {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remote process controls disabled")
                .help("Remote process controls are disabled.")
        } else if !row.isActionable {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Process identity unavailable; controls disabled")
                .help("Porto could not verify this process identity, so process controls are disabled.")
        } else if monitor.isOwnProcess(row) {
            Image(systemName: "nosign")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Porto cannot stop itself")
                .help("Porto cannot stop itself.")
        } else if let state = monitor.terminationState(for: row) {
            switch state {
            case .inProgress:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
                    .accessibilityLabel("Stopping \(row.processName)")
            case .forceKillAvailable:
                stopButton
                forceKillButton
            case let .failed(failure):
                failureIndicator(failure)
                stopButton
            }
        } else {
            stopButton
        }
    }

    private var stopButton: some View {
        Button {
            monitor.requestStop(for: row)
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(monitor.isTerminationDisabled(for: row))
        .accessibilityLabel("Stop \(row.processName)")
        .help("Send SIGTERM to process \(row.processName) (PID \(row.pid ?? 0)). This can close all ports owned by the process.")
    }

    private var forceKillButton: some View {
        Button {
            monitor.requestForceKill(for: row)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(monitor.isTerminationDisabled(for: row))
        .accessibilityLabel("Force kill \(row.processName)")
        .help("Force kill \(row.processName) (PID \(row.pid ?? 0)). SIGKILL prevents cleanup and can lose unsaved work.")
    }

    private func failureIndicator(_ failure: TerminationFailure) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityLabel(failure.userMessage)
            .help(failure.helpText)
    }
}
