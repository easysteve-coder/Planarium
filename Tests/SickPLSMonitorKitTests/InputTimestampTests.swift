import PlanariumRuntime
import Dispatch
@testable import PlanariumInput
import XCTest
import Combine
import SickPLSCore
import SickPLSMacTransport
@testable import SickPLSMonitorKit

@MainActor final class InputTimestampTests: XCTestCase {
    func testReadThreadTimestampSurvivesRXSessionHandoff() throws {
        let payload: [UInt8] = [B0ScanProfile.commandByte, 1, 0, 0x2C, 0x01, 0xAA]
        let frame = try Frame.build(address: 0x81, payload: payload).encoded()
        let session = RXSession(
            opener: FakeSerialPortOpener(portsToReturn: [
                FakeSerialPortFileDescriptor(readScript: [.bytes(frame), .closed])
            ]),
            readTimeoutMilliseconds: 10,
            // Gegenprobe: Ein Main-Thread-Stempel wäre 99; nur der
            // Lesethread darf den Wert 42.5 in den Batch schreiben.
            clock: ThreadStampClock()
        )
        let expectation = expectation(description: "Profil")
        var received: ScanProfileBatch?
        var cancellable: AnyCancellable?
        cancellable = session.performanceProfiles.sink {
            received = $0
            expectation.fulfill()
            cancellable?.cancel()
        }

        session.connect(portPath: "/dev/cu.latency", baudRate: .baud9600)
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(received?.receivedAtMonotonic, 42.5)
        session.disconnect()
    }
}

private struct ThreadStampClock: RuntimeClock {
 var now: Double { Thread.isMainThread ? 99 : 42.5 }
 func schedule(at deadline: Double, on queue: DispatchQueue, _ action: @escaping @Sendable () -> Void) -> RuntimeCancellation { RuntimeCancellation {} }
}
