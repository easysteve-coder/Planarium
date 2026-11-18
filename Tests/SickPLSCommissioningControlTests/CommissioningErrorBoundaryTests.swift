import Foundation
import XCTest
@testable import SickPLSCommissioning
@testable import SickPLSCommissioningControl
import SickPLSMacTransport

/// Ein **ausgedachter** Text, der so aussieht, wie eine fremde
/// Fehlerbeschreibung im schlimmsten Fall aussähe: Portpfad,
/// Telegrammbytes und ein geheimnisähnlicher Wert in einem Satz.
///
/// **Nichts davon ist echt** — kein realer Port, kein reales Telegramm,
/// kein reales Installationsgeheimnis. Er existiert nur, damit ein Test
/// sehen kann, ob so etwas durchsickern würde.
///
/// Er liegt bewusst als Datei-Konstante und **nicht** in einem Feld der
/// Fakes: Ein Wert, den die Objektgraphen der Nachweise selbst tragen,
/// würde beim Tiefendurchlauf gefunden und die Aussage wertlos machen.
private let leakyMarkerText =
    "LECKPROBE /dev/cu.erfunden bytes=AA-BB-CC geheim=XXXXXXXX"

/// Ein Fremdfehler, der seine Nutzlast über **jeden** üblichen Weg
/// preisgibt: Standardbeschreibung, `CustomStringConvertible`,
/// `CustomDebugStringConvertible` und `LocalizedError`.
private struct LeakyForeignError: Error, CustomStringConvertible,
                                 CustomDebugStringConvertible, LocalizedError {
    let payload: String
    var description: String { payload }
    var debugDescription: String { payload }
    var errorDescription: String? { payload }
}

/// Ein Laufanbieter, der genau so einen Fremdfehler wirft.
///
/// **Er speichert den Text nicht**, sondern baut ihn beim Werfen — sonst
/// stünde er im Objektgraphen des Bedienmodells, und der Tiefendurchlauf
/// unten fände ihn im eigenen Testaufbau statt im Prüfgegenstand.
private final class LeakyRunProvider: CommissioningRunProviding {
    private(set) var requestedPaths: [String] = []

    func makeRun(portPath: String) throws -> CommissioningRunning & CommissioningAborting {
        requestedPaths.append(portPath)
        throw LeakyForeignError(payload: leakyMarkerText)
    }
}

/// Ein Transportbau, der genau so einen Fremdfehler wirft — für den
/// Systemfabrikweg.
private func leakyTransportFactory() -> SystemCommissioningRunFactory {
    SystemCommissioningRunFactory(makeTransport: { _ in
        throw LeakyForeignError(payload: leakyMarkerText)
    })
}

/// Sammelt alles, was ein Wert über sich preisgibt — Beschreibung,
/// Debug-Ausgabe und der gespiegelte Objektgraph bis zu einer festen
/// Tiefe.
private func deepDump(_ value: Any, depth: Int = 5) -> String {
    var parts = [String(describing: value), String(reflecting: value)]
    guard depth > 0 else { return parts.joined(separator: "\n") }
    for child in Mirror(reflecting: value).children {
        parts.append(child.label ?? "")
        parts.append(deepDump(child.value, depth: depth - 1))
    }
    return parts.joined(separator: "\n")
}

/// Die Nachweise der datenfreien Fehlergrenze (SICK-032a1).
///
/// **Kein echter Port, kein TX, keine Hardware, keine PTY, kein Capture
/// und kein echter Geheimniswert** — der Markertext oben ist erfunden.
final class CommissioningErrorBoundaryTests: XCTestCase {

    // MARK: - Entstehungsstelle 1: fremder Laufanbieter

    func testAForeignProviderErrorNeverReachesTheOutcomeOrTheNotice() {
        let coordinator = SpyPortCoordinator()
        let provider = LeakyRunProvider()
        let dispatcher = ManualCommissioningDispatcher()
        let model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: dispatcher,
            portListing: FakeSerialPortListing()
        )
        model.selectPort("/dev/cu.usbserial-TEST")
        model.requestAccess()
        model.requestStep(.checkStartingRate)

        let outcome = model.confirmPendingStep()

