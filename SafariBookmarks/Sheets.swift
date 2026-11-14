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

// MARK: - Edycja (nazwa i adres)

/// Edycja zakładki (nazwa i adres) albo folderu (nazwa). Ten sam wygląd co „Nowa zakładka”.
struct RenameSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var address = ""

    private var node: BookmarkNode? { store.tree?.byID[id] }
    private var isBookmark: Bool { node?.kind == .leaf }
    private var addressOK: Bool { !isBookmark || BookmarkStore.normalizedURL(address) != nil }
    private var nameOK: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isBookmark ? L("Edytuj zakładkę", "Edit Bookmark") : L("Zmień nazwę folderu", "Rename Folder")).font(.headline)
            TextField(L("Nazwa", "Name"), text: $name).textFieldStyle(.roundedBorder)
            if isBookmark {
                TextField(L("Adres, np. https://…", "Address, e.g. https://…"), text: $address)
                    .textFieldStyle(.roundedBorder)
                if !address.trimmingCharacters(in: .whitespaces).isEmpty, !addressOK {
                    Text(L("To nie wygląda na adres strony.", "This does not look like a web address."))
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Zmień", "Change")) {
                    store.edit(id, title: name, url: isBookmark ? address : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameOK || !addressOK)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let node else { return }
            name = node.rawTitle.isEmpty ? node.title : node.rawTitle
            address = node.url ?? ""
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
            Text(L("Zakładki na Macu się nie zmienią. Po „Przygotuj” zapisz (⌘S) przy otwartym Safari.",
                   "Bookmarks on this Mac will not change. After “Prepare”, save (⌘S) while Safari is open."))
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

// MARK: - Duplikaty

struct DuplicatesSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [Duplicates.Group] = []
    /// Zakładki zaznaczone do usunięcia.
    @State private var toRemove: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Duplikaty", "Duplicates")).font(.headline)
            if groups.isEmpty {
                Text(L("Nie ma zdublowanych zakładek. (Lista Czytelnicza jest pominięta.)", "There are no duplicate bookmarks. (The Reading List is skipped.)"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(L("Zaznacz zakładki do usunięcia. W grupach z identycznym adresem aplikacja proponuje zostawić jedną: z Ulubionych, z https albo najstarszą. W grupach „prawie identycznych” (różnica tylko w http/https, „www.” albo ukośniku na końcu) nic nie jest zaznaczone – zdecyduj sam.",
                       "Check the bookmarks to delete. In groups with an identical address the app suggests keeping one: from Favorites, with https or the oldest. In “almost identical” groups (only http/https, “www.” or a trailing slash differ) nothing is checked – you decide."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                row(item)
                            }
                        } header: {
                            HStack {
                                Text(group.identical ? L("Identyczne", "Identical") : L("Prawie identyczne", "Almost identical"))
                                    .foregroundStyle(group.identical ? Color.primary : Color.orange)
                                Text(group.key).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(minHeight: 360)
            }
            HStack {
                Text(L("Grup: \(groups.count)", "Groups: \(groups.count)")).foregroundStyle(.secondary)
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Usuń zaznaczone (\(toRemove.count))", "Delete Checked (\(toRemove.count))")) {
                    store.delete(toRemove)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(toRemove.isEmpty || !store.canEdit(toRemove))
            }
            Text(L("Usunięcie da się cofnąć (⌘Z) aż do zapisu.", "Deleting can be undone (⌘Z) until you save."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: load)
    }

    private func row(_ item: BookmarkNode) -> some View {
        let checked = Binding(get: { toRemove.contains(item.id) },
                              set: { if $0 { toRemove.insert(item.id) } else { toRemove.remove(item.id) } })
        return HStack(alignment: .top) {
            Toggle(isOn: checked) { EmptyView() }
                .toggleStyle(.checkbox)
                .disabled(store.lockReason(item.id) != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.url ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    Label(store.tree?.pathString(of: item.id) ?? "", systemImage: "folder")
                    if let date = item.dateAdded {
                        Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(AppLanguage.locale)))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(checked.wrappedValue ? L("usuń", "delete") : L("zostaw", "keep"))
                .font(.caption).foregroundStyle(checked.wrappedValue ? .red : .green)
        }
    }

    private func load() {
        guard let tree = store.tree else { return }
        groups = Duplicates.find(in: tree)
        // Propozycja: w identycznych zostaje pierwsza (najlepsza), reszta do usunięcia.
        toRemove = Set(groups.filter(\.identical).flatMap { $0.items.dropFirst().map(\.id) }
            .filter { store.lockReason($0) == nil })
    }
}

// MARK: - Sprawdzanie linków

struct LinkCheckSheet: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var total = 0
    @State private var results: [LinkChecker.Result] = []
    @State private var running = false
    @State private var finished = false
    @State private var task: Task<Void, Never>?
    /// Zakładki z zaznaczoną poprawką adresu.
    @State private var fix: Set<String> = []
    /// Martwe zakładki zaznaczone do usunięcia.
    @State private var remove: Set<String> = []

    private var problems: [LinkChecker.Result] { results.filter { $0.verdict != .ok } }
    private var okCount: Int { results.count - problems.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Sprawdź linki", "Check Links")).font(.headline)
            if !running && !finished {
                Text(L("Aplikacja odwiedzi każdą zakładkę (\(store.linkCheckItems().count)) jak przeglądarka, ale bez ciasteczek i zapisanych logowań, i pokaże: martwe, przekierowane na stałe pod nowy adres oraz te, które działają też przez https. Każda strona zobaczy przy tym zwykłe wejście z Twojego adresu. Lista Czytelnicza i zakładki oznaczone „Pomijaj” nie są sprawdzane. Nic nie zmienia się bez Twojej zgody.",
                       "The app visits every bookmark (\(store.linkCheckItems().count)) like a browser, but without cookies or saved logins, and shows: dead ones, ones permanently moved to a new address, and ones that also work over https. Each site sees an ordinary visit from your address. The Reading List and bookmarks marked “Skip” are not checked. Nothing changes without your approval."))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView(value: Double(results.count), total: Double(max(total, 1))) {
                    Text(running ? L("Sprawdzono \(results.count) z \(total)", "Checked \(results.count) of \(total)")
                                 : L("Sprawdzono \(results.count) z \(total) – działa: \(okCount), do przejrzenia: \(problems.count)", "Checked \(results.count) of \(total) – working: \(okCount), to review: \(problems.count)"))
                }
                List {
                    section(L("Przekierowane na stałe – popraw adres", "Permanently moved – fix the address"), kind: .redirect)
                    section(L("Działają przez https – zmień adres", "Work over https – change the address"), kind: .https)
                    section(L("Martwe – zaznacz do usunięcia", "Dead – check to delete"), kind: .dead)
                    section(L("Niepewne – tylko do wiadomości", "Unsure – for your information"), kind: .unsure)
                }
                .frame(minHeight: 380)
            }
            HStack {
                if running {
                    Button(L("Zatrzymaj", "Stop")) { task?.cancel() }
                }
                Spacer()
                Button(L("Anuluj", "Cancel"), role: .cancel) { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !running && !finished {
                    Button(L("Sprawdź", "Check")) { start() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Zastosuj (\(fix.count + remove.count))", "Apply (\(fix.count + remove.count))")) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || fix.count + remove.count == 0)
                }
            }
        }
        .padding(20)
        .frame(width: 680)
        .onDisappear { task?.cancel() }
    }

    private enum Kind { case redirect, https, dead, unsure }

    private func kind(_ v: LinkChecker.Verdict) -> Kind? {
        switch v {
        case .ok: nil
        case .redirected: .redirect
        case .httpsAvailable: .https
        case .dead: .dead
        case .unsure: .unsure
        }
    }

    @ViewBuilder
    private func section(_ title: String, kind k: Kind) -> some View {
        let items = problems.filter { kind($0.verdict) == k }
        if !items.isEmpty {
            Section(title + " (\(items.count))") {
                ForEach(items) { r in row(r, kind: k) }
            }
        }
    }

    private func row(_ r: LinkChecker.Result, kind k: Kind) -> some View {
        let node = store.tree?.byID[r.id]
        let selection: Binding<Bool>? = switch k {
        case .redirect, .https: Binding(get: { fix.contains(r.id) }, set: { if $0 { fix.insert(r.id) } else { fix.remove(r.id) } })
        case .dead: Binding(get: { remove.contains(r.id) }, set: { if $0 { remove.insert(r.id) } else { remove.remove(r.id) } })
        case .unsure: nil
        }
        return HStack(alignment: .top) {
            if let selection {
                Toggle(isOn: selection) { EmptyView() }.toggleStyle(.checkbox)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node?.title ?? r.url).lineLimit(1)
                Text(r.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                switch r.verdict {
                case .redirected(let to), .httpsAvailable(let to):
                    Text("→ " + to).font(.caption).foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                case .dead(let why), .unsure(let why):
                    Text(why).font(.caption).foregroundStyle(k == .dead ? .red : .orange)
                case .ok:
                    EmptyView()
                }
                Text(store.tree?.pathString(of: r.id) ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Pomijaj", "Skip")) { skip(r) }
                .controlSize(.small)
                .help(L("Nie sprawdzaj tej zakładki w przyszłości", "Do not check this bookmark in the future"))
        }
    }

    private func start() {
        let items = store.linkCheckItems()
        total = items.count
        results = []
        running = true
        task = Task {
            await LinkChecker.check(items) { r in
                results.append(r)
                // Propozycja: poprawki adresów zaznaczone, usuwanie martwych – nie.
                switch r.verdict {
                case .redirected, .httpsAvailable: fix.insert(r.id)
                default: break
                }
            }
            running = false
            finished = true
        }
    }

    private func skip(_ r: LinkChecker.Result) {
        if let uuid = store.tree?.byID[r.id]?.uuid { LinkChecker.skipped.insert(uuid) }
        results.removeAll { $0.id == r.id }
        fix.remove(r.id)
        remove.remove(r.id)
    }

    private func apply() {
        var changes: [String: String] = [:]
        for r in results where fix.contains(r.id) {
            switch r.verdict {
            case .redirected(let to), .httpsAvailable(let to): changes[r.id] = to
            default: break
            }
        }
        store.updateAddresses(changes)
        if !remove.isEmpty { store.delete(remove) }
        dismiss()
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
                Text(L("Safari jest zamknięte – żeby przywrócić kopię, otwórz Safari.", "Safari is closed – open Safari to restore a backup."))
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
