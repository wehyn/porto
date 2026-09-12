import Darwin
import Foundation
import XCTest
@testable import Porto

final class PortVisibilityPolicyTests: XCTestCase {
    func testDeveloperPolicyHidesKnownInfrastructureWithoutHidingCustomPorts() {
        let policy = PortVisibilityPolicy.developerFocused

        XCTAssertFalse(policy.includes(parsedGroup(port: 3722, processName: "rapportd")))
        XCTAssertFalse(policy.includes(parsedGroup(port: 3722, processName: "remotepairingd")))
        XCTAssertFalse(policy.includes(parsedGroup(port: 5000, processName: "ControlCenter")))
        XCTAssertFalse(policy.includes(parsedGroup(port: 64776, processName: "rapportd")))
        XCTAssertFalse(policy.includes(parsedGroup(port: 62096, processName: "replicatord")))
        XCTAssertFalse(policy.includes(parsedGroup(port: 6463, processName: "Discord Helper (Renderer)")))
        XCTAssertFalse(policy.includes(parsedGroup(port: 52369, processName: "Zen")))
        XCTAssertTrue(policy.includes(parsedGroup(port: 3722, processName: "my-app")))
        XCTAssertTrue(policy.includes(parsedGroup(port: 5000, processName: "my-local-app")))
    }

    func testDeveloperPolicyKeepsCustomPortsVisible() {
        let policy = PortVisibilityPolicy.developerFocused

        XCTAssertTrue(policy.includes(parsedGroup(port: 45678, processName: "my-local-app")))
    }

    func testRemotePolicyHidesCommonServicePortsButKeepsCustomPortsVisible() {
        let policy = PortVisibilityPolicy.remoteFocused

        for port in [22, 53, 80, 137, 443, 5353] {
            XCTAssertFalse(policy.includes(parsedGroup(port: port, processName: "service")), "port \(port) should be hidden")
        }
        XCTAssertFalse(policy.includes(parsedGroup(port: 8080, processName: "Unknown process")))
        XCTAssertTrue(policy.includes(parsedGroup(port: 80, processName: "Docker · pihole")))
        XCTAssertTrue(policy.includes(parsedGroup(port: 8080, processName: "my-remote-app")))
    }

    private func parsedGroup(port: Int, processName: String) -> ParsedPortGroup {
        ParsedPortGroup(
            key: PreliminaryGroupKey(
                activityKind: .listener,
                transport: .tcp,
                localPort: port,
                pid: 10
            ),
            processName: processName,
            endpoints: []
        )
    }
}

final class LsofParserTests: XCTestCase {
    func testClassifiesAndGroupsTCPUDPIPv4IPv6AndSharedKeys() {
        let parsed = LsofParser().parse(mixedFixture)

        XCTAssertEqual(parsed.validRecords, 8)
        XCTAssertEqual(parsed.skippedRecords, 0)
        XCTAssertEqual(parsed.groups.count, 4)

        let webListener = parsed.groups.first {
            $0.key.pid == 100 && $0.key.activityKind == .listener && $0.key.localPort == 8080
        }
        XCTAssertEqual(webListener?.key.transport, .tcp)
        XCTAssertEqual(webListener?.endpoints.count, 2)
        XCTAssertEqual(webListener?.endpoints.map(\.rawValue), ["*:8080", "[::]:8080"])

        let webConnection = parsed.groups.first {
            $0.key.pid == 100 && $0.key.activityKind == .connection && $0.key.localPort == 8080
        }
        XCTAssertEqual(webConnection?.endpoints.count, 2)
        XCTAssertEqual(Set(webConnection?.endpoints.compactMap(\.socketState) ?? []), ["CLOSE_WAIT", "ESTABLISHED"])

        let udpListener = parsed.groups.first {
            $0.key.pid == 200 && $0.key.activityKind == .listener && $0.key.transport == .udp
        }
        XCTAssertEqual(udpListener?.key.localPort, 5353)
        XCTAssertEqual(udpListener?.endpoints.count, 2)

        let udpConnection = parsed.groups.first {
            $0.key.pid == 200 && $0.key.activityKind == .connection && $0.key.transport == .udp
        }
        XCTAssertEqual(udpConnection?.key.localPort, 50123)
        XCTAssertTrue(udpConnection?.endpoints.first?.hasRemoteEndpoint == true)
    }

    func testEndpointParserHandlesBracketedIPv6AndPortBounds() {
        XCTAssertEqual(EndpointParser.parse("[fe80::1]:1", state: nil)?.localPort, 1)
        XCTAssertEqual(EndpointParser.parse("*:65535", state: nil)?.localPort, 65_535)
        XCTAssertEqual(EndpointParser.parse("192.0.2.1:0", state: nil), nil)
        XCTAssertEqual(EndpointParser.parse("[::1]:65536", state: nil), nil)
        XCTAssertEqual(EndpointParser.parse("127.0.0.1:8080->", state: nil), nil)
        XCTAssertEqual(
            EndpointParser.parse("[::1]:40000->[2001:db8::2]:443", state: "established")?.rawValue,
            "[::1]:40000->[2001:db8::2]:443"
        )
    }

    func testStructuralOnlyOutputIsNotMalformed() {
        let parsed = LsofParser().parse(Data("\n\r\n\0".utf8))

        XCTAssertEqual(parsed.validRecords, 0)
        XCTAssertEqual(parsed.skippedRecords, 0)
        XCTAssertFalse(parsed.sawNonStructuralInput)
    }

    func testMalformedIncompleteUnknownAndInvalidUTF8RecordsAreSkippedIndividually() {
        var data = Data([112, 49, 50, 0, 99, 80, 0, 102, 49, 0, 80, 84, 67, 80, 0, 110, 42, 58, 48, 0])
        data.append(contentsOf: [10, 112, 50, 0, 99, 0xFF, 0xFE, 0, 102, 51, 0, 80, 85, 68, 80, 0, 110, 42, 58, 53, 51, 53, 51, 0])
        data.append(contentsOf: [10, 122, 117, 110, 107, 110, 111, 119, 110, 0])

        let parsed = LsofParser().parse(data)

        XCTAssertEqual(parsed.validRecords, 1)
        XCTAssertEqual(parsed.skippedRecords, 1)
        XCTAssertEqual(parsed.groups.count, 1)
        XCTAssertEqual(parsed.groups[0].processName, "��")
    }

