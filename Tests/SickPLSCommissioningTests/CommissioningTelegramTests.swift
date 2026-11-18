import XCTest
import SickPLSActiveControl
import SickPLSCore
@testable import SickPLSCommissioning

/// Encoder und **inhaltsbasierte** Redaktion, jeweils mit einem
/// Testgeheimnis (Auflage A5).
final class CommissioningTelegramTests: XCTestCase {

    private let recipe = CommissioningRecipe.r26

    // MARK: - Encoder

    func testCommissioningAddressesUseMixedAddressing() {
        let settings = CommissioningTelegram.settingsMode(secret: testSecret, recipe: recipe)
        let login = CommissioningTelegram.login(secret: testSecret, recipe: recipe)

        XCTAssertEqual(settings.address, recipe.settingsModeAddress.rawValue)
        XCTAssertEqual(settings.address, 0x00)
        XCTAssertEqual(settings.payload.first, recipe.configurationCommandByte)
        XCTAssertEqual(settings.payload.dropFirst().first, recipe.settingsModeByte)
        XCTAssertEqual(settings.payload.count, 2 + InstallationSecret.requiredByteCount)
        XCTAssertEqual(login.address, recipe.configurationAddress.rawValue)
        XCTAssertEqual(login.address, 0x01)
        XCTAssertNotEqual(settings.address, login.address)
        XCTAssertNotEqual(settings.payload[1], login.payload[1])
    }

    /// Der Login-Frame entsteht **über den bestehenden Framevertrag** —
    /// also mit gerechneter Länge und gerechneter Prüfsumme, nicht als
    /// abgeschriebene Bytefolge.
    func testTheLoginFrameIsBuiltThroughTheFrameContract() {
        let frame = CommissioningTelegram.login(secret: testSecret, recipe: recipe)

        XCTAssertEqual(frame.address, recipe.configurationAddress.rawValue)
        XCTAssertEqual(frame.payload.first, recipe.configurationCommandByte)
        XCTAssertEqual(frame.payload.dropFirst().first, recipe.loginModeByte)
        XCTAssertEqual(frame.payload.count, 2 + InstallationSecret.requiredByteCount)
        // Gegenprobe gegen eine hart kodierte Prüfsumme: Der Frame lässt
        // sich mit dem echten Decoder wieder einlesen.
        guard case .success(let decoded) = Frame.decodeExact(from: frame.encoded()) else {
            return XCTFail("Der eigene Decoder liest den gebauten Frame nicht wieder ein")
        }
        XCTAssertEqual(decoded.payload, frame.payload)
        XCTAssertEqual(decoded.address, frame.address)
    }

    func testTheBaudSwitchFrameTargetsTheSameAddressAsTheLogin() {
        let login = CommissioningTelegram.login(secret: testSecret, recipe: recipe)
        let baud = CommissioningTelegram.baudSwitch(recipe: recipe)
        XCTAssertEqual(baud.address, login.address)
        XCTAssertEqual(baud.payload, [recipe.configurationCommandByte, recipe.baudSwitchModeByte])
    }

    func testTheMeasurementModeFrameDiffersOnlyInItsModeByte() {
        let baud = CommissioningTelegram.baudSwitch(recipe: recipe)
        let measurement = CommissioningTelegram.measurementMode(recipe: recipe)
        XCTAssertEqual(measurement.address, baud.address)
        XCTAssertEqual(measurement.payload.first, baud.payload.first)
        XCTAssertNotEqual(measurement.payload[1], baud.payload[1])
    }

    func testDiagnosticVariantsUseTheExplicitlySelectedAddress() {
        let address = ConfirmedTargetAddress(rawValue: 0x2A)!

        XCTAssertEqual(
            CommissioningTelegram.settingsMode(secret: testSecret, recipe: recipe, address: address).address,
            0x2A
        )
        XCTAssertEqual(
            CommissioningTelegram.login(secret: testSecret, recipe: recipe, address: address).address,
            0x2A
        )
        XCTAssertEqual(CommissioningTelegram.baudSwitch(recipe: recipe, address: address).address, 0x2A)
        XCTAssertEqual(CommissioningTelegram.measurementMode(recipe: recipe, address: address).address, 0x2A)
    }

    /// Die Identitätsprobe ist **die aus SICK-011** und keine zweite
    /// Implementierung.
    func testTheIdentityRequestIsTheExistingOne() {
        let ours = CommissioningTelegram.identityRequest(address: recipe.verificationAddress)
        let theirs = IdentityProbe.requestFrame(address: recipe.verificationAddress)
        XCTAssertEqual(ours.address, theirs.address)
        XCTAssertEqual(ours.payload, theirs.payload)
    }

    /// Verschiedene Geheimnisse ergeben verschiedene Frames — der Wert
    /// wird also wirklich eingesetzt und nicht ignoriert.
    func testTheSecretActuallyReachesTheFrame() {
        let other = InstallationSecret(bytes: [0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22])!
        let a = CommissioningTelegram.login(secret: testSecret, recipe: recipe)
        let b = CommissioningTelegram.login(secret: other, recipe: recipe)
        XCTAssertNotEqual(a.payload, b.payload)
        XCTAssertEqual(a.payload.count, b.payload.count)
    }

    // MARK: - Der Geheimnistyp

