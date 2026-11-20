import Crypto
import Foundation
import ZIPFoundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct UnpackLimits: Sendable {
    public var maxFiles: Int
    public var maxBytes: Int64
}

public struct UnpackedFile: Sendable, Equatable {
    public var sha256: String
    public var size: Int64
}

/// Safely extracts a bundle zip. Every check runs on entry metadata before bytes are written, and size limits
/// are enforced against the bytes actually written, not the sizes the zip declares.
public enum Unpacker {
    static let junkDirs: Set<String> = ["__MACOSX"]
    static let junkFiles: Set<String> = [".DS_Store"]

    static func invalid(_ message: String, _ details: [String] = []) -> APIError {
        APIError(.unprocessableEntity, "bundle_invalid", message, details: details)
    }

    private struct Planned {
        var components: [String]
        var isDirectory: Bool
        var entry: Entry
    }

    /// Returns the extracted files keyed by normalized relative path.
    public static func unpack(zip: URL, into dest: URL, limits: UnpackLimits) throws -> [String: UnpackedFile] {
        let archive: Archive
        do {
            archive = try Archive(url: zip, accessMode: .read)
        } catch {
            throw invalid("The bundle is not a readable zip file.")
        }

        // Pass 1: metadata checks and planning.
        var planned: [Planned] = []
        var entryCount = 0
        for entry in archive {
            entryCount += 1
            if entryCount > limits.maxFiles {
                throw APIError(.payloadTooLarge, "bundle_too_many_files",
                               "The bundle has more than \(limits.maxFiles) entries.")
            }
            let rawPath = entry.path
            let components = try safeComponents(rawPath)
            if components.isEmpty { continue }
            if junkDirs.contains(components[0]) || junkFiles.contains(components.last!) { continue }

            switch entry.type {
            case .symlink:
                throw invalid("The bundle contains a symbolic link, which is not allowed.", [rawPath])
            case .directory, .file:
                if let kind = unixFileType(entry), kind != 0, kind != UInt32(S_IFREG), kind != UInt32(S_IFDIR) {
                    throw invalid("The bundle contains a device, FIFO or other special file, which is not allowed.", [rawPath])
                }
            }
            planned.append(Planned(components: components, isDirectory: entry.type == .directory, entry: entry))
        }

        // A zip of the folder instead of its contents: one top-level directory, nothing at the root.
        if let first = planned.first?.components.first,
           planned.allSatisfy({ $0.components.first == first }),
           !planned.contains(where: { $0.components.count == 1 && !$0.isDirectory }),
           planned.contains(where: { $0.components.count > 1 }) {
            planned = planned.compactMap { p in
                var q = p
                q.components.removeFirst()
                return q.components.isEmpty ? nil : q
            }
        }

        // Pass 2: extraction.
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var written: Int64 = 0
        var files: [String: UnpackedFile] = [:]
        for p in planned {
            let rel = p.components.joined(separator: "/")
            let target = dest.appendingPathComponent(rel, isDirectory: p.isDirectory)
            // Defence in depth: the resolved path must stay under dest.
            guard target.standardizedFileURL.path.hasPrefix(dest.standardizedFileURL.path + "/") else {
                throw invalid("The bundle contains a path that escapes the bundle root.", [p.entry.path])
            }
            if p.isDirectory {
                try makeDirectories(dest: dest, components: p.components, entryPath: p.entry.path)
                continue
            }
            if p.components.count > 1 {
                try makeDirectories(dest: dest, components: Array(p.components.dropLast()), entryPath: p.entry.path)
            }
            if files[rel] != nil {
                throw invalid("The bundle contains the same path twice.", [rel])
            }
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
            guard fd >= 0 else {
                throw invalid("The bundle contains a path that cannot be created (duplicate or file/directory clash).", [rel])
            }
            var hasher = SHA256()
            var size: Int64 = 0
            var writeError: Error?
            do {
                _ = try archive.extract(p.entry, skipCRC32: false) { data in
                    size += Int64(data.count)
                    written += Int64(data.count)
                    if written > limits.maxBytes {
                        throw APIError(.payloadTooLarge, "bundle_unpacked_too_large",
                                       "The bundle unpacks to more than \(limits.maxBytes / 1024 / 1024) MB.")
                    }
                    hasher.update(data: data)
                    try data.withUnsafeBytes { raw in
                        var off = 0
                        while off < raw.count {
                            let n = write(fd, raw.baseAddress! + off, raw.count - off)
                            if n < 0 {
                                if errno == EINTR { continue }
                                throw FileUtil.POSIXFailure(op: "write", path: target.path, code: errno)
                            }
                            off += n
                        }
                    }
                }
            } catch {
                writeError = error
            }
            close(fd)
            if let writeError {
                if writeError is APIError || writeError is FileUtil.POSIXFailure { throw writeError }
                throw invalid("The bundle could not be extracted (corrupt or unsupported entry).", [rel])
            }
            files[rel] = UnpackedFile(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), size: size)
        }
        return files
    }

    /// Splits and validates an entry path. Rejects absolute paths, drive letters, backslashes, `..` and control characters.
    static func safeComponents(_ path: String) throws -> [String] {
        if path.hasPrefix("/") || path.contains("\\") || path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            throw invalid("The bundle contains an absolute or malformed path.", [path])
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        if let first = parts.first, first.count == 2, first.hasSuffix(":") {
            throw invalid("The bundle contains an absolute or malformed path.", [path])
        }
        if parts.contains("..") {
            throw invalid("The bundle contains a path that escapes the bundle root.", [path])
        }
        if parts.contains(where: { $0.utf8.count > 255 }) || path.utf8.count > 1024 {
            throw invalid("The bundle contains a path that is too long.", [path])
        }
        return parts
    }

    private static func makeDirectories(dest: URL, components: [String], entryPath: String) throws {
        var url = dest
        for c in components {
            url = url.appendingPathComponent(c, isDirectory: true)
            var st = stat()
            if lstat(url.path, &st) == 0 {
                if (st.st_mode & S_IFMT) != S_IFDIR {
                    throw invalid("The bundle contains a path that is both a file and a directory.", [entryPath])
                }
                continue
            }
            guard mkdir(url.path, 0o755) == 0 else {
                throw invalid("The bundle contains a directory that cannot be created.", [entryPath])
            }
        }
    }

    /// The Unix file type bits (`S_IFMT`) of an entry made on a Unix-like system, or nil if unknown.
    /// ZIPFoundation folds devices and FIFOs into `.file`, so the raw attributes are read directly.
    static func unixFileType(_ entry: Entry) -> UInt32? {
        guard let cds = Mirror(reflecting: entry).descendant("centralDirectoryStructure") else { return nil }
        let m = Mirror(reflecting: cds)
        guard let attrs = m.descendant("externalFileAttributes") as? UInt32,
              let madeBy = m.descendant("versionMadeBy") as? UInt16 else { return nil }
        let os = madeBy >> 8
        guard os == 3 || os == 19 else { return nil } // Unix, OS X
        return (attrs >> 16) & 0o170000
    }
}
