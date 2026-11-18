import PlanariumRuntime
import PlanariumApplication
import PlanariumAudio
import PlanariumMIDI
import PlanariumDomain
import PlanariumInput
import Foundation
import XCTest
import Combine
import SickPLSCore
import SickPLSControlCore
import SickPLSMacTransport
import SickPLSMonitorKit
import PlanariumPresets
@testable import PlanariumScannerUI

// Gemeinsame Testgrundlage für `PlanariumScannerUI`.
//
// **Kein Scanner, kein Audiogerät, kein echter Timer, keine echte
// Uhr — und ausdrücklich keine SwiftUI-Ansicht.** Genau das ist der
// Punkt dieses Slices: Der Klangpfad muss ohne Renderdurchlauf
// funktionieren, also darf ihn auch kein Test über eine Ansicht
// anstoßen.
//
// Der Weg eines Profils läuft hier durch die **echte** `RXSession`
// samt echtem Hintergrund-Thread und echtem Framing — gefälscht ist nur
// die unterste Grenze (der Dateideskriptor) und der Audiohost.

// MARK: - Serielle Fakes

/// Wie `FakeSerialPortFileDescriptor` in `SickPLSMonitorKitTests`: Diese
/// Fakes werden von einem echten Hintergrund-Thread aus gerufen, nicht
/// nur synchron vom Testcode — deshalb `NSLock` statt ungesicherter
/// Felder.
final class FakeSerialPortFileDescriptor: SerialPortFileDescriptor {
    private let lock = NSLock()
    private var readScript: [SerialPortReadOutcome]
    private var _closeCallCount = 0
    /// Wie lange ``close()`` braucht, **bevor** der Zähler hochgeht
    /// (SICK-032c3a-K2, Default `0`: keine Wirkung auf bestehende Tests).
    ///
    /// Dasselbe Muster wie in `SickPLSMonitorKitTests/Fakes.swift`
    /// (SICK-030a): Ohne dieses Zeitfenster ist der Moment zwischen dem
    /// ausdrücklichen `disconnect()` und dem tatsächlichen `close(2)` auf
    /// dem Lesethread für einen Test unbeobachtbar — genau das Fenster,
    /// dessen sofortige Fokusprofil-Invalidierung dieser Slice belegt.
    private let closeDelaySeconds: TimeInterval

    var closeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _closeCallCount
    }

    init(readScript: [SerialPortReadOutcome], closeDelaySeconds: TimeInterval = 0) {
        self.readScript = readScript
        self.closeDelaySeconds = closeDelaySeconds
    }

    /// Wartet bei `.timeout` tatsächlich, wie echte Hardware es täte —
    /// sonst liefe ein endliches Skript in Mikrosekunden durch und
    /// Zwischenzustände wären von außen unbeobachtbar.
    func read(timeoutMilliseconds: Int32) -> SerialPortReadOutcome {
        let outcome: SerialPortReadOutcome = {
            lock.lock()
            defer { lock.unlock() }
            guard !readScript.isEmpty else { return .closed }
            return readScript.removeFirst()
        }()
        if outcome == .timeout {
            Thread.sleep(forTimeInterval: TimeInterval(timeoutMilliseconds) / 1000.0)
        }
        return outcome
    }

    func close() {
        if closeDelaySeconds > 0 {
            Thread.sleep(forTimeInterval: closeDelaySeconds)
        }
        lock.lock()
        _closeCallCount += 1
        lock.unlock()
    }
}

final class FakeSerialPortOpener: SerialPortOpener, ScanByteStreamOpening {
    struct OpenFailure: Error {}

