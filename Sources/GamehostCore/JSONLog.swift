import Foundation
import Logging

/// One JSON object per line on stdout.
public struct JSONLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .info
    let label: String
    private static let lock = NSLock()

    public init(label: String) { self.label = label }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var obj: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": event.level.rawValue,
            "msg": event.message.description,
            "logger": label,
        ]
        let merged = metadata.merging(event.metadata ?? [:]) { $1 }
        for (k, v) in merged { obj[k] = JSONLogHandler.unwrap(v) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        JSONLogHandler.lock.lock()
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        JSONLogHandler.lock.unlock()
    }

    static func unwrap(_ v: Logger.Metadata.Value) -> Any {
        switch v {
        case .string(let s): return s
        case .stringConvertible(let s): return s.description
        case .array(let a): return a.map(unwrap)
        case .dictionary(let d): return d.mapValues(unwrap)
        }
    }
}
