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
    let containerID: String?
    let localPort: Int
    let transport: TransportProtocol
    let hostAddress: String?
    let containerName: String

    init(
        containerID: String?,
        localPort: Int,
        transport: TransportProtocol,
        hostAddress: String?,
        containerName: String
    ) {
        self.containerID = containerID
        self.localPort = localPort
        self.transport = transport
        self.hostAddress = hostAddress
        self.containerName = containerName
    }

    init(
        localPort: Int,
        transport: TransportProtocol,
        hostAddress: String?,
        containerName: String
    ) {
        self.init(
            containerID: nil,
            localPort: localPort,
            transport: transport,
            hostAddress: hostAddress,
            containerName: containerName
        )
    }
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

    /// Labels rows backed by a published Docker host port before visibility
    /// filtering hides ownerless non-Docker rows. IPv4/IPv6, protocol, and
    /// host-port records for the same container become one logical row.
    func applying(to snapshot: PortSnapshot) -> PortSnapshot {
        var dockerGroups: [DockerRowKey: DockerRowAccumulator] = [:]
        var retainedListeners: [PortProcess] = []

        for row in snapshot.listeners {
            guard let annotation = dockerAnnotation(for: row) else {
                retainedListeners.append(row)
                continue
            }

            let labeledRow = labeled(row, with: annotation)
            guard annotation.containerIDs.count == 1,
                  let targetID = Self.remoteTargetID(from: row.origin) else {
                // Preserve the existing label behavior when metadata does not
                // identify exactly one container, but do not merge by name.
                retainedListeners.append(labeledRow)
                continue
            }

            let key = DockerRowKey(
                targetID: targetID,
                activityKind: row.activityKind,
                containerID: annotation.containerIDs[0]
            )
            var accumulator = dockerGroups[key, default: DockerRowAccumulator()]
            accumulator.containerNames.formUnion(annotation.containerNames)
            accumulator.localPorts.formUnion(row.localPorts)
            accumulator.transports.formUnion(row.transports)
            accumulator.endpoints.formUnion(row.endpoints)
            if let pid = row.pid {
                accumulator.pids.insert(pid)
            } else {
                accumulator.hasMissingPID = true
            }
            dockerGroups[key] = accumulator
        }

        let coalescedListeners = dockerGroups.map { key, accumulator in
            makeDockerRow(key: key, accumulator: accumulator)
        }
        return PortSnapshot(
            listeners: PortProcessSort.sort(retainedListeners + coalescedListeners),
            connections: PortProcessSort.sort(snapshot.connections)
        )
    }

    private func labeled(_ row: PortProcess, with annotation: DockerRowAnnotation) -> PortProcess {
        return PortProcess(
            id: row.id,
            origin: row.origin,
            localPorts: row.localPorts,
            transports: row.transports,
            processName: "Docker · " + annotation.containerNames.joined(separator: ", "),
            endpoints: row.endpoints,
            activityKind: row.activityKind
        )
    }

    private func dockerAnnotation(for row: PortProcess) -> DockerRowAnnotation? {
        guard row.activityKind == .listener,
              Self.remoteTargetID(from: row.origin) != nil else { return nil }
        let localAddresses = Set(row.endpoints.compactMap(Self.localAddress(from:)))
        let matchingBindings = bindings.filter {
            row.transports.contains($0.transport)
                && $0.localPort == row.localPort
                && Self.bindingMatches($0, localAddresses: localAddresses)
        }
        let names = Set(matchingBindings.map(\.containerName)).sorted()
        guard !names.isEmpty else { return nil }
        return DockerRowAnnotation(
            containerIDs: Set(matchingBindings.compactMap(\.containerID)).sorted(),
            containerNames: names
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

    private static func remoteTargetID(from origin: PortProcessOrigin) -> PortTargetID? {
        guard case let .remote(targetID, _) = origin else { return nil }
        return targetID
    }

    private func makeDockerRow(
        key: DockerRowKey,
        accumulator: DockerRowAccumulator
    ) -> PortProcess {
        let pid: Int32? = accumulator.hasMissingPID || accumulator.pids.count != 1
            ? nil
            : accumulator.pids.first
        return PortProcess(
            id: Self.dockerRowID(
                targetID: key.targetID,
                activityKind: key.activityKind,
                containerID: key.containerID
            ),
            origin: .remote(targetID: key.targetID, pid: pid),
            localPorts: accumulator.localPorts.sorted(),
            transports: accumulator.transports.sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.rawValue < rhs.rawValue
            },
            processName: "Docker · " + accumulator.containerNames.sorted().joined(separator: ", "),
            endpoints: accumulator.endpoints.sorted(by: dockerEndpointSort),
            activityKind: key.activityKind
        )
    }

    private static func dockerRowID(
        targetID: PortTargetID,
        activityKind: PortActivityKind,
        containerID: String
    ) -> String {
        return [
            "remote",
            "target=\(stableHex(targetID.rawValue))",
            "docker",
            activityKind.rawValue,
            "container=\(stableHex(containerID))"
        ].joined(separator: "|")
    }

    private static func stableHex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
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

private struct DockerRowAnnotation {
    let containerIDs: [String]
    let containerNames: [String]
}

private struct DockerRowKey: Hashable {
    let targetID: PortTargetID
    let activityKind: PortActivityKind
    let containerID: String
}

private struct DockerRowAccumulator {
    var containerNames: Set<String> = []
    var localPorts: Set<Int> = []
    var transports: Set<TransportProtocol> = []
    var endpoints: Set<Endpoint> = []
    var pids: Set<Int32> = []
    var hasMissingPID = false
}

private func dockerEndpointSort(_ lhs: Endpoint, _ rhs: Endpoint) -> Bool {
    if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
    return lhs.rawValue < rhs.rawValue
}

/// Parses `docker ps --format "{{.ID}}\t{{.Names}}\t{{.Ports}}"` output.
struct DockerPortParser: Sendable {
    private static let maximumContainerIDLength = 128
    private static let maximumContainerNameLength = 128
    private static let maximumPortRangeLength = 4_096

    func parse(_ output: String) -> DockerPortCatalog {
        var bindings: Set<DockerPortBinding> = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let name = sanitizeName(String(fields[1])) else { continue }
            let containerID = sanitizeContainerID(String(fields[0]))
            parsePortMappings(
                String(fields[2]),
                containerID: containerID,
                containerName: name,
                into: &bindings
            )
        }
        return DockerPortCatalog(bindings: bindings)
    }

    private func parsePortMappings(
        _ output: String,
        containerID: String?,
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
                    containerID: containerID,
                    localPort: port,
                    transport: transport,
                    hostAddress: hostAddress,
                    containerName: containerName
                ))
            }
        }
    }

    private func sanitizeContainerID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= Self.maximumContainerIDLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
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
