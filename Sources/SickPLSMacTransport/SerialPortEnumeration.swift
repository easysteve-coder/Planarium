/// Testbare Abstraktion über das Auflisten von Verzeichniseinträgen, damit
/// ``SerialPortEnumeration`` ohne echten Zugriff auf `/dev` getestet werden
/// kann (SICK-009-Auftrag: „kein physisches Gerät öffnen").
public protocol DirectoryLister {
    /// Namen der Einträge in `path` (ohne Pfadpräfix), in beliebiger
    /// Reihenfolge. Ein nicht existierendes oder nicht lesbares Verzeichnis
    /// liefert eine leere Liste, keinen Fehler -- Portauflistung ist reine
    /// Diagnose, kein Fehlerpfad, der eine laufende Sitzung stören sollte.
    func entryNames(inDirectory path: String) -> [String]
}

/// Listet nur `/dev/cu.*` auf, nie `/dev/tty.*` (SICK-009-Auftrag:
/// „Portliste darf nur /dev/cu.* lesen"). `/dev/tty.*` blockiert unter
/// macOS beim Öffnen, bis Carrier Detect (DCD) anliegt, und ist deshalb
/// für einen expliziten, nicht automatisch verbindenden Client die falsche
/// Wahl -- `/dev/cu.*` ("callout") ist der für ausgehende, nicht
/// blockierende Verbindungen vorgesehene Knoten.
public enum SerialPortEnumeration {
    public static let directoryPath = "/dev"
    public static let prefix = "cu."

    /// Vollständige Pfade aller `/dev/cu.*`-Einträge, sortiert. Wählt
    /// **keinen** Port aus und verbindet nicht -- reine Auflistung für
    /// einen Aufrufer, der den Pfad danach explizit übergibt (kein
    /// Auto-Scan, siehe ``SerialPortOpener``).
    public static func availablePortPaths(lister: DirectoryLister = DarwinDirectoryLister()) -> [String] {
        lister.entryNames(inDirectory: directoryPath)
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .map { "\(directoryPath)/\($0)" }
    }
}
