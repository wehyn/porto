import Foundation

enum SsParserError: Error, Equatable, Sendable {
    case malformedOutput
}

struct ParsedSsOutput: Equatable, Sendable {
    let snapshot: PortSnapshot
    let validRecords: Int
    let skippedRecords: Int
}

enum SsParserResult: Equatable, Sendable {
    case success(ParsedSsOutput)
    case failure(SsParserError)
}

/// Parses the bounded stdout produced by Porto's fixed Linux `ss` command.
struct SsParser: Sendable {
    func parse(_ data: Data, targetID: PortTargetID) -> SsParserResult {
        // This initializer deliberately repairs malformed UTF-8 with U+FFFD.
        let output = String(decoding: data, as: UTF8.self)
        var groups: [SsGroupKey: SsGroupAccumulator] = [:]
        var validRecords = 0
        var skippedRecords = 0
        var sawInput = false

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            sawInput = true
            guard let record = SsRecord.parse(line) else {
                skippedRecords += 1
                continue
            }

            validRecords += 1
            let owners = record.owners.isEmpty ? [SsOwner?](arrayLiteral: nil) : record.owners.map(Optional.some)
            for owner in owners {
                let identity = owner.map { "pid:\($0.pid)" } ?? record.fallbackIdentity
                let key = SsGroupKey(
                    activityKind: record.activityKind,
                    transport: record.transport,
                    localPort: record.endpoint.localPort,
                    ownerIdentity: identity
                )
                let candidateName = owner?.name ?? "Unknown process"
                var accumulator = groups[key] ?? SsGroupAccumulator(processName: candidateName)
                if ssNameSort(candidateName, before: accumulator.processName) {
                    accumulator.processName = candidateName
                }
                accumulator.pid = owner?.pid
                accumulator.endpoints.insert(record.endpoint)
                accumulator.idIdentity = owner == nil ? record.fallbackIdentity : ""
                groups[key] = accumulator
            }
        }

        guard validRecords > 0 || !sawInput else {
            return .failure(.malformedOutput)
        }

        let targetComponent = ssHex(targetID.rawValue)
        let rows = groups.map { key, value in
            let identity = value.pid.map {
                "pid=\($0);name=\(ssHex(SsOwner(pid: $0, name: value.processName).normalizedName))"
            } ?? value.idIdentity
            let id = [
                "remote", "target=\(targetComponent)", key.activityKind.rawValue,
                key.transport.rawValue, "port=\(key.localPort)", identity
            ].joined(separator: "|")
            return PortProcess(
                id: id,
                origin: .remote(targetID: targetID, pid: value.pid),
                localPort: key.localPort,
                transport: key.transport,
                processName: value.processName,
                endpoints: value.endpoints.sorted(by: ssEndpointSort),
                activityKind: key.activityKind
            )
        }
        let listeners = PortProcessSort.sort(rows.filter { $0.activityKind == .listener })
        let connections = PortProcessSort.sort(rows.filter { $0.activityKind == .connection })
        return .success(ParsedSsOutput(
            snapshot: PortSnapshot(listeners: listeners, connections: connections),
            validRecords: validRecords,
            skippedRecords: skippedRecords
        ))
    }
}

private struct SsRecord {
    let transport: TransportProtocol
    let activityKind: PortActivityKind
    let endpoint: Endpoint
    let owners: [SsOwner]
    let fallbackIdentity: String

