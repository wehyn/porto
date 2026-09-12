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

    func testDockerIPv4IPv6AndTCPUDPListenersCoalesceIntoOneLogicalRow() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:53 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 [::]:53 [::]:* ino:2 sk:two
        tcp LISTEN 0 128 [::]:53 [::]:* ino:2 sk:duplicate
        udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* ino:3 sk:three
        udp UNCONN 0 0 [::]:53 [::]:* ino:4 sk:four
        __PORTO_DOCKER__
        2b4f94051c6e\tpihole\t0.0.0.0:53->53/tcp, [::]:53->53/tcp, 0.0.0.0:53->53/udp, [::]:53->53/udp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 1)
        let row = try XCTUnwrap(snapshot.snapshot.listeners.first)
        XCTAssertEqual(row.processName, "Docker · pihole")
        XCTAssertEqual(row.localPort, 53)
        XCTAssertEqual(row.localPorts, [53])
        XCTAssertEqual(row.transports, [.tcp, .udp])
        XCTAssertEqual(row.endpoints.count, 4)
        XCTAssertEqual(Set(row.endpoints.compactMap(\.socketState)), ["LISTEN", "UNCONN"])
        XCTAssertEqual(snapshot.diagnostics.validRecords, 5)
    }

    func testDockerSameContainerPortsCoalesceIntoOneRowWithOrderedPorts() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:53 0.0.0.0:* ino:1 sk:tcp53-v4
        tcp LISTEN 0 128 [::]:53 [::]:* ino:2 sk:tcp53-v6
        udp UNCONN 0 0 0.0.0.0:53 0.0.0.0:* ino:3 sk:udp53-v4
        udp UNCONN 0 0 [::]:53 [::]:* ino:4 sk:udp53-v6
        tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* ino:5 sk:tcp80-v4
        tcp LISTEN 0 128 [::]:80 [::]:* ino:6 sk:tcp80-v6
        __PORTO_DOCKER__
        2b4f94051c6e\tpihole\t0.0.0.0:53->53/tcp, [::]:53->53/tcp, 0.0.0.0:53->53/udp, [::]:53->53/udp, 0.0.0.0:80->80/tcp, [::]:80->80/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 1)
        let row = try XCTUnwrap(snapshot.snapshot.listeners.first)
        XCTAssertEqual(row.processName, "Docker · pihole")
        XCTAssertEqual(row.localPort, 53)
        XCTAssertEqual(row.localPorts, [53, 80])
        XCTAssertEqual(row.transports, [.tcp, .udp])
        XCTAssertEqual(row.endpoints.count, 6)
        XCTAssertEqual(snapshot.diagnostics.validRecords, 6)
    }

    func testScreenshotDockerPortsCollapseAcrossIPv4AndIPv6() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* ino:80-v4 sk:80-v4
        tcp LISTEN 0 128 [::]:80 [::]:* ino:80-v6 sk:80-v6
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1455-v4 sk:1455-v4
        tcp LISTEN 0 128 [::]:1455 [::]:* ino:1455-v6 sk:1455-v6
        tcp LISTEN 0 128 0.0.0.0:2283 0.0.0.0:* ino:2283-v4 sk:2283-v4
        tcp LISTEN 0 128 [::]:2283 [::]:* ino:2283-v6 sk:2283-v6
        tcp LISTEN 0 128 0.0.0.0:6565 0.0.0.0:* ino:6565-v4 sk:6565-v4
        tcp LISTEN 0 128 [::]:6565 [::]:* ino:6565-v6 sk:6565-v6
        __PORTO_DOCKER__
        pihole-id\tpihole\t0.0.0.0:80->80/tcp, [::]:80->80/tcp
        omniroute-id\tomniroute\t0.0.0.0:1455->1455/tcp, [::]:1455->1455/tcp
        immich-id\timmich_server\t0.0.0.0:2283->2283/tcp, [::]:2283->2283/tcp
        filebrowser-id\tfilebrowser-filebrowser-1\t0.0.0.0:6565->80/tcp, [::]:6565->80/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [80, 1455, 2283, 6565])
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), [
            "Docker · pihole",
            "Docker · omniroute",
            "Docker · immich_server",
            "Docker · filebrowser-filebrowser-1"
        ])
        XCTAssertTrue(snapshot.snapshot.listeners.allSatisfy { $0.endpoints.count == 2 && $0.transports == [.tcp] })
        XCTAssertEqual(snapshot.diagnostics.validRecords, 8)
    }

    func testDockerLogicalRowIDIsStableAcrossAddressFamiliesAndInputOrder() async throws {
        let bothFamilies = """
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 [::]:1455 [::]:* ino:2 sk:two
        __PORTO_DOCKER__
        container-a\tomniroute\t0.0.0.0:1455->1455/tcp, [::]:1455->1455/tcp
        """
        let reversedFamilies = """
        tcp LISTEN 0 128 [::]:1455 [::]:* ino:2 sk:two
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        __PORTO_DOCKER__
        container-a\tomniroute\t[::]:1455->1455/tcp, 0.0.0.0:1455->1455/tcp
        """
        let singleFamily = """
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        __PORTO_DOCKER__
        container-a\tomniroute\t0.0.0.0:1455->1455/tcp
        """
        let twoPorts = """
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 0.0.0.0:2283 0.0.0.0:* ino:3 sk:three
        __PORTO_DOCKER__
        container-a\tomniroute\t0.0.0.0:1455->1455/tcp, 0.0.0.0:2283->2283/tcp
        """

        let firstSnapshot = try await scan(bothFamilies)
        let secondSnapshot = try await scan(reversedFamilies)
        let singleFamilySnapshot = try await scan(singleFamily)
        let twoPortsSnapshot = try await scan(twoPorts)
        let first = try XCTUnwrap(firstSnapshot.snapshot.listeners.first)
        let second = try XCTUnwrap(secondSnapshot.snapshot.listeners.first)
        let singleFamilyRow = try XCTUnwrap(singleFamilySnapshot.snapshot.listeners.first)
        let twoPortsRow = try XCTUnwrap(twoPortsSnapshot.snapshot.listeners.first)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, singleFamilyRow.id)
        XCTAssertEqual(first.id, twoPortsRow.id)
        XCTAssertEqual(twoPortsRow.localPorts, [1455, 2283])
        XCTAssertEqual(first, second)
    }

    func testDifferentDockerContainersOnTheSamePortRemainSeparate() async throws {
        let output = """
        tcp LISTEN 0 128 127.0.0.1:8080 127.0.0.1:* ino:1 sk:one
        tcp LISTEN 0 128 192.0.2.10:8080 192.0.2.10:* ino:2 sk:two
        __PORTO_DOCKER__
        container-a\tsame-name\t127.0.0.1:8080->8080/tcp
        container-b\tsame-name\t192.0.2.10:8080->8080/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 2)
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["Docker · same-name", "Docker · same-name"])
        XCTAssertNotEqual(snapshot.snapshot.listeners[0].id, snapshot.snapshot.listeners[1].id)
    }

    func testRowsWithoutUsableDockerIDsAreLabeledButNotCoalesced() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 [::]:8080 [::]:* ino:2 sk:two
        __PORTO_DOCKER__
        \tweb\t0.0.0.0:8080->8080/tcp, [::]:8080->8080/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 2)
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["Docker · web", "Docker · web"])
    }

    func testDockerMixedUsableAndMissingIDsRemainAtSocketGranularity() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 [::]:8080 [::]:* ino:2 sk:two
        tcp LISTEN 0 128 0.0.0.0:9090 0.0.0.0:* ino:3 sk:three
        __PORTO_DOCKER__
        known-id\tweb\t8080->8080/tcp
        \tweb\t8080->8080/tcp
        known-id\tweb\t9090->9090/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 3)
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [8080, 8080, 9090])
        XCTAssertEqual(snapshot.snapshot.listeners.filter { $0.localPort == 8080 }.map(\.localPorts), [[8080], [8080]])
        XCTAssertEqual(snapshot.snapshot.listeners.last?.localPorts, [9090])
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

    private func scan(_ output: String, sessionGeneration: UInt64 = 1) async throws -> TargetedPortSnapshot {
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(host: host, runner: runner)
        let request = PortScanRequest(
            targetID: PortTarget.ssh(host).id,
            sessionGeneration: sessionGeneration,
            scanGeneration: 1,
            trigger: .manual
        )

        let outcome = await scanner.scan(request)
        guard case let .success(snapshot) = outcome else {
            throw NSError(domain: "RemotePortScannerTests", code: 1)
        }
        return snapshot
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
