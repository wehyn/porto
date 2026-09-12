import Foundation

struct ParsedRemotePortOutput: Equatable, Sendable {
    let snapshot: PortSnapshot
    let validRecords: Int
    let skippedRecords: Int
    let dockerPorts: DockerPortCatalog
}

enum RemotePortOutputParserResult: Equatable, Sendable {
    case success(ParsedRemotePortOutput)
    case failure(SsParserError)
}

/// Splits the fixed remote output into the Linux socket stream and optional
/// Docker publication metadata, then delegates socket parsing to `SsParser`.
struct RemotePortOutputParser: Sendable {
    static let dockerMarker = "__PORTO_DOCKER__"

    private let ssParser: SsParser
    private let dockerParser: DockerPortParser

    init(ssParser: SsParser = SsParser(), dockerParser: DockerPortParser = DockerPortParser()) {
        self.ssParser = ssParser
        self.dockerParser = dockerParser
    }

    func parse(_ data: Data, targetID: PortTargetID) -> RemotePortOutputParserResult {
        let output = String(decoding: data, as: UTF8.self)
        let sections = split(output)
        switch ssParser.parse(Data(sections.ss.utf8), targetID: targetID) {
        case let .success(parsed):
            return .success(ParsedRemotePortOutput(
                snapshot: parsed.snapshot,
                validRecords: parsed.validRecords,
                skippedRecords: parsed.skippedRecords,
                dockerPorts: dockerParser.parse(sections.docker)
            ))
        case let .failure(error):
            return .failure(error)
        }
    }

    private func split(_ output: String) -> (ss: String, docker: String) {
        let markerLine = "\(Self.dockerMarker)\n"
        if output.hasPrefix(markerLine) {
            let dockerStart = output.index(output.startIndex, offsetBy: markerLine.count)
            return ("", String(output[dockerStart...]))
        }

        guard let marker = output.range(of: "\n\(markerLine)") else {
            return (output, "")
        }

        let ssOutput = String(output[..<marker.lowerBound])
        let dockerStart = marker.upperBound
        let dockerOutput = String(output[dockerStart...])
        return (ssOutput, dockerOutput)
    }
}

struct DockerPortBinding: Hashable, Sendable {
    let localPort: Int
    let transport: TransportProtocol
    let hostAddress: String?
    let containerName: String
}

struct DockerPortCatalog: Equatable, Sendable {
    let bindings: Set<DockerPortBinding>

    static let empty = DockerPortCatalog(bindings: [])

    func contains(localPort: Int, transport: TransportProtocol) -> Bool {
        bindings.contains { $0.localPort == localPort && $0.transport == transport }
    }

    func containerNames(localPort: Int, transport: TransportProtocol) -> [String] {
        Set(
            bindings
                .filter { $0.localPort == localPort && $0.transport == transport }
                .map(\.containerName)
        ).sorted()
    }

    private func containerNames(for row: PortProcess) -> [String] {
        guard row.activityKind == .listener else { return [] }
        let localAddresses = Set(row.endpoints.compactMap(Self.localAddress(from:)))
        return Set(
            bindings
                .filter {
                    $0.localPort == row.localPort
                        && $0.transport == row.transport
                        && Self.bindingMatches($0, localAddresses: localAddresses)
                }
                .map(\.containerName)
        ).sorted()
    }

    /// Labels rows backed by a published Docker host port before visibility
    /// filtering hides ownerless non-Docker rows.
    func applying(to snapshot: PortSnapshot) -> PortSnapshot {
        PortSnapshot(
            listeners: PortProcessSort.sort(snapshot.listeners.map { applying(to: $0) }),
            connections: PortProcessSort.sort(snapshot.connections.map { applying(to: $0) })
        )
    }

    private func applying(to row: PortProcess) -> PortProcess {
        let names = containerNames(for: row)
        guard !names.isEmpty else { return row }
        return PortProcess(
            id: row.id,
            origin: row.origin,
            localPort: row.localPort,
            transport: row.transport,
            processName: "Docker · " + names.joined(separator: ", "),
            endpoints: row.endpoints,
            activityKind: row.activityKind
        )
    }

