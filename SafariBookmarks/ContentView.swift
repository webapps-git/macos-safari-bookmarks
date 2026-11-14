import SwiftUI

struct ContentView: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        Group {
            if let error = store.error, store.tree == nil {
                ErrorView(error: error)
            } else if let tree = store.tree {
                NavigationSplitView {
                    FolderOutline(store: store, ui: ui, version: store.version, folderID: ui.isSearching ? nil : ui.folderID)
                        .safeAreaInset(edge: .bottom) { StatsFooter() }
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    VStack(spacing: 0) {
                        Banners()
                        contentList(tree)
                    }
                }
                .searchable(text: $ui.query, placement: .toolbar, prompt: L("Szukaj w nazwach i adresach", "Search names and addresses"))
                .toolbar(id: "main") { MainToolbar() }
                .navigationTitle(title(tree))
                .onChange(of: store.version) {
                    // Wybrany folder zniknął (np. usunięty) – przejdź wyżej.
                    if let id = ui.folderID, tree.byID[id] == nil { ui.folderID = nil }
                }
            } else {
                ProgressView()
            }
        }
        .sheet(item: $ui.sheet) { sheet in
            switch sheet {
            case .move(let ids): MoveSheet(ids: ids)
            case .rename(let id): RenameSheet(id: id)
            case .newBookmark(let folder): NewBookmarkSheet(folder: folder)
            case .info(let id): InfoSheet(id: id)
            case .backups: BackupsSheet()
            case .resend(let plan): ResendSheet(plan: plan)
            case .duplicates: DuplicatesSheet()
            case .linkCheck: LinkCheckSheet()
            case .importBookmarks: ImportSheet()
            }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button(L("Usuń", "Delete"), role: .destructive) {
                if let ids = ui.deleteRequest { store.delete(ids) }
                ui.selection = []
                ui.deleteRequest = nil
            }
        } message: {
            Text(L("Do zapisu możesz to cofnąć (⌘Z).", "Until you save, you can undo this (⌘Z)."))
        }
        .alert(L("Zapisać zmiany w zakładkach Safari?", "Save changes to Safari bookmarks?"), isPresented: $ui.confirmSave) {
            Button(L("Anuluj", "Cancel"), role: .cancel) {}
            Button(L("Zapisz", "Save")) { ui.performSave(store) }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(saveSummary)
        }
        .alert(item: $ui.message) { m in
            Alert(title: Text(m.title), message: Text(m.text), dismissButton: .default(Text("OK")))
        }
        .overlay { Toast() }
        .confirmationDialog(L("Odrzucić niezapisane zmiany i wczytać zakładki od nowa?", "Discard unsaved changes and reload the bookmarks?"), isPresented: $ui.confirmReload) {
            Button(L("Wczytaj od nowa", "Reload"), role: .destructive) { store.reload() }
        }
    }

    @ViewBuilder
    private func contentList(_ tree: BookmarkTree) -> some View {
        if ui.isSearching {
            let results = store.search(ui.query)
            if results.isEmpty {
                ContentUnavailableView.search
            } else {
                ContentTable(store: store, ui: ui, rows: results.map(\.node),
                             paths: Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.path) }),
                             folderID: nil, version: store.version, selection: ui.selection)
            }
        } else if let id = ui.folderID, let folder = tree.byID[id] {
            ContentTable(store: store, ui: ui, rows: folder.children ?? [], paths: nil,
                         folderID: id, version: store.version, selection: ui.selection)
                .overlay {
                    if folder.children?.isEmpty ?? true {
                        Text(L("Pusty folder – możesz tu przeciągnąć zakładki", "Empty folder – you can drag bookmarks here")).foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            ContentUnavailableView(L("Wybierz folder po lewej", "Choose a folder on the left"), systemImage: "folder")
        }
    }

    private func title(_ tree: BookmarkTree) -> String {
        if ui.isSearching { return L("Wyniki wyszukiwania", "Search results") }
        guard let id = ui.folderID, let node = tree.byID[id] else { return "Safari Bookmarks" }
        return node.title
    }

    private var saveSummary: String {
        let h = store.history
        var lines = h.prefix(6).map { "• \($0)" }
        if h.count > 6 { lines.append(L("• …i jeszcze \(h.count - 6)", "• …and \(h.count - 6) more")) }
        lines.append("")
        lines.append(L("Przed zapisem zostanie zrobiona kopia obecnych zakładek.", "A backup of the current bookmarks is made before saving."))
        return lines.joined(separator: "\n")
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { ui.deleteRequest != nil }, set: { if !$0 { ui.deleteRequest = nil } })
    }

    private var deleteTitle: String {
        guard let ids = ui.deleteRequest else { return "" }
        let s = store.deletionSummary(ids)
        if s.folders > 0 {
            return L("Usunąć razem z zawartością? W środku: \(Plural.folders(s.folders)), \(Plural.bookmarks(s.leaves)).", "Delete with everything inside? Inside: \(Plural.folders(s.folders)), \(Plural.bookmarks(s.leaves)).")
        }
        return s.items == 1 ? L("Usunąć tę zakładkę?", "Delete this bookmark?") : L("Usunąć \(Plural.bookmarks(s.leaves))?", "Delete \(Plural.bookmarks(s.leaves))?")
    }
}

