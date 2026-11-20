import Foundation

/// Writes `.br` (Brotli 11) and `.gz` (gzip 9) sidecars next to compressible files.
struct Precompressor: Sendable {
    static let extensions: Set<String> = ["wasm", "pck", "js", "html", "css", "json", "svg", "txt", "map"]
    static let minSize: Int64 = 1024

    let brotli: String
    let gzip: String

    static func isEligible(path: String, size: Int64) -> Bool {
        guard size > minSize, let dot = path.lastIndex(of: ".") else { return false }
        return extensions.contains(String(path[path.index(after: dot)...]).lowercased())
    }

    struct Outcome: Sendable {
        var br: Int64?
        var gz: Int64?
    }

    /// Compresses one file. A sidecar that is not smaller than the original is dropped.
    func compress(_ file: URL, size: Int64, makeBr: Bool, makeGz: Bool) async throws -> Outcome {
        async let br: Int64? = makeBr ? sidecar(file, size: size, ext: "br") { out in
            (brotli, ["-q", "11", "-f", "-o", out.path, "--", file.path])
        } : nil
        async let gz: Int64? = makeGz ? sidecar(file, size: size, ext: "gz") { out in
            (gzip, ["-9", "-n", "-k", "-f", "--", file.path])
        } : nil
        return try await Outcome(br: br, gz: gz)
    }

    private func sidecar(_ file: URL, size: Int64, ext: String,
                         command: (URL) -> (String, [String])) async throws -> Int64? {
        let out = URL(fileURLWithPath: file.path + "." + ext)
        let (exe, args) = command(out)
        let result = try await Subprocess.run(exe, args)
        guard result.status == 0 else {
            FileUtil.removeIfExists(out)
            throw APIError(.internalServerError, "precompress_failed", "Compressing a file failed.",
                           details: [file.lastPathComponent, String(result.output.suffix(500))])
        }
        guard let outSize = FileUtil.fileSize(out), outSize < size else {
            FileUtil.removeIfExists(out)
            return nil
        }
        try FileUtil.copyMtime(from: file, to: out)
        return outSize
    }
}
