/// Das Installationsgeheimnis für das Login-Telegramm des
/// Commissioning-Ablaufs (SICK-030a, Auflage **A5** aus
/// `review-sick-030-architecture.md`).
///
/// ## Was dieser Typ zusichert — und was nicht
///
/// **Zugesichert:** Der Wert ist nicht serialisierbar, nicht
/// beobachtbar und erscheint in keiner Text- oder Debugausgabe. Er
/// entsteht ausschließlich aus einer Eingabe des Bedieners und lebt nur
/// so lange, wie ein Ablauf ihn hält.
///
/// **Nicht zugesichert:** Swift kann Speicher nicht zuverlässig nullen
/// — ein `[UInt8]` kann kopiert, verschoben und ausgelagert werden,
/// ohne dass dieser Typ davon erfährt. Das hier ist eine
/// **Nicht-Persistenz-Zusage, keine Zeroing-Zusage.** Wer mehr braucht,
/// braucht eine andere Sprache oder den Schlüsselbund; beides ist
/// ausdrücklich nicht Teil dieses Slices.
///
/// ## Warum es trotzdem eine `description` gibt
///
/// Der Auftrag verlangt „keine `description`/Debug-Ausgabe". Wörtlich
/// umgesetzt wäre das **unsicherer**: Ein Swift-`struct` ohne
/// ``CustomStringConvertible`` bekommt von `String(describing:)` und
/// `dump()` eine **spiegelbasierte** Ausgabe — und die druckt das
/// Byte-Array aus. Eine eigene, redigierte Ausgabe ist der einzige Weg,
/// diesen Pfad zu schließen; ``customMirror`` schließt zusätzlich
/// `dump()` und jede andere Reflexion.
///
/// **Der Wert aus `SICK Doku/integration/` wird nirgends im Projekt
/// transkribiert** — nicht in Code, Tests, Fixtures, Testnamen,
/// Kommentaren, Handoffs oder Logs. Tests verwenden ein
/// Testgeheimnis; `SecretLeakRuleTests` prüft das automatisch.
public struct InstallationSecret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// Das Geheimnisfeld des Login-Telegramms ist ein Feld fester Länge
    /// (`SICK Doku/integration/active-sequences.md`, Schritt 2). Ein
    /// kürzerer oder längerer Wert ergäbe einen Frame anderer Länge und
    /// damit ein anderes Telegramm — deshalb ein harter Fehler statt
    /// einer stillen Auffüllung oder Kürzung.
    public static let requiredByteCount = 8

    private let bytes: [UInt8]

    /// `nil`, wenn die Länge nicht exakt ``requiredByteCount`` ist —
    /// **keine stille Korrektur** (Hausmuster wie `Frame.build`).
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.requiredByteCount else { return nil }
        self.bytes = bytes
    }

    /// Die Bedienereingabe ist Text; maßgeblich sind aber die Bytes.
    /// `nil`, wenn die UTF-8-Darstellung nicht exakt
    /// ``requiredByteCount`` Bytes ergibt (ein Umlaut zählt zwei).
    public init?(text: String) {
        self.init(bytes: Array(text.utf8))
    }

    /// Der **einzige** Weg an die Bytes — bewusst mit begrenztem
    /// Gültigkeitsbereich statt als Eigenschaft, damit eine Kopie eine
    /// sichtbare Entscheidung ist und nicht nebenbei entsteht.
    ///
    /// Modulintern: Außerhalb von `SickPLSCommissioning` gibt es keinen
    /// Zugriff auf den Inhalt. Die Encoder und die inhaltsbasierte
    /// Redaktion liegen in diesem Modul.
    func withBytes<R>(_ body: ([UInt8]) -> R) -> R {
        body(bytes)
    }

    public var description: String { "InstallationSecret(redigiert)" }
    public var debugDescription: String { description }
    /// Leerer Spiegel: `dump()` und jede andere Reflexion sehen keine
    /// Kinder und damit keine Bytes.
    public var customMirror: Mirror { Mirror(self, children: []) }
}
