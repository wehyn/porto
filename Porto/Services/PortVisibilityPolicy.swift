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

    /// Keeps remote snapshots focused on developer-owned services by hiding
    /// common host infrastructure ports. Custom application ports remain
    /// visible, even when their process metadata is unavailable over SSH.
    static let remoteFocused = PortVisibilityPolicy(
        hiddenPorts: [
            22,    // SSH
            53,    // DNS
            80,    // HTTP
            123,   // NTP
            137,   // NetBIOS name service
            138,   // NetBIOS datagram service
            139,   // NetBIOS session service
            161,   // SNMP
            162,   // SNMP traps
            443,   // HTTPS
            445,   // SMB
            5353   // mDNS
        ],
        hiddenProcessNames: []
    )

    func includes(_ group: ParsedPortGroup) -> Bool {
        includes(port: group.key.localPort, processName: group.processName)
    }

    func includes(_ row: PortProcess) -> Bool {
        includes(port: row.localPort, processName: row.processName)
    }

    func filtering(_ snapshot: PortSnapshot) -> PortSnapshot {
        PortSnapshot(
            listeners: snapshot.listeners.filter { includes($0) },
            connections: snapshot.connections.filter { includes($0) }
        )
    }

    private func includes(port: Int, processName: String) -> Bool {
        !hiddenPorts.contains(port)
            && !hiddenProcessNames.contains(Self.normalized(processName))
    }

    private static func normalized(_ processName: String) -> String {
        processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
