import Foundation

/// Lista zmian dla iCloud.
///
/// Program synchronizujący Safari (SafariBookmarksSyncAgent) nie porównuje pliku z chmurą –
/// wysyła tylko zmiany wpisane do `Sync.Changes` w korzeniu pliku. Safari dopisuje je samo;
/// my dopisujemy je w tym samym formacie (sprawdzonym na kodzie Safari):
///
/// - nowy folder albo zakładka: `Type = Add` (bez `BookmarkServerID` – iCloud nada go sam),
/// - przeniesienie albo zmiana kolejności: `Type = Modify`, `IsMove = true`,
/// - nowa nazwa albo adres: `Type = Modify`, `ChangedAttributes = [Title]` (folder) albo `[Title, URL]` (zakładka),
/// - usunięcie: `Type = Delete` z `DeletedBookmarkSyncData` = dotychczasowe `Sync.Data`,
///   osobno dla każdej usuniętej zakładki i folderu, najpierw zawartość, potem folder.
///
/// Każdy wpis ma też `Token` (nowy UUID), `BookmarkType` (`Leaf`/`Folder`), `BookmarkUUID`
/// i `BookmarkServerID` (jeśli element był już w iCloud).
enum SyncChanges {
    static let key = "Changes"

    /// Czy plik korzysta z iCloud (Safari nie notuje zmian, gdy synchronizacja jest wyłączona).
    static func isSynced(_ root: NSDictionary) -> Bool {
        (root["Sync"] as? NSDictionary)?["CloudKitMigrationState"] != nil
    }

    /// Dopisuje do `candidate` zmiany względem `original`. Zwraca liczbę dopisanych wpisów.
    @discardableResult
    static func record(original: NSDictionary, into candidate: NSMutableDictionary) -> Int {
        guard isSynced(original) else { return 0 }
        let entries = changes(from: original, to: candidate)
        guard !entries.isEmpty else { return 0 }
        let sync = NSMutableDictionary(dictionary: candidate["Sync"] as? NSDictionary ?? [:])
        let list = NSMutableArray(array: sync[key] as? [Any] ?? [])
        list.addObjects(from: entries)
        sync[key] = list
        candidate["Sync"] = sync
        return entries.count
    }

    // MARK: - Porównanie drzew

    struct Place {
        let node: NSDictionary
        let parent: String?
        let index: Int
    }

    /// Węzły z unikalnym UUID: UUID → miejsce. `order` – rodzic przed dziećmi,
    /// `postOrder` – dzieci przed rodzicem (kolejność usuwania w Safari).
    static func index(_ root: NSDictionary) -> (places: [String: Place], order: [String], postOrder: [String]) {
        var counts: [String: Int] = [:]
        var places: [String: Place] = [:]
        var order: [String] = []
        var postOrder: [String] = []
        func walk(_ node: NSDictionary, parent: String?, index: Int) {
            let uuid = node["WebBookmarkUUID"] as? String
            if let uuid {
                counts[uuid, default: 0] += 1
                places[uuid] = Place(node: node, parent: parent, index: index)
                order.append(uuid)
            }
            for (i, child) in (node["Children"] as? [NSDictionary] ?? []).enumerated() {
                walk(child, parent: uuid, index: i)
            }
            if let uuid { postOrder.append(uuid) }
        }
        walk(root, parent: nil, index: 0)
        let unique = places.filter { counts[$0.key] == 1 }
        return (unique, order.filter { unique[$0] != nil }, postOrder.filter { unique[$0] != nil })
    }

