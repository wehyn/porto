import Foundation

/// Keeps the default view useful for local development without hiding custom
/// ports that a developer may have chosen for a project.
struct PortVisibilityPolicy: Sendable, Equatable {
    let hiddenPorts: Set<Int>
    let hiddenProcessNames: Set<String>

    static let developerFocused = PortVisibilityPolicy(
        // Hide known background services and noisy user-level helpers by
        // process name rather than hiding numeric ports that a local
        // development server may also use.
        hiddenPorts: [],
        hiddenProcessNames: [
            "controlcenter",
            "rapportd",
            "identityservicesd",
            "remotepairingd",
            "replicatord",
            "sharingd",
            "discord",
            "discord helper",
            "discord helper (renderer)",
            "zen"
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
