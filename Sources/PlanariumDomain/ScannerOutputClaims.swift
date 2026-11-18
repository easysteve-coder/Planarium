import Foundation
import PlanariumMusicCore
import PlanariumControllerCore

extension CompiledInstrument {
    /// The sum CoreMIDI output of the instrument, if one is chosen.
    public var sumMIDIEndpoint: Int32? { midiTarget?.uniqueID }

    /// The sound targets the scanner instrument plays, per class. A controller
    /// layout is compiled against them: the scanner keeps what it owns.
    public func outputClaims(source: PlayingSourceID = .scanner) -> [OutputClaim] {
        layers.flatMap { layer in
            layer.routings.compactMap { routing -> OutputClaim? in
                guard let outputClass = OutputOwnership.outputClass(of: routing.target),
                      let key = OutputOwnership.key(of: routing.target, midiEndpoint: layer.midiTarget?.uniqueID,
                                                    sumEndpoint: midiTarget?.uniqueID) else { return nil }
                return OutputClaim(source: source, target: key, outputClass: outputClass)
            }
        }
    }
}

extension InstrumentDocument {
    /// Rejects a controller layout the engine could not play (feel, zones,
    /// target/program fit, MIDI ranges). Ownership conflicts are not errors.
    public func validateController() throws {
        _ = try CompiledControllerLayout(controller, source: .controller(0), sumEndpoint: midiTarget?.uniqueID)
    }
}
