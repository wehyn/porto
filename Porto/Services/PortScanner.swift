import Darwin
import Foundation

protocol ProcessInspecting: Sendable {
    func identity(for pid: Int32) -> ProcessIdentity?
    func processName(for pid: Int32) -> String?
}

struct DarwinProcessInspector: ProcessInspecting {
    func identity(for pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let bytes = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard bytes == expectedSize, info.pbi_pid == UInt32(pid) else { return nil }
        return ProcessIdentity(
            pid: pid,
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        )
    }

    func processName(for pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum SocketValidationResult: Sendable, Equatable {
    case matched(processName: String)
    case processExited
    case identityChanged
    case socketMissing
    case failed(ScanFailure)
}

protocol PortScanning: Sendable {
    func scan(generation: UInt64) async -> ScanOutcome
    func validateSocket(for row: PortProcess) async -> SocketValidationResult
    func cancelActiveWork() async
}

actor PortScanner: PortScanning {
    static let normalArguments = [
        "-nP", "-w", "-iTCP", "-iUDP", "-F0pcfPntT", "-Ts"
    ]

    static func targetedArguments(pid: Int32) -> [String] {
        ["-nP", "-w", "-a", "-p", String(pid), "-iTCP", "-iUDP", "-F0pcfPntT", "-Ts"]
    }

    private let runner: any LsofRunning
    private let inspector: any ProcessInspecting
    private let visibilityPolicy: PortVisibilityPolicy
    private let parser = LsofParser()

    init(
        runner: any LsofRunning,
        inspector: any ProcessInspecting,
        visibilityPolicy: PortVisibilityPolicy = .developerFocused
    ) {
        self.runner = runner
        self.inspector = inspector
        self.visibilityPolicy = visibilityPolicy
    }

    func scan(generation: UInt64) async -> ScanOutcome {
        let execution = await runner.run(arguments: Self.normalArguments)
        let diagnosticsBase = ScanDiagnostics(
            stdoutBytes: execution.stdout.count,
            stderrBytes: execution.stderr.count,
            validRecords: 0,
            skippedRecords: 0,
            durationMilliseconds: execution.durationMilliseconds
        )

        if let failure = execution.failure {
            if failure == .cancelled { return .cancelled }
            return .failure(error: map(failure), diagnostics: diagnosticsBase)
        }
        guard let status = execution.terminationStatus else {
            return .cancelled
        }
        if status != 0, !(status == 1 && execution.stdout.isEmpty && execution.stderr.isEmpty) {
            let failure: ScanFailure
            if dataContainsPermissionHint(execution.stderr) {
                failure = .permissionDenied
            } else {
                failure = .nonZeroExit(status: status)
            }
            return .failure(error: failure, diagnostics: diagnosticsBase)
        }

        let parsed = parser.parse(execution.stdout)
        let diagnostics = ScanDiagnostics(
            stdoutBytes: execution.stdout.count,
            stderrBytes: execution.stderr.count,
            validRecords: parsed.validRecords,
            skippedRecords: parsed.skippedRecords,
            durationMilliseconds: execution.durationMilliseconds
        )
        if parsed.sawNonStructuralInput && parsed.validRecords == 0 {
            return .failure(error: .malformedOutput, diagnostics: diagnostics)
        }

        let visibleGroups = parsed.groups.filter(visibilityPolicy.includes)
        let snapshot = enrich(visibleGroups, generation: generation)
        return .success(snapshot: snapshot, diagnostics: diagnostics)
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        guard row.pid > 0, row.identity?.pid == row.pid else { return .identityChanged }
        let execution = await runner.run(arguments: Self.targetedArguments(pid: row.pid))
        if let failure = execution.failure {
            if failure == .cancelled { return .failed(.cancelled) }
            if processIsGone(row.pid) { return .processExited }
            return .failed(map(failure))
        }
        guard let status = execution.terminationStatus else { return .failed(.cancelled) }
        let noMatchExit = status == 1 && execution.stdout.isEmpty && execution.stderr.isEmpty
        let parsed = parser.parse(execution.stdout)
        // macOS lsof can return 1 while still emitting valid records when
        // repeated -i selectors are combined for targeted validation. Those
        // records remain authoritative; an empty status-1 result is the
        // no-match case above.
        let parseableStatusOne = status == 1
            && execution.stderr.isEmpty
            && parsed.validRecords > 0
        if status != 0 && !noMatchExit && !parseableStatusOne {
            if processIsGone(row.pid) { return .processExited }
            let failure: ScanFailure = dataContainsPermissionHint(execution.stderr)
                ? .permissionDenied
                : .nonZeroExit(status: status)
            return .failed(failure)
        }
        if parsed.sawNonStructuralInput && parsed.validRecords == 0 {
            return .failed(.malformedOutput)
        }

        let matchedGroup = parsed.groups.first { group in
            group.key.pid == row.pid
                && group.key.activityKind == row.activityKind
                && group.key.transport == row.transport
                && group.key.localPort == row.localPort
        }
        if let matchedGroup {
            return .matched(processName: matchedGroup.processName)
        }
        if processIsGone(row.pid) { return .processExited }
        if inspector.identity(for: row.pid) != row.identity { return .identityChanged }
        return .socketMissing
    }

    func cancelActiveWork() async {
        await runner.cancelActive()
    }

    private func enrich(_ groups: [ParsedPortGroup], generation: UInt64) -> PortSnapshot {
        var identities: [Int32: ProcessIdentity] = [:]
        var inspectedPIDs: Set<Int32> = []
        for group in groups where inspectedPIDs.insert(group.key.pid).inserted {
            if let identity = inspector.identity(for: group.key.pid) {
                identities[group.key.pid] = identity
            }
        }

        let rows = groups.map { group in
            let identity = identities[group.key.pid]
            return PortProcess(
                id: PortProcess.makeID(
                    activityKind: group.key.activityKind,
                    transport: group.key.transport,
                    localPort: group.key.localPort,
                    pid: group.key.pid,
                    identity: identity,
                    scanGeneration: generation
                ),
                identity: identity,
                pid: group.key.pid,
                localPort: group.key.localPort,
                transport: group.key.transport,
                processName: group.processName.isEmpty ? "Unknown process" : group.processName,
                endpoints: group.endpoints,
                activityKind: group.key.activityKind
            )
        }

        return PortSnapshot(
            listeners: PortProcessSort.sort(rows.filter { $0.activityKind == .listener }),
            connections: PortProcessSort.sort(rows.filter { $0.activityKind == .connection })
        )
    }

    private func processIsGone(_ pid: Int32) -> Bool {
        inspector.identity(for: pid) == nil
    }

    private func map(_ failure: LsofRunnerFailure) -> ScanFailure {
        switch failure {
        case .launchFailed: return .launchFailed
        case .timedOut: return .timedOut
        case let .outputTooLarge(stream): return .outputTooLarge(stream: stream)
        case .readFailed: return .readFailed
        case .busy: return .readFailed
        case .cancelled: return .cancelled
        }
    }

    private func dataContainsPermissionHint(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("permission") || text.contains("operation not permitted") || text.contains("denied")
    }
}
