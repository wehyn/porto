import Foundation

enum DebugPopoverLaunchConfiguration {
    static let environmentKey = "PORTO_DEBUG_POPOVER"

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }
}
