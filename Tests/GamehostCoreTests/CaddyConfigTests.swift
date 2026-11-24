import XCTest
@testable import GamehostCore

final class CaddyConfigTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func render(_ toml: String, mode: String = "external") throws -> String {
        let config = try testConfig(dataDir: dir, mode: mode)
        let m = try Manifest.parse(toml, apiHostLabel: config.apiHostFirstLabel)
        return CaddyConfig.siteSnippet(key: m.name, manifest: m, config: config, storage: Storage(root: dir))
    }

    func testDefaultSnippet() throws {
        let s = try render("name = \"mygame\"\ndir = \"x\"")
        XCTAssertTrue(s.contains("http://mygame.games.test:8081 {"))
        XCTAssertTrue(s.contains("root * \"\(dir.path)/sites/mygame/current/files\""))
        XCTAssertTrue(s.contains("Cache-Control \"no-cache\""))
        XCTAssertTrue(s.contains("X-Content-Type-Options \"nosniff\""))
        XCTAssertTrue(s.contains("precompressed br gzip"))
        XCTAssertFalse(s.contains("Cross-Origin"))
        XCTAssertFalse(s.contains("rewrite"))
    }

    func testPerSiteAddressAndOptions() throws {
        let s = try render("""
        name = "mygame"
        dir = "x"
        entry = "web/game.html"
        [headers]
        cross_origin_isolation = true
        [cache]
        max_age = 300
        """, mode: "per-site")
        XCTAssertTrue(s.contains("\nmygame.games.test {"))
        XCTAssertTrue(s.contains("Cross-Origin-Opener-Policy \"same-origin\""))
        XCTAssertTrue(s.contains("Cross-Origin-Embedder-Policy \"require-corp\""))
        XCTAssertTrue(s.contains("Cache-Control \"public, max-age=300\""))
        XCTAssertTrue(s.contains("rewrite / \"/web/game.html\""))
    }

    func testQuotesAreEscaped() throws {
        let s = try render("name = \"a\"\ndir = \"x\"\n[headers.custom]\nPermissions-Policy = 'camera=(self \"https://x.test\")'")
        XCTAssertTrue(s.contains(#"Permissions-Policy "camera=(self \"https://x.test\")""#), s)
    }

    /// Round-trips hostile-but-valid header values through Caddy's own parser, when a Caddy binary is available,
    /// and checks that the snippet still contains exactly one site with exactly the expected headers.
    func testInjectionAttemptsThroughCaddy() throws {
        guard let caddy = ProcessInfo.processInfo.environment["GAMEHOST_TEST_CADDY"] else {
            throw XCTSkip("set GAMEHOST_TEST_CADDY to a caddy binary to run")
        }
        let value = #"x" respond "pwned" # trailing"#
        let toml = "name = \"a\"\ndir = \"x\"\n[headers.custom]\nX-Test = '\(value)'\nX-Second = 'import /etc/passwd'"
        let snippet = try render(toml)
        let file = dir.appendingPathComponent("test.caddy")
        try snippet.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: caddy)
        p.arguments = ["adapt", "--config", file.path, "--adapter", "caddyfile"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("static_response"), "a respond directive was injected: \(json)")
        // The whole value must arrive intact as a single header value.
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func find(_ any: Any) -> [String: [String]]? {
            if let d = any as? [String: Any] {
                if let set = d["set"] as? [String: [String]], set["X-Test"] != nil { return set }
                for v in d.values { if let r = find(v) { return r } }
            } else if let a = any as? [Any] {
                for v in a { if let r = find(v) { return r } }
            }
            return nil
        }
        let set = try XCTUnwrap(find(obj), json)
        XCTAssertEqual(set["X-Test"], [value])
        XCTAssertEqual(set["X-Second"], ["import /etc/passwd"])
    }

    func testRendererRefusesUnvalidatedValues() {
        // Guard against future callers bypassing validation: the precondition is the last line of defence.
        XCTAssertFalse(Manifest.headerProblems(name: "X", value: "a\nb").isEmpty)
        XCTAssertFalse(Manifest.headerProblems(name: "X", value: "{http.request.header.Authorization}").isEmpty)
    }

    func testMainCaddyfile() throws {
        let config = try testConfig(dataDir: dir, mode: "external", extra: ["GAMEHOST_MAX_UPLOAD_MB": "10", "GAMEHOST_TRUSTED_PROXIES": "10.0.0.0/8"])
        let s = CaddyConfig.mainCaddyfile(config, storage: Storage(root: dir))
        XCTAssertTrue(s.contains("http://deploy.games.test:8081 {"))
        XCTAssertTrue(s.contains("max_size \(10 * 1024 * 1024 + 1024 * 1024)"))
        XCTAssertTrue(s.contains("auto_https off"))
        XCTAssertTrue(s.contains("admin localhost:2019"))
        XCTAssertTrue(s.contains("trusted_proxies static 10.0.0.0/8"))
        XCTAssertTrue(s.contains("import \"\(dir.path)/caddy/sites/*.caddy\""))
        XCTAssertTrue(s.contains("http://:8081 {\n\trespond 404"))
    }

    func testConfigValidation() throws {
        XCTAssertThrowsError(try testConfig(dataDir: dir, extra: ["GAMEHOST_ADMIN_TOKEN": "short"]))
        XCTAssertThrowsError(try testConfig(dataDir: dir, extra: ["GAMEHOST_BASE_DOMAIN": "bad domain"]))
        XCTAssertThrowsError(try testConfig(dataDir: dir, mode: "bogus"))
        XCTAssertThrowsError(try testConfig(dataDir: dir, mode: "per-site", extra: ["GAMEHOST_ACME_EMAIL": ""]))
        XCTAssertThrowsError(try testConfig(dataDir: dir, extra: ["GAMEHOST_TRUSTED_PROXIES": "10.0.0.0/8 {"]))
        let c = try testConfig(dataDir: dir, extra: ["GAMEHOST_API_HOST": "ship.games.test"])
        XCTAssertEqual(c.apiHostFirstLabel, "ship")
    }

    func testPublicURLs() throws {
        // external mode defaults to https with no port: the fronting proxy terminates TLS.
        XCTAssertEqual(try testConfig(dataDir: dir, mode: "external").url(forKey: "mygame"), "https://mygame.games.test/")
        XCTAssertEqual(try testConfig(dataDir: dir, mode: "per-site").url(forKey: "a--pr-1"), "https://a--pr-1.games.test/")
        let local = try testConfig(dataDir: dir, mode: "external",
                                   extra: ["GAMEHOST_PUBLIC_SCHEME": "http", "GAMEHOST_PUBLIC_PORT": "18081"])
        XCTAssertEqual(local.url(forKey: "mygame"), "http://mygame.games.test:18081/")
        let defaultPort = try testConfig(dataDir: dir, mode: "external", extra: ["GAMEHOST_PUBLIC_PORT": "443"])
        XCTAssertEqual(defaultPort.url(forKey: "mygame"), "https://mygame.games.test/")
        XCTAssertThrowsError(try testConfig(dataDir: dir, mode: "external", extra: ["GAMEHOST_PUBLIC_SCHEME": "ftp"]))
        XCTAssertThrowsError(try testConfig(dataDir: dir, mode: "external", extra: ["GAMEHOST_PUBLIC_PORT": "70000"]))
        XCTAssertThrowsError(try testConfig(dataDir: dir, mode: "per-site", extra: ["GAMEHOST_PUBLIC_SCHEME": "http"]))
    }
}