    static func parse(_ line: String) -> SsRecord? {
        let columns = line.split(maxSplits: 6, whereSeparator: \Character.isWhitespace)
        guard columns.count >= 6 else { return nil }
        let netid = columns[0].lowercased()
        let transport: TransportProtocol
        if netid == "tcp" || netid == "tcp6" {
            transport = .tcp
        } else if netid == "udp" || netid == "udp6" {
            transport = .udp
        } else {
            return nil
        }
        guard UInt64(columns[2]) != nil, UInt64(columns[3]) != nil else {
            return nil
        }

        let state = columns[1].uppercased()
        let localText = String(columns[4])
        let peerText = String(columns[5])
        guard let local = SsAddress.parse(localText, requiresConcretePort: true),
              let peer = SsAddress.parse(peerText, requiresConcretePort: false) else {
            return nil
        }

        let activityKind: PortActivityKind
        switch transport {
        case .tcp:
            if state == "LISTEN" {
                activityKind = .listener
            } else if peer.concretePort != nil {
                activityKind = .connection
            } else {
                return nil
            }
        case .udp:
            if peer.concretePort != nil {
                activityKind = .connection
            } else if state == "UNCONN" || state == "UNCONNECTED" {
                // Linux does not have a TCP-style UDP listen state. Porto treats
                // unconnected bound UDP sockets as listeners, including clients.
                activityKind = .listener
            } else {
                return nil
            }
        }

        let rawEndpoint = "\(local.canonical)->\(peer.canonical)"
        let endpoint = Endpoint(
            rawValue: rawEndpoint,
            localPort: local.concretePort!,
            hasRemoteEndpoint: peer.concretePort != nil,
            socketState: state.isEmpty ? nil : state
        )
        let tail = columns.count == 7 ? String(columns[6]) : ""
        let metadata = SsMetadata.parse(tail)
        let tuple = "tuple=\(ssHex("\(transport.rawValue)|\(state)|\(rawEndpoint)"))"
        let fallback = metadata.cookie.map { "cookie=\(ssHex($0))" }
            ?? metadata.inode.map { "inode=\(ssHex($0))" }
            ?? tuple
        return SsRecord(
            transport: transport,
            activityKind: activityKind,
            endpoint: endpoint,
            owners: metadata.owners,
            fallbackIdentity: fallback
        )
    }
}

private struct SsAddress {
    let canonical: String
    let concretePort: Int?

    static func parse(_ input: String, requiresConcretePort: Bool) -> SsAddress? {
        guard !input.isEmpty, let separator = input.lastIndex(of: ":") else { return nil }
        let host = String(input[..<separator])
        let portText = String(input[input.index(after: separator)...])
        guard !host.isEmpty, ssBalancedEndpointBrackets(host), ssValidNumericHost(host) else { return nil }
        let port: Int?
        if portText == "*" {
            port = nil
        } else {
            guard !portText.isEmpty, portText.allSatisfy(\.isNumber),
                  let value = Int(portText), (1...65_535).contains(value) else { return nil }
            port = value
        }
        guard !requiresConcretePort || port != nil else { return nil }
        return SsAddress(canonical: "\(host):\(portText)", concretePort: port)
    }
}

private func ssBalancedEndpointBrackets(_ host: String) -> Bool {
    let opens = host.filter { $0 == "[" }.count
    let closes = host.filter { $0 == "]" }.count
    guard opens == closes, opens <= 1 else { return false }
    if opens == 1 {
        guard host.first == "[", let closing = host.firstIndex(of: "]") else { return false }
        let suffix = host[host.index(after: closing)...]
        return suffix.isEmpty || suffix.first == "%"
    }
    return true
}

private func ssValidNumericHost(_ host: String) -> Bool {
    if host == "*" { return true }
    var address = host
    if address.first == "[", let closing = address.firstIndex(of: "]") {
        let inside = address.index(after: address.startIndex)..<closing
        let suffix = address[address.index(after: closing)...]
        address = String(address[inside]) + suffix
    }
    let pieces = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
    guard !pieces[0].isEmpty else { return false }
    if pieces.count == 2 {
        guard !pieces[1].isEmpty, pieces[1].count <= 64,
              pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            return false
        }
    }
    let literal = pieces[0]
    if literal.contains(":") {
        return literal.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }
    let octets = literal.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4 && octets.allSatisfy { part in
        !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0...255).contains($0) } == true
    }
}

private struct SsOwner: Hashable {
    let pid: Int32
    let name: String

    var normalizedName: String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}

private struct SsMetadata {
    let owners: [SsOwner]
    let inode: String?
    let cookie: String?

    static func parse(_ tail: String) -> SsMetadata {
        var owners: Set<SsOwner> = []
        var searchStart = tail.startIndex
        while let marker = tail.range(of: "users:(", range: searchStart..<tail.endIndex) {
            let open = tail.index(before: marker.upperBound)
            guard let close = ssMatchingParenthesis(in: tail, from: open) else { break }
            let body = tail[tail.index(after: open)..<close]
            for tuple in ssTopLevelParenthesizedSubstrings(body) {
                if let owner = SsOwnerParser.parse(tuple) { owners.insert(owner) }
            }
            searchStart = tail.index(after: close)
        }

        return SsMetadata(
            owners: owners.sorted {
                if $0.pid != $1.pid { return $0.pid < $1.pid }
                return ssNameSort($0.name, before: $1.name)
            },
            inode: ssMetadataValue(named: "ino", in: tail),
            cookie: ssMetadataValue(named: "sk", in: tail)
        )
    }
}

