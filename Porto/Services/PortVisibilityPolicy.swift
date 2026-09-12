import Foundation

/// Keeps the default view useful for local development without hiding custom
/// ports that a developer may have chosen for a project.
struct PortVisibilityPolicy: Sendable, Equatable {
    let hiddenPorts: Set<Int>
    let hiddenProcessNames: Set<String>

    static let developerFocused = PortVisibilityPolicy(
        // 3722 is used by legacy Xserve RAID discovery and is not useful in a
        // local development port list.
        hiddenPorts: [3722],
        hiddenProcessNames: [
            "controlcenter",
            "crapportd",
            "identityservicesd",
            "remotepairingd",
            "sharingd"
        ]
    )

    func includes(_ group: ParsedPortGroup) -> Bool {
        !hiddenPorts.contains(group.key.localPort)
            && !hiddenProcessNames.contains(Self.normalized(group.processName))
    }

    private static func normalized(_ processName: String) -> String {
        processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
