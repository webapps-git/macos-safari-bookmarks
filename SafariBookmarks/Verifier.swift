import CryptoKit
import Foundation

/// Kontrola przed zapisem. Porównuje nowy plik ze stanem wczytanym z dysku.
///
/// Wolno zmienić tylko: kolejność i rodziców węzłów, Title folderu, URIDictionary.title zakładki,
/// usunąć całe poddrzewa, które użytkownik jawnie usunął, dodać nowe foldery i zakładki, i dopisać wpisy do listy zmian
/// dla iCloud (`Sync.Changes` w korzeniu). Wszystko inne (UUID, Sync węzłów, URL, daty,
/// pozostałe klucze, korzeń, foldery główne) musi być identyczne.
enum Verifier {
    /// Stan pliku w chwili wczytania.
    struct Baseline {
        let fileHash: String
        let scan: Scan
    }

    /// Co użytkownik jawnie usunął (sumarycznie, od ostatniego zapisu) i jakie foldery założył.
    struct Removed: Equatable {
        var uuidCounts: [String: Int] = [:]
        /// UUID nowych folderów i zakładek.
        var added: [String: Int] = [:]
        /// Ile nowych zakładek dodał użytkownik.
        var addedLeaves = 0
        /// Wpisy dla iCloud dosłane ze starych zapisów (Token).
        var resent: Set<String> = []
        var leaves = 0
        var missingUUID = 0

        mutating func add(_ s: Scan) {
            for (k, v) in s.uuidCounts { uuidCounts[k, default: 0] += v }
            leaves += s.leaves
            missingUUID += s.missingUUID
        }
    }

    struct Scan {
        var uuidCounts: [String: Int] = [:]
        var leaves = 0
        var missingUUID = 0
        /// UUID → słownik węzła bez Children i bez nazwy (tylko dla UUID unikalnych).
        var attrs: [String: NSDictionary] = [:]
        /// Korzeń bez Children i bez listy zmian dla iCloud.
        var rootAttrs: NSDictionary = [:]
        /// Lista zmian dla iCloud (`Sync.Changes`).
        var changes: [NSDictionary] = []
        /// UUID folderów głównych w kolejności.
        var topLevel: [String] = []
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func baseline(data: Data, root: NSDictionary) -> Baseline {
        Baseline(fileHash: hash(data), scan: scan(root: root))
    }

    static func scan(root: NSDictionary) -> Scan {
        var s = Scan()
        let rootCopy = stripped(root, keepTitle: true)
        s.changes = (root["Sync"] as? NSDictionary)?[SyncChanges.key] as? [NSDictionary] ?? []
        s.rootAttrs = rootCopy
        s.topLevel = (root["Children"] as? [NSDictionary] ?? []).map { $0["WebBookmarkUUID"] as? String ?? "?" }
        var seenAttrs: [String: NSDictionary] = [:]
        walk(root, into: &s, attrs: &seenAttrs)
        s.attrs = seenAttrs.filter { s.uuidCounts[$0.key] == 1 }
        return s
    }

    /// Skan poddrzewa (z węzłem) – do zliczenia tego, co jest usuwane.
    static func scan(subtree node: NSDictionary) -> Scan {
        var s = Scan()
        var ignored: [String: NSDictionary] = [:]
        walk(node, into: &s, attrs: &ignored)
        return s
    }

    private static func walk(_ node: NSDictionary, into s: inout Scan, attrs: inout [String: NSDictionary]) {
        if let uuid = node["WebBookmarkUUID"] as? String {
            s.uuidCounts[uuid, default: 0] += 1
            attrs[uuid] = stripped(node, keepTitle: false)
        } else {
            s.missingUUID += 1
        }
        if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" { s.leaves += 1 }
        for child in node["Children"] as? [NSDictionary] ?? [] {
            walk(child, into: &s, attrs: &attrs)
        }
    }

    /// Słownik węzła bez Children i (opcjonalnie) bez pól nazwy.
    private static func stripped(_ node: NSDictionary, keepTitle: Bool) -> NSDictionary {
        let copy = NSMutableDictionary(dictionary: node)
        copy.removeObject(forKey: "Children")
        // Lista zmian dla iCloud (tylko w korzeniu) jest sprawdzana osobno.
        if let sync = node["Sync"] as? NSDictionary, sync[SyncChanges.key] != nil {
            let s = NSMutableDictionary(dictionary: sync)
            s.removeObject(forKey: SyncChanges.key)
            copy["Sync"] = s
        }
        if !keepTitle {
            copy.removeObject(forKey: "Title")
            if let uri = node["URIDictionary"] as? NSDictionary {
                let u = NSMutableDictionary(dictionary: uri)
                u.removeObject(forKey: "title")
                copy["URIDictionary"] = u
            }
        }
        return copy
    }

    /// Ten sam słownik bez danych iCloud.
    private static func withoutSync(_ d: NSDictionary) -> NSDictionary {
        let copy = NSMutableDictionary(dictionary: d)
        copy.removeObject(forKey: "Sync")
        return copy
    }

