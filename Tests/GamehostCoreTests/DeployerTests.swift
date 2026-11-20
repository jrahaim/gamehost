import Crypto
import Logging
import XCTest
@testable import GamehostCore

final class DeployerTests: XCTestCase {
    var dir: URL!
    var deployer: Deployer!
    var proxy: RecordingProxy!

    override func setUp() async throws {
        dir = tempDir()
        let config = try testConfig(dataDir: dir)
        let storage = Storage(root: dir)
        try storage.ensureLayout()
        proxy = RecordingProxy(storage: storage)
        let tokens = try TokenStore(file: storage.tokensFile, adminToken: config.adminToken)
        deployer = Deployer(config: config, storage: storage, tokens: tokens, proxy: proxy, logger: Logger(label: "test"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    var storage: Storage { deployer.storage }

    let bigJS = String(repeating: "console.log('hello world');\n", count: 200)

    func manifest(_ extra: String = "", name: String = "mygame") -> String {
        "name = \"\(name)\"\ndir = \"build/web\"\n" + extra
    }

    func deploy(_ files: [String: String], manifest text: String? = nil, preview: String? = nil,
                principal: Principal = .admin) async throws -> DeployResult {
        var z = RawZip()
        for (k, v) in files.sorted(by: { $0.key < $1.key }) { z.file(k, v) }
        let data = z.build()
        let url = storage.tmp.appendingPathComponent("\(UUID().uuidString).zip")
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = try deployer.target(manifestText: text ?? manifest(), preview: preview, principal: principal)
        return try await deployer.deploy(target, bundle: url, bundleSha256: sha, meta: .init(commit: "abc", ref: "main", principal: principal))
    }

    func inode(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as! NSNumber).uint64Value
    }

    func testCreateSiteAndTokens() async throws {
        let (site, token) = try await deployer.createSite(name: "mygame")
        XCTAssertEqual(site.key, "mygame")
        XCTAssertTrue(token.hasPrefix("gh_"))
        let principal = await deployer.tokens.authenticate(token)
        guard case .site(let name, _) = principal else { return XCTFail("token did not authenticate") }
        XCTAssertEqual(name, "mygame")
        let anything = await deployer.tokens.authenticate("gh_nope")
        XCTAssertNil(anything)
        let admin = await deployer.tokens.authenticate(String(repeating: "x", count: 40))
        XCTAssertEqual(admin, .admin)

        // Hash only at rest, mode 0600.
        let raw = try String(contentsOf: storage.tokensFile, encoding: .utf8)
        XCTAssertFalse(raw.contains(token))
        let mode = (try FileManager.default.attributesOfItem(atPath: storage.tokensFile.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode, 0o600)

        do {
            _ = try await deployer.createSite(name: "mygame")
            XCTFail("expected conflict")
        } catch let e as APIError { XCTAssertEqual(e.code, "site_exists") }

        let rotated = try await deployer.rotateToken(site: "mygame")
        let old = await deployer.tokens.authenticate(token)
        XCTAssertNil(old)
        let fresh = await deployer.tokens.authenticate(rotated)
        XCTAssertNotNil(fresh)
    }

    func testDeployDedupePrecompressAndPrune() async throws {
        _ = try await deployer.createSite(name: "mygame")
        let r1 = try await deploy(["index.html": "<html>v1</html>", "engine.js": bigJS, "game.pck": "pck-v1"],
                                  manifest: manifest("[releases]\nkeep = 2"))
        XCTAssertNil(r1.previousRelease)
        XCTAssertEqual(r1.files, 3)
        XCTAssertEqual(r1.url, "http://mygame.games.test:8081/")
        XCTAssertEqual(storage.currentReleaseID("mygame"), r1.release)
        let f1 = storage.releaseFiles("mygame", r1.release)
        XCTAssertTrue(FileUtil.exists(f1.appendingPathComponent("engine.js.br")))
        XCTAssertTrue(FileUtil.exists(f1.appendingPathComponent("engine.js.gz")))
        XCTAssertFalse(FileUtil.exists(f1.appendingPathComponent("index.html.br")), "files <= 1KB are not precompressed")
        XCTAssertLessThan(r1.bytesBrotli, r1.bytes)
        XCTAssertTrue(FileUtil.exists(storage.snippet("mygame")))

        // Sidecar mtime equals the original's.
        let mt = { (u: URL) in try FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as! Date }
        XCTAssertEqual(try mt(f1.appendingPathComponent("engine.js")), try mt(f1.appendingPathComponent("engine.js.br")))

        try await Task.sleep(for: .milliseconds(1100)) // distinct release timestamp
        let r2 = try await deploy(["index.html": "<html>v1</html>", "engine.js": bigJS, "game.pck": "pck-v2"],
                                  manifest: manifest("[releases]\nkeep = 2"))
        XCTAssertEqual(r2.previousRelease, r1.release)
        let f2 = storage.releaseFiles("mygame", r2.release)
        XCTAssertEqual(try inode(f1.appendingPathComponent("engine.js")), try inode(f2.appendingPathComponent("engine.js")))
        XCTAssertEqual(try inode(f1.appendingPathComponent("engine.js.br")), try inode(f2.appendingPathComponent("engine.js.br")))
        XCTAssertNotEqual(try inode(f1.appendingPathComponent("game.pck")), try inode(f2.appendingPathComponent("game.pck")))
        XCTAssertEqual(r2.bytesBrotli, r1.bytesBrotli, "dedupe carries the brotli size forward")

        try await Task.sleep(for: .milliseconds(1100))
        let r3 = try await deploy(["index.html": "<html>v3</html>", "engine.js": bigJS, "game.pck": "pck-v3"],
                                  manifest: manifest("[releases]\nkeep = 2"))
        XCTAssertEqual(storage.releaseIDs("mygame"), [r2.release, r3.release])
        // The pruned release's hard-linked files survive in the newer releases.
        XCTAssertEqual(try String(contentsOf: storage.releaseFiles("mygame", r3.release).appendingPathComponent("engine.js"), encoding: .utf8), bigJS)
    }

    func testRollbackRestoresContentAndHeaders() async throws {
        _ = try await deployer.createSite(name: "mygame")
        let r1 = try await deploy(["index.html": "v1"], manifest: manifest("[headers]\ncross_origin_isolation = true"))
        try await Task.sleep(for: .milliseconds(1100))
        let r2 = try await deploy(["index.html": "v2"])
        XCTAssertFalse(try String(contentsOf: storage.snippet("mygame"), encoding: .utf8).contains("Cross-Origin"))

        let rb = try await deployer.rollback(site: "mygame", to: nil, principal: .admin)
        XCTAssertEqual(rb.release, r1.release)
        XCTAssertEqual(rb.previousRelease, r2.release)
        XCTAssertEqual(try String(contentsOf: storage.servedRoot("mygame").appendingPathComponent("index.html"), encoding: .utf8), "v1")
        XCTAssertTrue(try String(contentsOf: storage.snippet("mygame"), encoding: .utf8).contains("Cross-Origin-Opener-Policy"))

        let forward = try await deployer.rollback(site: "mygame", to: r2.release, principal: .admin)
        XCTAssertEqual(forward.release, r2.release)

        do {
            _ = try await deployer.rollback(site: "mygame", to: "20000101T000000Z-deadbeef", principal: .admin)
            XCTFail("expected 404")
        } catch let e as APIError { XCTAssertEqual(e.code, "release_not_found") }
        do {
            _ = try await deployer.rollback(site: "mygame", to: "../../etc", principal: .admin)
            XCTFail("expected 404")
        } catch let e as APIError { XCTAssertEqual(e.code, "release_not_found") }
    }

    func testFailuresLeaveLiveSiteUntouched() async throws {
        _ = try await deployer.createSite(name: "mygame")
        let r1 = try await deploy(["index.html": "v1"])

        do {
            _ = try await deploy(["other.html": "x"])
            XCTFail("expected entry_missing")
        } catch let e as APIError { XCTAssertEqual(e.code, "entry_missing") }

        proxy.failNext = true
        do {
            _ = try await deploy(["index.html": "v2"], manifest: manifest("[headers]\ncross_origin_isolation = true"))
            XCTFail("expected proxy failure")
        } catch let e as APIError { XCTAssertEqual(e.code, "proxy_config_failed") }

        XCTAssertEqual(storage.currentReleaseID("mygame"), r1.release)
        XCTAssertEqual(storage.releaseIDs("mygame"), [r1.release])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.tmp.path), [])
    }

    func testAuthorizationAndExistence() async throws {
        _ = try await deployer.createSite(name: "alpha")
        _ = try await deployer.createSite(name: "beta")
        XCTAssertThrowsError(try deployer.target(manifestText: manifest(name: "beta"), preview: nil,
                                                 principal: .site(name: "alpha", tokenID: "t"))) {
            XCTAssertEqual(($0 as? APIError)?.status, .forbidden)
        }
        XCTAssertThrowsError(try deployer.target(manifestText: manifest(name: "never"), preview: nil, principal: .admin)) {
            XCTAssertEqual(($0 as? APIError)?.code, "site_not_found")
        }
        XCTAssertThrowsError(try deployer.target(manifestText: manifest(name: "alpha"), preview: "Bad_Label", principal: .admin)) {
            XCTAssertEqual(($0 as? APIError)?.code, "preview_label_invalid")
        }
    }

    func testConcurrentDeploysConflict() async throws {
        _ = try await deployer.createSite(name: "mygame")
        let target = try deployer.target(manifestText: manifest(), preview: nil, principal: .admin)
        let held = await deployer.locks.tryAcquire([target.key])
        XCTAssertTrue(held)
        do {
            _ = try await deploy(["index.html": "v1"])
            XCTFail("expected 409")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "deploy_in_progress")
            XCTAssertEqual(e.status, .conflict)
        }
        await deployer.locks.release([target.key])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.tmp.path), [])
    }

    func testPreviewsAndDelete() async throws {
        _ = try await deployer.createSite(name: "mygame")
        _ = try await deploy(["index.html": "prod"])
        let p = try await deploy(["index.html": "pr"], preview: "feature-x", principal: .site(name: "mygame", tokenID: "t"))
        XCTAssertEqual(p.preview, "feature-x")
        XCTAssertEqual(p.url, "http://mygame--feature-x.games.test:8081/")
        XCTAssertEqual(storage.previews(of: "mygame").map(\.key), ["mygame--feature-x"])
        XCTAssertTrue(FileUtil.exists(storage.snippet("mygame--feature-x")))
        try await Task.sleep(for: .milliseconds(1100))
        _ = try await deploy(["index.html": "pr2"], manifest: manifest("[releases]\nkeep = 5"), preview: "feature-x")
        XCTAssertEqual(storage.releaseIDs("mygame--feature-x").count, 1, "previews keep one release")

        // TTL sweep: not yet expired, then expired.
        await deployer.sweepPreviews()
        XCTAssertEqual(storage.previews(of: "mygame").count, 1)
        await deployer.sweepPreviews(now: Date().addingTimeInterval(15 * 86_400))
        XCTAssertEqual(storage.previews(of: "mygame").count, 0)
        XCTAssertFalse(FileUtil.exists(storage.snippet("mygame--feature-x")))

        _ = try await deploy(["index.html": "pr"], preview: "other")
        try await deployer.deleteSite(name: "mygame", principal: .admin)
        XCTAssertEqual(storage.allSites().count, 0)
        XCTAssertFalse(FileUtil.exists(storage.snippet("mygame")))
        XCTAssertFalse(FileUtil.exists(storage.snippet("mygame--other")))
    }

    func testPrepareSweepsTmpAndRerendersSnippets() async throws {
        _ = try await deployer.createSite(name: "mygame")
        _ = try await deploy(["index.html": "v1"])
        try Data("junk".utf8).write(to: storage.tmp.appendingPathComponent("leftover.zip"))
        try Data("stale".utf8).write(to: storage.snippet("gone"))
        try "tampered".write(to: storage.snippet("mygame"), atomically: true, encoding: .utf8)
        try deployer.prepare()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.tmp.path), [])
        XCTAssertFalse(FileUtil.exists(storage.snippet("gone")))
        XCTAssertTrue(try String(contentsOf: storage.snippet("mygame"), encoding: .utf8).contains("mygame.games.test"))
        XCTAssertTrue(FileUtil.exists(deployer.config.caddyfilePath))
    }
}
