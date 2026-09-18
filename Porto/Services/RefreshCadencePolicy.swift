import Foundation

enum MonitorPowerMode: Sendable, Equatable {
    case normal
    case lowPower
}

enum RefreshTargetKind: Sendable, Equatable {
    case local
    case remote
}

protocol MonitorPowerModeProviding: Sendable {
    func currentMode() -> MonitorPowerMode
}

struct SystemMonitorPowerModeProvider: MonitorPowerModeProviding, Sendable {
    func currentMode() -> MonitorPowerMode {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : .normal
    }
}

struct RefreshCadencePolicy: Sendable, Equatable {
    private static let normalLocal = [
        Duration.seconds(2), Duration.seconds(5), Duration.seconds(15), Duration.seconds(30)
    ]
    private static let normalRemote = [
        Duration.seconds(5), Duration.seconds(15), Duration.seconds(30), Duration.seconds(60)
    ]
    private static let lowPowerLocal = [
        Duration.seconds(10), Duration.seconds(30), Duration.seconds(60), Duration.seconds(120)
    ]
    private static let lowPowerRemote = [
        Duration.seconds(15), Duration.seconds(30), Duration.seconds(60), Duration.seconds(120)
    ]
    private static let failures = [
        Duration.seconds(2), Duration.seconds(4), Duration.seconds(8),
        Duration.seconds(16), Duration.seconds(30)
    ]

    func delay(
        target: RefreshTargetKind,
        unchangedSuccesses: Int,
        powerMode: MonitorPowerMode
    ) -> Duration {
        let schedule: [Duration]
        switch (target, powerMode) {
        case (.local, .normal): schedule = Self.normalLocal
        case (.remote, .normal): schedule = Self.normalRemote
        case (.local, .lowPower): schedule = Self.lowPowerLocal
        case (.remote, .lowPower): schedule = Self.lowPowerRemote
        }
        return schedule[min(max(unchangedSuccesses, 0), schedule.count - 1)]
    }

    static func failureDelay(for consecutiveFailures: Int) -> Duration {
        failures[min(max(consecutiveFailures - 1, 0), failures.count - 1)]
    }
}
