import XCTest
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSMonitorKit

@MainActor final class ScanSessionStateTests: XCTestCase {

    /// Baut eine B0-Payload aus einzelnen (Messwert, field_flags)-Paaren --
    /// eigenständig byteweise zusammengesetzt (nicht über
    /// `B0ScanProfile.build`), damit ein Test, der eine `Frame`-Payload
    /// durch `applyingFrames` schickt, die tatsächliche Decodierung prüft
    /// statt sich selbst zu bestätigen (gleiches Muster wie
    /// `B0ScanProfileTests.makePayload`).
    private func b0Payload(partialScanIndex: UInt8 = 0, measurements: [UInt16]) -> [UInt8] {
        let n = measurements.count
        let byte2 = UInt8((n >> 8) & 0x03) | ((partialScanIndex & 0x03) << 3)
        var payload: [UInt8] = [B0ScanProfile.commandByte, UInt8(n & 0xFF), byte2]
        for value in measurements {
            payload.append(UInt8(value & 0xFF))
            payload.append(UInt8((value >> 8) & 0x1F))
        }
        payload.append(0xAA) // ein Trailer-Byte, wie real erwartet (b0-scan-profile.md §3)
        return payload
    }

    private func b0Frame(measurements: [UInt16], address: UInt8 = 0x81) throws -> Frame {
        try Frame.build(address: address, payload: b0Payload(measurements: measurements))
    }

