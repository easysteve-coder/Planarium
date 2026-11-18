import SickPLSCore
@testable import SickPLSCommissioning

// Gemeinsame Testgrundlage für `SickPLSCommissioning`.
//
// **Kein Port, kein Gerät, keine Uhr, kein TX.** Der Reducer bekommt
// seine Zeitpunkte gesetzt, nie gemessen; es wird nichts geöffnet und
// nichts gesendet.
//
// **Das Geheimnis aus der technischen Dokumentation kommt hier nirgends
// vor** (Auflage A5). Alle Tests verwenden `testSecret` — einen Wert,
// der mit dem echten nichts zu tun hat und deshalb im Quelltext stehen
// darf. `SecretLeakRuleTests` prüft automatisch, dass das so bleibt.

/// Acht Bytes, frei erfunden. Genau die geforderte Länge, damit der Typ
/// ihn annimmt.
let testSecretBytes: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]

var testSecret: InstallationSecret {
    InstallationSecret(bytes: testSecretBytes)!
}

/// Baut eine Bestätigungsantwort, wie das Gerät sie schicken würde —
/// über den echten Framevertrag, nicht als abgeschriebene Bytefolge.
func acknowledgementFrame(
    status: UInt8?,
    commandByte: UInt8 = AcknowledgementClassifier.responseCommandByte,
    thirdByte: UInt8? = 0x00
) -> Frame {
    var payload = [commandByte]
    if let status { payload.append(status) }
    if let thirdByte, status != nil { payload.append(thirdByte) }
    return try! Frame.build(address: 0x81, payload: payload)
}

/// Ein autonomer Scanprofil-Broadcast — das bekannte Umgebungsrauschen.
func scanProfileFrame() -> Frame {
    try! Frame.build(
        address: 0x81,
        payload: [0xB0, 90, 0] + Array(repeating: [UInt8(100), UInt8(0)], count: 90).flatMap { $0 } + [0]
    )
}

/// Führt den Reducer durch den gesamten erfolgreichen Umschaltweg bis
/// einschließlich der Verifikation und gibt jede unterwegs erzeugte
/// Anweisung zurück.
@discardableResult
func runSuccessfulSwitch(_ model: inout CommissioningModel) -> [CommissioningDirective] {
    var directives: [CommissioningDirective] = []
    directives.append(model.apply(.operatorRequestedStartingRateCheck, atMillis: 1_000))
    directives.append(model.apply(.identityOutcome(.identified), atMillis: 1_100))
    directives.append(model.apply(.operatorRequestedBaudSwitch(secretIsAvailable: true), atMillis: 2_000))
    directives.append(model.apply(.acknowledgement(.acknowledged), atMillis: 2_000))
    // Die ersten beiden Login-Versuche bleiben unbeantwortet -- genau
    // der in den Windows-Mitschnitten belegte Fall. Der dritte wird
    // bestaetigt.
    directives.append(model.apply(.deadlineReached, atMillis: 4_000))
    directives.append(model.apply(.deadlineReached, atMillis: 6_000))
    directives.append(model.apply(.acknowledgement(.acknowledged), atMillis: 6_150))
    directives.append(model.apply(.acknowledgement(.acknowledged), atMillis: 6_300))
    directives.append(model.apply(.portClosed, atMillis: 6_400))
    directives.append(model.apply(.portOpened(model.recipe.targetBaudRate), atMillis: 6_500))
    directives.append(model.apply(.identityOutcome(.identified), atMillis: 6_650))
    return directives
}
