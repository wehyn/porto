import SwiftUI

struct PortProcessRow: View {
    let row: PortProcess
    @ObservedObject var monitor: PortMonitor
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16, height: 22)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Hide details for \(row.processName)" : "Show details for \(row.processName)")
                .help(isExpanded ? "Hide details" : "Show details")

                Text("\(row.localPort)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 48, alignment: .trailing)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(row.processName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(row.processName)
                    .help(row.processName)
                Spacer(minLength: 4)
                actions
            }
            .contentShape(Rectangle())
            .focusable()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Port \(row.localPort), \(row.processName)")
            .accessibilityValue(row.accessibilityValue)

            if isExpanded {
                PortProcessDetails(row: row, monitor: monitor)
                    .padding(.leading, 22)
                    .padding(.bottom, 5)
            }
        }
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

private struct PortProcessDetails: View {
    let row: PortProcess
    @ObservedObject var monitor: PortMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(row.transport.rawValue) · PID \(row.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(visibleEndpoints.enumerated()), id: \.offset) { _, endpoint in
                Text(endpointDisplay(endpoint))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(endpoint.rawValue)
            }
            if remainingEndpointCount > 0, !showAllEndpoints {
                Text("and \(remainingEndpointCount) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show all endpoints") {
                    showAllEndpoints = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detailsAccessibilityLabel)
    }

    @State private var showAllEndpoints = false

    private var visibleEndpoints: ArraySlice<Endpoint> {
        row.endpoints.prefix(showAllEndpoints ? row.endpoints.count : 5)
    }

    private var remainingEndpointCount: Int {
        max(0, row.endpoints.count - 5)
    }

    private func endpointDisplay(_ endpoint: Endpoint) -> String {
        if let state = endpoint.socketState {
            return "\(endpoint.rawValue) · \(state)"
        }
        return endpoint.rawValue
    }

    private var detailsAccessibilityLabel: String {
        let stateText = row.endpoints.compactMap(\.socketState).uniqued().joined(separator: ", ")
        let endpointText = row.endpoints.map(\.rawValue).joined(separator: ", ")
        let stateSuffix = stateText.isEmpty ? "" : ", states \(stateText)"
        return "Protocol \(row.transport.rawValue), PID \(row.pid)\(stateSuffix), endpoints \(endpointText)"
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

private extension PortProcess {
    var accessibilityValue: String {
        let protocolText = transport.rawValue
        let endpointCount = endpoints.count == 1 ? "1 endpoint" : "\(endpoints.count) endpoints"
        return "\(protocolText), \(endpointCount)"
    }
}
