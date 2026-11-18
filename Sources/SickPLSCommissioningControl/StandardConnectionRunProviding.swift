import SickPLSCommissioning

/// Stellt für einen ausgewählten Port einen ``StandardConnectionRun``
/// her (SICK-0330b).
///
/// **Injizierbar, damit die Nachweise ohne Port und ohne Gerät laufen**
/// -- mit einem **echten** ``StandardConnectionRun`` über einen
/// skriptbaren Transport, nicht mit einem nachgebauten Lauf. Die einzige
/// produktive Umsetzung ist ``SystemStandardConnectionRunFactory``; sie
/// ist zugleich die einzige Stelle, die dafür einen echten Transport
/// erzeugt -- die Oberfläche tut das nie.
///
/// `onProgress` wird synchron aus dem laufenden `connect(portPath:)`
/// heraus gerufen, auf dessen Thread; der Aufrufer bringt die Berichte
/// selbst auf den Kontroll-Thread.
public protocol StandardConnectionRunProviding {
    func makeRun(
        portPath: String,
        measurementMode: ScannerMeasurementMode,
        onProgress: @escaping StandardConnectionProgressHandler
    ) throws -> StandardConnectionRun
}