    /// Zwraca listę problemów. Pusta lista = można zapisać.
    ///
    /// `syncMayChange` – kontrola pliku już po zapisie: program synchronizujący iCloud
    /// mógł w tym czasie przetworzyć listę zmian i odświeżyć dane `Sync`.
    static func check(candidate data: Data, against base: Baseline, removed: Removed, syncMayChange: Bool = false) -> [String] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else {
            return [L("Nie udało się odczytać przygotowanego pliku.", "Could not read the prepared file.")]
        }
        let new = scan(root: root)
        let old = base.scan
        var problems: [String] = []

        // 1. Zbiór UUID (z krotnościami) = stary + nowe foldery i zakładki − usunięte.
        var expected = old.uuidCounts
        for (k, v) in removed.added { expected[k, default: 0] += v }
        for (k, v) in removed.uuidCounts {
            expected[k, default: 0] -= v
            if expected[k] == 0 { expected[k] = nil }
        }
        let missing = expected.filter { new.uuidCounts[$0.key, default: 0] < $0.value }.map(\.key)
        let extra = new.uuidCounts.filter { $0.value > expected[$0.key, default: 0] }.map(\.key)
        if !missing.isEmpty {
            problems.append(L("Brakuje \(missing.count) elem., których nie usuwałeś.", "\(missing.count) item(s) you did not delete are missing."))
        }
        if !extra.isEmpty {
            problems.append(L("Pojawiło się \(extra.count) elem., których wcześniej nie było.", "\(extra.count) item(s) appeared that were not there before."))
        }

        // 2. Liczba zakładek i węzłów bez UUID.
        let expectedLeaves = old.leaves - removed.leaves + removed.addedLeaves
        if new.leaves != expectedLeaves {
            problems.append(L("Liczba zakładek się nie zgadza: jest \(new.leaves), powinno być \(expectedLeaves).", "The number of bookmarks does not match: \(new.leaves), expected \(expectedLeaves)."))
        }
        let expectedMissing = old.missingUUID - removed.missingUUID
        if new.missingUUID != expectedMissing {
            problems.append(L("Liczba uszkodzonych wpisów się zmieniła (jest \(new.missingUUID), było \(expectedMissing)).", "The number of damaged entries changed (now \(new.missingUUID), was \(expectedMissing))."))
        }

        // 3. Każdy węzeł: wszystko poza nazwą bez zmian (UUID, Sync, URL, typ, daty…).
        var changed: [String] = []
        for (uuid, attrs) in new.attrs {
            guard let before = old.attrs[uuid] else { continue }
            let same = syncMayChange ? withoutSync(before).isEqual(withoutSync(attrs)) : before.isEqual(attrs)
            if !same { changed.append(uuid) }
        }
        if !changed.isEmpty {
            problems.append(L("W \(changed.count) elem. zmieniło się coś więcej niż nazwa (np. adres albo dane iCloud).", "In \(changed.count) item(s) more than the name changed (for example the address or iCloud data)."))
        }

        // 4. Korzeń i foldery główne nietknięte.
        let sameRoot = syncMayChange ? withoutSync(old.rootAttrs).isEqual(withoutSync(new.rootAttrs)) : old.rootAttrs.isEqual(new.rootAttrs)
        if !sameRoot {
            problems.append(L("Zmieniły się ogólne dane pliku zakładek.", "The general data of the bookmarks file changed."))
        }

        // 5. Lista zmian dla iCloud: stare wpisy bez zmian, nowe tylko dla istniejących albo usuniętych elementów.
        if !syncMayChange {
            let prefixOK = new.changes.count >= old.changes.count
                && zip(old.changes, new.changes).allSatisfy { $0.isEqual($1) }
            let added = prefixOK ? Array(new.changes.dropFirst(old.changes.count)) : []
            let badEntry = added.contains { e in
                guard let uuid = e["BookmarkUUID"] as? String else { return true }
                // Dosłane stare zmiany: przeniesienie/nazwa istniejącego elementu albo usunięcie elementu, którego już nie ma.
                if let token = e["Token"] as? String, removed.resent.contains(token) {
                    switch e["Type"] as? String {
                    case "Modify": return old.uuidCounts[uuid] != 1 || new.uuidCounts[uuid] != 1
                    case "Delete": return old.uuidCounts[uuid] != nil || new.uuidCounts[uuid] != nil
                    default: return true
                    }
                }
                if e["Type"] as? String == "Add" {
                    return removed.added[uuid] == nil || old.uuidCounts[uuid] != nil || new.uuidCounts[uuid] != 1
                }
                guard old.uuidCounts[uuid] == 1 else { return true }
                switch e["Type"] as? String {
                case "Modify": return new.uuidCounts[uuid] != 1
                case "Delete": return removed.uuidCounts[uuid] == nil || new.uuidCounts[uuid] != nil
                default: return true
                }
            }
            if !prefixOK || badEntry {
                problems.append(L("Lista zmian dla iCloud się nie zgadza.", "The list of changes for iCloud does not match."))
            }
        }
        if old.topLevel != new.topLevel {
            problems.append(L("Zmienił się układ stałych folderów Safari.", "The layout of Safari's built-in folders changed."))
        }
        return problems
    }
}