    func testTheSecretRequiresExactlyTheDocumentedLength() {
        XCTAssertNil(InstallationSecret(bytes: Array(repeating: 0x41, count: 7)))
        XCTAssertNil(InstallationSecret(bytes: Array(repeating: 0x41, count: 9)))
        XCTAssertNil(InstallationSecret(bytes: []))
        XCTAssertNotNil(InstallationSecret(bytes: Array(repeating: 0x41, count: 8)))
    }

    func testTheSecretCountsBytesNotCharacters() {
        // Acht ASCII-Zeichen: acht Bytes.
        XCTAssertNotNil(InstallationSecret(text: "abcdefgh"))
        // Vier Umlaute: acht Bytes in UTF-8 -- der Typ zählt richtig.
        XCTAssertNotNil(InstallationSecret(text: "äöüß"))
        // Acht Umlaute wären sechzehn Bytes.
        XCTAssertNil(InstallationSecret(text: "ääääääää"))
    }

    /// **Kein Textausgabepfad zeigt das Geheimnis** — weder die
    /// Beschreibung noch die Spiegelung, auf der `dump()` aufbaut.
    func testNoTextOutputOfTheSecretRevealsItsBytes() {
        let secret = testSecret
        let renderings = [
            String(describing: secret),
            String(reflecting: secret),
            secret.description,
            secret.debugDescription
        ]
        for text in renderings {
            for byte in testSecretBytes {
                XCTAssertFalse(text.contains(String(byte)), "Dezimalwert eines Geheimnisbytes sichtbar: \(text)")
            }
            XCTAssertFalse(text.contains("0x11"), "Hexwert eines Geheimnisbytes sichtbar: \(text)")
        }
        XCTAssertTrue(Mirror(reflecting: secret).children.isEmpty, "dump() darf keine Kinder sehen")
    }

    /// Der Typ darf nicht serialisierbar sein — sonst landete er über
    /// irgendeinen `Codable`-Pfad in einer Datei.
    func testTheSecretIsNotCodable() throws {
        let source = try String(
            contentsOf: CommissioningSourcePaths.sources
                .appendingPathComponent("InstallationSecret.swift"),
            encoding: .utf8
        )
        for forbidden in ["Codable", "Encodable", "Decodable", "@Published"] {
            XCTAssertFalse(
                source.contains(": \(forbidden)") || source.contains(", \(forbidden)")
                    || source.contains("\(forbidden),"),
                "InstallationSecret darf \(forbidden) nicht annehmen"
            )
        }
    }

    // MARK: - Inhaltsbasierte Redaktion

    /// **Der Kern von Auflage A5:** Die Redaktion findet das Geheimnis
    /// an **jeder** Position — nicht nur dort, wo es im Login-Telegramm
    /// steht. Eine offset- oder modusbytebasierte Regel würde genau hier
    /// durchfallen.
    func testRedactionFindsTheSecretAtAnyPositionNotJustTheDocumentedOffset() {
        let atTheDocumentedPlace = CommissioningTelegram.login(secret: testSecret, recipe: recipe).payload
        let inSomeOtherBuffer = [0xDE, 0xAD] + testSecretBytes + [0xBE, 0xEF]
        let rightAtTheStart = testSecretBytes + [0x00]
        let rightAtTheEnd = [0x00] + testSecretBytes

        for bytes in [atTheDocumentedPlace, inSomeOtherBuffer, rightAtTheStart, rightAtTheEnd] {
            XCTAssertTrue(CommissioningRedaction.containsSecret(bytes, secret: testSecret))
            let redacted = CommissioningRedaction.redacting(bytes, secret: testSecret)
            XCTAssertFalse(
                CommissioningRedaction.containsSecret(redacted, secret: testSecret),
                "Nach der Redaktion darf das Geheimnis nicht mehr enthalten sein"
            )
            XCTAssertEqual(redacted.count, bytes.count, "Die Länge bleibt, damit nichts verraten wird")
        }
    }

    func testRedactionRemovesEveryOccurrence() {
        let bytes = testSecretBytes + [0x01] + testSecretBytes
        let redacted = CommissioningRedaction.redacting(bytes, secret: testSecret)
        XCTAssertFalse(CommissioningRedaction.containsSecret(redacted, secret: testSecret))
        XCTAssertEqual(redacted[InstallationSecret.requiredByteCount], 0x01, "Unbeteiligte Bytes bleiben")
    }

    func testRedactionLeavesUnrelatedBytesAlone() {
        let bytes: [UInt8] = [0x20, 0x40, 0x31, 0xB1]
        XCTAssertFalse(CommissioningRedaction.containsSecret(bytes, secret: testSecret))
        XCTAssertEqual(CommissioningRedaction.redacting(bytes, secret: testSecret), bytes)
    }

    /// Die Frame-Beschreibung nennt **gar keine** Payload-Bytes über das
    /// Kommandobyte hinaus — die Redaktion ist nur das Netz darunter.
    func testTheFrameDescriptionNeverPrintsPayloadBytes() {
        let text = CommissioningRedaction.describe(
            CommissioningTelegram.login(secret: testSecret, recipe: recipe)
        )
        for byte in testSecretBytes {
            XCTAssertFalse(text.contains(CommissioningRedaction.hex(byte)))
            XCTAssertFalse(text.contains(String(byte)))
        }
        // Struktur bleibt sichtbar: Adresse, Kommando, Länge.
        XCTAssertTrue(text.contains(CommissioningRedaction.hex(recipe.configurationAddress.rawValue)))
        XCTAssertTrue(text.contains(CommissioningRedaction.hex(recipe.configurationCommandByte)))
        XCTAssertTrue(text.contains("10 Byte"))
    }
}