    func testStructuralNewlinesAndOutOfOrderFieldsAreAccepted() {
        let output = nulFixture([
            "p300", "cdaemon", "f1", "n127.0.0.1:1234", "TST=listen", "zignored", "tIPv4", "PTcP"
        ])

        let parsed = LsofParser().parse(output)

        XCTAssertEqual(parsed.validRecords, 1)
        XCTAssertEqual(parsed.groups[0].key.activityKind, .listener)
        XCTAssertEqual(parsed.groups[0].key.transport, .tcp)
        XCTAssertEqual(parsed.groups[0].key.localPort, 1234)
    }

    func testInterfaceLoopbackEphemeralAndSamePortDifferentPIDRecordsRemainDistinct() {
        let output = nulFixture([
            "p11", "cBeta", "f1", "PTCP", "n127.0.0.1:1", "TST=LISTEN",
            "p12", "cAlpha", "f2", "PTCP", "n192.0.2.44:1", "TST=LISTEN",
            "p13", "cclient", "f3", "PTCP", "n192.0.2.44:49152->198.51.100.8:443", "TST=ESTABLISHED"
        ])

        let parsed = LsofParser().parse(output)

        XCTAssertEqual(parsed.validRecords, 3)
        XCTAssertEqual(parsed.groups.count, 3)
        XCTAssertEqual(
            Set(parsed.groups.map { "\($0.key.pid):\($0.key.localPort):\($0.key.activityKind.rawValue)" }),
            ["11:1:listener", "12:1:listener", "13:49152:connection"]
        )
    }

    func testMissingPIDProtocolEndpointAndCommandAreHandledIndividually() {
        let output = nulFixture([
            "p100", "calpha", "f1", "n*:1234", "TST=LISTEN",
            "f2", "PTCP", "TST=LISTEN",
            "pnot-a-pid", "cignored", "f3", "PTCP", "n*:1236", "TST=LISTEN",
            "p101", "f4", "PTCP", "n*:1235", "TST=LISTEN"
        ])

        let parsed = LsofParser().parse(output)

        XCTAssertEqual(parsed.validRecords, 1)
        XCTAssertEqual(parsed.skippedRecords, 3)
        XCTAssertEqual(parsed.groups.count, 1)
        XCTAssertEqual(parsed.groups[0].processName, "Unknown process")
        XCTAssertEqual(parsed.groups[0].key.pid, 101)
    }

    func testTCPAndUDPOnTheSamePortRemainSeparateRows() {
        let output = nulFixture([
            "p200", "cdual", "f1", "PTCP", "n*:5353", "TST=LISTEN",
            "f2", "PUDP", "n*:5353"
        ])

        let parsed = LsofParser().parse(output)

        XCTAssertEqual(parsed.validRecords, 2)
        XCTAssertEqual(parsed.groups.count, 2)
        XCTAssertEqual(Set(parsed.groups.map(\.key.transport)), [.tcp, .udp])
    }

    private var mixedFixture: Data {
        nulFixture([
            "p100", "cweb", "f3", "tIPv4", "PTCP", "n*:8080", "TST=LISTEN",
            "f4", "tIPv6", "PTCP", "n[::]:8080", "TST=LISTEN",
            "f5", "tIPv4", "PTCP", "n*:8080", "TST=LISTEN",
            "f6", "tIPv4", "PTCP", "n192.0.2.10:8080->198.51.100.20:443", "TST=ESTABLISHED",
            "f7", "tIPv4", "PTCP", "n192.0.2.10:8080->198.51.100.20:443", "TST=CLOSE_WAIT",
            "p200", "cdiscovery", "f8", "tIPv4", "PUDP", "n*:5353",
            "f9", "tIPv6", "PUDP", "n[::]:5353",
            "f10", "tIPv4", "PUDP", "n192.0.2.10:50123->198.51.100.40:5353"
        ])
    }
}

final class PortScannerTests: XCTestCase {
    func testScannerUsesExactCommandsAndEnrichesEachPIDOnce() async {
        let runner = StubLsofRunner(responses: [execution(stdout: LsofParserTestsFixture.mixed)])
        let inspector = StubInspector(
            identities: [
                100: identity(100, 10),
                200: identity(200, 20)
            ],
            names: [100: "web", 200: "discovery"]
        )
        let scanner = PortScanner(runner: runner, inspector: inspector)

        let outcome = await scanner.scan(generation: 7)

        guard case let .success(snapshot, diagnostics) = outcome else {
            return XCTFail("expected a successful scan")
        }
        XCTAssertEqual(snapshot.listeners.count, 2)
        XCTAssertEqual(snapshot.connections.count, 2)
        XCTAssertEqual(snapshot.listeners.map(\.localPort), [5353, 8080])
        XCTAssertEqual(snapshot.connections.map(\.localPort), [8080, 50123])
        XCTAssertEqual(diagnostics.validRecords, 8)
        let requestedArguments = await runner.arguments()
        XCTAssertEqual(requestedArguments, [PortScanner.normalArguments])
        XCTAssertEqual(inspector.callCount(for: 100), 1)
        XCTAssertEqual(inspector.callCount(for: 200), 1)
        XCTAssertEqual(snapshot.listeners.first(where: { $0.pid == 100 })?.identity, identity(100, 10))
    }

    func testDeveloperFocusedPolicyFiltersNoiseBeforeIdentityEnrichment() async {
        let output = nulFixture([
            "p100", "crapportd", "f1", "PUDP", "n*:3722",
            "p101", "cControlCenter", "f2", "PTCP", "n*:5000", "TST=LISTEN",
            "p102", "cmy-local-app", "f3", "PTCP", "n127.0.0.1:45678", "TST=LISTEN"
        ])
        let inspector = StubInspector(
            identities: [
                100: identity(100, 10),
                101: identity(101, 11),
                102: identity(102, 12)
            ]
        )
        let scanner = PortScanner(
            runner: StubLsofRunner(responses: [execution(stdout: output)]),
            inspector: inspector
        )

        let outcome = await scanner.scan(generation: 1)

        guard case let .success(snapshot, diagnostics) = outcome else {
            return XCTFail("expected a successful scan")
        }
        XCTAssertEqual(diagnostics.validRecords, 3)
        XCTAssertEqual(snapshot.listeners.map(\.localPort), [45678])
        XCTAssertEqual(inspector.callCount(for: 100), 0)
        XCTAssertEqual(inspector.callCount(for: 101), 0)
        XCTAssertEqual(inspector.callCount(for: 102), 1)
    }

