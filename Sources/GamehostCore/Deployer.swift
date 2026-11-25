import Foundation
import Logging

public struct DeployTarget: Sendable {
    public var manifest: Manifest
    public var site: String
    public var preview: String?
    public var key: String
}

public struct DeployResult: Content, Sendable {
    public var site: String
    public var preview: String?
    public var url: String
    public var release: String
    public var files: Int
    public var bytes: Int64
    public var bytesBrotli: Int64
    public var previousRelease: String?

    enum CodingKeys: String, CodingKey {
        case site, preview, url, release, files, bytes
        case bytesBrotli = "bytes_brotli"
        case previousRelease = "previous_release"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(site, forKey: .site)
        try c.encode(preview, forKey: .preview) // explicit null
        try c.encode(url, forKey: .url)
        try c.encode(release, forKey: .release)
        try c.encode(files, forKey: .files)
        try c.encode(bytes, forKey: .bytes)
        try c.encode(bytesBrotli, forKey: .bytesBrotli)
        try c.encode(previousRelease, forKey: .previousRelease)
    }
}

public struct RollbackResult: Content, Sendable {
    public var site: String
    public var url: String
    public var release: String
    public var previousRelease: String?

    enum CodingKeys: String, CodingKey {
        case site, url, release
        case previousRelease = "previous_release"
    }
}

import Vapor

/// Owns every state change to sites: create, deploy, rollback, delete, preview sweep.
public final class Deployer: Sendable {
    public let config: Config
    public let storage: Storage
    public let tokens: TokenStore
    public let proxy: ProxyController
    public let locks = KeyLocks()
    let logger: Logger
    let precompressor: Precompressor

    public init(config: Config, storage: Storage, tokens: TokenStore, proxy: ProxyController, logger: Logger) {
        self.config = config
        self.storage = storage
        self.tokens = tokens
        self.proxy = proxy
        self.logger = logger
        self.precompressor = Precompressor(brotli: config.brotliBinary, gzip: config.gzipBinary)
    }

    static func busy() -> APIError {
        APIError(.conflict, "deploy_in_progress", "Another deploy or change to this site is in progress.")
    }

    // MARK: Sites

    public func createSite(name: String) async throws -> (SiteRecord, String) {
        let problems = Names.problems(siteName: name, reservedLabels: config.reservedSiteLabels)
        guard problems.isEmpty else {
            throw APIError(.unprocessableEntity, "name_invalid", "Invalid site name.", details: problems)
        }
        return try await locks.withKeys([name], busy: Deployer.busy()) {
            if FileUtil.exists(storage.siteDir(name)) {
                throw APIError(.conflict, "site_exists", "Site \"\(name)\" already exists.")
            }
            let record = SiteRecord(key: name, site: name, preview: nil, created: Date())
            try FileManager.default.createDirectory(at: storage.releasesDir(name), withIntermediateDirectories: true)
            try storage.saveSite(record)
            let (token, tokenRecord) = try await tokens.issue(for: name)
            logger.info("site created", metadata: ["event": "site_create", "site": .string(name), "token_id": .string(tokenRecord.id)])
            return (record, token)
        }
    }

    public func productionSite(_ name: String) throws -> SiteRecord {
        guard let s = storage.site(name), s.preview == nil else { throw APIError.siteNotFound(name) }
        return s
    }

    public func rotateToken(site name: String) async throws -> String {
        _ = try productionSite(name)
        let (token, record) = try await tokens.issue(for: name)
        logger.info("token rotated", metadata: ["event": "token_rotate", "site": .string(name), "token_id": .string(record.id)])
        return token
    }

    public func deleteSite(name: String, principal: Principal) async throws {
        _ = try productionSite(name)
        let previews = storage.previews(of: name).map(\.key)
        let keys = [name] + previews
        try await locks.withKeys(keys, busy: Deployer.busy()) {
            var changes: [String: String?] = [:]
            for k in keys { changes.updateValue(nil, forKey: k) }
            try await proxy.apply(changes)
            for k in keys { FileUtil.removeIfExists(storage.siteDir(k)) }
            try await tokens.revokeAll(for: name)
            refreshIndex()
            logger.info("site deleted", metadata: ["event": "site_delete", "site": .string(name),
                                                   "previews": .string(previews.joined(separator: ",")),
                                                   "by": .string(principal.logID)])
        }
    }

