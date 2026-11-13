import Foundation

/// Dosłanie do iCloud zmian zapisanych wersją 1.0.0.
///
/// Wersja 1.0.0 nie dopisywała zmian do listy dla iCloud (`Sync.Changes`), więc iCloud ich nie zna.
/// Kopie zapasowe z tamtych zapisów pozwalają je odtworzyć:
///
/// - przeniesienia, kolejność i nazwy: najstarsza kopia (stan sprzed pierwszego zapisu aplikacji,
///   taki jak w iCloud) porównana z obecnymi zakładkami – jak przy zwykłym zapisie,
/// - usunięcia: to, co zniknęło między kolejnymi kopiami z tamtego okresu (czyli podczas zapisów
///   aplikacji) i czego nie ma w obecnych zakładkach; `DeletedBookmarkSyncData` z kopii.
///
/// Okres kończy się na pierwszym zapisie, przy którym dziennik aplikacji notuje „iCloud changes”
/// (od tego zapisu zmiany szły już do iCloud).
enum ResendChanges {
    struct Plan {
        var entries: [NSDictionary] = []
        var moved = 0
        var renamed = 0
        /// Usunięte elementy (najwyżej położone) z liczbą zakładek w środku.
        var deleted: [(title: String, leaves: Int, isFolder: Bool)] = []
        var deletedEntries = 0
        /// Data kopii, z którą porównano.
        var since: Date?

        var isEmpty: Bool { entries.isEmpty }
        var tokens: Set<String> { Set(entries.compactMap { $0["Token"] as? String }) }
    }

    /// Wpis w dzienniku aplikacji po zapisie z dosłanymi zmianami.
    static let logMarker = "old changes resent:"

    enum PlanError: LocalizedError {
        case notSynced, noBackups, unreadable(String), alreadySent
        var errorDescription: String? {
            switch self {
            case .alreadySent: L("Stare zmiany zostały już wysłane do iCloud. Drugi raz nie trzeba.", "The old changes have already been sent to iCloud. There is no need to do it again.")
            case .notSynced: L("Synchronizacja zakładek Safari z iCloud jest wyłączona – nie ma czego wysyłać.", "Safari bookmark sync with iCloud is off – there is nothing to send.")
            case .noBackups: L("Nie ma kopii zapasowych z wcześniejszych zapisów, więc nie da się ustalić starych zmian.", "There are no backups from earlier saves, so the old changes cannot be worked out.")
            case .unreadable(let name): L("Nie udało się odczytać kopii „\(name)”.", "Could not read the backup “\(name)”.")
            }
        }
    }

    // MARK: - Kopie z okresu wersji 1.0.0

    /// Kopie od najstarszej do pierwszej zrobionej przy zapisie z listą zmian dla iCloud (włącznie).
    /// `closed` – czy okres się skończył (był już zapis z listą zmian).
    static func chain(backups: [URL], log: String?) -> (urls: [URL], closed: Bool) {
        let sorted = backups
            .filter { $0.pathExtension == "plist" && !$0.lastPathComponent.hasPrefix("TEST") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let cutoff = firstSyncedBackupName(log: log) else { return (sorted, false) }
        return (sorted.filter { $0.lastPathComponent <= cutoff }, true)
    }

    /// Nazwa kopii zrobionej przy pierwszym zapisie, który dopisał zmiany dla iCloud.
    static func firstSyncedBackupName(log: String?) -> String? {
        guard let log else { return nil }
        var seen = false
        for line in log.split(separator: "\n") {
            if line.contains("iCloud changes:") { seen = true; continue }
            if seen, let r = line.range(of: "backup: ") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    static func date(ofBackup url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = name.range(of: #"\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.date(from: String(name[r]))
    }

    // MARK: - Plan

    /// `states` – kopie z okresu 1.0.0 (od najstarszej), gdy okres trwa do dziś – zakończone obecnym stanem.
    static func plan(states: [NSDictionary], current: NSDictionary) -> Plan {
        var plan = Plan()
        guard let first = states.first else { return plan }

        // Przeniesienia, kolejność, nazwy: jak przy zwykłym zapisie, od stanu sprzed pierwszego zapisu.
        for e in SyncChanges.changes(from: first, to: current) where e["Type"] as? String == "Modify" {
            plan.entries.append(e)
            if e["IsMove"] as? Bool == true { plan.moved += 1 } else { plan.renamed += 1 }
        }

        // Usunięcia: między kolejnymi kopiami, nieobecne dziś.
        let now = SyncChanges.index(current)
        var done: Set<String> = []
        for (a, b) in zip(states, states.dropFirst()) {
            let before = SyncChanges.index(a)
            let after = SyncChanges.index(b)
            var fixed: Set<String> = []
            if let r = a["WebBookmarkUUID"] as? String { fixed.insert(r) }
            for c in a["Children"] as? [NSDictionary] ?? [] {
                if let u = c["WebBookmarkUUID"] as? String { fixed.insert(u) }
            }
            let gone = Set(before.order.filter { after.places[$0] == nil && now.places[$0] == nil && !fixed.contains($0) })
            for uuid in before.postOrder where gone.contains(uuid) && !done.contains(uuid) {
                guard let place = before.places[uuid], let type = SyncChanges.bookmarkType(place.node) else { continue }
                var extra: [String: Any] = [:]
                if let data = (place.node["Sync"] as? NSDictionary)?["Data"] { extra["DeletedBookmarkSyncData"] = data }
                plan.entries.append(SyncChanges.entry(type: "Delete", bookmarkType: type, node: place.node, extra: extra))
                plan.deletedEntries += 1
                done.insert(uuid)
                // Do podsumowania: tylko element, którego folder nie zniknął razem z nim.
                if let parent = place.parent, gone.contains(parent) { continue }
                // Zakładki, które naprawdę zniknęły (część mogła być wcześniej przeniesiona gdzie indziej).
                let leaves = goneLeaves(in: place.node, gone: gone)
                plan.deleted.append((title(place.node), leaves, type == "Folder"))
            }
        }
        return plan
    }

    private static func goneLeaves(in node: NSDictionary, gone: Set<String>) -> Int {
        let own = node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf"
            && (node["WebBookmarkUUID"] as? String).map(gone.contains) == true ? 1 : 0
        return own + (node["Children"] as? [NSDictionary] ?? []).reduce(0) { $0 + goneLeaves(in: $1, gone: gone) }
    }

    private static func title(_ node: NSDictionary) -> String {
        if let t = node["Title"] as? String, !t.isEmpty { return t }
        if let t = (node["URIDictionary"] as? NSDictionary)?["title"] as? String, !t.isEmpty { return t }
        return node["URLString"] as? String ?? "?"
    }
}
