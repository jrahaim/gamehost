import Crypto
import Logging
import XCTest
@testable import GamehostCore

final class GamesIndexTests: XCTestCase {
    var dir: URL!
    var deployer: Deployer!

    override func setUp() async throws {
        dir = tempDir()
        let config = try testConfig(dataDir: dir, extra: ["GAMEHOST_INDEX_HOST": "arcade.games.test",
                                                          "GAMEHOST_INDEX_TITLE": "Portside & Co"])
        let storage = Storage(root: dir)
        try storage.ensureLayout()
        let tokens = try TokenStore(file: storage.tokensFile, adminToken: config.adminToken)
        deployer = Deployer(config: config, storage: storage, tokens: tokens, proxy: RecordingProxy(storage: storage),
                            logger: Logger(label: "test"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    var storage: Storage { deployer.storage }

    @discardableResult
    func deploy(_ name: String, listing: String, files: [String: String] = ["index.html": "<p>hi</p>", "cover.png": "png"],
                preview: String? = nil) async throws -> DeployResult {
        var z = RawZip()
        for (k, v) in files.sorted(by: { $0.key < $1.key }) { z.file(k, v) }
        let data = z.build()
        let url = storage.tmp.appendingPathComponent("\(UUID().uuidString).zip")
        try data.write(to: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let text = "name = \"\(name)\"\ndir = \"build/web\"\n" + listing
        let target = try deployer.target(manifestText: text, preview: preview, principal: .admin)
        return try await deployer.deploy(target, bundle: url, bundleSha256: sha, meta: .init(principal: .admin))
    }

    func index() throws -> GamesIndex.Document {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GamesIndex.Document.self, from: Data(contentsOf: storage.indexDir.appendingPathComponent("index.json")))
    }

    func indexHTML() throws -> String {
        try String(contentsOf: storage.indexDir.appendingPathComponent("index.html"), encoding: .utf8)
    }

    func testListedSitesAppearPreviewsAndUnlistedDoNot() async throws {
        for n in ["alpha", "beta", "gamma"] { _ = try await deployer.createSite(name: n) }
        let r = try await deploy("alpha", listing: """
            [listing]
            title = "Alpha <Wars>"
            description = "Ships & \\"wind\\""
            cover = "cover.png"
            listed = true
            """)
        try await deploy("beta", listing: "[listing]\ntitle = \"Beta\"\n")            // listed defaults to false
        try await deploy("gamma", listing: "")                                       // no [listing]
        try await deploy("alpha", listing: "[listing]\ntitle = \"Preview\"\nlisted = true\n", preview: "pr-1")

        let doc = try index()
        XCTAssertEqual(doc.title, "Portside & Co")
        XCTAssertEqual(doc.games.map(\.name), ["alpha"])
        let g = doc.games[0]
        XCTAssertEqual(g.title, "Alpha <Wars>")
        XCTAssertEqual(g.url, "https://alpha.games.test/")
        XCTAssertEqual(g.cover, "https://alpha.games.test/cover.png?v=\(r.release)")

        let html = try indexHTML()
        XCTAssertTrue(html.contains("<title>Portside &amp; Co</title>"))
        XCTAssertTrue(html.contains("Alpha &lt;Wars&gt;"))
        XCTAssertTrue(html.contains("Ships &amp; &quot;wind&quot;"))
        XCTAssertFalse(html.contains("<Wars>"))
        XCTAssertFalse(html.contains("Preview"))
    }

    func testRollbackAndDeleteUpdateTheIndex() async throws {
        _ = try await deployer.createSite(name: "alpha")
        try await deploy("alpha", listing: "[listing]\ntitle = \"Old\"\nlisted = true\n")
        try await deploy("alpha", listing: "[listing]\ntitle = \"New\"\nlisted = true\n")
        XCTAssertEqual(try index().games.map(\.title), ["New"])

        _ = try await deployer.rollback(site: "alpha", to: nil, principal: .admin)
        XCTAssertEqual(try index().games.map(\.title), ["Old"])

        try await deployer.deleteSite(name: "alpha", principal: .admin)
        XCTAssertEqual(try index().games.count, 0)
        XCTAssertTrue(try indexHTML().contains("No games are listed yet."))
    }

    func testCoverMustBeInTheBundle() async throws {
        _ = try await deployer.createSite(name: "alpha")
        do {
            try await deploy("alpha", listing: "[listing]\ntitle = \"A\"\ncover = \"art/cover.png\"\nlisted = true\n")
            XCTFail("expected cover_missing")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "cover_missing")
        }
        XCTAssertNil(storage.currentReleaseID("alpha"))
    }

    func testIndexHostLabelIsReservedAndPrepareWritesIndex() async throws {
        do {
            _ = try await deployer.createSite(name: "arcade")
            XCTFail("expected the index host's label to be reserved")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "name_invalid")
        }
        try deployer.prepare()
        XCTAssertEqual(try index().games.count, 0)
        let caddyfile = CaddyConfig.mainCaddyfile(deployer.config, storage: storage)
        XCTAssertTrue(caddyfile.contains("http://arcade.games.test:8081 {\n\troot * \"\(storage.indexDir.path)\""))
    }

    func testListingValidation() throws {
        func parse(_ listing: String) throws -> Manifest {
            try Manifest.parse("name = \"a\"\ndir = \"x\"\n[listing]\n" + listing, reservedLabels: ["deploy"])
        }
        XCTAssertEqual(try parse("").listing?.title, "a", "title defaults to the site name")
        XCTAssertEqual(try parse("listed = true").listing?.listed, true)
        XCTAssertEqual(try parse("cover = \"./img/c.PNG\"").listing?.cover, "img/c.PNG")
        for bad in ["title = \"\"", "title = \"\(String(repeating: "x", count: 81))\"", "description = \"a\\nb\"",
                    "cover = \"../c.png\"", "cover = \"c.svg\"", "cover = \"c d.png\"", "listed = \"yes\"", "bogus = 1"] {
            XCTAssertThrowsError(try parse(bad), bad)
        }
    }

    func testIndexDisabledByDefault() throws {
        let c = try testConfig(dataDir: dir)
        XCTAssertNil(c.indexHost)
        XCTAssertFalse(CaddyConfig.mainCaddyfile(c, storage: storage).contains("Games index"))
        XCTAssertThrowsError(try testConfig(dataDir: dir, extra: ["GAMEHOST_INDEX_HOST": "deploy.games.test"]))
        XCTAssertThrowsError(try testConfig(dataDir: dir, extra: ["GAMEHOST_INDEX_HOST": "not a host"]))
    }
}