    public func deletePreview(site name: String, label: String, principal: Principal, reason: String = "api") async throws {
        let key = Names.key(site: name, preview: label)
        guard Names.isValidPreviewLabel(label), let rec = storage.site(key), rec.preview == label, rec.site == name else {
            throw APIError(.notFound, "preview_not_found", "Preview \"\(label)\" of site \"\(name)\" does not exist.")
        }
        try await locks.withKeys([key], busy: Deployer.busy()) {
            let removal: [String: String?] = [key: nil]
            try await proxy.apply(removal)
            FileUtil.removeIfExists(storage.siteDir(key))
            logger.info("preview deleted", metadata: ["event": "preview_delete", "site": .string(name),
                                                      "preview": .string(label), "by": .string(principal.logID),
                                                      "reason": .string(reason)])
        }
    }

    // MARK: Deploy

    /// Validates a deploy before any bundle bytes are processed.
    public func target(manifestText: String, preview: String?, principal: Principal) throws -> DeployTarget {
        let manifest = try Manifest.parse(manifestText, reservedLabels: config.reservedSiteLabels)
        if let preview, !Names.isValidPreviewLabel(preview) {
            throw APIError(.unprocessableEntity, "preview_label_invalid",
                           "Preview labels are 1-20 characters of a-z, 0-9 and '-', without leading, trailing or doubled '-'.")
        }
        guard principal.canAccess(site: manifest.name) else { throw APIError.forbidden() }
        _ = try productionSite(manifest.name)
        return DeployTarget(manifest: manifest, site: manifest.name, preview: preview,
                            key: Names.key(site: manifest.name, preview: preview))
    }

    public struct Metadata: Sendable {
        public var commit: String?
        public var ref: String?
        public var principal: Principal
        public init(commit: String? = nil, ref: String? = nil, principal: Principal) {
            self.commit = commit
            self.ref = ref
            self.principal = principal
        }
    }

