import Vapor

/// The JSON error shape: `{"error": {"code", "message", "details"}}`.
public struct APIError: Error, AbortError, Sendable {
    public let status: HTTPResponseStatus
    public let code: String
    public let message: String
    public let details: [String]

    public init(_ status: HTTPResponseStatus, _ code: String, _ message: String, details: [String] = []) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
    }

    public var reason: String { message }

    static func unauthorized() -> APIError { .init(.unauthorized, "unauthorized", "Missing or invalid bearer token.") }
    static func forbidden() -> APIError { .init(.forbidden, "forbidden", "This token is not allowed to act on this site.") }
    static func siteNotFound(_ name: String) -> APIError { .init(.notFound, "site_not_found", "Site \"\(name)\" does not exist. An admin must create it first.") }
}

struct ErrorBody: Content {
    struct Inner: Content {
        let code: String
        let message: String
        let details: [String]
    }
    let error: Inner
}

/// Renders every thrown error as the API's JSON error shape.
struct JSONErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let apiError: APIError
            switch error {
            case let e as APIError:
                apiError = e
            case let e as AbortError:
                let code: String
                switch e.status {
                case .notFound: code = "not_found"
                case .methodNotAllowed: code = "method_not_allowed"
                case .payloadTooLarge: code = "upload_too_large"
                case .unsupportedMediaType: code = "unsupported_media_type"
                default: code = e.status.code >= 500 ? "internal_error" : "bad_request"
                }
                apiError = APIError(e.status, code, e.reason)
            default:
                request.logger.error("unhandled error", metadata: ["error": "\(String(reflecting: error))"])
                apiError = APIError(.internalServerError, "internal_error", "Internal server error.")
            }
            let body = ErrorBody(error: .init(code: apiError.code, message: apiError.message, details: apiError.details))
            let response = Response(status: apiError.status)
            try response.content.encode(body, as: .json)
            return response
        }
    }
}
