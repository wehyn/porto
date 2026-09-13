import Foundation

@MainActor
protocol RemoteServerProfileStoring: AnyObject {
    var profiles: [RemoteServerProfile] { get }
    func save(_ profile: RemoteServerProfile) throws
    func delete(id: UUID)
}

@MainActor
final class UserDefaultsRemoteServerProfileStore: RemoteServerProfileStoring {
    private let defaults: UserDefaults
    private let key: String
    private(set) var profiles: [RemoteServerProfile]

    init(
        suite: UserDefaults = .standard,
        key: String = "remoteServerProfiles"
    ) {
        defaults = suite
        self.key = key
        profiles = Self.load(from: suite, key: key)
    }

    func save(_ profile: RemoteServerProfile) throws {
        try profile.validate(against: profiles)
        var replacement = profiles
        if let index = replacement.firstIndex(where: { $0.id == profile.id }) {
            replacement[index] = profile
        } else {
            replacement.append(profile)
        }
        let sorted = Self.sorted(replacement)
        let data = try JSONEncoder().encode(sorted)
        defaults.set(data, forKey: key)
        profiles = sorted
    }

    func delete(id: UUID) {
        let replacement = profiles.filter { $0.id != id }
        guard replacement.count != profiles.count else { return }
        guard let data = try? JSONEncoder().encode(replacement) else { return }
        defaults.set(data, forKey: key)
        profiles = replacement
    }

    private static func load(from defaults: UserDefaults, key: String) -> [RemoteServerProfile] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RemoteServerProfile].self, from: data) else {
            return []
        }
        return sorted(decoded)
    }

    static func sorted(_ profiles: [RemoteServerProfile]) -> [RemoteServerProfile] {
        profiles.sorted {
            let left = $0.displayName.folding(options: [.caseInsensitive], locale: nil)
            let right = $1.displayName.folding(options: [.caseInsensitive], locale: nil)
            if left != right { return left < right }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

@MainActor
final class InMemoryRemoteServerProfileStore: RemoteServerProfileStoring {
    private(set) var profiles: [RemoteServerProfile] = []

    func save(_ profile: RemoteServerProfile) throws {
        try profile.validate(against: profiles)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles = UserDefaultsRemoteServerProfileStore.sorted(profiles)
    }

    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
    }
}
