import Foundation

/// A safe, direct SSH connection description discovered from local config.
/// The alias is display-only; callers should pass the fields explicitly.
struct SSHHostCandidate: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let alias: String
    let host: String
    let username: String
    let port: Int
    let identityFilePath: String?

    var displayID: String { alias }
    var label: String { alias }
    var addressLabel: String {
        guard port != 22 else { return host }
        if host.contains(":"), !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    init(alias: String, host: String, username: String, port: Int = 22, identityFilePath: String? = nil) {
        self.id = "ssh:" + Self.caseFold(alias)
        self.alias = alias
        self.host = host
        self.username = username
        self.port = port
        self.identityFilePath = identityFilePath
    }

    private static func caseFold(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            if (65...90).contains(scalar.value), let folded = UnicodeScalar(scalar.value + 32) {
                return Character(folded)
            }
            return Character(scalar)
        })
    }
}

enum PortActivityKind: String, Sendable, CaseIterable, Codable {
    case listener
    case connection
}

enum TransportProtocol: String, Sendable, CaseIterable, Codable {
    case tcp = "TCP"
    case udp = "UDP"

    var sortOrder: Int {
        switch self {
        case .tcp: return 0
        case .udp: return 1
        }
    }
}

struct ProcessIdentity: Hashable, Sendable, Codable {
    let pid: Int32
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64
}

struct Endpoint: Hashable, Sendable, Codable {
    let rawValue: String
    let localPort: Int
    let hasRemoteEndpoint: Bool
    let socketState: String?

    var sortKey: String {
        "\(rawValue)\u{1F}\(socketState ?? "")"
    }
}

enum PortProcessOrigin: Hashable, Sendable, Codable {
    case local(ProcessIdentity)
    case localUnverified(pid: Int32)
    case remote(targetID: PortTargetID, pid: Int32?)
}

enum PortProcessSource: Hashable, Sendable, Codable {
    case localApplication
    case dockerHostProcess
    case remoteProcess
    case dockerContainer(containerID: String?)
    case unknown
}

enum PortControlTarget: Hashable, Sendable, Codable {
    case none
    case local(ProcessIdentity)
    case remoteProcess(targetID: PortTargetID, pid: Int32?)
    case remoteDocker(targetID: PortTargetID, containerID: String)
}

enum DockerContainerID {
    static let minimumLength = 12
    static let maximumLength = 64

    static func validated(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minimumLength...maximumLength).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return nil }
        return trimmed
    }
}

