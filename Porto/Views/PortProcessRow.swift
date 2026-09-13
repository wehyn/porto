import SwiftUI

struct PortProcessRow: View {
    let row: PortProcess
    @ObservedObject var monitor: PortMonitor

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.processName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.processName)
                Text(portSummary)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .help(portHelp)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .contentShape(Rectangle())
        .focusable()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
            .padding(.vertical, 5)
            .frame(minHeight: 44)
    }

    private var accessibilitySummary: String {
        let process = row.processName.isEmpty ? "Unknown process" : row.processName
        let activity = row.activityKind == .listener ? "listener" : "connection"
        let endpoints = row.endpoints.map(\.rawValue).joined(separator: ", ")
        let access: String
        if row.isRemote {
            access = row.isActionable ? ", remote controls available" : ", remote controls disabled"
        } else {
            access = ""
        }
        let portLabel = row.localPorts.count == 1 ? "local port" : "local ports"
        return "\(monitor.selectedTarget.displayName), \(process), \(transportSummary), \(portLabel) \(accessiblePortSummary), \(activity), \(endpoints)\(access)"
    }

    private var portSummary: String {
        row.localPorts.map(String.init).joined(separator: ", ")
    }

    private var accessiblePortSummary: String {
        row.localPorts.map(String.init).joined(separator: " and ")
    }

    private var portHelp: String {
        "\(transportSummary), ports \(portSummary)"
    }

    private var transportSummary: String {
        row.transports.map(\.rawValue).joined(separator: " and ")
    }

    private var controlTargetDescription: String {
        if row.isDockerContainer {
            return "container \(row.processName)"
        }
        return "process \(row.processName) (PID \(row.pid ?? 0))"
    }

    @ViewBuilder
    private var actions: some View {
        if !row.isActionable && row.isRemote {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remote process controls disabled")
                .help(row.isDockerContainer
                    ? "Porto could not verify this remote container identity or Docker access, so container controls are disabled."
                    : "Porto could not verify this remote process identity, so process controls are disabled.")
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
                    .frame(width: 44, height: 44)
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
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(!row.isActionable || monitor.isTerminationDisabled(for: row))
        .accessibilityLabel("Stop \(row.processName)")
        .help("Send SIGTERM to \(controlTargetDescription). This can close all ports owned by the \(row.isDockerContainer ? "container" : "process").")
    }

    private var forceKillButton: some View {
        Button {
            monitor.requestForceKill(for: row)
        } label: {
            Image(systemName: "bolt.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.red)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(!row.isActionable || monitor.isTerminationDisabled(for: row))
        .accessibilityLabel("Force kill \(row.processName)")
        .help("Force kill \(controlTargetDescription). SIGKILL prevents cleanup and can lose unsaved work.")
    }

    private func failureIndicator(_ failure: TerminationFailure) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityLabel(failure.userMessage)
            .help(failure.helpText)
    }
}
