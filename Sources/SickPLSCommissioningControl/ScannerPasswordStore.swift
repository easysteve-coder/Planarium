import Foundation

/// Wo das **Scanner-Passwort** liegt (SICK-032a2).
///
/// ## Eine normale Geräteeinstellung
///
/// Owner-Entscheidung zu diesem Slice: Das Scanner-Passwort ist **keine
/// besondere Geheimnissache**, sondern eine unkritische Einstellung wie
/// der Anschluss oder die Baudrate. Es wird deshalb in den **normalen
/// App-Einstellungen** abgelegt, im Klartext angezeigt und ist jederzeit
/// direkt bearbeitbar.
///
/// **Bewusst nicht gebaut:** kein Schlüsselbund, keine Maskierung, kein
/// „Anzeigen"-Klick, keine Redigierung, kein eigener Wertetyp mit
/// abgeschalteter Beschreibung. Eine frühere Fassung dieses Slices hatte
/// das alles — es war überzogen und ist auf ausdrückliche Korrektur
/// wieder entfallen.
///
/// **Die einzige verbliebene Zurückhaltung:** Das Passwort wird nicht
/// absichtlich in Diagnosen, Protokolle oder Fehlertexte geschrieben,
/// weil es dort keinen Bediennutzen hat — genauso wenig wie jede andere
/// Einstellung, die niemand im Protokoll sucht.
public protocol ScannerPasswordStoring: AnyObject {

    /// Das hinterlegte Passwort. Leerer Text heißt: keines hinterlegt.
    func load() -> String

    /// Legt das Passwort ab und ersetzt ein vorhandenes.
    func save(_ password: String)

    /// Löscht das Passwort.
    func forget()
}

/// Die produktive Ablage: die **normalen App-Einstellungen**.
///
/// `UserDefaults` ist genau der dafür vorgesehene Ort — dieselbe Ablage,
/// in der auch jede andere Einstellung einer Mac-App landet.
public final class UserDefaultsScannerPasswordStore: ScannerPasswordStoring {

    /// Der Einstellungsschlüssel. **Nicht ändern** — ein anderer Wert
    /// macht ein bereits hinterlegtes Passwort unsichtbar, ohne es zu
    /// löschen.
    public static let defaultsKey = "de.sick.pls.scannerPassword"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> String {
        defaults.string(forKey: Self.defaultsKey) ?? ""
    }

    public func save(_ password: String) {
        defaults.set(password, forKey: Self.defaultsKey)
    }

    public func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
