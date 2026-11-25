import Foundation

/// `site.json`
public struct SiteRecord: Codable, Sendable {
    /// Storage key (`name` or `name--label`).
    public var key: String
    /// Production site name.
    public var site: String
    /// Preview label, nil for production.
    public var preview: String?
    public var created: Date
}

/// Per-file entry stored in `release.json`, used for dedupe on the next deploy.
public struct FileEntry: Codable, Sendable, Equatable {
    public var sha256: String
    public var size: Int64
    /// True when gamehost generated `<path>.br` / `<path>.gz` for this file.
    public var br: Bool
    public var gz: Bool
    public var brSize: Int64?
}

/// `release.json`
public struct ReleaseRecord: Codable, Sendable {
    public var id: String
    public var created: Date
    public var manifest: Manifest
    public var commit: String?
    public var ref: String?
    public var bundleSha256: String
    public var deployer: String
    public var files: Int
    public var bytes: Int64
    public var bytesBrotli: Int64
    public var index: [String: FileEntry]

    enum CodingKeys: String, CodingKey {
        case id, created, manifest, commit, ref, deployer, files, bytes, index
        case bundleSha256 = "bundle_sha256"
        case bytesBrotli = "bytes_brotli"
    }
}

/// On-disk layout under the data volume. See README "On-disk layout".
public struct Storage: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    public var sitesDir: URL { root.appendingPathComponent("sites", isDirectory: true) }
    public var caddyDir: URL { root.appendingPathComponent("caddy", isDirectory: true) }
    public var snippetsDir: URL { caddyDir.appendingPathComponent("sites", isDirectory: true) }
    public var caddyState: URL { caddyDir.appendingPathComponent("state", isDirectory: true) }
    public var tokensFile: URL { root.appendingPathComponent("tokens.json") }
    /// The generated games index (`index.html`, `index.json`), served on `GAMEHOST_INDEX_HOST`.
    public var indexDir: URL { root.appendingPathComponent("index", isDirectory: true) }

    public func siteDir(_ key: String) -> URL { sitesDir.appendingPathComponent(key, isDirectory: true) }
    public func siteFile(_ key: String) -> URL { siteDir(key).appendingPathComponent("site.json") }
    public func releasesDir(_ key: String) -> URL { siteDir(key).appendingPathComponent("releases", isDirectory: true) }
    public func releaseDir(_ key: String, _ id: String) -> URL { releasesDir(key).appendingPathComponent(id, isDirectory: true) }
    public func releaseFiles(_ key: String, _ id: String) -> URL { releaseDir(key, id).appendingPathComponent("files", isDirectory: true) }
    public func releaseFile(_ key: String, _ id: String) -> URL { releaseDir(key, id).appendingPathComponent("release.json") }
    public func currentLink(_ key: String) -> URL { siteDir(key).appendingPathComponent("current") }
    /// The path Caddy serves for a site: `current/files`.
    public func servedRoot(_ key: String) -> URL { currentLink(key).appendingPathComponent("files", isDirectory: true) }
    public func snippet(_ key: String) -> URL { snippetsDir.appendingPathComponent("\(key).caddy") }

    public func ensureLayout() throws {
        for d in [tmp, sitesDir, snippetsDir, caddyState, indexDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// Empties `tmp/`. Called at startup.
    public func sweepTmp() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: Sites

    public func site(_ key: String) -> SiteRecord? {
        try? FileUtil.readJSON(SiteRecord.self, from: siteFile(key))
    }

    public func saveSite(_ record: SiteRecord) throws {
        try FileUtil.writeJSON(record, to: siteFile(record.key))
    }

    public func allSites() -> [SiteRecord] {
        let keys = (try? FileManager.default.contentsOfDirectory(atPath: sitesDir.path)) ?? []
        return keys.sorted().compactMap { site($0) }
    }

    public func previews(of name: String) -> [SiteRecord] {
        allSites().filter { $0.site == name && $0.preview != nil }
    }

    // MARK: Releases

    public func currentReleaseID(_ key: String) -> String? {
        guard let target = FileUtil.readLink(currentLink(key)) else { return nil }
        // target is "releases/<id>"
        return target.split(separator: "/").last.map(String.init)
    }

    public func release(_ key: String, _ id: String) -> ReleaseRecord? {
        try? FileUtil.readJSON(ReleaseRecord.self, from: releaseFile(key, id))
    }

    /// Release IDs, oldest first.
    public func releaseIDs(_ key: String) -> [String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: releasesDir(key).path)) ?? []
        return ids.filter { !$0.hasPrefix(".") && FileUtil.exists(releaseFile(key, $0)) }.sorted()
    }

    public func currentRelease(_ key: String) -> ReleaseRecord? {
        currentReleaseID(key).flatMap { release(key, $0) }
    }

    public func switchCurrent(_ key: String, to id: String) throws {
        try FileUtil.atomicSymlink(target: "releases/\(id)", link: currentLink(key))
    }
}