    /// Runs the deploy algorithm (README "Deploy algorithm", steps 4-12). The caller holds the lock on `target.key`.
    /// `bundle` is a temp zip; it is always removed.
    public func deployLocked(_ target: DeployTarget, bundle: URL, bundleSha256: String, meta: Metadata) async throws -> DeployResult {
        let key = target.key
        let work = storage.tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var releaseDir: URL?
        var live = false
        defer {
            FileUtil.removeIfExists(bundle)
            FileUtil.removeIfExists(work)
            if !live, let releaseDir { FileUtil.removeIfExists(releaseDir) }
        }

        // 4. Unpack with safety checks.
        let limits = UnpackLimits(maxFiles: config.maxFiles, maxBytes: config.maxUnpackedBytes)
        let unpacked = try await FileUtil.blocking { try Unpacker.unpack(zip: bundle, into: work, limits: limits) }

        // 5. Entry must exist.
        guard unpacked[target.manifest.entry] != nil else {
            throw APIError(.unprocessableEntity, "entry_missing",
                           "The entry file \"\(target.manifest.entry)\" is not at the root of the bundle.")
        }
        if let cover = target.manifest.listing?.cover, unpacked[cover] == nil {
            throw APIError(.unprocessableEntity, "cover_missing", "The listing cover \"\(cover)\" is not in the bundle.")
        }

        // 6. Dedupe against the current release with hard links (keeps mtime, so ETags, stable).
        let current = storage.currentRelease(key)
        var index: [String: FileEntry] = [:]
        var toCompress: [(String, Int64)] = []
        for (path, file) in unpacked {
            var entry = FileEntry(sha256: file.sha256, size: file.size, br: false, gz: false, brSize: nil)
            if let current, let old = current.index[path], old.sha256 == file.sha256, old.size == file.size {
                let oldFiles = storage.releaseFiles(key, current.id)
                let newFile = work.appendingPathComponent(path)
                try FileManager.default.removeItem(at: newFile)
                try FileUtil.hardLink(from: oldFiles.appendingPathComponent(path), to: newFile)
                for ext in ["br", "gz"] where (ext == "br" ? old.br : old.gz) && unpacked[path + "." + ext] == nil {
                    let src = oldFiles.appendingPathComponent(path + "." + ext)
                    if FileUtil.exists(src) {
                        try FileUtil.hardLink(from: src, to: work.appendingPathComponent(path + "." + ext))
                        if ext == "br" { entry.br = true; entry.brSize = old.brSize } else { entry.gz = true }
                    }
                }
            } else if Precompressor.isEligible(path: path, size: file.size) {
                toCompress.append((path, file.size))
            }
            index[path] = entry
        }

        // 7. Precompress new files.
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let pc = precompressor
        try await withThrowingTaskGroup(of: (String, Precompressor.Outcome).self) { group in
            var it = toCompress.makeIterator()
            func next() -> Bool {
                guard let (path, size) = it.next() else { return false }
                let file = work.appendingPathComponent(path)
                let makeBr = unpacked[path + ".br"] == nil
                let makeGz = unpacked[path + ".gz"] == nil
                group.addTask { (path, try await pc.compress(file, size: size, makeBr: makeBr, makeGz: makeGz)) }
                return true
            }
            for _ in 0..<width where next() {}
            while let (path, outcome) = try await group.next() {
                index[path]?.br = outcome.br != nil
                index[path]?.gz = outcome.gz != nil
                index[path]?.brSize = outcome.br
                _ = next()
            }
        }

        // 8. Move into place.
        let releaseID = newReleaseID(key: key, bundleSha256: bundleSha256)
        let dir = storage.releaseDir(key, releaseID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        releaseDir = dir
        try FileManager.default.moveItem(at: work, to: storage.releaseFiles(key, releaseID))

        // 9. release.json
        let bytes = index.values.reduce(Int64(0)) { $0 + $1.size }
        let bytesBrotli = index.values.reduce(Int64(0)) { $0 + ($1.brSize ?? $1.size) }
        var manifest = target.manifest
        if target.preview != nil { manifest.releasesKeep = 1 }
        let record = ReleaseRecord(
            id: releaseID, created: Date(), manifest: manifest, commit: meta.commit, ref: meta.ref,
            bundleSha256: bundleSha256, deployer: meta.principal.logID,
            files: index.count, bytes: bytes, bytesBrotli: bytesBrotli, index: index
        )
        try FileUtil.writeJSON(record, to: storage.releaseFile(key, releaseID))

        if let preview = target.preview, storage.site(key) == nil {
            try storage.saveSite(SiteRecord(key: key, site: target.site, preview: preview, created: Date()))
        }

        // 10. Proxy config (validated and reloaded only when it changed).
        let snippet = CaddyConfig.siteSnippet(key: key, manifest: manifest, config: config, storage: storage)
        try await proxy.apply([key: snippet])

        // 11. Go live: atomic symlink swap.
        try storage.switchCurrent(key, to: releaseID)
        live = true

        // 12. Prune.
        prune(key: key, keep: manifest.releasesKeep, current: releaseID)
        if target.preview == nil { refreshIndex() }

        let result = DeployResult(
            site: target.site, preview: target.preview, url: config.url(forKey: key), release: releaseID,
            files: index.count, bytes: bytes, bytesBrotli: bytesBrotli, previousRelease: current?.id
        )
        logger.info("deploy", metadata: [
            "event": "deploy", "site": .string(target.site), "preview": .string(target.preview ?? ""),
            "release": .string(releaseID), "previous_release": .string(current?.id ?? ""),
            "files": .stringConvertible(index.count), "bytes": .stringConvertible(bytes),
            "compressed": .stringConvertible(toCompress.count), "commit": .string(meta.commit ?? ""),
            "ref": .string(meta.ref ?? ""), "by": .string(meta.principal.logID),
        ])
        return result
    }

    /// Convenience for callers that do not manage the lock themselves.
    public func deploy(_ target: DeployTarget, bundle: URL, bundleSha256: String, meta: Metadata) async throws -> DeployResult {
        do {
            return try await locks.withKeys([target.key], busy: Deployer.busy()) {
                try await deployLocked(target, bundle: bundle, bundleSha256: bundleSha256, meta: meta)
            }
        } catch {
            FileUtil.removeIfExists(bundle)
            throw error
        }
    }

    func newReleaseID(key: String, bundleSha256: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let base = "\(f.string(from: Date()))-\(bundleSha256.prefix(8))"
        var id = base
        var n = 1
        while FileUtil.exists(storage.releaseDir(key, id)) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    func prune(key: String, keep: Int, current: String) {
        let ids = storage.releaseIDs(key).reversed() // newest first
        var kept = 0
        for id in ids {
            if id == current || kept < keep - 1 {
                if id != current { kept += 1 }
                continue
            }
            FileUtil.removeIfExists(storage.releaseDir(key, id))
        }
        // Remove half-written release dirs (no release.json) left by a crash.
        let all = (try? FileManager.default.contentsOfDirectory(atPath: storage.releasesDir(key).path)) ?? []
        for id in all where !FileUtil.exists(storage.releaseFile(key, id)) && id != current {
            FileUtil.removeIfExists(storage.releaseDir(key, id))
        }
    }

    // MARK: Rollback

    public func rollback(site name: String, to requested: String?, principal: Principal) async throws -> RollbackResult {
        _ = try productionSite(name)
        return try await locks.withKeys([name], busy: Deployer.busy()) {
            let ids = storage.releaseIDs(name)
            guard let currentID = storage.currentReleaseID(name) else {
                throw APIError(.conflict, "no_release", "Site \"\(name)\" has no live release.")
            }
            let targetID: String
            if let requested {
                guard ids.contains(requested), !requested.contains("/") else {
                    throw APIError(.notFound, "release_not_found", "Release \"\(requested)\" does not exist (it may have been pruned).")
                }
                targetID = requested
            } else {
                guard let prev = ids.last(where: { $0 < currentID }) else {
                    throw APIError(.notFound, "release_not_found", "There is no release before the current one.")
                }
                targetID = prev
            }
            guard let release = storage.release(name, targetID) else {
                throw APIError(.notFound, "release_not_found", "Release \"\(targetID)\" does not exist.")
            }
            if targetID != currentID {
                let snippet = CaddyConfig.siteSnippet(key: name, manifest: release.manifest, config: config, storage: storage)
                try await proxy.apply([name: snippet])
                try storage.switchCurrent(name, to: targetID)
                refreshIndex()
            }
            logger.info("rollback", metadata: ["event": "rollback", "site": .string(name), "release": .string(targetID),
                                               "previous_release": .string(currentID), "by": .string(principal.logID)])
            return RollbackResult(site: name, url: config.url(forKey: name), release: targetID, previousRelease: currentID)
        }
    }

    // MARK: Maintenance

    /// Rewrites the games index. Never fails the change that triggered it: the site is already live.
    func refreshIndex() {
        do {
            try GamesIndex.write(config: config, storage: storage)
        } catch {
            logger.error("games index update failed", metadata: ["event": "index_failed", "error": "\(error)"])
        }
    }

    /// Deletes previews whose last deploy is older than the TTL.
    public func sweepPreviews(now: Date = Date()) async {
        let cutoff = now.addingTimeInterval(-Double(config.previewTTLDays) * 86_400)
        for rec in storage.allSites() {
            guard let label = rec.preview else { continue }
            let last = storage.currentRelease(rec.key)?.created ?? rec.created
            guard last < cutoff else { continue }
            do {
                try await deletePreview(site: rec.site, label: label, principal: .admin, reason: "ttl")
            } catch {
                logger.warning("preview sweep failed", metadata: ["preview": .string(rec.key), "error": "\(error)"])
            }
        }
    }

    /// Startup: clear temp files and re-render every snippet from its live release (the domain or TLS mode may
    /// have changed). Writes files only; Caddy is started afterwards.
    public func prepare() throws {
        try storage.ensureLayout()
        defer { refreshIndex() }
        try storage.sweepTmp()
        try FileUtil.atomicWrite(Data(CaddyConfig.mainCaddyfile(config, storage: storage).utf8), to: config.caddyfilePath)
        var live = Set<String>()
        for rec in storage.allSites() {
            guard let release = storage.currentRelease(rec.key) else { continue }
            live.insert(rec.key)
            let snippet = CaddyConfig.siteSnippet(key: rec.key, manifest: release.manifest, config: config, storage: storage)
            try FileUtil.atomicWrite(Data(snippet.utf8), to: storage.snippet(rec.key))
        }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: storage.snippetsDir.path)) ?? [] {
            guard file.hasSuffix(".caddy") else {
                if file.hasPrefix(".") { FileUtil.removeIfExists(storage.snippetsDir.appendingPathComponent(file)) }
                continue
            }
            if !live.contains(String(file.dropLast(".caddy".count))) {
                FileUtil.removeIfExists(storage.snippetsDir.appendingPathComponent(file))
            }
        }
    }
}
