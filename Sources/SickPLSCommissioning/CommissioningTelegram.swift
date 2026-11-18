import SickPLSActiveControl
import SickPLSCore

/// Die Encoder der vier Konfigurationstelegramme (SICK-030a).
///
/// **Alles läuft über den bestehenden Framevertrag.** `Frame.build`
/// rechnet Adresse, Länge und Prüfsumme; hier entsteht ausschließlich
/// der Payload. Es gibt keine zweite Rahmen- oder CRC-Implementierung
/// und keine hart kodierten Prüfwerte aus der Dokumentation — ein aus
/// der Doku abgeschriebener fertiger Frame wäre nicht nur ein
/// Geheimnisleck (Auflage A5), er würde auch stillschweigend an
/// `SickCRC16` vorbei gehen.
///
/// **Diese Typen senden nichts.** Sie öffnen keinen Port und kennen
/// keinen. Die I/O-Schleife entsteht erst in SICK-031.
public enum CommissioningTelegram {

    /// Die harmlose Identitätsprobe — unverändert die aus SICK-011.
    ///
    /// Bewusst **keine eigene Implementierung**: Es gibt im Projekt
    /// genau einen Identitätsprobe-Vertrag, und der ist real belegt.
    public static func identityRequest(address: ConfirmedTargetAddress) -> Frame {
        IdentityProbe.requestFrame(address: address)
    }

    /// Schaltet über die allgemeine Adresse in den belegten
    /// Einstellungsmodus, bevor der adressierte Login erfolgt.
    public static func settingsMode(secret: InstallationSecret, recipe: CommissioningRecipe) -> Frame {
        settingsMode(secret: secret, recipe: recipe, address: recipe.settingsModeAddress)
    }

    /// Variante für das ausdrücklich bediente Diagnosewerkzeug. Der
    /// Produktablauf bleibt an das geschlossene Rezept gebunden; nur die
    /// Handkonsole darf die bewusst gewählte Zieladresse einsetzen.
    public static func settingsMode(
        secret: InstallationSecret,
        recipe: CommissioningRecipe,
        address: ConfirmedTargetAddress
    ) -> Frame {
        let payload = secret.withBytes { secretBytes in
            [recipe.configurationCommandByte, recipe.settingsModeByte] + secretBytes
        }
        return try! Frame.build(address: address.rawValue, payload: payload)
    }

    /// Das Login-Telegramm: Kommandobyte, Modusbyte, Geheimnisfeld.
    ///
    /// Das Geheimnis wird **nur hier** in Bytes umgesetzt und verlässt
    /// diesen Aufruf ausschließlich als Teil des fertigen Frames. Weder
    /// der Rückgabewert noch das Audit noch eine Fehlermeldung tragen es
    /// in lesbarer Form (Auflage A5, siehe ``CommissioningRedaction``).
    ///
    /// Der Payload hat feste Länge (zwei Bytes plus
    /// ``InstallationSecret/requiredByteCount``) und liegt damit
    /// strukturell weit unter der Frame-Obergrenze — `Frame.build` kann
    /// hier nicht fehlschlagen, dieselbe Lage wie bei
    /// `IdentityProbe.requestFrame`.
    public static func login(secret: InstallationSecret, recipe: CommissioningRecipe) -> Frame {
        login(secret: secret, recipe: recipe, address: recipe.configurationAddress)
    }

    public static func login(
        secret: InstallationSecret,
        recipe: CommissioningRecipe,
        address: ConfirmedTargetAddress
    ) -> Frame {
        let payload = secret.withBytes { secretBytes in
            [recipe.configurationCommandByte, recipe.loginModeByte] + secretBytes
        }
        return try! Frame.build(address: address.rawValue, payload: payload)
    }

    /// Das Baudwechsel-Telegramm.
    ///
    /// Geht an **dieselbe** Adresse wie das Login — die Kopplung steht in
    /// ``CommissioningRecipe``, nicht in einem Parameter dieser
    /// Funktion, damit sie nicht je Aufrufstelle neu entschieden werden
    /// kann.
    public static func baudSwitch(recipe: CommissioningRecipe) -> Frame {
        baudSwitch(recipe: recipe, address: recipe.configurationAddress)
    }

    public static func baudSwitch(
        recipe: CommissioningRecipe,
        address: ConfirmedTargetAddress
    ) -> Frame {
        try! Frame.build(
            address: address.rawValue,
            payload: [recipe.configurationCommandByte, recipe.baudSwitchModeByte]
        )
    }

    /// Das **experimentelle** Messmodus-Telegramm.
    ///
    /// Strukturell identisch zum Baudwechsel, fachlich deutlich
    /// schwächer belegt — siehe
    /// ``CommissioningRecipe/measurementModeByte``. Der Ablauf hält den
    /// Schritt deshalb getrennt und kennzeichnet ihn.
    public static func measurementMode(recipe: CommissioningRecipe) -> Frame {
        measurementMode(recipe: recipe, address: recipe.configurationAddress)
    }

    public static func measurementMode(
        recipe: CommissioningRecipe,
        address: ConfirmedTargetAddress
    ) -> Frame {
        try! Frame.build(
            address: address.rawValue,
            payload: [recipe.configurationCommandByte, recipe.measurementModeByte]
        )
    }
}