    func testEmptyExitOneIsAValidEmptySnapshot() async {
        let runner = StubLsofRunner(responses: [execution(status: 1)])
        let scanner = PortScanner(runner: runner, inspector: StubInspector())

        let outcome = await scanner.scan(generation: 1)

        guard case let .success(snapshot, _) = outcome else {
            return XCTFail("expected exit 1 with no output to be an empty success")
        }
        XCTAssertEqual(snapshot, PortSnapshot.empty)
    }

    func testFailedScanDoesNotPublishMalformedPartialOutput() async {
        let runner = StubLsofRunner(responses: [execution(stdout: Data("garbage".utf8), status: 0)])
        let scanner = PortScanner(runner: runner, inspector: StubInspector())

        let outcome = await scanner.scan(generation: 1)

        guard case let .failure(error, diagnostics) = outcome else {
            return XCTFail("expected malformed output failure")
        }
        XCTAssertEqual(error, .malformedOutput)
        XCTAssertEqual(diagnostics.validRecords, 0)
    }

    func testTargetedValidationAcceptsParseableStatusOneOutput() async {
        let row = makeRow(pid: 100, port: 8080, name: "web")
        let runner = StubLsofRunner(responses: [execution(stdout: LsofParserTestsFixture.mixed, status: 1)])
        let scanner = PortScanner(
            runner: runner,
            inspector: StubInspector(identities: [100: identity(100, 10)])
        )

        let result = await scanner.validateSocket(for: row)

        XCTAssertEqual(result, .matched(processName: "web"))
        let requestedArguments = await runner.arguments()
        XCTAssertEqual(requestedArguments, [PortScanner.targetedArguments(pid: 100)])
    }

    func testTargetedMalformedOutputFailsClosed() async {
        let row = makeRow(pid: 100, port: 8080, name: "web")
        let runner = StubLsofRunner(responses: [execution(stdout: Data("garbage".utf8))])
        let scanner = PortScanner(
            runner: runner,
            inspector: StubInspector(identities: [100: identity(100, 10)])
        )

        let result = await scanner.validateSocket(for: row)

        XCTAssertEqual(result, .failed(.malformedOutput))
    }

    func testRunnerFailuresAndNonZeroStatusesMapToUserSafeFailures() async {
        let cases: [(LsofRunnerFailure?, Int32, Data, ScanFailure)] = [
            (.launchFailed, 0, Data(), .launchFailed),
            (.timedOut, 0, Data(), .timedOut),
            (.outputTooLarge(stream: .stdout), 0, Data(), .outputTooLarge(stream: .stdout)),
            (.readFailed, 0, Data(), .readFailed),
            (nil, 2, Data(), .nonZeroExit(status: 2)),
            (nil, 1, Data("Permission denied".utf8), .permissionDenied),
            (nil, 2, Data("Operation not permitted".utf8), .permissionDenied)
        ]

        for (runnerFailure, status, stderr, expectedFailure) in cases {
            let runner = StubLsofRunner(responses: [execution(stderr: stderr, status: status, failure: runnerFailure)])
            let scanner = PortScanner(runner: runner, inspector: StubInspector())

            let outcome = await scanner.scan(generation: 1)

            guard case let .failure(error, _) = outcome else {
                return XCTFail("expected \(expectedFailure), got \(outcome)")
            }
            XCTAssertEqual(error, expectedFailure)
        }
    }
}

final class LsofRunnerTests: XCTestCase {
    func testLaunchFailureIsReportedWithoutStartingAChild() async {
        let runner = LsofRunner(
            executableURL: URL(fileURLWithPath: "/definitely/not-a-real-porto-executable")
        )

        let result = await runner.run(arguments: [])

        XCTAssertEqual(result.failure, .launchFailed)
        XCTAssertNil(result.terminationStatus)
    }

    func testOutputLimitTerminatesTheRunnerOwnedChild() async throws {
        let executable = URL(fileURLWithPath: "/usr/bin/yes")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("yes is not installed")
        }
        let runner = LsofRunner(executableURL: executable, stdoutLimit: 1_024, timeout: .seconds(1))

        let result = await runner.run(arguments: [])

        XCTAssertEqual(result.failure, .outputTooLarge(stream: .stdout))
        XCTAssertLessThan(result.stdout.count, 1_024)
        XCTAssertFalse(result.wasCancelled)
    }

    func testCancellationTerminatesTheRunnerOwnedChild() async throws {
        let executable = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("sleep is not installed")
        }
        let runner = LsofRunner(executableURL: executable, timeout: .seconds(3))
        let task = Task {
            await runner.run(arguments: ["5"])
        }
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(result.wasCancelled)
    }

    func testExplicitRunnerCancellationIsReportedAsCancellation() async throws {
        let executable = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("sleep is not installed")
        }
        let runner = LsofRunner(executableURL: executable, timeout: .seconds(3))
        let task = Task {
            await runner.run(arguments: ["5"])
        }
        try await Task.sleep(for: .milliseconds(50))

        await runner.cancelActive()
        let result = await task.value

        XCTAssertEqual(result.failure, .cancelled)
        XCTAssertTrue(result.wasCancelled)
    }

    func testTimeoutTerminatesTheRunnerOwnedChild() async throws {
        let executable = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("sleep is not installed")
        }
        let runner = LsofRunner(executableURL: executable, timeout: .milliseconds(100))

        let result = await runner.run(arguments: ["5"])

        XCTAssertEqual(result.failure, .timedOut)
    }

    func testConcurrentRunReturnsBusyWithoutStartingASecondChild() async throws {
        let executable = URL(fileURLWithPath: "/bin/sleep")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("sleep is not installed")
        }
        let runner = LsofRunner(executableURL: executable, timeout: .seconds(2))
        let firstTask = Task {
            await runner.run(arguments: ["1"])
        }
        try await Task.sleep(for: .milliseconds(50))

        let secondResult = await runner.run(arguments: ["1"])
        let firstResult = await firstTask.value

        XCTAssertEqual(secondResult.failure, .busy)
        XCTAssertNil(firstResult.failure)
    }
}

