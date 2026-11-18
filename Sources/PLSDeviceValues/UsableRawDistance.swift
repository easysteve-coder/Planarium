/// Die **eine** Vorstellung davon, was ein brauchbarer PLS-Rohwert ist.
///
/// `0` heißt „kein Echo", `8191` heißt „Bereichsende" -- beides sind gültige
/// Drahtwerte, aber keine gemessene Fläche. Der Begriff steht in der
/// Kernschicht, weil der Messpfad hier liegt; `ScanFieldFit` in MonitorKit
/// verweist darauf, statt eine zweite Vorstellung zu führen.
///
/// Er sagt **nichts** über `fieldFlags`: deren Bedeutung ist weiter offen und
/// darf nicht nebenbei zur Gültigkeitsregel werden.
public enum UsableRawDistance {
    /// Kleinster Rohwert, der eine gemessene Fläche bezeichnet.
    public static let lowestRawValue: UInt16 = 1
    /// Größter Rohwert, der eine gemessene Fläche bezeichnet.
    public static let highestRawValue: UInt16 = 8_190

    /// Ob dieser Rohwert eine gemessene Fläche bezeichnet.
    public static func contains(_ rawValue: UInt16) -> Bool {
        rawValue >= lowestRawValue && rawValue <= highestRawValue
    }
}

