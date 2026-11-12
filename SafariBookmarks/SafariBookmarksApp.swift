import SwiftUI

@main
struct SafariBookmarksApp: App {
    @State private var store = BookmarkStore()
    @State private var ui = UIState()

    var body: some Scene {
        Window("Safari Bookmarks", id: "main") {
            ContentView()
                .environment(store)
                .environment(ui)
                .frame(minWidth: 960, minHeight: 540)
                .task { store.reload() }
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
        Button(L("Zmień nazwę…  (Enter)", "Rename…  (Return)")) { if let id = ui.singleSelection { ui.sheet = .rename(id) } }
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
    }
}