@MainActor
final class PortMonitorTests: XCTestCase {
    func testOpenScansImmediatelyAndCloseStopsRefresh() async {
        let firstSnapshot = PortSnapshot(
            listeners: [makeRow(pid: 9, port: 8080)],
            connections: [makeRow(pid: 10, port: 443, activityKind: .connection)]
        )
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(snapshot: firstSnapshot, diagnostics: zeroDiagnostics),
            .failure(error: .timedOut, diagnostics: zeroDiagnostics)
        ])
        let monitor = PortMonitor(scanner: scanner, terminator: NoopTerminator(), ownPID: 999)

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        XCTAssertTrue(monitor.hasSnapshot)
        XCTAssertEqual(monitor.listenerRows, firstSnapshot.listeners)
        XCTAssertEqual(monitor.connectionRows, firstSnapshot.connections)
        XCTAssertEqual(monitor.allRows, [firstSnapshot.connections[0], firstSnapshot.listeners[0]])
        monitor.refresh()
        await waitUntil { await scanner.scanCount() == 2 }
        XCTAssertEqual(monitor.listenerRows, firstSnapshot.listeners)
        XCTAssertEqual(monitor.scanError, .timedOut)
        XCTAssertTrue(monitor.isStale)

        monitor.setPresented(false)
        XCTAssertFalse(monitor.isPopoverPresented)
    }

    func testBackgroundRefreshDoesNotSetManualRefreshState() async {
        let clock = ManualMonitorClock()
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(snapshot: .empty, diagnostics: zeroDiagnostics),
            .success(snapshot: .empty, diagnostics: zeroDiagnostics)
        ])
        let monitor = PortMonitor(
            scanner: scanner,
            terminator: NoopTerminator(),
            ownPID: 999,
            clock: clock
        )
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 && !monitor.isScanning }
        XCTAssertFalse(monitor.isManualRefreshing)

        await waitUntil { await clock.waitingCount() == 1 }
        await clock.advance()
        await waitUntil { await scanner.scanCount() == 2 && !monitor.isScanning }
        XCTAssertFalse(monitor.isManualRefreshing)
    }

    func testManualRefreshStateIsSeparateFromBackgroundScan() async {
        let scanner = BlockingMonitorScanner(snapshot: .empty)
        let monitor = PortMonitor(scanner: scanner, terminator: NoopTerminator(), ownPID: 999)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        XCTAssertTrue(monitor.isScanning)
        XCTAssertFalse(monitor.isManualRefreshing)

        monitor.refresh()
        XCTAssertTrue(monitor.isManualRefreshing)

        await scanner.releaseFirstScan()
        await waitUntil { await scanner.scanCount() == 2 && !monitor.isScanning }
        XCTAssertFalse(monitor.isManualRefreshing)
    }

    func testSuccessfulEmptyScanReplacesThePreviousSnapshot() async {
        let firstSnapshot = PortSnapshot(
            listeners: [makeRow(pid: 9, port: 8080)],
            connections: []
        )
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(snapshot: firstSnapshot, diagnostics: zeroDiagnostics),
            .success(snapshot: .empty, diagnostics: zeroDiagnostics)
        ])
        let monitor = PortMonitor(scanner: scanner, terminator: NoopTerminator(), ownPID: 999)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        XCTAssertEqual(monitor.listenerRows, firstSnapshot.listeners)

        monitor.refresh()
        await waitUntil { await scanner.scanCount() == 2 }

        XCTAssertTrue(monitor.hasSnapshot)
        XCTAssertTrue(monitor.listenerRows.isEmpty)
        XCTAssertTrue(monitor.connectionRows.isEmpty)
        XCTAssertNil(monitor.scanError)
    }

    func testInjectedClockRefreshesAfterTwoSecondsAndStopsWhenClosed() async {
        let clock = ManualMonitorClock()
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(snapshot: .empty, diagnostics: zeroDiagnostics),
            .success(snapshot: .empty, diagnostics: zeroDiagnostics),
            .success(snapshot: .empty, diagnostics: zeroDiagnostics)
        ])
        let monitor = PortMonitor(
            scanner: scanner,
            terminator: NoopTerminator(),
            ownPID: 999,
            clock: clock
        )

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        await waitUntil { await clock.waitingCount() == 1 }
        let requestedDurations = await clock.requestedDurations()
        XCTAssertEqual(requestedDurations, [.seconds(2)])

        await clock.advance()
        await waitUntil { await scanner.scanCount() == 2 }

        monitor.setPresented(false)
        let countWhenClosed = await scanner.scanCount()
        await clock.advance()
        try? await Task.sleep(for: .milliseconds(50))
        let countAfterClose = await scanner.scanCount()
        XCTAssertEqual(countAfterClose, countWhenClosed)
    }

    func testClosingCancelsAnInFlightScanWithoutStartingAnother() async {
        let scanner = CancellationAwareMonitorScanner()
        let monitor = PortMonitor(scanner: scanner, terminator: NoopTerminator(), ownPID: 999)

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        monitor.setPresented(false)

        await waitUntil {
            await scanner.cancellationCount() == 1 && !monitor.isScanning
        }
        let countAfterCancellation = await scanner.scanCount()
        XCTAssertEqual(countAfterCancellation, 1)
        XCTAssertNil(monitor.scanError)
    }

    func testCloseAndReopenSuppressesTheOlderScanResult() async {
        let oldSnapshot = PortSnapshot(
            listeners: [makeRow(pid: 9, port: 8080, name: "old")],
            connections: []
        )
        let newSnapshot = PortSnapshot(
            listeners: [makeRow(pid: 10, port: 9090, name: "new")],
            connections: []
        )
        let scanner = LateResultMonitorScanner(oldSnapshot: oldSnapshot, newSnapshot: newSnapshot)
        let monitor = PortMonitor(scanner: scanner, terminator: NoopTerminator(), ownPID: 999)

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }

        monitor.setPresented(false)
        monitor.setPresented(true)
        let countBeforeReleasingOldScan = await scanner.scanCount()
        XCTAssertEqual(countBeforeReleasingOldScan, 1)

        await scanner.releaseFirstScan()
        await waitUntil { await scanner.scanCount() == 2 }
        await waitUntil { monitor.listenerRows == newSnapshot.listeners }

        XCTAssertEqual(monitor.listenerRows, newSnapshot.listeners)
        XCTAssertNotEqual(monitor.listenerRows, oldSnapshot.listeners)
        monitor.setPresented(false)
    }

    func testRefreshBurstsCoalesceToOneFollowUpScan() async {
        let scanner = BlockingMonitorScanner(
            snapshot: PortSnapshot(listeners: [makeRow(pid: 9, port: 8080)], connections: [])
        )
        let monitor = PortMonitor(scanner: scanner, terminator: NoopTerminator(), ownPID: 999)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        for _ in 0..<20 {
            monitor.refresh()
        }
        let coalescedCount = await scanner.scanCount()
        XCTAssertEqual(coalescedCount, 1)

        await scanner.releaseFirstScan()
        await waitUntil { await scanner.scanCount() == 2 }
        let maximumConcurrentScans = await scanner.maximumConcurrentScans()
        XCTAssertEqual(maximumConcurrentScans, 1)
    }

    func testTerminationStateIsSharedAndBlocksOtherProcessActions() async {
        let sameProcessRows = [
            makeRow(pid: 42, port: 8080, name: "server"),
            makeRow(pid: 42, port: 8081, name: "server")
        ]
        let otherProcessRow = makeRow(pid: 43, port: 8082, name: "other")
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(
                snapshot: PortSnapshot(
                    listeners: sameProcessRows + [otherProcessRow],
                    connections: []
                ),
                diagnostics: zeroDiagnostics
            )
        ])
        let terminator = BlockingTerminator(outcome: .exited)
        let monitor = PortMonitor(scanner: scanner, terminator: terminator, ownPID: 999)
        defer { monitor.setPresented(false) }

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        monitor.requestStop(for: sameProcessRows[0])
        await waitUntil { await terminator.stopCount() == 1 }

        XCTAssertEqual(monitor.terminationState(for: sameProcessRows[0]), .inProgress)
        XCTAssertEqual(monitor.terminationState(for: sameProcessRows[1]), .inProgress)
        XCTAssertTrue(monitor.isTerminationDisabled(for: otherProcessRow))

        monitor.requestStop(for: otherProcessRow)
        let attemptedStops = await terminator.stopCount()
        XCTAssertEqual(attemptedStops, 1)

        await terminator.release()
        await waitUntil { monitor.listenerRows.count == 1 }
        XCTAssertEqual(monitor.listenerRows.first?.pid, 43)
        XCTAssertNil(monitor.terminationState(for: sameProcessRows[0]))
        XCTAssertNil(monitor.terminationState(for: sameProcessRows[1]))
    }

    func testClosingPopoverDoesNotAbandonUserRequestedTermination() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(
                snapshot: PortSnapshot(listeners: [row], connections: []),
                diagnostics: zeroDiagnostics
            )
        ])
        let terminator = BlockingTerminator(outcome: .forceKillAvailable)
        let monitor = PortMonitor(scanner: scanner, terminator: terminator, ownPID: 999)

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        monitor.requestStop(for: row)
        await waitUntil { await terminator.stopCount() == 1 }

        monitor.setPresented(false)
        await terminator.release()
        await waitUntil { monitor.terminationState(for: row) == .forceKillAvailable }

        XCTAssertEqual(monitor.terminationState(for: row), .forceKillAvailable)
        XCTAssertFalse(monitor.isPopoverPresented)
    }

    func testTerminationSuspendsRefreshUntilTheWorkflowSettles() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let clock = ManualMonitorClock()
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(
                snapshot: PortSnapshot(listeners: [row], connections: []),
                diagnostics: zeroDiagnostics
            ),
            .success(snapshot: .empty, diagnostics: zeroDiagnostics)
        ])
        let terminator = BlockingTerminator(outcome: .forceKillAvailable)
        let monitor = PortMonitor(
            scanner: scanner,
            terminator: terminator,
            ownPID: 999,
            clock: clock
        )

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        await waitUntil { await clock.waitingCount() == 1 }
        monitor.requestStop(for: row)
        await waitUntil { await terminator.stopCount() == 1 }

        await clock.advance()
        try? await Task.sleep(for: .milliseconds(30))
        let countDuringTermination = await scanner.scanCount()
        XCTAssertEqual(countDuringTermination, 1)

        await terminator.release()
        await waitUntil { await scanner.scanCount() == 2 }
        await waitUntil { monitor.listenerRows.isEmpty }
        XCTAssertTrue(monitor.listenerRows.isEmpty)
        monitor.setPresented(false)
    }

    func testProcessReplacementClearsForceKillPromptAndEligibility() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let replacement = makeRow(pid: 43, port: 8080, name: "replacement")
        let scanner = SequencedMonitorScanner(outcomes: [
            .success(
                snapshot: PortSnapshot(listeners: [row], connections: []),
                diagnostics: zeroDiagnostics
            ),
            .success(
                snapshot: PortSnapshot(listeners: [row], connections: []),
                diagnostics: zeroDiagnostics
            ),
            .success(
                snapshot: PortSnapshot(listeners: [replacement], connections: []),
                diagnostics: zeroDiagnostics
            )
        ])
        let terminator = BlockingTerminator(outcome: .forceKillAvailable)
        let monitor = PortMonitor(scanner: scanner, terminator: terminator, ownPID: 999)

        monitor.setPresented(true)
        await waitUntil { await scanner.scanCount() == 1 }
        monitor.requestStop(for: row)
        await waitUntil { await terminator.stopCount() == 1 }
        await terminator.release()
        await waitUntil { await scanner.scanCount() == 2 }
        await waitUntil { monitor.terminationState(for: row) == .forceKillAvailable }

        monitor.requestForceKill(for: row)
        XCTAssertNotNil(monitor.forceKillPrompt)
        monitor.refresh()
        await waitUntil { await scanner.scanCount() == 3 }
        await waitUntil { monitor.listenerRows == [replacement] }

        XCTAssertNil(monitor.forceKillPrompt)
        XCTAssertNil(monitor.terminationState(for: row))
        monitor.setPresented(false)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true")
    }
}

