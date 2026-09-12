import Foundation
import XCTest
@testable import Porto

final class SsParserTests: XCTestCase {
    private let targetA = PortTargetID(rawValue: "ssh:production")
    private let targetB = PortTargetID(rawValue: "ssh:staging")

    func testParsesIPv4IPv6WildcardLoopbackAndInterfaceQualifiedEndpoints() throws {
        let parsed = try parse(fixture("mixed-endpoints"))

        XCTAssertEqual(parsed.validRecords, 6)
        XCTAssertEqual(parsed.skippedRecords, 0)
        XCTAssertEqual(parsed.snapshot.listeners.count, 4)
        XCTAssertEqual(parsed.snapshot.connections.count, 2)
        XCTAssertTrue(parsed.snapshot.allRows.flatMap(\.endpoints).contains { $0.rawValue == "[fe80::1%eth0]:5353->[::]:*" })
        XCTAssertTrue(parsed.snapshot.allRows.flatMap(\.endpoints).contains { $0.rawValue == "127.0.0.1:49152->127.0.0.1:443" })
    }

    func testClassifiesTCPTransitionalAndOwnerlessTimeWaitAsConnections() throws {
        let text = """
        tcp SYN-SENT 0 1 192.0.2.10:40000 198.51.100.1:443
        tcp TIME-WAIT 0 0 192.0.2.10:40001 198.51.100.2:443 timer:(timewait,10sec,0) ino:42 sk:abc
        tcp CLOSED 0 0 192.0.2.10:40002 0.0.0.0:*
        """
        let parsed = try parse(Data(text.utf8))

        XCTAssertEqual(parsed.snapshot.connections.count, 2)
        XCTAssertEqual(parsed.skippedRecords, 1)
        XCTAssertTrue(parsed.snapshot.connections.contains { $0.endpoints.first?.socketState == "TIME-WAIT" })
    }

    func testUDPWildcardIsListenerAndConcretePeerIsConnection() throws {
        let text = """
        udp UNCONN 0 0 0.0.0.0:5353 0.0.0.0:* users:(("mdns",pid=12,fd=3))
        udp ESTAB 0 0 192.0.2.2:53000 198.51.100.53:53 users:(("dns",pid=13,fd=4))
        """
        let parsed = try parse(Data(text.utf8))

        XCTAssertEqual(parsed.snapshot.listeners.map(\.localPort), [5353])
        XCTAssertEqual(parsed.snapshot.connections.map(\.localPort), [53000])
    }

    func testPortBoundsAndInvalidPortsAreIsolated() throws {
        let text = """
        tcp LISTEN 0 128 *:1 *:* ino:1
        tcp LISTEN 0 128 [::]:65535 [::]:* ino:2
        tcp LISTEN 0 128 *:0 *:* ino:3
        tcp LISTEN 0 128 *:65536 *:* ino:4
        tcp LISTEN 0 128 *:https *:* ino:5
        tcp LISTEN 0 128 missing-port *:* ino:6
        """
        let parsed = try parse(Data(text.utf8))

        XCTAssertEqual(parsed.snapshot.listeners.map(\.localPort), [1, 65_535])
        XCTAssertEqual(parsed.validRecords, 2)
        XCTAssertEqual(parsed.skippedRecords, 4)
    }

    func testMissingSingleMultipleMalformedEscapedAndTruncatedOwners() throws {
        let parsed = try parse(fixture("owners"))

        XCTAssertEqual(parsed.validRecords, 5)
        XCTAssertEqual(parsed.snapshot.listeners.count, 6)
        XCTAssertEqual(parsed.snapshot.listeners.filter { $0.processName == "Unknown process" }.count, 2)
        XCTAssertTrue(parsed.snapshot.listeners.contains { $0.processName == "quote\"daemon" })
        XCTAssertTrue(parsed.snapshot.listeners.contains { $0.processName == "comma, daemon" })
        XCTAssertFalse(parsed.snapshot.listeners.contains { $0.processName == "bad-pid" })
    }

    func testMalformedOwnerDoesNotDiscardValidSibling() throws {
        let text = "tcp LISTEN 0 128 *:8080 *:* users:((\"good\",pid=10,fd=3),(\"bad\",pid=nope,fd=4),(\"negative\",pid=-2,fd=5))"
        let parsed = try parse(Data(text.utf8))

        XCTAssertEqual(parsed.snapshot.listeners.count, 1)
        XCTAssertEqual(parsed.snapshot.listeners[0].processName, "good")
        guard case let .remote(_, pid) = parsed.snapshot.listeners[0].origin else {
            return XCTFail("expected remote origin")
        }
        XCTAssertEqual(pid, 10)
    }

