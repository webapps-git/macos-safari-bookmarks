import Foundation
import Observation

/// Stan interfejsu wspólny dla okna i menu.
@Observable
final class UIState {
    enum Sheet: Identifiable {
        case move(Set<String>)
        case rename(String)
        /// Nowa zakładka w podanym folderze.
        case newBookmark(String)
        case info(String)
        case backups
        /// Stare zmiany do dosłania do iCloud.
        case resend(ResendChanges.Plan)

        var id: String {
            switch self {
            case .move: "move"
            case .rename: "rename"
            case .newBookmark: "newBookmark"
            case .info: "info"
            case .backups: "backups"
            case .resend: "resend"
            }
        }
    }

    /// Folder wybrany w drzewie po lewej.
    var folderID: String?
    /// Zaznaczenie na liście po prawej.
    var selection: Set<String> = []
    var query = ""
    var sheet: Sheet?
    var deleteRequest: Set<String>?
    var confirmReload = false
    /// Pytanie „Zapisać zmiany?”.
    var confirmSave = false
    /// Zwykły komunikat systemowy (tytuł + treść).
    var message: Message?
    /// Krótkie potwierdzenie, które samo znika.
    var toast: String?

    struct Message: Identifiable {
        let title: String
        let text: String
        var id: String { title + text }
    }

    /// Przycisk „Zapisz”: najpierw sprawdzenia, potem pytanie.
    func requestSave(_ store: BookmarkStore) {
        guard store.hasChanges, !store.isWriting else { return }
        if store.safariBlocksSaving {
            message = Message(title: L("Najpierw zamknij Safari", "Quit Safari first"),
                              text: L("Zmiany można zapisać dopiero po zamknięciu Safari. Aplikacja sama go nie zamyka.",
                                      "Changes can only be saved after Safari is closed. The app does not quit Safari by itself."))
            return
        }
        let problems = store.verify()
        if !problems.isEmpty {
            message = Message(title: L("Nie można zapisać", "Cannot save"), text: problems.joined(separator: "\n"))
            return
        }
        confirmSave = true
    }

    func performSave(_ store: BookmarkStore) {
        Task {
            switch await store.save() {
            case .ok: showToast(L("Zapisano", "Saved"))
            case .failed(let text): message = Message(title: L("Nie zapisano", "Not saved"), text: text)
            }
        }
    }

    func performRestore(_ backup: Backup, store: BookmarkStore) {
        Task {
            switch await store.restore(backup) {
            case .ok: showToast(L("Przywrócono zakładki z kopii", "Bookmarks restored from backup"))
            case .failed(let text): message = Message(title: L("Nie przywrócono", "Not restored"), text: text)
            }
        }
    }

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == text { toast = nil }
        }
    }

    /// Nowy folder w `target` (albo w otwartym folderze / Ulubionych), od razu z polem na nazwę.
    func newFolder(_ store: BookmarkStore, in target: String? = nil) {
        guard sheet == nil, let folder = store.folderForNewFolder(preferred: target ?? (isSearching ? nil : folderID)),
              let id = store.addFolder(in: folder, title: L("Nowy folder", "New Folder")) else { return }
        query = ""
        folderID = folder
        selection = [id]
        sheet = .rename(id)
    }

    /// Okno „Nowa zakładka” dla `target` (albo otwartego folderu / Ulubionych).
    func newBookmark(_ store: BookmarkStore, in target: String? = nil) {
        guard sheet == nil, let folder = store.folderForNewBookmark(preferred: target ?? (isSearching ? nil : folderID)) else { return }
        sheet = .newBookmark(folder)
    }

    /// „Wyślij do iCloud stare zmiany…”: najpierw podsumowanie, nic jeszcze się nie zmienia.
    func openResend(_ store: BookmarkStore) {
        guard sheet == nil, !store.hasChanges else { return }
        switch store.resendPlan() {
        case .success(let plan) where plan.isEmpty:
            message = Message(title: L("Nie ma czego wysyłać", "Nothing to send"),
                              text: L("Wszystkie zmiany zapisane w aplikacji są już zgłoszone do iCloud.", "All changes saved in the app have already been passed to iCloud."))
        case .success(let plan):
            sheet = .resend(plan)
        case .failure(let error):
            message = Message(title: L("Nie można", "Not possible"), text: error.localizedDescription)
        }
    }

    /// Po dodaniu: pokaż folder i zaznacz nową zakładkę.
    func bookmarkAdded(_ id: String, in folder: String) {
        query = ""
        folderID = folder
        selection = [id]
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var singleSelection: String? { selection.count == 1 ? selection.first : nil }

    /// Otwiera folder zawierający element i zaznacza go.
    func reveal(_ id: String, in tree: BookmarkTree) {
        query = ""
        folderID = tree.parent[id]
        selection = [id]
    }

    func open(folder id: String) {
        query = ""
        folderID = id
        selection = []
    }
}
