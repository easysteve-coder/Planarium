import Foundation

/// Output destinations are data. The engine neither owns nor calls a port.
public enum MusicEvent: Equatable, Sendable {
    case programChange(destination: SpatialOutputDestination, channel: UInt8, selection: SpatialProgramChange)
    case midiValue(destination: SpatialOutputDestination, target: SpatialRoutingTarget, value: Double)
    case noteOn(destination: SpatialOutputDestination, channel: UInt8, note: SpatialPlayedNote)
    case noteOff(destination: SpatialOutputDestination, channel: UInt8, note: SpatialPlayedNote)
    case scalar(routingID: UUID, target: SpatialRoutingTarget, value: Double)
    case boolean(routingID: UUID, target: SpatialRoutingTarget, value: Bool)
    case allNotesOff(destination: SpatialOutputDestination, channel: UInt8)
    /// Published to the UI by Runtime; never an audio or MIDI output.
    case sceneChanged(UUID?)
}

