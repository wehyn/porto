import XCTest
@testable import Porto

final class PortProcessGroupingTests: XCTestCase {
    private let targetID = PortTargetID(rawValue: "remote:prod")
    private let identity = ProcessIdentity(pid: 42, startTimeSeconds: 10, startTimeMicroseconds: 20)

    func testOwnerIdentifiableLocalListenerRowsMergeAcrossPorts() {
        let rows = [
            row(id: "old-8080", port: 8080, name: "My App", origin: .local(identity), endpoint: "127.0.0.1:8080"),
            row(id: "old-9090", port: 9090, name: "my app", origin: .local(identity), endpoint: "127.0.0.1:9090")
        ]
        let grouped = PortProcessGrouping.group(rows, scanGeneration: 7)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].localPorts, [8080, 9090])
        XCTAssertEqual(grouped[0].endpoints.map(\.rawValue), ["127.0.0.1:8080", "127.0.0.1:9090"])
    }

    func testLocalAggregateKeepsStableIDAcrossProcessNameChanges() {
        let initial = PortProcessGrouping.group(
            [row(id: "initial", port: 8080, name: "daemon", origin: .local(identity))],
            scanGeneration: 1
        )[0]
        let renamed = PortProcessGrouping.group(
            [row(id: "renamed", port: 8080, name: "replacement-display-name", origin: .local(identity))],
            scanGeneration: 2
        )[0]

        XCTAssertEqual(initial.id, renamed.id)
        XCTAssertEqual(renamed.processName, "replacement-display-name")
    }

    func testAggregateDisplayNameIsDeterministicRegardlessInputOrder() {
        let rows = [
            row(id: "lower", port: 8080, name: "daemon", origin: .local(identity)),
            row(id: "upper", port: 8081, name: "Daemon", origin: .local(identity))
        ]

        XCTAssertEqual(
            PortProcessGrouping.group(rows, scanGeneration: 1),
            PortProcessGrouping.group(rows.reversed(), scanGeneration: 1)
        )
        XCTAssertEqual(PortProcessGrouping.group(rows, scanGeneration: 1).first?.processName, "Daemon")
    }

    func testListenerAndConnectionRowsRemainSeparate() {
        let rows = [
            row(id: "listener", port: 8080, name: "app", origin: .local(identity), activity: .listener, endpoint: "127.0.0.1:8080"),
            row(id: "connection", port: 8080, name: "APP", origin: .local(identity), activity: .connection, endpoint: "127.0.0.1:8080->127.0.0.1:50000", remote: true)
        ]
        let grouped = PortProcessGrouping.group(rows, scanGeneration: 1)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(Set(grouped.map(\.activityKind)), [.listener, .connection])
    }

    func testSameNameDifferentLocalProcessIdentityRowsRemainSeparate() {
        let otherIdentity = ProcessIdentity(pid: 43, startTimeSeconds: 10, startTimeMicroseconds: 20)
        let rows = [
            row(id: "first", port: 8080, name: "app", origin: .local(identity), endpoint: "127.0.0.1:8080"),
            row(id: "second", port: 8081, name: "APP", origin: .local(otherIdentity), endpoint: "127.0.0.1:8081")
        ]
        XCTAssertEqual(PortProcessGrouping.group(rows, scanGeneration: 1).count, 2)
    }

    func testLocalUnverifiedRowsMergeWithinAScanAndRemainLocked() {
        let rows = [
            row(id: "unverified-8080", port: 8080, name: "app", origin: .localUnverified(pid: 77)),
            row(id: "unverified-8443", port: 8443, name: "APP", origin: .localUnverified(pid: 77))
        ]

        let grouped = PortProcessGrouping.group(rows, scanGeneration: 9)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.localPorts, [8080, 8443])
        XCTAssertFalse(grouped.first?.isActionable ?? true)
        XCTAssertTrue(grouped.first?.id.contains("scan=9") ?? false)
    }

    func testRemoteTailscaledListenerAndConnectionGroupByActivityAndUnionSockets() {
        let origin = PortProcessOrigin.remote(targetID: targetID, pid: 100)
        let control = PortControlTarget.remoteProcess(targetID: targetID, pid: 100)
        let rows = [
            row(id: "connection-1", port: 41641, name: "tailscaled", origin: origin, activity: .connection, endpoint: "10.0.0.1:41641->10.0.0.2:50000", remote: true, socket: "sk:z,sk:a", source: .remoteProcess, control: control),
            row(id: "listener-1", port: 41641, name: "tailscaled", origin: origin, activity: .listener, endpoint: "0.0.0.0:41641", socket: "sk:l", source: .remoteProcess, control: control),
            row(id: "connection-2", port: 41642, name: "TAILSCALED", origin: origin, activity: .connection, endpoint: "10.0.0.1:41642->10.0.0.3:50001", remote: true, socket: "sk:b", source: .remoteProcess, control: control)
        ]
        let grouped = PortProcessGrouping.group(rows, scanGeneration: 4)
        let connection = try! XCTUnwrap(grouped.first { $0.activityKind == .connection })
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(connection.localPorts, [41641, 41642])
        XCTAssertEqual(connection.remoteSocketIdentity, "sk:a,sk:b,sk:z")
    }

    func testDockerPublishedAndAmbiguousDockerRowsRemainIndependent() {
        let docker = row(id: "docker", port: 8080, name: "web", origin: .remote(targetID: targetID, pid: nil), source: .dockerContainer(containerID: "0123456789ab"), control: .remoteDocker(targetID: targetID, containerID: "0123456789ab"), docker: true)
        let ambiguous = row(id: "ambiguous", port: 8080, name: "web", origin: .remote(targetID: targetID, pid: nil), source: .dockerContainer(containerID: nil), control: PortControlTarget.none, docker: true)
        XCTAssertEqual(PortProcessGrouping.group([docker, docker, ambiguous], scanGeneration: 1).count, 3)
    }

    func testOwnerlessRemoteRowsAndMissingSocketIdentityRemainNonActionable() {
        let origin = PortProcessOrigin.remote(targetID: targetID, pid: 100)
        let control = PortControlTarget.remoteProcess(targetID: targetID, pid: 100)
        let rows = [
            row(id: "with-socket", port: 8000, name: "app", origin: origin, socket: "sk:one", source: .remoteProcess, control: control),
            row(id: "without-socket", port: 8001, name: "APP", origin: origin, socket: nil, source: .remoteProcess, control: control),
            row(id: "pidless-a", port: 8002, name: "app", origin: .remote(targetID: targetID, pid: nil), source: .unknown, control: PortControlTarget.none),
            row(id: "pidless-b", port: 8003, name: "app", origin: .remote(targetID: targetID, pid: nil), source: .unknown, control: PortControlTarget.none)
        ]
        let grouped = PortProcessGrouping.group(rows, scanGeneration: 2)
        let aggregate = try! XCTUnwrap(grouped.first { $0.id != "pidless-a" && $0.id != "pidless-b" })
        XCTAssertEqual(grouped.count, 3)
        XCTAssertNil(aggregate.remoteSocketIdentity)
        XCTAssertFalse(aggregate.isActionable)
        XCTAssertTrue(grouped.contains { $0.id == "pidless-a" })
        XCTAssertTrue(grouped.contains { $0.id == "pidless-b" })
    }

    func testInputOrderDoesNotChangeAggregatesOrStableIDs() {
        let origin = PortProcessOrigin.remote(targetID: targetID, pid: 100)
        let control = PortControlTarget.remoteProcess(targetID: targetID, pid: 100)
        let rows = [
            row(id: "b", port: 9001, name: "APP", origin: origin, socket: "sk:b", source: .remoteProcess, control: control),
            row(id: "a", port: 9000, name: "app", origin: origin, socket: "sk:a", source: .remoteProcess, control: control)
        ]
        let forward = PortProcessGrouping.group(rows, scanGeneration: 8)
        let reverse = PortProcessGrouping.group(rows.reversed(), scanGeneration: 8)
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.first?.id, reverse.first?.id)
    }

    private func row(
        id: String, port: Int, name: String, origin: PortProcessOrigin,
        activity: PortActivityKind = .listener, endpoint: String? = nil,
        remote: Bool = false, socket: String? = nil, source: PortProcessSource? = nil,
        control: PortControlTarget? = nil, docker: Bool = false
    ) -> PortProcess {
        PortProcess(
            id: id, origin: origin, localPort: port, transport: .tcp, processName: name,
            endpoints: [Endpoint(rawValue: endpoint ?? "127.0.0.1:\(port)", localPort: port, hasRemoteEndpoint: remote, socketState: activity == .listener ? "LISTEN" : "ESTAB")],
            activityKind: activity, remoteSocketIdentity: socket, source: source,
            controlTarget: control, isDockerPublished: docker
        )
    }
}
