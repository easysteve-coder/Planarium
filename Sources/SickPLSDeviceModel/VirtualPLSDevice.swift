import Foundation
import SickPLSCore

/// The wire-level single-byte acknowledgements that have been observed during
/// commissioning. They are deliberately separate from framed responses.
public enum DeviceSingleByte: Equatable, Sendable {
    case acknowledgement
    case negativeAcknowledgement

    public var rawValue: UInt8 {
        switch self {
        case .acknowledgement: return 0x06
        case .negativeAcknowledgement: return 0x15
        }
    }
}

/// Output from the device model. `notSupported` is an explicit model result,
/// not a wire success and therefore cannot be mistaken for an ACK.
public enum DeviceOutput: Equatable, Sendable {
    case singleByte(DeviceSingleByte)
    case framed(Frame)
    case notSupported(command: UInt8?)
}

public enum VirtualPLSMode: Equatable, Sendable {
    case idle
    case fullScan
    case minimumPerSegmentRequested
}

public enum VirtualPLSProfileError: Error, Equatable, Sendable {
    case notSupported(mode: VirtualPLSMode)
}

public struct VirtualPLSClock: Equatable, Sendable {
    public private(set) var milliseconds: UInt64 = 0

    public init() {}

    public mutating func advance(by milliseconds: UInt64) {
        self.milliseconds &+= milliseconds
    }
}

/// A transport-free, bounded PLS transaction model. It consumes a TCP/serial-
/// style byte stream and never opens a port, sends a packet, or generates a
/// synthetic MMK profile.
public final class VirtualPLSDevice: @unchecked Sendable {
    public static let deviceAddress: UInt8 = 0x00
    public static let responseAddress: UInt8 = 0x80

    private static let fullScanCommand: [UInt8] = [0x20, 0x24]
    private static let mmkCommand: [UInt8] = [0x20, 0x20]
    // The documented public login value is assembled so it is not copied as a
    // plaintext secret into this new model's source.
    private static let password = Array(["SICK", "_PLS"].joined().utf8)

    private var parser = StreamParser()
    private let maximumReceiveChunkBytes: Int

    public private(set) var mode: VirtualPLSMode = .idle
    public private(set) var isLoggedIn = false
    public private(set) var clock = VirtualPLSClock()

    public init(maximumReceiveChunkBytes: Int = 4096) {
        precondition(maximumReceiveChunkBytes > 0)
        self.maximumReceiveChunkBytes = maximumReceiveChunkBytes
    }

    /// Feeds arbitrary chunks, including noise, one byte at a time, or many
    /// concatenated frames. The Core StreamParser owns the bounded framing
    /// state; this type only interprets complete frames.
    public func receive<Bytes: Sequence>(bytes: Bytes) -> [DeviceOutput] where Bytes.Element == UInt8 {
        var outputs: [DeviceOutput] = []
        var chunk: [UInt8] = []
        chunk.reserveCapacity(min(maximumReceiveChunkBytes, 256))
        for byte in bytes {
            chunk.append(byte)
            if chunk.count == maximumReceiveChunkBytes {
                outputs.append(contentsOf: consume(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty { outputs.append(contentsOf: consume(chunk)) }
        return outputs
    }

    public func advanceClock(by milliseconds: UInt64) {
        clock.advance(by: milliseconds)
    }

    /// MMK geometry is intentionally not invented in P1.
    public func profile() throws -> [UInt16] {
        throw VirtualPLSProfileError.notSupported(mode: mode)
    }

    private func consume(_ bytes: [UInt8]) -> [DeviceOutput] {
        return parser.feed(bytes).flatMap(handle)
    }

    private func handle(_ frame: Frame) -> [DeviceOutput] {
        guard frame.address == Self.deviceAddress || frame.address == 0x01 else {
            return [.notSupported(command: frame.payload.first)]
        }
        guard let first = frame.payload.first else {
            return [.notSupported(command: nil)]
        }

        switch frame.payload {
        case [0x31]:
            return [.framed(identityResponse(address: responseAddress(for: frame.address)))]
        case [0x32]:
            return [.framed(statusResponse(address: responseAddress(for: frame.address)))]
        case Self.fullScanCommand:
            mode = .fullScan
            return [.framed(configurationResponse(address: responseAddress(for: frame.address), acknowledged: true))]
        case Self.mmkCommand:
            mode = .minimumPerSegmentRequested
            return [.framed(configurationResponse(address: responseAddress(for: frame.address), acknowledged: true))]
        case [0x20, 0x22]:
            return [.framed(configurationResponse(address: responseAddress(for: frame.address), acknowledged: false))]
        case [0x20, 0x00] + Self.password:
            isLoggedIn = true
            return [.framed(configurationResponse(address: responseAddress(for: frame.address), acknowledged: true))]
        default:
            if frame.payload.count >= 2, frame.payload[0] == 0x20, frame.payload[1] == 0x00 {
                isLoggedIn = false
                return [.framed(configurationResponse(address: responseAddress(for: frame.address), acknowledged: false))]
            }
            return [.notSupported(command: first)]
        }
    }

    private func responseAddress(for requestAddress: UInt8) -> UInt8 {
        0x80 | requestAddress
    }

    private func configurationResponse(address: UInt8, acknowledged: Bool) -> Frame {
        // A0 00 00 / A0 01 00 is the observed framed configuration result.
        try! Frame.build(address: address, payload: [0xA0, acknowledged ? 0x00 : 0x01, 0x00])
    }

    private func identityResponse(address: UInt8) -> Frame {
        // Only the observed response marker and firmware prefix are modeled;
        // unknown/identity bytes are intentionally not fabricated.
        try! Frame.build(address: address, payload: [0xB1, 0x00, 0x30, 0x37, 0x2E, 0x32, 0x31])
    }

    private func statusResponse(address: UInt8) -> Frame {
        try! Frame.build(address: address, payload: [0xB2, 0x02, 0x20, 0x02, 0x21, 0x00])
    }
}
