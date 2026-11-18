import CoreGraphics

public struct SecondaryPointerGesture: Equatable, Sendable {
    public static let clickThreshold: CGFloat = 4

    public enum Output: Equatable, Sendable {
        case none
        case pan(CGSize)
        case openContextMenu(at: CGPoint)
    }

    private enum State: Equatable, Sendable {
        case idle
        case pressed(CGPoint)
        case panning(CGPoint)
    }

    private var state: State = .idle
    public init() {}

    public mutating func down(at point: CGPoint, inside: Bool) -> Output {
        guard inside, point.x.isFinite, point.y.isFinite else { state = .idle; return .none }
        state = .pressed(point)
        return .none
    }

    public mutating func dragged(to point: CGPoint) -> Output {
        guard point.x.isFinite, point.y.isFinite else { state = .idle; return .none }
        switch state {
        case .idle: return .none
        case let .pressed(origin):
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.clickThreshold else { return .none }
            state = .panning(point)
            return .pan(CGSize(width: point.x - origin.x, height: point.y - origin.y))
        case let .panning(last):
            state = .panning(point)
            return .pan(CGSize(width: point.x - last.x, height: point.y - last.y))
        }
    }

    public mutating func up(at point: CGPoint, inside: Bool) -> Output {
        defer { state = .idle }
        guard point.x.isFinite, point.y.isFinite else { return .none }
        if case .pressed = state, inside { return .openContextMenu(at: point) }
        return .none
    }

    public mutating func cancel() { state = .idle }
}
