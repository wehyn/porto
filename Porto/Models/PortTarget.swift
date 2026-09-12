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

    static func ssh(alias: String) -> PortTargetID {
        let encoded = Data(alias.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PortTargetID(rawValue: "ssh:\(encoded)")
    }
}

enum PortTarget: Hashable, Sendable, Codable {
    case local
    case ssh(SSHHost)

    var id: PortTargetID {
        switch self {
        case .local: .local
        case let .ssh(host): .ssh(alias: host.alias)
        }
    }

    var displayName: String {
        switch self {
        case .local: "This Mac"
        case let .ssh(host): host.alias
        }
    }

    var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }
}
