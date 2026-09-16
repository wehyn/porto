import Combine

@MainActor
protocol PortoUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var canCheckForUpdatesPublisher: AnyPublisher<Bool, Never> { get }
    func checkForUpdates()
}
