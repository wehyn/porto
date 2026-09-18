import Foundation
import XCTest
@testable import Porto

final class PortScannerGroupingTests: XCTestCase {
    func testScannerPublishesGroupedRowsAfterEnrichment() async throws {
        let inspector = GroupingTestInspector(
            identities: [100: ProcessIdentity(pid: 100, startTimeSeconds: 1, startTimeMicroseconds: 1)]
        )
        let scanner = PortScanner(
            runner: GroupingTestLsofRunner(responses: [groupingExecution()]),
            inspector: inspector
        )

        let outcome = await scanner.scan(generation: 7)

        guard case let .success(snapshot, _) = outcome else {
            return XCTFail("expected a successful scan")
        }
        XCTAssertEqual(snapshot.listeners.count, 1)
        XCTAssertEqual(snapshot.listeners[0].localPorts, [5353, 8080, 8443])
        XCTAssertEqual(snapshot.listeners[0].transports, [.tcp, .udp])
        XCTAssertEqual(snapshot.connections.count, 1)
        XCTAssertEqual(snapshot.connections[0].localPorts, [40000, 40001])
        XCTAssertEqual(
            snapshot.connections[0].endpoints.map(\.rawValue),
            [
                "192.0.2.10:40000->198.51.100.10:443",
                "192.0.2.10:40001->198.51.100.11:443"
            ]
        )
        XCTAssertEqual(inspector.callCount(for: 100), 1)
    }

    func testScannerKeepsSameNamedProcessesSeparate() async {
        let inspector = GroupingTestInspector(
            identities: [
                100: ProcessIdentity(pid: 100, startTimeSeconds: 1, startTimeMicroseconds: 1),
                200: ProcessIdentity(pid: 200, startTimeSeconds: 2, startTimeMicroseconds: 1)
            ]
        )
        let scanner = PortScanner(
            runner: GroupingTestLsofRunner(responses: [sameNameProcessesExecution()]),
            inspector: inspector
        )

        let outcome = await scanner.scan(generation: 8)

        guard case let .success(snapshot, _) = outcome else {
            return XCTFail("expected a successful scan")
        }
        XCTAssertEqual(snapshot.listeners.count, 2)
        XCTAssertEqual(Set(snapshot.listeners.map(\.pid)), [100, 200])
        XCTAssertEqual(Set(snapshot.listeners.map(\.localPorts)), [[8080], [8443]])
    }

    func testValidateSocketMatchesAnAggregatePortAndTransport() async {
        let identity = ProcessIdentity(pid: 100, startTimeSeconds: 1, startTimeMicroseconds: 1)
        let row = PortProcess(
            id: "aggregate",
            origin: .local(identity),
            localPorts: [8080, 8443],
            transports: [.tcp, .udp],
            processName: "web",
            endpoints: [],
            activityKind: .listener
        )
        let scanner = PortScanner(
            runner: GroupingTestLsofRunner(responses: [
                groupingExecution(fields: [
                    "p100", "cweb", "f1", "PTCP", "n*:8443", "TST=LISTEN"
                ])
            ]),
            inspector: GroupingTestInspector(identities: [100: identity])
        )

        let result = await scanner.validateSocket(for: row)

        XCTAssertEqual(result, .matched(processName: "web"))
    }

    func testValidateSocketRejectsPortOutsideAnAggregate() async {
        let identity = ProcessIdentity(pid: 100, startTimeSeconds: 1, startTimeMicroseconds: 1)
        let row = PortProcess(
            id: "aggregate",
            origin: .local(identity),
            localPorts: [8080, 8443],
            transports: [.tcp, .udp],
            processName: "web",
            endpoints: [],
            activityKind: .listener
        )
        let scanner = PortScanner(
            runner: GroupingTestLsofRunner(responses: [
                groupingExecution(fields: [
                    "p100", "cweb", "f1", "PTCP", "n*:9000", "TST=LISTEN"
                ])
            ]),
            inspector: GroupingTestInspector(identities: [100: identity])
        )

        let result = await scanner.validateSocket(for: row)

        XCTAssertEqual(result, .socketMissing)
    }

    private func groupingExecution(fields: [String]? = nil) -> LsofExecutionResult {
        let fields = fields ?? [
            "p100", "cweb", "f1", "PTCP", "n*:8080", "TST=LISTEN",
            "f2", "PTCP", "n*:8443", "TST=LISTEN",
            "f3", "PUDP", "n*:5353",
            "f4", "PTCP", "n192.0.2.10:40000->198.51.100.10:443", "TST=ESTABLISHED",
            "f5", "PTCP", "n192.0.2.10:40001->198.51.100.11:443", "TST=ESTABLISHED"
        ]
        return groupingExecution(stdout: nulFixture(fields))
    }

    private func sameNameProcessesExecution() -> LsofExecutionResult {
        groupingExecution(stdout: nulFixture([
            "p100", "cweb", "f1", "PTCP", "n*:8080", "TST=LISTEN",
            "p200", "cWEB", "f2", "PTCP", "n*:8443", "TST=LISTEN"
        ]))
    }

    private func groupingExecution(stdout: Data) -> LsofExecutionResult {
        LsofExecutionResult(
            stdout: stdout,
            stderr: Data(),
            terminationStatus: 0,
            terminationReason: .exit,
            failure: nil,
            durationMilliseconds: 1
        )
    }

    private func nulFixture(_ fields: [String]) -> Data {
        var data = Data(fields.joined(separator: "\0\n").utf8)
        data.append(0)
        return data
    }
}

private actor GroupingTestLsofRunner: LsofRunning {
    private var responses: [LsofExecutionResult]

    init(responses: [LsofExecutionResult]) {
        self.responses = responses
    }

    func run(arguments: [String]) async -> LsofExecutionResult {
        responses.isEmpty
            ? LsofExecutionResult(stdout: Data(), stderr: Data(), terminationStatus: nil, terminationReason: nil, failure: .cancelled, durationMilliseconds: 0)
            : responses.removeFirst()
    }

    func cancelActive() async {}
}

private final class GroupingTestInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let identities: [Int32: ProcessIdentity]
    private var calls: [Int32: Int] = [:]

    init(identities: [Int32: ProcessIdentity]) {
        self.identities = identities
    }

    func identity(for pid: Int32) -> ProcessIdentity? {
        lock.lock()
        calls[pid, default: 0] += 1
        lock.unlock()
        return identities[pid]
    }

    func processName(for pid: Int32) -> String? { nil }

    func callCount(for pid: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls[pid, default: 0]
    }
}
