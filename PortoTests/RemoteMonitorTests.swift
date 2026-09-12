import Foundation
import XCTest
@testable import Porto

@MainActor
final class RemoteMonitorTests: XCTestCase {
    func testRemoteRowsAreReadOnlyAndNeverReachTerminator() async throws {
        let root = try makeSSHDirectory(hosts: ["prod"])
        defer { try? FileManager.default.removeItem(at: root) }
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let remote = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(name: "nginx", port: 8080))])
        let terminator = RecordingTerminator()
        let monitor = PortMonitor(
            localScanner: local,
            terminator: terminator,
            hostCatalog: SSHHostCatalog(sshDirectory: root),
            remoteScannerFactory: { _ in remote },
            ownPID: 99,
            clock: NeverMonitorClock()
        )
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 }
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "prod")))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }

        let row = try XCTUnwrap(monitor.listenerRows.first)
        XCTAssertTrue(row.isRemote)
        XCTAssertFalse(row.isActionable)
        XCTAssertNil(monitor.terminationState(for: row))
        monitor.requestStop(for: row)
        let stopCount = await terminator.stopCount()
        XCTAssertEqual(stopCount, 0)
    }

    func testTargetCachesAreIsolatedAndFailureRetainsOnlySelectedCache() async throws {
        let root = try makeSSHDirectory(hosts: ["a", "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let a = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(name: "a", port: 8001))])
        let b = MonitorTestScanner(plans: [.failure(.remote(.hostUnreachable))])
        let monitor = PortMonitor(
            localScanner: local,
            terminator: RecordingTerminator(),
            hostCatalog: SSHHostCatalog(sshDirectory: root),
            remoteScannerFactory: { host in
                if host.alias == "a" {
                    return a as any PortSnapshotScanning
                }
                return b as any PortSnapshotScanning
            },
            clock: NeverMonitorClock()
        )
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 }
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "a")))
        await waitUntil { await a.count() == 1 && !monitor.isScanning }
        let aRows = monitor.listenerRows
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "b")))
        await waitUntil { await b.count() == 1 && !monitor.isScanning }
        XCTAssertTrue(monitor.listenerRows.isEmpty)
        XCTAssertEqual(monitor.remoteFailure, .hostUnreachable)
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "a")))
        await waitUntil { !monitor.isScanning }
        XCTAssertEqual(monitor.listenerRows, aRows)
        XCTAssertTrue(monitor.isStale)
    }

    func testLateOldTargetResultCannotPublishAfterSwitch() async throws {
        let root = try makeSSHDirectory(hosts: ["a", "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let local = MonitorTestScanner(plans: [.success(.empty)])
        let a = DelayedMonitorScanner(snapshot: makeRemoteSnapshot(name: "old", port: 8100))
        let b = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(name: "new", port: 8101))])
        let monitor = PortMonitor(
            localScanner: local,
            terminator: RecordingTerminator(),
            hostCatalog: SSHHostCatalog(sshDirectory: root),
            remoteScannerFactory: { host in
                if host.alias == "a" {
                    return a as any PortSnapshotScanning
                }
                return b as any PortSnapshotScanning
            },
            clock: NeverMonitorClock()
        )
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 }
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "a")))
        await waitUntil { await a.started() }
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "b")))
        await a.release()
        await waitUntil { await b.count() == 1 && monitor.listenerRows.first?.processName == "new" }
        await Task.yield()
        XCTAssertEqual(monitor.listenerRows.first?.processName, "new")
    }

    func testRemovedSelectedAliasFallsBackToThisMacOnNextOpen() async throws {
        let root = try makeSSHDirectory(hosts: ["gone"])
        defer { try? FileManager.default.removeItem(at: root) }
        let local = MonitorTestScanner(plans: [.success(.empty), .success(.empty)])
        let remote = MonitorTestScanner(plans: [.success(makeRemoteSnapshot(name: "gone", port: 8200))])
        let monitor = PortMonitor(
            localScanner: local,
            terminator: RecordingTerminator(),
            hostCatalog: SSHHostCatalog(sshDirectory: root),
            remoteScannerFactory: { _ in remote },
            clock: NeverMonitorClock()
        )
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await local.count() == 1 }
        monitor.selectTarget(PortTarget.ssh(SSHHost(alias: "gone")))
        await waitUntil { await remote.count() == 1 && !monitor.isScanning }

        try Data("Host replacement\n".utf8).write(to: root.appendingPathComponent("config"))
        monitor.setPresented(false)
        monitor.setPresented(true)

        XCTAssertEqual(monitor.selectedTarget, .local)
        await waitUntil { await local.count() == 2 && !monitor.isScanning }
    }

    func testBackoffScheduleIsBoundedAtThirtySeconds() {
        XCTAssertEqual(PortMonitor.backoffDelay(for: 1), .seconds(2))
        XCTAssertEqual(PortMonitor.backoffDelay(for: 2), .seconds(4))
        XCTAssertEqual(PortMonitor.backoffDelay(for: 3), .seconds(8))
        XCTAssertEqual(PortMonitor.backoffDelay(for: 4), .seconds(16))
        XCTAssertEqual(PortMonitor.backoffDelay(for: 5), .seconds(30))
        XCTAssertEqual(PortMonitor.backoffDelay(for: 100), .seconds(30))
    }

    private func makeSSHDirectory(hosts: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("porto-remote-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lines = hosts.map { "Host \($0)" }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: root.appendingPathComponent("config"))
        return root
    }

    private func makeRemoteSnapshot(name: String, port: Int) -> PortSnapshot {
        let target = PortTargetID.ssh(alias: name)
        let row = PortProcess(
            id: "remote|\(name)|\(port)",
            origin: .remote(targetID: target, pid: nil),
            localPort: port,
            transport: .tcp,
            processName: name,
            endpoints: [Endpoint(rawValue: "*:\(port)->*:*", localPort: port, hasRemoteEndpoint: false, socketState: "LISTEN")],
            activityKind: .listener
        )
        return PortSnapshot(listeners: [row], connections: [])
    }

    private func waitUntil(_ predicate: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<100 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct NeverMonitorClock: MonitorSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

private actor MonitorTestScanner: PortSnapshotScanning {
    enum Plan: Sendable {
        case success(PortSnapshot)
        case failure(PortScanFailure)
    }

    private var plans: [Plan]
    private var calls = 0

    init(plans: [Plan]) { self.plans = plans }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        calls += 1
        let plan = plans.isEmpty ? .success(.empty) : plans.removeFirst()
        switch plan {
        case let .success(snapshot):
            return .success(TargetedPortSnapshot(targetID: request.targetID, sessionGeneration: request.sessionGeneration, snapshot: snapshot, diagnostics: .zero))
        case let .failure(error):
            return .failure(targetID: request.targetID, sessionGeneration: request.sessionGeneration, error: error, diagnostics: .zero)
        }
    }

    func cancelActiveWork() async {}
    func count() -> Int { calls }
}

private actor DelayedMonitorScanner: PortSnapshotScanning {
    private let snapshot: PortSnapshot
    private var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(snapshot: PortSnapshot) { self.snapshot = snapshot }

    func scan(_ request: PortScanRequest) async -> PortScanOutcome {
        didStart = true
        await withCheckedContinuation { continuation in self.continuation = continuation }
        return .success(TargetedPortSnapshot(targetID: request.targetID, sessionGeneration: request.sessionGeneration, snapshot: snapshot, diagnostics: .zero))
    }

    func cancelActiveWork() async {}
    func started() -> Bool { didStart }
    func release() { continuation?.resume(); continuation = nil }
}

private actor RecordingTerminator: ProcessTerminating {
    private var stops = 0
    func stop(row: PortProcess) async -> TerminationOutcome { stops += 1; return .cancelled }
    func forceKill(row: PortProcess) async -> TerminationOutcome { .cancelled }
    func stopCount() -> Int { stops }
}

private extension ScanDiagnostics {
    static let zero = ScanDiagnostics(stdoutBytes: 0, stderrBytes: 0, validRecords: 0, skippedRecords: 0, durationMilliseconds: 0)
}