        // **Sichtbar und typisiert bleibt der Bedienfehler.**
        XCTAssertEqual(outcome, .refusedRunUnavailable(.transportUnavailable))
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(dispatcher.backgroundWork.count, 0, "Es darf nichts ausgeführt worden sein")

        // **Und nirgends steht die fremde Beschreibung.**
        assertNoLeak(in: outcome, "Rückgabewert")
        assertNoLeak(in: model.notice as Any, "Notice")
        assertNoLeak(in: model, "Bedienmodell")
    }

    /// Auch nach einem zweiten Versuch bleibt nichts hängen — der
    /// Fehlerpfad sammelt keine Historie an.
    func testRepeatedForeignProviderErrorsLeaveNothingBehind() {
        let coordinator = SpyPortCoordinator()
        let provider = LeakyRunProvider()
        let model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: provider,
            dispatcher: ManualCommissioningDispatcher(),
            portListing: FakeSerialPortListing()
        )
        model.selectPort("/dev/cu.usbserial-TEST")
        model.requestAccess()

        for _ in 0..<3 {
            model.requestStep(.checkStartingRate)
            XCTAssertEqual(model.confirmPendingStep(), .refusedRunUnavailable(.transportUnavailable))
        }
        XCTAssertEqual(provider.requestedPaths.count, 3, "Jeder Versuch fragt erneut")
        XCTAssertTrue(model.auditEntries.isEmpty, "Ein gescheiterter Aufbau protokolliert nichts")
        assertNoLeak(in: model, "Bedienmodell nach drei Versuchen")
    }

    // MARK: - Entstehungsstelle 2: System-Fabrik / Opener

    func testAForeignTransportErrorNeverLeavesTheSystemFactory() {
        let factory = leakyTransportFactory()
        do {
            _ = try factory.makeRun(portPath: "/dev/cu.usbserial-TEST")
            XCTFail("Der Transportbau hätte fehlschlagen müssen")
        } catch let reason as CommissioningRunUnavailableReason {
            XCTAssertEqual(reason, .transportUnavailable)
            assertNoLeak(in: reason, "Grund aus der Systemfabrik")
        } catch {
            XCTFail("Der Fremdfehler wurde unverändert durchgereicht")
        }
    }

    /// Und derselbe Weg über das Bedienmodell — bis in Hinweis und
    /// Debug-Ausgabe.
    func testAForeignTransportErrorNeverReachesTheModelThroughTheSystemFactory() {
        let coordinator = SpyPortCoordinator()
        let model = CommissioningControlModel(
            coordinator: coordinator,
            runProvider: leakyTransportFactory(),
            dispatcher: ManualCommissioningDispatcher(),
            portListing: FakeSerialPortListing()
        )
        model.selectPort("/dev/cu.usbserial-TEST")
        model.requestAccess()
        model.requestStep(.checkStartingRate)

        let outcome = model.confirmPendingStep()

        XCTAssertEqual(outcome, .refusedRunUnavailable(.transportUnavailable))
        XCTAssertTrue(model.notice?.message.contains("Nothing was sent") == true)
        assertNoLeak(in: outcome, "Rückgabewert")
        assertNoLeak(in: model.notice as Any, "Notice")
        assertNoLeak(in: model, "Bedienmodell")
    }

    /// **Gegenrichtung:** Ein bereits typisierter, geprüfter Grund wird
    /// unverändert durchgereicht und nicht zu `transportUnavailable`
    /// eingeebnet — sonst wäre die Datenfreiheit mit einem Verlust an
    /// Aussage erkauft.
    func testAnAlreadyTypedReasonPassesThroughTheSystemFactoryUnchanged() {
        let factory = SystemCommissioningRunFactory(makeTransport: { _ in
            throw CommissioningRunUnavailableReason.pathNotAllowed("/dev/cu.weitergereicht")
        })
        do {
            _ = try factory.makeRun(portPath: "/dev/cu.usbserial-TEST")
            XCTFail("Der Transportbau hätte fehlschlagen müssen")
        } catch let reason as CommissioningRunUnavailableReason {
            XCTAssertEqual(reason, .pathNotAllowed("/dev/cu.weitergereicht"))
        } catch {
            XCTFail("Unerwarteter Fehlertyp")
        }
    }

    // MARK: - Die erlaubten Nutzlasten bleiben erlaubt

    /// Der **eigene**, unmittelbar davor geprüfte Pfad darf weiterhin im
    /// Hinweis stehen — er ist die Auswahl des Bedienenden und steht
    /// ohnehin in der Vorabinformation.
    func testOurOwnCheckedPathIsStillNamed() {
        // **An der echten Systemfabrik geprüft**, nicht an einem Fake:
        // Diese Nutzlast soll ausdrücklich erhalten bleiben.
        let factory = SystemCommissioningRunFactory()
        do {
            _ = try factory.makeRun(portPath: "/dev/tty.verboten")
            XCTFail("Ein Pfad außerhalb von /dev/cu. muss abgelehnt werden")
        } catch let reason as CommissioningRunUnavailableReason {
            XCTAssertEqual(reason, .pathNotAllowed("/dev/tty.verboten"))
            // Und der Bedienhinweis nennt ihn weiterhin.
            let coordinator = SpyPortCoordinator()
            let model = CommissioningControlModel(
                coordinator: coordinator,
                runProvider: SystemCommissioningRunFactory(),
                dispatcher: ManualCommissioningDispatcher(),
                portListing: FakeSerialPortListing()
            )
            model.selectPort("/dev/tty.verboten")
            model.requestAccess()
            model.requestStep(.checkStartingRate)
            XCTAssertEqual(
                model.confirmPendingStep(),
                .refusedRunUnavailable(.pathNotAllowed("/dev/tty.verboten"))
            )
            XCTAssertTrue(model.notice?.message.contains("/dev/tty.verboten") == true)
        } catch {
            XCTFail("Unerwarteter Fehlertyp")
        }
    }

    func testTheEmptyPathIsStillItsOwnReason() {
        let factory = SystemCommissioningRunFactory()
        do {
            _ = try factory.makeRun(portPath: "")
            XCTFail("Ohne Pfad gibt es nichts vorzubereiten")
        } catch let reason as CommissioningRunUnavailableReason {
            XCTAssertEqual(reason, .noPortSelected)
        } catch {
            XCTFail("Unerwarteter Fehlertyp")
        }
    }

    // MARK: - Die Grenze selbst

    /// **Der datenfreie Fall trägt wirklich nichts.** Ein Fall ohne
    /// assoziierten Wert kann keinen mitschleppen — das ist der
    /// eigentliche Mechanismus, nicht die Sorgfalt an der Wurfstelle.
    func testTheDataFreeReasonCarriesNoPayloadAtAll() {
        let reason = CommissioningRunUnavailableReason.transportUnavailable
        XCTAssertTrue(Mirror(reflecting: reason).children.isEmpty)
        XCTAssertEqual(String(describing: reason), "transportUnavailable")
    }

    /// Gegenrichtung zur Quelltextregel: Der Aufzählungstyp darf nicht
    /// still wieder eine Fremdnutzlast bekommen.
    func testTheReasonDeclaresExactlyTheseThreeCases() throws {
        let text = try String(
            contentsOf: ControlSourcePaths.sources.appendingPathComponent("CommissioningRunning.swift"),
            encoding: .utf8
        )
        let cases = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
        XCTAssertEqual(
            cases,
            ["case noPortSelected", "case pathNotAllowed(String)", "case transportUnavailable"],
            "Die Fehlergrenze hat sich geändert -- SICK-032a1 bewusst mitpflegen"
        )
    }

    // MARK: - Hilfsmittel

    private func assertNoLeak(
        in value: Any,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let dump = deepDump(value)
        XCTAssertFalse(
            dump.contains(leakyMarkerText),
            "\(label) trägt die fremde Fehlerbeschreibung",
            file: file,
            line: line
        )
        // Auch Bruchstücke dürfen nicht durchkommen.
        for fragment in ["LECKPROBE", "/dev/cu.erfunden", "AA-BB-CC", "geheim="] {
            XCTAssertFalse(
                dump.contains(fragment),
                "\(label) trägt das Bruchstück \(fragment)",
                file: file,
                line: line
            )
        }
    }
}
