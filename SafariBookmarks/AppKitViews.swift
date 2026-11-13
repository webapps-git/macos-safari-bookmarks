import AppKit
import SwiftUI

/// Typ danych przeciąganych wewnątrz aplikacji: identyfikator elementu.
let nodeDragType = NSPasteboard.PasteboardType("local.safaribookmarks.node")

private func draggedIDs(_ info: NSDraggingInfo) -> Set<String> {
    Set(info.draggingPasteboard.pasteboardItems?.compactMap { $0.string(forType: nodeDragType) } ?? [])
}

private func dragItem(for node: BookmarkNode, store: BookmarkStore) -> NSPasteboardItem? {
    guard store.lockReason(node.id) == nil else { return nil }
    let item = NSPasteboardItem()
    item.setString(node.id, forType: nodeDragType)
    if let url = node.url { item.setString(url, forType: .string) }
    return item
}

private func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)
}

// MARK: - Menu kontekstowe

/// Cel akcji pozycji menu – trzymany przez representedObject.
private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

private func ClosureMenuItem(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = action
    item.representedObject = action
    item.isEnabled = enabled
    return item
}

enum NodeMenu {
    static func make(ids: Set<String>, store: BookmarkStore, ui: UIState, showReveal: Bool) -> NSMenu? {
        guard !ids.isEmpty, let tree = store.tree else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let single = ids.count == 1 ? ids.first : nil
        let node = single.flatMap { tree.byID[$0] }

        if let node, node.isFolder {
            menu.addItem(ClosureMenuItem(L("Otwórz folder", "Open Folder")) { ui.open(folder: node.id) })
        }
        if let node, let url = node.url, let u = URL(string: url) {
            menu.addItem(ClosureMenuItem(L("Otwórz w przeglądarce", "Open in Browser")) { NSWorkspace.shared.open(u) })
        }
        if showReveal, let single {
            menu.addItem(ClosureMenuItem(L("Pokaż w folderze", "Show in Folder")) { ui.reveal(single, in: tree) })
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }

        // Nowa zakładka / nowy folder: w klikniętym folderze, a przy zakładce – obok niej.
        if let node {
            let target = node.isFolder ? node.id : tree.parent[node.id]
            if let target, store.canAddFolder(in: target) {
                let name = tree.byID[target]?.title ?? ""
                menu.addItem(ClosureMenuItem(L("Nowa zakładka w „\(name)”…", "New Bookmark in “\(name)”…")) { ui.newBookmark(store, in: target) })
                menu.addItem(ClosureMenuItem(L("Nowy folder w „\(name)”", "New Folder in “\(name)”")) { ui.newFolder(store, in: target) })
                menu.addItem(.separator())
            }
        }

        let reason = ids.lazy.compactMap { store.lockReason($0) }.first
        let editable = reason == nil
        menu.addItem(ClosureMenuItem(L("Zmień nazwę…", "Rename…"), enabled: editable && single != nil) {
            if let single { ui.sheet = .rename(single) }
        })
        menu.addItem(ClosureMenuItem(L("Przenieś do…", "Move to…"), enabled: editable) { ui.sheet = .move(ids) })
        menu.addItem(ClosureMenuItem(ids.count == 1 ? L("Usuń…", "Delete…") : L("Usuń \(ids.count) elem.…", "Delete \(ids.count) Items…"), enabled: editable) {
            ui.deleteRequest = ids
        })
        if let reason {
            let info = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        menu.addItem(.separator())
        if let node, let url = node.url {
            menu.addItem(ClosureMenuItem(L("Kopiuj adres", "Copy Address")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            })
        }
        if let single {
            menu.addItem(ClosureMenuItem(L("Informacje…", "Get Info…")) { ui.sheet = .info(single) })
        }
        return menu
    }
}

/// Wspólne zachowanie klawiszy i menu dla drzewa i listy.
private protocol KeyHandling: AnyObject {
    var onDelete: (() -> Void)? { get }
    var onReturn: (() -> Void)? { get }
    var menuProvider: ((Int) -> NSMenu?)? { get }
}

final class KeyOutlineView: NSOutlineView, KeyHandling {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}

final class KeyTableView: NSTableView, KeyHandling {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(row)
    }
}

private func makeCell(_ view: NSTableView, id: String, image: NSImage?, text: String, secondary: Bool = false) -> NSTableCellView {
    let identifier = NSUserInterfaceItemIdentifier(id)
    let cell: NSTableCellView
    if let reused = view.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
        cell = reused
    } else {
        cell = NSTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iv)
        cell.imageView = iv
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 16),
            tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }
    cell.imageView?.image = image
    cell.imageView?.isHidden = image == nil
    cell.textField?.stringValue = text
    cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
    return cell
}

