import AppKit
import Foundation

enum FileError: LocalizedError {
    case noPermission(URL)
    case notABookmarksFile
    case backupMismatch
    case safariClosed
    case changedOutside
    case writeMismatch

    var errorDescription: String? {
        switch self {
        case .noPermission: L("Aplikacja nie ma dostępu do zakładek Safari. Daj jej Pełny dostęp do dysku w Ustawieniach systemowych.", "The app has no access to Safari bookmarks. Give it Full Disk Access in System Settings.")
        case .notABookmarksFile: L("To nie jest plik zakładek Safari.", "This is not a Safari bookmarks file.")
        case .backupMismatch: L("Kopia nie wyszła poprawnie. Nic nie zapisano.", "The backup did not come out right. Nothing was saved.")
        case .safariClosed: L("Safari jest zamknięte. Otwórz Safari i zapisz jeszcze raz.", "Safari is closed. Open Safari and save again.")
        case .changedOutside: L("Zakładki zmieniły się w międzyczasie (w Safari albo przez iCloud). Nic nie zapisano. Wczytaj zakładki ponownie (⌘R) i powtórz zmiany.", "The bookmarks changed in the meantime (in Safari or through iCloud). Nothing was saved. Reload the bookmarks (⌘R) and make your changes again.")
        case .writeMismatch: L("Po zapisie plik wygląda inaczej, niż powinien. Sprawdź zakładki, w razie potrzeby przywróć kopię.", "After saving, the file does not look as it should. Check your bookmarks and restore a backup if needed.")
        }
    }
}

enum BookmarksFile {
    static let safariURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Safari/Bookmarks.plist")

    /// Plik do pracy. Argument `-BookmarksFile <ścieżka>` pozwala pracować na kopii (bez ruszania Safari).
    static var configuredURL: URL {
        if let path = UserDefaults.standard.string(forKey: "BookmarksFile"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return safariURL
    }

    static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw FileError.noPermission(url)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            throw FileError.noPermission(url)
        }
    }

    static func parseMutable(_ data: Data) throws -> NSMutableDictionary {
        let plist = try PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)
        guard let dict = plist as? NSMutableDictionary, dict["Children"] is NSArray else {
            throw FileError.notABookmarksFile
        }
        return dict
    }

    static func serialize(_ root: NSDictionary) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// Atomowa podmiana: zapis do pliku tymczasowego na tym samym dysku, potem replaceItemAt
    /// (zachowuje uprawnienia i atrybuty oryginału).
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fm.removeItem(at: tempDir) }
        let temp = tempDir.appending(path: url.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
    }
}

// MARK: - Kopie zapasowe

struct Backup: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int
    var id: URL { url }
}

enum Backups {
    static var directory: URL {
        if let path = UserDefaults.standard.string(forKey: "BackupsDirectory"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Safari Bookmarks", directoryHint: .isDirectory)
        let dir = base.appending(path: "Backups", directoryHint: .isDirectory)
        // Wcześniejsze wersje trzymały kopie w „Kopie”.
        let old = base.appending(path: "Kopie", directoryHint: .isDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: dir)
        }
        return dir
    }

    /// Zapisuje kopię i sprawdza, czy na dysku jest dokładnie to samo.
    static func make(from data: Data, testMode: Bool) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = (testMode ? "TEST " : "") + "Bookmarks \(f.string(from: .now)).plist"
        let url = directory.appending(path: name)
        try data.write(to: url, options: .withoutOverwriting)
        guard try Data(contentsOf: url) == data else { throw FileError.backupMismatch }
        return url
    }

    static func list() -> [Backup] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "plist" }.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Backup(url: url, date: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0)
        }
        .sorted { $0.date > $1.date }
    }
}

// MARK: - Safari

enum SafariControl {
    static let bundleID = "com.apple.Safari"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func launch() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