struct PortProcess: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let origin: PortProcessOrigin
    /// The lowest port, retained for existing sorting and single-port callers.
    let localPort: Int
    /// Ordered unique ports represented by this process/activity row.
    let localPorts: [Int]
    let transports: [TransportProtocol]
    let processName: String
    let endpoints: [Endpoint]
    let activityKind: PortActivityKind
    /// Stable per-socket identity from remote Linux `ss -e` output, when available.
    let remoteSocketIdentity: String?
    let source: PortProcessSource
    let controlTarget: PortControlTarget
    let isDockerPublished: Bool

    init(
        id: String,
        origin: PortProcessOrigin,
        localPort: Int,
        transport: TransportProtocol,
        processName: String,
        endpoints: [Endpoint],
        activityKind: PortActivityKind,
        remoteSocketIdentity: String? = nil,
        source: PortProcessSource? = nil,
        controlTarget: PortControlTarget? = nil,
        isDockerPublished: Bool = false
    ) {
        self.init(
            id: id,
            origin: origin,
            localPorts: [localPort],
            transports: [transport],
            processName: processName,
            endpoints: endpoints,
            activityKind: activityKind,
            remoteSocketIdentity: remoteSocketIdentity,
            source: source,
            controlTarget: controlTarget,
            isDockerPublished: isDockerPublished
        )
    }

    init(
        id: String,
        origin: PortProcessOrigin,
        localPort: Int,
        transports: [TransportProtocol],
        processName: String,
        endpoints: [Endpoint],
        activityKind: PortActivityKind,
        remoteSocketIdentity: String? = nil,
        source: PortProcessSource? = nil,
        controlTarget: PortControlTarget? = nil,
        isDockerPublished: Bool = false
    ) {
        self.id = id
        self.origin = origin
        self.localPort = localPort
        self.localPorts = [localPort]
        let uniqueTransports = Set(transports)
        self.transports = uniqueTransports.isEmpty
            ? [.tcp]
            : uniqueTransports.sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.rawValue < rhs.rawValue
            }
        self.processName = processName
        self.endpoints = endpoints
        self.activityKind = activityKind
        self.remoteSocketIdentity = remoteSocketIdentity
        self.source = source ?? Self.defaultSource(for: origin)
        self.controlTarget = controlTarget ?? Self.defaultControlTarget(for: origin)
        self.isDockerPublished = isDockerPublished
    }

    init(
        id: String,
        origin: PortProcessOrigin,
        localPorts: [Int],
        transport: TransportProtocol,
        processName: String,
        endpoints: [Endpoint],
        activityKind: PortActivityKind,
        remoteSocketIdentity: String? = nil,
        source: PortProcessSource? = nil,
        controlTarget: PortControlTarget? = nil,
        isDockerPublished: Bool = false
    ) {
        self.init(
            id: id,
            origin: origin,
            localPorts: localPorts,
            transports: [transport],
            processName: processName,
            endpoints: endpoints,
            activityKind: activityKind,
            remoteSocketIdentity: remoteSocketIdentity,
            source: source,
            controlTarget: controlTarget,
            isDockerPublished: isDockerPublished
        )
    }

    init(
        id: String,
        origin: PortProcessOrigin,
        localPorts: [Int],
        transports: [TransportProtocol],
        processName: String,
        endpoints: [Endpoint],
        activityKind: PortActivityKind,
        remoteSocketIdentity: String? = nil,
        source: PortProcessSource? = nil,
        controlTarget: PortControlTarget? = nil,
        isDockerPublished: Bool = false
    ) {
        let uniqueLocalPorts = Set(localPorts).sorted()
        precondition(!uniqueLocalPorts.isEmpty, "PortProcess requires at least one local port")

        self.id = id
        self.origin = origin
        self.localPort = uniqueLocalPorts[0]
        self.localPorts = uniqueLocalPorts
        let uniqueTransports = Set(transports)
        self.transports = uniqueTransports.isEmpty
            ? [.tcp]
            : uniqueTransports.sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.rawValue < rhs.rawValue
            }
        self.processName = processName
        self.endpoints = endpoints
        self.activityKind = activityKind
        self.remoteSocketIdentity = remoteSocketIdentity
        self.source = source ?? Self.defaultSource(for: origin)
        self.controlTarget = controlTarget ?? Self.defaultControlTarget(for: origin)
        self.isDockerPublished = isDockerPublished
    }

    init(
        id: String,
        identity: ProcessIdentity?,
        pid: Int32,
        localPort: Int,
        transport: TransportProtocol,
        processName: String,
        endpoints: [Endpoint],
        activityKind: PortActivityKind
    ) {
        self.init(
            id: id,
            origin: identity.map(PortProcessOrigin.local) ?? .localUnverified(pid: pid),
            localPort: localPort,
            transport: transport,
            processName: processName,
            endpoints: endpoints,
            activityKind: activityKind
        )
    }

    /// The first transport preserves the existing single-transport call sites.
    /// Aggregate remote Docker rows expose every protocol through `transports`.
    var transport: TransportProtocol { transports[0] }

    var localIdentity: ProcessIdentity? {
        if case let .local(identity) = origin { return identity }
        return nil
    }

    var identity: ProcessIdentity? { localIdentity }

    var pid: Int32? {
        switch origin {
        case let .local(identity): identity.pid
        case let .localUnverified(pid): pid
        case let .remote(_, pid): pid
        }
    }

    var isActionable: Bool {
        switch controlTarget {
        case .none:
            return false
        case .local:
            return localIdentity != nil
        case let .remoteProcess(_, pid):
            return source == .remoteProcess
                && (pid ?? 0) > 0
                && remoteSocketIdentity?.isEmpty == false
        case let .remoteDocker(_, containerID):
            guard isDockerPublished,
                  case let .dockerContainer(sourceID) = source,
                  sourceID == containerID else { return false }
            return DockerContainerID.validated(containerID) != nil
        }
    }

    var isRemote: Bool {
        if case .remote = origin { return true }
        return false
    }

    var isDockerContainer: Bool {
        if case .dockerContainer = source { return true }
        return false
    }

    var stableSortName: String {
        // Keep the historical Docker-prefixed sort key so changing the
        // presentation label does not reshuffle rows relative to non-Docker
        // processes. The row ID remains the final deterministic tie-breaker.
        isDockerPublished ? "Docker · \(processName)" : processName
    }

    private static func defaultSource(for origin: PortProcessOrigin) -> PortProcessSource {
        switch origin {
        case .local: return .localApplication
        case .localUnverified: return .unknown
        case .remote: return .remoteProcess
        }
    }

    private static func defaultControlTarget(for origin: PortProcessOrigin) -> PortControlTarget {
        switch origin {
        case let .local(identity): return .local(identity)
        case .localUnverified: return .none
        case let .remote(targetID, pid): return .remoteProcess(targetID: targetID, pid: pid)
        }
    }

    static func makeID(
        activityKind: PortActivityKind,
        transport: TransportProtocol,
        localPort: Int,
        pid: Int32,
        identity: ProcessIdentity?,
        scanGeneration: UInt64
    ) -> String {
        let processPart: String
        if let identity {
            processPart = "pid=\(identity.pid);start=\(identity.startTimeSeconds).\(identity.startTimeMicroseconds)"
        } else {
            processPart = "pid=\(pid);fallback-generation=\(scanGeneration)"
        }
        return "\(activityKind.rawValue)|\(transport.rawValue)|port=\(localPort)|\(processPart)"
    }
}

