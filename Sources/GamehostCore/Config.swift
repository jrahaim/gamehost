import Foundation

public enum TLSMode: String, Sendable, CaseIterable {
    case perSite = "per-site"
    case wildcard
    case external
}

/// Runtime configuration, read from `GAMEHOST_*` environment variables.
public struct Config: Sendable {
    public var baseDomain: String
    public var apiHost: String
    public var adminToken: String
    public var tlsMode: TLSMode
    public var acmeEmail: String?
    public var dnsProvider: String?
    public var dnsToken: String?
    public var maxUploadBytes: Int64
    public var maxUnpackedBytes: Int64
    public var maxFiles: Int
    public var previewTTLDays: Int
    public var trustedProxies: [String]

    /// Root of the data volume (`/data` in the image).
    public var dataDir: URL
    /// Path of the generated main Caddyfile.
    public var caddyfilePath: URL
    /// Caddy binary used for validate/reload.
    public var caddyBinary: String
    /// Caddy admin endpoint (loopback only).
    public var caddyAdmin: String
    /// Address the API listens on. Always loopback in the image.
    public var apiListenHost: String
    public var apiListenPort: Int
    /// Port Caddy listens on in `external` mode.
    public var externalPort: Int
    public var brotliBinary: String
    public var gzipBinary: String

    public static let minAdminTokenLength = 32

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) throws {
        func value(_ key: String) -> String? {
            guard let v = env["GAMEHOST_" + key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        func int(_ key: String, _ def: Int, min: Int = 1) throws -> Int {
            guard let raw = value(key) else { return def }
            guard let v = Int(raw), v >= min else { throw Invalid(description: "GAMEHOST_\(key) must be an integer >= \(min)") }
            return v
        }

        guard let base = value("BASE_DOMAIN")?.lowercased() else {
            throw Invalid(description: "GAMEHOST_BASE_DOMAIN is required")
        }
        guard Config.isHostname(base) else { throw Invalid(description: "GAMEHOST_BASE_DOMAIN is not a valid hostname") }
        baseDomain = base

        let api = value("API_HOST")?.lowercased() ?? "deploy.\(base)"
        guard Config.isHostname(api) else { throw Invalid(description: "GAMEHOST_API_HOST is not a valid hostname") }
        apiHost = api

        guard let token = env["GAMEHOST_ADMIN_TOKEN"], !token.isEmpty else {
            throw Invalid(description: "GAMEHOST_ADMIN_TOKEN is required")
        }
        guard token.count >= Config.minAdminTokenLength else {
            throw Invalid(description: "GAMEHOST_ADMIN_TOKEN must be at least \(Config.minAdminTokenLength) characters")
        }
        adminToken = token

        let modeRaw = value("TLS_MODE") ?? TLSMode.perSite.rawValue
        guard let mode = TLSMode(rawValue: modeRaw) else {
            throw Invalid(description: "GAMEHOST_TLS_MODE must be one of per-site, wildcard, external")
        }
        if mode == .wildcard {
            throw Invalid(description: "GAMEHOST_TLS_MODE=wildcard is not implemented yet (milestone 5); use per-site or external")
        }
        tlsMode = mode
        acmeEmail = value("ACME_EMAIL")
        if let email = acmeEmail, !Config.isSafeCaddyWord(email) || !email.contains("@") {
            throw Invalid(description: "GAMEHOST_ACME_EMAIL is not a valid email address")
        }
        if mode == .perSite && acmeEmail == nil {
            throw Invalid(description: "GAMEHOST_ACME_EMAIL is required when GAMEHOST_TLS_MODE=per-site")
        }
        dnsProvider = value("DNS_PROVIDER")
        dnsToken = value("DNS_TOKEN")

        maxUploadBytes = Int64(try int("MAX_UPLOAD_MB", 512)) * 1024 * 1024
        maxUnpackedBytes = Int64(try int("MAX_UNPACKED_MB", 2048)) * 1024 * 1024
        maxFiles = try int("MAX_FILES", 20000)
        previewTTLDays = try int("PREVIEW_TTL_DAYS", 14)

        trustedProxies = (value("TRUSTED_PROXIES") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        for p in trustedProxies where !Config.isCIDRish(p) {
            throw Invalid(description: "GAMEHOST_TRUSTED_PROXIES entry \"\(p)\" is not an IP or CIDR")
        }

        dataDir = URL(fileURLWithPath: value("DATA_DIR") ?? "/data", isDirectory: true)
        caddyfilePath = URL(fileURLWithPath: value("CADDYFILE") ?? dataDir.appendingPathComponent("caddy/Caddyfile").path)
        caddyBinary = value("CADDY_BIN") ?? "caddy"
        caddyAdmin = value("CADDY_ADMIN") ?? "localhost:2019"
        apiListenHost = value("API_LISTEN_HOST") ?? "127.0.0.1"
        apiListenPort = try int("API_LISTEN_PORT", 8080)
        externalPort = try int("EXTERNAL_PORT", 8081)
        brotliBinary = value("BROTLI_BIN") ?? "brotli"
        gzipBinary = value("GZIP_BIN") ?? "gzip"
    }

    /// The first DNS label of the API host; reserved as a site name.
    public var apiHostFirstLabel: String { String(apiHost.split(separator: ".").first ?? "") }

    public func host(forKey key: String) -> String { "\(key).\(baseDomain)" }

    public func url(forKey key: String) -> String {
        switch tlsMode {
        case .external: return "http://\(host(forKey: key)):\(externalPort)/"
        default: return "https://\(host(forKey: key))/"
        }
    }

    static func isHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { l in
            !l.isEmpty && l.count <= 63 && l.first != "-" && l.last != "-"
                && l.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }

    static func isCIDRish(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" || $0 == "/" }
    }

    /// Characters that are safe to drop into a Caddyfile unquoted.
    static func isSafeCaddyWord(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "@._+-".contains($0)) }
    }
}
