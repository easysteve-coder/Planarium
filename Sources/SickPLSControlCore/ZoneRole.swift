/// Die Rolle, die eine ``Zone`` im späteren Mapping-/Editor-Slice
/// spielt -- mindestens diese fünf (SICK-013-Auftrag), ein
/// geschlossenes Enum wie `SerialPortBaudRate` in `SickPLSMacTransport`:
/// eine Rolle außerhalb dieser Liste ist ein bewusster, künftiger
/// Erweiterungsschritt, kein stiller String.
///
/// `SickPLSControlCore` selbst erzeugt aus einer Rolle **keinen**
/// MIDI-/Audio-/Notenwert -- die Rolle ist hier nur ein Etikett. Die
/// eigentliche Übersetzung in konkrete MIDI-/Audio-Werte ist bewusst
/// ein späterer, eigener Slice (siehe `ROADMAP.md`, Schritte 4-9 des
/// freigegebenen Prototypenpfads).
public enum ZoneRole: Equatable, Hashable, Sendable, CaseIterable {
    case pitch
    case volume
    case filter
    case gate
    case effectSend
}
