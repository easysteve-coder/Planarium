import AVFoundation
import Foundation

public struct StereoPeaks: Equatable, Sendable {
    public var left: Float = 0
    public var right: Float = 0
    public var deliveries: Int = 0
    public var deliveredFrames: Int = 0
    public init(left: Float = 0, right: Float = 0, deliveries: Int = 0, deliveredFrames: Int = 0) {
        self.left = left; self.right = right; self.deliveries = deliveries; self.deliveredFrames = deliveredFrames
    }
}

/// Only the tap writes samples; Main takes a value under the same lock.
/// No UI, Q, scheduling, or mutable graph reference crosses this boundary.
public final class PeakHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var peaks = StereoPeaks()
    public init() {}
    public func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        var local = StereoPeaks()
        for channel in 0..<min(Int(buffer.format.channelCount), 2) {
            var peak: Float = 0
            for frame in 0..<frames { peak = max(peak, abs(data[channel][frame])) }
            if channel == 0 { local.left = peak } else { local.right = peak }
        }
        if buffer.format.channelCount == 1 { local.right = local.left }
        lock.lock()
        peaks.left = max(peaks.left, local.left); peaks.right = max(peaks.right, local.right)
        peaks.deliveries += 1; peaks.deliveredFrames += frames
        lock.unlock()
    }
    public func take() -> StereoPeaks {
        lock.lock(); defer { peaks = StereoPeaks(); lock.unlock() }
        return peaks
    }
}
