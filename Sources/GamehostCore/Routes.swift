import Foundation
import Vapor

struct CreateSiteBody: Content {
    var name: String
}

struct RollbackBody: Content {
    var release: String?
}

struct SiteSummary: Content {
    var name: String
    var url: String
    var created: Date
    var currentRelease: String?
    var bytes: Int64?
    var previews: [String]

    enum CodingKeys: String, CodingKey {
        case name, url, created, bytes, previews
        case currentRelease = "current_release"
    }
}

struct ReleaseSummary: Content {
    var id: String
    var created: Date
    var current: Bool
    var commit: String?
    var ref: String?
    var files: Int
    var bytes: Int64
    var bytesBrotli: Int64
    var deployer: String

    enum CodingKeys: String, CodingKey {
        case id, created, current, commit, ref, files, bytes, deployer
        case bytesBrotli = "bytes_brotli"
    }
}

struct PreviewSummary: Content {
    var label: String
    var url: String
    var currentRelease: String?
    var lastDeploy: Date?

    enum CodingKeys: String, CodingKey {
        case label, url
        case currentRelease = "current_release"
        case lastDeploy = "last_deploy"
    }
}

struct SiteDetail: Content {
    var name: String
    var url: String
    var created: Date
    var currentRelease: String?
    var releases: [ReleaseSummary]
    var previews: [PreviewSummary]

    enum CodingKeys: String, CodingKey {
        case name, url, created, releases, previews
        case currentRelease = "current_release"
    }
}

struct TokenResponse: Content {
    var name: String
    var url: String
    var token: String
}

public struct GamehostRoutes: Sendable {
    let deployer: Deployer
    let auth: Authenticator

    public init(deployer: Deployer, limiter: AuthRateLimiter = AuthRateLimiter()) {
        self.deployer = deployer
        self.auth = Authenticator(tokens: deployer.tokens, limiter: limiter)
    }

    var storage: Storage { deployer.storage }
    var config: Config { deployer.config }

    public func register(_ app: Application) {
        app.get("healthz") { _ in ["ok": true] }

        let api = app.grouped("api")
        api.post("sites", use: createSite)
        api.get("sites", use: listSites)
        api.get("sites", ":name", use: siteDetail)
        api.delete("sites", ":name", use: deleteSite)
        api.post("sites", ":name", "token", use: rotateToken)
        api.post("sites", ":name", "rollback", use: rollback)
        api.delete("sites", ":name", "previews", ":label", use: deletePreview)
        api.on(.POST, "deploy", body: .stream, use: deploy)
    }

