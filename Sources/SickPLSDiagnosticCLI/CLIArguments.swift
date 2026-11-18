import SickPLSCore
import SickPLSMacTransport
import SickPLSActiveControl

/// Optionen des Diagnose-CLI, reine Werte ohne Seiteneffekt -- getrennt
/// von `main.swift`, damit ``parseArguments(_:)`` ohne `exit(_:)` bzw.
/// echten Prozessabbruch getestet werden kann (SICK-010-Auftrag).
struct CLIOptions: Equatable {
    var portPath: String?
    var listPorts = false
    var durationSeconds: Double?
    /// Explizit gewählte Baudrate, siehe ``SerialPortBaudRate``. Kein
    /// Default hier -- `main.swift` verlangt `--baud`, sobald tatsächlich
    /// verbunden wird (SICK-010-Scope-Änderung: kein Auto-Baud, siehe
    /// `SerialPortSettings.swift`-Kopfkommentar zu `SerialPortBaudRate`).
    var baudRate: SerialPortBaudRate?
    /// Sichtbarer Opt-in für die aktive Identitätsprobe (SICK-011-
    /// Auftrag) -- `false` per Default, es gibt keinen automatischen
    /// Start. Nur bei `true` sendet `main.swift` überhaupt ein Byte.
    var probeBaud = false
    /// Bewusst getroffene Zieladresse für die Probe, siehe
    /// ``ConfirmedTargetAddress``. `nil` heißt „nicht angegeben" --
    /// `main.swift` löst das explizit auf ``ConfirmedTargetAddress/universal``
    /// auf (dokumentierter Default, kein stiller Parameter-Default hier
    /// in der Optionsstruktur selbst).
    var targetAddress: ConfirmedTargetAddress?
    /// Scanindizes, deren Rohwerte über die Sitzung als Referenzreihe
    /// gesammelt und am Ende **nur als Kennzahlen** ausgegeben werden
    /// (SICK-034d). Leer per Default; Reihenfolge wie angegeben, ohne
    /// Duplikate.
    var referenceIndices: [Int] = []
}

/// Alles, was beim Parsen der Kommandozeile schiefgehen -- oder als
/// „bitte Hilfe zeigen und beenden" enden -- kann. `main.swift`
/// entscheidet anhand dieses Fehlers über den Exitcode; die Parsing-
/// Logik selbst ruft nie `exit(_:)` auf.
enum CLIArgumentError: Error, Equatable {
    case missingValue(option: String)
    case invalidDuration(String)
    case invalidBaudRate(String)
    case invalidTargetAddress(String)
    case invalidIndex(String)
    case unknownOption(String)
    case helpRequested
}

func message(for error: CLIArgumentError) -> String? {
    switch error {
    case .missingValue(let option):
        return "\(option) requires a value."
    case .invalidDuration(let value):
        return "--duration requires a number of seconds, got \"\(value)\"."
    case .invalidBaudRate(let value):
        let allowed = SerialPortBaudRate.allCases.map { String($0.rawValue) }.joined(separator: "/")
        return "--baud requires one of \(allowed), got \"\(value)\"."
    case .invalidTargetAddress(let value):
        return "--target-address requires a number 0–255 except 129 (0x81, reserved scanner reply address), got \"\(value)\"."
    case .invalidIndex(let value):
        return "--index requires a scan index 0–\(referenceIndexMaximum), got \"\(value)\"."
    case .unknownOption(let option):
        return "Unknown option: \(option)"
    case .helpRequested:
        return nil
    }
}

/// Parst die Kommandozeile. Reine Funktion: kein `print`, kein `exit`,
/// keine Verbindung -- ausschließlich `CLIOptions` oder ein
/// ``CLIArgumentError``.
func parseArguments(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = arguments.startIndex
    while index < arguments.endIndex {
        let argument = arguments[index]
        switch argument {
        case "--port":
            index += 1
            guard index < arguments.endIndex else {
                throw CLIArgumentError.missingValue(option: "--port")
            }
            options.portPath = arguments[index]
        case "--list-ports":
            options.listPorts = true
        case "--duration":
            index += 1
            guard index < arguments.endIndex else {
                throw CLIArgumentError.missingValue(option: "--duration")
            }
            guard let seconds = Double(arguments[index]) else {
                throw CLIArgumentError.invalidDuration(arguments[index])
            }
            options.durationSeconds = seconds
        case "--baud":
            index += 1
            guard index < arguments.endIndex else {
                throw CLIArgumentError.missingValue(option: "--baud")
            }
            guard let rawValue = Int32(arguments[index]),
                  let baudRate = SerialPortBaudRate(rawValue: rawValue) else {
                throw CLIArgumentError.invalidBaudRate(arguments[index])
            }
            options.baudRate = baudRate
        case "--probe-baud":
            options.probeBaud = true
        case "--target-address":
            index += 1
            guard index < arguments.endIndex else {
                throw CLIArgumentError.missingValue(option: "--target-address")
            }
            guard let rawValue = UInt8(arguments[index]),
                  let address = ConfirmedTargetAddress(rawValue: rawValue) else {
                throw CLIArgumentError.invalidTargetAddress(arguments[index])
            }
            options.targetAddress = address
        case "--index":
            index += 1
            guard index < arguments.endIndex else {
                throw CLIArgumentError.missingValue(option: "--index")
            }
            guard let value = Int(arguments[index]), (0...referenceIndexMaximum).contains(value) else {
                throw CLIArgumentError.invalidIndex(arguments[index])
            }
            if !options.referenceIndices.contains(value) {
                options.referenceIndices.append(value)
            }
        case "--help", "-h":
            throw CLIArgumentError.helpRequested
        default:
            throw CLIArgumentError.unknownOption(argument)
        }
        index += 1
    }
    return options
}
