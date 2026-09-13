import Foundation

struct SSHHost: Hashable, Sendable, Codable {
    let alias: String

    init(alias: String) {
        self.alias = alias
    }
}

struct PortTargetID: Hashable, Sendable, Codable {
    let rawValue: String

    static let local = PortTargetID(rawValue: "local")

    static func remote(profileID: UUID) -> PortTargetID {
        PortTargetID(rawValue: "remote:\(profileID.uuidString)")
    }

}

enum PortTarget: Hashable, Sendable, Codable {
    case local
    case remote(RemoteServerProfile)

    var id: PortTargetID {
        switch self {
        case .local: .local
        case let .remote(profile): .remote(profileID: profile.id)
        }
    }

    var displayName: String {
        switch self {
        case .local: "This Mac"
        case let .remote(profile): profile.displayName
        }
    }

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}
