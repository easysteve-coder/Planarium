/// Connection and profile facts may arrive in either order. A new session
/// clears manual visibility; repeated rate publications keep it.
public struct WorkspaceSetupState: Equatable, Sendable {
    public private(set) var visible: Bool
    public private(set) var session: String?
    public private(set) var connected = false
    public private(set) var hasProfile = false
    public private(set) var manualVisibility: Bool?
    public init(visible: Bool = true) { self.visible = visible }
    public enum Event: Equatable, Sendable {
        case connection(session: String, connected: Bool)
        case profile(session: String)
        case disconnected
        case manual(visible: Bool)
    }
    public func applying(_ event: Event) -> Self {
        var next = self
        func begin(_ session: String) {
            if next.session != session {
                next.session = session; next.connected = false
                next.hasProfile = false; next.manualVisibility = nil; next.visible = true
            }
        }
        switch event {
        case let .connection(session, connected):
            begin(session); next.connected = connected
            if !connected { next.hasProfile = false; next.manualVisibility = nil; next.visible = true }
        case .profile(let session): begin(session); next.hasProfile = true
        case .disconnected:
            next.session = nil; next.connected = false; next.hasProfile = false
            next.manualVisibility = nil; next.visible = true
        case .manual(let visible):
            next.visible = visible
            if next.session != nil { next.manualVisibility = visible }
        }
        if next.connected && next.hasProfile { next.visible = next.manualVisibility ?? false }
        return next
    }
}