struct PortSnapshot: Equatable, Sendable {
    let listeners: [PortProcess]
    let connections: [PortProcess]

    static let empty = PortSnapshot(listeners: [], connections: [])

    var allRows: [PortProcess] {
        listeners + connections
    }
}

struct ScanDiagnostics: Equatable, Sendable {
    let stdoutBytes: Int
    let stderrBytes: Int
    let validRecords: Int
    let skippedRecords: Int
    let durationMilliseconds: Int
}

enum ScanFailure: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputTooLarge(stream: OutputStream)
    case permissionDenied
    case malformedOutput
    case nonZeroExit(status: Int32)
    case readFailed
    case cancelled

    enum OutputStream: String, Sendable {
        case stdout
        case stderr
    }

    var userMessage: String {
        switch self {
        case .launchFailed:
            return "Port scan could not start."
        case .timedOut:
            return "Port scan timed out. Showing the last results."
        case .outputTooLarge:
            return "Port data exceeded the safe limit. Showing the last results."
        case .permissionDenied:
            return "Some port information is unavailable."
        case .malformedOutput:
            return "Port data could not be read. Showing the last results."
        case .nonZeroExit:
            return "Port scan failed. Showing the last results."
        case .readFailed:
            return "Port scan failed. Showing the last results."
        case .cancelled:
            return ""
        }
    }

    var firstLoadMessage: String {
        switch self {
        case .launchFailed:
            return "Port scan could not start."
        case .timedOut:
            return "Port scan timed out."
        case .outputTooLarge:
            return "Port data exceeded the safe limit."
        case .permissionDenied:
            return "Some port information is unavailable."
        case .malformedOutput:
            return "Port data could not be read."
        case .nonZeroExit:
            return "Port scan failed."
        case .readFailed:
            return "Port scan failed."
        case .cancelled:
            return ""
        }
    }
}

enum ScanOutcome: Sendable {
    case success(snapshot: PortSnapshot, diagnostics: ScanDiagnostics)
    case failure(error: ScanFailure, diagnostics: ScanDiagnostics)
    case cancelled
}

enum TerminationFailure: Error, Equatable, Sendable {
    case staleTarget
    case revalidationFailed
    case sshAccessFailed
    case permissionDenied
    case dockerUnavailable
    case dockerPermissionDenied
    case stillAlive
    case system(code: Int32, description: String)

    var userMessage: String {
        switch self {
        case .staleTarget:
            return "The process or container changed before it could be stopped."
        case .revalidationFailed:
            return "Porto could not verify the process or container before stopping it."
        case .sshAccessFailed:
            return "Porto could not revalidate the remote target over SSH."
        case .permissionDenied:
            return "Porto does not have permission to stop this process."
        case .dockerUnavailable:
            return "Docker control is unavailable on the remote host."
        case .dockerPermissionDenied:
            return "Porto does not have permission to control Docker on the remote host."
        case .stillAlive:
            return "The process or container is still running."
        case .system:
            return "The process could not be stopped."
        }
    }

    var helpText: String {
        switch self {
        case .staleTarget:
            return "The process, container, or selected port changed, so Porto sent no signal. Refresh and try again."
        case .revalidationFailed:
            return "Porto could not revalidate the process or container and sent no signal. Refresh and try again."
        case .sshAccessFailed:
            return "The SSH connection or remote port inspection failed, so Porto sent no signal. Check the profile and refresh."
        case .permissionDenied:
            return "The process denied the signal. Porto does not use elevated helpers in v1."
        case .dockerUnavailable:
            return "The Docker CLI or daemon was unavailable for this remote account. Porto does not install or start Docker for you."
        case .dockerPermissionDenied:
            return "The SSH account cannot access the Docker CLI or daemon. Porto does not use sudo or elevated helpers in v1."
        case .stillAlive:
            return "The process or container remained alive after the requested force kill."
        case let .system(_, description):
            return description
        }
    }
}

enum TerminationOutcome: Sendable, Equatable {
    case exited
    case forceKillAvailable
    case failed(TerminationFailure)
    case cancelled
}

enum TerminationUIState: Equatable, Sendable {
    case inProgress
    case forceKillAvailable
    case failed(TerminationFailure)
}

struct PortProcessSort {
    static func sort(_ rows: [PortProcess]) -> [PortProcess] {
        rows.sorted { lhs, rhs in
            if lhs.localPort != rhs.localPort { return lhs.localPort < rhs.localPort }
            let nameOrder = lhs.stableSortName.localizedCaseInsensitiveCompare(rhs.stableSortName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if lhs.transport.sortOrder != rhs.transport.sortOrder {
                return lhs.transport.sortOrder < rhs.transport.sortOrder
            }
            if lhs.pid != rhs.pid { return (lhs.pid ?? Int32.max) < (rhs.pid ?? Int32.max) }
            return lhs.id < rhs.id
        }
    }
}