@MainActor
final class MenuPresentationObserverTests: XCTestCase {
    func testPresentationRequiresVisibleKeyActiveNonMiniaturizedWindow() {
        XCTAssertTrue(
            MenuPresentationObserver.isPresented(
                windowIsVisible: true,
                windowIsKey: true,
                windowIsMiniaturized: false,
                applicationIsActive: true
            )
        )

        let dismissalConditions: [(Bool, Bool, Bool, Bool)] = [
            (false, true, false, true),
            (true, false, false, true),
            (true, true, true, true),
            (true, true, false, false)
        ]
        for (isVisible, isKey, isMiniaturized, isActive) in dismissalConditions {
            XCTAssertFalse(
                MenuPresentationObserver.isPresented(
                    windowIsVisible: isVisible,
                    windowIsKey: isKey,
                    windowIsMiniaturized: isMiniaturized,
                    applicationIsActive: isActive
                )
            )
        }
    }
}

final class ProcessTerminatorTests: XCTestCase {
    func testMatchingIdentitySendsOnlySIGTERMAndRecognizesExit() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let inspector = StubInspector(
            identities: [42: identity(42, 1)],
            names: [42: "server"],
            sequences: [42: [identity(42, 1), identity(42, 1), nil]]
        )
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: inspector,
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(signaler.signals(), [SIGTERM])
    }

    func testAlreadyExitedProcessSendsNoSignal() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: StubInspector(),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .exited)
        XCTAssertTrue(signaler.signals().isEmpty)
    }

    func testChangedProcessNameSendsNoSignal() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "replacement")),
            inspector: StubInspector(
                identities: [42: identity(42, 1)],
                names: [42: "server"]
            ),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .failed(.staleTarget))
        XCTAssertTrue(signaler.signals().isEmpty)
    }

    func testDisappearedSocketSendsNoSignal() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .socketMissing),
            inspector: StubInspector(identities: [42: identity(42, 1)]),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .failed(.staleTarget))
        XCTAssertTrue(signaler.signals().isEmpty)
    }

    func testPIDReuseAfterSocketValidationSendsNoSignal() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let inspector = StubInspector(
            identities: [42: identity(42, 1)],
            names: [42: "server"],
            sequences: [42: [identity(42, 1), identity(42, 2)]]
        )
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: inspector,
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .failed(.staleTarget))
        XCTAssertTrue(signaler.signals().isEmpty)
    }

    func testGraceTimeoutOnlyMakesForceKillAvailable() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let inspector = StubInspector(identities: [42: identity(42, 1)], names: [42: "server"])
        let signaler = StubSignalSender()
        let scanner = StubPortScanner(validation: .matched(processName: "server"))
        let terminator = ProcessTerminator(
            scanner: scanner,
            inspector: inspector,
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .forceKillAvailable)
        XCTAssertEqual(signaler.signals(), [SIGTERM])
        XCTAssertEqual(scanner.validationCount(), 1)
    }

    func testForceKillRequiresFreshValidationAndIsExplicitlySeparate() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let inspector = StubInspector(
            identities: [42: identity(42, 1)],
            names: [42: "server"],
            sequences: [42: [identity(42, 1), identity(42, 1), nil]]
        )
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: inspector,
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.forceKill(row: row)

        XCTAssertEqual(outcome, .exited)
        XCTAssertEqual(signaler.signals(), [SIGKILL])
    }

    func testPermissionFailureKeepsTheProcess() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let inspector = StubInspector(
            identities: [42: identity(42, 1)],
            names: [42: "server"]
        )
        let signaler = StubSignalSender(results: [SIGTERM: .failed(errno: EPERM, description: "Operation not permitted")])
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: inspector,
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .failed(.permissionDenied))
        XCTAssertEqual(signaler.signals(), [SIGTERM])
    }

    func testEACCESAndESRCHAreMappedWithoutKillingAnotherProcess() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let cases: [(Int32, TerminationOutcome)] = [
            (EACCES, .failed(.permissionDenied)),
            (ESRCH, .exited)
        ]
        for (errno, expected) in cases {
            let signaler = StubSignalSender(
                results: [SIGTERM: .failed(errno: errno, description: "synthetic errno")]
            )
            let terminator = ProcessTerminator(
                scanner: StubPortScanner(validation: .matched(processName: "server")),
                inspector: StubInspector(
                    identities: [42: identity(42, 1)],
                    names: [42: "server"]
                ),
                signalSender: signaler,
                clock: ImmediateClock(),
                ownPID: 999
            )

            let outcome = await terminator.stop(row: row)

            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(signaler.signals(), [SIGTERM])
        }
    }

    func testUnexpectedSignalErrorPreservesCapturedDescription() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender(
            results: [SIGTERM: .failed(errno: 9_999, description: "synthetic signal failure")]
        )
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: StubInspector(
                identities: [42: identity(42, 1)],
                names: [42: "server"]
            ),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(
            outcome,
            .failed(.system(code: 9_999, description: "synthetic signal failure"))
        )
    }

    func testForceKillStillAliveReportsFailureAfterItsBoundedPoll() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: StubInspector(
                identities: [42: identity(42, 1)],
                names: [42: "server"]
            ),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.forceKill(row: row)

        XCTAssertEqual(outcome, .failed(.stillAlive))
        XCTAssertEqual(signaler.signals(), [SIGKILL])
    }

    func testForceKillSocketMismatchSendsNoSIGKILL() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .socketMissing),
            inspector: StubInspector(identities: [42: identity(42, 1)]),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 999
        )

        let outcome = await terminator.forceKill(row: row)

        XCTAssertEqual(outcome, .failed(.staleTarget))
        XCTAssertTrue(signaler.signals().isEmpty)
    }

    func testPopoverTerminationCancellationStopsPollingWithoutEscalation() async {
        let row = makeRow(pid: 42, port: 8080, name: "server")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "server")),
            inspector: StubInspector(
                identities: [42: identity(42, 1)],
                names: [42: "server"]
            ),
            signalSender: signaler,
            clock: CancellingClock(),
            ownPID: 999
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(signaler.signals(), [SIGTERM])
    }

    func testOwnPIDIsNeverActionable() async {
        let row = makeRow(pid: 42, port: 8080, name: "Porto")
        let signaler = StubSignalSender()
        let terminator = ProcessTerminator(
            scanner: StubPortScanner(validation: .matched(processName: "Porto")),
            inspector: StubInspector(),
            signalSender: signaler,
            clock: ImmediateClock(),
            ownPID: 42
        )

        let outcome = await terminator.stop(row: row)

        XCTAssertEqual(outcome, .failed(.staleTarget))
        XCTAssertTrue(signaler.signals().isEmpty)
    }
}