    private static func bindingMatches(
        _ binding: DockerPortBinding,
        localAddresses: Set<String>
    ) -> Bool {
        guard let hostAddress = binding.hostAddress else { return true }
        return localAddresses.contains(hostAddress)
    }

    private static func localAddress(from endpoint: Endpoint) -> String? {
        let localComponent: String
        if let arrow = endpoint.rawValue.range(of: "->") {
            localComponent = String(endpoint.rawValue[..<arrow.lowerBound])
        } else {
            localComponent = endpoint.rawValue
        }
        guard let separator = localComponent.lastIndex(of: ":") else { return nil }
        let host = String(localComponent[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        return canonicalAddress(host)
    }

    private static func canonicalAddress(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.first == "[", value.last == "]" {
            value.removeFirst()
            value.removeLast()
        }
        switch value {
        case "*", "0.0.0.0": return "ipv4-wildcard"
        case "::": return "ipv6-wildcard"
        default: return value
        }
    }
}

/// Parses `docker ps --format "{{.ID}}\t{{.Names}}\t{{.Ports}}"` output.
struct DockerPortParser: Sendable {
    private static let maximumContainerNameLength = 128
    private static let maximumPortRangeLength = 4_096

    func parse(_ output: String) -> DockerPortCatalog {
        var bindings: Set<DockerPortBinding> = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let name = sanitizeName(String(fields[1])) else { continue }
            parsePortMappings(String(fields[2]), containerName: name, into: &bindings)
        }
        return DockerPortCatalog(bindings: bindings)
    }

    private func parsePortMappings(
        _ output: String,
        containerName: String,
        into bindings: inout Set<DockerPortBinding>
    ) {
        for rawMapping in output.split(separator: ",") {
            let mapping = rawMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let arrow = mapping.range(of: "->") else { continue }
            let hostEndpoint = String(mapping[..<arrow.lowerBound])
            let containerEndpoint = String(mapping[arrow.upperBound...])
            guard let separator = containerEndpoint.lastIndex(of: "/") else { continue }
            let protocolName = String(containerEndpoint[containerEndpoint.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let transport: TransportProtocol
            switch protocolName {
            case "tcp": transport = .tcp
            case "udp": transport = .udp
            default: continue
            }

            let hostAddress: String?
            let hostPortText: Substring
            if let portSeparator = hostEndpoint.lastIndex(of: ":") {
                let rawHostAddress = String(hostEndpoint[..<portSeparator])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hostAddress = rawHostAddress.isEmpty ? nil : Self.canonicalAddress(rawHostAddress)
                hostPortText = hostEndpoint[hostEndpoint.index(after: portSeparator)...]
            } else {
                hostAddress = nil
                hostPortText = Substring(hostEndpoint)
            }
            guard let portRange = parsePortRange(String(hostPortText)) else { continue }
            for port in portRange {
                bindings.insert(DockerPortBinding(
                    localPort: port,
                    transport: transport,
                    hostAddress: hostAddress,
                    containerName: containerName
                ))
            }
        }
    }

    private func parsePortRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let lower = Int(parts[0]),
              (1...65_535).contains(lower) else { return nil }
        let upper = parts.count == 2 ? Int(parts[1]) : lower
        guard let upper, (lower...65_535).contains(upper),
              upper - lower <= Self.maximumPortRangeLength else { return nil }
        return lower...upper
    }

    private func sanitizeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return String(trimmed.prefix(Self.maximumContainerNameLength))
    }

    private static func canonicalAddress(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.first == "[", value.last == "]" {
            value.removeFirst()
            value.removeLast()
        }
        switch value {
        case "*", "0.0.0.0": return "ipv4-wildcard"
        case "::": return "ipv6-wildcard"
        default: return value
        }
    }
}