    private let lock = NSLock()
    private var portsToReturn: [SerialPortFileDescriptor]
    private var _requestedPaths: [String] = []
    private var _requestedBaudRates: [SerialPortBaudRate] = []
    private var _errorToThrow: Error?

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedPaths
    }

    /// **Die tatsächlich verwendeten Raten** — daran hängt der Nachweis,
    /// dass eine verifizierte Rate eine Bedienauswahl schlägt
    /// (SICK-030a1).
    var requestedBaudRates: [SerialPortBaudRate] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedBaudRates
    }

    /// Lässt das Öffnen scheitern — für den Nachweis, dass auch ein
    /// gescheiterter Versuch den Port über das **echte** Ereignis
    /// freigibt.
    var errorToThrow: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _errorToThrow }
        set { lock.lock(); _errorToThrow = newValue; lock.unlock() }
    }

    init(portsToReturn: [SerialPortFileDescriptor]) {
        self.portsToReturn = portsToReturn
    }

    func open(atPath path: String, baudRate: SerialPortBaudRate) throws -> SerialPortFileDescriptor {
        lock.lock()
        defer { lock.unlock() }
        _requestedPaths.append(path)
        _requestedBaudRates.append(baudRate)
        if let error = _errorToThrow {
            throw error
        }
        guard !portsToReturn.isEmpty else {
            fatalError("FakeSerialPortOpener: kein weiterer Fake-Port vorbereitet")
        }
        return portsToReturn.removeFirst()
    }

    func openStream() throws -> SerialPortFileDescriptor {
        lock.lock()
        defer { lock.unlock() }
        if let error = _errorToThrow { throw error }
        guard !portsToReturn.isEmpty else {
            fatalError("FakeSerialPortOpener: kein weiterer Fake-Port vorbereitet")
        }
        return portsToReturn.removeFirst()
    }
}

/// Observes the real session events, without a product-side Main sound hook.
@MainActor final class SpyRXSessionDelivery {
    private(set) var acceptedProfiles: [[UInt16]] = []
    private(set) var inputEndedCount = 0
    private var subscriptions: Set<AnyCancellable> = []
    init(session: RXSession) {
        session.performanceProfiles.sink { [weak self] batch in
            self?.acceptedProfiles.append(batch.profile.measurements.map(\.value))
        }.store(in: &subscriptions)
        session.portReleased.sink { [weak self] _ in
            self?.inputEndedCount += 1
        }.store(in: &subscriptions)
    }
}

// MARK: - Testaufbau

/// Baut Koordinator, Sitzung und Audiodienst mit ausschließlich
/// gefälschten äußeren Grenzen.
@MainActor struct CoordinatorHarness {
    let root: PlanariumComposition
    var host: AudioHost { root.audio }
    var engine: AudioHost { root.audio }
    let opener: FakeSerialPortOpener
    let coordinator: ScannerWorkspaceModel
    let sessionDelivery: SpyRXSessionDelivery

    /// Die IDs der drei Zonen im Editorzustand des Koordinators.
    let pitchZoneID: EditableZone.ID
    let volumeZoneID: EditableZone.ID
    let gateZoneID: EditableZone.ID

    init(descriptors: [FakeSerialPortFileDescriptor]) {
        opener = FakeSerialPortOpener(portsToReturn: descriptors)

        root = try! PlanariumComposition(scanner: opener, midi: NoMIDI(), components: NoPlugins(), configuration: .init(offline: true), readTimeoutMilliseconds: 20)
        let session = root.input.session
        sessionDelivery = SpyRXSessionDelivery(session: session)
        coordinator = ScannerWorkspaceModel(input: root.input)

        var state = ZoneEditorState()
        pitchZoneID = state.addZone(Self.zone(role: .pitch, index: 0.0...0.3))
        volumeZoneID = state.addZone(Self.zone(role: .volume, index: 0.3...0.6))
        gateZoneID = state.addZone(Self.zone(role: .gate, index: 0.6...1.0))
        // Seit SICK-030b1 entstehen neue Zonen **deaktiviert**. Der
        // Prüfstand macht denselben ausdrücklichen Schritt, den auch der
        // Bedienende macht, damit die bestehenden Aussagen unverändert
        // gelten.
        state.setZone(pitchZoneID, isEnabled: true)
        state.setZone(volumeZoneID, isEnabled: true)
        state.setZone(gateZoneID, isEnabled: true)
        state.select(nil)
        coordinator.editorState = state
    }

    static func zone(role: ZoneRole, index: ClosedRange<Double>) -> Zone {
        try! Zone.build(
            indexLowerBound: index.lowerBound,
            indexUpperBound: index.upperBound,
            valueLowerBound: 100,
            valueUpperBound: 4000,
            role: role
        )
    }