final class RealProcessIntegrationTests: XCTestCase {
    func testDisposableCurrentUserTCPServerCanBeGracefullyStopped() async throws {
        let server = try DisposableRubyServer(ignoreSIGTERM: false)
        defer { server.cleanup() }

        let scanner = PortScanner(runner: LsofRunner(), inspector: DarwinProcessInspector())
        let outcome = await scanner.scan(generation: 1)
        guard case let .success(snapshot, _) = outcome,
              let row = snapshot.listeners.first(where: { $0.pid == server.process.processIdentifier && $0.transport == .tcp }) else {
            return XCTFail("disposable server was not discovered")
        }
        XCTAssertFalse(snapshot.allRows.contains { $0.localPort == 3722 })
        let validation = await scanner.validateSocket(for: row)
        XCTAssertEqual(validation, .matched(processName: row.processName))
        let terminator = ProcessTerminator(
            scanner: scanner,
            inspector: DarwinProcessInspector(),
            signalSender: DarwinProcessSignalSender(),
            ownPID: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        let result = await terminator.stop(row: row)

        XCTAssertEqual(result, .exited)
        XCTAssertFalse(server.process.isRunning)
    }

    func testDisposableSIGTERMIgnoringServerRequiresExplicitForceKill() async throws {
        let server = try DisposableRubyServer(ignoreSIGTERM: true)
        defer { server.cleanup() }

        let scanner = PortScanner(runner: LsofRunner(), inspector: DarwinProcessInspector())
        let outcome = await scanner.scan(generation: 1)
        guard case let .success(snapshot, _) = outcome,
              let row = snapshot.listeners.first(where: { $0.pid == server.process.processIdentifier && $0.transport == .tcp }) else {
            return XCTFail("disposable server was not discovered")
        }
        let validation = await scanner.validateSocket(for: row)
        XCTAssertEqual(validation, .matched(processName: row.processName))
        let terminator = ProcessTerminator(
            scanner: scanner,
            inspector: DarwinProcessInspector(),
            signalSender: DarwinProcessSignalSender(),
            ownPID: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        let gracefulResult = await terminator.stop(row: row)
        XCTAssertEqual(gracefulResult, .forceKillAvailable)
        XCTAssertTrue(server.process.isRunning)

        let forceResult = await terminator.forceKill(row: row)
        XCTAssertEqual(forceResult, .exited)
        XCTAssertFalse(server.process.isRunning)
    }
}

private enum LsofParserTestsFixture {
    static let mixed = nulFixture([
        "p100", "cweb", "f3", "tIPv4", "PTCP", "n*:8080", "TST=LISTEN",
        "f4", "tIPv6", "PTCP", "n[::]:8080", "TST=LISTEN",
        "f5", "tIPv4", "PTCP", "n*:8080", "TST=LISTEN",
        "f6", "tIPv4", "PTCP", "n192.0.2.10:8080->198.51.100.20:443", "TST=ESTABLISHED",
        "f7", "tIPv4", "PTCP", "n192.0.2.10:8080->198.51.100.20:443", "TST=CLOSE_WAIT",
        "p200", "cdiscovery", "f8", "tIPv4", "PUDP", "n*:5353",
        "f9", "tIPv6", "PUDP", "n[::]:5353",
        "f10", "tIPv4", "PUDP", "n192.0.2.10:50123->198.51.100.40:5353"
    ])
}

private func nulFixture(_ fields: [String]) -> Data {
    var data = Data(fields.joined(separator: "\0\n").utf8)
    data.append(0)
    return data
}

private func execution(
    stdout: Data = Data(),
    stderr: Data = Data(),
    status: Int32 = 0,
    failure: LsofRunnerFailure? = nil
) -> LsofExecutionResult {
    LsofExecutionResult(
        stdout: stdout,
        stderr: stderr,
        terminationStatus: status,
        terminationReason: .exit,
        failure: failure,
        durationMilliseconds: 1
    )
}

private func identity(_ pid: Int32, _ seconds: UInt64) -> ProcessIdentity {
    ProcessIdentity(pid: pid, startTimeSeconds: seconds, startTimeMicroseconds: 1)
}

private func makeRow(
    pid: Int32,
    port: Int,
    name: String = "process",
    activityKind: PortActivityKind = .listener
) -> PortProcess {
    let processIdentity = identity(pid, 1)
    return PortProcess(
        id: PortProcess.makeID(
            activityKind: activityKind,
            transport: .tcp,
            localPort: port,
            pid: pid,
            identity: processIdentity,
            scanGeneration: 1
        ),
        identity: processIdentity,
        pid: pid,
        localPort: port,
        transport: .tcp,
        processName: name,
        endpoints: [Endpoint(rawValue: "*:8080", localPort: port, hasRemoteEndpoint: false, socketState: "LISTEN")],
        activityKind: activityKind
    )
}

private let zeroDiagnostics = ScanDiagnostics(
    stdoutBytes: 0,
    stderrBytes: 0,
    validRecords: 0,
    skippedRecords: 0,
    durationMilliseconds: 0
)

private actor StubLsofRunner: LsofRunning {
    private var responses: [LsofExecutionResult]
    private var requestedArguments: [[String]] = []

    init(responses: [LsofExecutionResult]) {
        self.responses = responses
    }

    func run(arguments: [String]) async -> LsofExecutionResult {
        requestedArguments.append(arguments)
        return responses.isEmpty ? execution(failure: .cancelled) : responses.removeFirst()
    }

    func cancelActive() async {}

    func arguments() -> [[String]] {
        requestedArguments
    }
}

private final class StubInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [Int32: ProcessIdentity]
    private var names: [Int32: String]
    private var sequences: [Int32: [ProcessIdentity?]]
    private var calls: [Int32: Int] = [:]

    init(
        identities: [Int32: ProcessIdentity] = [:],
        names: [Int32: String] = [:],
        sequences: [Int32: [ProcessIdentity?]] = [:]
    ) {
        self.identities = identities
        self.names = names
        self.sequences = sequences
    }

    func identity(for pid: Int32) -> ProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        calls[pid, default: 0] += 1
        if var sequence = sequences[pid], !sequence.isEmpty {
            let result = sequence.removeFirst()
            sequences[pid] = sequence
            return result
        }
        return identities[pid]
    }