    private func date(_ secondsSinceReference: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: secondsSinceReference)
    }

    // MARK: - Anfangszustand

    func testInitialStateIsDisconnectedAndEmpty() {
        let state = ScanSessionState()

        XCTAssertEqual(state.connection, .disconnected)
        XCTAssertNil(state.lastProfile)
        XCTAssertNil(state.lastProfileReceivedAt)
        XCTAssertNil(state.profileRateHz)
        XCTAssertEqual(state.diagnostics, StreamParser.Diagnostics())
    }

    // MARK: - Verbindungsübergänge

    func testApplyingConnectingResetsEverythingEvenFromAPopulatedState() throws {
        var state = ScanSessionState.applyingConnecting(portPath: "/dev/cu.old", baudRate: .baud38400)
        state = state.applyingFrames([try b0Frame(measurements: [1, 2, 3])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))
        XCTAssertNotNil(state.lastProfile, "Testvoraussetzung: Zustand hat vor dem eigentlichen Test Daten")

        let reconnecting = ScanSessionState.applyingConnecting(portPath: "/dev/cu.new", baudRate: .baud9600)

        XCTAssertEqual(reconnecting.connection, .connecting(portPath: "/dev/cu.new", baudRate: .baud9600))
        XCTAssertNil(reconnecting.lastProfile, "ein neuer Verbindungsversuch darf kein Profil aus der alten Verbindung zeigen")
        XCTAssertEqual(reconnecting.diagnostics, StreamParser.Diagnostics())
    }

    func testApplyingConnectedPreservesAlreadyAccumulatedState() throws {
        let connecting = ScanSessionState.applyingConnecting(portPath: "/dev/cu.a", baudRate: .baud9600)
        let withProfile = connecting.applyingFrames([try b0Frame(measurements: [42])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))

        let connected = withProfile.applyingConnected(portPath: "/dev/cu.a", baudRate: .baud9600)

        XCTAssertEqual(connected.connection, .connected(portPath: "/dev/cu.a", baudRate: .baud9600))
        XCTAssertNotNil(connected.lastProfile, "applyingConnected ist keine Rücksetzung, nur ein Statuswechsel")
    }

    func testApplyingConnectFailureCarriesTheGivenMessage() {
        let state = ScanSessionState().applyingConnectFailure(portPath: "/dev/cu.a", baudRate: .baud9600, message: "Open failed (errno 2).")

        XCTAssertEqual(state.connection, .failed(portPath: "/dev/cu.a", baudRate: .baud9600, message: "Open failed (errno 2)."))
    }

    // MARK: - Frames/Diagnostik

    func testApplyingFramesWithValidB0FrameSetsLastProfileAndTimestamp() throws {
        let frame = try b0Frame(measurements: [10, 20, 30])

        let state = ScanSessionState().applyingFrames([frame], diagnostics: StreamParser.Diagnostics(), receivedAt: date(5))

        XCTAssertEqual(state.lastProfile?.measurements.count, 3)
        XCTAssertEqual(state.lastProfile?.trailingBytes, [0xAA])
        XCTAssertEqual(state.lastProfileReceivedAt, date(5))
    }

    func testApplyingFramesStoresWhateverDiagnosticsItIsGivenUnchanged() throws {
        // `StreamParser.Diagnostics`-Felder sind außerhalb von
        // `SickPLSCore` nur über einen echten Parserlauf mit einem von 0
        // verschiedenen Wert erreichbar -- das macht diesen Test
        // aussagekräftiger als ein Vergleich gegen den Default-Wert, der
        // auch ohne jede Durchreichung träfe.
        var parser = StreamParser()
        let frame = try b0Frame(measurements: [1])
        let frames = parser.feed(frame.encoded())
        XCTAssertEqual(frames.count, 1, "Testvoraussetzung: ein vollständiger Frame kam an")
        let diagnosticsAfterOneFrame = parser.diagnostics
        XCTAssertGreaterThan(diagnosticsAfterOneFrame.validFrames, 0, "Testvoraussetzung: ein von 0 verschiedener Wert")

        let state = ScanSessionState().applyingFrames(frames, diagnostics: diagnosticsAfterOneFrame, receivedAt: date(0))

        XCTAssertEqual(state.diagnostics, diagnosticsAfterOneFrame)
    }

    func testApplyingFramesWithUndecodableFrameLeavesLastProfileUnchanged() throws {
        let withProfile = ScanSessionState().applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))
        let unexpectedFrame = try Frame.build(address: 0x81, payload: [0xA0, 0x01])

        let state = withProfile.applyingFrames([unexpectedFrame], diagnostics: StreamParser.Diagnostics(), receivedAt: date(1))

        XCTAssertEqual(state.lastProfile, withProfile.lastProfile, "ein nicht-B0-Frame darf das zuletzt bekannte Profil nicht überschreiben")
        XCTAssertEqual(state.lastProfileReceivedAt, date(0), "kein neuer Zeitstempel ohne neues Profil")
    }

    // MARK: - Rollierende Profilrate

    func testProfileRateIsNilAfterOnlyOneProfile() throws {
        let state = ScanSessionState().applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))

        XCTAssertNil(state.profileRateHz)
    }

    func testProfileRateAfterTwoProfilesHalfASecondApart() throws {
        var state = ScanSessionState()
        state = state.applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))
        state = state.applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0.5))

        XCTAssertEqual(state.profileRateHz ?? 0, 2.0, accuracy: 1e-9)
    }

    func testProfileRateWindowDropsOldestTimestampBeyondWindowSize() throws {
        var state = ScanSessionState()
        // Acht Profile im Sekundentakt: t = 0...7 -> Rate exakt 1.0 Hz.
        for second in 0...7 {
            state = state.applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(Double(second)))
        }
        XCTAssertEqual(state.profileRateHz ?? 0, 1.0, accuracy: 1e-9, "Testvoraussetzung: volles Fenster ergibt exakt 1 Hz")

        // Ein neuntes Profil weit später -- das älteste Fenster-Element
        // (t=0) muss dabei aus dem rollierenden Fenster fallen.
        state = state.applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(107))

        // Mit t=0 verworfen bleiben t=1...7 und t=107: 7 Intervalle über 106 s.
        let expectedRate = 7.0 / 106.0
        XCTAssertEqual(state.profileRateHz ?? 0, expectedRate, accuracy: 1e-9)
    }

    // MARK: - Stromende / Trennen

    func testApplyingStreamEndedUnexpectedlyPreservesDataButMarksFailed() throws {
        let withProfile = ScanSessionState.applyingConnecting(portPath: "/dev/cu.a", baudRate: .baud9600)
            .applyingConnected(portPath: "/dev/cu.a", baudRate: .baud9600)
            .applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))

        let state = withProfile.applyingStreamEnded(portPath: "/dev/cu.a", baudRate: .baud9600, unexpectedly: true)

        guard case .failed(let portPath, let baudRate, let message) = state.connection else {
            return XCTFail("erwartet .failed, war \(state.connection)")
        }
        XCTAssertEqual(portPath, "/dev/cu.a")
        XCTAssertEqual(baudRate, .baud9600)
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotNil(state.lastProfile, "ein unerwartetes Stromende soll das zuletzt bekannte Profil nicht verwerfen")
    }

    func testApplyingStreamEndedNotUnexpectedlyResetsToBlankState() throws {
        let withProfile = ScanSessionState.applyingConnecting(portPath: "/dev/cu.a", baudRate: .baud9600)
            .applyingConnected(portPath: "/dev/cu.a", baudRate: .baud9600)
            .applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))

        let state = withProfile.applyingStreamEnded(portPath: "/dev/cu.a", baudRate: .baud9600, unexpectedly: false)

        XCTAssertEqual(state, ScanSessionState())
    }

    func testApplyingDisconnectedAlwaysResetsToBlankStateRegardlessOfPriorState() throws {
        let withProfile = ScanSessionState.applyingConnecting(portPath: "/dev/cu.a", baudRate: .baud9600)
            .applyingConnected(portPath: "/dev/cu.a", baudRate: .baud9600)
            .applyingFrames([try b0Frame(measurements: [1])], diagnostics: StreamParser.Diagnostics(), receivedAt: date(0))

        XCTAssertEqual(withProfile.applyingDisconnected(), ScanSessionState())
    }
}