// MARK: - Pasek narzędzi

private struct MainToolbar: CustomizableToolbarContent {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui
    @AppStorage("sortRecursive") private var sortRecursive = false

    var body: some CustomizableToolbarContent {
        let ids = ui.selection
        let editable = store.canEdit(ids)
        let folder = ui.isSearching ? nil : ui.folderID
        let folderName = folder.flatMap { store.tree?.byID[$0]?.title } ?? ""
        let isReadingList = folder.flatMap { store.tree?.byID[$0]?.isReadingListRoot } ?? false

        ToolbarItem(id: "undo", placement: .navigation) {
            Button(L("Cofnij", "Undo"), systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(store.undoLabel == nil)
                .help(store.undoLabel.map { L("Cofnij: \($0) (⌘Z)", "Undo: \($0) (⌘Z)") } ?? L("Cofnij ostatnią zmianę (⌘Z)", "Undo the last change (⌘Z)"))
        }
        ToolbarItem(id: "redo", placement: .navigation) {
            Button(L("Ponów", "Redo"), systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(store.redoLabel == nil)
                .help(store.redoLabel.map { L("Ponów: \($0) (⇧⌘Z)", "Redo: \($0) (⇧⌘Z)") } ?? L("Ponów cofniętą zmianę (⇧⌘Z)", "Redo the undone change (⇧⌘Z)"))
        }
        ToolbarItem(id: "rename") {
            Button(L("Edytuj", "Edit"), systemImage: "pencil") {
                if let id = ui.singleSelection { ui.sheet = .rename(id) }
            }
            .disabled(!editable || ids.count != 1)
            .help(L("Zmień nazwę i adres zaznaczonej zakładki albo nazwę folderu (Enter)", "Change the name and address of the selected bookmark, or the name of a folder (Return)"))
        }
        // Grupa – blok paska narzędzi mieści najwyżej 10 elementów.
        Group {
            ToolbarItem(id: "newBookmark") {
                Button(L("Nowa zakładka", "New Bookmark"), systemImage: "link.badge.plus") { ui.newBookmark(store) }
                    .disabled(store.folderForNewBookmark(preferred: folder) == nil)
                    .help(L("Nowa zakładka w otwartym folderze (⌘D)", "New bookmark in the open folder (⌘D)"))
            }
            ToolbarItem(id: "newFolder") {
                Button(L("Nowy folder", "New Folder"), systemImage: "folder.badge.plus") { ui.newFolder(store) }
                    .disabled(store.folderForNewFolder(preferred: folder) == nil)
                    .help(L("Nowy folder w otwartym folderze (⇧⌘N)", "New folder in the open folder (⇧⌘N)"))
            }
        }
        ToolbarItem(id: "move") {
            Button(L("Przenieś", "Move"), systemImage: "arrow.right.doc.on.clipboard") { ui.sheet = .move(ids) }
                .disabled(!editable)
                .help(L("Przenieś zaznaczone do innego folderu (⇧⌘M). Możesz też przeciągnąć myszą.", "Move the selection to another folder (⇧⌘M). You can also drag it."))
        }
        ToolbarItem(id: "delete") {
            Button(L("Usuń", "Delete"), systemImage: "trash") { ui.deleteRequest = ids }
                .disabled(!editable)
                .help(L("Usuń zaznaczone (⌫). Do zapisu możesz to cofnąć (⌘Z).", "Delete the selection (⌫). Until you save, you can undo it (⌘Z)."))
        }
        ToolbarItem(id: "sort") {
            Menu {
                if isReadingList {
                    // Lista Czytelnicza nie ma folderów – tylko jedno sortowanie.
                    Button(L("Sortuj alfabetycznie", "Sort Alphabetically")) {
                        if let folder { store.sort(folder, mode: .mixed, recursive: false) }
                    }
                } else {
                    Section(L("Sortuj folder „\(folderName)”", "Sort folder “\(folderName)”")) {
                        ForEach(BookmarkStore.SortMode.allCases) { mode in
                            Button(mode.title) { if let folder { store.sort(folder, mode: mode, recursive: sortRecursive) } }
                        }
                    }
                    Divider()
                    Toggle(L("Sortuj też wszystkie podfoldery", "Also sort all subfolders"), isOn: $sortRecursive)
                }
            } label: {
                Label(L("Sortuj", "Sort"), systemImage: "arrow.up.arrow.down")
            }
            .disabled(!store.canSort(folder))
            .help(L("Sortuj otwarty folder alfabetycznie. Zmienia kolejność w Safari po zapisie, można cofnąć (⌘Z).", "Sort the open folder alphabetically. Changes the order in Safari after saving; can be undone (⌘Z)."))
        }
        ToolbarItem(id: "reload") {
            Button(L("Wczytaj ponownie", "Reload"), systemImage: "arrow.clockwise") {
                if store.hasChanges { ui.confirmReload = true } else { store.reload() }
            }
            .help(L("Wczytaj zakładki od nowa z Safari (⌘R)", "Reload the bookmarks from Safari (⌘R)"))
        }
        ToolbarItem(id: "backups") {
            Button(L("Kopie zapasowe", "Backups"), systemImage: "clock.arrow.circlepath") { ui.sheet = .backups }
                .help(L("Kopie zapasowe – przywróć zakładki z wcześniejszego zapisu", "Backups – restore the bookmarks from an earlier save"))
        }
        // Grupa – blok paska narzędzi mieści najwyżej 10 elementów.
        Group {
        ToolbarItem(id: "icloud") {
            ICloudStatusButton()
        }
        ToolbarItem(id: "save") {
            Button {
                ui.requestSave(store)
            } label: {
                Label(store.hasChanges ? L("Zapisz (\(store.history.count))", "Save (\(store.history.count))") : L("Zapisz", "Save"), systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!store.hasChanges)
            .buttonStyle(.borderedProminent)
            .tint(store.hasChanges ? .accentColor : .gray)
            .help(store.hasChanges
                  ? L("Zapisz zmiany w zakładkach Safari (⌘S). Safari musi być otwarte.", "Save changes to Safari bookmarks (⌘S). Safari must be open.")
                  : L("Nie ma zmian do zapisania", "No changes to save"))
        }
        }
    }
}

/// Kolorowa ikonka stanu iCloud: zielona – wysłano, pomarańczowa – czeka, czerwona – problem, szara – wyłączony.
private struct ICloudStatusButton: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui
    @State private var showDetails = false

    var body: some View {
        Button {
            showDetails.toggle()
        } label: {
            Label(L("iCloud", "iCloud"), systemImage: symbol)
                .foregroundStyle(color)
        }
        .help(summary)
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label(summary, systemImage: symbol)
                    .foregroundStyle(color)
                    .font(.headline)
                Text(details)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if canSend {
                    HStack {
                        Spacer()
                        Button(L("Wyślij teraz", "Send Now")) {
                            showDetails = false
                            ui.sendNow(store)
                        }
                        .disabled(!store.safariRunning)
                    }
                }
            }
            .padding(16)
            .frame(width: 340)
        }
    }

