import SwiftUI

// MARK: - Przenoszenie

struct MoveSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    let ids: Set<String>
    @State private var target: String?
    @State private var atStart = false
    @State private var filter = ""

    var body: some View {
        let targets = store.moveTargets(for: ids)
        let q = filter.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? targets : targets.filter {
            $0.node.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(L("Szukaj folderu", "Find folder"), text: $filter).textFieldStyle(.roundedBorder)
            List(selection: $target) {
                ForEach(shown, id: \.node.id) { t in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(t.node.title, systemImage: t.node.systemImage)
                        if !q.isEmpty, let tree = store.tree {
                            Text(tree.pathString(of: t.node.id)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, q.isEmpty ? CGFloat(t.depth) * 16 : 0)
                    .foregroundStyle(t.enabled ? .primary : .tertiary)
                    .selectionDisabled(!t.enabled)
                    .tag(t.node.id)
                }
            }
            .frame(minHeight: 320)
            Picker(L("Gdzie", "Where"), selection: $atStart) {
                Text(L("na końcu folderu", "at the end of the folder")).tag(false)
                Text(L("na początku folderu", "at the start of the folder")).tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Przenieś", "Move")) {
                    if let target { store.move(ids, to: target, index: atStart ? 0 : nil) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target.map { !store.canMove(ids, to: $0) } ?? true)
            }
        }
        .padding(20)
        .frame(width: 480, height: 560)
    }

    private var title: String {
        if ids.count == 1, let id = ids.first, let node = store.tree?.byID[id] {
            return L("Przenieś „\(node.title)” do:", "Move “\(node.title)” to:")
        }
        return L("Przenieś \(ids.count) elem. do:", "Move \(ids.count) items to:")
    }
}

// MARK: - Zmiana nazwy

struct RenameSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Zmień nazwę", "Rename")).font(.headline)
            if let url = store.tree?.byID[id]?.url {
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            TextField(L("Nazwa", "Name"), text: $text).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Zmień", "Rename")) {
                    store.rename(id, to: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let node = store.tree?.byID[id] { text = node.rawTitle.isEmpty ? node.title : node.rawTitle }
        }
    }
}

// MARK: - Nowa zakładka

