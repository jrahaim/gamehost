import Foundation

enum Names {
    static let reserved: Set<String> = ["deploy", "api", "www", "admin"]

    /// Validates a site name. Returns a list of problems (empty when valid).
    static func problems(siteName name: String, apiHostLabel: String) -> [String] {
        problems(siteName: name, reservedLabels: [apiHostLabel])
    }

    /// `reservedLabels`: hostnames gamehost itself answers on under the base domain (API, games index).
    static func problems(siteName name: String, reservedLabels: Set<String>) -> [String] {
        var out: [String] = []
        if !matchesSiteName(name) {
            out.append("name must be 1-40 characters of a-z, 0-9 and '-', not starting or ending with '-'")
        }
        if name.contains("--") { out.append("name must not contain '--' (reserved as the preview separator)") }
        if reserved.contains(name) || reservedLabels.contains(name) { out.append("name \"\(name)\" is reserved") }
        return out
    }

    static func isValidSiteName(_ name: String, apiHostLabel: String) -> Bool {
        problems(siteName: name, apiHostLabel: apiHostLabel).isEmpty
    }

    /// Cover images the games index will show.
    static let coverExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "avif", "gif"]

    /// `^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$`
    static func matchesSiteName(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...40).contains(b.count) else { return false }
        func alnum(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
        guard alnum(b.first!), alnum(b.last!) else { return false }
        return b.allSatisfy { alnum($0) || $0 == 45 }
    }

    /// Preview label: `[a-z0-9-]`, 1-20 chars, no leading/trailing '-', no '--'.
    static func isValidPreviewLabel(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard (1...20).contains(b.count) else { return false }
        func alnum(_ c: UInt8) -> Bool { (c >= 97 && c <= 122) || (c >= 48 && c <= 57) }
        guard alnum(b.first!), alnum(b.last!), !s.contains("--") else { return false }
        return b.allSatisfy { alnum($0) || $0 == 45 }
    }

    /// Storage/host key for a site or preview.
    static func key(site: String, preview: String?) -> String {
        guard let preview else { return site }
        return "\(site)--\(preview)"
    }

    /// Validates a relative path from the manifest (`dir`, `entry`).
    static func isSafeRelativePath(_ p: String, allowEmpty: Bool = false) -> Bool {
        if p.isEmpty { return allowEmpty }
        if p.hasPrefix("/") || p.contains("\\") || p.contains("\0") { return false }
        if p.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        if parts.isEmpty { return allowEmpty }
        return !parts.contains("..")
    }

    /// `[A-Za-z0-9._/-]+` — safe to place in generated proxy config.
    static func isPlainPathCharset(_ p: String) -> Bool {
        !p.isEmpty && p.unicodeScalars.allSatisfy { c in
            (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) || (c.value >= 48 && c.value <= 57)
                || c == "." || c == "_" || c == "/" || c == "-"
        }
    }

    /// Normalizes a safe relative path: drops empty and "." components.
    static func normalize(_ p: String) -> String {
        p.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
}
