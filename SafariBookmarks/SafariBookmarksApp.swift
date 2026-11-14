import SwiftUI

@main
struct SafariBookmarksApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = BookmarkStore()
    @State private var ui = UIState()

    var body: some Scene {
        Window("Safari Bookmarks", id: "main") {
            ContentView()
                .environment(store)
                .environment(ui)
                .frame(minWidth: 960, minHeight: 540)
                .background(MainWindowCloser())
                .task {
                    AppServices.store = store
                    store.reload()
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) { AboutMenuButton() }
            // Nie ma pomocy.
            CommandGroup(replacing: .help) {}
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoLabel.map { L("Cofnij: \($0)", "Undo: \($0)") } ?? L("Cofnij", "Undo")) { store.undo() }
                    .keyboardShortcut("z")
                    .disabled(store.undoLabel == nil || ui.sheet != nil)
                Button(store.redoLabel.map { L("Ponów: \($0)", "Redo: \($0)") } ?? L("Ponów", "Redo")) { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(store.redoLabel == nil || ui.sheet != nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Zapisz w Safari…", "Save to Safari…")) { ui.requestSave(store) }
                    .keyboardShortcut("s")
                    .disabled(!store.hasChanges || ui.sheet != nil)
                Button(L("Kopie zapasowe…", "Backups…")) { ui.sheet = .backups }
                    .disabled(ui.sheet != nil)
                Divider()
                Button(L("Zamknij okno", "Close Window")) {
                    // Główne okno = koniec aplikacji (z pytaniem o niezapisane zmiany).
                    if let key = NSApp.keyWindow, key !== AppServices.mainWindow {
                        key.performClose(nil)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
                .keyboardShortcut("w")
            }
            CommandGroup(after: .newItem) {
                Button(L("Wczytaj ponownie", "Reload")) {
                    if store.hasChanges { ui.confirmReload = true } else { store.reload() }
                }
                .keyboardShortcut("r")
            }
            CommandMenu(L("Zakładki", "Bookmarks")) {
                EditCommands()
                    .environment(store)
                    .environment(ui)
            }
        }

        Window(L("O programie Safari Bookmarks", "About Safari Bookmarks"), id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

// MARK: - Zamykanie

/// Dostęp do stanu z kodu poza widokami (delegat aplikacji).
enum AppServices {
    static weak var store: BookmarkStore?
    static weak var mainWindow: NSWindow?
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wyjście z niezapisanymi zmianami: Zapisz / Nie zapisuj / Anuluj.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = AppServices.store, store.hasChanges else { return .terminateNow }
        if store.isWriting { return .terminateCancel }

        let alert = NSAlert()
        alert.messageText = L("Zapisać zmiany przed zamknięciem?", "Save changes before quitting?")
        var text = L("Masz niezapisane zmiany: \(store.history.count). Jeśli ich nie zapiszesz, przepadną.",
                     "You have unsaved changes: \(store.history.count). If you do not save them, they will be lost.")
        if store.safariBlocksSaving {
            text += "\n\n" + L("Safari jest zamknięte – żeby zapisać, najpierw otwórz Safari.",
                                "Safari is closed – to save, open Safari first.")
        }
        alert.informativeText = text
        alert.addButton(withTitle: L("Zapisz", "Save"))
        let dontSave = alert.addButton(withTitle: L("Nie zapisuj", "Don't Save"))
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let cancel = alert.addButton(withTitle: L("Anuluj", "Cancel"))
        cancel.keyEquivalent = "\u{1b}"

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save(store)
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func save(_ store: BookmarkStore) -> NSApplication.TerminateReply {
        if store.safariBlocksSaving {
            Self.inform(L("Najpierw otwórz Safari", "Open Safari first"),
                        L("Zmiany zapisuje się przy otwartym Safari. Aplikacja zostaje otwarta.",
                          "Changes are saved while Safari is open. The app stays open."))
            return .terminateCancel
        }
        let problems = store.verify()
        if !problems.isEmpty {
            Self.inform(L("Nie można zapisać", "Cannot save"), problems.joined(separator: "\n"))
            return .terminateCancel
        }
        Task {
            switch await store.save() {
            case .ok:
                NSApp.reply(toApplicationShouldTerminate: true)
            case .failed(let text):
                Self.inform(L("Nie zapisano", "Not saved"), text)
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    private static func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Czerwony przycisk głównego okna kończy aplikację (przez pytanie o niezapisane zmiany),
/// zamiast zostawiać ją uruchomioną bez okna.
private struct MainWindowCloser: NSViewRepresentable {
    final class Target: NSObject {
        @objc func quit() { NSApp.terminate(nil) }
    }

    private static let target = Target()

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor [weak view] in
            guard let window = view?.window, AppServices.mainWindow !== window else { return }
            AppServices.mainWindow = window
            let close = window.standardWindowButton(.closeButton)
            close?.target = Self.target
            close?.action = #selector(Target.quit)
        }
    }
}

/// „O programie Safari Bookmarks” w menu aplikacji.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("O programie Safari Bookmarks", "About Safari Bookmarks")) { openWindow(id: "about") }
    }
}

struct AboutView: View {
    static let projectURL = URL(string: "https://github.com/webapps-git/macos-safari-bookmarks")!
    static let licenseURL = URL(string: "https://github.com/webapps-git/macos-safari-bookmarks/blob/main/LICENSE")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)

            Text("Safari Bookmarks")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 10)

            Text(L("Wersja \(version)", "Version \(version)"))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(L("Porządkowanie zakładek Safari – przenoszenie, zmiana nazw, sortowanie i usuwanie – bez ryzyka ich utraty.", "Organize Safari bookmarks – move, rename, sort and delete – without losing them."))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Divider()
                .padding(.vertical, 18)

            Text(copyright)
            Text(L("Licencja MIT", "MIT License"))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            HStack(spacing: 12) {
                Button(L("Strona projektu", "Project Page")) { NSWorkspace.shared.open(Self.projectURL) }
                Button(L("Licencja", "License")) { NSWorkspace.shared.open(Self.licenseURL) }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 380)
    }
}

/// Polecenia edycji działające na zaznaczeniu (menu „Zakładki”).
private struct EditCommands: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        let ids = ui.selection
        let editable = store.canEdit(ids) && ui.sheet == nil
        Button(L("Nowa zakładka…", "New Bookmark…")) { ui.newBookmark(store) }
            .keyboardShortcut("d")
            .disabled(ui.sheet != nil || store.folderForNewBookmark(preferred: ui.isSearching ? nil : ui.folderID) == nil)
        Button(L("Nowy folder", "New Folder")) { ui.newFolder(store) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(ui.sheet != nil || store.folderForNewFolder(preferred: ui.isSearching ? nil : ui.folderID) == nil)
        Divider()
        Button(L("Edytuj…  (Enter)", "Edit…  (Return)")) { if let id = ui.singleSelection { ui.sheet = .rename(id) } }
            .disabled(!editable || ids.count != 1)
        Button(L("Przenieś do…", "Move to…")) { ui.sheet = .move(ids) }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!editable)
        Button(L("Przesuń w górę", "Move Up")) { if let id = ui.singleSelection { store.shift(id, by: -1) } }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(ui.singleSelection.map { !store.canShift($0, by: -1) } ?? true || ui.sheet != nil)
        Button(L("Przesuń w dół", "Move Down")) { if let id = ui.singleSelection { store.shift(id, by: 1) } }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(ui.singleSelection.map { !store.canShift($0, by: 1) } ?? true || ui.sheet != nil)
        Divider()
        Button(L("Usuń…  (⌫)", "Delete…  (⌫)")) { ui.deleteRequest = ids }
            .disabled(!editable)
        Divider()
        Button(L("Odrzuć wszystkie zmiany", "Discard All Changes")) { store.discardChanges() }
            .disabled(!store.hasChanges || ui.sheet != nil)
        Divider()
        Button(L("Znajdź duplikaty…", "Find Duplicates…")) { ui.sheet = .duplicates }
            .disabled(ui.sheet != nil || store.tree == nil)
        Button(L("Sprawdź linki…", "Check Links…")) { ui.sheet = .linkCheck }
            .disabled(ui.sheet != nil || store.tree == nil)
        Toggle(L("Pobieraj brakujące ikonki stron", "Download Missing Site Icons"), isOn: Binding(
            get: { Favicons.fetchFromWeb },
            set: { Favicons.fetchFromWeb = $0 }))
        Divider()
        Button(L("Importuj zakładki…", "Import Bookmarks…")) { ui.sheet = .importBookmarks }
            .disabled(ui.sheet != nil || store.tree == nil)
        Button(L("Eksportuj wszystkie zakładki…", "Export All Bookmarks…")) { exportBookmarks(store, ui: ui, folder: nil) }
            .disabled(ui.sheet != nil || store.tree == nil)
        Button(L("Eksportuj otwarty folder…", "Export Open Folder…")) { exportBookmarks(store, ui: ui, folder: ui.folderID) }
            .disabled(ui.sheet != nil || ui.isSearching || ui.folderID.flatMap { store.tree?.byID[$0] }?.isFolder != true)
        Divider()
        Button(L("Wyślij do iCloud stare zmiany…", "Send Old Changes to iCloud…")) { ui.openResend(store) }
            .disabled(store.hasChanges || ui.sheet != nil || store.tree == nil)
    }
}
