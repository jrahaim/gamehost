import Crypto
import Foundation
import MultipartKit
import Vapor

/// The parts of a deploy request, with the bundle streamed to a temp file on the data volume.
struct DeployUpload {
    var manifestText: String?
    var bundle: URL?
    var bundleSha256: String?
    var preview: String?
    var commit: String?
    var ref: String?
}

enum UploadReceiver {
    static let manifestLimit = 64 * 1024
    static let textLimit = 256

    /// Streams the multipart body. `checkEarly` runs once, when the bundle part begins and the manifest has already
    /// arrived, so an unauthorized or invalid deploy is rejected before the bundle is written.
    static func receive(_ req: Request, tmpDir: URL, maxBundleBytes: Int64,
                        checkEarly: (String, String?) async throws -> Void) async throws -> DeployUpload {
        guard let contentType = req.headers.contentType, contentType.type == "multipart", contentType.subType == "form-data",
              let boundary = contentType.parameters["boundary"], !boundary.isEmpty else {
            throw APIError(.unsupportedMediaType, "bad_request", "Expected a multipart/form-data body.")
        }
        if let length = req.headers.first(name: .contentLength).flatMap(Int64.init), length > maxBundleBytes + 1024 * 1024 {
            throw APIError(.payloadTooLarge, "upload_too_large", "The upload exceeds \(maxBundleBytes / 1024 / 1024) MB.")
        }

        final class Events {
            enum Event {
                case header(String, String)
                case body(ByteBuffer)
                case end
            }
            var items: [Event] = []
        }
        let events = Events()
        let parser = MultipartParser(boundary: boundary)
        parser.onHeader = { events.items.append(.header($0, $1)) }
        parser.onBody = { events.items.append(.body($0)) }
        parser.onPartComplete = { events.items.append(.end) }

        var upload = DeployUpload()
        var seen = Set<String>()
        var partName: String?
        var partFilename: String?
        var partStarted = false
        var text = [UInt8]()
        var bundleHandle: FileHandle?
        var bundleURL: URL?
        var hasher = SHA256()
        var bundleBytes: Int64 = 0
        var earlyChecked = false

        func fail(_ status: HTTPResponseStatus, _ code: String, _ message: String) -> APIError {
            APIError(status, code, message)
        }

        func cleanup() {
            try? bundleHandle?.close()
            bundleHandle = nil
            if let bundleURL { FileUtil.removeIfExists(bundleURL) }
        }

        func startPart() async throws {
            partStarted = true
            guard let name = partName else { throw fail(.badRequest, "bad_request", "A multipart part has no name.") }
            guard ["manifest", "bundle", "preview", "commit", "ref"].contains(name) else {
                throw fail(.badRequest, "unknown_part", "Unknown form part \"\(name)\". Expected manifest, bundle, preview, commit, ref.")
            }
            guard seen.insert(name).inserted else { throw fail(.badRequest, "duplicate_part", "Form part \"\(name)\" was sent twice.") }
            text.removeAll(keepingCapacity: true)
            if name == "bundle" {
                if let manifest = upload.manifestText, !earlyChecked {
                    earlyChecked = true
                    try await checkEarly(manifest, upload.preview)
                }
                let url = tmpDir.appendingPathComponent("\(UUID().uuidString).zip")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw APIError(.internalServerError, "internal_error", "Could not create a temp file.")
                }
                bundleURL = url
                bundleHandle = try FileHandle(forWritingTo: url)
            }
        }

        func body(_ buffer: ByteBuffer) throws {
            switch partName {
            case "bundle":
                bundleBytes += Int64(buffer.readableBytes)
                if bundleBytes > maxBundleBytes {
                    throw fail(.payloadTooLarge, "upload_too_large", "The bundle exceeds \(maxBundleBytes / 1024 / 1024) MB.")
                }
                buffer.withUnsafeReadableBytes { hasher.update(bufferPointer: $0) }
                try bundleHandle?.write(contentsOf: buffer.readableBytesView)
            case "manifest":
                text += buffer.readableBytesView
                if text.count > manifestLimit { throw fail(.payloadTooLarge, "manifest_too_large", "The manifest exceeds 64 KB.") }
            default:
                text += buffer.readableBytesView
                if text.count > textLimit { throw fail(.badRequest, "field_too_long", "Form field \"\(partName ?? "")\" is too long.") }
            }
        }

        func endPart() throws {
            switch partName {
            case "bundle":
                try bundleHandle?.close()
                bundleHandle = nil
                upload.bundle = bundleURL
                upload.bundleSha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            case "manifest":
                guard let s = String(bytes: text, encoding: .utf8) else {
                    throw fail(.unprocessableEntity, "manifest_invalid", "The manifest is not valid UTF-8.")
                }
                upload.manifestText = s
            case let field?:
                let s = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else {
                    throw fail(.badRequest, "field_invalid", "Form field \"\(field)\" must be printable ASCII.")
                }
                let value: String? = s.isEmpty ? nil : s
                switch field {
                case "preview": upload.preview = value
                case "commit": upload.commit = value
                case "ref": upload.ref = value
                default: break
                }
            case nil:
                break
            }
            partName = nil
            partFilename = nil
            partStarted = false
        }

        // One iterator for the whole body: after a rejection we keep pulling from it to drain what the client is
        // still sending. Answering mid-upload and closing makes a fronting proxy (e.g. Apache) hit a broken pipe
        // and replace our JSON error with its own 502.
        var chunks = req.body.makeAsyncIterator()
        do {
            while let chunk = try await chunks.next() {
                try parser.execute(chunk)
                let batch = events.items
                events.items.removeAll(keepingCapacity: true)
                for event in batch {
                    switch event {
                    case .header(let name, let value):
                        if name.lowercased() == "content-disposition" {
                            let d = parseDisposition(value)
                            partName = d["name"]
                            partFilename = d["filename"]
                        }
                    case .body(let buffer):
                        if !partStarted { try await startPart() }
                        try body(buffer)
                    case .end:
                        if !partStarted { try await startPart() }
                        try endPart()
                    }
                }
            }
        } catch let e as APIError {
            cleanup()
            // Bounded: never read more than an allowed upload in total, so a rejected client can't keep us busy.
            var remaining = maxBundleBytes + 1024 * 1024
            while remaining > 0, let chunk = try? await chunks.next() {
                remaining -= Int64(chunk.readableBytes)
            }
            throw e
        } catch {
            cleanup()
            throw fail(.badRequest, "bad_request", "The multipart body could not be read.")
        }
        _ = partFilename

        guard upload.manifestText != nil else {
            cleanup()
            throw fail(.badRequest, "missing_part", "The form part \"manifest\" is required.")
        }
        guard upload.bundle != nil else {
            cleanup()
            throw fail(.badRequest, "missing_part", "The form part \"bundle\" is required.")
        }
        return upload
    }

    /// Parses `form-data; name="bundle"; filename="bundle.zip"`.
    static func parseDisposition(_ value: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in value.split(separator: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            var val = kv[1].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            out[key] = val
        }
        return out
    }
}