    func processName(for pid: Int32) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[pid]
    }

    func callCount(for pid: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return calls[pid, default: 0]
    }
}

private final class StubSignalSender: ProcessSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var sentSignals: [Int32] = []
    private let results: [Int32: SignalSendResult]

    init(results: [Int32: SignalSendResult] = [:]) {
        self.results = results
    }

    func send(signal: Int32, to pid: Int32) -> SignalSendResult {
        lock.lock()
        sentSignals.append(signal)
        lock.unlock()
        return results[signal] ?? .sent
    }

    func signals() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return sentSignals
    }
}

private struct ImmediateClock: MonitorSleeping {
    func sleep(for duration: Duration) async throws {}
}

private actor ManualMonitorClock: MonitorSleeping {
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                durations.append(duration)
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(continuation)
                }
            }
        }, onCancel: {
            Task { await self.cancelPendingSleeps() }
        })
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func waitingCount() -> Int {
        waiters.count
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    private func cancelPendingSleeps() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}

private struct CancellingClock: MonitorSleeping {
    func sleep(for duration: Duration) async throws {
        throw CancellationError()
    }
}

private final class StubPortScanner: PortScanning, @unchecked Sendable {
    private let lock = NSLock()
    private let validation: SocketValidationResult
    private var validations = 0

