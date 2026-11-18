import Combine
import SwiftUI
import SickPLSSetupControl

/// Pending handoffs publish in willSet. Consume only after the value is
/// committed, and only if it is still current (cancel/replacement/two windows).
struct ScannerHandoffBridge: View {
    let handoffs: AnyPublisher<VerifiedScannerConnection?, Never>
    let current: () -> VerifiedScannerConnection?
    let consume: () -> Void
    let connect: (VerifiedScannerConnection) -> Void
    var body: some View {
        EmptyView().onReceive(handoffs.removeDuplicates().receive(on: RunLoop.main)) { endpoint in
            guard let endpoint, current() == endpoint else { return }
            // Claim before invoking the effect, so a nested Main run loop
            // cannot admit the same handoff through another window.
            consume()
            connect(endpoint)
        }
    }
}
