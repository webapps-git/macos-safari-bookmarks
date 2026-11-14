import Foundation
import SQLite3

/// Import zakładek z Chrome, Edge, Firefoksa i pliku HTML oraz eksport do pliku HTML.
///
/// Do innych przeglądarek nic nie zapisujemy: ich pliki są tylko czytane (Firefox – z kopii
/// bazy, bo przy otwartym Firefoksie jest zablokowana). Eksport tworzy plik HTML w formacie,
/// który Chrome, Edge i Firefox wczytują przez „Importuj zakładki”.
nonisolated enum ImportExport {
    /// Zakładka albo folder do zaimportowania.
    struct Node {
        var title: String
        var url: String?
        var dateAdded: Date?
        var children: [Node]?

        var isFolder: Bool { children != nil }
        var bookmarkCount: Int { url != nil ? 1 : (children ?? []).reduce(0) { $0 + $1.bookmarkCount } }
        var folderCount: Int { (children ?? []).reduce(0) { $0 + ($1.isFolder ? 1 + $1.folderCount : 0) } }
    }

    enum Kind: String { case chrome = "Chrome", edge = "Edge", firefox = "Firefox", html = "HTML" }

    struct Source: Identifiable, Hashable {
        let kind: Kind
        /// Plik z zakładkami (Bookmarks, places.sqlite albo plik HTML).
        let file: URL
        /// Nazwa profilu przeglądarki.
        let profile: String
        var id: URL { file }
        var title: String { kind == .html ? file.lastPathComponent : "\(kind.rawValue) – \(profile)" }
    }

    enum ImportError: LocalizedError {
        case unreadable, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: L("Nie udało się odczytać zakładek z tego źródła.", "Could not read bookmarks from this source.")
            case .empty: L("Nie ma tu żadnych zakładek.", "There are no bookmarks here.")
            }
        }
    }

    // MARK: - Wyszukiwanie przeglądarek

    static func detectSources() -> [Source] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        var out: [Source] = []
        for (kind, dir) in [(Kind.chrome, "Google/Chrome"), (.edge, "Microsoft Edge")] {
            let root = base.appending(path: dir)
            let names = chromiumProfileNames(root)
            let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for d in dirs.sorted() where d == "Default" || d.hasPrefix("Profile ") {
                let file = root.appending(path: d).appending(path: "Bookmarks")
                if FileManager.default.fileExists(atPath: file.path) {
                    out.append(Source(kind: kind, file: file, profile: names[d] ?? d))
                }
            }
        }
        let ff = base.appending(path: "Firefox/Profiles")
        for d in ((try? FileManager.default.contentsOfDirectory(atPath: ff.path)) ?? []).sorted() {
            let file = ff.appending(path: d).appending(path: "places.sqlite")
            if FileManager.default.fileExists(atPath: file.path) {
                out.append(Source(kind: .firefox, file: file, profile: d))
            }
        }
        return out
    }

    /// Nazwy profili Chrome/Edge z pliku „Local State” (katalog → nazwa widoczna w przeglądarce).
    static func chromiumProfileNames(_ root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: root.appending(path: "Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (dir, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String, !name.isEmpty { out[dir] = name }
        }
        return out
    }

    // MARK: - Wczytywanie

    /// Zakładki ze źródła jako jeden folder (w środku foldery główne przeglądarki).
    static func load(_ source: Source) throws -> Node {
        let root: Node
        switch source.kind {
        case .chrome, .edge: root = try loadChromium(source.file)
        case .firefox: root = try loadFirefox(source.file)
        case .html: root = try loadHTML(source.file)
        }
        guard root.bookmarkCount > 0 else { throw ImportError.empty }
        return root
    }

    /// Chrome i Edge: plik JSON „Bookmarks”.
    static func loadChromium(_ file: URL) throws -> Node {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ImportError.unreadable }
        func node(_ d: [String: Any]) -> Node? {
            let name = d["name"] as? String ?? ""
            let date = chromiumDate(d["date_added"])
            switch d["type"] as? String {
            case "url":
                guard let url = d["url"] as? String, isImportable(url) else { return nil }
                return Node(title: name, url: url, dateAdded: date)
            case "folder":
                let kids = (d["children"] as? [[String: Any]] ?? []).compactMap(node)
                return Node(title: name, dateAdded: date, children: kids)
            default:
                return nil
            }
        }
        var top: [Node] = []
        for key in ["bookmark_bar", "other", "synced"] {
            guard let d = roots[key] as? [String: Any], var n = node(d), n.bookmarkCount > 0 else { continue }
            if n.title.isEmpty { n.title = key }
            top.append(n)
        }
        return Node(title: "", children: top)
    }

    /// Chrome zapisuje datę jako mikrosekundy od 1601-01-01.
    static func chromiumDate(_ v: Any?) -> Date? {
        guard let s = v as? String, let us = Double(s), us > 0 else { return nil }
        return Date(timeIntervalSince1970: us / 1_000_000 - 11_644_473_600)
    }

    /// Firefox: baza places.sqlite (czytana z kopii).
    static func loadFirefox(_ file: URL) throws -> Node {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "SafariBookmarks-import-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let copy = tmp.appending(path: "places.sqlite")
        try fm.copyItem(at: file, to: copy)
        for suffix in ["-wal", "-shm"] {
            let extra = URL(fileURLWithPath: file.path + suffix)
            if fm.fileExists(atPath: extra.path) { try? fm.copyItem(at: extra, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ImportError.unreadable
        }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT b.id, b.type, b.parent, b.position, b.title, b.dateAdded, p.url, b.guid
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ImportError.unreadable }
        defer { sqlite3_finalize(stmt) }
        struct Row { let id: Int64; let type: Int32; let title: String; let date: Date?; let url: String?; let guid: String }
        var rows: [Int64: Row] = [:]
        var children: [Int64: [Int64]] = [:]
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let usec = sqlite3_column_int64(stmt, 5)
            rows[id] = Row(id: id, type: sqlite3_column_int(stmt, 1), title: text(4) ?? "",
                           date: usec > 0 ? Date(timeIntervalSince1970: Double(usec) / 1_000_000) : nil,
                           url: text(6), guid: text(7) ?? "")
            children[sqlite3_column_int64(stmt, 2), default: []].append(id)
        }
        func node(_ id: Int64) -> Node? {
            guard let r = rows[id] else { return nil }
            switch r.type {
            case 1:
                guard let url = r.url, isImportable(url) else { return nil }
                return Node(title: r.title, url: url, dateAdded: r.date)
            case 2:
                return Node(title: r.title, dateAdded: r.date, children: (children[id] ?? []).compactMap(node))
            default:
                return nil  // separatory
            }
        }
        // Foldery główne Firefoksa (bez „tagów”).
        let names = ["toolbar_____": L("Pasek zakładek", "Bookmarks Toolbar"), "menu________": L("Menu zakładek", "Bookmarks Menu"),
                     "unfiled_____": L("Inne zakładki", "Other Bookmarks"), "mobile______": L("Zakładki z telefonu", "Mobile Bookmarks")]
        var top: [Node] = []
        for guid in ["toolbar_____", "menu________", "unfiled_____", "mobile______"] {
            guard let row = rows.values.first(where: { $0.guid == guid }), var n = node(row.id), n.bookmarkCount > 0 else { continue }
            n.title = names[guid] ?? n.title
            top.append(n)
        }
        return Node(title: "", children: top)
    }

    /// Plik HTML w formacie zakładek (Netscape) – eksport z dowolnej przeglądarki.
    static func loadHTML(_ file: URL) throws -> Node {
        guard let data = try? Data(contentsOf: file) else { throw ImportError.unreadable }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parseHTML(text)
    }

    static func parseHTML(_ text: String) -> Node {
        // Znaczniki, które nas interesują: <DL>, </DL>, <H3 …>nazwa</H3>, <A …>nazwa</A>.
        let pattern = #"<DL\b[^>]*>|</DL>|<H3\b([^>]*)>(.*?)</H3>|<A\b([^>]*)>(.*?)</A>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return Node(title: "", children: [])
        }
        let ns = text as NSString
        var stack: [Node] = [Node(title: "", children: [])]
        var pendingFolder: Node?
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range).lowercased()
            if tag.hasPrefix("<dl") {
                stack.append(pendingFolder ?? Node(title: "", children: []))
                pendingFolder = nil
            } else if tag.hasPrefix("</dl") {
                guard stack.count > 1 else { continue }
                let done = stack.removeLast()
                stack[stack.count - 1].children!.append(done)
            } else if tag.hasPrefix("<h3") {
                let attrs = group(m, 1) ?? ""
                pendingFolder = Node(title: decode(stripTags(group(m, 2) ?? "")), dateAdded: htmlDate(attrs), children: [])
            } else if tag.hasPrefix("<a") {
                let attrs = group(m, 3) ?? ""
                guard let href = attribute("HREF", in: attrs), isImportable(decode(href)) else { continue }
                stack[stack.count - 1].children!.append(
                    Node(title: decode(stripTags(group(m, 4) ?? "")), url: decode(href), dateAdded: htmlDate(attrs)))
            }
        }
        while stack.count > 1 {
            let done = stack.removeLast()
            stack[stack.count - 1].children!.append(done)
        }
        // Zewnętrzny <DL> pliku jest pustym folderem – rozpakuj go.
        var root = stack[0]
        if root.children?.count == 1, let only = root.children?.first, only.title.isEmpty, only.isFolder { root = only }
        return root
    }

    static func attribute(_ name: String, in attrs: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*\"([^\"]*)\"", options: .caseInsensitive),
              let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) else { return nil }
        return (attrs as NSString).substring(with: m.range(at: 1))
    }

    static func htmlDate(_ attrs: String) -> Date? {
        guard let s = attribute("ADD_DATE", in: attrs), let t = Double(s), t > 0 else { return nil }
        return Date(timeIntervalSince1970: t > 100_000_000_000 ? t / 1_000_000 : t)
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decode(_ s: String) -> String {
        var out = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Tylko adresy, które Safari może otworzyć (bez wewnętrznych stron przeglądarek).
    static func isImportable(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "mailto", "javascript"].contains(scheme)
    }

    // MARK: - Eksport

    /// Plik HTML z zakładkami: `top` – foldery i zakładki najwyższego poziomu (słowniki z pliku Safari).
    static func exportHTML(_ top: [(title: String, node: NSDictionary)], toolbarTitle: String?) -> String {
        var out = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>

            """
        func date(_ d: NSDictionary) -> String {
            guard let date = d["dateAdded"] as? Date else { return "" }
            return " ADD_DATE=\"\(Int(date.timeIntervalSince1970))\""
        }
        func write(_ d: NSDictionary, title: String, depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            switch d["WebBookmarkType"] as? String {
            case "WebBookmarkTypeList":
                let bar = title == toolbarTitle ? " PERSONAL_TOOLBAR_FOLDER=\"true\"" : ""
                out += "\(pad)<DT><H3\(date(d))\(bar)>\(escape(title))</H3>\n\(pad)<DL><p>\n"
                for child in d["Children"] as? [NSDictionary] ?? [] {
                    write(child, title: childTitle(child), depth: depth + 1)
                }
                out += "\(pad)</DL><p>\n"
            case "WebBookmarkTypeLeaf":
                guard let url = d["URLString"] as? String else { return }
                out += "\(pad)<DT><A HREF=\"\(escape(url))\"\(date(d))>\(escape(title))</A>\n"
            default:
                break
            }
        }
        for (title, node) in top { write(node, title: title, depth: 1) }
        out += "</DL><p>\n"
        return out
    }

    static func childTitle(_ d: NSDictionary) -> String {
        if d["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" {
            let t = (d["URIDictionary"] as? NSDictionary)?["title"] as? String ?? ""
            return t.isEmpty ? (d["URLString"] as? String ?? "") : t
        }
        return d["Title"] as? String ?? ""
    }
}
