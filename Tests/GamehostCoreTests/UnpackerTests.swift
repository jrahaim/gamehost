import XCTest
@testable import GamehostCore

final class UnpackerTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    let limits = UnpackLimits(maxFiles: 100, maxBytes: 1_000_000)

    func unpack(_ zip: RawZip, limits: UnpackLimits? = nil) throws -> [String: UnpackedFile] {
        let url = dir.appendingPathComponent("\(UUID().uuidString).zip")
        try zip.build().write(to: url)
        return try Unpacker.unpack(zip: url, into: dir.appendingPathComponent("out-\(UUID().uuidString)"), limits: limits ?? self.limits)
    }

    func assertRejected(_ zip: RawZip, code: String, limits: UnpackLimits? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try unpack(zip, limits: limits), file: file, line: line) { error in
            XCTAssertEqual((error as? APIError)?.code, code, "\(error)", file: file, line: line)
        }
    }

    func testPlainBundle() throws {
        var z = RawZip()
        z.file("index.html", "<html>")
        z.dir("assets")
        z.file("assets/app.js", "js")
        let files = try unpack(z)
        XCTAssertEqual(Set(files.keys), ["index.html", "assets/app.js"])
        XCTAssertEqual(files["index.html"]?.size, 6)
    }

    func testSingleTopLevelDirectoryIsStripped() throws {
        var z = RawZip()
        z.dir("web")
        z.file("web/index.html", "x")
        z.file("web/sub/a.js", "y")
        z.file("__MACOSX/web/._index.html", "junk")
        z.file("web/.DS_Store", "junk")
        XCTAssertEqual(Set(try unpack(z).keys), ["index.html", "sub/a.js"])
    }

    func testSingleDirectoryWithRootFileIsNotStripped() throws {
        var z = RawZip()
        z.file("readme.txt", "x")
        z.file("web/index.html", "x")
        XCTAssertEqual(Set(try unpack(z).keys), ["readme.txt", "web/index.html"])
    }

    func testZipSlip() {
        var z = RawZip()
        z.file("../evil.html", "x")
        assertRejected(z, code: "bundle_invalid")
        var z2 = RawZip()
        z2.file("a/../../evil.html", "x")
        assertRejected(z2, code: "bundle_invalid")
        var z3 = RawZip()
        z3.file("/etc/evil", "x")
        assertRejected(z3, code: "bundle_invalid")
        var z4 = RawZip()
        z4.file("C:/evil", "x")
        assertRejected(z4, code: "bundle_invalid")
        var z5 = RawZip()
        z5.file("a\\..\\evil", "x")
        assertRejected(z5, code: "bundle_invalid")
    }

    func testSymlinkRejected() {
        var z = RawZip()
        z.file("index.html", "x")
        z.file("link", "/etc/passwd", mode: 0o120777)
        assertRejected(z, code: "bundle_invalid")
    }

    func testDeviceAndFifoRejected() {
        for mode: UInt32 in [0o020644, 0o060644, 0o010644, 0o140644] {
            var z = RawZip()
            z.file("index.html", "x")
            z.file("dev", "", mode: mode)
            assertRejected(z, code: "bundle_invalid")
        }
    }

    func testFileCountLimit() {
        var z = RawZip()
        for i in 0..<6 { z.file("f\(i).txt", "x") }
        assertRejected(z, code: "bundle_too_many_files", limits: UnpackLimits(maxFiles: 5, maxBytes: 1000))
    }

    func testUnpackedSizeLimitCountsRealBytes() {
        var z = RawZip()
        z.file("a.bin", data: Data(count: 600))
        z.file("b.bin", data: Data(count: 600))
        assertRejected(z, code: "bundle_unpacked_too_large", limits: UnpackLimits(maxFiles: 10, maxBytes: 1000))
    }

    func testDeflateBombIsCutOff() throws {
        // A real deflate-compressed zip (made with the system zip tool) that expands far beyond the limit.
        let src = dir.appendingPathComponent("bomb", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data(count: 5_000_000).write(to: src.appendingPathComponent("zeros.bin"))
        let zip = dir.appendingPathComponent("bomb.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = src
        p.arguments = ["-q", "-9", zip.path, "zeros.bin"]
        try p.run()
        p.waitUntilExit()
        XCTAssertLessThan(try Data(contentsOf: zip).count, 100_000)
        XCTAssertThrowsError(try Unpacker.unpack(zip: zip, into: dir.appendingPathComponent("o"), limits: limits)) {
            XCTAssertEqual(($0 as? APIError)?.code, "bundle_unpacked_too_large")
        }
    }

    func testDuplicateAndClashingPaths() {
        var z = RawZip()
        z.file("a.txt", "1")
        z.file("a.txt", "2")
        assertRejected(z, code: "bundle_invalid")
        var z2 = RawZip()
        z2.file("a", "1")
        z2.file("a/b", "2")
        assertRejected(z2, code: "bundle_invalid")
    }

    func testNotAZip() throws {
        let url = dir.appendingPathComponent("x.zip")
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try Unpacker.unpack(zip: url, into: dir.appendingPathComponent("o"), limits: limits)) {
            XCTAssertEqual(($0 as? APIError)?.code, "bundle_invalid")
        }
    }
}
