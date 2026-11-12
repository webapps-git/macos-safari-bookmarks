import Foundation

/// Dwa języki: polski, gdy macOS wybierze dla aplikacji polski, w każdym innym przypadku angielski.
/// macOS bierze z listy języków systemu pierwszy, który aplikacja zna (pl.lproj, en.lproj);
/// gdy nie zna żadnego – angielski (język bazowy projektu). Systemowe menu działa tak samo.
nonisolated enum AppLanguage {
    static let isPolish = Bundle.main.preferredLocalizations.first == "pl"
    static var locale: Locale { Locale(identifier: isPolish ? "pl_PL" : "en_US") }
}

/// Tekst w języku aplikacji: `L("polski", "English")`.
nonisolated func L(_ polish: String, _ english: String) -> String {
    AppLanguage.isPolish ? polish : english
}
