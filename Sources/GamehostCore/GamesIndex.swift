import Foundation

/// The public games index: a static `index.html` (and `index.json`) listing every production site whose live
/// release has `[listing] listed = true`. Regenerated after each production deploy, rollback and site deletion,
/// and at startup. Served by Caddy on `GAMEHOST_INDEX_HOST`.
public enum GamesIndex {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var title: String
        public var description: String?
        public var url: String
        /// Absolute cover URL on the game's own origin, versioned by release so browsers refetch after a deploy.
        public var cover: String?
        public var release: String
        public var updated: Date
    }

    public struct Document: Codable, Sendable {
        public var title: String
        public var updated: Date
        public var games: [Entry]
    }

    /// Listed production sites, most recently deployed first.
    public static func entries(config: Config, storage: Storage) -> [Entry] {
        storage.allSites().compactMap { rec -> Entry? in
            guard rec.preview == nil, let release = storage.currentRelease(rec.key),
                  let listing = release.manifest.listing, listing.listed else { return nil }
            let url = config.url(forKey: rec.key)
            // The cover was checked to exist when this release was deployed; check again in case of manual edits.
            let cover = listing.cover.flatMap { path in
                release.index[path] != nil ? "\(url)\(path)?v=\(release.id)" : nil
            }
            return Entry(name: rec.key, title: listing.title, description: listing.description, url: url,
                         cover: cover, release: release.id, updated: release.created)
        }
        .sorted { ($0.updated, $1.name) > ($1.updated, $0.name) }
    }

    private static let lock = NSLock()

    /// Writes `index.html` and `index.json`. No-op when the index is disabled. Serialized so concurrent deploys of
    /// different sites cannot leave an older snapshot in place.
    public static func write(config: Config, storage: Storage, now: Date = Date()) throws {
        guard config.indexHost != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        let doc = Document(title: config.indexTitle, updated: now, games: entries(config: config, storage: storage))
        try FileManager.default.createDirectory(at: storage.indexDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileUtil.atomicWrite(try encoder.encode(doc), to: storage.indexDir.appendingPathComponent("index.json"))
        try FileUtil.atomicWrite(Data(html(doc).utf8), to: storage.indexDir.appendingPathComponent("index.html"))
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    public static func html(_ doc: Document) -> String {
        let cards = doc.games.map { g -> String in
            let art: String
            if let cover = g.cover {
                art = "<img src=\"\(escape(cover))\" alt=\"\" loading=\"lazy\" decoding=\"async\">"
            } else {
                art = "<span class=\"ph\" aria-hidden=\"true\">\(escape(String(g.title.prefix(1)).uppercased()))</span>"
            }
            let desc = g.description.map { "<p>\(escape($0))</p>" } ?? ""
            return """
                  <li><a class="card" href="\(escape(g.url))">
                    <div class="art">\(art)</div>
                    <div class="text"><h2>\(escape(g.title))</h2>\(desc)</div>
                  </a></li>
            """
        }.joined(separator: "\n")
        let body = doc.games.isEmpty ? "<p class=\"empty\">No games are listed yet.</p>" : "<ul class=\"grid\">\n\(cards)\n    </ul>"
        let title = escape(doc.title)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { color-scheme: dark light; --bg: #0d1b24; --fg: #e8eef2; --muted: #9db0bd; --card: #142a37;
                --edge: #21404f; --accent: #f2c14e; }
        @media (prefers-color-scheme: light) {
          :root { --bg: #f4f7f9; --fg: #10212c; --muted: #4d6473; --card: #ffffff; --edge: #d5e0e7; --accent: #9a6a00; }
        }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--fg);
               font: 16px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
        main { max-width: 1100px; margin: 0 auto; padding: 40px 16px 64px; }
        h1 { margin: 0 0 28px; font-size: clamp(28px, 5vw, 40px); letter-spacing: .02em; }
        .grid { list-style: none; margin: 0; padding: 0; display: grid; gap: 20px;
                grid-template-columns: repeat(auto-fill, minmax(min(100%, 300px), 1fr)); }
        .card { display: flex; flex-direction: column; height: 100%; color: inherit; text-decoration: none;
                background: var(--card); border: 1px solid var(--edge); border-radius: 12px; overflow: hidden;
                transition: transform .15s ease, border-color .15s ease; }
        .card:hover, .card:focus-visible { transform: translateY(-2px); border-color: var(--accent); outline: none; }
        .art { aspect-ratio: 16 / 9; background: var(--edge); display: grid; place-items: center; }
        .art img { width: 100%; height: 100%; object-fit: cover; display: block; }
        .ph { font-size: 64px; font-weight: 700; color: var(--accent); }
        .text { padding: 14px 16px 18px; }
        h2 { margin: 0 0 4px; font-size: 20px; }
        .text p { margin: 0; color: var(--muted); font-size: 15px; }
        .empty { color: var(--muted); }
        @media (prefers-reduced-motion: reduce) { .card { transition: none; } .card:hover { transform: none; } }
        </style>
        </head>
        <body>
        <main>
          <h1>\(title)</h1>
            \(body)
        </main>
        </body>
        </html>

        """
    }
}
