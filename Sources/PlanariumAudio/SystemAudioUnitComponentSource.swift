import PlanariumDomain
// SystemAudioUnitComponentSource.swift
//
// Die **einzige** Stelle des Rack-Vertrags, die `AVFoundation` anfasst.
//
// Sie fragt Apples öffentlichen `AVAudioUnitComponentManager` nach
// vorhandenen Effektkomponenten und reicht deren Metadaten als
// framework-freie `AudioUnitComponentDescription` weiter. **Kein
// Dateisystemscan, keine eigene Plugin-Schnittstelle, keine
// Instanziierung.**
//
// ## Was hier bewusst nicht passiert
//
// `components(matching:)` liefert **Beschreibungen**, keine Instanzen.
// Es wird überhaupt nichts geladen, nichts ausgeführt und
// nichts an einen Audiographen gehängt. Die Instanziierung einer
// Komponente — und damit das erste Ausführen fremden Codes — ist
// ausdrücklich **noch offen** und gehört in einen eigenen,
// separat freizugebenden Folgeslice.
//
// **Eine ehrliche Einschränkung:** das System kann bei der Abfrage
// seinerseits eine Validierung von Komponenten anstoßen, die außerhalb
// unseres Prozesses läuft. Darauf haben wir keinen Einfluss; es ist
// Apples Entdeckungsmechanismus und der Grund, warum wir genau ihn
// verwenden statt selbst im Dateisystem zu suchen.

import AVFoundation

/// `AudioUnitComponentSource` auf Basis von
/// `AVAudioUnitComponentManager` (ab macOS 10.10, also innerhalb der
/// macOS-12-Grundlage).
public final class SystemAudioUnitComponentSource: AudioUnitComponentSource {
    public init() {}

    public func effectComponentDescriptions() -> [AudioUnitComponentDescription] {
        // Nur reine Audioeffekte. Subtyp und Hersteller bleiben `0`,
        // was bei `components(matching:)` „beliebig" bedeutet.
        var wanted = AudioComponentDescription()
        wanted.componentType = AudioUnitIdentity.effectComponentType
        wanted.componentSubType = 0
        wanted.componentManufacturer = 0
        wanted.componentFlags = 0
        wanted.componentFlagsMask = 0

        return AVAudioUnitComponentManager.shared()
            .components(matching: wanted)
            .map { component in
                AudioUnitComponentDescription(
                    componentType: component.audioComponentDescription.componentType,
                    componentSubType: component.audioComponentDescription.componentSubType,
                    componentManufacturer: component.audioComponentDescription.componentManufacturer,
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    isSandboxSafe: component.isSandboxSafe
                )
            }
    }

    public func instrumentComponentDescriptions() -> [AudioUnitComponentDescription] {
        descriptions(componentType: AudioUnitInstrumentIdentity.componentType)
    }

    private func descriptions(componentType: UInt32) -> [AudioUnitComponentDescription] {
        var wanted = AudioComponentDescription()
        wanted.componentType = componentType
        wanted.componentSubType = 0
        wanted.componentManufacturer = 0
        wanted.componentFlags = 0
        wanted.componentFlagsMask = 0

        return AVAudioUnitComponentManager.shared()
            .components(matching: wanted)
            .map { component in
                AudioUnitComponentDescription(
                    componentType: component.audioComponentDescription.componentType,
                    componentSubType: component.audioComponentDescription.componentSubType,
                    componentManufacturer: component.audioComponentDescription.componentManufacturer,
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    isSandboxSafe: component.isSandboxSafe
                )
            }
    }
}
