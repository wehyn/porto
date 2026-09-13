import Foundation

enum ScanTrigger: String, Sendable, Equatable, Codable {
    case presentation
    case targetChange
    case scheduled
    case manual
}

struct PortScanRequest: Sendable, Equatable {
    let targetID: PortTargetID
    let sessionGeneration: UInt64
    let scanGeneration: UInt64
    let trigger: ScanTrigger
}

struct TargetedPortSnapshot: Sendable, Equatable {
    let targetID: PortTargetID
    let sessionGeneration: UInt64
    let snapshot: PortSnapshot
    let diagnostics: ScanDiagnostics
}

enum RemoteScanFailure: Error, Equatable, Sendable {
    case sshNotFound
    case launchFailed
    case authenticationFailed
    case hostKeyVerificationFailed
    case hostUnreachable
    case connectionTimedOut
    case commandTimedOut
    case ssUnavailableOrIncompatible
    case outputTooLarge(stream: ScanFailure.OutputStream)
    case malformedOutput
    case readFailed
    case nonZeroExit(status: Int32)
    case cancelled

    var userMessage: String {
        switch self {
        case .sshNotFound: "OpenSSH is unavailable on this Mac."
        case .launchFailed: "The remote scan could not start."
        case .authenticationFailed: "SSH authentication failed."
        case .hostKeyVerificationFailed: "SSH host key verification failed."
        case .hostUnreachable: "The SSH host could not be reached."
        case .connectionTimedOut, .commandTimedOut: "The remote scan timed out."
        case .ssUnavailableOrIncompatible: "The server's `ss` command is unavailable or incompatible."
        case .outputTooLarge: "Remote port data exceeded the safe limit."
        case .malformedOutput: "Remote port data could not be read."
        case .readFailed: "The remote scan failed while reading output."
        case .nonZeroExit: "The remote scan failed."
        case .cancelled: ""
        }
    }
}

enum RemoteConnectionTestResult: Equatable, Sendable {
    case success
    case failed(RemoteScanFailure)
    case refusedDisabled
}

enum PortScanFailure: Error, Equatable, Sendable {
    case local(ScanFailure)
    case remote(RemoteScanFailure)

    var userMessage: String {
        switch self {
        case let .local(error): error.firstLoadMessage
        case let .remote(error): error.userMessage
        }
    }

    var isCancellation: Bool {
        self == .local(.cancelled) || self == .remote(.cancelled)
    }
}

enum PortScanOutcome: Sendable {
    case success(TargetedPortSnapshot)
    case failure(
        targetID: PortTargetID,
        sessionGeneration: UInt64,
        error: PortScanFailure,
        diagnostics: ScanDiagnostics
    )
    case cancelled
}

struct TargetMonitorState: Sendable, Equatable {
    var snapshot: PortSnapshot?
    var lastSuccess: ContinuousClock.Instant?
    var diagnostics: ScanDiagnostics?
    var failure: PortScanFailure?
    var consecutiveFailures: Int

    static let empty = TargetMonitorState(
        snapshot: nil,
        lastSuccess: nil,
        diagnostics: nil,
        failure: nil,
        consecutiveFailures: 0
    )
}
