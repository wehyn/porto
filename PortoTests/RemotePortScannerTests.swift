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

    func testRemotePolicyHidesCommonServicePortsButKeepsCustomPorts() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* ino:22
        udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* ino:53
        tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* ino:80
        tcp LISTEN 0 128 0.0.0.0:137 0.0.0.0:* ino:137
        tcp ESTAB 0 0 192.0.2.10:443 198.51.100.20:50000 ino:443
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"app\",pid=8080,fd=3)) ino:8080
        """
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(host).id, sessionGeneration: 2, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [8080])
        XCTAssertTrue(snapshot.snapshot.connections.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.validRecords, 6)
    }

    func testDockerPublishedPortReplacesUnknownProcessBeforeFiltering() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* ino:22
        tcp LISTEN 0 128 0.0.0.0:53 0.0.0.0:* ino:53
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:8080
        tcp ESTAB 0 0 192.0.2.10:8444 198.51.100.20:50000 ino:8444
        __PORTO_DOCKER__
        2b4f94051c6e\tpihole\t0.0.0.0:53->53/tcp
        f4bacc4f39f8\tmoneyprinterturbo-api\t0.0.0.0:8080->8080/tcp
        """
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(host).id, sessionGeneration: 3, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [53, 8080])
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["Docker · pihole", "Docker · moneyprinterturbo-api"])
        XCTAssertTrue(snapshot.snapshot.connections.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.validRecords, 4)
    }

    func testDockerLabelsOnlyMatchingListenerAddressAndNeverConnections() async throws {
        let output = """
        tcp LISTEN 0 128 127.0.0.1:8080 127.0.0.1:* ino:1
        tcp LISTEN 0 128 192.0.2.10:8080 192.0.2.10:* users:(("other",pid=2,fd=3)) ino:2
        tcp ESTAB 0 0 192.0.2.10:8080 198.51.100.20:50000 users:(("client",pid=3,fd=4)) ino:3
        __PORTO_DOCKER__
        2b4f94051c6e\tweb\t127.0.0.1:8080->8080/tcp
        """
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(targetID: PortTarget.ssh(host).id, sessionGeneration: 4, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["Docker · web", "other"])
        XCTAssertEqual(snapshot.snapshot.connections.map(\.processName), ["client"])
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

final class DockerPortParserTests: XCTestCase {
    func testParsesPublishedIPv4IPv6UDPAndRangesButSkipsInternalPorts() {
        let output = """
        one\tweb\t0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp
        two\tgame\t0.0.0.0:19132->19132/udp, 0.0.0.0:25565-25566->25565-25566/tcp
        three\tdatabase\t5432/tcp
        """

        let catalog = DockerPortParser().parse(output)

        XCTAssertEqual(catalog.containerNames(localPort: 8080, transport: .tcp), ["web"])
        XCTAssertEqual(catalog.containerNames(localPort: 19132, transport: .udp), ["game"])
        XCTAssertTrue(catalog.contains(localPort: 25565, transport: .tcp))
        XCTAssertTrue(catalog.contains(localPort: 25566, transport: .tcp))
        XCTAssertFalse(catalog.contains(localPort: 5432, transport: .tcp))
    }

    func testParsesPublishedHostPortWithoutAddress() {
        let catalog = DockerPortParser().parse("one\tweb\t8080->8080/tcp")

        XCTAssertEqual(catalog.containerNames(localPort: 8080, transport: .tcp), ["web"])
    }

    func testMalformedRowsAndUnsafeNamesAreIgnored() {
        let output = """
        malformed
        one\t\t0.0.0.0:8080->8080/tcp
        two\tgood\t0.0.0.0:not-a-port->8080/tcp
        three\tgood\t0.0.0.0:8081->8081/sctp
        four\tgood\t0.0.0.0:8082->8082/tcp
        """

        let catalog = DockerPortParser().parse(output)

        XCTAssertFalse(catalog.contains(localPort: 8080, transport: .tcp))
        XCTAssertFalse(catalog.contains(localPort: 8081, transport: .tcp))
        XCTAssertTrue(catalog.contains(localPort: 8082, transport: .tcp))
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
