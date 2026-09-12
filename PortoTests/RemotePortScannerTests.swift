import Foundation
import XCTest
@testable import Porto

final class RemotePortScannerTests: XCTestCase {
    private let host = SSHHost(alias: "prod")

    func testSuccessfulRemoteOutputProducesReadOnlyTargetedRows() async throws {
        let output = "tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"nginx\",pid=42,fd=3)) ino:7 sk:cookie\n"
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(host).id, sessionGeneration: 9, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.targetID, request.targetID)
        XCTAssertEqual(snapshot.sessionGeneration, request.sessionGeneration)
        let row = try XCTUnwrap(snapshot.snapshot.listeners.first)
        XCTAssertEqual(row.processName, "nginx")
        XCTAssertEqual(row.pid, 42)
        XCTAssertFalse(row.isActionable)
        XCTAssertTrue(row.isRemote)
        let aliases = await runner.aliases()
        XCTAssertEqual(aliases, ["prod"])
    }

    func testStatus255UnknownTextRemainsGenericTransportFailure() async {
        let runner = StubSSHCommandRunner(result: execution(stderr: Data("ssh: unknown failure\n".utf8), status: 255))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(host).id, sessionGeneration: 1, scanGeneration: 1, trigger: .presentation)

        let outcome = await scanner.scan(request)

        guard case let .failure(_, _, error, _) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .remote(.nonZeroExit(status: 255)))
    }

    func testDiagnosticFailureMappingNeverExposesRawStderr() async {
        let runner = StubSSHCommandRunner(result: execution(stderr: Data("prod-user@private.example: Permission denied (publickey).\n".utf8), status: 255))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(host).id, sessionGeneration: 1, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .failure(_, _, error, _) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .remote(.authenticationFailed))
        XCTAssertFalse(error.userMessage.contains("private.example"))
        XCTAssertFalse(error.userMessage.contains("prod-user"))
    }

    func testTargetMismatchDoesNotInvokeRunner() async {
        let runner = StubSSHCommandRunner(result: execution(status: 0))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(SSHHost(alias: "other")).id, sessionGeneration: 1, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case .failure = outcome else { return XCTFail("expected failure") }
        let aliases = await runner.aliases()
        XCTAssertTrue(aliases.isEmpty)
    }

    private func execution(stdout: Data = Data(), stderr: Data = Data(), status: Int32?) -> SSHCommandExecutionResult {
        SSHCommandExecutionResult(
            stdout: stdout,
            stderr: stderr,
            terminationStatus: status,
            terminationReason: status == nil ? nil : .exit,
            failure: nil,
            durationMilliseconds: 1
        )
    }
}

private actor StubSSHCommandRunner: SSHCommandRunning {
    private let result: SSHCommandExecutionResult
    private var requestedAliases: [String] = []

    init(result: SSHCommandExecutionResult) { self.result = result }

    func run(alias: String) async -> SSHCommandExecutionResult {
        requestedAliases.append(alias)
        return result
    }

    func cancelActive() async {}
    func aliases() -> [String] { requestedAliases }
}