    private var canSend: Bool {
        switch store.icloudState {
        case .waiting, .problem: true
        default: false
        }
    }

    private var symbol: String {
        switch store.icloudState {
        case .off: "icloud.slash"
        case .sent: "checkmark.icloud.fill"
        case .waiting: "icloud.and.arrow.up.fill"
        case .problem: "exclamationmark.icloud.fill"
        }
    }

    private var color: Color {
        switch store.icloudState {
        case .off: .gray
        case .sent: .green
        case .waiting: .orange
        case .problem: .red
        }
    }

    private var summary: String {
        switch store.icloudState {
        case .off: L("iCloud wyłączony", "iCloud off")
        case .sent: L("Wysłano do iCloud", "Sent to iCloud")
        case .waiting(let n): L("Czeka na iCloud: \(n)", "Waiting for iCloud: \(n)")
        case .problem(_, let n): L("Problem z wysłaniem: \(n)", "Problem sending: \(n)")
        }
    }

    private var details: String {
        switch store.icloudState {
        case .off:
            store.isTestFile
                ? L("Tryb testowy – aplikacja pracuje na kopii i nic nie wysyła do iCloud.", "Test mode – the app works on a copy and sends nothing to iCloud.")
                : L("Zakładki Safari nie są synchronizowane z iCloud na tym Macu.", "Safari bookmarks are not synced with iCloud on this Mac.")
        case .sent:
            L("Wszystkie zmiany są w iCloud. Inne urządzenia pobiorą je, gdy otworzysz na nich Safari.", "All changes are in iCloud. Other devices get them when you open Safari on them.")
        case .waiting(let n):
            L("\(n) zmian czeka w zakładkach Safari na wysłanie. Zwykle idą w ciągu kilku sekund po zapisie.", "\(n) changes are waiting in Safari bookmarks to be sent. They usually go within seconds after saving.")
        case .problem(let text, _):
            text
        }
    }
}

