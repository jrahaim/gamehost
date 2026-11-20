import Foundation

/// A FIFO async mutex. Used to serialize Caddy config changes.
public actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    public nonisolated func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await lock()
        do {
            let result = try await body()
            await unlock()
            return result
        } catch {
            await unlock()
            throw error
        }
    }
}

/// Non-blocking per-key locks: a busy key is reported, not waited on.
public actor KeyLocks {
    private var held: Set<String> = []

    public init() {}

    /// Acquires all keys or none.
    func tryAcquire(_ keys: [String]) -> Bool {
        guard held.isDisjoint(with: keys) else { return false }
        held.formUnion(keys)
        return true
    }

    func release(_ keys: [String]) {
        held.subtract(keys)
    }

    public nonisolated func withKeys<T: Sendable>(
        _ keys: [String], busy: @autoclosure @Sendable () -> Error, _ body: @Sendable () async throws -> T
    ) async throws -> T {
        guard await tryAcquire(keys) else { throw busy() }
        do {
            let result = try await body()
            await release(keys)
            return result
        } catch {
            await release(keys)
            throw error
        }
    }
}

/// Runs an external program with an argument array (never through a shell).
enum Subprocess {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    struct NotFound: Error, CustomStringConvertible {
        let name: String
        var description: String { "executable not found: \(name)" }
    }

    static func resolve(_ name: String) throws -> URL {
        if name.contains("/") { return URL(fileURLWithPath: name) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw NotFound(name: name)
    }

    static func run(_ executable: String, _ arguments: [String]) async throws -> Result {
        let url = try resolve(executable)
        return try await FileUtil.blocking {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }
    }
}
