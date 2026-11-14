import Foundation

/// Uruchomienie wysyłki do iCloud po zapisie.
///
/// Program synchronizujący Safari wysyła zmiany z listy w pliku zakładek tylko na sygnał od Safari,
/// a Safari daje go dopiero po własnym zapisie zakładek. Innego programu nie słucha (wymaga
/// prywatnego uprawnienia Apple). Dlatego prosimy Safari (AppleScript) o ponowne dodanie górnej
/// pozycji Listy Czytelniczej z tym samym adresem, tytułem i opisem: Safari zastępuje ją nową
/// (lista się nie zmienia, zmienia się tylko data dodania tej pozycji), zapisuje zakładki
/// i wysyła do iCloud wszystko, co czeka – także nasze zmiany. Sprawdzone 14.11.2026.
enum SafariNudge {
    struct Item {
        let url: String
        let title: String?
        let preview: String?
    }

    /// Górna pozycja Listy Czytelniczej.
    static func topReadingListItem(in root: NSDictionary) -> Item? {
        let rl = (root["Children"] as? [NSDictionary])?.first { $0["Title"] as? String == "com.apple.ReadingList" }
        guard let top = (rl?["Children"] as? [NSDictionary])?.first,
              top["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
              let url = top["URLString"] as? String, !url.isEmpty else { return nil }
        let title = (top["URIDictionary"] as? NSDictionary)?["title"] as? String
        let preview = (top["ReadingList"] as? NSDictionary)?["PreviewText"] as? String
        return Item(url: url, title: title, preview: preview)
    }

    /// Ile zmian czeka w pliku na wysłanie do iCloud.
    static func pendingCount(_ root: NSDictionary) -> Int {
        ((root["Sync"] as? NSDictionary)?[SyncChanges.key] as? [Any])?.count ?? 0
    }

    /// Prosi Safari o ponowne dodanie pozycji. Zwraca opis błędu albo nil.
    static func run(_ item: Item) -> String? {
        var command = "add reading list item \(literal(item.url))"
        if let t = item.title, !t.isEmpty { command += " with title \(literal(t))" }
        if let p = item.preview, !p.isEmpty { command += " and preview text \(literal(p))" }
        let source = "tell application id \"com.apple.Safari\" to \(command)"
        guard let script = NSAppleScript(source: source) else { return L("Nie udało się przygotować polecenia dla Safari.", "Could not prepare the command for Safari.") }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        let number = error[NSAppleScript.errorNumber] as? Int ?? 0
        if number == -1743 {
            return L("macOS nie pozwala aplikacji sterować Safari. Włącz to w Ustawieniach systemowych → Prywatność i ochrona → Automatyzacja → Safari Bookmarks → Safari.",
                     "macOS does not allow the app to control Safari. Turn it on in System Settings → Privacy & Security → Automation → Safari Bookmarks → Safari.")
        }
        return (error[NSAppleScript.errorMessage] as? String) ?? L("Safari nie wykonało polecenia (błąd \(number)).", "Safari did not run the command (error \(number)).")
    }

    /// Tekst w cudzysłowie do AppleScriptu.
    static func literal(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