private enum SsOwnerParser {
    static func parse(_ tuple: Substring) -> SsOwner? {
        let text = tuple.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.first == "(", text.last == ")" else { return nil }
        let inner = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.first == "\"" else { return nil }
        guard let (rawName, remainder) = ssQuotedString(inner) else { return nil }
        var pid: Int32?
        for field in ssSplitTopLevel(remainder.drop(while: { $0 == "," || $0.isWhitespace }), separator: ",") {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: CharacterSet.whitespaces) == "pid",
               let value = Int32(parts[1].trimmingCharacters(in: CharacterSet.whitespaces)), value > 0 {
                pid = value
            }
        }
        guard let pid else { return nil }
        return SsOwner(pid: pid, name: ssSanitizeName(rawName))
    }
}

private struct SsGroupKey: Hashable {
    let activityKind: PortActivityKind
    let transport: TransportProtocol
    let localPort: Int
    let ownerIdentity: String
}

private struct SsGroupAccumulator {
    var processName: String
    var pid: Int32?
    var endpoints: Set<Endpoint> = []
    var idIdentity = ""
}

private func ssMatchingParenthesis(in text: String, from open: String.Index) -> String.Index? {
    var depth = 0
    var quoted = false
    var escaped = false
    var index = open
    while index < text.endIndex {
        let character = text[index]
        if escaped {
            escaped = false
        } else if character == "\\" && quoted {
            escaped = true
        } else if character == "\"" {
            quoted.toggle()
        } else if !quoted, character == "(" {
            depth += 1
        } else if !quoted, character == ")" {
            depth -= 1
            if depth == 0 { return index }
        }
        index = text.index(after: index)
    }
    return nil
}

private func ssTopLevelParenthesizedSubstrings(_ text: Substring) -> [Substring] {
    var result: [Substring] = []
    var index = text.startIndex
    while index < text.endIndex {
        guard text[index] == "(" else {
            index = text.index(after: index)
            continue
        }
        let owned = String(text)
        let distance = text.distance(from: text.startIndex, to: index)
        let ownedOpen = owned.index(owned.startIndex, offsetBy: distance)
        guard let ownedClose = ssMatchingParenthesis(in: owned, from: ownedOpen) else { break }
        let closeDistance = owned.distance(from: owned.startIndex, to: ownedClose)
        let close = text.index(text.startIndex, offsetBy: closeDistance)
        result.append(text[index...close])
        index = text.index(after: close)
    }
    return result
}

private func ssQuotedString(_ text: String) -> (String, Substring)? {
    guard text.first == "\"" else { return nil }
    var value = ""
    var escaped = false
    var index = text.index(after: text.startIndex)
    while index < text.endIndex {
        let character = text[index]
        if escaped {
            value.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "\"" {
            return (value, text[text.index(after: index)...])
        } else {
            value.append(character)
        }
        index = text.index(after: index)
    }
    return nil
}

private func ssSplitTopLevel(_ text: Substring, separator: Character) -> [Substring] {
    var result: [Substring] = []
    var start = text.startIndex
    var quoted = false
    var escaped = false
    var index = start
    while index < text.endIndex {
        let character = text[index]
        if escaped { escaped = false }
        else if character == "\\" && quoted { escaped = true }
        else if character == "\"" { quoted.toggle() }
        else if character == separator && !quoted {
            result.append(text[start..<index])
            start = text.index(after: index)
        }
        index = text.index(after: index)
    }
    result.append(text[start..<text.endIndex])
    return result
}

private func ssMetadataValue(named name: String, in text: String) -> String? {
    for field in text.split(whereSeparator: \Character.isWhitespace) {
        let prefix = "\(name):"
        guard field.hasPrefix(prefix) else { continue }
        let value = field.dropFirst(prefix.count)
        guard !value.isEmpty, value.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else {
            continue
        }
        return String(value)
    }
    return nil
}

private func ssSanitizeName(_ raw: String) -> String {
    let replaced = String(raw.unicodeScalars.map { scalar in
        CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
    }.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = String(replaced.prefix(128))
    return bounded.isEmpty ? "Unknown process" : bounded
}

private func ssHex(_ string: String) -> String {
    string.utf8.map { String(format: "%02x", $0) }.joined()
}

private func ssNameSort(_ lhs: String, before rhs: String) -> Bool {
    let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
    if comparison != .orderedSame { return comparison == .orderedAscending }
    return lhs < rhs
}

private func ssEndpointSort(_ lhs: Endpoint, _ rhs: Endpoint) -> Bool {
    if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
    return lhs.rawValue < rhs.rawValue
}
