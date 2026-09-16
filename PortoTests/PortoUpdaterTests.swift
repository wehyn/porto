import Combine
import XCTest
@testable import Porto

@MainActor
private final class StubUpdateDriver: PortoUpdateDriving {
    let canCheckForUpdatesSubject: CurrentValueSubject<Bool, Never>
    private(set) var checkForUpdatesCallCount = 0

    init(canCheckForUpdates: Bool) {
        canCheckForUpdatesSubject = CurrentValueSubject(canCheckForUpdates)
    }

    var canCheckForUpdates: Bool {
        canCheckForUpdatesSubject.value
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        canCheckForUpdatesSubject.eraseToAnyPublisher()
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }
}

@MainActor
final class PortoUpdaterTests: XCTestCase {
    func testDisabledCheckForUpdatesDoesNotForward() {
        let driver = StubUpdateDriver(canCheckForUpdates: false)
        let updater = PortoUpdater(driver: driver, isCheckForUpdatesAllowed: true)

        updater.checkForUpdates()

        XCTAssertEqual(driver.checkForUpdatesCallCount, 0)
    }

    func testEnabledCheckForUpdatesForwardsExactlyOnce() {
        let driver = StubUpdateDriver(canCheckForUpdates: true)
        let updater = PortoUpdater(driver: driver, isCheckForUpdatesAllowed: true)

        updater.checkForUpdates()

        XCTAssertEqual(driver.checkForUpdatesCallCount, 1)
    }

    func testCanCheckForUpdatesMirrorsDriverPublisher() {
        let driver = StubUpdateDriver(canCheckForUpdates: false)
        let updater = PortoUpdater(driver: driver, isCheckForUpdatesAllowed: true)
        XCTAssertFalse(updater.canCheckForUpdates)

        driver.canCheckForUpdatesSubject.send(true)

        XCTAssertTrue(updater.canCheckForUpdates)
    }
}
