import AppKit
import CryptoKit
import SQLite3

/// Ikonki stron przy zakładkach.
///
/// Najpierw z pamięci ikonek samego Safari (`~/Library/Safari/Favicon Cache`: baza favicons.db
/// – adres strony → identyfikator ikonki; plik ikonki nazywa się MD5 tego identyfikatora),
/// potem z własnej pamięci aplikacji, a na końcu – jeśli włączone – pobierane ze strony
/// (favicon.ico albo <link rel="icon"> z początku strony) i zapisywane u nas.
/// Ikonki są wspólne dla całej domeny (nazwy strony).
final class Favicons {
    static let shared = Favicons()
    /// Wysyłane, gdy doszły nowe ikonki – listy odświeżają widoczne wiersze.
    static let didChange = Notification.Name("FaviconsDidChange")

    /// Czy pobierać brakujące ikonki ze stron (ustawienie w menu).
    static var fetchFromWeb: Bool {
        get { UserDefaults.standard.object(forKey: "FetchFavicons") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "FetchFavicons") }
    }

    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var queued: Set<String> = []
    private var waiting: [(host: String, page: URL)] = []
    private var running = 0
    private var safariByPage: [String: String] = [:]
    private var safariByHost: [String: String] = [:]
    private var safariLoaded = false
    private var notifyScheduled = false

    private let safariDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari/Favicon Cache")
    private lazy var cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: Bundle.main.bundleIdentifier ?? "SafariBookmarks").appending(path: "Favicons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Ikonka dla adresu albo nil (wtedy – jeśli trzeba – zaczyna jej szukać w tle).
    func icon(for urlString: String?) -> NSImage? {
        guard let s = urlString, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
        if let img = memory[host] { return img }
        if missing.contains(host) || queued.contains(host) { return nil }
        loadSafariIfNeeded()
        if let uuid = safariByPage[s] ?? safariByHost[host], let img = safariImage(uuid) {
            return remember(img, host: host)
        }
        if let data = try? Data(contentsOf: cacheFile(host)), let img = NSImage(data: data) {
            return remember(img, host: host)
        }
        // Wcześniej nie znaleziono – spróbuj znowu dopiero po tygodniu.
        if let date = (try? FileManager.default.attributesOfItem(atPath: missingFile(host).path))?[.modificationDate] as? Date,
           Date.now.timeIntervalSince(date) < 7 * 24 * 3600 {
            missing.insert(host)
            return nil
        }
        guard Self.fetchFromWeb else { missing.insert(host); return nil }
        queued.insert(host)
        waiting.append((host, url))
        startNext()
        return nil
    }

    private func remember(_ img: NSImage, host: String) -> NSImage {
        img.size = NSSize(width: 16, height: 16)
        memory[host] = img
        return img
    }

    // MARK: - Pamięć ikonek Safari

    private func loadSafariIfNeeded() {
        guard !safariLoaded else { return }
        safariLoaded = true
        let fm = FileManager.default
        let db = safariDir.appending(path: "favicons.db")
        guard fm.fileExists(atPath: db.path) else { return }
        // Kopia, żeby nie przeszkadzać Safari (baza bywa otwarta).
        let tmp = fm.temporaryDirectory.appending(path: "SafariBookmarks-favicons-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return }
        let copy = tmp.appending(path: "favicons.db")
        guard (try? fm.copyItem(at: db, to: copy)) != nil else { return }
        for suffix in ["-wal", "-shm"] {
            let extra = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: extra.path) { try? fm.copyItem(at: extra, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(handle); return }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        let sql = "SELECT p.url, i.uuid FROM page_url p JOIN icon_info i ON i.uuid = p.uuid ORDER BY i.width DESC"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_text(stmt, 0), let u = sqlite3_column_text(stmt, 1) else { continue }
            let page = String(cString: p), uuid = String(cString: u)
            if safariByPage[page] == nil { safariByPage[page] = uuid }
            if let host = URL(string: page)?.host?.lowercased(), safariByHost[host] == nil { safariByHost[host] = uuid }
        }
    }

    private func safariImage(_ uuid: String) -> NSImage? {
        let name = Insecure.MD5.hash(data: Data(uuid.utf8)).map { String(format: "%02X", $0) }.joined()
        return NSImage(contentsOf: safariDir.appending(path: "favicons").appending(path: name))
    }

    // MARK: - Pobieranie ze stron

    private func cacheFile(_ host: String) -> URL { cacheDir.appending(path: host + ".icon") }
    private func missingFile(_ host: String) -> URL { cacheDir.appending(path: host + ".none") }

    private func startNext() {
        while running < 4, !waiting.isEmpty {
            let job = waiting.removeFirst()
            running += 1
            Task {
                let data = await Self.fetch(page: job.page)
                self.finish(job.host, data: data)
            }
        }
    }

    private func finish(_ host: String, data: Data?) {
        running -= 1
        queued.remove(host)
        if let data, let img = NSImage(data: data), img.size.width > 0 {
            try? data.write(to: cacheFile(host), options: .atomic)
            _ = remember(img, host: host)
            scheduleNotify()
        } else {
            missing.insert(host)
            try? Data().write(to: missingFile(host))
        }
        startNext()
    }

    /// Jedno odświeżenie list na wiele ikonek naraz.
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            notifyScheduled = false
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    nonisolated static func fetch(page: URL) async -> Data? {
        let session = LinkChecker.makeSession()
        defer { session.finishTasksAndInvalidate() }
        var c = URLComponents()
        c.scheme = page.scheme
        c.host = page.host
        c.port = page.port
        c.path = "/favicon.ico"
        if let ico = c.url, let data = await download(ico, session: session, limit: 300_000), looksLikeImage(data) {
            return data
        }
        // Strona może wskazywać ikonkę w nagłówku: <link rel="icon" href="…">.
        guard let html = await download(page, session: session, limit: 200_000),
              let text = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1),
              let href = iconHref(in: text), let iconURL = URL(string: href, relativeTo: page)?.absoluteURL,
              let data = await download(iconURL, session: session, limit: 300_000), looksLikeImage(data) else { return nil }
        return data
    }

    nonisolated static func download(_ url: URL, session: URLSession, limit: Int) async -> Data? {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { bytes.task.cancel(); return nil }
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count >= limit { bytes.task.cancel(); break }
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    nonisolated static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count > 16, let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.representations.first as? NSBitmapImageRep else {
            return NSImage(data: data) != nil && data.count > 16
        }
        return rep.pixelsWide > 0
    }

    nonisolated static func iconHref(in html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return nil }
        let ns = html as NSString
        var best: (score: Int, href: String)?
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let rel = ImportExport.attribute("rel", in: tag.replacingOccurrences(of: "'", with: "\""))?.lowercased(),
                  rel.contains("icon"), let href = ImportExport.attribute("href", in: tag.replacingOccurrences(of: "'", with: "\"")) else { continue }
            // Zwykła ikonka przed ikonką dla iPhone'a (ta bywa duża); pomiń maskowane SVG Safari.
            let score = rel.contains("mask") ? 0 : (rel == "icon" || rel == "shortcut icon" ? 3 : 2)
            if score > (best?.score ?? 0) { best = (score, ImportExport.decode(href)) }
        }
        return best?.href
    }
}
