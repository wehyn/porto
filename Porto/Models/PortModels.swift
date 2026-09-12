import Foundation

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

struct PortProcess: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let origin: PortProcessOrigin
    let localPort: Int
    let transport: TransportProtocol
    let processName: String
    let endpoints: [Endpoint]
    let activityKind: PortActivityKind

    init(
        id: String,
        origin: PortProcessOrigin,
        localPort: Int,
        transport: TransportProtocol,
        processName: String,
        endpoints: [Endpoint],
        activityKind: PortActivityKind
    ) {
        self.id = id
        self.origin = origin
        self.localPort = localPort
        self.transport = transport
        self.processName = processName
        self.endpoints = endpoints
        self.activityKind = activityKind
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
        localIdentity != nil
    }

    var isRemote: Bool {
        if case .remote = origin { return true }
        return false
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
    case permissionDenied
    case stillAlive
    case system(code: Int32, description: String)

    var userMessage: String {
        switch self {
        case .staleTarget:
            return "The process changed before it could be stopped."
        case .revalidationFailed:
            return "Porto could not verify the process before stopping it."
        case .permissionDenied:
            return "Porto does not have permission to stop this process."
        case .stillAlive:
            return "The process is still running."
        case .system:
            return "The process could not be stopped."
        }
    }

    var helpText: String {
        switch self {
        case .staleTarget:
            return "The process or selected port changed, so Porto sent no signal. Refresh and try again."
        case .revalidationFailed:
            return "Porto could not revalidate the process and sent no signal. Refresh and try again."
        case .permissionDenied:
            return "The process denied the signal. Porto does not use elevated helpers in v1."
        case .stillAlive:
            return "The process remained alive after the requested force kill."
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
            let nameOrder = lhs.processName.localizedCaseInsensitiveCompare(rhs.processName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            if lhs.transport.sortOrder != rhs.transport.sortOrder {
                return lhs.transport.sortOrder < rhs.transport.sortOrder
            }
            if lhs.pid != rhs.pid { return (lhs.pid ?? Int32.max) < (rhs.pid ?? Int32.max) }
            return lhs.id < rhs.id
        }
    }
}