    func json<T: Content>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
        let r = Response(status: status)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try r.content.encode(value, using: enc)
        return r
    }

    @Sendable func createSite(_ req: Request) async throws -> Response {
        let principal = try await auth.requireAdmin(req)
        guard let body = try? req.content.decode(CreateSiteBody.self) else {
            throw APIError(.badRequest, "bad_request", "Expected a JSON body {\"name\": \"...\"}.")
        }
        let (site, token) = try await deployer.createSite(name: body.name)
        _ = principal
        return try json(TokenResponse(name: site.key, url: config.url(forKey: site.key), token: token), status: .created)
    }

    @Sendable func listSites(_ req: Request) async throws -> Response {
        _ = try await auth.requireAdmin(req)
        let all = storage.allSites()
        let summaries = all.filter { $0.preview == nil }.map { s -> SiteSummary in
            let current = storage.currentRelease(s.key)
            return SiteSummary(
                name: s.key, url: config.url(forKey: s.key), created: s.created, currentRelease: current?.id,
                bytes: current?.bytes, previews: all.filter { $0.site == s.key && $0.preview != nil }.compactMap(\.preview)
            )
        }
        return try json(summaries)
    }

    func authorizedSite(_ req: Request) async throws -> (Principal, SiteRecord) {
        let principal = try await auth.authenticate(req)
        let name = req.parameters.get("name") ?? ""
        guard principal.canAccess(site: name) else { throw APIError.forbidden() }
        return (principal, try deployer.productionSite(name))
    }

    @Sendable func siteDetail(_ req: Request) async throws -> Response {
        let (_, site) = try await authorizedSite(req)
        let currentID = storage.currentReleaseID(site.key)
        let releases = storage.releaseIDs(site.key).reversed().compactMap { id -> ReleaseSummary? in
            guard let r = storage.release(site.key, id) else { return nil }
            return ReleaseSummary(id: r.id, created: r.created, current: r.id == currentID, commit: r.commit, ref: r.ref,
                                  files: r.files, bytes: r.bytes, bytesBrotli: r.bytesBrotli, deployer: r.deployer)
        }
        let previews = storage.previews(of: site.key).map { p -> PreviewSummary in
            let cur = storage.currentRelease(p.key)
            return PreviewSummary(label: p.preview ?? "", url: config.url(forKey: p.key), currentRelease: cur?.id, lastDeploy: cur?.created)
        }
        return try json(SiteDetail(name: site.key, url: config.url(forKey: site.key), created: site.created,
                                   currentRelease: currentID, releases: Array(releases), previews: previews))
    }

    @Sendable func deleteSite(_ req: Request) async throws -> Response {
        let principal = try await auth.requireAdmin(req)
        let name = req.parameters.get("name") ?? ""
        try await deployer.deleteSite(name: name, principal: principal)
        return try json(["deleted": name])
    }

    @Sendable func rotateToken(_ req: Request) async throws -> Response {
        _ = try await auth.requireAdmin(req)
        let name = req.parameters.get("name") ?? ""
        let token = try await deployer.rotateToken(site: name)
        return try json(TokenResponse(name: name, url: config.url(forKey: name), token: token))
    }

    @Sendable func rollback(_ req: Request) async throws -> Response {
        let (principal, site) = try await authorizedSite(req)
        var requested: String?
        if let data = req.body.data, data.readableBytes > 0 {
            guard let body = try? req.content.decode(RollbackBody.self) else {
                throw APIError(.badRequest, "bad_request", "Expected an empty body or {\"release\": \"<id>\"}.")
            }
            requested = body.release
        }
        let result = try await deployer.rollback(site: site.key, to: requested, principal: principal)
        return try json(result)
    }

    @Sendable func deletePreview(_ req: Request) async throws -> Response {
        let (principal, site) = try await authorizedSite(req)
        let label = req.parameters.get("label") ?? ""
        try await deployer.deletePreview(site: site.key, label: label, principal: principal)
        return try json(["deleted": Names.key(site: site.key, preview: label)])
    }

    @Sendable func deploy(_ req: Request) async throws -> Response {
        let principal = try await auth.authenticate(req)
        let upload = try await UploadReceiver.receive(
            req, tmpDir: storage.tmp, maxBundleBytes: config.maxUploadBytes,
            checkEarly: { manifest, preview in
                _ = try deployer.target(manifestText: manifest, preview: preview, principal: principal)
            }
        )
        guard let bundle = upload.bundle, let sha = upload.bundleSha256, let manifestText = upload.manifestText else {
            throw APIError(.badRequest, "missing_part", "manifest and bundle are required.")
        }
        let target: DeployTarget
        do {
            target = try deployer.target(manifestText: manifestText, preview: upload.preview, principal: principal)
        } catch {
            FileUtil.removeIfExists(bundle)
            if let e = error as? APIError {
                req.logger.info("deploy rejected", metadata: ["event": "deploy_rejected", "code": .string(e.code), "by": .string(principal.logID)])
            }
            throw error
        }
        do {
            let result = try await deployer.deploy(
                target, bundle: bundle, bundleSha256: sha,
                meta: .init(commit: upload.commit, ref: upload.ref, principal: principal)
            )
            return try json(result, status: .created)
        } catch let e as APIError {
            req.logger.info("deploy rejected", metadata: ["event": "deploy_rejected", "code": .string(e.code),
                                                         "site": .string(target.key), "by": .string(principal.logID)])
            throw e
        }
    }
}
