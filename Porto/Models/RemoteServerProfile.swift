import Darwin
import Foundation

struct RemoteServerProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var host: String
    var username: String
    var port: Int
    var identityFilePath: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        username: String,
        port: Int = 22,
        identityFilePath: String? = nil,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.username = username
        self.port = port
        self.identityFilePath = identityFilePath
        self.isEnabled = isEnabled
    }

    /// The user-facing SSH address. IPv6 hosts are bracketed so the port
    /// separator remains unambiguous in Settings and the target picker.
    var sshAddress: String {
        guard !username.isEmpty || !host.isEmpty else { return "" }
        let displayHost = host.contains(":") && !host.hasPrefix("[")
            ? "[\(host)]"
            : host
        return "\(username)@\(displayHost)"
    }

    /// Parses the single user@hostname value used by the profile editor.
    /// The stored profile continues to keep the two components separate for
    /// the fixed SSH command contract and existing persisted profiles.
    static func parseSSHAddress(_ value: String) -> (username: String, host: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "@") else { return nil }
        let hostStart = trimmed.index(after: separator)
        guard separator > trimmed.startIndex, hostStart < trimmed.endIndex else { return nil }

        let username = String(trimmed[..<separator])
        let host = String(trimmed[hostStart...])
        guard isValidUsername(username), isValidHost(host) else { return nil }
        return (username, host)
    }

    static func validate(
        _ profile: RemoteServerProfile,
        against otherProfiles: some Sequence<RemoteServerProfile> = []
    ) throws {
        guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteServerProfileValidationError.blankDisplayName
        }
        guard !profile.displayName.unicodeScalars.contains(where: Self.isControl) else {
            throw RemoteServerProfileValidationError.invalidDisplayName
        }
        guard Self.isValidHost(profile.host) else {
            throw RemoteServerProfileValidationError.invalidHost
        }
        guard Self.isValidUsername(profile.username) else {
            throw RemoteServerProfileValidationError.invalidUsername
        }
        guard (1...65_535).contains(profile.port) else {
            throw RemoteServerProfileValidationError.invalidPort
        }

        let foldedName = profile.displayName.folding(options: [.caseInsensitive], locale: nil)
        if otherProfiles.contains(where: {
            $0.id != profile.id &&
            $0.displayName.folding(options: [.caseInsensitive], locale: nil) == foldedName
        }) {
            throw RemoteServerProfileValidationError.duplicateDisplayName
        }
    }

    func validate(against otherProfiles: some Sequence<RemoteServerProfile> = []) throws {
        try Self.validate(self, against: otherProfiles)
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard isSafeLiteralValue(value) else { return false }

        if value.first == "[" || value.last == "]" {
            guard value.first == "[", value.last == "]", value.count >= 4 else { return false }
            return isValidIPv6Literal(String(value.dropFirst().dropLast()))
        }

        if value.contains(":"), isValidIPv6Literal(value) {
            return true
        }
        if value.contains(".") && value.unicodeScalars.allSatisfy({ $0.value == 46 || isASCIIDigit($0) }) {
            return isValidIPv4Literal(value)
        }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.count <= 127 else { return false }
        guard value.count <= 253 else { return false }
        for (index, label) in labels.enumerated() {
            if index == labels.count - 1 && label.isEmpty {
                // A trailing dot is the absolute form of a DNS hostname.
                continue
            }
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy(isHostnameScalar) else {
                return false
            }
        }
        return true
    }

    private static func isValidUsername(_ value: String) -> Bool {
        guard isSafeLiteralValue(value), value.first != "-" else { return false }
        guard let first = value.unicodeScalars.first,
              (isASCIILetter(first) || first.value == 95) else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy { scalar in
            isASCIILetter(scalar) || isASCIIDigit(scalar) ||
                scalar.value == 95 || scalar.value == 45 || scalar.value == 46
        }
    }

    private static func isValidIPv4Literal(_ value: String) -> Bool {
        value.withCString { address in
            var parsed = in_addr()
            return inet_pton(AF_INET, address, &parsed) == 1
        }
    }

    private static func isValidIPv6Literal(_ value: String) -> Bool {
        let components = value.split(separator: "%", omittingEmptySubsequences: false)
        guard components.count <= 2, let address = components.first, !address.isEmpty else { return false }
        if components.count == 2 {
            let zone = components[1]
            guard !zone.isEmpty, zone.unicodeScalars.allSatisfy(isZoneScalar) else { return false }
        }
        return address.withCString { address in
            var parsed = in6_addr()
            return inet_pton(AF_INET6, address, &parsed) == 1
        }
    }

    private static func isSafeLiteralValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard !value.hasPrefix("-") else { return false }
        guard !value.unicodeScalars.contains(where: { $0.properties.isWhitespace || isControl($0) }) else {
            return false
        }
        return true
    }

    private static func isHostnameScalar(_ scalar: UnicodeScalar) -> Bool {
        isASCIILetter(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar.value == 45
    }

    private static func isZoneScalar(_ scalar: UnicodeScalar) -> Bool {
        isHostnameScalar(scalar) || scalar.value == 95
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    private static func isControl(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0
    }
}

enum RemoteServerProfileValidationError: Error, LocalizedError, Equatable, Sendable {
    case blankDisplayName
    case invalidDisplayName
    case invalidHost
    case invalidUsername
    case invalidPort
    case duplicateDisplayName

    var userMessage: String {
        switch self {
        case .blankDisplayName: "Enter a display name."
        case .invalidDisplayName: "The display name contains an invalid character."
        case .invalidHost: "Enter a hostname or IP address without whitespace or shell characters."
        case .invalidUsername: "Enter a username without whitespace or shell characters."
        case .invalidPort: "Enter a port from 1 to 65535."
        case .duplicateDisplayName: "Each profile must have a unique display name."
        }
    }

    var errorDescription: String? { userMessage }
}
