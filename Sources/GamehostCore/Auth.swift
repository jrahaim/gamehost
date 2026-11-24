import Foundation
import Vapor

/// In-memory failed-auth limiter: at most `limit` failures per IP per `window`.
public actor AuthRateLimiter {
    let limit: Int
    let window: TimeInterval
    private var failures: [String: [Date]] = [:]

    public init(limit: Int = 10, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    func isBlocked(_ ip: String, now: Date = Date()) -> Bool {
        prune(ip, now: now)
        return (failures[ip]?.count ?? 0) >= limit
    }

    func recordFailure(_ ip: String, now: Date = Date()) {
        prune(ip, now: now)
        failures[ip, default: []].append(now)
        if failures.count > 10_000 { // bound memory under a spray of IPs
            failures = failures.filter { !$0.value.isEmpty }
        }
    }

    private func prune(_ ip: String, now: Date) {
        guard let list = failures[ip] else { return }
        let kept = list.filter { now.timeIntervalSince($0) < window }
        failures[ip] = kept.isEmpty ? nil : kept
    }
}

struct Authenticator: Sendable {
    let tokens: TokenStore
    let limiter: AuthRateLimiter

    static func clientIP(_ req: Request) -> String {
        let remote = req.remoteAddress?.ipAddress ?? "unknown"
        // Caddy sets this header (respecting trusted_proxies); only trust it from loopback.
        if remote == "127.0.0.1" || remote == "::1", let forwarded = req.headers.first(name: "X-Gamehost-Client-IP"), !forwarded.isEmpty {
            return forwarded
        }
        return remote
    }

    func authenticate(_ req: Request) async throws -> Principal {
        let ip = Authenticator.clientIP(req)
        if await limiter.isBlocked(ip) {
            req.logger.warning("auth rate limited", metadata: ["event": "auth_rate_limited", "ip": .string(ip)])
            throw APIError(.tooManyRequests, "rate_limited", "Too many failed authentication attempts. Try again in a minute.")
        }
        if let bearer = req.headers.bearerAuthorization?.token, let principal = await tokens.authenticate(bearer) {
            return principal
        }
        await limiter.recordFailure(ip)
        req.logger.warning("auth failed", metadata: [
            "event": "auth_failed", "ip": .string(ip), "method": .string(req.method.rawValue), "path": .string(req.url.path),
            "reason": .string(req.headers.bearerAuthorization == nil ? "missing" : "invalid"),
        ])
        throw APIError.unauthorized()
    }

    func requireAdmin(_ req: Request) async throws -> Principal {
        let p = try await authenticate(req)
        guard p == .admin else { throw APIError.forbidden() }
        return p
    }
}
