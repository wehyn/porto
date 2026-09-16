import Combine
import Foundation
import Sparkle

@MainActor
final class PortoUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool

    private let driver: PortoUpdateDriving
    private let isCheckForUpdatesAllowed: Bool
    private var canCheckForUpdatesSubscription: AnyCancellable?
    private var sparkleController: SPUStandardUpdaterController?

    init() {
        #if DEBUG
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleController = controller
        self.driver = SparkleUpdateDriver(controller: controller)
        self.isCheckForUpdatesAllowed = false
        #else
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleController = controller
        self.driver = SparkleUpdateDriver(controller: controller)
        self.isCheckForUpdatesAllowed = true
        #endif
        self.canCheckForUpdates = driver.canCheckForUpdates
        subscribeToDriver()
    }

    init(driver: PortoUpdateDriving, isCheckForUpdatesAllowed: Bool) {
        self.driver = driver
        self.isCheckForUpdatesAllowed = isCheckForUpdatesAllowed
        self.canCheckForUpdates = driver.canCheckForUpdates
        subscribeToDriver()
    }

    func checkForUpdates() {
        guard isCheckForUpdatesAllowed, driver.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    private func subscribeToDriver() {
        canCheckForUpdatesSubscription = driver.canCheckForUpdatesPublisher
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
    }
}

@MainActor
private final class SparkleUpdateDriver: PortoUpdateDriving {
    private let controller: SPUStandardUpdaterController

    init(controller: SPUStandardUpdaterController) {
        self.controller = controller
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> {
        controller.updater
            .publisher(for: \SPUUpdater.canCheckForUpdates, options: [.initial, .new])
            .eraseToAnyPublisher()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
