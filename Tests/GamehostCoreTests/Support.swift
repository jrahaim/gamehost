import Foundation
@testable import GamehostCore

/// Minimal zip writer (stored entries) so tests can craft archives no well-behaved tool would produce.
struct RawZip {
    struct Item {
        var path: String
        var data: Data
        /// Full Unix st_mode, e.g. 0o100644 (file), 0o120777 (symlink), 0o020644 (char device).
        var mode: UInt32
    }

    var items: [Item] = []

    mutating func file(_ path: String, _ content: String, mode: UInt32 = 0o100644) {
        items.append(Item(path: path, data: Data(content.utf8), mode: mode))
    }

    mutating func file(_ path: String, data: Data, mode: UInt32 = 0o100644) {
        items.append(Item(path: path, data: data, mode: mode))
    }

    mutating func dir(_ path: String) {
        items.append(Item(path: path.hasSuffix("/") ? path : path + "/", data: Data(), mode: 0o040755))
    }

    func build() -> Data {
        var out = Data()
        var central = Data()
        for item in items {
            let name = Data(item.path.utf8)
            let crc = RawZip.crc32(item.data)
            let offset = UInt32(out.count)
            out.le32(0x04034b50); out.le16(20); out.le16(1 << 11); out.le16(0); out.le16(0); out.le16(0x21)
            out.le32(crc); out.le32(UInt32(item.data.count)); out.le32(UInt32(item.data.count))
            out.le16(UInt16(name.count)); out.le16(0)
            out.append(name); out.append(item.data)

            central.le32(0x02014b50); central.le16((3 << 8) | 20); central.le16(20); central.le16(1 << 11); central.le16(0)
            central.le16(0); central.le16(0x21); central.le32(crc)
            central.le32(UInt32(item.data.count)); central.le32(UInt32(item.data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(item.mode << 16); central.le32(offset)
            central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.le32(0x06054b50); out.le16(0); out.le16(0)
        out.le16(UInt16(items.count)); out.le16(UInt16(items.count))
        out.le32(UInt32(central.count)); out.le32(cdOffset); out.le16(0)
        return out
    }

    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gamehost-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testConfig(dataDir: URL, mode: String = "external", extra: [String: String] = [:]) throws -> Config {
    var env = [
        "GAMEHOST_BASE_DOMAIN": "games.test",
        "GAMEHOST_ADMIN_TOKEN": String(repeating: "x", count: 40),
        "GAMEHOST_TLS_MODE": mode,
        "GAMEHOST_ACME_EMAIL": "ops@example.com",
        "GAMEHOST_DATA_DIR": dataDir.path,
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ]
    for (k, v) in extra { env[k] = v }
    return try Config(environment: env)
}

/// Records snippet changes instead of driving Caddy.
final class RecordingProxy: ProxyController, @unchecked Sendable {
    let storage: Storage
    let lock = NSLock()
    var applied: [[String: String?]] = []
    var failNext = false

    init(storage: Storage) { self.storage = storage }

    func apply(_ changes: [String: String?]) async throws {
        let shouldFail: Bool = lock.withLock {
            applied.append(changes)
            defer { failNext = false }
            return failNext
        }
        if shouldFail { throw APIError(.internalServerError, "proxy_config_failed", "test failure") }
        for (key, content) in changes {
            if let content { try FileUtil.atomicWrite(Data(content.utf8), to: storage.snippet(key)) }
            else { FileUtil.removeIfExists(storage.snippet(key)) }
        }
    }
}
