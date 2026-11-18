import SickPLSCore

public struct FrameReadResult: Equatable, Sendable {
    public let frames: [Frame]
    public let diagnostics: StreamParser.Diagnostics
    public let reachedEndOfStream: Bool

    public init(frames: [Frame], diagnostics: StreamParser.Diagnostics, reachedEndOfStream: Bool) {
        self.frames = frames
        self.diagnostics = diagnostics
        self.reachedEndOfStream = reachedEndOfStream
    }
}

public final class ReadOnlyFrameStream {
    private let descriptor: SerialPortFileDescriptor
    private var parser = StreamParser()
    private var hasReachedEndOfStream = false
    private var hasClosedDescriptor = false

    public init(descriptor: SerialPortFileDescriptor) { self.descriptor = descriptor }
    public var diagnostics: StreamParser.Diagnostics { parser.diagnostics }

    public func readNext(timeoutMilliseconds: Int32 = 1_000) -> FrameReadResult {
        guard !hasReachedEndOfStream else {
            return FrameReadResult(frames: [], diagnostics: parser.diagnostics, reachedEndOfStream: true)
        }
        switch descriptor.read(timeoutMilliseconds: timeoutMilliseconds) {
        case .bytes(let bytes):
            return FrameReadResult(frames: parser.feed(bytes), diagnostics: parser.diagnostics, reachedEndOfStream: false)
        case .timeout:
            return FrameReadResult(frames: [], diagnostics: parser.diagnostics, reachedEndOfStream: false)
        case .closed:
            hasReachedEndOfStream = true
            return FrameReadResult(frames: parser.finish(), diagnostics: parser.diagnostics, reachedEndOfStream: true)
        }
    }

    @discardableResult
    public func close() -> FrameReadResult {
        if !hasClosedDescriptor { hasClosedDescriptor = true; descriptor.close() }
        guard !hasReachedEndOfStream else {
            return FrameReadResult(frames: [], diagnostics: parser.diagnostics, reachedEndOfStream: true)
        }
        hasReachedEndOfStream = true
        return FrameReadResult(frames: parser.finish(), diagnostics: parser.diagnostics, reachedEndOfStream: true)
    }
}
