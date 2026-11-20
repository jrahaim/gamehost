import Foundation
import Logging
import Vapor

/// Wires the API into a Vapor application.
public enum GamehostApp {
    public static func makeDeployer(config: Config, logger: Logger, proxy: ProxyController? = nil) throws -> Deployer {
        let storage = Storage(root: config.dataDir)
        try storage.ensureLayout()
        let tokens = try TokenStore(file: storage.tokensFile, adminToken: config.adminToken)
        let proxy = proxy ?? CaddyController(config: config, storage: storage, logger: logger)
        return Deployer(config: config, storage: storage, tokens: tokens, proxy: proxy, logger: logger)
    }

    public static func configure(_ app: Application, deployer: Deployer, limiter: AuthRateLimiter = AuthRateLimiter()) {
        app.http.server.configuration.hostname = deployer.config.apiListenHost
        app.http.server.configuration.port = deployer.config.apiListenPort
        app.http.server.configuration.serverName = nil
        app.middleware = Middlewares()
        app.middleware.use(JSONErrorMiddleware())
        // Small bodies (create, rollback) are collected; the deploy route streams.
        app.routes.defaultMaxBodySize = "64kb"
        GamehostRoutes(deployer: deployer, limiter: limiter).register(app)
    }

    /// Entry point used by `main.swift`.
    public static func main(arguments: [String]) async -> Int32 {
        LoggingSystem.bootstrap { JSONLogHandler(label: $0) }
        let logger = Logger(label: "gamehost")
        let command = arguments.dropFirst().first ?? "serve"

        let config: Config
        do {
            config = try Config()
        } catch {
            logger.critical("invalid configuration", metadata: ["error": "\(error)"])
            return 2
        }

        switch command {
        case "print-caddyfile":
            print(CaddyConfig.mainCaddyfile(config, storage: Storage(root: config.dataDir)), terminator: "")
            return 0
        case "prepare":
            do {
                let deployer = try makeDeployer(config: config, logger: logger)
                try deployer.prepare()
                logger.info("prepared", metadata: ["event": "prepare", "caddyfile": .string(config.caddyfilePath.path)])
                return 0
            } catch {
                logger.critical("prepare failed", metadata: ["error": "\(error)"])
                return 1
            }
        case "serve":
            do {
                let deployer = try makeDeployer(config: config, logger: logger)
                try deployer.storage.sweepTmp()
                let env = try Environment.detect(arguments: ["gamehost", "serve"])
                let app = try await Application.make(env)
                configure(app, deployer: deployer)
                let sweeper = Task {
                    try? await Task.sleep(for: .seconds(60))
                    while !Task.isCancelled {
                        await deployer.sweepPreviews()
                        try? await Task.sleep(for: .seconds(86_400))
                    }
                }
                logger.info("starting", metadata: ["event": "start", "base_domain": .string(config.baseDomain),
                                                   "api_host": .string(config.apiHost), "tls_mode": .string(config.tlsMode.rawValue)])
                do {
                    try await app.execute()
                } catch {
                    logger.critical("server failed", metadata: ["error": "\(error)"])
                    sweeper.cancel()
                    try? await app.asyncShutdown()
                    return 1
                }
                sweeper.cancel()
                try await app.asyncShutdown()
                return 0
            } catch {
                logger.critical("startup failed", metadata: ["error": "\(error)"])
                return 1
            }
        default:
            FileHandle.standardError.write(Data("usage: gamehost [serve|prepare|print-caddyfile]\n".utf8))
            return 64
        }
    }
}