    init(validation: SocketValidationResult) {
        self.validation = validation
    }

    func scan(generation: UInt64) async -> ScanOutcome {
        .success(snapshot: .empty, diagnostics: zeroDiagnostics)
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        recordValidation()
        return validation
    }

    func cancelActiveWork() async {}

    func validationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return validations
    }

    private func recordValidation() {
        lock.lock()
        validations += 1
        lock.unlock()
    }
}

private struct NoopTerminator: ProcessTerminating {
    func stop(row: PortProcess) async -> TerminationOutcome { .cancelled }
    func forceKill(row: PortProcess) async -> TerminationOutcome { .cancelled }
}

private actor SequencedMonitorScanner: PortScanning {
    private var outcomes: [ScanOutcome]
    private var calls = 0

    init(outcomes: [ScanOutcome]) {
        self.outcomes = outcomes
    }

    func scan(generation: UInt64) async -> ScanOutcome {
        calls += 1
        return outcomes.isEmpty ? .cancelled : outcomes.removeFirst()
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        .socketMissing
    }

    func cancelActiveWork() async {}

    func scanCount() -> Int { calls }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private actor BlockingMonitorScanner: PortScanning {
    private let firstScanGate = AsyncGate()
    private let snapshot: PortSnapshot
    private var calls = 0
    private var activeScans = 0
    private var maximumActiveScans = 0

    init(snapshot: PortSnapshot) {
        self.snapshot = snapshot
    }

    func scan(generation: UInt64) async -> ScanOutcome {
        calls += 1
        activeScans += 1
        maximumActiveScans = max(maximumActiveScans, activeScans)
        if calls == 1 {
            await firstScanGate.wait()
        }
        activeScans -= 1
        return .success(snapshot: snapshot, diagnostics: zeroDiagnostics)
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        .socketMissing
    }

    func cancelActiveWork() async {}

    func releaseFirstScan() async {
        await firstScanGate.open()
    }

    func scanCount() -> Int { calls }

    func maximumConcurrentScans() -> Int { maximumActiveScans }
}

private actor CancellationAwareMonitorScanner: PortScanning {
    private var calls = 0
    private var cancellations = 0
    private var cancellationRequested = false
    private var waiter: CheckedContinuation<Void, Never>?

    func scan(generation: UInt64) async -> ScanOutcome {
        calls += 1
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if cancellationRequested {
                    continuation.resume()
                } else {
                    waiter = continuation
                }
            }
        }, onCancel: {
            Task { await self.cancelPendingScan() }
        })
        return Task.isCancelled ? .cancelled : .success(snapshot: .empty, diagnostics: zeroDiagnostics)
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        .socketMissing
    }

    func cancelActiveWork() async {}

    func scanCount() -> Int { calls }

    func cancellationCount() -> Int { cancellations }

    private func cancelPendingScan() {
        cancellations += 1
        cancellationRequested = true
        waiter?.resume()
        waiter = nil
    }
}

private actor LateResultMonitorScanner: PortScanning {
    private let oldSnapshot: PortSnapshot
    private let newSnapshot: PortSnapshot
    private let firstScanGate = AsyncGate()
    private var calls = 0

    init(oldSnapshot: PortSnapshot, newSnapshot: PortSnapshot) {
        self.oldSnapshot = oldSnapshot
        self.newSnapshot = newSnapshot
    }

    func scan(generation: UInt64) async -> ScanOutcome {
        calls += 1
        if calls == 1 {
            await firstScanGate.wait()
            return .success(snapshot: oldSnapshot, diagnostics: zeroDiagnostics)
        }
        return .success(snapshot: newSnapshot, diagnostics: zeroDiagnostics)
    }

    func validateSocket(for row: PortProcess) async -> SocketValidationResult {
        .socketMissing
    }

    func cancelActiveWork() async {}

    func releaseFirstScan() async {
        await firstScanGate.open()
    }

    func scanCount() -> Int { calls }
}

private actor BlockingTerminator: ProcessTerminating {
    private let gate = AsyncGate()
    private let outcome: TerminationOutcome
    private var calls = 0

    init(outcome: TerminationOutcome) {
        self.outcome = outcome
    }

    func stop(row: PortProcess) async -> TerminationOutcome {
        calls += 1
        await gate.wait()
        return outcome
    }

    func forceKill(row: PortProcess) async -> TerminationOutcome {
        .cancelled
    }

    func release() async {
        await gate.open()
    }

    func stopCount() -> Int { calls }
}

private final class DisposableRubyServer: @unchecked Sendable {
    let process: Process
    let port: Int

    init(ignoreSIGTERM: Bool) throws {
        let executableCandidates = ["/opt/homebrew/bin/ruby", "/usr/bin/ruby"]
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Ruby is not installed")
        }
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let script = ignoreSIGTERM
            ? "require 'socket'; s=TCPServer.new('127.0.0.1',0); STDOUT.sync=true; puts s.addr[1]; trap('TERM') {}; loop { sleep 1 }"
            : "require 'socket'; s=TCPServer.new('127.0.0.1',0); STDOUT.sync=true; puts s.addr[1]; loop { sleep 1 }"
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        try process.run()
        var line = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 1), !chunk.isEmpty {
            if chunk[chunk.startIndex] == 10 { break }
            line.append(chunk[chunk.startIndex])
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            cleanupProcess(process)
            throw NSError(domain: "PortoTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ruby server did not report a port"])
        }
        self.port = port
    }

    func cleanup() {
        cleanupProcess(process)
    }
}

private func cleanupProcess(_ process: Process) {
    if process.isRunning {
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()
}