// MARK: - Drzewo folderów (lewa strona)

final class FolderItem: NSObject {
    let id: String
    var children: [FolderItem] = []
    init(id: String) { self.id = id }
}

struct FolderOutline: NSViewRepresentable {
    let store: BookmarkStore
    let ui: UIState
    /// Przekazywane, żeby SwiftUI odświeżało widok przy zmianach.
    let version: Int
    let folderID: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.allowsMultipleSelection = false
        outline.autoresizesOutlineColumn = true
        outline.registerForDraggedTypes([nodeDragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let c = context.coordinator
        c.parent = self
        c.outline = outline
        outline.dataSource = c
        outline.delegate = c
        outline.onDelete = { [weak c] in c?.deleteSelected() }
        outline.onReturn = { [weak c] in c?.renameSelected() }
        outline.menuProvider = { [weak c] row in c?.menu(row: row) }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        c.sync()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FolderOutline!
        weak var outline: KeyOutlineView?
        private var cache: [String: FolderItem] = [:]
        private var roots: [FolderItem] = []
        private var expanded: Set<String> = []
        private var loadedVersion = -1
        private var syncing = false

        private var store: BookmarkStore { parent.store }
        private var ui: UIState { parent.ui }

        func sync() {
            guard let outline else { return }
            syncing = true
            defer { syncing = false }
            if parent.version != loadedVersion {
                let firstLoad = loadedVersion == -1
                loadedVersion = parent.version
                rebuild()
                outline.reloadData()
                if firstLoad { expanded.formUnion(roots.map(\.id)) }
                expandSaved(roots)
            }
            // Zaznaczenie zgodne z wybranym folderem.
            if let id = parent.folderID, let item = cache[id] {
                if let tree = store.tree {
                    for ancestor in tree.path(of: id) {
                        if let a = cache[ancestor.id] { outline.expandItem(a) }
                    }
                }
                let row = outline.row(forItem: item)
                if row >= 0, outline.selectedRow != row {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
            } else if parent.folderID == nil, let first = roots.first {
                DispatchQueue.main.async { [ui] in if ui.folderID == nil { ui.folderID = first.id } }
            } else if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
            }
        }

        private func rebuild() {
            guard let tree = store.tree else { roots = []; return }
            var seen: [String: FolderItem] = [:]
            func make(_ node: BookmarkNode) -> FolderItem {
                let item = cache[node.id] ?? FolderItem(id: node.id)
                item.children = (node.children ?? []).filter(\.isFolder).map(make)
                seen[node.id] = item
                return item
            }
            roots = (tree.root.children ?? []).filter(\.isFolder).map(make)
            cache = seen
        }

        private func expandSaved(_ items: [FolderItem]) {
            for item in items where expanded.contains(item.id) {
                outline?.expandItem(item)
                expandSaved(item.children)
            }
        }

        private func node(_ item: Any?) -> BookmarkNode? {
            guard let f = item as? FolderItem else { return nil }
            return store.tree?.byID[f.id]
        }

        // Dane
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FolderItem)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? FolderItem)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? FolderItem)?.children.isEmpty ?? true)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = node(item) else { return nil }
            return makeCell(outlineView, id: "folder", image: symbol(node.systemImage), text: node.title)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline, outline.selectedRow >= 0,
                  let item = outline.item(atRow: outline.selectedRow) as? FolderItem else { return }
            if ui.folderID != item.id || ui.isSearching { ui.open(folder: item.id) }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let item = notification.userInfo?["NSObject"] as? FolderItem { expanded.insert(item.id) }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let item = notification.userInfo?["NSObject"] as? FolderItem { expanded.remove(item.id) }
        }

        // Przeciąganie
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = node(item) else { return nil }
            return dragItem(for: node, store: store)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let target = item as? FolderItem else { return [] }
            let ids = draggedIDs(info)
            return store.canMove(ids, to: target.id) ? .move : []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let target = item as? FolderItem, let folder = store.tree?.byID[target.id] else { return false }
            let ids = draggedIDs(info)
            var realIndex: Int?
            if index >= 0 {
                // Indeks liczony wśród folderów → pozycja wśród całej zawartości.
                let all = folder.children ?? []
                if index < target.children.count {
                    realIndex = all.firstIndex { $0.id == target.children[index].id }
                } else if let last = target.children.last, let i = all.firstIndex(where: { $0.id == last.id }) {
                    realIndex = i + 1
                } else {
                    realIndex = 0
                }
            }
            store.move(ids, to: target.id, index: realIndex)
            expanded.insert(target.id)
            return true
        }

        // Klawisze i menu
        private var selectedID: String? {
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return (outline.item(atRow: outline.selectedRow) as? FolderItem)?.id
        }

        func deleteSelected() {
            if let id = selectedID, store.lockReason(id) == nil { ui.deleteRequest = [id] }
        }

        func renameSelected() {
            if let id = selectedID, store.lockReason(id) == nil { ui.sheet = .rename(id) }
        }

        func menu(row: Int) -> NSMenu? {
            guard let item = outline?.item(atRow: row) as? FolderItem else { return nil }
            return NodeMenu.make(ids: [item.id], store: store, ui: ui, showReveal: false)
        }
    }
}

