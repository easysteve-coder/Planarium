import Foundation
import PlanariumDomain

/// Numeric receipts only. Storage is allocated with the port, never in record().
/// The port and this value are exclusively owned by Runtime Q.
public struct OutputMonitorEvent: Equatable, Sendable {
    public var sequence: UInt64 = 0
    public var status: UInt8 = 0
    public var number: UInt8 = 0
    public var value: UInt16 = 0
}
public struct OutputMonitorSnapshot: Equatable, Sendable {
    public let portID: UUID
    public let destination: SpatialOutputDestination
    public let generation: UInt64
    public let notes: [UInt8]
    public let controllers: [UInt8]
    public let bends: [UInt16]
    public let pressures: [UInt8]
    public let programs: [UInt8]
    public let events: [OutputMonitorEvent]
}
struct OutputMonitorStorage: Sendable {
    var enabled = false
    private(set) var generation: UInt64 = 0
    private var notes = Array(repeating: UInt8(0), count: 16 * 128)
    private var controllers = Array(repeating: UInt8(255), count: 16 * 128)
    private var bends = Array(repeating: UInt16(8192), count: 16)
    private var pressures = Array(repeating: UInt8(0), count: 16)
    private var programs = Array(repeating: UInt8(255), count: 16)
    private var ring = Array(repeating: OutputMonitorEvent(), count: 200)
    private var head = 0
    private var count = 0
    mutating func record(status: UInt8, number: UInt8, value: UInt16) {
        guard enabled else { return }
        let channel = Int(status & 15), index = Int(status & 15) * 128 + Int(number & 127)
        switch status & 0xF0 {
        case 0x90: notes[index] = UInt8(clamping: value)
        case 0x80: notes[index] = 0
        case 0xB0:
            if number != 120 && number != 123 { controllers[index] = UInt8(clamping: value) }
            if number == 120 || number == 123 {
                for pitch in 0..<128 { notes[channel * 128 + pitch] = 0 }
            }
        case 0xC0: programs[channel] = number
        case 0xD0: pressures[channel] = number
        case 0xE0: bends[channel] = value
        default: break
        }
        generation &+= 1
        ring[head] = .init(sequence: generation, status: status, number: number, value: value)
        head = (head + 1) % ring.count; count = min(count + 1, ring.count)
    }
    func snapshot(id: UUID, destination: SpatialOutputDestination) -> OutputMonitorSnapshot? {
        guard enabled else { return nil }
        // Independent buffers keep the Q tables uniquely referenced across UI frames.
        return .init(portID: id, destination: destination, generation: generation,
                     notes: notes.map { $0 }, controllers: controllers.map { $0 }, bends: bends.map { $0 },
                     pressures: pressures.map { $0 }, programs: programs.map { $0 },
                     events: (0..<count).map { ring[(head - count + $0 + ring.count) % ring.count] })
    }
}
