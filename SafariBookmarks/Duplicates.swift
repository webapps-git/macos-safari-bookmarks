import Foundation

/// Wyszukiwanie zdublowanych zakładek (Lista Czytelnicza pominięta).
enum Duplicates {
    struct Group: Identifiable {
        /// Adres wspólny dla grupy (dla grup „prawie identycznych” – uproszczony).
        let key: String
        /// Wszystkie adresy w grupie są dokładnie takie same.
        let identical: Bool
        /// Zakładki w kolejności „która najlepiej zostać” (pierwsza – propozycja do zostawienia).
        let items: [BookmarkNode]
        var id: String { (identical ? "=" : "~") + key }
    }

    /// Uproszczony adres: bez http/https, bez „www.”, bez ukośnika na końcu, nazwa strony małymi literami.
    static func looseKey(_ url: String) -> String {
        guard var c = URLComponents(string: url), let host = c.host?.lowercased() else {
            return url.lowercased()
        }
        let scheme = c.scheme?.lowercased()
        var h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = c.port, !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) { h += ":\(port)" }
        c.scheme = nil
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        var key = h + path
        if let q = c.percentEncodedQuery, !q.isEmpty { key += "?" + q }
        if let f = c.percentEncodedFragment, !f.isEmpty { key += "#" + f }
        return key
    }

    /// Grupy duplikatów: najpierw identyczne, potem prawie identyczne; w obu – w kolejności drzewa.
    static func find(in tree: BookmarkTree) -> [Group] {
        var leaves: [BookmarkNode] = []
        func visit(_ node: BookmarkNode) {
            for child in node.children ?? [] {
                if child.isReadingListRoot { continue }
                if child.kind == .leaf, child.uuid != nil, let url = child.url, !url.isEmpty { leaves.append(child) }
                visit(child)
            }
        }
        visit(tree.root)

        // Identyczne: ten sam adres co do znaku.
        var byExact: [String: [BookmarkNode]] = [:]
        var exactOrder: [String] = []
        // Prawie identyczne: ten sam adres po uproszczeniu, ale różne zapisy.
        var byLoose: [String: [BookmarkNode]] = [:]
        var looseOrder: [String] = []
        for leaf in leaves {
            let url = leaf.url!
            if byExact[url] == nil { exactOrder.append(url) }
            byExact[url, default: []].append(leaf)
            let k = looseKey(url)
            if byLoose[k] == nil { looseOrder.append(k) }
            byLoose[k, default: []].append(leaf)
        }

        let identical = exactOrder.compactMap { url -> Group? in
            guard let items = byExact[url], items.count > 1 else { return nil }
            return Group(key: url, identical: true, items: rank(items, in: tree))
        }
        let similar = looseOrder.compactMap { k -> Group? in
            guard let items = byLoose[k], Set(items.compactMap(\.url)).count > 1 else { return nil }
            return Group(key: k, identical: false, items: rank(items, in: tree))
        }
        return identical + similar
    }

    /// Kolejność propozycji: w Ulubionych przed resztą, https przed http, potem najstarsza, potem wyżej w drzewie.
    static func rank(_ items: [BookmarkNode], in tree: BookmarkTree) -> [BookmarkNode] {
        func inFavorites(_ n: BookmarkNode) -> Bool { tree.path(of: n.id).first?.rawTitle == "BookmarksBar" }
        func isHTTPS(_ n: BookmarkNode) -> Bool { n.url?.lowercased().hasPrefix("https:") == true }
        return items.sorted { a, b in
            if inFavorites(a) != inFavorites(b) { return inFavorites(a) }
            if isHTTPS(a) != isHTTPS(b) { return isHTTPS(a) }
            switch (a.dateAdded, b.dateAdded) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return tree.order[a.id, default: 0] < tree.order[b.id, default: 0]
            }
        }
    }
}