struct NewBookmarkSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    let folder: String
    @State private var name = ""
    @State private var address = ""

    private var validURL: String? { BookmarkStore.normalizedURL(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Nowa zakładka w „\(store.tree?.byID[folder]?.title ?? "")”", "New bookmark in “\(store.tree?.byID[folder]?.title ?? "")”"))
                .font(.headline)
            TextField(L("Nazwa (puste = nazwa strony z adresu)", "Name (empty = site name from the address)"), text: $name)
                .textFieldStyle(.roundedBorder)
            TextField(L("Adres, np. https://…", "Address, e.g. https://…"), text: $address)
                .textFieldStyle(.roundedBorder)
            if !address.trimmingCharacters(in: .whitespaces).isEmpty, validURL == nil {
                Text(L("To nie wygląda na adres strony.", "This does not look like a web address."))
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Dodaj", "Add")) {
                    if let id = store.addBookmark(in: folder, title: name, url: address) {
                        ui.bookmarkAdded(id, in: folder)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validURL == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // Adres skopiowany ze strony – od razu w polu.
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.lowercased().hasPrefix("http"), BookmarkStore.normalizedURL(s) != nil {
                address = s
            }
        }
    }
}

// MARK: - Stare zmiany do iCloud

struct ResendSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: ResendChanges.Plan

    private var since: String {
        plan.since?.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(AppLanguage.locale)) ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Wyślij do iCloud stare zmiany", "Send old changes to iCloud")).font(.headline)
            Text(L("Zmiany zapisane wersją 1.0.0 nie trafiły do iCloud, więc iPhone i inne urządzenia ich nie mają. Aplikacja porównała kopię z \(since) (sprzed pierwszego zapisu) z obecnymi zakładkami.",
                   "Changes saved with version 1.0.0 did not reach iCloud, so your iPhone and other devices do not have them. The app compared the backup from \(since) (before the first save) with your current bookmarks."))
                .fixedSize(horizontal: false, vertical: true)
            Form {
                LabeledContent(L("Przeniesienia i kolejność", "Moves and order"), value: "\(plan.moved)")
                LabeledContent(L("Zmiany nazw", "Renames"), value: "\(plan.renamed)")
                LabeledContent(L("Usunięte", "Deleted"), value: plan.deleted.isEmpty ? "0" : "\(plan.deleted.count) (\(Plural.bookmarks(plan.deleted.reduce(0) { $0 + $1.leaves })))")
            }
            .formStyle(.grouped)
            .frame(height: 150)
            if !plan.deleted.isEmpty {
                Text(L("Te elementy znikną też z iPhone’a i innych urządzeń:", "These items will also disappear from your iPhone and other devices:"))
                    .font(.callout)
                List(plan.deleted.indices, id: \.self) { i in
                    let d = plan.deleted[i]
                    HStack {
                        Label(d.title.replacingOccurrences(of: "\n", with: " "), systemImage: d.isFolder ? "folder" : "bookmark")
                            .lineLimit(1)
                        Spacer()
                        if d.isFolder { Text(Plural.bookmarks(d.leaves)).foregroundStyle(.secondary) }
                    }
                }
                .frame(minHeight: 160)
            }
            Text(L("Zakładki na Macu się nie zmienią. Po „Przygotuj” zapisz (⌘S) przy zamkniętym Safari, potem otwórz Safari – wtedy zmiany pójdą do iCloud.",
                   "Bookmarks on this Mac will not change. After “Prepare”, save (⌘S) with Safari closed, then open Safari – that is when the changes go to iCloud."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Przygotuj", "Prepare")) {
                    store.resend(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

// MARK: - Informacje

struct InfoSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tree = store.tree, let node = tree.byID[id] {
                Form {
                    Section {
                        LabeledContent(L("Nazwa", "Name")) { Text(node.title).textSelection(.enabled) }
                        if let url = node.url {
                            LabeledContent(L("Adres", "Address")) { Text(url).textSelection(.enabled).lineLimit(4) }
                        }
                        LabeledContent(L("Folder", "Folder"), value: tree.pathString(of: id).isEmpty ? "—" : tree.pathString(of: id))
                        if node.isFolder {
                            LabeledContent(L("W środku", "Contains"), value: "\(Plural.bookmarks(node.leafCount)), \(Plural.folders(node.folderCount))")
                        }
                        if let date = node.dateAdded {
                            LabeledContent(L("Dodano", "Added"), value: date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(AppLanguage.locale)))
                        }
                        LabeledContent(L("Synchronizowane z iCloud", "Synced with iCloud"), value: node.hasSync ? L("tak", "yes") : L("nie", "no"))
                        if let reason = store.lockReason(id) {
                            LabeledContent(L("Zmiany", "Changes"), value: reason)
                        }
                    }
                    Section {
                        DisclosureGroup(L("Dane techniczne", "Technical details")) {
                            LabeledContent(L("Identyfikator", "Identifier")) {
                                Text(node.uuid ?? "brak").textSelection(.enabled).monospaced()
                            }
                            ForEach(node.attributes, id: \.key) { a in
                                LabeledContent(a.key) {
                                    Text(a.preview).textSelection(.enabled).font(.caption.monospaced()).lineLimit(6)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                Text(L("Tego elementu już nie ma.", "This item no longer exists."))
            }
            HStack {
                Spacer()
                Button(L("Zamknij", "Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

// MARK: - Kopie zapasowe

struct BackupsSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [Backup] = []
    @State private var selected: Backup.ID?
    @State private var confirm: Backup?

    private var backupDate: String {
        confirm?.date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(AppLanguage.locale)) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Kopie zapasowe", "Backups")).font(.headline)
            Text(L("Kopia powstaje przy każdym zapisie.", "A backup is made with every save.")).font(.callout).foregroundStyle(.secondary)
            List(backups, selection: $selected) { b in
                HStack {
                    Text(b.date.formatted(Date.FormatStyle(date: .long, time: .standard).locale(AppLanguage.locale)))
                    if b.url.lastPathComponent.hasPrefix("TEST") { Text("(test)").foregroundStyle(.secondary) }
                    Spacer()
                }
                .tag(b.id)
            }
            .frame(minHeight: 260)
            if store.hasChanges {
                Text(L("Masz niezapisane zmiany – zapisz je albo odrzuć, zanim przywrócisz kopię.", "You have unsaved changes – save or discard them before restoring a backup."))
                    .font(.callout).foregroundStyle(.orange)
            } else if store.safariBlocksSaving {
                Text(L("Safari jest otwarte – żeby przywrócić kopię, zamknij Safari.", "Safari is open – quit Safari to restore a backup."))
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button(L("Pokaż w Finderze", "Show in Finder")) {
                    if let b = backups.first(where: { $0.id == selected }) {
                        NSWorkspace.shared.activateFileViewerSelecting([b.url])
                    } else {
                        NSWorkspace.shared.open(Backups.directory)
                    }
                }
                Spacer()
                Button(L("Zamknij", "Close"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Przywróć…", "Restore…")) { confirm = backups.first { $0.id == selected } }
                    .disabled(selected == nil || store.hasChanges || store.safariBlocksSaving)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { backups = Backups.list() }
        .alert(L("Przywrócić zakładki z tej kopii?", "Restore the bookmarks from this backup?"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(L("Anuluj", "Cancel"), role: .cancel) {}
            Button(L("Przywróć", "Restore")) {
                if let b = confirm {
                    dismiss()
                    ui.performRestore(b, store: store)
                }
            }
        } message: {
            Text(L("Obecne zakładki zostaną zastąpione stanem z \(backupDate). Obecny stan też trafi do kopii.", "The current bookmarks will be replaced with the state from \(backupDate). The current state is backed up too."))
        }
    }
}
