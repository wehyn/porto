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
        .accessibilityLabel("Process \(row.processName), port \(row.localPort)")
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actions: some View {
        if monitor.isOwnProcess(row) {
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
        .help("Send SIGTERM to process \(row.processName) (PID \(row.pid)). This can close all ports owned by the process.")
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
        .help("Force kill \(row.processName) (PID \(row.pid)). SIGKILL prevents cleanup and can lose unsaved work.")
    }

    private func failureIndicator(_ failure: TerminationFailure) -> some View {
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityLabel(failure.userMessage)
            .help(failure.helpText)
    }
}
