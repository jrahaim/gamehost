import XCTest
@testable import GamehostCore

final class ManifestTests: XCTestCase {
    func parse(_ s: String) throws -> Manifest { try Manifest.parse(s, apiHostLabel: "deploy") }

    func problems(_ s: String) -> [String] {
        do {
            _ = try parse(s)
            return []
        } catch let e as APIError {
            XCTAssertEqual(e.code, "manifest_invalid")
            return e.details.isEmpty ? [e.message] : e.details
        } catch {
            return ["\(error)"]
        }
    }

    func testDefaults() throws {
        let m = try parse(#"name = "mygame"\#ndir = "build/web""#)
        XCTAssertEqual(m.name, "mygame")
        XCTAssertEqual(m.entry, "index.html")
        XCTAssertFalse(m.crossOriginIsolation)
        XCTAssertEqual(m.cacheMaxAge, 0)
        XCTAssertEqual(m.releasesKeep, 5)
        XCTAssertEqual(m.customHeaders, [])
    }

    func testFullExample() throws {
        let m = try parse("""
        name = "my-game2"
        dir = "build/web"
        entry = "game.html"
        [headers]
        cross_origin_isolation = true
        [headers.custom]
        "Permissions-Policy" = "gamepad=(self)"
        X-Frame-Options = "DENY"
        [cache]
        max_age = 60
        [releases]
        keep = 2
        """)
        XCTAssertTrue(m.crossOriginIsolation)
        XCTAssertEqual(m.entry, "game.html")
        XCTAssertEqual(m.customHeaders.map(\.name), ["Permissions-Policy", "X-Frame-Options"])
        XCTAssertEqual(m.cacheMaxAge, 60)
        XCTAssertEqual(m.releasesKeep, 2)
    }

    func testRequiredAndUnknownKeys() {
        XCTAssertTrue(problems(#"dir = "x""#).contains("name is required"))
        XCTAssertTrue(problems(#"name = "a""#).contains("dir is required"))
        XCTAssertTrue(problems("name = \"a\"\ndir = \"x\"\nentyr = \"index.html\"").contains("unknown key \"entyr\""))
        XCTAssertTrue(problems("name = \"a\"\ndir = \"x\"\n[cache]\nmaxage = 1").contains("unknown key \"cache.maxage\""))
        XCTAssertTrue(problems("name = \"a\"\ndir = \"x\"\n[headers]\ncoi = true").contains("unknown key \"headers.coi\""))
    }

    func testSchemaVersion() throws {
        _ = try parse("schema = 1\nname = \"a\"\ndir = \"x\"")
        XCTAssertEqual(problems("schema = 2\nname = \"a\"\ndir = \"x\"").first, "schema must be one of: 1")
    }

    func testNames() {
        for bad in ["", "-a", "a-", "A", "a_b", "a--b", "deploy", "api", "www", "admin", String(repeating: "a", count: 41), "é"] {
            XCTAssertFalse(problems("name = \"\(bad)\"\ndir = \"x\"").isEmpty, bad)
        }
        for good in ["a", "0", "a-b", "a1-2b", String(repeating: "a", count: 40)] {
            XCTAssertTrue(problems("name = \"\(good)\"\ndir = \"x\"").isEmpty, good)
        }
        // The API host's first label is reserved too.
        XCTAssertThrowsError(try Manifest.parse("name = \"ship\"\ndir = \"x\"", apiHostLabel: "ship"))
    }

    func testPaths() {
        for bad in ["/abs", "../up", "a/../../b", "a\\b"] {
            XCTAssertFalse(problems("name = \"a\"\ndir = \"\(bad.replacingOccurrences(of: "\\", with: "\\\\"))\"").isEmpty, bad)
            XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\nentry = \"\(bad.replacingOccurrences(of: "\\", with: "\\\\"))\"").isEmpty, bad)
        }
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\nentry = \"my game.html\"").isEmpty)
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\nentry = \"a\\\"b.html\"").isEmpty)
    }

    func testRanges() {
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\n[releases]\nkeep = 0").isEmpty)
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\n[releases]\nkeep = 51").isEmpty)
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\n[cache]\nmax_age = -1").isEmpty)
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\n[cache]\nmax_age = \"60\"").isEmpty)
    }

    func testHeaderRules() {
        func h(_ name: String, _ value: String) -> [String] {
            problems("name = \"a\"\ndir = \"x\"\n[headers.custom]\n\"\(name)\" = \(value)")
        }
        XCTAssertTrue(h("X-Ok", "\"fine; value=\\\"quoted\\\"\"").isEmpty)
        XCTAssertFalse(h("X-Bad", "\"a\\nb\"").isEmpty, "LF")
        XCTAssertFalse(h("X-Bad", "\"a\\rb\"").isEmpty, "CR")
        XCTAssertFalse(h("X-Bad", "\"{env.GAMEHOST_ADMIN_TOKEN}\"").isEmpty, "placeholder")
        XCTAssertFalse(h("X-Bad", "\"{$GAMEHOST_ADMIN_TOKEN}\"").isEmpty, "env substitution")
        XCTAssertFalse(h("X-Bad", "\"a\\\\b\"").isEmpty, "backslash")
        XCTAssertFalse(h("X-Bad", "\"`x`\"").isEmpty, "backtick")
        XCTAssertFalse(h("X-Bad", "\"\"").isEmpty, "empty")
        XCTAssertFalse(h("X-Bad", "\"caf\u{e9}\"").isEmpty, "non-ascii")
        XCTAssertFalse(h("X-Bad", "1").isEmpty, "non-string")
        XCTAssertFalse(h("X Bad", "\"v\"").isEmpty, "space in name")
        XCTAssertFalse(h("-Server", "\"v\"").isEmpty, "leading dash deletes headers in Caddy")
        XCTAssertFalse(h("X-A}", "\"v\"").isEmpty)
        for forbidden in ["Content-Type", "content-encoding", "Content-Length", "ETag"] {
            XCTAssertFalse(h(forbidden, "\"v\"").isEmpty, forbidden)
        }
        XCTAssertFalse(problems("name = \"a\"\ndir = \"x\"\n[headers.custom]\n\"X-A\" = \"1\"\n\"x-a\" = \"2\"").isEmpty, "duplicate")
    }

    func testInvalidTOML() {
        XCTAssertFalse(problems("name = ").isEmpty)
    }
}
