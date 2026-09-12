import Darwin
import Foundation

struct SSHHostCatalog: Sendable {
    struct Limits: Equatable, Sendable {
        let maximumDepth: Int
        let maximumFiles: Int
        let maximumBytes: Int

        static let standard = Limits(
            maximumDepth: 16,
            maximumFiles: 256,
            maximumBytes: 4 * 1_024 * 1_024
        )
    }

    private let sshDirectory: URL
    private let environment: [String: String]
    private let limits: Limits

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        limits: Limits = .standard
    ) {
        sshDirectory = homeDirectory.appendingPathComponent(".ssh", isDirectory: true)
        self.environment = environment
        self.limits = limits
    }

    init(
        sshDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        limits: Limits = .standard
    ) {
        self.sshDirectory = sshDirectory
        self.environment = environment
        self.limits = limits
    }

    func load(previous: [SSHHost] = []) -> SSHHostCatalogResult {
        let rootURL = sshDirectory.appendingPathComponent("config", isDirectory: false)
        guard Self.itemExists(at: rootURL) else {
            return SSHHostCatalogResult(
                hosts: [],
                diagnostics: [],
                retainedPreviousCatalog: false,
                filesRead: 0,
                bytesRead: 0
            )
        }
        guard Self.isRegularFile(at: rootURL) else {
            return SSHHostCatalogResult(
                hosts: [],
                diagnostics: [.rootIsNotRegularFile],
                retainedPreviousCatalog: false,
                filesRead: 0,
                bytesRead: 0
            )
        }

        var state = LoadState()
        let rootRead = readConfiguration(at: rootURL, depth: 0, isRoot: true, state: &state)
        if rootRead == .failed {
            return SSHHostCatalogResult(
                hosts: previous,
                diagnostics: state.diagnostics,
                retainedPreviousCatalog: !previous.isEmpty,
                filesRead: state.filesRead,
                bytesRead: state.bytesRead
            )
        }

        let aliases = Self.sortedAndDeduplicated(state.aliases)
        return SSHHostCatalogResult(
            hosts: aliases.map(SSHHost.init(alias:)),
            diagnostics: state.diagnostics,
            retainedPreviousCatalog: false,
            filesRead: state.filesRead,
            bytesRead: state.bytesRead
        )
    }

    private func readConfiguration(
        at url: URL,
        depth: Int,
        isRoot: Bool,
        state: inout LoadState
    ) -> ReadResult {
        guard depth <= limits.maximumDepth else {
            state.append(.depthLimitReached)
            return .skipped
        }
        guard state.filesRead < limits.maximumFiles else {
            state.append(.fileLimitReached)
            return .skipped
        }

        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalPath = canonicalURL.path
        guard !state.visitedCanonicalPaths.contains(canonicalPath) else {
            state.append(.includeCycleSkipped)
            return .skipped
        }
        guard Self.isRegularFile(at: url) else {
            if isRoot {
                state.append(.rootIsNotRegularFile)
                return .failed
            }
            state.append(.includedFileIsNotRegular)
            return .skipped
        }

        let remainingBytes = max(0, limits.maximumBytes - state.bytesRead)
        let data: Data
        do {
            data = try Self.readBoundedData(from: url, maximumBytes: remainingBytes)
        } catch FileReadError.limitExceeded {
            state.append(.byteLimitReached)
            return isRoot ? .failed : .skipped
        } catch {
            state.append(isRoot ? .rootUnreadable : .includedFileUnreadable)
            return isRoot ? .failed : .skipped
        }

        state.visitedCanonicalPaths.insert(canonicalPath)
        state.filesRead += 1
        state.bytesRead += data.count

        let contents = String(decoding: data, as: UTF8.self)
        let logicalContents = Self.removingLineContinuations(from: contents)
        var insideMatch = false

        for rawLine in logicalContents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let directive = Self.parseDirective(String(rawLine)) else { continue }
            switch directive.keyword.lowercased() {
            case "match":
                insideMatch = true
            case "host":
                insideMatch = false
                state.aliases.append(contentsOf: directive.arguments.filter(Self.isSafeLiteralAlias))
            case "include" where !insideMatch:
                for pattern in directive.arguments {
                    for includedURL in expandedIncludeURLs(for: pattern) {
                        _ = readConfiguration(
                            at: includedURL,
                            depth: depth + 1,
                            isRoot: false,
                            state: &state
                        )
                    }
                }
            default:
                continue
            }
        }
        return .read
    }

    private func expandedIncludeURLs(for rawPattern: String) -> [URL] {
        guard !rawPattern.isEmpty, !rawPattern.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return []
        }
        guard let environmentExpanded = Self.expandEnvironment(in: rawPattern, environment: environment) else {
            return []
        }
        let expandedPath: String
        if environmentExpanded == "~" {
            expandedPath = sshDirectory.deletingLastPathComponent().path
        } else if environmentExpanded.hasPrefix("~/") {
            expandedPath = sshDirectory.deletingLastPathComponent()
                .appendingPathComponent(String(environmentExpanded.dropFirst(2)))
                .path
        } else if environmentExpanded.hasPrefix("/") {
            expandedPath = environmentExpanded
        } else {
            // OpenSSH resolves relative user-config Includes against ~/.ssh,
            // not against the directory of the file containing the directive.
            expandedPath = sshDirectory.appendingPathComponent(environmentExpanded).path
        }

        var result = glob_t()
        defer { globfree(&result) }
        let status = expandedPath.withCString {
            glob($0, GLOB_NOSORT, nil, &result)
        }
        guard status == 0, let pathVector = result.gl_pathv else { return [] }

        return (0..<Int(result.gl_pathc))
            .compactMap { pathVector[$0].map { URL(fileURLWithPath: String(cString: $0)) } }
            .sorted { $0.path < $1.path }
    }

    private static func parseDirective(_ line: String) -> (keyword: String, arguments: [String])? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        guard index < line.endIndex, line[index] != "#" else { return nil }

        let keywordStart = index
        while index < line.endIndex, !line[index].isWhitespace, line[index] != "=", line[index] != "#" {
            index = line.index(after: index)
        }
        guard keywordStart != index else { return nil }
        let keyword = String(line[keywordStart..<index])

        while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
        if index < line.endIndex, line[index] == "=" {
            index = line.index(after: index)
        }
        let remainder = String(line[index...])
        guard let arguments = tokenizeArguments(remainder) else { return nil }
        return (keyword, arguments)
    }

    private static func tokenizeArguments(_ input: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var hasToken = false
        var quote: Character?
        var escaping = false

        for character in input {
            if escaping {
                token.append(character)
                hasToken = true
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                hasToken = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                    hasToken = true
                }
                continue
            }
            if character == "\"" {
                quote = character
                hasToken = true
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                if hasToken {
                    tokens.append(token)
                    token = ""
                    hasToken = false
                }
            } else {
                token.append(character)
                hasToken = true
            }
        }
        guard !escaping, quote == nil else { return nil }
        if hasToken {
            tokens.append(token)
        }
        return tokens
    }

    private static func removingLineContinuations(from input: String) -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            if input[index] == "\\" {
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "\n" {
                    index = input.index(after: next)
                    continue
                }
                if next < input.endIndex, input[next] == "\r" {
                    let afterCarriageReturn = input.index(after: next)
                    if afterCarriageReturn < input.endIndex, input[afterCarriageReturn] == "\n" {
                        index = input.index(after: afterCarriageReturn)
                        continue
                    }
                }
            }
            output.append(input[index])
            index = input.index(after: index)
        }
        return output
    }

    private static func expandEnvironment(in input: String, environment: [String: String]) -> String? {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "$" else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }
            let openingBrace = input.index(after: index)
            guard openingBrace < input.endIndex, input[openingBrace] == "{" else {
                output.append("$")
                index = openingBrace
                continue
            }
            let nameStart = input.index(after: openingBrace)
            guard let closingBrace = input[nameStart...].firstIndex(of: "}") else {
                output.append("$")
                index = openingBrace
                continue
            }
            let name = String(input[nameStart..<closingBrace])
            if isEnvironmentName(name), let value = environment[name] {
                output.append(value)
            } else {
                // OpenSSH treats an unset Include environment variable as an
                // expansion error. It must not accidentally become a broader path.
                return nil
            }
            index = input.index(after: closingBrace)
        }
        return output
    }

    private static func isEnvironmentName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first)
        else { return false }
        return value.unicodeScalars.dropFirst().allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func isSafeLiteralAlias(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.first != "-", alias.first != "!" else { return false }
        guard !alias.contains("*"), !alias.contains("?"), !alias.contains("[") else { return false }
        return !alias.unicodeScalars.contains {
            $0.value == 0 || CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func sortedAndDeduplicated(_ aliases: [String]) -> [String] {
        let sorted = aliases.sorted { lhs, rhs in
            let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs < rhs
        }
        var seen: Set<String> = []
        return sorted.filter { alias in
            // SSH host names are case-insensitive. Use a locale-independent
            // fold for dedupe, while display ordering follows the product rule.
            seen.insert(asciiCaseFold(alias)).inserted
        }
    }

    private static func asciiCaseFold(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            if (65...90).contains(scalar.value), let folded = UnicodeScalar(scalar.value + 32) {
                return Character(folded)
            }
            return Character(scalar)
        })
    }

    private static func itemExists(at url: URL) -> Bool {
        var information = stat()
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return canonicalPath.withCString { lstat($0, &information) } == 0
    }

    private static func isRegularFile(at url: URL) -> Bool {
        var information = stat()
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalPath.withCString({ lstat($0, &information) }) == 0 else { return false }
        return information.st_mode & S_IFMT == S_IFREG
    }

    private static func readBoundedData(from url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var output = Data()
        while true {
            let allowance = maximumBytes - output.count
            let chunk = try handle.read(upToCount: min(64 * 1_024, max(1, allowance + 1))) ?? Data()
            guard !chunk.isEmpty else { return output }
            guard chunk.count <= allowance else { throw FileReadError.limitExceeded }
            output.append(chunk)
        }
    }
}

struct SSHHostCatalogResult: Equatable, Sendable {
    let hosts: [SSHHost]
    let diagnostics: [SSHHostCatalogDiagnostic]
    let retainedPreviousCatalog: Bool
    let filesRead: Int
    let bytesRead: Int
}

enum SSHHostCatalogDiagnostic: String, Equatable, Sendable {
    case rootIsNotRegularFile
    case rootUnreadable
    case includedFileIsNotRegular
    case includedFileUnreadable
    case includeCycleSkipped
    case depthLimitReached
    case fileLimitReached
    case byteLimitReached
}

private extension SSHHostCatalog {
    enum ReadResult {
        case read
        case skipped
        case failed
    }

    enum FileReadError: Error {
        case limitExceeded
    }

    struct LoadState {
        var aliases: [String] = []
        var diagnostics: [SSHHostCatalogDiagnostic] = []
        var visitedCanonicalPaths: Set<String> = []
        var filesRead = 0
        var bytesRead = 0

        mutating func append(_ diagnostic: SSHHostCatalogDiagnostic) {
            guard diagnostics.count < 64 else { return }
            diagnostics.append(diagnostic)
        }
    }
}
