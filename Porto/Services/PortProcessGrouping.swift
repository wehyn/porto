import Foundation

/// Coalesces the rows from one scan into stable, actionable process rows.
struct PortProcessGrouping {
    static func group(_ rows: [PortProcess], scanGeneration: UInt64) -> [PortProcess] {
        var groups: [GroupKey: [PortProcess]] = [:]
        var retained: [PortProcess] = []

        for row in rows {
            guard let key = GroupKey(row: row) else {
                retained.append(row)
                continue
            }
            groups[key, default: []].append(row)
        }

        let aggregates = groups.map { key, members in
            aggregate(key: key, members: members, scanGeneration: scanGeneration)
        }
        return PortProcessSort.sort(retained + aggregates)
    }

    private static func aggregate(
        key: GroupKey,
        members: [PortProcess],
        scanGeneration: UInt64
    ) -> PortProcess {
        let ports = Set(members.flatMap(\.localPorts)).sorted()
        let transports = Set(members.flatMap(\.transports)).sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.rawValue < rhs.rawValue
        }
        let endpoints = Set(members.flatMap(\.endpoints)).sorted {
            if $0.sortKey != $1.sortKey { return $0.sortKey < $1.sortKey }
            return $0.rawValue < $1.rawValue
        }
        let remoteSocketIdentity = remoteSocketIdentity(for: members)
        let processName = displayName(for: members)

        return PortProcess(
            id: stableID(for: key, scanGeneration: scanGeneration),
            origin: members[0].origin,
            localPorts: ports,
            transports: transports,
            processName: processName,
            endpoints: endpoints,
            activityKind: key.activityKind,
            remoteSocketIdentity: remoteSocketIdentity,
            source: members[0].source,
            controlTarget: members[0].controlTarget,
            isDockerPublished: false
        )
    }

    private static func remoteSocketIdentity(for members: [PortProcess]) -> String? {
        guard members.contains(where: { $0.isRemote }) else { return nil }

        var identities = Set<String>()
        for member in members {
            guard let value = member.remoteSocketIdentity else { return nil }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            identities.formUnion(parts)
        }
        return identities.isEmpty ? nil : identities.sorted().joined(separator: ",")
    }

    private static func stableID(for key: GroupKey, scanGeneration: UInt64) -> String {
        switch key.origin {
        case let .local(identity):
            return "local|activity=\(hex(key.activityKind.rawValue))|pid=\(identity.pid)|start=\(identity.startTimeSeconds).\(identity.startTimeMicroseconds)"
        case let .remote(targetID, pid):
            return "remote|target=\(hex(targetID.rawValue))|activity=\(hex(key.activityKind.rawValue))|pid=\(pid ?? 0)|name=\(hex(key.processName))"
        case let .localUnverified(pid):
            return "local-unverified|activity=\(hex(key.activityKind.rawValue))|pid=\(pid)|scan=\(scanGeneration)"
        }
    }

    private static func displayName(for members: [PortProcess]) -> String {
        members.map(\.processName).sorted { lhs, rhs in
            let lhsNormalized = GroupKey.normalize(lhs)
            let rhsNormalized = GroupKey.normalize(rhs)
            if lhsNormalized != rhsNormalized { return lhsNormalized < rhsNormalized }
            return lhs < rhs
        }.first ?? ""
    }

    private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private struct GroupKey: Hashable {
        let activityKind: PortActivityKind
        let origin: PortProcessOrigin
        let processName: String
        let source: PortProcessSource
        let controlTarget: PortControlTarget

        init?(row: PortProcess) {
            guard !row.isDockerPublished,
                  !row.isDockerContainer,
                  Self.hasOwner(row.origin) else { return nil }
            self.activityKind = row.activityKind
            self.origin = row.origin
            self.processName = Self.normalize(row.processName)
            self.source = row.source
            self.controlTarget = row.controlTarget
        }

        private static func hasOwner(_ origin: PortProcessOrigin) -> Bool {
            switch origin {
            case .local:
                return true
            case .localUnverified:
                return true
            case let .remote(_, pid):
                return pid.map { $0 > 0 } ?? false
            }
        }

        fileprivate static func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
    }
}
