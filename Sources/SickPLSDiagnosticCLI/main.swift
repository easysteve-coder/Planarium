import Darwin
import SickPLSCore
import SickPLSMacTransport
import SickPLSActiveControl

// Sehr schlankes RX-only-Diagnose-CLI (SICK-009-Auftrag, erweitert um
// SICK-010: Wertstatistik statt Rohbytes, sauberes SIGINT-Ende). Verbindet
// NIE automatisch -- nur bei explizitem `--port`, nie durch Auto-Scan.
// `--list-ports` listet ausschließlich `/dev/cu.*`. Der RX-only-Modus hat
// keinen TX-Pfad und keinen Weg, ein Byte zu senden
// (`SickPLSSerialConnection` hat strukturell keine `write`-Methode).
//
// Seit SICK-011 gibt es zusätzlich einen ausdrücklichen, nie
// automatischen Opt-in-Modus (`--probe-baud`) für die aktive
// Identitätsprobe aus `SickPLSActiveControl` -- die einzige Stelle in
// diesem CLI, die je ein Byte sendet. Siehe eigener Abschnitt unten.
//
// **Loggt keine Rohcaptures:** Es wird an keiner Stelle ein roher Byte-
// Dump von Frame-Payload oder Stream ausgegeben -- nur decodierte
// Zusammenfassungen und aggregierte Kennzahlen (siehe `CLIReporting.swift`)
// sowie die fortlaufenden `StreamParser.Diagnostics`-Zähler.
//
// Argumentparsing (`CLIArguments.swift`) und Ausgabeformatierung
// (`CLIReporting.swift`) sind reine, seiteneffektfreie Funktionen in
// eigenen Dateien -- diese Datei bleibt bewusst schmal auf
// Ablaufsteuerung reduziert, damit die Logik ohne `exit(_:)`/Verbindung
// per `@testable import` geprüft werden kann.

func printUsage() {
    print(usageText)
}

func monotonicSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

func printDiagnostics(_ diagnostics: StreamParser.Diagnostics) {
    print(describe(diagnostics))
}

let options: CLIOptions
do {
    options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
} catch CLIArgumentError.helpRequested {
    printUsage()
    exit(0)
} catch let error as CLIArgumentError {
    if let text = message(for: error) {
        print("Error: \(text)")
    }
    printUsage()
    exit(1)
}

if options.listPorts {
    let paths = SerialPortEnumeration.availablePortPaths()
    if paths.isEmpty {
        print("No /dev/cu.* ports found.")
    } else {
        for path in paths { print(path) }
    }
    if options.portPath == nil {
        exit(0)
    }
}

guard let portPath = options.portPath else {
    print("Error: no --port specified -- no automatic connection, see --help")
    printUsage()
    exit(1)
}

// Aktiver Opt-in-Modus (SICK-011-Auftrag): nur bei explizitem
// `--probe-baud`, endet danach über `exit(_:)` -- fällt nie in den
// RX-only-Zweig darunter durch, und der RX-only-Zweig läuft nie in
// diesen hinein. Zeigt Ziel/Raten/Wirkung, bevor irgendein Byte
// gesendet wird.
if options.probeBaud {
    let targetAddress = options.targetAddress ?? .universal
    print(describeProbePreview(portPath: portPath, targetAddress: targetAddress, candidates: BaudProbe.candidates))

    let auditLog: IdentityProbeAuditLog
    do {
        auditLog = try BaudProbe.run(
            portPath: portPath,
            targetAddress: targetAddress,
            opener: DarwinActiveControlSerialPortOpener()
        )
    } catch {
        print("Identity probe failed: \(error)")
        exit(1)
    }

    for attempt in auditLog.attempts {
        print(describe(attempt))
    }
    print(describe(auditLog))
    exit(auditLog.identifiedBaudRate != nil ? 0 : 1)
}

guard let baudRate = options.baudRate else {
    print("Error: no --baud specified -- no auto-baud, see --help")
    printUsage()
    exit(1)
}

let connection: SickPLSSerialConnection
do {
    connection = try SickPLSSerialConnection.open(portPath: portPath, baudRate: baudRate)
} catch {
    print("Error opening \(portPath): \(error)")
    exit(1)
}

print("Connected to \(portPath) (\(describe(baudRate)), no flow control). Ctrl-C to stop.")

// SIGINT (Strg-C) soll die Verbindung sauber schließen und eine
// Abschlussdiagnose ausgeben -- wie das reguläre `--duration`-Ende, statt
// den Prozess mitten im Lesezyklus abzubrechen (SICK-010-Auftrag:
// „SIGINT/EOF mit close+Abschlussdiagnose"). Ein C-Funktionszeiger darf
// aus Signal-Handler-Sicherheitsgründen nur ein `sig_atomic_t` setzen,
// keine Swift-Objekte anfassen -- die eigentliche Reaktion passiert
// gepollt in der Leseschleife unten.
var sigintReceived: sig_atomic_t = 0
signal(SIGINT) { _ in
    sigintReceived = 1
}

let startedAt = monotonicSeconds()
var lastStatusPrintedAt = startedAt
let statusIntervalSeconds = 5.0

// Referenzreihen (SICK-034d): je `--index` eine Reihe; gefüllt aus jedem
// decodierten B0-Profil, ausgegeben ausschließlich am Sitzungsende als
// Kennzahlen.
var referenceSeries = options.referenceIndices.map { ReferenceIndexSeries(index: $0) }

func recordReferenceValues(in frames: [Frame], series: inout [ReferenceIndexSeries]) {
    guard !series.isEmpty else { return }
    for frame in frames {
        guard case .success(let profile) = B0ScanProfile.decode(from: frame.payload) else { continue }
        for position in series.indices {
            series[position].record(profile)
        }
    }
}

func printReferenceSummary(_ series: [ReferenceIndexSeries]) {
    guard !series.isEmpty else { return }
    print("Reference series (statistics, no raw values):")
    for item in series {
        if let statistics = item.statistics() {
            print("  " + describe(statistics))
        } else {
            print("  " + describeEmptyReferenceSeries(item))
        }
    }
}

readLoop: while true {
    if sigintReceived != 0 {
        print("Ctrl-C received, closing connection cleanly.")
        let closeResult = connection.close()
        for frame in closeResult.frames {
            for line in describe(frame) { print(line) }
        }
        recordReferenceValues(in: closeResult.frames, series: &referenceSeries)
        printDiagnostics(closeResult.diagnostics)
        printReferenceSummary(referenceSeries)
        break readLoop
    }

    let result = connection.readNext(timeoutMilliseconds: 500)

    for frame in result.frames {
        for line in describe(frame) { print(line) }
    }
    recordReferenceValues(in: result.frames, series: &referenceSeries)

    let now = monotonicSeconds()
    if now - lastStatusPrintedAt >= statusIntervalSeconds {
        printDiagnostics(result.diagnostics)
        lastStatusPrintedAt = now
    }

    if result.reachedEndOfStream {
        print("End of stream reached (EOF/port closure).")
        printDiagnostics(result.diagnostics)
        printReferenceSummary(referenceSeries)
        break readLoop
    }

    if let durationSeconds = options.durationSeconds, now - startedAt >= durationSeconds {
        print("Target time reached, closing connection cleanly.")
        let closeResult = connection.close()
        for frame in closeResult.frames {
            for line in describe(frame) { print(line) }
        }
        recordReferenceValues(in: closeResult.frames, series: &referenceSeries)
        printDiagnostics(closeResult.diagnostics)
        printReferenceSummary(referenceSeries)
        break readLoop
    }
}
