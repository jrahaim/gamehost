import Foundation
import Logging

/// Applies per-site proxy configuration.
public protocol ProxyController: Sendable {
    /// Installs, replaces (non-nil) or removes (nil) snippets by key, then validates and reloads the proxy.
    /// On any failure the previous snippets are restored and `proxy_config_failed` is thrown.
    func apply(_ changes: [String: String?]) async throws
}

/// Drives Caddy through its CLI (`caddy validate`, `caddy reload` against the loopback admin API).
public struct CaddyController: ProxyController {
    let config: Config
    let storage: Storage
    let lock: AsyncLock
    let logger: Logger

    public init(config: Config, storage: Storage, logger: Logger) {
        self.config = config
        self.storage = storage
        self.lock = AsyncLock()
        self.logger = logger
    }

    public func apply(_ changes: [String: String?]) async throws {
        try await lock.withLock {
            var previous: [String: String?] = [:]
            for (key, content) in changes {
                let old = try? String(contentsOf: storage.snippet(key), encoding: .utf8)
                if old != content { previous[key] = old }
            }
            if previous.isEmpty { return }

            func write(_ set: [String: String?]) throws {
                for (key, content) in set {
                    if let content {
                        try FileUtil.atomicWrite(Data(content.utf8), to: storage.snippet(key))
                    } else {
                        FileUtil.removeIfExists(storage.snippet(key))
                    }
                }
            }

            let next = changes.filter { previous.keys.contains($0.key) }
            try write(next)

            let validate = try await caddy(["validate", "--config", config.caddyfilePath.path, "--adapter", "caddyfile"])
            if validate.status != 0 {
                try? write(previous)
                logger.error("caddy validate failed", metadata: ["output": .string(tail(validate.output))])
                throw APIError(.internalServerError, "proxy_config_failed", "The generated proxy configuration was rejected; the live site is unchanged.")
            }
            let reload = try await caddy(["reload", "--config", config.caddyfilePath.path, "--adapter", "caddyfile",
                                          "--address", config.caddyAdmin])
            if reload.status != 0 {
                try? write(previous)
                _ = try? await caddy(["reload", "--config", config.caddyfilePath.path, "--adapter", "caddyfile",
                                      "--address", config.caddyAdmin])
                logger.error("caddy reload failed", metadata: ["output": .string(tail(reload.output))])
                throw APIError(.internalServerError, "proxy_config_failed", "The proxy could not be reloaded; the live site is unchanged.")
            }
        }
    }

    private func caddy(_ args: [String]) async throws -> Subprocess.Result {
        try await Subprocess.run(config.caddyBinary, args)
    }

    private func tail(_ s: String) -> String { String(s.suffix(2000)) }
}
