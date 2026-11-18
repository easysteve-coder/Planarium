import XCTest
import Foundation

final class CoreMIDITransportContractTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path))
    }
    func testRuntimeTransportHasNoDispatchOrMainHandoffInsideSend() throws {
        let text = try source("Sources/PlanariumMIDI/CoreMIDIConnection.swift")
        let send = String(text[text.range(of: "func send(bytes:")!.lowerBound...])
        XCTAssertTrue(send.contains("MIDISend(")); XCTAssertFalse(send.contains(".async")); XCTAssertFalse(send.contains(".sync"))
    }
    func testMissingOrChangedEndpointIsUnboundBeforeSending() throws {
        let text = try source("Sources/PlanariumMIDI/CoreMIDIConnection.swift")
        XCTAssertTrue(text.contains(".unbound")); XCTAssertTrue(text.contains("expectedUniqueID"))
        XCTAssertTrue(text.contains("if target.uniqueID == 0"))
        XCTAssertTrue(text.contains("MIDISourceCreate"))
        XCTAssertTrue(text.contains("MIDIReceived"))
    }
    func testDestinationCallbackTransfersToMainAndPortsCloseAfterRetireAck() throws {
        let text = try source("Sources/PlanariumMIDI/CoreMIDIConnection.swift")
        let owner = try source("Sources/PlanariumMIDI/MIDIPortOwner.swift")
        XCTAssertTrue(text.contains("DispatchQueue.main.async")); XCTAssertTrue(owner.contains("runtime.retire")); XCTAssertTrue(owner.contains("transport.close()"))
    }
}
