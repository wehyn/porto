import Foundation
import XCTest
@testable import Porto

final class RemoteProcessTerminatorTests: XCTestCase {
    func testRemoteRowWithPIDButMissingSocketIdentityIsNotActionable() {
        let row = makeRemoteRow(pid: 42, socketIdentity: nil)

        XCTAssertFalse(row.isActionable)
    }

    func testRemoteRowWithPIDAndSocketIdentityIsActionable() {
        let row = makeRemoteRow(pid: 42, socketIdentity: "cookie")

        XCTAssertTrue(row.isActionable)
    }

    func testStopRevalidatesBeforeTermAndNeverUsesLocalSignals() async throws {
        let profile = RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=42,fd=3)) ino:7 sk:cookie\n".utf8)
        let parser = RemotePortOutputParser()
        guard case let .success(parsed) = parser.parse(output, targetID: targetID),
              let row = parsed.snapshot.listeners.first else { return XCTFail("expected row") }
        let runner = TerminatorRunner(scanOutputs: [output, Data()])
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let stopResult = await terminator.stop(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(stopResult, .exited)
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true), .signal(.term, pid: 42), .scan(includeDockerMetadata: true)])
    }

    func testStopStopsPollingAtInjectedGraceDeadline() async throws {
        let profile = RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=42,fd=3)) ino:7 sk:cookie\n".utf8)
        let runner = TerminatorRunner(scanOutputs: Array(repeating: output, count: 30))
        let timeline = TestTimeline()
        let terminator = RemoteProcessTerminator(
            profile: profile,
            runner: runner,
            clock: AdvancingClock(timeline: timeline),
            now: { timeline.now() }
        )
        guard case let .success(parsed) = RemotePortOutputParser().parse(output, targetID: targetID),
              let row = parsed.snapshot.listeners.first else { return XCTFail("expected row") }

        let result = await terminator.stop(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .failed(.revalidationFailed))
        XCTAssertEqual(operations.filter { if case .scan = $0 { true } else { false } }.count, 20)
    }

    func testStopDoesNotOfferForceKillWhenPollingTimesOutBeforeRevalidation() async throws {
        let profile = testProfile()
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=42,fd=3)) ino:7 sk:cookie\n".utf8)
        let row = try XCTUnwrap(parsedRow(output, targetID: targetID))
        let timeline = TestTimeline()
        let runner = TerminatorRunner(scanOutputs: [output])
        let terminator = RemoteProcessTerminator(
            profile: profile,
            runner: runner,
            clock: DeadlineAdvancingClock(timeline: timeline),
            now: { timeline.now() }
        )

        let result = await terminator.stop(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .failed(.revalidationFailed))
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true), .signal(.term, pid: 42)])
    }

    func testForceKillFailsClosedWhenPollingTimesOutBeforeRevalidation() async throws {
        let profile = testProfile()
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=42,fd=3)) ino:7 sk:cookie\n".utf8)
        let row = try XCTUnwrap(parsedRow(output, targetID: targetID))
        let timeline = TestTimeline()
        let runner = TerminatorRunner(scanOutputs: [output, output])
        let terminator = RemoteProcessTerminator(
            profile: profile,
            runner: runner,
            clock: DeadlineAdvancingClock(timeline: timeline),
            now: { timeline.now() }
        )

        let result = await terminator.forceKill(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .failed(.revalidationFailed))
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true), .signal(.kill, pid: 42)])
    }

    func testStopRejectsSamePIDAndNameWithDifferentSocketIdentity() async throws {
        let profile = RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let original = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=42,fd=3)) ino:7 sk:original\n".utf8)
        let replacement = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=42,fd=3)) ino:8 sk:replacement\n".utf8)
        let row = try XCTUnwrap(parsedRow(original, targetID: targetID))
        let runner = TerminatorRunner(scanOutputs: [replacement])
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let result = await terminator.stop(row: row)
        let operations = await runner.operations()
        XCTAssertEqual(result, .failed(.staleTarget))
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true)])
    }

    func testDockerStopUsesContainerSignalForPIDLessMultiPortRow() async throws {
        let profile = RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("""
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:one
        tcp LISTEN 0 128 0.0.0.0:8443 0.0.0.0:* ino:8 sk:two
        __PORTO_DOCKER__
        0123456789ab\tweb\t0.0.0.0:8080->8080/tcp, 0.0.0.0:8443->8443/tcp
        """.utf8)
        let row: PortProcess
        guard case let .success(parsed) = RemotePortOutputParser().parse(output, targetID: targetID),
              let parsedRow = parsed.dockerPorts.applying(to: parsed.snapshot).listeners.first else {
            return XCTFail("expected Docker row")
        }
        row = PortProcess(
            id: parsedRow.id, origin: parsedRow.origin, localPorts: parsedRow.localPorts,
            transports: parsedRow.transports, processName: parsedRow.processName,
            endpoints: parsedRow.endpoints, activityKind: parsedRow.activityKind,
            remoteSocketIdentity: parsedRow.remoteSocketIdentity,
            source: parsedRow.source, controlTarget: parsedRow.controlTarget,
            isDockerPublished: parsedRow.isDockerPublished
        )
        let runner = TerminatorRunner(scanOutputs: [output, Data()])
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        XCTAssertNil(row.pid)
        XCTAssertTrue(row.isActionable)
        let result = await terminator.stop(row: row)
        let operations = await runner.operations()
        XCTAssertEqual(result, .exited)
        XCTAssertEqual(operations, [
            .scan(includeDockerMetadata: true), .signalContainer(.term, containerID: "0123456789ab"), .scan(includeDockerMetadata: true)
        ])
    }

    func testDockerMetadataLossWithSurvivingSocketDoesNotLookExitedOrSignalHostPID() async throws {
        let profile = testProfile()
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let dockerOutput = dockerOutput(port: 8080)
        let socketOnlyOutput = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:one\n".utf8)
        let row = try XCTUnwrap(parsedRow(dockerOutput, targetID: targetID, applyingDocker: true))
        let runner = TerminatorRunner(scanOutputs: [socketOnlyOutput])
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let result = await terminator.stop(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .failed(.revalidationFailed))
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true)])
    }

    func testDockerMetadataLossDuringPostTermPollingKeepsForceKillAvailable() async throws {
        let profile = testProfile()
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let dockerOutput = dockerOutput(port: 8080)
        let socketOnlyOutput = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:one\n".utf8)
        let row = try XCTUnwrap(parsedRow(dockerOutput, targetID: targetID, applyingDocker: true))
        let runner = TerminatorRunner(scanOutputs: [dockerOutput, socketOnlyOutput])
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let result = await terminator.stop(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .forceKillAvailable)
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true), .signalContainer(.term, containerID: "0123456789ab"), .scan(includeDockerMetadata: true)])
    }

    func testForceKillWithMissingDockerMetadataNeverSignalsAHostPID() async throws {
        let profile = testProfile()
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let dockerOutput = dockerOutput(port: 8080)
        let socketOnlyOutput = Data("tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:one\n".utf8)
        let row = try XCTUnwrap(parsedRow(dockerOutput, targetID: targetID, applyingDocker: true))
        let runner = TerminatorRunner(scanOutputs: [socketOnlyOutput])
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let result = await terminator.forceKill(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .failed(.revalidationFailed))
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true)])
    }

    func testDockerPermissionFailureIsClearAndNeverFallsBackToHostPID() async throws {
        let profile = RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("""
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:one
        __PORTO_DOCKER__
        0123456789ab\tweb\t0.0.0.0:8080->8080/tcp
        """.utf8)
        guard case let .success(parsed) = RemotePortOutputParser().parse(output, targetID: targetID),
              let row = parsed.dockerPorts.applying(to: parsed.snapshot).listeners.first else {
            return XCTFail("expected Docker row")
        }
        let signalFailure = SSHCommandExecutionResult(
            stdout: Data(),
            stderr: Data("permission denied while trying to connect to the Docker daemon socket".utf8),
            terminationStatus: 1,
            terminationReason: .exit,
            failure: nil,
            durationMilliseconds: 1
        )
        let runner = TerminatorRunner(scanOutputs: [output], signalResult: signalFailure)
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let result = await terminator.stop(row: row)
        let operations = await runner.operations()

        XCTAssertEqual(result, .failed(.dockerPermissionDenied))
        XCTAssertEqual(operations, [
            .scan(includeDockerMetadata: true), .signalContainer(.term, containerID: "0123456789ab")
        ])
    }

    func testDockerUnavailableFailureIsClear() async throws {
        let profile = RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
        let targetID = PortTargetID(rawValue: "remote:\(profile.id.uuidString)")
        let output = Data("""
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:one
        __PORTO_DOCKER__
        0123456789ab\tweb\t0.0.0.0:8080->8080/tcp
        """.utf8)
        guard case let .success(parsed) = RemotePortOutputParser().parse(output, targetID: targetID),
              let row = parsed.dockerPorts.applying(to: parsed.snapshot).listeners.first else {
            return XCTFail("expected Docker row")
        }
        let signalFailure = SSHCommandExecutionResult(
            stdout: Data(),
            stderr: Data("docker: command not found".utf8),
            terminationStatus: 127,
            terminationReason: .exit,
            failure: nil,
            durationMilliseconds: 1
        )
        let runner = TerminatorRunner(scanOutputs: [output], signalResult: signalFailure)
        let terminator = RemoteProcessTerminator(profile: profile, runner: runner, clock: ImmediateClock())

        let result = await terminator.stop(row: row)

        XCTAssertEqual(result, .failed(.dockerUnavailable))
    }

    private func parsedRow(_ output: Data, targetID: PortTargetID, applyingDocker: Bool = false) -> PortProcess? {
        guard case let .success(parsed) = RemotePortOutputParser().parse(output, targetID: targetID) else { return nil }
        return (applyingDocker ? parsed.dockerPorts.applying(to: parsed.snapshot) : parsed.snapshot).listeners.first
    }

    private func testProfile() -> RemoteServerProfile {
        RemoteServerProfile(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            displayName: "Test", host: "example.com", username: "tester"
        )
    }

    private func dockerOutput(port: Int) -> Data {
        Data("tcp LISTEN 0 128 0.0.0.0:\(port) 0.0.0.0:* ino:7 sk:one\n__PORTO_DOCKER__\n0123456789ab\tweb\t0.0.0.0:\(port)->\(port)/tcp\n".utf8)
    }

    private func makeRemoteRow(pid: Int32?, socketIdentity: String?) -> PortProcess {
        PortProcess(
            id: "remote-row",
            origin: .remote(targetID: PortTargetID(rawValue: "remote:test"), pid: pid),
            localPort: 8080,
            transport: .tcp,
            processName: "app",
            endpoints: [],
            activityKind: .listener,
            remoteSocketIdentity: socketIdentity
        )
    }
}

