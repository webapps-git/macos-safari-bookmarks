import AppKit
import Foundation
import Observation

@Observable
final class BookmarkStore {
    let fileURL = BookmarksFile.configuredURL
    var isTestFile: Bool { fileURL != BookmarksFile.safariURL }

    private(set) var tree: BookmarkTree?
    private(set) var error: Error?
    private(set) var fileDate: Date?
    /// Rośnie przy każdej zmianie drzewa – widoki AppKit wiedzą, kiedy przeładować.
    private(set) var version = 0
    /// Ostatni komunikat dla użytkownika (np. odrzucona operacja).
    var notice: String?
    /// Czy Safari jest uruchomione (śledzone na bieżąco).
    private(set) var safariRunning = SafariControl.isRunning

    // Stan edycji
    private var root: NSMutableDictionary?
    private var baseline: Verifier.Baseline?
    /// Plik w chwili wczytania – do ustalenia listy zmian dla iCloud.
    private var original: NSDictionary?
    private var removed = Verifier.Removed()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot {
        let data: Data
        let removed: Verifier.Removed
        let label: String
    }

    var hasChanges: Bool { !undoStack.isEmpty }
    var history: [String] { undoStack.map(\.label) }
    var undoLabel: String? { undoStack.last?.label }
    var redoLabel: String? { redoStack.last?.label }

