import Foundation

/// Sprawdzanie adresów zakładek: martwe, przekierowane na stałe, możliwe https.
///
/// Każdy adres jest odwiedzany jak w przeglądarce, ale bez ciasteczek i zapisanych logowań;
/// po nagłówkach odpowiedzi połączenie jest przerywane (treść strony nie jest pobierana).
nonisolated enum LinkChecker {
    enum Verdict: Equatable {
        /// Strona odpowiada.
        case ok
        /// Przekierowanie na stałe pod nowy adres (propozycja poprawki).
        case redirected(to: String)
        /// Adres http działa też jako https (propozycja poprawki).
        case httpsAvailable(String)
        /// Strona nie istnieje albo serwer nie odpowiada.
        case dead(String)
        /// Nie da się ocenić (blokada, logowanie, czas minął…).
        case unsure(String)
    }

    struct Result: Identifiable {
        let id: String          // id zakładki
        let url: String
        let verdict: Verdict
    }

    /// Wynik pojedynczego zapytania.
    struct Probe {
        let status: Int?
        let finalURL: URL?
        /// Wszystkie przekierowania po drodze były stałe (301/308).
        let permanentOnly: Bool
        let redirected: Bool
        let error: URLError?
    }

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Sprawdza adresy, najwyżej `parallel` naraz. `progress` – po każdym sprawdzonym.
    static func check(_ items: [(id: String, url: String)], parallel: Int = 8,
                      progress: @escaping @MainActor (Result) -> Void) async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        await withTaskGroup(of: Result.self) { group in
            var it = items.makeIterator()
            for _ in 0..<parallel {
                guard let next = it.next() else { break }
                group.addTask { await verdict(for: next, session: session) }
            }
            while let r = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                await progress(r)
                if let next = it.next() { group.addTask { await verdict(for: next, session: session) } }
            }
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "text/html,application/xhtml+xml,*/*;q=0.8"]
        return URLSession(configuration: config)
    }

    static func verdict(for item: (id: String, url: String), session: URLSession) async -> Result {
        guard let url = URL(string: item.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            return Result(id: item.id, url: item.url, verdict: .unsure(L("To nie jest adres strony www.", "This is not a web address.")))
        }
        let p = await probe(url, session: session)
        let v = classify(original: url, probe: p)
        // http, które działa: sprawdź, czy jest też wersja https.
        if case .ok = v, scheme == "http", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if let https = c.url {
                let p2 = await probe(https, session: session)
                if let s = p2.status, (200..<400).contains(s), p2.error == nil {
                    return Result(id: item.id, url: item.url, verdict: .httpsAvailable(https.absoluteString))
                }
            }
        }
        return Result(id: item.id, url: item.url, verdict: v)
    }

    static func classify(original: URL, probe p: Probe) -> Verdict {
        let local = isInternalHost(original.host)
        let localNote = L("Adres w sieci lokalnej albo firmowej (np. przez VPN) – sprawdź go po połączeniu z tą siecią.",
                          "An address in a local or company network (e.g. over VPN) – check it when connected to that network.")
        if let e = p.error {
            switch e.code {
            case .cannotFindHost, .dnsLookupFailed:
                return local ? .unsure(localNote) : .dead(L("Domena nie istnieje.", "The domain does not exist."))
            case .cannotConnectToHost:
                // Serwer odmawia – to nie dowód, że strony nie ma (sieć firmowa, VPN, chwilowa awaria).
                return .unsure(local ? localNote : L("Serwer nie przyjmuje połączeń – może działa tylko w innej sieci albo ma chwilową awarię.",
                                                     "The server refuses connections – it may work only in another network or be down for a while."))
            case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return .unsure(local ? localNote : L("Strona nie odpowiedziała na czas.", "The page did not answer in time."))
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                return .unsure(L("Problem z certyfikatem strony.", "Problem with the site's certificate."))
            case .httpTooManyRedirects:
                return .unsure(L("Za dużo przekierowań.", "Too many redirects."))
            default:
                return .unsure(e.localizedDescription)
            }
        }
        guard let status = p.status else { return .unsure(L("Brak odpowiedzi.", "No answer.")) }
        switch status {
        case 404, 410:
            return .dead(L("Strony nie ma (\(status)).", "The page is gone (\(status))."))
        case 200..<400:
            if p.redirected, p.permanentOnly, let final = p.finalURL, final.absoluteString != original.absoluteString {
                // Konkretna strona przekierowuje na główną – zwykle znaczy, że jej już nie ma (np. produkt).
                if isRoot(final), !isRoot(original) {
                    return .dead(L("Przekierowuje na stronę główną – tej strony już nie ma.", "Redirects to the home page – this page is gone."))
                }
                return .redirected(to: final.absoluteString)
            }
            return .ok
        case 401, 403:
            return .unsure(L("Strona wymaga logowania albo blokuje sprawdzanie (\(status)).", "The page needs a login or blocks checking (\(status))."))
        case 429:
            return .unsure(L("Strona ogranicza liczbę wejść (429).", "The page limits visits (429)."))
        case 500..<600:
            return .unsure(L("Błąd serwera (\(status)).", "Server error (\(status))."))
        default:
            return .unsure(L("Nietypowa odpowiedź (\(status)).", "Unusual answer (\(status))."))
        }
    }

    /// Adres bez ścieżki i parametrów (strona główna).
    static func isRoot(_ url: URL) -> Bool {
        (url.path.isEmpty || url.path == "/") && (url.query ?? "").isEmpty
    }

    /// Nazwa serwera z sieci lokalnej albo firmowej: adres IP z puli prywatnej, nazwa bez kropki,
    /// końcówka z cyframi albo typowa dla sieci wewnętrznych (.local, .lan, .home, .internal…).
    static func isInternalHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !h.isEmpty else { return false }
        let parts = h.split(separator: ".").map(String.init)
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            let a = Int(parts[0])!, b = Int(parts[1])!
            return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        }
        if h.contains(":") { return h == "::1" || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80") }
        guard parts.count > 1, let tld = parts.last else { return true }
        if tld.contains(where: \.isNumber) { return true }
        return ["local", "lan", "home", "internal", "intranet", "corp", "localhost", "localdomain", "test", "invalid", "example", "private", "priv", "vpn"].contains(tld)
    }

    /// Jedno zapytanie: śledzi przekierowania, kończy po nagłówkach.
    static func probe(_ url: URL, session: URLSession) async -> Probe {
        let tracker = RedirectTracker()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: tracker)
            bytes.task.cancel()
            let http = response as? HTTPURLResponse
            return Probe(status: http?.statusCode, finalURL: response.url,
                         permanentOnly: tracker.permanentOnly, redirected: tracker.count > 0, error: nil)
        } catch {
            // Błąd sieci przychodzi raz jako URLError, raz jako NSError – sprowadzamy do jednego.
            let ns = error as NSError
            let e = (error as? URLError) ?? (ns.domain == NSURLErrorDomain ? URLError(URLError.Code(rawValue: ns.code)) : URLError(.unknown))
            let inner = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSURLErrorDomain ? URLError(URLError.Code(rawValue: $0.code)) : nil }
            return Probe(status: nil, finalURL: nil, permanentOnly: false, redirected: false, error: e.code == .unknown ? (inner ?? e) : e)
        }
    }

    /// Zapamiętuje rodzaj przekierowań.
    final class RedirectTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _permanentOnly = true
        var count: Int { lock.withLock { _count } }
        var permanentOnly: Bool { lock.withLock { _permanentOnly } }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                    newRequest request: URLRequest) async -> URLRequest? {
            let n = lock.withLock {
                _count += 1
                if response.statusCode != 301 && response.statusCode != 308 { _permanentOnly = false }
                return _count
            }
            return n > 10 ? nil : request
        }
    }

    /// Adresy pomijane na stałe (wybór użytkownika „Pomijaj”), po UUID zakładki.
    static var skipped: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "LinkCheckSkipped") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "LinkCheckSkipped") }
    }
}