private struct Banners: View {
    @Environment(BookmarkStore.self) private var store

    var body: some View {
        if store.isTestFile {
            banner(L("Tryb testowy: plik \(store.fileURL.lastPathComponent) zamiast zakładek Safari.", "Test mode: file \(store.fileURL.lastPathComponent) instead of Safari bookmarks."), color: .purple)
        }
        if store.safariBlocksSaving {
            HStack {
                Text(L("Safari jest zamknięte. Możesz porządkować, ale żeby zapisać zmiany, otwórz Safari.", "Safari is closed. You can organize, but to save changes, open Safari."))
                    .font(.callout)
                Spacer()
                Button(L("Otwórz Safari", "Open Safari")) { Task { await SafariControl.launch() } }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
        }
        if let notice = store.notice {
            banner(notice, color: .red)
        }
        if store.hasChanges {
            banner(L("Niezapisane zmiany: \(store.history.count). Safari zobaczy je dopiero po zapisie.", "Unsaved changes: \(store.history.count). Safari sees them only after saving."), color: .blue)
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.15))
    }
}

private struct StatsFooter: View {
    @Environment(BookmarkStore.self) private var store

    var body: some View {
        if let tree = store.tree {
            let s = tree.stats
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Plural.bookmarks(s.leaves)), \(Plural.folders(s.folders))")
                if s.missingUUID > 0 || !s.duplicateUUIDs.isEmpty {
                    Text(L("Uszkodzone wpisy: \(s.missingUUID + s.duplicateUUIDs.count) (nie da się ich zmieniać)", "Damaged entries: \(s.missingUUID + s.duplicateUUIDs.count) (cannot be changed)"))
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }
}

// MARK: - Krótkie potwierdzenie

private struct Toast: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        Group {
            if store.isWriting {
                hud(text: L("Zapisuję…", "Saving…")) { ProgressView().controlSize(.large) }
            } else if let text = ui.toast {
                hud(text: text) { Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.green) }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: ui.toast)
        .animation(.easeInOut(duration: 0.25), value: store.isWriting)
    }

    private func hud(text: String, @ViewBuilder icon: () -> some View) -> some View {
        VStack(spacing: 12) {
            icon()
            Text(text).font(.title3)
        }
        .padding(28)
        .frame(minWidth: 180)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - Błąd

private struct ErrorView: View {
    @Environment(BookmarkStore.self) private var store
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label(L("Nie udało się wczytać zakładek", "Could not load the bookmarks"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            if case FileError.noPermission = error {
                Button(L("Otwórz Ustawienia → Pełny dostęp do dysku", "Open Settings → Full Disk Access")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
            Button(L("Spróbuj ponownie", "Try again")) { store.reload() }
        }
    }
}