    /// Czy zapis jest zablokowany, bo Safari jest zamknięte (plik testowy – nigdy).
    /// Zapis idzie przy otwartym Safari: Safari samo wczytuje zmieniony plik.
    var safariBlocksSaving: Bool { !isTestFile && !safariRunning }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.safariRunning = SafariControl.isRunning }
            }
        }
        // Stan iCloud: plik może zmienić Safari albo program synchronizujący, więc sprawdzamy co kilka sekund.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshICloudState() }
        }
    }

    // MARK: - Wczytywanie

    func reload() {
        do {
            let data = try BookmarksFile.read(fileURL)
            let dict = try BookmarksFile.parseMutable(data)
            root = dict
            original = try BookmarksFile.parseMutable(data)
            baseline = Verifier.baseline(data: data, root: dict)
            removed = .init()
            undoStack = []
            redoStack = []
            fileDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
            rebuild()
            error = nil
            lastCheckedFileDate = nil
            refreshICloudState()
        } catch {
            self.error = error
        }
    }

    private func rebuild() {
        guard let root else { return }
        tree = BookmarkParser.parse(root as! [String: Any])
        version += 1
    }

    // MARK: - Wyszukiwanie

    struct SearchResult: Identifiable {
        let node: BookmarkNode
        let path: String
        var id: String { node.id }
    }

    /// Szukanie po nazwie i adresie, bez rozróżniania wielkości liter i polskich znaków.
    func search(_ query: String) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let tree, !q.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var results: [SearchResult] = []

        func visit(_ node: BookmarkNode) {
            for child in node.children ?? [] {
                if child.title.range(of: q, options: options) != nil
                    || child.url?.range(of: q, options: options) != nil {
                    results.append(SearchResult(node: child, path: tree.pathString(of: child.id)))
                }
                visit(child)
            }
        }
        visit(tree.root)
        return results
    }

    // MARK: - Reguły edycji

    /// Dlaczego tego nie wolno zmieniać (nil = wolno). Tekst dla użytkownika.
    func lockReason(_ id: String) -> String? {
        guard let tree, let node = tree.byID[id] else { return L("Nie ma już tego elementu.", "This item no longer exists.") }
        if tree.parent[id] == nil || tree.parent[id] == tree.root.id { return L("To stały folder Safari – nie można go zmieniać.", "This is a built-in Safari folder – it cannot be changed.") }
        if node.kind == .proxy || node.kind == .unknown { return L("To element Safari, nie zakładka.", "This is a Safari item, not a bookmark.") }
        if node.uuid == nil { return L("Tego elementu nie da się bezpiecznie zmienić (uszkodzony wpis w pliku).", "This item cannot be changed safely (damaged entry in the file).") }
        return nil
    }

    func canEdit(_ ids: Set<String>) -> Bool {
        !ids.isEmpty && ids.allSatisfy { lockReason($0) == nil }
    }

    private func inReadingList(_ id: String) -> Bool {
        guard let tree else { return false }
        if tree.byID[id]?.isReadingListRoot == true { return true }
        return tree.path(of: id).first?.isReadingListRoot == true
    }

    /// Usuwa z zaznaczenia elementy, których folder też jest zaznaczony, i sortuje od góry.
    private func topmost(_ ids: Set<String>) -> [String] {
        guard let tree else { return [] }
        return ids.filter { id in !ids.contains { $0 != id && tree.isDescendant(id, of: $0) } }
            .sorted { tree.order[$0, default: 0] < tree.order[$1, default: 0] }
    }

    /// Czy folder `target` może przyjąć elementy `ids`.
    func canMove(_ ids: Set<String>, to target: String) -> Bool {
        guard let tree, let folder = tree.byID[target], folder.isFolder, folder.uuid != nil,
              target != tree.root.id, canEdit(ids) else { return false }
        let rl = inReadingList(target)
        for id in ids {
            if id == target || tree.isDescendant(target, of: id) { return false }
            // Lista Czytelnicza nie ma folderów: do niej i z niej przechodzą tylko pojedyncze zakładki.
            if inReadingList(id) != rl, tree.byID[id]?.kind != .leaf { return false }
        }
        return true
    }

    /// Foldery, do których można przenieść `ids`, w kolejności drzewa, z głębokością.
    func moveTargets(for ids: Set<String>) -> [(node: BookmarkNode, depth: Int, enabled: Bool)] {
        guard let tree else { return [] }
        var out: [(BookmarkNode, Int, Bool)] = []
        func visit(_ node: BookmarkNode, depth: Int) {
            for child in node.children ?? [] where child.isFolder {
                out.append((child, depth, canMove(ids, to: child.id)))
                visit(child, depth: depth + 1)
            }
        }
        visit(tree.root, depth: 0)
        return out
    }

    // MARK: - Nowy folder

    /// Czy w folderze `target` można założyć nowy folder (nie w Liście Czytelniczej – ona nie ma folderów).
    func canAddFolder(in target: String) -> Bool {
        guard let tree, let folder = tree.byID[target], folder.isFolder, folder.uuid != nil,
              target != tree.root.id, folder.kind == .folder else { return false }
        return !inReadingList(target)
    }

    /// Folder, w którym powstanie nowy folder: otwarty folder albo Ulubione.
    func folderForNewFolder(preferred: String?) -> String? {
        if let preferred, canAddFolder(in: preferred) { return preferred }
        guard let tree else { return nil }
        return tree.root.children?.first { $0.rawTitle == "BookmarksBar" }?.id
    }

    /// Zakłada pusty folder (za ostatnim folderem w `target`). Zwraca jego id.
    @discardableResult
    func addFolder(in target: String, title: String) -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddFolder(in: target), !name.isEmpty, let tree, let folder = tree.byID[target] else {
            notice = L("Tu nie można założyć folderu.", "A folder cannot be created here.")
            return nil
        }
        let uuid = UUID().uuidString
        // Tak jak w Safari: typ, UUID, nazwa, pusta zawartość (+ data dodania). Dane iCloud dopisze iCloud.
        let node: NSMutableDictionary = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkUUID": uuid,
            "Title": name,
            "Children": NSMutableArray(),
            "dateAdded": Date(),
        ]
        let insertAt = (folder.children ?? []).lastIndex { $0.isFolder }.map { $0 + 1 } ?? 0
        perform(L("Dodano folder „\(name)” w „\(folder.title)”", "Added folder “\(name)” to “\(folder.title)”")) {
            guard let parent = locate(target)?.node else { throw OperationError(L("Nie znaleziono folderu.", "The folder was not found.")) }
            let children = parent["Children"] as? NSMutableArray ?? NSMutableArray()
            parent["Children"] = children
            children.insert(node, at: min(insertAt, children.count))
            removed.added[uuid, default: 0] += 1
        }
        return self.tree?.byID[uuid] != nil ? uuid : nil
    }

    // MARK: - Nowa zakładka

    /// Czy w folderze `target` można dodać zakładkę (nie w Liście Czytelniczej – do niej dodaje się z Safari).
    func canAddBookmark(in target: String) -> Bool { canAddFolder(in: target) }

    /// Folder, w którym powstanie nowa zakładka: otwarty folder albo Ulubione.
    func folderForNewBookmark(preferred: String?) -> String? { folderForNewFolder(preferred: preferred) }

    /// Adres wpisany przez użytkownika w postaci do zapisu (bez „https://” dopisuje je), albo nil, gdy to nie adres.
    static func normalizedURL(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        if s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil
            || s.range(of: "^[^/:]+:[0-9]+(/|$)", options: .regularExpression) != nil {
            s = "https://" + s
        }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            // Sam „example.com/” jak w Safari.
            if url.path.isEmpty, url.query == nil, url.fragment == nil, !s.hasSuffix("/") { s += "/" }
        }
        return s
    }

    /// Dodaje zakładkę na końcu folderu `target`. Zwraca jej id.
    @discardableResult
    func addBookmark(in target: String, title: String, url: String) -> String? {
        guard canAddBookmark(in: target), let address = Self.normalizedURL(url), let tree, let folder = tree.byID[target] else {
            notice = L("Tu nie można dodać zakładki.", "A bookmark cannot be added here.")
            return nil
        }
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = URL(string: address)?.host ?? address }
        let uuid = UUID().uuidString
        // Tak jak w Safari: typ, UUID, adres, nazwa (+ data dodania). Dane iCloud dopisze iCloud.
        let node: NSMutableDictionary = [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "WebBookmarkUUID": uuid,
            "URLString": address,
            "URIDictionary": NSMutableDictionary(dictionary: ["title": name]),
            "dateAdded": Date(),
        ]
        perform(L("Dodano zakładkę „\(name)” w „\(folder.title)”", "Added bookmark “\(name)” to “\(folder.title)”")) {
            guard let parent = locate(target)?.node else { throw OperationError(L("Nie znaleziono folderu.", "The folder was not found.")) }
            let children = parent["Children"] as? NSMutableArray ?? NSMutableArray()
            parent["Children"] = children
            children.add(node)
            removed.added[uuid, default: 0] += 1
            removed.addedLeaves += 1
        }
        return self.tree?.byID[uuid] != nil ? uuid : nil
    }

    // MARK: - Operacje

    private func locate(_ uuid: String, in node: NSMutableDictionary? = nil) -> (parent: NSMutableArray, index: Int, node: NSMutableDictionary)? {
        guard let start = node ?? root, let children = start["Children"] as? NSMutableArray else { return nil }
        for i in 0..<children.count {
            guard let child = children[i] as? NSMutableDictionary else { continue }
            if child["WebBookmarkUUID"] as? String == uuid { return (children, i, child) }
            if let found = locate(uuid, in: child) { return found }
        }
        return nil
    }

    private func perform(_ label: String, _ body: () throws -> Void) {
        guard let root, let data = try? BookmarksFile.serialize(root) else { return }
        let before = Snapshot(data: data, removed: removed, label: label)
        do {
            try body()
            // Nic się nie zmieniło (np. upuszczenie w tym samym miejscu) – nie zapisuj w historii.
            if let after = try? BookmarksFile.serialize(root), after == before.data { return }
            undoStack.append(before)
            redoStack.removeAll()
            notice = nil
        } catch {
            // Nieudana operacja – przywróć stan sprzed niej (pozostałe zmiany zostają).
            if let restored = try? BookmarksFile.parseMutable(before.data) {
                self.root = restored
                removed = before.removed
            }
            notice = L("Nie udało się: \(error.localizedDescription) Nic nie zmieniono.", "That did not work: \(error.localizedDescription) Nothing was changed.")
        }
        rebuild()
    }

    struct OperationError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Przenosi elementy do folderu `target`, na pozycję `index` (licząc w obecnej zawartości folderu)
    /// albo na koniec, gdy `index == nil`.
    func move(_ ids: Set<String>, to target: String, index: Int?) {
        guard let tree, canMove(ids, to: target), let folder = tree.byID[target] else {
            notice = L("Tego nie można tam przenieść.", "This cannot be moved there.")
            return
        }
        let order = topmost(ids)
        let sameFolder = order.allSatisfy { tree.parent[$0] == target }
        let what = order.count == 1 ? L("„\(tree.byID[order[0]]?.title ?? "")”", "“\(tree.byID[order[0]]?.title ?? "")”") : L("\(order.count) elem.", "\(order.count) items")
        let label = sameFolder ? L("Zmieniono kolejność: \(what)", "Reordered \(what)") : L("Przeniesiono \(what) do „\(folder.title)”", "Moved \(what) to “\(folder.title)”")
        perform(label) {
            guard let targetDict = locate(target)?.node, let children = targetDict["Children"] as? NSMutableArray else {
                throw OperationError(L("Nie znaleziono folderu docelowego.", "The target folder was not found."))
            }
            var insertAt = min(index ?? children.count, children.count)
            var nodes: [NSMutableDictionary] = []
            for id in order {
                guard let loc = locate(id) else { throw OperationError(L("Nie znaleziono elementu.", "The item was not found.")) }
                // Element wyjmowany z tego samego folderu przed miejscem wstawienia przesuwa pozycję.
                if loc.parent === children, loc.index < insertAt { insertAt -= 1 }
                nodes.append(loc.node)
                loc.parent.removeObject(at: loc.index)
            }
            for (i, n) in nodes.enumerated() { children.insert(n, at: insertAt + i) }
        }
    }

    /// Przesuwa element o jedną pozycję w obrębie folderu.
    func shift(_ id: String, by delta: Int) {
        guard let tree, canShift(id, by: delta), let parent = tree.parent[id],
              let i = tree.byID[parent]?.children?.firstIndex(where: { $0.id == id }) else { return }
        move([id], to: parent, index: delta < 0 ? i - 1 : i + 2)
    }

    func canShift(_ id: String, by delta: Int) -> Bool {
        guard let tree, lockReason(id) == nil, let parent = tree.parent[id],
              let siblings = tree.byID[parent]?.children,
              let i = siblings.firstIndex(where: { $0.id == id }) else { return false }
        return siblings.indices.contains(i + delta)
    }

    func rename(_ id: String, to newTitle: String) {
        edit(id, title: newTitle, url: nil)
    }

    /// Zmiana nazwy i (dla zakładki) adresu. `url == nil` – adres bez zmian.
    func edit(_ id: String, title newTitle: String, url newURL: String?) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tree, lockReason(id) == nil, let node = tree.byID[id], let uuid = node.uuid, !title.isEmpty else { return }
        var address: String?
        if node.kind == .leaf, let newURL {
            guard let a = Self.normalizedURL(newURL) else {
                notice = L("To nie wygląda na adres strony – adres bez zmian.", "This does not look like a web address – the address is unchanged.")
                return
            }
            if a != node.url { address = a }
        }
        let titleChanged = title != (node.rawTitle.isEmpty ? node.title : node.rawTitle)
        guard titleChanged || address != nil else { return }
        let label: String
        switch (titleChanged, address != nil) {
        case (true, false): label = L("Zmieniono nazwę „\(node.title)” na „\(title)”", "Renamed “\(node.title)” to “\(title)”")
        case (false, true): label = L("Zmieniono adres „\(node.title)”", "Changed the address of “\(node.title)”")
        default: label = L("Zmieniono nazwę i adres „\(node.title)” → „\(title)”", "Changed the name and address of “\(node.title)” → “\(title)”")
        }
        perform(label) {
            guard let loc = locate(id) else { throw OperationError(L("Nie znaleziono elementu.", "The item was not found.")) }
            switch node.kind {
            case .folder:
                loc.node["Title"] = title
            case .leaf:
                let uri = loc.node["URIDictionary"] as? NSMutableDictionary ?? NSMutableDictionary()
                uri["title"] = title
                loc.node["URIDictionary"] = uri
                if let address {
                    loc.node["URLString"] = address
                    removed.urlEdited.insert(uuid)
                }
            default:
                throw OperationError(L("Tego nie da się zmienić.", "This cannot be changed."))
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case foldersFirst, bookmarksFirst, mixed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .foldersFirst: L("Alfabetycznie – foldery na górze", "Alphabetically – folders first")
            case .bookmarksFirst: L("Alfabetycznie – zakładki na górze", "Alphabetically – bookmarks first")
            case .mixed: L("Alfabetycznie – wszystko razem", "Alphabetically – all together")
            }
        }
        var short: String {
            switch self {
            case .foldersFirst: L("foldery na górze", "folders first")
            case .bookmarksFirst: L("zakładki na górze", "bookmarks first")
            case .mixed: L("wszystko razem", "all together")
            }
        }
    }

    func canSort(_ folderID: String?) -> Bool {
        guard let folderID, let tree, let node = tree.byID[folderID], node.isFolder, node.uuid != nil,
              folderID != tree.root.id else { return false }
        // Lista Czytelnicza też: Safari pokazuje ją w kolejności z pliku (sprawdzone 2026-11-13).
        return (node.children?.count ?? 0) > 1 || node.folderCount > 0
    }

    /// Sortuje zawartość folderu alfabetycznie (po polsku), opcjonalnie także podfoldery.
    func sort(_ folderID: String, mode: SortMode, recursive: Bool) {
        guard canSort(folderID), let node = tree?.byID[folderID] else { return }
        perform(L("Posortowano „\(node.title)” (\(mode.short)\(recursive ? ", z podfolderami" : ""))", "Sorted “\(node.title)” (\(mode.short)\(recursive ? ", with subfolders" : ""))")) {
            guard let folder = locate(folderID)?.node, let children = folder["Children"] as? NSMutableArray else {
                throw OperationError(L("Nie znaleziono folderu.", "The folder was not found."))
            }
            Self.sortChildren(children, mode: mode, recursive: recursive)
        }
    }

    private static func sortChildren(_ array: NSMutableArray, mode: SortMode, recursive: Bool) {
        let items = array.compactMap { $0 as? NSMutableDictionary }
        guard items.count == array.count else { return }
        func isFolder(_ d: NSDictionary) -> Bool { d["WebBookmarkType"] as? String == "WebBookmarkTypeList" }
        func group(_ d: NSDictionary) -> Int {
            switch mode {
            case .mixed: 0
            case .foldersFirst: isFolder(d) ? 0 : 1
            case .bookmarksFirst: isFolder(d) ? 1 : 0
            }
        }
        func name(_ d: NSDictionary) -> String {
            if let t = d["Title"] as? String, !t.isEmpty { return t }
            if let t = (d["URIDictionary"] as? NSDictionary)?["title"] as? String, !t.isEmpty { return t }
            return d["URLString"] as? String ?? ""
        }
        let sorted = items.enumerated().sorted { a, b in
            let ga = group(a.element), gb = group(b.element)
            if ga != gb { return ga < gb }
            let c = name(a.element).localizedStandardCompare(name(b.element))
            return c == .orderedSame ? a.offset < b.offset : c == .orderedAscending
        }.map(\.element)
        array.removeAllObjects()
        array.addObjects(from: sorted)
        if recursive {
            for d in sorted where isFolder(d) {
                if let sub = d["Children"] as? NSMutableArray { sortChildren(sub, mode: mode, recursive: true) }
            }
        }
    }

    /// Ile elementów, zakładek i folderów zniknie przy usunięciu `ids`.
    func deletionSummary(_ ids: Set<String>) -> (items: Int, leaves: Int, folders: Int) {
        guard let tree else { return (0, 0, 0) }
        let top = topmost(ids).compactMap { tree.byID[$0] }
        let leaves = top.reduce(0) { $0 + $1.leafCount + ($1.kind == .leaf ? 1 : 0) }
        let folders = top.reduce(0) { $0 + $1.folderCount + ($1.isFolder ? 1 : 0) }
        return (top.count, leaves, folders)
    }

    func delete(_ ids: Set<String>) {
        guard let tree, canEdit(ids) else { return }
        let order = topmost(ids)
        let s = deletionSummary(ids)
        let label = order.count == 1
            ? L("Usunięto „\(tree.byID[order[0]]?.title ?? "")”", "Deleted “\(tree.byID[order[0]]?.title ?? "")”") + (s.folders > 0 ? " (\(Plural.bookmarks(s.leaves)))" : "")
            : L("Usunięto \(order.count) elem. (\(Plural.bookmarks(s.leaves)))", "Deleted \(order.count) items (\(Plural.bookmarks(s.leaves)))")
        perform(label) {
            for id in order {
                guard let loc = locate(id) else { throw OperationError(L("Nie znaleziono elementu.", "The item was not found.")) }
                removed.add(Verifier.scan(subtree: loc.node))
                loc.parent.removeObject(at: loc.index)
            }
        }
    }

    // MARK: - Dosłanie starych zmian do iCloud

    /// Zmiany zapisane wersją 1.0.0, których iCloud nie dostał (z kopii zapasowych).
    func resendPlan() -> Result<ResendChanges.Plan, Error> {
        guard let original else { return .failure(OperationError(L("Brak wczytanych zakładek.", "No bookmarks loaded."))) }
        guard SyncChanges.isSynced(original) else { return .failure(ResendChanges.PlanError.notSynced) }
        let urls = (try? FileManager.default.contentsOfDirectory(at: Backups.directory, includingPropertiesForKeys: nil)) ?? []
        let log = try? String(contentsOf: logURL, encoding: .utf8)
        if log?.contains(ResendChanges.logMarker) == true { return .failure(ResendChanges.PlanError.alreadySent) }
        let chain = ResendChanges.chain(backups: urls, log: log)
        guard let first = chain.urls.first else { return .failure(ResendChanges.PlanError.noBackups) }
        var states: [NSDictionary] = []
        for url in chain.urls {
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else {
                return .failure(ResendChanges.PlanError.unreadable(url.lastPathComponent))
            }
            states.append(dict)
        }
        // Okres 1.0.0 trwa do dziś – ostatnim stanem są obecne zakładki.
        if !chain.closed { states.append(original) }
        var plan = ResendChanges.plan(states: states, current: original)
        plan.since = ResendChanges.date(ofBackup: first)
        return .success(plan)
    }

    /// Dopisuje stare zmiany do listy dla iCloud. Zakładki się nie zmieniają; trafi to do iCloud przy zapisie.
    func resend(_ plan: ResendChanges.Plan) {
        guard !plan.isEmpty, !hasChanges else { return }
        perform(L("Stare zmiany do wysłania do iCloud (\(plan.entries.count))", "Old changes to send to iCloud (\(plan.entries.count))")) {
            guard let root else { throw OperationError(L("Brak wczytanych zakładek.", "No bookmarks loaded.")) }
            let sync = NSMutableDictionary(dictionary: root["Sync"] as? NSDictionary ?? [:])
            let list = NSMutableArray(array: sync[SyncChanges.key] as? [Any] ?? [])
            list.addObjects(from: plan.entries)
            sync[SyncChanges.key] = list
            root["Sync"] = sync
            removed.resent.formUnion(plan.tokens)
        }
    }

    // MARK: - Wysyłka do iCloud

    /// Czy zakładki Safari są synchronizowane z iCloud.
    var usesICloud: Bool { original.map(SyncChanges.isSynced) ?? false }

    /// Stan wysyłki do iCloud – do kolorowej ikonki.
    enum ICloudState: Equatable {
        /// iCloud wyłączony dla zakładek Safari (albo tryb testowy).
        case off
        /// W pliku nic nie czeka.
        case sent
        /// Tyle zmian czeka na wysłanie.
        case waiting(Int)
        /// Coś nie tak (opis dla użytkownika); `count` – ile czeka.
        case problem(String, count: Int)
    }

    private(set) var icloudState: ICloudState = .off
    /// Ostatni błąd prośby do Safari (czyszczony, gdy nic już nie czeka).
    private var lastSyncError: String?
    /// Od kiedy coś czeka (do wykrycia, że wisi za długo).
    private var pendingSince: Date?
    private var lastCheckedFileDate: Date?
    private var lastPendingCount = 0

    /// Odświeża stan iCloud (plik czytany tylko po zmianie). Wywoływane co kilka sekund.
    func refreshICloudState() {
        guard !isTestFile, usesICloud else { icloudState = .off; return }
        let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        if date != lastCheckedFileDate || date == nil {
            lastCheckedFileDate = date
            lastPendingCount = pendingICloudChanges() ?? lastPendingCount
        }
        let n = lastPendingCount
        guard n > 0 else {
            pendingSince = nil
            lastSyncError = nil
            icloudState = .sent
            return
        }
        let since = pendingSince ?? .now
        pendingSince = since
        if let lastSyncError {
            icloudState = .problem(lastSyncError, count: n)
        } else if Date.now.timeIntervalSince(since) > 120 {
            icloudState = .problem(L("Zmiany czekają już ponad 2 minuty. Kliknij „Wyślij teraz” albo zrób dowolną zmianę zakładek w Safari.",
                                     "Changes have been waiting for over 2 minutes. Click “Send Now” or make any bookmark change in Safari."), count: n)
        } else {
            icloudState = .waiting(n)
        }
    }

    /// Ile zmian czeka w pliku Safari na wysłanie do iCloud (odczyt z dysku).
    func pendingICloudChanges() -> Int? {
        guard let data = try? BookmarksFile.read(fileURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else { return nil }
        return SafariNudge.pendingCount(root)
    }

    /// Prosi Safari o zapis zakładek, po którym Safari wysyła czekające zmiany do iCloud. Zwraca błąd albo nil.
    func askSafariToSync() -> String? {
        // Tryb testowy pracuje na kopii – Safari nie ruszamy.
        guard !isTestFile else { return nil }
        guard safariRunning else {
            return L("Safari jest zamknięte, więc zmiany poczekają na wysłanie do iCloud. Otwórz Safari i kliknij „Wyślij teraz”.", "Safari is closed, so the changes will wait to be sent to iCloud. Open Safari and click “Send Now”.")
        }
        guard let data = try? BookmarksFile.read(fileURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else {
            return L("Nie udało się odczytać zakładek Safari.", "Could not read Safari bookmarks.")
        }
        // Pusta Lista Czytelnicza: dodajemy stronę aplikacji – zostaje tam jako pozycja do ponownego dodawania.
        let item = SafariNudge.topReadingListItem(in: root) ?? SafariNudge.appItem
        let error = SafariNudge.run(item)
        log("  asked Safari to sync: " + (error ?? "OK"))
        lastSyncError = error
        lastCheckedFileDate = nil
        refreshICloudState()
        return error
    }

    // MARK: - Cofanie

    func undo() { step(from: &undoStack, to: &redoStack) }
    func redo() { step(from: &redoStack, to: &undoStack) }

    private func step(from: inout [Snapshot], to: inout [Snapshot]) {
        guard let root, let snap = from.popLast(),
              let current = try? BookmarksFile.serialize(root),
              let restored = try? BookmarksFile.parseMutable(snap.data) else { return }
        to.append(Snapshot(data: current, removed: removed, label: snap.label))
        self.root = restored
        removed = snap.removed
        rebuild()
    }

    func discardChanges() {
        while !undoStack.isEmpty { undo() }
        redoStack.removeAll()
    }

    // MARK: - Kontrola i zapis

    /// Wynik kontroli bieżących zmian (pusta lista = OK).
    func verify() -> [String] {
        guard let root, let baseline else { return [L("Brak wczytanych zakładek.", "No bookmarks loaded.")] }
        do {
            return Verifier.check(candidate: try BookmarksFile.serialize(root), against: baseline, removed: removed)
        } catch {
            return [L("Nie udało się przygotować pliku: \(error.localizedDescription)", "Could not prepare the file: \(error.localizedDescription)")]
        }
    }

    /// Liczba zakładek przed i po zmianach.
    var countsSummary: (before: Int, after: Int, removed: Int) {
        (baseline?.scan.leaves ?? 0, tree?.stats.leaves ?? 0, removed.leaves)
    }

    /// Wynik zapisu lub przywrócenia – w prostych słowach.
    enum WriteResult {
        case ok
        case failed(String)
    }

    /// Trwa zapis albo przywracanie.
    private(set) var isWriting = false

    private var logURL: URL { Backups.directory.deletingLastPathComponent().appending(path: "log.txt") }

    /// Dziennik zapisów (dla diagnozy, bez pokazywania w aplikacji).
    private func log(_ s: String) {
        let line = "\(Date.now.formatted(date: .numeric, time: .standard))  \(s)\n"
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Zapis bieżących zmian. Safari musi być otwarte – samo wczytuje zmieniony plik.
    func save() async -> WriteResult {
        guard let root, let baseline, let original, hasChanges, !isWriting else { return .failed(L("Nie ma czego zapisać.", "There is nothing to save.")) }
        isWriting = true
        defer { isWriting = false }
        let data: Data
        let syncCount: Int
        do {
            // Kopia stanu z dopisaną listą zmian dla iCloud (sam stan w pamięci zostaje bez niej).
            let candidate = try BookmarksFile.parseMutable(BookmarksFile.serialize(root))
            syncCount = SyncChanges.record(original: original, into: candidate)
            data = try BookmarksFile.serialize(candidate)
        } catch {
            return .failed(L("Nie udało się przygotować zakładek do zapisu.", "Could not prepare the bookmarks for saving."))
        }
        let problems = Verifier.check(candidate: data, against: baseline, removed: removed)
        guard problems.isEmpty else {
            log("SAVE REFUSED: " + problems.joined(separator: " "))
            return .failed(problems.joined(separator: "\n"))
        }
        log("SAVE: " + history.joined(separator: "; "))
        log("  iCloud changes: \(syncCount)")
        let removedSnapshot = removed
        let result = await write(data, expectedHash: baseline.fileHash) { written in
            Verifier.check(candidate: written, against: baseline, removed: removedSnapshot, syncMayChange: true)
        }
        if case .ok = result, !removedSnapshot.resent.isEmpty {
            log("  \(ResendChanges.logMarker) \(removedSnapshot.resent.count)")
        }
        return result
    }

    /// Przywrócenie kopii zapasowej.
    func restore(_ backup: Backup) async -> WriteResult {
        guard !hasChanges, let baseline, !isWriting else { return .failed(L("Najpierw zapisz albo odrzuć zmiany.", "Save or discard your changes first.")) }
        isWriting = true
        defer { isWriting = false }
        do {
            let data = try Data(contentsOf: backup.url)
            _ = try BookmarksFile.parseMutable(data)
            log("RESTORE: \(backup.url.lastPathComponent)")
            return await write(data, expectedHash: baseline.fileHash) { written in
                written == data ? [] : [L("Plik różni się od kopii.", "The file differs from the backup.")]
            }
        } catch {
            return .failed(L("Ta kopia jest uszkodzona albo nie da się jej odczytać.", "This backup is damaged or cannot be read."))
        }
    }

    private func write(_ newData: Data, expectedHash: String, recheck: @escaping (Data) -> [String]) async -> WriteResult {
        do {
            if safariBlocksSaving { throw FileError.safariClosed }
            let current = try BookmarksFile.read(fileURL)
            guard Verifier.hash(current) == expectedHash else { throw FileError.changedOutside }
            let backup = try Backups.make(from: current, testMode: isTestFile)
            log("  backup: \(backup.lastPathComponent)")
            try BookmarksFile.writeAtomically(newData, to: fileURL)
            guard try BookmarksFile.read(fileURL) == newData else { throw FileError.writeMismatch }
            log("  written")
            // Czy iCloud nie nadpisał pliku zaraz po zapisie?
            try await Task.sleep(for: .seconds(2))
            let later = try BookmarksFile.read(fileURL)
            if later != newData {
                let p = recheck(later)
                log("  file changed from outside within 2 s; check: " + (p.isEmpty ? "OK" : p.joined(separator: " ")))
                if !p.isEmpty {
                    reload()
                    return .failed(L("Zaraz po zapisie coś (pewnie iCloud) zmieniło zakładki i coś się nie zgadza. Sprawdź je, w razie potrzeby przywróć kopię.", "Right after saving, something (probably iCloud) changed the bookmarks and something does not match. Check them and restore a backup if needed."))
                }
            }
        } catch {
            log("  ERROR: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
        reload()
        return .ok
    }
}

enum Plural {
    static func bookmarks(_ n: Int) -> String {
        "\(n) " + (AppLanguage.isPolish ? form(n, "zakładka", "zakładki", "zakładek") : (n == 1 ? "bookmark" : "bookmarks"))
    }

    static func folders(_ n: Int) -> String {
        "\(n) " + (AppLanguage.isPolish ? form(n, "folder", "foldery", "folderów") : (n == 1 ? "folder" : "folders"))
    }

    /// Polska odmiana: 1 zakładka, 2–4 zakładki, 5+ zakładek (12–14 zakładek).
    static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if n == 1 { return one }
        let d = n % 10, t = n % 100
        return (2...4).contains(d) && !(12...14).contains(t) ? few : many
    }
}