    static func changes(from original: NSDictionary, to candidate: NSDictionary) -> [NSDictionary] {
        let old = index(original)
        let new = index(candidate)
        // Korzeń i stałe foldery Safari nie są edytowalne.
        var fixed: Set<String> = []
        if let r = original["WebBookmarkUUID"] as? String { fixed.insert(r) }
        for c in original["Children"] as? [NSDictionary] ?? [] {
            if let u = c["WebBookmarkUUID"] as? String { fixed.insert(u) }
        }

        var adds: [NSDictionary] = []
        var moves: [NSDictionary] = []
        var renames: [NSDictionary] = []
        var deletes: [NSDictionary] = []

        // Przeniesienia: wszystko, co zmieniło folder, a w tym samym folderze – to, co wypadło
        // z najdłuższego ciągu zachowanej kolejności (tyle, ile przeciągnąłby użytkownik).
        var moved: Set<String> = []
        var childrenByParent: [String: [String]] = [:]
        for uuid in new.order {
            guard let p = new.places[uuid]?.parent else { continue }
            childrenByParent[p, default: []].append(uuid)
        }
        for (parent, children) in childrenByParent {
            let stayed = children.filter { old.places[$0]?.parent == parent }
            for uuid in children where old.places[uuid] != nil && old.places[uuid]?.parent != parent {
                moved.insert(uuid)
            }
            let keep = longestIncreasing(stayed.map { old.places[$0]!.index })
            for (i, uuid) in stayed.enumerated() where !keep.contains(i) {
                moved.insert(uuid)
            }
        }

        // Nowe foldery i zakładki (rodzic przed dziećmi, przed przeniesieniami do nich).
        for uuid in new.order where old.places[uuid] == nil {
            guard let node = new.places[uuid]?.node, let type = bookmarkType(node) else { continue }
            adds.append(entry(type: "Add", bookmarkType: type, node: node, extra: [:]))
        }

        for uuid in new.order where !fixed.contains(uuid) {
            guard let before = old.places[uuid], let after = new.places[uuid],
                  let type = bookmarkType(after.node) else { continue }
            if moved.contains(uuid) {
                moves.append(entry(type: "Modify", bookmarkType: type, node: before.node, extra: ["IsMove": true]))
            }
            let urlChanged = type == "Leaf" && (before.node["URLString"] as? String) != (after.node["URLString"] as? String)
            if title(before.node) != title(after.node) || urlChanged {
                let attrs = type == "Leaf" ? ["Title", "URL"] : ["Title"]
                renames.append(entry(type: "Modify", bookmarkType: type, node: before.node, extra: ["ChangedAttributes": attrs]))
            }
        }

        // Usunięcia: zawartość przed folderem (jak w Safari).
        for uuid in old.postOrder where new.places[uuid] == nil && !fixed.contains(uuid) {
            guard let node = old.places[uuid]?.node, let type = bookmarkType(node) else { continue }
            var extra: [String: Any] = [:]
            if let data = (node["Sync"] as? NSDictionary)?["Data"] { extra["DeletedBookmarkSyncData"] = data }
            deletes.append(entry(type: "Delete", bookmarkType: type, node: node, extra: extra))
        }
        return adds + moves + renames + deletes
    }

    static func entry(type: String, bookmarkType: String, node: NSDictionary, extra: [String: Any]) -> NSDictionary {
        let d = NSMutableDictionary(dictionary: extra)
        d["Token"] = UUID().uuidString
        d["Type"] = type
        d["BookmarkType"] = bookmarkType
        d["BookmarkUUID"] = node["WebBookmarkUUID"]
        if let server = (node["Sync"] as? NSDictionary)?["ServerID"] { d["BookmarkServerID"] = server }
        return d
    }

    static func bookmarkType(_ node: NSDictionary) -> String? {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf": "Leaf"
        case "WebBookmarkTypeList": "Folder"
        default: nil
        }
    }

    private static func title(_ node: NSDictionary) -> String? {
        if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf" {
            return (node["URIDictionary"] as? NSDictionary)?["title"] as? String
        }
        return node["Title"] as? String
    }

    /// Indeksy elementów najdłuższego rosnącego podciągu.
    static func longestIncreasing(_ a: [Int]) -> Set<Int> {
        guard !a.isEmpty else { return [] }
        var tails: [Int] = []          // indeksy w `a`
        var prev = [Int](repeating: -1, count: a.count)
        for i in a.indices {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if a[tails[mid]] < a[i] { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var result: Set<Int> = []
        var k = tails.last!
        while k >= 0 { result.insert(k); k = prev[k] }
        return result
    }
}