    func testUIDInodeCookieAndUnknownFieldsUseFallbackPrecedence() throws {
        let text = """
        tcp LISTEN 0 128 *:8000 *:* uid:1000 ino:10 sk:cookie-a future:value
        tcp LISTEN 0 128 *:8001 *:* uid:1000 ino:11 future:value
        tcp LISTEN 0 128 *:8002 *:* uid:1000 future:value
        """
        let rows = try parse(Data(text.utf8)).snapshot.listeners

        XCTAssertTrue(rows[0].id.contains("cookie="))
        XCTAssertTrue(rows[1].id.contains("inode="))
        XCTAssertTrue(rows[2].id.contains("tuple="))
    }

    func testDuplicateSocketsAndMultiSocketOwnersAreGroupedAndEndpointsSorted() throws {
        let text = """
        tcp LISTEN 0 128 [::]:8080 [::]:* users:(("web",pid=50,fd=4)) ino:1
        tcp LISTEN 0 128 *:8080 *:* users:(("web",pid=50,fd=3)) ino:2
        tcp LISTEN 0 128 *:8080 *:* users:(("web",pid=50,fd=3)) ino:2
        """
        let parsed = try parse(Data(text.utf8))

        XCTAssertEqual(parsed.validRecords, 3)
        XCTAssertEqual(parsed.snapshot.listeners.count, 1)
        XCTAssertEqual(parsed.snapshot.listeners[0].endpoints.map(\.rawValue), ["*:8080->*:*", "[::]:8080->[::]:*"])
    }

    func testInvalidUTF8AndControlCharactersAreReplacedAndNamesAreBounded() throws {
        var data = Data("tcp LISTEN 0 128 *:9000 *:* users:((\"bad".utf8)
        data.append(contentsOf: [0xFF, 0x01])
        data.append(Data(String(repeating: "x", count: 200).utf8))
        data.append(Data("\",pid=99,fd=3))".utf8))
        let row = try XCTUnwrap(try parse(data).snapshot.listeners.first)

        XCTAssertTrue(row.processName.contains("��"))
        XCTAssertEqual(row.processName.count, 128)
    }

    func testEmptySuccessMalformedIsolationAndAllMalformedFailure() throws {
        let empty = try parse(Data(" \n\r\n".utf8))
        XCTAssertEqual(empty.snapshot, .empty)
        XCTAssertEqual(empty.validRecords, 0)

        let partial = try parse(Data("garbage\ntcp LISTEN 0 128 *:22 *:* ino:1\nnope".utf8))
        XCTAssertEqual(partial.validRecords, 1)
        XCTAssertEqual(partial.skippedRecords, 2)

        XCTAssertEqual(SsParser().parse(Data("garbage\nstill bad".utf8), targetID: targetA), .failure(.malformedOutput))
    }

    func testIDsAreStableTargetScopedAndUseDeterministicOwnerlessFallbacks() throws {
        let data = fixture("stable-identity")
        let first = try parse(data, targetID: targetA).snapshot.allRows.map(\.id)
        let repeated = try parse(data, targetID: targetA).snapshot.allRows.map(\.id)
        let otherTarget = try parse(data, targetID: targetB).snapshot.allRows.map(\.id)

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, otherTarget)
        XCTAssertEqual(Set(first).count, 4)
    }

    func testRowsSortByPortNameTCPBeforeUDPThenPIDAndID() throws {
        let text = """
        udp UNCONN 0 0 *:7000 *:* users:(("alpha",pid=3,fd=1))
        tcp LISTEN 0 0 *:7000 *:* users:(("alpha",pid=2,fd=1))
        tcp LISTEN 0 0 *:6000 *:* users:(("zulu",pid=4,fd=1))
        tcp LISTEN 0 0 *:7000 *:* users:(("Alpha",pid=1,fd=1))
        """
        let rows = try parse(Data(text.utf8)).snapshot.listeners

        XCTAssertEqual(rows.map(\.localPort), [6000, 7000, 7000, 7000])
        XCTAssertEqual(rows.map(\.transport), [.tcp, .tcp, .tcp, .udp])
    }

    private func parse(_ data: Data, targetID: PortTargetID? = nil) throws -> ParsedSsOutput {
        switch SsParser().parse(data, targetID: targetID ?? targetA) {
        case let .success(output): return output
        case let .failure(error): throw error
        }
    }

    private func fixture(_ name: String) -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/Ss")
            ?? bundle.url(forResource: name, withExtension: "txt")!
        return try! Data(contentsOf: url)
    }
}