private struct ImmediateClock: MonitorSleeping {
    func sleep(for duration: Duration) async throws {}
}

private final class TestTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    func now() -> ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    func advance(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        instant += duration
    }
}

private struct AdvancingClock: MonitorSleeping {
    let timeline: TestTimeline

    func sleep(for duration: Duration) async throws {
        timeline.advance(duration)
    }
}

private struct DeadlineAdvancingClock: MonitorSleeping {
    let timeline: TestTimeline

    func sleep(for duration: Duration) async throws {
        timeline.advance(.seconds(3))
    }
}

private actor TerminatorRunner: SSHCommandRunning {
    var scanOutputs: [Data]
    let signalResult: SSHCommandExecutionResult
    var seen: [RemoteSSHOperation] = []

    init(scanOutputs: [Data], signalResult: SSHCommandExecutionResult? = nil) {
        self.scanOutputs = scanOutputs
        self.signalResult = signalResult ?? SSHCommandExecutionResult(
            stdout: Data(), stderr: Data(), terminationStatus: 0,
            terminationReason: .exit, failure: nil, durationMilliseconds: 1
        )
    }

    func run(profile: RemoteServerProfile, operation: RemoteSSHOperation) async -> SSHCommandExecutionResult {
        seen.append(operation)
        let stdout: Data
        switch operation {
        case .scan: stdout = scanOutputs.isEmpty ? Data() : scanOutputs.removeFirst()
        case .signal, .signalContainer:
            return signalResult
        }
        return SSHCommandExecutionResult(stdout: stdout, stderr: Data(), terminationStatus: 0,
                                         terminationReason: .exit, failure: nil, durationMilliseconds: 1)
    }

    func cancelActive() async {}
    func operations() -> [RemoteSSHOperation] { seen }
}
