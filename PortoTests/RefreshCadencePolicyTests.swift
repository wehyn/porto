import XCTest
@testable import Porto

final class RefreshCadencePolicyTests: XCTestCase {
    private let policy = RefreshCadencePolicy()

    func testNormalLocalCadenceBacksOffAndCaps() {
        XCTAssertEqual(
            (0...4).map { policy.delay(target: .local, unchangedSuccesses: $0, powerMode: .normal) },
            [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(30)]
        )
    }

    func testNormalRemoteCadenceBacksOffAndCaps() {
        XCTAssertEqual(
            (0...4).map { policy.delay(target: .remote, unchangedSuccesses: $0, powerMode: .normal) },
            [.seconds(5), .seconds(15), .seconds(30), .seconds(60), .seconds(60)]
        )
    }

    func testLowPowerCadenceIsSlowerForBothTargets() {
        XCTAssertEqual(
            (0...4).map { policy.delay(target: .local, unchangedSuccesses: $0, powerMode: .lowPower) },
            [.seconds(10), .seconds(30), .seconds(60), .seconds(120), .seconds(120)]
        )
        XCTAssertEqual(
            (0...4).map { policy.delay(target: .remote, unchangedSuccesses: $0, powerMode: .lowPower) },
            [.seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(120)]
        )
    }

    func testFailureBackoffCapsAtThirtySeconds() {
        XCTAssertEqual(
            (1...6).map { RefreshCadencePolicy.failureDelay(for: $0) },
            [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)]
        )
    }
}
