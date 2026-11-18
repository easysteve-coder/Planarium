import SickPLSCore

/// Das für die Klangerzeugung verwertbare Ergebnis **eines
/// abgeschlossenen Lesevorgangs** (SICK-029).
///
/// ## Warum genau ein Profil und nicht eine Serie
///
/// Ein einzelner Lesevorgang kann mehrere B0-Frames enthalten. Für die
/// Performance wird daraus **nur das letzte** verwendet — und das ist
/// keine willkürliche Datenvernichtung, sondern die einzige ehrliche
/// Wahl mit dem, was der Transport heute liefert: **Für die früheren
/// Profile gibt es keine belastbaren Einzelzeitstempel.** Sie mit
/// ausgedachten Mikrosekundenabständen in die Bewegungsprognose zu
/// drücken wäre Scheingenauigkeit und würde deren geschätzte
/// Geschwindigkeit verfälschen — also genau das Signal beschädigen, das
/// zwischen zwei echten Profilen den Ton trägt.
///
/// Deshalb trägt dieser Typ **das aktuelle, verwertbare Profil**, nicht
/// eine angeblich zeitlich geordnete Serie. ``profileCountInRead`` macht
/// sichtbar, wie viele es waren, ohne etwas über ihre zeitliche Lage zu
/// behaupten.
///
/// **Die Monitoranzeige ist davon unberührt:** `ScanSessionState`
/// verarbeitet weiterhin jedes decodierte Profil (Diagnose, Punktzahl,
/// Profilrate).
///
/// ## Was hier nie hineingehört
///
/// **Keine Rohframes, keine Bytes, kein `Date`.** Die Empfangszeit ist
/// Wanduhrzeit; sie ist Monitorzustand und darf die Laufzeitbrücke nie
/// erreichen. Die Steuerzeit vergibt allein die monotone Zeitleiste des
/// Performance-Controllers.
public struct ScanProfileBatch: Equatable {
    /// Das letzte decodierte B0-Profil dieses Lesevorgangs.
    public let profile: B0ScanProfile

    /// Wie viele gültige B0-Profile dieser eine Lesevorgang enthielt —
    /// immer mindestens `1`, sonst entstünde gar kein Ereignis.
    ///
    /// Rein informativ. **Kein Zeitindex und keine Reihenfolgeangabe:**
    /// Ein Wert über `1` heißt „in diesem Lesevorgang lagen mehrere
    /// Profile, und die früheren sind für die Klangerzeugung verworfen",
    /// mehr nicht.
    public let profileCountInRead: Int

    /// Monotone Zeit direkt nach dem Lesevorgang, der dieses Profil geliefert
    /// hat.
    public let receivedAtMonotonic: Double

    /// **Bewusst nicht öffentlich** (SICK-029a, Review-Befund N1 aus
    /// `review-sick-029.md`).
    ///
    /// Der Typ ist für Combine-Abonnenten öffentlich **lesbar**, aber
    /// ein Batch entsteht ausschließlich in ``ScanSession`` — und dort
    /// erst, nachdem `profiles.last` einen Wert geliefert hat.
    /// ``profileCountInRead`` ist damit **strukturell** mindestens `1`;
    /// die Invariante hängt nicht an einer Prüfung, sondern daran, dass
    /// es außerhalb dieses Moduls gar keine Entstehungsstelle gibt.
    ///
    /// **Bewusst keine validierende Fabrik** (anders als bei
    /// `Frame.build`/`Zone.build`/`ThereminGateEvent.build`): Ein Batch
    /// **ist** das Ergebnis eines Lesevorgangs. Außerhalb von
    /// ``ScanSession`` hat er keine fachliche Herkunft, also braucht es
    /// auch keinen zweiten Weg, ihn zu bauen — und ohne zweiten Weg
    /// gibt es nichts zu validieren.
    init(profile: B0ScanProfile, profileCountInRead: Int, receivedAtMonotonic: Double) {
        self.profile = profile
        self.profileCountInRead = profileCountInRead
        self.receivedAtMonotonic = receivedAtMonotonic
    }

    init(profile: B0ScanProfile, profileCountInRead: Int) {
        self.init(profile: profile, profileCountInRead: profileCountInRead, receivedAtMonotonic: 0)
    }

    /// `true`, wenn dieser Lesevorgang mehr als ein Profil enthielt und
    /// damit frühere Profile für die Klangerzeugung verworfen wurden.
    public var didDropEarlierProfiles: Bool { profileCountInRead > 1 }
}
