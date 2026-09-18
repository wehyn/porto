import Foundation
import XCTest
@testable import Porto

final class RemotePortScannerTests: XCTestCase {
    private let profile = RemoteServerProfile(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        displayName: "Production Linux", host: "prod.example.com", username: "wayne", port: 22
    )

    private var targetID: PortTargetID { PortTargetID(rawValue: "remote:\(profile.id.uuidString)") }

    func testSuccessfulRemoteOutputProducesActionableTargetedRows() async throws {
        let output = "tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"nginx\",pid=42,fd=3)) ino:7 sk:cookie\n"
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 9, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.targetID, request.targetID)
        XCTAssertEqual(snapshot.sessionGeneration, request.sessionGeneration)
        let row = try XCTUnwrap(snapshot.snapshot.listeners.first)
        XCTAssertEqual(row.processName, "nginx")
        XCTAssertEqual(row.pid, 42)
        XCTAssertTrue(row.isActionable)
        XCTAssertTrue(row.isRemote)
        XCTAssertEqual(row.source, .remoteProcess)
        XCTAssertEqual(row.controlTarget, .remoteProcess(targetID: targetID, pid: 42))
        let operations = await runner.operations()
        XCTAssertEqual(operations, [.scan(includeDockerMetadata: true)])
    }

    func testPresentationThenScheduledSocketScanReusesDockerLabelsWithinThirtySeconds() async throws {
        let fullOutput = dockerOutput(name: "web")
        let socketOutput = socketOutput(processName: "ss-owner")
        let clock = TestInstantBox()
        let runner = SequencedStubSSHCommandRunner(results: [
            execution(stdout: Data(fullOutput.utf8), status: 0),
            execution(stdout: Data(socketOutput.utf8), status: 0)
        ])
        let scanner = RemotePortScanner(profile: profile, runner: runner, now: { clock.value })

        let first = await scanner.scan(request(trigger: .presentation))
        clock.advance(by: .seconds(29))
        let second = await scanner.scan(request(trigger: .scheduled, generation: 2))

        let operations = await runner.operations()
        XCTAssertEqual(operations, [
            .scan(includeDockerMetadata: true), .scan(includeDockerMetadata: false)
        ])
        XCTAssertEqual(try XCTUnwrap(success(first)).snapshot.listeners.first?.processName, "web")
        XCTAssertEqual(try XCTUnwrap(success(second)).snapshot.listeners.first?.processName, "web")
    }

    func testExpiryAndManualTriggerForceFreshDockerMetadata() async throws {
        let clock = TestInstantBox()
        let runner = SequencedStubSSHCommandRunner(results: [
            execution(stdout: Data(dockerOutput(name: "first").utf8), status: 0),
            execution(stdout: Data(socketOutput(processName: "socket").utf8), status: 0),
            execution(stdout: Data(dockerOutput(name: "second").utf8), status: 0)
        ])
        let scanner = RemotePortScanner(profile: profile, runner: runner, now: { clock.value })

        _ = await scanner.scan(request(trigger: .presentation))
        clock.advance(by: .seconds(30))
        _ = await scanner.scan(request(trigger: .scheduled, generation: 2))
        _ = await scanner.scan(request(trigger: .manual, generation: 3))

        let operations = await runner.operations()
        XCTAssertEqual(operations, [
            .scan(includeDockerMetadata: true), .scan(includeDockerMetadata: true),
            .scan(includeDockerMetadata: true)
        ])
    }

    func testFailedSocketScanDoesNotReplaceCachedMetadata() async throws {
        let runner = SequencedStubSSHCommandRunner(results: [
            execution(stdout: Data(dockerOutput(name: "web").utf8), status: 0),
            execution(stderr: Data("temporary failure".utf8), status: 1),
            execution(stdout: Data(socketOutput(processName: "socket").utf8), status: 0)
        ])
        let scanner = RemotePortScanner(profile: profile, runner: runner)

        let initial = await scanner.scan(request(trigger: .presentation))
        let failed = await scanner.scan(request(trigger: .scheduled, generation: 2))
        let recovered = await scanner.scan(request(trigger: .scheduled, generation: 3))

        guard case .failure = failed else { return XCTFail("expected scheduled socket failure") }
        XCTAssertEqual(try XCTUnwrap(success(initial)).snapshot.listeners.first?.processName, "web")
        XCTAssertEqual(try XCTUnwrap(success(recovered)).snapshot.listeners.first?.processName, "web")
        let operations = await runner.operations()
        XCTAssertEqual(operations, [
            .scan(includeDockerMetadata: true), .scan(includeDockerMetadata: false),
            .scan(includeDockerMetadata: false)
        ])
    }

    func testFailedDockerMetadataDoesNotEraseLastSuccessfulCatalog() async throws {
        let runner = SequencedStubSSHCommandRunner(results: [
            execution(stdout: Data(dockerOutput(name: "web").utf8), status: 0),
            execution(stdout: Data(dockerFailureOutput().utf8), status: 0)
        ])
        let scanner = RemotePortScanner(profile: profile, runner: runner)

        _ = await scanner.scan(request(trigger: .presentation))
        let failedMetadata = await scanner.scan(request(trigger: .manual, generation: 2))

        let row = try XCTUnwrap(success(failedMetadata)?.snapshot.listeners.first)
        XCTAssertEqual(row.processName, "web")
        XCTAssertTrue(row.isDockerContainer)
        let operations = await runner.operations()
        XCTAssertEqual(operations, [
            .scan(includeDockerMetadata: true), .scan(includeDockerMetadata: true)
        ])
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
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 2, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [8080])
        XCTAssertTrue(snapshot.snapshot.connections.isEmpty)
        XCTAssertEqual(snapshot.revalidationSnapshot?.listeners.map(\.localPort), [22, 53, 80, 137, 8080])
        XCTAssertEqual(snapshot.revalidationSnapshot?.listeners.first(where: { $0.localPort == 8080 })?.id,
                       snapshot.snapshot.listeners.first?.id)
        XCTAssertEqual(snapshot.diagnostics.validRecords, 6)
    }

    func testSameProcessListenerPortsGroupWithAllTransportsAndSocketIdentities() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:38832 0.0.0.0:* users:((\"tailscaled\",pid=317,fd=3)) ino:38832 sk:tcp38832
        udp UNCONN 0 0 0.0.0.0:41641 0.0.0.0:* users:((\"tailscaled\",pid=317,fd=4)) ino:41641 sk:udp41641
        udp UNCONN 0 0 0.0.0.0:49361 0.0.0.0:* users:((\"tailscaled\",pid=317,fd=5)) ino:49361 sk:udp49361
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 1)
        let row = try XCTUnwrap(snapshot.snapshot.listeners.first)
        XCTAssertEqual(row.processName, "tailscaled")
        XCTAssertEqual(row.pid, 317)
        XCTAssertEqual(row.localPorts, [38832, 41641, 49361])
        XCTAssertEqual(row.transports, [.tcp, .udp])
        XCTAssertEqual(row.endpoints.map(\.rawValue), [
            "0.0.0.0:38832->0.0.0.0:*",
            "0.0.0.0:41641->0.0.0.0:*",
            "0.0.0.0:49361->0.0.0.0:*"
        ])
        XCTAssertEqual(row.remoteSocketIdentity, "sk:tcp38832,sk:udp41641,sk:udp49361")
    }

    func testSameProcessConnectionsGroupIntoOneVisibleConnection() async throws {
        let output = """
        tcp ESTAB 0 0 192.0.2.10:41641 198.51.100.20:50000 users:((\"tailscaled\",pid=317,fd=6)) ino:60001 sk:conn-one
        tcp ESTAB 0 0 192.0.2.10:41642 198.51.100.21:50001 users:((\"tailscaled\",pid=317,fd=7)) ino:60002 sk:conn-two
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.connections.count, 1)
        let row = try XCTUnwrap(snapshot.snapshot.connections.first)
        XCTAssertEqual(row.processName, "tailscaled")
        XCTAssertEqual(row.pid, 317)
        XCTAssertEqual(row.localPorts, [41641, 41642])
        XCTAssertEqual(row.remoteSocketIdentity, "sk:conn-one,sk:conn-two")
    }

    func testSameNameDifferentPIDsRemainSeparateProcessRows() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:9001 0.0.0.0:* users:((\"worker\",pid=101,fd=3)) ino:1 sk:one
        tcp LISTEN 0 128 0.0.0.0:9002 0.0.0.0:* users:((\"worker\",pid=202,fd=3)) ino:2 sk:two
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 2)
        XCTAssertEqual(Set(snapshot.snapshot.listeners.map(\.pid)), [101, 202])
        XCTAssertNotEqual(snapshot.snapshot.listeners[0].id, snapshot.snapshot.listeners[1].id)
    }

    func testRevalidationSnapshotRetainsOwnerlessRowsHiddenFromTheUI() async throws {
        let output = "tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:7 sk:cookie\n"
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 2, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertTrue(snapshot.snapshot.listeners.isEmpty)
        XCTAssertEqual(snapshot.revalidationSnapshot?.listeners.map(\.localPort), [8080])
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
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 3, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [53, 8080])
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["pihole", "moneyprinterturbo-api"])
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.source), [.dockerContainer(containerID: "2b4f94051c6e"), .dockerContainer(containerID: "f4bacc4f39f8")])
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
        XCTAssertEqual(row.processName, "pihole")
        XCTAssertEqual(row.controlTarget, .remoteDocker(targetID: targetID, containerID: "2b4f94051c6e"))
        XCTAssertEqual(row.source, .dockerContainer(containerID: "2b4f94051c6e"))
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
        XCTAssertEqual(row.processName, "pihole")
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
        aaaaaaaaaaaa\tpihole\t0.0.0.0:80->80/tcp, [::]:80->80/tcp
        bbbbbbbbbbbb\tomniroute\t0.0.0.0:1455->1455/tcp, [::]:1455->1455/tcp
        cccccccccccc\timmich_server\t0.0.0.0:2283->2283/tcp, [::]:2283->2283/tcp
        dddddddddddd\tfilebrowser-filebrowser-1\t0.0.0.0:6565->80/tcp, [::]:6565->80/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.map(\.localPort), [80, 1455, 2283, 6565])
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), [
            "pihole",
            "omniroute",
            "immich_server",
            "filebrowser-filebrowser-1"
        ])
        XCTAssertTrue(snapshot.snapshot.listeners.allSatisfy { $0.endpoints.count == 2 && $0.transports == [.tcp] })
        XCTAssertEqual(snapshot.diagnostics.validRecords, 8)
    }

    func testDockerLogicalRowIDIsStableAcrossAddressFamiliesAndInputOrder() async throws {
        let bothFamilies = """
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 [::]:1455 [::]:* ino:2 sk:two
        __PORTO_DOCKER__
        aaaaaaaaaaaa\tomniroute\t0.0.0.0:1455->1455/tcp, [::]:1455->1455/tcp
        """
        let reversedFamilies = """
        tcp LISTEN 0 128 [::]:1455 [::]:* ino:2 sk:two
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        __PORTO_DOCKER__
        aaaaaaaaaaaa\tomniroute\t[::]:1455->1455/tcp, 0.0.0.0:1455->1455/tcp
        """
        let singleFamily = """
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        __PORTO_DOCKER__
        aaaaaaaaaaaa\tomniroute\t0.0.0.0:1455->1455/tcp
        """
        let twoPorts = """
        tcp LISTEN 0 128 0.0.0.0:1455 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 0.0.0.0:2283 0.0.0.0:* ino:3 sk:three
        __PORTO_DOCKER__
        aaaaaaaaaaaa\tomniroute\t0.0.0.0:1455->1455/tcp, 0.0.0.0:2283->2283/tcp
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
        aaaaaaaaaaaa\tsame-name\t127.0.0.1:8080->8080/tcp
        bbbbbbbbbbbb\tsame-name\t192.0.2.10:8080->8080/tcp
        """

        let snapshot = try await scan(output)

        XCTAssertEqual(snapshot.snapshot.listeners.count, 2)
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["same-name", "same-name"])
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
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["web", "web"])
        XCTAssertTrue(snapshot.snapshot.listeners.allSatisfy {
            if case .dockerContainer(containerID: nil) = $0.source { return $0.controlTarget == .none }
            return false
        })
    }

    func testDockerMixedUsableAndMissingIDsRemainAtSocketGranularity() async throws {
        let output = """
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* ino:1 sk:one
        tcp LISTEN 0 128 [::]:8080 [::]:* ino:2 sk:two
        tcp LISTEN 0 128 0.0.0.0:9090 0.0.0.0:* ino:3 sk:three
        __PORTO_DOCKER__
        aaaaaaaaaaaa\tweb\t8080->8080/tcp
        \tweb\t8080->8080/tcp
        aaaaaaaaaaaa\tweb\t9090->9090/tcp
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
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 4, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .success(snapshot) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(snapshot.snapshot.listeners.map(\.processName), ["web", "other"])
        XCTAssertEqual(snapshot.snapshot.connections.map(\.processName), ["client"])
    }

    func testStatus255UnknownTextRemainsGenericTransportFailure() async {
        let runner = StubSSHCommandRunner(result: execution(stderr: Data("ssh: unknown failure\n".utf8), status: 255))
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 1, scanGeneration: 1, trigger: .presentation)

        let outcome = await scanner.scan(request)

        guard case let .failure(_, _, error, _) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .remote(.nonZeroExit(status: 255)))
    }

    func testDiagnosticFailureMappingNeverExposesRawStderr() async {
        let runner = StubSSHCommandRunner(result: execution(stderr: Data("prod-user@private.example: Permission denied (publickey).\n".utf8), status: 255))
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: targetID, sessionGeneration: 1, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case let .failure(_, _, error, _) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .remote(.authenticationFailed))
        XCTAssertFalse(error.userMessage.contains("private.example"))
        XCTAssertFalse(error.userMessage.contains("prod-user"))
    }

    func testTargetMismatchDoesNotInvokeRunner() async {
        let runner = StubSSHCommandRunner(result: execution(status: 0))
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(targetID: PortTargetID(rawValue: "remote:other"), sessionGeneration: 1, scanGeneration: 1, trigger: .manual)

        let outcome = await scanner.scan(request)

        guard case .failure = outcome else { return XCTFail("expected failure") }
        let operations = await runner.operations()
        XCTAssertTrue(operations.isEmpty)
    }

    private func scan(_ output: String, sessionGeneration: UInt64 = 1) async throws -> TargetedPortSnapshot {
        let runner = StubSSHCommandRunner(result: execution(stdout: Data(output.utf8), status: 0))
        let scanner = RemotePortScanner(profile: profile, runner: runner)
        let request = PortScanRequest(
            targetID: targetID,
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

    private func request(trigger: ScanTrigger, generation: UInt64 = 1) -> PortScanRequest {
        PortScanRequest(
            targetID: targetID,
            sessionGeneration: generation,
            scanGeneration: generation,
            trigger: trigger
        )
    }

    private func success(_ outcome: PortScanOutcome) -> TargetedPortSnapshot? {
        guard case let .success(snapshot) = outcome else { return nil }
        return snapshot
    }

    private func socketOutput(processName: String) -> String {
        "tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"\(processName)\",pid=42,fd=3)) ino:7 sk:cookie\n"
    }

    private func dockerOutput(name: String) -> String {
        socketOutput(processName: "host") + "__PORTO_DOCKER__\n0123456789ab\t\(name)\t0.0.0.0:8080->8080/tcp\n"
    }

    private func dockerFailureOutput() -> String {
        socketOutput(processName: "host") + "__PORTO_DOCKER__\n__PORTO_DOCKER_STATUS__1\n"
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

    func testContainerIDsAcceptOnlyLowercaseHexDockerLengths() {
        XCTAssertEqual(DockerContainerID.validated("0123456789ab"), "0123456789ab")
        XCTAssertEqual(DockerContainerID.validated(String(repeating: "a", count: 64))?.count, 64)
        XCTAssertNil(DockerContainerID.validated("short"))
        XCTAssertNil(DockerContainerID.validated("0123456789AB"))
        XCTAssertNil(DockerContainerID.validated("0123456789ab!"))
        XCTAssertNil(DockerContainerID.validated(String(repeating: "a", count: 65)))
    }
}

private actor StubSSHCommandRunner: SSHCommandRunning {
    private let result: SSHCommandExecutionResult
    private var requestedOperations: [RemoteSSHOperation] = []

    init(result: SSHCommandExecutionResult) { self.result = result }

    func run(profile: RemoteServerProfile, operation: RemoteSSHOperation) async -> SSHCommandExecutionResult {
        requestedOperations.append(operation)
        return result
    }

    func cancelActive() async {}
    func operations() -> [RemoteSSHOperation] { requestedOperations }
}

private actor SequencedStubSSHCommandRunner: SSHCommandRunning {
    private var results: [SSHCommandExecutionResult]
    private var requestedOperations: [RemoteSSHOperation] = []

    init(results: [SSHCommandExecutionResult]) {
        self.results = results
    }

    func run(profile: RemoteServerProfile, operation: RemoteSSHOperation) async -> SSHCommandExecutionResult {
        requestedOperations.append(operation)
        return results.removeFirst()
    }

    func cancelActive() async {}
    func operations() -> [RemoteSSHOperation] { requestedOperations }
}

private final class TestInstantBox: @unchecked Sendable {
    var value = ContinuousClock().now

    func advance(by duration: Duration) {
        value = value.advanced(by: duration)
    }
}
