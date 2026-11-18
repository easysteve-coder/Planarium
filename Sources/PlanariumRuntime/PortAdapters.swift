import Foundation
import PlanariumDomain

/// A direct, synchronous byte send. Missing target must return unbound.
/// Implementations are thread-safe; no transport queue or leases are involved.
public protocol MIDISendBoundary: Sendable {
    func send(bytes: [UInt8]) -> PortSendResult
}
/// P4 hands over blocks from the current AU instance. It keeps that instance
/// alive until retire's Main ack. A parameter send is normalized 0...1;
/// AudioHost supplies the actual parameter range in its schedule adapter.
public protocol AUScheduleBoundary: Sendable {
    func scheduleMIDI(bytes: [UInt8]) -> PortSendResult
    func scheduleParameter(_ target: SpatialAudioUnitParameterTarget, normalizedValue: Double) -> PortSendResult
}
public enum RuntimePorts {
    public static func midi(id: UUID = UUID(), boundary: any MIDISendBoundary, resetOnBind: Bool = false,
                            destination: SpatialOutputDestination = .midi, uniqueID: Int32? = nil) -> OutputPort {
        .init(id: id, destination: destination, resetOnBind: resetOnBind, midiUniqueID: uniqueID, plannedBoundary: boundary as? any PlannedNoteBoundary) { event in
            if case .programChange(_, let channel, let selection) = event {
                // Separate packets, synchronous on Q: a failed bank prevents
                // the PC, and an incomplete selection never enters memory.
                for bytes in MusicEventMIDIEncoding.programMessages(channel: channel, selection: selection) {
                    let result = boundary.send(bytes: bytes)
                    guard result == .sent else { return result }
                }
                return .sent
            }
            guard let bytes = MusicEventMIDIEncoding.bytes(event) else { return .unbound }
            return boundary.send(bytes: bytes)
        }
    }
    public static func audioUnit(id: UUID = UUID(), stripID: UUID = InstrumentChannel.legacyID, boundary: any AUScheduleBoundary,
                                 resetOnBind: Bool = false) -> OutputPort {
        .init(id: id, destination: .audioUnit(stripID: stripID), resetOnBind: resetOnBind, plannedBoundary: boundary as? any PlannedNoteBoundary) { event in
            if case .scalar(_, .audioUnitParameter(let target), let value) = event {
                return boundary.scheduleParameter(target, normalizedValue: value)
            }
            if case .programChange(_, let channel, let selection) = event {
                for bytes in MusicEventMIDIEncoding.programMessages(channel: channel, selection: selection) {
                    let result = boundary.scheduleMIDI(bytes: bytes)
                    guard result == .sent else { return result }
                }
                return .sent
            }
            guard let bytes = MusicEventMIDIEncoding.bytes(event) else { return .unbound }
            return boundary.scheduleMIDI(bytes: bytes)
        }
    }
}
public enum MusicEventMIDIEncoding {
    public static func releaseMessages(channel: UInt8) -> [[UInt8]] {
        [[0xB0 | (channel & 15), 64, 0], [0xE0 | (channel & 15), 0, 64], [0xB0 | (channel & 15), 123, 0]]
    }
    public static func programMessages(channel: UInt8, selection: SpatialProgramChange) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        if let msb = selection.bankMSB { messages.append([0xB0 | (channel & 15), 0, msb & 127]) }
        if let lsb = selection.bankLSB { messages.append([0xB0 | (channel & 15), 32, lsb & 127]) }
        messages.append([0xC0 | (channel & 15), selection.program & 127])
        return messages
    }
    public static func bytes(_ event: MusicEvent) -> [UInt8]? {
        switch event {
        case .midiValue(_, let target, let value):
            return bytes(.scalar(routingID: SpatialRoutingTarget.missingStripID, target: target, value: value))
        case let .noteOn(_, channel, note): return [0x90 | (channel & 15), note.number, note.velocity]
        case let .noteOff(_, channel, note): return [0x80 | (channel & 15), note.number, 0]
        case .allNotesOff(_, let channel): return [0xB0 | (channel & 15), 123, 0]
        case .boolean(_, .midiCC(let channel, let controller), let value),
             .boolean(_, .audioUnitCC(let channel, let controller, _), let value):
            return [0xB0 | (channel & 15), controller & 127, value ? 127 : 0]
        case .scalar(_, let target, let value):
            guard value.isFinite else { return nil }
            let unit = min(max(value, 0), 1)
            switch target {
            case .midiCC(let channel, let controller), .audioUnitCC(let channel, let controller, _):
                return [0xB0 | (channel & 15), controller & 127, UInt8((unit * 127).rounded())]
            case .midiChannelPressure(let channel), .audioUnitChannelPressure(let channel, _):
                return [0xD0 | (channel & 15), UInt8((unit * 127).rounded())]
            case .midiPitchBend(let channel), .audioUnitPitchBend(let channel, _):
                let bend = UInt16((unit * 16383).rounded())
                return [0xE0 | (channel & 15), UInt8(bend & 127), UInt8(bend >> 7)]
            default: return nil
            }
        default: return nil
        }
    }
}
