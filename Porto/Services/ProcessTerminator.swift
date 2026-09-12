import Darwin
import Foundation

protocol MonitorSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct SystemMonitorClock: MonitorSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

enum SignalSendResult: Sendable, Equatable {
    case sent
    case failed(errno: Int32, description: String)
}

protocol ProcessSignaling: Sendable {
    func send(signal: Int32, to pid: Int32) -> SignalSendResult
}

struct DarwinProcessSignalSender: ProcessSignaling {
    func send(signal: Int32, to pid: Int32) -> SignalSendResult {
        guard Darwin.kill(pid, signal) == 0 else {
            let code = errno
            let description = String(cString: strerror(code))
            return .failed(errno: code, description: description)
        }
        return .sent
    }
}

protocol ProcessTerminating: Sendable {
    func stop(row: PortProcess) async -> TerminationOutcome
    func forceKill(row: PortProcess) async -> TerminationOutcome
}

actor ProcessTerminator: ProcessTerminating {
    private let validator: any LocalSocketValidating
    private let inspector: any ProcessInspecting
    private let signalSender: any ProcessSignaling
    private let clock: any MonitorSleeping
    private let ownPID: Int32

    init(
        validator: any LocalSocketValidating,
        inspector: any ProcessInspecting,
        signalSender: any ProcessSignaling,
        clock: any MonitorSleeping = SystemMonitorClock(),
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.validator = validator
        self.inspector = inspector
        self.signalSender = signalSender
        self.clock = clock
        self.ownPID = ownPID
    }

    init(
        scanner: any LocalSocketValidating,
        inspector: any ProcessInspecting,
        signalSender: any ProcessSignaling,
        clock: any MonitorSleeping = SystemMonitorClock(),
        ownPID: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.init(
            validator: scanner,
            inspector: inspector,
            signalSender: signalSender,
            clock: clock,
            ownPID: ownPID
        )
    }

    func stop(row: PortProcess) async -> TerminationOutcome {
        guard let identity = row.localIdentity, identity.pid != ownPID else {
            return .failed(.staleTarget)
        }

        guard let beforeValidation = inspector.identity(for: identity.pid) else {
            return .exited
        }
        guard beforeValidation == identity else { return .failed(.staleTarget) }

        switch await validator.validateSocket(for: row) {
        case .processExited:
            return .exited
        case .identityChanged, .socketMissing:
            return .failed(.staleTarget)
        case let .failed(failure):
            return mapValidationFailure(failure)
        case let .matched(processName):
            guard processName == row.processName else { return .failed(.staleTarget) }
        }

        guard let afterValidation = inspector.identity(for: identity.pid) else {
            return .exited
        }
        guard afterValidation == identity else { return .failed(.staleTarget) }
        guard let currentName = inspector.processName(for: identity.pid), currentName == row.processName else {
            return .failed(.staleTarget)
        }
        guard !Task.isCancelled else { return .cancelled }

        switch signalSender.send(signal: SIGTERM, to: identity.pid) {
        case .sent:
            return await waitForExit(identity: identity, checks: 20)
        case let .failed(errno, description):
            return signalFailure(errno: errno, description: description)
        }
    }

    func forceKill(row: PortProcess) async -> TerminationOutcome {
        guard let identity = row.localIdentity, identity.pid != ownPID else {
            return .failed(.staleTarget)
        }

        guard let beforeValidation = inspector.identity(for: identity.pid) else {
            return .exited
        }
        guard beforeValidation == identity else { return .failed(.staleTarget) }

        switch await validator.validateSocket(for: row) {
        case .processExited:
            return .exited
        case .identityChanged, .socketMissing:
            return .failed(.staleTarget)
        case let .failed(failure):
            return mapValidationFailure(failure)
        case let .matched(processName):
            guard processName == row.processName else { return .failed(.staleTarget) }
        }

        guard let afterValidation = inspector.identity(for: identity.pid) else {
            return .exited
        }
        guard afterValidation == identity else { return .failed(.staleTarget) }
        guard let currentName = inspector.processName(for: identity.pid), currentName == row.processName else {
            return .failed(.staleTarget)
        }
        guard !Task.isCancelled else { return .cancelled }

        switch signalSender.send(signal: SIGKILL, to: identity.pid) {
        case .sent:
            return await waitForExit(identity: identity, checks: 10, forceKill: true)
        case let .failed(errno, description):
            return signalFailure(errno: errno, description: description)
        }
    }

    private func waitForExit(
        identity: ProcessIdentity,
        checks: Int,
        forceKill: Bool = false
    ) async -> TerminationOutcome {
        let interval: Duration = .milliseconds(100)

        for _ in 0..<checks {
            if Task.isCancelled { return .cancelled }
            do {
                try await clock.sleep(for: interval)
            } catch {
                return .cancelled
            }
            guard let current = inspector.identity(for: identity.pid) else { return .exited }
            if current != identity { return .exited }
        }
        return forceKill ? .failed(.stillAlive) : .forceKillAvailable
    }

    private func signalFailure(errno: Int32, description: String) -> TerminationOutcome {
        switch errno {
        case ESRCH:
            return .exited
        case EPERM, EACCES:
            return .failed(.permissionDenied)
        default:
            return .failed(.system(code: errno, description: description))
        }
    }

    private func mapValidationFailure(_ failure: ScanFailure) -> TerminationOutcome {
        switch failure {
        case .cancelled:
            return .cancelled
        case .permissionDenied:
            return .failed(.permissionDenied)
        default:
            return .failed(.revalidationFailed)
        }
    }
}