// MARK: - Zawartość folderu (prawa strona)

struct ContentTable: NSViewRepresentable {
    let store: BookmarkStore
    let ui: UIState
    let rows: [BookmarkNode]
    /// Ścieżki folderów – tylko przy wyszukiwaniu.
    let paths: [String: String]?
    /// Folder, którego zawartość pokazujemy (nil przy wyszukiwaniu).
    let folderID: String?
    let version: Int
    let selection: Set<String>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        for (id, title, width) in [("name", L("Nazwa", "Name"), 320.0), ("url", L("Adres", "Address"), 360.0), ("folder", L("Folder", "Folder"), 220.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.minWidth = 80
            table.addTableColumn(col)
        }
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autosaveName = "ContentTable"
        table.autosaveTableColumns = true
        table.registerForDraggedTypes([nodeDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .gap

        let c = context.coordinator
        c.parent = self
        c.table = table
        table.dataSource = c
        table.delegate = c
        table.target = c
        table.doubleAction = #selector(Coordinator.doubleClick)
        table.onDelete = { [weak c] in c?.deleteSelected() }
        table.onReturn = { [weak c] in c?.renameSelected() }
        table.menuProvider = { [weak c] _ in c?.menu() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        c.sync()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ContentTable!
        weak var table: KeyTableView?
        private var rows: [BookmarkNode] = []
        private var loadedKey: [String] = []
        private var loadedVersion = -1
        private var syncing = false

        private var store: BookmarkStore { parent.store }
        private var ui: UIState { parent.ui }
        private var searching: Bool { parent.paths != nil }

        func sync() {
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            let key = parent.rows.map(\.id)
            if key != loadedKey || parent.version != loadedVersion {
                rows = parent.rows
                loadedKey = key
                loadedVersion = parent.version
                table.tableColumn(withIdentifier: .init("folder"))?.isHidden = !searching
                table.reloadData()
            }
            let wanted = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            if wanted != table.selectedRowIndexes {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                if let first = wanted.first { table.scrollRowToVisible(first) }
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let node = rows[row]
            switch tableColumn?.identifier.rawValue {
            case "name":
                return makeCell(tableView, id: "name", image: symbol(node.systemImage), text: node.title)
            case "url":
                if node.isFolder {
                    return makeCell(tableView, id: "url", image: nil, text: Plural.bookmarks(node.leafCount), secondary: true)
                }
                return makeCell(tableView, id: "url", image: nil, text: node.url ?? "", secondary: true)
            default:
                return makeCell(tableView, id: "folder", image: nil, text: parent.paths?[node.id] ?? "", secondary: true)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if ui.selection != ids { ui.selection = ids }
        }

        @objc func doubleClick() {
            guard let table, table.clickedRow >= 0 else { return }
            let node = rows[table.clickedRow]
            if node.isFolder {
                ui.open(folder: node.id)
            } else if let url = node.url, let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        }

        // Przeciąganie
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            dragItem(for: rows[row], store: store)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            let ids = draggedIDs(info)
            if op == .on, rows.indices.contains(row), rows[row].isFolder, !ids.contains(rows[row].id) {
                return store.canMove(ids, to: rows[row].id) ? .move : []
            }
            // Wstawienie między wiersze – tylko w zwykłym folderze, nie w wynikach wyszukiwania.
            guard !searching, let folder = parent.folderID else { return [] }
            if op == .on { tableView.setDropRow(row, dropOperation: .above) }
            return store.canMove(ids, to: folder) ? .move : []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            let ids = draggedIDs(info)
            if op == .on, rows.indices.contains(row), rows[row].isFolder {
                store.move(ids, to: rows[row].id, index: nil)
            } else if let folder = parent.folderID, !searching {
                store.move(ids, to: folder, index: row)
            } else {
                return false
            }
            return true
        }

        // Klawisze i menu
        func deleteSelected() {
            let ids = ui.selection
            if store.canEdit(ids) { ui.deleteRequest = ids }
        }

        func renameSelected() {
            if let id = ui.singleSelection, store.lockReason(id) == nil { ui.sheet = .rename(id) }
        }

        func menu() -> NSMenu? {
            NodeMenu.make(ids: ui.selection, store: store, ui: ui, showReveal: searching)
        }
    }
}
