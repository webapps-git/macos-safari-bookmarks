import Foundation

/// Węzeł drzewa zakładek do wyświetlania. Niezmienny – budowany od nowa po każdej edycji.
struct BookmarkNode: Identifiable, Hashable {
    enum Kind: String {
        case folder = "WebBookmarkTypeList"
        case leaf = "WebBookmarkTypeLeaf"
        case proxy = "WebBookmarkTypeProxy"
        case unknown
    }

    /// WebBookmarkUUID, a jeśli go brak albo jest zdublowany – sztuczny identyfikator „missing-N”.
    let id: String
    let uuid: String?
    let kind: Kind
    /// Surowy tytuł z pliku (dla folderów specjalnych np. „BookmarksBar”).
    let rawTitle: String
    let url: String?
    let children: [BookmarkNode]?
    let hasSync: Bool
    let dateAdded: Date?
    /// Klucze słownika (bez Children) z podglądem wartości – do inspektora.
    let attributes: [Attribute]
    /// Liczba zakładek (liści) w całym poddrzewie.
    let leafCount: Int
    /// Liczba folderów w całym poddrzewie (bez tego węzła).
    let folderCount: Int

    struct Attribute: Hashable {
        let key: String
        let preview: String
    }

    var hasUUID: Bool { uuid != nil }
    var isFolder: Bool { kind == .folder }
    var isReadingListRoot: Bool { kind == .folder && rawTitle == "com.apple.ReadingList" }

    var title: String {
        switch rawTitle {
        case "BookmarksBar": L("Ulubione", "Favorites")
        case "BookmarksMenu": L("Menu zakładek", "Bookmarks Menu")
        case "com.apple.ReadingList": L("Lista Czytelnicza", "Reading List")
        case "History" where kind == .proxy: L("Historia", "History")
        default: rawTitle.isEmpty ? (url ?? L("(bez nazwy)", "(untitled)")) : rawTitle
        }
    }

    var systemImage: String {
        switch kind {
        case .folder:
            switch rawTitle {
            case "BookmarksBar": "star"
            case "BookmarksMenu": "menubar.rectangle"
            case "com.apple.ReadingList": "eyeglasses"
            default: "folder"
            }
        case .leaf: "bookmark"
        case .proxy: "clock"
        case .unknown: "questionmark.square"
        }
    }

    static func == (lhs: BookmarkNode, rhs: BookmarkNode) -> Bool {
        lhs.id == rhs.id && lhs.rawTitle == rhs.rawTitle && lhs.leafCount == rhs.leafCount
            && lhs.children?.map(\.id) == rhs.children?.map(\.id)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drzewo do wyświetlania + indeksy.
struct BookmarkTree {
    let root: BookmarkNode
    /// id węzła → id rodzica
    let parent: [String: String]
    /// id węzła → węzeł
    let byID: [String: BookmarkNode]
    /// id węzła → pozycja w kolejności „od góry do dołu”
    let order: [String: Int]
    let stats: Stats

    struct Stats {
        var leaves = 0
        var folders = 0
        var proxies = 0
        var missingUUID = 0
        var duplicateUUIDs: Set<String> = []
        var withSync = 0
    }

    /// Przodkowie węzła od góry (bez korzenia).
    func path(of id: String) -> [BookmarkNode] {
        var result: [BookmarkNode] = []
        var current = parent[id]
        while let c = current, c != root.id, let node = byID[c] {
            result.insert(node, at: 0)
            current = parent[c]
        }
        return result
    }

    func pathString(of id: String) -> String {
        path(of: id).map(\.title).joined(separator: " › ")
    }

    func isDescendant(_ id: String, of ancestor: String) -> Bool {
        var current = parent[id]
        while let c = current {
            if c == ancestor { return true }
            current = parent[c]
        }
        return false
    }
}

enum BookmarkParser {
    static func parse(_ dict: [String: Any]) -> BookmarkTree {
        var builder = Builder()
        // Pierwsze przejście: które UUID występują więcej niż raz.
        builder.countUUIDs(dict)
        let root = builder.build(dict, parentID: nil)
        return BookmarkTree(root: root, parent: builder.parent, byID: builder.byID, order: builder.order, stats: builder.stats)
    }

    private struct Builder {
        var parent: [String: String] = [:]
        var byID: [String: BookmarkNode] = [:]
        var order: [String: Int] = [:]
        var uuidCounts: [String: Int] = [:]
        var stats = BookmarkTree.Stats()
        var missingCounter = 0

        mutating func countUUIDs(_ dict: [String: Any]) {
            if let uuid = dict["WebBookmarkUUID"] as? String { uuidCounts[uuid, default: 0] += 1 }
            for child in dict["Children"] as? [[String: Any]] ?? [] { countUUIDs(child) }
        }

        mutating func build(_ dict: [String: Any], parentID: String?) -> BookmarkNode {
            let kind = BookmarkNode.Kind(rawValue: dict["WebBookmarkType"] as? String ?? "") ?? .unknown
            let rawUUID = dict["WebBookmarkUUID"] as? String
            let uuid: String?
            if let rawUUID, uuidCounts[rawUUID, default: 0] == 1 {
                uuid = rawUUID
            } else {
                uuid = nil
                if let rawUUID { stats.duplicateUUIDs.insert(rawUUID) } else { stats.missingUUID += 1 }
            }
            let id: String
            if let uuid {
                id = uuid
            } else {
                missingCounter += 1
                id = "missing-\(missingCounter)"
            }
            order[id] = order.count
            if dict["Sync"] != nil { stats.withSync += 1 }

            let title: String
            if kind == .leaf {
                title = (dict["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            } else {
                title = dict["Title"] as? String ?? ""
            }

            var children: [BookmarkNode]?
            var leafCount = 0
            var folderCount = 0
            switch kind {
            case .folder:
                stats.folders += 1
                let raw = dict["Children"] as? [[String: Any]] ?? []
                let built = raw.map { build($0, parentID: id) }
                children = built
                for c in built {
                    leafCount += c.leafCount + (c.kind == .leaf ? 1 : 0)
                    folderCount += c.folderCount + (c.kind == .folder ? 1 : 0)
                }
            case .leaf:
                stats.leaves += 1
            case .proxy:
                stats.proxies += 1
            case .unknown:
                break
            }

            let attributes = dict.keys.sorted().filter { $0 != "Children" }.map {
                BookmarkNode.Attribute(key: $0, preview: Self.preview(dict[$0]))
            }

            let node = BookmarkNode(
                id: id,
                uuid: uuid,
                kind: kind,
                rawTitle: title,
                url: dict["URLString"] as? String,
                children: children,
                hasSync: dict["Sync"] != nil,
                dateAdded: dict["dateAdded"] as? Date,
                attributes: attributes,
                leafCount: leafCount,
                folderCount: folderCount
            )
            byID[id] = node
            if let parentID { parent[id] = parentID }
            return node
        }

        static func preview(_ value: Any?, depth: Int = 0) -> String {
            switch value {
            case let s as String: return s
            case let d as Data: return "<\(d.count) B>"
            case let date as Date: return date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(AppLanguage.locale))
            case let n as NSNumber: return n.stringValue
            case let a as [Any]: return "[\(a.count)]"
            case let d as [String: Any]:
                guard depth < 1 else { return "{\(d.count)}" }
                return "{ " + d.keys.sorted().map { "\($0): \(preview(d[$0], depth: depth + 1))" }.joined(separator: ", ") + " }"
            case nil: return "—"
            default: return String(describing: value!)
            }
        }
    }
}
