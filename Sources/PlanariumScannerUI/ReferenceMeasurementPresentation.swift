import SickPLSCore

/// Reine, rohwertfreie Darstellung der Referenzmessung für eine spätere
/// Oberfläche. Die Zahlenzeile bleibt vollständig die Kernfunktion
/// `describe(_:)`.
public enum ReferenceMeasurementPresentation {
    public static func describe(_ measurement: ReferenceMeasurementModel) -> String {
        guard let statistics = measurement.statistics else {
            return measurement.isRunning
                ? "Reference measurement: running, no values yet"
                : "Reference measurement: not running"
        }
        let numbers = SickPLSCore.describe(statistics)
        return measurement.isRunning
            ? "Reference measurement: running\n\(numbers)"
            : "Reference measurement: stopped\n\(numbers)"
    }
}
