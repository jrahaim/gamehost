import Crypto
import Foundation

public struct TokenRecord: Codable, Sendable {
    public var id: String
    public var site: String
    public var sha256: String
    public var created: Date
}

public enum Principal: Sendable, Equatable {
    case admin
    case site(name: String, tokenID: String)

    var logID: String {
        switch self {
        case .admin: return "admin"
        case .site(_, let id): return id
        }
    }

    /// Whether this principal may act on production site `name` (and its previews).
    func canAccess(site name: String) -> Bool {
        switch self {
        case .admin: return true
        case .site(let s, _): return s == name
        }
    }
}

/// Site deploy tokens, persisted as SHA-256 hashes in `tokens.json` (mode 0600).
public actor TokenStore {
    private let file: URL
    private let adminHash: [UInt8]
    private var records: [TokenRecord]

    public init(file: URL, adminToken: String) throws {
        self.file = file
        self.adminHash = Array(SHA256.hash(data: Data(adminToken.utf8)))
        if FileManager.default.fileExists(atPath: file.path) {
            records = try FileUtil.readJSON([TokenRecord].self, from: file)
        } else {
            records = []
        }
    }

    static func hash(_ token: String) -> [UInt8] { Array(SHA256.hash(data: Data(token.utf8))) }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func fromHex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Resolves a bearer token. Every stored hash is compared, in constant time, regardless of matches.
    public func authenticate(_ token: String) -> Principal? {
        let h = TokenStore.hash(token)
        var match: Principal?
        if TokenStore.constantTimeEqual(h, adminHash) { match = .admin }
        for r in records {
            if let stored = TokenStore.fromHex(r.sha256), TokenStore.constantTimeEqual(h, stored), match == nil {
                match = .site(name: r.site, tokenID: r.id)
            }
        }
        return match
    }

    /// Creates (or replaces) the deploy token for `site`. Returns the plaintext once.
    public func issue(for site: String) throws -> (token: String, record: TokenRecord) {
        let token = "gh_" + TokenStore.base64url(TokenStore.randomBytes(32))
        let record = TokenRecord(
            id: "tok_" + TokenStore.hex(TokenStore.randomBytes(6)),
            site: site,
            sha256: TokenStore.hex(TokenStore.hash(token)),
            created: Date()
        )
        var next = records.filter { $0.site != site }
        next.append(record)
        try persist(next)
        return (token, record)
    }

    public func revokeAll(for site: String) throws {
        let next = records.filter { $0.site != site }
        guard next.count != records.count else { return }
        try persist(next)
    }

    private func persist(_ next: [TokenRecord]) throws {
        try FileUtil.writeJSON(next, to: file, mode: 0o600)
        records = next
    }
}
