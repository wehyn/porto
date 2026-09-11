import Foundation

struct PreliminaryGroupKey: Hashable, Sendable {
    let activityKind: PortActivityKind
    let transport: TransportProtocol
    let localPort: Int
    let pid: Int32
}

struct ParsedPortGroup: Sendable, Equatable {
    let key: PreliminaryGroupKey
    let processName: String
    let endpoints: [Endpoint]
}

struct ParsedLsofOutput: Sendable, Equatable {
    let groups: [ParsedPortGroup]
    let validRecords: Int
    let skippedRecords: Int
    let sawNonStructuralInput: Bool
}

struct LsofParser: Sendable {
    func parse(_ data: Data) -> ParsedLsofOutput {
        var groups: [PreliminaryGroupKey: ParsedGroupAccumulator] = [:]
        var currentProcess: ProcessFields?
        var currentFile: FileFields?
        var validRecords = 0
        var skippedRecords = 0
        var sawNonStructuralInput = false

        func flushFile() {
            guard let currentFile else { return }
            guard let process = currentProcess,
                  let pid = process.pid,
                  let protocolValue = currentFile.transport,
                  let endpoint = currentFile.endpoint,
                  let parsedEndpoint = EndpointParser.parse(endpoint, state: currentFile.socketState),
                  let activityKind = ActivityClassifier.classify(
                      transport: protocolValue,
                      endpoint: parsedEndpoint,
                      state: currentFile.socketState
                  ) else {
                skippedRecords += 1
                return
            }

            let key = PreliminaryGroupKey(
                activityKind: activityKind,
                transport: protocolValue,
                localPort: parsedEndpoint.localPort,
                pid: pid
            )
            var accumulator = groups[key] ?? ParsedGroupAccumulator(processName: process.command ?? "Unknown process")
            if accumulator.processName == "Unknown process", let command = process.command, !command.isEmpty {
                accumulator.processName = command
            }
            accumulator.endpoints.insert(parsedEndpoint)
            groups[key] = accumulator
            validRecords += 1
        }

        for rawToken in data.split(separator: 0, omittingEmptySubsequences: false) {
            let token = trimStructuralSeparators(Array(rawToken))
            guard !token.isEmpty else { continue }
            sawNonStructuralInput = true
            guard let field = token.first else { continue }
            let value = String(decoding: token.dropFirst(), as: UTF8.self)

            switch field {
            case UInt8(ascii: "p"):
                flushFile()
                currentFile = nil
                currentProcess = ProcessFields(pid: parsePID(value), command: nil)
            case UInt8(ascii: "c"):
                currentProcess?.command = value
            case UInt8(ascii: "f"):
                flushFile()
                currentFile = FileFields()
            case UInt8(ascii: "P"):
                currentFile?.transport = TransportProtocol(rawValue: value.uppercased())
            case UInt8(ascii: "n"):
                currentFile?.endpoint = value
            case UInt8(ascii: "T"):
                guard value.uppercased().hasPrefix("ST=") else { continue }
                let state = String(value.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                currentFile?.socketState = state.isEmpty ? nil : state
            default:
                continue
            }
        }
        flushFile()

        let parsedGroups = groups.map { key, accumulator in
            ParsedPortGroup(
                key: key,
                processName: accumulator.processName,
                endpoints: accumulator.endpoints.sorted { lhs, rhs in
                    if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
                    return lhs.rawValue < rhs.rawValue
                }
            )
        }.sorted { lhs, rhs in
            if lhs.key.activityKind != rhs.key.activityKind {
                return lhs.key.activityKind.rawValue < rhs.key.activityKind.rawValue
            }
            if lhs.key.localPort != rhs.key.localPort { return lhs.key.localPort < rhs.key.localPort }
            if lhs.key.pid != rhs.key.pid { return lhs.key.pid < rhs.key.pid }
            return lhs.key.transport.rawValue < rhs.key.transport.rawValue
        }

        return ParsedLsofOutput(
            groups: parsedGroups,
            validRecords: validRecords,
            skippedRecords: skippedRecords,
            sawNonStructuralInput: sawNonStructuralInput
        )
    }
}

private struct ProcessFields {
    var pid: Int32?
    var command: String?
}

private struct FileFields {
    var transport: TransportProtocol?
    var endpoint: String?
    var socketState: String?
}

private struct ParsedGroupAccumulator {
    var processName: String
    var endpoints: Set<Endpoint> = []
}

private func trimStructuralSeparators(_ bytes: [UInt8]) -> [UInt8] {
    var start = 0
    var end = bytes.count
    while start < end, bytes[start] == 0x0A || bytes[start] == 0x0D {
        start += 1
    }
    while end > start, bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D {
        end -= 1
    }
    return Array(bytes[start..<end])
}

private func parsePID(_ value: String) -> Int32? {
    guard let pid = Int32(value), pid > 0 else { return nil }
    return pid
}

enum EndpointParser {
    static func parse(_ rawValue: String, state: String?) -> Endpoint? {
        let rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        let localComponent: String
        let remoteComponent: String?
        if let arrow = rawValue.range(of: "->") {
            localComponent = String(rawValue[..<arrow.lowerBound])
            let remote = String(rawValue[arrow.upperBound...])
            guard !remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            remoteComponent = remote
        } else {
            localComponent = rawValue
            remoteComponent = nil
        }
        guard let localPort = parsePort(in: localComponent) else { return nil }
        let hasRemoteEndpoint = remoteComponent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return Endpoint(
            rawValue: rawValue,
            localPort: localPort,
            hasRemoteEndpoint: hasRemoteEndpoint,
            socketState: state?.uppercased()
        )
    }

    private static func parsePort(in component: String) -> Int? {
        let component = component.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText: Substring?
        if component.first == "[" {
            guard let closingBracket = component.firstIndex(of: "]"),
                  component.index(after: closingBracket) < component.endIndex,
                  component[component.index(after: closingBracket)] == ":" else {
                return nil
            }
            portText = component[component.index(after: closingBracket)...].dropFirst()
        } else {
            guard let separator = component.lastIndex(of: ":") else { return nil }
            portText = component[component.index(after: separator)...]
        }
        guard let portText, !portText.isEmpty,
              portText.allSatisfy(\.isNumber),
              let port = Int(portText), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }
}

enum ActivityClassifier {
    static func classify(
        transport: TransportProtocol,
        endpoint: Endpoint,
        state: String?
    ) -> PortActivityKind? {
        switch transport {
        case .tcp:
            if state?.uppercased() == "LISTEN" { return .listener }
            return endpoint.hasRemoteEndpoint ? .connection : nil
        case .udp:
            return endpoint.hasRemoteEndpoint ? .connection : .listener
        }
    }
}
