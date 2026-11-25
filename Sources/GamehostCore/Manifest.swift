import Foundation
import TOMLKit

/// A validated `gamehost.toml`.
public struct Manifest: Codable, Sendable, Equatable {
    public var schema: Int = 1
    public var name: String
    public var dir: String
    public var entry: String = "index.html"
    public var crossOriginIsolation: Bool = false
    /// Ordered list of custom headers (name, value), as written in the manifest (sorted by name for determinism).
    public var customHeaders: [Header] = []
    public var cacheMaxAge: Int = 0
    public var releasesKeep: Int = 5
    /// `[listing]`: how the site appears on the games index. Nil when the section is absent.
    public var listing: Listing?

    public struct Listing: Codable, Sendable, Equatable {
        public var title: String
        public var description: String?
        /// Path of a cover image inside the bundle.
        public var cover: String?
        /// Only listed sites appear on the index.
        public var listed: Bool = false
    }

    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
    }

    enum CodingKeys: String, CodingKey {
        case schema, name, dir, entry
        case crossOriginIsolation = "cross_origin_isolation"
        case customHeaders = "custom_headers"
        case cacheMaxAge = "cache_max_age"
        case releasesKeep = "releases_keep"
        case listing
    }

    public static let supportedSchemas: Set<Int> = [1]
    static let maxCacheAge = 31_536_000
    static let forbiddenHeaders: Set<String> = [
        "content-type", "content-encoding", "content-length", "etag",
        "transfer-encoding", "connection", "keep-alive", "upgrade", "trailer", "te",
    ]

    public init(name: String, dir: String) {
        self.name = name
        self.dir = dir
    }

    /// Parses and validates manifest text. Throws `APIError` (`manifest_invalid`) with every problem found.
    public static func parse(_ text: String, apiHostLabel: String) throws -> Manifest {
        try parse(text, reservedLabels: [apiHostLabel])
    }

    public static func parse(_ text: String, reservedLabels: Set<String>) throws -> Manifest {
        let root: TOMLTable
        do {
            root = try TOMLTable(string: text)
        } catch let e as TOMLParseError {
            throw APIError(.unprocessableEntity, "manifest_invalid", "gamehost.toml is not valid TOML.",
                           details: ["line \(e.source.begin.line), column \(e.source.begin.column): \(e.description)"])
        } catch {
            throw APIError(.unprocessableEntity, "manifest_invalid", "gamehost.toml is not valid TOML.")
        }

        var problems: [String] = []
        func unknown(_ table: TOMLTable, allowed: Set<String>, prefix: String) {
            for k in table.keys.sorted() where !allowed.contains(k) {
                problems.append("unknown key \"\(prefix)\(k)\"")
            }
        }
        func string(_ t: TOMLTable, _ k: String, _ path: String) -> String? {
            guard let v = t[k] else { return nil }
            guard let s = v.string else { problems.append("\(path) must be a string"); return nil }
            return s
        }
        func bool(_ t: TOMLTable, _ k: String, _ path: String) -> Bool? {
            guard let v = t[k] else { return nil }
            guard let b = v.bool else { problems.append("\(path) must be a boolean"); return nil }
            return b
        }
        func int(_ t: TOMLTable, _ k: String, _ path: String) -> Int? {
            guard let v = t[k] else { return nil }
            guard let i = v.int else { problems.append("\(path) must be an integer"); return nil }
            return i
        }
        func table(_ t: TOMLTable, _ k: String, _ path: String) -> TOMLTable? {
            guard let v = t[k] else { return nil }
            guard let tt = v.table else { problems.append("\(path) must be a table"); return nil }
            return tt
        }

        // Schema version first: an unknown version makes every other message noise.
        if let schemaValue = root["schema"] {
            guard let s = schemaValue.int, supportedSchemas.contains(s) else {
                throw APIError(.unprocessableEntity, "manifest_invalid", "Unsupported manifest schema version.",
                               details: ["schema must be one of: \(supportedSchemas.sorted().map(String.init).joined(separator: ", "))"])
            }
        }

        unknown(root, allowed: ["schema", "name", "dir", "entry", "headers", "cache", "releases", "listing"], prefix: "")

        var m = Manifest(name: "", dir: "")

        if let name = string(root, "name", "name") {
            m.name = name
            problems += Names.problems(siteName: name, reservedLabels: reservedLabels).map { "name: \($0)" }
        } else if root["name"] == nil {
            problems.append("name is required")
        }

        if let dir = string(root, "dir", "dir") {
            m.dir = dir
            if !Names.isSafeRelativePath(dir) { problems.append("dir must be a relative path without '..' or a leading '/'") }
        } else if root["dir"] == nil {
            problems.append("dir is required")
        }

        if let entry = string(root, "entry", "entry") {
            if Names.isSafeRelativePath(entry) && Names.isPlainPathCharset(entry) {
                m.entry = Names.normalize(entry)
            } else {
                problems.append("entry must be a relative path of A-Z a-z 0-9 . _ - / characters, without '..' or a leading '/'")
            }
        }

        if let headers = table(root, "headers", "headers") {
            unknown(headers, allowed: ["cross_origin_isolation", "custom"], prefix: "headers.")
            if let coi = bool(headers, "cross_origin_isolation", "headers.cross_origin_isolation") {
                m.crossOriginIsolation = coi
            }
            if let custom = table(headers, "custom", "headers.custom") {
                var seen = Set<String>()
                for key in custom.keys.sorted() {
                    let path = "headers.custom.\"\(key)\""
                    guard let value = custom[key]?.string else {
                        problems.append("\(path) must be a string")
                        continue
                    }
                    let headerProblems = Manifest.headerProblems(name: key, value: value)
                    if !headerProblems.isEmpty {
                        problems += headerProblems.map { "\(path): \($0)" }
                        continue
                    }
                    if !seen.insert(key.lowercased()).inserted {
                        problems.append("\(path): duplicate header name")
                        continue
                    }
                    m.customHeaders.append(Header(name: key, value: value))
                }
            }
        }

        if let cache = table(root, "cache", "cache") {
            unknown(cache, allowed: ["max_age"], prefix: "cache.")
            if let age = int(cache, "max_age", "cache.max_age") {
                if (0...maxCacheAge).contains(age) { m.cacheMaxAge = age }
                else { problems.append("cache.max_age must be between 0 and \(maxCacheAge)") }
            }
        }

        if let releases = table(root, "releases", "releases") {
            unknown(releases, allowed: ["keep"], prefix: "releases.")
            if let keep = int(releases, "keep", "releases.keep") {
                if (1...50).contains(keep) { m.releasesKeep = keep }
                else { problems.append("releases.keep must be between 1 and 50") }
            }
        }

        if let listing = table(root, "listing", "listing") {
            unknown(listing, allowed: ["title", "description", "cover", "listed"], prefix: "listing.")
            var l = Listing(title: m.name)
            if let title = string(listing, "title", "listing.title") {
                if let p = textProblem(title, max: 80, allowEmpty: false) { problems.append("listing.title \(p)") }
                else { l.title = title }
            }
            if let description = string(listing, "description", "listing.description") {
                if let p = textProblem(description, max: 300, allowEmpty: true) { problems.append("listing.description \(p)") }
                else if !description.isEmpty { l.description = description }
            }
            if let cover = string(listing, "cover", "listing.cover") {
                let ext = cover.split(separator: ".").last.map { $0.lowercased() } ?? ""
                if !Names.isSafeRelativePath(cover) || !Names.isPlainPathCharset(cover) {
                    problems.append("listing.cover must be a relative path of A-Z a-z 0-9 . _ - / characters, without '..' or a leading '/'")
                } else if !Names.coverExtensions.contains(ext) {
                    problems.append("listing.cover must be one of: \(Names.coverExtensions.sorted().joined(separator: ", "))")
                } else {
                    l.cover = Names.normalize(cover)
                }
            }
            if let listed = bool(listing, "listed", "listing.listed") { l.listed = listed }
            m.listing = l
        }

        if !problems.isEmpty {
            throw APIError(.unprocessableEntity, "manifest_invalid", "gamehost.toml failed validation.", details: problems)
        }
        return m
    }

    /// Display text for the games index: no control characters, bounded length. (It is HTML-escaped when rendered.)
    static func textProblem(_ s: String, max: Int, allowEmpty: Bool) -> String? {
        if !allowEmpty && s.trimmingCharacters(in: .whitespaces).isEmpty { return "must not be empty" }
        if s.count > max { return "must be at most \(max) characters" }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "must not contain control characters" }
        return nil
    }

    /// Validates a custom header. Values are restricted so that they can never alter the generated Caddy config:
    /// printable ASCII only, no CR/LF, no Caddy placeholder braces, no backslashes or backticks.
    static func headerProblems(name: String, value: String) -> [String] {
        var out: [String] = []
        let nameBytes = Array(name.utf8)
        func alnum(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
        if nameBytes.isEmpty || nameBytes.count > 100 || !nameBytes.allSatisfy({ alnum($0) || $0 == 45 }) {
            out.append("header name must match ^[A-Za-z0-9-]+$")
        } else if !alnum(nameBytes[0]) {
            out.append("header name must start with a letter or digit")
        }
        if forbiddenHeaders.contains(name.lowercased()) {
            out.append("header \(name) cannot be set from the manifest")
        }
        if value.contains("\r") || value.contains("\n") {
            out.append("header value must not contain CR or LF")
        } else if value.isEmpty || value.utf8.count > 2048 {
            out.append("header value must be 1-2048 bytes")
        } else if !value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) {
            out.append("header value must be printable ASCII")
        } else if value.contains(where: { "{}\\`".contains($0) }) {
            out.append("header value must not contain '{', '}', '\\' or '`'")
        }
        return out
    }
}
