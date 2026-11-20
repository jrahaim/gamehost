import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

enum FileUtil {
    struct POSIXFailure: Error, CustomStringConvertible {
        let op: String
        let path: String
        let code: Int32
        var description: String { "\(op) \(path): \(String(cString: strerror(code)))" }
    }

    /// Writes data to `url` atomically (temp file in the same directory + rename) with the given mode.
    static func atomicWrite(_ data: Data, to url: URL, mode: mode_t = 0o644) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw POSIXFailure(op: "open", path: tmp.path, code: errno) }
        var ok = false
        defer {
            if !ok { unlink(tmp.path) }
        }
        do {
            try data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXFailure(op: "write", path: tmp.path, code: errno)
                    }
                    off += n
                }
            }
            guard fsync(fd) == 0 else { throw POSIXFailure(op: "fsync", path: tmp.path, code: errno) }
            close(fd)
        } catch {
            close(fd)
            throw error
        }
        fchmodPath(tmp.path, mode)
        guard rename(tmp.path, url.path) == 0 else { throw POSIXFailure(op: "rename", path: url.path, code: errno) }
        ok = true
    }

    private static func fchmodPath(_ path: String, _ mode: mode_t) {
        _ = chmod(path, mode) // umask may have narrowed open()'s mode
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL, mode: mode_t = 0o644) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try atomicWrite(enc.encode(value), to: url, mode: mode)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(type, from: Data(contentsOf: url))
    }

    /// Atomically points the symlink `link` at `target` (a relative path), replacing any existing link.
    static func atomicSymlink(target: String, link: URL) throws {
        let tmp = link.deletingLastPathComponent().appendingPathComponent(".\(link.lastPathComponent).\(UUID().uuidString)")
        guard symlink(target, tmp.path) == 0 else { throw POSIXFailure(op: "symlink", path: tmp.path, code: errno) }
        guard rename(tmp.path, link.path) == 0 else {
            let code = errno
            unlink(tmp.path)
            throw POSIXFailure(op: "rename", path: link.path, code: code)
        }
    }

    static func readlink(_ url: URL) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = Foundation.readlink(url.path, &buf, buf.count - 1)
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func fileSize(_ url: URL) -> Int64? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(st.st_size)
    }

    /// Copies the modification (and access) time of `source` onto `dest` with full precision.
    static func copyMtime(from source: URL, to dest: URL) throws {
        var st = stat()
        guard stat(source.path, &st) == 0 else { throw POSIXFailure(op: "stat", path: source.path, code: errno) }
        #if canImport(Darwin)
        var times = [st.st_atimespec, st.st_mtimespec]
        #else
        var times = [st.st_atim, st.st_mtim]
        #endif
        guard utimensat(AT_FDCWD, dest.path, &times, 0) == 0 else {
            throw POSIXFailure(op: "utimensat", path: dest.path, code: errno)
        }
    }

    static func hardLink(from existing: URL, to new: URL) throws {
        guard link(existing.path, new.path) == 0 else { throw POSIXFailure(op: "link", path: new.path, code: errno) }
    }

    static func removeIfExists(_ url: URL) {
        if exists(url) { try? FileManager.default.removeItem(at: url) }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += fileSize(f) ?? 0 }
        return total
    }

    /// Runs blocking work off the cooperative thread pool.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try body() })
            }
        }
    }
}
