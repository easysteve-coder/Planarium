/// Eine bewusst getroffene, typisierte Zieladresse für ein einzelnes
/// Host→Scanner-Telegramm — niemals eine beobachtete RX-Adresse
/// übernommen (analog zu `pls_control.ConfirmedTargetAddress`,
/// `SICK Doku/active-control-roadmap.md` Abschnitt 3.1: „Ein Typ, der
/// die Zieladresse als bewusste, typisierte Entscheidung erzwingt, nicht
/// als stillschweigenden Default").
///
/// SICK-011-Auftrag: „typisierte explizite Zieladresse (universell 0 als
/// dokumentierter Default, keine RX-Adresse ableiten)". Das ist hier
/// zweifach umgesetzt: `wire-protocol.md` Abschnitt 1 dokumentiert
/// Adresse `0` als „empfohlene" Universaladresse — als einziger
/// vordefinierter Wert dieses Typs (``universal``), aber weiterhin als
/// bewusster, benannter Aufruf statt eines impliziten Parameter-Defaults
/// tief in einer Funktionssignatur. Und der fehlschlagbare
/// ``init(rawValue:)`` lehnt `0x81` strukturell ab — das ist in jeder
/// realen Beobachtung ausschließlich die Scanner→Host-Antwortadresse
/// (`wire-protocol.md` Abschnitt 2), niemals ein gültiges Ziel für ein
/// Host→Scanner-Telegramm. Ein Aufrufer, der versehentlich eine
/// beobachtete RX-Adresse als Sendeziel wiederverwendet, scheitert damit
/// schon bei der Konstruktion, nicht erst am realen Port.
public struct ConfirmedTargetAddress: Equatable, Sendable {
    public let rawValue: UInt8

    /// `wire-protocol.md` Abschnitt 1: „Universaladresse 0 empfohlen".
    public static let universal = ConfirmedTargetAddress(uncheckedRawValue: 0x00)

    private init(uncheckedRawValue: UInt8) {
        self.rawValue = uncheckedRawValue
    }

    /// Für jede andere, ebenfalls bewusst gewählte Adresse
    /// (`wire-protocol.md` Abschnitt 1: Einzeladressen 1–99 möglich).
    /// `nil`, wenn `rawValue == 0x81` (Scanner-Antwortadresse, siehe
    /// Kopfkommentar).
    public init?(rawValue: UInt8) {
        guard rawValue != 0x81 else { return nil }
        self.init(uncheckedRawValue: rawValue)
    }
}
