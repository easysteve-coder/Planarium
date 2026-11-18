import Combine
import SickPLSCommissioning

/// Ob das hinterlegte Scanner-Passwort für die Einrichtung taugt.
///
/// **Es hindert niemanden am Speichern.** Eine Einstellung darf
/// zwischendurch unfertig sein; die Rückmeldung sagt nur, ob sie beim
/// Umschalten schon benutzbar wäre.
public enum ScannerPasswordUsability: Equatable {
    /// Es ist keines eingetragen.
    case notSet
    /// Eingetragen, aber nicht in der Form, die das Gerät erwartet.
    case unusable
    /// Eingetragen und benutzbar.
    case usable
}

/// Die Einstellungsseite für das **Scanner-Passwort** (SICK-032a2).
///
/// ## Eine gewöhnliche Einstellung, mehr nicht
///
/// Der Wert steht im Klartext da, ist jederzeit direkt bearbeitbar und
/// wird beim Tippen gespeichert. **Kein Maskieren, kein „Anzeigen",
/// keine Bestätigung, kein Schlüsselbund** — das war eine frühere,
/// überzogene Fassung dieses Slices und ist auf Owner-Korrektur
/// entfallen.
///
/// Dieses Modell **verwaltet nur die Einstellung**. Es kennt keinen
/// Anschluss, keinen Ablauf und keinen Transport; es sendet nichts,
/// öffnet nichts und startet nichts. Die Einrichtung holt sich den Wert
/// später selbst aus derselben Ablage — beide Modelle teilen sich
/// **einen** ``ScannerPasswordStoring``, nicht einen
/// zwischengespeicherten Wert.
///
/// ## Threadvertrag
///
/// Kontroll-Thread (in der App der Main Thread), wie alle
/// `ObservableObject` dieses Projekts.
public final class ScannerPasswordSettingsModel: ObservableObject {

    /// Der Text, wie er im Einstellungsfeld steht. **Schreibbar** — die
    /// Ansicht bindet direkt daran.
    @Published public var password: String {
        didSet {
            guard password != oldValue else { return }
            // **Nur Eingaben schreiben zurück.** Wenn dieses Modell das
            // Feld selbst angleicht -- nach `forget()` oder `refresh()`
            // --, wäre ein Rückschreiben falsch: Nach dem Löschen legte
            // es prompt wieder einen (leeren) Eintrag an.
            guard !isSyncingFromStore else { return }
            store.save(password)
        }
    }

    /// Ob gerade das Modell selbst das Feld setzt (siehe `didSet`).
    private var isSyncingFromStore = false

    /// Ob der aktuelle Eintrag beim Umschalten benutzbar wäre.
    public var usability: ScannerPasswordUsability {
        Self.usability(of: password)
    }

    /// Ein kurzer, im Modell formulierter Hinweis — nie in der Ansicht
    /// getextet (Regel aus SICK-028/030a1).
    public var hint: String {
        switch usability {
        case .notSet:
            return "No scanner password entered. It is required to reconfigure the scanner."
        case .unusable:
            return "This scanner password does not yet match the device requirements."
        case .usable:
            return "Valid. Scanner setup uses it automatically."
        }
    }

    private let store: ScannerPasswordStoring

    public init(store: ScannerPasswordStoring) {
        self.store = store
        self.password = store.load()
    }

    /// Liest den gespeicherten Wert neu ein.
    public func refresh() {
        let stored = store.load()
        guard stored != password else { return }
        isSyncingFromStore = true
        password = stored
        isSyncingFromStore = false
    }

    /// Löscht das Passwort — Feld **und** Ablage.
    public func forget() {
        store.forget()
        guard password != "" else { return }
        // Ohne diese Klammer schriebe `didSet` sofort wieder einen
        // (leeren) Eintrag in die Einstellungen -- das Löschen wäre
        // dann keines.
        isSyncingFromStore = true
        password = ""
        isSyncingFromStore = false
    }

    /// Ob ein Text beim Umschalten benutzbar wäre.
    ///
    /// **Die Prüfung ist die von `InstallationSecret`** — es gibt keine
    /// zweite Vorstellung davon, was das Gerät akzeptiert.
    public static func usability(of text: String) -> ScannerPasswordUsability {
        if text.isEmpty { return .notSet }
        return InstallationSecret(text: text) == nil ? .unusable : .usable
    }
}