    /// Entfernt eine Zone — **über den produktiven Koordinatorweg**
    /// (SICK-032c1). Bis dahin schrieb dieser Prüfstand den
    /// Editorzustand selbst zurück; seit die Oberfläche das nicht mehr
    /// darf, nimmt auch der Test denselben Weg wie die Bedienung.
    func removeZone(_ id: EditableZone.ID) {
        coordinator.removeZone(id)
    }

    /// Schaltet eine Zone ein oder aus — ebenfalls über den produktiven
    /// Koordinatorweg (SICK-030b1, seit SICK-032c1 über den Koordinator).
    func setZone(_ id: EditableZone.ID, isEnabled: Bool) {
        coordinator.setZone(id, isEnabled: isEnabled)
    }
}

// MARK: - Wire-Bytes

/// Ein echtes, CRC-valides B0-Frame — der Weg läuft durch den echten
/// `StreamParser` und den echten `B0ScanProfile.decode`.
func b0FrameBytes(measurements: [UInt16]) throws -> [UInt8] {
    let n = measurements.count
    var payload: [UInt8] = [B0ScanProfile.commandByte, UInt8(n & 0xFF), UInt8((n >> 8) & 0x03)]
    for value in measurements {
        payload.append(UInt8(value & 0xFF))
        payload.append(UInt8((value >> 8) & 0x1F))
    }
    payload.append(0xAA)
    return try Frame.build(address: 0x81, payload: payload).encoded()
}

/// Ein CRC-valides Frame mit einem **anderen** Kommandobyte — gültiger
/// Rahmen, kein Scanprofil.
func nonB0FrameBytes() throws -> [UInt8] {
    try Frame.build(address: 0x81, payload: [0xB1, 0x01, 0x02, 0x03]).encoded()
}

/// Zehn Messwerte, alle im Zonenbereich `100...4000`.
///
/// `value: 3000` ergibt den Steuerwert ≈ 0,744 — **über** der
/// Gate-Schwelle `0,5`; `value: 1000` ergibt ≈ 0,231, also darunter.
func profileMeasurements(value: UInt16) -> [UInt16] {
    Array(repeating: value, count: 10)
}

/// Messwerte, die keine Zone sieht (weit über der Zonenobergrenze).
func measurementsSeenByNoZone() -> [UInt16] {
    Array(repeating: 8000, count: 10)
}

// MARK: - Warten

extension XCTestCase {
    /// Pumpt den Haupt-RunLoop, bis `condition` erfüllt ist.
    ///
    /// Nötig, weil `RXSession` aus einem echten Hintergrund-Thread
    /// über `DispatchQueue.main.async` zustellt. **Das ist kein
    /// SwiftUI-Renderdurchlauf** — es läuft keine Ansicht, es existiert
    /// kein Fenster.
    /// Wartet auf eine Bedingung. Das Zeitlimit begrenzt eine Flake und ist
    /// **keine** Zusicherung: keine Prüfung dieses Projekts verlangt, dass eine
    /// Bedingung schnell erfüllt wird, nur dass sie erfüllt wird. Es ist deshalb
    /// großzügig gewählt, damit eine belastete Maschine keinen Fehlschlag
    /// erfindet; ein wirklich unerfüllter Zustand fällt weiterhin auf.
    func waitUntil(
        timeout: TimeInterval = 10.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("Bedingung nicht innerhalb von \(timeout)s erfüllt", file: file, line: line)
    }

    /// Pumpt den RunLoop eine feste Zeit, ohne eine Bedingung zu
    /// erwarten — für die Nachweise, dass **nichts** passiert.
    func pumpMainLoop(seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
    }
}

@MainActor private final class NoMIDI: MIDIConnectionBoundary {
 var onDestinationLost: (@MainActor () -> Void)?
 func destinations() -> [MIDITargetDescription] { [] }
 func open(_ target: InstrumentMIDITarget) -> Result<any MIDISendBoundary, MIDIConnectionError> { .failure(.init("No destination")) }
 func close() {}
}
@MainActor private final class NoPlugins: PluginComponentSource {
 func load(_ identity: SpatialAudioUnitIdentity, completion: @escaping @MainActor @Sendable (Result<any PluginUnit, PluginLoadError>) -> Void) { completion(.failure(.init("No plug-in"))) }
}
